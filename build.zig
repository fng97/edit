const std = @import("std");

pub fn build(b: *std.Build) void {
    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run tests");
    const install_step = b.getInstallStep();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("editor.zig"),
        .target = target,
        .optimize = optimize,
    });

    test_step.dependOn(blk: {
        const run = b.addRunArtifact(b.addTest(.{
            .root_module = mod,
            // .use_llvm = true, // when using debugger
        }));
        break :blk &run.step;
    });

    run_step.dependOn(blk: {
        const main = b.addExecutable(.{ .name = "edit", .root_module = mod });
        b.installArtifact(main);
        const run = b.addRunArtifact(main);
        run.step.dependOn(install_step); // run from prefix
        run.addPassthruArgs(); // pass args: e.g. zig build run -- arg1
        break :blk &run.step;
    });
    test_step.dependOn(install_step); // make sure main executable gets built as part of tests
}
