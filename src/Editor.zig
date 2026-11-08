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

const Editor = @This();
const assert = std.debug.assert;

const esc_highlight_foreground = "\x1b[30m"; // black
const esc_highlight_background = "\x1b[47m"; // white (light gray on most palettes)
const esc_line_number_foreground = "\x1b[33m"; // yellow
const esc_colour_reset = "\x1b[0m";

/// All allocated memory used by the editor lives in this struct.
pub const Buffers = struct {
    document: []u8,
    clipboard: []u8,
    scratch: []u8,
    prompt: []u8, // prompt command text or message

    pub fn alloc(
        allocator: std.mem.Allocator,
        options: struct { file_size_max: u32, col_count_max: u32 },
    ) error{OutOfMemory}!Buffers {
        const document = try allocator.alloc(u8, options.file_size_max);
        errdefer allocator.free(document);
        const clipboard = try allocator.alloc(u8, options.file_size_max);
        errdefer allocator.free(clipboard);
        const scratch = try allocator.alloc(u8, options.file_size_max);
        errdefer allocator.free(scratch);
        // -1 accounts for the ':' shown when the prompt is active.
        const prompt = try allocator.alloc(u8, options.col_count_max - 1);
        errdefer allocator.free(prompt);

        return .{
            .document = document,
            .clipboard = clipboard,
            .scratch = scratch,
            .prompt = prompt,
        };
    }

    pub fn free(buffers: Buffers, allocator: std.mem.Allocator) void {
        allocator.free(buffers.document);
        allocator.free(buffers.clipboard);
        allocator.free(buffers.scratch);
        allocator.free(buffers.prompt);
    }
};

io: std.Io,
writer: *std.Io.Writer,

is_test: bool,
col_count_max: u32,
row_count_max: u32,
file_path: []const u8,
viewport: Viewport,
cursor: Cursor,
mode: union(enum) {
    normal,
    insert,
    prompt: union(enum) {
        command: struct { text: std.ArrayList(u8), cursor_offset: u32 },
        message: std.ArrayList(u8),
        unsaved,
    },
},
document: std.ArrayList(u8),
dirty: bool,
prompt_buffer: []u8, // shared by prompt command text and messages
scratch_buffer: []u8, // used for formatting, selection paste
clipboard: std.ArrayList(u8),

