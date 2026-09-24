const std = @import("std");
const bridge_protocol = @import("bridge_protocol.zig");
const bridge_io = @import("bridge_io.zig");
const http1 = @import("http1.zig").posix;

pub const Request = struct {
    protocol: []const u8 = "HTTP/2",
    allocator: std.mem.Allocator,
    method: []u8 = &.{},
    scheme: []u8 = &.{},
    authority: []u8 = &.{},
    path: []u8 = &.{},
    headers: std.ArrayList(bridge_protocol.Header) = .empty,
    body: std.ArrayList(u8) = .empty,
    headers_ready: bool = false,
    ended: bool = false,
    cancelled: bool = false,
    started: bool = false,
    request_id: ?u64 = null,
    direct_stage: enum { start, body, end, waiting } = .start,
    consumed_body: usize = 0,
    uncredited_body: usize = 0,
    outgoing_body: usize = 0,
    response_submitted: bool = false,
    backend: ?http1.Connection = null,
    outgoing: []u8 = &.{},
    outgoing_offset: usize = 0,
    incoming: std.ArrayList(u8) = .empty,
    response: bridge_io.Response = .{},
    response_done: bool = false,
    response_paused: bool = false,

    pub fn deinit(self: *Request) void {
        if (self.backend) |*backend| backend.close();
        self.allocator.free(self.outgoing);
        self.incoming.deinit(self.allocator);
        self.response.deinit(self.allocator);
        self.allocator.free(self.method);
        self.allocator.free(self.scheme);
        self.allocator.free(self.authority);
        self.allocator.free(self.path);
        for (self.headers.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.headers.deinit(self.allocator);
        self.body.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

fn requestHead(request: *Request) bridge_protocol.RequestHead {
    return .{
        .method = request.method,
        .scheme = if (request.scheme.len == 0) "https" else request.scheme,
        .authority = request.authority,
        .path = if (request.path.len == 0) "/" else if (std.mem.indexOfScalar(u8, request.path, '?')) |index| request.path[0..index] else request.path,
        .query = if (std.mem.indexOfScalar(u8, request.path, '?')) |index| request.path[index + 1 ..] else "",
        .protocol = request.protocol,
        .headers = request.headers.items,
    };
}

// Each pass does bounded work per stream; a pending Dart handler never owns
// the connection's receive loop. Only that loop calls the nghttp2 session.
pub fn progressRequest(allocator: std.mem.Allocator, server: anytype, request: *Request) !void {
    if (request.request_id) |id| request.consumed_body += server.takeRequestCredit(id);
    if (!request.headers_ready) return;
    if (request.response_done and request.direct_stage == .waiting) return;
    if (!request.started) {
        const head = requestHead(request);
        const start_size = try bridge_protocol.requestStartEncodedSize(head);
        if (server.bridgeEnabled()) {
            request.backend = try server.connectBackend();
        } else {
            const id = server.next_request_id.fetchAdd(1, .monotonic);
            if (!server.registerRequest(id)) return error.RequestQueueClosed;
            request.request_id = id;
        }
        const prefix: usize = if (request.backend != null) 4 else 0;
        request.outgoing = try allocator.alloc(u8, prefix + start_size);
        _ = try bridge_protocol.encodeRequestStart(head, request.outgoing[prefix..]);
        if (prefix != 0) std.mem.writeInt(u32, request.outgoing[0..4], @intCast(start_size), .big);
        request.started = true;
    }
    // A single frame is retained across partial writes or queue saturation.
    // Read responses on every pass even when the request producer is blocked.
    if (request.outgoing.len == 0 and request.direct_stage == .body) {
        if (request.body.items.len != 0) {
            const count = @min(request.body.items.len, 16384);
            var buffer: [16390]u8 = undefined;
            const payload = try bridge_protocol.encodeChunk(.request_chunk, request.body.items[0..count], &buffer);
            try queueOutgoing(allocator, request, payload);
            request.outgoing_body = count;
            const remaining = request.body.items.len - count;
            std.mem.copyForwards(u8, request.body.items[0..remaining], request.body.items[count..]);
            request.body.items.len = remaining;
        } else if (request.ended) {
            var end: [2]u8 = undefined;
            _ = try bridge_protocol.encodeTerminal(.request_end, &end);
            try queueOutgoing(allocator, request, &end);
            request.direct_stage = .end;
        }
    }
    if (request.outgoing.len != 0) {
        var sent = false;
        if (request.backend) |backend| {
            const remaining = request.outgoing[request.outgoing_offset..];
            if (try http1.sendNonblocking(backend.fd, remaining[0..@min(remaining.len, 16384)])) |count| {
                if (count == 0) return error.ConnectionClosed;
                request.outgoing_offset += count;
                sent = request.outgoing_offset == request.outgoing.len;
            }
        } else {
            const id = request.request_id.?;
            if (server.reserveRequestBytes(id, request.outgoing_body)) {
                sent = true;
                server.queue.push(@bitCast(id), request.outgoing) catch |err| {
                    server.refundRequestBytes(id, request.outgoing_body);
                    if (err != error.QueueFull) return err;
                    sent = false;
                };
            }
        }
        if (sent) {
            allocator.free(request.outgoing);
            request.outgoing = &.{};
            request.outgoing_offset = 0;
            if (request.backend != null) request.consumed_body += request.outgoing_body;
            request.outgoing_body = 0;
            request.direct_stage = if (request.direct_stage == .end) .waiting else .body;
        }
    }
    if (!request.response_done and !request.response_paused) {
        if (request.backend) |backend| {
            var buffer: [16384]u8 = undefined;
            if (try http1.receiveTimeout(backend.fd, &buffer, 0)) |count| {
                if (count == 0) return error.ConnectionClosed;
                try request.incoming.appendSlice(allocator, buffer[0..count]);
                var consumed: usize = 0;
                while (request.incoming.items.len - consumed >= 4) {
                    const length = bridge_io.frameLength(request.incoming.items[consumed..][0..4]);
                    if (length > 4 * 1024 * 1024 + 65536) return error.ResponseTooLarge;
                    if (request.incoming.items.len - consumed < 4 + length) break;
                    try bridge_io.decodeResponseFrame(allocator, request.incoming.items[consumed + 4 ..][0..length], &request.response, &request.response_done);
                    consumed += 4 + length;
                }
                const remaining = request.incoming.items.len - consumed;
                std.mem.copyForwards(u8, request.incoming.items[0..remaining], request.incoming.items[consumed..]);
                request.incoming.items.len = remaining;
            }
        } else {
            for (0..16) |_| {
                if (request.response_done or request.response.body.items.len >= 256 * 1024) break;
                const frame = server.takeResponse(request.request_id.?) orelse break;
                defer server.allocator.free(frame);
                try bridge_io.decodeResponseFrame(allocator, frame, &request.response, &request.response_done);
            }
        }
    }
    if (request.response.body.items.len > 4 * 1024 * 1024) return error.ResponseTooLarge;
    if (request.response.ready) try advertiseHttp3(allocator, server, &request.response);
}

fn queueOutgoing(allocator: std.mem.Allocator, request: *Request, payload: []const u8) !void {
    const prefix: usize = if (request.backend != null) 4 else 0;
    request.outgoing = try allocator.alloc(u8, prefix + payload.len);
    @memcpy(request.outgoing[prefix..], payload);
    if (prefix != 0) std.mem.writeInt(u32, request.outgoing[0..4], @intCast(payload.len), .big);
}

/// Advertise only a live UDP listener, preserving an explicit application value.
pub fn advertiseHttp3(a: std.mem.Allocator, server: anytype, response: *bridge_io.Response) !void {
    if (server.http3 == null) return;
    for (response.headers.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "alt-svc")) return;
    }
    const name = try a.dupe(u8, "alt-svc");
    errdefer a.free(name);
    const value = try std.fmt.allocPrint(a, "h3=\":{d}\"; ma=86400", .{server.port});
    errdefer a.free(value);
    try response.headers.append(a, .{ .name = name, .value = value });
}

/// Finish a body already exposed to Dart before retiring a cancelled stream.
/// Queue saturation is retried by the connection owner on its next turn.
pub fn finishCancelledRequest(server: anytype, request: *Request) !bool {
    if (request.backend) |backend| {
        if (request.direct_stage == .waiting) return true;
        // Complete a partially written frame before sending the terminal frame.
        if (request.outgoing.len != 0) {
            const count = (try http1.sendNonblocking(backend.fd, request.outgoing[request.outgoing_offset..])) orelse return false;
            if (count == 0) return error.ConnectionClosed;
            request.outgoing_offset += count;
            if (request.outgoing_offset != request.outgoing.len) return false;
            request.allocator.free(request.outgoing);
            request.outgoing = &.{};
            request.outgoing_offset = 0;
            if (request.direct_stage == .end) {
                request.direct_stage = .waiting;
                return true;
            }
        }
        var end: [2]u8 = undefined;
        _ = try bridge_protocol.encodeTerminal(.request_end, &end);
        try queueOutgoing(request.allocator, request, &end);
        request.direct_stage = .end;
        return false;
    }
    if (request.request_id) |id| {
        if (request.direct_stage != .start and request.direct_stage != .waiting) {
            var end: [2]u8 = undefined;
            _ = try bridge_protocol.encodeTerminal(.request_end, &end);
            server.queue.push(@bitCast(id), &end) catch |err| {
                if (err == error.QueueFull) return false;
                return err;
            };
            request.direct_stage = .waiting;
        }
    }
    return true;
}

test "shared request framing preserves HTTP3 protocol and query" {
    var request: Request = .{ .allocator = std.testing.allocator, .protocol = "HTTP/3" };
    request.path = try std.testing.allocator.dupe(u8, "/echo?q=a%20b&q=c");
    defer std.testing.allocator.free(request.path);
    const head = requestHead(&request);
    try std.testing.expectEqualStrings("HTTP/3", head.protocol);
    try std.testing.expectEqualStrings("/echo", head.path);
    try std.testing.expectEqualStrings("q=a%20b&q=c", head.query);
}

test "Alt-Svc exists only for live HTTP3 and preserves application override" {
    const FakeServer = struct { http3: ?u8, port: u16 };
    var response = bridge_io.Response{};
    defer response.deinit(std.testing.allocator);
    var server: FakeServer = .{ .http3 = null, .port = 8443 };
    try advertiseHttp3(std.testing.allocator, &server, &response);
    try std.testing.expectEqual(@as(usize, 0), response.headers.items.len);
    server.http3 = 1;
    try advertiseHttp3(std.testing.allocator, &server, &response);
    try std.testing.expectEqualStrings("h3=\":8443\"; ma=86400", response.headers.items[0].value);
    server.port = 9443;
    try advertiseHttp3(std.testing.allocator, &server, &response);
    try std.testing.expectEqual(@as(usize, 1), response.headers.items.len);
    try std.testing.expectEqualStrings("h3=\":8443\"; ma=86400", response.headers.items[0].value);
}

test "cancelled request terminal is retried under queue pressure without duplicates" {
    const Queue = @import("event_queue.zig").Queue;
    var queue = try Queue.init(std.testing.allocator, 1);
    defer queue.deinit();
    var server = .{ .queue = &queue };
    var request: Request = .{ .allocator = std.testing.allocator, .request_id = 7, .direct_stage = .body };
    try queue.push(9, "busy");
    try std.testing.expect(!try finishCancelledRequest(&server, &request));
    const busy = queue.pop().?;
    queue.release(busy);
    try std.testing.expect(try finishCancelledRequest(&server, &request));
    try std.testing.expect(try finishCancelledRequest(&server, &request));
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    const end = queue.pop().?;
    defer queue.release(end);
    try std.testing.expectEqual(@as(i64, 7), end.request_id);
    try std.testing.expectEqualSlices(u8, &.{ 1, 5 }, end.payload);
}

test "progressive direct request waits for queue capacity and never invents EOF" {
    const Queue = @import("event_queue.zig").Queue;
    const Fake = struct {
        queue: *Queue,
        allocator: std.mem.Allocator = std.testing.allocator,
        next_request_id: std.atomic.Value(u64) = .init(1),
        http3: ?u8 = null,
        port: u16 = 0,
        outstanding: usize = 0,
        credit: usize = 0,
        pub fn bridgeEnabled(_: *@This()) bool {
            return false;
        }
        pub fn connectBackend(_: *@This()) !http1.Connection {
            return error.Unexpected;
        }
        pub fn registerRequest(_: *@This(), _: u64) bool {
            return true;
        }
        pub fn reserveRequestBytes(self: *@This(), _: u64, n: usize) bool {
            self.outstanding += n;
            return true;
        }
        pub fn refundRequestBytes(self: *@This(), _: u64, n: usize) void {
            self.outstanding -= n;
        }
        pub fn takeRequestCredit(self: *@This(), _: u64) usize {
            const n = self.credit;
            self.credit = 0;
            return n;
        }
        pub fn takeResponse(_: *@This(), _: u64) ?[]u8 {
            return null;
        }
    };
    const a = std.testing.allocator;
    var queue = try Queue.init(a, 1);
    defer queue.deinit();
    var server: Fake = .{ .queue = &queue };
    const request = try a.create(Request);
    request.* = .{ .allocator = a, .headers_ready = true };
    defer request.deinit();
    try progressRequest(a, &server, request);
    try request.body.appendSlice(a, "abc");
    try progressRequest(a, &server, request);
    try std.testing.expectEqual(@as(usize, 0), request.consumed_body);
    const start = queue.pop().?;
    queue.release(start);
    try progressRequest(a, &server, request);
    try std.testing.expectEqual(@as(usize, 0), request.consumed_body);
    try std.testing.expectEqual(@as(usize, 3), server.outstanding);
    server.credit = 3;
    try progressRequest(a, &server, request);
    try std.testing.expectEqual(@as(usize, 3), request.consumed_body);
    const chunk = queue.pop().?;
    defer queue.release(chunk);
    try std.testing.expectEqualSlices(u8, &.{ 1, 4, 0, 0, 0, 3, 'a', 'b', 'c' }, chunk.payload);
    for (0..3) |_| try progressRequest(a, &server, request);
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    request.ended = true;
    try progressRequest(a, &server, request);
    const end = queue.pop().?;
    defer queue.release(end);
    try std.testing.expectEqualSlices(u8, &.{ 1, 5 }, end.payload);
    try progressRequest(a, &server, request);
    try std.testing.expectEqual(@as(usize, 0), queue.count());
}

test "bridge cancellation completes a partial frame before its terminal" {
    const c = @cImport({
        @cInclude("sys/socket.h");
        @cInclude("unistd.h");
    });
    const a = std.testing.allocator;
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    const request = try a.create(Request);
    request.* = .{ .allocator = a, .backend = .{ .fd = fds[0] }, .direct_stage = .body };
    defer request.deinit();
    var queue = try @import("event_queue.zig").Queue.init(a, 1);
    defer queue.deinit();
    var server = .{ .queue = &queue };
    try queueOutgoing(a, request, &.{ 1, 4, 0, 0, 0, 1, 'x' });
    try http1.sendAll(fds[0], request.outgoing[0..3]);
    request.outgoing_offset = 3;
    try std.testing.expect(!try finishCancelledRequest(&server, request));
    try std.testing.expect(try finishCancelledRequest(&server, request));
    try std.testing.expect(try finishCancelledRequest(&server, request));
    const chunk = try bridge_io.receiveFrame(a, fds[1]);
    defer a.free(chunk);
    try std.testing.expectEqualSlices(u8, &.{ 1, 4, 0, 0, 0, 1, 'x' }, chunk);
    const end = try bridge_io.receiveFrame(a, fds[1]);
    defer a.free(end);
    try std.testing.expectEqualSlices(u8, &.{ 1, 5 }, end);
    var extra: [1]u8 = undefined;
    try std.testing.expect((try http1.receiveTimeout(fds[1], &extra, 0)) == null);
}
