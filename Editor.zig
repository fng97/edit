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
const builtin = @import("builtin");

const assert = std.debug.assert;
const Editor = @This();

const file_size_max = 1 * 1024 * 1024;
const line_count_max = 10_000;
const line_offset_max = 1_000;
const row_count_max = 2_000;
const col_count_max = 500;
const terminal_init =
    // Use alternate screen. Stores original screen and cursor state and has no scrollback. See
    // https://terminfo.dev/modes/decset-1049-alt-screen-enter.
    "\x1b[?1049h" ++
    // Initialise Kitty Keyboard Protocol (KKP) in mode 1: disambiguate escape codes: See
    // https://sw.kovidgoyal.net/kitty/keyboard-protocol/#disambiguate-escape-codes.
    "\x1b[>1u" ++
    // Enable in-band resize notifications. See
    // https://gist.github.com/rockorager/e695fb2924d36b2bcf1fff4a3704bd83.
    "\x1b[?2048h";
const terminal_deinit =
    "\x1b[?2048l" ++ // disable in-band resize notifications
    "\x1b[<u" ++ // pop KKP flags
    "\x1b[?1049l"; // exit alt screen
const esc_highlight_foreground = "\x1b[38;2;40;40;40m"; // dark foreground
const esc_highlight_background = "\x1b[48;2;200;200;200m"; // light gray background
const esc_colour_reset = "\x1b[0m";

// Calculating last visible line or offset should never overflow.
comptime {
    const line_number_max = line_count_max - 1;
    // row_count-1 is the last visible row but that's for the status line so use row_count-2.
    assert(line_number_max + row_count_max - 2 <= std.math.maxInt(u32));
    assert(line_offset_max - 1 + row_count_max - 2 <= std.math.maxInt(u32));
}

io: std.Io,
reader: *std.Io.Reader,
writer: *std.Io.Writer,

file_path: []const u8,
viewport: Viewport,
cursor: Cursor,
mode: union(enum) {
    normal,
    insert,
    prompt: union(enum) {
        command: struct { buffer: std.ArrayList(u8), cursor_offset: u8 },
        message: enum { command_not_recognised, formatting_failed },
        unsaved,
    },
},
buffer: std.ArrayList(u8),
dirty: bool = false,
prompt_command_buffer: [std.math.maxInt(u8)]u8 = undefined,
formatting_buffer: [file_size_max]u8 = undefined,

