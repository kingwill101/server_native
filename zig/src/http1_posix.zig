const std = @import("std");

const c = @cImport({
    @cInclude("arpa/inet.h");
    @cInclude("netdb.h");
    @cInclude("netinet/in.h");
    @cInclude("netinet/tcp.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/types.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("openssl/ssl.h");
});

pub const Fd = c_int;

/// A nonblocking, coalescing wake signal for a native poll loop.
/// The reader owns draining; producers signal under the pending-request lock.
pub const WakeSignal = struct {
    reader: Fd,
    writer: Fd,

    pub fn init() !WakeSignal {
        var fds: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0, &fds) != 0) return error.WakeSignalFailed;
        return .{ .reader = fds[0], .writer = fds[1] };
    }

    pub fn signal(self: *WakeSignal) void {
        const byte = [_]u8{1};
        // A full socket already represents a pending wakeup. Never block Dart.
        _ = c.send(self.writer, &byte, 1, c.MSG_DONTWAIT | c.MSG_NOSIGNAL);
    }

    pub fn drain(reader: Fd) void {
        var buffer: [256]u8 = undefined;
        while (c.recv(reader, &buffer, buffer.len, c.MSG_DONTWAIT) > 0) {}
    }

    pub fn close(self: *WakeSignal) void {
        _ = c.close(self.reader);
        _ = c.close(self.writer);
    }
};

pub const Listener = struct {
    fd: Fd,
    port: u16,

    pub fn close(self: *Listener) void {
        if (self.fd >= 0) {
            _ = c.shutdown(self.fd, c.SHUT_RDWR);
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }
};

pub const TlsContext = struct {
    ctx: *c.SSL_CTX,

    pub fn init(cert_path: []const u8, key_path: []const u8, enable_h2: bool) !TlsContext {
        return initWithPassword(cert_path, key_path, enable_h2, null);
    }

    pub fn initWithPassword(cert_path: []const u8, key_path: []const u8, enable_h2: bool, password: ?[:0]const u8) !TlsContext {
        _ = c.OPENSSL_init_ssl(0, null);
        const ctx = c.SSL_CTX_new(c.TLS_server_method()) orelse return error.TlsContextFailed;
        errdefer c.SSL_CTX_free(ctx);
        const cert = try std.heap.c_allocator.dupeZ(u8, cert_path);
        defer std.heap.c_allocator.free(cert);
        const key = try std.heap.c_allocator.dupeZ(u8, key_path);
        defer std.heap.c_allocator.free(key);
        if (c.SSL_CTX_use_certificate_chain_file(ctx, cert.ptr) != 1) return error.TlsCertificateFailed;
        c.SSL_CTX_set_default_passwd_cb_userdata(ctx, if (password) |value| @ptrCast(@constCast(value.ptr)) else null);
        defer c.SSL_CTX_set_default_passwd_cb_userdata(ctx, null);
        if (c.SSL_CTX_use_PrivateKey_file(ctx, key.ptr, c.SSL_FILETYPE_PEM) != 1) return error.TlsKeyFailed;
        if (c.SSL_CTX_check_private_key(ctx) != 1) return error.TlsKeyMismatch;
        if (enable_h2) c.SSL_CTX_set_alpn_select_cb(ctx, selectAlpn, null);
        return .{ .ctx = ctx };
    }

    fn selectAlpn(_: ?*c.SSL, out: [*c][*c]const u8, outlen: [*c]u8, input: [*c]const u8, len: c_uint, _: ?*anyopaque) callconv(.c) c_int {
        var offset: usize = 0;
        while (offset < len) {
            const size = input[offset];
            offset += 1;
            if (size == 0 or size > len - offset) return c.SSL_TLSEXT_ERR_ALERT_FATAL;
            if (std.mem.eql(u8, input[offset..][0..size], "h2")) {
                out.* = input + offset;
                outlen.* = size;
                return c.SSL_TLSEXT_ERR_OK;
            }
            offset += size;
        }
        return c.SSL_TLSEXT_ERR_NOACK;
    }

    pub fn deinit(self: *TlsContext) void {
        c.SSL_CTX_free(self.ctx);
    }
};

pub const Connection = struct {
    fd: Fd,
    ssl: ?*c.SSL = null,
    response_started: bool = false,

    pub fn acceptTls(self: *Connection, context: *const TlsContext) !void {
        const ssl = c.SSL_new(context.ctx) orelse return error.TlsConnectionFailed;
        errdefer c.SSL_free(ssl);
        if (c.SSL_set_fd(ssl, self.fd) != 1) return error.TlsConnectionFailed;
        const flags = std.posix.system.fcntl(self.fd, std.posix.F.GETFL, @as(c_int, 0));
        if (flags < 0 or std.posix.system.fcntl(self.fd, std.posix.F.SETFL, flags | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }))) < 0) return error.TlsHandshakeFailed;
        defer _ = std.posix.system.fcntl(self.fd, std.posix.F.SETFL, flags);
        var now: c.struct_timespec = undefined;
        if (c.clock_gettime(c.CLOCK_MONOTONIC, &now) != 0) return error.TlsHandshakeFailed;
        const deadline = now.tv_sec * 1000 + @divTrunc(now.tv_nsec, 1_000_000) + 5000;
        while (true) {
            const result = c.SSL_accept(ssl);
            if (result == 1) break;
            const ssl_error = c.SSL_get_error(ssl, result);
            const events: i16 = switch (ssl_error) {
                c.SSL_ERROR_WANT_READ => std.posix.POLL.IN,
                c.SSL_ERROR_WANT_WRITE => std.posix.POLL.OUT,
                else => return error.TlsHandshakeFailed,
            };
            if (c.clock_gettime(c.CLOCK_MONOTONIC, &now) != 0) return error.TlsHandshakeFailed;
            const remaining = deadline - (now.tv_sec * 1000 + @divTrunc(now.tv_nsec, 1_000_000));
            if (remaining <= 0) return error.TlsHandshakeTimeout;
            var pollfds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = events, .revents = 0 }};
            if (try std.posix.poll(&pollfds, @intCast(remaining)) == 0) return error.TlsHandshakeTimeout;
        }
        self.ssl = ssl;
    }

    pub fn isH2(self: *const Connection) bool {
        const ssl = self.ssl orelse return false;
        var selected: [*c]const u8 = null;
        var length: c_uint = 0;
        c.SSL_get0_alpn_selected(ssl, &selected, &length);
        return selected != null and length == 2 and std.mem.eql(u8, selected[0..2], "h2");
    }

    pub fn hasHttp2Preface(self: *const Connection) bool {
        if (self.ssl != null) return false;
        // Route the reserved PRI method to nghttp2, which validates the full
        // preface. Waiting for this prefix also handles fragmented TCP input.
        var preface: [3]u8 = undefined;
        const count = c.recv(self.fd, &preface, preface.len, c.MSG_PEEK | c.MSG_WAITALL);
        return count == preface.len and std.mem.eql(u8, &preface, "PRI");
    }

    pub fn close(self: *Connection) void {
        if (self.ssl) |ssl| {
            _ = c.SSL_shutdown(ssl);
            c.SSL_free(ssl);
            self.ssl = null;
        }
        if (self.fd >= 0) {
            _ = c.shutdown(self.fd, c.SHUT_RDWR);
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }
};

