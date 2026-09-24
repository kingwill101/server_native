//! Internal, single-thread-owned HTTP/2 server sessions. No socket or Dart ABI.
const std = @import("std");
pub const c = @cImport({
    @cInclude("nghttp2/nghttp2.h");
});
pub const Header = struct { name: []const u8, value: []const u8 };
pub const Event = union(enum) {
    headers_begin: i32,
    header: struct { stream: i32, field: Header },
    headers_end: i32,
    data: struct { stream: i32, bytes: []const u8 },
    end_stream: i32,
    closed: struct { stream: i32, code: u32 },
};
/// Event slices are borrowed for the callback only. Do not reenter the session.
/// Returning false fails the connection; withhold read/consume for backpressure.
pub const Sink = struct { context: *anyopaque, emit: *const fn (*anyopaque, Event) bool };
pub const Error = error{ OutOfMemory, NativeFailure, Closed, SinkFailed, InvalidArgument, ResponsePending, Backpressure };
pub const Limits = struct { max_streams: u32 = 100, receive_window: u32 = 65535, response_bytes: usize = 4 * 1024 * 1024 };

pub const Session = struct {
    allocator: std.mem.Allocator,
    native: ?*c.nghttp2_session = null,
    sink: Sink,
    limits: Limits,
    bodies: std.AutoHashMap(i32, *Body),
    queued_bytes: usize = 0,
    failed: bool = false,
    sink_failed: bool = false,
    last_error: c_int = 0,
    const Body = struct { bytes: []u8, offset: usize = 0 };

    /// Allocated at a stable address because nghttp2 retains our callback context.
    pub fn create(allocator: std.mem.Allocator, sink: Sink, limits: Limits) Error!*Session {
        if (limits.max_streams == 0 or limits.receive_window > 0x7fffffff) return error.InvalidArgument;
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .sink = sink, .limits = limits, .bodies = .init(allocator) };
        var callbacks: ?*c.nghttp2_session_callbacks = null;
        try self.check(c.nghttp2_session_callbacks_new(&callbacks));
        defer c.nghttp2_session_callbacks_del(callbacks);
        c.nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, onBegin);
        c.nghttp2_session_callbacks_set_on_header_callback(callbacks, onHeader);
        c.nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, onFrame);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, onData);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, onClose);
        var option: ?*c.nghttp2_option = null;
        try self.check(c.nghttp2_option_new(&option));
        defer c.nghttp2_option_del(option);
        c.nghttp2_option_set_no_auto_window_update(option, 1);
        try self.check(c.nghttp2_session_server_new2(&self.native, callbacks, self, option));
        errdefer c.nghttp2_session_del(self.native);
        var settings = [_]c.nghttp2_settings_entry{
            .{ .settings_id = c.NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, .value = limits.max_streams },
            .{ .settings_id = c.NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, .value = limits.receive_window },
        };
        try self.check(c.nghttp2_submit_settings(self.native, 0, &settings, settings.len));
        return self;
    }

    pub fn destroy(self: *Session) void {
        c.nghttp2_session_del(self.native);
        var iter = self.bodies.valueIterator();
        while (iter.next()) |body| self.freeBody(body.*);
        self.bodies.deinit();
        self.allocator.destroy(self);
    }

    pub fn receive(self: *Session, bytes: []const u8) Error!usize {
        try self.alive();
        const count = c.nghttp2_session_mem_recv2(self.native, bytes.ptr, bytes.len);
        if (count < 0) {
            self.failed = true;
            try self.check(@intCast(count));
        }
        return @intCast(count);
    }

    /// Borrowed output must be written/copied before calling another session method.
    pub fn output(self: *Session) Error![]const u8 {
        try self.alive();
        var bytes: [*c]const u8 = null;
        const count = c.nghttp2_session_mem_send2(self.native, &bytes);
        if (count < 0) {
            self.failed = true;
            try self.check(@intCast(count));
        }
        if (count == 0) return &.{};
        return bytes[0..@intCast(count)];
    }

    /// Return receive-window credit only after the application consumes DATA.
    pub fn consume(self: *Session, stream: i32, count: usize) Error!void {
        try self.alive();
        try self.check(c.nghttp2_session_consume(self.native, stream, count));
    }

    /// Copies a finite response body. Memory is bounded across all active streams.
    /// Streaming response producers will be added when the transport is attached.
    pub fn respond(self: *Session, stream: i32, status: u16, headers: []const Header, bytes: []const u8) Error!void {
        try self.alive();
        if (stream <= 0 or status < 200 or status > 599 or headers.len > 128) return error.InvalidArgument;
        if (self.bodies.contains(stream)) return error.ResponsePending;
        if (c.nghttp2_session_get_stream_local_close(self.native, stream) != 0) return error.InvalidArgument;
        if ((status == 204 or status == 304) and bytes.len != 0) return error.InvalidArgument;
        if (bytes.len > self.limits.response_bytes - self.queued_bytes) return error.Backpressure;
        for (headers) |header| {
            if (header.name.len == 0 or header.name[0] == ':') return error.InvalidArgument;
        }
        const body = try self.allocator.create(Body);
        errdefer self.allocator.destroy(body);
        body.* = .{ .bytes = try self.allocator.dupe(u8, bytes) };
        errdefer self.allocator.free(body.bytes);
        try self.bodies.put(stream, body);
        errdefer _ = self.bodies.remove(stream);
        const fields = try self.allocator.alloc(c.nghttp2_nv, headers.len + 1);
        defer self.allocator.free(fields);
        var status_buf: [3]u8 = undefined;
        const status_text = std.fmt.bufPrint(&status_buf, "{d}", .{status}) catch unreachable;
        fields[0] = nv(.{ .name = ":status", .value = status_text });
        for (headers, fields[1..]) |header, *field| field.* = nv(header);
        var provider = c.nghttp2_data_provider2{ .source = .{ .ptr = body }, .read_callback = readBody };
        try self.check(c.nghttp2_submit_response2(self.native, stream, fields.ptr, fields.len, &provider));
        self.queued_bytes += bytes.len;
    }

    pub fn reset(self: *Session, stream: i32, code: u32) Error!void {
        try self.alive();
        try self.check(c.nghttp2_submit_rst_stream(self.native, 0, stream, code));
    }

    pub fn shutdown(self: *Session) Error!void {
        try self.alive();
        try self.check(c.nghttp2_submit_goaway(self.native, 0, c.nghttp2_session_get_last_proc_stream_id(self.native), c.NGHTTP2_NO_ERROR, null, 0));
    }

    fn alive(self: *Session) Error!void {
        if (self.failed) return error.Closed;
    }
    fn check(self: *Session, result: c_int) Error!void {
        if (result >= 0) return;
        self.last_error = result;
        if (self.sink_failed) return error.SinkFailed;
        if (result == c.NGHTTP2_ERR_NOMEM) return error.OutOfMemory;
        return error.NativeFailure;
    }
    fn freeBody(self: *Session, body: *Body) void {
        self.allocator.free(body.bytes);
        self.allocator.destroy(body);
    }
    fn emit(self: *Session, event: Event) c_int {
        if (self.sink.emit(self.sink.context, event)) return 0;
        self.sink_failed = true;
        return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    }
    fn from(data: ?*anyopaque) *Session {
        return @ptrCast(@alignCast(data.?));
    }
    fn onBegin(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, data: ?*anyopaque) callconv(.c) c_int {
        return from(data).emit(.{ .headers_begin = frame.*.hd.stream_id });
    }
    fn onHeader(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, name: [*c]const u8, namelen: usize, value: [*c]const u8, valuelen: usize, _: u8, data: ?*anyopaque) callconv(.c) c_int {
        return from(data).emit(.{ .header = .{ .stream = frame.*.hd.stream_id, .field = .{ .name = name[0..namelen], .value = value[0..valuelen] } } });
    }
    fn onFrame(_: ?*c.nghttp2_session, frame: [*c]const c.nghttp2_frame, data: ?*anyopaque) callconv(.c) c_int {
        const self = from(data);
        const hd = frame.*.hd;
        if (hd.type == c.NGHTTP2_HEADERS) {
            const result = self.emit(.{ .headers_end = hd.stream_id });
            if (result != 0) return result;
        }
        if ((hd.type == c.NGHTTP2_HEADERS or hd.type == c.NGHTTP2_DATA) and hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0)
            return self.emit(.{ .end_stream = hd.stream_id });
        return 0;
    }
    fn onData(_: ?*c.nghttp2_session, _: u8, stream: i32, bytes: [*c]const u8, len: usize, data: ?*anyopaque) callconv(.c) c_int {
        return from(data).emit(.{ .data = .{ .stream = stream, .bytes = bytes[0..len] } });
    }
    fn onClose(_: ?*c.nghttp2_session, stream: i32, code: u32, data: ?*anyopaque) callconv(.c) c_int {
        const self = from(data);
        if (self.bodies.fetchRemove(stream)) |entry| {
            self.queued_bytes -= entry.value.bytes.len;
            self.freeBody(entry.value);
        }
        return self.emit(.{ .closed = .{ .stream = stream, .code = code } });
    }
    fn readBody(_: ?*c.nghttp2_session, _: i32, buffer: [*c]u8, len: usize, flags: [*c]u32, source: [*c]c.nghttp2_data_source, _: ?*anyopaque) callconv(.c) c.nghttp2_ssize {
        const body: *Body = @ptrCast(@alignCast(source.*.ptr.?));
        const count = @min(len, body.bytes.len - body.offset);
        @memcpy(buffer[0..count], body.bytes[body.offset..][0..count]);
        body.offset += count;
        if (body.offset == body.bytes.len) flags.* |= c.NGHTTP2_DATA_FLAG_EOF;
        return @intCast(count);
    }
};

