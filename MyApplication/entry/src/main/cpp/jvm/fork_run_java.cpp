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
 * 3. 子进程：设置字体/locale/库路径环境 + 预加载 fontconfig stub
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
#include "../utils/amcl_log.h"
#include <hilog/log.h>
#include <dlfcn.h>
#include <unistd.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "FORK_JAVA"

/* ELF loader API（fontconfig stub 预加载用；libjvm 由 jvmInit 内部经 ELF loader 加载）*/
extern "C" {
    void* elf_open(const char* path);
}

/**
 * 子进程入口：复用 jvmInit + jvmCallMain 启动嵌入式 JVM 并跑 main()。
 *
 * 注意：fork 后子进程里 amcl_log 文件 writer 已 no-op（见文件头注释），日志安全。
 */
static void childMain(const char* filesDir, const char* jdkVersion,
                      const char* classpath, const char* mainClass,
                      int argc, const char** argv, int xmxMb,
                      const char* workDir) {
    std::string javaHome = std::string(filesDir) + "/jdk/" + jdkVersion;
    std::string jdkLib = javaHome + "/lib";
    std::string serverLib = jdkLib + "/server";

    /* 字体 / locale 环境（与主进程一致；jvmInit 自身只钉 LC_ALL/LANG，这里补 FONTCONFIG）。
     * 中文路径修复：把 locale 钉成 UTF-8，让 sun.jnu.encoding 经 CODESET 推断为 UTF-8，
     * 避免 musl 默认 "C" locale 损坏含中文的 .minecraft / 版本目录路径。 */
    setenv("FONTCONFIG_PATH", filesDir, 1);
    setenv("FONTCONFIG_FILE", (std::string(filesDir) + "/fonts.conf").c_str(), 1);
    setenv("LC_ALL", "en_US.UTF-8", 1);
    setenv("LANG", "en_US.UTF-8", 1);

    /* user.home/user.dir = 工作目录：jvmInit 优先读 AMCL_GAME_DIR 设这两个属性。processor
     * 全用绝对路径，但设为 mcDir 与旧 JLI（无 -Duser.dir → JVM 取 getcwd=workDir）行为一致最稳。*/
    if (workDir && workDir[0]) {
        setenv("AMCL_GAME_DIR", workDir, 1);
    }

    /* LD_LIBRARY_PATH：serverLib / jdkLib 前置，便于依赖库 dlopen（libjvm 本体由 ELF loader 加载）。*/
    std::string ldPath = serverLib + ":" + jdkLib;
    const char* oldLd = getenv("LD_LIBRARY_PATH");
    if (oldLd && oldLd[0]) { ldPath += ":"; ldPath += oldLd; }
    setenv("LD_LIBRARY_PATH", ldPath.c_str(), 1);
    fprintf(stdout, "[FORK_JAVA] jdkVersion=%s xmx=%dMB\n", jdkVersion, xmxMb);
    fprintf(stdout, "[FORK_JAVA] LD_LIBRARY_PATH=%s\n", ldPath.c_str());

    /* 预加载 fontconfig stub（jvmInit 不负责；processor 多为 headless 构建工具，防御性保留）。*/
    std::string fcPath = jdkLib + "/libfontconfig.so.1";
    void* fcDl = dlopen(fcPath.c_str(), RTLD_NOW | RTLD_GLOBAL);
    fprintf(stdout, "[FORK_JAVA] dlopen fontconfig: %s\n", fcDl ? "OK" : (dlerror() ? dlerror() : "fail"));
    elf_open(fcPath.c_str());

    /* 子分支已经先完成保留态/PID 验证和重置；这里仅切到 processor 的专属参数模式。 */
    jvmSetForkChildMode(1);

    /* classpath / 堆 / processor 专属额外参数 */
    jvmSetClasspath(classpath);
    jvmSetXmx(xmxMb);
    /* processor 专属：
     *   -XX:TieredStopAtLevel=1：用 C1 编译（比纯解释 -Xint 快 5-10×且安全，不涉及
     *       speculative opt / SIGSEGV safepoint），避免 BinaryPatcher/ART 等 processor 极慢。
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

    /* jvmCallMain：0=main 正常返回，-1=main 抛异常。processor 若 System.exit(n) 则进程已直接
     * 退出 n（不回到这里）。映射为 shell 退出码（0..255）：成功 0，异常 1。
     * 不调 jvmDestroy（DestroyJavaVM 会等非守护线程，可能挂起）；产物已落盘，直接 _exit。*/
    _exit(mainRc == 0 ? 0 : 1);
}

