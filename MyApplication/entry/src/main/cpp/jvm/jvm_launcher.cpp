#include "jdk_directory_lease.h"
#include "../utils/product_diagnostics.h"
/**
 * jvm_launcher.cpp — JVM 嵌入模块 (JNI Invocation API)
 *
 * 通过 JNI_CreateJavaVM 在 HarmonyOS 进程内嵌入 OpenJDK HotSpot。
 *
 * 架构：
 *   完整 JDK（含 .so + 数据）从 GitHub Releases 下载到 filesDir/jdk/<version>/
 *   .so 文件通过自定义 ELF loader 加载（绕过 HarmonyOS MAP_XPM 代码签名验证）
 *   需要 ALLOW_WRITABLE_CODE_MEMORY ACL 权限
 *   支持多版本 JDK（8/17/21/25），通过 jdkVersion 参数选择
 *
 * HotSpot 补丁的活动事实源为 prebuilt/jdk/<major>/patches/series；源码、工具链和
 * 四版候选来源分别随构建清单记录。这里不复制会与实际补丁漂移的数量或旧禁用策略。
 *
 * 历史警示（不要改回去）：
 *   - 不要关 safepoint polling（-XX:-UsePollingPageSafepoint）
 *   - 不要在 sigchain handler 里 mprotect fault page
 *   - 不要传 -XX:+AllowUserSignalHandlers
 *   详见 docs/adaptation/JDK_ADAPTATION_GUIDE.md 5.4 节和 docs/ROADMAP.md。
 */

#include "jvm_launcher.h"
#include "jvm_signal_dispatch.h"
#include "jvm_signal_ownership.h"
#include "jvm_status.h"
#include "runtime_bootstrap_contract.h"
#include "game_process_exit.h"
#include "jvm_game_directory.h"
#include "jdk_native_temp_preparation.h"
#include "elf_loader.h"
#include "jvm_common_args.h"
#include "jvm_cf_policy.h"
#include "jvm_heap_options.h"
#include "jvm_heap_backing_directory.h"
#include "jvm_heap_backing_verification.h"
#include "../platform/graphics_plan.h"
#include "../platform/graphics_observation_abi.h"
#include "../platform/env_publication.h"  // I27-05：JVM 创建认领时封存环境槽位登记表
#include "../platform/jdk_font_resources.h"
#include "../platform/jdk_install_store.h"
#include "jni_invocation_support.h"
#include "jni_watchdog_support.h"
#include "jni_mutf8.h"   // NewStringUTF 只吃 Modified UTF-8：用户内容一律先转（见头文件）
#include "../utils/amcl_log.h"
#include "../utils/session_log_io.h"

#include <hilog/log.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <sys/syscall.h>
#include <cerrno>
#include <thread>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sstream>
#include <vector>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <time.h>

#undef LOG_TAG
#define LOG_TAG "JVM_LAUNCHER"

// ============================================================
//  SIGABRT 现场：预开 fd，handler 只做有界 signal-safe 直写
//
//  MC 的 System.exit 在部分 OHOS 路线上会被 appspawn 转成 SIGABRT。旧实现把
//  退出尾部和回溯继续塞进 amcl_log 环形缓冲，然后立刻 raise，最有价值的证据
//  可能还没轮到 writer 就随进程一起消失。本实现把现场先写到 filesDir/logs/system/
//  crash-tail.log；下一次冷启动由 ActivityLedger 按 activityId 封存。
//
//  handler 内禁止 AppLogger/AMCL_LOG、malloc、stdio、锁、条件变量和动态符号解析。
//  只使用预先打开的 fd、静态缓冲、open/lseek/read/write/close，并限制读取窗口。
// ============================================================
static int g_crashTailFd = -1;
static char g_crashGameOutputPath[1024] = {0};
// handler登记前发布一次，此后FD/路径与handler共同持有到进程退出。普通配置写者的短
// 原子门只保护发布前复制，signal handler从不等待它；避免setter与首次登记交错读半路径。
static std::atomic<bool> g_crashObservationPublished{false};
static_assert(std::atomic<bool>::is_always_lock_free, "signal publication must not acquire an internal lock");
static std::atomic_flag g_crashConfigurationWriter = ATOMIC_FLAG_INIT;
struct CrashConfigurationWrite {
    CrashConfigurationWrite() {
        while (g_crashConfigurationWriter.test_and_set(std::memory_order_acquire)) std::this_thread::yield();
    }
    ~CrashConfigurationWrite() { g_crashConfigurationWriter.clear(std::memory_order_release); }
};
// atomic_flag 保证无锁；多个线程同时 abort 时只有一个写尾部，其他信号继续平台链。
static std::atomic_flag g_crashHandlerEntered = ATOMIC_FLAG_INIT;

static void crashWriteBytes(const char* data, size_t length) {
    if (g_crashTailFd < 0 || data == nullptr || length == 0) return;
    size_t written = 0;
    while (written < length) {
        ssize_t n = write(g_crashTailFd, data + written, length - written);
        if (n <= 0) break;
        written += static_cast<size_t>(n);
    }
}

static void crashWriteLiteral(const char* text) {
    if (text == nullptr) return;
    size_t length = 0;
    while (text[length] != '\0') ++length;
    crashWriteBytes(text, length);
}

static size_t crashAppendHex(char* out, size_t offset, size_t capacity, uintptr_t value) {
    if (offset >= capacity) return offset;
    const char digits[] = "0123456789abcdef";
    char reversed[2 * sizeof(uintptr_t)] = {0};
    size_t count = 0;
    do {
        reversed[count++] = digits[value & 0xfu];
        value >>= 4u;
    } while (value != 0 && count < sizeof(reversed));
    while (count > 0 && offset < capacity) out[offset++] = reversed[--count];
    return offset;
}

static void crashWriteAddressLine(const char* label, uintptr_t value) {
    char line[128] = {0};
    size_t offset = 0;
    while (label != nullptr && label[offset] != '\0' && offset + 1 < sizeof(line)) {
        line[offset] = label[offset];
        ++offset;
    }
    if (offset + 3 < sizeof(line)) {
        line[offset++] = '0'; line[offset++] = 'x';
        offset = crashAppendHex(line, offset, sizeof(line) - 2, value);
        line[offset++] = '\n';
        crashWriteBytes(line, offset);
    }
}

static void crashDumpGameTailDirect() {
    if (g_crashGameOutputPath[0] == '\0') return;
    int input = open(g_crashGameOutputPath, O_RDONLY | O_CLOEXEC);
    if (input < 0) return;
    const off_t tailSize = 24 * 1024;
    off_t end = lseek(input, 0, SEEK_END);
    if (end < 0) { close(input); return; }
    off_t start = end > tailSize ? end - tailSize : 0;
    if (lseek(input, start, SEEK_SET) < 0) { close(input); return; }
    static char buffer[24 * 1024];
    ssize_t count = read(input, buffer, sizeof(buffer));
    close(input);
    if (count > 0) {
        crashWriteLiteral("\n===== MC_EXIT_TAIL (signal-safe) =====\n");
        crashWriteBytes(buffer, static_cast<size_t>(count));
        crashWriteLiteral("\n===== MC_EXIT_TAIL end =====\n");
    }
}

extern "C" void jvmSetCrashOutputPath(const char* path) {
    CrashConfigurationWrite write;
    if (g_crashObservationPublished.load(std::memory_order_acquire)) return;
    if (path == nullptr) {
        g_crashGameOutputPath[0] = '\0';
        return;
    }
    strncpy(g_crashGameOutputPath, path, sizeof(g_crashGameOutputPath) - 1);
    g_crashGameOutputPath[sizeof(g_crashGameOutputPath) - 1] = '\0';
}


// ============================================================
//  __clear_cache — libjvm.so 需要此符号，HarmonyOS musl 不提供
//  直接在 libentry.so 中导出，确保 dlopen libjvm.so 时可用
// ============================================================
/**
 * 向四代 JDK 声明当前是宿主内的嵌入场景。使用进程内入口而不是环境标志，
 * 避免 ProcessBuilder 启动独立 java 后继承标志，错误跳过其库路径与 re-exec。
 * 该入口仅声明运行方式，不授予文件、信号或内存权限。
 */
extern "C" __attribute__((visibility("default")))
int amcl_jvm_is_embedded(void) { return 1; }

extern "C" __attribute__((visibility("default")))
void __clear_cache(void* start, void* end) {
    // 导出入口可能被多个 JIT/装载线程同时首次调用。CTR_EL0 直接读入本次栈上值，
    // 避免旧的共享非原子懒缓存数据竞争，也不为几条指令引入锁、guard 或初始化协议。
    // 保留 dc → dsb → ic → dsb/isb 顺序；调用者仍负责写代码与执行线程之间的发布同步。
    if (reinterpret_cast<uintptr_t>(start) >= reinterpret_cast<uintptr_t>(end)) return;
    size_t ctr_el0;
    __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr_el0));
    size_t icache_line = 4 << ((ctr_el0 >> 0) & 0xf);
    size_t dcache_line = 4 << ((ctr_el0 >> 16) & 0xf);
    char* p;
    for (p = (char*)((uintptr_t)start & ~(dcache_line - 1));
         p < (char*)end; p += dcache_line) {
        __asm__ volatile("dc cvau, %0" :: "r"(p) : "memory");
    }
    __asm__ volatile("dsb ish" ::: "memory");
    for (p = (char*)((uintptr_t)start & ~(icache_line - 1));
         p < (char*)end; p += icache_line) {
        __asm__ volatile("ic ivau, %0" :: "r"(p) : "memory");
    }
    __asm__ volatile("dsb ish\nisb" ::: "memory");
}

// ============================================================
//  JNI 头文件（从 OpenJDK 17 提取）
// ============================================================
#include "jni.h"
#include "hello_world_class.h"

/** JNI 使用其平台调用约定进入；实际退出核心不依赖 JNI，也不回调 Java/ArkTS。 */
static void JNICALL isolatedGameExitHook(jint code) {
    amclGameJvmExitHook(static_cast<int>(code));
}

/** 手机仅接管已经进入正常 Java shutdown 的退出；其他退出由 HotSpot 继续原实现。 */
static void JNICALL phoneGameExitHook(jint code) {
    // shutdown observer 之后也可能出现 late renderer fatal；重新读取无锁呈现事实。
    if (code == 0 && amclGraphicsHasUsablePresentationV1()) amclPhoneGameJvmExitHook(0);
}

// JNI_CreateJavaVM 函数签名
typedef jint (*JNI_CreateJavaVM_t)(JavaVM** pvm, void** penv, void* args);

// ============================================================
//  全局状态
// ============================================================
static amcl::jvm::StatusText g_status;
// 在模块初始化时只登记一次。所有钩子都只获取/释放本模块状态锁，不跨 JNI、日志或
// 其他业务锁。若登记失败，安装器 fork 准入会拒绝，避免把新同步锁变成子进程死锁点。
static const int g_statusForkHooks = pthread_atfork(
    [] { g_status.beforeFork(); }, [] { g_status.afterFork(); }, [] { g_status.afterFork(); });
static thread_local std::string g_fullTestResult; // 返回缓冲属于本次 native 调用线程。
static std::atomic<bool> g_testRunning{false}; // 诊断准入必须原子，不与游戏线程共用 JNIEnv。

