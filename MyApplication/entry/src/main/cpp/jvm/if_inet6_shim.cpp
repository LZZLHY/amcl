/**
 * if_inet6_shim.cpp — 见 if_inet6_shim.h 的完整背景说明
 *
 * 方案 §四·五 R1；施工记录 §S06。
 */
#include "if_inet6_shim.h"

#include "../utils/amcl_log.h"

#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "IPV6-SHIM"

namespace {

const char *const kTargetPath = "/proc/net/if_inet6";
const char *const kEnvSwitch = "AMCL_JDK_IF_INET6_SHIM";

// ---- 合成内容的载体（R1.5：每次调用现生成，不缓存内容）----
//
// fmemopen **不复制** buffer：返回的 FILE* 在被 fclose 之前，buffer 必须一直有效。
// 三种可选做法与取舍：
//   a) 每次 malloc 一块然后不释放 —— 会随调用次数无界泄漏。
//      NetworkInterface.getNetworkInterfaces() 是 Java 侧可被循环调用的公开 API，
//      放任无界泄漏不可接受。
//   b) 额外插桩 fclose 来释放 —— 要在 loader 里再加一处插桩，且得维护"哪些流是我们造的"
//      这张表；为一个诊断级别的读路径引入两处插桩不值得。
//   c) 固定大小的静态环（本实现）—— 内存有界（8 × 4 KiB = 32 KiB），无需插桩 fclose。
//
// 选 c 的前提是"同时打开的这类流不会超过环的槽位数"。JDK 两个消费者都是
// fopen → 顺序读 → fclose 的同步短流程，实际并发度是 1；给 8 槽是余量。
// ⚠️ 前提写在这里：若将来出现长期持有该流的消费者，环会被绕回覆写，那时必须改成 b。
constexpr int kRingSlots = 8;
constexpr size_t kSlotBytes = 4096;   // 一行约 56 B ⇒ 约 70 条地址的余量

char g_ring[kRingSlots][kSlotBytes];
int g_ringNext = 0;
pthread_mutex_t g_ringLock = PTHREAD_MUTEX_INITIALIZER;

// ---- 开关（R1.7）----
// 读一次就定死：JDK 的探测发生在 JNI_OnLoad，中途改环境变量没有意义，
// 而"同一进程内两次调用给出不同答案"会让日志无法判读。
amcl::ifinet6::ShimMode g_mode = amcl::ifinet6::ShimMode::On;
bool g_modeResolved = false;
pid_t g_modePid = 0;
pthread_mutex_t g_modeLock = PTHREAD_MUTEX_INITIALIZER;

// 标记文件：存在即关闭垫片。用沙箱内视角的绝对路径 —— 应用自己看到的 filesDir 就是
// /data/storage/el2/base/haps/entry/files（启动日志里的 filesDir 与此一致）。
// 主机侧投放：
//   hdc file send -b com.amcl.launcher <本地文件> \
//       ./data/storage/el2/base/haps/entry/files/.amcl_no_if_inet6_shim
// 撤销就是删掉它（DevEco 的 Device File Browser 沙箱视图可删，或重装应用）。
const char *const kMarkerPath =
    "/data/storage/el2/base/haps/entry/files/.amcl_no_if_inet6_shim";

bool markerFilePresent() {
    return access(kMarkerPath, F_OK) == 0;
}

amcl::ifinet6::ShimMode resolveMode() {
    pthread_mutex_lock(&g_modeLock);
    // 按 pid 复位（与 §S06.6 给观测计数器加的那条同一个理由）：探针与游戏都在
    // **fork 出来的子进程**里建 JVM，而 fork 会把父进程「已解析」的结果一起继承。
    // 父进程先解析过一次，子进程就再也读不到新投放的标记文件/新写的环境变量了 ——
    // 表现是「开关明明放上去了却没反应」，而且不报错。
    const pid_t self = getpid();
    if (g_modeResolved && g_modePid != self) {
        g_modeResolved = false;
        g_mode = amcl::ifinet6::ShimMode::On;
    }
    if (!g_modeResolved) {
        const char *v = getenv(kEnvSwitch);
        // 只认显式的 "0" 为关闭；其它值（含未设置）一律按开启，避免拼写错误静默关掉修复。
        if (v != nullptr && std::strcmp(v, "0") == 0) {
            g_mode = amcl::ifinet6::ShimMode::Off;
        } else if (markerFilePresent()) {
            g_mode = amcl::ifinet6::ShimMode::Off;
        }
        // ⚠️ R1.7 原本只有环境变量一条通道，而它在真机上**按不到**（2026-08-29 实测）：
        // HarmonyOS 的应用进程不继承 `hdc shell` 的环境，也没有 UI 去设它。
        // 「声明了却关不掉的 kill switch」比没有更糟：出事时会照文档去关，关不掉还不知道为什么。
        // 所以现在有两条**都验证过可达**的通道，环境变量只作为它们的内部载体：
        //
        //   ① 用户通道：JVM marker `-Damcl.jdk.ifInet6Shim=0`，走「自定义 JVM 参数」
        //      （与 R2 偏好护栏同一条已验证通道）。mc_launcher.cpp 把它翻成本环境变量，
        //      那里是进程内唯一的写入者，形状与 MG 那批开关逐字一致。
        //   ② 排查通道：标记文件（见 kMarkerPath）。
        //
        // 关于②的一段弯路，记下来免得重走：我一度断言「标记文件也不通」，依据是
        // `hdc shell touch` 被拒、`hdc file send` 用**物理路径**新建被拒。那个结论是错的 ——
        // 漏了 `hdc file send -b <bundleName> <本地> ./data/storage/el2/base/...`：
        // `-b` 是专给 **debug 应用沙箱**的通道（API 15+，要求 module.json5 有
        // ohos.permission.INTERNET，本仓有），实测能在沙箱里**新建**文件。
        // ⇒ 判定一个通道「不可行」之前要把它的墙实际量一遍（AGENTS §二.10），而且要确认
        //    自己用的是那条路的**正确形状**（§二.11 与 §三 就是从这次教训写下来的）——
        //    我这次是拿一个错的命令形状去否证一整条路。
        g_modeResolved = true;
        g_modePid = self;
    }
    amcl::ifinet6::ShimMode m = g_mode;
    pthread_mutex_unlock(&g_modeLock);
    return m;
}

// ---- 观测行（R1.8）----
// 每种判定只打第一次 + 之后每 64 次打一次，避免 NetworkInterface 被循环调用时刷屏，
// 但仍保留"这条路径确实在被走"的单调证据（AGENTS §2.3：判据要是单调增长的计数）。
struct DecisionCounter {
    unsigned long count;
};
DecisionCounter g_counters[6] = {{0u}, {0u}, {0u}, {0u}, {0u}, {0u}};

// ⚠️ 计数器必须按进程复位（2026-08-29 真机踩到才补的）。
//
// fork 会把整块内存**连计数器一起**复制给子进程。首次真机验证时的实际后果：
// 父进程（DevTools 能力探针的 C3b）先记了一次 synthesized → hits=1；随后 Java 侧探针
// fork 出子 JVM，子进程里 libnet 真正触发的那一次 synthesize 变成 hits=2，
// 正好被 observe() 的「首次 + 每 64 次」节流吃掉 ⇒ **子进程里一行都没打**，
// 于是"垫片在 fork 出来的 JVM 里到底有没有接管"变成不可判读的
// （而 amcl_log 在子进程是刻意 no-op 的，见 fork_run_java.cpp 文件头，
//   所以子进程唯一的文件通道就是被 dup2 到 logFile 的 stdout/stderr）。
//
// ⇒ 观测面上的状态跨 fork 一律要重新判定。这与"写线程不跨 fork 继承"是同一类错误。
pid_t g_ownerPid = 0;

void resetCountersIfForked() {
    pid_t self = getpid();
    if (g_ownerPid == self) return;
    for (int i = 0; i < 6; ++i) g_counters[i].count = 0u;
    g_ownerPid = self;
}

int decisionIndex(amcl::ifinet6::ShimDecision d) {
    switch (d) {
        case amcl::ifinet6::ShimDecision::NotOurPath:        return 0;
        case amcl::ifinet6::ShimDecision::NotReadMode:       return 1;
        case amcl::ifinet6::ShimDecision::Off:               return 2;
        case amcl::ifinet6::ShimDecision::PassthroughReal:   return 3;
        case amcl::ifinet6::ShimDecision::PassthroughNoIpv6: return 4;
        case amcl::ifinet6::ShimDecision::Synthesize:        return 5;
    }
    return 0;
}

void observe(amcl::ifinet6::ShimDecision d, size_t entries, const char *extra) {
    resetCountersIfForked();
    int i = decisionIndex(d);
    unsigned long n = ++g_counters[i].count;
    if (n != 1u && (n % 64u) != 0u) return;

    const char *sep = (extra != nullptr && extra[0] != '\0') ? " " : "";
    const char *tail = (extra != nullptr) ? extra : "";
    // 带上 pid：父进程与 fork 出来的子 JVM 会写进**同一个** amcl_launcher.log，
    // 没有 pid 就分不清哪条是谁的（首次判读时正是在这里花了时间）。
    const int pid = static_cast<int>(getpid());

    AMCL_LOG_I(LOG_TAG, "pid=%d mode=%s decision=%s entries=%zu hits=%lu%s%s",
               pid, amclIfInet6ShimModeName(), amcl::ifinet6::decisionName(d),
               entries, n, sep, tail);

    // ⚠️ 为什么还要写一遍 stderr（2026-08-29 真机踩到才补的）：
    // AMCL_LOG_I 的文件那一路是**异步**写（独立日志线程），而**线程不跨 fork 继承**。
    // 垫片恰恰会在 fork 子进程里被用到（forkRunJavaCwd 起的 JVM 走同一个 ELF loader），
    // 于是子进程里排进环形缓冲的行没有写者去落盘 —— 首次真机验证时这些行**一条都没落**，
    // 「垫片到底有没有接管」在 fork 路径上变成了不可判读的。
    // forkRunJavaCwd 会把子进程的 stdout/stderr 重定向到它的 logFile，游戏主进程的
    // native stderr 也有 jvm_stderr.log 兜底 ⇒ 写 stderr 两条路都能留下痕迹。
    // 节流已在上面做过（首次 + 每 64 次），不会刷屏。
    fprintf(stderr, "[IPV6-SHIM] pid=%d mode=%s decision=%s entries=%zu hits=%lu%s%s\n",
            pid, amclIfInet6ShimModeName(), amcl::ifinet6::decisionName(d),
            entries, n, sep, tail);
    fflush(stderr);
}

// 把 sockaddr_in6 的 netmask 数成前缀长度。
unsigned int prefixLenFromMask(const struct sockaddr_in6 *mask) {
    if (mask == nullptr) return 0u;
    unsigned int bits = 0u;
    for (int i = 0; i < 16; ++i) {
        unsigned char b = mask->sin6_addr.s6_addr[i];
        if (b == 0xffu) {
            bits += 8u;
            continue;
        }
        while ((b & 0x80u) != 0u) {
            bits++;
            b = static_cast<unsigned char>(b << 1);
        }
        break;
    }
    return bits;
}

} // namespace

