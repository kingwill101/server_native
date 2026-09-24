import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

void main() {
  for (final direct in [false, true]) {
    for (final mode in [
      'curl',
      'aioquic',
      'loss',
      'close-loss',
      'drain-replay',
    ]) {
      final independent = mode != 'curl';
      test(
        'HTTP/3 $mode runtime direct=$direct',
        () async {
          final server = await NativeHttpServer.bindSecure(
            '127.0.0.1',
            0,
            certificatePath: 'zig/src/testdata/tls-cert.pem',
            keyPath: 'zig/src/testdata/tls-key.pem',
            http3: true,
            nativeCallback: direct,
          );
          final entered = Completer<void>();
          final release = Completer<void>();
          server.listen((request) async {
            if (request.uri.path == '/advertise') {
              await request.response.close();
              return;
            }
            if (request.uri.path == '/slow') {
              entered.complete();
              await release.future;
            } else if (request.uri.path == '/barrier') {
              await entered.future;
              request.response.write('entered');
              await request.response.close();
              return;
            } else if (request.uri.path == '/release') {
              release.complete();
              request.response.write('released');
              await request.response.close();
              return;
            }
            expect(request.protocolVersion, contains('3'));
            final body = await utf8.decoder.bind(request).join();
            request.response.headers.set('x-protocol', 'h3');
            request.response.write(
              '${request.method} ${request.uri.path} ${request.uri.query} $body',
            );
            await request.response.close();
          });
          try {
            final noise = await RawDatagramSocket.bind('127.0.0.1', 0);
            for (final bytes in [
              <int>[],
              [0],
              List<int>.filled(1200, 255),
            ]) {
              noise.send(bytes, InternetAddress.loopbackIPv4, server.port);
            }
            noise.close();
            if (!independent) {
              for (final body in ['', 'hello', 'x' * (128 * 1024)]) {
                final process = await Process.start('curl', [
                  '--http3-only',
                  '--insecure',
                  '--silent',
                  '--show-error',
                  '--max-time',
                  '5',
                  '--noproxy',
                  '*',
                  '--data-binary',
                  '@-',
                  '--write-out',
                  '\n%{http_version}',
                  'https://127.0.0.1:${server.port}/echo?q=value',
                ]);
                final output = process.stdout.transform(utf8.decoder).join();
                final errors = process.stderr.transform(utf8.decoder).join();
                process.stdin.write(body);
                await process.stdin.close();
                expect(await process.exitCode, 0, reason: await errors);
                expect(await output, 'POST /echo q=value $body\n3');
              }
              for (final protocol in ['--http1.1', '--http2']) {
                final result = await Process.run('curl', [
                  protocol,
                  '--insecure',
                  '--silent',
                  '--show-error',
                  '--max-time',
                  '5',
                  '--noproxy',
                  '*',
                  '--dump-header',
                  '-',
                  'https://127.0.0.1:${server.port}/advertise',
                ]);
                expect(result.exitCode, 0, reason: '${result.stderr}');
                expect(
                  '${result.stdout}',
                  contains('alt-svc: h3=":${server.port}"'),
                );
              }
            }
            if (independent) {
              final python = Platform.environment['AIOQUIC_PYTHON']!;
              final result = await Process.run(python, [
                'tool/http3_aioquic_client.py',
                '${server.port}',
                mode,
              ]);
              expect(
                result.exitCode,
                0,
                reason: '${result.stdout}\n${result.stderr}',
              );
            }
          } finally {
            if (!release.isCompleted) release.complete();
            // A child must not inherit the native UDP descriptor and keep the
            // port alive after server shutdown.
            final child = await Process.start('sleep', ['10']);
            try {
              await server.close(force: true);
              final udp = await RawDatagramSocket.bind(
                '127.0.0.1',
                server.port,
              );
              udp.close();
            } finally {
              child.kill();
              await child.exitCode;
            }
          }
        },
        skip: independent && Platform.environment['AIOQUIC_PYTHON'] == null
            ? 'Set AIOQUIC_PYTHON to a Python environment with aioquic==1.3.0'
            : false,
        timeout: const Timeout(Duration(seconds: 90)),
      );
    }
  }
}
