const std = @import("std");

pub fn build(b: *std.Build) void {
    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run tests");
    const fuzz_step = b.step("fuzz", "Run the fuzzer");
    const install_step = b.getInstallStep();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/Editor.zig"),
        .target = target,
        .optimize = optimize,
    });

    test_step.dependOn(blk: {
        const exe = b.addTest(.{ .root_module = mod });
        const run = b.addRunArtifact(exe);
        break :blk &run.step;
    });

    run_step.dependOn(blk: {
        const exe = b.addExecutable(.{
            .name = "edit",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("Editor", mod);
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.step.dependOn(install_step); // run from prefix
        if (b.args) |args| run.addArgs(args); // pass args: e.g. zig build run -- arg1
        break :blk &run.step;
    });
    test_step.dependOn(install_step); // make sure main executable gets built as part of tests

    fuzz_step.dependOn(blk: {
        // TODO: Do a bit of fuzzing as part of the test step. To test determinism in general and
        // across optimisation modes, add a step that runs the fuzzer in replay mode in Debug and
        // ReleaseSafe and compares the output.
        const run = b.addRunArtifact(b.addExecutable(.{
            .name = "fuzz_harness",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/FRNG.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }));
        // Pass fuzz test executable path to fuzz harness.
        run.addArtifactArg(b.addExecutable(.{
            .name = "fuzz_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/fuzz.zig"),
                .target = target,
                .optimize = optimize,
            }),
        }));
        // By default, run fuzzing search (find failure then minimise).
        if (b.args) |args| run.addArgs(args) else {
            const attempts = 100; // test attempts per fuzzing input size
            const size_max = 8 * 1024 * 1024; // max entropy size per test
            run.addArg(b.fmt("--search={}:{}", .{ attempts, size_max }));
        }
        break :blk &run.step;
    });

    test_step.dependOn(blk: {
        const dep = b.dependency("tidy", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
        const exe = b.addTest(.{ .name = "tidy checks", .root_module = dep.module("tidy") });
        const run = b.addRunArtifact(exe);
        break :blk &run.step;
    });
}
