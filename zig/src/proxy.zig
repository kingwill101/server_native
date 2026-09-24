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
    frames: std.ArrayListUnmanaged([]u8) = .empty,
};

pub const ProxyServer = struct {
    allocator: std.mem.Allocator,
    queue: *event_queue.Queue,
    stopped: std.atomic.Value(bool) = .init(false),
    next_request_id: std.atomic.Value(u64) = .init(1),
    active_connections: std.atomic.Value(u32) = .init(0),
    pending_mutex: Mutex = .{},
    pending: std.AutoHashMap(u64, PendingResponse),
    listener: http1.Listener,
    accept_thread: ?std.Thread = null,
    port: u16,
    backend_kind: u8 = 0,
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
        if (config.backend_kind > 1) return null;
        const listener = http1.listen(
            allocator,
            host,
            config.port,
            config.backlog,
            config.shared != 0,
        ) catch return null;
        var tls: ?http1.TlsContext = null;
        if (config.tls_cert_path != null or config.tls_key_path != null) {
            if (config.tls_cert_path == null or config.tls_key_path == null) {
                var owned_listener = listener;
                owned_listener.close();
                return null;
            }
            tls = http1.TlsContext.init(std.mem.span(config.tls_cert_path), std.mem.span(config.tls_key_path), config.http2 != 0) catch {
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
            .backend_host = backend_host,
            .backend_path = backend_path,
            .backend_port = config.backend_port,
            .tls = tls,
            .http2_enabled = config.http2 != 0,
        };
        if (config.http3 != 0 and tls != null) {
            server.http3 = proxy_http3.Runtime(ProxyServer).create(server, std.mem.span(config.tls_cert_path), std.mem.span(config.tls_key_path)) catch {
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

    pub fn stop(self: *ProxyServer) void {
        if (self.stopped.swap(true, .acq_rel)) return;
        self.listener.close();
        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }
        while (self.active_connections.load(.acquire) != 0) {
            std.atomic.spinLoopHint();
        }
        if (self.http3) |runtime| runtime.deinit();
        self.queue.deinit();
        self.allocator.destroy(self.queue);
        self.pending_mutex.lock();
        var pending_it = self.pending.valueIterator();
        while (pending_it.next()) |response| {
            for (response.frames.items) |frame| self.allocator.free(frame);
            response.frames.deinit(self.allocator);
        }
        self.pending.deinit();
        self.pending_mutex.unlock();
        self.allocator.free(@constCast(self.backend_host));
        self.allocator.free(@constCast(self.backend_path));
        if (self.tls) |*context| context.deinit();
        self.allocator.destroy(self);
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
        while (!self.stopped.load(.acquire)) {
            var connection = http1.accept(self.listener.fd) catch {
                if (self.stopped.load(.acquire)) break;
                continue;
            };
            if (self.tls) |*context| {
                connection.acceptTls(context) catch {
                    connection.close();
                    continue;
                };
            }
            _ = self.active_connections.fetchAdd(1, .acq_rel);
            const thread = std.Thread.spawn(.{}, connectionLoop, .{ self, connection }) catch {
                connection.close();
                _ = self.active_connections.fetchSub(1, .acq_rel);
                continue;
            };
            thread.detach();
        }
    }

    fn connectionLoop(self: *ProxyServer, connection: http1.Connection) void {
        var owned_connection = connection;
        defer {
            owned_connection.close();
            _ = self.active_connections.fetchSub(1, .acq_rel);
        }

        if (self.http2_enabled and (owned_connection.isH2() or owned_connection.hasHttp2Preface())) {
            proxy_http2.serve(self.allocator, self, &owned_connection) catch {};
            return;
        }
        while (!self.stopped.load(.acquire)) {
            const keep_alive = proxy_http1.serveConnection(self.allocator, self, &owned_connection) catch |err| {
                if (err == error.InvalidRequest) break;
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
        self.pending.put(request_id, .{}) catch return false;
        return true;
    }

    pub fn pushResponse(self: *ProxyServer, request_id: u64, payload: [*]const u8, payload_len: u64) bool {
        if (self.stopped.load(.acquire) or payload_len > event_queue.max_queued_bytes) {
            return false;
        }
        const length: usize = @intCast(payload_len);
        const copy = self.allocator.dupe(u8, payload[0..length]) catch return false;
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        const response = self.pending.getPtr(request_id) orelse {
            self.allocator.free(copy);
            return false;
        };
        response.frames.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return false;
        };
        return true;
    }

    // The connection owns pending state until discardRequest, including after
    // response_end when an upgraded connection continues exchanging tunnel frames.
    pub fn takeResponse(self: *ProxyServer, request_id: u64) ?[]u8 {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        const response = self.pending.getPtr(request_id) orelse return null;
        if (response.frames.items.len != 0) {
            return response.frames.orderedRemove(0);
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
            for (response.frames.items) |frame| self.allocator.free(frame);
            response.frames.deinit(self.allocator);
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
