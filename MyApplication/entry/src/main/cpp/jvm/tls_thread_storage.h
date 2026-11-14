/**
 * 自加载 TLS 的纯存储协调器。仅供常驻、由系统装载的 libentry 持有；不安装第二条
 * C++ 析构队列，不调用用户 dtor/fini，也不负责 DSO 的代码/异常展开 pin。
 *
 * 合法module入口仍存活时，普通 TLS 也不能被早期 key/dtor 回调释放。最后外部引用
 * 结束后只释放payload，线程查找节点由原线程冷路径或明确OS终态回收，不跨线程改哈希。
 * tgkill 成功可能属于复用该编号的外部线程，因此终止回收不存在固定延迟保证。
 * 平台实际终止合同、系统 POD TLS 的退出期寿命和真实析构队列交错须在目标另验。
 */
#ifndef AMCL_TLS_THREAD_STORAGE_H
#define AMCL_TLS_THREAD_STORAGE_H

#include <atomic>
#include <cerrno>
#include <climits>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>
#include <pthread.h>
#include <sys/syscall.h>
#include <type_traits>
#include <unistd.h>

namespace amcl::tlsstorage {
class Coordinator;
struct Module;
struct Arena;
struct Block;

namespace detail {
enum class Phase : unsigned { Empty = 0, Constructing, Ready };
struct ThreadSlot { Coordinator* owner; Arena* arena; Phase phase; };
static_assert(std::is_trivial<ThreadSlot>::value && std::is_standard_layout<ThreadSlot>::value,
              "authoritative system TLS must remain zero-initialized POD");
// hidden + inline 合并同一 libentry 的多个 TU，避免其它 DSO 截获；只有 POD 零初始化。
// 此TU必须采用系统原生ELF TLS（OHOS clang需-fno-emulated-tls）并核验实际产物：
// 默认__emutls_get_address背后的pthread key可能在晚析构前清空，不能承担这个权威槽。
// 原生槽无TLS constructor/destructor，pthread key清空或回调迭代不会主动修改它。
inline thread_local ThreadSlot slot __attribute__((visibility("hidden"))) = {};
inline std::atomic<bool> forkChild __attribute__((visibility("hidden"))){false};
inline std::atomic<pid_t> initialProcess __attribute__((visibility("hidden"))){0};
inline pthread_once_t forkOnce __attribute__((visibility("hidden"))) = PTHREAD_ONCE_INIT;
inline int forkRegistrationError __attribute__((visibility("hidden"))) = 0;
inline void childAfterFork() noexcept { forkChild.store(true, std::memory_order_relaxed); }
inline void installForkGuard() noexcept { forkRegistrationError = pthread_atfork(nullptr, nullptr, childAfterFork); }

/** 冷路径先核进程，再接触可能从父进程继承的锁；不尝试重置、接管或释放父 arena。 */
inline int initializeProcess() noexcept {
    if (forkChild.load(std::memory_order_acquire)) return ECHILD;
    const pid_t actual = getpid();
    if (actual <= 0) return EPROTO;
    pid_t expected = 0;
    if (!initialProcess.compare_exchange_strong(expected, actual) && expected != actual) return ECHILD;
    const int onceError = pthread_once(&forkOnce, installForkGuard);
    return onceError ? onceError : forkRegistrationError;
}
inline void* allocate(size_t size, void*) noexcept { return std::malloc(size); }
inline void deallocate(void* value, void*) noexcept { std::free(value); }
inline int identity(pid_t& process, pid_t& thread, void*) noexcept {
    process = getpid();
    const long value = syscall(SYS_gettid);
    if (process <= 0 || value <= 0 || value > INT_MAX) return EPROTO;
    thread = static_cast<pid_t>(value); return 0;
}
inline int observe(pid_t process, pid_t thread, void*) noexcept {
    return syscall(SYS_tgkill, process, thread, 0) == 0 ? 0 : errno;
}
struct Lock {
    pthread_mutex_t* mutex;
    int error;
    explicit Lock(pthread_mutex_t& value) noexcept : mutex(&value), error(pthread_mutex_lock(&value)) {}
    ~Lock() { if (!error) pthread_mutex_unlock(mutex); }
};
inline bool add(size_t a, size_t b, size_t& result) noexcept {
    if (a > SIZE_MAX - b) return false;
    result = a + b; return true;
}
} // namespace detail

/** 所有 hook 在初始化后不再改变，context 必须活到全部 module/arena 释放。observe
 * 仅为不分配、不重入的 OS 查询；分配/释放 hook 从不在 registry 锁中执行。
 * 测试可替换身份/查询以控制编号复用，但不得让真实活线程的身份返回 ESRCH。
 */
struct Functions {
    void* (*allocate)(size_t, void*) noexcept = detail::allocate;
    void (*deallocate)(void*, void*) noexcept = detail::deallocate;
    int (*identity)(pid_t&, pid_t&, void*) noexcept = detail::identity;
    int (*observe)(pid_t, pid_t, void*) noexcept = detail::observe;
    void* context = nullptr;
};

/** 不可变模板与模块身份独立于 DSO mapping。每个 block 持有元数据引用；caller 的
 * descriptor/callback 也须各自保留引用，其代码 pin 由 loader 负责，不能由本模块猜测。
 */
struct Module {
private:
    friend class Coordinator;
    Coordinator* owner = nullptr;
    std::atomic<size_t> references{1};
    size_t externalReferences = 1; // registry锁下：creator/descriptor/callback；Block不是合法入口。
    Block* firstBlock = nullptr;
    std::atomic<bool> retired{false};
    uint64_t id = 0;
    size_t memorySize = 0, fileSize = 0, alignment = 0, allocationSize = 0;
    unsigned char* initial = nullptr;
public:
    uint64_t generation() const noexcept { return id; }
};

/** 独立payload。只有成功exchange取得其所有权的一方可在锁外释放；链字段用于
 * 一次最后external release批量收集，不分配辅助vector，也不触碰线程自己的哈希链。
 */
struct Payload {
    Payload* garbageNext = nullptr;
    size_t allocationSize = 0;
};

struct Block {
    Module* module = nullptr;
    Arena* arena = nullptr; // registry锁下由最后external释放通知所属活表；不取得线程表写权限。
    Block* hashNext = nullptr;
    Block* allNext = nullptr;
    Block* modulePrevious = nullptr;
    Block* moduleNext = nullptr;
    std::atomic<Payload*> payload{nullptr};
    void* address = nullptr;
    uint64_t generation = 0;
    bool prepared = false;
};

struct Arena {
    Coordinator* owner = nullptr;
    std::atomic<size_t> references{1}; // registry + 正在观察的 sweeper；线程指针不代替终止判断。
    Arena* previous = nullptr;
    Arena* next = nullptr;
    bool registered = false; // 仅 registry mutex 下读写。
    pid_t process = 0, thread = 0;
    uint64_t id = 0;
    Block** buckets = nullptr; // 以下查找状态由原线程独占；终止后才由回收者读取/释放。
    size_t capacity = 0, count = 0;
    uint64_t nextBlock = 0;
    std::atomic<bool> hasTombstones{false}; // 最后external在registry锁下置位，原线程冷miss清除。
    std::atomic<Block*> blocks{nullptr}; // release 发布纯元数据，回收者 acquire 读取。
    Module* recentModule = nullptr;
    Block* recentBlock = nullptr;
    bool allocating = false;
};

/** 仅 PrepareBlock 新分配且尚未被普通 GetBlock 发布的块可以回滚。ticket 不是 pin，
 * 只能在原线程、原 arena 仍存活时使用；不能把已经交给构造函数的地址回滚掉。
 */
class PreparedBlock {
    friend class Coordinator;
    Arena* arena_ = nullptr;
    Block* block_ = nullptr;
    uint64_t arenaId_ = 0, moduleId_ = 0, blockId_ = 0;
public:
    bool valid() const noexcept { return block_ != nullptr; }
};
struct Result {
    void* address = nullptr;
    int error = 0;
    uint64_t arenaGeneration = 0;
    PreparedBlock rollback;
};
/** 普通TLS取址只返回两个寄存器可承载的信息；准备ticket留在独立冷接口。 */
struct AddressResult { void* address = nullptr; int error = 0; };
struct Stats {
    size_t residentArenas = 0, registeredArenas = 0, blocks = 0, storageBytes = 0;
    size_t modules = 0, moduleBytes = 0, retiredModules = 0;
    size_t payloads = 0, payloadBytes = 0, externalReferences = 0;
    size_t tombstonePasses = 0, tombstoneVisits = 0; // 冷路径成本，热命中不更新这些诊断计数。
    int expansionError = 0, error = 0;
    uint32_t failureGeneration = 0;
};
struct SweepStats {
    size_t examined = 0, live = 0, unknown = 0, removed = 0;
    int error = 0;
};

/**
 * 单进程常驻 owner。Initialize/Shutdown 是显式冷路径；实例必须比全部 descriptor、
 * callback、module 和 arena 更长寿，禁止在主线程退出或 atexit 中强制释放活线程。
 * 析构器不清理资源，避免静态析构错误地变成“所有线程已经死亡”的证明。
 */
class Coordinator {
public:
    Coordinator() = default;
    Coordinator(const Coordinator&) = delete;
    Coordinator& operator=(const Coordinator&) = delete;