pub fn nv(header: Header) c.nghttp2_nv {
    return .{ .name = @constCast(header.name.ptr), .namelen = header.name.len, .value = @constCast(header.value.ptr), .valuelen = header.value.len, .flags = c.NGHTTP2_NV_FLAG_NONE };
}

const Probe = struct {
    headers: usize = 0,
    ends: usize = 0,
    closed: usize = 0,
    data_bytes: usize = 0,
    reject: bool = false,
    fn emit(context: *anyopaque, event: Event) bool {
        const self: *Probe = @ptrCast(@alignCast(context));
        if (self.reject) return false;
        switch (event) {
            .header => self.headers += 1,
            .end_stream => self.ends += 1,
            .closed => self.closed += 1,
            .data => |data| self.data_bytes += data.bytes.len,
            else => {},
        }
        return true;
    }
    fn sink(self: *Probe) Sink {
        return .{ .context = self, .emit = emit };
    }
};
const Client = struct {
    fragment_size: usize = 3,
    native: ?*c.nghttp2_session = null,
    received: std.ArrayList(u8) = .empty,
    statuses: usize = 0,
    fn init(self: *Client) !void {
        var callbacks: ?*c.nghttp2_session_callbacks = null;
        try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_session_callbacks_new(&callbacks));
        defer c.nghttp2_session_callbacks_del(callbacks);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, data);
        c.nghttp2_session_callbacks_set_on_header_callback(callbacks, header);
        try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_session_client_new(&self.native, callbacks, self));
        try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_submit_settings(self.native, 0, null, 0));
    }
    fn deinit(self: *Client) void {
        c.nghttp2_session_del(self.native);
        self.received.deinit(std.testing.allocator);
    }
    fn request(self: *Client) !i32 {
        var fields = [_]c.nghttp2_nv{
            nv(.{ .name = ":method", .value = "GET" }),          nv(.{ .name = ":scheme", .value = "https" }),
            nv(.{ .name = ":authority", .value = "localhost" }), nv(.{ .name = ":path", .value = "/health" }),
        };
        const stream = c.nghttp2_submit_request2(self.native, null, &fields, fields.len, null, null);
        try std.testing.expect(stream > 0);
        return stream;
    }
    fn toServer(self: *Client, server: *Session) !void {
        for (0..100) |_| {
            var bytes: [*c]const u8 = null;
            const len = c.nghttp2_session_mem_send2(self.native, &bytes);
            try std.testing.expect(len >= 0);
            if (len == 0) return;
            var offset: usize = 0;
            while (offset < len) {
                const n = @min(self.fragment_size, @as(usize, @intCast(len)) - offset);
                const consumed = try server.receive(bytes[offset..][0..n]);
                try std.testing.expectEqual(n, consumed);
                offset += consumed;
            }
        }
        return error.DidNotDrain;
    }
    fn fromServer(self: *Client, server: *Session) !void {
        for (0..100) |_| {
            const bytes = try server.output();
            if (bytes.len == 0) return;
            const len = c.nghttp2_session_mem_recv2(self.native, bytes.ptr, bytes.len);
            try std.testing.expectEqual(@as(c.nghttp2_ssize, @intCast(bytes.len)), len);
        }
        return error.DidNotDrain;
    }
    fn data(_: ?*c.nghttp2_session, _: u8, _: i32, bytes: [*c]const u8, len: usize, context: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(context.?));
        self.received.appendSlice(std.testing.allocator, bytes[0..len]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
        return 0;
    }
    fn header(_: ?*c.nghttp2_session, _: [*c]const c.nghttp2_frame, name: [*c]const u8, nlen: usize, value: [*c]const u8, vlen: usize, _: u8, context: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, name[0..nlen], ":status") and std.mem.eql(u8, value[0..vlen], "200")) self.statuses += 1;
        return 0;
    }
};

