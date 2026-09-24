// 冻结 provider 的唯一实现位于中立 libamcl_graphics_runtime。环境仅用于首次输入，之后不参与每帧分派。
#include "graphics_runtime_binding.h"
#include "graphics_bootstrap.h"
#include "system_gl_dispatch.h"
#include "gl_host.h"
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <cstdio>
#include <mutex>
#include <unistd.h>

namespace amcl::graphics {
namespace {
uint64_t presentSequence();
uint64_t reserveContext(void*);
int commitContext(uint64_t, void*);
int retireContext(void*);
int contextOperation(uint32_t, AmclGraphicsContextStateV1*, uint32_t, const AmclGraphicsContextRequestV1*, int32_t, char*, uint32_t);
int auxiliaryVerified(int);
int cleanupSafe();
const char* featuresJson();
void* providerProc(const char*);
std::atomic<GraphicsRuntimeBinding*> active{nullptr};
bool freezeLocal(const char*, const char*, std::string&);
const GraphicsRuntimeBinding* localBound() {
    const auto* value = active.load(std::memory_order_acquire);
    return value && value->processId == static_cast<int>(getpid()) ? value : nullptr;
}
// 同一DSO可能被OHOS的另一个linker namespace再次装入。GPU绑定必须仍归首个服务owner；
// 表仅含C ABI字段，先校验PID/版本/布局再调用，旧进程的表绝不能在fork后复用。
struct RuntimeService {
    uint32_t size, abi, publicApiSize;
    int pid;
    int (*bind)(const char*, const char*, char*, int);
    const AmclGraphicsRuntimeV1* (*bound)();
};
constexpr const char* serviceEnv = "AMCL_GRAPHICS_RUNTIME_SERVICE_V2";
std::atomic<const RuntimeService*> cachedService{nullptr};
int bindLocal(const char* profile, const char* api, char* output, int capacity) {
    std::string error;
    bool ready = false;
    try { ready = freezeLocal(profile, api, error); }
    catch (...) { error = "graphics_binding_exception"; }
    if (output && capacity > 0) {
        std::strncpy(output, error.c_str(), static_cast<std::size_t>(capacity) - 1);
        output[capacity - 1] = '\0';
    }
    return ready ? 1 : 0;
}
const AmclGraphicsRuntimeV1* boundLocal() {
    const auto* value = localBound(); return value ? &value->publicApi : nullptr;
}
const RuntimeService* service(bool create, std::string* error = nullptr) {
    const auto reject = [&](const char* text) -> const RuntimeService* { if (error) *error = text; return nullptr; };
    const int pid = static_cast<int>(getpid());
    if (const auto* cached = cachedService.load(std::memory_order_acquire))
        return cached->pid == pid ? cached : reject("graphics_binding_inherited_requires_restart");
    const char* encoded = std::getenv(serviceEnv);
    RuntimeService* candidate = nullptr;
    if ((!encoded || !*encoded) && create) {
        candidate = new RuntimeService{sizeof(RuntimeService), 2u, sizeof(AmclGraphicsRuntimeV1), pid, bindLocal, boundLocal};
        char text[96]; std::snprintf(text, sizeof(text), "2:%d:%p", pid, static_cast<void*>(candidate));
        int result = 0;
#if defined(_WIN32)
        // Windows只用于系统边界宿主测试；真实OHOS/POSIX用setenv(overwrite=0)原子竞争首次发布。
        static std::mutex publication;
        { std::lock_guard<std::mutex> lock(publication); if (!std::getenv(serviceEnv)) result = _putenv_s(serviceEnv, text); }
#else
        result = setenv(serviceEnv, text, 0);
#endif
        if (result != 0) { delete candidate; return reject("graphics_runtime_service_publish_failed"); }
        encoded = std::getenv(serviceEnv);
    }
    if (!encoded || !*encoded) return nullptr;
    int ownerPid = 0, end = 0; void* address = nullptr;
    if (std::sscanf(encoded, "2:%d:%p%n", &ownerPid, &address, &end) != 2 || encoded[end] || ownerPid != pid || !address) {
        delete candidate; return reject(ownerPid != pid ? "graphics_binding_inherited_requires_restart" : "graphics_runtime_service_invalid");
    }
    const auto* owner = static_cast<const RuntimeService*>(address);
    if (owner->size < sizeof(RuntimeService) || owner->abi != 2 || owner->publicApiSize < sizeof(AmclGraphicsRuntimeV1) ||
        owner->pid != pid || !owner->bind || !owner->bound) {
        if (owner != candidate) delete candidate;
        return reject("graphics_runtime_service_abi_mismatch");
    }
    if (owner != candidate) delete candidate;
    cachedService.store(owner, std::memory_order_release);
    return owner;
}
// 填充同一provider的只读EGL入口；代理仅向owner查询，不自行发现/初始化驱动。
void fillEglTable(GraphicsRuntimeBinding& value) {
#define AMCL_BIND_EGL(name) value.egl.name = reinterpret_cast<decltype(value.egl.name)>(value.eglProc(#name));
        AMCL_BIND_EGL(eglGetDisplay) AMCL_BIND_EGL(eglInitialize) AMCL_BIND_EGL(eglBindAPI)
        AMCL_BIND_EGL(eglQueryAPI) AMCL_BIND_EGL(eglChooseConfig) AMCL_BIND_EGL(eglGetConfigAttrib)
        AMCL_BIND_EGL(eglCreateContext) AMCL_BIND_EGL(eglCreateWindowSurface) AMCL_BIND_EGL(eglCreatePbufferSurface)
        AMCL_BIND_EGL(eglDestroySurface) AMCL_BIND_EGL(eglDestroyContext) AMCL_BIND_EGL(eglMakeCurrent)
        AMCL_BIND_EGL(eglGetCurrentContext) AMCL_BIND_EGL(eglGetCurrentDisplay) AMCL_BIND_EGL(eglGetCurrentSurface)
        AMCL_BIND_EGL(eglSwapBuffers) AMCL_BIND_EGL(eglSwapInterval) AMCL_BIND_EGL(eglQuerySurface)
        AMCL_BIND_EGL(eglQueryString) AMCL_BIND_EGL(eglGetError) AMCL_BIND_EGL(eglGetProcAddress) AMCL_BIND_EGL(eglTerminate)
#undef AMCL_BIND_EGL
        // MG 的共享 display 不由窗口 terminate，QueryAPI 只属于系统探针，均非 MG 必需入口。
        const auto& a = value.egl;
        value.egl.ready = a.eglGetDisplay && a.eglInitialize && a.eglBindAPI && a.eglChooseConfig &&
            a.eglGetConfigAttrib && a.eglCreateContext && a.eglCreateWindowSurface && a.eglCreatePbufferSurface &&
            a.eglDestroySurface && a.eglDestroyContext && a.eglMakeCurrent && a.eglGetCurrentContext &&
            a.eglGetCurrentDisplay && a.eglGetCurrentSurface && a.eglSwapBuffers && a.eglSwapInterval &&
            a.eglQuerySurface && a.eglGetError && (!value.is("mobilegl") || a.eglTerminate);

}

bool owned(void* address, void* image) {
    Dl_info value{};
    return address && image && dladdr(address, &value) && value.dli_fbase == image;
}
// 以当前宿主库位置定位包内依赖，系统驱动使用其约定 SONAME。失败只返回该 provider 错误。
void* openSibling(const char* name) {
    Dl_info host{};
    if (!dladdr(reinterpret_cast<void*>(&FreezeGraphicsRuntime), &host) || !host.dli_fname) return nullptr;
    const std::string path = host.dli_fname;
    const auto separator = path.rfind('/');
    return separator == std::string::npos ? nullptr :
        dlopen((path.substr(0, separator + 1) + name).c_str(), RTLD_NOW | RTLD_LOCAL);
}
bool translatorsOwnSymbols(const GraphicsRuntimeBinding& value) {
    return value.is("mobilegl") || value.is("mobileglues");
}
}

void* GraphicsRuntimeBinding::glProc(const char* name) const {
    if (!name || processId != static_cast<int>(getpid()) || !profile ||
        GraphicsProfileStringEqual(profile->api, "VULKAN")) return nullptr;
    if (delegate) return delegate->glProc(name);
    // NativeGL必须与eglCreateContext/eglMakeCurrent使用同一提供者。libGLv4的
    // dlsym地址是另一层线程包装入口，不能在预检通过后又让SDL/GLFW/LWJGL回到它。
    if (is("nativegl")) return amcl::desktop::ResolveSystemGlProc(egl, name);
    void* result = glResolver ? glResolver(name) : nullptr;
    if (!result && glLibrary) result = dlsym(glLibrary, name);
    // GL4ES可返回其驱动入口；自带完整GL/EGL的两翻译器必须属于选定映像。
    return translatorsOwnSymbols(*this) && !owned(result, providerImage) ? nullptr : result;
}
void* GraphicsRuntimeBinding::eglProc(const char* name) const {
    if (!name || processId != static_cast<int>(getpid())) return nullptr;
    if (delegate) return delegate->eglProc(name);
    void* result = eglResolver ? eglResolver(name) : nullptr;
    if (!result && eglLibrary) result = dlsym(eglLibrary, name);
    return translatorsOwnSymbols(*this) && !owned(result, providerImage) ? nullptr : result;
}

void* GraphicsRuntimeBinding::providerProc(const char* name) const {
    if (!name || processId != static_cast<int>(getpid())) return nullptr;
    if (delegate) return delegate->providerProc ? delegate->providerProc(name) : nullptr;
    // 公共provider查询也遵守原生GL的驱动归属，不能成为绕过glProc的包装层后门。
    if (is("nativegl")) return glProc(name);
    void* address = glLibrary ? dlsym(glLibrary, name) : nullptr;
    return translatorsOwnSymbols(*this) && !owned(address, providerImage) ? nullptr : address;
}

const GraphicsRuntimeBinding* BoundGraphicsRuntime() {
    const auto* owner = service(false);
    const auto* api = owner ? owner->bound() : nullptr;
    if (!api || api->structSize < sizeof(AmclGraphicsRuntimeV1) || api->abiVersion != 1 ||
        api->processId != static_cast<uint64_t>(getpid())) return nullptr;
    if (const auto* local = localBound()) if (&local->publicApi == api) return local;
    // 其他namespace只取得公共C描述符。C++视图由本映像自己分配，不借用owner对象布局。
    static std::atomic<GraphicsRuntimeBinding*> proxy{nullptr};
    if (const auto* value = proxy.load(std::memory_order_acquire))
        return value->processId == static_cast<int>(getpid()) && value->delegate == api ? value : nullptr;
    const auto* metadata = FindGraphicsProfile(api->profile);
    if (!metadata || !GraphicsProfileStringEqual(metadata->api, api->api) ||
        !GraphicsProfileStringEqual(metadata->contextApi, api->contextApi) || !api->glProc || !api->eglProc ||
        !api->contextOperation || !api->auxiliaryVerified || !api->cleanupSafe || !api->featuresJson) return nullptr;
    auto value = std::make_unique<GraphicsRuntimeBinding>();
    value->processId = static_cast<int>(getpid()); value->profile = metadata; value->delegate = api;
    value->publicApi = *api;
    value->implementationIdentity = api->implementationIdentity ? api->implementationIdentity : "";
    if (!GraphicsProfileStringEqual(metadata->api, "VULKAN")) {
        fillEglTable(*value);
        if (!value->egl.ready) return nullptr;
        value->contextOperations = ForwardedEglContextOperations(value->desktopGl());
    }
    GraphicsRuntimeBinding* previous = nullptr;
    if (proxy.compare_exchange_strong(previous, value.get(), std::memory_order_release, std::memory_order_acquire)) return value.release();
    return previous && previous->delegate == api ? previous : nullptr;
}

namespace {
struct BindingInitialization {
    std::mutex mutex;
    bool attempted = false;
    std::string failure;
};
BindingInitialization& initialization() { static auto* value = new BindingInitialization; return *value; }
thread_local bool bindingInProgress = false;
bool freezeLocal(const char* id, const char* api, std::string& error) {
    error.clear();
    // 驱动初始化期间的同线程回调不得再次等待自己的初始化锁；返回明确的未就绪结果，
    // 不发布半张表，也不为了递归查询重新装入provider。其他线程仍等待唯一初始化事务。
    if (bindingInProgress) { error = "graphics_binding_reentrant_initialization"; return false; }
    auto& attempt = initialization();
    std::lock_guard<std::mutex> lock(attempt.mutex);
    auto* previous = active.load(std::memory_order_acquire);
    const auto* metadata = FindGraphicsProfile(id);
    if (!metadata || !GraphicsProfileStringEqual(metadata->api, api)) {
        error = "graphics_binding_profile_api_mismatch"; return false;
    }
    // 本 adapter 的资源连续性依赖停车 context；声明未知/不支持的 OpenGL 路线不能借旧能力进入。
    if (GraphicsProfileStringEqual(metadata->api, "OPENGL") &&
        !GraphicsProfileStringEqual(metadata->parkingContext, "supported")) {
        error = "graphics_binding_parking_unsupported"; return false;
    }
    if (previous) {
        if (previous->processId != static_cast<int>(getpid())) {
            error = "graphics_binding_inherited_requires_restart"; return false;
        }
        if (previous->profile != metadata) { error = "graphics_binding_change_requires_restart"; return false; }
        return true;
    }
    if (attempt.attempted) { error = "graphics_binding_failed_requires_restart:" + attempt.failure; return false; }
    // 系统OpenGL不能绕过应用启动声明直接dlopen/初始化。已冻结的表在上面返回，
    // 后续环境变化不重新选择provider；这里仅保护首次nativegl绑定。
    if (GraphicsProfileStringEqual(metadata->id, "nativegl") && !SystemGraphicsBootstrapConfigured()) {
        error = "graphics_system_gl_bootstrap_missing_requires_restart"; return false;
    }
    attempt.attempted = true;
    bindingInProgress = true;
    // 异常或任意失败出口都保留本次失败身份；后续请求不能在部分初始化进程中切provider。
    struct FailureGuard {
        BindingInitialization& state; std::string& error;
        ~FailureGuard() {
            bindingInProgress = false;
            if (!active.load(std::memory_order_acquire)) state.failure = error.empty() ? "initialization-exception" : error;
        }
    } failureGuard{attempt, error};
    auto value = std::make_unique<GraphicsRuntimeBinding>();
    value->processId = static_cast<int>(getpid()); value->profile = metadata;
    value->features = std::make_unique<GraphicsFeatureState>();
    value->publicApi = {sizeof(AmclGraphicsRuntimeV1), 1u, static_cast<uint64_t>(value->processId),
        metadata->id, metadata->api, metadata->contextApi, amclGraphicsGlProcV1, amclGraphicsEglProcV1, amclGraphicsInspectContextV1,
        value->is("mobilegl") ? presentSequence : nullptr, reserveContext, commitContext, retireContext,
        contextOperation, auxiliaryVerified, cleanupSafe, featuresJson, nullptr, providerProc};
    if (!GraphicsProfileStringEqual(metadata->api, "VULKAN")) {
        value->contextOperations = FindEglContextOperations(metadata->id);
        if (!value->contextOperations) { error = "graphics_context_implementation_missing"; return false; }
        value->glLibrary = metadata->systemLibrary ? dlopen(metadata->glLibName, RTLD_NOW | RTLD_LOCAL) :
            openSibling(value->is("mobileglues") ? "libamcl_gl_host.so" : metadata->glLibName);
        value->eglLibrary = translatorsOwnSymbols(*value) ? value->glLibrary : dlopen("libEGL.so", RTLD_NOW | RTLD_LOCAL);
        if (!value->glLibrary || !value->eglLibrary) { error = "graphics_binding_library_missing"; return false; }
        Dl_info image{};
        if (translatorsOwnSymbols(*value)) {
            if (!dladdr(dlsym(value->glLibrary, "eglGetDisplay"), &image) || !image.dli_fbase) {
                error = "graphics_binding_image_missing"; return false;
            }
            value->providerImage = image.dli_fbase;
        }
        if (value->is("mobilegl")) {
            void* sequence = dlsym(value->glLibrary, "mobileglGetPresentedSequenceV1");
            if (!owned(sequence, value->providerImage)) { error = "graphics_present_evidence_entry_missing"; return false; }
            value->providerPresentSequence = reinterpret_cast<uint64_t (*)()>(sequence);
        }
        using Resolver = void* (*)(const char*);
        if (value->is("mobileglues")) {
            value->glResolver = reinterpret_cast<Resolver>(dlsym(value->glLibrary, "amclGlHostGetProcAddressV1"));
            value->eglResolver = reinterpret_cast<Resolver>(dlsym(value->eglLibrary, "amclGlHostGetEglProcAddressV1"));
            using Initialize = int (*)(AmclGlHostInitReportV1*);
            auto initialize = reinterpret_cast<Initialize>(dlsym(value->glLibrary, "amclGlHostInitializeV1"));
            AmclGlHostInitReportV1 report{sizeof(report), 1u, 0, 0, {0}};
            if (!value->glResolver || !value->eglResolver || !initialize || !initialize(&report)) {
                error = std::string("graphics_binding_mg_initialize:") + report.stage; return false;
            }
            using Identity = const char* (*)();
            void* address = dlsym(value->glLibrary, "amclGlHostSourceIdentityV1");
            const char* identity = owned(address, value->providerImage) ? reinterpret_cast<Identity>(address)() : nullptr;
            if (identity && std::strlen(identity) <= 1024) value->implementationIdentity = identity;
        } else if (!value->is("nativegl")) {
            // 原生GL不使用GLX查找器；fillEglTable完成后由glProc消费其EGL解析入口。
            // MobileGL/GL4ES仍按各自提供者的既有公开查询方式工作。
            value->glResolver = reinterpret_cast<Resolver>(dlsym(value->glLibrary,
                value->is("mobilegl") ? "eglGetProcAddress" : "glXGetProcAddress"));
        }
        fillEglTable(*value);
        if (!value->egl.ready || !value->glProc("glGetString")) {
            error = "graphics_binding_required_entry_missing"; return false;
        }
    }
    value->publicApi.implementationIdentity = value->implementationIdentity.c_str();
    // 表完整后一次发布；初始化互斥已保证输家不会进入任何provider副作用。
    auto* candidate = value.get();
    if (active.compare_exchange_strong(previous, candidate, std::memory_order_release, std::memory_order_acquire)) {
        value.release(); return true;
    }
    if (previous && previous->processId == value->processId && previous->profile == metadata) return true;
    error = "graphics_binding_concurrent_conflict"; return false;
}
}

namespace {
uint64_t presentSequence() {
    const auto* value = BoundGraphicsRuntime();
    return value && value->providerPresentSequence ? value->providerPresentSequence() : 0;
}
uint64_t reserveContext(void* share) {
    const auto* value = BoundGraphicsRuntime(); return value ? ReserveGraphicsContext(*value, share) : 0;
}
int commitContext(uint64_t permit, void* context) {
    const auto* value = BoundGraphicsRuntime(); return value && CommitGraphicsContext(*value, permit, context);
}
int retireContext(void* context) {
    const auto* value = BoundGraphicsRuntime(); return value && RetireGraphicsContext(*value, context);
}
int auxiliaryVerified(int shared) { const auto* r = localBound(); return r && GraphicsAuxiliaryVerified(*r, shared != 0); }
int cleanupSafe() { const auto* r = localBound(); return r && GraphicsCleanupSafe(*r); }
const char* featuresJson() {
    static thread_local std::string text;
    const auto* r = localBound(); text = r ? GraphicsFeaturesJson(*r) : "null"; return text.c_str();
}
void* providerProc(const char* name) { const auto* r = localBound(); return r ? r->providerProc(name) : nullptr; }
int contextOperation(uint32_t operation, AmclGraphicsContextStateV1* state, uint32_t size,
    const AmclGraphicsContextRequestV1* request, int32_t tid, char* output, uint32_t capacity) {
    const auto* r = localBound(); std::string error; bool ready = false;
    const bool valid = r && r->contextOperations && state && size >= sizeof(*state) && tid > 0;
    try {
        if (!valid) error = "graphics_context_abi_or_owner_invalid";
        else if (operation == AMCL_CONTEXT_CREATE && request) {
            const amcl::desktop::ContextRequest q{request->major, request->minor, request->profile, request->forward != 0};
            ready = r->contextOperations->create(*r, *state, q, tid, error);
        } else if (operation == AMCL_CONTEXT_ATTACH && request)
            ready = r->contextOperations->attach(*r, *state, request->nativeWindow, request->width, request->height, tid, error);
        else if (operation == AMCL_CONTEXT_SUSPEND) ready = r->contextOperations->suspend(*r, *state, tid, error);
        else if (operation == AMCL_CONTEXT_DESTROY) ready = r->contextOperations->destroy(*r, *state, tid, error);
        else error = "graphics_context_operation_invalid";
    } catch (...) {
        error = "graphics_context_operation_exception";
        if (valid) { state->contextLostFatal = 1; state->shouldClose = 1; }
    }
    if (output && capacity) { std::strncpy(output, error.c_str(), capacity - 1); output[capacity - 1] = 0; }
    return ready ? 1 : 0;
}
}

bool FreezeGraphicsRuntime(const char* id, const char* api, std::string& error) {
    error.clear();
    const auto* owner = service(true, &error);
    if (!owner) return false;
    char detail[512]{};
    const bool ready = owner->bind(id, api, detail, sizeof(detail)) == 1;
    error = detail;
    if (!ready) return false;
    // SDL等纯C消费者也必须共享同一owner；并发发布的地址来自赢家binding，始终相同。
    const auto* value = BoundGraphicsRuntime();
    if (!value) { error = "graphics_binding_owner_missing"; return false; }
    char encoded[96]; std::snprintf(encoded, sizeof(encoded), "1:%d:%p", value->processId,
        static_cast<const void*>(value->delegate ? value->delegate : &value->publicApi));
#if defined(_WIN32)
    const int published = _putenv_s(AMCL_GRAPHICS_RUNTIME_ENV, encoded);
#else
    const int published = setenv(AMCL_GRAPHICS_RUNTIME_ENV, encoded, 1);
#endif
    if (published != 0) {
        error = "graphics_binding_publication_failed"; return false;
    }
    return true;
}

const GraphicsRuntimeBinding* RequireGraphicsRuntime() {
    if (const auto* value = BoundGraphicsRuntime()) return value;
    std::string error;
    const char* id = std::getenv("AMCL_GRAPHICS_PROFILE");
    const char* api = std::getenv("AMCL_GRAPHICS_API");
    return FreezeGraphicsRuntime(id, api, error) ? BoundGraphicsRuntime() : nullptr;
}
}
extern "C" uintptr_t amclGraphicsRuntimeOwnerV1() {
    return reinterpret_cast<uintptr_t>(amcl::graphics::service(false));
}
extern "C" int amclGraphicsReadPresentSequenceV1(uint64_t* sequence) {
    if (!sequence) return 0;
    *sequence = 0;
    const auto* value = amcl::graphics::BoundGraphicsRuntime();
    if (!value || !value->publicApi.presentSequence) return 0;
    *sequence = value->publicApi.presentSequence(); return 1;
}
extern "C" void* amclGraphicsGlProcV1(const char* name) {
    const auto* value = amcl::graphics::BoundGraphicsRuntime();
    return value ? value->glProc(name) : nullptr;
}
extern "C" void* amclGraphicsEglProcV1(const char* name) {
    const auto* value = amcl::graphics::BoundGraphicsRuntime();
    return value ? value->eglProc(name) : nullptr;
}
extern "C" int amclGraphicsBindRuntimeV1(const char* profile, const char* api, char* output, int capacity) {
    std::string error;
    const bool ready = amcl::graphics::FreezeGraphicsRuntime(profile, api, error);
    if (output && capacity > 0) {
        std::strncpy(output, error.c_str(), static_cast<std::size_t>(capacity) - 1);
        output[capacity - 1] = '\0';
    }
    return ready ? 1 : 0;
}
extern "C" __attribute__((visibility("default"))) const char* amclGraphicsBoundProfileV1() {
    const auto* value = amcl::graphics::BoundGraphicsRuntime(); return value ? value->profile->id : "UNKNOWN";
}
extern "C" __attribute__((visibility("default"))) const char* amclGraphicsBoundApiV1() {
    const auto* value = amcl::graphics::BoundGraphicsRuntime(); return value ? value->profile->api : "UNKNOWN";
}
