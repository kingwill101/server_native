const std = @import("std");
const bridge_protocol = @import("bridge_protocol.zig");
const http1 = @import("http1.zig").posix;

const known_header_names = [_][]const u8{
    "host", "connection", "user-agent", "accept", "accept-encoding", "accept-language",
    "content-type", "content-length", "transfer-encoding", "cookie", "set-cookie",
    "cache-control", "pragma", "upgrade", "authorization", "origin", "referer", "location",
    "server", "date", "x-forwarded-for", "x-forwarded-proto", "x-forwarded-host",
    "x-forwarded-port", "x-request-id", "sec-websocket-key", "sec-websocket-version",
    "sec-websocket-protocol", "sec-websocket-extensions",
};

pub const Response = struct {
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
            response.status = try readU16(frame, &offset);
            try decodeHeaders(allocator, frame, &offset, &response.headers);
            try response.body.appendSlice(allocator, try readBytes(frame, &offset));
            if (offset != frame.len) return error.InvalidResponse;
            done.* = true;
        },
        6, 14 => {
            var offset: usize = 2;
            response.status = try readU16(frame, &offset);
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
        const value = try allocator.dupe(u8, try readBytes(frame, offset));
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
