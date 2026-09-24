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
    ended: bool = false,
    cancelled: bool = false,
    started: bool = false,
    request_id: ?u64 = null,
    direct_stage: enum { start, body, end, waiting } = .start,
    body_offset: usize = 0,
    backend: ?http1.Connection = null,
    outgoing: []u8 = &.{},
    outgoing_offset: usize = 0,
    incoming: std.ArrayList(u8) = .empty,
    response: bridge_io.Response = .{},
    response_done: bool = false,

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
    if (request.response_done and (request.backend != null or request.direct_stage == .waiting)) return;
    if (!request.started) {
        const head = requestHead(request);
        const start_size = try bridge_protocol.requestStartEncodedSize(head);
        if (server.bridgeEnabled()) {
            request.backend = try server.connectBackend();
            request.outgoing = try allocator.alloc(u8, 8 + start_size + request.body.items.len);
            const payload = try bridge_protocol.encodeRequest(head, request.body.items, request.outgoing[4..]);
            std.mem.writeInt(u32, request.outgoing[0..4], @intCast(payload.len), .big);
        } else {
            const id = server.next_request_id.fetchAdd(1, .monotonic);
            if (!server.registerRequest(id)) return error.RequestQueueClosed;
            request.request_id = id;
            request.outgoing = try allocator.alloc(u8, start_size);
            _ = try bridge_protocol.encodeRequestStart(head, request.outgoing);
        }
        request.started = true;
    }
    if (request.backend) |*backend| {
        if (request.outgoing_offset < request.outgoing.len) {
            const remaining = request.outgoing[request.outgoing_offset..];
            const count = (try http1.sendNonblocking(backend.fd, remaining[0..@min(remaining.len, 16384)])) orelse return;
            request.outgoing_offset += count;
            if (request.outgoing_offset < request.outgoing.len) return;
            allocator.free(request.outgoing);
            request.outgoing = &.{};
            request.outgoing_offset = 0;
            request.body.clearAndFree(allocator);
        }
        var buffer: [16384]u8 = undefined;
        const count = (try http1.receiveTimeout(backend.fd, &buffer, 0)) orelse return;
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
    } else {
        const id = request.request_id.?;
        // Retry queue saturation on the next pass without duplicating frames.
        switch (request.direct_stage) {
            .start => {
                server.queue.push(@bitCast(id), request.outgoing) catch |err| {
                    if (err == error.QueueFull) return;
                    return err;
                };
                allocator.free(request.outgoing);
                request.outgoing = &.{};
                request.direct_stage = .body;
            },
            .body => {
                const remaining = request.body.items[request.body_offset..];
                if (remaining.len == 0) {
                    request.body.clearAndFree(allocator);
                    request.direct_stage = .end;
                } else {
                    var buffer: [16384 + 6]u8 = undefined;
                    const count = @min(remaining.len, 16384);
                    const payload = try bridge_protocol.encodeChunk(.request_chunk, remaining[0..count], &buffer);
                    server.queue.push(@bitCast(id), payload) catch |err| {
                        if (err == error.QueueFull) return;
                        return err;
                    };
                    request.body_offset += count;
                }
            },
            .end => {
                var end: [2]u8 = undefined;
                _ = try bridge_protocol.encodeTerminal(.request_end, &end);
                server.queue.push(@bitCast(id), &end) catch |err| {
                    if (err == error.QueueFull) return;
                    return err;
                };
                request.direct_stage = .waiting;
            },
            .waiting => {},
        }
        // Limit response draining so one producer cannot starve peer streams.
        for (0..16) |_| {
            if (request.response_done) break;
            const frame = server.takeResponse(id) orelse break;
            defer allocator.free(frame);
            try bridge_io.decodeResponseFrame(allocator, frame, &request.response, &request.response_done);
            if (request.response_done) break;
        }
    }
    if (request.response.body.items.len > 4 * 1024 * 1024) return error.ResponseTooLarge;
    if (request.response_done) try advertiseHttp3(allocator, server, &request.response);
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
