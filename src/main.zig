const std = @import("std");
const Editor = @import("Editor.zig");

const assert = std.debug.assert;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    // Load and process buffer.
    var args_iterator = std.process.Args.Iterator.init(init.minimal.args);
    assert(args_iterator.skip()); // first arg is executable path
    const file_name = args_iterator.next() orelse @panic("Missing file path arg");
    const file_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        file_name,
        allocator,
        .limited(1 * 1024 * 1024), // 1 MiB
    );
    defer allocator.free(file_bytes);

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

    // TODO: Get rid of this? Expect to get the dimensions on first pass of loop below.
    // Get window size using ioctl. Future resizing relies on in-band resize notifications (escape
    // sequences).
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = std.posix.system.ioctl(stdout.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    assert(std.posix.errno(err) == .SUCCESS);

    var editor: Editor = try .init(
        allocator,
        reader,
        writer,
        file_name,
        file_bytes,
        winsize.row,
        winsize.col,
        .{ .file_lines_max = 1024 * 10 },
    );
    defer editor.deinit();

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
            std.Io.File.stdout().writeStreamingAll(
                threaded.io(),
                "\x1b[<u\x1b[?2048l\x1b[?1049l",
            ) catch {};
            std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, t) catch {}; // restore termios
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panic);
