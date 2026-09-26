const std = @import("std");
const abi = @import("abi.zig");
const event_queue = @import("event_queue.zig");
const bridge_protocol = @import("bridge_protocol.zig");
const proxy_http1 = @import("proxy_http1.zig");
const proxy_http2 = @import("proxy_http2.zig");
const proxy_http3 = @import("proxy_http3.zig");
const http1 = @import("http1.zig").posix;

const c = abi.c;
const dart = @cImport({
    @cInclude("dart_api_dl.h");
});

const Mutex = struct {
    state: std.atomic.Value(u8) = .init(0),

    fn lock(self: *Mutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
    }
};

const PendingResponse = struct {
    wake: ?http1.WakeSignal = null,
    frames: std.ArrayListUnmanaged([]u8) = .empty,
    bytes: usize = 0,
    request_outstanding: usize = 0,
    request_acked: usize = 0,
};

pub const ProxyServer = struct {
    allocator: std.mem.Allocator,
    queue: *event_queue.Queue,
    stopped: std.atomic.Value(bool) = .init(false),
    http_closed: std.atomic.Value(bool) = .init(false),
    detached_connections: std.ArrayList(http1.Fd) = .empty,
    next_request_id: std.atomic.Value(u64) = .init(1),
    active_connections: std.atomic.Value(u32) = .init(0),
    connections_mutex: Mutex = .{},
    connections: std.ArrayList(http1.Fd) = .empty,
    pending_mutex: Mutex = .{},
    pending: std.AutoHashMap(u64, PendingResponse),
    pending_bytes: usize = 0,
    pending_frames: usize = 0,
    response_waiters: bool = false,
    response_limit: usize = 16 * 1024 * 1024,
    stream_response_limit: usize = 256 * 1024,
    listener: http1.Listener,
    accept_thread: ?std.Thread = null,
    port: u16,
    backend_kind: u8 = 0,
    benchmark_mode: u8 = 0,
    backend_host: []const u8 = &.{},
    backend_path: []const u8 = &.{},
    backend_port: u16 = 0,
    tls: ?http1.TlsContext = null,
    http2_enabled: bool = false,
    http3: ?*proxy_http3.Runtime(ProxyServer) = null,
    event_port: std.atomic.Value(i64) = .init(0),

    pub fn setEventPort(self: *ProxyServer, port: i64) void {
        self.event_port.store(port, .release);
        self.queue.setNotifier(self, if (port == 0) null else notifyDart);
    }

    fn notifyDart(context: ?*anyopaque) void {
        const self: *ProxyServer = @ptrCast(@alignCast(context.?));
        const port = self.event_port.load(.acquire);
        if (port == 0) return;
        const post = dart.Dart_PostInteger_DL orelse return;
        _ = post(port, 1);
    }

    pub fn create(config: *const c.ServerNativeProxyConfig, out_port: *u16) ?*ProxyServer {
        const allocator = std.heap.c_allocator;
        if (config.host == null) return null;
        const host = std.mem.span(config.host);
        if (host.len == 0) return null;
        if (config.backend_kind > 1 or config.benchmark_mode > 2) return null;
        const listener = http1.listen(
            allocator,
            host,
            config.port,
            config.backlog,
            config.shared != 0,
            config.v6_only != 0,
        ) catch return null;
        var tls: ?http1.TlsContext = null;
        if (config.tls_cert_path != null or config.tls_key_path != null) {
            if (config.tls_cert_path == null or config.tls_key_path == null) {
                var owned_listener = listener;
                owned_listener.close();
                return null;
            }
            tls = http1.TlsContext.initWithPassword(std.mem.span(config.tls_cert_path), std.mem.span(config.tls_key_path), config.http2 != 0, if (config.tls_cert_password) |password| std.mem.span(password) else null) catch {
                var owned_listener = listener;
                owned_listener.close();
                return null;
            };
        }
        const backend_host = if (config.backend_host) |ptr| allocator.dupe(u8, std.mem.span(ptr)) catch {
            if (tls) |*context| context.deinit();
            var owned_listener = listener;
            owned_listener.close();
            return null;
        } else &.{};
        const backend_path = if (config.backend_path) |ptr| allocator.dupe(u8, std.mem.span(ptr)) catch {
            allocator.free(@constCast(backend_host));
            if (tls) |*context| context.deinit();
            var owned_listener = listener;
            owned_listener.close();
            return null;
        } else &.{};

        const queue = allocator.create(event_queue.Queue) catch {
            var owned_listener = listener;
            owned_listener.close();
            allocator.free(@constCast(backend_host));
            allocator.free(@constCast(backend_path));
            if (tls) |*context| context.deinit();
            return null;
        };
        queue.* = event_queue.Queue.init(allocator, event_queue.max_queue_slots) catch {
            allocator.destroy(queue);
            allocator.free(@constCast(backend_host));
            allocator.free(@constCast(backend_path));
            if (tls) |*context| context.deinit();
            return null;
        };

        const server = allocator.create(ProxyServer) catch {
            queue.deinit();
            allocator.destroy(queue);
            var owned_listener = listener;
            owned_listener.close();
            allocator.free(@constCast(backend_host));
            allocator.free(@constCast(backend_path));
            if (tls) |*context| context.deinit();
            return null;
        };
        server.* = .{
            .allocator = allocator,
            .queue = queue,
            .pending = std.AutoHashMap(u64, PendingResponse).init(allocator),
            .listener = listener,
            .port = listener.port,
            .backend_kind = config.backend_kind,
            .benchmark_mode = config.benchmark_mode,
            .backend_host = backend_host,
            .backend_path = backend_path,
            .backend_port = config.backend_port,
            .tls = tls,
            .http2_enabled = config.http2 != 0,
        };
        if (config.http3 != 0 and tls != null) {
            server.http3 = proxy_http3.Runtime(ProxyServer).create(server, std.mem.span(config.tls_cert_path), std.mem.span(config.tls_key_path), if (config.tls_cert_password) |password| std.mem.span(password) else null, config.shared != 0) catch {
                server.stop();
                return null;
            };
            server.http3.?.start() catch {
                server.stop();
                return null;
            };
        }
        server.accept_thread = std.Thread.spawn(.{}, acceptLoop, .{server}) catch {
            if (server.http3 != null) {
                server.stop();
                return null;
            }
            server.queue.deinit();
            allocator.destroy(server.queue);
            server.listener.close();
            allocator.free(@constCast(server.backend_host));
            allocator.free(@constCast(server.backend_path));
            if (server.tls) |*context| context.deinit();
            allocator.destroy(server);
            return null;
        };
        out_port.* = listener.port;
        return server;
    }

    pub fn detachConnection(self: *ProxyServer, fd: http1.Fd) !void {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();
        try self.detached_connections.append(self.allocator, fd);
    }

    pub fn closeHttp(self: *ProxyServer) void {
        if (self.http_closed.swap(true, .acq_rel)) return;
        self.listener.close();
        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();
        for (self.connections.items) |fd| {
            if (std.mem.indexOfScalar(http1.Fd, self.detached_connections.items, fd) == null) http1.shutdownBoth(fd);
        }
        if (self.http3) |runtime| runtime.beginShutdown();
    }

    pub fn stop(self: *ProxyServer) void {
        if (self.stopped.swap(true, .acq_rel)) return;
        self.listener.close();
        self.connections_mutex.lock();
        for (self.connections.items) |fd| http1.shutdownBoth(fd);
        self.connections_mutex.unlock();
        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }
        while (self.active_connections.load(.acquire) != 0) {
            std.atomic.spinLoopHint();
        }
        self.connections.deinit(self.allocator);
        self.detached_connections.deinit(self.allocator);
        if (self.http3) |runtime| runtime.deinit();
        self.queue.deinit();
        self.allocator.destroy(self.queue);
        self.pending_mutex.lock();
        var pending_it = self.pending.valueIterator();
        while (pending_it.next()) |response| {
            for (response.frames.items) |frame| self.allocator.free(frame);
            response.frames.deinit(self.allocator);
            if (response.wake) |*wake| wake.close();
        }
        self.pending.deinit();
        self.pending_mutex.unlock();
        self.allocator.free(@constCast(self.backend_host));
        self.allocator.free(@constCast(self.backend_path));
        if (self.tls) |*context| context.deinit();
        self.allocator.destroy(self);
    }

    /// The mutex protects both registration and shutdown from descriptor reuse.
    pub fn trackConnection(self: *ProxyServer, fd: http1.Fd) bool {
        self.connections_mutex.lock();
        defer self.connections_mutex.unlock();
        if (self.stopped.load(.acquire) or self.http_closed.load(.acquire)) return false;
        self.connections.append(self.allocator, fd) catch return false;
        return true;
    }

    pub fn closeConnection(self: *ProxyServer, connection: *http1.Connection) void {
        self.connections_mutex.lock();
        if (std.mem.indexOfScalar(http1.Fd, self.detached_connections.items, connection.fd)) |i| {
            _ = self.detached_connections.swapRemove(i);
        }
        for (self.connections.items, 0..) |fd, i| {
            if (fd == connection.fd) {
                _ = self.connections.swapRemove(i);
                break;
            }
        }
        self.connections_mutex.unlock();
        // Removed descriptors are still owned here and cannot be reused until
        // close. A stop racing removal must also unblock TLS shutdown writes.
        if (self.stopped.load(.acquire)) http1.shutdownBoth(connection.fd);
        connection.close();
    }

    pub fn poll(self: *ProxyServer, timeout_ms: u32, out_request_id: *u64, out_payload: *?[*]u8, out_payload_len: *u64) bool {
        var waited: u32 = 0;
        while (!self.stopped.load(.acquire)) {
            if (self.queue.pop()) |event| {
                out_request_id.* = @bitCast(event.request_id);
                out_payload.* = event.payload.ptr;
                out_payload_len.* = @intCast(event.payload.len);
                return true;
            }
            if (timeout_ms == 0 or waited >= timeout_ms) return false;
            std.atomic.spinLoopHint();
            waited += 1;
        }
        return false;
    }

    fn acceptLoop(self: *ProxyServer) void {
        while (!self.stopped.load(.acquire) and !self.http_closed.load(.acquire)) {
            var connection = http1.accept(self.listener.fd) catch {
                if (self.stopped.load(.acquire) or self.http_closed.load(.acquire)) break;
                continue;
            };
            if (!self.trackConnection(connection.fd)) {
                connection.close();
                break;
            }
            _ = self.active_connections.fetchAdd(1, .acq_rel);
            const thread = std.Thread.spawn(.{}, connectionLoop, .{ self, connection }) catch {
                self.closeConnection(&connection);
                _ = self.active_connections.fetchSub(1, .acq_rel);
                continue;
            };
            thread.detach();
        }
    }

    fn connectionLoop(self: *ProxyServer, connection: http1.Connection) void {
        var owned_connection = connection;
        defer {
            self.closeConnection(&owned_connection);
            _ = self.active_connections.fetchSub(1, .acq_rel);
        }

        if (self.tls) |*context| {
            owned_connection.acceptTls(context) catch return;
        }
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(self.allocator);
        if (self.http2_enabled and (owned_connection.isH2() or owned_connection.hasHttp2Preface())) {
            proxy_http2.serve(self.allocator, self, &owned_connection) catch {};
            return;
        }
        while (!self.stopped.load(.acquire)) {
            owned_connection.response_started = false;
            const keep_alive = proxy_http1.serveConnection(self.allocator, self, &owned_connection, &input) catch |err| {
                if (self.stopped.load(.acquire) or owned_connection.response_started or err == error.InvalidRequest) break;
                if (err == error.InvalidRequestTarget or err == error.InvalidTransferEncoding) {
                    http1.sendAllConnection(&owned_connection, "HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\nconnection: close\r\n\r\n") catch {};
                    break;
                }
                const fallback = "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 0\r\nconnection: close\r\n\r\n";
                http1.sendAllConnection(&owned_connection, fallback) catch {};
                break;
            };
            if (!keep_alive) break;
        }
    }

    pub fn registerRequest(self: *ProxyServer, request_id: u64) bool {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        if (self.pending.count() >= 4096 or self.pending.contains(request_id)) return false;
        self.pending.put(request_id, .{}) catch return false;
        return true;
    }

    pub const PushResult = enum(u8) { closed = 0, accepted = 1, full = 2 };

    pub fn pushResponse(self: *ProxyServer, request_id: u64, payload: [*]const u8, payload_len: u64) bool {
        return self.tryPushResponse(request_id, payload, payload_len) == .accepted;
    }

    pub fn tryPushResponse(self: *ProxyServer, request_id: u64, payload: [*]const u8, payload_len: u64) PushResult {
        if (self.stopped.load(.acquire) or payload_len > 4 * 1024 * 1024 + 65536) return .closed;
        const length: usize = @intCast(payload_len);
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        const response = self.pending.getPtr(request_id) orelse return .closed;
        if (length > self.response_limit) return .closed;
        // A finite legacy frame larger than the streaming watermark can occupy
        // an otherwise empty stream queue, within the server-wide byte budget.
        if (length > self.response_limit - self.pending_bytes or
            (response.bytes != 0 and length > self.stream_response_limit -| response.bytes) or
            response.frames.items.len >= 256 or self.pending_frames >= 4096)
        {
            self.response_waiters = true;
            return .full;
        }
        const copy = self.allocator.dupe(u8, payload[0..length]) catch return .closed;
        response.frames.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return .closed;
        };
        response.bytes += length;
        self.pending_bytes += length;
        self.pending_frames += 1;
        if (response.wake) |*wake| wake.signal();
        return .accepted;
    }

    pub fn enableResponseWake(self: *ProxyServer, request_id: u64) !http1.Fd {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        const response = self.pending.getPtr(request_id) orelse return error.RequestClosed;
        if (response.wake == null) response.wake = try http1.WakeSignal.init();
        return response.wake.?.reader;
    }

    fn wakeResponseProducers(self: *ProxyServer) void {
        if (!self.response_waiters) return;
        self.response_waiters = false;
        notifyDart(self);
    }

    pub fn reserveRequestBytes(self: *ProxyServer, request_id: u64, count: usize) bool {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        const request = self.pending.getPtr(request_id) orelse return false;
        if (count > 65536 -| request.request_outstanding) return false;
        request.request_outstanding += count;
        return true;
    }

    pub fn refundRequestBytes(self: *ProxyServer, request_id: u64, count: usize) void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        if (self.pending.getPtr(request_id)) |request| request.request_outstanding -= count;
    }

    pub fn consumeRequestBytes(self: *ProxyServer, request_id: u64, count: usize) void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        if (self.pending.getPtr(request_id)) |request| {
            const consumed = @min(count, request.request_outstanding);
            request.request_outstanding -= consumed;
            request.request_acked += consumed;
        }
    }

    pub fn takeRequestCredit(self: *ProxyServer, request_id: u64) usize {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        const request = self.pending.getPtr(request_id) orelse return 0;
        const count = request.request_acked;
        request.request_acked = 0;
        return count;
    }

    // The connection owns pending state until discardRequest, including after
    // response_end when an upgraded connection continues exchanging tunnel frames.
    pub fn takeResponse(self: *ProxyServer, request_id: u64) ?[]u8 {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        const response = self.pending.getPtr(request_id) orelse return null;
        if (response.frames.items.len != 0) {
            const frame = response.frames.orderedRemove(0);
            response.bytes -= frame.len;
            self.pending_bytes -= frame.len;
            self.pending_frames -= 1;
            self.wakeResponseProducers();
            return frame;
        }
        return null;
    }

    pub fn bridgeEnabled(self: *ProxyServer) bool {
        return self.backend_host.len != 0 or self.backend_path.len != 0;
    }

    pub fn connectBackend(self: *ProxyServer) !http1.Connection {
        if (self.backend_kind == 1) return http1.connectUnix(self.backend_path);
        return http1.connectTcp(self.allocator, self.backend_host, self.backend_port);
    }

    pub fn discardRequest(self: *ProxyServer, request_id: u64) void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        if (self.pending.fetchRemove(request_id)) |entry| {
            var response = entry.value;
            self.pending_bytes -= response.bytes;
            self.pending_frames -= response.frames.items.len;
            self.wakeResponseProducers();
            for (response.frames.items) |frame| self.allocator.free(frame);
            response.frames.deinit(self.allocator);
            if (response.wake) |*wake| wake.close();
        }
    }
};

