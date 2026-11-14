/**
 * 真实Native worker/CURLM的网关回归。仅在libcurl传输边界把专用测试HTTPS URL映射到
 * 本机HTTP夹具，生产URL规划、HMAC、队列、Range、错误/回退与最终SHA均原样执行。
 * 此映射不进入HAP，不改生产TLS选项；本suite不声称验证TLS，真机另验实际HTTPS。
 */
#pragma once
#include "relay.h"
#include "hmac_sha256.h"
#include <set>
#include <cstdarg>

namespace {
std::atomic<int> relay_fixture_port{0};
std::atomic<bool> relay_fixture_stop42{false};
std::atomic<bool> relay_fixture_dualstack{false};
std::atomic<int> relay_fixture_rc23{0}, relay_fixture_rc42{0};
// 仅宿主测试观察实际worker；默认空钩子不改传输/回调结果。同步perform退出时读取对象，
// 只保存数值快照，绝不把NetThread裸指针带到owner生命周期之外使用。
std::atomic<void (*)(CURL*, void*)> fixture_worker_data_observer{nullptr};
std::atomic<void (*)(CURL*, CURLcode)> fixture_worker_result_observer{nullptr};

/** 只认专用测试地址，默认不改动任何旧用例；映射前保留原始编码路径及所有请求头。 */
std::string mapRelayFixtureTransport(const char* raw) {
    const int port = relay_fixture_port.load();
    std::string url = raw ? raw : "";
    if (!port) return url;
    if (url.rfind("https://", 0) == 0) {
        const size_t slash = url.find('/', 8);
        const std::string host = url.substr(8, slash - 8);
        const std::string suffix = ".fixture.invalid";
        if (host == "piston-data.mojang.com" || host == "libraries.minecraft.net" ||
            (host.size() > suffix.size() && host.compare(host.size() - suffix.size(), suffix.size(), suffix) == 0))
            return std::string("http://") + (relay_fixture_dualstack.load() ? "localhost:" : "127.0.0.1:") +
                std::to_string(port) + url.substr(slash);
    }
    return url;
}
/** 真实生产progress先执行；夹具只在已写满时主动结束，以真实curl生成rc42。 */
int relayFixtureProgress(void* data, curl_off_t total, curl_off_t now, curl_off_t up_total, curl_off_t up_now) {
    const int code = download::NetThread::onProgress(data, total, now, up_total, up_now);
    auto* thread = static_cast<download::NetThread*>(data);
    if (code) return code;
    return relay_fixture_stop42.load() && thread->length() > 0 && thread->done() >= thread->length() ? 1 : 0;
}
void recordRelayFixtureResult(CURLcode code) {
    if (!relay_fixture_port.load()) return;
    if (code == CURLE_WRITE_ERROR) ++relay_fixture_rc23;
    if (code == CURLE_ABORTED_BY_CALLBACK) ++relay_fixture_rc42;
}
}

extern "C" CURLcode __real_curl_easy_setopt(CURL*, CURLoption, ...);
extern "C" CURLcode __real_curl_easy_perform(CURL*);
extern "C" CURLMsg* __real_curl_multi_info_read(CURLM*, int*);
/**
 * 精确在URL设置边界映射；EFFECTIVE_URL是上次响应事实，easy复用时不能当配置getter。
 * 其余选项按libcurl公开的参数类别/回调签名原样转发，不改变生产状态机。
 */
