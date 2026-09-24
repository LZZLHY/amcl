#include "../platform/native_gl.h"
#include "../platform/graphics_runtime_binding.h"
#include "../platform/graphics_observation_abi.h"
#include "../platform/graphics_fault_injection.h"
#include <ctime>
#include "../platform/desktop_launch_policy.h"
#include "../utils/product_diagnostics.h"
/**
 * mc_launcher.cpp — MC 启动器 (P6)
 *
 * 职责：
 *   1. 检测 .minecraft 游戏文件（mcCheckFiles 诊断）
 *   2. 配置 JVM 参数（内存、library path、MC 系统属性）
 *   3. 按声明的世代交付 classpath，创建本局唯一 JVM
 *   4. 经 AmclLauncher 中间层调起 MC mainClass
 *   （classpath 组装在 ArkTS LaunchProfileBuilder，2026-08-27 起 C 层不再有副本）
 *
 * 依赖：
 *   - jvm_launcher.h (JVM 初始化基础设施)
 *   - P5 LWJGL native 库 (entry/libs/arm64-v8a/)
 *   - 原生图形 provider / WindowHost（由 GraphicsPlan 选择，不预加载 Java 绑定）
 *   - P2 GLFW 兼容层 (libglfw.so)
 */

#include "mc_launcher.h"
#include "jvm_launcher.h"
#include "game_process_exit.h"
#include "runtime_bootstrap_contract.h"
#include <sys/syscall.h>
#include "jni_registry.h"
#include "jni.h"
#include "jni_mutf8.h"   // NewStringUTF 只吃 Modified UTF-8：用户内容一律先转（见头文件）
#include "../platform/vulkan_probe.h"
#include "../platform/vulkan_wsi.h"
#include "../platform/graphics_profile_mirror.generated.h"
#include "../glfw/glfw_compat.h"         // 宿主窗口接口；SDL 准备不再调用 Java GLFW 预热。
// 渲染后端 id → GL 库名 的最小镜像。⚠️ 事实源是 ArkTS 的 RendererBackendRegistry.ets，
// 一致性由 scripts/check-renderer-registry.mjs 交叉校验（治理规范 §3.3 / 施工记录 §S4）。
#include "../platform/renderer_backend_ids.h"
// 渲染分辨率缩放（-Damcl.render.scale）：解析纯函数 + 启动时机补偿钩子（契约见该头）。
#include "../platform/render_scale.h"
#include "../platform/graphics_plan.h"
#include "graphics_launch_failure.h"

#include <hilog/log.h>
#include "../utils/amcl_log.h"
#include "../utils/session_log_io.h"
#include <hidebug/hidebug.h>
#include <hidebug/hidebug_type.h>
#include <dlfcn.h>
#include <dirent.h>
#include <fcntl.h>          // open / O_APPEND（phase_redirectIO 单一写入者）
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <sstream>
#include <vector>
#include <cstdint>
#include <algorithm>
#include <thread>
#include <atomic>
#include <mutex>

#undef LOG_TAG
#define LOG_TAG "MC_LAUNCHER"

// ============================================================
//  设备内存检测
// ============================================================
// 读 /proc/meminfo 的 MemTotal（KB → MB）。
// 注意：HarmonyOS NEXT 三方应用沙箱通常禁止直接 fopen("/proc/meminfo")，
// 大概率返回 NULL → 0。仅作为官方 API 失败时的兜底，不应是主路径。
static int readMemTotalFromProc() {
    FILE* f = fopen("/proc/meminfo", "r");
    if (!f) return 0;
    char line[256];
    long totalKB = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "MemTotal:", 9) == 0) {
            sscanf(line + 9, "%ld", &totalKB);
            break;
        }
    }
    fclose(f);
    return (int)(totalKB / 1024);
}

// 设备总物理内存（MB）。
// 主路径：HiDebug OH_HiDebug_GetSystemMemInfo()（API 12+），内部读 /proc/meminfo
// 的 MemTotal，是沙箱内有权限走通的官方接口。totalMem 单位为 KB。
// 文档约定：结构体数据为空（totalMem==0）表示调用失败 → 回退裸读 → 最终 0。
static int getDeviceTotalMemoryMB() {
    HiDebug_SystemMemInfo info;
    memset(&info, 0, sizeof(info));
    OH_HiDebug_GetSystemMemInfo(&info);
    if (info.totalMem > 0) {
        return (int)(info.totalMem / 1024);  // KB → MB
    }
    AMCL_LOG_W(LOG_TAG, "OH_HiDebug_GetSystemMemInfo returned empty, fallback to /proc/meminfo");
    return readMemTotalFromProc();
}

// 读 /proc/meminfo 的 MemAvailable（KB → MB）。沙箱常禁直读 → 0，仅兜底。
static int readMemAvailableFromProc() {
    FILE* f = fopen("/proc/meminfo", "r");
    if (!f) return 0;
    char line[256];
    long kb = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "MemAvailable:", 13) == 0) {
            sscanf(line + 13, "%ld", &kb);
            break;
        }
    }
    fclose(f);
    return (int)(kb / 1024);
}

// 设备【当前可用】物理内存（MB）。主路径 HiDebug availableMem（KB），兜底裸读
// /proc MemAvailable。0 表示取不到（调用方据此跳过"可用内存封顶"）。
static int getDeviceAvailableMemoryMB() {
    HiDebug_SystemMemInfo info;
    memset(&info, 0, sizeof(info));
    OH_HiDebug_GetSystemMemInfo(&info);
    if (info.availableMem > 0) {
        return (int)(info.availableMem / 1024);  // KB → MB
    }
    return readMemAvailableFromProc();
}

// 设备「想要」的堆大小：只看总内存，不受当前可用内存约束（对齐 256MB）。
// 用于：① 普通模式下作为基准，再被可用内存二次封顶；② 虚拟内存（堆文件）模式下
// 直接采用——因为堆落在存储文件上、可被系统回收，不再受物理可用内存制约。
static int computeDesiredXmxNoAvailCap(int totalMB) {
    if (totalMB <= 0) return 1024;
    int xmx = totalMB / 2;
    if (xmx < 1024) xmx = 1024;
    // 上限：设备总内存的 80%（对齐 256MB），给大内存设备放开、给系统留余量。
    int hardCap = (int)((long long)totalMB * 80 / 100);
    hardCap = (hardCap / 256) * 256;
    if (hardCap < 512) hardCap = 512;
    if (xmx > hardCap) xmx = hardCap;
    xmx = (xmx / 256) * 256;
    if (xmx < 1024) xmx = 1024;
    return xmx;
}

static int computeRecommendedXmx() {
    int totalMB = getDeviceTotalMemoryMB();
    if (totalMB <= 0) return 1024; // fallback
    // 返回「设备想要」的堆作为 -Xmx 硬上限（防 Java OOM）。
    // 真实 RAM 占用不再靠收紧 -Xmx 来控制（1000248 的可用内存硬封顶会让 SerialGC
    // 把堆顶满后被系统 SIGKILL），而是改由「G1 增量回收 + SoftMaxHeapSize 软目标 +
    // 归还内存」承担（见 launchWithProfileImpl 的 GC 路由）。这样上限可放宽、避免
    // worldgen 时 Java 堆 OOM，同时真实占用紧贴存活数据。
    int xmx = computeDesiredXmxNoAvailCap(totalMB);
    AMCL_LOG_I(LOG_TAG, "Device RAM total=%{public}d MB -> recommended Xmx(hard cap)=%{public}d MB", totalMB, xmx);
    return xmx;
}

// 内存感知的 -Xmx 硬上限（MB）。两头都要防：
//   · 太大（如滑块拉到 8192）→ 堆撑进大量 swap → GC 扫堆读回换出页 → 渲染线程停顿
//     → OHOS AppFreeze 杀进程（1000250 冻结的根因）。
//   · 太小（如瞬时可用内存偏低算出 2560）→ 连材质图集都拼不下 → 启动期 Java 堆 OOM
//     （1000251 崩在资源加载的根因）。
// 故：在【设备总内存 33%（下限，保证够加载）~ 55%（上限，防撑爆 swap）】区间内，
// 取「当前可用内存 − native 预留」。下限用总内存而非瞬时可用（后者抖动会把堆压到无法
// 加载），真正的 RAM 占用峰值改由 SoftMax 节流 + 系统 swap 兜底。取不到内存返回 0（不封顶）。
static int computeXmxHardCeilMB() {
    int totalMB = getDeviceTotalMemoryMB();
    int availMB = getDeviceAvailableMemoryMB();
    if (totalMB <= 0) return 0;
    int nativeReserve = totalMB * 18 / 100;
    if (nativeReserve < 2048) nativeReserve = 2048;
    int ceil = (availMB > 0) ? (availMB - nativeReserve) : (totalMB / 2);
    int floorMB = (totalMB * 33 / 100 / 256) * 256;  // 12G→~3840：低于此连图集都拼不下
    if (floorMB < 1536) floorMB = 1536;
    int upperMB = (totalMB * 55 / 100 / 256) * 256;  // 12G→~6400：高于此撑进 swap
    if (upperMB < floorMB) upperMB = floorMB;
    if (ceil < floorMB) ceil = floorMB;
    if (ceil > upperMB) ceil = upperMB;
    ceil = (ceil / 256) * 256;
    if (ceil < 1536) ceil = 1536;
    return ceil;
}

// ============================================================
//  虚拟内存（堆文件 / JEP 316 -XX:AllocateHeapAt）支持
// ============================================================
// 删除堆文件目录里的残留文件（上次被 SIGKILL 时 JVM 来不及删的 .map 文件），
// 然后确保目录存在。返回目录路径。
static std::string prepareHeapFileDir(const std::string& filesDir) {
    std::string dir = filesDir + "/jvm-heap";
    DIR* d = opendir(dir.c_str());
    if (d) {
        struct dirent* ent;
        while ((ent = readdir(d)) != nullptr) {
            std::string name(ent->d_name);
            if (name == "." || name == "..") continue;
            std::string p = dir + "/" + name;
            remove(p.c_str());
        }
        closedir(d);
    } else {
        mkdir(dir.c_str(), 0700);
    }
    return dir;
}

// 检查目录所在分区可用磁盘空间（MB）。取不到返回 -1。
static long getFreeDiskMB(const std::string& path) {
    struct statvfs st;
    if (statvfs(path.c_str(), &st) != 0) return -1;
    unsigned long long freeBytes = (unsigned long long)st.f_bavail * (unsigned long long)st.f_frsize;
    return (long)(freeBytes / (1024ULL * 1024ULL));
}

// ============================================================
//  全局状态
// ============================================================
// 2026-08-27（加载链审查修复批次）：g_mcStatus 由启动线程写、NAPI（JS 主线程）轮询读。
// 裸 std::string 的并发读写是 UB —— 中文状态文案走堆分配，赋值瞬间旧缓冲被释放，
// 读端 c_str() 可能拿到悬垂指针。写端保持 `g_mcStatus = ...` 语法不变（operator=
// 内部加锁），读端一律经 snapshot() 拷贝。
namespace {
class GuardedStatus {
public:
    GuardedStatus& operator=(const char* text) {
        std::lock_guard<std::mutex> lock(mutex_);
        value_ = (text != nullptr) ? text : "";
        return *this;
    }
    GuardedStatus& operator=(const std::string& text) {
        std::lock_guard<std::mutex> lock(mutex_);
        value_ = text;
        return *this;
    }
    std::string snapshot() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return value_;
    }
private:
    mutable std::mutex mutex_;
    std::string value_;
};
} // namespace
static GuardedStatus g_mcStatus;

// 图形准入发生在同步 NAPI 调用线程。线程局部快照避免后台游戏状态覆盖本次失败，
// PID 核验阻止 fork 子进程读取父进程的旧失败；它不参与窗口/驱动资源的所有权。
static thread_local amcl::graphics::LaunchFailure g_graphicsLaunchFailure;
static thread_local pid_t g_graphicsLaunchFailurePid = 0;

extern "C" void mcClearGraphicsLaunchFailure() {
    g_graphicsLaunchFailure = {};
    g_graphicsLaunchFailurePid = getpid();
}

extern "C" const char* mcGetGraphicsLaunchFailure() {
    static thread_local std::string serialized;
    serialized = g_graphicsLaunchFailurePid == getpid()
        ? amcl::graphics::SerializeLaunchFailure(g_graphicsLaunchFailure) : "{}";
    return serialized.c_str();
}

/**
 * 在实际失败分支记录稳定阶段/代码。计划激活后即使 JVM 尚未创建也要求新进程，
 * 因为 EGL/provider 与计划锁存不能由销毁某个 session 或修改环境变量证明已复位。
 */
static void recordGraphicsLaunchFailure(int rc, const char* stage, const std::string& code,
                                        const std::string& profile = "", bool forceRestart = false) {
    g_graphicsLaunchFailurePid = getpid();
    const auto* active = amcl::graphics::ActiveGraphicsPlan();
    g_graphicsLaunchFailure = amcl::graphics::BuildLaunchFailure(rc, stage, code, profile,
        active ? active->profile : "", active != nullptr,
        jvmRuntimeState() != amcl::jvm::RuntimeOnce::Fresh, forceRestart);
}
static std::atomic<bool> g_mcRunning{false};
/* SDL can discover an unrecoverable renderer/context failure after the Java
 * launcher has already entered Minecraft.  That process must not be reused:
 * RenderSystem/SDL state is not guaranteed to unwind in a way that supports a
 * second in-process launch. */
static std::atomic<bool> g_rendererProcessTainted{false};
static std::thread g_mcThread;
static std::string g_markerPath = "/data/storage/el2/base/haps/entry/files/.mc_window_destroyed";

static bool rendererRestartMarkerPresent() {
    const char* marker = getenv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART");
    return marker && strcmp(marker, "1") == 0;
}

static void markRendererProcessTainted(const char* reason) {
    g_rendererProcessTainted.store(true, std::memory_order_release);
    g_mcStatus = "渲染器状态不可复用，需要重启进程";
    AMCL_LOG_E(LOG_TAG,
               "renderer process tainted; process restart required reason=%{public}s",
               reason ? reason : "unspecified");
}

static void initMarkerPath(const std::string& filesDir) {
    g_markerPath = filesDir + "/.mc_window_destroyed";
    setenv("AMCL_FILES_DIR", filesDir.c_str(), 1);
}

// 构建 LaunchConfig JSON 传给 AmclLauncher.main()
static std::string jsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 16);
    for (char c : s) {
        if (c == '"') out += "\\\"";
        else if (c == '\\') out += "\\\\";
        else if (c == '\n') out += "\\n";
        else if (c == '\t') out += "\\t";
        else out += c;
    }
    return out;
}

static std::string buildLaunchConfigJson(
    const std::string& mainClass, const std::string& classpath,
    const std::vector<std::string>& mcArgs,
    const std::string& gameDir, const std::string& mcDir,
    const std::string& filesDir,
    bool isForge, bool isFabric)
{
    // classpath 是冒号分隔的字符串，拆成 JSON 数组
    std::vector<std::string> cpEntries;
    std::istringstream cpStream(classpath);
    std::string entry;
    while (std::getline(cpStream, entry, ':')) {
        if (!entry.empty()) cpEntries.push_back(entry);
    }

    // mcDir 回退策略：若 ArkTS 未注入（空），退化为 gameDir 以保持向后兼容
    std::string actualMcDir = mcDir.empty() ? gameDir : mcDir;

    std::ostringstream js;
    js << "{";
    js << "\"mainClass\":\"" << jsonEscape(mainClass) << "\",";
    js << "\"classpath\":[";
    for (size_t i = 0; i < cpEntries.size(); i++) {
        if (i > 0) js << ",";
        js << "\"" << jsonEscape(cpEntries[i]) << "\"";
    }
    js << "],\"mcArgs\":[";
    for (size_t i = 0; i < mcArgs.size(); i++) {
        if (i > 0) js << ",";
        js << "\"" << jsonEscape(mcArgs[i]) << "\"";
    }
    js << "],";
    js << "\"gameDir\":\"" << jsonEscape(gameDir) << "\",";
    js << "\"mcDir\":\"" << jsonEscape(actualMcDir) << "\",";
    js << "\"filesDir\":\"" << jsonEscape(filesDir) << "\",";
    js << "\"isForge\":" << (isForge ? "true" : "false") << ",";
    js << "\"isFabric\":" << (isFabric ? "true" : "false");
    js << "}";
    return js.str();
}

// ============================================================
//  JNI 辅助：设置 Java 系统属性
// ============================================================
static void setSystemProperty(JNIEnv* env, const char* key, const char* value) {
    jclass systemClass = env->FindClass("java/lang/System");
    if (!systemClass) { env->ExceptionClear(); return; }
    jmethodID setProp = env->GetStaticMethodID(systemClass, "setProperty",
        "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    if (!setProp) { env->ExceptionClear(); env->DeleteLocalRef(systemClass); return; }
    jstring jKey = env->NewStringUTF(key);
    // value 可能含用户内容（gameDir / 版本目录名可带 emoji 等增补字符）→ 必须转 MUTF-8
    jstring jVal = env->NewStringUTF(amcl::toModifiedUtf8(value).c_str());
    jobject old = env->CallStaticObjectMethod(systemClass, setProp, jKey, jVal);
    if (old) env->DeleteLocalRef(old);
    env->DeleteLocalRef(jKey);
    env->DeleteLocalRef(jVal);
    env->DeleteLocalRef(systemClass);
    if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }
    AMCL_LOG_I(LOG_TAG, "  setProperty: %{public}s = %{public}s", key, value);
}