pub fn listen(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    backlog: u32,
    shared: bool,
    v6_only: bool,
) !Listener {
    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);
    const port_text = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_text);
    const port_z = try allocator.dupeZ(u8, port_text);
    defer allocator.free(port_z);

    var hints = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_family = c.AF_UNSPEC;
    hints.ai_socktype = c.SOCK_STREAM;
    hints.ai_flags = c.AI_PASSIVE;

    var result: ?*c.struct_addrinfo = null;
    const lookup = c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &result);
    if (lookup != 0) return error.AddressResolutionFailed;
    defer if (result) |ptr| c.freeaddrinfo(ptr);

    var current = result;
    while (current) |address| : (current = address.ai_next) {
        const fd = c.socket(address.ai_family, address.ai_socktype, address.ai_protocol);
        if (fd < 0) continue;
        var owned = true;
        defer if (owned) {
            _ = c.close(fd);
        };

        if (address.ai_family == c.AF_INET6) {
            var option: c_int = @intFromBool(v6_only);
            if (c.setsockopt(fd, c.IPPROTO_IPV6, c.IPV6_V6ONLY, &option, @sizeOf(c_int)) != 0) continue;
        }
        var reuse: c_int = 1;
        _ = c.setsockopt(
            fd,
            c.SOL_SOCKET,
            c.SO_REUSEADDR,
            &reuse,
            @sizeOf(c_int),
        );
        if (shared) {
            _ = c.setsockopt(
                fd,
                c.SOL_SOCKET,
                c.SO_REUSEPORT,
                &reuse,
                @sizeOf(c_int),
            );
        }
        if (c.bind(fd, address.ai_addr, address.ai_addrlen) != 0) continue;
        const requested_backlog: c_int = if (backlog == 0)
            128
        else if (backlog > std.math.maxInt(c_int))
            std.math.maxInt(c_int)
        else
            @intCast(backlog);
        if (c.listen(fd, requested_backlog) != 0) continue;

        const actual_port = try boundPort(fd, address.ai_family);
        owned = false;
        return .{ .fd = fd, .port = actual_port };
    }

    return error.AddressBindFailed;
}

