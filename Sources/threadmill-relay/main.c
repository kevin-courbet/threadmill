// threadmill-relay: bridges stdin/stdout to a Unix domain socket.
// Ghostty spawns this as the surface "command". The app listens on the
// socket and relays data to/from the WebSocket connection to Spindle.
//
// Usage: THREADMILL_SOCKET=/tmp/threadmill-<id>.sock threadmill-relay

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <termios.h>
#include <unistd.h>

#define BUF_SIZE 16384

static struct termios orig_termios;
static int termios_saved = 0;

static void restore_termios(void) {
    if (termios_saved)
        tcsetattr(STDIN_FILENO, TCSANOW, &orig_termios);
}

// Put stdin into raw mode: no echo, no line buffering, no signal generation.
// Remote terminal handles all of this.
static int set_raw_mode(void) {
    if (!isatty(STDIN_FILENO))
        return 0;
    if (tcgetattr(STDIN_FILENO, &orig_termios) < 0)
        return -1;
    termios_saved = 1;
    atexit(restore_termios);

    struct termios raw = orig_termios;
    // Fully transparent PTY — remote terminal handles everything.
    // cfmakeraw equivalent, but explicit for clarity.
    raw.c_iflag &= ~(BRKINT | ICRNL | INLCR | IGNCR | INPCK | ISTRIP | IXON | IXOFF);
    raw.c_oflag &= ~(OPOST);
    raw.c_cflag &= ~(CSIZE | PARENB);
    raw.c_cflag |= CS8;
    raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    return tcsetattr(STDIN_FILENO, TCSANOW, &raw);
}

int main(void) {
    const char *sock_path = getenv("THREADMILL_SOCKET");
    if (!sock_path || !*sock_path)
        return 1;

    if (set_raw_mode() < 0) {
        fprintf(stderr, "threadmill-relay: failed to set raw mode: %s\n", strerror(errno));
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("threadmill-relay: socket");
        return 1;
    }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

    // Retry connect — the app listener may not be ready yet
    for (int attempt = 0; attempt < 50; attempt++) {
        if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0)
            goto connected;
        usleep(100000); // 100ms
    }
    fprintf(stderr, "threadmill-relay: failed to connect to %s\n", sock_path);
    close(fd);
    return 1;

connected:
    struct pollfd fds[2];
    fds[0].fd = STDIN_FILENO;
    fds[0].events = POLLIN;
    fds[1].fd = fd;
    fds[1].events = POLLIN;

    char buf[BUF_SIZE];

    for (;;) {
        int ret = poll(fds, 2, -1);
        if (ret < 0) {
            if (errno == EINTR) continue;
            break;
        }

        // stdin → socket (user keystrokes from ghostty)
        if (fds[0].revents & POLLIN) {
            ssize_t n = read(STDIN_FILENO, buf, BUF_SIZE);
            if (n <= 0) break;
            const char *p = buf;
            ssize_t remaining = n;
            while (remaining > 0) {
                ssize_t w = write(fd, p, remaining);
                if (w <= 0) goto done;
                p += w;
                remaining -= w;
            }
        }

        // socket → stdout (remote terminal output to ghostty)
        if (fds[1].revents & POLLIN) {
            ssize_t n = read(fd, buf, BUF_SIZE);
            if (n <= 0) break;
            const char *p = buf;
            ssize_t remaining = n;
            while (remaining > 0) {
                ssize_t w = write(STDOUT_FILENO, p, remaining);
                if (w <= 0) goto done;
                p += w;
                remaining -= w;
            }
        }

        if ((fds[0].revents | fds[1].revents) & (POLLHUP | POLLERR))
            break;
    }

done:
    close(fd);
    return 0;
}
