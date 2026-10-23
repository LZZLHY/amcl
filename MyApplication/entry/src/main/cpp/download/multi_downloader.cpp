/**
 * multi_downloader.cpp — 保留CURLM/easy池的小文件事件循环。
 *
 * pending按任务轮转；feed在来源、频率和Engine共享准入后才开文件并加入multi。
 * poll/perform/drain推进真实请求。每个重定向完成后带原NetThread/NetSource重入下一hop，
 * 不阻塞header回调，不绕过真实host账本，也不把3xx正文写入工件。
 *
 * easy连接缓存和现有兼容profile保留；完全空闲仍无限事件等待。终态发布后必须移除
 * handle/回调，再报告execution-settled，不能以“请求结束”替代NetFile最终提交屏障。
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
#include "host_admission.h"
#include "download_execution_context.h"
#include "transport_policy.h"
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

std::string extractHost(const std::string& url) { return transportHost(url); }

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

/** 本地指数退避有 cap；服务器 not-before 永不被 cap 截短。 */
int64_t retryDelayWithJitter(int64_t retry_after_ms, int attempt, int source_id) {
    const int shift = std::min(attempt > 0 ? attempt - 1 : 0, 5);
    const int64_t base = std::max<int64_t>(retry_after_ms, 500LL * (1LL << shift));
    const int64_t window = std::min<int64_t>(1000, std::max<int64_t>(100, base / 5));
    const int64_t jitter = 50 + ((attempt * 1103515245LL + source_id * 97LL) % window);
    return transportDeadlineAfter(base, jitter);
}

} // namespace

// M-2 修复：header callback 拦截 302 → bad host
size_t MultiDownloader::onHeader(char* buffer, size_t size, size_t nitems, void* userdata) {
    TransferCtx* ctx = static_cast<TransferCtx*>(userdata);
    if (!ctx || (size != 0 && nitems > SIZE_MAX / size)) return 0;
    size_t total = size * nitems;
    std::string line(buffer, total);
    // 与worker路径共享状态行和授权消费事实；该回调不会转发任何Bearer内容。
    NetThread::onHeader(buffer, size, nitems, ctx->thread.get());
    if (startsWithIgnoreCase(line, "HTTP/")) {
        ctx->retry_after_ms = 0; ctx->content_range_seen = false;
        ctx->content_range_valid = false; ctx->content_range_start = -1;
        ctx->content_range_end = -1; ctx->content_range_total = -1;
    }

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
        ctx->retry_after_ms = parseTransportRetryAfter(line.substr(12));
    }
    // 重定向由完成事件重新排入下一 hop，先取得真实目标主机的同一 Engine 名额。
    // header 回调仅收集事实，不占探针/同步等待，不再让 curl 隐式绕过准入。
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
    // 空闲循环不再定期醒来兜底。与等待方共用mu_发布退出，避免谓词已检查、
    // 真正进入wait之前的notify丢失；释放锁后才join，不能挡住退出收尾。
    {
        std::lock_guard<std::mutex> lk(mu_);
        if (!running_.exchange(false, std::memory_order_acq_rel)) return;
    }
    cv_.notify_all();

    if (loop_thread_.joinable()) {
        loop_thread_.join();
    }

    // 防御性清理：正常 eventLoop 会在退出前收敛为空；若 curl multi 异常留下
    // transfer，先移除 callback userdata，再发布 settled。
    for (auto& kv : transfers_) {
        auto* ctx = kv.second.get();
        NetThreadPtr thread = ctx->thread;
        thread->endTransportAttempt();
        if (ctx->fd_acquired) {
            thread->task()->releaseFd();
            ctx->fd_acquired = false;
        }
        // 取消终态不得暴露此前换源的 HTTP 错误；Aborted 状态承担取消分类。
        thread->setError(nullptr);
        thread->setState(NetState::Aborted);
        curl_multi_remove_handle(multi_, kv.first);
        curl_easy_cleanup(kv.first);
        thread->markExecutionSettled();
    }
    transfers_.clear();
    pending_redirects_.clear();
    // 真实 transfer 已逐项归还 Engine token。这里只清本执行器活动计数，不能清全局
    // Retry-After、来源坏内容或权限消费事实；同对象再次start不继承幽灵占位。
    host_active_.clear();
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

