const std = @import("std");
const image = @import("resize.zig");
const Io = std.Io;

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

/// One disk tier. Payloads never live in the index. `used` includes reservations
/// and unlinked files whose response leases are still open; metadata is bounded
/// separately. A cache directory must belong to one running service at a time.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    io: Io,
    limit: usize,
    ttl_ns: i96,
    directory: ?Io.Dir = null,
    buckets: []?*Entry,
    used: usize = 0,
    count: usize = 0,
    leases: usize = 0,
    admissions: usize = 0,
    sequence: u64 = 0,
    mutex: Io.Mutex = .init,
    head: ?*Entry = null,
    tail: ?*Entry = null,

    pub const header_size = 32;
    pub const max_entries = 262144;
    const max_leases = 1024;
    const max_admissions = 64;
    const prefix = "imgresize-v1-";
    const suffix = ".cache";
    const name_size = prefix.len + 64 + suffix.len;
    const magic = "IMGRSZ01";

    const Entry = struct {
        key: Key,
        size: usize,
        inserted: i96,
        pins: usize = 0,
        resident: bool = true,
        previous: ?*Entry = null,
        next: ?*Entry = null,
        hash_next: ?*Entry = null,
    };

    pub const Lease = struct {
        cache: *Cache,
        entry: *Entry,
        file: Io.File,

        pub fn size(self: Lease) usize {
            return self.entry.size - header_size;
        }

        pub fn read(self: Lease, buffer: []u8, offset: usize) !usize {
            if (offset >= self.size()) return 0;
            return self.file.readPositional(self.cache.io, &.{buffer[0..@min(buffer.len, self.size() - offset)]}, header_size + @as(u64, @intCast(offset)));
        }

        pub fn deinit(self: *Lease) void {
            const cache = self.cache;
            self.file.close(cache.io);
            cache.mutex.lockUncancelable(cache.io);
            defer cache.mutex.unlock(cache.io);
            self.entry.pins -= 1;
            cache.leases -= 1;
            if (!self.entry.resident and self.entry.pins == 0) cache.destroy(self.entry);
            self.* = undefined;
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: Io, limit: usize, ttl_seconds: usize, path: []const u8) !Cache {
        const buckets = try allocator.alloc(?*Entry, if (limit == 0) 0 else 4096);
        @memset(buckets, null);
        var self: Cache = .{ .allocator = allocator, .io = io, .limit = limit, .ttl_ns = @as(i96, @intCast(ttl_seconds)) * std.time.ns_per_s, .buckets = buckets };
        errdefer self.deinit();
        if (limit == 0) return self; // Disabled means no directory I/O.
        try Io.Dir.cwd().createDirPath(io, path);
        self.directory = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        try self.restore(Io.Clock.Timestamp.now(io, .real).raw.toNanoseconds());
        return self;
    }

    /// All admissions and leases must have ended. Resident files survive restart.
    pub fn deinit(self: *Cache) void {
        std.debug.assert(self.leases == 0 and self.admissions == 0);
        var current = self.head;
        while (current) |entry| {
            current = entry.next;
            self.allocator.destroy(entry);
        }
        if (self.directory) |directory| directory.close(self.io);
        self.allocator.free(self.buckets);
        self.* = undefined;
    }

    pub fn get(self: *Cache, key: Key, now: i96) ?Lease {
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.find(key) orelse return null;
        if (self.expired(entry, now)) {
            _ = self.remove(entry);
            return null;
        }
        if (self.leases == max_leases) return null;
        var name: [name_size]u8 = undefined;
        const file = self.directory.?.openFile(self.io, filename(key, &name), .{ .follow_symlinks = false }) catch return null;
        self.unlink(entry);
        self.linkHead(entry);
        entry.pins += 1;
        self.leases += 1;
        return .{ .cache = self, .entry = entry, .file = file };
    }

    /// Copies directly to disk, never copies into a retained RAM buffer and never
    /// consumes Encoded. Reservations are made before creating a temporary file.
    /// Failed admissions leave the original available for an uncached response.
    pub fn insert(self: *Cache, key: Key, encoded: *image.Encoded, now: i96) Io.Cancelable!bool {
        if (self.directory == null or encoded.bytes.len > self.limit or header_size > self.limit - encoded.bytes.len) return false;
        const charge = header_size + encoded.bytes.len;
        self.mutex.lockUncancelable(self.io);
        if (self.find(key)) |entry| {
            if (!self.expired(entry, now) or !self.remove(entry)) {
                self.mutex.unlock(self.io);
                return false;
            }
        }
        if (self.admissions == max_admissions or !self.makeRoom(charge)) {
            self.mutex.unlock(self.io);
            return false;
        }
        const entry = self.allocator.create(Entry) catch {
            self.mutex.unlock(self.io);
            return false;
        };
        self.used += charge;
        self.count += 1;
        self.admissions += 1;
        self.sequence +%= 1;
        const sequence = self.sequence;
        self.mutex.unlock(self.io);

        var name_buffer: [name_size]u8 = undefined;
        const name = filename(key, &name_buffer);
        var temp_buffer: [name_size + 64]u8 = undefined;
        const temp = std.fmt.bufPrint(&temp_buffer, "{s}.tmp-{x}-{x}", .{ name, @as(u96, @bitCast(now)), sequence }) catch unreachable;
        var committed = false;
        var created = false;
        defer {
            const protection = self.io.swapCancelProtection(.blocked);
            defer _ = self.io.swapCancelProtection(protection);
            // If unlink fails, retain the reservation: never undercount owned bytes.
            const released = if (!committed and created) blk: {
                self.directory.?.deleteFile(self.io, temp) catch break :blk false;
                break :blk true;
            } else !committed;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.admissions -= 1;
            if (!committed) {
                self.allocator.destroy(entry);
                if (released) {
                    self.used -= charge;
                    self.count -= 1;
                }
            }
        }
        const file = self.directory.?.createFile(self.io, temp, .{ .exclusive = true }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return false,
        };
        created = true;
        defer file.close(self.io);
        var header: [header_size]u8 = @splat(0);
        @memcpy(header[0..8], magic);
        std.mem.writeInt(i96, header[8..20], now, .little);
        std.mem.writeInt(u64, header[20..28], @intCast(encoded.bytes.len), .little);
        file.writePositionalAll(self.io, &header, 0) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return false,
        };
        file.writePositionalAll(self.io, encoded.bytes, header_size) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return false,
        };
        // Publication and duplicate detection are short serialized operations.
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.find(key) != null) return false;
        Io.Dir.rename(self.directory.?, temp, self.directory.?, name, self.io) catch return false;
        entry.* = .{ .key = key, .size = charge, .inserted = now };
        self.add(entry);
        committed = true;
        return true;
    }

    pub fn cleanup(self: *Cache, now: i96) void {
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var current = self.tail;
        while (current) |entry| {
            current = entry.previous;
            if (self.expired(entry, now)) _ = self.remove(entry);
        }
    }

    fn restore(self: *Cache, now: i96) !void {
        var iterator = self.directory.?.iterate();
        while (try iterator.next(self.io)) |item| {
            if (item.kind != .file) continue;
            const key = parseName(item.name) orelse continue;
            if (item.name.len != name_size) {
                try self.directory.?.deleteFile(self.io, item.name);
                continue;
            }
            const file = try self.directory.?.openFile(self.io, item.name, .{ .follow_symlinks = false });
            defer file.close(self.io);
            const stat = try file.stat(self.io);
            var header: [header_size]u8 = undefined;
            const length = try file.readPositionalAll(self.io, &header, 0);
            const inserted = if (length == header_size) std.mem.readInt(i96, header[8..20], .little) else 0;
            const payload = if (length == header_size) std.mem.readInt(u64, header[20..28], .little) else 0;
            if (length != header_size or !std.mem.eql(u8, header[0..8], magic) or stat.size < header_size or payload != stat.size - header_size or stat.size > self.limit or self.expiredTime(inserted, now)) {
                try self.directory.?.deleteFile(self.io, item.name);
                continue;
            }
            const charge: usize = @intCast(stat.size);
            if (!self.makeRoom(charge)) return error.CacheCapacity;
            const entry = try self.allocator.create(Entry);
            entry.* = .{ .key = key, .size = charge, .inserted = inserted };
            self.used += charge;
            self.count += 1;
            self.add(entry);
        }
        // Restart order is insertion age (live hits are not persisted).
        const entries = try self.allocator.alloc(*Entry, self.count);
        defer self.allocator.free(entries);
        var current = self.head;
        for (entries) |*slot| {
            slot.* = current.?;
            current = current.?.next;
        }
        std.sort.pdq(*Entry, entries, {}, struct {
            fn lessThan(_: void, left: *Entry, right: *Entry) bool {
                if (left.inserted != right.inserted) return left.inserted < right.inserted;
                return std.mem.order(u8, &left.key, &right.key) == .lt;
            }
        }.lessThan);
        self.head = null;
        self.tail = null;
        for (entries) |entry| self.linkHead(entry);
    }

    fn filename(key: Key, out: *[name_size]u8) []const u8 {
        @memcpy(out[0..prefix.len], prefix);
        const hex = std.fmt.bytesToHex(key, .lower);
        @memcpy(out[prefix.len..][0..64], &hex);
        @memcpy(out[prefix.len + 64 ..], suffix);
        return out;
    }

    fn parseName(name: []const u8) ?Key {
        if (name.len < name_size or !std.mem.startsWith(u8, name, prefix) or !std.mem.eql(u8, name[prefix.len + 64 .. name_size], suffix)) return null;
        if (name.len != name_size) {
            const rest = name[name_size..];
            if (!std.mem.startsWith(u8, rest, ".tmp-")) return null;
            var parts = std.mem.splitScalar(u8, rest[5..], '-');
            _ = std.fmt.parseInt(u96, parts.next() orelse return null, 16) catch return null;
            _ = std.fmt.parseInt(u64, parts.next() orelse return null, 16) catch return null;
            if (parts.next() != null) return null;
        }
        var key: Key = undefined;
        _ = std.fmt.hexToBytes(&key, name[prefix.len..][0..64]) catch return null;
        return key;
    }

    fn expired(self: *Cache, entry: *Entry, now: i96) bool {
        return self.expiredTime(entry.inserted, now);
    }

    fn expiredTime(self: *Cache, inserted: i96, now: i96) bool {
        if (now < inserted) return true;
        const age = std.math.sub(i96, now, inserted) catch return true;
        return age >= self.ttl_ns;
    }

    fn makeRoom(self: *Cache, charge: usize) bool {
        while (charge > self.limit - self.used or self.count >= max_entries) {
            if (!self.remove(self.tail orelse return false)) return false;
        }
        return true;
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

    fn add(self: *Cache, entry: *Entry) void {
        entry.hash_next = self.buckets[self.bucket(entry.key)];
        self.buckets[self.bucket(entry.key)] = entry;
        self.linkHead(entry);
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

    fn remove(self: *Cache, entry: *Entry) bool {
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        var name: [name_size]u8 = undefined;
        self.directory.?.deleteFile(self.io, filename(entry.key, &name)) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return false,
        };
        var link = &self.buckets[self.bucket(entry.key)];
        while (link.* != entry) link = &link.*.?.hash_next;
        link.* = entry.hash_next;
        self.unlink(entry);
        entry.resident = false;
        if (entry.pins == 0) self.destroy(entry);
        return true;
    }

    fn destroy(self: *Cache, entry: *Entry) void {
        self.used -= entry.size;
        self.count -= 1;
        self.allocator.destroy(entry);
    }
};

