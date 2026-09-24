//! Internal HTTP/3 stream codec and QUIC/TLS setup. The caller owns UDP I/O,
//! ngtcp2 connection callbacks, clocks, retransmission, and flow-control credit.
const std = @import("std");
pub const c = @cImport({
    @cInclude("nghttp3/nghttp3.h");
    @cInclude("ngtcp2/ngtcp2.h");
    @cInclude("ngtcp2/ngtcp2_crypto_boringssl.h");
    @cInclude("openssl/ssl.h");
});
pub const Error = error{ NativeFailure, OutOfMemory, Closed, InvalidArgument, BufferTooSmall };

const max_stream_id: i64 = (1 << 62) - 1;

pub const Connection = struct {
    native: ?*c.nghttp3_conn,
    failed: bool = false,
    last_error: c_int = 0,

    /// Callback user data must remain valid until deinit. This value owns its
    /// connection and must not be copied. Callbacks use nghttp3's borrowed data.
    pub fn initServer(callbacks: *const c.nghttp3_callbacks, user_data: ?*anyopaque) Error!Connection {
        var settings: c.nghttp3_settings = undefined;
        c.nghttp3_settings_default(&settings);
        settings.max_field_section_size = 64 * 1024;
        var self: Connection = .{ .native = null };
        try self.check(c.nghttp3_conn_server_new(&self.native, callbacks, &settings, null, user_data));
        return self;
    }
    pub fn deinit(self: *Connection) void {
        if (self.native) |native| c.nghttp3_conn_del(native);
        self.native = null;
    }
    /// IDs must be server-initiated unidirectional streams opened by ngtcp2.
    pub fn bindStreams(self: *Connection, control: i64, encoder: i64, decoder: i64) Error!void {
        try self.alive();
        if (control < 0 or encoder < 0 or decoder < 0 or control > max_stream_id or encoder > max_stream_id or decoder > max_stream_id or control & 3 != 3 or encoder & 3 != 3 or decoder & 3 != 3 or control == encoder or control == decoder or encoder == decoder) return error.InvalidArgument;
        try self.check(c.nghttp3_conn_bind_control_stream(self.native, control));
        try self.check(c.nghttp3_conn_bind_qpack_streams(self.native, encoder, decoder));
    }
    /// Return value is flow-control credit, not necessarily the input length:
    /// nghttp3 excludes DATA delivered to recv_data from this count.
    pub fn receive(self: *Connection, stream: i64, bytes: []const u8, fin: bool, now: u64) Error!usize {
        try self.alive();
        if (stream < 0 or stream > max_stream_id) return error.InvalidArgument;
        const result = c.nghttp3_conn_read_stream2(self.native, stream, bytes.ptr, bytes.len, @intFromBool(fin), now);
        if (result < 0) {
            self.failed = true;
            try self.check(@intCast(result));
        }
        // Peer unidirectional FIN closes that stream. nghttp3 determines its
        // type from the wire; IDs alone cannot identify critical streams.
        if (fin and stream & 3 == 2) {
            try self.check(c.nghttp3_conn_close_stream(self.native, stream, c.NGHTTP3_H3_NO_ERROR));
        }
        return @intCast(result);
    }
    pub const Output = struct { stream: i64, fin: bool, vectors: []c.nghttp3_vec };
    /// Borrowed vectors must be sent to QUIC before another connection operation.
    /// A nonnegative stream ID with zero vectors and fin=true is still output.
    pub fn output(self: *Connection, vectors: []c.nghttp3_vec) Error!Output {
        try self.alive();
        if (vectors.len == 0) return error.InvalidArgument;
        var stream: i64 = -1;
        var fin: c_int = 0;
        const result = c.nghttp3_conn_writev_stream(self.native, &stream, &fin, vectors.ptr, vectors.len);
        if (result < 0) {
            self.failed = true;
            try self.check(@intCast(result));
        }
        return .{ .stream = stream, .fin = fin != 0, .vectors = vectors[0..@intCast(result)] };
    }
    /// Advance only by bytes actually accepted by the QUIC transport.
    pub fn wrote(self: *Connection, stream: i64, count: usize) Error!void {
        try self.alive();
        if (stream < 0 or stream > max_stream_id) return error.InvalidArgument;
        try self.check(c.nghttp3_conn_add_write_offset(self.native, stream, count));
    }
    pub fn acknowledged(self: *Connection, stream: i64, count: u64) Error!void {
        try self.alive();
        if (stream < 0 or stream > max_stream_id) return error.InvalidArgument;
        try self.check(c.nghttp3_conn_add_ack_offset(self.native, stream, count));
    }
    fn alive(self: *Connection) Error!void {
        if (self.native == null or self.failed) return error.Closed;
    }
    fn check(self: *Connection, result: c_int) Error!void {
        if (result >= 0) return;
        self.last_error = result;
        self.failed = true;
        if (result == c.NGHTTP3_ERR_NOMEM) return error.OutOfMemory;
        return error.NativeFailure;
    }
};