pub fn accept(listener: Fd) !Connection {
    const fd = c.accept(listener, null, null);
    if (fd < 0) return error.AcceptFailed;
    errdefer _ = c.close(fd);
    try setTcpNoDelay(fd);
    return .{ .fd = fd };
}

fn setTcpNoDelay(fd: Fd) !void {
    const enabled: c_int = 1;
    if (c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_NODELAY, &enabled, @sizeOf(c_int)) != 0) return error.SocketOptionFailed;
}

pub fn connectTcp(allocator: std.mem.Allocator, host: []const u8, port: u16) !Connection {
    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);
    const port_text = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_text);
    const port_z = try allocator.dupeZ(u8, port_text);
    defer allocator.free(port_z);
    var hints = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_family = c.AF_UNSPEC;
    hints.ai_socktype = c.SOCK_STREAM;
    var result: ?*c.struct_addrinfo = null;
    if (c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &result) != 0) return error.BackendConnectFailed;
    defer if (result) |ptr| c.freeaddrinfo(ptr);
    var current = result;
    while (current) |address| : (current = address.ai_next) {
        const fd = c.socket(address.ai_family, address.ai_socktype, address.ai_protocol);
        if (fd < 0) continue;
        if (c.connect(fd, address.ai_addr, address.ai_addrlen) == 0) {
            setTcpNoDelay(fd) catch {
                _ = c.close(fd);
                continue;
            };
            return .{ .fd = fd };
        }
        _ = c.close(fd);
    }
    return error.BackendConnectFailed;
}

pub fn connectUnix(path: []const u8) !Connection {
    if (path.len >= 108) return error.BackendPathTooLong;
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return error.BackendConnectFailed;
    errdefer _ = c.close(fd);
    var address = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(address.sun_path[0..path.len], path);
    const length: c.socklen_t = @intCast(@offsetOf(c.struct_sockaddr_un, "sun_path") + path.len + 1);
    if (c.connect(fd, @ptrCast(&address), length) != 0) return error.BackendConnectFailed;
    return .{ .fd = fd };
}

/// Interrupt blocked reads and writes while the owning worker retains close ownership.
pub fn shutdownBoth(fd: Fd) void {
    _ = c.shutdown(fd, c.SHUT_RDWR);
}

pub fn receive(connection: Fd, buffer: []u8) !usize {
    const result = c.recv(connection, buffer.ptr, buffer.len, 0);
    if (result < 0) return error.ReceiveFailed;
    return @intCast(result);
}

pub fn receiveConnection(connection: *Connection, buffer: []u8) !usize {
    if (connection.ssl) |ssl| {
        const result = c.SSL_read(ssl, buffer.ptr, @intCast(buffer.len));
        if (result <= 0) return error.ReceiveFailed;
        return @intCast(result);
    }
    return receive(connection.fd, buffer);
}

pub fn receiveTimeoutConnection(connection: *Connection, buffer: []u8, timeout_ms: i32) !?usize {
    if (connection.ssl) |ssl| {
        if (c.SSL_pending(ssl) > 0) return try receiveConnection(connection, buffer);
    }
    var descriptors = [_]std.posix.pollfd{.{
        .fd = connection.fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&descriptors, timeout_ms) catch return error.ReceiveFailed;
    if (ready == 0) return null;
    return try receiveConnection(connection, buffer);
}

pub fn receiveTimeout(connection: Fd, buffer: []u8, timeout_ms: i32) !?usize {
    var descriptors = [_]std.posix.pollfd{.{
        .fd = connection,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&descriptors, timeout_ms) catch return error.ReceiveFailed;
    if (ready == 0) return null;
    return try receive(connection, buffer);
}

pub fn sendAll(connection: Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = c.send(connection, bytes.ptr + offset, bytes.len - offset, 0);
        if (result <= 0) return error.SendFailed;
        const written: usize = @intCast(result);
        if (offset > bytes.len or written > bytes.len - offset) return error.SendFailed;
        offset = std.math.add(usize, offset, written) catch return error.SendFailed;
    }
}

pub fn sendAllConnection(connection: *Connection, bytes: []const u8) !void {
    if (connection.ssl) |ssl| {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const result = c.SSL_write(ssl, bytes.ptr + offset, @intCast(bytes.len - offset));
            if (result <= 0) return error.SendFailed;
            const written: usize = @intCast(result);
            if (written > bytes.len - offset) return error.SendFailed;
            offset = std.math.add(usize, offset, written) catch return error.SendFailed;
        }
        return;
    }
    return sendAll(connection.fd, bytes);
}

