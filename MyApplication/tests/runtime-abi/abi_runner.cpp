/** 独立进程行为验收：并发 guard、失败重试、跨库异常/RTTI 和 C++ TLS 析构。 */
#include "abi_contract.h"
#include <atomic>
#include <cstdio>
#include <cstring>
#include <pthread.h>
#include <sstream>

namespace {
std::atomic<int> failures{0};
std::atomic<bool> start{false};
void* worker(void*) {
    while (!start.load(std::memory_order_acquire)) {}
    if (abi_static_value() != 42) ++failures;
    abi_touch_tls();
    return nullptr;
}
}

int main(int argc, char** argv) {
    // iostream/locale 会读取 SDK 的平台 rune 契约，覆盖 JDK jpackage 的真实输入。
    std::stringstream formatted;
    formatted << 73;
    int parsed = 0;
    formatted >> parsed;
    if (parsed != 73) ++failures;
    // 所有已创建线程都 join 后才读取析构计数；没有把“收到退出通知”当作析构完成。
    constexpr int count = 24;
    pthread_t threads[count];
    int made = 0;
    for (; made < count; ++made) {
        if (pthread_create(&threads[made], nullptr, worker, nullptr) != 0) break;
    }
    start.store(true, std::memory_order_release);
    for (int i = 0; i < made; ++i) {
        if (pthread_join(threads[i], nullptr) != 0) ++failures;
    }
    if (made != count || abi_static_constructions() != 1 || abi_tls_destructors() != count) ++failures;
    // 负控制仅替换旧 guard，隔离在另一进程；必须真实观察到未完成构造的值。
    if (argc == 2 && std::strcmp(argv[1], "--guard-only") == 0) {
        std::printf("ABI guardFailures=%d\n", failures.load());
        return failures.load() ? 1 : 0;
    }
    try {
        abi_retry_value();
        ++failures;
    } catch (const AbiError& error) {
        if (error.code != 19) ++failures;
    } catch (...) { ++failures; }
    if (abi_retry_value() != 61 || abi_retry_attempts() != 2) ++failures;
    try {
        abi_throw(37);
    } catch (const AbiError& error) {
        if (error.code != 37) ++failures;
        // 重抛也跨异常处理状态，不能用只返回 exc 的伪 begin_catch 通过。
        try { throw; } catch (const std::runtime_error& base) {
            if (base.what()[0] != 'c') ++failures;
        }
    } catch (...) { ++failures; }
    AbiBase* base = abi_create();
    AbiDerived* derived = dynamic_cast<AbiDerived*>(base);
    if (!derived || derived->value() != 73) ++failures;
    delete base;
    std::printf("ABI guard=%d retry=%d tls=%d/%d failures=%d\n",
                abi_static_constructions(), abi_retry_attempts(),
                abi_tls_destructors(), count, failures.load());
    return failures.load() ? 1 : 0;
}
