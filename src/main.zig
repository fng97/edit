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

// NB: File cooridnates (line_number, line_offset) are represented by a `File.Position,` while
// viewport coordinates (row, col) are represented by a `Viewport.Cell`. Both are indexed from 0.

// TODO: Diagnose and get rid of occasional flickering.

const std = @import("std");
const assert = std.debug.assert;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    // Load and process buffer.
    var args_iterator = std.process.Args.Iterator.init(init.minimal.args);
    assert(args_iterator.skip()); // first arg is executable path
    const file_name = args_iterator.next() orelse @panic("Missing file path arg");
    const file_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        file_name,
        allocator,
        .limited(1 * 1024 * 1024), // 1 MiB
    );
    defer allocator.free(file_bytes);

    const stdin = std.Io.File.stdin();
    var stdin_buffer: [128]u8 = undefined; // TODO: What's a reasonable size here?
    var stdin_reader = stdin.reader(io, &stdin_buffer);
    const reader: *std.Io.Reader = &stdin_reader.interface;

    // TODO: Later, we'll want to buffer the whole screen and flush in one go. Will need to work out
    // the maximum buffer size based on resolution and rendering (have to account for escape
    // sequences).
    const stdout = std.Io.File.stdout();
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = stdout.writer(io, &stdout_buffer);
    const writer: *std.Io.Writer = &stdout_writer.interface;

    // Put terminal in raw mode. Restore original termios on exit.
    termios_original = try std.posix.tcgetattr(stdin.handle);
    defer std.posix.tcsetattr(stdin.handle, .FLUSH, termios_original.?) catch {}; // restore on exit
    var termios_raw = termios_original.?;
    termios_raw.iflag.BRKINT = false;
    termios_raw.iflag.ICRNL = false;
    termios_raw.iflag.INPCK = false;
    termios_raw.iflag.ISTRIP = false;
    termios_raw.iflag.IXON = false;
    termios_raw.oflag.OPOST = false;
    termios_raw.cflag.CSIZE = .CS8;
    termios_raw.lflag.ECHO = false;
    termios_raw.lflag.ICANON = false;
    termios_raw.lflag.IEXTEN = false;
    termios_raw.lflag.ISIG = false;
    termios_raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    termios_raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin.handle, .FLUSH, termios_raw);

    defer { // clean up terminal on exit -- safe to send even if KKP disabled or not in alt mode
        writer.writeAll("\x1b[<u") catch {}; // pop KKP flags
        writer.writeAll("\x1b[?2048l") catch {}; // disable in-band resize notifications
        writer.writeAll("\x1b[?1049l") catch {}; // exit alt screen
        writer.flush() catch {};
    }

    // Use alt screen: It stores screen and cursor state separately and has no scrollback. This is
    // the convention for fullscreen TUIs like vim, tmux, etc.
    try writer.writeAll("\x1b[?1049h");
    // Initialise Kitty Keyboard Protocol (KKP) with mode 1 (disambiguate escape codes).
    try writer.writeAll("\x1b[>1u");
    // Enable in-band resize notifications.
    try writer.writeAll("\x1b[?2048h");
    try writer.flush();

    // TODO: Get rid of this? Expect to get the dimensions on first pass of loop below.
    // Get window size using ioctl. Future resizing relies on in-band resize notifications (escape
    // sequences).
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = std.posix.system.ioctl(stdout.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    assert(std.posix.errno(err) == .SUCCESS);

    var editor: Editor = try .init(
        allocator,
        reader,
        writer,
        file_name,
        file_bytes,
        winsize.row,
        winsize.col,
        .{ .file_lines_max = 1024 * 10 },
    );
    defer editor.deinit();

    loop: while (true) {
        // TODO: Handle file changes. Re-index lines and update gutter width.

        const cursor_position = editor.file.positionFrom(editor.cursor.offset);
        const lines = editor.file.lines.items;

        // TODO: Render screen after handling input.
        try editor.viewport.render(editor.writer, cursor_position, &editor.file);

        // Handle input: parse Kitty Keyboard Protocol events.
        switch (try reader.takeByte()) {
            // Key events that produce text are sent directly as UTF-8 encyoded bytes.
            0x21...0x7E => |c| switch (c) {
                'q' => break :loop, // quit
                'h' => editor.cursor.offset =
                    editor.file.offsetFrom(cursor_position.move(.left, lines)),
                'j' => {
                    const moved = cursor_position.move(.down, lines);
                    editor.cursor.offset = editor.file.offsetFrom(moved);
                    if (moved.line_number > editor.viewport.lastLine())
                        editor.viewport.first_line += 1;
                },
                'k' => {
                    const moved = cursor_position.move(.up, lines);
                    editor.cursor.offset = editor.file.offsetFrom(moved);
                    if (moved.line_number < editor.viewport.first_line)
                        editor.viewport.first_line -= 1;
                },
                'l' => editor.cursor.offset =
                    editor.file.offsetFrom(cursor_position.move(.right, lines)),
                else => {},
            },
            '\x1b' => { // escape sequence
                assert(try reader.takeByte() == '['); // escape sequences must start with CSI
                switch (try std.fmt.parseInt(i32, (try reader.takeDelimiter(';')).?, 10)) {
                    // TODO: Enforce that escape codes use lowercase codepoint:
                    // https://sw.kovidgoyal.net/kitty/keyboard-protocol/#key-codes

                    // Resize: CSI 48 ; height_chars ; width_chars ; height_pix ; width_pix t.
                    48 => {
                        editor.viewport.row_count =
                            try std.fmt.parseInt(u16, (try reader.takeDelimiter(';')).?, 10);
                        editor.viewport.col_count =
                            try std.fmt.parseInt(u16, (try reader.takeDelimiter(';')).?, 10);
                        _ = try reader.takeDelimiter(';'); // height_pix
                        _ = try reader.takeDelimiter('t'); // width_pix
                    },
                    else => |c| std.debug.panic(
                        "Unrecognised KKP escape sequence: {x}{x}",
                        .{ c, reader.buffered() },
                    ),
                }
            },
            else => |c| std.debug.panic(
                "Unrecognised KKP escape sequence: {x}{x}{x}",
                .{ "\x1b[", c, reader.buffered() },
            ),
        }
    }
}

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

