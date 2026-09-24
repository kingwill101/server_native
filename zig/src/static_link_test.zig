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

extern fn server_native_zig_queue_create(usize) ?*anyopaque;
extern fn server_native_zig_queue_destroy(?*anyopaque) void;
extern fn server_native_zig_queue_push(*anyopaque, i64, [*]const u8, usize) bool;
extern fn server_native_zig_queue_length(*anyopaque) usize;
extern fn server_native_zig_queue_post_next(*anyopaque, i64) bool;

test "static asset queue ABI owns data and links API-DL symbols without a Dart VM" {
    try std.testing.expect(server_native_zig_queue_create(0) == null);
    const queue = server_native_zig_queue_create(1) orelse return error.OutOfMemory;
    defer server_native_zig_queue_destroy(queue);
    try std.testing.expect(server_native_zig_queue_push(queue, -1, "binary\x00", 7));
    try std.testing.expect(!server_native_zig_queue_push(queue, 2, "full", 4));
    try std.testing.expectEqual(@as(usize, 1), server_native_zig_queue_length(queue));
    // API-DL has not been initialized: posting fails safely and frees the event.
    try std.testing.expect(!server_native_zig_queue_post_next(queue, 1));
    try std.testing.expectEqual(@as(usize, 0), server_native_zig_queue_length(queue));
}
