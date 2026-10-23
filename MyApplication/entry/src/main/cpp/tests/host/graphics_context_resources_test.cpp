// 使用真实功能探针的驱动边界桩，并执行生产冻结操作表/资源账本；窗口生命周期算法不复制。
#define main GraphicsProbeFixtureMain
#include "graphics_features_test.cpp"
#undef main
#ifndef AMCL_EGL_CONTEXT_TEST_HEADER
#define AMCL_EGL_CONTEXT_TEST_HEADER "../../platform/graphics_egl_context.cpp"
#endif
#include AMCL_EGL_CONTEXT_TEST_HEADER
#include <cstdlib>

// 正式脚本把当前 glfw_egl.cpp::report 逐字抽为头文件，接在真实公共 operation 之后。
// 这里只模拟窗口前端布局和故障总线接收端，不替生产报告器分类 EGL 错误。
#ifdef AMCL_TYPED_REPORT_TEST_HEADER
struct GLFWwindow : amcl::graphics::EglContextState { uint64_t nativeWindowGeneration = 17; };
static int typedFatalReports = 0;
static uint32_t typedFatalError = 0;
template<class... Args> void typedReportLog(Args&&...) {}
#define LOG_TAG "TypedReportTest"
#define AMCL_EXTERNAL_LOG_E(...) typedReportLog(__VA_ARGS__)
extern "C" void amclGraphicsFatalV1(const char*, uint32_t error, uint64_t) {
    ++typedFatalReports; typedFatalError = error;
}
// 生产报告器经 glfw_compat.cpp 的 requestRendererProcessRestart 原位置重启标记槽位（I27-05），
// 不再直接 setenv；桩只计数，下面断言它恰在 context lost 时被请求一次。
static int typedRestartRequests = 0;
void requestRendererProcessRestart(const char*) { ++typedRestartRequests; }
#include AMCL_TYPED_REPORT_TEST_HEADER
#endif

