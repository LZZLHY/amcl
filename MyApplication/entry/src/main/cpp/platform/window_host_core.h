#pragma once
#include "window_host.h"
#include "../glfw/amcl_native_window_lease_ledger.h"
#include "../glfw/amcl_presentation_owner.h"
#include <atomic>
#include <mutex>
#include <shared_mutex>
#include <vector>

namespace amcl::window {
struct NativeReferenceDriver {
    int (*reference)(void*, void*) = nullptr;
    int (*unreference)(void*, void*) = nullptr;
    void* context = nullptr;
    void (*publishSnapshot)(const AmclWindowHostSnapshot&, void*) = nullptr;
};

class WindowHostCore final {
public:
    explicit WindowHostCore(NativeReferenceDriver driver, uint64_t initialGeneration = 0);
    bool setReferenceDriver(NativeReferenceDriver driver);
    uint64_t publish(void*, int, int, AmclWindowHostCommitFn beforeCommit = nullptr, void* context = nullptr);
    uint64_t updateSize(void*, uint64_t, int, int);
    uint64_t clear(void*, uint64_t);
    int acquire(void*, uint64_t, void**, int*, int*, uint64_t*);
    int acquireIdentity(void*, uint64_t, AmclNativeWindowIdentityV1*);
    int movePresentationGeometry(uint64_t, void*, uint64_t, uint64_t, uint64_t);
    void release(void*);
    int claimPresentation(void*, uint64_t, uint32_t, uint64_t*);
    int movePresentation(uint64_t, void*, uint64_t);
    int releasePresentation(uint64_t);
    int beginInputPublication(int*, int*, uint64_t*);
    void endInputPublication();
    AmclWindowHostSnapshot snapshot() const;
    AmclWindowHostStats stats() const;
    bool retryRetiredReferences();
    uint64_t peekGeneration() const { return peekGeneration_.load(std::memory_order_acquire); }
    AmclNativeWindowPublicationState peekState() const { return peekState_.load(std::memory_order_acquire); }
private:
    bool ready() const;
    int acquireLocked(void*, uint64_t, void**, int*, int*, uint64_t*);
    void commit(void* retiredPublication = nullptr, AmclWindowHostCommitFn beforeCommit = nullptr, void* context = nullptr);
    void retire(void*);
    void retryRetiredReferencesLocked();
    NativeReferenceDriver driver_;
    mutable std::mutex mutex_;
    std::shared_mutex inputPublicationMutex_;
    AmclWindowHostSnapshot snapshot_{};
    // 公共旧 snapshot 的字节布局保持；epoch 仅通过尺寸可检查的新 broker 尾部输出。
    uint64_t resourceEpoch_ = 0;
    uint64_t geometryEpoch_ = 0;
    bool publicationReference_ = false;
    AmclNativeWindowLeaseLedger leases_;
    AmclPresentationOwner presenter_;
    std::vector<void*> pendingRetirements_;
    AmclWindowHostStats counters_{};
    std::atomic<uint64_t> peekGeneration_{0};
    std::atomic<AmclNativeWindowPublicationState> peekState_{AMCL_NATIVE_WINDOW_PUBLICATION_UNPUBLISHED};
};
}
