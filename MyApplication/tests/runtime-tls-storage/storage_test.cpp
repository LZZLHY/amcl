/** 直接执行生产存储核心。真实 system thread_local、pthread TSD 和线程终止参与测试；
 * 可控身份/errno仅用于复用及故障边界，不把模拟ID测试冒称目标内核复用资格。
 */
#include "../../entry/src/main/cpp/jvm/tls_thread_storage.h"
#include <cassert>
#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>
#include <sys/wait.h>

using namespace amcl::tlsstorage;
static_assert(sizeof(AddressResult) <= 2 * sizeof(void*), "ordinary address return must not carry a preparation ticket");
static thread_local pid_t modeledTid = 0;
static thread_local bool scannerThread = false;
static constexpr pid_t ReusedTid = INT_MAX - 123;
struct alignas(std::max_align_t) Allocation { size_t size; };
struct Hooks {
    std::atomic<long> failAfter{-1};
    std::atomic<size_t> allocations{0}, frees{0}, live{0}, bytes{0}, identities{0}, observations{0};
    std::atomic<int> observationError{0};
    std::atomic<bool> modeledLive{true}, blockScanner{false}, scannerEntered{false}, releaseScanner{false}, newBirthWarm{false};
    std::atomic<bool> triggerReentry{false};
    Coordinator* owner = nullptr;
    Module* reentryModule = nullptr;
    std::atomic<int> reentryError{0};

    static void* allocate(size_t size, void* value) noexcept {
        auto& hooks = *static_cast<Hooks*>(value);
        hooks.allocations.fetch_add(1);
        if (hooks.triggerReentry.exchange(false)) hooks.reentryError.store(hooks.owner->GetBlock(hooks.reentryModule).error);
        long remaining = hooks.failAfter.load();
        while (remaining >= 0) {
            if (hooks.failAfter.compare_exchange_weak(remaining, remaining ? remaining - 1 : -1)) {
                if (!remaining) return nullptr;
                break;
            }
        }
        auto* allocation = static_cast<Allocation*>(std::malloc(sizeof(Allocation) + size));
        if (!allocation) return nullptr;
        allocation->size = size; hooks.live.fetch_add(1); hooks.bytes.fetch_add(size);
        return allocation + 1;
    }
    static void free(void* value, void* opaque) noexcept {
        if (!value) return;
        auto& hooks = *static_cast<Hooks*>(opaque);
        auto* allocation = static_cast<Allocation*>(value) - 1;
        hooks.live.fetch_sub(1); hooks.bytes.fetch_sub(allocation->size); hooks.frees.fetch_add(1); std::free(allocation);
    }
    static int identity(pid_t& process, pid_t& thread, void* value) noexcept {
        static_cast<Hooks*>(value)->identities.fetch_add(1);
        const int error = detail::identity(process, thread, nullptr);
        if (!error && modeledTid) thread = modeledTid;
        return error;
    }
    static int observe(pid_t process, pid_t thread, void* value) noexcept {
        auto& hooks = *static_cast<Hooks*>(value); hooks.observations.fetch_add(1);
        if (const int error = hooks.observationError.load()) return error;
        if (thread == ReusedTid) {
            if (scannerThread && hooks.blockScanner.load()) {
                // 先取得旧线程不存在的观察，再阻塞返回；新birth可以暖查成功但不能越过registry摘除。
                const int captured = hooks.modeledLive.load() ? 0 : ESRCH;
                hooks.scannerEntered.store(true);
                while (!hooks.releaseScanner.load()) std::this_thread::yield();
                return captured;
            }
            if (modeledTid) hooks.newBirthWarm.store(true);
            return hooks.modeledLive.load() ? 0 : ESRCH;
        }
        return detail::observe(process, thread, nullptr);
    }
    Functions functions() { return {allocate, free, identity, observe, this}; }
};

