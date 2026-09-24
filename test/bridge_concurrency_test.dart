import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:server_native/server_native.dart';
import 'package:test/test.dart';

Future<void> _exerciseListeners(int worker, bool native) async {
  final servers = <HttpServer>[];
  final client = HttpClient();
  try {
    await Future.wait([
      for (var index = 0; index < 8; index++)
        () async {
          final server = native
              ? await NativeHttpServer.bind(
                  InternetAddress.loopbackIPv4,
                  0,
                  nativeCallback: false,
                )
              : await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          servers.add(server);
          server.listen((request) async {
            request.response.write('$worker:${server.port}');
            await request.response.close();
          });
        }(),
    ]);
    Future<void> check(HttpServer server) async {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/'),
      );
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok ||
          body != '$worker:${server.port}') {
        throw StateError('Listener ${server.port} delivered $body');
      }
    }

    await Future.wait(servers.map(check));
    final closing = servers.take(4).toList();
    servers.removeRange(0, 4);
    await Future.wait(closing.map((server) => server.close(force: true)));
    // Closing one bridge must not unlink another listener's backend socket.
    for (var round = 0; round < 3; round++) {
      await Future.wait(servers.map(check));
    }
  } finally {
    client.close(force: true);
    await Future.wait(servers.map((server) => server.close(force: true)));
  }
}

void main() {
  for (final native in [false, true]) {
    test(
      'concurrent isolate listeners remain independent native=$native',
      () async {
        await Future.wait([
          for (var worker = 0; worker < 4; worker++)
            Isolate.run(() => _exerciseListeners(worker, native)),
        ]);
      },
    );
  }
}
