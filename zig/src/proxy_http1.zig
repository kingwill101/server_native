const std = @import("std");
const bridge_protocol = @import("bridge_protocol.zig");
const bridge_io = @import("bridge_io.zig");
const http1 = @import("http1.zig").posix;

pub const max_header_bytes: usize = 64 * 1024;
pub const max_body_bytes: usize = 32 * 1024 * 1024;

pub fn serveConnection(
    allocator: std.mem.Allocator,
    server: anytype,
    connection: *http1.Connection,
    input: *std.ArrayList(u8),
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const request_allocator = arena.allocator();

    var scratch: [8192]u8 = undefined;
    var header_end: ?usize = null;
    var content_length: usize = 0;
    var chunked_body = false;

    while (header_end == null) {
        if (server.stopped.load(.acquire)) return false;
        if (std.mem.indexOf(u8, input.items, "\r\n\r\n")) |index| {
            header_end = index + 4;
            const header_bytes = input.items[0..index];
            content_length = parseContentLength(header_bytes) catch return error.InvalidContentLength;
            chunked_body = try parseTransferEncoding(header_bytes);
            if (content_length > max_body_bytes) return error.BodyTooLarge;
            if (header_end.? > max_header_bytes) return error.HeadersTooLarge;
            break;
        }
        if (input.items.len > max_header_bytes) return error.HeadersTooLarge;
        const count = (try http1.receiveTimeoutConnection(connection, &scratch, 50)) orelse continue;
        if (count == 0) return false;
        try input.appendSlice(allocator, scratch[0..count]);
    }

    var scanner: ChunkScanner = .{};
    var body_end: usize = undefined;
    var idle_body_reads: u16 = 0;
    while (true) {
        if (chunked_body) {
            if (try scanner.scan(input.items[header_end.?..])) |end| {
                body_end = header_end.? + end;
                break;
            }
        } else if (input.items.len >= header_end.? + content_length) {
            body_end = header_end.? + content_length;
            break;
        }
        const count = (try http1.receiveTimeoutConnection(connection, &scratch, 50)) orelse {
            idle_body_reads += 1;
            if (idle_body_reads >= 20) return error.RequestBodyTimeout;
            continue;
        };
        idle_body_reads = 0;
        if (count == 0) return error.ConnectionClosed;
        try input.appendSlice(allocator, scratch[0..count]);
        if (input.items.len > header_end.? + max_body_bytes + max_header_bytes) return error.BodyTooLarge;
    }
    // Keep bytes belonging to the next request until its handler runs.
    defer {
        const remaining = input.items.len - body_end;
        std.mem.copyForwards(u8, input.items[0..remaining], input.items[body_end..]);
        input.items.len = remaining;
    }

    var lines = std.mem.splitSequence(u8, input.items[0 .. header_end.? - 4], "\r\n");
    const request_line = lines.next() orelse return error.InvalidRequest;
    const first_space = std.mem.indexOfScalar(u8, request_line, ' ') orelse return error.InvalidRequest;
    const second_space = std.mem.indexOfScalarPos(u8, request_line, first_space + 1, ' ') orelse return error.InvalidRequest;
    const method = request_line[0..first_space];
    const target = request_line[first_space + 1 .. second_space];
    const protocol = request_line[second_space + 1 ..];
    if (!std.mem.eql(u8, protocol, "HTTP/1.0") and !std.mem.eql(u8, protocol, "HTTP/1.1")) return error.InvalidRequest;
    if (std.mem.indexOfScalar(u8, target, '#') != null) return error.InvalidRequestTarget;

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
        .protocol = protocol[5..],
        .headers = headers.items,
    };

    if (server.benchmark_mode != 0) {
        var response: bridge_io.Response = .{};
        defer response.deinit(allocator);
        try bridge_io.benchmarkResponse(allocator, &response);
        try writeHttpResponse(allocator, connection, response.status, response.headers.items, response.body.items, keep_alive);
        return keep_alive;
    }

    const request_id = server.next_request_id.fetchAdd(1, .monotonic);
    if (!server.registerRequest(request_id)) return error.RequestQueueClosed;
    defer server.discardRequest(request_id);

    const start_size = try bridge_protocol.requestStartEncodedSize(head);
    const start = try allocator.alloc(u8, start_size);
    defer allocator.free(start);
    _ = try bridge_protocol.encodeRequestStart(head, start);
    if (!server.bridgeEnabled()) try server.queue.push(@bitCast(request_id), start);

    const body = if (chunked_body)
        try decodeChunkedBody(request_allocator, input.items[header_end.?..body_end])
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

    var response = bridge_io.Response{};
    defer response.deinit(allocator);
    var response_done = false;
    while (!response_done and !server.stopped.load(.acquire)) {
        const frame = server.takeResponse(request_id) orelse {
            std.atomic.spinLoopHint();
            continue;
        };
        defer allocator.free(frame);
        if (frame.len == 3 and frame[0] == 1 and frame[1] == 15) {
            try server.detachConnection(connection.fd);
            try server.queue.push(@bitCast(request_id), &.{ 1, 16 });
            if (frame[2] == 1) {
                try runDirectTunnel(allocator, server, request_id, connection);
                return false;
            }
            continue;
        }
        try bridge_io.decodeResponseFrame(allocator, frame, &response, &response_done);
        if (upgrade and response.status == 101) {
            try writeUpgradeResponse(allocator, connection, response.status, response.headers.items);
            try runDirectTunnel(allocator, server, request_id, connection);
            return false;
        }
    }
    if (!response_done or server.stopped.load(.acquire)) return false;
    try @import("proxy_request.zig").advertiseHttp3(allocator, server, &response);
    try writeHttpResponse(allocator, connection, response.status, response.headers.items, response.body.items, keep_alive);
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
    var backend = server.connectBackend() catch |err| {
        return writeBridgeFailure(allocator, connection, "bridge call failed", err);
    };
    if (!server.trackConnection(backend.fd)) {
        backend.close();
        return false;
    }
    defer server.closeConnection(&backend);

    const start_len = try bridge_protocol.requestStartEncodedSize(head);
    const request = try allocator.alloc(u8, start_len);
    defer allocator.free(request);
    _ = try bridge_protocol.encodeRequestStart(head, request);
    try bridge_io.sendFrame(allocator, backend.fd, request);
    if (body.len != 0) {
        const chunk = try allocator.alloc(u8, 6 + body.len);
        defer allocator.free(chunk);
        _ = try bridge_protocol.encodeChunk(.request_chunk, body, chunk);
        try bridge_io.sendFrame(allocator, backend.fd, chunk);
    }
    try bridge_io.sendFrame(allocator, backend.fd, &.{ 1, 5 });

    var response = bridge_io.Response{};
    defer response.deinit(allocator);
    var done = false;
    while (!done) {
        const payload = bridge_io.receiveFrame(allocator, backend.fd) catch |err| {
            return writeBridgeFailure(allocator, connection, if (response.ready)
                "bridge call failed before response end"
            else
                "bridge call failed: read frame header failed", err);
        };
        defer allocator.free(payload);
        if (payload.len == 3 and payload[0] == 1 and payload[1] == 15) {
            try server.detachConnection(connection.fd);
            try server.detachConnection(backend.fd);
            try bridge_io.sendFrame(allocator, backend.fd, &.{ 1, 16 });
            if (payload[2] == 1) {
                try runTunnel(allocator, server, backend.fd, connection);
                return false;
            }
            continue;
        }
        if (!response.ready and payload.len >= 2 and payload[0] == bridge_protocol.protocol_version) {
            switch (payload[1]) {
                2, 6, 12, 14 => {},
                else => return writeBridgeFailure(allocator, connection, "bridge call failed: decode response failed: invalid bridge response frame type", error.InvalidResponse),
            }
        }
        bridge_io.decodeResponseFrame(allocator, payload, &response, &done) catch |err| {
            return writeBridgeFailure(allocator, connection, "bridge call failed: decode response failed", err);
        };
        if (upgrade and response.status == 101 and (payload[1] == @intFromEnum(bridge_protocol.FrameType.response_start) or payload[1] == @intFromEnum(bridge_protocol.FrameType.response_start_tokenized))) {
            try writeUpgradeResponse(allocator, connection, response.status, response.headers.items);
            try runTunnel(allocator, server, backend.fd, connection);
            return false;
        }
    }
    if (upgrade and response.status == 101) {
        try writeUpgradeResponse(allocator, connection, response.status, response.headers.items);
        try runTunnel(allocator, server, backend.fd, connection);
        return false;
    }
    try @import("proxy_request.zig").advertiseHttp3(allocator, server, &response);
    try writeHttpResponse(allocator, connection, response.status, response.headers.items, response.body.items, keep_alive);
    return keep_alive;
}

