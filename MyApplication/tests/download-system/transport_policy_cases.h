/**
 * 统一传输策略的真实生产路径回归。
 *
 * 本头在 native.cpp 的宿主夹具 helpers 之后引入：直接运行真实 DownloadEngine、
 * worker/CURLM、Range 和磁盘提交，不在测试里复制下载重试算法。服务器只监听回环，
 * 目标均位于命令行指定的 fixture root；不访问公网或用户实例。
 */
#pragma once

#include <algorithm>
#include <cassert>
#include <atomic>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <thread>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <poll.h>
#include <unistd.h>
#include <sys/time.h>
#include <new>
#include "engine.h"
#include "sha1.h"
#include "transport_policy.h"

namespace transport_policy_cases {

/**
 * 一次断流→Range重试→相对重定向→最终206，或一次503冷却→成功。
 * 每个 server 单独占回环 IP，避免其他用例保留的合法主机冷却影响测试前提。
 */
class HttpFixture {
public:
    enum class Mode { ResumedRedirect, Cooldown, Complete };
    const Mode mode;
    const std::string host;
    std::string payload;
    std::string redirect_target;
    int listener = -1;
    int port = 0;
    std::atomic<bool> stopping{false};
    std::atomic<int> head_requests{0}, origin_requests{0}, target_requests{0};
    std::atomic<int64_t> target_offset{-1};
    std::atomic<int64_t> last_offset{-1};
    std::thread worker;

    HttpFixture(size_t bytes, Mode fixture_mode, std::string address, std::string target = {})
        : mode(fixture_mode), host(std::move(address)), redirect_target(std::move(target)) {
        payload.resize(bytes);
        // 非恒定内容同时验证前缀、偏移和3xx正文未混入，不能仅靠文件长度冒充正确。
        for (size_t i = 0; i < bytes; ++i) payload[i] = static_cast<char>('a' + i % 23);
        listener = ::socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
        sockaddr_in local{}; local.sin_family = AF_INET;
        assert(::inet_pton(AF_INET, host.c_str(), &local.sin_addr) == 1);
        assert(::bind(listener, reinterpret_cast<sockaddr*>(&local), sizeof(local)) == 0);
        socklen_t length = sizeof(local);
        assert(::getsockname(listener, reinterpret_cast<sockaddr*>(&local), &length) == 0);
        port = ntohs(local.sin_port); assert(::listen(listener, 8) == 0);
        worker = std::thread([this] { serve(); });
    }

    ~HttpFixture() {
        stopping.store(true);
        if (worker.joinable()) worker.join();
        if (listener >= 0) ::close(listener);
    }

    std::string url() const { return "http://" + host + ":" + std::to_string(port) + "/start"; }

private:
    /** 完整发送尽力而为；客户取消/故障会中断发送，测试服务器不因SIGPIPE终止进程。 */
    static void sendBytes(int client, const char* data, size_t bytes) {
        size_t sent = 0;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        while (sent < bytes && std::chrono::steady_clock::now() < deadline) {
            const ssize_t n = ::send(client, data + sent, bytes - sent, MSG_NOSIGNAL);
            if (n <= 0) break;
            sent += static_cast<size_t>(n);
        }
    }

    /** 只解释夹具需要的 Range 起点；生产区间校验仍由真正的下载器执行。 */
    static int64_t rangeOffset(const std::string& request, bool& ranged) {
        const auto begin = request.find("Range: bytes=");
        ranged = begin != std::string::npos;
        return ranged ? std::stoll(request.substr(begin + 13)) : 0;
    }

