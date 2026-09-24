#include "glfw_internal.h"
#include "../platform/native_gl.h"
#include "../platform/system_egl.h"
#include "../platform/desktop_egl_core.h"
#include <unistd.h>

bool InitEGL(GLFWwindow* win) {
    if (!win || !amcl::desktop::SystemEgl().ready) return false;
    const amcl::desktop::ContextRequest request{g_hintMajor,g_hintMinor,g_hintProfile,g_hintForwardCompatible};
    std::string error;
    const bool ok = amcl::desktop::CreateDesktopEgl(amcl::desktop::SystemEgl(),*win,
        request,amcl::desktop::NativeGlProc,static_cast<int>(gettid()),error);
    if (!ok && g_errorCallback) {
        // Use the existing GLFW error channel; no extra native log producer.
        error = "Desktop EGL: " + error;
        g_errorCallback(GLFW_PLATFORM_ERROR,error.c_str());
    }
    return ok;
}

bool TerminateEGL(GLFWwindow* win) {
    return !win || amcl::desktop::DestroyDesktopEgl(amcl::desktop::SystemEgl(),*win,static_cast<int>(gettid()));
}

bool SuspendEGLSurface(GLFWwindow* win) {
    return !win || amcl::desktop::SuspendDesktopEglSurface(amcl::desktop::SystemEgl(),*win,
        static_cast<int>(gettid()));
}

bool AttachEGLSurface(GLFWwindow* win, void* nativeWindow, int width, int height) {
    return win && amcl::desktop::AttachDesktopEglSurface(amcl::desktop::SystemEgl(),*win,
        nativeWindow,width,height,static_cast<int>(gettid()));
}
