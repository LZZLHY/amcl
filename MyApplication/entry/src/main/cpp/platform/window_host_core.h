#pragma once
#include "window_host.h"
#include "../glfw/amcl_native_window_lease_ledger.h"
#include "../glfw/amcl_presentation_owner.h"
#include <atomic>
#include <mutex>
#include <shared_mutex>
#include <vector>

namespace amcl::window {
// NativeWindow 引用计数驱动：生产为 OH_NativeWindow_NativeObject(Un)Reference，宿主测试注入
// 计数替身。只负责引用，不再镜像快照到环境变量（AMCL_NATIVE_WINDOW_SNAPSHOT 无读者，
// 每次 surface 事件写一次 environ 只会扩大 I27-05 的竞争面，已随 I27-05 删除）。
struct NativeReferenceDriver {
    int (*reference)(void*, void*) = nullptr;
    int (*unreference)(void*, void*) = nullptr;
    void* context = nullptr;
};

class WindowHostCore final {
public:
    explicit WindowHostCore(NativeReferenceDriver driver, uint64_t initialGeneration = 0);
    bool setReferenceDriver(NativeReferenceDriver driver);
    uint64_t publish(void*, int, int, AmclWindowHostCommitFn beforeCommit = nullptr,
                     void* context = nullptr, bool* textDemandWithdrawn = nullptr);
    uint64_t updateSize(void*, uint64_t, int, int, bool* textDemandWithdrawn = nullptr);
    uint64_t clear(void*, uint64_t, bool* textDemandWithdrawn = nullptr);
    int acquire(void*, uint64_t, void**, int*, int*, uint64_t*);
    int acquireIdentity(void*, uint64_t, AmclNativeWindowIdentityV1*);
    int movePresentationGeometry(uint64_t, void*, uint64_t, uint64_t, uint64_t);
    void release(void*);
    int claimPresentation(void*, uint64_t, uint32_t, uint64_t*);
    int movePresentation(uint64_t, void*, uint64_t);
    int releasePresentation(uint64_t);
    // 只核验当前呈现租约，不转移/续期；返回后不得假设锁仍由调用方持有。
    bool matchesPresentation(void*, uint64_t, uint64_t) const;
    bool matchesPresentationIdentity(void*,uint64_t,uint64_t,uint64_t) const;
    // 同一被引用NativeWindow从零面积恢复时，owner可能尚持旧发布代次；仅授权其
    // 安全点处理当前窗口，返回当前代次供entry再次CAS，不移动呈现token或证明GPU连续。
    uint64_t geometryCheckpointGeneration(void*, uint64_t, uint64_t) const;
    int setTextInputDemand(void*, uint64_t, uint32_t, uint32_t, bool* changed = nullptr);
    uint64_t textInputDemandIdentity() const { return activeTextInputDemand_.load(std::memory_order_acquire); }
    int runTextInputCommand(uint64_t demand, AmclWindowTextInputCommandFn command, void* context);
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
    void withdrawTextInputDemand(bool* wasActive);
    void retryRetiredReferencesLocked();
    NativeReferenceDriver driver_;
    mutable std::mutex mutex_;
    std::shared_mutex inputPublicationMutex_;
    AmclWindowHostSnapshot snapshot_{};
    // 公共旧 snapshot 的字节布局保持；epoch 仅通过尺寸可检查的新 broker 尾部输出。
    uint64_t resourceEpoch_ = 0;
    uint64_t geometryEpoch_ = 0;
    // NativeWindow对象连续性与GPU资源epoch不同：零面积会退休GPU资源，但仍可由
    // 原owner配置同一被引用对象；clear/publish即使同地址也必须拒绝原owner的配置。
    uint64_t objectEpoch_ = 0;
    uint64_t presentationObjectEpoch_ = 0;
    // 每个请求属于精确发布代与SDL窗口；序号还区分一次唤醒中合并的关闭、再打开。
    uint64_t textInputPublicationGeneration_ = 0;
    uint64_t textInputDemandSerial_ = 0;
    // SDL事件队列持有自己的锁。终消费只需原子读，禁止进入WindowHost锁或平台回调。
    std::atomic<uint64_t> activeTextInputDemand_{0};
    uint32_t textInputSdlWindowId_ = 0;
    bool publicationReference_ = false;
    AmclNativeWindowLeaseLedger leases_;
    AmclPresentationOwner presenter_;
    std::vector<void*> pendingRetirements_;
    AmclWindowHostStats counters_{};
    std::atomic<uint64_t> peekGeneration_{0};
    std::atomic<AmclNativeWindowPublicationState> peekState_{AMCL_NATIVE_WINDOW_PUBLICATION_UNPUBLISHED};
};
}
