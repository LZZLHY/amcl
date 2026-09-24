/**
 * multi_downloader.cpp — v4.5 curl_multi 事件循环下载器
 *
 * 核心事件循环：
 *   while (running || has_pending || has_active) {
 *       feedTransfers();         // pending queue → curl_multi_add_handle
 *       curl_multi_poll(100ms);  // 等待 socket 事件
 *       curl_multi_perform();    // 推进所有传输
 *       drainCompleted();        // 处理已完成的传输
 *   }
 *
 * HTTP/2 多路复用：curl_multi 自动对同一 host 复用 TCP 连接。
 * 64 个并发请求 × 同一 BMCLAPI host → 1-2 条 TCP 连接 × 64 个 HTTP/2 stream。
 * 对比原方案：64 个独立 curl_easy → 64 条 TCP + 64 次 TLS 握手。
 */
#include "multi_downloader.h"

#include <algorithm>
#include <curl/curl.h>
#include <fcntl.h>
#include <hilog/log.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <cstdio>
#include <cstring>
#include <limits>

#include "config.h"
#include "engine.h"
#include "http_range.h"
#include "net_file.h"
#include "../utils/amcl_log.h"

#undef LOG_TAG
#define LOG_TAG "DL_MULTI"

namespace download {

namespace {

/**
 * 探测"下一个可用 fd 号" —— 直接等于进程当前 fd 水位。失败返回 -1。
 *
 * 之所以需要它：随包 libcurl 的 Curl_poll 走 select() 分支（HAVE_POLL_FINE 未定义），
 * fd >= FD_SETSIZE(1024) 就整体失败。诊断时唯一需要的数字就是这个水位。
 */
int probeNextFreeFd() {
    int fd = ::open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ::close(fd);
    return fd;
}

/** CURLM_UNRECOVERABLE_POLL 只告警一次（它一旦发生就是每轮都发生，刷屏没有信息量）。 */
void logUnrecoverablePollOnce() {
    static std::atomic<bool> warned{false};
    bool expected = false;
    if (!warned.compare_exchange_strong(expected, true)) return;
    AMCL_LOG_E(LOG_TAG,
        "curl_multi_poll UNRECOVERABLE (select/poll), next_free_fd=%{public}d — "
        "shipped libcurl has no poll(); any fd >= FD_SETSIZE(1024) breaks every "
        "transfer AND every curl_easy_perform permanently until the process restarts",
        probeNextFreeFd());
}

ErrorKind mapCurlCode(CURLcode rc) {
    switch (rc) {
        case CURLE_OPERATION_TIMEDOUT:
            return ErrorKind::Timeout;
        case CURLE_COULDNT_CONNECT:
        case CURLE_COULDNT_RESOLVE_HOST:
        case CURLE_COULDNT_RESOLVE_PROXY:
            return ErrorKind::ConnectionError;
        case CURLE_SSL_CONNECT_ERROR:
        case CURLE_SSL_CERTPROBLEM:
        case CURLE_SSL_CIPHER:
        case CURLE_PEER_FAILED_VERIFICATION:
            return ErrorKind::SslError;
        case CURLE_HTTP_RETURNED_ERROR:
            return ErrorKind::ProtocolError;
        case CURLE_ABORTED_BY_CALLBACK:
            return ErrorKind::AbortedByUser;
        default:
            return ErrorKind::ConnectionError;
    }
}

/**
 * 是否是需要频率节流的源。
 *
 * 完全照抄 PCL2 的判据：`NewThread.Source.Url.Contains("bmclapi")`
 * （ModNet.vb:1822 / 1842）。PCL2 只对 bmclapi 做 Sleep(100)，其它主机不节流，
 * 这里保持一致 —— 不自作聪明扩大范围。
 */
bool isThrottledSourceUrl(const std::string& url) {
    return url.find("bmclapi") != std::string::npos;
}

std::string extractHost(const std::string& url) {
    size_t hs = url.find("://");
    if (hs == std::string::npos) return {};
    hs += 3;
    size_t he = url.find('/', hs);
    size_t pe = url.find(':', hs);
    if (pe != std::string::npos && (he == std::string::npos || pe < he)) he = pe;
    return url.substr(hs, he == std::string::npos ? std::string::npos : he - hs);
}

/** 大小写无关比较前缀 */
bool startsWithIgnoreCase(const std::string& s, const char* prefix) {
    size_t n = std::strlen(prefix);
    if (s.size() < n) return false;
    for (size_t i = 0; i < n; ++i) {
        char a = s[i];
        char b = prefix[i];
        if (a >= 'A' && a <= 'Z') a = static_cast<char>(a - 'A' + 'a');
        if (b >= 'A' && b <= 'Z') b = static_cast<char>(b - 'A' + 'a');
        if (a != b) return false;
    }
    return true;
}

int64_t steadyNowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

int64_t retryDelayWithJitter(int64_t retry_after_ms, int attempt, int source_id) {
    constexpr int64_t kMaxDelayMs = 5 * 60 * 1000LL;
    int shift = std::min(attempt > 0 ? attempt - 1 : 0, 5);
    int64_t base_ms = retry_after_ms > 0 ? retry_after_ms : 500LL * (1LL << shift);
    base_ms = std::min(base_ms, kMaxDelayMs - 1000);
    int64_t window = std::min<int64_t>(1000, std::max<int64_t>(100, base_ms / 5));
    int64_t jitter = 50 + ((attempt * 1103515245LL + source_id * 97LL) % window);
    return std::min(kMaxDelayMs, base_ms + jitter);
}

} // namespace

// M-2 修复：header callback 拦截 302 → bad host
size_t MultiDownloader::onHeader(char* buffer, size_t size, size_t nitems, void* userdata) {
    TransferCtx* ctx = static_cast<TransferCtx*>(userdata);
    if (!ctx || (size != 0 && nitems > SIZE_MAX / size)) return 0;
    size_t total = size * nitems;
    std::string line(buffer, total);

    if (startsWithIgnoreCase(line, "Content-Range:")) {
        ParsedContentRange parsed;
        ctx->content_range_seen = true;
        ctx->content_range_valid = parseContentRangeHeader(buffer, total, parsed);
        if (ctx->content_range_valid) {
            ctx->content_range_start = parsed.start;
            ctx->content_range_end = parsed.end;
            ctx->content_range_total = parsed.total;
        }
        return total;
    }

    if (startsWithIgnoreCase(line, "Retry-After:")) {
        std::string val = line.substr(12);
        size_t a = val.find_first_not_of(" \t");
        size_t b = val.find_last_not_of(" \t\r\n");
        if (a != std::string::npos && b >= a) {
            val = val.substr(a, b - a + 1);
            char* endp = nullptr;
            errno = 0;
            long long sec = std::strtoll(val.c_str(), &endp, 10);
            if (errno == 0 && endp && *endp == '\0' && sec >= 0) {
                ctx->retry_after_ms = sec > 86400 ? 86400000 : sec * 1000;
            } else {
                time_t when = curl_getdate(val.c_str(), nullptr);
                time_t now = std::time(nullptr);
                if (when > now) ctx->retry_after_ms =
                    std::min<int64_t>(86400000, static_cast<int64_t>(when - now) * 1000);
            }
        }
        return total;
    }

    if (!startsWithIgnoreCase(line, "Location:")) return total;
    std::string val = line.substr(9);
    size_t a = val.find_first_not_of(" \t");
    if (a == std::string::npos) return total;
    size_t b = val.find_last_not_of(" \t\r\n");
    if (b < a) return total;
    std::string target = val.substr(a, b - a + 1);
    std::string host = extractHost(target);
    if (!host.empty() && DownloadEngine::instance().isBadHost(host)) {
        ctx->abort_reason_bad_host = host;
        AMCL_LOG_W(LOG_TAG, "multi onHeader: Location->bad host %{public}s, aborting transfer",
                    host.c_str());
        return 0;
    }
    return total;
}

// ============================================================================
// 构造 / 析构
// ============================================================================

MultiDownloader::MultiDownloader() : cfg_() {}

MultiDownloader::MultiDownloader(const Config& cfg) : cfg_(cfg) {}

MultiDownloader::~MultiDownloader() {
    shutdown();
}

// ============================================================================
// 生命周期
// ============================================================================

void MultiDownloader::start() {
    if (running_.load(std::memory_order_acquire)) return;

    multi_ = curl_multi_init();
    if (!multi_) {
        AMCL_LOG_E(LOG_TAG, "curl_multi_init failed");
        return;
    }

    // v6.5：经实测 HTTP/2 多路复用在本设备上因 per-stream 流控窗口（64KB）固定不增长
    // 反而限速，已弃用 —— 模组/资源改走 HTTP/1.1 单连接（见 startTransfer）。这里关闭
    // 多路复用，让自动协商到 h2 的普通文件也不被小窗口钳速；每 transfer 独立 1.1 连接，
    // TCP 接收窗口由内核自适应放大到 BDP，单连接即可吃满带宽。
    curl_multi_setopt(multi_, CURLMOPT_PIPELINING, CURLPIPE_NOTHING);

    // libcurl 层硬上限与调度层渐进上限双保险：同一 host 永远不会瞬间打满 64 连接。
    // ⚠️ 2026-08-04：这里曾是 assets 慢的**第二道**闸门，而且比调度层那道更硬。
    //
    //   原来 `CURLMOPT_MAX_HOST_CONNECTIONS = max_host_concurrent(8)`：即使调度层放行，
    //   libcurl 自己也只会给同一主机开 8 条连接，其余 easy handle 在 multi 内部排队。
    //   4750 个 asset 全在 bmclapi2 一个主机上 → 有效并发 8 → 实测 4~5 文件/秒。
    //
    //   PCL2 没有任何 per-host 连接上限（ModNet.vb 的 ThreadStarter 只查全局
    //   `NetTaskThreadCount >= NetTaskThreadLimit`）。现在 max_host_concurrent 已等于
    //   全局上限，这里跟着变成"不额外限制 host"，频率节流交给
    //   `throttled_host_start_interval_ms`（PCL2 的 bmclapi Sleep(100) 等价物）。
    int hard_host_limit = std::max(1, std::min(cfg_.max_host_concurrent, cfg_.max_concurrent));
    curl_multi_setopt(multi_, CURLMOPT_MAX_HOST_CONNECTIONS,
                      static_cast<long>(hard_host_limit));

    // 连接池上限：覆盖总并发即可，host 由上面的硬限制约束。
    curl_multi_setopt(multi_, CURLMOPT_MAXCONNECTS,
                      static_cast<long>(std::max(cfg_.max_concurrent, hard_host_limit)));

    // 最大并发传输数
    curl_multi_setopt(multi_, CURLMOPT_MAX_TOTAL_CONNECTIONS,
                      static_cast<long>(cfg_.max_concurrent));

    running_.store(true, std::memory_order_release);
    loop_thread_ = std::thread([this] { eventLoop(); });

    AMCL_LOG_I(LOG_TAG,
        "MultiDownloader started: max_concurrent=%{public}d host_limit=%{public}d "
        "throttled_start_interval=%{public}dms",
        cfg_.max_concurrent, hard_host_limit, cfg_.throttled_host_start_interval_ms);
}

void MultiDownloader::shutdown() {
    if (!running_.exchange(false, std::memory_order_acq_rel)) return;

    // 唤醒事件循环线程
    cv_.notify_all();

    if (loop_thread_.joinable()) {
        loop_thread_.join();
    }

    // 防御性清理：正常 eventLoop 会在退出前收敛为空；若 curl multi 异常留下
    // transfer，先移除 callback userdata，再发布 settled。
    for (auto& kv : transfers_) {
        auto* ctx = kv.second.get();
        NetThreadPtr thread = ctx->thread;
        if (ctx->fd_acquired) {
            thread->task()->releaseFd();
            ctx->fd_acquired = false;
        }
        thread->setState(NetState::Aborted);
        curl_multi_remove_handle(multi_, kv.first);
        curl_easy_cleanup(kv.first);
        thread->markExecutionSettled();
    }
    transfers_.clear();
    {
        std::lock_guard<std::mutex> lk(mu_);
        pending_by_task_.clear();
        pending_task_order_.clear();
        pending_count_ = 0;
    }

    // 清理对象池
    for (auto* e : easy_pool_) {
        curl_easy_cleanup(e);
    }
    easy_pool_.clear();

    if (multi_) {
        curl_multi_cleanup(multi_);
        multi_ = nullptr;
    }

    AMCL_LOG_I(LOG_TAG, "MultiDownloader shutdown");
}

void MultiDownloader::enqueue(std::vector<NetThreadPtr> threads) {
    if (threads.empty()) return;
    {
        std::lock_guard<std::mutex> lk(mu_);
        for (auto& thread : threads) {
            uint64_t task_id = thread && thread->task() ? thread->task()->taskId() : 0;
            auto& queue = pending_by_task_[task_id];
            if (queue.empty()) pending_task_order_.push_back(task_id);
            queue.push_back(std::move(thread));
            ++pending_count_;
        }
    }
    cv_.notify_one();
}

// ============================================================================
// Easy handle 对象池
// ============================================================================

CURL* MultiDownloader::acquireEasy() {
    if (!easy_pool_.empty()) {
        CURL* e = easy_pool_.back();
        easy_pool_.pop_back();
        curl_easy_reset(e);  // 重置选项但保留连接缓存
        return e;
    }
    return curl_easy_init();
}

void MultiDownloader::releaseEasy(CURL* easy) {
    if (easy) {
        // v4.6: 不在此处 reset，acquireEasy() 取出时会 reset。
        // 避免双重 reset 浪费 CPU（curl_easy_reset 保留连接缓存，不影响连接复用）。
        easy_pool_.push_back(easy);
    }
}

int64_t MultiDownloader::pendingWaitMs() const {
    int64_t now = steadyNowMs();
    int64_t earliest = std::numeric_limits<int64_t>::max();
    for (const auto& item : pending_by_task_) {
        for (const auto& thread : item.second) {
            if (!thread) return 0;
            int64_t ready = thread->retryNotBeforeMs();
            if (ready <= now) return 0;
            earliest = std::min(earliest, ready);
        }
    }
    return earliest == std::numeric_limits<int64_t>::max()
        ? 200 : std::max<int64_t>(1, earliest - now);
}

// ============================================================================
// 事件循环
// ============================================================================

void MultiDownloader::eventLoop() {
    AMCL_LOG_I(LOG_TAG, "MultiDownloader eventLoop started");

    while (true) {
        // 检查退出条件
        bool has_pending;
        {
            std::lock_guard<std::mutex> lk(mu_);
            has_pending = pending_count_ > 0;
        }
        bool has_active = !transfers_.empty();

        if (!running_.load(std::memory_order_acquire) && !has_pending && !has_active) {
            break;
        }

        // 如果没有活跃传输也没有待处理的，等待新任务入队
        if (!has_pending && !has_active) {
            std::unique_lock<std::mutex> lk(mu_);
            cv_.wait_for(lk, std::chrono::milliseconds(200), [this] {
                return !running_.load(std::memory_order_acquire) || pending_count_ > 0;
            });
            continue;
        }

        // 1. 从 pending 队列取 NetThread，加入 multi
        feedTransfers();
        if (transfers_.empty()) {
            std::unique_lock<std::mutex> lk(mu_);
            // 所有 pending 均有 not-before 时直接睡到最早 deadline；新 enqueue/shutdown
            // 会通过 cv_ 提前唤醒。避免固定 50ms 轮询形成空转。
            int64_t wait_ms = pendingWaitMs();
            cv_.wait_for(lk, std::chrono::milliseconds(wait_ms), [this] {
                return !running_.load(std::memory_order_acquire) || pending_count_ == 0 ||
                       pendingWaitMs() == 0;
            });
            continue;
        }

        // 2. 等待 socket 事件（最多 50ms — 小文件下载延迟敏感，不要等太久）
        if (!transfers_.empty()) {
            int numfds = 0;
            CURLMcode mc = curl_multi_poll(multi_, nullptr, 0, 50, &numfds);
            if (mc == CURLM_UNRECOVERABLE_POLL) {
                // 2026-08-04：这不是网络问题，是 fd 号越过 FD_SETSIZE。
                //
                // 随包 libcurl 8.10.1 交叉编译时 HAVE_POLL_FINE 未定义，Curl_poll 编进了
                // select() 分支，curl 自己的注释就写着 "-1 = system call error or
                // fd >= FD_SETSIZE"。一旦踩到，本事件循环和所有 curl_easy_perform
                // （元数据请求）都会**永久**失败且不自愈，用户表现是"什么都下不了、
                // 重试无限次都秒失败"。把 fd 水位直接打出来，避免再花几小时定位。
                //
                // next_free_fd 就是进程当前 fd 水位：>= 1024 即已中招。
                logUnrecoverablePollOnce();
            } else if (mc != CURLM_OK) {
                AMCL_LOG_W(LOG_TAG, "curl_multi_poll error: %{public}s",
                            curl_multi_strerror(mc));
            }
        }

        // 3. 推进所有传输
        int still_running = 0;
        CURLMcode mc = curl_multi_perform(multi_, &still_running);
        if (mc != CURLM_OK) {
            AMCL_LOG_W(LOG_TAG, "curl_multi_perform error: %{public}s",
                        curl_multi_strerror(mc));
        }

        active_count_.store(still_running, std::memory_order_relaxed);

        // 4. 处理已完成的传输
        drainCompleted();
    }

    AMCL_LOG_I(LOG_TAG, "MultiDownloader eventLoop exited: ok=%{public}d fail=%{public}d retry=%{public}d",
                stats_success_.load(), stats_fail_.load(), stats_retry_.load());
}

// ============================================================================
// feedTransfers — 从 pending 队列取 NetThread，配置 easy handle，加入 multi
// ============================================================================

void MultiDownloader::feedTransfers() {
    // 每轮只检查进入本函数时已有的 pending 项一次。被 cooldown/host limit 重新入队的项
    // 留到下一轮，既不会热循环，也不会因队首同 host 被限而阻塞后面的其他 host。
    size_t scan_budget = 0;
    {
        std::lock_guard<std::mutex> lk(mu_);
        scan_budget = pending_count_;
    }
    int gated_scan_streak = 0;

    while (scan_budget-- > 0 &&
           static_cast<int>(transfers_.size()) < cfg_.max_concurrent) {
        NetThreadPtr thread;
        {
            std::lock_guard<std::mutex> lk(mu_);
            if (pending_task_order_.empty()) break;
            uint64_t task_id = pending_task_order_.front();
            pending_task_order_.pop_front();
            auto queue_it = pending_by_task_.find(task_id);
            if (queue_it == pending_by_task_.end() || queue_it->second.empty()) continue;
            thread = std::move(queue_it->second.front());
            queue_it->second.pop_front();
            --pending_count_;
            if (queue_it->second.empty()) pending_by_task_.erase(queue_it);
            else pending_task_order_.push_back(task_id);
        }

        if (!thread) continue;

        // shutdown/abort 必须先于 cooldown。否则 running=false 会让 wait predicate
        // 持续立即唤醒，而 pending 仍被 not-before 推回，形成最长数分钟热自旋。
        if (!running_.load(std::memory_order_acquire) || thread->isAborted()) {
            thread->setState(NetState::Aborted);
            thread->markExecutionSettled();
            continue;
        }

        if (thread->retryNotBeforeMs() > steadyNowMs()) {
            std::lock_guard<std::mutex> lk(mu_);
            uint64_t task_id = thread && thread->task() ? thread->task()->taskId() : 0;
            auto& queue = pending_by_task_[task_id];
            if (queue.empty()) pending_task_order_.push_back(task_id);
            queue.push_back(std::move(thread));
            ++pending_count_;
            continue;
        }

        // 断点续传短路：已经下载完的段
        if (thread->end() >= 0 && thread->done() >= thread->length()) {
            thread->setState(NetState::Finished);
            thread->markExecutionSettled();
            continue;
        }

        // false 既可能是终结，也可能是 cooldown/host 限流后重新入队；scan_budget
        // 保证本轮不会再次取到它，同时继续给其他 host 启动机会。
        NetThreadPtr execution = thread;
        throttle_deferred_ = false;
        bool started = startTransfer(std::move(thread));
        if (!started && execution) {
            NetState state = execution->state();
            if (state == NetState::Finished || state == NetState::Failed ||
                state == NetState::Aborted) {
                execution->markExecutionSettled();
            }
        }

        // 频率节流的早退（2026-08-04）：受限主机每轮最多放行一条，之后本轮剩余候选全会
        // 被同一个时间闸门挡回。assets 有 4700+ 个候选且**全在同一主机**，若继续扫完整队列，
        // 每 50ms 就要白白 pop/push 四千多次。这里连续被节流挡回 kMaxGatedScan 次就结束本轮；
        // 上限取 128 而不是 1，是为了保留原有的公平性 —— 队列里若混着别的主机的候选，
        // 128 的窗口足够把它挑出来，不会被前面一堆 bmclapi 候选饿死。
        constexpr int kMaxGatedScan = 128;
        if (throttle_deferred_) {
            if (++gated_scan_streak >= kMaxGatedScan) break;
        } else {
            gated_scan_streak = 0;
        }
    }
}

// ============================================================================
// startTransfer — 为一个 NetThread 配置 easy handle 并加入 multi
// ============================================================================

bool MultiDownloader::startTransfer(NetThreadPtr thread) {
    NetFile* file = thread->task();

    // 活动账本：本函数只服务这一个传输，开头设一次即可。事件循环是单线程处理多个
    // 并发传输，所以必须按传输设、不能按线程设一次（同 drainCompleted 的理由）。
    // 覆盖的是「源命中坏主机黑名单而换源」「curl_multi_add_handle 失败」这类
    // 起步阶段的失败原因 —— 2026-08-01 实测发现这段此前丢归属。
    AmclActivityScope actScope(amclLedgerActivityOfTask(file ? file->taskId() : 0));

    // ⚠️ 2026-08-04：**acquireFd 已挪到本函数末尾**（所有准入闸门之后）。
    //
    //   原来它在函数最开头，于是每一个被闸门挡回的候选都要白付一整套文件系统操作：
    //     acquireFd  → openTrustedParentAt(dup + 逐级 openat) + openat + fstat + ftruncate
    //     releaseFd  → ftruncate + **fsync** + close
    //   而 feedTransfers 每轮会扫描全部 pending 候选。assets 有 4750 个文件、其中
    //   4665 个走 multi 路径，稳态下 4600+ 个候选每轮都被 host 并发闸门挡回一次
    //   ⇒ **每轮几千次 fsync**。事件循环因此几乎没有时间去跑 curl_multi_perform：
    //   真机实测 `multi stats ... active=3` / `active=6`（并发水位只有 3~6，而上限是 64），
    //   assets 完成速率只有 3.4 文件/秒 —— 而按 ttfb 388ms + 平均 95KB/文件算，
    //   哪怕只有 8 并发也该有 ~18 文件/秒。这是 assets 慢的**首要**原因。
    //
    //   PCL2 同样是"被准入之后才碰文件"：它在 NetThread 内部才建立文件流
    //   （ModNet.vb 的下载线程里），ThreadStarter 只做计数与频率判断，不碰磁盘。
    //
    //   所有闸门分支因此都不再需要 releaseFd —— 那时 fd 根本还没开。

    // 选择最佳源；若只是全部处于 cooldown，按最早 ready deadline 延迟入队，不能失败或热循环。
    bool needs_range = thread->requiresRangeSupport();
    NetSourcePtr src = file->pickBestSource(needs_range);
    if (!src) {
        int64_t ready = file->nextSourceReadyMs(needs_range);
        int64_t now = steadyNowMs();
        if (ready > now) {
            int64_t deadline = thread->retryDeadlineMs();
            if (deadline > 0 && ready > deadline) {
                auto ex = makeException(ErrorKind::ConnectionError,
                                        "source cooldown exceeds retry deadline");
                thread->setError(ex);
                thread->setState(NetState::Failed);
                file->reportThreadFinished(thread.get());
                return false;
            }
            thread->deferUntilMs(ready);
            std::lock_guard<std::mutex> lk(mu_);
            uint64_t task_id = thread && thread->task() ? thread->task()->taskId() : 0;
            auto& queue = pending_by_task_[task_id];
            if (queue.empty()) pending_task_order_.push_back(task_id);
            queue.push_back(std::move(thread));
            ++pending_count_;
            return false;
        }
        auto ex = makeException(ErrorKind::ConnectionError,
                                "no available sources (all failed)");
        thread->setError(ex);
        thread->setState(NetState::Failed);
        file->reportThreadFinished(thread.get());
        return false;
    }

    // ------------------------------------------------------------------
    // 每主机准入（2026-08-04 改为对齐 PCL2）
    //
    //   PCL2 的模型是「**频率**节流，不是**并发**节流」：
    //     ModNet.vb:1820-1842  ThreadStarter 只查全局 NetTaskThreadCount >= NetTaskThreadLimit，
    //                          没有任何 per-host 上限；
    //     ModNet.vb:1822/1842  `If NewThread.Source.Url.Contains("bmclapi") Then Thread.Sleep(100)`
    //                          —— 启动一条 bmclapi 线程后歇 100ms；两个 ThreadStarter 按
    //                          `File.Uuid Mod 2` 分片交错运行 ⇒ 有效约 50ms/条。
    //
    //   所以这里：
    //     · 并发上限已在 Config 里放到与全局上限相同（等价"无 per-host 上限"），
    //       仅保留 429 触发的自适应收缩作为 PCL2 没有的额外保险；
    //     · 新增受限主机（bmclapi）的最小启动间隔，把节流从"并发"移到"频率"。
    //   实现差异见 Config::throttled_host_start_interval_ms 注释（不能在事件循环里 sleep）。
    // ------------------------------------------------------------------
    std::string source_host = extractHost(src->url);
    if (!source_host.empty()) {
        int max_limit = std::max(1, std::min(cfg_.max_host_concurrent, cfg_.max_concurrent));
        int initial_limit = std::max(1, std::min(cfg_.initial_host_concurrent, max_limit));
        int& limit = host_limit_[source_host];
        if (limit <= 0) limit = initial_limit;
        if (host_active_[source_host] >= limit) {
            thread->deferUntilMs(steadyNowMs() + 25);
            std::lock_guard<std::mutex> lk(mu_);
            uint64_t task_id = thread && thread->task() ? thread->task()->taskId() : 0;
            auto& queue = pending_by_task_[task_id];
            if (queue.empty()) pending_task_order_.push_back(task_id);
            queue.push_back(std::move(thread));
            ++pending_count_;
            // 并发已满也算"准入被推迟"：稳态下（跑满 64）队列里剩余几千个候选每轮都会
            // 撞在这里，交给 feedTransfers 的早退计数收住，别每 50ms 空转几千次。
            throttle_deferred_ = true;
            return false;
        }

        // PCL2 的 bmclapi Sleep(100) 等价物：受限主机两条新连接之间至少隔 interval 毫秒。
        if (isThrottledSourceUrl(src->url) && cfg_.throttled_host_start_interval_ms > 0) {
            int64_t now = steadyNowMs();
            auto slot = host_next_start_ms_.find(source_host);
            if (slot != host_next_start_ms_.end() && now < slot->second) {
                thread->deferUntilMs(slot->second);
                std::lock_guard<std::mutex> lk(mu_);
                uint64_t task_id = thread && thread->task() ? thread->task()->taskId() : 0;
                auto& queue = pending_by_task_[task_id];
                if (queue.empty()) pending_task_order_.push_back(task_id);
                queue.push_back(std::move(thread));
                ++pending_count_;
                throttle_deferred_ = true;   // 供 feedTransfers 早退计数
                return false;
            }
            // 本轮放行 → 记账下次允许时刻。放在 curl_multi_add_handle 之前设也没关系：
            // 后面若因故失败返回，最坏只是多等一个 interval，不会漏放行。
            host_next_start_ms_[source_host] =
                now + cfg_.throttled_host_start_interval_ms;
        }
    }

    // M-2 修复：预检源 URL 本身的 host 是否被加入坏主机黑名单。
    // 命中说明此源已被其他 transfer 证实有问题，直接标记 source 失败、换源重试。
    // 不写文件、不动 fd，省 5s connect timeout。
    {
        std::string src_host = extractHost(src->url);
        if (!src_host.empty() && DownloadEngine::instance().isBadHost(src_host)) {
            AMCL_LOG_W(LOG_TAG, "multi: source host %{public}s on bad list, skip: %{public}s",
                        src_host.c_str(), src->url.c_str());
            auto ex = makeException(ErrorKind::ConnectionError,
                                    "source host on bad list: " + src_host);
            ex->url_context = src->url;
            src->recordFailure(ex, /*max_failures=*/1);
            // 把 thread 重新塞回 pending，让 feedTransfers 下次选别的源
            thread->resetDone();
            {
                std::lock_guard<std::mutex> lk(mu_);
                uint64_t task_id = thread && thread->task() ? thread->task()->taskId() : 0;
                auto& queue = pending_by_task_[task_id];
                if (queue.empty()) pending_task_order_.push_back(task_id);
                queue.push_back(std::move(thread));
                ++pending_count_;
            }
            return false;
        }
    }

    // ------------------------------------------------------------------
    // 到这里才算真正准入 —— 现在才开文件。见函数开头的说明。
    // ------------------------------------------------------------------
    int fd = file->acquireFd();
    if (fd < 0) {
        int e = file->fdError();
        ErrorKind kind = e == ENOSPC ? ErrorKind::DiskFullError :
#ifdef EDQUOT
                         e == EDQUOT ? ErrorKind::QuotaExceededError :
#endif
                         e == EIO ? ErrorKind::StorageIoError : ErrorKind::FileIoError;
        auto ex = makeException(kind, "acquireFd failed: " + file->stagingPath() +
                                      " errno=" + std::to_string(e));
        ex->native_code = e;
        thread->setError(ex);
        thread->setState(NetState::Failed);
        file->reportThreadFinished(thread.get());
        return false;
    }

    // 获取 easy handle
    CURL* easy = acquireEasy();
    if (!easy) {
        file->releaseFd();
        auto ex = makeException(ErrorKind::InternalError, "curl_easy_init returned NULL");
        thread->setError(ex);
        thread->setState(NetState::Failed);
        file->reportThreadFinished(thread.get());
        return false;
    }

    // 创建传输上下文
    auto ctx = std::make_unique<TransferCtx>();
    ctx->easy = easy;
    ctx->thread = thread;
    ctx->source = src;
    ctx->host = source_host;
    ctx->actual_url = src->url;
    ctx->fd_acquired = true;
    ctx->err_buf[0] = '\0';
    thread->clearWriteErrno();

    // --- 配置 easy handle ---

    curl_easy_setopt(easy, CURLOPT_URL, ctx->actual_url.c_str());
    // curl_multi 可以安全地自动 follow redirect，但我们需要过滤坏主机
    // 暂时用 FOLLOWLOCATION = 1 让 curl 自动处理 302，在完成时检查 effective URL
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(easy, CURLOPT_MAXREDIRS, 5L);
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);

