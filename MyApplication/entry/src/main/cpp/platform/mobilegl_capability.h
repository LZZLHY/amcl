#pragma once

#include "graphics_capability.h"
#include "../glfw/amcl_native_window_lease_broker_abi.h"
#include <functional>
#include <string>
#include <vector>

namespace amcl::graphics {

// Only C handles cross the MobileGL DSO boundary. These signatures are the EGL
// and desktop GL functions used by the production admission experiment.
struct MobileGlProbeFunctions {
    void* (*getDisplay)(void*) = nullptr;
    unsigned (*initialize)(void*, int*, int*) = nullptr;
    unsigned (*chooseConfig)(void*, const int*, void**, int, int*) = nullptr;
    void* (*createPbuffer)(void*, void*, const int*) = nullptr;
    void* (*createWindow)(void*, void*, uintptr_t, const int*) = nullptr;
    void* (*createContext)(void*, void*, void*, const int*) = nullptr;
    unsigned (*makeCurrent)(void*, void*, void*, void*) = nullptr;
    unsigned (*swapBuffers)(void*, void*) = nullptr;
    uint64_t (*presentSequence)() = nullptr; // 同线程实际上屏证据，不能用EGL_TRUE代替。
    unsigned (*destroyContext)(void*, void*) = nullptr;
    unsigned (*destroySurface)(void*, void*) = nullptr;
    unsigned (*terminate)(void*) = nullptr;
    void* (*getProcAddress)(const char*) = nullptr;
    const unsigned char* (*getString)(unsigned) = nullptr;
    unsigned (*getError)() = nullptr;
    unsigned (*createShader)(unsigned) = nullptr;
    void (*shaderSource)(unsigned, int, const char* const*, const int*) = nullptr;
    void (*compileShader)(unsigned) = nullptr;
    void (*getShaderiv)(unsigned, unsigned, int*) = nullptr;
    void (*deleteShader)(unsigned) = nullptr;
    unsigned (*createProgram)() = nullptr;
    void (*attachShader)(unsigned, unsigned) = nullptr;
    void (*linkProgram)(unsigned) = nullptr;
    void (*getProgramiv)(unsigned, unsigned, int*) = nullptr;
    void (*useProgram)(unsigned) = nullptr;
    void (*deleteProgram)(unsigned) = nullptr;
    void (*genVertexArrays)(int, unsigned*) = nullptr;
    void (*bindVertexArray)(unsigned) = nullptr;
    void (*deleteVertexArrays)(int, const unsigned*) = nullptr;
    void (*genTextures)(int, unsigned*) = nullptr;
    void (*bindTexture)(unsigned, unsigned) = nullptr;
    void (*texImage2D)(unsigned, int, int, int, int, int, unsigned, unsigned, const void*) = nullptr;
    void (*deleteTextures)(int, const unsigned*) = nullptr;
    void (*genFramebuffers)(int, unsigned*) = nullptr;
    void (*bindFramebuffer)(unsigned, unsigned) = nullptr;
    void (*framebufferTexture2D)(unsigned, unsigned, unsigned, unsigned, int) = nullptr;
    unsigned (*checkFramebufferStatus)(unsigned) = nullptr;
    void (*deleteFramebuffers)(int, const unsigned*) = nullptr;
    void (*viewport)(int, int, int, int) = nullptr;
    void (*drawArrays)(unsigned, int, int) = nullptr;
    void (*readPixels)(int, int, int, int, unsigned, unsigned, void*) = nullptr;
    void (*clearColor)(float, float, float, float) = nullptr;
    void (*clear)(unsigned) = nullptr;
};

struct MobileGlProbeWindow {
    void* pointer = nullptr;
    int width = 0;
    int height = 0;
    uint64_t generation = 0;
    const AmclNativeWindowLeaseBrokerV2* broker = nullptr;
};

class MobileGlProbeHost {
public:
    virtual ~MobileGlProbeHost() = default;
    virtual bool acquire(MobileGlProbeWindow&, std::string& error) = 0;
    virtual bool load(MobileGlProbeFunctions&, std::string& error) = 0;
    virtual GraphicsCapability queryDevice(const std::string& observedRenderer) = 0;
    virtual void requireRestart(const std::string& reason) = 0;
};

struct MobileGlProbeReport {
    GraphicsCapability capability;
    uint64_t successfulPresents = 0;
    uint64_t presentCounter = 0;
    unsigned shaderCompilations = 0;
    unsigned programLinks = 0;
    unsigned pixelVerifications = 0;
    bool cleanupComplete = false;
    bool runtimeChecksPassed = false;
    std::vector<std::string> stages;
    bool admitted() const;
    std::string text() const;
};

// Tests inject this exact function table and broker; the same executor runs on
// device. No report string is interpreted as capability evidence.
MobileGlProbeReport RunMobileGlCapabilityProbe(MobileGlProbeHost& host,
    const std::string& nativeLibraryDir, int processId, const std::string& windowProvider = "SDL3",
    const std::string& requirementId = "mobilegl-direct-vulkan-v1");
size_t MobileGlCapabilityQuarantinedCount();
using MobileGlDeviceAudit = std::function<GraphicsCapability(const std::string& observedRenderer)>;
MobileGlProbeReport ProbeMobileGlCapability(const std::string& nativeLibraryDir,
    const MobileGlDeviceAudit& deviceAudit, const std::string& windowProvider = "SDL3",
    const std::string& requirementId = "mobilegl-direct-vulkan-v1");
std::string MobileGlCapabilityDiagnosticReport();

} // namespace amcl::graphics
