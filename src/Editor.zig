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

pub const file_size_max = 1 * 1024 * 1024;
pub const line_count_max = 10_000;
pub const line_offset_max = 1_000;
pub const row_count_max = 2_000;
pub const col_count_max = 500;

// Calculating last visible line or offset should never overflow.
comptime {
    const line_number_max = line_count_max - 1;
    // row_count-1 is the last visible row but that's for the status line so use row_count-2.
    assert(line_number_max + row_count_max - 2 <= std.math.maxInt(u16));
    assert(line_offset_max - 1 + row_count_max - 2 <= std.math.maxInt(u16));
}

io: std.Io,
reader: *std.Io.Reader,
writer: *std.Io.Writer,

mode: enum { normal, insert, select },
dirty: bool = false,

// Viewport state:
viewport: struct {
    row_count: u16,
    col_count: u16,
    line_number_start: u16, // line number of the top line
    line_offset_start: u16, // viewport offset into lines (for horizontal scroll)
},
cursor: Cursor,

// File state:
name: []const u8,
buffer: std.ArrayList(u8),
lines: std.ArrayList(Line),

const Cursor = struct {
    // TODO: Maybe we should actually store the offset instead of the Position.
    head: Position,
    line_offset_snap: u16,

    const Direction = enum { up, down, left, right };

    fn moveOne(cursor: *Cursor, direction: Direction, lines: []const Line) void {
        switch (direction) {
            .left, .right => {
                const offset = cursor.head.toOffset(lines);
                const offset_new = @min(
                    if (direction == .left) offset -| 1 else offset +| 1,
                    lines[lines.len - 1].tail, // clamp to end of file
                );
                cursor.head = .fromOffset(offset_new, lines);
                cursor.line_offset_snap = cursor.head.line_offset;
            },
            .up, .down => {
                const line_number = cursor.head.line_number;
                cursor.head.line_number = @min(
                    if (direction == .up) line_number -| 1 else line_number +| 1,
                    lines.len - 1, // clamp to last line in file
                );
                // Clamp to line end if less than snap offset. Subtract 1 to go from size to offset.
                cursor.head.line_offset = @min(
                    cursor.line_offset_snap,
                    lines[cursor.head.line_number].size() - 1,
                );
            },
        }
    }

    fn moveMax(cursor: *Cursor, direction: Direction, lines: []const Line) void {
        const line_number = cursor.head.line_number;
        const line_offset = cursor.head.line_offset;
        const line = lines[line_number];
        switch (direction) {
            .left => cursor.move(.left, line_offset, lines),
            .right => cursor.move(.right, line.size() - 1 - line_offset, lines),
            .down => cursor.move(.down, @intCast(lines.len - line_number), lines),
            .up => cursor.move(.up, line_number, lines),
        }
    }

    // TODO: Build count back into move.
    fn move(cursor: *Cursor, direction: Direction, count: u32, lines: []const Line) void {
        for (0..count) |_| cursor.moveOne(direction, lines);
    }
};

const Error = error{
    CsiTooLong,
    FileEmpty,
    FileNotAscii,
    FileNotNewlineTerminated,
    FileTooManyLines,
    InvalidEscapeSequence,
    LineTooLong,
    ViewportTooLarge,
    ViewportTooSmall,
};

const Line = struct {
    head: u32, // line start offset
    tail: u32, // line end offset (always a newline)

    pub fn bytes(line: Line, file_bytes: []const u8) []const u8 {
        assert(file_bytes[line.tail] == '\n');
        return file_bytes[line.head..line.tail];
    }

    pub fn size(line: Line) u16 {
        const result: u16 = @intCast(line.tail - line.head + 1); // +1 for index -> count
        assert(result > 0);
        return result;
    }
};

/// Coordinate in the viewport.
const Cell = struct {
    row: u16,
    col: u16,
};

fn cellFromPosition(editor: *const Editor, position: Position) Cell {
    return .{
        .row = position.line_number - editor.viewport.line_number_start,
        .col = position.line_offset - editor.viewport.line_offset_start + editor.gutterWidth(),
    };
}