extern "C" CURLcode __wrap_curl_easy_setopt(CURL* easy, CURLoption option, ...) {
    va_list args; va_start(args, option); CURLcode result;
    if (option == CURLOPT_URL) {
        const auto local = mapRelayFixtureTransport(va_arg(args, const char*));
        result = __real_curl_easy_setopt(easy, option, local.c_str());
    } else if (option == CURLOPT_XFERINFOFUNCTION) {
        auto callback = va_arg(args, curl_xferinfo_callback);
        if (relay_fixture_stop42.load() && callback == reinterpret_cast<curl_xferinfo_callback>(&download::NetThread::onProgress))
            callback = relayFixtureProgress;
        result = __real_curl_easy_setopt(easy, option, callback);
    } else if (option == CURLOPT_WRITEFUNCTION || option == CURLOPT_HEADERFUNCTION) {
        result = __real_curl_easy_setopt(easy, option, va_arg(args, curl_write_callback));
    } else if (option == CURLOPT_SOCKOPTFUNCTION) {
        result = __real_curl_easy_setopt(easy, option, va_arg(args, curl_sockopt_callback));
    } else if (option < CURLOPTTYPE_OBJECTPOINT) {
        result = __real_curl_easy_setopt(easy, option, va_arg(args, long));
    } else if (option < CURLOPTTYPE_FUNCTIONPOINT) {
        auto* value = va_arg(args, void*);
        if (option == CURLOPT_XFERINFODATA)
            if (auto observe = fixture_worker_data_observer.load()) observe(easy, value);
        result = __real_curl_easy_setopt(easy, option, value);
    } else if (option >= CURLOPTTYPE_OFF_T && option < CURLOPTTYPE_BLOB) {
        result = __real_curl_easy_setopt(easy, option, va_arg(args, curl_off_t));
    } else {
        assert(false && "explicitly type any new curl callback/blob used by host regression");
        result = CURLE_UNKNOWN_OPTION;
    }
    va_end(args); return result;
}
extern "C" CURLcode __wrap_curl_easy_perform(CURL* easy) {
    const auto result = __real_curl_easy_perform(easy);
    if (auto observe = fixture_worker_result_observer.load()) observe(easy, result);
    recordRelayFixtureResult(result); return result;
}
extern "C" CURLMsg* __wrap_curl_multi_info_read(CURLM* multi, int* left) {
    auto* message = __real_curl_multi_info_read(multi, left);
    if (message && message->msg == CURLMSG_DONE) recordRelayFixtureResult(message->data.result);
    return message;
}

/** 只解析夹具用到的头，客户端票据不写日志；server在同一互斥量下保存计数和nonce。 */
static std::string relayFixtureHeader(const std::string& request, const std::string& name) {
    const std::string marker = "\r\n" + name + ": ";
    const size_t found = request.find(marker);
    if (found == std::string::npos) return {};
    const size_t begin = found + marker.size();
    return request.substr(begin, request.find("\r\n", begin) - begin);
}

/** 独占回环socket和服务线程；析构先join后关监听，nonce/安全头事实只保存在本轮内存。 */
class RelayHttpFixture {
public:
    int listener = -1, listener6 = -1, port = 0;
    std::atomic<bool> stop{false};
    std::thread worker;
    const std::string payload;
    std::string base;
    std::mutex mutex;
    int gateway = 0, direct = 0, external = 0, authorized = 0;
    // defer用例的B候选只应经过准入拒绝；任何真实HTTP都单独计数并使断言失败。
    int deferred_requests = 0;
    bool invalid_proof = false, leaked_headers = false, duplicate_nonce = false;
    bool returned_without_credentials = false;
    bool direct_family_failure_sent = false;
    // 此状态只由本夹具服务线程访问；不记录请求凭据。
    bool bounce_direct_failure_sent = false;
    std::vector<std::string> recovery_hops;
    int64_t largest_direct_offset = 0;
    std::set<std::string> nonces;
    const std::string key = "relay-test-session-key";

