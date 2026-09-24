//
// ipv6_probe_test.cpp — JDK IPv6 能力探针（Phase 0 诊断）
//
// 方案出处：docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §3 P0-a
// 施工记录：docs/refactor/JDK-IPv6施工记录.md
//
// ============================================================================
// 这个探针要回答什么
// ============================================================================
// 用户报告"加入服务器填 IPv6 会失败、且像崩溃"。静态审查给出的推断是：AMCL 携带的
// OpenJDK 在 HarmonyOS 沙箱里把 IPv6 判成不可用 → NIO 建出 IPv4-only channel →
// 连 Inet6Address 抛 UnsupportedAddressTypeException。
//
// ⚠️ 那是**推断**。按 AGENTS.md §2.1「推断出的成因不得直接拿去改代码」，
//    先把它变成一个可以数的数，再决定改不改、改哪。本探针就是那个"数"。
//
// ============================================================================
// 判据不是一个，是四个 —— 这正是本探针存在的理由
// ============================================================================
// `IPv6_supported()`（libnet，JNI_OnLoad 期缓存，决定 sun.nio.ch.Net.isIPv6Available()）
// 是**四条 AND**，任意一条不成立就返回 JNI_FALSE。上游源码逐条核实：
//
//   C1  socket(AF_INET6, SOCK_STREAM, 0) >= 0
//   C2  getsockname(fd 0) 若成功且 sa_family == AF_INET → 判 false
//       （inetd/xinetd 场景的保护。⚠️ **只有 JDK 17 有这条**，21/25 已删除）
//   C3  fopen("/proc/net/if_inet6") 成功 **且** 一次 fgets 拿到非空行
//       （上游注释原话：不需要解析内容，只要一个"有 IPv6"的指示）
//   C4  dlsym(RTLD_DEFAULT, "inet_pton") != NULL
//
// 四条合并成一个 boolean 之后，到了真机就查不下去 —— 这正是 AGENTS.md §2.9 那条
// 「一个错误码把 N 个成因合并成一个值」的形状。所以这里**逐条单独测量并单独打印**，
// 再按 17 与 21/25 两套判据分别给出复现结论。
//
// ============================================================================
// 为什么必须跑在应用进程里
// ============================================================================
// 不能用 `hdc shell cat /proc/net/if_inet6` 代替：shell 身份是 uid=2000(shell)
// context=u:r:sh:s0，与应用进程是两个 SELinux 域。本仓在 SDL3 C2 那一轮已经为
// 「shell 域测的结论不可迁移到应用域」付过学费（CHANGELOG 1000468）。
//
// ============================================================================
// 只观测，不改变行为
// ============================================================================
// 本探针不安装任何插桩、不改 JDK、不写任何文件到 JDK 目录。第 5 层的"合成预演"
// 只是把 getifaddrs 的结果按内核格式打印出来看，用于判断路线 B 的数据来源够不够，
// **不会被任何人读取**。
//
// 每输出一行就即时写 hilog + amcl_log 文件：C1/C4 涉及 socket 与 dlsym，
// 万一某层把进程弄挂，前面的结论已经落盘。
// 注意不走 AMCL_LOG_I 宏 —— 那个宏 fmt 里的 %s 没带 {public}，hilog 会打成 <private>。
//
#include "../jvm/if_inet6_shim.h"        // collectLocalEntries：与出货垫片同一份收集逻辑
#include "../platform/if_inet6_synth.h"

#include "../utils/amcl_log.h"

#include <arpa/inet.h>
#include <dirent.h>
#include <dlfcn.h>
#include <hilog/log.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "IPV6_PROBE"

namespace {

const char *const kIfInet6Path = "/proc/net/if_inet6";
// Android 上 /proc/net 是指向 /proc/self/net 的符号链接，某些沙箱策略下后者可读而
// 前者不可读。若这里成立，路线 B 可以退化成"只改路径"，比合成内容更轻。
const char *const kIfInet6SelfPath = "/proc/self/net/if_inet6";
// 阳性对照：本仓多处已实证应用进程可读（stack_sampler / jvm_test / sdl3_c2_test）。
// 按 AGENTS.md §2.8，判定"有没有"的工具本身要先在已知为真的样本上验证过。
const char *const kPositiveControlPath = "/proc/self/maps";

std::string g_report;

class Reporter {
public:
    void line(const std::string &s) {
        ss_ << s << "\n";
        OH_LOG_INFO(LOG_APP, "[IPV6_PROBE] %{public}s", s.c_str());
        amclLogWrite(AMCL_LOG_LEVEL_INFO, LOG_TAG, "%s", s.c_str());
    }

    void linef(const char *fmt, ...) {
        char buf[1024];
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        line(buf);
    }

