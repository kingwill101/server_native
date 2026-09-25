# Zig ABI

`NativeProxyServer` uses the sole Zig asset `src/zig_ffi.g.dart`. Exported proxy
symbols retain their `server_native_zig_` prefix. The public Dart API is unchanged.

`include/server_native_abi.h` is the configuration layout source. Generate its
Dart struct with `dart run tool/generate_ffi.dart`; generate exported Zig function
bindings with `python3 tool/generate_zig_bindings.py`.

The legacy configuration field order remains stable. The callback slot is
reserved for ABI layout compatibility; runtime notifications use Dart API-DL
ports and queued FFI payloads. Keep native and Dart layout tests in sync when
changing this header.

`server_native_zig_close_http` stops the HTTP listener and ordinary connections
while preserving detached tunnels. Final stop releases the runtime and queues.
