#pragma once
/**
 * 两个真实metadata入口的回环故障矩阵。服务端只实现确定的响应时序，不复制候选
 * 选择/截止/进展算法；请求计数来自完整HTTP头实际抵达，全部网络留在独立回环地址。
 * 析构主动结束等待并join，不能用后台sleep把后续场景拖进旧请求或遗留线程。
 */
namespace metadata_fallback_cases {
class Server {
public:
    enum class Mode { Quick, Silent, PartialStall, Drip, ErrorDrip };
    const std::string host;
    const Mode mode;
    int listener = -1, port = 0;
    std::atomic<bool> stopping{false};
    std::atomic<int> requests{0};
    std::thread worker;

    Server(const std::string& address, Mode response) : host(address), mode(response) {
        listener = ::socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
        sockaddr_in local{}; local.sin_family = AF_INET;
        assert(::inet_pton(AF_INET, host.c_str(), &local.sin_addr) == 1);
        assert(::bind(listener, reinterpret_cast<sockaddr*>(&local), sizeof(local)) == 0);
        socklen_t size = sizeof(local);
        assert(::getsockname(listener, reinterpret_cast<sockaddr*>(&local), &size) == 0);
        port = ntohs(local.sin_port); assert(::listen(listener, 8) == 0);
        worker = std::thread([this] { serve(); });
    }
    ~Server() { stopping = true; if (worker.joinable()) worker.join(); ::close(listener); }
    std::string url() const { return "http://" + host + ":" + std::to_string(port) + "/metadata"; }

private:
    /** 只用于服务器的确定性时序；每10ms检查停止，析构不等完整延迟。 */
    void wait(int milliseconds) {
        const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(milliseconds);
        while (!stopping && std::chrono::steady_clock::now() < until)
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    bool sendAll(int client, const std::string& bytes) {
        size_t sent = 0;
        while (!stopping && sent < bytes.size()) {
            const ssize_t count = ::send(client, bytes.data() + sent, bytes.size() - sent, MSG_NOSIGNAL);
            if (count <= 0) return false;
            sent += static_cast<size_t>(count);
        }
        return sent == bytes.size();
    }
    void serve() {
        while (!stopping) {
            pollfd ready{listener, POLLIN, 0}; if (::poll(&ready, 1, 50) <= 0) continue;
            const int client = ::accept(listener, nullptr, nullptr); if (client < 0) continue;
            timeval timeout{1, 0};
            ::setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            ::setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            std::string request; char buffer[2048];
            while (!stopping && request.size() < 16384 && request.find("\r\n\r\n") == std::string::npos) {
                const ssize_t count = ::recv(client, buffer, sizeof(buffer), 0); if (count <= 0) break;
                request.append(buffer, static_cast<size_t>(count));
            }
            if (request.find("\r\n\r\n") != std::string::npos) {
                ++requests;
                const std::string header = std::string("HTTP/1.1 ") + (mode == Mode::ErrorDrip ? "503" : "200") +
                    " Fixture\r\nContent-Length: 12\r\nConnection: close\r\n" +
                    (mode == Mode::ErrorDrip ? "Retry-After: 120\r\n" : "") + "\r\n";
                if (mode == Mode::Silent) wait(15000);
                else if (mode == Mode::PartialStall) { sendAll(client, header + "m"); wait(15000); }
                else if (mode == Mode::Drip || mode == Mode::ErrorDrip) {
                    if (sendAll(client, header)) {
                        for (char byte : std::string("metadata-ok!")) {
                            if (!sendAll(client, std::string(1, byte))) break;
                            wait(450);
                        }
                    }
                } else sendAll(client, header + "metadata-ok!");
            }
            ::shutdown(client, SHUT_RDWR); ::close(client);
        }
    }
};

/** 首字节黑洞和收到一个字节后的停滞都必须让位，不能把30秒再乘候选数。 */
inline void stalledCandidateYields(download::DownloadEngine& engine) {
    for (bool extended : {false, true}) {
        Server slow(extended ? "127.0.0.172" : "127.0.0.170",
                    extended ? Server::Mode::PartialStall : Server::Mode::Silent);
        Server fast(extended ? "127.0.0.173" : "127.0.0.171", Server::Mode::Quick);
        const auto start = std::chrono::steady_clock::now();
        std::string body, kind, message; download::FetchResponse response;
        const int result = extended ? engine.fetchToBufferEx(slow.url(), {fast.url()}, 6, {}, 64, response) :
            engine.fetchToBuffer(slow.url(), {fast.url()}, 6, body, kind, message);
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
        assert(result == 0 && (extended ? response.body : body) == "metadata-ok!");
        assert(slow.requests == 1 && fast.requests == 1 && elapsed < 5500);
    }
    std::cout << "PASS metadata first-byte and partial-body stalls yield to real fallback inside shared budget" << std::endl;
}

/** 持续有效正文可跨过空闲窗口总时长，不能把大manifest误当作需要固定5秒完成。 */
inline void progressiveBodyKeepsItsBudget(download::DownloadEngine& engine) {
    Server drip("127.0.0.174", Server::Mode::Drip), spare("127.0.0.175", Server::Mode::Quick);
    download::FetchResponse response;
    const auto start = std::chrono::steady_clock::now();
    assert(engine.fetchToBufferEx(drip.url(), {spare.url()}, 8, {}, 64, response) == 0);
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
    assert(response.body == "metadata-ok!" && drip.requests == 1 && spare.requests == 0);
    assert(elapsed > 4000 && elapsed < 7500);
    std::cout << "PASS metadata progressing body keeps aggregate request budget without fixed candidate wall cap" << std::endl;
}

/** 全部黑洞只能消耗一份总deadline；已知服务器冷却则零请求切备用且保持冷却事实。 */
inline void deadlineAndCoolingHost(download::DownloadEngine& engine) {
    Server a("127.0.0.176", Server::Mode::Silent), b("127.0.0.177", Server::Mode::Silent);
    download::FetchResponse response;
    const auto start = std::chrono::steady_clock::now();
    assert(engine.fetchToBufferEx(a.url(), {a.url(), b.url()}, 2, {}, 64, response) != 0);
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
    assert(response.err_kind == "Timeout" && elapsed < 3200 && a.requests == 1 && b.requests <= 1);
    Server cooling("127.0.0.178", Server::Mode::Quick), fast("127.0.0.179", Server::Mode::Quick);
    engine.noteHostRateLimit(cooling.host, 120000);
    assert(engine.fetchToBufferEx(cooling.url(), {fast.url()}, 3, {}, 64, response) == 0);
    assert(cooling.requests == 0 && fast.requests == 1 && response.body == "metadata-ok!");
    const int64_t now_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    assert(engine.hostRateLimitUntilMs(cooling.host) > now_ms);
    std::cout << "PASS metadata mirrors share one deadline, duplicate URL is not retried, and cooling host performs no HTTP" << std::endl;
}

/** 名额不足与错误页滴流同样没有有效metadata，不能吞掉后继候选的全部预算。 */
inline void admissionAndErrorBodyYield(download::DownloadEngine& engine) {
    Server occupied("127.0.0.180", Server::Mode::Quick), fast("127.0.0.181", Server::Mode::Quick);
    std::vector<uint64_t> tokens;
    for (int count = 0; count < 64; ++count) {
        uint64_t token = 0; if (!engine.tryAcquireHostSlot(occupied.host, &token)) break;
        tokens.push_back(token);
    }
    assert(!tokens.empty());
    uint64_t overflow = 0; assert(!engine.tryAcquireHostSlot(occupied.host, &overflow));
    download::FetchResponse response;
    auto start = std::chrono::steady_clock::now();
    assert(engine.fetchToBufferEx(occupied.url(), {fast.url()}, 4, {}, 64, response) == 0);
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
    assert(occupied.requests == 0 && fast.requests == 1 && elapsed < 3200);
    for (auto token : tokens) engine.releaseHostSlot(occupied.host, false, token);
    Server error("127.0.0.182", Server::Mode::ErrorDrip), spare("127.0.0.183", Server::Mode::Quick);
    start = std::chrono::steady_clock::now();
    assert(engine.fetchToBufferEx(error.url(), {spare.url()}, 6, {}, 64, response) == 0);
    elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
    assert(response.body == "metadata-ok!" && error.requests == 1 && spare.requests == 1 && elapsed < 5000);
    assert(engine.hostRateLimitUntilMs(error.host) > 0);
    std::cout << "PASS metadata saturated admission and dripping 503 yield without losing server Retry-After" << std::endl;
}
} // namespace metadata_fallback_cases

inline void runMetadataFallbackCases(download::DownloadEngine& engine) {
    metadata_fallback_cases::stalledCandidateYields(engine);
    metadata_fallback_cases::progressiveBodyKeepsItsBudget(engine);
    metadata_fallback_cases::deadlineAndCoolingHost(engine);
    metadata_fallback_cases::admissionAndErrorBodyYield(engine);
}
