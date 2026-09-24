/**
 * napi_mc.cpp — Minecraft 启动器 NAPI 实现
 *
 * 行为与重构前 napi_entry.cpp 中同名 static 函数等价。
 * 唯一改动：所有 `napi_value fail; napi_create_int32(env, -1, &fail); return fail;`
 *           （重构前共 10 处复制粘贴）替换为 `return MakeIntResult(env, -1);`
 */
#include "napi_mc.h"
#include "napi_helpers.h"

#include <hilog/log.h>

#include <string>
#include <vector>
#include <chrono>

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <unistd.h>
#include <signal.h>

#include "../jvm/mc_launcher.h"
#include "../jvm/jvm_launcher.h"
#include "../jvm/game_process_exit.h"
#include "../platform/graphics_observation_abi.h"
#include "../platform/runtime_slot_store.h"

#undef LOG_TAG
#define LOG_TAG "NAPI_MC"

namespace {

// OS 锁在进程结束（含崩溃）时释放，锁文件本身永不删除。缓存必须连同取得锁的 PID、
// 逻辑启动器与目录一起核验，不能把 fork 继承来的 fd 当成新游戏进程的隔离证明。
int desktopGameLockFd = -1;
pid_t desktopGameLockOwnerPid = 0;
int32_t desktopGameLauncherPid = 0;
std::string desktopGameLockDirectory;
napi_value DesktopProcessId(napi_env env, napi_callback_info) {
    return amcl::napi::MakeIntResult(env, static_cast<int32_t>(getpid()));
}
napi_value DesktopGameProcessState(napi_env env, napi_callback_info info) {
    size_t count = 2; napi_value args[2]{}; int32_t parent = 0; std::string dir;
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    if (count != 2 || !amcl::napi::ReadStringValue(env, args[0], dir) ||
        dir.empty() || dir[0] != '/' || dir.find('\0') != std::string::npos ||
        napi_get_value_int32(env, args[1], &parent) != napi_ok || parent < 0)
        return amcl::napi::MakeIntResult(env, -1);
    if (parent == getpid()) return amcl::napi::MakeIntResult(env, -2);
    if (desktopGameLockFd >= 0) {
        const bool sameOwner = desktopGameLockOwnerPid == getpid() && dir == desktopGameLockDirectory &&
            (parent == 0 || parent == desktopGameLauncherPid);
        return amcl::napi::MakeIntResult(env, sameOwner ? 1 : -2);
    }
    const int fd = open((dir + "/.desktop-game.lock").c_str(), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return amcl::napi::MakeIntResult(env, -1);
    int rc; do { rc = flock(fd, LOCK_EX | LOCK_NB); } while (rc != 0 && errno == EINTR);
    if (rc != 0) { const int err = errno; close(fd); return amcl::napi::MakeIntResult(env,
        err == EWOULDBLOCK || err == EAGAIN ? (parent ? -3 : 1) : -1); }
    if (parent) {
        // 只有独立进程首次持锁且尚未使用 JVM 才能授权退出协议；不是从 ArkTS 布尔或
        // Java 属性相信“已经隔离”。授权仅借用 fd，NAPI 继续持有到整个游戏进程退出。
        if (jvmRuntimeState() != 0 || amclGameExitAuthorize(dir.c_str(), parent, fd) < 0) {
            close(fd);
            return amcl::napi::MakeIntResult(env, -4);
        }
        desktopGameLockFd = fd;
        desktopGameLockOwnerPid = getpid();
        desktopGameLauncherPid = parent;
        desktopGameLockDirectory = dir;
    } else close(fd);
    return amcl::napi::MakeIntResult(env, parent ? 1 : 0);
}

// --- P6: MC 启动器 ---
napi_value McCheckFiles(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    char mcDir[512] = {0}, mcVer[64] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], mcDir, sizeof(mcDir), &len);
    if (argc >= 2) napi_get_value_string_utf8(env, argv[1], mcVer, sizeof(mcVer), &len);
    return amcl::napi::WrapStringResult(env, mcCheckFiles(mcDir, mcVer));
}

// ⚰️ 2026-08-27（加载链审查修复批次）：这里曾有 McLaunch（NAPI 导出名 "mcLaunch"，
//   legacy 启动接口，C 层拼 classpath、绕过 AmclClassLoader 隔离契约）。
//   ArkTS 无调用方，与 mc_launcher.cpp 实现、index.d.ts 声明、obfuscation-rules
//   同批删除。⚠️ 三处必须同批 —— 只删实现会留下声明存在但符号缺失的 NAPI 导出。