extern fn g_malloc(size: usize) ?*anyopaque;

fn testEncoded(size: usize, value: u8) !image.Encoded {
    const pointer: [*]u8 = @ptrCast(g_malloc(size) orelse return error.OutOfMemory);
    @memset(pointer[0..size], value);
    return .{ .bytes = pointer[0..size] };
}

fn testNow() i96 {
    return Io.Clock.Timestamp.now(std.testing.io, .real).raw.toNanoseconds();
}

fn testPath(directory: Io.Dir, buffer: []u8) ![]const u8 {
    const length = try directory.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

test "disk LRU hits promote and least-recent entry is evicted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    var cache = try Cache.init(std.testing.allocator, std.testing.io, 2 * (Cache.header_size + 128), 10, try testPath(tmp.dir, &path_buffer));
    defer cache.deinit();
    var encoded = try testEncoded(128, 7);
    defer encoded.deinit();
    const now = testNow();
    const a = keyFor("a", .{});
    const b = keyFor("b", .{});
    const c = keyFor("c", .{});
    try std.testing.expect(try cache.insert(a, &encoded, now));
    try std.testing.expect(try cache.insert(b, &encoded, now));
    var hit = cache.get(a, now).?;
    hit.deinit();
    try std.testing.expect(try cache.insert(c, &encoded, now));
    try std.testing.expect(cache.get(b, now) == null);
    var retained = cache.get(a, now).?;
    defer retained.deinit();
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try retained.read(&buffer, 4));
    try std.testing.expectEqualSlices(u8, &([_]u8{7} ** 8), &buffer);
    try std.testing.expectEqual(@as(usize, 320), cache.used);
}

