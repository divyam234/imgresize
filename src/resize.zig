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

/// Borrows input through encoding. Operation caching must be disabled so graphs
/// cannot outlive the borrowed source buffer. All graph ownership stays here.
pub fn resize(input: []const u8, options: Options, max_pixels: usize) !Encoded {
    const end: ?*anyopaque = null;
    defer vips.vips_thread_shutdown();
    try guardPixels(options.width, options.height, max_pixels);
    {
        const source = vips.vips_image_new_from_buffer(input.ptr, input.len, "", "access", @intFromEnum(vips.Access.sequential), end) orelse return error.VipsFailure;
        defer vips.g_object_unref(source);
        try guardImage(source, max_pixels);
    }

    const crop: vips.Crop = if (options.fit == .cover) .centre else .none;
    const size: vips.Size = switch (options.fit) {
        .cover, .fill => .both,
        .contain, .inside => .down,
        .outside => .up,
    };
    var thumb: ?*vips.Image = null;
    defer if (thumb) |owned| vips.g_object_unref(owned);
    // Nonlinear thumbnails permit decoder shrink-on-load and autorotation.
    if (vips.vips_thumbnail_buffer(@constCast(input.ptr), input.len, &thumb, @intCast(options.width), "height", @as(c_int, @intCast(options.height)), "crop", @intFromEnum(crop), "size", @intFromEnum(size), "linear", @as(c_int, 0), "no_rotate", @as(c_int, 0), end) != 0)
        return error.VipsFailure;
    const thumbnail = thumb orelse return error.VipsFailure;
    try guardImage(thumbnail, max_pixels);

    var stretched: ?*vips.Image = null;
    defer if (stretched) |owned| vips.g_object_unref(owned);
    if (options.fit == .fill) {
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
