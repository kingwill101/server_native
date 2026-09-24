import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;
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

    test('exports the current Zig transport version', () {
      expect(server_native_transport_version(), 1);
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

    test('queues copied payloads and posts them through Dart API-DL', () async {
      final queue = server_native_zig_queue_create(2);
      expect(queue, isNot(ffi.nullptr));
      addTearDown(() => server_native_zig_queue_destroy(queue));

      final payload = pkg_ffi.calloc<ffi.Uint8>(3);
      addTearDown(() => pkg_ffi.calloc.free(payload));
      payload
        ..[0] = 1
        ..[1] = 2
        ..[2] = 3;

      expect(server_native_zig_queue_push(queue, 77, payload, 3), isTrue);
      payload[0] = 9;
      expect(server_native_zig_queue_length(queue), 1);

      final port = ReceivePort();
      addTearDown(port.close);
      expect(
        server_native_zig_queue_post_next(queue, port.sendPort.nativePort),
        isTrue,
      );

      final message = await port.first.timeout(const Duration(seconds: 2));
      expect(message, isA<List<Object?>>());
      final values = message as List<Object?>;
      expect(values[0], 77);
      expect(values[1], Uint8List.fromList(const [1, 2, 3]));
      expect(server_native_zig_queue_length(queue), 0);
      expect(
        server_native_zig_queue_post_next(queue, port.sendPort.nativePort),
        isFalse,
      );
    });

    test('rejects invalid queue capacities', () {
      expect(server_native_zig_queue_create(0), ffi.nullptr);
      expect(server_native_zig_queue_create(257), ffi.nullptr);
    });
  });
}
