const std = @import("std");

pub const protocol_version: u8 = 1;
pub const max_frame_bytes: usize = 64 * 1024 * 1024;

pub const FrameType = enum(u8) {
    request = 1,
    response = 2,
    request_start = 3,
    request_chunk = 4,
    request_end = 5,
    response_start = 6,
    response_chunk = 7,
    response_end = 8,
    tunnel_chunk = 9,
    tunnel_close = 10,
    request_tokenized = 11,
    response_tokenized = 12,
    request_start_tokenized = 13,
    response_start_tokenized = 14,
};

pub const Error = error{
    BufferTooSmall,
    FieldTooLarge,
    FrameTooLarge,
    InvalidLength,
    TruncatedPayload,
    UnexpectedFrameType,
    UnsupportedVersion,
};

pub fn encodeWireFrame(payload: []const u8, out: []u8) Error![]const u8 {
    if (payload.len > max_frame_bytes) return error.FrameTooLarge;

    const required = 4 + payload.len;
    if (out.len < required) return error.BufferTooSmall;

    writeU32(out[0..4], @intCast(payload.len));
    @memcpy(out[4..required], payload);
    return out[0..required];
}

pub fn decodeWireFrame(frame: []const u8) Error![]const u8 {
    if (frame.len < 4) return error.TruncatedPayload;

    const payload_len: usize = @intCast(readU32(frame[0..4]));
    if (payload_len > max_frame_bytes) return error.FrameTooLarge;
    if (frame.len - 4 != payload_len) return error.InvalidLength;

    return frame[4..];
}

pub fn encodeChunk(
    frame_type: FrameType,
    chunk: []const u8,
    out: []u8,
) Error![]const u8 {
    if (chunk.len > max_frame_bytes - 6) return error.FrameTooLarge;

    const required = 6 + chunk.len;
    if (out.len < required) return error.BufferTooSmall;

    out[0] = protocol_version;
    out[1] = @intFromEnum(frame_type);
    writeU32(out[2..6], @intCast(chunk.len));
    @memcpy(out[6..required], chunk);
    return out[0..required];
}

pub fn decodeChunk(
    payload: []const u8,
    expected_type: FrameType,
) Error![]const u8 {
    if (payload.len < 6) return error.TruncatedPayload;
    if (payload[0] != protocol_version) return error.UnsupportedVersion;
    if (payload[1] != @intFromEnum(expected_type)) {
        return error.UnexpectedFrameType;
    }

    const chunk_len: usize = @intCast(readU32(payload[2..6]));
    if (payload.len - 6 != chunk_len) return error.InvalidLength;
    return payload[6..];
}

pub fn encodeTerminal(frame_type: FrameType, out: []u8) Error![]const u8 {
    if (out.len < 2) return error.BufferTooSmall;
    out[0] = protocol_version;
    out[1] = @intFromEnum(frame_type);
    return out[0..2];
}

pub fn frameType(payload: []const u8) Error!FrameType {
    if (payload.len < 2) return error.TruncatedPayload;
    if (payload[0] != protocol_version) return error.UnsupportedVersion;
    return switch (payload[1]) {
        1 => .request,
        2 => .response,
        3 => .request_start,
        4 => .request_chunk,
        5 => .request_end,
        6 => .response_start,
        7 => .response_chunk,
        8 => .response_end,
        9 => .tunnel_chunk,
        10 => .tunnel_close,
        11 => .request_tokenized,
        12 => .response_tokenized,
        13 => .request_start_tokenized,
        14 => .response_start_tokenized,
        else => error.UnexpectedFrameType,
    };
}


pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const RequestHead = struct {
    method: []const u8,
    scheme: []const u8,
    authority: []const u8,
    path: []const u8,
    query: []const u8,
    protocol: []const u8,
    headers: []const Header,
};

const header_name_literal_token: u16 = 0xffff;
const connection_header = "connection";
const sanitized_connection_header = "x-server-native-connection";
const empty_connection_sentinel = "__server_native_empty_connection__";

