import 'dart:async';
import 'dart:io';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

void main() {
  final python = Platform.environment['AIOQUIC_PYTHON'];
  for (final direct in [false, true]) {
    for (final loss in [false, true]) {
      test(
        'HTTP/3 graceful shutdown direct=$direct loss=$loss',
        () async {
          final server = await NativeHttpServer.bindSecure(
            '127.0.0.1',
            0,
            certificatePath: 'zig/src/testdata/tls-cert.pem',
            keyPath: 'zig/src/testdata/tls-key.pem',
            http3: true,
            nativeCallback: direct,
          );
          final stopped = Completer<void>();
          var ticks = 0;
          server.listen((request) async {
            await request.drain<void>();
            request.response.write('closing');
            await request.response.close();
            // Let the response reach the client before it blackholes the path.
            Timer(const Duration(milliseconds: 100), () async {
              final heartbeat = Timer.periodic(
                const Duration(milliseconds: 10),
                (_) => ticks++,
              );
              try {
                await server.close().timeout(const Duration(seconds: 3));
                stopped.complete();
              } catch (error, stack) {
                stopped.completeError(error, stack);
              } finally {
                heartbeat.cancel();
              }
            });
          });
          try {
            final client = Process.run(python!, [
              'tool/http3_aioquic_client.py',
              '${server.port}',
              loss ? 'shutdown-loss' : 'shutdown',
            ]);
            await stopped.future.timeout(const Duration(seconds: 10));
            expect(
              ticks,
              greaterThan(5),
              reason: 'Dart timers must run during native shutdown',
            );
            final result = await client.timeout(const Duration(seconds: 10));
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout}\n${result.stderr}',
            );
          } finally {
            await server.close(force: true);
          }
        },
        skip: python == null ? 'Set AIOQUIC_PYTHON (aioquic==1.3.0)' : false,
        timeout: const Timeout(Duration(seconds: 25)),
      );
    }
  }
}
