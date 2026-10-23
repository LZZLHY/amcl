/**
 * 未知大小与 Range 的真实核心组合回归。服务器只在回环地址制造截流/错误窗口，
 * 运行生产 Engine、worker/multi、meta 恢复、摘要与原子提交，不复制下载状态机。
 * HEAD 故意不给长度；GET 计数只在服务端读到完整请求头后增加，不能用 attempt 日志
 * 代替真实请求。夹具全部位于命令行指定的 POSIX root，不操作用户文件或外网。
 */
#pragma once

#include <atomic>
#include <mutex>
#include <string>
#include <vector>
#include <sys/time.h>

namespace unknown_size_cases {

constexpr size_t kObjectBytes = 3699647;
constexpr size_t kPrefixBytes = 577640;

/** 每个实例单线程串行服务；本组下载显式限为一个连接，方便逐请求精确对账。 */
class HttpFixture {
public:
    enum class Mode { TruncateFirst, HoldFirstPrefix, ShortRangeSecond, ShortBodySecond, LongBodySecond,
                      UnsolicitedPartial, Good, BadShortFull };
    const std::string host, body;
    const Mode mode;
    const std::filesystem::path final_path;
    const int malformed_request;
    int listener = -1, port = 0;
    std::atomic<bool> stopped{false}, release_prefix{false};
    std::atomic<int> heads{0}, gets{0}, premature_publications{0};
    // 仅在请求开始观察 canonical total；发布使用 release/acquire，测试不会竞态写裸指针。
    std::atomic<download::NetFile*> observed_file{nullptr};
    std::thread worker;

    HttpFixture(std::string address, std::string bytes, Mode behavior,
                std::filesystem::path target = {}, int malformed_at = 2)
        : host(std::move(address)), body(std::move(bytes)), mode(behavior), final_path(std::move(target)),
          malformed_request(malformed_at) {
        listener = ::socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
        sockaddr_in value{}; value.sin_family = AF_INET;
        assert(::inet_pton(AF_INET, host.c_str(), &value.sin_addr) == 1);
        assert(::bind(listener, reinterpret_cast<sockaddr*>(&value), sizeof(value)) == 0);
        socklen_t length = sizeof(value);
        assert(::getsockname(listener, reinterpret_cast<sockaddr*>(&value), &length) == 0);
        port = ntohs(value.sin_port); assert(::listen(listener, 8) == 0);
        worker = std::thread([this] { serve(); });
    }
    ~HttpFixture() { stopped = true; if (worker.joinable()) worker.join(); ::close(listener); }
    std::string url() const { return "http://" + host + ":" + std::to_string(port) + "/object"; }
    std::vector<int64_t> recordedOffsets() {
        std::lock_guard<std::mutex> lock(records_mu_); return offsets_;
    }
    std::vector<int64_t> observedTotals() {
        std::lock_guard<std::mutex> lock(records_mu_); return totals_;
    }

private:
    std::mutex records_mu_;
    std::vector<int64_t> offsets_, totals_;