bool MultiDownloader::enqueue(const std::vector<NetThreadPtr>& threads) noexcept {
    if (threads.empty()) return true;
    struct Checkpoint { uint64_t id; size_t previous_size; bool created; bool order_added; };
    try {
        std::unordered_map<uint64_t, std::vector<NetThreadPtr>> grouped;
        for (const auto& thread : threads) {
            const uint64_t id = thread && thread->task() ? thread->task()->taskId() : 0;
            grouped[id].push_back(thread);
        }
        std::vector<Checkpoint> checkpoints;
        checkpoints.reserve(grouped.size());
        std::lock_guard<std::mutex> lk(mu_);
        if (!running_.load(std::memory_order_acquire)) return false;
        try {
            for (const auto& group : grouped) {
                auto inserted = pending_by_task_.try_emplace(group.first);
                auto& queue = inserted.first->second;
                checkpoints.push_back({group.first, queue.size(), inserted.second, false});
                for (const auto& thread : group.second) queue.push_back(thread);
                if (checkpoints.back().previous_size == 0) {
                    pending_task_order_.push_back(group.first);
                    checkpoints.back().order_added = true;
                }
            }
            pending_count_ += threads.size();
        } catch (...) {
            // 同锁内 eventLoop 无法观察新尾；倒序归还本事务追加的轮转槽和队列，
            // 既有 pending 与计数不变。此处只回滚，不在 Engine lifecycle 锁下回调。
            for (auto it = checkpoints.rbegin(); it != checkpoints.rend(); ++it) {
                if (it->order_added) pending_task_order_.pop_back();
                auto queue = pending_by_task_.find(it->id);
                while (queue->second.size() > it->previous_size) queue->second.pop_back();
                if (it->created && queue->second.empty()) pending_by_task_.erase(queue);
            }
            return false;
        }
    } catch (...) { return false; }
    cv_.notify_one();
    return true;
}