// 数据驱动启动（v3 架构：ArkTS 传入 LaunchProfile 全部字段）
napi_value McLaunchWithProfile(napi_env env, napi_callback_info info) {
    mcClearGraphicsLaunchFailure();
    size_t argc = 8;
    napi_value argv[8];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string filesDir, gameDir, jdkVer;
    std::string mainClass, classpath, mcArgsStr, extraJvmArgs;
    int32_t xmx = 0;

    if (argc >= 1 && !amcl::napi::ReadStringValue(env, argv[0], filesDir)) {
        OH_LOG_ERROR(LOG_APP, "McLaunchWithProfile: filesDir must be string");
        return amcl::napi::MakeIntResult(env, -1);
    }
    if (argc >= 2 && !amcl::napi::ReadStringValue(env, argv[1], gameDir)) {
        OH_LOG_ERROR(LOG_APP, "McLaunchWithProfile: gameDir must be string");
        return amcl::napi::MakeIntResult(env, -1);
    }
    if (argc >= 3 && !amcl::napi::ReadStringValue(env, argv[2], jdkVer)) {
        OH_LOG_ERROR(LOG_APP, "McLaunchWithProfile: jdkVer must be string");
        return amcl::napi::MakeIntResult(env, -1);
    }
    if (argc >= 4 && napi_get_value_int32(env, argv[3], &xmx) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "McLaunchWithProfile: xmx must be number");
        return amcl::napi::MakeIntResult(env, -1);
    }
    if (argc >= 5 && !amcl::napi::ReadStringValue(env, argv[4], mainClass)) {
        OH_LOG_ERROR(LOG_APP, "McLaunchWithProfile: mainClass must be string");
        return amcl::napi::MakeIntResult(env, -1);
    }
    if (argc >= 6 && !amcl::napi::ReadStringValue(env, argv[5], classpath)) {
        OH_LOG_ERROR(LOG_APP, "McLaunchWithProfile: classpath must be string");
        return amcl::napi::MakeIntResult(env, -1);
    }
    if (argc >= 7 && !amcl::napi::ReadStringValue(env, argv[6], mcArgsStr)) {
        OH_LOG_ERROR(LOG_APP, "McLaunchWithProfile: mcArgsStr must be string");
        return amcl::napi::MakeIntResult(env, -1);
    }
    if (argc >= 8 && !amcl::napi::ReadStringValue(env, argv[7], extraJvmArgs)) {
        OH_LOG_ERROR(LOG_APP, "McLaunchWithProfile: extraJvmArgs must be string");
        return amcl::napi::MakeIntResult(env, -1);
    }

    int rc = mcLaunchWithProfile(
        filesDir.c_str(),
        gameDir.c_str(),
        jdkVer.empty() ? nullptr : jdkVer.c_str(),
        xmx,
        mainClass.c_str(),
        classpath.c_str(),
        mcArgsStr.c_str(),
        extraJvmArgs.c_str()
    );
    return amcl::napi::MakeIntResult(env, rc);
}

// 数据驱动启动（v4 参数协议：ArkTS 传入 string[]，不再使用逗号拼接）
napi_value McLaunchWithProfileV2(napi_env env, napi_callback_info info) {
    mcClearGraphicsLaunchFailure();
    size_t argc = 8;
    napi_value argv[8];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string filesDir, gameDir, jdkVer, mainClass, classpath;
    int32_t xmx = 0;
    std::vector<std::string> mcArgs;
    std::vector<std::string> extraJvmArgs;

    if (argc < 6
        || !amcl::napi::ReadStringValue(env, argv[0], filesDir)
        || !amcl::napi::ReadStringValue(env, argv[1], gameDir)
        || !amcl::napi::ReadStringValue(env, argv[2], jdkVer)
        || napi_get_value_int32(env, argv[3], &xmx) != napi_ok
        || !amcl::napi::ReadStringValue(env, argv[4], mainClass)
        || !amcl::napi::ReadStringValue(env, argv[5], classpath)) {
        OH_LOG_ERROR(LOG_APP, "McLaunchWithProfileV2: invalid base args");
        return amcl::napi::MakeIntResult(env, -1);
    }

    if (argc >= 7 && !amcl::napi::ReadStringArrayValue(env, argv[6], mcArgs)) {
        OH_LOG_ERROR(LOG_APP, "McLaunchWithProfileV2: mcArgs must be string[]");
        return amcl::napi::MakeIntResult(env, -1);
    }
    if (argc >= 8 && !amcl::napi::ReadStringArrayValue(env, argv[7], extraJvmArgs)) {
        OH_LOG_ERROR(LOG_APP, "McLaunchWithProfileV2: extraJvmArgs must be string[]");
        return amcl::napi::MakeIntResult(env, -1);
    }

    std::vector<const char*> mcArgv;
    mcArgv.reserve(mcArgs.size());
    for (const auto& arg : mcArgs) {
        mcArgv.push_back(arg.c_str());
    }

    std::vector<const char*> extraArgv;
    extraArgv.reserve(extraJvmArgs.size());
    for (const auto& arg : extraJvmArgs) {
        extraArgv.push_back(arg.c_str());
    }

    int rc = mcLaunchWithProfileV2(
        filesDir.c_str(),
        gameDir.c_str(),
        jdkVer.empty() ? nullptr : jdkVer.c_str(),
        xmx,
        mainClass.c_str(),
        classpath.c_str(),
        (int)mcArgv.size(),
        mcArgv.empty() ? nullptr : mcArgv.data(),
        (int)extraArgv.size(),
        extraArgv.empty() ? nullptr : extraArgv.data()
    );
    return amcl::napi::MakeIntResult(env, rc);
}

