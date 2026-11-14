#pragma once
/**
 * 公共metadata网关opt-in的真实socket回归。复用relay_cases.h仅传输边界HTTPS映射、
 * 服务器HMAC核对及nonce计数；生产候选、证明、手动跳转、正文上限和回退算法不替换。
 * 不验证TLS或公网速度；真机仍须经正常JDK列表刷新、重新安装取得独立交付证据。
 */
namespace metadata_relay_cases {

/**
 * 目录专用两种服务时序：网关静默但原站立即响应，或同一网关302后需要重签。
 * 每个连接独占线程以免夹具的静默连接串行堵住回源；析构先停止accept、再join
 * 每个客户端，不遗留后台sleep/socket，也不依赖公网/DNS/TLS替换下载策略。
 */
class TimedFixture {
public:
    int listener = -1, port = 0;
    const bool silent;
    std::atomic<bool> stopping{false}, invalid_proof{false};
    std::atomic<int> gateway{0}, direct{0};
    std::thread accepting;
    std::vector<std::thread> clients;
    std::mutex nonces_mutex;
    std::set<std::string> nonces;
    std::string base;
    const std::string body = "metadata-catalog-ok";

    explicit TimedFixture(bool silence) : silent(silence) {
        listener = ::socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
        sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        assert(::bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
        socklen_t size = sizeof(address);
        assert(::getsockname(listener, reinterpret_cast<sockaddr*>(&address), &size) == 0);
        port = ntohs(address.sin_port); assert(::listen(listener, 8) == 0);
        base = "https://metadata-" + std::to_string(port) + ".fixture.invalid/dl";
        relay_fixture_port = port;
        download::RelayConfig config; config.enabled = true; config.base = base;
        config.ticket = "relay-test-ticket"; config.session_key = "relay-test-session-key";
        download::relaySetConfig(config);
        accepting = std::thread([this] {
            while (!stopping) {
                pollfd ready{listener, POLLIN, 0}; if (::poll(&ready, 1, 20) <= 0) continue;
                const int client = ::accept(listener, nullptr, nullptr); if (client < 0) continue;
                clients.emplace_back([this, client] { serve(client); });
            }
        });
    }
    ~TimedFixture() {
        stopping = true; if (accepting.joinable()) accepting.join();
        for (auto& client : clients) client.join();
        ::close(listener); relay_fixture_port = 0; download::relayDisable();
    }
private:
    void serve(int client) {
        timeval timeout{1, 0}; ::setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        std::string request; char buffer[2048];
        while (!stopping && request.find("\r\n\r\n") == std::string::npos && request.size() < 16384) {
            const auto count = ::recv(client, buffer, sizeof(buffer), 0);
            if (count <= 0) break; request.append(buffer, static_cast<size_t>(count));
        }
        const size_t first = request.find(' '), last = request.find(' ', first + 1);
        const std::string path = request.substr(first + 1, last - first - 1);
        const bool via = path.rfind("/dl/p/", 0) == 0;
        if (via) {
            ++gateway;
            const auto ts = relayFixtureHeader(request, "X-AMCL-Ts");
            const auto nonce = relayFixtureHeader(request, "X-AMCL-Nonce");
            const auto sig = relayFixtureHeader(request, "X-AMCL-Sig");
            const std::string canonical = "v1\nGET\n" + path.substr(3) + "\n" + ts + "\n" + nonce;
            std::lock_guard<std::mutex> lock(nonces_mutex);
            if (relayFixtureHeader(request, "Authorization") != "Bearer relay-test-ticket" || nonce.empty() ||
                !nonces.insert(nonce).second || sig != download::hmacSha256Hex("relay-test-session-key", canonical)) invalid_proof = true;
        } else {
            ++direct;
            if (!relayFixtureHeader(request, "Authorization").empty() ||
                !relayFixtureHeader(request, "X-AMCL-Sig").empty()) invalid_proof = true;
        }
        if (via && silent) {
            // Native必须在唯一候选内为回源保留预算；由析构打断服务端等待，不能让
            // “curl客户端超时”掩盖服务器线程仍常驻这一资源生命周期错误。
            while (!stopping) std::this_thread::sleep_for(std::chrono::milliseconds(10));
        } else {
            const bool redirect = via && path.find("final.json") == std::string::npos;
            const std::string header = redirect
                ? "HTTP/1.1 302 Fixture\r\nLocation: " + base + "/p/piston-data.mojang.com/final.json\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 200 Fixture\r\nContent-Length: " + std::to_string(body.size()) + "\r\nConnection: close\r\n\r\n" + body;
            size_t sent = 0;
            while (sent < header.size()) {
                const auto count = ::send(client, header.data() + sent, header.size() - sent, MSG_NOSIGNAL);
                if (count <= 0) break; sent += static_cast<size_t>(count);
            }
        }
        ::shutdown(client, SHUT_RDWR); ::close(client);
    }
};

/** 唯一候选的网关黑洞仍有界回原站；同网关302须签当前path、使用独立nonce。 */
inline void idleAndRedirect(download::DownloadEngine& engine) {
    for (bool silent : {true, false}) {
        TimedFixture server(silent); download::FetchResponse result;
        const auto start = std::chrono::steady_clock::now();
        assert(engine.fetchToBufferEx("https://piston-data.mojang.com/catalog.json", {}, 4, {}, 128, result, true) == 0);
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
        assert(result.body == server.body && result.err_kind.empty() && result.err_msg.empty());
        assert(server.gateway == (silent ? 1 : 2) && server.direct == (silent ? 1 : 0));
        assert(!server.invalid_proof && elapsed < 3800);
        if (silent) assert(elapsed >= 1500);
    }
    std::cout << "PASS metadata silent relay yields within shared deadline and same-gateway redirects receive fresh valid proof" << std::endl;
}

/** 每case重配真实网关以清除前项熔断；票据仅为回环夹具，无真实用户材料。 */
inline void configure(RelayHttpFixture& server) {
    download::RelayConfig config;
    config.enabled = true; config.base = server.base;
    config.ticket = "relay-test-ticket"; config.session_key = server.key;
    download::relaySetConfig(config);
}

/** 来源只有一个官方URL；测试不会把第三方镜像当作“网关回退”的替代品。 */
inline std::string official(const std::string& endpoint) {
    return "https://piston-data.mojang.com/amcl-relay-test/metadata-" + endpoint + ".json";
}

/** 旧默认和用户关网关都维持源站；opt-in成功须在服务端核对真实签名及精确正文。 */
inline void routing(download::DownloadEngine& engine) {
    for (int mode = 0; mode < 3; ++mode) {
        RelayHttpFixture server(257); configure(server);
        if (mode == 2) download::relayDisable();
        const auto before = download::relayStats(); download::FetchResponse result;
        const int code = mode == 0
            ? engine.fetchToBufferEx(official("default"), {}, 5, {}, 512, result)
            : engine.fetchToBufferEx(official("opt-in"), {}, 5, {}, 512, result, true);
        assert(code == 0 && result.body == server.payload && result.status_code == 200);
        const bool via = mode == 1; const auto after = download::relayStats();
        std::lock_guard<std::mutex> lock(server.mutex);
        assert(server.gateway == (via ? 1 : 0) && server.direct == (via ? 0 : 1));
        assert(!server.invalid_proof && !server.duplicate_nonce && !server.leaked_headers);
        assert(after.requests - before.requests == (via ? 1 : 0));
        assert(after.fallbacks == before.fallbacks && after.failures == before.failures);
    }
    download::relayDisable();
    std::cout << "PASS metadata opt-in proves real relay HMAC; default and disabled relay retain origin-only route" << std::endl;
}

/** HTTP拒绝/断流只回同一源站一次；回源失败不套回网关，也不偷偷加第三方镜像。 */
inline void boundedFallback(download::DownloadEngine& engine) {
    for (const std::string endpoint : {"deny401", "deny503", "partial", "bounce503"}) {
        RelayHttpFixture server(257); configure(server);
        const auto before = download::relayStats(); download::FetchResponse result;
        const int code = engine.fetchToBufferEx(official(endpoint), {}, 5, {}, 512, result, true);
        const auto after = download::relayStats();
        assert((code == 0) == (endpoint != "bounce503"));
        if (code == 0) assert(result.body == server.payload && result.status_code == 200);
        else assert(result.status_code == 503);
        std::lock_guard<std::mutex> lock(server.mutex);
        assert(server.gateway == 1 && server.direct == 1 && server.external == 0);
        assert(!server.invalid_proof && !server.duplicate_nonce && !server.leaked_headers);
        assert(after.requests == before.requests + 1 && after.fallbacks == before.fallbacks + 1);
        assert(after.failures == before.failures + 1);
    }
    download::relayDisable();
    std::cout << "PASS metadata 401/503/truncated-body fall back once to same origin; direct 503 never re-enters relay" << std::endl;
}

/** 外部跳转不能携带网关票据；业务Bearer即使opt-in仍只交原始官方主机。 */
inline void credentialBoundaries(download::DownloadEngine& engine) {
    {
        RelayHttpFixture server(257); configure(server); download::FetchResponse result;
        assert(engine.fetchToBufferEx(official("redirect"), {}, 5, {}, 512, result, true) == 0);
        assert(result.body == server.payload);
        std::lock_guard<std::mutex> lock(server.mutex);
        assert(server.gateway == 1 && server.external == 1 && server.direct == 0);
        assert(!server.leaked_headers && !server.invalid_proof);
    }
    {
        RelayHttpFixture server(257); configure(server); download::FetchResponse result;
        assert(engine.fetchToBufferEx(official("business"), {}, 5,
            {{"Authorization", "Bearer business-lease"}}, 512, result, true) == 0);
        std::lock_guard<std::mutex> lock(server.mutex);
        assert(server.gateway == 0 && server.direct == 1 && server.authorized == 1);
        assert(!server.leaked_headers);
    }
    download::relayDisable();
    std::cout << "PASS metadata redirect strips relay credentials and caller business Bearer disables relay" << std::endl;
}

/** 超解压后正文上限属于本地拒绝，不惩罚网关或通过回退绕过限制。 */
inline void responseLimit(download::DownloadEngine& engine) {
    RelayHttpFixture server(257); configure(server); download::FetchResponse result;
    const auto before = download::relayStats();
    assert(engine.fetchToBufferEx(official("oversized"), {}, 5, {}, 128, result, true) != 0);
    const auto after = download::relayStats();
    assert(result.err_kind == "ResponseTooLarge" && result.body.empty());
    {
        std::lock_guard<std::mutex> lock(server.mutex);
        assert(server.gateway == 1 && server.direct == 0);
        assert(!server.invalid_proof && !server.leaked_headers);
    }
    assert(after.failures == before.failures && after.fallbacks == before.fallbacks);
    download::relayDisable();
    std::cout << "PASS metadata relay retains real body cap without fallback or false gateway failure" << std::endl;
}
} // namespace metadata_relay_cases

inline void runMetadataRelayCases(download::DownloadEngine& engine) {
    metadata_relay_cases::routing(engine);
    metadata_relay_cases::boundedFallback(engine);
    metadata_relay_cases::credentialBoundaries(engine);
    metadata_relay_cases::responseLimit(engine);
    metadata_relay_cases::idleAndRedirect(engine);
}
