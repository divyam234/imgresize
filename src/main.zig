const std = @import("std");
const Io = std.Io;
const Budget = @import("budget.zig").Budget;
const image = @import("resize.zig");
const fetch = @import("fetch.zig");
const response_cache = @import("cache.zig");

const Config = struct {
    port: u16,
    http_workers: usize,
    resize_workers: usize,
    connections: usize,
    source_bytes: usize,
    buffer_bytes: usize,
    pixels: usize,
    cache_bytes: usize,
    cache_ttl_seconds: usize,
    cache_cleanup_seconds: usize,
    vips_concurrency: c_int,

    fn load(env: *const std.process.Environ.Map) !Config {
        return .{
            .port = @intCast(try number(env, "PORT", 8080, 65535)),
            .http_workers = try number(env, "THREAD_POOL", 8, 128),
            .resize_workers = try number(env, "RESIZE_WORKERS", @min(std.Thread.getCpuCount() catch 1, 4), 128),
            .connections = try number(env, "CONN_LIMIT", 128, 65535),
            .source_bytes = (try number(env, "MAX_BODY_MB", 50, 1024)) * 1024 * 1024,
            .buffer_bytes = (try number(env, "BUFFER_MEMORY_MB", 128, 8192)) * 1024 * 1024,
            .pixels = try number(env, "MAX_PIXELS", 40000000, std.math.maxInt(c_int)),
            .cache_bytes = try cacheSize(env.get("CACHE_MAX_SIZE") orelse "0"),
            .cache_ttl_seconds = try number(env, "CACHE_TTL_SECONDS", 300, std.math.maxInt(i64)),
            .cache_cleanup_seconds = try number(env, "CACHE_CLEANUP_SECONDS", 30, std.math.maxInt(i64)),
            .vips_concurrency = @intCast(try number(env, "VIPS_CONCURRENCY", 1, 128)),
        };
    }

    fn number(env: *const std.process.Environ.Map, name: []const u8, default: usize, maximum: usize) !usize {
        const text = env.get(name) orelse return default;
        if (text.len == 0) return default;
        const value = std.fmt.parseInt(usize, text, 10) catch return invalid(name, maximum);
        if (value == 0 or value > maximum) return invalid(name, maximum);
        return value;
    }

    fn cacheSize(text: []const u8) !usize {
        return parseCacheSize(text) catch {
            std.log.err("invalid CACHE_MAX_SIZE (expected 0..8GiB, e.g. 64MiB or 512MB)", .{});
            return error.InvalidConfiguration;
        };
    }

    fn invalid(name: []const u8, maximum: usize) error{InvalidConfiguration} {
        std.log.err("invalid {s} (expected 1..{d})", .{ name, maximum });
        return error.InvalidConfiguration;
    }
};

fn parseCacheSize(text: []const u8) error{InvalidSize}!usize {
    const value = std.mem.trim(u8, text, " \t\r\n");
    if (value.len == 0) return 0;
    var end: usize = 0;
    while (end < value.len and std.ascii.isDigit(value[end])) : (end += 1) {}
    if (end == 0) return error.InvalidSize;
    const amount = std.fmt.parseInt(usize, value[0..end], 10) catch return error.InvalidSize;
    const unit = std.mem.trim(u8, value[end..], " \t");
    const multiplier: usize = if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "B"))
        1
    else if (std.ascii.eqlIgnoreCase(unit, "KB"))
        1000
    else if (std.ascii.eqlIgnoreCase(unit, "MB"))
        1000 * 1000
    else if (std.ascii.eqlIgnoreCase(unit, "GB"))
        1000 * 1000 * 1000
    else if (std.ascii.eqlIgnoreCase(unit, "KiB"))
        1024
    else if (std.ascii.eqlIgnoreCase(unit, "MiB"))
        1024 * 1024
    else if (std.ascii.eqlIgnoreCase(unit, "GiB"))
        1024 * 1024 * 1024
    else
        return error.InvalidSize;
    const maximum: usize = 8 * 1024 * 1024 * 1024;
    if (amount > maximum / multiplier) return error.InvalidSize;
    return amount * multiplier;
}