static Module* module(Coordinator& owner, size_t bytes = 64, size_t alignment = 64) {
    const uint32_t initial = 41; int error = 0;
    Module* result = owner.CreateModule(&initial, sizeof(initial), bytes, alignment, error);
    assert(result && !error); return result;
}
template<class Predicate> static void until(Predicate predicate) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!predicate()) { assert(std::chrono::steady_clock::now() < deadline); std::this_thread::yield(); }
}
static void finish(Coordinator& owner, Hooks& hooks, const std::vector<Module*>& modules) {
    for (Module* value : modules) assert(owner.Retire(value) == 0);
    assert(owner.Sweep().error == 0);
    const auto stats = owner.Snapshot();
    assert(!stats.error && stats.residentArenas == 0 && stats.registeredArenas == 0 && stats.blocks == 0);
    assert(stats.storageBytes == 0 && stats.modules == 0 && stats.moduleBytes == 0 && stats.retiredModules == 0);
    assert(stats.payloads == 0 && stats.payloadBytes == 0 && stats.externalReferences == 0);
    assert(hooks.live == 0 && hooks.bytes == 0 && owner.Shutdown() == 0);
}

static void basicAndHotPath() {
    Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0);
    Module* value = module(owner);
    std::thread worker([&] {
        const auto first = owner.GetBlock(value); assert(first.address && first.error == 0);
        assert(reinterpret_cast<uintptr_t>(first.address) % 64 == 0);
        auto* bytes = static_cast<unsigned char*>(first.address);
        assert(*reinterpret_cast<uint32_t*>(bytes) == 41);
        for (size_t i = 4; i < 64; ++i) assert(bytes[i] == 0);
        *reinterpret_cast<uint32_t*>(bytes) = 927;
        const size_t identities = hooks.identities, observations = hooks.observations, allocations = hooks.allocations;
        for (size_t i = 0; i < 200000; ++i) {
            const auto again = owner.GetBlock(value);
            assert(again.address == bytes && *static_cast<uint32_t*>(again.address) == 927);
        }
        assert(hooks.identities == identities && hooks.observations == observations && hooks.allocations == allocations);
    }); worker.join();
    finish(owner, hooks, {value});
    std::puts("PASS stable aligned TLS and 200000 hot hits without identity/probe/allocation hooks");
}

struct LateContext {
    Coordinator* owner; Module* b; Module* c; void* address; uint64_t arena;
    std::atomic<int> cpp{0}, tsd{0}; pthread_key_t key = 0;
    bool blockCallbacks = false;
    std::atomic<bool> cppEntered{false}, releaseCpp{false}, tsdEntered{false}, releaseTsd{false};
};
static thread_local LateContext* lateContext = nullptr;
struct LateReader {
    ~LateReader() {
        auto& context = *lateContext;
        if (context.blockCallbacks) {
            context.cppEntered = true;
            until([&] { return context.releaseCpp.load(); });
        }
        const auto b = context.owner->GetBlock(context.b);
        assert(b.address == context.address && context.owner->CurrentArenaGeneration() == context.arena && *static_cast<int*>(b.address) == 718);
        const auto c = context.owner->GetBlock(context.c);
        assert(c.address && context.owner->CurrentArenaGeneration() == context.arena); context.cpp.fetch_add(1);
    }
};
static thread_local LateReader lateReader;
static void tsdReader(void*) {
    auto& context = *lateContext;
    if (context.blockCallbacks) {
        context.tsdEntered = true;
        until([&] { return context.releaseTsd.load(); });
    }
    const auto b = context.owner->GetBlock(context.b);
    assert(b.address == context.address && context.owner->CurrentArenaGeneration() == context.arena && *static_cast<int*>(b.address) == 718);
    if (context.tsd.fetch_add(1) == 0) assert(pthread_setspecific(context.key, reinterpret_cast<void*>(1)) == 0);
}
static void lateCallbacks() {
    Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0);
    Module* b = module(owner); Module* c = module(owner);
    LateContext context{&owner, b, c, nullptr, 0};
    assert(pthread_key_create(&context.key, tsdReader) == 0);
    std::thread worker([&] {
        lateContext = &context; (void)&lateReader; // 系统CXX析构先登记，B普通块稍后出现。
        const auto block = owner.GetBlock(b); context.address = block.address; context.arena = owner.CurrentArenaGeneration();
        assert(block.address); *static_cast<int*>(block.address) = 718;
        assert(pthread_setspecific(context.key, reinterpret_cast<void*>(1)) == 0);
    }); worker.join();
    assert(context.cpp == 1 && context.tsd == 2); assert(pthread_key_delete(context.key) == 0);
    finish(owner, hooks, {b, c});
    std::puts("PASS cross-block late CXX access, first block during exit and cleared/rearmed TSD key");
}