// JVM 生命周期
static std::atomic<JavaVM*> g_jvm{nullptr};
// 自有主调用/诊断与 VM 销毁共享准入；watchdog 另有可停止、可 join 的线程所有者。
// 原生消费者取得的 JavaVM 借用仍由其会话负责静止，不能靠一个原子指针强行回收它们。
static amcl::jni::InvocationGate g_invocationGate;
static amcl::jni::WatchdogWorker g_watchdog;
static std::atomic<jint> g_watchdogDetachFailure{JNI_OK};
static std::atomic_flag g_destroyInProgress = ATOMIC_FLAG_INIT;
// 一次创建尝试占用本进程；失败、游戏退出或 DestroyJavaVM 不清零 HotSpot/native 身份。
// 安装器只从从未创建 JVM 的父进程 fork；父进程先原子保留，子进程验证 PID 后独立认领。
static amcl::jvm::RuntimeOnce g_runtimeOnce;
extern "C" int jvmRuntimeState() { return g_runtimeOnce.state(); }
extern "C" void jvmRetireRuntime() {
    g_runtimeOnce.retire();
    g_invocationGate.close();
    // 退休不能在 Java 转储尚未返回时卡住游戏主线程；真正销毁会在后面 join。
    g_watchdog.requestStop();
}
extern "C" int jvmReserveForFork() {
    if (g_statusForkHooks != 0) {
        g_status = "JVM 状态文本的 fork 同步钩子不可用";
        return -7;
    }
    return g_runtimeOnce.reserveFork(static_cast<uint32_t>(getpid()));
}
extern "C" int jvmReleaseForkReservation() {
    return g_runtimeOnce.releaseFork(static_cast<uint32_t>(getpid())) ? 0 : -1;
}
// JNI 版本：随 JDK 布局在 jvmInit 里确定（JDK 8 经典布局 = JNI_VERSION_1_8，模块化 17/21/25 =
//   JNI_VERSION_10）。后续 GetEnv/AttachCurrentThread 都用它，否则 JDK 8 上传 JNI_VERSION_10 会失败。
static jint g_jniVersion = JNI_VERSION_10;
static std::string g_nativeLibDir;
static std::string g_jdkDataDir;
static std::string g_classpath;   // 外部可通过 jvmSetClasspath 设置
static std::string g_extraLibPath; // 额外 native library 搜索路径
static int g_xmxMb = 128;         // JVM 最大堆内存 MB
static std::vector<std::string> g_extraArgs; // 额外 JVM 参数列表（模组加载器用）
static bool g_jitMode = false;  // true=JIT混合模式, false=解释模式
// fork 子进程模式（安装器 processor）：true 时 jvmInit 跳过游戏主进程专属 -D（system.class.loader /
// lwjgl libname）与 watchdog 线程。由 fork_run_java 的 childMain 经 jvmSetForkChildMode 设置。
static bool g_forkChildMode = false;
#ifdef MC_OHOS_BUILD_TESTS
// 固定资格开关只在Fresh独立工具进程中设置；读取发生在唯一一次VM参数构造中。
static bool g_qualificationCfExplicit = false;
extern "C" int jvmSetQualificationCfExplicit(int enabled) {
    if (g_runtimeOnce.state() != 0 || g_jvm || !g_forkChildMode) return -1;
    g_qualificationCfExplicit = enabled != 0;
    return 0;
}
#endif

static bool detectJitSupport() {
    void* p = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p != MAP_FAILED) {
        munmap(p, 4096);
        return true;
    }
    return false;
}

extern "C" int jvmCheckJitAvailable(void) {
    return detectJitSupport() ? 1 : 0;
}

// ============================================================
//  外部配置接口（在 jvmInit 之前调用）
// ============================================================

extern "C" void jvmSetClasspath(const char* classpath) {
    if (classpath) g_classpath = classpath;
    AMCL_LOG_I(LOG_TAG, "jvmSetClasspath: %{public}zu chars", g_classpath.size());
}

extern "C" void jvmSetExtraLibPath(const char* path) {
    if (path) g_extraLibPath = path;
}

extern "C" const char* jvmGetExtraLibPath() {
    return g_extraLibPath.c_str();
}

extern "C" void jvmSetXmx(int mb) {
    g_xmxMb = mb > 0 ? mb : 128;
    AMCL_LOG_I(LOG_TAG, "jvmSetXmx: %{public}d MB", g_xmxMb);
}

extern "C" void jvmSetForkChildMode(int enabled) {
    g_forkChildMode = (enabled != 0);
    AMCL_LOG_I(LOG_TAG, "jvmSetForkChildMode: %{public}d", g_forkChildMode ? 1 : 0);
}

extern "C" int jvmResetForForkChild(void) {
    // 只能认领经过保留、且 getpid 已变化的真实子进程。先检查 JVM 指针，拒绝任何异常的
    // “保留态却已有 HotSpot”组合；失败不修改原运行时身份，不能靠清零指针伪装干净。
    if (g_jvm || !g_runtimeOnce.adoptForkChild(static_cast<uint32_t>(getpid()))) {
        return -7;
    }
    g_jvm = nullptr;
    // 只有未创建JVM的Fresh父进程允许走到这里；fork后仅当前线程，父侧配置门的副本
    // 可以重新置空。已注册handler/已尝试JVM的父进程不能通过RuntimeOnce准入此路径。
    g_crashConfigurationWriter.clear(std::memory_order_release);
    g_crashObservationPublished.store(false, std::memory_order_release);
    if (g_crashTailFd >= 0) {
        close(g_crashTailFd);
        g_crashTailFd = -1;
    }
    g_crashGameOutputPath[0] = '\0';
    g_crashHandlerEntered.clear(std::memory_order_release);
    g_classpath.clear();
    g_extraLibPath.clear();
    g_extraArgs.clear();
    g_xmxMb = 128;
    g_jitMode = false;
    return 0;
}

extern "C" void jvmSetExtraArgs(const char* args) {
    g_extraArgs.clear();
    if (args && args[0] != '\0') {
        std::string item;
        for (const char* p = args; *p; ++p) {
            if (*p == ',') {
                if (!item.empty()) {
                    g_extraArgs.push_back(item);
                    item.clear();
                }
            } else {
                item.push_back(*p);
            }
        }
        if (!item.empty()) g_extraArgs.push_back(item);
    }
    AMCL_LOG_I(LOG_TAG, "jvmSetExtraArgs(legacy): %{public}zu args", g_extraArgs.size());
}

void jvmSetExtraArgsList(const std::vector<std::string>& args) {
    g_extraArgs = args;
    AMCL_LOG_I(LOG_TAG, "jvmSetExtraArgsList: %{public}zu args", g_extraArgs.size());
}

// ============================================================
//  工具函数
// ============================================================

static const char* safeDlerror() {
    const char* err = dlerror();
    return err ? err : "(no error message)";
}

static bool fileExists(const char* path) {
    if (!path) return false;
    struct stat st;
    return stat(path, &st) == 0;
}

static uint64_t nowMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/** Java 字符串按 UTF-16 正确转成 UI/日志使用的 UTF-8；归还借用不依赖转换是否抛错。 */
static bool readJavaString(JNIEnv* env, jstring text, std::string& result) {
    const jsize length = env->GetStringLength(text);
    if (env->ExceptionCheck()) return false;
    const jchar* chars = env->GetStringChars(text, nullptr);
    if (!chars || env->ExceptionCheck()) return false;
    struct BorrowedChars {
        JNIEnv* env; jstring text; const jchar* chars;
        ~BorrowedChars() { env->ReleaseStringChars(text, chars); }
    } borrowed{env, text, chars};
    return amcl::utf16ToUtf8(chars, static_cast<size_t>(length), result);
}

/**
 * 首个异常已由调用者保存。这里逐项检查补充诊断所需的 JNI 分配/查找，失败只放弃
 * 额外文本，不覆盖原异常；嵌套局部帧使所有成功/失败路径均释放临时引用。
 */
static std::string getThrowableStackTrace(JNIEnv* env, jthrowable exception) {
    if (!env || !exception || env->ExceptionCheck()) return {};
    amcl::jni::LocalFrame frame(env, 16);
    auto failed = [&] { if (env->ExceptionCheck()) env->ExceptionClear(); return std::string{}; };
    if (!frame.valid()) return failed();
    jclass writerClass = env->FindClass("java/io/StringWriter");
    if (!writerClass || env->ExceptionCheck()) return failed();
    jclass printerClass = env->FindClass("java/io/PrintWriter");
    if (!printerClass || env->ExceptionCheck()) return failed();
    jclass throwableClass = env->FindClass("java/lang/Throwable");
    if (!throwableClass || env->ExceptionCheck()) return failed();
    jmethodID writerCtor = env->GetMethodID(writerClass, "<init>", "()V");
    if (!writerCtor || env->ExceptionCheck()) return failed();
    jmethodID toString = env->GetMethodID(writerClass, "toString", "()Ljava/lang/String;");
    if (!toString || env->ExceptionCheck()) return failed();
    jmethodID printerCtor = env->GetMethodID(printerClass, "<init>", "(Ljava/io/Writer;)V");
    if (!printerCtor || env->ExceptionCheck()) return failed();
    jmethodID print = env->GetMethodID(throwableClass, "printStackTrace", "(Ljava/io/PrintWriter;)V");
    if (!print || env->ExceptionCheck()) return failed();
    jobject writer = env->NewObject(writerClass, writerCtor);
    if (!writer || env->ExceptionCheck()) return failed();
    jobject printer = env->NewObject(printerClass, printerCtor, writer);
    if (!printer || env->ExceptionCheck()) return failed();
    env->CallVoidMethod(exception, print, printer);
    if (env->ExceptionCheck()) return failed();
    jstring trace = static_cast<jstring>(env->CallObjectMethod(writer, toString));
    if (!trace || env->ExceptionCheck()) return failed();
    std::string result;
    if (!readJavaString(env, trace, result)) return failed();
    return result;
}

static void logJavaStackTrace(const std::string& trace) {
    if (trace.empty()) return;
    std::istringstream iss(trace);
    std::string line;
    int lineCount = 0;
    while (std::getline(iss, line)) {
        if (line.empty()) continue;
        AMCL_LOG_E(LOG_TAG, "JavaTrace: %{public}s", line.c_str());
        lineCount++;
        if (lineCount >= 120) {
            AMCL_LOG_E(LOG_TAG, "JavaTrace: ... (truncated)");
            break;
        }
    }
}

// ============================================================
//  JVM 初始化
// ============================================================

/**
 * 初始化一次 JVM。进入运行时装载后，即使失败，本进程也不能再次创建。
 * @param appFilesDir  应用 filesDir 路径
 * @param jdkVersion   JDK 版本号（如 "17"），NULL 则使用默认路径 filesDir/jdk/
 * @return 0 成功，负数失败
 */
// JVM 映射开始后进程不能重建另一运行时；共享租约与该进程同寿命。
static int g_jdkDirectoryLeaseFd = -1;

// 两参数 C ABI 保留给 processor、NCP 资格和独立诊断，不隐式改变其 cwd。
extern "C" int jvmInit(const char* appFilesDir, const char* jdkVersion) {
    return jvmInit(appFilesDir, jdkVersion, nullptr);
}

// MC 显式传入已选目录；所有既有前置检查、认领和创建状态都只在本主体执行一次。
int jvmInit(const char* appFilesDir, const char* jdkVersion, const char* gameWorkingDirectory) {
    return jvmInit(appFilesDir, jdkVersion, gameWorkingDirectory, nullptr);
}

// appFilesDir保留现有运行包安装根语义；仅隔离NCP通过第4参给真实应用父根。
// 目录准备、环境发布、失败回滚及CreateVM边界只有此单一owner，NCP不另写TMPDIR。
int jvmInit(const char* appFilesDir, const char* jdkVersion, const char* gameWorkingDirectory,
            const char* trustedAppFilesDir) {
    return jvmInit(appFilesDir, jdkVersion, gameWorkingDirectory, trustedAppFilesDir, false);
}

