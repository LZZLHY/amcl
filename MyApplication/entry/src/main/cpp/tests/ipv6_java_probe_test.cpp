//
// ipv6_java_probe_test.cpp — Java 侧 IPv6 诊断的驱动（Phase 0 · P0-b / Q5）
//
// 方案：docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §3 P0-b
// 施工记录：docs/refactor/JDK-IPv6施工记录.md
//
// ============================================================================
// 它做什么 / 不做什么
// ============================================================================
// 它只负责**把 com.amcl.launcher.Ipv6Diagnostics 跑起来并把输出取回来**。
// 判据全在那个 Java 类里（那样才能读到 Java 层真正观测到的东西）。
//
// ⚠️ 只观测。不安装插桩、不改 JDK、不写任何东西到 JDK 目录。
//
// ============================================================================
// 为什么 fork 子进程，而不是在应用进程里建 JVM
// ============================================================================
// 应用进程里也能建 JVM（DevTools 的「JVM 嵌入」就是），但那有两个问题：
//   1. 一个进程只能 JNI_CreateJavaVM 一次 —— 建过之后 classpath 再也改不了，
//      而这个诊断希望能反复跑、并且与游戏进程的 JVM 状态完全无关；
//   2. 诊断不应该给应用进程留下一个常驻 JVM（信号链、堆、线程都留下了）。
// forkRunJavaCwd 是本仓给 Forge/NeoForge 各 processor 用的成熟路径：
// fork → ELF loader 载 libjvm → JNI_CreateJavaVM → 跑 main → 子进程退出。
// 子进程崩了也只是子进程崩，应用不受影响 —— 对一个要去踩地址族边界的诊断正合适。
//
// ============================================================================
// 前置条件
// ============================================================================
// 需要 filesDir/amcl-launcher.jar（Ipv6Diagnostics 就打在这个 jar 里）。
// 它由 McGamePage 在每次启动游戏前从 rawfile 解出来，所以**装完新版后至少启动过一次
// 游戏**才会有；缺失时本探针会明确报出来，而不是给一个含糊的失败。
//
#include "../jvm/fork_run_java.h"
#include "../utils/amcl_log.h"

#include <hilog/log.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "IPV6_JAVA"

namespace {

const char *const kMainClass = "com.amcl.launcher.Ipv6Diagnostics";
// RFC 3849 文档保留前缀：保证不可路由，不会真碰到任何主机。
const char *const kDefaultAddr = "2001:db8::1";
const char *const kDefaultPort = "25565";

std::string g_report;

bool fileExists(const std::string &p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && st.st_size > 0;
}

// 找一个已安装的 JDK。顺序按"新到旧"：设备上通常装的是最新那个。
// 模块化布局（17/21/25）与经典布局（8）各查一处标志文件。
std::string detectJdkVersion(const std::string &filesDir, std::string *layoutOut) {
    const char *cands[] = {"25", "21", "17", "8", nullptr};
    for (int i = 0; cands[i]; ++i) {
        std::string base = filesDir + "/jdk/" + cands[i];
        if (fileExists(base + "/lib/server/libjvm.so")) {
            *layoutOut = "modular";
            return cands[i];
        }
        if (fileExists(base + "/jre/lib/aarch64/server/libjvm.so")) {
            *layoutOut = "classic";
            return cands[i];
        }
    }
    *layoutOut = "";
    return "";
}

std::string readAll(const std::string &path) {
    FILE *f = fopen(path.c_str(), "rb");
    if (f == nullptr) return std::string();
    std::string out;
    char buf[4096];
    size_t n = 0;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        out.append(buf, n);
    }
    fclose(f);
    return out;
}

// 每行都进 hilog + amcl_log，和 native 侧探针保持同一套取证方式
// （tag=IPV6_JAVA，方便事后从 amcl_launcher.log 里整段捞出来）。
void emit(std::string &sink, const std::string &line) {
    sink += line;
    sink += "\n";
    OH_LOG_INFO(LOG_APP, "[IPV6_JAVA] %{public}s", line.c_str());
    amclLogWrite(AMCL_LOG_LEVEL_INFO, LOG_TAG, "%s", line.c_str());
}

} // namespace

