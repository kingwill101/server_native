const std = @import("std");

const c = @cImport({
    @cInclude("arpa/inet.h");
    @cInclude("netdb.h");
    @cInclude("netinet/in.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/types.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
    @cInclude("openssl/ssl.h");
});

pub const Fd = c_int;

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
        _ = c.OPENSSL_init_ssl(0, null);
        const ctx = c.SSL_CTX_new(c.TLS_server_method()) orelse return error.TlsContextFailed;
        errdefer c.SSL_CTX_free(ctx);
        const cert = try std.heap.c_allocator.dupeZ(u8, cert_path);
        defer std.heap.c_allocator.free(cert);
        const key = try std.heap.c_allocator.dupeZ(u8, key_path);
        defer std.heap.c_allocator.free(key);
        if (c.SSL_CTX_use_certificate_chain_file(ctx, cert.ptr) != 1) return error.TlsCertificateFailed;
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

    pub fn acceptTls(self: *Connection, context: *const TlsContext) !void {
        const ssl = c.SSL_new(context.ctx) orelse return error.TlsConnectionFailed;
        errdefer c.SSL_free(ssl);
        if (c.SSL_set_fd(ssl, self.fd) != 1) return error.TlsConnectionFailed;
        if (c.SSL_accept(ssl) != 1) return error.TlsHandshakeFailed;
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
        errdefer _ = c.close(fd);

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
        return .{ .fd = fd, .port = actual_port };
    }

    return error.AddressBindFailed;
}

pub fn accept(listener: Fd) !Connection {
    const fd = c.accept(listener, null, null);
    if (fd < 0) return error.AcceptFailed;
    return .{ .fd = fd };
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
        if (c.connect(fd, address.ai_addr, address.ai_addrlen) == 0) return .{ .fd = fd };
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