// gl4es（老 MC ≤1.16.5 固定管线后端）的接入说明见 phase_setProperties 中的 gl4es 分支与
//   prebuilt/gl4es/README.md / CHANGELOG 1000145：libgl4es 由 LWJGL 经 org.lwjgl.opengl.libname
//   加载，并在首个 GL 调用时经 OHOS 补丁 gl4es_ensure_init() 懒初始化（渲染线程、context current、
//   非 dlopen 内）。gl4es 的 GLES 函数来源由 LIBGL_GLES=libGLESv3.so（实库）经 dlsym 解析——
//   不再需要 libentry 侧的 dlopen 预加载、set_getprocaddress 解析器注入或跨 .so 延迟 init 指针传递。

// 读取 Java 系统属性（用于读 -D 注入的决策位，如 amcl.gl.backend）。失败/未设返回空串。
static std::string getSystemProperty(JNIEnv* env, const char* key) {
    std::string result;
    jclass systemClass = env->FindClass("java/lang/System");
    if (!systemClass) { env->ExceptionClear(); return result; }
    jmethodID getProp = env->GetStaticMethodID(systemClass, "getProperty",
        "(Ljava/lang/String;)Ljava/lang/String;");
    if (!getProp) { env->ExceptionClear(); env->DeleteLocalRef(systemClass); return result; }
    jstring jKey = env->NewStringUTF(key);
    jstring jVal = (jstring)env->CallStaticObjectMethod(systemClass, getProp, jKey);
    if (jVal) {
        const char* s = env->GetStringUTFChars(jVal, nullptr);
        if (s) { result = s; env->ReleaseStringUTFChars(jVal, s); }
        env->DeleteLocalRef(jVal);
    }
    env->DeleteLocalRef(jKey);
    env->DeleteLocalRef(systemClass);
    if (env->ExceptionCheck()) { env->ExceptionClear(); }
    return result;
}

// ============================================================
//  工具函数
// ============================================================

static bool fileExists(const char* path) {
    struct stat st;
    return stat(path, &st) == 0;
}

static long fileSize(const char* path) {
    struct stat st;
    if (stat(path, &st) == 0) return (long)st.st_size;
    return -1;
}

static bool dirExists(const char* path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static std::string resolveHapNativeDir(const std::string& filesDir) {
    std::vector<std::string> candidates;
    candidates.push_back("/data/storage/el1/bundle/libs/arm64");
    candidates.push_back("/data/storage/el1/bundle/libs/arm64-v8a");
    candidates.push_back("/data/storage/el1/bundle/libs");

    size_t filesPos = filesDir.rfind("/files");
    if (filesPos != std::string::npos) {
        std::string baseDir = filesDir.substr(0, filesPos);
        candidates.push_back(baseDir + "/libs/arm64");
        candidates.push_back(baseDir + "/libs/arm64-v8a");
        candidates.push_back(baseDir + "/libs");
        candidates.push_back(baseDir + "/lib");
        candidates.push_back(baseDir + "/lib64");
    }

    for (const auto& path : candidates) {
        if (dirExists(path.c_str())) {
            AMCL_LOG_I(LOG_TAG, "Resolved hapNativeDir=%s", path.c_str());
            return path;
        }
    }

    std::string fallback = "/data/storage/el1/bundle/libs/arm64";
    AMCL_LOG_W(LOG_TAG, "Failed to resolve hapNativeDir, fallback=%s", fallback.c_str());
    return fallback;
}

// ============================================================
//  Stub JAR：原 createStubJar() 手写 Java class 字节码 + ZIP 局部头的实现
//  已于 2026-05-08 删除（共 ~353 行死代码）。详见
//  docs/guides/napi-layer-refactor-plan.md §五 Step 9。
//
//  实际的 stub-objc-bridge.jar 由 ArkTS RuntimeDeployer.deployStubObjcBridge()
//  从 entry/src/main/resources/rawfile/stub-objc-bridge.jar 抽取到 .minecraft/，
//  是否挂进 classpath 由 ArkTS LaunchProfileBuilder.buildClasspath() 决定
//  （LWJGL2 老 Forge 路径刻意排除，理由见该方法注释）。
// ============================================================

// 递归收集目录下所有 .jar 文件
static void collectJars(const std::string& dir, std::vector<std::string>& jars) {
    DIR* d = opendir(dir.c_str());
    if (!d) return;

    struct dirent* entry;
    while ((entry = readdir(d)) != nullptr) {
        if (entry->d_name[0] == '.') continue;

        std::string path = dir + "/" + entry->d_name;
        struct stat st;
        if (stat(path.c_str(), &st) != 0) continue;

        if (S_ISDIR(st.st_mode)) {
            collectJars(path, jars);
        } else if (S_ISREG(st.st_mode)) {
            size_t len = strlen(entry->d_name);
            if (len > 4 && strcmp(entry->d_name + len - 4, ".jar") == 0) {
                jars.push_back(path);
            }
        }
    }
    closedir(d);
}

// ⚰️ 2026-08-27（加载链审查修复批次）：这里曾有 isLwjglJar() 与 C 层 buildClasspath()
//   —— legacy mcLaunch 专用（递归扫 libraries 拼 classpath，把游戏 jar 全量放进
//   java.class.path）。随 mcLaunch 一并删除；classpath 组装的唯一实现是
//   ArkTS LaunchProfileBuilder.buildClasspath()。collectJars() 保留（mcCheckFiles 在用）。

// ============================================================
//  文件检测
// ============================================================

// 递归统计目录下文件数量
static int countFiles(const std::string& dir) {
    int count = 0;
    DIR* d = opendir(dir.c_str());
    if (!d) return 0;
    struct dirent* entry;
    while ((entry = readdir(d)) != nullptr) {
        if (entry->d_name[0] == '.') continue;
        std::string path = dir + "/" + entry->d_name;
        struct stat st;
        if (stat(path.c_str(), &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                count += countFiles(path);
            } else {
                count++;
            }
        }
    }
    closedir(d);
    return count;
}

// 递归统计目录下空文件数量
static int countEmptyFiles(const std::string& dir) {
    int count = 0;
    DIR* d = opendir(dir.c_str());
    if (!d) return 0;
    struct dirent* entry;
    while ((entry = readdir(d)) != nullptr) {
        if (entry->d_name[0] == '.') continue;
        std::string path = dir + "/" + entry->d_name;
        struct stat st;
        if (stat(path.c_str(), &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                count += countEmptyFiles(path);
            } else if (st.st_size == 0) {
                count++;
            }
        }
    }
    closedir(d);
    return count;
}

extern "C" const char* mcCheckFiles(const char* mcDir, const char* mcVersion) {
    static std::string result;
    std::ostringstream ss;

    if (!mcDir || !mcVersion) {
        result = "{\"ok\":false,\"error\":\"参数为空\"}";
        return result.c_str();
    }

    std::string dir(mcDir);
    std::string ver(mcVersion);
    int issues = 0;

    ss << "===== MC 游戏完整性检测 =====\n";
    ss << "目录: " << dir << "\n";
    ss << "版本: " << ver << "\n\n";

    // 1. .minecraft 根目录
    ss << "【基础目录】\n";
    bool dirOk = dirExists(dir.c_str());
    ss << (dirOk ? "  ✅" : "  ❌") << " .minecraft 目录\n";
    if (!dirOk) { issues++; result = ss.str(); return result.c_str(); }

    // 2. version JSON
    std::string verJson = dir + "/versions/" + ver + "/" + ver + ".json";
    long vjSize = fileSize(verJson.c_str());
    if (vjSize > 0) {
        ss << "  ✅ " << ver << ".json (" << (vjSize / 1024) << " KB)\n";
    } else {
        ss << "  ❌ " << ver << ".json (不存在)\n"; issues++;
    }

    // 3. client.jar
    std::string mcJar = dir + "/versions/" + ver + "/" + ver + ".jar";
    long jarSz = fileSize(mcJar.c_str());
    if (jarSz > 1024 * 1024) {
        ss << "  ✅ " << ver << ".jar (" << (jarSz / 1024 / 1024) << " MB)\n";
    } else if (jarSz >= 0) {
        ss << "  ❌ " << ver << ".jar (" << jarSz << " 字节 — 不完整！)\n"; issues++;
    } else {
        ss << "  ❌ " << ver << ".jar (不存在)\n"; issues++;
    }

    // 4. libraries
    ss << "\n【Libraries】\n";
    std::string libDir = dir + "/libraries";
    if (dirExists(libDir.c_str())) {
        std::vector<std::string> jars;
        collectJars(libDir, jars);
        int emptyJars = 0;
        long totalLibSize = 0;
        for (const auto& jar : jars) {
            long sz = fileSize(jar.c_str());
            if (sz <= 0) emptyJars++;
            else totalLibSize += sz;
        }
        ss << "  ✅ libraries 目录: " << jars.size() << " 个 jar (" << (totalLibSize / 1024 / 1024) << " MB)\n";
        if (emptyJars > 0) {
            ss << "  ⚠️ " << emptyJars << " 个空文件（需重新下载）\n";
            issues++;
        }
    } else {
        ss << "  ❌ libraries 目录不存在\n"; issues++;
    }

    // 5. LWJGL OHOS jars
    std::string lwjglDir = dir + "/lwjgl-ohos";
    if (dirExists(lwjglDir.c_str())) {
        std::vector<std::string> lwjglJars;
        collectJars(lwjglDir, lwjglJars);
        ss << "  ✅ lwjgl-ohos: " << lwjglJars.size() << " 个 jar\n";
    } else {
        ss << "  ℹ️ lwjgl-ohos 目录不存在（首次启动时自动解包）\n";
    }

    // 6. assets
    ss << "\n【Assets 资源】\n";
    std::string assetsDir = dir + "/assets";
    if (dirExists(assetsDir.c_str())) {
        // asset index
        std::string indexDir = assetsDir + "/indexes";
        if (dirExists(indexDir.c_str())) {
            int indexCount = countFiles(indexDir);
            ss << "  ✅ indexes: " << indexCount << " 个索引文件\n";
        } else {
            ss << "  ❌ indexes 目录不存在\n"; issues++;
        }

        // asset objects
        std::string objDir = assetsDir + "/objects";
        if (dirExists(objDir.c_str())) {
            int objCount = countFiles(objDir);
            int emptyObj = countEmptyFiles(objDir);
            ss << "  " << (objCount > 1000 ? "✅" : "⚠️") << " objects: " << objCount << " 个资源文件";
            if (objCount < 1000) {
                ss << " (偏少，MC 1.20.4 约需 3800+)";
                issues++;
            }
            ss << "\n";
            if (emptyObj > 0) {
                ss << "  ⚠️ " << emptyObj << " 个空文件（需重新下载）\n";
                issues++;
            }
        } else {
            ss << "  ❌ objects 目录不存在（需下载 assets）\n"; issues++;
        }
    } else {
        ss << "  ❌ assets 目录不存在\n"; issues++;
    }

    // 7. 其他
    ss << "\n【其他】\n";
    std::string logCfg = dir + "/options.txt";
    ss << (fileExists(logCfg.c_str()) ? "  ✅" : "  ℹ️") << " options.txt"
       << (fileExists(logCfg.c_str()) ? "" : "（首次启动自动生成）") << "\n";

    // 总结
    ss << "\n===== 检测结果 =====\n";
    if (issues == 0) {
        ss << "🎉 所有文件就绪，可以启动！\n";
    } else {
        ss << "⚠️ 发现 " << issues << " 个问题，请先下载缺失文件\n";
    }

    result = ss.str();
    return result.c_str();
}

// ============================================================
//  MC 启动 — 阶段化架构
//
//  Phase 0: VALIDATE        启动前校验（在 ArkTS：PreLaunchValidator +
//                           LaunchProfileBuilder.build()，C 层不再重复）
//  Phase 1: INIT_JVM        初始化 JVM + sigchain（phase_initJvmWithClasspath）
//  Phase 1.5: PREPARE_JAVA  AmclLauncher.prepare 挂载游戏 classpath
//  进入上游加载器前：重定向日志、发布原生 host 描述符、准备 classpath、核对已冻结属性。
//  不再预加载 org.lwjgl.*；JNI 与 SDL 准备属于实际消费者及其 native 实例。
//  Phase 5: LAUNCH_MAIN     调用 AmclLauncher.main()
// ============================================================

// 强制 options.txt fullscreen:false（移动设备始终全屏渲染，MC 的全屏切换会破坏触摸坐标）
static void forceOptionsFullscreenOff(const std::string& gameDir) {
    std::string optPath = gameDir + "/options.txt";
    FILE* f = fopen(optPath.c_str(), "r");
    if (!f) return; // 首次启动，options.txt 还不存在

    // 读取全部内容
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::string content(sz, '\0');
    fread(&content[0], 1, sz, f);
    fclose(f);

    // 查找并替换 fullscreen:true → fullscreen:false
    const char* needle = "fullscreen:true";
    const char* replacement = "fullscreen:false";
    size_t pos = content.find(needle);
    if (pos == std::string::npos) return; // 已经是 false，无需修改

    // 只替换第一个匹配（key_key.fullscreen 不受影响，因为那个是 key_key.fullscreen:key.keyboard.f11）
    content.replace(pos, strlen(needle), replacement);

    f = fopen(optPath.c_str(), "w");
    if (f) {
        fwrite(content.c_str(), 1, content.size(), f);
        fclose(f);
        AMCL_LOG_I(LOG_TAG, "Forced options.txt fullscreen:false (mobile always fullscreen)");
    }
}

// ============================================================
//  游戏语言（options.txt 的 lang 键）——启动器权威写入
// ============================================================
// 支持的游戏语言白名单。**必须与 ArkTS commons/GameLanguages.ets 的 GAME_LANGUAGES
// code 集合保持一致**（改一处改两处）。未知/空 → 不处理，保持 MC 默认行为。
static bool isSupportedGameLang(const std::string& lang) {
    static const char* kLangs[] = {
        "zh_cn", "zh_tw", "zh_hk", "en_us", "en_gb", "ja_jp", "ko_kr",
        "ru_ru", "de_de", "fr_fr", "es_es", "pt_br", "it_it", "vi_vn",
    };
    for (const char* l : kLangs) {
        if (lang == l) return true;
    }
    return false;
}

// 把游戏语言写进 options.txt 的 lang 键（启动器权威：每次启动按用户在启动器里选择的
// 语言校正，使"设置页 / 版本选项"的语言选择真正生效）。对齐 PCL2 的 options.txt lang
// 写入，但 AMCL 把 lang 作为启动器控制的权威值（每次启动写入）。
//
// options.txt 为 "key:value" 逐行文本。
//   · 文件不存在（首启）→ 创建仅含一行 lang 的最小文件，MC 首次即用选定语言、其余项补齐。
//   · 已存在 → 替换已有 lang 行；没有 lang 行则追加。内容无变化时不写盘。
//
// 说明：lang code 采用现代 MC（1.11+）小写格式（AMCL 适配 1.13+）。若未来接入 ≤1.10，
// 需按版本纪元把末两位改大写（zh_CN），届时在此按 gameDir 内 version 判定处理。
static void applyGameLanguage(const std::string& gameDir, const std::string& lang) {
    if (lang.empty()) return;  // 未指定（理论上不会，全局默认 zh_cn）→ 保持 MC 默认
    if (!isSupportedGameLang(lang)) {
        AMCL_LOG_W(LOG_TAG, "applyGameLanguage: unsupported lang '%{public}s', skip", lang.c_str());
        return;
    }
    std::string optPath = gameDir + "/options.txt";
    FILE* f = fopen(optPath.c_str(), "r");
    if (!f) {
        // 首启：options.txt 还不存在，写一个只含 lang 的最小文件（MC 会补齐其余项）。
        FILE* w = fopen(optPath.c_str(), "w");
        if (w) {
            fprintf(w, "lang:%s\n", lang.c_str());
            fclose(w);
            AMCL_LOG_I(LOG_TAG, "applyGameLanguage: created options.txt with lang:%{public}s", lang.c_str());
        } else {
            AMCL_LOG_W(LOG_TAG, "applyGameLanguage: cannot create options.txt");
        }
        return;
    }

    // 读取全部内容
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::string content(sz > 0 ? (size_t)sz : 0, '\0');
    if (sz > 0) fread(&content[0], 1, (size_t)sz, f);
    fclose(f);

    // 逐行处理：替换已有 "lang:" 行，否则末尾追加。保留其它行原样。
    std::istringstream in(content);
    std::ostringstream out;
    std::string line;
    bool replaced = false;
    bool first = true;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();  // 容忍 CRLF
        if (!first) out << "\n";
        if (line.compare(0, 5, "lang:") == 0) {
            out << "lang:" << lang;
            replaced = true;
        } else {
            out << line;
        }
        first = false;
    }
    if (!replaced) {
        if (!first) out << "\n";
        out << "lang:" << lang;
    }
    out << "\n";

    std::string newContent = out.str();
    if (newContent == content) {
        AMCL_LOG_I(LOG_TAG, "applyGameLanguage: lang already %{public}s, no change", lang.c_str());
        return;
    }
    FILE* w = fopen(optPath.c_str(), "w");
    if (w) {
        fwrite(newContent.c_str(), 1, newContent.size(), w);
        fclose(w);
        AMCL_LOG_I(LOG_TAG, "applyGameLanguage: set lang:%{public}s", lang.c_str());
    } else {
        AMCL_LOG_W(LOG_TAG, "applyGameLanguage: failed to rewrite options.txt");
    }
}

