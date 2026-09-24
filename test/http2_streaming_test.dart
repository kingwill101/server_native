import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http2/transport.dart';
import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

void main() {
  for (final tls in [false, true]) {
    for (final direct in [false, true]) {
      test('HTTP/2 progressive echo tls=$tls direct=$direct', () async {
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
        server.listen((request) async {
          request.response.bufferOutput = false;
          await for (final chunk in request) {
            request.response.add(chunk);
            await request.response.flush();
          }
          await request.response.close();
        });
        final Socket socket = tls
            ? await SecureSocket.connect(
                '127.0.0.1',
                server.port,
                onBadCertificate: (_) => true,
                supportedProtocols: ['h2'],
              )
            : await Socket.connect('127.0.0.1', server.port);
        final client = ClientTransportConnection.viaSocket(socket);
        final stream = client.makeRequest([
          Header.ascii(':method', 'POST'),
          Header.ascii(':path', '/echo'),
          Header.ascii(':scheme', tls ? 'https' : 'http'),
          Header.ascii(':authority', 'localhost'),
        ]);
        final incoming = StreamIterator(
          stream.incomingMessages
              .where((message) => message is DataStreamMessage)
              .cast<DataStreamMessage>(),
        );
        try {
          // Exceed the old whole-response cap without sending upload EOF.
          for (var index = 0; index < 80; index++) {
            final bytes = Uint8List(65536)..fillRange(0, 65536, index);
            stream.outgoingMessages.add(DataStreamMessage(bytes));
            var received = 0;
            while (received < bytes.length) {
              expect(
                await incoming.moveNext().timeout(const Duration(seconds: 3)),
                isTrue,
              );
              final chunk = incoming.current;
              expect(chunk.endStream, isFalse);
              expect(chunk.bytes, everyElement(index));
              received += chunk.bytes.length;
            }
            expect(received, bytes.length);
          }
          stream.outgoingMessages.add(
            DataStreamMessage(const [], endStream: true),
          );
          while (await incoming.moveNext().timeout(
            const Duration(seconds: 3),
          )) {
            expect(incoming.current.bytes, isEmpty);
          }
        } finally {
          await incoming.cancel();
          socket.destroy();
          await server.close(force: true);
        }
      }, timeout: const Timeout(Duration(seconds: 45)));
    }
  }
}
