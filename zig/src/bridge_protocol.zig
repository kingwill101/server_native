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
    OutOfMemory,
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
const max_request_head_headers: u32 = 65536;
pub const min_request_head_descriptor_bytes: usize = 28;

/// Decodes the Dart-to-Zig request-head descriptor used by the queue FFI.
///
/// It contains six u32-BE-length-prefixed fields (method, scheme, authority,
/// path, query, protocol), followed by a u32-BE header count and repeated
/// length-prefixed name/value pairs. This input descriptor is distinct from
/// the Rust-compatible tokenized bridge payload produced below.
pub fn decodeRequestHeadDescriptor(
    allocator: std.mem.Allocator,
    input: []const u8,
) Error!RequestHead {
    var reader = RequestHeadReader{ .bytes = input };
    const method = try reader.readField();
    const scheme = try reader.readField();
    const authority = try reader.readField();
    const path = try reader.readField();
    const query = try reader.readField();
    const protocol = try reader.readField();
    const header_count = try reader.readU32Value();

    if (header_count > max_request_head_headers) return error.FrameTooLarge;
    const header_count_usize: usize = @intCast(header_count);
    if (header_count_usize > (input.len -| reader.offset) / 8) {
        return error.InvalidLength;
    }
    const headers = try allocator.alloc(Header, header_count_usize);
    errdefer allocator.free(headers);
    for (headers) |*header| {
        header.* = .{
            .name = try reader.readField(),
            .value = try reader.readField(),
        };
    }
    if (reader.offset != input.len) return error.InvalidLength;

    return .{
        .method = method,
        .scheme = scheme,
        .authority = authority,
        .path = path,
        .query = query,
        .protocol = protocol,
        .headers = headers,
    };
}

pub fn encodeRequestStart(request: RequestHead, out: []u8) Error![]const u8 {
    var writer = Writer{ .bytes = out };
    try writeRequestStart(request, &writer);
    return out[0..writer.offset];
}

/// Returns the exact encoded size without allocating an output buffer.
pub fn requestStartEncodedSize(request: RequestHead) Error!usize {
    var writer = Writer{ .bytes = null };
    try writeRequestFrame(request, &writer, .request_start_tokenized, null);
    return writer.offset;
}

pub fn encodeRequest(request: RequestHead, body: []const u8, out: []u8) Error![]const u8 {
    var writer = Writer{ .bytes = out };
    try writeRequestFrame(request, &writer, .request_tokenized, body);
    return out[0..writer.offset];
}

fn writeRequestStart(request: RequestHead, writer: *Writer) Error!void {
    try writeRequestFrame(request, writer, .request_start_tokenized, null);
}

fn writeRequestFrame(request: RequestHead, writer: *Writer, frame_type: FrameType, body: ?[]const u8) Error!void {
    try writer.putU8(protocol_version);
    try writer.putU8(@intFromEnum(frame_type));
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

    writer.patchU32(count_position, header_count);
    if (body) |bytes| try writer.putBytes(bytes);
    if (writer.offset > max_frame_bytes) return error.FrameTooLarge;
}

const RequestHeadReader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn readU32Value(self: *RequestHeadReader) Error!u32 {
        if (self.bytes.len -| self.offset < 4) return error.TruncatedPayload;
        const value = readU32(self.bytes[self.offset .. self.offset + 4]);
        self.offset += 4;
        return value;
    }

    fn readField(self: *RequestHeadReader) Error![]const u8 {
        const length: usize = @intCast(try self.readU32Value());
        if (length > self.bytes.len -| self.offset) return error.TruncatedPayload;
        const field = self.bytes[self.offset .. self.offset + length];
        self.offset += length;
        return field;
    }
};