// 设备不支持 MC 官方 Vulkan 后端时，拒绝本次启动并保留 options.txt 的
// preferredGraphicsBackend:"vulkan"（不静默改写用户偏好）。
//
// 背景：MC 26.2 起 options.txt 记 preferredGraphicsBackend。若用户在游戏内选了 Vulkan，
// 但设备 GPU 缺 MC 硬性扩展（如 Maleoon 920 缺 VK_KHR_push_descriptor），则：
//   - 即便 glfwVulkanSupported() 已门控返回 FALSE，MC 仍按 options 的 "vulkan" 偏好走 Vulkan
//     窗口创建流程，拿不到 Vulkan → 抛 BackendCreationException → 窗口销毁 → 进程退出（崩溃表现）。
//   - 且该偏好已持久化，用户每次启动都崩、无法自救（设置入口在游戏内，进不去游戏改不了）。
// 启动前（MC 读 options.txt 之前）由 native 探针判定；不支持时给出可恢复错误，
// 由用户选择受支持后端或修正设置。支持 Vulkan 的设备（探针 available=true）保持原偏好。
static bool rejectUnsupportedVulkanPreference(const std::string& gameDir) {
    std::string optPath = gameDir + "/options.txt";
    FILE* f = fopen(optPath.c_str(), "r");
    if (!f) return true; // 首次启动，options.txt 还不存在（MC 会用默认 default）

    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) { fclose(f); return true; }
    std::string content(sz, '\0');
    fread(&content[0], 1, sz, f);
    fclose(f);

    // 只在确实选了 vulkan 时才介入（避免无谓探测开销）。
    const char* needle = "preferredGraphicsBackend:\"vulkan\"";
    size_t pos = content.find(needle);
    if (pos == std::string::npos) return true; // 不是 vulkan 偏好，无需处理

    // Never rewrite the user's preference. Reject this launch with an explicit,
    // recoverable diagnostic; the next launch may use another profile or an
    // externally corrected options file.
    AMCL_LOG_E(LOG_TAG, "graphics_plan_rejected reason=vulkan_preference_conflicts_with_active_opengl_plan options_preference_preserved=1");
    return false;
}

// 强制禁用 Forge EarlyDisplay（写 earlyWindowControl = false）。
//
// 为什么必须禁（2026-05-31 回归 3.3.3 时代的稳定方案）：
//   Forge EarlyDisplay 的 DisplayWindow.setupMinecraftWindow 在窗口交接时执行
//     glfwSetWindowPosCallback(window, null).free();
//   它依赖 GLFW 标准契约"set callback 返回上一个 callback"，拿返回值 .free()。
//   我们的 GLFW（无论 Plan A 手写、还是 Plan B 上游 + libglfw.so native）首次/未存
//   旧指针时返回 null → Forge 无条件 .free() → NullPointerException → 崩。
//   PojavLauncher 系移动端 launcher 通行做法：直接禁用 EarlyDisplay（它只是个加载
//   进度小窗，禁掉对游戏功能零影响），绕开这个崩点。
//
// 历史：本函数曾反向（删除 earlyWindowControl=false 以"恢复"EarlyDisplay），理由是
//   "EGL 重试逻辑已能处理时序"。但 EarlyDisplay 真正的崩点是上面的 callback .free()
//   NPE，不是 EGL 时序——所以"恢复"会让 Forge 崩。现已反转回"强制禁用"。
//   详见 docs 里 LWJGL / Forge 启动分析。
//
// 与 ArkTS LaunchProfileBuilder.disableForgeEarlyDisplay + Java ForgeHelper.disableEarlyDisplay
// 构成三重冗余：本函数是 C 层最后一道，确保即使前两者漏写也兜底。
static void forceDisableForgeEarlyWindow(const std::string& gameDir) {
    std::string fmlToml = gameDir + "/config/fml.toml";

    std::string content;
    FILE* f = fopen(fmlToml.c_str(), "r");
    if (f) {
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        if (sz > 0) {
            content.resize(sz);
            fread(&content[0], 1, sz, f);
        }
        fclose(f);
    }
    // 无 fml.toml：Forge 默认 earlyWindowControl=true（EarlyDisplay 开），必须创建并禁用。

    // ⚠️ 2026-06-06 修复：Forge 1.17+ 的 fml.toml 是【扁平】的（earlyWindowControl 是
    //   顶层 key，无 [fmlClient] 段）。历史代码把 key 写进 [fmlClient] 段 → Forge 顶层
    //   找不到 → 用默认 true → 加载 EarlyDisplay → OHOS 上卡在 Forge 加载界面。
    //
    // ⚠️ 2026-06-15 修复（整合包 ATM9 启动崩溃根治）：整合包 overrides 自带的 fml.toml
    //   已含 earlyWindow* 键（如 ATM9 的 `earlyWindowSquir = false`）。上层 ArkTS/Java 的
    //   upsert 在某些边界（行尾无换行/多次写入/replaceFirst 只改第一处）会**追加重复键** →
    //   FML 的 nightconfig TOML 解析器对重复键直接抛 `entry defined twice` → 启动即崩。
    //   现把本函数升级为**全量净化**：去掉 [fmlClient] 段头 + **删除全部 4 个 earlyWindow*
    //   键的所有出现（去重）**，再在末尾各写回一次（=false）。本函数在 Java ForgeHelper
    //   之前执行，且产出每个键恰好一次 → Java 的 upsert 只会原地替换、不会再追加重复。
    static const char* EARLY_KEYS[] = {
        "earlyWindowControl",
        "earlyWindowShowCPU",
        "earlyWindowSquir",
        "earlyWindowLogHelpMessage",
    };
    const size_t EARLY_KEYS_N = sizeof(EARLY_KEYS) / sizeof(EARLY_KEYS[0]);

    // 判定一行是否是某个 earlyWindow* 键的赋值行（trimmed 以 "key" 开头且后随 空白/'='）。
    auto isEarlyKeyLine = [&](const std::string& trimmed) -> bool {
        for (size_t k = 0; k < EARLY_KEYS_N; k++) {
            std::string key = EARLY_KEYS[k];
            if (trimmed.rfind(key, 0) == 0) {
                // key 之后必须是 空白 或 '='（避免 earlyWindowControlX 之类前缀误伤）
                char after = (trimmed.size() > key.size()) ? trimmed[key.size()] : '\0';
                if (after == '\0' || after == ' ' || after == '\t' || after == '=') {
                    return true;
                }
            }
        }
        return false;
    };

    std::string rebuilt;
    size_t i = 0;
    while (i < content.size()) {
        size_t nl = content.find('\n', i);
        bool hasNl = (nl != std::string::npos);
        std::string line = content.substr(i, (hasNl ? nl : content.size()) - i);
        i = hasNl ? nl + 1 : content.size();

        // trim 前导空白用于判定
        size_t s = line.find_first_not_of(" \t\r");
        std::string trimmed = (s == std::string::npos) ? "" : line.substr(s);

        if (trimmed.rfind("[fmlClient]", 0) == 0) {
            // 丢弃我们历史误加的段头（不输出）
            continue;
        }
        if (isEarlyKeyLine(trimmed)) {
            // 删除所有 earlyWindow* 键的出现（含整合包自带的与历史重复），稍后统一写回一次
            continue;
        }
        rebuilt += line;
        rebuilt += "\n";
    }
    // 在末尾把 4 个键各写回一次（顶层、=false）
    if (!rebuilt.empty() && rebuilt[rebuilt.size() - 1] != '\n') rebuilt += "\n";
    for (size_t k = 0; k < EARLY_KEYS_N; k++) {
        rebuilt += EARLY_KEYS[k];
        rebuilt += " = false\n";
    }

    if (rebuilt == content) {
        return; // 无变化，省一次写盘
    }

    f = fopen(fmlToml.c_str(), "w");
    if (f) {
        fwrite(rebuilt.c_str(), 1, rebuilt.size(), f);
        fclose(f);
        AMCL_LOG_I(LOG_TAG, "Forced fml.toml: sanitized all earlyWindow* keys (dedup + =false; flat schema, strip [fmlClient])");
    } else {
        AMCL_LOG_W(LOG_TAG, "Failed to write fml.toml to disable EarlyDisplay: %{public}s", fmlToml.c_str());
    }
}

// ⚰️ 2026-08-27（加载链审查修复批次）：这里曾有 legacy 的 phase_validate()
//   （Phase 0，mcLaunch 专用）。profile 启动路径的启动前校验在 ArkTS
//   PreLaunchValidator + LaunchProfileBuilder.build()（缺失/ZIP 头/Forge 产物），
//   随 mcLaunch 退役删除。

// ⚰️ 2026-08-27（加载链审查修复批次）：这里曾有 legacy 的 phase_initJvm()
//   （C 层拼 classpath 后整包塞进 java.class.path），随 mcLaunch 退役删除。
//   现存的 Phase 1 实现是下方 phase_initJvmWithClasspath()（bootstrap 只挂
//   amcl-launcher.jar，游戏 classpath 交给 AmclClassLoader 动态挂载）。
//   它的 xmx mmap 预检警示已随迁至该函数内。

/**
 * JVM 创建前冻结的属性快照。只在本局调用上游加载器前回读；不重新设置已缓存的值，
 * 也不通过 FindClass 初始化 LWJGL、SDL 或 CallbackBridge。发布后同一 JVM 不会再启动第二局。
 */
static std::vector<amcl::jvm::BootstrapProperty> g_runtimeBootstrapProperties;
static bool phase_verifyRuntimeProperties(JNIEnv* env) {
    for (const auto& property : g_runtimeBootstrapProperties) {
        if (getSystemProperty(env, property.first.c_str()) != property.second) {
            g_mcStatus = "运行库属性已被提前修改: " + property.first;
            AMCL_LOG_E(LOG_TAG, "runtime_property_mismatch key=%{public}s", property.first.c_str());
            return false;
        }
    }
    AMCL_LOG_I(LOG_TAG, "AMCL_RUNTIME_BOOTSTRAP properties=verified game_java_preload=0");
    return true;
}

/**
 * 发布本局 SDL 的不可变宿主描述符，不打开 SDL/GLFW，不借 Java 层提前加载 JNI core。
 * SDL 的实际实例在 InitSubSystem 入口验证 PID、系统 TID、session 后完成 main-ready。
 * 描述符一直保留到进程退出；即使主函数返回，本进程的 JVM 也已经不可复用。
 */
static bool phase_publishPlatformRuntime(uint64_t session) {
    if (publishCallbackBridgeHostV1(session) != JNI_OK) {
        g_mcStatus = "JNI bridge 宿主接口发布失败";
        return false;
    }
    const auto* plan = amcl::graphics::ActiveGraphicsPlan();
    if (!plan) { g_mcStatus = "缺少已激活的图形计划"; return false; }
    if (plan->window == "SDL3") {
        char descriptor[128];
        const long tid = static_cast<long>(syscall(SYS_gettid));
        std::snprintf(descriptor, sizeof(descriptor), "1:%llu:%llu:%llu",
            static_cast<unsigned long long>(getpid()), static_cast<unsigned long long>(tid),
            static_cast<unsigned long long>(session));
        const char* previous = std::getenv("AMCL_SDL_HOST_RUNTIME");
        if ((previous && std::strcmp(previous, descriptor) != 0) ||
            setenv("AMCL_SDL_HOST_RUNTIME", descriptor, 1) != 0) {
            g_mcStatus = "SDL 宿主运行身份冲突，需要重启游戏进程";
            return false;
        }
        AMCL_LOG_I(LOG_TAG, "AMCL_SDL_HOST_RUNTIME published pid=%{public}d tid=%{public}ld session=%{public}llu",
            getpid(), tid, static_cast<unsigned long long>(session));
    }
    return true;
}

// 只挂载游戏 classpath，不初始化游戏平台库。AmclLauncher.main 在同一 attached 线程消费
// prepared state，随后上游加载器按照自己的拓扑选择各个平台绑定类的定义者。
static bool phase_prepareJavaLaunch(JNIEnv* env, const std::string& launchConfigJson) {
    AMCL_LOG_I(LOG_TAG, "[Phase 1.5] PREPARE_JAVA_CLASSPATH");
    jclass launcher = env->FindClass("com/amcl/launcher/AmclLauncher");
    if (!launcher || env->ExceptionCheck()) {
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
        }
        if (launcher) env->DeleteLocalRef(launcher);
        g_mcStatus = "❌ AmclLauncher 启动类不可用";
        return false;
    }
    jmethodID prepare = env->GetStaticMethodID(launcher, "prepare", "(Ljava/lang/String;)V");
    if (!prepare || env->ExceptionCheck()) {
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
        }
        env->DeleteLocalRef(launcher);
        g_mcStatus = "❌ AmclLauncher.prepare 不可用";
        return false;
    }
    // JSON 内含 username/gameDir 等用户内容 → 必须转 MUTF-8（增补字符对 NewStringUTF 是 UB）
    jstring json = env->NewStringUTF(amcl::toModifiedUtf8(launchConfigJson).c_str());
    if (!json || env->ExceptionCheck()) {
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
        }
        if (json) env->DeleteLocalRef(json);
        env->DeleteLocalRef(launcher);
        g_mcStatus = "❌ 启动配置无法传入 Java";
        return false;
    }
    env->CallStaticVoidMethod(launcher, prepare, json);
    const bool ok = !env->ExceptionCheck();
    if (!ok) {
        env->ExceptionDescribe();
        env->ExceptionClear();
        g_mcStatus = "❌ 游戏 classpath 所有权检查失败";
    }
    env->DeleteLocalRef(json);
    env->DeleteLocalRef(launcher);
    return ok;
}

// Phase 4: 重定向 IO
std::string g_mcOutputLogPath; // 供 logTailThread 使用

/**
 * 游戏日志保留的历史局数（当前 mc_output.log 之外，再留 N 局）。
 * 命名与启动器日志一致：mc_output.1.log（上一局）… mc_output.3.log（最旧）。
 */
static constexpr int MC_LOG_MAX_BACKUPS = 3;

/**
 * 为新的一局归档上一局日志（日志系统 v3 · S2）。
 *
 * 2026-07-30 修复 P0-2：**旧实现每次启动都会把上一局日志清空**。
 *   根因不是注释里写的"多局累积无限增长"，而是恰恰相反 —— Java 侧用的是
 *   `new FileOutputStream(String)` **单参构造，语义是截断**（不是追加）。
 *   真机取证印证了这点：文件里始终只有 1 个会话，且全盘从未出现过 `.1` 备份
 *   （原来那段 8 MiB 轮转因此形同死代码，已随本次改造删除）。
 *   后果是用户复现一次问题、日志就没了，"一局游戏的完整日志"根本留不住。
 *
 * 现在改为：每局开始前把上一局整体归档，滚动保留最近 MC_LOG_MAX_BACKUPS 局。
 * 配合下面的 append 语义，当前局日志从空开始且全程只增不减。
 */
static void archivePreviousGameLog(const std::string& base) {
    std::string cur = base + ".log";
    struct stat st;
    if (stat(cur.c_str(), &st) != 0 || st.st_size <= 0) return;  // 上一局没留下内容

    // 删最旧的一份，其余依次后移
    std::string oldest = base + "." + std::to_string(MC_LOG_MAX_BACKUPS) + ".log";
    remove(oldest.c_str());
    for (int i = MC_LOG_MAX_BACKUPS - 1; i >= 1; i--) {
        std::string from = base + "." + std::to_string(i) + ".log";
        std::string to   = base + "." + std::to_string(i + 1) + ".log";
        rename(from.c_str(), to.c_str());   // 不存在时失败无害
    }
    std::string first = base + ".1.log";
    if (rename(cur.c_str(), first.c_str()) == 0) {
        AMCL_LOG_I(LOG_TAG, "Archived previous session log (%ld bytes) -> mc_output.1.log",
                   (long)st.st_size);
    } else {
        // 归档失败不阻断启动：最坏情况是这一局继续追加在上一局后面（仍不丢数据）
        AMCL_LOG_W(LOG_TAG, "Failed to archive previous session log: %s", strerror(errno));
    }
}

/**
 * 写入机器可解析的会话起始标记（日志系统 v3 · S2）。
 * 让离线分析能明确切出"这一局"，也便于用户在文件里一眼看到分界。
 */
static void writeSessionBanner(const std::string& gameDir) {
    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    char ts[32] = {0};
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm_buf);
    // 直接走 stdout（此时已 dup2 到日志文件），与游戏输出同序
    printf("\n##AMCL-SESSION-BEGIN {\"startedAt\":\"%s\",\"epochMs\":%lld,\"activityId\":%lld,\"gameDir\":\"%s\"}\n",
           ts, (long long)now * 1000LL, (long long)amclLedgerGetLaunchActivity(), gameDir.c_str());
    fflush(stdout);
}

