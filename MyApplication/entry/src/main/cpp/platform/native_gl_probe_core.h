#pragma once
#include "native_gl.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <cmath>

namespace amcl::desktop {
/** 私有探针资源从分配起即登记到进程持有的记录。清理失败不丢句柄，不跨线程重试；
 * 外层将进程隔离直到退出。display仅为关联身份，不归探针所有，不能eglTerminate。
 */
struct NativeGlProbeResources {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLenum previousApi = EGL_OPENGL_ES_API;
    bool ownsCurrent = false;
    bool restoreApi = false;
    bool live() const { return context != EGL_NO_CONTEXT || surface != EGL_NO_SURFACE || ownsCurrent || restoreApi; }
};

/** 在调用线程执行实际4.2 context与像素读回；入口能力由外层查询，驱动函数表必须冻结。
 * 系统边界可由宿主测试替换，但资源登记、错误采集和退休顺序使用此生产正文。
 * 已有current时拒绝，不夺走调用者context；绑定OpenGL后再检查该API的current，
 * 防止线程此前绑定GLES时看不到另一个API仍持有的context。
 */
template<class Api, class Resolve, class Diagnostics>
void ProbeNativeGlContext(const Api& api, NativeGlProbeResources& resources,
                          Resolve resolve, Diagnostics diagnostics, bool detailed, NativeGlCapability& result) {
    if (resources.live()) {
        result.stage = "probe-resources-retained"; result.cleanupComplete = false; result.restartRequired = true;
        return;
    }
    bool failed = false;
    const auto failure = [&](const char* stage, int error, const char* domain) {
        if (!failed) { result.stage = stage; result.error = error; result.errorDomain = domain; failed = true; }
    };
    const auto eglFailure = [&](const char* stage) { failure(stage, api.eglGetError(), "EGL"); };
    try {
        do {
            if (api.eglGetCurrentContext() != EGL_NO_CONTEXT) { failure("worker-context", 0, "state"); break; }
            resources.previousApi = api.eglQueryAPI();
            resources.restoreApi = true;
            resources.display = api.eglGetDisplay(EGL_DEFAULT_DISPLAY);
            if (resources.display == EGL_NO_DISPLAY) { eglFailure("get-display"); break; }
            if (!api.eglInitialize(resources.display, nullptr, nullptr)) { eglFailure("initialize"); break; }
            if (!api.eglBindAPI(EGL_OPENGL_API)) { eglFailure("bind-opengl"); break; }
            if (api.eglGetCurrentContext() != EGL_NO_CONTEXT) { failure("worker-opengl-context", 0, "state"); break; }
            EGLConfig config{}; EGLint count = 0;
            const EGLint attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE,
                EGL_OPENGL_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
            if (!api.eglChooseConfig(resources.display, attributes, &config, 1, &count)) { eglFailure("config"); break; }
            if (count != 1) { failure("config-count", 0, "state"); break; }
            const EGLint size[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
            resources.surface = api.eglCreatePbufferSurface(resources.display, config, size);
            if (resources.surface == EGL_NO_SURFACE) { eglFailure("surface"); break; }
            // API22+系统OpenGL文档的4.2 core，不把缺少4.6作为设备失败。
            const EGLint contextAttributes[] = {EGL_CONTEXT_MAJOR_VERSION, 4, EGL_CONTEXT_MINOR_VERSION, 2,
                EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
            resources.context = api.eglCreateContext(resources.display, config, EGL_NO_CONTEXT, contextAttributes);
            result.contextCreated = resources.context != EGL_NO_CONTEXT;
            if (!result.contextCreated) { eglFailure("context-4.2-core"); break; }
            if (!api.eglMakeCurrent(resources.display, resources.surface, resources.surface, resources.context)) {
                eglFailure("make-current"); break;
            }
            resources.ownsCurrent = true;
            using GetString = const unsigned char* (*)(unsigned);
            using GetError = unsigned (*)();
            using ClearColor = void (*)(float,float,float,float);
            using Clear = void (*)(unsigned);
            using Read = void (*)(int,int,int,int,unsigned,unsigned,void*);
            const auto getString = reinterpret_cast<GetString>(resolve("glGetString"));
            const auto getError = reinterpret_cast<GetError>(resolve("glGetError"));
            const auto clearColor = reinterpret_cast<ClearColor>(resolve("glClearColor"));
            const auto clear = reinterpret_cast<Clear>(resolve("glClear"));
            const auto read = reinterpret_cast<Read>(resolve("glReadPixels"));
            if (!getString || !getError || !clearColor || !clear || !read) { failure("symbols", 0, "entrypoint"); break; }
            const auto version = getString(0x1f02), vendor = getString(0x1f00), renderer = getString(0x1f01);
            if (version) result.version = reinterpret_cast<const char*>(version);
            if (vendor) result.vendor = reinterpret_cast<const char*>(vendor);
            if (renderer) result.renderer = reinterpret_cast<const char*>(renderer);
            const auto versionError = getError();
            if (versionError || result.version.empty()) { failure("gl-version", static_cast<int>(versionError), "GL"); break; }
            unsigned char pixel[4]{};
            clearColor(0.25f, 0.5f, 0.75f, 1.0f); clear(0x4000);
            read(0, 0, 1, 1, 0x1908, 0x1401, pixel);
            const auto pixelError = getError();
            result.pixelVerified = pixelError == 0 && std::abs(int(pixel[0])-64) <= 2 &&
                std::abs(int(pixel[1])-128) <= 2 && std::abs(int(pixel[2])-191) <= 2;
            if (!result.pixelVerified) { failure("pixel-readback", static_cast<int>(pixelError), "GL"); break; }
            if (detailed) result.renderDiagnostics = diagnostics();
        } while (false);
    } catch (...) {
        // 即使诊断构造/边界调用抛出异常，已登记的资源仍进入同一退休流程。
        failure("probe-exception", 0, "exception");
    }

    const auto cleanupFailure = [&](const char* stage, int error) {
        if (result.cleanupComplete) { result.cleanupStage = stage; result.cleanupError = error; }
        result.cleanupComplete = false; result.restartRequired = true;
        failure(stage, error, "EGL");
    };
    bool canRetire = true;
    try {
        if (resources.ownsCurrent) {
            if (api.eglMakeCurrent(resources.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) resources.ownsCurrent = false;
            else { cleanupFailure("cleanup-unbind", api.eglGetError()); canRetire = false; }
        }
        if (canRetire && resources.context != EGL_NO_CONTEXT) {
            if (api.eglDestroyContext(resources.display, resources.context)) resources.context = EGL_NO_CONTEXT;
            else { cleanupFailure("cleanup-context", api.eglGetError()); canRetire = false; }
        }
        if (canRetire && resources.surface != EGL_NO_SURFACE) {
            if (api.eglDestroySurface(resources.display, resources.surface)) resources.surface = EGL_NO_SURFACE;
            else { cleanupFailure("cleanup-surface", api.eglGetError()); canRetire = false; }
        }
        // 解绑失败时仍持有自己的current，不能切API隐藏这个事实。已解绑但对象退休失败
        // 则仍可恢复调用线程的API；原始清理错误先采集，后续恢复不能覆盖它。
        if (!resources.ownsCurrent && resources.restoreApi) {
            if (api.eglBindAPI(resources.previousApi)) resources.restoreApi = false;
            else cleanupFailure("cleanup-api", api.eglGetError());
        }
    } catch (...) { cleanupFailure("cleanup-exception", 0); }
    result.ready = !failed && result.pixelVerified && result.cleanupComplete;
    if (result.cleanupComplete) resources.display = EGL_NO_DISPLAY;
    if (result.ready) { result.stage = "ready"; result.error = 0; result.errorDomain.clear(); }
}
}
