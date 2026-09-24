#include "window_host_core.h"
#include <utility>

namespace amcl::window {
WindowHostCore::WindowHostCore(NativeReferenceDriver driver, uint64_t initialGeneration) : driver_(driver) {
    snapshot_.generation = initialGeneration;
    snapshot_.state = AMCL_NATIVE_WINDOW_PUBLICATION_UNPUBLISHED;
    peekGeneration_.store(initialGeneration, std::memory_order_relaxed);
}

bool WindowHostCore::setReferenceDriver(NativeReferenceDriver driver) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (publicationReference_ || counters_.liveLeases || !pendingRetirements_.empty() || presenter_.token()) return false;
    driver_ = driver;
    return driver_.reference && driver_.unreference;
}

bool WindowHostCore::ready() const {
    return publicationReference_ && snapshot_.nativeWindow && snapshot_.width > 0 && snapshot_.height > 0;
}

void WindowHostCore::commit(void* retiredPublication, AmclWindowHostCommitFn beforeCommit, void* context) {
    snapshot_.state = !snapshot_.nativeWindow ? AMCL_NATIVE_WINDOW_PUBLICATION_CLEARED :
        ready() ? AMCL_NATIVE_WINDOW_PUBLICATION_READY : AMCL_NATIVE_WINDOW_PUBLICATION_SUSPENDED;
    ++counters_.publications;
    if (driver_.publishSnapshot) driver_.publishSnapshot(snapshot_, driver_.context);
    if (beforeCommit) beforeCommit(&snapshot_, context);
    retire(retiredPublication);
    // Preserve the established generation/state/generation reader contract.
    peekGeneration_.store(snapshot_.generation, std::memory_order_release);
    peekState_.store(snapshot_.state, std::memory_order_release);
}

void WindowHostCore::retire(void* window) {
    if (!window) return;
    if (!driver_.unreference || driver_.unreference(window, driver_.context) != 0) {
        ++counters_.unreferenceFailures;
        pendingRetirements_.push_back(window);
    }
}

void WindowHostCore::retryRetiredReferencesLocked() {
    for (auto item = pendingRetirements_.begin(); item != pendingRetirements_.end();) {
        if (driver_.unreference && driver_.unreference(*item, driver_.context) == 0) item = pendingRetirements_.erase(item);
        else { ++counters_.unreferenceFailures; ++item; }
    }
}

bool WindowHostCore::retryRetiredReferences() {
    std::lock_guard<std::mutex> lock(mutex_);
    retryRetiredReferencesLocked();
    return pendingRetirements_.empty();
}

uint64_t WindowHostCore::publish(void* window, int width, int height, AmclWindowHostCommitFn beforeCommit, void* context) {
    std::unique_lock<std::shared_mutex> inputLock(inputPublicationMutex_);
    std::lock_guard<std::mutex> lock(mutex_);
    if (snapshot_.generation == UINT64_MAX) return 0;
    if (window && (!driver_.reference || driver_.reference(window, driver_.context) != 0)) {
        ++counters_.referenceFailures;
        return 0;
    }
    retryRetiredReferencesLocked();
    void* previous = publicationReference_ ? snapshot_.nativeWindow : nullptr;
    snapshot_.nativeWindow = window;
    snapshot_.width = window ? width : 0;
    snapshot_.height = window ? height : 0;
    ++snapshot_.generation;
    publicationReference_ = window != nullptr;
    resourceEpoch_ = snapshot_.generation;
    geometryEpoch_ = snapshot_.generation;
    commit(previous, beforeCommit, context);
    return snapshot_.generation;
}

uint64_t WindowHostCore::updateSize(void* expected, uint64_t generation, int width, int height) {
    std::unique_lock<std::shared_mutex> inputLock(inputPublicationMutex_);
    std::lock_guard<std::mutex> lock(mutex_);
    if (!expected || !generation || expected != snapshot_.nativeWindow || generation != snapshot_.generation || generation == UINT64_MAX) return 0;
    const bool continuous = ready() && width > 0 && height > 0;
    snapshot_.width = width;
    snapshot_.height = height;
    ++snapshot_.generation;
    geometryEpoch_ = snapshot_.generation;
    // 零尺寸暂停与恢复不提供连续性保证，避免消费者漏看暂停后错误沿用 surface。
    if (!continuous) resourceEpoch_ = snapshot_.generation;
    commit();
    return snapshot_.generation;
}

uint64_t WindowHostCore::clear(void* expected, uint64_t generation) {
    std::unique_lock<std::shared_mutex> inputLock(inputPublicationMutex_);
    std::lock_guard<std::mutex> lock(mutex_);
    if (!expected || !generation || expected != snapshot_.nativeWindow || generation != snapshot_.generation || generation == UINT64_MAX) return 0;
    void* previous = publicationReference_ ? snapshot_.nativeWindow : nullptr;
    snapshot_.nativeWindow = nullptr;
    snapshot_.width = 0;
    snapshot_.height = 0;
    ++snapshot_.generation;
    publicationReference_ = false;
    resourceEpoch_ = snapshot_.generation;
    geometryEpoch_ = snapshot_.generation;
    commit(previous);
    return snapshot_.generation;
}

