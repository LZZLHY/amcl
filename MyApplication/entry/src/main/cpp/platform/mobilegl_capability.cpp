#include "mobilegl_capability.h"

#include <atomic>
#include <cstring>
#include <memory>
#include <sstream>

namespace amcl::graphics {
namespace {
constexpr int kNone = 0x3038;
constexpr unsigned kFramebuffer = 0x8D40;
constexpr unsigned kTexture2D = 0x0DE1;
constexpr unsigned kRgba = 0x1908;
constexpr unsigned kUnsignedByte = 0x1401;
std::atomic<uint64_t> presented{0};

bool functionsComplete(const MobileGlProbeFunctions& f) {
    return f.getDisplay && f.initialize && f.chooseConfig && f.createPbuffer && f.createWindow &&
        f.createContext && f.makeCurrent && f.swapBuffers && f.presentSequence && f.destroyContext && f.destroySurface &&
        f.terminate && f.getProcAddress && f.getString && f.getError && f.createShader && f.shaderSource && f.compileShader &&
        f.getShaderiv && f.deleteShader && f.createProgram && f.attachShader && f.linkProgram &&
        f.getProgramiv && f.useProgram && f.deleteProgram && f.genVertexArrays && f.bindVertexArray &&
        f.deleteVertexArrays && f.genTextures && f.bindTexture && f.texImage2D && f.deleteTextures &&
        f.genFramebuffers && f.bindFramebuffer && f.framebufferTexture2D && f.checkFramebufferStatus &&
        f.deleteFramebuffers && f.viewport && f.drawArrays && f.readPixels && f.clearColor && f.clear;
}

struct ProbeResources {
    MobileGlProbeFunctions functions;
    MobileGlProbeWindow window;
    uint64_t presentationToken = 0;
    void* display = nullptr;
    void* config = nullptr;
    void* pbuffer = nullptr;
    void* surface = nullptr;
    void* context = nullptr;
    unsigned vertexShader = 0;
    unsigned fragmentShader = 0;
    unsigned program = 0;
    unsigned vertexArray = 0;
    unsigned texture = 0;
    unsigned framebuffer = 0;
    bool providerEntered = false;
    bool retirementFailed = false;

    bool generationCurrent() const {
        return window.broker && window.broker->peekGeneration &&
            window.broker->peekGeneration() == window.generation;
    }

    void deleteGpuObjects() {
        auto& f = functions;
        if (program) { f.useProgram(0); f.deleteProgram(program); program = 0; }
        if (vertexShader) { f.deleteShader(vertexShader); vertexShader = 0; }
        if (fragmentShader) { f.deleteShader(fragmentShader); fragmentShader = 0; }
        if (vertexArray) { f.deleteVertexArrays(1, &vertexArray); vertexArray = 0; }
        if (framebuffer) { f.bindFramebuffer(kFramebuffer, 0); f.deleteFramebuffers(1, &framebuffer); framebuffer = 0; }
        if (texture) { f.deleteTextures(1, &texture); texture = 0; }
    }