pub fn encodeRequestStart(request: RequestHead, out: []u8) Error![]const u8 {
    var writer = Writer{ .bytes = out };
    try writer.putU8(protocol_version);
    try writer.putU8(@intFromEnum(FrameType.request_start_tokenized));
    try writer.putBytes(request.method);
    try writer.putBytes(request.scheme);
    try writer.putBytes(request.authority);
    try writer.putBytes(request.path);
    try writer.putBytes(request.query);
    try writer.putBytes(request.protocol);

    const count_position = writer.offset;
    try writer.putU32(0);

    var header_count: u32 = 0;
    var has_sanitized_connection = false;
    for (request.headers) |header| {
        if (std.mem.eql(u8, header.name, sanitized_connection_header)) {
            has_sanitized_connection = true;
            break;
        }
    }

    for (request.headers) |header| {
        if (has_sanitized_connection and
            std.mem.eql(u8, header.name, connection_header))
        {
            continue;
        }

        const name = if (std.mem.eql(
            u8,
            header.name,
            sanitized_connection_header,
        )) connection_header else header.name;

        if (std.mem.eql(u8, name, connection_header)) {
            var emitted = false;
            var tokens = std.mem.splitScalar(u8, header.value, ',');
            while (tokens.next()) |raw_token| {
                const token = trimAsciiWhitespace(raw_token);
                if (token.len == 0 or
                    asciiEqualIgnoreCase(token, empty_connection_sentinel))
                {
                    continue;
                }
                try incrementHeaderCount(&header_count);
                try writer.putHeaderName(name);
                try writer.putBytes(token);
                emitted = true;
            }
            if (!emitted) {
                try incrementHeaderCount(&header_count);
                try writer.putHeaderName(name);
                try writer.putBytes("");
            }
            continue;
        }

        try incrementHeaderCount(&header_count);
        try writer.putHeaderName(name);
        try writer.putBytes(header.value);
    }

    writeU32(writer.bytes[count_position .. count_position + 4], header_count);
    if (writer.offset > max_frame_bytes) return error.FrameTooLarge;
    return writer.bytes[0..writer.offset];
}

const Writer = struct {
    bytes: []u8,
    offset: usize = 0,

    fn putU8(self: *Writer, value: u8) Error!void {
        try self.ensure(1);
        self.bytes[self.offset] = value;
        self.offset += 1;
    }

    fn putU16(self: *Writer, value: u16) Error!void {
        try self.ensure(2);
        self.bytes[self.offset] = @intCast(value >> 8);
        self.bytes[self.offset + 1] = @intCast(value);
        self.offset += 2;
    }

    fn putU32(self: *Writer, value: u32) Error!void {
        try self.ensure(4);
        writeU32(self.bytes[self.offset .. self.offset + 4], value);
        self.offset += 4;
    }

    fn putBytes(self: *Writer, value: []const u8) Error!void {
        if (value.len > std.math.maxInt(u32)) return error.FieldTooLarge;
        try self.putU32(@intCast(value.len));
        try self.ensure(value.len);
        @memcpy(self.bytes[self.offset .. self.offset + value.len], value);
        self.offset += value.len;
    }

    fn putHeaderName(self: *Writer, name: []const u8) Error!void {
        if (headerNameToken(name)) |token| {
            return self.putU16(token);
        }
        try self.putU16(header_name_literal_token);
        try self.putBytes(name);
    }

    fn ensure(self: *Writer, additional: usize) Error!void {
        if (additional > self.bytes.len -| self.offset) {
            return error.BufferTooSmall;
        }
    }
};

fn incrementHeaderCount(count: *u32) Error!void {
    if (count.* == std.math.maxInt(u32)) return error.FieldTooLarge;
    count.* += 1;
}

fn headerNameToken(name: []const u8) ?u16 {
    const names = [_][]const u8{
        "host",
        "connection",
        "user-agent",
        "accept",
        "accept-encoding",
        "accept-language",
        "content-type",
        "content-length",
        "transfer-encoding",
        "cookie",
        "set-cookie",
        "cache-control",
        "pragma",
        "upgrade",
        "authorization",
        "origin",
        "referer",
        "location",
        "server",
        "date",
        "x-forwarded-for",
        "x-forwarded-proto",
        "x-forwarded-host",
        "x-forwarded-port",
        "x-request-id",
        "sec-websocket-key",
        "sec-websocket-version",
        "sec-websocket-protocol",
        "sec-websocket-extensions",
    };
    for (names, 0..) |candidate, index| {
        if (std.mem.eql(u8, name, candidate)) return @intCast(index);
    }
    return null;
}

fn trimAsciiWhitespace(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and (value[start] == ' ' or value[start] == '\t')) {
        start += 1;
    }
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) {
        end -= 1;
    }
    return value[start..end];
}

fn asciiEqualIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        const lower_a = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const lower_b = if (b >= 'A' and b <= 'Z') b + 32 else b;
        if (lower_a != lower_b) return false;
    }
    return true;
}

fn writeU32(out: []u8, value: u32) void {
    out[0] = @intCast(value >> 24);
    out[1] = @intCast(value >> 16);
    out[2] = @intCast(value >> 8);
    out[3] = @intCast(value);
}

fn readU32(input: []const u8) u32 {
    return (@as(u32, input[0]) << 24) |
        (@as(u32, input[1]) << 16) |
        (@as(u32, input[2]) << 8) |
        @as(u32, input[3]);
}

test "encodes the Rust-compatible request chunk payload" {
    var storage: [16]u8 = undefined;
    const payload = try encodeChunk(.request_chunk, "abc", &storage);
    try std.testing.expectEqualSlices(
        u8,
        &.{ protocol_version, 4, 0, 0, 0, 3, 'a', 'b', 'c' },
        payload,
    );
    try std.testing.expectEqualStrings(
        "abc",
        try decodeChunk(payload, .request_chunk),
    );
}

