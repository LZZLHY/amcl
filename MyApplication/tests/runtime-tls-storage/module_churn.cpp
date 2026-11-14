/** 同一个合法module周转合同同时运行于新核心与冻结旧核心。只在持有creator时使用
 * TLS；Retire之后不读旧地址。退出码77只表示确认旧资源反例，崩溃/超时不算复现。
 */
#ifndef AMCL_TLS_STORAGE_HEADER
#define AMCL_TLS_STORAGE_HEADER "../../entry/src/main/cpp/jvm/tls_thread_storage.h"
#endif
#include AMCL_TLS_STORAGE_HEADER
#include <cassert>
#include <atomic>
#include <cstdio>
#include <thread>

int main() {
    using namespace amcl::tlsstorage;
    Coordinator owner; assert(owner.Initialize() == 0);
    std::atomic<bool> ready{false}, leave{false};
    std::thread worker([&] {
        for (unsigned cycle = 0; cycle < 64; ++cycle) {
            const int initial = 37; int error = 0;
            Module* value = owner.CreateModule(&initial, sizeof(initial), 16384, 64, error);
            assert(value && !error);
            const auto block = owner.GetBlock(value); assert(block.address && !block.error);
            assert(*static_cast<int*>(block.address) == initial);
            assert(owner.Retire(value) == 0);
        }
        ready = true;
        while (!leave.load()) std::this_thread::yield();
    });
    while (!ready.load()) std::this_thread::yield();
    const auto sample = owner.Snapshot();
    const bool oldGrowth = sample.blocks == 64 && sample.storageBytes >= 64 * 16384;
    const bool bounded = sample.blocks <= 1 && sample.modules <= 1 && sample.storageBytes < 16384;
    std::printf("MEASURE module churn: blocks=%zu modules=%zu storageBytes=%zu moduleBytes=%zu\n",
                sample.blocks, sample.modules, sample.storageBytes, sample.moduleBytes);
    leave = true; worker.join();
    // join使用户工作结束，仍依据实际Sweep观察终态；外层timeout只限定测试预算。
    while (owner.Snapshot().residentArenas) { assert(!owner.Sweep().error); std::this_thread::yield(); }
    assert(owner.Snapshot().modules == 0 && owner.Shutdown() == 0);
    if (oldGrowth) { std::puts("REPRO closed modules retain 64 complete TLS payloads on a live thread"); return 77; }
    assert(bounded);
    std::puts("PASS legal module churn keeps at most one small retired node");
}