    explicit RelayHttpFixture(size_t size, bool stop42 = false, bool dualstack = false) : payload(size, 'r') {
        listener = ::socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
        sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        assert(::bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
        socklen_t length = sizeof(address);
        assert(::getsockname(listener, reinterpret_cast<sockaddr*>(&address), &length) == 0);
        port = ntohs(address.sin_port); assert(::listen(listener, 32) == 0);
        // 每case唯一host，避免真实Engine的跨case熔断污染下一项独立输入。
        base = "https://relay-" + std::to_string(port) + ".fixture.invalid/dl";
        if (dualstack) {
            // 两个纯回环监听共享端口，使真实libcurl可从IPv6失败后切IPv4，无公网替代。
            listener6 = ::socket(AF_INET6, SOCK_STREAM, 0); assert(listener6 >= 0);
            sockaddr_in6 address6{}; address6.sin6_family = AF_INET6;
            address6.sin6_addr = in6addr_loopback; address6.sin6_port = htons(port);
            assert(::bind(listener6, reinterpret_cast<sockaddr*>(&address6), sizeof(address6)) == 0);
            assert(::listen(listener6, 32) == 0);
        }
        relay_fixture_port = port;
        relay_fixture_stop42 = stop42; relay_fixture_rc23 = 0; relay_fixture_rc42 = 0;
        relay_fixture_dualstack = dualstack;
        worker = std::thread([this] {
            while (!stop.load()) {
                pollfd ready[2]{{listener, POLLIN, 0}, {listener6, POLLIN, 0}};
                if (::poll(ready, listener6 >= 0 ? 2 : 1, 50) <= 0) continue;
                const int incoming = ready[0].revents & POLLIN ? listener : listener6;
                int client = ::accept(incoming, nullptr, nullptr); if (client < 0) continue;
                std::string request; char buffer[4096];
                while (request.find("\r\n\r\n") == std::string::npos && request.size() < 16384) {
                    const auto count = ::recv(client, buffer, sizeof(buffer), 0);
                    if (count <= 0) break; request.append(buffer, static_cast<size_t>(count));
                }
                const size_t first = request.find(' '), last = request.find(' ', first + 1);
                const std::string path = request.substr(first + 1, last - first - 1);
                const bool via = path.rfind("/dl/p/", 0) == 0;
                const bool unauthenticated_return = via && path.find("chain-final") != std::string::npos;
                const bool redirected = path.rfind("/external/", 0) == 0;
                const std::string auth = relayFixtureHeader(request, "Authorization");
                const std::string ts = relayFixtureHeader(request, "X-AMCL-Ts");
                const std::string nonce = relayFixtureHeader(request, "X-AMCL-Nonce");
                const std::string signature = relayFixtureHeader(request, "X-AMCL-Sig");
                const std::string range = relayFixtureHeader(request, "Range");
                const bool metadata = request.rfind("HEAD ", 0) == 0 || range == "bytes=0-0";
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    if (path.find("blocked-next-source.jar") != std::string::npos) ++deferred_requests;
                    if (via && !unauthenticated_return) {
                        ++gateway;
                        const std::string canonical = "v1\nGET\n" + path.substr(3) + "\n" + ts + "\n" + nonce;
                        if (auth != "Bearer relay-test-ticket" || nonce.empty() ||
                            signature != download::hmacSha256Hex(key, canonical)) invalid_proof = true;
                        if (!nonces.insert(nonce).second) duplicate_nonce = true;
                    } else {
                        if (redirected) ++external; else if (!metadata) ++direct;
                        if (auth == "Bearer business-lease") ++authorized;
                        else if (!auth.empty()) leaked_headers = true;
                        if (!ts.empty() || !nonce.empty() || !signature.empty()) leaked_headers = true;
                        if (unauthenticated_return && auth.empty() && nonce.empty()) returned_without_credentials = true;
                    }
                }
                int code = 200;
                std::string body = payload, extra;
                size_t offset = 0, end = payload.size() - 1;
                if (range.rfind("bytes=", 0) == 0) {
                    const size_t dash = range.find('-'); offset = std::stoull(range.substr(6, dash - 6));
                    if (dash + 1 < range.size()) end = std::min(end, static_cast<size_t>(std::stoull(range.substr(dash + 1))));
                    assert(offset <= end);
                    code = 206; body = payload.substr(offset, end - offset + 1);
                    extra = "Content-Range: bytes " + std::to_string(offset) + "-" + std::to_string(end) + "/" + std::to_string(payload.size()) + "\r\n";
                    if (!via) { std::lock_guard<std::mutex> lock(mutex); largest_direct_offset = std::max<int64_t>(largest_direct_offset, offset); }
                }
                if (via && path.find("deny401") != std::string::npos) { code = 401; body = "{\"error\":\"ticket_expired\"}"; extra.clear(); }
                if (via && path.find("deny503") != std::string::npos) { code = 503; body = "{\"error\":\"server_busy\"}"; extra.clear(); }
                if (via && path.find("family-chain") != std::string::npos) { code = 503; body = "gateway temporary failure"; extra.clear(); }
                if (!via && path.find("family-chain") != std::string::npos && !direct_family_failure_sent) {
                    direct_family_failure_sent = true;
                    ::shutdown(client, SHUT_RDWR); ::close(client); continue; // 真实连接已建立但无HTTP响应。
                }
                if (path.find("chain401") != std::string::npos) {
                    code = via ? 401 : 302; body = "fallback redirect is not artifact";
                    extra = via ? "" : "Location: " + base + "/p/piston-data.mojang.com/amcl-relay-test/chain-final.jar\r\n";
                }
                if (unauthenticated_return) { code = 401; body = "anonymous gateway must deny"; extra.clear(); }
                if (via && path.find("redirect") != std::string::npos) {
                    code = 302; body = "redirect must not enter file";
                    extra = "Location: https://external.fixture.invalid/external/ok\r\n";
                }
                // 大于本段需要的正文使真实onWrite填满后返回短写，curl真实返回23。
                if (via && path.find("stop23") != std::string::npos) body += payload;
                if (via && path.find("short-eof") != std::string::npos) body.resize(body.size() / 2);
                if (via && path.find("drop") != std::string::npos) {
                    ::shutdown(client, SHUT_RDWR); ::close(client); continue;
                }
                // 小文件的真实恢复故障链：网关先失败，第一次直连也失败。
                // 后续直连可成功；再次套回网关则额外失败，暴露重入。
                if (path.find("bounce503") != std::string::npos || path.find("switch503") != std::string::npos ||
                    path.find("defer503") != std::string::npos) {
                    if (via) { code = 503; body = "gateway temporary failure"; extra.clear(); }
                    else if (!bounce_direct_failure_sent) {
                        bounce_direct_failure_sent = true; code = 503;
                        body = "first direct temporary failure"; extra.clear();
                    }
                    std::lock_guard<std::mutex> lock(mutex);
                    recovery_hops.push_back(std::string(via ? "gateway" : "direct") +
                        " http=" + std::to_string(code) + " range=" + range);
                }
                const std::string header = "HTTP/1.1 " + std::to_string(code) + " Fixture\r\nContent-Length: " +
                    std::to_string(body.size()) + "\r\nAccept-Ranges: bytes\r\nConnection: close\r\n" + extra + "\r\n";
                std::string response = header + body;
                if (via && path.find("partial") != std::string::npos) response.resize(header.size() + body.size() / 2);
                size_t sent = 0;
                while (sent < response.size()) {
                    const auto count = ::send(client, response.data() + sent, response.size() - sent, MSG_NOSIGNAL);
                    if (count <= 0) break; sent += static_cast<size_t>(count);
                }
                ::shutdown(client, SHUT_RDWR); ::close(client);
            }
        });
    }
    ~RelayHttpFixture() {
        stop = true; if (worker.joinable()) worker.join(); ::close(listener);
        if (listener6 >= 0) ::close(listener6);
        relay_fixture_port = 0; relay_fixture_stop42 = false; relay_fixture_dualstack = false;
    }
};

