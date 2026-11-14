/**
 * 只覆盖strong/noauth普通冷取样新增的一次让渡。真实socket塑造相反线路、零正文与
 * 目标后变慢，完整8MiB仍由生产Range/pwrite/最终SHA交付；server发送量不冒充wire量。
 * observer仅在同步curl返回栈中读取NetThread，将数值事实复制后不再解引用该指针。
 */
#pragma once
#include <map>
#include <poll.h>

namespace cold_source_yield_cases {
struct AttemptFact {
    uintptr_t thread;
    int source, curl, stop;
    int64_t done;
    bool used;
};
std::mutex facts_mu;
std::map<CURL*, download::NetThread*> running;
std::vector<AttemptFact> facts;
void observeData(CURL* easy, void* data) {
    std::lock_guard<std::mutex> lock(facts_mu);
    running[easy] = static_cast<download::NetThread*>(data);
}
void observeResult(CURL* easy, CURLcode result) {
    std::lock_guard<std::mutex> lock(facts_mu);
    auto found = running.find(easy);
    if (found == running.end()) return;
    auto* thread = found->second;
    facts.push_back({reinterpret_cast<uintptr_t>(thread), thread->currentSourceId(),
        static_cast<int>(result), static_cast<int>(thread->callbackStopReason()),
        thread->done(), thread->coldSourceYieldUsed()});
    running.erase(found);
}
void startObservation() {
    { std::lock_guard<std::mutex> lock(facts_mu); assert(running.empty()); facts.clear(); }
    fixture_worker_data_observer.store(observeData);
    fixture_worker_result_observer.store(observeResult);
}
std::vector<AttemptFact> stopObservation() {
    fixture_worker_data_observer.store(nullptr); fixture_worker_result_observer.store(nullptr);
    std::lock_guard<std::mutex> lock(facts_mu); assert(running.empty()); return facts;
}

class BodyServer {
public:
    const std::string body, host;
    const int pause_ms;
    const bool zero_body, partial_drop, change_after_two, invalid_range, relay_only_fault;
    int listener = -1, port = 0;
    std::atomic<bool> stopping{false};
    std::atomic<int> requests{0}, gateway{0}, invalid_proof{0}, leaked_headers{0};
    std::mutex mutex;
    std::vector<std::pair<size_t, size_t>> ranges;
    std::thread acceptor;
    std::vector<std::thread> workers;
    BodyServer(const std::string& data, std::string address, int pause,
               bool empty = false, bool drop = false, bool change = false, bool bad_range = false, bool via_fault = false)
        : body(data), host(std::move(address)), pause_ms(pause), zero_body(empty),
          partial_drop(drop), change_after_two(change), invalid_range(bad_range), relay_only_fault(via_fault) {
        listener = ::socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
        int yes = 1; ::setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        sockaddr_in address_in{}; address_in.sin_family = AF_INET;
        address_in.sin_addr.s_addr = inet_addr(host.c_str());
        assert(::bind(listener, reinterpret_cast<sockaddr*>(&address_in), sizeof(address_in)) == 0);
        socklen_t size = sizeof(address_in);
        assert(::getsockname(listener, reinterpret_cast<sockaddr*>(&address_in), &size) == 0);
        port = ntohs(address_in.sin_port); assert(::listen(listener, 32) == 0);
        acceptor = std::thread([this] {
            while (!stopping.load()) {
                int peer = ::accept(listener, nullptr, nullptr); if (peer < 0) break;
                workers.emplace_back([this, peer] { serve(peer); ::close(peer); });
            }
        });
    }
    ~BodyServer() {
        stopping.store(true); ::shutdown(listener, SHUT_RDWR); ::close(listener);
        if (acceptor.joinable()) acceptor.join();
        for (auto& worker : workers) if (worker.joinable()) worker.join();
    }
    std::string url() const { return "http://" + host + ":" + std::to_string(port) + "/cold-body.jar"; }
    void serve(int peer) {
        timeval timeout{2, 0}; ::setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        std::string request; char buffer[4096];
        while (request.find("\r\n\r\n") == std::string::npos && request.size() < 32768) {
            auto count = ::recv(peer, buffer, sizeof(buffer), 0); if (count <= 0) return;
            request.append(buffer, static_cast<size_t>(count));
        }
        const auto path = request.substr(request.find(' ') + 1,
            request.find(' ', request.find(' ') + 1) - request.find(' ') - 1);
        const auto range = relayFixtureHeader(request, "Range");
        size_t begin = 0, end = body.size() - 1;
        if (range.rfind("bytes=", 0) == 0) {
            const auto dash = range.find('-'); begin = std::stoull(range.substr(6, dash - 6));
            if (dash + 1 < range.size()) end = std::stoull(range.substr(dash + 1));
        }
        assert(begin <= end && end < body.size());
        const bool via = path.rfind("/dl/p/", 0) == 0;
        const auto auth = relayFixtureHeader(request, "Authorization");
        const auto ts = relayFixtureHeader(request, "X-AMCL-Ts");
        const auto nonce = relayFixtureHeader(request, "X-AMCL-Nonce");
        const auto signature = relayFixtureHeader(request, "X-AMCL-Sig");
        if (via) {
            ++gateway;
            const std::string canonical = "v1\nGET\n" + path.substr(3) + "\n" + ts + "\n" + nonce;
            if (auth != "Bearer relay-test-ticket" || nonce.empty() ||
                signature != download::hmacSha256Hex("cold-yield-key", canonical)) ++invalid_proof;
        } else if (!auth.empty() || !ts.empty() || !nonce.empty() || !signature.empty()) ++leaked_headers;
        const bool head = request.rfind("HEAD ", 0) == 0;
        const bool faulty_response = !relay_only_fault || via;
        std::string header = "HTTP/1.1 206 Partial Content\r\nContent-Length: " +
            std::to_string(end - begin + 1) + "\r\nAccept-Ranges: bytes\r\nConnection: close\r\nContent-Range: bytes " +
            std::to_string(begin + (invalid_range && faulty_response ? 1 : 0)) + "-" + std::to_string(end) + "/" + std::to_string(body.size()) + "\r\n\r\n";
        if (!ColdSourceBodyFixture::sendAll(peer, header.data(), header.size()) || head) return;
        const int ordinal = requests.fetch_add(1) + 1;
        { std::lock_guard<std::mutex> lock(mutex); ranges.emplace_back(begin, end); }
        // 无正文服务器保持连接；客户端取消后POLLHUP可观察，析构stop也保证join有界。
        if (zero_body && faulty_response) {
            while (!stopping.load()) {
                pollfd watched{peer, POLLIN | POLLHUP, 0};
                if (::poll(&watched, 1, 20) > 0) {
                    char byte; if (::recv(peer, &byte, 1, MSG_DONTWAIT) <= 0) break;
                }
            }
            return;
        }
        const int delay = change_after_two ? (ordinal <= 2 ? 0 : pause_ms) : pause_ms;
        for (size_t offset = begin; offset <= end && !stopping.load();) {
            size_t count = std::min<size_t>(16384, end - offset + 1);
            if (!ColdSourceBodyFixture::sendAll(peer, body.data() + offset, count)) return;
            offset += count;
            // 真实短响应曾向旧recordSample提供吞吐，但不能成为完成样本。
            if (partial_drop && offset - begin >= 256 * 1024) return;
            if (delay) std::this_thread::sleep_for(std::chrono::milliseconds(delay));
        }
    }
    bool resumedInsidePiece() {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto item : ranges) if (item.first % (2 * 1024 * 1024)) return true;
        return false;
    }
};

