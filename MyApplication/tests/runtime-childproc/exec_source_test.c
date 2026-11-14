/* 将完整锁定childproc.c编入同一TU，覆盖25的static入口；只替换最后的exec系统边界。
 * 测试在宿主父侧运行，验证实际源函数的路径/环境/argv/errno，而不是重写同一算法测试副本。
 * 原源对照明确观察到execvp调用；候选要求0次execvp与environ地址/内容不变。
 */
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#define execve amcl_test_execve
#define execvp amcl_test_execvp
#include "childproc.c"
#undef execve
#undef execvp

struct Expected {
    const char* program;
    int error;
    int shell;
};
static struct Expected expected[4];
static unsigned count, position, execvp_calls;
static const char* const* expected_environment;
static char** initial_environment;
static const char* original_argv0;
static unsigned cases;

/* exec仅在此替换，所有PATH/ENOEXEC行为都由真实固定源码决定。 */
int amcl_test_execve(const char* file, char* const argv[], char* const envp[]) {
    assert(position < count);
    const struct Expected* next = &expected[position++];
    assert(strcmp(file, next->program) == 0);
    assert((const void*)envp == (const void*)expected_environment);
    assert(environ == initial_environment);
    if (next->shell) {
        assert(strcmp(argv[0], "/bin/sh") == 0);
        assert(strcmp(argv[1], expected[position - 2].program) == 0);
        assert(strcmp(argv[2], "argument-\xe4\xb8\xad\xe6\x96\x87") == 0 && argv[3] == NULL);
    } else {
        assert(argv[0] == original_argv0);
        assert(strcmp(argv[1], "argument-\xe4\xb8\xad\xe6\x96\x87") == 0 && argv[2] == NULL);
    }
    errno = next->error;
    return -1;
}
int amcl_test_execvp(const char* file, char* const argv[]) {
    (void)file; (void)argv;
    ++execvp_calls;
    errno = ENOENT;
    return -1;
}
static void begin(const char* const envp[]) {
    memset(expected, 0, sizeof(expected));
    count = position = execvp_calls = 0;
    initial_environment = environ;
    expected_environment = envp ? envp : (const char* const*)environ;
}
static void add(const char* program, int error, int shell) {
    assert(count < 4);
    expected[count++] = (struct Expected){program, error, shell};
}
static void check(int mode, const char* file, const char* const envp[], int error) {
    const char* argv[4] = {file, "argument-\xe4\xb8\xad\xe6\x96\x87", NULL, NULL};
    original_argv0 = file;
    errno = 0;
    JDK_execvpe(mode, file, argv, envp);
    assert(errno == error);
    assert(position == count && execvp_calls == 0 && environ == initial_environment);
    assert(argv[0] == file && argv[2] == NULL);
    ++cases;
}
int main(void) {
#ifdef AMCL_EXPECT_ORIGINAL
    /* 非活动原源证明空env确实调用execvp，不把候选实现的0次调用当作原本已有能力。 */
    const char* argv[4] = {"/fixed/missing", "arg", NULL, NULL};
    begin(NULL);
    JDK_execvpe(MODE_FORK, argv[0], argv, NULL);
    assert(execvp_calls == 1 && position == 0 && errno == ENOENT);
    puts("PASS original source control: inherited env invokes execvp");
    return 0;
#else
    const char* envp[] = {"PATH=/child/path/is/not/search", "AMCL_VALUE=unicode-\xe4\xb8\xad", NULL};
    const char* paths[] = {"/first/", "/second", NULL};
    parentPathv = paths;
    const int modes[] = {MODE_FORK, MODE_POSIX_SPAWN, MODE_VFORK};
    for (unsigned i = 0; i < sizeof(modes) / sizeof(modes[0]); ++i) {
        const int mode = modes[i];
        begin(envp); add("/absolute/tool", ENOENT, 0);
        check(mode, "/absolute/tool", envp, ENOENT);
        begin(NULL); add("/absolute/tool", ENOENT, 0);
        check(mode, "/absolute/tool", NULL, ENOENT);
        begin((const char* const*)environ); add("/absolute/tool", ENOENT, 0);
        check(mode, "/absolute/tool", (const char* const*)environ, ENOENT);
        begin(envp); add("/first/tool", ENOENT, 0); add("/second/tool", ENOENT, 0);
        check(mode, "tool", envp, ENOENT);
        begin(NULL); add("/first/tool", EACCES, 0); add("/second/tool", ENOENT, 0);
        check(mode, "tool", NULL, EACCES);
        begin(envp); add("/first/tool", EIO, 0);
        check(mode, "tool", envp, EIO);
        begin(envp); check(mode, "", envp, ENOENT);
        begin(envp); add("./relative/tool", ENOENT, 0);
        check(mode, "./relative/tool", envp, ENOENT);
        begin(envp); add("/script", ENOEXEC, 0); add("/bin/sh", EACCES, 1);
        check(mode, "/script", envp, EACCES);
        begin(NULL); add("/first/script", ENOEXEC, 0); add("/bin/sh", EIO, 1);
        check(mode, "script", NULL, EIO);
    }
    /* effectivePathv在fork前把空PATH组件转为"."；这里消费其真实约定，不另造PATH解析器。 */
    const char* current_paths[] = {".", NULL};
    parentPathv = current_paths;
    begin(envp); add("./tool", ENOENT, 0);
    check(MODE_FORK, "tool", envp, ENOENT);
    char long_path[PATH_MAX + 16];
    memset(long_path, 'p', sizeof(long_path) - 1); long_path[sizeof(long_path) - 1] = '\0';
    const char* long_paths[] = {long_path, "/second", NULL};
    parentPathv = long_paths;
    begin(envp); add("/second/tool", ENOENT, 0);
    check(MODE_FORK, "tool", envp, ENOENT);
    printf("PASS candidate source: %u exec/PATH/env/ENOEXEC/errno cases, no execvp or environ mutation\n", cases);
    return 0;
#endif
}
