import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../zig_ffi.g.dart' as zig;
import 'transport.dart';
import 'transport_config.dart';

bool _apiInitialized = false;

final class ZigTransportBackend implements NativeTransportBackend {
  const ZigTransportBackend();

  @override
  int get abiVersion => zig.server_native_zig_transport_version();

  @override
  NativeTransport start(NativeTransportConfig config) {
    if (!_apiInitialized) {
      final result = zig.server_native_dart_api_initialize(
        ffi.NativeApi.initializeApiDLData,
      );
      if (result != 0) {
        throw StateError(
          'Failed to initialize the Zig Dart API-DL bridge: $result',
        );
      }
      _apiInitialized = true;
    }
    if (config.directRequestCallback != null) {
      throw UnsupportedError(
        'Zig backend uses the Dart API-DL queue and does not support '
        'NativeDirectRequestCallback yet.',
      );
    }
    final (handle, port) = config.startNative(
      (config, port) =>
          zig.server_native_zig_start_proxy_server(config.cast(), port),
    );
    return _ZigTransport(handle, port);
  }
}

final class _ZigTransport extends NativeTransport {
  _ZigTransport(super.handle, super.port) {
    _eventPort.listen((_) {
      if (!_requestReady.isCompleted) _requestReady.complete();
    });
    zig.server_native_zig_set_event_port(
      handle,
      _eventPort.sendPort.nativePort,
    );
  }

  final ReceivePort _eventPort = ReceivePort();
  Completer<void> _requestReady = Completer<void>();
  Future<void>? _closeFuture;

  @override
  Future<void> waitForDirectRequestFrame() async {
    if (closed) return;
    final ready = _requestReady;
    await ready.future;
    if (identical(_requestReady, ready)) _requestReady = Completer<void>();
  }

  @override
  Future<void> closeHttp() async {
    if (!closed) zig.server_native_zig_close_http(handle);
  }

  @override
  Future<void> closeAsync({bool force = false}) =>
      _closeFuture ??= _closeAsync(force: force);

  Future<void> _closeAsync({required bool force}) async {
    if (closed) return;
    if (!force) {
      zig.server_native_zig_begin_shutdown(handle);
      while (!zig.server_native_zig_shutdown_done(handle)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    closed = true;
    _detachPort();
    final address = handle.address;
    // Only the address crosses isolates. No Dart code accesses the handle after
    // this point; stop joins native threads before freeing native ownership.
    await Isolate.run(() => _stopProxy(address));
  }

  void _detachPort() {
    zig.server_native_zig_set_event_port(handle, 0);
    _eventPort.close();
    if (!_requestReady.isCompleted) _requestReady.complete();
  }

  @override
  void close() {
    if (closed || _closeFuture != null) return;
    closed = true;
    zig.server_native_zig_set_event_port(handle, 0);
    zig.server_native_zig_stop_proxy_server(handle);
    _eventPort.close();
    if (!_requestReady.isCompleted) _requestReady.complete();
  }

  @override
  Future<bool> pushDirectResponseFrameAsync(
    int requestId,
    Uint8List payload,
  ) async {
    if (closed) return false;
    final pointer = calloc<ffi.Uint8>(payload.length);
    try {
      pointer.asTypedList(payload.length).setAll(0, payload);
      while (!closed) {
        // Capture readiness before checking capacity to avoid a lost wakeup.
        final ready = _requestReady;
        final result = zig.server_native_zig_try_push_response(
          handle,
          requestId,
          pointer,
          payload.length,
        );
        if (result != 2) return result == 1;
        await ready.future;
        if (identical(_requestReady, ready)) _requestReady = Completer<void>();
      }
      return false;
    } finally {
      calloc.free(pointer);
    }
  }

  @override
  void consumeDirectRequestBytes(int requestId, int count) {
    if (!closed) {
      zig.server_native_zig_consume_request(handle, requestId, count);
    }
  }

  @override
  int pushFrame(int requestId, ffi.Pointer<ffi.Uint8> payload, int length) =>
      zig.server_native_zig_push_direct_response_frame(
        handle,
        requestId,
        payload,
        length,
      );

  @override
  int pollFrame(
    int timeoutMs,
    ffi.Pointer<ffi.Uint64> requestId,
    ffi.Pointer<ffi.Pointer<ffi.Uint8>> payload,
    ffi.Pointer<ffi.Uint64> length,
  ) => zig.server_native_zig_poll_direct_request_frame(
    handle,
    timeoutMs,
    requestId,
    payload,
    length,
  );

  @override
  void freePayload(ffi.Pointer<ffi.Uint8> payload, int length) =>
      zig.server_native_zig_free_direct_request_payload(payload, length);
}

void _stopProxy(int address) =>
    zig.server_native_zig_stop_proxy_server(ffi.Pointer.fromAddress(address));