    bool retire(std::string& error) {
        auto& f = functions;
        if (retirementFailed) {
            error = "mobilegl_surface_retirement_uncertain";
            return false;
        }
        try {
            // Delete GL objects only while their context is current. Context
            // destruction also retires objects when an earlier bind failed.
            if (context && (vertexShader || fragmentShader || program || vertexArray || texture || framebuffer)) {
                void* target = pbuffer ? pbuffer : surface;
                if (!target || !f.makeCurrent(display, target, target, context)) {
                    error = "mobilegl_cleanup_rebind_failed";
                    return false;
                }
                deleteGpuObjects();
            }
            if (context) {
                if (!f.makeCurrent(display, nullptr, nullptr, nullptr)) {
                    error = "mobilegl_cleanup_unbind_failed";
                    return false;
                }
                if (!f.destroyContext(display, context)) {
                    error = "mobilegl_cleanup_context_failed";
                    return false;
                }
                context = nullptr;
            }
            if (surface) {
                if (!f.destroySurface(display, surface)) {
                    error = "mobilegl_cleanup_window_surface_failed";
                    return false;
                }
                surface = nullptr;
            }
            if (pbuffer) {
                if (!f.destroySurface(display, pbuffer)) {
                    error = "mobilegl_cleanup_pbuffer_failed";
                    return false;
                }
                pbuffer = nullptr;
            }
            if (providerEntered) {
                if (!display || !f.terminate(display)) {
                    error = "mobilegl_cleanup_display_failed";
                    return false;
                }
                display = nullptr;
                providerEntered = false;
            }
            if (presentationToken) {
                if (window.broker->releasePresentation(presentationToken) != 1) {
                    error = "mobilegl_cleanup_presentation_token_failed";
                    return false;
                }
                presentationToken = 0;
            }
            if (window.pointer) {
                if (!window.broker || window.broker->abiVersion != AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION ||
                    window.broker->structSize < AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_CORE_SIZE || !window.broker->release) {
                    error = "mobilegl_cleanup_lease_broker_missing";
                    return false;
                }
                window.broker->release(window.pointer);
                window.pointer = nullptr;
            }
            return true;
        } catch (...) {
            error = "mobilegl_cleanup_provider_exception";
            return false;
        }
    }
};

// Keep the complete cleanup state and DSO function table until process exit if
// teardown is uncertain. Never release a window beneath a live driver surface.
std::vector<std::unique_ptr<ProbeResources>>& quarantine() {
    static auto* resources = new std::vector<std::unique_ptr<ProbeResources>>();
    return *resources;
}

bool reject(MobileGlProbeReport& report, const char* reason) {
    report.capability.reasonCode = reason;
    report.stages.emplace_back(reason);
    return false;
}

bool verifyPixel(ProbeResources& resources, MobileGlProbeReport& report) {
    auto& f = resources.functions;
    f.bindFramebuffer(kFramebuffer, resources.framebuffer);
    unsigned char pixel[4] = {};
    f.readPixels(0, 0, 1, 1, kRgba, kUnsignedByte, pixel);
    f.bindFramebuffer(kFramebuffer, 0);
    if (f.getError() != 0 || pixel[0] < 63 || pixel[0] > 65 || pixel[1] < 127 || pixel[1] > 129 ||
        pixel[2] < 190 || pixel[2] > 192 || pixel[3] != 255) return reject(report, "mobilegl_shader_pixel_mismatch");
    ++report.pixelVerifications;
    return true;
}

bool compileAndDraw(ProbeResources& resources, MobileGlProbeReport& report) {
    auto& f = resources.functions;
    static constexpr char vertexSource[] =
        "#version 330 core\n"
        "const vec2 p[3] = vec2[3](vec2(-1,-1),vec2(3,-1),vec2(-1,3));\n"
        "void main(){ gl_Position=vec4(p[gl_VertexID],0,1); }\n";
    static constexpr char fragmentSource[] =
        "#version 330 core\nout vec4 color;\n"
        "void main(){ color=vec4(0.25,0.5,0.75,1.0); }\n";
    const char* sources[] = {vertexSource, fragmentSource};
    unsigned* shaderSlots[] = {&resources.vertexShader, &resources.fragmentShader};
    const unsigned shaderTypes[] = {0x8B31, 0x8B30};
    for (unsigned index = 0; index < 2; ++index) {
        *shaderSlots[index] = f.createShader(shaderTypes[index]);
        if (!*shaderSlots[index]) return reject(report, "mobilegl_shader_create_failed");
        f.shaderSource(*shaderSlots[index], 1, &sources[index], nullptr);
        f.compileShader(*shaderSlots[index]);
        int compiled = 0;
        f.getShaderiv(*shaderSlots[index], 0x8B81, &compiled);
        if (!compiled) return reject(report, "mobilegl_shader_compile_failed");
        ++report.shaderCompilations;
    }
    resources.program = f.createProgram();
    if (!resources.program) return reject(report, "mobilegl_program_create_failed");
    f.attachShader(resources.program, resources.vertexShader);
    f.attachShader(resources.program, resources.fragmentShader);
    f.linkProgram(resources.program);
    int linked = 0;
    f.getProgramiv(resources.program, 0x8B82, &linked);
    if (!linked) return reject(report, "mobilegl_program_link_failed");
    ++report.programLinks;
    f.genTextures(1, &resources.texture);
    f.genFramebuffers(1, &resources.framebuffer);
    f.genVertexArrays(1, &resources.vertexArray);
    if (!resources.texture || !resources.framebuffer || !resources.vertexArray) return reject(report, "mobilegl_gpu_object_create_failed");
    f.bindTexture(kTexture2D, resources.texture);
    f.texImage2D(kTexture2D, 0, 0x8058, 4, 4, 0, kRgba, kUnsignedByte, nullptr);
    f.bindFramebuffer(kFramebuffer, resources.framebuffer);
    f.framebufferTexture2D(kFramebuffer, 0x8CE0, kTexture2D, resources.texture, 0);
    if (f.checkFramebufferStatus(kFramebuffer) != 0x8CD5) return reject(report, "mobilegl_framebuffer_incomplete");
    f.bindVertexArray(resources.vertexArray);
    f.useProgram(resources.program);
    f.viewport(0, 0, 4, 4);
    f.drawArrays(0x0004, 0, 3);
    if (!verifyPixel(resources, report)) return false;
    f.useProgram(0);
    f.bindVertexArray(0);
    report.capability.shaderToolchain = CapabilityEvidence::Yes;
    report.stages.emplace_back("mobilegl_shader_compile_link_draw_readback_verified");
    return true;
}

bool present(ProbeResources& resources, MobileGlProbeReport& report) {
    if (!resources.generationCurrent()) {
        report.capability.windowSurface = CapabilityEvidence::Unknown;
        report.capability.queuePresentation = CapabilityEvidence::Unknown;
        return reject(report, "mobilegl_window_generation_changed");
    }
    auto& f = resources.functions;
    f.bindFramebuffer(kFramebuffer, 0);
    f.viewport(0, 0, resources.window.width, resources.window.height);
    f.clearColor(0.1f, 0.3f, 0.5f, 1.0f);
    f.clear(0x00004000);
    const uint64_t before = f.presentSequence();
    if (f.getError() != 0 || !f.swapBuffers(resources.display, resources.surface)) {
        report.capability.queuePresentation = CapabilityEvidence::No;
        return reject(report, "mobilegl_present_failed");
    }
    if (f.presentSequence() <= before) {
        report.capability.queuePresentation = CapabilityEvidence::No;
        return reject(report, "mobilegl_present_deferred_without_submission");
    }
    ++report.successfulPresents;
    report.presentCounter = presented.fetch_add(1, std::memory_order_relaxed) + 1;
    report.capability.queuePresentation = CapabilityEvidence::Yes;
    report.stages.emplace_back("mobilegl_present_success_" + std::to_string(report.presentCounter));
    return true;
}

bool execute(MobileGlProbeHost& host, ProbeResources& resources, MobileGlProbeReport& report) {
    auto& result = report.capability;
    auto& f = resources.functions;
    std::string error;
    if (!host.acquire(resources.window, error)) return reject(report, error.empty() ? "native_window_not_ready" : error.c_str());
    const auto* broker = resources.window.broker;
    if (!resources.window.pointer || !broker || broker->abiVersion != AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION ||
        broker->structSize < AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PRESENTATION_SIZE ||
        !broker->release || !broker->claimPresentation || !broker->releasePresentation || !broker->peekGeneration) {
        return reject(report, "mobilegl_window_broker_incomplete");
    }
    if (resources.window.width <= 0 || resources.window.height <= 0 || resources.window.generation == 0) {
        return reject(report, "mobilegl_window_geometry_invalid");
    }
    if (broker->claimPresentation(resources.window.pointer, resources.window.generation, 1, &resources.presentationToken) != 1) {
        return reject(report, "mobilegl_presentation_owner_busy");
    }
    result.nativeWindowGeneration = resources.window.generation;
    if (!host.load(f, error) || !functionsComplete(f)) {
        result.nativeArtifacts = CapabilityEvidence::No;
        return reject(report, error.empty() ? "mobilegl_provider_entrypoint_missing" : error.c_str());
    }
    result.nativeArtifacts = CapabilityEvidence::Yes;
    resources.providerEntered = true;
    resources.display = f.getDisplay(nullptr);
    if (!resources.display) return reject(report, "mobilegl_display_create_failed");
    int major = 0;
    int minor = 0;
    if (!f.initialize(resources.display, &major, &minor)) return reject(report, "mobilegl_display_initialize_failed");
    // MobileGL's eglGetProcAddress itself initializes its globals. Invoke it
    // only after the resource guard owns a display that can be terminated.
    if (f.getProcAddress("glGetString") != reinterpret_cast<void*>(f.getString) ||
        f.getProcAddress("glGetError") != reinterpret_cast<void*>(f.getError) ||
        f.getProcAddress("glCompileShader") != reinterpret_cast<void*>(f.compileShader) ||
        f.getProcAddress("glLinkProgram") != reinterpret_cast<void*>(f.linkProgram) ||
        f.getProcAddress("glDrawArrays") != reinterpret_cast<void*>(f.drawArrays)) {
        result.nativeArtifacts = CapabilityEvidence::No;
        return reject(report, "mobilegl_provider_proc_split");
    }
    const int configAttributes[] = {0x3033, 0x0005, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, kNone};
    int count = 0;
    if (!f.chooseConfig(resources.display, configAttributes, &resources.config, 1, &count) || !resources.config || count < 1) {
        return reject(report, "mobilegl_config_unavailable");
    }
    const int pbufferAttributes[] = {0x3057, 16, 0x3056, 16, kNone};
    resources.pbuffer = f.createPbuffer(resources.display, resources.config, pbufferAttributes);
    if (!resources.pbuffer) return reject(report, "mobilegl_pbuffer_create_failed");
    resources.context = f.createContext(resources.display, resources.config, nullptr, nullptr);
    if (!resources.context) return reject(report, "mobilegl_context_create_failed");
    if (!f.makeCurrent(resources.display, resources.pbuffer, resources.pbuffer, resources.context)) {
        return reject(report, "mobilegl_pbuffer_make_current_failed");
    }
    const auto* versionBytes = f.getString(0x1F02);
    const std::string version = versionBytes ? reinterpret_cast<const char*>(versionBytes) : "";
    const auto* rendererBytes = f.getString(0x1F01);
    const std::string renderer = rendererBytes ? reinterpret_cast<const char*>(rendererBytes) : "";
    result.observedProvider = renderer;
    if (version.find("MobileGL") == std::string::npos || version.find("Vulkan") == std::string::npos || renderer.empty()) {
        result.nativeArtifacts = CapabilityEvidence::No;
        return reject(report, "mobilegl_direct_vulkan_identity_mismatch");
    }
    const GraphicsCapability facts = host.queryDevice(renderer);
    result.loader = facts.loader;
    result.instance = facts.instance;
    result.physicalDevice = facts.physicalDevice;
    result.deviceExtensions = facts.deviceExtensions;
    result.featureBits = facts.featureBits;
    result.apiVersion = facts.apiVersion;
    result.driverIdentity = facts.driverIdentity;
    if (result.loader != CapabilityEvidence::Yes || result.instance != CapabilityEvidence::Yes ||
        result.physicalDevice != CapabilityEvidence::Yes || result.deviceExtensions != CapabilityEvidence::Yes ||
        result.featureBits != CapabilityEvidence::Yes) {
        return reject(report, facts.reasonCode.empty() ? "mobilegl_device_requirement_not_met" : facts.reasonCode.c_str());
    }
    result.shaderToolchain = CapabilityEvidence::No;
    if (!compileAndDraw(resources, report)) return false;
    const int surfaceAttributes[] = {0x3057, resources.window.width, 0x3056, resources.window.height, kNone};
    for (unsigned round = 0; round < 2; ++round) {
        if (!resources.generationCurrent()) {
            result.windowSurface = CapabilityEvidence::Unknown;
            return reject(report, "mobilegl_window_generation_changed");
        }
        resources.surface = f.createWindow(resources.display, resources.config,
            reinterpret_cast<uintptr_t>(resources.window.pointer), surfaceAttributes);
        if (!resources.surface || !f.makeCurrent(resources.display, resources.surface, resources.surface, resources.context)) {
            result.windowSurface = CapabilityEvidence::No;
            return reject(report, "mobilegl_window_surface_create_or_bind_failed");
        }
        result.windowSurface = CapabilityEvidence::Yes;
        if (!verifyPixel(resources, report)) return false;
        if (!present(resources, report) || (round == 0 && !present(resources, report))) return false;
        if (!f.makeCurrent(resources.display, resources.pbuffer, resources.pbuffer, resources.context)) {
            return reject(report, "mobilegl_window_to_pbuffer_failed");
        }
        if (!verifyPixel(resources, report)) return false;
        if (!f.destroySurface(resources.display, resources.surface)) {
            resources.retirementFailed = true;
            return reject(report, "mobilegl_round_surface_retirement_failed");
        }
        resources.surface = nullptr;
    }
    if (!resources.generationCurrent()) {
        result.windowSurface = CapabilityEvidence::Unknown;
        result.queuePresentation = CapabilityEvidence::Unknown;
        return reject(report, "mobilegl_window_generation_changed");
    }
    result.reasonCode = "mobilegl_launch_prerequisites_verified";
    return true;
}
} // namespace

bool MobileGlProbeReport::admitted() const {
    const auto& c = capability;
    return runtimeChecksPassed && cleanupComplete && c.loader == CapabilityEvidence::Yes && c.instance == CapabilityEvidence::Yes &&
        c.physicalDevice == CapabilityEvidence::Yes && c.deviceExtensions == CapabilityEvidence::Yes &&
        c.featureBits == CapabilityEvidence::Yes && c.windowSurface == CapabilityEvidence::Yes &&
        c.queuePresentation == CapabilityEvidence::Yes && c.shaderToolchain == CapabilityEvidence::Yes &&
        c.nativeArtifacts == CapabilityEvidence::Yes && successfulPresents > 0 && pixelVerifications > 0;
}

std::string MobileGlProbeReport::text() const {
    std::ostringstream output;
    output << "AMCL_MOBILEGL_CAPABILITY_V1\nprofile=mobilegl game_api=OPENGL internal_transport=VULKAN\n";
    for (const auto& stage : stages) output << stage << '\n';
    output << "shader_compilations=" << shaderCompilations << " program_links=" << programLinks
        << " pixel_verifications=" << pixelVerifications << " successful_presents=" << successfulPresents
        << " present_counter=" << presentCounter << " cleanup_complete=" << cleanupComplete << '\n';
    output << "admission=" << (admitted() ? "PASS" : "FAIL") << " reason=" << capability.reasonCode << '\n';
    output << "lifecycle_smoke=NOT_RUN (rotation/background/input/Minecraft are separate checks)\n";
    return output.str();
}

MobileGlProbeReport RunMobileGlCapabilityProbe(MobileGlProbeHost& host,
    const std::string& nativeLibraryDir, int processId, const std::string& windowProvider,
    const std::string& requirementId) {
    MobileGlProbeReport report;
    report.capability.profileId = "mobilegl";
    // 调用边界先验证 requirement/provider 组合，再将实际请求身份原样保留到结果。
    report.capability.requirementId = requirementId;
    report.capability.windowProvider = windowProvider;
    report.capability.nativeLibraryDir = nativeLibraryDir;
    report.capability.processId = processId;
    auto resources = std::make_unique<ProbeResources>();
    bool unknownProviderResources = false;
    try {
        report.runtimeChecksPassed = execute(host, *resources, report);
    } catch (...) {
        reject(report, "mobilegl_provider_exception");
        unknownProviderResources = resources->providerEntered;
    }
    if (!report.runtimeChecksPassed && report.capability.windowSurface == CapabilityEvidence::Yes) {
        report.capability.windowSurface = CapabilityEvidence::Unknown;
    }
    std::string cleanupError;
    if (unknownProviderResources) cleanupError = "mobilegl_provider_exception_cleanup_unknown";
    report.cleanupComplete = !unknownProviderResources && resources->retire(cleanupError);
    if (!report.cleanupComplete) {
        report.capability.queuePresentation = CapabilityEvidence::Unknown;
        report.capability.windowSurface = CapabilityEvidence::Unknown;
        report.capability.reasonCode = cleanupError;
        report.stages.push_back(cleanupError);
        host.requireRestart(cleanupError);
        quarantine().push_back(std::move(resources));
    }
    return report;
}

size_t MobileGlCapabilityQuarantinedCount() { return quarantine().size(); }
} // namespace amcl::graphics
