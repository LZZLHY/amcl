// 原样包含生产绑定实现；只替换系统链接器与 PID，测试不复制 provider 决策算法。
#define EGL_NO_PLATFORM_SPECIFIC_TYPES
#if defined(_MSC_VER)
#define __attribute__(x)
#endif
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>
// 先载入宿主 CRT，再给生产 POSIX PID 调用指定独立符号，避免覆盖 Windows 的 getpid ABI。
#define getpid amclBindingTestPid
#include "../../platform/graphics_runtime_binding.cpp"
#include "../../platform/graphics_egl_context.cpp"
#include "../../platform/graphics_features.cpp"

namespace {
int currentPid = 71;
std::atomic<int> opens{0};
std::string missing;
bool foreignGl = false;
bool nativeSystemLibrary = false;
std::string missingDriver;
unsigned nativeWrapperLookups = 0;
bool reenter = false, reentryRejected = false;
void implementation() {}
void nativeWrapper() {}
void foreignImplementation() {}
int initialize(AmclGlHostInitReportV1* value) {
    if (reenter) {
        std::string reason;
        reentryRejected = !amcl::graphics::FreezeGraphicsRuntime("mobileglues", "OPENGL", reason)
            && reason == "graphics_binding_reentrant_initialization";
    }
    value->state = 2; return 1;
}
const char* sourceIdentity() { return "test-source-identity"; }
void* resolve(const char* name) {
    if (missing == name || missingDriver == name) return nullptr;
    return foreignGl && std::strcmp(name, "glGetString") == 0 ?
        reinterpret_cast<void*>(&foreignImplementation) : reinterpret_cast<void*>(&implementation);
}
// EGL函数具有函数指针返回类型；测试同样遵守真实声明，不依赖void*返回类型转换碰巧兼容。
__eglMustCastToProperFunctionPointerType eglResolve(const char* name) {
    return reinterpret_cast<__eglMustCastToProperFunctionPointerType>(resolve(name));
}
void check(bool passed, const char* message) { if (!passed) throw std::runtime_error(message); }
void reset() {
    delete amcl::graphics::active.exchange(nullptr);
    // 用例之间模拟新进程；实际产品不提供复位失败初始化的入口。
    amcl::graphics::initialization().attempted = false;
    amcl::graphics::initialization().failure.clear();
    currentPid = 71; opens = 0; missing.clear(); foreignGl = false;
    nativeSystemLibrary = false; missingDriver.clear(); nativeWrapperLookups = 0;
    reenter = reentryRejected = false;
}
void environment(const char* name, const char* value) {
#if defined(_WIN32)
    _putenv_s(name, value);
#else
    setenv(name, value, 1);
#endif
}
}
int getpid() { return currentPid; }
void* dlopen(const char* name, int) {
    ++opens;if(std::strcmp(name,"libGLv4.so")==0)nativeSystemLibrary=true;
    return reinterpret_cast<void*>(0x1000);
}
void* dlsym(void*, const char* name) {
    if (missing == name) return nullptr;
    if (std::strcmp(name,"eglGetProcAddress")==0) return reinterpret_cast<void*>(&eglResolve);
    // libGLv4公开的是线程包装层而非EGL创建context所属驱动；它没有GLX平台入口。
    if (nativeSystemLibrary && std::strncmp(name,"gl",2)==0) {
        ++nativeWrapperLookups;
        if (std::strncmp(name,"glX",3)==0)return nullptr;
        return reinterpret_cast<void*>(&nativeWrapper);
    }
    if (std::strcmp(name, "amclGlHostInitializeV1") == 0) return reinterpret_cast<void*>(&initialize);
    if (std::strcmp(name, "amclGlHostSourceIdentityV1") == 0) return reinterpret_cast<void*>(&sourceIdentity);
    if (std::strcmp(name, "glXGetProcAddress") == 0 ||
        std::strcmp(name, "amclGlHostGetProcAddressV1") == 0 || std::strcmp(name, "amclGlHostGetEglProcAddressV1") == 0)
        return reinterpret_cast<void*>(&resolve);
    return resolve(name);
}
int dladdr(const void* address, Dl_info* value) {
    if (!address) return 0;
    value->dli_fname = "/app/libglfw.so";
    value->dli_fbase = address == reinterpret_cast<void*>(&foreignImplementation) ?
        reinterpret_cast<void*>(0x2000) : reinterpret_cast<void*>(0x1000);
    return 1;
}