    // v4.5b: 不强制 HTTP/2，让 curl 自动协商（大部分 CDN 镜像用 HTTP/1.1）
    // 每个 transfer 独立连接，不做多路复用——匹配 v2 ArkTS 的行为
    //
    // v6.5：实测发现 HTTP/2 在本设备上反而限速 —— 单 stream 稳定卡在 ~256KB/s，
    // 恰好等于 h2 默认流控窗口 64KB ÷ RTT ~250ms。HTTP/2 在 TCP 之上**再加一层**流控
    // 窗口，而 libcurl 的 per-stream h2 接收窗口不会随带宽自适应增长（固定 64KB），
    // 于是无论管道多宽，每条 stream 都被钳在 64KB/RTT。浏览器快是因为它用了很大的 h2
    // 窗口或 HTTP/3。我们没有可移植的 API 调大 curl 的 h2 窗口，故对模组/资源改用
    // HTTP/1.1：HTTP/1.1 没有应用层流控，内核会把 TCP 接收窗口自适应放大到 BDP
    // （可达数 MB），单连接即可吃满带宽 ramp 到数 MB/s。多个模组并发 = 多条 1.1 连接，
    // 各自独立 ramp、互不挤占同一个小窗口。连接仍由 multi handle 的连接缓存复用
    // （keep-alive），第二个文件复用热连接 = 跳过握手 + 直接吃已放大的 TCP 窗口。
    bool high_parallel = (file != nullptr && file->isHighParallel());
    if (high_parallel) {
        curl_easy_setopt(easy, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
        // 大缓冲 + 关闭 Nagle，让大窗口下的吞吐不被小包/算法拖累。
        curl_easy_setopt(easy, CURLOPT_BUFFERSIZE, 524288L);
        curl_easy_setopt(easy, CURLOPT_TCP_NODELAY, 1L);
    } else {
        curl_easy_setopt(easy, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_NONE);
    }

    // DNS + SSL session 共享
    CURLSH* sh = DownloadEngine::instance().curlShare();
    if (sh) {
        curl_easy_setopt(easy, CURLOPT_SHARE, sh);
    }

    // 超时策略（小文件优化）
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT, static_cast<long>(cfg_.connect_timeout_s));
    curl_easy_setopt(easy, CURLOPT_LOW_SPEED_LIMIT, static_cast<long>(cfg_.low_speed_limit));
    curl_easy_setopt(easy, CURLOPT_LOW_SPEED_TIME, static_cast<long>(cfg_.low_speed_time_s));
    curl_easy_setopt(easy, CURLOPT_TIMEOUT, static_cast<long>(cfg_.total_timeout_s));