int WindowHostCore::acquire(void* retained, uint64_t generation, void** window, int* width, int* height, uint64_t* publishedGeneration) {
    std::lock_guard<std::mutex> lock(mutex_);
    return acquireLocked(retained, generation, window, width, height, publishedGeneration);
}

int WindowHostCore::acquireIdentity(void* retained, uint64_t generation, AmclNativeWindowIdentityV1* identity) {
    if (!identity || identity->abiVersion != 1 || identity->structSize < sizeof(*identity)) return 0;
    std::lock_guard<std::mutex> lock(mutex_);
    identity->resourceEpoch = resourceEpoch_;
    identity->geometryEpoch = geometryEpoch_;
    return acquireLocked(retained, generation, &identity->nativeWindow, &identity->width,
        &identity->height, &identity->generation);
}

// 由两个 ABI 入口共同调用，引用、尺寸、发布和 identity 必须处于同一锁事务。
int WindowHostCore::acquireLocked(void* retained, uint64_t generation, void** window, int* width, int* height, uint64_t* publishedGeneration) {
    if (window) *window = nullptr;
    if (width) *width = 0;
    if (height) *height = 0;
    if (publishedGeneration) *publishedGeneration = snapshot_.generation;
    if (!ready() || !window) return 0;
    int result = 1;
    if (retained == snapshot_.nativeWindow && generation == snapshot_.generation && leases_.count(retained) != 0) {
        ++counters_.reused;
        result = 2;
    } else {
        if (!driver_.reference || driver_.reference(snapshot_.nativeWindow, driver_.context) != 0) {
            ++counters_.referenceFailures;
            return 0;
        }
        leases_.granted(snapshot_.nativeWindow);
        ++counters_.acquired;
        ++counters_.liveLeases;
    }
    *window = snapshot_.nativeWindow;
    if (width) *width = snapshot_.width;
    if (height) *height = snapshot_.height;
    return result;
}

void WindowHostCore::release(void* window) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!leases_.consume(window)) { ++counters_.rejectedReleases; return; }
    --counters_.liveLeases;
    ++counters_.released;
    retire(window);
}

int WindowHostCore::claimPresentation(void* window, uint64_t generation, uint32_t api, uint64_t* token) {
    if (token) *token = 0;
    std::lock_guard<std::mutex> lock(mutex_);
    uint64_t result = 0;
    if (!token || !ready() || window != snapshot_.nativeWindow || generation != snapshot_.generation ||
        !presenter_.claim(window, generation, api, result)) {
        ++counters_.rejectedPresentations;
        return 0;
    }
    *token = result;
    return 1;
}

int WindowHostCore::movePresentation(uint64_t token, void* window, uint64_t generation) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!ready() || window != snapshot_.nativeWindow || generation != snapshot_.generation ||
        !presenter_.move(token, window, generation)) {
        ++counters_.rejectedPresentations;
        return 0;
    }
    return 1;
}

int WindowHostCore::releasePresentation(uint64_t token) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!presenter_.release(token)) { ++counters_.rejectedPresentations; return 0; }
    return 1;
}

int WindowHostCore::movePresentationGeometry(uint64_t token, void* window, uint64_t previous,
                                             uint64_t generation, uint64_t resourceEpoch) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!ready() || !resourceEpoch || resourceEpoch != resourceEpoch_ ||
        window != snapshot_.nativeWindow || generation != snapshot_.generation ||
        presenter_.generation() != previous || !presenter_.move(token, window, generation)) {
        ++counters_.rejectedPresentations;
        return 0;
    }
    return 1;
}

int WindowHostCore::beginInputPublication(int* width, int* height, uint64_t* generation) {
    if (width) *width = 0;
    if (height) *height = 0;
    if (generation) *generation = 0;
    inputPublicationMutex_.lock_shared();
    std::lock_guard<std::mutex> lock(mutex_);
    if (!ready()) { inputPublicationMutex_.unlock_shared(); return 0; }
    if (width) *width = snapshot_.width;
    if (height) *height = snapshot_.height;
    if (generation) *generation = snapshot_.generation;
    return 1;
}

void WindowHostCore::endInputPublication() { inputPublicationMutex_.unlock_shared(); }

AmclWindowHostSnapshot WindowHostCore::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return snapshot_;
}

AmclWindowHostStats WindowHostCore::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto result = counters_;
    result.generation = snapshot_.generation;
    result.state = snapshot_.state;
    result.publicationReference = publicationReference_ ? 1u : 0u;
    result.livePresentationToken = presenter_.token();
    result.pendingRetirements = pendingRetirements_.size();
    return result;
}
}
