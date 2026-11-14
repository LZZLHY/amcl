/**
 * 固定 NativeChildProcess 退出矩阵：区分 SDK 文档契约、公开源码中的混合数值与商业设备
 * 实际回调。不将 signal=0 当作一般 exit(0) 证明，也不把某个数值擅自解释成信号或状态码。
 * 每个动作独占新 NCP，写入/fsync 本轮 marker 后才执行；真实结束由官方退出事件确认。
 */
#include "jdk_process_qualification.h"
#ifdef MC_OHOS_BUILD_TESTS
#include "napi_helpers.h"
#include "../platform/jdk_install_io.h"
#include "../jvm/processor_exec_probe.h"
#include "../../../../../tests/runtime-childproc/fd_probe.hpp"
#include <AbilityKit/native_child_process.h>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <dirent.h>
#include <memory>
#include <mutex>
#include <poll.h>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

extern "C" __attribute__((visibility("default")))
void AmclJdkProcessQualificationMain(NativeChildProcess_Args args);

namespace {
namespace io = amcl::jdk::io;
using Clock = std::chrono::steady_clock;
using KillChild = Ability_NativeChildProcess_ErrCode (*)(int32_t);
std::atomic<bool> active{false};
std::mutex exitMutex;
int32_t expectedPid = -1, callbackSignal = 0;
bool exitObserved = false;

/** 输入只能选择编译期固定动作，既不能指定路径，也不能编码任意 signal/exit 数值。 */
struct Mode { const char* name; int code; int signal; bool returns; };
const Mode modes[] = {{"return", 0, 0, true}, {"exit0", 0, 0, false}, {"exit7", 7, 0, false},
    {"exit255", 255, 0, false}, {"sigterm", -1, SIGTERM, false}, {"sigbus", -1, SIGBUS, false}};
// 在原六动作之后单独执行；其真实posix_spawn/wait记录不混入SDK回调退出类型。
const Mode execRoutesMode{"exec-routes", 0, 0, true};
// 独立固定FD清理候选：内部只fork syscall/POD child，不加载JDK、不接受动态程序路径。
const Mode fdCleanupMode{"fd-cleanup", 0, 0, true};
const Mode* modeFor(const char* name) {
    if (!name) return nullptr;
    for (const auto& mode : modes) if (!strcmp(name, mode.name)) return &mode;
    if (!strcmp(name, execRoutesMode.name)) return &execRoutesMode;
    if (!strcmp(name, fdCleanupMode.name)) return &fdCleanupMode;
    return nullptr;
}
bool validNonce(const std::string& nonce) {
    return !nonce.empty() && nonce.size() <= 80 &&
        nonce.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_") == std::string::npos;
}
/** 只读记录全新NCP在用户动作前的实际线程数，用于比较后续干净进程实现。
 * 一次快照不构成单线程平台合同，也不授权在未知线程状态下fork；读失败保留errno。
 */
struct ThreadObservation { unsigned count = 0; int error = 0; };
ThreadObservation observeThreads() {
    ThreadObservation result;
    DIR* tasks = opendir("/proc/self/task");
    if (!tasks) { result.error = errno; return result; }
    for (;;) {
        errno = 0;
        const dirent* item = readdir(tasks);
        if (!item) { result.error = errno; break; }
        const char* name = item->d_name;
        bool numeric = name[0] != '\0';
        for (const char* cursor = name; *cursor; ++cursor)
            numeric = numeric && *cursor >= '0' && *cursor <= '9';
        if (numeric) ++result.count;
    }
    if (closedir(tasks) != 0 && !result.error) result.error = errno;
    return result;
}
std::string quoted(const std::string& text) {
    const char digits[] = "0123456789abcdef";
    std::string result = "\"";
    for (unsigned char c : text) {
        if (c == '\\' || c == '"') { result += '\\'; result += static_cast<char>(c); }
        else if (c < 32) { result += "\\u00"; result += digits[c >> 4]; result += digits[c & 15]; }
        else result += static_cast<char>(c);
    }
    return result + '"';
}

/** 同 Java 资格通道的已核查找协议；暂独立保留，避免并行集成修改正在冻结的公共文件。 */
struct ProviderLookup {
    int (*address)(const void*, Dl_info*) = dladdr;
    void* (*open)(const char*, int) = dlopen;
    void* (*symbol)(void*, const char*) = dlsym;
    int (*close)(void*) = dlclose;
    char* (*error)() = dlerror;
};
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
        io::Require(lookup.address(reinterpret_cast<const void*>(&OH_Ability_StartNativeChildProcess), &start) &&
            start.dli_fname && start.dli_fname[0] && start.dli_fbase, "无法核实 NCP Start 提供者");
        path_ = start.dli_fname;
        handle_.close = lookup.close;
        lookup.error();
        handle_.value = lookup.open(path_.c_str(), RTLD_NOW | RTLD_NOLOAD);
        if (!handle_.value) handle_.value = lookup.open("libchild_process.so", RTLD_NOW | RTLD_NOLOAD);
        io::Require(handle_.value != nullptr, "无法打开已加载 NCP 提供者");
        lookup.error();
        void* address = lookup.symbol(handle_.value, "OH_Ability_KillChildProcess");
        const char* detail = lookup.error();
        io::Require(address && !detail, "已加载 NCP 提供者没有终止接口");
        Dl_info target{};
        io::Require(lookup.address(address, &target) && target.dli_fbase == start.dli_fbase,
                    "NCP 终止接口不属于 Start 提供者");
        function_ = reinterpret_cast<KillChild>(address);
    }
    ChildProcessProvider(const ChildProcessProvider&) = delete;
    ChildProcessProvider& operator=(const ChildProcessProvider&) = delete;
    KillChild function() const noexcept { return function_; }
    const std::string& path() const noexcept { return path_; }
};

