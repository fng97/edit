const std = @import("std");
const FRNG = @import("FRNG.zig");
const Editor = @import("Editor.zig");

const assert = std.debug.assert;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdin_reader = std.Io.File.stdin().reader(io, &.{});
    const entropy = try stdin_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(entropy);

    var frng: FRNG = .{ .entropy = entropy };

    // Generate file name.
    // TODO: Is this big enough? Make it look more like a path?
    const file_name_size = frng.logInt(u8) catch return;
    const file_name_buffer = try allocator.alloc(u8, file_name_size);
    defer allocator.free(file_name_buffer);
    for (file_name_buffer) |*byte| byte.* = frng.rangeInclusive(u8, 0x20, 0x7E) catch return;

    // Generate file contents.
    // TODO: Handle opening empty files: add a single newline rather than supporting empty files.
    if (frng.entropy.len == 0) return;
    const file_size = frng.logRangeInclusive(u32, 1, @intCast(frng.entropy.len)) catch return;
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

    // Generate viewport dimensions.
    const row_count = frng.logInt(u16) catch return;
    const col_count = frng.logInt(u16) catch return;

    // Use the remaining entropy to generate inputs.
    var input: std.Io.Writer.Allocating = .init(allocator);
    defer input.deinit();
    // First input must be resize (parsed during init below for dimensions).
    try input.writer.print("\x1b[48;{d};{d};0;0t", .{ row_count, col_count }); // pix values ignored
    while (true) switch (frng.weighted(.{ .move = 900, .resize = 10, .quit = 1 }) catch break) {
        .move => try input.writer.writeByte(switch (frng.weighted(.{
            .h = 1,
            .j = 1,
            .k = 1,
            .l = 1,
        }) catch break) {
            .h => 'h',
            .j => 'j',
            .k => 'k',
            .l => 'l',
        }),
        .resize => try input.writer.print("\x1b[48;{d};{d};0;0t", .{
            frng.logInt(u16) catch break,
            frng.logInt(u16) catch break,
        }),
        .quit => break,
    };
    try input.writer.writeByte('q'); // guarantee a clean exit
    var reader: std.Io.Reader = .fixed(input.written());

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var editor = Editor.init(
        allocator,
        &reader,
        &writer.writer,
        file_name_buffer,
        file_buffer,
        .{},
    ) catch |err| switch (err) {
        error.FileNotAscii, error.FileTooManyLines => return,
        else => return err,
    };
    defer editor.deinit();

    while (editor.tick() catch |err| switch (err) {
        error.ViewportTooSmall => return,
        else => return err,
    }) {}
}
