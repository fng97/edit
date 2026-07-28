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

    const file_name_size = frng.int(u8) catch return; // TODO: Is this big enough?
    const file_name_buffer = try allocator.alloc(u8, file_name_size);
    defer allocator.free(file_name_buffer);
    for (file_name_buffer) |*byte| byte.* = frng.rangeInclusive(u8, 0x20, 0x7E) catch return;

    // TODO: Generate these too.
    const row_count = 12;
    const col_count = 36;
    const resize = try std.fmt.allocPrint(
        allocator,
        "\x1b[48;{d};{d};0;0t", // pix values ignored
        .{ row_count, col_count },
    );
    defer allocator.free(resize);
    var reader = std.Io.Reader.fixed(resize);
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

    // TODO: Feed input to stdin. Call tick instead. Make render private again.
}
