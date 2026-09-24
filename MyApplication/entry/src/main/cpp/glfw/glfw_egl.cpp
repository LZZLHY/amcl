// GLFW只传递窗口请求与资源状态；后端生命周期由中立运行时的冻结操作表执行。
// UI线程不调用这里，失败保留驱动句柄和broker租约，不能换一个provider继续运行。
#include "glfw_internal.h"
#include "../platform/graphics_runtime_binding.h"
#include "../utils/amcl_log_bridge.h"
#include <unistd.h>
#include <cstdlib>
#undef LOG_TAG
#define LOG_TAG "GLFW_EGL"
namespace {
bool report(GLFWwindow* win, const char* operation, bool result, const std::string& error) {
    if (result) return true;
    AMCL_EXTERNAL_LOG_E(LOG_TAG, "GLFW: EGL %{public}s failed: %{public}s", operation, error.c_str());
    if (win && win->contextLostFatal) setenv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART", "1", 1);
    if (g_errorCallback) g_errorCallback(GLFW_PLATFORM_ERROR, error.c_str());
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
