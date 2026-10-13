const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.linkSystemLibrary("vips", .{ .use_pkg_config = .force });
    const executable = b.addExecutable(.{ .name = "imgresize", .root_module = module });
    b.installArtifact(executable);

    const benchmark = b.addExecutable(.{
        .name = "imgresize-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(benchmark);
    const benchmark_run = b.addRunArtifact(benchmark);
    if (b.args) |args| benchmark_run.addArgs(args);
    b.step("benchmark", "Benchmark concurrent URL resizing").dependOn(&benchmark_run.step);

    const run = b.addRunArtifact(executable);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the URL resize service").dependOn(&run.step);

    const test_options = b.addOptions();
    test_options.addOptionPath("server_path", executable.getEmittedBin());
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.linkSystemLibrary("vips", .{ .use_pkg_config = .force });
    test_module.addOptions("test_options", test_options);
    const tests = b.addTest(.{ .root_module = test_module });
    const test_run = b.addRunArtifact(tests);
    b.step("test", "Run unit and real-server integration tests").dependOn(&test_run.step);
}