fn boundPort(fd: Fd, family: c_int) !u16 {
    var storage = std.mem.zeroes(c.struct_sockaddr_storage);
    var length: c.socklen_t = @sizeOf(c.struct_sockaddr_storage);
    if (c.getsockname(fd, @ptrCast(&storage), &length) != 0) {
        return error.AddressQueryFailed;
    }
    return switch (family) {
        c.AF_INET => c.ntohs(@as(*const c.struct_sockaddr_in, @ptrCast(@alignCast(&storage))).sin_port),
        c.AF_INET6 => c.ntohs(@as(*const c.struct_sockaddr_in6, @ptrCast(@alignCast(&storage))).sin6_port),
        else => error.UnsupportedAddressFamily,
    };
}

/// Sends FIN without discarding bytes still arriving from the peer.
pub fn shutdownWrite(fd: Fd) void {
    _ = c.shutdown(fd, c.SHUT_WR);
}

/// Returns null when the peer cannot currently accept more bridge bytes.
pub fn sendNonblocking(fd: Fd, bytes: []const u8) !?usize {
    const result = c.send(fd, bytes.ptr, bytes.len, c.MSG_DONTWAIT | c.MSG_NOSIGNAL);
    if (result < 0) {
        return switch (std.posix.errno(result)) {
            .AGAIN, .INTR => null,
            else => error.SendFailed,
        };
    }
    if (result == 0) return error.SendFailed;
    return @intCast(result);
}

test "TCP listener binds an ephemeral port and supports half-close response traffic" {
    var listener = try listen(std.testing.allocator, "127.0.0.1", 0, 8, false, false);
    defer listener.close();
    try std.testing.expect(listener.port != 0);
    var client = try connectTcp(std.testing.allocator, "127.0.0.1", listener.port);
    defer client.close();
    var peer = try accept(listener.fd);
    defer peer.close();
    for ([_]Fd{ client.fd, peer.fd }) |fd| {
        var enabled: c_int = 0;
        var length: c.socklen_t = @sizeOf(c_int);
        try std.testing.expectEqual(@as(c_int, 0), c.getsockopt(fd, c.IPPROTO_TCP, c.TCP_NODELAY, &enabled, &length));
        try std.testing.expectEqual(@as(c_int, 1), enabled);
    }
    var buffer: [16]u8 = undefined;
    try std.testing.expect((try receiveTimeoutConnection(&peer, &buffer, 0)) == null);
    try sendAllConnection(&client, "request");
    shutdownWrite(client.fd);
    const count = (try receiveTimeoutConnection(&peer, &buffer, 1000)) orelse return error.NoRequest;
    try std.testing.expectEqualStrings("request", buffer[0..count]);
    try std.testing.expectEqual(@as(?usize, 0), try receiveTimeoutConnection(&peer, &buffer, 1000));
    try sendAllConnection(&peer, "reply");
    const reply = (try receiveTimeoutConnection(&client, &buffer, 1000)) orelse return error.NoReply;
    try std.testing.expectEqualStrings("reply", buffer[0..reply]);
    peer.close();
    peer.close();
    try std.testing.expectEqual(@as(Fd, -1), peer.fd);
    listener.close();
    listener.close();
    try std.testing.expectEqual(@as(Fd, -1), listener.fd);
}