int main() try {
    using namespace amcl::graphics;
    std::string error;
    reset(); environment("NEED_OPENGL", "0");
    check(!FreezeGraphicsRuntime("nativegl", "OPENGL", error) && opens == 0,
        "missing system bootstrap reached native GL provider");
    environment("NEED_OPENGL", "1");
    for (const char* profile : {"mobilegl", "mobileglues", "gl4es", "nativegl"}) {
        reset();
        environment("NEED_OPENGL", "1");
        check(FreezeGraphicsRuntime(profile, "OPENGL", error), "provider binding failed");
        const auto* runtime = BoundGraphicsRuntime();
        check(runtime && runtime->egl.ready && runtime->is(profile), "wrong bound table");
        if (runtime->is("nativegl")) {
            check(runtime->glProc("glGetString")==reinterpret_cast<void*>(&implementation),
                "native GL resolved wrapper instead of EGL provider");
            check(runtime->providerProc("glGetString")==reinterpret_cast<void*>(&implementation),
                "native GL provider API bypassed EGL resolver");
            missingDriver="glUnsupportedFeature";
            check(!runtime->glProc(missingDriver.c_str()), "missing driver entry fell back to wrapper");
            check(nativeWrapperLookups==0, "native GL queried wrapper/GLX library symbols");
            missingDriver.clear();
        }
        const auto before = runtime->glProc("glGetError");
        environment("AMCL_GRAPHICS_PROFILE", "minecraft-vulkan");
        environment("AMCL_GRAPHICS_API", "VULKAN");
        check(RequireGraphicsRuntime() == runtime && runtime->glProc("glGetError") == before,
            "environment changed active provider");
        check(!FreezeGraphicsRuntime("minecraft-vulkan", "VULKAN", error), "provider change accepted");
        const int openCount = opens;
        currentPid = 72;
        check(!BoundGraphicsRuntime() && !runtime->glProc("glGetError") && !runtime->eglProc("eglGetDisplay"),
            "inherited provider remained usable");
        check(!FreezeGraphicsRuntime(profile, "OPENGL", error) && opens == openCount, "fork opened another provider");
    }
    reset();missing="eglGetProcAddress";
    check(!FreezeGraphicsRuntime("nativegl","OPENGL",error) && !BoundGraphicsRuntime(),
        "native GL without system resolver published a wrapper binding");
    reset();
    check(FreezeGraphicsRuntime("minecraft-vulkan", "VULKAN", error), "Vulkan identity failed");
    check(opens == 0 && !BoundGraphicsRuntime()->egl.ready && !amclGraphicsGlProcV1("glGetString"),
        "native Vulkan entered an OpenGL provider");
    for (const char* entry : {"eglMakeCurrent", "eglCreatePbufferSurface", "glGetString", "mobileglGetPresentedSequenceV1"}) {
        reset(); missing = entry;
        check(!FreezeGraphicsRuntime("mobilegl", "OPENGL", error) && !BoundGraphicsRuntime(),
            "missing entry published partial binding");
        const int before = opens;
        missing.clear();
        check(!FreezeGraphicsRuntime("mobileglues", "OPENGL", error) && opens == before,
            "failed initialization allowed another provider side effect");
    }
    reset(); foreignGl = true;
    check(!FreezeGraphicsRuntime("mobilegl", "OPENGL", error), "foreign GL image accepted");
    reset();
    check(!FreezeGraphicsRuntime("mobilegl", "VULKAN", error) && opens == 0, "API mismatch loaded library");
    std::atomic<int> successes{0}; std::vector<std::thread> workers;
    for (int i = 0; i < 16; ++i) workers.emplace_back([&] {
        std::string reason;
        if (FreezeGraphicsRuntime("mobilegl", "OPENGL", reason)) ++successes;
    });
    for (auto& worker : workers) worker.join();
    check(successes == 16 && BoundGraphicsRuntime()->is("mobilegl"), "concurrent binding diverged");
    check(opens == 1, "same provider initialized more than once");
    // 异provider竞争必须在dlopen前决出初始化owner，输家不能先污染系统EGL再被CAS拒绝。
    reset(); successes = 0; workers.clear(); std::atomic<bool> start{false};
    for (const char* profile : {"mobilegl", "mobileglues"}) workers.emplace_back([&, profile] {
        while (!start.load()) std::this_thread::yield();
        std::string reason; if (FreezeGraphicsRuntime(profile, "OPENGL", reason)) ++successes;
    });
    start = true; for (auto& worker : workers) worker.join();
    check(successes == 1 && opens == 1, "losing provider entered initialization");
    reset(); reenter = true;
    check(FreezeGraphicsRuntime("mobileglues", "OPENGL", error) && reentryRejected && opens == 1,
        "provider callback reentry deadlocked or initialized another provider");
    char detail[4] = {};
    check(!amclGraphicsBindRuntimeV1("invalid", "OPENGL", detail, sizeof(detail)) && detail[3] == '\0',
        "bounded C ABI error failed");
    reset();
    std::cout << "Frozen runtime provider: environment/fork/image/missing-entry/concurrency isolation PASS\n";
    return 0;
} catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