test "exact expiration unlinks disk file but charges open response lease" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    var cache = try Cache.init(std.testing.allocator, std.testing.io, 4096, 1, try testPath(tmp.dir, &path_buffer));
    defer cache.deinit();
    var encoded = try testEncoded(16, 9);
    defer encoded.deinit();
    const now = testNow();
    const key = keyFor("expiry", .{});
    try std.testing.expect(try cache.insert(key, &encoded, now));
    var pinned = cache.get(key, now).?;
    var before = cache.get(key, now + std.time.ns_per_s - 1).?;
    before.deinit();
    cache.cleanup(now + std.time.ns_per_s);
    try std.testing.expect(cache.get(key, now + std.time.ns_per_s) == null);
    try std.testing.expectEqual(@as(usize, 48), cache.used);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try pinned.read(&byte, 0));
    try std.testing.expectEqual(@as(u8, 9), byte[0]);
    pinned.deinit();
    try std.testing.expectEqual(@as(usize, 0), cache.used);
}

test "pinned eviction prevents admission until lease release" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    var cache = try Cache.init(std.testing.allocator, std.testing.io, 160, 10, try testPath(tmp.dir, &path_buffer));
    defer cache.deinit();
    var encoded = try testEncoded(128, 3);
    defer encoded.deinit();
    const now = testNow();
    const key = keyFor("pinned", .{});
    const other = keyFor("other", .{});
    try std.testing.expect(try cache.insert(key, &encoded, now));
    var pinned = cache.get(key, now).?;
    try std.testing.expect(!try cache.insert(other, &encoded, now));
    try std.testing.expectEqual(@as(usize, 160), cache.used);
    var byte: [1]u8 = undefined;
    _ = try pinned.read(&byte, 127);
    try std.testing.expectEqual(@as(u8, 3), byte[0]);
    pinned.deinit();
    try std.testing.expect(try cache.insert(other, &encoded, now));
    try std.testing.expectEqual(@as(u8, 3), encoded.bytes[0]);
}

