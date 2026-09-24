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
void publishEnv(const char* name, const char* value) {
#ifdef _WIN32
    _putenv_s(name, value);
#else
    setenv(name, value, 1);
#endif
}
void publishSnapshot(const AmclWindowHostSnapshot& snapshot, void*) {
    char encoded[128];
    std::snprintf(encoded, sizeof(encoded), "%llu:%llu:%d:%d",
        static_cast<unsigned long long>(snapshot.generation),
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(snapshot.nativeWindow)), snapshot.width, snapshot.height);
    publishEnv("AMCL_NATIVE_WINDOW_SNAPSHOT", encoded);
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
    WindowHostCore core{NativeReferenceDriver{nativeReference, nativeUnreference, nullptr, publishSnapshot}};
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
const AmclNativeWindowLeaseBrokerV2 kLocalBroker{
    AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION, sizeof(AmclNativeWindowLeaseBrokerV2),
    localAcquire, localRelease, localBeginInput, localEndInput, localPeekGeneration, localPeekState,
    localClaim, localMove, localReleasePresentation, localAcquireIdentity, localMoveGeometry
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
    return runtime().core.setReferenceDriver({reference, unreference, context, publishSnapshot}) ? 1 : 0;
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
#if defined(AMCL_WINDOW_HOST_TESTING)
    decltype(&localSetDriver) setDriver;
#endif
};
OwnerApi& localOwnerApi() {
    static std::atomic<OwnerApi*> slot{new OwnerApi{1, sizeof(OwnerApi), processId(),
        localPublish, localUpdate, localClear, localRead, localStats, localRetry, localBroker
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
OwnerResolution owner() {
    const char* encoded = std::getenv(kOwnerEnv);
    if (!encoded || !*encoded) return {&localOwnerApi(), OwnerStatus::kAbsent};
    unsigned long long pid = 0;
    void* address = nullptr;
    int consumed = 0;
    if (std::sscanf(encoded, "%llu:%p%n", &pid, &address, &consumed) != 2 || encoded[consumed] != '\0' || !address)
        return {nullptr, OwnerStatus::kMalformed};
    if (pid != processId()) return {&localOwnerApi(), OwnerStatus::kInherited};
    const auto* api = static_cast<const OwnerApi*>(address);
    if (api->version != 1 || api->size < sizeof(OwnerApi) || api->pid != processId() ||
        !api->publish || !api->update || !api->clear || !api->read || !api->stats || !api->retry || !api->broker)
        return {nullptr, OwnerStatus::kMalformed};
    return {api, api == &localOwnerApi() ? OwnerStatus::kLocal : OwnerStatus::kRemote};
}
bool validBroker(const AmclNativeWindowLeaseBrokerV2* broker) {
    if (!broker || broker->abiVersion != AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION ||
        broker->structSize < AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_CORE_SIZE || !broker->acquire || !broker->release ||
        !broker->beginInputPublication || !broker->endInputPublication) return false;
    return broker->structSize < AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PEEK_SIZE || (broker->peekGeneration && broker->peekState);
}
const AmclNativeWindowLeaseBrokerV2* resolveBroker() {
    const auto resolved = owner();
    if (!resolved.api) return nullptr;
    if (resolved.status == OwnerStatus::kInherited) return &kLocalBroker;
    const char* encoded = std::getenv(AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV);
    if (!encoded || !*encoded) return resolved.api->broker();
    unsigned version = 0;
    void* address = nullptr;
    int consumed = 0;
    if (std::sscanf(encoded, "%u:%p%n", &version, &address, &consumed) != 2 || encoded[consumed] != '\0' ||
        version != AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION || !address) return nullptr;
    const auto* broker = static_cast<const AmclNativeWindowLeaseBrokerV2*>(address);
    if (!validBroker(broker)) return nullptr;
    // Existing legacy ABI descriptors remain consumable. A new-style owner
    // descriptor must agree with the published broker, never split ownership.
    if (resolved.status != OwnerStatus::kAbsent && broker != resolved.api->broker()) return nullptr;
    return broker;
}
bool publishOwner() {
    auto& state = runtime();
    std::lock_guard<std::mutex> lock(state.ownerPublicationMutex);
    const auto resolved = owner();
    if (!resolved.api || resolved.status == OwnerStatus::kRemote) return false;
    if (state.ownerPublished) return true;
    // A pre-existing descriptor belongs to another owner that does not expose
    // the new owner table. Never overwrite it from a duplicate image. A fork
    // child is the exception: its inherited descriptor has a different PID
    // and runtime() deliberately starts a fresh owner.
    if (resolved.status != OwnerStatus::kInherited) {
        const char* existing = std::getenv(AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV);
        if (existing && *existing) return false;
    }
    char encoded[96];
    // Keep the established v2 transport exactly; consumers already parse 2:%p.
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
    // Once this image has published, a descriptor mutation is evidence of a
    // split owner. Refuse to advance its private core until the wire is fixed.
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
#if defined(AMCL_WINDOW_HOST_TESTING)
int amclWindowHostSetReferenceDriver(AmclWindowHostReferenceFn reference, AmclWindowHostReferenceFn unreference, void* context) {
    const auto resolved = owner();
    return resolved.api && resolved.api->setDriver ? resolved.api->setDriver(reference, unreference, context) : 0;
}
void amclWindowHostTestOverridePid(uint64_t pid) { testPid.store(pid, std::memory_order_release); }
#endif
}