// 最后一个参数只由游戏启动入口传递；安装器和其他 JVM 创建者不预备手机退出记录。
int jvmInit(const char* appFilesDir, const char* jdkVersion, const char* gameWorkingDirectory,
            const char* trustedAppFilesDir, bool returnToLauncherOnExit) {
    const int runtimeState = g_runtimeOnce.state();
    if (runtimeState == amcl::jvm::RuntimeOnce::ForkReserved) {
        g_status = "安装器正在创建子进程，请稍后重试";
        return -8;
    }
    if (runtimeState != amcl::jvm::RuntimeOnce::Fresh || g_jvm) {
        g_status = "JVM 运行身份已锁定，请重启游戏进程";
        AMCL_LOG_E(LOG_TAG, "jvmInit: runtime_restart_required state=%{public}d", g_runtimeOnce.state());
        return -7;
    }
    if (!appFilesDir) {
        g_status = "filesDir 为空";
        return -1;
    }

    // 用户/加载器字符串不能提供 Invocation API 回调指针。此处同时覆盖 processor 和
    // 诊断入口，不能仅依赖游戏 profile 的属性冻结；错误参数在触碰 JVM/loader 前拒绝。
    for (const auto& argument : g_extraArgs) {
        if (amcl::jvm::IsReservedInvocationHookOption(argument)) {
            g_status = "JVM 参数不能覆盖宿主退出/中止/输出回调";
            AMCL_LOG_E(LOG_TAG, "runtime_invocation_hook_override");
            return -9;
        }
    }

    AMCL_LOG_I(LOG_TAG, "=== jvmInit START ===");

    // JDK 目录：filesDir/jdk/<version>/（如 filesDir/jdk/17/）
    std::string jdkDataDir;
    if (jdkVersion && jdkVersion[0] != '\0') {
        jdkDataDir = std::string(appFilesDir) + "/jdk/" + jdkVersion;
    } else {
        jdkDataDir = std::string(appFilesDir) + "/jdk";
    }
    AMCL_LOG_I(LOG_TAG, "JDK path: %{public}s", jdkDataDir.c_str());
    amcl::jdk::DirectoryReadLease directoryLease;
    std::string leaseError;
    if (!directoryLease.acquire(appFilesDir, jdkVersion, leaseError)) {
        g_status = leaseError;
        AMCL_LOG_E(LOG_TAG, "jdk_runtime_in_use: %{public}s", leaseError.c_str());
        return -12;
    }
    // 读者在同一 SH 内检查稳定 journal，不能边读半完成发布边尝试升级为写锁。
    // 需要恢复时栈租约随返回释放，由安装协调层取得 writer/use.EX 恢复后重新启动。
    try {
        // 无版本的旧兼容目录不属于数字槽事务；不能把它伪造为传给安装器的 major。
        if (jdkVersion && jdkVersion[0] && amcl::jdk::InstallRecoveryRequired(appFilesDir, jdkVersion)) {
            g_status = "JDK 安装事务尚待恢复，请先完成运行时恢复后重试";
            return -13;
        }
    } catch (const std::exception& error) {
        g_status = "无法核实 JDK 安装事务: " + std::string(error.what());
        return -13;
    }
    // 同一SH租约下读取release，目录布局/slot名/native-temp marker都不冒充版本身份。
    // 未知只保留原自动规避，不成为新的启动错误；后续显式compiler参数完全不参与此决策。
    const auto releaseIdentity = amcl::jvm::ReadReleaseMajor(jdkDataDir, jdkVersion);
    bool addAutomaticCfExclusion = amcl::jvm::NeedsLegacyCfDefault(releaseIdentity);
#ifdef MC_OHOS_BUILD_TESTS
    // 固定CF资格臂自行提供完整规则，避免把生产默认变更悄悄计入旧broad/full实验。
    if (g_forkChildMode && g_qualificationCfExplicit) addAutomaticCfExclusion = false;
#endif
    AMCL_LOG_I(LOG_TAG, "CF automatic default: releaseMajor=%{public}d status=%{public}s broad=%{public}d",
               releaseIdentity.major, releaseIdentity.status, addAutomaticCfExclusion ? 1 : 0);
    std::string fontsConfiguration, classicFontProperties, fontError;
    if (!amcl::jdk::PrepareFontResources(appFilesDir, fontsConfiguration, classicFontProperties, fontError)) {
        g_status = "字体配置准备失败: " + fontError;
        return -14;
    }

    // ============================================================
    // 查找 libjvm.so（ELF loader 模式，从 filesDir 加载）
    // 支持两种目录布局：lib/server/libjvm.so 和 lib/libjvm.so
    // ============================================================
    std::string nativeLibDir = jdkDataDir + "/lib";
    // JDK 8 经典布局（无模块系统）：libjvm 在 jre/lib/<arch>/server/，rt.jar 在 jre/lib/。
    // 仅当检测到该布局才切换；模块化布局（17/21/25）路径完全不变。
    std::string classicLibDir = jdkDataDir + "/jre/lib/aarch64";
    bool classicLayout = false;
    if (fileExists((classicLibDir + "/server/libjvm.so").c_str())) {
        nativeLibDir = classicLibDir;
        classicLayout = true;
        AMCL_LOG_I(LOG_TAG, "Detected classic JDK layout (JDK 8): %{public}s", nativeLibDir.c_str());
    }
    std::string jvmPathServer = nativeLibDir + "/server/libjvm.so";
    std::string jvmPathFlat   = nativeLibDir + "/libjvm.so";
    bool jvmInServer = false;

    if (fileExists(jvmPathServer.c_str())) {
        jvmInServer = true;
        AMCL_LOG_I(LOG_TAG, "Found libjvm.so in server/ layout");
    } else if (fileExists(jvmPathFlat.c_str())) {
        jvmInServer = false;
        AMCL_LOG_I(LOG_TAG, "Found libjvm.so in flat layout");
    } else {
        g_status = "❌ libjvm.so 不存在！请先下载 JDK。";
        AMCL_LOG_E(LOG_TAG, "libjvm.so not found in %{public}s", nativeLibDir.c_str());
        return -1;
    }

    const std::string jvmPath = jvmInServer ? jvmPathServer : jvmPathFlat;
    std::string nativeTempError;
    const auto nativeTempContract = amcl::jvm::ReadNativeTempContractFile(jvmPath, nativeTempError);
    if (nativeTempContract == amcl::jvm::NativeTempContract::Invalid) {
        g_status = "JDK原生临时目录合同无效: " + nativeTempError;
        return -17;
    }
    amcl::jvm::PreparedNativeTempRoot nativeTempRoot;
    if (nativeTempContract == amcl::jvm::NativeTempContract::StartupTmpdirV1) {
        // 嵌入宿主已有可信应用根；系统继承TMPDIR不是用户配置，不能选作私有工具目录。
        // 复用本次prepare的实际分支/元数据；诊断不另执行探针、不枚举环境或调整权限。
        amcl::jvm::NativeTempPreparationTrace tempTrace;
        const int tempPreparation = nativeTempRoot.prepareEmbedded(
            trustedAppFilesDir ? trustedAppFilesDir : appFilesDir, &tempTrace);
        if (tempPreparation != 0) {
            g_status = "JVM原生临时目录不可用 (errno=" + std::to_string(tempPreparation) +
                "); nativeTempPreparation=" + tempTrace.json(tempPreparation);
            return -17;
        }
    }
    // 老包缺少marker时不准备目录、不改TMPDIR，继续保留既有两条自动禁用参数。
    amcl::jvm::NativeTempEnvironment nativeTempEnvironment([](int error) noexcept {
        // 状态对象持有自己的锁，只能先取独立快照、在锁外拼接再发布；不借出共享字符串。
        // 此通知可能发生在析构/异常展开中，状态文本分配失败不能再次抛出而掩盖原启动错误。
        try {
            g_status = g_status.snapshot() + "；TMPDIR恢复失败 (errno=" + std::to_string(error) + ")";
        } catch (...) {
            // 保留原状态，下面的固定格式原生日志仍记录实际恢复errno。
        }
        AMCL_LOG_E(LOG_TAG, "native_temp_environment_restore_failed errno=%{public}d", error);
    });

    // boot class path 核心文件检查：模块化 = lib/modules；JDK 8 经典 = jre/lib/rt.jar。
    if (!classicLayout) {
        std::string modulesPath = jdkDataDir + "/lib/modules";
        if (!fileExists(modulesPath.c_str())) {
            g_status = "❌ lib/modules 不存在！JDK 数据不完整，请删除 JDK 后重新下载。";
            AMCL_LOG_E(LOG_TAG, "FATAL: %{public}s not found!", modulesPath.c_str());
            return -1;
        }
    } else {
        std::string rtJar = jdkDataDir + "/jre/lib/rt.jar";
        if (!fileExists(rtJar.c_str())) {
            g_status = "❌ rt.jar 不存在！JDK 8 数据不完整，请删除 JDK 后重新下载。";
            AMCL_LOG_E(LOG_TAG, "FATAL: %{public}s not found!", rtJar.c_str());
            return -1;
        }
    }

    // 此处只取得选中目录的描述符，失败时原 cwd 与 Fresh 身份都不变。实际 fchdir 必须
    // 晚于下面的原子认领，避免 processor fork 保留窗口复制到一半变更的进程 cwd。
    amcl::jvm::GameWorkingDirectory gameDirectory;
    const int gameDirectoryPreparation = gameDirectory.prepare(gameWorkingDirectory);
    if (gameDirectoryPreparation != 0) {
        g_status = "游戏工作目录不可用 (errno=" + std::to_string(gameDirectoryPreparation) + ")";
        AMCL_LOG_E(LOG_TAG, "game_working_directory_prepare_failed errno=%{public}d", gameDirectoryPreparation);
        return -16;
    }

    // 堆参数在任何一次性认领、信号变更或 libjvm 装载之前检查。用户可以修正非法输入后
    // 再启动；不能让 HotSpot 在 Xms>Xmx 时直接退出当前进程，丢掉可展示的错误原因。
    amcl::jvm::HeapOptions heapOptions;
    std::string heapError;
    if (!amcl::jvm::ResolveHeapOptions(g_xmxMb, g_extraArgs, classicLayout, heapOptions, heapError)) {
        g_status = "JVM 堆参数无效: " + heapError;
        AMCL_LOG_E(LOG_TAG, "jvm_heap_options_rejected reason=%{public}s", heapError.c_str());
        return -11;
    }

    // 文件背书与堆容量独立：使用上面按真实参数顺序得到的最终最大堆做磁盘准入。
    // 失败发生在一次性认领前，不静默带着显式大-Xmx切回RAM，不清理共享目录。
    amcl::jvm::HeapBackingRequest heapBacking;
    amcl::jvm::PreparedHeapBackingDirectory heapDirectory;
    if (!amcl::jvm::ResolveHeapBackingRequest(g_extraArgs, releaseIdentity.major, classicLayout,
            getenv("JAVA_TOOL_OPTIONS"), getenv("_JAVA_OPTIONS"), getenv("JDK_AOT_VM_OPTIONS"),
            heapBacking, heapError) ||
        (heapBacking.enabled && !heapDirectory.prepare(trustedAppFilesDir ? trustedAppFilesDir : appFilesDir,
            heapBacking, heapOptions.maximumBytes, heapError))) {
        g_status = "文件堆准备失败（未回退普通内存）: " + heapError;
        AMCL_LOG_E(LOG_TAG, "jvm_heap_backing_rejected reason=%{public}s", heapError.c_str());
        return -11;
    }
    const std::string heapFileOption = heapBacking.enabled ? "-XX:AllocateHeapAt=" + heapDirectory.path() : "";
    if (heapBacking.enabled) AMCL_LOG_I(LOG_TAG,
        "heapfile admitted finalMaximumBytes=%{public}llu requiredDiskBytes=%{public}llu freeDiskBytes=%{public}llu",
        (unsigned long long)heapOptions.maximumBytes, (unsigned long long)heapDirectory.requiredBytes(),
        (unsigned long long)heapDirectory.freeBytes());

    // ============================================================
    // 在改变进程信号/装载运行时前原子认领；后续失败保持非 Fresh，不得再建另一 JVM。
    const int creationClaim = g_runtimeOnce.beginResult();
    if (creationClaim != 0) {
        if (creationClaim == amcl::jvm::RuntimeOnce::ForkBusy) {
            g_status = "安装器正在创建子进程，请稍后重试";
            return -8;
        }
        g_status = "JVM 创建事务已被认领，需要重启进程";
        return -7;
    }

    if (nativeTempContract == amcl::jvm::NativeTempContract::StartupTmpdirV1) {
        const int tempIdentity = nativeTempRoot.revalidate();
        if (tempIdentity != 0) {
            g_status = "JVM原生临时目录发布前身份变化 (errno=" + std::to_string(tempIdentity) + ")";
            return -17;
        }
        const int tempPublication = nativeTempEnvironment.publish(nativeTempRoot.path());
        if (tempPublication != 0) {
            g_status = "JVM原生临时目录环境发布失败 (errno=" + std::to_string(tempPublication) + ")";
            return -17;
        }
    }

    // I27-05：认领之后本进程不会再有第二个 JVM，JNI_CreateJavaVM 一返回就有 JVM 线程。在此封存
    // 环境槽位登记表：此后第一方代码只允许原位改值，登记新名字一律失败并记录。认领之前的可重试
    // 失败不封存，同一进程换路线重试时仍能登记新路线的槽位。
    amcl::ohos::SealProcessEnvironment(g_forkChildMode ? "fork-child-jvm-claim" : "jvm-create-claim");

    // 只有成功认领运行时才保留共享租约；前面的任何可重试失败由栈对象自动释放。
    if (g_jdkDirectoryLeaseFd >= 0) close(g_jdkDirectoryLeaseFd);
    g_jdkDirectoryLeaseFd = directoryLease.releaseToProcess();

    // 必须在一次性创建认领之后准备退出 fd，防止 processor fork 与宿主配置并发。
    // 独立游戏的持锁授权与手机显式选择互斥，安装器不继承任何退出协议。
    // 已授权但准备失败就停止启动，不能退回会被 appspawn 中止的无记录退出路径。
    if (!g_forkChildMode) {
        const int exitPreparation = amclGameExitPrepare(appFilesDir, amclLedgerGetLaunchActivity());
        if (exitPreparation < 0) {
            g_status = "独立游戏退出记录通道准备失败，请重新启动游戏";
            AMCL_LOG_E(LOG_TAG, "isolated_game_exit_prepare_failed rc=%{public}d", exitPreparation);
            return -10;
        }
        if (exitPreparation == 1 && returnToLauncherOnExit &&
            (amcl::jvm::HasImplicitInvocationOptions(getenv("JAVA_TOOL_OPTIONS"), getenv("_JAVA_OPTIONS")) ||
                !amclPhoneExitPrepare(appFilesDir, amclLedgerGetLaunchActivity()))) {
            AMCL_LOG_W(LOG_TAG, "phone_game_exit_restart_unavailable: options or journal preparation");
        }
    }

    // 必须在认领之后才修改共享 loader 路径/JVM 配置，避免 fork 保留窗口内复制到一半写入。
    // 上方仅检查本地字符串与必需文件，缺失 JDK 时仍允许修复文件后在 Fresh 进程重试。
    g_nativeLibDir = nativeLibDir;
    g_jdkDataDir = jdkDataDir;
    std::string searchPaths = nativeLibDir + ":" + nativeLibDir + "/server:" + nativeLibDir + "/jli";
    elf_set_search_path(searchPaths.c_str());
    // Invocation 不读取 JLI 的 jvm.cfg；完整 CLI 所需配置由正式 image 提供，启动器
    // 不能在已认证且持 SH 的 JDK 槽里临时补文件来掩盖损坏或改变载荷身份。

    // java.home 取值：模块化布局（17/21/25）= JDK 根（jdkDataDir，模块在 <home>/lib/modules）；
    // JDK 8 经典布局 = JRE 目录（jdkDataDir/jre），因为 set_boot_path 按 <java.home>/lib/rt.jar
    // 等定位引导类，rt.jar 实际在 jre/lib/ 下。若误用 jdkDataDir 会找 jdk/8/lib/rt.jar（不存在）
    // → VM 初始化期 NoClassDefFoundError: java/lang/Object。
    std::string javaHomeDir = classicLayout ? (jdkDataDir + "/jre") : jdkDataDir;

    // 设置环境变量（HotSpot patch 依赖：os_linux.cpp 用 getenv("JAVA_HOME") 覆盖 dladdr 推断）
    const std::string fontDirectory = fontsConfiguration.substr(0, fontsConfiguration.find_last_of('/'));
    if (setenv("JAVA_HOME", javaHomeDir.c_str(), 1) != 0 ||
        setenv("SUN_BOOT_LIBRARY_PATH", nativeLibDir.c_str(), 1) != 0 ||
        setenv("FONTCONFIG_PATH", fontDirectory.c_str(), 1) != 0 ||
        setenv("FONTCONFIG_FILE", fontsConfiguration.c_str(), 1) != 0) {
        g_status = "JVM 路径/字体环境准备失败 (errno=" + std::to_string(errno) + ")";
        return -14;
    }

    // 中文路径修复（2026-06）：把 locale 钉成 UTF-8。
    // sun.jnu.encoding（JVM 文件名 ↔ 字节转换的编码）在 VM 早期由 OS locale 的
    // CODESET 推断；musl 默认 "C" locale 的 CODESET 报 ASCII → 含中文的 classpath /
    // user.dir / 文件名被损坏（NoSuchFileException / 乱码）。设 LC_ALL/LANG 为 UTF-8
    // locale 让 nl_langinfo(CODESET) 返回 UTF-8 → sun.jnu.encoding=UTF-8。
    // 必须在 JNI_CreateJavaVM 之前 setenv（VM init 时读一次）。与 jvm_common_args.cpp
    // 的 -Dsun.jnu.encoding=UTF-8 / -Dfile.encoding=UTF-8 双保险。
    if (setenv("LC_ALL", "en_US.UTF-8", 1) != 0 || setenv("LANG", "en_US.UTF-8", 1) != 0) {
        g_status = "JVM UTF-8 环境准备失败 (errno=" + std::to_string(errno) + ")";
        return -14;
    }

    // 崩溃现场文件在注册 handler 之前预先打开。下一次冷启动先把它归档到上一条活动账本，
    // 此处已独占 JVM 创建事务，才可以关闭/替换全局 fd 并安全 O_TRUNC。
    if (g_crashTailFd >= 0) close(g_crashTailFd);
    g_crashTailFd = -1;
    if (!g_forkChildMode) {
        std::string crashTailDir = std::string(appFilesDir) + "/logs/system";
        mkdir((std::string(appFilesDir) + "/logs").c_str(), 0755);
        mkdir(crashTailDir.c_str(), 0755);
        g_crashTailFd = open((crashTailDir + "/crash-tail.log").c_str(),
                             O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    }
    g_crashHandlerEntered.clear(std::memory_order_release);
    if (g_crashTailFd >= 0) crashWriteLiteral("AMCL_SIGNAL_SAFE_CRASH_TAIL_V1\n");

    // 同步硬件 fault 不能保持 SIG_IGN。只归一四个同步 signal 中实际被忽略的项，
    // 合法自定义普通 handler 仍由 HotSpot 的 UseSignalChaining 保存并在非 VM 信号时
    // 链回；其消费也属于四参数入口的合法 handled 结果。OHOS 特殊链及其他 signal
    // owner 均保持，禁止 reset 1..31 或把四个同步信号的自定义 owner 一并清空。
    {
        amcl::jvm::PosixSignalActions actions;
        const auto result = amcl::jvm::NormalizeIgnoredJvmSignals(actions);
        if (!result.ok()) {
            g_status = "JVM 被忽略同步信号的归一失败";
            AMCL_LOG_E(LOG_TAG, "synchronous signal handoff failed signal=%{public}d errno=%{public}d rollback=%{public}d",
                result.signal, result.error, result.rollbackError);
            return -15;
        }
        AMCL_LOG_I(LOG_TAG, "JVM ignored synchronous signals normalized; custom and unrelated owners retained");
    }

    // 检测 JIT 权限（RWX mmap）— 必须在加载 libjvm.so 之前！
    // libjvm.so 的 .init_array 中有函数会尝试 mmap(RWX)，无权限时直接崩溃
    g_jitMode = detectJitSupport();
    if (g_jitMode) {
        AMCL_LOG_I(LOG_TAG, "JIT mode: ENABLED (RWX mmap supported)");
    } else {
        AMCL_LOG_E(LOG_TAG, "JIT mode: UNAVAILABLE - no RWX permission, JVM creation aborted");
        g_status = "❌ 无 JIT 权限（RWX mmap 不可用），无法创建 JVM。\n"
                   "HotSpot 需要可执行内存映射权限。\n"
                   "请在 module.json5 中申请 ohos.permission.ALLOW_WRITABLE_CODE_MEMORY 权限。";
        return -5;
    }

    // libjsig.so 跳过：ELF loader 的 elf_dlsym 无法正确实现 RTLD_NEXT 语义
    AMCL_LOG_I(LOG_TAG, "Skipping libjsig.so (using OHOS sigchain)");

    // 加载 JVM 库（通过 ELF loader）
    elf_dlopen((nativeLibDir + "/libcxxabi_shim.so").c_str(), RTLD_NOW | RTLD_GLOBAL);
    void* jvmH = elf_dlopen(jvmPath.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (!jvmH) {
        g_status = std::string("libjvm.so 加载失败: ") + elf_error();
        return -2;
    }

    auto createVM = (JNI_CreateJavaVM_t)elf_dlsym(jvmH, "JNI_CreateJavaVM");
    if (!createVM) {
        g_status = "JNI_CreateJavaVM 符号未找到";
        return -3;
    }

    // JVM 参数（classpath 和 library path 可能很长，用 std::string）
    const std::string opt0 = "-Djava.home=" + javaHomeDir;
    const std::string opt1 = "-Dsun.boot.library.path=" + nativeLibDir;
    // user.home 和 user.dir：优先使用环境变量 AMCL_GAME_DIR（由 launchWithProfileImpl 设置）
    // 这样 JVM 启动时就使用正确的 gameDir，而不是 filesDir
    const char* gameDirEnv = getenv("AMCL_GAME_DIR");
    const char* userHomeDir = (gameDirEnv && gameDirEnv[0]) ? gameDirEnv : appFilesDir;
    const char* userDirDir = (gameDirEnv && gameDirEnv[0]) ? gameDirEnv : appFilesDir;
    const std::string opt3 = std::string("-Duser.home=") + userHomeDir;
    const std::string opt4 = std::string("-Duser.dir=") + userDirDir;
    const std::string opt5 = std::string("-Djava.io.tmpdir=") + appFilesDir;
    // 路径使用完整动态字符串，不能把合法的深层工作目录静默截为 512 字节。
    // Fatal 报告直接归本局，旧工具/processor 沿用原目录，不把别次 JVM 的报告拼进来。
    const std::string fatalDir = amcl::sessionlog::owned()
        ? std::string(amcl::sessionlog::state.directory) + "/jvm" : jdkDataDir;
    const std::string opt6 = "-XX:ErrorFile=" + fatalDir + "/hs_err_pid%p.log";

    // classpath: 优先使用外部设置的，否则默认 appFilesDir
    std::string cpStr = g_classpath.empty() ? std::string(appFilesDir) : g_classpath;
    std::string opt7str = "-Djava.class.path=" + cpStr;
    AMCL_LOG_I(LOG_TAG, "classpath length: %{public}zu chars, jars estimated: ~%{public}zu",
                cpStr.size(), std::count(cpStr.begin(), cpStr.end(), ':') + 1);

    // java.library.path: HAP native dir + 额外路径
    std::string libPathStr = nativeLibDir;
    if (!g_extraLibPath.empty()) {
        libPathStr += ":" + g_extraLibPath;
    }
    std::string opt2str = "-Djava.library.path=" + libPathStr;

    // ============================================================
    // AWT headless 模式（v6 起：放弃 Cacio，走 OpenJDK 自带 headless 路径）
    //
    // 历史：v1-v5 期间项目同时设了 -Djava.awt.headless=false（让 Cacio CTCToolkit
    // 接管）和 jdk21u patch 0009（让 getDefaultHeadlessProperty 返 true），
    // 二者冲突 —— system property 优先级高于 platform default，patch 完全被绕过；
    // 装错 mod 触发 Fabric Swing 错误对话框时崩在 Insets.<clinit>.initIDs（其
    // native 注册在 --enable-headless-only 编译已不构建的 libawt_xawt.so 内）。
    //
    // v6 决策：不再用 Cacio。设 -Djava.awt.headless=true，让 OpenJDK 走
    //   java.awt.GraphicsEnvironment.isHeadless()=true → 所有 AWT 类的
    //   <clinit>（Insets / Rectangle / Color 等）通过 if (!isHeadless()) 保护
    //   跳过 native initIDs() 调用。Toolkit.getDefaultToolkit() 会返回
    //   sun.awt.HeadlessToolkit（标准库自带）；peer 调用全部抛 HeadlessException
    //   或 no-op，不再触达 X11 / xawt 任何 native。
    //
    // 同时设 -Dfabric.noGui=true：Fabric Loader 检测到错误时直接 log 到 stderr，
    // 不再尝试弹 Swing 对话框（即便 isHeadless=true 已经够，多一道防线零成本）。
    //
    // 详见 docs/archive/jdk21-awt-headless-journey-202605.md §5（第一阶段方案）。
    // ============================================================

    // 预检已按最后生效的用户 Xmx/别名计算自动 Xms。显式初始堆保持原输入及覆盖顺序；
    // 不修改 GC/NewRatio/预触页策略。局部 heapOptions 在整个 Invocation 调用期间有效。
    AMCL_LOG_I(LOG_TAG, "JVM heap effective maximum=%{public}llu initial=%{public}llu initialExplicit=%{public}d",
        static_cast<unsigned long long>(heapOptions.maximumBytes),
        static_cast<unsigned long long>(heapOptions.initialBytes), heapOptions.initialExplicit ? 1 : 0);

    // The plan is fixed by mc_launcher before this JVM is created. Expose its
    // validated profile as an early Java property so classes that inspect the
    // runtime identity see the same decision as native; user arguments cannot
    // replace the structured plan marker.
    char graphicsProfileOpt[128] = {0};
    const amcl::graphics::GraphicsPlan* graphicsPlan = amcl::graphics::ActiveGraphicsPlan();
    if (graphicsPlan != nullptr) {
        snprintf(graphicsProfileOpt, sizeof(graphicsProfileOpt),
                 "-Damcl.graphics.profile=%s", graphicsPlan->profile.c_str());
    }

    // ============================================================
    //  JVM 参数集
    //
    //  通用"OHOS 兼容性修复"参数由 amcl::getCommonJvmArgs() 提供，是全局唯一
    //  权威清单（主进程 + Forge installer 子进程 + ArkTS 去重表共享）。
    //  修改共享参数请改 entry/src/main/cpp/jvm/jvm_common_args.cpp。
    //
    //  本文件只负责装入：
    //    - 运行时生成的参数（opt0-opt7str, optXmx，路径/xmx）
    //    - 主进程专属参数（log4j2 / lwjgl.checkThread0 / system.class.loader）
    //    - AWT headless 参数（见下方 java.awt.headless / fabric.noGui）
    //
    //  关键警示（详见 docs/adaptation/JDK_ADAPTATION_GUIDE.md 5.4）：
    //    - 不要关闭 safepoint polling page（不传 -XX:-UsePollingPageSafepoint）
    //    - 不要在 sigchain 里对 fault page 做 mprotect
    //  否则 Forge 的 Module.implAddExportsOrOpens(syncVM=true) 触发全 VM 死锁（黑屏）。
    // ============================================================
    std::vector<JavaVMOption> optVec = {
        // 路径/内存（运行时生成）
        { const_cast<char*>(opt0.c_str()), nullptr }, { const_cast<char*>(opt1.c_str()), nullptr },
        { const_cast<char*>(opt2str.c_str()), nullptr },
        { const_cast<char*>(opt3.c_str()), nullptr }, { const_cast<char*>(opt4.c_str()), nullptr },
        { const_cast<char*>(opt5.c_str()), nullptr },
        { const_cast<char*>(opt7str.c_str()), nullptr },
        { const_cast<char*>(heapOptions.defaultMaximumOption.c_str()), nullptr },
        { const_cast<char*>(opt6.c_str()), nullptr },  // -XX:ErrorFile

        // 主进程专属
        //   Dorg.lwjgl.glfw.checkThread0: LWJGL 默认校验 GLFW 调用的线程 ID，
        //       但我们自实现的 glfw_compat 不跨线程，直接关掉校验避免误报。
        //   Dlog4j2.formatMsgNoLookups: Log4Shell (CVE-2021-44228) 硬加固。
        //   Djava.system.class.loader: 替换系统 CL 为 AmclClassLoader。
        //       JVM 父加载器只拥有 amcl-launcher.jar；游戏 classpath 由该系统 CL
        //       动态挂载，Forge/Fabric 的 custom CL 再从它继承。不要把游戏 jar
        //       放回 java.class.path，否则父优先委派会绕过兼容转换。
        //
        // 分配器跟随实际 LWJGL 槽。现代槽用 RuntimeBootstrapProperties 在 JVM 创建前
        // 固定本包的 jemalloc 绝对路径；旧槽及安装器沿用自己的选择，勿在这里全局指定。
        // 只提供 Java 绑定会在首次分配时才暴露缺库，绑定与原生库须成套验收。
        { (char*)"-Dlog4j2.formatMsgNoLookups=true", nullptr },
        // glfw.checkThread0 / java.system.class.loader 为游戏渲染/类加载专属：
        //   fork 子进程（安装器 processor）不能注入 system.class.loader（AmclClassLoader
        //   不在 processor 干净 classpath 上，会令 JNI_CreateJavaVM 失败）。
        //   故移到下方 if (!g_forkChildMode) 条件追加（与 lwjgl libname 一起）。

        // org.lwjgl.vulkan.libname：必须作为 -D 启动参数（而非仅 System.setProperty）！
        // 根因（2026-06 真机 Vulkan 实验定位）：LWJGL 的 Configuration.VULKAN_LIBRARY_NAME 是
        //   static final 字段，在 Configuration 类 <clinit> 时**一次性**读 System.getProperty
        //   ("org.lwjgl.vulkan.libname") 并缓存（见 lwjgl3 Configuration.java StateInit.STRING）。
        //   之后 VK.create() 只用这个缓存值，不再回读属性。
        //   MC 26.2 的 com.mojang.blaze3d.platform.NativeLibrariesBootstrap.tryLoadingVulkan 在
        //   启动**极早期**就触发 VK.create → 加载 Configuration 类。该时刻早于 mc_launcher 的
        //   phase_setProperties（JNI System.setProperty）执行，故缓存到的是 null → VK.create
        //   在 LINUX 分支回退默认名 libvulkan.so.1。但 OHOS 系统库是 libvulkan.so（无 .1 后缀）
        //   → UnsatisfiedLinkError「Failed to locate library: libvulkan.so.1」→ MC 放弃 Vulkan、
        //   回退 OpenGL（实测 latest.log 06:14:43）。
        //   修法：作为 -D 参数在 JVM 创建时就注入，保证 Configuration <clinit> 读到正确值。
        //   （opengl/glfw/freetype 的 libname 走 setProperty 能 work，是因为它们在 MC 创建 GL
        //    窗口阶段才读、晚于属性设置；唯独 Vulkan 的 bootstrap 读得太早，必须用 -D。）
        // ↑ 见下方 if (!g_forkChildMode) 条件追加。

        // shaderc / spvc libname 同理必须用 -D：Configuration.{SHADERC,SPVC}_LIBRARY_NAME 也是
        //   static final，在上面 tryLoadingVulkan 触发 Configuration <clinit> 那一刻一起被捕获。
        //   若仅靠 phase_setProperties 的 setProperty（晚于 <clinit>），这俩也会捕获到 null →
        //   回退到 mapLibraryNameBundled 默认名。shaderc 默认名 libshaderc.so 恰好对（侥幸），
        //   但 spvc 默认名 libspirv-cross.so 会触发 LWJGL「带连字符全名」正则误判（见
        //   VULKAN_ADAPTATION_PLAN.md Phase 3.1）→ 加载失败。故两者都用 -D 显式注入**裸名**
        //   （System.mapLibraryName 会正确产出 libshaderc.so / libspirv-cross.so）。
        // ↑ vulkan/shaderc/spvc libname 三条同为渲染专属，移到下方 if (!g_forkChildMode) 追加。

        // OHOS 平台标识 — 我们自定义的 system property，与 os.name="Linux" 共存。
        // 历史用途：v1-v5 期间 jdk21u patch 0009 读这个属性切到自带的 OhosHeadlessGE。
        // v6 起 patch 0009 已删（真 headless 模式不需要它），属性保留供未来 OHOS-only
        // Java 代码做平台判断（比如 mc_launcher.cpp / AmclLauncher.java 内的兜底分支）。
        // 不改 os.name 是有意为之：保持上游 LWJGL/MC/mod 的 Linux 路径推断。
        { (char*)"-Damcl.platform.ohos=true", nullptr },

        // AWT headless：v6 起永远开启。详见上方 § AWT headless 模式。
        { (char*)"-Djava.awt.headless=true", nullptr },

        // Fabric noGui：错误时不弹 Swing 对话框（即便 isHeadless=true 也加这条作双保险）。
        // Fabric Loader SystemProperties.NO_GUI = "fabric.noGui"，FabricGuiEntry.displayError
        // 检测到此属性后只 log 到 stderr 后 System.exit(1)，不进 Swing 路径。
        { (char*)"-Dfabric.noGui=true", nullptr },
    };

    // 四代均使用上游 Fontconfig 匹配系统字体。JDK8 的显式 sun.awt.fontconfig
    // 会令 foundOsSpecificFile 保持 true，跳过 FcFontConfiguration 并只采用旧表的
    // Latin 组件；awtfontpath 的目录枚举不会自动补入该逻辑字体的回退链。
    // 真实 provider 现在由运行时提供，因此不再默认注入旧 properties。原用户显式
    // 配置仍按后续自定义 JVM 参数生效，宿主也不改写已认证的 JDK 字体目录。

    // 用户没有提供初始堆时才注入。它仍位于所有用户选项之前，用户 MinHeapSize 的
    // 原始顺序保持不变；显式 -Xms0 的 HotSpot 自动计算含义也不被宿主默认值覆盖。
    if (!heapOptions.automaticInitialOption.empty()) {
        optVec.push_back({ const_cast<char*>(heapOptions.automaticInitialOption.c_str()), nullptr });
    }

    // ============================================================
    // 游戏主进程专属 -D（fork 子进程/安装器 processor 不适用，见 g_forkChildMode）：
    //   - java.system.class.loader=AmclClassLoader：该类在游戏 classpath 上，processor
    //     的干净 classpath 没有它 → 注入会令 JNI_CreateJavaVM 直接失败。
    //   - org.lwjgl.* libname / glfw.checkThread0：渲染相关，processor 是纯构建工具用不到。
    // 详细根因见上方各条原注释。
    // ============================================================
    if (!g_forkChildMode) {
        optVec.push_back({ (char*)"-Dorg.lwjgl.glfw.checkThread0=false", nullptr });
        optVec.push_back({ (char*)"-Djava.system.class.loader=com.amcl.launcher.AmclClassLoader", nullptr });
        if (graphicsProfileOpt[0] != '\0') {
            optVec.push_back({ graphicsProfileOpt, nullptr });
        }
        optVec.push_back({ (char*)"-Dorg.lwjgl.vulkan.libname=libamcl_vulkan_wsi.so", nullptr });
        optVec.push_back({ graphicsPlan && graphicsPlan->window == "SDL3" ?
            (char*)"-Damcl.sdl3=1" : (char*)"-Damcl.sdl3=0", nullptr });
        optVec.push_back({ (char*)"-Dorg.lwjgl.shaderc.libname=shaderc", nullptr });
        optVec.push_back({ (char*)"-Dorg.lwjgl.spvc.libname=spirv-cross", nullptr });
    } else {
        AMCL_LOG_I(LOG_TAG, "fork-child mode: skip game-only -D (system.class.loader / lwjgl libname)");
    }

    // SSOT: 追加共享参数清单（详见 jvm_common_args.cpp）
    //
    // 只要启动方（重型整合包路由）或用户（「自定义 JVM 参数」）显式选了收集器，就跳过
    // SSOT 里的默认收集器，否则 JVM 会报 "Multiple garbage collectors selected" 直接失败。
    //
    // 这里原先只认字面量 -XX:+UseG1GC，于是除 G1 之外的任何选择都会让启动失败 —— 用户在
    // 设置里写 -XX:+UseParallelGC 就会撞上，而那条路径本该是最高优先级。改为识别任意
    // 「-XX:+Use 开头且以 GC 结尾」的开关，这样收集器选择不再和某个特定收集器绑死。
    // 判据对 -XX:+UseCompressedOops、-XX:UseSVE=0 这类同前缀但非收集器的参数不会误伤。
    std::string gcOverride;
    auto isGcSelector = [](const std::string& s) {
        return s.rfind("-XX:+Use", 0) == 0 && s.size() > 10 && s.compare(s.size() - 2, 2, "GC") == 0;
    };
    for (const auto& s : g_extraArgs) {
        if (isGcSelector(s)) { gcOverride = s; break; }
    }
    const auto& commonArgs = amcl::getCommonJvmArgs();
    for (const auto& s : commonArgs) {
        // 只省略新包不再需要的自动保守项；后面的用户显式参数仍原样追加且最后生效。
        if (amcl::jvm::OmitLegacyTempDefault(nativeTempContract, s.c_str())) continue;
        if (!gcOverride.empty() && s != gcOverride && isGcSelector(s)) {
            AMCL_LOG_I(LOG_TAG, "  GC override: skip SSOT %{public}s (%{public}s requested)", s.c_str(),
                       gcOverride.c_str());
            continue;
        }
        optVec.push_back({ const_cast<char*>(s.c_str()), nullptr });
    }

    // 自动项先于所有显式extra参数。这里只添加本方25/unknown旧默认，绝不追加false
    // 或筛掉用户/加载器相同的CompileCommand、CompileOnly、command/directive文件。
    if (addAutomaticCfExclusion) {
        optVec.push_back({ const_cast<char*>(amcl::jvm::LegacyCfExclusion), nullptr });
    }

    // 追加模组加载器的额外 JVM 参数（结构化列表）
    if (!g_extraArgs.empty()) {
        for (auto& s : g_extraArgs) {
            if (s.empty()) continue;
            // 只在最终统一入口产生一个冻结文件堆选项，marker不交给Java业务代码。
            if (amcl::jvm::IsHeapFileMarker(s) || amcl::jvm::IsHeapFileLocation(s)) continue;
            optVec.push_back({ const_cast<char*>(s.c_str()), nullptr });
            AMCL_LOG_I(LOG_TAG, "  extra JVM arg: %{public}s", s.c_str());
        }
    }

    // JavaVMOption 最终只保留每个 -D 键的最后值，与 JVM 原语义相同；不处理 --add-opens 等
    // 允许重复的模块参数。计划属性已经由 FreezeBootstrapProperties 校验，这里只消除
    // 公共默认项与冻结项的等值重复，使产物日志可以直接证明唯一生效值。
    for (size_t i = 0; i < optVec.size();) {
        const auto key = amcl::jvm::PropertyKey(optVec[i].optionString ? optVec[i].optionString : "");
        bool superseded = false;
        if (!key.empty()) {
            for (size_t j = i + 1; j < optVec.size(); ++j) {
                if (key == amcl::jvm::PropertyKey(optVec[j].optionString ? optVec[j].optionString : "")) {
                    superseded = true;
                    break;
                }
            }
        }
        if (superseded) optVec.erase(optVec.begin() + i);
        else ++i;
    }

    // JDK 8（经典布局）无模块系统：剔除 JDK 9+ 才有的 `--add-opens/--add-exports/--add-reads`
    //   等 `--` 长选项。JDK 8 不识别这些选项，且它们以 `--` 开头、不受 ignoreUnrecognized 保护
    //   （后者只忽略以 `-X`/`_` 开头的未知项）→ 会直接令 JNI_CreateJavaVM 失败。
    if (classicLayout) {
        std::vector<JavaVMOption> filtered;
        filtered.reserve(optVec.size());
        size_t dropped = 0;
        for (const auto& o : optVec) {
            if (o.optionString && o.optionString[0] == '-' && o.optionString[1] == '-') {
                AMCL_LOG_I(LOG_TAG, "  [JDK8] strip JDK9+ option: %{public}s", o.optionString);
                dropped++;
                continue;
            }
            filtered.push_back(o);
        }
        optVec.swap(filtered);
        AMCL_LOG_I(LOG_TAG, "Classic JDK8: stripped %{public}zu JDK9+ '--' options", dropped);

        // JDK 8 经典布局的 NIO `sun.nio.fs.DefaultFileSystemProvider.create()` 按 os.name
        //   分派：仅认 "Linux"/"SunOS"/"OS X"/"AIX"，否则抛 AssertionError("Platform not
        //   recognized") 致 VM 初始化失败。OHOS 上 uname().sysname = "HarmonyOS" → os.name
        //   = "HarmonyOS" 不被识别。模块化 JDK（9+）的 NIO provider 是编译期固定的，不走
        //   os.name 分派，故 17/21/25 无此问题。这里仅对经典布局强制 os.name=Linux（-D 覆盖
        //   原生计算值；本就是 linux-target 构建、跑在兼容内核上，语义正确）。
        static const char* kOsNameLinux = "-Dos.name=Linux";
        optVec.push_back({ const_cast<char*>(kOsNameLinux), nullptr });
        AMCL_LOG_I(LOG_TAG, "Classic JDK8: forced -Dos.name=Linux (NIO platform dispatch)");
    }

    // 所有用户参数和 JDK8 过滤结束后才追加唯一的 native-owned hook；不能被后续
    // 同名字符串以空 extraInfo 覆盖。未启用的同进程与 processor 路线不安装。
    if (!g_forkChildMode && amclGameExitArmedForCurrentProcess()) {
        if (amcl::jvm::HasImplicitInvocationOptions(getenv("JAVA_TOOL_OPTIONS"), getenv("_JAVA_OPTIONS"))) {
            g_status = "独立游戏不接受隐式 JVM 环境参数，请改用启动器的自定义 JVM 参数设置";
            // 只记录入口名称，不打印可能包含凭据或本地路径的环境变量内容。
            AMCL_LOG_E(LOG_TAG, "isolated_game_implicit_jvm_options_rejected (JAVA_TOOL_OPTIONS/_JAVA_OPTIONS)");
            return -9;
        }
        optVec.push_back({ const_cast<char*>("exit"), reinterpret_cast<void*>(isolatedGameExitHook) });
        AMCL_LOG_I(LOG_TAG, "AMCL_JVM_EXIT_HOOK armed pid=%{public}d activity=%{public}lld",
            getpid(), amclLedgerGetLaunchActivity());
    } else if (!g_forkChildMode && amclPhoneExitArmed()) {
        optVec.push_back({ const_cast<char*>("exit"), reinterpret_cast<void*>(phoneGameExitHook) });
        AMCL_LOG_I(LOG_TAG, "AMCL_PHONE_JVM_EXIT_HOOK armed pid=%{public}d activity=%{public}lld",
            getpid(), amclLedgerGetLaunchActivity());
    }

    JavaVMInitArgs vm_args;
    if (heapBacking.enabled) {
        // 构建参数期间目录仍可能变化，按持有fd再次核验。显式文件堆不继承
        // 普通RAM的忽略未知选项策略；实际VM管理值还会在CreateVM后再次读回。
        if (!heapDirectory.revalidate(heapError)) {
            g_status = "文件堆目录或空间已改变，请重启游戏进程: " + heapError;
            return -11;
        }
        optVec.push_back({const_cast<char*>(heapFileOption.c_str()),nullptr});
        optVec.push_back({const_cast<char*>("-XX:-IgnoreUnrecognizedVMOptions"),nullptr});
    }
    // JNI 版本随 JDK 布局选择：JDK 8 最高仅支持 JNI_VERSION_1_8，传 JNI_VERSION_10 会被拒
    //   （JNI_CreateJavaVM 立即返回 -3 = JNI_EVERSION）。模块化 JDK（17/21/25）仍用 JNI_VERSION_10。
    vm_args.version = classicLayout ? JNI_VERSION_1_8 : JNI_VERSION_10;
    g_jniVersion = vm_args.version;
    vm_args.nOptions = (jint)optVec.size();
    vm_args.options = optVec.data();
    vm_args.ignoreUnrecognized = heapBacking.enabled ? JNI_FALSE : JNI_TRUE;

    for (int i = 0; i < vm_args.nOptions; i++) {
        AMCL_LOG_I(LOG_TAG, "  opt[%{public}d]: %{public}s", i, optVec[i].optionString);
    }

    // 使用 OpenJDK 为嵌入者导出的四参数入口，不能调用 void 的 javaSignalHandler
    // 再盲目返回 true。OHOS 版 JDK 的普通 handler 不会为未识别异常 abort，旧桥因此把
    // 真实硬件故障吞成信号循环。处理结果只以 VM 返回值为准，不以 PC 是否变化为准。
    struct signal_chain_action {
        bool (*sca_sigaction)(int, siginfo_t*, void*);
        sigset_t sca_mask;
        int sca_flags;
    };
    using AddSpecialHandler = void (*)(int, signal_chain_action*);
    using HotspotSignalHandler = int (*)(int, siginfo_t*, void*, int);
    static HotspotSignalHandler hotspotSignal = nullptr;
    static signal_chain_action jvmChainAction{};
    static_assert(std::atomic<unsigned>::is_always_lock_free, "signal report budget must not acquire a lock");
    static std::atomic<unsigned> unhandledReports{0};
    auto addSpecialHandler = reinterpret_cast<AddSpecialHandler>(dlsym(RTLD_DEFAULT, "add_special_signal_handler"));
    hotspotSignal = reinterpret_cast<HotspotSignalHandler>(elf_dlsym(jvmH, "JVM_handle_linux_signal"));
    if (addSpecialHandler == nullptr || hotspotSignal == nullptr) {
        g_status = "JVM 信号分发接口不完整，请修复运行时后重启游戏";
        AMCL_LOG_E(LOG_TAG, "Required JVM signal contract unavailable: chain=%{public}d hotspot=%{public}d",
            addSpecialHandler != nullptr, hotspotSignal != nullptr);
        return -11;
    }
    if (sigemptyset(&jvmChainAction.sca_mask) != 0) {
        g_status = "JVM 信号桥掩码初始化失败";
        return -15;
    }
    jvmChainAction.sca_flags = 0;
    jvmChainAction.sca_sigaction = [](int sig, siginfo_t* info, void* context) -> bool {
        const int savedErrno = errno;
        const bool diagnosticsReady = g_crashObservationPublished.load(std::memory_order_acquire);
        const bool handled = amcl::jvm::forwardSynchronousSignal(hotspotSignal, sig, info, context);
        if (!handled && info != nullptr && context != nullptr && info->si_code > 0) {
            // 故障路径只写启动前打开的 fd 和栈上十六进制文本，不做分配、符号解析或异步日志入队。
            auto* state = static_cast<ucontext_t*>(context);
            if (diagnosticsReady && unhandledReports.fetch_add(1, std::memory_order_relaxed) < 8) {
                crashWriteLiteral("\nAMCL_UNHANDLED_JVM_SIGNAL_V1\n");
                crashWriteAddressLine("SIGNAL=", static_cast<uintptr_t>(sig));
                crashWriteAddressLine("PC=", static_cast<uintptr_t>(state->uc_mcontext.pc));
                crashWriteAddressLine("FAULT=", reinterpret_cast<uintptr_t>(info->si_addr));
                crashWriteAddressLine("LR=", static_cast<uintptr_t>(state->uc_mcontext.regs[30]));
            }
            // 本机后续普通 JVM handler 也会忽略未知信号，仅返回 false 仍会重试故障指令。
            // 已经确认是同步硬件故障且 VM 没有处理后，使用官方 fatal 路径生成 hs_err；
            // 它按契约不应返回 false。若运行时违约仍返回，立即退出，不能再次空转或刷盘。
            if (hotspotSignal(sig, info, context, 1) != 0) { errno = savedErrno; return true; }
            _exit(128 + sig);
        }
        errno = savedErrno;
        return handled;
    };
    {
        CrashConfigurationWrite write;
        g_crashObservationPublished.store(true, std::memory_order_release);
    }
    // 只接管 HotSpot 可能消费的同步硬件异常。异步终止、采样和平台通知保持各自的所有者。
    for (int sig : {SIGSEGV, SIGBUS, SIGILL, SIGFPE}) addSpecialHandler(sig, &jvmChainAction);
    AMCL_LOG_I(LOG_TAG, "JVM signal bridge ready: boolean result forwarding; unrecognized hardware faults are fatal");

    // SIGABRT 只作特殊链观察者；输出完成后返回 false，让平台 DFX/原普通 owner 按
    // 自己的协议处理。不能为了抓一段栈尾而覆盖应用或平台已有的 abort disposition。
    {
        static signal_chain_action abortAction{};
        if (sigemptyset(&abortAction.sca_mask) != 0) {
            g_status = "JVM 中止观察掩码初始化失败";
            return -15;
        }
        abortAction.sca_flags = 0;
        abortAction.sca_sigaction = [](int sig, siginfo_t* info, void* ctx) -> bool {
            (void)sig;
            (void)info;
            const int savedErrno = errno;
            if (!g_crashObservationPublished.load(std::memory_order_acquire)) return false;
            if (g_crashHandlerEntered.test_and_set(std::memory_order_acquire)) {
                errno = savedErrno;
                return false;
            }
            crashWriteLiteral("\n===== SIGABRT (signal-safe) =====\n");
            if (ctx != nullptr) {
                ucontext_t* uc = static_cast<ucontext_t*>(ctx);
                crashWriteAddressLine("PC=", static_cast<uintptr_t>(uc->uc_mcontext.pc));
                crashWriteAddressLine("FP=", static_cast<uintptr_t>(uc->uc_mcontext.regs[29]));
            }
            crashDumpGameTailDirect();
            crashWriteLiteral("===== SIGABRT end =====\n");
            g_crashHandlerEntered.clear(std::memory_order_release);
            errno = savedErrno;
            return false;
        };
        addSpecialHandler(SIGABRT, &abortAction);
    }

    // Redirect JVM stderr+stdout to a file (survives instant process kill)
    // Pipe approach loses data if process is killed before reader thread runs.
    const bool ownedSessionOutput = amcl::sessionlog::owned();
    std::string stderrFile = ownedSessionOutput ? amcl::sessionlog::jvmPath()
        : std::string(appFilesDir) + "/jvm_stderr.log";
    int origStderr = -1, origStdout = -1;
    if (!g_forkChildMode) {
        // processor 已在任何 JVM 初始化前校验并建立显式日志，不再临时切到跨任务共用的
        // jvm_stderr.log；这样初始化诊断也留在该 processor 的原始 stdout/stderr 合同里。
        int fd = open(stderrFile.c_str(), O_WRONLY | O_CREAT | (ownedSessionOutput ? O_APPEND : O_TRUNC), 0644);
        if (fd >= 0) {
            origStderr = dup(STDERR_FILENO);
            origStdout = dup(STDOUT_FILENO);
            if (origStderr < 0 || origStdout < 0 || dup2(fd, STDERR_FILENO) < 0 || dup2(fd, STDOUT_FILENO) < 0) {
                amcl::sessionlog::failure(errno);
            }
            close(fd);
            AMCL_LOG_I(LOG_TAG, "JVM stderr/stdout → %{public}s", stderrFile.c_str());
        } else { amcl::sessionlog::failure(errno); }
    }
    uint64_t tStart = nowMs();
    JavaVM* jvm = nullptr;
    JNIEnv* env = nullptr;
    // 所有会提前返回的前置工作都已结束，当前已独占 RuntimeOnce。失败的 fchdir 不改变
    // cwd；成功后不再插入可拒绝启动的工作，立即创建 VM，让早期 compiler/agent 线程与
    // 后续游戏看到同一目录。真正 CreateJavaVM 已调用后，即使返回失败也保留一次性失败
    // 身份及该 cwd，不擅自假定未遗留线程。这里只移动原 Phase4 的时机，不限制任何 JIT。
    const int gameDirectoryEntry = gameDirectory.enter();
    jint rc = JNI_ERR;
    if (gameDirectoryEntry == 0) {
        AMCL_LOG_I(LOG_TAG, "Calling JNI_CreateJavaVM at %{public}p ...", (void*)createVM);
        // 此后即使创建失败也不能假定没有残留线程；TMPDIR与runtime一次性身份一起保留。
        nativeTempEnvironment.retainAfterVmEntry();
        rc = createVM(&jvm, (void**)&env, &vm_args);
    }

    // Restore stderr/stdout
    fflush(stderr);
    fflush(stdout);
    if (origStderr >= 0) { if (dup2(origStderr, STDERR_FILENO) < 0) amcl::sessionlog::failure(errno); close(origStderr); }
    if (origStdout >= 0) { if (dup2(origStdout, STDOUT_FILENO) < 0) amcl::sessionlog::failure(errno); close(origStdout); }
    // 原始 JVM stdout/stderr 仅保留在独立可选证据中；启动器只记录 JNI 结果。
    uint64_t elapsed = nowMs() - tStart;
    if (gameDirectoryEntry != 0) {
        // stdio 已恢复，VM 未调用；原 cwd 由 fchdir 的失败语义保留。认领后的失败仍要求
        // 重启进程，不回退 RuntimeOnce 或把已经装载的库/信号准备伪装成 Fresh。
        amcl::sessionlog::finish();
        g_status = "无法进入游戏工作目录，JVM 尚未创建 (errno=" + std::to_string(gameDirectoryEntry) + ")";
        AMCL_LOG_E(LOG_TAG, "game_working_directory_enter_failed errno=%{public}d create_vm_called=0", gameDirectoryEntry);
        return -16;
    }

    AMCL_LOG_I(LOG_TAG, "JNI_CreateJavaVM returned %{public}d in %{public}llu ms", rc, (unsigned long long)elapsed);

    if (rc != JNI_OK || !env) {
        amcl::sessionlog::finish();
        g_status = "JNI_CreateJavaVM 失败 (rc=" + std::to_string(rc) + ")";
        return -4;
    }

    g_jvm = jvm;
    if (heapBacking.enabled) {
        uint64_t actualMaximum = 0;
        if (!amcl::jvm::VerifyHeapBackingVm(env, heapDirectory.path(), heapOptions.maximumBytes,
                                          actualMaximum, heapError)) {
            // VM已存在，保留一次性认领及g_jvm供进程退出；绝不重试第二个RAM JVM。
            g_status = "JVM 文件堆合同未生效，需要结束游戏进程: " + heapError;
            AMCL_LOG_E(LOG_TAG,"heapfile vm verification failed reason=%{public}s",heapError.c_str());
            return -11;
        }
        AMCL_LOG_I(LOG_TAG,"heapfile VM verified actualMaximumBytes=%{public}llu strictOptions=1",
            (unsigned long long)actualMaximum);
    }
    g_runtimeOnce.ready();

    // 创建前后使用同一个有返回值的入口；无需切换到吞异常的中间模式。
    AMCL_LOG_I(LOG_TAG, "JVM signal bridge retained after initialization");

    g_status = "JVM 已就绪";
    AMCL_LOG_I(LOG_TAG, "=== jvmInit SUCCESS (%llu ms) ===", (unsigned long long)elapsed);
    return 0;
}

/**
 * 诊断测试：初始化 JVM + 获取系统属性 + 运行 HelloWorld
 */
#ifdef MC_OHOS_BUILD_TESTS
extern "C" const char* jvmRunFullTest(const char* appFilesDir) {
    (void)appFilesDir; // 保留 ABI；测试类直接定义在独立 loader，不再往已冻结 classpath 旁写无效文件。
    bool expected = false;
    if (!g_testRunning.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
        g_fullTestResult = "测试已在运行中";
        return g_fullTestResult.c_str();
    }
    struct RunningGuard { ~RunningGuard() { g_testRunning.store(false, std::memory_order_release); } } running;
    amcl::jni::InvocationGate::Use use(g_invocationGate);
    JavaVM* vm = g_jvm.load(std::memory_order_acquire);
    if (!use || g_runtimeOnce.state() != 2 || !vm) {
        g_fullTestResult = "JVM 尚未就绪或本局已退休；请在已启动的 Minecraft 会话中运行诊断。";
        return g_fullTestResult.c_str();
    }
    amcl::jni::Environment environment(vm, g_jniVersion, true);
    JNIEnv* env = environment.get();
    if (!env || env->ExceptionCheck()) {
        g_fullTestResult = "无法取得无待处理异常的当前线程 JNIEnv";
        return g_fullTestResult.c_str();
    }
    std::ostringstream output;
    output << "========== JVM 嵌入测试 ==========\n";
    try {
        amcl::jni::LocalFrame frame(env, 48);
        amcl::jni::Failure failure;
        auto execute = [&]() -> bool {
            if (!frame.valid()) return failure.record(env, "PushLocalFrame(diagnostics)");
            jclass system = env->FindClass("java/lang/System");
            if (!failure.require(env, system, "FindClass(System)")) return false;
            jmethodID get = env->GetStaticMethodID(system, "getProperty", "(Ljava/lang/String;)Ljava/lang/String;");
            if (!failure.require(env, get, "System.getProperty")) return false;
            output << "【JVM 系统属性】\n";
            for (const char* property : {"java.version", "java.vm.name", "java.vm.version", "os.name", "os.arch", "java.home"}) {
                jstring key = env->NewStringUTF(property);
                if (!failure.require(env, key, "NewStringUTF(property)")) return false;
                jstring value = static_cast<jstring>(env->CallStaticObjectMethod(system, get, key));
                if (!failure.check(env, "System.getProperty()")) return false;
                output << property << " = ";
                if (value) {
                    std::string text;
                    if (!readJavaString(env, value, text)) return failure.record(env, "read Java property string");
                    output << text << '\n';
                } else output << "(null)\n";
                env->DeleteLocalRef(value); env->DeleteLocalRef(key);
            }
            jclass runtimeClass = env->FindClass("java/lang/Runtime");
            if (!failure.require(env, runtimeClass, "FindClass(Runtime)")) return false;
            jmethodID getRuntime = env->GetStaticMethodID(runtimeClass, "getRuntime", "()Ljava/lang/Runtime;");
            if (!failure.require(env, getRuntime, "Runtime.getRuntime")) return false;
            jobject runtime = env->CallStaticObjectMethod(runtimeClass, getRuntime);
            if (!failure.require(env, runtime, "Runtime.getRuntime()")) return false;
            output << "【JVM Runtime】\n";
            for (const char* name : {"maxMemory", "totalMemory", "freeMemory"}) {
                jmethodID method = env->GetMethodID(runtimeClass, name, "()J");
                if (!failure.require(env, method, name)) return false;
                const jlong bytes = env->CallLongMethod(runtime, method);
                if (!failure.check(env, name)) return false;
                output << name << " = " << bytes / (1024 * 1024) << " MB\n";
            }
            jmethodID cpuMethod = env->GetMethodID(runtimeClass, "availableProcessors", "()I");
            if (!failure.require(env, cpuMethod, "Runtime.availableProcessors")) return false;
            const jint cpus = env->CallIntMethod(runtime, cpuMethod);
            if (!failure.check(env, "Runtime.availableProcessors()")) return false;
            output << "availableProcessors = " << cpus << '\n';
            // 每次诊断拥有独立类加载器，重复调用不重定义同一类，也不借用游戏的 HelloWorld。
            jclass urlClass = env->FindClass("java/net/URL");
            if (!failure.require(env, urlClass, "FindClass(URL)")) return false;
            jclass loaderClass = env->FindClass("java/net/URLClassLoader");
            if (!failure.require(env, loaderClass, "FindClass(URLClassLoader)")) return false;
            jmethodID ctor = env->GetMethodID(loaderClass, "<init>", "([Ljava/net/URL;Ljava/lang/ClassLoader;)V");
            if (!failure.require(env, ctor, "URLClassLoader.<init>")) return false;
            jobjectArray urls = env->NewObjectArray(0, urlClass, nullptr);
            if (!failure.require(env, urls, "NewObjectArray(empty URLs)")) return false;
            jobject loader = env->NewObject(loaderClass, ctor, urls, static_cast<jobject>(nullptr));
            if (!failure.require(env, loader, "NewObject(diagnostic loader)")) return false;
            jclass hello = env->DefineClass("HelloWorld", loader, reinterpret_cast<const jbyte*>(kHelloWorldClass), kHelloWorldClassLen);
            if (!failure.require(env, hello, "DefineClass(HelloWorld)")) return false;
            jmethodID main = env->GetStaticMethodID(hello, "main", "([Ljava/lang/String;)V");
            if (!failure.require(env, main, "GetStaticMethodID(HelloWorld.main)")) return false;
            jclass stringClass = env->FindClass("java/lang/String");
            if (!failure.require(env, stringClass, "FindClass(String)")) return false;
            jobjectArray args = env->NewObjectArray(0, stringClass, nullptr);
            if (!failure.require(env, args, "NewObjectArray(HelloWorld args)")) return false;
            env->CallStaticVoidMethod(hello, main, args);
            if (!failure.check(env, "HelloWorld.main()")) return false;
            output << "HelloWorld: PASS\n";
            return true;
        };
        if (!execute()) {
            output << "诊断失败: " << (failure.stage ? failure.stage : "unknown") << '\n';
            if (failure.exception) {
                env->Throw(failure.exception); env->ExceptionDescribe(); env->ExceptionClear();
                env->DeleteLocalRef(failure.exception);
            }
        }
    } catch (const std::exception& error) {
        if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }
        output << "诊断宿主错误: " << error.what() << '\n';
    }
    const jint detached = environment.finish();
    if (detached != JNI_OK) output << "DetachCurrentThread 失败: " << detached << '\n';
    g_fullTestResult = output.str();
    return g_fullTestResult.c_str();
}

#endif

/** watchdog 的文本出口不持有 JNI 引用；任何文本都在对应 UTF chars 租约内同步消费。 */
struct WatchdogLog {
    void thread(const char* name, jsize depth) {
        AMCL_LOG_I(LOG_TAG, "[WATCHDOG] Thread: %{public}s depth=%{public}d", name, static_cast<int>(depth));
    }
    void frame(const char* text) { AMCL_LOG_I(LOG_TAG, "[WATCHDOG]   at %{public}s", text); }
};

/** 线程所有者在首次等待结束后才附加；停止后先释放本轮局部帧，再准确 detach。 */
static void runWatchdog(void* context, amcl::jni::WatchdogWorker& worker) noexcept {
    if (worker.wait(20000)) return;
    auto* vm = static_cast<JavaVM*>(context);
    amcl::jni::Environment environment(vm, g_jniVersion, true);
    JNIEnv* env = environment.get();
    if (!env) {
        AMCL_LOG_E(LOG_TAG, "[WATCHDOG] JNI environment failed rc=%{public}d", environment.status());
        return;
    }
    try {
        unsigned round = 0;
        while (!worker.stopped()) {
            amcl::jni::LocalFrame frame(env, 32);
            amcl::jni::Failure failure;
            WatchdogLog output;
            AMCL_LOG_I(LOG_TAG, "[WATCHDOG] ==== Thread Dump #%{public}u ====", ++round);
            const bool success = frame.valid()
                ? amcl::jni::dumpThreadStacks(env, failure, output, [&] { return worker.stopped(); })
                : failure.record(env, "watchdog PushLocalFrame");
            if (!success) {
                AMCL_LOG_E(LOG_TAG, "[WATCHDOG] stopped after first JNI failure: %{public}s",
                    failure.stage ? failure.stage : "unknown");
                if (failure.exception) {
                    // 只打印已保存的首个异常，不在资源失败路径继续构造 Java 栈文本。
                    env->Throw(failure.exception);
                    env->ExceptionDescribe();
                    if (env->ExceptionCheck()) env->ExceptionClear();
                    env->DeleteLocalRef(failure.exception);
                }
                break;
            }
            AMCL_LOG_I(LOG_TAG, "[WATCHDOG] ==== End Dump #%{public}u ====", round);
            if (worker.wait(15000)) break;
        }
    } catch (const std::exception& error) {
        if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }
        AMCL_LOG_E(LOG_TAG, "[WATCHDOG] native diagnostic failed: %{public}s", error.what());
    } catch (...) {
        if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }
        AMCL_LOG_E(LOG_TAG, "[WATCHDOG] native diagnostic failed with unknown exception");
    }
    const jint result = environment.finish();
    if (result != JNI_OK) {
        g_watchdogDetachFailure.store(result, std::memory_order_release);
        AMCL_LOG_E(LOG_TAG, "[WATCHDOG] DetachCurrentThread failed rc=%{public}d", result);
    }
}

