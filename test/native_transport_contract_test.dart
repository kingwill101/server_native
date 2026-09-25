import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:server_native/src/native/transport.dart';
import 'package:server_native/src/native/transport_config.dart';
import 'package:test/test.dart';

// Exercise the shared ownership contract without invoking either native asset.
final class _Transport extends NativeTransport {
  _Transport() : super(ffi.nullptr, 8123);
  Uint8List? queued;
  List<int>? submitted;
  int? submittedId;
  int calls = 0;
  int frees = 0;
  int pushResult = 1;

  @override
  int pushFrame(int id, ffi.Pointer<ffi.Uint8> payload, int length) {
    calls++;
    submittedId = id;
    submitted = payload.asTypedList(length).toList();
    return pushResult;
  }

  @override
  int pollFrame(
    int timeout,
    ffi.Pointer<ffi.Uint64> id,
    ffi.Pointer<ffi.Pointer<ffi.Uint8>> payload,
    ffi.Pointer<ffi.Uint64> length,
  ) {
    calls++;
    final bytes = queued;
    if (bytes == null) return 0;
    queued = null;
    id.value = 42;
    length.value = bytes.length;
    // Even an empty frame can carry an owned, non-null allocation.
    payload.value = calloc<ffi.Uint8>(bytes.isEmpty ? 1 : bytes.length);
    payload.value.asTypedList(bytes.length).setAll(0, bytes);
    return 1;
  }

  @override
  void freePayload(ffi.Pointer<ffi.Uint8> payload, int length) {
    frees++;
    // Poison before freeing: the Dart result must own a separate copy.
    payload.asTypedList(length).fillRange(0, length, 0xff);
    calloc.free(payload);
  }

  @override
  Future<void> closeHttp() async {}

  @override
  void close() => closed = true;
  @override
  Future<void> closeAsync({bool force = false}) async => close();
  @override
  Future<void> waitForDirectRequestFrame() async {}
  @override
  void consumeDirectRequestBytes(int requestId, int count) {}
}

void main() {
  test('polled bytes survive the matching backend deallocator', () {
    final transport = _Transport()..queued = Uint8List.fromList([0, 128, 255]);
    final frame = transport.pollDirectRequestFrame(timeoutMs: 0)!;
    expect(frame.requestId, 42);
    expect(frame.payload, [0, 128, 255]);
    expect(transport.frees, 1);
    expect(transport.pollDirectRequestFrame(timeoutMs: 0), isNull);
    expect(transport.frees, 1);
  });

  test('empty frames release a non-null owned allocation', () {
    final transport = _Transport()..queued = Uint8List(0);
    expect(transport.pollDirectRequestFrame()!.payload, isEmpty);
    expect(transport.frees, 1);
  });

  test('invalid polling timeout never enters a backend', () {
    final transport = _Transport();
    expect(
      () => transport.pollDirectRequestFrame(timeoutMs: -1),
      throwsArgumentError,
    );
    expect(transport.calls, 0);
  });

  test('push preserves bytes and id and reports backend rejection', () async {
    final transport = _Transport();
    final payload = Uint8List.fromList([0, 255, 3]);
    expect(transport.pushDirectResponseFrame(99, payload), isTrue);
    expect(transport.submittedId, 99);
    expect(transport.submitted, payload);
    transport.pushResult = 0;
    expect(
      await transport.pushDirectResponseFrameAsync(100, Uint8List(0)),
      isFalse,
    );
    expect(transport.submitted, isEmpty);
  });

  test('closed transports never push or poll a freed handle', () async {
    final transport = _Transport();
    await transport.closeAsync();
    transport.close();
    expect(transport.pushDirectResponseFrame(1, Uint8List(1)), isFalse);
    expect(
      await transport.pushDirectResponseFrameAsync(1, Uint8List(1)),
      isFalse,
    );
    expect(transport.pollDirectRequestFrame(), isNull);
    expect(transport.calls, 0);
  });

  test('startup configuration preserves pre-FFI validation', () {
    NativeTransportConfig config({
      int kind = 0,
      String? path,
      int backlog = 0,
      int benchmark = 0,
    }) => NativeTransportConfig(
      host: '127.0.0.1',
      port: 0,
      backendHost: '',
      backendPort: 0,
      backendKind: kind,
      backendPath: path,
      backlog: backlog,
      benchmarkMode: benchmark,
    );
    for (final value in [-1, 256]) {
      expect(() => config(kind: value), throwsArgumentError);
      expect(() => config(benchmark: value), throwsArgumentError);
    }
    for (final value in [-1, 0x100000000]) {
      expect(() => config(backlog: value), throwsArgumentError);
    }
    expect(() => config(kind: bridgeBackendKindUnix), throwsArgumentError);
    expect(
      () => config(kind: bridgeBackendKindUnix, path: ''),
      throwsArgumentError,
    );
    expect(
      config(kind: bridgeBackendKindUnix, path: '/tmp/bridge').backendPath,
      '/tmp/bridge',
    );
  });
}