pub fn tick(editor: *Editor, event: Event) !bool {
    if (event == .resize) {
        editor.viewport.row_count = event.resize.row_count;
        editor.viewport.col_count = event.resize.col_count;
        // Crop the command text so it still fits on the row with the ':' prompt prefix and the
        // cursor after it.
        if (editor.mode == .prompt and editor.mode.prompt == .command) {
            const command = &editor.mode.prompt.command;
            assert(command.cursor_offset == command.text.items.len);
            command.text.shrinkRetainingCapacity(
                @min(command.text.items.len, editor.viewport.col_count -| 2),
            );
            command.cursor_offset = @intCast(command.text.items.len);
        }
    } else switch (editor.mode) {
        .normal => switch (event) {
            .ascii => |c| switch (c) {
                'h' => editor.cursor.move(.left, 1, editor.document.items),
                'l' => editor.cursor.move(.right, 1, editor.document.items),
                'j' => editor.cursor.move(.down, 1, editor.document.items),
                'k' => editor.cursor.move(.up, 1, editor.document.items),
                '0' => editor.cursor.moveMax(.left, editor.document.items),
                '$' => editor.cursor.moveMax(.right, editor.document.items),
                'G' => editor.cursor.moveMax(.down, editor.document.items),
                'g' => editor.cursor.moveMax(.up, editor.document.items),
                'e' => editor.cursor.update(
                    editor.document.items,
                    wordTailNext(editor.document.items, editor.cursor.offset),
                    .snap_update,
                ),
                'E' => editor.cursor.update(
                    editor.document.items,
                    tokenTailNext(editor.document.items, editor.cursor.offset),
                    .snap_update,
                ),
                'b' => editor.cursor.update(
                    editor.document.items,
                    wordHeadPrev(editor.document.items, editor.cursor.offset),
                    .snap_update,
                ),
                'B' => editor.cursor.update(
                    editor.document.items,
                    tokenHeadPrev(editor.document.items, editor.cursor.offset),
                    .snap_update,
                ),
                'w' => editor.cursor.update(
                    editor.document.items,
                    wordHeadNext(editor.document.items, editor.cursor.offset),
                    .snap_update,
                ),
                'W' => editor.cursor.update(
                    editor.document.items,
                    tokenHeadNext(editor.document.items, editor.cursor.offset),
                    .snap_update,
                ),
                // Don't go into insert mode if a selection is active.
                'i' => if (editor.cursor.anchor == null) {
                    editor.mode = .insert;
                },
                'I' => if (editor.cursor.anchor == null) {
                    const offset = lineHead(editor.document.items, editor.cursor.offset) +
                        lineIndentation(editor.document.items, editor.cursor.offset);
                    editor.cursor.update(editor.document.items, offset, .snap_update);
                    editor.mode = .insert;
                },
                'a' => if (editor.cursor.anchor == null) {
                    if (editor.document.items[editor.cursor.offset] != '\n')
                        editor.cursor.move(.right, 1, editor.document.items);
                    editor.mode = .insert;
                },
                'A' => if (editor.cursor.anchor == null) {
                    editor.cursor.moveMax(.right, editor.document.items);
                    editor.mode = .insert;
                },
                    editor.cursor.moveMax(.right, editor.document.items);
                    const indentation = lineIndentation(
                        editor.document.items,
                        editor.cursor.offset,
                'o' => if (editor.cursor.anchor == null) {
                    );
                    try insert(&editor.document, &editor.cursor, &editor.dirty, "\n");
                    for (0..indentation) |_| try insert(
                        &editor.document,
                        &editor.cursor,
                        &editor.dirty,
                        " ",
                    );
                    editor.mode = .insert;
                },
                'O' => if (editor.cursor.anchor == null) {
                    editor.cursor.moveMax(.left, editor.document.items);
                    const indentation = lineIndentation(
                        editor.document.items,
                        editor.cursor.offset,
                    );
                    try insert(&editor.document, &editor.cursor, &editor.dirty, "\n");
                    editor.cursor.move(.up, 1, editor.document.items);
                    for (0..indentation) |_| try insert(
                        &editor.document,
                        &editor.cursor,
                        &editor.dirty,
                        " ",
                    );
                    editor.mode = .insert;
                },
                // Enable/disable selection. If we have a selection in the same mode, deselect,
                // otherwise, do selection. Going from a linewise selection to a normal one,
                // and vice versa, is valid.
                'v' => editor.cursor.anchor = if (editor.cursor.anchor) |anchor|
                    if (!anchor.lines) null else .{ .offset = anchor.offset, .lines = false }
                else
                    .{ .offset = editor.cursor.offset, .lines = false },
                // Enable/disable linewise selection. Same as above.
                'V' => editor.cursor.anchor = if (editor.cursor.anchor) |anchor|
                    if (anchor.lines) null else .{ .offset = anchor.offset, .lines = true }
                else
                    .{ .offset = editor.cursor.offset, .lines = true },
                'd' => delete(
                    &editor.document,
                    &editor.clipboard,
                    &editor.cursor,
                    &editor.dirty,
                ),
                ':' => editor.mode = .{
                    .prompt = .{
                        .command = .{
                            .text = .initBuffer(editor.prompt_buffer),
                            .cursor_offset = 0,
                        },
                    },
                },
                'y' => yank(editor.document.items, &editor.clipboard, &editor.cursor),
                // Yank the lines covered by the selection or, without one, the cursor's line.
                // The cursor stays where it is.
                'Y' => {
                    const anchor_offset = if (editor.cursor.anchor) |anchor|
                        anchor.offset
                    else
                        editor.cursor.offset;
                    var lines = editor.cursor;
                    lines.anchor = .{ .offset = anchor_offset, .lines = true };
                    yankInner(editor.document.items, &editor.clipboard, lines);
                    editor.cursor.anchor = null;
                },
                // Delete the lines covered by the selection or, without one, the cursor's line.
                'D' => {
                    const anchor_offset = if (editor.cursor.anchor) |anchor|
                        anchor.offset
                    else
                        editor.cursor.offset;
                    editor.cursor.anchor = .{ .offset = anchor_offset, .lines = true };
                    delete(&editor.document, &editor.clipboard, &editor.cursor, &editor.dirty);
                },
                // 'P' => {}, // TODO: paste before
                'p' => try paste(
                    &editor.document,
                    &editor.clipboard,
                    editor.scratch_buffer,
                    &editor.cursor,
                    &editor.dirty,
                ),
                'z' => editor.centreCursorVertically(),
                else => {},
            },
            .chord => |chord| {
                const ctrl: Modifiers = .{ .ctrl = true };
                switch (chord.ascii) {
                    'u', 'd' => |c| if (chord.modifiers == ctrl) {
                        editor.cursor.move(
                            if (c == 'u') .up else .down,
                            editor.viewport.row_count / 3,
                            editor.document.items,
                        );
                        editor.centreCursorVertically();
                    },
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
            switch (event) {
                .escape => editor.mode = .normal,
                .ascii => |c| try insert(
                    &editor.document,
                    &editor.cursor,
                    &editor.dirty,
                    &.{c},
                ),
                .backspace => if (editor.cursor.offset != 0) {
                    editor.cursor.move(.left, 1, editor.document.items);
                    // Using replace here instead of delete because delete updates clipboard.
                    replace(
                        &editor.document,
                        &editor.dirty,
                        editor.cursor.offset,
                        1,
                        "",
                    ) catch unreachable;
                },
                .tab => try insert(&editor.document, &editor.cursor, &editor.dirty, "    "),
                .enter => {
                    const indent_count = lineIndentation(
                        editor.document.items,
                        editor.cursor.offset,
                    );
                    try insert(&editor.document, &editor.cursor, &editor.dirty, "\n");
                    for (0..indent_count) |_|
                        try insert(&editor.document, &editor.cursor, &editor.dirty, " ");
                },
                .chord => {}, // do nothing
                .resize => unreachable,
            }
        },
        .prompt => |*prompt| switch (prompt.*) {
            .command => |*command| switch (event) {
                .escape => editor.mode = .normal,
                // Keep entering text as long as we've got room in the document and on the row. The
                // -2 below (aside from count->index) is to account for the prompt prefix, ':'.
                .ascii => |c| if (command.cursor_offset < command.text.capacity and
                    command.cursor_offset < editor.viewport.col_count - 2)
                {
                    assert(command.cursor_offset == command.text.items.len);
                    try command.text.insertBounded(command.cursor_offset, c);
                    command.cursor_offset += 1;
                    assert(command.cursor_offset == command.text.items.len);
                },
                .backspace => if (command.cursor_offset != 0) {
                    assert(command.cursor_offset == command.text.items.len);
                    _ = command.text.orderedRemove(command.cursor_offset - 1);
                    command.cursor_offset -= 1;
                    assert(command.cursor_offset == command.text.items.len);
                },
                .enter => if (std.meta.stringToEnum(
                    enum { w, q, @"w!", @"q!", wq, @"wq!" },
                    command.text.items,
                )) |name| switch (name) {
                    .w => if (try editor.formatAndSave()) {
                        editor.mode = .normal;
                    },
                    .q => {
                        if (!editor.dirty) return false; // exit!
                        // Trying to exit without saving. Prompt user to save.
                        editor.mode = .{ .prompt = .unsaved };
                    },
                    .@"w!" => { // skip formatting
                        try editor.save();
                        editor.mode = .normal;
                    },
                    .@"q!" => return false, // exit, for real!
                    .wq => if (try editor.formatAndSave()) return false, // exit if saved
                    .@"wq!" => { // skip formatting
                        try editor.save();
                        return false;
                    },
                } else if (std.fmt.parseInt(u32, command.text.items, 10) catch null) |number| {
                    // Line number given is indexed from 1.
                    const line_number = @max(number, 1) - 1;
                    if (lineHeadFromNumber(editor.document.items, line_number)) |head| {
                        editor.cursor.update(editor.document.items, head, .snap_remain);
                        editor.centreCursorVertically();
                    }
                    editor.mode = .normal;
                } else editor.showMessage("invalid command", .{}),
                .tab, .chord => {}, // do nothing
                .resize => unreachable,
            },
            .message => switch (event) {
                .enter, .escape => editor.mode = .normal,
                .ascii, .tab, .chord, .backspace => {}, // do nothing
                .resize => unreachable,
            },
            .unsaved => switch (event) {
                .escape => editor.mode = .normal,
                .ascii => |c| switch (c) {
                    'y' => if (try editor.formatAndSave()) return false, // exit if saved
                    'n' => return false, // quit without saving
                    else => {}, // do nothing
                },
                .enter, .tab, .chord, .backspace => {}, // do nothing
                .resize => unreachable,
            },
        },
    }

    const cursor_position = position(editor.document.items, editor.cursor.offset);

    // Cursor is always at snap line offset or line end.
    assert(cursor_position.line_offset == @min(
        editor.cursor.line_offset_snap,
        lineSize(editor.document.items, editor.cursor.offset) - 1,
    ));
    assert(cursor_position.line_offset <= editor.cursor.line_offset_snap);
    // Selection must point into the document.
    if (editor.cursor.anchor) |anchor| assert(anchor.offset < editor.document.items.len);
    if (editor.cursor.selection(editor.document.items)) |selection| {
        assert(selection.head < editor.document.items.len);
        assert(selection.tail < editor.document.items.len);
    }

    try editor.focus(cursor_position);
    try editor.render(cursor_position);

    return true;
}

/// Focus the viewport: Ensure it contains the cursor.
fn focus(editor: *Editor, cursor: Position) error{ ViewportTooSmall, ViewportTooLarge }!void {
    const row_count = editor.viewport.row_count;
    const row_count_max = editor.row_count_max;
    const col_count = editor.viewport.col_count;
    const col_count_max = editor.col_count_max;
    const line_number = cursor.line_number;
    const line_offset = cursor.line_offset;

    // Check viewport dimensions.
    if (row_count < 2) return error.ViewportTooSmall; // at least one line plus the status line
    if (row_count > row_count_max) return error.ViewportTooLarge;
    if (col_count < editor.viewport.gutterWidth() + 1)
        return error.ViewportTooSmall; // at least one char
    if (col_count > col_count_max) return error.ViewportTooLarge;

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

    // Make sure cursor is within the viewport's bounds.
    assert(cursor.line_number >= editor.viewport.line_number_start);
    assert(cursor.line_number <= editor.viewport.lastLine());
    assert(cursor.line_offset >= editor.viewport.line_offset_start);
    assert(cursor.line_offset <= editor.viewport.lastOffset());
}

fn render(editor: *const Editor, cursor: Position) !void {
    const writer = editor.writer;
    const row_count = editor.viewport.row_count;
    const col_count = editor.viewport.col_count;
    const gutter_width = editor.viewport.gutterWidth();
    const line_number_start = editor.viewport.line_number_start;
    const line_offset_start = editor.viewport.line_offset_start;
    const document = editor.document.items;
    const file_path = editor.file_path;

    // Begin synchronised update. See
    // https://contour-terminal.org/vt-extensions/synchronized-output.
    try writer.writeAll("\x1b[?2026h");
    // Clear screen. See https://ghostty.org/docs/vt/csi/ed.
    try writer.writeAll("\x1b[2J");
    // Place cursor at top left. See https://ghostty.org/docs/vt/csi/cup.
    try writer.writeAll("\x1b[H");

    // Render the document.
    assert(document.len > 0);
    var line_head = blk: {
        var i: u32 = lineHead(document, editor.cursor.offset);
        for (0..cursor.line_number - line_number_start) |_| i = lineHead(document, i - 1);
        break :blk i;
    };
    var highlight = false;
    for (line_number_start..line_number_start + row_count - 1) |line_number| {
        if (line_head < document.len) {
            // Draw gutter: coloured line number and space delimiter.
            try writer.print(esc_line_number_foreground ++ "{[line_number]d: >[gutter_width]}" ++
                esc_colour_reset ++ " ", .{
                .line_number = line_number + 1, // displayed line number indexed from 1
                .gutter_width = gutter_width - 1, // space suffix already in format string
            });

            const line_tail = lineTail(document, line_head);

            // Handle horizontal scroll.
            const text_width = col_count - gutter_width;
            const cropped_head = @min(line_head + line_offset_start, line_tail);
            const cropped_tail = @min(line_tail, cropped_head + text_width);

            if (line_head == line_tail) {} // empty line
            // Handle selection highlighting.
            else if (editor.cursor.selection(document)) |selection| {
                const esc_highlight = esc_highlight_foreground ++ esc_highlight_background;

                // Should we have already started/stopped highlighting? E.g. anchor not within
                // cropped line.
                if (selection.head < cropped_head) highlight = true;
                if (selection.tail < cropped_head) highlight = false;

                if (highlight) try writer.writeAll(esc_highlight);

                for (cropped_head..cropped_tail) |offset| {
                    if (offset == selection.head) {
                        highlight = true;
                        try writer.writeAll(esc_highlight);
                    }

                    try writer.writeByte(document[offset]);

                    if (offset == selection.tail) {
                        highlight = false;
                        try writer.writeAll(esc_colour_reset);
                    }
                }

                // Reset before printing the next line so that line numbers aren't highlighted.
                if (highlight) try writer.writeAll(esc_colour_reset);
            } else try writer.writeAll(document[cropped_head..cropped_tail]); // normal line

            line_head = line_tail + 1;
        } else try writer.writeByte('~'); // past end of document: '~' in gutter
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
            var min_size = file_path.len;
            const dirty_indicator = " [+]";
            if (editor.dirty) min_size += dirty_indicator.len;
            min_size += cursor_coordinates_col_count + 1; // 1 for padding
            if (min_size > col_count) return error.ViewportTooSmall;

            try writer.writeAll(file_path);
            if (editor.dirty) try writer.writeAll(dirty_indicator);
            try writer.splatByteAll(' ', col_count - min_size);
            try writer.print(" {d},{d}", .{ cursor.line_number + 1, cursor.line_offset + 1 });
        },
        // Draw prompt. Takes place of status line.
        .prompt => |prompt| switch (prompt) {
            .command => |command| {
                try writer.writeByte(':');
                try writer.writeAll(command.text.items);
            },
            .unsaved => try writer.print("Save changes to {s} (y/n)?", .{editor.file_path}),
            // Crop messages that don't fit on the row.
            .message => |message| try writer.writeAll(
                message.items[0..@min(message.items.len, col_count)],
            ),
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

pub fn init(args: struct {
    io: std.Io,
    buffers: Buffers,
    file_path: []const u8,
    file_reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    col_count: u32,
    row_count: u32,
    col_count_max: u32,
    row_count_max: u32,
    cursor_line_number: u32,
    cursor_line_offset: u32,
    is_test: bool,
}) error{ FileTooLong, FileContainsInvalidCharacter, ReadFailed }!Editor {
    // The max file size is the size of the document buffer (same size as clipboard and scratch
    // buffers).
    assert(args.buffers.document.len == args.buffers.clipboard.len);
    assert(args.buffers.document.len == args.buffers.scratch.len);
    assert(args.buffers.prompt.len == args.col_count_max - 1); // -1 for the ':' in prompt

    // Read file into scratch buffer before loading into `document`.
    var scratch_writer: std.Io.Writer = .fixed(args.buffers.scratch);
    const file_size =
        args.file_reader.streamRemaining(&scratch_writer) catch |err| switch (err) {
            error.WriteFailed => return error.FileTooLong,
            error.ReadFailed => |e| return e,
        };
    var document: std.ArrayList(u8) = .initBuffer(args.buffers.document);
    var dirty = false;
    try load(&document, &dirty, args.buffers.scratch, @intCast(file_size));

    const cursor_offset_start =
        offsetFromPosition(document.items, args.cursor_line_number, args.cursor_line_offset);

    return .{
        .is_test = args.is_test,
        .io = args.io,
        .writer = args.writer,
        .mode = .normal,
        .viewport = .{
            .row_count = args.row_count,
            .col_count = args.col_count,
            .line_number_start = 0,
            .line_offset_start = 0,
        },
        .file_path = args.file_path,
        .document = document,
        .dirty = dirty,
        .cursor = .{
            .offset = cursor_offset_start orelse 0,
            .anchor = null,
            .line_offset_snap = if (cursor_offset_start) |_| args.cursor_line_offset else 0,
        },
        .clipboard = .initBuffer(args.buffers.clipboard),
        .prompt_buffer = args.buffers.prompt,
        .scratch_buffer = args.buffers.scratch,
        .col_count_max = args.col_count_max,
        .row_count_max = args.row_count_max,
    };
}

/// Do initial render. After this, `tick` renders on every event.
pub fn start(editor: *Editor) !void {
    const cursor_position = position(editor.document.items, editor.cursor.offset);
    try editor.focus(cursor_position);
    editor.centreCursorVertically();
    try editor.render(cursor_position);
}

/// Show a message in place of the status line. Written to the prompt buffer, cropped if it
/// doesn't fit. Don't pass the command text in `args`, it's in the same buffer.
fn showMessage(editor: *Editor, comptime format: []const u8, args: anytype) void {
    var message_writer: std.Io.Writer = .fixed(editor.prompt_buffer);
    message_writer.print(format, args) catch {}; // fixed writer keeps what fits
    editor.mode = .{ .prompt = .{ .message = message_writer.toArrayList() } };
}

/// Format document if formatter available then save. If formatting fails, show the error and
/// don't save. Returns whether the document was saved so the caller can decide what to do next
/// (e.g. exit).
fn formatAndSave(editor: *Editor) !bool {
    if (try editor.formatDocument() == false) {
        editor.showMessage("formatting failed", .{});
        return false;
    }
    try editor.save();
    return true;
}

fn centreCursorVertically(editor: *Editor) void {
    const line_number = lineNumber(editor.document.items, editor.cursor.offset);
    const rows_to_middle = editor.viewport.row_count / 2 - 1;
    if (rows_to_middle < line_number)
        editor.viewport.line_number_start = line_number - rows_to_middle;
}

fn formatDocument(editor: *Editor) !?bool {
    const formatted = (if (editor.is_test) formatDocumentWithTestFormatter(
        editor.document.items,
        editor.scratch_buffer,
    ) else blk: {
        const extension = std.meta.stringToEnum(
            enum { @".zig", @".zon", @".md", @".sh", @".c", @".h", @".cpp", @".hpp" },
            std.fs.path.extension(editor.file_path),
        ) orelse return null; // no formatter, save as is
        break :blk try runFormatter(editor.io, switch (extension) {
            .@".zig", .@".zon" => &.{ "zig", "fmt", "--stdin" },
            .@".md" => &.{ "prettier", "--parser", "markdown" },
            .@".sh" => &.{ "shfmt", "--indent", "4" },
            .@".c", .@".h", .@".cpp", .@".hpp" => &.{ "clang-format", "--style=Google" }, // C, C++
        }, editor.document.items, editor.scratch_buffer);
    }) orelse return false;

    // Treat output we can't accept as a formatting failure, leaving the document untouched.
    // Check it's valid before replacing, replace asserts on invalid characters.
    validateDocument(formatted) catch return false;
    replace(
        &editor.document,
        &editor.dirty,
        0,
        @intCast(editor.document.items.len),
        formatted,
    ) catch return false; // too long once the trailing newline is added

    editor.cursor.anchor = null;

    // Move cursor to start of line.
    const offset = @min(editor.cursor.offset, editor.document.items.len - 1);
    const offset_new = lineHead(editor.document.items, offset) +
        lineIndentation(editor.document.items, offset);
    editor.cursor.update(editor.document.items, offset_new, .snap_update);

    return true;
}

fn save(editor: *Editor) !void {
    if (!editor.is_test) {
        try std.Io.Dir.cwd().writeFile(editor.io, .{
            .data = editor.document.items,
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
        // Going from count to index: subtract 1.
        const line_number_last = viewport.line_number_start + viewport.row_count - 1;
        // Displayed line numbers indexed from 1, so add 1.
        const line_number_last_width = digitCount(line_number_last + 1);
        return line_number_last_width + 1; // +1: padding
    }
};

const Cursor = struct {
    offset: u32,
    /// Cursor selection is implemented with anchor. A normal selection is just the cursor offset to
    /// the anchor offset, or vice versa if the anchor comes before. See `selection`. If we are
    /// selecting lines (e.g 'V'), lines is true.
    anchor: ?struct { offset: u32, lines: bool },
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
                cursor.line_offset_snap = std.math.maxInt(u32);
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

    fn selection(cursor: Cursor, document: []const u8) ?struct {
        head: u32,
        tail: u32,

        fn size(s: @This()) u32 {
            return s.tail - s.head + 1; // +1: offset -> size
        }

        fn slice(s: @This(), buffer: []const u8) []const u8 {
            return buffer[s.head .. s.tail + 1];
        }
    } {
        if (cursor.anchor) |anchor| {
            const selection_head = @min(anchor.offset, cursor.offset);
            const selection_tail = @max(anchor.offset, cursor.offset);
            return .{
                .head = if (anchor.lines) lineHead(document, selection_head) else selection_head,
                .tail = if (anchor.lines) lineTail(document, selection_tail) else selection_tail,
            };
        } else return null;
    }

    fn head(cursor: Cursor, document: []const u8) u32 {
        return if (cursor.selection(document)) |s| s.head else cursor.offset;
    }
};

/// All modifications to the document happen through this function. This allows us to handle all
/// modification checks and invariants in one place. Replacing an empty range (offset with size 0)
/// is insertion. Replacing a range with nothing is deletion.
fn replace(
    document: *std.ArrayList(u8),
    dirty: *bool,
    offset: u32,
    size: u32,
    text: []const u8,
) error{FileTooLong}!void {
    assert(document.items.len > 0);
    assert(document.last() == '\n');
    // Offset may equal the document size for an insertion at the very end (after the trailing
    // newline). The second assert rules out deleting past the end.
    assert(offset <= document.items.len);
    assert(offset + size <= document.items.len);
    assert(size > 0 or text.len > 0); // must be an insertion or deletion, should never be a noop
    // Text must not alias the document.
    assert(text.len == 0 or
        @intFromPtr(text.ptr) >= @intFromPtr(document.items.ptr) + document.capacity or
        @intFromPtr(text.ptr) + text.len <= @intFromPtr(document.items.ptr));
    for (text) |c| assert(characterValid(c));

    // The document must always end in a newline. Work out up front whether we'll need to append
    // one so that we can check the final size before modifying anything. Either the whole
    // replacement happens or none of it does.
    const newline_needed = newline_needed: {
        // If the range doesn't reach the end of the document the existing trailing newline stays.
        if (offset + size < document.items.len) break :newline_needed false;
        if (text.len == 0) {
            // We're deleting a range that reaches the end of the document, check if the last byte
            // before the range (becomes the end) is a newline.
            if (offset == 0) break :newline_needed true; // deleting entire document
            if (document.items[offset - 1] != '\n') break :newline_needed true;
        } else {
            // Replacing end of file with text. Check the last byte.
            if (text[text.len - 1] != '\n') break :newline_needed true;
        }
        break :newline_needed false;
    };
    const size_new = document.items.len - size + text.len + @intFromBool(newline_needed);
    if (size_new > document.capacity) return error.FileTooLong;

    document.replaceRangeAssumeCapacity(offset, size, text);
    if (newline_needed) document.appendAssumeCapacity('\n');
    assert(document.items.len == size_new);
    assert(document.last() == '\n');
    dirty.* = true;
}

test replace {
    var document_buffer: [8]u8 = undefined;
    var document: std.ArrayList(u8) = .initBuffer(&document_buffer);
    var dirty = false;

    // Full document. Replacing the last line with text that doesn't end in a newline needs one
    // more byte than we have. Nothing should change.
    document.appendSliceAssumeCapacity("abc\ndef\n");
    try std.testing.expectError(error.FileTooLong, replace(&document, &dirty, 4, 4, "wxyz"));
    try std.testing.expectEqualStrings("abc\ndef\n", document.items);
    try std.testing.expect(!dirty);

    // Same but one byte shorter fits exactly once the newline is added back.
    try replace(&document, &dirty, 4, 4, "wxy");
    try std.testing.expectEqualStrings("abc\nwxy\n", document.items);
    try std.testing.expect(dirty);

    // Insertion that overflows.
    dirty = false;
    try std.testing.expectError(error.FileTooLong, replace(&document, &dirty, 0, 0, "x"));
    try std.testing.expectEqualStrings("abc\nwxy\n", document.items);
    try std.testing.expect(!dirty);

    // Deleting the trailing newline puts it back.
    try replace(&document, &dirty, 7, 1, "");
    try std.testing.expectEqualStrings("abc\nwxy\n", document.items);

    // Deleting the last line including its newline. The byte before the range is already a
    // newline so one isn't added.
    try replace(&document, &dirty, 4, 4, "");
    try std.testing.expectEqualStrings("abc\n", document.items);

    // Deleting everything leaves a single newline.
    try replace(&document, &dirty, 0, 4, "");
    try std.testing.expectEqualStrings("\n", document.items);

    // Replacing everything with text that ends in a newline doesn't add another.
    try replace(&document, &dirty, 0, 1, "hello\n");
    try std.testing.expectEqualStrings("hello\n", document.items);

    // Inserting at the very end, after the trailing newline.
    try replace(&document, &dirty, 6, 0, "x\n");
    try std.testing.expectEqualStrings("hello\nx\n", document.items);
}

fn insert(
    document: *std.ArrayList(u8),
    cursor: *Cursor,
    dirty: *bool,
    text: []const u8,
) error{FileTooLong}!void {
    assert(text.len > 0);
    assert(cursor.offset < document.items.len);
    const offset = cursor.offset;
    try replace(document, dirty, cursor.offset, 0, text);
    cursor.move(.right, @intCast(text.len), document.items);
    assert(cursor.offset == offset + text.len);
}

test insert {
    var document_buffer: [16]u8 = undefined;
    var document: std.ArrayList(u8) = .initBuffer(&document_buffer);
    document.appendSliceAssumeCapacity("abc\ndef\n");
    var cursor: Cursor = undefined;
    var dirty = false;

    // Mid-line. Cursor ends up on the character after the inserted text.
    cursor = .{ .offset = 1, .anchor = null, .line_offset_snap = 1 };
    try insert(&document, &cursor, &dirty, "xy");
    try std.testing.expectEqualStrings("axybc\ndef\n", document.items);
    try std.testing.expectEqual(3, cursor.offset);
    try std.testing.expectEqual(3, cursor.line_offset_snap);
    try std.testing.expect(dirty);

    // Start of document.
    dirty = false;
    cursor = .{ .offset = 0, .anchor = null, .line_offset_snap = 0 };
    try insert(&document, &cursor, &dirty, "z");
    try std.testing.expectEqualStrings("zaxybc\ndef\n", document.items);
    try std.testing.expectEqual(1, cursor.offset);
    try std.testing.expectEqual(1, cursor.line_offset_snap);
    try std.testing.expect(dirty);

    // Newline splits the line. Cursor moves to the start of the new line.
    cursor = .{ .offset = 3, .anchor = null, .line_offset_snap = 3 };
    try insert(&document, &cursor, &dirty, "\n");
    try std.testing.expectEqualStrings("zax\nybc\ndef\n", document.items);
    try std.testing.expectEqual(4, cursor.offset);
    try std.testing.expectEqual(0, cursor.line_offset_snap);

    // Before the trailing newline (end of last line). Cursor stays on the trailing newline.
    cursor = .{ .offset = 11, .anchor = null, .line_offset_snap = 3 };
    try insert(&document, &cursor, &dirty, "g");
    try std.testing.expectEqualStrings("zax\nybc\ndefg\n", document.items);
    try std.testing.expectEqual(12, cursor.offset);
    try std.testing.expectEqual(4, cursor.line_offset_snap);

    // Text ending in a newline before the trailing newline. Leaves an empty last line, no extra
    // newline is added.
    try insert(&document, &cursor, &dirty, "\n");
    try std.testing.expectEqualStrings("zax\nybc\ndefg\n\n", document.items);
    try std.testing.expectEqual(13, cursor.offset);
    try std.testing.expectEqual(0, cursor.line_offset_snap);

    // Overflow. Document, cursor and dirty are untouched.
    dirty = false;
    const cursor_before = cursor;
    try std.testing.expectError(error.FileTooLong, insert(&document, &cursor, &dirty, "xyz"));
    try std.testing.expectEqualStrings("zax\nybc\ndefg\n\n", document.items);
    try std.testing.expectEqual(cursor_before, cursor);
    try std.testing.expect(!dirty);

    // Fills the buffer exactly.
    try insert(&document, &cursor, &dirty, "xy");
    try std.testing.expectEqual(document.capacity, document.items.len);
    try std.testing.expectEqualStrings("zax\nybc\ndefg\nxy\n", document.items);
}

fn paste(
    document: *std.ArrayList(u8),
    clipboard: *std.ArrayList(u8),
    scratch_buffer: []u8,
    cursor: *Cursor,
    dirty: *bool,
) error{FileTooLong}!void {
    // Any selection must fit in the clipboard and scratch buffer.
    assert(clipboard.capacity >= document.capacity);
    assert(scratch_buffer.len >= document.items.len);

    if (clipboard.items.len == 0) return;

    // If there is a selection, pasting swaps the clipboard contents with the selection.
    if (cursor.selection(document.items)) |selection| {
        // Save selection in scratch until it can be copied to the clipboard.
        var scratch: std.ArrayList(u8) = .initBuffer(scratch_buffer);
        scratch.appendSliceAssumeCapacity(selection.slice(document.items));

        // Replace the selection with what's in the current clipboard. Move the cursor to the end
        // of what we just pasted.
        try replace(document, dirty, selection.head, selection.size(), clipboard.items);
        cursor.update(
            document.items,
            @intCast(selection.head + clipboard.items.len - 1),
            .snap_update,
        );
        cursor.anchor = null;

        clipboard.clearRetainingCapacity();
        clipboard.appendSliceAssumeCapacity(scratch.items);
        assert(clipboard.items.len == selection.size());
    } else if (clipboard.last() == '\n') { // line-wise paste
        // Clipboard ends in a newline: treat it as whole lines and paste them below the cursor's
        // line. On the last line the offset is the document size, an insertion after the trailing
        // newline.
        const offset = lineTail(document.items, cursor.offset) + 1;
        try replace(document, dirty, offset, 0, clipboard.items);
        // Cursor on the last pasted line, after its indentation, so pasting again appends below
        // the whole block rather than splitting it. The last pasted byte is that line's newline.
        const line_head = lineHead(document.items, @intCast(offset + clipboard.items.len - 1));
        cursor.update(
            document.items,
            line_head + lineIndentation(document.items, line_head),
            .snap_update,
        );
    } else {
        // Normal pasting starts to the right of the cursor. Make an exception when pasting on a
        // newline so we're not inserting on the next line. Don't move the cursor until the paste
        // has succeeded so that it's untouched on error.
        const offset = cursor.offset + @intFromBool(document.items[cursor.offset] != '\n');
        try replace(document, dirty, offset, 0, clipboard.items);
        // Cursor on the last pasted byte, same as when pasting over a selection.
        cursor.update(document.items, @intCast(offset + clipboard.items.len - 1), .snap_update);
    }
    assert(cursor.anchor == null);
}

test paste {
    const document_original = "Hello, world!\n  All your codebase are belong to us.\n";
    var document_buffer: [64]u8 = undefined;
    var document: std.ArrayList(u8) = .initBuffer(&document_buffer);
    document.appendSliceAssumeCapacity(document_original);
    var clipboard_buffer: [document_buffer.len]u8 = undefined;
    var clipboard: std.ArrayList(u8) = .initBuffer(&clipboard_buffer);
    var scratch_buffer: [document_buffer.len]u8 = undefined;
    var cursor: Cursor = undefined;
    var dirty = false;

    // Empty clipboard does nothing.
    cursor = .{ .offset = 4, .anchor = null, .line_offset_snap = 4 };
    try paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty);
    try std.testing.expectEqualStrings(document_original, document.items);
    try std.testing.expectEqual(4, cursor.offset);
    try std.testing.expect(!dirty);

    // Paste after the cursor. Cursor ends on the last pasted byte.
    clipboard.appendSliceAssumeCapacity("Hello");
    try paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty);
    try std.testing.expectEqualStrings("Hello", clipboard.items);
    try std.testing.expectEqualStrings(
        "HelloHello, world!\n  All your codebase are belong to us.\n",
        document.items,
    );
    try std.testing.expect(dirty);
    try std.testing.expectEqual(9, cursor.offset);
    try std.testing.expectEqual(null, cursor.anchor);
    try std.testing.expectEqual(9, cursor.line_offset_snap);

    // Paste over a selection (cursor at the head). Clipboard and selection swap.
    dirty = false;
    cursor = .{ .offset = 0, .anchor = .{ .offset = 9, .lines = false }, .line_offset_snap = 0 };
    try paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty);
    try std.testing.expectEqualStrings(document_original, document.items);
    try std.testing.expectEqualStrings("HelloHello", clipboard.items);
    try std.testing.expect(dirty);
    try std.testing.expectEqual(4, cursor.offset);
    try std.testing.expectEqual(null, cursor.anchor);
    try std.testing.expectEqual(4, cursor.line_offset_snap);

    // Paste over a selection (cursor at the tail).
    cursor = .{ .offset = 4, .anchor = .{ .offset = 0, .lines = false }, .line_offset_snap = 4 };
    try paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty);
    try std.testing.expectEqualStrings(
        "HelloHello, world!\n  All your codebase are belong to us.\n",
        document.items,
    );
    try std.testing.expectEqualStrings("Hello", clipboard.items);
    try std.testing.expectEqual(9, cursor.offset);
    try std.testing.expectEqual(null, cursor.anchor);
    try std.testing.expectEqual(9, cursor.line_offset_snap);

    // Paste on a newline inserts before it rather than on the next line.
    cursor = .{ .offset = 18, .anchor = null, .line_offset_snap = 18 };
    try paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty);
    try std.testing.expectEqualStrings(
        "HelloHello, world!Hello\n  All your codebase are belong to us.\n",
        document.items,
    );
    try std.testing.expectEqual(22, cursor.offset);
    try std.testing.expectEqual(22, cursor.line_offset_snap);

    // Select all and paste the whole document over itself.
    document.clearRetainingCapacity();
    document.appendSliceAssumeCapacity(document_original);
    clipboard.clearRetainingCapacity();
    clipboard.appendSliceAssumeCapacity(document_original);
    dirty = false;
    cursor = .{
        .offset = 0,
        .anchor = .{
            .offset = @intCast(document.items.len - 1), // select all
            .lines = false,
        },
        .line_offset_snap = 0,
    };
    try paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty);
    try std.testing.expectEqualStrings(document_original, clipboard.items);
    try std.testing.expectEqualStrings(document_original, document.items);
    try std.testing.expect(dirty);
    try std.testing.expectEqual(document.items.len - 1, cursor.offset);
    try std.testing.expectEqual(null, cursor.anchor);
    try std.testing.expectEqual(lineOffset(document.items, cursor.offset), cursor.line_offset_snap);

    // Too long without a selection. Nothing changes, including the cursor.
    clipboard.clearRetainingCapacity();
    clipboard.appendSliceAssumeCapacity("0123456789abc"); // 52 + 13 > 64
    dirty = false;
    cursor = .{ .offset = 4, .anchor = null, .line_offset_snap = 4 };
    var cursor_before = cursor;
    try std.testing.expectError(
        error.FileTooLong,
        paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty),
    );
    try std.testing.expectEqualStrings(document_original, document.items);
    try std.testing.expectEqualStrings("0123456789abc", clipboard.items);
    try std.testing.expectEqual(cursor_before, cursor);
    try std.testing.expect(!dirty);

    // Too long over a selection. Nothing changes, selection is kept.
    clipboard.appendSliceAssumeCapacity("d"); // 52 - 1 + 14 > 64
    cursor = .{ .offset = 0, .anchor = .{ .offset = 0, .lines = false }, .line_offset_snap = 0 };
    cursor_before = cursor;
    try std.testing.expectError(
        error.FileTooLong,
        paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty),
    );
    try std.testing.expectEqualStrings(document_original, document.items);
    try std.testing.expectEqualStrings("0123456789abcd", clipboard.items);
    try std.testing.expectEqual(cursor_before, cursor);
    try std.testing.expect(!dirty);

    // Clipboard ending in a newline pastes whole lines below the cursor's line, wherever the
    // cursor is in the line. Cursor ends on the first pasted line after its indentation.
    clipboard.clearRetainingCapacity();
    clipboard.appendSliceAssumeCapacity("  foo\nbar\n");
    cursor = .{ .offset = 4, .anchor = null, .line_offset_snap = 4 };
    try paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty);
    try std.testing.expectEqualStrings(
        "Hello, world!\n  foo\nbar\n  All your codebase are belong to us.\n",
        document.items,
    );
    try std.testing.expectEqualStrings("  foo\nbar\n", clipboard.items);
    try std.testing.expect(dirty);
    try std.testing.expectEqual(20, cursor.offset); // on the last pasted line
    try std.testing.expectEqual(0, cursor.line_offset_snap);

    // Same with the cursor on the line's newline.
    document.clearRetainingCapacity();
    document.appendSliceAssumeCapacity(document_original);
    cursor = .{ .offset = 13, .anchor = null, .line_offset_snap = 13 };
    try paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty);
    try std.testing.expectEqualStrings(
        "Hello, world!\n  foo\nbar\n  All your codebase are belong to us.\n",
        document.items,
    );
    try std.testing.expectEqual(20, cursor.offset);

    // Pasting lines below the last line appends them to the document.
    document.clearRetainingCapacity();
    document.appendSliceAssumeCapacity(document_original);
    clipboard.clearRetainingCapacity();
    clipboard.appendSliceAssumeCapacity("bar\n");
    cursor = .{ .offset = 20, .anchor = null, .line_offset_snap = 6 };
    try paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty);
    try std.testing.expectEqualStrings(document_original ++ "bar\n", document.items);
    try std.testing.expectEqual(document_original.len, cursor.offset);
    try std.testing.expectEqual(0, cursor.line_offset_snap);

    // A lone newline is an empty line.
    clipboard.clearRetainingCapacity();
    clipboard.appendSliceAssumeCapacity("\n");
    cursor = .{ .offset = 0, .anchor = null, .line_offset_snap = 0 };
    try paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty);
    try std.testing.expectEqualStrings(
        "Hello, world!\n\n  All your codebase are belong to us.\nbar\n",
        document.items,
    );
    try std.testing.expectEqual(14, cursor.offset);
    try std.testing.expectEqual(0, cursor.line_offset_snap);

    // Too long. Nothing changes, including the cursor.
    clipboard.clearRetainingCapacity();
    clipboard.appendSliceAssumeCapacity("0123456789ab\n"); // 57 + 13 > 64
    dirty = false;
    cursor = .{ .offset = 4, .anchor = null, .line_offset_snap = 4 };
    cursor_before = cursor;
    const document_before = document.items.len;
    try std.testing.expectError(
        error.FileTooLong,
        paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty),
    );
    try std.testing.expectEqual(document_before, document.items.len);
    try std.testing.expectEqual(cursor_before, cursor);
    try std.testing.expect(!dirty);
}

