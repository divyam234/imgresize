const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const max_body = 64 * 1024 * 1024;

const Config = struct {
    source: []const u8,
    base: []const u8 = "http://127.0.0.1:8080",
    concurrency: std.ArrayList(usize) = .empty,
    rounds: usize = 1,
    pid: ?u32 = null,

    fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !Config {
        var config: Config = .{ .source = "" };
        errdefer config.concurrency.deinit(allocator);
        var positional: usize = 0;
        var i: usize = 1;
        while (i < args.len) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--concurrency")) {
                i += 1;
                const start = i;
                while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
                    try config.concurrency.append(allocator, try positive(args[i], 4096));
                }
                if (i == start) return error.MissingConcurrency;
            } else if (std.mem.eql(u8, arg, "--rounds") or std.mem.eql(u8, arg, "--pid")) {
                i += 1;
                if (i == args.len) return error.MissingOptionValue;
                if (std.mem.eql(u8, arg, "--rounds")) {
                    config.rounds = try positive(args[i], 100000);
                } else {
                    if (builtin.os.tag != .linux) return error.PidSamplingRequiresLinux;
                    config.pid = @intCast(try positive(args[i], std.math.maxInt(i32)));
                }
                i += 1;
            } else {
                if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;
                switch (positional) {
                    0 => config.source = arg,
                    1 => config.base = arg,
                    else => return error.TooManyArguments,
                }
                positional += 1;
                i += 1;
            }
        }
        if (positional == 0) return error.MissingSourceUrl;
        _ = try checkedUri(config.source, false);
        const base = try checkedUri(config.base, true);
        if (base.query != null or base.fragment != null) return error.InvalidBaseUrl;
        if (config.concurrency.items.len == 0) try config.concurrency.appendSlice(allocator, &.{ 1, 16, 100 });
        return config;
    }
};

fn positive(text: []const u8, maximum: usize) !usize {
    const value = std.fmt.parseInt(usize, text, 10) catch return error.InvalidPositiveInteger;
    if (value == 0 or value > maximum) return error.InvalidPositiveInteger;
    return value;
}

fn checkedUri(text: []const u8, base: bool) !std.Uri {
    if (text.len == 0 or text.len > 8192) return error.InvalidUrl;
    for (text) |byte| if (byte <= 0x20 or byte == 0x7f) return error.InvalidUrl;
    const uri = std.Uri.parse(text) catch return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        (base or !std.ascii.eqlIgnoreCase(uri.scheme, "https"))) return error.InvalidUrl;
    if (uri.host == null or uri.user != null or uri.password != null) return error.InvalidUrl;
    return uri;
}

fn targetUrl(allocator: std.mem.Allocator, config: Config) ![]u8 {
    const base = std.mem.trimEnd(u8, config.base, "/");
    const prefix = "/resize?url=";
    const suffix = "&w=300&h=200&format=webp&q=80";
    var encoded_len: usize = 0;
    for (config.source) |byte| encoded_len += if (unreserved(byte)) @as(usize, 1) else 3;
    const target = try allocator.alloc(u8, base.len + prefix.len + encoded_len + suffix.len);
    @memcpy(target[0..base.len], base);
    @memcpy(target[base.len..][0..prefix.len], prefix);
    var cursor = base.len + prefix.len;
    const hex = "0123456789ABCDEF";
    for (config.source) |byte| {
        if (unreserved(byte)) {
            target[cursor] = byte;
            cursor += 1;
        } else {
            target[cursor] = '%';
            target[cursor + 1] = hex[byte >> 4];
            target[cursor + 2] = hex[byte & 15];
            cursor += 3;
        }
    }
    @memcpy(target[cursor..], suffix);
    return target;
}

fn unreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
}

const Result = struct {
    latency_seconds: f64 = 180,
    success: bool = false,
    output_bytes: usize = 0,
    error_name: ?[]const u8 = "RoundTimeout",
};

const Resources = struct {
    ticks: u64,
    rss: u64,
    threads: u64,
    starttime: u64,
};

const Monitor = struct {
    path: []const u8,
    initial: Resources,
    final: Resources,
    peak_rss: u64,
    peak_threads: u64,
    ticks_per_second: usize,

    fn sample(self: *Monitor, io: Io) !void {
        const current = try readResources(io, self.path);
        if (current.starttime != self.initial.starttime) return error.ServerPidReused;
        if (current.ticks < self.initial.ticks) return error.InvalidServerCpuCounter;
        self.final = current;
        self.peak_rss = @max(self.peak_rss, current.rss);
        self.peak_threads = @max(self.peak_threads, current.threads);
    }
};

