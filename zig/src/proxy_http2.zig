const std = @import("std");
const http2 = @import("http2.zig");
const http1 = @import("http1.zig").posix;

const shared = @import("proxy_request.zig");
const Request = shared.Request;

const State = struct {
    allocator: std.mem.Allocator,
    requests: std.AutoHashMap(i32, *Request),

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
            },
            .headers_end => |stream| {
                if (self.requests.get(stream)) |request| request.headers_ready = true;
            },
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
            // Protocol errors and peer EOF bypass normal stream retirement.
            // Complete pending bridge framing before closing its private socket.
            for (0..8) |_| {
                if (shared.finishCancelledRequest(server, request.*) catch true) break;
            }
            if (request.*.request_id) |id| server.discardRequest(id);
            request.*.deinit();
        }
        state.requests.deinit();
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
            if (!(shared.finishCancelledRequest(server, request) catch true)) continue;
            try retired.append(allocator, stream);
            continue;
        }
        if (!request.headers_ready) continue;
        request.response_paused = request.response.body.items.len >= 256 * 1024;
        shared.progressRequest(allocator, server, request) catch {
            try session.reset(stream, http2.c.NGHTTP2_INTERNAL_ERROR);
            try retired.append(allocator, stream);
            continue;
        };
        if (request.consumed_body != 0) {
            try session.consume(stream, request.consumed_body);
            request.consumed_body = 0;
        }
        if (request.response_submitted) {
            if (request.response.body.items.len != 0 or request.response_done) try session.resumeResponse(stream);
            continue;
        }
        if (!request.response.ready) continue;
        var headers: std.ArrayList(http2.Header) = .empty;
        defer headers.deinit(allocator);
        for (request.response.headers.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "connection") or
                std.ascii.eqlIgnoreCase(header.name, "transfer-encoding") or
                std.ascii.eqlIgnoreCase(header.name, "keep-alive") or
                std.ascii.eqlIgnoreCase(header.name, "upgrade")) continue;
            try headers.append(allocator, .{ .name = header.name, .value = header.value });
        }
        session.respondStreaming(stream, request.response.status, headers.items, .{ .context = request, .read = readResponse }) catch |err| {
            if (err == error.Backpressure) continue;
            try session.reset(stream, http2.c.NGHTTP2_INTERNAL_ERROR);
            continue;
        };
        request.response_submitted = true;
    }
    for (retired.items) |stream| {
        const request = state.requests.fetchRemove(stream).?.value;
        if (request.request_id) |id| server.discardRequest(id);
        request.deinit();
    }
}

fn readResponse(context: *anyopaque, output: []u8, done: *bool) usize {
    const request: *Request = @ptrCast(@alignCast(context));
    const body = &request.response.body;
    const count = @min(output.len, body.items.len);
    @memcpy(output[0..count], body.items[0..count]);
    const remaining = body.items.len - count;
    std.mem.copyForwards(u8, body.items[0..remaining], body.items[count..]);
    body.items.len = remaining;
    done.* = request.response_done and remaining == 0;
    return count;
}
