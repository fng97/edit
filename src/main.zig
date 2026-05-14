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

// TODO: Add dbg()

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

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

    // Get window size using ioctl. Future resizing relies on in-band resize notifications (escape
    // sequences).
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = std.posix.system.ioctl(stdout.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    assert(std.posix.errno(err) == .SUCCESS);
    var rows = winsize.row;
    var cols = winsize.col;

    // Load and process buffer.
    var args_iterator = std.process.Args.Iterator.init(init.minimal.args);
    assert(args_iterator.skip()); // first arg is executable path
    const file_name = args_iterator.next() orelse @panic("Missing file path arg");
    const file_buffer = try allocator.alloc(u8, 1 * 1024 * 1024); // 1 MiB
    defer allocator.free(file_buffer);
    const file_bytes = try std.Io.Dir.cwd().readFile(io, file_name, file_buffer);
    for (file_bytes) |byte| assert(std.ascii.isAscii(byte));
    // TODO: Keep track of lines.
    const line_count = 1000; // just stub it out for now

    const Cursor = struct { row: u16, col: u16 };
    // Determine gutter width: enough for the digits of the greatest line number plus one more for
    // padding. This trick gets us the number of digits in a positive number: log_10(x) + 1.
    var gutter_width = std.math.log10_int(@as(u16, @max(rows, line_count))) + 2;
    var cursor: Cursor = .{ .row = 0, .col = gutter_width };

    loop: while (true) {

        // Render screen.
        try writer.writeAll("\x1b[2J"); // clear screen
        try writer.writeAll("\x1b[H"); // place cursor at top left
        gutter_width = std.math.log10_int(@as(u16, @max(rows, line_count))) + 2; // TODO: duped
        var lines = std.mem.splitScalar(u8, file_bytes, '\n');
        for (0..rows - 1, 1..) |_, line_number| try writer.print(
            "{[line_number]d: >[gutter_width]} {[line]s}\r\n",
            .{
                .line_number = line_number,
                .gutter_width = gutter_width - 1, // extra space of padding already in format string
                .line = if (lines.next()) |l| l else "~",
            },
        );
        try writer.writeAll(file_name); // status line
        // Make sure cursor is within bounds.
        assert(cursor.col >= gutter_width); // right of line numbers
        assert(cursor.col < cols); // does not exceed screen bounds horizontally
        assert(cursor.row < rows); // does not exceed screen bounds vertically
        // Place the cursor (escape code indexes from 1): CSI rows ; cols H.
        try writer.print("\x1b[{d};{d}H", .{ cursor.row + 1, cursor.col + 1 });
        try writer.flush();

        // Handle input: parse Kitty Keyboard Protocol events.
        switch (try reader.takeByte()) {
            // Key events that produce text are sent directly as UTF-8 encyoded bytes.
            0x21...0x7E => |c| switch (c) {
                'q' => break :loop, // quit
                'h' => { // move cursor left
                    if (cursor.col != gutter_width) cursor.col -= 1;
                },
                'j' => { // move cursor down
                    if (cursor.row != rows - 2) cursor.row += 1; // rows - 2 to keep off statusline
                },
                'k' => { // move cursor up
                    if (cursor.row != 0) cursor.row -= 1;
                },
                'l' => { // move cursor right
                    if (cursor.col != cols - 1) cursor.col += 1;
                },
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