/**
 * 仅为defer回归占满一个本case独有主机的真实Engine准入名额，不发请求、不改准入策略。
 * B候选因此会经过startTransfer/deferSource，而A的直连主机和网关不受影响。所有收据
 * 在同一个owner析构时逐项归还；用healthy=false避免把没有HTTP的夹具占位奖励成健康样本。
 */
class RelayDeferredHostOccupancy {
    download::DownloadEngine& engine_;
    std::string host_;
    std::vector<uint64_t> receipts_;
public:
    RelayDeferredHostOccupancy(download::DownloadEngine& engine, const std::string& host)
        : engine_(engine), host_(host) {
        if (host_.empty()) return;
        // 上限只是防夹具错误无限取名额；真实准入应先因同主机窗口已满而拒绝。
        for (int attempt = 0; attempt < 256; ++attempt) {
            uint64_t receipt = 0;
            if (!engine_.tryAcquireHostSlot(host_, &receipt)) break;
            assert(receipt != 0); receipts_.push_back(receipt);
        }
        uint64_t unexpected = 0;
        assert(!receipts_.empty() && !engine_.tryAcquireHostSlot(host_, &unexpected));
    }
    ~RelayDeferredHostOccupancy() {
        for (const auto receipt : receipts_) engine_.releaseHostSlot(host_, false, receipt);
    }
};

