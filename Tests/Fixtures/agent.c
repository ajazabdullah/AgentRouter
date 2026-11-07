// Disposable agent substitute. Reads raw terminal bytes; never executes them.
#include <unistd.h>
#include <signal.h>
#include <termios.h>
#include <stdio.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <sys/select.h>
static volatile sig_atomic_t stopping = 0;
static void stop(int s) { _exit(0); }
int main(int argc, char **argv) {
    signal(SIGTERM, access("ignore-term", F_OK) == 0 ? SIG_IGN : stop);
    struct termios old, raw;
    tcgetattr(0, &old); raw = old; cfmakeraw(&raw); tcsetattr(0, TCSANOW, &raw);
    int output = open("received.bin", O_CREAT|O_TRUNC|O_WRONLY, 0600);
    FILE *color = fopen("color-environment.txt", "w");
    if (color) { fputs(getenv("NO_COLOR") ? "disabled" : "enabled", color); fclose(color); }
    if (!getenv("NO_COLOR")) write(1, "\033[31mCOLOR\033[0m\r\n", 16);
    write(1, "\033[?2004hREADY\r\n", 15);
    while (!stopping) {
        if (access("hook.json", F_OK) == 0 && access("helper-path", F_OK) == 0) {
            FILE *path = fopen("helper-path", "r"); char helper[4096] = {0};
            fgets(helper, sizeof(helper), path); fclose(path);
            int input = open("hook.json", O_RDONLY);
            unlink("hook.json");
            pid_t child = fork();
            if (child == 0) { dup2(input, 0); close(input); execl(helper, helper, NULL); _exit(1); }
            close(input); int status; waitpid(child, &status, 0);
        }
        fd_set fds; FD_ZERO(&fds); FD_SET(0, &fds);
        struct timeval timeout = {0, 100000};
        if (select(1, &fds, NULL, NULL, &timeout) <= 0) continue;
        char b[4096]; ssize_t n = read(0, b, sizeof(b));
        if (n > 0) { write(output, b, n); fsync(output); }
        else if (n == 0) break;
    }
    write(1, "\033[?2004l", 8); tcsetattr(0, TCSANOW, &old); close(output);
    return 0;
}