const Writer = struct {
    bytes: ?[]u8,
    offset: usize = 0,

    fn putU8(self: *Writer, value: u8) Error!void {
        try self.ensure(1);
        if (self.bytes) |bytes| bytes[self.offset] = value;
        self.offset += 1;
    }

    fn putU16(self: *Writer, value: u16) Error!void {
        try self.ensure(2);
        if (self.bytes) |bytes| {
            bytes[self.offset] = @intCast((value >> 8) & 0xff);
            bytes[self.offset + 1] = @intCast(value & 0xff);
        }
        self.offset += 2;
    }

    fn putU32(self: *Writer, value: u32) Error!void {
        try self.ensure(4);
        if (self.bytes) |bytes| writeU32(bytes[self.offset .. self.offset + 4], value);
        self.offset += 4;
    }

    fn patchU32(self: *Writer, offset: usize, value: u32) void {
        if (self.bytes) |bytes| writeU32(bytes[offset .. offset + 4], value);
    }

    fn putBytes(self: *Writer, value: []const u8) Error!void {
        if (value.len > std.math.maxInt(u32)) return error.FieldTooLarge;
        try self.putU32(@intCast(value.len));
        try self.ensure(value.len);
        if (self.bytes) |bytes| {
            @memcpy(bytes[self.offset .. self.offset + value.len], value);
        }
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
        if (additional > max_frame_bytes -| self.offset) {
            return error.FrameTooLarge;
        }
        if (self.bytes) |bytes| {
            if (additional > bytes.len -| self.offset) {
                return error.BufferTooSmall;
            }
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
    out[0] = @intCast((value >> 24) & 0xff);
    out[1] = @intCast((value >> 16) & 0xff);
    out[2] = @intCast((value >> 8) & 0xff);
    out[3] = @intCast(value & 0xff);
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

test "wire frames round trip deterministic binary payloads and reject truncation" {
    var rng = std.Random.DefaultPrng.init(0x5e7e2026);
    var payload: [2048]u8 = undefined;
    var output: [2052]u8 = undefined;
    for (0..100) |_| {
        const len = rng.random().uintLessThan(usize, payload.len + 1);
        rng.random().bytes(payload[0..len]);
        const encoded = try encodeWireFrame(payload[0..len], &output);
        try std.testing.expectEqualSlices(u8, payload[0..len], try decodeWireFrame(encoded));
        if (len > 0) try std.testing.expectError(error.InvalidLength, decodeWireFrame(encoded[0 .. encoded.len - 1]));
        try std.testing.expectError(error.BufferTooSmall, encodeWireFrame(payload[0..len], output[0 .. encoded.len - 1]));
    }
}

test "chunk frame types round trip binary and empty bodies" {
    const kinds = [_]FrameType{ .request_chunk, .response_chunk, .tunnel_chunk };
    var output: [256]u8 = undefined;
    const data = [_]u8{ 0, 255, 1, 128, 13, 10 };
    for (kinds) |kind| {
        for ([_][]const u8{ "", &data }) |bytes| {
            const encoded = try encodeChunk(kind, bytes, &output);
            try std.testing.expectEqualSlices(u8, bytes, try decodeChunk(encoded, kind));
            try std.testing.expectEqual(kind, try frameType(encoded));
            try std.testing.expectError(error.BufferTooSmall, encodeChunk(kind, bytes, output[0 .. encoded.len - 1]));
        }
    }
}

test "frame type decoder covers every tag and rejects unknown tags" {
    for (0..256) |tag| {
        const bytes = [_]u8{ protocol_version, @intCast(tag) };
        if (tag >= 1 and tag <= 14) {
            try std.testing.expectEqual(@as(u8, @intCast(tag)), @intFromEnum(try frameType(&bytes)));
        } else try std.testing.expectError(error.UnexpectedFrameType, frameType(&bytes));
    }
    for ([_][]const u8{ "", &.{protocol_version} }) |bytes|
        try std.testing.expectError(error.TruncatedPayload, frameType(bytes));
}

test "chunk decoder rejects forged lengths versions and trailing bytes" {
    try std.testing.expectError(error.InvalidLength, decodeChunk(&.{ 1, 4, 0, 0, 0, 1 }, .request_chunk));
    try std.testing.expectError(error.InvalidLength, decodeChunk(&.{ 1, 4, 0, 0, 0, 0, 7 }, .request_chunk));
    try std.testing.expectError(error.UnsupportedVersion, decodeChunk(&.{ 9, 4, 0, 0, 0, 0 }, .request_chunk));
    try std.testing.expectError(error.FrameTooLarge, decodeWireFrame(&.{ 255, 255, 255, 255 }));
}

const test_descriptor = [_]u8{
    0,   0,   0, 3, 'G', 'E', 'T', 0, 0, 0, 4,   'h', 't', 't', 'p', 0,   0,   0,   0,
    0,   0,   0, 1, '/', 0,   0,   0, 0, 0, 0,   0,   8,   'H', 'T', 'T', 'P', '/', '1',
    '.', '1', 0, 0, 0,   1,   0,   0, 0, 1, 'x', 0,   0,   0,   1,   'y',
};

test "request descriptor rejects every truncated prefix" {
    for (0..test_descriptor.len) |len| {
        const result = decodeRequestHeadDescriptor(std.testing.allocator, test_descriptor[0..len]);
        if (result) |head| {
            std.testing.allocator.free(head.headers);
            return error.AcceptedTruncatedDescriptor;
        } else |err| try std.testing.expect(err == error.TruncatedPayload or err == error.InvalidLength);
    }
    const head = try decodeRequestHeadDescriptor(std.testing.allocator, &test_descriptor);
    defer std.testing.allocator.free(head.headers);
    try std.testing.expectEqualStrings("GET", head.method);
    try std.testing.expectEqualStrings("/", head.path);
    try std.testing.expectEqualStrings("y", head.headers[0].value);
}

fn descriptorAllocation(allocator: std.mem.Allocator) !void {
    const head = try decodeRequestHeadDescriptor(allocator, &test_descriptor);
    defer allocator.free(head.headers);
    const size = try requestStartEncodedSize(head);
    const out = try allocator.alloc(u8, size);
    defer allocator.free(out);
    try std.testing.expectEqual(size, (try encodeRequestStart(head, out)).len);
}

test "request descriptor and tokenized output unwind allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, descriptorAllocation, .{});
}

test "request descriptor rejects trailing data and hostile field counts" {
    const extra = test_descriptor ++ [_]u8{0};
    try std.testing.expectError(error.InvalidLength, decodeRequestHeadDescriptor(std.testing.allocator, &extra));
    var empty = [_]u8{0} ** 28;
    @memset(empty[24..28], 255);
    try std.testing.expectError(error.FrameTooLarge, decodeRequestHeadDescriptor(std.testing.allocator, &empty));
    @memset(empty[0..4], 255);
    try std.testing.expectError(error.TruncatedPayload, decodeRequestHeadDescriptor(std.testing.allocator, &empty));
}

test "request encoded size matches all token and connection normalization branches" {
    const names = [_][]const u8{ "host", "x-custom", "connection", "x-server-native-connection" };
    const values = [_][]const u8{ "", "foo", "keep-alive, upgrade", " , \t , ", "__server_native_empty_connection__" };
    for (names) |name| for (values) |value| {
        const head: RequestHead = .{ .method = "POST", .scheme = "https", .authority = "test", .path = "/", .query = "a=b", .protocol = "HTTP/2", .headers = &.{.{ .name = name, .value = value }} };
        const size = try requestStartEncodedSize(head);
        const out = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(out);
        try std.testing.expectEqual(size, (try encodeRequestStart(head, out)).len);
        try std.testing.expectError(error.BufferTooSmall, encodeRequestStart(head, out[0 .. size - 1]));
    };
}

test "request start rejects every undersized output buffer without overwriting guards" {
    const head: RequestHead = .{ .method = "POST", .scheme = "https", .authority = "example.test", .path = "/echo", .query = "a=1", .protocol = "HTTP/3", .headers = &.{.{ .name = "x-custom", .value = "value" }} };
    const size = try requestStartEncodedSize(head);
    const buffer = try std.testing.allocator.alloc(u8, size + 2);
    defer std.testing.allocator.free(buffer);
    for (0..size) |length| {
        @memset(buffer, 0xa5);
        try std.testing.expectError(error.BufferTooSmall, encodeRequestStart(head, buffer[1..][0..length]));
        try std.testing.expectEqual(@as(u8, 0xa5), buffer[0]);
        for (buffer[length + 1 ..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    }
    try std.testing.expectEqual(size, (try encodeRequestStart(head, buffer[1..][0..size])).len);
}

test "wire length decoder rejects oversized prefixes before requiring payload" {
    try std.testing.expectError(error.FrameTooLarge, decodeWireFrame(&.{ 4, 0, 0, 1 }));
    try std.testing.expectError(error.FrameTooLarge, decodeWireFrame(&.{ 255, 255, 255, 255 }));
    try std.testing.expectEqualSlices(u8, "", try decodeWireFrame(&.{ 0, 0, 0, 0 }));
}
