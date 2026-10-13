const std = @import("std");
const image = @import("resize.zig");

pub const Key = [32]u8;

/// Hash explicit, normalized fields, never Options padding or raw query spelling.
pub fn keyFor(url: []const u8, options: image.Options) Key {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(url);
    var fields: [11]u8 = undefined;
    std.mem.writeInt(u32, fields[0..4], options.width, .little);
    std.mem.writeInt(u32, fields[4..8], options.height, .little);
    fields[8] = @intFromEnum(options.fit);
    fields[9] = @intFromEnum(options.format);
    fields[10] = options.quality;
    hash.update(&fields);
    return hash.finalResult();
}

/// Encoded buffers remain owned here until both their cache membership and all
/// response leases end. Removed-but-pinned entries remain charged to the limit.
/// The bucket allocation and every entry's metadata are also charged. The bound
/// describes requested allocation sizes, not allocator/libc bookkeeping.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    limit: usize,
    ttl_ns: i96,
    buckets: []?*Entry,
    used: usize,
    mutex: std.Io.Mutex = .init,
    head: ?*Entry = null,
    tail: ?*Entry = null,

    const Entry = struct {
        key: Key,
        encoded: image.Encoded,
        inserted: i96,
        pins: usize,
        resident: bool,
        previous: ?*Entry = null,
        next: ?*Entry = null,
        hash_next: ?*Entry = null,
    };

    pub const Lease = struct {
        cache: *Cache,
        entry: *Entry,

        pub fn bytes(self: Lease) []const u8 {
            return self.entry.encoded.bytes;
        }

        pub fn deinit(self: *Lease) void {
            const cache = self.cache;
            cache.mutex.lockUncancelable(cache.io);
            defer cache.mutex.unlock(cache.io);
            std.debug.assert(self.entry.pins > 0);
            self.entry.pins -= 1;
            if (!self.entry.resident and self.entry.pins == 0) cache.destroy(self.entry);
            self.* = undefined;
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, limit: usize, ttl_seconds: usize) !Cache {
        // A power-of-two bucket table, bounded to 32 KiB on 64-bit systems.
        // Tiny/disabled caches allocate nothing and simply bypass insertions.
        var count: usize = 0;
        if (limit >= @sizeOf(?*Entry) + @sizeOf(Entry) + 1) {
            count = 1;
            const target = @min(limit / (@sizeOf(Entry) * 4), 4096);
            while (count < target) count *= 2;
        }
        const buckets = try allocator.alloc(?*Entry, count);
        @memset(buckets, null);
        return .{
            .allocator = allocator,
            .io = io,
            .limit = limit,
            .ttl_ns = @as(i96, @intCast(ttl_seconds)) * std.time.ns_per_s,
            .buckets = buckets,
            .used = buckets.len * @sizeOf(?*Entry),
        };
    }

    /// All jobs and leases must be joined/released before deinit.
    pub fn deinit(self: *Cache) void {
        while (self.tail) |entry| self.remove(entry);
        std.debug.assert(self.used == self.buckets.len * @sizeOf(?*Entry));
        self.allocator.free(self.buckets);
        self.* = undefined;
    }

    pub fn get(self: *Cache, key: Key, now: i96) ?Lease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.find(key) orelse return null;
        if (self.expired(entry, now)) {
            self.remove(entry);
            return null;
        }
        self.unlink(entry);
        self.linkHead(entry);
        entry.pins += 1;
        return .{ .cache = self, .entry = entry };
    }

    /// Success transfers Encoded ownership and returns the first response lease.
    /// Failure leaves Encoded untouched; the caller serves it with its transient
    /// budget. Concurrent duplicate misses deliberately do not single-flight.
    pub fn insert(self: *Cache, key: Key, encoded: *image.Encoded, now: i96) ?Lease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.buckets.len == 0) return null;
        const base = self.buckets.len * @sizeOf(?*Entry);
        if (encoded.bytes.len > self.limit - base or
            @sizeOf(Entry) > self.limit - base - encoded.bytes.len) return null;
        if (self.find(key)) |existing| {
            if (self.expired(existing, now)) self.remove(existing) else return null;
        }
        const charge = @sizeOf(Entry) + encoded.bytes.len;
        while (charge > self.limit - self.used) {
            self.remove(self.tail orelse return null);
        }
        const entry = self.allocator.create(Entry) catch return null;
        entry.* = .{
            .key = key,
            .encoded = encoded.*,
            .inserted = now,
            .pins = 1,
            .resident = true,
            .hash_next = self.buckets[self.bucket(key)],
        };
        self.buckets[self.bucket(key)] = entry;
        self.linkHead(entry);
        self.used += charge;
        encoded.* = undefined;
        return .{ .cache = self, .entry = entry };
    }

    pub fn cleanup(self: *Cache, now: i96) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var current = self.tail;
        while (current) |entry| {
            current = entry.previous;
            if (self.expired(entry, now)) self.remove(entry);
        }
    }

    fn expired(self: *Cache, entry: *Entry, now: i96) bool {
        return now - entry.inserted >= self.ttl_ns;
    }

    fn bucket(self: *Cache, key: Key) usize {
        return @as(usize, @truncate(std.mem.readInt(u64, key[0..8], .little))) & (self.buckets.len - 1);
    }

    fn find(self: *Cache, key: Key) ?*Entry {
        if (self.buckets.len == 0) return null;
        var current = self.buckets[self.bucket(key)];
        while (current) |entry| : (current = entry.hash_next) {
            if (std.mem.eql(u8, &entry.key, &key)) return entry;
        }
        return null;
    }

    fn linkHead(self: *Cache, entry: *Entry) void {
        entry.previous = null;
        entry.next = self.head;
        if (self.head) |head| head.previous = entry else self.tail = entry;
        self.head = entry;
    }

    fn unlink(self: *Cache, entry: *Entry) void {
        if (entry.previous) |previous| previous.next = entry.next else self.head = entry.next;
        if (entry.next) |next| next.previous = entry.previous else self.tail = entry.previous;
    }

    fn remove(self: *Cache, entry: *Entry) void {
        var link = &self.buckets[self.bucket(entry.key)];
        while (link.* != entry) link = &link.*.?.hash_next;
        link.* = entry.hash_next;
        self.unlink(entry);
        entry.resident = false;
        if (entry.pins == 0) self.destroy(entry);
    }

    fn destroy(self: *Cache, entry: *Entry) void {
        self.used -= @sizeOf(Entry) + entry.encoded.bytes.len;
        entry.encoded.deinit();
        self.allocator.destroy(entry);
    }
};