/** 规划不会计请求；关闭/换配置后的旧计划不执行submit，也不消费请求计数。 */
static void relayPlanGeneration() {
    download::RelayConfig cfg; cfg.enabled = true; cfg.base = "https://relay.fixture.invalid/dl";
    cfg.ticket = "relay-test-ticket"; cfg.session_key = "relay-test-session-key";
    download::relaySetConfig(cfg);
    const auto before = download::relayStats();
    auto first = download::relayPrepareRequest("GET", "https://piston-data.mojang.com/a%2Bb.jar?q=%2B", true);
    auto second = download::relayPrepareRequest("GET", "https://piston-data.mojang.com/a%2Bb.jar?q=%2B", true);
    assert(first.via_relay && first.url.find("a%2Bb.jar?q=%2B") != std::string::npos);
    assert(first.headers[2] != second.headers[2]);
    assert(download::relayStats().requests == before.requests);
    download::relayDisable(); bool called = false;
    assert(!download::relaySubmitRequest(first, [&] { called = true; return true; }) && !called);
    download::relaySetConfig(cfg);
    assert(!download::relaySubmitRequest(second, [&] { called = true; return true; }) && !called);
    auto token = download::relayPrepareRequest("GET", "https://piston-data.mojang.com/token.jar", false);
    auto external = download::relayPrepareRequest("GET", "https://external.fixture.invalid/x", true, false);
    auto direct_return = download::relayPrepareRequest("GET", first.url, true, false, true);
    assert(!token.via_relay && token.headers.empty() && !external.via_relay && external.headers.empty());
    assert(!direct_return.via_relay && direct_return.headers.empty() && direct_return.fallback);
    assert(download::relayStats().requests == before.requests);
    download::relayDisable();
    std::cout << "PASS relay snapshot generation cancels unsubmitted credentials and preparation does not count HTTP" << std::endl;
}