fn delete(
    document: *std.ArrayList(u8),
    clipboard: *std.ArrayList(u8),
    cursor: *Cursor,
    dirty: *bool,
) void {
    // If it's a selection, snap cursor to head after yank.
    const cursor_offset = cursor.head(document.items);

    yankInner(document.items, clipboard, cursor.*);

    // Delete from the head of the selection or, without a selection, the byte under the cursor.
    const size: u32 = if (cursor.selection(document.items)) |selection| selection.size() else 1;
    // We're removing at least one byte. Even if the trailing newline has to be added back the
    // document can't grow, so this never returns an error.
    assert(size > 0);
    replace(document, dirty, cursor_offset, size, "") catch unreachable;
    const lines = if (cursor.anchor) |anchor| anchor.lines else false;
    cursor.anchor = null;

    if (lines) {
        // Deleting the last lines leaves the head past the end of the document, so clamp it onto
        // the line above. Either way, land after the indentation of the line now at the cursor.
        const line_head = lineHead(document.items, @min(cursor_offset, document.items.len - 1));
        cursor.update(
            document.items,
            line_head + lineIndentation(document.items, line_head),
            .snap_update,
        );
    } else cursor.update(document.items, cursor_offset, .snap_update);
    assert(cursor.offset < document.items.len);
}