extern fn g_malloc(size: usize) ?*anyopaque;

fn testEncoded(size: usize, value: u8) !image.Encoded {
    const pointer: [*]u8 = @ptrCast(g_malloc(size) orelse return error.OutOfMemory);
    @memset(pointer[0..size], value);
    return .{ .bytes = pointer[0..size] };
}

fn testInsert(cache: *Cache, key: Key, size: usize, value: u8, now: i96) !Cache.Lease {
    var encoded = try testEncoded(size, value);
    return cache.insert(key, &encoded, now) orelse {
        encoded.deinit();
        return error.UnexpectedBypass;
    };
}

test "LRU hits promote and least-recent entry is evicted" {
    const size = 128;
    // One bucket and space for precisely two entries.
    var cache = try Cache.init(std.testing.allocator, std.testing.io, @sizeOf(?*Cache.Entry) + 2 * (@sizeOf(Cache.Entry) + size), 10);
    defer cache.deinit();
    const a = keyFor("a", .{});
    const b = keyFor("b", .{});
    const c = keyFor("c", .{});
    var first = try testInsert(&cache, a, size, 1, 0);
    first.deinit();
    var second = try testInsert(&cache, b, size, 2, 0);
    second.deinit();
    var hit = cache.get(a, 1).?;
    hit.deinit();
    var third = try testInsert(&cache, c, size, 3, 2);
    third.deinit();
    try std.testing.expect(cache.get(b, 3) == null);
    var retained = cache.get(a, 3).?;
    defer retained.deinit();
    try std.testing.expectEqual(@as(u8, 1), retained.bytes()[0]);
}