    // v6.6：模组/资源（high_parallel）快速失败转移。
    //
    // 实测：iris+sodium 并发下载同一 CDN（cdn.modrinth.com）时，偶尔有一条连接被
    // 网络/边缘节点"饿"住，稳定在 ~28KB/s 长达 30s 才触发总超时——而它远高于
    // 1KB/s 的低速地板，旧逻辑的"无数据"看门狗和低速掐断都不触发。但同一文件的镜像源
    // （mod.mcimirror.top，有自己的缓存）往往 1s 就下完。因此对模组把低速地板抬到
    // ~96KB/s、持续 5s 即判失败 → retryTransfer 立刻换到镜像源，避免干等 30s。
    //
    // 不误杀正在 ramp 的连接：curl 的 LOW_SPEED 判定是"整个 LOW_SPEED_TIME 窗口内
    // 平均速度持续低于地板"才掐；慢启动末尾一旦 burst，平均值抬升即不触发。iris 这种
    // 几秒内就 ramp 完的连接全程不会落入 5s 持续 <96KB/s。
    if (high_parallel) {
        curl_easy_setopt(easy, CURLOPT_LOW_SPEED_LIMIT, 98304L);  // 96KB/s
        curl_easy_setopt(easy, CURLOPT_LOW_SPEED_TIME, 5L);
        curl_easy_setopt(easy, CURLOPT_TIMEOUT, 0L);  // 不用总超时，交给低速地板更精准地掐
    }

