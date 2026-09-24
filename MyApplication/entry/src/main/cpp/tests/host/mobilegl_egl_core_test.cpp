// 复用已有 EGL 失败驱动桩；所有资源算法来自生产 header，不能在测试中复制生命周期实现。
#define main DesktopCoreFixtureMain
#include "desktop_egl_core_test.cpp"
#undef main
#include "../../platform/mobilegl_egl_core.h"

struct MobileApi : Fake {
    mutable int terminates = 0;
    mutable int createdWidth = 0, createdHeight = 0;
    // 模拟当前 MobileGL：创建时后端收到了尺寸，但 EGLState 的窗口查询仍返回双零。
    // 这样能重现真机发现的初始化失败，避免桩默认返回正尺寸而漏掉 provider 差异。
    EGLSurface eglCreateWindowSurface(EGLDisplay d, EGLConfig c, EGLNativeWindowType n, const EGLint* attrs) const {
        CHECK(attrs && attrs[0] == EGL_WIDTH && attrs[2] == EGL_HEIGHT && attrs[4] == EGL_NONE);
        createdWidth = attrs[1]; createdHeight = attrs[3];
        return Fake::eglCreateWindowSurface(d, c, n, attrs);
    }
    bool eglQuerySurface(EGLDisplay d, EGLSurface s, EGLint field, EGLint* value) const {
        if (s == reinterpret_cast<EGLSurface>(5)) {
            if (fail == "parking-size") return false;
            *value = 1;
            return true;
        }
        *value = fail == "partial-size" && field == EGL_WIDTH ? 1280 : fail == "negative-size" ? -1 : 0;
        return fail != "size";
    }
    bool eglTerminate(EGLDisplay) const {
        ++terminates;
        return fail != "terminate";
    }
};

int main() try {
    using namespace amcl::graphics;
    const amcl::desktop::ContextRequest request{3, 2, 0x00032001, true};
    fakeVersion = "4.3 MobileGL DirectVulkan";
    for (const char* fault : {"", "size", "partial-size", "negative-size", "parking-size", "park-bind"}) {
        MobileApi api; Window win; std::string error;
        win.width = 1280; win.height = 720;
        api.fail = fault;
        const bool ready = CreateMobileGlEgl(api, win, request, Resolve, 7, error);
        CHECK(ready == api.fail.empty());
        api.fail.clear();
        if (ready) {
            CHECK(win.width == 1280 && win.height == 720 && api.createdWidth == 1280 && api.createdHeight == 720);
            const auto original = win.context;
            CHECK(amcl::desktop::SuspendDesktopEglSurface(api, win, 7));
            CHECK(api.current == original && api.draw == win.parkingSurface);
            CHECK(AttachMobileGlEglSurface(api, win, win.nativeWindow, 1920, 1080, 7));
            CHECK(api.createdWidth == 1920 && api.createdHeight == 1080);
            CHECK(win.context == original && api.creates == 1);
            CHECK(!DestroyMobileGlEgl(api, win, 8));
            CHECK(api.terminates == 0);
            api.fail = "terminate";
            CHECK(!DestroyMobileGlEgl(api, win, 7));
            CHECK(win.display != EGL_NO_DISPLAY && win.eglTeardownPending);
            CHECK(win.context == EGL_NO_CONTEXT && win.surface == EGL_NO_SURFACE);
            api.fail.clear();
        }
        CHECK(DestroyMobileGlEgl(api, win, 7));
        CHECK(win.display == EGL_NO_DISPLAY && !win.eglTeardownPending);
        const int retired = api.terminates;
        CHECK(DestroyMobileGlEgl(api, win, 7)); CHECK(api.terminates == retired);
    }
    for (const char* version : {"4.3 system driver", "4.3 MobileGL DirectGLES"}) {
        fakeVersion = version;
        MobileApi api; Window win; std::string error;
        win.width = 1280; win.height = 720;
        CHECK(!CreateMobileGlEgl(api, win, request, Resolve, 7, error));
        CHECK(error == "mobilegl-direct-vulkan-context-identity");
        CHECK(DestroyMobileGlEgl(api, win, 7));
    }
    fakeVersion = "4.3 MobileGL DirectVulkan";
    MobileApi api; Window win; std::string error;
    CHECK(!CreateMobileGlEgl(api, win, request, Resolve, 7, error)); CHECK(api.creates == 0);
    CHECK(error == "mobilegl-native-window-size");
    win.width = 1280; win.height = 720;
    win.shareContext = reinterpret_cast<EGLContext>(9);
    CHECK(!CreateMobileGlEgl(api, win, request, Resolve, 7, error)); CHECK(api.creates == 0);
    win.shareContext = EGL_NO_CONTEXT;
    CHECK(!CreateMobileGlEgl(api, win, {2, 1, 0, false}, Resolve, 7, error)); CHECK(api.creates == 0);
    std::cout << "MobileGL OpenGL lifecycle: host geometry/provider identity/parking/context continuity/retirement retry PASS\n";
} catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << '\n'; return 1;
}
