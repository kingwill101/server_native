const std = @import("std");
const c = @cImport({
    @cInclude("nghttp2/nghttp2.h");
    @cInclude("ngtcp2/ngtcp2.h");
    @cInclude("nghttp3/nghttp3.h");
    @cInclude("openssl/ssl.h");
    @cInclude("ngtcp2/ngtcp2_crypto_boringssl.h");
});

test "linked protocol versions match their headers" {
    try std.testing.expectEqualStrings("1.70.0", std.mem.span(c.nghttp2_version(0).*.version_str));
    try std.testing.expectEqualStrings("1.25.0", std.mem.span(c.ngtcp2_version(0).*.version_str));
    try std.testing.expectEqualStrings("1.18.0", std.mem.span(c.nghttp3_version(0).*.version_str));
}

test "internal protocol adapters" {
    _ = @import("http2.zig");
    _ = @import("http3.zig");
}
