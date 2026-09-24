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
    using namespace amcl::jvm;
    const auto properties = RuntimeBootstrapProperties("/hap/libs", "/instance", "mobilegl", "libmobilegl.so", true);
    std::string error;
    std::vector<std::string> args{"-Xmx1024m", "-Dorg.lwjgl.sdl.libname=libSDL3.so", "-Dorg.lwjgl.libname=lwjgl_v322"};
    REQUIRE(FreezeBootstrapProperties(args, properties, error));
    const auto once = args;
    REQUIRE(std::find(args.begin(), args.end(), "-Djna.tmpdir=/instance/natives/jna") != args.end());
    REQUIRE(FreezeBootstrapProperties(args, properties, error) && args == once);
    REQUIRE(std::count(args.begin(), args.end(), "-Dorg.lwjgl.sdl.libname=libSDL3.so") == 1);
    REQUIRE(std::find(args.begin(), args.end(), "-Dorg.lwjgl.libname=lwjgl_v322") != args.end());
    for (const char* invalid : {"-Dorg.lwjgl.sdl.libname", "-Dorg.lwjgl.opengl.libname=evil",
            "-Djava.system.class.loader=Other", "-Djava.class.path=/other", "-Djava.library.path=/other",
            "-Dorg.lwjgl.vulkan.libname=other", "-Damcl.sdl3=0", "-Damcl.graphics.profile=other",
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
