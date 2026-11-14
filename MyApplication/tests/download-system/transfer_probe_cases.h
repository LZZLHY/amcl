/**
 * 执行生产Engine限量二进制GET的真实socket/TLS回归。不复制竞速或下载算法；HTTP服务
 * 只控制响应时序和协议故障，TLS由本轮临时CA+Python标准库服务实际握手验证。
 */
#pragma once
#include <sys/wait.h>
#include <signal.h>
#include "config.h"

namespace transfer_probe_cases {

/** 独占回环监听；不同case使用独立IP，避免真实Retry-After主机冷却污染后续输入。 */
class Server {
public:
    enum class Mode { FastHeaders, FastBody, IgnoreRange, WrongRange, Html, HtmlSniff, Silent, Redirect, Short, RateLimit, RedirectOnce, ForbiddenRedirect, HeadersOnly };
    const Mode mode;
    const size_t total = 1024 * 1024;
    std::string host;
    int listener = -1, port = 0;
    std::atomic<bool> stop{false}, credential_seen{false};
    std::atomic<int> requests{0};
    std::thread acceptor;
    std::vector<std::thread> clients;
    explicit Server(Mode selected) : mode(selected) {
        static int next = 1; host = "127.0.2." + std::to_string(next++);
        listener = ::socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
        sockaddr_in address{}; address.sin_family = AF_INET; assert(::inet_pton(AF_INET, host.c_str(), &address.sin_addr) == 1);
        assert(::bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0);
        socklen_t size = sizeof(address); assert(::getsockname(listener, reinterpret_cast<sockaddr*>(&address), &size) == 0);
        port = ntohs(address.sin_port); assert(::listen(listener, 8) == 0);
        acceptor = std::thread([this] {
            while (!stop) {
                pollfd ready{listener, POLLIN, 0}; if (::poll(&ready, 1, 20) <= 0) continue;
                int socket = ::accept(listener, nullptr, nullptr);
                if (socket >= 0) clients.emplace_back([this, socket] { serve(socket); });
            }
        });
    }
    ~Server() {
        stop = true; if (acceptor.joinable()) acceptor.join();
        for (auto& client : clients) client.join();
        ::close(listener);
    }
    std::string url() const { return "http://" + host + ":" + std::to_string(port) + "/sample"; }
private:
    /** 小步等待响应停止，测试清理不留下睡眠线程或未关闭socket。 */
    bool pause(int milliseconds) {
        const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(milliseconds);
        while (!stop && std::chrono::steady_clock::now() < until) std::this_thread::sleep_for(std::chrono::milliseconds(10));
        return !stop;
    }
    bool sendAll(int socket, const std::string& data) {
        size_t at = 0;
        while (!stop && at < data.size()) {
            auto count = ::send(socket, data.data() + at, data.size() - at, MSG_NOSIGNAL);
            if (count <= 0) return false; at += static_cast<size_t>(count);
        }
        return at == data.size();
    }
    /** 从真实Range读出本次目标；响应故障只改服务端，不改生产函数的cap或时钟。 */
    void serve(int socket) {
        timeval timeout{2, 0}; ::setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        std::string request; char buffer[2048];
        while (request.find("\r\n\r\n") == std::string::npos && request.size() < 16384) {
            auto count = ::recv(socket, buffer, sizeof(buffer), 0); if (count <= 0) break;
            request.append(buffer, static_cast<size_t>(count));
        }
        ++requests;
        if (request.find("Authorization:") != std::string::npos || request.find("X-AMCL-") != std::string::npos ||
            request.find("Cookie:") != std::string::npos) credential_seen = true;
        const auto range = relayFixtureHeader(request, "Range"); assert(range.rfind("bytes=0-", 0) == 0);
        const size_t sample = std::stoull(range.substr(8)) + 1;
        assert(sample >= 1 && sample <= 524288);
        if (mode == Mode::FastBody) pause(700);
        if (mode == Mode::Silent) { pause(10000); ::close(socket); return; }
        if (mode == Mode::Redirect || mode == Mode::ForbiddenRedirect ||
            (mode == Mode::RedirectOnce && request.rfind("GET /sample ", 0) == 0)) {
            if (mode == Mode::Redirect) pause(650);
            if (mode == Mode::RedirectOnce) pause(150);
            const std::string next = mode == Mode::ForbiddenRedirect ? "file:///etc/passwd" :
                (mode == Mode::RedirectOnce ? "/final?sig=A%2Bb&x=2&x=1" : "/sample");
            sendAll(socket, "HTTP/1.1 302 Found\r\nLocation: " + next + "\r\nContent-Length: 1048576\r\n\r\n" + std::string(65536, 'x'));
            ::close(socket); return;
        }
        if (mode == Mode::RedirectOnce) assert(request.rfind("GET /final?sig=A%2Bb&x=2&x=1 ", 0) == 0);
        const bool full = mode == Mode::IgnoreRange;
        const int status = mode == Mode::RateLimit ? 503 : (full ? 200 : 206);
        const size_t length = full ? total : sample;
        std::string header = "HTTP/1.1 " + std::to_string(status) + " Fixture\r\nContent-Length: " + std::to_string(length) +
            "\r\nContent-Type: " + (mode == Mode::Html ? "text/html" : "application/octet-stream") + "\r\nConnection: close\r\n";
        if (!full) header += "Content-Range: bytes " + std::to_string(mode == Mode::WrongRange ? 1 : 0) + "-" +
            std::to_string(sample - 1) + "/" + std::to_string(total) + "\r\n";
        if (mode == Mode::RateLimit) header += "Retry-After: 60\r\n";
        bool open = sendAll(socket, header + "\r\n");
        if (mode == Mode::HeadersOnly) { pause(10000); ::close(socket); return; }
        std::string body(length, 'q');
        if (mode == Mode::Html || mode == Mode::HtmlSniff) body.replace(0, 15, "<!doctype html>");
        if (mode == Mode::Short) body.resize(sample / 2);
        for (size_t at = 0; open && at < body.size();) {
            const size_t bytes = std::min<size_t>(8192, body.size() - at);
            open = sendAll(socket, body.substr(at, bytes)); at += bytes;
            if (mode == Mode::FastHeaders && open) pause(100);
        }
        ::shutdown(socket, SHUT_RDWR); ::close(socket);
    }
};

/** 只返回测量结果，正常限样不产生文件或relay请求，严格传递收到的HTTP/字节事实。 */
static download::TransferProbeResult measure(download::DownloadEngine& engine, Server& server, int seconds = 5, size_t cap = 262144) {
    download::TransferProbeResult result;
    engine.probeTransfer(server.url(), server.total, cap, seconds, "amcl/probe-test", result);
    assert(!server.credential_seen);
    return result;
}

/** 快TTFB慢正文与慢TTFB快正文必须呈现不同测量值，不能按一次HEAD的RTT当下载吞吐。 */
static void timing(download::DownloadEngine& engine) {
    Server a(Server::Mode::FastHeaders), b(Server::Mode::FastBody);
    const auto slow = measure(engine, a), fast = measure(engine, b);
    assert(slow.completed_sample && fast.completed_sample && slow.received_bytes == 262144 && fast.received_bytes == 262144);
    assert(slow.ttfb_ms < fast.ttfb_ms && slow.elapsed_ms > fast.elapsed_ms * 2);
    std::cout << "PASS probe actual GET distinguishes fast-headers/slow-body " << slow.elapsed_ms << "ms from slow-headers/fast-body " << fast.elapsed_ms << "ms" << std::endl;
}

/** 限样、Range拒绝、错误HTML、短读和服务端冷却均由真实HTTP触发。 */
static void protocols(download::DownloadEngine& engine) {
    for (auto mode : {Server::Mode::IgnoreRange, Server::Mode::WrongRange, Server::Mode::Html,
                      Server::Mode::HtmlSniff, Server::Mode::Short, Server::Mode::RateLimit}) {
        Server server(mode); const auto result = measure(engine, server);
        if (mode == Server::Mode::IgnoreRange) {
            assert(result.completed_sample && !result.range_honored && result.received_bytes == 262144 && result.error_kind.empty());
            download::FetchResponse legacy;
            assert(engine.fetchToBufferEx(server.url(), {}, 5, {{"Range", "bytes=0-262143"}}, 262144, legacy) < 0);
            assert(legacy.err_kind == "ResponseTooLarge"); // 原字符串API的错误语义保持，不能拿它冒充sample完成。
        }
        else assert(!result.completed_sample && !result.error_kind.empty());
        if (mode == Server::Mode::RateLimit) assert(result.http_status == 503 && engine.hostRateLimitUntilMs(server.host) > download::netThreadSteadyNowMs());
        std::cout << "PASS probe protocol mode=" << static_cast<int>(mode) << " status=" << result.http_status << " bytes=" << result.received_bytes << " error=" << result.error_kind << std::endl;
    }
    Server hard_cap(Server::Mode::IgnoreRange); const auto full = measure(engine, hard_cap, 5, 524288);
    assert(full.completed_sample && full.received_bytes == 524288);
    download::TransferProbeResult denied;
    assert(engine.probeTransfer(hard_cap.url(), hard_cap.total, 524289, 5, "amcl/test", denied) < 0 && denied.error_kind == "InvalidArgument");
    assert(engine.probeTransfer(hard_cap.url(), hard_cap.total, 262144, 9, "amcl/test", denied) < 0 && denied.error_kind == "InvalidArgument");
    assert(hard_cap.requests == 1);
    download::TransferProbeResult credentials;
    const auto address = hard_cap.url(); const auto colon = address.find("://") + 3;
    assert(engine.probeTransfer(address.substr(0, colon) + "user:secret@" + address.substr(colon), hard_cap.total,
        262144, 5, "amcl/test", credentials) < 0 && credentials.error_kind == "InvalidArgument");
    assert(hard_cap.requests == 1);
    std::cout << "PASS probe 512KiB/8s hard admission bounds perform zero extra HTTP" << std::endl;
    Server redirected(Server::Mode::RedirectOnce), forbidden(Server::Mode::ForbiddenRedirect);
    const auto followed = measure(engine, redirected), rejected = measure(engine, forbidden);
    assert(followed.completed_sample && redirected.requests == 2 && followed.received_bytes == 262144 && followed.ttfb_ms >= 140);
    assert(!rejected.completed_sample && rejected.error_kind == "InvalidRedirect" && forbidden.requests == 1);
    std::cout << "PASS probe relative redirect preserves signed query, excludes 3xx body and rejects file protocol" << std::endl;
}

/** 静默/多跳/准入等待共用总deadline；异步排队耗掉预算时不能重新起钟发HTTP。 */
static void deadlines(download::DownloadEngine& engine) {
    for (auto mode : {Server::Mode::Silent, Server::Mode::HeadersOnly, Server::Mode::Redirect}) {
        Server server(mode); const auto result = measure(engine, server, 1);
        std::cout << "PROBE DEADLINE mode=" << static_cast<int>(mode) << " elapsed=" << result.elapsed_ms
                  << " error=" << result.error_kind << " status=" << result.http_status << " requests=" << server.requests << std::endl;
        assert(!result.completed_sample && result.error_kind == "Timeout" && result.elapsed_ms >= 900 && result.elapsed_ms < 1500);
        assert(result.received_bytes == 0 && result.ttfb_ms == -1);
        std::cout << "PASS probe shared deadline mode=" << static_cast<int>(mode) << " elapsed=" << result.elapsed_ms << "ms requests=" << server.requests << std::endl;
    }
    Server server(Server::Mode::FastBody);
    std::vector<uint64_t> slots;
    for (int i = 0; i < 256; ++i) { uint64_t token = 0; if (!engine.tryAcquireHostSlot(server.host, &token)) break; slots.push_back(token); }
    assert(!slots.empty()); const auto result = measure(engine, server, 1);
    for (auto token : slots) engine.releaseHostSlot(server.host, false, token);
    assert(result.error_kind == "Timeout" && server.requests == 0 && result.elapsed_ms < 1500);
    uint64_t next = 0; assert(engine.tryAcquireHostSlot(server.host, &next)); engine.releaseHostSlot(server.host, false, next);
    download::TransferProbeResult queued;
    engine.probeTransfer(server.url(), server.total, 262144, 5, "amcl/test", queued, download::netThreadSteadyNowMs() - 9000);
    assert(queued.error_kind == "Timeout" && server.requests == 0);
    download::TransferProbeResult delayed;
    engine.probeTransfer(server.url(), server.total, 262144, 5, "amcl/test", delayed, download::netThreadSteadyNowMs() - 2000);
    assert(delayed.completed_sample && delayed.ttfb_ms >= 2600 && delayed.elapsed_ms >= delayed.ttfb_ms &&
        delayed.elapsed_ms - delayed.ttfb_ms < 500);
    std::cout << "PROBE CLOCK queuedTTFB=" << delayed.ttfb_ms << " elapsed=" << delayed.elapsed_ms
              << " body=" << delayed.elapsed_ms - delayed.ttfb_ms << "ms" << std::endl;
    std::cout << "PASS probe admission/expired-queue deadlines perform zero HTTP and return slots" << std::endl;
}

/** 子进程只用本轮路径和固定程序，无shell插值；返回值由真实waitpid核对。 */
static pid_t child(const std::vector<std::string>& arguments) {
    const auto pid = ::fork(); assert(pid >= 0);
    if (pid == 0) {
        int null = ::open("/dev/null", O_WRONLY); ::dup2(null, STDOUT_FILENO); ::dup2(null, STDERR_FILENO); ::close(null);
        std::vector<char*> values; for (const auto& value : arguments) values.push_back(const_cast<char*>(value.c_str())); values.push_back(nullptr);
        ::execvp(values[0], values.data()); ::_exit(127);
    }
    return pid;
}

/** 实际TLS：未信任证书和主机名不匹配必须失败，正确CA/主机才得到有效206样本。 */
static void tls(download::DownloadEngine& engine, const fs::path& root) {
    fs::path dir = root / "sample-tls"; fs::create_directories(dir);
    auto cert = (dir / "ca.pem").string(), key = (dir / "key.pem").string();
    auto openssl = child({"openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost", "-keyout", key, "-out", cert});
    int status = 0; assert(::waitpid(openssl, &status, 0) == openssl && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    Server plaintext(Server::Mode::FastBody);
    write(dir / "serve.py", R"PY(import http.server,ssl,sys,pathlib
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  if self.path=='/downgrade':
   self.send_response(302);self.send_header('Location',sys.argv[4]);self.send_header('Content-Length','0');self.end_headers();return
  n=int(self.headers['Range'].split('-')[1])+1
  self.send_response(206);self.send_header('Content-Length',str(n));self.send_header('Content-Range',f'bytes 0-{n-1}/1048576');self.end_headers()
  try:self.wfile.write(b'z'*n)
  except (BrokenPipeError,ConnectionResetError):pass
s=http.server.ThreadingHTTPServer(('127.0.0.1',0),H)
c=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);c.load_cert_chain(sys.argv[2],sys.argv[3]);s.socket=c.wrap_socket(s.socket,server_side=True)
pathlib.Path(sys.argv[1]).write_text(str(s.server_address[1]));s.serve_forever()
)PY");
    const auto ready = dir / "ready";
    auto python = child({"python3", (dir / "serve.py").string(), ready.string(), cert, key, plaintext.url()});
    for (int i = 0; i < 500 && !fs::exists(ready); ++i) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    assert(fs::exists(ready)); const std::string port = readFixtureFile(ready);
    const auto original_ca = download::getCaBundlePath(); download::setCaBundlePath("");
    download::TransferProbeResult untrusted, wrong_host, trusted, downgrade;
    engine.probeTransfer("https://localhost:" + port + "/sample", 1048576, 262144, 5, "amcl/test", untrusted);
    download::setCaBundlePath(cert);
    engine.probeTransfer("https://127.0.0.1:" + port + "/sample", 1048576, 262144, 5, "amcl/test", wrong_host);
    engine.probeTransfer("https://localhost:" + port + "/sample", 1048576, 262144, 5, "amcl/test", trusted);
    engine.probeTransfer("https://localhost:" + port + "/downgrade", 1048576, 262144, 5, "amcl/test", downgrade);
    download::setCaBundlePath(original_ca);
    ::kill(python, SIGTERM); assert(::waitpid(python, &status, 0) == python);
    assert(untrusted.error_kind == "SslFail" && wrong_host.error_kind == "SslFail");
    assert(untrusted.http_status == 0 && wrong_host.http_status == 0 && trusted.completed_sample && trusted.range_honored);
    assert(downgrade.error_kind == "InvalidRedirect" && plaintext.requests == 0);
    std::cout << "PASS probe real TLS rejects unknown CA/wrong hostname and accepts trusted matching host" << std::endl;
}

/** 即使已有有效网关配置，公共样本仍只测指定原站，不计proof/故障/回退。 */
static void bypassRelay(download::DownloadEngine& engine) {
    RelayHttpFixture server(1048576);
    download::RelayConfig cfg; cfg.enabled = true; cfg.base = server.base;
    cfg.ticket = "relay-test-ticket"; cfg.session_key = server.key;
    download::relaySetConfig(cfg); const auto before = download::relayStats();
    download::TransferProbeResult result;
    engine.probeTransfer("https://piston-data.mojang.com/amcl-relay-test/probe.jar", 1048576, 262144, 5, "amcl/test", result);
    const auto after = download::relayStats();
    assert(result.completed_sample && result.range_honored && server.gateway == 0 && server.direct == 1 && !server.leaked_headers);
    assert(before.requests == after.requests && before.failures == after.failures && before.fallbacks == after.fallbacks);
    download::relayDisable();
    std::cout << "PASS probe bypasses enabled relay without credentials or cap failure counters" << std::endl;
}

/** 通过真shutdown中断Native调用，返回后server可join且Engine生命周期计数不再阻塞退出。 */
static void shutdown(download::DownloadEngine& engine) {
    Server server(Server::Mode::Silent); download::TransferProbeResult result;
    std::thread active([&] { result = measure(engine, server, 5); });
    for (int i = 0; i < 500 && server.requests == 0; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    assert(server.requests == 1); const auto before = download::netThreadSteadyNowMs();
    engine.shutdown(); active.join();
    assert(result.error_kind == "Aborted" && download::netThreadSteadyNowMs() - before < 1500);
    std::cout << "PASS probe actual shutdown settles curl/admission/lifecycle owner" << std::endl;
}
}

static void runTransferProbeCases(download::DownloadEngine& engine, const fs::path& root) {
    transfer_probe_cases::timing(engine); transfer_probe_cases::protocols(engine);
    transfer_probe_cases::deadlines(engine); transfer_probe_cases::tls(engine, root);
    transfer_probe_cases::bypassRelay(engine);
}
