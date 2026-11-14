/**
 * 真实退出矩阵的 NAPI/子进程所有权测试。SDK 替身只拒绝创建或发送明确的控制事件，
 * 从不创建 JavaVM，也不据此声称真实 NativeChildProcess/目标 JDK 已通过。
 */
#include "../../entry/src/main/cpp/napi/jdk_process_qualification.cpp"
#include <cassert>
#include <dirent.h>
#include <filesystem>
#include <fstream>
#include <sys/wait.h>
// 复用的最小 SDK stub 没有 API22 声明；此真实测试 DSO 的签名与本机 SDK 完全一致。
extern "C" int OH_Ability_KillChildProcess(int32_t pid);

struct napi_async_work__ {
    napi_async_execute_callback execute;
    napi_async_complete_callback complete;
    void* data;
};
struct napi_ref__ {};
namespace {
int fault = 0, refs = 0, works = 0, scopes = 0, callbacks = 0, strings = 0, registered = 0, terminations = 0;
int iteration = 0;
napi_async_work queued = nullptr;
napi_env env = reinterpret_cast<napi_env>(1);
napi_value value = reinterpret_cast<napi_value>(1);
std::string fixtureRoot, callbackText;

/** 查找边界注入：RTLD_DEFAULT 不可见不应影响显式 provider；错误归属必须拒绝。 */
struct LookupSimulation {
    static int scenario, opened, closed, symbols;
    static char* pendingError;
    static int address(const void* function, Dl_info* information) {
        const bool start = function == reinterpret_cast<const void*>(&OH_Ability_StartNativeChildProcess);
        if ((scenario == 1 && start) || (scenario == 5 && !start)) return 0;
        information->dli_fname = "/already-loaded/libchild_process.so";
        information->dli_fbase = reinterpret_cast<void*>(scenario == 4 && !start ? 0x2000 : 0x1000);
        return 1;
    }
    static void* open(const char* path, int flags) {
        ++opened;
        assert(flags == (RTLD_NOW | RTLD_NOLOAD));
        assert(std::string(path) == "/already-loaded/libchild_process.so" || std::string(path) == "libchild_process.so");
        if (scenario == 2 || (scenario == 6 && opened == 1)) {
            static char unavailable[] = "provider is not visible by this name";
            pendingError = unavailable;
            return nullptr;
        }
        return reinterpret_cast<void*>(0x1234);
    }
    static void* symbol(void* handle, const char* name) {
        ++symbols;
        // 真机问题的关键：不使用 RTLD_DEFAULT，而是只查已经核实的独立提供者句柄。
        assert(handle == reinterpret_cast<void*>(0x1234));
        assert(std::string(name) == "OH_Ability_KillChildProcess");
        if (scenario == 3) {
            static char absent[] = "symbol does not exist in provider";
            pendingError = absent;
            return nullptr;
        }
        return reinterpret_cast<void*>(&OH_Ability_KillChildProcess);
    }
    static int close(void* handle) { assert(handle == reinterpret_cast<void*>(0x1234)); ++closed; return 0; }
    static char* error() { char* value = pendingError; pendingError = nullptr; return value; }
    static ProviderLookup functions() { return {address, open, symbol, close, error}; }
};
int LookupSimulation::scenario = 0, LookupSimulation::opened = 0, LookupSimulation::closed = 0,
    LookupSimulation::symbols = 0;
char* LookupSimulation::pendingError = nullptr;

/** Linux 测试夹具统计真实 FD，不以 fake API 计数代替文件资源检查。 */
int descriptors() {
    DIR* directory = opendir("/proc/self/fd");
    assert(directory);
    int count = 0;
    while (readdir(directory)) ++count;
    closedir(directory);
    return count;
}
}
namespace amcl::napi {
bool ReadStringValue(napi_env, napi_value input, std::string& output) {
    if (fault == 5) throw std::bad_alloc();
    const auto index = reinterpret_cast<uintptr_t>(input);
    output = index == 1 ? fixtureRoot : index == 2 ? "case-" + std::to_string(iteration) : "21";
    return true;
}
}
extern "C" {
napi_status napi_get_undefined(napi_env, napi_value* out) { *out = value; return napi_ok; }
napi_status napi_get_cb_info(napi_env, napi_callback_info, size_t* count, napi_value* args, napi_value*, void**) {
    *count = 3;
    for (uintptr_t i = 0; i < 3; ++i) args[i] = reinterpret_cast<napi_value>(i + 1);
    return napi_ok;
}
napi_status napi_typeof(napi_env, napi_value, napi_valuetype* type) { *type = napi_function; return napi_ok; }
napi_status napi_throw_error(napi_env, const char*, const char*) { return napi_ok; }
napi_status napi_throw_type_error(napi_env, const char*, const char*) { return napi_ok; }
napi_status napi_create_reference(napi_env, napi_value, uint32_t, napi_ref* out) {
    if (fault == 1) return napi_generic_failure;
    *out = new napi_ref__; ++refs; return napi_ok;
}
napi_status napi_delete_reference(napi_env, napi_ref ref) { delete ref; --refs; return napi_ok; }
napi_status napi_get_reference_value(napi_env, napi_ref, napi_value* out) {
    if (fault == 6) return napi_generic_failure;
    *out = value; return napi_ok;
}
napi_status napi_create_string_utf8(napi_env, const char* text, size_t, napi_value* out) {
    ++strings;
    if ((fault == 2 && strings == 1) || (fault == 7 && strings == 2)) return napi_generic_failure;
    if (strings == 2) callbackText = text;
    *out = value; return napi_ok;
}
napi_status napi_open_handle_scope(napi_env, napi_handle_scope* out) {
    if (fault == 8) return napi_generic_failure;
    *out = reinterpret_cast<napi_handle_scope>(1); ++scopes; return napi_ok;
}
napi_status napi_close_handle_scope(napi_env, napi_handle_scope) { --scopes; return napi_ok; }
napi_status napi_create_async_work(napi_env, napi_value, napi_value, napi_async_execute_callback execute,
        napi_async_complete_callback complete, void* data, napi_async_work* out) {
    if (fault == 3) return napi_generic_failure;
    *out = new napi_async_work__{execute, complete, data}; ++works; return napi_ok;
}
napi_status napi_queue_async_work(napi_env, napi_async_work work) {
    if (fault == 4) return napi_generic_failure;
    queued = work; return napi_ok;
}
napi_status napi_delete_async_work(napi_env, napi_async_work work) { delete work; --works; return napi_ok; }
napi_status napi_call_function(napi_env, napi_value, napi_value, size_t, const napi_value*, napi_value*) {
    ++callbacks; return fault == 9 ? napi_pending_exception : napi_ok;
}
int OH_Ability_RegisterNativeChildProcessExitCallback(OH_Ability_OnNativeChildProcessExit) { ++registered; return 0; }
int OH_Ability_UnregisterNativeChildProcessExitCallback(OH_Ability_OnNativeChildProcessExit) { --registered; return 0; }
void AmclJavaQualificationTestExit(int32_t pid, int32_t signal) {
    ++terminations;
    childExit(pid, signal);
}
}

