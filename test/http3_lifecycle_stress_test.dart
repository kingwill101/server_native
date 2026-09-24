import 'dart:async';
import 'dart:io';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

import 'support/udp_binding_probe.dart';

// Run separately from other test files: descriptor counts are process-wide.
void main() {
  final python = Platform.environment['AIOQUIC_PYTHON'];
  final rounds = int.parse(Platform.environment['HTTP3_STRESS_ROUNDS'] ?? '16');
  final maxRssGrowth =
      int.parse(
        Platform.environment['HTTP3_STRESS_MAX_RSS_GROWTH_MB'] ?? '32',
      ) *
      1024 *
      1024;
  if (rounds < 8) throw ArgumentError('HTTP3_STRESS_ROUNDS must be at least 8');
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
          final binding = UdpBindingProbe.capture(server.port);
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
          final rebound = await binding.rebind('127.0.0.1');
          final closed = rebound.drain<void>();
          rebound.close();
          await closed;
        }

        // Warm up lazy native/Dart process resources before comparing descriptors.
        for (var warmup = 0; warmup < 4; warmup++) {
          await cycle();
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final descriptors = Directory('/proc/self/fd');
        final before = descriptors.listSync().length;
        final rss = <int>[];
        for (var round = 0; round < rounds; round++) {
          await cycle();
          rss.add(ProcessInfo.currentRss);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final after = descriptors.listSync().length;
        // Compare low-water marks over windows, not arbitrary GC phases.
        // This is a regression envelope for this workload, not a universal RSS cap.
        final window = rounds < 16 ? 4 : 8;
        final initialRss = rss.take(window).reduce((a, b) => a < b ? a : b);
        final finalRss = rss
            .skip(rss.length - window)
            .reduce((a, b) => a < b ? a : b);
        final peakRss = rss.reduce((a, b) => a > b ? a : b);
        print(
          'HTTP/3 resource direct=$direct rounds=$rounds '
          'fds=$before->$after rss=$initialRss->$finalRss peak=$peakRss',
        );
        expect(
          finalRss - initialRss,
          lessThanOrEqualTo(maxRssGrowth),
          reason:
              'resident-memory low-water mark grew beyond the workload budget',
        );
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
