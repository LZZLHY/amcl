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
 *   支持多版本 JDK（17/21/25），通过 jdkVersion 参数选择
 *
 * HotSpot 源码补丁（权威清单见 prebuilt/jdk/<ver>/patches/series）：
 *   JDK 17: 8 个 —— musl-dlvsym-dlinfo / java-home-env / dll-dir-env / musl-utmpx /
 *           signals-posix-abort / aarch64-elf-safepoint-fallback /
 *           safepoint-mem-prot-read / libjli-skip-re-exec
 *   JDK 21: 8 个 —— 与 17 同构（全部 __MUSL__ 门控）
 *   JDK 25: 9 个 —— 21 的 8 个 + jfr-cpu-time-musl-disable
 *           （JDK 25 新增 JFR CPU-time profiling 用 musl 不支持的 SIGEV_THREAD_ID）
 *           详见 docs/adaptation/JDK25_ADAPTATION_ASSESSMENT.md
 *
 * 历史警示（不要改回去）：
 *   - 不要关 safepoint polling（-XX:-UsePollingPageSafepoint）
 *   - 不要在 sigchain handler 里 mprotect fault page
 *   - 不要传 -XX:+AllowUserSignalHandlers
 *   详见 docs/adaptation/JDK_ADAPTATION_GUIDE.md 5.4 节和 docs/ROADMAP.md。
 */

#include "jvm_launcher.h"
#include "jvm_signal_dispatch.h"
#include "runtime_bootstrap_contract.h"
#include "game_process_exit.h"
#include "elf_loader.h"
#include "jvm_common_args.h"
#include "../platform/graphics_plan.h"
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
static volatile sig_atomic_t g_crashHandlerEntered = 0;

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
extern "C" __attribute__((visibility("default")))
void __clear_cache(void* start, void* end) {
    static size_t ctr_el0 = 0;
    if (ctr_el0 == 0) {
        __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr_el0));
    }
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

// JNI_CreateJavaVM 函数签名
typedef jint (*JNI_CreateJavaVM_t)(JavaVM** pvm, void** penv, void* args);

// ============================================================
//  全局状态
// ============================================================
static std::string g_status;
static std::string g_fullTestResult;
static volatile bool g_testRunning = false;

// JVM 生命周期
static JavaVM* g_jvm = nullptr;
// 一次创建尝试占用本进程；失败、游戏退出或 DestroyJavaVM 不清零 HotSpot/native 身份。
// 安装器只从从未创建 JVM 的父进程 fork；父进程先原子保留，子进程验证 PID 后独立认领。
static amcl::jvm::RuntimeOnce g_runtimeOnce;
extern "C" int jvmRuntimeState() { return g_runtimeOnce.state(); }
extern "C" void jvmRetireRuntime() { g_runtimeOnce.retire(); }
extern "C" int jvmReserveForFork() {
    return g_runtimeOnce.reserveFork(static_cast<uint32_t>(getpid()));
}
extern "C" int jvmReleaseForkReservation() {
    return g_runtimeOnce.releaseFork(static_cast<uint32_t>(getpid())) ? 0 : -1;
}
// JNI 版本：随 JDK 布局在 jvmInit 里确定（JDK 8 经典布局 = JNI_VERSION_1_8，模块化 17/21/25 =
//   JNI_VERSION_10）。后续 GetEnv/AttachCurrentThread 都用它，否则 JDK 8 上传 JNI_VERSION_10 会失败。
static jint g_jniVersion = JNI_VERSION_10;
static JNIEnv* g_env = nullptr;
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
    if (g_jvm || g_env || !g_runtimeOnce.adoptForkChild(static_cast<uint32_t>(getpid()))) {
        return -7;
    }
    g_jvm = nullptr;
    g_env = nullptr;
    if (g_crashTailFd >= 0) {
        close(g_crashTailFd);
        g_crashTailFd = -1;
    }
    g_crashGameOutputPath[0] = '\0';
    g_crashHandlerEntered = 0;
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

static std::string jstringToStdString(JNIEnv* env, jstring s) {
    if (!env || !s) return "";
    const char* c = env->GetStringUTFChars(s, nullptr);
    if (!c) return "";
    std::string out(c);
    env->ReleaseStringUTFChars(s, c);
    return out;
}

static std::string getThrowableStackTrace(JNIEnv* env, jthrowable ex) {
    if (!env || !ex) return "";

    std::string trace;
    jclass swClass = env->FindClass("java/io/StringWriter");
    jclass pwClass = env->FindClass("java/io/PrintWriter");
    jclass throwableClass = env->FindClass("java/lang/Throwable");
    if (!swClass || !pwClass || !throwableClass) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        if (swClass) env->DeleteLocalRef(swClass);
        if (pwClass) env->DeleteLocalRef(pwClass);
        if (throwableClass) env->DeleteLocalRef(throwableClass);
        return "";
    }

    jmethodID swCtor = env->GetMethodID(swClass, "<init>", "()V");
    jmethodID swToString = env->GetMethodID(swClass, "toString", "()Ljava/lang/String;");
    jmethodID pwCtor = env->GetMethodID(pwClass, "<init>", "(Ljava/io/Writer;)V");
    jmethodID printStackTrace = env->GetMethodID(throwableClass, "printStackTrace", "(Ljava/io/PrintWriter;)V");
    if (!swCtor || !swToString || !pwCtor || !printStackTrace) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        env->DeleteLocalRef(swClass);
        env->DeleteLocalRef(pwClass);
        env->DeleteLocalRef(throwableClass);
        return "";
    }

    jobject sw = env->NewObject(swClass, swCtor);
    jobject pw = nullptr;
    if (sw) {
        pw = env->NewObject(pwClass, pwCtor, sw);
    }

    if (sw && pw) {
        env->CallVoidMethod(ex, printStackTrace, pw);
        if (!env->ExceptionCheck()) {
            jstring stack = (jstring)env->CallObjectMethod(sw, swToString);
            if (!env->ExceptionCheck() && stack) {
                trace = jstringToStdString(env, stack);
                env->DeleteLocalRef(stack);
            } else if (env->ExceptionCheck()) {
                env->ExceptionClear();
            }
        } else {
            env->ExceptionClear();
        }
    } else {
        if (env->ExceptionCheck()) env->ExceptionClear();
    }

    if (pw) env->DeleteLocalRef(pw);
    if (sw) env->DeleteLocalRef(sw);
    env->DeleteLocalRef(swClass);
    env->DeleteLocalRef(pwClass);
    env->DeleteLocalRef(throwableClass);
    return trace;
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

/**
 * 确保 jvm.cfg 文件存在
 */