    std::string str() const { return ss_.str(); }

private:
    std::ostringstream ss_;
};

// fopen + 一次 fgets 的结果。刻意与上游 C3 的判据逐字对应。
struct FgetsProbe {
    bool openOk = false;
    int  openErrno = 0;
    bool firstLineOk = false;   // fgets 返回非 NULL
    int  fgetsErrno = 0;
    int  totalLines = 0;        // 继续读完，用于报告；上游只看第一行
    std::string firstLine;
};

FgetsProbe probeFgets(const char *path) {
    FgetsProbe p;
    errno = 0;
    FILE *fp = fopen(path, "r");
    if (fp == nullptr) {
        p.openErrno = errno;
        return p;
    }
    p.openOk = true;

    char buf[255];
    errno = 0;
    char *bufP = fgets(buf, sizeof(buf), fp);
    if (bufP == nullptr) {
        p.fgetsErrno = errno;
    } else {
        p.firstLineOk = true;
        p.totalLines = 1;
        std::string first(buf);
        while (!first.empty() && (first.back() == '\n' || first.back() == '\r')) {
            first.pop_back();
        }
        p.firstLine = first;
        while (fgets(buf, sizeof(buf), fp) != nullptr) {
            p.totalLines++;
        }
    }
    fclose(fp);
    return p;
}

// ⚠️ 这里原本有一份 prefixLenFromMask。它已随 collectLocalEntries 一起搬到出货侧
// （jvm/if_inet6_shim.cpp）—— 探针与垫片必须用**同一份**收集逻辑，否则"预演"就不算预演。

std::string addrToText(const unsigned char addr[16]) {
    char txt[INET6_ADDRSTRLEN];
    struct in6_addr a;
    std::memcpy(a.s6_addr, addr, 16);
    if (inet_ntop(AF_INET6, &a, txt, sizeof(txt)) == nullptr) {
        return std::string("<inet_ntop failed>");
    }
    return std::string(txt);
}

const char *scopeName(unsigned int scope) {
    switch (scope) {
        case 0x00u: return "global";
        case 0x10u: return "host";
        case 0x20u: return "link";
        case 0x40u: return "site";
        default:    return "other";
    }
}

// ============================================================
//  后果面测量用的小工具
// ============================================================
//
// 全部只在**本机回环与设备自身地址**上收发，不出设备、不需要任何外部服务器。
// 这是为了让「翻 true 之后 IPv4 还能不能用」这件事在没有 IPv6 服务器的条件下也可判定。

// Linux 的 IP_MULTICAST_ALL。musl 头不一定给，故自带常量（值与内核一致）。
// 上游 Net.socket0 对 SOCK_DGRAM 会以 IPPROTO_IPV6 为 level 设这个选项。
constexpr int kIpMulticastAll = 49;

// 建一个 AF_INET6 listener。bindAddr 为 nullptr 表示 in6addr_any。
// 返回 fd（失败 -1），端口经 outPort 回传。
int makeListener6(Reporter &r, bool clearV6Only, const unsigned char *bindAddr, int *outPort) {
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) {
        r.linef("    socket(AF_INET6) 失败 errno=%d (%s)", errno, strerror(errno));
        return -1;
    }
    if (clearV6Only) {
        int zero = 0;
        if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof(int)) < 0) {
            r.linef("    setsockopt(IPV6_V6ONLY,0) 失败 errno=%d (%s)", errno, strerror(errno));
            close(fd);
            return -1;
        }
    }
    struct sockaddr_in6 a;
    std::memset(&a, 0, sizeof(a));
    a.sin6_family = AF_INET6;
    a.sin6_port = 0;
    if (bindAddr != nullptr) {
        std::memcpy(a.sin6_addr.s6_addr, bindAddr, 16);
    } else {
        a.sin6_addr = in6addr_any;
    }
    if (bind(fd, reinterpret_cast<struct sockaddr *>(&a), sizeof(a)) < 0) {
        r.linef("    bind 失败 errno=%d (%s)", errno, strerror(errno));
        close(fd);
        return -1;
    }
    if (listen(fd, 1) < 0) {
        r.linef("    listen 失败 errno=%d (%s)", errno, strerror(errno));
        close(fd);
        return -1;
    }
    struct sockaddr_in6 got;
    socklen_t glen = sizeof(got);
    std::memset(&got, 0, sizeof(got));
    if (getsockname(fd, reinterpret_cast<struct sockaddr *>(&got), &glen) < 0) {
        r.linef("    getsockname 失败 errno=%d", errno);
        close(fd);
        return -1;
    }
    *outPort = static_cast<int>(ntohs(got.sin6_port));
    return fd;
}

// 建一个 AF_INET listener，绑 127.0.0.1。
int makeListener4(Reporter &r, int *outPort) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        r.linef("    socket(AF_INET) 失败 errno=%d (%s)", errno, strerror(errno));
        return -1;
    }
    struct sockaddr_in a;
    std::memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = 0;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, reinterpret_cast<struct sockaddr *>(&a), sizeof(a)) < 0) {
        r.linef("    bind(127.0.0.1) 失败 errno=%d (%s)", errno, strerror(errno));
        close(fd);
        return -1;
    }
    if (listen(fd, 1) < 0) {
        r.linef("    listen 失败 errno=%d (%s)", errno, strerror(errno));
        close(fd);
        return -1;
    }
    struct sockaddr_in got;
    socklen_t glen = sizeof(got);
    std::memset(&got, 0, sizeof(got));
    if (getsockname(fd, reinterpret_cast<struct sockaddr *>(&got), &glen) < 0) {
        r.linef("    getsockname 失败 errno=%d", errno);
        close(fd);
        return -1;
    }
    *outPort = static_cast<int>(ntohs(got.sin_port));
    return fd;
}

// 在 timeoutMs 内等一个连接进来。只在回环上用，正常应当立刻返回。
bool acceptWithin(int srv, int timeoutMs) {
    struct pollfd p;
    p.fd = srv;
    p.events = POLLIN;
    p.revents = 0;
    int rc = poll(&p, 1, timeoutMs);
    if (rc <= 0) return false;
    int c = accept(srv, nullptr, nullptr);
    if (c < 0) return false;
    close(c);
    return true;
}

