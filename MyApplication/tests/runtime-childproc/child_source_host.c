/* 四代完整候选childProcess的真实fork/exec/wait回归。
 * 所有路径/环境/argv/管道在fork前准备；child只调用已核C路径，不运行JVM。
 * 故障入口只向固定/proc打开动作返回EACCES，检验失败管道确实阻止exec。
 */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static int inject_cleanup_failure;
static long fd_syscall(long number, ...);
#define AMCL_CHILD_FD_SYSCALL fd_syscall
#include "childproc.c"

/* 不替换正常kernel结果；只在明确负例的openat返回固定失败，且无堆/锁/stdio。 */
static long fd_syscall(long number, ...) {
    va_list args;
    va_start(args, number);
    long result;
    if (number == SYS_openat) {
        long directory = va_arg(args, long);
        const char* path = va_arg(args, const char*);
        long flags = va_arg(args, long), mode = va_arg(args, long);
        if (inject_cleanup_failure) { errno = EACCES; result = -1; }
        else result = syscall(number, directory, path, flags, mode);
    } else if (number == SYS_getdents64) {
        long directory = va_arg(args, long);
        unsigned char* data = va_arg(args, unsigned char*);
        size_t size = va_arg(args, size_t);
        result = syscall(number, directory, data, size);
    } else if (number == SYS_close) {
        result = syscall(number, va_arg(args, long));
    } else {
        // 固定候选必须DENTS_ONLY；若未来误接close_range，直接显式失败而非继续。
        errno = ENOSYS;
        result = -1;
    }
    va_end(args);
    return result;
}

static long long milliseconds(void) {
    struct timespec now;
    assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}
static void save_file(const char* path, const char* bytes, mode_t mode) {
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY, mode);
    assert(fd >= 0);
    size_t size = strlen(bytes);
    assert(write(fd, bytes, size) == (ssize_t)size);
    assert(close(fd) == 0);
}

/* 跑一个固定源输入并完整回收。exec成功由failpipe EOF+真实payload/wait共同证明，
 * exec失败必须收到原errno，不能用child退出255混淆System.exit(255)等正常状态。
 */
