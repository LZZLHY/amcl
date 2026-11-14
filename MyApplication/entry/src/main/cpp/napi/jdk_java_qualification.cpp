/**
 * 真正的 OHOS Java 资格通道：完整候选先经过生产安装事务，释放 use.EX 后由 jvmInit
 * 持有同一私有根的 use.SH。默认创建官方NCP；不支持NCP的设备可显式选择仅basic/extended
 * 的shared工具冷进程，每个major/profile必须重启。两者均不改写用户现役filesDir/jdk，
 * shared不授予游戏、独立子进程或跨VM资格。此TU全部入口受TestHooks编译宏约束。
 */
#include "jdk_java_qualification.h"
#ifdef MC_OHOS_BUILD_TESTS
#include "jdk_java_fixture.h"
#include "jdk_shared_qualification_io.h"
#include "jdk_permission_qualification.h"
#include "jdk_font_context_qualification.h"
#include "jdk_font_defaults_qualification.h"
#include "jdk_audio_timing_qualification.h"
#include "jdk_capture_diagnostics.h"
#include "jdk_capture_native_qualification.h"
#include "jdk_native_temp_qualification.h"
#include "jdk_native_file_times_qualification.h"
#include "jdk_native_temp_pair_owner.h"
#include <iterator>
#include <new>
#include <pthread.h>
#include "napi_helpers.h"
#include "graphics_semantics_guard.h"
#include "../jvm/jvm_launcher.h"
#include "../jvm/mc_launcher.h"
#include "../jvm/jvm_cf_policy.h"
#include "../jvm/processor_environment.h"
#include "../platform/jdk_install_io.h"
#include "../platform/jdk_install_store.h"
#include <AbilityKit/native_child_process.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <memory>
#include <mutex>
#include <poll.h>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

extern "C" __attribute__((visibility("default")))
void AmclJdkJavaQualificationMain(NativeChildProcess_Args args);
extern "C" __attribute__((visibility("default")))
void AmclJdkNativeTempVmMain(NativeChildProcess_Args args);

// 公共执行体只借用目录/报告fd；NCP包装器与shared worker分别保有真实资源owner。
static void runQualification(const char* parameters, int pipe, int transferredRoot, bool shared);