/// Config values can be passed directly to the future ngtcp2 connection owner.
/// Server CID-specific transport parameters must be populated for each connection.
pub const QuicConfig = struct {
    settings: c.ngtcp2_settings,
    transport: c.ngtcp2_transport_params,
    pub fn init(now: u64) QuicConfig {
        var self: QuicConfig = undefined;
        c.ngtcp2_settings_default(&self.settings);
        c.ngtcp2_transport_params_default(&self.transport);
        self.settings.initial_ts = now;
        self.transport.initial_max_data = 1024 * 1024;
        self.transport.initial_max_stream_data_bidi_remote = 64 * 1024;
        self.transport.initial_max_stream_data_uni = 64 * 1024;
        self.transport.initial_max_streams_bidi = 100;
        self.transport.initial_max_streams_uni = 3;
        self.transport.disable_active_migration = 1;
        return self;
    }
    pub fn encode(self: *const QuicConfig, out: []u8) Error![]const u8 {
        const result = c.ngtcp2_transport_params_encode(out.ptr, out.len, &self.transport);
        if (result == c.NGTCP2_ERR_NOBUF) return error.BufferTooSmall;
        if (result < 0) return error.NativeFailure;
        return out[0..@intCast(result)];
    }
};

pub const TlsContext = struct {
    native: ?*c.SSL_CTX,
    pub fn initServer() Error!TlsContext {
        const context = c.SSL_CTX_new(c.TLS_method()) orelse return error.OutOfMemory;
        errdefer c.SSL_CTX_free(context);
        if (c.ngtcp2_crypto_boringssl_configure_server_context(context) != 0) return error.NativeFailure;
        c.SSL_CTX_set_alpn_select_cb(context, selectAlpn, null);
        return .{ .native = context };
    }
    pub fn deinit(self: *TlsContext) void {
        if (self.native) |context| c.SSL_CTX_free(context);
        self.native = null;
    }
    /// Load a PEM chain and key, verifying they match before accepting sessions.
    pub fn certificate(self: *TlsContext, chain: [:0]const u8, key: [:0]const u8) Error!void {
        const context = self.native orelse return error.Closed;
        if (c.SSL_CTX_use_certificate_chain_file(context, chain.ptr) != 1 or c.SSL_CTX_use_PrivateKey_file(context, key.ptr, c.SSL_FILETYPE_PEM) != 1 or c.SSL_CTX_check_private_key(context) != 1) return error.NativeFailure;
    }
    /// The caller must attach ngtcp2_crypto_conn_ref via SSL_set_app_data before
    /// driving a handshake. This wrapper does not perform a handshake itself.
    pub fn session(self: *TlsContext, params: []const u8) Error!TlsSession {
        const context = self.native orelse return error.Closed;
        const ssl = c.SSL_new(context) orelse return error.OutOfMemory;
        errdefer c.SSL_free(ssl);
        c.SSL_set_accept_state(ssl);
        if (c.SSL_set_quic_transport_params(ssl, params.ptr, params.len) != 1) return error.NativeFailure;
        return .{ .native = ssl };
    }
    fn selectAlpn(_: ?*c.SSL, out: [*c][*c]const u8, outlen: [*c]u8, input: [*c]const u8, len: c_uint, _: ?*anyopaque) callconv(.c) c_int {
        var offset: usize = 0;
        while (offset < len) {
            const size = input[offset];
            offset += 1;
            if (size == 0 or size > len - offset) return c.SSL_TLSEXT_ERR_ALERT_FATAL;
            if (std.mem.eql(u8, input[offset..][0..size], "h3")) {
                out.* = input + offset;
                outlen.* = size;
                return c.SSL_TLSEXT_ERR_OK;
            }
            offset += size;
        }
        return c.SSL_TLSEXT_ERR_ALERT_FATAL;
    }
};

