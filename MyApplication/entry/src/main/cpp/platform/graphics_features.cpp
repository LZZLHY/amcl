// 功能探针只在首次新context交付前运行，不进入每帧路径、不向游戏宣称未测的高级GL功能。
#include "graphics_features.h"
#include "graphics_runtime_binding.h"
#include <array>
#include <chrono>
#include <cstring>
#include <cstdio>
#include <sstream>
#include <vector>

namespace amcl::graphics {
namespace {
constexpr unsigned arrayBuffer = 0x8892, arrayBinding = 0x8894, copyRead = 0x8f36, copyWrite = 0x8f37;
struct Gl {
    void (*getInt)(unsigned, int*) = nullptr;
    const unsigned char* (*getString)(unsigned) = nullptr;
    unsigned (*getError)() = nullptr;
    void (*gen)(int, unsigned*) = nullptr;
    void (*bind)(unsigned, unsigned) = nullptr;
    void (*data)(unsigned, intptr_t, const void*, unsigned) = nullptr;
    void (*copy)(unsigned, unsigned, intptr_t, intptr_t, intptr_t) = nullptr;
    void* (*map)(unsigned, intptr_t, intptr_t, unsigned) = nullptr;
    unsigned char (*unmap)(unsigned) = nullptr;
    void (*remove)(int, const unsigned*) = nullptr;
    unsigned char (*isBuffer)(unsigned) = nullptr;
    void* (*fence)(unsigned, unsigned) = nullptr;
    unsigned (*wait)(void*, unsigned, uint64_t) = nullptr;
    void (*deleteSync)(void*) = nullptr;
};
std::string text(const unsigned char* value) {
    return value ? std::string(reinterpret_cast<const char*>(value)).substr(0, 256) : "";
}
const char* evidence(FeatureEvidence value) {
    switch (value) { case FeatureEvidence::Verified: return "verified"; case FeatureEvidence::Unsupported: return "unsupported";
        case FeatureEvidence::Unknown: return "unknown"; default: return "not-run"; }
}
std::string quote(const std::string& value) {
    std::string result = "\"";
    for (unsigned char c : value) { if (c == '\\' || c == '"') result += '\\'; result += c >= 32 ? static_cast<char>(c) : '_'; }
    return result + '"';
}
}
/** SDL只传EGL句柄与已选择的context请求，不依赖GLFW/C++窗口布局；真实current仍由探针校验。 */
extern "C" int amclGraphicsInspectContextV1(void* display, void* config, void* context, void* surface,
    int major, int minor, int profile) {
    const auto* runtime = amcl::graphics::BoundGraphicsRuntime();
    if (!runtime || !runtime->egl.ready) return 0;
    if (runtime->delegate) return runtime->delegate->inspectContext ? runtime->delegate->inspectContext(display, config, context,
        surface, major, minor, profile) : 0;
    if (!runtime->features) return 0;
    amcl::graphics::EglContextState state;
    state.display = display; state.config = config; state.context = context; state.surface = surface;
    state.actualContextMajor = major; state.actualContextMinor = minor; state.actualContextProfile = profile;
    return amcl::graphics::ProbeGraphicsFeatures(*runtime, state) ? 1 : 0;
}
bool ProbeGraphicsFeatures(const GraphicsRuntimeBinding& runtime, EglContextState& window) {
    if (runtime.delegate) return runtime.delegate->inspectContext && runtime.delegate->inspectContext(window.display, window.config,
        window.context, window.surface, window.actualContextMajor, window.actualContextMinor, window.actualContextProfile) == 1;
    auto& report = *runtime.features;
    std::lock_guard<std::mutex> lock(report.mutex);
    if (report.probed) return report.cleanupSafe;
    // 只有真实current且资源完整时测试；尚无context不应缓存成永久“不支持”。
    const auto& egl = runtime.egl;
    if (!egl.ready || window.context == EGL_NO_CONTEXT || window.config == nullptr ||
        egl.eglGetCurrentContext() != window.context || egl.eglGetCurrentDisplay() != window.display) return false;
    report.probed = true;
    const auto started = std::chrono::steady_clock::now();
    Gl gl;
#define LOAD(member, name) gl.member = reinterpret_cast<decltype(gl.member)>(runtime.glProc(name))
    LOAD(getInt, "glGetIntegerv"); LOAD(getString, "glGetString"); LOAD(getError, "glGetError");
    LOAD(gen, "glGenBuffers"); LOAD(bind, "glBindBuffer"); LOAD(data, "glBufferData");
    LOAD(copy, "glCopyBufferSubData"); LOAD(map, "glMapBufferRange"); LOAD(unmap, "glUnmapBuffer");
    LOAD(remove, "glDeleteBuffers"); LOAD(isBuffer, "glIsBuffer"); LOAD(fence, "glFenceSync");
    LOAD(wait, "glClientWaitSync"); LOAD(deleteSync, "glDeleteSync");
#undef LOAD
    if (gl.getString) { report.vendor = text(gl.getString(0x1f00)); report.renderer = text(gl.getString(0x1f01)); report.version = text(gl.getString(0x1f02)); }
    // GL2/缺入口保持未测；不能仅以兼容层导出一个同名stub就制造能力证据。
    int frontendMajor = 0;
    const char* versionText = report.version.c_str();
    if (report.version.rfind("OpenGL ES ", 0) == 0) versionText += 10;
    std::sscanf(versionText, "%d", &frontendMajor);
    if (frontendMajor < 3 || window.actualContextMajor < 3 || !gl.getInt || !gl.getError || !gl.gen || !gl.bind ||
        !gl.data || !gl.map || !gl.unmap || !gl.remove || !gl.isBuffer) {
        report.reason = "buffer-probe-entry-or-version-unavailable"; return true;
    }
    if (gl.getError() != 0) { report.reason = "preexisting-gl-error-probe-skipped"; return true; }
    int previousArray = 0, previousRead = 0, previousWrite = 0;
    gl.getInt(arrayBinding, &previousArray);
    if (gl.getError() != 0) { report.reason = "array-binding-query-unavailable"; return true; }
    gl.getInt(copyRead, &previousRead); gl.getInt(copyWrite, &previousWrite);
    // 有的翻译器没有实现COPY_*绑定查询。不能让该查询的遗留GL错误污染独立的ARRAY
    // 对象/共享验证；也不能在无法还原原绑定时修改COPY_*状态。只跳过复制这一项。
    const bool copyBindingsReadable = gl.getError() == 0;
    const EGLSurface previousDraw = egl.eglGetCurrentSurface(EGL_DRAW), previousReadSurface = egl.eglGetCurrentSurface(EGL_READ);
    const std::array<unsigned, 4> expected{{0x31415926u, 0x27182818u, 0x10203040u, 0x55667788u}};
    unsigned objects[2]{}; gl.gen(2, objects);
    auto matches = [&](unsigned target) {
        void* bytes = gl.map(target, 0, sizeof(expected), 1u /* GL_MAP_READ_BIT */);
        const bool matched = bytes && std::memcmp(bytes, expected.data(), sizeof(expected)) == 0;
        const bool unmapped = !bytes || gl.unmap(target) != 0;
        return matched && unmapped && gl.getError() == 0;
    };
    gl.bind(arrayBuffer, objects[0]); gl.data(arrayBuffer, sizeof(expected), expected.data(), 0x88e4);
    const bool sourceValid = objects[0] && objects[1] && gl.isBuffer(objects[0]) && matches(arrayBuffer);
    if (sourceValid && gl.copy && copyBindingsReadable) {
        gl.bind(copyRead, objects[0]); gl.bind(copyWrite, objects[1]); gl.data(copyWrite, sizeof(expected), nullptr, 0x88e4);
        gl.copy(copyRead, copyWrite, 0, 0, sizeof(expected));
        report.bufferCopy = matches(copyWrite) ? FeatureEvidence::Verified : FeatureEvidence::Unsupported;
    } else report.bufferCopy = FeatureEvidence::Unknown;
    if (gl.fence && gl.wait && gl.deleteSync) {
        void* sync = gl.fence(0x9117 /* GL_SYNC_GPU_COMMANDS_COMPLETE */, 0);
        const unsigned waited = sync ? gl.wait(sync, 1u, 50000000u) : 0;
        if (sync) gl.deleteSync(sync);
        report.fence = gl.getError() != 0 || !sync ? FeatureEvidence::Unsupported :
            (waited == 0x911a || waited == 0x911c) ? FeatureEvidence::Verified : FeatureEvidence::Unknown;
    }
    // 实际创建共享与非共享context，不仅检查eglCreateContext返回值。GL绑定必须隔离，
    // 共享buffer要读回相同字节；非共享context不能看到同名对象。失败不开放辅助窗口。
    EGLSurface probeSurface = EGL_NO_SURFACE;
    EGLContext shared = EGL_NO_CONTEXT, independent = EGL_NO_CONTEXT;
    const EGLint pbuffer[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    std::vector<EGLint> attributes = {EGL_CONTEXT_MAJOR_VERSION, window.actualContextMajor};
    if (runtime.desktopGl()) {
        attributes.insert(attributes.end(), {EGL_CONTEXT_MINOR_VERSION, window.actualContextMinor});
        if (window.actualContextProfile) attributes.insert(attributes.end(), {EGL_CONTEXT_OPENGL_PROFILE_MASK,
            window.actualContextProfile == 0x00032001 ? EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT : EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT});
    }
    attributes.push_back(EGL_NONE);
    if (sourceValid) {
        probeSurface = egl.eglCreatePbufferSurface(window.display, window.config, pbuffer);
        shared = probeSurface != EGL_NO_SURFACE ? egl.eglCreateContext(window.display, window.config, window.context, attributes.data()) : EGL_NO_CONTEXT;
        if (shared != EGL_NO_CONTEXT && egl.eglMakeCurrent(window.display, probeSurface, probeSurface, shared)) {
            int binding = -1; gl.getInt(arrayBinding, &binding);
            report.contextIsolation = binding == 0 ? FeatureEvidence::Verified : FeatureEvidence::Unsupported;
            const bool visible = gl.isBuffer(objects[0]) != 0;
            gl.bind(arrayBuffer, objects[0]);
            report.sharedObjects = visible && matches(arrayBuffer) ? FeatureEvidence::Verified : FeatureEvidence::Unsupported;
            gl.bind(arrayBuffer, 0);
            // 回原context验证其绑定没有随辅助context变化；只看新context初值不足以发现全局GLState。
            if (egl.eglMakeCurrent(window.display, previousDraw, previousReadSurface, window.context)) {
                gl.getInt(arrayBinding, &binding);
                if (binding != static_cast<int>(objects[0])) report.contextIsolation = FeatureEvidence::Unsupported;
            } else report.cleanupSafe = false;
            independent = egl.eglCreateContext(window.display, window.config, EGL_NO_CONTEXT, attributes.data());
            if (report.cleanupSafe && independent != EGL_NO_CONTEXT && egl.eglMakeCurrent(window.display, probeSurface, probeSurface, independent)) {
                gl.getInt(arrayBinding, &binding);
                report.independentObjects = !gl.isBuffer(objects[0]) && binding == 0 && gl.getError() == 0
                    ? FeatureEvidence::Verified : FeatureEvidence::Unsupported;
            }
            report.auxiliary = FeatureEvidence::Verified;
        } else { report.auxiliary = FeatureEvidence::Unsupported; report.sharedObjects = FeatureEvidence::Unsupported; }
    }
    // 无论探针结果如何都还原调用者的context和绑定。还原失败时对象域归属不明，不删
    // buffer、不抛弃句柄并要求进程退出；绝不能让游戏继续使用被探针换走的current状态。
    if (!egl.eglMakeCurrent(window.display, previousDraw, previousReadSurface, window.context)) report.cleanupSafe = false;
    if (report.cleanupSafe) {
        gl.bind(arrayBuffer, static_cast<unsigned>(previousArray));
        if (copyBindingsReadable) { gl.bind(copyRead, static_cast<unsigned>(previousRead)); gl.bind(copyWrite, static_cast<unsigned>(previousWrite)); }
        gl.remove(2, objects);
        objects[0] = objects[1] = 0;
        if (shared != EGL_NO_CONTEXT) { if (egl.eglDestroyContext(window.display, shared)) shared = EGL_NO_CONTEXT; else report.cleanupSafe = false; }
        if (report.cleanupSafe && independent != EGL_NO_CONTEXT) { if (egl.eglDestroyContext(window.display, independent)) independent = EGL_NO_CONTEXT; else report.cleanupSafe = false; }
        if (report.cleanupSafe && probeSurface != EGL_NO_SURFACE) { if (egl.eglDestroySurface(window.display, probeSurface)) probeSurface = EGL_NO_SURFACE; else report.cleanupSafe = false; }
    }
    // 这些临时句柄只在整个进程退出时才可强收。保留诊断身份，不在当前会话重试或terminate display。
    if (!report.cleanupSafe) {
        report.reason = "functional-probe-retirement-requires-restart";
        report.retainedSharedContext = shared; report.retainedIndependentContext = independent; report.retainedSurface = probeSurface;
        report.retainedBuffers[0] = objects[0]; report.retainedBuffers[1] = objects[1];
    }
    else {
        (void)egl.eglGetError(); (void)gl.getError();
        report.reason = !sourceValid ? "buffer-source-readback-unverified" : !copyBindingsReadable ?
            "copy-binding-query-unavailable" : "functional-probe-complete";
    }
    report.elapsedNs = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count());
    return report.cleanupSafe;
}
bool GraphicsAuxiliaryVerified(const GraphicsRuntimeBinding& runtime, bool shared) {
    if (runtime.delegate) return runtime.delegate->auxiliaryVerified && runtime.delegate->auxiliaryVerified(shared ? 1 : 0) == 1;
    if (!runtime.features) return false;
    auto& f = *runtime.features; std::lock_guard<std::mutex> lock(f.mutex);
    return f.cleanupSafe && f.auxiliary == FeatureEvidence::Verified && f.contextIsolation == FeatureEvidence::Verified &&
        f.independentObjects == FeatureEvidence::Verified && (!shared || f.sharedObjects == FeatureEvidence::Verified);
}
bool GraphicsCleanupSafe(const GraphicsRuntimeBinding& runtime) {
    if (runtime.delegate) return runtime.delegate->cleanupSafe && runtime.delegate->cleanupSafe() == 1;
    return runtime.features && runtime.features->cleanupSafe.load(std::memory_order_acquire);
}
uint64_t ReserveGraphicsContext(const GraphicsRuntimeBinding& runtime, void* shared) {
    if (runtime.delegate) return runtime.delegate->reserveContext ? runtime.delegate->reserveContext(shared) : 0;
    if (!runtime.features || !runtime.egl.ready) return 0;
    auto& state = *runtime.features;
    std::lock_guard<std::recursive_mutex> lock(state.resourcesMutex);
    if (!state.cleanupSafe || state.nextContextPermit == UINT64_MAX) return 0;
    if (shared) {
        bool known = false;
        for (const auto& entry : state.contextPermits) if (entry.second == shared) known = true;
        if (!known) return 0;
    }
    if (!state.contextPermits.empty() && !GraphicsAuxiliaryVerified(runtime, shared != nullptr)) return 0;
    const uint64_t permit = ++state.nextContextPermit;
    state.contextPermits.emplace(permit, nullptr);
    return permit;
}
bool CommitGraphicsContext(const GraphicsRuntimeBinding& runtime, uint64_t permit, void* context) {
    if (runtime.delegate) return runtime.delegate->commitContext && runtime.delegate->commitContext(permit, context) == 1;
    if (!runtime.features || !permit || !context) return false;
    auto& state = *runtime.features;
    std::lock_guard<std::recursive_mutex> lock(state.resourcesMutex);
    const auto found = state.contextPermits.find(permit);
    if (found == state.contextPermits.end() || (found->second && found->second != context)) return false;
    for (const auto& entry : state.contextPermits) if (entry.first != permit && entry.second == context) return false;
    found->second = context; return true;
}
bool RetireGraphicsContext(const GraphicsRuntimeBinding& runtime, void* context) {
    if (runtime.delegate) return runtime.delegate->retireContext && runtime.delegate->retireContext(context) == 1;
    if (!context) return true;
    if (!runtime.features) return false;
    auto& state = *runtime.features;
    std::lock_guard<std::recursive_mutex> lock(state.resourcesMutex);
    for (auto entry = state.contextPermits.begin(); entry != state.contextPermits.end(); ++entry) {
        if (entry->second == context) { state.contextPermits.erase(entry); return true; }
    }
    return false;
}
void ReleaseGraphicsContextPermit(const GraphicsRuntimeBinding& runtime, uint64_t permit) {
    if (!runtime.features || !permit) return;
    std::lock_guard<std::recursive_mutex> lock(runtime.features->resourcesMutex);
    runtime.features->contextPermits.erase(permit);
}
std::string GraphicsFeaturesJson(const GraphicsRuntimeBinding& runtime) {
    if (runtime.delegate) {
        const char* value = runtime.delegate->featuresJson ? runtime.delegate->featuresJson() : nullptr;
        return value ? value : "null";
    }
    if (!runtime.features) return "null";
    auto& f = *runtime.features; std::lock_guard<std::mutex> lock(f.mutex);
    std::ostringstream out;
    out << "{\"schemaVersion\":1,\"profile\":" << quote(runtime.profile->id) << ",\"implementation\":" << quote(runtime.implementationIdentity)
        << ",\"vendor\":" << quote(f.vendor) << ",\"renderer\":" << quote(f.renderer) << ",\"version\":" << quote(f.version)
        << ",\"bufferCopyReadback\":\"" << evidence(f.bufferCopy) << "\",\"fenceSync\":\"" << evidence(f.fence)
        << "\",\"auxiliaryPbuffer\":\"" << evidence(f.auxiliary) << "\",\"sharedBufferObjects\":\"" << evidence(f.sharedObjects)
        << "\",\"contextStateIsolation\":\"" << evidence(f.contextIsolation) << "\",\"independentObjectIsolation\":\"" << evidence(f.independentObjects)
        << "\",\"persistentMapping\":\"not-run\",\"timerQuery\":\"not-run\",\"performance\":null,\"probeElapsedNs\":" << f.elapsedNs
        << ",\"cleanupSafe\":" << (f.cleanupSafe ? "true" : "false") << ",\"reason\":" << quote(f.reason) << '}';
    return out.str();
}
}