pub fn asHandle(server: *ProxyServer) *anyopaque {
    return @ptrCast(server);
}

pub fn fromHandle(handle: *anyopaque) *ProxyServer {
    return @ptrCast(@alignCast(handle));
}

pub fn freePolledPayload(payload: ?[*]u8, payload_len: u64) void {
    const ptr = payload orelse return;
    if (payload_len == 0) return;
    std.heap.c_allocator.free(ptr[0..@intCast(payload_len)]);
}

test "proxy lifecycle allocates and stops an opaque handle" {
    const host = "127.0.0.1";
    var config: c.ServerNativeProxyConfig = std.mem.zeroes(c.ServerNativeProxyConfig);
    config.host = @ptrCast(host.ptr);
    var port: u16 = 0;
    const server = ProxyServer.create(&config, &port) orelse return error.OutOfMemory;
    try std.testing.expect(port > 0);
    try std.testing.expect(server.registerRequest(7));
    const response = [_]u8{ 1, 2 };
    try std.testing.expect(server.pushResponse(7, &response, response.len));
    try std.testing.expect(!server.pushResponse(8, &response, response.len));
    server.discardRequest(7);
    server.stop();
}

test "response end retains tunnel request until explicit discard" {
    var config = std.mem.zeroes(c.ServerNativeProxyConfig);
    config.host = "127.0.0.1";
    var port: u16 = 0;
    const server = ProxyServer.create(&config, &port) orelse return error.OutOfMemory;
    defer server.stop();
    try std.testing.expect(server.registerRequest(42));
    const end = [_]u8{ bridge_protocol.protocol_version, @intFromEnum(bridge_protocol.FrameType.response_end) };
    try std.testing.expect(server.pushResponse(42, &end, end.len));
    const received = server.takeResponse(42).?;
    server.allocator.free(received);
    // Polling an empty queue must not discard the upgraded connection.
    try std.testing.expectEqual(null, server.takeResponse(42));
    var chunk: [10]u8 = undefined;
    _ = try bridge_protocol.encodeChunk(.tunnel_chunk, "echo", &chunk);
    try std.testing.expect(server.pushResponse(42, &chunk, chunk.len));
    const echoed = server.takeResponse(42).?;
    defer server.allocator.free(echoed);
    try std.testing.expectEqualSlices(u8, &chunk, echoed);
    server.discardRequest(42);
    try std.testing.expect(!server.pushResponse(42, &chunk, chunk.len));
}

