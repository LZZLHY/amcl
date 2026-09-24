// 一个进程只发布一份观测/呈现owner。图形边界先记录真实帧，再分发输入屏障；输入
// 未激活、观测采样关闭或采集锁竞争均不得抹去已经成功呈现的事实。
#include "graphics_observation_abi.h"
#include "graphics_observation_core.h"
#include "graphics_runtime_binding.h"
#include "window_host.h"
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <sstream>
#include <unistd.h>

namespace {
struct Observation {
    const uint64_t pid = static_cast<uint64_t>(getpid());
    const bool enabled = !std::getenv("AMCL_GRAPHICS_OBSERVATION") || std::strcmp(std::getenv("AMCL_GRAPHICS_OBSERVATION"), "0") != 0;
    const bool costEnabled = std::getenv("AMCL_GRAPHICS_OBSERVATION_COST") && std::strcmp(std::getenv("AMCL_GRAPHICS_OBSERVATION_COST"), "1") == 0;
    std::atomic<uint64_t> totalFrames{0}, totalSwapFailures{0}, dropped{0}, costNs{0}, costMaxNs{0}, costCount{0};
    std::atomic<unsigned> provider{0};
    std::atomic<AmclGraphicsPresentSinkV1> inputSinks[3]{};
    uint64_t lossSeen = 0;
    std::mutex mutex;
    amcl::graphics::GraphicsObservationCore frames;
    uint64_t failureSequence = 0, failureGeneration = 0, failurePresentCount = 0;
    uint32_t failureCode = 0;
    std::string failureStage;
};
Observation& local() {
    static std::atomic<Observation*> value{new Observation};
    auto* observed = value.load(std::memory_order_acquire);
    if (observed->pid != static_cast<uint64_t>(getpid())) {
        auto* next = new Observation;
        if (value.compare_exchange_strong(observed, next, std::memory_order_acq_rel)) observed = next;
        else delete next;
    }
    return *observed;
}
uint64_t nowNs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
std::string token(const char* text) {
    std::string value;
    if (text) for (const char* p = text; *p && value.size() < 64; ++p)
        value.push_back((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
            (*p >= '0' && *p <= '9') || *p == '-' || *p == '_' || *p == '.' ? *p : '_');
    return value;
}
unsigned providerId(const char* name) {
    return name && std::strcmp(name, "GLFW") == 0 ? 1u : name && std::strcmp(name, "SDL3") == 0 ? 2u : 0u;
}
const std::string& providerName(unsigned id) {
    static const std::string names[] = {"UNKNOWN", "GLFW", "SDL3"};
    return names[id <= 2 ? id : 0];
}
// 成功swap与既有present通知在同一渲染线程顺序发生。TLS暂存耗时，将正常帧合并为一次短锁。
struct PendingSwap { uint64_t elapsed = 0; unsigned provider = 0; bool ready = false; };
thread_local PendingSwap pending;
void recordCost(Observation& state, uint64_t started) {
    if (!state.costEnabled) return;
    const uint64_t cost = nowNs() - started;
    state.costNs.fetch_add(cost, std::memory_order_relaxed); state.costCount.fetch_add(1, std::memory_order_relaxed);
    auto maximum = state.costMaxNs.load(std::memory_order_relaxed);
    while (cost > maximum && !state.costMaxNs.compare_exchange_weak(maximum, cost, std::memory_order_relaxed)) {}
}
void presentedAt(const char* provider, uint64_t generation) {
    auto& state = local(); const unsigned source = providerId(provider);
    // “已出帧”是恢复策略的安全事实，关闭统计或丢样都不能丢失这个独立原子计数。
    state.totalFrames.fetch_add(1, std::memory_order_relaxed); state.provider.store(source, std::memory_order_relaxed);
    if (!state.enabled) { pending.ready = false; return; }
    const uint64_t now = nowNs();
    if (!generation) generation = amclWindowHostPeekGeneration();
    std::unique_lock<std::mutex> lock(state.mutex, std::try_to_lock);
    if (!lock.owns_lock()) {
        state.dropped.fetch_add(1, std::memory_order_relaxed); pending.ready = false; recordCost(state, now); return;
    }
    const uint64_t lost = state.dropped.load(std::memory_order_relaxed);
    if (lost != state.lossSeen) { state.frames.resetSegment(); state.lossSeen = lost; }
    if (pending.ready && pending.provider == source) state.frames.swapped(pending.elapsed, true);
    pending.ready = false;
    state.frames.presented(now, generation, providerName(source));
    lock.unlock(); recordCost(state, now);
}
// 保留旧的纯观测前缀，旧调用者已经自行通知输入，不能让它被再次分发。
void presented(const char* provider) { presentedAt(provider, 0); }
void dispatchPresent(const char* provider, uint64_t window, uint64_t generation) {
    const unsigned source = providerId(provider);
    if (!source) return;
    presentedAt(provider, generation);
    if (const auto sink = local().inputSinks[source].load(std::memory_order_acquire)) sink(window, generation);
}
// 唯一输入owner只发布一次；同指针重复注册幂等，不允许另一个映像覆盖活动订阅者。
int registerPresentSink(const char* provider, AmclGraphicsPresentSinkV1 sink) {
    const unsigned source = providerId(provider);
    if (!source || !sink) return 0;
    auto& slot = local().inputSinks[source];
    AmclGraphicsPresentSinkV1 previous = nullptr;
    return slot.compare_exchange_strong(previous, sink, std::memory_order_release, std::memory_order_acquire) || previous == sink;
}
void swapped(const char* provider, uint64_t elapsed, int success, uint32_t) {
    auto& state = local();
    // swap失败属于生命周期事实，不随采样开关和采集锁竞争丢失；统计耗时仍允许丢样。
    if (!success) state.totalSwapFailures.fetch_add(1, std::memory_order_relaxed);
    if (!state.enabled) return;
    if (success) { pending = {elapsed, providerId(provider), true}; return; }
    pending.ready = false;
    std::unique_lock<std::mutex> lock(state.mutex, std::try_to_lock);
    if (lock.owns_lock()) state.frames.swapped(elapsed, false);
    else state.dropped.fetch_add(1, std::memory_order_relaxed);
}
void fatal(const char* stage, uint32_t code, uint64_t generation) {
    auto& state = local(); std::lock_guard<std::mutex> lock(state.mutex);
    // 保留本局第一个致命错误，后续 teardown 错误不能覆盖根因或重新开放重试窗口。
    if (state.failureSequence) return;
    state.failureSequence = 1; state.failureStage = token(stage); state.failureCode = code;
    state.failureGeneration = generation; state.failurePresentCount = state.totalFrames.load(std::memory_order_relaxed);
}
void foreground(int visible) {
    auto& state = local(); std::lock_guard<std::mutex> lock(state.mutex);
    state.frames.setForeground(visible != 0);
}
const char* snapshot(int failuresOnly) {
    static thread_local std::string json;
    auto& state = local(); std::unique_lock<std::mutex> lock(state.mutex);
    // 既有 UI 心跳只询问致命故障，正常帧不做分位数排序或 JSON 分配。
    if (failuresOnly && !state.failureSequence) return "";
    // 锁内只复制固定大小快照；分位数排序与JSON分配全部在锁外、调用采集端的线程执行。
    const auto f = state.frames;
    const auto failureSequence = state.failureSequence, failureGeneration = state.failureGeneration,
        failurePresentCount = state.failurePresentCount;
    const auto failureCode = state.failureCode;
    const std::string failureStage = state.failureStage;
    const auto totalFrames = state.totalFrames.load(std::memory_order_relaxed);
    const auto provider = state.provider.load(std::memory_order_relaxed);
    lock.unlock();
    const auto* runtime = amcl::graphics::BoundGraphicsRuntime();
    const char* profile = runtime ? runtime->profile->id : "UNKNOWN";
    std::ostringstream out;
    out << "{\"schemaVersion\":1,\"pid\":" << state.pid << ",\"profile\":\"" << profile
        << "\",\"apiFamily\":\"" << (runtime ? runtime->profile->api : "UNKNOWN")
        << "\",\"provider\":\"" << providerName(provider) << "\",\"presentCount\":" << totalFrames
        << ",\"surfaceGeneration\":" << f.generation << ",\"foreground\":" << (f.foreground ? "true" : "false")
        << ",\"intervalSamples\":" << f.intervalCount << ",\"sampleWindow\":" << std::min<uint64_t>(f.intervalCount, f.capacity)
        << ",\"frameP50Us\":" << f.percentile(f.intervals, f.intervalCount, 50)
        << ",\"frameP95Us\":" << f.percentile(f.intervals, f.intervalCount, 95)
        << ",\"frameP99Us\":" << f.percentile(f.intervals, f.intervalCount, 99)
        << ",\"long50ms\":" << f.long50 << ",\"long100ms\":" << f.long100 << ",\"long1000ms\":" << f.long1000
        << ",\"boundaryResets\":" << f.boundaries << ",\"swapSamples\":" << f.swapCount
        << ",\"segment\":" << f.segment
        << ",\"swapFailures\":" << state.totalSwapFailures.load(std::memory_order_relaxed)
        << ",\"swapP95Us\":" << f.percentile(f.swapTimes, f.swapCount, 95)
        << ",\"gpuTimeUs\":null,\"cpuRenderTimeUs\":null,\"uploadTimeUs\":null"
        << ",\"samplesEnabled\":" << (state.enabled ? "true" : "false")
        << ",\"sampledPresentCount\":" << f.frames << ",\"droppedSamples\":" << state.dropped.load(std::memory_order_relaxed)
        << ",\"observerCostEnabled\":" << (state.costEnabled ? "true" : "false")
        << ",\"observerCostSamples\":" << state.costCount.load(std::memory_order_relaxed)
        << ",\"observerCostTotalNs\":" << (state.costEnabled ? std::to_string(state.costNs.load(std::memory_order_relaxed)) : "null")
        << ",\"observerCostMaxNs\":" << (state.costEnabled ? std::to_string(state.costMaxNs.load(std::memory_order_relaxed)) : "null")
        << ",\"measurementScope\":\"present-interval-and-swap-call\",\"failureSequence\":" << failureSequence
        << ",\"failureStage\":\"" << failureStage << "\",\"failureCode\":" << failureCode
        << ",\"failureGeneration\":" << failureGeneration << ",\"failurePresentCount\":" << failurePresentCount
        << ",\"features\":" << (runtime ? amcl::graphics::GraphicsFeaturesJson(*runtime) : "null") << '}';
    json = out.str(); return json.c_str();
}
const AmclGraphicsObserverV1* descriptor() {
    static std::atomic<const AmclGraphicsObserverV1*> cached{nullptr};
    const auto* previous = cached.load(std::memory_order_acquire);
    if (previous && previous->processId == static_cast<uint64_t>(getpid())) return previous;
    // 描述符不可变、进程期保留；不同 PID 的旧地址不解引用，防止 fork 错借父对象。
    const char* encoded = std::getenv(AMCL_GRAPHICS_OBSERVER_ENV);
    if (!encoded || !*encoded) return nullptr;
    unsigned long long pid = 0; void* address = nullptr; int consumed = 0;
    if (std::sscanf(encoded, "1:%llu:%p%n", &pid, &address, &consumed) != 2 ||
        encoded[consumed] || pid != static_cast<uint64_t>(getpid()) || !address) return nullptr;
    const auto* value = static_cast<const AmclGraphicsObserverV1*>(address);
    if (value->abiVersion != 1 || value->structSize < offsetof(AmclGraphicsObserverV1, samplesEnabled) || value->processId != pid ||
        !value->presented || !value->swapped || !value->fatal || !value->foreground || !value->snapshot) return nullptr;
    cached.store(value, std::memory_order_release);
    return value;
}
int enabled() { return local().enabled ? 1 : 0; }
}
extern "C" int amclGraphicsPublishObserverV1() {
    if (descriptor()) return 1;
    auto* value = new AmclGraphicsObserverV1{sizeof(AmclGraphicsObserverV1), 1u,
        static_cast<uint64_t>(getpid()), presented, swapped, fatal, foreground, snapshot, enabled,
        dispatchPresent, registerPresentSink};
    char encoded[96]; std::snprintf(encoded, sizeof(encoded), "1:%llu:%p",
        static_cast<unsigned long long>(value->processId), static_cast<void*>(value));
    // 每PID竞争一个owner，再发布给旧固定键消费者。即使fork继承旧键或同时从两个映像发布，
    // 当前PID的竞争也只产生一个赢家；不能用两个各自的mutex假装跨namespace串行。
    const std::string ownerKey = "AMCL_GRAPHICS_OBSERVER_OWNER_" + std::to_string(getpid());
    if (setenv(ownerKey.c_str(), encoded, 0) != 0) { delete value; return 0; }
    const char* winner = std::getenv(ownerKey.c_str());
    const bool owns = winner && std::strcmp(winner, encoded) == 0;
    if (!owns) delete value;
    if (!winner || setenv(AMCL_GRAPHICS_OBSERVER_ENV, winner, 1) != 0) return 0;
    const auto* api = descriptor(); if (!api) return 0;
    const char* visible = std::getenv("AMCL_GRAPHICS_FOREGROUND");
    if (visible) api->foreground(std::strcmp(visible, "0") != 0);
    return 1;
}
extern "C" void amclGraphicsPresentedV1(const char* provider) { if (const auto* api = descriptor()) api->presented(provider); }
extern "C" int amclGraphicsDispatchPresentV1(const char* provider, uint64_t window, uint64_t generation) {
    const auto* api = descriptor();
    if (!api || api->structSize < sizeof(AmclGraphicsObserverV1) || !api->dispatchPresent) return 0;
    api->dispatchPresent(provider, window, generation); return 1;
}
extern "C" int amclGraphicsRegisterPresentSinkV1(const char* provider, AmclGraphicsPresentSinkV1 sink) {
    const auto* api = descriptor();
    return api && api->structSize >= sizeof(AmclGraphicsObserverV1) && api->registerPresentSink
        ? api->registerPresentSink(provider, sink) : 0;
}
extern "C" void amclGraphicsSwapV1(const char* provider, uint64_t elapsed, int success, uint32_t error) {
    if (const auto* api = descriptor()) api->swapped(provider, elapsed, success, error);
}
extern "C" void amclGraphicsFatalV1(const char* stage, uint32_t error, uint64_t generation) {
    if (const auto* api = descriptor()) api->fatal(stage, error, generation);
}
extern "C" void amclGraphicsForegroundV1(int visible) {
    setenv("AMCL_GRAPHICS_FOREGROUND", visible ? "1" : "0", 1);
    if (const auto* api = descriptor()) api->foreground(visible);
}
extern "C" const char* amclGraphicsRuntimeJsonV1() {
    const auto* api = descriptor(); return api ? api->snapshot(0) : "";
}
extern "C" const char* amclGraphicsFailureJsonV1() {
    const auto* api = descriptor(); return api ? api->snapshot(1) : "";
}
extern "C" int amclGraphicsObservationEnabledV1() {
    const auto* api = descriptor();
    return api && (api->structSize < offsetof(AmclGraphicsObserverV1, dispatchPresent) || !api->samplesEnabled || api->samplesEnabled());
}
