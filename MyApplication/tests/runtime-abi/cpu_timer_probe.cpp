/** 单独进程验证定向 CPU timer 的创建、启动、实际投递与删除，不改变宿主信号。 */
#include "../../prebuilt/jdk/25/shims/cpu_time_timer_ohos.hpp"
#include <cstdio>
#include <unistd.h>
#include <sys/syscall.h>

namespace {
volatile sig_atomic_t samples = 0;
volatile sig_atomic_t wrong_thread = 0;
pid_t expected_tid;
void sample(int, siginfo_t* info, void*) {
    if (info->si_code != SI_TIMER) return;
    if (static_cast<pid_t>(syscall(SYS_gettid)) != expected_tid) wrong_thread = 1;
    ++samples;
}
}

int main() {
    expected_tid = static_cast<pid_t>(syscall(SYS_gettid));
    timer_t timer;
    if (amcl_ohos::create_thread_cpu_timer(pthread_self(), expected_tid, SIGPROF, &timer) != 0) {
        std::printf("CPU_TIMER create failed errno=%d\n", errno);
        return 2;
    }
    struct sigaction action{}, old{};
    action.sa_sigaction = sample;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGPROF, &action, &old) != 0) { timer_delete(timer); return 3; }
    struct itimerspec period{};
    period.it_interval.tv_nsec = 1000000;
    period.it_value = period.it_interval;
    if (timer_settime(timer, 0, &period, nullptr) != 0) {
        std::printf("CPU_TIMER arm failed errno=%d\n", errno);
        timer_delete(timer);
        sigaction(SIGPROF, &old, nullptr);
        return 4;
    }
    timespec begin{}, now{};
    clock_gettime(CLOCK_MONOTONIC, &begin);
    volatile unsigned long work = 0;
    do {
        for (int i = 0; i < 10000; ++i) work += i;
        clock_gettime(CLOCK_MONOTONIC, &now);
    } while (samples < 3 && now.tv_sec - begin.tv_sec < 5);
    const int deleted = timer_delete(timer);
    // 进程即将退出；先忽略已在途的计时信号，避免把排队尾部误认作新测试失败。
    signal(SIGPROF, SIG_IGN);
    std::printf("CPU_TIMER samples=%d wrongThread=%d delete=%d\n",
                static_cast<int>(samples), static_cast<int>(wrong_thread), deleted);
    return samples >= 3 && !wrong_thread && deleted == 0 ? 0 : 5;
}
