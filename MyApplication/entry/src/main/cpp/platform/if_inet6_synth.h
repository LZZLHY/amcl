// if_inet6_synth.h — /proc/net/if_inet6 的合成、回读与"该不该合成"的决策（纯函数，无平台依赖）
//
// 方案：docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §四·五 R1
// 施工记录：docs/refactor/JDK-IPv6施工记录.md §S06
//
// ⚠️ 2026-08-29 从 tests/ 搬到 platform/：它现在是**出货代码**（被 jvm/if_inet6_shim.cpp 使用），
//    不再只是探针的辅助。搬迁是刻意的一步 —— 搬过来之后它就进 libentry.so 的常驻代码面了。
//
// ============================================================================
// 为什么格式要对：两个消费者的要求**不一样**
// ============================================================================
// 消费者 A：`IPv6_supported()`（libnet，决定 Net.isIPv6Available()）
//   上游源码原话是「Don't need to parse the line - we just need an indication」，
//   它只做 fopen + 一次 fgets，**拿到任意非空的一行就算通过**，不解析内容。
//   ⇒ 对 A 来说格式无关，能读到一行就够。
//
// 消费者 B：`NetworkInterface.c` 的 Linux IPv6 枚举（enumIPv6Interfaces）
//   它按 `%4s%4s%4s%4s%4s%4s%4s%4s %08x %02x %02x %02x %20s` 逐行 fscanf，
//   要用到 32 hex 地址、ifindex、prefixlen、设备名；**fopen 失败时静默容忍**
//   （所以只修 A 的做法会留下"能力 true 但枚举 0 条"的不自洽状态）。
//   ⇒ 对 B 来说格式必须对，否则 IPv6 地址枚举不出来**且不报错**。
//
// 所以这里按**内核 if6_seq_show 的真实格式**逐字节合成（而不是只糊一行给 A 过关），
// 并提供 parseLine 用 B 的 scanf 形状读回来自检。
//
// 内核格式（net/ipv6/addrconf.c if6_seq_show）：
//     "%08x%08x%08x%08x %02x %02x %02x %02x %8s\n"
//      └─ 32 hex 的地址，无冒号 ─┘  idx  plen scope flags devname
#ifndef MC_OHOS_IF_INET6_SYNTH_H
#define MC_OHOS_IF_INET6_SYNTH_H

#include <cstddef>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace amcl {
namespace ifinet6 {

// 一条 IPv6 地址记录。字段取名对齐内核那一行的五列。
struct Entry {
    unsigned char addr[16];   // 网络字节序的 128 位地址
    unsigned int  ifIndex;    // if_nametoindex()
    unsigned int  prefixLen;  // 由 netmask 数出来的位数
    unsigned int  scope;      // 见 scopeForAddr()
    unsigned int  flags;      // ⚠️ getifaddrs 给不出，见下方说明
    char          name[32];   // 设备名

