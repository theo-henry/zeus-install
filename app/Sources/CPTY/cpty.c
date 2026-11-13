#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

pid_t zeus_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                     unsigned short rows, unsigned short cols, int *master_fd) {
    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_row = rows;
    size.ws_col = cols;

    int master = -1;
    // forkpty: openpty, fork, then login_tty in the child (setsid, TIOCSCTTY, dup2 onto 0, 1, 2).
    pid_t pid = forkpty(&master, NULL, NULL, &size);
    if (pid < 0) return -1;
    if (pid == 0) {
        // Child: only async-signal-safe calls until exec.
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        if (cwd != NULL && chdir(cwd) != 0) _exit(126);
        execve(path, argv, envp);
        _exit(127);
    }
    int flags = fcntl(master, F_GETFD);
    if (flags >= 0) fcntl(master, F_SETFD, flags | FD_CLOEXEC);
    int io_flags = fcntl(master, F_GETFL);
    if (io_flags >= 0) fcntl(master, F_SETFL, io_flags | O_NONBLOCK);
    *master_fd = master;
    return pid;
}

int zeus_pty_resize(int master_fd, unsigned short rows, unsigned short cols) {
    struct winsize size;
    memset(&size, 0, sizeof(size));
    size.ws_row = rows;
    size.ws_col = cols;
    return ioctl(master_fd, TIOCSWINSZ, &size);
}
