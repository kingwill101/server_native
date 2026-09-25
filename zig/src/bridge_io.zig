const std = @import("std");
const bridge_protocol = @import("bridge_protocol.zig");
const http1 = @import("http1.zig").posix;

const known_header_names = [_][]const u8{
    "host",         "connection",        "user-agent",            "accept",                 "accept-encoding",          "accept-language",
    "content-type", "content-length",    "transfer-encoding",     "cookie",                 "set-cookie",               "cache-control",
    "pragma",       "upgrade",           "authorization",         "origin",                 "referer",                  "location",
    "server",       "date",              "x-forwarded-for",       "x-forwarded-proto",      "x-forwarded-host",         "x-forwarded-port",
    "x-request-id", "sec-websocket-key", "sec-websocket-version", "sec-websocket-protocol", "sec-websocket-extensions",
};

pub const Response = struct {
    ready: bool = false,
    status: u16 = 500,
    headers: std.ArrayList(bridge_protocol.Header) = .empty,
    body: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        for (self.headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        self.headers.deinit(allocator);
        self.body.deinit(allocator);
    }
};

pub fn sendFrame(allocator: std.mem.Allocator, fd: http1.Fd, payload: []const u8) !void {
    if (payload.len > bridge_protocol.max_frame_bytes) return error.FrameTooLarge;
    const frame = try allocator.alloc(u8, 4 + payload.len);
    defer allocator.free(frame);
    frame[0] = @intCast((payload.len >> 24) & 0xff);
    frame[1] = @intCast((payload.len >> 16) & 0xff);
    frame[2] = @intCast((payload.len >> 8) & 0xff);
    frame[3] = @intCast(payload.len & 0xff);
    @memcpy(frame[4..], payload);
    try http1.sendAll(fd, frame);
}

pub fn frameLength(input: []const u8) u32 {
    return (@as(u32, input[0]) << 24) | (@as(u32, input[1]) << 16) |
        (@as(u32, input[2]) << 8) | input[3];
}

pub fn receiveFrame(allocator: std.mem.Allocator, fd: http1.Fd) ![]u8 {
    var length_bytes: [4]u8 = undefined;
    try receiveExact(fd, &length_bytes);
    const length = frameLength(length_bytes[0..]);
    if (length > bridge_protocol.max_frame_bytes) return error.FrameTooLarge;
    const payload = try allocator.alloc(u8, length);
    errdefer allocator.free(payload);
    try receiveExact(fd, payload);
    return payload;
}

pub fn decodeResponseFrame(
    allocator: std.mem.Allocator,
    frame: []const u8,
    response: *Response,
    done: *bool,
) !void {
    if (frame.len < 2 or frame[0] != bridge_protocol.protocol_version) return error.InvalidResponse;
    switch (frame[1]) {
        2, 12 => {
            var offset: usize = 2;
            response.ready = true;
            response.status = normalizeStatus(try readU16(frame, &offset));
            try decodeHeaders(allocator, frame, &offset, &response.headers);
            try response.body.appendSlice(allocator, try readBytes(frame, &offset));
            if (offset != frame.len) return error.InvalidResponse;
            done.* = true;
        },
        6, 14 => {
            var offset: usize = 2;
            response.ready = true;
            response.status = normalizeStatus(try readU16(frame, &offset));
            try decodeHeaders(allocator, frame, &offset, &response.headers);
            if (offset != frame.len) return error.InvalidResponse;
        },
        7 => {
            var offset: usize = 2;
            try response.body.appendSlice(allocator, try readBytes(frame, &offset));
            if (offset != frame.len) return error.InvalidResponse;
        },
        8 => {
            if (frame.len != 2) return error.InvalidResponse;
            done.* = true;
        },
        else => return error.InvalidResponse,
    }
}

// Match http::StatusCode used by the Rust bridge, including extension statuses.
fn normalizeStatus(status: u16) u16 {
    return if (status >= 100 and status <= 999) status else 502;
}

/// Both existing native benchmark modes use this same finite JSON response.
/// The caller must invoke this only once for a fresh response.
pub fn benchmarkResponse(allocator: std.mem.Allocator, response: *Response) !void {
    const name = try allocator.dupe(u8, "content-type");
    errdefer allocator.free(name);
    const value = try allocator.dupe(u8, "application/json");
    errdefer allocator.free(value);
    // Reserve the header before committing its owned fields, so failures in the
    // body allocation cannot leave dangling header strings in the response.
    try response.headers.ensureUnusedCapacity(allocator, 1);
    try response.body.appendSlice(allocator, "{\"ok\":true,\"label\":\"server_native_direct\"}");
    response.headers.appendAssumeCapacity(.{ .name = name, .value = value });
    response.status = 200;
    response.ready = true;
}

