import 'dart:typed_data';

import 'backend_selection.dart';
import 'transport.dart';
import 'transport_config.dart';

export 'transport.dart'
    show
        bridgeBackendKindTcp,
        bridgeBackendKindUnix,
        benchmarkModeNone,
        benchmarkModeStaticNativeDirect,
        benchmarkModeStaticServerNativeDirectShape,
        benchmarkModeStaticRoutedFfiDirectShape,
        NativeDirectRequestCallback,
        NativeDirectRequestFrame;

/// Returns the ABI version for the selected native transport asset.
int transportAbiVersion() => selectedTransportBackend().abiVersion;

/// Backend-independent handle to a running native proxy server.
final class NativeProxyServer {
  NativeProxyServer._(this._transport);
  final NativeTransport _transport;
  int get port => _transport.port;
  bool get isClosed => _transport.closed;

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
    final config = NativeTransportConfig(
      host: host,
      port: port,
      backendHost: backendHost,
      backendPort: backendPort,
      backendKind: backendKind,
      backendPath: backendPath,
      backlog: backlog,
      v6Only: v6Only,
      shared: shared,
      requestClientCertificate: requestClientCertificate,
      enableHttp2: enableHttp2,
      enableHttp3: enableHttp3,
      tlsCertPath: tlsCertPath,
      tlsKeyPath: tlsKeyPath,
      tlsCertPassword: tlsCertPassword,
      benchmarkMode: benchmarkMode,
      directRequestCallback: directRequestCallback,
    );
    return NativeProxyServer._(selectedTransportBackend().start(config));
  }

  void close() => _transport.close();
  Future<void> closeHttp() => _transport.closeHttp();

  Future<void> closeAsync({bool force = false}) =>
      _transport.closeAsync(force: force);
  Future<void> waitForDirectRequestFrame() =>
      _transport.waitForDirectRequestFrame();
  bool pushDirectResponseFrame(int requestId, Uint8List payload) =>
      _transport.pushDirectResponseFrame(requestId, payload);
  Future<bool> pushDirectResponseFrameAsync(int requestId, Uint8List payload) =>
      _transport.pushDirectResponseFrameAsync(requestId, payload);
  void consumeDirectRequestBytes(int requestId, int count) =>
      _transport.consumeDirectRequestBytes(requestId, count);
  bool completeDirectRequest(int requestId, Uint8List payload) =>
      pushDirectResponseFrame(requestId, payload);
  NativeDirectRequestFrame? pollDirectRequestFrame({int timeoutMs = 50}) =>
      _transport.pollDirectRequestFrame(timeoutMs: timeoutMs);
}