test "HTTP2 fragmented concurrent requests, owned responses, reset, and shutdown" {
    var probe: Probe = .{};
    const server = try Session.create(std.testing.allocator, probe.sink(), .{ .response_bytes = 16 });
    defer server.destroy();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    try std.testing.expectError(error.InvalidArgument, server.respond(99, 200, &.{}, ""));
    const one = try client.request();
    const two = try client.request();
    try client.toServer(server);
    try std.testing.expectEqual(@as(usize, 8), probe.headers);
    try std.testing.expectEqual(@as(usize, 2), probe.ends);
    try std.testing.expectError(error.InvalidArgument, server.respond(one, 204, &.{}, "invalid"));
    try std.testing.expectError(error.Backpressure, server.respond(one, 200, &.{}, "this exceeds the limit"));
    var body = [_]u8{ 'O', 'K' };
    try server.respond(one, 200, &.{.{ .name = "content-type", .value = "text/plain" }}, &body);
    body[0] = 'X';
    try std.testing.expectError(error.ResponsePending, server.respond(one, 200, &.{}, ""));
    try server.respond(two, 200, &.{}, "two");
    try server.reset(two, c.NGHTTP2_CANCEL);
    try client.fromServer(server);
    try client.toServer(server);
    try std.testing.expectEqualStrings("OK", client.received.items);
    try std.testing.expectEqual(@as(usize, 1), client.statuses);
    try std.testing.expectEqual(@as(usize, 0), server.queued_bytes);
    try std.testing.expectEqual(@as(usize, 2), probe.closed);
    try server.shutdown();
    try client.fromServer(server);
}

