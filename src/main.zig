const std = @import("std");
const Editor = @import("Editor.zig");

const assert = std.debug.assert;

const terminal_init =
    "\x1b[?1049h" ++ // use alt screen: stores screen and cursor state and has no scrollback
    "\x1b[>1u" ++ // initialise Kitty Keyboard Protocol (KKP) mode 1 (disambiguate escape codes)
    "\x1b[?2048h"; // enable in-band resize notifications
const terminal_deinit =
    "\x1b[?2048l" ++ // disable in-band resize notifications
    "\x1b[<u" ++ // pop KKP flags
    "\x1b[?1049l"; // exit alt screen

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    // Load and process buffer.
    var args_iterator = std.process.Args.Iterator.init(init.minimal.args);
    assert(args_iterator.skip()); // first arg is executable path
    const file_name = args_iterator.next() orelse @panic("missing file path arg");
    const file_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        file_name,
        allocator,
        .limited(Editor.file_size_max),
    );
    defer allocator.free(file_bytes);

    const stdin = std.Io.File.stdin();
    var stdin_buffer: [128]u8 = undefined; // TODO: What's a reasonable size here?
    var stdin_reader = stdin.reader(io, &stdin_buffer);
    const reader: *std.Io.Reader = &stdin_reader.interface;

    // Ideally this buffer is big enough to buffer everything rendered so that flush is only ever
    // called once per render.
    const stdout_buffer = try allocator.alloc(u8, Editor.file_size_max);
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
    termios_raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    termios_raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(stdin.handle, .FLUSH, termios_raw);

    // Always restore, even if init fails.
    defer stdout.writeStreamingAll(io, terminal_deinit) catch {};
    try stdout.writeStreamingAll(io, terminal_init);

    var editor: Editor = try .init(allocator, reader, writer, file_name, file_bytes);
    defer editor.deinit(allocator);

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
            std.Io.File.stdout().writeStreamingAll(threaded.io(), terminal_deinit) catch {};
            std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, t) catch {}; // restore termios
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panic);