    void serve() {
        while (!stopping.load()) {
            pollfd ready{listener, POLLIN, 0};
            if (::poll(&ready, 1, 100) <= 0) continue;
            const int client = ::accept(listener, nullptr, nullptr);
            if (client < 0) continue;
            timeval socket_timeout{1, 0};
            ::setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &socket_timeout, sizeof(socket_timeout));
            ::setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &socket_timeout, sizeof(socket_timeout));
            std::string request;
            char buffer[2048];
            const auto request_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (!stopping.load() && std::chrono::steady_clock::now() < request_deadline &&
                   request.find("\r\n\r\n") == std::string::npos && request.size() < 16384) {
                const ssize_t n = ::recv(client, buffer, sizeof(buffer), 0);
                if (n <= 0) break;
                request.append(buffer, static_cast<size_t>(n));
            }
            bool ranged = false;
            const int64_t offset = rangeOffset(request, ranged);
            last_offset.store(offset);
            const bool target = request.find(" /target ") != std::string::npos;
            const bool head = request.compare(0, 5, "HEAD ") == 0;
            if (head) ++head_requests;
            const int request_number = target ? ++target_requests : ++origin_requests;
            if (mode == Mode::Cooldown && request_number == 1) {
                const std::string header = "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 6\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                sendBytes(client, header.data(), header.size());
            } else if (mode == Mode::ResumedRedirect && !target && request_number > 1) {
                // 第一跳的 Retry-After/Content-Range 不得污染最终200/206响应。
                const std::string body = "redirect body is not artifact bytes";
                const std::string next = redirect_target.empty() ? "/target" : redirect_target;
                const std::string header = "HTTP/1.1 302 Found\r\nLocation: " + next + "\r\nRetry-After: 999\r\nContent-Length: " +
                    std::to_string(body.size()) + "\r\nConnection: close\r\n\r\n";
                sendBytes(client, header.data(), header.size());
                if (!head) sendBytes(client, body.data(), body.size());
            } else {
                assert(offset >= 0 && static_cast<size_t>(offset) < payload.size());
                const size_t remaining = payload.size() - static_cast<size_t>(offset);
                std::string header = ranged ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n";
                header += "Content-Length: " + std::to_string(remaining) + "\r\n";
                if (ranged) header += "Content-Range: bytes " + std::to_string(offset) + "-" +
                    std::to_string(payload.size() - 1) + "/" + std::to_string(payload.size()) + "\r\n";
                header += "Connection: close\r\n\r\n";
                sendBytes(client, header.data(), header.size());
                size_t bytes = remaining;
                if (mode == Mode::ResumedRedirect && !target && request_number == 1) bytes /= 2;
                if (target) target_offset.store(offset);
                if (!head) sendBytes(client, payload.data() + offset, bytes);
            }
            ::shutdown(client, SHUT_RDWR); ::close(client);
        }
    }
};

