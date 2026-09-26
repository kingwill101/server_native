//! Native worker locks park under contention instead of consuming Dart's CPU.
const std = @import("std");

pub const Mutex = struct {
    native: std.c.pthread_mutex_t = .{},

    pub fn lock(self: *Mutex) void {
        const result = std.c.pthread_mutex_lock(&self.native);
        std.debug.assert(result == .SUCCESS);
    }

    pub fn unlock(self: *Mutex) void {
        const result = std.c.pthread_mutex_unlock(&self.native);
        std.debug.assert(result == .SUCCESS);
    }

    pub fn deinit(self: *Mutex) void {
        const result = std.c.pthread_mutex_destroy(&self.native);
        std.debug.assert(result == .SUCCESS);
    }
};

test "mutex protects updates from contending native workers" {
    const Shared = struct {
        mutex: Mutex = .{},
        value: usize = 0,
        fn run(self: *@This()) void {
            for (0..10000) |_| {
                self.mutex.lock();
                self.value += 1;
                self.mutex.unlock();
            }
        }
    };
    var shared: Shared = .{};
    defer shared.mutex.deinit();
    var threads: [8]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Shared.run, .{&shared});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    try std.testing.expectEqual(@as(usize, 80000), shared.value);
}
