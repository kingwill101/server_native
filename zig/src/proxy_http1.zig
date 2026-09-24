const std = @import("std");
const bridge_protocol = @import("bridge_protocol.zig");
const http1 = @import("http1.zig").posix;

pub const max_header_bytes: usize = 64 * 1024;
pub const max_body_bytes: usize = 32 * 1024 * 1024;

pub fn serveConnection(
    allocator: std.mem.Allocator,
    server: anytype,
    connection: *http1.Connection,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const request_allocator = arena.allocator();

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    var scratch: [8192]u8 = undefined;
    var header_end: ?usize = null;
    var content_length: usize = 0;
    var chunked_body = false;

    while (header_end == null) {
        const count = try http1.receive(connection.fd, &scratch);
        if (count == 0) return false;
        try input.appendSlice(allocator, scratch[0..count]);
        if (input.items.len > max_header_bytes) return error.HeadersTooLarge;
        if (std.mem.indexOf(u8, input.items, "\r\n\r\n")) |index| {
            header_end = index + 4;
            const header_bytes = input.items[0..index];
            content_length = parseContentLength(header_bytes) catch return error.InvalidContentLength;
            chunked_body = hasChunkedEncoding(header_bytes);
            if (content_length > max_body_bytes) return error.BodyTooLarge;
        }
    }

    var idle_body_reads: u16 = 0;
    while ((chunked_body and std.mem.indexOf(u8, input.items[header_end.?..], "\r\n0\r\n\r\n") == null) or
        (!chunked_body and input.items.len < header_end.? + content_length))
    {
        const count = (try http1.receiveTimeout(connection.fd, &scratch, 50)) orelse {
            idle_body_reads += 1;
            if (idle_body_reads >= 20) return error.RequestBodyTimeout;
            continue;
        };
        idle_body_reads = 0;
        if (count == 0) return error.ConnectionClosed;
        try input.appendSlice(allocator, scratch[0..count]);
        if (!chunked_body and input.items.len > header_end.? + content_length) break;
        if (input.items.len > header_end.? + max_body_bytes + 128) return error.BodyTooLarge;
    }

    var lines = std.mem.splitSequence(u8, input.items[0 .. header_end.? - 4], "\r\n");
    const request_line = lines.next() orelse return error.InvalidRequest;
    const first_space = std.mem.indexOfScalar(u8, request_line, ' ') orelse return error.InvalidRequest;
    const second_space = std.mem.indexOfScalarPos(u8, request_line, first_space + 1, ' ') orelse return error.InvalidRequest;
    const method = request_line[0..first_space];
    const target = request_line[first_space + 1 .. second_space];
    const protocol = request_line[second_space + 1 ..];
    if (!std.mem.startsWith(u8, protocol, "HTTP/")) return error.InvalidRequest;

    var headers: std.ArrayList(bridge_protocol.Header) = .empty;
    defer headers.deinit(request_allocator);
    var authority: []const u8 = "";
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidRequest;
        const name_raw = line[0..colon];
        const value = trim(line[colon + 1 ..]);
        const name = try request_allocator.alloc(u8, name_raw.len);
        for (name_raw, 0..) |byte, index| name[index] = std.ascii.toLower(byte);
        try headers.append(request_allocator, .{ .name = name, .value = value });
        if (std.mem.eql(u8, name, "host")) authority = value;
    }

    const query = if (std.mem.indexOfScalar(u8, target, '?')) |index| target[index + 1 ..] else "";
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |index| target[0..index] else target;
    const keep_alive = requestKeepsAlive(protocol, headers.items);
    const upgrade = requestIsUpgrade(headers.items);
    const head = bridge_protocol.RequestHead{
        .method = method,
        .scheme = "http",
        .authority = authority,
        .path = if (path.len == 0) "/" else path,
        .query = query,
        .protocol = protocol,
        .headers = headers.items,
    };

    const request_id = server.next_request_id.fetchAdd(1, .monotonic);
    if (!server.registerRequest(request_id)) return error.RequestQueueClosed;
    defer server.discardRequest(request_id);

    const start_size = try bridge_protocol.requestStartEncodedSize(head);
    const start = try allocator.alloc(u8, start_size);
    defer allocator.free(start);
    _ = try bridge_protocol.encodeRequestStart(head, start);
    try server.queue.push(@bitCast(request_id), start);

    const body = if (chunked_body)
        try decodeChunkedBody(request_allocator, input.items[header_end.?..])
    else
        input.items[header_end.? .. header_end.? + content_length];
    if (server.bridgeEnabled()) {
        return serveBridge(allocator, server, connection, head, body, keep_alive, upgrade);
    }
    if (body.len != 0) {
        const chunk = try allocator.alloc(u8, 6 + body.len);
        defer allocator.free(chunk);
        _ = try bridge_protocol.encodeChunk(.request_chunk, body, chunk);
        try server.queue.push(@bitCast(request_id), chunk);
    }
    var terminal: [2]u8 = undefined;
    _ = try bridge_protocol.encodeTerminal(.request_end, &terminal);
    try server.queue.push(@bitCast(request_id), &terminal);

    var response_headers: std.ArrayList(bridge_protocol.Header) = .empty;
    defer {
        for (response_headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        response_headers.deinit(allocator);
    }
    var response_body: std.ArrayList(u8) = .empty;
    defer response_body.deinit(allocator);
    var response_status: u16 = 500;
    var response_done = false;
    while (!response_done and !server.stopped.load(.acquire)) {
        const frame = server.takeResponse(request_id) orelse {
            std.atomic.spinLoopHint();
            continue;
        };
        defer allocator.free(frame);
        try decodeResponseFrame(
            allocator,
            frame,
            &response_status,
            &response_headers,
            &response_body,
            &response_done,
        );
        if (upgrade and response_status == 101) {
            try writeUpgradeResponse(allocator, connection.fd, response_status, response_headers.items);
            try runDirectTunnel(allocator, server, request_id, connection.fd);
            return false;
        }
    }
    if (!response_done) return error.ResponseUnavailable;
    try writeHttpResponse(allocator, connection.fd, response_status, response_headers.items, response_body.items, keep_alive);
    return keep_alive;
}

