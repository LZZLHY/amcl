/**
 * if_inet6_shim.cpp — 见 if_inet6_shim.h 的完整背景说明
 *
 * 方案 §四·五 R1；施工记录 §S06。
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "if_inet6_shim.h"
#include "../platform/owned_read_stream.h"

#include "../utils/amcl_log.h"

#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <atomic>
#include <memory>
#include <cerrno>
#include <cstdint>
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

// 每次打开由 owned_read_stream 持有独立不可变快照，fclose 自动释放。
// 没有容量为八的共享环，也没有在 fork 子进程中可能继承锁定态的流注册表。

// ---- 开关（R1.7）----
// 读一次就定死：JDK 的探测发生在 JNI_OnLoad，中途改环境变量没有意义，
// 而"同一进程内两次调用给出不同答案"会让日志无法判读。
// 上 32 位记录真实 PID，下 32 位为 1(on)/2(off)。一次原子发布完整状态，
// fork 继承旧 PID 后重新解析；不存在被其他线程持有且在子进程永久锁死的 mutex。
static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "fork-safe state requires lock-free 64-bit atomics");
std::atomic<unsigned long long> g_modeState{0};

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
    const auto tag = static_cast<unsigned long long>(static_cast<uint32_t>(getpid())) << 32;
    auto state = g_modeState.load(std::memory_order_acquire);
    if ((state & 0xffffffff00000000ULL) != tag || (state & 0xffffffffULL) == 0) {
        // 启动参数写环境发生在启动 JVM 之前；第一次读取后维持本进程的稳定策略。
        const char* value = getenv(kEnvSwitch);
        const bool disabled = (value && std::strcmp(value, "0") == 0) || markerFilePresent();
        state = tag | (disabled ? 2ULL : 1ULL);
        g_modeState.store(state, std::memory_order_release);
    }
    return (state & 0xffffffffULL) == 2 ? amcl::ifinet6::ShimMode::Off : amcl::ifinet6::ShimMode::On;
}

// ---- 观测行（R1.8）----
// 每种判定只打第一次 + 之后每 64 次打一次，避免 NetworkInterface 被循环调用时刷屏，
// 但仍保留"这条路径确实在被走"的单调证据（AGENTS §2.3：判据要是单调增长的计数）。
std::atomic<unsigned long long> g_counters[6]{};

// PID 与计数同一次 CAS 发布，避免并发 reset 抹掉另一个线程的增量。
// 计数到 32 位上限后饱和，不回绕成“首次”；不影响任何文件或网络行为。
unsigned long nextCount(int index) {
    const auto tag = static_cast<unsigned long long>(static_cast<uint32_t>(getpid())) << 32;
    auto previous = g_counters[index].load(std::memory_order_relaxed);
    for (;;) {
        unsigned long long count = (previous & 0xffffffff00000000ULL) == tag
            ? previous & 0xffffffffULL : 0;
        if (count < 0xffffffffULL) ++count;
        if (g_counters[index].compare_exchange_weak(previous, tag | count,
                std::memory_order_relaxed)) return static_cast<unsigned long>(count);
    }
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
    unsigned long n = nextCount(decisionIndex(d));
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
    // vector 扩容失败时也释放平台地址表，异常交给打开边界转成 ENOMEM。
    std::unique_ptr<ifaddrs, decltype(&freeifaddrs)> owner(head, freeifaddrs);
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
    return out.size();
}

} // namespace ifinet6
} // namespace amcl

extern "C" {

const char *amclIfInet6ShimModeName(void) {
    return (resolveMode() == amcl::ifinet6::ShimMode::Off) ? "off" : "on";
}

FILE *amclIfInet6ShimOpen(const char *path, const char *mode) try {
    // R1.1：只拦精确路径。这里先做最便宜的判断，绝大多数 fopen 在此原路返回。
    if (path == nullptr || std::strcmp(path, kTargetPath) != 0) {
        return nullptr;   // 不打日志：这是热路径，JDK 的每次 fopen 都会经过
    }

    const bool readOnly = amcl::ifinet6::isReadOnlyMode(mode);
    const amcl::ifinet6::ShimMode m = resolveMode();

    // R1.2：真文件优先。平台放开之后垫片自动退场。
    FILE *real = fopen(path, mode);
    const int realError = errno;
    const bool realOk = (real != nullptr);
    // 只补沙箱的权限性观测缺口；ENOENT/EIO/EMFILE 等必须保留其真实失败。
    if (!realOk && realError != EACCES && realError != EPERM) {
        errno = realError;
        return nullptr;
    }

    // 先按不需要枚举地址的分支判一次，避免无谓地调 getifaddrs。
    amcl::ifinet6::ShimDecision d =
        amcl::ifinet6::decide(true, readOnly, m, realOk, /*entryCount=*/1u);
    if (d != amcl::ifinet6::ShimDecision::Synthesize) {
        observe(d, 0u, nullptr);
        if (!realOk) errno = realError;
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
    FILE* stream = amcl::ifinet6::openOwnedReadStream(text.data(), text.size());
    const int error = errno;
    observe(d, n, stream ? nullptr : "note=owned-stream-failed");
    if (!stream) errno = error;
    return stream;
} catch (const std::bad_alloc&) {
    // C 边界不允许 C++ 分配异常穿过 fopen 调用方。
    errno = ENOMEM;
    return nullptr;
}

} // extern "C"