    /** 发送失败立即退出；停止令牌、单次 socket 超时和总时限共同保证失败夹具有界退出。 */
    void sendAll(int client, const std::string& bytes) {
        size_t done = 0;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        while (!stopped.load() && done < bytes.size() && std::chrono::steady_clock::now() < deadline) {
            const ssize_t sent = ::send(client, bytes.data() + done, bytes.size() - done, MSG_NOSIGNAL);
            if (sent <= 0) return;
            done += static_cast<size_t>(sent);
        }
    }
    void serve() {
        while (!stopped.load()) {
            pollfd ready{listener, POLLIN, 0}; if (::poll(&ready, 1, 100) <= 0) continue;
            const int client = ::accept(listener, nullptr, nullptr); if (client < 0) continue;
            timeval timeout{1, 0};
            ::setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            ::setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            std::string request; char buffer[2048];
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (!stopped.load() && std::chrono::steady_clock::now() < deadline && request.size() < 16384 &&
                   request.find("\r\n\r\n") == std::string::npos) {
                const ssize_t count = ::recv(client, buffer, sizeof(buffer), 0); if (count <= 0) break;
                request.append(buffer, static_cast<size_t>(count));
            }
            if (request.find("\r\n\r\n") == std::string::npos) { ::close(client); continue; }
            if (request.compare(0, 5, "HEAD ") == 0) {
                ++heads;
                sendAll(client, "HTTP/1.1 405 Fixture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            } else {
                assert(request.compare(0, 4, "GET ") == 0);
                const auto range_pos = request.find("Range: bytes=");
                const bool range = range_pos != std::string::npos;
                const int64_t offset = range ? std::stoll(request.substr(range_pos + 13)) : 0;
                assert(offset >= 0 && static_cast<size_t>(offset) < body.size());
                const int number = ++gets;
                const auto* file = observed_file.load(std::memory_order_acquire);
                {
                    std::lock_guard<std::mutex> lock(records_mu_);
                    offsets_.push_back(offset); totals_.push_back(file ? file->fileSize() : -999);
                }
                if (!final_path.empty() && readFixtureFile(final_path) != "USER-KEEP") ++premature_publications;
                size_t response_end = body.size() - 1;
                // 语法合法且 start 对齐，但这个窗口没有抵达声明的完整对象 EOF。
                // 若只检查 HTTP 正常结束，无 checker 的恢复任务会错误发布短文件。
                if (mode == Mode::ShortRangeSecond && number == malformed_request) {
                    assert(range); response_end = static_cast<size_t>(offset) + 1023;
                }
                size_t response_length = response_end - static_cast<size_t>(offset) + 1;
                // header声称的窗口已到对象末尾，但CL与实际正文只给1024B；curl会正常
                // 结束，下载器仍须由本次Content-Range的完整长度识别短读。
                if (mode == Mode::ShortBodySecond && number == malformed_request) { assert(range); response_length = 1024; }
                const bool overlong = mode == Mode::LongBodySecond && number == malformed_request;
                const bool unsolicited = mode == Mode::UnsolicitedPartial && number == 1;
                if (overlong) { assert(range); response_length += 100; }
                if (unsolicited) { assert(!range); response_end = 1023; response_length = 1024; }
                std::string header = range || unsolicited ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n";
                header += "Content-Length: " + std::to_string(response_length) + "\r\n";
                if (range || unsolicited) header += "Content-Range: bytes " + std::to_string(offset) + "-" +
                    std::to_string(response_end) + "/" + std::to_string(body.size()) + "\r\n";
                sendAll(client, header + "Connection: close\r\n\r\n");
                size_t limit = response_length;
                if (number == 1 && offset == 0 && mode != Mode::Good && mode != Mode::BadShortFull && !unsolicited)
                    limit = std::min(response_length, kPrefixBytes);
                std::string response_body = body.substr(static_cast<size_t>(offset), limit);
                if (overlong) response_body.append(100, 'x');
                sendAll(client, response_body);
                if (number == 1 && mode == Mode::HoldFirstPrefix) {
                    // 测试先确认有效前缀和持久化 meta，再触发取消；避免靠 sleep 猜取消窗口。
                    const auto hold_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
                    while (!stopped.load() && !release_prefix.load() && std::chrono::steady_clock::now() < hold_deadline)
                        std::this_thread::sleep_for(std::chrono::milliseconds(2));
                }
            }
            ::shutdown(client, SHUT_RDWR); ::close(client);
        }
    }
};

inline std::string payload(size_t length) {
    std::string bytes(length, 'a');
    for (size_t i = 0; i < length; ++i) bytes[i] = static_cast<char>('a' + i % 23);
    return bytes;
}

/** 相同工件分别走有/无 expected_size；有 checker 时使用真实全文 SHA1，不用大小替代内容。 */
inline download::LoaderDownload::Config configuration(const std::filesystem::path& root,
        const std::filesystem::path& target, const std::vector<std::string>& urls,
        const std::string& bytes, bool known, bool with_hash = true) {
    auto cfg = config("unknown total and range composition", root, target);
    auto& file = cfg.files[0]; file.urls = urls; file.max_connections = 1;
    file.check.expected_size = known ? static_cast<int64_t>(bytes.size()) : -1;
    file.check.expected_sha1.clear();
    if (with_hash) {
        download::Sha1 hash; hash.update(bytes.data(), bytes.size()); file.check.expected_sha1 = hash.finalizeHex();
    }
    return cfg;
}

/** 手机同值反例：第一次只保存577640B，下一次正确206应直接完成，不能丢前缀重下。 */
inline void partialThenResume(download::DownloadEngine& engine, const std::filesystem::path& root, bool known) {
    const auto bytes = payload(kObjectBytes);
    const auto target = root / (known ? "known-size-range-control" : "unknown-size-range-regression");
    write(target, "USER-KEEP");
    HttpFixture source(known ? "127.0.0.132" : "127.0.0.131", bytes, HttpFixture::Mode::TruncateFirst, target);
    auto task = engine.createTask(configuration(root, target, {source.url()}, bytes, known));
    source.observed_file.store(task->files()[0].get(), std::memory_order_release);
    assert(engine.startTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Finished && readFixtureFile(target) == bytes);
    assert(source.recordedOffsets() == std::vector<int64_t>({0, static_cast<int64_t>(kPrefixBytes)}));
    assert(source.gets == 2 && source.heads == (known ? 0 : 1) && source.premature_publications == 0);
    const auto totals = source.observedTotals(); assert(totals.size() == 2);
    if (!known) assert(totals[0] < 0 && totals[1] < 0);
    const auto progress = task->computeProgress();
    assert(task->files()[0]->fileSize() == static_cast<int64_t>(bytes.size()));
    assert(progress.bytes_total == static_cast<int64_t>(bytes.size()) && progress.bytes_done == progress.bytes_total);
    purgeSettled(engine, task->taskId());
    std::cout << "PASS " << (known ? "known-size control" : "unknown-size failed prefix")
              << " resumes once at 577640; final size/progress=3699647; wire GET=2" << std::endl;
}

/** 摘要失败的完整短正文同样不能成为下一来源的 total，健康大对象应从0独立复验成功。 */
inline void badDigestDoesNotPublishTotal(download::DownloadEngine& engine, const std::filesystem::path& root) {
    const auto bytes = payload(kObjectBytes); const auto target = root / "unknown-size-bad-digest";
    write(target, "USER-KEEP");
    HttpFixture bad("127.0.0.133", std::string(kPrefixBytes, '!'), HttpFixture::Mode::BadShortFull, target);
    HttpFixture good("127.0.0.134", bytes, HttpFixture::Mode::Good, target);
    auto task = engine.createTask(configuration(root, target, {bad.url(), good.url()}, bytes, false));
    bad.observed_file.store(task->files()[0].get(), std::memory_order_release);
    good.observed_file.store(task->files()[0].get(), std::memory_order_release);
    assert(engine.startTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Finished && readFixtureFile(target) == bytes);
    assert(bad.gets == 1 && good.gets == 1 && good.recordedOffsets() == std::vector<int64_t>({0}));
    assert(good.observedTotals().front() < 0 && good.premature_publications == 0);
    assert(task->files()[0]->sources()[0]->checksum_bad && !task->files()[0]->sources()[1]->checksum_bad);
    assert(task->files()[0]->fileSize() == static_cast<int64_t>(bytes.size()));
    purgeSettled(engine, task->taskId());
    std::cout << "PASS unknown-size digest failure never publishes the bad body's shorter total" << std::endl;
}

/** 同一取消任务真实落盘v1未知size meta后恢复；取消仅终止执行，不凭prefix确定对象大小。 */
inline void cancelAndResumeUnknown(download::DownloadEngine& engine, const std::filesystem::path& root) {
    const auto bytes = payload(kObjectBytes); const auto target = root / "unknown-size-cancel-resume";
    write(target, "USER-KEEP");
    HttpFixture source("127.0.0.135", bytes, HttpFixture::Mode::HoldFirstPrefix, target);
    auto cfg = configuration(root, target, {source.url()}, bytes, false);
    auto task = engine.createTask(cfg); const auto file = task->files()[0];
    source.observed_file.store(file.get(), std::memory_order_release);
    assert(engine.startTask(task->taskId()));
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (file->downloadedBytes() < static_cast<int64_t>(kPrefixBytes) && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    assert(file->downloadedBytes() == static_cast<int64_t>(kPrefixBytes));
    const auto snapshot = file->snapshotForMeta(); assert(snapshot.execution_active && snapshot.file_size < 0);
    download::DownloadMeta meta; meta.url_primary = source.url(); meta.url_sources = {source.url()};
    meta.file_size = snapshot.file_size; meta.check = cfg.files[0].check; meta.created_at = "2026-10-19T00:00:00Z";
    for (const auto& segment : snapshot.segments) meta.segments.push_back({segment.start, segment.end, segment.done});
    assert(file->persistResumeMeta(meta, snapshot.storage_generation));
    assert(engine.cancelTask(task->taskId())); source.release_prefix = true; waitForSettled(task);
    assert(task->state() == download::LoadState::Aborted && file->fileSize() < 0);
    assert(std::filesystem::file_size(target.string() + ".amcl.part") == kPrefixBytes);
    assert(readFixtureFile(target) == "USER-KEEP");
    const auto saved = download::readMetaFile(target.string() + ".download-meta");
    assert(saved && saved->file_size < 0 && saved->segments[0].done == static_cast<int64_t>(kPrefixBytes));
    assert(engine.resumeTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Finished && readFixtureFile(target) == bytes);
    assert(source.gets == 2 && source.recordedOffsets() == std::vector<int64_t>({0, static_cast<int64_t>(kPrefixBytes)}));
    assert(file->fileSize() == static_cast<int64_t>(bytes.size()) && source.premature_publications == 0);
    purgeSettled(engine, task->taskId());
    std::cout << "PASS cancelled unknown-size prefix stays unknown in v1 meta and resumes at exact saved offset" << std::endl;
}

/**
 * 旧版失败close留下的v1记录：假total保留，而open-ended段done可能已重置或缩小。
 * 真实reader仍须接受旧格式，但不能再信其总长；保留meta声明的有效前缀，分别以一次
 * 完整GET或正确206续传收齐，覆盖升级前已经存在的饱和、归零及部分恢复磁盘状态。
 */
inline void legacySaturatedPrefixStaysResumable(download::DownloadEngine& engine,
                                               const std::filesystem::path& root) {
    const auto bytes = payload(kObjectBytes);
    for (size_t saved : {kPrefixBytes, size_t(0), size_t(215553)}) {
    const auto target = root / ("legacy-v1-open-prefix-" + std::to_string(saved));
    write(target, "USER-KEEP");
    HttpFixture source("127.0.0.137", bytes, HttpFixture::Mode::Good, target);
    auto cfg = configuration(root, target, {source.url()}, bytes, false);
    // 旧版已把前缀当正数total预分配/保留，即使resetDone归零也不会截短该磁盘文件。
    // 保留其真实物理形状，确保start的meta/part大小核验通过，实际进入兼容降级分支。
    write(target.string() + ".amcl.part", bytes.substr(0, kPrefixBytes));
    download::DownloadMeta meta; meta.url_primary = source.url(); meta.url_sources = {source.url()};
    meta.file_size = kPrefixBytes; meta.check = cfg.files[0].check; meta.created_at = "2026-10-18T00:00:00Z";
    meta.segments.push_back({0, -1, static_cast<int64_t>(saved)});
    assert(download::writeMetaFile(target.string() + ".download-meta", meta));
    const auto old_meta = download::readMetaFile(target.string() + ".download-meta");
    assert(old_meta && old_meta->file_size == static_cast<int64_t>(kPrefixBytes));
    auto task = engine.createTask(cfg);
    source.observed_file.store(task->files()[0].get(), std::memory_order_release);
    assert(engine.startTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Finished && readFixtureFile(target) == bytes);
    assert(source.heads == 0 && source.gets == 1 && source.premature_publications == 0);
    assert(source.recordedOffsets() == std::vector<int64_t>({static_cast<int64_t>(saved)}));
    assert(source.observedTotals().front() < 0 && task->files()[0]->fileSize() == static_cast<int64_t>(bytes.size()));
    const auto progress = task->computeProgress();
    assert(progress.bytes_total == static_cast<int64_t>(bytes.size()) && progress.bytes_done == progress.bytes_total);
    purgeSettled(engine, task->taskId());
    }
    std::cout << "PASS legacy v1 saturated, reset-zero and partial open-ended prefixes keep bytes without trusting unproven total" << std::endl;
}

/** 无 checker 的未知下载也不能以一个未到对象末尾的合法206窗口宣告完成。 */
inline void shortRangeCannotFinishUnknown(download::DownloadEngine& engine, const std::filesystem::path& root) {
    const auto bytes = payload(kObjectBytes); const auto target = root / "unknown-size-short-range";
    write(target, "USER-KEEP");
    HttpFixture source("127.0.0.136", bytes, HttpFixture::Mode::ShortRangeSecond, target);
    auto task = engine.createTask(configuration(root, target, {source.url()}, bytes, false, false));
    source.observed_file.store(task->files()[0].get(), std::memory_order_release);
    assert(engine.startTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Finished && readFixtureFile(target) == bytes);
    assert(source.gets == 3 && source.recordedOffsets() == std::vector<int64_t>({0, static_cast<int64_t>(kPrefixBytes), 0}));
    assert(source.premature_publications == 0 && task->files()[0]->fileSize() == static_cast<int64_t>(bytes.size()));
    purgeSettled(engine, task->taskId());
    std::cout << "PASS unknown-size open-ended Range must reach declared EOF even without a checker" << std::endl;
}

/** 已验证的完整Range声明不能让CL短读蒙混过关；保存的正确前缀可继续下一次Range。 */
inline void shortBodyCannotFinishUnknown(download::DownloadEngine& engine, const std::filesystem::path& root) {
    const auto bytes = payload(kObjectBytes); const auto target = root / "unknown-size-short-body";
    write(target, "USER-KEEP");
    HttpFixture source("127.0.0.138", bytes, HttpFixture::Mode::ShortBodySecond, target);
    auto task = engine.createTask(configuration(root, target, {source.url()}, bytes, false, false));
    source.observed_file.store(task->files()[0].get(), std::memory_order_release);
    assert(engine.startTask(task->taskId())); waitForSettled(task);
    assert(task->state() == download::LoadState::Finished && readFixtureFile(target) == bytes);
    // 该响应声明完整206却通过更短CL提前EOF，沿用生产run()已有SizeMismatch处理
    // 将段归零再取完整对象；不能假定它会保留这次不一致窗口中的1024B。
    assert(source.gets == 3 && source.recordedOffsets() == std::vector<int64_t>(
        {0, static_cast<int64_t>(kPrefixBytes), 0}));
    assert(source.premature_publications == 0 && task->files()[0]->fileSize() == static_cast<int64_t>(bytes.size()));
    purgeSettled(engine, task->taskId());
    std::cout << "PASS unknown-size 206 with short body cannot finish despite a syntactically complete Range" << std::endl;
}

/**
 * Engine当前把unknown路由worker；仍直接验证生产Multi公共入口的相同完成合同，避免
 * 只改未覆盖的另一执行器。使用普通Loader/NetFile公共生命周期、真实v1恢复和CURLM，
 * 无私有字段/test hook，不宣称这是Engine自动路由；此处没有注册Engine任务可purge。
 */
inline void multiRejectsIncompleteOpenRange(const std::filesystem::path& root, HttpFixture::Mode mode) {
    const auto bytes = payload(kObjectBytes);
    const bool short_body = mode == HttpFixture::Mode::ShortBodySecond;
    const bool long_body = mode == HttpFixture::Mode::LongBodySecond;
    const bool unsolicited = mode == HttpFixture::Mode::UnsolicitedPartial;
    const auto target = root / ("multi-unknown-malformed-" + std::to_string(static_cast<int>(mode)));
    write(target, "USER-KEEP");
    HttpFixture source(short_body ? "127.0.0.140" : long_body ? "127.0.0.143" : unsolicited ? "127.0.0.144" : "127.0.0.139",
                       bytes, mode, target, 1);
    auto cfg = configuration(root, target, {source.url()}, bytes, false, false);
    const size_t prefix = unsolicited ? 0 : kPrefixBytes;
    write(target.string() + ".amcl.part", bytes.substr(0, prefix));
    download::DownloadMeta meta; meta.url_primary = source.url(); meta.url_sources = {source.url()};
    meta.file_size = -2; meta.check = cfg.files[0].check; meta.created_at = "2026-10-19T00:00:00Z";
    meta.segments.push_back({0, -1, static_cast<int64_t>(prefix)});
    assert(download::writeMetaFile(target.string() + ".download-meta", meta));
    auto task = std::make_shared<download::LoaderDownload>(cfg); task->onStart();
    const auto file = task->files()[0]; source.observed_file.store(file.get(), std::memory_order_release);
    assert(!file->start());
    download::MultiDownloader multi(download::MultiDownloader::Config{}); multi.start();
    assert(multi.enqueue(file->threadsToLaunch()));
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < deadline &&
           (task->state() == download::LoadState::Loading || !task->isExecutionSettled()))
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    assert(task->state() == download::LoadState::Finished && task->isExecutionSettled()); multi.shutdown();
    assert(readFixtureFile(target) == bytes && source.premature_publications == 0);
    assert(source.gets == 2 && source.recordedOffsets() == std::vector<int64_t>({static_cast<int64_t>(prefix), 0}));
    assert(file->fileSize() == static_cast<int64_t>(bytes.size()));
    std::cout << "PASS production CURLM rejects unknown-size " << (short_body ? "short body" : long_body ? "overlong body" : unsolicited ? "unsolicited 206" : "short window")
              << " before publishing; explicit executor coverage" << std::endl;
}

/** 无checker也须拒绝超出声明EOF的206，以及full GET收到的意外部分对象。 */
inline void malformed206CannotFinishUnknown(download::DownloadEngine& engine, const std::filesystem::path& root) {
    for (bool overlong : {true, false}) {
        const auto bytes = payload(kObjectBytes);
        const auto target = root / (overlong ? "unknown-overlong-body" : "unknown-unsolicited-206");
        write(target, "USER-KEEP");
        HttpFixture source(overlong ? "127.0.0.141" : "127.0.0.142", bytes,
            overlong ? HttpFixture::Mode::LongBodySecond : HttpFixture::Mode::UnsolicitedPartial, target);
        auto task = engine.createTask(configuration(root, target, {source.url()}, bytes, false, false));
        source.observed_file.store(task->files()[0].get(), std::memory_order_release);
        assert(engine.startTask(task->taskId())); waitForSettled(task);
        assert(task->state() == download::LoadState::Finished && readFixtureFile(target) == bytes);
        assert(source.premature_publications == 0 && task->files()[0]->fileSize() == static_cast<int64_t>(bytes.size()));
        assert(source.recordedOffsets() == (overlong ? std::vector<int64_t>({0, static_cast<int64_t>(kPrefixBytes), 0}) :
                                                              std::vector<int64_t>({0, 0})));
        purgeSettled(engine, task->taskId());
    }
    std::cout << "PASS unknown-size overlong and unsolicited 206 cannot publish without checker" << std::endl;
}

} // namespace unknown_size_cases

inline void runUnknownSizeCases(download::DownloadEngine& engine, const std::filesystem::path& root) {
    unknown_size_cases::partialThenResume(engine, root, false);
    unknown_size_cases::partialThenResume(engine, root, true);
    unknown_size_cases::badDigestDoesNotPublishTotal(engine, root);
    unknown_size_cases::cancelAndResumeUnknown(engine, root);
    unknown_size_cases::legacySaturatedPrefixStaysResumable(engine, root);
    unknown_size_cases::shortRangeCannotFinishUnknown(engine, root);
    unknown_size_cases::shortBodyCannotFinishUnknown(engine, root);
    unknown_size_cases::malformed206CannotFinishUnknown(engine, root);
    unknown_size_cases::multiRejectsIncompleteOpenRange(root, unknown_size_cases::HttpFixture::Mode::ShortRangeSecond);
    unknown_size_cases::multiRejectsIncompleteOpenRange(root, unknown_size_cases::HttpFixture::Mode::ShortBodySecond);
    unknown_size_cases::multiRejectsIncompleteOpenRange(root, unknown_size_cases::HttpFixture::Mode::LongBodySecond);
    unknown_size_cases::multiRejectsIncompleteOpenRange(root, unknown_size_cases::HttpFixture::Mode::UnsolicitedPartial);
}
