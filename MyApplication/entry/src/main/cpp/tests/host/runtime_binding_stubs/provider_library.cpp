// 双映像运行时实验的系统边界：提供有签名的最小EGL库，生命周期算法继续执行生产代码。
// 不模拟真实GPU能力；缺少buffer入口使功能探针保持未测，不能把本fixture当设备支持。
#define EGL_NO_PLATFORM_SPECIFIC_TYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <cstdint>
#include <cstring>
#include <map>
#include <array>
#include <atomic>
#include <mutex>

namespace {
std::atomic<uintptr_t> next{100};
std::mutex mutex;
std::map<EGLSurface, std::array<int, 2>> surfaces;
thread_local EGLContext current = EGL_NO_CONTEXT;
thread_local EGLSurface draw = EGL_NO_SURFACE;
EGLDisplay display() { return reinterpret_cast<EGLDisplay>(1); }
EGLSurface surface(int width, int height) {
    const auto value = reinterpret_cast<EGLSurface>(++next);
    std::lock_guard<std::mutex> lock(mutex); surfaces[value] = {width, height}; return value;
}
}
extern "C" const unsigned char* glGetString(unsigned) { return reinterpret_cast<const unsigned char*>("4.3 MobileGL Vulkan fixture"); }
extern "C" void glGetIntegerv(unsigned, int* value) { *value = 1; }
extern "C" uint64_t mobileglGetPresentedSequenceV1() { return 0; }
extern "C" EGLDisplay eglGetDisplay(EGLNativeDisplayType) { return display(); }
extern "C" EGLBoolean eglInitialize(EGLDisplay, EGLint*, EGLint*) { return EGL_TRUE; }
extern "C" EGLBoolean eglBindAPI(EGLenum) { return EGL_TRUE; }
extern "C" EGLenum eglQueryAPI() { return EGL_OPENGL_API; }
extern "C" EGLBoolean eglChooseConfig(EGLDisplay, const EGLint*, EGLConfig* config, EGLint, EGLint* count) {
    *config = reinterpret_cast<EGLConfig>(2); *count = 1; return EGL_TRUE;
}
extern "C" EGLBoolean eglGetConfigAttrib(EGLDisplay, EGLConfig, EGLint key, EGLint* value) {
    *value = key == EGL_SURFACE_TYPE ? EGL_WINDOW_BIT | EGL_PBUFFER_BIT : EGL_OPENGL_BIT; return EGL_TRUE;
}
extern "C" EGLContext eglCreateContext(EGLDisplay, EGLConfig, EGLContext, const EGLint*) { return reinterpret_cast<EGLContext>(++next); }
extern "C" EGLSurface eglCreateWindowSurface(EGLDisplay, EGLConfig, EGLNativeWindowType, const EGLint*) { return surface(640, 480); }
extern "C" EGLSurface eglCreatePbufferSurface(EGLDisplay, EGLConfig, const EGLint* attributes) {
    int width = 1, height = 1;
    for (int i = 0; attributes && attributes[i] != EGL_NONE; i += 2) {
        if (attributes[i] == EGL_WIDTH) width = attributes[i + 1];
        if (attributes[i] == EGL_HEIGHT) height = attributes[i + 1];
    }
    return surface(width, height);
}
extern "C" EGLBoolean eglDestroySurface(EGLDisplay, EGLSurface value) {
    std::lock_guard<std::mutex> lock(mutex); return surfaces.erase(value) ? EGL_TRUE : EGL_FALSE;
}
extern "C" EGLBoolean eglDestroyContext(EGLDisplay, EGLContext) { return EGL_TRUE; }
extern "C" EGLBoolean eglMakeCurrent(EGLDisplay, EGLSurface value, EGLSurface, EGLContext context) { draw = value; current = context; return EGL_TRUE; }
extern "C" EGLContext eglGetCurrentContext() { return current; }
extern "C" EGLDisplay eglGetCurrentDisplay() { return display(); }
extern "C" EGLSurface eglGetCurrentSurface(EGLint) { return draw; }
extern "C" EGLBoolean eglSwapBuffers(EGLDisplay, EGLSurface) { return EGL_TRUE; }
extern "C" EGLBoolean eglSwapInterval(EGLDisplay, EGLint) { return EGL_TRUE; }
extern "C" EGLBoolean eglQuerySurface(EGLDisplay, EGLSurface value, EGLint key, EGLint* result) {
    std::lock_guard<std::mutex> lock(mutex);
    const auto found = surfaces.find(value); if (found == surfaces.end()) return EGL_FALSE;
    *result = found->second[key == EGL_WIDTH ? 0 : 1]; return EGL_TRUE;
}
extern "C" const char* eglQueryString(EGLDisplay, EGLint) { return ""; }
extern "C" EGLint eglGetError() { return EGL_SUCCESS; }
extern "C" EGLBoolean eglTerminate(EGLDisplay) { return EGL_TRUE; }
extern "C" __eglMustCastToProperFunctionPointerType eglGetProcAddress(const char* name) {
    if (!std::strcmp(name, "glGetString")) return reinterpret_cast<__eglMustCastToProperFunctionPointerType>(&glGetString);
    if (!std::strcmp(name, "glGetIntegerv")) return reinterpret_cast<__eglMustCastToProperFunctionPointerType>(&glGetIntegerv);
    return nullptr;
}