    int Initialize(Functions functions = {}) noexcept {
        const int processError = detail::initializeProcess();
        if (processError) return processError;
        if (ready_.load(std::memory_order_acquire)) return EALREADY;
        if (!functions.allocate || !functions.deallocate || !functions.identity || !functions.observe) return EINVAL;
        // 初始化由启动线程独占；尚未 ready 的实例不能被其它 API 消费。
        functions_ = functions; process_ = getpid();
        ready_.store(true, std::memory_order_release); return 0;
    }

    /** 初始化模板只复制有效 fileSize；BSS 在每线程新块创建时清零。溢出/错误对齐/OOM
     * 都返回错误，未发布的分配完整回滚，不提供看似合法的零偏移或错误地址。
     */
    Module* CreateModule(const void* initial, size_t fileSize, size_t memorySize, size_t alignment, int& error) noexcept {
        error = CheckCold();
        if (error) return nullptr;
        if ((error = ExpansionError())) return nullptr;
        if (alignment && (alignment & (alignment - 1))) { error = EINVAL; return nullptr; }
        if (!alignment) alignment = alignof(void*);
        if (alignment < alignof(void*)) alignment = alignof(void*);
        size_t bytes = 0, check = 0;
        if ((alignment & (alignment - 1)) || fileSize > memorySize || (fileSize && !initial) ||
            !detail::add(sizeof(Module), fileSize, bytes) || !BlockBytes(memorySize, alignment, check)) {
            error = EINVAL; return nullptr;
        }
        void* raw = functions_.allocate(sizeof(Module), functions_.context);
        if (!raw) { error = ENOMEM; return nullptr; }
        auto* module = new(raw) Module;
        module->owner = this; module->fileSize = fileSize; module->memorySize = memorySize;
        module->alignment = alignment; module->allocationSize = sizeof(Module);
        if (fileSize) {
            module->initial = static_cast<unsigned char*>(functions_.allocate(fileSize, functions_.context));
            if (!module->initial) {
                module->~Module(); functions_.deallocate(raw, functions_.context); error = ENOMEM; return nullptr;
            }
            std::memcpy(module->initial, initial, fileSize);
        }
        uint64_t id = nextModule_.load(std::memory_order_relaxed);
        while (id != UINT64_MAX && !nextModule_.compare_exchange_weak(id, id + 1, std::memory_order_relaxed)) {}
        const int lateError = ExpansionError();
        if (id == UINT64_MAX || lateError) {
            if (module->initial) functions_.deallocate(module->initial, functions_.context);
            module->~Module(); functions_.deallocate(raw, functions_.context);
            error = id == UINT64_MAX ? EOVERFLOW : lateError; return nullptr;
        }
        module->id = id + 1;
        modules_.fetch_add(1); moduleBytes_.fetch_add(bytes); externalReferences_.fetch_add(1); return module;
    }