namespace amcl {
namespace ifinet6 {

std::size_t collectLocalEntries(std::vector<Entry> &out) {
    out.clear();
    struct ifaddrs *head = nullptr;
    if (getifaddrs(&head) != 0) {
        return 0u;
    }
    for (struct ifaddrs *ifa = head; ifa != nullptr; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr == nullptr) continue;
        if (ifa->ifa_addr->sa_family != AF_INET6) continue;

        const struct sockaddr_in6 *sin6 =
            reinterpret_cast<const struct sockaddr_in6 *>(ifa->ifa_addr);
        Entry e;
        std::memcpy(e.addr, sin6->sin6_addr.s6_addr, 16);
        e.ifIndex = (ifa->ifa_name != nullptr) ? if_nametoindex(ifa->ifa_name) : 0u;
        e.prefixLen = prefixLenFromMask(
            reinterpret_cast<const struct sockaddr_in6 *>(ifa->ifa_netmask));
        e.scope = scopeForAddr(e.addr);
        e.flags = kFlagsPlaceholder;
        std::snprintf(e.name, sizeof(e.name), "%s",
                      (ifa->ifa_name != nullptr) ? ifa->ifa_name : "?");
        out.push_back(e);
    }
    freeifaddrs(head);
    return out.size();
}

} // namespace ifinet6
} // namespace amcl

