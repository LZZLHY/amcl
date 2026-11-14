/**
 * fork_run_java.cpp — 在子进程中运行 Java 程序
 *
 * fork 子进程 → 复用游戏侧验证过的 jvmInit（含 pre-JVM sigchain）→ JNI_CreateJavaVM
 * → jvmCallMain 运行 main()。用于 Forge/NeoForge 各 processor 等需要独立 JVM 实例的场景。
 *
 * 为什么不再用 JLI_Launch（2026-06 方案 B 合并）：
 *   旧实现移植自 Amethyst-iOS，用 JLI_Launch 启动 JVM 且 `signal(SIGSEGV, SIG_DFL)`，
 *   **没有 sigchain 保护**。HotSpot 把 SIGSEGV 当正常控制流（safepoint polling /
 *   implicit null check），而 OHOS DFX 崩溃处理器（add_special_signal_handler 注册）
 *   优先级高于 sigaction，会在 JVM 装自己的 handler 之前先截获 init 期 SIGSEGV 并杀进程。
 *   JDK 17 在该无保护窗口"碰巧"没踩到致命 SIGSEGV，JDK 21/25 则必崩（退出码 -117）。
 *   游戏路径 jvm_launcher.cpp 的 jvmInit 在 JNI_CreateJavaVM 前注册了 pre-JVM sigchain
 *   handler（init 期把 SIGSEGV 转发给 HotSpot 并 return true 阻止 DFX 杀进程），21/25
 *   实测可用。故本文件改为复用 jvmInit/jvmCallMain，两条 JVM 启动路径合并为一套内核，
 *   安装器得以像游戏运行时一样按 MC 纪元自动选 JDK（17/21/25）。
 *   详见 docs/adaptation/安装器JDK统一与JVM启动路径合并方案.md 与 JDK_ADAPTATION_GUIDE.md §5。
 *
 * 核心流程：
 * 1. 原子保留从 Fresh 到 fork 返回的窗口；fork() 创建子进程
 * 2. 子进程：先验证保留态/PID并重置，再重定向 stdout/stderr、chdir 到目标目录
 * 3. 子进程：固定真实 cwd/正确 classic 或现代库路径；jvmInit统一准备字体/locale
 * 4. 子进程：jvmSetForkChildMode(true)（跳过游戏专属 -D 与 watchdog）
 * 5. 子进程：jvmSetClasspath / jvmSetXmx / jvmSetExtraArgsList → jvmInit → jvmCallMain
 * 6. 父进程：fork 返回后立即释放保留，waitpid 等待子进程结束，返回退出码
 *
 * 日志：fork 子进程里 amcl_log 的异步文件 writer 已通过 pthread_atfork(onForkInChild)
 *   自动 no-op（g_initialized=false），故 jvmInit/jvmCallMain 内的 AMCL_LOG_* 不会因
 *   写线程已死的 mutex 而死锁；hilog 部分照常输出（真机 hilog -x 可见 processor JVM 日志）。
 *   processor 自身的 System.out/err 经 dup2 落到 logFile。
 */

#include "fork_run_java.h"
#include "jvm_launcher.h"
#include "processor_wait.h"
#include "processor_environment.h"
#include "processor_child_owner.h"
#include "update_install_lease.h"
#include "../utils/amcl_log.h"
#include <hilog/log.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <string>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "FORK_JAVA"

/**
 * 子进程入口：复用 jvmInit + jvmCallMain 启动嵌入式 JVM 并跑 main()。
 *
 * 注意：fork 后子进程里 amcl_log 文件 writer 已 no-op（见文件头注释），日志安全。
 */