const Editor = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    file: File,
    viewport: Viewport,
    cursor: Cursor,

    pub fn init(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        file_name: []const u8,
        file_bytes: []const u8,
        row_count: u16,
        col_count: u16,
        options: struct { file_lines_max: u16 },
    ) !Editor {
        // File must not be empty, contain only ASCII, and end in newline.
        assert(file_bytes.len != 0);
        for (file_bytes) |byte| if (!std.ascii.isAscii(byte)) return error.FileNotAscii;
        if (file_bytes[file_bytes.len - 1] != '\n') return error.FileNotNewlineTerminated;

        var file: File = .{
            .name = file_name,
            .bytes = file_bytes,
            .lines = try .initCapacity(allocator, options.file_lines_max),
        };
        errdefer file.lines.deinit(allocator);
        indexLines(file_bytes, &file.lines);

        var viewport: Viewport = .{
            .row_count = row_count,
            .col_count = col_count,
            .first_line = 0,
            .gutter_width = 0,
        };
        viewport.updateGutterWidth(file.lines.items);

        return .{
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
            .file = file,
            .viewport = viewport,
            .cursor = .{ .offset = 0, .sticky_col = 0 },
        };
    }

    pub fn deinit(editor: *Editor) void {
        editor.file.lines.deinit(editor.allocator);
    }
};

const Cursor = struct {
    offset: u32,
    sticky_col: u16,
};

