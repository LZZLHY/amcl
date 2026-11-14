/**
 * 父进程对一次真实 fork 返回 PID 的无分配所有者。异常退出必须先停止并回收 child，
 * 才能让上层结束 Promise/释放安装目录租约。只有本对象是该 child 的等待者；正常
 * wait 一旦返回目标 PID 立即解权。ECHILD 只表示等待身份已丢失，绝不能再 kill 同号PID。
 */
#pragma once
#include "processor_wait.h"
#include <cerrno>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

namespace amcl::jvm {
struct PosixChildOwnership {
    int64_t wait(int64_t pid, int* status, int flags, int* error) noexcept {
        const pid_t actual = waitpid(static_cast<pid_t>(pid), status, flags);
        *error = actual < 0 ? errno : 0; return actual;
    }
    int stop(int64_t pid) noexcept { return kill(static_cast<pid_t>(pid), SIGKILL); }
    void pause() noexcept { (void)poll(nullptr, 0, 20); }
};

template<class System = PosixChildOwnership>
class ProcessorChildOwner {
public:
    ProcessorChildOwner(int64_t pid, System& system) noexcept : pid_(pid), system_(system) {}
    ProcessorChildOwner(const ProcessorChildOwner&) = delete;
    ProcessorChildOwner& operator=(const ProcessorChildOwner&) = delete;
    ~ProcessorChildOwner() noexcept { finish(); }
    /** 必须紧跟真实 wait 返回、早于日志或状态分配；失去child身份时也停止使用数字PID。 */
    void observe(const ProcessorWaitResult& result) noexcept {
        if ((result.reaped && result.actualPid == pid_) || (!result.reaped && result.error == ECHILD)) pid_ = -1;
    }
    void finish() noexcept {
        if (pid_ <= 0) return;
        const int savedErrno = errno;
        // 非阻塞 wait 首先确认身份：已退出则直接reap，ECHILD立即解权，不发送信号。
        // 其他未知错误不代表可复用PID，也不提供可杀身份；保留所有权后重试，不能提前
        // 让Promise settle。该资源失败路径没有绝对墙钟上限，不把系统拒绝掩盖成成功。
        for (;;) {
            int status = 0, error = 0;
            const int64_t actual = system_.wait(pid_, &status, WNOHANG, &error);
            if (actual == pid_ || (actual < 0 && error == ECHILD)) { pid_ = -1; errno = savedErrno; return; }
            if (actual == 0) break;
            if (actual < 0 && error == EINTR) continue;
            system_.pause();
        }
        int stopped;
        do { stopped = system_.stop(pid_); } while (stopped < 0 && errno == EINTR);
        // kill成功/ESRCH/拒绝都不是退出证明。保持租约并等待真实终结；不调用C++日志，
        // 从而使bad_alloc回退本身不会再次分配、抛异常或绕过等待。
        for (;;) {
            int status = 0, error = 0;
            const int64_t actual = system_.wait(pid_, &status, 0, &error);
            if (actual == pid_ || (actual < 0 && error == ECHILD)) { pid_ = -1; errno = savedErrno; return; }
            if (actual < 0 && error == EINTR) continue;
            system_.pause();
        }
    }
private:
    int64_t pid_;
    System& system_;
};
} // namespace amcl::jvm