static void childMain(const char* filesDir, const char* jdkVersion,
                      const char* classpath, const char* mainClass,
                      int argc, const char** argv, int xmxMb) {
    std::string javaHome = std::string(filesDir) + "/jdk/" + jdkVersion;
    // 只读当前槽的真实布局；8 的 native 库在 jre/lib/aarch64，不能把现代 lib/ 前缀
    // 写进环境后再期望 jvmInit 的搜索路径掩盖它。现有自带 fontconfig 也按同布局读取。
    const std::string classicLib = javaHome + "/jre/lib/aarch64";
    struct stat classicVm{};
    const bool classic = stat((classicLib + "/server/libjvm.so").c_str(), &classicVm) == 0 && S_ISREG(classicVm.st_mode);
    std::string jdkLib = classic ? classicLib : javaHome + "/lib";
    std::string serverLib = jdkLib + "/server";

    // 字体配置与 UTF-8 locale 统一由 jvmInit 在首次加载 native 前准备；其配置在宿主
    // 内容地址目录中，不在启动时重写或跨槽复制已认证 JDK 载荷。

    // user.dir 必须反映已经成功 chdir 后的真实绝对目录。相对 cwd 不能直接变成 Java
    // 属性，未指定 cwd 也不能继承父进程旧 AMCL_GAME_DIR；两者都按真实 getcwd 处理。
    // 缓冲逐次扩展，不另设512/8192字节限制；资源失败由子入口异常边界准确结束。
    std::vector<char> currentDirectory(256);
    while (!getcwd(currentDirectory.data(), currentDirectory.size())) {
        if (errno != ERANGE) {
            fprintf(stderr, "[FORK_JAVA] getcwd failed errno=%d\n", errno); _exit(78);
        }
        if (currentDirectory.size() > currentDirectory.max_size() / 2) throw std::bad_alloc();
        currentDirectory.resize(currentDirectory.size() * 2);
    }
    if (setenv("AMCL_GAME_DIR", currentDirectory.data(), 1) != 0) {
        fprintf(stderr, "[FORK_JAVA] AMCL_GAME_DIR environment failed errno=%d\n", errno);
        _exit(78);
    }

    /* LD_LIBRARY_PATH：serverLib / jdkLib 前置，便于依赖库 dlopen（libjvm 本体由 ELF loader 加载）。*/
    std::string ldPath = serverLib + ":" + jdkLib;
    const char* oldLd = getenv("LD_LIBRARY_PATH");
    if (oldLd && oldLd[0]) { ldPath += ":"; ldPath += oldLd; }
    if (setenv("LD_LIBRARY_PATH", ldPath.c_str(), 1) != 0) {
        fprintf(stderr, "[FORK_JAVA] LD_LIBRARY_PATH environment failed errno=%d\n", errno);
        _exit(78);
    }
    fprintf(stdout, "[FORK_JAVA] jdkVersion=%s xmx=%dMB\n", jdkVersion, xmxMb);
    fprintf(stdout, "[FORK_JAVA] LD_LIBRARY_PATH=%s\n", ldPath.c_str());

    // FontConfigManager 自身按 versioned/unversioned 名读取提供者，jvmInit 建立正确的
    // 当前槽搜索路径；这里不在配置/目录租约前提前执行库构造器，也不双重 open 同一库。

    /* 子分支已经先完成保留态/PID 验证和重置；这里仅切到 processor 的专属参数模式。 */
    jvmSetForkChildMode(1);

    /* classpath / 堆 / processor 专属额外参数 */
    jvmSetClasspath(classpath);
    jvmSetXmx(xmxMb);
    /* processor 专属：
     *   -XX:TieredStopAtLevel=1：暂保留既有 processor 编译策略，等待安全点修复后的
     *       C1/C2 因子与吞吐实测。C1 仍会参与安全点，不能把它当作信号协议替代。
     *   -Xms128m：与旧 JLI 路径一致。
     *   -Dsun.java2d.fontpath：OHOS 系统字体路径，AWT/字体相关 processor 兜底。
     * （add-opens / -XX 基础 / 编码等共享参数由 jvmInit 内的 getCommonJvmArgs() 统一下发。）*/
    std::vector<std::string> extra = {
        "-XX:TieredStopAtLevel=1",
        "-Xms128m",
        "-Dsun.java2d.fontpath=/system/fonts",
    };
    jvmSetExtraArgsList(extra);

    fprintf(stdout, "[FORK_JAVA] jvmInit...\n");
    fflush(stdout);
    int initRc = jvmInit(filesDir, jdkVersion);
    if (initRc != 0) {
        fprintf(stderr, "[FORK_JAVA] ERROR: jvmInit failed rc=%d: %s\n", initRc, jvmGetStatus());
        fflush(stderr);
        _exit(70); /* 区别于 Java 退出码：JVM 初始化失败 */
    }

    fprintf(stdout, "[FORK_JAVA] jvmCallMain %s argc=%d\n", mainClass, argc);
    fflush(stdout);
    int mainRc = jvmCallMain(mainClass, argc, argv);
    fprintf(stdout, "[FORK_JAVA] jvmCallMain returned %d (status=%s)\n", mainRc, jvmGetStatus());
    fflush(stdout);

    // main 返回不能证明线程产物和 shutdown hooks 已完成。即使 main 抛错也按标准
    // Invocation 生命周期完成非 daemon 工作；System.exit/halt 已结束进程则不会回来。
    // 本层不把无限等待伪装成成功；后续进程监督负责取消/超时，不能靠截断工作来简化。
    const int finishRc = jvmFinishProcessor();
    if (finishRc != 0) {
        fprintf(stderr, "[FORK_JAVA] VM completion failed rc=%d: %s\n", finishRc, jvmGetStatus());
        fflush(stderr);
        _exit(70);
    }
    fflush(stdout);
    fflush(stderr);
    _exit(mainRc == 0 ? 0 : 1);
}

