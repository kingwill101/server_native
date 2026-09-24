import 'dart:convert';
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

    test('encodes request-start heads in Zig and posts wire bytes', () async {
      final queue = server_native_zig_queue_create(2);
      expect(queue, isNot(ffi.nullptr));
      addTearDown(() => server_native_zig_queue_destroy(queue));

      final descriptorBytes = _encodeRequestHeadDescriptor(
        method: 'GET',
        scheme: 'http',
        authority: 'example.com',
        path: '/hello',
        query: '',
        protocol: 'HTTP/1.1',
        headers: const <(String, String)>[
          ('host', 'example.com'),
          ('x-test', 'ok'),
        ],
      );
      final descriptor = pkg_ffi.calloc<ffi.Uint8>(descriptorBytes.length);
      addTearDown(() => pkg_ffi.calloc.free(descriptor));
      for (var i = 0; i < descriptorBytes.length; i++) {
        descriptor[i] = descriptorBytes[i];
      }

      expect(
        server_native_zig_queue_push_request_start(
          queue,
          91,
          descriptor,
          descriptorBytes.length,
        ),
        isTrue,
      );

      final port = ReceivePort();
      addTearDown(port.close);
      expect(
        server_native_zig_queue_post_next(queue, port.sendPort.nativePort),
        isTrue,
      );
      final message = await port.first.timeout(const Duration(seconds: 2));
      final values = message as List<Object?>;
      expect(values[0], 91);
      expect(
        values[1],
        Uint8List.fromList(_expectedTokenizedRequestStart()),
      );
    });

    test('rejects invalid queue capacities', () {
      expect(server_native_zig_queue_create(0), ffi.nullptr);
      expect(server_native_zig_queue_create(257), ffi.nullptr);
    });
  });
}

Uint8List _encodeRequestHeadDescriptor({
  required String method,
  required String scheme,
  required String authority,
  required String path,
  required String query,
  required String protocol,
  required List<(String, String)> headers,
}) {
  final builder = BytesBuilder(copy: false);
  for (final field in <String>[
    method,
    scheme,
    authority,
    path,
    query,
    protocol,
  ]) {
    _appendLengthPrefixedBytes(builder, utf8.encode(field));
  }
  _appendU32(builder, headers.length);
  for (final (name, value) in headers) {
    _appendLengthPrefixedBytes(builder, utf8.encode(name));
    _appendLengthPrefixedBytes(builder, utf8.encode(value));
  }
  return builder.takeBytes();
}

List<int> _expectedTokenizedRequestStart() => <int>[
  1,
  13,
  ..._field('GET'),
  ..._field('http'),
  ..._field('example.com'),
  ..._field('/hello'),
  ..._field(''),
  ..._field('HTTP/1.1'),
  ..._u32(2),
  ..._u16(0),
  ..._field('example.com'),
  ..._u16(0xffff),
  ..._field('x-test'),
  ..._field('ok'),
];

List<int> _field(String value) => _lengthPrefixedBytes(utf8.encode(value));

List<int> _lengthPrefixedBytes(List<int> value) => <int>[
  ..._u32(value.length),
  ...value,
];

void _appendLengthPrefixedBytes(BytesBuilder builder, List<int> value) {
  _appendU32(builder, value.length);
  builder.add(value);
}

void _appendU32(BytesBuilder builder, int value) {
  final bytes = ByteData(4)..setUint32(0, value, Endian.big);
  builder.add(bytes.buffer.asUint8List());
}

List<int> _u32(int value) {
  final bytes = ByteData(4)..setUint32(0, value, Endian.big);
  return bytes.buffer.asUint8List();
}

List<int> _u16(int value) => <int>[(value >> 8) & 0xff, value & 0xff];