/** 只在 main 输入全部准备成功后启动既有显式 opt-in 诊断；不开启时不创建线程。 */
static void startRequestedWatchdog() {
    const char* setting = std::getenv("AMCL_JVM_THREAD_DUMP_WATCHDOG");
    const bool enabled = (AMCL_DIAGNOSTICS_MASK & 1) && setting && std::strcmp(setting, "1") == 0;
    if (g_forkChildMode || !enabled) return;
    JavaVM* vm = g_jvm.load(std::memory_order_acquire);
    if (!vm || g_runtimeOnce.state() != amcl::jvm::RuntimeOnce::Ready) return;
    const int result = g_watchdog.start(runWatchdog, vm);
    if (result != 0 && result != EALREADY && result != ECANCELED) {
        AMCL_LOG_E(LOG_TAG, "[WATCHDOG] pthread_create/setup failed: %{public}d", result);
    }
}

/**
 * 当前线程获取环境并拥有局部帧。所有准备失败都在 main 前停止；main 抛出的异常使用
 * 独立阶段报告。只解除本层附加的线程，已有 Java/宿主调用线程继续由其原所有者管理。
 */
extern "C" int jvmCallMain(const char* className, int argc, const char** argv) {
    amcl::jni::InvocationGate::Use use(g_invocationGate);
    JavaVM* vm = g_jvm.load(std::memory_order_acquire);
    if (!use || g_runtimeOnce.state() != 2 || !vm) {
        g_status = "JVM 不处于可调用状态";
        return -1;
    }
    amcl::jni::Environment environment(vm, g_jniVersion);
    JNIEnv* env = environment.get();
    if (!env) {
        g_status = "取得当前线程 JNIEnv 失败 (rc=" + std::to_string(environment.status()) + ")";
        return -1;
    }
    // 调用者已有异常时不执行更多 Java 操作，也不擅自清除调用者的异常。
    if (env->ExceptionCheck()) { g_status = "调用 main 前已有 JNI 异常"; return -1; }
    std::string resultStatus;
    bool success = false;
    bool enteredMain = false;
    try {
        amcl::jni::LocalFrame frame(env, 32);
        amcl::jni::Failure failure;
        if (!frame.valid()) failure.record(env, "PushLocalFrame(main)");
        else success = amcl::jni::callMain(env, className, argc, argv, g_forkChildMode, g_classpath, failure, [] {
            // 可选诊断线程的创建失败不能改变 Java 主程序本身的启动结果。
            try { startRequestedWatchdog(); }
            catch (const std::system_error& error) { AMCL_LOG_E(LOG_TAG, "watchdog start failed: %{public}s", error.what()); }
        });
        enteredMain = failure.enteredMain;
        if (!success) {
            resultStatus = enteredMain ? "main 已执行并失败: " : "main 执行前失败: ";
            resultStatus += failure.stage ? failure.stage : "unknown JNI failure";
            if (failure.exception) {
                // 先把首个异常交给 JVM 打印，再做可失败的补充格式化；后者不覆盖原阶段。
                env->Throw(failure.exception);
                env->ExceptionDescribe();
                if (env->ExceptionCheck()) env->ExceptionClear();
                try {
                    const std::string trace = getThrowableStackTrace(env, failure.exception);
                    if (!trace.empty()) { logJavaStackTrace(trace); resultStatus += "\n" + trace; }
                } catch (const std::exception&) {
                    if (env->ExceptionCheck()) env->ExceptionClear();
                    // 首个阶段和 JVM 已打印的异常仍有效；补充文本失败不能覆盖它。
                }
                env->DeleteLocalRef(failure.exception);
            }
        } else {
            resultStatus = std::string(className) + ".main() 执行完成";
        }
    } catch (const std::exception& error) {
        if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }
        resultStatus = enteredMain ? "main 执行后的宿主错误: " : "main 执行前的宿主错误: ";
        resultStatus += error.what();
        success = false;
    }
    const jint detached = environment.finish();
    if (detached != JNI_OK) {
        AMCL_LOG_E(LOG_TAG, "DetachCurrentThread failed: %{public}d", detached);
        if (success) resultStatus = "main 已返回，但解除宿主线程附加失败 (rc=" + std::to_string(detached) + ")";
        success = false;
    }
    g_status = resultStatus;
    AMCL_LOG_I(LOG_TAG, "main result=%{public}d: %{public}s", success ? 0 : -1, resultStatus.c_str());
    return success ? 0 : -1;
}

