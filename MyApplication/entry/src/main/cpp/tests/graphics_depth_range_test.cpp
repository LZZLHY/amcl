// default/TestHooks专用的真实MG深度范围资格探针。共享场景与host使用同一份
// C++代码；本文件只编排生产runtime/context owner、函数身份、冷进程和证据。
#include "tests.h"
#include "../platform/env_slot.h"
#include "../platform/graphics_runtime_binding.h"
#include "../utils/amcl_log.h"
#include "../../../../../tests/graphics-semantics/depth_range_scene.h"

#include <chrono>
#include <atomic>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <fstream>
#include <mutex>
#include <signal.h>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <cerrno>
#include <utility>
#include <stdexcept>

namespace {
constexpr const char* kDirectory = "/data/storage/el2/base/haps/entry/files/mg-depth-range-probe";
constexpr const char* kReportPath = "/data/storage/el2/base/haps/entry/files/mg-depth-range-probe/result.txt";
std::mutex runMutex;
std::string resultText;
std::atomic<bool> testProcessClaimed{false};

// 固定MG初始化ABI只用于冷启动资格的只读检查，不在检查阶段初始化MG。
// 布局对应第三方include/MG/init.h的v1；未知ABI/大小或读取失败均拒绝实验。
struct InitReport { uint32_t size, abi; int32_t state, error; char stage[64]; };
using ReadInit = int (*)(InitReport*);

// 流量逐行落盘并立即flush；设备宿主从动作之前监督进程，可在崩溃/超时时
// 读取已产生的阶段。任何证据I/O失败都抛错，不允许仍生成完整资格PASS。
void Emit(FILE* report, const std::string& line) {
    if (std::fprintf(report, "%s\n", line.c_str()) < 0 || std::fflush(report) != 0 || std::ferror(report))
        throw std::runtime_error("probe evidence write/flush failed");
}

// 创建run身份时直接读取系统时钟；单调纳秒与父PID保证同一进程多次调用可区分，
// Unix纳秒用于设备/宿主时间对账。写入失败不能仍返回上次报告或资格PASS。
bool WriteAll(int fd, const std::string& text) {
    std::size_t offset = 0;
    while (offset < text.size()) {
        const ssize_t written = write(fd, text.data() + offset, text.size() - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return false;
        offset += static_cast<std::size_t>(written);
    }
    return true;
}

// 将dladdr已经确认的真实已装入provider文件原字节复制到app可回收的沙箱。
// 宿主随后对这个副本计算SHA，并与实际安装HAP内的成员比较；不能只从预期HAP
// 取一个SHA就宣称设备加载的库相同。此处不命名为candidate，也不复制构建树的库。
void CopyLoadedProvider(FILE* report, const char* loadedPath) {
    const std::string destination = std::string(kDirectory) + "/loaded-libamcl_gl_host.so";
    const char* basename = loadedPath ? std::strrchr(loadedPath, '/') : nullptr;
    basename = basename ? basename + 1 : loadedPath;
    if (!basename || std::strcmp(basename, "libamcl_gl_host.so") != 0)
        throw std::runtime_error("loaded provider filename does not match libamcl_gl_host.so");
    std::ifstream source(loadedPath, std::ios::binary);
    if (!source.is_open()) throw std::runtime_error("cannot open actual loaded provider image");
    source.seekg(0, std::ios::end);
    const auto expectedBytes = source.tellg();
    if (!source || expectedBytes <= 0) throw std::runtime_error("loaded provider byte size is invalid");
    source.seekg(0, std::ios::beg);
    if (!source) throw std::runtime_error("cannot rewind actual loaded provider image");
    std::ofstream target(destination, std::ios::binary | std::ios::trunc);
    if (!target.is_open()) throw std::runtime_error("cannot open loaded provider evidence copy");
    std::array<char, 64 * 1024> buffer{};
    std::uint64_t copied = 0;
    for (;;) {
        source.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        const auto bytes = source.gcount();
        if (bytes > 0) {
            target.write(buffer.data(), bytes);
            if (!target) throw std::runtime_error("loaded provider evidence copy write failed");
            copied += static_cast<std::uint64_t>(bytes);
        }
        if (source.bad() || (source.fail() && !source.eof()))
            throw std::runtime_error("actual loaded provider image read failed");
        if (source.eof()) break;
    }
    if (copied != static_cast<std::uint64_t>(expectedBytes))
        throw std::runtime_error("loaded provider evidence byte count mismatch");
    // 到达EOF会置failbit；只有已确认正常EOF才clear，然后独立检查close本身。
    source.clear(); source.close();
    if (source.fail()) throw std::runtime_error("actual loaded provider image close failed");
    target.flush();
    if (!target) throw std::runtime_error("loaded provider evidence flush failed");
    target.close();
    if (!target) throw std::runtime_error("loaded provider evidence close failed");
    Emit(report, "IMAGE_COPY library=libamcl_gl_host.so bytes=" + std::to_string(copied) +
         " path=" + destination);
}

struct Resolution {
    const amcl::graphics::GraphicsRuntimeBinding* runtime;
    FILE* report;
    void* imageBase;
    unsigned functions = 0;
    unsigned rejected = 0;
};

// runtime.glProc是产品使用的同一路径；每个地址再与真实MG初始化符号映像比较。
// 缺失/外来地址直接返回null给共享场景，禁止借系统GL同名符号补足生产MG。
void* Resolve(void* user, const char* name) {
    auto& state = *static_cast<Resolution*>(user);
    void* address = state.runtime->glProc(name);
    Dl_info image{};
    const bool owned = address && dladdr(address, &image) && image.dli_fname &&
        image.dli_fbase == state.imageBase;
    ++state.functions;
    if (!owned) ++state.rejected;
    std::ostringstream evidence;
    evidence << "FUNCTION name=" << name << " address=" << address << " owned=" << owned
             << " image=" << (image.dli_fname ? image.dli_fname : "UNKNOWN")
             << " symbol=" << (image.dli_sname ? image.dli_sname : "UNKNOWN");
    Emit(state.report, evidence.str());
    return owned ? address : nullptr;
}

// 生产context状态持有者：无论创建完整成功还是部分失败，都通过原owner退休。
// 遇到失败保留报告并返回FAIL；不绕开owner直接eglDestroy来隐藏资源账本故障。
struct ContextOwner {
    const amcl::graphics::GraphicsRuntimeBinding& runtime;
    amcl::graphics::EglContextState state;
    int tid;
    FILE* report;
    bool retired = false;
    bool Retire() {
        if (retired) return true;
        std::string error;
        const bool ok = runtime.contextOperations->destroy(runtime, state, tid, error);
        // 驱动已退休时先发布本地事实，随后证据写失败不能导致对已退休句柄重复操作。
        retired = ok;
        Emit(report, std::string(ok ? "PASS" : "FAIL") + " context-owner-destroy error=" + error +
             " permit=" + std::to_string(state.contextPermit));
        return ok;
    }
};

// 生产runtime会保留EglContextState地址。失败时不能销毁栈对象留下悬空账本；
// 诊断进程已永久阻断JVM/游戏，保留这一次owner及其精确句柄直到宿主重启进程。
// 成功路径正常删除；证据异常不允许析构抛出第二个异常而跳过原始失败报告。
struct ContextOwnerDeleter {
    void operator()(ContextOwner* owner) const noexcept {
        if (!owner) return;
        try { if (owner->Retire()) { delete owner; return; } }
        catch (...) { if (owner->retired) { delete owner; return; } }
        AMCL_LOG_E("MG_DEPTH_RANGE_PROBE", "context owner retained until process restart after retirement failure");
    }
};

// 真正图形测试只在重启后的专用诊断进程执行。从中立runtime冻结profile，再从同一生产操作
// 表建立auxiliary pbuffer；不取得游戏NativeWindow，也不覆盖全局函数表。
int Probe(FILE* report) {
    Emit(report, "BEGIN MG_DEPTH_RANGE production-profile=mobileglues api=OPENGL");
    std::string error;
    if (!amcl::graphics::FreezeGraphicsRuntime("mobileglues", "OPENGL", error)) {
        Emit(report, "FAIL freeze-runtime error=" + error); return 2;
    }
    const auto* runtime = amcl::graphics::BoundGraphicsRuntime();
    if (!runtime || !runtime->is("mobileglues") || !runtime->contextOperations) {
        Emit(report, "FAIL bound-runtime identity"); return 2;
    }
    void* ownerSymbol = runtime->providerProc("mg_get_init_report_v1");
    Dl_info provider{};
    if (!ownerSymbol || !dladdr(ownerSymbol, &provider) || !provider.dli_fbase || !provider.dli_fname) {
        Emit(report, "FAIL provider-image identity"); return 2;
    }
    Emit(report, "PROVIDER image=" + std::string(provider.dli_fname) +
         " implementation=" + runtime->implementationIdentity);
    CopyLoadedProvider(report, provider.dli_fname);
    const int tid = static_cast<int>(gettid());
    std::unique_ptr<ContextOwner, ContextOwnerDeleter> retainedOwner(new ContextOwner{*runtime, {}, tid, report});
    auto& owner = *retainedOwner;
    owner.state.auxiliary = 1;
    owner.state.width = 16; owner.state.height = 16;
    amcl::desktop::ContextRequest request;
    // 新MG公共frontend是桌面GL；共享initializer使用GLSL330，所以实际请求
    // 3.3/core，不能借旧GLES transport的3.0请求或字符串配置上限授予语言资格。
    request.major = 3; request.minor = 3; request.profile = 0x00032001;
    if (!runtime->contextOperations->create(*runtime, owner.state, request, tid, error)) {
        Emit(report, "FAIL context-owner-create error=" + error); return 2;
    }
    const bool current = runtime->egl.eglGetCurrentContext() == owner.state.context &&
        runtime->egl.eglGetCurrentDisplay() == owner.state.display && owner.state.contextOwnerTid == tid;
    Emit(report, std::string(current ? "PASS" : "FAIL") + " legal-current-thread tid=" + std::to_string(tid) +
         " actualMajor=" + std::to_string(owner.state.actualContextMajor) +
         " actualMinor=" + std::to_string(owner.state.actualContextMinor));
    if (!current) return 2;
    Resolution resolver{runtime, report, provider.dli_fbase};
    using GetString = const unsigned char* (*)(unsigned);
    using GetInteger = void (*)(unsigned, int*);
    const auto getString = reinterpret_cast<GetString>(Resolve(&resolver, "glGetString"));
    const auto getInteger = reinterpret_cast<GetInteger>(Resolve(&resolver, "glGetIntegerv"));
    if (!getString || !getInteger) return 2;
    for (const auto& field : {std::pair<unsigned, const char*>{0x1F02, "GL_VERSION"},
                             {0x1F00, "GL_VENDOR"}, {0x1F01, "GL_RENDERER"}}) {
        const auto* value = getString(field.first);
        Emit(report, std::string(field.second) + "=" + (value ? reinterpret_cast<const char*>(value) : "UNKNOWN"));
    }
    int glMajor = 0, glMinor = 0;
    getInteger(0x821B, &glMajor); getInteger(0x821C, &glMinor);
    Emit(report, "GL_INTEGER_VERSION=" + std::to_string(glMajor) + "." + std::to_string(glMinor));
    const auto scene = amcl::graphics_semantics::RunDepthRange(Resolve, &resolver,
        amcl::graphics_semantics::ShaderDialect::Desktop330);
    // JSONL各行单独flush，既有hilog长度限制不会截掉整份像素证据。
    std::istringstream lines(scene.evidence);
    std::string line;
    while (std::getline(lines, line)) Emit(report, line);
    const unsigned depthFunctions = resolver.functions, depthRejected = resolver.rejected;
    // 同一专用current owner接续shader声明初值用例，仍使用上述生产resolver和映像。
    // 两场景各自的计数/JSONL终止marker保持独立；后者不借depth83/26/24授予资格。
    Emit(report, "BEGIN MG_UNIFORM_INITIALIZER sceneVersion=1 shader=desktop330");
    const auto initializer = amcl::graphics_semantics::RunUniformInitializer(Resolve, &resolver);
    std::istringstream initializerLines(initializer.evidence);
    while (std::getline(initializerLines, line)) Emit(report, line);
    const bool retired = owner.Retire();
    const bool completeEvidence = amcl::graphics_semantics::ValidateCompleteDepthRangeEvidence(scene);
    const bool completeInitializer = amcl::graphics_semantics::ValidateCompleteUniformInitializerEvidence(initializer);
    const bool depthPass = completeEvidence && scene.failures == 0 && depthRejected == 0 && retired;
    const bool initializerPass = completeInitializer && initializer.failures == 0 &&
        resolver.rejected == depthRejected && retired;
    const bool pass = depthPass && initializerPass;
    Emit(report, "MG_DEPTH_RANGE_RESULT completed=" + std::to_string(scene.completed) +
         " checks=" + std::to_string(scene.checks) + " queryChecks=" + std::to_string(scene.queryChecks) +
         " pixelChecks=" + std::to_string(scene.pixelChecks) + " failures=" + std::to_string(scene.failures) +
         " resolved=" + std::to_string(depthFunctions) + " rejected=" + std::to_string(depthRejected) +
         " evidenceComplete=" + std::to_string(completeEvidence) +
         " retired=" + std::to_string(retired) + " verdict=" + (depthPass ? "PASS" : "FAIL"));
    Emit(report, "MG_UNIFORM_INITIALIZER_RESULT sceneVersion=1 completed=" + std::to_string(initializer.completed) +
         " checks=" + std::to_string(initializer.checks) + " queryChecks=" + std::to_string(initializer.queryChecks) +
         " pixelChecks=" + std::to_string(initializer.pixelChecks) + " failures=" + std::to_string(initializer.failures) +
         " resolved=" + std::to_string(resolver.functions - depthFunctions) +
         " rejected=" + std::to_string(resolver.rejected - depthRejected) +
         " evidenceComplete=" + std::to_string(completeInitializer) + " retired=" + std::to_string(retired) +
         " verdict=" + (initializerPass ? "PASS" : "FAIL"));
    return pass ? 0 : scene.completed && initializer.completed ? 1 : 2;
}

// 进程已进入游戏/已冻结图形/MG已初始化时，不能产生真正冷的图形状态。
// 这些情况必须重启应用后再测；拒绝消息明确NOT_RUN，绝不作通过或缺陷证据。
std::string CannotStart() {
    if (testProcessClaimed.load(std::memory_order_acquire)) return "NOT_RUN: diagnostic process already consumed; restart application";
    if (amcl::envslot::ProcessRegistry().Sealed()) return "NOT_RUN: environment registry is sealed; restart application before launching a game";
    if (std::getenv("AMCL_GRAPHICS_RUNTIME_SERVICE_V2") || std::getenv("AMCL_GRAPHICS_RUNTIME_V1") ||
        amcl::graphics::BoundGraphicsRuntime()) return "NOT_RUN: graphics runtime already exists; restart application";
    void* library = dlopen("libamcl_gl_host.so", RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    if (!library) return {};
    auto read = reinterpret_cast<ReadInit>(dlsym(library, "mg_get_init_report_v1"));
    InitReport report{sizeof(report), 1, 0, 0, {}};
    const int state = read ? read(&report) : -1;
    dlclose(library);
    if (!read || state != 0 || report.state != 0 || report.abi != 1 || report.size != sizeof(report))
        return "NOT_RUN: MobileGlues image is not verifiably COLD; restart application";
    return {};
}
}  // namespace

// NAPI游戏/JVM入口在TestHooks构建里消费这一个原子只读门；不增加环境变量，
// 诊断进程一旦认领就不可恢复为游戏进程，必须由宿主停止后重新启动应用。
int graphicsSemanticsRestartRequired() {
    return testProcessClaimed.load(std::memory_order_acquire) ? 1 : 0;
}

int graphicsSemanticsTryClaimProcess() {
    bool expected = false;
    return testProcessClaimed.compare_exchange_strong(expected, true, std::memory_order_acq_rel) ? 1 : 0;
}

const char* graphicsSemanticsCannotStart() {
    static thread_local std::string message;
    message = CannotStart();
    return message.c_str();
}

const char* runMgDepthRangeTest() {
    std::lock_guard<std::mutex> lock(runMutex);
    const auto monotonicNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    const auto unixNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    const std::string runId = std::to_string(getpid()) + "-" + std::to_string(monotonicNs);
    const std::string header = "PROBE_RUN runId=" + runId + " processPid=" + std::to_string(getpid()) +
        " startUnixNs=" + std::to_string(unixNs) + " startSteadyNs=" + std::to_string(monotonicNs) + "\n";
    if (mkdir(kDirectory, 0700) != 0 && errno != EEXIST) {
        resultText = header + "FAIL: cannot create probe evidence directory\n"; return resultText.c_str();
    }
    // 先截断固定报告，拒绝或失败不能读出上次PASS。报告与NAPI返回都绑定runId。
    const int reportFd = open(kReportPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (reportFd < 0) { resultText = header + "FAIL: cannot open probe evidence\n"; return resultText.c_str(); }
    if (!WriteAll(reportFd, header)) {
        close(reportFd); resultText = header + "FAIL: cannot write run identity\n"; return resultText.c_str();
    }
    FILE* report = fdopen(reportFd, "w");
    if (!report) { close(reportFd); resultText = header + "FAIL: cannot create evidence stream\n"; return resultText.c_str(); }
    int code = 2;
    bool ran = false;
    std::string failure;
    try {
        const std::string rejected = CannotStart();
        if (!rejected.empty()) {
            Emit(report, rejected);
            Emit(report, "PROBE_END runId=" + runId + " processPid=" + std::to_string(getpid()) +
                 " completed=0 exitCode=-1 restartRequired=" +
                 std::to_string(graphicsSemanticsRestartRequired()) + " verdict=NOT_RUN");
        } else {
            // ArkUI/NAPI应用本来是多线程进程；fork后再调用C++/dlopen/driver不保证
            // 干净或async-signal-safe。直接在冷启动诊断app运行，宿主在动作前采集并
            // 负责30秒上限和force-stop；完成后该进程永久要求重启，不能继续启动游戏。
            if (!graphicsSemanticsTryClaimProcess())
                throw std::runtime_error("diagnostic process concurrently claimed; restart application");
            ran = true;
            std::ofstream config(std::string(kDirectory) + "/config.json");
            config << "{\"customGLVersion\":46,\"fsr1Setting\":0,\"hideMGEnvLevel\":0}";
            config.close();
            if (!config) throw std::runtime_error("probe configuration write/close failed");
            if (setenv("MG_DIR_PATH", kDirectory, 1) != 0) throw std::runtime_error("config environment failed");
            code = Probe(report);
            Emit(report, "PROBE_END runId=" + runId + " processPid=" + std::to_string(getpid()) +
                 " completed=1 exitCode=" + std::to_string(code) + " restartRequired=1 verdict=" +
                 (code == 0 ? "PASS" : "FAIL"));
        }
    } catch (const std::exception& exception) { failure = exception.what(); }
      catch (...) { failure = "unknown exception"; }
    if (!failure.empty()) {
        try { Emit(report, "FAIL exception=" + failure); } catch (...) {}
    }
    const bool closed = std::fclose(report) == 0;
    if (!closed || !failure.empty()) {
        resultText = header + "FAIL: " + (failure.empty() ? "evidence close failed" : failure) +
            " restartRequired=" + std::to_string(ran) + "\n";
        return resultText.c_str();
    }
    std::ifstream file(kReportPath);
    std::ostringstream buffer;
    buffer << file.rdbuf();
    if (!file.is_open() || file.bad()) { resultText = header + "FAIL: cannot read run evidence\n"; return resultText.c_str(); }
    resultText = buffer.str();
    const std::size_t reportBytes = resultText.size();
    // 此marker只向NAPI返回/宿主预先启动的hilog流发布，晚于报告close及回读成功。
    // 文件PROBE_END必须与外部PROBE_RETURN共同匹配runId/PID/bytes，才可验收PASS；
    // 不能把“已写PASS但close失败”的孤立文件当作函数成功返回的证据。
    resultText += "PROBE_RETURN runId=" + runId + " processPid=" + std::to_string(getpid()) +
        " reportBytes=" + std::to_string(reportBytes) + " returned=1 verdict=" +
        (!ran ? "NOT_RUN" : code == 0 ? "PASS" : "FAIL") + "\n";
    std::istringstream lines(resultText);
    std::string line;
    while (std::getline(lines, line)) AMCL_LOG_I("MG_DEPTH_RANGE_PROBE", "%{public}s", line.c_str());
    return resultText.c_str();
}
