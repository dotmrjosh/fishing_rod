const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const smdl_mod = b.addModule("smdl", .{
        .root_source_file = b.path("src/smdl/module.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sxr_mod = b.addModule("sxr", .{
        .root_source_file = b.path("src/sxr/module.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sxr", .module = sxr_mod },
            .{ .name = "smdl", .module = smdl_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "sxre",
        .root_module = exe_mod,
    });

    // Runner
    const exe_run = b.addRunArtifact(exe);
    if (b.args) |args| {
        exe_run.addArgs(args);
    }

    const run_step = b.step("run", "run the extractor");
    run_step.dependOn(&exe_run.step);

    // Tests
    const sxr_tests = b.addTest(.{
        .root_module = sxr_mod,
    });

    const sxr_tests_run = b.addRunArtifact(sxr_tests);

    const run_tests = b.step("test", "run unit tests");
    run_tests.dependOn(&sxr_tests_run.step);
}