namespace {
namespace io = amcl::jdk::io;
using Clock = std::chrono::steady_clock;
constexpr auto Timeout = std::chrono::seconds(180);
std::atomic<bool> active{false};
// shared资格受理后即占用整个诊断进程；即使排队/安装失败也不回退，防止普通UI复用工具配置。
std::atomic<bool> sharedProcessClaimed{false};
/** 固定白名单没有pair、音频或任意profile透传，调用者只能请求这两项shared工具。 */
bool sharedProfile(const std::string& profile) {
    return profile == "shared-basic" || profile == "shared-extended";
}
std::mutex exitMutex;
int32_t expectedPid = -1;
bool exitObserved = false;
int32_t exitSignal = 0;
using KillChild = Ability_NativeChildProcess_ErrCode (*)(int32_t);

/**
 * 只在此测试入口的冷启动边界注入系统查找函数，供宿主精确复现命名空间不可见、
 * provider 缺失和错误符号归属；实际 HAP 默认调用系统的 dladdr/dlopen/dlsym/dlclose。
 */
struct ProviderLookup {
    int (*address)(const void*, Dl_info*) = dladdr;
    void* (*open)(const char*, int) = dlopen;
    void* (*symbol)(void*, const char*) = dlsym;
    int (*close)(void*) = dlclose;
    char* (*error)() = dlerror;
};

/**
 * API26 真机已存在 KillChildProcess，但其系统 namespace 不参加 RTLD_DEFAULT 查询。
 * 从静态链接且已成功使用的 Start 函数取得真实 DSO，再只打开已加载实例并查找同库
 * Kill 导出。handle 先于 callback/ChildOwner 创建，最后释放，终止函数不会变成悬空指针。
 */
class ChildProcessProvider {
    struct Handle {
        void* value = nullptr;
        int (*close)(void*) = nullptr;
        ~Handle() { if (value) close(value); }
    } handle_;
    KillChild function_ = nullptr;
    std::string path_;
public:
    explicit ChildProcessProvider(ProviderLookup lookup = {}) {
        Dl_info start{};
        io::Require(lookup.address(reinterpret_cast<const void*>(&OH_Ability_StartNativeChildProcess), &start) != 0 &&
                    start.dli_fname && start.dli_fname[0] && start.dli_fbase,
                    "无法核实 NativeChildProcess Start 的已加载提供者");
        path_ = start.dli_fname;
        handle_.close = lookup.close;
        lookup.error();
        handle_.value = lookup.open(path_.c_str(), RTLD_NOW | RTLD_NOLOAD);
        // 某些 namespace 只允许公共 NDK basename；两条路径都禁止装入新映像，并在
        // 获取符号后比较真实基址，不能意外认领另一个同名/依赖库中的终止入口。
        if (!handle_.value) handle_.value = lookup.open("libchild_process.so", RTLD_NOW | RTLD_NOLOAD);
        if (!handle_.value) {
            const char* detail = lookup.error();
            throw std::runtime_error("无法取得已加载 NativeChildProcess 提供者: " + path_ +
                "; " + (detail ? detail : "no loader detail"));
        }
        lookup.error();
        void* address = lookup.symbol(handle_.value, "OH_Ability_KillChildProcess");
        const char* detail = lookup.error();
        io::Require(address && !detail, "已加载 NativeChildProcess 提供者缺少终止入口: " + path_ +
                    "; " + (detail ? detail : "null symbol"));
        Dl_info termination{};
        io::Require(lookup.address(address, &termination) != 0 && termination.dli_fbase == start.dli_fbase,
                    "NativeChildProcess 终止入口不属于已核实的 Start 提供者");
        function_ = reinterpret_cast<KillChild>(address);
    }
    ChildProcessProvider(const ChildProcessProvider&) = delete;
    ChildProcessProvider& operator=(const ChildProcessProvider&) = delete;
    KillChild function() const noexcept { return function_; }
    const std::string& path() const noexcept { return path_; }
};

/** JSON 文本字段保留 UTF-8 原文，只转义结构字符；控制字符不能伪造另一条阶段记录。 */
std::string quoted(const std::string& text) {
    static const char digits[] = "0123456789abcdef";
    std::string result = "\"";
    for (unsigned char c : text) {
        if (c == '\\' || c == '"') { result += '\\'; result += static_cast<char>(c); }
        else if (c < 32) { result += "\\u00"; result += digits[c >> 4]; result += digits[c & 15]; }
        else result += static_cast<char>(c);
    }
    return result + '"';
}

bool validMajor(const std::string& major) {
    return major == "8" || major == "17" || major == "21" || major == "25";
}
/** CF策略只用于CF专属profile，工具/音频资格不能因共用入口而意外改变生产编译策略。 */
bool cfProfile(const std::string& profile) {
    return profile == "broad" || profile == "c2-only" || profile == "full";
}
bool extendedProfile(const std::string& profile) {
    return profile == "extended" || profile == "extended-fork";
}
bool soundProfile(const std::string& profile) {
    return profile == "sound-software" || profile == "sound-playback";
}
/** 拒权观察不会start；正向短录音须由宿主取得用户同意并完成系统授权后显式选择。 */
bool captureProfile(const std::string& profile) {
    return profile == "sound-capture-denied" || profile == "sound-capture" ||
        profile == "sound-capture-diagnostic";
}
/** 正向统计诊断与正常短录音使用相同的10秒预算；拒权观察不调用start。 */
bool positiveCaptureProfile(const std::string& profile) {
    return profile == "sound-capture" || profile == "sound-capture-diagnostic" ||
        profile == "sound-capture-native" || profile == "sound-capture-layout" || profile == "sound-capture-startup" ||
        profile == "sound-capture-channels";
}
/** main正常返回仅表示夹具执行结束；独占完成记录还必须声明成功并绑定原始报告字节。 */
void requireProcessCompletion(int runRoot) {
    io::Fd directory(openat(runRoot, "java-process", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    io::Require(directory.get() >= 0, "ProcessBuilder报告目录不可读取");
    const std::string result = io::SmallFile(directory.get(), "result.json", 65536);
    const std::string marker = io::SmallFile(directory.get(), "complete.json", 256);
    const std::string expected = "{\"protocol\":\"AMCL_JAVA_PROCESS_COMPLETE_V1\",\"resultSha256\":\"" +
        io::Digest(result) + "\",\"passed\":true}\n";
    io::Require(marker == expected, "ProcessBuilder完成记录为失败或与原始结果不符");
}
/** 只接受本次固定设备观察的精确协议与完整进度摘要；MIDI收发始终明确未授予资格。
 * 唯一动态整数为正Port数量，按十进制有界解析，避免substring匹配把false或伪字段当完成。
 */
void requireSoundDevicesCompletion(int runRoot, const std::string& major) {
    const auto progress = io::SmallFile(runRoot, "native-sound-devices-progress.jsonl", 2 * 1024 * 1024);
    const auto marker = io::SmallFile(runRoot, "native-sound-devices-complete.json", 1024);
    const auto prefix = "{\"protocol\":\"AMCL_NATIVE_SOUND_DEVICES_V1\",\"major\":" + major +
        ",\"passed\":true,\"midiIoQualified\":false,\"portCount\":";
    const auto suffix = ",\"progressSha256\":\"" + io::Digest(progress) + "\"}\n";
    io::Require(marker.size() > prefix.size() + suffix.size() && marker.compare(0, prefix.size(), prefix) == 0 &&
        marker.compare(marker.size() - suffix.size(), suffix.size(), suffix) == 0, "原生音频设备观察完成记录或摘要不符");
    const auto number = marker.substr(prefix.size(), marker.size() - prefix.size() - suffix.size());
    io::Require(number.size() <= 10 && number.front() >= '1' && number.front() <= '9', "设备观察Port数量不合法");
    uint64_t count = 0;
    for (char digit : number) {
        io::Require(digit >= '0' && digit <= '9', "设备观察Port数量含非法字符");
        count = count * 10 + static_cast<unsigned>(digit - '0');
        io::Require(count <= 2147483647, "设备观察Port数量溢出");
    }
}
/** 固定策略只对新NCP生效；8没有等价的单类C2-only，不允许伪装成全局C1。 */
bool validProfile(const std::string& major, const std::string& profile) {
    return profile == "basic" || profile == "native-temp" || profile == "native-file-times" || profile == "native-temp-vms" || profile == "font-defaults" || profile == "process-java" || profile == "sound-timing" || profile == "sound-capture-native" || profile == "sound-capture-layout" || profile == "sound-capture-startup" || profile == "sound-capture-channels" || profile == "native-sound-devices" || extendedProfile(profile) || soundProfile(profile) || captureProfile(profile) || profile == "broad" || profile == "full" ||
        (profile == "c2-only" && major != "8");
}
bool validNonce(const std::string& nonce) {
    return !nonce.empty() && nonce.size() <= 80 &&
        nonce.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_") == std::string::npos;
}

/** Native前置观察没有实际JDK选择，独立目录避免被Java报告消费者误认作已运行major。 */
std::string qualificationRunName(const std::string& major, const std::string& profile) {
    if (profile == "native-temp") return "run-native-temp";
    if (profile == "native-file-times") return "run-native-file-times";
    return "run-" + major;
}

/** 所有资格产物必须新建；前轮成功证据不能被本轮静默复用。fd 由 RAII 恰好关闭一次。 */
void writeNew(int directory, const std::string& name, const void* bytes, size_t size) {
    io::Fd file(openat(directory, name.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (file.get() < 0) io::Error("资格文件已存在或不可创建: " + name);
    io::Write(file.get(), bytes, size);
    io::Sync(file.get());
    io::Sync(directory);
}
void writeNew(int directory, const std::string& name, const std::string& text) {
    writeNew(directory, name, text.data(), text.size());
}

/** 短报告同时写到独占阶段日志和 IPC 管道；管道暂满不改变 JVM 结果，完整日志仍在沙箱。 */
class Report {
    int pipe_;
    io::Fd file_;
public:
    Report(int pipe, int run) : pipe_(pipe), file_(openat(run, "native-stages.jsonl",
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600)) {
        if (file_.get() < 0) io::Error("无法建立资格阶段日志");
    }
    void line(const std::string& value) {
        const std::string text = value + "\n";
        io::Write(file_.get(), text.data(), text.size());
        io::Sync(file_.get());
        if (pipe_ < 0) return; // shared直接保留原阶段文件，没有伪造NCP报告管道。
        size_t offset = 0;
        while (offset < text.size()) {
            const ssize_t count = write(pipe_, text.data() + offset, text.size() - offset);
            if (count > 0) offset += static_cast<size_t>(count);
            else if (count < 0 && errno == EINTR) continue;
            else break;
        }
    }
    void stage(const char* name) { line("{\"stage\":" + quoted(name) + "}"); }
};

/** 原生前置完成协议不含Java init/main/Destroy或归档成功字段。OBSERVED也不授Attach资格。 */
void writeNativeTempCompletion(int run, Report* report, const std::string& nonce,
                               const std::string& hash, const std::string& error) {
    const std::string receipt = "{\"protocol\":\"AMCL_NATIVE_TEMP_RESULT_V1\",\"profile\":\"native-temp\",\"pid\":" +
        std::to_string(getpid()) + ",\"nonce\":" + quoted(nonce) + ",\"observationComplete\":" +
        (error.empty() && io::Hash(hash) ? "true" : "false") + ",\"reportSha256\":" + quoted(hash) +
        ",\"archiveInstalled\":false,\"jvmStarted\":false,\"error\":" + quoted(error) + "}\n";
    if (run >= 0) writeNew(run, "result.json", receipt);
    if (report) report->line(receipt);
}

/** 文件时间对照独立于Java和Attach资格，完成只表示观察收敛，不表示所有系统调用成功。 */
void writeNativeFileTimesCompletion(int run, Report* report, const std::string& nonce,
                                   const std::string& hash, const std::string& error) {
    const std::string receipt = "{\"protocol\":\"AMCL_NATIVE_FILE_TIMES_RESULT_V1\",\"profile\":\"native-file-times\",\"pid\":" +
        std::to_string(getpid()) + ",\"nonce\":" + quoted(nonce) + ",\"observationComplete\":" +
        (error.empty() && io::Hash(hash) ? "true" : "false") + ",\"reportSha256\":" + quoted(hash) +
        ",\"archiveInstalled\":false,\"jvmStarted\":false,\"error\":" + quoted(error) + "}\n";
    if (run >= 0) writeNew(run, "result.json", receipt);
    if (report) report->line(receipt);
}

/** 对完整 ZIP 重新流式计算摘要并核对前后身份/大小；SHA 文本由维护者独立投放。 */
std::string archiveDigest(int root) {
    io::Fd archive(openat(root, "runtime.zip", O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
    if (archive.get() < 0) io::Error("无法打开 runtime.zip");
    struct stat before{}, after{};
    io::Require(fstat(archive.get(), &before) == 0 && S_ISREG(before.st_mode) && before.st_size > 0,
                "runtime.zip 不是有效普通文件");
    download::Sha256 hash;
    std::vector<char> buffer(256 * 1024);
    uint64_t bytes = 0;
    for (;;) {
        const ssize_t count = read(archive.get(), buffer.data(), buffer.size());
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) io::Error("runtime.zip 读取失败");
        if (count == 0) break;
        hash.update(buffer.data(), static_cast<size_t>(count));
        bytes += static_cast<uint64_t>(count);
    }
    io::Require(fstat(archive.get(), &after) == 0 && before.st_dev == after.st_dev &&
                before.st_ino == after.st_ino && before.st_size == after.st_size &&
                bytes == static_cast<uint64_t>(before.st_size), "runtime.zip 读取期间身份/大小变化");
    return hash.finalizeHex();
}

/** 安装只操作本 nonce 的数字槽；writer 与 use.EX 在退出本函数前全部释放。 */
std::string installCandidate(const std::string& rootPath, int root, const std::string& major, Report& report) {
    const std::string sidecar = io::SmallFile(root, "archive-sha256.txt", 66);
    io::Require(sidecar.size() == 65 && sidecar.back() == '\n' && io::Hash(sidecar.substr(0, 64)),
                "archive-sha256.txt 必须为 64 位小写 hex 加换行");
    const std::string digest = sidecar.substr(0, 64);
    report.stage("archive-sha256-before");
    io::Require(archiveDigest(root) == digest, "候选 ZIP SHA256 不匹配");
    auto jdk = io::ChildDirectory(root, "jdk", true);
    io::Require(!io::Exists(jdk.get(), major), "资格槽已存在，拒绝覆盖或复用");
    auto locks = io::ChildDirectory(jdk.get(), ".locks", true);
    auto lease = [&](const std::string& name) {
        io::Fd fd(openat(locks.get(), name.c_str(), O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600));
        if (fd.get() < 0) io::Error("资格安装租约打开失败");
        io::Require(flock(fd.get(), LOCK_EX | LOCK_NB) == 0, "资格安装租约存在冲突");
        return fd;
    };
    auto writer = lease(major + ".writer");
    auto use = lease(major + ".use");
    io::Require(!amcl::jdk::InstallRecoveryRequired(rootPath, major), "新资格根含有未完成 journal");
    report.stage("install-stage");
    const std::string stage = amcl::jdk::CreateInstallStage(rootPath, major, writer.get());
    // 失败或超时保留 staging/journal，便于诊断；它们属于隔离根，不会污染用户现役槽。
    report.stage("install-extract");
    amcl::jdk::ExtractInstallArchive(rootPath + "/runtime.zip", stage, digest, 150000);
    report.stage("install-seal");
    amcl::jdk::SealInstallStage(stage, major, digest);
    report.stage("install-publish");
    amcl::jdk::PublishInstallStage(rootPath, major, stage, writer.get(), use.get());
    amcl::jdk::DiscardInstallStage(rootPath, major, stage, writer.get());
    io::Require(!amcl::jdk::InstallRecoveryRequired(rootPath, major), "发布后的 journal 尚未完成");
    report.stage("archive-sha256-after");
    io::Require(archiveDigest(root) == digest && io::SmallFile(root, "archive-sha256.txt", 66) == sidecar,
                "安装修改了原始 ZIP 或 SHA 文本");
    report.line("{\"stage\":\"install-complete\",\"archiveSha256\":" + quoted(digest) + "}");
    return digest;
}

/** 退出回调只接收 SDK 明确给出的 signal；不虚构 waitpid 状态，也不将 pipe EOF 当退出证明。 */
void childExit(int32_t pid, int32_t signal) {
    std::lock_guard<std::mutex> guard(exitMutex);
    if (pid == expectedPid) { exitSignal = signal; exitObserved = true; }
}

/**
 * Start 成功之后，任何 C++ 分配/日志异常都不能让父任务抛出时遗留后台 JVM。
 * 此 owner 比退出回调 owner 后创建，先等待真实退出再允许注销回调；异常清理不分配。
 */
class ChildOwner {
    KillChild terminate_;
    int32_t pid_ = -1;
public:
    explicit ChildOwner(KillChild terminate) : terminate_(terminate) {}
    void adopt(int32_t pid) noexcept { pid_ = pid; }
    void exited() noexcept { pid_ = -1; }
    ~ChildOwner() {
        if (pid_ < 0) return;
        auto nextTermination = Clock::now();
        for (;;) {
            {
                std::lock_guard<std::mutex> guard(exitMutex);
                if (exitObserved && expectedPid == pid_) return;
            }
            const auto now = Clock::now();
            if (now >= nextTermination) {
                terminate_(pid_);
                nextTermination = now + std::chrono::seconds(1);
            }
            poll(nullptr, 0, 50);
        }
    }
};

struct NativeTempPairSession;
struct Job {
    napi_async_work work{};
    napi_ref callback{};
    std::string files;
    std::string nonce;
    std::string major;
    std::string profile;
    std::string result;
    bool shared = false; // 仅固定shared-basic/shared-extended映射，不随意选择生产进程模式。
    std::shared_ptr<NativeTempPairSession> pair;
};

#include "jdk_native_temp_vm_pair.inc"

/** 正向录音/固定native-only观察各有10秒阶段预算，不拿安装/VM的180秒时限代替。
 * Native阶段协议来自本次专属pipe；接收窗口只保留512字节，支持跨read分片且不反复延时。
 * 超时后仍沿官方身份约束Kill及真实退出监督收尾，不把发出终止请求伪装成已经退出。 */
struct QualificationPhaseDeadline {
    bool enabled, began = false, finished = false;
    std::string tail;
    std::string startMarker, endMarker;
    Clock::time_point deadline{};
    explicit QualificationPhaseDeadline(bool selected, const char* stage = "capture-main") : enabled(selected),
        startMarker("{\"stage\":\"" + std::string(stage) + "\"}\n"),
        endMarker("{\"stage\":\"" + std::string(stage) + "-return\",") {}
    void receive(const char* data, size_t size, Clock::time_point now) {
        if (!enabled || finished) return;
        tail.append(data, size);
        if (!began && tail.find(startMarker) != std::string::npos) {
            began = true; deadline = now + std::chrono::seconds(10);
        }
        if (began && tail.find(endMarker) != std::string::npos) finished = true;
        if (tail.size() > 512) tail.erase(0, tail.size() - 512);
    }
    bool expired(Clock::time_point now) const { return enabled && began && !finished && now >= deadline; }
};

/**
 * 准入与目录验证在异步 worker 完成。NCP 从本进程刚打开的 root fd 接收目录身份；
 * canonical path 仅供生产 JVM 的路径接口使用，两者在子进程再次逐项核对。
 */
std::string runParent(const Job& job) {
    if (job.profile == "native-temp-vms") return runNativeTempPair(job);
    const bool nativeOnly = job.profile == "native-temp" || job.profile == "native-file-times";
    // API22 才有按“本应用 NCP 身份”终止的接口。先核实实际已加载 provider，而不是
    // 把全局查找不可见误报为 API 缺失；仍缺导出时在创建子进程前明确拒绝。
    ChildProcessProvider provider;
    const auto killChild = provider.function();
    char* canonical = realpath(job.files.c_str(), nullptr);
    io::Require(canonical != nullptr, "应用 filesDir 不存在");
    std::unique_ptr<char, decltype(&free)> ownedCanonical(canonical, &free);
    const std::string files(canonical);
    auto filesRoot = io::Directory(files);
    auto qualification = io::ChildDirectory(filesRoot.get(), "jdk-runtime-qualification");
    auto root = io::ChildDirectory(qualification.get(), job.nonce);
    const std::string rootPath = files + "/jdk-runtime-qualification/" + job.nonce;
    const std::string runName = qualificationRunName(job.major, job.profile);
    io::Require(mkdirat(root.get(), runName.c_str(), 0700) == 0, "资格运行目录已存在，必须使用新 nonce");
    auto run = io::ChildDirectory(root.get(), runName);
    if (!nativeOnly)
        writeNew(run.get(), "qualification.jar", amcl::jdkqualification::FixtureJar, amcl::jdkqualification::FixtureJarSize);
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC | O_NONBLOCK) != 0) io::Error("无法创建资格报告管道");
    io::Fd readEnd(pipefd[0]), writeEnd(pipefd[1]);
    const int registration = OH_Ability_RegisterNativeChildProcessExitCallback(childExit);
    io::Require(registration == 0, "NCP 退出回调注册失败: " + std::to_string(registration));
    struct CallbackOwner {
        ~CallbackOwner() { OH_Ability_UnregisterNativeChildProcessExitCallback(childExit); }
    } callbackOwner;
    ChildOwner childOwner(killChild);
    std::ostringstream report;
    report << "{\"stage\":\"parent\",\"pid\":" << getpid() << ",\"nativeOnly\":" << (nativeOnly ? "true" : "false")
           << ",\"major\":" << (nativeOnly ? "null" : quoted(job.major))
           << ",\"root\":" << quoted(rootPath) << ",\"fixtureSha256\":"
           << (nativeOnly ? "null" : quoted(amcl::jdkqualification::FixtureJarSha256)) << ",\"childProcessProvider\":"
           << quoted(provider.path()) << "}\n";
    const std::string parameters = rootPath + "\n" + job.major + "\n" + job.profile;
    char reportName[] = "report", rootName[] = "root";
    NativeChildProcess_Fd rootArgument{rootName, root.get(), nullptr};
    NativeChildProcess_Fd reportArgument{reportName, writeEnd.get(), &rootArgument};
    NativeChildProcess_Args args{const_cast<char*>(parameters.c_str()), {&reportArgument}};
    NativeChildProcess_Options options{NCP_ISOLATION_MODE_NORMAL, 0};
    int32_t child = -1;
    int started;
    {
        // SDK 文档规定退出回调在独立线程。启动期间持门锁，使极短子进程先等待 PID
        // 发布，避免它在 Start 返回前退出而丢失唯一的结束事件。
        std::lock_guard<std::mutex> guard(exitMutex);
        expectedPid = -1; exitObserved = false; exitSignal = 0;
        started = OH_Ability_StartNativeChildProcess("libentry.so:AmclJdkJavaQualificationMain", args, options, &child);
        if (!started) { expectedPid = child; childOwner.adopt(child); }
    }
    writeEnd = io::Fd();
    report << "{\"stage\":\"native-child-start\",\"result\":" << started << ",\"pid\":" << child << "}\n";
    if (started) return report.str();
    // Native-only没有安装/VM等待；总预算也限制10秒，覆盖阶段返回后的报告/退出收口。
    const auto deadline = Clock::now() + (nativeOnly ? std::chrono::seconds(10) : Timeout);
    auto nextTermination = deadline;
    bool timedOut = false, ended = false;
    const std::string nativePhase = job.profile + "-main";
    QualificationPhaseDeadline phaseDeadline(positiveCaptureProfile(job.profile) || nativeOnly,
                                              nativeOnly ? nativePhase.c_str() : "capture-main");
    int32_t signal = 0;
    size_t bytes = 0;
    for (;;) {
        pollfd pending{readEnd.get(), POLLIN | POLLHUP, 0};
        poll(&pending, 1, 50);
        char buffer[4096];
        ssize_t count;
        while ((count = read(readEnd.get(), buffer, sizeof(buffer))) > 0) {
            phaseDeadline.receive(buffer, static_cast<size_t>(count), Clock::now());
            if (bytes + static_cast<size_t>(count) <= 128 * 1024) report.write(buffer, count);
            bytes += static_cast<size_t>(count);
        }
        {
            std::lock_guard<std::mutex> guard(exitMutex);
            ended = exitObserved; signal = exitSignal;
        }
        if (ended) break;
        const auto now = Clock::now();
        if (!timedOut && phaseDeadline.expired(now)) nextTermination = now;
        if (now >= nextTermination) {
            timedOut = true;
            const int result = killChild(child);
            report << "{\"stage\":\"deadline-termination\",\"result\":" << result
                   << ",\"captureStageDeadline\":" << (!nativeOnly && phaseDeadline.expired(now) ? "true" : "false")
                   << ",\"nativeTempStageDeadline\":" << (nativeOnly && phaseDeadline.expired(now) ? "true" : "false") << "}\n";
            // 即使服务临时失败也不能回调为“已完成”；保留进程所有权并重试，直到 SDK
            // 给出该 PID 的真实退出事件。宿主可从阶段日志定位卡住的阶段。
            nextTermination = now + std::chrono::seconds(1);
        }
    }
    childOwner.exited();
    report << "{\"stage\":\"native-child-exit\",\"observed\":true,\"signal\":" << signal
           << ",\"timedOut\":" << (timedOut ? "true" : "false") << ",\"reportBytes\":" << bytes << "}\n";
    // 退出之后才回读最终收据。收据缺失、Java/Destroy/正常关闭证据不全均不能成为 PASS。
    try { report << "nativeReceipt=" << io::SmallFile(run.get(), "result.json", 65536) << '\n'; }
    catch (const std::exception& error) { report << "receiptError=" << quoted(error.what()) << '\n'; }
    const std::string result = report.str();
    writeNew(run.get(), "parent-report.txt", result);
    return result;
}

/** 共享工具在现有async worker完成安装/Create/main/Detach/Destroy，UI事件循环不等待。
 * 没有NCP API、pipe或内部kill；外部HDC监督必须绑定冷启动PID并在有界期限后收尾。
 * 正常返回只证明VM生命周期结束，应用进程仍在，不能冒称已收到子进程退出事件。
 */
std::string runShared(const Job& job) {
    io::Require(job.shared && (job.profile == "basic" || job.profile == "extended"), "共享资格仅允许basic/extended");
    io::Require(sharedProcessClaimed.load(std::memory_order_acquire) && jvmRuntimeState() == 0 &&
                jvmGetJavaVM() == nullptr, "共享资格必须使用已独占的Fresh主进程");
    char* canonical = realpath(job.files.c_str(), nullptr);
    io::Require(canonical != nullptr, "应用filesDir不存在");
    std::unique_ptr<char, decltype(&free)> ownedCanonical(canonical, &free);
    const std::string files(canonical);
    auto filesRoot = io::Directory(files);
    auto qualification = io::ChildDirectory(filesRoot.get(), "jdk-runtime-qualification");
    auto root = io::ChildDirectory(qualification.get(), job.nonce);
    const std::string rootPath = files + "/jdk-runtime-qualification/" + job.nonce;
    const std::string runName = qualificationRunName(job.major, job.profile);
    io::Require(mkdirat(root.get(), runName.c_str(), 0700) == 0, "共享资格目录已存在，必须使用新nonce");
    auto run = io::ChildDirectory(root.get(), runName);
    writeNew(run.get(), "qualification.jar", amcl::jdkqualification::FixtureJar, amcl::jdkqualification::FixtureJarSize);
    const std::string parameters = rootPath + "\n" + job.major + "\n" + job.profile;
    // 共享前置身份先于任何VM/stdio操作落盘，供外部监督绑定这次PID和实际安装/JAR输入。
    writeNew(run.get(), "shared-process.json", "{\"executionMode\":\"shared-tool\",\"pid\":" +
        std::to_string(getpid()) + ",\"major\":" + quoted(job.major) + ",\"profile\":" + quoted(job.profile) +
        ",\"nonce\":" + quoted(job.nonce) + ",\"fixtureSha256\":" + quoted(amcl::jdkqualification::FixtureJarSha256) +
        ",\"restartRequired\":true,\"externalSupervisorRequired\":true}\n");
    runQualification(parameters.c_str(), -1, root.get(), true);
    const std::string result = "{\"stage\":\"shared-process-complete\",\"pid\":" + std::to_string(getpid()) +
        ",\"executionMode\":\"shared-tool\",\"processExitObserved\":false,\"restartRequired\":true}\n" +
        "nativeReceipt=" + io::SmallFile(run.get(), "result.json", 128 * 1024) + "\n";
    writeNew(run.get(), "parent-report.txt", result);
    return result;
}

void execute(napi_env, void* data) {
    auto& job = *static_cast<Job*>(data);
    try { job.result = job.shared ? runShared(job) : runParent(job); }
    catch (const std::exception& error) {
        try { job.result = "qualificationError=" + quoted(error.what()) + "\n"; }
        catch (...) { job.result = "qualificationError=native failure; diagnostic allocation failed\n"; }
    }
    catch (...) { job.result = "qualificationError=unknown native exception\n"; }
}

/** 工作线程从不调用 NAPI；回到 VM 线程后只在有效局部 scope 内借回调、交付文本并释放 owner。 */
void complete(napi_env env, napi_status status, void* data) {
    std::unique_ptr<Job> job(static_cast<Job*>(data));
    napi_handle_scope scope{};
    if (napi_open_handle_scope(env, &scope) == napi_ok) {
        napi_value callback{}, receiver{}, text{}, ignored{};
        const char* result = status == napi_ok ? job->result.c_str() : "qualificationError=async work cancelled\n";
        if (napi_get_reference_value(env, job->callback, &callback) == napi_ok &&
            napi_get_undefined(env, &receiver) == napi_ok &&
            napi_create_string_utf8(env, result, NAPI_AUTO_LENGTH, &text) == napi_ok)
            napi_call_function(env, receiver, callback, 1, &text, &ignored);
        napi_close_handle_scope(env, scope);
    }
    napi_delete_reference(env, job->callback);
    napi_delete_async_work(env, job->work);
    if (job->pair) {
        // 两个PID退出前仍保留固定owner和busy；迟到exit排队到现有NAPI事件循环收尾。
        job->pair->exits.seal();
        job->pair->exits.releaseWorker();
    } else active.store(false, std::memory_order_release);
}
}

extern "C" __attribute__((visibility("default")))
void AmclJdkJavaQualificationMain(NativeChildProcess_Args args) {
    int pipe = -1, transferredRoot = -1;
    for (auto* item = args.fdList.head; item; item = item->next) {
        if (item->fdName && !strcmp(item->fdName, "report")) pipe = item->fd;
        if (item->fdName && !strcmp(item->fdName, "root")) transferredRoot = item->fd;
    }
    io::Fd pipeOwner(pipe), rootOwner(transferredRoot);
    if (pipe < 0 || transferredRoot < 0 || !args.entryParams) return;
    runQualification(args.entryParams, pipe, transferredRoot, false);
}

/** shared只复用工具语义，不设置/伪造NCP或fork身份；固定工具配置的实际作用是跳过游戏
 * classloader/LWJGL与watchdog，并让同一worker使用既有Detach→Destroy正常收尾。
 */
static void runQualification(const char* entryParameters, int pipe, int transferredRoot, bool shared) {
    amcl::jdkqualification::SharedQualificationStdio sharedStdio(shared);
    io::Fd run;
    std::unique_ptr<Report> report;
    int initResult = -999, mainResult = -999, destroyResult = -999, cfResult = -999, specialtyResult = -999;
    bool installComplete = false, completionProof = false;
    std::string major, profile, rootPath, archiveSha, error, nativeNonce;
    try {
        const std::string parameters(entryParameters);
        const size_t separator = parameters.find('\n');
        const size_t profileSeparator = separator == std::string::npos ? std::string::npos :
            parameters.find('\n', separator + 1);
        io::Require(separator != std::string::npos && profileSeparator != std::string::npos &&
                    parameters.find('\n', profileSeparator + 1) == std::string::npos,
                    "资格入口参数格式错误");
        rootPath = parameters.substr(0, separator);
        major = parameters.substr(separator + 1, profileSeparator - separator - 1);
        profile = parameters.substr(profileSeparator + 1);
        io::Require(validMajor(major) && validProfile(major, profile), "资格 JDK major/profile 无效");
        io::Require(!shared || profile == "basic" || profile == "extended", "共享资格拒绝非固定profile");
        const std::string marker = "/jdk-runtime-qualification/";
        const size_t position = rootPath.rfind(marker);
        io::Require(position != std::string::npos && rootPath.front() == '/' &&
                    validNonce(rootPath.substr(position + marker.size())), "资格根不在专属目录");
        auto openedRoot = io::Directory(rootPath);
        struct stat expected{}, actual{};
        io::Require(fstat(transferredRoot, &expected) == 0 && fstat(openedRoot.get(), &actual) == 0 &&
                    S_ISDIR(actual.st_mode) && expected.st_dev == actual.st_dev && expected.st_ino == actual.st_ino,
                    "资格根路径与传入目录 fd 不一致");
        run = io::ChildDirectory(transferredRoot, qualificationRunName(major, profile));
        report.reset(new Report(pipe, run.get()));
        report->line("{\"stage\":" + quoted(shared ? "shared-worker" : "child") + ",\"executionMode\":" +
            quoted(shared ? "shared-tool" : "native-child") + ",\"pid\":" + std::to_string(getpid()) + ",\"ppid\":" +
            std::to_string(getppid()) + ",\"runtimeState\":" + std::to_string(jvmRuntimeState()) + "}");
        io::Require(jvmRuntimeState() == 0 && jvmGetJavaVM() == nullptr, "资格进程不是Fresh JVM身份");
        if (profile == "native-file-times") {
            // 在任何JDK安装/ELF重定位前调用系统libc，才能与Java路径形成有效对照。
            nativeNonce = rootPath.substr(position + marker.size());
            report->stage("native-file-times-main");
            const auto observation = amcl::jdkqualification::RunNativeFileTimesQualification(transferredRoot, run.get(), rootPath);
            const auto hash = io::Digest(observation);
            report->line("{\"stage\":\"native-file-times-main-return\",\"result\":0}");
            writeNativeFileTimesCompletion(run.get(), report.get(), nativeNonce, hash, "");
            return;
        }
        if (profile == "native-temp") {
            // 固定OS观察在JAR校验、候选安装、任何VM或媒体操作之前返回。
            nativeNonce = rootPath.substr(position + marker.size());
            report->stage("native-temp-main");
            const std::string observation = amcl::jdkqualification::RunNativeTempQualification(
                transferredRoot, run.get(), rootPath);
            const std::string hash = io::Digest(observation);
            report->line("{\"stage\":\"native-temp-main-return\",\"result\":0}");
            report->line("{\"stage\":\"native-temp-observed\",\"reportSha256\":" + quoted(hash) + "}");
            writeNativeTempCompletion(run.get(), report.get(), nativeNonce, hash, "");
            return;
        }
        const std::string runPath = rootPath + "/run-" + major;
        const std::string logPath = runPath + "/stdout.log";
        io::Require(io::Digest(io::SmallFile(run.get(), "qualification.jar",
                    amcl::jdkqualification::FixtureJarSize + 1)) == amcl::jdkqualification::FixtureJarSha256,
                    "实际 Java 夹具 JAR 与内嵌身份不一致");
        amcl::jvm::PosixProcessorIo system;
        const auto setup = amcl::jvm::PrepareProcessorIo(shared ? nullptr : runPath.c_str(), logPath.c_str(), system);
        io::Require(setup.ok(), "资格 cwd/stdio 准备失败，errno=" + std::to_string(setup.error));
        // 独立NCP先取得官方缓存API的实际行为；探针自行恢复全部环境/CWD，失败时
        // 不允许污染后续VM。它不证明任意fresh exec拥有同样的应用Context。
        if (!shared) {
            const auto fontContext = amcl::jdkqualification::RunFontContextQualification(run.get());
            report->line("{\"stage\":\"font-context-observations\",\"reportSha256\":" +
                quoted(io::Digest(fontContext)) + "}");
        } else {
            // 该专项会清空环境并切换CWD，只适合独立NCP；共享进程不借它声称默认缓存资格。
            report->line("{\"stage\":\"font-context-observations\",\"status\":\"NOT-RUN\","
                "\"reason\":\"shared-process-global-environment\"}");
        }
        // 在加载任一候选JDK之前调用宿主真实libc，避免把旧chmod桥接的伪成功当平台能力。
        // 完整逐对象矩阵独占落盘；阶段流只绑定其SHA，外部根缺失仍在原报告中记NOT-RUN。
        const auto permissions = amcl::jdkqualification::RunPermissionQualification(
            transferredRoot, run.get(), rootPath, major);
        report->line("{\"stage\":\"permission-observations\",\"reportSha256\":" +
            quoted(io::Digest(permissions)) + "}");
        archiveSha = installCandidate(rootPath, transferredRoot, major, *report);
        installComplete = true;
        if (profile == "sound-capture-native" || profile == "sound-capture-layout" || profile == "sound-capture-startup" ||
            profile == "sound-capture-channels") {
            // 固定原生观察在加载JDK前运行：native/layout各200ms、startup单流1s保持。
            // channels另行授权且固定stereo-first/mono-second各200ms；不借startup授权扩大范围。
            // 全部复用capture-main的10秒父预算；仅OBSERVED，不授予音频保真。
            report->stage("capture-main");
            const bool layoutComparison = profile == "sound-capture-layout";
            const bool startupObservation = profile == "sound-capture-startup";
            const bool channelsObservation = profile == "sound-capture-channels";
            // 布局对照固定为MONO-first/default-second，除此之外全部是同一FAST格式。
            // 不接受Want指定layout/source或持续时间，也不把观察成功当成已修复。
            const auto observation = channelsObservation ?
                amcl::jdkqualification::RunCaptureChannelsQualification(run.get()) : startupObservation ?
                amcl::jdkqualification::RunCaptureStartupQualification(run.get()) : layoutComparison ?
                amcl::jdkqualification::RunCaptureLayoutQualification(run.get()) :
                amcl::jdkqualification::RunCaptureNativeQualification(run.get());
            specialtyResult = 0; // 该入口在任何SDK/期限/关闭失败时保存报告并抛异常。
            report->line("{\"stage\":\"capture-main-return\",\"result\":0,\"mode\":\"native-observation\"}");
            report->line("{\"stage\":" + quoted(channelsObservation ? "capture-channels-observed" : startupObservation ? "capture-startup-observed" :
                layoutComparison ? "capture-layout-observed" : "capture-native-observed") + ",\"reportSha256\":" +
                quoted(io::Digest(observation)) + "}");
        }
        if (profile == "sound-timing") {
            // 固定系统时钟观察在候选JDK加载之前运行，隔离系统API语义与Java后端算法。
            // OBSERVED仅表示观测完成；原始报告保存每个API返回值，绝不授予JavaSound播放资格。
            report->stage("audio-timing-observations");
            const auto timing = amcl::jdkqualification::RunAudioTimingQualification(run.get());
            report->line("{\"stage\":\"audio-timing-observations-return\",\"reportSha256\":" +
                quoted(io::Digest(timing)) + "}");
            specialtyResult = timing.find("{\"schema\":2,\"status\":\"OBSERVED\",") == 0 ? 0 : -1;
            io::Require(specialtyResult == 0, "音频时钟观察失败，查看独立原始报告");
        }
        if (profile == "font-defaults") {
            // 侧车只携带三份已审核SHA，所有实际路径均从本次已安装数字槽派生。
            // 绑定原ZIP摘要，防止另一个候选的provider身份被错误移用；不解析Want路径。
            const auto input = io::SmallFile(transferredRoot, "font-defaults-inputs.txt", 512);
            std::array<std::string, 4> values;
            size_t position = 0;
            for (auto& value : values) {
                const auto end = input.find('\n', position);
                io::Require(end != std::string::npos, "默认字体侧车缺少固定字段");
                value = input.substr(position, end - position); position = end + 1;
            }
            io::Require(position == input.size() && values[0] == "AMCL-FONT-DEFAULTS-1" &&
                values[1] == archiveSha && io::Hash(values[2]) && io::Hash(values[3]), "默认字体侧车身份不匹配");
            // 本调用链仍是fresh NCP，此前没有custom loader搜索状态。明确建立/恢复空状态，
            // 后面的生产jvmInit自行配置其路径；不在已经运行的VM或CF计时期间改变环境。
            elf_set_search_path("");
            report->stage("font-defaults");
            const bool qualified = amcl::jdkqualification::RunInstalledFontDefaultsQualification(
                run.get(), rootPath + "/jdk/" + major, major, values[2], values[3], "");
            specialtyResult = qualified ? 0 : -1;
            io::Require(qualified, "安装槽provider默认缓存资格失败，查看独立报告");
        }
        io::Require(setenv("AMCL_GAME_DIR", runPath.c_str(), 1) == 0, "无法设置资格工作目录");
        // NCP 是从系统创建的全新进程，不调用 jvmResetForForkChild。这里仅复用独立工具
        // 的参数选择和完整退出 API，不继承 fork_run_java 中尚待专项解除的 C1 限制。
        // 复用既有纯工具VM配置；shared的进程身份只由上方executionMode记录，不调用fork/NCP。
        jvmSetForkChildMode(1);
        jvmSetClasspath((runPath + "/qualification.jar").c_str());
        jvmSetXmx(256);
        jvmSetCrashOutputPath(logPath.c_str());
        std::vector<std::string> extraArgs{"-Xcheck:jni", "-XX:+PrintCompilation", "-Xms64m",
            "-Dsun.java2d.fontpath=/system/fonts", "-XX:ErrorFile=" + runPath + "/hs_err_pid%p.log"};
        if (cfProfile(profile)) {
            // 固定资格臂显式提供原v2规则，不能随着生产默认改变broad实验含义。
            // 8 full为空；现代full/C2-only仍保留既有受控BROAD→false组合及原JSON，
            // 这些仅属于TestHooks实验，普通产品自动策略绝不追加exclude=false。
            io::Require(jvmSetQualificationCfExplicit(1) == 0, "CF固定策略必须在Fresh工具进程设置");
            if (major != "8" || profile != "full") extraArgs.push_back(amcl::jvm::LegacyCfExclusion);
            extraArgs.push_back("-XX:+UnlockDiagnosticVMOptions");
            extraArgs.push_back("-XX:+LogCompilation");
            extraArgs.push_back("-XX:LogFile=" + runPath + "/compilation.xml");
            if (major != "8") {
                extraArgs.push_back("-XX:+CompilerDirectivesPrint");
                if (profile != "broad")
                    extraArgs.push_back("-XX:CompileCommand=exclude,java/util/concurrent/CompletableFuture.*,false");
                if (profile == "c2-only") {
                    writeNew(run.get(), "directives.json", amcl::jdkqualification::CfC2OnlyDirectives);
                    extraArgs.push_back("-XX:CompilerDirectivesFile=" + runPath + "/directives.json");
                }
            }
        }
        // 这些导出/反射权限只服务固定测试类，不进入普通产品公共参数，也不接收外部参数。
        if (major != "8" && extendedProfile(profile)) {
            extraArgs.push_back("--add-exports=java.base/sun.security.tools.keytool=ALL-UNNAMED");
            extraArgs.push_back("--add-opens=java.base/java.lang=ALL-UNNAMED");
        }
        if (profile == "extended-fork") extraArgs.push_back("-Djdk.lang.Process.launchMechanism=FORK");
        if (major != "8" && (soundProfile(profile) || captureProfile(profile) || profile == "native-sound-devices"))
            extraArgs.push_back("--add-opens=java.desktop/com.sun.media.sound=ALL-UNNAMED");
        jvmSetExtraArgsList(extraArgs);
        report->stage("jvm-init");
        std::string trustedAppFilesDir;
        io::Require(io::Exists(transferredRoot, "permission-roots.txt"), "缺少真实应用filesDir身份，不能用nonce根代替原生工具根");
        trustedAppFilesDir = amcl::jdkqualification::VerifiedPermissionSandbox(rootPath,
            amcl::jdkqualification::ParsePermissionRoots(io::SmallFile(transferredRoot, "permission-roots.txt", 8192)));
        // 只把已核fd身份的父根传给生产单owner，NCP不创建另一套TMPDIR/环境回滚。
        initResult = jvmInit(rootPath.c_str(), major.c_str(), nullptr,
            trustedAppFilesDir.c_str());
        report->line("{\"stage\":\"jvm-init-return\",\"result\":" + std::to_string(initResult) +
            ",\"status\":" + quoted(jvmGetStatus()) + "}");
        io::Require(initResult == 0, "jvmInit 失败");
        if (io::Exists(transferredRoot, "permission-roots.txt")) {
            const auto roots = amcl::jdkqualification::ParsePermissionRoots(
                io::SmallFile(transferredRoot, "permission-roots.txt", 8192));
            const std::string permissionNonce = "java-" + major + "-" + std::to_string(getpid());
            unsigned permissionIndex = 0;
            for (const auto& location : {roots.sandbox, roots.external}) {
                if (location.empty()) continue;
                // 同一真实VM观察Files.createTempFile、Java直接权限API与ZIPFS写回。
                // 精确errno对照仍由宿主结合native报告判断，任何对象/模式矛盾或ZIP失败
                // 都不得让本次整体夹具成功；未配置的外部根仍明确跳过而不伪造外部PASS。
                const std::string permissionReport = runPath + "/permission-java-" + std::to_string(permissionIndex++) + ".jsonl";
                const char* permissionArgs[] = {location.c_str(), permissionNonce.c_str(), permissionReport.c_str()};
                const int permissionResult = jvmCallMain("PermissionCopyProbe", 3, permissionArgs);
                report->line("{\"stage\":\"java-permission-observations\",\"root\":" + quoted(location) +
                    ",\"result\":" + std::to_string(permissionResult) + ",\"status\":" + quoted(jvmGetStatus()) +
                    ",\"permissionSemanticsQualified\":false}");
                io::Require(permissionResult == 0, "Java权限对象或ZIPFS写回验证失败: " + location);
            }
        }
        if (cfProfile(profile)) {
            const char* cfArguments[] = {runPath.c_str(), profile.c_str(), "4", "50000", "1000000", "1200"};
            report->stage("cf-main");
            cfResult = jvmCallMain("CompletableFutureQualification", 6, cfArguments);
            report->line("{\"stage\":\"cf-main-return\",\"profile\":" + quoted(profile) +
                ",\"result\":" + std::to_string(cfResult) + ",\"status\":" + quoted(jvmGetStatus()) + "}");
            io::Require(cfResult == 0, "CF工作量或内部进展验证失败");
        }
        if (profile == "process-java") {
            // 此固定专项使用真实默认机制及有界直接child，不追加FORK或任意Want参数。
            // 流字节/退出/回收/完成SHA由宿主独立验证器复核，main返回后仍执行VM退出夹具。
            const char* processArguments[] = {runPath.c_str(), major.c_str()};
            report->stage("process-java-main");
            specialtyResult = jvmCallMain("JavaProcessQualification", 2, processArguments);
            report->line("{\"stage\":\"process-java-return\",\"result\":" + std::to_string(specialtyResult) +
                ",\"status\":" + quoted(jvmGetStatus()) + "}");
            io::Require(specialtyResult == 0, "ProcessBuilder数据/退出/取消专项失败，查看独立结果");
            // 本夹具无论成功失败都会正常返回并留下完成记录，因此不能只检查JNI返回值。
            // 固定协议把passed=true和同一原始result字节摘要绑定；流/语义仍由独立宿主核验。
            requireProcessCompletion(run.get());
        }
        if (extendedProfile(profile)) {
            const char* toolArguments[] = {runPath.c_str(), major.c_str()};
            report->stage("extended-main");
            specialtyResult = jvmCallMain("ExtendedRuntimeQualification", 2, toolArguments);
            report->line("{\"stage\":\"extended-main-return\",\"result\":" + std::to_string(specialtyResult) +
                ",\"status\":" + quoted(jvmGetStatus()) + "}");
            io::Require(specialtyResult == 0, "工具/网络/TLS/JFR专项有未通过项，查看独立结果");
        }
        if (soundProfile(profile)) {
            const char* mode = profile == "sound-playback" ? "playback" : "software";
            const char* soundArguments[] = {runPath.c_str(), major.c_str(), mode};
            report->stage("sound-main");
            specialtyResult = jvmCallMain("JavaSoundQualification", 3, soundArguments);
            report->line("{\"stage\":\"sound-main-return\",\"result\":" + std::to_string(specialtyResult) +
                ",\"mode\":" + quoted(mode) + ",\"status\":" + quoted(jvmGetStatus()) + "}");
            io::Require(specialtyResult == 0, "JavaSound所选范围未通过，软件PASS不能代替PCM播放");
            io::Require(io::SmallFile(run.get(), "java-sound-complete.txt", 256) ==
                "JAVA-SOUND:" + major + ":" + mode + "\n", "JavaSound完成范围标记不一致");
        }
        if (captureProfile(profile)) {
            const bool diagnostic = profile == "sound-capture-diagnostic";
            const char* mode = profile == "sound-capture-denied" ? "denied" :
                diagnostic ? "diagnostic" : "capture";
            const char* captureArguments[] = {runPath.c_str(), major.c_str(), mode};
            // 只对显式诊断profile选用正常HAP中的typed统计回调；不创建流、不申请权限。
            // Java仍只读取两段各200ms，main返回时finally已关闭line，才可收口回调统计。
            if (diagnostic) amcl::jdkqualification::BeginCaptureDiagnostic();
            report->stage("capture-main");
            specialtyResult = jvmCallMain("JavaSoundCaptureQualification", 3, captureArguments);
            report->line("{\"stage\":\"capture-main-return\",\"result\":" + std::to_string(specialtyResult) +
                ",\"mode\":" + quoted(mode) + ",\"status\":" + quoted(jvmGetStatus()) + "}");
            if (diagnostic) {
                // 即使Java专项失败也先保留实际观测。正文独占落盘并绑定SHA，OBSERVED不授予
                // 音频保真资格，是否同一前缀仍由独立宿主比较回调与Java的真实计数决定。
                const std::string observation = amcl::jdkqualification::FinishCaptureDiagnostic(run.get());
                report->line("{\"stage\":\"capture-diagnostic-observed\",\"sha256\":" +
                    quoted(io::Digest(observation)) + "}");
            }
            io::Require(specialtyResult == 0, "JavaSound输入专项失败，查看阶段记录");
            io::Require(io::SmallFile(run.get(), "java-sound-capture-complete.txt", 256) ==
                "JAVA-SOUND-CAPTURE:" + major + ":" + mode + "\n", "JavaSound输入完成范围不一致");
        }
        if (profile == "native-sound-devices") {
            // MIDI仅枚举；Ports打开仅取得真实设备快照，不请求Capture或发送任何MIDI事件。
            const char* deviceArguments[] = {runPath.c_str(), major.c_str()};
            report->stage("native-sound-devices-main");
            specialtyResult = jvmCallMain("NativeSoundDevicesQualification", 2, deviceArguments);
            report->line("{\"stage\":\"native-sound-devices-return\",\"result\":" + std::to_string(specialtyResult) +
                ",\"status\":" + quoted(jvmGetStatus()) + "}");
            io::Require(specialtyResult == 0, "原生MIDI枚举/Ports只读观察失败");
            requireSoundDevicesCompletion(run.get(), major);
        }
        // 专项之后仍执行既有生命周期夹具，独立证明worker及shutdown hook被正常等待。
        const char* arguments[] = {runPath.c_str(), major.c_str(), "AMCL 中文 \xf0\x9f\x98\x80"};
        report->stage("java-main");
        mainResult = jvmCallMain("RuntimeQualification", 3, arguments);
        report->line("{\"stage\":\"java-main-return\",\"result\":" + std::to_string(mainResult) +
            ",\"status\":" + quoted(jvmGetStatus()) + "}");
        writeNew(run.get(), "destroy-started.txt", "native-main-returned\n");
        report->stage("destroy-java-vm");
        destroyResult = jvmFinishProcessor();
        report->line("{\"stage\":\"destroy-java-vm-return\",\"result\":" + std::to_string(destroyResult) +
            ",\"status\":" + quoted(jvmGetStatus()) + "}");
        const std::string token = "AMCL-JAVA-QUALIFICATION:1:" + major + "\n";
        if (mainResult == 0 && destroyResult == 0) {
            completionProof = io::SmallFile(run.get(), "fixture-pass.txt", 256) == token &&
                io::SmallFile(run.get(), "main-thread-ended.txt", 256) == token &&
                io::SmallFile(run.get(), "non-daemon.txt", 256) == token &&
                io::SmallFile(run.get(), "shutdown-hook.txt", 256) == token;
            io::Require(completionProof, "main/非 daemon/shutdown hook 完成文件不一致");
        }
    } catch (const std::exception& exception) { error = exception.what(); }
    catch (...) { error = "未知 native 资格异常"; }
    if (profile == "native-file-times") {
        try { writeNativeFileTimesCompletion(run.get(), report.get(), nativeNonce, "", error); }
        catch (...) { /* 原始错误已保留于阶段文件，不能因诊断报告失败继续进入Java路径。 */ }
        return;
    }
    if (profile == "native-temp") {
        // 失败也保留独立native-only收据；不进入任何Java清理或伪造Java返回值。
        try { writeNativeTempCompletion(run.get(), report.get(), nativeNonce, "", error); }
        catch (...) {
            static constexpr char failure[] = "{\"stage\":\"native-temp-receipt-failed\"}\n";
            const ssize_t ignored = write(pipe, failure, sizeof(failure) - 1); (void)ignored;
        }
        return;
    }
    // 初始化之后任意报告/文件异常也要释放等待中的合法 Java worker，再按生产协议退出。
    // Destroy 已尝试失败则不隐式重试；原始返回值与剩余 VM 身份保存在收据中。
    if (jvmGetJavaVM() && jvmRuntimeState() == 2 && destroyResult == -999) {
        try {
            if (run.get() >= 0 && !io::Exists(run.get(), "destroy-started.txt"))
                writeNew(run.get(), "destroy-started.txt", "native-error-cleanup\n");
            destroyResult = jvmFinishProcessor();
        } catch (...) { if (error.empty()) error = "JVM 错误清理未完成"; }
    }
    const int stdioRestoreError = sharedStdio.restore();
    if (stdioRestoreError && error.empty()) error = "共享资格stdio恢复失败: " + std::to_string(stdioRestoreError);
    try {
        const bool passed = error.empty() && installComplete && initResult == 0 && mainResult == 0 &&
            destroyResult == 0 && completionProof && jvmGetJavaVM() == nullptr &&
            (profile == "basic" || (cfProfile(profile) ? cfResult == 0 : specialtyResult == 0));
        const std::string receipt = "{\"schema\":1,\"executionMode\":" + quoted(shared ? "shared-tool" : "native-child") +
            ",\"runtimeState\":" + std::to_string(jvmRuntimeState()) + ",\"javaVmPresent\":" +
            (jvmGetJavaVM() ? "true" : "false") + ",\"stdioRestored\":" + (stdioRestoreError == 0 ? "true" : "false") + ",\"major\":" + quoted(major) + ",\"pid\":" +
            std::to_string(getpid()) + ",\"archiveSha256\":" + quoted(archiveSha) +
            ",\"fixtureSha256\":" + quoted(amcl::jdkqualification::FixtureJarSha256) +
            ",\"profile\":" + quoted(profile) + ",\"cfResult\":" + std::to_string(cfResult) +
            ",\"specialtyResult\":" + std::to_string(specialtyResult) +
            ",\"installComplete\":" + (installComplete ? "true" : "false") +
            ",\"initResult\":" + std::to_string(initResult) + ",\"mainResult\":" + std::to_string(mainResult) +
            ",\"destroyResult\":" + std::to_string(destroyResult) + ",\"completionProof\":" +
            (completionProof ? "true" : "false") + ",\"passed\":" + (passed ? "true" : "false") +
            ",\"error\":" + quoted(error) + "}\n";
        if (run.get() >= 0) writeNew(run.get(), "result.json", receipt);
        if (report) report->line(receipt);
    } catch (...) {
        static constexpr char failure[] = "{\"stage\":\"receipt-write-failed\",\"passed\":false}\n";
        const ssize_t ignored = write(pipe, failure, sizeof(failure) - 1); (void)ignored;
    }
    fflush(stdout); fflush(stderr);
    // NCP返回官方入口后由系统结束，父任务另等真实退出；shared仅返回worker，由HDC监督
    // 收回证据后重启整个应用。两者都不能从本函数返回值推测OS进程exit code。
}

extern "C" __attribute__((visibility("default")))
void AmclJdkNativeTempVmMain(NativeChildProcess_Args args) { runNativeTempPairChild(args); }

bool JdkSharedQualificationRestartRequired() noexcept {
    return sharedProcessClaimed.load(std::memory_order_acquire);
}

napi_value RunJdkJavaQualificationNapi(napi_env env, napi_callback_info info) try {
    napi_value unused{}; napi_get_undefined(env, &unused);
    size_t count = 5;
    napi_value args[5]{}, resource{};
    if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != 5) {
        napi_throw_type_error(env, "JDK_JAVA_ARGS", "需要 filesDir、nonce、major、固定profile和完成回调"); return unused;
    }
    napi_valuetype type;
    if (napi_typeof(env, args[4], &type) != napi_ok || type != napi_function) {
        napi_throw_type_error(env, "JDK_JAVA_CALLBACK", "完成回调必须是函数"); return unused;
    }
    std::unique_ptr<Job> job(new Job);
    job->result.reserve(16384);
    if (!amcl::napi::ReadStringValue(env, args[0], job->files) || job->files.empty() || job->files[0] != '/' ||
        job->files.find('\0') != std::string::npos || job->files.find('\n') != std::string::npos ||
        !amcl::napi::ReadStringValue(env, args[1], job->nonce) || !validNonce(job->nonce) ||
        !amcl::napi::ReadStringValue(env, args[2], job->major) || !validMajor(job->major) ||
        !amcl::napi::ReadStringValue(env, args[3], job->profile) ||
        (!validProfile(job->major, job->profile) && !sharedProfile(job->profile)) ||
        ((job->profile == "native-temp" || job->profile == "native-temp-vms") && !amcl::nativetempprobe::ValidNonce(job->nonce))) {
        napi_throw_type_error(env, "JDK_JAVA_INPUT", "filesDir、nonce、major或profile无效"); return unused;
    }
    if (sharedProcessClaimed.load(std::memory_order_acquire)) {
        napi_throw_error(env, "JDK_SHARED_RESTART_REQUIRED", "本进程已受理共享资格，请重启AMCL后再运行"); return unused;
    }
    job->shared = sharedProfile(job->profile);
    if (job->shared && amcl::napi::RejectGraphicsSemanticsJvmStart(env)) return unused;
    if (job->shared && (jvmRuntimeState() != 0 || jvmGetJavaVM() != nullptr || mcIsRunning())) {
        napi_throw_error(env, "JDK_SHARED_NOT_FRESH", "共享资格只允许未启动游戏或JVM的冷进程"); return unused;
    }
    if (job->shared) job->profile = job->profile.substr(7); // 只规范化已通过固定白名单的前缀。
    if (active.exchange(true, std::memory_order_acq_rel)) {
        napi_throw_error(env, "JDK_JAVA_BUSY", "已有 Java 资格子进程尚未结束"); return unused;
    }
    // JS线程同步受理后立即封住既有普通JVM/游戏NAPI入口；异步排队失败仍要求重启。
    if (job->shared) sharedProcessClaimed.store(true, std::memory_order_release);
    napi_status status = napi_create_reference(env, args[4], 1, &job->callback);
    if (status == napi_ok) status = napi_create_string_utf8(env, "JdkJavaQualification", NAPI_AUTO_LENGTH, &resource);
    if (status == napi_ok && job->profile == "native-temp-vms") status = prepareNativeTempPair(env, resource, *job);
    if (status == napi_ok) status = napi_create_async_work(env, nullptr, resource, execute, complete, job.get(), &job->work);
    if (status == napi_ok) status = napi_queue_async_work(env, job->work);
    if (status != napi_ok) {
        cancelUnstartedNativeTempPair(env, *job);
        if (job->work) napi_delete_async_work(env, job->work);
        if (job->callback) napi_delete_reference(env, job->callback);
        active.store(false, std::memory_order_release);
        napi_throw_error(env, "JDK_JAVA_QUEUE", "无法提交 Java 资格任务");
    } else job.release(); // 完成回调成为引用、async work 和 Job 的唯一所有者。
    return unused;
} catch (...) {
    napi_throw_error(env, "JDK_JAVA_PREPARE", "无法准备 Java 资格任务");
    return nullptr;
}
#endif
