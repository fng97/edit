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

prompt_buffer: [std.math.maxInt(u8)]u8 = undefined,
mode: union(enum) {
    normal,
    insert,
    prompt: struct { buffer: std.ArrayList(u8), cursor_offset: u8 },
},
dirty: bool = false,

// Viewport state:
viewport: Viewport,
cursor: Cursor,

// File state:
name: []const u8,
buffer: std.ArrayList(u8),

pub fn tick(editor: *Editor) !bool {
    const input = try parseOne(editor.reader);
    if (input == .resize) {
        editor.viewport.row_count = input.resize.row_count;
        editor.viewport.col_count = input.resize.col_count;
    } else switch (editor.mode) {
        .normal => switch (input) {
            .ascii => |c| switch (c) {
                'q' => return false, // quit
                'h' => editor.cursor.move(.left, 1, editor.buffer.items),
                'l' => editor.cursor.move(.right, 1, editor.buffer.items),
                'j' => editor.cursor.move(.down, 1, editor.buffer.items),
                'k' => editor.cursor.move(.up, 1, editor.buffer.items),
                '0' => editor.cursor.moveMax(.left, editor.buffer.items),
                '$' => editor.cursor.moveMax(.right, editor.buffer.items),
                'G' => editor.cursor.moveMax(.down, editor.buffer.items),
                'g' => editor.cursor.moveMax(.up, editor.buffer.items),
                'e' => editor.cursor.update(
                    editor.buffer.items,
                    wordTailNext(editor.buffer.items, editor.cursor.offset),
                    .snap_update,
                ),
                'E' => editor.cursor.update(
                    editor.buffer.items,
                    tokenTailNext(editor.buffer.items, editor.cursor.offset),
                    .snap_update,
                ),
                'b' => editor.cursor.update(
                    editor.buffer.items,
                    wordHeadPrev(editor.buffer.items, editor.cursor.offset),
                    .snap_update,
                ),
                'B' => editor.cursor.update(
                    editor.buffer.items,
                    tokenHeadPrev(editor.buffer.items, editor.cursor.offset),
                    .snap_update,
                ),
                'w' => editor.cursor.update(
                    editor.buffer.items,
                    wordHeadNext(editor.buffer.items, editor.cursor.offset),
                    .snap_update,
                ),
                'W' => editor.cursor.update(
                    editor.buffer.items,
                    tokenHeadNext(editor.buffer.items, editor.cursor.offset),
                    .snap_update,
                ),
                'i' => editor.mode = .insert,
                'I' => {
                    const offset = lineHead(editor.buffer.items, editor.cursor.offset) +
                        lineIndentation(editor.buffer.items, editor.cursor.offset);
                    editor.cursor.update(editor.buffer.items, offset, .snap_update);
                    editor.mode = .insert;
                },
                'a' => {
                    editor.cursor.move(.right, 1, editor.buffer.items);
                    editor.mode = .insert;
                },
                'A' => {
                    editor.cursor.moveMax(.right, editor.buffer.items);
                    editor.mode = .insert;
                },
                'o' => {
                    editor.cursor.moveMax(.right, editor.buffer.items);
                    const indentation = lineIndentation(editor.buffer.items, editor.cursor.offset);
                    try editor.insert("\n");
                    for (0..indentation) |_| try editor.insert(" ");
                    editor.mode = .insert;
                },
                'O' => {
                    editor.cursor.moveMax(.left, editor.buffer.items);
                    const indentation = lineIndentation(editor.buffer.items, editor.cursor.offset);
                    try editor.insert("\n");
                    editor.cursor.move(.up, 1, editor.buffer.items);
                    for (0..indentation) |_| try editor.insert(" ");
                    editor.mode = .insert;
                },
                // Enable/disable selection.
                'v' => editor.cursor.anchor =
                    if (editor.cursor.anchor != null) null else editor.cursor.offset,
                'd' => {
                    const selection_head = if (editor.cursor.anchor) |anchor| @min(
                        editor.cursor.offset,
                        anchor,
                    ) else editor.cursor.offset;
                    try editor.delete();
                    editor.cursor.update(editor.buffer.items, selection_head, .snap_update);
                },
                ':' => {
                    for (&editor.prompt_buffer) |*byte| byte.* = undefined;
                    editor.mode = .{
                        .prompt = .{
                            .buffer = .initBuffer(&editor.prompt_buffer),
                            .cursor_offset = 0,
                        },
                    };
                },
                else => {},
            },
            .chord => |chord| {
                const scroll = editor.viewport.row_count / 2;
                const ctrl: Modifiers = .{ .ctrl = true };
                const mod = chord.modifiers;
                switch (chord.ascii) {
                    'u' => if (mod == ctrl) editor.cursor.move(.up, scroll, editor.buffer.items),
                    'd' => if (mod == ctrl) editor.cursor.move(.down, scroll, editor.buffer.items),
                    else => {},
                }
            },
            .escape => editor.cursor.anchor = null,
            .backspace,
            .enter,
            .tab,
            => {}, // do nothing
            .resize => unreachable,
        },
        .insert => {
            editor.cursor.anchor = null;
            switch (input) {
                .escape => editor.mode = .normal,
                .ascii => |c| try editor.insert(&.{c}),
                .backspace => if (editor.cursor.offset != 0) {
                    editor.cursor.move(.left, 1, editor.buffer.items);
                    try editor.delete();
                },
                .tab => try editor.insert("    "),
                .enter => {
                    const indent_count = lineIndentation(editor.buffer.items, editor.cursor.offset);
                    try editor.insert("\n");
                    for (0..indent_count) |_| try editor.insert(" ");
                },
                .chord => {}, // do nothing
                .resize => unreachable,
            }
        },
        .prompt => |*prompt| switch (input) {
            .escape => editor.mode = .normal,
            .ascii => |c| {
                assert(prompt.cursor_offset == prompt.buffer.items.len);
                try prompt.buffer.insertBounded(prompt.cursor_offset, c);
                prompt.cursor_offset += 1;
                assert(prompt.cursor_offset == prompt.buffer.items.len);
            },
            .backspace => if (prompt.cursor_offset != 0) {
                assert(prompt.cursor_offset == prompt.buffer.items.len);
                _ = prompt.buffer.orderedRemove(prompt.cursor_offset - 1);
                prompt.cursor_offset -= 1;
                assert(prompt.cursor_offset == prompt.buffer.items.len);
            },
            .enter => {
                if (std.mem.eql(u8, "w", prompt.buffer.items)) {
                    try editor.save();
                } else if (std.mem.eql(u8, "q", prompt.buffer.items)) {
                    return false;
                } else if (std.mem.eql(u8, "wq", prompt.buffer.items)) {
                    try editor.save();
                    return false;
                }
                // TODO: Error if command not recognised.
                editor.mode = .normal;
            },
            .tab, .chord => {}, // do nothing
            .resize => unreachable,
        },
    }

    const buffer = editor.buffer.items;
    const offset = editor.cursor.offset;
    const line_number = lineNumber(buffer, offset);
    const line_offset = lineOffset(buffer, offset);
    const row_count = editor.viewport.row_count;
    const col_count = editor.viewport.col_count;

    // Check viewport dimensions.
    if (row_count < 2) return Error.ViewportTooSmall; // at least one line plus the status line
    if (row_count > row_count_max) return Error.ViewportTooLarge;
    if (col_count < editor.viewport.gutterWidth() + 1)
        return Error.ViewportTooSmall; // at least one char
    if (col_count > col_count_max) return Error.ViewportTooLarge;

    // If cursor moved out of viewport, move viewport.
    const last_line = editor.viewport.lastLine();
    if (line_number < editor.viewport.line_number_start) {
        editor.viewport.line_number_start = line_number;
    } else if (line_number > last_line) {
        editor.viewport.line_number_start += line_number - last_line;
    }
    const last_offset = editor.viewport.lastOffset();
    if (line_offset < editor.viewport.line_offset_start) {
        editor.viewport.line_offset_start = line_offset;
    } else if (line_offset > last_offset) {
        editor.viewport.line_offset_start += line_offset - last_offset;
    }

    // Cursor is always at snap line offset or line end.
    assert(line_offset == @min(editor.cursor.line_offset_snap, lineSize(buffer, offset) - 1));
    assert(line_offset <= editor.cursor.line_offset_snap);

    // Make sure cursor is within the viewport's bounds.
    assert(line_number >= editor.viewport.line_number_start);
    assert(line_number <= editor.viewport.lastLine());
    assert(line_offset >= editor.viewport.line_offset_start);
    assert(line_offset <= editor.viewport.lastOffset());

    try editor.render(.{ .line_number = line_number, .line_offset = line_offset });

    return true;
}

