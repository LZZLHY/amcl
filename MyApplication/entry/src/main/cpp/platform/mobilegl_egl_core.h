#pragma once

#include "desktop_egl_core.h"

namespace amcl::graphics {
/**
 * MobileGL OHOS 的窗口几何由 WindowHost 租约给出，创建时须显式传递到 Vulkan 后端。
 * 当前 MobileGL EGLState 的 window 宽高初始为 0，只有内部 ResizePlatformWindowSurface
 * 会更新；它不是已导出的 EGL 接口，不能假定首次 swap 会补齐。查询成功且双维为 0
 * 时采用已传入的租约尺寸；查询失败、负数或仅一维为 0 仍拒绝。pbuffer 不走此规则。
 * 该尺寸处理只解决窗口协议，不代替独立的 provider 身份与真实 draw/present 探测。
 */
struct MobileGlSurfaceGeometry {
    static constexpr bool RequiresNativeWindow = true;
    int nativeWidth, nativeHeight;
    template<class Api>
    EGLSurface Create(const Api& api, EGLDisplay display, EGLConfig config, void* nativeWindow) const {
        if (!nativeWindow || nativeWidth <= 0 || nativeHeight <= 0) return EGL_NO_SURFACE;
        const EGLint attributes[] = {EGL_WIDTH, nativeWidth, EGL_HEIGHT, nativeHeight, EGL_NONE};
        return api.eglCreateWindowSurface(display, config,
            reinterpret_cast<EGLNativeWindowType>(nativeWindow), attributes);
    }
    template<class Api>
    bool Measure(const Api& api, EGLDisplay display, EGLSurface surface, EGLint& width, EGLint& height,
                 EglLifecycleStatus* status = nullptr) const {
        if (!api.eglQuerySurface(display, surface, EGL_WIDTH, &width) ||
            !api.eglQuerySurface(display, surface, EGL_HEIGHT, &height))
            return EglLifecycleFailure(api, "mobilegl-window-size-query", true, status);
        if (width == 0 && height == 0) { width = nativeWidth; height = nativeHeight; }
        return (width > 0 && height > 0) || EglLifecycleFailure(api, "mobilegl-window-size-invalid", false, status);
    }
};

/**
 * MobileGL 提供桌面 OpenGL 语义，复用 OpenGL context 生命周期而不是 GLES 版本钳制。
 * 宿主只允许一个 presented GLFW window；共享/固定管线上下文不在本 adapter 的承诺中。
 * 首次窗口绑定之后验证停车及还原，确保前后台切换不会到第一次失活时才发现不支持。
 */
template<class Api, class Window, class Resolver>
bool CreateMobileGlEgl(const Api& api, Window& win, const amcl::desktop::ContextRequest& request,
                       Resolver resolve, int tid, std::string& error, bool auxiliary = false, bool sharingVerified = false,
                       EglLifecycleStatus* status = nullptr) {
    if ((!sharingVerified && win.shareContext != EGL_NO_CONTEXT) || request.major < 3 || request.profile == 0x00032002) {
        error = "MobileGL requires modern OpenGL and verified sharing before accepting a shared context";
        return false;
    }
    if (win.width <= 0 || win.height <= 0) {
        error = "mobilegl-native-window-size";
        return false;
    }
    const MobileGlSurfaceGeometry geometry{win.width, win.height};
    const bool created = auxiliary ? amcl::desktop::CreateDesktopEgl(api, win, request, resolve, tid, error,
        amcl::desktop::EglPbufferGeometry{win.width, win.height}, status) :
        amcl::desktop::CreateDesktopEgl(api, win, request, resolve, tid, error, geometry, status);
    if (!created) return false;
    using GetString = const unsigned char* (*)(unsigned);
    const auto getString = reinterpret_cast<GetString>(resolve("glGetString"));
    const char* version = getString ? reinterpret_cast<const char*>(getString(0x1f02)) : nullptr;
    if (!version || !std::strstr(version, "MobileGL") || !std::strstr(version, "Vulkan")) {
        error = "mobilegl-direct-vulkan-context-identity";
        return false;
    }
    // 停车尺寸、绑定与还原由公共desktop核心完成；此处只增加MobileGL实现身份校验。
    return true;
}

// 恢复使用新租约的几何创建 window surface，停车 context 与全部 GL 对象仍沿用原局。
// 失败句柄由公共 attach 核心保留，BackendSession 在退休完成前不会释放对应租约。
template<class Api, class Window>
bool AttachMobileGlEglSurface(const Api& api, Window& win, void* nativeWindow,
                             int width, int height, int tid, EglLifecycleStatus* status = nullptr) {
    return amcl::desktop::AttachDesktopEglSurface(api, win, nativeWindow, width, height, tid,
        MobileGlSurfaceGeometry{width, height}, status);
}

/**
 * MobileGL 的 EGL display 属于本局 provider，可在最后一个 GLFW window 资源退休后终止。
 * terminate 失败时恢复 display 句柄并标记待清理，使 BackendSession 保留租约而非假成功。
 * 系统 EGL / MG 的共享 display 不经过本函数。
 */
template<class Api, class Window>
bool DestroyMobileGlEgl(const Api& api, Window& win, int tid) {
    const EGLDisplay display = win.display;
    if (!amcl::desktop::DestroyDesktopEgl(api, win, tid)) return false;
    if (display != EGL_NO_DISPLAY && !api.eglTerminate(display)) {
        win.display = display;
        win.eglTeardownPending = true;
        return false;
    }
    return true;
}
}
