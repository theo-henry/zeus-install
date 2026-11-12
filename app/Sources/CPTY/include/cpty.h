#ifndef ZEUS_CPTY_H
#define ZEUS_CPTY_H

#include <sys/types.h>

// Starts `path` with `argv` and `envp` in a new pseudo-terminal, in the folder `cwd`.
// The child becomes a session leader with the terminal as its controlling terminal, so
// /dev/tty works in it, as in a Terminal window. Writes the master side to `master_fd`.
// Returns the child's process ID, or -1 with errno set.
pid_t zeus_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                     unsigned short rows, unsigned short cols, int *master_fd);

// Changes the size of the terminal on `master_fd`.
int zeus_pty_resize(int master_fd, unsigned short rows, unsigned short cols);

#endif
