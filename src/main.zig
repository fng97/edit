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

var termios_original: ?std.posix.termios = null;
pub fn panic_after_termios_restore(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (termios_original) |t| { // only do this once
        std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, t) catch {};
        termios_original = null;
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}
pub const panic = std.debug.FullPanic(panic_after_termios_restore);

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

    // Initialise Kitty Keyboard Protocol (KKP) with mode 1 (disambiguate escape codes) then
    // immediately query KKP flags to confirm the protocol is supported. Also request Primary Device
    // Attributes (DA1) as a fallback so we don't hang on the read if the KKP query isn't
    // recognised.
    try writer.writeAll("\x1b[>1u"); // CSI > 1 u <- enable KKP mode 1
    try writer.writeAll("\x1b[?u"); // CSI ? u <- query KKP flags
    try writer.writeAll("\x1b[c"); // CSI c <- query device attributes
    try writer.flush(); // send KKP init and queries to stdout
    // Assert KKP mode 1 enabled: CSI ? 1 u (5 bytes).
    if (!std.mem.eql(u8, try reader.take(5), "\x1b[?1u"))
        return error.KittyKeyboardProtocolNotSupported;
    defer {
        writer.writeAll("\x1b[<u") catch {}; // pop KKP flags
        writer.writeAll("\x1b[2J") catch {}; // clear the screen
        writer.writeAll("\x1b[H") catch {}; // place cursor at top left
        writer.flush() catch {};
    }
    // Make sure DA1 was consumed. DA1 starts with CSI ? and ends with c (only c in sequence).
    if (!std.mem.eql(u8, try reader.take(3), "\x1b[?")) return error.MissingDA1Response;
    _ = try reader.discardDelimiterInclusive('c');

    // Get window size.
    // TODO: Query it with CSI 18 t instead of doing ioctl.
    // try writer.writeAll("\x1b[18t"); // query window size
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = std.posix.system.ioctl(stdout.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    assert(std.posix.errno(err) == .SUCCESS);

    // Render welcome screen.
    try writer.writeAll("\x1b[2J"); // clear the screen
    try writer.writeAll("\x1b[H"); // place cursor at top left
    for (0..winsize.row - 1) |_| try writer.writeAll("~\r\n"); // start empty rows with ~
    try writer.writeAll("~"); // don't add newline on final row (otherwise scrolls to make room)
    try writer.writeAll("\x1b[H"); // place cursor at top left
    try writer.flush();

    while (true) if (try reader.takeByte() == 'q') break;
}
