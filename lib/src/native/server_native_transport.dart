import 'dart:async';
import 'dart:isolate';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:server_native/src/ffi.g.dart' as rust_ffi;
import 'package:server_native/src/zig_ffi.g.dart' as zig_ffi;

const int bridgeBackendKindTcp = 0;
const int bridgeBackendKindUnix = 1;
const int benchmarkModeNone = 0;
const int benchmarkModeStaticNativeDirect = 1;
const int benchmarkModeStaticServerNativeDirectShape = 2;

@Deprecated('Use benchmarkModeStaticServerNativeDirectShape')
const int benchmarkModeStaticRoutedFfiDirectShape =
    benchmarkModeStaticServerNativeDirectShape;

typedef NativeDirectRequestCallback = void Function(
  int requestId,
  Uint8List payload,
);

typedef _NativeDirectRequestCallbackC = ffi.Void Function(
  ffi.Uint64 requestId,
  ffi.Pointer<ffi.Uint8> payload,
  ffi.Uint64 payloadLen,
);

final Set<ffi.NativeCallable<_NativeDirectRequestCallbackC>>
_retainedDirectRequestCallbacks =
    <ffi.NativeCallable<_NativeDirectRequestCallbackC>>{};

/// One direct request frame polled from the Rust transport queue.
final class NativeDirectRequestFrame {
  const NativeDirectRequestFrame({
    required this.requestId,
    required this.payload,
  });

  /// Correlation id used when pushing response frames back to Rust.
  final int requestId;

  /// Encoded bridge payload bytes.
  final Uint8List payload;
}

const _compileTimeBackend = String.fromEnvironment(
  'server_native.backend',
  defaultValue: 'rust',
);

bool _zigApiInitialized = false;

String _configuredBackend() {
  final runtime = Platform.environment['SERVER_NATIVE_BACKEND'];
  final value = (runtime == null || runtime.trim().isEmpty)
      ? _compileTimeBackend
      : runtime;
  final normalized = value.trim().toLowerCase();
  if (normalized == 'rust' || normalized == 'zig') {
    return normalized;
  }
  throw StateError(
    'Invalid SERVER_NATIVE_BACKEND/server_native.backend value "$value"; '
    'expected "rust" or "zig".',
  );
}

bool get _useZig => _configuredBackend() == 'zig';

void _ensureZigApiInitialized() {
  if (_zigApiInitialized) return;
  final result = zig_ffi.server_native_dart_api_initialize(
    ffi.NativeApi.initializeApiDLData,
  );
  if (result != 0) {
    throw StateError(
      'Failed to initialize the Zig Dart API-DL bridge: $result',
    );
  }
  _zigApiInitialized = true;
}

/// Returns the ABI version for the selected native transport asset.
int transportAbiVersion() => _useZig
    ? zig_ffi.server_native_zig_transport_version()
    : rust_ffi.server_native_transport_version();

/// Handle to a running native proxy transport server.

final class NativeProxyServer {
  NativeProxyServer._(
    this._handle,
    this.port, {
    required bool zigBackend,
    ffi.NativeCallable<_NativeDirectRequestCallbackC>? directRequestCallback,
  }) : _zigBackend = zigBackend,
       _directRequestCallback = directRequestCallback {
    if (_zigBackend) {
      final port = _eventPort = ReceivePort();
      port.listen((_) {
        if (!_requestReady.isCompleted) _requestReady.complete();
      });
      zig_ffi.server_native_zig_set_event_port(
        _handle,
        port.sendPort.nativePort,
      );
    }
  }

  ReceivePort? _eventPort;
  Completer<void> _requestReady = Completer<void>();

