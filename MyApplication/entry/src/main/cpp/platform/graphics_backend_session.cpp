#include "graphics_backend_session.h"
#include <cstdio>
#include <sstream>
#include <utility>

namespace amcl::graphics {
namespace {
bool validCore(const AmclNativeWindowLeaseBrokerV2* abi) {
    return abi && abi->abiVersion == AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION &&
        abi->structSize >= AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_CORE_SIZE && abi->acquire && abi->release;
}
bool validPresentation(const AmclNativeWindowLeaseBrokerV2* abi) {
    return validCore(abi) && abi->structSize >= AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PRESENTATION_SIZE &&
        abi->claimPresentation && abi->movePresentation && abi->releasePresentation;
}
bool validIdentity(const AmclNativeWindowLeaseBrokerV2* abi) {
    return validPresentation(abi) && abi->structSize >= AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_IDENTITY_SIZE &&
        abi->acquireIdentity && abi->movePresentationGeometry;
}
struct QuarantinedSession {
    uint64_t id;
    std::string profile;
    std::shared_ptr<NativeWindowBroker> broker;
    std::shared_ptr<BackendAdapter> adapter;
    NativeWindowLease lease;
    std::vector<NativeWindowLease> retiredLeases;
    bool presentOwner;
    bool resourcesCreated;
    std::string error;
};
struct Quarantine {
    std::mutex mutex;
    std::vector<QuarantinedSession> sessions;
    uint64_t failures = 0;
};
Quarantine& quarantine() {
    // Failed resources stay owned until explicit retry or process teardown.
    // Static destruction must not silently drop those owners.
    static auto* value = new Quarantine();
    return *value;
}
}

AbiNativeWindowBroker::AbiNativeWindowBroker(const AmclNativeWindowLeaseBrokerV2* abi, uint32_t api)
    : abi_(abi), api_(api) {}

bool AbiNativeWindowBroker::acquire(const NativeWindowLease* requested, NativeWindowLease& out, std::string& error) {
    out = {};
    if (!validCore(abi_)) { error = "window broker ABI unavailable"; return false; }
    void* pointer = nullptr;
    int width = 0;
    int height = 0;
    uint64_t generation = 0;
    AmclNativeWindowIdentityV1 identity{sizeof(identity), 1u, nullptr, 0, 0, 0, 0, 0};
    int rc = 0;
    if (validIdentity(abi_)) {
        rc = abi_->acquireIdentity(requested ? requested->nativeWindow : nullptr,
            requested ? requested->generation : 0, &identity);
        pointer = identity.nativeWindow; width = identity.width; height = identity.height; generation = identity.generation;
    } else {
        rc = abi_->acquire(requested ? requested->nativeWindow : nullptr,
            requested ? requested->generation : 0, &pointer, &width, &height, &generation);
    }
    if ((rc != 1 && rc != 2) || !pointer || generation == 0 || width <= 0 || height <= 0) {
        if (rc == 1 && pointer) abi_->release(pointer);
        std::ostringstream message;
        message << "window acquire failed rc=" << rc << " generation=" << generation;
        error = message.str();
        return false;
    }
    if (rc == 2 && (!requested || requested->nativeWindow != pointer || requested->generation != generation)) {
        error = "window broker returned a borrowed lease without a retained match";
        return false;
    }
    out = {pointer, generation, width, height, rc == 1, identity.resourceEpoch, identity.geometryEpoch};
    return true;
}

void AbiNativeWindowBroker::release(NativeWindowLease& lease) {
    if (lease.nativeWindow && lease.ownsReference && validCore(abi_)) abi_->release(lease.nativeWindow);
    lease = {};
}

bool AbiNativeWindowBroker::claimPresentOwner(uint64_t id, const NativeWindowLease& lease, std::string& error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!id || !lease.valid() || presentOwner_) { error = "invalid or occupied present owner"; return false; }
    if (!validPresentation(abi_)) { error = "window broker presentation tail unavailable"; return false; }
    uint64_t token = 0;
    if (!abi_->claimPresentation(lease.nativeWindow, lease.generation, api_, &token) || !token) {
        error = "presentation owner claim rejected";
        return false;
    }
    presentationToken_ = token;
    presentOwner_ = id;
    presentGeneration_ = lease.generation;
    return true;
}

