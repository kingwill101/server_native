import 'dart:ffi' as ffi;
import 'dart:io';

import 'transport.dart';
import 'zig_transport.dart';

/// Zig is the sole native implementation. Old backend selectors have no effect.
NativeTransportBackend selectedTransportBackend() {
  if (!Platform.isLinux ||
      (ffi.Abi.current() != ffi.Abi.linuxX64 &&
          ffi.Abi.current() != ffi.Abi.linuxArm64)) {
    throw UnsupportedError(
      'server_native currently supports Linux x64 and ARM64 only.',
    );
  }
  return const ZigTransportBackend();
}
