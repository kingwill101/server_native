const std = @import("std");

const c = @cImport({
    @cInclude("arpa/inet.h");
    @cInclude("netdb.h");
    @cInclude("netinet/in.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/types.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
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

pub const Connection = struct {
    fd: Fd,

    pub fn close(self: *Connection) void {
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
        offset += @intCast(result);
    }
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
