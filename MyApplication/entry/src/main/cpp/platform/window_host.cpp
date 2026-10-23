// window_host.cpp — libamcl_window_host：进程唯一的 NativeWindow 发布 owner 与租约 broker。
//
// 同一个 DSO 可能被不同 linker namespace 各装入一份（libentry 依赖的一份、JVM 装入的一份）。
// 第一份发布 surface 的映像成为进程 owner：它把 owner 函数表与 v2 broker 的地址写进两个
// 进程常量环境描述符（AMCL_WINDOW_HOST_OWNER / AMCL_NATIVE_WINDOW_LEASE_BROKER），其他映像
// 解析描述符后把全部调用转发给 owner，保证只有一份租约账本和一把发布锁。
//
// 环境纪律（I27-05）：
//   - 两个描述符在进程内只写一次（publishOwner 的 ownerPublished 标志），正常流程由 libentry
//     在首个 NAPI 模块初始化时经 amclWindowHostPublishOwner 提前写入，早于任何游戏/JVM 线程；
//   - owner()/resolveBroker() 处在 GLFW 每帧的 poll/swap/make-current 热路径上，只缓存本 PID
//     “已发布且校验通过”的解析结果，缺席/畸形/继承自父进程的结果不缓存；
//   - surface 状态只经 broker/快照 API 读取，不再镜像到任何环境变量。
// fork 子进程：processId() 变化后 runtime()/localOwnerApi() 各自换成新对象，缓存按 PID 失效，
// 继承来的描述符因 PID 不符被当作 kInherited，子进程从未发布状态开始。
//
// 输入前台位（broker 的 peekInputForeground 尾部）：XComponent 门禁的计算结果经
// amclWindowHostSetInputForeground 转发给 owner 映像的 Runtime 原子量；消费者（SDL 每次
// pump/swap/make-current）经已缓存的 broker 指针做一次 acquire 读，替代逐帧 getenv。
#include "window_host.h"
#include "window_host_core.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif
#if !defined(AMCL_WINDOW_HOST_TESTING)
#include <native_window/external_window.h>
#endif