bool AbiNativeWindowBroker::movePresentOwner(uint64_t id, const NativeWindowLease& replacement, std::string& error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!id || presentOwner_ != id || !presentationToken_ || !replacement.valid() || !validPresentation(abi_)) {
        error = "presentation owner move has no valid retained owner";
        return false;
    }
    if (!abi_->movePresentation(presentationToken_, replacement.nativeWindow, replacement.generation)) {
        error = "presentation owner move rejected; old token retained";
        return false;
    }
    presentGeneration_ = replacement.generation;
    return true;
}

bool AbiNativeWindowBroker::releasePresentOwner(uint64_t id, std::string& error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!presentOwner_) return true;
    if (presentOwner_ != id || !validPresentation(abi_) || !presentationToken_ ||
        !abi_->releasePresentation(presentationToken_)) {
        error = "presentation release rejected; retained token and window lease";
        return false;
    }
    presentOwner_ = 0;
    presentGeneration_ = 0;
    presentationToken_ = 0;
    return true;
}

bool AbiNativeWindowBroker::moveGeometryOwner(uint64_t id, const NativeWindowLease& previous,
                                             const NativeWindowLease& replacement, std::string& error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!validIdentity(abi_) || id != presentOwner_ || !presentationToken_ ||
        previous.generation != presentGeneration_ || !previous.resourceEpoch ||
        previous.resourceEpoch != replacement.resourceEpoch || previous.nativeWindow != replacement.nativeWindow ||
        !abi_->movePresentationGeometry(presentationToken_, replacement.nativeWindow, previous.generation,
            replacement.generation, replacement.resourceEpoch)) {
        error = "geometry identity changed or authoritative token update rejected";
        return false;
    }
    presentGeneration_ = replacement.generation;
    return true;
}

uint64_t AbiNativeWindowBroker::currentGeneration() const {
    return validCore(abi_) && abi_->structSize >= AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PEEK_SIZE &&
        abi_->peekGeneration ? abi_->peekGeneration() : 0;
}

BackendSession::BackendSession(uint64_t id, std::string profile, std::shared_ptr<NativeWindowBroker> broker,
                               std::shared_ptr<BackendAdapter> adapter)
    : sessionId_(id), profile_(std::move(profile)), broker_(std::move(broker)), adapter_(std::move(adapter)) {}

BackendSession::~BackendSession() {
    if (state_ == BackendSessionState::kDestroyed) return;
    std::string error;
    if (destroy(false, error)) return;
    if (!presentOwner_ && !lease_.nativeWindow && retiredLeases_.empty()) return;
    auto& retained = quarantine();
    std::lock_guard<std::mutex> lock(retained.mutex);
    ++retained.failures;
    std::fprintf(stderr, "[graphics-session] quarantine id=%llu profile=%s failures=%llu reason=%s\n",
        static_cast<unsigned long long>(sessionId_), profile_.c_str(),
        static_cast<unsigned long long>(retained.failures), error.c_str());
    retained.sessions.push_back({sessionId_, std::move(profile_), std::move(broker_), std::move(adapter_),
        lease_, std::move(retiredLeases_), presentOwner_, resourcesCreated_, std::move(error)});
    lease_ = {};
    presentOwner_ = false;
}

size_t BackendSession::quarantinedCount() {
    auto& retained = quarantine();
    std::lock_guard<std::mutex> lock(retained.mutex);
    return retained.sessions.size();
}

uint64_t BackendSession::quarantineFailureCount() {
    auto& retained = quarantine();
    std::lock_guard<std::mutex> lock(retained.mutex);
    return retained.failures;
}

bool BackendSession::retryQuarantined(std::string& error) {
    auto& retained = quarantine();
    std::lock_guard<std::mutex> lock(retained.mutex);
    for (auto entry = retained.sessions.begin(); entry != retained.sessions.end();) {
        if (!entry->adapter || !entry->adapter->onDestroy(!entry->resourcesCreated, entry->error)) {
            error = entry->error;
            ++retained.failures;
            ++entry;
            continue;
        }
        entry->resourcesCreated = false;
        if (entry->presentOwner && !entry->broker->releasePresentOwner(entry->id, entry->error)) {
            error = entry->error;
            ++retained.failures;
            ++entry;
            continue;
        }
        entry->broker->release(entry->lease);
        for (auto& lease : entry->retiredLeases) entry->broker->release(lease);
        entry = retained.sessions.erase(entry);
    }
    return retained.sessions.empty();
}