test "TCP reserved PRI prefix detection does not consume input" {
    for ([_][]const u8{ "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", "GET / HTTP/1.1\r\n" }, 0..) |wire, index| {
        var fds: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds));
        var peer: Connection = .{ .fd = fds[0] };
        defer peer.close();
        defer _ = c.close(fds[1]);
        try sendAll(fds[1], wire);
        try std.testing.expectEqual(index == 0, peer.hasHttp2Preface());
        try std.testing.expect(!peer.isH2());
        var buffer: [64]u8 = undefined;
        const count = try receiveConnection(&peer, &buffer);
        try std.testing.expectEqualStrings(wire, buffer[0..count]);
    }
}

test "socket nonblocking writes report pressure and resume after peer drains" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    var size: c_int = 4096;
    try std.testing.expectEqual(@as(c_int, 0), c.setsockopt(fds[0], c.SOL_SOCKET, c.SO_SNDBUF, &size, @sizeOf(c_int)));
    const bytes: [4096]u8 = @splat(0x5a);
    var sent: usize = 0;
    var blocked = false;
    for (0..1024) |_| {
        const count = (try sendNonblocking(fds[0], &bytes)) orelse {
            blocked = true;
            break;
        };
        sent += count;
    }
    try std.testing.expect(blocked and sent > 0);
    var buffer: [4096]u8 = undefined;
    var received: usize = 0;
    while (received < sent) {
        const count = (try receiveTimeout(fds[1], &buffer, 1000)) orelse return error.DrainTimeout;
        try std.testing.expect(count != 0);
        try std.testing.expectEqualSlices(u8, bytes[0..count], buffer[0..count]);
        received += count;
    }
    try std.testing.expectEqual(@as(?usize, 1), try sendNonblocking(fds[0], "x"));
}

test "socket invalid descriptors and excessive Unix paths fail explicitly" {
    var buffer: [1]u8 = undefined;
    try std.testing.expectError(error.AcceptFailed, accept(-1));
    try std.testing.expectError(error.ReceiveFailed, receive(-1, &buffer));
    try std.testing.expectError(error.SendFailed, sendAll(-1, "x"));
    try std.testing.expectError(error.SendFailed, sendNonblocking(-1, "x"));
    try std.testing.expectError(error.AddressQueryFailed, boundPort(-1, c.AF_INET));
    try std.testing.expectError(error.BackendPathTooLong, connectUnix(&(@as([108]u8, @splat('x')))));
    try std.testing.expectError(error.BackendConnectFailed, connectUnix(""));
}

test "HTTP1 TLS ALPN chooses h2 from an offer and rejects malformed lengths" {
    var selected: [*c]const u8 = null;
    var length: u8 = 0;
    const protocols = "\x08http/1.1\x02h2";
    try std.testing.expectEqual(c.SSL_TLSEXT_ERR_OK, TlsContext.selectAlpn(null, &selected, &length, protocols, protocols.len, null));
    try std.testing.expectEqualStrings("h2", selected[0..length]);
    for ([_][]const u8{ "\x00", "\x03h2" }) |invalid| {
        try std.testing.expectEqual(c.SSL_TLSEXT_ERR_ALERT_FATAL, TlsContext.selectAlpn(null, &selected, &length, invalid.ptr, @intCast(invalid.len), null));
    }
    const http11 = "\x08http/1.1";
    try std.testing.expectEqual(c.SSL_TLSEXT_ERR_NOACK, TlsContext.selectAlpn(null, &selected, &length, http11, http11.len, null));
    try std.testing.expectError(error.TlsCertificateFailed, TlsContext.init("", "", true));
}

test "wake signals are nonblocking coalesce and return to idle after drain" {
    var wake = try WakeSignal.init();
    defer wake.close();
    var pollfds = [_]std.posix.pollfd{.{ .fd = wake.reader, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&pollfds, 0));
    // Exceed socket buffering: signal must remain nonblocking when full.
    for (0..100000) |_| wake.signal();
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&pollfds, 0));
    WakeSignal.drain(wake.reader);
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&pollfds, 0));
    wake.signal();
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&pollfds, 0));
}

test "TLS encrypted key uses its password only during initialization" {
    try std.testing.expectError(error.TlsKeyFailed, TlsContext.initWithPassword("../example/http2/cert.pem", "../example/http2/key_encrypted.pem", false, "wrong-pass"));
    var tls = try TlsContext.initWithPassword("../example/http2/cert.pem", "../example/http2/key_encrypted.pem", true, "routed-test-pass");
    defer tls.deinit();
    try std.testing.expect(c.SSL_CTX_get_default_passwd_cb_userdata(tls.ctx) == null);
}
