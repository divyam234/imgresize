const std = @import("std");

/// Accounts owned source capacity and encoded responses, not decoder scratch space.
pub const Budget = struct {
    limit: usize,
    used: std.atomic.Value(usize) = .init(0),

    pub fn reserve(self: *Budget, amount: usize) bool {
        var current = self.used.load(.monotonic);
        while (true) {
            if (amount > self.limit - current) return false;
            current = self.used.cmpxchgWeak(current, current + amount, .monotonic, .monotonic) orelse return true;
        }
    }

    pub fn release(self: *Budget, amount: usize) void {
        const previous = self.used.fetchSub(amount, .monotonic);
        std.debug.assert(previous >= amount);
    }
};

test "capacity exhaustion and released capacity remain balanced" {
    var budget: Budget = .{ .limit = 100 };
    try std.testing.expect(budget.reserve(60));
    try std.testing.expect(!budget.reserve(41));
    try std.testing.expect(budget.reserve(40));
    budget.release(60);
    try std.testing.expect(budget.reserve(60));
    budget.release(100);
    try std.testing.expectEqual(@as(usize, 0), budget.used.load(.monotonic));
}