pub const TlsSession = struct {
    native: ?*c.SSL,
    pub fn deinit(self: *TlsSession) void {
        if (self.native) |ssl| c.SSL_free(ssl);
        self.native = null;
    }
};

test "HTTP3 control output and invalid stream IDs" {
    var callbacks = std.mem.zeroes(c.nghttp3_callbacks);
    var connection = try Connection.initServer(&callbacks, null);
    defer connection.deinit();
    try std.testing.expectError(error.InvalidArgument, connection.bindStreams(2, 7, 11));
    try connection.bindStreams(3, 7, 11);
    var vectors: [8]c.nghttp3_vec = undefined;
    const output = try connection.output(&vectors);
    try std.testing.expect(output.stream >= 0);
    var len: usize = 0;
    for (output.vectors) |vector| len += vector.len;
    try std.testing.expect(len > 0);
    try connection.wrote(output.stream, len);
    try connection.acknowledged(output.stream, len);
    // A DATA frame before SETTINGS on the control stream is invalid.
    try std.testing.expectError(error.NativeFailure, connection.receive(2, &.{ 0, 0, 0 }, false, 0));
    try std.testing.expectError(error.Closed, connection.output(&vectors));
    connection.deinit();
    try std.testing.expectError(error.Closed, connection.bindStreams(3, 7, 11));
}

test "QUIC transport configuration and TLS session lifecycle" {
    var config = QuicConfig.init(1234);
    var bytes: [512]u8 = undefined;
    const encoded = try config.encode(&bytes);
    try std.testing.expectError(error.BufferTooSmall, config.encode(bytes[0..0]));
    var decoded: c.ngtcp2_transport_params = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.ngtcp2_transport_params_decode(&decoded, encoded.ptr, encoded.len));
    try std.testing.expectEqual(@as(u64, 3), decoded.initial_max_streams_uni);
    try std.testing.expectEqual(@as(u8, 1), decoded.disable_active_migration);
    try std.testing.expectEqual(@as(u64, 1234), config.settings.initial_ts);
    var context = try TlsContext.initServer();
    defer context.deinit();
    try std.testing.expectError(error.NativeFailure, context.certificate("/nonexistent/server-native-cert.pem", "/nonexistent/server-native-key.pem"));
    var session = try context.session(encoded);
    defer session.deinit();
    try std.testing.expectEqual(@as(c_int, 1), c.SSL_is_quic(session.native));
    context.deinit(); // SSL_new retains a reference to the context.
    try std.testing.expectError(error.Closed, context.session(encoded));
    session.deinit();
}

