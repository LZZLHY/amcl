/**
 * 来源三模式的真实正文补证。两个独立loopback origin交付相同8MiB，镜像正文限速、
 * 官方正文快速；只改变fixture线路，不修改生产调度、评分和默认线程数。
 * 复用已复现的8连接/默认4连接真实正文场景；另验size-only/授权/单GET边界，默认
 * 强摘要首批必须实际收到第二允许源的样本，不能拿准备就绪或计时器替代。
 * server写入量仅用于确认请求触达；通过条件依赖最终完整字节/SHA及Native真实正文采样。
 */
#pragma once
#include <algorithm>
#include <cctype>

class ColdSourceBodyFixture {
public:
    int fd = -1, port = 0;
    const std::string host, body;
    const int pause_ms;
    std::atomic<bool> stopped{false};
    std::atomic<int> requests{0};
    std::atomic<long long> sent{0};
    std::thread acceptor;
    std::vector<std::thread> workers;

    ColdSourceBodyFixture(std::string address, const std::string& payload, int delay)
        : host(std::move(address)), body(payload), pause_ms(delay) {
        fd = ::socket(AF_INET, SOCK_STREAM, 0); assert(fd >= 0);
        int yes = 1; ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        sockaddr_in addr{}; addr.sin_family = AF_INET; addr.sin_addr.s_addr = inet_addr(host.c_str());
        assert(::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);
        socklen_t len = sizeof(addr); assert(::getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) == 0);
        port = ntohs(addr.sin_port); assert(::listen(fd, 32) == 0);
        acceptor = std::thread([this] {
            while (!stopped.load()) {
                int peer = ::accept(fd, nullptr, nullptr);
                if (peer < 0) break;
                workers.emplace_back([this, peer] { serve(peer); ::close(peer); });
            }
        });
    }
    ~ColdSourceBodyFixture() {
        stopped.store(true); ::shutdown(fd, SHUT_RDWR); ::close(fd);
        if (acceptor.joinable()) acceptor.join();
        for (auto& worker : workers) if (worker.joinable()) worker.join();
    }
    std::string url() const { return "http://" + host + ":" + std::to_string(port) + "/immutable.jar"; }
    static bool sendAll(int peer, const char* data, size_t bytes) {
        while (bytes) {
            auto n = ::send(peer, data, bytes, MSG_NOSIGNAL);
            if (n <= 0) return false;
            data += n; bytes -= static_cast<size_t>(n);
        }
        return true;
    }
    /** 只交付请求声明的精确字节范围；服务端限速塑造线路差异，客户端调度保持生产实现。 */
    void serve(int peer) {
        timeval timeout{2, 0}; ::setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        std::string request; char buffer[4096];
        while (request.find("\r\n\r\n") == std::string::npos && request.size() < 32768) {
            auto n = ::recv(peer, buffer, sizeof(buffer), 0); if (n <= 0) return;
            request.append(buffer, static_cast<size_t>(n));
        }
        std::string lower = request;
        std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return std::tolower(c); });
        size_t begin = 0, end = body.size() - 1;
        auto range = lower.find("\r\nrange: bytes=");
        bool partial = range != std::string::npos;
        if (partial) {
            auto start = range + 15, dash = lower.find('-', start);
            assert(dash != std::string::npos);
            begin = std::stoull(lower.substr(start, dash - start));
            if (lower[dash + 1] != '\r') end = std::stoull(lower.substr(dash + 1));
        }
        assert(begin <= end && end < body.size());
        bool head = request.rfind("HEAD ", 0) == 0;
        std::string header = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n";
        header += "Content-Length: " + std::to_string(end - begin + 1) + "\r\nAccept-Ranges: bytes\r\nConnection: close\r\n";
        if (partial) header += "Content-Range: bytes " + std::to_string(begin) + "-" + std::to_string(end) + "/" + std::to_string(body.size()) + "\r\n";
        header += "\r\n";
        if (!sendAll(peer, header.data(), header.size()) || head) return;
        requests.fetch_add(1);
        for (size_t offset = begin; offset <= end && !stopped.load();) {
            size_t count = std::min<size_t>(16384, end - offset + 1);
            if (!sendAll(peer, body.data() + offset, count)) return;
            sent.fetch_add(static_cast<long long>(count)); offset += count;
            if (pause_ms) std::this_thread::sleep_for(std::chrono::milliseconds(pause_ms));
        }
    }
};

