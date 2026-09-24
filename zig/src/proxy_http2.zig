const std = @import("std");
const http2 = @import("http2.zig");
const bridge_protocol = @import("bridge_protocol.zig");
const bridge_io = @import("bridge_io.zig");
const http1 = @import("http1.zig").posix;

const Request = struct {
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

    fn deinit(self: *Request) void {
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

const Credit = struct { stream: i32, count: usize };

const State = struct {
    allocator: std.mem.Allocator,
    requests: std.AutoHashMap(i32, *Request),
    credits: std.ArrayList(Credit) = .empty,

    fn emit(context: *anyopaque, event: http2.Event) bool {
        const self: *State = @ptrCast(@alignCast(context));
        switch (event) {
            .headers_begin => |stream| {
                if (!self.requests.contains(stream)) {
                    const request = self.allocator.create(Request) catch return false;
                    request.* = .{ .allocator = self.allocator };
                    self.requests.put(stream, request) catch {
                        request.deinit();
                        return false;
                    };
                }
            },
            .header => |header| {
                const request = self.requests.get(header.stream) orelse return false;
                const name = self.allocator.dupe(u8, header.field.name) catch return false;
                const value = self.allocator.dupe(u8, header.field.value) catch {
                    self.allocator.free(name);
                    return false;
                };
                if (std.mem.eql(u8, name, ":method")) {
                    self.allocator.free(request.method);
                    request.method = value;
                    self.allocator.free(name);
                } else if (std.mem.eql(u8, name, ":scheme")) {
                    self.allocator.free(request.scheme);
                    request.scheme = value;
                    self.allocator.free(name);
                } else if (std.mem.eql(u8, name, ":authority")) {
                    self.allocator.free(request.authority);
                    request.authority = value;
                    self.allocator.free(name);
                } else if (std.mem.eql(u8, name, ":path")) {
                    self.allocator.free(request.path);
                    request.path = value;
                    self.allocator.free(name);
                } else {
                    request.headers.append(self.allocator, .{ .name = name, .value = value }) catch {
                        self.allocator.free(name);
                        self.allocator.free(value);
                        return false;
                    };
                }
            },
            .data => |data| {
                const request = self.requests.get(data.stream) orelse return false;
                if (data.bytes.len > 32 * 1024 * 1024 -| request.body.items.len) return false;
                request.body.appendSlice(self.allocator, data.bytes) catch return false;
                self.credits.append(self.allocator, .{ .stream = data.stream, .count = data.bytes.len }) catch return false;
            },
            .headers_end => {},
            .end_stream => |stream| {
                const request = self.requests.get(stream) orelse return false;
                request.ended = true;
            },
            .closed => |closed| {
                if (self.requests.get(closed.stream)) |request| request.cancelled = true;
            },
        }
        return true;
    }
};

pub fn serve(allocator: std.mem.Allocator, server: anytype, connection: *http1.Connection) !void {
    var state = State{
        .allocator = allocator,
        .requests = std.AutoHashMap(i32, *Request).init(allocator),
    };
    defer {
        var iterator = state.requests.valueIterator();
        while (iterator.next()) |request| {
            if (request.*.request_id) |id| server.discardRequest(id);
            request.*.deinit();
        }
        state.requests.deinit();
        state.credits.deinit(allocator);
    }
    var session = try http2.Session.create(allocator, .{ .context = @ptrCast(&state), .emit = State.emit }, .{});
    defer session.destroy();

    var input: [16 * 1024]u8 = undefined;
    while (!server.stopped.load(.acquire)) {
        try flushOutput(session, connection);
        if (session.finished()) return;
        if (try http1.receiveTimeoutConnection(connection, &input, 5)) |count| {
            if (count == 0) return;
            _ = try session.receive(input[0..count]);
        }
        for (state.credits.items) |credit| try session.consume(credit.stream, credit.count);
        state.credits.clearRetainingCapacity();
        if (!session.terminating) try dispatchReady(allocator, server, session, &state);
        try flushOutput(session, connection);
    }
}

fn flushOutput(session: *http2.Session, connection: *http1.Connection) !void {
    while (true) {
        const bytes = try session.output();
        if (bytes.len == 0) return;
        try http1.sendAllConnection(connection, bytes);
    }
}

fn dispatchReady(allocator: std.mem.Allocator, server: anytype, session: *http2.Session, state: *State) !void {
    var retired: std.ArrayList(i32) = .empty;
    defer retired.deinit(allocator);
    var iterator = state.requests.iterator();
    while (iterator.next()) |entry| {
        const stream = entry.key_ptr.*;
        const request = entry.value_ptr.*;
        if (request.cancelled) {
            // A dispatched Dart request body still needs its terminal event.
            if (request.request_id) |id| {
                if (request.direct_stage != .start and request.direct_stage != .waiting) {
                    var end: [2]u8 = undefined;
                    _ = try bridge_protocol.encodeTerminal(.request_end, &end);
                    server.queue.push(@bitCast(id), &end) catch |err| {
                        if (err == error.QueueFull) continue;
                        return err;
                    };
                }
            }
            try retired.append(allocator, stream);
            continue;
        }
        if (!request.ended) continue;
        progressRequest(allocator, server, request) catch {
            try session.reset(stream, http2.c.NGHTTP2_INTERNAL_ERROR);
            try retired.append(allocator, stream);
            continue;
        };
        if (!request.response_done or (request.request_id != null and request.direct_stage != .waiting)) continue;
        var headers: std.ArrayList(http2.Header) = .empty;
        defer headers.deinit(allocator);
        for (request.response.headers.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "connection") or
                std.ascii.eqlIgnoreCase(header.name, "transfer-encoding") or
                std.ascii.eqlIgnoreCase(header.name, "keep-alive") or
                std.ascii.eqlIgnoreCase(header.name, "upgrade")) continue;
            try headers.append(allocator, .{ .name = header.name, .value = header.value });
        }
        session.respond(stream, request.response.status, headers.items, request.response.body.items) catch |err| {
            if (err == error.Backpressure) continue;
            try session.reset(stream, http2.c.NGHTTP2_INTERNAL_ERROR);
        };
        try retired.append(allocator, stream);
    }
    for (retired.items) |stream| {
        const request = state.requests.fetchRemove(stream).?.value;
        if (request.request_id) |id| server.discardRequest(id);
        request.deinit();
    }
}

fn requestHead(request: *Request) bridge_protocol.RequestHead {
    return .{
        .method = request.method,
        .scheme = if (request.scheme.len == 0) "https" else request.scheme,
        .authority = request.authority,
        .path = if (request.path.len == 0) "/" else if (std.mem.indexOfScalar(u8, request.path, '?')) |index| request.path[0..index] else request.path,
        .query = if (std.mem.indexOfScalar(u8, request.path, '?')) |index| request.path[index + 1 ..] else "",
        .protocol = "HTTP/2",
        .headers = request.headers.items,
    };
}

// Each pass does bounded work per stream; a pending Dart handler never owns
// the connection's receive loop. Only that loop calls the nghttp2 session.
fn progressRequest(allocator: std.mem.Allocator, server: anytype, request: *Request) !void {
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
}