test "HTTP3 ALPN requires h3 and rejects malformed offers" {
    var out: [*c]const u8 = null;
    var len: u8 = 0;
    const offer = "\x02h2\x02h3";
    try std.testing.expectEqual(@as(c_int, c.SSL_TLSEXT_ERR_OK), TlsContext.selectAlpn(null, &out, &len, offer, offer.len, null));
    try std.testing.expectEqualStrings("h3", out[0..len]);
    try std.testing.expectEqual(@as(c_int, c.SSL_TLSEXT_ERR_ALERT_FATAL), TlsContext.selectAlpn(null, &out, &len, "\x02h2", 3, null));
    try std.testing.expectEqual(@as(c_int, c.SSL_TLSEXT_ERR_ALERT_FATAL), TlsContext.selectAlpn(null, &out, &len, "\x03h3", 3, null));
}

test "HTTP3 rejects invalid and duplicate server stream IDs without poisoning" {
    const cases = [_][3]i64{ .{ -1, 7, 11 }, .{ 3, -1, 11 }, .{ 3, 7, -1 }, .{ 0, 7, 11 }, .{ 1, 7, 11 }, .{ 2, 7, 11 }, .{ 3, 6, 11 }, .{ 3, 7, 10 }, .{ 3, 3, 11 }, .{ 3, 7, 7 }, .{ 3, 7, 3 } };
    var callbacks = std.mem.zeroes(c.nghttp3_callbacks);
    var conn = try Connection.initServer(&callbacks, null);
    defer conn.deinit();
    for (cases) |ids| try std.testing.expectError(error.InvalidArgument, conn.bindStreams(ids[0], ids[1], ids[2]));
    try std.testing.expectError(error.InvalidArgument, conn.receive(-1, "", false, 0));
    try std.testing.expectError(error.InvalidArgument, conn.output(&.{}));
    try std.testing.expectError(error.InvalidArgument, conn.wrote(-1, 0));
    try std.testing.expectError(error.InvalidArgument, conn.acknowledged(-1, 0));
    try conn.bindStreams(15, 19, 23);
}

test "HTTP3 every operation rejects a deinitialized connection" {
    var callbacks = std.mem.zeroes(c.nghttp3_callbacks);
    var conn = try Connection.initServer(&callbacks, null);
    conn.deinit();
    conn.deinit();
    var vectors: [1]c.nghttp3_vec = undefined;
    try std.testing.expectError(error.Closed, conn.bindStreams(3, 7, 11));
    try std.testing.expectError(error.Closed, conn.receive(0, "", false, 0));
    try std.testing.expectError(error.Closed, conn.output(&vectors));
    try std.testing.expectError(error.Closed, conn.wrote(3, 0));
    try std.testing.expectError(error.Closed, conn.acknowledged(3, 0));
}

test "HTTP3 partial output writes drain each control stream exactly once" {
    var callbacks = std.mem.zeroes(c.nghttp3_callbacks);
    var conn = try Connection.initServer(&callbacks, null);
    defer conn.deinit();
    try conn.bindStreams(3, 7, 11);
    var seen = [_]bool{false} ** 3;
    var total: usize = 0;
    var done = false;
    for (0..128) |_| {
        var vectors: [1]c.nghttp3_vec = undefined;
        const output = try conn.output(&vectors);
        if (output.stream == -1) {
            done = true;
            break;
        }
        try std.testing.expect(output.stream == 3 or output.stream == 7 or output.stream == 11);
        seen[@intCast(@divExact(output.stream - 3, 4))] = true;
        try std.testing.expect(output.vectors.len > 0);
        try std.testing.expect(output.vectors[0].len > 0);
        // Accept just one byte; nghttp3 must reoffer the remainder.
        try conn.wrote(output.stream, 1);
        try conn.acknowledged(output.stream, 1);
        total += 1;
    }
    try std.testing.expect(done);
    try std.testing.expect(total > 3);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, &seen);
}

test "HTTP3 duplicate peer control streams are a terminal protocol error" {
    var callbacks = std.mem.zeroes(c.nghttp3_callbacks);
    var conn = try Connection.initServer(&callbacks, null);
    defer conn.deinit();
    _ = try conn.receive(2, &.{ 0, 4, 0 }, false, 0);
    try std.testing.expectError(error.NativeFailure, conn.receive(6, &.{ 0, 4, 0 }, false, 1));
    try std.testing.expect(conn.last_error < 0);
    try std.testing.expectError(error.Closed, conn.receive(2, "", false, 2));
}