extern "C" int forkRunJavaCwd(
    const char* filesDir, const char* jdkVersion,
    const char* classpath, const char* mainClass,
    int argc, const char** argv,
    const char* workDir,
    const char* logFile, int xmxMb
) {
    // 与 JVM 创建使用同一个原子状态字，不能仅先检查 Fresh 再 fork（检查后可能被抢占）。
    // 保留只覆盖 fork 的短窗口；其他 processor 遇到 -8 是暂忙，不误报必须冷重启。
    const int reservation = jvmReserveForFork();
    if (reservation != 0) {
        AMCL_LOG_E(LOG_TAG, "processor_fork_rejected reason=%{public}s rc=%{public}d",
                   reservation == -8 ? "fork_busy_retry_later" : "parent_jvm_not_fresh", reservation);
        return reservation;
    }
    AMCL_LOG_I(LOG_TAG, "forkRunJava (JNI_CreateJavaVM/jvmInit): jdk=%s main=%s, cp=%zu chars, xmx=%dMB",
                jdkVersion, mainClass, strlen(classpath), xmxMb);

    pid_t pid = fork();
    if (pid < 0) {
        const int forkError = errno;
        jvmReleaseForkReservation();
        AMCL_LOG_E(LOG_TAG, "fork() failed: %s", strerror(forkError));
        return -1;
    }

    if (pid == 0) {
        /* 子进程第一项运行时操作：只有继承了保留态且 PID 改变才能恢复 Fresh。
         * 失败仅 write/_exit，不运行 fontconfig、ELF loader 或错误状态下的 JVM 配置。
         * 这里只封闭 HotSpot 创建与 fork 的竞争，不把整个多线程进程变成 async-signal-safe。 */
        if (jvmResetForForkChild() != 0) {
            static const char error[] = "[FORK_JAVA] invalid fork reservation; refusing inherited JVM state\n";
            write(STDERR_FILENO, error, sizeof(error) - 1);
            _exit(70);
        }
        /* 重定向 stdout/stderr 到日志文件 */
        if (logFile) {
            int fd = open(logFile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) {
                dup2(fd, STDOUT_FILENO);
                dup2(fd, STDERR_FILENO);
                close(fd);
            }
        }

        /* chdir 到显式工作目录（installer 在当前目录写日志等；processor 用绝对路径，
         * cwd 设为 mcDir 最稳）。workDir 为空则不切。 */
        if (workDir && workDir[0]) {
            chdir(workDir);
            fprintf(stdout, "[FORK_JAVA] chdir to %s\n", workDir);
        }

        /* 运行 Java（复用 jvmInit/jvmCallMain）*/
        childMain(filesDir, jdkVersion, classpath, mainClass, argc, argv, xmxMb, workDir);
        _exit(99); /* 不应该到这里 */
    }

    /* 父侧不等待 processor 结束才放锁：fork 已完成快照，后续父子状态彼此独立。
     * 保留释放失败是内部契约错误；仍回收已经创建的子进程，不能遗留 zombie。 */
    const bool released = jvmReleaseForkReservation() == 0;
    if (!released) AMCL_LOG_E(LOG_TAG, "processor_fork_release_failed");
    AMCL_LOG_I(LOG_TAG, "forkRunJava: child pid=%d, waiting...", pid);
    // errno 必须紧随 waitpid 保存；EINTR 继续等待同一个 PID，其他失败不解析初始 status=0。
    const auto waited = amcl::jvm::WaitForProcessor(pid, [](int64_t expectedPid, int* status, int* waitError) {
        const pid_t actualPid = waitpid(static_cast<pid_t>(expectedPid), status, 0);
        *waitError = actualPid < 0 ? errno : 0;
        return static_cast<int64_t>(actualPid);
    });
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
