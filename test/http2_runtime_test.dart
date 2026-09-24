import 'dart:convert';
import 'dart:io';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

// Set H2SPEC to the h2spec executable to run the external conformance gate.
void main() {
  final h2spec = Platform.environment['H2SPEC'];
  for (final tls in [false, true]) {
    for (final direct in [false, true]) {
      test(
        'HTTP/2 runtime tls=$tls direct=$direct',
        () async {
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
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final body = await request.fold<int>(
              0,
              (n, bytes) => n + bytes.length,
            );
            if (request.method != 'HEAD') {
              request.response.write(
                request.uri.path == '/echo'
                    ? '${request.uri.path}|${request.uri.query}|$body'
                    : 'h2 works!',
              );
            }
            await request.response.close();
          });
          final result = await Process.run(h2spec!, [
            '-p',
            '${server.port}',
            if (tls) ...['-t', '-k'],
          ]).timeout(const Duration(seconds: 60));
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(result.stdout, contains('0 failed'));
          final curl = await Process.start('curl', [
            '-ksS',
            '--max-time',
            '10',
            tls ? '--http2' : '--http2-prior-knowledge',
            '--data-binary',
            '@-',
            '-w',
            '|%{http_version}',
            '${tls ? 'https' : 'http'}://127.0.0.1:${server.port}/echo?q=hello',
          ]);
          final output = utf8.decodeStream(curl.stdout);
          final errors = utf8.decodeStream(curl.stderr);
          curl.stdin.add(List<int>.filled(131072, 120));
          await curl.stdin.close();
          expect(await curl.exitCode, 0, reason: await errors);
          expect(await output, '/echo|q=hello|131072|2');
        },
        skip: h2spec == null
            ? 'Set H2SPEC to run HTTP/2 interoperability tests'
            : false,
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }
}