    curl_easy_setopt(easy, CURLOPT_FAILONERROR, 1L);

    // SSL 证书
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);
    std::string ca_path = getCaBundlePath();
    if (!ca_path.empty()) {
        curl_easy_setopt(easy, CURLOPT_CAINFO, ca_path.c_str());
    }

    // Range request: a non-zero offset is always a resume/secondary segment. Open-ended
    // segments must use "N-" as well; otherwise a full 200 response would be appended.
    const int64_t thread_done = thread->done();
    if (thread_done < 0 || thread->start() > INT64_MAX - thread_done) {
        file->releaseFd();
        ctx->fd_acquired = false;
        releaseEasy(easy);
        auto ex = makeException(ErrorKind::InvalidConfig, "download Range offset overflow");
        thread->setError(ex);
        thread->setState(NetState::Failed);
        file->reportThreadFinished(thread.get());
        return false;
    }
    ctx->requested_offset = thread->start() + thread_done;
    if (ctx->requested_offset > 0) {
        char range_buf[64];
        if (thread->end() >= thread->start()) {
            std::snprintf(range_buf, sizeof(range_buf), "%lld-%lld",
                          (long long)ctx->requested_offset, (long long)thread->end());
        } else {
            std::snprintf(range_buf, sizeof(range_buf), "%lld-",
                          (long long)ctx->requested_offset);
        }
        curl_easy_setopt(easy, CURLOPT_RANGE, range_buf);
        ctx->range_requested = true;
    }

    // 回调：直接使用 NetThread 的静态回调，userdata = NetThread*
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, &NetThread::onWrite);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, thread.get());
    curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, &NetThread::onProgress);
    curl_easy_setopt(easy, CURLOPT_XFERINFODATA, thread.get());

    // M-2 修复：header callback 拦截 302→bad host。userdata = TransferCtx*
    // ctx 已在 transfers_[easy] 持稳定指针，pointer 在 transfer 生命周期内有效。
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, &MultiDownloader::onHeader);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, ctx.get());

    curl_easy_setopt(easy, CURLOPT_USERAGENT, "amcl/0.1 (OHOS; libcurl/8.10.1)");
    // ⚠️ 2026-07-31：小文件路径（assets / libraries，数千个）同样按主机挑地址族。
    //   这条路径 FOLLOWLOCATION=1 由 curl 自动跟随，因此族选择只看**直连源主机**；
    //   重定向后的实际主机由 CURLINFO_EFFECTIVE_URL 在完成回调里记账（见 onComplete）。
    //   见 DownloadEngine::ipResolveFor 的实测依据。
    ctx->family_host = extractHost(ctx->actual_url);
    ctx->family_resolve = DownloadEngine::instance().ipResolveFor(ctx->family_host);
    curl_easy_setopt(easy, CURLOPT_IPRESOLVE, ctx->family_resolve);

    curl_easy_setopt(easy, CURLOPT_ERRORBUFFER, ctx->err_buf);

    // attempt 属于 NetThread 生命周期；每次 TransferCtx 真正加入 multi 前占用一次预算。
    // 普通 resetDone 不清零，因此跨 TransferCtx/文件级重入仍严格最多 30 次。
    if (!thread->tryBeginAttempt(30)) {
        file->releaseFd();
        ctx->fd_acquired = false;
        releaseEasy(easy);
        auto ex = makeException(ErrorKind::ConnectionError, "retry attempts exhausted");
        thread->setError(ex);
        thread->setState(NetState::Failed);
        file->reportThreadFinished(thread.get());
        return false;
    }

    // 状态转换：Connecting
    thread->setState(NetState::Connecting);

    // 加入 multi
    CURLMcode mc = curl_multi_add_handle(multi_, easy);
    if (mc != CURLM_OK) {
        AMCL_LOG_E(LOG_TAG, "curl_multi_add_handle failed: %{public}s",
                     curl_multi_strerror(mc));
        file->releaseFd();
        releaseEasy(easy);
        auto ex = makeException(ErrorKind::InternalError,
                                "curl_multi_add_handle: " + std::string(curl_multi_strerror(mc)));
        thread->setError(ex);
        thread->setState(NetState::Failed);
        file->reportThreadFinished(thread.get());
        return false;
    }

    if (!ctx->host.empty()) {
        ++host_active_[ctx->host];
    }
    transfers_[easy] = std::move(ctx);
    return true;
}

