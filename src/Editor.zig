// ASCII cheatsheet:
//      0    1    2    3    4    5    6    7    8    9    A    B    C    D    E    F
// 0x0  NUL  SOH  STX  ETX  EOT  ENQ  ACK  BEL  BS   HT   LF   VT   FF   CR   SO   SI
// 0x1  DLE  DC1  DC2  DC3  DC4  NAK  SYN  ETB  CAN  EM   SUB  ESC  FS   GS   RS   US
// 0x2  SP   !    "    #    $    %    &    '    (    )    *    +    ,    -    .    /
// 0x3  0    1    2    3    4    5    6    7    8    9    :    ;    <    =    >    ?
// 0x4  @    A    B    C    D    E    F    G    H    I    J    K    L    M    N    O
// 0x5  P    Q    R    S    T    U    V    W    X    Y    Z    [    \    ]    ^    _
// 0x6  `    a    b    c    d    e    f    g    h    i    j    k    l    m    n    o
// 0x7  p    q    r    s    t    u    v    w    x    y    z    {    |    }    ~    DEL

// TODO: Diagnose and get rid of occasional flickering.

const std = @import("std");

const assert = std.debug.assert;
const Editor = @This();

const file_lines_max = 1024 * 10; // 10 MiB
const file_line_size_max = 999;

allocator: std.mem.Allocator,
reader: *std.Io.Reader,
writer: *std.Io.Writer,

// Viewport state:
row_count: u16,
col_count: u16,
first_line: u16, // line number of the top line
first_offset: u16, // viewport offset into lines (for horizontal scroll)
snap_offset: u16,

// File state:
name: []const u8,
bytes: []const u8,
lines: std.ArrayList(Line),

cursor: struct {
    position: Position,
},

/// Coordinate in the viewport.
const Cell = struct {
    row: u16,
    col: u16,
};

/// Coordinate in the file.
const Position = struct {
    line_number: u16,
    line_offset: u16,

    pub fn fromFileOffset(file_offset: u32, lines: []const Line) Position {
        for (lines, 0..) |line, line_number| {
            if (file_offset <= line.tail) return .{
                .line_number = @intCast(line_number),
                .line_offset = @intCast(file_offset - line.head),
            };
        } else @panic("Offset not within file bounds");
    }

    pub fn toFileOffset(position: Position, lines: []const Line) u32 {
        return lines[position.line_number].head + position.line_offset;
    }
};

const Line = struct {
    head: u32, // line start offset
    tail: u32, // line end offset (always a newline)

    pub fn slice(line: Line, file_bytes: []const u8) []const u8 {
        return file_bytes[line.head..line.tail];
    }

    pub fn size(line: Line) u16 {
        return @intCast(line.tail - line.head);
    }
};

