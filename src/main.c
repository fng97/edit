#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#define EDIT_VERSION "0.0.1"
#define CTRL_KEY(k) ((k) & 0x1f)

struct State {
    uint16_t cx;
    uint16_t cy;
    uint16_t cols;
    uint16_t rows;
    struct termios termios_original;
};

struct State state;

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

struct AppendBuffer {
    char* buf;
    uint32_t len;
};

void ab_append(struct AppendBuffer* ab, const char* s, uint32_t len) {
    // FIXME: Don't risk reallocating each time. Just use one huge buffer.
    char* new = realloc(ab->buf, ab->len + len);  // make sure we have room for new string
    if (new == NULL) panic("realloc");
    memcpy(&new[ab->len], s, len);  // append new string to end of old one
    ab->buf = new;
    ab->len += len;
}

void ab_free(struct AppendBuffer* ab) { free(ab->buf); }

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
    // Init cursor coordinates to start of screen (top left).
    state.cx = 0;
    state.cy = 0;

    while (1) {
        // Update screen: write everything to a buffer then write it to stdout in one go.
        struct AppendBuffer ab = {.buf = NULL, .len = 0};
        ab_append(&ab, "\x1b[?25l", 6);  // hide the cursor
        ab_append(&ab, "\x1b[H", 3);     // place cursor at start
        // Draw tildes at the start of lines that come after the end of our file.
        for (uint16_t y = 0; y < state.rows; y++) {
            if (y == state.rows / 3) {  // a third of the way down
                char welcome[80];
                uint8_t len = snprintf(welcome, sizeof(welcome), "Edit v%s", EDIT_VERSION);
                if (len > state.cols) len = state.cols;
                uint16_t padding = (state.cols - len) / 2;
                if (padding) {
                    ab_append(&ab, "~", 1);
                    padding--;
                }
                while (padding--) ab_append(&ab, " ", 1);
                ab_append(&ab, welcome, len);
            } else {
                ab_append(&ab, "~", 1);
            }
            // Clear the rest of the line (rather than clearing the whole screen in one go above).
            ab_append(&ab, "\x1b[K", 3);
            // Make sure not to write a newline after the final row. The terminal would scroll to
            // make room, removing a line we printed.
            if (y < state.rows - 1) ab_append(&ab, "\r\n", 2);
        }
        // Position cursor.
        char buf[32];
        snprintf(buf, sizeof(buf), "\x1b[%d;%dH", state.cy + 1, state.cx + 1);
        ab_append(&ab, buf, strlen(buf));
        ab_append(&ab, "\x1b[?25h", 6);  // unhide the cursor
        // Write the buffer to update the screen.
        write(STDOUT_FILENO, ab.buf, ab.len);
        ab_free(&ab);

        // Try read until we get a character.
        int32_t nread = 0;
        char c;
        while ((nread = read(STDIN_FILENO, &c, 1)) != 1) {
            if (nread == -1) panic("read");
        }

        // Handle escape sequences.
        if (c == '\x1b') {
            char seq[3];
            // Try read the escape sequence.
            if ((read(STDIN_FILENO, &seq[0], 1) == 1) && (read(STDIN_FILENO, &seq[1], 1) == 1) &&
                (seq[0] == '[')) {
                switch (seq[1]) {
                    case 'A':
                        state.cy--;
                        continue;
                    case 'B':
                        state.cy++;
                        continue;
                    case 'C':
                        state.cx++;
                        continue;
                    case 'D':
                        state.cx--;
                        continue;
                }
            }
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