fn serveBridge(
    allocator: std.mem.Allocator,
    server: anytype,
    connection: *http1.Connection,
    head: bridge_protocol.RequestHead,
    body: []const u8,
    keep_alive: bool,
    upgrade: bool,
) !bool {
    var backend = try server.connectBackend();
    defer backend.close();

    const start_len = try bridge_protocol.requestStartEncodedSize(head);
    // The request body is already buffered. A complete frame also allows
    // upgrade handlers to detach without subscribing to a body stream.
    const request = try allocator.alloc(u8, start_len + 4 + body.len);
    defer allocator.free(request);
    _ = try bridge_protocol.encodeRequest(head, body, request);
    try sendWireFrame(allocator, backend.fd, request);

    var response_headers: std.ArrayList(bridge_protocol.Header) = .empty;
    defer {
        for (response_headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        response_headers.deinit(allocator);
    }
    var response_body: std.ArrayList(u8) = .empty;
    defer response_body.deinit(allocator);
    var status: u16 = 500;
    var done = false;
    while (!done) {
        var length_bytes: [4]u8 = undefined;
        try receiveExact(backend.fd, &length_bytes);
        const length = readWireU32(length_bytes[0..]);
        if (length > bridge_protocol.max_frame_bytes) return error.FrameTooLarge;
        const payload = try allocator.alloc(u8, length);
        defer allocator.free(payload);
        try receiveExact(backend.fd, payload);
        try decodeResponseFrame(allocator, payload, &status, &response_headers, &response_body, &done);
        if (upgrade and status == 101 and (payload[1] == @intFromEnum(bridge_protocol.FrameType.response_start) or payload[1] == @intFromEnum(bridge_protocol.FrameType.response_start_tokenized))) {
            try writeUpgradeResponse(allocator, connection.fd, status, response_headers.items);
            try runTunnel(allocator, server, backend.fd, connection.fd);
            return false;
        }
    }
    if (upgrade and status == 101) {
        try writeUpgradeResponse(allocator, connection.fd, status, response_headers.items);
        try runTunnel(allocator, server, backend.fd, connection.fd);
        return false;
    }
    try writeHttpResponse(allocator, connection.fd, status, response_headers.items, response_body.items, keep_alive);
    return keep_alive;
}

fn sendWireFrame(allocator: std.mem.Allocator, fd: http1.Fd, payload: []const u8) !void {
    const frame = try allocator.alloc(u8, 4 + payload.len);
    defer allocator.free(frame);
    frame[0] = @intCast((payload.len >> 24) & 0xff);
    frame[1] = @intCast((payload.len >> 16) & 0xff);
    frame[2] = @intCast((payload.len >> 8) & 0xff);
    frame[3] = @intCast(payload.len & 0xff);
    @memcpy(frame[4..], payload);
    try http1.sendAll(fd, frame);
}

fn runDirectTunnel(allocator: std.mem.Allocator, server: anytype, request_id: u64, client_fd: http1.Fd) !void {
    defer {
        var close_payload: [2]u8 = undefined;
        _ = bridge_protocol.encodeTerminal(.tunnel_close, &close_payload) catch unreachable;
        server.queue.push(@bitCast(request_id), &close_payload) catch {};
    }
    var buffer: [8192]u8 = undefined;
    var input_closed = false;
    var output_closed = false;
    while (!server.stopped.load(.acquire)) {
        while (server.takeResponse(request_id)) |frame| {
            defer allocator.free(frame);
            switch (try bridge_protocol.frameType(frame)) {
                .tunnel_chunk => try http1.sendAll(client_fd, try bridge_protocol.decodeChunk(frame, .tunnel_chunk)),
                .tunnel_close => {
                    output_closed = true;
                    http1.shutdownWrite(client_fd);
                },
                .response_end => {},
                else => return error.UnexpectedTunnelFrame,
            }
        }
        if (input_closed and output_closed) return;
        if (input_closed) {
            _ = try std.posix.poll(&.{}, 1);
            continue;
        }
        const count = (try http1.receiveTimeout(client_fd, &buffer, 10)) orelse continue;
        if (count == 0) {
            input_closed = true;
            var end: [2]u8 = undefined;
            _ = try bridge_protocol.encodeTerminal(.tunnel_close, &end);
            try server.queue.push(@bitCast(request_id), &end);
            continue;
        }
        const payload = try allocator.alloc(u8, 6 + count);
        defer allocator.free(payload);
        _ = try bridge_protocol.encodeChunk(.tunnel_chunk, buffer[0..count], payload);
        try server.queue.push(@bitCast(request_id), payload);
    }
}

fn runTunnel(allocator: std.mem.Allocator, server: anytype, backend_fd: http1.Fd, client_fd: http1.Fd) !void {
    var backend_input: std.ArrayList(u8) = .empty;
    defer backend_input.deinit(allocator);
    var client_buffer: [8192]u8 = undefined;
    var backend_buffer: [8192]u8 = undefined;
    var input_closed = false;
    var output_closed = false;
    while ((!input_closed or !output_closed) and !server.stopped.load(.acquire)) {
        var descriptors = [_]std.posix.pollfd{
            .{ .fd = if (input_closed) -1 else client_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = if (output_closed) -1 else backend_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&descriptors, 1000) catch return;
        if (descriptors[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            const count = http1.receive(client_fd, &client_buffer) catch return;
            if (count == 0) {
                var close_payload: [2]u8 = undefined;
                _ = bridge_protocol.encodeTerminal(.tunnel_close, &close_payload) catch return;
                sendWireFrame(allocator, backend_fd, &close_payload) catch {};
                input_closed = true;
                continue;
            }
            const payload = try allocator.alloc(u8, 6 + count);
            defer allocator.free(payload);
            _ = try bridge_protocol.encodeChunk(.tunnel_chunk, client_buffer[0..count], payload);
            try sendWireFrame(allocator, backend_fd, payload);
        }
        if (descriptors[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            const count = http1.receive(backend_fd, &backend_buffer) catch return;
            if (count == 0) return;
            try backend_input.appendSlice(allocator, backend_buffer[0..count]);
            while (backend_input.items.len >= 4) {
                const length = readWireU32(backend_input.items[0..4]);
                if (length > bridge_protocol.max_frame_bytes) return error.FrameTooLarge;
                if (backend_input.items.len < 4 + length) break;
                const payload = backend_input.items[4 .. 4 + length];
                const kind = bridge_protocol.frameType(payload) catch return error.UnexpectedTunnelFrame;
                switch (kind) {
                    .tunnel_chunk => try http1.sendAll(client_fd, try bridge_protocol.decodeChunk(payload, .tunnel_chunk)),
                    .tunnel_close => {
                        output_closed = true;
                        http1.shutdownWrite(client_fd);
                    },
                    .response_end, .response_start, .response_start_tokenized => {},
                    else => return error.UnexpectedTunnelFrame,
                }
                const remaining = backend_input.items.len - (4 + length);
                std.mem.copyForwards(u8, backend_input.items[0..remaining], backend_input.items[4 + length ..]);
                backend_input.items.len = remaining;
            }
        }
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

fn readWireU32(input: []const u8) u32 {
    return (@as(u32, input[0]) << 24) |
        (@as(u32, input[1]) << 16) |
        (@as(u32, input[2]) << 8) |
        @as(u32, input[3]);
}

fn hasChunkedEncoding(headers: []const u8) bool {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (asciiEqualIgnoreCase(line[0..colon], "transfer-encoding")) {
            var tokens = std.mem.splitScalar(u8, line[colon + 1 ..], ',');
            var last: []const u8 = "";
            while (tokens.next()) |token| {
                const normalized = trim(token);
                if (normalized.len != 0) last = normalized;
            }
            if (asciiEqualIgnoreCase(last, "chunked")) return true;
        }
    }
    return false;
}

fn decodeChunkedBody(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    var offset: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, encoded, offset, "\r\n") orelse return error.InvalidChunkedBody;
        const raw_size = trim(encoded[offset..line_end]);
        const size_text = if (std.mem.indexOfScalar(u8, raw_size, ';')) |separator|
            raw_size[0..separator]
        else
            raw_size;
        const size = std.fmt.parseUnsigned(usize, trim(size_text), 16) catch return error.InvalidChunkedBody;
        offset = line_end + 2;
        if (size == 0) return output.toOwnedSlice(allocator);
        if (size > max_body_bytes -| output.items.len or size > encoded.len -| offset) return error.BodyTooLarge;
        try output.appendSlice(allocator, encoded[offset .. offset + size]);
        offset += size;
        if (encoded.len -| offset < 2 or !std.mem.eql(u8, encoded[offset .. offset + 2], "\r\n")) return error.InvalidChunkedBody;
        offset += 2;
    }
}

fn parseContentLength(headers: []const u8) !usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        if (!asciiEqualIgnoreCase(name, "content-length")) continue;
        return std.fmt.parseUnsigned(usize, trim(line[colon + 1 ..]), 10);
    }
    return 0;
}

fn decodeResponseFrame(
    allocator: std.mem.Allocator,
    frame: []const u8,
    status: *u16,
    headers: *std.ArrayList(bridge_protocol.Header),
    body: *std.ArrayList(u8),
    done: *bool,
) !void {
    if (frame.len < 2 or frame[0] != bridge_protocol.protocol_version) return error.InvalidResponse;
    switch (frame[1]) {
        2, 12 => {
            var offset: usize = 2;
            status.* = try readU16(frame, &offset);
            try decodeHeaders(allocator, frame, &offset, headers);
            const bytes = try readBytes(frame, &offset);
            try body.appendSlice(allocator, bytes);
            if (offset != frame.len) return error.InvalidResponse;
            done.* = true;
        },
        6, 14 => {
            var offset: usize = 2;
            status.* = try readU16(frame, &offset);
            try decodeHeaders(allocator, frame, &offset, headers);
            if (offset != frame.len) return error.InvalidResponse;
        },
        7 => {
            var offset: usize = 2;
            const bytes = try readBytes(frame, &offset);
            if (offset != frame.len) return error.InvalidResponse;
            try body.appendSlice(allocator, bytes);
        },
        8 => {
            if (frame.len != 2) return error.InvalidResponse;
            done.* = true;
        },
        else => return error.InvalidResponse,
    }
}

fn decodeHeaders(
    allocator: std.mem.Allocator,
    frame: []const u8,
    offset: *usize,
    headers: *std.ArrayList(bridge_protocol.Header),
) !void {
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
    const names = [_][]const u8{
        "host",              "connection",            "user-agent",             "accept",                   "accept-encoding",
        "accept-language",   "content-type",          "content-length",         "transfer-encoding",        "cookie",
        "set-cookie",        "cache-control",         "pragma",                 "upgrade",                  "authorization",
        "origin",            "referer",               "location",               "server",                   "date",
        "x-forwarded-for",   "x-forwarded-proto",     "x-forwarded-host",       "x-forwarded-port",         "x-request-id",
        "sec-websocket-key", "sec-websocket-version", "sec-websocket-protocol", "sec-websocket-extensions",
    };
    if (token >= names.len) return error.InvalidHeaderToken;
    return allocator.dupe(u8, names[token]);
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
    const result = (@as(u32, frame[offset.*]) << 24) |
        (@as(u32, frame[offset.* + 1]) << 16) |
        (@as(u32, frame[offset.* + 2]) << 8) |
        frame[offset.* + 3];
    offset.* += 4;
    return result;
}

fn writeUpgradeResponse(allocator: std.mem.Allocator, fd: http1.Fd, status: u16, headers: []const bridge_protocol.Header) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try appendFormat(allocator, &output, "HTTP/1.1 {d} {s}\r\n", .{ status, reason(status) });
    for (headers) |header| try appendFormat(allocator, &output, "{s}: {s}\r\n", .{ header.name, header.value });
    try output.appendSlice(allocator, "\r\n");
    try http1.sendAll(fd, output.items);
}

