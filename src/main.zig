const std = @import("std");
const Editor = @import("Editor");

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
    "\x1b[?2026l" ++ // end synchronised update, in case we crashed mid-render
    "\x1b[0m" ++ // reset colours, in case we crashed mid-render
    "\x1b[?25h" ++ // show cursor
    "\x1b[?2048l" ++ // disable in-band resize notifications
    "\x1b[<u" ++ // pop KKP flags
    "\x1b[?1049l"; // exit alt screen

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

    // Restore terminal if we're killed. ISIG is off so CTRL+C etc. arrive as input, but these can
    // still be sent with kill(1).
    const termination_action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleTerminationSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESETHAND, // so the re-raise in the handler takes the default action
    };
    for ([_]std.posix.SIG{ .TERM, .INT, .HUP, .QUIT }) |sig| {
        std.posix.sigaction(sig, &termination_action, null);
    }

    // Always restore, even if init fails.
    defer stdout.writeStreamingAll(io, terminal_deinit) catch {};
    try stdout.writeStreamingAll(io, terminal_init);

    var parser: Editor.Parser = .{};
    const dimensions = switch (try Editor.Event.next(&parser, reader)) {
        .resize => |dimensions| dimensions,
        else => return error.FirstEventMustBeResize,
    };

    const col_count_max = 400;
    const row_count_max = 300;
    const buffers: Editor.Buffers = try .alloc(allocator, .{
        .file_size_max = 1 * 1024 * 1024, // 1 MiB
        .col_count_max = col_count_max,
    });
    defer buffers.free(allocator);

    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    var file_reader = file.reader(io, &.{});
    var editor: Editor = try .init(.{
        .io = io,
        .buffers = buffers,
        .file_path = file_path,
        .file_reader = &file_reader.interface,
        .writer = writer,
        .cursor_line_number = if (cursor_line_number) |cln| cln - 1 else 0,
        .cursor_line_offset = if (cursor_line_offset) |clo| clo - 1 else 0,
        .row_count = dimensions.row_count,
        .col_count = dimensions.col_count,
        .col_count_max = col_count_max,
        .row_count_max = row_count_max,
        .is_test = false,
    });
    file.close(io);

    // Do the initial render. In event loop we render on every tick.
    try editor.start();
    while (true) {
        const event = try Editor.Event.next(&parser, reader);
        if (!try editor.tick(event)) return;
    }
}

var termios_original: ?std.posix.termios = null;
// Restore terminal state when crashing. Runs only once. Writes straight to stdout rather than via
// the buffered writer so we don't flush a partial frame. Restoring termios with FLUSH discards any
// input the terminal has sent that we haven't read yet, so it doesn't end up in the shell.
fn restoreTerminalOnCrash() void {
    if (termios_original) |t| {
        termios_original = null; // so we only do this once
        var threaded: std.Io.Threaded = .init_single_threaded;
        std.Io.File.stdout().writeStreamingAll(threaded.io(), terminal_deinit) catch {};
        std.posix.tcsetattr(std.Io.File.stdin().handle, .FLUSH, t) catch {}; // restore termios
    }
}

// Wrap panic handler so that we can restore terminal state first. Calls default panic after
// cleanup. This prevents jank backtraces when we crash.
pub const panic = std.debug.FullPanic(struct {
    pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        @branchHint(.cold);
        restoreTerminalOnCrash();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panic);

// Same for segfaults (SIGSEGV, SIGILL, SIGBUS, SIGFPE), which don't go through the panic handler.
pub const debug = struct {
    pub fn handleSegfault(addr: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
        restoreTerminalOnCrash();
        std.debug.defaultHandleSegfault(addr, name, ctx);
    }
};

// Restore terminal state then re-raise so we exit with the usual status for the signal. The signal
// is blocked until the handler returns, by which point the default action has been reinstated.
fn handleTerminationSignal(sig: std.posix.SIG) callconv(.c) void {
    restoreTerminalOnCrash();
    std.posix.raise(sig) catch {};
}

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

pub const std_options: std.Options = .{
    .logFn = logFn,
    // Only enabled by default in safe builds. Enable always so we can restore the terminal.
    .enable_segfault_handler = true,
};