test delete {
    const document_original = "Hello, world!\n  All your codebase are belong to us.\n";
    var document_buffer: [document_original.len]u8 = undefined;
    var document: std.ArrayList(u8) = .initBuffer(&document_buffer);
    document.appendSliceAssumeCapacity(document_original);
    var clipboard_buffer: [document_original.len]u8 = undefined;
    var clipboard: std.ArrayList(u8) = .initBuffer(&clipboard_buffer);
    var cursor: Cursor = undefined;
    var dirty = false;

    cursor = .{ // select all
        .offset = @intCast(document.items.len - 1),
        .anchor = .{ .offset = 0, .lines = false },
        .line_offset_snap = @intCast(document.items.len - 1),
    };
    delete(&document, &clipboard, &cursor, &dirty);
    try std.testing.expectEqualStrings("\n", document.items);
    try std.testing.expectEqualStrings(document_original, clipboard.items);
    try std.testing.expect(cursor.anchor == null); // deselect after yank
    try std.testing.expect(cursor.offset == 0); // snap back to head
    try std.testing.expect(dirty);

    dirty = false;
    document.clearRetainingCapacity();
    document.appendSliceAssumeCapacity(document_original); // refill document
    cursor = .{ .offset = 0, .anchor = null, .line_offset_snap = 0 };
    delete(&document, &clipboard, &cursor, &dirty);
    try std.testing.expectEqualStrings("H", clipboard.items);
    try std.testing.expectEqualStrings(document_original[1..], document.items);
    try std.testing.expect(cursor.offset == 0);
    try std.testing.expect(dirty);

    dirty = false;
    cursor = .{ .offset = 6, .anchor = .{ .offset = 12, .lines = false }, .line_offset_snap = 6 };
    delete(&document, &clipboard, &cursor, &dirty);
    try std.testing.expectEqualStrings("world!\n", clipboard.items);
    try std.testing.expect(cursor.anchor == null); // deselect after yank
    try std.testing.expect(cursor.offset == 6); // stays at head
    try std.testing.expectEqualStrings(
        "ello,   All your codebase are belong to us.\n",
        document.items,
    );
    try std.testing.expect(dirty);

    // Deleting a newline between lines joins them.
    document.clearRetainingCapacity();
    document.appendSliceAssumeCapacity(document_original); // refill document
    cursor = .{ .offset = 13, .anchor = null, .line_offset_snap = 13 };
    delete(&document, &clipboard, &cursor, &dirty);
    try std.testing.expectEqualStrings("\n", clipboard.items);
    try std.testing.expectEqualStrings(
        "Hello, world!  All your codebase are belong to us.\n",
        document.items,
    );
    try std.testing.expectEqual(13, cursor.offset);
    try std.testing.expectEqual(13, cursor.line_offset_snap);

    // Deleting the trailing newline puts it back. The document is unchanged but still marked
    // dirty (harmless false positive).
    dirty = false;
    cursor = .{ .offset = 50, .anchor = null, .line_offset_snap = 50 };
    delete(&document, &clipboard, &cursor, &dirty);
    try std.testing.expectEqualStrings("\n", clipboard.items);
    try std.testing.expectEqualStrings(
        "Hello, world!  All your codebase are belong to us.\n",
        document.items,
    );
    try std.testing.expectEqual(50, cursor.offset);
    try std.testing.expect(dirty);

    // Line-wise selection deletes whole lines, newlines included. The cursor lands after the
    // indentation of the line that takes their place.
    document.clearRetainingCapacity();
    document.appendSliceAssumeCapacity(document_original); // refill document
    cursor = .{ .offset = 5, .anchor = .{ .offset = 5, .lines = true }, .line_offset_snap = 5 };
    delete(&document, &clipboard, &cursor, &dirty);
    try std.testing.expectEqualStrings("Hello, world!\n", clipboard.items);
    try std.testing.expectEqualStrings(document_original[14..], document.items);
    try std.testing.expect(cursor.anchor == null);
    try std.testing.expectEqual(2, cursor.offset);
    try std.testing.expectEqual(2, cursor.line_offset_snap);

    // Deleting the last line moves the cursor up onto the line before it.
    document.clearRetainingCapacity();
    document.appendSliceAssumeCapacity(document_original); // refill document
    cursor = .{ .offset = 20, .anchor = .{ .offset = 30, .lines = true }, .line_offset_snap = 6 };
    delete(&document, &clipboard, &cursor, &dirty);
    try std.testing.expectEqualStrings(document_original[14..], clipboard.items);
    try std.testing.expectEqualStrings("Hello, world!\n", document.items);
    try std.testing.expectEqual(0, cursor.offset);

    // Deleting every line leaves just the trailing newline.
    document.clearRetainingCapacity();
    document.appendSliceAssumeCapacity(document_original); // refill document
    cursor = .{ .offset = 20, .anchor = .{ .offset = 3, .lines = true }, .line_offset_snap = 6 };
    delete(&document, &clipboard, &cursor, &dirty);
    try std.testing.expectEqualStrings(document_original, clipboard.items);
    try std.testing.expectEqualStrings("\n", document.items);
    try std.testing.expectEqual(0, cursor.offset);
}

