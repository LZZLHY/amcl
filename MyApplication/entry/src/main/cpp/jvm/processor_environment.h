/**
 * processor 在任何 JVM/ELF 初始化前的 cwd/stdio 准备。显式请求失败立即返回原 errno；
 * 调用者必须终止该子进程，不能在继承目录或部分重定向状态继续运行 Java。
 * 只使用 POSIX 系统调用，不分配堆内存。此模块不宣称整个 fork 后启动链异步信号安全。
 */
#pragma once
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>

namespace amcl::jvm {
enum class ProcessorSetupStep { None, LogOpen, LogDescriptor, Stdout, Stderr, WorkingDirectory };
struct ProcessorSetupResult {
    ProcessorSetupStep step;
    int error;
    bool ok() const { return step == ProcessorSetupStep::None; }
};

/** 真实调用适配仅用于让测试注入指定外部失败，不在产品路径上引入虚函数或全局状态。 */
struct PosixProcessorIo {
    int openLog(const char* path) { return open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644); }
    int moveAboveStdio(int fd) { return fcntl(fd, F_DUPFD_CLOEXEC, 3); }
    int duplicate(int from, int to) { return dup2(from, to); }
    void closeFd(int fd) { close(fd); }
    int changeDirectory(const char* path) { return chdir(path); }
};

template<class System>
ProcessorSetupResult PrepareProcessorIo(const char* workDir, const char* logFile, System& system) {
    if (logFile && logFile[0]) {
        int fd;
        do { fd = system.openLog(logFile); } while (fd < 0 && errno == EINTR);
        if (fd < 0) return {ProcessorSetupStep::LogOpen, errno};
        if (fd < 3) {
            // 原 stdout/stderr 关闭时 open 可能占用其编号。移到独立 fd 后再 dup2，避免
            // dup2(fd, fd) 保留 CLOEXEC 或最终 close 把目标 stdout/stderr 一并关闭。
            int moved;
            do { moved = system.moveAboveStdio(fd); } while (moved < 0 && errno == EINTR);
            const int error = errno;
            system.closeFd(fd);
            if (moved < 0) return {ProcessorSetupStep::LogDescriptor, error};
            fd = moved;
        }
        const int destinations[] = {STDOUT_FILENO, STDERR_FILENO};
        for (const int destination : destinations) {
            int result;
            do { result = system.duplicate(fd, destination); } while (result < 0 && errno == EINTR);
            if (result < 0) {
                const int error = errno;
                system.closeFd(fd);
                return {destination == STDOUT_FILENO ? ProcessorSetupStep::Stdout : ProcessorSetupStep::Stderr, error};
            }
        }
        system.closeFd(fd);
    }
    if (workDir && workDir[0]) {
        int result;
        do { result = system.changeDirectory(workDir); } while (result < 0 && errno == EINTR);
        if (result < 0) return {ProcessorSetupStep::WorkingDirectory, errno};
    }
    return {ProcessorSetupStep::None, 0};
}

/** 错误输出使用固定栈缓冲和 write；不依赖日志线程、strerror、stdio 或动态分配。 */
inline void ReportProcessorSetupFailure(const ProcessorSetupResult& failure) {
    char message[128]; size_t length = 0;
    auto append = [&](const char* text) { while (*text && length < sizeof(message)) message[length++] = *text++; };
    auto number = [&](unsigned value) {
        char digits[16]; unsigned count = 0;
        do { digits[count++] = static_cast<char>('0' + value % 10); value /= 10; } while (value);
        while (count) message[length++] = digits[--count];
    };
    append("[FORK_JAVA] setup failed step="); number(static_cast<unsigned>(failure.step));
    append(" errno="); number(static_cast<unsigned>(failure.error)); append("; JVM not started\n");
    size_t done = 0;
    while (done < length) {
        const ssize_t count = write(STDERR_FILENO, message + done, length - done);
        if (count > 0) done += static_cast<size_t>(count);
        else if (count < 0 && errno == EINTR) continue;
        else break; // 无可写 stderr 时仍保持原准备失败；调用者按独立非零状态结束。
    }
}
}
