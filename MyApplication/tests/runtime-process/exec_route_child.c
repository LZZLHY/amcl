/* 宿主固定动作程序，不链接JVM/替身；供真实posix_spawn/wait检验正常码、信号、背压和期限。 */
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>
int main(int argc, char** argv) {
    if (argc != 2) return 99;
    struct rlimit noCore = {0, 0}; setrlimit(RLIMIT_CORE, &noCore);
    if (!strcmp(argv[1], "exit255")) return 255;
    if (!strcmp(argv[1], "sigbus")) { signal(SIGBUS, SIG_DFL); raise(SIGBUS); return 98; }
    if (!strcmp(argv[1], "hang")) { for (;;) pause(); }
    if (!strcmp(argv[1], "flood") || !strcmp(argv[1], "infinite-flood")) {
        char bytes[1024]; memset(bytes, 'x', sizeof(bytes));
        for (int n = 0; n < 100 || !strcmp(argv[1], "infinite-flood"); ++n)
            if (write(STDOUT_FILENO, bytes, sizeof(bytes)) <= 0) return 97;
        return 7;
    }
    printf("AMCL_EXEC_PROBE pid=%d ppid=%d argc=%d\n", (int)getpid(), (int)getppid(), argc);
    fflush(stdout);
    return 7;
}