extern "C" {

const char *amclIfInet6ShimModeName(void) {
    return (resolveMode() == amcl::ifinet6::ShimMode::Off) ? "off" : "on";
}

FILE *amclIfInet6ShimOpen(const char *path, const char *mode) {
    // R1.1：只拦精确路径。这里先做最便宜的判断，绝大多数 fopen 在此原路返回。
    if (path == nullptr || std::strcmp(path, kTargetPath) != 0) {
        return nullptr;   // 不打日志：这是热路径，JDK 的每次 fopen 都会经过
    }

    const bool readOnly = amcl::ifinet6::isReadOnlyMode(mode);
    const amcl::ifinet6::ShimMode m = resolveMode();

    // R1.2：真文件优先。平台放开之后垫片自动退场。
    FILE *real = fopen(path, mode);
    const bool realOk = (real != nullptr);

    // 先按不需要枚举地址的分支判一次，避免无谓地调 getifaddrs。
    amcl::ifinet6::ShimDecision d =
        amcl::ifinet6::decide(true, readOnly, m, realOk, /*entryCount=*/1u);
    if (d != amcl::ifinet6::ShimDecision::Synthesize) {
        observe(d, 0u, nullptr);
        return realOk ? real : nullptr;   // 非 Synthesize 一律回落（realOk 时就是真文件流）
    }

    // 到这里：路径命中、只读、开关开、真文件打不开 ⇒ 才去问"本机到底有没有 IPv6"
    std::vector<amcl::ifinet6::Entry> entries;
    const size_t n = amcl::ifinet6::collectLocalEntries(entries);
    d = amcl::ifinet6::decide(true, readOnly, m, realOk, n);
    if (d != amcl::ifinet6::ShimDecision::Synthesize) {
        // R1.4：没有任何 IPv6 地址 —— 不造假，维持今天的行为
        observe(d, n, nullptr);
        return nullptr;
    }

    const std::string text = amcl::ifinet6::formatFile(entries);
    if (text.empty() || text.size() >= kSlotBytes) {
        // R1.6：装不下就 fail-safe 回落，不截断（截断会产出一条残行喂给 fscanf）
        observe(d, n, "note=too-large-fallback");
        return nullptr;
    }

    pthread_mutex_lock(&g_ringLock);
    char *slot = g_ring[g_ringNext];
    g_ringNext = (g_ringNext + 1) % kRingSlots;
    std::memcpy(slot, text.data(), text.size());
    slot[text.size()] = '\0';
    pthread_mutex_unlock(&g_ringLock);

    FILE *mem = fmemopen(slot, text.size(), "r");
    if (mem == nullptr) {
        observe(d, n, "note=fmemopen-failed-fallback");
        return nullptr;   // R1.6
    }
    observe(d, n, nullptr);
    return mem;
}

} // extern "C"
