// 独立 Linux EGL 宿主。每次启动只有一个 provider/context：Mesa 桌面GL参考用于
// 校准规范oracle，MG模式必须解析指定真实库的全部GL和EGL入口，不允许系统补齐。
#include "depth_range_scene.h"
#include <EGL/egl.h>
#include <MG/init.h>
#include <dlfcn.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <limits.h>

namespace {
using amcl::graphics_semantics::ShaderDialect;
struct Provider {
    void* library = nullptr;
    bool production = false;
    std::string control;
    std::string canonicalLibrary;
    void (*enable)(unsigned) = nullptr;
    void (*getDouble)(unsigned, double*) = nullptr;
    void (*shaderSource)(unsigned, int, const char* const*, const int*) = nullptr;
    std::ofstream identities;
};
Provider* calibration = nullptr;

// 真实映像文件路径必须和--library指向同一实际DSO，不能只因为两个符号来自
// facade的某个依赖就把facade摘要登记成MG生产载荷。
std::string Canonical(const char* path) {
    std::array<char, PATH_MAX> resolved{};
    if (!path || !realpath(path, resolved.data())) throw std::runtime_error("cannot canonicalize DSO identity");
    return resolved.data();
}

// 所有证据文件在返回PASS前都必须flush/close成功；std::ofstream默认不会抛出
// 磁盘写满等错误，因此明确检查状态。异常由main整形成环境失败exitCode=2。
void CloseEvidence(std::ofstream& stream) {
    stream.flush();
    if (!stream) throw std::runtime_error("evidence flush failed");
    stream.close();
    if (!stream) throw std::runtime_error("evidence close failed");
}

// 负控只改变当前测试进程的局部resolver返回值，不改系统或MG函数表。它们的
// 结果只证明oracle能识别空入口、关闭深度测试和短查询，不能冒充MG旧版本证据。
void EmptyDouble(double, double) {}
void DisabledDepth(unsigned capability) { if (capability != 0x0B71) calibration->enable(capability); }
void ShortDoubleQuery(unsigned pname, double* values) {
    if (pname == 0x0B70) { double both[2]{}; calibration->getDouble(pname, both); values[0] = both[0]; }
    else calibration->getDouble(pname, values);
}

// 独立oracle控制只移除声明初值，仍让真实Mesa编译/link/draw/query；manual setter
// 保持，因此须只失败在link默认query/像素。它不是旧MG制品的实际生产反例。
void StripInitializer(unsigned shader, int count, const char* const* sources, const int* lengths) {
    std::string body;
    for (int i = 0; i < count; ++i) body.append(sources[i], lengths && lengths[i] >= 0 ?
        static_cast<std::size_t>(lengths[i]) : std::strlen(sources[i]));
    const std::string declaration = "tint=vec4(0.25,0.5,0.75,1.0)";
    const auto begin = body.find(declaration);
    if (begin != std::string::npos) body.replace(begin, declaration.size(), "tint");
    const char* changed = body.c_str();
    calibration->shaderSource(shader, 1, &changed, nullptr);
}

// Mesa GLVND允许eglGetProcAddress提供dispatch入口；生产库必须自身导出，失败
// 即fail-closed。dladdr记录实际映像和符号，避免系统同名函数给MG制造假阳性。
void* Resolve(void* user, const char* name) {
    auto& provider = *static_cast<Provider*>(user);
    void* address = dlsym(provider.library, name);
    if (!address && !provider.production)
        address = reinterpret_cast<void*>(eglGetProcAddress(name));
    Dl_info info{};
    const bool identified = address && dladdr(address, &info) && info.dli_fname;
    const bool sameImage = !provider.production || (identified &&
        reinterpret_cast<void*>(dlsym(provider.library, "mg_initialize_v1")) &&
        [&] { Dl_info owner{}; dladdr(dlsym(provider.library, "mg_initialize_v1"), &owner);
              return owner.dli_fbase == info.dli_fbase &&
                     Canonical(owner.dli_fname) == provider.canonicalLibrary; }());
    provider.identities << name << '\t' << address << '\t'
                        << (identified ? info.dli_fname : "UNKNOWN") << '\t'
                        << (identified && info.dli_sname ? info.dli_sname : "DISPATCH") << '\n';
    provider.identities.flush();
    if (!provider.identities) throw std::runtime_error("function identity write failed");
    if (!identified || !sameImage) return nullptr;
    if (provider.control == "double-stub" && std::strcmp(name, "glDepthRange") == 0)
        return reinterpret_cast<void*>(&EmptyDouble);
    if (provider.control == "depth-disabled" && std::strcmp(name, "glEnable") == 0) {
        provider.enable = reinterpret_cast<decltype(provider.enable)>(address);
        return reinterpret_cast<void*>(&DisabledDepth);
    }
    if (provider.control == "short-double-query" && std::strcmp(name, "glGetDoublev") == 0) {
        provider.getDouble = reinterpret_cast<decltype(provider.getDouble)>(address);
        return reinterpret_cast<void*>(&ShortDoubleQuery);
    }
    if (provider.control == "initializer-stripped" && std::strcmp(name, "glShaderSource") == 0) {
        provider.shaderSource = reinterpret_cast<decltype(provider.shaderSource)>(address);
        return reinterpret_cast<void*>(&StripInitializer);
    }
    return address;
}

// EGL操作也按同一个provider选择；MG context的登记必须经过MG EGL包装，不能
// 先用系统EGL建context后把它伪装成MG合法context。
template<class T> T EglFunction(Provider& provider, const char* name, T systemFunction) {
    if (!provider.production) return systemFunction;
    void* address = dlsym(provider.library, name);
    if (!address) throw std::runtime_error(std::string("missing production EGL entry: ") + name);
    Dl_info info{}, owner{};
    if (!dladdr(address, &info) || !dladdr(dlsym(provider.library, "mg_initialize_v1"), &owner) ||
        info.dli_fbase != owner.dli_fbase || Canonical(owner.dli_fname) != provider.canonicalLibrary)
        throw std::runtime_error(std::string("foreign EGL entry: ") + name);
    provider.identities << name << '\t' << address << '\t' << info.dli_fname << '\n';
    provider.identities.flush();
    if (!provider.identities) throw std::runtime_error("EGL identity write failed");
    return reinterpret_cast<T>(address);
}

// 由宿主配置建立合法pbuffer，销毁由同一函数所有权表执行。资源阶段失败会
// 返回2，语义错误返回1，完整通过返回0，便于宿主区分负控检出和环境故障。
int Run(int argc, char** argv) {
    if (argc < 2) throw std::runtime_error("usage: host-runner OUTPUT [--library DSO] [--control NAME]");
    const std::string output = argv[1];
    Provider provider;
    bool initializer = false;
    std::string libraryName = "libGL.so.1";
    for (int i = 2; i < argc; ++i) {
        if (std::strcmp(argv[i], "--library") == 0 && i + 1 < argc) {
            provider.production = true; libraryName = argv[++i];
        } else if (std::strcmp(argv[i], "--control") == 0 && i + 1 < argc) provider.control = argv[++i];
        else if (std::strcmp(argv[i], "--scene") == 0 && i + 1 < argc && std::strcmp(argv[i + 1], "initializer") == 0) {
            initializer = true; ++i;
        }
        else throw std::runtime_error("unknown argument");
    }
    if (!provider.control.empty() && provider.production)
        throw std::runtime_error("oracle calibration controls require Mesa reference mode");
    if (!provider.control.empty() && provider.control != "double-stub" &&
        provider.control != "depth-disabled" && provider.control != "short-double-query" && provider.control != "initializer-stripped")
        throw std::runtime_error("unknown calibration control");
    if ((!provider.control.empty()) && (initializer != (provider.control == "initializer-stripped")))
        throw std::runtime_error("calibration control does not belong to the selected scene");
    provider.identities.open(output + "/functions.tsv");
    if (!provider.identities) throw std::runtime_error("cannot open function evidence");
    provider.library = dlopen(libraryName.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!provider.library) throw std::runtime_error(dlerror());
    calibration = &provider;
    if (provider.production) {
        auto initialize = reinterpret_cast<int (*)(mg_init_report_v1*)>(dlsym(provider.library, "mg_initialize_v1"));
        if (!initialize) throw std::runtime_error("production MG initialization entry is missing");
        provider.canonicalLibrary = Canonical(libraryName.c_str());
        Dl_info owner{};
        if (!dladdr(reinterpret_cast<void*>(initialize), &owner) ||
            Canonical(owner.dli_fname) != provider.canonicalLibrary)
            throw std::runtime_error("MG initializer belongs to a dependency, not the requested library");
        mg_init_report_v1 report{};
        report.struct_size = sizeof(report);
        report.abi_version = MG_INIT_ABI_VERSION;
        if (!initialize(&report)) throw std::runtime_error(std::string("MG initialize failed: ") + report.stage);
    }
#define EGL_FN(name) const auto name##Fn = EglFunction(provider, #name, &name)
    EGL_FN(eglGetDisplay); EGL_FN(eglInitialize); EGL_FN(eglBindAPI); EGL_FN(eglChooseConfig);
    EGL_FN(eglCreatePbufferSurface); EGL_FN(eglCreateContext); EGL_FN(eglMakeCurrent);
    EGL_FN(eglGetCurrentContext); EGL_FN(eglDestroyContext); EGL_FN(eglDestroySurface); EGL_FN(eglTerminate);
#undef EGL_FN
    const EGLDisplay display = eglGetDisplayFn(EGL_DEFAULT_DISPLAY);
    EGLint major = 0, minor = 0;
    if (!display || !eglInitializeFn(display, &major, &minor)) throw std::runtime_error("EGL initialize failed");
    if (!eglBindAPIFn(EGL_OPENGL_API)) throw std::runtime_error("EGL desktop GL bind failed");
    // MG将桌面context请求转换为GLES配置；Mesa参考本身使用OPENGL_BIT。
    const EGLint configAttributes[]{EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 16, EGL_NONE};
    EGLConfig config{};
    EGLint found = 0;
    if (!eglChooseConfigFn(display, configAttributes, &config, 1, &found) || found != 1)
        throw std::runtime_error("EGL pbuffer config failed");
    const EGLint pbufferAttributes[]{EGL_WIDTH, 64, EGL_HEIGHT, 64, EGL_NONE};
    const EGLint contextAttributes[]{EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
    const EGLSurface surface = eglCreatePbufferSurfaceFn(display, config, pbufferAttributes);
    const EGLContext context = eglCreateContextFn(display, config, EGL_NO_CONTEXT, contextAttributes);
    if (!surface || !context || !eglMakeCurrentFn(display, surface, surface, context) ||
        eglGetCurrentContextFn() != context) throw std::runtime_error("EGL legal current context failed");
    using GetString = const unsigned char* (*)(unsigned);
    const auto getString = reinterpret_cast<GetString>(Resolve(&provider, "glGetString"));
    if (!getString) throw std::runtime_error("GL identity is unavailable");
    const auto* renderer = getString(0x1F01);
    if (!renderer || (!provider.production && !std::strstr(reinterpret_cast<const char*>(renderer), "llvmpipe")))
        throw std::runtime_error("software reference did not actually select llvmpipe");
    std::cout << "HOST_IDENTITY provider=" << (provider.production ? "mobileglues-production" : "mesa-reference")
              << " control=" << (provider.control.empty() ? "none" : provider.control)
              << " EGL=" << major << '.' << minor << " version=" << getString(0x1F02)
              << " renderer=" << renderer << " vendor=" << getString(0x1F00) << '\n';
    // GLVND入口映像与实际光栅化驱动是不同层。保留进程真实映射，宿主再对映射
    // 到的图形DSO取摘要；不能用libGL dispatch地址替代Mesa驱动实际载荷身份。
    std::ifstream mappings("/proc/self/maps");
    std::ofstream graphicsMappings(output + "/graphics-maps.txt");
    if (!mappings || !graphicsMappings) throw std::runtime_error("cannot open actual graphics mappings evidence");
    std::string mapping;
    while (std::getline(mappings, mapping)) {
        if (mapping.find("libGL") != std::string::npos || mapping.find("libEGL") != std::string::npos ||
            mapping.find("libgallium") != std::string::npos || mapping.find("_dri.so") != std::string::npos ||
            mapping.find("libglapi") != std::string::npos || mapping.find("mobileglues") != std::string::npos)
            graphicsMappings << mapping << '\n';
    }
    if (mappings.bad()) throw std::runtime_error("cannot read actual graphics mappings");
    CloseEvidence(graphicsMappings);
    const auto result = initializer ? amcl::graphics_semantics::RunUniformInitializer(Resolve, &provider) :
        amcl::graphics_semantics::RunDepthRange(Resolve, &provider, ShaderDialect::Desktop330);
    const bool completeEvidence = initializer ? amcl::graphics_semantics::ValidateCompleteUniformInitializerEvidence(result) :
        amcl::graphics_semantics::ValidateCompleteDepthRangeEvidence(result);
    std::ofstream evidence(output + "/evidence.jsonl");
    evidence << result.evidence;
    CloseEvidence(evidence);
    std::ofstream summary(output + "/summary.json");
    summary << "{\"completed\":" << (result.completed ? "true" : "false")
            << ",\"checks\":" << result.checks << ",\"queryChecks\":" << result.queryChecks
            << ",\"pixelChecks\":" << result.pixelChecks << ",\"failures\":" << result.failures
            << ",\"evidenceComplete\":" << (completeEvidence ? "true" : "false")
            << ",\"stage\":\"" << (provider.production ? "host-production" : "software-reference") << "\"}\n";
    CloseEvidence(summary);
    CloseEvidence(provider.identities);
    std::cout << (initializer ? "UNIFORM_INITIALIZER_RESULT" : "DEPTH_RANGE_RESULT") << " completed=" << result.completed << " checks=" << result.checks
              << " queryChecks=" << result.queryChecks << " pixelChecks=" << result.pixelChecks
              << " failures=" << result.failures << '\n';
    bool cleaned = eglMakeCurrentFn(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) &&
        eglDestroyContextFn(display, context) && eglDestroySurfaceFn(display, surface) && eglTerminateFn(display);
    if (!cleaned) throw std::runtime_error("EGL ownership cleanup failed");
    // 不在GLVND线程内部资源仍可能引用dispatch DSO时执行dlclose；进程立即退出。
    return !completeEvidence ? 2 : result.failures ? 1 : 0;
}
}  // namespace
int main(int argc, char** argv) {
    try { return Run(argc, argv); }
    catch (const std::exception& error) { std::cerr << "HOST_SETUP_FAILURE " << error.what() << '\n'; return 2; }
}