static bool phase_redirectIO(JNIEnv* env, const std::string& gameDir) {
    AMCL_LOG_I(LOG_TAG, "[Phase 4] REDIRECT_IO logFile=%s/mc_output.log", gameDir.c_str());
    std::string base = gameDir + "/mc_output";
    // 新启动的原件由 JVM 前准备的会话目录拥有；旧工具没有活动 ID 时才保留兼容路径。
    const bool sessionOwned = amcl::sessionlog::owned();
    std::string logFile = sessionOwned ? amcl::sessionlog::consolePath() : base + ".log";
    g_mcOutputLogPath = logFile;
    // jvm_launcher 的崩溃 handler 使用固定 C 缓冲保存这个路径，避免在
    // signal context 中读取 std::string。
    jvmSetCrashOutputPath(logFile.c_str());
    g_mcStatus = "重定向日志...";

    // 一局一文件：先把上一局归档，本局从空文件开始
    if (!sessionOwned) archivePreviousGameLog(base);

    // 2026-07-30 修复 P1-1：**单一写入者**。
    //   旧实现 C 侧 `freopen(…,"a")` 走 O_APPEND，Java 侧 fd 从 0 起按自己的偏移写，
    //   两个 fd 的文件位置互相独立 —— native 的输出会被随后的 Java 输出覆盖，
    //   日志内容不可信。现在改为：用 open() 拿一个 O_APPEND 的 fd 并 dup2 到
    //   STDOUT/STDERR，Java 侧改用**两参构造 append=true**。两边都是 O_APPEND，
    //   每次 write 都原子地追加到当前末尾，不再互相覆盖。
    int fd = open(logFile.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        const bool redirected = dup2(fd, STDOUT_FILENO) >= 0 && dup2(fd, STDERR_FILENO) >= 0;
        if (fd != STDOUT_FILENO && fd != STDERR_FILENO) close(fd);
        if (!redirected) {
            amcl::sessionlog::failure(errno);
            AMCL_LOG_E(LOG_TAG, "Session stdout/stderr dup2 failed: %s", strerror(errno));
            return false;
        }
        // 原始证据不依赖退出时的 stdio flush；普通运行仍由系统页缓存合并磁盘写入。
        setvbuf(stdout, nullptr, _IONBF, 0);
        setvbuf(stderr, nullptr, _IONBF, 0);
    } else {
        amcl::sessionlog::failure(errno);
        AMCL_LOG_E(LOG_TAG, "Session output open failed: %s", strerror(errno));
        return false;
    }

    if (!sessionOwned) writeSessionBanner(gameDir);

    bool javaRedirected = false;
    jclass fosClass = env->FindClass("java/io/FileOutputStream");
    jclass psClass = env->FindClass("java/io/PrintStream");
    jclass systemClass = env->FindClass("java/lang/System");
    if (fosClass && psClass && systemClass) {
        // ⚰️ 2026-09-04：这里曾加过一次 `System.out.flush()`，想把 Phase 1.5 的诊断
        //   （`phase=isolation` / `[AMCL-TERRAIN-PATCH-SET]` / `[AMCL-CP-DELIVERY]`）
        //   从"永久丢失"里救回来。**真机实测无效，已撤回。**
        //
        //   当时的成因假设是"Java 侧 8 KiB 缓冲未 flush"，那是**推断而非实测**（违反
        //   AGENTS.md §二.1）。真实机制在 jvm_launcher.cpp：`JNI_CreateJavaVM` 之前
        //   `dup2(jvm_stderr.log, STDOUT/STDERR)`，**createVM 一返回就 dup2 回原始 fd**。
        //   ⇒ Phase 1.5 的 Java 输出写的是应用原始 stdout，OHOS 直接丢弃；
        //   flush 只是把字节更早地送进那个黑洞。
        //
        //   ⇒ 可见性问题的正确修法不在这一层：需要让 Phase 1.5 的判定在**换流之后**
        //   复述一次。见 `AmclClassLoader.reportPatchSetStatesAfterRedirect()`
        //   与施工记录 §S05。
        // (Ljava/lang/String;Z)V = FileOutputStream(String name, boolean append)
        // 必须用两参构造并传 append=true。单参构造是**截断**语义，正是 P0-2 的根因。
        jmethodID fosCtor = env->GetMethodID(fosClass, "<init>", "(Ljava/lang/String;Z)V");
        jstring jLogFile = env->NewStringUTF(amcl::toModifiedUtf8(logFile).c_str());
        jobject fos = fosCtor && jLogFile && !env->ExceptionCheck()
            ? env->NewObject(fosClass, fosCtor, jLogFile, (jboolean)JNI_TRUE) : nullptr;
        if (fos && !env->ExceptionCheck()) {
            jmethodID psCtor = env->GetMethodID(psClass, "<init>", "(Ljava/io/OutputStream;Z)V");
            jobject ps = psCtor && !env->ExceptionCheck() ? env->NewObject(psClass, psCtor, fos, (jboolean)JNI_TRUE) : nullptr;
            if (ps && !env->ExceptionCheck()) {
                jmethodID setOut = env->GetStaticMethodID(systemClass, "setOut", "(Ljava/io/PrintStream;)V");
                jmethodID setErr = env->GetStaticMethodID(systemClass, "setErr", "(Ljava/io/PrintStream;)V");
                if (setOut && setErr && !env->ExceptionCheck()) {
                    env->CallStaticVoidMethod(systemClass, setOut, ps);
                    if (!env->ExceptionCheck()) env->CallStaticVoidMethod(systemClass, setErr, ps);
                    javaRedirected = !env->ExceptionCheck();
                }
                AMCL_LOG_I(LOG_TAG, "Java stdout/stderr redirected to mc_output.log");
            }
            if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }
        } else {
            if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }
        }
        env->DeleteLocalRef(jLogFile);
    }
    if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }
    if (!javaRedirected) {
        amcl::sessionlog::failure(EIO);
        AMCL_LOG_E(LOG_TAG, "Java stdout/stderr replacement failed; launch stopped with capture gap");
        return false;
    }
    amcl::sessionlog::javaReady();
    // 标准 java.lang.System 属于 bootstrap，不触发任何游戏 JNI/加载器预热。
    const jmethodID property = env->GetStaticMethodID(systemClass, "getProperty", "(Ljava/lang/String;)Ljava/lang/String;");
    const char* properties[] = {"java.version", "java.vendor", "java.vm.name", "os.arch", "os.name"};
    const char* keys[] = {"java.version", "java.vendor", "java.vm", "java.arch", "java.guestOs"};
    if (property) for (int index = 0; index < 5; ++index) {
        jstring name = env->NewStringUTF(properties[index]);
        jstring value = static_cast<jstring>(env->CallStaticObjectMethod(systemClass, property, name));
        if (value && !env->ExceptionCheck()) {
            const char* text = env->GetStringUTFChars(value, nullptr);
            if (text) {
                amclLogWriteFor(amclLedgerGetLaunchActivity(), AMCL_LOG_LEVEL_INFO, "SessionEnvironment",
                    "AMCL_ENV_V1\t%s\t%s\tJVM.System.getProperty", keys[index], text);
                env->ReleaseStringUTFChars(value, text);
            }
        }
        if (env->ExceptionCheck()) env->ExceptionClear();
        if (value) env->DeleteLocalRef(value);
        env->DeleteLocalRef(name);
    }

    mkdir((gameDir + "/logs").c_str(), 0755);
    chdir(gameDir.c_str());
    return true;
}

// Phase 5: 调用 MC Main（支持自定义 mainClass 和 mcArgs）
// 启动后台线程定期读取 mc_output.log 新增内容输出到 hilog（调试/诊断用）。
//
// 2026-06-06 重写（修复"MC 闪退时真正的 Java 异常堆栈在 hilog 里丢失"的诊断盲区）：
//   旧实现有三个致命缺陷：
//     1) 每轮只读"新增内容的最后 500 字节" → MC 初始化每 3 秒写入远超 500B，
//        异常堆栈（数十行）绝大部分被直接丢弃；
//     2) 在 500 字节窗口上直接 strtok → 首尾行被从中间截断（hilog 里常见
//        "ch(MinecraftGameProvider.java:514)" 这种半截行）；
//     3) 轮询间隔 3 秒，崩溃发生在两次轮询之间时最后一段输出永远读不到。
//   新实现：按文件偏移【增量读取全部新增字节】，跨轮缓冲不完整的行、只输出完整行；
//   轮询间隔降到 1 秒；过滤每帧刷屏的 "[GLFW-DIAG] poll#" 行避免 hilog 限流丢日志；
//   线程停止时做一次最终 drain（含残留的最后一行）。
//   背景：mc_output.log 在 app el2 沙箱/外部 Download 目录，hdc shell 因 uid/命名空间
//   隔离读不到，所以 hilog 转发是真机排查 MC 闪退异常的唯一可靠通道，必须完整可信。
// 2026-08-27（加载链审查修复批次）：停止信号从单布尔改为世代计数。
// 旧协议是「启动前置 false → 线程自己置 true → 结束时置 false」：若 jvmCallMain
// 快速失败，主线程的置 false 可能先于新线程的置 true 执行 —— 停止信号被覆盖，
// 孤儿线程永续轮询；重试启动还会出现两个线程对同一文件双份转发。
// 现在每次启动 fetch_add 拿自己的世代号，任何后续 fetch_add（停止/新启动）都会
// 让旧线程在下一轮退出，无窗口期。
static std::atomic<uint64_t> g_logTailGeneration{0};
static void logTailThread(std::string logPath, uint64_t myGeneration) {
    long lastPos = 0;
    std::string lineBuf;            // 跨轮缓冲：上一轮末尾不完整的行
    const size_t kMaxLineBuf = 1 << 20; // 1MB 保护：极端无换行行强制冲洗，避免无限增长

    auto emitOneLine = [](std::string line) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) return;
        // 过滤每帧刷屏行，避免 hilog 限流把真正有用的日志挤掉
        if (line.find("[GLFW-DIAG] poll#") != std::string::npos) return;
        // 只转发到 hilog，**不再**经 AMCL_LOG_I 走应用自己的文件日志。
        //
        // MC 的输出本来就已经完整落在 mc_output.log 里，再抄一份进应用日志纯属重复：
        // 每行都要抢 512 槽环形缓冲的锁并唤醒 writer 线程，MC 初始化/游戏中每秒
        // 成百上千行，等于把应用日志管道整个占住 —— 真正的启动器诊断行被挤掉，
        // 而且 writer 的唤醒风暴与 ArkUI / 渲染线程抢 CPU，表现为输入回调延迟。
        // 转发的目的一直只是"hdc 沙箱外看不到 mc_output.log"，hilog 一条就够。
        OH_LOG_INFO(LOG_APP, "[%{public}s] MC_LOG: %{public}s", LOG_TAG,
                    line.c_str());
    };
    auto emitCompleteLines = [&](bool flushRemainder) {
        size_t start = 0;
        for (;;) {
            size_t nl = lineBuf.find('\n', start);
            if (nl == std::string::npos) break;
            emitOneLine(lineBuf.substr(start, nl - start));
            start = nl + 1;
        }
        lineBuf.erase(0, start);
        // 1MB 保护：单行长期无换行时强制冲洗，防止 lineBuf 无限增长
        if (!flushRemainder && lineBuf.size() > kMaxLineBuf) {
            emitOneLine(lineBuf);
            lineBuf.clear();
        }
        if (flushRemainder && !lineBuf.empty()) {
            emitOneLine(lineBuf);
            lineBuf.clear();
        }
    };
    auto drainNewBytes = [&](FILE* f, long curSize) {
        fseek(f, lastPos, SEEK_SET);
        char buf[8192];
        long remaining = curSize - lastPos;
        while (remaining > 0) {
            size_t want = remaining > (long)sizeof(buf) ? sizeof(buf) : (size_t)remaining;
            size_t n = fread(buf, 1, want, f);
            if (n == 0) break;
            lineBuf.append(buf, n);
            remaining -= (long)n;
        }
        lastPos = curSize;
    };

    while (g_logTailGeneration.load(std::memory_order_relaxed) == myGeneration) {
        usleep(1000000); // 1 秒
        FILE* f = fopen(logPath.c_str(), "r");
        if (!f) continue;
        fseek(f, 0, SEEK_END);
        long curSize = ftell(f);
        // 日志被截断/轮转（curSize < lastPos）→ 从头再读
        if (curSize < lastPos) { lastPos = 0; lineBuf.clear(); }
        if (curSize > lastPos) {
            drainNewBytes(f, curSize);
            emitCompleteLines(false);
        }
        fclose(f);
    }

    // 线程停止时最终 drain（含残留的不完整最后一行）
    FILE* f = fopen(logPath.c_str(), "r");
    if (f) {
        fseek(f, 0, SEEK_END);
        long curSize = ftell(f);
        if (curSize < lastPos) { lastPos = 0; lineBuf.clear(); }
        if (curSize > lastPos) drainNewBytes(f, curSize);
        fclose(f);
    }
    emitCompleteLines(true);
}

static bool phase_launchMain(JNIEnv* env, const std::string& mainClass,
                             const std::vector<std::string>& mcArgs) {
    AMCL_LOG_I(LOG_TAG, "[Phase 5] LAUNCH_MAIN: %s (%zu args)", mainClass.c_str(), mcArgs.size());
    g_mcStatus = "⏳ MC Main 运行中";

    // 启动日志 tail 线程
    // 从 mcArgs 中提取 gameDir（最后一个参数通常是 JSON 配置，但我们用 phase_redirectIO 的路径）
    // 实际上 mc_output.log 的路径在 phase_redirectIO 中已经确定了
    // 这里我们从 mainClass 推断——如果是 AmclLauncher，gameDir 在 JSON 参数中
    // 简单方案：直接用全局的 stdout 重定向目标
    extern std::string g_mcOutputLogPath; // 在 phase_redirectIO 中设置
    if (!g_mcOutputLogPath.empty()) {
        const uint64_t generation =
            g_logTailGeneration.fetch_add(1, std::memory_order_relaxed) + 1;
        std::thread tailThread(logTailThread, g_mcOutputLogPath, generation);
        tailThread.detach();
    }

    std::vector<const char*> argv;
    for (const auto& arg : mcArgs) {
        argv.push_back(arg.c_str());
    }

    int rc = jvmCallMain(mainClass.c_str(), (int)argv.size(), argv.data());
    g_logTailGeneration.fetch_add(1, std::memory_order_relaxed); // 停止 tail 线程（推进世代）

    if (rc != 0) {
        g_mcStatus = std::string("❌ MC Main 失败: ") + jvmGetStatus();
        return false;
    }
    g_mcStatus = "MC Main 执行完成";
    return true;
}

// `java.class.path` 的两种交付方式。与 ArkTS `ClasspathDelivery` 的字面量逐字对应
// （契约见 docs/refactor/启动世代契约规范.md §3.3）。
//
// ⚠️ 字面量必须与 ArkTS 侧一致，由 scripts/check-launch-generation-contract.mjs 静态校验 ——
// 两侧各写一份字符串必然漂移，那正是渲染后端 id 曾经出现在 6 处的同一个问题。
static constexpr const char* kDeliveryAmclLoaderOnly = "amcl-loader-only";
static constexpr const char* kDeliveryJvmClasspathFull = "jvm-classpath-full";

