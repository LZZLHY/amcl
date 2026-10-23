// GLFW只传递窗口请求与资源状态；后端生命周期由中立运行时的冻结操作表执行。
// UI线程不调用这里，失败保留驱动句柄和broker租约，不能换一个provider继续运行。
#include "glfw_internal.h"
#include "../platform/graphics_runtime_binding.h"
#include "../platform/graphics_observation_abi.h"
#include "../utils/amcl_log_bridge.h"
#include <unistd.h>
#include <cstdlib>
#undef LOG_TAG
#define LOG_TAG "GLFW_EGL"
// 定义在 glfw_compat.cpp：经已登记环境槽位原位置重启标记，绝不 setenv（I27-05）。
void requestRendererProcessRestart(const char* stage);
namespace {
bool report(GLFWwindow* win, const char* operation, bool result, const std::string& error) {
    if (result) return true;
    AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: EGL %{public}s failed: %{public}s", operation, error.c_str());
    if (win && win->contextLostFatal) {
        requestRendererProcessRestart(operation);
        // typed 生命周期已在驱动失败边界保存原始错误。先交付确切的 context lost，
        // 外层随后发出的通用 window-create-failed 不能覆盖进程故障总线锁存的首因。
        // 功能探针等其他终局原因没有该驱动错误，不能仅凭 fatal 标志伪报 context lost。
        if (win->lastFailure.driverFailure && win->lastFailure.error == EGL_CONTEXT_LOST)
            amclGraphicsFatalV1("egl-context-lost", static_cast<uint32_t>(win->lastFailure.error),
                win->nativeWindowGeneration);
    }
    // 这里仍在 BackendSession 的 attach/suspend/resume/destroy 事务栈内。用户错误
    // 回调可以销毁窗口和该 session，不能在内部事务未返回时调用；公共 GLFW 边界负责
    // 在状态提交/资源保留完成后通知用户，并在回调之后立即返回。
    return false;
}
const amcl::graphics::GraphicsRuntimeBinding* runtime(GLFWwindow* win) {
    const auto* value = amcl::graphics::RequireGraphicsRuntime();
    return win && win->clientAPI != GLFW_NO_API && value && value->egl.ready && value->contextOperations ? value : nullptr;
}
}
// 首次窗口/停车/context验证由选定实现完成，实际版本只在成功交付后反映到旧hint查询。
bool InitEGL(GLFWwindow* win) {
    const auto* value = runtime(win); std::string error;
    if (!value) return report(win, "initialize", false, "selected runtime has no complete OpenGL operations");
    const amcl::desktop::ContextRequest request{g_hintMajor, g_hintMinor, g_hintProfile, g_hintForwardCompatible};
    if (!report(win, "initialize", value->contextOperations->create(*value, *win, request, static_cast<int>(gettid()), error), error)) return false;
    if (!amcl::graphics::ProbeGraphicsFeatures(*value, *win)) {
        win->contextLostFatal = true;
        return report(win, "functional-probe", false, "functional probe could not restore and retire its temporary resources");
    }
    if (!value->contextOperations->desktopApi && (g_hintMajor > 3 ? 3 : g_hintMajor) != win->actualContextMajor) {
        g_hintMajor = win->actualContextMajor; g_hintMinor = 0;
    }
    amclExternalLogWrite(1, LOG_TAG, "graphics_context_ready profile=%{public}s implementation=%{public}s runtime_owner=%{public}llu parking=verified version=%{public}d.%{public}d",
        value->profile->id, value->contextOperations->implementation, static_cast<unsigned long long>(amclGraphicsRuntimeOwnerV1()),
        win->actualContextMajor, win->actualContextMinor);
    return true;
}
// surface暂停保留context对象域；驱动失败时句柄不丢失，由BackendSession协调后续重试。
bool SuspendEGLSurface(GLFWwindow* win) {
    if (!win) return true; const auto* value = runtime(win); std::string error;
    return value ? report(win, "suspend", value->contextOperations->suspend(*value, *win, static_cast<int>(gettid()), error), error) : false;
}
// 仅在会话持有新租约、旧surface已退休后挂接；operation表与原context属于同一provider。
bool AttachEGLSurface(GLFWwindow* win, void* nativeWindow, int width, int height) {
    const auto* value = runtime(win); std::string error;
    return value ? report(win, "attach", value->contextOperations->attach(*value, *win, nativeWindow, width, height, static_cast<int>(gettid()), error), error) : false;
}
// 未分配资源的拒绝可以收口；已有句柄且运行时不可用时必须保留所有权，不能假装销毁成功。
bool TerminateEGL(GLFWwindow* win) {
    if (!win) return true; const auto* value = runtime(win); std::string error;
    if (!value) return win->display == EGL_NO_DISPLAY && win->context == EGL_NO_CONTEXT && win->surface == EGL_NO_SURFACE && win->parkingSurface == EGL_NO_SURFACE;
    if (!amcl::graphics::GraphicsCleanupSafe(*value))
        return report(win, "destroy", false, "functional probe retained context resources until process exit");
    return report(win, "destroy", value->contextOperations->destroy(*value, *win, static_cast<int>(gettid()), error), error);
}