static void sweepDuringBlockedCallbacks() {
    Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0);
    Module* b = module(owner); Module* c = module(owner);
    LateContext context{&owner, b, c, nullptr, 0}; context.blockCallbacks = true;
    assert(pthread_key_create(&context.key, tsdReader) == 0);
    std::thread worker([&] {
        lateContext = &context; (void)&lateReader;
        const auto block = owner.GetBlock(b); assert(block.address);
        context.address = block.address; context.arena = owner.CurrentArenaGeneration();
        *static_cast<int*>(block.address) = 718;
        assert(pthread_setspecific(context.key, reinterpret_cast<void*>(1)) == 0);
    });
    // 不假设CXX与TSD的内部排序；分别在两类真实回调仍阻塞的窗口运行回收者。
    until([&] { return context.cppEntered.load() || context.tsdEntered.load(); });
    const bool cppFirst = context.cppEntered.load();
    const auto stillAlive = [&] {
        for (unsigned i = 0; i < 16; ++i) {
            const auto observation = owner.Sweep();
            assert(observation.error == 0 && observation.live == 1 && observation.removed == 0);
            assert(owner.Snapshot().residentArenas == 1);
        }
    };
    stillAlive();
    if (cppFirst) context.releaseCpp = true; else context.releaseTsd = true;
    until([&] { return cppFirst ? context.tsdEntered.load() : context.cppEntered.load(); });
    stillAlive(); context.releaseCpp = true; context.releaseTsd = true;
    worker.join(); assert(context.cpp == 1 && context.tsd == 2);
    assert(pthread_key_delete(context.key) == 0); finish(owner, hooks, {b, c});
    std::puts("PASS real CXX/TSD callback windows remain Live during 32 concurrent storage sweeps");
}

static void failuresAndRollback() {
    for (long failure = 0; failure < 4; ++failure) {
        Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0); Module* value = module(owner);
        const size_t baselineAllocations = hooks.live;
        std::thread worker([&] {
            hooks.failAfter = failure;
            const auto bad = owner.GetBlock(value); assert(bad.error == ENOMEM && bad.address == nullptr);
            assert(owner.Snapshot().residentArenas == 0 && hooks.live == baselineAllocations);
            hooks.failAfter = -1; assert(owner.GetBlock(value).address);
        }); worker.join(); finish(owner, hooks, {value});
    }
    Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0);
    Module* first = module(owner); Module* second = module(owner);
    hooks.owner = &owner; hooks.reentryModule = first;
    std::thread worker([&] {
        hooks.triggerReentry = true;
        const auto baseline = owner.GetBlock(first); assert(baseline.address && hooks.reentryError == EDEADLK);
        *static_cast<int*>(baseline.address) = 501;
        const auto prepared = owner.PrepareBlock(second); assert(prepared.address && prepared.rollback.valid());
        assert(owner.RollbackPrepared(prepared.rollback) == 0);
        const auto next = owner.PrepareBlock(second); assert(next.address && next.rollback.valid());
        assert(owner.RollbackPrepared(prepared.rollback) == EINVAL); // 同模块重分配也不能复用旧ticket。
        assert(owner.GetBlock(second).address == next.address);
        assert(owner.RollbackPrepared(next.rollback) == EINVAL); // 普通访问已经发布，不能“准备失败”回收。
        assert(owner.GetBlock(first).address == baseline.address && *static_cast<int*>(baseline.address) == 501);
    }); worker.join(); finish(owner, hooks, {first, second});
    std::puts("PASS arena/table/node/payload OOM rollback, reentrant first registration and prepared-ticket ABA rejection");
}

static void tableFailureAndModuleValidation() {
    Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0);
    int error = 0; const int initial = 1;
    assert(!owner.CreateModule(&initial, 4, 8, 3, error) && error == EINVAL);
    assert(!owner.CreateModule(&initial, 4, 2, 8, error) && error == EINVAL);
    assert(!owner.CreateModule(nullptr, 4, 8, 8, error) && error == EINVAL);
    assert(!owner.CreateModule(nullptr, 0, SIZE_MAX, 64, error) && error == EINVAL);
    hooks.failAfter = 0; assert(!owner.CreateModule(&initial, 4, 8, 8, error) && error == ENOMEM);
    hooks.failAfter = 1; assert(!owner.CreateModule(&initial, 4, 8, 8, error) && error == ENOMEM && hooks.live == 0);
    std::vector<Module*> values; for (unsigned i = 0; i < 13; ++i) values.push_back(module(owner));
    std::thread worker([&] {
        void* original[12]{};
        for (unsigned i = 0; i < 12; ++i) { original[i] = owner.GetBlock(values[i]).address; assert(original[i]); *static_cast<unsigned*>(original[i]) = i + 100; }
        hooks.failAfter = 0;
        assert(owner.GetBlock(values[12]).error == ENOMEM);
        for (unsigned i = 0; i < 12; ++i) assert(owner.GetBlock(values[i]).address == original[i] && *static_cast<unsigned*>(original[i]) == i + 100);
        assert(owner.GetBlock(values[12]).address);
    }); worker.join(); finish(owner, hooks, values);
    std::puts("PASS invalid templates and table growth OOM preserve all previous blocks");
}