  /// Waits for a native queue notification without blocking the Dart isolate.
  /// Rust retains its polling fallback until its port ABI is available.
  Future<void> waitForDirectRequestFrame() async {
    if (_closed) return;
    if (!_zigBackend) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return;
    }
    final ready = _requestReady;
    await ready.future;
    if (identical(_requestReady, ready)) _requestReady = Completer<void>();
  }

  final ffi.Pointer<ffi.Void> _handle;
  final ffi.NativeCallable<_NativeDirectRequestCallbackC>?
  _directRequestCallback;
  final bool _zigBackend;

  /// Public port exposed by the Rust transport server.
  final int port;

  bool _closed = false;

  /// Returns whether this proxy handle has been closed.
  bool get isClosed => _closed;

  /// Starts a Rust proxy server that forwards requests to a local Dart backend.
  static NativeProxyServer start({
    required String host,
    required int port,
    required String backendHost,
    required int backendPort,
    int backendKind = bridgeBackendKindTcp,
    String? backendPath,
    int backlog = 0,
    bool v6Only = false,
    bool shared = false,
    bool requestClientCertificate = false,
    bool enableHttp2 = true,
    bool enableHttp3 = false,
    String? tlsCertPath,
    String? tlsKeyPath,
    String? tlsCertPassword,
    int benchmarkMode = benchmarkModeNone,
    NativeDirectRequestCallback? directRequestCallback,
  }) {
    if (backendKind < 0 || backendKind > 255) {
      throw ArgumentError.value(
        backendKind,
        'backendKind',
        'backendKind must be between 0 and 255',
      );
    }
    if (backendKind == bridgeBackendKindUnix &&
        (backendPath == null || backendPath.isEmpty)) {
      throw ArgumentError.value(
        backendPath,
        'backendPath',
        'backendPath is required when backendKind is Unix',
      );
    }
    if (benchmarkMode < 0 || benchmarkMode > 255) {
      throw ArgumentError.value(
        benchmarkMode,
        'benchmarkMode',
        'benchmarkMode must be between 0 and 255',
      );
    }
    if (backlog < 0) {
      throw ArgumentError.value(backlog, 'backlog', 'backlog must be >= 0');
    }
    if (backlog > 0xffffffff) {
      throw ArgumentError.value(
        backlog,
        'backlog',
        'backlog must be <= 4294967295',
      );
    }

    final useZig = _useZig;
    if (useZig) {
      _ensureZigApiInitialized();
      if (directRequestCallback != null) {
        throw UnsupportedError(
          'Zig backend uses the Dart API-DL queue and does not support '
          'NativeDirectRequestCallback yet.',
        );
      }
    }

    final configPtr = calloc<rust_ffi.ServerNativeProxyConfig>();
    final outPortPtr = calloc<ffi.Uint16>();
    final hostPtr = host.toNativeUtf8();
    // Rust's callback queue mode still validates a placeholder upstream;
    // Zig uses an empty endpoint to distinguish queue mode from bridge mode.
    final nativeBackendHost = !_useZig && backendHost.isEmpty
        ? InternetAddress.loopbackIPv4.address
        : backendHost;
    final nativeBackendPort = !_useZig && backendHost.isEmpty ? 9 : backendPort;
    final backendHostPtr = nativeBackendHost.toNativeUtf8();
    final backendPathPtr = backendPath?.toNativeUtf8();
    final tlsCertPathPtr = tlsCertPath?.toNativeUtf8();
    final tlsKeyPathPtr = tlsKeyPath?.toNativeUtf8();
    final tlsCertPasswordPtr = tlsCertPassword?.toNativeUtf8();
    ffi.NativeCallable<_NativeDirectRequestCallbackC>? nativeCallback;
    ffi.Pointer<ffi.NativeFunction<_NativeDirectRequestCallbackC>>
    nativeCallbackPtr = ffi.nullptr;
    if (directRequestCallback != null) {
      final callback = directRequestCallback;
      nativeCallback =
          ffi.NativeCallable<_NativeDirectRequestCallbackC>.listener((
            int requestId,
            ffi.Pointer<ffi.Uint8> payload,
            int payloadLen,
          ) {
            final payloadBytes = payloadLen == 0
                ? Uint8List(0)
                : Uint8List.fromList(payload.asTypedList(payloadLen));
            callback(requestId, payloadBytes);
          });
      nativeCallbackPtr = nativeCallback.nativeFunction;
    }

    try {
      configPtr.ref
        ..host = hostPtr.cast<ffi.Char>()
        ..port = port
        ..backend_host = backendHostPtr.cast<ffi.Char>()
        ..backend_port = nativeBackendPort
        ..backend_kind = backendKind
        ..backend_path = (backendPathPtr ?? ffi.nullptr).cast<ffi.Char>()
        ..backlog = backlog
        ..v6_only = v6Only ? 1 : 0
        ..shared = shared ? 1 : 0
        ..request_client_certificate = requestClientCertificate ? 1 : 0
        ..http2 = enableHttp2 ? 1 : 0
        ..http3 = enableHttp3 ? 1 : 0
        ..tls_cert_path = (tlsCertPathPtr ?? ffi.nullptr).cast<ffi.Char>()
        ..tls_key_path = (tlsKeyPathPtr ?? ffi.nullptr).cast<ffi.Char>()
        ..tls_cert_password = (tlsCertPasswordPtr ?? ffi.nullptr)
            .cast<ffi.Char>()
        ..benchmark_mode = benchmarkMode
        ..direct_request_callback = nativeCallbackPtr.cast<ffi.Void>();

      final ffi.Pointer<ffi.Void> handle = useZig
          ? zig_ffi.server_native_zig_start_proxy_server(
              configPtr.cast<ffi.Void>(),
              outPortPtr,
            )
          : rust_ffi
                .server_native_start_proxy_server(configPtr, outPortPtr)
                .cast<ffi.Void>();
      if (handle == ffi.nullptr) {
        nativeCallback?.close();
        throw StateError(
          'Failed to start server_native proxy server for $host:$port',
        );
      }

      if (nativeCallback != null) {
        _retainedDirectRequestCallbacks.add(nativeCallback);
      }

      return NativeProxyServer._(
        handle,
        outPortPtr.value,
        zigBackend: useZig,
        directRequestCallback: nativeCallback,
      );
    } finally {
      if (tlsCertPathPtr != null) {
        calloc.free(tlsCertPathPtr);
      }
      if (backendPathPtr != null) {
        calloc.free(backendPathPtr);
      }
      if (tlsKeyPathPtr != null) {
        calloc.free(tlsKeyPathPtr);
      }
      if (tlsCertPasswordPtr != null) {
        calloc.free(tlsCertPasswordPtr);
      }
      calloc.free(hostPtr);
      calloc.free(backendHostPtr);
      calloc.free(outPortPtr);
      calloc.free(configPtr);
    }
  }

  /// Stops the native proxy server.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_zigBackend) {
      zig_ffi.server_native_zig_set_event_port(_handle, 0);
      zig_ffi.server_native_zig_stop_proxy_server(_handle);
      _eventPort?.close();
      if (!_requestReady.isCompleted) _requestReady.complete();
    } else {
      rust_ffi.server_native_stop_proxy_server(
        _handle.cast<rust_ffi.ProxyServerHandle>(),
      );
    }
    if (_directRequestCallback != null) {
      // Intentionally retained after shutdown; see note below.
    }
    // Intentionally do not close the NativeCallable here.
    //
    // The Rust runtime can still race a late callback dispatch during teardown
    // (especially with upgraded/tunneled sockets). Closing the listener first
    // can crash the VM with "Callback invoked after it has been deleted".
    //
    // Keeping the callback alive for process lifetime avoids that teardown race
    // and makes shutdown safe.
  }

  bool pushDirectResponseFrame(int requestId, Uint8List responsePayload) {
    if (_closed) {
      return false;
    }
    final payloadPtr = calloc<ffi.Uint8>(responsePayload.length);
    try {
      payloadPtr.asTypedList(responsePayload.length).setAll(0, responsePayload);
      final result = _zigBackend
          ? zig_ffi.server_native_zig_push_direct_response_frame(
              _handle,
              requestId,
              payloadPtr,
              responsePayload.length,
            )
          : rust_ffi.server_native_push_direct_response_frame(
              _handle.cast<rust_ffi.ProxyServerHandle>(),
              requestId,
              payloadPtr,
              responsePayload.length,
            );
      return result != 0;
    } finally {
      calloc.free(payloadPtr);
    }
  }

  bool completeDirectRequest(int requestId, Uint8List responsePayload) {
    // Backward-compatible alias for one-shot response mode.
    return pushDirectResponseFrame(requestId, responsePayload);
  }

  /// Polls one queued direct request frame from Rust.
  ///
  /// Returns `null` on timeout/no frame.
  NativeDirectRequestFrame? pollDirectRequestFrame({int timeoutMs = 50}) {
    if (_closed) {
      return null;
    }
    if (timeoutMs < 0) {
      throw ArgumentError.value(
        timeoutMs,
        'timeoutMs',
        'timeoutMs must be >= 0',
      );
    }

    final requestIdPtr = calloc<ffi.Uint64>();
    final payloadPtrPtr = calloc<ffi.Pointer<ffi.Uint8>>();
    final payloadLenPtr = calloc<ffi.Uint64>();
    try {
      final ok = _zigBackend
          ? zig_ffi.server_native_zig_poll_direct_request_frame(
              _handle,
              timeoutMs,
              requestIdPtr,
              payloadPtrPtr,
              payloadLenPtr,
            )
          : rust_ffi.server_native_poll_direct_request_frame(
              _handle.cast<rust_ffi.ProxyServerHandle>(),
              timeoutMs,
              requestIdPtr,
              payloadPtrPtr,
              payloadLenPtr,
            );
      if (ok == 0) {
        return null;
      }

      final payloadPtr = payloadPtrPtr.value;
      final payloadLen = payloadLenPtr.value;
      if (payloadPtr == ffi.nullptr || payloadLen == 0) {
        return NativeDirectRequestFrame(
          requestId: requestIdPtr.value,
          payload: Uint8List(0),
        );
      }

      final payloadBytes = Uint8List.fromList(
        payloadPtr.asTypedList(payloadLen),
      );
      if (_zigBackend) {
        zig_ffi.server_native_zig_free_direct_request_payload(
          payloadPtr,
          payloadLen,
        );
      } else {
        rust_ffi.server_native_free_direct_request_payload(
          payloadPtr,
          payloadLen,
        );
      }
      return NativeDirectRequestFrame(
        requestId: requestIdPtr.value,
        payload: payloadBytes,
      );
    } finally {
      calloc.free(requestIdPtr);
      calloc.free(payloadPtrPtr);
      calloc.free(payloadLenPtr);
    }
  }
}
