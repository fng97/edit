const std = @import("std");

pub fn build(b: *std.Build) void {
    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run tests");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    run_step.dependOn(blk: {
        const exe = b.addExecutable(.{ .name = "edit", .root_module = mod });
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep()); // run from prefix
        break :blk &run.step;
    });

    test_step.dependOn(blk: {
        const exe = b.addTest(.{ .root_module = mod });
        const run = b.addRunArtifact(exe);
        break :blk &run.step;
    });

    test_step.dependOn(blk: {
        const dep = b.dependency("tidy", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
        const exe = b.addTest(.{ .name = "tidy checks", .root_module = dep.module("tidy") });
        const run = b.addRunArtifact(exe);
        break :blk &run.step;
    });
}
