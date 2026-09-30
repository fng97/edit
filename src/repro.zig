const std = @import("std");

const editor = @import("editor.zig");
const Editor = editor.Editor;
const fuzzEditor = editor.fuzzEditor;
const FuzzContext = editor.FuzzContext;
const nextEvent = editor.nextEvent;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    const corpus = try std.Io.Dir.cwd().readFileAlloc(
        io,
        ".zig-cache/f/crash",
        allocator,
        .unlimited,
    );
    defer allocator.free(corpus);

    var smith: std.testing.Smith = .{ .in = corpus };

    var ctx: FuzzContext = try .init(allocator, io);
    defer ctx.deinit(allocator);

    var e = try ctx.editor(&smith);
    defer e.deinit(allocator);

    while (true) if (try e.tick(nextEvent(&smith))) continue else return;
}
