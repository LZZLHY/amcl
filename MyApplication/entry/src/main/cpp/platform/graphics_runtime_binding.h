#pragma once
#include "graphics_profile_mirror.generated.h"
#include "graphics_runtime_export.h"
#include "graphics_runtime_abi.h"
#include "graphics_egl_context.h"
#include "graphics_features.h"
#include "system_egl.h"
#include <cstdint>
#include <memory>
#include <string>

namespace amcl::graphics {
/** 所有窗口前端共享的进程期图形绑定。调用者只能取得 const 视图，不能重新选库或替换函数表。
 * Freeze 在已激活启动计划后调用；失败不发布半成品。fork 继承的绑定明确拒绝使用。
 * DSO 与表保留至进程退出，context/surface 的所有权仍在各 BackendSession。
 */
struct AMCL_GRAPHICS_PUBLIC GraphicsRuntimeBinding {
    int processId = 0;
    const GraphicsProfileMetadata* profile = nullptr;
    amcl::desktop::SystemEglApi egl;
    void* glLibrary = nullptr;
    void* eglLibrary = nullptr;
    void* providerImage = nullptr;
    void* (*glResolver)(const char*) = nullptr;
    void* (*eglResolver)(const char*) = nullptr;
    uint64_t (*providerPresentSequence)() = nullptr;
    const EglContextOperations* contextOperations = nullptr;
    AmclGraphicsRuntimeV1 publicApi{};
    // 非owner映像只持C描述符及本地只读视图；features永远不借用另一个C++映像中的地址。
    const AmclGraphicsRuntimeV1* delegate = nullptr;
    // 实际装入制品报告的不可变实现身份；未知版本不能获准使用历史MG专用规避。
    std::string implementationIdentity;
    std::unique_ptr<GraphicsFeatureState> features;
    void* glProc(const char* name) const;
    void* eglProc(const char* name) const;
    void* providerProc(const char* name) const;
    bool desktopGl() const { return profile && GraphicsProfileStringEqual(profile->contextApi, "desktop-gl"); }
    bool is(const char* id) const { return profile && GraphicsProfileStringEqual(profile->id, id); }
};
AMCL_GRAPHICS_PUBLIC bool FreezeGraphicsRuntime(const char* profile, const char* api, std::string& error);
AMCL_GRAPHICS_PUBLIC const GraphicsRuntimeBinding* BoundGraphicsRuntime();
// 唯一环境兼容入口：只在未绑定时读取启动器发布的值；绑定后所有消费端读 const 状态。
AMCL_GRAPHICS_PUBLIC const GraphicsRuntimeBinding* RequireGraphicsRuntime();
}

/** libentry 的只读观察入口；没有绑定或当前 PID 不匹配时返回空，不创建任何 context。
 * 函数表所有权在中立 libamcl_graphics_runtime 内，调用者不得释放或缓存到下一游戏进程。
 */
extern "C" __attribute__((visibility("default"))) void* amclGraphicsGlProcV1(const char* name);
extern "C" __attribute__((visibility("default"))) void* amclGraphicsEglProcV1(const char* name);
extern "C" __attribute__((visibility("default"))) int amclGraphicsBindRuntimeV1(
    const char* profile, const char* api, char* error, int capacity);
// 只读进程服务身份，供诊断核对不同linker namespace确实消费同一owner；未发布时为0。
extern "C" AMCL_GRAPHICS_PUBLIC uintptr_t amclGraphicsRuntimeOwnerV1();
// 返回1表示本provider要求比较同线程的实际呈现序列；0表示普通EGL成功语义，输出清零。
extern "C" AMCL_GRAPHICS_PUBLIC int amclGraphicsReadPresentSequenceV1(uint64_t* sequence);
extern "C" AMCL_GRAPHICS_PUBLIC int amclGraphicsInspectContextV1(void* display, void* config, void* context,
    void* surface, int major, int minor, int profile);
