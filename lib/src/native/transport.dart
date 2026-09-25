import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'transport_config.dart';
import 'transport_types.dart';

export 'transport_types.dart';

/// Selection is separate from the lifetime of any running server.
abstract interface class NativeTransportBackend {
  int get abiVersion;
  NativeTransport start(NativeTransportConfig config);
}

/// Shared ownership and frame-copying contract. Backend adapters own native
/// lifecycle, notification, flow control, and their matching payload deallocator.
abstract base class NativeTransport {
  NativeTransport(this.handle, this.port);
  final ffi.Pointer<ffi.Void> handle;
  final int port;
  bool closed = false;

  Future<void> closeHttp();
  void close();
  Future<void> closeAsync({bool force = false});
  Future<void> waitForDirectRequestFrame();
  void consumeDirectRequestBytes(int requestId, int count);

  int pushFrame(int requestId, ffi.Pointer<ffi.Uint8> payload, int length);
  int pollFrame(
    int timeoutMs,
    ffi.Pointer<ffi.Uint64> requestId,
    ffi.Pointer<ffi.Pointer<ffi.Uint8>> payload,
    ffi.Pointer<ffi.Uint64> length,
  );
  void freePayload(ffi.Pointer<ffi.Uint8> payload, int length);

  bool pushDirectResponseFrame(int requestId, Uint8List payload) {
    if (closed) return false;
    return using((arena) {
      final pointer = arena<ffi.Uint8>(payload.length);
      pointer.asTypedList(payload.length).setAll(0, payload);
      return pushFrame(requestId, pointer, payload.length) != 0;
    });
  }

  Future<bool> pushDirectResponseFrameAsync(
    int requestId,
    Uint8List payload,
  ) async => pushDirectResponseFrame(requestId, payload);

  NativeDirectRequestFrame? pollDirectRequestFrame({int timeoutMs = 50}) {
    if (closed) return null;
    if (timeoutMs < 0) {
      throw ArgumentError.value(
        timeoutMs,
        'timeoutMs',
        'timeoutMs must be >= 0',
      );
    }
    return using((arena) {
      final requestId = arena<ffi.Uint64>();
      final payload = arena<ffi.Pointer<ffi.Uint8>>();
      final length = arena<ffi.Uint64>();
      if (pollFrame(timeoutMs, requestId, payload, length) == 0) return null;
      final pointer = payload.value;
      final size = length.value;
      try {
        return NativeDirectRequestFrame(
          requestId: requestId.value,
          payload: pointer == ffi.nullptr || size == 0
              ? Uint8List(0)
              : Uint8List.fromList(pointer.asTypedList(size)),
        );
      } finally {
        if (pointer != ffi.nullptr) freePayload(pointer, size);
      }
    });
  }
}