fn yankInner(document: []const u8, clipboard: *std.ArrayList(u8), cursor: Cursor) void {
    assert(clipboard.capacity >= document.len); // any selection fits
    clipboard.clearRetainingCapacity();
    if (cursor.selection(document)) |selection|
        clipboard.appendSliceAssumeCapacity(selection.slice(document))
    else
        clipboard.appendAssumeCapacity(document[cursor.offset]);
}

fn yank(document: []const u8, clipboard: *std.ArrayList(u8), cursor: *Cursor) void {
    // If it's a selection, snap cursor to head after yank.
    const cursor_offset = cursor.head(document);
    yankInner(document, clipboard, cursor.*);
    cursor.anchor = null; // unselect
    cursor.update(document, cursor_offset, .snap_update);
}

test yank {
    const document = "Hello, world!\n  All your codebase are belong to us.\n";
    var clipboard_buffer: [document.len]u8 = undefined;
    var clipboard: std.ArrayList(u8) = .initBuffer(&clipboard_buffer);
    var cursor: Cursor = undefined;

    cursor = .{ .offset = 0, .anchor = null, .line_offset_snap = 0 };
    yank(document, &clipboard, &cursor);
    try std.testing.expectEqualStrings("H", clipboard.items);
    try std.testing.expect(cursor.offset == 0);

    cursor = .{ .offset = 7, .anchor = .{ .offset = 13, .lines = false }, .line_offset_snap = 7 };
    yank(document, &clipboard, &cursor);
    try std.testing.expectEqualStrings("world!\n", clipboard.items);
    try std.testing.expect(cursor.anchor == null); // deselect after yank
    try std.testing.expect(cursor.offset == 7); // snap back to head
    try std.testing.expectEqual(7, cursor.line_offset_snap);

    // Cursor at the tail of a selection snaps back to the head.
    cursor = .{ .offset = 18, .anchor = .{ .offset = 7, .lines = false }, .line_offset_snap = 4 };
    yank(document, &clipboard, &cursor);
    try std.testing.expectEqualStrings("world!\n  All", clipboard.items);
    try std.testing.expect(cursor.anchor == null); // deselect after yank
    try std.testing.expectEqual(7, cursor.offset);
    try std.testing.expectEqual(7, cursor.line_offset_snap);

    cursor = .{ // select all
        .offset = document.len - 1,
        .anchor = .{ .offset = 0, .lines = false },
        .line_offset_snap = lineOffset(document, document.len - 1),
    };
    yank(document, &clipboard, &cursor);
    try std.testing.expectEqualStrings(document, clipboard.items);
    try std.testing.expect(cursor.anchor == null); // deselect after yank
    try std.testing.expect(cursor.offset == 0); // snap back to head
    try std.testing.expectEqual(0, cursor.line_offset_snap);
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

    /// Decode Kitty Keyboard Protocol modifiers from parameter: "In the escape code, the modifier
    /// value is encoded as a decimal number which is 1 + actual modifiers. So to represent shift
    /// only, the value would be 1 + 1 = 2, to represent ctrl+shift the value would be
    /// 1 + 0b101 = 6 and so on."
    fn decode(encoded: u32) ?Modifiers {
        if (encoded == 0) return null;
        if (encoded - 1 > std.math.maxInt(u8)) return null;
        const byte: u8 = @intCast(encoded - 1);
        return @bitCast(byte);
    }
};

const ViewportDimensions = struct { row_count: u32, col_count: u32 };

pub const Event = union(enum) {
    resize: ViewportDimensions,
    ascii: u8,
    chord: struct { ascii: u8, modifiers: Modifiers },
    backspace,
    enter,
    escape,
    tab,

    /// Give a parser action meaning. Returns null for actions that aren't recognised.
    fn decode(action: Parser.Action) ?Event {
        switch (action) {
            .print => |c| return .{ .ascii = c },
            .execute => |byte| switch (byte) {
                0x08, 0x7F => return .backspace,
                0x09 => return .tab,
                0x0D => return .enter,
                else => return null,
            },
            .esc_dispatch => return null,
            .csi_dispatch => |csi| {
                if (csi.private_marker) |_| return null;
                if (csi.intermediates.len != 0) return null;
                const first = if (0 < csi.params.len) csi.params[0] else return null;
                switch (csi.final) {
                    'u' => switch (first) {
                        0x1b => return .escape,
                        // Printable ASCII with modifiers. Codepoints must be the lowercase variant.
                        0x20...0x7E => |c| return .{
                            .chord = .{
                                .ascii = @intCast(switch (c) {
                                    // CSI u unicode-key-code must be unshifted (e.g. a not A).
                                    'A'...'Z' => return null, // discard
                                    else => c,
                                }),
                                // Modifiers may not be present. It defaults to 1 (no modifiers). For
                                // now ignore events without them.
                                .modifiers = Modifiers.decode(
                                    if (1 < csi.params.len) csi.params[1] else return null,
                                ) orelse return null,
                            },
                        },
                        else => return null,
                    },
                    't' => switch (first) {
                        // Resize: CSI 48 ; height_chars ; width_chars ; height_pix ; width_pix t. See
                        // https://gist.github.com/rockorager/e695fb2924d36b2bcf1fff4a3704bd83.
                        48 => return .{
                            .resize = .{
                                .row_count = if (1 < csi.params.len) csi.params[1] else return null,
                                .col_count = if (2 < csi.params.len) csi.params[2] else return null,
                            },
                        },
                        else => return null,
                    },
                    else => return null,
                }
            },
        }
    }

    /// Pull actions from the parser until one decodes to an event.
    pub fn next(parser: *Parser, reader: *std.Io.Reader) error{ EndOfStream, ReadFailed }!Event {
        while (true) {
            const action = try parser.next(reader);
            if (Event.decode(action)) |event| return event;
        }
    }
};

fn runFormatter(
    io: std.Io,
    argv: []const []const u8,
    document: []const u8,
    scratch_buffer: []u8,
) !?[]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    // Write the document to stdin.
    try child.stdin.?.writeStreamingAll(io, document);
    child.stdin.?.close(io);
    child.stdin = null;

    // Resulting stdout is new document.
    var stdout_reader = child.stdout.?.reader(io, &.{});
    var buffer_writer: std.Io.Writer = .fixed(scratch_buffer);
    const stdout_size = stdout_reader.interface.streamRemaining(&buffer_writer) catch |err|
        switch (err) {
            error.WriteFailed => return null, // output doesn't fit, treat as formatting failure
            error.ReadFailed => return err,
        };

    const term = try child.wait(io);
    if (!term.success()) return null;
    return scratch_buffer[0..stdout_size];
}