napi_value McGetStatus(napi_env env, napi_callback_info info) {
    return amcl::napi::WrapStringResult(env, mcGetStatus());
}

/** 同一 JS 调用线程读取刚结束的启动准入失败，后台状态字符串仍走 McGetStatus。 */
napi_value McGetGraphicsLaunchFailure(napi_env env, napi_callback_info) {
    return amcl::napi::WrapStringResult(env, mcGetGraphicsLaunchFailure());
}
/** 异步渲染故障与帧摘要属于同一 PID/后端快照，UI 读取不会调用任何 GL 函数。 */
napi_value McGetGraphicsRuntimeState(napi_env env, napi_callback_info) {
    return amcl::napi::WrapStringResult(env, amclGraphicsRuntimeJsonV1());
}
napi_value McGetGraphicsRuntimeFailure(napi_env env, napi_callback_info) {
    return amcl::napi::WrapStringResult(env, amclGraphicsFailureJsonV1());
}
/** 精确查询已知旧游戏 PID 是否仍存在；配合 OS 游戏锁，不能把 Ability 返回当作进程死亡。 */
napi_value DesktopProcessAlive(napi_env env, napi_callback_info info) {
    size_t count = 1; napi_value args[1]{}; int32_t pid = 0;
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    if (count != 1 || napi_get_value_int32(env, args[0], &pid) != napi_ok || pid <= 0)
        return amcl::napi::MakeIntResult(env, -1);
    const int result = kill(pid, 0);
    return amcl::napi::MakeIntResult(env, result == 0 || errno == EPERM ? 1 : errno == ESRCH ? 0 : -1);
}

/** 存储错误必须传播到部署/预检，不能把“未提交”解释为可用。目录边界由 native 再验证。 */
bool ReadSlotArguments(napi_env env, napi_callback_info info, std::string& first, std::string* second = nullptr) {
    size_t count = second ? 2 : 1; napi_value args[2]{};
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    if (count != (second ? 2u : 1u) || !amcl::napi::ReadStringValue(env, args[0], first) ||
        (second && !amcl::napi::ReadStringValue(env, args[1], *second))) {
        napi_throw_type_error(env, nullptr, "Invalid runtime slot arguments"); return false;
    }
    return true;
}
napi_value SlotFailure(napi_env env, const std::string& error) {
    napi_throw_error(env, "RUNTIME_SLOT", error.empty() ? "Runtime slot operation failed" : error.c_str()); return nullptr;
}
napi_value RuntimeSlotCreateStage(napi_env env, napi_callback_info info) {
    std::string path, error; if (!ReadSlotArguments(env, info, path)) return nullptr;
    const auto stage = amcl::runtime::CreateSlotStage(path, error);
    return stage.empty() ? SlotFailure(env, error) : amcl::napi::WrapStringResult(env, stage.c_str());
}
napi_value RuntimeSlotPublish(napi_env env, napi_callback_info info) {
    std::string stage, destination, error; if (!ReadSlotArguments(env, info, stage, &destination)) return nullptr;
    return amcl::runtime::PublishSlotGeneration(stage, destination, error) ? amcl::napi::MakeBoolResult(env, true) : SlotFailure(env, error);
}
napi_value RuntimeSlotDiscardStage(napi_env env, napi_callback_info info) {
    std::string path, error; if (!ReadSlotArguments(env, info, path)) return nullptr;
    return amcl::runtime::DiscardSlotStage(path, error) ? amcl::napi::MakeBoolResult(env, true) : SlotFailure(env, error);
}
napi_value RuntimeSlotAcquire(napi_env env, napi_callback_info info) {
    std::string path, error; if (!ReadSlotArguments(env, info, path)) return nullptr;
    const auto lease = amcl::runtime::AcquireSlotGeneration(path, error);
    return lease.empty() ? SlotFailure(env, error) : amcl::napi::WrapStringResult(env, lease.c_str());
}
napi_value RuntimeSlotRelease(napi_env env, napi_callback_info info) {
    std::string handle; if (!ReadSlotArguments(env, info, handle)) return nullptr;
    return amcl::napi::MakeBoolResult(env, amcl::runtime::ReleaseSlotGeneration(handle));
}
napi_value RuntimeSlotRetire(napi_env env, napi_callback_info info) {
    std::string path, error; if (!ReadSlotArguments(env, info, path)) return nullptr;
    return amcl::napi::MakeBoolResult(env, amcl::runtime::RetireSlotGeneration(path, error));
}
napi_value RuntimeSlotCollect(napi_env env, napi_callback_info info) {
    std::string path; if (!ReadSlotArguments(env, info, path)) return nullptr;
    const auto result = amcl::runtime::CollectSlotGarbage(path);
    return amcl::napi::MakeIntResult(env, static_cast<int32_t>(result.removed));
}
napi_value GraphicsRecoveryMaintain(napi_env env, napi_callback_info info) {
    std::string path, keep; if (!ReadSlotArguments(env, info, path, &keep)) return nullptr;
    const auto now = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    const auto result = amcl::runtime::CollectGraphicsTickets(path, keep, now);
    return amcl::napi::MakeIntResult(env, static_cast<int32_t>(result.removed));
}

