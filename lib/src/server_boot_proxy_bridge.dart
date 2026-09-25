part of 'server_boot.dart';

/// Tracks open sockets and in-flight request counts for a proxy runtime.
///
/// Used to implement `HttpServer.connectionsInfo()` semantics on top of the
/// native transport listener(s).
final class _ProxyConnectionCounters {
  int _openSockets = 0;
  int _activeRequests = 0;
  int _detached = 0;
  void onDetached() => _detached++;
  void onDetachedClosed() {
    if (_detached > 0) _detached--;
  }

  /// Records a newly accepted backend bridge socket.
  void onSocketOpened() {
    _openSockets++;
  }

  /// Records socket close and clamps active request count.
  void onSocketClosed() {
    if (_openSockets > 0) {
      _openSockets--;
    }
    if (_activeRequests > _openSockets) {
      _activeRequests = _openSockets;
    }
  }

  /// Records request dispatch start for one bridge frame.
  void onRequestStarted() {
    _activeRequests++;
  }

  /// Records request dispatch completion.
  void onRequestCompleted() {
    if (_activeRequests > 0) {
      _activeRequests--;
    }
  }

  /// Returns a current [HttpConnectionsInfo] snapshot.
  HttpConnectionsInfo snapshot() {
    final info = HttpConnectionsInfo();
    info.total = (_openSockets - _detached).clamp(0, _openSockets);
    info.active = (_activeRequests - _detached).clamp(0, _activeRequests);
    info.idle = (info.total - info.active).clamp(0, info.total);
    info.closing = 0;
    return info;
  }

  /// Clears tracked counters.
  void reset() {
    _openSockets = 0;
    _activeRequests = 0;
  }
}

/// Binds the local bridge transport server used for Zig <-> Dart frames.
///
/// On Unix this prefers a Unix-domain socket, falling back to loopback TCP.
/// On non-Unix hosts this always uses loopback TCP.
Future<_BridgeBinding> _bindBridgeServer() async {
  if (Platform.isLinux || Platform.isMacOS) {
    Directory? directory;
    String? path;
    try {
      // Reserve a namespace atomically across isolates and processes. A timestamp
      // alone can collide, and failed-bind cleanup must never unlink a peer.
      directory = await Directory.systemTemp.createTemp(
        'server_native_bridge_',
      );
      final ownedDirectory = directory;
      path = '${directory.path}/bridge.sock';
      final unixAddress = InternetAddress(path, type: InternetAddressType.unix);
      final server = await ServerSocket.bind(unixAddress, 0);
      return _BridgeBinding(
        server: server,
        backendKind: bridgeBackendKindUnix,
        backendHost: '',
        backendPort: 0,
        backendPath: path,
        dispose: () async {
          await server.close();
          try {
            await ownedDirectory.delete(recursive: true);
          } catch (_) {}
        },
      );
    } catch (error) {
      stderr.writeln(
        '[server_native] unix bridge bind failed ($path): $error; falling back to loopback tcp.',
      );
      try {
        await directory?.delete(recursive: true);
      } catch (_) {}
    }
  }

  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  return _BridgeBinding(
    server: server,
    backendKind: bridgeBackendKindTcp,
    backendHost: InternetAddress.loopbackIPv4.address,
    backendPort: server.port,
    backendPath: null,
    dispose: () => server.close(),
  );
}

/// Handles one accepted bridge socket from the native Zig transport.
///
/// This function decodes request frames, dispatches to Dart handlers, encodes
/// response frames, and runs tunnel mode for upgraded/detached sockets.
Future<void> _handleBridgeSocket(
  Socket socket, {
  required _BridgeHandleFrame handleFrame,
  required _BridgeHandleStream handleStream,
  _BridgeHandlePayload? handlePayload,
  Duration? Function()? idleTimeoutProvider,
  void Function()? onRequestStarted,
  void Function()? onRequestCompleted,
  void Function()? onSocketClosed,
}) async {
  final reader = _SocketFrameReader(socket);
  final writer = _BridgeSocketWriter(socket);
  var transportFailed = false;
  try {
    while (true) {
      Uint8List? firstPayload;
      try {
        firstPayload = await reader.readFrame(
          timeout: idleTimeoutProvider?.call(),
        );
      } on TimeoutException {
        return;
      }
      if (firstPayload == null) {
        return;
      }

      try {
        if (BridgeRequestFrame.isStartPayload(firstPayload)) {
          final startFrame = BridgeRequestFrame.decodeStartPayload(
            firstPayload,
          );
          onRequestStarted?.call();
          try {
            await _handleChunkedBridgeRequest(
              reader,
              writer,
              handleStream: handleStream,
              startFrame: startFrame,
            );
          } finally {
            onRequestCompleted?.call();
          }
          continue;
        }
      } on SocketException {
        transportFailed = true;
        return;
      } catch (error) {
        _writeBridgeBadRequest(writer, error);
        continue;
      }

      onRequestStarted?.call();
      try {
        late final _BridgeHandleFrameResult response;
        if (handlePayload != null) {
          try {
            response = await handlePayload(firstPayload);
          } catch (error) {
            _writeBridgeBadRequest(writer, error);
            continue;
          }
        } else {
          BridgeRequestFrame frame;
          try {
            frame = BridgeRequestFrame.decodePayload(firstPayload);
          } catch (error) {
            _writeBridgeBadRequest(writer, error);
            continue;
          }
          response = await handleFrame(frame);
        }
        _writeBridgeResponse(writer, response);
        final detachedSocket = response.detachedSocket;
        if (detachedSocket != null) {
          await _runDetachedSocketTunnel(reader, writer, detachedSocket);
          return;
        }
      } finally {
        onRequestCompleted?.call();
      }
    }
  } on SocketException {
    // Native cancellation and protocol-error shutdown close this internal socket.
    transportFailed = true;
  } catch (error, stack) {
    transportFailed = true;
    stderr.writeln('[server_native] bridge socket error: $error\n$stack');
  } finally {
    onSocketClosed?.call();
    await reader.cancel();
    if (transportFailed) {
      socket.destroy();
    } else {
      try {
        await socket.flush();
      } catch (_) {}
      try {
        await socket.close();
      } catch (_) {}
    }
  }
}
