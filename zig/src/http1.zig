const builtin = @import("builtin");

pub const posix = if (builtin.os.tag == .windows) struct {
    pub const Fd = usize;
    pub const Listener = struct {};
    pub const Connection = struct {};
    pub fn listen(_: anytype, _: []const u8, _: u16, _: u32, _: bool) error{Unsupported}!Listener {
        return error.Unsupported;
    }
} else @import("http1_posix.zig");
