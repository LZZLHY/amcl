/** 生产 processor 准备核心的失败注入与真实 fork/stdio/cwd 验证；全部文件由调用者指定在仓外。 */
#include "../../entry/src/main/cpp/jvm/processor_environment.h"
#include <cassert>
#include <cstdio>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>

using amcl::jvm::ProcessorSetupStep;
struct FakeSystem {
    ProcessorSetupStep failure = ProcessorSetupStep::None;
    int fd = 4, closes = 0, duplicates = 0, directories = 0, interrupts = 0;
    int openLog(const char*) {
        if (interrupts) { --interrupts; errno = EINTR; return -1; }
        if (failure == ProcessorSetupStep::LogOpen) { errno = EACCES; return -1; }
        return fd;
    }
    int moveAboveStdio(int) {
        if (failure == ProcessorSetupStep::LogDescriptor) { errno = EMFILE; return -1; }
        return 4;
    }
    int duplicate(int source, int destination) {
        assert(source >= 3); ++duplicates;
        if ((failure == ProcessorSetupStep::Stdout && destination == 1) ||
            (failure == ProcessorSetupStep::Stderr && destination == 2)) { errno = EBADF; return -1; }
        return destination;
    }
    void closeFd(int) { ++closes; errno = EIO; } // 刻意改变 errno，验证失败保存发生在清理之前。
    int changeDirectory(const char*) {
        ++directories;
        if (failure == ProcessorSetupStep::WorkingDirectory) { errno = ENOENT; return -1; }
        return 0;
    }
};

/** 只在真实子进程调用，父侧自身的 cwd/stdio 完全不动；明确等待本次创建的 PID。 */
void realCase(const std::string& root, const std::string& name, int closed, bool badCwd, bool badLog) {
    const std::string directory = root + "/" + name;
    assert(mkdir(directory.c_str(), 0700) == 0);
    const std::string log = directory + (badLog ? "/missing/subdir/log" : "/output.log");
    const std::string cwd = directory + (badCwd ? "/missing" : "");
    const pid_t child = fork(); assert(child >= 0);
    if (child == 0) {
        if (closed >= 0) close(closed);
        amcl::jvm::PosixProcessorIo system;
        const auto result = amcl::jvm::PrepareProcessorIo(cwd.c_str(), log.c_str(), system);
        if (!result.ok()) { amcl::jvm::ReportProcessorSetupFailure(result); _exit(78); }
        if ((fcntl(1, F_GETFD) & FD_CLOEXEC) || (fcntl(2, F_GETFD) & FD_CLOEXEC)) _exit(90);
        const int marker = open("java-must-not-run-on-failure", O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (marker < 0) _exit(91);
        close(marker);
        if (write(1, "OUT\n", 4) != 4 || write(2, "ERR\n", 4) != 4) _exit(92);
        _exit(0);
    }
    int status = 0; assert(waitpid(child, &status, 0) == child && WIFEXITED(status));
    assert(WEXITSTATUS(status) == (badCwd || badLog ? 78 : 0));
    const bool marker = access((directory + "/java-must-not-run-on-failure").c_str(), F_OK) == 0;
    assert(marker == !(badCwd || badLog));
    if (!badCwd && !badLog) {
        std::ifstream file(log); const std::string text{std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
        assert(text == "OUT\nERR\n");
    }
}

int main(int argc, char** argv) {
    assert(argc == 2); const std::string root(argv[1]); assert(mkdir(root.c_str(), 0700) == 0);
    for (const auto step : {ProcessorSetupStep::LogOpen, ProcessorSetupStep::LogDescriptor,
            ProcessorSetupStep::Stdout, ProcessorSetupStep::Stderr, ProcessorSetupStep::WorkingDirectory}) {
        FakeSystem system; system.failure = step; system.fd = step == ProcessorSetupStep::LogDescriptor ? 1 : 4;
        const auto result = amcl::jvm::PrepareProcessorIo("cwd", "log", system);
        const int expected = step == ProcessorSetupStep::LogOpen ? EACCES :
            step == ProcessorSetupStep::LogDescriptor ? EMFILE : step == ProcessorSetupStep::WorkingDirectory ? ENOENT : EBADF;
        assert(result.step == step && result.error == expected && !result.ok());
        assert(system.closes == (step == ProcessorSetupStep::LogOpen ? 0 : 1));
        assert(system.directories == (step == ProcessorSetupStep::WorkingDirectory ? 1 : 0));
    }
    { FakeSystem system; system.interrupts = 2;
      assert(amcl::jvm::PrepareProcessorIo("cwd", "log", system).ok()); assert(system.duplicates == 2 && system.closes == 1); }
    { FakeSystem system;
      assert(amcl::jvm::PrepareProcessorIo(nullptr, nullptr, system).ok()); assert(!system.closes && !system.directories); }
    realCase(root, "中文 空格", -1, false, false);
    realCase(root, "closed-stdin", 0, false, false);
    realCase(root, "closed-stdout", 1, false, false);
    realCase(root, "closed-stderr", 2, false, false);
    realCase(root, "invalid-cwd", -1, true, false);
    realCase(root, "invalid-log", -1, false, true);
    std::puts("PASS processor setup: 5 exact failures, EINTR, optional paths, 6 real children; no marker on failure");
}
