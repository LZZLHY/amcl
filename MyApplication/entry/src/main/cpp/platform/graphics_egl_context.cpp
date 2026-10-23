// OpenGL生命周期实现注册表：复用已有生产核心，冻结后由窗口前端直接调用同一操作表。
#include "graphics_egl_context.h"
#include "graphics_runtime_binding.h"
#include "gles_egl_core.h"
#include "mobilegl_egl_core.h"
#include <cstring>
#include <unistd.h>
namespace amcl::graphics {
namespace {
// 在任何驱动分配前登记，部分初始化失败仍有可达owner；共享组身份在父context销毁后不变。
bool track(const GraphicsRuntimeBinding& r, EglContextState& s, std::string& error) {
    auto& f = *r.features; std::lock_guard<std::recursive_mutex> lock(f.resourcesMutex);
    if (f.contexts.count(&s)) { error = "context-already-tracked"; return false; }
    s.contextPermit = ReserveGraphicsContext(r, s.shareContext);
    if (!s.contextPermit) { error = "context-topology-unverified-or-creation-pending"; return false; }
    if (s.shareContext != EGL_NO_CONTEXT) for (const auto* owner : f.contexts)
        if (owner->context == s.shareContext) { s.shareGroup = owner->shareGroup; break; }
    if (!s.shareGroup) s.shareGroup = ++f.nextShareGroup;
    f.contexts.insert(&s);
    return true;
}
// 完成驱动创建后将真实句柄登记到同一资格。失败保留预留和句柄，原destroy路径负责退休。
bool created(const GraphicsRuntimeBinding& r, EglContextState& s, bool ready, std::string& error) {
    if (!ready) return false;
    // 不借窗口表推断 display 生命周期：成功创建证明 eglInitialize 已经完成，哪怕
    // 后续资格提交失败也仍有待真实退休的 provider 对象。记录与最后 context 退休同锁。
    { std::lock_guard<std::recursive_mutex> lock(r.features->resourcesMutex);
      r.features->initializedEglDisplay = s.display; }
    if (CommitGraphicsContext(r, s.contextPermit, s.context)) return true;
    error = "context-permit-commit-failed"; s.contextLostFatal = true; s.shouldClose = 1; return false;
}
bool untrack(const GraphicsRuntimeBinding& r, EglContextState& s, bool result, EGLDisplay oldDisplay, std::string& e) {
    if (!result) return false;
    auto& f = *r.features; std::lock_guard<std::recursive_mutex> lock(f.resourcesMutex);
    // MobileGL display属于进程provider，而非某个窗口。主/辅任意顺序销毁时只在最后一个
    // 真正退休后terminate；失败保持账本与display，以便重试，不使剩余context失效。
    if (r.is("mobilegl") && f.contextPermits.size() == 1 && f.contexts.count(&s) && oldDisplay != EGL_NO_DISPLAY) {
        if (!r.egl.eglTerminate(oldDisplay)) {
            s.display = oldDisplay; s.eglTeardownPending = true; e = "last-context-display-retirement"; return false;
        }
        // 唯有本次真实 terminate 成功才失效；GLFW 末窗可能仍有 SDL/另一 namespace 的
        // context 资格，因此不得按窗口数清除。系统/MG 路线保留初始化到进程结束。
        f.initializedEglDisplay = nullptr;
    }
    ReleaseGraphicsContextPermit(r, s.contextPermit); s.contextPermit = 0;
    f.contexts.erase(&s); return true;
}
bool completeEglOperation(EglContextState& s, bool result, const EglLifecycleStatus& failure,
                    const char* operation, std::string& error, bool wasFatal) {
    if (result) return true;
    // 原生错误已由失败操作捕获。线程/状态拒绝的driverFailure为false，绝不读取遗留错误；
    // context lost立即封闭恢复路线，原句柄仍交给实际owner按原顺序退休。
    // 判断必须使用调用底层之前的终局快照。GLES core 会在返回本次 lost 之前先置 fatal，
    // 事后读取该位会漏存第一次错误。此前已有终局则保留其首因（包括非驱动原因），
    // 此前尚未终局则记录本次真实失败，让普通 surface 故障能正确升级成 context lost。
    if (!wasFatal) s.lastFailure = failure;
    if (failure.contextLost()) { s.contextLostFatal = true; s.shouldClose = 1; }
    if (error.empty()) error = *failure.stage ? failure.text() : std::string(operation) + " failed; resource ownership retained";
    return false;
}
bool createGles(const GraphicsRuntimeBinding& r, EglContextState& s, const amcl::desktop::ContextRequest& q, int tid, std::string& e) {
    if (!track(r, s, e)) return false;
    const bool wasFatal = s.contextLostFatal;
    EglLifecycleStatus failure;
    const bool ready = CreateGlesEgl(r.egl, s, q.major, tid, e, s.auxiliary, &failure);
    return created(r, s, completeEglOperation(s, ready, failure, "create-gles", e, wasFatal), e);
}
bool suspendGles(const GraphicsRuntimeBinding& r, EglContextState& s, int tid, std::string& e) {
    const bool wasFatal = s.contextLostFatal;
    EglLifecycleStatus failure;
    const bool ready = SuspendGlesEglSurface(r.egl, s, tid, e, &failure);
    return completeEglOperation(s, ready, failure, "suspend-gles", e, wasFatal);
}
bool attachGles(const GraphicsRuntimeBinding& r, EglContextState& s, void* w, int x, int y, int tid, std::string& e) {
    const bool wasFatal = s.contextLostFatal;
    EglLifecycleStatus failure;
    const bool ready = AttachGlesEglSurface(r.egl, s, w, x, y, tid, e, &failure);
    return completeEglOperation(s, ready, failure, "attach-gles", e, wasFatal);
}
bool destroyGles(const GraphicsRuntimeBinding& r, EglContextState& s, int tid, std::string& e) {
    const bool wasFatal = s.contextLostFatal;
    const auto display = s.display; EglLifecycleStatus failure;
    const bool ready = DestroyGlesEgl(r.egl, s, tid, e, &failure);
    return untrack(r, s, completeEglOperation(s, ready, failure, "destroy-gles", e, wasFatal), display, e);
}
bool createDesktop(const GraphicsRuntimeBinding& r, EglContextState& s, const amcl::desktop::ContextRequest& q, int tid, std::string& e) {
    if (!track(r, s, e)) return false;
    const bool wasFatal = s.contextLostFatal;
    EglLifecycleStatus failure;
    const bool ready = s.auxiliary ? amcl::desktop::CreateDesktopEgl(r.egl, s, q, amclGraphicsGlProcV1, tid, e,
        amcl::desktop::EglPbufferGeometry{s.width, s.height}, &failure) :
        amcl::desktop::CreateDesktopEgl(r.egl, s, q, amclGraphicsGlProcV1, tid, e, amcl::desktop::EglSurfaceGeometry{}, &failure);
    return created(r, s, completeEglOperation(s, ready, failure, "create-desktop", e, wasFatal), e);
}
bool createMobile(const GraphicsRuntimeBinding& r, EglContextState& s, const amcl::desktop::ContextRequest& q, int tid, std::string& e) {
    if (!track(r, s, e)) return false;
    const bool wasFatal = s.contextLostFatal;
    EglLifecycleStatus failure;
    const bool ready = CreateMobileGlEgl(r.egl, s, q, amclGraphicsGlProcV1, tid, e, s.auxiliary, GraphicsAuxiliaryVerified(r, true), &failure);
    return created(r, s, completeEglOperation(s, ready, failure, "create-mobilegl", e, wasFatal), e);
}
bool suspendDesktop(const GraphicsRuntimeBinding& r, EglContextState& s, int tid, std::string& e) {
    const bool wasFatal = s.contextLostFatal;
    EglLifecycleStatus failure;
    const bool ready = amcl::desktop::SuspendDesktopEglSurface(r.egl, s, tid, &failure);
    return completeEglOperation(s, ready, failure, "suspend-desktop", e, wasFatal);
}
bool attachDesktop(const GraphicsRuntimeBinding& r, EglContextState& s, void* w, int x, int y, int tid, std::string& e) {
    const bool wasFatal = s.contextLostFatal;
    EglLifecycleStatus failure;
    const bool ready = amcl::desktop::AttachDesktopEglSurface(r.egl, s, w, x, y, tid, amcl::desktop::EglSurfaceGeometry{}, &failure);
    return completeEglOperation(s, ready, failure, "attach-desktop", e, wasFatal);
}
bool attachMobile(const GraphicsRuntimeBinding& r, EglContextState& s, void* w, int x, int y, int tid, std::string& e) {
    const bool wasFatal = s.contextLostFatal;
    EglLifecycleStatus failure;
    const bool ready = AttachMobileGlEglSurface(r.egl, s, w, x, y, tid, &failure);
    return completeEglOperation(s, ready, failure, "attach-mobilegl", e, wasFatal);
}
bool destroyDesktop(const GraphicsRuntimeBinding& r, EglContextState& s, int tid, std::string& e) {
    const bool wasFatal = s.contextLostFatal;
    const auto display = s.display;
    EglLifecycleStatus failure;
    const bool ready = amcl::desktop::DestroyDesktopEgl(r.egl, s, tid, &failure);
    return untrack(r, s, completeEglOperation(s, ready, failure, "destroy-desktop", e, wasFatal), display, e);
}
bool destroyMobile(const GraphicsRuntimeBinding& r, EglContextState& s, int tid, std::string& e) {
    return destroyDesktop(r, s, tid, e);
}
const EglContextOperations gles{"gles", false, createGles, suspendGles, attachGles, destroyGles};
const EglContextOperations desktop{"system-desktop-gl", true, createDesktop, suspendDesktop, attachDesktop, destroyDesktop};
// 操作算法与系统 desktop 核心共用，观测名称保留真实 translator 身份，不能把其
// 底层 GLES 包装记成系统 desktop driver。该记录不是第二套 provider 选择注册表。
const EglContextOperations mobilegluesDesktop{"mobileglues-desktop-gl", true, createDesktop, suspendDesktop, attachDesktop, destroyDesktop};
const EglContextOperations mobile{"mobilegl-desktop-gl", true, createMobile, suspendDesktop, attachMobile, destroyMobile};
struct Registration { const char* profile; const EglContextOperations* operations; };
// MG 公开 EGL 接受 desktop 请求并保存授予身份，实际 ES transport 由同一 provider
// 内部建立。复用整个 desktop 操作表使 create/停车/恢复/退休采用相同 API，不能只在
// create 时改入口而让后续操作又按 GLES 请求。GL4ES 仍消费系统 GLES context。
const Registration implementations[] = {{"mobileglues", &mobilegluesDesktop}, {"gl4es", &gles}, {"nativegl", &desktop}, {"mobilegl", &mobile}};
}
const EglContextOperations* FindEglContextOperations(const char* profile) {
    if (profile) for (const auto& item : implementations) if (std::strcmp(item.profile, profile) == 0) return item.operations;
    return nullptr;
}
namespace {
// 非owner副本只传递C资源记录，不捕获owner的std::function/unique_ptr/mutex。
bool forwardContext(const GraphicsRuntimeBinding& runtime, uint32_t operation, EglContextState& state,
                    const AmclGraphicsContextRequestV1* request, int tid, std::string& error) {
    if (!runtime.delegate || !runtime.delegate->contextOperation) { error = "graphics_context_owner_unavailable"; return false; }
    char detail[512]{};
    const bool result = runtime.delegate->contextOperation(operation, &state, sizeof(state), request, tid, detail, sizeof(detail)) == 1;
    error = detail; return result;
}
bool forwardCreate(const GraphicsRuntimeBinding& r, EglContextState& s, const amcl::desktop::ContextRequest& q, int tid, std::string& e) {
    const AmclGraphicsContextRequestV1 request{q.major, q.minor, q.profile, q.forward ? 1u : 0u, nullptr, 0, 0};
    return forwardContext(r, AMCL_CONTEXT_CREATE, s, &request, tid, e);
}
bool forwardSuspend(const GraphicsRuntimeBinding& r, EglContextState& s, int tid, std::string& e) {
    return forwardContext(r, AMCL_CONTEXT_SUSPEND, s, nullptr, tid, e);
}
bool forwardAttach(const GraphicsRuntimeBinding& r, EglContextState& s, void* window, int width, int height, int tid, std::string& e) {
    const AmclGraphicsContextRequestV1 request{0, 0, 0, 0, window, width, height};
    return forwardContext(r, AMCL_CONTEXT_ATTACH, s, &request, tid, e);
}
bool forwardDestroy(const GraphicsRuntimeBinding& r, EglContextState& s, int tid, std::string& e) {
    return forwardContext(r, AMCL_CONTEXT_DESTROY, s, nullptr, tid, e);
}
const EglContextOperations forwardedGl{"process-owner-desktop", true, forwardCreate, forwardSuspend, forwardAttach, forwardDestroy};
const EglContextOperations forwardedEs{"process-owner-gles", false, forwardCreate, forwardSuspend, forwardAttach, forwardDestroy};
}
const EglContextOperations* ForwardedEglContextOperations(bool desktopApi) { return desktopApi ? &forwardedGl : &forwardedEs; }

void* InitializedEglDisplay(const GraphicsRuntimeBinding& runtime) {
    if (runtime.processId != static_cast<int>(getpid())) return nullptr;
    if (runtime.delegate) {
        if (!runtime.delegate->contextOperation) return nullptr;
        EglContextState snapshot{};
        // 只读扩展不要求线程取得 context owner；旧 owner 不支持 opcode 时返回0，
        // 必须保持失败关闭，不能转而读另一映像的缓存或新装入 provider。
        return runtime.delegate->contextOperation(AMCL_CONTEXT_QUERY_DISPLAY, &snapshot, sizeof(snapshot),
            nullptr, 0, nullptr, 0) == 1 ? snapshot.display : nullptr;
    }
    if (!runtime.features) return nullptr;
    std::lock_guard<std::recursive_mutex> lock(runtime.features->resourcesMutex);
    return runtime.features->initializedEglDisplay;
}
}
