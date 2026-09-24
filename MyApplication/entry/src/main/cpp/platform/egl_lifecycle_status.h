#pragma once
#include <EGL/egl.h>
#include <cstdio>
#include <string>
#include "graphics_context_abi.h"

namespace amcl::graphics {
/** 一次生命周期操作的失败事实。stage 指向进程期字面量；只有真正失败的驱动调用
 * 才消费 eglGetError，线程/状态拒绝保留 EGL_SUCCESS，避免把旧错误误报为 context lost。
 * 资源句柄仍由调用方状态持有，本结构不会清理、重试或跨线程转移所有权。
 */
struct EglLifecycleStatus {
    const char* stage = "";
    EGLint error = EGL_SUCCESS;
    bool driverFailure = false;
    operator AmclEglFailureV1() const { return {stage, error, driverFailure ? 1u : 0u}; }
    bool contextLost() const { return driverFailure && error == EGL_CONTEXT_LOST; }
    std::string text() const {
        if (!driverFailure) return stage;
        char detail[192];
        std::snprintf(detail, sizeof(detail), "%s (EGL 0x%04x)", stage, static_cast<unsigned>(error));
        return detail;
    }
};

// 所有desktop/MobileGL生命周期共享同一错误采集边界；先保存原始错误，再由上层
// 决定终局/恢复，后续资源退休的错误不得覆盖首次失败的分类。
template<class Api>
bool EglLifecycleFailure(const Api& api, const char* stage, bool driver, EglLifecycleStatus* output) {
    const EGLint error = driver ? api.eglGetError() : EGL_SUCCESS;
    if (output) *output = {stage, error, driver};
    return false;
}
}
