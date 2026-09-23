import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:server_native/src/zig_ffi.g.dart';
import 'package:test/test.dart';

void main() {
  group('Zig Dart API-DL bridge', () {
    setUpAll(() {
      expect(
        server_native_dart_api_initialize(ffi.NativeApi.initializeApiDLData),
        0,
      );
    });

    test('exports the expected ABI version', () {
      expect(server_native_abi_version(), 1);
    });

    test('posts a native integer to a Dart ReceivePort', () async {
      final port = ReceivePort();
      addTearDown(port.close);

      expect(
        server_native_dart_post_integer(port.sendPort.nativePort, 42),
        isTrue,
      );
      await expectLater(
        port.first.timeout(const Duration(seconds: 2)),
        completion(42),
      );
    });
  });
}