test "HTTP2 sink failure poisons the session and teardown releases pending bodies" {
    var probe: Probe = .{};
    const server = try Session.create(std.testing.allocator, probe.sink(), .{});
    defer server.destroy();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const stream = try client.request();
    try client.toServer(server);
    try server.respond(stream, 200, &.{}, "pending body");
    probe.reject = true;
    _ = try client.request();
    try std.testing.expectError(error.SinkFailed, client.toServer(server));
    try std.testing.expectError(error.Closed, server.output());
}

test "HTTP2 request DATA waits for explicit receive credit" {
    var probe: Probe = .{};
    const server = try Session.create(std.testing.allocator, probe.sink(), .{ .receive_window = 4 });
    defer server.destroy();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    // Negotiate the small window before submitting the request body.
    try client.toServer(server);
    try client.fromServer(server);
    try client.toServer(server);
    var fields = [_]c.nghttp2_nv{
        nv(.{ .name = ":method", .value = "POST" }),         nv(.{ .name = ":scheme", .value = "https" }),
        nv(.{ .name = ":authority", .value = "localhost" }), nv(.{ .name = ":path", .value = "/upload" }),
    };
    var body: Session.Body = .{ .bytes = @constCast("12345678") };
    var provider = c.nghttp2_data_provider2{ .source = .{ .ptr = &body }, .read_callback = Session.readBody };
    const stream = c.nghttp2_submit_request2(client.native, null, &fields, fields.len, &provider, null);
    try std.testing.expect(stream > 0);
    try client.toServer(server);
    try std.testing.expectEqual(@as(usize, 4), probe.data_bytes);
    try std.testing.expectEqual(@as(usize, 0), probe.ends);
    try client.fromServer(server);
    try client.toServer(server);
    try std.testing.expectEqual(@as(usize, 4), probe.data_bytes);
    try server.consume(stream, 4);
    try client.fromServer(server);
    try client.toServer(server);
    try std.testing.expectEqual(@as(usize, 8), probe.data_bytes);
    try std.testing.expectEqual(@as(usize, 1), probe.ends);
    try server.consume(stream, 4);
    try server.respond(stream, 200, &.{}, "received");
    try client.fromServer(server);
    try std.testing.expectEqualStrings("received", client.received.items);
}

