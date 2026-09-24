// 执行生产 GLES 生命周期核心，而不是复制一份修复逻辑。假驱动模拟 current、句柄、
// 对象域、首次 viewport 与销毁约束，验证停车期间资源更新和失败事务；不替代真机 EGL。
#define EGL_NO_PLATFORM_SPECIFIC_TYPES
#include "../../platform/gles_egl_core.h"
#include <cstdint>
#include <iostream>
#include <map>
#include <stdexcept>
#include <vector>

#define CHECK(value) do { if (!(value)) throw std::runtime_error(#value); } while (false)

struct Window {
    void* nativeWindow = reinterpret_cast<void*>(10);
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface surface = EGL_NO_SURFACE, parkingSurface = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT, shareContext = EGL_NO_CONTEXT;
    EGLConfig config = nullptr;
    int contextOwnerTid = 0, width = 0, height = 0, actualContextMajor = 0, actualContextMinor = 0;
    bool eglTeardownPending = false, eglSurfaceDetachPending = false, contextLostFatal = false;
    bool swapIntervalSet = true;
    int swapInterval = 0, shouldClose = 0;
};

// 故障点只拒绝本次操作，拒绝时不偷偷改变 current。生产代码必须在明确成功后才提交
// 句柄/线程状态；每个资源都有独立身份，重复删除与删除仍 current 的 surface 会失败。
struct Driver {
    struct Surface { bool parking; int width; int height; };
    mutable std::map<EGLSurface, Surface> surfaces;
    mutable EGLContext current = EGL_NO_CONTEXT, allocated = EGL_NO_CONTEXT;
    mutable EGLSurface draw = EGL_NO_SURFACE;
    mutable int owner = 0, thread = 7, nextSurface = 100, creates = 0, destroys = 0;
    mutable int binds = 0, windowBinds = 0, intervals = 0, viewportWidth = 0, resourceValue = 0;
    mutable std::vector<int> requestedVersions;
    int geometryWidth = 1280, geometryHeight = 720;
    int surfaceMask = EGL_WINDOW_BIT | EGL_PBUFFER_BIT;
    int renderableMask = EGL_OPENGL_ES3_BIT | EGL_OPENGL_ES2_BIT;
    int onlyVersion = 0;
    EGLint failureCode = EGL_BAD_ACCESS;
    std::string fail;
    EGLDisplay eglGetDisplay(EGLNativeDisplayType) const {
        return fail == "display" ? EGL_NO_DISPLAY : reinterpret_cast<EGLDisplay>(1);
    }
    EGLBoolean eglInitialize(EGLDisplay, EGLint*, EGLint*) const { return fail != "initialize"; }
    EGLBoolean eglBindAPI(EGLenum api) const { CHECK(api == EGL_OPENGL_ES_API); return fail != "api"; }
    EGLBoolean eglChooseConfig(EGLDisplay, const EGLint* attrs, EGLConfig* config, EGLint capacity, EGLint* count) const {
        CHECK(capacity == 1 && attrs[0] == EGL_SURFACE_TYPE);
        CHECK(attrs[1] == (EGL_WINDOW_BIT | EGL_PBUFFER_BIT));
        CHECK(attrs[2] == EGL_RENDERABLE_TYPE && attrs[3] == EGL_OPENGL_ES3_BIT);
        *config = reinterpret_cast<EGLConfig>(2); *count = fail == "no-config" ? 0 : 1;
        return fail != "choose";
    }
    EGLBoolean eglGetConfigAttrib(EGLDisplay, EGLConfig config, EGLint attribute, EGLint* result) const {
        CHECK(config == reinterpret_cast<EGLConfig>(2));
        *result = attribute == EGL_SURFACE_TYPE ? surfaceMask : renderableMask;
        return fail != "config-query";
    }
    EGLSurface eglCreateWindowSurface(EGLDisplay, EGLConfig config, EGLNativeWindowType, const EGLint*) const {
        CHECK(config == reinterpret_cast<EGLConfig>(2));
        if (fail == "window-create") return EGL_NO_SURFACE;
        const auto result = reinterpret_cast<EGLSurface>(static_cast<intptr_t>(++nextSurface));
        surfaces.emplace(result, Surface{false, geometryWidth, geometryHeight});
        return result;
    }
    EGLSurface eglCreatePbufferSurface(EGLDisplay, EGLConfig config, const EGLint* attrs) const {
        CHECK(config == reinterpret_cast<EGLConfig>(2));
        CHECK(attrs[0] == EGL_WIDTH && attrs[1] == 1 && attrs[2] == EGL_HEIGHT && attrs[3] == 1);
        if (fail == "parking-create") return EGL_NO_SURFACE;
        const auto result = reinterpret_cast<EGLSurface>(static_cast<intptr_t>(++nextSurface));
        surfaces.emplace(result, Surface{true, fail == "parking-size" ? 2 : 1, 1});
        return result;
    }
    EGLContext eglCreateContext(EGLDisplay, EGLConfig config, EGLContext share, const EGLint* attrs) const {
        CHECK(config == reinterpret_cast<EGLConfig>(2) && share == EGL_NO_CONTEXT);
        CHECK(attrs[0] == EGL_CONTEXT_CLIENT_VERSION);
        requestedVersions.push_back(attrs[1]);
        if (fail == "context-create" || (onlyVersion && attrs[1] != onlyVersion)) return EGL_NO_CONTEXT;
        CHECK(allocated == EGL_NO_CONTEXT);
        ++creates; allocated = reinterpret_cast<EGLContext>(3);
        return allocated;
    }
    EGLBoolean eglMakeCurrent(EGLDisplay, EGLSurface target, EGLSurface read, EGLContext context) const {
        CHECK(target == read);
        ++binds;
        if (owner && owner != thread) return EGL_FALSE;
        if (context == EGL_NO_CONTEXT) {
            if (fail == "unbind") return EGL_FALSE;
            current = EGL_NO_CONTEXT; draw = EGL_NO_SURFACE; owner = 0;
            return EGL_TRUE;
        }
        CHECK(context == allocated && surfaces.count(target));
        const bool parking = surfaces.at(target).parking;
        if (!parking) ++windowBinds;
        if ((parking && fail == "parking-bind") || (!parking && fail == "window-bind") ||
            (!parking && fail == "window-restore" && windowBinds == 2)) return EGL_FALSE;
        if (!viewportWidth) viewportWidth = surfaces.at(target).width;
        current = context; draw = target; owner = thread;
        return EGL_TRUE;
    }
    EGLDisplay eglGetCurrentDisplay() const { return eglGetCurrentContext() ? reinterpret_cast<EGLDisplay>(1) : EGL_NO_DISPLAY; }
    EGLContext eglGetCurrentContext() const { return owner == thread ? current : EGL_NO_CONTEXT; }
    EGLBoolean eglQuerySurface(EGLDisplay, EGLSurface surface, EGLint attribute, EGLint* value) const {
        CHECK(surfaces.count(surface));
        const auto& selected = surfaces.at(surface);
        if (fail == (selected.parking ? "parking-query" : "window-query")) return EGL_FALSE;
        *value = attribute == EGL_WIDTH ? selected.width : selected.height;
        return EGL_TRUE;
    }
    EGLBoolean eglSwapInterval(EGLDisplay, EGLint interval) const {
        CHECK(current != EGL_NO_CONTEXT && surfaces.count(draw) && !surfaces.at(draw).parking);
        CHECK(interval == 0); ++intervals;
        return fail != "interval";
    }
    EGLBoolean eglDestroySurface(EGLDisplay, EGLSurface surface) const {
        CHECK(surfaces.count(surface) && surface != draw);
        const bool parking = surfaces.at(surface).parking;
        if (fail == (parking ? "parking-destroy" : "window-destroy")) return EGL_FALSE;
        surfaces.erase(surface); ++destroys;
        return EGL_TRUE;
    }
    EGLBoolean eglDestroyContext(EGLDisplay, EGLContext context) const {
        CHECK(context == allocated && context != current);
        if (fail == "context-destroy") return EGL_FALSE;
        allocated = EGL_NO_CONTEXT; ++destroys;
        return EGL_TRUE;
    }
    EGLint eglGetError() const { return failureCode; }
    // 故意不实现 eglTerminate：如果生产核心误终止共享 display，测试会编译失败。
    void updateResource(int value) const {
        CHECK(eglGetCurrentContext() == allocated && allocated != EGL_NO_CONTEXT);
        resourceValue = value;
    }
};

