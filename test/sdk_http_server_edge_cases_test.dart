import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

// Zig is the sole native backend. Every run
// includes the real dart:io baseline, and both native dispatch paths.
enum _Mode { dartIo, direct, bridge }

Future<HttpServer> _bind(_Mode mode) => mode == _Mode.dartIo
    ? HttpServer.bind(InternetAddress.loopbackIPv4, 0)
    : NativeHttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        http3: false,
        nativeCallback: mode == _Mode.direct,
      );

Future<String> _wire(
  HttpServer server,
  String request, {
  String? delayedBody,
}) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    server.port,
  );
  final bytes = <int>[];
  final done = Completer<void>();
  socket.listen(
    bytes.addAll,
    onDone: () => done.complete(),
    onError: (Object error) {
      // Some protocol rejections close with RST rather than a response.
      if (error is! SocketException) done.completeError(error);
    },
  );
  try {
    socket.add(latin1.encode(request));
    await socket.flush();
    if (delayedBody != null) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      socket.add(latin1.encode(delayedBody));
      await socket.flush();
    }
    await done.future.timeout(const Duration(seconds: 3));
    return latin1.decode(bytes);
  } finally {
    socket.destroy();
  }
}

void main() {
  for (final mode in _Mode.values) {
    group(mode.name, () {
      late HttpServer server;
      setUp(() async {
        server = await _bind(mode);
      });
      tearDown(() async {
        await server.close(force: true).timeout(const Duration(seconds: 5));
      });

      for (final target in [
        '/foo/bar?qs=value',
        '/a%20b/%23?q=one&q=two&empty=',
        '/a:b?encoded=%2F%3F',
      ]) {
        test('request metadata preserves $target', () async {
          final seen = Completer<Map<String, Object?>>();
          server.listen((request) async {
            seen.complete({
              'method': request.method,
              'uri': request.uri.toString(),
              'requestedUri': request.requestedUri.toString(),
              'protocol': request.protocolVersion,
              'host': request.headers.value('host'),
            });
            request.response.contentLength = 0;
            await request.response.close();
          });
          final reply = await _wire(
            server,
            'GET $target HTTP/1.1\r\nHost: example.test:8123\r\nConnection: close\r\n\r\n',
          );
          expect(reply, startsWith('HTTP/1.1 200 '));
          expect(await seen.future, {
            'method': 'GET',
            'uri': target,
            'requestedUri': 'http://example.test:8123$target',
            'protocol': '1.1',
            'host': 'example.test:8123',
          });
        });
      }

      for (final version in ['1.0', '1.1']) {
        test('protocolVersion is the numeric version $version', () async {
          final seen = Completer<String>();
          server.listen((request) async {
            seen.complete(request.protocolVersion);
            request.response.contentLength = 0;
            await request.response.close();
          });
          await _wire(
            server,
            'GET / HTTP/$version\r\nHost: localhost\r\nConnection: close\r\n\r\n',
          );
          expect(await seen.future, version);
        });
      }

      for (final target in ['/bad path']) {
        test('reject malformed request target ${jsonEncode(target)}', () async {
          var dispatched = false;
          server.listen((request) async {
            dispatched = true;
            request.response.contentLength = 0;
            await request.response.close();
          });
          final reply = await _wire(
            server,
            'GET $target HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
          );
          expect(
            dispatched,
            isFalse,
            reason: 'Invalid targets must not reach the handler',
          );
          expect(reply, isNot(startsWith('HTTP/1.1 200 ')));
        });
      }

      test(
        'fragment in request target is not silently escaped into a path',
        () async {
          server.listen((request) async {
            // Frameworks may reject a URI with a fragment. Preserve that signal
            // rather than converting '#' to '%23' before they inspect it.
            request.response.statusCode = request.uri.hasFragment ? 400 : 200;
            request.response.contentLength = 0;
            await request.response.close();
          });
          final reply = await _wire(
            server,
            'GET /#/ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
          );
          expect(reply, startsWith('HTTP/1.1 400 '));
        },
      );

      for (final coding in ['', 'custom-encoding', 'chunked, gzip']) {
        test('reject indeterminate transfer encoding ${jsonEncode(coding)}', () async {
          var dispatched = false;
          server.listen((request) async {
            dispatched = true;
            request.response.contentLength = 0;
            await request.response.close();
          });
          final reply = await _wire(
            server,
            'POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: $coding\r\nConnection: close\r\n\r\n',
          );
          expect(
            dispatched,
            isFalse,
            reason:
                'Ambiguous request framing must be rejected before dispatch',
          );
          expect(reply, isNot(startsWith('HTTP/1.1 200 ')));
        });
      }

      test(
        'GET preserves chunk framing when body arrives after headers',
        () async {
          final body = Completer<String>();
          server.listen((request) async {
            body.complete(await utf8.decoder.bind(request).join());
            request.response.contentLength = 0;
            await request.response.close();
          });
          final reply = await _wire(
            server,
            'GET / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n',
            delayedBody: '3\r\nabc\r\n0\r\n\r\n',
          );
          expect(reply, startsWith('HTTP/1.1 200 '));
          expect(await body.future.timeout(const Duration(seconds: 2)), 'abc');
        },
      );

      for (final valid in [true, false]) {
        test(
          'transfer coding order spans repeated headers valid=$valid',
          () async {
            var dispatched = false;
            server.listen((request) async {
              dispatched = true;
              expect(await utf8.decoder.bind(request).join(), 'abc');
              request.response.contentLength = 0;
              await request.response.close();
            });
            final reply = await _wire(
              server,
              'POST / HTTP/1.1\r\nHost: localhost\r\n'
              'Transfer-Encoding: ${valid ? 'gzip' : 'chunked'}\r\n'
              'Transfer-Encoding: ${valid ? 'chunked' : 'gzip'}\r\n'
              'Connection: close\r\n\r\n3\r\nabc\r\n0\r\n\r\n',
            );
            expect(dispatched, valid);
            expect(reply.startsWith('HTTP/1.1 200 '), valid);
          },
        );
      }

      test(
        'clearing response headers preserves request connection close',
        () async {
          server.listen((request) async {
            request.response.headers.clear();
            request.response.statusCode = HttpStatus.internalServerError;
            request.response.write('error');
            await request.response.close();
          });
          final reply = await _wire(
            server,
            'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
          );
          expect(reply, startsWith('HTTP/1.1 500 '));
          expect(reply, contains('error'));
        },
      );

      for (final coding in ['chunked', 'gzip, chunked']) {
        test('complete chunked framing with $coding', () async {
          final body = Completer<String>();
          server.listen((request) async {
            body.complete(await utf8.decoder.bind(request).join());
            request.response.contentLength = 0;
            await request.response.close();
          });
          final reply = await _wire(
            server,
            'POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: $coding\r\nConnection: close\r\n\r\n'
            '3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n',
          );
          expect(reply, startsWith('HTTP/1.1 200 '));
          // HttpServer removes chunk framing, not arbitrary transfer codings.
          expect(
            await body.future.timeout(const Duration(seconds: 2)),
            'abcde',
          );
        });
      }

      test(
        'empty Connection header follows HttpServer normalization',
        () async {
          final seen = Completer<List<String>?>();
          server.listen((request) async {
            seen.complete(request.headers['connection']);
            request.response.persistentConnection = false;
            request.response.contentLength = 0;
            await request.response.close();
          });
          await _wire(
            server,
            'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: \r\n\r\n',
          );
          expect(await seen.future, isNull);
        },
      );

      for (final force in [false, true]) {
        test('close(force: $force) with four gated requests', () async {
          final arrived = Completer<void>();
          final requests = <HttpRequest>[];
          server.listen((request) {
            requests.add(request);
            if (requests.length == 4) arrived.complete();
          });
          final client = HttpClient()..maxConnectionsPerHost = 4;
          addTearDown(() => client.close(force: true));
          final results = List.generate(4, (_) async {
            try {
              final request = await client.getUrl(
                Uri.parse('http://127.0.0.1:${server.port}/'),
              );
              final response = await request.close();
              await response.drain<void>();
              return response.statusCode;
            } on HttpException {
              return -1;
            } on SocketException {
              return -1;
            }
          });
          await arrived.future.timeout(const Duration(seconds: 3));
          final closing = server.close(force: force);
          if (!force) {
            for (final request in requests) {
              request.response.contentLength = 2;
              request.response.write('ok');
              await request.response.close();
            }
          }
          try {
            await closing.timeout(const Duration(seconds: 3));
            expect(
              await Future.wait(results).timeout(const Duration(seconds: 3)),
              List.filled(4, force ? -1 : 200),
            );
          } finally {
            // A broken force-close must not strand native workers after this
            // assertion fails. Release the gated responses only after checking.
            client.close(force: true);
            if (force) {
              for (final request in requests) {
                try {
                  request.response.contentLength = 0;
                  await request.response.close().timeout(
                    const Duration(seconds: 1),
                  );
                } catch (_) {
                  // Already-aborted responses are expected during cleanup.
                }
              }
            }
          }
        });
      }

      test('WebSocket heartbeat keeps idle connection usable', () async {
        final accepted = Completer<WebSocket>();
        final errors = <Object>[];
        server.listen((request) async {
          final ws = await WebSocketTransformer.upgrade(request);
          ws.pingInterval = const Duration(milliseconds: 200);
          ws.listen(ws.add, onError: errors.add);
          accepted.complete(ws);
        });
        final client = await WebSocket.connect(
          'ws://127.0.0.1:${server.port}/',
        );
        final native = await accepted.future;
        addTearDown(() async {
          await client.close();
          await native.close();
        });
        final received = Completer<dynamic>();
        final done = Completer<void>();
        // Keep the client stream subscribed and unpaused so its automatic pong
        // processing runs during the idle interval.
        client.listen(
          received.complete,
          onDone: done.complete,
          onError: (Object error, StackTrace stack) {
            if (!received.isCompleted) received.completeError(error, stack);
          },
        );
        await Future<void>.delayed(const Duration(milliseconds: 900));
        client.add('after-heartbeats');
        expect(
          await received.future.timeout(const Duration(seconds: 3)),
          'after-heartbeats',
        );
        expect(errors, isEmpty);
        await client.close(WebSocketStatus.normalClosure, 'done');
        await done.future.timeout(const Duration(seconds: 3));
        expect(client.closeCode, WebSocketStatus.normalClosure);
      });

      test('late WebSocket traffic does not stop subsequent requests', () async {
        server.listen((request) async {
          if (!WebSocketTransformer.isUpgradeRequest(request)) {
            request.response.write('still-serving');
            await request.response.close();
            return;
          }
          final ws = await WebSocketTransformer.upgrade(request);
          ws.listen((_) {}, onError: (Object _) {});
          unawaited(ws.close(WebSocketStatus.goingAway));
        });
        for (var attempt = 0; attempt < 4; attempt++) {
          final socket = await Socket.connect('127.0.0.1', server.port);
          final upgraded = Completer<void>();
          final bytes = <int>[];
          socket.listen((chunk) {
            bytes.addAll(chunk);
            if (!upgraded.isCompleted &&
                latin1.decode(bytes).contains('\r\n\r\n')) {
              upgraded.complete();
            }
          }, onError: (Object _) {});
          try {
            socket.write(
              'GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
              'Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n'
              'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n',
            );
            await upgraded.future.timeout(const Duration(seconds: 3));
            // Valid masked empty text frames race the server's close handshake.
            socket.add(
              List<int>.generate(600, (i) => [0x81, 0x80, 1, 2, 3, 4][i % 6]),
            );
            try {
              await socket.flush();
            } on SocketException {
              // A peer that has already closed may reject the late data.
            }
          } finally {
            socket.destroy();
          }
          final response = await _wire(
            server,
            'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
          );
          expect(response, contains('still-serving'));
        }
      });

      test('WebSocket closes when raw peer never answers ping', () async {
        final closed = Completer<int?>();
        final errors = <Object>[];
        server.listen((request) async {
          final ws = await WebSocketTransformer.upgrade(request);
          ws.pingInterval = const Duration(milliseconds: 200);
          ws.listen(
            (_) {},
            onError: errors.add,
            onDone: () => closed.complete(ws.closeCode),
          );
        });
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          server.port,
        );
        addTearDown(socket.destroy);
        final bytes = <int>[];
        socket.listen(bytes.addAll, onError: (Object _) {});
        socket.write(
          'GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
          'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n',
        );
        await socket.flush();
        expect(
          await closed.future.timeout(const Duration(seconds: 3)),
          WebSocketStatus.goingAway,
        );
        expect(latin1.decode(bytes), startsWith('HTTP/1.1 101 '));
        expect(errors, isEmpty);
      });
    });
  }
}
