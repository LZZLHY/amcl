/**
 * 独立 processor 的取消/超时仲裁与唯一父等待者监督。取消被接受后保持终态原因，
 * 不能被随后观察到的 exit0 覆盖。监督只处理本次 fork 得到且尚未 reap 的精确 PID；
 * 不给已回收/未知 PID 发信号，不触碰同应用其他任务。此层不宣称管理任意自行脱离的
 * 孙进程，也不把现有 fork 路线改称干净 exec；完整进程树/CLI 资格另行验证。
 */
#pragma once
#include "processor_wait.h"
#include <atomic>
#include <chrono>
#include <cstdint>
#include <signal.h>
#include <sys/wait.h>
#include <thread>

namespace amcl::jvm {
constexpr int ProcessorCancelled = -10001;
constexpr int ProcessorTimedOut = -10002;

class ProcessorControl {
public:
    enum State : unsigned { Active, Cancelled, TimedOut, Completed };
    explicit ProcessorControl(uint64_t timeoutMs = 0) : timeoutMs_(timeoutMs) {}
    /** 只有仍在执行/排队的任务可接受取消；已完成和重复取消返回 false。 */
    bool cancel() { unsigned expected = Active; return state_.compare_exchange_strong(expected, Cancelled, std::memory_order_acq_rel); }
    void timeout() { unsigned expected = Active; state_.compare_exchange_strong(expected, TimedOut, std::memory_order_acq_rel); }
    bool stopping() const { const unsigned state = state_.load(std::memory_order_acquire); return state == Cancelled || state == TimedOut; }
    uint64_t timeoutMs() const { return timeoutMs_; }
    /** 完成和取消通过同一 CAS 线性化，返回数值与真实 wait 解码值分开。 */
    int finish(int processResult) {
        unsigned expected = Active;
        if (state_.compare_exchange_strong(expected, Completed, std::memory_order_acq_rel)) return processResult;
        return expected == Cancelled ? ProcessorCancelled : expected == TimedOut ? ProcessorTimedOut : processResult;
    }
private:
    const uint64_t timeoutMs_;
    std::atomic<unsigned> state_{Active};
};

struct ProcessorSupervisionResult {
    ProcessorWaitResult waited;
    int signalError = 0; // 第一项实际 kill 错误，用于报告，不冒充已成功终止。
};

/** 真系统适配没有虚函数，测试只替换 syscall/时钟外部边界。 */
struct PosixProcessorSupervisor {
    int64_t wait(int64_t pid, int* status, int* error) {
        const pid_t actual = waitpid(static_cast<pid_t>(pid), status, WNOHANG);
        *error = actual < 0 ? errno : 0; return actual;
    }
    int signal(int64_t pid, int signal) { return kill(static_cast<pid_t>(pid), signal); }
    uint64_t now() {
        return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
    }
    void pause(unsigned milliseconds) { std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds)); }
};

/**
 * 先验证实际 wait，再决定是否发送终止信号。默认每 20ms 唤醒，只有用户显式选择
 * requestId/timeout 的任务使用此监督；旧 8 参数调用仍使用原阻塞 waitpid。
 * TERM 的 2s 宽限给 JVM 正常 shutdown 机会，之后最多一次 KILL；发信号后继续真实
 * wait，不把 kill 返回0当成退出。OS 拒绝信号或调度停滞时没有绝对墙钟完成保证。
 */
template<class System>
ProcessorSupervisionResult SuperviseProcessor(int64_t pid, ProcessorControl& control, System& system) {
    if (pid <= 0) return {{false, 0, EINVAL, -1}, 0};
    const uint64_t started = system.now();
    uint64_t stoppingSince = 0;
    bool sentTerm = false, sentKill = false;
    int signalError = 0;
    for (;;) {
        int status = 0, error = 0;
        const int64_t actual = system.wait(pid, &status, &error);
        if (actual == pid) return {{true, status, 0, actual}, signalError};
        if (actual == -1 && error == EINTR) continue;
        if (actual != 0) return {{false, 0, actual == -1 ? (error ? error : EIO) : ECHILD, actual}, signalError};
        const uint64_t now = system.now();
        if (control.timeoutMs() && now - started >= control.timeoutMs()) control.timeout();
        if (control.stopping() && !sentTerm) {
            stoppingSince = now; sentTerm = true;
            if (system.signal(pid, SIGTERM) != 0 && !signalError) signalError = errno;
        }
        if (sentTerm && !sentKill && now - stoppingSince >= 2000) {
            sentKill = true;
            if (system.signal(pid, SIGKILL) != 0 && !signalError) signalError = errno;
        }
        unsigned pause = 20;
        if (!sentTerm && control.timeoutMs() && now - started < control.timeoutMs()) {
            const uint64_t remaining = control.timeoutMs() - (now - started);
            if (remaining < pause) pause = static_cast<unsigned>(remaining);
        }
        system.pause(pause);
    }
}
} // namespace amcl::jvm
