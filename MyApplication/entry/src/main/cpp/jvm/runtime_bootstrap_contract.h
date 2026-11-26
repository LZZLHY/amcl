#pragma once

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>
#include "jna_runtime_contract.h"
#include "hap_native_provider_contract.h"
#include "../platform/egl_provider_dispatch.h"

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
 * 为 LWJGL EGL Java 绑定固定唯一的查询桥。MG/MobileGL 的 display、context 与 surface
 * 由进程 owner 持有；Java ClassLoader 即使使用绝对路径，也可能在另一 linker namespace
 * 再映射 provider，直接传其路径会形成两套 wrapper 对象域。独立桥不实现任何 EGL 操作，
 * 只把 eglGetProcAddress 转给已经冻结的 amclGraphicsEglProcV1，因此窗口和 Java 始终
 * 使用同一函数表。这里仅生成路径，不装入桥、provider 或系统驱动。
 * Vulkan/未知 profile 没有已准入的 EGL provider，返回空并由调用方省略该属性。
 */
inline std::string RuntimeEglLibrary(const std::string& nativeDir, const std::string& profile) {
    using amcl::desktop::EglProvider;
    const auto provider = amcl::desktop::SelectEglProvider(profile == "nativegl", profile.c_str(),
        profile == "minecraft-vulkan" ? "VULKAN" : "OPENGL");
    if (provider != EglProvider::kUnavailable) return nativeDir + "/libamcl_lwjgl_egl.so";
    return {};
}

/**
 * 结构化计划已核验槽位。兼容旧调用方时，只识别 AMCL 现代槽中明确交付的新绑定；
 * 旧槽同名 JAR、其它 Maven 目录及文件名的前缀均不改变原有分配器。
 */
inline std::string AllocatorRuntimeSlot(bool hasPlan, const std::string& slot, std::string_view classpath) {
    if (hasPlan) return slot;
    constexpr std::string_view binding = "/lwjgl-ohos/lwjgl-jemalloc.jar";
    while (!classpath.empty()) {
        const auto separator = classpath.find(':');
        const auto entry = classpath.substr(0, separator);
        if (entry.size() >= binding.size() && entry.substr(entry.size() - binding.size()) == binding) return "LWJGL3";
        if (separator == std::string_view::npos) break;
        classpath.remove_prefix(separator + 1);
    }
    return {};
}

/**
 * 按已准入的 GraphicsPlan 生成早读属性。调用方负责验证绝对路径与 provider 制品；
 * 本函数不重新选择后端，也不触碰加载器。所有值必须在 Java agent/Configuration 初始化前生效。
 * JNA 临时目录沿用实例的隔离目录，避免后置 setProperty 改写已缓存的路径。
 */
