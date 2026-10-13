const std = @import("std");
pub const vips = @import("vips.zig");

pub const Fit = enum { cover, contain, inside, outside, fill };
pub const Format = enum {
    jpeg,
    webp,
    png,
    avif,

    pub fn contentType(self: Format) []const u8 {
        return switch (self) {
            .jpeg => "image/jpeg",
            .webp => "image/webp",
            .png => "image/png",
            .avif => "image/avif",
        };
    }
};

pub const Options = struct {
    width: u32 = 300,
    height: u32 = 300,
    fit: Fit = .cover,
    format: Format = .jpeg,
    quality: u8 = 80,
};

/// Owns a libvips allocation, never a Zig allocator allocation.
pub const Encoded = struct {
    bytes: []u8,

    pub fn deinit(self: *Encoded) void {
        vips.g_free(self.bytes.ptr);
        self.* = undefined;
    }
};

fn guardPixels(width: u32, height: u32, maximum: usize) !void {
    if (width == 0 or height == 0) return error.VipsFailure;
    if (width > std.math.maxInt(c_int) or height > std.math.maxInt(c_int) or
        width > maximum / height) return error.PixelLimit;
}

fn guardImage(input: *vips.Image, maximum: usize) !void {
    const width = vips.vips_image_get_width(input);
    const height = vips.vips_image_get_height(input);
    if (width <= 0 or height <= 0) return error.VipsFailure;
    try guardPixels(@intCast(width), @intCast(height), maximum);
}

const Dimensions = struct { width: u32, height: u32 };

// Resolve only the unconstrained axis, using displayed (autorotated) dimensions.
// Ceiling keeps this bounding box from constraining the requested positive axis.
fn targetDimensions(options: Options, original: Dimensions, orientation: c_int, maximum: usize) !Dimensions {
    try guardPixels(original.width, original.height, maximum);
    if (options.width == 0 and options.height == 0) return error.InvalidDimensions;
    var target: Dimensions = .{ .width = options.width, .height = options.height };
    const displayed: Dimensions = if (orientation >= 5 and orientation <= 8)
        .{ .width = original.height, .height = original.width }
    else
        original;
    if (target.width == 0 or target.height == 0) {
        const numerator = if (target.width == 0)
            @as(u64, target.height) * displayed.width
        else
            @as(u64, target.width) * displayed.height;
        const denominator: u64 = if (target.width == 0) displayed.height else displayed.width;
        const resolved = (numerator + denominator - 1) / denominator;
        if (resolved > std.math.maxInt(c_int)) return error.PixelLimit;
        if (target.width == 0) target.width = @intCast(resolved) else target.height = @intCast(resolved);
    }
    try guardPixels(target.width, target.height, maximum);
    return target;
}