void childExit(int32_t pid, int32_t signal) {
    std::lock_guard<std::mutex> guard(exitMutex);
    if (pid == expectedPid) { callbackSignal = signal; exitObserved = true; }
}
/** 启动成功之后的任意父侧异常先终止并等待退出，不能注销回调后遗留孤立测试进程。 */
class ChildOwner {
    KillChild terminate_;
    int32_t pid_ = -1;
public:
    explicit ChildOwner(KillChild terminate) : terminate_(terminate) {}
    void adopt(int32_t pid) noexcept { pid_ = pid; }
    void exited() noexcept { pid_ = -1; }
    ~ChildOwner() {
        if (pid_ < 0) return;
        auto next = Clock::now();
        for (;;) {
            { std::lock_guard<std::mutex> guard(exitMutex); if (exitObserved && expectedPid == pid_) return; }
            const auto now = Clock::now();
            if (now >= next) { terminate_(pid_); next = now + std::chrono::seconds(1); }
            poll(nullptr, 0, 50);
        }
    }
};

/** marker 与最终父报告均新建并同步，拒绝复用历史结果；不修改任何 JDK/用户游戏内容。 */
void writeNew(int directory, const std::string& name, const std::string& text) {
    io::Fd file(openat(directory, name.c_str(), O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC, 0600));
    if (file.get() < 0) io::Error("退出矩阵文件已存在或不可创建");
    io::Write(file.get(), text.data(), text.size()); io::Sync(file.get()); io::Sync(directory);
}