const Viewport = struct {
    row_count: u16,
    col_count: u16,
    first_line: u16, // line number of the top line
    gutter_width: u8, // cols to allow for line numbers (and delimiting whitespace)

    pub const Cell = struct {
        row: u16,
        col: u16,
    };

    pub fn render(
        viewport: Viewport,
        writer: *std.Io.Writer,
        cursor_position: File.Position,
        file: *const File,
    ) !void {
        const row_count = viewport.row_count;
        const col_count = viewport.col_count;
        const first_line = viewport.first_line;
        const gutter_width = viewport.gutter_width;
        const lines = file.lines.items;
        const file_bytes = file.bytes;
        const file_name = file.name;

        try writer.writeAll("\x1b[2J"); // clear screen
        try writer.writeAll("\x1b[H"); // place cursor at top left

        // The -1 below is to leave room for the status line.
        for (first_line..first_line + row_count - 1) |line_number| try writer.print(
            "{[line_number]d: >[gutter_width]} {[line]s}\r\n",
            .{
                .line_number = line_number + 1, // displayed line number indexed from 1
                .gutter_width = gutter_width - 1, // extra space of padding already in format string
                .line = if (line_number < lines.len) lines[line_number].slice(file_bytes) else "~",
            },
        );

        // Draw status line. Displayed line number and offset should be indexed from 1.
        const cursor_coordinates_col_count =
            digitCount(cursor_position.line_number + 1) +
            digitCount(cursor_position.line_offset + 1) +
            1; // the ',' in "{displayed_line_number},{displayed_line_offset}"
        assert(file_name.len < col_count - cursor_coordinates_col_count);
        const padding_col_count = col_count - file_name.len - cursor_coordinates_col_count;
        try writer.writeAll(file_name);
        try writer.splatByteAll(' ', padding_col_count);
        try writer.print("{d},{d}", .{
            cursor_position.line_number + 1,
            cursor_position.line_offset + 1,
        });

        // Make sure cursor is within the viewport's bounds.
        const cursor_cell = viewport.cellFrom(cursor_position, lines);
        assert(cursor_cell.col >= gutter_width); // right of line numbers
        assert(cursor_cell.col < col_count); // does not exceed screen bounds horizontally
        assert(cursor_cell.row < row_count); // does not exceed screen bounds vertically

        // Place the cursor (escape code indexes from 1): CSI rows ; cols H.
        try writer.print("\x1b[{d};{d}H", .{ cursor_cell.row + 1, cursor_cell.col + 1 });
        try writer.flush();
    }

    /// Update gutter width, enough digits for the greatest line number plus one for padding.
    pub fn updateGutterWidth(viewport: *Viewport, lines: []const Line) void {
        viewport.gutter_width = digitCount(@intCast(@max(viewport.row_count, lines.len))) + 1;
    }

    fn cellFrom(
        viewport: Viewport,
        position: File.Position,
        lines: []const Line,
    ) Cell {
        const row_count = viewport.row_count;
        const col_count = viewport.col_count;
        const first_line = viewport.first_line;
        const gutter_width = viewport.gutter_width;

        // TODO: Get line wrapping working later.
        for (first_line..first_line + row_count) |i| if (i < lines.len)
            assert(lines[i].tail - lines[i].head <= col_count);

        const row = position.line_number - first_line;
        const col = position.line_offset + gutter_width;
        assert(row < row_count);
        assert(col < col_count);

        return .{ .row = row, .col = col };
    }

    // Calculate index of last line in viewport.
    pub fn lastLine(viewport: Viewport) u16 {
        // The -2 below: -1 to go from count to index and another -1 for the status line.
        return viewport.first_line + viewport.row_count - 2;
    }
};

const File = struct {
    name: []const u8,
    bytes: []const u8,
    lines: std.ArrayList(Line),

    const Position = struct {
        line_number: u16, // zero-indexed
        line_offset: u16,

        pub fn move(
            position: Position,
            direction: enum { left, down, up, right },
            lines: []const Line,
        ) Position {
            const line_number = position.line_number;
            const line_offset = position.line_offset;
            const line = lines[line_number];

            switch (direction) {
                .left => return .{ .line_number = line_number, .line_offset = line_offset -| 1 },
                .right => if (line_offset + 1 < line.size()) return .{
                    .line_number = line_number,
                    .line_offset = line_offset + 1,
                },
                .up => if (line_number > 0) {
                    // Clamp the offset in case previous line is shorter than the current one.
                    // Subtract 1 to go from size to offset, saturated so we don't underflow in the
                    // case of an empty line.
                    const prev_line_end = lines[line_number - 1].size() -| 1;
                    return .{
                        .line_number = line_number - 1,
                        .line_offset = @intCast(
                            if (line_offset > prev_line_end) prev_line_end else line_offset,
                        ),
                    };
                },
                .down => if (line_number + 1 < lines.len) {
                    const next_line_end = lines[line_number + 1].size() -| 1;
                    return .{
                        .line_number = line_number + 1,
                        .line_offset = @intCast(
                            if (line_offset > next_line_end) next_line_end else line_offset,
                        ),
                    };
                },
            }
            return position;
        }
    };

    pub fn positionFrom(file: *const File, offset: u32) Position {
        for (file.lines.items, 0..) |line, line_number| {
            if (offset <= line.tail) return .{
                .line_number = @intCast(line_number),
                .line_offset = @intCast(offset - line.head),
            };
        } else @panic("Offset not within file bounds");
    }

    pub fn offsetFrom(file: *const File, position: Position) u32 {
        return file.lines.items[position.line_number].head + position.line_offset;
    }
};