test "restart restores owned files TTL and ignores legacy files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const path = try testPath(tmp.dir, &path_buffer);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stash-thumbnail.jpg", .data = "legacy" });
    var encoded = try testEncoded(16, 5);
    defer encoded.deinit();
    const key = keyFor("persisted", .{});
    const now = testNow();
    var first = try Cache.init(std.testing.allocator, std.testing.io, 4096, 10, path);
    try std.testing.expect(try first.insert(key, &encoded, now));
    first.deinit();
    var cache = try Cache.init(std.testing.allocator, std.testing.io, 4096, 10, path);
    defer cache.deinit();
    try std.testing.expectEqual(@as(usize, 48), cache.used);
    var lease = cache.get(key, now + 1).?;
    lease.deinit();
    try std.testing.expect(cache.get(key, now + 10 * std.time.ns_per_s) == null);
    var legacy: [16]u8 = undefined;
    try std.testing.expectEqualStrings("legacy", try tmp.dir.readFile(std.testing.io, "stash-thumbnail.jpg", &legacy));
}

test "disabled cache does not touch nonexistent directory and oversize bypass retains ownership" {
    var cache = try Cache.init(std.testing.allocator, std.testing.io, 0, 1, "/nonexistent/imgresize-disabled");
    defer cache.deinit();
    var encoded = try testEncoded(64, 4);
    defer encoded.deinit();
    try std.testing.expect(!try cache.insert(keyFor("disabled", .{}), &encoded, testNow()));
    try std.testing.expect(cache.directory == null);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    var small = try Cache.init(std.testing.allocator, std.testing.io, 64, 1, try testPath(tmp.dir, &path_buffer));
    defer small.deinit();
    try std.testing.expect(!try small.insert(keyFor("large", .{}), &encoded, testNow()));
    try std.testing.expectEqual(@as(usize, 0), small.used);
    try std.testing.expectEqual(@as(u8, 4), encoded.bytes[0]);
}