// D3：双栈 listener 能否接受一个真正的 IPv4 客户端。
bool dualStackAcceptsIpv4(Reporter &r) {
    int port = 0;
    int srv = makeListener6(r, true, nullptr, &port);
    if (srv < 0) return false;
    r.linef("    双栈 listener 就绪，端口 %d", port);

    int cli = socket(AF_INET, SOCK_STREAM, 0);
    bool ok = false;
    if (cli < 0) {
        r.linef("    客户端 socket(AF_INET) 失败 errno=%d", errno);
    } else {
        struct sockaddr_in d;
        std::memset(&d, 0, sizeof(d));
        d.sin_family = AF_INET;
        d.sin_port = htons(static_cast<uint16_t>(port));
        d.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        errno = 0;
        if (connect(cli, reinterpret_cast<struct sockaddr *>(&d), sizeof(d)) == 0) {
            ok = acceptWithin(srv, 800);
            r.linef("    IPv4 客户端 connect 成功，accept %s", ok ? "成功 ✅" : "超时 ❌");
        } else {
            r.linef("    IPv4 客户端 connect 失败 errno=%d (%s) ❌", errno, strerror(errno));
        }
        close(cli);
    }
    close(srv);
    return ok;
}

// D4：双栈套接字连一个 IPv4 目标（用 ::ffff:127.0.0.1 映射地址）。
// 这一条等价于 SocketChannel 在 ipv6_available=true 之后连任何 IPv4 服务器时走的路径。
bool dualStackConnectsToIpv4(Reporter &r) {
    int port = 0;
    int srv = makeListener4(r, &port);
    if (srv < 0) return false;
    r.linef("    IPv4 listener 就绪 127.0.0.1:%d", port);

    int cli = socket(AF_INET6, SOCK_STREAM, 0);
    bool ok = false;
    if (cli < 0) {
        r.linef("    客户端 socket(AF_INET6) 失败 errno=%d", errno);
    } else {
        int zero = 0;
        if (setsockopt(cli, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof(int)) < 0) {
            r.linef("    客户端 setsockopt(IPV6_V6ONLY,0) 失败 errno=%d (%s) ❌", errno, strerror(errno));
        } else {
            struct sockaddr_in6 d;
            std::memset(&d, 0, sizeof(d));
            d.sin6_family = AF_INET6;
            d.sin6_port = htons(static_cast<uint16_t>(port));
            // ::ffff:127.0.0.1
            d.sin6_addr.s6_addr[10] = 0xff;
            d.sin6_addr.s6_addr[11] = 0xff;
            d.sin6_addr.s6_addr[12] = 127;
            d.sin6_addr.s6_addr[15] = 1;
            errno = 0;
            if (connect(cli, reinterpret_cast<struct sockaddr *>(&d), sizeof(d)) == 0) {
                ok = acceptWithin(srv, 800);
                r.linef("    双栈 → ::ffff:127.0.0.1 connect 成功，accept %s",
                        ok ? "成功 ✅" : "超时 ❌");
            } else {
                r.linef("    双栈 → ::ffff:127.0.0.1 connect 失败 errno=%d (%s) ❌",
                        errno, strerror(errno));
            }
        }
        close(cli);
    }
    close(srv);
    return ok;
}

// D5：纯 IPv6 回环通路。
bool ipv6LoopbackWorks(Reporter &r) {
    unsigned char loop[16];
    std::memset(loop, 0, sizeof(loop));
    loop[15] = 1;   // ::1
    int port = 0;
    int srv = makeListener6(r, false, loop, &port);
    if (srv < 0) return false;
    r.linef("    [::1] listener 就绪，端口 %d", port);

    int cli = socket(AF_INET6, SOCK_STREAM, 0);
    bool ok = false;
    if (cli < 0) {
        r.linef("    客户端 socket(AF_INET6) 失败 errno=%d", errno);
    } else {
        struct sockaddr_in6 d;
        std::memset(&d, 0, sizeof(d));
        d.sin6_family = AF_INET6;
        d.sin6_port = htons(static_cast<uint16_t>(port));
        std::memcpy(d.sin6_addr.s6_addr, loop, 16);
        errno = 0;
        if (connect(cli, reinterpret_cast<struct sockaddr *>(&d), sizeof(d)) == 0) {
            ok = acceptWithin(srv, 800);
            r.linef("    connect ::1 成功，accept %s", ok ? "成功 ✅" : "超时 ❌");
        } else {
            r.linef("    connect ::1 失败 errno=%d (%s) ❌", errno, strerror(errno));
        }
        close(cli);
    }
    close(srv);
    return ok;
}

// D6：设备自身 global IPv6 地址能否 bind + 自连（不出设备）。
bool globalIpv6SelfConnect(Reporter &r, const amcl::ifinet6::Entry &e) {
    int port = 0;
    int srv = makeListener6(r, false, e.addr, &port);
    if (srv < 0) return false;
    r.linef("    在 %s 上 listen 成功，端口 %d", addrToText(e.addr).c_str(), port);

    int cli = socket(AF_INET6, SOCK_STREAM, 0);
    bool ok = false;
    if (cli < 0) {
        r.linef("    客户端 socket(AF_INET6) 失败 errno=%d", errno);
    } else {
        struct sockaddr_in6 d;
        std::memset(&d, 0, sizeof(d));
        d.sin6_family = AF_INET6;
        d.sin6_port = htons(static_cast<uint16_t>(port));
        std::memcpy(d.sin6_addr.s6_addr, e.addr, 16);
        errno = 0;
        if (connect(cli, reinterpret_cast<struct sockaddr *>(&d), sizeof(d)) == 0) {
            ok = acceptWithin(srv, 800);
            r.linef("    自连成功，accept %s", ok ? "成功 ✅" : "超时 ❌");
        } else {
            r.linef("    自连失败 errno=%d (%s)", errno, strerror(errno));
        }
        close(cli);
    }
    close(srv);
    return ok;
}

} // namespace