fn receiveExact(fd: http1.Fd, output: []u8) !void {
    var offset: usize = 0;
    while (offset < output.len) {
        const count = try http1.receive(fd, output[offset..]);
        if (count == 0) return error.ConnectionClosed;
        offset += count;
    }
}

fn decodeHeaders(allocator: std.mem.Allocator, frame: []const u8, offset: *usize, headers: *std.ArrayList(bridge_protocol.Header)) !void {
    const count = try readU32(frame, offset);
    if (count > 65536) return error.TooManyHeaders;
    for (0..count) |_| {
        const name = try readHeaderName(allocator, frame, offset);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, try readBytes(frame, offset));
        errdefer allocator.free(value);
        try headers.append(allocator, .{ .name = name, .value = value });
    }
}

fn readHeaderName(allocator: std.mem.Allocator, frame: []const u8, offset: *usize) ![]u8 {
    const token = try readU16(frame, offset);
    if (token == 0xffff) return allocator.dupe(u8, try readBytes(frame, offset));
    if (token >= known_header_names.len) return error.InvalidHeaderToken;
    return allocator.dupe(u8, known_header_names[token]);
}

fn readBytes(frame: []const u8, offset: *usize) ![]const u8 {
    const length = try readU32(frame, offset);
    if (length > frame.len -| offset.*) return error.TruncatedResponse;
    const result = frame[offset.* .. offset.* + length];
    offset.* += length;
    return result;
}

fn readU16(frame: []const u8, offset: *usize) !u16 {
    if (frame.len -| offset.* < 2) return error.TruncatedResponse;
    const result = (@as(u16, frame[offset.*]) << 8) | frame[offset.* + 1];
    offset.* += 2;
    return result;
}

fn readU32(frame: []const u8, offset: *usize) !u32 {
    if (frame.len -| offset.* < 4) return error.TruncatedResponse;
    const result = (@as(u32, frame[offset.*]) << 24) | (@as(u32, frame[offset.* + 1]) << 16) |
        (@as(u32, frame[offset.* + 2]) << 8) | frame[offset.* + 3];
    offset.* += 4;
    return result;
}

// Fixed bytes are independent of the request encoder: this is the Dart response
// wire contract, including one tokenized and one literal header and binary data.
const test_response = [_]u8{ 1, 12, 0, 201, 0, 0, 0, 2, 0, 6, 0, 0, 0, 3, 'a', '/', 'b', 255, 255, 0, 0, 0, 3, 'x', '-', 'a', 0, 0, 0, 1, 'v', 0, 0, 0, 3, 0, 255, 42 };

fn responseAllocation(allocator: std.mem.Allocator) !void {
    var response: Response = .{};
    defer response.deinit(allocator);
    var done = false;
    try decodeResponseFrame(allocator, &test_response, &response, &done);
    try std.testing.expect(done and response.ready);
    try std.testing.expectEqual(@as(u16, 201), response.status);
    try std.testing.expectEqualStrings("content-type", response.headers.items[0].name);
    try std.testing.expectEqualStrings("a/b", response.headers.items[0].value);
    try std.testing.expectEqualStrings("x-a", response.headers.items[1].name);
    try std.testing.expectEqualStrings("v", response.headers.items[1].value);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 42 }, response.body.items);
}

test "bridge response owns headers and binary body with allocation failure cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, responseAllocation, .{});
    var input = test_response;
    var response: Response = .{};
    defer response.deinit(std.testing.allocator);
    var done = false;
    try decodeResponseFrame(std.testing.allocator, &input, &response, &done);
    @memset(&input, 0);
    try std.testing.expectEqualStrings("x-a", response.headers.items[1].name);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 42 }, response.body.items);
}

test "bridge response rejects every truncated prefix and trailing bytes" {
    for (0..test_response.len) |length| {
        var response: Response = .{};
        defer response.deinit(std.testing.allocator);
        var done = false;
        if (decodeResponseFrame(std.testing.allocator, test_response[0..length], &response, &done)) |_| {
            return error.AcceptedTruncatedResponse;
        } else |err| try std.testing.expect(err == error.InvalidResponse or err == error.TruncatedResponse);
        try std.testing.expect(!done);
    }
    var response: Response = .{};
    defer response.deinit(std.testing.allocator);
    var done = false;
    try std.testing.expectError(error.InvalidResponse, decodeResponseFrame(std.testing.allocator, &(test_response ++ .{0}), &response, &done));
}

