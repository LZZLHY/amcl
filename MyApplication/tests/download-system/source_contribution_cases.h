/**
 * 来源贡献的真实回环回归：运行生产 Engine/worker/multi/磁盘终检，不复制换源算法。
 * 一份错误 prefix 与健康来源 tail 能凑齐大小，必须由最终摘要阻止发布；贡献未知时
 * 不得把最后来源判成坏源，后续完整单源复验应恢复。所有文件仅在宿主 fixture root。
 */
#pragma once

#include <atomic>
#include <fstream>
#include <mutex>
#include <string>
#include <vector>
#include <sys/time.h>

namespace source_contribution_cases {

class HttpFixture {
public:
    enum class Mode { Good, BadPrefixThenCooldown, BadFull };
    const Mode mode;
    const std::string host, payload;
    const std::filesystem::path final_path;
    int listener = -1, port = 0;
    std::atomic<bool> stopped{false};
    std::atomic<int> requests{0}, heads{0}, invalid_publications{0};
    std::mutex offsets_mu;
    std::vector<int64_t> offsets;
    std::thread worker;

    HttpFixture(std::string address, std::string body, Mode behavior,
                std::filesystem::path published = {})
        : mode(behavior), host(std::move(address)), payload(std::move(body)),
          final_path(std::move(published)) {
        listener = ::socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
        sockaddr_in address_value{}; address_value.sin_family = AF_INET;
        assert(::inet_pton(AF_INET, host.c_str(), &address_value.sin_addr) == 1);
        assert(::bind(listener, reinterpret_cast<sockaddr*>(&address_value), sizeof(address_value)) == 0);
        socklen_t length = sizeof(address_value);
        assert(::getsockname(listener, reinterpret_cast<sockaddr*>(&address_value), &length) == 0);
        port = ntohs(address_value.sin_port); assert(::listen(listener, 8) == 0);
        worker = std::thread([this] { serve(); });
    }
    ~HttpFixture() { stopped = true; if (worker.joinable()) worker.join(); ::close(listener); }
    std::string url() const { return "http://" + host + ":" + std::to_string(port) + "/object"; }
    std::vector<int64_t> recordedOffsets() {
        std::lock_guard<std::mutex> lock(offsets_mu); return offsets;
    }

private:
    void sendAll(int client, const std::string& value) {
        size_t done = 0;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        while (!stopped.load() && done < value.size() && std::chrono::steady_clock::now() < deadline) {
            ssize_t sent = ::send(client, value.data() + done, value.size() - done, MSG_NOSIGNAL);
            if (sent <= 0) return;
            done += static_cast<size_t>(sent);
        }
    }
    void serve() {
        while (!stopped.load()) {
            pollfd ready{listener, POLLIN, 0}; if (::poll(&ready, 1, 100) <= 0) continue;
            int client = ::accept(listener, nullptr, nullptr); if (client < 0) continue;
            timeval timeout{1, 0};
            ::setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            ::setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            std::string request; char buffer[2048];
            const auto request_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (!stopped.load() && std::chrono::steady_clock::now() < request_deadline &&
                   request.find("\r\n\r\n") == std::string::npos && request.size() < 16384) {
                ssize_t size = ::recv(client, buffer, sizeof(buffer), 0); if (size <= 0) break;
                request.append(buffer, static_cast<size_t>(size));
            }
            if (request.compare(0, 5, "HEAD ") == 0) ++heads;
            const auto range = request.find("Range: bytes=");
            const int64_t offset = range == std::string::npos ? 0 : std::stoll(request.substr(range + 13));
            const int number = ++requests;
            { std::lock_guard<std::mutex> lock(offsets_mu); offsets.push_back(offset); }
            // 在第二次完整复验正文交付前，坏混合内容已经完成过一轮终检。最终路径
            // 仍须保留原用户内容，证明未以大小相等就发布损坏对象。
            if (!final_path.empty() && readFixtureFile(final_path) != "USER-KEEP") ++invalid_publications;
            if (mode == Mode::BadPrefixThenCooldown && number > 1) {
                sendAll(client, "HTTP/1.1 503 Fixture\r\nRetry-After: 120\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            } else {
                assert(offset >= 0 && static_cast<size_t>(offset) < payload.size());
                const size_t remaining = payload.size() - static_cast<size_t>(offset);
                std::string header = range == std::string::npos ? "HTTP/1.1 200 OK\r\n" : "HTTP/1.1 206 Partial Content\r\n";
                header += "Content-Length: " + std::to_string(remaining) + "\r\n";
                if (range != std::string::npos) header += "Content-Range: bytes " + std::to_string(offset) + "-" +
                    std::to_string(payload.size() - 1) + "/" + std::to_string(payload.size()) + "\r\n";
                sendAll(client, header + "Connection: close\r\n\r\n");
                std::string body = payload.substr(static_cast<size_t>(offset));
                if (mode == Mode::BadPrefixThenCooldown) body.assign(payload.size() / 2, '!');
                else if (mode == Mode::BadFull) body.assign(remaining, '!');
                sendAll(client, body);
            }
            ::shutdown(client, SHUT_RDWR); ::close(client);
        }
    }
};

inline std::string payload(size_t size) {
    std::string result(size, 'a');
    for (size_t i = 0; i < size; ++i) result[i] = static_cast<char>('a' + i % 23);
    return result;
}

inline download::LoaderDownload::Config configuration(const std::filesystem::path& root,
        const std::filesystem::path& target, const std::vector<std::string>& urls, const std::string& bytes) {
    auto cfg = config("logical content contribution", root, target);
    cfg.files[0].urls = urls; cfg.files[0].max_connections = 1;
    cfg.files[0].check.expected_size = bytes.size();
    download::Sha1 hash; hash.update(bytes.data(), bytes.size()); cfg.files[0].check.expected_sha1 = hash.finalizeHex();
    return cfg;
}

inline void mixedPrefix(download::DownloadEngine& engine, const std::filesystem::path& root, size_t size) {
    const bool small = size < 1024 * 1024;
    const auto target = root / (small ? "mixed-prefix-multi" : "mixed-prefix-worker"); write(target, "USER-KEEP");
    const auto bytes = payload(size);
    HttpFixture bad(small ? "127.0.0.81" : "127.0.0.83", bytes, HttpFixture::Mode::BadPrefixThenCooldown);
    HttpFixture good(small ? "127.0.0.82" : "127.0.0.84", bytes, HttpFixture::Mode::Good, target);
    auto task = engine.createTask(configuration(root, target, {bad.url(), good.url()}, bytes));
    assert(engine.startTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Finished && readFixtureFile(target) == bytes);
    const auto requests = good.recordedOffsets();
    assert(requests.size() == 2 && requests[0] == static_cast<int64_t>(size / 2) && requests[1] == 0);
    assert(!task->files()[0]->sources()[0]->checksum_bad && !task->files()[0]->sources()[1]->checksum_bad);
    assert(task->files()[0]->requiresSingleSourceRecheck() && good.invalid_publications == 0);
    purgeSettled(engine, task->taskId());
    std::cout << "PASS mixed prefix does not blame healthy tail; full recheck path=" << (small ? "multi" : "worker") << std::endl;
}

inline void unknownResumePrefix(download::DownloadEngine& engine, const std::filesystem::path& root, size_t size) {
    const bool small = size < 1024 * 1024;
    const auto target = root / (small ? "unknown-prefix-multi" : "unknown-prefix-worker"); write(target, "USER-KEEP");
    const auto bytes = payload(size);
    HttpFixture good(small ? "127.0.0.85" : "127.0.0.86", bytes, HttpFixture::Mode::Good, target);
    auto cfg = configuration(root, target, {good.url()}, bytes);
    std::string old_part(size, '\0'); std::fill(old_part.begin(), old_part.begin() + size / 2, '!');
    write(target.string() + ".amcl.part", old_part);
    download::DownloadMeta meta; meta.url_primary = good.url(); meta.url_sources = {good.url()};
    meta.file_size = size; meta.check = cfg.files[0].check; meta.created_at = "2026-10-18T00:00:00Z";
    meta.segments.push_back({0, -1, static_cast<int64_t>(size / 2)});
    assert(download::writeMetaFile(target.string() + ".download-meta", meta));
    auto task = engine.createTask(cfg); assert(engine.startTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Finished && readFixtureFile(target) == bytes);
    const auto requests = good.recordedOffsets();
    assert(requests.size() == 2 && requests[0] == static_cast<int64_t>(size / 2) && requests[1] == 0);
    assert(!task->files()[0]->sources()[0]->checksum_bad && good.invalid_publications == 0);
    purgeSettled(engine, task->taskId());
    std::cout << "PASS unknown v1 prefix does not blame healthy tail path=" << (small ? "multi" : "worker") << std::endl;
}

inline void pureBadAndAuthorizedBoundaries(download::DownloadEngine& engine, const std::filesystem::path& root) {
    const auto bytes = payload(4096);
    const auto target = root / "pure-source-recheck"; write(target, "USER-KEEP");
    HttpFixture bad("127.0.0.87", bytes, HttpFixture::Mode::BadFull);
    HttpFixture good("127.0.0.88", bytes, HttpFixture::Mode::Good, target);
    auto task = engine.createTask(configuration(root, target, {bad.url(), good.url()}, bytes));
    assert(engine.startTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Finished && readFixtureFile(target) == bytes);
    assert(task->files()[0]->sources()[0]->checksum_bad && !task->files()[0]->sources()[1]->checksum_bad);
    purgeSettled(engine, task->taskId());

    const auto restricted_target = root / "authorized-bad-digest"; write(restricted_target, "USER-KEEP");
    HttpFixture restricted("127.0.0.89", bytes, HttpFixture::Mode::BadFull);
    auto cfg = configuration(root, restricted_target, {restricted.url()}, bytes);
    auto& file = cfg.files[0]; file.bearer_token = "fixture-only-lease"; file.authorized_policy = true;
    file.authorized_single_use = true; file.authorized_max_http_attempts = 1;
    file.authorized_valid_for_ms = 60000; file.authorized_max_bytes = bytes.size();
    auto authorized = engine.createTask(cfg); assert(engine.startTask(authorized->taskId())); waitForSettled(authorized);
    assert(authorized->state() == download::LoadState::Failed && restricted.requests == 1);
    assert(!authorized->files()[0]->requiresSingleSourceRecheck() && readFixtureFile(restricted_target) == "USER-KEEP");
    assert(authorized->error() && authorized->error()->kind == download::ErrorKind::ChecksumMismatch);
    assert(authorized->error()->http_attempts == 1 && authorized->error()->bytes_written == 4096);
    purgeSettled(engine, authorized->taskId());
    std::cout << "PASS pure source attribution excludes bad source; authorized digest failure never ordinary-retries" << std::endl;
}

/** 宿主进程实际 read/pread 字节，用于证明已进入大文件摘要读取而非只碰巧读到状态。 */
inline uint64_t processReadCharacters() {
    std::ifstream input("/proc/self/io"); assert(input.good());
    std::string line;
    while (std::getline(input, line)) {
        if (line.compare(0, 6, "rchar:") == 0) return std::stoull(line.substr(6));
    }
    assert(false && "host read accounting missing"); return 0;
}

/**
 * 完成的 v1 part 需要真实重读摘要。确认至少8MiB已经读取后再取消，覆盖 onAll
 * 入口取消检查之后、checksum 失败转入完整复验之前的窗口；不得发出新的 HTTP。
 */
inline void cancellationDuringDigestDoesNotRecheck(download::DownloadEngine& engine,
                                                   const std::filesystem::path& root) {
    constexpr size_t size = 64 * 1024 * 1024;
    const auto target = root / "cancel-during-checksum"; write(target, "USER-KEEP");
    HttpFixture source("127.0.0.90", payload(4096), HttpFixture::Mode::Good);
    auto cfg = config("cancel during complete digest verification", root, target);
    auto& file_cfg = cfg.files[0]; file_cfg.urls = {source.url()}; file_cfg.max_connections = 1;
    file_cfg.check.expected_size = size;
    const std::string good_chunk(8192, 'g'), bad_chunk(8192, '!');
    download::Sha1 hash;
    std::ofstream part(target.string() + ".amcl.part", std::ios::binary);
    assert(part.good());
    for (size_t written = 0; written < size; written += good_chunk.size()) {
        hash.update(good_chunk.data(), good_chunk.size()); part.write(bad_chunk.data(), bad_chunk.size());
    }
    part.close(); assert(part.good()); file_cfg.check.expected_sha1 = hash.finalizeHex();
    download::DownloadMeta meta; meta.url_primary = source.url(); meta.url_sources = {source.url()};
    meta.file_size = size; meta.check = file_cfg.check; meta.created_at = "2026-10-18T00:00:00Z";
    meta.segments.push_back({0, static_cast<int64_t>(size - 1), static_cast<int64_t>(size)});
    assert(download::writeMetaFile(target.string() + ".download-meta", meta));
    auto task = engine.createTask(cfg);
    const uint64_t before = processReadCharacters();
    assert(engine.startTask(task->taskId()));
    bool reading_digest = false;
    // 本套件此处没有其他下载；轮询自身最多约百KiB /proc读取，无法伪造8MiB门槛。
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    for (int poll = 0; poll < 1000 && std::chrono::steady_clock::now() < deadline; ++poll) {
        if (task->files()[0]->state() == download::NetState::FinalCheck &&
            processReadCharacters() - before >= 8 * 1024 * 1024) {
            reading_digest = true; break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    assert(reading_digest && task->files()[0]->state() == download::NetState::FinalCheck);
    assert(engine.cancelTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Aborted && source.requests == 0);
    assert(readFixtureFile(target) == "USER-KEEP"); purgeSettled(engine, task->taskId());
    std::cout << "PASS cancellation during actual digest read never starts a checksum recheck HTTP" << std::endl;
}

} // namespace source_contribution_cases

inline void runSourceContributionCases(download::DownloadEngine& engine, const std::filesystem::path& root) {
    for (size_t size : {size_t(4096), size_t(3 * 1024 * 1024)}) {
        source_contribution_cases::mixedPrefix(engine, root, size);
        source_contribution_cases::unknownResumePrefix(engine, root, size);
    }
    source_contribution_cases::pureBadAndAuthorizedBoundaries(engine, root);
    source_contribution_cases::cancellationDuringDigestDoesNotRecheck(engine, root);
}
