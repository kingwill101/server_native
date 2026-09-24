//! A single-owner allocator with a hard limit, composable with a parent budget.
//! Also supplies C allocation callbacks for ngtcp2/nghttp3's per-connection heaps.
const std = @import("std");
const Alignment = std.mem.Alignment;
pub const Budget = struct {
    parent: std.mem.Allocator,
    limit: usize,
    used: usize = 0,
    peak: usize = 0,

    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn from(context: *anyopaque) *Budget {
        return @ptrCast(@alignCast(context));
    }
    fn grow(self: *Budget, count: usize) bool {
        if (count > self.limit - self.used) return false;
        self.used += count;
        self.peak = @max(self.peak, self.used);
        return true;
    }
    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const self = from(context);
        if (!self.grow(len)) return null;
        return self.parent.rawAlloc(len, alignment, ret) orelse {
            self.used -= len;
            return null;
        };
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ret: usize) bool {
        const self = from(context);
        const growth = len -| memory.len;
        if (!self.grow(growth)) return false;
        if (!self.parent.rawResize(memory, alignment, len, ret)) {
            self.used -= growth;
            return false;
        }
        self.used -= memory.len -| len;
        return true;
    }
    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ret: usize) ?[*]u8 {
        const self = from(context);
        const growth = len -| memory.len;
        if (!self.grow(growth)) return null;
        const result = self.parent.rawRemap(memory, alignment, len, ret) orelse {
            self.used -= growth;
            return null;
        };
        self.used -= memory.len -| len;
        return result;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, ret: usize) void {
        const self = from(context);
        self.parent.rawFree(memory, alignment, ret);
        self.used -= memory.len;
    }

    const Header = struct { length: usize align(16) };
    pub fn cMalloc(length: usize, context: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self = from(context.?);
        const total = std.math.add(usize, length, @sizeOf(Header)) catch return null;
        const memory = self.allocator().alignedAlloc(u8, .@"16", total) catch return null;
        const header: *Header = @ptrCast(memory.ptr);
        header.* = .{ .length = total };
        return @ptrCast(memory.ptr + @sizeOf(Header));
    }
    pub fn cFree(pointer: ?*anyopaque, context: ?*anyopaque) callconv(.c) void {
        const ptr = pointer orelse return;
        const bytes: [*]u8 = @ptrCast(ptr);
        const header: *Header = @ptrCast(@alignCast(bytes - @sizeOf(Header)));
        const memory: [*]align(16) u8 = @ptrCast(header);
        from(context.?).allocator().free(memory[0..header.length]);
    }
    pub fn cCalloc(count: usize, size: usize, context: ?*anyopaque) callconv(.c) ?*anyopaque {
        const length = std.math.mul(usize, count, size) catch return null;
        const ptr = cMalloc(length, context) orelse return null;
        @memset(@as([*]u8, @ptrCast(ptr))[0..length], 0);
        return ptr;
    }
    pub fn cRealloc(pointer: ?*anyopaque, length: usize, context: ?*anyopaque) callconv(.c) ?*anyopaque {
        const old = pointer orelse return cMalloc(length, context);
        if (length == 0) {
            cFree(old, context);
            return null;
        }
        const bytes: [*]u8 = @ptrCast(old);
        const header: *Header = @ptrCast(@alignCast(bytes - @sizeOf(Header)));
        const new = cMalloc(length, context) orelse return null;
        const count = @min(length, header.length - @sizeOf(Header));
        @memcpy(@as([*]u8, @ptrCast(new))[0..count], bytes[0..count]);
        cFree(old, context);
        return new;
    }
};

