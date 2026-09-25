import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

Future<HttpServer> _bind(String mode) => mode == 'sdk'
    ? HttpServer.bind(InternetAddress.loopbackIPv4, 0)
    : NativeHttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        nativeCallback: mode == 'direct',
        http3: false,
      );

void main() {
  final fixtures = jsonDecode(
    File('test/fixtures/http_server/requests.json').readAsStringSync(),
  ) as List;
  for (final mode in ['sdk', 'direct', 'bridge']) {
    group(mode, () {
      for (final fixture in fixtures.cast<Map<String, dynamic>>()) {
        test('wire fixture: ${fixture['name']}', () async {
          final server = await _bind(mode);
          addTearDown(() => server.close(force: true));
          var handled = false;
          server.listen((request) async {
            handled = true;
            if (request.uri.hasFragment) {
              request.response.statusCode = 400;
            } else {
              expect(request.uri.toString(), fixture['target']);
              expect(request.headers['x-trace'] ?? [], fixture['trace']);
              final body = await utf8.decoder.bind(request).join();
              expect(body, fixture['body']);
              request.response.headers.set('x-fixture', fixture['name']);
              request.response.write(body);
            }
            await request.response.close();
          });
          final socket = await Socket.connect('127.0.0.1', server.port);
          addTearDown(socket.destroy);
          final reply = latin1.decoder.bind(socket).join();
          socket.add(latin1.encode(fixture['wire'] as String));
          final text = await reply.timeout(const Duration(seconds: 3));
          if (fixture['reject'] == true) {
            expect(handled, isFalse);
            expect(text.isEmpty || text.startsWith('HTTP/1.1 400 '), isTrue);
          } else {
            expect(text, startsWith('HTTP/1.1 ${fixture['status']} '));
          }
          if (fixture['status'] == 200) {
            expect(handled, isTrue);
            expect(text, contains('x-fixture: ${fixture['name']}'));
          }
        });
      }
      test(
        'raw detachment preserves application-written HTTP response',
        () async {
          final server = await _bind(mode);
          addTearDown(() => server.close(force: true));
          const wire =
              'HTTP/1.1 202 Accepted\r\n'
              'Content-Length: 5\r\nConnection: close\r\n'
              'X-Manual: retained\r\n\r\nhello';
          server.listen((request) async {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.write(wire);
            await socket.flush();
            await socket.close();
            socket.destroy();
          });
          final client = await Socket.connect('127.0.0.1', server.port);
          addTearDown(client.destroy);
          final response = latin1.decoder.bind(client).join();
          client.write('GET /manual HTTP/1.1\r\nHost: fixture.test\r\n\r\n');
          expect(await response.timeout(const Duration(seconds: 3)), wire);
        },
      );
      test(
        'streamed upload and paused response reader preserve bytes',
        () async {
          final server = await _bind(mode);
          addTearDown(() => server.close(force: true));
          final payload = List<int>.generate(256 * 1024, (i) => i % 251);
          server.listen((request) async {
            request.response.headers.contentType = ContentType.binary;
            await request.response.addStream(request);
            await request.response.close();
          });
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final request = await client.post(
            '127.0.0.1',
            server.port,
            '/upload',
          );
          // Unknown length exercises chunked upload and response framing.
          await request.addStream(
            Stream.fromIterable([
              for (var offset = 0; offset < payload.length; offset += 1024)
                payload.sublist(offset, offset + 1024),
            ]),
          );
          final response = await request.close();
          final received = <int>[];
          final complete = Completer<void>();
          late StreamSubscription<List<int>> subscription;
          subscription = response.listen(
            (chunk) {
              received.addAll(chunk);
              subscription.pause();
              scheduleMicrotask(subscription.resume);
            },
            onError: complete.completeError,
            onDone: complete.complete,
          );
          await complete.future.timeout(const Duration(seconds: 10));
          expect(response.statusCode, 200);
          expect(received, payload);
        },
      );
      test('raw slow reader receives every byte when it resumes', () async {
        final server = await _bind(mode);
        final flooded = Completer<Socket>();
        final chunk = Uint8List.fromList(
          List<int>.generate(1024 * 1024, (i) => i % 251),
        );
        const count = 32;
        server.listen((request) async {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          for (var i = 0; i < count; i++) {
            socket.add(chunk);
          }
          flooded.complete(socket);
          await socket.close();
        });
        final client = await Socket.connect('127.0.0.1', server.port);
        addTearDown(() async {
          client.destroy();
          await server.close(force: true);
        });
        client.write('GET /resume HTTP/1.1\r\nHost: fixture.test\r\n\r\n');
        final socket = await flooded.future.timeout(const Duration(seconds: 3));
        addTearDown(socket.destroy);
        // The application has queued the entire payload before the peer reads.
        var received = 0;
        await (() async {
          await for (final bytes in client) {
            for (final byte in bytes) {
              if (byte != chunk[received % chunk.length]) {
                fail('Corrupt tunnel byte at offset $received');
              }
              received++;
            }
          }
        })().timeout(const Duration(seconds: 15));
        expect(received, count * chunk.length);
      });
      test('raw slow reader closes after owner drain deadline', () async {
        final server = await _bind(mode);
        final detached = Completer<Socket>();
        server.listen((request) async {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          final chunk = Uint8List(1024 * 1024);
          for (var i = 0; i < 64; i++) {
            socket.add(chunk);
          }
          detached.complete(socket);
        });
        final client = await Socket.connect('127.0.0.1', server.port);
        addTearDown(() async {
          client.destroy();
          await server.close(force: true);
        });
        // Deliberately never subscribe to the client's incoming stream.
        client.write('GET /slow HTTP/1.1\r\nHost: fixture.test\r\n\r\n');
        final socket = await detached.future.timeout(
          const Duration(seconds: 3),
        );
        addTearDown(socket.destroy);
        final drained = socket.drain<void>();
        final owned = <Socket>{socket};
        unawaited(socket.done.whenComplete(() => owned.remove(socket)));
        await server.close().timeout(const Duration(seconds: 3));
        await socket.close().timeout(
          const Duration(seconds: 1),
          onTimeout: () {
            for (final pending in owned) {
              pending.destroy();
            }
            return socket;
          },
        );
        for (final pending in owned) {
          pending.destroy();
        }
        await drained.timeout(const Duration(seconds: 2));
      });
      for (final force in [false, true]) {
        test(
          'detached WebSocket survives HTTP server close force=$force',
          () async {
            final server = await _bind(mode);
            final accepted = Completer<WebSocket>();
            server.listen((request) async {
              final ws = await WebSocketTransformer.upgrade(request);
              ws.listen(ws.add);
              accepted.complete(ws);
            });
            final port = server.port;
            final client = await WebSocket.connect(
              'ws://127.0.0.1:${server.port}/',
            );
            final peer = await accepted.future;
            final echo = Completer<String>();
            final closed = Completer<void>();
            client.listen(
              (event) => echo.complete(event as String),
              onDone: closed.complete,
            );
            addTearDown(() async {
              await client.close();
              await peer.close();
              await server.close(force: true);
            });
            await server
                .close(force: force)
                .timeout(const Duration(seconds: 2));
            await expectLater(
              Socket.connect('127.0.0.1', port),
              throwsA(isA<SocketException>()),
            );
            client.add('still-owned-by-application');
            expect(
              await echo.future.timeout(const Duration(seconds: 2)),
              'still-owned-by-application',
            );
            await peer.close(WebSocketStatus.goingAway, 'application shutdown');
            await closed.future.timeout(const Duration(seconds: 2));
            expect(client.closeCode, WebSocketStatus.goingAway);
          },
        );
        test(
          'raw detached socket survives HTTP server close force=$force',
          () async {
            final server = await _bind(mode);
            final detached = Completer<Socket>();
            server.listen((request) async {
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              socket.listen(socket.add, onDone: socket.destroy);
              detached.complete(socket);
            });
            final client = await Socket.connect('127.0.0.1', server.port);
            final received = Completer<List<int>>();
            final bytes = <int>[];
            client.listen((chunk) {
              bytes.addAll(chunk);
              if (bytes.length >= 4 && !received.isCompleted) {
                received.complete(bytes);
              }
            });
            client.write('GET /raw HTTP/1.1\r\nHost: fixture.test\r\n\r\n');
            final peer = await detached.future.timeout(
              const Duration(seconds: 2),
            );
            addTearDown(() async {
              client.destroy();
              peer.destroy();
              await server.close(force: true);
            });
            await server
                .close(force: force)
                .timeout(const Duration(seconds: 2));
            client.add([0, 255, 13, 10]);
            expect(await received.future.timeout(const Duration(seconds: 2)), [
              0,
              255,
              13,
              10,
            ]);
          },
        );
      }
    });
  }
}