fn render(editor: *const Editor, cursor: Position) !void {
    const writer = editor.writer;
    const row_count = editor.viewport.row_count;
    const col_count = editor.viewport.col_count;
    const gutter_width = editor.viewport.gutterWidth();
    const line_number_start = editor.viewport.line_number_start;
    const line_offset_start = editor.viewport.line_offset_start;
    const buffer = editor.buffer.items;
    const file_name = editor.name;

    try writer.writeAll("\x1b[?2026h"); // begin synchronised update
    // Clear screen. See https://ghostty.org/docs/vt/csi/ed.
    try writer.writeAll("\x1b[2J");
    // Place cursor at top left. See https://ghostty.org/docs/vt/csi/cup.
    try writer.writeAll("\x1b[H");

    // Render the buffer.
    assert(buffer.len > 0);
    var line_head = blk: {
        var i: u32 = lineHead(buffer, editor.cursor.offset);
        for (0..cursor.line_number - line_number_start) |_| i = lineHead(buffer, i - 1);
        break :blk i;
    };
    var highlight = false;
    for (line_number_start..line_number_start + row_count - 1) |line_number| {
        try writer.print("{[line_number]d: >[gutter_width]} ", .{ // draw gutter
            .line_number = line_number + 1, // displayed line number indexed from 1
            .gutter_width = gutter_width - 1, // space suffix already in format string
        });

        if (line_head < buffer.len) {
            const line_tail = lineTail(buffer, line_head);

            // Handle horizontal scroll.
            const text_width = col_count - gutter_width;
            const cropped_head = @min(line_head + line_offset_start, line_tail);
            const cropped_tail = @min(line_tail, cropped_head + text_width);

            // Handle selection highlighting.
            if (editor.cursor.anchor) |anchor| {
                const esc_highlight =
                    "\x1b[38;2;40;40;40m" ++ // dark foreground
                    "\x1b[48;2;200;200;200m"; // light gray background
                const esc_reset = "\x1b[0m"; // reset
                const highlight_head = @min(anchor, editor.cursor.offset);
                const highlight_tail = @max(anchor, editor.cursor.offset);

                // Should we have already started/stopped highlighting? E.g. anchor not within
                // cropped line.
                if (highlight_head < cropped_head) highlight = true;
                if (highlight_tail < cropped_head) highlight = false;

                if (highlight) try writer.writeAll(esc_highlight);

                for (cropped_head..cropped_tail) |offset| {
                    if (offset == highlight_head) {
                        highlight = true;
                        try writer.writeAll(esc_highlight);
                    }

                    try writer.writeByte(buffer[offset]);

                    if (offset == highlight_tail) {
                        highlight = false;
                        try writer.writeAll(esc_reset);
                    }
                }

                // Reset before printing the next line so that line numbers aren't highlighted.
                if (highlight) try writer.writeAll(esc_reset);
            } else try writer.writeAll(buffer[cropped_head..cropped_tail]); // strips newline

            line_head = line_tail + 1;
        } else try writer.writeByte('~');
        try writer.writeAll("\r\n");
    }

    // Draw final row: status line or prompt.
    switch (editor.mode) {
        // Draw status line. Displayed line number and offset should be indexed from 1.
        .insert, .normal => {
            const cursor_coordinates_col_count =
                digitCount(cursor.line_number + 1) +
                digitCount(cursor.line_offset + 1) +
                1; // the ',' in "{displayed_line_number},{displayed_line_offset}"
            var min_size = file_name.len;
            const dirty_indicator = " [+]";
            if (editor.dirty) min_size += dirty_indicator.len;
            min_size += cursor_coordinates_col_count + 1; // 1 for padding
            if (min_size > col_count) return Error.ViewportTooSmall;

            try writer.writeAll(file_name);
            if (editor.dirty) try writer.writeAll(dirty_indicator);
            try writer.splatByteAll(' ', col_count - min_size);
            try writer.print(" {d},{d}", .{ cursor.line_number + 1, cursor.line_offset + 1 });
        },
        // Draw prompt. Takes place of status line.
        .prompt => |prompt| {
            try writer.writeByte(':');
            try writer.writeAll(prompt.buffer.items);
        },
    }

    // Restore cursor.
    const cursor_style: u8 = switch (editor.mode) {
        .normal => 2, // steady block
        .prompt, .insert => 6, // steady vertical bar
    };
    // Restore and style cursor. See https://ghostty.org/docs/vt/csi/decscusr.
    try writer.print("\x1b[{d}\x20q", .{cursor_style});
    var cursor_cell: Viewport.Cell = undefined;
    switch (editor.mode) {
        .normal, .insert => {
            cursor_cell = .{
                .row = cursor.line_number - line_number_start,
                .col = cursor.line_offset - line_offset_start + gutter_width,
            };
            assert(cursor_cell.col >= gutter_width); // right of line numbers
        },
        .prompt => |prompt| cursor_cell = .{
            .row = editor.viewport.row_count - 1, // final row
            .col = prompt.cursor_offset + 1, // +1 for the ':' prompt prefix
        },
    }
    assert(cursor_cell.col < col_count); // does not exceed screen bounds horizontally
    assert(cursor_cell.row < row_count); // does not exceed screen bounds vertically
    try writer.print("\x1b[{d};{d}H", .{ cursor_cell.row + 1, cursor_cell.col + 1 });
    try writer.writeAll("\x1b[?2026l"); // end synchronised update

    try writer.flush();
}