test "hierarchical budgets bound siblings and restore capacity after free" {
    var root: Budget = .{ .parent = std.testing.allocator, .limit = 100 };
    var one: Budget = .{ .parent = root.allocator(), .limit = 80 };
    var two: Budget = .{ .parent = root.allocator(), .limit = 80 };
    const a = try one.allocator().alloc(u8, 70);
    try std.testing.expectError(error.OutOfMemory, one.allocator().alloc(u8, 11));
    try std.testing.expectError(error.OutOfMemory, two.allocator().alloc(u8, 31));
    try std.testing.expectEqual(@as(usize, 0), two.used);
    const b = try two.allocator().alloc(u8, 30);
    try std.testing.expectEqual(@as(usize, 100), root.used);
    one.allocator().free(a);
    two.allocator().free(b);
    try std.testing.expectEqual(@as(usize, 0), root.used);
}

test "budgeted C realloc failure preserves data and metadata is charged" {
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 128 };
    const old = Budget.cCalloc(4, 8, &budget).?;
    const bytes: [*]u8 = @ptrCast(old);
    try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0))), bytes[0..32]);
    bytes[0] = 99;
    try std.testing.expect(Budget.cRealloc(old, 128, &budget) == null);
    try std.testing.expectEqual(@as(u8, 99), bytes[0]);
    const new = Budget.cRealloc(old, 40, &budget).?;
    try std.testing.expectEqual(@as(u8, 99), @as([*]u8, @ptrCast(new))[0]);
    Budget.cFree(new, &budget);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    try std.testing.expect(Budget.cCalloc(std.math.maxInt(usize), 2, &budget) == null);
    try std.testing.expect(Budget.cMalloc(std.math.maxInt(usize), &budget) == null);
    Budget.cFree(null, &budget);
}

test "budget resize and remap charge exact growth and restore shrink capacity" {
    var storage: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var budget: Budget = .{ .parent = fixed.allocator(), .limit = 64 };
    const a = budget.allocator();
    var bytes = try a.alloc(u8, 16);
    @memset(bytes, 42);
    try std.testing.expect(a.resize(bytes, 48));
    bytes = bytes.ptr[0..48];
    try std.testing.expectEqual(@as(usize, 48), budget.used);
    try std.testing.expect(!a.resize(bytes, 65));
    try std.testing.expectEqual(@as(usize, 48), budget.used);
    bytes = a.remap(bytes, 24) orelse return error.RemapFailed;
    try std.testing.expectEqual(@as(usize, 24), budget.used);
    bytes = a.remap(bytes, 64) orelse return error.RemapFailed;
    try std.testing.expectEqual(@as(usize, 64), budget.used);
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(42))), bytes[0..16]);
    try std.testing.expect(a.remap(bytes, 65) == null);
    a.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    try std.testing.expectEqual(@as(usize, 64), budget.peak);
}

test "budget parent exhaustion rolls back allocation resize and remap accounting" {
    var storage: [32]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var budget: Budget = .{ .parent = fixed.allocator(), .limit = 256 };
    const a = budget.allocator();
    const bytes = try a.alloc(u8, 24);
    defer a.free(bytes);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 9));
    try std.testing.expect(!a.resize(bytes, 33));
    try std.testing.expect(a.remap(bytes, 33) == null);
    try std.testing.expectEqual(@as(usize, 24), budget.used);
}

test "budget C allocation alignment shrink preservation and zero realloc release" {
    var budget: Budget = .{ .parent = std.testing.allocator, .limit = 256 };
    const first = Budget.cRealloc(null, 40, &budget) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(first) % 16);
    @memset(@as([*]u8, @ptrCast(first))[0..40], 0x7b);
    const small = Budget.cRealloc(first, 3, &budget) orelse return error.OutOfMemory;
    try std.testing.expectEqualSlices(u8, &.{ 0x7b, 0x7b, 0x7b }, @as([*]u8, @ptrCast(small))[0..3]);
    try std.testing.expect(Budget.cRealloc(small, 0, &budget) == null);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    const empty = Budget.cCalloc(0, std.math.maxInt(usize), &budget) orelse return error.OutOfMemory;
    Budget.cFree(empty, &budget);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}