const Job = struct {
    stream: Io.net.Stream,
    deadline: Io.Clock.Timestamp,
};

const Service = struct {
    io: Io,
    config: Config,
    budget: Budget,
    cache: response_cache.Cache,
    slots: Io.Semaphore,
    client: std.http.Client,
    queue: Io.Queue(Job),
    connections: std.atomic.Value(usize) = .init(0),

    fn accept(self: *Service, listener: *Io.net.Server) !void {
        while (true) {
            const stream = listener.accept(self.io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => return err,
            };
            const previous = self.connections.fetchAdd(1, .monotonic);
            if (previous >= self.config.connections) {
                _ = self.connections.fetchSub(1, .monotonic);
                stream.close(self.io);
                continue;
            }
            const job: Job = .{
                .stream = stream,
                .deadline = deadlineAfter(self.io, 30),
            };
            self.queue.putOne(self.io, job) catch |err| {
                stream.close(self.io);
                _ = self.connections.fetchSub(1, .monotonic);
                return err;
            };
        }
    }

    fn worker(self: *Service) Io.Cancelable!void {
        while (true) {
            const job = self.queue.getOne(self.io) catch |err| switch (err) {
                error.Closed => return,
                error.Canceled => return error.Canceled,
            };
            defer job.stream.close(self.io);
            defer _ = self.connections.fetchSub(1, .monotonic);
            timed(self.io, job.deadline, Service.serve, .{ self, job.stream }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                // Client disconnects, malformed heads and expired connections end here.
                else => {},
            };
        }
    }

    fn cleanCache(self: *Service) Io.Cancelable!void {
        while (true) {
            try Io.sleep(self.io, .fromSeconds(@intCast(self.config.cache_cleanup_seconds)), .awake);
            self.cache.cleanup(cacheNow(self.io));
        }
    }

    fn serve(self: *Service, stream: Io.net.Stream) !void {
        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        var writer = stream.writer(self.io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        if (request.head.method != .GET)
            return respond(&request, .method_not_allowed, "use GET /resize?url=...\n", "text/plain", false);
        const target = request.head.target;
        const split = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        const path = target[0..split];
        if (std.mem.eql(u8, path, "/health"))
            return respond(&request, .ok, "ok\n", "text/plain", false);
        if (!std.mem.eql(u8, path, "/resize"))
            return respond(&request, .not_found, "use GET /resize?url=...\n", "text/plain", false);

        // Decode once into stack storage; all parameter slices live through the response.
        var query_buffer: [8192]u8 = undefined;
        const raw_query = if (split < target.len) target[split + 1 ..] else "";
        const parameters = Parameters.parse(raw_query, &query_buffer) catch
            return respond(&request, .bad_request, "invalid query encoding\n", "text/plain", false);
        const source_url = parameters.url orelse
            return respond(&request, .bad_request, "missing url parameter\n", "text/plain", false);
        if (source_url.len == 0)
            return respond(&request, .bad_request, "missing url parameter\n", "text/plain", false);
        const options = parameters.options();
        const key = if (self.config.cache_bytes != 0) response_cache.keyFor(source_url, options) else [_]u8{0} ** 32;
        if (if (self.config.cache_bytes != 0) self.cache.get(key, cacheNow(self.io)) else null) |cached| {
            var lease = cached;
            defer lease.deinit();
            return respond(&request, .ok, lease.bytes(), options.format.contentType(), true);
        }

        var source = fetch.download(&self.client, source_url, self.config.source_bytes, &self.budget) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.InvalidUrl => return respond(&request, .bad_request, "url must use http or https\n", "text/plain", false),
            error.MemoryBudget => return respond(&request, .service_unavailable, "source memory budget exhausted; retry later\n", "text/plain", false),
            else => return respond(&request, .bad_gateway, "source download failed or exceeded size/time limit\n", "text/plain", false),
        };
        defer source.deinit();
        const resized = blk: {
            try self.slots.wait(self.io);
            defer self.slots.post(self.io);
            try self.io.checkCancel();
            break :blk image.resize(source.bytes(), options, self.config.pixels);
        };
        source.deinit();
        var encoded: ?image.Encoded = resized catch {
            image.vips.vips_error_clear();
            return respond(&request, .bad_request, "decode/resize failed or exceeded pixel limit\n", "text/plain", false);
        };
        defer if (encoded) |*owned| owned.deinit();
        try self.io.checkCancel();
        if (if (self.config.cache_bytes != 0) self.cache.insert(key, &encoded.?, cacheNow(self.io)) else null) |cached| {
            encoded = null;
            var lease = cached;
            defer lease.deinit();
            return respond(&request, .ok, lease.bytes(), options.format.contentType(), true);
        }
        if (!self.budget.reserve(encoded.?.bytes.len))
            return respond(&request, .service_unavailable, "response memory budget exhausted; retry later\n", "text/plain", false);
        defer self.budget.release(encoded.?.bytes.len);
        try respond(&request, .ok, encoded.?.bytes, options.format.contentType(), true);
    }
};