test "absolute expiry boundary and cleaner retain active leases" {
    var cache = try Cache.init(std.testing.allocator, std.testing.io, 4096, 1);
    defer cache.deinit();
    const key = keyFor("expiry", .{});
    var lease = try testInsert(&cache, key, 16, 7, 123);
    const charged = cache.used;
    var hit = cache.get(key, 123 + std.time.ns_per_s - 1).?;
    hit.deinit();
    cache.cleanup(123 + std.time.ns_per_s);
    try std.testing.expect(cache.get(key, 123 + std.time.ns_per_s) == null);
    try std.testing.expectEqual(charged, cache.used);
    try std.testing.expectEqual(@as(u8, 7), lease.bytes()[0]);
    lease.deinit();
    try std.testing.expectEqual(cache.buckets.len * @sizeOf(?*Cache.Entry), cache.used);
    var again = try testInsert(&cache, key, 16, 8, 123);
    again.deinit();
    try std.testing.expect(cache.get(key, 123 + std.time.ns_per_s) == null);
}

test "pinned eviction keeps hard capacity and buffer until release" {
    const size = 128;
    const limit = @sizeOf(?*Cache.Entry) + @sizeOf(Cache.Entry) + size;
    var cache = try Cache.init(std.testing.allocator, std.testing.io, limit, 10);
    defer cache.deinit();
    const a = keyFor("pinned", .{});
    const b = keyFor("replacement", .{});
    var pinned = try testInsert(&cache, a, size, 9, 0);
    var encoded = try testEncoded(size, 10);
    defer encoded.deinit();
    try std.testing.expect(cache.insert(b, &encoded, 1) == null);
    try std.testing.expect(cache.get(a, 1) == null);
    try std.testing.expectEqual(limit, cache.used);
    try std.testing.expectEqual(@as(u8, 9), pinned.bytes()[0]);
    pinned.deinit();
    var next = try testInsert(&cache, b, size, 11, 2);
    defer next.deinit();
    try std.testing.expect(cache.used <= limit);
}

test "oversized disabled and failed allocations leave caller ownership" {
    var cache = try Cache.init(std.testing.allocator, std.testing.io, 512, 10);
    defer cache.deinit();
    var large = try testEncoded(512, 12);
    defer large.deinit();
    try std.testing.expect(cache.insert(keyFor("large", .{}), &large, 0) == null);
    try std.testing.expectEqual(@as(u8, 12), large.bytes[0]);
    var disabled = try Cache.init(std.testing.allocator, std.testing.io, 0, 10);
    defer disabled.deinit();
    try std.testing.expect(disabled.insert(keyFor("disabled", .{}), &large, 0) == null);
    try std.testing.expectEqual(@as(usize, 0), disabled.used);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var failed = try Cache.init(failing.allocator(), std.testing.io, 512, 10);
    defer failed.deinit();
    var small = try testEncoded(1, 13);
    defer small.deinit();
    try std.testing.expect(failed.insert(keyFor("allocation", .{}), &small, 0) == null);
    try std.testing.expectEqual(@as(u8, 13), small.bytes[0]);
}

test "key includes exact URL and every normalized option" {
    const base = keyFor("https://example.com/a", .{});
    const variants = [_]image.Options{
        .{ .width = 301 },    .{ .height = 301 }, .{ .fit = .contain },
        .{ .format = .webp }, .{ .quality = 81 },
    };
    for (variants) |options| try std.testing.expect(!std.mem.eql(u8, &base, &keyFor("https://example.com/a", options)));
    try std.testing.expect(!std.mem.eql(u8, &base, &keyFor("https://example.com/b", .{})));
    try std.testing.expectEqual(base, keyFor("https://example.com/a", .{ .width = 300, .height = 300, .fit = .cover, .format = .jpeg, .quality = 80 }));
}