// Phase 1 变体：使用外部提供的 classpath（数据驱动模式）
//
// ⭐ `delivery` 由 ArkTS 的世代契约表决定，本函数**只执行、不推断**。
//   2026-09-04 之前这里硬编码"只挂 amcl-launcher.jar"，而那条收窄对原版是必需的、
//   对 Forge 新 bootstrap 与 Fabric Knot 是致命的（它们只认 java.class.path）——
//   一个全局值服务 7 条不同契约，于是 Fabric（1000576）与 Forge 先后启动即崩。
//   成因与取证见 docs/reports/2026-09-04_FORGE_BOOTSTRAP_CLASSPATH_OWNERSHIP_RESEARCH.md。
static bool phase_initJvmWithClasspath(const std::string& filesDir,
                                       const std::string& gameDir,
                                       const std::string& classpath,
                                       int xmx, const char* jdkVersion,
                                       const std::string& delivery) {
    AMCL_LOG_I(LOG_TAG, "[Phase 1] INIT_JVM (profile classpath, %zu chars)", classpath.size());
    // 在动态加载 JVM 和 Java bootstrap 之前固定原始输出；此失败不能被“启动就绪”掩盖。
    if (!amcl::sessionlog::prepare(filesDir.c_str(), amclLedgerGetLaunchActivity())) {
        g_mcStatus = "会话日志无法创建或重定向，请检查存储空间";
        AMCL_LOG_E(LOG_TAG, "Session log preparation failed before JVM initialization");
        return false;
    }
    // ⚠️ 2026-04-19：不要在此加 xmx 虚拟地址空间预检（曾移植 Amethyst-iOS
    // validateVirtualMemorySpace：mmap(xmx+256MB, PROT_NONE) + munmap）。实测导致
    // MC Render thread 初始化 JVM 模块系统时卡死（mc_output.log 停在
    // "Opening jdk.naming.dns ... to java.naming"）——OHOS 内核对进程虚拟地址空间
    // 的分配策略与 Linux/iOS 不同，预先 reserve 再 release 的大块区间会干扰
    // HotSpot heap reservation / elf_loader 已映射的 JDK .so 布局。
    // 详见 docs/ROADMAP.md "踩坑记录"。
    g_mcStatus = "初始化 JVM...";

    std::string nativesDir = gameDir + "/natives";
    if (!dirExists(nativesDir.c_str())) {
        if (mkdir(nativesDir.c_str(), 0755) != 0 && errno != EEXIST) {
            const int error = errno;
            g_mcStatus = std::string("❌ natives 目录创建失败: ") + nativesDir;
            AMCL_LOG_E(LOG_TAG, "Cannot create natives directory %s errno=%d (%s)",
                       nativesDir.c_str(), error, strerror(error));
            return false;
        }
        if (!dirExists(nativesDir.c_str())) {
            g_mcStatus = std::string("❌ natives 目录不可用: ") + nativesDir;
            AMCL_LOG_E(LOG_TAG, "Natives path is not a directory after mkdir: %s",
                       nativesDir.c_str());
            return false;
        }
    }

    std::string launcherJar = filesDir + "/amcl-launcher.jar";
    // JNA 早读属性已冻结到实例子目录；必须在 JVM/agent 之前准备，不能回退到共享应用根。
    const std::string jnaTemp = nativesDir + "/jna";
    if (!dirExists(jnaTemp.c_str()) && mkdir(jnaTemp.c_str(), 0755) != 0 && errno != EEXIST) {
        g_mcStatus = "JNA 实例临时目录创建失败";
        return false;
    }
    if (!dirExists(jnaTemp.c_str())) { g_mcStatus = "JNA 临时路径不是目录"; return false; }
    if (!fileExists(launcherJar.c_str()) || fileSize(launcherJar.c_str()) <= 0) {
        g_mcStatus = "❌ amcl-launcher.jar 缺失";
        AMCL_LOG_E(LOG_TAG, "Bootstrap classpath jar missing: %{public}s", launcherJar.c_str());
        return false;
    }

    // 未知/缺失的 delivery 值倒向"完整 classpath"，与 ArkTS 的
    // UNKNOWN_GENERATION_DELIVERY 同一条 fail-open 决策：猜错的代价是 terrain 变换
    // 静默失效（掉帧），反向猜错的代价是启动即崩。
    const bool narrow = (delivery == kDeliveryAmclLoaderOnly);
    if (narrow) {
        // 原版路线：JVM 的父加载器只能看见启动器。完整游戏 classpath 经 LaunchConfig JSON
        // 交给 AmclClassLoader 动态挂载 —— 游戏 jar 一旦进 java.class.path，默认
        // AppClassLoader 会因 parent-first 抢先定义游戏 Main，AmclClassLoader.findClass()
        // 永远收不到兼容目标，terrain 变换静默失效。
        jvmSetClasspath(launcherJar.c_str());
    } else {
        // 模组加载器路线：与 642edf87 之前逐字相同的形态，也是桌面端/HMCL/FCL/Pojav
        // 的原生契约。加载器自己定义游戏类，收窄在这里保护不到任何东西
        // （五个 patch set 的哈希门禁在该路线上全部 fail closed，实测见根因报告 §3）。
        std::string fullCp = launcherJar + ":" + classpath;
        jvmSetClasspath(fullCp.c_str());
    }
    // 单一判据行：delivery 是声明值，narrow 是**实际执行**的那一支。两者都打出来，
    // 才能把"表里写了什么"与"真的做了什么"分开归因。
    AMCL_LOG_I(LOG_TAG,
               "AMCL_CP_OWNERSHIP schema=1 delivery=%{public}s narrow=%d bootstrap_jars=1 game_chars=%zu",
               delivery.empty() ? "(absent)" : delivery.c_str(), narrow ? 1 : 0, classpath.size());
    // 仅在 extraLibPath 未被预设时设置默认值（Forge 启动时已在调用方合并了 native 路径）
    const char* currentExtraLib = jvmGetExtraLibPath();
    if (!currentExtraLib || currentExtraLib[0] == '\0') {
        jvmSetExtraLibPath(nativesDir.c_str());
    } else {
        AMCL_LOG_I(LOG_TAG, "Keeping pre-set extraLibPath, skipping default nativesDir");
    }
    jvmSetXmx(xmx);

    int rc = jvmInit(filesDir.c_str(), jdkVersion);
    if (rc != 0) {
        g_mcStatus = std::string("❌ JVM 初始化失败: ") + jvmGetStatus();
        return false;
    }
    return true;
}

// 旧协议辅助：将逗号分隔的字符串拆分为 vector
static std::vector<std::string> splitString(const std::string& str, char delim) {
    std::vector<std::string> result;
    std::string item;
    for (char c : str) {
        if (c == delim) {
            if (!item.empty()) result.push_back(item);
            item.clear();
        } else {
            item += c;
        }
    }
    if (!item.empty()) result.push_back(item);
    return result;
}

static std::vector<std::string> toArgVector(int argc, const char* const* argv) {
    std::vector<std::string> result;
    if (!argv || argc <= 0) return result;
    result.reserve((size_t)argc);
    for (int i = 0; i < argc; ++i) {
        if (argv[i] && argv[i][0] != '\0') {
            result.emplace_back(argv[i]);
        }
    }
    return result;
}

// ============================================================
//  启动线程：依次执行 Phase 1.5-5（Phase 0-1 在主线程完成）
// ============================================================
// ⚰️ 2026-08-27（加载链审查修复批次）：这里曾有 legacy 的 mcLaunchThread()
//   （硬编码 mainClass/mcArgs、不经 AmclLauncher），随 mcLaunch 退役删除。

// 数据驱动启动线程（v3 架构：从 profile 读取所有参数）
// 通过 AmclLauncher Java 中间层启动 MC（动态 classpath + Forge 预处理）
static void mcLaunchThreadWithProfile(std::string filesDir, std::string gameDir,
                                      std::string mcDir,
                                      std::string hapNativeDir, std::string mainClass,
                                      std::string mcClasspath,
                                      std::vector<std::string> mcArgs,
                                      bool isForge, bool isFabric) {
    // 活动账本（L3）：本线程后续所有 MC_LAUNCHER / JVM_LAUNCHER 日志归属到这一局。
    // 必须放在函数最开头 —— 下面第一条 AMCL_LOG_I 就该被算进账本。
    AmclActivityScope actScope(amclLedgerGetLaunchActivity());
    AMCL_LOG_I(LOG_TAG, "=== MC Launch Thread Started (profile via AmclLauncher) ===");
    AMCL_LOG_I(LOG_TAG, "  mainClass: %s, args: %zu, forge: %d, mcDir: %s",
               mainClass.c_str(), mcArgs.size(), isForge,
               mcDir.empty() ? "(=gameDir)" : mcDir.c_str());

    JavaVM* jvm = (JavaVM*)jvmGetJavaVM();
    if (!jvm) { g_mcStatus = "❌ JVM 未初始化"; jvmRetireRuntime(); g_mcRunning = false; return; }

    JNIEnv* env = nullptr;
    if (jvm->AttachCurrentThread((void**)&env, nullptr) != 0 || !env) {
        g_mcStatus = "❌ AttachCurrentThread 失败"; jvmRetireRuntime(); g_mcRunning = false; return;
    }

    // 构建 JSON 配置传给 AmclLauncher
    {
        std::string json = buildLaunchConfigJson(
            mainClass, mcClasspath, mcArgs, gameDir, mcDir, filesDir, isForge, isFabric);
        // 日志先就绪，prepare 的失败证据也必须落盘。原生 host 仅发布描述符，不触发 JNI
        // 游戏类查找；LWJGL/SDL 的首次加载留给 Knot/Forge/FML 自己建立的合法库域。
        const int64_t activity = amclLedgerGetLaunchActivity();
        const uint64_t session = activity > 0 ? static_cast<uint64_t>(activity) :
            static_cast<uint64_t>(std::chrono::steady_clock::now().time_since_epoch().count()) + 1u;
        if (!phase_redirectIO(env, gameDir))                                    goto cleanup;
        if (!phase_publishPlatformRuntime(session))                            goto cleanup;
        if (!phase_verifyRuntimeProperties(env))                                goto cleanup;
        if (!phase_prepareJavaLaunch(env, json))                                goto cleanup;
        std::vector<std::string> launcherArgs = { json };
        amcl::sessionlog::gameReady();
        const bool mainOk = phase_launchMain(
            env, "com.amcl.launcher.AmclLauncher", launcherArgs);
        if (rendererRestartMarkerPresent()) {
            markRendererProcessTainted("SDL renderer lifecycle failure");
        } else if (!mainOk) {
            AMCL_LOG_W(LOG_TAG,
                       "MC main returned failure without renderer taint marker");
        }
    }

cleanup:
    // 无论正常返回还是 Java 准备失败，已创建的 JVM 都不可再承载另一套游戏加载器。
    // 只撤销本方 bridge，绝不尝试卸载游戏 JNI 库来伪造“恢复干净”。
    revokeCallbackBridgeHostV1();
    jvmRetireRuntime();
    jvm->DetachCurrentThread();
    g_mcRunning = false;
}

// ⚰️ 2026-08-27（加载链审查修复批次）：这里曾有 legacy 公开接口 mcLaunch()
//   （C 层拼 classpath + mcLaunchThread 硬编码参数、不经 AmclLauncher）。
//   它把游戏 jar 全量放进 java.class.path —— 父加载器会抢先定义游戏类、绕过
//   AmclClassLoader 的兼容变换（隔离契约见 phase_initJvmWithClasspath 内注释），
//   而日志仍会报 patch-set active。ArkTS 侧早已无调用方（唯一启动入口 =
//   mcLaunchWithProfileV2），与 NAPI 导出 / index.d.ts / obfuscation-rules 同批删除。

