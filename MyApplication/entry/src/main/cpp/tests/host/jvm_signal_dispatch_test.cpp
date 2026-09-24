#include "../../jvm/jvm_signal_dispatch.h"
#include <cstdio>
#include <cstdlib>
#include <initializer_list>

/** 真实生产分发函数的返回值/参数矩阵，特意包含 PC 不变的合法安全点和 PC 变化的拒绝。 */
struct SignalInfo { int code; };
struct Context { int pc; };
static int result = 0, calls = 0, expectedSignal = 11;
static bool movePc = false;
static void require(bool value, const char* message) {
    if (!value) { std::fprintf(stderr, "FAIL %s\n", message); std::exit(1); }
}
static int hotspot(int signal, SignalInfo* info, void* context, int abortUnknown) {
    ++calls;
    require(signal == expectedSignal && info->code == 1, "original signal metadata changed");
    require(abortUnknown == 0, "unrecognized application fault forced through VM abort");
    if (movePc) static_cast<Context*>(context)->pc++;
    return result;
}
int main() {
    SignalInfo info{1}; Context context{7};
    for (int signal : {4, 8, 11, 7}) {
        expectedSignal = signal;
        for (int recognized : {0, 1}) for (bool change : {false, true}) {
            calls = 0; result = recognized; movePc = change;
            const bool handled = amcl::jvm::forwardSynchronousSignal(&hotspot, signal, &info, &context);
            require(handled == (recognized != 0), "PC heuristic replaced actual VM result");
            require(calls == 1, "handler was skipped or called twice");
        }
    }
    using Handler = int (*)(int, SignalInfo*, void*, int);
    calls = 0;
    require(!amcl::jvm::forwardSynchronousSignal(Handler(nullptr), 11, &info, &context), "missing handler consumed signal");
    require(!amcl::jvm::forwardSynchronousSignal(&hotspot, 11, static_cast<SignalInfo*>(nullptr), &context), "missing info consumed signal");
    require(!amcl::jvm::forwardSynchronousSignal(&hotspot, 11, &info, nullptr), "missing context consumed signal");
    require(calls == 0, "invalid envelope entered VM");
    std::puts("PASS synchronous JVM signal result, unchanged-PC safepoint, changed-PC rejection and missing-envelope controls");
}
