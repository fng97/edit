const std = @import("std");
const editor = @import("editor.zig");
const EditorFuzzContext = editor.EditorFuzzContext;
const fuzzEditor = editor.fuzzEditor;
const terminalPanic = editor.terminalPanic;
const terminal_init = editor.terminal_init;
const terminal_deinit = editor.terminal_deinit;
const enableRawMode = editor.enableRawMode;

var termios_original: ?std.posix.termios = null;
pub const panic = std.debug.FullPanic(terminalPanic);

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

    const stdin = std.Io.File.stdin();
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = stdin.reader(io, &stdin_buffer);
    const reader: *std.Io.Reader = &stdin_reader.interface;

    const stdout = std.Io.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout.writer(io, &stdout_buffer);
    const writer: *std.Io.Writer = &stdout_writer.interface;

    try writer.writeAll("Attach the debugger. Press enter to continue.");
    try writer.flush();
    _ = try reader.discardDelimiterInclusive('\n');

    termios_original = try std.posix.tcgetattr(stdin.handle);
    defer std.posix.tcsetattr(stdin.handle, .FLUSH, termios_original.?) catch {}; // restore on exit
    try enableRawMode(termios_original.?);

    defer stdout.writeStreamingAll(io, terminal_deinit) catch {};
    try stdout.writeStreamingAll(io, terminal_init);

    var smith: std.testing.Smith = .{ .in = crash };

    var ctx: EditorFuzzContext = try .init(allocator, io, writer);
    defer ctx.deinit(allocator);

    try fuzzEditor(&ctx, &smith);
}