// ============================================================
//  数据驱动启动接口（v3 架构）
//  ArkTS 层解析 version.json 后传入所有参数，C 层纯执行
// ============================================================
static int launchWithProfileImpl(const char* appFilesDir, const char* gameDir,
                                 const char* jdkVersion, int xmxMb,
                                 const char* mainClass, const char* classpath,
                                 const std::vector<std::string>& mcArgs,
                                 const std::vector<std::string>& extraJvmArgs) {
    mcClearGraphicsLaunchFailure();
    if (g_rendererProcessTainted.load(std::memory_order_acquire) ||
        rendererRestartMarkerPresent()) {
        markRendererProcessTainted("new launch requested after renderer failure");
        recordGraphicsLaunchFailure(-2, "runtime", "renderer_process_tainted", "", true);
        return -2;
    }
    const int runtimeState = jvmRuntimeState();
    if (runtimeState == amcl::jvm::RuntimeOnce::ForkReserved) {
        g_mcStatus = "安装器正在派生独立运行时，请稍后重试";
        return -8;
    }
    if (runtimeState != amcl::jvm::RuntimeOnce::Fresh) {
        g_mcStatus = "JVM 已用于本局或启动失败，需要重启游戏进程后再启动";
        AMCL_LOG_E(LOG_TAG, "runtime_restart_required state=%{public}d", jvmRuntimeState());
        recordGraphicsLaunchFailure(-7, "runtime", "runtime_already_used", "", true);
        return -7;
    }
    if (g_mcRunning) {
        g_mcStatus = "MC 已在运行中";
        return -1;
    }
    if (!appFilesDir || !gameDir || !mainClass || !classpath) {
        g_mcStatus = "参数为空";
        return -1;
    }

    // 原子认领启动事务，防止两个入口在 JVM 创建之前各自看到 false 后同时修改全局参数。
    bool expectedRunning = false;
    if (!g_mcRunning.compare_exchange_strong(expectedRunning, true)) {
        g_mcStatus = "MC 正在启动中";
        return -1;
    }
    g_mcStatus = "正在启动...";

    /* A normal new launch starts with an explicit clean marker.  Never clear
     * it after the process has been tainted; the guard above rejects reuse. */
    unsetenv("AMCL_RENDERER_REQUIRES_PROCESS_RESTART");

    // 重置上次启动可能残留的 extraLibPath（避免 Forge→Vanilla 切换时路径污染）
    jvmSetExtraLibPath("");

    std::string filesDir(appFilesDir);
    initMarkerPath(filesDir);
    remove(g_markerPath.c_str());
    std::string gameDirStr(gameDir);
    int xmx = xmxMb > 0 ? xmxMb : computeRecommendedXmx();
    std::string hapNativeDir = resolveHapNativeDir(filesDir);

    // Resolve one immutable graphics plan before JVM/LWJGL/provider initialization.
    // The legacy GL marker remains accepted for ABI compatibility, but cannot
    // silently override a structured plan.
    amcl::graphics::GraphicsPlan graphicsPlan;
    std::string graphicsWire, legacyBackend, graphicsError;
    int graphicsPlanMarkers = 0;
    int legacyBackendMarkers = 0;
    int sdlMarkers = 0;
    bool legacySdl = false;
    bool sdlMarkerValid = true;
    for (const auto& arg : extraJvmArgs) {
        static constexpr char kPlan[] = "-Damcl.graphics.plan=";
        static constexpr char kLegacy[] = "-Damcl.gl.backend=";
        if (arg.compare(0, sizeof(kPlan) - 1, kPlan) == 0) { graphicsWire = arg.substr(sizeof(kPlan) - 1); ++graphicsPlanMarkers; }
        if (arg.compare(0, sizeof(kLegacy) - 1, kLegacy) == 0) {
            legacyBackend = arg.substr(sizeof(kLegacy) - 1);
            ++legacyBackendMarkers;
        }
        if (arg.compare(0, sizeof("-Damcl.sdl3=") - 1, "-Damcl.sdl3=") == 0) {
            ++sdlMarkers;
            legacySdl = arg == "-Damcl.sdl3=1";
            sdlMarkerValid = arg == "-Damcl.sdl3=0" || legacySdl;
        }
    }
    bool graphicsPlanOk = graphicsPlanMarkers <= 1 && legacyBackendMarkers <= 1 && sdlMarkers <= 1 && sdlMarkerValid &&
        (graphicsPlanMarkers == 0
        ? amcl::graphics::LegacyGraphicsPlan(legacyBackend, graphicsPlan, graphicsError)
        : amcl::graphics::ParseGraphicsPlan(graphicsWire, graphicsPlan, graphicsError));
    if (graphicsPlanMarkers > 1 || legacyBackendMarkers > 1 || sdlMarkers > 1) graphicsError = "duplicate_graphics_marker";
    if (!sdlMarkerValid) graphicsError = "invalid_sdl_marker";
    if (graphicsPlanOk && graphicsPlanMarkers == 0) graphicsPlan.window = legacySdl ? "SDL3" : "GLFW";
    if (graphicsPlanOk && graphicsPlanMarkers == 1 && sdlMarkers != 0 && legacySdl != (graphicsPlan.window == "SDL3")) {
        graphicsPlanOk = false;
        graphicsError = "sdl_marker_conflicts_with_graphics_plan";
    }
    if (!graphicsPlanOk) {
        recordGraphicsLaunchFailure(-5, "plan", graphicsError.empty() ? "invalid_graphics_plan" : graphicsError);
        g_mcStatus = std::string("图形计划拒绝: ") + graphicsError;
        AMCL_LOG_E(LOG_TAG, "graphics_plan_rejected reason=%{public}s", graphicsError.c_str());
        g_mcRunning = false;
        return -5;
    }
    if (!graphicsWire.empty() && !legacyBackend.empty()) {
        const std::string legacyId = legacyBackend == "system-opengl" ? "nativegl" : legacyBackend;
        const auto* compatibilityProfile = amcl::graphics::FindGraphicsProfile(legacyId.c_str());
        if (!compatibilityProfile || compatibilityProfile->nativeRoute != graphicsPlan.route) {
            recordGraphicsLaunchFailure(-5, "plan", "legacy_marker_conflict", graphicsPlan.profile);
            g_mcStatus = "图形计划与兼容后端标记冲突";
            AMCL_LOG_E(LOG_TAG, "graphics_plan_rejected reason=legacy_marker_conflict");
            g_mcRunning = false;
            return -5;
        }
    }
    if (!amcl::graphics::ActivateGraphicsPlan(graphicsPlan, graphicsError)) {
        recordGraphicsLaunchFailure(-5, "activation", graphicsError, graphicsPlan.profile);
        g_mcStatus = std::string("图形计划无法激活: ") + graphicsError;
        AMCL_LOG_E(LOG_TAG, "graphics_plan_rejected reason=%{public}s", graphicsError.c_str());
        if (graphicsError == "graphics_profile_change_requires_process_restart") {
            markRendererProcessTainted(graphicsError.c_str());
        }
        g_mcRunning = false;
        return -5;
    }
    // 系统EGL能力由AppScope启动环境提供；UI或入口查询早已可能锁存其提供者。
    // 本局只发布游戏profile，不能再写NEED_OPENGL制造“驱动仍可动态切换”的假象。
    setenv("AMCL_NATIVE_GL_ACTIVE", graphicsPlan.profile == "nativegl" ? "1" : "0", 1);
    if (amclVulkanSetAdmission(0, graphicsPlan.profile.c_str(), graphicsPlan.requirement.c_str()) != 1) {
        recordGraphicsLaunchFailure(-5, "admission", "previous_vulkan_surface_live", graphicsPlan.profile, true);
        g_mcStatus = "Vulkan 窗口仍被上一会话持有，需要重启进程";
        markRendererProcessTainted("previous Vulkan surface remains live");
        g_mcRunning = false;
        return -5;
    }
    // Native Vulkan is admitted only after the immutable plan has been parsed
    // and the device capability probe has returned a positive result.  The
    // derived grant is consumed by the GLFW WSI adapter; a forged JVM marker
    // therefore cannot enable Vulkan by itself.
    const auto* admittedProfile = amcl::graphics::FindGraphicsProfile(graphicsPlan.profile.c_str());
    // 真机验证父进程等待旧 PID/锁退出的协议；只有显式短期沙箱票据可触发，且只能一次。
    if (amcl::graphics::ConsumeGraphicsAdmissionFault(filesDir, graphicsPlan.profile,
            static_cast<long long>(std::time(nullptr)), (AMCL_DIAGNOSTICS_MASK & 1u) != 0)) {
        recordGraphicsLaunchFailure(-5, "admission", "vulkan_capability_rejected", graphicsPlan.profile);
        g_graphicsLaunchFailure.diagnosticInjected = true;
        AMCL_LOG_W(LOG_TAG, "graphics_fault_injected stage=admission profile=%{public}s pid=%{public}d", graphicsPlan.profile.c_str(), getpid());
        g_mcStatus = "诊断：已消费一次性图形准入故障";
        g_mcRunning = false;
        return -5;
    }
    if (admittedProfile && std::strcmp(admittedProfile->capabilityKind, "native-gl") == 0) {
        const amcl::desktop::NativeGlCapability nativeGl = amcl::desktop::QueryNativeGlCapability();
        if (!nativeGl.ready) {
            // 失败资源由探针状态继续持有；将重启边界交给现有隔离进程恢复，不能原地再试。
            if (nativeGl.restartRequired) markRendererProcessTainted("native GL probe retirement or inherited driver");
            recordGraphicsLaunchFailure(-5, "admission", "native_gl_" + nativeGl.stage, graphicsPlan.profile, nativeGl.restartRequired);
            const std::string detail = amcl::desktop::NativeGlFailureDetail(nativeGl);
            AMCL_LOG_E(LOG_TAG, "native_gl_admission_failed bootstrap=%{public}d stage=%{public}s domain=%{public}s error=0x%{public}X cleanup=%{public}d cleanupStage=%{public}s cleanupError=0x%{public}X restart=%{public}d",
                nativeGl.bootstrapConfigured ? 1 : 0, nativeGl.stage.c_str(), nativeGl.errorDomain.c_str(),
                static_cast<unsigned>(nativeGl.error), nativeGl.cleanupComplete ? 1 : 0, nativeGl.cleanupStage.c_str(),
                static_cast<unsigned>(nativeGl.cleanupError), nativeGl.restartRequired ? 1 : 0);
            g_mcStatus = "原生 OpenGL 未通过设备准入: " + detail;
            g_mcRunning = false;
            return -5;
        }
    }
    if (admittedProfile && std::strcmp(admittedProfile->capabilityKind, "vulkan") == 0) {
        const amcl::graphics::GraphicsCapability capability = amcl::graphics::ProbeGraphicsCapability(
            graphicsPlan.profile, graphicsPlan.requirement, graphicsPlan.window, hapNativeDir);
        std::string grantError;
        const bool prerequisites = amcl::graphics::ValidateGraphicsCapability(graphicsPlan, capability, grantError);
        const bool nativeVulkan = graphicsPlan.api == "VULKAN";
        const bool granted = prerequisites && (!nativeVulkan ||
            (amcl::graphics::GrantNativeVulkan(graphicsPlan, capability, grantError) &&
                amclVulkanSetAdmission(1, graphicsPlan.profile.c_str(), graphicsPlan.requirement.c_str()) == 1));
        if (!granted) {
            recordGraphicsLaunchFailure(-5, "admission", "vulkan_capability_rejected", graphicsPlan.profile);
            if (grantError.empty()) grantError = "Vulkan WSI admission rejected";
            g_mcStatus = std::string("Vulkan 图形能力未通过准入: ") + grantError;
            AMCL_LOG_E(LOG_TAG, "graphics_plan_rejected reason=native_vulkan_not_admitted detail=%{public}s",
                       grantError.c_str());
            g_mcRunning = false;
            return -5;
        }
        if (nativeVulkan) setenv("SDL_VULKAN_LIBRARY", "libamcl_vulkan_wsi.so", 1);
        else unsetenv("SDL_VULKAN_LIBRARY");
        AMCL_LOG_I(LOG_TAG, "graphics_plan_capability_admitted profile=%{public}s api=%{public}s requirement=%{public}s native_files=%{public}s window_generation=%{public}llu",
            graphicsPlan.profile.c_str(), graphicsPlan.api.c_str(), graphicsPlan.requirement.c_str(), hapNativeDir.c_str(),
            static_cast<unsigned long long>(capability.nativeWindowGeneration));
    } else {
        amclVulkanSetAdmission(0, graphicsPlan.profile.c_str(), graphicsPlan.requirement.c_str());
        unsetenv("SDL_VULKAN_LIBRARY");
    }
    AMCL_LOG_I(LOG_TAG, "graphics_plan_selected version=%{public}s profile=%{public}s api=%{public}s route=%{public}s window=%{public}s declared_transport=%{public}s actual_provider=%{public}s actual_vulkan=%{public}s strict=%{public}d",
               graphicsPlan.version.c_str(), graphicsPlan.profile.c_str(), graphicsPlan.api.c_str(),
               graphicsPlan.route.c_str(), graphicsPlan.window.c_str(), graphicsPlan.transport.c_str(),
               graphicsPlan.actualProvider.c_str(), graphicsPlan.actualVulkan.c_str(), graphicsPlan.strict ? 1 : 0);

    // MC 26.3+ 的 RenderPearl 会在每次 submit 后等待两次提交以前的 owner fence。
    // caller 级真机证据已确认阻塞集中在该 global submit backpressure；不改变 fence/timeout，
    // 而是在共用的 MobileGlues present 边界限制下一帧到达速度。ArkTS 只为目标 SDL3 路线
    // 注入 marker；用户可用同 key 的自定义 JVM 参数设为 0 或 30..240。这里必须在任何
    // GLFW/SDL/MobileGlues 初始化前转成环境变量，且每次启动都显式写 0，避免进程内重启残留。
    {
        static constexpr char kPacingPrefix[] = "-Damcl.mg.framePacingFps=";
        // The structured plan is the decision source. The legacy marker was
        // already validated above and is not consulted for routing here.
        const std::string requestedBackend = graphicsPlan.profile;
        int framePacingFps = 0;

        for (const auto& arg : extraJvmArgs) {
            if (arg.compare(0, sizeof(kPacingPrefix) - 1, kPacingPrefix) != 0) continue;

            const std::string value = arg.substr(sizeof(kPacingPrefix) - 1);
            int parsed = 0;
            bool valid = !value.empty();
            for (char digit : value) {
                if (digit < '0' || digit > '9') {
                    valid = false;
                    break;
                }
                parsed = parsed * 10 + (digit - '0');
                if (parsed > 240) {
                    valid = false;
                    break;
                }
            }
            if (valid && (parsed == 0 || parsed >= 30)) {
                framePacingFps = parsed;
            } else {
                framePacingFps = 0;
                AMCL_LOG_W(LOG_TAG, "invalid MobileGlues frame pacing value '%{public}s'; disabling pacing",
                           value.c_str());
            }
        }

        const bool nativeGl = requestedBackend == "nativegl";
        // Desktop builds may select Minecraft's native Vulkan profile as a
        // peer of SystemOpenGL; the immutable graphics plan and capability
        // admission above decide which route is valid.

        // System desktop GL has no MobileGlues policy. Keep mobile-specific
        // environment writes and diagnostics out of the native launch path.
        if (!nativeGl) {
            // frame pacing 只对**默认后端**（MobileGlues）有意义：`AMCL_MG_FRAME_PACING_FPS`
            // 由 MobileGlues 的 present 边界读取。gl4es 只借用 libglfw 的窗口/EGL，
            // zink 走 OSMesa 自己上屏 —— 两者都不经那个边界。
            //
            // ⚠️ 判据从 `requestedBackend == "gl4es"` 改成"不是默认后端"，这是**扩大**了置零范围
            // （原先 zink 会拿到非零值）。语义上更正确：zink 从不读这个 env，所以旧行为无害但没意义。
            // 📌 现实影响为零：zink 在本构建里 fail closed（见上方 availableInThisBuild），
            // 且即将在施工记录 §S6 完全退役。⇒ 这不是"顺手改语义"，是把一个已经无效的特例
            // 换成表驱动判据，避免加第四个后端时再补一个 `|| == "xxx"`。
            if (!requestedBackend.empty() && requestedBackend != amcl::renderer::kDefaultBackendId) {
                framePacingFps = 0;
            }
            const std::string pacingValue = std::to_string(framePacingFps);
            setenv("AMCL_MG_FRAME_PACING_FPS", pacingValue.c_str(), 1);
            AMCL_LOG_I(LOG_TAG, "MobileGlues frame pacing = %{public}d FPS (backend=%{public}s)",
                       framePacingFps,
                       requestedBackend.empty() ? "default/mobileglues" : requestedBackend.c_str());

            // MobileGL 的后端选择：它在自己初始化时读 MOBILEGL_BACKEND_TYPE 一次并闭锁
            // （一进程一后端，上游 ConfigLoader 的契约）。必须在 JVM/LWJGL 加载它之前写好。
            // 只在路由到 mobilegl 时写 —— 其它路线不加载该库，残留值无读者
            // （同款后端专属胶水的先例：上方 gl4es 的 LIBGL_GLES）。
            // DirectVulkan 是本仓引入它的全部理由（方案 §1.3：唯一不经 Maleoon GLES 驱动的路径）；
            // DirectGLES 只作为 Phase 3 归因实验的对照臂，届时经验证包单独表达。
            if (requestedBackend == "mobilegl") {
                setenv("MOBILEGL_BACKEND_TYPE", "DirectVulkan", 1);
                AMCL_LOG_I(LOG_TAG, "MobileGL backend type -> DirectVulkan (latched by its first EGL call)");
            }

            // A/B switch for MG's twelfth commit (ARB indirect-draw advertisement).
            // Same transport discipline as pacing: user expresses intent as a JVM
            // marker, this is the single env writer, and the value is written
            // explicitly on every launch so an in-process relaunch cannot inherit
            // a stale choice. MG echoes the effective value as [MG-INDIRECT-DRAW].
            static constexpr char kIndirectPrefix[] = "-Damcl.mg.exposeIndirectDraw=";
            const char* exposeIndirect = "1";
            for (const auto& arg : extraJvmArgs) {
                if (arg.compare(0, sizeof(kIndirectPrefix) - 1, kIndirectPrefix) != 0) continue;
                if (arg.substr(sizeof(kIndirectPrefix) - 1) == "0") exposeIndirect = "0";
            }
            setenv("AMCL_MG_EXPOSE_INDIRECT_DRAW", exposeIndirect, 1);
            AMCL_LOG_I(LOG_TAG, "MobileGlues indirect-draw advertisement = %{public}s", exposeIndirect);

            // A/B switch for MG's thirteenth/fourteenth commits (conditional
            // GL_ARB_base_instance advertisement + translation, the second half of
            // RenderPearl's indirect trio). Three states: "0" off, "1"/default auto
            // (extension-string gated), "force" trusts the resolved EXT symbols even
            // when the driver omits the string (Maleoon does exactly that) -- a
            // controlled experiment whose risk the user opts into explicitly. Same
            // transport discipline as above. MG prints the probe verdict as
            // [MG-BASE-INSTANCE] in every configuration.
            static constexpr char kBaseInstancePrefix[] = "-Damcl.mg.exposeBaseInstance=";
            const char* exposeBaseInstance = "1";
            for (const auto& arg : extraJvmArgs) {
                if (arg.compare(0, sizeof(kBaseInstancePrefix) - 1, kBaseInstancePrefix) != 0) continue;
                const std::string value = arg.substr(sizeof(kBaseInstancePrefix) - 1);
                if (value == "0") {
                    exposeBaseInstance = "0";
                } else if (value == "1") {
                    exposeBaseInstance = "1";
                } else if (value == "force") {
                    exposeBaseInstance = "force";
                } else {
                    AMCL_LOG_W(LOG_TAG,
                               "invalid MobileGlues base-instance value '%{public}s'; using default",
                               value.c_str());
                }
            }
            setenv("AMCL_MG_EXPOSE_BASE_INSTANCE", exposeBaseInstance, 1);
            AMCL_LOG_I(LOG_TAG, "MobileGlues base-instance advertisement = %{public}s", exposeBaseInstance);
        }

        // /proc/net/if_inet6 垫片的 kill switch（方案 §四·五 R1.7）。
        //
        // ⚠️ 为什么要有这一段：R1.7 原本只把开关定成环境变量 AMCL_JDK_IF_INET6_SHIM，
        // 而那个变量在真机上**按不到** —— 应用进程不继承 hdc shell 的环境；`hdc shell`
        // 写不进应用沙箱；`hdc file send` 只能覆盖已存在的文件、新建照样 permission denied
        //（三条都在 2026-08-29 实测过）。⇒ 那是一个"声明了却关不掉"的 kill switch，
        // 比没有更糟：出事时会照文档去关，关不掉还不知道为什么。
        //
        // 这里把它接到与 R2 偏好护栏同一条**已验证的用户通道**上：「自定义 JVM 参数」。
        // 传输纪律与上面 MG 那批逐字一致：JVM marker 表达意图，这里是进程内唯一的 env 写入者，
        // 每次启动都显式写值（默认 "1"），进程内重启不可能继承上一次的选择。
        static constexpr char kIfInet6ShimPrefix[] = "-Damcl.jdk.ifInet6Shim=";
        const char* ifInet6Shim = "1";
        for (const auto& arg : extraJvmArgs) {
            if (arg.compare(0, sizeof(kIfInet6ShimPrefix) - 1, kIfInet6ShimPrefix) != 0) continue;
            const std::string value = arg.substr(sizeof(kIfInet6ShimPrefix) - 1);
            if (value == "0") {
                ifInet6Shim = "0";
            } else if (value == "1") {
                ifInet6Shim = "1";
            } else {
                AMCL_LOG_W(LOG_TAG,
                           "invalid if_inet6 shim value '%{public}s'; using default (on)",
                           value.c_str());
            }
        }
        setenv("AMCL_JDK_IF_INET6_SHIM", ifInet6Shim, 1);
        AMCL_LOG_I(LOG_TAG, "JDK /proc/net/if_inet6 shim = %{public}s", ifInet6Shim);

        // 渲染分辨率缩放（GPU-bound 的最大杠杆，契约见 platform/render_scale.h）。
        // 传输纪律同 pacing：用户以 JVM marker 表达，这里是唯一 env 写入者，每次启动
        // 都显式写值（无效写 "1"），进程内重启不可能继承上一次的比例。
        static constexpr char kRenderScalePrefix[] = "-Damcl.render.scale=";
        std::string renderScaleText;
        for (const auto& arg : extraJvmArgs) {
            if (arg.compare(0, sizeof(kRenderScalePrefix) - 1, kRenderScalePrefix) != 0) continue;
            renderScaleText = arg.substr(sizeof(kRenderScalePrefix) - 1);
        }
        bool renderScaleValid = false;
        const double renderScale =
            amcl::renderscale::ParseScale(renderScaleText.c_str(), &renderScaleValid);
        if (!renderScaleText.empty() && !renderScaleValid) {
            AMCL_LOG_W(LOG_TAG,
                       "invalid render scale '%{public}s' (domain [0.5, 1.0)); using 1.0",
                       renderScaleText.c_str());
        }
        if (renderScaleValid) {
            // 写规范化小数而不是用户原文：env 的下游（xcomponent）用同一 ParseScale
            // 再读一次，"0.7500" 与 "0.75" 解析等值，规范化只为日志/诊断可读。
            char scaleBuf[16];
            snprintf(scaleBuf, sizeof(scaleBuf), "%.4f", renderScale);
            setenv("AMCL_RENDER_SCALE", scaleBuf, 1);
        } else {
            setenv("AMCL_RENDER_SCALE", "1", 1);
        }
        AMCL_LOG_I(LOG_TAG, "render scale = %{public}.4f (requested='%{public}s')",
                   renderScale, renderScaleText.empty() ? "<default>" : renderScaleText.c_str());
        // 启动时机补偿：本页面的 surface 在 startMC 之前就已创建并按 real 尺寸发布，
        // env 写完必须对存活 surface 重放一次几何+发布（同一 JS/UI 线程序列，见头注释）。
        amclRenderScaleReapplyForLaunch();
    }

    // SDL_EGL_LoadLibraryOnly owns separate GL and EGL handles. Point both at
    // the same libglfw.so that backs LWJGL's GL FunctionProvider; this is what
    // makes MC 26.3's strict SDL_GL_GetProcAddress address comparison pass.
    // Environment hints must exist before JVM/LWJGL/SDL class initialization.
    //
    // 判据是 ArkTS 按 version.json 注入的 -Damcl.sdl3=1 marker（见 LaunchProfileBuilder
    // 的 usesSdl3 一段），不是 classpath 里有没有 lwjgl-sdl.jar —— 后者对 1.19+ 恒真。
    // 新路径只消费已校验的计划；旧 SDL marker 在计划激活前校验一致性。
    {
        const bool usesSdl3 = graphicsPlan.window == "SDL3";
        static constexpr char kSdlAuxiliaryWindowPrefix[] =
            "-Damcl.sdl.auxiliaryWindows=";
        std::string requestedAuxiliaryWindowMode;
        for (const auto& a : extraJvmArgs) {
            if (a.compare(0, sizeof(kSdlAuxiliaryWindowPrefix) - 1,
                          kSdlAuxiliaryWindowPrefix) == 0) {
                // Last marker wins. LaunchProfileBuilder's normal merge emits
                // exactly one, but this keeps the legacy C entry point's JVM
                // duplicate-key semantics deterministic too.
                requestedAuxiliaryWindowMode =
                    a.substr(sizeof(kSdlAuxiliaryWindowPrefix) - 1);
            }
        }

        // MobileGL 可由 GLFW 或 SDL 消费；provider 已由锁存计划和能力证据确认。
        // GLFW 自身取得同源 GL/EGL 表；只有 SDL 路线需要下方的 SDL 库环境。

        const bool validAuxiliaryWindowMode =
            requestedAuxiliaryWindowMode.empty() ||
            requestedAuxiliaryWindowMode == "off" ||
            requestedAuxiliaryWindowMode == "pbuffer";
        if (!validAuxiliaryWindowMode) {
            AMCL_LOG_W(LOG_TAG,
                       "invalid SDL3 auxiliary window mode '%{public}s'; using off",
                       requestedAuxiliaryWindowMode.c_str());
        }
        const char* effectiveAuxiliaryWindowMode =
            // 支持度取自 canonical profile；有效字符串不能绕过 API/宿主能力声明。
            usesSdl3 && graphicsPlan.api == "OPENGL" && admittedProfile &&
                    amcl::graphics::GraphicsProfileStringEqual(admittedProfile->sdlAuxiliaryWindow, "supported") &&
                    validAuxiliaryWindowMode &&
                    requestedAuxiliaryWindowMode == "pbuffer"
                ? "pbuffer"
                : "off";

        // JVM/SDL 初始化前显式发布本次模式；独立游戏进程也可能继承环境，不能把父进程
        // 留下的 pbuffer 模式当成本次选择。发布失败时计划已锁存，后续必须新进程启动。
        if (setenv("SDL_OPENHARMONY_AUXILIARY_WINDOW_MODE",
                   effectiveAuxiliaryWindowMode, 1) != 0) {
            AMCL_LOG_E(LOG_TAG,
                       "failed to set SDL3 auxiliary window mode errno=%{public}d",
                       errno);
            g_mcStatus = "SDL3 辅助窗口模式配置失败";
            recordGraphicsLaunchFailure(-1, "bootstrap", "sdl_environment_set_failed", graphicsPlan.profile);
            g_mcRunning = false;
            return -1;
        }
        const char* actualAuxiliaryWindowMode =
            getenv("SDL_OPENHARMONY_AUXILIARY_WINDOW_MODE");
        if (!actualAuxiliaryWindowMode ||
            strcmp(actualAuxiliaryWindowMode, effectiveAuxiliaryWindowMode) != 0) {
            AMCL_LOG_E(LOG_TAG,
                       "SDL3 auxiliary window mode verification failed requested=%{public}s actual=%{public}s",
                       effectiveAuxiliaryWindowMode,
                       actualAuxiliaryWindowMode ? actualAuxiliaryWindowMode : "<unset>");
            g_mcStatus = "SDL3 辅助窗口模式校验失败";
            recordGraphicsLaunchFailure(-1, "bootstrap", "sdl_environment_verify_failed", graphicsPlan.profile);
            g_mcRunning = false;
            return -1;
        }
        AMCL_LOG_I(LOG_TAG,
                   "SDL3 auxiliary window mode = %{public}s (marker=%{public}s route=%{public}s)",
                   actualAuxiliaryWindowMode,
                   requestedAuxiliaryWindowMode.empty()
                       ? "<unset>" : requestedAuxiliaryWindowMode.c_str(),
                   usesSdl3 ? "sdl3" : "glfw");

        if (usesSdl3 && graphicsPlan.api == "OPENGL") {
            // G9（治理规范 §11，2026-08-28 关闭）：SDL 的 GL/EGL 提供者 = 当前后端的
            // glLibName，查 renderer_backend_ids.h 的同一张镜像表 —— 此前硬编码
            // libglfw.so，是一个绕过注册表的决策消费点（mobilegl 一来就漂移）。
            // MobileGlues 的 GL 库现在是独立 libamcl_gl_host.so；本路径的环境与 GLFW
            // 冻结绑定使用同一注册表记录。未知/缺件 id 拒绝，与 phase_setProperties
            // 的路由处置一致（那边还会打身份行与告警，这里不重复）。
            const std::string sdlBackendId = graphicsPlan.profile;
            const amcl::renderer::BackendGlLibrary* sdlBackend =
                amcl::renderer::FindBackendGlLibrary(sdlBackendId);
            if (sdlBackend == nullptr || !sdlBackend->availableInThisBuild) {
                recordGraphicsLaunchFailure(-5, "artifacts", "sdl_gl_provider_missing", graphicsPlan.profile);
                g_mcStatus = "SDL 图形计划缺少指定的 GL provider";
                g_mcRunning = false;
                return -5;
            }
            const std::string glProviderPath = sdlBackend->systemLibrary ? sdlBackend->glLibName : hapNativeDir + "/" + sdlBackend->glLibName;
            setenv("SDL_OPENGL_LIBRARY", glProviderPath.c_str(), 1);
            setenv("SDL_EGL_LIBRARY", sdlBackend->systemLibrary ? "libEGL.so" : glProviderPath.c_str(), 1);
            AMCL_LOG_I(LOG_TAG, "SDL3 GL/EGL library hints -> %{public}s (backend=%{public}s)",
                       glProviderPath.c_str(), sdlBackend->id);

            // Keep the default framebuffer linear, i.e. do exactly what the
            // GLFW-era path does.
            //
            // MC requests SDL_GL_FRAMEBUFFER_SRGB_CAPABLE=1. On desktop GL that
            // only asks for the *capability*: the linear->sRGB encode happens
            // solely while the app has GL_FRAMEBUFFER_SRGB enabled, and MC drives
            // that itself. GLES has no such switch, and SDL honours the request by
            // creating the window surface with EGL_GL_COLORSPACE_SRGB_KHR
            // (SDL_egl.c, SDL_EGL_CreateSurface) -- so the driver encodes on
            // *every* write to the default framebuffer, unconditionally.
            //
            // MC's output is already display-referred, so that extra encode is a
            // second gamma pass: mid-tones lift, blacks turn grey, whites stay
            // white. 2026-08-04 device evidence: the Mojang splash came up pale
            // pink instead of red and the main menu looked like a white sheet was
            // laid over it, while the same device on the GLFW path (<=26.2) was
            // correct -- and that path passes no colorspace attribute at all
            // (glfw_egl.cpp: eglCreateWindowSurface(..., nullptr)).
            //
            // "skip" means "do not specify the attribute", which is precisely the
            // GLFW path's behaviour -- not a claim that sRGB is unsupported.
            // Set via env because env wins over any SDL_SetHint() the app makes
            // at SDL_HINT_NORMAL priority.
            if (sdlBackend->systemLibrary) unsetenv("SDL_OPENGL_FORCE_SRGB_FRAMEBUFFER");
            else setenv("SDL_OPENGL_FORCE_SRGB_FRAMEBUFFER", "skip", 1);
            AMCL_LOG_I(LOG_TAG, "SDL3 sRGB framebuffer request -> skip "
                                "(GLES converts unconditionally; MC output is already display-referred)");
        } else {
            unsetenv("SDL_OPENGL_LIBRARY");
            unsetenv("SDL_EGL_LIBRARY");
            unsetenv("SDL_OPENGL_FORCE_SRGB_FRAMEBUFFER");
            // 显式记一笔：≤26.2 走 GLFW 路径，不设 SDL hint、不做 SDL 准备、
            // 也不会为 SDL 提前初始化渲染 provider（由 LWJGL 的 glfwInit 按产品路径触发）。
            AMCL_LOG_I(LOG_TAG, "SDL3 path not requested by version manifest — GLFW path unchanged");
        }
    }

    // 内存感知硬上限：防止用户把滑块拉到远超可用内存（如 8192MB），否则 G1 会把堆
    // 撑向该上限、涨进大量 swap → GC 扫堆读 swap 页 → 渲染线程长停顿 → AppFreeze
    // 看门狗杀进程（实测 Xmx=8192 在 ~6G 可用设备 worldgen 冻结的根因）。
    {
        int hardCeil = computeXmxHardCeilMB();
        if (hardCeil > 0 && xmx > hardCeil) {
            AMCL_LOG_I(LOG_TAG, "Xmx %{public}d MB capped to %{public}d MB by available memory", xmx, hardCeil);
            xmx = hardCeil;
        }
    }

    // ============================================================
    //  虚拟内存（堆文件）模式：ArkTS 在低内存设备/重型整合包场景下注入
    //  marker `-Damcl.heapfile=1`。开启后把 Java 堆分配到沙箱存储文件上
    //  （-XX:AllocateHeapAt，JEP 316），使堆内存「文件背书、可被系统回收」，
    //  避免 worldgen 内存峰值被 lowmemkiller SIGKILL；代价是存储分页带来的卡顿。
    // ============================================================
    std::vector<std::string> finalJvmArgs;
    finalJvmArgs.reserve(extraJvmArgs.size() + 1);
    bool heapFileMode = false;
    std::string gameLang;  // -Damcl.gamelang=<code> marker → 写进 options.txt 的 lang（不下传 JVM）
    for (const auto& a : extraJvmArgs) {
        if (a == "-Damcl.heapfile=1") { heapFileMode = true; continue; } // marker 本身不下传 JVM
        if (a.compare(0, sizeof("-Damcl.graphics.plan=") - 1, "-Damcl.graphics.plan=") == 0) continue;
        // 保留所有 owned -D 参数交给唯一 Freeze 校验：提前丢弃会掩盖异值冲突。
        if (a.compare(0, 16, "-Damcl.gamelang=") == 0) { gameLang = a.substr(16); continue; }
        finalJvmArgs.push_back(a);
    }
    if (heapFileMode) {
        int totalMB = getDeviceTotalMemoryMB();
        // 堆文件模式不受当前可用内存约束：直接采用「设备想要」的堆（总内存基准）。
        int desired = computeDesiredXmxNoAvailCap(totalMB);
        if (xmxMb > 0 && xmxMb > desired) desired = (xmxMb / 256) * 256; // 用户手动设更大也尊重
        std::string heapDir = prepareHeapFileDir(filesDir);
        long freeMB = getFreeDiskMB(heapDir);
        // 安全闸：堆文件大小约等于 Xmx，要求磁盘至少有 Xmx + 1GB 余量，否则回退普通模式。
        if (freeMB >= 0 && freeMB < (long)desired + 1024) {
            AMCL_LOG_W(LOG_TAG, "heapfile mode: insufficient disk (free=%{public}ld MB < need=%{public}d MB), fallback to RAM heap",
                       freeMB, desired + 1024);
            heapFileMode = false;
        } else {
            xmx = desired;
            finalJvmArgs.push_back("-XX:AllocateHeapAt=" + heapDir);
            AMCL_LOG_I(LOG_TAG, "heapfile mode ON: AllocateHeapAt=%{public}s Xmx=%{public}d MB freeDisk=%{public}ld MB",
                       heapDir.c_str(), xmx, freeMB);
        }
    }

    // Native Vulkan can legitimately pass loader/device creation and still
    // stall in the post-device Java/VMA/command-encoder boundary before a
    // window exists.  The default product already carries diagnostics, so
    // enable a bounded Java stack sampler for this route.  It emits five
    // snapshots at 8-second intervals and then stops; it is deliberately not
    // enabled for OpenGL or for the desktop product.
    if (graphicsPlan.api == "VULKAN" && (AMCL_DIAGNOSTICS_MASK & 1)) {
        finalJvmArgs.push_back("-Damcl.watchdog=true");
        finalJvmArgs.push_back("-Damcl.vulkan.startupWatchdog=true");
        AMCL_LOG_I(LOG_TAG, "vulkan_startup_watchdog=bounded interval=8s rounds=5");
    }

    // ============================================================
    //  GC：保持 SSOT 的 SerialGC（不路由 G1）。
    //  实测结论（ATM8 / 真机 1000250-1000252）：本设备上 G1 反而更差——
    //   · G1 每堆约 10-15% 元数据开销（remembered set / mark bitmap）→ 同样 3840MB
    //     下「可用堆」比 SerialGC 少 → 在 ModelBakery 模型烘焙阶段 Java 堆 OOM
    //     （SerialGC 同样 3840MB 能过模型烘焙、到主菜单）。
    //   · Xmx 放大到 8192 让 G1 把堆撑进 swap → 渲染线程 GC 停顿被 AppFreeze 冻结杀。
    //  故重型整合包加载阶段是「Java 堆受限」，SerialGC 的"每 MB 可用堆更多"更关键。
    //  仍保留内存感知 Xmx 硬上限（computeXmxHardCeilMB）防止滑块拉太高撑爆 swap。
    // ============================================================
    // 2026-08-06：这行日志此前写「SerialGC (SSOT)」，而 SSOT 早已换成 ParallelGC
    //   （jvm_common_args.cpp 的 -XX:+UseParallelGC）。上面那段注释同样是 SerialGC 时代
    //   留下的，其中「重型整合包按堆大小路由 G1」在代码里**并不存在** —— 全仓 grep
    //   UseG1GC / SoftMaxHeapSize 只命中注释与 CHANGELOG。日志说谎比没有日志更糟，
    //   所以改成不点名收集器，只报事实：收集器由 SSOT 决定，可被启动方/用户覆盖。
    AMCL_LOG_I(LOG_TAG, "GC: from SSOT (see jvm_common_args.cpp; overridable) Xmx=%{public}d MB", xmx);

    // 设置 AMCL_GAME_DIR 环境变量，供 jvmInit 中设置 user.dir/user.home
    setenv("AMCL_GAME_DIR", gameDirStr.c_str(), 1);

    AMCL_LOG_I(LOG_TAG, "=== MC Launch (profile): main=%s Xmx=%dMB mcArgs=%zu jvmArgs=%zu heapfile=%d ===",
               mainClass, xmx, mcArgs.size(), finalJvmArgs.size(), heapFileMode ? 1 : 0);

    // 冻结所有 profile 的早读运行库属性，而非只有 nativegl。必须先于 JNI_CreateJavaVM
    // （包括 agent premain），不能在 Configuration 初始化之后再 setProperty 补救。
    // nativegl 也由同一冻结函数校验；不能先用旧 helper 擦掉异值来制造“没有冲突”。
    const auto* runtimeBackend = amcl::renderer::FindBackendGlLibrary(graphicsPlan.profile);
    const bool nativeVulkanPlan = graphicsPlan.api == "VULKAN";
    if (!nativeVulkanPlan && (!runtimeBackend || !runtimeBackend->availableInThisBuild)) {
        recordGraphicsLaunchFailure(-5, "artifacts", "gl_provider_missing", graphicsPlan.profile);
        g_mcStatus = "图形计划缺少已编入的 GL provider";
        g_mcRunning = false;
        return -5;
    }
    const char* glLibrary = nativeVulkanPlan ? "libglfw.so" : runtimeBackend->glLibName;
    if (!nativeVulkanPlan && !runtimeBackend->systemLibrary &&
        !fileExists((hapNativeDir + "/" + glLibrary).c_str())) {
        recordGraphicsLaunchFailure(-5, "artifacts", "gl_library_missing", graphicsPlan.profile);
        g_mcStatus = "指定的 GL 运行库不存在: " + std::string(glLibrary);
        g_mcRunning = false;
        return -5;
    }
    g_runtimeBootstrapProperties = amcl::jvm::RuntimeBootstrapProperties(
        hapNativeDir, gameDirStr, graphicsPlan.profile,
        nativeVulkanPlan ? glLibrary : "libamcl_graphics_runtime.so", graphicsPlan.window == "SDL3");
    std::string bootstrapError;
    if (!amcl::jvm::FreezeBootstrapProperties(finalJvmArgs, g_runtimeBootstrapProperties, bootstrapError)) {
        recordGraphicsLaunchFailure(-5, "bootstrap", "runtime_property_conflict", graphicsPlan.profile);
        g_mcStatus = "运行库启动契约冲突: " + bootstrapError;
        AMCL_LOG_E(LOG_TAG, "runtime_bootstrap_rejected reason=%{public}s", bootstrapError.c_str());
        g_mcRunning = false;
        return -5;
    }
    if (graphicsPlan.profile == "gl4es") {
        setenv("LIBGL_GLES", "libGLESv3.so", 1);
        setenv("LIBGL_NOBANNER", "0", 1);
    }
    // 所有 provider 环境已经发布、能力准入已通过，现在在 JVM 之前冻结唯一函数表。
    // SDL 与 GLFW 共用这份身份；第三方库后续改写环境不会改变宿主的资源销毁提供者。
    char bindingFailure[256] = {};
    if (amclGraphicsBindRuntimeV1(graphicsPlan.profile.c_str(), graphicsPlan.api.c_str(),
            bindingFailure, sizeof(bindingFailure)) != 1) {
        recordGraphicsLaunchFailure(-5, "binding", bindingFailure, graphicsPlan.profile, true);
        g_mcStatus = std::string("图形后端绑定失败: ") + bindingFailure;
        g_mcRunning = false;
        return -5;
    }
    // 从冻结的实际MG映像读取版本身份，不接受用户属性伪装。此属性也要在agent与
    // 系统ClassLoader初始化之前冻结，后续换依赖/dirty修改会自动使旧补丁规则不适用。
    const auto* boundGraphics = amcl::graphics::BoundGraphicsRuntime();
    g_runtimeBootstrapProperties.emplace_back("amcl.graphics.implementation",
        boundGraphics ? boundGraphics->implementationIdentity : "");
    if (!amcl::jvm::FreezeBootstrapProperties(finalJvmArgs, g_runtimeBootstrapProperties, bootstrapError)) {
        recordGraphicsLaunchFailure(-5, "bootstrap", "runtime_property_conflict", graphicsPlan.profile);
        g_mcStatus = "图形实现身份属性冲突: " + bootstrapError; g_mcRunning = false; return -5;
    }
    // 只读取显式诊断属性，不干预游戏的上传/提交/帧率策略。开关在owner发布前冻结，
    // 关闭时仍保留安全恢复所需的首帧与swap失败计数；非法值保留默认并明确报告。
    const char* observationValue = "1";
    const char* observationCostValue = "0";
    for (const auto& arg : finalJvmArgs) {
        const std::string samplePrefix = "-Damcl.graphics.observation=";
        const std::string costPrefix = "-Damcl.graphics.observation.cost=";
        const bool sampling = arg.compare(0, samplePrefix.size(), samplePrefix) == 0;
        const bool costing = arg.compare(0, costPrefix.size(), costPrefix) == 0;
        if (!sampling && !costing) continue;
        const std::string value = arg.substr(sampling ? samplePrefix.size() : costPrefix.size());
        if (value != "0" && value != "1") {
            AMCL_LOG_W(LOG_TAG, "graphics_observer_option_invalid option=%{public}s", sampling ? "sampling" : "cost");
            continue;
        }
        if (sampling) observationValue = value == "0" ? "0" : "1";
        else observationCostValue = value == "0" ? "0" : "1";
    }
    setenv("AMCL_GRAPHICS_OBSERVATION", observationValue, 1);
    setenv("AMCL_GRAPHICS_OBSERVATION_COST", observationCostValue, 1);
    // 观测 owner 在 JVM 和 SDL 装载前发布；失败只丢失增强诊断，不改变图形准入结论。
    if (!amclGraphicsPublishObserverV1()) {
        AMCL_LOG_W(LOG_TAG, "graphics_observer_unavailable");
    }
    AMCL_LOG_I(LOG_TAG, "AMCL_RENDERER backend=%{public}s lib=%{public}s properties=pre-jvm",
        graphicsPlan.profile.c_str(), glLibrary);
    jvmSetExtraArgsList(finalJvmArgs);
    if (!finalJvmArgs.empty()) {
        AMCL_LOG_I(LOG_TAG, "Configured %zu extra JVM args", finalJvmArgs.size());
    }

    // 从 extraJvmArgs 中提取 Forge 指定的 native library 路径，合并到 extraLibPath
    // ArkTS 层将 -Djava.library.path=X 转换为 -Damcl.forge.native.path=X
    std::string forgeNativePath;
    {
        static const char PREFIX[] = "-Damcl.forge.native.path=";
        for (const auto& arg : finalJvmArgs) {
            if (arg.compare(0, sizeof(PREFIX) - 1, PREFIX) == 0) {
                forgeNativePath = arg.substr(sizeof(PREFIX) - 1);
                break;
            }
        }
    }

    // 从 extraJvmArgs 中提取 ArkTS 注入的真实 mcDir（.minecraft 根目录）
    // ArkTS LaunchProfileBuilder 在 build() 末尾追加 -Damcl.mc.dir=<mcDir>
    // 用于 ForgeHelper 区分 mcDir 与 gameDir，正确写入两处 config/
    std::string mcDirStr;
    {
        static const char MC_DIR_PREFIX[] = "-Damcl.mc.dir=";
        for (const auto& arg : finalJvmArgs) {
            if (arg.compare(0, sizeof(MC_DIR_PREFIX) - 1, MC_DIR_PREFIX) == 0) {
                mcDirStr = arg.substr(sizeof(MC_DIR_PREFIX) - 1);
                break;
            }
        }
        if (mcDirStr.empty()) {
            mcDirStr = gameDirStr; // 向后兼容：未注入时回退为 gameDir
        }
    }

    // 强制 fullscreen:false（移动设备始终全屏，MC 的全屏切换会破坏触摸坐标）
    forceOptionsFullscreenOff(gameDirStr);
    // 按启动器选择的游戏语言校正 options.txt 的 lang（全局默认 zh_cn / 单版本可覆盖）。
    applyGameLanguage(gameDirStr, gameLang);
    if (graphicsPlan.api != "VULKAN" && !rejectUnsupportedVulkanPreference(gameDirStr)) {
        recordGraphicsLaunchFailure(-6, "preference", "game_vulkan_preference_conflict", graphicsPlan.profile);
        g_mcStatus = "游戏 Vulkan 偏好与当前 OpenGL 计划冲突；图形偏好保持不变";
        g_mcRunning = false;
        return -6;
    }
    // 强制禁用 Forge EarlyDisplay（避免 setupMinecraftWindow 的 callback .free() NPE）
    forceDisableForgeEarlyWindow(gameDirStr);

    // 构建完整的 native library 搜索路径，在 JVM 初始化前设置
    // 必须包含 hapNativeDir（LWJGL .so 文件所在目录），否则 Forge 的
    // BootstrapLauncher 创建的模块层无法通过 java.library.path 找到原生库。
    // 注意：phase_setProperties 中的 System.setProperty("java.library.path", ...)
    // 只改变属性字符串，不会更新 JVM 内部缓存的原生库搜索路径。
    {
        std::string mergedLibPath = hapNativeDir + ":" + gameDirStr + "/natives";
        if (!forgeNativePath.empty()) {
            mergedLibPath += ":" + forgeNativePath;
        }
        jvmSetExtraLibPath(mergedLibPath.c_str());
        AMCL_LOG_I(LOG_TAG, "Pre-set native lib path: %s", mergedLibPath.c_str());
    }

    // classpath 交付方式（世代契约表的产出，ArkTS 经 -Damcl.classpathDelivery= 下传）。
    //
    // ⚠️ **只能从参数向量里读，不能读系统属性** —— 本段执行时 JVM 还不存在。
    //   与 -Damcl.sdl3 / -Damcl.mc.dir 走同一条既有通道。
    std::string classpathDelivery;
    {
        static const char DELIVERY_PREFIX[] = "-Damcl.classpathDelivery=";
        for (const auto& arg : finalJvmArgs) {
            if (arg.compare(0, sizeof(DELIVERY_PREFIX) - 1, DELIVERY_PREFIX) == 0) {
                classpathDelivery = arg.substr(sizeof(DELIVERY_PREFIX) - 1);
                break;
            }
        }
        if (classpathDelivery.empty()) {
            // 走不到这里：LaunchProfileBuilder 无条件追加该 marker。真出现说明
            // 上游协议破了 ⇒ 告警并 fail-open 到完整 classpath（见 phase_initJvmWithClasspath）。
            AMCL_LOG_W(LOG_TAG,
                       "AMCL_CP_OWNERSHIP delivery marker absent -> falling back to full classpath");
        }
    }

    // Phase 1: INIT_JVM（使用 ArkTS 传入的 classpath 与世代契约的 delivery）
    if (!phase_initJvmWithClasspath(filesDir, gameDirStr, std::string(classpath),
                                     xmx, jdkVersion, classpathDelivery)) {
        g_mcRunning = false;
        return -4;
    }

    // Phase 2-5: 后台线程（通过 AmclLauncher Java 中间层启动）
    g_mcStatus = "正在后台线程启动 MC...";
    if (g_mcThread.joinable()) {
        g_mcThread.join();
    }

    // 检测 Forge/Fabric（用于 AmclLauncher JSON 配置）
    bool isForge = std::string(mainClass).find("forge") != std::string::npos ||
                   std::string(mainClass).find("Forge") != std::string::npos ||
                   std::string(mainClass).find("bootstrap") != std::string::npos ||
                   std::string(mainClass).find("Bootstrap") != std::string::npos;
    bool isFabric = std::string(mainClass).find("fabricmc") != std::string::npos ||
                    std::string(mainClass).find("Knot") != std::string::npos;

    g_mcThread = std::thread(mcLaunchThreadWithProfile, filesDir, gameDirStr, mcDirStr,
                             hapNativeDir, std::string(mainClass),
                             std::string(classpath), mcArgs, isForge, isFabric);
    g_mcThread.detach();

    return 0;
}