/// Paul Williams' DEC ANSI parser state machine. See https://vt100.net/emu/dec_ansi_parser.
///
/// Deviations from the spec:
/// - DEL is executed rather than printed, since it's what the Backspace key sends.
/// - 0x80-0xFF is ignored since UTF-8 is not yet supported.
/// - C0 bytes mid-sequence are ignored.
/// - BEL terminates any string, not just OSC. Due to how this is handled, ESC \ (ST) never produces
///   an ESC dispatch.
/// - High bytes mid-sequence are ignored rather than aborted.
pub const Parser = struct {
    param_buffer: [16]u32 = undefined,
    intermediate_buffer: [2]u8 = undefined,

    const Action = union(enum) {
        print: u8,
        execute: u8,
        esc_dispatch: Esc,
        csi_dispatch: Csi,
    };

    /// Slices point into the parser and are valid until the next call to `next`.
    const Esc = struct {
        intermediates: []const u8,
        final: u8,
    };

    /// Slices point into the parser and are valid until the next call to `next`.
    const Csi = struct {
        private_marker: ?u8,
        params: []const u32,
        intermediates: []const u8,
        final: u8,
    };

    /// Pull bytes from the reader until an action is produced.
    fn next(parser: *Parser, reader: *std.Io.Reader) error{ EndOfStream, ReadFailed }!Action {
        var params: std.ArrayList(u32) = .initBuffer(&parser.param_buffer);
        var intermediates: []const u8 = "";
        var private: ?u8 = null;

        state: switch (enum {
            ground,
            escape,
            escape_intermediate,
            escape_ignore,
            string_ignore,
            csi_entry,
            csi_param,
            csi_intermediate,
            csi_ignore,
        }.ground) {
            // This trick lets us write shared code. The switch statments apply to multiple branches
            // except for the final one which behaves as expected.
            inline else => |state| {
                const byte = try reader.takeByte();

                switch (byte) { // anywhere
                    0x07 => if (state != .ground and state != .string_ignore)
                        continue :state state, // ignore BEL
                    0x00...0x06, 0x08...0x17, 0x19, 0x1C...0x1F => if (state != .ground)
                        continue :state state, // ignore C0
                    0x18, 0x1A => return .{ .execute = byte }, // CAN, SUB: abort
                    0x1B => { // abort and start a new sequence
                        params.clearRetainingCapacity();
                        intermediates = "";
                        private = null;
                        continue :state .escape;
                    },
                    0x7F => if (state != .ground) continue :state state, // ignore DEL
                    0x80...0xFF => continue :state state, // ignore UTF-8 and C1, not supported
                    else => {},
                }

                switch (state) {
                    .ground => switch (byte) {
                        0x18, 0x1A, 0x1B, 0x80...0xFF => unreachable, // handled above
                        0x00...0x17, 0x19, 0x1C...0x1F => return .{ .execute = byte }, // C0
                        0x20...0x7E => return .{ .print = byte },
                        0x7F => return .{ .execute = byte }, // DEL
                    },
                    .escape => switch (byte) {
                        0x00...0x1F, 0x7F...0xFF => unreachable,
                        '[' => continue :state .csi_entry, // 0x5B
                        0x20...0x2F => { // intermediates
                            assert(intermediates.len == 0);
                            parser.intermediate_buffer[0] = byte;
                            intermediates = parser.intermediate_buffer[0..1];
                            continue :state .escape_intermediate;
                        },
                        'P', ']', 'X', '^', '_' => continue :state .string_ignore,
                        0x5C => continue :state .ground,
                        0x30...0x4F, 0x51...0x57, 0x59...0x5A, 0x60...0x7E => return .{
                            .esc_dispatch = .{ .intermediates = "", .final = byte },
                        },
                    },
                    .escape_intermediate => switch (byte) {
                        0x00...0x1F, 0x7F...0xFF => unreachable,
                        0x20...0x2F => { // second intermediate
                            assert(intermediates.len != 0);
                            if (intermediates.len > 1)
                                continue :state .escape_ignore; // max of 2 intermediates
                            parser.intermediate_buffer[1] = byte;
                            intermediates = parser.intermediate_buffer[0..2];
                            continue :state .escape_intermediate; // next byte should be final
                        },
                        0x30...0x7E => return .{
                            .esc_dispatch = .{ .intermediates = intermediates, .final = byte },
                        },
                    },
                    .escape_ignore => switch (byte) {
                        0x00...0x1F, 0x7F...0xFF => unreachable,
                        0x20...0x2F => continue :state .escape_ignore, // ignore until end of sequence
                        0x30...0x7E => continue :state .ground, // final byte
                    },
                    // All strings are terminated by BEL or ESC \. ESC is handled by anywhere.
                    .string_ignore => switch (byte) {
                        0x00...0x06, 0x08...0x1F, 0x7F...0xFF => unreachable,
                        0x07 => continue :state .ground, // BEL
                        0x20...0x7E => continue :state .string_ignore,
                    },
                    .csi_entry => switch (byte) {
                        0x00...0x1F, 0x7F...0xFF => unreachable,
                        0x20...0x2F => { // intermediates
                            assert(intermediates.len == 0);
                            parser.intermediate_buffer[0] = byte;
                            intermediates = parser.intermediate_buffer[0..1];
                            continue :state .csi_intermediate;
                        },
                        '0'...'9' => { // first param
                            assert(params.items.len == 0);
                            params.appendAssumeCapacity(byte - '0');
                            continue :state .csi_param;
                        },
                        ':' => continue :state .csi_ignore, // not valid
                        ';' => {
                            assert(params.items.len == 0);
                            params.appendAssumeCapacity(0); // default empty param to 0
                            params.appendAssumeCapacity(0); // initialise next param (after ;) to 0
                            continue :state .csi_param;
                        },
                        0x3C...0x3F => if (private == null) { // accept ONE private (< = > ?)
                            private = byte;
                            continue :state .csi_entry;
                        } else continue :state .csi_ignore,
                        0x40...0x7E => return .{
                            .csi_dispatch = .{
                                .private_marker = private,
                                .params = &.{},
                                .intermediates = "",
                                .final = byte,
                            },
                        },
                    },
                    .csi_param => switch (byte) {
                        0x00...0x1F, 0x7F...0xFF => unreachable,
                        0x20...0x2F => { // intermediate
                            assert(intermediates.len == 0);
                            parser.intermediate_buffer[0] = byte;
                            intermediates = parser.intermediate_buffer[0..1];
                            continue :state .csi_intermediate;
                        },
                        '0'...'9' => { // param
                            const last = params.lastPtr().?;
                            last.* = last.* *| 10 +| (byte - '0');
                            continue :state .csi_param;
                        },
                        ':' => continue :state .csi_ignore, // not valid
                        ';' => {
                            params.appendBounded(0) catch continue :state .csi_ignore; // drop if too long
                            continue :state .csi_param;
                        },
                        0x3C...0x3F => continue :state .csi_ignore, // private only valid as first byte
                        0x40...0x7E => return .{ // final byte
                            .csi_dispatch = .{
                                .private_marker = private,
                                .params = params.items,
                                .intermediates = "",
                                .final = byte,
                            },
                        },
                    },
                    .csi_intermediate => switch (byte) {
                        0x00...0x1F, 0x7F...0xFF => unreachable,
                        0x20...0x2F => { // second intermediate
                            assert(intermediates.len != 0);
                            if (intermediates.len > 1) continue :state .csi_ignore; // max of 2 intermediates
                            parser.intermediate_buffer[1] = byte;
                            intermediates = parser.intermediate_buffer[0..2];
                            continue :state .csi_intermediate; // next byte should be final
                        },
                        // No privates or params after intermediates.
                        0x3C...0x3F, '0'...'9', ';' => continue :state .csi_ignore,
                        ':' => continue :state .csi_ignore, // not valid
                        0x40...0x7E => return .{ // final byte
                            .csi_dispatch = .{
                                .private_marker = private,
                                .params = params.items,
                                .intermediates = intermediates,
                                .final = byte,
                            },
                        },
                    },
                    .csi_ignore => switch (byte) {
                        0x00...0x1F, 0x7F...0xFF => unreachable,
                        0x40...0x7E => continue :state .ground, // final byte (different from .escape_ignore)
                        0x20...0x3F => continue :state .csi_ignore, // ignore until end of sequence
                    },
                }
            },
        }
    }
};

/// Check the actions parsed from the input, then that the input is used up. Each action is
/// checked as it's produced, since its slices are only valid until the next call.
fn expectActions(input: []const u8, expected: []const Parser.Action) !void {
    var reader: std.Io.Reader = .fixed(input);
    var parser: Parser = .{};
    for (expected) |expected_action| {
        try std.testing.expectEqualDeep(expected_action, try parser.next(&reader));
    }
    try std.testing.expectError(error.EndOfStream, parser.next(&reader));
}

/// Check the events decoded from the input. Actions that aren't events are skipped.
fn expectEvents(input: []const u8, expected: []const Event) !void {
    var reader: std.Io.Reader = .fixed(input);
    var parser: Parser = .{};
    for (expected) |expected_event| {
        const event = while (true) {
            if (Event.decode(try parser.next(&reader))) |event| break event;
        };
        try std.testing.expectEqual(expected_event, event);
    }
    while (true) {
        const action = parser.next(&reader) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        try std.testing.expectEqual(null, Event.decode(action));
    }
}

/// Test helper: a CSI dispatch, with defaults for the parts most tests leave out.
fn testCsi(args: struct {
    private_marker: ?u8 = null,
    params: []const u32 = &.{},
    intermediates: []const u8 = "",
    final: u8,
}) Parser.Action {
    return .{
        .csi_dispatch = .{
            .private_marker = args.private_marker,
            .params = args.params,
            .intermediates = args.intermediates,
            .final = args.final,
        },
    };
}

/// Test helper: an ESC dispatch, with defaults for the parts most tests leave out.
fn testEsc(args: struct { intermediates: []const u8 = "", final: u8 }) Parser.Action {
    return .{ .esc_dispatch = .{ .intermediates = args.intermediates, .final = args.final } };
}

test "parser: ground" {
    try expectActions("a\r~", &.{ .{ .print = 'a' }, .{ .execute = '\r' }, .{ .print = '~' } });
    try expectActions("\x00\x07\x08\x09\x0d\x1f", &.{
        .{ .execute = 0x00 },
        .{ .execute = 0x07 },
        .{ .execute = 0x08 },
        .{ .execute = 0x09 },
        .{ .execute = 0x0d },
        .{ .execute = 0x1f },
    });
    // DEL is executed, since it's what the Backspace key sends.
    try expectActions("\x7f", &.{.{ .execute = 0x7F }});
    // Bytes >= 0x80 are ignored: UTF-8 (here e acute) isn't supported, and 8-bit C1 controls
    // (0x80-0x9F) aren't recognised.
    try expectActions("\xc3\xa9a\x80\x9b\xff", &.{.{ .print = 'a' }});
    try expectActions("", &.{});
}

test "parser: esc" {
    try expectActions("\x1bc", &.{testEsc(.{ .final = 'c' })});
    try expectActions("\x1b7\x1b8", &.{ testEsc(.{ .final = '7' }), testEsc(.{ .final = '8' }) });
    // Lowest and highest final bytes.
    try expectActions("\x1b0\x1b~", &.{ testEsc(.{ .final = '0' }), testEsc(.{ .final = '~' }) });
    try expectActions("\x1b(B", &.{testEsc(.{ .intermediates = "(", .final = 'B' })});
    try expectActions("\x1b ~", &.{testEsc(.{ .intermediates = " ", .final = '~' })});
    // DEL and bytes >= 0x80 are ignored.
    try expectActions("\x1b\x7f\x80\xffc", &.{testEsc(.{ .final = 'c' })});
    // Unfinished.
    try expectActions("\x1b", &.{});
}

test "parser: csi params" {
    try expectActions("\x1b[109;5u", &.{testCsi(.{ .params = &.{ 109, 5 }, .final = 'u' })});
    try expectActions("\x1b[0123456789m", &.{testCsi(.{ .params = &.{123456789}, .final = 'm' })});
    try expectActions("\x1b[48;24;80;480;800t", &.{
        testCsi(.{ .params = &.{ 48, 24, 80, 480, 800 }, .final = 't' }),
    });
    // No params. Lowest and highest final bytes.
    try expectActions("\x1b[A", &.{testCsi(.{ .final = 'A' })});
    try expectActions("\x1b[@\x1b[~", &.{ testCsi(.{ .final = '@' }), testCsi(.{ .final = '~' }) });
    // Empty params are 0.
    try expectActions("\x1b[;5u\x1b[5;u\x1b[;u", &.{
        testCsi(.{ .params = &.{ 0, 5 }, .final = 'u' }),
        testCsi(.{ .params = &.{ 5, 0 }, .final = 'u' }),
        testCsi(.{ .params = &.{ 0, 0 }, .final = 'u' }),
    });
    // Values saturate.
    try expectActions("\x1b[99999999999999999999u", &.{
        testCsi(.{ .params = &.{std.math.maxInt(u32)}, .final = 'u' }),
    });
    // Params are cleared between sequences.
    try expectActions("\x1b[1;2;3u\x1b[u", &.{
        testCsi(.{ .params = &.{ 1, 2, 3 }, .final = 'u' }),
        testCsi(.{ .final = 'u' }),
    });
    // 16 params is the max.
    try expectActions("\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16m", &.{
        testCsi(.{ .params = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }, .final = 'm' }),
    });
    // DEL and bytes >= 0x80 are ignored.
    try expectActions("\x1b[1\x7f\x80\xff2u", &.{testCsi(.{ .params = &.{12}, .final = 'u' })});
    // Unfinished.
    try expectActions("\x1b[12", &.{});
}