static int runProcessor(
    const char* filesDir, const char* jdkVersion,
    const char* classpath, const char* mainClass,
    int argc, const char** argv,
    const char* workDir,
    const char* logFile, int xmxMb, amcl::jvm::ProcessorControl* control
) {
    if (control && control->stopping()) return control->finish(-1);
    // 共享租约覆盖 fork 前准入和精确 waitpid 完成。子进程继承同一 open-file-description，
    // 即使父进程被替换，仍在执行的 processor 也不会让覆盖安装获得排他租约。
    amcl::UpdateInstallReadLease fileLease(filesDir);
    if (!fileLease.acquired()) {
        AMCL_LOG_E(LOG_TAG, "processor_file_lease_rejected");
        return -8;
    }
    // 与 JVM 创建使用同一个原子状态字，不能仅先检查 Fresh 再 fork（检查后可能被抢占）。
    // 保留只覆盖 fork 的短窗口；其他 processor 遇到 -8 是暂忙，不误报必须冷重启。
    const int reservation = jvmReserveForFork();
    if (reservation != 0) {
        AMCL_LOG_E(LOG_TAG, "processor_fork_rejected reason=%{public}s rc=%{public}d",
                   reservation == -8 ? "fork_busy_retry_later" : "parent_jvm_not_fresh", reservation);
        return reservation;
    }
    // fork前的日志/输入分配也可能抛C++异常；保留态必须在异常退栈时归还，避免父进程
    // 永久停在ForkReserved。子分支按合同只会_exit，不调用父侧release析构。
    struct ForkReservationOwner {
        bool active = true;
        int release() noexcept { if (!active) return -1; active = false; return jvmReleaseForkReservation(); }
        ~ForkReservationOwner() { if (active) jvmReleaseForkReservation(); }
    } reservationOwner;
    AMCL_LOG_I(LOG_TAG, "forkRunJava (JNI_CreateJavaVM/jvmInit): jdk=%s main=%s, cp=%zu chars, xmx=%dMB",
                jdkVersion, mainClass, strlen(classpath), xmxMb);

    pid_t pid = fork();
    if (pid < 0) {
        const int forkError = errno;
        reservationOwner.release();
        AMCL_LOG_E(LOG_TAG, "fork() failed: %s", strerror(forkError));
        return -1;
    }

    // 从parent第一次可抛操作之前即持有child。退出码/状态日志出错不能把仍运行的
    // processor遗留给上层；该guard先于更早创建的文件租约析构，保证停止/回收先完成。
    amcl::jvm::PosixChildOwnership childSystem;
    amcl::jvm::ProcessorChildOwner<> childOwner(pid, childSystem);
    if (pid == 0) {
        try {
        /* 子进程第一项运行时操作：只有继承了保留态且 PID 改变才能恢复 Fresh。
         * 失败仅 write/_exit，不运行 fontconfig、ELF loader 或错误状态下的 JVM 配置。
         * 这里只封闭 HotSpot 创建与 fork 的竞争，不把整个多线程进程变成 async-signal-safe。 */
        if (jvmResetForForkChild() != 0) {
            static const char error[] = "[FORK_JAVA] invalid fork reservation; refusing inherited JVM state\n";
            const ssize_t written = write(STDERR_FILENO, error, sizeof(error) - 1);
            (void)written; // 错误日志仅尽力写出；写失败也必须保持下面的准确非零退出。
            _exit(70);
        }
        // 显式日志和 cwd 都是本次启动合同。任何一步失败均先记录原 errno 再结束；
        // 不能继续触碰 ELF/JVM，更不能在错误目录产出文件后向父进程报告成功。
        amcl::jvm::PosixProcessorIo setupSystem;
        const auto setup = amcl::jvm::PrepareProcessorIo(workDir, logFile, setupSystem);
        if (!setup.ok()) {
            amcl::jvm::ReportProcessorSetupFailure(setup);
            _exit(78); // 与已有 JVM 初始化失败 70 分开；父侧仍等真实子进程结束。
        }
        if (workDir && workDir[0]) fprintf(stdout, "[FORK_JAVA] chdir to %s\n", workDir);

        /* 运行 Java（复用 jvmInit/jvmCallMain）*/
        childMain(filesDir, jdkVersion, classpath, mainClass, argc, argv, xmxMb);
        _exit(99); /* 不应该到这里 */
        } catch (...) {
            // fork复制了NAPI worker的调用栈。任何C++异常都必须在子入口结束，不能向上
            // 退回继承的异步运行时、触碰父进程的NAPI对象或误执行complete。此处不分配。
            static const char failure[] = "[FORK_JAVA] native child initialization/execution exception; exiting 70\n";
            const ssize_t written = write(STDERR_FILENO, failure, sizeof(failure) - 1);
            (void)written; // OOM/坏stderr时不为补诊断再次分配或返回父worker栈。
            _exit(70);
        }
    }

    /* 父侧不等待 processor 结束才放锁：fork 已完成快照，后续父子状态彼此独立。
     * 保留释放失败是内部契约错误；仍回收已经创建的子进程，不能遗留 zombie。 */
    const bool released = reservationOwner.release() == 0;
    if (!released) AMCL_LOG_E(LOG_TAG, "processor_fork_release_failed");
    AMCL_LOG_I(LOG_TAG, "forkRunJava: child pid=%d, waiting...", pid);
    // errno 必须紧随 waitpid 保存；EINTR 继续等待同一个 PID，其他失败不解析初始 status=0。
    amcl::jvm::ProcessorWaitResult waited{};
    if (control) {
        amcl::jvm::PosixProcessorSupervisor system;
        const auto supervised = amcl::jvm::SuperviseProcessor(pid, *control, system);
        waited = supervised.waited;
        childOwner.observe(waited);
        if (supervised.signalError) AMCL_LOG_E(LOG_TAG,
            "processor terminate signal failed errno=%{public}d; result still requires actual wait", supervised.signalError);
    } else {
        waited = amcl::jvm::WaitForProcessor(pid, [](int64_t expectedPid, int* status, int* waitError) {
            const pid_t actualPid = waitpid(static_cast<pid_t>(expectedPid), status, 0);
            *waitError = actualPid < 0 ? errno : 0;
            return static_cast<int64_t>(actualPid);
        });
        childOwner.observe(waited);
    }
    if (!waited.reaped) {
        AMCL_LOG_E(LOG_TAG, "processor_wait_failed expected=%{public}d actual=%{public}lld errno=%{public}d (%{public}s)",
                   pid, static_cast<long long>(waited.actualPid), waited.error, strerror(waited.error));
        return released ? -1 : -7;
    }
    const int status = waited.status;

    int exitCode = -1;
    if (WIFEXITED(status)) {
        exitCode = WEXITSTATUS(status);
        AMCL_LOG_I(LOG_TAG, "forkRunJava: child exited with code %d", exitCode);
    } else if (WIFSIGNALED(status)) {
        AMCL_LOG_E(LOG_TAG, "forkRunJava: child killed by signal %d", WTERMSIG(status));
        exitCode = -128 + WTERMSIG(status);
    }

    return released ? exitCode : -7;
}

extern "C" int forkRunJavaCwd(const char* filesDir, const char* jdkVersion,
    const char* classpath, const char* mainClass, int argc, const char** argv,
    const char* workDir, const char* logFile, int xmxMb) {
    return runProcessor(filesDir, jdkVersion, classpath, mainClass, argc, argv, workDir, logFile, xmxMb, nullptr);
}

int amcl::jvm::RunControlledProcessor(const char* filesDir, const char* jdkVersion,
    const char* classpath, const char* mainClass, int argc, const char** argv,
    const char* workDir, const char* logFile, int xmxMb, ProcessorControl& control) {
    const int result = runProcessor(filesDir, jdkVersion, classpath, mainClass, argc, argv, workDir, logFile, xmxMb, &control);
    const int completion = control.finish(result);
    // fork/wait/保留身份错误没有提供“目标已回收”资格，不能被取消标记包装成正常取消完成。
    return result == -1 || result == -7 ? result : completion;
}
