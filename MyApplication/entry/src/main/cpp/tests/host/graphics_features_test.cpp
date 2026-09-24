// 生产功能探针的系统边界故障实验；GL对象/上下文模拟只供确定性反例，不能代表真实GPU支持。
#include "../../platform/graphics_features.cpp"
#include "host_test_check.h"
#include <map>
#include <memory>
#include <iostream>
namespace fixture {
using Objects = std::map<unsigned, std::vector<unsigned char>>;
struct Context { std::shared_ptr<Objects> objects = std::make_shared<Objects>(); unsigned array = 0, read = 0, write = 0; };
std::map<uintptr_t, Context> contexts;
uintptr_t current = 1, next = 2;
unsigned nextBuffer = 10, generated = 0, surfaces = 0;
EGLSurface surface = reinterpret_cast<EGLSurface>(10);
std::string fault;
const amcl::graphics::GraphicsRuntimeBinding* activeRuntime = nullptr;
unsigned pendingError = 0;
Context& binding() { return contexts.at(fault == "global-state" ? 1 : current); }
unsigned& target(unsigned t) { return t == 0x8892 ? binding().array : t == 0x8f36 ? binding().read : binding().write; }
const unsigned char* getString(unsigned name) { return reinterpret_cast<const unsigned char*>(name == 0x1f02 ? (fault == "gl2" ? "2.1 fixture" : "4.3 MobileGL DirectVulkan") : "fixture"); }
void getInt(unsigned name, int* out) {
    if (name == 0x821e || name == 0x9126) { *out = 1; return; }
    if (fault == "copy-query-unavailable" && name != 0x8894) { pendingError = 0x500; return; }
    *out = target(name == 0x8894 ? 0x8892 : name);
}
unsigned getError() { const auto value = pendingError; pendingError = 0; return value; }
void gen(int n, unsigned* out) { generated += n; while (n--) *out++ = nextBuffer++; }
void bind(unsigned t, unsigned value) { target(t) = value; if (value) (*contexts[current].objects)[value]; }
void data(unsigned t, intptr_t bytes, const void* source, unsigned) {
    auto& destination = (*contexts[current].objects)[target(t)]; destination.resize(bytes);
    if (source) std::memcpy(destination.data(), source, bytes);
}
void copy(unsigned read, unsigned write, intptr_t, intptr_t, intptr_t) {
    auto& objects = *contexts[current].objects; objects[target(write)] = objects[target(read)];
    if (fault == "bad-copy") objects[target(write)][0] ^= 1;
}
void* map(unsigned t, intptr_t, intptr_t, unsigned) {
    auto& bytes = (*contexts[current].objects)[target(t)]; return bytes.empty() ? nullptr : bytes.data();
}
unsigned char unmap(unsigned) { return 1; }
void remove(int n, const unsigned* ids) { while (n--) contexts[current].objects->erase(*ids++); }
unsigned char isBuffer(unsigned id) { return contexts[current].objects->count(id) != 0; }
void* fence(unsigned, unsigned) { return reinterpret_cast<void*>(123); }
unsigned wait(void*, unsigned, uint64_t) { return fault == "timeout" ? 0x911b : 0x911a; }
void deleteSync(void*) {}
EGLContext getContext() { return reinterpret_cast<EGLContext>(current); }
EGLDisplay getDisplay() { return reinterpret_cast<EGLDisplay>(1); }
EGLSurface getSurface(EGLint) { return surface; }
EGLSurface createPbuffer(EGLDisplay, EGLConfig, const EGLint*) { ++surfaces; return reinterpret_cast<EGLSurface>(20); }
EGLContext createContext(EGLDisplay, EGLConfig, EGLContext share, const EGLint*) {
    auto id = next++; contexts[id] = {};
    if ((share && fault != "unshared") || fault == "leak-independent")
        contexts[id].objects = contexts[share ? reinterpret_cast<uintptr_t>(share) : 1].objects;
    return reinterpret_cast<EGLContext>(id);
}
EGLBoolean makeCurrent(EGLDisplay, EGLSurface draw, EGLSurface, EGLContext context) {
    if (fault == "restore-failed" && current != 1 && reinterpret_cast<uintptr_t>(context) == 1) return EGL_FALSE;
    current = reinterpret_cast<uintptr_t>(context); surface = draw; return EGL_TRUE;
}
EGLBoolean destroyContext(EGLDisplay, EGLContext context) {
    if (fault == "destroy-failed") return EGL_FALSE;
    contexts.erase(reinterpret_cast<uintptr_t>(context)); return EGL_TRUE;
}
EGLBoolean destroySurface(EGLDisplay, EGLSurface) { --surfaces; return EGL_TRUE; }
EGLint eglError() { return EGL_SUCCESS; }
void* resolve(const char* name) {
#define ENTRY(label, function) if (!std::strcmp(name, label)) return reinterpret_cast<void*>(&function)
    ENTRY("glGetIntegerv", getInt); ENTRY("glGetString", getString); ENTRY("glGetError", getError);
    ENTRY("glGenBuffers", gen); ENTRY("glBindBuffer", bind); ENTRY("glBufferData", data);
    ENTRY("glCopyBufferSubData", copy); ENTRY("glMapBufferRange", map); ENTRY("glUnmapBuffer", unmap);
    ENTRY("glDeleteBuffers", remove); ENTRY("glIsBuffer", isBuffer); ENTRY("glFenceSync", fence);
    ENTRY("glClientWaitSync", wait); ENTRY("glDeleteSync", deleteSync);
#undef ENTRY
    return nullptr;
}
}
namespace amcl::graphics {
void* GraphicsRuntimeBinding::glProc(const char* name) const { return fixture::resolve(name); }
const GraphicsRuntimeBinding* BoundGraphicsRuntime() { return fixture::activeRuntime; }
}
int main() {
    using namespace amcl::graphics;
    for (const char* fault : {"", "bad-copy", "global-state", "unshared", "leak-independent", "timeout", "restore-failed", "destroy-failed", "gl2", "copy-query-unavailable"}) {
        fixture::fault = fault; fixture::contexts.clear(); fixture::contexts[1] = {};
        fixture::current = 1; fixture::next = 2; fixture::nextBuffer = 10; fixture::generated = 0; fixture::surfaces = 0;
        fixture::surface = reinterpret_cast<EGLSurface>(10);
        fixture::contexts[1].array = 7; fixture::contexts[1].read = 8; fixture::contexts[1].write = 9;
        GraphicsRuntimeBinding runtime; runtime.features = std::make_unique<GraphicsFeatureState>();
        auto& features = *runtime.features;
        fixture::activeRuntime = &runtime; fixture::pendingError = 0;
        runtime.profile = FindGraphicsProfile("mobilegl");
        runtime.egl.ready = true; runtime.egl.eglGetCurrentContext = fixture::getContext;
        runtime.egl.eglGetCurrentDisplay = fixture::getDisplay; runtime.egl.eglGetCurrentSurface = fixture::getSurface;
        runtime.egl.eglCreatePbufferSurface = fixture::createPbuffer; runtime.egl.eglCreateContext = fixture::createContext;
        runtime.egl.eglMakeCurrent = fixture::makeCurrent; runtime.egl.eglDestroyContext = fixture::destroyContext;
        runtime.egl.eglDestroySurface = fixture::destroySurface; runtime.egl.eglGetError = fixture::eglError;
        EglContextState window; window.display = reinterpret_cast<EGLDisplay>(1); window.context = reinterpret_cast<EGLContext>(1);
        window.config = reinterpret_cast<EGLConfig>(1); window.actualContextMajor = 4; window.actualContextMinor = 3; window.actualContextProfile = 0x00032001;
        const bool failedCleanup = fixture::fault == "restore-failed" || fixture::fault == "destroy-failed";
        CHECK(ProbeGraphicsFeatures(runtime, window) == !failedCleanup);
        CHECK(ProbeGraphicsFeatures(runtime, window) == !failedCleanup);
        if (failedCleanup) { CHECK(!GraphicsAuxiliaryVerified(runtime, true)); CHECK(features.retainedSurface); continue; }
        CHECK(fixture::current == 1 && fixture::contexts.size() == 1 && !fixture::surfaces);
        CHECK(fixture::contexts[1].array == 7 && fixture::contexts[1].read == 8 && fixture::contexts[1].write == 9);
        if (fixture::fault == "gl2") { CHECK(!fixture::generated && features.bufferCopy == FeatureEvidence::NotRun); continue; }
        CHECK(features.bufferCopy == (fixture::fault == "bad-copy" ? FeatureEvidence::Unsupported :
            fixture::fault == "copy-query-unavailable" ? FeatureEvidence::Unknown : FeatureEvidence::Verified));
        CHECK(features.fence == (fixture::fault == "timeout" ? FeatureEvidence::Unknown : FeatureEvidence::Verified));
        CHECK(GraphicsAuxiliaryVerified(runtime, true) == (fixture::fault.empty() || fixture::fault == "bad-copy" ||
            fixture::fault == "timeout" || fixture::fault == "copy-query-unavailable"));
        CHECK(GraphicsFeaturesJson(runtime).find("\"performance\":null") != std::string::npos);
    }
    std::cout << "Graphics functional probes PASS: actual production executor, readback faults, per-context/nonshare isolation, bounded fence, restore/retirement retention\n";
    return 0;
}
