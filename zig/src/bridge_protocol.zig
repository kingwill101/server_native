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
    return std.meta.intToEnum(FrameType, payload[1]) catch {
        return error.UnexpectedFrameType;
    };
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
