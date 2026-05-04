//                                 ASCII TABLE
//                                 ===========
//
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
    if (termios_original) |t| std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, t) catch {};
    std.debug.defaultPanic(msg, first_trace_addr);
}
pub const panic = std.debug.FullPanic(panic_after_termios_restore);

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const stdin = std.Io.File.stdin();
    var stdin_buffer: [128]u8 = undefined; // TODO: What's a reasonable size here?
    // TODO: Later, we'll want to buffer the whole screen and flush in one go. Will need to work out
    // the maximum buffer size based on resolution and rendering.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
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
    const read_size = try std.posix.read(stdin.handle, &stdin_buffer);
    // Assert KKP mode 1 enabled: CSI ? 1 u.
    if (!std.mem.startsWith(u8, stdin_buffer[0..read_size], "\x1b[?1u"))
        return error.KittyKeyboardProtocolNotSupported;
    defer {
        writer.writeAll("\x1b[<u") catch {}; // pop KKP flags
        writer.writeAll("\x1b[2J") catch {}; // clear the screen
        writer.writeAll("\x1b[H") catch {}; // place cursor at top left
        writer.flush() catch {};
    }
    // Make sure DA1 was consumed. Read again if not yet received.
    var da1 = stdin_buffer[5..read_size]; // KKP response was 5 bytes
    if (da1.len == 0) {
        const da1_size = try std.posix.read(stdin.handle, &stdin_buffer);
        da1 = stdin_buffer[0..da1_size];
    }
    // DA1 starts with CSI ? and ends with c.
    if (!std.mem.startsWith(u8, da1, "\x1b[?") or !std.mem.endsWith(u8, da1, "c"))
        return error.InvalidDa1Response;

    try writer.writeAll("\x1b[2J"); // clear the screen
    try writer.writeAll("\x1b[H"); // place cursor at top left
    try writer.flush();

    event_loop: while (true) {
        const size = try std.posix.read(stdin.handle, &stdin_buffer);
        const bytes = stdin_buffer[0..size];
        for (bytes) |byte| if (byte == 'q') break :event_loop;
        _ = try stdout_writer.interface.write(bytes);
        try stdout_writer.interface.flush();
    }
}
