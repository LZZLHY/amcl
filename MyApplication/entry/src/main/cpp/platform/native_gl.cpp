#include "native_gl.h"
#include "system_egl.h"
#include "system_gl_dispatch.h"
#include "native_gl_render_probe.h"
#include "native_gl_probe_core.h"
#include "graphics_bootstrap.h"
#include "graphics_probe_gate.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <dlfcn.h>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <sstream>
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

#ifndef AMCL_DESKTOP_NATIVE_GL_VALIDATE
#define AMCL_DESKTOP_NATIVE_GL_VALIDATE 0
#endif
#ifndef AMCL_NATIVE_DESKTOP_ONLY
#define AMCL_NATIVE_DESKTOP_ONLY 0
#endif
namespace amcl::desktop {
bool NativeGlValidationEnabled() { return AMCL_DESKTOP_NATIVE_GL_VALIDATE != 0; }
bool NativeGlRequired() { return false; } // Legacy ABI: products no longer require a renderer.
bool NativeGlRequested() {
    // GraphicsPlan publishes the route before provider initialization.
    const char* api = getenv("AMCL_GRAPHICS_API");
    if (api && strcmp(api, "VULKAN") == 0) return false;
    const char* profile = getenv("AMCL_GRAPHICS_PROFILE");
    if (profile && strcmp(profile, "minecraft-vulkan") == 0) return false;
    if (profile) return strcmp(profile, "nativegl") == 0;
    const char* value = getenv("AMCL_NATIVE_GL_ACTIVE");
    return value && strcmp(value, "1") == 0;
}
void* NativeGlProc(const char* name) {
    // 库存在性及进程寿命仍由系统提供者固定；GL地址只从同一个EGL驱动解析，
    // 不能优先调用libGLv4中可能保留no-context TLS的包装函数。
    static void* library = dlopen("libGLv4.so", RTLD_NOW | RTLD_LOCAL);
    return library ? ResolveSystemGlProc(SystemEgl(), name) : nullptr;
}
namespace {
int probeProcessId() {
#ifdef _WIN32
    return _getpid();
#else
    return getpid();
#endif
}
/** 探针提供者和失败资源按进程存活；fork不借用父驱动，清理失败后不在别的worker重试。
 * gate串行保护下面的资源和poisoned状态，忙调用立即返回，不阻塞NAPI工作线程。
 */
struct NativeGlProbeState {
    const int processId = probeProcessId();
    amcl::graphics::GraphicsProbeGate gate;
    bool poisoned = false;
    NativeGlProbeResources resources;
};
NativeGlProbeState& nativeGlProbeState() {
    static auto* value = new NativeGlProbeState;
    return *value;
}
/** 只读取包装入口的地址供诊断对照，绝不以该地址执行GL。 */
void* NativeGlWrapperAddress(const char* name) {
    static void* library = dlopen("libGLv4.so", RTLD_NOW | RTLD_LOCAL);
    return library && name ? dlsym(library, name) : nullptr;
}
std::string ProcImage(void* pointer) {
    Dl_info info{};
    return pointer && dladdr(pointer,&info) && info.dli_fname ? info.dli_fname : "unresolved";
}
std::string RenderDiagnostics() {
    std::ostringstream report;
    report << "AMCL_DESKTOP_RENDER_PROBE_V3\n"
        << "scope=private-context; not-game-frame; not-JVM-namespace\n";
    for (const char* name : {"glGetString", "glGetError", "glDrawElements", "glDrawElementsBaseVertex",
        "glMultiDrawElementsBaseVertex", "glBindBufferRange", "glMapBufferRange", "glBufferStorage",
        "glTexImage2D", "glTexStorage2D", "glVertexAttribPointer", "glVertexAttribIPointer",
        "glBindSampler", "glShaderSource", "glUniformBlockBinding", "glBindFramebuffer", "glBlitFramebuffer"}) {
        void* driver = NativeGlProc(name);
        void* wrapper = NativeGlWrapperAddress(name);
        report << name << " egl-provider=" << ProcImage(driver) << " wrapper-address-only=" << ProcImage(wrapper)
            << " present=" << (driver != nullptr) << ',' << (wrapper != nullptr)
            << " same=" << (driver == wrapper) << '\n';
    }
    // 正式LWJGL也经冻结运行时使用同一EGL解析规则。详细探针不再执行可能失效的
    // 包装层作为“第二次对照”，否则修好基础探针后仍会在开发诊断里重现同样崩溃。
    report << renderprobe::Run(NativeGlProc,"system-egl-provider");
    report << "boundary=diagnostic-only; does not validate Minecraft, mods, persistent mapping or window presentation\n";
    return report.str();
}
}
NativeGlCapability QueryNativeGlCapability(bool detailed, bool availabilityOnly) {
    NativeGlCapability result;
    // 只验证启动声明，不晚写环境。缺失时甚至不执行入口查询，避免为错误包继续锁存GLES。
    result.bootstrapConfigured = amcl::graphics::SystemGraphicsBootstrapConfigured();
    if (!result.bootstrapConfigured) { result.stage = "system-gl-bootstrap-missing"; return result; }
    auto& state = nativeGlProbeState();
    const int currentPid = probeProcessId();
    if (state.processId != currentPid) {
        result.stage = "native-gl-inherited-provider"; result.restartRequired = true; return result;
    }
    amcl::graphics::GraphicsProbeGate::Lease lease(state.gate, static_cast<uint32_t>(currentPid));
    if (!lease.entered()) { result.stage = "native-gl-probe-busy"; return result; }
    if (state.poisoned) {
        result.stage = "native-gl-probe-retirement-requires-restart";
        result.cleanupComplete = false; result.restartRequired = true; return result;
    }
    static void* library = dlopen("libGLv4.so", RTLD_NOW | RTLD_LOCAL);
    result.systemLibrary = library != nullptr;
    if (!result.systemLibrary) { result.stage = "system-gl-library"; return result; }
    if (!SystemEgl().ready) { result.stage = "system-egl-symbols"; result.errorDomain = "entrypoint"; return result; }
    using Query = EGLBoolean (*)();
    const auto query = reinterpret_cast<Query>(SystemEgl().eglGetProcAddress("OH_Graphics_QueryGL"));
    result.queryAvailable = query != nullptr;
    if (!query) return result;
    result.querySupported = query() == EGL_TRUE;
    if (!result.querySupported) return result;
    // 入口查询可能初始化系统EGL，但启动能力声明已在AppScope生效；这里不制造context证据。
    if (availabilityOnly) { result.stage = "system-gl-entry-ready"; return result; }
    ProbeNativeGlContext(SystemEgl(), state.resources, NativeGlProc, RenderDiagnostics, detailed, result);
    if (!result.cleanupComplete) state.poisoned = true;
    return result;
}

std::string NativeGlFailureDetail(const NativeGlCapability& capability) {
    // 使用已采集首错和独立清理结果，格式化阶段禁止再次调用eglGetError消耗或改写证据。
    std::ostringstream out;
    out << capability.stage;
    if (capability.error) out << " [" << capability.errorDomain << " 0x" << std::hex << capability.error << ']';
    if (!capability.bootstrapConfigured) out << "; startup NEED_OPENGL=1 missing";
    if (!capability.cleanupComplete) out << "; " << capability.cleanupStage << " [EGL 0x" << std::hex << capability.cleanupError << ']';
    if (capability.restartRequired) out << "; process restart required";
    return out.str();
}
}
