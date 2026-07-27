const std = @import("std");
const FRNG = @import("FRNG.zig");

// TODO: Move this struct out into separate file.
const Editor = @import("main.zig").Editor;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdin_reader = std.Io.File.stdin().reader(io, &.{});
    const entropy = try stdin_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(entropy);

    var frng: FRNG = .{ .entropy = entropy };

    // TODO: Handle opening empty files: add a single newline rather than supporting empty files.
    if (frng.entropy.len / 2 < 1) return;
    const file_size = frng.rangeInclusive(u32, 1, @intCast(frng.entropy.len / 2)) catch return;
    const file_buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(file_buffer);
    // These weights are loosely based on the byte distribution of the TigerBeetle source code.
    for (file_buffer) |*byte| byte.* = switch (frng.weighted(.{
        .printable = 662,
        .space = 252,
        .newline = 24,
        .tab = 62,
    }) catch return) {
        .printable => frng.rangeInclusive(u8, '!', '~') catch return,
        .space => ' ',
        .tab => '\t',
        .newline => '\n',
    };
    file_buffer[file_buffer.len - 1] = '\n';

    // TODO: Generate these too.
    const row_count = 12;
    const col_count = 36;

    // TODO: Handle file path not fitting in status bar. For now just use fixed name.
    // const file_name_size = frng.int(u8); // TODO: Is this big enough?
    // const file_name_buffer = try.allocator.alloc(u8, file_name_size);
    // defer allocator.free(file_name_buffer);
    // for (file_name_buffer) |*byte| byte.* = frng.rangeInclusive(u8, ?, ?) catch return;

    var reader = std.Io.Reader.fixed(&.{});
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    var editor = Editor.init(
        allocator,
        &reader,
        &writer.writer,
        "main.zig",
        file_buffer,
        row_count,
        col_count,
        .{ .file_lines_max = 1024 * 10 },
    ) catch |err| switch (err) {
        error.FileNotAscii, error.FileTooManyLines => return,
        else => return err,
    };
    defer editor.deinit();

    try editor.viewport.render(
        &writer.writer,
        editor.file.positionFrom(editor.cursor.offset),
        &editor.file,
    );

    // TODO: Feed input to stdin.
}
