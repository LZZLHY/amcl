#include "../../platform/graphics_backend_session.h"
#include <algorithm>
#include <iostream>
#include <map>
#include <memory>
#include <utility>
#include <vector>

using namespace amcl::graphics;
namespace {
int failures = 0;
void require(bool value, const char* message) {
    if (!value) { std::cerr << "FAIL: " << message << '\n'; ++failures; }
}
struct Trace {
    std::vector<std::string> events;
    bool surface = false;
    bool context = false;
    bool failAttach = false;
    bool failResume = false;
    bool failSuspend = false;
    bool failDestroy = false;
};
class FakeBroker final : public NativeWindowBroker {
public:
    uint64_t generation = 1;
    uint64_t resourceEpoch = 0;
    int width = 640, height = 480;
    void* pointer = reinterpret_cast<void*>(0x1234);
    uint64_t owner = 0;
    uint64_t ownerGeneration = 0;
    bool failMove = false;
    bool failRelease = false;
    std::map<void*, int> references;
    std::shared_ptr<Trace> trace = std::make_shared<Trace>();
    bool acquire(const NativeWindowLease*, NativeWindowLease& out, std::string& error) override {
        if (generation == 0) { error = "unpublished"; return false; }
        trace->events.push_back("acquire");
        out = {pointer, generation, width, height, true, resourceEpoch, generation};
        ++references[pointer];
        return true;
    }
    void release(NativeWindowLease& lease) override {
        trace->events.push_back("release-lease");
        require(!lease.ownsReference || references[lease.nativeWindow] > 0, "release requires a reference");
        if (lease.ownsReference) --references[lease.nativeWindow];
        lease = {};
    }
    bool claimPresentOwner(uint64_t id, const NativeWindowLease& lease, std::string& error) override {
        trace->events.push_back("claim");
        if (owner || lease.generation != generation) { error = "busy or stale"; return false; }
        owner = id;
        ownerGeneration = lease.generation;
        return true;
    }
    bool movePresentOwner(uint64_t id, const NativeWindowLease& lease, std::string& error) override {
        trace->events.push_back("move");
        require(!trace->surface, "old API surface must retire before token move");
        if (owner != id || lease.generation != generation || failMove) { error = "move rejected"; return false; }
        ownerGeneration = lease.generation;
        return true;
    }
    bool releasePresentOwner(uint64_t id, std::string& error) override {
        trace->events.push_back("release-token");
        require(!trace->surface && !trace->context, "API resources must retire before token release");
        if (owner != id || failRelease) { error = "release rejected"; return false; }
        owner = 0;
        ownerGeneration = 0;
        return true;
    }
    bool moveGeometryOwner(uint64_t id, const NativeWindowLease& previous, const NativeWindowLease& next, std::string&) override {
        if (id != owner || !resourceEpoch || previous.resourceEpoch != resourceEpoch ||
            next.resourceEpoch != resourceEpoch || previous.generation != ownerGeneration ||
            next.generation != generation || failMove) return false;
        trace->events.push_back("geometry-move"); ownerGeneration = next.generation; return true;
    }
    uint64_t currentGeneration() const override { return generation; }
    int totalReferences() const {
        int count = 0;
        for (const auto& item : references) count += item.second;
        return count;
    }
};

std::shared_ptr<BackendAdapter> realOperations(const std::shared_ptr<FakeBroker>& broker, uint64_t id) {
    auto trace = broker->trace;
    BackendAdapterCallbacks callbacks;
    callbacks.attach = [broker, trace, id](const NativeWindowLease& lease, std::string& error) {
        trace->events.push_back("api-init");
        require(broker->owner == id && broker->references[lease.nativeWindow] > 0, "claim and lease precede API init");
        trace->context = true;
        trace->surface = true;
        if (trace->failAttach) { error = "partial API init"; return false; }
        return true;
    };
    callbacks.suspend = [trace](std::string& error) {
        trace->events.push_back("api-suspend");
        if (trace->failSuspend) { error = "surface destroy rejected"; return false; }
        trace->surface = false;
        return true;
    };
    callbacks.resume = [broker, trace, id](const NativeWindowLease& lease, std::string& error) {
        trace->events.push_back("api-attach");
        require(!trace->surface && trace->context, "resume preserves context and requires retired surface");
        require(broker->owner == id && broker->ownerGeneration == lease.generation, "atomic move precedes new API surface");
        trace->surface = true;
        if (trace->failResume) { error = "replacement bind failed"; return false; }
        return true;
    };
    callbacks.resize = [trace](int width, int height, std::string&) {
        trace->events.push_back("api-resize");
        return width > 0 && height > 0;
    };
    callbacks.detach = callbacks.suspend;
    callbacks.destroy = [trace](bool, std::string& error) {
        trace->events.push_back("api-destroy");
        if (trace->failDestroy) { error = "real backend teardown failed"; return false; }
        trace->surface = false;
        trace->context = false;
        return true;
    };
    return std::make_shared<SystemOpenGLBackendSessionAdapter>(std::move(callbacks));
}

void normalOrderingAndReplacement() {
    auto broker = std::make_shared<FakeBroker>();
    auto trace = broker->trace;
    auto adapter = realOperations(broker, 1);
    std::string error;
    BackendSession session(1, "system-opengl", broker, adapter);
    require(!session.recordPresent(error) && session.presentCount() == 0, "unprepared session cannot record presentation");
    require(session.prepare(error), "initial prepare succeeds");
    require(!session.recordPresent(error) && session.presentCount() == 0, "prepared but unattached session cannot record presentation");
    require(session.attach(error), "initial attach succeeds");
    require(trace->events == std::vector<std::string>({"acquire", "claim", "api-init"}), "initial ownership ordering");
    require(session.hasResources(), "attach tracks real backend resources");
    require(session.recordPresent(error) && session.recordPresent(error) && session.presentCount() == 2,
        "attached session counts successive real presentation notifications");
    require(!session.resize(0, 1, 1, error), "invalid resize fails");
    auto contenderAdapter = std::make_shared<MinecraftVulkanBackendSessionAdapter>();
    BackendSession contender(2, "minecraft-vulkan", broker, contenderAdapter);
    require(contender.prepare(error) && !contender.attach(error), "second session rejected before API creation");
    require(broker->owner == 1 && trace->surface, "claim refusal does not disturb existing owner");
    require(broker->totalReferences() == 1, "claim refusal releases only contender lease");

    trace->events.clear();
    void* original = broker->pointer;
    broker->pointer = reinterpret_cast<void*>(0x5678);
    broker->generation = 2;
    require(session.resize(800, 600, 2, error), "replacement resize succeeds");
    require(trace->events == std::vector<std::string>({"api-suspend", "acquire", "move", "api-attach", "release-lease", "api-resize"}),
        "replacement executes suspend, atomic move, attach, old lease release");
    require(broker->references[original] == 0 && broker->totalReferences() == 1, "old reference retires after new attach");
    require(!session.resize(1, 1, 1, error), "stale resize rejected");
    require(session.detach(error) && session.detach(error), "detach is idempotent");
    require(!session.recordPresent(error) && session.presentCount() == 2, "detached session cannot record presentation");
    require(session.attach(error), "detached owner resumes without double claim");
    trace->events.clear();
    require(session.destroy(false, error) && session.destroy(false, error), "adapter owns actual idempotent destruction");
    require(!session.recordPresent(error) && session.presentCount() == 2, "destroyed session preserves its total and cannot add presentation");
    require(trace->events == std::vector<std::string>({"api-destroy", "release-token", "release-lease"}), "destroy tears down API before releasing ownership");
    require(broker->owner == 0 && broker->totalReferences() == 0, "normal lifecycle releases everything");
}

void failuresKeepOwnership() {
    auto broker = std::make_shared<FakeBroker>();
    auto trace = broker->trace;
    std::string error;
    BackendSession session(3, "mobileglues", broker, realOperations(broker, 3));
    require(session.prepare(error) && session.attach(error), "failure test attach");
    void* original = broker->pointer;
    broker->pointer = reinterpret_cast<void*>(0x9012);
    broker->generation = 2;
    trace->failSuspend = true;
    trace->events.clear();
    require(!session.resize(800, 600, 2, error), "suspend failure blocks replacement");
    require(trace->events == std::vector<std::string>({"api-suspend"}), "no token move while real old surface is live");
    require(session.generation() == 1 && broker->references[original] == 1 && broker->ownerGeneration == 1, "suspend failure keeps old ownership");

    trace->failSuspend = false;
    broker->failMove = true;
    require(!session.resize(800, 600, 2, error), "move failure reported");
    require(session.state() == BackendSessionState::kSuspended && session.generation() == 1, "failed move stays on original suspended epoch");
    require(broker->owner == 3 && broker->ownerGeneration == 1 && broker->totalReferences() == 1, "failed atomic move retains original token and lease");
    broker->failMove = false;
    trace->failResume = true;
    require(!session.resume(error), "new API attachment failure reported");
    require(broker->owner == 3 && broker->ownerGeneration == 2 && broker->references[original] == 1 && broker->totalReferences() == 2,
        "failed new attachment retains token and both leases");
    require(!trace->surface && trace->context, "failed replacement surface is cleaned before retry");
    trace->failResume = false;
    require(session.resume(error), "retry uses retained moved token");
    require(broker->references[original] == 0 && broker->totalReferences() == 1, "successful retry retires old reference");
    trace->failDestroy = true;
    require(!session.destroy(false, error), "teardown failure reported");
    require(trace->surface && trace->context && session.hasPresentOwner() && broker->totalReferences() == 1, "teardown failure retains API handles and ownership");
    trace->failDestroy = false;
    broker->failRelease = true;
    require(!session.destroy(false, error), "host token release failure reported");
    require(!trace->surface && !trace->context && broker->totalReferences() == 1 && session.hasPresentOwner(), "release failure retains lease after API teardown");
    broker->failRelease = false;
    require(session.destroy(false, error), "failed teardown/release can retry");
}

void partialAttachAndRaii() {
    std::string error;
    auto broker = std::make_shared<FakeBroker>();
    auto trace = broker->trace;
    trace->failAttach = true;
    trace->failDestroy = true;
    {
        BackendSession session(4, "mobileglues", broker, realOperations(broker, 4));
        require(session.prepare(error) && !session.attach(error), "partial attach failure reported");
        require(session.hasPresentOwner() && trace->surface && broker->totalReferences() == 1, "failed partial-init teardown retains owner");
        trace->failDestroy = false;
    }
    require(broker->owner == 0 && broker->totalReferences() == 0 && !trace->surface, "RAII calls real teardown for partial allocation");

    trace->failAttach = false;
    trace->failDestroy = true;
    const uint64_t failuresBefore = BackendSession::quarantineFailureCount();
    {
        BackendSession session(5, "system-opengl", broker, realOperations(broker, 5));
        require(session.prepare(error) && session.attach(error), "RAII quarantine attach");
    }
    require(BackendSession::quarantinedCount() == 1 && BackendSession::quarantineFailureCount() == failuresBefore + 1,
        "failed RAII transfers complete owner to observable quarantine");
    require(broker->owner == 5 && broker->totalReferences() == 1, "quarantine keeps backend ownership alive");
    require(!BackendSession::retryQuarantined(error), "quarantine does not fake teardown success");
    trace->failDestroy = false;
    require(BackendSession::retryQuarantined(error) && BackendSession::quarantinedCount() == 0,
        "quarantine retry completes real teardown");
    require(broker->totalReferences() == 0 && broker->owner == 0, "quarantine successful retry releases exact ownership");

    BackendAdapterCallbacks empty;
    auto incomplete = std::make_shared<SystemOpenGLBackendSessionAdapter>(std::move(empty));
    BackendSession missingCallbacks(6, "system-opengl", broker, incomplete);
    require(!missingCallbacks.prepare(error), "empty EGL adapter callbacks cannot admit a session");
}

int abiReleases = 0;
int invalidSizeAcquire(void*, uint64_t, void** pointer, int* width, int* height, uint64_t* generation) {
    *pointer = reinterpret_cast<void*>(0x2468); *width = 0; *height = 480; *generation = 1; return 1;
}
void abiRelease(void*) { ++abiReleases; }
uint64_t forbiddenPeek() { require(false, "truncated ABI tail must never be called"); return 9; }
void abiGuards() {
    AmclNativeWindowLeaseBrokerV2 abi{};
    abi.abiVersion = AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION;
    abi.structSize = AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_CORE_SIZE;
    abi.acquire = invalidSizeAcquire;
    abi.release = abiRelease;
    abi.peekGeneration = forbiddenPeek;
    AbiNativeWindowBroker broker(&abi);
    NativeWindowLease lease;
    std::string error;
    require(broker.currentGeneration() == 0, "core-only ABI has no readable peek tail");
    require(!broker.acquire(nullptr, lease, error) && abiReleases == 1, "invalid acquired dimensions release the added reference");
    const NativeWindowLease requested{reinterpret_cast<void*>(0x2468), 1, 640, 480, false};
    require(!broker.claimPresentOwner(7, requested, error), "missing presentation tail fails closed");
}
}