test "HTTP3 unknown unidirectional streams may finish at stream two" {
    var callbacks = std.mem.zeroes(c.nghttp3_callbacks);
    var conn = try Connection.initServer(&callbacks, null);
    defer conn.deinit();
    // QUIC IDs encode direction, not HTTP/3 stream type. Type 0x21 is unknown.
    _ = try conn.receive(2, &.{ 0x21, 0xab }, true, 0);
    _ = try conn.receive(6, &.{ 0, 4, 0 }, false, 1);
}

test "HTTP3 closing a control stream at any peer ID is fatal" {
    for ([_]i64{ 2, 6, 14 }) |stream| {
        var callbacks = std.mem.zeroes(c.nghttp3_callbacks);
        var conn = try Connection.initServer(&callbacks, null);
        defer conn.deinit();
        _ = try conn.receive(stream, &.{ 0, 4, 0 }, false, 0);
        try std.testing.expectError(error.NativeFailure, conn.receive(stream, "", true, 1));
        try std.testing.expect(conn.last_error < 0);
    }
}

test "QUIC transport encoding accepts exact buffer and rejects every shorter length" {
    var config = QuicConfig.init(0);
    var storage: [512]u8 = undefined;
    const size = (try config.encode(&storage)).len;
    for (0..size) |length| try std.testing.expectError(error.BufferTooSmall, config.encode(storage[0..length]));
    try std.testing.expectEqual(size, (try config.encode(storage[0..size])).len);
}

test "QUIC transport parameters preserve varint boundary values" {
    const values = [_]u64{ 0, 1, 63, 64, 16383, 16384, 1073741823, 1073741824, (1 << 62) - 1 };
    for (values) |value| {
        var config = QuicConfig.init(value);
        config.transport.initial_max_data = value;
        config.transport.initial_max_stream_data_bidi_remote = value;
        var storage: [512]u8 = undefined;
        const encoded = try config.encode(&storage);
        var decoded: c.ngtcp2_transport_params = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.ngtcp2_transport_params_decode(&decoded, encoded.ptr, encoded.len));
        try std.testing.expectEqual(value, decoded.initial_max_data);
        try std.testing.expectEqual(value, decoded.initial_max_stream_data_bidi_remote);
        try std.testing.expectEqual(@as(u64, 3), decoded.initial_max_streams_uni);
    }
}

test "HTTP3 ALPN offer matrix preserves exact protocol matching" {
    const cases = [_]struct { bytes: []const u8, accepted: bool }{
        .{ .bytes = "", .accepted = false },            .{ .bytes = "\x00", .accepted = false },
        .{ .bytes = "\x01h", .accepted = false },       .{ .bytes = "\x02H3", .accepted = false },
        .{ .bytes = "\x05h3-29", .accepted = false },   .{ .bytes = "\xffh3", .accepted = false },
        .{ .bytes = "\x02h3", .accepted = true },       .{ .bytes = "\x08http/1.1\x02h3", .accepted = true },
        .{ .bytes = "\x02h3\x02h2", .accepted = true }, .{ .bytes = "\x02h3\x02h3", .accepted = true },
    };
    for (cases) |case| {
        var out: [*c]const u8 = null;
        var len: u8 = 0;
        const result = TlsContext.selectAlpn(null, &out, &len, case.bytes.ptr, @intCast(case.bytes.len), null);
        try std.testing.expectEqual(@as(c_int, if (case.accepted) c.SSL_TLSEXT_ERR_OK else c.SSL_TLSEXT_ERR_ALERT_FATAL), result);
        if (case.accepted) try std.testing.expectEqualStrings("h3", out[0..len]);
    }
}