test "HTTP2 validates limits before allocating" {
    var probe: Probe = .{};
    try std.testing.expectError(error.InvalidArgument, Session.create(std.testing.failing_allocator, probe.sink(), .{ .max_streams = 0 }));
    try std.testing.expectError(error.InvalidArgument, Session.create(std.testing.failing_allocator, probe.sink(), .{ .receive_window = 0x80000000 }));
    const server = try Session.create(std.testing.allocator, probe.sink(), .{ .receive_window = 0, .response_bytes = 0 });
    defer server.destroy();
    try std.testing.expectEqual(@as(usize, 0), try server.receive(""));
}

test "HTTP2 rejects invalid responses without retaining buffers" {
    var probe: Probe = .{};
    const server = try Session.create(std.testing.allocator, probe.sink(), .{});
    defer server.destroy();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const stream = try client.request();
    try client.toServer(server);
    for ([_]u16{ 0, 100, 199, 600, 65535 }) |status|
        try std.testing.expectError(error.InvalidArgument, server.respond(stream, status, &.{}, ""));
    for ([_]i32{ -1, 0, 99 }) |id|
        try std.testing.expectError(error.InvalidArgument, server.respond(id, 200, &.{}, ""));
    for ([_]Header{ .{ .name = "", .value = "x" }, .{ .name = ":status", .value = "200" } }) |field|
        try std.testing.expectError(error.InvalidArgument, server.respond(stream, 200, &.{field}, ""));
    const headers = [_]Header{.{ .name = "x-test", .value = "x" }} ** 129;
    try std.testing.expectError(error.InvalidArgument, server.respond(stream, 200, &headers, ""));
    for ([_]u16{ 204, 304 }) |status|
        try std.testing.expectError(error.InvalidArgument, server.respond(stream, status, &.{}, "body"));
    try std.testing.expectEqual(@as(usize, 0), server.queued_bytes);
    try std.testing.expectEqual(@as(u32, 0), server.bodies.count());
    try server.respond(stream, 200, &.{}, "valid");
    try client.fromServer(server);
    try std.testing.expectEqualStrings("valid", client.received.items);
}

