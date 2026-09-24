#pragma once
#include <cstdint>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include "egl_lifecycle_status.h"

namespace amcl::desktop {
struct ContextRequest {
    int major = 3, minor = 0, profile = 0;
    bool forward = false;
};

// 系统 OpenGL 的窗口大小由 EGL 查询提供。独立 provider 可以注入自己的窗口几何
// 协议，但不得改动 context 身份、版本、停车资源或失败时保留句柄的公共生命周期。
struct EglSurfaceGeometry {
    static constexpr bool RequiresNativeWindow = true;
    template<class Api>
    EGLSurface Create(const Api& api, EGLDisplay display, EGLConfig config, void* nativeWindow) const {
        return api.eglCreateWindowSurface(display, config,
            reinterpret_cast<EGLNativeWindowType>(nativeWindow), nullptr);
    }
    template<class Api>
    bool Measure(const Api& api, EGLDisplay display, EGLSurface surface, EGLint& width, EGLint& height,
                 amcl::graphics::EglLifecycleStatus* status = nullptr) const {
        if (!api.eglQuerySurface(display, surface, EGL_WIDTH, &width) ||
            !api.eglQuerySurface(display, surface, EGL_HEIGHT, &height))
            return amcl::graphics::EglLifecycleFailure(api, "window-size-query", true, status);
        return (width > 0 && height > 0) ||
            amcl::graphics::EglLifecycleFailure(api, "window-size-invalid", false, status);
    }
};

/** 隐藏窗口的实际离屏surface。与presented共用可停车config，但绝不借NativeWindow。 */
struct EglPbufferGeometry {
    static constexpr bool RequiresNativeWindow = false;
    int width, height;
    template<class Api> EGLSurface Create(const Api& api, EGLDisplay display, EGLConfig config, void*) const {
        const EGLint attributes[] = {EGL_WIDTH, width, EGL_HEIGHT, height, EGL_NONE};
        return api.eglCreatePbufferSurface(display, config, attributes);
    }
    template<class Api> bool Measure(const Api& api, EGLDisplay display, EGLSurface surface, EGLint& x, EGLint& y,
                                     amcl::graphics::EglLifecycleStatus* status = nullptr) const {
        if (!api.eglQuerySurface(display, surface, EGL_WIDTH, &x) || !api.eglQuerySurface(display, surface, EGL_HEIGHT, &y))
            return amcl::graphics::EglLifecycleFailure(api, "pbuffer-size-query", true, status);
        return (x == width && y == height) || amcl::graphics::EglLifecycleFailure(api, "pbuffer-size-mismatch", false, status);
    }
};

// 窗口只退休自己的surface/context，display留给进程owner。每步成功才清句柄；
// 失败留下精确资源和操作状态，调用方不能提前释放NativeWindow租约。
template<class Api, class Window>
bool DestroyDesktopEgl(const Api& api, Window& win, int tid, amcl::graphics::EglLifecycleStatus* status = nullptr) {
    if (status) *status = {};
    const auto fail = [&](const char* stage, bool driver = false) {
        return amcl::graphics::EglLifecycleFailure(api, stage, driver, status);
    };
    win.eglTeardownPending = true;
    if (win.contextOwnerTid != 0 && win.contextOwnerTid != tid) return fail("destroy-context-owner");
    if (win.display == EGL_NO_DISPLAY) {
        if (win.context != EGL_NO_CONTEXT || win.surface != EGL_NO_SURFACE ||
            win.parkingSurface != EGL_NO_SURFACE) return fail("destroy-display-missing");
    } else {
        if (!api.eglBindAPI(EGL_OPENGL_API)) return fail("destroy-bind-api", true);
        if (win.context != EGL_NO_CONTEXT && api.eglGetCurrentContext() == win.context &&
            !api.eglMakeCurrent(win.display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT)) return fail("destroy-unbind", true);
        if (win.surface != EGL_NO_SURFACE) {
            if (!api.eglDestroySurface(win.display,win.surface)) return fail("destroy-window", true);
            win.surface = EGL_NO_SURFACE;
        }
        if (win.parkingSurface != EGL_NO_SURFACE) {
            if (!api.eglDestroySurface(win.display,win.parkingSurface)) return fail("destroy-parking", true);
            win.parkingSurface = EGL_NO_SURFACE;
        }
        if (win.context != EGL_NO_CONTEXT) {
            if (!api.eglDestroyContext(win.display,win.context)) return fail("destroy-context", true);
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

template<class Api, class Window, class Resolver, class Geometry = EglSurfaceGeometry>
bool CreateDesktopEgl(const Api& api, Window& win, const ContextRequest& request,
                      Resolver resolve, int tid, std::string& error, const Geometry& geometry = {},
                      amcl::graphics::EglLifecycleStatus* status = nullptr) {
    amcl::graphics::EglLifecycleStatus failure;
    if (status) *status = {};
    auto fail = [&](const char* stage, bool driver = false) {
        amcl::graphics::EglLifecycleFailure(api, stage, driver, &failure);
        if (status) *status = failure;
        error = failure.text(); return false;
    };
    if (win.display != EGL_NO_DISPLAY || win.context != EGL_NO_CONTEXT || win.surface != EGL_NO_SURFACE ||
        win.parkingSurface != EGL_NO_SURFACE) return fail("context-resources-already-live");
    if (geometry.RequiresNativeWindow && !win.nativeWindow) return fail("native-window-missing");
    if (request.major < 1 || request.minor < 0 ||
        (request.profile != 0 && request.profile != 0x00032001 && request.profile != 0x00032002))
        return fail("invalid-context-request");
    win.display = api.eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (win.display == EGL_NO_DISPLAY || !api.eglInitialize(win.display,nullptr,nullptr)) return fail("display-initialize", true);
    if (!api.eglBindAPI(EGL_OPENGL_API)) return fail("bind-opengl", true);
    const EGLint config[] = {EGL_SURFACE_TYPE,EGL_WINDOW_BIT|EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_BIT,
        EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,
        EGL_DEPTH_SIZE,24,EGL_STENCIL_SIZE,8,EGL_NONE};
    EGLint count = 0;
    if (!api.eglChooseConfig(win.display,config,&win.config,1,&count)) return fail("window-config", true);
    if (count != 1) return fail("window-config-count");
    win.surface = geometry.Create(api, win.display, win.config, win.nativeWindow);
    if (win.surface == EGL_NO_SURFACE) return fail("window-surface", true);
    // 在交付游戏前分配并验证停车面。仅创建句柄不能证明第一次后台切换能够安全停车。
    const EGLint parkingSize[] = {EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE};
    win.parkingSurface = api.eglCreatePbufferSurface(win.display,win.config,parkingSize);
    if (win.parkingSurface == EGL_NO_SURFACE) return fail("parking-surface", true);
    EGLint parkingWidth = 0, parkingHeight = 0;
    if (!api.eglQuerySurface(win.display, win.parkingSurface, EGL_WIDTH, &parkingWidth) ||
        !api.eglQuerySurface(win.display, win.parkingSurface, EGL_HEIGHT, &parkingHeight)) return fail("parking-size-query", true);
    if (parkingWidth != 1 || parkingHeight != 1) return fail("parking-size");
    std::vector<EGLint> attrs = {EGL_CONTEXT_MAJOR_VERSION,request.major,EGL_CONTEXT_MINOR_VERSION,request.minor};
    if (request.profile) {
        attrs.push_back(EGL_CONTEXT_OPENGL_PROFILE_MASK);
        attrs.push_back(request.profile == 0x00032001 ? EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT : EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT);
    }
    attrs.push_back(EGL_CONTEXT_OPENGL_FORWARD_COMPATIBLE);
    attrs.push_back(request.forward ? EGL_TRUE : EGL_FALSE);
    attrs.push_back(EGL_NONE);
    win.context = api.eglCreateContext(win.display,win.config,win.shareContext,attrs.data());
    if (win.context == EGL_NO_CONTEXT) return fail("create-opengl-context", true);
    if (!api.eglMakeCurrent(win.display,win.surface,win.surface,win.context)) return fail("make-current", true);
    win.contextOwnerTid = tid;
    // 第一次current仍为真实窗口以初始化viewport；随后用同一context验证停车再恢复。
    if (!api.eglMakeCurrent(win.display,win.parkingSurface,win.parkingSurface,win.context)) return fail("parking-bind", true);
    if (!api.eglMakeCurrent(win.display,win.surface,win.surface,win.context)) return fail("parking-restore", true);
    using GetString = const unsigned char* (*)(unsigned);
    using GetInt = void (*)(unsigned,int*);
    auto getString = reinterpret_cast<GetString>(resolve("glGetString"));
    auto getInt = reinterpret_cast<GetInt>(resolve("glGetIntegerv"));
    if (!getString || !getInt) return fail("context-query-symbols");
    const char* version = reinterpret_cast<const char*>(getString(0x1f02));
    if (!version || std::strncmp(version,"OpenGL ES",9) == 0 ||
        std::sscanf(version,"%d.%d",&win.actualContextMajor,&win.actualContextMinor) != 2)
        return fail("desktop-gl-identity");
    if (win.actualContextMajor < request.major ||
        (win.actualContextMajor == request.major && win.actualContextMinor < request.minor))
        return fail("requested-version-unavailable");
    win.actualContextProfile = 0;
    win.actualContextFlags = 0;
    if (win.actualContextMajor >= 3) getInt(0x821e /* GL_CONTEXT_FLAGS */,&win.actualContextFlags);
    if (win.actualContextMajor > 3 || (win.actualContextMajor == 3 && win.actualContextMinor >= 2)) {
        int profile = 0;
        getInt(0x9126 /* GL_CONTEXT_PROFILE_MASK */,&profile);
        if (profile & 1) win.actualContextProfile = 0x00032001;
        else if (profile & 2) win.actualContextProfile = 0x00032002;
    }
    if (request.profile && request.profile != win.actualContextProfile) return fail("requested-profile-unavailable");
    EGLint width = 0, height = 0;
    if (!geometry.Measure(api, win.display, win.surface, width, height, &failure)) {
        if (status) *status = failure;
        error = failure.text(); return false;
    }
    win.width = width; win.height = height;
    if (win.swapIntervalSet && !api.eglSwapInterval(win.display,win.swapInterval)) return fail("swap-interval", true);
    win.eglSurfaceDetachPending = false; win.eglTeardownPending = false;
    return true;
}

template<class Api, class Window>
bool SuspendDesktopEglSurface(const Api& api, Window& win, int tid, amcl::graphics::EglLifecycleStatus* status = nullptr) {
    if (status) *status = {};
    const auto fail = [&](const char* stage, bool driver = false) {
        return amcl::graphics::EglLifecycleFailure(api, stage, driver, status);
    };
    if (win.surface == EGL_NO_SURFACE) return true;
    if (win.contextOwnerTid && win.contextOwnerTid != tid) return fail("suspend-context-owner");
    if (!api.eglBindAPI(EGL_OPENGL_API)) return fail("suspend-bind-api", true);
    // 当前线程已拥有的context停到pbuffer；显式释放的context保持释放，不抢其他线程状态。
    if (api.eglGetCurrentContext() == win.context) {
        if (win.parkingSurface == EGL_NO_SURFACE) return fail("suspend-parking-missing");
        if (!api.eglMakeCurrent(win.display,win.parkingSurface,win.parkingSurface,win.context)) return fail("suspend-parking-bind", true);
    }
    if (!api.eglDestroySurface(win.display,win.surface)) return fail("suspend-window-destroy", true);
    win.surface = EGL_NO_SURFACE;
    return true;
}

template<class Api, class Window, class Geometry = EglSurfaceGeometry>
bool AttachDesktopEglSurface(const Api& api, Window& win, void* nativeWindow,
                             int width, int height, int tid, const Geometry& geometry = {},
                             amcl::graphics::EglLifecycleStatus* status = nullptr) {
    if (status) *status = {};
    const auto fail = [&](const char* stage, bool driver = false) {
        return amcl::graphics::EglLifecycleFailure(api, stage, driver, status);
    };
    if (!nativeWindow || width <= 0 || height <= 0 || win.display == EGL_NO_DISPLAY ||
        win.context == EGL_NO_CONTEXT || win.surface != EGL_NO_SURFACE ||
        win.parkingSurface == EGL_NO_SURFACE || (win.contextOwnerTid && win.contextOwnerTid != tid)) return fail("attach-state-or-owner");
    if (!api.eglBindAPI(EGL_OPENGL_API)) return fail("attach-bind-api", true);
    const EGLSurface surface = geometry.Create(api, win.display, win.config, nativeWindow);
    if (surface == EGL_NO_SURFACE) return fail("replacement-surface", true);
    // 绑定失败先捕获原始错误，清理失败仍保留新surface及租约，不以二次错误覆盖根因。
    win.surface = surface;
    if (!api.eglMakeCurrent(win.display,surface,surface,win.context)) {
        fail("replacement-bind", true);
        if (api.eglDestroySurface(win.display,surface)) win.surface = EGL_NO_SURFACE;
        else { win.eglSurfaceDetachPending = true; (void)api.eglGetError(); }
        return false;
    }
    win.contextOwnerTid = tid;
    EGLint actualWidth = 0, actualHeight = 0;
    if (!geometry.Measure(api, win.display, surface, actualWidth, actualHeight, status)) return false;
    if (win.swapIntervalSet && !api.eglSwapInterval(win.display,win.swapInterval)) return fail("replacement-swap-interval", true);
    win.nativeWindow = nativeWindow; win.width = actualWidth; win.height = actualHeight;
    win.eglSurfaceDetachPending = false;
    return true;
}
}
