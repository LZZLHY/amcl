// if_inet6_synth_test.cpp — /proc/net/if_inet6 合成格式的宿主端钉子
//
// 方案 docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §4 路线 B；
// 施工记录 docs/refactor/JDK-IPv6施工记录.md。
//
// ⭐ 这份测试存在的直接原因：路线 B 的失败模式是**静默的**。
//
// `IPv6_supported()` 只要求"能读到任意一行"，所以哪怕合成出一行垃圾，
// `Net.isIPv6Available()` 也会变成 true —— 看起来修好了。但 `NetworkInterface.c`
// 是按 `%4s%4s%4s%4s%4s%4s%4s%4s %08x %02x %02x %02x %20s` 逐行 fscanf 的，
// 格式错一位它就枚举不出 IPv6 地址，而**没有任何报错**：
// 表现是"能连上但 NetworkInterface 看不见 IPv6"，下一轮排查会从头再来一遍。
//
// ⇒ 所以这里钉两件事：
//     1) 合成结果与**内核 if6_seq_show 的真实格式**逐字节相同；
//     2) 用 JDK 那条 scanf 形状能把每个字段原样读回来。
//
// 并且按 AGENTS.md §2.8「判定工具本身要先在已知为真的样本上验证过」：
// 下面第 5 组直接喂**真实 Linux 机器上 /proc/net/if_inet6 的行**，
// 确认解析器不是只认自己合成的东西。

#include "if_inet6_synth.h"

#include <cstddef>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

int g_failures = 0;

void require(bool condition, const char *message) {
    if (condition) return;
    std::cerr << "if_inet6_synth_test: FAIL: " << message << '\n';
    ++g_failures;
}

void requireEq(const std::string &actual, const std::string &expected, const char *message) {
    if (actual == expected) return;
    std::cerr << "if_inet6_synth_test: FAIL: " << message << '\n'
              << "  expected: [" << expected << "]\n"
              << "  actual  : [" << actual << "]\n";
    ++g_failures;
}

// 从 8 组 hextet 字面量填地址，省得手写 16 个字节。
amcl::ifinet6::Entry makeEntry(const unsigned int hextets[8], unsigned int idx,
                               unsigned int plen, const char *name) {
    amcl::ifinet6::Entry e;
    for (int i = 0; i < 8; ++i) {
        e.addr[i * 2] = static_cast<unsigned char>((hextets[i] >> 8) & 0xffu);
        e.addr[i * 2 + 1] = static_cast<unsigned char>(hextets[i] & 0xffu);
    }
    e.ifIndex = idx;
    e.prefixLen = plen;
    e.scope = amcl::ifinet6::scopeForAddr(e.addr);
    e.flags = amcl::ifinet6::kFlagsPlaceholder;
    std::snprintf(e.name, sizeof(e.name), "%s", name);
    return e;
}

} // namespace

