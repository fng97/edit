const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const stdin = std.Io.File.stdin();
    var stdin_buffer: [16]u8 = undefined;
    // TODO: Later, we'll want to buffer the whole screen and flush in one go. Will need to work out
    // the maximum buffer size based on resolution and rendering.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);

    // Put terminal in raw mode. Restore original termios on exit.
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
    termios_raw.lflag.ISIG = false;
    termios_raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    termios_raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin.handle, .FLUSH, termios_raw);
    // TODO: Also do this from the panic handler.
    defer std.posix.tcsetattr(stdin.handle, .FLUSH, termios_original) catch {}; // restore on exit

    // TODO: Initialise Kitty Keyboard Protocol and defer deinit.

    event_loop: while (true) {
        const size = try std.posix.read(stdin.handle, &stdin_buffer);
        const bytes = stdin_buffer[0..size];
        for (bytes) |byte| if (byte == 'q') break :event_loop;
        _ = try stdout_writer.interface.write(bytes);
        try stdout_writer.interface.flush();
    }
}