/** 终态与真实执行收敛一起等待；任何超时直接失败，不把等待超时当已释放。 */
inline void waitSettled(download::DownloadEngine& engine, const download::LoaderDownloadPtr& task) {
    for (int i = 0; i < 2000; ++i) {
        const auto state = task->state();
        if (state != download::LoadState::Loading && state != download::LoadState::Waiting &&
            task->isExecutionSettled() && engine.isTaskExecutionSettled(task->taskId())) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    assert(false && "transport fixture failed to settle");
}

/** 同一个真实故障分别通过文件大小进入CURLM和worker，不手工调用私有完成函数。 */
inline void resumedRedirect(download::DownloadEngine& engine, const std::filesystem::path& root, size_t size) {
    const bool small = size < 1024 * 1024;
    HttpFixture server(size, HttpFixture::Mode::ResumedRedirect, small ? "127.0.0.41" : "127.0.0.42");
    download::NetFile::Config file;
    file.local_path = (root / (small ? "policy-redirect-multi" : "policy-redirect-worker")).string();
    file.allowed_root = root.string(); file.urls = {server.url()}; file.max_connections = 1;
    file.check.expected_size = size;
    download::Sha1 hash; hash.update(server.payload.data(), server.payload.size());
    file.check.expected_sha1 = hash.finalizeHex();
    download::LoaderDownload::Config config; config.name = "real resumed redirect"; config.files.push_back(file);
    auto task = engine.createTask(config); assert(engine.startTask(task->taskId())); waitSettled(engine, task);
    assert(task->state() == download::LoadState::Finished);
    assert(server.head_requests == 0 && server.origin_requests == 2 && server.target_requests == 1);
    assert(server.target_offset == static_cast<int64_t>(size / 2));
    std::ifstream input(file.local_path, std::ios::binary);
    const std::string saved((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    assert(saved == server.payload);
    assert(engine.purgeTask(task->taskId()));
    std::cout << "PASS real resumed relative redirect preserves prefix path=" << (small ? "multi" : "worker") << std::endl;
}

/** 6s冷却长于小文件5s stall阈值；第二请求必须重新起钟，恰好两次GET完成。 */
inline void cooldownStartsFreshAttempt(download::DownloadEngine& engine, const std::filesystem::path& root) {
    HttpFixture server(4096, HttpFixture::Mode::Cooldown, "127.0.0.43");
    download::NetFile::Config file;
    file.local_path = (root / "policy-cooldown-multi").string(); file.allowed_root = root.string();
    file.urls = {server.url()}; file.max_connections = 1; file.check.expected_size = server.payload.size();
    download::LoaderDownload::Config config; config.name = "fresh HTTP attempt after cooldown"; config.files.push_back(file);
    const auto start = std::chrono::steady_clock::now();
    auto task = engine.createTask(config); assert(engine.startTask(task->taskId())); waitSettled(engine, task);
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
    assert(task->state() == download::LoadState::Finished && server.origin_requests == 2);
    assert(elapsed >= 6000 && server.head_requests == 0);
    assert(engine.purgeTask(task->taskId()));
    std::cout << "PASS cooldown excluded from next HTTP stall clock elapsed=" << elapsed << "ms" << std::endl;
}

/** 用生产账本证明120s服务端等待不被45s本地cap截短，极大值也不溢出成可重试。 */
inline void serverDeadline(download::DownloadEngine& engine) {
    const int64_t before = download::netThreadSteadyNowMs();
    const int64_t until = engine.noteHostRateLimit("policy-server-deadline.invalid", 120000);
    assert(until >= before + 120000);
    uint64_t token = 0;
    assert(!engine.tryAcquireHostSlot("policy-server-deadline.invalid", &token));
    assert(download::parseTransportRetryAfter("120") == 120000);
    const auto huge = download::parseTransportRetryAfter("999999999999999999999999999999");
    assert(huge == std::numeric_limits<int64_t>::max());
    assert(download::transportDeadlineAfter(before, huge) == std::numeric_limits<int64_t>::max());
    assert(!download::slowerThanTransportPeers(7000, 16 * 7000, 16));
    assert(!download::slowerThanTransportPeers(7000, 7000, 1));
    assert(download::slowerThanTransportPeers(7000, 7000 + 3 * 500000, 4));
    std::cout << "PASS server Retry-After is an uncapped not-before" << std::endl;
}

/** metadata真实HTTP夹具，覆盖条件请求、跨origin重定向、限长及服务器冷却。 */
class MetadataFixture {
public:
    std::string host;
    std::string redirect_target;
    int listener = -1, port = 0;
    std::atomic<bool> stopping{false}, credential_received{false};
    std::atomic<int> requests{0};
    std::thread worker;

    explicit MetadataFixture(std::string address, std::string target = {})
        : host(std::move(address)), redirect_target(std::move(target)) {
        listener = ::socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
        sockaddr_in local{}; local.sin_family = AF_INET;
        assert(::inet_pton(AF_INET, host.c_str(), &local.sin_addr) == 1);
        assert(::bind(listener, reinterpret_cast<sockaddr*>(&local), sizeof(local)) == 0);
        socklen_t length = sizeof(local);
        assert(::getsockname(listener, reinterpret_cast<sockaddr*>(&local), &length) == 0);
        port = ntohs(local.sin_port); assert(::listen(listener, 8) == 0);
        worker = std::thread([this] {
            while (!stopping.load()) {
                pollfd ready{listener, POLLIN, 0}; if (::poll(&ready, 1, 100) <= 0) continue;
                const int client = ::accept(listener, nullptr, nullptr); if (client < 0) continue;
                timeval socket_timeout{1, 0};
                ::setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &socket_timeout, sizeof(socket_timeout));
                ::setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &socket_timeout, sizeof(socket_timeout));
                std::string request; char buffer[2048];
                const auto request_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
                while (!stopping.load() && std::chrono::steady_clock::now() < request_deadline &&
                       request.find("\r\n\r\n") == std::string::npos && request.size() < 16384) {
                    const ssize_t n = ::recv(client, buffer, sizeof(buffer), 0); if (n <= 0) break;
                    request.append(buffer, static_cast<size_t>(n));
                }
                ++requests;
                if (request.find("Authorization:") != std::string::npos || request.find("Cookie:") != std::string::npos)
                    credential_received = true;
                int status = 200;
                std::string extra = "ETag: metadata-v1\r\n";
                std::string body = "metadata-ok";
                if (!redirect_target.empty()) {
                    status = 302; extra = "Location: " + redirect_target + "\r\nETag: wrong-hop\r\n";
                    body.assign(256, 'r'); // 大于最终16B额度的3xx体必须被丢弃。
                } else if (request.find(" /rate ") != std::string::npos) {
                    status = 503; extra += "Retry-After: 120\r\n"; body.clear();
                } else if (request.find(" /large ") != std::string::npos) body.assign(128, 'l');
                else if (request.find("If-None-Match: metadata-v1") != std::string::npos) { status = 304; body.clear(); }
                const std::string header = "HTTP/1.1 " + std::to_string(status) + " Fixture\r\n" + extra +
                    "Content-Length: " + std::to_string(body.size()) + "\r\nConnection: close\r\n\r\n";
                const std::string response = header + body;
                size_t sent = 0;
                const auto send_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
                while (!stopping.load() && std::chrono::steady_clock::now() < send_deadline && sent < response.size()) {
                    const ssize_t n = ::send(client, response.data() + sent, response.size() - sent, MSG_NOSIGNAL);
                    if (n <= 0) break; sent += static_cast<size_t>(n);
                }
                ::shutdown(client, SHUT_RDWR); ::close(client);
            }
        });
    }

    ~MetadataFixture() { stopping = true; if (worker.joinable()) worker.join(); ::close(listener); }
    std::string url(const char* path = "/ok") const { return "http://" + host + ":" + std::to_string(port) + path; }
};

/** 两个公开metadata入口真实经过同一执行，保留304、限长、最终headers和凭据隔离。 */
inline void metadataAdmission(download::DownloadEngine& engine) {
    MetadataFixture target("127.0.0.45");
    MetadataFixture origin("127.0.0.44", target.url());
    download::FetchResponse response;
    assert(engine.fetchToBufferEx(origin.url(), {}, 5,
        {{"If-None-Match", "metadata-v1"}, {"Authorization", "Bearer fixture-not-a-real-credential"}},
        16, response) == 0);
    assert(response.status_code == 304 && response.body.empty());
    assert(response.headers.at("etag") == "metadata-v1");
    assert(origin.credential_received && !target.credential_received);
    std::string body, kind, message;
    assert(engine.fetchToBuffer(origin.url(), {}, 5, body, kind, message) == 0 && body == "metadata-ok");
    assert(engine.fetchToBufferEx(target.url("/large"), {}, 5, {}, 16, response) != 0);
    assert(response.err_kind == "ResponseTooLarge" && response.body.empty());
    MetadataFixture limited("127.0.0.46");
    assert(engine.fetchToBufferEx(limited.url("/rate"), {}, 5, {}, 16, response) != 0);
    assert(response.status_code == 503 && response.headers.at("retry-after") == "120");
    const int before = limited.requests.load();
    assert(engine.fetchToBufferEx(limited.url(), {}, 1, {}, 16, response) != 0);
    assert(response.err_kind == "RetryAfter" && limited.requests == before);
    MetadataFixture saturated("127.0.0.47");
    uint64_t occupied[64] = {};
    for (auto& token : occupied) assert(engine.tryAcquireHostSlot(saturated.host, &token));
    assert(engine.fetchToBufferEx(saturated.url(), {}, 1, {}, 16, response) != 0);
    assert(response.err_kind == "Timeout" && saturated.requests == 0);
    for (auto token : occupied) engine.releaseHostSlot(saturated.host, false, token);
    assert(engine.fetchToBufferEx(saturated.url(), {}, 5, {}, 16, response) == 0 && saturated.requests == 1);
    std::cout << "PASS real metadata GET hop admission, 304, bounds, credentials and Retry-After" << std::endl;
}

/** 首次HTTP前已有一小时冷却，不能因retry时钟尚未建立而睡一小时或提前打请求。 */
inline void initialCooldownIsBounded(download::DownloadEngine& engine, const std::filesystem::path& root) {
    for (bool small : {true, false}) {
        HttpFixture server(small ? 4096 : 2 * 1024 * 1024, HttpFixture::Mode::Cooldown,
                           small ? "127.0.0.48" : "127.0.0.49");
        engine.noteHostRateLimit(server.host, 60 * 60 * 1000LL);
        download::NetFile::Config file;
        file.local_path = (root / (small ? "policy-initial-cooldown-multi" : "policy-initial-cooldown-worker")).string();
        file.allowed_root = root.string(); file.urls = {server.url()}; file.max_connections = 1;
        file.check.expected_size = server.payload.size();
        download::LoaderDownload::Config cfg; cfg.name = "bounded initial host cooldown"; cfg.files.push_back(file);
        auto task = engine.createTask(cfg); assert(engine.startTask(task->taskId())); waitSettled(engine, task);
        assert(task->state() == download::LoadState::Failed && server.origin_requests == 0 && server.head_requests == 0);
        assert(engine.purgeTask(task->taskId()));
    }
    std::cout << "PASS initial cooldown beyond admission budget performs zero HTTP on both paths" << std::endl;
}

/** A已写前缀后302至冷却X，健康备源B必须马上接续；两执行器都不得钉住X。 */
inline void deferredRedirectSelectsFallback(download::DownloadEngine& engine, const std::filesystem::path& root) {
    for (bool small : {true, false}) {
        const size_t size = small ? 4096 : 2 * 1024 * 1024;
        HttpFixture blocked(size, HttpFixture::Mode::Complete, small ? "127.0.0.52" : "127.0.0.55");
        HttpFixture alternate(size, HttpFixture::Mode::Complete, small ? "127.0.0.53" : "127.0.0.56");
        HttpFixture origin(size, HttpFixture::Mode::ResumedRedirect, small ? "127.0.0.51" : "127.0.0.54", blocked.url());
        engine.noteHostRateLimit(blocked.host, 120000);
        download::NetFile::Config file;
        file.local_path = (root / (small ? "policy-deferred-redirect-multi" : "policy-deferred-redirect-worker")).string();
        file.allowed_root = root.string(); file.urls = {origin.url(), alternate.url()}; file.max_connections = 1;
        file.check.expected_size = size;
        download::Sha1 hash; hash.update(origin.payload.data(), origin.payload.size()); file.check.expected_sha1 = hash.finalizeHex();
        download::LoaderDownload::Config cfg; cfg.name = "redirect admission yields to healthy fallback"; cfg.files.push_back(file);
        auto task = engine.createTask(cfg);
        // A带既有快样本，使第一次断流后仍优先A，保证真实经过A第二次GET与302。
        // B全程合法且可用；只在X实际准入被拒后，调度才应让它接管原有效前缀。
        task->files()[0]->sources()[0]->recordSample(0, 1000000000.0);
        const auto start = std::chrono::steady_clock::now();
        assert(engine.startTask(task->taskId())); waitSettled(engine, task);
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
        assert(task->state() == download::LoadState::Finished && elapsed < 10000);
        assert(origin.origin_requests == 2 && blocked.origin_requests == 0 && alternate.origin_requests == 1);
        assert(alternate.last_offset == static_cast<int64_t>(size / 2));
        std::ifstream input(file.local_path, std::ios::binary);
        const std::string saved((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
        assert(saved == origin.payload && engine.purgeTask(task->taskId()));
    }
    std::cout << "PASS deferred redirect reselects healthy fallback with exact prefix on both paths" << std::endl;
}

/**
 * 生产入口 acquireCurlUse 后的urls.reserve真实抛bad_alloc，两入口都必须被RAII归还。
 * 原Native main随后有带限时断言的真实shutdown；若计数泄漏，该既有收尾反例将失败。
 * 所有参数先构造，TLS钩子后直接调用，不让测试日志/实参构造抢先消费故障。
 */
inline void metadataExceptionReleasesUse(download::DownloadEngine& engine) {
    const std::string url = "http://127.0.0.57:1/unused";
    const std::vector<std::string> mirrors;
    const std::map<std::string, std::string> headers;
    std::string body, kind, message;
    download::FetchResponse response;
    bool plain_threw = false, extended_threw = false;
    amclNativeTestFailNextAllocation();
    try { engine.fetchToBuffer(url, mirrors, 1, body, kind, message); }
    catch (const std::bad_alloc&) { plain_threw = true; }
    amclNativeTestFailNextAllocation();
    try { engine.fetchToBufferEx(url, mirrors, 1, headers, 16, response); }
    catch (const std::bad_alloc&) { extended_threw = true; }
    assert(plain_threw && extended_threw);
    std::cout << "PASS both metadata entry allocation exceptions unwind curl-use receipt before final bounded shutdown" << std::endl;
}

/**
 * 真实生产熔断TTL过后反复纯查询不能消费探针。取消/未发请求归还后仍需新探针，
 * 只有显式成功归还后才闭路。等待生产最短15s TTL，不为测试修改下载器时间源。
 */
inline void halfOpenObservation(download::DownloadEngine& engine) {
    const std::string host = "policy-half-open.invalid";
    uint64_t old_inflight = 0;
    assert(engine.tryAcquireHostSlot(host, &old_inflight) && old_inflight != 0);
    engine.addBadHost(host); engine.addBadHost(host); engine.addBadHost(host);
    const int64_t ready = engine.badHostReadyAtMs(host);
    assert(ready > download::netThreadSteadyNowMs());
    const int64_t remaining = ready - download::netThreadSteadyNowMs();
    std::this_thread::sleep_for(std::chrono::milliseconds(std::max<int64_t>(0, remaining) + 5));
    for (int i = 0; i < 8; ++i) assert(!engine.isBadHost(host));
    uint64_t first = 0, other = 0;
    assert(engine.tryAcquireHostSlot(host, &first) && first != 0);
    // 旧A在B探针期间到达的有效正文/EOF不得清掉新故障代次，也不得释放B名额。
    engine.markHostHealthy(host, old_inflight);
    engine.markHostHealthy(host, old_inflight);
    engine.releaseHostSlot(host, true, old_inflight);
    engine.releaseHostSlot(host, false, old_inflight);
    assert(engine.isBadHost(host) && !engine.tryAcquireHostSlot(host, &other));
    engine.releaseHostSlot(host, false, first);
    uint64_t second = 0;
    assert(engine.tryAcquireHostSlot(host, &second) && second != 0 && second != first);
    engine.releaseHostSlot(host, true, second);
    uint64_t closed = 99;
    assert(engine.tryAcquireHostSlot(host, &closed) && closed != 0);
    engine.releaseHostSlot(host, true, closed);
    uint64_t occupied[64] = {};
    for (auto& receipt : occupied) assert(engine.tryAcquireHostSlot(host, &receipt));
    engine.releaseHostSlot("wrong-host.invalid", false, occupied[0]);
    engine.releaseHostSlot(host, false, old_inflight); // 旧收据再次归还不能空出第65份额度
    uint64_t overflow = 0; assert(!engine.tryAcquireHostSlot(host, &overflow));
    for (auto receipt : occupied) engine.releaseHostSlot(host, false, receipt);
    std::cout << "PASS read-only half-open observation and explicit request settlement" << std::endl;
}

} // namespace transport_policy_cases

/** native.cpp 只需显式调用一次；所有场景复用它已启动的唯一 Engine。 */
inline void runTransportPolicyCases(download::DownloadEngine& engine, const std::filesystem::path& root) {
    transport_policy_cases::serverDeadline(engine);
    transport_policy_cases::resumedRedirect(engine, root, 4096);
    transport_policy_cases::resumedRedirect(engine, root, 2 * 1024 * 1024);
    transport_policy_cases::cooldownStartsFreshAttempt(engine, root);
    transport_policy_cases::metadataAdmission(engine);
    transport_policy_cases::initialCooldownIsBounded(engine, root);
    transport_policy_cases::deferredRedirectSelectsFallback(engine, root);
    transport_policy_cases::halfOpenObservation(engine);
    transport_policy_cases::metadataExceptionReleasesUse(engine);
}