test "response budgets reject before copying and release on dequeue and cancellation" {
    var config = std.mem.zeroes(c.ServerNativeProxyConfig);
    config.host = "127.0.0.1";
    var port: u16 = 0;
    const server = ProxyServer.create(&config, &port) orelse return error.OutOfMemory;
    defer server.stop();
    server.response_limit = 10;
    server.stream_response_limit = 6;
    try std.testing.expect(server.registerRequest(1));
    try std.testing.expect(server.registerRequest(2));
    try std.testing.expect(!server.registerRequest(1));
    try std.testing.expectEqual(ProxyServer.PushResult.accepted, server.tryPushResponse(1, "12345678", 8));
    try std.testing.expectEqual(ProxyServer.PushResult.full, server.tryPushResponse(1, "x", 1));
    try std.testing.expectEqual(ProxyServer.PushResult.accepted, server.tryPushResponse(2, "ab", 2));
    try std.testing.expectEqual(ProxyServer.PushResult.full, server.tryPushResponse(2, "c", 1));
    try std.testing.expectEqual(@as(usize, 10), server.pending_bytes);
    const first = server.takeResponse(1).?;
    defer server.allocator.free(first);
    try std.testing.expectEqualStrings("12345678", first);
    try std.testing.expectEqual(@as(usize, 2), server.pending_bytes);
    try std.testing.expectEqual(ProxyServer.PushResult.accepted, server.tryPushResponse(2, "cdef", 4));
    server.discardRequest(2);
    try std.testing.expectEqual(@as(usize, 0), server.pending_bytes);
    try std.testing.expectEqual(@as(usize, 0), server.pending_frames);
    try std.testing.expectEqual(ProxyServer.PushResult.closed, server.tryPushResponse(2, "x", 1));
    try std.testing.expectEqual(ProxyServer.PushResult.closed, server.tryPushResponse(1, "12345678901", 11));
}

