const std = @import("std");
const Io = std.Io;
const vips = @import("vips.zig");
const a = std.testing.allocator;
const io = std.testing.io;
const null_arg: ?*anyopaque = null;

fn timer(seconds: i64) Io.Cancelable!void {
    try Io.sleep(io, .fromSeconds(seconds), .awake);
}

// Cancel and join both contenders before inspecting caller-owned output slots.
fn bounded(comptime function: anytype, args: anytype, seconds: i64) !void {
    const Result = union(enum) { operation: anyerror!void, timeout: Io.Cancelable!void };
    var storage: [2]Result = undefined;
    var select = Io.Select(Result).init(io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.operation, function, args);
    try select.concurrent(.timeout, timer, .{seconds});
    const result = try select.await();
    select.cancelDiscard();
    switch (result) {
        .operation => |value| try value,
        .timeout => |value| {
            try value;
            return error.TestDeadlineExceeded;
        },
    }
}

const Fixture = struct {
    bytes: []u8,

    fn init(noisy: bool) !Fixture {
        var image: ?*vips.Image = null;
        var pixels: []u8 = &.{};
        defer a.free(pixels);
        defer if (image) |owned| vips.g_object_unref(owned);
        if (noisy) {
            pixels = try a.alloc(u8, 1024 * 1024 * 3);
            var random = std.Random.DefaultPrng.init(0x12345678);
            random.random().bytes(pixels);
            image = vips.vips_image_new_from_memory(pixels.ptr, pixels.len, 1024, 1024, 3, 0);
            try std.testing.expect(image != null);
        } else {
            try std.testing.expectEqual(@as(c_int, 0), vips.vips_black(&image, 160, 120, "bands", @as(c_int, 3), null_arg));
        }
        var data: ?*anyopaque = null;
        var size: usize = 0;
        errdefer vips.g_free(data);
        try std.testing.expectEqual(@as(c_int, 0), vips.vips_jpegsave_buffer(image.?, &data, &size, "Q", @as(c_int, if (noisy) 65 else 90), null_arg));
        return .{ .bytes = @as([*]u8, @ptrCast(data.?))[0..size] };
    }

    fn deinit(self: Fixture) void {
        vips.g_free(self.bytes.ptr);
    }
};

const Reply = struct {
    status: std.http.Status,
    bytes: []u8,
    fn deinit(self: Reply) void {
        a.free(self.bytes);
    }
};

fn exchange(port: u16, target: []const u8, method: std.http.Method, output: *?Reply) !void {
    return exchangeWithPause(port, target, method, output, null, null);
}

fn exchangeWithPause(port: u16, target: []const u8, method: std.http.Method, output: *?Reply, entered: ?*Io.Event, release: ?*Io.Event) !void {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ port, target });
    defer a.free(url);
    var request = try client.request(method, try std.Uri.parse(url), .{ .keep_alive = false });
    defer {
        if (request.connection) |connection| connection.closing = true;
        request.deinit();
    }
    if (method.requestHasBody()) {
        try request.sendBodyComplete(&.{});
    } else {
        try request.sendBodiless();
    }
    var response = try request.receiveHead(&.{});
    if (entered) |event| event.set(io);
    if (release) |event| try event.wait(io);
    const bytes = try response.reader(&.{}).allocRemaining(a, .limited(8 * 1024 * 1024));
    errdefer a.free(bytes);
    if (response.head.content_length) |length| try std.testing.expectEqual(length, bytes.len);
    output.* = .{ .status = response.head.status, .bytes = bytes };
}

fn call(port: u16, target: []const u8, method: std.http.Method) !Reply {
    var reply: ?Reply = null;
    errdefer if (reply) |r| r.deinit();
    try bounded(exchange, .{ port, target, method, &reply }, 35);
    return reply.?;
}

fn targetFor(origin: u16, path: []const u8, options: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "/resize?url=http%3A%2F%2F127.0.0.1%3A{d}{s}{s}", .{ origin, path, options });
}

fn expectImage(reply: Reply, width: c_int, height: c_int, format: @import("resize.zig").Format) !void {
    try std.testing.expectEqual(.ok, reply.status);
    switch (format) {
        .jpeg => try std.testing.expect(std.mem.startsWith(u8, reply.bytes, "\xff\xd8")),
        .png => try std.testing.expect(std.mem.startsWith(u8, reply.bytes, "\x89PNG\r\n\x1a\n")),
        .webp => {
            if (reply.bytes.len < 12) return error.InvalidReturnedImage;
            try std.testing.expectEqualStrings("RIFF", reply.bytes[0..4]);
            try std.testing.expectEqualStrings("WEBP", reply.bytes[8..12]);
        },
        .avif => {
            if (reply.bytes.len < 12) return error.InvalidReturnedImage;
            try std.testing.expectEqualStrings("ftyp", reply.bytes[4..8]);
            try std.testing.expectEqualStrings("avif", reply.bytes[8..12]);
        },
    }
    const image = vips.vips_image_new_from_buffer(reply.bytes.ptr, reply.bytes.len, "", null_arg) orelse return error.InvalidReturnedImage;
    defer vips.g_object_unref(image);
    try std.testing.expectEqual(width, vips.vips_image_get_width(image));
    try std.testing.expectEqual(height, vips.vips_image_get_height(image));
}

fn listener() !Io.net.Server {
    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    return address.listen(io, .{ .kernel_backlog = 256 });
}

