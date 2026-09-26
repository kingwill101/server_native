import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

Future<HttpServer> bind(String mode, {bool secure = false}) async {
  const cert = 'zig/src/testdata/tls-cert.pem';
  const key = 'zig/src/testdata/tls-key.pem';
  if (mode == 'sdk') {
    if (!secure) return HttpServer.bind('127.0.0.1', 0);
    final context = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    return HttpServer.bindSecure('127.0.0.1', 0, context);
  }
  if (!secure) {
    return NativeHttpServer.bind(
      '127.0.0.1',
      0,
      http3: false,
      nativeCallback: mode == 'direct',
    );
  }
  return NativeHttpServer.bindSecure(
    '127.0.0.1',
    0,
    certificatePath: cert,
    keyPath: key,
    http3: false,
    nativeCallback: mode == 'direct',
  );
}

void main() {
  for (final mode in ['sdk', 'direct', 'bridge']) {
    for (final paused in [false, true]) {
      test(
        '$mode closes with ${paused ? "paused" : "no"} request listener',
        () async {
          final server = await bind(mode);
          final subscription = paused ? server.listen((_) {}) : null;
          subscription?.pause();
          try {
            await server.close().timeout(const Duration(seconds: 3));
            await server.close().timeout(const Duration(seconds: 3));
          } finally {
            await subscription?.cancel();
          }
        },
      );
    }
    for (final explicitLength in [false, true]) {
      test(
        '$mode streams response before producer completes (length=$explicitLength)',
        () async {
          final server = await bind(mode);
          addTearDown(() => server.close(force: true));
          final release = Completer<void>();
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          server.listen((request) async {
            request.response.bufferOutput = false;
            if (explicitLength) request.response.contentLength = 6;
            request.response.write('one');
            await request.response.flush();
            await release.future;
            request.response.write('two');
            await request.response.close();
          });
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/'),
          );
          final response = await request.close().timeout(
            const Duration(seconds: 3),
          );
          expect(response.headers.chunkedTransferEncoding, !explicitLength);
          final first = Completer<void>();
          final bytes = <int>[];
          final done = Completer<void>();
          response.listen(
            (chunk) {
              bytes.addAll(chunk);
              if (bytes.length >= 3 && !first.isCompleted) first.complete();
            },
            onDone: done.complete,
            onError: done.completeError,
          );
          await first.future.timeout(const Duration(seconds: 3));
          expect(latin1.decode(bytes), 'one');
          release.complete();
          await done.future.timeout(const Duration(seconds: 3));
          expect(latin1.decode(bytes), 'onetwo');
        },
      );
    }
    for (final body in <String?>[
      null,
      '0\r\n\r\n',
      '5\r\n\r\n0\r\n\r\n0;end=yes\r\n\r\n',
    ]) {
      test(
        '$mode pipelining after ${body == null
            ? "GET"
            : body.startsWith("0")
            ? "empty chunks"
            : "chunk data resembling terminator"}',
        () async {
          final server = await bind(mode);
          addTearDown(() => server.close(force: true));
          final observed = <String>[];
          server.listen((request) async {
            final data = await latin1.decoder.bind(request).join();
            observed.add('${request.uri.path}:$data');
            request.response.write('ok');
            await request.response.close();
          });
          final client = await Socket.connect('127.0.0.1', server.port);
          addTearDown(client.destroy);
          final response = latin1.decoder.bind(client).join();
          client.write(
            '${body == null ? "GET" : "POST"} /one HTTP/1.1\r\nHost: x\r\n'
            '${body == null ? "" : "Transfer-Encoding: chunked\r\n"}\r\n${body ?? ""}'
            'GET /two HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
          );
          final text = await response.timeout(const Duration(seconds: 4));
          expect(
            RegExp('HTTP/1.1 200').allMatches(text).length,
            2,
            reason: text,
          );
          expect(observed, [
            '/one:${body != null && body.startsWith("5") ? "\r\n0\r\n" : ""}',
            '/two:',
          ]);
        },
      );
    }
    test(
      '$mode stalled TLS handshake does not block another client or shutdown',
      () async {
        final server = await bind(mode, secure: true);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          request.response.write('ok');
          await request.response.close();
        });
        final stalled = await Socket.connect('127.0.0.1', server.port);
        addTearDown(stalled.destroy);
        final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
        addTearDown(() => client.close(force: true));
        final status = await (() async {
          final request = await client.getUrl(
            Uri.parse('https://127.0.0.1:${server.port}/'),
          );
          final response = await request.close();
          await response.drain<void>();
          return response.statusCode;
        })().timeout(const Duration(seconds: 3));
        expect(status, 200);
        await server.close(force: true).timeout(const Duration(seconds: 3));
      },
    );
  }
  test('Zig expires an unfinished TLS handshake', () async {
    final server = await bind('direct', secure: true);
    addTearDown(() => server.close(force: true));
    server.listen((request) async => request.response.close());
    final client = await Socket.connect('127.0.0.1', server.port);
    addTearDown(client.destroy);
    await client.drain<void>().timeout(const Duration(seconds: 8));
  });
}