test "HTTP2 aggregate response budget is reclaimed after stream completion" {
    var probe: Probe = .{};
    const server = try Session.create(std.testing.allocator, probe.sink(), .{ .response_bytes = 8 });
    defer server.destroy();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const first = try client.request();
    const second = try client.request();
    try client.toServer(server);
    try server.respond(first, 200, &.{}, "12345678");
    try std.testing.expectError(error.Backpressure, server.respond(second, 200, &.{}, "x"));
    try std.testing.expectEqual(@as(usize, 8), server.queued_bytes);
    try client.fromServer(server);
    try std.testing.expectEqual(@as(usize, 0), server.queued_bytes);
    try server.respond(second, 200, &.{}, "abcdefgh");
    try client.fromServer(server);
    try std.testing.expectEqualStrings("12345678abcdefgh", client.received.items);
}

test "HTTP2 empty and bodyless responses close without leaking entries" {
    for ([_]u16{ 200, 204, 304, 599 }) |status| {
        var probe: Probe = .{};
        const server = try Session.create(std.testing.allocator, probe.sink(), .{ .response_bytes = 0 });
        defer server.destroy();
        var client: Client = .{};
        try client.init();
        defer client.deinit();
        const stream = try client.request();
        try client.toServer(server);
        try server.respond(stream, status, &.{}, "");
        try client.fromServer(server);
        try std.testing.expectEqual(@as(usize, 1), probe.closed);
        try std.testing.expectEqual(@as(u32, 0), server.bodies.count());
        try std.testing.expectEqual(@as(usize, 0), client.received.items.len);
        try std.testing.expectError(error.InvalidArgument, server.respond(stream, 200, &.{}, ""));
    }
}

test "HTTP2 invalid preface records error and makes every operation terminal" {
    var probe: Probe = .{};
    const server = try Session.create(std.testing.allocator, probe.sink(), .{});
    defer server.destroy();
    try std.testing.expectError(error.NativeFailure, server.receive("XXXXXXXXXXXXXXXXXXXXXXXX"));
    try std.testing.expect(server.last_error < 0);
    try std.testing.expectError(error.Closed, server.receive(""));
    try std.testing.expectError(error.Closed, server.output());
    try std.testing.expectError(error.Closed, server.consume(1, 0));
    try std.testing.expectError(error.Closed, server.respond(1, 200, &.{}, ""));
    try std.testing.expectError(error.Closed, server.reset(1, c.NGHTTP2_CANCEL));
    try std.testing.expectError(error.Closed, server.shutdown());
}

test "HTTP2 response header strings are copied at submission" {
    var probe: Probe = .{};
    const server = try Session.create(std.testing.allocator, probe.sink(), .{});
    defer server.destroy();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const stream = try client.request();
    try client.toServer(server);
    // Content-Length mutation would cause a protocol failure if retained.
    var value = [_]u8{'2'};
    var name = "content-length".*;
    try server.respond(stream, 200, &.{.{ .name = &name, .value = &value }}, "OK");
    value[0] = '9';
    @memset(&name, 'x');
    try client.fromServer(server);
    try std.testing.expectEqualStrings("OK", client.received.items);
    try std.testing.expectEqual(@as(usize, 1), probe.closed);
}

test "HTTP2 peer cancellation frees an unsent response" {
    var probe: Probe = .{};
    const server = try Session.create(std.testing.allocator, probe.sink(), .{});
    defer server.destroy();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const stream = try client.request();
    try client.toServer(server);
    try server.respond(stream, 200, &.{}, "never sent");
    try std.testing.expectEqual(@as(c_int, 0), c.nghttp2_submit_rst_stream(client.native, 0, stream, c.NGHTTP2_CANCEL));
    try client.toServer(server);
    try std.testing.expectEqual(@as(usize, 0), server.queued_bytes);
    try std.testing.expectEqual(@as(u32, 0), server.bodies.count());
    try client.fromServer(server);
    try std.testing.expectEqual(@as(usize, 0), client.received.items.len);
}