const Parameters = struct {
    url: ?[]const u8 = null,
    width: ?[]const u8 = null,
    height: ?[]const u8 = null,
    fit: ?[]const u8 = null,
    format: ?[]const u8 = null,
    alias: ?[]const u8 = null,
    quality: ?[]const u8 = null,

    fn parse(raw: []const u8, storage: []u8) !Parameters {
        var result: Parameters = .{};
        var used: usize = 0;
        var fields = std.mem.splitScalar(u8, raw, '&');
        while (fields.next()) |field| {
            const separator = std.mem.indexOfScalar(u8, field, '=') orelse field.len;
            const key = try decode(field[0..separator], storage, &used);
            const value = try decode(if (separator < field.len) field[separator + 1 ..] else "", storage, &used);
            const entry: ?*?[]const u8 = if (std.mem.eql(u8, key, "url")) &result.url else if (std.mem.eql(u8, key, "w")) &result.width else if (std.mem.eql(u8, key, "h")) &result.height else if (std.mem.eql(u8, key, "fit")) &result.fit else if (std.mem.eql(u8, key, "format")) &result.format else if (std.mem.eql(u8, key, "f")) &result.alias else if (std.mem.eql(u8, key, "q")) &result.quality else null;
            if (entry) |pointer| if (pointer.* == null) {
                pointer.* = value;
            };
        }
        return result;
    }

    fn options(self: Parameters) image.Options {
        const width = dimension(self.width, 300);
        const format = self.format orelse self.alias orelse "jpeg";
        const fit = self.fit orelse "cover";
        return .{
            .width = width,
            .height = dimension(self.height, width),
            .quality = @intCast(@min(dimension(self.quality, 80), 100)),
            .fit = if (equal(fit, "contain")) .contain else if (equal(fit, "inside")) .inside else if (equal(fit, "outside")) .outside else if (equal(fit, "fill")) .fill else .cover,
            .format = if (equal(format, "webp")) .webp else if (equal(format, "png")) .png else if (equal(format, "avif")) .avif else .jpeg,
        };
    }

    fn dimension(text: ?[]const u8, default: u32) u32 {
        const value = std.fmt.parseInt(u32, text orelse return default, 10) catch return default;
        return if (value > 0 and value <= 8192) value else default;
    }

    fn equal(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }

    fn decode(raw: []const u8, storage: []u8, used: *usize) ![]const u8 {
        const start = used.*;
        var index: usize = 0;
        while (index < raw.len) : (index += 1) {
            if (used.* == storage.len) return error.QueryTooLarge;
            const byte: u8 = switch (raw[index]) {
                '+' => ' ',
                '%' => blk: {
                    if (raw.len - index < 3) return error.InvalidEncoding;
                    const high = std.fmt.charToDigit(raw[index + 1], 16) catch return error.InvalidEncoding;
                    const low = std.fmt.charToDigit(raw[index + 2], 16) catch return error.InvalidEncoding;
                    const value = high * 16 + low;
                    index += 2;
                    break :blk value;
                },
                else => raw[index],
            };
            if (byte == 0) return error.InvalidEncoding;
            storage[used.*] = byte;
            used.* += 1;
        }
        return storage[start..used.*];
    }
};