/// Borrows input through encoding. Operation caching must be disabled so graphs
/// cannot outlive the borrowed source buffer. All graph ownership stays here.
pub fn resize(input: []const u8, options: Options, max_pixels: usize) !Encoded {
    const end: ?*anyopaque = null;
    defer vips.vips_thread_shutdown();
    const single_axis = options.width == 0 or options.height == 0;
    if (!single_axis) try guardPixels(options.width, options.height, max_pixels);
    var target: Dimensions = undefined;
    {
        const source = vips.vips_image_new_from_buffer(input.ptr, input.len, "", "access", @intFromEnum(vips.Access.sequential), end) orelse return error.VipsFailure;
        defer vips.g_object_unref(source);
        const width = vips.vips_image_get_width(source);
        const height = vips.vips_image_get_height(source);
        if (width <= 0 or height <= 0) return error.VipsFailure;
        target = try targetDimensions(options, .{
            .width = @intCast(width),
            .height = @intCast(height),
        }, if (single_axis) vips.vips_image_get_orientation(source) else 1, max_pixels);
    }

    const crop: vips.Crop = if (options.fit == .cover and !single_axis) .centre else .none;
    const size: vips.Size = switch (options.fit) {
        .cover, .fill => .both,
        .contain, .inside => .down,
        .outside => .up,
    };
    var thumb: ?*vips.Image = null;
    defer if (thumb) |owned| vips.g_object_unref(owned);
    // Nonlinear thumbnails permit decoder shrink-on-load and autorotation.
    if (vips.vips_thumbnail_buffer(@constCast(input.ptr), input.len, &thumb, @intCast(target.width), "height", @as(c_int, @intCast(target.height)), "crop", @intFromEnum(crop), "size", @intFromEnum(size), "linear", @as(c_int, 0), "no_rotate", @as(c_int, 0), end) != 0)
        return error.VipsFailure;
    const thumbnail = thumb orelse return error.VipsFailure;
    try guardImage(thumbnail, max_pixels);

    var stretched: ?*vips.Image = null;
    defer if (stretched) |owned| vips.g_object_unref(owned);
    if (options.fit == .fill and !single_axis) {
        const sx = @as(f64, @floatFromInt(options.width)) / @as(f64, @floatFromInt(vips.vips_image_get_width(thumbnail)));
        const sy = @as(f64, @floatFromInt(options.height)) / @as(f64, @floatFromInt(vips.vips_image_get_height(thumbnail)));
        if (vips.vips_resize(thumbnail, &stretched, sx, "vscale", sy, "kernel", @intFromEnum(vips.Kernel.lanczos3), end) != 0)
            return error.VipsFailure;
        try guardImage(stretched orelse return error.VipsFailure, max_pixels);
    }
    const output = stretched orelse thumbnail;

    var buffer: ?*anyopaque = null;
    var length: usize = 0;
    errdefer vips.g_free(buffer);
    const result = switch (options.format) {
        .jpeg => vips.vips_jpegsave_buffer(output, &buffer, &length, "Q", @as(c_int, options.quality), "strip", @as(c_int, 1), "interlace", @as(c_int, 0), "optimize_coding", @as(c_int, 1), end),
        .webp => vips.vips_webpsave_buffer(output, &buffer, &length, "Q", @as(c_int, options.quality), "strip", @as(c_int, 1), "effort", @as(c_int, 4), end),
        .png => vips.vips_pngsave_buffer(output, &buffer, &length, "compression", @as(c_int, if (options.quality >= 90) 3 else if (options.quality <= 50) 9 else 6), "strip", @as(c_int, 1), "interlace", @as(c_int, 0), end),
        .avif => vips.vips_heifsave_buffer(output, &buffer, &length, "Q", @as(c_int, options.quality), "compression", @intFromEnum(vips.HeifCompression.av1), "strip", @as(c_int, 1), "effort", @as(c_int, 4), end),
    };
    if (result != 0) return error.VipsFailure;
    const bytes: [*]u8 = @ptrCast(buffer orelse return error.VipsFailure);
    return .{ .bytes = bytes[0..length] };
}

test "single-axis targets preserve displayed proportions and enforce limits" {
    try std.testing.expectEqual(Dimensions{ .width = 80, .height = 120 }, try targetDimensions(.{ .width = 80, .height = 0 }, .{ .width = 160, .height = 240 }, 1, 40000));
    try std.testing.expectEqual(Dimensions{ .width = 80, .height = 120 }, try targetDimensions(.{ .width = 80, .height = 0 }, .{ .width = 240, .height = 160 }, 6, 40000));
    try std.testing.expectEqual(Dimensions{ .width = 90, .height = 60 }, try targetDimensions(.{ .width = 0, .height = 60 }, .{ .width = 240, .height = 160 }, 1, 40000));
    try std.testing.expectEqual(Dimensions{ .width = 2, .height = 1 }, try targetDimensions(.{ .width = 0, .height = 1 }, .{ .width = 3, .height = 2 }, 1, 6));
    try std.testing.expectEqual(Dimensions{ .width = 1, .height = 1 }, try targetDimensions(.{ .width = 1, .height = 0 }, .{ .width = 100, .height = 1 }, 1, 100));
    try std.testing.expectEqual(Dimensions{ .width = 1, .height = 9000 }, try targetDimensions(.{ .width = 1, .height = 0 }, .{ .width = 1, .height = 9000 }, 1, 9000));
    try std.testing.expectError(error.InvalidDimensions, targetDimensions(.{ .width = 0, .height = 0 }, .{ .width = 3, .height = 2 }, 1, 6));
    try std.testing.expectError(error.PixelLimit, targetDimensions(.{ .width = 1, .height = 0 }, .{ .width = 3, .height = 2 }, 1, 5));
    try std.testing.expectError(error.PixelLimit, targetDimensions(.{ .width = 0, .height = 100 }, .{ .width = 3, .height = 2 }, 1, 100));
    try std.testing.expectError(error.PixelLimit, targetDimensions(.{ .width = std.math.maxInt(u32), .height = 0 }, .{ .width = 1, .height = 2 }, 1, 100));
    try std.testing.expectError(error.PixelLimit, targetDimensions(.{ .width = 0, .height = std.math.maxInt(u32) }, .{ .width = 2, .height = 1 }, 1, 100));
}