fn save(editor: *Editor) !void {
    try std.Io.Dir.cwd().writeFile(editor.io, .{
        .data = editor.buffer.items,
        .sub_path = editor.name,
    });
    editor.dirty = false;
}

const Position = struct { line_number: u16, line_offset: u16 };

const Viewport = struct {
    row_count: u16,
    col_count: u16,
    line_number_start: u16, // line number of the top line
    line_offset_start: u16, // viewport offset into lines (for horizontal scroll)

    /// Coordinate in the viewport.
    const Cell = struct {
        row: u16,
        col: u16,
    };

    /// Last line offset visible in the viewport.
    fn lastOffset(viewport: Viewport) u16 {
        const text_width = viewport.col_count - viewport.gutterWidth();
        return viewport.line_offset_start + text_width - 1;
    }

    /// Last line number visible in the viewport.
    fn lastLine(viewport: Viewport) u16 {
        // The extra -1 is for the status line.
        return viewport.line_number_start + viewport.row_count - 2;
    }

    /// Determine gutter width: enough digits for the greatest visible line number plus one for
    /// padding.
    fn gutterWidth(viewport: Viewport) u8 {
        return digitCount(@intCast(viewport.line_number_start + viewport.row_count - 1)) + 1;
    }
};

const Cursor = struct {
    offset: u32,
    anchor: ?u32,
    line_offset_snap: u16,

    fn update(
        cursor: *Cursor,
        buffer: []const u8,
        offset: u32,
        kind: enum { snap_update, snap_remain },
    ) void {
        assert(buffer.len > 0);
        cursor.offset = @min(offset, buffer.len - 1);
        if (kind == .snap_update) cursor.line_offset_snap = lineOffset(buffer, cursor.offset);
    }

    const Direction = enum { up, down, left, right };

    /// Max here is in the context of a file coordinate (line_number, line_offset). Left and right
    /// go to the start or end of a line respectively. Up and down go to the first or last line
    /// respectively. Right is a special case. We lock `line_offset_snap` to its max so that as we
    /// go up and down lines the cursor is clamped to the end of each line.
    fn moveMax(cursor: *Cursor, direction: Direction, buffer: []const u8) void {
        switch (direction) {
            .left => cursor.update(buffer, lineHead(buffer, cursor.offset), .snap_update),
            .right => {
                cursor.update(buffer, lineTail(buffer, cursor.offset), .snap_update);
                cursor.line_offset_snap = line_offset_max;
            },
            .down => {
                const line_head = lineHead(buffer, @intCast(buffer.len - 1)); // last line
                const line_offset = @min(cursor.line_offset_snap, lineSize(buffer, line_head) - 1);
                cursor.update(buffer, line_head + line_offset, .snap_remain);
            },
            .up => cursor.update(buffer, @min( // stay clamped to snap or line end
                cursor.line_offset_snap,
                lineSize(buffer, 0) - 1, // first line
            ), .snap_remain),
        }
    }

    fn move(cursor: *Cursor, direction: Direction, count: u32, buffer: []const u8) void {
        switch (direction) {
            .left => cursor.update(buffer, cursor.offset -| count, .snap_update),
            .right => cursor.update(buffer, cursor.offset +| count, .snap_update),
            .up => cursor.update(buffer, moveLineUp(buffer, .{
                .offset = cursor.offset,
                .count = @intCast(count),
                .line_offset_snap = cursor.line_offset_snap,
            }), .snap_remain),
            .down => cursor.update(buffer, moveLineDown(buffer, .{
                .offset = cursor.offset,
                .count = @intCast(count),
                .line_offset_snap = cursor.line_offset_snap,
            }), .snap_remain),
        }
    }
};

const Error = error{
    CsiSequenceInvalid,
    CsiSequenceNotRecognised,
    CsiSequenceTooLong,
    FileContainsInvalidCharacter,
    FileEmpty,
    FileNotNewlineTerminated,
    FileTooManyLines,
    LineTooLong,
    ViewportTooLarge,
    ViewportTooSmall,
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
    for (file_bytes) |byte| switch (byte) {
        0x0A => {}, // newline
        0x20...0x7E => {}, // printable
        // TODO: Handle tabs.
        else => return Error.FileContainsInvalidCharacter,
    };
    if (file_bytes[file_bytes.len - 1] != '\n') return Error.FileNotNewlineTerminated;

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
        .cursor = .{ .offset = 0, .anchor = null, .line_offset_snap = 0 },
    };

    // First input must be viewport dimensions.
    assert(try editor.tick());
    assert(editor.viewport.row_count != 0);
    assert(editor.viewport.col_count != 0);

    return editor;
}