fn respond(request: *std.http.Server.Request, status: std.http.Status, body: []const u8, content_type: []const u8, cache: bool) !void {
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = content_type },
        .{ .name = "Cache-Control", .value = "public, max-age=86400" },
    };
    try request.respond(body, .{
        .status = status,
        // Fixed workers do not remain occupied by idle keep-alive clients.
        .keep_alive = false,
        .extra_headers = headers[0..if (cache) @as(usize, 2) else 1],
    });
}

fn cacheNow(io: Io) i96 {
    return Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
}

fn deadlineAfter(io: Io, seconds: i64) Io.Clock.Timestamp {
    return Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .clock = .awake, .raw = .fromSeconds(seconds) });
}

fn timed(io: Io, deadline: Io.Clock.Timestamp, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) anyerror!@typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.payload {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Completion = union(enum) { done: Result, timeout: Io.Cancelable!void };
    var results: [2]Completion = undefined;
    var select = Io.Select(Completion).init(io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.timeout, Io.Clock.Timestamp.wait, .{ deadline, io });
    try select.concurrent(.done, function, args);
    return switch (try select.await()) {
        .done => |result| try result,
        .timeout => |result| blk: {
            try result;
            break :blk error.Timeout;
        },
    };
}

fn waitForSignal(io: Io, file: Io.File) !void {
    var reader = file.readerStreaming(io, &.{});
    var signal_info: [128]u8 = undefined;
    try reader.interface.readSliceAll(&signal_info);
}

pub fn main(init: std.process.Init) !void {
    const config = try Config.load(init.environ_map);
    const io = init.io;
    var signals = std.posix.sigemptyset();
    std.posix.sigaddset(&signals, .INT);
    std.posix.sigaddset(&signals, .TERM);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &signals, null);
    const signal_file: Io.File = .{
        .handle = try std.posix.signalfd(-1, &signals, std.os.linux.SFD.CLOEXEC),
        .flags = .{ .nonblocking = false },
    };
    defer signal_file.close(io);

    if (image.vips.vips_init("imgresize") != 0) return error.VipsInitialization;
    defer image.vips.vips_shutdown();
    image.vips.vips_cache_set_max(0);
    image.vips.vips_cache_set_max_mem(0);
    image.vips.vips_concurrency_set(config.vips_concurrency);

    const address = try Io.net.IpAddress.parseIp4("0.0.0.0", config.port);
    var listener = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = @intCast(config.connections) });
    defer listener.deinit(io);
    // Map large source buffers directly instead of retaining libc thread arenas.
    const allocator = if (@import("builtin").mode == .Debug) init.gpa else std.heap.smp_allocator;
    const queue_storage = try allocator.alloc(Job, config.connections);
    defer allocator.free(queue_storage);
    var service: Service = .{
        .io = io,
        .config = config,
        .cache = try response_cache.Cache.init(allocator, io, config.cache_bytes, config.cache_ttl_seconds),
        .budget = .{ .limit = config.buffer_bytes },
        .slots = .{ .permits = config.resize_workers },
        .client = .{ .allocator = allocator, .io = io, .connection_pool = .{ .free_size = config.http_workers } },
        .queue = .init(queue_storage),
    };
    defer service.client.deinit();
    defer service.cache.deinit();
    defer std.debug.assert(service.budget.used.load(.monotonic) == 0);
    var workers: Io.Group = .init;
    defer {
        service.queue.close(io);
        workers.cancel(io);
        var remaining: [1]Job = undefined;
        while ((service.queue.getUncancelable(io, &remaining, 0) catch 0) != 0) {
            remaining[0].stream.close(io);
            _ = service.connections.fetchSub(1, .monotonic);
        }
        std.debug.assert(service.connections.load(.monotonic) == 0);
    }
    for (0..config.http_workers) |_| try workers.concurrent(io, Service.worker, .{&service});
    if (config.cache_bytes != 0) try workers.concurrent(io, Service.cleanCache, .{&service});

    const Completion = union(enum) { stopped: anyerror!void, serve: anyerror!void };
    var results: [2]Completion = undefined;
    var select = Io.Select(Completion).init(io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.stopped, waitForSignal, .{ io, signal_file });
    try select.concurrent(.serve, Service.accept, .{ &service, &listener });
    std.log.info("imgresize listening on :{d} (HTTP workers={d}, resize workers={d}, connections={d}, vips concurrency={d})", .{ config.port, config.http_workers, config.resize_workers, config.connections, config.vips_concurrency });
    switch (try select.await()) {
        .stopped => |result| try result,
        .serve => |result| try result,
    }
}

