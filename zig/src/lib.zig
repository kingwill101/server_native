const std = @import("std");
const abi = @import("abi.zig");
const proxy = @import("proxy.zig");

// Zig-only adapters; no new C exports or Dart bindings.
pub const http2 = @import("http2.zig");
pub const http3 = @import("http3.zig");

const c = @cImport({
    @cInclude("dart_api_dl.h");
});

export fn server_native_zig_transport_version() c_int {
    return 1;
}

export fn server_native_zig_start_proxy_server(
    config: ?*anyopaque,
    out_port: ?*u16,
) ?*anyopaque {
    const config_ptr = config orelse return null;
    const port_ptr = out_port orelse return null;
    const typed_config: *const abi.c.ServerNativeProxyConfig = @ptrCast(@alignCast(config_ptr));
    const server = proxy.ProxyServer.create(typed_config, port_ptr) orelse return null;
    return proxy.asHandle(server);
}

export fn server_native_zig_begin_shutdown(handle: ?*anyopaque) void {
    const server = proxy.fromHandle(handle orelse return);
    if (server.http3) |runtime| runtime.beginShutdown();
}

export fn server_native_zig_shutdown_done(handle: ?*anyopaque) bool {
    const server = proxy.fromHandle(handle orelse return true);
    return if (server.http3) |runtime| runtime.shutdownDone() else true;
}

export fn server_native_zig_set_event_port(handle: ?*anyopaque, port: i64) void {
    const server = handle orelse return;
    proxy.fromHandle(server).setEventPort(port);
}

export fn server_native_zig_stop_proxy_server(handle: ?*anyopaque) void {
    const opaque_handle = handle orelse return;
    proxy.fromHandle(opaque_handle).stop();
}

export fn server_native_zig_push_direct_response_frame(
    handle: ?*anyopaque,
    request_id: u64,
    response_payload: ?[*]const u8,
    response_payload_len: u64,
) u8 {
    const opaque_handle = handle orelse return 0;
    const payload = response_payload orelse return 0;
    return @intFromBool(proxy.fromHandle(opaque_handle).pushResponse(
        request_id,
        payload,
        response_payload_len,
    ));
}

export fn server_native_zig_try_push_response(
    handle: ?*anyopaque,
    request_id: u64,
    payload: ?[*]const u8,
    length: u64,
) u8 {
    return @intFromEnum(proxy.fromHandle(handle orelse return 0).tryPushResponse(request_id, payload orelse return 0, length));
}

export fn server_native_zig_consume_request(handle: ?*anyopaque, request_id: u64, count: usize) void {
    proxy.fromHandle(handle orelse return).consumeRequestBytes(request_id, count);
}

export fn server_native_zig_complete_direct_request(
    handle: ?*anyopaque,
    request_id: u64,
    response_payload: ?[*]const u8,
    response_payload_len: u64,
) u8 {
    return server_native_zig_push_direct_response_frame(
        handle,
        request_id,
        response_payload,
        response_payload_len,
    );
}

export fn server_native_zig_poll_direct_request_frame(
    handle: ?*anyopaque,
    timeout_millis: u32,
    out_request_id: ?*u64,
    out_payload: ?*?[*]u8,
    out_payload_len: ?*u64,
) u8 {
    const opaque_handle = handle orelse return 0;
    const request_id_ptr = out_request_id orelse return 0;
    const payload_ptr = out_payload orelse return 0;
    const payload_len_ptr = out_payload_len orelse return 0;
    return @intFromBool(proxy.fromHandle(opaque_handle).poll(
        timeout_millis,
        request_id_ptr,
        payload_ptr,
        payload_len_ptr,
    ));
}

export fn server_native_zig_free_direct_request_payload(
    payload: ?[*]u8,
    payload_len: u64,
) void {
    proxy.freePolledPayload(payload, payload_len);
}

export fn server_native_dart_api_initialize(data: *anyopaque) isize {
    return c.Dart_InitializeApiDL(data);
}

export fn server_native_dart_post_integer(port_id: c.Dart_Port_DL, value: i64) bool {
    var message: c.Dart_CObject = undefined;
    message.type = c.Dart_CObject_kInt64;
    message.value.as_int64 = value;
    return c.Dart_PostCObject_DL.?(port_id, &message);
}

export fn server_native_zig_queue_create(slot_capacity: usize) ?*anyopaque {
    const event_queue = @import("event_queue.zig");
    const queue = std.heap.c_allocator.create(event_queue.Queue) catch return null;
    queue.* = event_queue.Queue.init(
        std.heap.c_allocator,
        slot_capacity,
    ) catch {
        std.heap.c_allocator.destroy(queue);
        return null;
    };
    return @ptrCast(queue);
}

