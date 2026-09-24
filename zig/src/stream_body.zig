//! Stable response storage: QUIC borrows slices until application-data ACKs.
const std = @import("std");
pub const Body = struct {
    const Chunk = struct { bytes: []u8, offered: bool = false, acknowledged: usize = 0 };
    chunks: std.ArrayList(Chunk) = .empty,
    bytes: usize = 0,

    pub fn deinit(self: *Body, allocator: std.mem.Allocator) void {
        for (self.chunks.items) |chunk| allocator.free(chunk.bytes);
        self.chunks.deinit(allocator);
    }

    /// Takes ownership only on success.
    pub fn append(self: *Body, allocator: std.mem.Allocator, bytes: []u8) !void {
        try self.chunks.append(allocator, .{ .bytes = bytes });
        self.bytes += bytes.len;
    }

    pub fn next(self: *Body) ?[]u8 {
        for (self.chunks.items) |*chunk| {
            if (chunk.offered) continue;
            chunk.offered = true;
            return chunk.bytes;
        }
        return null;
    }

    pub fn acknowledge(self: *Body, allocator: std.mem.Allocator, count: usize) !void {
        var remaining = count;
        while (remaining != 0) {
            if (self.chunks.items.len == 0) return error.InvalidAcknowledgement;
            const first = &self.chunks.items[0];
            if (!first.offered) return error.InvalidAcknowledgement;
            const n = @min(remaining, first.bytes.len - first.acknowledged);
            first.acknowledged += n;
            remaining -= n;
            self.bytes -= n;
            if (first.acknowledged == first.bytes.len) {
                allocator.free(first.bytes);
                _ = self.chunks.orderedRemove(0);
            }
        }
    }
};

test "QUIC body retains stable chunks across partial and combined acknowledgements" {
    const a = std.testing.allocator;
    var body: Body = .{};
    defer body.deinit(a);
    try body.append(a, try a.dupe(u8, "first"));
    const first = body.next().?;
    for (0..32) |_| try body.append(a, try a.dupe(u8, "second"));
    try std.testing.expectEqualStrings("first", first);
    try body.acknowledge(a, 2);
    try std.testing.expectEqualStrings("first", first);
    try std.testing.expectEqualStrings("second", body.next().?);
    try body.acknowledge(a, 9);
    try std.testing.expectEqual(@as(usize, 31 * 6), body.bytes);
    for (0..31) |_| _ = body.next().?;
    try std.testing.expect(body.next() == null);
    try body.acknowledge(a, 31 * 6);
    try std.testing.expectEqual(@as(usize, 0), body.bytes);
    try std.testing.expectError(error.InvalidAcknowledgement, body.acknowledge(a, 1));
}

test "QUIC body cancellation frees both offered and pending chunks" {
    const a = std.testing.allocator;
    var body: Body = .{};
    defer body.deinit(a);
    try body.append(a, try a.dupe(u8, "offered"));
    try body.append(a, try a.dupe(u8, "pending"));
    _ = body.next();
    try body.acknowledge(a, 3);
    try std.testing.expectEqual(@as(usize, 11), body.bytes);
}