bool BackendSession::prepare(std::string& error) {
    if (!sessionId_ || profile_.empty() || !broker_ || !adapter_) {
        error = "session requires an id, profile, broker and backend adapter";
        return false;
    }
    if (state_ == BackendSessionState::kPrepared) return true;
    if (state_ != BackendSessionState::kNew) { error = "prepare requires New"; return false; }
    if (!adapter_->onPrepare(error)) return false;
    state_ = BackendSessionState::kPrepared;
    return true;
}

bool BackendSession::acquireAndClaim(const NativeWindowLease* expected, std::string& error) {
    NativeWindowLease acquired;
    if (!broker_->acquire(nullptr, acquired, error)) return false;
    if (expected && (acquired.nativeWindow != expected->nativeWindow || acquired.generation != expected->generation)) {
        broker_->release(acquired);
        error = "published window changed during attach";
        return false;
    }
    if (!broker_->claimPresentOwner(sessionId_, acquired, error)) { broker_->release(acquired); return false; }
    lease_ = acquired;
    presentOwner_ = true;
    // Attach may allocate a surface before failing. Commit ownership before
    // the callback, then release only after actual backend teardown succeeds.
    resourcesCreated_ = true;
    if (!adapter_->onAttach(lease_, error)) {
        std::string teardownError;
        if (adapterDestroy(false, teardownError)) {
            resourcesCreated_ = false;
            if (!abandonOwnership(teardownError)) error += "; " + teardownError;
        } else {
            error += "; teardown retained ownership: " + teardownError;
        }
        return false;
    }
    return true;
}

bool BackendSession::attach(std::string& error) {
    if (state_ == BackendSessionState::kAttached) return true;
    if (state_ == BackendSessionState::kDetached && presentOwner_) {
        state_ = BackendSessionState::kSuspended;
        return resume(error);
    }
    if (state_ != BackendSessionState::kPrepared) { error = "attach requires Prepared"; return false; }
    if (!acquireAndClaim(nullptr, error)) { state_ = BackendSessionState::kFailed; return false; }
    state_ = BackendSessionState::kAttached;
    return true;
}

bool BackendSession::attach(const NativeWindowLease& expected, std::string& error) {
    if (state_ != BackendSessionState::kPrepared || !expected.valid()) {
        error = "attach requires Prepared and a valid expected window";
        return false;
    }
    if (!acquireAndClaim(&expected, error)) { state_ = BackendSessionState::kFailed; return false; }
    state_ = BackendSessionState::kAttached;
    return true;
}

bool BackendSession::markResourcesCreated(std::string& error) {
    if (state_ != BackendSessionState::kAttached || !presentOwner_) { error = "resources require Attached"; return false; }
    if (!adapter_->onResourcesCreated(error)) return false;
    resourcesCreated_ = true;
    return true;
}

bool BackendSession::markResourcesRetired(std::string& error) {
    if (!resourcesCreated_) { error = "no live resources"; return false; }
    if (!adapter_->onResourcesRetired(error)) return false;
    resourcesCreated_ = false;
    return true;
}

bool BackendSession::recordPresent(std::string& error) {
    if (state_ != BackendSessionState::kAttached || !presentOwner_ || !resourcesCreated_) {
        error = "presentation requires an attached owner with live backend resources";
        return false;
    }
    if (presentCount_ == UINT64_MAX) { error = "presentation counter exhausted"; return false; }
    ++presentCount_;
    return true;
}

bool BackendSession::replaceLease(uint64_t generation, std::string& error) {
    if (generation == lease_.generation) return true;
    if (state_ != BackendSessionState::kSuspended || !presentOwner_) {
        error = "window replacement requires a suspended owner";
        return false;
    }
    NativeWindowLease replacement;
    if (!broker_->acquire(nullptr, replacement, error)) return false;
    if (replacement.generation != generation) {
        broker_->release(replacement);
        error = "publication changed before window replacement";
        return false;
    }
    if (!broker_->movePresentOwner(sessionId_, replacement, error)) {
        broker_->release(replacement);
        return false;
    }
    retiredLeases_.push_back(lease_);
    lease_ = replacement;
    return true;
}

bool BackendSession::resize(int width, int height, uint64_t generation, std::string& error) {
    if (state_ != BackendSessionState::kAttached && state_ != BackendSessionState::kSuspended) {
        error = "resize requires Attached/Suspended";
        return false;
    }
    if (width <= 0 || height <= 0 || !generation || generation < lease_.generation ||
        broker_->currentGeneration() != generation) {
        error = "stale generation or invalid size";
        return false;
    }
    if (generation != lease_.generation) {
        const bool wasAttached = state_ == BackendSessionState::kAttached;
        if (wasAttached && !suspend(error)) return false;
        if (!replaceLease(generation, error)) return false;
        if (wasAttached && !resume(error)) return false;
    }
    if (!adapter_->onResize(width, height, error)) return false;
    lease_.width = width;
    lease_.height = height;
    return true;
}

