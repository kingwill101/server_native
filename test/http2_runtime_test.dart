import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http2/transport.dart';
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

  test(
    'HTTP/2 runtime preserves concurrent progress after stream cancellation',
    () async {
      final server = await NativeHttpServer.bind(
        '127.0.0.1',
        0,
        http2: true,
        http3: false,
      );
      final pending = Completer<void>();
      final entered = Completer<void>();
      server.listen((request) async {
        if (request.uri.path == '/pending') {
          entered.complete();
          await pending.future;
        }
        request.response.write(request.uri.path);
        await request.response.close();
      });
      final socket = await Socket.connect('127.0.0.1', server.port);
      final client = ClientTransportConnection.viaSocket(socket);
      List<Header> headers(String path) => [
        Header.ascii(':method', 'GET'),
        Header.ascii(':path', path),
        Header.ascii(':scheme', 'http'),
        Header.ascii(':authority', '127.0.0.1:${server.port}'),
      ];
      Future<String> read(ClientTransportStream stream) async {
        final bytes = BytesBuilder();
        await for (final message in stream.incomingMessages) {
          if (message is DataStreamMessage) bytes.add(message.bytes);
        }
        return utf8.decode(bytes.takeBytes());
      }

      try {
        final pendingStream = client.makeRequest(
          headers('/pending'),
          endStream: true,
        );
        final pendingResponse = read(pendingStream);
        await entered.future.timeout(const Duration(seconds: 3));
        pendingStream.terminate();

        final fastResponse = read(
          client.makeRequest(headers('/fast'), endStream: true),
        );
        expect(await fastResponse.timeout(const Duration(seconds: 1)), '/fast');
        await pendingResponse.timeout(
          const Duration(seconds: 1),
          onTimeout: () => '',
        );
      } finally {
        pending.complete();
        await client.finish();
        await server.close(force: true);
      }
    },
  );
}