    int Retain(Module* module) noexcept {
        int error = CheckCold(); if (!error) error = CheckHot(module); if (error) return error;
        detail::Lock lock(registry_); if (lock.error) return lock.error;
        if (!module->externalReferences) return ESTALE; // 最后合法入口关闭后禁止从Block反向复活。
        if (module->externalReferences == SIZE_MAX || module->references.load() == SIZE_MAX) return EOVERFLOW;
        ++module->externalReferences; module->references.fetch_add(1); externalReferences_.fetch_add(1); return 0;
    }
    int Release(Module* module) noexcept {
        return ReleaseExternal(module, false);
    }
    /** Retire 恰好释放创建者引用；其它合法 callback/descriptor 引用仍可使用模板。
     * creator必须覆盖fini及仍可能触发TLS的全部合法入口；不能将一次公共dlclose误当此门。
     * 最后external关闭后清payload，而不是让Block内部ref永久维持完整大块或DSO映射。
     */
    int Retire(Module* module) noexcept {
        return ReleaseExternal(module, true);
    }

    /** 已有块的普通访问不携带准备ticket，不进入大型冷函数的栈帧；失效payload只能
     * 表示caller已失去合法外部入口，返回ESTALE而不把它重新初始化成另一个对象。
     */
    __attribute__((always_inline)) inline AddressResult GetBlock(Module* module) noexcept {
        const int error = CheckHot(module); if (error) return {nullptr, error};
        auto& slot = detail::slot;
        if (slot.phase == detail::Phase::Ready && slot.owner == this) {
            if (Block* block = Lookup(slot.arena, module)) {
                if (!block->payload.load(std::memory_order_acquire)) return {nullptr, ESTALE};
                if (block->prepared) block->prepared = false;
                return {block->address, 0};
            }
        }
        return AddressSlow(module);
    }
    Result PrepareBlock(Module* module) noexcept { return Access(module, true); }
    /** 诊断/测试用冷接口，不附着在普通TLSDESC返回值上。 */
    uint64_t CurrentArenaGeneration() const noexcept {
        if (CheckCold()) return 0;
        const auto& slot = detail::slot;
        return slot.phase == detail::Phase::Ready && slot.owner == this ? slot.arena->id : 0;
    }

