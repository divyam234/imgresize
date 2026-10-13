const std = @import("std");
const Budget = @import("budget.zig").Budget;
const Io = std.Io;

pub const Source = struct {
    buffer: []u8 = &.{},
    len: usize = 0,
    allocator: std.mem.Allocator,
    budget: *Budget,

    pub fn bytes(self: *const Source) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn deinit(self: *Source) void {
        const capacity = self.buffer.len;
        if (capacity == 0) return;
        self.allocator.free(self.buffer);
        self.budget.release(capacity);
        self.buffer = &.{};
        self.len = 0;
    }

    fn grow(self: *Source, max_bytes: usize) !void {
        const old_capacity = self.buffer.len;
        const capacity = if (old_capacity == 0)
            @min(@as(usize, 65536), max_bytes)
        else if (old_capacity > max_bytes / 2)
            max_bytes
        else
            old_capacity * 2;
        const extra = capacity - old_capacity;
        if (!self.budget.reserve(extra)) return error.MemoryBudget;
        self.buffer = self.allocator.realloc(self.buffer, capacity) catch {
            self.budget.release(extra);
            return error.MemoryBudget;
        };
    }
};

// Tasks publish resources through caller-owned slots rather than Select results.
// Canceling and joining the Select before inspecting a slot also covers the race
// where a task completes successfully just as its deadline wins.
const Completion = union(enum) {
    operation: anyerror!void,
    deadline: Io.Cancelable!void,
};

fn waitDeadline(io: Io, deadline: Io.Clock.Timestamp) Io.Cancelable!void {
    try deadline.wait(io);
}

fn deadlineAfter(io: Io, seconds: i64) Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = .fromSeconds(seconds), .clock = .awake });
}

fn validUrlText(text: []const u8) bool {
    for (text) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn validUri(uri: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return false;
    var host_buffer: [Io.net.HostName.max_len]u8 = undefined;
    const host = uri.host orelse return false;
    const bytes = host.toRaw(&host_buffer) catch return false;
    if (bytes.len > 1 and bytes[0] == '[' and bytes[bytes.len - 1] == ']') {
        _ = Io.net.Ip6Address.parse(bytes[1 .. bytes.len - 1], uri.port orelse 0) catch return false;
    } else {
        Io.net.HostName.validate(bytes) catch return false;
    }
    return true;
}

fn closeRequest(request: *std.http.Client.Request) void {
    // Never drain an error/redirect body in deinit: that could block after the
    // deadline, or download an unbounded body just to reuse the connection.
    if (request.connection) |connection| connection.closing = true;
    request.deinit();
}

fn openRequest(client: *std.http.Client, uri: std.Uri, slot: *?std.http.Client.Request) anyerror!void {
    slot.* = client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = true,
        .headers = .{
            .user_agent = .{ .override = "imgresize/1.0" },
            .accept_encoding = .{ .override = "identity" },
        },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.MemoryBudget,
        else => return err,
    };
    const request = &slot.*.?;
    request.reader.max_head_len = 8192;
    request.accept_encoding = @splat(false);
    request.accept_encoding[@intFromEnum(std.http.ContentEncoding.identity)] = true;
    try request.sendBodiless();
}

fn connectWithDeadline(client: *std.http.Client, uri: std.Uri) !std.http.Client.Request {
    var slot: ?std.http.Client.Request = null;
    errdefer if (slot) |*request| closeRequest(request);
    var results: [2]Completion = undefined;
    var select = Io.Select(Completion).init(client.io, &results);
    defer select.cancelDiscard();
    // concurrent, not async: async may execute inline and prevent a timer from
    // starting when the Io implementation has exhausted its concurrency.
    const deadline = deadlineAfter(client.io, 5);
    try select.concurrent(.operation, openRequest, .{ client, uri, &slot });
    try select.concurrent(.deadline, waitDeadline, .{ client.io, deadline });
    const result = try select.await();
    select.cancelDiscard();
    switch (result) {
        .operation => |operation| try operation,
        .deadline => |timer| {
            try timer;
            return error.Timeout;
        },
    }
    return slot.?;
}

fn transfer(client: *std.http.Client, initial_uri: std.Uri, max_bytes: usize, source: *Source) anyerror!void {
    var uri = initial_uri;
    // Resolution keeps references to preceding URI components. A single bounded
    // arena preserves those components throughout all five redirect hops.
    var redirect_storage: [65536]u8 = undefined;
    var redirect_space: []u8 = &redirect_storage;
    var redirects: usize = 0;
    while (true) {
        // URI schemes are case-insensitive; the native protocol table is not.
        uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) "http" else "https";
        var request = try connectWithDeadline(client, uri);
        var fully_read = false;
        defer if (fully_read) request.deinit() else closeRequest(&request);
        var response = try request.receiveHead(&.{});
        const status = response.head.status;
        if (status == .moved_permanently or status == .found or
            status == .see_other or status == .temporary_redirect or
            status == .permanent_redirect)
        {
            if (redirects == 5) return error.TooManyHttpRedirects;
            const location = response.head.location orelse return error.HttpRedirectLocationMissing;
            if (!validUrlText(location)) return error.InvalidRedirectUrl;
            if (location.len > redirect_space.len) return error.HttpRedirectLocationOversize;
            @memcpy(redirect_space[0..location.len], location);
            uri = try uri.resolveInPlace(location.len, &redirect_space);
            if (!validUri(uri)) return error.InvalidRedirectUrl;
            redirects += 1;
            continue;
        }
        if (status.class() != .success) return error.HttpStatus;
        const content_length = response.head.content_length;
        if (content_length) |length| {
            if (length > max_bytes) return error.SourceTooLarge;
        }
        // No payload decompression: Accept-Encoding is identity and the native
        // reader still validates HTTP transfer framing (including chunked data).
        const reader = response.reader(&.{});
        while (true) {
            if (source.len == source.buffer.len) {
                var next: [1]u8 = undefined;
                if (try reader.readSliceShort(&next) == 0) break;
                if (source.len == max_bytes) return error.SourceTooLarge;
                try source.grow(max_bytes);
                source.buffer[source.len] = next[0];
                source.len += 1;
            }
            const available = source.buffer[source.len..];
            const count = try reader.readSliceShort(available);
            source.len += count;
            if (count != available.len) break;
        }
        if (source.len == 0) return error.EmptySource;
        // The native content-length reader can report EOF for a truncated body;
        // explicitly verify the announced length instead of accepting that EOF.
        if (content_length) |length| {
            if (response.head.transfer_encoding == .none and source.len != length)
                return error.IncompleteResponse;
        }
        fully_read = true;
        return;
    }
}

pub fn download(client: *std.http.Client, url: []const u8, max_bytes: usize, budget: *Budget) !Source {
    const deadline = deadlineAfter(client.io, 20);
    if (url.len > 8192 or !validUrlText(url)) return error.InvalidUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!validUri(uri)) return error.InvalidUrl;
    var source: Source = .{ .allocator = client.allocator, .budget = budget };
    errdefer source.deinit();
    var results: [2]Completion = undefined;
    var select = Io.Select(Completion).init(client.io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.operation, transfer, .{ client, uri, max_bytes, &source });
    try select.concurrent(.deadline, waitDeadline, .{ client.io, deadline });
    const result = try select.await();
    select.cancelDiscard();
    switch (result) {
        .operation => |operation| try operation,
        .deadline => |timer| {
            try timer;
            return error.Timeout;
        },
    }
    return source;
}
