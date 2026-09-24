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

const SpinMutex = struct {
    state: std.atomic.Value(u8) = .init(0),

    fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(
            0,
            1,
            .acquire,
            .monotonic,
        ) != null) {}
    }

    fn unlock(self: *SpinMutex) void {
        self.state.store(0, .release);
    }
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    mutex: SpinMutex = .{},
    slots: []?Event,
    head: usize = 0,
    len: usize = 0,
    queued_bytes: usize = 0,
    byte_limit: usize,

    pub fn init(allocator: std.mem.Allocator, slot_capacity: usize) Error!Queue {
        return initWithByteLimit(allocator, slot_capacity, max_queued_bytes);
    }

    fn initWithByteLimit(
        allocator: std.mem.Allocator,
        slot_capacity: usize,
        byte_limit: usize,
    ) Error!Queue {
        if (slot_capacity == 0 or slot_capacity > max_queue_slots or byte_limit == 0) {
            return error.InvalidCapacity;
        }

        const slots = allocator.alloc(?Event, slot_capacity) catch {
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

        const owned = self.allocator.dupe(u8, payload) catch {
            return error.OutOfMemory;
        };
        errdefer self.allocator.free(owned);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.len == self.slots.len or
            payload.len > self.byte_limit - self.queued_bytes)
        {
            return error.QueueFull;
        }

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

test "queue wraps its ring repeatedly without reordering" {
    var queue = try Queue.init(std.testing.allocator, 3);
    defer queue.deinit();
    for (0..200) |round| {
        for (0..3) |i| try queue.push(@intCast(round * 3 + i), "payload");
        try std.testing.expectError(error.QueueFull, queue.push(-1, "rejected"));
        for (0..3) |i| {
            const event = queue.pop().?;
            defer queue.release(event);
            try std.testing.expectEqual(@as(i64, @intCast(round * 3 + i)), event.request_id);
            try std.testing.expectEqualStrings("payload", event.payload);
        }
        try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());
    }
}

test "queue zero length payloads occupy slots but no byte budget" {
    var queue = try Queue.initWithByteLimit(std.testing.allocator, 2, 1);
    defer queue.deinit();
    try queue.push(std.math.minInt(i64), "");
    try queue.push(std.math.maxInt(i64), "");
    try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());
    try std.testing.expectError(error.QueueFull, queue.push(0, ""));
    const first = queue.pop().?;
    defer queue.release(first);
    try std.testing.expectEqual(std.math.minInt(i64), first.request_id);
    try queue.push(0, "x");
    try std.testing.expectEqual(@as(usize, 1), queue.queuedBytes());
}

fn allocationQueue(allocator: std.mem.Allocator) !void {
    var queue = try Queue.init(allocator, 3);
    defer queue.deinit();
    try queue.push(1, "one");
    try queue.push(2, "two");
    const event = queue.pop().?;
    queue.release(event);
    try queue.push(3, "three");
}

test "queue every allocation failure releases queued payloads" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationQueue, .{});
}

test "queue rejected insertion preserves existing payload and counters" {
    var queue = try Queue.initWithByteLimit(std.testing.allocator, 4, 4);
    defer queue.deinit();
    try queue.push(7, "abcd");
    try std.testing.expectError(error.PayloadTooLarge, queue.push(8, "abcde"));
    try std.testing.expectError(error.QueueFull, queue.push(8, "x"));
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try std.testing.expectEqual(@as(usize, 4), queue.queuedBytes());
    const event = queue.pop().?;
    defer queue.release(event);
    try std.testing.expectEqualStrings("abcd", event.payload);
    try std.testing.expectEqual(@as(i64, 7), event.request_id);
}

const ThreadedQueueProbe = struct {
    queue: *Queue,
    finished: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    fn produce(self: *ThreadedQueueProbe, producer: usize) void {
        defer _ = self.finished.fetchAdd(1, .release);
        for (0..200) |sequence| {
            const id: u32 = @intCast(producer * 200 + sequence);
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, id, .big);
            var pushed = false;
            for (0..1000000) |_| {
                self.queue.push(id, &bytes) catch |err| {
                    if (err == error.QueueFull) {
                        std.Thread.yield() catch {};
                        continue;
                    }
                    self.failed.store(true, .release);
                    return;
                };
                pushed = true;
                break;
            }
            if (!pushed) {
                self.failed.store(true, .release);
                return;
            }
        }
    }
};

test "queue concurrent producers deliver every owned event exactly once" {
    var queue = try Queue.init(std.testing.allocator, 7);
    defer queue.deinit();
    var probe: ThreadedQueueProbe = .{ .queue = &queue };
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |thread| thread.join();
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, ThreadedQueueProbe.produce, .{ &probe, i });
        spawned += 1;
    }
    var seen = [_]bool{false} ** 800;
    var next = [_]usize{0} ** 4;
    var count: usize = 0;
    for (0..10000000) |_| {
        if (queue.pop()) |event| {
            defer queue.release(event);
            const id: usize = @intCast(event.request_id);
            try std.testing.expect(id < seen.len);
            try std.testing.expect(!seen[id]);
            seen[id] = true;
            try std.testing.expectEqual(@as(u32, @intCast(id)), std.mem.readInt(u32, event.payload[0..4], .big));
            try std.testing.expectEqual(next[id / 200], id % 200);
            next[id / 200] += 1;
            count += 1;
        } else if (probe.finished.load(.acquire) == 4) break else std.Thread.yield() catch {};
    }
    try std.testing.expect(!probe.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 800), count);
    try std.testing.expectEqual(@as(usize, 0), queue.count());
    try std.testing.expectEqual(@as(usize, 0), queue.queuedBytes());
}