void geometryContinuity() {
    auto broker = std::make_shared<FakeBroker>(); broker->resourceEpoch = 1;
    auto adapter = realOperations(broker, 80); std::string error;
    BackendSession session(80, "mobilegl", broker, adapter);
    require(session.prepare(error) && session.attach(error), "geometry session initialized");
    broker->trace->events.clear(); broker->generation = 2; broker->width = 800;
    require(session.refreshGeometry(800, 480, 2, error), "same resource geometry accepted");
    require(session.generation() == 2 && broker->ownerGeneration == 2 && broker->totalReferences() == 1,
        "geometry commits one owned current lease");
    require(std::find(broker->trace->events.begin(), broker->trace->events.end(), "api-suspend") == broker->trace->events.end(),
        "geometry keeps surface and context live");
    broker->generation = 3; broker->failMove = true;
    require(!session.refreshGeometry(800, 480, 3, error) && session.generation() == 2 && broker->totalReferences() == 1,
        "failed geometry move retains old owner and releases candidate");
    broker->failMove = false; broker->resourceEpoch = 3;
    require(!session.refreshGeometry(800, 480, 3, error), "resource replacement rejects fast path");
    require(session.resize(800, 480, 3, error), "resource replacement follows full retirement/rebind");
    require(session.destroy(false, error) && broker->totalReferences() == 0, "geometry session retires completely");
}

int main() {
    geometryContinuity();
    normalOrderingAndReplacement();
    failuresKeepOwnership();
    partialAttachAndRaii();
    abiGuards();
    if (failures == 0) std::cout << "graphics_backend_session_host_test: OK\n";
    return failures == 0 ? 0 : 1;
}
