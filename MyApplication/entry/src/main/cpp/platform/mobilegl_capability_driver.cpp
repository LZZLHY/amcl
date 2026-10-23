#include "mobilegl_capability.h"
#include "env_slot.h"
#include "graphics_probe_gate.h"
#include "../glfw/glfw_compat.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <mutex>
#include <hilog/log.h>

namespace amcl::graphics {
namespace {
void* providerLibrary = nullptr;
void* providerImage = nullptr;
int providerProcessId = 0;
// 生产准入与冷诊断共用发布点；串行化首次缺值的check/write，避免两个
// 冷调用同时setenv相同键，释放另一个读者刚取得的字符串。
std::mutex backendPublicationMutex;
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
        // MobileGL 在首次 EGL 调用时读一次并闭锁后端类型。值恒为 DirectVulkan：已是该值就不再
        // setenv（I27-05：重复 setenv 会释放并发 getenv 读者持有的旧串）。产品流程里首次写入发生在
        // 启动准入（mc_launcher，建 JVM 之前）的完整探针中。登记表已封存说明本进程已认领 JVM、
        // 可能已有游戏/JVM 线程：此时拒绝本次探针而不是新增或改写名字。
        if (!PublishMobileGlDirectVulkanBeforeLoad(error)) return false;
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

    // 进程级重启标记经已登记槽位原位置 '1'，不 setenv（I27-05）；登记表不可用时状态码进日志。
    void requireRestart(const std::string& reason) override {
        const int status = amcl::envslot::RequestRendererRestart();
        OH_LOG_ERROR(LOG_APP, "MobileGL capability cleanup requires restart: %{public}s marker=%{public}d",
                     reason.c_str(), status);
    }
private:
    std::string directory_;
    MobileGlDeviceAudit deviceAudit_;
    std::string windowProvider_;
};
} // namespace

bool PublishMobileGlDirectVulkanBeforeLoad(std::string& error) {
    std::lock_guard<std::mutex> publication(backendPublicationMutex);
    const char* backendType = std::getenv("MOBILEGL_BACKEND_TYPE");
    // 不重复释放getenv读者可能持有的字符串；已封存但值相同也是纯读取。
    if (backendType && std::strcmp(backendType, "DirectVulkan") == 0) return true;
    if (amcl::envslot::ProcessRegistry().Sealed()) {
        error = "mobilegl_backend_type_unpublished_after_runtime_start";
        return false;
    }
    // 此模块的生产静态引用说明后端可能已闭锁。错误值不能在装入之后改写，
    // 不能把环境里的新文字当作库已切换；调用者应退休/重启原进程。
    if (providerLibrary) {
        error = "mobilegl_backend_type_already_loaded_requires_restart";
        return false;
    }
    if (setenv("MOBILEGL_BACKEND_TYPE", "DirectVulkan", 1) != 0) {
        error = "mobilegl_backend_type_publish_failed";
        return false;
    }
    return true;
}

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