namespace {
using amcl::window::NativeReferenceDriver;
using amcl::window::WindowHostCore;
constexpr const char* kOwnerEnv = "AMCL_WINDOW_HOST_OWNER";
#if defined(AMCL_WINDOW_HOST_TESTING)
std::atomic<uint64_t> testPid{0};
#endif
uint64_t processId() {
#if defined(AMCL_WINDOW_HOST_TESTING)
    if (const uint64_t injected = testPid.load(std::memory_order_acquire)) return injected;
#endif
#ifdef _WIN32
    return static_cast<uint64_t>(_getpid());
#else
    return static_cast<uint64_t>(getpid());
#endif
}
// 只被 publishOwner 调用，写两个进程常量描述符；调用受 ownerPublicationMutex 串行化且每进程一次。
void publishEnv(const char* name, const char* value) {
#ifdef _WIN32
    _putenv_s(name, value);
#else
    setenv(name, value, 1);
#endif
}
int nativeReference(void* window, void*) {
#if defined(AMCL_WINDOW_HOST_TESTING)
    (void)window;
    return -1;
#else
    return OH_NativeWindow_NativeObjectReference(window);
#endif
}
int nativeUnreference(void* window, void*) {
#if defined(AMCL_WINDOW_HOST_TESTING)
    (void)window;
    return -1;
#else
    return OH_NativeWindow_NativeObjectUnreference(window);
#endif
}
struct Runtime {
    const uint64_t pid = processId();
    std::mutex ownerPublicationMutex;
    bool ownerPublished = false;
    // 宿主输入前台门禁的最新值（0/1）。写者只有 owner 映像的 localSetInputForeground
    // （XComponent 门禁锁内，UI 线程），读者是 broker 尾部的无锁 peek；单个 32 位原子量，
    // release/acquire 配对即可让读者看到写入前的门禁状态，不需要额外的锁或代次。
    std::atomic<uint32_t> inputForeground{0u};
    WindowHostCore core{NativeReferenceDriver{nativeReference, nativeUnreference, nullptr}};
};
Runtime& runtime() {
    // Never touch mutexes or native handles inherited from a different PID.
    // The old allocation belongs to the parent; the child starts unpublished.
    static std::atomic<Runtime*> slot{new Runtime};
    auto* current = slot.load(std::memory_order_acquire);
    if (current->pid != processId()) {
        auto* replacement = new Runtime;
        if (!slot.compare_exchange_strong(current, replacement, std::memory_order_acq_rel)) delete replacement;
        else current = replacement;
    }
    return *current;
}

int localAcquire(void* retained, uint64_t generation, void** window, int* width, int* height, uint64_t* published) {
    return runtime().core.acquire(retained, generation, window, width, height, published);
}
void localRelease(void* window) { runtime().core.release(window); }
int localBeginInput(int* width, int* height, uint64_t* generation) { return runtime().core.beginInputPublication(width, height, generation); }
void localEndInput() { runtime().core.endInputPublication(); }
uint64_t localPeekGeneration() { return runtime().core.peekGeneration(); }
AmclNativeWindowPublicationState localPeekState() { return runtime().core.peekState(); }
int localClaim(void* window, uint64_t generation, uint32_t api, uint64_t* token) {
    return runtime().core.claimPresentation(window, generation, api, token);
}
int localMove(uint64_t token, void* window, uint64_t generation) { return runtime().core.movePresentation(token, window, generation); }
int localReleasePresentation(uint64_t token) { return runtime().core.releasePresentation(token); }
int localAcquireIdentity(void* retained, uint64_t generation, AmclNativeWindowIdentityV1* identity) {
    return runtime().core.acquireIdentity(retained, generation, identity);
}
int localMoveGeometry(uint64_t token, void* window, uint64_t previous, uint64_t generation, uint64_t resourceEpoch) {
    return runtime().core.movePresentationGeometry(token, window, previous, generation, resourceEpoch);
}
// broker 尾部：本映像（即 owner，broker 表只从 owner 发布）的前台位。只读一个原子量，
// 可在任意线程逐帧调用；fork 子进程经 runtime() 换成新对象后从 0 开始。
uint32_t localPeekInputForeground() { return runtime().inputForeground.load(std::memory_order_acquire); }
// owner 表里的写入口：把任意非零值规范成 1，保证读者只见到 ABI 声明的 0/1 两个值。
int localSetInputForeground(int foreground) {
    runtime().inputForeground.store(foreground != 0 ? 1u : 0u, std::memory_order_release);
    return 1;
}
const AmclNativeWindowLeaseBrokerV2 kLocalBroker{
    AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION, sizeof(AmclNativeWindowLeaseBrokerV2),
    localAcquire, localRelease, localBeginInput, localEndInput, localPeekGeneration, localPeekState,
    localClaim, localMove, localReleasePresentation, localAcquireIdentity, localMoveGeometry,
    localPeekInputForeground
};

uint64_t localPublish(void*, int, int, AmclWindowHostCommitFn, void*);
uint64_t localUpdate(void* window, uint64_t generation, int width, int height) { return runtime().core.updateSize(window, generation, width, height); }
uint64_t localClear(void* window, uint64_t generation) { return runtime().core.clear(window, generation); }
int localRead(AmclWindowHostSnapshot* snapshot) {
    if (!snapshot) return 0;
    *snapshot = runtime().core.snapshot();
    return snapshot->state == AMCL_NATIVE_WINDOW_PUBLICATION_READY ? 1 : 0;
}
void localStats(AmclWindowHostStats* stats) { if (stats) *stats = runtime().core.stats(); }
int localRetry() { return runtime().core.retryRetiredReferences() ? 1 : 0; }
const AmclNativeWindowLeaseBrokerV2* localBroker() { return &kLocalBroker; }
#if defined(AMCL_WINDOW_HOST_TESTING)
int localSetDriver(AmclWindowHostReferenceFn reference, AmclWindowHostReferenceFn unreference, void* context) {
    return runtime().core.setReferenceDriver({reference, unreference, context}) ? 1 : 0;
}
#endif
struct OwnerApi {
    uint32_t version;
    uint32_t size;
    uint64_t pid;
    decltype(&localPublish) publish;
    decltype(&localUpdate) update;
    decltype(&localClear) clear;
    decltype(&localRead) read;
    decltype(&localStats) stats;
    decltype(&localRetry) retry;
    decltype(&localBroker) broker;
    // 前台位写入口：非 owner 映像经此转发，保证 broker 尾部读到的是唯一一份门禁状态。
    decltype(&localSetInputForeground) setInputForeground;
#if defined(AMCL_WINDOW_HOST_TESTING)
    decltype(&localSetDriver) setDriver;
#endif
};
OwnerApi& localOwnerApi() {
    static std::atomic<OwnerApi*> slot{new OwnerApi{1, sizeof(OwnerApi), processId(),
        localPublish, localUpdate, localClear, localRead, localStats, localRetry, localBroker,
        localSetInputForeground
#if defined(AMCL_WINDOW_HOST_TESTING)
        , localSetDriver
#endif
    }};
    auto* api = slot.load(std::memory_order_acquire);
    if (api->pid != processId()) {
        auto* replacement = new OwnerApi(*api);
        replacement->pid = processId();
        if (!slot.compare_exchange_strong(api, replacement, std::memory_order_acq_rel)) delete replacement;
        else api = replacement;
    }
    return *api;
}
enum class OwnerStatus { kAbsent, kLocal, kRemote, kInherited, kMalformed };
struct OwnerResolution { const OwnerApi* api; OwnerStatus status; };

// 已验证解析的每 PID 缓存。写者先存数据再以 release 存 PID，读者以 acquire 读 PID 后才取数据；
// 并发的两次成功解析写入的是同一组值（描述符每进程只发布一次），因此不需要锁。
// 常量初始化（atomic 的 constexpr 构造），不依赖跨 TU 的静态初始化顺序。
struct ResolutionCache {
    std::atomic<uint64_t> ownerPid{0};
    std::atomic<const OwnerApi*> ownerApi{nullptr};
    std::atomic<int> ownerStatus{0};
    std::atomic<uint64_t> brokerPid{0};
    std::atomic<const AmclNativeWindowLeaseBrokerV2*> broker{nullptr};
};
ResolutionCache g_resolutionCache;

// 纯解析：每次都读环境，失败语义与原实现逐条一致（畸形 → nullptr 失败关闭，PID 不符 → 本地）。
OwnerResolution parseOwner(uint64_t currentPid) {
    const char* encoded = std::getenv(kOwnerEnv);
    if (!encoded || !*encoded) return {&localOwnerApi(), OwnerStatus::kAbsent};
    unsigned long long pid = 0;
    void* address = nullptr;
    int consumed = 0;
    if (std::sscanf(encoded, "%llu:%p%n", &pid, &address, &consumed) != 2 || encoded[consumed] != '\0' || !address)
        return {nullptr, OwnerStatus::kMalformed};
    if (pid != currentPid) return {&localOwnerApi(), OwnerStatus::kInherited};
    const auto* api = static_cast<const OwnerApi*>(address);
    if (api->version != 1 || api->size < sizeof(OwnerApi) || api->pid != currentPid ||
        !api->publish || !api->update || !api->clear || !api->read || !api->stats || !api->retry || !api->broker ||
        !api->setInputForeground)
        return {nullptr, OwnerStatus::kMalformed};
    return {api, api == &localOwnerApi() ? OwnerStatus::kLocal : OwnerStatus::kRemote};
}
// 只有“本 PID 已发布且表校验通过”（kLocal/kRemote）才进缓存：缺席时稍后可能由本映像或
// 另一映像发布，畸形时必须每次失败关闭，继承态会在子进程自己发布后变成 kLocal。
OwnerResolution owner() {
    const uint64_t pid = processId();
    if (g_resolutionCache.ownerPid.load(std::memory_order_acquire) == pid) {
        return {g_resolutionCache.ownerApi.load(std::memory_order_relaxed),
                static_cast<OwnerStatus>(g_resolutionCache.ownerStatus.load(std::memory_order_relaxed))};
    }
    const OwnerResolution resolved = parseOwner(pid);
    if (resolved.status == OwnerStatus::kLocal || resolved.status == OwnerStatus::kRemote) {
        g_resolutionCache.ownerApi.store(resolved.api, std::memory_order_relaxed);
        g_resolutionCache.ownerStatus.store(static_cast<int>(resolved.status), std::memory_order_relaxed);
        g_resolutionCache.ownerPid.store(pid, std::memory_order_release);
    }
    return resolved;
}
bool validBroker(const AmclNativeWindowLeaseBrokerV2* broker) {
    if (!broker || broker->abiVersion != AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION ||
        broker->structSize < AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_CORE_SIZE || !broker->acquire || !broker->release ||
        !broker->beginInputPublication || !broker->endInputPublication) return false;
    return broker->structSize < AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PEEK_SIZE || (broker->peekGeneration && broker->peekState);
}
void cacheBroker(uint64_t pid, const AmclNativeWindowLeaseBrokerV2* broker) {
    g_resolutionCache.broker.store(broker, std::memory_order_relaxed);
    g_resolutionCache.brokerPid.store(pid, std::memory_order_release);
}
// 缓存条件同 owner()：只有已发布 owner（kLocal/kRemote）且 broker 与 owner 一致时才缓存。
// 旧 ABI 只有 broker 描述符的情形（owner 缺席）仍逐次解析，保持可消费但不固化。
const AmclNativeWindowLeaseBrokerV2* resolveBroker() {
    const uint64_t pid = processId();
    if (g_resolutionCache.brokerPid.load(std::memory_order_acquire) == pid) {
        return g_resolutionCache.broker.load(std::memory_order_relaxed);
    }
    const auto resolved = owner();
    if (!resolved.api) return nullptr;
    if (resolved.status == OwnerStatus::kInherited) return &kLocalBroker;
    const bool ownerPublished = resolved.status != OwnerStatus::kAbsent;
    const char* encoded = std::getenv(AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV);
    if (!encoded || !*encoded) {
        const auto* local = resolved.api->broker();
        if (ownerPublished) cacheBroker(pid, local);
        return local;
    }
    unsigned version = 0;
    void* address = nullptr;
    int consumed = 0;
    if (std::sscanf(encoded, "%u:%p%n", &version, &address, &consumed) != 2 || encoded[consumed] != '\0' ||
        version != AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION || !address) return nullptr;
    const auto* broker = static_cast<const AmclNativeWindowLeaseBrokerV2*>(address);
    if (!validBroker(broker)) return nullptr;
    // 旧 ABI 描述符仍可消费；新式 owner 描述符必须与已发布 broker 一致，绝不拆分所有权。
    if (ownerPublished && broker != resolved.api->broker()) return nullptr;
    if (ownerPublished) cacheBroker(pid, broker);
    return broker;
}
bool publishOwner() {
    auto& state = runtime();
    std::lock_guard<std::mutex> lock(state.ownerPublicationMutex);
    const auto resolved = owner();
    if (!resolved.api || resolved.status == OwnerStatus::kRemote) return false;
    // 一次性守卫：描述符是进程常量，已发布就不再写环境（I27-05）。
    if (state.ownerPublished) return true;
    // 已存在的 broker 描述符属于一个不提供新 owner 表的旧 owner，重复映像绝不覆盖它。
    // 例外是 fork 子进程：继承的描述符 PID 不同，runtime() 已为子进程换成全新的 owner。
    if (resolved.status != OwnerStatus::kInherited) {
        const char* existing = std::getenv(AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV);
        if (existing && *existing) return false;
    }
    char encoded[96];
    // 保持既有 v2 线格式 "2:%p"，SDL 等消费者已按它解析。先 broker 后 owner：看见 owner 的
    // 读者一定也能解析到一致的 broker。
    std::snprintf(encoded, sizeof(encoded), "%u:%p", AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION,
        static_cast<const void*>(&kLocalBroker));
    publishEnv(AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV, encoded);
    std::snprintf(encoded, sizeof(encoded), "%llu:%p", static_cast<unsigned long long>(processId()),
        static_cast<const void*>(&localOwnerApi()));
    publishEnv(kOwnerEnv, encoded);
    state.ownerPublished = true;
    return true;
}
uint64_t localPublish(void* window, int width, int height, AmclWindowHostCommitFn callback, void* context) {
    if (!publishOwner()) return 0;
    // 本映像已发布后，若解析出的 broker 不是本映像的，说明所有权被拆分；在描述符恢复一致前
    // 拒绝推进私有 core。缓存只记录本 PID 首次通过校验的结果，所以此检查针对的是首次解析。
    if (runtime().ownerPublished && resolveBroker() != &kLocalBroker) return 0;
    return runtime().core.publish(window, width, height, callback, context);
}
}