/** 按真实size进入worker/CURLM，保留文件级重试与最终SHA；只比较实际采集的提交/响应。 */
static void relayTransfer(download::DownloadEngine& engine, const fs::path& root, size_t size,
                          const std::string& endpoint, bool business = false, int count = 1,
                          bool headerless = false) {
    RelayHttpFixture server(size, endpoint == "stop42", endpoint == "family-chain");
    const std::string deferred_host = endpoint == "defer503"
        ? "deferred-" + std::to_string(server.port) + ".fixture.invalid" : "";
    RelayDeferredHostOccupancy occupied(engine, deferred_host);
    download::RelayConfig relay; relay.enabled = true; relay.base = server.base;
    relay.ticket = "relay-test-ticket"; relay.session_key = server.key;
    download::relaySetConfig(relay);
    const auto before = download::relayStats();
    auto task_config = config("relay actual executor", root, root / ("relay-" + std::to_string(size) + endpoint + (business ? "-token" : "")));
    task_config.files.clear();
    for (int i = 0; i < count; ++i) {
        auto file = config("one", root, root / ("relay-" + std::to_string(size) + "-" + endpoint + "-" + std::to_string(i) + (business ? "-token" : "") + ".jar")).files[0];
        const std::string origin = endpoint == "family-chain" ? "libraries.minecraft.net" : "piston-data.mojang.com";
        file.urls = {"https://" + origin + "/amcl-relay-test/" + endpoint + "%2B.jar"};
        // A 的首次直连503令其冷却后，B 必须继续按自己的合法网关计划请求；A 的
        // force_direct 不能跨源继承。两URL交付同一夹具字节，仍接受既有SHA终检。
        if (endpoint == "switch503") file.urls.push_back("https://libraries.minecraft.net/amcl-relay-test/healthy-next-source.jar");
        // A首次直连503进入原冷却后会选到B；B被真实host准入拒绝，不能因此消费A的
        // 直连恢复身份。B不在Relay白名单，实际主机正是上方独占的deferred_host。
        if (endpoint == "defer503") file.urls.push_back("https://" + deferred_host + "/blocked-next-source.jar");
        file.check.expected_size = size;
        download::Sha1 hash; hash.update(server.payload.data(), server.payload.size()); file.check.expected_sha1 = hash.finalizeHex();
        // 主动段终止只针对真正的有限Range段；单段full-GET没有可缩短的end边界。
        file.max_connections = endpoint == "stop23" || endpoint == "stop42" ? 2 : 1;
        if (endpoint == "stop23" || endpoint == "stop42") file.piece_min_bytes = 256 * 1024;
        if (business) {
            file.bearer_token = headerless ? "" : "business-lease";
            file.authorized_policy = true; file.authorized_single_use = true;
            file.authorized_max_http_attempts = 1; file.authorized_valid_for_ms = 300000; file.authorized_max_bytes = size;
        }
        task_config.files.push_back(file);
    }
    auto task = engine.createTask(task_config); assert(engine.startTask(task->taskId())); waitForSettled(task);
    if (endpoint == "chain401") assert(task->state() == download::LoadState::Failed);
    else {
        if (task->state() != download::LoadState::Finished)
            std::cerr << "relay task failed endpoint=" << endpoint << " error=" << (task->error() ? task->error()->toString() : "none") << std::endl;
        assert(task->state() == download::LoadState::Finished);
        for (const auto& file : task_config.files) assert(readFixtureFile(file.local_path) == server.payload);
    }
    const auto after = download::relayStats();
    {
        std::lock_guard<std::mutex> lock(server.mutex);
        assert(!server.invalid_proof && !server.leaked_headers && !server.duplicate_nonce);
        if (after.requests - before.requests != server.gateway)
            std::cerr << "relay count mismatch endpoint=" << endpoint << " submitted=" << after.requests-before.requests
                      << " received=" << server.gateway << " direct=" << server.direct << std::endl;
        assert(after.requests - before.requests == server.gateway);
        if (endpoint == "bounce503" || endpoint == "defer503") {
            std::cerr << "RECOVERY EVIDENCE executor=CURLM bytes=" << size
                      << " endpoint=" << endpoint
                      << " gateway=" << server.gateway << " direct=" << server.direct
                      << " task=Finished hash=verified" << std::endl;
            for (const auto& hop : server.recovery_hops) std::cerr << "RECOVERY HOP " << hop << std::endl;
            if (endpoint == "defer503") {
                const auto& sources = task->files()[0]->sources();
                assert(sources.size() == 2);
                const int64_t deferred_until = sources[1]->cooldown_until_ms.load(std::memory_order_acquire);
                std::cerr << "DEFER EVIDENCE sourceB_http=" << server.deferred_requests
                          << " sourceB_cooldown=" << deferred_until << std::endl;
                // 非零冷却由真实deferSource产生；同时证明B从未真正提交HTTP，排除
                // “切到B成功后又回来”的另一种合法状态转换。失败日志保留这两个事实。
                assert(deferred_until > 0 && server.deferred_requests == 0);
            }
            // 产品修正前在此失败，前面的最终字节与SHA检查已通过。
            assert(server.gateway == 1 && server.direct == 2);
            assert(after.fallbacks - before.fallbacks == 2 && after.failures - before.failures == 1);
        }
        else if (endpoint == "switch503") {
            assert(server.gateway == 2 && server.direct == 1);
            assert(after.fallbacks - before.fallbacks == 1 && after.failures - before.failures == 1);
        }
        else if (endpoint == "family-chain") {
            assert(server.gateway == 1 && server.direct == 2 && server.direct_family_failure_sent);
            assert(after.fallbacks - before.fallbacks == 2 && after.failures - before.failures == 1);
        }
        else if (endpoint == "chain401") {
            if (!(server.gateway == 1 && server.direct >= 2 && server.direct <= 30 && server.returned_without_credentials))
                std::cerr << "chain counters gateway=" << server.gateway << " direct=" << server.direct
                          << " returned=" << server.returned_without_credentials << std::endl;
            // Task外层保留既有文件级重试，最终匿名401可能重新执行整个两hop链。
            // 不能把“同一hop禁止再次加票据”误写成“整个Task只能有两条请求”。
            assert(server.gateway == 1 && server.direct >= 2 && server.direct <= 30 && server.returned_without_credentials);
            assert(after.fallbacks - before.fallbacks == 2 && after.failures - before.failures == 1);
        }
        else if (business) { assert(server.gateway == 0 && server.authorized == (headerless ? 0 : count) &&
                               server.direct == count && after.fallbacks == before.fallbacks); }
        else if (endpoint.rfind("deny", 0) == 0 || endpoint == "drop" || endpoint == "partial" || endpoint == "short-eof") {
            assert(server.gateway >= 1 && server.direct == count && after.fallbacks - before.fallbacks == count);
            assert(after.failures > before.failures);
            if (endpoint == "partial") assert(server.largest_direct_offset > 0);
        } else if (endpoint == "redirect") { assert(server.gateway == count && server.external == count); }
        else { assert(server.gateway >= count && server.direct == 0 && after.failures == before.failures); }
        if (endpoint == "stop23") assert(relay_fixture_rc23 > 0 && !download::relayTripped());
        if (endpoint == "stop42") assert(relay_fixture_rc42 > 0 && !download::relayTripped());
    }
    purgeSettled(engine, task->taskId()); download::relayDisable();
    std::cout << "PASS actual " << (size < 1024 * 1024 ? "CURLM" : "worker") << " relay " << endpoint
              << (business ? " business token bypass" : "") << " files=" << count << std::endl;
}