test "bridge response header count token and version are bounded" {
    const cases = .{
        .{ &[_]u8{ 2, 8 }, error.InvalidResponse },
        .{ &[_]u8{ 1, 99 }, error.InvalidResponse },
        .{ &[_]u8{ 1, 8, 0 }, error.InvalidResponse },
        .{ &[_]u8{ 1, 14, 0, 200, 0, 1, 0, 1 }, error.TooManyHeaders },
        .{ &[_]u8{ 1, 14, 0, 200, 0, 0, 0, 1, 0, 29 }, error.InvalidHeaderToken },
        .{ &[_]u8{ 1, 7, 255, 255, 255, 255 }, error.TruncatedResponse },
    };
    inline for (cases) |case| {
        var response: Response = .{};
        defer response.deinit(std.testing.allocator);
        var done = false;
        try std.testing.expectError(case[1], decodeResponseFrame(std.testing.allocator, case[0], &response, &done));
        try std.testing.expect(!done);
    }
}

test "bridge progressive response distinguishes headers chunks and terminal" {
    var response: Response = .{};
    defer response.deinit(std.testing.allocator);
    var done = false;
    try decodeResponseFrame(std.testing.allocator, &.{ 1, 14, 0, 200, 0, 0, 0, 0 }, &response, &done);
    try std.testing.expect(response.ready and !done);
    for ([_][]const u8{ &.{ 1, 7, 0, 0, 0, 0 }, &.{ 1, 7, 0, 0, 0, 2, 'a', 'b' }, &.{ 1, 7, 0, 0, 0, 1, 'c' } }) |frame| {
        try decodeResponseFrame(std.testing.allocator, frame, &response, &done);
        try std.testing.expect(!done);
    }
    try decodeResponseFrame(std.testing.allocator, &.{ 1, 8 }, &response, &done);
    try std.testing.expect(done);
    try std.testing.expectEqualStrings("abc", response.body.items);
}

test "bridge wire IO preserves consecutive empty and binary frames" {
    const c = @cImport({
        @cInclude("sys/socket.h");
        @cInclude("unistd.h");
    });
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    for ([_][]const u8{ "", &.{ 0, 255, 128 }, "last" }) |payload| {
        try sendFrame(std.testing.allocator, fds[0], payload);
        const received = try receiveFrame(std.testing.allocator, fds[1]);
        defer std.testing.allocator.free(received);
        try std.testing.expectEqualSlices(u8, payload, received);
    }
}

test "bridge wire IO rejects truncated prefix payload and oversized lengths" {
    const c = @cImport({
        @cInclude("sys/socket.h");
        @cInclude("unistd.h");
    });
    for ([_][]const u8{ "", &.{0}, &.{ 0, 0, 0 }, &.{ 0, 0, 0, 3, 42 }, &.{ 4, 0, 0, 1 } }, 0..) |wire, i| {
        var fds: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds));
        defer _ = c.close(fds[0]);
        defer _ = c.close(fds[1]);
        try http1.sendAll(fds[0], wire);
        http1.shutdownWrite(fds[0]);
        try std.testing.expectError(if (i == 4) error.FrameTooLarge else error.ConnectionClosed, receiveFrame(std.testing.allocator, fds[1]));
    }
}

test "bridge response status normalization matches Rust for finite and streaming frames" {
    for ([_]u16{ 0, 99, 100, 200, 599, 600, 999, 1000, 65535 }) |status| {
        for ([_]u8{ 12, 14 }) |tag| {
            var frame = [_]u8{ 1, tag, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
            std.mem.writeInt(u16, frame[2..4], status, .big);
            var response: Response = .{};
            defer response.deinit(std.testing.allocator);
            var done = false;
            try decodeResponseFrame(std.testing.allocator, frame[0..(if (tag == 12) @as(usize, 12) else 8)], &response, &done);
            try std.testing.expectEqual(@as(u16, if (status < 100 or status > 999) 502 else status), response.status);
            try std.testing.expectEqual(tag == 12, done);
        }
    }
}

fn benchmarkAllocation(allocator: std.mem.Allocator) !void {
    var response: Response = .{};
    defer response.deinit(allocator);
    try benchmarkResponse(allocator, &response);
    try std.testing.expect(response.ready);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("application/json", response.headers.items[0].value);
    try std.testing.expectEqualStrings("{\"ok\":true,\"label\":\"server_native_direct\"}", response.body.items);
}

test "native benchmark response has Rust parity and unwinds allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, benchmarkAllocation, .{});
}