test "empty response frames are bounded by slot count" {
    var config = std.mem.zeroes(c.ServerNativeProxyConfig);
    config.host = "127.0.0.1";
    var port: u16 = 0;
    const server = ProxyServer.create(&config, &port) orelse return error.OutOfMemory;
    defer server.stop();
    try std.testing.expect(server.registerRequest(1));
    for (0..256) |_| try std.testing.expect(server.pushResponse(1, "", 0));
    try std.testing.expectEqual(ProxyServer.PushResult.full, server.tryPushResponse(1, "", 0));
    server.discardRequest(1);
    try std.testing.expectEqual(@as(usize, 0), server.pending_frames);
}

test "upload credit follows consumption and survives queue reservation rollback" {
    var config = std.mem.zeroes(c.ServerNativeProxyConfig);
    config.host = "127.0.0.1";
    var port: u16 = 0;
    const server = ProxyServer.create(&config, &port) orelse return error.OutOfMemory;
    defer server.stop();
    try std.testing.expect(server.registerRequest(1));
    try std.testing.expect(server.reserveRequestBytes(1, 65536));
    try std.testing.expect(!server.reserveRequestBytes(1, 1));
    try std.testing.expectEqual(@as(usize, 0), server.takeRequestCredit(1));
    server.consumeRequestBytes(1, 16384);
    try std.testing.expectEqual(@as(usize, 16384), server.takeRequestCredit(1));
    try std.testing.expectEqual(@as(usize, 0), server.takeRequestCredit(1));
    try std.testing.expect(server.reserveRequestBytes(1, 16384));
    server.refundRequestBytes(1, 16384);
    try std.testing.expect(server.reserveRequestBytes(1, 16384));
    try std.testing.expect(!server.reserveRequestBytes(1, 1));
    server.discardRequest(1);
    server.consumeRequestBytes(1, 65536);
    try std.testing.expectEqual(@as(usize, 0), server.takeRequestCredit(1));
}

