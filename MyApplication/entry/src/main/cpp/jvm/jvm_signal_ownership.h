/**
 * HotSpot 同步异常入口的最小普通 disposition 归一。只查询 SIGSEGV/BUS/ILL/FPE，
 * 仅把实际 SIG_IGN 改为 SIG_DFL；合法自定义普通 handler 保持由 HotSpot 正常保存/链回。
 * SIGABRT 诊断通过 OHOS 特殊链旁观，其他信号由平台、应用或 JVM 自己的安装协议管理。
 * 修改前先保存四项，失败则尝试恢复已改变项并同时报告恢复错误，绝不默默继续建 VM。
 */
#pragma once
#include <cerrno>
#include <signal.h>

namespace amcl::jvm {
struct SignalOwnershipResult {
    int signal = 0;
    int error = 0;
    int rollbackError = 0;
    bool ok() const { return error == 0; }
};
struct PosixSignalActions {
    int action(int signal, const struct sigaction* next, struct sigaction* previous) {
        return sigaction(signal, next, previous);
    }
};
template<class System>
SignalOwnershipResult NormalizeIgnoredJvmSignals(System& system) {
    const int signals[]{SIGSEGV, SIGBUS, SIGILL, SIGFPE};
    struct sigaction original[4]{};
    struct sigaction clean{};
    if (sigemptyset(&clean.sa_mask) != 0) return {0, errno, 0};
    clean.sa_handler = SIG_DFL;
    for (unsigned index = 0; index < 4; ++index) {
        if (system.action(signals[index], nullptr, &original[index]) != 0) return {signals[index], errno, 0};
    }
    for (unsigned index = 0; index < 4; ++index) {
        if (original[index].sa_handler != SIG_IGN) continue;
        if (system.action(signals[index], &clean, nullptr) == 0) continue;
        SignalOwnershipResult result{signals[index], errno, 0};
        while (index > 0) {
            --index;
            if (original[index].sa_handler != SIG_IGN) continue;
            if (system.action(signals[index], &original[index], nullptr) != 0 && !result.rollbackError) result.rollbackError = errno;
        }
        return result;
    }
    return {};
}
} // namespace amcl::jvm