// 初次选择、pbuffer 能力、真实绑定、尺寸和 interval 中任一步失败，都只能清理自己的
// 已记录资源。验证不到组合能力时没有 window-only 降级，避免假装具有恢复保证。
void initializationFailures() {
    for (const char* fault : {"display", "initialize", "api", "choose", "no-config", "config-query",
        "window-create", "parking-create", "parking-size", "parking-query", "context-create",
        "window-bind", "parking-bind", "window-restore", "window-query", "interval"}) {
        Driver api; Window win; std::string error; api.fail = fault;
        CHECK(!amcl::graphics::CreateGlesEgl(api, win, 3, 7, error) && !error.empty());
        api.fail.clear();
        CHECK(amcl::graphics::DestroyGlesEgl(api, win, 7, error));
        CHECK(api.surfaces.empty() && api.allocated == EGL_NO_CONTEXT && api.current == EGL_NO_CONTEXT);
    }
    Driver api; Window win; std::string error;
    api.surfaceMask = EGL_WINDOW_BIT;
    CHECK(!amcl::graphics::CreateGlesEgl(api, win, 3, 7, error));
    CHECK(api.surfaces.empty() && api.requestedVersions.empty());
    CHECK(amcl::graphics::DestroyGlesEgl(api, win, 7, error));
    api.surfaceMask |= EGL_PBUFFER_BIT; api.onlyVersion = 2;
    CHECK(amcl::graphics::CreateGlesEgl(api, win, 3, 7, error));
    CHECK(win.actualContextMajor == 2 && api.requestedVersions == std::vector<int>({3, 3, 2}));
    CHECK(amcl::graphics::DestroyGlesEgl(api, win, 7, error));
}