extern "C" int mcLaunchWithProfile(const char* appFilesDir, const char* gameDir,
                                   const char* jdkVersion, int xmxMb,
                                   const char* mainClass, const char* classpath,
                                   const char* mcArgsStr,
                                   const char* extraJvmArgs) {
    // 兼容旧协议（逗号分隔）: 主流程将迁移到 mcLaunchWithProfileV2
    std::vector<std::string> mcArgs = splitString(mcArgsStr ? std::string(mcArgsStr) : "", ',');
    std::vector<std::string> extraArgs = splitString(extraJvmArgs ? std::string(extraJvmArgs) : "", ',');
    return launchWithProfileImpl(appFilesDir, gameDir, jdkVersion, xmxMb,
                                 mainClass, classpath, mcArgs, extraArgs);
}

extern "C" int mcLaunchWithProfileV2(const char* appFilesDir, const char* gameDir,
                                     const char* jdkVersion, int xmxMb,
                                     const char* mainClass, const char* classpath,
                                     int mcArgc, const char* const* mcArgv,
                                     int extraJvmArgc, const char* const* extraJvmArgv) {
    std::vector<std::string> mcArgs = toArgVector(mcArgc, mcArgv);
    std::vector<std::string> extraArgs = toArgVector(extraJvmArgc, extraJvmArgv);
    return launchWithProfileImpl(appFilesDir, gameDir, jdkVersion, xmxMb,
                                 mainClass, classpath, mcArgs, extraArgs);
}