static void unknownErrorBoundary() {
    Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0);
    Module* first = module(owner); Module* second = module(owner);
    std::atomic<int> phase{0};
    std::thread worker([&] {
        const auto old = owner.GetBlock(first); assert(old.address); *static_cast<int*>(old.address) = 882;
        phase = 1; until([&] { return phase >= 2; });
        const size_t queries = hooks.observations;
        const auto retained = owner.GetBlock(first); assert(retained.address == old.address && *static_cast<int*>(retained.address) == 882);
        assert(hooks.observations == queries);
        const auto denied = owner.GetBlock(second); assert(!denied.address && denied.error == EPERM);
        phase = 3; until([&] { return phase >= 4; });
        assert(owner.GetBlock(second).address);
    });
    until([&] { return phase == 1; }); hooks.observationError = EPERM;
    assert(owner.Sweep().error == EPERM);
    const auto retained = owner.Snapshot(); assert(retained.residentArenas == 1 && retained.expansionError == EPERM);
    int error = 0; assert(!owner.CreateModule(nullptr, 0, 8, 8, error) && error == EPERM);
    phase = 2; until([&] { return phase == 3; });
    assert(owner.Snapshot().storageBytes == retained.storageBytes);
    hooks.observationError = 0; assert(owner.RecheckCapability() == 0); phase = 4; worker.join();
    hooks.observationError = EINVAL; assert(owner.Sweep().error == EINVAL);
    const size_t isolated = owner.Snapshot().storageBytes;
    for (unsigned i = 0; i < 64; ++i) { std::thread denied([&] { assert(owner.GetBlock(first).error == EINVAL); }); denied.join(); }
    assert(owner.Snapshot().storageBytes == isolated && owner.Snapshot().residentArenas == 1);
    hooks.observationError = 0; assert(owner.RecheckCapability() == 0); finish(owner, hooks, {first, second});
    std::puts("PASS unknown errno preserves old blocks, rejects expansion with bounded retained bytes and explicit recovery");
}

static void threadChurnAndModuleRetention() {
    Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0); Module* value = module(owner);
    for (unsigned i = 0; i < 1024; ++i) { std::thread worker([&] { assert(owner.GetBlock(value).address); }); worker.join(); assert(!owner.Sweep().error); }
    std::atomic<unsigned> detachedDone{0};
    for (unsigned i = 0; i < 128; ++i) std::thread([&] { assert(owner.GetBlock(value).address); detachedDone.fetch_add(1); }).detach();
    until([&] { owner.Sweep(); return detachedDone == 128 && owner.Snapshot().residentArenas == 0; });
    finish(owner, hooks, {value});

    Hooks retainedHooks; Coordinator retained; assert(retained.Initialize(retainedHooks.functions()) == 0);
    std::atomic<bool> ready{false}, release{false};
    std::thread longLived([&] {
        for (unsigned i = 0; i < 64; ++i) { Module* generation = module(retained, 16384); assert(retained.GetBlock(generation).address); assert(retained.Retire(generation) == 0); }
        ready = true; until([&] { return release.load(); });
    });
    until([&] { return ready.load(); }); const auto sample = retained.Snapshot();
    assert(sample.blocks <= 1 && sample.modules <= 1 && sample.payloads == 0 && sample.payloadBytes == 0 && sample.storageBytes < 16384);
    std::printf("RECLAIMED legal module churn: payloads=%zu retainedNodes=%zu metadataBytes=%zu\n", sample.payloads, sample.blocks, sample.storageBytes + sample.moduleBytes);
    release = true; longLived.join(); finish(retained, retainedHooks, {});
    std::puts("PASS real detached/joined churn and bounded long-lived module-retirement storage");
}