/// Kitty Keyboard Protocol modifiers:
///
/// shift     0b1         (1)
/// alt       0b10        (2)
/// ctrl      0b100       (4)
/// super     0b1000      (8)
/// hyper     0b10000     (16)
/// meta      0b100000    (32)
/// caps_lock 0b1000000   (64)
/// num_lock  0b10000000  (128)
const Modifiers = packed struct(u8) {
    shift: bool,
    alt: bool,
    ctrl: bool,
    super: bool,
    hyper: bool,
    meta: bool,
    caps_lock: bool,
    num_lock: bool,

    /// Decode modifiers from ASCII value passed in escape sequence: "In the escape code, the
    /// modifier value is encoded as a decimal number which is 1 + actual modifiers. So to represent
    /// shift only, the value would be 1 + 1 = 2, to represent ctrl+shift the value would be 1 +
    /// 0b101 = 6 and so on."
    pub fn decode(encoded: []const u8) !Modifiers {
        // u9 because if all bits were high we'd have 255 + 1 = 256, which cannot be stored in a u8.
        const value = try std.fmt.parseInt(u9, encoded, 10);
        assert(value != 0);
        const byte: u8 = @intCast(value - 1);
        return @bitCast(byte);
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    file_name: []const u8,
    file_bytes: []const u8,
    options: struct { file_lines_max: u16 = file_lines_max },
) !Editor {
    // File must not be empty, contain only ASCII, and end in newline.
    assert(file_bytes.len != 0);
    for (file_bytes) |byte| if (!std.ascii.isAscii(byte)) return error.FileNotAscii;
    if (file_bytes[file_bytes.len - 1] != '\n') return error.FileNotNewlineTerminated;

    const dimensions = switch (try parseOne(reader)) {
        .resize => |resize| resize,
        else => @panic("First event must be resize"),
    };

    var lines: std.ArrayList(Line) = try .initCapacity(allocator, options.file_lines_max);
    errdefer lines.deinit(allocator);
    try indexLines(file_bytes, &lines);

    return .{
        .allocator = allocator,
        .reader = reader,
        .writer = writer,
        .row_count = dimensions.row_count,
        .col_count = dimensions.col_count,
        .first_line = 0,
        .first_offset = 0,
        .snap_offset = 0,
        .name = file_name,
        .bytes = file_bytes,
        .lines = lines,
        .cursor = .{ .position = .{ .line_number = 0, .line_offset = 0 } },
    };
}

pub fn deinit(editor: *Editor) void {
    editor.lines.deinit(editor.allocator);
}

/// Handle input: parse Kitty Keyboard Protocol events.
fn parseOne(reader: *std.Io.Reader) !union(enum) {
    resize: struct { row_count: u16, col_count: u16 },
    ascii: u8,
} {
    switch (try reader.takeByte()) {
        // Key events that produce text are sent directly as UTF-8 encyoded bytes.
        0x21...0x7E => |c| return .{ .ascii = c },
        '\x1b' => { // escape sequence
            assert(try reader.takeByte() == '['); // escape sequences must start with CSI
            switch (try std.fmt.parseInt(i32, (try reader.takeDelimiter(';')).?, 10)) {
                // TODO: Enforce that escape codes use lowercase codepoint:
                // https://sw.kovidgoyal.net/kitty/keyboard-protocol/#key-codes

                // Resize: CSI 48 ; height_chars ; width_chars ; height_pix ; width_pix t.
                48 => {
                    const row_count =
                        try std.fmt.parseInt(u16, (try reader.takeDelimiter(';')).?, 10);
                    const col_count =
                        try std.fmt.parseInt(u16, (try reader.takeDelimiter(';')).?, 10);
                    _ = try reader.takeDelimiter(';'); // height_pix
                    _ = try reader.takeDelimiter('t'); // width_pix
                    return .{ .resize = .{ .row_count = row_count, .col_count = col_count } };
                },
                else => |c| std.debug.panic("Unrecognised KKP escape sequence: {x}{x}", .{
                    c,
                    reader.buffered(),
                }),
            }
        },
        else => |c| std.debug.panic("Unrecognised KKP escape sequence: {x}{x}{x}", .{
            "\x1b[",
            c,
            reader.buffered(),
        }),
    }
}

pub fn tick(editor: *Editor) !bool {
    // Vertically, need room for at least one line and the status line.
    if (editor.row_count < 2) return error.ViewportTooSmall;
    // Horizontally, need room for the gutter and one character.
    if (editor.col_count < editor.gutterWidth() + 1) return error.ViewportTooSmall;

    try editor.render();

    const lines = editor.lines.items;
    switch (try parseOne(editor.reader)) {
        .ascii => |byte| switch (byte) {
            'q' => return false, // quit
            'h', 'l' => |c| { // left, right
                const line_offset = editor.cursor.position.line_offset;
                editor.cursor.position.line_offset = @min(
                    if (c == 'h') line_offset -| 1 else line_offset +| 1,
                    lines[editor.cursor.position.line_number].size() -| 1, // clamp to end of line
                );
                editor.snap_offset = editor.cursor.position.line_offset;
            },
            'j', 'k' => |c| { // down, up
                const line_number = editor.cursor.position.line_number;
                editor.cursor.position.line_number = @min(
                    if (c == 'j') line_number +| 1 else line_number -| 1,
                    lines.len - 1, // clamp to last line in file
                );
                // Clamp the offset if previous line is shorter. Subtract 1 to go from size to
                // offset, saturated so we don't underflow in the case of an empty line.
                editor.cursor.position.line_offset =
                    @min(editor.snap_offset, lines[editor.cursor.position.line_number].size() -| 1);
            },
            else => {},
        },
        .resize => |resize| {
            editor.row_count = resize.row_count;
            editor.col_count = resize.col_count;
        },
    }

    // Cursor must be within viewport.
    const last_line = editor.lastLine();
    if (editor.cursor.position.line_number < editor.first_line) {
        editor.first_line = editor.cursor.position.line_number;
    } else if (editor.cursor.position.line_number > last_line) {
        editor.first_line += editor.cursor.position.line_number - last_line;
    }
    const last_offset = editor.lastOffset();
    if (editor.cursor.position.line_offset < editor.first_offset) {
        editor.first_offset = editor.cursor.position.line_offset;
    } else if (editor.cursor.position.line_offset > last_offset) {
        editor.first_offset += editor.cursor.position.line_offset - last_offset;
    }

    return true;
}

// TODO: Make this private and only use `tick()`?
pub fn render(editor: *const Editor) !void {
    const writer = editor.writer;
    const row_count = editor.row_count;
    const col_count = editor.col_count;
    const first_line = editor.first_line;
    const first_offset = editor.first_offset;
    const file_bytes = editor.bytes;
    const file_name = editor.name;
    const lines = editor.lines.items;
    const cursor_position = editor.cursor.position;

    const gutter_width = editor.gutterWidth();

    try writer.writeAll("\x1b[2J"); // clear screen
    try writer.writeAll("\x1b[H"); // place cursor at top left

    // The -1 below is to leave room for the status line.
    for (first_line..first_line + row_count - 1) |line_number| {
        const line = if (line_number < lines.len) blk: {
            const line_full = lines[line_number].slice(file_bytes);
            if (first_offset > line_full.len) break :blk "";
            const line = line_full[first_offset..];
            const line_size = @min(line.len, col_count - gutter_width);
            break :blk line_full[first_offset .. first_offset + line_size];
        } else "~";
        try writer.print(
            "{[line_number]d: >[gutter_width]} {[line]s}\r\n",
            .{
                .line_number = line_number + 1, // displayed line number indexed from 1
                .gutter_width = gutter_width - 1, // extra space already in format string
                .line = line,
            },
        );
    }

    // Draw status line. Displayed line number and offset should be indexed from 1.
    const cursor_coordinates_col_count =
        digitCount(cursor_position.line_number + 1) +
        digitCount(cursor_position.line_offset + 1) +
        1; // the ',' in "{displayed_line_number},{displayed_line_offset}"
    // TODO: Display the relative file path.
    // TODO: Minimise the file_name (path). For now, only print it if it fits.
    const cursor_coordinates_col_count_max =
        digitCount(file_lines_max) +
        digitCount(file_line_size_max) + 1;
    if (file_name.len + cursor_coordinates_col_count_max < col_count) {
        const padding_col_count = col_count - file_name.len - cursor_coordinates_col_count;
        try writer.writeAll(file_name);
        try writer.splatByteAll(' ', padding_col_count);
    } else try writer.splatByteAll(' ', col_count - cursor_coordinates_col_count_max);
    try writer.print("{d},{d}", .{
        cursor_position.line_number + 1,
        cursor_position.line_offset + 1,
    });

    // Make sure cursor is within the viewport's bounds.
    assert(cursor_position.line_number >= first_line);
    assert(cursor_position.line_number <= editor.lastLine());
    assert(cursor_position.line_offset >= first_offset);
    assert(cursor_position.line_offset <= editor.lastOffset());
    const cursor_cell: Cell = .{
        .row = cursor_position.line_number - first_line,
        .col = cursor_position.line_offset - first_offset + gutter_width,
    };
    assert(cursor_cell.col >= gutter_width); // right of line numbers
    assert(cursor_cell.col < col_count); // does not exceed screen bounds horizontally
    assert(cursor_cell.row < row_count); // does not exceed screen bounds vertically

    // Place the cursor (escape code indexes from 1): CSI rows ; cols H.
    try writer.print("\x1b[{d};{d}H", .{ cursor_cell.row + 1, cursor_cell.col + 1 });
    try writer.flush();
}

/// Last line number visible in the viewport.
fn lastLine(editor: *const Editor) u16 {
    return editor.first_line + editor.row_count - 2; // extra -1 for status line
}

/// Last line offset (col) visible in the viewport.
fn lastOffset(editor: *const Editor) u16 {
    const text_width = editor.col_count - editor.gutterWidth();
    return editor.first_offset + text_width - 1;
}

fn gutterWidth(editor: *const Editor) u8 {
    // Determine gutter width, enough digits for the greatest line number plus one for padding.
    return digitCount(@intCast(@max(editor.row_count, editor.lines.items.len))) + 1;
}

// This trick gets us the number of digits in a positive number: log_10(x) + 1.
fn digitCount(number: u16) u8 {
    return std.math.log10_int(number) + 1;
}

fn positionFrom(lines: []const Line, offset: u32) Position {
    for (lines, 0..) |line, line_number| {
        if (offset <= line.tail) return .{
            .line_number = @intCast(line_number),
            .line_offset = @intCast(offset - line.head),
        };
    } else @panic("Offset not within file bounds");
}

fn indexLines(file_bytes: []const u8, lines: *std.ArrayList(Line)) error{FileTooManyLines}!void {
    lines.clearRetainingCapacity();
    assert(file_bytes[file_bytes.len - 1] == '\n'); // make sure file is newline terminated
    var head: u32 = 0;
    while (head < file_bytes.len) {
        var tail = head;
        while (tail < file_bytes.len and file_bytes[tail] != '\n') tail += 1;
        if (lines.items.len == file_lines_max) return error.FileTooManyLines;
        lines.appendAssumeCapacity(.{ .head = head, .tail = tail });
        head = tail + 1;
    }
}

test fuzzer {
    return std.testing.fuzz({}, fuzzer, .{});
}
fn fuzzer(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    const allocator = std.testing.allocator;

    // TODO: I think instead of generating a file size then allocating we could just allocate a max
    // buffer and use the Smith slice functions.
    const file_size_max = 1 * 1024 * 1024;
    // TODO: Handle opening empty files: add a single newline rather than supporting empty files.
    const file_size = smith.valueRangeAtMost(u32, 1, file_size_max);
    const file_buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(file_buffer);

    const Strategy = enum { all, ascii, printable, code };
    smith.bytesWeighted(file_buffer, switch (smith.valueWeighted(Strategy, &.{
        .value(Strategy, .all, 1),
        .value(Strategy, .ascii, 1),
        .value(Strategy, .printable, 1),
        .value(Strategy, .code, 27),
    })) {
        .all => std.testing.Smith.baselineWeights(u8),
        .ascii => &.{.rangeAtMost(u8, 0, 127, 1)},
        .printable => &.{.rangeAtMost(u8, 0x20, 0x7E, 1)},
        .code => &.{
            .value(u8, ' ', 30),
            .rangeAtMost(u8, '!', '/', 5), // ! " # $ % & ' ( ) * + , - . /
            .rangeAtMost(u8, '0', '9', 10),
            .rangeAtMost(u8, ':', '@', 5), // : ; < = > ? @
            .rangeAtMost(u8, 'A', 'Z', 15),
            .rangeAtMost(u8, '[', '`', 5), // [ \ ] ^ _ `
            .rangeAtMost(u8, 'a', 'z', 30),
            .rangeAtMost(u8, '{', '~', 5), // { | } ~
            .value(u8, '\n', 15),
            // TODO: Handle tabs.
            // .value(u8, '\t', 5),
        },
    });

    // TODO: Generate these too.
    const row_count = 12;
    const col_count = 36;

    // TODO: Handle file path not fitting in status bar. For now just use fixed name.
    // const file_name_size = smith.valueRangeAtMost(u8, 0, col_count);
    // const file_name_buffer = try allocator.alloc(u8, file_name_size);
    // defer allocator.free(file_name_buffer);
    // smith.bytes(file_name_buffer);

    // On init STDIN must start with resize:
    // CSI 48 ; height_chars ; width_chars ; height_pix ; width_pix t
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
        std.testing.allocator,
        &reader,
        &writer.writer,
        "main.zig",
        file_buffer,
        .{ .file_lines_max = file_lines_max },
    ) catch |err| switch (err) {
        error.FileNotNewlineTerminated, error.FileNotAscii => return,
        else => return err,
    };
    defer editor.deinit();

    try editor.render();
}