void MultiDownloader::notifyCancellation() {
    // 等待方在 mu_ 下检查取消令牌并进入条件变量等待；通知方也经过同一把锁，
    // 使“谓词检查后、真正睡眠前”发生的取消不会丢失唤醒。这里不持锁调用任何回调。
    {
        std::lock_guard<std::mutex> lk(mu_);
    }
    cv_.notify_all();
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
            // 取消优先于 not-before：通知唤醒后必须让等待谓词成立，下一轮 feedTransfers
            // 才能正常退出该段并发布 execution-settled，而不是继续等原 Retry-After。
            if (thread->isAborted()) return 0;
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
    DownloadExecutionContext execution_context;
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

        // 没有传输/待办就无限期事件等待；enqueue、cancel与shutdown均经mu_通知。
        // 有限deadline和socket轮询只属于下面真实活动的传输，不能让空闲游戏期每200ms醒来。
        if (!has_pending && !has_active) {
            std::unique_lock<std::mutex> lk(mu_);
            cv_.wait(lk, [this] {
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
            thread->setError(nullptr);
            thread->setState(NetState::Aborted);
            pending_redirects_.erase(thread.get());
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
            thread->setError(nullptr);
            thread->setState(NetState::Finished);
            pending_redirects_.erase(thread.get());
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
                pending_redirects_.erase(execution.get());
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
    if (steadyNowMs() >= thread->schedulingDeadlineMs()) {
        thread->setError(makeRetryTerminationException(thread->error(), "host admission deadline exhausted"));
        thread->setState(NetState::Failed); file->reportThreadFinished(thread.get()); return false;
    }

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
    bool needs_range = thread->requiresRangeSupport() &&
        !(file->requiresSingleSourceRecheck() && thread->start() == 0 && thread->end() < 0);
    const auto redirect = pending_redirects_.find(thread.get());
    NetSourcePtr src = redirect != pending_redirects_.end()
        ? redirect->second.source : file->pickBestSource(needs_range,
            thread->retryCount() == 0 ? thread->preferredSourceIdx() : -1);
    const std::string request_url = redirect != pending_redirects_.end()
        ? redirect->second.url : (src ? src->url : std::string());
    const int redirect_count = redirect != pending_redirects_.end() ? redirect->second.count : 0;
    if (!src) {
        int64_t ready = file->nextSourceReadyMs(needs_range);
        int64_t now = steadyNowMs();
        if (ready > now) {
            int64_t deadline = thread->schedulingDeadlineMs();
            if (deadline > 0 && ready > deadline) {
                auto ex = makeRetryTerminationException(thread->error(),
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
        // 重新入队仍属于同一段执行；保留它最近实际请求的异常，不从源缓存猜测原因。
        auto ex = makeRetryTerminationException(thread->error(),
                                "no available sources (all failed)");
        thread->setError(ex);
        thread->setState(NetState::Failed);
        file->reportThreadFinished(thread.get());
        return false;
    }

    const auto deferSource = [&](int64_t ready) {
        // 真实CDN/relay的限流属于本候选，不钉住整个NetThread。回源调度后若有健康
        // 备源立即选它；全部不可用才由nextSourceReadyMs有界等待，已写前缀不动。
        src->extendCooldownUntil(ready);
        pending_redirects_.erase(thread.get());
        thread->deferUntilMs(steadyNowMs() + 1);
        std::lock_guard<std::mutex> lk(mu_);
        auto& queue = pending_by_task_[file->taskId()];
        if (queue.empty()) pending_task_order_.push_back(file->taskId());
        queue.push_back(std::move(thread)); ++pending_count_;
        throttle_deferred_ = true;
        return false;
    };

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
    std::string source_host = extractHost(request_url);
    if (!source_host.empty()) {
        int max_limit = std::max(1, std::min(cfg_.max_host_concurrent, cfg_.max_concurrent));
        int initial_limit = std::max(1, std::min(cfg_.initial_host_concurrent, max_limit));
        int& limit = host_limit_[source_host];
        if (limit <= 0) limit = initial_limit;
        if (host_active_[source_host] >= limit) return deferSource(steadyNowMs() + 25);

        // PCL2 的 bmclapi Sleep(100) 等价物：受限主机两条新连接之间至少隔 interval 毫秒。
        if (isThrottledSourceUrl(request_url) && cfg_.throttled_host_start_interval_ms > 0) {
            int64_t now = steadyNowMs();
            auto slot = host_next_start_ms_.find(source_host);
            if (slot != host_next_start_ms_.end() && now < slot->second)
                return deferSource(slot->second);
            // 本轮放行 → 记账下次允许时刻。放在 curl_multi_add_handle 之前设也没关系：
            // 后面若因故失败返回，最坏只是多等一个 interval，不会漏放行。
            host_next_start_ms_[source_host] =
                now + cfg_.throttled_host_start_interval_ms;
        }
    }

    // 共享准入在打开文件前完成；source/redirect host 在同一 Engine 账本计数。
    // 暂未准入不记源失败、不清有效前缀、不消费实际请求/授权次数。
    auto admission = std::make_unique<HostAdmissionLease>();
    if (!admission->tryAcquire(source_host)) {
        const int64_t ready = std::max(steadyNowMs() + 25,
            std::max(DownloadEngine::instance().badHostReadyAtMs(source_host),
                     DownloadEngine::instance().hostRateLimitUntilMs(source_host)));
        return deferSource(ready);
    }

    // 普通准入让行仍保留 prefix；只有完整摘要已证伪后的隔离复验会在换 logical
    // 来源时从0重做。绑定发生在 Range 窗口/ctx.done_before 形成之前，redirect 同源不重置。
    thread->prepareContentSource(src);

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
    ctx->actual_url = request_url;
    ctx->redirect_count = redirect_count;
    ctx->admission = std::move(admission);
    ctx->done_before = thread->done();
    ctx->fd_acquired = true;
    ctx->err_buf[0] = '\0';
    thread->clearWriteErrno();

    // --- 配置 easy handle ---

    curl_easy_setopt(easy, CURLOPT_URL, ctx->actual_url.c_str());
    // 每个重定向在完成事件重入 pending，真实目标也必须经过同一准入/预算。
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
    // 短时授权绑定单一节点；禁止跨重定向转发。easy_reset 会清除上一任务的凭据。
    if (!file->bearerToken().empty()) {
        ctx->authorization_headers.reset(curl_slist_append(nullptr, ("Authorization: Bearer " + file->bearerToken()).c_str()));
        if (!ctx->authorization_headers) {
            file->releaseFd(); ctx->fd_acquired = false; releaseEasy(easy);
            thread->setError(makeException(ErrorKind::InternalError, "authorization header allocation failed"));
            thread->setState(NetState::Failed); file->reportThreadFinished(thread.get()); return false;
        }
        curl_easy_setopt(easy, CURLOPT_HTTPHEADER, ctx->authorization_headers.get());
        curl_easy_setopt(easy, CURLOPT_FRESH_CONNECT, 1L);
        curl_easy_setopt(easy, CURLOPT_FORBID_REUSE, 1L);
    }
    curl_easy_setopt(easy, CURLOPT_MAXREDIRS, 5L);
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);

    // 继续使用原 CURLM Config 的兼容 profile，不借整理引入新的吞吐参数或分流。
    const auto profile = multiRequestProfile(cfg_.connect_timeout_s, cfg_.total_timeout_s,
        cfg_.low_speed_limit, cfg_.low_speed_time_s, file->isHighParallel());
    applyTransportProfile(easy, profile);
    CURLSH* sh = DownloadEngine::instance().curlShare(); // 当前只共享 DNS
    if (sh) curl_easy_setopt(easy, CURLOPT_SHARE, sh);
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
    ctx->requested_end = thread->end() >= ctx->requested_offset ? thread->end() : -1;
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

    // header callback 只收集本次响应事实。userdata = TransferCtx*
    // ctx 已在 transfers_[easy] 持稳定指针，pointer 在 transfer 生命周期内有效。
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, &MultiDownloader::onHeader);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, ctx.get());

    curl_easy_setopt(easy, CURLOPT_USERAGENT, "amcl/0.1 (OHOS; libcurl/8.10.1)");
    // 每个 hop 均按它自己的真实主机选择地址族；最终 CDN 结果不回写逻辑 origin。
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
        auto ex = makeRetryTerminationException(thread->error(), "retry attempts exhausted");
        thread->setError(ex);
        thread->setState(NetState::Failed);
        file->reportThreadFinished(thread.get());
        return false;
    }

    if (auto denied = file->beginAuthorizedRequest()) {
        file->releaseFd(); ctx->fd_acquired = false; releaseEasy(easy);
        thread->setError(denied); thread->setState(NetState::Failed);
        file->reportThreadFinished(thread.get()); return false;
    }
    // 真正加入 CURLM 之前才开始本次 HTTP 时钟；此前队列和 Retry-After 时间不算 stall。
    thread->beginTransportAttempt(ctx->admission.get());
    thread->setState(NetState::Connecting);

    // 加入 multi
    CURLMcode mc = curl_multi_add_handle(multi_, easy);
    if (mc != CURLM_OK) {
        thread->endTransportAttempt();
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
    pending_redirects_.erase(thread.get());
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
                pending_redirects_.erase(completed_thread.get());
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
    thr->endTransportAttempt();

    // 每个 TransferCtx 只代表一个真实 hop，故 primary IP 只能给本 ctx 的主机打分。
    // 不再把最终 CDN 的地址族结果反写到逻辑 origin，也不把未发出的 probe 算成功。
    const int64_t progress = thr->done() > ctx->done_before ? thr->done() - ctx->done_before : 0;
    char* raw_ip = nullptr;
    curl_easy_getinfo(ctx->easy, CURLINFO_PRIMARY_IP, &raw_ip);
    const std::string primary_ip = raw_ip ? raw_ip : "";
    auto& engine = DownloadEngine::instance();
    if (http_code > 0 || ctx->downloaded_bytes > 0 ||
        isFamilyConnectFailure(result, http_code, ctx->downloaded_bytes))
        engine.noteFamilyOutcome(ctx->family_host, ctx->family_resolve, primary_ip,
                                 http_code > 0 || ctx->downloaded_bytes > 0,
                                 result == CURLE_COULDNT_RESOLVE_HOST);
    const long used_family = ctx->family_resolve == CURL_IPRESOLVE_WHATEVER
        ? DownloadEngine::familyFromIp(primary_ip) : ctx->family_resolve;
    ctx->family_retry = isFamilyConnectFailure(result, http_code, ctx->downloaded_bytes) &&
        engine.hasUntriedFamily(ctx->family_host, used_family);
    const bool local_failure = thr->writeErrno() != 0 || (thr->error() && thr->error()->needs_new_lease);
    const bool healthy = !thr->isAborted() && !local_failure &&
        ((result == CURLE_OK && http_code >= 200 && http_code < 400) || progress >= 1024 * 1024);
    if (ctx->admission) ctx->admission->finish(healthy);
    if (!healthy && !thr->isAborted() && !local_failure && !ctx->family_retry &&
             isFamilyConnectFailure(result, http_code, ctx->downloaded_bytes)) engine.addBadHost(ctx->host);
    if (progress > 0 && ctx->total_time_us > 0 && !thr->isAborted() && !local_failure &&
        http_code >= 200 && http_code < 300) {
        ctx->source->recordSample(static_cast<int>(ctx->connect_time_us / 1000),
            static_cast<double>(progress) * 1000000.0 / static_cast<double>(ctx->total_time_us));
    }

    // 取消/本地错误/授权额度先于“段已填满”，不能让残存前缀把本次失败改判成功。
    if (thr->isAborted() || local_failure) { handleFailure(ctx, result, http_code); return; }

    if (result == CURLE_OK && (http_code == 301 || http_code == 302 || http_code == 307 || http_code == 308)) {
        char* raw_redirect = nullptr;
        curl_easy_getinfo(ctx->easy, CURLINFO_REDIRECT_URL, &raw_redirect);
        const std::string next_url = raw_redirect ? raw_redirect : "";
        if (!thr->task()->bearerToken().empty()) {
            auto ex = makeException(ErrorKind::ProtocolError, "authorized node returned redirect");
            ex->http_status = http_code; ex->url_context = ctx->actual_url;
            thr->setError(thr->task()->authorizationFailure(ex));
            handleFailure(ctx, CURLE_HTTP_RETURNED_ERROR, http_code); return;
        }
        if (ctx->redirect_count >= 5 || !isTransportHttpUrl(next_url)) {
            handleFailure(ctx, CURLE_HTTP_RETURNED_ERROR, http_code); return;
        }
        // 3xx 正文由 NetThread::onWrite 丢弃。保留所有有效已写字节；下一 hop 再取得
        // 新 host 的名额、重建时钟/响应头/Range，不能在 header 回调内阻塞整个 CURLM。
        pending_redirects_[thr] = {ctx->source, next_url, ctx->redirect_count + 1};
        retryTransfer(ctx); return;
    }
    if (result == CURLE_OK && (http_code < 200 || http_code >= 300)) {
        handleFailure(ctx, CURLE_HTTP_RETURNED_ERROR, http_code); return;
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

    // full GET收到意外206仍是部分对象，不能凭curl正常EOF当作无摘要未知下载成功。
    if (!ctx->range_requested && http_code == 206) {
        auto ex = makeException(ErrorKind::SizeMismatch, "unsolicited partial response for full GET");
        ex->http_status = http_code; ex->url_context = ctx->actual_url;
        thr->setError(ex); thr->resetDone(); retryTransfer(ctx); return;
    }
    if (ctx->range_requested && http_code == 206) {
        ParsedContentRange range;
        range.start = ctx->content_range_start;
        range.end = ctx->content_range_end;
        range.total = ctx->content_range_total;
        const int64_t requested_end = ctx->requested_end;
        // 与 worker 保持相同的完整性合同：开放式 Range 的正常 HTTP EOF 只有在
        // Content-Range 抵达 total-1 时才代表剩余对象已收齐；合法但较短的中间窗口
        // 不能作为未知大小完整下载成功。header 不在这里改写 NetFile 权威总长。
        if (!ctx->content_range_seen || !ctx->content_range_valid ||
            !contentRangeMatches(range, ctx->requested_offset, requested_end,
                                 thr->task()->fileSize()) ||
            (requested_end < 0 && range.end != range.total - 1)) {
            AMCL_LOG_W(LOG_TAG,
                "multi: invalid Content-Range offset=%{public}lld url=%{public}s",
                (long long)ctx->requested_offset, ctx->actual_url.c_str());
            ctx->source->no_range_support.store(true, std::memory_order_release);
            auto ex = makeException(ErrorKind::SizeMismatch, "invalid Content-Range for requested offset");
            ex->http_status = http_code; ex->url_context = ctx->actual_url;
            thr->setError(ex);
            thr->resetDone(); retryTransfer(ctx); return;
        }
        ctx->source->range_verified.store(true, std::memory_order_release);
        // 与worker相同：声明完整末尾但实际CL更短的正常EOF仍是短读。把验证过的
        // response total仅用于本次完成条件，不改变NetFile total或授权累计事实。
        if (requested_end < 0 && expected_len < 0) expected_len = range.total - thr->start();
        if (requested_end < 0 && current_done > range.total - thr->start()) {
            auto ex = makeException(ErrorKind::SizeMismatch, "open-ended Range body exceeded declared object EOF");
            ex->http_status = http_code; ex->url_context = ctx->actual_url;
            thr->setError(ex); thr->resetDone(); retryTransfer(ctx); return;
        }
    }

    if (http_code == 200 && ctx->range_requested && ctx->requested_offset > 0) {
        AMCL_LOG_W(LOG_TAG,
            "multi: DATA MISALIGNED HTTP 200 for resumed Range offset=%{public}lld",
            (long long)ctx->requested_offset);
        ctx->source->no_range_support.store(true, std::memory_order_release);
        auto ex = makeException(ErrorKind::SizeMismatch, "server ignored resumed Range");
        ex->http_status = http_code; ex->url_context = ctx->actual_url;
        thr->setError(ex);
        thr->resetDone(); retryTransfer(ctx); return;
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
    // 保留CURLM配置窗口；连续成功逐步恢复，真实总名额仍受Engine共享账本约束。
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

    // 正文成功后清除换源阶段的旧异常，并在发布 Finished 前完成，避免成功快照误报。
    ctx->thread->setError(nullptr);
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
        thr->setError(nullptr);
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

    // 实际主机/地址族已由 handleComplete 统一记账；此处只决定本文件来源恢复。
    // 构造异常
    auto ex = std::make_shared<DownloadException>();
    ex->kind = kind;
    ex->native_code = static_cast<int>(rc);
    ex->http_status = http_code;
    ex->url_context = ctx->actual_url;
    ex->message = msg;
    ex->retry_after_ms = ctx->retry_after_ms;

    // 正文额度失败优先于curl通用write error；认证失效以类型事实要求业务层续领。
    if (auto pending = thr->error(); pending && pending->needs_new_lease) ex = pending;
    else if (!thr->task()->bearerToken().empty() && (http_code == 401 || http_code == 403 || http_code == 429 || http_code == 503))
        ex = thr->task()->authorizationFailure(ex);
    if (!thr->task()->bearerToken().empty() && (http_code == 429 || http_code == 503)) ex->retry_after_ms = std::max<int64_t>(1000, ex->retry_after_ms);
    if (ex->needs_new_lease) {
        if ((http_code == 429 || http_code == 503) && ctx->retry_after_ms > 0)
            DownloadEngine::instance().noteHostRateLimit(ctx->host, ctx->retry_after_ms);
        if (ctx->fd_acquired) { thr->task()->releaseFd(); ctx->fd_acquired = false; }
        thr->setError(ex); thr->setState(NetState::Failed); thr->task()->reportThreadFinished(thr); return;
    }

    thr->setError(ex);

    if (ctx->family_retry) {
        // 地址族失败不等于 URL 失败。下一请求固定同一实际 hop，交给 ipResolveFor 换族，
        // 仍走同一请求次数/授权/时间预算，不清除已有 Range 前缀。
        pending_redirects_[thr] = {ctx->source, ctx->actual_url, ctx->redirect_count};
        retryTransfer(ctx); return;
    }

    // 4xx 错误处理（在通用 recordFailure 之前，避免双重计数）
    if (kind == ErrorKind::ProtocolError) {
        long s = ex->http_status;
        // 404/416: 镜像没此文件，1次即禁该源，立即换源重试
        if (s == 404 || s == 416) {
            ctx->source->recordFailure(ex, /*max_failures=*/1);
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
        const int64_t now = steadyNowMs();
        const int64_t until = DownloadEngine::instance().noteHostRateLimit(ctx->host, ctx->retry_after_ms);
        const int64_t delay_ms = until > now ? until - now : 0;
        ctx->source->extendCooldownUntil(until); // 即使超预算退出，也保留服务器 not-before
        if (thr->task()->pickBestSource(thr->requiresRangeSupport())) {
            if (http_code == 429) DownloadEngine::instance().penalizeHost(ctx->host);
            retryTransfer(ctx); return;
        }
        if (!thr->addRetryDelayMs(delay_ms, 5 * 60 * 1000LL)) {
            if (ctx->fd_acquired) { thr->task()->releaseFd(); ctx->fd_acquired = false; }
            stats_fail_.fetch_add(1, std::memory_order_relaxed);
            thr->setError(makeRetryTerminationException(thr->error(),
                                        "retry deadline exhausted during cooldown"));
            thr->setState(NetState::Failed);
            thr->task()->reportThreadFinished(thr);
            return;
        }
        ctx->source->extendCooldownUntil(until);
        thr->deferUntilMs(until);

        if (http_code == 429 && !ctx->host.empty()) {
            DownloadEngine::instance().penalizeHost(ctx->host);
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

    // 网络/HTTP失败不撤销已验证写入偏移；仅明确错位/坏区间的分支重置内容。
    retryTransfer(ctx);
}

// ============================================================================
// retryTransfer — 重新入队让 feedTransfers 选新 source 重试
// ============================================================================

void MultiDownloader::retryTransfer(TransferCtx* ctx) {
    // 所有多下载重试出口（含Range格式/EOF）都受单次权限约束，不能绕回再GET。
    if (ctx->thread->task()->singleUseAuthorization() ||
        (ctx->thread->error() && ctx->thread->error()->needs_new_lease)) {
        if (ctx->fd_acquired) { ctx->thread->task()->releaseFd(); ctx->fd_acquired = false; }
        ctx->thread->setError(ctx->thread->task()->authorizationFailure(ctx->thread->error()));
        ctx->thread->setState(NetState::Failed);
        ctx->thread->task()->reportThreadFinished(ctx->thread.get()); return;
    }
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
        ctx->thread->setError(makeRetryTerminationException(ctx->thread->error(),
                                                           "retry budget exhausted"));
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