/// Coordinate in the file.
const Position = struct {
    line_number: u16,
    line_offset: u16,

    pub fn fromOffset(file_offset: u32, lines: []const Line) Position {
        // TODO: How much faster would binary search be?
        for (lines, 0..) |line, line_number| {
            if (file_offset <= line.tail) return .{
                .line_number = @intCast(line_number),
                .line_offset = @intCast(file_offset - line.head),
            };
        } else @panic("offset not within file bounds");
    }

    pub fn toOffset(position: Position, lines: []const Line) u32 {
        assert(position.line_offset < lines[position.line_number].size());
        return lines[position.line_number].head + position.line_offset;
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    file_name: []const u8,
    file_bytes: []const u8,
) !Editor {
    // File must not be empty, contain only ASCII, and end in newline.
    if (file_bytes.len == 0) return Error.FileEmpty;
    for (file_bytes) |byte| if (!std.ascii.isAscii(byte)) return Error.FileNotAscii;
    if (file_bytes[file_bytes.len - 1] != '\n') return Error.FileNotNewlineTerminated;

    var lines: std.ArrayList(Line) = try .initCapacity(allocator, line_count_max);
    errdefer lines.deinit(allocator);
    try indexLines(file_bytes, &lines);

    assert(file_bytes.len <= file_size_max);
    var buffer: std.ArrayList(u8) = try .initCapacity(allocator, file_size_max);
    errdefer buffer.deinit(allocator);
    buffer.appendSliceAssumeCapacity(file_bytes);

    var editor: Editor = .{
        .io = io,
        .reader = reader,
        .writer = writer,
        .mode = .normal,
        .viewport = .{
            .row_count = 0,
            .col_count = 0,
            .line_number_start = 0,
            .line_offset_start = 0,
        },
        .name = file_name,
        .buffer = buffer,
        .lines = lines,
        .cursor = .{
            .head = .{ .line_number = 0, .line_offset = 0 },
            .line_offset_snap = 0,
        },
    };

    // First input must be viewport dimensions.
    assert(try editor.tick());
    assert(editor.viewport.row_count != 0);
    assert(editor.viewport.col_count != 0);

    return editor;
}

pub fn deinit(editor: *Editor, allocator: std.mem.Allocator) void {
    editor.lines.deinit(allocator);
    editor.buffer.deinit(allocator);
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
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,

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

/// Handle input: parse Kitty Keyboard Protocol events.
fn parseOne(reader: *std.Io.Reader) !union(enum) {
    resize: struct { row_count: u16, col_count: u16 },
    ascii: u8,
    chord: struct { ascii: u8, modifiers: Modifiers },
    backspace,
    enter,
    escape,
    tab,
} {
    switch (try reader.takeByte()) {
        0x08, 0x7F => return .backspace,
        0x09 => return .tab,
        0x0D => return .enter,
        // Key events that produce text are sent directly as UTF-8 encyoded bytes.
        0x20...0x7E => |c| return .{ .ascii = c },
        // Control sequences start with CSI (0x1b 0x5b) and end with a character in the range,
        // 0x40-0x7E. See https://ghostty.org/docs/vt/concepts/sequences#escape-sequences.
        '\x1b' => { // CSI is ESC [ (0x1b 0x5b).
            assert(try reader.takeByte() == '[');

            var params_buffer: [32]u8 = undefined;
            var params_index: usize = 0;
            // Read until the final byte so we have all that remains of the escape sequence.
            const final = while (true) : (params_index += 1) switch (try reader.takeByte()) {
                0x30...0x3F => |byte| {
                    if (params_index == params_buffer.len) return Error.CsiTooLong;
                    params_buffer[params_index] = byte;
                },
                0x40...0x7E => |final_byte| break final_byte,
                else => @panic("escape sequence contains character outside 0x20-0x7E"),
            };

            const params = params_buffer[0..params_index];
            var iter = std.mem.splitScalar(u8, params, ';');
            const first_str = iter.next() orelse @panic("escape sequence has no parameters");
            const first = try std.fmt.parseInt(i32, first_str, 10);
            switch (final) {
                'u' => switch (first) {
                    0x1b => return .escape,
                    // Printable ASCII with modifiers. Codepoints must be the lowercase variant.
                    0x20...0x7E => |c| return .{ .chord = .{
                        .ascii = @intCast(switch (c) {
                            'A'...'Z' => @panic("CSI u unicode-key-code must be unshifted"),
                            else => c,
                        }),
                        .modifiers = try .decode(
                            iter.next() orelse @panic("CSI u sequence missing modifiers"),
                        ),
                    } },
                    else => {}, // fall through to panic
                },
                't' => switch (first) {
                    // Resize: CSI 48 ; height_chars ; width_chars ; height_pix ; width_pix t.
                    48 => return .{
                        .resize = .{
                            .row_count = try std.fmt.parseInt(u16, iter.next().?, 10),
                            .col_count = try std.fmt.parseInt(u16, iter.next().?, 10),
                        },
                    },
                    else => return Error.InvalidEscapeSequence,
                },
                else => return Error.InvalidEscapeSequence,
            }
            unreachable;
        },
        else => return Error.InvalidEscapeSequence,
    }
}

// TODO: Add function for inserting slices so we don't have to do:
// `for (count) |_| try editor.insert(c);`.
fn insert(editor: *Editor, character: u8) !void {
    const offset = editor.cursor.head.toOffset(editor.lines.items);
    try editor.buffer.insertBounded(offset, character);
    try indexLines(editor.buffer.items, &editor.lines);
    editor.cursor.moveOne(.right, editor.lines.items);
    editor.dirty = true;
}

fn indentCount(editor: *const Editor) u16 {
    const line = editor.lines.items[editor.cursor.head.line_number];
    var i = line.head;
    while (editor.buffer.items[i] == ' ') i += 1;
    return @intCast(i - line.head);
}

fn textFamily(c: u8) enum { whitespace, symbols, word } {
    return switch (c) {
        '\n' => .whitespace,
        0x20...0x7E => switch (c) { // printable ASCII range
            ' ' => .whitespace,
            '_' => .word,
            '0'...'9' => .word,
            'a'...'z' => .word,
            'A'...'Z' => .word,
            else => .symbols,
        },
        else => unreachable,
    };
}

/// Find the end of the current word. Along with normal words, sequences of whitespace count as a
/// word, as do sequences of symbols.
fn anyWordTail(buffer: []const u8, offset: u32) u32 {
    assert(offset < buffer.len);
    const family = textFamily(buffer[offset]);
    for (buffer[offset..], offset..) |c, i| {
        if (textFamily(c) != family) return @intCast(i - 1);
    } else return @intCast(buffer.len);
}

fn wordTail(buffer: []const u8, offset: u32) u32 {
    assert(offset < buffer.len);
    const tail = anyWordTail(buffer, offset);
    if (tail >= buffer.len - 1) return @intCast(buffer.len - 1); // end of file
    const family = textFamily(buffer[tail]);
    if (family == .whitespace) return anyWordTail(buffer, tail + 1) else return tail;
}

pub fn tick(editor: *Editor) !bool {
    const input = try parseOne(editor.reader);
    if (input == .resize) {
        editor.viewport.row_count = input.resize.row_count;
        editor.viewport.col_count = input.resize.col_count;
    } else switch (editor.mode) {
        .normal => switch (input) {
            .ascii => |c| switch (c) {
                'q' => return false, // quit
                'h' => editor.cursor.moveOne(.left, editor.lines.items),
                'l' => editor.cursor.moveOne(.right, editor.lines.items),
                'j' => editor.cursor.moveOne(.down, editor.lines.items),
                'k' => editor.cursor.moveOne(.up, editor.lines.items),
                '0' => editor.cursor.moveMax(.left, editor.lines.items),
                '$' => editor.cursor.moveMax(.right, editor.lines.items),
                'G' => editor.cursor.moveMax(.down, editor.lines.items),
                'g' => editor.cursor.moveMax(.up, editor.lines.items),
                'e' => {
                    editor.cursor.moveOne(.right, editor.lines.items);
                    const offset = editor.cursor.head.toOffset(editor.lines.items);
                    const word_tail = wordTail(editor.buffer.items, offset);
                    editor.cursor.move(.right, word_tail - offset, editor.lines.items);
                },
                'i' => editor.mode = .insert,
                'I' => {
                    const indent_count = editor.indentCount();
                    editor.cursor.moveMax(.left, editor.lines.items);
                    editor.cursor.move(.right, indent_count, editor.lines.items);
                    editor.mode = .insert;
                },
                'a' => {
                    editor.cursor.moveOne(.right, editor.lines.items);
                    editor.mode = .insert;
                },
                'A' => {
                    editor.cursor.moveMax(.right, editor.lines.items);
                    editor.mode = .insert;
                },
                'o' => {
                    const indent_count = editor.indentCount();
                    editor.cursor.moveMax(.right, editor.lines.items);
                    editor.mode = .insert;
                    try editor.insert('\n');
                    for (0..indent_count) |_| try editor.insert(' ');
                },
                'O' => {
                    const indent_count = editor.indentCount();
                    editor.cursor.moveMax(.left, editor.lines.items);
                    editor.mode = .insert;
                    try editor.insert('\n');
                    editor.cursor.moveOne(.up, editor.lines.items);
                    for (0..indent_count) |_| try editor.insert(' ');
                },
                else => {},
            },
            .chord => |chord| {
                const lines = editor.lines.items;
                const scroll = editor.viewport.row_count / 2;
                const ctrl: Modifiers = .{ .ctrl = true };
                const mod = chord.modifiers;
                switch (chord.ascii) {
                    'u' => if (mod == ctrl) editor.cursor.move(.up, scroll, lines),
                    'd' => if (mod == ctrl) editor.cursor.move(.down, scroll, lines),
                    'w' => if (mod == ctrl) {
                        try std.Io.Dir.cwd().writeFile(editor.io, .{
                            .data = editor.buffer.items,
                            .sub_path = editor.name,
                        });
                        editor.dirty = false;
                    },
                    else => {},
                }
            },
            .backspace,
            .enter,
            .escape,
            .tab,
            => {}, // do nothing
            .resize => unreachable,
        },
        .insert => switch (input) {
            .escape => editor.mode = .normal,
            .ascii => |c| try editor.insert(c),
            .backspace => if (editor.cursor.head.toOffset(editor.lines.items) != 0) {
                editor.cursor.moveOne(.left, editor.lines.items);
                const offset = editor.cursor.head.toOffset(editor.lines.items);
                _ = editor.buffer.orderedRemove(offset);
                try indexLines(editor.buffer.items, &editor.lines);
                editor.dirty = true;
            },
            .tab => for (0..4) |_| try editor.insert(' '),
            .enter => {
                const indent_count = editor.indentCount();
                try editor.insert('\n');
                for (0..indent_count) |_| try editor.insert(' ');
            },
            .chord => {}, // do nothing
            .resize => unreachable,
        },
        .select => {},
    }

    // Check viewport dimensions.
    const row_count = editor.viewport.row_count;
    const col_count = editor.viewport.col_count;
    if (row_count < 2) return Error.ViewportTooSmall; // at least one line plus the status line
    if (row_count > row_count_max) return Error.ViewportTooLarge;
    if (col_count < editor.gutterWidth() + 1) return Error.ViewportTooSmall; // at least one char
    if (col_count > col_count_max) return Error.ViewportTooLarge;

    // Cursor must be within viewport. Adjust viewport if necessary.
    const last_line = editor.lastLine();
    if (editor.cursor.head.line_number < editor.viewport.line_number_start) {
        editor.viewport.line_number_start = editor.cursor.head.line_number;
    } else if (editor.cursor.head.line_number > last_line) {
        editor.viewport.line_number_start += editor.cursor.head.line_number - last_line;
    }
    const last_offset = editor.lastOffset();
    if (editor.cursor.head.line_offset < editor.viewport.line_offset_start) {
        editor.viewport.line_offset_start = editor.cursor.head.line_offset;
    } else if (editor.cursor.head.line_offset > last_offset) {
        editor.viewport.line_offset_start += editor.cursor.head.line_offset - last_offset;
    }

    assert(editor.cursor.head.line_offset <= editor.cursor.line_offset_snap);

    // Make sure cursor is within the viewport's bounds.
    const line_number_start = editor.viewport.line_number_start;
    const line_offset_start = editor.viewport.line_offset_start;
    assert(editor.cursor.head.line_number >= line_number_start);
    assert(editor.cursor.head.line_number <= editor.lastLine());
    assert(editor.cursor.head.line_offset >= line_offset_start);
    assert(editor.cursor.head.line_offset <= editor.lastOffset());
    const cursor_cell = editor.cellFromPosition(editor.cursor.head);
    assert(cursor_cell.col >= editor.gutterWidth()); // right of line numbers
    assert(cursor_cell.col < col_count); // does not exceed screen bounds horizontally
    assert(cursor_cell.row < row_count); // does not exceed screen bounds vertically

    try editor.render();

    return true;
}

fn render(editor: *const Editor) !void {
    const writer = editor.writer;
    const row_count = editor.viewport.row_count;
    const col_count = editor.viewport.col_count;
    const line_number_start = editor.viewport.line_number_start;
    const line_offset_start = editor.viewport.line_offset_start;
    const file_bytes = editor.buffer.items;
    const file_name = editor.name;
    const lines = editor.lines.items;
    const cursor_head = editor.cursor.head;

    const gutter_width = editor.gutterWidth();

    // Clear screen. See https://ghostty.org/docs/vt/csi/ed.
    try writer.writeAll("\x1b[2J");
    // Place cursor at top left. See https://ghostty.org/docs/vt/csi/cup.
    try writer.writeAll("\x1b[H");

    // The -1 below is to leave room for the status line.
    for (line_number_start..line_number_start + row_count - 1) |line_number| {
        const line = if (line_number < lines.len) blk: {
            const line_full = lines[line_number].bytes(file_bytes);
            if (line_offset_start > line_full.len) break :blk "";
            const line = line_full[line_offset_start..];
            const line_size = @min(line.len, col_count - gutter_width);
            break :blk line_full[line_offset_start .. line_offset_start + line_size];
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
        digitCount(cursor_head.line_number + 1) +
        digitCount(cursor_head.line_offset + 1) +
        1; // the ',' in "{displayed_line_number},{displayed_line_offset}"
    var min_size = file_name.len;
    const dirty_indicator = " [+]";
    if (editor.dirty) min_size += dirty_indicator.len;
    min_size += cursor_coordinates_col_count + 1; // 1 for padding
    if (min_size > col_count) return Error.ViewportTooSmall;

    try writer.writeAll(file_name);
    if (editor.dirty) try writer.writeAll(dirty_indicator);
    try writer.splatByteAll(' ', col_count - min_size);
    try writer.print(" {d},{d}", .{ cursor_head.line_number + 1, cursor_head.line_offset + 1 });

    // Restore and style cursor. See https://ghostty.org/docs/vt/csi/decscusr.
    const cursor_cell = editor.cellFromPosition(cursor_head);
    const cursor_style: u8 = switch (editor.mode) {
        .normal,
        .select,
        => 2, // steady block
        .insert => 6, // steady vertical bar
    };
    try writer.print("\x1b[{d}\x20q", .{cursor_style});
    try writer.print("\x1b[{d};{d}H", .{ cursor_cell.row + 1, cursor_cell.col + 1 });

    try writer.flush();
}

/// Last line number visible in the viewport.
fn lastLine(editor: *const Editor) u16 {
    // The extra -1 is for the status line.
    return editor.viewport.line_number_start + editor.viewport.row_count - 2;
}

/// Last line offset (col) visible in the viewport.
fn lastOffset(editor: *const Editor) u16 {
    const text_width = editor.viewport.col_count - editor.gutterWidth();
    return editor.viewport.line_offset_start + text_width - 1;
}

fn gutterWidth(editor: *const Editor) u8 {
    // Determine gutter width, enough digits for the greatest line number plus one for padding.
    return digitCount(@intCast(@max(editor.viewport.row_count, editor.lines.items.len))) + 1;
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
    } else @panic("offset not within file bounds");
}

fn indexLines(file_bytes: []const u8, lines: *std.ArrayList(Line)) !void {
    assert(file_bytes[file_bytes.len - 1] == '\n'); // make sure file is newline terminated

    lines.clearRetainingCapacity();
    var head: u32 = 0;
    while (head < file_bytes.len) {
        var tail = head;
        while (tail < file_bytes.len and file_bytes[tail] != '\n') tail += 1;
        if (tail - head > line_offset_max) return Error.LineTooLong;
        if (lines.items.len == line_count_max) return Error.FileTooManyLines;
        lines.appendAssumeCapacity(.{ .head = head, .tail = tail });
        head = tail + 1;
    }

    assert(lines.items[0].head == 0);
    assert(lines.last().?.tail == file_bytes.len - 1);
}

test fuzzer {
    return std.testing.fuzz({}, fuzzer, .{});
}
fn fuzzer(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const file_size = smith.valueRangeAtMost(u32, 0, file_size_max);
    const file_buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(file_buffer);
    smith.bytes(file_buffer);

    // TODO: Is this big enough? Make it look more like a path?
    const file_name_size = smith.value(u8);
    const file_name_buffer = try allocator.alloc(u8, file_name_size);
    defer allocator.free(file_name_buffer);
    smith.bytes(file_name_buffer);

    const row_count = smith.valueRangeAtMost(u16, 0, row_count_max);
    const col_count = smith.valueRangeAtMost(u16, 0, col_count_max);

    var input: std.Io.Writer.Allocating = .init(allocator);
    defer input.deinit();
    // TODO: Sometimes don't generate resize?
    // First input must be resize (parsed during init below for dimensions).
    try input.writer.print("\x1b[48;{d};{d};0;0t", .{ row_count, col_count }); // pix values ignored
    const input_size = smith.valueRangeAtMost(u16, 0, 4 * 1024); // 4 KiB input max
    for (0..input_size) |_| try input.writer.writeByte(smith.value(u8));
    try input.writer.writeByte('q'); // clean exit
    var reader: std.Io.Reader = .fixed(input.written());
    var writer: std.Io.Writer.Discarding = .init(&.{});

    var editor = Editor.init(
        allocator,
        io,
        &reader,
        &writer.writer,
        file_name_buffer,
        file_buffer,
    ) catch |err| switch (err) {
        Error.FileEmpty,
        Error.FileNotAscii,
        Error.FileNotNewlineTerminated,
        Error.FileTooManyLines,
        Error.LineTooLong,
        Error.ViewportTooLarge,
        Error.ViewportTooSmall,
        => return,
        else => return err,
    };
    defer editor.deinit(allocator);

    while (editor.tick() catch |err| switch (err) {
        Error.InvalidEscapeSequence,
        Error.ViewportTooLarge,
        Error.ViewportTooSmall,
        => return,
        else => return err,
    }) continue;
}

// test "fuzz repro" {
//     try std.testing.fuzz({}, fuzzer, .{ .corpus = &.{@embedFile("crash")} });
// }

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

const test_input = "\x1b[48;12;36;0;0t" // dimensions: 12 rows by 36 cols
    ++ "q"; // quit after first render

const StrippingWriter = struct {
    out: std.Io.Writer.Allocating,
    interface: std.Io.Writer,

    fn init(allocator: std.mem.Allocator) !StrippingWriter {
        return .{
            .out = .init(allocator),
            .interface = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
        };
    }

    fn deinit(stripping: *StrippingWriter) void {
        stripping.out.deinit();
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const stripping: *StrippingWriter = @alignCast(@fieldParentPtr("interface", w));

        var write_size: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            for (slice) |byte| if (byte != '\r') try stripping.out.writer.writeByte(byte);
            write_size += slice.len;
        }

        const splat_slice = data[data.len - 1];
        for (0..splat) |_| {
            for (splat_slice) |byte| if (byte != '\r') try stripping.out.writer.writeByte(byte);
        }
        return write_size + splat_slice.len * splat;
    }

    pub fn writer(stripping: *StrippingWriter) *std.Io.Writer {
        return &stripping.interface;
    }

    pub fn written(stripping: *StrippingWriter) []const u8 {
        return stripping.out.written();
    }
};

test "rendering: hello_c" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed(test_input);
    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expect(try editor.tick() == false); // last tick: reports false on quit
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
    ++ "\x1b[2\x20q" // set cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates at start of file: 0, 3 (but indexed from 1)
    , stripping.written());
}

