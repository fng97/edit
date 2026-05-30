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

// NB: Rows and columns are indexed from (0, 0), representing the top left corner.

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
    const file_buffer = try allocator.alloc(u8, 1 * 1024 * 1024); // 1 MiB
    defer allocator.free(file_buffer);
    const file_bytes = try std.Io.Dir.cwd().readFile(io, file_name, file_buffer);
    for (file_bytes) |byte| assert(std.ascii.isAscii(byte));
    const lines_buffer = try allocator.alloc(Line, 10 * 1024); // ~10k lines max
    defer allocator.free(lines_buffer);
    var lines: std.ArrayList(Line) = .initBuffer(lines_buffer);
    index_lines(file_bytes, &lines);

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

    // TODO: Get rid of this. Expect to get the dimensions on first pass of loop below.
    // Get window size using ioctl. Future resizing relies on in-band resize notifications (escape
    // sequences).
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = std.posix.system.ioctl(stdout.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    assert(std.posix.errno(err) == .SUCCESS);
    var rows = winsize.row;
    var cols = winsize.col;

    // Determine gutter width: enough for the digits of the greatest line number plus one more for
    // padding.
    var gutter_width = digit_count(@intCast(@max(rows, lines.items.len))) + 1;
    var cursor_offset: u32 = 0; // start at the first character of the first line

    loop: while (true) {
        // TODO: Render screen after handling input.
        // Render screen.
        try writer.writeAll("\x1b[2J"); // clear screen
        try writer.writeAll("\x1b[H"); // place cursor at top left
        gutter_width = digit_count(@intCast(@max(rows, lines.items.len))) + 1;
        for (0..rows - 1) |row| try writer.print(
            "{[line_number]d: >[gutter_width]} {[line]s}\r\n",
            .{
                .line_number = row + 1, // line numbers indexed from 1
                .gutter_width = gutter_width - 1, // extra space of padding already in format string
                .line = if (row < lines.items.len) lines.items[row].slice(file_bytes) else "~",
            },
        );
        // Draw status line. Displayed line number and offset should be indexed from 1.
        const cursor_file_pos: FilePos = .from_offset(cursor_offset, lines.items);
        try writer.writeAll(file_name);
        const padding_cols_count = cols -
            file_name.len -
            digit_count(cursor_file_pos.line_number + 1) -
            digit_count(cursor_file_pos.line_offset + 1) -
            1; // the ',' in "{displayed_line_number},{displayed_line_offset}"
        try writer.splatByteAll(' ', padding_cols_count);
        try writer.print("{d},{d}", .{
            cursor_file_pos.line_number + 1,
            cursor_file_pos.line_offset + 1,
        });
        // Make sure cursor is within bounds.
        const cursor_view_pos: ViewPos = .from_file_pos(
            cursor_file_pos,
            lines.items,
            0,
            gutter_width,
            rows,
            cols,
        );
        assert(cursor_view_pos.col >= gutter_width); // right of line numbers
        assert(cursor_view_pos.col < cols); // does not exceed screen bounds horizontally
        assert(cursor_view_pos.row < rows); // does not exceed screen bounds vertically
        // Place the cursor (escape code indexes from 1): CSI rows ; cols H.
        try writer.print("\x1b[{d};{d}H", .{ cursor_view_pos.row + 1, cursor_view_pos.col + 1 });
        try writer.flush();

        // Handle input: parse Kitty Keyboard Protocol events.
        switch (try reader.takeByte()) {
            // Key events that produce text are sent directly as UTF-8 encyoded bytes.
            0x21...0x7E => |c| switch (c) {
                'q' => break :loop, // quit
                'h' => cursor_offset =
                    cursor_file_pos.move(.left, lines.items).to_offset(lines.items),
                'j' => cursor_offset =
                    cursor_file_pos.move(.down, lines.items).to_offset(lines.items),
                'k' => cursor_offset =
                    cursor_file_pos.move(.up, lines.items).to_offset(lines.items),
                'l' => cursor_offset =
                    cursor_file_pos.move(.right, lines.items).to_offset(lines.items),
                else => {},
            },
            '\x1b' => { // escape sequence
                assert(try reader.takeByte() == '['); // escape sequences must start with CSI
                switch (try std.fmt.parseInt(i32, (try reader.takeDelimiter(';')).?, 10)) {
                    // TODO: Enforce that escape codes use lowercase codepoint:
                    // https://sw.kovidgoyal.net/kitty/keyboard-protocol/#key-codes

                    // Resize: CSI 48 ; height_chars ; width_chars ; height_pix ; width_pix t.
                    48 => {
                        rows = try std.fmt.parseInt(u16, (try reader.takeDelimiter(';')).?, 10);
                        cols = try std.fmt.parseInt(u16, (try reader.takeDelimiter(';')).?, 10);
                        _ = try reader.takeDelimiter(';'); // height_pix
                        _ = try reader.takeDelimiter('t'); // width_pix
                    },
                    else => |c| std.debug.panic(
                        "Unrecognized sequence: {x}{x}",
                        .{ c, reader.buffered() },
                    ),
                }
            },
            else => |c| std.debug.panic("Unrecognized sequence: {x}{x}", .{ c, reader.buffered() }),
        }
    }
}

