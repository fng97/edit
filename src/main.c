#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

struct State {
    int cols;
    int rows;
    struct termios termios_original;
};

struct State state;

#define CTRL_KEY(k) ((k) & 0x1f)

void clear_screen() {
    // Clear the screen with an *escape sequence*. These start with the escape character,
    // '\x1b,' followed by a '['. '2J' clears the entire screen. We are using VT100 escape
    // sequences. See https://vt100.net/docs/vt100-ug/chapter3.html. For J (Erase In Display),
    // see https://vt100.net/docs/vt100-ug/chapter3.html#ED.
    write(STDOUT_FILENO, "\x1b[2J", 4);  // 4 because we are writing 4 bytes
    // Place the cursor at the start of the screen. For H (Cursor Position), see
    // http://vt100.net/docs/vt100-ug/chapter3.html#CUP. The default arguments 1, 1 (rows and
    // columns are indexed from 1).
    write(STDOUT_FILENO, "\x1b[H", 3);
}

// Prints the error corresponding with the current value of the global `errno`, prefixed with the
// string passed in ("{s}: {errno_message}").
void panic(const char* s) {
    clear_screen();
    perror(s);
    exit(1);
}

void disable_raw_mode() {
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &state.termios_original) == -1) panic("tcsetattr");
}

int main() {
    // Enable raw mode. See https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html.
    if (tcgetattr(STDIN_FILENO, &state.termios_original) == -1) panic("tcgetattr");
    atexit(disable_raw_mode);  // restore original settings on exit
    struct termios raw = state.termios_original;
    raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_oflag &= ~(OPOST);
    raw.c_cflag |= (CS8);
    raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 1;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)) panic("tcsetattr");

    // Get terminal screen size. If this doesn't work, try this:
    // https://viewsourcecode.org/snaptoken/kilo/03.rawInputAndOutput.html#window-size-the-hard-way
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == -1 || ws.ws_col == 0) panic("ioctl");
    state.cols = ws.ws_col;
    state.rows = ws.ws_row;

    while (1) {
        // Refresh screen.
        clear_screen();
        // Draw tildes at the start of lines that come after the end of our file.
        for (int y = 0; y < state.rows; y++) {
            write(STDOUT_FILENO, "~", 1);
            // Make sure not to write a newline after the final row. The terminal would scroll to
            // make room, removing a line we printed.
            if (y < state.rows - 1) write(STDOUT_FILENO, "\r\n", 2);
        }
        write(STDOUT_FILENO, "\x1b[H", 3);  // reposition cursor at start

        // Try read until we get a character.
        int nread = 0;
        char c;
        while ((nread = read(STDIN_FILENO, &c, 1)) != 1) {
            if (nread == -1) panic("read");
        }

        // Handle character.
        switch (c) {
            case CTRL_KEY('q'):
                clear_screen();
                exit(0);
                break;
        }
    }

    return 0;
}