/** 一次固定动作对应一个独立管道和 NCP；回调退出和 marker 分别记录，互不代替。 */
std::string runMode(int root, const Mode& mode, KillChild terminate) {
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC | O_NONBLOCK) != 0) io::Error("无法创建退出矩阵管道");
    io::Fd input(pipefd[0]), output(pipefd[1]);
    ChildOwner owner(terminate);
    char rootName[] = "root", reportName[] = "report";
    NativeChildProcess_Fd rootArgument{rootName, root, nullptr};
    NativeChildProcess_Fd reportArgument{reportName, output.get(), &rootArgument};
    NativeChildProcess_Args args{const_cast<char*>(mode.name), {&reportArgument}};
    NativeChildProcess_Options options{NCP_ISOLATION_MODE_NORMAL, 0};
    int32_t child = -1;
    int started;
    const auto deadline = Clock::now() + std::chrono::seconds(
        !strcmp(mode.name, fdCleanupMode.name) ? 25 : !strcmp(mode.name, execRoutesMode.name) ? 20 : 10);
    {
        // 官方回调在独立线程运行；门锁保证极短动作退出前发布其实际 PID，不丢事件。
        std::lock_guard<std::mutex> guard(exitMutex);
        expectedPid = -1; exitObserved = false; callbackSignal = 0;
        started = OH_Ability_StartNativeChildProcess("libentry.so:AmclJdkProcessQualificationMain", args, options, &child);
        if (!started) { expectedPid = child; owner.adopt(child); }
    }
    output = io::Fd();
    bool ended = false, forced = false, overflow = false;
    int32_t signal = 0;
    int killResult = -999;
    std::string reportBytes;
    auto nextTermination = deadline;
    if (!started) {
        for (;;) {
            pollfd pending{input.get(), POLLIN | POLLHUP, 0};
            poll(&pending, 1, 20);
            char bytes[512]; ssize_t count;
            while ((count = read(input.get(), bytes, sizeof(bytes))) > 0) {
                if (reportBytes.size() + static_cast<size_t>(count) <= 4096) reportBytes.append(bytes, static_cast<size_t>(count));
                else overflow = true;
            }
            { std::lock_guard<std::mutex> guard(exitMutex); ended = exitObserved; signal = callbackSignal; }
            if (ended) break;
            const auto now = Clock::now();
            if (now >= nextTermination) {
                forced = true;
                killResult = terminate(child);
                nextTermination = now + std::chrono::seconds(1);
            }
            // 管道已关闭而系统回调稍晚时，POLLHUP 会立即返回；留出短等待避免空转。
            if (pending.revents & POLLHUP) poll(nullptr, 0, 20);
        }
        owner.exited();
    }
    std::string marker, markerError;
    try { marker = io::SmallFile(root, std::string(mode.name) + ".marker.json", 4096); }
    catch (const std::exception& error) { markerError = error.what(); }
    std::ostringstream line;
    line << "{\"requestedMode\":" << quoted(mode.name) << ",\"requestedExitCode\":"
         << ((mode.signal || mode.returns) ? "null" : std::to_string(mode.code)) << ",\"requestedSignal\":"
         << (mode.signal ? std::to_string(mode.signal) : "null") << ",\"startResult\":" << started
         << ",\"childPid\":" << child << ",\"callbackObserved\":" << (ended ? "true" : "false")
         << ",\"callbackSignal\":" << (ended ? std::to_string(signal) : "null")
         << ",\"exitKind\":\"unclassified\",\"forcedTermination\":" << (forced ? "true" : "false")
         << ",\"killResult\":" << (forced ? std::to_string(killResult) : "null")
         << ",\"actualChildMarker\":" << quoted(marker) << ",\"markerError\":" << quoted(markerError)
         << ",\"pipeReport\":" << quoted(reportBytes) << ",\"pipeOverflow\":" << (overflow ? "true" : "false") << '}';
    const std::string result = line.str();
    // exec模式的NCP退出观察与应用父进程的exec路线观测是不同产物，不能共用O_EXCL文件名。
    const std::string observationFile = !strcmp(mode.name, execRoutesMode.name)
        ? "exec-routes.ncp-exit.json" : !strcmp(mode.name, fdCleanupMode.name)
        ? "fd-cleanup.ncp-exit.json" : std::string(mode.name) + ".parent.json";
    writeNew(root, observationFile, result + "\n");
    return result;
}