test "TLS context supports independent sessions and rejects operations after close" {
    var context = try TlsContext.initServer();
    defer context.deinit();
    var first = try context.session("");
    defer first.deinit();
    var second = try context.session("");
    defer second.deinit();
    try std.testing.expect(first.native != second.native);
    first.deinit();
    first.deinit();
    try std.testing.expectEqual(@as(c_int, 1), c.SSL_is_quic(second.native));
    context.deinit();
    try std.testing.expectError(error.Closed, context.certificate("missing", "missing"));
    try std.testing.expectError(error.Closed, context.session(""));
    try std.testing.expectEqual(@as(c_uint, c.ssl_encryption_initial), c.SSL_quic_read_level(second.native));
}

const H3RequestProbe = struct {
    headers: usize = 0,
    ends: usize = 0,
    reject: bool,
    fn headersEnd(_: ?*c.nghttp3_conn, stream: i64, _: c_int, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self: *H3RequestProbe = @ptrCast(@alignCast(context.?));
        if (self.reject or stream != 0) return c.NGHTTP3_ERR_CALLBACK_FAILURE;
        self.headers += 1;
        return 0;
    }
    fn end(_: ?*c.nghttp3_conn, stream: i64, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self: *H3RequestProbe = @ptrCast(@alignCast(context.?));
        if (stream != 0) return c.NGHTTP3_ERR_CALLBACK_FAILURE;
        self.ends += 1;
        return 0;
    }
};

fn h3Request(reject: bool) !void {
    var probe: H3RequestProbe = .{ .reject = reject };
    var callbacks = std.mem.zeroes(c.nghttp3_callbacks);
    callbacks.end_headers = H3RequestProbe.headersEnd;
    callbacks.end_stream = H3RequestProbe.end;
    var server = try Connection.initServer(&callbacks, &probe);
    defer server.deinit();
    try server.bindStreams(3, 7, 11);
    c.nghttp3_conn_set_max_client_streams_bidi(server.native, 100);
    var client: ?*c.nghttp3_conn = null;
    var settings: c.nghttp3_settings = undefined;
    c.nghttp3_settings_default(&settings);
    var client_callbacks = std.mem.zeroes(c.nghttp3_callbacks);
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp3_conn_client_new(&client, &client_callbacks, &settings, null, null));
    defer c.nghttp3_conn_del(client);
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp3_conn_bind_control_stream(client, 2));
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp3_conn_bind_qpack_streams(client, 6, 10));
    const fields = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = ":method", .value = "GET" },          .{ .name = ":scheme", .value = "https" },
        .{ .name = ":authority", .value = "localhost" }, .{ .name = ":path", .value = "/health" },
    };
    var nva: [4]c.nghttp3_nv = undefined;
    for (fields, &nva) |field, *nv| nv.* = .{ .name = @constCast(field.name.ptr), .namelen = field.name.len, .value = @constCast(field.value.ptr), .valuelen = field.value.len, .flags = c.NGHTTP3_NV_FLAG_NONE };
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp3_conn_submit_request(client, 0, &nva, nva.len, null, null));
    for (0..64) |round| {
        var vectors: [8]c.nghttp3_vec = undefined;
        var stream: i64 = -1;
        var fin: c_int = 0;
        const count = c.nghttp3_conn_writev_stream(client, &stream, &fin, &vectors, vectors.len);
        try std.testing.expect(count >= 0);
        if (stream == -1) break;
        var total: usize = 0;
        for (vectors[0..@intCast(count)], 0..) |vector, index| {
            for (0..vector.len) |offset| {
                const last = index + 1 == count and offset + 1 == vector.len and fin != 0;
                _ = server.receive(stream, vector.base[offset..][0..1], last, round) catch |err| {
                    if (!reject) return err;
                    try std.testing.expectEqual(error.NativeFailure, err);
                    try std.testing.expectEqual(@as(c_int, c.NGHTTP3_ERR_CALLBACK_FAILURE), server.last_error);
                    return;
                };
            }
            total += vector.len;
        }
        try std.testing.expectEqual(@as(c_int, 0), c.nghttp3_conn_add_write_offset(client, stream, total));
    }
    try std.testing.expect(!reject);
    try std.testing.expectEqual(@as(usize, 1), probe.headers);
    try std.testing.expectEqual(@as(usize, 1), probe.ends);
}