// 最重要的行为测试：窗口丢失期间继续更新同一对象域，然后恢复到新窗口。context
// 创建次数始终为一、viewport 维持首次窗口尺寸、失败后精确 surface 仍受 session 管理。
void parkingAndRecovery() {
    Driver api; Window win; std::string error;
    CHECK(amcl::graphics::CreateGlesEgl(api, win, 3, 7, error));
    const auto context = win.context;
    CHECK(api.draw == win.surface && api.viewportWidth == 1280 && api.intervals == 1);
    api.updateResource(41);
    api.thread = 8;
    CHECK(!amcl::graphics::SuspendGlesEglSurface(api, win, 8, error));
    CHECK(!amcl::graphics::DestroyGlesEgl(api, win, 8, error));
    api.thread = 7; win.eglTeardownPending = false;
    const auto original = win.surface;
    api.fail = "parking-bind";
    CHECK(!amcl::graphics::SuspendGlesEglSurface(api, win, 7, error));
    CHECK(win.surface == original && api.draw == original && api.current == context);
    api.fail = "window-destroy";
    CHECK(!amcl::graphics::SuspendGlesEglSurface(api, win, 7, error));
    CHECK(win.surface == original && api.draw == win.parkingSurface && api.current == context);
    api.updateResource(42);
    api.fail.clear();
    CHECK(amcl::graphics::SuspendGlesEglSurface(api, win, 7, error));
    CHECK(win.surface == EGL_NO_SURFACE && win.contextOwnerTid == 7 && api.current == context);
    api.updateResource(43);
    CHECK(!amcl::graphics::AttachGlesEglSurface(api, win, reinterpret_cast<void*>(20), 1920, 1080, 8, error));
    for (const char* fault : {"window-create", "window-bind", "window-query", "interval"}) {
        api.fail = fault;
        CHECK(!amcl::graphics::AttachGlesEglSurface(api, win, reinterpret_cast<void*>(20), 1920, 1080, 7, error));
        const auto candidate = win.surface;
        api.fail.clear();
        if (candidate != EGL_NO_SURFACE) {
            api.fail = "window-destroy";
            CHECK(!amcl::graphics::SuspendGlesEglSurface(api, win, 7, error));
            CHECK(win.surface == candidate && api.surfaces.count(candidate));
            api.fail.clear();
        }
        CHECK(amcl::graphics::SuspendGlesEglSurface(api, win, 7, error));
        CHECK(api.current == context && api.draw == win.parkingSurface);
        api.updateResource(44);
    }
    api.geometryWidth = 1920; api.geometryHeight = 1080;
    CHECK(amcl::graphics::AttachGlesEglSurface(api, win, reinterpret_cast<void*>(20), 1920, 1080, 7, error));
    CHECK(api.creates == 1 && api.resourceValue == 44 && api.current == context && api.draw == win.surface);
    CHECK(win.width == 1920 && win.height == 1080 && api.viewportWidth == 1280);
    CHECK(amcl::graphics::DestroyGlesEgl(api, win, 7, error));
    CHECK(api.surfaces.empty() && api.current == EGL_NO_CONTEXT);
}