// ============================================================================
// drainCompleted — 处理所有已完成的传输
// ============================================================================

void MultiDownloader::drainCompleted() {
    CURLMsg* msg;
    int msgs_left;

    while ((msg = curl_multi_info_read(multi_, &msgs_left)) != nullptr) {
        if (msg->msg != CURLMSG_DONE) continue;

        CURL* easy = msg->easy_handle;
        CURLcode result = msg->data.result;

        auto it = transfers_.find(easy);
        if (it == transfers_.end()) {
            AMCL_LOG_E(LOG_TAG, "drainCompleted: unknown easy handle");
            continue;
        }

        TransferCtx* ctx = it->second.get();
        NetThreadPtr completed_thread = ctx->thread;
        std::string completed_host = ctx->host;
        {
            // 活动账本（L2-b）：事件循环是**单线程处理多个并发传输**，情形与 ArkTS 的
            // async 交错一样 —— 不能靠「线程启动时设一次」，必须按传输逐个设。
            // handleComplete 里的 DL_MULTI 日志（下载成败、URL、换源、重试）正是排查
            // 下载失败最有价值的部分，归属错了整个账本就失去意义。
            AmclActivityScope actScope(amclLedgerActivityOfTask(
                (ctx->thread && ctx->thread->task()) ? ctx->thread->task()->taskId() : 0));
            handleComplete(ctx, result);
        }

        if (!completed_host.empty()) {
            auto hit = host_active_.find(completed_host);
            if (hit != host_active_.end() && hit->second > 0) --hit->second;
        }

        // 必须先移除 easy handle 和 callback userdata，再发布 execution-settled；
        // reportThreadFinished 可能同步进入终态并允许 Engine purge。
        curl_multi_remove_handle(multi_, easy);
        releaseEasy(easy);
        transfers_.erase(it);

        if (completed_thread) {
            NetState state = completed_thread->state();
            if (state == NetState::Finished || state == NetState::Failed ||
                state == NetState::Aborted) {
                completed_thread->markExecutionSettled();
            }
        }
    }
}