pub fn tick(editor: *Editor) !bool {
    const input = try parseOne(editor.reader);
    if (input == .resize) {
        editor.viewport.row_count = input.resize.row_count;
        editor.viewport.col_count = input.resize.col_count;
    } else switch (editor.mode) {
        .normal => switch (input) {
            .ascii => |c| switch (c) {
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
                    const cursor_offset = if (editor.cursor.selection()) |selection|
                        selection.head
                    else
                        editor.cursor.offset;
                    try editor.delete();
                    editor.cursor.update(editor.buffer.items, cursor_offset, .snap_update);
                },
                ':' => editor.mode = .{
                    .prompt = .{
                        .command = .{
                            .buffer = .initBuffer(&editor.prompt_command_buffer),
                            .cursor_offset = 0,
                        },
                    },
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
        .prompt => |*prompt| switch (prompt.*) {
            .command => |*command| switch (input) {
                .escape => editor.mode = .normal,
                // Keep entering text as long as we've got room in the buffer and on the row. The
                // -2 below (aside from count->index) is to account for the prompt prefix, ':'.
                .ascii => |c| if (command.cursor_offset < command.buffer.capacity and
                    command.cursor_offset < editor.viewport.col_count - 2)
                {
                    assert(command.cursor_offset == command.buffer.items.len);
                    try command.buffer.insertBounded(command.cursor_offset, c);
                    command.cursor_offset += 1;
                    assert(command.cursor_offset == command.buffer.items.len);
                },
                .backspace => if (command.cursor_offset != 0) {
                    assert(command.cursor_offset == command.buffer.items.len);
                    _ = command.buffer.orderedRemove(command.cursor_offset - 1);
                    command.cursor_offset -= 1;
                    assert(command.cursor_offset == command.buffer.items.len);
                },
                .enter => {
                    if (std.mem.eql(u8, "w", command.buffer.items)) {
                        if (try editor.formatBuffer()) {
                            try editor.save();
                            editor.mode = .normal;
                        } else {
                            editor.mode = .{ .prompt = .{ .message = .formatting_failed } };
                        }
                    } else if (std.mem.eql(u8, "q", command.buffer.items)) {
                        if (!editor.dirty) return false; // exit!
                        // Trying to exit without saving. Prompt user to save.
                        editor.mode = .{ .prompt = .unsaved };
                    } else if (std.mem.eql(u8, "q!", command.buffer.items)) {
                        return false; // exit, for real!
                    } else if (std.mem.eql(u8, "wq", command.buffer.items)) {
                        try editor.save();
                        return false;
                    } else if (std.fmt.parseInt(u32, command.buffer.items, 10) catch null) |number| {
                        // Line number given is indexed from 1.
                        const line_number = @max(number, 1) - 1;
                        if (lineHeadFromNumber(editor.buffer.items, line_number)) |head| {
                            editor.cursor.update(editor.buffer.items, head, .snap_remain);
                        }
                        editor.mode = .normal;
                    } else editor.mode = .{ .prompt = .{ .message = .command_not_recognised } };
                },
                .tab, .chord => {}, // do nothing
                .resize => unreachable,
            },
            .message => switch (input) {
                .enter, .escape => editor.mode = .normal,
                .ascii, .tab, .chord, .backspace => {}, // do nothing
                .resize => unreachable,
            },
            .unsaved => switch (input) {
                .escape => editor.mode = .normal,
                .ascii => |c| switch (c) {
                    'y' => {
                        try editor.save();
                        return false;
                    },
                    'n' => return false, // quit without saving
                    else => {}, // do nothing
                },
                .enter, .tab, .chord, .backspace => {}, // do nothing
                .resize => unreachable,
            },
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
    const file_name = editor.file_path;

    // Begin synchronised update. See
    // https://contour-terminal.org/vt-extensions/synchronized-output.
    try writer.writeAll("\x1b[?2026h");
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

            if (line_head == line_tail) {} // empty line
            else if (editor.cursor.anchor) |anchor| { // handle selection highlighting
                const esc_highlight = esc_highlight_foreground ++ esc_highlight_background;
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
                        try writer.writeAll(esc_colour_reset);
                    }
                }

                // Reset before printing the next line so that line numbers aren't highlighted.
                if (highlight) try writer.writeAll(esc_colour_reset);
            } else try writer.writeAll(buffer[cropped_head..cropped_tail]); // normal line

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
        .prompt => |prompt| switch (prompt) {
            .command => |command| {
                try writer.writeByte(':');
                try writer.writeAll(command.buffer.items);
            },
            .unsaved => try writer.print("Save changes to {s} (y/n)?", .{editor.file_path}),
            .message => |message| switch (message) {
                .command_not_recognised => try writer.writeAll("invalid command"),
                .formatting_failed => try writer.writeAll("formatting failed"),
            },
        },
    }

    // Restore cursor.
    const cursor_style: Cursor.Style = switch (editor.mode) {
        .normal => .steady_block,
        .prompt => |prompt| switch (prompt) {
            .command => .steady_bar,
            .message, .unsaved => .steady_block,
        },
        .insert => .steady_bar,
    };
    // Restore and style cursor. See https://ghostty.org/docs/vt/csi/decscusr.
    try writer.print("\x1b[{d}\x20q", .{@backingInt(cursor_style)});
    const cursor_cell: Viewport.Cell = if (editor.mode == .prompt and
        editor.mode.prompt == .command) .{
        .row = editor.viewport.row_count - 1, // final row
        .col = editor.mode.prompt.command.cursor_offset + 1, // +1 for the ':' prompt prefix
    } else blk: {
        const cursor_cell: Viewport.Cell = .{
            .row = cursor.line_number - line_number_start,
            .col = cursor.line_offset - line_offset_start + gutter_width,
        };
        assert(cursor_cell.col >= gutter_width); // right of line numbers
        break :blk cursor_cell;
    };
    assert(cursor_cell.col < col_count); // does not exceed screen bounds horizontally
    assert(cursor_cell.row < row_count); // does not exceed screen bounds vertically
    try writer.print("\x1b[{d};{d}H", .{ cursor_cell.row + 1, cursor_cell.col + 1 });
    try writer.writeAll("\x1b[?2026l"); // end synchronised update

    try writer.flush();
}

pub fn main(juice: std.process.Init) !void {
    const io = juice.io;
    const allocator = juice.arena.allocator();

    // Load and process buffer.
    var args_iterator = std.process.Args.Iterator.init(juice.minimal.args);
    assert(args_iterator.skip()); // first arg is executable path
    const file_name = args_iterator.next() orelse @panic("missing file path arg");
    const file_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        file_name,
        allocator,
        .limited(Editor.file_size_max),
    );
    defer allocator.free(file_bytes);

    const stdin = std.Io.File.stdin();
    var stdin_buffer: [128]u8 = undefined; // TODO: What's a reasonable size here?
    var stdin_reader = stdin.reader(io, &stdin_buffer);
    const reader: *std.Io.Reader = &stdin_reader.interface;

    // Ideally this buffer is big enough to buffer everything rendered so that flush is only ever
    // called once per render.
    const stdout_buffer = try allocator.alloc(u8, Editor.file_size_max);
    defer allocator.free(stdout_buffer);
    const stdout = std.Io.File.stdout();
    var stdout_writer = stdout.writer(io, stdout_buffer);
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
    termios_raw.cc[@backingInt(std.posix.V.MIN)] = 1;
    termios_raw.cc[@backingInt(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin.handle, .FLUSH, termios_raw);

    // Always restore, even if init fails.
    defer stdout.writeStreamingAll(io, terminal_deinit) catch {};
    try stdout.writeStreamingAll(io, terminal_init);

    var editor: Editor = try .init(allocator, io, reader, writer, file_name, file_bytes);
    defer editor.deinit(allocator);

    while (try editor.tick()) {}
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
            std.Io.File.stdout().writeStreamingAll(threaded.io(), terminal_deinit) catch {};
            std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, t) catch {}; // restore termios
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panic);

