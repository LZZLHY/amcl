#pragma once
#include <EGL/egl.h>
#include <dlfcn.h>

namespace amcl::desktop {
// 系统探针通过显式libEGL句柄访问系统实现；活动会话则使用冻结运行时的函数表。
// 不通过全局egl符号的加载顺序推断provider，避免翻译器和系统驱动互相插入。
#define AMCL_SYSTEM_EGL_FUNCTIONS(X) \
    X(eglGetDisplay) X(eglInitialize) X(eglBindAPI) X(eglQueryAPI) \
    X(eglChooseConfig) X(eglGetConfigAttrib) X(eglCreateContext) \
    X(eglCreateWindowSurface) X(eglCreatePbufferSurface) X(eglDestroySurface) \
    X(eglDestroyContext) X(eglMakeCurrent) X(eglGetCurrentContext) \
    X(eglGetCurrentDisplay) X(eglGetCurrentSurface) X(eglSwapBuffers) \
    X(eglSwapInterval) X(eglQuerySurface) X(eglQueryString) X(eglGetError) \
    X(eglGetProcAddress) X(eglTerminate)
struct SystemEglApi {
#define AMCL_EGL_MEMBER(name) decltype(&::name) name = nullptr;
    AMCL_SYSTEM_EGL_FUNCTIONS(AMCL_EGL_MEMBER)
#undef AMCL_EGL_MEMBER
    bool ready = false;
};
inline const SystemEglApi& SystemEgl() {
    static const SystemEglApi api = [] {
        SystemEglApi result;
        void* library = dlopen("libEGL.so", RTLD_NOW | RTLD_LOCAL);
        if (!library) return result;
        result.ready = true;
#define AMCL_EGL_LOAD(name) result.name = reinterpret_cast<decltype(result.name)>(dlsym(library, #name)); result.ready = result.ready && result.name;
        AMCL_SYSTEM_EGL_FUNCTIONS(AMCL_EGL_LOAD)
#undef AMCL_EGL_LOAD
        // Keep the provider pinned for the lifetime of its contexts.
        return result;
    }();
    return api;
}
#undef AMCL_SYSTEM_EGL_FUNCTIONS
}