const Line = struct {
    head: u32, // line start offset
    tail: u32, // line end offset (always a newline)

    pub fn slice(line: Line, file_bytes: []const u8) []const u8 {
        return file_bytes[line.head..line.tail];
    }

    pub fn size(line: Line) u32 {
        return line.tail - line.head;
    }
};

fn indexLines(file_bytes: []const u8, lines: *std.ArrayList(Line)) void {
    lines.clearRetainingCapacity();
    assert(file_bytes[file_bytes.len - 1] == '\n'); // make sure file is newline terminated
    var head: u32 = 0;
    while (head < file_bytes.len) {
        var tail = head;
        while (tail < file_bytes.len and file_bytes[tail] != '\n') tail += 1;
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

    var reader = std.Io.Reader.fixed(&.{});
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    var editor = Editor.init(
        std.testing.allocator,
        &reader,
        &writer.writer,
        "main.zig",
        file_buffer,
        row_count,
        col_count,
        .{ .file_lines_max = 1024 * 10 },
    ) catch |err| switch (err) {
        error.FileNotNewlineTerminated, error.FileNotAscii => return,
        else => return err,
    };
    defer editor.deinit();

    // TODO: Place cursor somewhere randomly.

    try editor.viewport.render(
        &writer.writer,
        editor.file.positionFrom(editor.cursor.offset),
        &editor.file,
    );
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
    var reader = std.Io.Reader.fixed(&.{});
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    var editor: Editor = try .init(
        std.testing.allocator,
        &reader,
        &writer.writer,
        "hello.c",
        hello_c,
        12,
        36,
        .{ .file_lines_max = 1024 * 10 },
    );
    defer editor.deinit();

    try editor.viewport.render(
        &writer.writer,
        editor.file.positionFrom(editor.cursor.offset),
        &editor.file,
    );
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
    var reader = std.Io.Reader.fixed(&.{});
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    var editor: Editor = try .init(
        std.testing.allocator,
        &reader,
        &writer.writer,
        "empty.zig",
        "\n",
        12,
        36,
        .{ .file_lines_max = 1024 * 10 },
    );
    defer editor.deinit();

    try editor.viewport.render(
        &writer.writer,
        editor.file.positionFrom(editor.cursor.offset),
        &editor.file,
    );
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

    indexLines(hello_c, &lines);
    try std.testing.expect(lines.items.len == 6);
    try std.testing.expect(lines.items[0].head == 0);
    try std.testing.expect(lines.items[0].tail == 18);
    try std.testing.expect(lines.getLast().tail == hello_c.len - 1);

    // This function should never be called with an empty slice. Empty files are handled by
    // inserting a single newline.
    const empty_file = "\n";
    indexLines(empty_file, &lines);
    try std.testing.expect(lines.items.len == 1);
    try std.testing.expect(lines.items[0].head == 0);
    try std.testing.expect(lines.items[0].tail == 0);
}

// This trick gets us the number of digits in a positive number: log_10(x) + 1.
fn digitCount(number: u16) u8 {
    return std.math.log10_int(number) + 1;
}

var termios_original: ?std.posix.termios = null;
// Wrap panic handler so that we can restore terminal state first. Calls default panic after
// cleanup. Cleanup logic runs only once. This prevents jank backtraces when we crash.
pub const panic = std.debug.FullPanic(struct {
    pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        @branchHint(.cold);
        // TODO: Worth draining stdin on panic so we don't get garbage input by the terminal cursor
        // once prior terminal restored?
        if (termios_original) |t| {
            termios_original = null; // so we only do this once
            var threaded: std.Io.Threaded = .init_single_threaded;
            // Disable KKP (CSI < u) and resize (CSI ? 2048 l) then exit alt screen (CSI ? 1049 l).
            std.Io.File.stdout().writeStreamingAll(
                threaded.io(),
                "\x1b[<u\x1b[?2048l\x1b[?1049l",
            ) catch {};
            std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, t) catch {}; // restore termios
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panic);
