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

// TODO: Add dbg()

pub fn main(init: std.process.Init) !void {
    const io = init.io;

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
    defer std.posix.tcsetattr(stdin.handle, .FLUSH, termios_original.?) catch {}; // restore on exit

    // Use alt screen: It stores screen and cursor state separately and has no scrollback. This is
    // the convention for fullscreen TUIs like vim, tmux, etc.
    try writer.writeAll("\x1b[?1049h"); // CSI ? 1049 h <- enable alt screen
    // Initialise Kitty Keyboard Protocol (KKP) with mode 1 (disambiguate escape codes) then
    // immediately query KKP flags to confirm the protocol is supported. Follow with window size
    // query. We need this anyway but used as fallback here so we don't hang on the read if the KKP
    // query isn't recognised.
    try writer.writeAll("\x1b[>1u"); // CSI > 1 u <- enable KKP mode 1
    try writer.writeAll("\x1b[?u"); // CSI ? u <- query KKP flags
    try writer.writeAll("\x1b[18t"); // CSI 18 t <- query window size
    try writer.flush();
    defer { // clean up terminal on exit -- safe to send even if KKP disabled or not in alt mode
        writer.writeAll("\x1b[<u") catch {}; // CSI < u <- pop KKP flags
        writer.writeAll("\x1b[?1049l") catch {}; // CSI ? 1049 l <- exit alt screen
        writer.writeAll("\x1b[2J") catch {}; // CSI 2 J <- clear the screen
        writer.writeAll("\x1b[H") catch {}; // CSI H <- place cursor at top left
        writer.flush() catch {};
    }
    // Assert KKP mode 1 enabled: CSI ? 1 u (5 bytes).
    if (!std.mem.eql(u8, try reader.take(5), "\x1b[?1u"))
        return error.KittyKeyboardProtocolNotSupported;
    // Read window size. Response format is CSI 8 ; <rows> ; <cols> t.
    assert(std.mem.eql(u8, try reader.take(4), "\x1b[8;"));
    const rows = try std.fmt.parseInt(u16, (try reader.takeDelimiter(';')).?, 10);
    const cols = try std.fmt.parseInt(u16, (try reader.takeDelimiter('t')).?, 10);
    _ = cols;

    // Render welcome screen.
    try writer.writeAll("\x1b[2J"); // clear the screen
    try writer.writeAll("\x1b[H"); // place cursor at top left
    for (0..rows - 1) |_| try writer.writeAll("~\r\n"); // start empty rows with ~
    try writer.writeAll("~"); // don't add newline on final row (otherwise scrolls to make room)
    try writer.writeAll("\x1b[H"); // place cursor at top left
    try writer.flush();

    while (true) if (try reader.takeByte() == 'q') break;
}

var termios_original: ?std.posix.termios = null;
/// Wrap panic handler so that we can restore terminal state first. Calls default panic after
/// cleanup. Cleanup logic runs only once.
pub const panic = std.debug.FullPanic(struct {
    pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        @branchHint(.cold);
        if (termios_original) |t| {
            // Pop KKP flags (CSI < u) and exit alt screen (CSI ? 1049 l).
            _ = std.c.write(std.Io.File.stdout().handle, "\x1b[<u\x1b[?1049l", 12);
            std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, t) catch {}; // restore termios
            termios_original = null; // so we only do this once
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panic);