/** 同一生产执行器覆盖正常/真实rc23/42、拒绝/短读/回退、重定向及两种业务授权。 */
static void runRelayCases(download::DownloadEngine& engine, const fs::path& root) {
    relayPlanGeneration();
    for (size_t size : {size_t(4096), size_t(2 * 1024 * 1024)}) {
        relayTransfer(engine, root, size, "ok");
        if (size >= 1024 * 1024) {
            relayTransfer(engine, root, size, "stop23");
            relayTransfer(engine, root, size, "stop42");
        }
        relayTransfer(engine, root, size, "deny401");
        relayTransfer(engine, root, size, "deny503");
        relayTransfer(engine, root, size, "chain401");
        relayTransfer(engine, root, size, "drop");
        relayTransfer(engine, root, size, "partial");
        relayTransfer(engine, root, size, "short-eof");
        relayTransfer(engine, root, size, "redirect");
        relayTransfer(engine, root, size, "authorized", true);
        relayTransfer(engine, root, size, "headerless", true, 1, true);
    }
    relayTransfer(engine, root, 4096, "concurrent", false, 6);
    relayTransfer(engine, root, 2 * 1024 * 1024, "family-chain");
    // 同一CURLM官方源的直连暂时失败后，不能重新套回已失败网关。
    relayTransfer(engine, root, 4096, "bounce503");
    // 确认恢复状态只属于原逻辑源，健康备源仍可正常经网关，避免一刀切禁用加速。
    relayTransfer(engine, root, 4096, "switch503");
    // 仅挑选到尚未准入的B不算换源提交；A冷却恢复后仍须延续原直连链。
    relayTransfer(engine, root, 4096, "defer503");
}
