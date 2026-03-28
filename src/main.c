#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>

struct termios termios_original;

void die(const char* s) {
    perror(s);
    exit(1);
}

void disable_raw_mode() {
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &termios_original) == -1) die("tcsetattr");
}

int main() {
    // Enable raw mode. See https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html.
    if (tcgetattr(STDIN_FILENO, &termios_original) == -1) die("tcgetattr");
    atexit(disable_raw_mode);  // restore original settings on exit
    struct termios raw = termios_original;
    raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    raw.c_oflag &= ~(OPOST);
    raw.c_cflag |= (CS8);
    raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 1;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)) die("tcsetattr");

    while (1) {
        // read(STDIN_FILENO, &c, 1) == 1 && c != 'q'
        char c = '\0';
        if (read(STDIN_FILENO, &c, 1) == -1) die("read");
        if (iscntrl(c)) {
            printf("%d\r\n", c);
        } else {
            printf("%d ('%c')\r\n", c, c);
        }
        if (c == 'q') break;
    }

    return 0;
}
