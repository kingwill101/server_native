// Run from an extracted package to verify its installed native code asset.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:server_native/server_native.dart';

Future<void> main() async {
  for (final direct in [true, false]) {
    final server = await NativeHttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      http3: false,
      nativeCallback: direct,
    );
    final client = HttpClient();
    server.listen((request) async {
      request.response.write('prebuilt-ok');
      await request.response.close();
    });
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/'),
      );
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != 200 || body != 'prebuilt-ok') {
        throw StateError(
          'Prebuilt response failed: ${response.statusCode} $body',
        );
      }
      stdout.writeln('Verified ${Abi.current()}: direct=$direct');
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  }
}
