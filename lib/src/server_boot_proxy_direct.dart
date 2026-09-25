part of 'server_boot.dart';

/// State holder for in-flight native direct stream requests.
final class _NativeDirectRequestStreamState {
  _NativeDirectRequestStreamState(
    this.requestBody, {
    required this.onTrackedClose,
  });

  final StreamController<Uint8List> requestBody;
  final void Function() onTrackedClose;
  BridgeDetachedSocket? detachedSocket;
  int responseStatusCode = HttpStatus.ok;
  bool detachedSocketUsesTunnel = false;
  final tunnelInputClosed = Completer<void>();
  final detachedReady = Completer<void>();
  final List<Uint8List> _pendingUnconsumedBodyChunks = <Uint8List>[];
  bool requestEnded = false;
  bool responseCompleted = false;
  bool _trackedClosed = false;

  void closeTrackedRequest() {
    if (_trackedClosed) {
      return;
    }
    _trackedClosed = true;
    onTrackedClose();
  }

  void maybeBufferUnconsumedRequestChunk(Uint8List chunk) {
    if (chunk.isEmpty) {
      return;
    }
    if (detachedSocket != null || requestBody.hasListener) {
      return;
    }
    _pendingUnconsumedBodyChunks.add(chunk);
  }

  void flushBufferedChunksToDetachedSocket() {
    final socket = detachedSocket;
    if (socket == null || _pendingUnconsumedBodyChunks.isEmpty) {
      return;
    }
    for (final chunk in _pendingUnconsumedBodyChunks) {
      socket.bridgeSocket.add(chunk);
    }
    _pendingUnconsumedBodyChunks.clear();
  }

  void clearBufferedRequestChunks() {
    _pendingUnconsumedBodyChunks.clear();
  }
}