// ============================================================================
// handleComplete — 处理单个传输完成
// ============================================================================

void MultiDownloader::handleComplete(TransferCtx* ctx, CURLcode result) {
    long http_code = 0;
    curl_easy_getinfo(ctx->easy, CURLINFO_RESPONSE_CODE, &http_code);
    curl_easy_getinfo(ctx->easy, CURLINFO_SIZE_DOWNLOAD_T, &ctx->downloaded_bytes);
    curl_easy_getinfo(ctx->easy, CURLINFO_TOTAL_TIME_T, &ctx->total_time_us);
    curl_easy_getinfo(ctx->easy, CURLINFO_CONNECT_TIME_T, &ctx->connect_time_us);

    NetThread* thr = ctx->thread.get();

    // 检查是否被重定向到了坏主机
    char* effective_url = nullptr;
    curl_easy_getinfo(ctx->easy, CURLINFO_EFFECTIVE_URL, &effective_url);

    // 地址族记账（见 DownloadEngine::noteFamilyOutcome）。这条路径 FOLLOWLOCATION=1，
    // CURLOPT_IPRESOLVE 对**所有跳**生效，因此把结果同时记到直连主机和最终主机上。
    {
        const bool fam_ok = (result == CURLE_OK) || ctx->downloaded_bytes > 0 || http_code > 0;
        const bool fam_unresolvable = (result == CURLE_COULDNT_RESOLVE_HOST);
        char* fam_ip_raw = nullptr;
        curl_easy_getinfo(ctx->easy, CURLINFO_PRIMARY_IP, &fam_ip_raw);
        const std::string fam_ip = (fam_ip_raw && fam_ip_raw[0] != '\0') ? fam_ip_raw : "";
        auto& fam_engine = DownloadEngine::instance();
        fam_engine.noteFamilyOutcome(ctx->family_host, ctx->family_resolve, fam_ip,
                                     fam_ok, fam_unresolvable);
        if (effective_url && effective_url[0] != '\0') {
            std::string eff_family_host = extractHost(std::string(effective_url));
            if (!eff_family_host.empty() && eff_family_host != ctx->family_host) {
                fam_engine.noteFamilyOutcome(eff_family_host, ctx->family_resolve, fam_ip,
                                             fam_ok, fam_unresolvable);
            }
        }
    }

    int64_t expected_len = thr->length();
    int64_t current_done = thr->done();

    // 全量模式（end < 0）但 NetFile 知道文件大小：用 file_size 当 expected
    if (expected_len < 0) {
        int64_t fsz = thr->task()->fileSize();
        if (fsz > 0) expected_len = fsz;
    }

    AMCL_LOG_D(LOG_TAG, "multi complete: url=%{public}s rc=%{public}d http=%{public}ld "
                "done=%{public}lld expected=%{public}lld",
                ctx->actual_url.c_str(), (int)result, http_code,
                (long long)current_done, (long long)expected_len);

    if (ctx->range_requested && http_code == 206) {
        ParsedContentRange range;
        range.start = ctx->content_range_start;
        range.end = ctx->content_range_end;
        range.total = ctx->content_range_total;
        const int64_t requested_end = thr->end() >= ctx->requested_offset ? thr->end() : -1;
        if (!ctx->content_range_seen || !ctx->content_range_valid ||
            !contentRangeMatches(range, ctx->requested_offset, requested_end,
                                 thr->task()->fileSize())) {
            AMCL_LOG_W(LOG_TAG,
                "multi: invalid Content-Range offset=%{public}lld url=%{public}s",
                (long long)ctx->requested_offset, ctx->actual_url.c_str());
            ctx->source->no_range_support.store(true, std::memory_order_release);
            thr->resetDone();
            retryTransfer(ctx);
            return;
        }
        ctx->source->range_verified.store(true, std::memory_order_release);
    }

    if (http_code == 200 && ctx->range_requested && ctx->requested_offset > 0) {
        AMCL_LOG_W(LOG_TAG,
            "multi: DATA MISALIGNED HTTP 200 for resumed Range offset=%{public}lld",
            (long long)ctx->requested_offset);
        ctx->source->no_range_support.store(true, std::memory_order_release);
        thr->resetDone();
        retryTransfer(ctx);
        return;
    }

    // --- 成功判定 ---
    // 段完整写满（typical 206 Partial Content）
    if (expected_len > 0 && current_done >= expected_len) {
        handleSuccess(ctx);
        return;
    }

    // curl rc=OK 但 done < expected：server 提前 EOF
    if (result == CURLE_OK && expected_len > 0 && current_done < expected_len) {
        AMCL_LOG_W(LOG_TAG, "multi: truncated %{public}s: %{public}lld/%{public}lld",
                    ctx->actual_url.c_str(), (long long)current_done, (long long)expected_len);
        thr->resetDone();
        retryTransfer(ctx);
        return;
    }

    // 未知大小段，curl rc=OK 即成功
    if (result == CURLE_OK) {
        handleSuccess(ctx);
        return;
    }

    // --- 失败处理 ---
    handleFailure(ctx, result, http_code);
}