static void runColdSourceRaceCases(download::DownloadEngine& engine, const fs::path& root) {
    std::string body(8 * 1024 * 1024, '\0');
    for (size_t i = 0; i < body.size(); ++i) body[i] = static_cast<char>((i * 31 + i / 251) % 251);
    download::Sha1 hash; hash.update(body.data(), body.size()); auto sha = hash.finalizeHex();
    for (int mode = 0; mode < 6; ++mode) {
        ColdSourceBodyFixture mirror("127.0.0.91", body, mode == 5 ? 0 : 50), official("127.0.0.92", body, 0);
        auto target = root / ("source-mode-" + std::to_string(mode) + ".jar");
        auto cfg = config("source-mode-real-body", root, target);
        cfg.files[0].urls = mode == 2 ? std::vector<std::string>{official.url()}
            : std::vector<std::string>{mirror.url(), official.url()};
        cfg.files[0].check.expected_size = body.size(); cfg.files[0].check.expected_sha1 = sha;
        cfg.files[0].max_connections = mode == 0 || mode == 2 ? 8 : (mode == 5 ? 1 : 4);
        // 弱身份没有内容摘要，授权路径即便有摘要也不能因本次冷启动修复新增跨源请求。
        if (mode == 3) cfg.files[0].check.expected_sha1.clear();
        if (mode == 4) {
            cfg.files[0].authorized_policy = true;
            cfg.files[0].authorized_max_http_attempts = 30;
            cfg.files[0].authorized_valid_for_ms = 300000;
            cfg.files[0].authorized_max_bytes = body.size() * 4;
        }
        auto task = engine.createTask(cfg); assert(engine.startTask(task->taskId())); waitForSettled(task);
        assert(task->state() == download::LoadState::Finished);
        assert(readFixtureFile(target) == body);
        auto file = task->files().front(); const auto& sources = file->sources();
        auto winner = file->pickBestSource(true);
        const bool official_sampled = sources.back()->avgThroughputBps() > 0;
        // 先落真实计数再裁决，负控失败时同样保留官方是否被访问/采样的证据。
        std::cout << "COLD_SOURCE_BODY {\"mode\":" << mode << ",\"connections\":" << cfg.files[0].max_connections
            << ",\"verifiedBytes\":" << body.size() << ",\"sha1\":\"" << sha << "\",\"mirrorRequests\":" << mirror.requests
            << ",\"officialRequests\":" << official.requests << ",\"officialSampled\":" << (official_sampled ? "true" : "false")
            << ",\"mirrorBps\":" << (mode == 2 ? 0 : sources.front()->avgThroughputBps())
            << ",\"officialBps\":" << sources.back()->avgThroughputBps()
            << ",\"officialNextSelected\":" << (winner && winner->url == official.url() ? "true" : "false") << "}" << std::endl;
        // 高并发及新的强摘要default4均须真实采到官方正文；快官方应在后续评分选择胜出。
        if (mode == 0 || mode == 1) {
            assert(mirror.requests > 0 && official.requests > 0 && official_sampled);
            assert(sources.back()->avgThroughputBps() > sources.front()->avgThroughputBps());
            assert(winner && winner->url == official.url());
        }
        if (mode == 2) assert(mirror.requests == 0 && official_sampled);
        if (mode == 3 || mode == 4 || mode == 5) assert(mirror.requests > 0 && official.requests == 0 && !official_sampled);
        if (mode == 5) assert(mirror.requests == 1);
        // 新完成样本/早让渡只属于strong普通default4；原high、单源、弱身份、授权、
        // 单GET均不得因为共用NetThread而被偷偷纳入（真实传输完成后仍必须为0）。
        if (mode != 1) for (const auto& source : sources)
            assert(source->completedTransferGoodputBps() == 0);
        // 包括weak case也独立读取完整真实文件核摘要，不把大小一致冒充字节正确。
        assert(download::computeFileSha1(target.string()) == sha);
        purgeSettled(engine, task->taskId());
    }
}
