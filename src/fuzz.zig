const std = @import("std");
const FRNG = @import("FRNG.zig");
const Editor = @import("Editor.zig");

const assert = std.debug.assert;

fn run(allocator: std.mem.Allocator, frng: *FRNG) !void {
    // Generate file name.
    // TODO: Is this big enough? Make it look more like a path?
    const file_name_size = try frng.int(u8);
    const file_name_buffer = try allocator.alloc(u8, file_name_size);
    defer allocator.free(file_name_buffer);
    for (file_name_buffer) |*byte| byte.* = try frng.rangeInclusive(u8, 0x20, 0x7E);

    // Generate file contents. 1 byte of entropy in != 1 random byte out. Keep max file size a small
    // portion of remaining entropy so that it's likely we'll be able to fill the whole file without
    // running out of entropy.
    const file_size_max: u32 = @intCast(frng.entropy.len / 4);
    // TODO: Handle opening empty files: add a single newline rather than supporting empty files.
    const file_size = try frng.rangeInclusive(u32, 1, @max(file_size_max, 1));
    const file_buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(file_buffer);
    const FileWeights = struct { printable: u32, space: u32, newline: u32, tab: u32 };
    const file_weights: FileWeights = switch (try frng.weighted(.{ .code = 999, .random = 1 })) {
        // These weights are loosely based on the byte distribution of the TigerBeetle source code.
        .code => .{ .printable = 662, .space = 252, .newline = 24, .tab = 62 },
        .random => try frng.randomWeights(FileWeights),
    };
    for (file_buffer) |*byte| byte.* = switch (try frng.weighted(file_weights)) {
        .printable => try frng.rangeInclusive(u8, '!', '~'),
        .space => ' ',
        .tab => '\t',
        .newline => '\n',
    };
    file_buffer[file_buffer.len - 1] = '\n';

    // Generate viewport dimensions.
    const row_count = try viewportDimension(frng);
    const col_count = try viewportDimension(frng);

    // Use the remaining entropy to generate inputs.
    var input: std.Io.Writer.Allocating = .init(allocator);
    defer input.deinit();
    // First input must be resize (parsed during init below for dimensions).
    try input.writer.print("\x1b[48;{d};{d};0;0t", .{ row_count, col_count }); // pix values ignored
    const move_weights = try frng.randomWeights(struct { h: u32, j: u32, k: u32, l: u32 });
    // Fill the input buffer with inputs until we run out of entropy.
    while (true) generateInput(&input.writer, frng, move_weights) catch |err| switch (err) {
        error.OutOfEntropy => break,
        else => return err,
    };

    try input.writer.writeByte('q'); // guarantee a clean exit
    var reader: std.Io.Reader = .fixed(input.written());

    var writer: std.Io.Writer.Discarding = .init(&.{});
    var editor = Editor.init(
        allocator,
        &reader,
        &writer.writer,
        file_name_buffer,
        file_buffer,
    ) catch |err| switch (err) {
        error.FileNotAscii,
        error.FileTooManyLines,
        error.ViewportTooSmall,
        error.ViewportTooLarge,
        => return,
        else => return err,
    };
    defer editor.deinit();

    while (editor.tick() catch |err| switch (err) {
        error.ViewportTooSmall,
        error.ViewportTooLarge,
        => return,
        else => return err,
    }) {}
}

fn generateInput(writer: *std.Io.Writer, frng: *FRNG, weights: anytype) !void {
    return switch (try frng.weighted(.{ .move = 999, .resize = 1 })) {
        .move => {
            const repeat = try frng.boolean();
            const byte: u8 = switch (try frng.weighted(weights)) {
                .h => 'h',
                .j => 'j',
                .k => 'k',
                .l => 'l',
            };
            if (repeat) {
                try writer.splatByteAll(byte, try frng.int(u8));
            } else try writer.writeByte(byte);
        },
        .resize => try writer.print("\x1b[48;{d};{d};0;0t", .{
            try viewportDimension(frng),
            try viewportDimension(frng),
        }),
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdin_reader = std.Io.File.stdin().reader(io, &.{});
    const entropy = try stdin_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(entropy);

    var frng: FRNG = .{ .entropy = entropy };
    run(allocator, &frng) catch |err| switch (err) {
        error.OutOfEntropy => return,
        else => return err,
    };
}

fn viewportDimension(frng: *FRNG) FRNG.Error!u16 {
    return switch (try frng.weighted(.{
        .small = 1,
        .normal = 998,
        .large = 1,
    })) {
        .small => try frng.rangeInclusive(u8, 2, 15), // below 2 triggers error.ViewportTooSmall
        .normal => try frng.rangeInclusive(u8, 16, 255),
        .large => try frng.int(u16),
    };
}
