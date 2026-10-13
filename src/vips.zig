//! Stable libvips/GLib ABI used by the image engine. Opaque images and accessor
//! functions avoid depending on C struct layouts or translating unrelated headers.
pub const Image = opaque {};
pub const Access = enum(c_int) { random = 0, sequential = 1 };
pub const Crop = enum(c_int) { none = 0, centre = 1 };
pub const Size = enum(c_int) { both = 0, up = 1, down = 2 };
pub const Kernel = enum(c_int) { lanczos3 = 5 };
pub const HeifCompression = enum(c_int) { av1 = 4 };

pub extern fn vips_init(name: [*:0]const u8) c_int;
pub extern fn vips_shutdown() void;
pub extern fn vips_thread_shutdown() void;
pub extern fn vips_error_clear() void;
pub extern fn vips_cache_set_max(count: c_int) void;
pub extern fn vips_cache_set_max_mem(bytes: usize) void;
pub extern fn vips_concurrency_set(count: c_int) void;
pub extern fn vips_image_get_width(image: *const Image) c_int;
pub extern fn vips_image_get_height(image: *const Image) c_int;
pub extern fn vips_image_new_from_buffer(data: *const anyopaque, len: usize, options: [*:0]const u8, ...) ?*Image;
pub extern fn vips_image_new_from_memory(data: *const anyopaque, size: usize, width: c_int, height: c_int, bands: c_int, format: c_int) ?*Image;
pub extern fn vips_thumbnail_buffer(data: *anyopaque, len: usize, output: *?*Image, width: c_int, ...) c_int;
pub extern fn vips_black(output: *?*Image, width: c_int, height: c_int, ...) c_int;
pub extern fn vips_resize(input: *Image, output: *?*Image, scale: f64, ...) c_int;
pub extern fn vips_jpegsave_buffer(image: *Image, data: *?*anyopaque, len: *usize, ...) c_int;
pub extern fn vips_webpsave_buffer(image: *Image, data: *?*anyopaque, len: *usize, ...) c_int;
pub extern fn vips_pngsave_buffer(image: *Image, data: *?*anyopaque, len: *usize, ...) c_int;
pub extern fn vips_heifsave_buffer(image: *Image, data: *?*anyopaque, len: *usize, ...) c_int;
pub extern fn g_object_unref(object: *anyopaque) void;
pub extern fn g_free(data: ?*anyopaque) void;