// 显式 release 不被 suspend 撤销，之后允许新线程显式接管原 context。销毁每一步的
// 故障必须留下剩余句柄并保持可重试；真实 context lost 则明确要求退出，不再假恢复。
void releaseTeardownAndContextLoss() {
    for (const char* fault : {"unbind", "window-destroy", "parking-destroy", "context-destroy"}) {
        Driver api; Window win; std::string error;
        CHECK(amcl::graphics::CreateGlesEgl(api, win, 3, 7, error));
        api.fail = fault;
        CHECK(!amcl::graphics::DestroyGlesEgl(api, win, 7, error) && win.eglTeardownPending);
        CHECK(win.context != EGL_NO_CONTEXT);
        api.fail.clear();
        CHECK(amcl::graphics::DestroyGlesEgl(api, win, 7, error));
        CHECK(api.surfaces.empty() && api.allocated == EGL_NO_CONTEXT);
        const int destroyed = api.destroys;
        CHECK(amcl::graphics::DestroyGlesEgl(api, win, 7, error) && api.destroys == destroyed);
    }
    Driver api; Window win; std::string error;
    CHECK(amcl::graphics::CreateGlesEgl(api, win, 3, 7, error));
    CHECK(api.eglMakeCurrent(win.display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT));
    win.contextOwnerTid = 0;
    const int binds = api.binds;
    CHECK(amcl::graphics::SuspendGlesEglSurface(api, win, 7, error));
    CHECK(api.current == EGL_NO_CONTEXT && api.binds == binds && win.contextOwnerTid == 0);
    api.thread = 8;
    CHECK(amcl::graphics::AttachGlesEglSurface(api, win, reinterpret_cast<void*>(20), 1920, 1080, 8, error));
    CHECK(win.contextOwnerTid == 8 && api.owner == 8 && api.creates == 1);
    api.fail = "parking-bind"; api.failureCode = EGL_CONTEXT_LOST;
    CHECK(!amcl::graphics::SuspendGlesEglSurface(api, win, 8, error));
    CHECK(win.contextLostFatal && win.shouldClose == 1);
    api.fail.clear();
    CHECK(amcl::graphics::DestroyGlesEgl(api, win, 8, error));
}

int main() try {
    initializationFailures();
    parkingAndRecovery();
    releaseTeardownAndContextLoss();
    std::cout << "GLES production lifecycle: initialization/failure retention/parked object continuity/thread transfer PASS\n";
} catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
}
