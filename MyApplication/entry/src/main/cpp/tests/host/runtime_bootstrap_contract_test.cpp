// 实际编译生产纯核心，覆盖属性冻结事务与一次性 JVM 状态，不模拟出恒真的调用计数。
#include "../../jvm/runtime_bootstrap_contract.h"
#include <cstdlib>
#include <iostream>
#include <thread>
#if !defined(_WIN32)
#include <unistd.h>
#include <sys/wait.h>
#endif

#define REQUIRE(x) do { if (!(x)) { std::cerr << "FAIL " << __LINE__ << ": " #x << '\n'; std::exit(1); } } while (0)
int main() {
    // 标准音频只补默认值；用户指定其它已安装provider仍按Java原有选择规则处理。
    std::vector<std::string> audioArgs{"-Djavax.sound.sampled.SourceDataLine=UserProvider#Mixer"};
    amcl::jvm::ApplyAudioMixerDefaults(audioArgs);
    REQUIRE(audioArgs.size() == 3);
    REQUIRE(audioArgs.front() == "-Djavax.sound.sampled.SourceDataLine=UserProvider#Mixer");
    const auto audioOnce = audioArgs;
    amcl::jvm::ApplyAudioMixerDefaults(audioArgs);
    REQUIRE(audioArgs == audioOnce);
    using namespace amcl::jvm;
    const std::string modern = "/mc/.amcl-runtime/id/lwjgl-ohos/lwjgl-jemalloc.jar";
    REQUIRE(AllocatorRuntimeSlot(false, "LWJGL3", "other:" + modern + ":last") == "LWJGL3");
    REQUIRE(AllocatorRuntimeSlot(false, "LWJGL3", modern) == "LWJGL3");
    REQUIRE(AllocatorRuntimeSlot(false, "LWJGL3", modern + ".bak:/mc/lwjgl-ohos-322/lwjgl-jemalloc.jar").empty());
    REQUIRE(AllocatorRuntimeSlot(true, "LWJGL322", modern) == "LWJGL322");
    // HAP 缺件在现代槽提前报告；旧槽即使没有对应库也继续启动，且不会去读它。
    REQUIRE(CheckModernAllocatorFile("LWJGL3", "/hap/libs", [](const std::string& p) {
        return p == "/hap/libs/libamcl_lwjgl_jemalloc.so";
    }));
    REQUIRE(!CheckModernAllocatorFile("LWJGL3", "/hap/libs", [](const auto&) { return false; }));
    REQUIRE(CheckModernAllocatorFile("LWJGL322", "/hap/libs", [](const auto&) { std::abort(); return false; }));
    // 三代槽使用同一游戏启动入口；只有明确的现代槽绑定本包的独立分配器。
    for (const std::string slot : {"LWJGL3", "LWJGL322", "LWJGL2", ""}) {
        const auto selected = RuntimeBootstrapProperties("/hap/libs", "/instance", "mobilegl", "libmobilegl.so",
            false, JnaBootstrap{}, slot);
        const auto allocator = std::find_if(selected.begin(), selected.end(), [](const auto& property) {
            return property.first == "org.lwjgl.system.jemalloc.libname";
        });
        if (slot == "LWJGL3") {
            REQUIRE(allocator != selected.end() && allocator->second == "/hap/libs/libamcl_lwjgl_jemalloc.so");
        } else {
            REQUIRE(allocator == selected.end());
        }
    }
    auto properties = RuntimeBootstrapProperties("/hap/libs", "/instance", "mobilegl", "libmobilegl.so", true);
    // 当前安装包映像是唯一目录来源：用户数据、路径穿越、别的DSO都不能冒充本包。
    std::string directory, ownerError;
    for (const char* root : {"/data/storage/el1/bundle/libs/arm64",
            "/data/storage/el1/bundle/libs/arm64-v8a", "/data/storage/el1/bundle/libs"}) {
        REQUIRE(HapNativeDirectoryFromOwner(std::string(root) + "/libentry.so", directory, ownerError));
        REQUIRE(directory == root);
    }
    for (const char* owner : {"libentry.so", "/data/storage/el2/base/files/libs/libentry.so",
            "/data/storage/el1/bundle/libs/arm64/../arm64/libentry.so",
            "/data/storage/el1/bundle/libs/arm64/libglfw.so", ""}) {
        directory = "unchanged";
        REQUIRE(!HapNativeDirectoryFromOwner(owner, directory, ownerError) && directory == "unchanged");
    }
    REQUIRE(CheckHapExternalProviderFiles("/hap/libs", [](const std::string&) { return true; }, ownerError));
    REQUIRE(!CheckHapExternalProviderFiles("/hap/libs", [](const std::string& p) {
        return p != "/hap/libs/libfreetype.so";
    }, ownerError));
    REQUIRE(ownerError == "hap_native_provider_missing:libfreetype.so");
    // EGL 必须在首次 LWJGL Configuration 读取前与真实 provider 配对，不能误用 Linux 的
    // libEGL.so.1 或把翻译器的虚拟句柄交给系统 EGL。这里同时覆盖两条系统路线及无 EGL 的 Vulkan。
    REQUIRE(RuntimeEglLibrary("/hap/libs", "mobileglues") == "/hap/libs/libamcl_lwjgl_egl.so");
    REQUIRE(RuntimeEglLibrary("/hap/libs", "mobilegl") == "/hap/libs/libamcl_lwjgl_egl.so");
    REQUIRE(RuntimeEglLibrary("/hap/libs", "gl4es") == "/hap/libs/libamcl_lwjgl_egl.so");
    REQUIRE(RuntimeEglLibrary("/hap/libs", "nativegl") == "/hap/libs/libamcl_lwjgl_egl.so");
    REQUIRE(RuntimeEglLibrary("/hap/libs", "minecraft-vulkan").empty());
    REQUIRE(RuntimeEglLibrary("/hap/libs", "unknown-profile").empty());
    std::string error;
    std::vector<std::string> args{"-Xmx1024m", "-Dorg.lwjgl.sdl.libname=libSDL3.so", "-Dorg.lwjgl.libname=lwjgl_v322"};
    bool customOpenAl = true;
    REQUIRE(NormalizeHapProviderArguments(args, properties, "/hap/libs", customOpenAl, error));
    REQUIRE(!customOpenAl);
    REQUIRE(FreezeBootstrapProperties(args, properties, error));
    const auto once = args;
    REQUIRE(std::find(args.begin(), args.end(), "-Djna.tmpdir=/instance/natives/jna") != args.end());
    REQUIRE(std::find(args.begin(), args.end(), "-Djava.io.tmpdir=/instance/.amcl/java-tmp") != args.end());
    // provider候选根属于真实HAP；用户的上游ZstdNativePath仍可显式选择，二者不能混淆。
    REQUIRE(std::count(args.begin(), args.end(), "-Damcl.zstd.native.path=/hap/libs") == 1);
    std::vector<std::string> spoofedZstd{"-Damcl.zstd.native.path=/public/mods"};
    const auto spoofedOriginal = spoofedZstd;
    REQUIRE(!FreezeBootstrapProperties(spoofedZstd, properties, error) && spoofedZstd == spoofedOriginal);
    std::vector<std::string> customZstd{"-DZstdNativePath=/user/custom-zstd.so"};
    REQUIRE(FreezeBootstrapProperties(customZstd, properties, error));
    REQUIRE(customZstd.front() == "-DZstdNativePath=/user/custom-zstd.so");
    REQUIRE(std::find(args.begin(), args.end(), "-Dorg.lwjgl.egl.libname=/hap/libs/libamcl_lwjgl_egl.so") != args.end());
    REQUIRE(std::find(args.begin(), args.end(), "-Dorg.lwjgl.opengles.libname=libGLESv3.so") != args.end());
    REQUIRE(std::find(args.begin(), args.end(), "-Dorg.lwjgl.opengles.contextAPI=EGL") != args.end());
    REQUIRE(FreezeBootstrapProperties(args, properties, error) && args == once);
    REQUIRE(std::count(args.begin(), args.end(), "-Dorg.lwjgl.sdl.libname=/hap/libs/libSDL3.so") == 1);
    // 独立FFM消费者与LWJGL命中同一制品；这只绑定fallback，不提前执行其SDL_Init。
    REQUIRE(std::count(args.begin(), args.end(), "-Ddev.isxander.sdl.library=/hap/libs/libSDL3.so") == 1);
    REQUIRE(std::count(args.begin(), args.end(), "-Dorg.lwjgl.openal.libname=/hap/libs/libopenal.so") == 1);
    for (const auto& alias : HapOwnedProviderAliases()) {
        REQUIRE(std::count(args.begin(), args.end(), std::string("-D") + alias.key + "=/hap/libs/" + alias.artifact) == 1);
    }
    REQUIRE(std::find(args.begin(), args.end(), "-Dorg.lwjgl.libname=lwjgl_v322") != args.end());
    // 自定义Java临时目录保留最后参数语义，既不重写用户路径也不创建缺省目录。
    for (const std::vector<std::string>& customTemp : {
            std::vector<std::string>{"-Djava.io.tmpdir=/chosen/tmp"},
            std::vector<std::string>{"-Djava.io.tmpdir=/first", "-Djava.io.tmpdir="}}) {
        auto properties = RuntimeBootstrapProperties("/hap/libs", "/instance", "mobilegl", "libmobilegl.so", false);
        REQUIRE(PreserveExplicitJavaTempDirectory(customTemp, properties));
        REQUIRE(std::none_of(properties.begin(), properties.end(), [](const auto& p) { return p.first == "java.io.tmpdir"; }));
        auto actual = customTemp;
        REQUIRE(FreezeBootstrapProperties(actual, properties, error));
        REQUIRE(std::equal(customTemp.begin(), customTemp.end(), actual.begin()));
    }
    // OpenAL保留高级显式选择及最后值语义；默认值规范化不覆盖用户的不同provider。
    for (const std::string value : {"none", "", "/user/custom/libopenal.so"}) {
        auto customProperties = RuntimeBootstrapProperties("/hap/libs", "/instance", "mobilegl", "libmobilegl.so", true);
        std::vector<std::string> customArgs{"-Dorg.lwjgl.openal.libname=libopenal.so", "-Dorg.lwjgl.openal.libname=" + value};
        const auto originalArgs = customArgs;
        REQUIRE(NormalizeHapProviderArguments(customArgs, customProperties, "/hap/libs", customOpenAl, error));
        REQUIRE(customOpenAl && customArgs == originalArgs);
        REQUIRE(std::none_of(customProperties.begin(), customProperties.end(), [](const auto& p) {
            return p.first == "org.lwjgl.openal.libname";
        }));
        REQUIRE(FreezeBootstrapProperties(customArgs, customProperties, error));
        REQUIRE(std::find(customArgs.begin(), customArgs.end(), "-Dorg.lwjgl.openal.libname=" + value) != customArgs.end());
    }
    auto defaultProperties = RuntimeBootstrapProperties("/hap/libs", "/instance", "mobilegl", "libmobilegl.so", true);
    std::vector<std::string> defaultArgs{"-Dorg.lwjgl.openal.libname=none", "-Dorg.lwjgl.openal.libname=libopenal.so"};
    REQUIRE(NormalizeHapProviderArguments(defaultArgs, defaultProperties, "/hap/libs", customOpenAl, error));
    REQUIRE(!customOpenAl && defaultArgs.empty());
    REQUIRE(FreezeBootstrapProperties(defaultArgs, defaultProperties, error));
    // 子入口缺席时继续Supplier复用；显式等值可规范，外来库拒绝且不产生半更新。
    const std::string childKey = "org.lwjgl.shaderc.glslang.libname";
    REQUIRE(std::none_of(properties.begin(), properties.end(), [&](const auto& p) { return p.first == childKey; }));
    auto childProperties = properties;
    std::vector<std::string> childArgs{"-D" + childKey + "=shaderc"};
    REQUIRE(NormalizeHapProviderArguments(childArgs, childProperties, "/hap/libs", customOpenAl, error));
    REQUIRE(FreezeBootstrapProperties(childArgs, childProperties, error));
    const auto childOnce = childArgs; const auto propertiesOnce = childProperties;
    REQUIRE(NormalizeHapProviderArguments(childArgs, childProperties, "/hap/libs", customOpenAl, error));
    REQUIRE(FreezeBootstrapProperties(childArgs, childProperties, error));
    REQUIRE(childArgs == childOnce && childProperties == propertiesOnce);
    std::vector<std::string> badChild{"-Dorg.lwjgl.glfw.libname=libglfw.so", "-D" + childKey + "=/other/libshaderc.so"};
    const auto badChildBefore = badChild; const auto childPropertiesBefore = childProperties;
    REQUIRE(!NormalizeHapProviderArguments(badChild, childProperties, "/hap/libs", customOpenAl, error));
    REQUIRE(badChild == badChildBefore && childProperties == childPropertiesBefore);
    for (const char* invalid : {"-Dorg.lwjgl.sdl.libname", "-Dorg.lwjgl.opengl.libname=evil",
            "-Djava.system.class.loader=Other", "-Djava.class.path=/other", "-Djava.library.path=/other",
            "-Dorg.lwjgl.vulkan.libname=other", "-Dorg.lwjgl.egl.libname=libEGL.so.1",
            "-Dorg.lwjgl.egl.libname", "-Dorg.lwjgl.opengles.libname=libGLESv2.so.2",
            "-Dorg.lwjgl.opengles.contextAPI=native", "-Damcl.sdl3=0", "-Damcl.graphics.profile=other",
            "exit", "exit=0", "exitHook", "abort", "abortSuffix", "vfprintf", "vfprintf=log"}) {
        auto bad = once; bad.emplace_back(invalid); const auto unchanged = bad;
        REQUIRE(!FreezeBootstrapProperties(bad, properties, error) && bad == unchanged && !error.empty());
    }
    // 回调保留项按 JDK8 前缀语义保护，但不得误伤普通属性或标准 JVM 开关。
    for (const char* allowed : {"", "exi", "-Dexit=0", "-Dabort=yes", "-Xmx1024m", "--add-opens=java.base/java.lang=ALL-UNNAMED"}) {
        REQUIRE(!IsReservedInvocationHookOption(allowed));
    }
    REQUIRE(!HasImplicitInvocationOptions(nullptr, nullptr));
    REQUIRE(!HasImplicitInvocationOptions("", ""));
    REQUIRE(HasImplicitInvocationOptions("exit", nullptr));
    REQUIRE(HasImplicitInvocationOptions(nullptr, "exit"));
    REQUIRE(HasImplicitInvocationOptions("-Dotherwise.valid=1", ""));
    const auto desktop = RuntimeBootstrapProperties("/hap/libs", "/instance", "nativegl", "libGLv4.so", false);
    REQUIRE(std::find(desktop.begin(), desktop.end(), BootstrapProperty{"org.lwjgl.opengl.contextAPI", "native"}) != desktop.end());
    // 同时开始也只能有一个创建者；Ready/Spent 均不得重新创建，避免失败后偷换 ClassLoader。
    RuntimeOnce runtime;
    std::atomic<int> accepted{0};
    std::thread a([&] { if (runtime.begin()) ++accepted; });
    std::thread b([&] { if (runtime.begin()) ++accepted; });
    a.join(); b.join();
    REQUIRE(accepted == 1 && runtime.state() == RuntimeOnce::Creating);
    runtime.ready(); REQUIRE(!runtime.begin());
    runtime.retire(); REQUIRE(runtime.state() == RuntimeOnce::Spent && !runtime.begin());

    // 合法父侧只短暂保留 fork 窗口；同 PID 假 reset、错误 PID 释放、未保留 reset 均拒绝。
    RuntimeOnce parent;
    REQUIRE(!parent.adoptForkChild(102) && parent.reserveFork(0) == RuntimeOnce::ForkInvalidPid);
    REQUIRE(parent.reserveFork(101) == RuntimeOnce::ForkAcquired);
    REQUIRE(parent.state() == RuntimeOnce::ForkReserved);
    REQUIRE(parent.beginResult() == RuntimeOnce::ForkBusy);
    REQUIRE(parent.reserveFork(101) == RuntimeOnce::ForkBusy);
    REQUIRE(!parent.adoptForkChild(101) && !parent.adoptForkChild(0));
    REQUIRE(!parent.releaseFork(102) && !parent.releaseFork(0));
    REQUIRE(parent.releaseFork(101) && parent.state() == RuntimeOnce::Fresh);
    REQUIRE(!parent.releaseFork(101));
    REQUIRE(parent.begin() && !parent.adoptForkChild(102));
    REQUIRE(parent.reserveFork(101) == RuntimeOnce::ForkNotFresh);
    parent.ready(); REQUIRE(!parent.adoptForkChild(102));
    parent.retire(); REQUIRE(!parent.adoptForkChild(102));

    // Windows 宿主也运行相同生产状态核心的 PID seam；只允许继承保留且 PID 改变的子侧认领。
    RuntimeOnce inherited;
    REQUIRE(inherited.reserveFork(101) == RuntimeOnce::ForkAcquired);
    REQUIRE(inherited.adoptForkChild(102) && inherited.state() == RuntimeOnce::Fresh);
    REQUIRE(!inherited.adoptForkChild(102) && inherited.begin());

    // 真正同时竞争同一个生产 CAS：fork 与创建不能双赢，也不能把 fork 暂忙误报为已污染。
    for (int round = 0; round < 128; ++round) {
        RuntimeOnce racing;
        std::atomic<int> waiting{0};
        std::atomic<bool> go{false};
        int createResult = 999, forkResult = 999;
        auto waitForStart = [&] {
            waiting.fetch_add(1);
            while (!go.load(std::memory_order_acquire)) std::this_thread::yield();
        };
        std::thread creator([&] { waitForStart(); createResult = racing.beginResult(); });
        std::thread forker([&] { waitForStart(); forkResult = racing.reserveFork(101); });
        while (waiting.load() != 2) std::this_thread::yield();
        go.store(true, std::memory_order_release);
        creator.join(); forker.join();
        REQUIRE((createResult == 0) != (forkResult == 0));
        if (forkResult == 0) {
            REQUIRE(createResult == RuntimeOnce::ForkBusy && racing.releaseFork(101));
            REQUIRE(racing.begin());
        } else {
            REQUIRE(forkResult == RuntimeOnce::ForkNotFresh && racing.state() == RuntimeOnce::Creating);
        }
    }

    // 两个 processor 同时保留：只有一个持有 fork 权限，另一个拿到可重试的 busy。
    RuntimeOnce competingForks;
    std::atomic<int> forkAccepted{0}, forkBusy{0};
    auto reserve = [&] {
        const int result = competingForks.reserveFork(101);
        if (result == RuntimeOnce::ForkAcquired) ++forkAccepted;
        else if (result == RuntimeOnce::ForkBusy) ++forkBusy;
    };
    std::thread firstFork(reserve), secondFork(reserve);
    firstFork.join(); secondFork.join();
    REQUIRE(forkAccepted == 1 && forkBusy == 1 && competingForks.releaseFork(101));

#if !defined(_WIN32)
    // POSIX CI 额外验证真实 fork 的 COW 状态：父释放不会抹掉子侧继承的保留记录。
    RuntimeOnce realFork;
    const uint32_t parentPid = static_cast<uint32_t>(getpid());
    REQUIRE(realFork.reserveFork(parentPid) == RuntimeOnce::ForkAcquired);
    const pid_t childPid = fork();
    REQUIRE(childPid >= 0);
    if (childPid == 0) {
        const bool correct = realFork.adoptForkChild(static_cast<uint32_t>(getpid())) && realFork.begin();
        _exit(correct ? 0 : 1);
    }
    REQUIRE(realFork.releaseFork(parentPid) && realFork.begin());
    int childStatus = 0;
    REQUIRE(waitpid(childPid, &childStatus, 0) == childPid && WIFEXITED(childStatus) && WEXITSTATUS(childStatus) == 0);
#endif
    std::cout << "PASS frozen properties, conflicts, old-slot preservation, concurrent single JVM lifecycle, "
                 "128 fork/create CAS races, fork PID identity and busy recovery\n";
}