napi_value McIsRunning(napi_env env, napi_callback_info info) {
    return amcl::napi::MakeBoolResult(env, mcIsRunning());
}

napi_value McForceExit(napi_env env, napi_callback_info info) {
    mcForceExit();
    // 不会到达这里（_exit 立即终止进程）
    return nullptr;
}

napi_value McReadLog(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char mcDir[512] = "";
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], mcDir, sizeof(mcDir), &len);
    int32_t maxBytes = 2048;
    if (argc > 1) napi_get_value_int32(env, args[1], &maxBytes);
    return amcl::napi::WrapStringResult(env, mcReadLog(mcDir, maxBytes));
}

// --- 设备内存查询 ---
napi_value McGetDeviceMemoryMB(napi_env env, napi_callback_info info) {
    return amcl::napi::MakeIntResult(env, mcGetDeviceMemoryMB());
}

napi_value McGetRecommendedXmx(napi_env env, napi_callback_info info) {
    return amcl::napi::MakeIntResult(env, mcGetRecommendedXmx());
}

// --- 沙箱外存储可行性探针（Phase 0）---
//
// 用裸 POSIX 调用在给定目录上跑 mkdir/open/write/read/stat/unlink，回报每步成败 + errno。
// 这是 "MC 的 JVM 能否在该目录跑起来" 的忠实代理：ELF loader 加载的 JDK .so 与本 libentry.so
// 同进程、同 sandbox/SELinux 上下文，本函数 open() 能成则 JVM 的 libjava/libnio open() 也能成。
// ArkTS 先用 Environment.getUserDownloadDir() + 授权拿到 Download 的沙箱映射路径再传进来。
#ifdef MC_OHOS_BUILD_TESTS
napi_value ProbeNativePath(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string dir;
    if (argc < 1 || !amcl::napi::ReadStringValue(env, argv[0], dir) || dir.empty()) {
        return amcl::napi::WrapStringResult(env, "ERR: probeNativePath needs a non-empty path arg");
    }

    std::string report;
    auto line = [&](const std::string& s) { report += s; report += "\n"; };
    auto err = [&](const char* what) {
        line(std::string(what) + " FAIL errno=" + std::to_string(errno) + " (" + strerror(errno) + ")");
    };

    line(std::string("native probe dir=") + dir);

    // 1. mkdir（父目录由 ArkTS 侧保证存在；这里只建叶子目录）
    if (mkdir(dir.c_str(), 0700) != 0 && errno != EEXIST) {
        err("mkdir");
        line("RESULT: NATIVE_DENIED");
        return amcl::napi::WrapStringResult(env, report.c_str());
    }
    line("mkdir OK");

    const std::string file = dir + "/amcl_native_probe.bin";
    const char* payload = "AMCL-NATIVE-PROBE-0123456789";
    const size_t plen = strlen(payload);

    // 2. open(O_CREAT|O_RDWR) + write
    int fd = open(file.c_str(), O_CREAT | O_RDWR | O_TRUNC, 0600);
    if (fd < 0) {
        err("open(O_CREAT)");
        line("RESULT: NATIVE_DENIED");
        return amcl::napi::WrapStringResult(env, report.c_str());
    }
    line(std::string("open(O_CREAT) OK fd=") + std::to_string(fd));
    ssize_t w = write(fd, payload, plen);
    if (w < 0) { err("write"); close(fd); line("RESULT: NATIVE_DENIED"); return amcl::napi::WrapStringResult(env, report.c_str()); }
    line(std::string("write OK bytes=") + std::to_string((long)w));
    close(fd);

    // 3. reopen(O_RDONLY) + read + 校验内容
    int rfd = open(file.c_str(), O_RDONLY);
    if (rfd < 0) { err("reopen(O_RDONLY)"); line("RESULT: NATIVE_DENIED"); return amcl::napi::WrapStringResult(env, report.c_str()); }
    char buf[64] = {0};
    ssize_t r = read(rfd, buf, sizeof(buf) - 1);
    close(rfd);
    if (r < 0) { err("read"); line("RESULT: NATIVE_DENIED"); return amcl::napi::WrapStringResult(env, report.c_str()); }
    bool match = ((size_t)r == plen) && (strncmp(buf, payload, plen) == 0);
    line(std::string("read OK bytes=") + std::to_string((long)r) + " content-match=" + (match ? "YES" : "NO"));

    // 4. stat
    struct stat st {};
    if (stat(file.c_str(), &st) == 0) line(std::string("stat OK size=") + std::to_string((long)st.st_size));
    else err("stat");

    // 5. unlink（清理探针文件）
    if (unlink(file.c_str()) == 0) line("unlink OK");
    else err("unlink");

    line(match ? "RESULT: NATIVE_RW_OK" : "RESULT: NATIVE_RW_PARTIAL");
    return amcl::napi::WrapStringResult(env, report.c_str());
}