    int RollbackPrepared(const PreparedBlock& ticket) noexcept {
        const int processError = CheckCold(); if (processError) return processError;
        auto& slot = detail::slot;
        if (slot.phase != detail::Phase::Ready || slot.owner != this || !ticket.valid() ||
            slot.arena != ticket.arena_ || slot.arena->id != ticket.arenaId_) return EINVAL;
        Arena* arena = slot.arena;
        if (arena->allocating) return EDEADLK;
        // ticket 不先解引用潜在旧 block：从仍活的 arena 表中核对精确指针/代次。
        Block* previous = nullptr;
        Block* block = arena->blocks.load(std::memory_order_acquire);
        while (block && block != ticket.block_) { previous = block; block = block->allNext; }
        if (!block || !block->prepared || block->module->id != ticket.moduleId_ || block->generation != ticket.blockId_) return EINVAL;
        arena->allocating = true;
        Payload* payload = nullptr;
        {
            detail::Lock lock(registry_);
            if (lock.error) { arena->allocating = false; return lock.error; }
            payload = DetachNodeLocked(block);
        }
        const size_t bucket = Hash(block->module) & (arena->capacity - 1);
        Block** link = &arena->buckets[bucket];
        while (*link != block) link = &(*link)->hashNext;
        *link = block->hashNext;
        Block* head = arena->blocks.load(std::memory_order_relaxed);
        if (previous) previous->allNext = block->allNext; else head = block->allNext;
        arena->recentBlock = nullptr; arena->recentModule = nullptr; --arena->count;
        arena->blocks.store(head, std::memory_order_release);
        FreePayload(payload); FreeNode(block);
        if (!arena->count) {
            const size_t bytes = arena->capacity * sizeof(Block*);
            functions_.deallocate(arena->buckets, functions_.context);
            storageBytes_.fetch_sub(bytes); arena->buckets = nullptr; arena->capacity = 0;
        }
        arena->allocating = false; return 0;
    }

    /** 每次仅在短 registry 临界区查询一个具体对象；下一对象持有观察引用，避免
     * 并发 sweep/新 birth 摘除后按旧 TID 误删新 arena。free 与 module release 都在锁外。
     */
    SweepStats Sweep() noexcept {
        SweepStats result;
        if ((result.error = CheckCold())) return result;
        pid_t process = 0, thread = 0;
        int probeError = functions_.identity(process, thread, functions_.context);
        if (!probeError && process != process_) probeError = ECHILD;
        if (!probeError) probeError = functions_.observe(process, thread, functions_.context);
        if (probeError) { result.error = RecordFailure(probeError); return result; }
        Arena* current = nullptr;
        {
            detail::Lock lock(registry_);
            if (lock.error) { result.error = lock.error; return result; }
            current = first_; if (current) current->references.fetch_add(1);
        }
        int unknownError = 0;
        while (current) {
            Arena* next = nullptr; bool removed = false;
            {
                detail::Lock lock(registry_);
                if (lock.error) { ReleaseArena(current); result.error = lock.error; return result; }
                if (current->registered) {
                    next = current->next;
                    const int observation = functions_.observe(current->process, current->thread, functions_.context);
                    ++result.examined;
                    if (observation == ESRCH) { Unlink(current); removed = true; ++result.removed; }
                    else if (!observation) ++result.live;
                    else { ++result.unknown; unknownError = RecordFailure(observation); }
                } else {
                    // 仅并发摘除的罕见路径需要从头恢复；正常遍历为线性，不按数字ID重找对象。
                    next = first_;
                    while (next && next->id <= current->id) next = next->next;
                }
                if (next) next->references.fetch_add(1);
            }
            if (removed) ReleaseArena(current);
            ReleaseArena(current); current = next;
        }
        // 恢复必须基于新一轮可靠观察。并发扫描存在时不能用较旧成功结果清除新失败。
        result.error = unknownError ? unknownError : ExpansionError();
        return result;
    }

    /** 能力恢复为显式冷操作：在 registry 锁下再次查本线程与所有当前 arena，全部
     * 返回0/ESRCH才解除扩张拒绝。未知对象从不因超时或次数被强制释放。
     */
    int RecheckCapability() noexcept {
        int error = CheckCold(); if (error) return error;
        // 快照必须在任何查询之前取得；锁外的self/warm失败也递增同一个代次，不能被
        // 当前这轮较早的成功观察覆盖。只比较errno会让同值的新失败产生ABA。
        uint64_t observedState = expansionState_.load(std::memory_order_acquire);
        if ((observedState >> 32) == UINT32_MAX) return EOVERFLOW;
        pid_t process = 0, thread = 0;
        error = functions_.identity(process, thread, functions_.context);
        if (error || process != process_) return RecordFailure(error ? error : ECHILD);
        detail::Lock lock(registry_); if (lock.error) return lock.error;
        error = functions_.observe(process, thread, functions_.context);
        if (!error) for (Arena* arena = first_; arena; arena = arena->next) {
            const int observed = functions_.observe(arena->process, arena->thread, functions_.context);
            if (observed && observed != ESRCH) { error = observed; break; }
        }
        if (error) return RecordFailure(error);
        const uint64_t cleared = observedState & 0xffffffff00000000ULL;
        if (expansionState_.compare_exchange_strong(observedState, cleared, std::memory_order_acq_rel)) return 0;
        // 更新后的errno为0也不证明本轮观察覆盖了新代次；让caller重新发起明确重验。
        const int current = static_cast<int>(observedState & UINT32_MAX);
        return current ? current : EAGAIN;
    }

