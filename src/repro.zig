const std = @import("std");
const Editor = @import("Editor");
const EditorFuzzContext = Editor.EditorFuzzContext;
const fuzzEditor = Editor.fuzzEditor;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const crash = try std.Io.Dir.cwd().readFileAlloc(
        io,
        ".zig-cache/f/crash",
        allocator,
        .unlimited,
    );
    defer allocator.free(crash);

    var smith: std.testing.Smith = .{ .in = crash };
    var ctx: EditorFuzzContext = .{};
    try fuzzEditor(&ctx, &smith);
}