test Modifiers {
    try std.testing.expect(try Modifiers.decode("1") == Modifiers{
        .shift = false,
        .alt = false,
        .ctrl = false,
        .super = false,
        .hyper = false,
        .meta = false,
        .caps_lock = false,
        .num_lock = false,
    });

    try std.testing.expect(try Modifiers.decode("2") == Modifiers{
        .shift = true,
        .alt = false,
        .ctrl = false,
        .super = false,
        .hyper = false,
        .meta = false,
        .caps_lock = false,
        .num_lock = false,
    });

    try std.testing.expect(try Modifiers.decode("6") == Modifiers{
        .shift = true,
        .alt = false,
        .ctrl = true,
        .super = false,
        .hyper = false,
        .meta = false,
        .caps_lock = false,
        .num_lock = false,
    });

    try std.testing.expect(try Modifiers.decode("256") == Modifiers{
        .shift = true,
        .alt = true,
        .ctrl = true,
        .super = true,
        .hyper = true,
        .meta = true,
        .caps_lock = true,
        .num_lock = true,
    });
}

const hello_c =
    \\#include <stdio.h>
    \\
    \\int main() {
    \\  printf("Hello, world!\n");
    \\  return 0;
    \\}
    \\
;

test "rendering: hello_c" {
    const allocator = std.testing.allocator;

    var reader = std.Io.Reader.fixed("\x1b[48;12;36;0;0t"); // 12 rows by 36 cols
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var editor: Editor = try .init(allocator, &reader, &writer.writer, "hello.c", hello_c, .{});
    defer editor.deinit();

    try editor.render();
    const result = writer.written();

    // For the comparison below to work we need to strip the carriage returns ('\r').
    var stripped_buffer = try allocator.alloc(u8, result.len);
    defer allocator.free(stripped_buffer);
    const stripped_count = std.mem.replace(u8, result, "\r", "", stripped_buffer);
    const stripped = stripped_buffer[0 .. result.len - stripped_count];

    try std.testing.expectEqualSlices(u8, "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 #include <stdio.h>
        \\ 2 
        \\ 3 int main() {
        \\ 4   printf("Hello, world!\n");
        \\ 5   return 0;
        \\ 6 }
        \\ 7 ~
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c                          1,1
    ++ "\x1b[1;4H" // cursor coordinates at start of file: 0, 3 (but indexed from 1)
    , stripped);
}