test "rendering: empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed(test_input);
    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "empty.zig", "\n");
    defer editor.deinit(allocator);

    try std.testing.expect(try editor.tick() == false);

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
    ++ "\x1b[2\x20q" // set cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates at start of file: 0, 3 (but indexed from 1)
    , stripping.written());
}

test "go to start/end of file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader = std.Io.Reader.fixed("\x1b[48;5;36;0;0t" ++ // dimensions: 5 rows by 36 cols
        "G" ++ // go to end of file
        "g" ++ // go to start of file
        "q"); // quit
    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\1 #include <stdio.h>
        \\2 
        \\3 int main() {
        \\4   printf("Hello, world!\n");
        \\hello.c                          1,1
    ++ "\x1b[2\x20q" // set cursor style (steady block)
    ++ "\x1b[1;3H" // cursor coordinates at start of file: 0, 2 (but indexed from 1)
    , stripping.written());

    stripping.out.clearRetainingCapacity(); // clear what we've written
    try std.testing.expect(try editor.tick() == true); // process the G
    try std.testing.expectEqualSlices(u8, "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\3 int main() {
        \\4   printf("Hello, world!\n");
        \\5   return 0;
        \\6 }
        \\hello.c                          6,1
    ++ "\x1b[2\x20q" // set cursor style (steady block)
    ++ "\x1b[4;3H" // cursor coordinates at end of file: 3, 2 (but indexed from 1)
    , stripping.written());

    stripping.out.clearRetainingCapacity(); // clear what we've written
    try std.testing.expect(try editor.tick() == true); // process the g
    try std.testing.expectEqualSlices(u8, "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\1 #include <stdio.h>
        \\2 
        \\3 int main() {
        \\4   printf("Hello, world!\n");
        \\hello.c                          1,1
    ++ "\x1b[2\x20q" // set cursor style (steady block)
    ++ "\x1b[1;3H" // cursor coordinates at start of file: 0, 2 (but indexed from 1)
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // process the q, exited
}

test "go to start/end of line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader = std.Io.Reader.fixed("\x1b[48;12;12;0;0t" ++ // dimensions: 12 rows by 12 cols
        "$" ++ // go to end of line
        "0" ++ // go to start of line
        "q"); // quit
    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 #include 
        \\ 2 
        \\ 3 int main(
        \\ 4   printf(
        \\ 5   return 
        \\ 6 }
        \\ 7 ~
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c  1,1
    ++ "\x1b[2\x20q" // set cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates at start of file: 0, 2 (but indexed from 1)
    , stripping.written());

    stripping.out.clearRetainingCapacity(); // clear what we've written
    try std.testing.expect(try editor.tick() == true); // process the $
    try std.testing.expectEqualSlices(u8, "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 stdio.h>
        \\ 2 
        \\ 3  {
        \\ 4 Hello, wo
        \\ 5 ;
        \\ 6 
        \\ 7 ~
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c 1,19
    ++ "\x1b[2\x20q" // set cursor style (steady block)
    ++ "\x1b[1;12H" // cursor coordinates at end of line: 0, 11 (but indexed from 1)
    , stripping.written());

    stripping.out.clearRetainingCapacity(); // clear what we've written
    try std.testing.expect(try editor.tick() == true); // process the 0
    try std.testing.expectEqualSlices(u8, "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 #include 
        \\ 2 
        \\ 3 int main(
        \\ 4   printf(
        \\ 5   return 
        \\ 6 }
        \\ 7 ~
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c  1,1
    ++ "\x1b[2\x20q" // set cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates at start of file: 0, 2 (but indexed from 1)
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // process the q, exited
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
    try std.testing.expect(lines.items[0].size() == 19);
    try std.testing.expect(lines.last().?.tail == hello_c.len - 1);

    // This function should never be called with an empty slice. Empty files are handled by
    // inserting a single newline.
    const empty_file = "\n";
    try indexLines(empty_file, &lines);
    try std.testing.expect(lines.items.len == 1);
    try std.testing.expect(lines.items[0].head == 0);
    try std.testing.expect(lines.items[0].tail == 0);
    try std.testing.expect(lines.items[0].size() == 1);
}