int main() {
    using amcl::ifinet6::Entry;
    using amcl::ifinet6::formatAddrHex;
    using amcl::ifinet6::formatFile;
    using amcl::ifinet6::formatLine;
    using amcl::ifinet6::parseLine;
    using amcl::ifinet6::scopeForAddr;

    // ── 1) scope 列的推导 ────────────────────────────────────────────
    {
        const unsigned int loopback[8] = {0, 0, 0, 0, 0, 0, 0, 1};
        const unsigned int linkLocal[8] = {0xfe80, 0, 0, 0, 0x0242, 0x81ff, 0xfe0a, 0x1b2c};
        const unsigned int siteLocal[8] = {0xfec0, 0, 0, 0, 0, 0, 0, 1};
        const unsigned int global[8] = {0x2001, 0x0db8, 0, 0, 0, 0, 0, 1};
        const unsigned int unspecified[8] = {0, 0, 0, 0, 0, 0, 0, 0};

        Entry e;
        e = makeEntry(loopback, 1u, 128u, "lo");
        require(scopeForAddr(e.addr) == 0x10u, "::1 must map to host scope 0x10");
        e = makeEntry(linkLocal, 2u, 64u, "wlan0");
        require(scopeForAddr(e.addr) == 0x20u, "fe80::/10 must map to link scope 0x20");
        e = makeEntry(siteLocal, 2u, 64u, "wlan0");
        require(scopeForAddr(e.addr) == 0x40u, "fec0::/10 must map to site scope 0x40");
        e = makeEntry(global, 2u, 64u, "wlan0");
        require(scopeForAddr(e.addr) == 0x00u, "2001:db8:: must map to global scope 0x00");
        // :: 全零不是 loopback（最后一字节不是 1），必须落到 global 而不是被误判成 host。
        e = makeEntry(unspecified, 0u, 0u, "any");
        require(scopeForAddr(e.addr) == 0x00u, ":: must not be mistaken for loopback");
    }

    // ── 2) 地址列：32 个小写 hex，无冒号 ────────────────────────────
    {
        const unsigned int linkLocal[8] = {0xfe80, 0, 0, 0, 0x0242, 0x81ff, 0xfe0a, 0x1b2c};
        Entry e = makeEntry(linkLocal, 2u, 64u, "wlan0");
        std::string hex = formatAddrHex(e.addr);
        require(hex.size() == 32u, "address column must be exactly 32 hex chars");
        requireEq(hex, "fe80000000000000024281fffe0a1b2c", "address column bytes");
        for (size_t i = 0; i < hex.size(); ++i) {
            require(!(hex[i] >= 'A' && hex[i] <= 'F'), "address column must be lowercase");
        }
    }

    // ── 3) 整行与内核 "%08x%08x%08x%08x %02x %02x %02x %02x %8s" 逐字节相同 ──
    // devname 是 %8s（右对齐补空格），所以 "lo" 前面是 6 个填充空格 + 1 个分隔空格。
    {
        const unsigned int loopback[8] = {0, 0, 0, 0, 0, 0, 0, 1};
        Entry lo = makeEntry(loopback, 1u, 128u, "lo");
        requireEq(formatLine(lo),
                  "00000000000000000000000000000001 01 80 10 80       lo",
                  "loopback line must match kernel formatting byte for byte");

        const unsigned int linkLocal[8] = {0xfe80, 0, 0, 0, 0x0242, 0x81ff, 0xfe0a, 0x1b2c};
        Entry wl = makeEntry(linkLocal, 2u, 64u, "wlan0");
        requireEq(formatLine(wl),
                  "fe80000000000000024281fffe0a1b2c 02 40 20 80    wlan0",
                  "link-local line must match kernel formatting byte for byte");
    }

    // ── 4) round-trip：JDK 的 scanf 形状必须把每个字段原样读回来 ─────
    {
        const unsigned int loopback[8] = {0, 0, 0, 0, 0, 0, 0, 1};
        const unsigned int linkLocal[8] = {0xfe80, 0, 0, 0, 0x0242, 0x81ff, 0xfe0a, 0x1b2c};
        std::vector<Entry> entries;
        entries.push_back(makeEntry(loopback, 1u, 128u, "lo"));
        entries.push_back(makeEntry(linkLocal, 2u, 64u, "wlan0"));

        std::string file = formatFile(entries);
        // 每条一行，且每行都以 '\n' 收尾（内核如此，JDK 的 fscanf 也期望如此）。
        size_t newlines = 0;
        for (size_t i = 0; i < file.size(); ++i) {
            if (file[i] == '\n') newlines++;
        }
        require(newlines == entries.size(), "formatFile must emit one newline per entry");
        require(!file.empty() && file[file.size() - 1] == '\n',
                "formatFile must end with a newline");

        for (size_t k = 0; k < entries.size(); ++k) {
            Entry back;
            require(parseLine(formatLine(entries[k]), &back), "parseLine must accept our own output");
            require(std::memcmp(back.addr, entries[k].addr, 16) == 0, "round-trip address");
            require(back.ifIndex == entries[k].ifIndex, "round-trip ifIndex");
            require(back.prefixLen == entries[k].prefixLen, "round-trip prefixLen");
            require(back.scope == entries[k].scope, "round-trip scope");
            require(back.flags == entries[k].flags, "round-trip flags");
            require(std::strcmp(back.name, entries[k].name) == 0, "round-trip devname");
        }
    }

    // ── 5) 已知为真的样本：真实 Linux /proc/net/if_inet6 的行 ────────
    // 不是我们合成的。若解析器只认自己的输出，这一组会红。
    {
        Entry got;
        require(parseLine("00000000000000000000000000000001 01 80 10 80       lo", &got),
                "parser must accept a real kernel loopback line");
        require(got.ifIndex == 1u, "real sample ifIndex");
        require(got.prefixLen == 128u, "real sample prefixLen");
        require(got.scope == 0x10u, "real sample scope");
        require(std::strcmp(got.name, "lo") == 0, "real sample devname");
        require(got.addr[15] == 1u, "real sample last address byte");
        for (int i = 0; i < 15; ++i) {
            require(got.addr[i] == 0u, "real sample leading address bytes must be zero");
        }

        Entry got2;
        require(parseLine("fe80000000000000024281fffe0a1b2c 02 40 20 80    wlan0", &got2),
                "parser must accept a real kernel link-local line");
        require(got2.addr[0] == 0xfeu && got2.addr[1] == 0x80u, "real sample fe80 prefix");
        require(got2.prefixLen == 64u, "real sample prefixLen 64");
        require(std::strcmp(got2.name, "wlan0") == 0, "real sample devname wlan0");
    }

    // ── 6) 负例：解析器不能什么都收 ─────────────────────────────────
    // 这一组存在的理由与第 5 组相反：一个恒真的解析器同样让第 4 组变成恒真断言。
    {
        Entry sink;
        require(!parseLine("", &sink), "empty line must be rejected");
        require(!parseLine("not an if_inet6 line at all", &sink),
                "garbage must be rejected");
        // 地址短一位 —— 最后一组只有 3 个字符
        require(!parseLine("0000000000000000000000000000001 01 80 10 80       lo", &sink),
                "short address column must be rejected");
        // 缺 devname 列
        require(!parseLine("00000000000000000000000000000001 01 80 10 80", &sink),
                "missing devname column must be rejected");
        require(!parseLine("00000000000000000000000000000001 01 80 10 80       lo",
                           static_cast<Entry *>(nullptr)),
                "null out pointer must be rejected");
    }

    // ── 6.5) ⭐ 垫片决策真值表（方案 §四·五 R1.1–R1.7）────────────────
    // 这组是 R1 落地之后**最重要**的断言：这套策略的每一条错误形态都是**静默的**。
    // 尤其 R1.4（无 IPv6 地址时不得合成）—— 写反了会让真没有 IPv6 的设备以为有，
    // 之后所有 socket 走双栈，而**没有任何报错**会出现。
    {
        using amcl::ifinet6::decide;
        using amcl::ifinet6::decisionName;
        using amcl::ifinet6::isReadOnlyMode;
        using amcl::ifinet6::ShimDecision;
        using amcl::ifinet6::ShimMode;

        // R1.1 路径不匹配一律透传，其余入参都不该影响这个结论
        require(decide(false, true, ShimMode::On, false, 5) == ShimDecision::NotOurPath,
                "R1.1 non-matching path must pass through");
        require(decide(false, false, ShimMode::Off, true, 0) == ShimDecision::NotOurPath,
                "R1.1 non-matching path wins over every other input");

        // 只服务只读打开
        require(decide(true, false, ShimMode::On, false, 5) == ShimDecision::NotReadMode,
                "write-intent open must pass through");

        // R1.2 真文件能打开 → 用真的。⚠️ 必须优先于开关与合成：
        // 平台哪天放开了这个文件，垫片要能自动退场。
        require(decide(true, true, ShimMode::On, true, 5) == ShimDecision::PassthroughReal,
                "R1.2 real file wins when it opens");
        require(decide(true, true, ShimMode::Off, true, 0) == ShimDecision::PassthroughReal,
                "R1.2 real file wins even with the shim switched off");

        // R1.7 开关关闭 → 透传（回到修复前的行为）
        require(decide(true, true, ShimMode::Off, false, 5) == ShimDecision::Off,
                "R1.7 kill switch must fall back");

        // R1.4 ⭐ 没有任何 IPv6 地址 → 绝不合成
        require(decide(true, true, ShimMode::On, false, 0) == ShimDecision::PassthroughNoIpv6,
                "R1.4 must not fabricate capability when the host has no IPv6 address");

        // R1.3 命中 + 只读 + 开 + 真文件打不开 + 有地址 → 合成
        require(decide(true, true, ShimMode::On, false, 1) == ShimDecision::Synthesize,
                "R1.3 synthesize when the host really has IPv6 and the file is unreadable");
        require(decide(true, true, ShimMode::On, false, 99) == ShimDecision::Synthesize,
                "R1.3 holds for many addresses too");

        // 判定名是 [IPV6-SHIM] 观测行的一部分（R1.8），不能为空/不能重名
        const ShimDecision all[] = {
            ShimDecision::NotOurPath, ShimDecision::NotReadMode, ShimDecision::Off,
            ShimDecision::PassthroughReal, ShimDecision::PassthroughNoIpv6,
            ShimDecision::Synthesize,
        };
        for (size_t i = 0; i < sizeof(all) / sizeof(all[0]); ++i) {
            const char *ni = decisionName(all[i]);
            require(ni != nullptr && ni[0] != '\0', "every decision needs a log name");
            for (size_t j = i + 1; j < sizeof(all) / sizeof(all[0]); ++j) {
                require(std::strcmp(ni, decisionName(all[j])) != 0,
                        "decision log names must be distinct");
            }
        }

        // mode 串判读：只读才接管
        require(isReadOnlyMode("r"), "\"r\" is read-only");
        require(isReadOnlyMode("rb"), "\"rb\" is read-only");
        require(isReadOnlyMode("rt"), "\"rt\" is read-only");
        require(!isReadOnlyMode("r+"), "\"r+\" is not read-only");
        require(!isReadOnlyMode("rb+"), "\"rb+\" is not read-only");
        require(!isReadOnlyMode("w"), "\"w\" is not read-only");
        require(!isReadOnlyMode("a"), "\"a\" is not read-only");
        require(!isReadOnlyMode(""), "empty mode is not read-only");
        require(!isReadOnlyMode(nullptr), "null mode is not read-only");
    }

    // ── 7) 空输入 ───────────────────────────────────────────────────
    // 合成出空文件在上游同样判 false（fgets 返回 NULL），所以这不是"修好了"。
    // 这条断言把它钉成一个显式事实，免得将来有人以为空文件也能过关。
    {
        std::vector<Entry> none;
        requireEq(formatFile(none), std::string(), "no entries must produce an empty file");
    }

    if (g_failures == 0) {
        std::cout << "if_inet6_synth_test: all assertions passed\n";
        return 0;
    }
    std::cerr << "if_inet6_synth_test: " << g_failures << " failure(s)\n";
    return 1;
}
