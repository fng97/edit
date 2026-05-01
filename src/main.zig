const std = @import("std");

pub fn main() !void {
    const stdin = std.Io.File.stdin();

    // Put terminal in raw mode.
    const termios_original = try std.posix.tcgetattr(stdin.handle);
    var termios_raw = termios_original;
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
    // TODO: Leave exiting with CTRL-C on until we have our own exit.
    // termios_raw.lflag.ISIG = false;
    termios_raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    termios_raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin.handle, .FLUSH, termios_raw);
    // TODO: Also do this from the panic handler.
    defer std.posix.tcsetattr(stdin.handle, .FLUSH, termios_original) catch {}; // restore on exit

    // TODO: Initialise Kitty Keyboard Protocol.
    // TODO: Pass in stdout.
    // TODO: Deinitialise Kitty Keyboard Protocol. Restore terminal state.
}
