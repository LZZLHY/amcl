/** 使用真实 flock 验证 native 共享租约，与 SDK File.tryLock 的原生调用一致。 */
#include "../../entry/src/main/cpp/jvm/jdk_directory_lease.h"
#include <cassert>
#include <iostream>
#include <sys/wait.h>

int main(int argc, char** argv) {
    assert(argc == 2);
    const std::string root = argv[1];
    mkdir(root.c_str(), 0700);
    std::string error;
    int owner = -1;
    {
        amcl::jdk::DirectoryReadLease first, second;
        assert(first.acquire(root, "17", error));
        assert(second.acquire(root, "17", error));
        owner = first.releaseToProcess();
        const int writer = open((root + "/jdk/.locks/17.use").c_str(), O_RDWR);
        assert(writer >= 0 && flock(writer, LOCK_EX | LOCK_NB) != 0);
        close(writer);
    }
    // 独立进程即使关闭继承的那份 fd，也不能绕过父进程还持有的共享租约。
    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        close(owner);
        const int fd = open((root + "/jdk/.locks/17.use").c_str(), O_RDWR);
        _exit(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0 ? 0 : 1);
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    close(owner);
    const int writer = open((root + "/jdk/.locks/17.use").c_str(), O_RDWR);
    assert(flock(writer, LOCK_EX | LOCK_NB) == 0);
    amcl::jdk::DirectoryReadLease blocked;
    assert(!blocked.acquire(root, "17", error));
    close(writer);
    assert(blocked.acquire(root, "17", error));
    amcl::jdk::DirectoryReadLease invalid;
    assert(!invalid.acquire(root, "../17", error));
    std::cout << "PASS native JDK lease: shared readers, cross-process writer exclusion and retry after release\n";
}
