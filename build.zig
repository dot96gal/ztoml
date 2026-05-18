const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("ztoml", .{
        .root_source_file = b.path("src/ztoml.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "ztoml",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ztoml", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const example_basic_step = b.step("example-basic", "Run examples/basic.zig");

    const exe_example_basic = b.addRunArtifact(exe);
    example_basic_step.dependOn(&exe_example_basic.step);
    exe_example_basic.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        exe_example_basic.addArgs(args);
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

    const e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("e2e/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ztoml", .module = mod },
            },
        }),
    });

    const run_e2e_tests = b.addRunArtifact(e2e_tests);

    const e2e_step = b.step("e2e", "Run E2E tests");
    e2e_step.dependOn(&run_e2e_tests.step);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "ztoml", .module = mod },
            },
        }),
    });

    const run_bench_exe = b.addRunArtifact(bench_exe);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench_exe.step);

    const docs_obj = b.addObject(.{
        .name = "ztoml",
        .root_module = mod,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&install_docs.step);
}
