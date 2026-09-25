import 'dart:typed_data';

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

/// One direct request frame polled from the native transport queue.
final class NativeDirectRequestFrame {
  const NativeDirectRequestFrame({
    required this.requestId,
    required this.payload,
  });

  /// Correlation id used when pushing response frames back to the transport.
  final int requestId;

  /// Encoded bridge payload bytes.
  final Uint8List payload;
}