const FilePos = struct {
    line_number: u16, // zero-indexed
    line_offset: u16,

    pub fn from_offset(offset: u32, lines: []const Line) FilePos {
        for (lines, 0..) |line, line_number| {
            if (offset <= line.tail) return .{
                .line_number = @intCast(line_number),
                .line_offset = @intCast(offset - line.head),
            };
        } else @panic("Offset not within file bounds");
    }

    pub fn move(file_pos: FilePos, direction: enum { left, down, up, right }, lines: []const Line) FilePos {
        const line_number = file_pos.line_number;
        const line_offset = file_pos.line_offset;
        const line = lines[line_number];
        const line_size = line.tail - line.head;

        switch (direction) {
            .left => return .{ .line_number = line_number, .line_offset = line_offset -| 1 },
            .right => if (line_offset + 1 < line_size) return .{
                .line_number = line_number,
                .line_offset = line_offset + 1,
            },
            .up => if (line_number > 0) {
                // Clamp the offset in case previous line is shorter than the current one. Subtract
                // 1 to go from size to offset, saturated so we don't underflow.
                const prev_line_end = lines[line_number - 1].size() -| 1;
                return .{
                    .line_number = line_number - 1,
                    .line_offset = @intCast(if (line_offset > prev_line_end) prev_line_end else line_offset),
                };
            },
            .down => if (line_number + 1 < lines.len) {
                const next_line_end = lines[line_number + 1].size() -| 1;
                return .{
                    .line_number = line_number + 1,
                    .line_offset = @intCast(if (line_offset > next_line_end) next_line_end else line_offset),
                };
            },
        }
        return file_pos;
    }

    pub fn to_offset(file_pos: FilePos, lines: []const Line) u32 {
        return lines[file_pos.line_number].head + file_pos.line_offset;
    }
};

const ViewPos = struct {
    row: u16,
    col: u16,

    pub fn from_file_pos(
        file_pos: FilePos,
        lines: []const Line,
        first_line: u16,
        gutter_width: u8,
        row_count: u16,
        col_count: u16,
    ) ViewPos {
        // TODO: Get line wrapping working later.
        for (first_line..first_line + row_count) |i|
            assert(lines[i].tail - lines[i].head <= col_count);
        const row = file_pos.line_number - first_line;
        assert(row < row_count);
        const col = file_pos.line_offset + gutter_width;
        assert(col < col_count);
        return .{ .row = row, .col = col };
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

fn index_lines(file_bytes: []const u8, lines: *std.ArrayList(Line)) void {
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

test index_lines {
    var lines_buffer: [32]Line = undefined;
    var lines: std.ArrayList(Line) = .initBuffer(&lines_buffer);

    const hello_c =
        \\#include <stdio.h>
        \\
        \\int main() {
        \\  printf("Hello, world!\n");
        \\  return 0;
        \\}
        \\
    ;
    index_lines(hello_c, &lines);
    try std.testing.expect(lines.items.len == 6);
    try std.testing.expect(lines.items[0].head == 0);
    try std.testing.expect(lines.items[0].tail == 18);
    try std.testing.expect(lines.getLast().tail == hello_c.len - 1);

    const empty_file = "\n"; // need at least a newline
    index_lines(empty_file, &lines);
    try std.testing.expect(lines.items.len == 1);
    try std.testing.expect(lines.items[0].head == 0);
    try std.testing.expect(lines.items[0].tail == 0);
}

// This trick gets us the number of digits in a positive number: log_10(x) + 1.
fn digit_count(number: u16) u8 {
    return std.math.log10_int(number) + 1;
}

var termios_original: ?std.posix.termios = null;
// Wrap panic handler so that we can restore terminal state first. Calls default panic after
// cleanup. Cleanup logic runs only once. This prevents jank backtraces when we crash.
pub const panic = std.debug.FullPanic(struct {
    pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        @branchHint(.cold);
        if (termios_original) |t| {
            var threaded: std.Io.Threaded = .init_single_threaded;
            // Disable KKP (CSI < u) and resize (CSI ) then exit alt screen (CSI ? 1049 l).
            std.Io.File.stdout().writeStreamingAll(
                threaded.io(),
                "\x1b[<u\x1b[?2048l\x1b[?1049l",
            ) catch {};
            std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, t) catch {}; // restore termios
            termios_original = null; // so we only do this once
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panic);