pub fn deinit(editor: *Editor, allocator: std.mem.Allocator) void {
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

fn parseCsiInt(text: []const u8) !u32 {
    return std.fmt.parseInt(u32, text, 10) catch |err| switch (err) {
        error.InvalidCharacter => return Error.CsiSequenceInvalid,
        else => return err,
    };
}

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
        // 0x40-0x7E. See https://ghostty.org/docs/vt/concepts/sequences#escape-sequences and
        // https://en.wikipedia.org/wiki/ANSI_escape_code.
        '\x1b' => { // CSI is ESC [ (0x1b 0x5b).
            if (try reader.takeByte() != '[') return Error.CsiSequenceInvalid;

            var params_buffer: [32]u8 = undefined;
            var params_index: usize = 0;
            // Read until the final byte so we have all that remains of the escape sequence.
            const final = while (true) : (params_index += 1) switch (try reader.takeByte()) {
                // Since we don't yet support a sequence that uses intermediates, just reject them.
                0x20...0x2F => return Error.CsiSequenceNotRecognised, // intermediates
                0x30...0x3F => |byte| {
                    if (params_index == params_buffer.len) return Error.CsiSequenceTooLong;
                    params_buffer[params_index] = byte;
                },
                0x40...0x7E => |final_byte| break final_byte,
                else => return Error.CsiSequenceInvalid,
            };

            const params = params_buffer[0..params_index];
            var iter = std.mem.splitScalar(u8, params, ';');
            // The escape sequences we support
            const first_str = iter.next() orelse return Error.CsiSequenceNotRecognised;
            const first = try parseCsiInt(first_str);
            switch (final) {
                'u' => switch (first) {
                    0x1b => return .escape,
                    // Printable ASCII with modifiers. Codepoints must be the lowercase variant.
                    0x20...0x7E => |c| return .{
                        .chord = .{
                            .ascii = @intCast(switch (c) {
                                // CSI u unicode-key-code must be unshifted (e.g. a not A).
                                'A'...'Z' => return Error.CsiSequenceInvalid,
                                else => c,
                            }),
                            // Modifiers may not be present. It defaults to 1 (no modifiers). For
                            // now return an error if these are missing.
                            .modifiers = try .decode(
                                iter.next() orelse return Error.CsiSequenceNotRecognised,
                            ),
                        },
                    },
                    else => return Error.CsiSequenceNotRecognised,
                },
                't' => switch (first) {
                    // Resize: CSI 48 ; height_chars ; width_chars ; height_pix ; width_pix t. See
                    // https://gist.github.com/rockorager/e695fb2924d36b2bcf1fff4a3704bd83.
                    48 => return .{
                        .resize = .{
                            .row_count = @intCast(try parseCsiInt(iter.next().?)),
                            .col_count = @intCast(try parseCsiInt(iter.next().?)),
                        },
                    },
                    else => return Error.CsiSequenceNotRecognised,
                },
                else => return Error.CsiSequenceNotRecognised,
            }
            unreachable;
        },
        else => return Error.CsiSequenceNotRecognised,
    }
}

fn insert(editor: *Editor, text: []const u8) !void {
    assert(text.len > 0);
    assert(editor.cursor.offset < editor.buffer.items.len);
    try editor.buffer.insertSliceBounded(editor.cursor.offset, text);
    editor.cursor.move(.right, @intCast(text.len), editor.buffer.items);
    editor.dirty = true;
}

/// Delete text under cursor.
fn delete(editor: *Editor) !void {
    if (editor.cursor.anchor) |anchor| {
        const selection_head = @min(anchor, editor.cursor.offset);
        const selection_tail = @max(anchor, editor.cursor.offset);
        const selection_size = selection_tail - selection_head + 1; // +1: offset -> size
        // We're removing text here so this should never return an error.
        editor.buffer.replaceRangeAssumeCapacity(selection_head, selection_size, "");
        editor.cursor.anchor = null;
    } else _ = editor.buffer.orderedRemove(editor.cursor.offset);
    // File must always end in a newline.
    if (editor.buffer.items.len == 0 or editor.buffer.last() != '\n')
        editor.buffer.appendAssumeCapacity('\n');
    editor.dirty = true;
}

fn lineIndentation(buffer: []const u8, offset: u32) u16 {
    assert(offset < buffer.len);
    const line_head = lineHead(buffer, offset);
    var i = line_head;
    while (buffer[i] == ' ') i += 1;
    return @intCast(i - line_head);
}

test lineIndentation {
    try std.testing.expectEqual(2, lineIndentation("  badabop\n boom \npow", 0));
    try std.testing.expectEqual(2, lineIndentation("  badabop\n boom \npow", 3));
    try std.testing.expectEqual(2, lineIndentation("  badabop\n boom \npow", 9));
    try std.testing.expectEqual(1, lineIndentation("  badabop\n boom \npow", 10));
    try std.testing.expectEqual(0, lineIndentation("  badabop\n boom \npow", 17));
}

fn lineOffset(buffer: []const u8, offset: u32) u16 {
    assert(offset < buffer.len);
    return @intCast(offset - lineHead(buffer, offset));
}

test lineOffset {
    const file =
        \\  yo
        \\
        \\hi
        \\
        \\
    ;
    try std.testing.expectEqualStrings("  yo\n\nhi\n\n", file); // for clarity
    try std.testing.expectEqual(0, lineOffset(file, 0)); // line 0: * yo
    try std.testing.expectEqual(3, lineOffset(file, 3)); // line 0:   y*
    try std.testing.expectEqual(4, lineOffset(file, 4)); // line 0:   yo* (end of line 0 newline)
    try std.testing.expectEqual(0, lineOffset(file, 5)); // line 1: * (end of blank line newline)
    try std.testing.expectEqual(1, lineOffset(file, 7)); // line 2: h*
    try std.testing.expectEqual(0, lineOffset(file, 9)); // line 3: * (end of file newline)
}

fn lineNumber(buffer: []const u8, offset: u32) u16 {
    return @intCast(std.mem.countScalar(u8, buffer[0..offset], '\n'));
}