static void callbackReferenceAndImmediatePayloadRelease() {
    {
        Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0);
        Module* b = module(owner); Module* c = module(owner); assert(owner.Retain(b) == 0);
        LateContext context{&owner, b, c, nullptr, 0};
        assert(pthread_key_create(&context.key, tsdReader) == 0);
        std::atomic<bool> ready{false}, exit{false};
        std::thread worker([&] {
            lateContext = &context; (void)&lateReader;
            const auto block = owner.GetBlock(b); assert(block.address);
            context.address = block.address; context.arena = owner.CurrentArenaGeneration();
            *static_cast<int*>(block.address) = 718;
            assert(pthread_setspecific(context.key, reinterpret_cast<void*>(1)) == 0);
            ready = true; until([&] { return exit.load(); });
        });
        until([&] { return ready.load(); });
        assert(owner.Retire(b) == 0); // creator关闭，独立callback引用仍保护所有合法晚访问。
        assert(owner.Snapshot().payloads == 1);
        exit = true; worker.join(); assert(context.cpp == 1 && context.tsd == 2);
        assert(owner.Release(b) == 0); assert(pthread_key_delete(context.key) == 0);
        finish(owner, hooks, {c});
    }
    {
        Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0);
        constexpr size_t TemplateBytes = 65536;
        std::vector<unsigned char> initial(TemplateBytes, 17); int error = 0;
        Module* large = owner.CreateModule(initial.data(), initial.size(), initial.size() + 64, 64, error);
        assert(large && !error); initial.assign(TemplateBytes, 29); // 模板必须独立于已修改/卸载的原image。
        Module* stable = module(owner); Module* next = module(owner);
        std::atomic<int> phase{0};
        std::thread worker([&] {
            void* stableAddress = owner.GetBlock(stable).address; assert(stableAddress); *static_cast<int*>(stableAddress) = 616;
            auto payload = owner.GetBlock(large); assert(payload.address);
            assert(static_cast<unsigned char*>(payload.address)[0] == 17 && static_cast<unsigned char*>(payload.address)[TemplateBytes] == 0);
            phase = 1; until([&] { return phase >= 2; });
            // 最后合法入口已经关闭，后续不再读取旧payload/调用旧Module，只访问仍有owner的模块。
            const size_t allocations = hooks.allocations;
            assert(owner.GetBlock(stable).address == stableAddress && *static_cast<int*>(stableAddress) == 616);
            assert(hooks.allocations == allocations);
            assert(owner.GetBlock(next).address); // 原线程冷miss清理自己的tombstone，不能跨线程改表。
            phase = 3; until([&] { return phase >= 4; });
            assert(owner.GetBlock(stable).address == stableAddress && *static_cast<int*>(stableAddress) == 616);
        });
        until([&] { return phase == 1; });
        const auto before = owner.Snapshot(); assert(before.blocks == 2 && before.payloads == 2);
        assert(owner.Retire(large) == 0); // 另一线程释放最后合法入口，owner线程仍活着。
        const auto after = owner.Snapshot();
        assert(after.blocks == 2 && after.payloads == 1 && after.moduleBytes + TemplateBytes == before.moduleBytes);
        assert(after.payloadBytes + TemplateBytes <= before.payloadBytes);
        phase = 2; until([&] { return phase == 3; });
        assert(owner.Snapshot().modules == 2 && owner.Snapshot().blocks == 2);
        phase = 4; worker.join(); finish(owner, hooks, {stable, next});
    }
    std::puts("PASS callback refs preserve late accesses; final external release frees payload/template without changing live thread hash");
}

static void retirementRacesTerminalCollection() {
    for (unsigned round = 0; round < 64; ++round) {
        Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0); Module* value = module(owner, 16384);
        std::thread worker([&] { assert(owner.GetBlock(value).address); }); worker.join();
        std::atomic<bool> begin{false};
        std::thread close([&] { until([&] { return begin.load(); }); assert(owner.Retire(value) == 0); });
        std::thread reap([&] { until([&] { return begin.load(); }); assert(owner.Sweep().error == 0); });
        begin = true; close.join(); reap.join(); finish(owner, hooks, {});
    }
    std::puts("PASS 64 last-external-release versus terminal-reaper races claim each payload exactly once");
}

/** 准备块尚未交给用户代码时，loader可回滚本次准备，同时另一线程关闭最后入口。
 * 两者只竞争payload所有权，ticket核验依靠仍在当前arena中的节点，不访问已释放payload。
 */