    Stats Snapshot() noexcept {
        Stats stats;
        if ((stats.error = CheckCold())) return stats;
        { detail::Lock lock(registry_); if (lock.error) { stats.error = lock.error; return stats; } stats.registeredArenas = registered_; }
        stats.residentArenas = arenas_.load(); stats.blocks = blocks_.load(); stats.storageBytes = storageBytes_.load();
        stats.modules = modules_.load(); stats.moduleBytes = moduleBytes_.load(); stats.retiredModules = retiredModules_.load();
        stats.payloads = payloads_.load(); stats.payloadBytes = payloadBytes_.load(); stats.externalReferences = externalReferences_.load();
        stats.tombstonePasses = tombstonePasses_.load(); stats.tombstoneVisits = tombstoneVisits_.load();
        const uint64_t failure = expansionState_.load(std::memory_order_acquire);
        stats.expansionError = static_cast<int>(failure & UINT32_MAX);
        stats.failureGeneration = static_cast<uint32_t>(failure >> 32); return stats;
    }
    int Shutdown() noexcept {
        const Stats stats = Snapshot();
        if (stats.error) return stats.error;
        if (stats.residentArenas || stats.modules) return EBUSY;
        // 调用者先排除全部并发 API；实例不能在另一个线程仍访问时销毁/重新初始化。
        ready_.store(false, std::memory_order_release); return 0;
    }

private:
    int ExpansionError() const noexcept {
        return static_cast<int>(expansionState_.load(std::memory_order_acquire) & UINT32_MAX);
    }
    /** 每个失败都改变观察代次，即使errno相同。代次饱和后永久关闭本实例的扩张和
     * 自动恢复；不能绕回旧数值制造ABA，也不能用超时释放仍未知的存储。
     */
    int RecordFailure(int error) noexcept {
        if (error <= 0) error = EPROTO;
        uint64_t current = expansionState_.load(std::memory_order_relaxed);
        while (true) {
            const uint32_t generation = static_cast<uint32_t>(current >> 32);
            const bool exhausted = generation >= UINT32_MAX - 1;
            const uint64_t next = (uint64_t(exhausted ? UINT32_MAX : generation + 1) << 32) |
                static_cast<uint32_t>(exhausted ? EOVERFLOW : error);
            if (expansionState_.compare_exchange_weak(current, next, std::memory_order_acq_rel))
                return static_cast<int>(next & UINT32_MAX);
        }
    }
    int CheckCold() const noexcept {
        if (detail::forkChild.load(std::memory_order_acquire) ||
            (process_ && getpid() != process_)) return ECHILD;
        return ready_.load(std::memory_order_acquire) ? 0 : EINVAL;
    }
    int CheckHot(const Module* module) const noexcept {
        if (detail::forkChild.load(std::memory_order_acquire)) return ECHILD;
        if (!ready_.load(std::memory_order_acquire) || !module || module->owner != this) return EINVAL;
        return 0;
    }
    static size_t Hash(const Module* module) noexcept {
        const uintptr_t pointer = reinterpret_cast<uintptr_t>(module) >> 4;
        return (pointer ^ (pointer >> 17)) * uintptr_t(0x9e3779b97f4a7c15ULL);
    }
    static bool BlockBytes(size_t memory, size_t alignment, size_t& bytes) noexcept {
        return detail::add(sizeof(Payload), alignment - 1, bytes) && detail::add(bytes, memory ? memory : 1, bytes);
    }
    /** 查找只访问原线程的节点，不读取DSO或初始化模板。recent命中不重复写缓存行。 */
    static Block* Lookup(Arena* arena, Module* module) noexcept {
        if (arena->recentModule == module) return arena->recentBlock;
        if (arena->capacity) for (Block* block = arena->buckets[Hash(module) & (arena->capacity - 1)]; block; block = block->hashNext) {
            if (block->module == module) { arena->recentModule = module; arena->recentBlock = block; return block; }
        }
        return nullptr;
    }
    __attribute__((noinline)) AddressResult AddressSlow(Module* module) noexcept {
        const Result result = Access(module, false);
        return {result.address, result.error};
    }
    void ReleaseLifetime(Module* module) noexcept {
        if (module->references.fetch_sub(1, std::memory_order_acq_rel) != 1) return;
        if (module->retired.load()) retiredModules_.fetch_sub(1);
        modules_.fetch_sub(1); moduleBytes_.fetch_sub(module->allocationSize);
        module->~Module(); functions_.deallocate(module, functions_.context);
    }
    void FreePayload(Payload* payload) noexcept {
        if (!payload) return;
        const size_t bytes = payload->allocationSize;
        payloads_.fetch_sub(1); payloadBytes_.fetch_sub(bytes); storageBytes_.fetch_sub(bytes);
        functions_.deallocate(payload, functions_.context);
    }
    void FreePayloads(Payload* payload) noexcept {
        while (payload) { Payload* next = payload->garbageNext; FreePayload(payload); payload = next; }
    }
    /** registry锁下摘Module链并claim payload。线程自己的hash/allNext/cache在此不修改。 */
    Payload* DetachNodeLocked(Block* block) noexcept {
        Module* module = block->module;
        if (block->modulePrevious) block->modulePrevious->moduleNext = block->moduleNext;
        else module->firstBlock = block->moduleNext;
        if (block->moduleNext) block->moduleNext->modulePrevious = block->modulePrevious;
        block->modulePrevious = nullptr; block->moduleNext = nullptr;
        return block->payload.exchange(nullptr, std::memory_order_acq_rel);
    }
    void FreeNode(Block* block) noexcept {
        Module* module = block->module;
        blocks_.fetch_sub(1); storageBytes_.fetch_sub(sizeof(Block));
        block->~Block(); functions_.deallocate(block, functions_.context); ReleaseLifetime(module);
    }
    int ReleaseExternal(Module* module, bool retireCreator) noexcept {
        int error = CheckCold(); if (!error) error = CheckHot(module); if (error) return error;
        Payload* garbage = nullptr; unsigned char* initial = nullptr;
        {
            detail::Lock lock(registry_); if (lock.error) return lock.error;
            if (!module->externalReferences) return ESTALE;
            if (retireCreator) {
                if (module->retired.exchange(true, std::memory_order_acq_rel)) return EALREADY;
                retiredModules_.fetch_add(1);
            }
            --module->externalReferences; externalReferences_.fetch_sub(1);
            if (!module->externalReferences) {
                // 外部入口关闭不可复活。Block内部refs只维持小型元数据，不能让大payload
                // 或template永久驻留；仍有callback/descriptor时external不为0，不会到这里。
                for (Block* block = module->firstBlock; block; block = block->moduleNext) {
                    if (Payload* payload = block->payload.exchange(nullptr, std::memory_order_acq_rel)) {
                        payload->garbageNext = garbage; garbage = payload;
                        block->arena->hasTombstones.store(true, std::memory_order_release);
                    }
                }
                initial = module->initial; module->initial = nullptr;
            }
        }
        FreePayloads(garbage);
        if (initial) { moduleBytes_.fetch_sub(module->fileSize); functions_.deallocate(initial, functions_.context); }
        ReleaseLifetime(module); return 0; // 此后module可能释放，不能再解引用。
    }
    /** 只由原线程的冷miss执行，回收已无payload的节点，元数据不会随长期churn增长。
     * 不改其它线程表；last-external只把atomic payload置空，直到owner自己看见tombstone。
     */
    int CollectTombstones(Arena* arena) noexcept {
        // 只扫描真正收到退休通知的当前arena；别的线程/模块退休不会迫使本线程扫描，
        // 连续添加仍存活模块也不会累积N²遍历。此通知不进入普通GetBlock热命中。
        if (!arena->hasTombstones.load(std::memory_order_acquire)) return 0;
        Block* garbage = nullptr;
        size_t visited = 0;
        {
            detail::Lock lock(registry_); if (lock.error) return lock.error;
            Block* head = arena->blocks.load(std::memory_order_relaxed);
            Block** all = &head;
            while (*all) {
                Block* block = *all;
                ++visited;
                if (block->payload.load(std::memory_order_acquire)) { all = &block->allNext; continue; }
                DetachNodeLocked(block);
                Block** hash = &arena->buckets[Hash(block->module) & (arena->capacity - 1)];
                while (*hash != block) hash = &(*hash)->hashNext;
                *hash = block->hashNext; *all = block->allNext; --arena->count;
                if (arena->recentBlock == block) { arena->recentBlock = nullptr; arena->recentModule = nullptr; }
                block->hashNext = garbage; garbage = block;
            }
            arena->blocks.store(head, std::memory_order_release);
            // 与最后external释放共用registry锁，本轮全部通知对应的payload置空都已可见。
            // 解锁后的新退休重新置位，由下一次真正的冷miss处理，绝不跨线程改查找表。
            arena->hasTombstones.store(false, std::memory_order_relaxed);
        }
        tombstonePasses_.fetch_add(1, std::memory_order_relaxed);
        tombstoneVisits_.fetch_add(visited, std::memory_order_relaxed);
        while (garbage) { Block* next = garbage->hashNext; FreeNode(garbage); garbage = next; }
        return 0;
    }
    void ReleaseArena(Arena* arena) noexcept {
        if (arena->references.fetch_sub(1, std::memory_order_acq_rel) != 1) return;
        Block* block = arena->blocks.load(std::memory_order_acquire);
        Payload* garbage = nullptr;
        {
            detail::Lock lock(registry_);
            // 正常已初始化的非递归mutex只应成功。若实例寿命/锁完整性已损坏，不能继续
            // free而给Module链留下悬空节点；准确关闭扩张并保留此批内存供上层故障处理。
            if (lock.error) { RecordFailure(lock.error); return; }
            for (Block* item = block; item; item = item->allNext) {
                if (Payload* payload = DetachNodeLocked(item)) { payload->garbageNext = garbage; garbage = payload; }
            }
        }
        FreePayloads(garbage);
        while (block) { Block* next = block->allNext; FreeNode(block); block = next; }
        if (arena->buckets) functions_.deallocate(arena->buckets, functions_.context);
        storageBytes_.fetch_sub(sizeof(Arena) + arena->capacity * sizeof(Block*));
        arenas_.fetch_sub(1); arena->~Arena(); functions_.deallocate(arena, functions_.context);
    }
    void Unlink(Arena* arena) noexcept {
        if (arena->previous) arena->previous->next = arena->next; else first_ = arena->next;
        if (arena->next) arena->next->previous = arena->previous; else last_ = arena->previous;
        arena->registered = false; arena->previous = nullptr; arena->next = nullptr; --registered_;
    }

