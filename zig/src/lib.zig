const std = @import("std");

pub const bridge_protocol = @import("bridge_protocol.zig");

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

test "reports the active Zig transport ABI version" {
    try std.testing.expectEqual(@as(c_int, 1), server_native_transport_version());
}

test "loads the bridge protocol implementation" {
    std.testing.refAllDecls(bridge_protocol);
}