// 仅限已附着、资源连续且有原子身份扩展的 OpenGL 窗口。失败返回给调用者走原保守路径；
// 新引用始终在成功提交 token 前保留，旧引用仅在新 lease 已替代后退休。
bool BackendSession::refreshGeometry(int width, int height, uint64_t generation, std::string& error) {
    if (state_ != BackendSessionState::kAttached || !presentOwner_ || !resourcesCreated_ ||
        !lease_.resourceEpoch || generation <= lease_.generation || width <= 0 || height <= 0) return false;
    NativeWindowLease replacement;
    if (!broker_->acquire(nullptr, replacement, error)) return false;
    const bool continuous = replacement.generation == generation && replacement.nativeWindow == lease_.nativeWindow &&
        replacement.resourceEpoch == lease_.resourceEpoch && replacement.geometryEpoch >= lease_.geometryEpoch &&
        replacement.width == width && replacement.height == height;
    if (!continuous || !adapter_->onResize(width, height, error) ||
        !broker_->moveGeometryOwner(sessionId_, lease_, replacement, error)) {
        broker_->release(replacement);
        return false;
    }
    NativeWindowLease retired = lease_;
    lease_ = replacement;
    broker_->release(retired);
    return true;
}

bool BackendSession::suspend(std::string& error) {
    if (state_ == BackendSessionState::kSuspended) return true;
    if (state_ != BackendSessionState::kAttached) { error = "suspend requires Attached"; return false; }
    if (!adapter_->onSuspend(error)) return false;
    state_ = BackendSessionState::kSuspended;
    return true;
}

bool BackendSession::resume(std::string& error) {
    if (state_ == BackendSessionState::kAttached) return true;
    if (state_ != BackendSessionState::kSuspended) { error = "resume requires Suspended"; return false; }
    const uint64_t generation = broker_->currentGeneration();
    if (!generation) { error = "published generation unavailable"; return false; }
    if (!replaceLease(generation, error)) return false;
    resourcesCreated_ = true;
    if (!adapter_->onResume(lease_, error)) {
        std::string cleanupError;
        if (!adapter_->onSuspend(cleanupError)) {
            state_ = BackendSessionState::kFailed;
            error += "; replacement surface cleanup retained ownership: " + cleanupError;
        }
        return false;
    }
    releaseRetiredLeases();
    state_ = BackendSessionState::kAttached;
    return true;
}

bool BackendSession::detach(std::string& error) {
    if (state_ == BackendSessionState::kDetached) return true;
    if (state_ != BackendSessionState::kAttached && state_ != BackendSessionState::kSuspended) {
        error = "detach requires Attached/Suspended";
        return false;
    }
    if (!adapter_->onDetach(error)) return false;
    state_ = BackendSessionState::kDetached;
    return true;
}

bool BackendSession::adapterDestroy(bool resourcesDestroyed, std::string& error) {
    if (!adapter_) return !resourcesCreated_;
    return adapter_->onDestroy(resourcesDestroyed || !resourcesCreated_, error);
}

bool BackendSession::destroy(bool resourcesDestroyed, std::string& error) {
    if (state_ == BackendSessionState::kDestroyed) return true;
    if (!adapterDestroy(resourcesDestroyed, error)) { state_ = BackendSessionState::kFailed; return false; }
    resourcesCreated_ = false;
    if (!abandonOwnership(error)) { state_ = BackendSessionState::kFailed; return false; }
    state_ = BackendSessionState::kDestroyed;
    return true;
}

bool BackendSession::fail(const std::string& reason) {
    if (state_ == BackendSessionState::kDestroyed || reason.empty()) return false;
    state_ = BackendSessionState::kFailed;
    return true;
}

void BackendSession::releaseRetiredLeases() {
    for (auto& lease : retiredLeases_) broker_->release(lease);
    retiredLeases_.clear();
}

bool BackendSession::abandonOwnership(std::string& error) {
    if (!broker_) return true;
    if (presentOwner_) {
        if (!broker_->releasePresentOwner(sessionId_, error)) return false;
        presentOwner_ = false;
    }
    if (lease_.nativeWindow) broker_->release(lease_);
    releaseRetiredLeases();
    return true;
}
}