void runCase(download::DownloadEngine& engine, const fs::path& root,
             const std::string& body, const std::string& sha, int mode) {
    // 0官方快；1镜像快；2镜像快/官方零正文；3网关慢/镜像快；
    // 4首快源在接续时变慢，另一已完成来源更快也不得二次让渡；5短响应无完成证明；
    // 6零正文同时宣告错误Range，真实callback42也不能掩盖随后协议校验的SizeMismatch。
    BodyServer mirror(body, "127.0.0.93", mode == 0 || mode == 5 ? 50 : (mode == 4 ? 80 : 0), false, false, mode == 4);
    BodyServer official(body, mode == 3 || mode == 6 ? "127.0.0.1" : "127.0.0.94", mode == 0 || mode == 5 || mode == 6 ? 0 : 80,
        mode == 2 || mode == 6, mode == 5, false, mode == 6, mode == 6);
    BodyServer third(body, "127.0.0.95", 5);
    if (mode == 3 || mode == 6) {
        relay_fixture_port.store(official.port);
        download::RelayConfig relay; relay.enabled = true; relay.base = "https://relay.fixture.invalid/dl";
        relay.ticket = "relay-test-ticket"; relay.session_key = "cold-yield-key"; download::relaySetConfig(relay);
    }
    const auto before = download::relayStats();
    auto target = root / ("cold-yield-" + std::to_string(mode) + ".jar");
    auto cfg = config("cold-yield-real-body", root, target);
    cfg.files[0].urls = {mirror.url(), mode == 3 || mode == 6 ? "https://piston-data.mojang.com/cold-body.jar" : official.url()};
    if (mode == 4) cfg.files[0].urls.push_back(third.url());
    cfg.files[0].max_connections = 4; cfg.files[0].check.expected_size = body.size();
    cfg.files[0].check.expected_sha1 = sha;
    startObservation(); const auto started = std::chrono::steady_clock::now();
    auto task = engine.createTask(cfg); assert(engine.startTask(task->taskId())); waitForSettled(task);
    const int64_t elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
    auto observed = stopObservation(); assert(task->state() == download::LoadState::Finished);
    assert(readFixtureFile(target) == body && download::computeFileSha1(target.string()) == sha);
    const auto& sources = task->files().front()->sources();
    const auto after = download::relayStats();
    std::map<uintptr_t, int> yields;
    int local_peer_stops = 0;
    for (const auto& fact : observed) {
        if (fact.curl == CURLE_ABORTED_BY_CALLBACK &&
            fact.stop == static_cast<int>(download::NetThread::CallbackStopReason::PeerRebalance)) {
            assert(fact.used); ++local_peer_stops; ++yields[fact.thread];
        }
    }
    int maximum_yields = 0; for (auto item : yields) maximum_yields = std::max(maximum_yields, item.second);
    std::cout << "COLD_SOURCE_YIELD {\"mode\":" << mode << ",\"elapsedMs\":" << elapsed
        << ",\"verifiedBytes\":" << body.size() << ",\"sha1\":\"" << sha
        << "\",\"mirrorRequests\":" << mirror.requests << ",\"officialRequests\":" << official.requests
        << ",\"thirdRequests\":" << third.requests << ",\"peerStops\":" << local_peer_stops
        << ",\"maximumYieldsPerThread\":" << maximum_yields
        << ",\"mirrorCompletedBps\":" << sources[0]->completedTransferGoodputBps()
        << ",\"officialCompletedBps\":" << sources[1]->completedTransferGoodputBps()
        << ",\"relayFailureDelta\":" << after.failures - before.failures
        << ",\"relayFallbackDelta\":" << after.fallbacks - before.fallbacks << "}" << std::endl;
    if (mode <= 3) {
        assert(local_peer_stops > 0 && maximum_yields == 1 && elapsed < 5000);
        assert(sources[mode == 0 ? 1 : 0]->completedTransferGoodputBps() > 0);
        assert(sources[mode == 0 ? 0 : 1]->completedTransferGoodputBps() == 0);
        for (const auto& source : sources) assert(source->fail_count == 0 && !source->is_failed);
        if (mode != 2) assert(mode == 0 ? official.resumedInsidePiece() : mirror.resumedInsidePiece());
    } else if (mode == 4) {
        // 目标后退化的额外合成场景允许付出有限慢尾，只证明once跨attempt不重置。
        assert(local_peer_stops == 1 && maximum_yields == 1 && mirror.requests == 3 && third.requests == 1);
        bool saw_continuation_used = false;
        for (const auto& fact : observed) if (fact.used && fact.curl == CURLE_OK) saw_continuation_used = true;
        assert(saw_continuation_used && elapsed >= 7000 && elapsed < 15000);
    } else if (mode == 5) {
        assert(sources[1]->avgThroughputBps() > 0 && sources[1]->completedTransferGoodputBps() == 0);
        assert(local_peer_stops == 0); for (const auto& fact : observed) assert(!fact.used);
    } else {
        // 错Range与真实callback42同时存在时必须按协议错记relay失败、沿同官方源直连；
        // 不能被本地Peer理由吞掉或无故把官方源标坏。直连正确Range后才发布完成样本。
        assert(local_peer_stops > 0 && elapsed < 5000 && official.requests == 4 && official.gateway == 2);
        assert(after.failures - before.failures == 2 && after.fallbacks - before.fallbacks == 2);
        assert(sources[1]->completedTransferGoodputBps() > 0 && !sources[1]->no_range_support);
        assert(official.invalid_proof == 0 && official.leaked_headers == 0);
    }
    if (mode == 3) {
        assert(official.gateway == 2 && official.requests == 2 && official.invalid_proof == 0);
        assert(mirror.leaked_headers == 0 && after.failures == before.failures && after.fallbacks == before.fallbacks);
    }
    if (mode == 3 || mode == 6) { download::relayDisable(); relay_fixture_port.store(0); }
    purgeSettled(engine, task->taskId());
}

