#pragma once
#include "graphics_runtime_export.h"
#include "graphics_context_abi.h"
#include "sdl_aux_runtime_policy.h"
#include <atomic>
#include <mutex>
#include <set>
#include <map>
#include <string>
#include <cstdint>
namespace amcl::graphics {
struct GraphicsRuntimeBinding;
using EglContextState = AmclGraphicsContextStateV1;
/** 设备功能的实测状态与生命周期账本，地址由冻结binding持有，跨namespace共用。
 * 声明支持/符号存在不等于verified；功能正确性与性能保持独立，未知不能用于开放共享。
 */
enum class FeatureEvidence { NotRun, Unsupported, Verified, Unknown };
// 真实owner在window-surface创建/attach完整成功后保存的值副本。不借用前端可变
// state指针；pbuffer创建不进入此表，避免把worker context和主窗口token拼成资格。
struct PresentingEglIdentity {
    void* display = nullptr;
    void* context = nullptr;
    void* surface = nullptr;
    void* nativeWindow = nullptr;
    bool matches(const AmclSdlAuxRequestV1& proof) const {
        return display == proof.display && context == proof.context &&
            surface == proof.drawSurface && nativeWindow == proof.nativeWindow;
    }
};
struct GraphicsFeatureState {
    std::mutex mutex;
    bool probed = false;
    std::atomic<bool> cleanupSafe{true};
    FeatureEvidence bufferCopy = FeatureEvidence::NotRun, fence = FeatureEvidence::NotRun;
    FeatureEvidence auxiliary = FeatureEvidence::NotRun, sharedObjects = FeatureEvidence::NotRun;
    FeatureEvidence contextIsolation = FeatureEvidence::NotRun, independentObjects = FeatureEvidence::NotRun;
    uint64_t elapsedNs = 0;
    std::string vendor, renderer, version, reason;
    // 异常收尾保留探针资源身份供进程级退休；绝不在错误context删除这些名字。
    void* retainedSharedContext = nullptr; void* retainedIndependentContext = nullptr; void* retainedSurface = nullptr;
    unsigned retainedBuffers[2]{};
    // 仅由生命周期操作访问。一个display可有多个GLFW context；最后一个退休才允许terminate。
    std::recursive_mutex resourcesMutex;
    std::set<EglContextState*> contexts;
    // 首个成功交付的 context 证明 display 已完成初始化。窗口字段在 destroy 时会清空，
    // 此 owner 记录独立于 GLFW/SDL 窗口表；仅真实 provider eglTerminate 成功后退休。
    void* initializedEglDisplay = nullptr;
    uint64_t nextShareGroup = 0;
    // 前端无关的真实context资格账本，0句柄表示驱动创建中的预留。SDL的多个surface
    // 不增加记录；并发创建必须先看到预留，不能同时把自己当成第一个context。
    std::map<uint64_t, void*> contextPermits;
    std::map<uint64_t, PresentingEglIdentity> presentingSurfaces;
    uint64_t nextContextPermit = 0;
    // 与contextPermits同锁，保证角色验证和首次消费不能跨越context退休。
    struct SdlAuxSessionState {
        // 每个实例分别持有准入策略和已确认的线程、会话身份。
        SdlAuxRuntimePolicy policy;
        // 首次 claim 在资源锁内发布固定身份；退休只清 alive，事件泵按 acquire 无锁核验。
        uint64_t sessionId=0,instanceId=0;
        int32_t launchThreadId=0,ownerThreadId=0;
        std::atomic<bool> alive{false};
    };
    // LWJGL 平台 SDK 与第三方无窗口 SDK 独立登记，只读同一平台手柄快照。
    SdlAuxSessionState sdlAux,controllerAux;
};
// 在新context交付游戏前执行一次有界小对象探针；任何清理/原context恢复失败均返回false。
AMCL_GRAPHICS_PUBLIC bool ProbeGraphicsFeatures(const GraphicsRuntimeBinding&, EglContextState&);
AMCL_GRAPHICS_PUBLIC bool GraphicsAuxiliaryVerified(const GraphicsRuntimeBinding&, bool shared);
AMCL_GRAPHICS_PUBLIC std::string GraphicsFeaturesJson(const GraphicsRuntimeBinding&);
AMCL_GRAPHICS_PUBLIC bool GraphicsCleanupSafe(const GraphicsRuntimeBinding&);
AMCL_GRAPHICS_PUBLIC uint64_t ReserveGraphicsContext(const GraphicsRuntimeBinding&, void* shareContext);
AMCL_GRAPHICS_PUBLIC bool CommitGraphicsContext(const GraphicsRuntimeBinding&, uint64_t permit, void* context);
AMCL_GRAPHICS_PUBLIC bool RetireGraphicsContext(const GraphicsRuntimeBinding&, void* context);
// 仅本方生命周期在证明部分创建的资源已经完整退休后释放预留；SDL创建异常保留到进程退出。
AMCL_GRAPHICS_PUBLIC void ReleaseGraphicsContextPermit(const GraphicsRuntimeBinding&, uint64_t permit);
// 只由实际生命周期owner调用；成功surface资格与permit同锁，失败不授予准入。
bool RecordPresentingEglSurface(const GraphicsRuntimeBinding&, const EglContextState&);
void RevokePresentingEglSurface(const GraphicsRuntimeBinding&, const EglContextState&);
}
