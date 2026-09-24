import 'dart:io';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

import 'support/udp_binding_probe.dart';

void main() {
  final rounds = int.parse(Platform.environment['HTTP3_BIND_ROUNDS'] ?? '1');
  for (var round = 0; round < rounds; round++) {
    for (final direct in [false, true]) {
      for (final v6Only in [false, true]) {
        test(
          'HTTP/3 IPv6 v6Only=$v6Only direct=$direct round=$round',
          () async {
            final server = await NativeHttpServer.bindSecure(
              InternetAddress.anyIPv6,
              0,
              v6Only: v6Only,
              certificatePath: 'zig/src/testdata/tls-cert.pem',
              keyPath: 'zig/src/testdata/tls-key.pem',
              http3: true,
              nativeCallback: direct,
            );
            final binding = UdpBindingProbe.capture(server.port);
            server.listen((request) async {
              request.response.write('ipv6');
              await request.response.close();
            });
            try {
              for (final host in ['[::1]', if (!v6Only) '127.0.0.1']) {
                final response = await Process.run('curl', [
                  '--http3-only',
                  '--insecure',
                  '--silent',
                  '--show-error',
                  '--max-time',
                  '5',
                  '--noproxy',
                  '*',
                  'https://$host:${server.port}/',
                ]);
                expect(response.exitCode, 0, reason: '${response.stderr}');
                expect(response.stdout, 'ipv6');
              }
              if (v6Only) {
                // IPv6-only UDP must leave the IPv4 port available, just as TCP does.
                final ipv4 = await RawDatagramSocket.bind(
                  InternetAddress.anyIPv4,
                  server.port,
                  reuseAddress: false,
                );
                final ipv4Closed = ipv4.drain<void>();
                ipv4.close();
                await ipv4Closed;
              }
            } finally {
              await server.close(force: true);
            }
            final rebound = await binding.rebind(InternetAddress.anyIPv6);
            final closed = rebound.drain<void>();
            rebound.close();
            await closed;
          },
        );
      }
    }
  }
}