test lineNumber {
    try std.testing.expectEqual(0, lineNumber("  yo\n\nhi\n\n", 0));
    try std.testing.expectEqual(0, lineNumber("  yo\n\nhi\n\n", 3));
    try std.testing.expectEqual(0, lineNumber("  yo\n\nhi\n\n", 4));
    try std.testing.expectEqual(1, lineNumber("  yo\n\nhi\n\n", 5));
    try std.testing.expectEqual(3, lineNumber("  yo\n\nhi\n\n", 9));
}

fn lineHead(buffer: []const u8, offset: u32) u32 {
    assert(offset < buffer.len);
    return @intCast(if (std.mem.findScalarLast(u8, buffer[0..offset], '\n')) |i| i + 1 else 0);
}

test lineHead {
    try std.testing.expectEqual(0, lineHead("yo\nwhat's\nup?", 0));
    try std.testing.expectEqual(0, lineHead("yo\nwhat's\nup?", 1));
    try std.testing.expectEqual(0, lineHead("yo\nwhat's\nup?", 2));
    try std.testing.expectEqual(3, lineHead("yo\nwhat's\nup?", 3));
    try std.testing.expectEqual(10, lineHead("yo\nwhat's\nup?", 12));
}

fn lineTail(buffer: []const u8, offset: u32) u32 {
    assert(offset < buffer.len);
    return @intCast(if (std.mem.findScalarPos(u8, buffer, offset, '\n')) |i| i else buffer.len - 1);
}

test lineTail {
    try std.testing.expectEqual(2, lineTail("yo\nwhat's\nup?", 0));
    try std.testing.expectEqual(2, lineTail("yo\nwhat's\nup?", 2));
    try std.testing.expectEqual(9, lineTail("yo\nwhat's\nup?", 3));
    try std.testing.expectEqual(12, lineTail("yo\nwhat's\nup?", 10));
    try std.testing.expectEqual(13, lineTail("yo\nwhat's\nup?\n", 10));
}

/// Calculate the size of a line. A line starts after a newline (unless it's the first line in
/// the buffer) and ends with a newline. The ending newline is part of the line.
fn lineSize(buffer: []const u8, offset: u32) u32 {
    assert(offset < buffer.len);
    return lineTail(buffer, offset) - lineHead(buffer, offset) + 1; // +1 for offset -> size
}

test lineSize {
    try std.testing.expectEqual(3, lineSize("  \n\n \n", 0));
    try std.testing.expectEqual(3, lineSize("  \n\n \n", 2));
    try std.testing.expectEqual(1, lineSize("  \n\n \n", 3));
    try std.testing.expectEqual(2, lineSize("  \n\n \n", 4));
    try std.testing.expectEqual(2, lineSize("  \n\n \n", 5));
}

fn moveLineUp(
    buffer: []const u8,
    options: struct { offset: u32, count: u16, line_offset_snap: u16 },
) u32 {
    assert(options.offset < buffer.len);
    var i: u32 = lineHead(buffer, options.offset);
    for (0..options.count) |_| i = if (i == 0) break else lineHead(buffer, i - 1);
    return i + @min(lineSize(buffer, i) - 1, options.line_offset_snap);
}

test moveLineUp {
    const eq = std.testing.expectEqual; // low on cols
    const buffer = "aaa\na\n\naa\n";
    // Moving up on first line does nothing.
    try eq(0, moveLineUp(buffer, .{ .offset = 0, .count = 1, .line_offset_snap = 0 }));
    try eq(1, moveLineUp(buffer, .{ .offset = 1, .count = 1, .line_offset_snap = 1 }));
    // Same goes when clamping to line end.
    try eq(3, moveLineUp(buffer, .{ .offset = 3, .count = 1, .line_offset_snap = 5 }));
    // Actually move up, clamping to line end.
    try eq(3, moveLineUp(buffer, .{ .offset = 5, .count = 1, .line_offset_snap = 5 }));
    // Move up, respecting snap offset.
    try eq(0, moveLineUp(buffer, .{ .offset = 4, .count = 1, .line_offset_snap = 0 }));
    // Again, checking we can't go up beyond first line.
    try eq(0, moveLineUp(buffer, .{ .offset = 4, .count = 2, .line_offset_snap = 0 }));
    // Move up multiple lines.
    try eq(1, moveLineUp(buffer, .{ .offset = 6, .count = 2, .line_offset_snap = 1 }));
    try eq(1, moveLineUp(buffer, .{ .offset = 8, .count = 3, .line_offset_snap = 1 }));
    // Again, but clamp to line end.
    try eq(3, moveLineUp(buffer, .{ .offset = 9, .count = 3, .line_offset_snap = 5 }));
}

fn moveLineDown(
    buffer: []const u8,
    options: struct { offset: u32, count: u16, line_offset_snap: u16 },
) u32 {
    assert(options.offset < buffer.len);
    var i: u32 = lineHead(buffer, options.offset);
    for (0..options.count) |_| {
        const line_tail = lineTail(buffer, i);
        if (line_tail == buffer.len - 1) break;
        i = line_tail + 1;
    }
    return i + @min(lineSize(buffer, i) - 1, options.line_offset_snap);
}

test moveLineDown {
    const eq = std.testing.expectEqual;
    const buffer = "aaa\na\n\naa\n";
    try eq(4, moveLineDown(buffer, .{ .offset = 0, .count = 1, .line_offset_snap = 0 }));
    try eq(5, moveLineDown(buffer, .{ .offset = 3, .count = 1, .line_offset_snap = 3 }));
    try eq(5, moveLineDown(buffer, .{ .offset = 3, .count = 1, .line_offset_snap = 4 }));
    try eq(6, moveLineDown(buffer, .{ .offset = 3, .count = 2, .line_offset_snap = 3 }));
    try eq(9, moveLineDown(buffer, .{ .offset = 3, .count = 3, .line_offset_snap = 3 }));
    try eq(9, moveLineDown(buffer, .{ .offset = 9, .count = 1, .line_offset_snap = 3 }));
    try eq(9, moveLineDown(buffer, .{ .offset = 9, .count = 2, .line_offset_snap = 3 }));
}

