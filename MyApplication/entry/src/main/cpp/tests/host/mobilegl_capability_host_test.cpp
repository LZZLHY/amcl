#include "../../platform/mobilegl_capability.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

using namespace amcl::graphics;
namespace {
int failures = 0;
void check(bool condition, const char* message) {
    if (!condition) { std::cerr << "FAIL " << message << '\n'; ++failures; }
}
struct State {
    std::string fault;
    int references = 0;
    int releaseCalls = 0;
    int token = 0;
    int displays = 0;
    int contexts = 0;
    int surfaces = 0;
    int pbufferBinds = 0;
    int loaded = 0;
    int queries = 0;
    unsigned names = 10;
    uint64_t generation = 7;
    uint64_t presentSequence = 0;
    bool restart = false;
    bool terminated = false;
    bool current = false;
    std::vector<std::string> events;
} state;
bool is(const char* name) { return state.fault == name; }
void event(const char* value) { state.events.emplace_back(value); }
void* pointer(uintptr_t value) { return reinterpret_cast<void*>(value); }

void release(void*) {
    check(state.displays == 0 && state.contexts == 0 && state.surfaces == 0, "lease released while driver resources are live");
    --state.references; ++state.releaseCalls; event("lease-release");
}
int claim(void*, uint64_t generation, uint32_t api, uint64_t* token) {
    check(api == 1, "MobileGL transport must not claim the Minecraft Vulkan API token");
    if (is("owner-busy")) return 0;
    check(generation == state.generation, "claim generation");
    *token = 9; state.token = 1; event("claim"); return 1;
}
int releaseToken(uint64_t token) {
    check(token == 9, "token identity");
    check(state.displays == 0 && state.contexts == 0 && state.surfaces == 0 && !state.current,
        "presentation token released before driver teardown");
    if (is("token-release")) return 0;
    state.token = 0; event("token-release"); return 1;
}
uint64_t generation() { return state.generation; }
AmclNativeWindowLeaseBrokerV2 broker = {
    AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION, sizeof(AmclNativeWindowLeaseBrokerV2),
    nullptr, release, nullptr, nullptr, generation, nullptr, claim, nullptr, releaseToken
};
void* display(void*) { event("display"); if (is("display")) return nullptr; ++state.displays; return pointer(1); }
unsigned initialize(void*, int* major, int* minor) { *major = 1; *minor = 5; event("initialize"); return !is("initialize"); }
unsigned config(void*, const int*, void** out, int, int* count) { *out = pointer(2); *count = 1; return !is("config"); }
void* pbuffer(void*, void*, const int*) { if (is("pbuffer")) return nullptr; ++state.surfaces; return pointer(3); }
void* surface(void*, void*, uintptr_t, const int*) {
    if (is("window")) return nullptr;
    if (is("generation")) state.generation = 8;
    ++state.surfaces; return pointer(4);
}
void* context(void*, void*, void*, const int*) {
    if (is("provider-exception")) throw std::runtime_error("injected provider failure");
    if (is("context")) return nullptr;
    ++state.contexts; return pointer(5);
}
unsigned makeCurrent(void*, void* draw, void*, void* ctx) {
    if (!ctx) { event("unbind"); if (is("unbind")) return 0; state.current = false; return 1; }
    if (draw == pointer(3)) ++state.pbufferBinds;
    if (is("current") || (is("current-window") && draw == pointer(4)) ||
        (is("switch-pbuffer") && draw == pointer(3) && state.pbufferBinds > 1)) return 0;
    state.current = true; return 1;
}
unsigned swap(void*, void*) {
    event("swap");
    if (!is("swap") && !is("deferred-present")) ++state.presentSequence;
    return !is("swap");
}
uint64_t presentSequence() { return state.presentSequence; }
unsigned destroyContext(void*, void*) {
    event("destroy-context"); if (is("destroy-context")) return 0; --state.contexts; return 1;
}
unsigned destroySurface(void*, void*) {
    event("destroy-surface"); if (is("destroy-surface")) return 0; --state.surfaces; return 1;
}
unsigned terminate(void*) {
    event("terminate"); if (is("terminate")) return 0;
    check(!state.current, "terminate while current");
    state.displays = 0; state.contexts = 0; state.surfaces = 0; state.terminated = true; return 1;
}
const unsigned char* getString(unsigned key) {
    const char* value = key == 0x1F02 ? (is("identity") ? "System GLES" : "4.3 MobileGL, Direct (Vulkan) Backend")
        : "Magma (MobileGL) (MockGPU, Vulkan 1.1.0)";
    return reinterpret_cast<const unsigned char*>(value);
}
unsigned glError() { return is("draw") ? 0x0502u : 0u; }
unsigned createShader(unsigned) { return is("shader-create") ? 0u : ++state.names; }
void shaderSource(unsigned, int, const char* const*, const int*) {}
void compileShader(unsigned) {}
void shaderStatus(unsigned, unsigned, int* status) { *status = !is("shader-compile"); }
void deleteOne(unsigned) {}
unsigned createProgram() { return is("program-create") ? 0u : ++state.names; }
void attach(unsigned, unsigned) {}
void linkProgram(unsigned) {}
void programStatus(unsigned, unsigned, int* status) { *status = !is("program-link"); }
void gen(int, unsigned* name) { *name = is("gpu-object") ? 0u : ++state.names; }
void bind(unsigned, unsigned) {}
void deleteObjects(int, const unsigned*) {}
void image(unsigned, int, int, int, int, int, unsigned, unsigned, const void*) {}
void attachment(unsigned, unsigned, unsigned, unsigned, int) {}
unsigned framebufferStatus(unsigned) { return is("framebuffer") ? 0u : 0x8CD5u; }
void viewport(int, int, int, int) {}
void draw(unsigned, int, int) {}
void read(int, int, int, int, unsigned, unsigned, void* output) {
    const unsigned char good[] = {64, 128, 191, 255};
    const unsigned char bad[] = {0, 0, 0, 255};
    std::memcpy(output, is("pixel") ? bad : good, 4);
}
void color(float, float, float, float) {}
void* getProc(const char* name) {
    if (is("proc-split")) return nullptr;
    if (std::strcmp(name, "glGetString") == 0) return reinterpret_cast<void*>(getString);
    if (std::strcmp(name, "glGetError") == 0) return reinterpret_cast<void*>(glError);
    if (std::strcmp(name, "glCompileShader") == 0) return reinterpret_cast<void*>(compileShader);
    if (std::strcmp(name, "glLinkProgram") == 0) return reinterpret_cast<void*>(linkProgram);
    if (std::strcmp(name, "glDrawArrays") == 0) return reinterpret_cast<void*>(draw);
    return nullptr;
}

class Host final : public MobileGlProbeHost {
public:
    bool acquire(MobileGlProbeWindow& value, std::string&) override {
        if (is("no-window")) return false;
        ++state.references;
        value.pointer = pointer(100); value.width = 800; value.height = 600;
        value.generation = 7; value.broker = &broker;
        return true;
    }
    bool load(MobileGlProbeFunctions& f, std::string&) override {
        ++state.loaded;
        if (is("load")) return false;
        f.getDisplay = display; f.initialize = initialize; f.chooseConfig = config;
        f.createPbuffer = pbuffer; f.createWindow = surface; f.createContext = context;
        f.makeCurrent = makeCurrent; f.swapBuffers = swap; f.presentSequence = presentSequence; f.destroyContext = destroyContext;
        f.destroySurface = destroySurface; f.terminate = terminate; f.getProcAddress = getProc;
        f.getString = getString; f.getError = glError;
        f.createShader = createShader; f.shaderSource = shaderSource; f.compileShader = compileShader;
        f.getShaderiv = shaderStatus; f.deleteShader = deleteOne; f.createProgram = createProgram;
        f.attachShader = attach; f.linkProgram = linkProgram; f.getProgramiv = programStatus;
        f.useProgram = deleteOne; f.deleteProgram = deleteOne; f.genVertexArrays = gen;
        f.bindVertexArray = deleteOne; f.deleteVertexArrays = deleteObjects;
        f.genTextures = gen; f.bindTexture = bind; f.texImage2D = image; f.deleteTextures = deleteObjects;
        f.genFramebuffers = gen; f.bindFramebuffer = bind; f.framebufferTexture2D = attachment;
        f.checkFramebufferStatus = framebufferStatus; f.deleteFramebuffers = deleteObjects;
        f.viewport = viewport; f.drawArrays = draw; f.readPixels = read; f.clearColor = color; f.clear = deleteOne;
        if (is("symbol")) f.compileShader = nullptr;
        return true;
    }
    GraphicsCapability queryDevice(const std::string& renderer) override {
        check(renderer.find("MockGPU") != std::string::npos, "device audit receives actual GL provider renderer");
        ++state.queries;
        GraphicsCapability facts;
        facts.loader = facts.instance = facts.physicalDevice = facts.deviceExtensions = facts.featureBits = CapabilityEvidence::Yes;
        facts.apiVersion = "1.1.0";
        if (is("device")) facts.deviceExtensions = CapabilityEvidence::No;
        return facts;
    }
    void requireRestart(const std::string&) override { state.restart = true; }
};

void runCase(const char* fault, const char* provider = "SDL3") {
    state = State{};
    state.fault = fault;
    Host host;
    const size_t quarantinedBefore = MobileGlCapabilityQuarantinedCount();
    const auto result = RunMobileGlCapabilityProbe(host, "/app/libs/arm64", 21, provider);
    check(result.admitted() == is("none"), fault);
    check(result.capability.profileId == "mobilegl" && result.capability.requirementId == "mobilegl-direct-vulkan-v1" &&
        result.capability.windowProvider == provider, "capability remains scoped to the requested MobileGL window provider");
    check(result.capability.lifecycleSmoke == CapabilityEvidence::NotRun, "probe does not fabricate background/rotation lifecycle evidence");
    const bool mustRetain = is("display") || is("switch-pbuffer") || is("unbind") || is("destroy-context") ||
        is("destroy-surface") || is("terminate") || is("token-release") || is("provider-exception");
    if (mustRetain) {
        check(state.references == 1 && state.token == 1 && state.releaseCalls == 0 && state.restart, "unsafe cleanup retains both owners and requires restart");
        check(MobileGlCapabilityQuarantinedCount() == quarantinedBefore + 1, "quarantine keeps complete cleanup state");
        check(!result.cleanupComplete, "uncertain teardown cannot report complete");
    } else {
        check(state.references == 0 && state.token == 0 && !state.restart && result.cleanupComplete, "safe cleanup returns both owners");
    }
    if (is("none")) {
        check(result.successfulPresents == 3 && result.shaderCompilations == 2 && result.programLinks == 1 && result.pixelVerifications == 5,
            "success requires both shader stages, linked draw, preserved GPU contents and repeated presents");
        check(state.events.size() >= 3 && state.events[state.events.size() - 3] == "terminate" &&
            state.events[state.events.size() - 2] == "token-release" && state.events.back() == "lease-release", "resource-token-reference release order");
    }
    if (is("no-window") || is("owner-busy")) check(state.loaded == 0 && state.queries == 0, "busy or missing window cannot initialize a provider");
    if (is("device")) check(result.shaderCompilations == 0 && result.capability.shaderToolchain == CapabilityEvidence::NotRun, "device rejection keeps unrun shader evidence");
    if (is("shader-compile") || is("program-link") || is("pixel")) check(result.capability.shaderToolchain == CapabilityEvidence::No, "failed shader pipeline cannot become YES");
    if (is("generation")) check(result.capability.windowSurface == CapabilityEvidence::Unknown, "stale window is not admitted");
}
} // namespace

int main(int argc, char** argv) {
    const char* faults[] = {"none", "no-window", "owner-busy", "load", "symbol", "display", "initialize", "config", "pbuffer",
        "context", "current", "identity", "proc-split", "device", "shader-create", "shader-compile", "program-create", "program-link",
        "gpu-object", "framebuffer", "draw", "pixel", "window", "current-window", "swap", "deferred-present", "switch-pbuffer", "destroy-surface",
        "unbind", "destroy-context", "terminate", "token-release", "generation", "provider-exception"};
    if (argc == 2) {
        const char* fault = argv[1];
        if (std::strcmp(fault, "choose") == 0) fault = "config";
        else if (std::strcmp(fault, "surface") == 0) fault = "window";
        else if (std::strcmp(fault, "gl-error") == 0) fault = "draw";
        else if (std::strcmp(fault, "exception") == 0) fault = "provider-exception";
        else if (std::strcmp(fault, "provider-split") == 0) fault = "proc-split";
        runCase(fault);
    }
    else for (const char* provider : {"SDL3", "GLFW"}) for (const char* fault : faults) runCase(fault, provider);
    if (failures == 0) std::cout << "mobilegl_capability_host_test: PASS\n";
    return failures == 0 ? 0 : 1;
}
