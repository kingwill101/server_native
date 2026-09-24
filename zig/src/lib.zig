const std = @import("std");

const c = @cImport({
    @cInclude("dart_api_dl.h");
});

export fn server_native_transport_version() c_int {
    return 1;
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
    const opaque = handle orelse return;
    const event_queue = @import("event_queue.zig");
    const queue: *event_queue.Queue = @ptrCast(@alignCast(opaque));
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
    try std.testing.expectEqual(@as(c_int, 1), server_native_transport_version());
}

test "loads internal Zig modules" {
    const bridge_protocol = @import("bridge_protocol.zig");
    const event_queue = @import("event_queue.zig");
    std.testing.refAllDecls(bridge_protocol);
    std.testing.refAllDecls(event_queue);
}