fn readResources(io: Io, path: []const u8) !Resources {
    var buffer: [4096]u8 = undefined;
    const bytes = Io.Dir.cwd().readFile(io, path, &buffer) catch |err| {
        if (err != error.Canceled) std.log.err("cannot sample server {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
    if (bytes.len == buffer.len) return error.ProcStatTooLarge;
    const close = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return error.InvalidProcStat;
    var fields = std.mem.tokenizeAny(u8, bytes[close + 1 ..], " \t\n");
    var index: usize = 0;
    var user: u64 = 0;
    var system: u64 = 0;
    var threads: u64 = 0;
    var starttime: u64 = 0;
    var rss: u64 = 0;
    while (fields.next()) |field| : (index += 1) {
        switch (index) {
            11 => user = try std.fmt.parseInt(u64, field, 10),
            12 => system = try std.fmt.parseInt(u64, field, 10),
            17 => threads = try std.fmt.parseInt(u64, field, 10),
            19 => starttime = try std.fmt.parseInt(u64, field, 10),
            21 => {
                const pages = try std.fmt.parseInt(i64, field, 10);
                if (pages < 0) return error.InvalidProcStat;
                rss = try std.math.mul(u64, @intCast(pages), std.heap.pageSize());
                break;
            },
            else => {},
        }
    }
    if (index != 21 or threads == 0) return error.InvalidProcStat;
    return .{ .ticks = try std.math.add(u64, user, system), .rss = rss, .threads = threads, .starttime = starttime };
}

const Round = struct {
    io: Io,
    client: *std.http.Client,
    uri: std.Uri,
    results: []Result,
    concurrency: usize,
    next: std.atomic.Value(usize) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),

    fn worker(self: *Round) Io.Cancelable!void {
        while (!self.stopping.load(.acquire)) {
            const index = self.next.fetchAdd(1, .monotonic);
            if (index >= self.results.len) return;
            const start = Io.Timestamp.now(self.io, .awake);
            const result = &self.results[index];
            self.performRequest(result) catch |err| {
                result.error_name = @errorName(err);
                result.latency_seconds = seconds(start.durationTo(Io.Timestamp.now(self.io, .awake)));
                if (err == error.Canceled) return error.Canceled;
                continue;
            };
            result.success = true;
            result.error_name = null;
            result.latency_seconds = seconds(start.durationTo(Io.Timestamp.now(self.io, .awake)));
        }
    }

    fn performRequest(self: *Round, result: *Result) !void {
        var request = try self.client.request(.GET, self.uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        });
        defer {
            if (request.connection) |connection| connection.closing = true;
            request.deinit();
        }
        request.reader.max_head_len = 8192;
        request.accept_encoding = @splat(false);
        request.accept_encoding[@intFromEnum(std.http.ContentEncoding.identity)] = true;
        try request.sendBodiless();
        var response = try request.receiveHead(&.{});
        if (response.head.status != .ok) return error.HttpStatusNot200;
        const length = response.head.content_length orelse return error.MissingContentLength;
        if (length > max_body) return error.ResponseTooLarge;
        const reader = response.reader(&.{});
        var framing: [12]u8 = undefined;
        var framing_len: usize = 0;
        var buffer: [8192]u8 = undefined;
        while (true) {
            const count = try reader.readSliceShort(&buffer);
            if (count == 0) break;
            if (count > max_body - result.output_bytes) return error.ResponseTooLarge;
            const copied = @min(count, framing.len - framing_len);
            @memcpy(framing[framing_len..][0..copied], buffer[0..copied]);
            framing_len += copied;
            result.output_bytes += count;
        }
        if (result.output_bytes != length) return error.ContentLengthMismatch;
        if (framing_len != 12 or !std.mem.eql(u8, framing[0..4], "RIFF") or
            !std.mem.eql(u8, framing[8..12], "WEBP")) return error.InvalidWebpFraming;
        const riff_size = std.mem.readInt(u32, framing[4..8], .little);
        if (@as(u64, riff_size) + 8 != result.output_bytes) return error.InvalidWebpLength;
    }

    fn run(self: *Round) !void {
        var workers: Io.Group = .init;
        defer workers.cancel(self.io);
        for (0..self.concurrency) |_| try workers.concurrent(self.io, Round.worker, .{self});
        try workers.await(self.io);
    }
};

const Completion = union(enum) { requests: anyerror!void, monitor: anyerror!void };

fn watch(io: Io, deadline: Io.Clock.Timestamp, monitor: ?*Monitor) !void {
    if (monitor == null) {
        try deadline.wait(io);
        return error.RoundTimeout;
    }
    while (true) {
        try monitor.?.sample(io);
        if (Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) return error.RoundTimeout;
        try Io.sleep(io, .fromMilliseconds(20), .awake);
    }
}

fn seconds(duration: Io.Duration) f64 {
    return @as(f64, @floatFromInt(duration.nanoseconds)) / std.time.ns_per_s;
}