fn requestIsUpgrade(headers: []const bridge_protocol.Header) bool {
    var has_upgrade = false;
    var has_connection_upgrade = false;
    for (headers) |header| {
        if (asciiEqualIgnoreCase(header.name, "upgrade") and trim(header.value).len != 0) has_upgrade = true;
        if (asciiEqualIgnoreCase(header.name, "connection") and containsToken(header.value, "upgrade")) has_connection_upgrade = true;
    }
    return has_upgrade and has_connection_upgrade;
}

fn requestKeepsAlive(protocol: []const u8, headers: []const bridge_protocol.Header) bool {
    var connection_value: []const u8 = "";
    var connection_seen = false;
    for (headers) |header| {
        if (asciiEqualIgnoreCase(header.name, "connection")) {
            connection_seen = true;
            connection_value = header.value;
        }
    }
    if (connection_seen and trim(connection_value).len == 0) return false;
    if (containsToken(connection_value, "close")) return false;
    if (std.mem.eql(u8, protocol, "HTTP/1.0")) return containsToken(connection_value, "keep-alive");
    return true;
}

fn containsToken(value: []const u8, token: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| if (asciiEqualIgnoreCase(trim(part), token)) return true;
    return false;
}

fn writeHttpResponse(
    allocator: std.mem.Allocator,
    fd: http1.Fd,
    status: u16,
    headers: []const bridge_protocol.Header,
    body: []const u8,
    keep_alive: bool,
) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try appendFormat(allocator, &output, "HTTP/1.1 {d} {s}\r\n", .{ status, reason(status) });
    var has_length = false;
    var has_connection = false;
    for (headers) |header| {
        if (asciiEqualIgnoreCase(header.name, "content-length")) has_length = true;
        if (asciiEqualIgnoreCase(header.name, "connection")) has_connection = true;
        try appendFormat(allocator, &output, "{s}: {s}\r\n", .{ header.name, header.value });
    }
    if (!has_length) try appendFormat(allocator, &output, "content-length: {d}\r\n", .{body.len});
    if (!has_connection) {
        if (keep_alive) try output.appendSlice(allocator, "connection: keep-alive\r\n") else try output.appendSlice(allocator, "connection: close\r\n");
    }
    try output.appendSlice(allocator, "\r\n");
    try output.appendSlice(allocator, body);
    try http1.sendAll(fd, output.items);
}

fn appendFormat(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    comptime format: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(text);
    try output.appendSlice(allocator, text);
}

fn reason(status: u16) []const u8 {
    return switch (status) {
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Response",
    };
}

fn trim(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and (value[start] == ' ' or value[start] == '\t')) start += 1;
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) end -= 1;
    return value[start..end];
}

fn asciiEqualIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}
