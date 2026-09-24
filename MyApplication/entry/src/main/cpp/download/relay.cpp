/**
 * download/relay.cpp — 加速网关客户端实现
 */
#include "relay.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <random>
#include <shared_mutex>
#include <string>

#include "hmac_sha256.h"
#include "../utils/amcl_log.h"

#undef LOG_TAG
#define LOG_TAG "DL_RELAY"

namespace download {

namespace {

std::shared_mutex g_mu;
RelayConfig       g_cfg;

std::atomic<int64_t> g_requests{0};
std::atomic<int64_t> g_failures{0};
std::atomic<int64_t> g_fallbacks{0};
std::atomic<int64_t> g_auth_rejects{0};

// 熔断：连续失败达到阈值后停用一段时间。加速是"增强"，绝不能因为网关抽风
// 反而把下载拖死 —— 宁可回退直连。
constexpr int   kTripThreshold = 5;
constexpr int64_t kTripCooldownMs = 60 * 1000;
std::atomic<int>     g_consecutive_failures{0};
std::atomic<int64_t> g_tripped_until_ms{0};

int64_t nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

/**
 * 可加速的**官方源**主机白名单。
 * 与网关侧 upstreams.js 的白名单保持一致（网关会二次校验，这里只是避免无谓往返）。
 * 注意只列官方源：镜像源不改写（见 relay.h 注释）。
 */
bool isOfficialHost(const std::string& host) {
    static const char* kHosts[] = {
        // Modrinth
        "cdn.modrinth.com", "api.modrinth.com",
        // CurseForge（官方 CDN；mod.mcimirror.top 属镜像，不改写）
        "mediafilez.forgecdn.net", "edge.forgecdn.net",
        // Mojang
        "piston-data.mojang.com", "piston-meta.mojang.com",
        "launchermeta.mojang.com", "launcher.mojang.com",
        "libraries.minecraft.net", "resources.download.minecraft.net",
        // 加载器 / Maven 官方
        "maven.neoforged.net", "maven.minecraftforge.net",
        "maven.fabricmc.net", "meta.fabricmc.net", "maven.quiltmc.org",
        "files.minecraftforge.net", "repo1.maven.org",
        // GitHub
        "github.com", "raw.githubusercontent.com", "api.github.com",
        // JDK
        "api.adoptium.net",
    };
    for (const char* h : kHosts) {
        if (host == h) return true;
    }
    return false;
}

/** 从 URL 取 scheme 之后的 host（小写）与其余部分 */
bool splitUrl(const std::string& url, std::string& host, std::string& rest) {
    const std::string prefix = "https://";
    if (url.size() <= prefix.size() || url.compare(0, prefix.size(), prefix) != 0) {
        return false;  // 只加速 https
    }
    size_t start = prefix.size();
    size_t slash = url.find('/', start);
    std::string h = (slash == std::string::npos) ? url.substr(start) : url.substr(start, slash - start);
    if (h.empty() || h.find('@') != std::string::npos) return false;   // 拒绝 userinfo
    // 去端口：只接受默认端口（带显式端口的一律不加速，避免绕过白名单语义）
    if (h.find(':') != std::string::npos) return false;
    for (char& c : h) c = static_cast<char>(::tolower(static_cast<unsigned char>(c)));
    host = h;
    rest = (slash == std::string::npos) ? "/" : url.substr(slash);
    return true;
}

std::string randomNonceHex() {
    // 32 hex 字符 = 16 字节。用 random_device 播种的 mt19937_64，够用且无外部依赖。
    static thread_local std::mt19937_64 rng([] {
        std::random_device rd;
        uint64_t seed = (static_cast<uint64_t>(rd()) << 32) ^ rd() ^
                        static_cast<uint64_t>(nowMs());
        return seed;
    }());
    char buf[33];
    uint64_t a = rng();
    uint64_t b = rng();
    std::snprintf(buf, sizeof(buf), "%016llx%016llx",
                  static_cast<unsigned long long>(a), static_cast<unsigned long long>(b));
    return std::string(buf, 32);
}

} // namespace

void relaySetConfig(const RelayConfig& cfg) {
    {
        std::unique_lock<std::shared_mutex> lk(g_mu);
        g_cfg = cfg;
    }
    // 重新注入配置视为"恢复健康"：清掉熔断，让新票据立刻可用
    g_consecutive_failures.store(0, std::memory_order_relaxed);
    g_tripped_until_ms.store(0, std::memory_order_relaxed);
    AMCL_LOG_I(LOG_TAG,
        "relay config: enabled=%{public}d base=%{public}s proof=%{public}d ttl_ms=%{public}lld",
        cfg.enabled ? 1 : 0, cfg.base.c_str(), cfg.require_proof ? 1 : 0,
        (long long)(cfg.expires_at_ms > 0 ? cfg.expires_at_ms - nowMs() : 0));
}

void relayDisable() {
    std::unique_lock<std::shared_mutex> lk(g_mu);
    g_cfg = RelayConfig{};
    AMCL_LOG_I(LOG_TAG, "relay disabled");
}

bool relayTripped() {
    int64_t until = g_tripped_until_ms.load(std::memory_order_relaxed);
    return until > 0 && nowMs() < until;
}

bool relayUsable() {
    if (relayTripped()) return false;
    std::shared_lock<std::shared_mutex> lk(g_mu);
    if (!g_cfg.enabled) return false;
    if (g_cfg.base.empty() || g_cfg.ticket.empty()) return false;
    if (g_cfg.require_proof && g_cfg.session_key.empty()) return false;
    // 留 30s 余量：避免请求在途中票据到期
    if (g_cfg.expires_at_ms > 0 && nowMs() > g_cfg.expires_at_ms - 30000) return false;
    return true;
}

bool relayCanAccelerate(const std::string& url) {
    if (!relayUsable()) return false;
    std::string host;
    std::string rest;
    if (!splitUrl(url, host, rest)) return false;
    if (rest.find("..") != std::string::npos) return false;
    return isOfficialHost(host);
}

std::string relayRewriteUrl(const std::string& url) {
    if (!relayCanAccelerate(url)) return std::string();
    std::string host;
    std::string rest;
    if (!splitUrl(url, host, rest)) return std::string();
    std::string base;
    {
        std::shared_lock<std::shared_mutex> lk(g_mu);
        base = g_cfg.base;
    }
    if (base.empty()) return std::string();
    while (!base.empty() && base.back() == '/') base.pop_back();
    // rest 原样拼接，不做任何编解码
    return base + "/p/" + host + rest;
}

bool relayIsRelayUrl(const std::string& url) {
    std::shared_lock<std::shared_mutex> lk(g_mu);
    if (g_cfg.base.empty()) return false;
    std::string base = g_cfg.base;
    while (!base.empty() && base.back() == '/') base.pop_back();
    return url.size() > base.size() && url.compare(0, base.size(), base) == 0;
}

bool relayBuildAuthHeaders(const std::string& method,
                           const std::string& url,
                           std::string& out_authorization,
                           std::string& out_ts,
                           std::string& out_nonce,
                           std::string& out_sig) {
    std::string ticket;
    std::string session_key;
    bool require_proof = true;
    {
        std::shared_lock<std::shared_mutex> lk(g_mu);
        if (!g_cfg.enabled || g_cfg.ticket.empty()) return false;
        ticket = g_cfg.ticket;
        session_key = g_cfg.session_key;
        require_proof = g_cfg.require_proof;
    }

    out_authorization = "Authorization: Bearer " + ticket;
    if (!require_proof) {
        out_ts.clear();
        out_nonce.clear();
        out_sig.clear();
        return true;
    }
    if (session_key.empty()) return false;

    // 签名路径从 "/p/" 起截取：与网关侧 rawPathOf() 完全一致，
    // 这样签名与部署前缀（/dl）解耦。
    size_t p = url.find("/p/");
    if (p == std::string::npos) return false;
    const std::string raw_path = url.substr(p);

    const std::string ts = std::to_string(nowMs());
    const std::string nonce = randomNonceHex();
    // v1\n<METHOD>\n<PATH>\n<TS>\n<NONCE>
    std::string canon;
    canon.reserve(raw_path.size() + 64);
    canon.append("v1\n").append(method).append("\n").append(raw_path).append("\n")
         .append(ts).append("\n").append(nonce);
    const std::string sig = hmacSha256Hex(session_key, canon);

    out_ts = "X-AMCL-Ts: " + ts;
    out_nonce = "X-AMCL-Nonce: " + nonce;
    out_sig = "X-AMCL-Sig: " + sig;
    g_requests.fetch_add(1, std::memory_order_relaxed);
    return true;
}

void relayNoteFailure(int http_status) {
    g_failures.fetch_add(1, std::memory_order_relaxed);
    if (http_status == 401 || http_status == 403) {
        g_auth_rejects.fetch_add(1, std::memory_order_relaxed);
        // 鉴权 / 白名单类拒绝对**同一套配置**永远不会自愈：票据不对、签名不符、
        // 目标不在网关白名单里，再试同一个 URL 只是把失败重复一遍。
        // 所以不等攒满 kTripThreshold，立刻熔断，让下一次尝试直接走直连。
        //
        // 这样做是安全的，因为熔断会被两件事解除：
        //   · 60s 冷却到期后自动重新试探；
        //   · ArkTS 侧续签票据时调 relaySetConfig，那里会清掉熔断状态 ——
        //     所以"票据过期"这种真·瞬时问题不会白等 60s。
        //
        // 背景（2026-08-02）：nginx 把 %2B 解码成 + 导致带 `+` 的模组一律
        // proof_mismatch 401。当时每个模组都要先失败若干次才攒够 5 次熔断，
        // 表现就像"模组被屏蔽"。根因已修，但这条快速回退能让同类问题只损失一次尝试。
        g_tripped_until_ms.store(nowMs() + kTripCooldownMs, std::memory_order_relaxed);
        g_consecutive_failures.store(0, std::memory_order_relaxed);
        AMCL_LOG_W(LOG_TAG,
            "relay auth/whitelist reject (http=%{public}d) -> tripped for %{public}lldms, "
            "falling back to direct immediately",
            http_status, (long long)kTripCooldownMs);
        return;
    }
    int n = g_consecutive_failures.fetch_add(1, std::memory_order_relaxed) + 1;
    if (n >= kTripThreshold) {
        g_tripped_until_ms.store(nowMs() + kTripCooldownMs, std::memory_order_relaxed);
        g_consecutive_failures.store(0, std::memory_order_relaxed);
        AMCL_LOG_W(LOG_TAG,
            "relay tripped for %{public}lldms after %{public}d consecutive failures (last http=%{public}d); "
            "falling back to direct",
            (long long)kTripCooldownMs, n, http_status);
    }
}

void relayNoteSuccess() {
    g_consecutive_failures.store(0, std::memory_order_relaxed);
}

RelayStats relayStats() {
    RelayStats s;
    s.requests = g_requests.load(std::memory_order_relaxed);
    s.failures = g_failures.load(std::memory_order_relaxed);
    s.fallbacks = g_fallbacks.load(std::memory_order_relaxed);
    s.auth_rejects = g_auth_rejects.load(std::memory_order_relaxed);
    return s;
}

} // namespace download
