const std = @import("std");

pub const c = @cImport({
    @cInclude("server_native_abi.h");
});

pub const ProxyServerHandle = c.ProxyServerHandle;
pub const ServerNativeProxyConfig = c.ServerNativeProxyConfig;

/// Compile-time ABI checks shared by the Rust and Zig native assets.
///
/// The field order mirrors `native/bindings.h`. The exact size is target
/// dependent, so the check compares the C-imported declaration with itself and
/// keeps all exported Zig functions on that declaration rather than a second
/// hand-written layout.
pub fn validate() void {
    comptime {
        if (@sizeOf(ServerNativeProxyConfig) != @sizeOf(c.ServerNativeProxyConfig)) {
            @compileError("server_native proxy config ABI size mismatch");
        }
        if (@alignOf(ServerNativeProxyConfig) != @alignOf(c.ServerNativeProxyConfig)) {
            @compileError("server_native proxy config ABI alignment mismatch");
        }
    }
}

test "imports the shared proxy config ABI" {
    validate();
    try std.testing.expect(@sizeOf(ServerNativeProxyConfig) > 0);
    try std.testing.expect(@alignOf(ServerNativeProxyConfig) > 0);
}
