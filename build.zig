const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cli_dep = b.dependency("chilli", .{
        .target = target,
        .optimize = optimize,
    });

    const enable_tsan = b.option(bool, "tsan", "Enable thread sanitizer");

    const mod = b.addModule("bm25", .{
        .root_source_file = b.path("src/root.zig"),

        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "bm25",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,
            .sanitize_thread = enable_tsan,

            .imports = &.{
                .{ .name = "bm25", .module = mod },
                .{ .name = "chilli", .module = cli_dep.module("chilli") },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bm25", .module = mod },
            },
        }),
    });

    b.installArtifact(benchmark_exe);

    const benchmark_step = b.step("benchmark", "Run indexing benchmark");
    const run_benchmark_cmd = b.addRunArtifact(benchmark_exe);
    benchmark_step.dependOn(&run_benchmark_cmd.step);
    if (b.args) |args| {
        run_benchmark_cmd.addArgs(args);
    }
}
