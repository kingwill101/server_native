import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

void main() {
  final python = Platform.environment['AIOQUIC_PYTHON'];
  for (final direct in [false, true]) {
    test(
      'HTTP/3 stalled producers preserve peer progress direct=$direct',
      () async {
        final server = await NativeHttpServer.bindSecure(
          '127.0.0.1',
          0,
          certificatePath: 'zig/src/testdata/tls-cert.pem',
          keyPath: 'zig/src/testdata/tls-key.pem',
          http3: true,
          nativeCallback: direct,
        );
        final release = Completer<void>();
        var produced = 0;
        Stream<List<int>> largeBody() async* {
          final chunk = Uint8List(16384);
          for (var i = 0; i < 2048; i++) {
            produced += chunk.length;
            yield chunk;
          }
        }

        server.listen((request) async {
          try {
            switch (request.uri.path) {
              case '/download':
                await request.response.addStream(largeBody());
              case '/progress':
                request.response.write('$produced');
              case '/upload':
                await release.future;
                await request.drain<void>();
                request.response.write('uploaded');
              case '/release':
                if (!release.isCompleted) release.complete();
                request.response.write('released');
              default:
                request.response.write('fast');
            }
            await request.response.close();
          } on SocketException {
            // The independent client deliberately resets the blocked download.
          } on HttpException {
            // Both dart:io and native adapters can report cancellation to writers.
          }
        });
        try {
          final result = await Process.run(python!, [
            'tool/http3_aioquic_client.py',
            '${server.port}',
            'pressure',
          ]).timeout(const Duration(seconds: 35));
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
        } finally {
          if (!release.isCompleted) release.complete();
          await server.close(force: true);
        }
      },
      skip: python == null ? 'Set AIOQUIC_PYTHON (aioquic==1.3.0)' : false,
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }
}
