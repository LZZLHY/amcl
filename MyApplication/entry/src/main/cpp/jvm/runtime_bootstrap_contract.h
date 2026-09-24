#pragma once

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace amcl::jvm {
/** 启动期属性键值。只存字符串，不持有 JNI 对象，不会初始化任何游戏平台类。 */
using BootstrapProperty = std::pair<std::string, std::string>;

/**
 * Invocation API 的回调只能由 native 提供函数指针，不能来自用户/加载器的字符串参数。
 * JDK8 对这些名称使用前缀匹配，因此 exit=.../abortX 也必须拒绝；否则其 extraInfo=null
 * 会覆盖先前安装的宿主回调。-Dexit=... 等普通属性不命中，不扩大为一般参数白名单。
 */
inline bool IsReservedInvocationHookOption(const std::string& argument) {
    return argument.compare(0, 4, "exit") == 0 ||
        argument.compare(0, 5, "abort") == 0 || argument.compare(0, 8, "vfprintf") == 0;
}

/**
 * 已隔离游戏只消费显式 JVM 参数。HotSpot 还会自行读取这两个环境入口，其中
 * _JAVA_OPTIONS 晚于 Invocation 参数解析，能够绕过宿主的回调/属性冻结。
 * 不复制不同 JDK 的引号分词器，也不静默删除用户输入；非空时拒绝本次启动并提示迁移。
 */
inline bool HasImplicitInvocationOptions(const char* toolOptions, const char* javaOptions) {
    return (toolOptions && toolOptions[0] != '\0') || (javaOptions && javaOptions[0] != '\0');
}

/**
 * 按已准入的 GraphicsPlan 生成早读属性。调用方负责验证绝对路径与 provider 制品；
 * 本函数不重新选择后端，也不触碰加载器。所有值必须在 Java agent/Configuration 初始化前生效。
 * JNA 临时目录沿用实例的隔离目录，避免后置 setProperty 改写已缓存的路径。
 */
inline std::vector<BootstrapProperty> RuntimeBootstrapProperties(
    const std::string& nativeDir, const std::string& gameDir,
    const std::string& profile, const std::string& glLibrary, bool sdl) {
    std::vector<BootstrapProperty> result{
        {"java.system.class.loader", "com.amcl.launcher.AmclClassLoader"},
        {"os.name", "Linux"}, {"os.version", "5.10"},
        {"org.lwjgl.librarypath", nativeDir},
        {"org.lwjgl.opengl.libname", glLibrary},
        {"org.lwjgl.glfw.libname", "libglfw.so"},
        {"org.lwjgl.sdl.libname", "libSDL3.so"},
        {"org.lwjgl.freetype.libname", "libfreetype.so"},
        {"org.lwjgl.vulkan.libname", "libamcl_vulkan_wsi.so"},
        {"org.lwjgl.shaderc.libname", "shaderc"},
        {"org.lwjgl.spvc.libname", "spirv-cross"},
        {"amcl.graphics.profile", profile}, {"amcl.sdl3", sdl ? "1" : "0"},
        {"jna.boot.library.path", nativeDir}, {"jna.tmpdir", gameDir + "/natives/jna"},
        {"imgui.library.path", nativeDir},
        {"minecraft.applet.TargetDirectory", gameDir},
        {"net.minecraft.clientmodname", "AMCL"}
    };
    if (profile == "nativegl") result.emplace_back("org.lwjgl.opengl.contextAPI", "native");
    return result;
}

/** 精确提取 -D 属性键；裸 -Dkey 与 -Dkey=value 视为同键，避免尾部空值绕过保护。 */
inline std::string PropertyKey(const std::string& argument) {
    if (argument.compare(0, 2, "-D") != 0) return {};
    const auto end = argument.find('=', 2);
    return argument.substr(2, end == std::string::npos ? end : end - 2);
}

/**
 * 冻结计划拥有的属性。已有等值项合并为一条；异值项返回具名错误而不是暗中替换。
 * 校验全部完成后才修改参数向量，所以失败不产生半更新；不记录可能含凭据的原始参数。
 */
inline bool FreezeBootstrapProperties(std::vector<std::string>& args,
    const std::vector<BootstrapProperty>& properties, std::string& error) {
    for (const auto& argument : args) {
        if (IsReservedInvocationHookOption(argument)) {
            error = "runtime_invocation_hook_override";
            return false;
        }
        const auto key = PropertyKey(argument);
        for (const auto& property : properties) {
            if (key == property.first && argument != "-D" + property.first + "=" + property.second) {
                error = "runtime_property_conflict:" + key;
                return false;
            }
        }
        // 这些路径由 jvmInit 按真实运行身份构造；接受自定义值会让契约日志与实际 JVM 分离。
        if (key == "java.class.path" || key == "java.library.path" ||
            key == "java.home" || key == "sun.boot.library.path") {
            error = "runtime_path_override:" + key;
            return false;
        }
    }
    args.erase(std::remove_if(args.begin(), args.end(), [&](const std::string& argument) {
        const auto key = PropertyKey(argument);
        return std::any_of(properties.begin(), properties.end(),
            [&](const BootstrapProperty& property) { return property.first == key; });
    }), args.end());
    for (const auto& property : properties) args.push_back("-D" + property.first + "=" + property.second);
    return true;
}

/**
 * 每进程 JVM 的一次性创建闸门。进入创建后即不可退回 Fresh，即使创建失败或 DestroyJavaVM
 * 返回，也不能证明 HotSpot/native 静态状态可重用。安装器必须先原子保留 Fresh 到 fork 返回，
 * 防止“检查时还 Fresh、实际 fork 时另一个线程已经创建 JVM”。状态与父 PID 合并在一个
 * 无锁原子字中发布；禁止使用可能在 fork 后继承已锁状态的 mutex 或有锁 atomic 实现。
 */
class RuntimeOnce final {
public:
    enum State : int { Fresh = 0, Creating = 1, Ready = 2, Spent = 3, ForkReserved = 4 };
    enum ForkResult : int { ForkAcquired = 0, ForkNotFresh = -7, ForkBusy = -8, ForkInvalidPid = -9 };
    /** 与 reserveFork 共用 CAS；失败原因取 CAS 看到的状态，不二次读取而误判刚释放的 busy。 */
    int beginResult() {
        uint64_t expected = Fresh;
        if (state_.compare_exchange_strong(expected, Creating, std::memory_order_acq_rel)) return 0;
        return static_cast<uint32_t>(expected) == ForkReserved ? ForkBusy : ForkNotFresh;
    }
    bool begin() { return beginResult() == 0; }

    /** 仅成功调用者可以执行一次 fork；失败回报 busy 与必须重启两种不同状态。 */
    int reserveFork(uint32_t parentPid) {
        if (!parentPid) return ForkInvalidPid;
        uint64_t expected = Fresh;
        if (state_.compare_exchange_strong(expected, forkWord(parentPid), std::memory_order_acq_rel)) {
            return ForkAcquired;
        }
        return static_cast<uint32_t>(expected) == ForkReserved ? ForkBusy : ForkNotFresh;
    }

    /** 父进程 fork 成功或失败都必须释放；只接受本次保留者的 PID，不允许子进程冒充释放。 */
    bool releaseFork(uint32_t parentPid) {
        if (!parentPid) return false;
        uint64_t expected = forkWord(parentPid);
        return state_.compare_exchange_strong(expected, Fresh, std::memory_order_acq_rel);
    }

    /**
     * 子进程的第一项运行时操作：必须继承 ForkReserved 且 PID 确实改变。
     * 仅把“尚未创建 JVM 的保留态”恢复为 Fresh；Creating/Ready/Spent 和同 PID 假 reset 均拒绝。
     * fork 复制的原子字与父进程已经独立，父侧释放不会影响本方法的验证。
     */
    bool adoptForkChild(uint32_t childPid) {
        uint64_t expected = state_.load(std::memory_order_acquire);
        const auto parentPid = static_cast<uint32_t>(expected >> 32);
        if (!childPid || !parentPid || childPid == parentPid ||
            static_cast<uint32_t>(expected) != ForkReserved) return false;
        return state_.compare_exchange_strong(expected, Fresh, std::memory_order_acq_rel);
    }

    void ready() { state_.store(Ready, std::memory_order_release); }
    void retire() { state_.store(Spent, std::memory_order_release); }
    int state() const { return static_cast<uint32_t>(state_.load(std::memory_order_acquire)); }
private:
    static uint64_t forkWord(uint32_t pid) { return (static_cast<uint64_t>(pid) << 32) | ForkReserved; }
    static_assert(std::atomic<uint64_t>::is_always_lock_free, "fork lifecycle requires lock-free 64-bit atomics");
    std::atomic<uint64_t> state_{Fresh};
};
}
