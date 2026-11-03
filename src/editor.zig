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

const root = @This();
const assert = std.debug.assert;

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
const esc_highlight_foreground = "\x1b[30m"; // black
const esc_highlight_background = "\x1b[47m"; // white (light gray on most palettes)
const esc_line_number_foreground = "\x1b[33m"; // yellow
const esc_colour_reset = "\x1b[0m";

const Editor = struct {
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
            command: struct { text: std.ArrayList(u8), cursor_offset: u8 },
            message: enum { command_not_recognised, formatting_failed },
            unsaved,
        },
    },
    document: std.ArrayList(u8),
    dirty: bool = false,
    prompt_text_buffer: []u8,
    scratch_buffer: []u8, // used for formatting, selection paste
    clipboard: std.ArrayList(u8),

    fn tick(editor: *Editor, event: Event) !bool {
        if (event == .resize) {
            editor.viewport.row_count = event.resize.row_count;
            editor.viewport.col_count = event.resize.col_count;
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
                    'i' => editor.mode = .insert,
                    'I' => {
                        const offset = lineHead(editor.document.items, editor.cursor.offset) +
                            lineIndentation(editor.document.items, editor.cursor.offset);
                        editor.cursor.update(editor.document.items, offset, .snap_update);
                        editor.mode = .insert;
                    },
                    'a' => {
                        editor.cursor.move(.right, 1, editor.document.items);
                        editor.mode = .insert;
                    },
                    'A' => {
                        editor.cursor.moveMax(.right, editor.document.items);
                        editor.mode = .insert;
                    },
                    'o' => {
                        editor.cursor.moveMax(.right, editor.document.items);
                        const indentation = lineIndentation(
                            editor.document.items,
                            editor.cursor.offset,
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
                    'O' => {
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
                    // Enable/disable selection.
                    'v' => editor.cursor.anchor =
                        if (editor.cursor.anchor != null) null else editor.cursor.offset,
                    'd' => delete(
                        &editor.document,
                        &editor.clipboard,
                        &editor.cursor,
                        &editor.dirty,
                    ),
                    ':' => editor.mode = .{
                        .prompt = .{
                            .command = .{
                                .text = .initBuffer(editor.prompt_text_buffer),
                                .cursor_offset = 0,
                            },
                        },
                    },
                    'y' => yank(editor.document.items, &editor.clipboard, &editor.cursor),
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
                    .ascii => |c| try insert(&editor.document, &editor.cursor, &editor.dirty, &.{c}),
                    .backspace => if (editor.cursor.offset != 0) {
                        editor.cursor.move(.left, 1, editor.document.items);
                        delete(&editor.document, &editor.clipboard, &editor.cursor, &editor.dirty);
                    },
                    .tab => try insert(&editor.document, &editor.cursor, &editor.dirty, "    "),
                    .enter => {
                        const indent_count = lineIndentation(editor.document.items, editor.cursor.offset);
                        try insert(&editor.document, &editor.cursor, &editor.dirty, "\n");
                        for (0..indent_count) |_| try insert(&editor.document, &editor.cursor, &editor.dirty, " ");
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
                    .enter => {
                        if (std.mem.eql(u8, "w", command.text.items)) {
                            if (try editor.formatAndSave()) editor.mode = .normal;
                        } else if (std.mem.eql(u8, "q", command.text.items)) {
                            if (!editor.dirty) return false; // exit!
                            // Trying to exit without saving. Prompt user to save.
                            editor.mode = .{ .prompt = .unsaved };
                        } else if (std.mem.eql(u8, "w!", command.text.items)) { // skip formatting
                            try editor.save();
                            editor.mode = .normal;
                        } else if (std.mem.eql(u8, "q!", command.text.items)) {
                            return false; // exit, for real!
                        } else if (std.mem.eql(u8, "wq", command.text.items)) {
                            if (try editor.formatAndSave()) return false; // exit if saved
                        } else if (std.mem.eql(u8, "wq!", command.text.items)) { // skip formatting
                            try editor.save();
                            return false;
                        } else if (std.fmt.parseInt(u32, command.text.items, 10) catch null) |number| {
                            // Line number given is indexed from 1.
                            const line_number = @max(number, 1) - 1;
                            if (lineHeadFromNumber(editor.document.items, line_number)) |head| {
                                editor.cursor.update(editor.document.items, head, .snap_remain);
                                editor.centreCursorVertically();
                            }
                            editor.mode = .normal;
                        } else editor.mode = .{ .prompt = .{ .message = .command_not_recognised } };
                    },
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
        // Selection anchor must point into the document.
        if (editor.cursor.anchor) |anchor| assert(anchor < editor.document.items.len);

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
            // Draw gutter: coloured line number and space delimiter.
            try writer.print(esc_line_number_foreground ++ "{[line_number]d: >[gutter_width]}" ++
                esc_colour_reset ++ " ", .{
                .line_number = line_number + 1, // displayed line number indexed from 1
                .gutter_width = gutter_width - 1, // space suffix already in format string
            });

            if (line_head < document.len) {
                const line_tail = lineTail(document, line_head);

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

                        try writer.writeByte(document[offset]);

                        if (offset == highlight_tail) {
                            highlight = false;
                            try writer.writeAll(esc_colour_reset);
                        }
                    }

                    // Reset before printing the next line so that line numbers aren't highlighted.
                    if (highlight) try writer.writeAll(esc_colour_reset);
                } else try writer.writeAll(document[cropped_head..cropped_tail]); // normal line

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

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        writer: *std.Io.Writer,
        file_path: []const u8,
        file_reader: *std.Io.Reader,
        options: struct {
            cursor_line_number: u32,
            cursor_line_offset: u32,
            col_count: u32,
            row_count: u32,
            file_size_max: u32,
            col_count_max: u32,
            row_count_max: u32,
        },
    ) !Editor {
        // Read the file into the scratch buffer. The document is built from it by `load`.
        const scratch_buffer = try allocator.alloc(u8, options.file_size_max);
        errdefer allocator.free(scratch_buffer);
        var scratch_writer: std.Io.Writer = .fixed(scratch_buffer);
        const file_size = file_reader.streamRemaining(&scratch_writer) catch |err| switch (err) {
            error.WriteFailed => return error.FileTooLong,
            error.ReadFailed => return err,
        };
        var document: std.ArrayList(u8) = try .initCapacity(allocator, options.file_size_max);
        errdefer document.deinit(allocator);
        var dirty = false;
        try load(&document, &dirty, scratch_buffer, @intCast(file_size));

        var clipboard: std.ArrayList(u8) = try .initCapacity(allocator, options.file_size_max);
        errdefer clipboard.deinit(allocator);
        // -1 accounts for the ':' shown when the prompt is active.
        const prompt_text_buffer = try allocator.alloc(u8, options.col_count_max - 1);
        errdefer allocator.free(prompt_text_buffer);

        const cursor_offset_start: ?u32 = offsetFromPosition(
            document.items,
            options.cursor_line_number,
            options.cursor_line_offset,
        ) orelse null;

        return .{
            .is_test = builtin.is_test,
            .io = io,
            .writer = writer,
            .mode = .normal,
            .viewport = .{
                .row_count = options.row_count,
                .col_count = options.col_count,
                .line_number_start = 0,
                .line_offset_start = 0,
            },
            .file_path = file_path,
            .document = document,
            .dirty = dirty,
            .cursor = .{
                .offset = cursor_offset_start orelse 0,
                .anchor = null,
                .line_offset_snap = if (cursor_offset_start) |_| options.cursor_line_offset else 0,
            },
            .clipboard = clipboard,
            .prompt_text_buffer = prompt_text_buffer,
            .scratch_buffer = scratch_buffer,
            .col_count_max = options.col_count_max,
            .row_count_max = options.row_count_max,
        };
    }

    fn deinit(editor: *Editor, allocator: std.mem.Allocator) void {
        editor.document.deinit(allocator);
        editor.clipboard.deinit(allocator);
        allocator.free(editor.prompt_text_buffer);
        allocator.free(editor.scratch_buffer);
    }

    /// Format document if formatter available then save. If formatting fails, show the error and
    /// don't save. Returns whether the document was saved so the caller can decide what to do next
    /// (e.g. exit).
    fn formatAndSave(editor: *Editor) !bool {
        if (try editor.formatDocument() == false) {
            editor.mode = .{ .prompt = .{ .message = .formatting_failed } };
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
        const document_kind: enum {
            zig,
            markdown,
            sh,
            testing,
            c, // C and C++
            unknown,
        } = if (editor.is_test)
            .testing
        else if (std.mem.endsWith(u8, editor.file_path, ".zig") or
            std.mem.endsWith(u8, editor.file_path, ".zon"))
            .zig
        else if (std.mem.endsWith(u8, editor.file_path, ".md"))
            .markdown
        else if (std.mem.endsWith(u8, editor.file_path, ".c") or
            std.mem.endsWith(u8, editor.file_path, ".h") or
            std.mem.endsWith(u8, editor.file_path, ".cpp") or
            std.mem.endsWith(u8, editor.file_path, ".hpp"))
            .c
        else if (std.mem.endsWith(u8, editor.file_path, ".sh"))
            .sh
        else
            .unknown;

        const formatted = (if (document_kind == .testing) formatDocumentWithTestFormatter(
            editor.document.items,
            editor.scratch_buffer,
        ) else try runFormatter(editor.io, switch (document_kind) {
            .testing => unreachable,
            .zig => &.{ "zig", "fmt", "--stdin" },
            .markdown => &.{ "prettier", "--parser", "markdown" },
            .sh => &.{ "shfmt", "--indent", "4" },
            .c => &.{ "clang-format", "--style=Google" },
            .unknown => return null, // no formatter, save as is
        }, editor.document.items, editor.scratch_buffer)) orelse return false;

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
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    const log_buffer = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(log_buffer);
    var log_writer_fixed: std.Io.Writer = .fixed(log_buffer);
    log_writer = &log_writer_fixed;
    // Defer order matters here. The logs should only be printed once the original terminal state
    // is restored.
    defer std.debug.print("{s}", .{log_writer_fixed.buffered()});

    var cursor_line_number: ?u32 = null;
    var cursor_line_offset: ?u32 = null;
    var args_iterator = init.minimal.args.iterate();
    assert(args_iterator.skip()); // first arg is executable path
    const file_path = args_iterator.next() orelse @panic("missing file path arg");
    while (args_iterator.next()) |arg| {
        // Option to open editor with cursor at the given Position (indexed from one).
        if (std.mem.startsWith(u8, arg, "--goto=")) {
            const colon_index = std.mem.indexOfScalar(u8, arg, ':').?;
            cursor_line_number = try std.fmt.parseInt(u32, arg["--goto=".len..colon_index], 10);
            cursor_line_offset = try std.fmt.parseInt(u32, arg[colon_index + 1 ..], 10);
        } else std.debug.panic("argument not recognised: {s}", .{arg});
    }

    const stdin = std.Io.File.stdin();
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = stdin.reader(io, &stdin_buffer);
    const reader: *std.Io.Reader = &stdin_reader.interface;

    const stdout_buffer = try allocator.alloc(u8, 16 * 1024);
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

    const dimensions = switch (try parseOne(reader)) {
        .resize => |dimensions| dimensions,
        else => return error.FirstEventMustBeResize,
    };

    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    var file_reader = file.reader(io, &.{});
    var editor: Editor = try .init(
        allocator,
        io,
        writer,
        file_path,
        &file_reader.interface,
        .{
            .cursor_line_number = if (cursor_line_number) |cln| cln - 1 else 0,
            .cursor_line_offset = if (cursor_line_offset) |clo| clo - 1 else 0,
            .row_count = dimensions.row_count,
            .col_count = dimensions.col_count,
            .file_size_max = 1 * 1024 * 1024, // 1 MB
            .col_count_max = 400,
            .row_count_max = 300,
        },
    );
    file.close(io);
    defer editor.deinit(allocator);

    // Do the initial render. In event loop we render on every tick.
    const cursor_position = position(editor.document.items, editor.cursor.offset);
    try editor.focus(cursor_position);
    editor.centreCursorVertically();
    try editor.render(cursor_position);
    while (true) {
        const event = try parseOne(reader);
        if (!try editor.tick(event)) return;
    }
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

var log_writer: ?*std.Io.Writer = null;
fn logFnErr(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) !void {
    if (log_writer) |writer| {
        try writer.writeAll(message_level.asText());
        if (scope != .default) try writer.print("({t})", .{scope});
        try writer.writeAll(": ");
        try writer.print(format ++ "\n", args);
    } else @panic("tried to log without initialising log writer");
}
fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    logFnErr(message_level, scope, format, args) catch |e| std.debug.panic("log failed: {}", .{e});
}
pub const std_options: std.Options = .{ .logFn = logFn };

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

    fn selection(cursor: Cursor) ?struct {
        head: u32,
        tail: u32,

        fn size(s: @This()) u32 {
            return s.tail - s.head + 1; // +1: offset -> size
        }

        fn slice(s: @This(), buffer: []const u8) []const u8 {
            return buffer[s.head .. s.tail + 1];
        }
    } {
        if (cursor.anchor) |anchor| return .{
            .head = @min(anchor, cursor.offset),
            .tail = @max(anchor, cursor.offset),
        } else return null;
    }

    fn head(cursor: Cursor) u32 {
        return if (cursor.selection()) |s| s.head else cursor.offset;
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
    assert(offset < document.items.len);
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
    if (cursor.selection()) |selection| {
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
    cursor = .{ .offset = 0, .anchor = 9, .line_offset_snap = 0 };
    try paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty);
    try std.testing.expectEqualStrings(document_original, document.items);
    try std.testing.expectEqualStrings("HelloHello", clipboard.items);
    try std.testing.expect(dirty);
    try std.testing.expectEqual(4, cursor.offset);
    try std.testing.expectEqual(null, cursor.anchor);
    try std.testing.expectEqual(4, cursor.line_offset_snap);

    // Paste over a selection (cursor at the tail).
    cursor = .{ .offset = 4, .anchor = 0, .line_offset_snap = 4 };
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
        .anchor = @intCast(document.items.len - 1), // select all
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
    cursor = .{ .offset = 0, .anchor = 0, .line_offset_snap = 0 };
    cursor_before = cursor;
    try std.testing.expectError(
        error.FileTooLong,
        paste(&document, &clipboard, &scratch_buffer, &cursor, &dirty),
    );
    try std.testing.expectEqualStrings(document_original, document.items);
    try std.testing.expectEqualStrings("0123456789abcd", clipboard.items);
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
    const cursor_offset = cursor.head();

    yankInner(document.items, clipboard, cursor.*);

    // Delete from the head of the selection or, without a selection, the byte under the cursor.
    const size: u32 = if (cursor.selection()) |selection| selection.size() else 1;
    // We're removing at least one byte. Even if the trailing newline has to be added back the
    // document can't grow, so this never returns an error.
    assert(size > 0);
    replace(document, dirty, cursor_offset, size, "") catch unreachable;
    cursor.anchor = null;

    cursor.update(document.items, cursor_offset, .snap_update);
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
        .anchor = 0,
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
    cursor = .{ .offset = 6, .anchor = 12, .line_offset_snap = 6 };
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
}

fn yankInner(document: []const u8, clipboard: *std.ArrayList(u8), cursor: Cursor) void {
    assert(clipboard.capacity >= document.len); // any selection fits
    clipboard.clearRetainingCapacity();
    if (cursor.selection()) |selection|
        clipboard.appendSliceAssumeCapacity(selection.slice(document))
    else
        clipboard.appendAssumeCapacity(document[cursor.offset]);
}

fn yank(document: []const u8, clipboard: *std.ArrayList(u8), cursor: *Cursor) void {
    // If it's a selection, snap cursor to head after yank.
    const cursor_offset = cursor.head();
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

    cursor = .{ .offset = 7, .anchor = 13, .line_offset_snap = 7 };
    yank(document, &clipboard, &cursor);
    try std.testing.expectEqualStrings("world!\n", clipboard.items);
    try std.testing.expect(cursor.anchor == null); // deselect after yank
    try std.testing.expect(cursor.offset == 7); // snap back to head
    try std.testing.expectEqual(7, cursor.line_offset_snap);

    // Cursor at the tail of a selection snaps back to the head.
    cursor = .{ .offset = 18, .anchor = 7, .line_offset_snap = 4 };
    yank(document, &clipboard, &cursor);
    try std.testing.expectEqualStrings("world!\n  All", clipboard.items);
    try std.testing.expect(cursor.anchor == null); // deselect after yank
    try std.testing.expectEqual(7, cursor.offset);
    try std.testing.expectEqual(7, cursor.line_offset_snap);

    cursor = .{ // select all
        .offset = document.len - 1,
        .anchor = 0,
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

    /// Decode modifiers from ASCII value passed in escape sequence: "In the escape code, the
    /// modifier value is encoded as a decimal number which is 1 + actual modifiers. So to represent
    /// shift only, the value would be 1 + 1 = 2, to represent ctrl+shift the value would be 1 +
    /// 0b101 = 6 and so on."
    fn decode(encoded: []const u8) error{CsiSequenceInvalid}!Modifiers {
        // u9 because if all bits were high we'd have 255 + 1 = 256, which cannot be stored in a u8.
        const value = try parseCsiInt(encoded);
        if (value == 0) return error.CsiSequenceInvalid;
        if (value - 1 > std.math.maxInt(u8)) return error.CsiSequenceInvalid;
        const byte: u8 = @intCast(value - 1);
        return @bitCast(byte);
    }
};

fn parseCsiInt(text: []const u8) error{CsiSequenceInvalid}!u32 {
    return std.fmt.parseInt(u32, text, 10) catch return error.CsiSequenceInvalid;
}

const ViewportDimensions = struct { row_count: u32, col_count: u32 };

const Event = union(enum) {
    resize: ViewportDimensions,
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
            if (try reader.takeByte() != '[') return error.CsiSequenceInvalid;

            var params_buffer: [32]u8 = undefined;
            var params_index: usize = 0;
            // Read until the final byte so we have all that remains of the escape sequence.
            const final = while (true) : (params_index += 1) switch (try reader.takeByte()) {
                // Since we don't yet support a sequence that uses intermediates, just reject them.
                0x20...0x2F => return error.CsiSequenceNotRecognised, // intermediates
                0x30...0x3F => |byte| {
                    if (params_index == params_buffer.len) return error.CsiSequenceTooLong;
                    params_buffer[params_index] = byte;
                },
                0x40...0x7E => |final_byte| break final_byte,
                else => return error.CsiSequenceInvalid,
            };

            const params = params_buffer[0..params_index];
            var iter = std.mem.splitScalar(u8, params, ';');
            // The escape sequences we support
            const first_str = iter.next() orelse return error.CsiSequenceNotRecognised;
            const first = try parseCsiInt(first_str);
            switch (final) {
                'u' => switch (first) {
                    0x1b => return .escape,
                    // Printable ASCII with modifiers. Codepoints must be the lowercase variant.
                    0x20...0x7E => |c| return .{
                        .chord = .{
                            .ascii = @intCast(switch (c) {
                                // CSI u unicode-key-code must be unshifted (e.g. a not A).
                                'A'...'Z' => return error.CsiSequenceInvalid,
                                else => c,
                            }),
                            // Modifiers may not be present. It defaults to 1 (no modifiers). For
                            // now return an error if these are missing.
                            .modifiers = try .decode(
                                iter.next() orelse return error.CsiSequenceNotRecognised,
                            ),
                        },
                    },
                    else => return error.CsiSequenceNotRecognised,
                },
                't' => switch (first) {
                    // Resize: CSI 48 ; height_chars ; width_chars ; height_pix ; width_pix t. See
                    // https://gist.github.com/rockorager/e695fb2924d36b2bcf1fff4a3704bd83.
                    48 => return .{
                        .resize = .{
                            .row_count = try parseCsiInt(iter.next() orelse return error.CsiSequenceInvalid),
                            .col_count = try parseCsiInt(iter.next() orelse return error.CsiSequenceInvalid),
                        },
                    },
                    else => return error.CsiSequenceNotRecognised,
                },
                else => return error.CsiSequenceNotRecognised,
            }
            unreachable;
        },
        else => return error.CsiSequenceNotRecognised,
    }
}

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

fn fuzzKkpParser(reader_buffer: *[128]u8, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    const size = smith.slice(reader_buffer);
    var reader: std.Io.Reader = .fixed(reader_buffer[0..size]);

    while (true) _ = parseOne(&reader) catch |err| switch (err) {
        error.EndOfStream => return,
        error.CsiSequenceNotRecognised,
        error.CsiSequenceInvalid,
        => continue,
        else => return err,
    };
}

test fuzzKkpParser {
    var reader_buffer: [128]u8 = undefined;
    try std.testing.fuzz(&reader_buffer, fuzzKkpParser, .{});
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
    , formatDocumentWithTestFormatter(hello_c, &buffer).?);

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
    editor: Editor,

    pub fn init(allocator: std.mem.Allocator) !EditorFuzzContext {
        var editor: Editor = undefined;
        editor.document = try .initCapacity(allocator, EditorFuzzContext.file_size_max);
        errdefer editor.document.deinit(allocator);
        editor.clipboard = try .initCapacity(allocator, EditorFuzzContext.file_size_max);
        errdefer editor.clipboard.deinit(allocator);
        editor.scratch_buffer = try allocator.alloc(u8, EditorFuzzContext.file_size_max);
        errdefer allocator.free(editor.scratch_buffer);
        editor.prompt_text_buffer = try allocator.alloc(u8, EditorFuzzContext.col_count_max - 1);
        errdefer allocator.free(editor.prompt_text_buffer);

        return .{ .editor = editor };
    }

    pub fn deinit(ctx: *EditorFuzzContext, allocator: std.mem.Allocator) void {
        ctx.editor.deinit(allocator);
    }
};

pub fn fuzzEditor(ctx: *EditorFuzzContext, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    // Generate editor state.
    var discarding_writer: std.Io.Writer.Discarding = .init(&.{});
    const file_size = smith.slice(&ctx.file_buffer);
    const file = ctx.file_buffer[0..file_size];
    const file_path_size = smith.slice(&ctx.file_path_buffer);
    const file_path = ctx.file_path_buffer[0..file_path_size];
    const row_count = smith.valueRangeAtMost(u32, 0, EditorFuzzContext.row_count_max);
    const col_count = smith.valueRangeAtMost(u32, 0, EditorFuzzContext.col_count_max);
    @memcpy(ctx.editor.scratch_buffer[0..file.len], file);
    var dirty = false;
    load(&ctx.editor.document, &dirty, ctx.editor.scratch_buffer, @intCast(file.len)) catch return;
    const cursor_offset_start =
        smith.valueRangeLessThan(u32, 0, @intCast(ctx.editor.document.items.len));

    // The editor is reused for each fuzzing run to avoid memory allocations in the fuzzer. It is
    // reinitialised using struct initialisation syntax so that we don't forget to update any
    // fields.
    ctx.editor = .{
        .is_test = true,
        .io = .failing,
        .writer = &discarding_writer.writer,
        .col_count_max = EditorFuzzContext.col_count_max,
        .row_count_max = EditorFuzzContext.row_count_max,
        .file_path = file_path,
        .viewport = .{
            .row_count = row_count,
            .col_count = col_count,
            .line_number_start = 0,
            .line_offset_start = 0,
        },
        .cursor = .{
            .offset = cursor_offset_start,
            .anchor = 0,
            .line_offset_snap = lineOffset(ctx.editor.document.items, cursor_offset_start),
        },
        .mode = .normal,
        .document = ctx.editor.document,
        .dirty = dirty,
        .clipboard = blk: {
            ctx.editor.clipboard.clearRetainingCapacity();
            break :blk ctx.editor.clipboard;
        },
        .prompt_text_buffer = ctx.editor.prompt_text_buffer,
        .scratch_buffer = ctx.editor.scratch_buffer,
    };

    const cursor_position = position(ctx.editor.document.items, ctx.editor.cursor.offset);
    ctx.editor.focus(cursor_position) catch return;
    ctx.editor.centreCursorVertically();
    while (true) {
        const event: Event = smith.value(Event); // generate input

        if (event == .ascii and !characterValid(event.ascii)) continue; // valid ascii only

        if (ctx.editor.tick(event) catch |err| switch (err) {
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
    var ctx: EditorFuzzContext = try .init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    return std.testing.fuzz(&ctx, fuzzEditor, .{});
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

const StrippingWriter = struct {
    raw: std.Io.Writer.Allocating, // everything the editor has written since the last takeFrame
    frame: std.Io.Writer.Allocating, // the last frame, stripped
    interface: std.Io.Writer,

    const Colour = enum { strip_colour, keep_colour };

    fn init(allocator: std.mem.Allocator) !StrippingWriter {
        return .{
            .raw = .init(allocator),
            .frame = .init(allocator),
            .interface = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
        };
    }

    fn deinit(stripping: *StrippingWriter) void {
        stripping.raw.deinit();
        stripping.frame.deinit();
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const stripping: *StrippingWriter = @alignCast(@fieldParentPtr("interface", w));

        var write_size: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            try stripping.raw.writer.writeAll(slice);
            write_size += slice.len;
        }

        const splat_slice = data[data.len - 1];
        for (0..splat) |_| try stripping.raw.writer.writeAll(splat_slice);
        return write_size + splat_slice.len * splat;
    }

    fn writer(stripping: *StrippingWriter) *std.Io.Writer {
        return &stripping.interface;
    }

    /// Returns the last frame rendered since the previous call. Strips '\r' and optionally colour
    /// sequences. Discards everything written so far, so a tick that should render but doesn't
    /// fails the next call instead of returning a stale frame.
    fn takeFrame(stripping: *StrippingWriter, colour: Colour) ![]const u8 {
        const raw = stripping.raw.written();
        // Every frame begins with "begin synchronised update".
        var i = std.mem.lastIndexOf(u8, raw, "\x1b[?2026h") orelse @panic("no frame rendered");
        stripping.frame.clearRetainingCapacity();
        while (i < raw.len) {
            if (raw[i] == '\r') {
                i += 1;
                continue;
            }
            // SGR sequence: "\x1b[" then digits and ';' then 'm'.
            if (colour == .strip_colour and std.mem.startsWith(u8, raw[i..], "\x1b[")) {
                const tail = std.mem.indexOfNonePos(u8, raw, i + 2, "0123456789;") orelse raw.len;
                if (tail < raw.len and raw[tail] == 'm') {
                    i = tail + 1;
                    continue;
                }
            }
            try stripping.frame.writer.writeByte(raw[i]);
            i += 1;
        }

        stripping.raw.clearRetainingCapacity();
        return stripping.frame.written();
    }
};

const TestEditor = struct {
    const allocator = std.testing.allocator;

    reader: std.Io.Reader,
    stripping_writer: StrippingWriter,
    editor: Editor,

    fn init(test_editor: *TestEditor, params: struct {
        file_path: []const u8,
        file_bytes: []const u8,
        input: []const u8,
    }) !void {
        var file_reader: std.Io.Reader = .fixed(params.file_bytes);

        test_editor.stripping_writer = try .init(allocator);
        test_editor.reader = .fixed(params.input);

        const dimensions = switch (try parseOne(&test_editor.reader)) {
            .resize => |dimensions| dimensions,
            else => return error.FirstEventMustBeResize,
        };

        test_editor.editor = try .init(
            allocator,
            .failing,
            test_editor.stripping_writer.writer(),
            params.file_path,
            &file_reader,
            .{
                .cursor_line_number = 0,
                .cursor_line_offset = 0,
                .col_count = dimensions.col_count,
                .row_count = dimensions.row_count,
                .file_size_max = 1024,
                .col_count_max = 80,
                .row_count_max = 60,
            },
        );

        const cursor_position = position(
            test_editor.editor.document.items,
            test_editor.editor.cursor.offset,
        );
        try test_editor.editor.focus(cursor_position);
        test_editor.editor.centreCursorVertically();
        try test_editor.editor.render(cursor_position);
    }

    fn deinit(test_editor: *TestEditor) void {
        test_editor.stripping_writer.deinit();
        test_editor.editor.deinit(allocator);
    }

    fn tick(test_editor: *TestEditor) !void {
        const event = try parseOne(&test_editor.reader);
        try std.testing.expect(try test_editor.editor.tick(event) == true);
    }

    fn expectTickExit(test_editor: *TestEditor) !void {
        const event = try parseOne(&test_editor.reader);
        try std.testing.expect(try test_editor.editor.tick(event) == false);
    }

    fn expectQuit(
        test_editor: *TestEditor,
        comptime save: enum { save, no_save },
        comptime force: enum { force, no_force },
    ) !void {
        // Process exit inputs: ":[w]q[!]".
        const input = ":" ++
            (if (save == .save) "w" else "") ++
            "q" ++
            (if (force == .force) "!" else "");
        for (input) |c| {
            const event = try parseOne(&test_editor.reader);
            try std.testing.expect(event == .ascii);
            try std.testing.expectEqual(c, event.ascii);
            try std.testing.expect(try test_editor.editor.tick(event) == true); // no exit yet
        }

        // Process the return (enter) keypress.
        const event = try parseOne(&test_editor.reader);
        try std.testing.expectEqual(.enter, event);
        try std.testing.expect(try test_editor.editor.tick(event) == false); // exit
    }

    fn expectRender(
        test_editor: *TestEditor,
        viewport: []const u8,
        cursor_cell: Viewport.Cell,
        cursor_style: Cursor.Style,
    ) !void {
        try test_editor.expectFrame(.strip_colour, viewport, cursor_cell, cursor_style);
    }

    fn expectFrame(
        test_editor: *TestEditor,
        colour: StrippingWriter.Colour,
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
        try std.testing.expectEqualSlices(u8, expected, try test_editor.stripping_writer.takeFrame(colour));
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

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
}

test "rendering: line number colour" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;4;36;0;0t" ++ // dimensions: 4 rows by 36 cols
            ":q!\r", // quit
    });
    defer test_editor.deinit();

    const ln = esc_line_number_foreground;
    const rs = esc_colour_reset;
    try test_editor.expectFrame(
        .keep_colour,
        ln ++ "1" ++ rs ++ " #include <stdio.h>\n" ++
            ln ++ "2" ++ rs ++ " \n" ++
            ln ++ "3" ++ rs ++ " int main() {\n" ++
            "hello.c                          1,1",
        .{ .row = 0, .col = 2 },
        .steady_block,
    );

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
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

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
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

    try test_editor.tick(); // process G

    try test_editor.expectRender(
        \\3 int main() {
        \\4   printf("Hello, world!\n");
        \\5   return 0;
        \\6 }
        \\hello.c                          6,1
    , .{ .row = 3, .col = 2 }, .steady_block);

    try test_editor.tick(); // process g

    try test_editor.expectRender(
        \\1 #include <stdio.h>
        \\2 
        \\3 int main() {
        \\4   printf("Hello, world!\n");
        \\hello.c                          1,1
    , .{ .row = 0, .col = 2 }, .steady_block);

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
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

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
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

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
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

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
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

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
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

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
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

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
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

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
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

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
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

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
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

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
}

test "opening a file that needs fixing marks it dirty" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "tabs.txt",
        .file_bytes = "\tx", // tab expanded and trailing newline added on load
        .input = "\x1b[48;12;36;0;0t", // dimensions: 12 rows by 36 cols
    });
    defer test_editor.deinit();

    try std.testing.expectEqualStrings("        x\n", test_editor.editor.document.items);
    try std.testing.expect(test_editor.editor.dirty);
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

    try test_editor.tick(); // process \r

    // This looks different because saving also runs formatting. There is a dedicated testing
    // formatter (see `formatDocumentWithTestFormatter`) to avoid calling a real one.
    try test_editor.expectRender(
        \\ 1 include <stdio.h>
        \\ 2 
        \\ 3 
        \\ 4 int main() {
        \\ 5 printf("Hello, world!\n");
        \\ 6 return 0;
        \\ 7 }
        \\ 8 ~
        \\ 9 ~
        \\10 ~
        \\11 ~
        \\hello.c                          1,1
    , .{ .row = 0, .col = 3 }, .steady_block);

    try test_editor.expectQuit(.no_save, .force); // process :q!\r
}

test "formatting clears selection" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "hello.c",
        .file_bytes = hello_c,
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "Gvk" ++ // select from the last line up, anchor near the end of the document
            ":w\r", // save, formatting removes indentation so the document shrinks
    });
    defer test_editor.deinit();

    for ("Gvk") |_| try test_editor.tick();
    const anchor = test_editor.editor.cursor.anchor.?;
    for (":w\r") |_| try test_editor.tick();

    // Without clearing the selection, the anchor would point past the end of the document.
    try std.testing.expect(anchor >= test_editor.editor.document.items.len);
    try std.testing.expectEqual(null, test_editor.editor.cursor.anchor);
    try std.testing.expect(!test_editor.editor.dirty); // formatting marks dirty, saving clears it
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

    for (":wq") |_| try test_editor.tick();
    try test_editor.expectTickExit(); // process \r
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

    try test_editor.expectQuit(.no_save, .no_force); // process :q\r
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

    try test_editor.expectTickExit(); // process y
}