test "rendering: empty" {
    const allocator = std.testing.allocator;

    var reader = std.Io.Reader.fixed("\x1b[48;12;36;0;0t"); // 12 rows by 36 cols
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var editor: Editor = try .init(allocator, &reader, &writer.writer, "empty.zig", "\n", .{});
    defer editor.deinit();

    try editor.render();
    const result = writer.written();

    // For the comparison below to work we need to strip the carriage returns ('\r').
    var stripped_buffer = try allocator.alloc(u8, result.len);
    defer allocator.free(stripped_buffer);
    const stripped_count = std.mem.replace(u8, result, "\r", "", stripped_buffer);
    const stripped = stripped_buffer[0 .. result.len - stripped_count];

    try std.testing.expectEqualSlices(u8, "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 
        \\ 2 ~
        \\ 3 ~
        \\ 4 ~
        \\ 5 ~
        \\ 6 ~
        \\ 7 ~
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\empty.zig                        1,1
    ++ "\x1b[1;4H" // cursor coordinates at start of file: 0, 3 (but indexed from 1)
    , stripped);
}

test indexLines {
    const allocator = std.testing.allocator;
    var lines: std.ArrayList(Line) = try .initCapacity(
        allocator,
        std.mem.countScalar(u8, hello_c, '\n'),
    );
    defer lines.deinit(allocator);

    try indexLines(hello_c, &lines);
    try std.testing.expect(lines.items.len == 6);
    try std.testing.expect(lines.items[0].head == 0);
    try std.testing.expect(lines.items[0].tail == 18);
    try std.testing.expect(lines.getLast().tail == hello_c.len - 1);

    // This function should never be called with an empty slice. Empty files are handled by
    // inserting a single newline.
    const empty_file = "\n";
    try indexLines(empty_file, &lines);
    try std.testing.expect(lines.items.len == 1);
    try std.testing.expect(lines.items[0].head == 0);
    try std.testing.expect(lines.items[0].tail == 0);
}