extern "C" {

const char *runIpv6JavaProbe(const char *filesDirC, const char *testAddrC) {
    std::string sink;
    std::string filesDir = (filesDirC != nullptr) ? filesDirC : "";
    std::string testAddr = (testAddrC != nullptr && testAddrC[0] != '\0') ? testAddrC : kDefaultAddr;

    emit(sink, "========================================");
    emit(sink, "Java 侧 IPv6 诊断驱动 (Phase 0 · P0-b / Q5)");
    emit(sink, "方案: docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §3 P0-b");
    emit(sink, "⚠️ 只观测：不安装插桩、不改 JDK");
    emit(sink, "========================================");

    if (filesDir.empty()) {
        emit(sink, "❌ filesDir 为空，无法继续");
        g_report = sink;
        return g_report.c_str();
    }

    std::string layout;
    std::string ver = detectJdkVersion(filesDir, &layout);
    if (ver.empty()) {
        emit(sink, "❌ 没找到已安装的 JDK（查过 25/21/17/8 两种布局）");
        emit(sink, "   请先在「设置 → JDK 管理」装一个 JDK 再跑本探针。");
        g_report = sink;
        return g_report.c_str();
    }
    emit(sink, "JDK 版本 = " + ver + "（" + layout + " 布局）");

    std::string jar = filesDir + "/amcl-launcher.jar";
    if (!fileExists(jar)) {
        emit(sink, "❌ 缺少 " + jar);
        emit(sink, "   Ipv6Diagnostics 打在 amcl-launcher.jar 里，而该 jar 由 McGamePage 在");
        emit(sink, "   启动游戏前从 rawfile 解出。装完新版后**先启动过一次游戏**再跑本探针。");
        g_report = sink;
        return g_report.c_str();
    }
    emit(sink, "classpath = " + jar);
    emit(sink, "主类      = " + std::string(kMainClass));
    emit(sink, "测试地址  = [" + testAddr + "]:" + kDefaultPort
                   + "  （RFC 3849 文档前缀，永不可路由）");

    // 每次跑之前清掉旧日志，确保读回来的就是**这一次**的输出。
    std::string logFile = filesDir + "/logs/ipv6-java-probe.log";
    unlink(logFile.c_str());

    std::vector<const char *> argv;
    argv.push_back(testAddr.c_str());
    argv.push_back(kDefaultPort);

    emit(sink, "");
    emit(sink, "正在 fork 子进程建 JVM…（首次约数秒，期间界面会短暂无响应）");
    amclLogFlush();

    int rc = forkRunJavaCwd(filesDir.c_str(), ver.c_str(), jar.c_str(), kMainClass,
                            static_cast<int>(argv.size()), argv.data(),
                            nullptr, logFile.c_str(), 128);

    emit(sink, "子进程退出码 = " + std::to_string(rc)
                   + (rc == 0 ? "（正常）" : rc == -1 ? "（fork 失败）"
                      : rc == -2 ? "（JVM 创建失败）" : "（Java 侧非零退出）"));
    emit(sink, "");
    emit(sink, "---- 子进程输出（" + logFile + "）----");

    std::string child = readAll(logFile);
    if (child.empty()) {
        emit(sink, "（空 —— 子进程没有产生输出，多半是 JVM 没起来；见 hilog tag=FORK_JAVA）");
    } else {
        // 逐行 emit，让每一行都进 amcl_log，事后可整段捞取
        size_t start = 0;
        while (start < child.size()) {
            size_t nl = child.find('\n', start);
            if (nl == std::string::npos) nl = child.size();
            std::string line = child.substr(start, nl - start);
            while (!line.empty() && (line.back() == '\r')) line.pop_back();
            emit(sink, line);
            start = nl + 1;
        }
    }

    emit(sink, "========================================");
    emit(sink, "判读要点：");
    emit(sink, "  C 段 channelFamily=INET  ⇒ Net.isIPv6Available() == false（与 native 判据一致）");
    emit(sink, "  D 段抛 UnsupportedAddressTypeException 且 message=<null>");
    emit(sink, "      ⇒ 这就是 Q5 的现场证据，也是 Minecraft 二次 NPE 的原料");
    emit(sink, "  G 段 IPv6 地址 0 条 ⇒ 第二个消费者（NetworkInterface）的基线");
    emit(sink, "  修复后复跑：C 段应变 INET6、D 段应不再抛地址族异常（改为 pending 后超时）");
    emit(sink, "Java 侧 IPv6 诊断驱动完成");
    emit(sink, "========================================");
    amclLogFlush();

    g_report = sink;
    return g_report.c_str();
}

} // extern "C"