fn runRound(init: std.process.Init, client: *std.http.Client, uri: std.Uri, concurrency: usize, number: usize, warmup: bool, pid: ?u32, output: *Io.Writer) !bool {
    const total = if (warmup) @as(usize, 1) else @max(20, concurrency);
    const results = try init.gpa.alloc(Result, total);
    defer init.gpa.free(results);
    @memset(results, .{});
    const latencies = try init.gpa.alloc(f64, total);
    defer init.gpa.free(latencies);
    var path_buffer: [64]u8 = undefined;
    var monitor: ?Monitor = null;
    if (pid) |server_pid| {
        const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/stat", .{server_pid});
        const initial = try readResources(init.io, path);
        const ticks = if (builtin.os.tag == .linux)
            (if (builtin.link_libc) std.c.getauxval(std.elf.AT_CLKTCK) else std.os.linux.getauxval(std.elf.AT_CLKTCK))
        else
            0;
        if (ticks == 0) return error.KernelClockTickCountUnavailable;
        monitor = .{ .path = path, .initial = initial, .final = initial, .peak_rss = initial.rss, .peak_threads = initial.threads, .ticks_per_second = ticks };
    }
    var round: Round = .{ .io = init.io, .client = client, .uri = uri, .results = results, .concurrency = concurrency };
    var completions: [2]Completion = undefined;
    var select = Io.Select(Completion).init(init.io, &completions);
    defer {
        round.stopping.store(true, .release);
        select.cancelDiscard();
    }
    const start = Io.Timestamp.now(init.io, .awake);
    const deadline: Io.Clock.Timestamp = .{ .clock = .awake, .raw = start.addDuration(.fromSeconds(180)) };
    try select.concurrent(.monitor, watch, .{ init.io, deadline, if (monitor) |*m| m else null });
    try select.concurrent(.requests, Round.run, .{&round});
    const completion = try select.await();
    round.stopping.store(true, .release);
    select.cancelDiscard();
    var round_error: ?[]const u8 = null;
    switch (completion) {
        .requests => |operation| try operation,
        .monitor => |operation| operation catch |err| {
            if (err != error.RoundTimeout) return err;
            round_error = @errorName(err);
        },
    }
    const elapsed = seconds(start.durationTo(Io.Timestamp.now(init.io, .awake)));
    if (monitor) |*m| try m.sample(init.io);
    var errors: usize = 0;
    var output_bytes: usize = 0;
    var first_error = round_error;
    for (results, latencies) |result, *latency| {
        latency.* = result.latency_seconds;
        output_bytes += result.output_bytes;
        if (!result.success) {
            errors += 1;
            if (first_error == null) first_error = result.error_name;
        }
    }
    std.mem.sort(f64, latencies, {}, std.sort.asc(f64));
    var json: std.json.Stringify = .{ .writer = output };
    try json.beginObject();
    try json.objectField("phase");
    try json.write(if (warmup) "warmup" else "round");
    try json.objectField("concurrency");
    try json.write(concurrency);
    try json.objectField("round");
    try json.write(number);
    try json.objectField("requests");
    try json.write(total);
    try json.objectField("seconds");
    try json.write(elapsed);
    try json.objectField("requests_per_second");
    try json.write(@as(f64, @floatFromInt(total)) / @max(elapsed, 0.000000001));
    try json.objectField("p50_seconds");
    try json.write(latencies[(total - 1) / 2]);
    try json.objectField("p95_seconds");
    try json.write(latencies[(total - 1) * 95 / 100]);
    try json.objectField("errors");
    try json.write(errors);
    try json.objectField("total_output_bytes");
    try json.write(output_bytes);
    try json.objectField("first_error");
    try json.write(first_error);
    if (monitor) |m| {
        try json.objectField("cpu_seconds");
        try json.write(@as(f64, @floatFromInt(m.final.ticks - m.initial.ticks)) / @as(f64, @floatFromInt(m.ticks_per_second)));
        try json.objectField("peak_rss_mb");
        try json.write(@as(f64, @floatFromInt(m.peak_rss)) / 1048576);
        try json.objectField("end_rss_mb");
        try json.write(@as(f64, @floatFromInt(m.final.rss)) / 1048576);
        try json.objectField("peak_threads");
        try json.write(m.peak_threads);
    }
    try json.endObject();
    try output.writeByte('\n');
    try output.flush();
    return errors != 0 or round_error != null;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var config = Config.parse(init.gpa, args) catch |err| {
        std.log.err("{s}; usage: imgresize-bench <source-http(s)-url> [base-http-url] [--concurrency N ...] [--rounds N] [--pid SERVER_PID]", .{@errorName(err)});
        return err;
    };
    defer config.concurrency.deinit(init.gpa);
    const target = try targetUrl(init.gpa, config);
    defer init.gpa.free(target);
    const uri = try std.Uri.parse(target);
    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();
    var stdout_buffer: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &stdout_buffer);
    var failed = false;
    failed = try runRound(init, &client, uri, 1, 0, true, config.pid, &stdout.interface);
    for (config.concurrency.items) |concurrency| {
        for (1..config.rounds + 1) |number| {
            failed = (try runRound(init, &client, uri, concurrency, number, false, config.pid, &stdout.interface)) or failed;
        }
    }
    if (failed) return error.BenchmarkRequestsFailed;
}