const CacheConfig = struct {
    temporary: std.testing.TmpDir,
    path: []u8,
    max_size: []const u8,
    ttl: []const u8,

    fn init(max_size: []const u8, ttl: []const u8) !CacheConfig {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const length = try temporary.dir.realPath(io, &buffer);
        return .{
            .temporary = temporary,
            .path = try a.dupe(u8, buffer[0..length]),
            .max_size = max_size,
            .ttl = ttl,
        };
    }

    fn deinit(self: *CacheConfig) void {
        a.free(self.path);
        self.temporary.cleanup();
    }
};

const Service = struct {
    child: std.process.Child,
    port: u16,

    fn start(small: bool, pixels: usize) !Service {
        return startWithCache(small, pixels, null);
    }

    fn startWithCache(small: bool, pixels: usize, cache: ?*const CacheConfig) !Service {
        var reservation = try listener();
        const port = reservation.socket.address.getPort();
        reservation.deinit(io);
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        var buffer: [32]u8 = undefined;
        try env.put("PORT", try std.fmt.bufPrint(&buffer, "{d}", .{port}));
        try env.put("THREAD_POOL", "4");
        try env.put("RESIZE_WORKERS", "2");
        try env.put("CONN_LIMIT", "256");
        try env.put("VIPS_CONCURRENCY", "1");
        try env.put("MAX_BODY_SIZE", if (small) "1MiB" else "8MiB");
        try env.put("BUFFER_MEMORY_SIZE", if (small) "1MiB" else "64MiB");
        try env.put("MAX_PIXELS", try std.fmt.bufPrint(&buffer, "{d}", .{pixels}));
        try env.put("CACHE_MAX_SIZE", "0");
        if (cache) |config| {
            try env.put("CACHE_DIR", config.path);
            try env.put("CACHE_MAX_SIZE", config.max_size);
            try env.put("CACHE_TTL_SECONDS", config.ttl);
            try env.put("CACHE_CLEANUP_SECONDS", "1");
        }
        var child = try std.process.spawn(io, .{
            .argv = &.{@import("test_options").server_path},
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        errdefer child.kill(io);
        try bounded(ready, .{port}, 10);
        return .{ .child = child, .port = port };
    }

    fn ready(port: u16) !void {
        while (true) {
            var reply: ?Reply = null;
            exchange(port, "/health", .GET, &reply) catch |err| {
                if (err == error.Canceled) return err;
                try Io.sleep(io, .fromMilliseconds(20), .awake);
                continue;
            };
            defer reply.?.deinit();
            try std.testing.expectEqual(.ok, reply.?.status);
            return;
        }
    }

    fn wait(child: *std.process.Child, term: *?std.process.Child.Term) !void {
        term.* = try child.wait(io);
    }

    fn stop(self: *Service) !void {
        try std.testing.expectEqual(@as(usize, 0), std.os.linux.kill(self.child.id.?, .TERM));
        var term: ?std.process.Child.Term = null;
        try bounded(wait, .{ &self.child, &term }, 10);
        switch (term.?) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.ServiceDidNotExitCleanly,
        }
    }

    fn deinit(self: *Service) void {
        self.child.kill(io);
    }
};

const Origin = struct {
    server: Io.net.Server,
    fixture: []const u8,
    alternate_fixture: []const u8 = &.{},
    use_alternate: std.atomic.Value(bool) = .init(false),
    unavailable: std.atomic.Value(bool) = .init(false),
    fetched: std.atomic.Value(usize) = .init(0),
    tasks: Io.Group = .init,
    handlers: Io.Group = .init,
    release: Io.Event = .unset,
    entered: Io.Event = .unset,
    reused: std.atomic.Value(usize) = .init(0),

    fn start(self: *Origin) !void {
        try self.tasks.concurrent(io, accept, .{self});
    }
    fn port(self: *Origin) u16 {
        return self.server.socket.address.getPort();
    }
    fn deinit(self: *Origin) void {
        self.tasks.cancel(io);
        self.handlers.cancel(io);
        self.server.deinit(io);
    }
    fn accept(self: *Origin) Io.Cancelable!void {
        while (true) {
            const stream = self.server.accept(io) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                return;
            };
            self.handlers.concurrent(io, handle, .{ self, stream }) catch {
                stream.close(io);
                return;
            };
        }
    }
    fn handle(self: *Origin, stream: Io.net.Stream) Io.Cancelable!void {
        serve(self, stream) catch |err| {
            if (err == error.Canceled) return error.Canceled;
        };
    }
    fn serve(self: *Origin, stream: Io.net.Stream) !void {
        defer stream.close(io);
        var rb: [8192]u8 = undefined;
        var wb: [4096]u8 = undefined;
        var reader = stream.reader(io, &rb);
        var writer = stream.writer(io, &wb);
        var http = std.http.Server.init(&reader.interface, &writer.interface);
        const request = try http.receiveHead();
        const path = request.head.target;
        _ = self.fetched.fetchAdd(1, .monotonic);
        if (self.unavailable.load(.acquire)) {
            try writer.interface.writeAll("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return writer.interface.flush();
        }
        const fixture = if (std.mem.eql(u8, path, "/mutable") and self.use_alternate.load(.acquire))
            self.alternate_fixture
        else
            self.fixture;
        const w = &writer.interface;
        if (std.mem.eql(u8, path, "/reuse")) {
            try w.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n", .{self.fixture.len});
            try w.writeAll(self.fixture);
            try w.flush();
            var next_http = std.http.Server.init(&reader.interface, &writer.interface);
            const next = try next_http.receiveHead();
            if (!std.mem.eql(u8, next.head.target, "/reuse")) return error.UnexpectedReuseTarget;
            _ = self.reused.fetchAdd(1, .monotonic);
            try w.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{self.fixture.len});
            try w.writeAll(self.fixture);
            return w.flush();
        }
        if (std.mem.eql(u8, path, "/uppercase")) {
            try w.print("HTTP/1.1 302 Found\r\nLocation: HTTP://127.0.0.1:{d}/image\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{self.port()});
            return w.flush();
        }
        if (std.mem.startsWith(u8, path, "/chain/")) {
            const hops = try std.fmt.parseInt(u8, path[7..], 10);
            if (hops != 0) {
                try w.print("HTTP/1.1 302 Found\r\nLocation: /chain/{d}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{hops - 1});
                return w.flush();
            }
        } else if (std.mem.eql(u8, path, "/redirect") or std.mem.eql(u8, path, "/file")) {
            const location = if (std.mem.eql(u8, path, "/file")) "file:///etc/passwd" else "/image";
            try w.print("HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{location});
            return w.flush();
        } else if (std.mem.eql(u8, path, "/404")) {
            try w.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return w.flush();
        } else if (std.mem.eql(u8, path, "/oversize")) {
            try w.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 9000000\r\nConnection: close\r\n\r\n");
            return w.flush();
        } else if (std.mem.eql(u8, path, "/empty")) {
            try w.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return w.flush();
        } else if (std.mem.eql(u8, path, "/invalid")) {
            try w.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nnot an image");
            return w.flush();
        } else if (std.mem.eql(u8, path, "/chunked")) {
            try w.writeAll("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
            const split = self.fixture.len / 2;
            for ([_][]const u8{ self.fixture[0..split], self.fixture[split..] }) |chunk| {
                try w.print("{x}\r\n", .{chunk.len});
                try w.writeAll(chunk);
                try w.writeAll("\r\n");
            }
            try w.writeAll("0\r\n\r\n");
            return w.flush();
        } else if (std.mem.eql(u8, path, "/gated") or std.mem.eql(u8, path, "/stall")) {
            try w.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 716800\r\nConnection: close\r\n\r\n");
            try w.writeAll(self.fixture);
            const padding: [8192]u8 = @splat(0);
            var sent = self.fixture.len;
            const partial = if (std.mem.eql(u8, path, "/stall")) self.fixture.len else 614400;
            while (sent < partial) {
                const count = @min(padding.len, partial - sent);
                try w.writeAll(padding[0..count]);
                sent += count;
            }
            try w.flush();
            self.entered.set(io);
            try self.release.wait(io);
            while (sent < 716800) {
                const count = @min(padding.len, 716800 - sent);
                try w.writeAll(padding[0..count]);
                sent += count;
            }
            return w.flush();
        }
        try w.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{fixture.len});
        try w.writeAll(if (std.mem.eql(u8, path, "/truncated")) fixture[0 .. fixture.len / 2] else fixture);
        try w.flush();
    }
};

fn checkSource(service: *Service, origin: *Origin, path: []const u8, expected: std.http.Status) !void {
    const target = try targetFor(origin.port(), path, "&w=80&h=60&fit=fill");
    defer a.free(target);
    const reply = try call(service.port, target, .GET);
    defer reply.deinit();
    try std.testing.expectEqual(expected, reply.status);
    if (expected == .ok) try expectImage(reply, 80, 60, .jpeg);
}

fn checkHttpContracts() !void {
    const fixture = try Fixture.init(false);
    defer fixture.deinit();
    var origin: Origin = .{ .server = try listener(), .fixture = fixture.bytes };
    defer origin.deinit();
    try origin.start();
    var service = try Service.start(false, 1000000);
    defer service.deinit();
    for ([_][]const u8{ "/image", "/redirect", "/chunked", "/chain/5" }) |path| try checkSource(&service, &origin, path, .ok);
    for ([_][]const u8{ "/404", "/empty", "/oversize", "/truncated", "/file", "/chain/6" }) |path| try checkSource(&service, &origin, path, .bad_gateway);
    try checkSource(&service, &origin, "/invalid", .bad_request);
    const cases = [_]struct { target: []const u8, method: std.http.Method, status: std.http.Status }{
        .{ .target = "/resize", .method = .GET, .status = .bad_request },
        .{ .target = "/health", .method = .POST, .status = .method_not_allowed },
        .{ .target = "/resize?url=file%3A%2F%2F%2Fetc%2Fpasswd", .method = .GET, .status = .bad_request },
        .{ .target = "/resize?url=not-a-url", .method = .GET, .status = .bad_request },
    };
    for (cases) |row| {
        const reply = try call(service.port, row.target, row.method);
        defer reply.deinit();
        try std.testing.expectEqual(row.status, reply.status);
    }
    try checkSource(&service, &origin, "/uppercase", .ok);
    const uppercase = try std.fmt.allocPrint(a, "/resize?url=HTTP%3A%2F%2F127.0.0.1%3A{d}/image&w=80&h=60&fit=fill", .{origin.port()});
    defer a.free(uppercase);
    const uppercase_reply = try call(service.port, uppercase, .GET);
    defer uppercase_reply.deinit();
    try expectImage(uppercase_reply, 80, 60, .jpeg);
    try checkSource(&service, &origin, "/reuse", .ok);
    try checkSource(&service, &origin, "/reuse", .ok);
    try std.testing.expectEqual(@as(usize, 1), origin.reused.load(.monotonic));
    const png_target = try targetFor(origin.port(), "/image", "&w=71&h=53&fit=fill&format=png");
    defer a.free(png_target);
    const png = try call(service.port, png_target, .GET);
    defer png.deinit();
    try expectImage(png, 71, 53, .png);
    for ([_]@import("resize.zig").Format{ .webp, .avif }) |format| {
        const options = try std.fmt.allocPrint(a, "&w=71&h=53&fit=fill&format={s}", .{@tagName(format)});
        defer a.free(options);
        const target = try targetFor(origin.port(), "/image", options);
        defer a.free(target);
        const reply = try call(service.port, target, .GET);
        defer reply.deinit();
        try expectImage(reply, 71, 53, format);
    }
    const fits = [_]struct { options: []const u8, width: c_int, height: c_int }{
        .{ .options = "&w=81&h=43&fit=cover&format=png", .width = 81, .height = 43 },
        .{ .options = "&w=128&h=64&fit=contain&format=png", .width = 85, .height = 64 },
        .{ .options = "&w=64&h=128&fit=inside&format=png", .width = 64, .height = 48 },
    };
    for (fits) |fit| {
        const target = try targetFor(origin.port(), "/image", fit.options);
        defer a.free(target);
        const reply = try call(service.port, target, .GET);
        defer reply.deinit();
        try expectImage(reply, fit.width, fit.height, .png);
    }
    try service.stop();
    var bounded_pixels = try Service.start(false, 1000);
    defer bounded_pixels.deinit();
    try checkSource(&bounded_pixels, &origin, "/image", .bad_request);
    const source_pixel_target = try targetFor(origin.port(), "/image", "&w=10&h=10&fit=fill");
    defer a.free(source_pixel_target);
    const source_pixel_reply = try call(bounded_pixels.port, source_pixel_target, .GET);
    defer source_pixel_reply.deinit();
    try std.testing.expectEqual(.bad_request, source_pixel_reply.status);
    try bounded_pixels.stop();
}

fn singleAxisFixture(width: c_int, height: c_int, orientation: c_int) !Fixture {
    var image: ?*vips.Image = null;
    try std.testing.expectEqual(@as(c_int, 0), vips.vips_black(&image, width, height, "bands", @as(c_int, 3), null_arg));
    defer vips.g_object_unref(image.?);
    vips.vips_image_set_int(image.?, "orientation", orientation);
    var data: ?*anyopaque = null;
    var size: usize = 0;
    errdefer vips.g_free(data);
    try std.testing.expectEqual(@as(c_int, 0), vips.vips_jpegsave_buffer(image.?, &data, &size, null_arg));
    return .{ .bytes = @as([*]u8, @ptrCast(data.?))[0..size] };
}

fn checkSingleAxisResizes() !void {
    var cache = try CacheConfig.init("1MiB", "30");
    defer cache.deinit();
    var service = try Service.startWithCache(false, 1000000, &cache);
    defer service.deinit();
    const sources = [_]struct { width: c_int, height: c_int, orientation: c_int = 1 }{
        .{ .width = 160, .height = 240 },
        .{ .width = 240, .height = 160 },
        .{ .width = 240, .height = 160, .orientation = 6 },
        .{ .width = 160, .height = 240, .orientation = 8 },
    };
    for (sources) |source| {
        const fixture = try singleAxisFixture(source.width, source.height, source.orientation);
        defer fixture.deinit();
        // Confirm the fixture actually retained orientation through its encoder.
        const decoded = vips.vips_image_new_from_buffer(fixture.bytes.ptr, fixture.bytes.len, "", null_arg) orelse return error.InvalidFixture;
        defer vips.g_object_unref(decoded);
        try std.testing.expectEqual(source.orientation, vips.vips_image_get_orientation(decoded));
        var origin: Origin = .{ .server = try listener(), .fixture = fixture.bytes };
        defer origin.deinit();
        try origin.start();
        const rotated = source.orientation >= 5 and source.orientation <= 8;
        const width = if (rotated) source.height else source.width;
        const height = if (rotated) source.width else source.height;
        const cases = [_]struct { options: []const u8, width: c_int, height: c_int }{
            .{ .options = "&w=80&h=0&fit=inside&format=png", .width = 80, .height = if (width == 160) 120 else 53 },
            .{ .options = "&w=0&h=60&fit=inside&format=png", .width = if (height == 240) 40 else 90, .height = 60 },
            .{ .options = "&w=800&h=0&fit=inside&format=png", .width = width, .height = height },
            .{ .options = "&w=0&h=600&fit=inside&format=png", .width = width, .height = height },
            .{ .options = "&w=80&fit=cover&format=png", .width = 80, .height = 80 },
            .{ .options = "&w=80&h=0&fit=cover&format=png", .width = 80, .height = if (width == 160) 120 else 53 },
            .{ .options = "&w=80&h=0&fit=fill&format=png", .width = 80, .height = if (width == 160) 120 else 53 },
        };
        for (cases) |row| {
            const target = try targetFor(origin.port(), "/image", row.options);
            defer a.free(target);
            const reply = try call(service.port, target, .GET);
            defer reply.deinit();
            try expectImage(reply, row.width, row.height, .png);
        }
        const before = origin.fetched.load(.acquire);
        const invalid_target = try targetFor(origin.port(), "/image", "&w=0&h=0");
        defer a.free(invalid_target);
        const invalid = try call(service.port, invalid_target, .GET);
        defer invalid.deinit();
        try std.testing.expectEqual(.bad_request, invalid.status);
        try std.testing.expectEqual(before, origin.fetched.load(.acquire));
        const limited_target = try targetFor(origin.port(), "/image", "&w=8192&h=0&fit=inside");
        defer a.free(limited_target);
        const limited = try call(service.port, limited_target, .GET);
        defer limited.deinit();
        try std.testing.expectEqual(.bad_request, limited.status);
    }
    try service.stop();
}

const ClientJob = struct {
    port: u16,
    target: []const u8,
    reply: ?Reply = null,
    failure: ?anyerror = null,
    start: ?*Io.Event = null,
    rejected: ?*Io.Event = null,
    response_entered: ?*Io.Event = null,
    response_release: ?*Io.Event = null,
    fn run(self: *ClientJob) Io.Cancelable!void {
        if (self.start) |gate| try gate.wait(io);
        exchangeWithPause(self.port, self.target, .GET, &self.reply, self.response_entered, self.response_release) catch |err| {
            self.failure = err;
            if (err == error.Canceled) return error.Canceled;
            if (self.rejected) |event| event.set(io);
            return;
        };
        if (self.reply.?.status == .service_unavailable) if (self.rejected) |event| event.set(io);
    }
    fn deinit(self: *ClientJob) void {
        if (self.reply) |reply| reply.deinit();
    }
};

fn awaitGroup(group: *Io.Group) !void {
    try group.await(io);
}
fn awaitEvent(event: *Io.Event) !void {
    try event.wait(io);
}

fn checkConcurrentResizes() !void {
    const fixture = try Fixture.init(false);
    defer fixture.deinit();
    var origin: Origin = .{ .server = try listener(), .fixture = fixture.bytes };
    defer origin.deinit();
    try origin.start();
    var service = try Service.start(false, 1000000);
    defer service.deinit();
    const target = try targetFor(origin.port(), "/chunked", "&w=93&h=67&fit=fill&format=png");
    defer a.free(target);
    var gate: Io.Event = .unset;
    var jobs: [100]ClientJob = undefined;
    for (&jobs) |*job| job.* = .{ .port = service.port, .target = target, .start = &gate };
    defer for (&jobs) |*job| job.deinit();
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (&jobs) |*job| try group.concurrent(io, ClientJob.run, .{job});
    gate.set(io);
    try bounded(awaitGroup, .{&group}, 35);
    for (&jobs) |*job| {
        if (job.failure) |failure| return failure;
        try expectImage(job.reply.?, 93, 67, .png);
    }
    try service.stop();
}

fn cacheRequest(service: *Service, origin: *Origin, path: []const u8, options: []const u8, width: c_int, height: c_int, format: @import("resize.zig").Format, fetched: usize) !void {
    const target = try targetFor(origin.port(), path, options);
    defer a.free(target);
    const reply = try call(service.port, target, .GET);
    defer reply.deinit();
    try expectImage(reply, width, height, format);
    try std.testing.expectEqual(fetched, origin.fetched.load(.acquire));
}

fn checkResponseCache() !void {
    const fixture = try Fixture.init(false);
    defer fixture.deinit();
    const alternate = try Fixture.init(true);
    defer alternate.deinit();
    var origin: Origin = .{
        .server = try listener(),
        .fixture = fixture.bytes,
        .alternate_fixture = alternate.bytes,
    };
    defer origin.deinit();
    try origin.start();
    var cache = try CacheConfig.init("1MiB", "1");
    defer cache.deinit();
    var service = try Service.startWithCache(false, 2000000, &cache);
    defer service.deinit();

    // Omitted defaults, option order, case, and the format alias normalize to
    // the same full Options value, rather than distinct raw query strings.
    try cacheRequest(&service, &origin, "/cached", "&w=80", 80, 80, .jpeg, 1);
    try cacheRequest(&service, &origin, "/cached", "&q=80&f=JPG&fit=COVER&h=80&w=80", 80, 80, .jpeg, 1);
    const distinct = [_]struct {
        path: []const u8 = "/cached",
        options: []const u8,
        width: c_int = 80,
        height: c_int = 80,
        format: @import("resize.zig").Format = .jpeg,
    }{
        .{ .options = "&w=81&h=80", .width = 81 },
        .{ .options = "&w=80&h=81", .height = 81 },
        .{ .options = "&w=80&fit=fill" },
        .{ .options = "&w=80&format=png", .format = .png },
        .{ .options = "&w=80&q=81" },
        .{ .path = "/other-source", .options = "&w=80" },
    };
    for (distinct, 0..) |row, index| {
        try cacheRequest(&service, &origin, row.path, row.options, row.width, row.height, row.format, index + 2);
    }

    const target = try targetFor(origin.port(), "/concurrent-cache", "&w=93&h=67&fit=fill&format=png");
    defer a.free(target);
    var gate: Io.Event = .unset;
    var jobs: [16]ClientJob = undefined;
    for (&jobs) |*job| job.* = .{ .port = service.port, .target = target, .start = &gate };
    defer for (&jobs) |*job| job.deinit();
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (&jobs) |*job| try group.concurrent(io, ClientJob.run, .{job});
    const warmed = try call(service.port, target, .GET);
    defer warmed.deinit();
    try expectImage(warmed, 93, 67, .png);
    const warmed_count = origin.fetched.load(.acquire);
    gate.set(io);
    try bounded(awaitGroup, .{&group}, 10);
    for (&jobs) |*job| {
        if (job.failure) |failure| return failure;
        try expectImage(job.reply.?, 93, 67, .png);
        try std.testing.expectEqualSlices(u8, warmed.bytes, job.reply.?.bytes);
    }
    try std.testing.expectEqual(warmed_count, origin.fetched.load(.acquire));

    // Change the actual source after insertion. A hit must retain the original
    // image, but absolute expiry must fetch and decode the new square source.
    const before_expiry = origin.fetched.load(.acquire);
    try cacheRequest(&service, &origin, "/mutable", "&w=80&h=60&fit=contain&format=png", 80, 60, .png, before_expiry + 1);
    origin.use_alternate.store(true, .release);
    try Io.sleep(io, .fromMilliseconds(600), .awake);
    const hit_began = Io.Clock.awake.now(io);
    try cacheRequest(&service, &origin, "/mutable", "&w=80&h=60&fit=contain&format=png", 80, 60, .png, before_expiry + 1);
    // Only 500ms since the hit: a sliding TTL would wrongly serve 80x60 here.
    try Io.sleep(io, .fromMilliseconds(500), .awake);
    // Fail rather than let a scheduling delay turn this into a false-positive
    // sliding-TTL test. The probe begins within the hit's fresh TTL window.
    try std.testing.expectEqual(@as(i64, 0), hit_began.durationTo(Io.Clock.awake.now(io)).toSeconds());
    try cacheRequest(&service, &origin, "/mutable", "&w=80&h=60&fit=contain&format=png", 60, 60, .png, before_expiry + 2);
    try cacheRequest(&service, &origin, "/mutable", "&w=80&h=60&fit=contain&format=png", 60, 60, .png, before_expiry + 2);
    // Shutdown with populated entries and a periodic cleaner still active.
    try service.stop();
}

fn checkCacheOversizeBypass() !void {
    const fixture = try Fixture.init(true);
    defer fixture.deinit();
    var origin: Origin = .{ .server = try listener(), .fixture = fixture.bytes };
    defer origin.deinit();
    try origin.start();
    var cache = try CacheConfig.init("1MiB", "30");
    defer cache.deinit();
    var service = try Service.startWithCache(false, 2000000, &cache);
    defer service.deinit();
    const target = try targetFor(origin.port(), "/image", "&w=1024&h=1024&fit=fill&format=png");
    defer a.free(target);
    for (0..2) |index| {
        const reply = try call(service.port, target, .GET);
        defer reply.deinit();
        try expectImage(reply, 1024, 1024, .png);
        try std.testing.expect(reply.bytes.len > 1024 * 1024);
        try std.testing.expectEqual(index + 1, origin.fetched.load(.acquire));
    }
    // The bypass must not prevent smaller successful responses being cached.
    try cacheRequest(&service, &origin, "/small", "&w=80&h=60&fit=fill&format=png", 80, 60, .png, 3);
    try cacheRequest(&service, &origin, "/small", "&w=80&h=60&fit=fill&format=png", 80, 60, .png, 3);
    try service.stop();
}
fn checkCachePersistence() !void {
    const fixture = try Fixture.init(false);
    defer fixture.deinit();
    const alternate = try Fixture.init(true);
    defer alternate.deinit();
    var origin: Origin = .{
        .server = try listener(),
        .fixture = fixture.bytes,
        .alternate_fixture = alternate.bytes,
    };
    defer origin.deinit();
    try origin.start();
    var cache = try CacheConfig.init("1MiB", "5");
    defer cache.deinit();
    var service = try Service.startWithCache(false, 2000000, &cache);
    defer service.deinit();
    const target = try targetFor(origin.port(), "/mutable", "&w=80&h=60&fit=contain&format=png");
    defer a.free(target);
    const inserted = try call(service.port, target, .GET);
    defer inserted.deinit();
    try expectImage(inserted, 80, 60, .png);
    try std.testing.expectEqual(@as(usize, 1), origin.fetched.load(.acquire));
    try Io.sleep(io, .fromMilliseconds(2000), .awake);
    try service.stop();

    // A fresh process cannot reconstruct the image from the blocked origin.
    // The directory belongs to this scenario, not either process lifetime.
    origin.unavailable.store(true, .release);
    origin.use_alternate.store(true, .release);
    service = try Service.startWithCache(false, 2000000, &cache);
    const restart_began = Io.Clock.awake.now(io);
    const restarted = try call(service.port, target, .GET);
    defer restarted.deinit();
    try expectImage(restarted, 80, 60, .png);
    try std.testing.expectEqualSlices(u8, inserted.bytes, restarted.bytes);
    try std.testing.expectEqual(@as(usize, 1), origin.fetched.load(.acquire));

    // Cross the original insertion TTL but stay inside a wrongly reset TTL.
    // A restarted cache must not serve expired data, even on origin failure.
    try Io.sleep(io, .fromMilliseconds(3200), .awake);
    try std.testing.expect(restart_began.durationTo(Io.Clock.awake.now(io)).toSeconds() < 5);
    const expired = try call(service.port, target, .GET);
    defer expired.deinit();
    try std.testing.expectEqual(.bad_gateway, expired.status);
    try std.testing.expectEqual(@as(usize, 2), origin.fetched.load(.acquire));
    origin.unavailable.store(false, .release);
    try cacheRequest(&service, &origin, "/mutable", "&w=80&h=60&fit=contain&format=png", 60, 60, .png, 3);
    try cacheRequest(&service, &origin, "/mutable", "&w=80&h=60&fit=contain&format=png", 60, 60, .png, 3);
    try service.stop();
}

fn checkCacheEvictionConcurrency() !void {
    const fixture = try Fixture.init(true);
    defer fixture.deinit();
    var origin: Origin = .{ .server = try listener(), .fixture = fixture.bytes };
    defer origin.deinit();
    try origin.start();
    var cache = try CacheConfig.init("4MiB", "30");
    defer cache.deinit();
    var service = try Service.startWithCache(false, 2000000, &cache);
    defer service.deinit();
    const target = try targetFor(origin.port(), "/evicted", "&w=1024&h=1024&fit=fill&format=png");
    defer a.free(target);
    const replacement_target = try targetFor(origin.port(), "/replacement", "&w=1024&h=1024&fit=fill&format=png");
    defer a.free(replacement_target);
    const warmed = try call(service.port, target, .GET);
    defer warmed.deinit();
    try expectImage(warmed, 1024, 1024, .png);
    try std.testing.expect(warmed.bytes.len < 4 * 1024 * 1024 - 32);
    // Derive a one-file capacity from the actual encoded output, so this is
    // independent of codec compression changes while still forcing eviction.
    try service.stop();
    var size_buffer: [32]u8 = undefined;
    cache.max_size = try std.fmt.bufPrint(&size_buffer, "{d}", .{warmed.bytes.len + warmed.bytes.len / 2 + 32});
    service = try Service.startWithCache(false, 2000000, &cache);
    var gate: Io.Event = .unset;
    var jobs: [16]ClientJob = undefined;
    for (&jobs) |*job| job.* = .{ .port = service.port, .target = target, .start = &gate };
    var response_entered: Io.Event = .unset;
    var response_release: Io.Event = .unset;
    jobs[0].response_entered = &response_entered;
    jobs[0].response_release = &response_release;
    defer for (&jobs) |*job| job.deinit();
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (&jobs) |*job| try group.concurrent(io, ClientJob.run, .{job});
    gate.set(io);
    try bounded(awaitEvent, .{&response_entered}, 10);
    const competing = try call(service.port, replacement_target, .GET);
    defer competing.deinit();
    try expectImage(competing, 1024, 1024, .png);
    response_release.set(io);
    try bounded(awaitGroup, .{&group}, 35);
    for (&jobs) |*job| {
        if (job.failure) |failure| return failure;
        try expectImage(job.reply.?, 1024, 1024, .png);
        try std.testing.expectEqualSlices(u8, warmed.bytes, job.reply.?.bytes);
    }
    // Leases may cause admission bypass; after readers finish, replacement
    // insertion must evict the old entry and the next replacement must hit.
    const replacement = try call(service.port, replacement_target, .GET);
    defer replacement.deinit();
    try expectImage(replacement, 1024, 1024, .png);
    const settled_count = origin.fetched.load(.acquire);
    try cacheRequest(&service, &origin, "/replacement", "&w=1024&h=1024&fit=fill&format=png", 1024, 1024, .png, settled_count);
    try cacheRequest(&service, &origin, "/evicted", "&w=1024&h=1024&fit=fill&format=png", 1024, 1024, .png, settled_count + 1);
    try service.stop();
}

fn checkCacheCleanupStreaming() !void {
    const fixture = try Fixture.init(true);
    defer fixture.deinit();
    var origin: Origin = .{ .server = try listener(), .fixture = fixture.bytes };
    defer origin.deinit();
    try origin.start();
    var cache = try CacheConfig.init("4MiB", "1");
    defer cache.deinit();
    var service = try Service.startWithCache(false, 2000000, &cache);
    defer service.deinit();
    const target = try targetFor(origin.port(), "/cleanup", "&w=1024&h=1024&fit=fill&format=png");
    defer a.free(target);
    const warmed = try call(service.port, target, .GET);
    defer warmed.deinit();
    try expectImage(warmed, 1024, 1024, .png);
    var entered: Io.Event = .unset;
    var release: Io.Event = .unset;
    var job: ClientJob = .{
        .port = service.port,
        .target = target,
        .response_entered = &entered,
        .response_release = &release,
    };
    defer job.deinit();
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, ClientJob.run, .{&job});
    try bounded(awaitEvent, .{&entered}, 10);
    try std.testing.expectEqual(@as(usize, 1), origin.fetched.load(.acquire));
    // Keep the response reader paused through expiry and periodic cleanup.
    try Io.sleep(io, .fromMilliseconds(2200), .awake);
    const fresh = try call(service.port, target, .GET);
    defer fresh.deinit();
    try expectImage(fresh, 1024, 1024, .png);
    try std.testing.expectEqual(@as(usize, 2), origin.fetched.load(.acquire));
    release.set(io);
    try bounded(awaitGroup, .{&group}, 10);
    if (job.failure) |failure| return failure;
    try expectImage(job.reply.?, 1024, 1024, .png);
    try std.testing.expectEqualSlices(u8, warmed.bytes, job.reply.?.bytes);
    try service.stop();
}

fn checkSourceBudget() !void {
    const fixture = try Fixture.init(false);
    defer fixture.deinit();
    var origin: Origin = .{ .server = try listener(), .fixture = fixture.bytes };
    defer origin.deinit();
    try origin.start();
    var service = try Service.start(true, 2000000);
    defer service.deinit();
    try checkSource(&service, &origin, "/oversize", .bad_gateway);
    const target = try targetFor(origin.port(), "/gated", "&w=80&h=60&fit=fill");
    defer a.free(target);
    var rejected: Io.Event = .unset;
    var jobs = [_]ClientJob{
        .{ .port = service.port, .target = target, .rejected = &rejected },
        .{ .port = service.port, .target = target, .rejected = &rejected },
    };
    defer for (&jobs) |*job| job.deinit();
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (&jobs) |*job| try group.concurrent(io, ClientJob.run, .{job});
    try bounded(awaitEvent, .{&rejected}, 10);
    origin.release.set(io);
    try bounded(awaitGroup, .{&group}, 10);
    var successes: usize = 0;
    var failures: usize = 0;
    for (&jobs) |*job| {
        if (job.failure) |failure| return failure;
        switch (job.reply.?.status) {
            .ok => {
                try expectImage(job.reply.?, 80, 60, .jpeg);
                successes += 1;
            },
            .service_unavailable => failures += 1,
            else => return error.UnexpectedBudgetResponse,
        }
    }
    try std.testing.expect(failures >= 1);
    try std.testing.expectEqual(@as(usize, 2), successes + failures);
    try checkSource(&service, &origin, "/image", .ok);
    try service.stop();
}

fn checkResponseBudget() !void {
    const fixture = try Fixture.init(true);
    defer fixture.deinit();
    try std.testing.expect(fixture.bytes.len < 1024 * 1024);
    var origin: Origin = .{ .server = try listener(), .fixture = fixture.bytes };
    defer origin.deinit();
    try origin.start();
    var service = try Service.start(true, 2000000);
    defer service.deinit();
    const target = try targetFor(origin.port(), "/image", "&w=1024&h=1024&fit=fill&format=png");
    defer a.free(target);
    const reply = try call(service.port, target, .GET);
    defer reply.deinit();
    try std.testing.expectEqual(.service_unavailable, reply.status);
    try checkSource(&service, &origin, "/image", .ok);
    try service.stop();
}

fn checkDeadlinesAndShutdown() !void {
    const fixture = try Fixture.init(false);
    defer fixture.deinit();
    var origin: Origin = .{ .server = try listener(), .fixture = fixture.bytes };
    defer origin.deinit();
    try origin.start();
    var service = try Service.start(true, 2000000);
    defer service.deinit();
    const began = Io.Clock.awake.now(io);
    try checkSource(&service, &origin, "/stall", .bad_gateway);
    const elapsed = began.durationTo(Io.Clock.awake.now(io)).toSeconds();
    try std.testing.expect(elapsed >= 19 and elapsed <= 27);
    try checkSource(&service, &origin, "/image", .ok);
    origin.entered = .unset;
    const target = try targetFor(origin.port(), "/stall", "&w=80&h=60");
    defer a.free(target);
    var job: ClientJob = .{ .port = service.port, .target = target };
    defer job.deinit();
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, ClientJob.run, .{&job});
    try bounded(awaitEvent, .{&origin.entered}, 5);
    try service.stop();
    try bounded(awaitGroup, .{&group}, 5);
    try std.testing.expect(job.failure != null or job.reply.?.status != .ok);
}

fn recoverAfterAbort(port: u16, target: []const u8) !void {
    while (true) {
        var reply: ?Reply = null;
        try exchange(port, target, .GET, &reply);
        defer reply.?.deinit();
        if (reply.?.status == .service_unavailable) {
            try Io.sleep(io, .fromMilliseconds(20), .awake);
            continue;
        }
        try expectImage(reply.?, 80, 60, .jpeg);
        return;
    }
}

fn checkAbortRecovery() !void {
    const fixture = try Fixture.init(false);
    defer fixture.deinit();
    var origin: Origin = .{ .server = try listener(), .fixture = fixture.bytes };
    defer origin.deinit();
    try origin.start();
    var service = try Service.start(true, 2000000);
    defer service.deinit();
    const target = try targetFor(origin.port(), "/gated", "&w=80&h=60&fit=fill");
    defer a.free(target);
    var job: ClientJob = .{ .port = service.port, .target = target };
    defer job.deinit();
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, ClientJob.run, .{&job});
    try bounded(awaitEvent, .{&origin.entered}, 5);
    group.cancel(io);
    origin.release.set(io);
    const recovery_target = try targetFor(origin.port(), "/image", "&w=80&h=60&fit=fill");
    defer a.free(recovery_target);
    try bounded(recoverAfterAbort, .{ service.port, recovery_target }, 10);
    try service.stop();
}

test "native service codecs, HTTP contracts, response cache, resource limits, 100 clients, deadlines and shutdown" {
    // libvips cannot be restarted after shutdown within the same process.
    // Each scenario owns its fixtures/origin/child; the engine owns the suite lifetime.
    try std.testing.expectEqual(@as(c_int, 0), vips.vips_init("zig-integration"));
    defer vips.vips_shutdown();
    vips.vips_concurrency_set(1);
    vips.vips_cache_set_max(0);
    try checkHttpContracts();
    try checkSingleAxisResizes();
    try checkConcurrentResizes();
    try checkResponseCache();
    try checkCacheOversizeBypass();
    try checkCachePersistence();
    try checkCacheEvictionConcurrency();
    try checkCacheCleanupStreaming();
    try checkSourceBudget();
    try checkResponseBudget();
    try checkDeadlinesAndShutdown();
    try checkAbortRecovery();
}