inline std::vector<BootstrapProperty> RuntimeBootstrapProperties(
    const std::string& nativeDir, const std::string& gameDir,
    const std::string& profile, const std::string& glLibrary, bool sdl,
    const JnaBootstrap& jna = JnaBootstrap{}, const std::string& lwjglSlot = {}) {
    std::vector<BootstrapProperty> result{
        {"java.system.class.loader", "com.amcl.launcher.AmclClassLoader"},
        {"os.name", "Linux"}, {"os.version", "5.10"},
        {"org.lwjgl.librarypath", nativeDir},
        {"org.lwjgl.opengl.libname", glLibrary},
        // OHOS 的真实 GLES API 由系统 libGLESv3.so 提供；Linux 默认 .so.2 不存在。
        // EGL 查询始终属于已冻结 provider；本属性只补库名，不把桌面 GL context 变为
        // GLES。调用者须保证同线程已有兼容的真实 GLES current context，本属性不切换它。
        {"org.lwjgl.opengles.libname", "libGLESv3.so"},
        {"org.lwjgl.opengles.contextAPI", "EGL"},
        // 明确选择本 HAP 的外部 C provider，避免同名 JDK 库/上游平台 natives 抢占。
        // LWJGL 的绝对路径入口不使用 Maven natives SHA1；AMCL 成品门绑定真实 ELF、
        // 来源和导出面，生成 JNI 模块的原有 hash 检查不受影响。
        {"org.lwjgl.glfw.libname", nativeDir + "/libglfw.so"},
        {"org.lwjgl.openal.libname", nativeDir + "/libopenal.so"},
        {"org.lwjgl.sdl.libname", nativeDir + "/libSDL3.so"},
        // SDL的独立FFM绑定在system fallback读取此公开属性。显式Path加载的第三方内嵌
        // 库仍由原绑定处理；这里只冻结fallback到已审核的同包制品，不抢先初始化SDL。
        {"dev.isxander.sdl.library", nativeDir + "/libamcl_sdl_controller.so"},
        {"org.lwjgl.freetype.libname", nativeDir + "/libfreetype.so"},
        {"org.lwjgl.vulkan.libname", nativeDir + "/libamcl_vulkan_wsi.so"},
        {"org.lwjgl.shaderc.libname", nativeDir + "/libshaderc.so"},
        {"org.lwjgl.spvc.libname", nativeDir + "/libspirv-cross.so"},
        {"amcl.graphics.profile", profile}, {"amcl.sdl3", sdl ? "1" : "0"},
        // JNI 协议由实际 classpath JNA 决定。deferred 用空 boot path 与禁止系统搜索，
        // 交回 JNA 自带 native，不能再无条件强制协议 7 或允许错误 fallback 偷换槽位。
        {"jna.boot.library.path", jna.bootLibraryPath}, {"jna.boot.library.name", jna.bootLibraryName},
        {"jna.nosys", "true"}, {"jna.tmpdir", gameDir + "/natives/jna"},
        {"imgui.library.path", nativeDir},
        // 标准 Java Sound SPI 由启动器父加载域交付；JNI 路径须先于任意 AudioSystem 查询冻结。
        {"amcl.audio.jni.path", nativeDir + "/libamcl_audio_jni.so"},
        {"amcl.audio.enabled", "true"}, {"amcl.audio.service.schema", "1"},
        // 自有候选路径只描述已交付 native。Java 只读 resolver 命中真实绑定后才启用官方属性。
        {"amcl.sherpa.native.path", nativeDir},
        // 供已核实的 SDL2/JNI 和 JNA 绑定在各自游戏类加载器内打开随包库。
        {"amcl.gamepad.sdl2.dir", nativeDir},
        // zstd标准/DH绑定先按完整Java身份选择；只发布当前HAP目录，不预加载或改变上游用户值。
        {"amcl.zstd.native.path", nativeDir},
        {"minecraft.applet.TargetDirectory", gameDir},
        // Java业务临时文件与实例数据同卷，默认Files.move可走rename。VM工具/Attach使用
        // jvmInit独立发布的私有TMPDIR；processor入口不调用本游戏属性工厂，仍沿用旧默认。
        {"java.io.tmpdir", gameDir + "/.amcl/java-tmp"},
        {"net.minecraft.clientmodname", "AMCL"}
    };
    // 必须在 agent 与 LWJGL Configuration 初始化前冻结；Linux 默认 libEGL.so.1
    // 既不匹配 OHOS 系统库名，也不能代表 MG/MobileGL 的 wrapper 对象域。
    // 现代槽的 Java 绑定及交给 STB、SPNG、NanoVG 的原生回调共用这一个 HAP 内的库。
    // 旧槽带有自己的 Java ABI；省略该属性可避免它们拾取现代分配器。
    if (lwjglSlot == "LWJGL3") {
        result.emplace_back("org.lwjgl.system.jemalloc.libname", nativeDir + "/libamcl_lwjgl_jemalloc.so");
    }
    const auto eglLibrary = RuntimeEglLibrary(nativeDir, profile);
    if (!eglLibrary.empty()) result.emplace_back("org.lwjgl.egl.libname", eglLibrary);
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
 * 显式Java临时目录是高级用户输入，保留其最后参数生效语义，不暗中替换为游戏默认值。
 * 只移除本厂生成的缺省属性，不修改原参数；返回true提示调用方不要创建缺省目录。
 * 它不改变VM原生TMPDIR，也不因自定义路径而授予同卷移动或私有存储保证。
 */
inline bool PreserveExplicitJavaTempDirectory(const std::vector<std::string>& arguments,
        std::vector<BootstrapProperty>& properties) {
    const bool custom = std::any_of(arguments.begin(), arguments.end(), [](const auto& argument) {
        return PropertyKey(argument) == "java.io.tmpdir";
    });
    if (custom) properties.erase(std::remove_if(properties.begin(), properties.end(), [](const auto& property) {
        return property.first == "java.io.tmpdir";
    }), properties.end());
    return custom;
}

/** 标准mixer仅提供缺省选择；保留用户明确选的可用provider，不把它升级为宿主独占路径。 */
inline void ApplyAudioMixerDefaults(std::vector<std::string>& args) {
    for (const char* key : {"javax.sound.sampled.SourceDataLine", "javax.sound.sampled.TargetDataLine", "javax.sound.sampled.Clip"}) {
        const bool selected = std::any_of(args.begin(), args.end(), [key](const std::string& arg) { return PropertyKey(arg) == key; });
        if (!selected) args.emplace_back(std::string("-D") + key + "=com.amcl.audio.OhosMixerProvider");
    }
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