static void retirementRacesPreparedRollback() {
    for (unsigned round = 0; round < 64; ++round) {
        Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0);
        Module* value = module(owner, 16384);
        std::atomic<bool> ready{false}, begin{false};
        std::thread worker([&] {
            const auto prepared = owner.PrepareBlock(value); assert(prepared.rollback.valid());
            ready = true; until([&] { return begin.load(); });
            assert(owner.RollbackPrepared(prepared.rollback) == 0);
            assert(owner.RollbackPrepared(prepared.rollback) == EINVAL);
        });
        until([&] { return ready.load(); });
        std::thread close([&] { until([&] { return begin.load(); }); assert(owner.Retire(value) == 0); });
        begin = true; worker.join(); close.join(); finish(owner, hooks, {});
    }
    std::puts("PASS 64 last-external-release versus prepared rollback races claim payload and metadata once");
}

/** 对正常批量装载的成本回归：没有模块退休时，新增N个块只做哈希插入/必要扩容，
 * 不扫描此前所有节点；别的线程arena中的退休也不产生本线程无用的全表扫描。
 */
static void coldMissDoesNotScanUnchangedTables() {
    Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0);
    std::vector<Module*> values;
    for (unsigned index = 0; index < 512; ++index) values.push_back(module(owner));
    Module* other = module(owner);
    std::atomic<int> phase{0};
    std::thread worker([&] {
        for (unsigned index = 0; index < 256; ++index) assert(owner.GetBlock(values[index]).address);
        phase = 1; until([&] { return phase >= 2; });
        for (unsigned index = 256; index < values.size(); ++index) assert(owner.GetBlock(values[index]).address);
        const auto stats = owner.Snapshot(); assert(stats.tombstonePasses == 0 && stats.tombstoneVisits == 0);
    });
    until([&] { return phase == 1; });
    std::thread unrelated([&] { assert(owner.GetBlock(other).address); }); unrelated.join();
    assert(owner.Retire(other) == 0); phase = 2; worker.join();
    finish(owner, hooks, values);
    std::puts("PASS 512 live modules and unrelated retirement require zero tombstone table scans");
}

static void identityReuseAndConcurrentSweep() {
    Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0); Module* value = module(owner);
    uint64_t original = 0, replacement = 0;
    std::thread old([&] { modeledTid = ReusedTid; const auto block = owner.GetBlock(value); original = owner.CurrentArenaGeneration(); assert(block.address); }); old.join();
    assert(owner.Sweep().live == 1); // 模拟该数字被不使用customTLS的外部活线程持有：只保守保留。
    hooks.blockScanner = true; hooks.newBirthWarm = false; hooks.modeledLive = false;
    SweepStats scanned;
    std::thread scanner([&] { scannerThread = true; scanned = owner.Sweep(); });
    until([&] { return hooks.scannerEntered.load(); });
    hooks.modeledLive = true; // 旧查询已取得不存在；随后新birth才占用该数字编号。
    std::atomic<bool> born{false}, exit{false};
    std::thread fresh([&] {
        modeledTid = ReusedTid; const auto block = owner.GetBlock(value); assert(block.address);
        replacement = owner.CurrentArenaGeneration(); *static_cast<int*>(block.address) = 338; born = true;
        until([&] { return exit.load(); }); assert(owner.GetBlock(value).address == block.address && *static_cast<int*>(block.address) == 338);
    });
    until([&] { return hooks.newBirthWarm.load(); }); assert(!born);
    hooks.releaseScanner = true; scanner.join(); until([&] { return born.load(); });
    assert(scanned.removed == 1 && replacement > original && owner.Snapshot().residentArenas == 1);
    exit = true; fresh.join(); hooks.modeledLive = false; finish(owner, hooks, {value});

    Hooks same; Coordinator newOwner; assert(newOwner.Initialize(same.functions()) == 0); Module* item = module(newOwner);
    std::thread a([&] { modeledTid = ReusedTid; assert(newOwner.GetBlock(item).address); }); a.join();
    std::thread b([&] { modeledTid = ReusedTid; assert(newOwner.GetBlock(item).address); assert(newOwner.Snapshot().residentArenas == 1); }); b.join();
    same.modeledLive = false; finish(newOwner, same, {item});
    std::puts("PASS controlled ID reuse, foreign-ID retention and old-observer/new-birth serialization");
}