extern "C" {

const char *runIpv6CapabilityProbe(void) {
    Reporter r;

    r.line("========================================");
    r.line("AMCL IPv6 能力探针 (Phase 0 诊断)");
    r.line("方案: docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §3 P0-a");
    r.line("⚠️ 只观测，不安装插桩，不改 JDK 行为");
    r.line("========================================");
    r.linef("进程: pid=%d uid=%d", static_cast<int>(getpid()), static_cast<int>(getuid()));
    r.line("");

    // ---------------- L0 阳性对照 ----------------
    // 先证明本探针的 fopen 路径在这个进程里是能成功的，否则下面 C3 失败无法区分
    // "文件不可读" 与 "探针自己有问题"。
    r.line("L0) 阳性对照 —— 证明探针本身有效");
    FgetsProbe ctrl = probeFgets(kPositiveControlPath);
    r.linef("    fopen(%s) → %s%s", kPositiveControlPath,
            ctrl.openOk ? "成功" : "失败",
            ctrl.openOk ? "" : ("  errno=" + std::to_string(ctrl.openErrno)
                                + " (" + strerror(ctrl.openErrno) + ")").c_str());
    if (ctrl.openOk) {
        r.linef("    fgets 首行 → %s（共 %d 行可读）",
                ctrl.firstLineOk ? "非空" : "空", ctrl.totalLines);
    }
    if (!ctrl.openOk || !ctrl.firstLineOk) {
        r.line("    ❌ 阳性对照失败 —— 下面 C3 的结论不可用（探针自身路径有问题）");
    } else {
        r.line("    ✅ 对照通过：应用进程能 fopen+fgets /proc 下的文件");
    }
    r.line("");

    // ---------------- C1 socket(AF_INET6) ----------------
    r.line("C1) socket(AF_INET6, SOCK_STREAM, 0) —— 四条判据之一（17/21/25 都有）");
    errno = 0;
    int fd6 = socket(AF_INET6, SOCK_STREAM, 0);
    int fd6Errno = errno;
    bool c1 = (fd6 >= 0);
    if (c1) {
        r.linef("    fd=%d ✅ 成立", fd6);
        close(fd6);
    } else {
        r.linef("    返回 %d ❌ 不成立  errno=%d (%s)", fd6, fd6Errno, strerror(fd6Errno));
    }
    // IPv4 对照：区分"只有 IPv6 被拒"与"根本建不了 socket"（如缺 INTERNET 权限）
    errno = 0;
    int fd4 = socket(AF_INET, SOCK_STREAM, 0);
    if (fd4 >= 0) {
        r.linef("    对照 socket(AF_INET)=%d 成功 → socket 本身可用", fd4);
        close(fd4);
    } else {
        r.linef("    对照 socket(AF_INET) 也失败 errno=%d (%s) → 不是 IPv6 特异问题",
                errno, strerror(errno));
    }
    r.line("");

    // ---------------- C2 getsockname(fd 0) ----------------
    r.line("C2) getsockname(fd 0) 的 inetd 保护 —— ⚠️ 仅 JDK 17 有这条，21/25 已删");
    struct sockaddr_storage ss0;
    socklen_t ss0Len = sizeof(ss0);
    std::memset(&ss0, 0, sizeof(ss0));
    errno = 0;
    int gsRc = getsockname(0, reinterpret_cast<struct sockaddr *>(&ss0), &ss0Len);
    bool c2Fails17 = false;
    if (gsRc == 0) {
        r.linef("    fd 0 是 socket，sa_family=%d", static_cast<int>(ss0.ss_family));
        if (ss0.ss_family == AF_INET) {
            c2Fails17 = true;
            r.line("    ❌ fd 0 是 AF_INET socket → JDK 17 会在此直接判 IPv6 不可用");
        } else {
            r.line("    ✅ 不是 AF_INET，17 的这条判据不拦");
        }
    } else {
        r.linef("    getsockname(0) 失败 errno=%d (%s) → 上游视为「非 socket」，不拦 ✅",
                errno, strerror(errno));
    }
    r.line("");

    // ---------------- C3 /proc/net/if_inet6 ----------------
    r.line("C3) fopen(/proc/net/if_inet6) + 一次 fgets —— 四条判据之一（17/21/25 都有）");
    r.line("    上游注释：不解析内容，拿到任意非空一行即视为「内核有 IPv6」");
    FgetsProbe main6 = probeFgets(kIfInet6Path);
    bool c3 = main6.openOk && main6.firstLineOk;
    if (!main6.openOk) {
        r.linef("    fopen → 失败  errno=%d (%s)", main6.openErrno, strerror(main6.openErrno));
        if (main6.openErrno == ENOENT) {
            r.line("    ⇒ ENOENT：路径在本进程视图里不存在（/proc/net 可能未挂载/被隐藏）");
        } else if (main6.openErrno == EACCES || main6.openErrno == EPERM) {
            r.line("    ⇒ EACCES/EPERM：存在但被拒（沙箱 / SELinux 域策略）");
        }
    } else if (!main6.firstLineOk) {
        r.linef("    fopen 成功但 fgets 返回 NULL（文件为空）errno=%d", main6.fgetsErrno);
        r.line("    ⇒ 上游同样判 false（空文件 == 没有 IPv6 地址）");
    } else {
        r.linef("    ✅ 成立：共 %d 行", main6.totalLines);
        r.linef("       首行: %s", main6.firstLine.c_str());
    }

    // 旁证 1：/proc/self/net/if_inet6（Android 上 /proc/net 是它的符号链接）
    FgetsProbe self6 = probeFgets(kIfInet6SelfPath);
    r.linef("    旁证 fopen(%s) → %s%s", kIfInet6SelfPath,
            self6.openOk ? "成功" : "失败",
            self6.openOk ? "" : ("  errno=" + std::to_string(self6.openErrno)).c_str());
    if (self6.openOk && self6.firstLineOk) {
        r.linef("       首行: %s", self6.firstLine.c_str());
        if (!c3) {
            r.line("       ⚠️ 关键：主路径不可读但 self 路径可读 ⇒ 路线 B 可退化成「只改路径」");
        }
    }

    // 旁证 2：stat 与 open，区分"打不开"的层级
    struct stat st;
    errno = 0;
    if (stat(kIfInet6Path, &st) == 0) {
        r.linef("    旁证 stat(%s) 成功 mode=0%o size=%lld", kIfInet6Path,
                static_cast<unsigned>(st.st_mode & 07777),
                static_cast<long long>(st.st_size));
    } else {
        r.linef("    旁证 stat(%s) 失败 errno=%d (%s)", kIfInet6Path, errno, strerror(errno));
    }

    // 旁证 3：/proc/net 目录本身能否列举 —— 判断是整棵子树被藏还是只藏这一个文件
    errno = 0;
    DIR *d = opendir("/proc/net");
    if (d != nullptr) {
        int n = 0;
        bool sawIfInet6 = false;
        struct dirent *de = nullptr;
        while ((de = readdir(d)) != nullptr) {
            n++;
            if (std::strcmp(de->d_name, "if_inet6") == 0) sawIfInet6 = true;
        }
        closedir(d);
        r.linef("    旁证 opendir(/proc/net) 成功：%d 项，if_inet6 %s",
                n, sawIfInet6 ? "在列表里" : "不在列表里");
    } else {
        r.linef("    旁证 opendir(/proc/net) 失败 errno=%d (%s) → 整棵子树不可见",
                errno, strerror(errno));
    }
    r.line("");

    // ---------------- C3b 垫片是否接管 ----------------
    //
    // ⚠️ 上面的 C3 量的是**平台**，不是垫片：本探针自己的 fopen 在编译期直连 libc，
    //    **不经过** elf_loader 的插桩表（插桩只对 ELF-loaded 的 JDK 库生效）。
    //    ⇒ R1 落地之后 C3 仍然会是 EACCES，**那是预期结果，不是垫片没生效**。
    //    这一条是首次真机验证时差点被误读的地方，所以把话写在输出里而不是只写在文档里。
    //
    // 这里直接调**出货垫片的入口函数**（就是 JDK 的 fopen 会被解析到的那一个），
    // 于是"垫片有没有接管、给出的第一行长什么样"变成报告里一个能直接读到的值，
    // 不依赖日志通道是否可靠（真机上它在 fork 子进程里确实丢过）。
    r.line("C3b) 垫片直连测试 —— 调 amclIfInet6ShimOpen()（JDK 的 fopen 会被解析到这里）");
    r.line("     ⚠️ 注意：C3 量的是平台原始行为，R1 落地后它**仍应**是 EACCES；");
    r.line("        本探针自己的 fopen 不走插桩，只有 ELF-loaded 的 JDK 库才走。");
    bool shimTookOver = false;
    {
        FILE *sf = amclIfInet6ShimOpen(kIfInet6Path, "r");
        if (sf == nullptr) {
            r.line("     垫片未接管（返回 NULL）⇒ 调用方会回落真 fopen");
            r.line("     可能原因：开关关闭（AMCL_JDK_IF_INET6_SHIM=0）/ 本机无 IPv6 地址 / 合成失败");
        } else {
            shimTookOver = true;
            char line[256];
            if (fgets(line, sizeof(line), sf) != nullptr) {
                std::string first(line);
                while (!first.empty() && (first.back() == '\n' || first.back() == '\r')) first.pop_back();
                int extra = 0;
                while (fgets(line, sizeof(line), sf) != nullptr) extra++;
                r.linef("     ✅ 垫片接管，首行: %s", first.c_str());
                r.linef("        共 %d 行（首行 + %d 行）", extra + 1, extra);
            } else {
                r.line("     ⚠️ 垫片返回了流但读不到任何行 —— 这会让上游同样判 false");
            }
            fclose(sf);
        }
    }
    r.line("");

    // ---------------- C4 dlsym(RTLD_DEFAULT, "inet_pton") ----------------
    r.line("C4) dlsym(RTLD_DEFAULT, \"inet_pton\") —— 四条判据之一（17/21/25 都有）");
    r.line("    ⚠️ OHOS 的 linker namespace 会让 RTLD_DEFAULT 的可见性与桌面 Linux 不同，");
    r.line("       所以这条不能想当然（本仓已实证 RTLD_DEFAULT 能解析到系统库符号）");
    void *pton = dlsym(RTLD_DEFAULT, "inet_pton");
    bool c4 = (pton != nullptr);
    if (c4) {
        r.linef("    地址=%p ✅ 成立", pton);
    } else {
        const char *e = dlerror();
        r.linef("    NULL ❌ 不成立  dlerror=%s", e ? e : "(null)");
    }
    r.line("");

    // ---------------- L4 getifaddrs 枚举 ----------------
    r.line("L4) getifaddrs() 枚举本机 IPv6 —— 回答「设备到底有没有 IPv6 地址」");
    // ⭐ 2026-08-29 起改用**出货垫片的同一份收集逻辑**
    // （jvm/if_inet6_shim.cpp 的 collectLocalEntries）。这样下面 L5 的"合成预演"
    // 就是垫片真正会产出的内容，而不是另写一遍的近似物 —— 探针因此可以当作
    // R1 的回归判据用（方案 §四·五 R5.4）。
    std::vector<amcl::ifinet6::Entry> entries;
    int v4Count = 0;
    size_t n6 = amcl::ifinet6::collectLocalEntries(entries);
    {
        // IPv4 条数只用于报告可读性，单独数一遍（垫片不关心 IPv4）
        struct ifaddrs *ifa0 = nullptr;
        if (getifaddrs(&ifa0) == 0) {
            for (struct ifaddrs *ifa = ifa0; ifa != nullptr; ifa = ifa->ifa_next) {
                if (ifa->ifa_addr != nullptr && ifa->ifa_addr->sa_family == AF_INET) v4Count++;
            }
            freeifaddrs(ifa0);
        }
    }
    if (n6 == 0u && entries.empty()) {
        r.line("    getifaddrs 没给出任何 IPv6 地址（或调用失败）");
    }
    {
        int global = 0;
        int link = 0;
        int host = 0;
        for (size_t i = 0; i < entries.size(); ++i) {
            switch (entries[i].scope) {
                case 0x00u: global++; break;
                case 0x20u: link++; break;
                case 0x10u: host++; break;
                default: break;
            }
        }
        r.linef("    IPv6 地址 %zu 条（global=%d link=%d host=%d），IPv4 地址 %d 条",
                entries.size(), global, link, host, v4Count);
        for (size_t i = 0; i < entries.size(); ++i) {
            r.linef("      [%zu] %-8s %s/%u  scope=%s(0x%02x) idx=%u",
                    i, entries[i].name, addrToText(entries[i].addr).c_str(),
                    entries[i].prefixLen, scopeName(entries[i].scope),
                    entries[i].scope, entries[i].ifIndex);
        }
        if (global == 0) {
            r.line("    ⚠️ 没有 global 地址：即便 JDK 判 IPv6 可用，也连不上公网 IPv6 服务器");
        }
    }
    r.line("");

    // ---------------- L5 路线 B 数据充分性预演 ----------------
    r.line("L5) 路线 B 预演 —— 若要合成 if_inet6，数据够不够、格式对不对");
    r.line("    （只打印，不写文件、不安装插桩）");
    if (entries.empty()) {
        r.line("    ⚠️ getifaddrs 没给出任何 IPv6 地址 ⇒ 合成也只能是空文件，");
        r.line("       而空文件在上游同样判 false ⇒ 路线 B 在本设备当前网络下救不了");
    } else {
        std::string synth = amcl::ifinet6::formatFile(entries);
        std::istringstream iss(synth);
        std::string ln;
        int i = 0;
        while (std::getline(iss, ln)) {
            r.linef("    合成[%d]: %s", i++, ln.c_str());
        }
        // 自检：用 JDK NetworkInterface.c 的 scanf 形状读回来，逐字段比对
        bool roundTripOk = true;
        std::istringstream iss2(synth);
        size_t k = 0;
        while (std::getline(iss2, ln) && k < entries.size()) {
            amcl::ifinet6::Entry back;
            if (!amcl::ifinet6::parseLine(ln, &back)) {
                roundTripOk = false;
                r.linef("    ❌ 第 %zu 行按 JDK 的 scanf 形状读不回来", k);
                break;
            }
            if (std::memcmp(back.addr, entries[k].addr, 16) != 0
                || back.prefixLen != entries[k].prefixLen
                || back.ifIndex != entries[k].ifIndex) {
                roundTripOk = false;
                r.linef("    ❌ 第 %zu 行 round-trip 字段不一致", k);
                break;
            }
            k++;
        }
        r.linef("    round-trip（JDK NetworkInterface.c 的 scanf 形状）: %s",
                roundTripOk ? "一致 ✅" : "不一致 ❌");

        // 如果真文件可读，做一次真值比对 —— 这是格式正确性最强的证据
        if (c3) {
            r.linef("    真文件首行: %s", main6.firstLine.c_str());
            r.line("    ⇒ 真文件可读时不需要合成；此比对仅用于确认格式判读无误");
        }
    }
    r.line("");

    // ================================================================
    //  第二部分：后果面测量
    // ================================================================
    //
    // 为什么必须有这一部分：把 IPv6_available 从 false 翻成 true **不只是**让 IPv6
    // 地址能连。上游 `Net.socket0`（libnio/ch/Net.c）逐字如下：
    //
    //     int domain = (ipv6_available() && preferIPv6) ? AF_INET6 : AF_INET;
    //     fd = socket(domain, type, 0);
    //     if (domain == AF_INET6 && ipv4_available()) {
    //         int arg = 0;
    //         if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &arg, sizeof(int)) < 0) {
    //             throw SocketException("Unable to set IPV6_V6ONLY");   // ← 每个 socket
    //             close(fd); return -1;
    //         }
    //     }
    //
    // ⇒ 翻成 true 之后，**每一个** NIO socket 都会走 AF_INET6 + 清 V6ONLY 这条路。
    //   若沙箱不允许清 V6ONLY，MC 的每次 socket 创建都抛异常 —— 那是比"IPv6 连不上"
    //   严重得多的回归（IPv4 也一起死）。若允许清但双栈到 IPv4 目标不通，同样是全面回归。
    //
    // 下面几条全部在本机回环与设备自身地址上完成，**不依赖任何外部网络、不需要 IPv6 服务器**。
    r.line("");
    r.line("========================================");
    r.line("第二部分：后果面测量（若把 ipv6_available 翻成 true，会发生什么）");
    r.line("========================================");

    // ---------------- D1/D2 IPV6_V6ONLY ----------------
    r.line("D1/D2) IPV6_V6ONLY —— ⭐ 决定 Net.socket0 会不会对每个 socket 抛 SocketException");
    bool d2 = false;
    int v6onlyDefault = -1;
    {
        int fd = socket(AF_INET6, SOCK_STREAM, 0);
        if (fd < 0) {
            r.linef("    socket(AF_INET6) 失败 errno=%d ⇒ 本组无法测量", errno);
        } else {
            int arg = -1;
            socklen_t alen = sizeof(arg);
            if (getsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &arg, &alen) == 0) {
                v6onlyDefault = arg;
                r.linef("    默认 IPV6_V6ONLY = %d %s", arg,
                        arg == 0 ? "(已是双栈)" : "(仅 IPv6，需清零)");
            } else {
                r.linef("    getsockopt(IPV6_V6ONLY) 失败 errno=%d (%s)", errno, strerror(errno));
            }
            int zero = 0;
            errno = 0;
            if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof(int)) == 0) {
                d2 = true;
                int back = -1;
                socklen_t blen = sizeof(back);
                getsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &back, &blen);
                r.linef("    setsockopt(IPV6_V6ONLY, 0) ✅ 成功（回读 = %d）", back);
            } else {
                r.linef("    setsockopt(IPV6_V6ONLY, 0) ❌ 失败 errno=%d (%s)", errno, strerror(errno));
                r.line("       ⇒ 致命：翻 true 后 Net.socket0 会对每个 socket 抛 SocketException");
            }
            close(fd);
        }
    }
    r.line("");

    // ---------------- D3 双栈监听接受 IPv4 ----------------
    r.line("D3) 双栈监听能否接受 IPv4 连接（AF_INET6[::]:0 V6ONLY=0 ← AF_INET 127.0.0.1）");
    bool d3 = dualStackAcceptsIpv4(r);
    r.line("");

    // ---------------- D4 双栈发起到 IPv4 目标 ----------------
    r.line("D4) ⭐ 双栈套接字连 IPv4 目标（等价于 SocketChannel 连一个 IPv4 服务器）");
    bool d4 = dualStackConnectsToIpv4(r);
    r.line("");

    // ---------------- D5 纯 IPv6 回环 ----------------
    r.line("D5) 纯 IPv6 通路自检（[::1] 回环 listen + connect）");
    bool d5 = ipv6LoopbackWorks(r);
    r.line("");

    // ---------------- D6 设备全局 IPv6 地址可 bind/连 ----------------
    r.line("D6) 设备自身 global IPv6 地址能否 bind + 自连（不出设备，不需要外部服务器）");
    bool d6 = false;
    bool d6Tested = false;
    for (size_t i = 0; i < entries.size(); ++i) {
        if (entries[i].scope != 0x00u) continue;   // 只试 global
        d6Tested = true;
        d6 = globalIpv6SelfConnect(r, entries[i]);
        break;
    }
    if (!d6Tested) {
        r.line("    设备没有 global IPv6 地址，跳过（本条不构成阻塞项）");
    }
    r.line("");

    // ---------------- D7 datagram 上的 IP_MULTICAST_ALL ----------------
    // 上游 Net.socket0 对 SOCK_DGRAM 还会设 IP_MULTICAST_ALL=0，失败且 errno != ENOPROTOOPT
    // 时同样抛 SocketException。MC 的局域网发现走 datagram，所以这条也要量。
    r.line("D7) datagram 上的 IP_MULTICAST_ALL=0（上游对 SOCK_DGRAM 会设，失败即抛）");
    bool d7 = false;
    {
        int fd = socket(AF_INET6, SOCK_DGRAM, 0);
        if (fd < 0) {
            r.linef("    socket(AF_INET6, SOCK_DGRAM) 失败 errno=%d", errno);
        } else {
            int arg = 0;
            errno = 0;
            if (setsockopt(fd, IPPROTO_IPV6, kIpMulticastAll, &arg, sizeof(arg)) == 0) {
                d7 = true;
                r.line("    setsockopt(IPPROTO_IPV6, IP_MULTICAST_ALL, 0) ✅ 成功");
            } else if (errno == ENOPROTOOPT) {
                d7 = true;
                r.line("    返回 ENOPROTOOPT —— 上游显式容忍这个错误码 ✅ 不阻塞");
            } else {
                r.linef("    ❌ 失败 errno=%d (%s) 且非 ENOPROTOOPT ⇒ datagram 创建会抛异常",
                        errno, strerror(errno));
            }
            close(fd);
        }
    }
    r.line("");

    // ---------------- D8 AF_UNSPEC 解析路径 ----------------
    // 翻 true 之后 Inet6AddressImpl 会用 AF_UNSPEC 解析主机名，AAAA 记录开始进入结果集；
    // 而 MC 1.20.4 的官方 manifest 自带 -Djava.net.preferIPv6Addresses=system。
    r.line("D8) AF_UNSPEC 解析路径（翻 true 后主机名解析会走这条，AAAA 开始进结果集）");
    {
        struct addrinfo hints;
        std::memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        struct addrinfo *res = nullptr;
        int grc = getaddrinfo("localhost", nullptr, &hints, &res);
        if (grc != 0) {
            r.linef("    getaddrinfo(localhost, AF_UNSPEC) 失败 rc=%d (%s)", grc, gai_strerror(grc));
        } else {
            int n4 = 0;
            int n6 = 0;
            std::string order;
            for (struct addrinfo *ai = res; ai != nullptr; ai = ai->ai_next) {
                if (ai->ai_family == AF_INET) { n4++; order += "4"; }
                else if (ai->ai_family == AF_INET6) { n6++; order += "6"; }
            }
            freeaddrinfo(res);
            r.linef("    localhost → IPv4 %d 条 / IPv6 %d 条，返回顺序=%s", n4, n6, order.c_str());
            r.line("    ⚠️ 顺序由系统策略决定；MC 1.20.4 的官方 manifest 带");
            r.line("       -Djava.net.preferIPv6Addresses=system ⇒ 翻 true 后主机名会开始优先 IPv6。");
            r.line("       本仓已有真机记录：本平台存在「有 IPv6 路由但该主机 IPv6 不通」的情况");
            r.line("       （CHANGELOG 1000467，下载器为此加了每主机地址族选择），而 MC/Netty 没有这种回退。");
        }
    }
    r.line("");

    // ---------------- 判定 ----------------
    r.line("========================================");
    bool verdict17 = c1 && !c2Fails17 && c3 && c4;
    bool verdict2125 = c1 && c3 && c4;
    r.linef("逐条: C1(socket)=%s  C2(fd0 非 AF_INET)=%s  C3(if_inet6)=%s  C4(inet_pton)=%s",
            c1 ? "OK" : "FAIL",
            c2Fails17 ? "FAIL" : "OK",
            c3 ? "OK" : "FAIL",
            c4 ? "OK" : "FAIL");
    r.linef("复现 IPv6_supported() → JDK 17: %s", verdict17 ? "JNI_TRUE" : "JNI_FALSE");
    r.linef("复现 IPv6_supported() → JDK 21/25: %s", verdict2125 ? "JNI_TRUE" : "JNI_FALSE");
    r.line("");

    r.linef("垫片(C3b): %s", shimTookOver ? "已接管（合成流可读）" : "未接管（回落真 fopen）");
    r.line("");
    if (!c1) {
        r.line("结论: 沙箱连 AF_INET6 socket 都建不了 —— 比「文件读不到」更底层。");
        r.line("      合成 if_inet6 救不了（C1 在它之前），需要另找原因。");
    } else if (!c4) {
        r.line("结论: inet_pton 在 RTLD_DEFAULT 下解析不到 —— 与 /proc 无关的第四条判据失败。");
    } else if (c2Fails17) {
        r.line("结论: fd 0 是 AF_INET socket —— JDK 17 会因 inetd 保护判 false，而 21/25 不受影响。");
        r.line("      这条与 /proc/net/if_inet6 无关，需要单独处理（且能解释「17 挂 21 不挂」）。");
    } else if (!c3 && shimTookOver) {
        r.line("结论: 平台仍拒读该文件（C3=FAIL，**预期**），但垫片已接管 ⇒ ELF-loaded 的 JDK");
        r.line("      会读到合成内容、判 IPv6 可用。上面复现的 JNI_FALSE 是**平台原始判据**，");
        r.line("      不是 JDK 的实际结果 —— JDK 的实际结果要看「IPv6 · Java 侧」那个关卡。");
    } else if (!c3) {
        r.line("结论: 仅 C3 不成立，且垫片未接管 ⇒ JDK 会判 IPv6 不可用（未修复状态）。");
        r.line("      垫片未接管的原因见上面 C3b 那一行。");
    } else {
        r.line("结论: 四条判据在本设备上全部成立 ⇒ JDK 会判 IPv6 可用。");
        r.line("      ⇒ 静态审查的 JDK 假设**在本设备上不成立**，应转向路线 C：");
        r.line("        输入形态（[IPv6]:port）/ 网络可达性 / Minecraft 自身 null-message NPE。");
    }
    r.line("");

    // ---------------- 后果面判定 ----------------
    r.line("---- 后果面 ----");
    r.linef("逐条: D1(V6ONLY 默认值)=%d  D2(清 V6ONLY)=%s  D3(双栈收 IPv4)=%s  D4(双栈连 IPv4)=%s  D5(IPv6 回环)=%s  D7(MULTICAST_ALL)=%s",
            v6onlyDefault, d2 ? "OK" : "FAIL", d3 ? "OK" : "FAIL", d4 ? "OK" : "FAIL",
            d5 ? "OK" : "FAIL", d7 ? "OK" : "FAIL");
    if (d6Tested) {
        r.linef("      D6(global 自连)=%s", d6 ? "OK" : "FAIL");
    }
    if (!d2) {
        r.line("⛔ 阻塞项：清不掉 IPV6_V6ONLY ⇒ 一旦 ipv6_available=true，Net.socket0 会对");
        r.line("   **每一个** socket 抛 SocketException(\"Unable to set IPV6_V6ONLY\")。");
        r.line("   ⇒ 无论走哪条路线，**都不能就这么翻**，否则 IPv4 也一起死。");
    } else if (!d4) {
        r.line("⛔ 阻塞项：双栈套接字连不到 IPv4 目标 ⇒ 翻 true 后所有 IPv4 连接都走这条路，");
        r.line("   会整体回归。必须先解决双栈到 IPv4 的可达性，或改为不走双栈的方案。");
    } else if (!d7) {
        r.line("⚠️ 次级阻塞：datagram 的 IP_MULTICAST_ALL 失败且非 ENOPROTOOPT ⇒ 翻 true 后");
        r.line("   DatagramChannel 创建会抛异常（影响局域网发现一类功能）。");
    } else {
        r.line("✅ 后果面未发现阻塞项：清 V6ONLY、双栈收发 IPv4、datagram 选项都成立。");
        r.line("   ⇒ 把 ipv6_available 翻成 true **不会**打断 IPv4 通路。");
    }
    r.line("⚠️ 但仍有一条不属于本探针能判定的风险：主机名解析会开始返回 AAAA，");
    r.line("   而 MC 1.20.4 官方 manifest 自带 -Djava.net.preferIPv6Addresses=system ⇒");
    r.line("   IPv6 会被优先选。若某主机「有 IPv6 路由但路径不通」，表现是连接变慢/失败，");
    r.line("   且 MC/Netty 没有像我方下载器那样的按主机地址族回退。见方案 §4 的取舍。");
    r.line("");
    r.line("⚠️ 本探针只复现 native 判据与 native 后果面。Java 侧 Net.isIPv6Available() 的");
    r.line("   实际值仍需 P0-b 在 JVM 内测量（两者不等价：中间还有 preferIPv4Stack 与缓存时序）。");
    r.line("IPv6 探针完成");
    r.line("========================================");

    amclLogFlush();
    g_report = r.str();
    return g_report.c_str();
}

} // extern "C"