fn writeBridgeFailure(allocator: std.mem.Allocator, connection: *http1.Connection, context: []const u8, err: anyerror) !bool {
    const message = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ context, @errorName(err) });
    defer allocator.free(message);
    try writeHttpResponse(allocator, connection, 502, &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }}, message, false);
    return false;
}

fn runDirectTunnel(allocator: std.mem.Allocator, server: anytype, request_id: u64, client: *http1.Connection) !void {
    const client_fd = client.fd;
    const response_wake = try server.enableResponseWake(request_id);
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
                .tunnel_chunk => try http1.sendAllConnection(client, try bridge_protocol.decodeChunk(frame, .tunnel_chunk)),
                .tunnel_close => {
                    output_closed = true;
                    http1.shutdownWrite(client_fd);
                },
                .response_end => {},
                else => return error.UnexpectedTunnelFrame,
            }
        }
        if (input_closed and output_closed) return;
        const available = if (input_closed) null else try http1.receiveTimeoutConnection(client, &buffer, 0);
        const count = available orelse {
            var descriptors = [_]std.posix.pollfd{
                .{ .fd = if (input_closed) -1 else client_fd, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = response_wake, .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = try std.posix.poll(&descriptors, 100);
            if (descriptors[1].revents & std.posix.POLL.IN != 0) http1.WakeSignal.drain(response_wake);
            continue;
        };
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

fn runTunnel(allocator: std.mem.Allocator, server: anytype, backend_fd: http1.Fd, client: *http1.Connection) !void {
    const client_fd = client.fd;
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
            const count = http1.receiveConnection(client, &client_buffer) catch return;
            if (count == 0) {
                var close_payload: [2]u8 = undefined;
                _ = bridge_protocol.encodeTerminal(.tunnel_close, &close_payload) catch return;
                bridge_io.sendFrame(allocator, backend_fd, &close_payload) catch {};
                input_closed = true;
                continue;
            }
            const payload = try allocator.alloc(u8, 6 + count);
            defer allocator.free(payload);
            _ = try bridge_protocol.encodeChunk(.tunnel_chunk, client_buffer[0..count], payload);
            try bridge_io.sendFrame(allocator, backend_fd, payload);
        }
        if (descriptors[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            const count = http1.receive(backend_fd, &backend_buffer) catch return;
            if (count == 0) return;
            try backend_input.appendSlice(allocator, backend_buffer[0..count]);
            while (backend_input.items.len >= 4) {
                const length = bridge_io.frameLength(backend_input.items[0..4]);
                if (length > bridge_protocol.max_frame_bytes) return error.FrameTooLarge;
                if (backend_input.items.len < 4 + length) break;
                const payload = backend_input.items[4 .. 4 + length];
                const kind = bridge_protocol.frameType(payload) catch return error.UnexpectedTunnelFrame;
                switch (kind) {
                    .tunnel_chunk => try http1.sendAllConnection(client, try bridge_protocol.decodeChunk(payload, .tunnel_chunk)),
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

fn parseTransferEncoding(headers: []const u8) !bool {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    var present = false;
    var last: []const u8 = "";
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (asciiEqualIgnoreCase(line[0..colon], "transfer-encoding")) {
            present = true;
            var tokens = std.mem.splitScalar(u8, line[colon + 1 ..], ',');
            while (tokens.next()) |token| {
                const normalized = trim(token);
                if (normalized.len != 0) last = normalized;
            }
        }
    }
    // Request framing is indeterminate unless the final coding is chunked.
    // Consider all field lines, not merely the first one containing chunked.
    if (present and !asciiEqualIgnoreCase(last, "chunked")) return error.InvalidTransferEncoding;
    return present;
}

const ChunkScanner = struct {
    offset: usize = 0,
    decoded_bytes: usize = 0,

    fn scan(self: *ChunkScanner, encoded: []const u8) !?usize {
        while (true) {
            const line_end = std.mem.indexOfPos(u8, encoded, self.offset, "\r\n") orelse {
                if (encoded.len - self.offset > max_header_bytes) return error.InvalidChunkedBody;
                return null;
            };
            const line = encoded[self.offset..line_end];
            const size_text = if (std.mem.indexOfScalar(u8, line, ';')) |end| line[0..end] else line;
            const size = std.fmt.parseUnsigned(usize, trim(size_text), 16) catch return error.InvalidChunkedBody;
            const start = line_end + 2;
            if (size > max_body_bytes - self.decoded_bytes) return error.BodyTooLarge;
            if (encoded.len - start < size + 2) return null;
            const end = start + size;
            if (!std.mem.eql(u8, encoded[end..][0..2], "\r\n")) return error.InvalidChunkedBody;
            if (size == 0) return end + 2;
            self.offset = end + 2;
            self.decoded_bytes += size;
        }
    }
};

fn decodeChunkedBody(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
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

fn writeUpgradeResponse(allocator: std.mem.Allocator, connection: *http1.Connection, status: u16, headers: []const bridge_protocol.Header) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try appendFormat(allocator, &output, "HTTP/1.1 {d} {s}\r\n", .{ status, reason(status) });
    for (headers) |header| try appendFormat(allocator, &output, "{s}: {s}\r\n", .{ header.name, header.value });
    try output.appendSlice(allocator, "\r\n");
    try http1.sendAllConnection(connection, output.items);
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
    connection: *http1.Connection,
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
    try http1.sendAllConnection(connection, output.items);
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

test "HTTP1 transfer encoding uses a case insensitive final coding" {
    try std.testing.expect(try parseTransferEncoding("POST / HTTP/1.1\r\nTrAnSfEr-EnCoDiNg: gzip, CHUNKED\r\n"));
    try std.testing.expectError(error.InvalidTransferEncoding, parseTransferEncoding("GET / HTTP/1.1\r\nTransfer-Encoding: chunked, gzip\r\n"));
    try std.testing.expect(!try parseTransferEncoding("GET / HTTP/1.1\r\nX-Transfer-Encoding: chunked\r\n"));
    try std.testing.expectError(error.InvalidTransferEncoding, parseTransferEncoding("GET / HTTP/1.1\r\nTransfer-Encoding: xchunked\r\n"));
}

test "HTTP1 content length rejects invalid digits overflow and negative values" {
    try std.testing.expectEqual(@as(usize, 0), try parseContentLength("GET / HTTP/1.1\r\nHost: test"));
    try std.testing.expectEqual(@as(usize, 42), try parseContentLength("POST / HTTP/1.1\r\nCONTENT-LENGTH: \t42\t "));
    for ([_][]const u8{ "-1", "1x", "", "184467440737095516160" }) |value| {
        const headers = try std.fmt.allocPrint(std.testing.allocator, "POST / HTTP/1.1\r\nContent-Length: {s}", .{value});
        defer std.testing.allocator.free(headers);
        if (parseContentLength(headers)) |_| return error.AcceptedInvalidLength else |_| {}
    }
}

fn chunkedAllocation(allocator: std.mem.Allocator) !void {
    const decoded = try decodeChunkedBody(allocator, "3;ext=value\r\na\x00b\r\n2\r\ncd\r\n0\r\n\r\n");
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, "a\x00bcd", decoded);
}

test "HTTP1 chunked body decodes binary extensions and unwinds allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, chunkedAllocation, .{});
    const empty = try decodeChunkedBody(std.testing.allocator, "0\r\n\r\n");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "HTTP1 malformed chunk suffix releases previously decoded chunks" {
    for ([_][]const u8{ "1\r\nx\r\n", "1\r\nx\r\nZ\r\n", "1\r\nxZZ", "1\r\nx\r\n2\r\ny", "2000001\r\n" }) |body| {
        if (decodeChunkedBody(std.testing.allocator, body)) |decoded| {
            std.testing.allocator.free(decoded);
            return error.AcceptedInvalidChunk;
        } else |err| try std.testing.expect(err == error.InvalidChunkedBody or err == error.BodyTooLarge);
    }
}

test "HTTP1 keepalive respects protocol and exact comma separated connection tokens" {
    const Header = bridge_protocol.Header;
    try std.testing.expect(requestKeepsAlive("HTTP/1.1", &.{}));
    try std.testing.expect(!requestKeepsAlive("HTTP/1.0", &.{}));
    for ([_][]const u8{ "close", "Keep-Alive, CLOSE", "\tclose " }) |value| {
        try std.testing.expect(!requestKeepsAlive("HTTP/1.1", &.{Header{ .name = "Connection", .value = value }}));
    }
    try std.testing.expect(requestKeepsAlive("HTTP/1.0", &.{Header{ .name = "connection", .value = "upgrade, KEEP-ALIVE" }}));
    try std.testing.expect(requestKeepsAlive("HTTP/1.1", &.{Header{ .name = "connection", .value = "disclose" }}));
    try std.testing.expect(!requestKeepsAlive("HTTP/1.1", &.{Header{ .name = "connection", .value = " \t" }}));
}

test "HTTP1 upgrade requires both a protocol and an exact connection token" {
    const upgrade: bridge_protocol.Header = .{ .name = "Upgrade", .value = "websocket" };
    try std.testing.expect(!requestIsUpgrade(&.{upgrade}));
    try std.testing.expect(!requestIsUpgrade(&.{ upgrade, .{ .name = "connection", .value = "xupgrade" } }));
    try std.testing.expect(requestIsUpgrade(&.{ upgrade, .{ .name = "CONNECTION", .value = "keep-alive, Upgrade" } }));
    try std.testing.expect(!requestIsUpgrade(&.{ .{ .name = "upgrade", .value = " \t" }, .{ .name = "connection", .value = "upgrade" } }));
}

test "HTTP1 response writer supplies framing without duplicating application headers" {
    const c = @cImport({
        @cInclude("sys/socket.h");
        @cInclude("unistd.h");
    });
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds));
    var connection: http1.Connection = .{ .fd = fds[0] };
    defer connection.close();
    defer _ = c.close(fds[1]);
    try writeHttpResponse(std.testing.allocator, &connection, 201, &.{}, "a\x00b", true);
    var buffer: [1024]u8 = undefined;
    const count = (try http1.receiveTimeout(fds[1], &buffer, 1000)) orelse return error.NoResponse;
    try std.testing.expectEqualStrings("HTTP/1.1 201 Created\r\ncontent-length: 3\r\nconnection: keep-alive\r\n\r\na\x00b", buffer[0..count]);
    try writeHttpResponse(std.testing.allocator, &connection, 200, &.{ .{ .name = "Content-Length", .value = "1" }, .{ .name = "Connection", .value = "close" } }, "x", false);
    const second = (try http1.receiveTimeout(fds[1], &buffer, 1000)) orelse return error.NoResponse;
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx", buffer[0..second]);
    try writeUpgradeResponse(std.testing.allocator, &connection, 101, &.{.{ .name = "upgrade", .value = "websocket" }});
    const upgraded = (try http1.receiveTimeout(fds[1], &buffer, 1000)) orelse return error.NoResponse;
    try std.testing.expectEqualStrings("HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\n\r\n", buffer[0..upgraded]);
}

fn rejectRequest(wire: []const u8, expected: anyerror) !void {
    const c = @cImport({
        @cInclude("sys/socket.h");
        @cInclude("unistd.h");
    });
    const a = std.testing.allocator;
    var queue = try @import("event_queue.zig").Queue.init(a, 4);
    defer queue.deinit();
    const Server = @import("proxy.zig").ProxyServer;
    var server: Server = .{ .allocator = a, .queue = &queue, .pending = .init(a), .listener = .{ .fd = -1, .port = 0 }, .port = 0 };
    defer server.pending.deinit();
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds));
    var connection: http1.Connection = .{ .fd = fds[0] };
    defer connection.close();
    defer _ = c.close(fds[1]);
    try http1.sendAll(fds[1], wire);
    http1.shutdownWrite(fds[1]);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    try std.testing.expectError(expected, serveConnection(a, &server, &connection, &input));
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    try std.testing.expectEqual(@as(u32, 0), server.pending.count());
}

test "HTTP1 rejects malformed request lines and headers before Dart dispatch" {
    try rejectRequest("bogus\r\n\r\n", error.InvalidRequest);
    try rejectRequest("GET / NOTHTTP\r\n\r\n", error.InvalidRequest);
    try rejectRequest("GET / HTTP/1.1\r\nmissing-colon\r\n\r\n", error.InvalidRequest);
    try rejectRequest("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n", error.InvalidContentLength);
    try rejectRequest("POST / HTTP/1.1\r\nContent-Length: 33554433\r\n\r\n", error.BodyTooLarge);
}

test "HTTP1 rejects peer EOF in a declared body and oversized headers" {
    try rejectRequest("POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\nx", error.ConnectionClosed);
    const wire = try std.testing.allocator.alloc(u8, max_header_bytes + 1);
    defer std.testing.allocator.free(wire);
    @memset(wire, 'x');
    try rejectRequest(wire, error.HeadersTooLarge);
}

fn responseWriterAllocation(allocator: std.mem.Allocator) !void {
    var connection: http1.Connection = .{ .fd = -1 };
    writeHttpResponse(allocator, &connection, 200, &.{.{ .name = "x-one", .value = "value" }}, "body", false) catch |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(error.SendFailed, err);
        return;
    };
    return error.UnexpectedWriteSuccess;
}