test "proxy rejects invalid configuration without modifying the output port" {
    var config = std.mem.zeroes(c.ServerNativeProxyConfig);
    var port: u16 = 42;
    try std.testing.expect(ProxyServer.create(&config, &port) == null);
    config.host = "";
    try std.testing.expect(ProxyServer.create(&config, &port) == null);
    config.host = "127.0.0.1";
    config.backend_kind = 2;
    try std.testing.expect(ProxyServer.create(&config, &port) == null);
    config.backend_kind = 0;
    config.benchmark_mode = 3;
    try std.testing.expect(ProxyServer.create(&config, &port) == null);
    config.benchmark_mode = 0;
    config.tls_cert_path = "missing";
    try std.testing.expect(ProxyServer.create(&config, &port) == null);
    config.tls_cert_path = null;
    config.tls_key_path = "missing";
    try std.testing.expect(ProxyServer.create(&config, &port) == null);
    try std.testing.expectEqual(@as(u16, 42), port);
}

test "proxy request admission limit recovers after cancellation and preserves peer queues" {
    var config = std.mem.zeroes(c.ServerNativeProxyConfig);
    config.host = "127.0.0.1";
    var port: u16 = 0;
    const server = ProxyServer.create(&config, &port) orelse return error.StartFailed;
    defer server.stop();
    for (0..4096) |id| try std.testing.expect(server.registerRequest(id));
    try std.testing.expect(!server.registerRequest(4096));
    try std.testing.expect(server.pushResponse(1, "peer", 4));
    server.discardRequest(0);
    server.discardRequest(0);
    try std.testing.expect(server.registerRequest(4096));
    try std.testing.expect(!server.registerRequest(4097));
    const frame = server.takeResponse(1).?;
    defer server.allocator.free(frame);
    try std.testing.expectEqualStrings("peer", frame);
    try std.testing.expectEqual(@as(usize, 0), server.pending_bytes);
}

