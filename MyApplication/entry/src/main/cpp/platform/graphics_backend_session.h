#pragma once
#include "../glfw/amcl_native_window_lease_broker_abi.h"
#include <cstdint>
#include "graphics_runtime_export.h"
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace amcl::graphics {
enum class BackendSessionState : uint8_t { kNew, kPrepared, kAttached, kSuspended, kDetached, kDestroyed, kFailed };
struct NativeWindowLease {
    void* nativeWindow = nullptr;
    uint64_t generation = 0;
    int width = 0;
    int height = 0;
    bool ownsReference = false;
    uint64_t resourceEpoch = 0;
    uint64_t geometryEpoch = 0;
    bool valid() const { return nativeWindow != nullptr && generation != 0; }
};

// Adapter callbacks are owned by the rendering backend. BackendSession only
// coordinates their ordering and never destroys backend-owned Vulkan objects.
struct BackendAdapterCallbacks {
    std::function<bool(std::string&)> prepare;
    std::function<bool(const NativeWindowLease&, std::string&)> attach;
    std::function<bool(std::string&)> resourcesCreated;
    std::function<bool(std::string&)> resourcesRetired;
    std::function<bool(int, int, std::string&)> resize;
    std::function<bool(std::string&)> suspend;
    std::function<bool(const NativeWindowLease&, std::string&)> resume;
    std::function<bool(std::string&)> detach;
    std::function<bool(bool, std::string&)> destroy;
};

class BackendAdapter {
public:
    virtual ~BackendAdapter() = default;
    virtual bool onPrepare(std::string& error) { (void)error; return true; }
    virtual bool onAttach(const NativeWindowLease& lease, std::string& error) { (void)lease; (void)error; return true; }
    virtual bool onResourcesCreated(std::string& error) { (void)error; return true; }
    virtual bool onResourcesRetired(std::string& error) { (void)error; return true; }
    virtual bool onResize(int width, int height, std::string& error) { (void)width; (void)height; (void)error; return true; }
    virtual bool onSuspend(std::string& error) { (void)error; return true; }
    virtual bool onResume(const NativeWindowLease& lease, std::string& error) { (void)lease; (void)error; return true; }
    virtual bool onDetach(std::string& error) { (void)error; return true; }
    // resourcesDestroyed is a fact supplied by the backend owner. A Vulkan
    // adapter must return false when it would require destroying game objects.
    virtual bool onDestroy(bool resourcesDestroyed, std::string& error) {
        if (!resourcesDestroyed) error = "resource owner has not confirmed teardown";
        return resourcesDestroyed;
    }
};

class CallbackBackendAdapter : public BackendAdapter {
public:
    explicit CallbackBackendAdapter(BackendAdapterCallbacks callbacks) : callbacks_(std::move(callbacks)) {}
    bool onPrepare(std::string& e) override { return invoke(callbacks_.prepare, e); }
    bool onAttach(const NativeWindowLease& l, std::string& e) override { return callbacks_.attach ? callbacks_.attach(l, e) : true; }
    bool onResourcesCreated(std::string& e) override { return invoke(callbacks_.resourcesCreated, e); }
    bool onResourcesRetired(std::string& e) override { return invoke(callbacks_.resourcesRetired, e); }
    bool onResize(int w, int h, std::string& e) override { return callbacks_.resize ? callbacks_.resize(w, h, e) : true; }
    bool onSuspend(std::string& e) override { return invoke(callbacks_.suspend, e); }
    bool onResume(const NativeWindowLease& l, std::string& e) override { return callbacks_.resume ? callbacks_.resume(l, e) : true; }
    bool onDetach(std::string& e) override { return invoke(callbacks_.detach, e); }
    bool onDestroy(bool r, std::string& e) override { return callbacks_.destroy ? callbacks_.destroy(r, e) : r; }
private:
    static bool invoke(const std::function<bool(std::string&)>& callback, std::string& e) { return callback ? callback(e) : true; }
protected:
    BackendAdapterCallbacks callbacks_;
};

class EglBackendSessionAdapter : public CallbackBackendAdapter {
public:
    explicit EglBackendSessionAdapter(BackendAdapterCallbacks c) : CallbackBackendAdapter(std::move(c)) {}
    bool onPrepare(std::string& error) override {
        if (!callbacks_.attach || !callbacks_.resize || !callbacks_.suspend || !callbacks_.resume ||
            !callbacks_.detach || !callbacks_.destroy) {
            error = "EGL adapter lifecycle operations are incomplete";
            return false;
        }
        return CallbackBackendAdapter::onPrepare(error);
    }
};
class MobileGlBackendSessionAdapter : public EglBackendSessionAdapter { public: explicit MobileGlBackendSessionAdapter(BackendAdapterCallbacks c) : EglBackendSessionAdapter(std::move(c)) {} };
class SystemOpenGLBackendSessionAdapter : public EglBackendSessionAdapter { public: explicit SystemOpenGLBackendSessionAdapter(BackendAdapterCallbacks c) : EglBackendSessionAdapter(std::move(c)) {} };
class MinecraftVulkanBackendSessionAdapter : public CallbackBackendAdapter {
public:
    explicit MinecraftVulkanBackendSessionAdapter(BackendAdapterCallbacks c = {}) : CallbackBackendAdapter(std::move(c)) {}
    bool onDestroy(bool resourcesDestroyed, std::string& error) override {
        if (!resourcesDestroyed) { error = "game-owned Vulkan resources are still live"; return false; }
        return CallbackBackendAdapter::onDestroy(true, error);
    }
};

class NativeWindowBroker {
public:
    virtual ~NativeWindowBroker() = default;
    virtual bool acquire(const NativeWindowLease*, NativeWindowLease&, std::string&) = 0;
    virtual void release(NativeWindowLease&) = 0;
    virtual bool claimPresentOwner(uint64_t, const NativeWindowLease&, std::string&) = 0;
    // Move the existing opaque token atomically. The old surface must already
    // be retired; a failed move leaves the old token and lease unchanged.
    virtual bool movePresentOwner(uint64_t, const NativeWindowLease&, std::string&) = 0;
    // 未实现 identity 扩展的旧 broker 始终要求完整重建，不能按指针猜测资源连续。
    virtual bool moveGeometryOwner(uint64_t, const NativeWindowLease&, const NativeWindowLease&, std::string&) { return false; }
    virtual bool releasePresentOwner(uint64_t, std::string&) = 0;
    virtual uint64_t currentGeneration() const = 0;
};

class AMCL_GRAPHICS_PUBLIC AbiNativeWindowBroker final : public NativeWindowBroker {
public:
    explicit AbiNativeWindowBroker(const AmclNativeWindowLeaseBrokerV2*, uint32_t api = 1);
    bool acquire(const NativeWindowLease*, NativeWindowLease&, std::string&) override;
    void release(NativeWindowLease&) override;
    bool claimPresentOwner(uint64_t, const NativeWindowLease&, std::string&) override;
    bool movePresentOwner(uint64_t, const NativeWindowLease&, std::string&) override;
    bool moveGeometryOwner(uint64_t, const NativeWindowLease&, const NativeWindowLease&, std::string&) override;
    bool releasePresentOwner(uint64_t, std::string&) override;
    uint64_t currentGeneration() const override;
    const AmclNativeWindowLeaseBrokerV2* abi() const { return abi_; }
private:
    const AmclNativeWindowLeaseBrokerV2* abi_;
    mutable std::mutex mutex_;
    uint64_t presentOwner_ = 0;
    uint64_t presentGeneration_ = 0;
    uint64_t presentationToken_ = 0;
    uint32_t api_ = 1;
};

class AMCL_GRAPHICS_PUBLIC BackendSession final {
public:
    BackendSession(uint64_t, std::string, std::shared_ptr<NativeWindowBroker>, std::shared_ptr<BackendAdapter>);
    ~BackendSession();
    BackendSession(const BackendSession&) = delete;
    BackendSession& operator=(const BackendSession&) = delete;
    bool prepare(std::string&);
    bool attach(std::string&);
    bool attach(const NativeWindowLease&, std::string&);
    bool markResourcesCreated(std::string&);
    bool markResourcesRetired(std::string&);
    // Called only after the backend reports a successful real presentation.
    bool recordPresent(std::string&);
    bool resize(int, int, uint64_t, std::string&);
    bool refreshGeometry(int, int, uint64_t, std::string&);
    bool suspend(std::string&);
    bool resume(std::string&);
    bool detach(std::string&);
    bool destroy(bool, std::string&);
    bool fail(const std::string&);
    BackendSessionState state() const { return state_; }
    uint64_t generation() const { return lease_.generation; }
    const NativeWindowLease& lease() const { return lease_; }
    const std::string& profile() const { return profile_; }
    uint64_t sessionId() const { return sessionId_; }
    bool hasResources() const { return resourcesCreated_; }
    bool hasPresentOwner() const { return presentOwner_; }
    uint64_t presentCount() const { return presentCount_; }
    // A destructor that cannot retire API resources transfers the complete
    // owner to quarantine. The retained adapter/broker keep cleanup callable.
    static size_t quarantinedCount();
    static uint64_t quarantineFailureCount();
    static bool retryQuarantined(std::string&);
private:
    bool acquireAndClaim(const NativeWindowLease*, std::string&);
    bool replaceLease(uint64_t, std::string&);
    void releaseRetiredLeases();
    bool abandonOwnership(std::string&);
    bool adapterDestroy(bool, std::string&);
    uint64_t sessionId_;
    std::string profile_;
    std::shared_ptr<NativeWindowBroker> broker_;
    std::shared_ptr<BackendAdapter> adapter_;
    BackendSessionState state_ = BackendSessionState::kNew;
    NativeWindowLease lease_{};
    std::vector<NativeWindowLease> retiredLeases_;
    bool presentOwner_ = false;
    bool resourcesCreated_ = false;
    uint64_t presentCount_ = 0;
};
}
