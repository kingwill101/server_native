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

test "linked protocols reject unavailable ABI version requirements" {
    try std.testing.expect(c.nghttp2_version(std.math.maxInt(c_int)) == null);
    try std.testing.expect(c.ngtcp2_version(std.math.maxInt(c_int)) == null);
    try std.testing.expect(c.nghttp3_version(std.math.maxInt(c_int)) == null);
    try std.testing.expectEqual(c.NGHTTP2_VERSION_NUM, c.nghttp2_version(0).*.version_num);
    try std.testing.expectEqual(c.NGTCP2_VERSION_NUM, c.ngtcp2_version(0).*.version_num);
    try std.testing.expectEqual(c.NGHTTP3_VERSION_NUM, c.nghttp3_version(0).*.version_num);
}