void proofBoundaries(const fs::path& root) {
    download::NetFile::Config cfg; cfg.local_path = (root / "not-started-proof.jar").string();
    cfg.allowed_root = root.string(); cfg.urls = {"http://127.0.0.93/a", "http://127.0.0.94/a"};
    download::NetFile file(cfg); auto source = file.sources()[1];
    source->range_verified.store(true); source->recordSample(0, 100000000); source->recordSuccess();
    assert(source->avgThroughputBps() > 0 && source->success_count > 0);
    assert(file.completedFasterSourceIndex(0, 100000) == -1);
    source->recordCompletedTransferSample(256 * 1024 - 1, 0);
    assert(source->completedTransferGoodputBps() == 0);
    source->recordCompletedTransferSample(256 * 1024, 0);
    assert(source->completedTransferGoodputBps() == 256 * 1024 * 1000LL / 20);
    assert(file.completedFasterSourceIndex(0, 100000) == 1);
    source->cooldown_until_ms.store(download::netThreadSteadyNowMs() + 10000);
    assert(file.completedFasterSourceIndex(0, 100000) == -1); source->cooldown_until_ms.store(0);
    source->no_range_support.store(true); assert(file.completedFasterSourceIndex(0, 100000) == -1);
    source->no_range_support.store(false); source->checksum_bad.store(true);
    assert(file.completedFasterSourceIndex(0, 100000) == -1); source->checksum_bad.store(false);
    source->is_failed.store(true); assert(file.completedFasterSourceIndex(0, 100000) == -1);
    std::cout << "PASS cold completion proof excludes old/partial/tiny samples and unavailable candidates" << std::endl;
}

