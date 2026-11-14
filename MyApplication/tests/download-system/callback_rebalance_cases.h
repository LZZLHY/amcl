/**
 * 真实worker的慢尾与网关归责回归。复用relay_cases的专用HTTPS→回环映射，真实执行
 * curl、onProgress、Range续传和最终SHA；不修改生产时钟或阈值，不声称验证TLS。
 */
#pragma once

namespace callback_rebalance_cases {

/**
 * 两段HTTP独立流式响应。首段可短抖动、持续低速或完全无正文，另一段提供真实快peer；
 * 服务端记录网关/直连/续传次数，保证结论来自实际HTTP而不是测试调用生产分类helper。
 * 析构先停止accept再join所有连接，失败保留外层夹具文件，成功由suite回收自有目录。
 */
class StreamingRelayFixture {
public:
    enum class Mode { Burst, Sustained, NoProgress, Cancel };
    const Mode mode;
    const std::string payload;
    const int64_t started = download::netThreadSteadyNowMs();
    std::string base;
    int listener = -1, port = 0;
    std::atomic<bool> stop{false};
    std::atomic<int> gateway{0}, direct{0}, resumed_gateway{0}, invalid_headers{0};
    std::thread acceptor;
    std::vector<std::thread> clients;

    explicit StreamingRelayFixture(Mode selected) : mode(selected), payload(makePayload()) {
        listener = ::socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
        sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        assert(::bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
        socklen_t size = sizeof(address); assert(::getsockname(listener, reinterpret_cast<sockaddr*>(&address), &size) == 0);
        port = ntohs(address.sin_port); assert(::listen(listener, 8) == 0);
        base = "https://stream-" + std::to_string(port) + ".fixture.invalid/dl";
        relay_fixture_port = port;
        acceptor = std::thread([this] {
            while (!stop.load()) {
                pollfd ready{listener, POLLIN, 0};
                if (::poll(&ready, 1, 50) <= 0) continue;
                const int socket = ::accept(listener, nullptr, nullptr);
                if (socket >= 0) clients.emplace_back([this, socket] { serve(socket); });
            }
        });
    }
    ~StreamingRelayFixture() {
        stop = true; if (acceptor.joinable()) acceptor.join();
        for (auto& client : clients) if (client.joinable()) client.join();
        if (listener >= 0) ::close(listener);
        relay_fixture_port = 0;
    }

private:
    /** 不同偏移有不同正文，避免Range错位也恰好通过恒定字符检查。 */
    static std::string makePayload() {
        std::string data(16 * 1024 * 1024, '\0');
        for (size_t i = 0; i < data.size(); ++i) data[i] = static_cast<char>('a' + i % 23);
        return data;
    }
    /** 取消/断连后尽快退出服务线程，不留下后台socket消费者。 */
    bool pause(int socket, int64_t milliseconds) {
        const int64_t until = download::netThreadSteadyNowMs() + milliseconds;
        while (!stop.load() && download::netThreadSteadyNowMs() < until) {
            pollfd ready{socket, POLLIN | POLLHUP, 0};
            if (::poll(&ready, 1, 20) > 0) {
                char peek; if (::recv(socket, &peek, 1, MSG_PEEK | MSG_DONTWAIT) == 0) return false;
            }
        }
        return !stop.load();
    }
    bool sendAll(int socket, const char* data, size_t bytes) {
        size_t sent = 0;
        while (!stop.load() && sent < bytes) {
            const auto count = ::send(socket, data + sent, bytes - sent, MSG_NOSIGNAL);
            if (count <= 0) return false;
            sent += static_cast<size_t>(count);
        }
        return sent == bytes;
    }
    /** 每个HTTP只处理自己的Range；只有原始低速首段受调速，续传立即给完整正确内容。 */
    void serve(int socket) {
        timeval timeout{2, 0};
        ::setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        ::setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        std::string request; char buffer[4096];
        while (request.find("\r\n\r\n") == std::string::npos && request.size() < 16384) {
            const auto count = ::recv(socket, buffer, sizeof(buffer), 0);
            if (count <= 0) break; request.append(buffer, static_cast<size_t>(count));
        }
        const size_t first = request.find(' '), last = request.find(' ', first + 1);
        const std::string path = request.substr(first + 1, last - first - 1);
        const bool via = path.rfind("/dl/p/", 0) == 0;
        const std::string range = relayFixtureHeader(request, "Range");
        assert(range.rfind("bytes=", 0) == 0);
        const auto dash = range.find('-');
        const size_t offset = std::stoull(range.substr(6, dash - 6));
        const size_t end = std::stoull(range.substr(dash + 1));
        const size_t half = payload.size() / 2;
        assert(offset <= end && end < payload.size());
        if (via) {
            ++gateway; if (offset > 0 && offset < half) ++resumed_gateway;
            const auto ts = relayFixtureHeader(request, "X-AMCL-Ts");
            const auto nonce = relayFixtureHeader(request, "X-AMCL-Nonce");
            const std::string canonical = "v1\nGET\n" + path.substr(3) + "\n" + ts + "\n" + nonce;
            if (relayFixtureHeader(request, "Authorization") != "Bearer relay-test-ticket" || nonce.empty() ||
                relayFixtureHeader(request, "X-AMCL-Sig") != download::hmacSha256Hex("relay-test-session-key", canonical)) ++invalid_headers;
        } else {
            ++direct;
            if (!relayFixtureHeader(request, "Authorization").empty() || !relayFixtureHeader(request, "X-AMCL-Sig").empty()) ++invalid_headers;
        }
        const std::string headers = "HTTP/1.1 206 Fixture\r\nContent-Length: " + std::to_string(end - offset + 1) +
            "\r\nContent-Range: bytes " + std::to_string(offset) + "-" + std::to_string(end) + "/" +
            std::to_string(payload.size()) + "\r\nConnection: close\r\n\r\n";
        bool open = sendAll(socket, headers.data(), headers.size());
        size_t current = offset;
        while (open && current <= end && !stop.load()) {
            const int64_t elapsed = download::netThreadSteadyNowMs() - started;
            if (mode == Mode::Cancel || (mode == Mode::NoProgress && via && offset == 0)) {
                open = pause(socket, 50); continue;
            }
            // 19秒后快peer已证明持续存在；结束调速使测试有界收敛，无需等8MiB慢流传完。
            const bool paced = via && elapsed < 19000 && (offset == 0 || offset == half);
            const bool slow_first = paced && offset == 0;
            const size_t quantum = !paced ? 1024 * 1024 : (slow_first ? (mode == Mode::Burst ? 64 * 1024 : 4096) : 16 * 1024);
            const size_t count = std::min(quantum, end - current + 1);
            open = sendAll(socket, payload.data() + current, count); current += count;
            if (open && paced) open = pause(socket, slow_first ? 500 : 40);
        }
        ::shutdown(socket, SHUT_RDWR); ::close(socket);
    }
};

/** 边界使用生产纯策略；间歇恢复、peer消失和新hop清零均不能继承旧慢尾证据。 */
static void slowWindowBoundaries() {
    std::atomic<int64_t> since{0};
    assert(!download::sustainedTransportPeerSlow(since, 10000, true));
    assert(!download::sustainedTransportPeerSlow(since, 12999, true));
    assert(download::sustainedTransportPeerSlow(since, 13000, true));
    assert(!download::sustainedTransportPeerSlow(since, 13001, false) && since == 0);
    assert(!download::sustainedTransportPeerSlow(since, 15000, true));
    assert(!download::sustainedTransportPeerSlow(since, 15001, false));
    assert(!download::sustainedTransportPeerSlow(since, 18000, true));
    assert(!download::sustainedTransportPeerSlow(since, 18001, false));
    std::cout << "PASS sustained peer window rejects burst/recovered/no-peer and accepts continuous 3s" << std::endl;
}

/** 通过真实服务器请求计数与实际最终SHA裁决，不以内部callback标志或完成声明冒充成功。 */
static void transfer(download::DownloadEngine& engine, const fs::path& root, StreamingRelayFixture::Mode mode,
                     const std::string& name) {
    StreamingRelayFixture server(mode);
    download::RelayConfig relay; relay.enabled = true; relay.base = server.base;
    relay.ticket = "relay-test-ticket"; relay.session_key = "relay-test-session-key";
    download::relaySetConfig(relay); const auto before = download::relayStats();
    auto task_config = config("callback real worker " + name, root, root / (name + ".jar"));
    auto& file = task_config.files[0];
    file.urls = {"https://piston-data.mojang.com/amcl-relay-test/callback.jar"};
    file.max_connections = 2; file.piece_min_bytes = 1024 * 1024;
    file.check.expected_size = server.payload.size();
    download::Sha1 sha; sha.update(server.payload.data(), server.payload.size()); file.check.expected_sha1 = sha.finalizeHex();
    auto task = engine.createTask(task_config); assert(engine.startTask(task->taskId()));
    if (mode == StreamingRelayFixture::Mode::Cancel) {
        for (int i = 0; i < 100 && server.gateway.load() < 2; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(10));
        assert(server.gateway == 2); task->abort();
    }
    waitForSettled(task); const auto after = download::relayStats();
    std::cout << "CALLBACK EVIDENCE case=" << name << " gateway=" << server.gateway << " direct=" << server.direct
              << " resumedGateway=" << server.resumed_gateway << " failureDelta=" << after.failures - before.failures
              << " fallbackDelta=" << after.fallbacks - before.fallbacks
              << " elapsedMs=" << download::netThreadSteadyNowMs() - server.started << std::endl;
    assert(server.invalid_headers == 0 && after.requests - before.requests == server.gateway);
    if (mode == StreamingRelayFixture::Mode::Cancel) {
        assert(task->state() == download::LoadState::Aborted && server.direct == 0);
        assert(after.failures == before.failures && after.fallbacks == before.fallbacks);
    } else {
        assert(task->state() == download::LoadState::Finished && readFixtureFile(file.local_path) == server.payload);
        if (mode == StreamingRelayFixture::Mode::NoProgress) {
            assert(server.direct == 1 && after.failures - before.failures == 1 && after.fallbacks - before.fallbacks == 1);
        } else {
            assert(server.direct == 0 && after.failures == before.failures && after.fallbacks == before.fallbacks);
            if (mode == StreamingRelayFixture::Mode::Sustained) assert(server.resumed_gateway >= 1);
            else assert(server.gateway == 2 && server.resumed_gateway == 0);
        }
    }
    purgeSettled(engine, task->taskId()); download::relayDisable();
    std::cout << "PASS real worker callback " << name << " response/hash/route/owner facts" << std::endl;
}
}

/** 可选定向case仅供宿主负控复用同一业务断言；默认运行全部真实正反边界。 */
static void runCallbackRebalanceCases(download::DownloadEngine& engine, const fs::path& root) {
    using namespace callback_rebalance_cases;
    const char* choice = std::getenv("AMCL_CALLBACK_REBALANCE_CASE");
    const std::string selected = choice ? choice : "";
    if (selected.empty()) slowWindowBoundaries();
    for (const auto& item : std::vector<std::pair<StreamingRelayFixture::Mode, std::string>>{
        {StreamingRelayFixture::Mode::Burst, "burst"}, {StreamingRelayFixture::Mode::Sustained, "sustained"},
        {StreamingRelayFixture::Mode::NoProgress, "no-progress"}, {StreamingRelayFixture::Mode::Cancel, "cancel"}})
        if (selected.empty() || selected == item.second) transfer(engine, root, item.first, item.second);
}