    /** 仅原线程执行。分配/复制和哈希扩容全部在 registry 锁外；失败不改旧块/旧表。 */
    Block* AddBlock(Arena* arena, Module* module, bool prepared, int& error) noexcept {
        // 已有arena也可能来自fork继承。早于本模块注册的child handler会先于poison执行，
        // 所以新分配这条冷路径必须核PID；已有块热读的该前置窗口仍明确不在完整fork保证内。
        if ((error = CheckCold())) return nullptr;
        if (arena->allocating) { error = EDEADLK; return nullptr; }
        if ((error = ExpansionError())) return nullptr;
        if (arena->nextBlock == UINT64_MAX) { error = EOVERFLOW; return nullptr; }
        arena->allocating = true;
        struct End { Arena* arena; ~End() { arena->allocating = false; } } end{arena};
        if ((error = Retain(module))) return nullptr;
        struct Hold { Coordinator* owner; Module* module; ~Hold() { owner->Release(module); } } hold{this, module};
        if ((error = CollectTombstones(arena))) return nullptr;
        Block** replacement = nullptr;
        size_t capacity = arena->capacity;
        if (!capacity || arena->count >= capacity - capacity / 4) {
            if (capacity > SIZE_MAX / 2 / sizeof(Block*)) { error = EOVERFLOW; return nullptr; }
            capacity = capacity ? capacity * 2 : 16;
            replacement = static_cast<Block**>(functions_.allocate(capacity * sizeof(Block*), functions_.context));
            if (!replacement) { error = ENOMEM; return nullptr; }
            std::memset(replacement, 0, capacity * sizeof(Block*));
        }
        size_t bytes = 0; BlockBytes(module->memorySize, module->alignment, bytes);
        void* rawNode = functions_.allocate(sizeof(Block), functions_.context);
        if (!rawNode) {
            if (replacement) functions_.deallocate(replacement, functions_.context);
            error = ENOMEM; return nullptr;
        }
        void* rawPayload = functions_.allocate(bytes, functions_.context);
        if (!rawPayload) {
            functions_.deallocate(rawNode, functions_.context);
            if (replacement) functions_.deallocate(replacement, functions_.context);
            error = ENOMEM; return nullptr;
        }
        auto* block = new(rawNode) Block;
        auto* payload = new(rawPayload) Payload; payload->allocationSize = bytes;
        if ((error = ExpansionError())) {
            functions_.deallocate(rawPayload, functions_.context);
            block->~Block(); functions_.deallocate(rawNode, functions_.context);
            if (replacement) functions_.deallocate(replacement, functions_.context);
            return nullptr;
        }
        block->generation = ++arena->nextBlock;
        block->module = module; block->arena = arena; block->prepared = prepared;
        const uintptr_t begin = reinterpret_cast<uintptr_t>(payload + 1);
        block->address = reinterpret_cast<void*>((begin + module->alignment - 1) & ~(uintptr_t(module->alignment) - 1));
        std::memset(block->address, 0, module->memorySize);
        if (module->fileSize) std::memcpy(block->address, module->initial, module->fileSize);
        {
            detail::Lock lock(registry_);
            if (lock.error) error = lock.error;
            else if (!module->externalReferences) error = ESTALE;
            else if (module->references.load() == SIZE_MAX) error = EOVERFLOW;
            else {
                // 内部Block ref不增加external；它只让Module元数据在tombstone仍被线程表
                // 引用时存在。payload在完整链上登记后才发布给该线程的查找表。
                module->references.fetch_add(1);
                block->moduleNext = module->firstBlock;
                if (module->firstBlock) module->firstBlock->modulePrevious = block;
                module->firstBlock = block;
                block->payload.store(payload, std::memory_order_release);
                blocks_.fetch_add(1); payloads_.fetch_add(1); payloadBytes_.fetch_add(bytes);
                storageBytes_.fetch_add(sizeof(Block) + bytes);
            }
        }
        if (error) {
            functions_.deallocate(rawPayload, functions_.context);
            block->~Block(); functions_.deallocate(rawNode, functions_.context);
            if (replacement) functions_.deallocate(replacement, functions_.context);
            return nullptr;
        }
        if (replacement) {
            for (Block* item = arena->blocks.load(std::memory_order_relaxed); item; item = item->allNext) {
                const size_t bucket = Hash(item->module) & (capacity - 1);
                item->hashNext = replacement[bucket]; replacement[bucket] = item;
            }
            Block** old = arena->buckets; const size_t oldBytes = arena->capacity * sizeof(Block*);
            arena->buckets = replacement; arena->capacity = capacity;
            storageBytes_.fetch_add(capacity * sizeof(Block*));
            if (old) { functions_.deallocate(old, functions_.context); storageBytes_.fetch_sub(oldBytes); }
        }
        const size_t bucket = Hash(module) & (arena->capacity - 1);
        block->hashNext = arena->buckets[bucket]; arena->buckets[bucket] = block;
        block->allNext = arena->blocks.load(std::memory_order_relaxed); ++arena->count;
        arena->recentModule = module; arena->recentBlock = block;
        arena->blocks.store(block, std::memory_order_release); return block;
    }