fn formatBuffer(editor: *Editor) !bool {
    if (builtin.is_test) return true;

    const io = editor.io;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "zig", "fmt", "--stdin" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    // Write the buffer to stdin.
    try child.stdin.?.writeStreamingAll(io, editor.buffer.items);
    child.stdin.?.close(io);
    child.stdin = null;

    // Resulting stdout is new buffer.
    var stdout_reader = child.stdout.?.reader(io, &.{});
    var buffer_writer: std.Io.Writer = .fixed(&editor.formatting_buffer);
    const stdout_size = try stdout_reader.interface.streamRemaining(&buffer_writer);

    const term = try child.wait(io);

    if (!term.success()) return false;

    editor.buffer.clearRetainingCapacity();
    editor.buffer.appendSliceAssumeCapacity(editor.formatting_buffer[0..stdout_size]);
    assert(editor.buffer.items.len > 0);
    return true;
}

fn save(editor: *Editor) !void {
    if (!builtin.is_test) {
        try std.Io.Dir.cwd().writeFile(editor.io, .{
            .data = editor.buffer.items,
            .sub_path = editor.file_path,
        });
    }

    editor.dirty = false;
}

const Position = struct { line_number: u32, line_offset: u32 };

const Viewport = struct {
    row_count: u32,
    col_count: u32,
    line_number_start: u32, // line number of the top line
    line_offset_start: u32, // viewport offset into lines (for horizontal scroll)

    /// Coordinate in the viewport.
    const Cell = struct {
        row: u32,
        col: u32,
    };

    /// Last line offset visible in the viewport.
    fn lastOffset(viewport: Viewport) u32 {
        const text_width = viewport.col_count - viewport.gutterWidth();
        return viewport.line_offset_start + text_width - 1;
    }

    /// Last line number visible in the viewport.
    fn lastLine(viewport: Viewport) u32 {
        // The extra -1 is for the status line.
        return viewport.line_number_start + viewport.row_count - 2;
    }

    /// Determine gutter width: enough digits for the greatest visible line number plus one for
    /// padding.
    fn gutterWidth(viewport: Viewport) u8 {
        return digitCount(viewport.line_number_start + viewport.row_count - 1) + 1;
    }
};

