const std = @import("std");

pub const max_queue_slots: usize = 256;
pub const max_queued_bytes: usize = 64 * 1024 * 1024;

pub const Error = error{
    InvalidCapacity,
    OutOfMemory,
    PayloadTooLarge,
    QueueFull,
};

pub const Event = struct {
    request_id: i64,
    payload: []u8,
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    slots: []?Event,
    head: usize = 0,
    len: usize = 0,
    queued_bytes: usize = 0,
    byte_limit: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Error!Queue {
        return initWithByteLimit(allocator, capacity, max_queued_bytes);
    }

    fn initWithByteLimit(
        allocator: std.mem.Allocator,
        capacity: usize,
        byte_limit: usize,
    ) Error!Queue {
        if (capacity == 0 or capacity > max_queue_slots or byte_limit == 0) {
            return error.InvalidCapacity;
        }

        const slots = allocator.alloc(?Event, capacity) catch {
            return error.OutOfMemory;
        };
        for (slots) |*slot| slot.* = null;

        return .{
            .allocator = allocator,
            .slots = slots,
            .byte_limit = byte_limit,
        };
    }

    pub fn deinit(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.slots) |slot| {
            if (slot) |event| self.allocator.free(event.payload);
        }
        self.allocator.free(self.slots);
        self.slots = self.slots[0..0];
        self.head = 0;
        self.len = 0;
        self.queued_bytes = 0;
    }

    pub fn capacity(self: *const Queue) usize {
        return self.slots.len;
    }

    pub fn count(self: *Queue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.len;
    }

    pub fn queuedBytes(self: *Queue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queued_bytes;
    }

    pub fn push(self: *Queue, request_id: i64, payload: []const u8) Error!void {
        if (payload.len > self.byte_limit) return error.PayloadTooLarge;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len == self.slots.len or
            payload.len > self.byte_limit - self.queued_bytes)
        {
            return error.QueueFull;
        }

        const owned = self.allocator.dupe(u8, payload) catch {
            return error.OutOfMemory;
        };
        const tail = (self.head + self.len) % self.slots.len;
        self.slots[tail] = .{
            .request_id = request_id,
            .payload = owned,
        };
        self.len += 1;
        self.queued_bytes += owned.len;
    }

    pub fn pop(self: *Queue) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len == 0) return null;

        const event = self.slots[self.head].?;
        self.slots[self.head] = null;
        self.head = (self.head + 1) % self.slots.len;
        self.len -= 1;
        self.queued_bytes -= event.payload.len;
        return event;
    }

    pub fn release(self: *Queue, event: Event) void {
        self.allocator.free(event.payload);
    }
};

test "queue preserves FIFO order and owns payload bytes" {
    var queue = try Queue.init(std.testing.allocator, 2);
    defer queue.deinit();

    var source = [_]u8{ 1, 2, 3 };
    try queue.push(41, &source);
    source[0] = 9;
    try queue.push(42, "next");

    const first = queue.pop().?;
    defer queue.release(first);
    try std.testing.expectEqual(@as(i64, 41), first.request_id);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, first.payload);

    const second = queue.pop().?;
    defer queue.release(second);
    try std.testing.expectEqual(@as(i64, 42), second.request_id);
    try std.testing.expectEqualStrings("next", second.payload);
    try std.testing.expect(queue.pop() == null);
}

test "queue applies slot and byte backpressure" {
    var queue = try Queue.initWithByteLimit(std.testing.allocator, 2, 5);
    defer queue.deinit();

    try queue.push(1, "abc");
    try std.testing.expectError(error.QueueFull, queue.push(2, "def"));
    try queue.push(2, "de");
    try std.testing.expectError(error.QueueFull, queue.push(3, ""));

    const first = queue.pop().?;
    queue.release(first);
    try queue.push(3, "xyz");
    try std.testing.expectEqual(@as(usize, 2), queue.count());
    try std.testing.expectEqual(@as(usize, 5), queue.queuedBytes());
}

test "queue validates capacity and payload limits" {
    try std.testing.expectError(
        error.InvalidCapacity,
        Queue.init(std.testing.allocator, 0),
    );
    try std.testing.expectError(
        error.InvalidCapacity,
        Queue.init(std.testing.allocator, max_queue_slots + 1),
    );

    var queue = try Queue.initWithByteLimit(std.testing.allocator, 1, 2);
    defer queue.deinit();
    try std.testing.expectError(error.PayloadTooLarge, queue.push(1, "abc"));
}