// ============================================================================
// handleSuccess — 传输成功，释放资源并报告完成
// ============================================================================

void MultiDownloader::handleSuccess(TransferCtx* ctx) {
    ctx->source->recordSuccess();
    if (ctx->total_time_us > 0) {
        const double throughput = static_cast<double>(ctx->downloaded_bytes) * 1000000.0 /
                                  static_cast<double>(ctx->total_time_us);
        ctx->source->recordSample(static_cast<int>(ctx->connect_time_us / 1000), throughput);
    }

    // 每 host 从 initial_host_concurrent 起步；连续成功达到当前窗口后才 +1，最高默认 8。
    if (!ctx->host.empty()) {
        int max_limit = std::max(1, std::min(cfg_.max_host_concurrent, cfg_.max_concurrent));
        int initial_limit = std::max(1, std::min(cfg_.initial_host_concurrent, max_limit));
        int& limit = host_limit_[ctx->host];
        if (limit <= 0) limit = initial_limit;
        int& streak = host_success_streak_[ctx->host];
        if (++streak >= std::max(2, limit) && limit < max_limit) {
            ++limit;
            streak = 0;
            AMCL_LOG_D(LOG_TAG, "multi: host %{public}s concurrency ramp -> %{public}d",
                       ctx->host.c_str(), limit);
        }
    }

    // 释放 fd
    if (ctx->fd_acquired) {
        ctx->thread->task()->releaseFd();
        ctx->fd_acquired = false;
    }

    // 记录交付字节的源（与 worker run() 成功路径一致）。缺此调用时单段小文件的 SHA1
    // 终检失败无法定位坏内容源，NetFile 的 checksum_bad 换源逻辑会失效。
    ctx->thread->setLastUsedSource(ctx->source);

    ctx->thread->setState(NetState::Finished);
    ctx->thread->task()->reportThreadFinished(ctx->thread.get());

    int ok = stats_success_.fetch_add(1, std::memory_order_relaxed) + 1;
    if (ok % 200 == 0) {
        AMCL_LOG_I(LOG_TAG, "multi stats: ok=%{public}d fail=%{public}d retry=%{public}d active=%{public}d",
                    ok, stats_fail_.load(), stats_retry_.load(),
                    active_count_.load());
    }
}

// ============================================================================
// handleFailure — 传输失败，决定重试还是放弃
// ============================================================================