test "HTTP3 QPACK request headers survive one-byte fragmentation" {
    try h3Request(false);
}
test "HTTP3 application callback failure closes the connection" {
    try h3Request(true);
}

fn withPemFiles(mismatch: bool) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cert.pem", .data = @embedFile("testdata/tls-cert.pem") });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "key.pem", .data = if (mismatch) @embedFile("testdata/tls-other-key.pem") else @embedFile("testdata/tls-key.pem") });
    const cert = try tmp.dir.realPathFileAlloc(std.testing.io, "cert.pem", std.testing.allocator);
    defer std.testing.allocator.free(cert);
    const key = try tmp.dir.realPathFileAlloc(std.testing.io, "key.pem", std.testing.allocator);
    defer std.testing.allocator.free(key);
    var context = try TlsContext.initServer();
    defer context.deinit();
    if (mismatch) {
        try std.testing.expectError(error.NativeFailure, context.certificate(cert, key));
    } else {
        try context.certificate(cert, key);
        try std.testing.expectEqual(@as(c_int, 1), c.SSL_CTX_check_private_key(context.native));
        var session = try context.session("");
        defer session.deinit();
        try std.testing.expect(c.SSL_get_certificate(session.native) != null);
    }
}

test "TLS loads a matching certificate and private key" {
    try withPemFiles(false);
}
test "TLS rejects mismatched certificate and private key" {
    try withPemFiles(true);
}

test "HTTP3 stream IDs beyond QUIC varint range never reach native assertions" {
    var callbacks = std.mem.zeroes(c.nghttp3_callbacks);
    var conn = try Connection.initServer(&callbacks, null);
    defer conn.deinit();
    const bad = std.math.maxInt(i64);
    try std.testing.expectError(error.InvalidArgument, conn.bindStreams(bad, 7, 11));
    try std.testing.expectError(error.InvalidArgument, conn.bindStreams(3, bad, 11));
    try std.testing.expectError(error.InvalidArgument, conn.bindStreams(3, 7, bad));
    try std.testing.expectError(error.InvalidArgument, conn.receive(bad, "", false, 0));
    try std.testing.expectError(error.InvalidArgument, conn.wrote(bad, 0));
    try std.testing.expectError(error.InvalidArgument, conn.acknowledged(bad, 0));
    try conn.bindStreams(max_stream_id, max_stream_id - 4, max_stream_id - 8);
}

test "HTTP3 QPACK encoder and decoder closure is fatal at arbitrary IDs" {
    for ([_]u8{ 2, 3 }) |kind| {
        var callbacks = std.mem.zeroes(c.nghttp3_callbacks);
        var conn = try Connection.initServer(&callbacks, null);
        defer conn.deinit();
        _ = try conn.receive(18, &.{kind}, false, 0);
        try std.testing.expectError(error.NativeFailure, conn.receive(18, "", true, 1));
        try std.testing.expectEqual(@as(c_int, c.NGHTTP3_ERR_H3_CLOSED_CRITICAL_STREAM), conn.last_error);
    }
}

test "HTTP3 fragmented multi-byte unknown stream type may finish normally" {
    var callbacks = std.mem.zeroes(c.nghttp3_callbacks);
    var conn = try Connection.initServer(&callbacks, null);
    defer conn.deinit();
    _ = try conn.receive(2, &.{0x40}, false, 0);
    _ = try conn.receive(2, &.{0x21}, false, 1);
    _ = try conn.receive(2, "discard me", true, 2);
    try conn.bindStreams(3, 7, 11);
}