    Result Access(Module* module, bool prepared) noexcept {
        Result result;
        if ((result.error = CheckHot(module))) return result;
        auto& slot = detail::slot;
        if (slot.phase == detail::Phase::Constructing) { result.error = EDEADLK; return result; }
        Arena* arena = slot.arena;
        Block* block = nullptr;
        bool created = false;
        if (slot.phase == detail::Phase::Ready) {
            if (slot.owner != this) { result.error = EINVAL; return result; }
            block = Lookup(arena, module);
            if (!block) { block = AddBlock(arena, module, prepared, result.error); created = block != nullptr; }
        } else {
            // 必须在身份查询、分配 hook 或 registry 之前发布“构造中”，同线程重入不能
            // 伪装成“系统TLS为空的新 birth”，从而误回收当前仍活着的线程对象。
            slot = {this, nullptr, detail::Phase::Constructing};
            struct Reset { detail::ThreadSlot& slot; ~Reset() { if (slot.phase == detail::Phase::Constructing) slot = {}; } } reset{slot};
            if ((result.error = CheckCold()) || (result.error = ExpansionError())) return result;
            pid_t process = 0, thread = 0;
            result.error = functions_.identity(process, thread, functions_.context);
            if (!result.error && (process != process_ || thread <= 0)) result.error = ECHILD;
            if (!result.error) result.error = functions_.observe(process, thread, functions_.context);
            if (result.error) { result.error = RecordFailure(result.error); return result; }
            void* raw = functions_.allocate(sizeof(Arena), functions_.context);
            if (!raw) { result.error = ENOMEM; return result; }
            arena = new(raw) Arena; arena->owner = this; arena->process = process; arena->thread = thread;
            arenas_.fetch_add(1); storageBytes_.fetch_add(sizeof(Arena));
            block = AddBlock(arena, module, prepared, result.error);
            if (!block) { ReleaseArena(arena); return result; }
            Arena* replaced = nullptr;
            {
                detail::Lock lock(registry_);
                const int lateError = ExpansionError();
                if (lock.error || nextArena_ == UINT64_MAX || lateError)
                    result.error = lock.error ? lock.error : (nextArena_ == UINT64_MAX ? EOVERFLOW : lateError);
                else {
                    // 相同pid/tid且权威系统TLS确实为空的新注册：原线程不能同时还存在。
                    // 替换只摘这个具体旧对象；其它 sweeper 引用使其元数据延迟到锁外释放。
                    for (Arena* old = first_; old; old = old->next) if (old->process == process && old->thread == thread) { replaced = old; Unlink(old); break; }
                    arena->id = ++nextArena_; arena->registered = true; arena->previous = last_;
                    if (last_) last_->next = arena; else first_ = arena;
                    last_ = arena; ++registered_;
                }
            }
            if (result.error) { ReleaseArena(arena); return result; }
            if (replaced) ReleaseArena(replaced);
            slot = {this, arena, detail::Phase::Ready}; created = true;
        }
        if (!block) return result;
        if (!block->payload.load(std::memory_order_acquire)) { result.error = ESTALE; return result; }
        if (!prepared) block->prepared = false;
        arena->recentModule = module; arena->recentBlock = block;
        result.address = block->address; result.arenaGeneration = arena->id;
        if (prepared && created) {
            result.rollback.arena_ = arena; result.rollback.block_ = block;
            result.rollback.arenaId_ = arena->id; result.rollback.moduleId_ = module->id;
            result.rollback.blockId_ = block->generation;
        }
        return result;
    }

    Functions functions_{};
    pid_t process_ = 0;
    std::atomic<bool> ready_{false};
    std::atomic<uint64_t> expansionState_{0}; // 高32位失败代次，低32位errno；一次CAS避免错误状态ABA。
    pthread_mutex_t registry_ = PTHREAD_MUTEX_INITIALIZER;
    Arena* first_ = nullptr;
    Arena* last_ = nullptr;
    uint64_t nextArena_ = 0;
    size_t registered_ = 0;
    std::atomic<uint64_t> nextModule_{0};
    std::atomic<size_t> arenas_{0}, blocks_{0}, storageBytes_{0}, modules_{0}, moduleBytes_{0}, retiredModules_{0};
    std::atomic<size_t> payloads_{0}, payloadBytes_{0}, externalReferences_{0};
    std::atomic<size_t> tombstonePasses_{0}, tombstoneVisits_{0};
};
} // namespace amcl::tlsstorage
#endif