test "wraps payloads in the Rust-compatible wire length prefix" {
    var storage: [16]u8 = undefined;
    const frame = try encodeWireFrame(&.{ protocol_version, 5 }, &storage);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 0, 2, protocol_version, 5 },
        frame,
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ protocol_version, 5 },
        try decodeWireFrame(frame),
    );
}

test "encodes terminal and tunnel frames" {
    var terminal_storage: [2]u8 = undefined;
    const terminal = try encodeTerminal(.tunnel_close, &terminal_storage);
    try std.testing.expectEqualSlices(
        u8,
        &.{ protocol_version, 10 },
        terminal,
    );
    try std.testing.expectEqual(FrameType.tunnel_close, try frameType(terminal));
}

test "rejects malformed frames" {
    try std.testing.expectError(
        error.TruncatedPayload,
        decodeWireFrame(&.{ 0, 0, 0 }),
    );
    try std.testing.expectError(
        error.InvalidLength,
        decodeWireFrame(&.{ 0, 0, 0, 2, protocol_version }),
    );
    try std.testing.expectError(
        error.UnsupportedVersion,
        frameType(&.{ 2, 5 }),
    );
    try std.testing.expectError(
        error.UnexpectedFrameType,
        decodeChunk(
            &.{ protocol_version, 7, 0, 0, 0, 0 },
            .request_chunk,
        ),
    );
}

test "encodes tokenized request start fields and headers" {
    const headers = [_]Header{
        .{ .name = "host", .value = "example.com" },
        .{ .name = "x-test", .value = "ok" },
    };
    var storage: [256]u8 = undefined;
    const payload = try encodeRequestStart(.{
        .method = "GET",
        .scheme = "http",
        .authority = "example.com",
        .path = "/hello",
        .query = "",
        .protocol = "HTTP/1.1",
        .headers = &headers,
    }, &storage);

    try std.testing.expectEqual(protocol_version, payload[0]);
    try std.testing.expectEqual(
        @intFromEnum(FrameType.request_start_tokenized),
        payload[1],
    );

    var offset: usize = 2;
    try expectEncodedField(payload, &offset, "GET");
    try expectEncodedField(payload, &offset, "http");
    try expectEncodedField(payload, &offset, "example.com");
    try expectEncodedField(payload, &offset, "/hello");
    try expectEncodedField(payload, &offset, "");
    try expectEncodedField(payload, &offset, "HTTP/1.1");

    try std.testing.expectEqual(@as(u32, 2), readU32(payload[offset .. offset + 4]));
    offset += 4;
    try std.testing.expectEqual(@as(u16, 0), readU16(payload[offset .. offset + 2]));
    offset += 2;
    try expectEncodedField(payload, &offset, "example.com");
    try std.testing.expectEqual(
        header_name_literal_token,
        readU16(payload[offset .. offset + 2]),
    );
    offset += 2;
    try expectEncodedField(payload, &offset, "x-test");
    try expectEncodedField(payload, &offset, "ok");
    try std.testing.expectEqual(payload.len, offset);
}

test "splits connection tokens and prefers the sanitized header" {
    const headers = [_]Header{
        .{ .name = "connection", .value = "close" },
        .{
            .name = "x-server-native-connection",
            .value = "keep-alive, upgrade",
        },
    };
    var storage: [256]u8 = undefined;
    const payload = try encodeRequestStart(.{
        .method = "GET",
        .scheme = "http",
        .authority = "",
        .path = "/",
        .query = "",
        .protocol = "HTTP/1.1",
        .headers = &headers,
    }, &storage);

    var offset: usize = 2;
    inline for (.{ "GET", "http", "", "/", "", "HTTP/1.1" }) |field| {
        try expectEncodedField(payload, &offset, field);
    }
    try std.testing.expectEqual(@as(u32, 2), readU32(payload[offset .. offset + 4]));
    offset += 4;
    try std.testing.expectEqual(@as(u16, 1), readU16(payload[offset .. offset + 2]));
    offset += 2;
    try expectEncodedField(payload, &offset, "keep-alive");
    try std.testing.expectEqual(@as(u16, 1), readU16(payload[offset .. offset + 2]));
    offset += 2;
    try expectEncodedField(payload, &offset, "upgrade");
    try std.testing.expectEqual(payload.len, offset);
}

fn expectEncodedField(
    payload: []const u8,
    offset: *usize,
    expected: []const u8,
) !void {
    const length: usize = @intCast(readU32(payload[offset.* .. offset.* + 4]));
    offset.* += 4;
    try std.testing.expectEqual(expected.len, length);
    try std.testing.expectEqualSlices(
        u8,
        expected,
        payload[offset.* .. offset.* + length],
    );
    offset.* += length;
}

fn readU16(input: []const u8) u16 {
    return (@as(u16, input[0]) << 8) | @as(u16, input[1]);
}
