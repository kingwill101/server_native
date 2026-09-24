import 'dart:async';
import 'dart:io';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

// Run separately from other test files: descriptor counts are process-wide.
void main() {
  final python = Platform.environment['AIOQUIC_PYTHON'];
  final rounds = int.parse(Platform.environment['HTTP3_STRESS_ROUNDS'] ?? '16');
  for (final direct in [false, true]) {
    test(
      'HTTP/3 repeated startup/traffic/reset/close direct=$direct',
      () async {
        Future<void> cycle() async {
          final server = await NativeHttpServer.bindSecure(
            '127.0.0.1',
            0,
            certificatePath: 'zig/src/testdata/tls-cert.pem',
            keyPath: 'zig/src/testdata/tls-key.pem',
            nativeCallback: direct,
            http3: true,
          );
          server.listen((request) async {
            try {
              await request.response.addStream(request);
              await request.response.close();
            } on SocketException {
              // Deliberate cancellation while the upload is incomplete.
            } on HttpException {
              // Deliberate cancellation while the upload is incomplete.
            }
          });
          try {
            final result = await Process.run(python!, [
              'tool/http3_aioquic_client.py',
              '${server.port}',
              'lifecycle-stress',
            ]).timeout(const Duration(seconds: 15));
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout}\n${result.stderr}',
            );
          } finally {
            await server.close(force: true);
          }
          final rebound = await RawDatagramSocket.bind(
            '127.0.0.1',
            server.port,
          );
          rebound.close();
        }

        // Warm up lazy native/Dart process resources before comparing descriptors.
        await cycle();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final descriptors = Directory('/proc/self/fd');
        final before = descriptors.listSync().length;
        for (var round = 0; round < rounds; round++) {
          await cycle();
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final after = descriptors.listSync().length;
        expect(
          after,
          lessThanOrEqualTo(before + 2),
          reason:
              'file descriptors grew across $rounds closed listeners: $before -> $after',
        );
      },
      skip: !Platform.isLinux || python == null
          ? 'Requires Linux descriptor accounting and AIOQUIC_PYTHON'
          : false,
      timeout: Timeout(Duration(seconds: 30 + rounds * 15)),
    );
  }
}