#endif

#define NAPI_FUNC(name, fn) \
    { name, nullptr, fn, nullptr, nullptr, nullptr, napi_default, nullptr }

constexpr napi_property_descriptor kMcDescriptors[] = {
    NAPI_FUNC("desktopProcessId", DesktopProcessId),
    NAPI_FUNC("desktopGameProcessState", DesktopGameProcessState),
    NAPI_FUNC("mcLaunchWithProfile",   McLaunchWithProfile),
    NAPI_FUNC("mcLaunchWithProfileV2", McLaunchWithProfileV2),
    NAPI_FUNC("mcGetStatus",           McGetStatus),
    NAPI_FUNC("mcGetGraphicsLaunchFailure", McGetGraphicsLaunchFailure),
    NAPI_FUNC("mcGetGraphicsRuntimeState", McGetGraphicsRuntimeState),
    NAPI_FUNC("mcGetGraphicsRuntimeFailure", McGetGraphicsRuntimeFailure),
    NAPI_FUNC("desktopProcessAlive", DesktopProcessAlive),
    NAPI_FUNC("runtimeSlotCreateStage", RuntimeSlotCreateStage),
    NAPI_FUNC("runtimeSlotPublish", RuntimeSlotPublish),
    NAPI_FUNC("runtimeSlotDiscardStage", RuntimeSlotDiscardStage),
    NAPI_FUNC("runtimeSlotAcquire", RuntimeSlotAcquire),
    NAPI_FUNC("runtimeSlotRelease", RuntimeSlotRelease),
    NAPI_FUNC("runtimeSlotRetire", RuntimeSlotRetire),
    NAPI_FUNC("runtimeSlotCollect", RuntimeSlotCollect),
    NAPI_FUNC("graphicsRecoveryMaintain", GraphicsRecoveryMaintain),
    NAPI_FUNC("mcCheckFiles",          McCheckFiles),
    NAPI_FUNC("mcIsRunning",           McIsRunning),
    NAPI_FUNC("mcForceExit",           McForceExit),
    NAPI_FUNC("mcReadLog",             McReadLog),
    NAPI_FUNC("getDeviceMemoryMB",     McGetDeviceMemoryMB),
    NAPI_FUNC("getRecommendedXmx",     McGetRecommendedXmx),
#ifdef MC_OHOS_BUILD_TESTS
    NAPI_FUNC("probeNativePath",       ProbeNativePath),
#endif
};

#undef NAPI_FUNC

} // anonymous namespace

namespace amcl::napi {

void registerMcNapi(napi_env env, napi_value exports) {
    napi_define_properties(env, exports,
                           sizeof(kMcDescriptors) / sizeof(kMcDescriptors[0]),
                           kMcDescriptors);
}

} // namespace amcl::napi