test "HTTP1 response construction releases allocations on OOM and socket failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, responseWriterAllocation, .{});
}

test "HTTP1 framing rejects unknown empty and non-final transfer codings across field lines" {
    for ([_][]const u8{
        "Transfer-Encoding:",
        "Transfer-Encoding: custom-encoding",
        "Transfer-Encoding: chunked\r\nTransfer-Encoding: gzip",
        "Transfer-Encoding: , ,",
    }) |field| {
        const headers = try std.fmt.allocPrint(std.testing.allocator, "POST / HTTP/1.1\r\n{s}\r\n", .{field});
        defer std.testing.allocator.free(headers);
        try std.testing.expectError(error.InvalidTransferEncoding, parseTransferEncoding(headers));
    }
    try std.testing.expect(try parseTransferEncoding("POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: , CHUNKED, \r\n"));
    try std.testing.expect(!try parseTransferEncoding("GET / HTTP/1.1\r\nHost: test\r\n"));
}

test "chunk scanner handles every split and leaves pipelined bytes untouched" {
    const wire = "5\r\n\r\n0\r\n\r\n0;done=yes\r\n\r\n";
    for (0..wire.len) |split| {
        var scanner: ChunkScanner = .{};
        try std.testing.expectEqual(@as(?usize, null), try scanner.scan(wire[0..split]));
        try std.testing.expectEqual(@as(?usize, wire.len), try scanner.scan(wire ++ "GET /next HTTP/1.1\r\n\r\n"));
    }
    var empty: ChunkScanner = .{};
    try std.testing.expectEqual(@as(?usize, 5), try empty.scan("0\r\n\r\nGET /next"));
}

test "chunk scanner rejects missing delimiters and decoded body overflow" {
    var malformed: ChunkScanner = .{};
    try std.testing.expectError(error.InvalidChunkedBody, malformed.scan("1\r\nxXX"));
    var oversized: ChunkScanner = .{};
    try std.testing.expectError(error.BodyTooLarge, oversized.scan("2000001\r\n"));
}