/**
 * 销毁只在自有 JNI 调用静止之后执行。关闭闸门不等待正在执行的 Java 主函数，遇忙
 * 返回真实失败，调用者可在原调用结束后再次尝试销毁，但永远不能再次创建 JVM。
 * 借出 JavaVM 的外部 GUI/采样等所有者也必须已经停止；本函数不强杀第三方 native 调用。
 */
static jint finishVm() {
    if (g_destroyInProgress.test_and_set(std::memory_order_acquire)) {
        g_status = "JVM 销毁已在进行中";
        return JNI_ERR;
    }
    struct DestroyGuard { ~DestroyGuard() { g_destroyInProgress.clear(std::memory_order_release); } } guard;
    JavaVM* vm = g_jvm.load(std::memory_order_acquire);
    if (!vm) { g_status = "JVM 未创建或已销毁"; return JNI_ERR; }
    jvmRetireRuntime();
    const int joined = g_watchdog.stopAndJoin();
    if (joined != 0 || g_watchdogDetachFailure.load(std::memory_order_acquire) != JNI_OK) {
        g_status = "JVM 诊断线程未安全结束，拒绝销毁";
        return JNI_ERR;
    }
    if (!g_invocationGate.idle()) {
        g_status = "仍有宿主 JNI 调用正在执行，拒绝销毁 JVM";
        return JNI_ERR;
    }
    jint result;
    if (g_forkChildMode) {
        // processor/NCP工具在当前native线程执行完main；必须先终结该Java线程身份。
        // 否则依赖main.join/isAlive的合法worker（例如管道解码器）会与Destroy互相等待。
        // 普通游戏的线程收尾仍按原契约，不借此假定另一线程创建的VM主线程已经结束。
        const auto completion = amcl::jni::finishLauncherVm(vm);
        if (completion.detached != JNI_OK) {
            g_status = "launcher 主线程解除附加失败 (rc=" + std::to_string(completion.detached) + ")";
            return completion.detached;
        }
        result = completion.destroyed;
    } else {
        result = vm->DestroyJavaVM();
    }
    if (result != JNI_OK) {
        g_status = "DestroyJavaVM 失败 (rc=" + std::to_string(result) + ")";
        return result;
    }
    g_jvm.store(nullptr, std::memory_order_release);
    // OHOS特殊链仍在进程中注册，其他Native线程仍可能SIGABRT。不能在Destroy后关闭
    // FD/清空路径：handler可能已取到旧FD，随后close+重用会写错文件。一个进程只建
    // 一次JVM，因此固定这一个诊断FD及不可变路径与handler同进程寿命，由OS最终关闭；
    // 不清理正在使用的重入标记，也不声称DestroyJavaVM已解除平台signal链。
    g_status = "JVM 已完成非 daemon 工作和正常关闭";
    return JNI_OK;
}

