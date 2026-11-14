/**
 * 对锁定上游的真实 DwarfFDECache 注入扩容分配失败，验证旧表未损、错误可返回、
 * 后续重试与并发/反复登记注销可用。此测试不把伪造的条目当作有效 FDE 去展开。
 */
#include <cassert>
#include <cstdlib>
#include <cstdio>
#include <thread>
#include <vector>
#include <atomic>
#include <stdlib.h>
#include "config.h"
#include "libunwind_ext.h"
static std::atomic<bool> failCacheAllocation{false};
static std::atomic<unsigned> cacheAllocations{0};
static void* cache_malloc(size_t size) {
    ++cacheAllocations;
    return failCacheAllocation.load() ? nullptr : std::malloc(size);
}
// 只替换源头模板中的 malloc，线程/测试设施使用正常分配；没有产品故障注入开关。
#define malloc cache_malloc
#include "UnwindCursor.hpp"
#undef malloc
using Cache = libunwind::DwarfFDECache<libunwind::LocalAddressSpace>;

int main() {
    for (uintptr_t i = 0; i < 64; ++i) Cache::add(1, 1000 + i * 2, 1001 + i * 2, 2000 + i);
    assert(cacheAllocations == 0);
    failCacheAllocation = true;
#ifdef AMCL_OLD_UNWIND
    // 旧版必须在这次确定的 malloc(NULL) 后触发 ASan 的 null memcpy，而非超时或任意崩溃。
    Cache::add(2, 5000, 5001, 6000);
    std::puts("FAIL old cache unexpectedly survived NULL allocation");
    return 2;
#else
    assert(Cache::add(2, 5000, 5001, 6000) == UNW_ENOMEM);
    assert(Cache::findFDE(2, 5000) == 0);
    for (uintptr_t i = 0; i < 64; ++i) assert(Cache::findFDE(1, 1000 + i * 2) == 2000 + i);
    failCacheAllocation = false;
    assert(Cache::add(2, 5000, 5001, 6000) == UNW_ESUCCESS);
    assert(Cache::findFDE(2, 5000) == 6000);
    assert(Cache::removeAllIn(1) == UNW_ESUCCESS);
    assert(Cache::removeAllIn(2) == UNW_ESUCCESS);
    const unsigned warmed = cacheAllocations;
    for (int round = 0; round < 1000; ++round) {
        for (uintptr_t i = 0; i < 200; ++i) assert(Cache::add(3, i * 2, i * 2 + 1, i + 1) == 0);
        assert(Cache::removeAllIn(3) == 0);
    }
    assert(cacheAllocations == warmed); // 顺序 churn 不随历史次数增长缓存。
    std::vector<std::thread> workers;
    for (uintptr_t group = 10; group < 18; ++group) workers.emplace_back([group] {
        for (uintptr_t i = 0; i < 300; ++i) {
            const uintptr_t pc = group * 10000 + i * 2;
            assert(Cache::add(group, pc, pc + 1, pc + 1000) == 0);
            assert(Cache::findFDE(group, pc) == pc + 1000);
        }
        assert(Cache::removeAllIn(group) == 0);
    });
    for (auto& worker : workers) worker.join();
    std::puts("PASS checked FDE cache OOM rollback, retry, 200000 churn entries and 8 concurrent owners");
#endif
}
