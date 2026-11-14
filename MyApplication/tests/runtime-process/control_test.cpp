/** 生产监督核心的结果仲裁、定时信号和真实唯一 PID 回收；不启动 JVM 替身冒充 Java。 */
#include "../../entry/src/main/cpp/jvm/processor_control.h"
#include <cassert>
#include <cstdio>
#include <unistd.h>
#include <vector>

namespace {
struct FakeSystem {
    uint64_t time = 0, exitAt = 100, cancelledAt = UINT64_MAX;
    int status = 0, waits = 0, injectedWaitError = 0, signalFailure = 0;
    amcl::jvm::ProcessorControl* control = nullptr;
    std::vector<int> signals;
    int64_t wait(int64_t pid, int* result, int* error) {
        assert(pid == 42); ++waits;
        if (injectedWaitError) { *error = injectedWaitError; injectedWaitError = 0; return -1; }
        if (time >= cancelledAt) control->cancel();
        if (time >= exitAt) { *result = status; return pid; }
        return 0;
    }
    int signal(int64_t pid, int signal) {
        assert(pid == 42); signals.push_back(signal);
        if (signalFailure) { errno = signalFailure; return -1; } return 0;
    }
    uint64_t now() { return time; }
    void pause(unsigned milliseconds) { assert(milliseconds > 0 && milliseconds <= 20); time += milliseconds; }
};
pid_t sleepingChild(bool ignoreTerm, int& readyFd) {
    int ready[2]; assert(pipe(ready) == 0);
    const pid_t child = fork(); assert(child >= 0);
    if (!child) {
        close(ready[0]);
        if (ignoreTerm) assert(signal(SIGTERM, SIG_IGN) != SIG_ERR);
        const char marker = 'R'; assert(write(ready[1], &marker, 1) == 1); close(ready[1]);
        for (;;) pause();
    }
    close(ready[1]); readyFd = ready[0]; char marker; assert(read(readyFd, &marker, 1) == 1 && marker == 'R'); close(readyFd);
    return child;
}
}
int main() {
    using namespace amcl::jvm;
    { ProcessorControl control; FakeSystem system; system.control = &control; system.injectedWaitError = EINTR;
      const auto result = SuperviseProcessor(42, control, system); assert(result.waited.reaped && system.signals.empty());
      assert(control.finish(0) == 0 && !control.cancel()); }
    { ProcessorControl control; FakeSystem system; system.control = &control; system.cancelledAt = 100;
      const auto result = SuperviseProcessor(42, control, system); assert(result.waited.reaped && system.signals.empty());
      assert(control.finish(0) == ProcessorCancelled); } // 取消与exit0同时到达，已接受取消必须保持。
    { ProcessorControl control(25); FakeSystem system; system.control = &control; system.exitAt = 2100;
      const auto result = SuperviseProcessor(42, control, system);
      assert(result.waited.reaped && system.signals == std::vector<int>({SIGTERM, SIGKILL}));
      assert(control.finish(0) == ProcessorTimedOut && !control.cancel()); }
    { ProcessorControl control; FakeSystem system; system.control = &control; system.injectedWaitError = ECHILD;
      const auto result = SuperviseProcessor(42, control, system); assert(!result.waited.reaped && result.waited.error == ECHILD);
      assert(system.signals.empty()); }
    { ProcessorControl control(1); FakeSystem system; system.control = &control; system.signalFailure = EPERM;
      const auto result = SuperviseProcessor(42, control, system); assert(result.waited.reaped && result.signalError == EPERM); }
    for (bool ignoresTerm : {false, true}) {
        int descriptor = -1; const pid_t child = sleepingChild(ignoresTerm, descriptor);
        ProcessorControl control(30); PosixProcessorSupervisor system;
        const uint64_t start = system.now();
        const auto result = SuperviseProcessor(child, control, system);
        assert(result.waited.reaped && !result.signalError && WIFSIGNALED(result.waited.status));
        assert(WTERMSIG(result.waited.status) == (ignoresTerm ? SIGKILL : SIGTERM));
        assert(control.finish(0) == ProcessorTimedOut);
        int status = 0; assert(waitpid(child, &status, WNOHANG) == -1 && errno == ECHILD);
        if (ignoresTerm) assert(system.now() - start >= 2000);
    }
    { int descriptor = -1; const pid_t child = sleepingChild(false, descriptor);
      ProcessorControl control; PosixProcessorSupervisor system;
      std::thread cancel([&] { std::this_thread::sleep_for(std::chrono::milliseconds(30)); assert(control.cancel()); });
      const auto result = SuperviseProcessor(child, control, system); cancel.join();
      assert(result.waited.reaped && control.finish(0) == ProcessorCancelled); }
    puts("PASS processor control: sticky cancellation/timeout vs exit0, EINTR/ECHILD/kill failure, TERM/KILL grace, 3 real child reaps");
}