test "encoded source query and explicit format precedence" {
    var storage: [1024]u8 = undefined;
    const parameters = try Parameters.parse(
        "url=https%3A%2F%2Fexample.com%2Fphoto%3Fx%3D1%26y%3Da%2Bb&f=png&format=webp&w=400&h=100&fit=fill&q=90",
        &storage,
    );
    try std.testing.expectEqualStrings("https://example.com/photo?x=1&y=a+b", parameters.url.?);
    try std.testing.expectEqual(image.Options{
        .width = 400,
        .height = 100,
        .fit = .fill,
        .format = .webp,
        .quality = 90,
    }, parameters.options());
}

test "malformed URL escapes and query storage limits reject safely" {
    var storage: [32]u8 = undefined;
    try std.testing.expectError(error.InvalidEncoding, Parameters.parse("url=x%2", &storage));
    try std.testing.expectError(error.InvalidEncoding, Parameters.parse("url=x%GG", &storage));
    try std.testing.expectError(error.InvalidEncoding, Parameters.parse("url=x%00", &storage));
    try std.testing.expectError(error.InvalidEncoding, Parameters.parse("url=x%+1", &storage));
    try std.testing.expectError(error.InvalidEncoding, Parameters.parse("url=x%_1", &storage));
    var short: [4]u8 = undefined;
    try std.testing.expectError(error.QueryTooLarge, Parameters.parse("url=abc", &short));
}

test "dimensions and quality retain bounded fallback behavior" {
    const options = (Parameters{
        .width = "400",
        .height = "8193",
        .quality = "200",
        .format = "WEBP",
    }).options();
    try std.testing.expectEqual(@as(u32, 400), options.height);
    try std.testing.expectEqual(@as(u8, 100), options.quality);
    try std.testing.expectEqual(image.Format.webp, options.format);
}

test "cache keys normalize defaults aliases parameter order and fallbacks" {
    var left_storage: [1024]u8 = undefined;
    var right_storage: [1024]u8 = undefined;
    const left = try Parameters.parse("url=https%3A%2F%2Fexample.com%2Fa", &left_storage);
    const right = try Parameters.parse("q=80&fit=COVER&h=300&w=300&f=JPEG&url=https%3A%2F%2Fexample.com%2Fa", &right_storage);
    try std.testing.expectEqual(response_cache.keyFor(left.url.?, left.options()), response_cache.keyFor(right.url.?, right.options()));
    const fallback = (Parameters{ .width = "bad", .height = "0", .quality = "bad", .format = "unknown", .fit = "unknown" }).options();
    try std.testing.expectEqual(response_cache.keyFor(left.url.?, left.options()), response_cache.keyFor(left.url.?, fallback));
}

test "human-readable cache sizes distinguish decimal and binary units and reject overflow" {
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), try parseCacheSize("64MiB"));
    try std.testing.expectEqual(@as(usize, 512000000), try parseCacheSize("512MB"));
    try std.testing.expectEqual(@as(usize, 1024), try parseCacheSize(" 1 kib "));
    try std.testing.expectEqual(@as(usize, 4096), try parseCacheSize("4096"));
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024 * 1024), try parseCacheSize("8GiB"));
    try std.testing.expectEqual(@as(usize, 0), try parseCacheSize("0B"));
    for ([_][]const u8{ "-1MiB", "1.5GB", "64MIB junk", "9GiB", "8589934593B", "18446744073709551616", "18446744073709551615GB", "MiB" }) |invalid| {
        try std.testing.expectError(error.InvalidSize, parseCacheSize(invalid));
    }
}