void MultiDownloader::handleFailure(TransferCtx* ctx, CURLcode rc, long http_code) {
    NetThread* thr = ctx->thread.get();
    ErrorKind kind = (rc == CURLE_OK) ? ErrorKind::ProtocolError : mapCurlCode(rc);

    // 被用户取消（真正的 abort，不是 stall 检测）
    if (thr->isAborted()) {
        if (ctx->fd_acquired) {
            thr->task()->releaseFd();
            ctx->fd_acquired = false;
        }
        thr->setState(NetState::Aborted);
        thr->task()->reportThreadFinished(thr);
        return;
    }

    // H-08：CURLE_WRITE_ERROR 若由 pwrite 触发，优先使用 callback 持久化的 errno；
    // ENOSPC/EDQUOT/EIO 分别映射本地存储错误，并直接终止，绝不 recordFailure(source)。
    if (rc == CURLE_WRITE_ERROR) {
        if (auto ex = thr->writeFailure(ctx->actual_url)) {
            thr->setError(ex);
            if (ctx->fd_acquired) {
                thr->task()->releaseFd();
                ctx->fd_acquired = false;
            }
            stats_fail_.fetch_add(1, std::memory_order_relaxed);
            thr->setState(NetState::Failed);
            thr->task()->reportThreadFinished(thr);
            return;
        }
    }

    // M-2 修复：header callback 主动 abort 导致的 CURLE_WRITE_ERROR — Location 指向
    // 坏主机。不计入源失败计数（这是 redirect 目标问题，源本身未必坏），但要让
    // source 立刻换：把当前 source 记一笔（max=1 立即禁用）然后 retry。
    if (rc == CURLE_WRITE_ERROR && !ctx->abort_reason_bad_host.empty()) {
        AMCL_LOG_W(LOG_TAG, "multi: Location->bad host %{public}s, swap source: %{public}s",
                    ctx->abort_reason_bad_host.c_str(), ctx->actual_url.c_str());
        auto ex = makeException(ErrorKind::ConnectionError,
                                "redirect to blacklisted host: " + ctx->abort_reason_bad_host);
        ex->url_context = ctx->actual_url;
        ctx->source->recordFailure(ex, /*max_failures=*/1);
        thr->resetDone();
        retryTransfer(ctx);
        return;
    }

    // v4.5b: stall 导致的 ABORTED_BY_CALLBACK 不是取消，重映射为 Timeout 走重试
    if (kind == ErrorKind::AbortedByUser) {
        kind = ErrorKind::Timeout;
    }

    std::string msg = ctx->err_buf[0] ? ctx->err_buf : curl_easy_strerror(rc);
    AMCL_LOG_W(LOG_TAG, "multi: FAIL %{public}s rc=%{public}d http=%{public}ld: %{public}s",
                ctx->actual_url.c_str(), (int)rc, http_code, msg.c_str());

    if (!ctx->host.empty()) {
        host_success_streak_[ctx->host] = 0;
        int max_limit = std::max(1, std::min(cfg_.max_host_concurrent, cfg_.max_concurrent));
        int initial_limit = std::max(1, std::min(cfg_.initial_host_concurrent, max_limit));
        int& limit = host_limit_[ctx->host];
        if (limit <= 0) limit = initial_limit;
        if (limit > initial_limit) --limit;
    }

    // 把超时/连接失败的目标主机加入坏主机黑名单
    if (kind == ErrorKind::Timeout || kind == ErrorKind::ConnectionError
            || kind == ErrorKind::SslError) {
        char* eff_url = nullptr;
        curl_easy_getinfo(ctx->easy, CURLINFO_EFFECTIVE_URL, &eff_url);
        if (eff_url) {
            std::string host = extractHost(std::string(eff_url));
            if (!host.empty() && ctx->source->url.find(host) == std::string::npos) {
                DownloadEngine::instance().addBadHost(host);
            }
        }
    }

    // 构造异常
    auto ex = std::make_shared<DownloadException>();
    ex->kind = kind;
    ex->native_code = static_cast<int>(rc);
    ex->http_status = http_code;
    ex->url_context = ctx->actual_url;
    ex->message = msg;

    thr->setError(ex);

    // 4xx 错误处理（在通用 recordFailure 之前，避免双重计数）
    if (kind == ErrorKind::ProtocolError) {
        long s = ex->http_status;
        // 404/416: 镜像没此文件，1次即禁该源，立即换源重试
        if (s == 404 || s == 416) {
            ctx->source->recordFailure(ex, /*max_failures=*/1);
            thr->resetDone();
            retryTransfer(ctx);
            return;
        }
        // 其他不可重试的 4xx（400/401）→ 直接永久失败
        bool retryable = (s == 408 || s == 429 || s == 403 || (s >= 500 && s < 600));
        if (!retryable) {
            ctx->source->recordFailure(ex);
            if (ctx->fd_acquired) {
                thr->task()->releaseFd();
                ctx->fd_acquired = false;
            }
            stats_fail_.fetch_add(1, std::memory_order_relaxed);
            AMCL_LOG_E(LOG_TAG, "multi: PERMANENT FAIL http=%{public}ld file=%{public}s url=%{public}s",
                         s, thr->task()->localPath().c_str(), ctx->actual_url.c_str());
            thr->setState(NetState::Failed);
            thr->task()->reportThreadFinished(thr);
            return;
        }
    }

    bool is_bmclapi = (ctx->source->url.find("bmclapi") != std::string::npos);
    if (http_code == 408 || http_code == 429 || http_code == 503) {
        // 所有类型的源（含 BMCLAPI）统一进入临时 cooldown；限流不是源质量失败，
        // 不增加 fail_count。Retry-After（秒或 HTTP-date）优先，否则指数退避并加 jitter。
        int64_t delay_ms = retryDelayWithJitter(ctx->retry_after_ms,
                                               thr->retryCount(), ctx->source->id);
        if (!thr->addRetryDelayMs(delay_ms, 5 * 60 * 1000LL)) {
            if (ctx->fd_acquired) { thr->task()->releaseFd(); ctx->fd_acquired = false; }
            stats_fail_.fetch_add(1, std::memory_order_relaxed);
            thr->setError(makeException(ErrorKind::ConnectionError,
                                        "retry deadline exhausted during cooldown"));
            thr->setState(NetState::Failed);
            thr->task()->reportThreadFinished(thr);
            return;
        }
        int64_t until = steadyNowMs() + delay_ms;
        ctx->source->extendCooldownUntil(until);
        thr->deferUntilMs(until);

        if (http_code == 429 && !ctx->host.empty()) {
            int& limit = host_limit_[ctx->host];
            if (limit <= 0) {
                limit = std::max(1, std::min(cfg_.initial_host_concurrent,
                                             cfg_.max_host_concurrent));
            }
            limit = std::max(1, limit / 2);
            host_success_streak_[ctx->host] = 0;
            AMCL_LOG_W(LOG_TAG, "multi: host %{public}s 429 window -> %{public}d",
                       ctx->host.c_str(), limit);
        }
        AMCL_LOG_W(LOG_TAG, "multi: %{public}ld cooldown %{public}lldms: %{public}s",
                   http_code, (long long)delay_ms, ctx->source->url.c_str());
    } else if (http_code == 403 && is_bmclapi) {
        ctx->source->recordFailure(ex, /*max_failures=*/3);
    } else {
        int max_failures = kind == ErrorKind::SslError ? 8 :
                           kind == ErrorKind::Timeout ? 10 : 5;
        ctx->source->recordFailure(ex, max_failures);
        // 通用 5xx（500/502/504 等）也需退避，否则 retryTransfer 会零延迟重入，
        // 在 max_failures 内高频打同一源。与 worker run() 的 5xx 退避保持一致。
        if (http_code >= 500 && http_code < 600) {
            int64_t delay_ms = retryDelayWithJitter(0, thr->retryCount(), ctx->source->id);
            if (thr->addRetryDelayMs(delay_ms, 5 * 60 * 1000LL)) {
                int64_t until = steadyNowMs() + delay_ms;
                ctx->source->extendCooldownUntil(until);
                thr->deferUntilMs(until);
            }
        }
    }

    // 重试
    thr->resetDone();
    retryTransfer(ctx);
}

// ============================================================================
// retryTransfer — 重新入队让 feedTransfers 选新 source 重试
// ============================================================================

void MultiDownloader::retryTransfer(TransferCtx* ctx) {
    stats_retry_.fetch_add(1, std::memory_order_relaxed);

    // attempt 在 startTransfer 真正加入 multi 前由 NetThread::tryBeginAttempt 计数；
    // 这里绝不创建 TransferCtx 局部计数，确保跨销毁/重建仍严格最多 30 次。
    int64_t deadline = ctx->thread->retryDeadlineMs();
    bool exhausted = ctx->thread->retryCount() >= 30 ||
                     (deadline > 0 && steadyNowMs() >= deadline);
    if (exhausted) {
        if (ctx->fd_acquired) {
            ctx->thread->task()->releaseFd();
            ctx->fd_acquired = false;
        }
        if (!ctx->thread->error()) {
            ctx->thread->setError(makeException(ErrorKind::ConnectionError,
                                                "retry budget exhausted"));
        }
        stats_fail_.fetch_add(1, std::memory_order_relaxed);
        AMCL_LOG_E(LOG_TAG, "multi: RETRY EXHAUSTED attempts=%{public}d file=%{public}s",
                   ctx->thread->retryCount(), ctx->thread->task()->localPath().c_str());
        ctx->thread->setState(NetState::Failed);
        ctx->thread->task()->reportThreadFinished(ctx->thread.get());
        return;
    }

    // 释放 fd（feedTransfers 重新 acquireFd）
    if (ctx->fd_acquired) {
        ctx->thread->task()->releaseFd();
        ctx->fd_acquired = false;
    }

    // 重新入队（push_back 而非 push_front）；feedTransfers 会严格检查 retryNotBeforeMs，
    // cooldown 到期前不会建立 easy handle，也不会被同 host 队首阻塞其他 host。
    {
        std::lock_guard<std::mutex> lk(mu_);
        uint64_t task_id = ctx->thread && ctx->thread->task()
            ? ctx->thread->task()->taskId() : 0;
        auto& queue = pending_by_task_[task_id];
        if (queue.empty()) pending_task_order_.push_back(task_id);
        queue.push_back(ctx->thread);
        ++pending_count_;
    }
    cv_.notify_one();
}

} // namespace download