extern "C" const char* mcGetStatus() {
    // NAPI 只在 JS 主线程调用本函数；快照放 static，指针在拷入 JS 字符串期间稳定。
    static std::string s_statusSnapshot;
    s_statusSnapshot = g_mcStatus.snapshot();
    return s_statusSnapshot.c_str();
}

extern "C" int mcIsRunning() {
    // JVM 已完成退出记录并进入有限窗口交接时，复用页面既有退出轮询通知 UI。
    // 此处不进入 JVM、不取其停机锁，也不能继续调用渲染器来推断已经终止的 Java 状态。
    if (amclGameExitPendingForCurrentProcess()) return 0;
    if (rendererRestartMarkerPresent()) {
        markRendererProcessTainted("renderer failure observed by status poll");
    }
    if (!g_mcRunning) return 0;
    // 窗口销毁可能早于 System.exit/shutdown hooks，不能凭它抢先 _exit(0)。
    // 授权覆盖 Prepared→记录写盘→Pending 的整个区间；只查 Armed 会在写盘期间出现
    // 空窗。隔离会话只接受上方真实退出请求或主函数已返回，旧页面路线仍消费原 marker。
    if (amclGameExitAuthorizedForCurrentProcess()) return 1;
    struct stat st;
    if (stat(g_markerPath.c_str(), &st) == 0) {
        AMCL_LOG_I(LOG_TAG, "Window destroy marker found! MC has exited.");
        g_mcRunning = false;
        return 0;
    }
    return 1;
}

/**
 * 退出动作的 UI→native 接缝。隔离 JVM 正等待窗口交接时只发送 ACK，由原 hook 按
 * 保存的原始退出码结束进程，不能在这里把非零码改为 0。ACK 只代表 UI 已完成请求，
 * 不冒充已回到前台；有界等待和实际前台仍分别取证。其余路线沿用既有 _exit(0) 兜底。
 */
extern "C" void mcForceExit() {
    // 该函数在 UI/NAPI 普通线程上运行。游戏已结束才收尾异步账本与原始 fd，
    // 不把可能持 JVM 停机锁的退出 hook 变成等待 logger 的地方；用户强制结束仍标为未确认。
    if (amclGameExitPendingForCurrentProcess() || !g_mcRunning.load()) {
        amclLedgerEnd(amclLedgerGetLaunchActivity());
        amcl::sessionlog::finish();
    }
    if (amclGameExitAcknowledgeRequested()) return;
    AMCL_LOG_I(LOG_TAG, "mcForceExit: _exit(0) called");
    _exit(0);
}

// 读取文件最后 N 字节
static std::string readFileTail(const std::string& path, int maxBytes) {
    FILE* f = fopen(path.c_str(), "r");
    if (!f) return "";
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    int readSz = (maxBytes > 0 && maxBytes < sz) ? maxBytes : (int)sz;
    fseek(f, sz - readSz, SEEK_SET);
    std::string buf(readSz, '\0');
    fread(&buf[0], 1, readSz, f);
    fclose(f);
    return buf;
}

// 查找最新的 crash report 文件
static std::string findLatestCrashReport(const std::string& mcDir) {
    std::string crashDir = mcDir + "/crash-reports";
    DIR* d = opendir(crashDir.c_str());
    if (!d) return "";
    std::string latest;
    struct dirent* ent;
    while ((ent = readdir(d)) != nullptr) {
        std::string name(ent->d_name);
        if (name.find("crash-") == 0 && name.find("-client.txt") != std::string::npos) {
            if (name > latest) latest = name;
        }
    }
    closedir(d);
    return latest.empty() ? "" : (crashDir + "/" + latest);
}

/**
 * 解析游戏日志的实际所在目录（日志系统 v3 · S2）。
 *
 * 2026-07-30 修复 P1-3：`mcReadLog` 原来固定读 `<mcDir>/mc_output.log`，
 *   但**版本隔离开启时**真实路径在 `<mcDir>/versions/<版本 ID>/` 下 ——
 *   真机确认 `.minecraft/` 根目录下没有这个文件，于是 McGamePage 的日志面板
 *   与 Index 的「复制日志」拿到的永远是「(日志文件不存在)」。
 *
 * NAPI 签名只给了 mcDir、拿不到 versionId，所以这里按与 ArkTS 侧
 * `commons/GameLogPaths` 一致的策略探测：
 *   1. `<mcDir>/mc_output.log`                —— 非隔离布局
 *   2. `<mcDir>/versions/<*>/mc_output.log`   —— 隔离布局，取 mtime 最新的一个
 * 两者都在时取更新的那个（用户可能中途切过隔离开关）。
 *
 * @return 命中的游戏目录（不含文件名）；都找不到时返回 mcDir
 */
static std::string resolveGameLogDir(const std::string& mcDir) {
    std::string best = mcDir;
    time_t bestMtime = 0;

    struct stat st;
    std::string flat = mcDir + "/mc_output.log";
    if (stat(flat.c_str(), &st) == 0 && st.st_size > 0) {
        bestMtime = st.st_mtime;
    }

    std::string versionsDir = mcDir + "/versions";
    DIR* d = opendir(versionsDir.c_str());
    if (d) {
        struct dirent* ent;
        while ((ent = readdir(d)) != nullptr) {
            std::string name(ent->d_name);
            if (name == "." || name == "..") continue;
            std::string candidate = versionsDir + "/" + name + "/mc_output.log";
            struct stat cs;
            if (stat(candidate.c_str(), &cs) != 0 || cs.st_size <= 0) continue;
            if (cs.st_mtime >= bestMtime) {
                bestMtime = cs.st_mtime;
                best = versionsDir + "/" + name;
            }
        }
        closedir(d);
    }
    return best;
}

// 读取 mc_output.log + crash report
static std::string g_mcLogCache;
extern "C" const char* mcReadLog(const char* mcDir, int maxBytes) {
    // 当前进程已建立会话原件时读取其固定路径；不能跳回旧工作目录再混入上一局崩溃报告。
    if (amcl::sessionlog::owned()) {
        g_mcLogCache = readFileTail(amcl::sessionlog::consolePath(), maxBytes);
        return g_mcLogCache.c_str();
    }
    std::string dir = resolveGameLogDir(std::string(mcDir));
    std::string log = readFileTail(dir + "/mc_output.log", maxBytes);

    // 如果 MC 不在运行，尝试读取 crash report
    if (!g_mcRunning) {
        std::string crashPath = findLatestCrashReport(dir);
        if (!crashPath.empty()) {
            std::string crash = readFileTail(crashPath, maxBytes);
            if (!crash.empty()) {
                log += "\n\n========== CRASH REPORT ==========\n";
                log += crashPath.substr(crashPath.rfind('/') + 1) + "\n\n";
                log += crash;
            }
        }
    }

    if (log.empty()) log = "(日志文件不存在)";
    g_mcLogCache = log;
    return g_mcLogCache.c_str();
}

extern "C" int mcGetDeviceMemoryMB() {
    return getDeviceTotalMemoryMB();
}

extern "C" int mcGetRecommendedXmx() {
    return computeRecommendedXmx();
}