test "proxy response copies input and upload consumption clamps duplicate credit" {
    var config = std.mem.zeroes(c.ServerNativeProxyConfig);
    config.host = "127.0.0.1";
    var port: u16 = 0;
    const server = ProxyServer.create(&config, &port) orelse return error.StartFailed;
    defer server.stop();
    try std.testing.expect(server.registerRequest(1));
    var input = [_]u8{ 0, 255, 42 };
    try std.testing.expect(server.pushResponse(1, &input, input.len));
    @memset(&input, 0);
    const frame = server.takeResponse(1).?;
    defer server.allocator.free(frame);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 42 }, frame);
    try std.testing.expect(server.reserveRequestBytes(1, 123));
    server.consumeRequestBytes(1, 999);
    server.consumeRequestBytes(1, 999);
    try std.testing.expectEqual(@as(usize, 123), server.takeRequestCredit(1));
    try std.testing.expectEqual(@as(usize, 0), server.takeRequestCredit(1));
    try std.testing.expect(server.reserveRequestBytes(1, 65536));
}

test "proxy stop interrupts registered sockets without stealing worker close ownership" {
    const socket = @cImport({
        @cInclude("sys/socket.h");
    });
    var fds: [2]c_int = undefined;
    if (socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    var worker_connection: http1.Connection = .{ .fd = fds[0] };
    defer worker_connection.close();
    var peer: http1.Connection = .{ .fd = fds[1] };
    defer peer.close();
    var config = std.mem.zeroes(c.ServerNativeProxyConfig);
    config.host = "127.0.0.1";
    var port: u16 = 0;
    const server = ProxyServer.create(&config, &port) orelse return error.StartFailed;
    const registered = server.trackConnection(worker_connection.fd);
    server.stop();
    try std.testing.expect(registered);
    var buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 0), try http1.receiveTimeout(peer.fd, &buffer, 1000));
    // Stop shut down the descriptor, but only the worker closes it.
    try std.testing.expect(worker_connection.fd >= 0);
}

test "direct tunnel responses wake their own request poller" {
    var config = std.mem.zeroes(c.ServerNativeProxyConfig);
    config.host = "127.0.0.1";
    var port: u16 = 0;
    const server = ProxyServer.create(&config, &port) orelse return error.StartFailed;
    defer server.stop();
    try std.testing.expect(server.registerRequest(1));
    try std.testing.expect(server.registerRequest(2));
    const first = try server.enableResponseWake(1);
    const second = try server.enableResponseWake(2);
    try std.testing.expectEqual(first, try server.enableResponseWake(1));
    var pollfds = [_]std.posix.pollfd{
        .{ .fd = first, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = second, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const frame = [_]u8{ 1, 10 };
    try std.testing.expect(server.pushResponse(2, &frame, frame.len));
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&pollfds, 0));
    try std.testing.expectEqual(@as(i16, 0), pollfds[0].revents);
    try std.testing.expect(pollfds[1].revents & std.posix.POLL.IN != 0);
    http1.WakeSignal.drain(second);
    server.discardRequest(2);
    try std.testing.expectError(error.RequestClosed, server.enableResponseWake(2));
    server.discardRequest(1);
}