test "parser: csi private markers and intermediates" {
    try expectActions("\x1b[?2048h", &.{testCsi(.{ .private_marker = '?', .params = &.{2048}, .final = 'h' })});
    try expectActions("\x1b[>1u", &.{testCsi(.{ .private_marker = '>', .params = &.{1}, .final = 'u' })});
    try expectActions("\x1b[<u", &.{testCsi(.{ .private_marker = '<', .final = 'u' })});
    try expectActions("\x1b[1;2$x", &.{testCsi(.{ .params = &.{ 1, 2 }, .intermediates = "$", .final = 'x' })});
    // Set cursor style (DECSCUSR), as the editor sends.
    try expectActions("\x1b[2 q", &.{testCsi(.{ .params = &.{2}, .intermediates = " ", .final = 'q' })});
    try expectActions("\x1b[ !x", &.{testCsi(.{ .intermediates = " !", .final = 'x' })});
    try expectActions("\x1b[?1$p", &.{
        testCsi(.{ .private_marker = '?', .params = &.{1}, .intermediates = "$", .final = 'p' }),
    });
}

test "parser: malformed sequences are dropped" {
    // They're consumed up to their final byte, so the bytes after them are still parsed correctly.
    // Private markers are only valid first, and only one.
    try expectActions("\x1b[1?2ux", &.{.{ .print = 'x' }});
    try expectActions("\x1b[<?ua", &.{.{ .print = 'a' }});
    // Sub-params (':') aren't supported. KKP only uses them for flags we don't enable (alternate
    // keys, event types).
    try expectActions("\x1b[97:65;2ua", &.{.{ .print = 'a' }});
    try expectActions("\x1b[:ua", &.{.{ .print = 'a' }});
    // Params and private markers can't follow intermediates.
    try expectActions("\x1b[2$3xy", &.{.{ .print = 'y' }});
    try expectActions("\x1b[$?xy", &.{.{ .print = 'y' }});
    // At most 2 intermediates. ESC finals start at 0x30, below CSI finals.
    try expectActions("\x1b[ !\"xy", &.{.{ .print = 'y' }});
    try expectActions("\x1b(((Ba", &.{.{ .print = 'a' }});
    try expectActions("\x1b(((0a", &.{.{ .print = 'a' }});
    // At most 16 params.
    try expectActions("\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17ma", &.{.{ .print = 'a' }});
    // DEL and bytes >= 0x80 are ignored while dropping.
    try expectActions("\x1b[1?\x7f\x80;2ua", &.{.{ .print = 'a' }});
}

test "parser: esc, can, and sub abort sequences" {
    // ESC aborts the current sequence and starts a new one.
    try expectActions("\x1b[\x1b[A", &.{testCsi(.{ .final = 'A' })});
    try expectActions("\x1b[12\x1b[A", &.{testCsi(.{ .final = 'A' })});
    try expectActions("\x1b[1?\x1b[A", &.{testCsi(.{ .final = 'A' })});
    try expectActions("\x1b(\x1bc", &.{testEsc(.{ .final = 'c' })});
    // CAN and SUB abort it and are executed.
    try expectActions("\x18\x1a", &.{ .{ .execute = 0x18 }, .{ .execute = 0x1A } });
    try expectActions("\x1b\x18a", &.{ .{ .execute = 0x18 }, .{ .print = 'a' } });
    try expectActions("\x1b[12\x18a", &.{ .{ .execute = 0x18 }, .{ .print = 'a' } });
    try expectActions("\x1b[12\x1aa", &.{ .{ .execute = 0x1A }, .{ .print = 'a' } });
    try expectActions("\x1b[1?\x18a", &.{ .{ .execute = 0x18 }, .{ .print = 'a' } });
    // Aborted and dropped sequences leave nothing behind.
    try expectActions("\x1b[?\x1b[A", &.{testCsi(.{ .final = 'A' })});
    try expectActions("\x1b(\x1b(B", &.{testEsc(.{ .intermediates = "(", .final = 'B' })});
    try expectActions("\x1b[$\x1b[$x", &.{testCsi(.{ .intermediates = "$", .final = 'x' })});
    try expectActions("\x1b[?1$1x\x1b[A", &.{testCsi(.{ .final = 'A' })});
}

test "parser: C0 controls within sequences are ignored" {
    try expectActions("\x1b\rc", &.{testEsc(.{ .final = 'c' })});
    try expectActions("\x1b(\rB", &.{testEsc(.{ .intermediates = "(", .final = 'B' })});
    try expectActions("\x1b[1\r0m", &.{testCsi(.{ .params = &.{10}, .final = 'm' })});
    try expectActions("\x1b[1;2$\rx", &.{testCsi(.{ .params = &.{ 1, 2 }, .intermediates = "$", .final = 'x' })});
    try expectActions("\x1b[1?\r2ux", &.{.{ .print = 'x' }});
}

test "parser: strings are dropped" {
    // OSC (ESC ]), DCS (ESC P), SOS (ESC X), PM (ESC ^), and APC (ESC _) are dropped up to ST
    // (ESC \) or BEL. The ESC ends the string, then the '\' is consumed without an action.
    try expectActions("\x1b]0;title\x07a", &.{.{ .print = 'a' }});
    try expectActions("\x1b]52;c;aGk=\x1b\\a", &.{.{ .print = 'a' }});
    // XTVERSION and DECRQSS responses (DCS).
    try expectActions("\x1bP>|ghostty\r1.0\x1b\\a", &.{.{ .print = 'a' }});
    try expectActions("\x1bP1$r0m\x1b\\a", &.{.{ .print = 'a' }});
    try expectActions("\x1bP1:2q\x1b\\a", &.{.{ .print = 'a' }});
    // Kitty graphics protocol response (APC).
    inline for (.{ "\x1bXsos", "\x1b^pm", "\x1b_Gi=1;OK" }) |string| {
        try expectActions(string ++ "\x1b\\a", &.{.{ .print = 'a' }});
    }
    // C0 controls and bytes >= 0x80 are part of the string.
    try expectActions("\x1b]0;a\rb\xc3\xa9\x07c", &.{.{ .print = 'c' }});
    // CAN, SUB, and ESC still abort it.
    try expectActions("\x1b]0;title\x18a", &.{ .{ .execute = 0x18 }, .{ .print = 'a' } });
    try expectActions("\x1bPq\x1aa", &.{ .{ .execute = 0x1A }, .{ .print = 'a' } });
    try expectActions("\x1b]0;ti\x1b[Atle", &.{
        testCsi(.{ .final = 'A' }),
        .{ .print = 't' },
        .{ .print = 'l' },
        .{ .print = 'e' },
    });
    // ST on its own.
    try expectActions("\x1b\\a", &.{.{ .print = 'a' }});
    // Unfinished.
    try expectActions("\x1b]0;title", &.{});
    try expectActions("\x1bP>|ghostty", &.{});
    try expectActions("\x1b_Gi=1;OK", &.{});
}

test "event: decode keys" {
    try expectEvents("a~ \x7f\x08\t\r", &.{
        .{ .ascii = 'a' },
        .{ .ascii = '~' },
        .{ .ascii = ' ' },
        .backspace,
        .backspace,
        .tab,
        .enter,
    });
    try expectEvents("\x1b[27u", &.{.escape});
    try expectEvents("\x1b[109;5u", &.{.{ .chord = .{ .ascii = 'm', .modifiers = .{ .ctrl = true } } }});
    try expectEvents("\x1b[97;7u", &.{
        .{ .chord = .{ .ascii = 'a', .modifiers = .{ .alt = true, .ctrl = true } } },
    });
}

test "event: decode resize" {
    try expectEvents("\x1b[48;24;80;480;800t", &.{.{ .resize = .{ .row_count = 24, .col_count = 80 } }});
}

test "event: decode skips unsupported sequences" {
    try expectEvents(
        // KKP key codes must be unshifted (a not A).
        "\x1b[65;5u" ++
            // Missing, zero, and out of range modifiers.
            "\x1b[97u" ++ "\x1b[97;0u" ++ "\x1b[97;258u" ++
            // Private markers and intermediates.
            "\x1b[?1u" ++ "\x1b[1;2$u" ++
            // Resize without dimensions.
            "\x1b[48;24t" ++
            // Other actions.
            "\x1bc" ++ "\x1b]0;title\x07" ++ "\x01" ++ "\x1b[A" ++
            "a",
        &.{.{ .ascii = 'a' }},
    );
}

const ParserFuzzContext = struct {
    parser: Parser = .{},
    input_buffer: [128]u8 = undefined,
};

fn fuzzParser(ctx: *ParserFuzzContext, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    const parser = &ctx.parser;
    const input_buffer = &ctx.input_buffer;

    // Garbage followed by a valid sequence.
    const resync = "\x1b[97;5u";
    const garbage_size = smith.slice(input_buffer[0 .. input_buffer.len - resync.len]);
    @memcpy(input_buffer[garbage_size..][0..resync.len], resync);
    var reader: std.Io.Reader = .fixed(input_buffer[0 .. garbage_size + resync.len]);

    var resynced = false;
    while (true) {
        const action = parser.next(&reader) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        // Every action is well formed.
        switch (action) {
            .print => |byte| try std.testing.expect(byte >= 0x20 and byte <= 0x7E),
            .execute => |byte| try std.testing.expect(byte <= 0x1F or byte == 0x7F),
            .esc_dispatch => |esc| {
                try std.testing.expect(esc.intermediates.len <= 2);
                for (esc.intermediates) |byte| try std.testing.expect(byte >= 0x20 and byte <= 0x2F);
                try std.testing.expect(esc.final >= 0x30 and esc.final <= 0x7E);
            },
            .csi_dispatch => |csi| {
                if (csi.private_marker) |marker| try std.testing.expect(marker >= 0x3C and marker <= 0x3F);
                try std.testing.expect(csi.params.len <= 16);
                try std.testing.expect(csi.intermediates.len <= 2);
                for (csi.intermediates) |byte| try std.testing.expect(byte >= 0x20 and byte <= 0x2F);
                try std.testing.expect(csi.final >= 0x40 and csi.final <= 0x7E);
            },
        }
        _ = Event.decode(action); // any action can be decoded
        // The valid sequence is parsed whatever state the garbage left the parser in.
        resynced = action == .csi_dispatch and
            action.csi_dispatch.private_marker == null and
            std.mem.eql(u32, action.csi_dispatch.params, &.{ 97, 5 }) and
            action.csi_dispatch.intermediates.len == 0 and
            action.csi_dispatch.final == 'u';
    }
    try std.testing.expect(resynced);
}

test fuzzParser {
    var ctx: ParserFuzzContext = .{};
    try std.testing.fuzz(&ctx, fuzzParser, .{});
}

/// Fake formatter for testing. Double all blank lines. Remove all indentation. Like a real
/// formatter on a syntax error, fail (return null) if braces are unbalanced. Also fail if the
/// output doesn't fit in the scratch buffer, like `runFormatter`.
fn formatDocumentWithTestFormatter(document: []const u8, scratch_buffer: []u8) ?[]const u8 {
    if (std.mem.countScalar(u8, document, '{') != std.mem.countScalar(u8, document, '}'))
        return null;

    // Double all blank lines ("\n\n" -> "\n\n\n").
    if (std.mem.replacementSize(u8, document, "\n\n", "\n\n\n") > scratch_buffer.len) return null;
    const replacement_count = std.mem.replace(u8, document, "\n\n", "\n\n\n", scratch_buffer);
    const with_newlines_doubled = scratch_buffer[0 .. document.len + replacement_count];

    var formatted: std.ArrayList(u8) = .fromOwnedSlice(with_newlines_doubled);

    // Remove all indentation. Start with first line.
    while (formatted.items.len != 0 and formatted.items[0] == ' ') _ = formatted.orderedRemove(0);
    // Remove remaining indentation (e.g. following newlines). Replace "\n " with "\n" until "\n "
    // no longer found.
    while (std.mem.find(u8, formatted.items, "\n ")) |index|
        // Safe to assume capacity because we are shrinking the slice.
        formatted.replaceRangeAssumeCapacity(index, "\n ".len, "\n");

    return formatted.items;
}

