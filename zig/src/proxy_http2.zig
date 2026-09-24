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

    fn deinit(self: *Request) void {
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
                request.body.appendSlice(self.allocator, data.bytes) catch return false;
                self.credits.append(self.allocator, .{ .stream = data.stream, .count = data.bytes.len }) catch return false;
            },
            .headers_end => {},
            .end_stream => |stream| {
                const request = self.requests.get(stream) orelse return false;
                request.ended = true;
            },
            .closed => |closed| {
                if (self.requests.fetchRemove(closed.stream)) |entry| entry.value.deinit();
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
        while (iterator.next()) |request| request.*.deinit();
        state.requests.deinit();
        state.credits.deinit(allocator);
    }
    var session = try http2.Session.create(allocator, .{ .context = @ptrCast(&state), .emit = State.emit }, .{});
    defer session.destroy();

    var input: [16 * 1024]u8 = undefined;
    while (!server.stopped.load(.acquire)) {
        try flushOutput(session, connection);
        if (session.finished()) return;
        const count = try http1.receiveConnection(connection, &input);
        if (count == 0) return;
        _ = try session.receive(input[0..count]);
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
    var ready: std.ArrayList(i32) = .empty;
    defer ready.deinit(allocator);
    var iterator = state.requests.iterator();
    while (iterator.next()) |entry| if (entry.value_ptr.*.ended) try ready.append(allocator, entry.key_ptr.*);

    for (ready.items) |stream| {
        const request = state.requests.fetchRemove(stream) orelse continue;
        defer request.value.deinit();
        var response = if (server.bridgeEnabled())
            try bridgeRequest(allocator, server, request.value)
        else
            try directRequest(allocator, server, request.value);
        defer response.deinit(allocator);
        var headers: std.ArrayList(http2.Header) = .empty;
        defer headers.deinit(allocator);
        for (response.headers.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "connection") or
                std.ascii.eqlIgnoreCase(header.name, "transfer-encoding") or
                std.ascii.eqlIgnoreCase(header.name, "keep-alive") or
                std.ascii.eqlIgnoreCase(header.name, "upgrade")) continue;
            try headers.append(allocator, .{ .name = header.name, .value = header.value });
        }
        try session.respond(stream, response.status, headers.items, response.body.items);
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

fn directRequest(allocator: std.mem.Allocator, server: anytype, request: *Request) !bridge_io.Response {
    var response = bridge_io.Response{};
    const request_id = server.next_request_id.fetchAdd(1, .monotonic);
    if (!server.registerRequest(request_id)) return error.RequestQueueClosed;
    defer server.discardRequest(request_id);
    const head = requestHead(request);
    const start = try allocator.alloc(u8, try bridge_protocol.requestStartEncodedSize(head));
    defer allocator.free(start);
    _ = try bridge_protocol.encodeRequestStart(head, start);
    try server.queue.push(@bitCast(request_id), start);
    if (request.body.items.len != 0) {
        const chunk = try allocator.alloc(u8, 6 + request.body.items.len);
        defer allocator.free(chunk);
        _ = try bridge_protocol.encodeChunk(.request_chunk, request.body.items, chunk);
        try server.queue.push(@bitCast(request_id), chunk);
    }
    var end: [2]u8 = undefined;
    _ = try bridge_protocol.encodeTerminal(.request_end, &end);
    try server.queue.push(@bitCast(request_id), &end);
    var done = false;
    while (!done and !server.stopped.load(.acquire)) {
        const frame = server.takeResponse(request_id) orelse {
            std.atomic.spinLoopHint();
            continue;
        };
        defer allocator.free(frame);
        try bridge_io.decodeResponseFrame(allocator, frame, &response, &done);
    }
    if (!done) return error.ResponseUnavailable;
    return response;
}

fn bridgeRequest(allocator: std.mem.Allocator, server: anytype, request: *Request) !bridge_io.Response {
    var response = bridge_io.Response{};
    var backend = try server.connectBackend();
    defer backend.close();
    const head = requestHead(request);
    const start_size = try bridge_protocol.requestStartEncodedSize(head);
    const payload = try allocator.alloc(u8, start_size + 4 + request.body.items.len);
    defer allocator.free(payload);
    _ = try bridge_protocol.encodeRequest(head, request.body.items, payload);
    try bridge_io.sendFrame(allocator, backend.fd, payload);

    var done = false;
    while (!done) {
        const frame = try bridge_io.receiveFrame(allocator, backend.fd);
        defer allocator.free(frame);
        try bridge_io.decodeResponseFrame(allocator, frame, &response, &done);
    }
    return response;
}
