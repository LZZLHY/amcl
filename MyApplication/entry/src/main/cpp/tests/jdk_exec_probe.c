/* 随测试 HAP 安装的真实 PIE；验证 exec、参数、stdout 与 waitpid 的真实退出码。 */
#include <stdio.h>
#include <unistd.h>
int main(int argc, char** argv) {
    (void)argv;
    printf("AMCL_EXEC_PROBE pid=%d ppid=%d argc=%d\n", (int)getpid(), (int)getppid(), argc);
    fflush(stdout);
    return 7;
}
