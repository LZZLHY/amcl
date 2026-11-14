/**
 * OHOS AArch64 的线程 CPU timer 适配，不以 SDK 缺宏推断内核缺能力。
 *
 * 固定 OpenHarmony musl 07fa503bf652dcaad71e88c9c2bcb93bdc56efc2 的
 * include/signal.h 和 src/time/timer_create.c 声明并实现 SIGEV_THREAD_ID=4，
 * tid 位于 sigev_notify 后。当前 SDK 的旧声明保留相同 64 字节 ABI，但未公开
 * 该成员名。本适配只使用公开 timer_create/pthread_getcpuclockid，复制已核对的
 * ABI 字段；运行时拒绝时原样返回失败，不能把源码存在等同设备能力通过。
 */
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <time.h>

namespace amcl_ohos {
/** 创建未启动的定向 timer；timer_settime 之前不会占用或投递目标信号。 */
inline int create_thread_cpu_timer(pthread_t thread, pid_t tid, int signal_number, timer_t* result) {
    static_assert(sizeof(struct sigevent) == 64, "unqualified OHOS sigevent size");
    static_assert(offsetof(struct sigevent, sigev_notify) == 12, "unqualified OHOS sigevent layout");
    static_assert(sizeof(pid_t) == sizeof(int32_t), "unqualified OHOS thread id");
    clockid_t clock;
    const int error = pthread_getcpuclockid(thread, &clock);
    if (error != 0) { errno = error; return -1; }
    struct sigevent event{};
    event.sigev_notify = 4; // 固定 musl/Linux ABI 的 SIGEV_THREAD_ID，局部使用，不伪造全局 SDK 宏。
    event.sigev_signo = signal_number;
    const size_t tid_offset = offsetof(struct sigevent, sigev_notify) + sizeof(event.sigev_notify);
    memcpy(reinterpret_cast<char*>(&event) + tid_offset, &tid, sizeof(tid));
    return timer_create(clock, &event, result);
}
}
