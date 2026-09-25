import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'proxy_config.g.dart' as abi;
import 'transport_types.dart';

/// Backend-neutral startup options. Validation happens before native allocation.
final class NativeTransportConfig {
  NativeTransportConfig({
    required this.host,
    required this.port,
    required this.backendHost,
    required this.backendPort,
    this.backendKind = bridgeBackendKindTcp,
    this.backendPath,
    this.backlog = 0,
    this.v6Only = false,
    this.shared = false,
    this.requestClientCertificate = false,
    this.enableHttp2 = true,
    this.enableHttp3 = false,
    this.tlsCertPath,
    this.tlsKeyPath,
    this.tlsCertPassword,
    this.benchmarkMode = benchmarkModeNone,
    this.directRequestCallback,
  }) {
    if (backendKind < 0 || backendKind > 255) {
      throw ArgumentError.value(
        backendKind,
        'backendKind',
        'backendKind must be between 0 and 255',
      );
    }
    if (backendKind == bridgeBackendKindUnix &&
        (backendPath?.isEmpty ?? true)) {
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
  }

  final String host;
  final int port;
  final String backendHost;
  final int backendPort;
  final int backendKind;
  final String? backendPath;
  final int backlog;
  final bool v6Only;
  final bool shared;
  final bool requestClientCertificate;
  final bool enableHttp2;
  final bool enableHttp3;
  final String? tlsCertPath;
  final String? tlsKeyPath;
  final String? tlsCertPassword;
  final int benchmarkMode;
  final NativeDirectRequestCallback? directRequestCallback;

  /// Config strings are borrowed only for the duration of [start].
  /// Each native implementation copies any data it retains.
  (ffi.Pointer<ffi.Void>, int) startNative(
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<abi.ServerNativeProxyConfig>,
      ffi.Pointer<ffi.Uint16>,
    )
    start, {
    String? effectiveBackendHost,
    int? effectiveBackendPort,
    ffi.Pointer<ffi.Void>? callback,
  }) => using((arena) {
    final config = arena<abi.ServerNativeProxyConfig>();
    final outPort = arena<ffi.Uint16>();
    ffi.Pointer<ffi.Char> string(String? value) => value == null
        ? ffi.nullptr
        : value.toNativeUtf8(allocator: arena).cast();
    config.ref
      ..host = string(host)
      ..port = port
      ..backend_host = string(effectiveBackendHost ?? backendHost)
      ..backend_port = effectiveBackendPort ?? backendPort
      ..backend_kind = backendKind
      ..backend_path = string(backendPath)
      ..backlog = backlog
      ..v6_only = v6Only ? 1 : 0
      ..shared = shared ? 1 : 0
      ..request_client_certificate = requestClientCertificate ? 1 : 0
      ..http2 = enableHttp2 ? 1 : 0
      ..http3 = enableHttp3 ? 1 : 0
      ..tls_cert_path = string(tlsCertPath)
      ..tls_key_path = string(tlsKeyPath)
      ..tls_cert_password = string(tlsCertPassword)
      ..benchmark_mode = benchmarkMode
      ..direct_request_callback = callback ?? ffi.nullptr;
    final handle = start(config, outPort);
    if (handle == ffi.nullptr) {
      throw StateError(
        'Failed to start server_native proxy server for $host:$port',
      );
    }
    return (handle, outPort.value);
  });
}