fn allocationLifecycle(allocator: std.mem.Allocator) !void {
    var probe: Probe = .{};
    const server = try Session.create(allocator, probe.sink(), .{});
    defer server.destroy();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const stream = try client.request();
    try client.toServer(server);
    try server.respond(stream, 200, &.{.{ .name = "x-test", .value = "test" }}, "allocated");
    // Destroy while the response owns outstanding allocations.
}

test "HTTP2 every Zig allocation failure unwinds session and response ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationLifecycle, .{});
}

test "HTTP2 large response resumes after peer flow credit" {
    var probe: Probe = .{};
    const server = try Session.create(std.testing.allocator, probe.sink(), .{});
    defer server.destroy();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    const stream = try client.request();
    try client.toServer(server);
    const body = try std.testing.allocator.alloc(u8, 150000);
    defer std.testing.allocator.free(body);
    for (body, 0..) |*byte, i| byte.* = @truncate(i);
    try server.respond(stream, 200, &.{}, body);
    try client.fromServer(server);
    try std.testing.expect(client.received.items.len < body.len);
    try std.testing.expect(server.queued_bytes > 0);
    for (0..10) |_| {
        try client.toServer(server);
        try client.fromServer(server);
        if (client.received.items.len == body.len) break;
    }
    try std.testing.expectEqualSlices(u8, body, client.received.items);
    try std.testing.expectEqual(@as(usize, 0), server.queued_bytes);
}

test "HTTP2 sequential reuse and concurrent stream churn preserve bytes" {
    var probe: Probe = .{};
    const server = try Session.create(std.testing.allocator, probe.sink(), .{});
    defer server.destroy();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    for (0..8) |_| {
        var streams: [16]i32 = undefined;
        for (&streams) |*stream| stream.* = try client.request();
        try client.toServer(server);
        for (streams) |stream| try server.respond(stream, 200, &.{}, "ok");
        try client.fromServer(server);
        try client.toServer(server);
        try std.testing.expectEqual(@as(usize, 0), server.queued_bytes);
        try std.testing.expectEqual(@as(u32, 0), server.bodies.count());
    }
    try std.testing.expectEqual(@as(usize, 128), probe.ends);
    try std.testing.expectEqual(@as(usize, 128), probe.closed);
    try std.testing.expectEqualStrings("ok" ** 128, client.received.items);
}

test "HTTP2 wire exchange handles boundary-sized fragments" {
    for ([_]usize{ 1, 2, 3, 8, 9, 24, 65535 }) |size| {
        var probe: Probe = .{};
        const server = try Session.create(std.testing.allocator, probe.sink(), .{});
        defer server.destroy();
        var client: Client = .{ .fragment_size = size };
        try client.init();
        defer client.deinit();
        const stream = try client.request();
        try client.toServer(server);
        try std.testing.expectEqual(@as(usize, 4), probe.headers);
        try std.testing.expectEqual(@as(usize, 1), probe.ends);
        try server.respond(stream, 200, &.{}, "hello");
        try client.fromServer(server);
        try std.testing.expectEqualStrings("hello", client.received.items);
    }
}

test "HTTP2 negotiated concurrent stream limit defers additional requests" {
    var probe: Probe = .{};
    const server = try Session.create(std.testing.allocator, probe.sink(), .{ .max_streams = 1 });
    defer server.destroy();
    var client: Client = .{};
    try client.init();
    defer client.deinit();
    try client.toServer(server);
    try client.fromServer(server);
    const first = try client.request();
    const second = try client.request();
    try client.toServer(server);
    try std.testing.expectEqual(@as(usize, 1), probe.ends);
    try server.respond(first, 200, &.{}, "first");
    try client.fromServer(server);
    try client.toServer(server);
    try std.testing.expectEqual(@as(usize, 2), probe.ends);
    try server.respond(second, 200, &.{}, "second");
    try client.fromServer(server);
    try std.testing.expectEqualStrings("firstsecond", client.received.items);
}