const Cursor = struct {
    offset: u32,
    anchor: ?u32,
    line_offset_snap: u32,

    fn update(
        cursor: *Cursor,
        buffer: []const u8,
        offset: u32,
        kind: enum { snap_update, snap_remain },
    ) void {
        assert(buffer.len > 0);
        cursor.offset = @min(offset, buffer.len - 1);
        switch (kind) {
            .snap_update => cursor.line_offset_snap = lineOffset(buffer, cursor.offset),
            // Remain snapped. Make sure offset is on snap OR line end.
            .snap_remain => cursor.offset = lineHead(buffer, cursor.offset) +
                @min(cursor.line_offset_snap, lineSize(buffer, cursor.offset) - 1),
        }
    }

    const Style = enum(u8) {
        steady_bar = 6,
        steady_block = 2,
    };

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
            .down => cursor.update(buffer, @intCast(buffer.len - 1), .snap_remain), // last line
            .up => cursor.update(buffer, 0, .snap_remain), // first line
        }
    }

    fn move(cursor: *Cursor, direction: Direction, count: u32, buffer: []const u8) void {
        switch (direction) {
            .left => cursor.update(buffer, cursor.offset -| count, .snap_update),
            .right => cursor.update(buffer, cursor.offset +| count, .snap_update),
            .up => cursor.update(buffer, moveLineUp(buffer, .{
                .offset = cursor.offset,
                .count = count,
                .line_offset_snap = cursor.line_offset_snap,
            }), .snap_remain),
            .down => cursor.update(buffer, moveLineDown(buffer, .{
                .offset = cursor.offset,
                .count = count,
                .line_offset_snap = cursor.line_offset_snap,
            }), .snap_remain),
        }
    }

    fn selection(cursor: *const Cursor) ?struct {
        head: u32,
        tail: u32,

        fn size(sel: @This()) u32 {
            return sel.tail - sel.head + 1; // +1: offset -> size
        }
    } {
        if (cursor.anchor) |anchor| return .{
            .head = @min(anchor, cursor.offset),
            .tail = @max(anchor, cursor.offset),
        } else return null;
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
        .file_path = file_name,
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
        const value = try parseCsiInt(encoded);
        if (value == 0) return Error.CsiSequenceInvalid;
        if (value - 1 > std.math.maxInt(u8)) return Error.CsiSequenceInvalid;
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

const Event = union(enum) {
    resize: struct { row_count: u32, col_count: u32 },
    ascii: u8,
    chord: struct { ascii: u8, modifiers: Modifiers },
    backspace,
    enter,
    escape,
    tab,
};

/// Handle input: parse Kitty Keyboard Protocol events.
fn parseOne(reader: *std.Io.Reader) !Event {
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
                            .row_count = try parseCsiInt(iter.next() orelse return Error.CsiSequenceInvalid),
                            .col_count = try parseCsiInt(iter.next() orelse return Error.CsiSequenceInvalid),
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

test fuzzKkpParser {
    return std.testing.fuzz({}, fuzzKkpParser, .{});
}
fn fuzzKkpParser(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    var reader_buffer: [128]u8 = undefined;
    const size = smith.slice(&reader_buffer);
    var reader: std.Io.Reader = .fixed(reader_buffer[0..size]);

    while (true) _ = parseOne(&reader) catch |err| switch (err) {
        error.EndOfStream => return,
        Error.CsiSequenceNotRecognised,
        Error.CsiSequenceInvalid,
        => continue,
        else => return err,
    };
}

// test "fuzzKkpParser repro" {
//     const crash = try std.Io.Dir.cwd().readFileAlloc(
//         std.testing.io,
//         ".zig-cache/f/crash",
//         std.testing.allocator,
//         .unlimited,
//     );
//     defer std.testing.allocator.free(crash);
//     try std.testing.fuzz({}, fuzzKkpParser, .{ .corpus = &.{crash} });
// }

fn insert(editor: *Editor, text: []const u8) !void {
    assert(text.len > 0);
    assert(editor.cursor.offset < editor.buffer.items.len);
    try editor.buffer.insertSliceBounded(editor.cursor.offset, text);
    editor.cursor.move(.right, @intCast(text.len), editor.buffer.items);
    editor.dirty = true;
}

/// Delete text under cursor.
fn delete(editor: *Editor) !void {
    if (editor.cursor.selection()) |selection| {
        // We're removing text here so this should never return an error.
        editor.buffer.replaceRangeAssumeCapacity(selection.head, selection.size(), "");
        editor.cursor.anchor = null;
    } else _ = editor.buffer.orderedRemove(editor.cursor.offset);
    // File must always end in a newline.
    if (editor.buffer.items.len == 0 or editor.buffer.last() != '\n')
        editor.buffer.appendAssumeCapacity('\n');
    editor.dirty = true;
}

fn lineIndentation(buffer: []const u8, offset: u32) u32 {
    assert(offset < buffer.len);
    const line_head = lineHead(buffer, offset);
    var i = line_head;
    while (buffer[i] == ' ') i += 1;
    return i - line_head;
}

test lineIndentation {
    try std.testing.expectEqual(2, lineIndentation("  badabop\n boom \npow", 0));
    try std.testing.expectEqual(2, lineIndentation("  badabop\n boom \npow", 3));
    try std.testing.expectEqual(2, lineIndentation("  badabop\n boom \npow", 9));
    try std.testing.expectEqual(1, lineIndentation("  badabop\n boom \npow", 10));
    try std.testing.expectEqual(0, lineIndentation("  badabop\n boom \npow", 17));
}

fn lineHeadFromNumber(buffer: []const u8, line_number: u32) ?u32 {
    var i: u32 = 0;
    var count: u32 = 0;
    while (i < buffer.len and count < line_number) : (i += 1) {
        if (buffer[i] == '\n') count += 1;
    }
    return if (i == buffer.len) null else i;
}

test lineHeadFromNumber {
    try std.testing.expectEqual(0, lineHeadFromNumber("  yo\n\nhi\n\n", 0));
    try std.testing.expectEqual(5, lineHeadFromNumber("  yo\n\nhi\n\n", 1));
    try std.testing.expectEqual(6, lineHeadFromNumber("  yo\n\nhi\n\n", 2));
    try std.testing.expectEqual(9, lineHeadFromNumber("  yo\n\nhi\n\n", 3));
    try std.testing.expectEqual(null, lineHeadFromNumber("  yo\n\nhi\n\n", 4));
}

fn lineOffset(buffer: []const u8, offset: u32) u32 {
    assert(offset < buffer.len);
    return offset - lineHead(buffer, offset);
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

fn lineNumber(buffer: []const u8, offset: u32) u32 {
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
    options: struct { offset: u32, count: u32, line_offset_snap: u32 },
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
    options: struct { offset: u32, count: u32, line_offset_snap: u32 },
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
fn digitCount(number: u32) u8 {
    return std.math.log10_int(number) + 1;
}

test fuzzEditor {
    return std.testing.fuzz({}, fuzzEditor, .{});
}
fn fuzzEditor(_: void, smith: *std.testing.Smith) !void {
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

    const row_count = smith.valueRangeAtMost(u32, 0, row_count_max);
    const col_count = smith.valueRangeAtMost(u32, 0, col_count_max);

    var input: std.Io.Writer.Allocating = .init(allocator);
    defer input.deinit();
    // TODO: Sometimes don't generate resize?
    // First input must be resize (parsed during init below for dimensions).
    try input.writer.print("\x1b[48;{d};{d};0;0t", .{ row_count, col_count }); // pix values ignored
    const input_size = smith.valueRangeAtMost(u32, 0, 4 * 1024); // 4 KiB input max
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

// test "fuzzEditor repro" {
//     const crash = try std.Io.Dir.cwd().readFileAlloc(
//         std.testing.io,
//         ".zig-cache/f/crash",
//         std.testing.allocator,
//         .unlimited,
//     );
//     defer std.testing.allocator.free(crash);
//     try std.testing.fuzz({}, fuzzEditor, .{ .corpus = &.{crash} });
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

const TestEditor = struct {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    reader: std.Io.Reader,
    stripping_writer: StrippingWriter,
    editor: Editor,

    fn init(test_editor: *TestEditor, params: struct {
        file_path: []const u8,
        file_bytes: []const u8,
        input: []const u8,
    }) !void {
        test_editor.stripping_writer = try .init(allocator);
        test_editor.reader = .fixed(params.input);
        test_editor.editor = try .init(
            allocator,
            io,
            &test_editor.reader,
            test_editor.stripping_writer.writer(),
            params.file_path,
            params.file_bytes,
        );
    }

    fn deinit(test_editor: *TestEditor) void {
        test_editor.stripping_writer.deinit();
        test_editor.editor.deinit(allocator);
    }

    fn tick(test_editor: *TestEditor) !void {
        try std.testing.expect(try test_editor.editor.tick());
    }

    fn expectQuit(test_editor: *TestEditor) !void {
        try std.testing.expect(try test_editor.editor.tick()); // process :
        try std.testing.expect(try test_editor.editor.tick()); // process q
        try std.testing.expect(try test_editor.editor.tick()); // process !
        try std.testing.expect(!try test_editor.editor.tick()); // process enter, returns false
    }

    fn clearRenderBuffer(test_editor: *TestEditor) void {
        test_editor.stripping_writer.out.clearRetainingCapacity();
    }

    fn expectRender(
        test_editor: *TestEditor,
        viewport: []const u8,
        cursor_cell: Viewport.Cell,
        cursor_style: Cursor.Style,
    ) !void {
        const expected = try std.fmt.allocPrint(
            allocator,
            "\x1b[?2026h" ++ // begin synchronised update
                "\x1b[2J" ++ // clear screen
                "\x1b[H" ++ // place cursor at top left
                "{s}" ++
                "\x1b[{d}\x20q" ++ // cursor style
                "\x1b[{d};{d}H" ++ // cursor coordinates (indexed from 1)
                "\x1b[?2026l", // end synchronised update
            .{
                viewport,
                @backingInt(cursor_style),
                cursor_cell.row + 1,
                cursor_cell.col + 1,
            },
        );
        defer allocator.free(expected);
        try std.testing.expectEqualSlices(u8, expected, test_editor.stripping_writer.written());
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
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.expectQuit(); // process quit
}

test "rendering: empty" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "empty.zig",
        .file_bytes = "\n",
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "vertical scroll: go to start/end of file" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;5;36;0;0t" ++ // dimensions: 5 rows by 36 cols
            "G" ++ // go to end of file
            "g" ++ // go to start of file
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
        \\1 #include <stdio.h>
        \\2 
        \\3 int main() {
        \\4   printf("Hello, world!\n");
        \\hello.c                          1,1
    , .{ .row = 0, .col = 2 }, .steady_block);

    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process G

    try test_editor.expectRender(
        \\3 int main() {
        \\4   printf("Hello, world!\n");
        \\5   return 0;
        \\6 }
        \\hello.c                          6,1
    , .{ .row = 3, .col = 2 }, .steady_block);

    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process g

    try test_editor.expectRender(
        \\1 #include <stdio.h>
        \\2 
        \\3 int main() {
        \\4   printf("Hello, world!\n");
        \\hello.c                          1,1
    , .{ .row = 0, .col = 2 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "horizontal scroll: go to start/end of line" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;12;0;0t" ++ // dimensions: 12 rows by 12 cols
            "$" ++ // go to end of line
            "0" ++ // go to start of line
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process $

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 11 }, .steady_block);

    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process 0

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "insert mode" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "i" ++ // enter insert mode
            "a" ++ // insert text
            "b" ++ // insert text
            "\x1b[27u" ++ // ESC: return to normal mode
            "$" ++ // move to end of line
            "i" ++ // enter insert mode
            "\x08" ++ // backspace
            "\x1b[27u" ++ // ESC: return to normal mode
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process i

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_bar); // changed to steady bar

    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process a

    try test_editor.expectRender(
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
        //         ^ dirty buffer indicator
    , .{ .row = 0, .col = 4 }, .steady_bar);

    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process b

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 5 }, .steady_bar);

    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process escape

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 5 }, .steady_block); // back to steady block

    try test_editor.tick(); // process $
    try test_editor.tick(); // process i
    try test_editor.tick(); // process backspace
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process escape

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 22 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "new line with o preserves indentation" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "jjj" ++ // move to printf line
            "o" ++ // open new line below
            "x" ++ // insert text
            "\x1b[27u" ++ // ESC: return to normal mode
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process j
    try test_editor.tick(); // process j
    try test_editor.tick(); // process j
    try test_editor.tick(); // process o
    try test_editor.tick(); // process x
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process escape

    try test_editor.expectRender(
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
    , .{ .row = 4, .col = 6 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "new line with O preserves indentation" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "jjj" ++ // move to printf line
            "O" ++ // open new line above
            "x" ++ // insert text
            "\x1b[27u" ++ // ESC: return to normal mode
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process j
    try test_editor.tick(); // process j
    try test_editor.tick(); // process j
    try test_editor.tick(); // process O
    try test_editor.tick(); // process x
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process escape

    try test_editor.expectRender(
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
    , .{ .row = 3, .col = 6 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "insert with I goes to start of line after indentation" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "jjj" ++ // move to printf line
            "I" ++ // insert at first non-whitespace character
            "x" ++ // insert text
            "\x1b[27u" ++ // ESC: return to normal mode
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process j
    try test_editor.tick(); // process j
    try test_editor.tick(); // process j
    try test_editor.tick(); // process I
    try test_editor.tick(); // process x
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process escape

    try test_editor.expectRender(
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
    , .{ .row = 3, .col = 6 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "A inserts at end of line" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "jjj" ++ // move to printf line
            "A" ++ // insert at end of line
            "x" ++ // insert text
            "\x1b[27u" ++ // ESC: return to normal mode
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process j
    try test_editor.tick(); // process j
    try test_editor.tick(); // process j
    try test_editor.tick(); // process A
    try test_editor.tick(); // process x
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process escape

    try test_editor.expectRender(
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
    , .{ .row = 3, .col = 32 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "tab inserts four spaces" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "i" ++ // enter insert mode
            "\t" ++ // insert four spaces
            "x" ++ // insert text
            "\x1b[27u" ++ // ESC: return to normal mode
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process i
    try test_editor.tick(); // process tab
    try test_editor.tick(); // process x
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process escape

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 8 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "enter preserves indentation" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "jjj" ++ // move to printf line
            "I" ++ // insert at first non-whitespace character
            "x" ++ // insert text
            "\r" ++ // enter
            "y" ++ // insert text
            "\x1b[27u" ++ // ESC: return to normal mode
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process j
    try test_editor.tick(); // process j
    try test_editor.tick(); // process j
    try test_editor.tick(); // process I
    try test_editor.tick(); // process x
    try test_editor.tick(); // process enter
    try test_editor.tick(); // process y
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process escape

    try test_editor.expectRender(
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
    , .{ .row = 4, .col = 6 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "delete" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "d" ++ // delete first character
            "$" ++ // move to end of line
            "d" ++ // delete newline (character at end of line)
            "G" ++ // move to last line
            "$" ++ // move to end of line
            "d" ++ // move to end of line
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process d

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process $
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process d

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 20 }, .steady_block);

    try test_editor.tick(); // process G
    try test_editor.tick(); // process $
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process d

    // Same as last time. You can't delete the final newline.
    try test_editor.expectRender(
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
    , .{ .row = 4, .col = 4 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "delete selection" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
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
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process $
    try test_editor.tick(); // process v
    try test_editor.tick(); // process 0
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process d

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process j
    try test_editor.tick(); // process e
    try test_editor.tick(); // process v
    try test_editor.tick(); // process G
    try test_editor.tick(); // process $
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process d

    try test_editor.expectRender(
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
    , .{ .row = 1, .col = 5 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "save file" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "d" ++ // delete first character
            ":w\r" ++ // save file
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process d

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process :
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process w

    try test_editor.expectRender(
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
        \\:w
    , .{ .row = 11, .col = 2 }, .steady_bar);

    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process \r

    try test_editor.expectRender(
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
        \\hello.c                          1,1
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "save file and quit" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "d" ++ // delete first character
            ":wq\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process d

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process :
    try test_editor.tick(); // process w
    try test_editor.tick(); // process q
    try std.testing.expect(!try test_editor.editor.tick()); // process \r
}

test "quit" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            ":q\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process :
    try test_editor.tick(); // process q
    try std.testing.expect(!try test_editor.editor.tick()); // process \r
}

test "quit without saving" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "d" ++ // delete first character
            ":q\r" ++ // try quit
            "y", // respond to unsaved prompt: save and quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process d

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process :
    try test_editor.tick(); // process q
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process \r

    try test_editor.expectRender(
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
        \\Save changes to hello.c (y/n)?
    , .{ .row = 0, .col = 3 }, .steady_block);

    try std.testing.expect(!try test_editor.editor.tick()); // process \r
}

test "go to line" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "$" ++ // go to end of line
            ":5\r" ++ // go to line 5
            ":wq\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process $
    try test_editor.tick(); // process :
    try test_editor.tick(); // process 5
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process \r

    try test_editor.expectRender(
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
        \\hello.c                         5,12
    , .{ .row = 4, .col = 14 }, .steady_block);

    try test_editor.expectQuit(); // process :q!\r
}

test "user message" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            ":a1\r" ++ // some invalid command
            "\x1b[27u" ++ // ESC: dismiss command and return to normal mode
            ":wq\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process :
    try test_editor.tick(); // process a
    try test_editor.tick(); // process 1
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process \r

    try test_editor.expectRender(
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
        \\invalid command
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process escape
    try test_editor.expectQuit(); // process :q!\r
}

test "selection highlighting" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "v" ++ // start selection
            "jj" ++ // multi-line selection
            "v" ++ // toggle selection
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    try test_editor.expectRender(
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
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.tick(); // process v
    try test_editor.tick(); // process j
    test_editor.clearRenderBuffer();
    try test_editor.tick(); // process j

    try test_editor.expectRender(
        \\ 1 
    ++ esc_highlight_foreground ++ esc_highlight_background ++
        "#include <stdio.h>" ++ esc_colour_reset ++ "\n" ++
        \\ 2 
        \\ 3 
    ++ esc_highlight_foreground ++ esc_highlight_background ++
        "i" ++ esc_colour_reset ++ "nt main() {\n" ++
        \\ 4   printf("Hello, world!\n");
        \\ 5   return 0;
        \\ 6 }
        \\ 7 ~
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c                          3,1
    , .{ .row = 2, .col = 3 }, .steady_block);

    try test_editor.tick(); // process v
    try test_editor.expectQuit(); // process :q!\r
}