struct Job { napi_async_work work{}; napi_ref callback{}; std::string files, nonce, result; };
std::string runParent(const Job& job) {
    ChildProcessProvider provider; // 最后析构，覆盖原六动作及两个独立资格动作owner的完整寿命。
    char* canonical = realpath(job.files.c_str(), nullptr);
    io::Require(canonical != nullptr, "filesDir 不存在");
    std::unique_ptr<char, decltype(&free)> owned(canonical, &free);
    auto files = io::Directory(canonical);
    auto parent = io::ChildDirectory(files.get(), "jdk-process-qualification", true);
    io::Require(mkdirat(parent.get(), job.nonce.c_str(), 0700) == 0, "nonce 已存在，不能复用退出矩阵");
    auto root = io::ChildDirectory(parent.get(), job.nonce);
    const int registered = OH_Ability_RegisterNativeChildProcessExitCallback(childExit);
    io::Require(registered == 0, "NCP 退出回调注册失败");
    struct CallbackOwner { ~CallbackOwner() { OH_Ability_UnregisterNativeChildProcessExitCallback(childExit); } } callback;
    std::ostringstream report;
    report << "{\"schema\":1,\"kind\":\"NativeChildProcessExitObservation\",\"parentPid\":" << getpid()
           << ",\"provider\":" << quoted(provider.path()) << ",\"observations\":[";
    bool first = true;
    for (const auto& mode : modes) {
        if (!first) report << ',';
        report << runMode(root.get(), mode, provider.function());
        first = false;
    }
    report << "],\"execNcpExitObservation\":" << runMode(root.get(), execRoutesMode, provider.function());
    // 两个上下文分别运行同一固定路线；主进程与NCP的许可不能互借，更不能外推到手机/API20。
    const auto nativeEntry = reinterpret_cast<const void*>(&AmclJdkProcessQualificationMain);
    const std::string parentExec = amcl::jvm::execprobe::run(nativeEntry, "application-parent");
    writeNew(root.get(), "exec-routes.application-parent.json", parentExec);
    report << ",\"execParent\":" << parentExec;
    try {
        const std::string childExec = io::SmallFile(root.get(), "exec-routes.child.json", 65536);
        report << ",\"execNcp\":" << childExec;
    }
    catch (const std::exception& error) { report << ",\"execNcpError\":" << quoted(error.what()); }
    // FD候选自身的真实waitpid结果保存在子报告；外层SDK callback仍保持unclassified。
    report << ",\"fdCleanupNcpExitObservation\":" << runMode(root.get(), fdCleanupMode, provider.function());
    try {
        const std::string childFd = io::SmallFile(root.get(), "fd-cleanup.child.json", 65536);
        report << ",\"fdCleanup\":" << childFd;
    }
    catch (const std::exception& error) { report << ",\"fdCleanupError\":" << quoted(error.what()); }
    report << "}\n";
    const std::string result = report.str();
    writeNew(root.get(), "parent-report.json", result);
    return result;
}
void execute(napi_env, void* data) {
    auto& job = *static_cast<Job*>(data);
    try { job.result = runParent(job); }
    catch (const std::exception& error) {
        try { job.result = "{\"probeError\":" + quoted(error.what()) + "}\n"; }
        catch (...) { job.result = "{\"probeError\":\"native error; report allocation failed\"}\n"; }
    }
    catch (...) { job.result = "{\"probeError\":\"unknown native error\"}\n"; }
}
void complete(napi_env env, napi_status status, void* data) {
    std::unique_ptr<Job> job(static_cast<Job*>(data));
    napi_handle_scope scope{};
    if (napi_open_handle_scope(env, &scope) == napi_ok) {
        napi_value callback{}, receiver{}, text{}, ignored{};
        const char* result = status == napi_ok ? job->result.c_str() : "{\"probeError\":\"async cancelled\"}\n";
        if (napi_get_reference_value(env, job->callback, &callback) == napi_ok && napi_get_undefined(env, &receiver) == napi_ok &&
            napi_create_string_utf8(env, result, NAPI_AUTO_LENGTH, &text) == napi_ok)
            napi_call_function(env, receiver, callback, 1, &text, &ignored);
        napi_close_handle_scope(env, scope);
    }
    napi_delete_reference(env, job->callback); napi_delete_async_work(env, job->work);
    active.store(false, std::memory_order_release);
}
}

