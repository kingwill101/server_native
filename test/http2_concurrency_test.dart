import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

// Minimal wire client: HPACK static/literal request fields, DATA responses,
// SETTINGS acknowledgements and RST_STREAM. No dependency on the server codec.
final class _Client {
  _Client(this.socket) {
    subscription = socket.listen(
      _receive,
      onError: (Object error) {
        for (final done in responses.values) {
          if (!done.isCompleted) done.completeError(error);
        }
      },
    );
    socket.add(ascii.encode('PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'));
    send(4, 0, 0, []);
  }
  final Socket socket;
  late final StreamSubscription<Uint8List> subscription;
  final pending = <int>[];
  final responses = <int, Completer<String>>{};
  final bodies = <int, List<int>>{};
  final pong = Completer<void>();

  void send(int type, int flags, int stream, List<int> payload) {
    final header = ByteData(9)
      ..setUint8(0, payload.length >> 16)
      ..setUint16(1, payload.length & 0xffff)
      ..setUint8(3, type)
      ..setUint8(4, flags)
      ..setUint32(5, stream);
    socket.add([...header.buffer.asUint8List(), ...payload]);
  }

  Future<String> get(int stream, String path) {
    final done = responses[stream] = Completer<String>();
    bodies[stream] = [];
    final encoded = ascii.encode(path);
    send(1, 5, stream, [
      0x82,
      0x87,
      0x04,
      encoded.length,
      ...encoded,
      0x01,
      9,
      ...ascii.encode('localhost'),
    ]);
    return done.future.timeout(const Duration(seconds: 3));
  }

  void cancel(int stream) {
    send(3, 0, stream, [0, 0, 0, 8]);
    responses.remove(stream)?.complete('cancelled');
    bodies.remove(stream);
  }

  void _receive(Uint8List bytes) {
    pending.addAll(bytes);
    while (pending.length >= 9) {
      final length = (pending[0] << 16) | (pending[1] << 8) | pending[2];
      if (pending.length < length + 9) return;
      final type = pending[3];
      final flags = pending[4];
      final stream =
          ((pending[5] & 127) << 24) |
          (pending[6] << 16) |
          (pending[7] << 8) |
          pending[8];
      final payload = pending.sublist(9, 9 + length);
      pending.removeRange(0, 9 + length);
      if (type == 4 && flags & 1 == 0) send(4, 1, 0, []);
      if (type == 6 && flags & 1 != 0 && !pong.isCompleted) pong.complete();
      if (type == 0) bodies[stream]?.addAll(payload);
      if ((type == 0 || type == 1) && flags & 1 != 0) {
        responses
            .remove(stream)
            ?.complete(utf8.decode(bodies.remove(stream) ?? []));
      }
      if (type == 3) {
        responses
            .remove(stream)
            ?.completeError(StateError('Stream $stream reset: $payload'));
      }
    }
  }

  Future<void> close() async {
    await subscription.cancel();
    socket.destroy();
  }
}

void main() {
  for (final tls in [false, true]) {
    for (final direct in [false, true]) {
      test(
        'HTTP/2 pending handler does not block streams or reset tls=$tls direct=$direct',
        () async {
          final entered = Completer<void>();
          final release = Completer<void>();
          final handlerDone = Completer<void>();
          final server = tls
              ? await NativeHttpServer.bindSecure(
                  '127.0.0.1',
                  0,
                  certificatePath: 'zig/src/testdata/tls-cert.pem',
                  keyPath: 'zig/src/testdata/tls-key.pem',
                  http2: true,
                  http3: false,
                  nativeCallback: direct,
                )
              : await NativeHttpServer.bind(
                  '127.0.0.1',
                  0,
                  http2: true,
                  http3: false,
                  nativeCallback: direct,
                );
          addTearDown(() async {
            if (!release.isCompleted) release.complete();
            await server.close(force: true);
          });
          server.listen((request) async {
            if (request.uri.path == '/slow') {
              entered.complete();
              await release.future;
              try {
                request.response.write('late');
                await request.response.close();
              } catch (_) {
                // The peer has reset this stream; its response can be rejected.
              } finally {
                handlerDone.complete();
              }
            } else {
              request.response.write(request.uri.path);
              await request.response.close();
            }
          });
          final Socket socket = tls
              ? await SecureSocket.connect(
                  '127.0.0.1',
                  server.port,
                  supportedProtocols: ['h2'],
                  onBadCertificate: (_) => true,
                )
              : await Socket.connect('127.0.0.1', server.port);
          final client = _Client(socket);
          addTearDown(client.close);
          final slow = client.get(1, '/slow');
          await entered.future.timeout(const Duration(seconds: 3));
          expect(await client.get(3, '/fast'), '/fast');
          client.send(6, 0, 0, List<int>.filled(8, 42));
          await client.pong.future.timeout(const Duration(seconds: 3));
          client.cancel(1);
          expect(await slow, 'cancelled');
          expect(await client.get(5, '/after-reset'), '/after-reset');
          release.complete();
          await handlerDone.future.timeout(const Duration(seconds: 3));
          expect(
            await client.get(7, '/after-late-response'),
            '/after-late-response',
          );
        },
      );
    }
  }
}