fn characterKind(c: u8) enum { whitespace, symbol, alphanumeric } {
    return switch (c) {
        '\n' => .whitespace,
        0x20...0x7E => switch (c) { // printable ASCII range
            ' ' => .whitespace,
            '_' => .alphanumeric,
            '0'...'9' => .alphanumeric,
            'a'...'z' => .alphanumeric,
            'A'...'Z' => .alphanumeric,
            else => .symbol,
        },
        else => unreachable,
    };
}

/// Find the next word end where a word is a contiguous span of only aphanumeric characters OR only
/// symbols. If the offset is already the end of the word, returns the index of the next word end.
/// Advances past whitespace to the next word. The only time this returns an index containing
/// whitespace is if it's the end of the buffer.
fn wordTailNext(buffer: []const u8, offset: u32) u32 {
    assert(offset < buffer.len);
    var i: u32 = offset + 1;
    while (i < buffer.len and characterKind(buffer[i]) == .whitespace) i += 1; // go past whitespace
    if (i == buffer.len) return i - 1;
    const kind = characterKind(buffer[i]);
    while (i + 1 < buffer.len and characterKind(buffer[i + 1]) == kind) i += 1;
    return i;
}

test wordTailNext {
    try std.testing.expectEqual(4, wordTailNext("Hello,\n  world!", 0));
    try std.testing.expectEqual(4, wordTailNext("Hello,\n  world!", 1));
    try std.testing.expectEqual(5, wordTailNext("Hello,\n  world!", 4));
    try std.testing.expectEqual(13, wordTailNext("Hello,\n  world!", 5));
    try std.testing.expectEqual(13, wordTailNext("Hello,\n  world!", 7));
    try std.testing.expectEqual(14, wordTailNext("Hello,\n  world!", 13));
    try std.testing.expectEqual(14, wordTailNext("Hello,\n  world!", 14));
}

/// Same as `wordTailNext` except each token is any contiguous span of non-whitespace.
fn tokenTailNext(buffer: []const u8, offset: u32) u32 {
    assert(offset < buffer.len);
    var i: u32 = offset + 1;
    while (i < buffer.len and characterKind(buffer[i]) == .whitespace) i += 1; // go past whitespace
    if (i == buffer.len) return i - 1;
    while (i + 1 < buffer.len and characterKind(buffer[i + 1]) != .whitespace) i += 1;
    return i;
}

test tokenTailNext {
    try std.testing.expectEqual(5, tokenTailNext("Hello,\n  world!", 0));
    try std.testing.expectEqual(5, tokenTailNext("Hello,\n  world!", 1));
    try std.testing.expectEqual(14, tokenTailNext("Hello,\n  world!", 5));
    try std.testing.expectEqual(14, tokenTailNext("Hello,\n  world!", 14));
    try std.testing.expectEqual(14, tokenTailNext("Hello,\n  world!", 14));
}

/// Same principle `wordTailNext` but going backwards until we find the next word start.
fn wordHeadPrev(buffer: []const u8, offset: u32) u32 {
    assert(offset < buffer.len);
    if (offset == 0) return 0;
    var i: u32 = offset - 1;
    while (i > 0 and characterKind(buffer[i]) == .whitespace) i -= 1; // go past whitespace
    const kind = characterKind(buffer[i]);
    while (i > 0 and characterKind(buffer[i - 1]) == kind) i -= 1;
    return i;
}

test wordHeadPrev {
    try std.testing.expectEqual(9, wordHeadPrev("Hello,\n  world!", 14));
    try std.testing.expectEqual(9, wordHeadPrev("Hello,\n  world!", 12));
    try std.testing.expectEqual(5, wordHeadPrev("Hello,\n  world!", 9));
    try std.testing.expectEqual(0, wordHeadPrev("Hello,\n  world!", 5));
    try std.testing.expectEqual(0, wordHeadPrev("Hello,\n  world!", 4));
    try std.testing.expectEqual(0, wordHeadPrev("Hello,\n  world!", 0));
    try std.testing.expectEqual(0, wordHeadPrev(", ", 1));
    try std.testing.expectEqual(0, wordHeadPrev(",  ", 2));
    try std.testing.expectEqual(1, wordHeadPrev(" , ", 2));
    try std.testing.expectEqual(0, wordHeadPrev(",, ", 2));
}

fn tokenHeadPrev(buffer: []const u8, offset: u32) u32 {
    assert(offset < buffer.len);
    if (offset == 0) return 0;
    var i: u32 = offset - 1;
    while (i > 0 and characterKind(buffer[i]) == .whitespace) i -= 1; // go past whitespace
    while (i > 0 and characterKind(buffer[i - 1]) != .whitespace) i -= 1;
    return i;
}

test tokenHeadPrev {
    try std.testing.expectEqual(9, tokenHeadPrev("Hello,\n  world!", 14));
    try std.testing.expectEqual(9, tokenHeadPrev("Hello,\n  world!", 12));
    try std.testing.expectEqual(0, tokenHeadPrev("Hello,\n  world!", 9));
    try std.testing.expectEqual(0, tokenHeadPrev("Hello,\n  world!", 5));
    try std.testing.expectEqual(0, tokenHeadPrev("Hello,\n  world!", 4));
    try std.testing.expectEqual(0, tokenHeadPrev("Hello,\n  world!", 0));
    try std.testing.expectEqual(0, tokenHeadPrev(", ", 1));
    try std.testing.expectEqual(0, tokenHeadPrev(",  ", 2));
    try std.testing.expectEqual(1, tokenHeadPrev(" , ", 2));
    try std.testing.expectEqual(0, tokenHeadPrev(",, ", 2));
}

fn wordHeadNext(buffer: []const u8, offset: u32) u32 {
    assert(offset < buffer.len);
    const kind = characterKind(buffer[offset]);
    var i: u32 = offset;
    while (i < buffer.len and characterKind(buffer[i]) == kind) i += 1; // go past word
    while (i < buffer.len and characterKind(buffer[i]) == .whitespace) i += 1; // go past whitespace
    return @min(i, @as(u32, @intCast(buffer.len - 1)));
}

test wordHeadNext {
    try std.testing.expectEqual(2, wordHeadNext("  Hello,\n  world!", 0));
    try std.testing.expectEqual(2, wordHeadNext("  Hello,\n  world!", 1));
    try std.testing.expectEqual(7, wordHeadNext("  Hello,\n  world!", 2));
    try std.testing.expectEqual(11, wordHeadNext("  Hello,\n  world!", 7));
    try std.testing.expectEqual(16, wordHeadNext("  Hello,\n  world!", 11));
    try std.testing.expectEqual(16, wordHeadNext("  Hello,\n  world!", 16));
}