static void run_case(const char* label, const char* program, const char* cwd, const char* const* environment,
                     int wanted_exit, int wanted_errno, const char* expected_output, int cleanup_failure) {
    int fails[2], output[2];
    assert(pipe2(fails, O_CLOEXEC) == 0 && pipe2(output, O_CLOEXEC) == 0);
    const char* arguments[6] = {program, "--payload", "argument-\xe4\xb8\xad\xe6\x96\x87",
                               wanted_exit == 255 ? "255" : "7", NULL, NULL};
    ChildStuff setup;
    memset(&setup, 0, sizeof(setup));
    setup.in[0] = setup.in[1] = setup.out[0] = setup.out[1] = -1;
    setup.err[0] = setup.err[1] = setup.childenv[0] = setup.childenv[1] = -1;
    setup.fail[0] = fails[0]; setup.fail[1] = fails[1];
    setup.fds[0] = 0; setup.fds[1] = output[1]; setup.fds[2] = 2;
    setup.mode = MODE_FORK; setup.argv = arguments;
    setup.envv = (const char**)environment; setup.pdir = cwd;
    inject_cleanup_failure = cleanup_failure;
    const pid_t owner = getpid();
    const pid_t child = fork();
    if (child == 0) {
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != owner) _exit(90);
        childProcess(&setup);
        _exit(91);
    }
    assert(child > 0);
    assert(close(fails[1]) == 0 && close(output[1]) == 0);
    assert(fcntl(fails[0], F_SETFL, O_NONBLOCK) == 0 && fcntl(output[0], F_SETFL, O_NONBLOCK) == 0);
    unsigned char error_bytes[sizeof(int)] = {0};
    size_t error_size = 0, output_size = 0;
    char received[8192] = {0};
    int status = 0;
    long long deadline = milliseconds() + 5000;
    for (;;) {
        if (error_size < sizeof(int)) {
            ssize_t count = read(fails[0], error_bytes + error_size, sizeof(int) - error_size);
            if (count > 0) error_size += (size_t)count;
        }
        if (output_size < sizeof(received) - 1) {
            ssize_t count = read(output[0], received + output_size, sizeof(received) - 1 - output_size);
            if (count > 0) output_size += (size_t)count;
        }
        pid_t done = waitpid(child, &status, WNOHANG);
        if (done == child) break;
        assert(done == 0 || (done < 0 && errno == EINTR));
        if (milliseconds() >= deadline) {
            kill(child, SIGKILL);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            assert(!"owned source child deadline exceeded after reap");
        }
        struct pollfd pending[2] = {{fails[0], POLLIN, 0}, {output[0], POLLIN, 0}};
        poll(pending, 2, 5);
    }
    // 补读最后一次wait之间到达的数据；退出已回收，不存在写者。
    ssize_t more;
    if (error_size < sizeof(int) &&
        (more = read(fails[0], error_bytes + error_size, sizeof(int) - error_size)) > 0) error_size += (size_t)more;
    while (output_size < sizeof(received) - 1 &&
        (more = read(output[0], received + output_size, sizeof(received) - 1 - output_size)) > 0) output_size += (size_t)more;
    assert(close(fails[0]) == 0 && close(output[0]) == 0);
    int actual_errno = 0;
    if (error_size == sizeof(int)) memcpy(&actual_errno, error_bytes, sizeof(int));
    assert(error_size == (wanted_errno ? sizeof(int) : 0));
    assert(actual_errno == wanted_errno && WIFEXITED(status) && WEXITSTATUS(status) == wanted_exit);
    assert(strcmp(received, expected_output) == 0);
    printf("PASS source child %-20s wait=%d errno=%d outputBytes=%zu\n", label, WEXITSTATUS(status), actual_errno, output_size);
}
int main(int argc, char** argv) {
    if (argc == 4 && strcmp(argv[1], "--payload") == 0) {
        // 已经exec到全新宿主映像，普通libc调用在这里合法；验证childProcess交付的实际内容。
        char cwd[4096];
        assert(getcwd(cwd, sizeof(cwd)));
        assert(strcmp(argv[2], "argument-\xe4\xb8\xad\xe6\x96\x87") == 0);
        assert(fcntl(4096, F_GETFD) == -1 && errno == EBADF);
        printf("%s|%s|%s", argv[2], getenv("AMCL_VALUE"), cwd);
        return atoi(argv[3]);
    }
    assert(argc == 2);
    char executable[4096], working[4096], script[4096], denied[4096], expected_output[8192];
    assert(realpath(argv[0], executable));
    assert(snprintf(working, sizeof(working), "%s/source-work", argv[1]) > 0);
    assert(mkdir(working, 0700) == 0);
    assert(snprintf(script, sizeof(script), "%s/plain-script", working) > 0);
    assert(snprintf(denied, sizeof(denied), "%s/denied", working) > 0);
    save_file(script, "printf 'script:%s' \"$AMCL_VALUE\"\nexit 7\n", 0700);
    save_file(denied, "unused", 0600);
    const char* payload_name = strrchr(executable, '/') + 1;
    char parent_directory[4096];
    strcpy(parent_directory, executable); *strrchr(parent_directory, '/') = '\0';
    const char* paths[] = {"/definitely/missing-amcl", parent_directory, NULL};
    parentPathv = paths;
    assert(setenv("AMCL_VALUE", "inherited", 1) == 0);
    const char* custom[] = {"AMCL_VALUE=custom-\xe4\xb8\xad\xe6\x96\x87", "PATH=/not/the/parent/search/path", NULL};
    int base = open("/dev/null", O_RDONLY);
    assert(base >= 0);
    assert(fcntl(base, F_DUPFD, 4096) == 4096); // 故意非CLOEXEC，证明由child清理，不借exec自动关闭。
    assert(snprintf(expected_output, sizeof(expected_output), "argument-\xe4\xb8\xad\xe6\x96\x87|inherited|%s", working) > 0);
    run_case("absolute-inherited", executable, working, NULL, 7, 0, expected_output, 0);
    assert(snprintf(expected_output, sizeof(expected_output), "argument-\xe4\xb8\xad\xe6\x96\x87|custom-\xe4\xb8\xad\xe6\x96\x87|%s", working) > 0);
    run_case("parent-PATH-custom-env", payload_name, working, custom, 255, 0, expected_output, 0);
    run_case("ENOEXEC-plain-script", script, working, custom, 7, 0, "script:custom-\xe4\xb8\xad\xe6\x96\x87", 0);
    run_case("missing-program", "/definitely/missing-amcl/executable", working, custom, 255, ENOENT, "", 0);
    run_case("bad-cwd", executable, "/definitely/missing-amcl/cwd", custom, 255, ENOENT, "", 0);
    run_case("denied-program", denied, working, custom, 255, EACCES, "", 0);
    run_case("FD-cleanup-failure", executable, working, custom, 255, EACCES, "", 1);
    assert(fcntl(4096, F_GETFD) >= 0 && close(4096) == 0 && close(base) == 0);
    assert(strcmp(getenv("AMCL_VALUE"), "inherited") == 0);
    puts("PASS complete candidate childProcess: 7 actual fork/exec/wait cases; parent FD/env unchanged");
}