test formatDocumentWithTestFormatter {
    var buffer: [128]u8 = undefined;

    try std.testing.expectEqualStrings(
        \\#include <stdio.h>
        \\
        \\
        \\int main() {
        \\printf("Hello, world!\n");
        \\return 0;
        \\}
        \\
    , formatDocumentWithTestFormatter(
        \\#include <stdio.h>
        \\
        \\int main() {
        \\  printf("Hello, world!\n");
        \\  return 0;
        \\}
        \\
    , &buffer).?);

    try std.testing.expectEqualStrings(
        "hello\n\n\n\n\n\nworld!\n",
        formatDocumentWithTestFormatter(" hello\n\n\n\n  world!\n", &buffer).?,
    );

    try std.testing.expectEqualStrings("", formatDocumentWithTestFormatter("", &buffer).?);
    try std.testing.expectEqualStrings("", formatDocumentWithTestFormatter(" ", &buffer).?);
    try std.testing.expectEqualStrings("\n\n\n", formatDocumentWithTestFormatter(" \n\n", &buffer).?);

    // Output doesn't fit.
    try std.testing.expectEqual(null, formatDocumentWithTestFormatter("\n\n\n\n", buffer[0..5]));

    // Unbalanced braces fail.
    try std.testing.expectEqual(null, formatDocumentWithTestFormatter("int main() {\n", &buffer));
    try std.testing.expectEqual(null, formatDocumentWithTestFormatter("}\n", &buffer));
}

fn validateDocument(document: []const u8) error{FileContainsInvalidCharacter}!void {
    var line_number: u32 = 0;
    var line_offset: u32 = 0;
    for (document) |c| {
        if (!characterValid(c)) {
            std.log.warn(
                "file contains invalid character (0x{x}) at {d}:{d}",
                .{ c, line_number + 1, line_offset + 1 },
            );
            return error.FileContainsInvalidCharacter;
        }

        line_offset += 1;
        if (c == '\n') {
            line_number += 1;
            line_offset = 0;
        }
    }
}

/// Build a valid document from the raw file bytes in `scratch_buffer[0..file_size]`. A valid
/// document is not empty, contains only newlines and printable ASCII, and ends in a newline. To get
/// there we expand tabs to eight spaces, add a missing trailing newline, and turn an empty file into
/// a single newline. Any of those mean the document no longer matches the file on disk so we mark
/// it dirty.
fn load(
    document: *std.ArrayList(u8),
    dirty: *bool,
    scratch_buffer: []u8,
    file_size: u32,
) error{ FileTooLong, FileContainsInvalidCharacter }!void {
    assert(document.capacity > 0);
    assert(scratch_buffer.len >= document.capacity); // expanded file must fit in scratch too
    assert(file_size <= document.capacity); // callers read at most file_size_max bytes

    // Replace all tabs with eight spaces, in the scratch buffer. Capacity is limited to the
    // document's so that a file that's too long once expanded fails here.
    var expanded: std.ArrayList(u8) = .initBuffer(scratch_buffer[0..document.capacity]);
    expanded.items.len = file_size;
    while (std.mem.findScalar(u8, expanded.items, '\t')) |index| {
        const tab_whitespace: [8]u8 = @splat(' ');
        expanded.replaceRangeBounded(index, 1, &tab_whitespace) catch return error.FileTooLong;
    }

    try validateDocument(expanded.items);

    // Start from the smallest valid document then replace it with the file. `replace` takes care
    // of empty files and the trailing newline.
    document.clearRetainingCapacity();
    document.appendAssumeCapacity('\n');
    try replace(document, dirty, 0, 1, expanded.items);

    // `replace` always marks the document dirty. Every change we make while loading adds bytes
    // (tab -> 8 spaces, missing newline, empty file), so the document matches the file on disk
    // exactly when the sizes match.
    assert(document.items.len >= file_size);
    dirty.* = document.items.len != file_size;
}

test load {
    var document_buffer: [16]u8 = undefined;
    var document: std.ArrayList(u8) = .initBuffer(&document_buffer);
    var scratch_buffer: [document_buffer.len]u8 = undefined;
    var dirty = true;

    // Already valid. Unchanged, not dirty.
    @memcpy(scratch_buffer[0..4], "abc\n");
    try load(&document, &dirty, &scratch_buffer, 4);
    try std.testing.expectEqualStrings("abc\n", document.items);
    try std.testing.expect(!dirty);

    // Empty file becomes a single newline.
    try load(&document, &dirty, &scratch_buffer, 0);
    try std.testing.expectEqualStrings("\n", document.items);
    try std.testing.expect(dirty);

    // Missing trailing newline is added.
    dirty = false;
    @memcpy(scratch_buffer[0..3], "abc");
    try load(&document, &dirty, &scratch_buffer, 3);
    try std.testing.expectEqualStrings("abc\n", document.items);
    try std.testing.expect(dirty);

    // Tabs are expanded.
    dirty = false;
    @memcpy(scratch_buffer[0..3], "\ta\n");
    try load(&document, &dirty, &scratch_buffer, 3);
    try std.testing.expectEqualStrings("        a\n", document.items);
    try std.testing.expect(dirty);

    // Exactly fills the document.
    dirty = true;
    @memcpy(scratch_buffer[0..16], "123456789012345\n");
    try load(&document, &dirty, &scratch_buffer, 16);
    try std.testing.expectEqualStrings("123456789012345\n", document.items);
    try std.testing.expect(!dirty);

    // Full but no room for the trailing newline.
    @memcpy(scratch_buffer[0..16], "1234567890123456");
    try std.testing.expectError(error.FileTooLong, load(&document, &dirty, &scratch_buffer, 16));

    // Too long once tabs are expanded.
    @memcpy(scratch_buffer[0..3], "\t\t\n");
    try std.testing.expectError(error.FileTooLong, load(&document, &dirty, &scratch_buffer, 3));

    // Invalid characters.
    std.testing.log_level = .err; // don't print the expected warning
    @memcpy(scratch_buffer[0..3], "a\rb");
    try std.testing.expectError(
        error.FileContainsInvalidCharacter,
        load(&document, &dirty, &scratch_buffer, 3),
    );
}

fn characterValid(c: u8) bool {
    return switch (c) {
        0x0A => true, // newline
        0x20...0x7E => true, // printable
        else => false,
    };
}

fn offsetFromPosition(buffer: []const u8, line_number: u32, line_offset: u32) ?u32 {
    var offset: u32 = 0;
    // Go to the start of line line_number.
    for (0..line_number) |_| {
        const line_tail: u32 =
            @intCast(std.mem.findScalarPos(u8, buffer, offset, '\n') orelse return null);
        offset = line_tail + 1;
        if (offset == buffer.len) return null;
    }
    const line_tail = lineTail(buffer, offset);
    // Line offset must land within the current line.
    offset += line_offset;
    if (offset > line_tail or offset >= buffer.len) return null;
    return offset;
}

test offsetFromPosition {
    const buffer = "\n\n \n  \n";
    try std.testing.expectEqual(0, offsetFromPosition(buffer, 0, 0));
    try std.testing.expectEqual(4, offsetFromPosition(buffer, 3, 0));
    try std.testing.expectEqual(null, offsetFromPosition(buffer, 4, 0));
    try std.testing.expectEqual(5, offsetFromPosition(buffer, 3, 1));
    try std.testing.expectEqual(6, offsetFromPosition(buffer, 3, 2));
    try std.testing.expectEqual(null, offsetFromPosition(buffer, 3, 3));
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

fn position(buffer: []const u8, offset: u32) Position {
    return .{
        .line_number = lineNumber(buffer, offset),
        .line_offset = lineOffset(buffer, offset),
    };
}

pub const EditorFuzzContext = struct {
    const file_size_max = 512;
    const col_count_max = 80;
    const row_count_max = 60;

    file_buffer: [file_size_max]u8 = undefined,
    file_path_buffer: [col_count_max]u8 = undefined,
    document_buffer: [file_size_max]u8 = undefined,
    clipboard_buffer: [file_size_max]u8 = undefined,
    scratch_buffer: [file_size_max]u8 = undefined,
    prompt_buffer: [col_count_max - 1]u8 = undefined,
};

pub fn fuzzEditor(ctx: *EditorFuzzContext, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    // Generate editor state.
    const file_size = smith.slice(&ctx.file_buffer);
    const file = ctx.file_buffer[0..file_size];
    const file_path_size = smith.slice(&ctx.file_path_buffer);
    const file_path = ctx.file_path_buffer[0..file_path_size];
    const row_count = smith.valueRangeAtMost(u32, 0, EditorFuzzContext.row_count_max);
    const col_count = smith.valueRangeAtMost(u32, 0, EditorFuzzContext.col_count_max);
    const line_count: u32 = @intCast(std.mem.countScalar(u8, file, '\n') + 1);
    const cursor_line_number = smith.valueRangeLessThan(u32, 0, line_count);
    const cursor_line_offset = smith.valueRangeLessThan(u32, 0, EditorFuzzContext.col_count_max);

    var discarding_writer: std.Io.Writer.Discarding = .init(&.{});
    var file_reader: std.Io.Reader = .fixed(file);
    var editor = Editor.init(.{
        .io = .failing,
        .buffers = .{
            .document = &ctx.document_buffer,
            .clipboard = &ctx.clipboard_buffer,
            .scratch = &ctx.scratch_buffer,
            .prompt = &ctx.prompt_buffer,
        },
        .file_path = file_path,
        .file_reader = &file_reader,
        .writer = &discarding_writer.writer,
        .col_count = col_count,
        .row_count = row_count,
        .col_count_max = EditorFuzzContext.col_count_max,
        .row_count_max = EditorFuzzContext.row_count_max,
        .cursor_line_number = cursor_line_number,
        .cursor_line_offset = cursor_line_offset,
        .is_test = true,
    }) catch |err| switch (err) {
        error.FileTooLong,
        error.FileContainsInvalidCharacter,
        => return,
        else => return err,
    };

    editor.start() catch |err| switch (err) {
        error.ViewportTooLarge,
        error.ViewportTooSmall,
        => return,
        else => return err,
    };
    while (true) {
        const event: Event = smith.value(Event); // generate input
        if (event == .ascii and !characterValid(event.ascii)) continue; // valid ascii only
        if (editor.tick(event) catch |err| switch (err) {
            error.FileTooLong,
            error.ViewportTooLarge,
            error.ViewportTooSmall,
            => return,
            else => return err,
        }) continue else return;
    }
}

test fuzzEditor {
    std.testing.log_level = .err;
    var ctx: EditorFuzzContext = .{};
    return std.testing.fuzz(&ctx, fuzzEditor, .{});
}

test Modifiers {
    try std.testing.expect(Modifiers.decode(1) == Modifiers{
        .shift = false,
        .alt = false,
        .ctrl = false,
        .super = false,
        .hyper = false,
        .meta = false,
        .caps_lock = false,
        .num_lock = false,
    });

    try std.testing.expect(Modifiers.decode(2) == Modifiers{
        .shift = true,
        .alt = false,
        .ctrl = false,
        .super = false,
        .hyper = false,
        .meta = false,
        .caps_lock = false,
        .num_lock = false,
    });

    try std.testing.expect(Modifiers.decode(6) == Modifiers{
        .shift = true,
        .alt = false,
        .ctrl = true,
        .super = false,
        .hyper = false,
        .meta = false,
        .caps_lock = false,
        .num_lock = false,
    });

    try std.testing.expect(Modifiers.decode(256) == Modifiers{
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

test "handle allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn allocAndFree(allocator: std.mem.Allocator) !void {
            const buffers: Buffers = try .alloc(allocator, .{
                .file_size_max = 64,
                .col_count_max = 80,
            });
            buffers.free(allocator);
        }
    }.allocAndFree, .{});
}

test "handle reader failures" {
    var buffer: [1]u8 = undefined;
    var reader: std.Io.Reader = .failing; // borrow failing logic
    reader.buffer = &buffer; // but give it a real buffer so we get an error instead of unreachable
    var parser: Parser = .{};
    try std.testing.expectError(error.ReadFailed, Event.next(&parser, &reader));
}
