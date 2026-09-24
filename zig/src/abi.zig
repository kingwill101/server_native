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

test "proxy config preserves frozen C field offsets on 32 and 64 bit targets" {
    // These are the published ABI offsets, independent of the imported alias.
    const fields = .{ "host", "port", "backend_host", "backend_port", "backend_kind", "backend_path", "backlog", "v6_only", "shared", "request_client_certificate", "http2", "http3", "tls_cert_path", "tls_key_path", "tls_cert_password", "benchmark_mode", "direct_request_callback" };
    const offsets64 = [_]usize{ 0, 8, 16, 24, 26, 32, 40, 44, 45, 46, 47, 48, 56, 64, 72, 80, 88 };
    const offsets32 = [_]usize{ 0, 4, 8, 12, 14, 16, 20, 24, 25, 26, 27, 28, 32, 36, 40, 44, 48 };
    const wide = @sizeOf(usize) == 8;
    inline for (fields, 0..) |field, i| {
        try std.testing.expectEqual(if (wide) offsets64[i] else offsets32[i], @offsetOf(ServerNativeProxyConfig, field));
    }
    try std.testing.expectEqual(@as(usize, if (wide) 96 else 52), @sizeOf(ServerNativeProxyConfig));
    try std.testing.expectEqual(@alignOf(?*anyopaque), @alignOf(ServerNativeProxyConfig));
}
