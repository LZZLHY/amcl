#include "mobilegl_capability.h"
#include "graphics_probe_gate.h"
#include "../glfw/glfw_compat.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <hilog/log.h>

namespace amcl::graphics {
namespace {
void* providerLibrary = nullptr;
void* providerImage = nullptr;
int providerProcessId = 0;
// PID与忙资格一次取得；不能在另一个线程进入后再清busy。
GraphicsProbeGate probeGate;

bool presentArtifact(const std::string& directory, const char* library) {
    struct stat info{};
    const std::string path = directory + "/" + library;
    return !directory.empty() && stat(path.c_str(), &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0;
}

class NativeProbeHost final : public MobileGlProbeHost {
public:
    NativeProbeHost(std::string directory, MobileGlDeviceAudit audit, std::string provider)
        : directory_(std::move(directory)), deviceAudit_(std::move(audit)), windowProvider_(std::move(provider)) {}

    bool acquire(MobileGlProbeWindow& window, std::string& error) override {
        if (providerLibrary && providerProcessId != static_cast<int>(getpid())) {
            error = "mobilegl_inherited_provider_requires_process_restart";
            requireRestart(error);
            return false;
        }
        const char* restart = std::getenv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART");
        if (restart && std::strcmp(restart, "0") != 0) {
            error = "mobilegl_process_restart_required";
            return false;
        }
        void* pointer = nullptr;
        void* broker = nullptr;
        int width = 0;
        int height = 0;
        uint64_t generation = 0;
        if (glfwOHOS_AcquireNativeWindowSnapshot(nullptr, 0, nullptr, &pointer,
                &width, &height, &generation, &broker) != 1) {
            error = "native_window_not_ready";
            return false;
        }
        window.pointer = pointer;
        window.width = width;
        window.height = height;
        window.generation = generation;
        window.broker = static_cast<const AmclNativeWindowLeaseBrokerV2*>(broker);
        return true;
    }

    bool load(MobileGlProbeFunctions& functions, std::string& error) override {
        for (const char* name : {"libmobilegl.so", windowProvider_ == "SDL3" ? "libSDL3.so" : "libglfw.so", "liblwjgl.so"}) {
            if (!presentArtifact(directory_, name)) {
                error = std::string("mobilegl_native_artifact_missing:") + name;
                return false;
            }
        }
        const int currentPid = static_cast<int>(getpid());
        if (providerLibrary && providerProcessId != currentPid) {
            error = "mobilegl_inherited_provider_requires_process_restart";
            requireRestart(error);
            return false;
        }
        setenv("MOBILEGL_BACKEND_TYPE", "DirectVulkan", 1);
        if (!providerLibrary) {
            providerLibrary = dlopen((directory_ + "/libmobilegl.so").c_str(), RTLD_NOW | RTLD_LOCAL);
            providerProcessId = currentPid;
        }
        if (!providerLibrary) {
            error = "mobilegl_provider_load_failed";
            return false;
        }
        Dl_info identity{};
        if (!dladdr(dlsym(providerLibrary, "eglGetDisplay"), &identity) || !identity.dli_fbase) {
            error = "mobilegl_provider_identity_unavailable";
            return false;
        }
        providerImage = identity.dli_fbase;
        auto resolve = [&](const char* symbol) -> void* {
            void* address = dlsym(providerLibrary, symbol);
            Dl_info owner{};
            if (!address || !dladdr(address, &owner) || owner.dli_fbase != providerImage) {
                error = std::string("mobilegl_provider_symbol_unavailable_or_foreign:") + symbol;
                return nullptr;
            }
            return address;
        };
#define LOAD(member, symbol) \
        functions.member = reinterpret_cast<decltype(functions.member)>(resolve(#symbol)); \
        if (!functions.member) return false
        LOAD(getDisplay, eglGetDisplay);
        LOAD(initialize, eglInitialize);
        LOAD(chooseConfig, eglChooseConfig);
        LOAD(createPbuffer, eglCreatePbufferSurface);
        LOAD(createWindow, eglCreateWindowSurface);
        LOAD(createContext, eglCreateContext);
        LOAD(makeCurrent, eglMakeCurrent);
        LOAD(swapBuffers, eglSwapBuffers);
        LOAD(presentSequence, mobileglGetPresentedSequenceV1);
        LOAD(destroyContext, eglDestroyContext);
        LOAD(destroySurface, eglDestroySurface);
        LOAD(terminate, eglTerminate);
        LOAD(getProcAddress, eglGetProcAddress);
        LOAD(getString, glGetString);
        LOAD(getError, glGetError);
        LOAD(createShader, glCreateShader);
        LOAD(shaderSource, glShaderSource);
        LOAD(compileShader, glCompileShader);
        LOAD(getShaderiv, glGetShaderiv);
        LOAD(deleteShader, glDeleteShader);
        LOAD(createProgram, glCreateProgram);
        LOAD(attachShader, glAttachShader);
        LOAD(linkProgram, glLinkProgram);
        LOAD(getProgramiv, glGetProgramiv);
        LOAD(useProgram, glUseProgram);
        LOAD(deleteProgram, glDeleteProgram);
        LOAD(genVertexArrays, glGenVertexArrays);
        LOAD(bindVertexArray, glBindVertexArray);
        LOAD(deleteVertexArrays, glDeleteVertexArrays);
        LOAD(genTextures, glGenTextures);
        LOAD(bindTexture, glBindTexture);
        LOAD(texImage2D, glTexImage2D);
        LOAD(deleteTextures, glDeleteTextures);
        LOAD(genFramebuffers, glGenFramebuffers);
        LOAD(bindFramebuffer, glBindFramebuffer);
        LOAD(framebufferTexture2D, glFramebufferTexture2D);
        LOAD(checkFramebufferStatus, glCheckFramebufferStatus);
        LOAD(deleteFramebuffers, glDeleteFramebuffers);
        LOAD(viewport, glViewport);
        LOAD(drawArrays, glDrawArrays);
        LOAD(readPixels, glReadPixels);
        LOAD(clearColor, glClearColor);
        LOAD(clear, glClear);
#undef LOAD
        return true;
    }

    GraphicsCapability queryDevice(const std::string& renderer) override {
        return deviceAudit_ ? deviceAudit_(renderer) : GraphicsCapability{};
    }

    void requireRestart(const std::string& reason) override {
        setenv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART", "1", 1);
        OH_LOG_ERROR(LOG_APP, "MobileGL capability cleanup requires restart: %{public}s", reason.c_str());
    }
private:
    std::string directory_;
    MobileGlDeviceAudit deviceAudit_;
    std::string windowProvider_;
};
} // namespace

MobileGlProbeReport ProbeMobileGlCapability(const std::string& nativeLibraryDir,
    const MobileGlDeviceAudit& deviceAudit, const std::string& windowProvider,
    const std::string& requirementId) {
    const int currentPid = static_cast<int>(getpid());
    GraphicsProbeGate::Lease lease(probeGate, static_cast<uint32_t>(currentPid));
    if (!lease.entered()) {
        MobileGlProbeReport report;
        report.capability.profileId = "mobilegl";
        report.capability.requirementId = requirementId;
        report.capability.windowProvider = windowProvider;
        report.capability.nativeLibraryDir = nativeLibraryDir;
        report.capability.processId = currentPid;
        report.capability.reasonCode = "mobilegl_probe_busy";
        return report;
    }
    NativeProbeHost host(nativeLibraryDir, deviceAudit, windowProvider);
    MobileGlProbeReport report = RunMobileGlCapabilityProbe(host, nativeLibraryDir, currentPid, windowProvider, requirementId);
    OH_LOG_INFO(LOG_APP, "MobileGL admission=%{public}d presents=%{public}llu shader_compilations=%{public}u cleanup=%{public}d reason=%{public}s",
        report.admitted() ? 1 : 0, static_cast<unsigned long long>(report.presentCounter),
        report.shaderCompilations, report.cleanupComplete ? 1 : 0, report.capability.reasonCode.c_str());
    return report;
}
} // namespace amcl::graphics
