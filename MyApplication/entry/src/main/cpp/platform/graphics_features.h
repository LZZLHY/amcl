#pragma once
#include "graphics_runtime_export.h"
#include "graphics_context_abi.h"
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
    uint64_t nextShareGroup = 0;
    // 前端无关的真实context资格账本，0句柄表示驱动创建中的预留。SDL的多个surface
    // 不增加记录；并发创建必须先看到预留，不能同时把自己当成第一个context。
    std::map<uint64_t, void*> contextPermits;
    uint64_t nextContextPermit = 0;
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
}
