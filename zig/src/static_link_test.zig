const std = @import("std");

extern fn server_native_zig_transport_version() c_int;
extern fn nghttp2_version(c_int) ?*const anyopaque;
extern fn ngtcp2_version(c_int) ?*const anyopaque;
extern fn nghttp3_version(c_int) ?*const anyopaque;
extern fn TLS_method() ?*const anyopaque;
extern fn SSL_CTX_new(?*const anyopaque) ?*anyopaque;
extern fn SSL_CTX_free(?*anyopaque) void;
extern fn ngtcp2_crypto_boringssl_configure_server_context(?*anyopaque) c_int;

// Link only the distributed archive and the C/C++ runtimes. This catches
// accidental omission of transitive archives from the static package asset.
test "static asset contains the runtime, protocols, and QUIC TLS adapter" {
    try std.testing.expectEqual(@as(c_int, 1), server_native_zig_transport_version());
    try std.testing.expect(nghttp2_version(0) != null);
    try std.testing.expect(ngtcp2_version(0) != null);
    try std.testing.expect(nghttp3_version(0) != null);
    const context = SSL_CTX_new(TLS_method()) orelse return error.TlsContextCreation;
    defer SSL_CTX_free(context);
    try std.testing.expectEqual(@as(c_int, 0), ngtcp2_crypto_boringssl_configure_server_context(context));
}