/// Starts the native callback transport path (no bridge socket backend).
NativeProxyServer _startNativeDirectProxy({
  required String host,
  required int port,
  required int backlog,
  required bool v6Only,
  required bool shared,
  required bool requestClientCertificate,
  required bool enableHttp2,
  required bool enableHttp3,
  required String? tlsCertPath,
  required String? tlsKeyPath,
  required String? tlsCertPassword,
  required _BridgeHandlePayload directPayloadHandler,
  required _BridgeHandleStream handleStream,
  void Function()? onSocketOpened,
  void Function()? onSocketClosed,
  void Function()? onRequestStarted,
  void Function()? onRequestCompleted,
}) {
  final nativeDirectStreams = <int, _NativeDirectRequestStreamState>{};
  late final NativeProxyServer proxyRef;

  void processRequestFrame(int requestId, Uint8List requestPayload) {
    if (proxyRef.isClosed) {
      return;
    }

    void beginTrackedRequest() {
      onSocketOpened?.call();
      onRequestStarted?.call();
    }

    void endTrackedRequest() {
      onRequestCompleted?.call();
      onSocketClosed?.call();
    }

    Future<void> pushResponsePayload(
      Uint8List responsePayload, {
      bool requireAccepted = false,
    }) async {
      if (proxyRef.isClosed) {
        if (requireAccepted) throw StateError('Native tunnel is closed');
        return;
      }
      final pushed = await proxyRef.pushDirectResponseFrameAsync(
        requestId,
        responsePayload,
      );
      if (!pushed) {
        if (requireAccepted) throw StateError('Native tunnel rejected a frame');
        _nativeVerboseLog(
          '[server_native] native direct callback push failed for requestId=$requestId',
        );
      }
    }

    Future<void> forwardDetachedOutput(
      BridgeDetachedSocket detachedSocket, {
      required Future<void> Function(Uint8List chunkBytes) emitChunk,
    }) async {
      Future<void> emitBounded(Uint8List bytes) async {
        // Socket read chunks can grow beyond the native frame limit when a
        // writer floods the loopback pair. Bound every frame and await native
        // capacity before reading the next chunk; never discard rejected data.
        for (var offset = 0; offset < bytes.length; offset += 16384) {
          final end = offset + 16384 < bytes.length
              ? offset + 16384
              : bytes.length;
          await emitChunk(Uint8List.sublistView(bytes, offset, end));
        }
      }

      final prefetched = detachedSocket.takePrefetchedTunnelBytes();
      if (prefetched != null) await emitBounded(prefetched);
      final bridgeIterator = detachedSocket.bridgeIterator();
      while (await bridgeIterator.moveNext()) {
        await emitBounded(bridgeIterator.current);
      }
    }

    Future<void> removeNativeDirectStream({
      required _NativeDirectRequestStreamState streamState,
      bool closeDetachedSocket = true,
      bool closeTrackedRequest = true,
    }) async {
      final removed = nativeDirectStreams.remove(requestId);
      if (!identical(removed, streamState)) {
        return;
      }
      if (!streamState.requestBody.isClosed) {
        unawaited(streamState.requestBody.close());
      }
      streamState.clearBufferedRequestChunks();
      if (closeDetachedSocket) {
        final detachedSocket = streamState.detachedSocket;
        if (detachedSocket != null) {
          await detachedSocket.close();
        }
      }
      if (closeTrackedRequest) {
        streamState.closeTrackedRequest();
      }
    }

    if (BridgeRequestFrame.isStartPayload(requestPayload)) {
      BridgeRequestFrame startFrame;
      try {
        startFrame = BridgeRequestFrame.decodeStartPayload(requestPayload);
      } catch (error, stack) {
        stderr.writeln(
          '[server_native] native direct callback handler error: $error\n$stack',
        );
        unawaited(pushResponsePayload(_encodeDirectBadRequestPayload(error)));
        return;
      }
      beginTrackedRequest();

      final requestBody = StreamController<Uint8List>(sync: true);
      final streamState = _NativeDirectRequestStreamState(
        requestBody,
        onTrackedClose: endTrackedRequest,
      );
      nativeDirectStreams[requestId] = streamState;

      unawaited(() async {
        var keepStreamState = false;
        var detachedForwardingStarted = false;
        var responseStartSent = false;

        void startDetachedForwardingIfNeeded() {
          if (!responseStartSent) {
            return;
          }
          if (detachedForwardingStarted) {
            return;
          }
          final detachedSocket = streamState.detachedSocket;
          if (detachedSocket == null) {
            return;
          }
          detachedForwardingStarted = true;
          keepStreamState = true;
          final usesTunnel = streamState.detachedSocketUsesTunnel;
          unawaited(() async {
            try {
              if (usesTunnel) {
                await pushResponsePayload(
                  BridgeResponseFrame.encodeEndPayload(),
                );
                await forwardDetachedOutput(
                  detachedSocket,
                  emitChunk: (chunk) async {
                    await pushResponsePayload(
                      BridgeTunnelFrame.encodeChunkPayload(chunk),
                      requireAccepted: true,
                    );
                  },
                );
              } else {
                await forwardDetachedOutput(
                  detachedSocket,
                  emitChunk: (chunk) async {
                    await pushResponsePayload(
                      BridgeResponseFrame.encodeChunkPayload(chunk),
                      requireAccepted: true,
                    );
                  },
                );
                await pushResponsePayload(
                  BridgeResponseFrame.encodeEndPayload(),
                );
              }
            } catch (_) {
              // Peer closure and write errors both end the tunnel.
            } finally {
              if (usesTunnel &&
                  identical(nativeDirectStreams[requestId], streamState)) {
                await pushResponsePayload(
                  BridgeTunnelFrame.encodeClosePayload(),
                );
                await streamState.tunnelInputClosed.future;
              }
              await removeNativeDirectStream(
                streamState: streamState,
                closeDetachedSocket: true,
                closeTrackedRequest: true,
              );
            }
          }());
        }

        try {
          await handleStream(
            frame: startFrame,
            bodyStream: requestBody.stream.map((chunk) {
              proxyRef.consumeDirectRequestBytes(requestId, chunk.length);
              return chunk;
            }),
            onDetachedSocket: (socket) {
              streamState.detachedSocket = socket;
              streamState.flushBufferedChunksToDetachedSocket();
              startDetachedForwardingIfNeeded();
            },
            onResponseStart: (frame) async {
              responseStartSent = true;
              streamState.responseStatusCode = frame.status;
              streamState.detachedSocketUsesTunnel =
                  frame.status == HttpStatus.switchingProtocols;
              streamState.detachedSocket = frame.detachedSocket;
              streamState.flushBufferedChunksToDetachedSocket();
              final detached = frame.detachedSocket;
              if (detached != null) {
                final accepted = await proxyRef.pushDirectResponseFrameAsync(
                  requestId,
                  detached.detachFrame(),
                );
                if (!accepted) {
                  throw StateError('Native request closed before detachment');
                }
                await streamState.detachedReady.future.timeout(
                  const Duration(seconds: 5),
                );
              }
              if (detached?.raw != true) {
                await pushResponsePayload(frame.encodeStartPayload());
              }
              startDetachedForwardingIfNeeded();
            },
            onResponseChunk: (chunkBytes) async {
              if (chunkBytes.isEmpty) {
                return;
              }
              for (
                var offset = 0;
                offset < chunkBytes.length;
                offset += 16384
              ) {
                final end = offset + 16384 < chunkBytes.length
                    ? offset + 16384
                    : chunkBytes.length;
                await pushResponsePayload(
                  BridgeResponseFrame.encodeChunkPayload(
                    Uint8List.sublistView(chunkBytes, offset, end),
                  ),
                );
              }
            },
          );
          streamState.responseCompleted = true;
          if (!requestBody.hasListener && streamState.detachedSocket == null) {
            for (final chunk in streamState._pendingUnconsumedBodyChunks) {
              proxyRef.consumeDirectRequestBytes(requestId, chunk.length);
            }
            streamState.clearBufferedRequestChunks();
          }
          if (streamState.detachedSocket != null) {
            startDetachedForwardingIfNeeded();
          } else {
            await pushResponsePayload(BridgeResponseFrame.encodeEndPayload());
            if (streamState.requestEnded) {
              await removeNativeDirectStream(
                streamState: streamState,
                closeDetachedSocket: true,
                closeTrackedRequest: true,
              );
            }
          }
        } catch (error, stack) {
          stderr.writeln(
            '[server_native] native direct callback stream handler error: $error\n$stack',
          );
          await pushResponsePayload(
            _internalServerErrorFrame(error).encodePayload(),
          );
          streamState.responseCompleted = true;
          if (!requestBody.hasListener && streamState.detachedSocket == null) {
            for (final chunk in streamState._pendingUnconsumedBodyChunks) {
              proxyRef.consumeDirectRequestBytes(requestId, chunk.length);
            }
            streamState.clearBufferedRequestChunks();
          }
          if (streamState.requestEnded && streamState.detachedSocket == null) {
            await removeNativeDirectStream(
              streamState: streamState,
              closeDetachedSocket: true,
              closeTrackedRequest: true,
            );
          }
        } finally {
          if (!keepStreamState &&
              streamState.requestEnded &&
              streamState.detachedSocket == null) {
            await removeNativeDirectStream(
              streamState: streamState,
              closeDetachedSocket: true,
              closeTrackedRequest: true,
            );
          }
        }
      }());
      return;
    }

    final streamState = nativeDirectStreams[requestId];
    if (streamState != null) {
      if (BridgeDetachedSocket.isReady(requestPayload)) {
        if (!streamState.detachedReady.isCompleted) {
          streamState.detachedReady.complete();
        }
        return;
      }
      if (BridgeRequestFrame.isChunkPayload(requestPayload)) {
        try {
          final chunk = BridgeRequestFrame.decodeChunkPayload(requestPayload);
          if (chunk.isNotEmpty) {
            final detachedSocket = streamState.detachedSocket;
            if (detachedSocket != null) {
              detachedSocket.bridgeSocket.add(chunk);
            } else if (streamState.responseCompleted &&
                !streamState.requestBody.hasListener) {
              proxyRef.consumeDirectRequestBytes(requestId, chunk.length);
            } else {
              streamState.maybeBufferUnconsumedRequestChunk(chunk);
              streamState.requestBody.add(chunk);
            }
          }
        } catch (error) {
          streamState.requestBody.addError(error);
          streamState.requestEnded = true;
          unawaited(streamState.requestBody.close());
          if (streamState.responseCompleted &&
              streamState.detachedSocket == null) {
            unawaited(
              removeNativeDirectStream(
                streamState: streamState,
                closeDetachedSocket: true,
                closeTrackedRequest: true,
              ),
            );
          }
        }
        return;
      }
      if (BridgeRequestFrame.isEndPayload(requestPayload)) {
        try {
          BridgeRequestFrame.decodeEndPayload(requestPayload);
        } catch (error) {
          streamState.requestBody.addError(error);
        }
        streamState.requestEnded = true;
        unawaited(streamState.requestBody.close());
        if (streamState.responseCompleted &&
            streamState.detachedSocket == null) {
          unawaited(
            removeNativeDirectStream(
              streamState: streamState,
              closeDetachedSocket: true,
              closeTrackedRequest: true,
            ),
          );
        }
        return;
      }

      final detachedSocket = streamState.detachedSocket;
      if (detachedSocket != null && streamState.detachedSocketUsesTunnel) {
        if (BridgeTunnelFrame.isChunkPayload(requestPayload)) {
          Uint8List chunkBytes;
          try {
            chunkBytes = BridgeTunnelFrame.decodeChunkPayload(requestPayload);
          } catch (error) {
            _nativeVerboseLog(
              '[server_native] invalid native direct tunnel chunk for requestId=$requestId: $error',
            );
            unawaited(
              removeNativeDirectStream(
                streamState: streamState,
                closeDetachedSocket: true,
                closeTrackedRequest: true,
              ),
            );
            return;
          }
          if (chunkBytes.isNotEmpty) {
            try {
              detachedSocket.bridgeSocket.add(chunkBytes);
            } on SocketException {
              // A native frame can arrive after the detached peer has closed.
              // Finish this request without terminating the shared drain loop.
              unawaited(
                removeNativeDirectStream(
                  streamState: streamState,
                  closeDetachedSocket: true,
                  closeTrackedRequest: true,
                ),
              );
              if (!streamState.tunnelInputClosed.isCompleted) {
                streamState.tunnelInputClosed.complete();
              }
            }
          }
          return;
        }

        if (BridgeTunnelFrame.isClosePayload(requestPayload)) {
          try {
            BridgeTunnelFrame.decodeClosePayload(requestPayload);
          } catch (_) {}
          unawaited(detachedSocket.bridgeSocket.close());
          if (!streamState.tunnelInputClosed.isCompleted) {
            streamState.tunnelInputClosed.complete();
          }
          return;
        }
      }

      _nativeVerboseLog(
        '[server_native] dropping unexpected in-flight native direct request frame '
        'for requestId=$requestId',
      );
      return;
    }

    if (BridgeRequestFrame.isChunkPayload(requestPayload) ||
        BridgeRequestFrame.isEndPayload(requestPayload) ||
        BridgeTunnelFrame.isChunkPayload(requestPayload) ||
        BridgeTunnelFrame.isClosePayload(requestPayload)) {
      _nativeVerboseLog(
        '[server_native] dropping unmatched native direct frame for requestId=$requestId',
      );
      return;
    }

    unawaited(() async {
      beginTrackedRequest();
      try {
        final result = await directPayloadHandler(requestPayload);
        final responsePayload =
            result.encodedPayload ?? result.frame.encodePayload();
        await pushResponsePayload(responsePayload);
      } catch (error, stack) {
        stderr.writeln(
          '[server_native] native direct callback handler error: $error\n$stack',
        );
        await pushResponsePayload(
          _internalServerErrorFrame(error).encodePayload(),
        );
      } finally {
        endTrackedRequest();
      }
    }());
  }

  final proxy = NativeProxyServer.start(
    host: host,
    port: port,
    // Direct queue mode does not use a Dart bridge socket. Keep the backend
    // endpoint empty so Zig can distinguish it from bridge mode.
    backendHost: '',
    backendPort: 0,
    backlog: backlog,
    v6Only: v6Only,
    shared: shared,
    requestClientCertificate: requestClientCertificate,
    enableHttp2: enableHttp2,
    enableHttp3: enableHttp3,
    tlsCertPath: tlsCertPath,
    tlsKeyPath: tlsKeyPath,
    tlsCertPassword: tlsCertPassword,
    directRequestCallback: null,
  );
  proxyRef = proxy;

  unawaited(() async {
    var drained = 0;
    while (!proxyRef.isClosed) {
      NativeDirectRequestFrame? frame;
      try {
        // Use non-blocking native polling to avoid monopolizing the isolate
        // thread during websocket tunnel forwarding and teardown races.
        frame = proxyRef.pollDirectRequestFrame(timeoutMs: 0);
      } catch (error, stack) {
        stderr.writeln(
          '[server_native] native direct poll failed: $error\n$stack',
        );
        if (proxyRef.isClosed) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        continue;
      }
      if (frame == null) {
        drained = 0;
        await proxyRef.waitForDirectRequestFrame();
        continue;
      }
      processRequestFrame(frame.requestId, frame.payload);
      if (++drained == 64) {
        drained = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
  }());

  return proxy;
}