extern "C" __attribute__((visibility("default")))
void AmclJdkProcessQualificationMain(NativeChildProcess_Args args) {
    int root = -1, pipe = -1;
    for (auto* fd = args.fdList.head; fd; fd = fd->next) {
        if (fd->fdName && !strcmp(fd->fdName, "root")) root = fd->fd;
        if (fd->fdName && !strcmp(fd->fdName, "report")) pipe = fd->fd;
    }
    io::Fd rootOwner(root), pipeOwner(pipe);
    const Mode* mode = modeFor(args.entryParams);
    if (root < 0 || pipe < 0 || !mode) return;
    try {
        struct stat directory{};
        io::Require(fstat(root, &directory) == 0 && S_ISDIR(directory.st_mode), "marker 根不是目录");
        int setupError = 0;
        if (mode->signal) {
            struct sigaction action{};
            action.sa_handler = SIG_DFL;
            sigemptyset(&action.sa_mask);
            if (sigaction(mode->signal, &action, nullptr) != 0) setupError = errno;
            sigset_t unblocked; sigemptyset(&unblocked); sigaddset(&unblocked, mode->signal);
            if (!setupError && sigprocmask(SIG_UNBLOCK, &unblocked, nullptr) != 0) setupError = errno;
        }
        // marker 只证明实际 child 已到达动作前，不伪造“动作已经完成”或最终退出状态。
        const auto threads = observeThreads();
        const std::string marker = "{\"requestedMode\":" + quoted(mode->name) + ",\"pid\":" +
            std::to_string(getpid()) + ",\"ppid\":" + std::to_string(getppid()) +
            ",\"stage\":\"before-action\",\"signalSetupErrno\":" + std::to_string(setupError) +
            ",\"observedThreadCount\":" + std::to_string(threads.count) +
            ",\"threadObservationErrno\":" + std::to_string(threads.error) + "}\n";
        writeNew(root, std::string(mode->name) + ".marker.json", marker);
        io::Write(pipe, marker.data(), marker.size());
        if (!strcmp(mode->name, execRoutesMode.name)) {
            const auto entry = reinterpret_cast<const void*>(&AmclJdkProcessQualificationMain);
            writeNew(root, "exec-routes.child.json", amcl::jvm::execprobe::run(entry, "native-child-process"));
            return;
        }
        if (!strcmp(mode->name, fdCleanupMode.name)) {
            writeNew(root, "fd-cleanup.child.json", amcl::childfdprobe::run());
            return;
        }
        if (setupError || mode->returns) return;
        if (!mode->signal) _exit(mode->code);
        // 只给本进程发送两个固定信号。保留平台特殊信号链的实际处理结果；SDK 若最终
        // 报告另一数值，父报告如实记录，不用源代码里“请求了 SIGBUS”强改观察结果。
        const int sent = kill(getpid(), mode->signal);
        const int error = sent ? errno : 0;
        const std::string returned = "{\"stage\":\"signal-action-returned\",\"sendErrno\":" + std::to_string(error) + "}\n";
        io::Write(pipe, returned.data(), returned.size());
        writeNew(root, std::string(mode->name) + ".returned.json", returned);
    } catch (...) {
        const char error[] = "{\"stage\":\"child-preparation-failed\"}\n";
        const ssize_t ignored = write(pipe, error, sizeof(error) - 1); (void)ignored;
    }
}

napi_value RunJdkProcessQualificationNapi(napi_env env, napi_callback_info info) try {
    napi_value unused{}; napi_get_undefined(env, &unused);
    size_t count = 3; napi_value args[3]{}, resource{};
    if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != 3) {
        napi_throw_type_error(env, "JDK_PROCESS_ARGS", "需要 filesDir、nonce 与回调"); return unused;
    }
    napi_valuetype type;
    if (napi_typeof(env, args[2], &type) != napi_ok || type != napi_function) {
        napi_throw_type_error(env, "JDK_PROCESS_CALLBACK", "完成回调必须是函数"); return unused;
    }
    std::unique_ptr<Job> job(new Job); job->result.reserve(32768);
    if (!amcl::napi::ReadStringValue(env, args[0], job->files) || job->files.empty() || job->files[0] != '/' ||
        job->files.find('\0') != std::string::npos || !amcl::napi::ReadStringValue(env, args[1], job->nonce) ||
        !validNonce(job->nonce)) {
        napi_throw_type_error(env, "JDK_PROCESS_INPUT", "filesDir 或 nonce 无效"); return unused;
    }
    if (active.exchange(true, std::memory_order_acq_rel)) {
        napi_throw_error(env, "JDK_PROCESS_BUSY", "退出矩阵仍在运行"); return unused;
    }
    napi_status status = napi_create_reference(env, args[2], 1, &job->callback);
    if (status == napi_ok) status = napi_create_string_utf8(env, "JdkProcessQualification", NAPI_AUTO_LENGTH, &resource);
    if (status == napi_ok) status = napi_create_async_work(env, nullptr, resource, execute, complete, job.get(), &job->work);
    if (status == napi_ok) status = napi_queue_async_work(env, job->work);
    if (status != napi_ok) {
        if (job->work) napi_delete_async_work(env, job->work);
        if (job->callback) napi_delete_reference(env, job->callback);
        active.store(false, std::memory_order_release);
        napi_throw_error(env, "JDK_PROCESS_QUEUE", "无法提交退出矩阵");
    } else job.release();
    return unused;
} catch (...) {
    napi_throw_error(env, "JDK_PROCESS_PREPARE", "无法准备退出矩阵"); return nullptr;
}
#endif