static void ensureJvmCfg(const std::string& libDir) {
    std::string cfgPath = libDir + "/jvm.cfg";
    if (fileExists(cfgPath.c_str())) return;

    FILE* f = fopen(cfgPath.c_str(), "w");
    if (f) {
        fprintf(f, "-server KNOWN\n");
        fclose(f);
        AMCL_LOG_I(LOG_TAG, "Created jvm.cfg at %{public}s", cfgPath.c_str());
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
extern "C" int jvmInit(const char* appFilesDir, const char* jdkVersion) {
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

    // 必须在一次性创建认领之后准备退出 fd，防止 processor fork 与宿主配置并发。
    // 仅 native 持锁授权的当前游戏 PID 可安装；页面路线/安装器不继承此权限。
    // 已授权但准备失败就停止启动，不能退回会被 appspawn 中止的无记录退出路径。
    if (!g_forkChildMode) {
        const int exitPreparation = amclGameExitPrepare(appFilesDir, amclLedgerGetLaunchActivity());
        if (exitPreparation < 0) {
            g_status = "独立游戏退出记录通道准备失败，请重新启动游戏";
            AMCL_LOG_E(LOG_TAG, "isolated_game_exit_prepare_failed rc=%{public}d", exitPreparation);
            return -10;
        }
    }

    // 必须在认领之后才修改共享 loader 路径/JVM 配置，避免 fork 保留窗口内复制到一半写入。
    // 上方仅检查本地字符串与必需文件，缺失 JDK 时仍允许修复文件后在 Fresh 进程重试。
    g_nativeLibDir = nativeLibDir;
    g_jdkDataDir = jdkDataDir;
    std::string searchPaths = nativeLibDir + ":" + nativeLibDir + "/server:" + nativeLibDir + "/jli";
    elf_set_search_path(searchPaths.c_str());
    ensureJvmCfg(nativeLibDir);

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
    g_crashHandlerEntered = 0;
    if (g_crashTailFd >= 0) crashWriteLiteral("AMCL_SIGNAL_SAFE_CRASH_TAIL_V1\n");

    // HotSpot 会保存前任普通处理器并在未知异常时回调它。同步硬件异常不能设为
    // SIG_IGN，否则 VM 会把未识别故障当成“旧处理器已消费”，永远重试同一指令。
    // 先恢复普通处理器默认值；下面在创建 JVM 前登记 OHOS 特殊链，优先处理真正的 VM 信号。
    {
        struct sigaction clean_sa{};
        sigemptyset(&clean_sa.sa_mask);
        clean_sa.sa_handler = SIG_DFL;
        for (int sigid = 1; sigid < 32; sigid++) {
            if (sigid != SIGKILL && sigid != SIGSTOP) sigaction(sigid, &clean_sa, nullptr);
        }
        AMCL_LOG_I(LOG_TAG, "Ordinary signal dispositions reset to default before JVM ownership");
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
    std::string jvmPath = jvmInServer
        ? (nativeLibDir + "/server/libjvm.so")
        : (nativeLibDir + "/libjvm.so");
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

    // java.home 取值：模块化布局（17/21/25）= JDK 根（jdkDataDir，模块在 <home>/lib/modules）；
    // JDK 8 经典布局 = JRE 目录（jdkDataDir/jre），因为 set_boot_path 按 <java.home>/lib/rt.jar
    // 等定位引导类，rt.jar 实际在 jre/lib/ 下。若误用 jdkDataDir 会找 jdk/8/lib/rt.jar（不存在）
    // → VM 初始化期 NoClassDefFoundError: java/lang/Object。
    std::string javaHomeDir = classicLayout ? (jdkDataDir + "/jre") : jdkDataDir;

    // 设置环境变量（HotSpot patch 依赖：os_linux.cpp 用 getenv("JAVA_HOME") 覆盖 dladdr 推断）
    setenv("JAVA_HOME", javaHomeDir.c_str(), 1);
    setenv("SUN_BOOT_LIBRARY_PATH", nativeLibDir.c_str(), 1);

    // 中文路径修复（2026-06）：把 locale 钉成 UTF-8。
    // sun.jnu.encoding（JVM 文件名 ↔ 字节转换的编码）在 VM 早期由 OS locale 的
    // CODESET 推断；musl 默认 "C" locale 的 CODESET 报 ASCII → 含中文的 classpath /
    // user.dir / 文件名被损坏（NoSuchFileException / 乱码）。设 LC_ALL/LANG 为 UTF-8
    // locale 让 nl_langinfo(CODESET) 返回 UTF-8 → sun.jnu.encoding=UTF-8。
    // 必须在 JNI_CreateJavaVM 之前 setenv（VM init 时读一次）。与 jvm_common_args.cpp
    // 的 -Dsun.jnu.encoding=UTF-8 / -Dfile.encoding=UTF-8 双保险。
    setenv("LC_ALL", "en_US.UTF-8", 1);
    setenv("LANG", "en_US.UTF-8", 1);

    // JVM 参数（classpath 和 library path 可能很长，用 std::string）
    char opt0[512], opt1[512], opt3[512], opt4[512], opt5[512], opt6[512];
    snprintf(opt0, sizeof(opt0), "-Djava.home=%s", javaHomeDir.c_str());
    snprintf(opt1, sizeof(opt1), "-Dsun.boot.library.path=%s", nativeLibDir.c_str());
    // user.home 和 user.dir：优先使用环境变量 AMCL_GAME_DIR（由 launchWithProfileImpl 设置）
    // 这样 JVM 启动时就使用正确的 gameDir，而不是 filesDir
    const char* gameDirEnv = getenv("AMCL_GAME_DIR");
    const char* userHomeDir = (gameDirEnv && gameDirEnv[0]) ? gameDirEnv : appFilesDir;
    const char* userDirDir = (gameDirEnv && gameDirEnv[0]) ? gameDirEnv : appFilesDir;
    snprintf(opt3, sizeof(opt3), "-Duser.home=%s", userHomeDir);
    snprintf(opt4, sizeof(opt4), "-Duser.dir=%s", userDirDir);
    snprintf(opt5, sizeof(opt5), "-Djava.io.tmpdir=%s", appFilesDir);
    // snprintf 只需要把 %p 原样交给 HotSpot；%% 是 C 格式串中的一个字面 %。
    // 旧代码用了 %%%%p，生成的参数多了一层转义，可能无法按 pid 分文件。
    // Fatal 报告直接归本局，旧工具/processor 沿用原目录，不把别次 JVM 的报告拼进来。
    const std::string fatalDir = amcl::sessionlog::owned()
        ? std::string(amcl::sessionlog::state.directory) + "/jvm" : jdkDataDir;
    snprintf(opt6, sizeof(opt6), "-XX:ErrorFile=%s/hs_err_pid%%p.log", fatalDir.c_str());

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

    // Xmx
    char optXmx[64];
    snprintf(optXmx, sizeof(optXmx), "-Xmx%dm", g_xmxMb > 0 ? g_xmxMb : 128);

    // ============================================================
    //  -Xms：初始堆。2026-08-30 落地，此前从未传过（只传 -Xmx）。
    //
    //  为什么需要它（算据）：HotSpot 默认初始堆是 max(MinHeapSize, 物理内存/64)
    //  ⇒ 本机 11.8 GB 约 184 MB，ParallelGC 默认 NewRatio=2 ⇒ eden 约 48 MB，
    //  而 MC 每秒分配几百 MB。这会造成 young GC 频繁 + 反复扩堆 +
    //  UseAdaptiveSizePolicy 每次 GC 重算分代比例，而 ParallelGC 全程
    //  stop-the-world ⇒ 收集次数多 = 渲染线程被冻结次数多。
    //
    //  ⭐ 这条推断已被真机证据坐实（这也是它从"待办"变成"落地"的唯一理由）：
    //  2026-08-30 在 MC 1.18.2 + Fabric 0.19.3 上采到 -Xlog:gc* 全量日志，约 72 秒内
    //  Pause Young 185 次 / 合计 3109.5 ms / 最长 117.6 ms（另有 Full 4 次 / 905.7 ms /
    //  最长 461.5 ms）。185 次 young GC 正是 eden 只有 48 MB 的直接后果。
    //
    //  取值：Xmx 的一半，钳在 [512, 1024] MB。上限保守是因为本设备有被 lowmemkiller
    //  杀的历史（CHANGELOG 1000248 / 1000250 / 1000251）；-Xms 只 commit 不 pre-touch
    //  （**不要**加 AlwaysPreTouch），所以 RSS 仍按实际使用增长。
    //
    //  ⚠️ 最后那道夹取不是冗余：g_xmxMb 未设时上面的兜底是 128 MB，而下限 512 会让
    //  Xms > Xmx —— HotSpot 对此是**拒绝启动**（不是降级）。任何以后调整钳位区间的人
    //  都必须保留这一条。
    //
    //  ⚠️ 刻意不一并改 NewRatio / -Xmn / -XX:-UseAdaptiveSizePolicy —— 那些是另外的
    //  变量，混在一批里改会让真机 A/B 无法归因（1000488 就是两个变量同时改的教训）。
    // ============================================================
    char optXms[64];
    {
        const int xmxMb = g_xmxMb > 0 ? g_xmxMb : 128;
        int xmsMb = xmxMb / 2;
        if (xmsMb < 512) xmsMb = 512;
        if (xmsMb > 1024) xmsMb = 1024;
        if (xmsMb > xmxMb) xmsMb = xmxMb;
        snprintf(optXms, sizeof(optXms), "-Xms%dm", xmsMb);
    }

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
        { opt0, nullptr }, { opt1, nullptr },
        { const_cast<char*>(opt2str.c_str()), nullptr },
        { opt3, nullptr }, { opt4, nullptr }, { opt5, nullptr },
        { const_cast<char*>(opt7str.c_str()), nullptr },
        { optXmx, nullptr },
        // 装在这里（而不是追加到末尾）是有意的：g_extraArgs 在本 vector 之后装入，
        // HotSpot 对重复的 -Xms 取最后一个 ⇒ 用户在「自定义 JVM 参数」里写的 -Xms
        // 仍然覆盖这里的注入值，与 ArkTS 侧「用户参数最高优先级」的约定一致。
        { optXms, nullptr },
        { opt6, nullptr },  // -XX:ErrorFile

        // 主进程专属
        //   Dorg.lwjgl.glfw.checkThread0: LWJGL 默认校验 GLFW 调用的线程 ID，
        //       但我们自实现的 glfw_compat 不跨线程，直接关掉校验避免误报。
        //   Dlog4j2.formatMsgNoLookups: Log4Shell (CVE-2021-44228) 硬加固。
        //   Djava.system.class.loader: 替换系统 CL 为 AmclClassLoader。
        //       JVM 父加载器只拥有 amcl-launcher.jar；游戏 classpath 由该系统 CL
        //       动态挂载，Forge/Fabric 的 custom CL 再从它继承。不要把游戏 jar
        //       放回 java.class.path，否则父优先委派会绕过兼容转换。
        //
        // ⚠️ 曾尝试 -Dorg.lwjgl.system.allocator=system（移植自 Amethyst-iOS）：
        //   在鸿蒙上会让 MC Render thread 进 Minecraft 主循环后卡死（Forge Initialized
        //   之后静默无输出、窗口黑屏），疑似 OHOS libc malloc 在 LWJGL 小对象高并发分配下
        //   与 JDK 分配器锁竞争。**不要作为 -D 启动参数加**（JavaVMOption.optionString 这一条）。
        //   见 docs/ROADMAP.md 和 2026-04-19 验证日志。
        //
        //   2026-08-02 更新：上面那句「保留 LWJGL 默认分配器（rpmalloc/jemalloc）」已不成立，
        //   本项目从未构建过 OHOS 版 librpmalloc.so / libjemalloc.so，实际生效的一直是 LWJGL
        //   兜底的 StdlibAllocator（即 libc malloc）。理由可复核：LWJGL ≤3.4.1 的 allocator 实现
        //   是顶层类 JEmallocAllocator，它带 `static { JEmalloc.getLibrary(); }`，缺 native 时
        //   Class.forName 当场抛错并被 MemoryManage 的 catch(Throwable) 静默回退。也就是说
        //   「-D system 会黑屏」与「StdlibAllocator 长期在跑且 26.1/26.2 可正常游玩」两条同时
        //   为真，2026-04-19 那次黑屏的归因存疑（原注释本来也只写「疑似」）。若要再动这里，
        //   请先重新取证，不要直接沿用旧结论。
        //
        //   3.4.2 起上游把实现类改成嵌套 JEmalloc$Allocator（无静态块，见 lwjgl3 2ea89788c），
        //   实例化不再触发 native 加载 → 回退机制失效 → 缺 libjemalloc.so 会在第一次 malloc 时
        //   抛 ExceptionInInitializerError 且不可恢复，MC 在 NativeLibrariesBootstrap 阶段直接崩。
        //   因此 lwjgl-jemalloc 已从现代槽位移除，见 deps.lock [lwjgl-jars] 的说明。
        //
        //   注意：`mc_launcher.cpp:phase_setProperties` 里的 `System.setProperty()` 对这个属性
        //   **无效**——Configuration.MEMORY_ALLOCATOR 是 StateInit.STRING，在 Configuration 类
        //   <clinit> 时一次性读取并缓存，而 NativeLibrariesBootstrap.tryLoadingVulkan → VK.create
        //   会在启动极早期就触发该 <clinit>，早于 phase_setProperties（与 vulkan libname 同一个坑，
        //   见下方 org.lwjgl.vulkan.libname 的说明）。详见 ROADMAP "关于 org.lwjgl.system.allocator
        //   =system 的重要澄清" 小节及 docs/archive/forge-analysis/forge-runtime-lwjgl-mismatch-20260328.md。
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
        if (!gcOverride.empty() && s != gcOverride && isGcSelector(s)) {
            AMCL_LOG_I(LOG_TAG, "  GC override: skip SSOT %{public}s (%{public}s requested)", s.c_str(),
                       gcOverride.c_str());
            continue;
        }
        optVec.push_back({ const_cast<char*>(s.c_str()), nullptr });
    }

    // 追加模组加载器的额外 JVM 参数（结构化列表）
    if (!g_extraArgs.empty()) {
        for (auto& s : g_extraArgs) {
            if (s.empty()) continue;
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
    // 同名字符串以空 extraInfo 覆盖。没有授权的同进程/processor 路线完全不安装。
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
    }

    JavaVMInitArgs vm_args;
    // JNI 版本随 JDK 布局选择：JDK 8 最高仅支持 JNI_VERSION_1_8，传 JNI_VERSION_10 会被拒
    //   （JNI_CreateJavaVM 立即返回 -3 = JNI_EVERSION）。模块化 JDK（17/21/25）仍用 JNI_VERSION_10。
    vm_args.version = classicLayout ? JNI_VERSION_1_8 : JNI_VERSION_10;
    g_jniVersion = vm_args.version;
    vm_args.nOptions = (jint)optVec.size();
    vm_args.options = optVec.data();
    vm_args.ignoreUnrecognized = JNI_TRUE;

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
    sigemptyset(&jvmChainAction.sca_mask);
    jvmChainAction.sca_flags = 0;
    jvmChainAction.sca_sigaction = [](int sig, siginfo_t* info, void* context) -> bool {
        const int savedErrno = errno;
        const bool handled = amcl::jvm::forwardSynchronousSignal(hotspotSignal, sig, info, context);
        if (!handled && info != nullptr && context != nullptr && info->si_code > 0) {
            // 故障路径只写启动前打开的 fd 和栈上十六进制文本，不做分配、符号解析或异步日志入队。
            auto* state = static_cast<ucontext_t*>(context);
            if (unhandledReports.fetch_add(1, std::memory_order_relaxed) < 8) {
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
    // 只接管 HotSpot 可能消费的同步硬件异常。异步终止、采样和平台通知保持各自的所有者。
    for (int sig : {SIGSEGV, SIGBUS, SIGILL, SIGFPE}) addSpecialHandler(sig, &jvmChainAction);
    AMCL_LOG_I(LOG_TAG, "JVM signal bridge ready: boolean result forwarding; unrecognized hardware faults are fatal");

    // 注册 SIGABRT handler 来捕获 abort 调用位置
    {
        struct sigaction abortSa;
        memset(&abortSa, 0, sizeof(abortSa));
        sigemptyset(&abortSa.sa_mask);
        abortSa.sa_flags = SA_SIGINFO;
        abortSa.sa_sigaction = [](int sig, siginfo_t* info, void* ctx) {
            (void)info;
            if (g_crashHandlerEntered != 0) _exit(128 + sig);
            g_crashHandlerEntered = 1;
            crashWriteLiteral("\n===== SIGABRT (signal-safe) =====\n");
            if (ctx != nullptr) {
                ucontext_t* uc = static_cast<ucontext_t*>(ctx);
                crashWriteAddressLine("PC=", static_cast<uintptr_t>(uc->uc_mcontext.pc));
                crashWriteAddressLine("FP=", static_cast<uintptr_t>(uc->uc_mcontext.regs[29]));
            }
            crashDumpGameTailDirect();
            crashWriteLiteral("===== SIGABRT end =====\n");
            signal(SIGABRT, SIG_DFL);
            raise(SIGABRT);
        };
        sigaction(SIGABRT, &abortSa, nullptr);
    }

    // Redirect JVM stderr+stdout to a file (survives instant process kill)
    // Pipe approach loses data if process is killed before reader thread runs.
    const bool ownedSessionOutput = amcl::sessionlog::owned();
    std::string stderrFile = ownedSessionOutput ? amcl::sessionlog::jvmPath()
        : std::string(appFilesDir) + "/jvm_stderr.log";
    int origStderr = -1, origStdout = -1;
    {
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
    AMCL_LOG_I(LOG_TAG, "Calling JNI_CreateJavaVM at %{public}p ...", (void*)createVM);

    uint64_t tStart = nowMs();
    JavaVM* jvm = nullptr;
    JNIEnv* env = nullptr;
    jint rc = createVM(&jvm, (void**)&env, &vm_args);

    // Restore stderr/stdout
    fflush(stderr);
    fflush(stdout);
    if (origStderr >= 0) { if (dup2(origStderr, STDERR_FILENO) < 0) amcl::sessionlog::failure(errno); close(origStderr); }
    if (origStdout >= 0) { if (dup2(origStdout, STDOUT_FILENO) < 0) amcl::sessionlog::failure(errno); close(origStdout); }
    // 原始 JVM stdout/stderr 仅保留在独立可选证据中；启动器只记录 JNI 结果。
    uint64_t elapsed = nowMs() - tStart;

    AMCL_LOG_I(LOG_TAG, "JNI_CreateJavaVM returned %{public}d in %{public}llu ms", rc, (unsigned long long)elapsed);

    if (rc != JNI_OK || !env) {
        amcl::sessionlog::finish();
        g_status = "JNI_CreateJavaVM 失败 (rc=" + std::to_string(rc) + ")";
        return -4;
    }

    g_jvm = jvm;
    g_env = env;
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
    if (g_testRunning) {
        g_fullTestResult = "⚠️ 测试已在运行中";
        return g_fullTestResult.c_str();
    }
    g_testRunning = true;

    std::ostringstream ss;
    ss << "========== JVM 嵌入测试 ==========\n\n";

    // 不再在测试中创建 JVM！
    // JVM 只能创建一次，classpath 在创建时固定，之后无法修改。
    // 如果测试先创建了 JVM（classpath 为空），MC 启动时就找不到类。
    // JVM 应该由 mcLaunchWithProfileV2 的启动链创建（bootstrap classpath 正确）。
    if (!g_jvm) {
        ss << "⚠️ JVM 尚未初始化\n\n";
        ss << "请先启动 Minecraft，JVM 会随 MC 一起初始化。\n";
        ss << "MC 启动后可再次运行此测试查看 JVM 状态。\n\n";
        ss << "原因：JVM 只能创建一次，classpath 在创建时固定。\n";
        ss << "如果测试先创建 JVM（无 MC classpath），MC 将无法启动。\n";
        g_testRunning = false;
        g_fullTestResult = ss.str();
        return g_fullTestResult.c_str();
    }

    ss << "jvmInit: ✅ JVM 已就绪\n";
    ss << "状态: " << g_status << "\n\n";

    JNIEnv* env = g_env;

    // 获取 JVM 系统属性
    ss << "【JVM 系统属性】\n";
    jclass systemClass = env->FindClass("java/lang/System");
    if (systemClass) {
        jmethodID getProperty = env->GetStaticMethodID(systemClass, "getProperty",
            "(Ljava/lang/String;)Ljava/lang/String;");
        if (getProperty) {
            const char* props[] = {
                "java.version", "java.vm.name", "java.vm.version",
                "os.name", "os.arch", "java.home"
            };
            for (const char* prop : props) {
                jstring key = env->NewStringUTF(prop);
                jstring val = (jstring)env->CallStaticObjectMethod(systemClass, getProperty, key);
                if (val) {
                    const char* valStr = env->GetStringUTFChars(val, nullptr);
                    ss << "  " << prop << " = " << valStr << "\n";
                    env->ReleaseStringUTFChars(val, valStr);
                } else {
                    ss << "  " << prop << " = (null)\n";
                }
                env->DeleteLocalRef(key);
                if (val) env->DeleteLocalRef(val);
            }
        }
        env->DeleteLocalRef(systemClass);
    }

    // 获取 Runtime 信息
    ss << "\n【JVM Runtime】\n";
    jclass rtClass = env->FindClass("java/lang/Runtime");
    if (rtClass) {
        jmethodID getRuntime = env->GetStaticMethodID(rtClass, "getRuntime", "()Ljava/lang/Runtime;");
        jobject runtime = env->CallStaticObjectMethod(rtClass, getRuntime);
        if (runtime) {
            jlong maxM = env->CallLongMethod(runtime, env->GetMethodID(rtClass, "maxMemory", "()J"));
            jlong totalM = env->CallLongMethod(runtime, env->GetMethodID(rtClass, "totalMemory", "()J"));
            jlong freeM = env->CallLongMethod(runtime, env->GetMethodID(rtClass, "freeMemory", "()J"));
            jint nCpu = env->CallIntMethod(runtime, env->GetMethodID(rtClass, "availableProcessors", "()I"));
            ss << "  maxMemory: " << (maxM / 1024 / 1024) << " MB\n";
            ss << "  totalMemory: " << (totalM / 1024 / 1024) << " MB\n";
            ss << "  freeMemory: " << (freeM / 1024 / 1024) << " MB\n";
            ss << "  availableProcessors: " << nCpu << "\n";
            env->DeleteLocalRef(runtime);
        }
        env->DeleteLocalRef(rtClass);
    }

    if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }

    // HelloWorld 测试
    ss << "\n【HelloWorld 测试】\n";
    std::string classFile = std::string(appFilesDir) + "/HelloWorld.class";
    FILE* cf = fopen(classFile.c_str(), "wb");
    if (cf) {
        fwrite(kHelloWorldClass, 1, kHelloWorldClassLen, cf);
        fclose(cf);
        int callRc = jvmCallMain("HelloWorld", 0, nullptr);
        ss << "  jvmCallMain: " << (callRc == 0 ? "✅" : "❌") << " (rc=" << callRc << ")\n";
    }

    ss << "\n========== 测试完成 ==========\n";
    g_testRunning = false;
    g_fullTestResult = ss.str();
    return g_fullTestResult.c_str();
}

#endif

extern "C" int jvmCallMain(const char* className, int argc, const char** argv) {
    if (!g_jvm || !g_env) {
        g_status = "JVM 未初始化";
        return -1;
    }
    if (!className) {
        g_status = "className 为空";
        return -1;
    }

    AMCL_LOG_I(LOG_TAG, "jvmCallMain: class=%{public}s, argc=%{public}d", className, argc);

    // 调试：通过 Java API 读取实际的 java.class.path
    {
        JNIEnv* dbgEnv = nullptr;
        jint rc2 = g_jvm->GetEnv((void**)&dbgEnv, g_jniVersion);
        if (rc2 == JNI_EDETACHED) g_jvm->AttachCurrentThread((void**)&dbgEnv, nullptr);
        if (dbgEnv) {
            jclass sysClass = dbgEnv->FindClass("java/lang/System");
            if (sysClass) {
                jmethodID getProp = dbgEnv->GetStaticMethodID(sysClass, "getProperty",
                    "(Ljava/lang/String;)Ljava/lang/String;");
                if (getProp) {
                    jstring key = dbgEnv->NewStringUTF("java.class.path");
                    jstring val = (jstring)dbgEnv->CallStaticObjectMethod(sysClass, getProp, key);
                    if (val) {
                        const char* cval = dbgEnv->GetStringUTFChars(val, nullptr);
                        int cpLen = cval ? (int)strlen(cval) : 0;
                        AMCL_LOG_I(LOG_TAG, "java.class.path length=%{public}d", cpLen);
                        if (cval && cpLen > 0) {
                            // 打印前 300 字符
                            std::string preview(cval, std::min(cpLen, 300));
                            AMCL_LOG_I(LOG_TAG, "java.class.path: %{public}s...", preview.c_str());
                        } else {
                            AMCL_LOG_E(LOG_TAG, "java.class.path is EMPTY!");
                        }
                        if (cval) dbgEnv->ReleaseStringUTFChars(val, cval);
                    }
                    dbgEnv->DeleteLocalRef(key);
                }
                dbgEnv->DeleteLocalRef(sysClass);
            }
            if (dbgEnv->ExceptionCheck()) { dbgEnv->ExceptionDescribe(); dbgEnv->ExceptionClear(); }
        }
    }

    // 确保当前线程已 attach 到 JVM
    JNIEnv* env = nullptr;
    jint getEnvRc = g_jvm->GetEnv((void**)&env, g_jniVersion);
    if (getEnvRc == JNI_EDETACHED) {
        g_jvm->AttachCurrentThread((void**)&env, nullptr);
    } else if (getEnvRc != JNI_OK) {
        g_status = "GetEnv 失败 (rc=" + std::to_string(getEnvRc) + ")";
        return -1;
    }

    // className 保持 '.' 格式用于 ClassLoader.loadClass()
    // 同时准备 '/' 格式用于 fallback FindClass
    std::string dotClassName(className);
    std::string jniClassName(className);
    for (char& c : jniClassName) {
        if (c == '.') c = '/';
    }

    // 使用 SystemClassLoader.loadClass() 加载类
    // Invocation Interface 的 FindClass 使用 system CL（不是 TCCL/未来的 Knot/FML）。
    // 本处仅加载启动器/processor 入口，游戏平台类由上游入口按照自己的拓扑加载。
    jclass cls = nullptr;

    jclass classLoaderClass = env->FindClass("java/lang/ClassLoader");
    if (classLoaderClass) {
        jmethodID getSystemCL = env->GetStaticMethodID(classLoaderClass,
            "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
        if (getSystemCL) {
            jobject systemCL = env->CallStaticObjectMethod(classLoaderClass, getSystemCL);
            if (systemCL) {
                jmethodID loadClass = env->GetMethodID(classLoaderClass,
                    "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
                if (loadClass) {
                    jstring jClassName = env->NewStringUTF(dotClassName.c_str());
                    cls = (jclass)env->CallObjectMethod(systemCL, loadClass, jClassName);
                    if (env->ExceptionCheck()) {
                        AMCL_LOG_E(LOG_TAG, "SystemClassLoader.loadClass failed for: %{public}s",
                                     dotClassName.c_str());
                        env->ExceptionDescribe();
                        env->ExceptionClear();
                        cls = nullptr;
                    }
                    env->DeleteLocalRef(jClassName);
                }
                env->DeleteLocalRef(systemCL);
            }
        }
        env->DeleteLocalRef(classLoaderClass);
    }
    if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }

    // 仅独立 processor 的工具兼容回退。游戏必须使用配置好的系统入口，不新建第二个
    // parent=null URLClassLoader；入口缺失即失败，禁止用回退掩盖错误 classpath/运行身份。
    if (!cls && g_forkChildMode && !g_classpath.empty()) {
        AMCL_LOG_I(LOG_TAG, "Trying URLClassLoader fallback with g_classpath (%{public}zu chars)",
                    g_classpath.size());

        // 解析 g_classpath（冒号分隔）为 URL[] 数组
        jclass urlClass = env->FindClass("java/net/URL");
        jclass urlClsLoaderClass = env->FindClass("java/net/URLClassLoader");
        jclass fileClass = env->FindClass("java/io/File");

        if (urlClass && urlClsLoaderClass && fileClass) {
            // 解析 classpath 条目
            std::vector<std::string> cpEntries;
            std::istringstream cpStream(g_classpath);
            std::string entry;
            while (std::getline(cpStream, entry, ':')) {
                if (!entry.empty()) cpEntries.push_back(entry);
            }
            AMCL_LOG_I(LOG_TAG, "URLClassLoader: %{public}zu classpath entries", cpEntries.size());

            // 诊断：打印前 5 个 classpath 条目和文件存在性
            for (int i = 0; i < (int)cpEntries.size() && i < 5; i++) {
                struct stat st;
                bool exists = (stat(cpEntries[i].c_str(), &st) == 0);
                long sz = exists ? (long)st.st_size : -1;
                AMCL_LOG_I(LOG_TAG, "  cp[%{public}d]: exists=%{public}d size=%{public}ld %{public}s",
                            i, exists, sz, cpEntries[i].c_str());
            }

            // 创建 URL[] 数组
            jobjectArray urlArray = env->NewObjectArray((jint)cpEntries.size(), urlClass, nullptr);
            jmethodID fileCtor = env->GetMethodID(fileClass, "<init>", "(Ljava/lang/String;)V");
            jmethodID toURI = env->GetMethodID(fileClass, "toURI", "()Ljava/net/URI;");
            jclass uriClass = env->FindClass("java/net/URI");
            jmethodID toURL = env->GetMethodID(uriClass, "toURL", "()Ljava/net/URL;");

            for (int i = 0; i < (int)cpEntries.size(); i++) {
                jstring jPath = env->NewStringUTF(amcl::toModifiedUtf8(cpEntries[i]).c_str());
                jobject fileObj = env->NewObject(fileClass, fileCtor, jPath);
                jobject uriObj = env->CallObjectMethod(fileObj, toURI);
                jobject urlObj = env->CallObjectMethod(uriObj, toURL);
                env->SetObjectArrayElement(urlArray, i, urlObj);
                env->DeleteLocalRef(jPath);
                env->DeleteLocalRef(fileObj);
                env->DeleteLocalRef(uriObj);
                env->DeleteLocalRef(urlObj);
                if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); break; }
            }

            // new URLClassLoader(urls, null)
            // 使用 null parent 避免 parent-first delegation 到 system classloader
            // system classloader 在 JVM 重用时可能没有 MC jar
            jmethodID urlClCtor = env->GetMethodID(urlClsLoaderClass, "<init>",
                "([Ljava/net/URL;Ljava/lang/ClassLoader;)V");

            jobject urlClassLoader = env->NewObject(urlClsLoaderClass, urlClCtor, urlArray, (jobject)nullptr);
            if (urlClassLoader && !env->ExceptionCheck()) {
                // 设置为当前线程的 context class loader
                jclass threadClass = env->FindClass("java/lang/Thread");
                jmethodID currentThread = env->GetStaticMethodID(threadClass, "currentThread",
                    "()Ljava/lang/Thread;");
                jobject thread = env->CallStaticObjectMethod(threadClass, currentThread);
                jmethodID setContextCL = env->GetMethodID(threadClass, "setContextClassLoader",
                    "(Ljava/lang/ClassLoader;)V");
                env->CallVoidMethod(thread, setContextCL, urlClassLoader);

                // 用 URLClassLoader 加载目标类
                jmethodID loadClass2 = env->GetMethodID(urlClsLoaderClass,
                    "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
                jstring jClassName2 = env->NewStringUTF(dotClassName.c_str());
                cls = (jclass)env->CallObjectMethod(urlClassLoader, loadClass2, jClassName2);
                if (env->ExceptionCheck()) {
                    AMCL_LOG_E(LOG_TAG, "URLClassLoader.loadClass failed for: %{public}s",
                                 dotClassName.c_str());
                    env->ExceptionDescribe();
                    env->ExceptionClear();
                    cls = nullptr;
                } else {
                    AMCL_LOG_I(LOG_TAG, "URLClassLoader loaded: %{public}s", dotClassName.c_str());
                }
                env->DeleteLocalRef(jClassName2);
                env->DeleteLocalRef(thread);
                env->DeleteLocalRef(threadClass);
            } else {
                if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }
                AMCL_LOG_E(LOG_TAG, "Failed to create URLClassLoader");
            }

            if (urlArray) env->DeleteLocalRef(urlArray);
            if (uriClass) env->DeleteLocalRef(uriClass);
        }
        if (urlClass) env->DeleteLocalRef(urlClass);
        if (urlClsLoaderClass) env->DeleteLocalRef(urlClsLoaderClass);
        if (fileClass) env->DeleteLocalRef(fileClass);
        if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }
    }

    // 游戏入口失败不允许偷换类加载拓扑；独立 processor 保留既有工具兼容回退。
    if (!cls && g_forkChildMode) {
        AMCL_LOG_I(LOG_TAG, "Trying FindClass fallback for: %{public}s", jniClassName.c_str());
        cls = env->FindClass(jniClassName.c_str());
    }

    if (!cls) {
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
        }
        g_status = "类未找到: " + dotClassName;
        AMCL_LOG_E(LOG_TAG, "Class not found: %{public}s", dotClassName.c_str());
        return -1;
    }
    AMCL_LOG_I(LOG_TAG, "Class loaded: %{public}s", dotClassName.c_str());

    // 查找 public static void main(String[] args)
    jmethodID mainMethod = env->GetStaticMethodID(cls, "main", "([Ljava/lang/String;)V");
    if (!mainMethod) {
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
        }
        g_status = "main 方法未找到: " + jniClassName;
        AMCL_LOG_E(LOG_TAG, "GetStaticMethodID(main) failed: %{public}s", jniClassName.c_str());
        env->DeleteLocalRef(cls);
        return -1;
    }

    // 构建 String[] args
    jclass stringClass = env->FindClass("java/lang/String");
    jobjectArray jArgs = env->NewObjectArray(argc, stringClass, nullptr);
    for (int i = 0; i < argc; i++) {
        // mcArgs 含 --username 等用户内容 → 必须转 MUTF-8（见 jni_mutf8.h）
        jstring s = env->NewStringUTF(amcl::toModifiedUtf8(argv[i]).c_str());
        env->SetObjectArrayElement(jArgs, i, s);
        env->DeleteLocalRef(s);
    }

    // Full Java thread dumps are only available to the default development product.
    static std::atomic<bool> s_watchdogStarted{false};
    const char* watchdogOptIn = std::getenv("AMCL_JVM_THREAD_DUMP_WATCHDOG");
    const bool watchdogEnabled =
        (AMCL_DIAGNOSTICS_MASK & 1) && watchdogOptIn != nullptr && std::strcmp(watchdogOptIn, "1") == 0;
    if ((AMCL_DIAGNOSTICS_MASK & 1) && !g_forkChildMode && !watchdogEnabled) {
        AMCL_LOG_I(LOG_TAG,
                   "[WATCHDOG] Periodic thread dumps disabled; set "
                   "AMCL_JVM_THREAD_DUMP_WATCHDOG=1 for hang diagnostics");
    }
    bool expected = false;
    if (!g_forkChildMode && watchdogEnabled &&
        s_watchdogStarted.compare_exchange_strong(expected, true)) {
        JavaVM* vmForWatchdog = g_jvm;
        std::thread([vmForWatchdog]() {
            // 给 MC 足够的启动时间再开始 dump
            std::this_thread::sleep_for(std::chrono::seconds(20));
            JNIEnv* wEnv = nullptr;
            JavaVMAttachArgs aargs{};
            aargs.version = g_jniVersion;
            aargs.name = (char*)"amcl-watchdog";
            aargs.group = nullptr;
            if (vmForWatchdog->AttachCurrentThreadAsDaemon((void**)&wEnv, &aargs) != JNI_OK) {
                AMCL_LOG_E(LOG_TAG, "[WATCHDOG] Failed to attach to JVM");
                return;
            }
            AMCL_LOG_I(LOG_TAG, "[WATCHDOG] Attached — will dump Java thread stacks every 15s");
            // 预解析类与方法
            jclass threadCls = wEnv->FindClass("java/lang/Thread");
            jclass mapCls = wEnv->FindClass("java/util/Map");
            jclass mapEntryCls = wEnv->FindClass("java/util/Map$Entry");
            jclass setCls = wEnv->FindClass("java/util/Set");
            jclass iterCls = wEnv->FindClass("java/util/Iterator");
            jclass steCls = wEnv->FindClass("java/lang/StackTraceElement");
            if (wEnv->ExceptionCheck()) wEnv->ExceptionClear();
            if (!threadCls || !mapCls || !mapEntryCls || !setCls || !iterCls || !steCls) {
                AMCL_LOG_E(LOG_TAG, "[WATCHDOG] Failed to resolve classes");
                vmForWatchdog->DetachCurrentThread();
                return;
            }
            jmethodID getAllStacks = wEnv->GetStaticMethodID(threadCls, "getAllStackTraces", "()Ljava/util/Map;");
            jmethodID entrySet = wEnv->GetMethodID(mapCls, "entrySet", "()Ljava/util/Set;");
            jmethodID setIter = wEnv->GetMethodID(setCls, "iterator", "()Ljava/util/Iterator;");
            jmethodID iterHasNext = wEnv->GetMethodID(iterCls, "hasNext", "()Z");
            jmethodID iterNext = wEnv->GetMethodID(iterCls, "next", "()Ljava/lang/Object;");
            jmethodID entryGetKey = wEnv->GetMethodID(mapEntryCls, "getKey", "()Ljava/lang/Object;");
            jmethodID entryGetVal = wEnv->GetMethodID(mapEntryCls, "getValue", "()Ljava/lang/Object;");
            jmethodID threadGetName = wEnv->GetMethodID(threadCls, "getName", "()Ljava/lang/String;");
            jmethodID steToString = wEnv->GetMethodID(steCls, "toString", "()Ljava/lang/String;");
            if (wEnv->ExceptionCheck()) { wEnv->ExceptionClear(); }

            int round = 0;
            while (true) {
                round++;
                AMCL_LOG_I(LOG_TAG, "[WATCHDOG] ==== Thread Dump #%{public}d ====", round);
                jobject allMap = wEnv->CallStaticObjectMethod(threadCls, getAllStacks);
                if (wEnv->ExceptionCheck()) { wEnv->ExceptionClear(); allMap = nullptr; }
                if (!allMap) {
                    AMCL_LOG_W(LOG_TAG, "[WATCHDOG] getAllStackTraces returned null (JVM cannot reach safepoint?)");
                } else {
                    jobject set = wEnv->CallObjectMethod(allMap, entrySet);
                    jobject it = set ? wEnv->CallObjectMethod(set, setIter) : nullptr;
                    while (it && wEnv->CallBooleanMethod(it, iterHasNext)) {
                        jobject entry = wEnv->CallObjectMethod(it, iterNext);
                        jobject thread = wEnv->CallObjectMethod(entry, entryGetKey);
                        jobjectArray stack = (jobjectArray)wEnv->CallObjectMethod(entry, entryGetVal);
                        jstring nameStr = (jstring)wEnv->CallObjectMethod(thread, threadGetName);
                        const char* nameC = nameStr ? wEnv->GetStringUTFChars(nameStr, nullptr) : "?";
                        jsize depth = stack ? wEnv->GetArrayLength(stack) : 0;
                        AMCL_LOG_I(LOG_TAG, "[WATCHDOG] Thread: %{public}s depth=%{public}d", nameC, (int)depth);
                        // 只打印前 12 帧，避免日志爆炸
                        int maxFrames = depth < 12 ? depth : 12;
                        for (int i = 0; i < maxFrames; i++) {
                            jobject ste = wEnv->GetObjectArrayElement(stack, i);
                            jstring s = (jstring)wEnv->CallObjectMethod(ste, steToString);
                            const char* sC = s ? wEnv->GetStringUTFChars(s, nullptr) : "?";
                            AMCL_LOG_I(LOG_TAG, "[WATCHDOG]   at %{public}s", sC ? sC : "?");
                            if (sC && s) wEnv->ReleaseStringUTFChars(s, sC);
                            if (s) wEnv->DeleteLocalRef(s);
                            if (ste) wEnv->DeleteLocalRef(ste);
                        }
                        if (nameC && nameStr) wEnv->ReleaseStringUTFChars(nameStr, nameC);
                        if (nameStr) wEnv->DeleteLocalRef(nameStr);
                        if (stack) wEnv->DeleteLocalRef(stack);
                        if (thread) wEnv->DeleteLocalRef(thread);
                        if (entry) wEnv->DeleteLocalRef(entry);
                    }
                    if (it) wEnv->DeleteLocalRef(it);
                    if (set) wEnv->DeleteLocalRef(set);
                    wEnv->DeleteLocalRef(allMap);
                }
                if (wEnv->ExceptionCheck()) { wEnv->ExceptionClear(); }
                AMCL_LOG_I(LOG_TAG, "[WATCHDOG] ==== End Dump #%{public}d ====", round);
                std::this_thread::sleep_for(std::chrono::seconds(15));
            }
        }).detach();
    }

    // 调用 main
    AMCL_LOG_I(LOG_TAG, "Calling %{public}s.main()...", className);
    env->CallStaticVoidMethod(cls, mainMethod, jArgs);

    // 检查异常 — 提取完整异常信息用于 UI 显示
    if (env->ExceptionCheck()) {
        jthrowable ex = env->ExceptionOccurred();
        env->ExceptionDescribe();  // 输出到 logcat
        env->ExceptionClear();

        // 提取异常类名和消息
        std::string exInfo = dotClassName + ".main() 抛出异常";
        if (ex) {
            // 获取异常类名
            jclass exClass = env->GetObjectClass(ex);
            if (exClass) {
                jclass classClass = env->FindClass("java/lang/Class");
                jmethodID getName = env->GetMethodID(classClass, "getName", "()Ljava/lang/String;");
                jstring exClassName = (jstring)env->CallObjectMethod(exClass, getName);
                if (exClassName) {
                    const char* exNameStr = env->GetStringUTFChars(exClassName, nullptr);
                    exInfo = std::string(exNameStr);
                    env->ReleaseStringUTFChars(exClassName, exNameStr);
                    env->DeleteLocalRef(exClassName);
                }
                env->DeleteLocalRef(classClass);
                env->DeleteLocalRef(exClass);
            }

            // 获取异常消息
            jclass throwableClass = env->FindClass("java/lang/Throwable");
            jmethodID getMessage = env->GetMethodID(throwableClass, "getMessage", "()Ljava/lang/String;");
            jstring msg = (jstring)env->CallObjectMethod(ex, getMessage);
            if (msg) {
                const char* msgStr = env->GetStringUTFChars(msg, nullptr);
                exInfo += ": " + std::string(msgStr);
                env->ReleaseStringUTFChars(msg, msgStr);
                env->DeleteLocalRef(msg);
            }

            // 获取 cause
            jmethodID getCause = env->GetMethodID(throwableClass, "getCause", "()Ljava/lang/Throwable;");
            jthrowable cause = (jthrowable)env->CallObjectMethod(ex, getCause);
            if (cause) {
                jclass causeClass = env->GetObjectClass(cause);
                jclass classClass2 = env->FindClass("java/lang/Class");
                jmethodID getName2 = env->GetMethodID(classClass2, "getName", "()Ljava/lang/String;");
                jstring causeName = (jstring)env->CallObjectMethod(causeClass, getName2);
                jstring causeMsg = (jstring)env->CallObjectMethod(cause, getMessage);
                if (causeName) {
                    const char* s = env->GetStringUTFChars(causeName, nullptr);
                    exInfo += "\n  Caused by: " + std::string(s);
                    env->ReleaseStringUTFChars(causeName, s);
                    env->DeleteLocalRef(causeName);
                }
                if (causeMsg) {
                    const char* s = env->GetStringUTFChars(causeMsg, nullptr);
                    exInfo += ": " + std::string(s);
                    env->ReleaseStringUTFChars(causeMsg, s);
                    env->DeleteLocalRef(causeMsg);
                }
                env->DeleteLocalRef(causeClass);
                env->DeleteLocalRef(classClass2);
                env->DeleteLocalRef(cause);
            }
            env->DeleteLocalRef(throwableClass);
        }
        if (env->ExceptionCheck()) { env->ExceptionClear(); }

        // 不依赖 stderr 文件，直接将 Java 堆栈按行写入 hilog 便于真机定位
        if (ex) {
            std::string trace = getThrowableStackTrace(env, ex);
            logJavaStackTrace(trace);
        }

        g_status = exInfo;
        AMCL_LOG_E(LOG_TAG, "Exception: %{public}s", exInfo.c_str());
        if (ex) env->DeleteLocalRef(ex);
        env->DeleteLocalRef(jArgs);
        env->DeleteLocalRef(stringClass);
        env->DeleteLocalRef(cls);
        return -1;
    }

    env->DeleteLocalRef(jArgs);
    env->DeleteLocalRef(stringClass);
    env->DeleteLocalRef(cls);

    g_status = jniClassName + ".main() 执行完成";
    AMCL_LOG_I(LOG_TAG, "%{public}s.main() completed successfully", className);
    return 0;
}

extern "C" void jvmDestroy() {
    if (g_jvm) {
        AMCL_LOG_I(LOG_TAG, "Destroying JVM...");
        g_jvm->DestroyJavaVM();
        g_jvm = nullptr;
        g_env = nullptr;
        g_status = "JVM 已销毁";
        AMCL_LOG_I(LOG_TAG, "JVM destroyed");
    }
    if (g_crashTailFd >= 0) {
        close(g_crashTailFd);
        g_crashTailFd = -1;
    }
    g_crashGameOutputPath[0] = '\0';
    g_crashHandlerEntered = 0;
}

extern "C" void* jvmGetJavaVM() {
    return (void*)g_jvm;
}

extern "C" void* jvmGetJNIEnv() {
    return (void*)g_env;
}

extern "C" const char* jvmGetStatus() {
    return g_status.c_str();
}

#ifdef MC_OHOS_BUILD_TESTS
extern "C" int jvmIsTestRunning() {
    return g_testRunning ? 1 : 0;
}

#endif