    Entry() : addr{}, ifIndex(0u), prefixLen(0u), scope(0u), flags(0u), name{} {}
};

// flags 列的占位值。
// ⚠️ 诚实标注：`getifaddrs()` **拿不到** IFA_F_* 标志位（那是 netlink IFA_FLAGS 才有的），
// 所以这一列只能给一个占位。选 0x80（IFA_F_PERMANENT）是因为真实文件里静态配置的地址
// 就是这个值，且上面两个消费者都不读它。若将来有消费者读 flags，这里必须改成走 netlink，
// 不能继续用占位 —— 这条前提写在这里，免得下一个人以为它是真值。
constexpr unsigned int kFlagsPlaceholder = 0x80u;

// 地址 → scope 列。取值对齐 Linux 在该文件里实际写出的那组值。
inline unsigned int scopeForAddr(const unsigned char addr[16]) {
    // ::1 → host(0x10)
    bool isLoopback = true;
    for (int i = 0; i < 15; ++i) {
        if (addr[i] != 0u) { isLoopback = false; break; }
    }
    if (isLoopback && addr[15] == 1u) return 0x10u;

    // fe80::/10 → link(0x20)
    if (addr[0] == 0xfeu && (addr[1] & 0xc0u) == 0x80u) return 0x20u;
    // fec0::/10 → site(0x40)（已废弃但仍可能出现）
    if (addr[0] == 0xfeu && (addr[1] & 0xc0u) == 0xc0u) return 0x40u;

    // 其余按 global(0x00)
    return 0x00u;
}

// 32 位十六进制地址串（小写，无冒号），与内核 "%08x%08x%08x%08x" 等价。
inline std::string formatAddrHex(const unsigned char addr[16]) {
    char buf[33];
    for (int i = 0; i < 16; ++i) {
        std::snprintf(buf + i * 2, 3, "%02x", static_cast<unsigned>(addr[i]));
    }
    buf[32] = '\0';
    return std::string(buf);
}

// 合成一行（不含换行）。devname 按内核的 "%8s" 右对齐补空格。
inline std::string formatLine(const Entry &e) {
    char buf[128];
    std::snprintf(buf, sizeof(buf), "%s %02x %02x %02x %02x %8s",
                  formatAddrHex(e.addr).c_str(),
                  e.ifIndex & 0xffu,
                  e.prefixLen & 0xffu,
                  e.scope & 0xffu,
                  e.flags & 0xffu,
                  e.name);
    return std::string(buf);
}

// 合成整个文件内容（每行末尾一个 '\n'，与内核一致）。
inline std::string formatFile(const std::vector<Entry> &entries) {
    std::string out;
    for (size_t i = 0; i < entries.size(); ++i) {
        out += formatLine(entries[i]);
        out += '\n';
    }
    return out;
}

// 按 **JDK NetworkInterface.c 的 scanf 形状** 把一行读回来。
// 存在的意义不是"我们需要一个解析器"，而是让"JDK 能不能读懂我们合成的东西"变成一条断言。
inline bool parseLine(const std::string &line, Entry *out) {
    if (out == nullptr) return false;

    char h[8][5];
    unsigned int idx = 0u;
    unsigned int plen = 0u;
    unsigned int scope = 0u;
    unsigned int flags = 0u;
    char devname[21];
    std::memset(h, 0, sizeof(h));
    std::memset(devname, 0, sizeof(devname));

    int n = std::sscanf(line.c_str(),
                        "%4s%4s%4s%4s%4s%4s%4s%4s %08x %02x %02x %02x %20s",
                        h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
                        &idx, &plen, &scope, &flags, devname);
    if (n != 13) return false;

    Entry e;
    for (int g = 0; g < 8; ++g) {
        if (std::strlen(h[g]) != 4u) return false;
        unsigned int hextet = 0u;
        if (std::sscanf(h[g], "%4x", &hextet) != 1) return false;
        e.addr[g * 2] = static_cast<unsigned char>((hextet >> 8) & 0xffu);
        e.addr[g * 2 + 1] = static_cast<unsigned char>(hextet & 0xffu);
    }
    e.ifIndex = idx;
    e.prefixLen = plen;
    e.scope = scope;
    e.flags = flags;
    std::snprintf(e.name, sizeof(e.name), "%s", devname);
    *out = e;
    return true;
}

// ============================================================
//  垫片决策（方案 §四·五 R1.1–R1.7 的全部策略，纯函数）
// ============================================================
//
// 把"该不该合成"抽成纯函数的理由：这套策略里每一条都是**由测量得出的**，
// 而它的错误形态是静默的 —— 例如 R1.4 若写反（无 IPv6 地址时也造一行），
// JDK 会在真没有 IPv6 的设备上以为有，之后所有 socket 走双栈，没人会看到报错。
// 抽成纯函数之后，这张真值表可以在宿主机上被逐条断言（tests/host/if_inet6_synth_test.cpp）。

/** 垫片开关的三态。默认 On。 */
enum class ShimMode {
    Off = 0,   // AMCL_JDK_IF_INET6_SHIM=0：完全不介入，回到修复前的行为
    On = 1,    // 缺省
};

/** 决策结果。除 Synthesize 之外**一律回落真 fopen**（fail-safe，绝不 fail-open）。 */
enum class ShimDecision {
    NotOurPath,           // 不是 /proc/net/if_inet6 —— 透传
    NotReadMode,          // 带写/追加意图 —— 透传（我们只服务只读打开）
    Off,                  // 开关关闭 —— 透传
    PassthroughReal,      // 真文件本来就能打开 —— 用真的那个流（R1.2）
    PassthroughNoIpv6,    // 打不开，但本机确实没有 IPv6 地址 —— 不造假（R1.4）
    Synthesize,           // 打不开且本机有 IPv6 地址 —— 合成（R1.3）
};

/**
 * R1 的全部策略，一处判定。
 *
 * @param pathMatches  路径是否精确等于 /proc/net/if_inet6（R1.1）
 * @param readOnlyMode fopen mode 是否为纯只读
 * @param mode         垫片开关（R1.7）
 * @param realOpenOk   真 fopen 是否成功（R1.2）
 * @param entryCount   getifaddrs 找到的 IPv6 地址条数（R1.4）
 */
inline ShimDecision decide(bool pathMatches, bool readOnlyMode, ShimMode mode,
                           bool realOpenOk, size_t entryCount) {
    if (!pathMatches) return ShimDecision::NotOurPath;
    if (!readOnlyMode) return ShimDecision::NotReadMode;
    // ⚠️ 顺序要紧：真文件优先于开关与合成 —— 平台哪天放开了，垫片自动无害退场。
    if (realOpenOk) return ShimDecision::PassthroughReal;
    if (mode == ShimMode::Off) return ShimDecision::Off;
    if (entryCount == 0u) return ShimDecision::PassthroughNoIpv6;
    return ShimDecision::Synthesize;
}

/** 决策 → 日志用的短名（也是 [IPV6-SHIM] 观测行里的 mode= 取值，R1.8）。 */
inline const char *decisionName(ShimDecision d) {
    switch (d) {
        case ShimDecision::NotOurPath:        return "not-our-path";
        case ShimDecision::NotReadMode:       return "not-read-mode";
        case ShimDecision::Off:               return "off";
        case ShimDecision::PassthroughReal:   return "passthrough-real";
        case ShimDecision::PassthroughNoIpv6: return "passthrough-no-ipv6";
        case ShimDecision::Synthesize:        return "synthesized";
    }
    return "unknown";
}

/**
 * fopen 的 mode 串是否为纯只读（"r" / "rb" / "rt" …，不含 + w a）。
 * 只服务只读打开：JDK 那两个消费者都是只读，写意图一律透传给真 fopen。
 */
inline bool isReadOnlyMode(const char *mode) {
    if (mode == nullptr || mode[0] != 'r') return false;
    for (const char *p = mode; *p != '\0'; ++p) {
        if (*p == '+' || *p == 'w' || *p == 'a') return false;
    }
    return true;
}

} // namespace ifinet6
} // namespace amcl

#endif // MC_OHOS_IF_INET6_SYNTH_H