fn tokenHeadNext(buffer: []const u8, offset: u32) u32 {
    assert(offset < buffer.len);
    var i: u32 = offset;
    while (i < buffer.len and characterKind(buffer[i]) != .whitespace) i += 1; // go past token
    while (i < buffer.len and characterKind(buffer[i]) == .whitespace) i += 1; // go past whitespace
    return @min(i, @as(u32, @intCast(buffer.len - 1)));
}

test tokenHeadNext {
    try std.testing.expectEqual(2, tokenHeadNext("  Hello,\n  world!", 0));
    try std.testing.expectEqual(2, tokenHeadNext("  Hello,\n  world!", 1));
    try std.testing.expectEqual(11, tokenHeadNext("  Hello,\n  world!", 2));
    try std.testing.expectEqual(11, tokenHeadNext("  Hello,\n  world!", 4));
    try std.testing.expectEqual(16, tokenHeadNext("  Hello,\n  world!", 11));
    try std.testing.expectEqual(16, tokenHeadNext("  Hello,\n  world!", 16));
}

// This trick gets us the number of digits in a positive number: log_10(x) + 1.
fn digitCount(number: u16) u8 {
    return std.math.log10_int(number) + 1;
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
        Error.FileContainsInvalidCharacter,
        Error.FileEmpty,
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
        Error.CsiSequenceInvalid,
        Error.CsiSequenceNotRecognised,
        Error.ViewportTooLarge,
        Error.ViewportTooSmall,
        error.EndOfStream, // probably won't show up in normal usage so handle it here instead
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
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed("\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
        "q"); // quit after first render
    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // last tick: reports false on quit
}

test "rendering: empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed("\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
        "q"); // quit after first render
    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "empty.zig", "\n");
    defer editor.deinit(allocator);

    try std.testing.expect(try editor.tick() == false);

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());
}

test "go to start/end of file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed("\x1b[48;5;36;0;0t" ++ // dimensions: 5 rows by 36 cols
        "G" ++ // go to end of file
        "g" ++ // go to start of file
        "q"); // quit
    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\1 #include <stdio.h>
        \\2 
        \\3 int main() {
        \\4   printf("Hello, world!\n");
        \\hello.c                          1,1
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;3H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    stripping.out.clearRetainingCapacity(); // clear what we've written
    try std.testing.expect(try editor.tick() == true); // process the G
    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\3 int main() {
        \\4   printf("Hello, world!\n");
        \\5   return 0;
        \\6 }
        \\hello.c                          6,1
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[4;3H" // cursor coordinates at end of file: 3, 2 (but indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    stripping.out.clearRetainingCapacity(); // clear what we've written
    try std.testing.expect(try editor.tick() == true); // process the g
    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\1 #include <stdio.h>
        \\2 
        \\3 int main() {
        \\4   printf("Hello, world!\n");
        \\hello.c                          1,1
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;3H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // process the q, exited
}

test "go to start/end of line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed("\x1b[48;12;12;0;0t" ++ // dimensions: 12 rows by 12 cols
        "$" ++ // go to end of line
        "0" ++ // go to start of line
        "q"); // quit
    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    stripping.out.clearRetainingCapacity(); // clear what we've written
    try std.testing.expect(try editor.tick() == true); // process the $
    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;12H" // cursor coordinates at end of line: 0, 11 (but indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    stripping.out.clearRetainingCapacity(); // clear what we've written
    try std.testing.expect(try editor.tick() == true); // process the 0
    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // process the q, exited
}

test "insert mode" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed("\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
        "i" ++ // enter insert mode
        "a" ++ // insert text
        "b" ++ // insert text
        "\x1b[27u" ++ // ESC: return to normal mode
        "$" ++ // move to end of line
        "i" ++ // enter insert mode
        "\x08" ++ // backspace
        "\x1b[27u" ++ // ESC: return to normal mode
        "q"); // quit

    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process i

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[6\x20q" // cursor style (steady block -> steady bar)
    ++ "\x1b[1;4H" // cursor remains at start of file
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process a

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 a#include <stdio.h>
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
        \\hello.c [+]                      1,2
    ++ "\x1b[6\x20q" // cursor style (steady bar)
    ++ "\x1b[1;5H" // cursor moves after inserted character
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process b

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 ab#include <stdio.h>
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
        \\hello.c [+]                      1,3
    ++ "\x1b[6\x20q" // cursor style (steady bar)
    ++ "\x1b[1;6H" // cursor moves after second inserted character
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process escape

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 ab#include <stdio.h>
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
        \\hello.c [+]                      1,3
    ++ "\x1b[2\x20q" // restore normal cursor style
    ++ "\x1b[1;6H" // cursor remains after inserted text
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == true); // process $
    try std.testing.expect(try editor.tick() == true); // process i
    try std.testing.expect(try editor.tick() == true); // process backspace
    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process escape

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 ab#include <stdio.h
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
        \\hello.c [+]                     1,20
    ++ "\x1b[2\x20q" // cursor style
    ++ "\x1b[1;23H" // cursor coordinates (indexed from 0)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // process q
}

test "new line with o preserves indentation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed("\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
        "jjj" ++ // move to printf line
        "o" ++ // open new line below
        "x" ++ // insert text
        "\x1b[27u" ++ // ESC: return to normal mode
        "q"); // quit

    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process o
    try std.testing.expect(try editor.tick() == true); // process x
    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process escape

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 #include <stdio.h>
        \\ 2 
        \\ 3 int main() {
        \\ 4   printf("Hello, world!\n");
        \\ 5   x
        \\ 6   return 0;
        \\ 7 }
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c [+]                      5,4
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[5;7H" // cursor after x
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // process q
}