export fn server_native_zig_queue_destroy(handle: ?*anyopaque) void {
    const opaque_handle = handle orelse return;
    const event_queue = @import("event_queue.zig");
    const queue: *event_queue.Queue = @ptrCast(@alignCast(opaque_handle));
    queue.deinit();
    std.heap.c_allocator.destroy(queue);
}

export fn server_native_zig_queue_push(
    handle: *anyopaque,
    request_id: i64,
    payload: [*]const u8,
    payload_len: usize,
) bool {
    const event_queue = @import("event_queue.zig");
    const queue: *event_queue.Queue = @ptrCast(@alignCast(handle));
    queue.push(request_id, payload[0..payload_len]) catch return false;
    return true;
}

export fn server_native_zig_queue_push_request_start(
    handle: *anyopaque,
    request_id: i64,
    descriptor: [*]const u8,
    descriptor_len: usize,
) bool {
    const bridge_protocol = @import("bridge_protocol.zig");
    if (descriptor_len < bridge_protocol.min_request_head_descriptor_bytes or
        descriptor_len > bridge_protocol.max_frame_bytes)
    {
        return false;
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();

    const request = bridge_protocol.decodeRequestHeadDescriptor(
        arena.allocator(),
        descriptor[0..descriptor_len],
    ) catch return false;
    const payload_len = bridge_protocol.requestStartEncodedSize(request) catch return false;
    const payload = std.heap.c_allocator.alloc(u8, payload_len) catch return false;
    defer std.heap.c_allocator.free(payload);

    const encoded = bridge_protocol.encodeRequestStart(request, payload) catch return false;
    const event_queue = @import("event_queue.zig");
    const queue: *event_queue.Queue = @ptrCast(@alignCast(handle));
    queue.push(request_id, encoded) catch return false;
    return true;
}

export fn server_native_zig_queue_length(handle: *anyopaque) usize {
    const event_queue = @import("event_queue.zig");
    const queue: *event_queue.Queue = @ptrCast(@alignCast(handle));
    return queue.count();
}

export fn server_native_zig_queue_post_next(
    handle: *anyopaque,
    port_id: c.Dart_Port_DL,
) bool {
    const event_queue = @import("event_queue.zig");
    const queue: *event_queue.Queue = @ptrCast(@alignCast(handle));
    const event = queue.pop() orelse return false;
    defer queue.release(event);

    var request_id: c.Dart_CObject = undefined;
    request_id.type = c.Dart_CObject_kInt64;
    request_id.value.as_int64 = event.request_id;

    var payload: c.Dart_CObject = undefined;
    payload.type = c.Dart_CObject_kTypedData;
    payload.value.as_typed_data.type = c.Dart_TypedData_kUint8;
    payload.value.as_typed_data.length = @intCast(event.payload.len);
    payload.value.as_typed_data.values = @ptrCast(event.payload.ptr);

    var values = [_][*c]c.Dart_CObject{ &request_id, &payload };
    var message: c.Dart_CObject = undefined;
    message.type = c.Dart_CObject_kArray;
    message.value.as_array.length = values.len;
    message.value.as_array.values = @ptrCast(&values);

    const post = c.Dart_PostCObject_DL orelse return false;
    return post(port_id, &message);
}

test "reports the active Zig transport ABI version" {
    try std.testing.expectEqual(@as(c_int, 1), server_native_zig_transport_version());
}

test "loads internal Zig modules" {
    _ = @import("protocol_test.zig");
    const bridge_protocol = @import("bridge_protocol.zig");
    const event_queue = @import("event_queue.zig");
    abi.validate();
    std.testing.refAllDecls(abi);
    std.testing.refAllDecls(bridge_protocol);
    std.testing.refAllDecls(event_queue);
}

test "FFI nullable lifecycle and response arguments fail without touching outputs" {
    var port: u16 = 1234;
    try std.testing.expect(server_native_zig_start_proxy_server(null, &port) == null);
    try std.testing.expectEqual(@as(u16, 1234), port);
    var config = std.mem.zeroes(abi.ServerNativeProxyConfig);
    try std.testing.expect(server_native_zig_start_proxy_server(&config, null) == null);
    server_native_zig_begin_shutdown(null);
    try std.testing.expect(server_native_zig_shutdown_done(null));
    server_native_zig_stop_proxy_server(null);
    server_native_zig_set_event_port(null, 1);
    server_native_zig_consume_request(null, 1, 100);
    try std.testing.expectEqual(@as(u8, 0), server_native_zig_try_push_response(null, 1, "x", 1));
    try std.testing.expectEqual(@as(u8, 0), server_native_zig_complete_direct_request(null, 1, null, 0));
    try std.testing.expectEqual(@as(u8, 0), server_native_zig_poll_direct_request_frame(null, 0, null, null, null));
    server_native_zig_free_direct_request_payload(null, 0);
    server_native_zig_queue_destroy(null);
}

test "FFI queue rejects invalid capacity and malformed descriptors without queuing" {
    try std.testing.expect(server_native_zig_queue_create(0) == null);
    try std.testing.expect(server_native_zig_queue_create(257) == null);
    const handle = server_native_zig_queue_create(1) orelse return error.OutOfMemory;
    defer server_native_zig_queue_destroy(handle);
    const malformed = [_]u8{255} ** 28;
    try std.testing.expect(!server_native_zig_queue_push_request_start(handle, 1, &malformed, 27));
    try std.testing.expect(!server_native_zig_queue_push_request_start(handle, 1, &malformed, malformed.len));
    try std.testing.expectEqual(@as(usize, 0), server_native_zig_queue_length(handle));
    try std.testing.expect(server_native_zig_queue_push(handle, 1, "x", 1));
    try std.testing.expect(!server_native_zig_queue_push(handle, 2, "y", 1));
    try std.testing.expectEqual(@as(usize, 1), server_native_zig_queue_length(handle));
}

test "FFI queue posts owned binary messages and preserves signed request IDs" {
    const Post = struct {
        var calls: usize = 0;
        var valid = false;
        fn send(port: c.Dart_Port_DL, message: [*c]c.Dart_CObject) callconv(.c) bool {
            calls += 1;
            if (port != 77 or message.*.type != c.Dart_CObject_kArray or message.*.value.as_array.length != 2) return false;
            const values = message.*.value.as_array.values;
            const id = values[0].*;
            const data = values[1].*;
            valid = id.type == c.Dart_CObject_kInt64 and id.value.as_int64 == -42 and
                data.type == c.Dart_CObject_kTypedData and data.value.as_typed_data.type == c.Dart_TypedData_kUint8 and
                data.value.as_typed_data.length == 3 and std.mem.eql(u8, data.value.as_typed_data.values[0..3], &.{ 0, 255, 17 });
            return valid;
        }
    };
    Post.calls = 0;
    Post.valid = false;
    const saved = c.Dart_PostCObject_DL;
    c.Dart_PostCObject_DL = Post.send;
    defer c.Dart_PostCObject_DL = saved;
    const handle = server_native_zig_queue_create(2) orelse return error.OutOfMemory;
    defer server_native_zig_queue_destroy(handle);
    var payload = [_]u8{ 0, 255, 17 };
    try std.testing.expect(server_native_zig_queue_push(handle, -42, &payload, payload.len));
    @memset(&payload, 0);
    try std.testing.expect(server_native_zig_queue_post_next(handle, 77));
    try std.testing.expect(Post.valid);
    try std.testing.expect(!server_native_zig_queue_post_next(handle, 77));
    try std.testing.expectEqual(@as(usize, 1), Post.calls);
    try std.testing.expectEqual(@as(usize, 0), server_native_zig_queue_length(handle));
}

test "FFI direct polling transfers payload ownership and leaves empty outputs untouched" {
    var config = std.mem.zeroes(abi.ServerNativeProxyConfig);
    config.host = "127.0.0.1";
    var port: u16 = 0;
    const handle = server_native_zig_start_proxy_server(&config, &port) orelse return error.StartFailed;
    defer server_native_zig_stop_proxy_server(handle);
    const server = proxy.fromHandle(handle);
    const id: u64 = std.math.maxInt(u64);
    try server.queue.push(@bitCast(id), "payload");
    try std.testing.expectEqual(@as(u8, 0), server_native_zig_poll_direct_request_frame(handle, 0, null, null, null));
    try std.testing.expectEqual(@as(usize, 1), server.queue.count());
    var out_id: u64 = 0;
    var payload: ?[*]u8 = null;
    var length: u64 = 0;
    try std.testing.expectEqual(@as(u8, 1), server_native_zig_poll_direct_request_frame(handle, 0, &out_id, &payload, &length));
    defer server_native_zig_free_direct_request_payload(payload, length);
    try std.testing.expectEqual(id, out_id);
    try std.testing.expectEqualStrings("payload", payload.?[0..@intCast(length)]);
    const original = payload;
    try std.testing.expectEqual(@as(u8, 0), server_native_zig_poll_direct_request_frame(handle, 0, &out_id, &payload, &length));
    try std.testing.expectEqual(original, payload);
    try std.testing.expectEqual(id, out_id);
    try std.testing.expectEqual(@as(u64, 7), length);
    try std.testing.expect(server_native_zig_shutdown_done(handle));
}