void cancelCase(download::DownloadEngine& engine, const fs::path& root,
                const std::string& body, const std::string& sha) {
    BodyServer mirror(body, "127.0.0.93", 0), official(body, "127.0.0.94", 0, true);
    auto cfg = config("cold-cancel-real-body", root, root / "cold-cancel.jar");
    cfg.files[0].urls = {mirror.url(), official.url()}; cfg.files[0].max_connections = 4;
    cfg.files[0].check.expected_size = body.size(); cfg.files[0].check.expected_sha1 = sha;
    startObservation(); auto task = engine.createTask(cfg); assert(engine.startTask(task->taskId()));
    for (int i = 0; i < 100 && !(official.requests == 2 &&
        task->files().front()->sources()[0]->completedTransferGoodputBps() > 0); ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    assert(official.requests == 2 && task->files().front()->sources()[0]->completedTransferGoodputBps() > 0);
    task->abort(); waitForSettled(task); auto observed = stopObservation();
    assert(task->state() == download::LoadState::Aborted);
    bool saw_user_cancel = false;
    for (const auto& fact : observed) {
        assert(!fact.used);
        if (fact.stop == static_cast<int>(download::NetThread::CallbackStopReason::UserCancelled)) saw_user_cancel = true;
    }
    for (const auto& source : task->files().front()->sources()) assert(source->fail_count == 0 && !source->is_failed);
    assert(saw_user_cancel); purgeSettled(engine, task->taskId());
    std::cout << "PASS cold user cancel wins over available completed-peer evidence and settles owners" << std::endl;
}

static void run(download::DownloadEngine& engine, const fs::path& root, int selected = -1) {
    std::string body(8 * 1024 * 1024, '\0');
    for (size_t i = 0; i < body.size(); ++i) body[i] = static_cast<char>((i * 31 + i / 251) % 251);
    download::Sha1 hash; hash.update(body.data(), body.size()); auto sha = hash.finalizeHex();
    if (selected < 0) proofBoundaries(root);
    for (int mode = 0; mode < 7; ++mode) if (selected < 0 || selected == mode) runCase(engine, root, body, sha, mode);
    if (selected < 0) cancelCase(engine, root, body, sha);
}
} // namespace cold_source_yield_cases