test "SHA256 cache keys distinguish normalized option fields and source URL" {
    const base = keyFor("source", .{});
    try std.testing.expect(!std.mem.eql(u8, &base, &keyFor("other", .{})));
    inline for (.{ image.Options{ .width = 0 }, image.Options{ .height = 0 }, image.Options{ .width = 100 }, image.Options{ .height = 100 }, image.Options{ .fit = .contain }, image.Options{ .format = .png }, image.Options{ .quality = 90 } }) |options| {
        try std.testing.expect(!std.mem.eql(u8, &base, &keyFor("source", options)));
    }
}

fn concurrentInsert(cache: *Cache, key: Key, encoded: *image.Encoded, now: i96) Io.Cancelable!void {
    _ = try cache.insert(key, encoded, now);
}

test "concurrent admissions and duplicate publication respect the disk limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const limit = 4 * (Cache.header_size + 4096);
    var cache = try Cache.init(std.testing.allocator, std.testing.io, limit, 10, try testPath(tmp.dir, &path_buffer));
    defer cache.deinit();
    var encoded = try testEncoded(4096, 6);
    defer encoded.deinit();
    const now = testNow();
    var group: Io.Group = .init;
    defer group.cancel(std.testing.io);
    for (0..32) |index| {
        const key: Key = @splat(@intCast(index % 8));
        try group.concurrent(std.testing.io, concurrentInsert, .{ &cache, key, &encoded, now });
    }
    try group.await(std.testing.io);
    try std.testing.expect(cache.used <= limit);
    try std.testing.expect(cache.count <= 4);
    try std.testing.expectEqual(@as(usize, 0), cache.admissions);
    var iterator = cache.directory.?.iterate();
    var disk_bytes: usize = 0;
    var files: usize = 0;
    while (try iterator.next(std.testing.io)) |item| {
        try std.testing.expectEqual(Cache.name_size, item.name.len);
        const file = try cache.directory.?.openFile(std.testing.io, item.name, .{});
        defer file.close(std.testing.io);
        disk_bytes += @intCast((try file.stat(std.testing.io)).size);
        files += 1;
    }
    try std.testing.expectEqual(cache.used, disk_bytes);
    try std.testing.expectEqual(cache.count, files);
}

test "startup removes only recognizable orphan temps and expired owned files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const path = try testPath(tmp.dir, &path_buffer);
    const key = keyFor("orphan", .{});
    var name_buffer: [Cache.name_size]u8 = undefined;
    const name = Cache.filename(key, &name_buffer);
    var temp_buffer: [Cache.name_size + 16]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_buffer, "{s}.tmp-1-2", .{name});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = temp, .data = "partial" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "imgresize-v1-unrelated.tmp", .data = "keep" });
    var encoded = try testEncoded(16, 1);
    defer encoded.deinit();
    var first = try Cache.init(std.testing.allocator, std.testing.io, 4096, 1, path);
    try std.testing.expect(try first.insert(key, &encoded, testNow() - 2 * std.time.ns_per_s));
    first.deinit();
    var restored = try Cache.init(std.testing.allocator, std.testing.io, 4096, 1, path);
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 0), restored.used);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, name, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, temp, .{}));
    var unrelated: [8]u8 = undefined;
    try std.testing.expectEqualStrings("keep", try tmp.dir.readFile(std.testing.io, "imgresize-v1-unrelated.tmp", &unrelated));
}

test "canceled concurrent writes leave no temporary files or reservations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    var cache = try Cache.init(std.testing.allocator, std.testing.io, 8 * 1024 * 1024, 10, try testPath(tmp.dir, &path_buffer));
    defer cache.deinit();
    var encoded = try testEncoded(1024 * 1024, 8);
    defer encoded.deinit();
    var group: Io.Group = .init;
    defer group.cancel(std.testing.io);
    const now = testNow();
    for (0..16) |index| {
        const key: Key = @splat(@intCast(index));
        try group.concurrent(std.testing.io, concurrentInsert, .{ &cache, key, &encoded, now });
    }
    group.cancel(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), cache.admissions);
    var iterator = cache.directory.?.iterate();
    var bytes: usize = 0;
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |item| {
        try std.testing.expectEqual(Cache.name_size, item.name.len);
        const file = try cache.directory.?.openFile(std.testing.io, item.name, .{});
        defer file.close(std.testing.io);
        bytes += @intCast((try file.stat(std.testing.io)).size);
        count += 1;
    }
    try std.testing.expectEqual(cache.used, bytes);
    try std.testing.expectEqual(cache.count, count);
}