test "new line with O preserves indentation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed("\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
        "jjj" ++ // move to printf line
        "O" ++ // open new line above
        "x" ++ // insert text
        "\x1b[27u" ++ // ESC: return to normal mode
        "q"); // quit

    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process O
    try std.testing.expect(try editor.tick() == true); // process x
    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process escape

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 #include <stdio.h>
        \\ 2 
        \\ 3 int main() {
        \\ 4   x
        \\ 5   printf("Hello, world!\n");
        \\ 6   return 0;
        \\ 7 }
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c [+]                      4,4
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[4;7H" // cursor after x
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // process q
}

test "insert with I goes to start of line after indentation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed("\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
        "jjj" ++ // move to printf line
        "I" ++ // insert at first non-whitespace character
        "x" ++ // insert text
        "\x1b[27u" ++ // ESC: return to normal mode
        "q"); // quit

    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process I
    try std.testing.expect(try editor.tick() == true); // process x
    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process escape

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 #include <stdio.h>
        \\ 2 
        \\ 3 int main() {
        \\ 4   xprintf("Hello, world!\n");
        \\ 5   return 0;
        \\ 6 }
        \\ 7 ~
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c [+]                      4,4
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[4;7H" // cursor after y
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // process q
}

test "A inserts at end of line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed("\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
        "jjj" ++ // move to printf line
        "A" ++ // insert at end of line
        "x" ++ // insert text
        "\x1b[27u" ++ // ESC: return to normal mode
        "q"); // quit

    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process A
    try std.testing.expect(try editor.tick() == true); // process x
    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process escape

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 #include <stdio.h>
        \\ 2 
        \\ 3 int main() {
        \\ 4   printf("Hello, world!\n");x
        \\ 5   return 0;
        \\ 6 }
        \\ 7 ~
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c [+]                     4,30
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[4;33H" // cursor after x
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // process q
}

test "tab inserts four spaces" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed("\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
        "i" ++ // enter insert mode
        "\t" ++ // insert four spaces
        "x" ++ // insert text
        "\x1b[27u" ++ // ESC: return to normal mode
        "q"); // quit

    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == true); // process i
    try std.testing.expect(try editor.tick() == true); // process tab
    try std.testing.expect(try editor.tick() == true); // process x
    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process escape

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1     x#include <stdio.h>
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
        \\hello.c [+]                      1,6
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;9H" // cursor after x
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // process q
}

test "enter preserves indentation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed("\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
        "jjj" ++ // move to printf line
        "I" ++ // insert at first non-whitespace character
        "x" ++ // insert text
        "\r" ++ // enter
        "y" ++ // insert text
        "\x1b[27u" ++ // ESC: return to normal mode
        "q"); // quit

    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process I
    try std.testing.expect(try editor.tick() == true); // process x
    try std.testing.expect(try editor.tick() == true); // process enter
    try std.testing.expect(try editor.tick() == true); // process y
    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process escape

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 #include <stdio.h>
        \\ 2 
        \\ 3 int main() {
        \\ 4   x
        \\ 5   yprintf("Hello, world!\n");
        \\ 6   return 0;
        \\ 7 }
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c [+]                      5,4
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[5;7H" // cursor after y
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // process q
}

test "delete" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed("\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
        "d" ++ // delete first character
        "$" ++ // move to end of line
        "d" ++ // delete newline (character at end of line)
        "G" ++ // move to last line
        "$" ++ // move to end of line
        "d" ++ // move to end of line
        "q"); // quit

    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process d

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 include <stdio.h>
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
        \\hello.c [+]                      1,1
        //         ^ file edited
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == true); // process $
    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process d

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 include <stdio.h>
        \\ 2 int main() {
        \\ 3   printf("Hello, world!\n");
        \\ 4   return 0;
        \\ 5 }
        \\ 6 ~
        \\ 7 ~
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c [+]                     1,18
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;21H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == true); // process G
    try std.testing.expect(try editor.tick() == true); // process $
    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process d

    // Same as last time. You can't delete the final newline.
    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 include <stdio.h>
        \\ 2 int main() {
        \\ 3   printf("Hello, world!\n");
        \\ 4   return 0;
        \\ 5 }
        \\ 6 ~
        \\ 7 ~
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c [+]                      5,2
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[5;5H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // process q
}

test "delete selection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reader: std.Io.Reader = .fixed("\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
        // Delete first line with anchor trailing cursor offset.
        "$" ++ // move to end of line
        "v" ++ // start selection
        "0" ++ // move to start of file
        "d" ++ // delete selection
        "j" ++ // move down a line
        "e" ++ // move to end of word
        // Delete multiline selection with anchor leading cursor offset.
        "v" ++ // start selection
        "G" ++ // move to last line
        "$" ++ // move to end of line
        "d" ++ // delete selection
        "q"); // quit

    var stripping: StrippingWriter = try .init(allocator);
    defer stripping.deinit();
    var editor: Editor = try .init(allocator, io, &reader, stripping.writer(), "hello.c", hello_c);
    defer editor.deinit(allocator);

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
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
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == true); // process $
    try std.testing.expect(try editor.tick() == true); // process v
    try std.testing.expect(try editor.tick() == true); // process 0
    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process d

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 
        \\ 2 int main() {
        \\ 3   printf("Hello, world!\n");
        \\ 4   return 0;
        \\ 5 }
        \\ 6 ~
        \\ 7 ~
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c [+]                      1,1
        //         ^ file edited
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[1;4H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == true); // process j
    try std.testing.expect(try editor.tick() == true); // process e
    try std.testing.expect(try editor.tick() == true); // process v
    try std.testing.expect(try editor.tick() == true); // process G
    try std.testing.expect(try editor.tick() == true); // process $
    stripping.out.clearRetainingCapacity();
    try std.testing.expect(try editor.tick() == true); // process d

    try std.testing.expectEqualSlices(u8, "\x1b[?2026h" ++ // begin synchronised update
        "\x1b[2J" ++ // clear screen
        "\x1b[H" ++ // place cursor at top left
        \\ 1 
        \\ 2 in
        \\ 3 ~
        \\ 4 ~
        \\ 5 ~
        \\ 6 ~
        \\ 7 ~
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c [+]                      2,3
    ++ "\x1b[2\x20q" // cursor style (steady block)
    ++ "\x1b[2;6H" // cursor coordinates (indexed from 1)
    ++ "\x1b[?2026l" // end synchronised update
    , stripping.written());

    try std.testing.expect(try editor.tick() == false); // process q
}
