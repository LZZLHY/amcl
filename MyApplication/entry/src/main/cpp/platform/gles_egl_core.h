#pragma once

// GLFW 的 GLES 呈现生命周期核心。MobileGlues 与 GL4ES 使用同一套资源顺序，
// 但调用者必须注入所选 provider 的入口：MG 的 MakeCurrent 还维护自己的对象域，
// 不能绕过 wrapper 直接调用系统 EGL。模板注入使宿主测试执行这份生产代码。
#include <cstdint>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <cstdio>
#include <string>
#include "egl_lifecycle_status.h"

namespace amcl::graphics {

// 仅在失败边界读取一次 EGL error，保留阶段与错误码；普通资源操作不新增日志。
template<class Api>
bool GlesEglFailure(const Api& api, const char* stage, std::string& error,
                    EGLint* observed = nullptr, EglLifecycleStatus* status = nullptr) {
    EglLifecycleStatus failure;
    EglLifecycleFailure(api, stage, true, &failure);
    if (observed) *observed = failure.error;
    if (status) *status = failure;
    error = failure.text();
    return false;
}

// 运行期 context lost 无法靠重建 surface 恢复游戏对象。把该事实交回现有关闭路径，
// 不允许下一次恢复创建一个空 context 冒充原 context。初始化失败不使用此入口。
template<class Api, class Window>
bool GlesEglRuntimeFailure(const Api& api, Window& win, const char* stage, std::string& error, EglLifecycleStatus* status = nullptr) {
    EGLint value = EGL_SUCCESS;
    GlesEglFailure(api, stage, error, &value, status);
    if (value == EGL_CONTEXT_LOST) {
        win.contextLostFatal = true;
        win.shouldClose = 1;
    }
    return false;
}

// 初次交付前证明 window 与 parking 可以共用同一个 config/context。要求组合 config；
// 若驱动不提供，明确拒绝初始化，不能悄悄退回会在 surface 丢失时解除 current 的路径。
// 部分分配的句柄立即记录在 win，失败后由 BackendSession 调用 DestroyGlesEgl 逐项清理。
template<class Api, class Window>
bool CreateGlesEgl(const Api& api, Window& win, int requestedMajor, int tid, std::string& error, bool auxiliary = false, EglLifecycleStatus* status = nullptr) {
    error.clear();
    if (status) *status = {};
    if ((!auxiliary && !win.nativeWindow) || requestedMajor < 1 || win.display != EGL_NO_DISPLAY ||
        win.context != EGL_NO_CONTEXT || win.surface != EGL_NO_SURFACE ||
        win.parkingSurface != EGL_NO_SURFACE) {
        error = "invalid GLES initialization state";
        return false;
    }
    win.display = api.eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (win.display == EGL_NO_DISPLAY || !api.eglInitialize(win.display, nullptr, nullptr))
        return GlesEglFailure(api, "display-initialize", error, nullptr, status);
    if (!api.eglBindAPI(EGL_OPENGL_ES_API)) return GlesEglFailure(api, "bind-gles", error, nullptr, status);
    const EGLint attributes[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8, EGL_NONE
    };
    EGLint count = 0, surfaceTypes = 0, renderableTypes = 0;
    if (!api.eglChooseConfig(win.display, attributes, &win.config, 1, &count) || count != 1)
        return GlesEglFailure(api, "window-and-pbuffer-config", error, nullptr, status);
    if (!api.eglGetConfigAttrib(win.display, win.config, EGL_SURFACE_TYPE, &surfaceTypes) ||
        !api.eglGetConfigAttrib(win.display, win.config, EGL_RENDERABLE_TYPE, &renderableTypes))
        return GlesEglFailure(api, "config-capabilities", error, nullptr, status);
    if ((surfaceTypes & (EGL_WINDOW_BIT | EGL_PBUFFER_BIT)) != (EGL_WINDOW_BIT | EGL_PBUFFER_BIT) ||
        (renderableTypes & EGL_OPENGL_ES3_BIT) == 0) {
        error = "selected config cannot provide the required GLES window and parking surface";
        return false;
    }
    const EGLint auxiliarySize[] = {EGL_WIDTH, win.width, EGL_HEIGHT, win.height, EGL_NONE};
    win.surface = auxiliary ? api.eglCreatePbufferSurface(win.display, win.config, auxiliarySize) :
        api.eglCreateWindowSurface(win.display, win.config, reinterpret_cast<EGLNativeWindowType>(win.nativeWindow), nullptr);
    if (win.surface == EGL_NO_SURFACE) return GlesEglFailure(api, "window-surface", error, nullptr, status);
    const EGLint parkingSize[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    win.parkingSurface = api.eglCreatePbufferSurface(win.display, win.config, parkingSize);
    if (win.parkingSurface == EGL_NO_SURFACE) return GlesEglFailure(api, "parking-surface", error, nullptr, status);
    EGLint parkingWidth = 0, parkingHeight = 0;
    if (!api.eglQuerySurface(win.display, win.parkingSurface, EGL_WIDTH, &parkingWidth) ||
        !api.eglQuerySurface(win.display, win.parkingSurface, EGL_HEIGHT, &parkingHeight))
        return GlesEglFailure(api, "parking-size-query", error, nullptr, status);
    if (parkingWidth != 1 || parkingHeight != 1) {
        error = "parking surface size differs from its 1x1 request";
        return false;
    }

    // 保留原 GLES 版本重试策略：先试请求（最高 ES3），瞬态失败重试一次，再试 ES3，
    // 最后仅在该固定 config 明确包含 ES2 位时尝试 ES2。任何重试都不更换 config。
    int effectiveMajor = requestedMajor > 3 ? 3 : requestedMajor;
    auto createContext = [&](int major) {
        const EGLint contextAttributes[] = {EGL_CONTEXT_CLIENT_VERSION, major, EGL_NONE};
        win.context = api.eglCreateContext(win.display, win.config, win.shareContext, contextAttributes);
        if (win.context != EGL_NO_CONTEXT) effectiveMajor = major;
        return win.context != EGL_NO_CONTEXT;
    };
    if (!createContext(effectiveMajor) && !createContext(effectiveMajor) &&
        !(effectiveMajor != 3 && createContext(3)) &&
        !((renderableTypes & EGL_OPENGL_ES2_BIT) != 0 && createContext(2)))
        return GlesEglFailure(api, "create-gles-context", error, nullptr, status);

    // 第一次 current 必须是实际窗口，否则 EGL 会把初始 viewport/scissor 设为 1x1。
    // 随后验证 parking 绑定，再回窗口；EGL 规范保证同一 context 后续绑定不重置它们。
    if (!api.eglMakeCurrent(win.display, win.surface, win.surface, win.context))
        return GlesEglFailure(api, "initial-window-bind", error, nullptr, status);
    win.contextOwnerTid = tid;
    if (!api.eglMakeCurrent(win.display, win.parkingSurface, win.parkingSurface, win.context))
        return GlesEglFailure(api, "initial-parking-bind", error, nullptr, status);
    if (!api.eglMakeCurrent(win.display, win.surface, win.surface, win.context))
        return GlesEglFailure(api, "initial-window-restore", error, nullptr, status);
    EGLint width = 0, height = 0;
    if (!api.eglQuerySurface(win.display, win.surface, EGL_WIDTH, &width) ||
        !api.eglQuerySurface(win.display, win.surface, EGL_HEIGHT, &height))
        return GlesEglFailure(api, "window-size-query", error, nullptr, status);
    if (width <= 0 || height <= 0) { error = "window-size-invalid"; return false; }
    if (win.swapIntervalSet && !api.eglSwapInterval(win.display, win.swapInterval))
        return GlesEglFailure(api, "initial-swap-interval", error, nullptr, status);
    win.width = width;
    win.height = height;
    win.actualContextMajor = effectiveMajor;
    win.actualContextMinor = 0;
    win.eglSurfaceDetachPending = false;
    win.eglTeardownPending = false;
    return true;
}

// 只退休呈现 surface，保留对象域与线程归属。显式释放后的 context 不会被该操作重新
// current；其他线程拥有的 context 一律拒绝。停车/销毁失败保留精确句柄供 owner 重试。
template<class Api, class Window>
bool SuspendGlesEglSurface(const Api& api, Window& win, int tid, std::string& error, EglLifecycleStatus* status = nullptr) {
    error.clear();
    if (status) *status = {};
    if (win.contextOwnerTid && win.contextOwnerTid != tid) {
        error = "GLES suspension attempted outside the context owner thread";
        return false;
    }
    if (win.surface == EGL_NO_SURFACE) return true;
    if (!api.eglBindAPI(EGL_OPENGL_ES_API)) return GlesEglRuntimeFailure(api, win, "suspend-bind-gles", error, status);
    const bool currentHere = win.context != EGL_NO_CONTEXT &&
        api.eglGetCurrentDisplay() == win.display && api.eglGetCurrentContext() == win.context;
    if (currentHere) {
        if (win.parkingSurface == EGL_NO_SURFACE) {
            error = "GLES suspension has no validated parking surface";
            return false;
        }
        if (!api.eglMakeCurrent(win.display, win.parkingSurface, win.parkingSurface, win.context))
            return GlesEglRuntimeFailure(api, win, "suspend-parking-bind", error, status);
    }
    if (!api.eglDestroySurface(win.display, win.surface))
        return GlesEglRuntimeFailure(api, win, "suspend-window-destroy", error, status);
    win.surface = EGL_NO_SURFACE;
    return true;
}

// BackendSession 已持有新窗口 lease/token 时才调用。新 surface 在进入驱动前后的句柄
// 都保存在 win；绑定失败不会丢弃可能仍存活的 surface，session 会通过 suspend 清理。
// 停车 context 继续 current，直到新 surface、尺寸及 interval 均成功，期间不新建 context。
template<class Api, class Window>
bool AttachGlesEglSurface(const Api& api, Window& win, void* nativeWindow,
                          int width, int height, int tid, std::string& error, EglLifecycleStatus* status = nullptr) {
    error.clear();
    if (status) *status = {};
    if (!nativeWindow || width <= 0 || height <= 0 || win.display == EGL_NO_DISPLAY ||
        win.context == EGL_NO_CONTEXT || !win.config || win.parkingSurface == EGL_NO_SURFACE ||
        win.surface != EGL_NO_SURFACE || (win.contextOwnerTid && win.contextOwnerTid != tid)) {
        error = "invalid GLES replacement state or context owner";
        return false;
    }
    if (!api.eglBindAPI(EGL_OPENGL_ES_API)) return GlesEglRuntimeFailure(api, win, "attach-bind-gles", error, status);
    win.surface = api.eglCreateWindowSurface(win.display, win.config,
        reinterpret_cast<EGLNativeWindowType>(nativeWindow), nullptr);
    if (win.surface == EGL_NO_SURFACE) return GlesEglRuntimeFailure(api, win, "replacement-surface", error, status);
    if (!api.eglMakeCurrent(win.display, win.surface, win.surface, win.context))
        return GlesEglRuntimeFailure(api, win, "replacement-bind", error, status);
    win.contextOwnerTid = tid;
    EGLint surfaceWidth = 0, surfaceHeight = 0;
    if (!api.eglQuerySurface(win.display, win.surface, EGL_WIDTH, &surfaceWidth) ||
        !api.eglQuerySurface(win.display, win.surface, EGL_HEIGHT, &surfaceHeight))
        return GlesEglRuntimeFailure(api, win, "replacement-size-query", error, status);
    if (surfaceWidth <= 0 || surfaceHeight <= 0) { error = "replacement-size-invalid"; return false; }
    if (win.swapIntervalSet && !api.eglSwapInterval(win.display, win.swapInterval))
        return GlesEglRuntimeFailure(api, win, "replacement-swap-interval", error, status);
    win.nativeWindow = nativeWindow;
    win.width = surfaceWidth;
    win.height = surfaceHeight;
    win.eglSurfaceDetachPending = false;
    return true;
}

// 逆序退休本窗口持有的资源；每次驱动成功才清句柄，所以失败可重试且 lease 不会早放。
// EGLDisplay 是进程共享对象，eglInitialize 不是引用计数；这里不能 eglTerminate，
// 否则会撤销同 display 的其他上下文。与系统 OpenGL 路线一样，将 display 留给进程寿命。
template<class Api, class Window>
bool DestroyGlesEgl(const Api& api, Window& win, int tid, std::string& error, EglLifecycleStatus* status = nullptr) {
    error.clear();
    if (status) *status = {};
    win.eglTeardownPending = true;
    if (win.contextOwnerTid && win.contextOwnerTid != tid) {
        error = "GLES destruction attempted outside the context owner thread";
        return false;
    }
    if (win.display == EGL_NO_DISPLAY) {
        if (win.surface != EGL_NO_SURFACE || win.parkingSurface != EGL_NO_SURFACE || win.context != EGL_NO_CONTEXT) {
            error = "GLES resources exist without their display";
            return false;
        }
    } else {
        if (!api.eglBindAPI(EGL_OPENGL_ES_API)) return GlesEglFailure(api, "destroy-bind-gles", error, nullptr, status);
        if (win.context != EGL_NO_CONTEXT && api.eglGetCurrentDisplay() == win.display &&
            api.eglGetCurrentContext() == win.context &&
            !api.eglMakeCurrent(win.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT))
            return GlesEglFailure(api, "destroy-unbind", error, nullptr, status);
        if (win.surface != EGL_NO_SURFACE) {
            if (!api.eglDestroySurface(win.display, win.surface)) return GlesEglFailure(api, "destroy-window", error, nullptr, status);
            win.surface = EGL_NO_SURFACE;
        }
        if (win.parkingSurface != EGL_NO_SURFACE) {
            if (!api.eglDestroySurface(win.display, win.parkingSurface)) return GlesEglFailure(api, "destroy-parking", error, nullptr, status);
            win.parkingSurface = EGL_NO_SURFACE;
        }
        if (win.context != EGL_NO_CONTEXT) {
            if (!api.eglDestroyContext(win.display, win.context)) return GlesEglFailure(api, "destroy-context", error, nullptr, status);
            win.context = EGL_NO_CONTEXT;
        }
    }
    win.display = EGL_NO_DISPLAY;
    win.config = nullptr;
    win.contextOwnerTid = 0;
    win.eglSurfaceDetachPending = false;
    win.eglTeardownPending = false;
    return true;
}
} // namespace amcl::graphics