int main(int argc, char** argv) {
    assert(argc == 1 || argc == 2); // 可选外置目录保留实际runParent串联报告，便于独立JSON读回。
    for (int selected = 0; selected <= 6; ++selected) {
        LookupSimulation::scenario = selected;
        LookupSimulation::opened = LookupSimulation::closed = LookupSimulation::symbols = 0;
        LookupSimulation::pendingError = nullptr;
        bool accepted = false;
        try {
            ChildProcessProvider provider(LookupSimulation::functions());
            assert(provider.function() == &OH_Ability_KillChildProcess);
            assert(LookupSimulation::closed == 0); // 持有到最后使用者离开作用域。
            accepted = true;
        } catch (const std::exception&) {}
        assert(accepted == (selected == 0 || selected == 6));
        assert(LookupSimulation::closed == ((selected == 1 || selected == 2) ? 0 : 1));
        if (selected == 6) assert(LookupSimulation::opened == 2); // basename 仅认领同一已有实例。
    }
    char path[] = "/dev/shm/amcl-java-owner-XXXXXX";
    assert(mkdtemp(path));
    fixtureRoot = path;
    assert(mkdir((fixtureRoot + "/jdk-process-qualification").c_str(), 0700) == 0);
    const int before = descriptors();
    for (fault = 1; fault <= 5; ++fault) {
        strings = 0;
        RunJdkProcessQualificationNapi(env, nullptr);
        assert(!queued && !refs && !works && !scopes && !registered && !active.load());
        assert(descriptors() == before);
    }
    for (int selected : {0, 6, 7, 8, 9, 10}) {
        ++iteration;
        fault = selected; strings = 0; callbackText.clear();
        const int prior = callbacks;
        RunJdkProcessQualificationNapi(env, nullptr);
        assert(queued && refs == 1 && works == 1 && active.load());
        auto* work = queued; queued = nullptr;
        if (selected == 0) {
            RunJdkProcessQualificationNapi(env, nullptr);
            assert(!queued && refs == 1 && works == 1 && active.load()); // busy 不清掉另一任务所有权。
        }
        if (selected != 10) work->execute(env, work->data);
        work->complete(env, selected == 10 ? napi_cancelled : napi_ok, work->data);
        assert(!refs && !works && !scopes && !registered && !active.load());
        assert(callbacks - prior == ((selected == 0 || selected == 9 || selected == 10) ? 1 : 0));
        if (selected == 0) {
            // 真正执行runParent→八次runMode→独占报告发布，即使SDK边界拒绝也须得到完整报告。
            // 这会抓住exec NCP观察与application-parent执行报告的同名O_EXCL冲突。
            assert(callbackText.find("\"startResult\":801") != std::string::npos);
            assert(callbackText.find("\"probeError\"") == std::string::npos);
            assert(callbackText.find("\"execNcpExitObservation\"") != std::string::npos);
            assert(callbackText.find("\"execParent\"") != std::string::npos);
            assert(callbackText.find("\"fdCleanupNcpExitObservation\"") != std::string::npos);
            assert(callbackText.find("\"fdCleanupError\"") != std::string::npos);
            assert(callbackText.find("\"fdCleanup\":,") == std::string::npos);
            const auto resultRoot = fixtureRoot + "/jdk-process-qualification/case-" + std::to_string(iteration);
            assert(std::filesystem::is_regular_file(resultRoot + "/exec-routes.ncp-exit.json"));
            assert(std::filesystem::is_regular_file(resultRoot + "/exec-routes.application-parent.json"));
            assert(std::filesystem::is_regular_file(resultRoot + "/parent-report.json"));
            assert(std::filesystem::is_regular_file(resultRoot + "/fd-cleanup.ncp-exit.json"));
            assert(!std::filesystem::exists(resultRoot + "/exec-routes.parent.json"));
            assert(!std::filesystem::exists(resultRoot + "/fd-cleanup.parent.json"));
            if (argc == 2) {
                std::ofstream saved(std::string(argv[1]) + "/parent-chain-report.json");
                saved << callbackText; assert(saved.good());
            }
        }
        assert(descriptors() == before);
    }
    // 报告或分配发生异常时 owner 仍发出真实身份约束终止请求，等对应退出事件后才销毁。
    // SDK 替身中的 signal=9 只测试状态传递，不作为任何目标进程的实测退出证据。
    expectedPid = 98765; exitObserved = false; callbackSignal = 0;
    try {
        ChildOwner owner(OH_Ability_KillChildProcess);
        owner.adopt(expectedPid);
        throw std::bad_alloc();
    } catch (const std::bad_alloc&) {}
    assert(terminations == 1 && exitObserved && callbackSignal == 9);
    // 在单线程宿主测试进程中真实执行固定 child 动作，独立 waitpid 仅检验夹具请求。
    // 此处观察的是 Linux wait 状态，绝不能外推到 OHOS NCP 回调的数值/类型语义。
    assert(!modeFor("arbitrary") && !modeFor("../exit7") && !modeFor(nullptr));
    assert(modeFor("fd-cleanup") == &fdCleanupMode && modeFor("exec-routes") == &execRoutesMode);
    for (const auto& mode : modes) {
        const std::string name = fixtureRoot + "/actions-" + mode.name;
        assert(mkdir(name.c_str(), 0700) == 0);
        io::Fd directory(open(name.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
        assert(directory.get() >= 0);
        int descriptors[2]; assert(pipe(descriptors) == 0);
        pid_t pid = fork(); assert(pid >= 0);
        if (pid == 0) {
            close(descriptors[0]);
            char rootName[] = "root", reportName[] = "report";
            NativeChildProcess_Fd rootFd{rootName, directory.get(), nullptr};
            NativeChildProcess_Fd reportFd{reportName, descriptors[1], &rootFd};
            NativeChildProcess_Args args{const_cast<char*>(mode.name), {&reportFd}};
            AmclJdkProcessQualificationMain(args);
            _exit(0);
        }
        close(descriptors[1]);
        int status; assert(waitpid(pid, &status, 0) == pid);
        if (mode.signal) assert(WIFSIGNALED(status) && WTERMSIG(status) == mode.signal);
        else assert(WIFEXITED(status) && WEXITSTATUS(status) == mode.code);
        const auto marker = io::SmallFile(directory.get(), std::string(mode.name) + ".marker.json", 4096);
        assert(marker.find("\"requestedMode\":" + quoted(mode.name)) != std::string::npos);
        assert(marker.find("\"pid\":" + std::to_string(pid)) != std::string::npos);
        assert(marker.find("\"stage\":\"before-action\"") != std::string::npos);
        assert(marker.find("\"signalSetupErrno\":0") != std::string::npos);
        char bytes[4096]; assert(read(descriptors[0], bytes, sizeof(bytes)) > 0);
        close(descriptors[0]);
    }
    assert(descriptors() == before);
    std::filesystem::remove_all(fixtureRoot); // 只移除本测试 mkdtemp 创建的明确目录。
    std::puts("PASS Process qualification owner: 6 actual host child actions + 7 provider lookup cases + 11 NAPI cases + busy ownership + exception child ownership; refs/work/scopes/fds balanced");
}
