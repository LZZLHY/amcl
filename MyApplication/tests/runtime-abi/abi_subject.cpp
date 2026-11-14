/** 被测库：保留编译器生成的 guard/RTTI/EH/TLS 路径，不自行替换 ABI 函数。 */
#include "abi_contract.h"
#include <atomic>
#include <unistd.h>

namespace {
std::atomic<int> constructions{0};
std::atomic<int> attempts{0};
std::atomic<int> destructors{0};
struct Published {
    int number = 0;
    Published() {
        ++constructions;
        // 扩大发布窗口；坏 guard 会让其他线程在构造完成前读到 0。
        usleep(20000);
        number = 42;
    }
};
struct Retry {
    int number = 0;
    Retry() {
        if (++attempts == 1) {
            throw AbiError(19);
        }
        number = 61;
    }
};
struct PerThread {
    int number = 7;
    ~PerThread() { ++destructors; }
};
thread_local PerThread local;
}

extern "C" int abi_static_value() { static Published value; return value.number; }
extern "C" int abi_static_constructions() { return constructions.load(); }
extern "C" int abi_retry_value() { static Retry value; return value.number; }
extern "C" int abi_retry_attempts() { return attempts.load(); }
extern "C" void abi_throw(int code) { throw AbiError(code); }
extern "C" AbiBase* abi_create() { return new AbiDerived; }
extern "C" void abi_touch_tls() { local.number += 1; }
extern "C" int abi_tls_destructors() { return destructors.load(); }