namespace resources {
std::map<uintptr_t, std::array<int, 2>> surfaces;
uintptr_t nextSurface = 100;
int terminates = 0;
bool failNextCurrent = false;
EGLint currentFailure = EGL_SUCCESS;
EGLBoolean makeCurrent(EGLDisplay display, EGLSurface draw, EGLSurface read, EGLContext context) {
    if (failNextCurrent) { failNextCurrent = false; return EGL_FALSE; }
    return fixture::makeCurrent(display, draw, read, context);
}
EGLint error() { const EGLint value = currentFailure; currentFailure = EGL_SUCCESS; return value; }
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
// 供桌面与 GLES 共用同一组平台边界桩，生命周期/账本逻辑仍执行各自真实生产 operation。
void configure(amcl::graphics::GraphicsRuntimeBinding& r) {
    auto& api = r.egl; api.ready = true; api.eglGetDisplay = display; api.eglInitialize = initialize;
    api.eglBindAPI = bindApi; api.eglChooseConfig = choose; api.eglGetConfigAttrib = config;
    api.eglCreateContext = fixture::createContext; api.eglCreatePbufferSurface = pbuffer; api.eglCreateWindowSurface = window;
    api.eglMakeCurrent = makeCurrent; api.eglGetCurrentContext = fixture::getContext; api.eglGetCurrentDisplay = fixture::getDisplay;
    api.eglGetCurrentSurface = fixture::getSurface; api.eglQuerySurface = query; api.eglGetError = error;
    api.eglDestroySurface = destroySurface; api.eglDestroyContext = fixture::destroyContext;
    api.eglTerminate = terminate; api.eglSwapInterval = interval;
}
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
        resources::configure(r);
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
        // 先记录真实 typed context lost，再让退休遇到线程拒绝和驱动销毁失败。
        // 两种次生故障均必须保留原始终局 stage/error，不能把问题改写成普通清理错误。
        const EglLifecycleStatus lost{"original-context-loss", EGL_CONTEXT_LOST, true};
        CHECK(!completeEglOperation(a, false, lost, "injected-loss", error, false));
        CHECK(a.contextLostFatal && a.shouldClose == 1 && a.lastFailure.error == EGL_CONTEXT_LOST);
        CHECK(!r.contextOperations->destroy(r, a, 8, error) && features.contexts.size() == 2);
        CHECK(std::strcmp(a.lastFailure.stage, "original-context-loss") == 0 && a.lastFailure.error == EGL_CONTEXT_LOST);
        fixture::fault = "destroy-failed";
        CHECK(!r.contextOperations->destroy(r, a, 7, error) && a.context != EGL_NO_CONTEXT && features.contexts.size() == 2);
        CHECK(a.contextLostFatal && a.shouldClose == 1 && a.lastFailure.driverFailure == 1);
        CHECK(std::strcmp(a.lastFailure.stage, "original-context-loss") == 0 && a.lastFailure.error == EGL_CONTEXT_LOST);
        fixture::fault.clear(); CHECK(r.contextOperations->destroy(r, a, 7, error));
        CHECK(std::strcmp(a.lastFailure.stage, "original-context-loss") == 0 && a.lastFailure.error == EGL_CONTEXT_LOST);
        CHECK(resources::terminates == 0 && features.contexts.size() == 1 && fixture::isBuffer(77));
        fixture::fault = "terminate-failed";
        CHECK(!r.contextOperations->destroy(r, b, 7, error));
        CHECK(features.contexts.size() == 1 && b.display != EGL_NO_DISPLAY && b.eglTeardownPending);
        fixture::fault.clear(); CHECK(r.contextOperations->destroy(r, b, 7, error));
        CHECK(features.contexts.empty() && fixture::contexts.empty() && resources::surfaces.empty() && resources::terminates == 2);
    }
    // GLES 会在下层先置 contextLostFatal；必须经过真实 operation 才能检出事后判断
    // fatal 导致首因遗漏的回归。两种 GLES profile、停车和恢复均覆盖，普通拒绝作对照。
    for (const char* profile : {"gl4es", "mobileglues"}) for (bool attach : {false, true})
    for (EGLint code : {EGL_BAD_ACCESS, EGL_CONTEXT_LOST}) {
        fixture::fault.clear(); fixture::contexts.clear(); fixture::current = 0; fixture::next = 1;
        resources::surfaces.clear(); resources::failNextCurrent = false; resources::currentFailure = EGL_SUCCESS;
        GraphicsRuntimeBinding r; r.features = std::make_unique<GraphicsFeatureState>();
        r.profile = FindGraphicsProfile(profile); r.contextOperations = FindEglContextOperations(profile);
        fixture::activeRuntime = &r; resources::configure(r);
#ifdef AMCL_TYPED_REPORT_TEST_HEADER
        GLFWwindow s;
#else
        EglContextState s;
#endif
        s.nativeWindow = reinterpret_cast<void*>(9); s.width = 640; s.height = 480;
        std::string error; amcl::desktop::ContextRequest request{3, 0, 0, false};
        CHECK(r.contextOperations->create(r, s, request, 7, error));
        if (attach) CHECK(r.contextOperations->suspend(r, s, 7, error));
        resources::failNextCurrent = true; resources::currentFailure = code;
        const bool ready = attach ? r.contextOperations->attach(r, s, s.nativeWindow, 640, 480, 7, error) :
            r.contextOperations->suspend(r, s, 7, error);
        CHECK(!ready && s.lastFailure.driverFailure == 1 && s.lastFailure.error == code);
        CHECK(std::strcmp(s.lastFailure.stage, attach ? "replacement-bind" : "suspend-parking-bind") == 0);
        CHECK(s.contextLostFatal == (code == EGL_CONTEXT_LOST) && s.shouldClose == (code == EGL_CONTEXT_LOST));
#ifdef AMCL_TYPED_REPORT_TEST_HEADER
        typedFatalReports = 0; typedFatalError = 0; typedRestartRequests = 0;
        CHECK(!report(&s, attach ? "attach" : "suspend", ready, error));
        CHECK(typedFatalReports == (code == EGL_CONTEXT_LOST ? 1 : 0));
        CHECK(typedRestartRequests == (code == EGL_CONTEXT_LOST ? 1 : 0));
        if (code == EGL_CONTEXT_LOST) CHECK(typedFatalError == EGL_CONTEXT_LOST);
#endif
        const char* originalStage = s.lastFailure.stage;
        fixture::fault = "destroy-failed";
        CHECK(!r.contextOperations->destroy(r, s, 7, error));
        if (code == EGL_CONTEXT_LOST) CHECK(s.lastFailure.error == code && s.lastFailure.stage == originalStage);
        fixture::fault.clear(); CHECK(r.contextOperations->destroy(r, s, 7, error));
        CHECK(r.features->contexts.empty() && resources::surfaces.empty() && fixture::contexts.empty());
    }
    // 已经存在非驱动终局时，后续清理即使遇到 lost，也不能改写最初的功能探针失败。
    {
        EglContextState s; s.contextLostFatal = true; s.shouldClose = 1;
        s.lastFailure = {"functional-probe-retirement", EGL_SUCCESS, 0u};
        std::string error; const EglLifecycleStatus cleanup{"later-destroy", EGL_CONTEXT_LOST, true};
        CHECK(!completeEglOperation(s, false, cleanup, "destroy", error, true));
        CHECK(std::strcmp(s.lastFailure.stage, "functional-probe-retirement") == 0 && !s.lastFailure.driverFailure);
    }
    CHECK(!FindEglContextOperations("unknown"));
    std::cout << "Graphics context resources PASS: real operation tables, hidden/presented ordering, shared-object lifetime, owner refusal, destroy/terminate failure retention\n";
}