extern "C" {
uint64_t amclWindowHostNextGeneration(uint64_t current) { return current == UINT64_MAX ? 0 : current + 1; }
uint64_t amclWindowHostPublish(void* window, int width, int height, AmclWindowHostCommitFn callback, void* context) {
    const auto resolved = owner();
    return resolved.api ? resolved.api->publish(window, width, height, callback, context) : 0;
}
uint64_t amclWindowHostUpdateSize(void* window, uint64_t generation, int width, int height) {
    const auto resolved = owner();
    return resolved.api && resolveBroker() ? resolved.api->update(window, generation, width, height) : 0;
}
uint64_t amclWindowHostClear(void* window, uint64_t generation) {
    const auto resolved = owner();
    return resolved.api && resolveBroker() ? resolved.api->clear(window, generation) : 0;
}
int amclWindowHostReadSnapshot(AmclWindowHostSnapshot* snapshot) {
    if (!snapshot) return 0;
    *snapshot = {};
    const auto resolved = owner();
    return resolved.api ? resolved.api->read(snapshot) : 0;
}
uint64_t amclWindowHostPeekGeneration(void) {
    const auto* broker = resolveBroker();
    return broker && broker->structSize >= AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PEEK_SIZE && broker->peekGeneration ? broker->peekGeneration() : 0;
}
AmclNativeWindowPublicationState amclWindowHostPeekState(void) {
    const auto* broker = resolveBroker();
    return broker && broker->structSize >= AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PEEK_SIZE && broker->peekState ? broker->peekState() : AMCL_NATIVE_WINDOW_PUBLICATION_UNPUBLISHED;
}
const AmclNativeWindowLeaseBrokerV2* amclWindowHostGetBroker(void) { return resolveBroker(); }
int amclWindowHostAcquire(void* retained, uint64_t generation, void* retainedBroker,
    void** window, int* width, int* height, uint64_t* published, void** outBroker) {
    if (window) *window = nullptr;
    if (width) *width = 0;
    if (height) *height = 0;
    if (published) *published = 0;
    if (outBroker) *outBroker = nullptr;
    if (!window || !outBroker) return 0;
    const auto* broker = resolveBroker();
    if (!broker) { if (published) *published = UINT64_MAX; return 0; }
    const bool reuse = retained && retainedBroker == broker;
    const int result = broker->acquire(reuse ? retained : nullptr, reuse ? generation : 0, window, width, height, published);
    if (result == 1) *outBroker = const_cast<AmclNativeWindowLeaseBrokerV2*>(broker);
    return result;
}
void amclWindowHostRelease(void* window, void* rawBroker) {
    const auto* broker = static_cast<const AmclNativeWindowLeaseBrokerV2*>(rawBroker);
    if (window && validBroker(broker)) broker->release(window);
}
int amclWindowHostBeginInputPublication(int* width, int* height, uint64_t* generation, void** outBroker) {
    if (width) *width = 0;
    if (height) *height = 0;
    if (generation) *generation = 0;
    if (outBroker) *outBroker = nullptr;
    if (!outBroker) return 0;
    const auto* broker = resolveBroker();
    if (!broker || !broker->beginInputPublication(width, height, generation)) return 0;
    *outBroker = const_cast<AmclNativeWindowLeaseBrokerV2*>(broker);
    return 1;
}
void amclWindowHostEndInputPublication(void* rawBroker) {
    const auto* broker = static_cast<const AmclNativeWindowLeaseBrokerV2*>(rawBroker);
    if (validBroker(broker)) broker->endInputPublication();
}
void amclWindowHostGetStats(AmclWindowHostStats* stats) {
    if (!stats) return;
    *stats = {};
    const auto resolved = owner();
    if (resolved.api) resolved.api->stats(stats);
}
int amclWindowHostRetryRetiredReferences(void) {
    const auto resolved = owner();
    return resolved.api ? resolved.api->retry() : 0;
}
// 提前发布进程 owner 描述符（I27-05）：与首次 amclWindowHostPublish 内部走同一个 publishOwner()
// （同一把锁、同一次性标志），因此之后的 surface 发布不再写环境。只应由 XComponent 所在映像
// （libentry 的直接依赖）在任何游戏/JVM 线程出现之前调用。
int amclWindowHostPublishOwner(void) { return publishOwner() ? 1 : 0; }
// 前台位写入：与 publish/update 同样经 owner() 转发，owner 未发布时写本映像（它随后发布时
// 就是 owner）；畸形描述符失败关闭返回 0。不写环境、不加宿主发布锁，调用方自己的门禁锁
// 已经串行化“计算 + 发布”。
int amclWindowHostSetInputForeground(int foreground) {
    const auto resolved = owner();
    return resolved.api ? resolved.api->setInputForeground(foreground) : 0;
}
#if defined(AMCL_WINDOW_HOST_TESTING)
int amclWindowHostSetReferenceDriver(AmclWindowHostReferenceFn reference, AmclWindowHostReferenceFn unreference, void* context) {
    const auto resolved = owner();
    return resolved.api && resolved.api->setDriver ? resolved.api->setDriver(reference, unreference, context) : 0;
}
void amclWindowHostTestOverridePid(uint64_t pid) { testPid.store(pid, std::memory_order_release); }
#endif
}