/** processor 不启用周期 watchdog；依然复用同一准确销毁状态与返回值。 */
extern "C" int jvmFinishProcessor(void) {
    if (!g_forkChildMode || !g_jvm.load(std::memory_order_acquire) ||
        g_runtimeOnce.state() != amcl::jvm::RuntimeOnce::Ready) {
        g_status = "processor JVM 不处于可结束状态";
        return JNI_ERR;
    }
    return finishVm();
}

extern "C" void jvmDestroy() {
    const jint result = finishVm();
    if (result == JNI_OK) AMCL_LOG_I(LOG_TAG, "JVM destroyed after owned observers stopped");
    else AMCL_LOG_E(LOG_TAG, "JVM destroy refused/failed rc=%{public}d: %{public}s", result, jvmGetStatus());
}

extern "C" void* jvmGetJavaVM() {
    return static_cast<void*>(g_jvm.load(std::memory_order_acquire));
}

extern "C" void* jvmGetJNIEnv() {
    // 兼容入口只查询当前线程，不隐式附加而把解除责任遗失给无所有权的 void*。
    JNIEnv* env = nullptr;
    amcl::jni::InvocationGate::Use use(g_invocationGate);
    JavaVM* vm = g_jvm.load(std::memory_order_acquire);
    if (!use || g_runtimeOnce.state() != 2 || !vm ||
        vm->GetEnv(reinterpret_cast<void**>(&env), g_jniVersion) != JNI_OK) return nullptr;
    return env;
}

extern "C" const char* jvmGetStatus() {
    // const char* 属于读取线程，下一次同线程查询前有效，不受另一线程发布/销毁影响。
    thread_local std::string snapshot;
    try { snapshot = g_status.snapshot(); return snapshot.c_str(); }
    catch (...) { return "无法分配 JVM 状态快照"; }
}

#ifdef MC_OHOS_BUILD_TESTS
extern "C" int jvmIsTestRunning() {
    return g_testRunning.load(std::memory_order_acquire) ? 1 : 0;
}

#endif
