// 使用真实功能探针的驱动边界桩，并执行生产冻结操作表/资源账本；窗口生命周期算法不复制。
#define main GraphicsProbeFixtureMain
#include "graphics_features_test.cpp"
#undef main
#include "../../platform/graphics_egl_context.cpp"

namespace resources {
std::map<uintptr_t, std::array<int, 2>> surfaces;
uintptr_t nextSurface = 100;
int terminates = 0;
EGLDisplay display(EGLNativeDisplayType) { return reinterpret_cast<EGLDisplay>(1); }
EGLBoolean initialize(EGLDisplay, EGLint*, EGLint*) { return EGL_TRUE; }
EGLBoolean bindApi(EGLenum) { return EGL_TRUE; }
EGLBoolean choose(EGLDisplay, const EGLint*, EGLConfig* out, EGLint, EGLint* count) { *out = reinterpret_cast<EGLConfig>(1); *count = 1; return EGL_TRUE; }
EGLBoolean config(EGLDisplay, EGLConfig, EGLint key, EGLint* out) {
    *out = key == EGL_SURFACE_TYPE ? EGL_WINDOW_BIT | EGL_PBUFFER_BIT : EGL_OPENGL_ES3_BIT | EGL_OPENGL_ES2_BIT | EGL_OPENGL_BIT; return EGL_TRUE;
}
EGLSurface createSurface(const EGLint* attributes) {
    int width = 1, height = 1;
    if (attributes) for (int i = 0; attributes[i] != EGL_NONE; i += 2) {
        if (attributes[i] == EGL_WIDTH) width = attributes[i + 1];
        if (attributes[i] == EGL_HEIGHT) height = attributes[i + 1];
    }
    const auto id = ++nextSurface; surfaces[id] = {width, height}; return reinterpret_cast<EGLSurface>(id);
}
EGLSurface pbuffer(EGLDisplay, EGLConfig, const EGLint* attributes) { return createSurface(attributes); }
EGLSurface window(EGLDisplay, EGLConfig, EGLNativeWindowType, const EGLint* attributes) { return createSurface(attributes); }
EGLBoolean query(EGLDisplay, EGLSurface surface, EGLint key, EGLint* value) {
    const auto found = surfaces.find(reinterpret_cast<uintptr_t>(surface)); if (found == surfaces.end()) return EGL_FALSE;
    *value = found->second[key == EGL_WIDTH ? 0 : 1]; return EGL_TRUE;
}
EGLBoolean destroySurface(EGLDisplay, EGLSurface surface) { return surfaces.erase(reinterpret_cast<uintptr_t>(surface)) ? EGL_TRUE : EGL_FALSE; }
EGLBoolean terminate(EGLDisplay) { ++terminates; return fixture::fault == "terminate-failed" ? EGL_FALSE : EGL_TRUE; }
EGLBoolean interval(EGLDisplay, EGLint) { return EGL_TRUE; }
}
extern "C" void* amclGraphicsGlProcV1(const char* name) { return fixture::resolve(name); }
int main() {
    using namespace amcl::graphics;
    for (const bool presentedFirst : {false, true}) {
        fixture::fault.clear(); fixture::contexts.clear(); fixture::current = 0; fixture::next = 1;
        resources::surfaces.clear(); resources::terminates = 0;
        GraphicsRuntimeBinding r; r.features = std::make_unique<GraphicsFeatureState>(); auto& features = *r.features;
        r.profile = FindGraphicsProfile("mobilegl");
        r.contextOperations = FindEglContextOperations(r.profile->id); fixture::activeRuntime = &r;
        // “功能是否真的支持”由独立生产探针反例覆盖，此处只让已验证能力进入真实共享生命周期。
        features.probed = true; features.auxiliary = features.contextIsolation = features.independentObjects = features.sharedObjects = FeatureEvidence::Verified;
        auto& api = r.egl; api.ready = true; api.eglGetDisplay = resources::display; api.eglInitialize = resources::initialize;
        api.eglBindAPI = resources::bindApi; api.eglChooseConfig = resources::choose; api.eglGetConfigAttrib = resources::config;
        api.eglCreateContext = fixture::createContext; api.eglCreatePbufferSurface = resources::pbuffer; api.eglCreateWindowSurface = resources::window;
        api.eglMakeCurrent = fixture::makeCurrent; api.eglGetCurrentContext = fixture::getContext; api.eglGetCurrentDisplay = fixture::getDisplay;
        api.eglGetCurrentSurface = fixture::getSurface; api.eglQuerySurface = resources::query; api.eglGetError = fixture::eglError;
        api.eglDestroySurface = resources::destroySurface; api.eglDestroyContext = fixture::destroyContext;
        api.eglTerminate = resources::terminate; api.eglSwapInterval = resources::interval;
        EglContextState a, b; a.auxiliary = !presentedFirst; b.auxiliary = presentedFirst;
        a.width = b.width = 640; a.height = b.height = 480;
        a.nativeWindow = a.auxiliary ? nullptr : reinterpret_cast<void*>(9);
        b.nativeWindow = b.auxiliary ? nullptr : reinterpret_cast<void*>(9);
        std::string error; amcl::desktop::ContextRequest request{3, 3, 0x00032001, true};
        CHECK(r.contextOperations->create(r, a, request, 7, error));
        fixture::bind(0x8892, 77); unsigned value = 123; fixture::data(0x8892, sizeof(value), &value, 0x88e4);
        b.shareContext = a.context;
        CHECK(r.contextOperations->create(r, b, request, 7, error));
        CHECK(a.context != b.context && a.shareGroup != 0 && a.shareGroup == b.shareGroup && features.contexts.size() == 2);
        CHECK(fixture::isBuffer(77));
        CHECK(!r.contextOperations->destroy(r, a, 8, error) && features.contexts.size() == 2);
        fixture::fault = "destroy-failed";
        CHECK(!r.contextOperations->destroy(r, a, 7, error) && a.context != EGL_NO_CONTEXT && features.contexts.size() == 2);
        fixture::fault.clear(); CHECK(r.contextOperations->destroy(r, a, 7, error));
        CHECK(resources::terminates == 0 && features.contexts.size() == 1 && fixture::isBuffer(77));
        fixture::fault = "terminate-failed";
        CHECK(!r.contextOperations->destroy(r, b, 7, error));
        CHECK(features.contexts.size() == 1 && b.display != EGL_NO_DISPLAY && b.eglTeardownPending);
        fixture::fault.clear(); CHECK(r.contextOperations->destroy(r, b, 7, error));
        CHECK(features.contexts.empty() && fixture::contexts.empty() && resources::surfaces.empty() && resources::terminates == 2);
    }
    CHECK(!FindEglContextOperations("unknown"));
    std::cout << "Graphics context resources PASS: real operation tables, hidden/presented ordering, shared-object lifetime, owner refusal, destroy/terminate failure retention\n";
}
