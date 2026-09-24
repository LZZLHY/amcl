#pragma once

#include "../platform/gl_host.h"
#include "../platform/system_egl.h"
#include "../platform/native_gl.h"
#include "../platform/egl_provider_dispatch.h"
#include "../platform/graphics_runtime_binding.h"
#include <cstdlib>
#include <utility>

namespace amcl::desktop {
/** MobileGL 向游戏提供桌面 OpenGL，内部 Vulkan 并不改变 EGL 的 client API。 */
inline bool UsesDesktopOpenGlContext() {
    const auto* runtime = amcl::graphics::RequireGraphicsRuntime();
    return runtime && runtime->desktopGl();
}
/** 名称判断只读冻结后的身份，不重新消费环境；用于生命周期适配器的确切实现分支。 */
inline bool RuntimeProfileIs(const char* id) {
    const auto* runtime = amcl::graphics::RequireGraphicsRuntime();
    return runtime && runtime->is(id);
}
// 生命周期事务一次取得同一 provider 的函数表，保证 GLES parking 也经过 MG wrapper。
// 计划已经在启动边界锁存；函数表只用于当前事务，不跨进程缓存或降级到其他 provider。
inline SystemEglApi LifecycleEglApi() {
    const auto* runtime = amcl::graphics::RequireGraphicsRuntime();
    return runtime ? runtime->egl : SystemEglApi{};
}

template<typename Function, typename... Args>
auto DispatchEgl(const char* name, Function SystemEglApi::*member, Args... args)
    -> decltype(std::declval<Function>()(args...)) {
    (void)name;
    const auto* runtime = amcl::graphics::RequireGraphicsRuntime();
    const Function function = runtime ? runtime->egl.*member : nullptr;
    return function ? function(args...) : decltype(function(args...)){};
}
}
#define AMCL_DISPATCH_EGL(name, ...) ::amcl::desktop::DispatchEgl(#name, &::amcl::desktop::SystemEglApi::name, __VA_ARGS__)
#define eglGetDisplay(...) AMCL_DISPATCH_EGL(eglGetDisplay, __VA_ARGS__)
#define eglInitialize(...) AMCL_DISPATCH_EGL(eglInitialize, __VA_ARGS__)
#define eglBindAPI(...) AMCL_DISPATCH_EGL(eglBindAPI, __VA_ARGS__)
#define eglChooseConfig(...) AMCL_DISPATCH_EGL(eglChooseConfig, __VA_ARGS__)
#define eglGetConfigAttrib(...) AMCL_DISPATCH_EGL(eglGetConfigAttrib, __VA_ARGS__)
#define eglCreateContext(...) AMCL_DISPATCH_EGL(eglCreateContext, __VA_ARGS__)
#define eglCreateWindowSurface(...) AMCL_DISPATCH_EGL(eglCreateWindowSurface, __VA_ARGS__)
#define eglCreatePbufferSurface(...) AMCL_DISPATCH_EGL(eglCreatePbufferSurface, __VA_ARGS__)
#define eglDestroySurface(...) AMCL_DISPATCH_EGL(eglDestroySurface, __VA_ARGS__)
#define eglDestroyContext(...) AMCL_DISPATCH_EGL(eglDestroyContext, __VA_ARGS__)
#define eglMakeCurrent(...) AMCL_DISPATCH_EGL(eglMakeCurrent, __VA_ARGS__)
#define eglGetCurrentContext() ::amcl::desktop::DispatchEgl("eglGetCurrentContext", &::amcl::desktop::SystemEglApi::eglGetCurrentContext)
#define eglGetCurrentDisplay() ::amcl::desktop::DispatchEgl("eglGetCurrentDisplay", &::amcl::desktop::SystemEglApi::eglGetCurrentDisplay)
#define eglGetCurrentSurface(...) AMCL_DISPATCH_EGL(eglGetCurrentSurface, __VA_ARGS__)
#define eglSwapBuffers(...) AMCL_DISPATCH_EGL(eglSwapBuffers, __VA_ARGS__)
#define eglSwapInterval(...) AMCL_DISPATCH_EGL(eglSwapInterval, __VA_ARGS__)
#define eglQuerySurface(...) AMCL_DISPATCH_EGL(eglQuerySurface, __VA_ARGS__)
#define eglQueryString(...) AMCL_DISPATCH_EGL(eglQueryString, __VA_ARGS__)
#define eglGetError() ::amcl::desktop::DispatchEgl("eglGetError", &::amcl::desktop::SystemEglApi::eglGetError)
#define eglTerminate(...) AMCL_DISPATCH_EGL(eglTerminate, __VA_ARGS__)