test "save and quit stays open if formatting fails" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "main.c",
        .file_bytes = "int main() {\n", // unbalanced braces, test formatter fails
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "d" ++ // delete first character, make the document dirty
            ":wq\r" ++ // try to save and quit, formatting fails
            "\r" ++ // dismiss the formatting error
            ":wq!\r", // save without formatting and quit
    });
    defer test_editor.deinit();

    try test_editor.tick(); // process d
    for (":wq\r") |_| try test_editor.tick(); // doesn't exit
    try std.testing.expect(test_editor.editor.mode == .prompt);
    try std.testing.expect(test_editor.editor.mode.prompt == .message);
    try std.testing.expectEqual(.formatting_failed, test_editor.editor.mode.prompt.message);
    try std.testing.expect(test_editor.editor.dirty); // not saved
    try std.testing.expectEqualStrings("nt main() {\n", test_editor.editor.document.items);

    try test_editor.tick(); // process \r
    try std.testing.expect(test_editor.editor.mode == .normal);

    for (":wq!") |_| try test_editor.tick();
    try test_editor.expectTickExit(); // process \r
    try std.testing.expect(!test_editor.editor.dirty); // saved
    try std.testing.expectEqualStrings("nt main() {\n", test_editor.editor.document.items);
}

test "save and quit from unsaved prompt formats" {
    var test_editor: TestEditor = undefined;
    try test_editor.init(.{
        .file_path = "main.c",
        .file_bytes = "int main() {\n  return 0;\n", // unbalanced braces, test formatter fails
        .input = "\x1b[48;12;36;0;0t" ++ // dimensions: 12 rows by 36 cols
            "d" ++ // delete first character, make the document dirty
            ":q\r" ++ // try quit, prompts to save
            "y" ++ // save and quit, formatting fails
            "\r" ++ // dismiss the formatting error
            "G" ++ // go to last line
            "o}" ++ // balance the braces...
            "\x1b[27u" ++ // ...and back to normal mode
            ":q\r" ++ // try quit, prompts to save
            "y", // save and quit, formatting succeeds
    });
    defer test_editor.deinit();

    try test_editor.tick(); // process d
    for (":q\ry") |_| try test_editor.tick(); // doesn't exit
    try std.testing.expect(test_editor.editor.mode == .prompt);
    try std.testing.expect(test_editor.editor.mode.prompt == .message);
    try std.testing.expectEqual(.formatting_failed, test_editor.editor.mode.prompt.message);
    try std.testing.expect(test_editor.editor.dirty); // not saved

    try test_editor.tick(); // process \r
    for ("Go}") |_| try test_editor.tick();
    try test_editor.tick(); // process escape
    for (":q\r") |_| try test_editor.tick();
    try test_editor.expectTickExit(); // process y
    try std.testing.expect(!test_editor.editor.dirty); // saved
    // Formatted: indentation removed.
    try std.testing.expectEqualStrings(
        "nt main() {\nreturn 0;\n}\n",
        test_editor.editor.document.items,
    );
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

    try test_editor.expectQuit(.save, .no_force); // process :wq\r
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
    try test_editor.expectQuit(.save, .no_force); // process :wq\r
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
    try test_editor.tick(); // process j

    const ln = esc_line_number_foreground;
    const rs = esc_colour_reset;
    const hl = esc_highlight_foreground ++ esc_highlight_background;
    try test_editor.expectFrame(
        .keep_colour,
        ln ++ " 1" ++ rs ++ " " ++ hl ++ "#include <stdio.h>" ++ rs ++ "\n" ++
            ln ++ " 2" ++ rs ++ " \n" ++
            ln ++ " 3" ++ rs ++ " " ++ hl ++ "i" ++ rs ++ "nt main() {\n" ++
            ln ++ " 4" ++ rs ++ "   printf(\"Hello, world!\\n\");\n" ++
            ln ++ " 5" ++ rs ++ "   return 0;\n" ++
            ln ++ " 6" ++ rs ++ " }\n" ++
            ln ++ " 7" ++ rs ++ " ~\n" ++
            ln ++ " 8" ++ rs ++ " ~\n" ++
            ln ++ " 9" ++ rs ++ " ~\n" ++
            ln ++ "10" ++ rs ++ " ~\n" ++
            ln ++ "11" ++ rs ++ " ~\n" ++
            "hello.c                          3,1",
        .{ .row = 2, .col = 3 },
        .steady_block,
    );

    try test_editor.tick(); // process v
    try test_editor.expectQuit(.no_save, .force); // process :q!\r
}