struct EarlyForkContext {
    Coordinator* owner; Module* existing; Module* absent; PreparedBlock prepared; void* expected;
    Hooks* hooks; size_t allocations;
    bool inheritedWarm = false, coldRejected = false, rollbackRejected = false, metadataRejected = false, sweepRejected = false, noAllocation = false;
};
static EarlyForkContext* earlyForkContext = nullptr;
static void beforeStorageChildHandler() {
    if (!earlyForkContext) return;
    alarm(5);
    auto& context = *earlyForkContext;
    // 这个handler先注册，合法执行顺序使它先于本模块的child poison。明确保留热读窗口，
    // 不把后置handler的成功冒称所有fork回调时刻都已隔离；截止alarm只保护本测试child。
    const auto inherited = context.owner->GetBlock(context.existing);
    context.inheritedWarm = !inherited.error && inherited.address == context.expected;
    context.coldRejected = context.owner->GetBlock(context.absent).error == ECHILD;
    context.rollbackRejected = context.owner->RollbackPrepared(context.prepared) == ECHILD;
    context.metadataRejected = context.owner->Retain(context.absent) == ECHILD &&
        context.owner->Release(context.absent) == ECHILD && context.owner->Retire(context.absent) == ECHILD;
    context.sweepRejected = context.owner->Sweep().error == ECHILD;
    context.noAllocation = context.hooks->allocations.load() == context.allocations;
}

static void forkRejectsInheritedState() {
    Hooks hooks; Coordinator owner; assert(owner.Initialize(hooks.functions()) == 0); Module* value = module(owner);
    Module* absent = module(owner); Module* preparedModule = module(owner);
    std::atomic<bool> warm{false}, forkNow{false}, forkFinished{false};
    std::thread worker([&] {
        modeledTid = ReusedTid;
        const auto existing = owner.GetBlock(value); assert(existing.address);
        const auto prepared = owner.PrepareBlock(preparedModule); assert(prepared.address && prepared.rollback.valid());
        EarlyForkContext context{&owner, value, absent, prepared.rollback, existing.address, &hooks, hooks.allocations.load()};
        earlyForkContext = &context; warm = true;
        until([&] { return forkNow.load(); });
        const pid_t child = fork(); assert(child >= 0);
        if (child == 0) {
            alarm(5); // 错误实现触碰继承锁时以失败终止自己的测试child，不让负例永久挂住QA。
            const auto result = owner.GetBlock(value);
            const bool before = context.inheritedWarm && context.coldRejected && context.rollbackRejected &&
                context.metadataRejected && context.sweepRejected && context.noAllocation;
            _exit(before && result.error == ECHILD && result.address == nullptr && owner.Sweep().error == ECHILD ? 0 : 77);
        }
        int status = 0; pid_t waited;
        do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
        assert(waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
        forkFinished = true;
        assert(owner.GetBlock(value).address == existing.address);
        assert(owner.RollbackPrepared(prepared.rollback) == 0); earlyForkContext = nullptr;
    });
    until([&] { return warm.load(); }); hooks.blockScanner = true;
    std::thread scanner([&] { scannerThread = true; assert(owner.Sweep().error == 0); });
    until([&] { return hooks.scannerEntered.load(); }); forkNow = true;
    until([&] { return forkFinished.load(); }); hooks.releaseScanner = true;
    scanner.join(); worker.join(); hooks.modeledLive = false; finish(owner, hooks, {value, absent, preparedModule});
    std::puts("PASS fork child rejects inherited locked registry; cold operations also reject before our child hook");
    std::puts("OPEN FORK GATE: earlier child handler can still read an inherited warm block before our poison hook");
}

int main() {
    assert(pthread_atfork(nullptr, nullptr, beforeStorageChildHandler) == 0);
    basicAndHotPath(); lateCallbacks(); sweepDuringBlockedCallbacks(); failuresAndRollback(); tableFailureAndModuleValidation();
    unknownErrorBoundary(); threadChurnAndModuleRetention(); identityReuseAndConcurrentSweep(); forkRejectsInheritedState();
    callbackReferenceAndImmediatePayloadRelease(); retirementRacesTerminalCollection();
    retirementRacesPreparedRollback(); coldMissDoesNotScanUnchangedTables();
    std::puts("PASS storage core only; real loader/cxa integration and target platform qualification remain pending");
}
