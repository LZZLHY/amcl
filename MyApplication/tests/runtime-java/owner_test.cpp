/**
 * 真实资格入口的 NAPI/子进程所有权测试。SDK 替身只拒绝创建或发送明确的控制事件，
 * 从不创建 JavaVM，也不据此声称真实 NativeChildProcess/目标 JDK 已通过。
 */
#include "../../entry/src/main/cpp/napi/jdk_java_qualification.cpp"
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
/** 原完整Job入口用的最小TSFN生命周期替身；不复制PairOwner/生产调度算法。 */
struct napi_threadsafe_function__ {
    int count = 1;
    void* data;
    void* context;
    napi_finalize finalize;
    napi_threadsafe_function_call_js invoke;
};
namespace {
int fault = 0, refs = 0, works = 0, scopes = 0, callbacks = 0, strings = 0, registered = 0, terminations = 0;
int iteration = 0;
napi_async_work queued = nullptr;
napi_env env = reinterpret_cast<napi_env>(1);
napi_value value = reinterpret_cast<napi_value>(1);
std::string fixtureRoot, callbackText;
bool nativeChildTest = false;
int testRuntimeState = 0, testGameRunning = 0, testGraphicsUsed = 0;
std::string requestedProfile = "basic";
int tsfns = 0;
napi_threadsafe_function pendingTsfn = nullptr;
void (*cleanupHook)(void*) = nullptr;
void* cleanupContext = nullptr;

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
    output = index == 1 ? fixtureRoot : index == 2 ? "case-" + std::to_string(iteration) :
        index == 3 ? "21" : requestedProfile;
    return true;
}
}
namespace amcl::jdkqualification {
// 所有权单测不执行真实音频；误入子进程专项立即失败，不能以替身制造播放观察结果。
std::string RunAudioTimingQualification(int) { assert(false); return {}; }
void BeginCaptureDiagnostic() { assert(false); }
std::string FinishCaptureDiagnostic(int) { assert(false); return {}; }
std::string RunCaptureNativeQualification(int) { assert(false); return {}; }
std::string RunCaptureLayoutQualification(int) { assert(false); return {}; }
std::string RunCaptureStartupQualification(int) { assert(false); return {}; }
std::string RunCaptureChannelsQualification(int) { assert(false); return {}; }
}
// 新四参入口只补链接边界：本套件验证NCP所有权，任何落到真实VM创建阶段的路径都必须失败。
// 不能用返回0的替身把native-only或故障路径伪装成完成了Java初始化。
int jvmInit(const char*, const char*, const char*, const char*) { assert(false); return -1; }
extern "C" {
// 子入口不在这套边界单测中执行；任何误入生产 JVM 的调用立即失败，不制造假 Java PASS。
int jvmInit(const char*, const char*) { assert(false); return -1; }
int jvmRuntimeState() { assert(nativeChildTest); return testRuntimeState; }
void* jvmGetJavaVM() { assert(nativeChildTest); return nullptr; }
int jvmCallMain(const char*, int, const char**) { assert(false); return -1; }
int jvmFinishProcessor() { assert(false); return -1; }
int mcIsRunning() { return testGameRunning; }
int graphicsSemanticsRestartRequired() { return testGraphicsUsed; }
const char* jvmGetStatus() { assert(false); return "unreachable"; }
void jvmSetForkChildMode(int) { assert(false); }
int jvmSetQualificationCfExplicit(int) { assert(false); return -1; }
void jvmSetClasspath(const char*) { assert(false); }
void jvmSetXmx(int) { assert(false); }
void jvmSetCrashOutputPath(const char*) { assert(false); }
// 此套件不运行child或真实字体；任何误入目标ELF加载都立即失败，避免替身伪造默认缓存PASS。
void elf_set_search_path(const char*) { assert(false); }
void* elf_dlopen(const char*, int) { assert(false); return nullptr; }
void* elf_dlsym(void*, const char*) { assert(false); return nullptr; }
int elf_dlclose(void*) { assert(false); return -1; }
int elf_dladdr(const void*, void*) { assert(false); return 0; }
char* elf_dlerror() { assert(false); return nullptr; }

napi_status napi_get_undefined(napi_env, napi_value* out) { *out = value; return napi_ok; }
// 原测试不创建真实NCP；新pair正常分支仍由SDK Start=801拒绝。这里只验证Job与回调释放顺序。
napi_status napi_create_threadsafe_function(napi_env,napi_value,napi_value,napi_value,size_t,size_t,void* data,
        napi_finalize finalize,void* context,napi_threadsafe_function_call_js invoke,napi_threadsafe_function* out) {
    if (fault == 11) return napi_generic_failure;
    *out = new napi_threadsafe_function__{1,data,context,finalize,invoke}; ++tsfns; return napi_ok;
}
napi_status napi_add_env_cleanup_hook(napi_env,void(*function)(void*),void* context) {
    if (fault == 12) return napi_generic_failure;
    assert(!cleanupHook); cleanupHook = function; cleanupContext = context; return napi_ok;
}
napi_status napi_remove_env_cleanup_hook(napi_env,void(*function)(void*),void* context) {
    assert(cleanupHook == function && cleanupContext == context);
    cleanupHook = nullptr; cleanupContext = nullptr; return napi_ok;
}
napi_status napi_unref_threadsafe_function(napi_env,napi_threadsafe_function) { return fault == 13 ? napi_generic_failure : napi_ok; }
napi_status napi_acquire_threadsafe_function(napi_threadsafe_function function) { assert(function->count > 0); ++function->count; return napi_ok; }
napi_status napi_release_threadsafe_function(napi_threadsafe_function function,napi_threadsafe_function_release_mode mode) {
    if (mode == napi_tsfn_abort && pendingTsfn == function) pendingTsfn = nullptr;
    assert(function->count > 0);
    if (--function->count == 0 && pendingTsfn != function) { function->finalize(env,function->data,nullptr); delete function; --tsfns; }
    return napi_ok;
}
napi_status napi_call_threadsafe_function(napi_threadsafe_function function,void*,napi_threadsafe_function_call_mode) {
    assert(!pendingTsfn); pendingTsfn = function; return napi_ok;
}
napi_status napi_get_cb_info(napi_env, napi_callback_info, size_t* count, napi_value* args, napi_value*, void**) {
    assert(*count == 5);
    *count = 5;
    for (uintptr_t i = 0; i < 5; ++i) args[i] = reinterpret_cast<napi_value>(i + 1);
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
void jvmSetExtraArgsList(const std::vector<std::string>&) { assert(false); }

/** 每个场景使用真正的新宿主进程，生产shared单次标记从不在测试中重置。
 * 真正编译执行完整NAPI/worker/body；故意缺archive停在VM前，任何VM或音频误入仍assert。
 */
void sharedHostCases() {
    for (int scenario = 0; scenario < 12; ++scenario) {
        const pid_t child = fork(); assert(child >= 0);
        if (child == 0) {
            nativeChildTest = true;
            char path[] = "/dev/shm/amcl-shared-owner-XXXXXX"; assert(mkdtemp(path));
            fixtureRoot = path;
            assert(mkdir((fixtureRoot + "/jdk-runtime-qualification").c_str(),0700) == 0);
            assert(mkdir((fixtureRoot + "/jdk-runtime-qualification/case-0").c_str(),0700) == 0);
            requestedProfile = scenario == 1 ? "shared-extended" : "shared-basic";
            if (scenario >= 4 && scenario <= 7) testRuntimeState = scenario - 3;
            if (scenario == 8) testGameRunning = 1;
            if (scenario == 9) testGraphicsUsed = 1;
            if (scenario == 10) requestedProfile = "shared-native-temp-vms";
            if (scenario == 11) requestedProfile = "shared-sound-capture";
            fault = scenario == 2 ? 3 : scenario == 3 ? 4 : 0;
            struct stat stdoutBefore{},stderrBefore{},cwdBefore{},stdoutAfter{},stderrAfter{},cwdAfter{};
            assert(fstat(STDOUT_FILENO,&stdoutBefore)==0 && fstat(STDERR_FILENO,&stderrBefore)==0 && stat(".",&cwdBefore)==0);
            const int before = descriptors();
            RunJdkJavaQualificationNapi(env,nullptr);
            if (scenario < 2) {
                assert(queued && refs==1 && works==1 && active && JdkSharedQualificationRestartRequired());
                assert(amcl::napi::RejectGraphicsSemanticsJvmStart(env));
                auto* work=queued;queued=nullptr;work->execute(env,work->data);
                work->complete(env,napi_ok,work->data);
                assert(callbackText.find("shared-process-complete")!=std::string::npos);
                assert(callbackText.find("\"processExitObserved\":false")!=std::string::npos);
                assert(callbackText.find("\"executionMode\":\"shared-tool\"")!=std::string::npos);
                assert(callbackText.find("\"passed\":false")!=std::string::npos);
                assert(callbackText.find("\"stdioRestored\":true")!=std::string::npos);
                assert(callbackText.find("native-child-")==std::string::npos);
                auto run=io::Directory(fixtureRoot+"/jdk-runtime-qualification/case-0/run-21");
                const auto stages=io::SmallFile(run.get(),"native-stages.jsonl",65536);
                assert(stages.find("shared-worker")!=std::string::npos);
                assert(stages.find("shared-process-global-environment")!=std::string::npos);
                assert(!io::Exists(run.get(),"font-context-report.json"));
                assert(!io::Exists(run.get(),"destroy-started.txt"));
                assert(!registered && !terminations && !pendingTsfn && !pairCallbackOwner);
                RunJdkJavaQualificationNapi(env,nullptr);assert(!queued); // worker结束也不能再次运行。
            } else if (scenario < 4) {
                assert(JdkSharedQualificationRestartRequired() && amcl::napi::RejectGraphicsSemanticsJvmStart(env));
                fault=0;RunJdkJavaQualificationNapi(env,nullptr);assert(!queued); // queue失败也必须重启。
            } else assert(!JdkSharedQualificationRestartRequired());
            assert(!queued && !refs && !works && !scopes && !active && !registered && !terminations);
            assert(fstat(STDOUT_FILENO,&stdoutAfter)==0 && fstat(STDERR_FILENO,&stderrAfter)==0 && stat(".",&cwdAfter)==0);
            assert(stdoutBefore.st_dev==stdoutAfter.st_dev && stdoutBefore.st_ino==stdoutAfter.st_ino);
            assert(stderrBefore.st_dev==stderrAfter.st_dev && stderrBefore.st_ino==stderrAfter.st_ino);
            assert(cwdBefore.st_dev==cwdAfter.st_dev && cwdBefore.st_ino==cwdAfter.st_ino);
            assert(descriptors()==before);
            std::filesystem::remove_all(fixtureRoot);
            _exit(0);
        }
        int status=0;assert(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==0);
    }
    puts("PASS shared actual-source: two fixed profiles; real pre-VM failure/stdio/CWD/FD restoration; queue failures remain restart-only; 4 used runtime states/game/graphics/pair/mic rejected");
}

int main() {
    sharedHostCases();
    // 录音预算从真实Native阶段开始，分片不丢标记，重复开始不会延长，结束后恢复普通VM预算。
    const auto epoch = Clock::time_point{};
    QualificationPhaseDeadline capture(true);
    const std::string first = "{\"stage\":\"capture-", last = "main\"}\n";
    capture.receive(first.data(), first.size(), epoch);
    assert(!capture.expired(epoch + std::chrono::seconds(100)));
    capture.receive(last.data(), last.size(), epoch);
    assert(!capture.expired(epoch + std::chrono::seconds(9)));
    const std::string start = first + last;
    capture.receive(start.data(), start.size(), epoch + std::chrono::seconds(8));
    assert(capture.expired(epoch + std::chrono::seconds(10)));
    const std::string finish = "{\"stage\":\"capture-main-return\",\"result\":0}\n";
    capture.receive(finish.data(), finish.size(), epoch + std::chrono::seconds(11));
    assert(!capture.expired(epoch + std::chrono::seconds(100)));
    QualificationPhaseDeadline ordinary(false);
    ordinary.receive(start.data(), start.size(), epoch);
    assert(!ordinary.expired(epoch + std::chrono::seconds(100)));
    QualificationPhaseDeadline nativeDeadline(true, "native-temp-main");
    nativeDeadline.receive(start.data(), start.size(), epoch); // 录音标记不能启动OS前置预算。
    assert(!nativeDeadline.expired(epoch + std::chrono::seconds(100)));
    const std::string nativeStart = "{\"stage\":\"native-temp-main\"}\n";
    nativeDeadline.receive(nativeStart.data(), 17, epoch);
    nativeDeadline.receive(nativeStart.data() + 17, nativeStart.size() - 17, epoch);
    assert(nativeDeadline.expired(epoch + std::chrono::seconds(10)));
    const std::string nativeFinish = "{\"stage\":\"native-temp-main-return\",\"result\":0}\n";
    nativeDeadline.receive(nativeFinish.data(), nativeFinish.size(), epoch + std::chrono::seconds(11));
    assert(!nativeDeadline.expired(epoch + std::chrono::seconds(100)));
    // 外部profile不能注入参数/路径，且8的C2-only必须在创建子进程前明确拒绝。
    for (const auto* major : {"8", "17", "21", "25"}) {
        for (const auto* profile : {"basic", "broad", "full"}) assert(validProfile(major, profile));
        for (const auto* profile : {"extended", "extended-fork", "sound-software", "sound-playback", "font-defaults", "process-java", "sound-capture-denied", "sound-capture", "sound-capture-diagnostic", "sound-capture-native", "sound-capture-layout", "sound-capture-startup", "sound-capture-channels", "native-temp", "sound-timing", "native-sound-devices"}) {
            assert(validProfile(major, profile));
            assert(!cfProfile(profile));
        }
        assert(validProfile(major, "c2-only") == (std::string(major) != "8"));
        for (const auto* profile : {"", "FULL", "../full", "full\n-Xint", "-Xint"})
            assert(!validProfile(major, profile));
    }
    // 新诊断模式不能因名字不同逃过短录音预算，非正向模式不被误当作已授权录音。
    assert(positiveCaptureProfile("sound-capture"));
    assert(positiveCaptureProfile("sound-capture-diagnostic"));
    assert(positiveCaptureProfile("sound-capture-native"));
    assert(positiveCaptureProfile("sound-capture-layout"));
    assert(positiveCaptureProfile("sound-capture-startup"));
    assert(positiveCaptureProfile("sound-capture-channels"));
    assert(!positiveCaptureProfile("native-temp"));
    assert(!positiveCaptureProfile("sound-capture-denied"));
    assert(!positiveCaptureProfile("sound-playback"));
    assert(qualificationRunName("25", "native-temp") == "run-native-temp");
    assert(validProfile("17", "native-file-times"));
    assert(!sharedProfile("native-file-times"));
    assert(qualificationRunName("17", "native-file-times") == "run-native-file-times");
    assert(qualificationRunName("25", "sound-capture-startup") == "run-25");
    assert(qualificationRunName("25", "sound-capture-channels") == "run-25");
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
    assert(mkdir((fixtureRoot + "/jdk-runtime-qualification").c_str(), 0700) == 0);
    // 重放目标暴露的“main返回0而report失败”：真实文件+生产SHA/消费者门必须拒绝。
    const auto processPath = fixtureRoot + "/java-process";
    assert(mkdir(processPath.c_str(), 0700) == 0);
    {
        io::Fd root(open(fixtureRoot.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
        assert(root.get() >= 0);
        const std::string report = "{\"fixture\":\"真实报告字节\"}\n";
        std::ofstream(processPath + "/result.json", std::ios::binary) << report;
        for (int scenario = 0; scenario < 3; ++scenario) {
            const auto digest = scenario == 2 ? std::string(64, '0') : io::Digest(report);
            const std::string marker = "{\"protocol\":\"AMCL_JAVA_PROCESS_COMPLETE_V1\",\"resultSha256\":\"" +
                digest + "\",\"passed\":" + (scenario == 1 ? "false" : "true") + "}\n";
            std::ofstream(processPath + "/complete.json", std::ios::binary) << marker;
            bool accepted = false;
            try { requireProcessCompletion(root.get()); accepted = true; }
            catch (const std::exception&) {}
            assert(accepted == (scenario == 0));
        }
    }
    const int before = descriptors();
    {
        // 真正调用native-only子入口的前半段：没有runtime.zip/qualification.jar，所有VM装载
        // 和媒体函数仍是assert(false)。只允许读取Fresh状态；OS helper按本宿主真实libc运行。
        nativeChildTest = true;
        for (const bool provideRoots : {true, false}) {
            const std::string nonce = provideRoots ? "native-owner" : "native-owner-missing";
            const std::string rootPath = fixtureRoot + "/jdk-runtime-qualification/" + nonce;
            assert(mkdir(rootPath.c_str(), 0700) == 0);
            assert(mkdir((rootPath + "/run-native-temp").c_str(), 0700) == 0);
            if (provideRoots) std::ofstream(rootPath + "/permission-roots.txt", std::ios::binary) <<
                "AMCL-PERM-ROOTS-1\n" << fixtureRoot << "\n\nenvironment\n";
            io::Fd root(open(rootPath.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
            io::Fd run(open((rootPath + "/run-native-temp").c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
            assert(root.get() >= 0 && run.get() >= 0);
            int pipefd[2]; assert(pipe2(pipefd, O_CLOEXEC | O_NONBLOCK) == 0);
            io::Fd reader(pipefd[0]), writer(pipefd[1]);
            char rootName[] = "root", reportName[] = "report";
            NativeChildProcess_Fd rootArgument{rootName, dup(root.get()), nullptr};
            NativeChildProcess_Fd reportArgument{reportName, dup(writer.get()), &rootArgument};
            const std::string parameters = rootPath + "\n25\nnative-temp";
            NativeChildProcess_Args arguments{const_cast<char*>(parameters.c_str()), {&reportArgument}};
            AmclJdkJavaQualificationMain(arguments);
            const auto result = io::SmallFile(run.get(), "result.json", 65536);
            assert(result.find("AMCL_NATIVE_TEMP_RESULT_V1") != std::string::npos);
            assert(result.find(provideRoots ? "\"observationComplete\":true" : "\"observationComplete\":false") != std::string::npos);
            assert(result.find("\"archiveInstalled\":false") != std::string::npos && result.find("\"jvmStarted\":false") != std::string::npos);
            for (const auto* forbidden : {"initResult", "mainResult", "destroyResult", "archiveSha256", "fixtureSha256"})
                assert(result.find(forbidden) == std::string::npos);
            assert(!io::Exists(run.get(), "qualification.jar") && !io::Exists(root.get(), "jdk"));
            const auto stages = io::SmallFile(run.get(), "native-stages.jsonl", 65536);
            for (const auto* forbidden : {"install-stage", "jvm-init", "java-main", "capture-main"})
                assert(stages.find(forbidden) == std::string::npos);
        }
        nativeChildTest = false;
        const std::string nonce = "native-parent";
        assert(mkdir((fixtureRoot + "/jdk-runtime-qualification/" + nonce).c_str(), 0700) == 0);
        Job job; job.files = fixtureRoot; job.nonce = nonce; job.major = "25"; job.profile = "native-temp";
        const auto parent = runParent(job); // SDK替身拒绝Start，但父分支必须已跳过JAR。
        assert(parent.find("\"nativeOnly\":true") != std::string::npos && parent.find("\"fixtureSha256\":null") != std::string::npos);
        assert(!std::filesystem::exists(fixtureRoot + "/jdk-runtime-qualification/" + nonce + "/run-native-temp/qualification.jar"));
    }
    assert(descriptors() == before);
    {
        // 新原生时间模式必须先于归档/JAR/VM准备；同一应用根输入仍经正式桥校验。
        nativeChildTest = true;
        const std::string externalRoot = fixtureRoot + "/time-external";
        assert(mkdir(externalRoot.c_str(), 0700) == 0);
        for (const bool provideRoots : {true, false}) {
            const std::string rootPath = fixtureRoot + "/jdk-runtime-qualification/" +
                (provideRoots ? "time-owner" : "time-owner-missing");
            assert(mkdir(rootPath.c_str(), 0700) == 0);
            assert(mkdir((rootPath + "/run-native-file-times").c_str(), 0700) == 0);
            if (provideRoots) std::ofstream(rootPath + "/permission-roots.txt") <<
                "AMCL-PERM-ROOTS-1\n" << fixtureRoot << '\n' << externalRoot << "\nenvironment\n";
            io::Fd root(open(rootPath.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
            io::Fd run(open((rootPath + "/run-native-file-times").c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
            int pipes[2]; assert(pipe2(pipes, O_CLOEXEC | O_NONBLOCK) == 0);
            io::Fd reader(pipes[0]), writer(pipes[1]);
            char rootName[] = "root", reportName[] = "report";
            NativeChildProcess_Fd rootArgument{rootName, dup(root.get()), nullptr};
            NativeChildProcess_Fd reportArgument{reportName, dup(writer.get()), &rootArgument};
            const std::string parameters = rootPath + "\n17\nnative-file-times";
            NativeChildProcess_Args arguments{const_cast<char*>(parameters.c_str()), {&reportArgument}};
            AmclJdkJavaQualificationMain(arguments);
            const auto result = io::SmallFile(run.get(), "result.json", 65536);
            assert(result.find("AMCL_NATIVE_FILE_TIMES_RESULT_V1") != std::string::npos);
            assert(result.find(provideRoots ? "\"observationComplete\":true" : "\"observationComplete\":false") != std::string::npos);
            assert(result.find("\"jvmStarted\":false") != std::string::npos);
            assert(!io::Exists(run.get(), "qualification.jar") && !io::Exists(root.get(), "jdk"));
            if (provideRoots) {
                const auto observation = io::SmallFile(run.get(), "native-file-times.json", 131072);
                assert(observation.find("AMCL_NATIVE_FILE_TIMES_OBSERVATION_V1") != std::string::npos);
                assert(observation.find("both-omit") != std::string::npos && observation.find("pwriteBytes") != std::string::npos);
            }
        }
        nativeChildTest = false;
    }
    assert(descriptors() == before);
    {
        io::Fd root(open(fixtureRoot.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
        const std::string progress = "{\"stage\":\"complete\"}\n";
        std::ofstream(fixtureRoot + "/native-sound-devices-progress.jsonl", std::ios::binary) << progress;
        for (const std::string count : {"2", "0", "02", "-1", "2147483648", "2x"}) {
            const auto marker = "{\"protocol\":\"AMCL_NATIVE_SOUND_DEVICES_V1\",\"major\":17,\"passed\":true,\"midiIoQualified\":false,\"portCount\":" +
                count + ",\"progressSha256\":\"" + io::Digest(progress) + "\"}\n";
            std::ofstream(fixtureRoot + "/native-sound-devices-complete.json", std::ios::binary) << marker;
            bool accepted = false;
            try { requireSoundDevicesCompletion(root.get(), "17"); accepted = true; } catch (const std::exception&) {}
            assert(accepted == (count == "2"));
        }
    }
    for (fault = 1; fault <= 5; ++fault) {
        strings = 0;
        RunJdkJavaQualificationNapi(env, nullptr);
        assert(!queued && !refs && !works && !scopes && !registered && !active.load());
        assert(descriptors() == before);
    }
    for (int selected : {0, 6, 7, 8, 9, 10}) {
        ++iteration;
        assert(mkdir((fixtureRoot + "/jdk-runtime-qualification/case-" + std::to_string(iteration)).c_str(), 0700) == 0);
        fault = selected; strings = 0; callbackText.clear();
        const int prior = callbacks;
        RunJdkJavaQualificationNapi(env, nullptr);
        assert(queued && refs == 1 && works == 1 && active.load());
        auto* work = queued; queued = nullptr;
        if (selected == 0) {
            RunJdkJavaQualificationNapi(env, nullptr);
            assert(!queued && refs == 1 && works == 1 && active.load()); // busy 不清掉另一任务所有权。
        }
        if (selected != 10) work->execute(env, work->data);
        work->complete(env, selected == 10 ? napi_cancelled : napi_ok, work->data);
        assert(!refs && !works && !scopes && !registered && !active.load());
        assert(callbacks - prior == ((selected == 0 || selected == 9 || selected == 10) ? 1 : 0));
        if (selected == 0) assert(callbackText.find("\"result\":801") != std::string::npos);
        assert(descriptors() == before);
    }
    // 报告或分配发生异常时 owner 仍发出真实身份约束终止请求，等对应退出事件后才销毁。
    // SDK 替身中的 signal=9 只测试状态传递，不作为任何目标进程的实测退出证据。
    expectedPid = 98765; exitObserved = false; exitSignal = 0;
    try {
        ChildOwner owner(OH_Ability_KillChildProcess);
        owner.adopt(expectedPid);
        throw std::bad_alloc();
    } catch (const std::bad_alloc&) {}
    assert(terminations == 1 && exitObserved && exitSignal == 9);
    requestedProfile = "native-temp-vms";
    for (int selected : {3,4,11,12,13}) {
        fault = selected; strings = 0;
        RunJdkJavaQualificationNapi(env,nullptr);
        assert(!queued && !refs && !works && !scopes && !registered && !active.load());
        assert(!pendingTsfn && !cleanupHook && tsfns == 0 && descriptors() == before);
    }
    for (int selected : {0,10,20}) {
        ++iteration;
        assert(mkdir((fixtureRoot + "/jdk-runtime-qualification/case-" + std::to_string(iteration)).c_str(),0700) == 0);
        fault = selected; strings = 0; callbackText.clear();
        RunJdkJavaQualificationNapi(env,nullptr);
        assert(queued && refs == 1 && works == 1 && tsfns == 1 && cleanupHook && active);
        auto* work = queued; queued = nullptr;
        if (selected != 10) work->execute(env,work->data);
        // 官方NativeEngine先等异步请求，complete在有效env上运行，之后才进入env cleanup hook。
        // 完整生产Job此刻仍busy；不能用session手动releaseWorker代替这个边界。
        assert(active && refs == 1 && works == 1 && !pendingTsfn);
        work->complete(env,selected == 10 ? napi_cancelled : napi_ok,work->data);
        assert(!refs && !works && !scopes && pendingTsfn && active);
        if (selected == 20) {
            // 正常引擎允许complete已交还、TSFN尚在排队时开始env cleanup。
            // 从完整Job进入真实hook，后者安排一次性native清理；不是手工releaseWorker。
            auto function=cleanupHook;auto context=cleanupContext;cleanupHook=nullptr;cleanupContext=nullptr;
            function(context);
            const auto deadline=Clock::now()+std::chrono::seconds(2);
            while(active.load(std::memory_order_acquire) && Clock::now()<deadline)poll(nullptr,0,1);
        } else {
            auto function = pendingTsfn; pendingTsfn = nullptr;
            function->invoke(env,nullptr,function->context,nullptr);
        }
        assert(!tsfns && !cleanupHook && !registered && !active && !pairCallbackOwner && descriptors() == before);
    }
    requestedProfile = "basic";
    std::filesystem::remove_all(fixtureRoot); // 只移除本测试 mkdtemp 创建的明确目录。
    std::puts("PASS Java qualification owner: 7 provider cases + 11 NAPI cases + 8 complete pair Job failure/cancel/execute/complete/env-hook cases + native-only parent/child + phase deadlines + busy/exception ownership; refs/work/scopes/fds balanced");
}
