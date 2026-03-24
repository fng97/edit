const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run the main executable");
    const gtest_step = b.step("gtest", "Run googletest");
    const gbench_step = b.step("gbench", "Run google benchmark");
    const test_step = b.step("test", "Run all checks");
    const fmt_step = b.step("fmt", "Format C/C++ files with clang-format");

    const googletest_dep = b.dependency("googletest", .{ .target = target, .optimize = optimize });
    const benchmark_dep = b.dependency("benchmark", .{ .target = target, .optimize = optimize });
    const clang_tools_dep = b.dependency("clang_tools", .{ .target = b.graph.host });

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.appendSlice(b.allocator, &.{
        "-std=c++20",
        "-fno-exceptions",
        "-Wall",
        "-Wextra",
        "-Werror",
    });
    if (optimize == .Debug) try flags.append(b.allocator, "-fstack-protector-all");

    const lib = b.addLibrary(.{
        .name = "lib",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            // .link_libc = true,
            // .link_libcpp = true,
        }),
    });
    lib.root_module.addCSourceFiles(.{
        .root = b.path("src"),
        // Source files go here.
        .files = &.{
            "lib.cpp",
        },
        .flags = flags.items,
    });
    // To link standard libraries:
    // lib.linkLibCpp();
    // lib.linkLibC();

    const exe = b.addExecutable(.{
        .name = "main",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    exe.root_module.addCSourceFiles(.{ .files = &.{"src/main.cpp"}, .flags = flags.items });
    exe.linkLibrary(lib);
    b.installArtifact(exe); // install step installs this exe to prefix/bin
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep()); // also install artefacts when we run `zig build run`

    const gtest_exe = b.addExecutable(.{
        .name = "gtest",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    gtest_exe.root_module.addCSourceFiles(.{
        .root = b.path("src"),
        // Test files go here.
        .files = &.{
            "test.cpp",
        },
        .flags = flags.items,
    });
    gtest_exe.linkLibrary(lib);
    gtest_exe.linkLibrary(googletest_dep.artifact("gtest"));
    gtest_exe.linkLibrary(googletest_dep.artifact("gtest_main"));
    const gtest_run = b.addRunArtifact(gtest_exe);
    gtest_run.addArg("--gtest_brief=1");
    if (b.args) |args| gtest_run.addArgs(args);
    gtest_step.dependOn(&gtest_run.step);

    // Also add googletest tests to `zig build test` step.
    const gtest_check_exe = b.addRunArtifact(gtest_exe);
    gtest_check_exe.addArg("--gtest_brief=1");
    gtest_check_exe.expectExitCode(0); // hides stdout when tests pass
    test_step.dependOn(&gtest_check_exe.step);

    const gbench_exe = b.addExecutable(.{
        .name = "gbench",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    gbench_exe.root_module.addCSourceFiles(.{
        .root = b.path("src"),
        // Benchmark files go here.
        .files = &.{
            "benchmark.cpp",
        },
        .flags = flags.items,
    });
    gbench_exe.linkLibrary(lib);
    gbench_exe.linkLibrary(benchmark_dep.artifact("benchmark"));
    gbench_exe.linkLibrary(benchmark_dep.artifact("benchmark_main"));
    const gbench_run = b.addRunArtifact(gbench_exe);
    if (b.args) |args| gbench_run.addArgs(args);
    gbench_step.dependOn(&gbench_run.step);

    // Also add a quick run of the Google Benchmark benchmarks to `zig build test`.
    const gbench_check_exe = b.addRunArtifact(gbench_exe);
    gbench_check_exe.addArg("--benchmark_min_time=0s"); // fast: only one iteration per benchmark
    gbench_check_exe.expectExitCode(0);
    _ = gbench_check_exe.captureStdErr(); // hide stderr
    test_step.dependOn(&gbench_check_exe.step);

    // Save list of C/C++ files to format to a file.
    const git_ls_cmd = b.addSystemCommand(&.{ "git", "ls-files", "*.[ch]pp", "*.[ch]" });
    const files_list = git_ls_cmd.captureStdOut();

    // Format the C/C++ code in-place with clang-format with `zig build fmt`.
    const clang_format_cmd = std.Build.Step.Run.create(b, "clang-format");
    const clang_format_bin =
        clang_tools_dep.builder.named_lazy_paths.get("clang-format") orelse return;
    clang_format_cmd.addFileArg(clang_format_bin);
    clang_format_cmd.addArg("-i");
    clang_format_cmd.addPrefixedFileArg("--files=", files_list);
    fmt_step.dependOn(&clang_format_cmd.step);

    // Add checking the C/C++ code formatting with clang-format to `zig build test`.
    const clang_format_check_cmd = std.Build.Step.Run.create(b, &.{});
    clang_format_check_cmd.addFileArg(clang_format_bin);
    clang_format_check_cmd.addArgs(&.{ "--dry-run", "--Werror" });
    clang_format_check_cmd.addPrefixedFileArg("--files=", files_list);
    clang_format_check_cmd.expectExitCode(0);
    _ = clang_format_check_cmd.captureStdErr();
    test_step.dependOn(&clang_format_check_cmd.step);
}
