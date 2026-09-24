/**
 * net_thread.cpp — 单分段下载的 curl 工作线程
 *
 * 运行流程：
 *   loop over sources:
 *     state = Connecting
 *     easy = curl_easy_init + setopt(URL, Range, callbacks, timeouts, ca-bundle)
 *     state = Downloading (由 write_callback 第一次触发)
 *     rc = curl_easy_perform  (阻塞)
 *     curl_easy_cleanup
 *     if rc OK && http 2xx: state=Finished，return
 *     else: source.recordFailure(ex) + 重试下一个源（done_ 重置为 0）
 *   全部源失败 → state=Failed
 *
 * pwrite：write_callback 内部对 task_->fd() 做 pwrite(buf, n, start_ + done_)。
 *         POSIX pwrite 保证原子性，多线程并发写同一 fd 的不同 offset 是安全的。
 */
#include "net_thread.h"

#include <curl/curl.h>
#include <hilog/log.h>
#include <unistd.h>
#include <sys/socket.h>

#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <cstring>
#include <limits>
#include <sstream>
#include <thread>

#include "config.h"
#include "engine.h"
#include "http_range.h"
#include "net_file.h"
#include "relay.h"

#include "../utils/amcl_log.h"

#undef LOG_TAG
#define LOG_TAG "DL_THREAD"

namespace download {

namespace {

/**
 * 从 URL 取第一个 host，用作每主机并发闸门的 key。
 * 代理镜像 URL 形如 https://github.moeyy.xyz/https://github.com/... —— 取首个 host
 * 正是「实际要连的那台机器」（github.moeyy.xyz），这才是被限流的主体。
 */
std::string extractHostForSlot(const std::string& url) {
    size_t s = url.find("://");
    if (s == std::string::npos) return {};
    s += 3;
    size_t e = url.find('/', s);
    size_t p = url.find(':', s);
    if (p != std::string::npos && (e == std::string::npos || p < e)) e = p;
    if (e == std::string::npos) return url.substr(s);
    return url.substr(s, e - s);
}

int64_t nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

/**
 * H-2 修复：构造 HTTP Range header 字符串。
 *
 * 主路径与 redirect 路径都需要这个逻辑，但原代码两处实现不同：
 *   - 主路径仅在 `end >= start` 时设 Range，遗漏了 "断点续传到未知大小段"（end<0,start>0）
 *   - redirect 路径还兜了 `start>0 || end>=0` 的 case，但代码冗余
 *
 * 统一行为：
 *   1. `end >= start`：定长段 → "<start+done>-<end>"
 *   2. `end < start && start+done > 0`：断点续传未知大小段 → "<start+done>-"
 *   3. `start=0 && end<0 && done=0`：全量请求 → 空字符串（不发 Range）
 *
 * @return 空字符串 = 不发 Range；否则即 CURLOPT_RANGE 值
 */
std::string buildRangeHeader(int64_t start, int64_t end, int64_t done) {
    int64_t range_start = start + done;
    if (end >= start) {
        return std::to_string(range_start) + "-" + std::to_string(end);
    }
    if (range_start > 0) {
        return std::to_string(range_start) + "-";
    }
    return {};
}

/**
 * v7：CURLOPT_SOCKOPTFUNCTION 回调 —— 在 connect 前显式放大 socket 接收/发送缓冲。
 *
 * 诊断证据（perform PERF 日志）：本引擎单条全量 GET 实测仅 ~21KB/s，而系统 HTTP 栈在
 * 同一 URL 上有 ~555KB/s。21KB/s ≈ 5KB 窗口 / 230ms RTT —— 说明我们这条 socket 的 TCP
 * 接收窗口被钉在极小值、内核自适应没把它放大（系统栈那条却放大了）。对高 RTT(国内→CDN)
 * 链路，显式把 SO_RCVBUF 设大可强制内核用大窗口（受 net.core.rmem_max 上限钳制，但即便被
 * 钳到几百 KB 也远好于 5KB）。仅对模组/资源高并发路径启用。
 */
int sockoptEnlargeRcvbuf(void* /*clientp*/, curl_socket_t fd, curlsocktype purpose) {
    if (purpose == CURLSOCKTYPE_IPCXN) {
        int rcv = 4 * 1024 * 1024;   // 期望 4MB（内核会按 rmem_max 钳制 + 翻倍记账）
        int snd = 1 * 1024 * 1024;
        ::setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof(rcv));
        ::setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, sizeof(snd));
    }
    return CURL_SOCKOPT_OK;
}

/**
 * 统计该文件当前还"可用"的源数量（未永久失败、未被 checksum 拉黑）。
 *
 * 2026-07-30：用于判断"低速时值不值得掐断换源"。sources_ 在 NetFile 构造后不再增删，
 * 各状态位都是 atomic，因此只读遍历无需持锁。
 */
int countUsableSources(const NetFile* file) {
    if (!file) return 0;
    int usable = 0;
    for (const auto& s : file->sources()) {
        if (!s) continue;
        if (s->checksum_bad.load(std::memory_order_relaxed)) continue;
        if (s->is_failed.load(std::memory_order_relaxed)) continue;
        ++usable;
    }
    return usable;
}

/** 把 CURLcode 映射到我们的 ErrorKind */
ErrorKind mapCurlCode(CURLcode rc) {
    switch (rc) {
        case CURLE_COULDNT_CONNECT:
        case CURLE_COULDNT_RESOLVE_HOST:
        case CURLE_COULDNT_RESOLVE_PROXY:
        case CURLE_GOT_NOTHING:
        case CURLE_RECV_ERROR:
        case CURLE_SEND_ERROR:
            return ErrorKind::ConnectionError;
        case CURLE_OPERATION_TIMEDOUT:
            return ErrorKind::Timeout;
        case CURLE_ABORTED_BY_CALLBACK:
            return ErrorKind::AbortedByUser;
        case CURLE_SSL_CONNECT_ERROR:
        case CURLE_SSL_CERTPROBLEM:
        case CURLE_SSL_CIPHER:
        case CURLE_PEER_FAILED_VERIFICATION:
            return ErrorKind::SslError;
        case CURLE_HTTP_RETURNED_ERROR:
            return ErrorKind::ProtocolError;
        default:
            return ErrorKind::ConnectionError;
    }
}

} // namespace

// ============================================================================
// NetThread
// ============================================================================

NetThread::NetThread(std::shared_ptr<NetFile> task,
                     int64_t start, int64_t end, int64_t done)
    : task_keepalive_(std::move(task)), task_(task_keepalive_.get()),
      start_(start), initial_done_(done), end_(end) {
    done_.store(done, std::memory_order_relaxed);
}

NetThread::NetThread(NetFile* task, int64_t start, int64_t end, int64_t done)
    : NetThread(task ? task->shared_from_this() : std::shared_ptr<NetFile>{},
                start, end, done) {}

NetThread::~NetThread() = default;

void NetThread::markExecutionSettled() {
    const uint64_t epoch = execution_epoch_.load(std::memory_order_acquire);
    uint64_t settled = transport_settled_epoch_.load(std::memory_order_acquire);
    while (settled < epoch &&
           !transport_settled_epoch_.compare_exchange_weak(
               settled, epoch, std::memory_order_acq_rel, std::memory_order_acquire)) {}
    if (settled >= epoch) return;

    // 第一阶段：curl callback/worker 已退出，先移走本轮 keepalive。report 期间
    // completion_reported_epoch 仍落后，因此 Engine::purgeTask 不能销毁 LoaderDownload。
    // report 可能同步 prepare 新 epoch；下面只发布捕获到的旧 epoch，绝不污染新轮次。
    std::shared_ptr<NetFile> owner;
    {
        std::lock_guard<std::mutex> lk(execution_mu_);
        owner = std::move(task_keepalive_);
    }
    if (owner) owner->reportThreadFinished(this);

    uint64_t reported = completion_reported_epoch_.load(std::memory_order_acquire);
    while (reported < epoch &&
           !completion_reported_epoch_.compare_exchange_weak(
               reported, epoch, std::memory_order_release, std::memory_order_acquire)) {}
}

bool NetThread::prepareForRetryExecution() {
    uint64_t epoch = execution_epoch_.load(std::memory_order_acquire);
    if (transport_settled_epoch_.load(std::memory_order_acquire) < epoch) return false;
    if (!execution_epoch_.compare_exchange_strong(
            epoch, epoch + 1, std::memory_order_acq_rel, std::memory_order_acquire)) {
        return false;
    }

    try {
        std::lock_guard<std::mutex> lk(execution_mu_);
        task_keepalive_ = task_->shared_from_this();
    } catch (...) {
        transport_settled_epoch_.store(epoch + 1, std::memory_order_release);
        completion_reported_epoch_.store(epoch + 1, std::memory_order_release);
        return false;
    }

    // 文件级 retry 是一个全新的执行 epoch。旧实现只更新生命周期 epoch，却把
    // retry_count/deadline/not_before 原样带入下一轮：首轮长下载一旦用完 5 分钟绝对
    // deadline，后续 8 轮文件重试会在 run() 入口全部瞬间报 budget exhausted。
    // 这里重置的是“连续无有效进度”预算，不改 done_，因此已落盘字节仍会 Range 续传。
    retry_count_.store(0, std::memory_order_release);
    retry_delay_ms_.store(0, std::memory_order_release);
    retry_deadline_ms_.store(0, std::memory_order_release);
    retry_not_before_ms_.store(0, std::memory_order_release);
    const int64_t current_done = done_.load(std::memory_order_acquire);
    speed_.last_ts_ms.store(0, std::memory_order_release);
    speed_.last_done.store(current_done, std::memory_order_release);
    speed_.last_speed_bps.store(0, std::memory_order_release);
    transfer_start_ms_.store(0, std::memory_order_release);
    last_data_receive_ms_.store(0, std::memory_order_release);
    current_source_id_.store(-1, std::memory_order_release);
    AMCL_LOG_I(LOG_TAG,
        "retry epoch reset: epoch=%{public}llu done=%{public}lld no-progress budget renewed",
        (unsigned long long)(epoch + 1), (long long)current_done);
    return true;
}

bool NetThread::tryBeginAttempt(int max_attempts) {
    constexpr int64_t kRetryLifetimeMs = 5 * 60 * 1000LL;
    const int64_t now = nowMs();
    int64_t deadline = retry_deadline_ms_.load(std::memory_order_acquire);
    if (deadline == 0) {
        int64_t expected = 0;
        const int64_t proposed = now + kRetryLifetimeMs;
        if (retry_deadline_ms_.compare_exchange_strong(expected, proposed,
                                                       std::memory_order_acq_rel,
                                                       std::memory_order_acquire)) {
            deadline = proposed;
        } else {
            deadline = expected;
        }
    }
    if (now >= deadline) return false;

    int old = retry_count_.load(std::memory_order_acquire);
    while (old < max_attempts) {
        if (retry_count_.compare_exchange_weak(old, old + 1,
                                               std::memory_order_acq_rel,
                                               std::memory_order_acquire)) {
            return true;
        }
    }
    return false;
}

bool NetThread::addRetryDelayMs(int64_t delay_ms, int64_t total_budget_ms) {
    if (delay_ms < 0) delay_ms = 0;
    const int64_t deadline = retry_deadline_ms_.load(std::memory_order_acquire);
    const int64_t now = nowMs();
    if (deadline > 0 && (now >= deadline || delay_ms > deadline - now)) return false;

    int64_t old = retry_delay_ms_.load(std::memory_order_acquire);
    while (true) {
        if (old > total_budget_ms || delay_ms > total_budget_ms - old) return false;
        if (retry_delay_ms_.compare_exchange_weak(old, old + delay_ms,
                                                  std::memory_order_acq_rel,
                                                  std::memory_order_acquire)) return true;
    }
}

void NetThread::deferUntilMs(int64_t when_ms) {
    int64_t old = retry_not_before_ms_.load(std::memory_order_acquire);
    while (old < when_ms &&
           !retry_not_before_ms_.compare_exchange_weak(old, when_ms,
                                                       std::memory_order_acq_rel,
                                                       std::memory_order_acquire)) {
    }
}

DownloadExceptionPtr NetThread::writeFailure(const std::string& url_context) const {
    int e = writeErrno();
    if (e == 0) return nullptr;
    // H-08：write callback 保存的 errno 优先决定 CURLE_WRITE_ERROR 的本地故障类型。
    // 这些错误由目标存储产生，调用方必须终止本段且绝不能惩罚下载源。
    ErrorKind kind = ErrorKind::FileIoError;
    if (e == ENOSPC) {
        kind = ErrorKind::DiskFullError;
#ifdef EDQUOT
    } else if (e == EDQUOT) {
        kind = ErrorKind::QuotaExceededError;
#endif
    } else if (e == EIO) {
        kind = ErrorKind::StorageIoError;
    }
    auto ex = makeException(kind, "pwrite failed errno=" + std::to_string(e));
    ex->native_code = e;
    ex->url_context = url_context;
    return ex;
}

DownloadExceptionPtr NetThread::error() const {
    std::lock_guard<std::mutex> lk(last_error_mu_);
    return last_error_;
}

void NetThread::setError(DownloadExceptionPtr ex) {
    std::lock_guard<std::mutex> lk(last_error_mu_);
    last_error_ = std::move(ex);
}

NetSourcePtr NetThread::lastUsedSource() const {
    std::lock_guard<std::mutex> lk(last_used_source_mu_);
    return last_used_source_;
}

void NetThread::setLastUsedSource(NetSourcePtr src) {
    std::lock_guard<std::mutex> lk(last_used_source_mu_);
    last_used_source_ = std::move(src);
}

/**
 * ⚠️ 2026-07-29 修复「UI 显示 5MB/s，实际只有几十 KB/s」：
 *   速度窗口只在 curl 的 progress_callback 里更新（每 200ms 一次），而
 *   `last_speed_bps` 过去是**无条件返回最后一次算出的值**、没有任何过期判定。
 *   于是一旦该段的传输停止推进（429 被拒后退避 sleep、TTFB 长时间等待、
 *   段已下完但线程尚未 settle、换源之间的间隙），progress_callback 不再被调用，
 *   这个值就**永久冻结在最后的峰值**上。
 *   NetFile::sumRecentSpeedBps 又把所有 Downloading/Connecting/Reading 段的值相加
 *   —— 16 个段各冻结一个历史峰值，聚合出的数字可以比真实吞吐高一个数量级。
 *   真机实测：UI 报 5MB/s，而 .part 文件实测只涨 41~46KB/s（差 20 倍以上）。
 *   修法：读取时做**新鲜度判定**。超过 kSpeedStaleMs 未更新即视为 0；
 *   处于 (200ms, kSpeedStaleMs] 之间则按经过时间线性衰减，避免数字忽然跳变。
 */
int64_t NetThread::recentSpeedBps() const {
    constexpr int64_t kSpeedStaleMs = 1500;
    const int64_t last_ts = speed_.last_ts_ms.load(std::memory_order_relaxed);
    if (last_ts <= 0) return 0;
    const int64_t age = nowMs() - last_ts;
    if (age >= kSpeedStaleMs) return 0;      // 久未更新 = 这条连接此刻没在搬数据
    const int64_t bps = speed_.last_speed_bps.load(std::memory_order_relaxed);
    if (bps <= 0) return 0;
    if (age <= 300) return bps;              // 窗口内的新鲜采样，直接用
    // 线性衰减：age 从 300ms → kSpeedStaleMs 时权重 1 → 0。
    const int64_t span = kSpeedStaleMs - 300;
    return bps * (span - (age - 300)) / span;
}

int64_t NetThread::recentSpeedBpsRaw() const {
    return speed_.last_speed_bps.load(std::memory_order_relaxed);
}

void NetThread::abort() {
    aborted_.store(true, std::memory_order_release);
}

int64_t NetThread::shrinkEndTo(int64_t new_end) {
    std::lock_guard<std::mutex> boundary_lk(write_boundary_mu_);
    // 边界修改与 onWrite 的边界读取+pwrite 共用同一锁；返回后旧段不可能再写新段区间。
    int64_t old = end_.load(std::memory_order_acquire);
    if (old < start_) return -1;
    int64_t done = done_.load(std::memory_order_relaxed);
    if (done > INT64_MAX - start_) return -1;
    int64_t cur = start_ + done;
    if (new_end < cur || new_end >= old) return -1;
    end_.store(new_end, std::memory_order_release);
    ++boundary_generation_;
    return old;
}

// ----------------------------------------------------------------------------
// curl callbacks (C ABI)
// ----------------------------------------------------------------------------

size_t NetThread::onWrite(char* ptr, size_t sz, size_t nmemb, void* userdata) {
    auto* self = static_cast<NetThread*>(userdata);
    if (self->aborted_.load(std::memory_order_relaxed)) {
        return 0;  // 让 curl 中止
    }

    if (sz != 0 && nmemb > std::numeric_limits<size_t>::max() / sz) return 0;
    const size_t requested = sz * nmemb;
    if (requested == 0) return 0;

    // ⚠️ 2026-07-31：丢弃 3xx 重定向响应体（如 "302 Found"/"307" 的 HTML body）。
    //   手动 follow（CURLOPT_FOLLOWLOCATION=0）时它不属于目标文件，写入会污染 done_/SHA1，
    //   迫使 follow 时 resetDone() 归零 → 续传经重定向时把已下有效字节一起丢掉（进度倒退）。
    //   返回 requested 表示"已消费"，curl 照常结束本跳并交由下面的重定向循环 follow。
    {
        long resp_code = self->hdr_status_code_.load(std::memory_order_acquire);
        if (resp_code >= 300 && resp_code < 400) return requested;
    }

    // 第一次为无锁快速预检；end_ 只会缩小，因此这里只用于尽早拒绝已填满的段。
    int64_t current_done = self->done_.load(std::memory_order_relaxed);
    int64_t seg_end = self->end_.load(std::memory_order_acquire);
    if (seg_end >= self->start_) {
        int64_t segment_len = seg_end - self->start_ + 1;
        if (current_done >= segment_len) return 0;
    }

    int fd = self->task_->fd();
    if (fd < 0) {
        self->write_errno_.store(EBADF, std::memory_order_release);
        AMCL_LOG_E(LOG_TAG, "onWrite: fd invalid for %{public}s",
                     self->task_->localPath().c_str());
        return 0;
    }

    // H-动态边界：真正 pwrite 前必须在与 shrinkEndTo 相同的锁下二次读取 done/end。
    // 锁持续覆盖 pwrite 与 done 提交；因此 shrinkEndTo 一旦返回，旧段不可能再向新段越界写。
    std::lock_guard<std::mutex> boundary_lk(self->write_boundary_mu_);
    if (self->aborted_.load(std::memory_order_relaxed)) return 0;

    current_done = self->done_.load(std::memory_order_relaxed);
    seg_end = self->end_.load(std::memory_order_acquire);
    size_t n = requested;
    if (seg_end >= self->start_) {
        int64_t segment_len = seg_end - self->start_ + 1;
        if (current_done >= segment_len) return 0;
        int64_t room = segment_len - current_done;
        if (n > static_cast<uint64_t>(room)) n = static_cast<size_t>(room);
    }
    if (current_done < 0 || self->start_ > INT64_MAX - current_done) {
        self->write_errno_.store(EOVERFLOW, std::memory_order_release);
        return 0;
    }
    off_t offset = static_cast<off_t>(self->start_ + current_done);

    size_t written = 0;
    while (written < n) {
        ssize_t w = ::pwrite(fd, ptr + written, n - written, offset + written);
        if (w < 0) {
            if (errno == EINTR) continue;
            int saved = errno;
            // H-08：在离开 callback 前持久化 errno，后续 CURLE_WRITE_ERROR 必须优先读取它。
            self->write_errno_.store(saved, std::memory_order_release);
            AMCL_LOG_E(LOG_TAG, "onWrite: pwrite failed errno=%{public}d offset=%{public}lld",
                         saved, (long long)(offset + written));
            return 0;
        }
        if (w == 0) {
            self->write_errno_.store(EIO, std::memory_order_release);
            return 0;
        }
        written += static_cast<size_t>(w);
    }

    self->done_.fetch_add(written, std::memory_order_acq_rel);

    // v4.6: 增量 SHA1 — 下载同时计算，完成后直接取结果，零额外 I/O
    if (written > 0) {
        self->sha1_hasher_.update(ptr, written);
    }

    // 每次成功写盘都刷新“无有效进度”截止时间。旧实现从首次尝试起固定 5 分钟，
    // 即使持续下载也不延长；大文件正常传输超过 5 分钟后只要末尾断线，下一次续传
    // 就会在 run() 入口立即 budget exhausted。每 5 秒至多推进一次，避免逐块 CAS。
    constexpr int64_t kRetryNoProgressLifetimeMs = 5 * 60 * 1000LL;
    constexpr int64_t kRetryDeadlineRefreshStepMs = 5 * 1000LL;
    const int64_t receive_now = nowMs();
    self->last_data_receive_ms_.store(receive_now, std::memory_order_relaxed);
    int64_t deadline = self->retry_deadline_ms_.load(std::memory_order_acquire);
    const int64_t refreshed_deadline = receive_now + kRetryNoProgressLifetimeMs;
    while (deadline > 0 && refreshed_deadline - deadline >= kRetryDeadlineRefreshStepMs &&
           !self->retry_deadline_ms_.compare_exchange_weak(
               deadline, refreshed_deadline,
               std::memory_order_acq_rel, std::memory_order_acquire)) {
    }

    // 第一次写成功就翻到 Downloading（从 Reading/Connecting）
    NetState expected = NetState::Reading;
    if (!self->state_.compare_exchange_strong(expected, NetState::Downloading)) {
        NetState expected2 = NetState::Connecting;
        self->state_.compare_exchange_strong(expected2, NetState::Downloading);
    }

    return written;
}

size_t NetThread::onHeader(char* ptr, size_t sz, size_t nmemb, void* userdata) {
    auto* self = static_cast<NetThread*>(userdata);
    if (!self || (sz != 0 && nmemb > std::numeric_limits<size_t>::max() / sz)) return 0;
    size_t n = sz * nmemb;
    // 状态行 "HTTP/x.y CODE reason"：记录本响应状态码，供 onWrite 丢弃 3xx 重定向响应体。
    // libcurl 保证状态行/响应头先于响应体（onWrite）到达，故 onWrite 读到的必是本响应的码。
    if (n >= 5 && ptr[0] == 'H' && ptr[1] == 'T' && ptr[2] == 'T' && ptr[3] == 'P' && ptr[4] == '/') {
        const void* sp = memchr(ptr, ' ', n);
        if (sp != nullptr) {
            long code = std::strtol(static_cast<const char*>(sp) + 1, nullptr, 10);
            if (code > 0) self->hdr_status_code_.store(code, std::memory_order_release);
        }
        return n;
    }
    ParsedContentRange content_range;
    if (parseContentRangeHeader(ptr, n, content_range)) {
        self->response_content_range_seen_.store(true, std::memory_order_release);
        self->response_content_range_start_.store(content_range.start, std::memory_order_release);
        self->response_content_range_end_.store(content_range.end, std::memory_order_release);
        self->response_content_range_total_.store(content_range.total, std::memory_order_release);
        self->response_content_range_valid_.store(true, std::memory_order_release);
        return n;
    }
    std::string line(ptr, n);
    const char* name = "retry-after:";
    if (line.size() < 12) return n;
    for (size_t i = 0; i < 12; ++i) {
        char c = line[i];
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
        if (c != name[i]) return n;
    }
    std::string value = line.substr(12);
    size_t first = value.find_first_not_of(" \t");
    size_t last = value.find_last_not_of(" \t\r\n");
    if (first == std::string::npos || last < first) return n;
    value = value.substr(first, last - first + 1);
    int64_t delay_ms = 0;
    char* endp = nullptr;
    errno = 0;
    long long seconds = std::strtoll(value.c_str(), &endp, 10);
    if (errno == 0 && endp && *endp == '\0' && seconds >= 0) {
        delay_ms = seconds > 86400 ? 86400000 : seconds * 1000;
    } else {
        time_t when = curl_getdate(value.c_str(), nullptr);
        time_t now = std::time(nullptr);
        if (when > now) delay_ms = std::min<int64_t>(86400000, static_cast<int64_t>(when - now) * 1000);
    }
    if (delay_ms > 0) self->response_retry_after_ms_.store(delay_ms, std::memory_order_release);
    return n;
}

int NetThread::onProgress(void* userdata, int64_t /*dltotal*/, int64_t /*dlnow*/,
                          int64_t /*ultotal*/, int64_t /*ulnow*/) {
    auto* self = static_cast<NetThread*>(userdata);
    if (self->aborted_.load(std::memory_order_relaxed)) {
        return 1;  // 非 0 返回让 curl 中止并返回 CURLE_ABORTED_BY_CALLBACK
    }

    // 滑动窗口速度：每 200ms 更新一次
    int64_t now = nowMs();
    int64_t last = self->speed_.last_ts_ms.load(std::memory_order_relaxed);
    if (now - last >= 200) {
        int64_t last_done = self->speed_.last_done.load(std::memory_order_relaxed);
        int64_t curr_done = self->done_.load(std::memory_order_relaxed);
        int64_t diff_bytes = curr_done - last_done;
        int64_t diff_ms    = now - last;
        int64_t bps = (diff_ms > 0) ? (diff_bytes * 1000) / diff_ms : 0;
        // CAS 避免多 callback 并发覆盖
        if (self->speed_.last_ts_ms.compare_exchange_strong(last, now)) {
            self->speed_.last_done.store(curr_done, std::memory_order_release);
            self->speed_.last_speed_bps.store(bps, std::memory_order_release);
        }

        // ⚠️ 2026-07-30 新增：僵尾连接抢占（endgame straggler preemption）。
        //
        //   现有两道看门狗都拦不住"活着但几乎不动"的连接：
        //     · curl LOW_SPEED 是 1KB/s 绝对地板（多 Range 路径），7KB/s 安全过关；
        //     · 下面的 stall 看门狗要求 20s **零字节**，7KB/s 每秒都在喂它。
        //   真机实测（2026-07-30 23:36:32~23:38:05，client.jar 39MB / 92.5s）：
        //     `bmclapi KBps=7 total_ms=82980`（单连接跑 83 秒）、`KBps=56 total_ms=45305`、
        //     `KBps=52 total_ms=50439`，而 23:37:08 → 23:38:05 有 **57 秒零动作**。
        //   即 92.5s 里约 57s 被 3~4 条僵尾独占，同一次里健康连接是 300~570KB/s、
        //   BMCLAPI 热连接峰值 4552KB/s，差两个数量级。
        //
        //   处置：主动 abort 这条连接。run() 会把 CURLE_ABORTED_BY_CALLBACK 归一成
        //   Timeout（瞬时网络错误）→ 换源/重连并从 done_ 续传，**已落盘字节不丢**；
        //   因为本次 attempt 有实际字节，也不会计入主机熔断。
        //
        //   安全条件（缺一不做，避免把正常慢速网络下的唯一连接掐死）：
        //     1) 已经收到过数据（done>0）—— 零字节的挂死交给 stall 看门狗；
        //     2) 本轮 transfer 已跑满 15s，给慢启动/高 TTFB 充分 ramp 时间；
        //     3) 近期速度低于 32KB/s 地板；
        //     4) 本段是 Range 段且剩余 > 512KB —— 快收尾的段让它跑完更划算；
        //     5) 文件还有 >=2 个段在传输 —— 单段文件绝不自杀（对齐 PCL2
        //        `ModNet.vb:1103` 的 `Th.Source.SingleThread Is Nothing` 豁免）；
        //     6) **相对**判据：本段速度不到该文件聚合速度的 1/6。这一条最关键 ——
        //        它保证「整条链路本来就慢」时不会互相误杀（此时每段都接近平均值，
        //        比值条件不成立），只在**同一文件里存在明显快慢分化**时才抢占。
        //        实测那次正是分化：健康段 300~570KB/s、BMCLAPI 热连接峰值 4552KB/s，
        //        僵尾 7~56KB/s，差两个数量级。
        static constexpr int64_t kZombieMinRunMs       = 15 * 1000;
        static constexpr int64_t kZombieSpeedFloorBps  = 32 * 1024;
        static constexpr int64_t kZombieMinRemainBytes = 512 * 1024;
        static constexpr int64_t kZombieAggregateRatio = 6;
        if (curr_done > 0 && bps >= 0 && bps < kZombieSpeedFloorBps) {
            const int64_t seg_end = self->end_.load(std::memory_order_acquire);
            const int64_t started = self->transfer_start_ms_.load(std::memory_order_relaxed);
            const int64_t remain = (seg_end >= self->start_)
                ? (seg_end - (self->start_ + curr_done) + 1) : -1;
            if (started > 0 && now - started >= kZombieMinRunMs &&
                remain > kZombieMinRemainBytes &&
                self->state_.load(std::memory_order_relaxed) == NetState::Downloading &&
                self->task_ != nullptr && self->task_->activeSegmentCount() >= 2) {
                const int64_t file_bps = self->task_->sumRecentSpeedBps();
                if (bps * kZombieAggregateRatio < file_bps) {
                    AMCL_LOG_W(LOG_TAG,
                        "zombie segment preempted: %{public}lldB/s (file %{public}lldB/s) "
                        "for %{public}lldms, remain=%{public}lldB seg=[%{public}lld-%{public}lld], "
                        "switching connection",
                        (long long)bps, (long long)file_bps, (long long)(now - started),
                        (long long)remain, (long long)self->start_, (long long)seg_end);
                    return 1;  // 非 0 → curl 返回 CURLE_ABORTED_BY_CALLBACK
                }
            }
        }
    }

    // 5 秒无数据主动断线 —— 但仅对小文件（assets，有大量备选源可快速切换）。
    // 对较大的单文件（模组/库，通常只有镜像+官方两个源、且常单连接），5s 太激进：
    // 弱网下一次 >5s 的卡顿就会掐掉一个已下到一半的连接，反复重置导致永远下不完
    // （对齐 PCL2：5s 快切只在有备选线程时用，主连接给 15~30s 容忍）。大文件用 20s，
    // 真正死连接仍由 curl 的 LOW_SPEED_LIMIT(1KB/s 持续 15s) 兜底掐断。
    int64_t fsz = self->task_->fileSize();
    int64_t stall_ms = (fsz > 0 && fsz < 1024 * 1024) ? 5000 : 20000;
    // ⚠️ 2026-07-29 修复「下载卡在 95%、速度 0、取消重试仍卡同一处」：
    //   基线过去只有 last_data_receive_ms_（仅 onWrite 里更新），于是**一个字节都没收到过的
    //   连接 last_recv 恒为 0**，`last_recv > 0` 直接让看门狗失效。这种段既不推进 done，
    //   也永远不返回 1，于是：
    //     · curl 的 LOW_SPEED 看门狗也救不了——它按"平均速度"算，而这条连接连响应体都没开始，
    //       在高并发路径下（JDK：LOW_SPEED 4KB/s×30s）实测可以长期挂住不被掐；
    //     · NetFile 只在**所有**段 settle 后才 onAllThreadsDone，一条永不返回的段
    //       就让整个文件永远停在 Downloading → UI 卡在最后几十 KB、速度 0、没有终态；
    //     · 用户取消后 .amcl.part/meta 保留，重试时剩余段又落到同样的坏连接 → 卡在同一百分比。
    //   修法：基线取 max(最后收到数据, 本次 transfer 开始)。这样"连上但一直不吐字节"的段
    //   也会在 stall_ms 后被掐断，走正常的换源/重试路径。
    int64_t last_recv = self->last_data_receive_ms_.load(std::memory_order_relaxed);
    int64_t baseline = last_recv > 0
        ? last_recv
        : self->transfer_start_ms_.load(std::memory_order_relaxed);
    if (baseline > 0 && now - baseline > stall_ms) {
        NetState st = self->state_.load(std::memory_order_relaxed);
        // Connecting/Reading 也要掐：TTFB 卡死的连接同样必须让位，否则文件永不收敛。
        if (st == NetState::Downloading || st == NetState::Reading ||
            st == NetState::Connecting) {
            AMCL_LOG_W(LOG_TAG,
                "stall detected: no data for %{public}lldms (limit %{public}lldms, first_byte=%{public}d), aborting transfer",
                (long long)(now - baseline), (long long)stall_ms, last_recv > 0 ? 1 : 0);
            return 1;  // 非 0 → curl 返回 CURLE_ABORTED_BY_CALLBACK
        }
    }

    return 0;
}

// ----------------------------------------------------------------------------
// 单次 perform（一个 source 一次尝试）
// ----------------------------------------------------------------------------

DownloadExceptionPtr NetThread::performOnce(NetSourcePtr source, CURL* easy) {
    curl_easy_reset(easy);
    clearWriteErrno();
    // 每次尝试都重置 stall 看门狗基线：首字节到达前用它计时，避免"连上不吐字节"的连接
    // 永远挂住（见 progress_callback 里的 baseline 计算）。
    transfer_start_ms_.store(nowMs(), std::memory_order_relaxed);
    last_data_receive_ms_.store(0, std::memory_order_relaxed);
    // 每次尝试独立判定"是否该换地址族再试"，不能继承上一次的结论。
    family_retry_pending_.store(false, std::memory_order_release);
    const auto resetResponseHeaders = [this]() {
        response_retry_after_ms_.store(0, std::memory_order_release);
        response_content_range_seen_.store(false, std::memory_order_release);
        response_content_range_valid_.store(false, std::memory_order_release);
        response_content_range_start_.store(-1, std::memory_order_release);
        response_content_range_end_.store(-1, std::memory_order_release);
        response_content_range_total_.store(-1, std::memory_order_release);
        // 每跳（含首次）都清零本响应状态码；onHeader 收到状态行后再填入。这样 onWrite
        // 对 3xx 的丢弃判定只反映"当前这一跳"，重定向后的最终 200/206 能正常写入。
        hdr_status_code_.store(0, std::memory_order_release);
    };
    resetResponseHeaders();

    // v4.3: 手动处理 302 重定向。不让 curl 自动 follow，而是在 follow 前
    // 检查目标主机是否在全局坏主机黑名单中，避免白等 5s 超时。
    std::string actual_url = source->url;

    // ============================================================
    //  加速网关改写（2026-08-01）
    // ============================================================
    // 用户在设置里打开「加速下载」后，官方源 URL 在这里被改写成经由网关的地址。
    // 放在这一层的原因：引擎会换源/重试/跟随重定向，改写必须贴着**真正发出的那次请求**。
    // 任何一步不满足（未启用 / 非官方源 / 票据过期 / 网关熔断中）都保持原 URL，
    // 也就是自动回退直连 —— 加速只做增强，绝不降低可用性。
    bool via_relay = false;
    {
        std::string rewritten = relayRewriteUrl(actual_url);
        if (!rewritten.empty()) {
            actual_url = rewritten;
            via_relay = true;
        }
    }
    curl_easy_setopt(easy, CURLOPT_URL, actual_url.c_str());
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);  // 不自动 follow
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);        // 多线程必须
    // v4.3: 共享 DNS 缓存 + SSL session（减少 TLS 握手，assets 3000+ 文件请求同域名）
    CURLSH* sh = DownloadEngine::instance().curlShare();
    if (sh) {
        curl_easy_setopt(easy, CURLOPT_SHARE, sh);
    }
    // v4.3: 超时策略
    int64_t file_sz = task_->fileSize();
    bool is_small = (file_sz > 0 && file_sz < 1024 * 1024);
    // GitHub 代理被判定为多线程不友好时，NetFile 仍保留 max_connections>0，
    // 但实际段是 [0, EOF) 的单段 full GET。它不能继续套用“多 Range 慢启动”专用的
    // 4KB/s×30s 宽容策略，否则真机上 5KB/s 的劣质镜像会占位近一分钟。
    const bool is_single_full_get =
        start_ == 0 && end_.load(std::memory_order_acquire) < start_;
    // ⚠️ 2026-07-30 修复「加载器安装器下载 3.6MB 花 184 秒」：
    //   单段全量 GET 过去**固定** 16KB/s×15s 快速淘汰。那条策略的前提是"还有别的源可换"
    //   （原始场景：一堆 GitHub 代理里有一个 5KB/s 的劣质节点，掐掉换下一个稳赚）。
    //   但只剩一个可用源时，掐断不会让速度变快，只会白付一次 TTFB：
    //     真机 hdc 2026-07-30 20:55:45~20:58:45，NeoForge installer（BMCLAPI 无此 beta →
    //     仅 maven.neoforged.net 可用）稳定 8~24KB/s、全程没有一次断流，却被 16KB/s
    //     判定连掐 4 次（"Operation too slow. Less than 16384 bytes/sec transferred the
    //     last 15 seconds"），每次重连再付 1.6~5.4s TTFB，3.60MB 走了 184.1s。
    //   PCL2 在同样情形下**完全不掐**（Modules/Base/ModNet.vb:1102-1105）：
    //     If Th.LastReceiveTime > 0 AndAlso DeltaTime > 5000 AndAlso DeltaTime > RealDataCount
    //        AndAlso Th.Source.SingleThread Is Nothing Then  '单线程下载豁免
    //   —— 阈值约 1KB/s、判据是"单个数据包间隔 > 5s"，且单线程模式整条豁免。
    //   这里取同样语义：只有**存在备选源**时才保留 16KB/s 快淘汰；只剩一个源就退回
    //   1KB/s 地板，真死连接由 onProgress 的 stall 看门狗（20s 一个字节都没有）兜住。
    const bool has_alternate_source = countUsableSources(task_) > 1;
    const long low_speed_floor_bps =
        (is_single_full_get && has_alternate_source) ? 16L * 1024L : 1024L;
    // 连接超时。⚠️ 2026-07-31：6s→12s（真机 cdn-alt.modrinth.com 实测数据驱动）。
    //   劣质跨境路由（模组真机：cdn-alt 解析到 203.10.96.211，RTT 395ms + 丢包）上，
    //   TCP+TLS 握手需多次重传，connect_ms 实测在 0~5387ms 剧烈波动。旧的 6s 上限把
    //   "5~6s 才能建立"的连接在门口掐死（日志现象：rc=28 "SSL connection timeout"、
    //   done=0、addBadHost cdn-alt fail N/12），5 段并发握手竞争进一步放大失败率。
    //   放宽到 12s 让这类慢连接得以建立（openssl 无连接超时时同一源能下）。代价——死镜像
    //   多等几秒——由 addBadHost 主机熔断（普通 3 次 / 受保护 12 次）兜底；且 GitHub 代理/
    //   BMCLAPI 已被 isMultiThreadUnfriendlyHost 强制单段，放宽只影响那一条连接。
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT, is_small ? 8L : 12L);
    curl_easy_setopt(easy, CURLOPT_LOW_SPEED_LIMIT, low_speed_floor_bps);
    curl_easy_setopt(easy, CURLOPT_LOW_SPEED_TIME, is_small ? 10L : 15L);
    if (is_small) {
        curl_easy_setopt(easy, CURLOPT_TIMEOUT, 20L);  // 小文件总超时 20s（5s连接+15s传输足够）
    } else {
        curl_easy_setopt(easy, CURLOPT_TIMEOUT, 0L);   // 大文件不设总超时
    }
    // v7.5：真正的高并发 Range 路径低速看门狗放宽到 4KB/s×30s，避免高 TTFB
    // 让短分段反复 thrash；单段 full GET 则保留上面的 16KB/s×15s 快速淘汰策略。
    if (task_->isHighParallel() && !is_single_full_get) {
        curl_easy_setopt(easy, CURLOPT_LOW_SPEED_LIMIT, 4096L);   // 4KB/s
        curl_easy_setopt(easy, CURLOPT_LOW_SPEED_TIME, 30L);      // 30s
    }
    curl_easy_setopt(easy, CURLOPT_FAILONERROR, 1L);         // HTTP 4xx/5xx 返回错误
    // v6.2：高吞吐调优。设备实测——平板浏览器单连接对 cdn.modrinth.com 可达 5MB/s，
    // 但本引擎仅 ~160KB/s/连接。根因是 TCP 接收窗口没涨起来：① 之前每段强制全新连接
    //（FRESH_CONNECT），256KB 小段还没走完 TCP 慢启动就结束，窗口永远小→已去掉，改回连接复用，
    // 让长连接的窗口在多段之间持续 ramp；② 默认 16KB 接收缓冲太小，app 排空慢→内核不放大窗口，
    // 改大到 512KB；③ 显式放大 SO_RCVBUF（见 NetThread::sockoptCb），覆盖高 RTT(中国→Cloudflare)
    // 的带宽时延积。
    //
    // ⚠️ 2026-07-30：判据从「高并发模式（模组/JDK）」改为「高并发模式**或**大文件」。
    //
    //   这套调优在 1000182 就实测有效，但一直被 `isHighParallel()` 门控住，于是 MC 原版的
    //   client.jar / 大 library **从来没享受到**，07-29 把 isHighParallel 收窄成
    //   `max_connections > piece_limit` 之后连 client 的 maxConnections=4 也进不去。
    //
    //   决定性对照（2026-07-30，真机 hdc，同一设备同一网络同一源，零 AMCL 代码）：
    //     设备 shell 裸 `openssl s_client` 单连接 GET piston-data.mojang.com 的 client.jar
    //       → 39,193,950 bytes / 27.8s = **1378 KB/s**
    //     同一次安装里我们引擎对同一 URL 的 `perform PERF`
    //       → 单连接平均 **487 KB/s**（区间 92~1241）
    //   即我们的单连接吞吐只有裸 HTTPS 的 ~35%。两处差异正是这里被跳过的三项 + 下面的
    //   HTTP 版本：裸 openssl 是纯 HTTP/1.1 + 内核自适应窗口；我们是 h2（NONE 时 libcurl
    //   默认协商 h2）+ 16KB 接收缓冲，per-stream 流控窗口固定 64KB → 64KB/RTT 天花板。
    //
    //   为什么用**文件大小**而不是继续用并发模式做判据：这三项的收益来自"让单条 TCP 连接
    //   的窗口 ramp 到 BDP"，只有传输时间足够长才 ramp 得起来；而代价（每 socket 申请 4MB
    //   SO_RCVBUF）在海量小文件下会被放大 64 倍。assets（3000+ 个、多数 <1MB）与多数
    //   library 保持原路径不变，行为零改动；client.jar / 大 library / JDK / 模组进新路径。
    static constexpr int64_t kThroughputTuningMinBytes = 4 * 1024 * 1024;
    const bool tune_throughput =
        task_->isHighParallel() || (file_sz >= kThroughputTuningMinBytes);
    if (tune_throughput) {
        curl_easy_setopt(easy, CURLOPT_BUFFERSIZE, 512L * 1024L);
        curl_easy_setopt(easy, CURLOPT_TCP_NODELAY, 1L);
        // v7：显式放大 socket 接收缓冲，强制内核用大 TCP 窗口（修复单连接卡在 ~21KB/s 的
        // 小窗口问题，见 sockoptEnlargeRcvbuf 注释）。
        curl_easy_setopt(easy, CURLOPT_SOCKOPTFUNCTION, sockoptEnlargeRcvbuf);
    }
    // 1. server 若对 Range 请求返回压缩，Content-Length 是压缩后大小，
    //    curl 解压后实际字节和 Range 不一致，pwrite 位置会错乱
    // 2. MC 下载的 .jar 本身就是压缩归档，二次 gzip 几乎无收益
    // 之前 CURLOPT_ACCEPT_ENCODING="" 让 server 返回 gzip，导致 thread 0
    // 的 Range 请求被 server 以 HTTP 200 回应（忽略 Range），造成数据混乱。

    // 证书校验：OHOS 没有标准 /etc/ssl/certs/，用 ArkTS 层抽到 filesDir 的
    // Mozilla ca-bundle（rawfile/cacert.pem）。见 download/config.{h,cpp}。
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);
    std::string ca_path = getCaBundlePath();
    if (!ca_path.empty()) {
        curl_easy_setopt(easy, CURLOPT_CAINFO, ca_path.c_str());
    }

    // Track the byte offset represented by the final request. A server returning 200 to
    // any resumed request (including start=0, done>0) sends bytes from offset zero and
    // would otherwise be appended into the staging file.
    bool range_was_requested = false;
    int64_t requested_offset = 0;
    int64_t requested_end = -1;
    const auto applyCurrentRange = [&]() {
        const int64_t current_done = done_.load(std::memory_order_acquire);
        const int64_t request_end = end_.load(std::memory_order_acquire);
        requested_offset = (current_done >= 0 && start_ <= INT64_MAX - current_done)
            ? start_ + current_done : INT64_MAX;
        // Content-Range 必须与真正发出的 HTTP Range 对齐。动态拆分可能在
        // curl_easy_perform 期间缩短 end_，但服务端响应仍对应这里捕获的旧窗口。
        requested_end = request_end >= requested_offset ? request_end : -1;
        std::string range = buildRangeHeader(start_, request_end, current_done);
        range_was_requested = !range.empty();
        if (range_was_requested) curl_easy_setopt(easy, CURLOPT_RANGE, range.c_str());
    };
    applyCurrentRange();

    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, &NetThread::onWrite);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, this);
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, &NetThread::onHeader);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, this);
    curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, &NetThread::onProgress);
    curl_easy_setopt(easy, CURLOPT_XFERINFODATA, this);

    // 高吞吐路径固定 CURL_HTTP_VERSION_1_1：实测 h2 的 per-stream 流控窗口固定 64KB 反而
    // 限速（见 CHANGELOG 1000182），且独立 TCP 连接更能叠加吞吐。
    // 注：曾试用 CURL_HTTP_VERSION_2TLS 但因上述流控窗口问题回退，此处不再启用 h2。
    //
    // ⚠️ 2026-07-30：与上面的 tune_throughput 同一判据（高并发**或** >=4MiB）。
    //   `CURL_HTTP_VERSION_NONE` 在 libcurl 8.x 上等于"HTTPS 优先协商 h2"，于是 client.jar
    //   走 h2 被 64KB/RTT 钳死（RTT ~200ms → ~320KB/s，与实测单连接 487KB/s 同量级），
    //   而设备裸 HTTP/1.1 对同一 URL 能跑 1378KB/s。海量小文件仍用 NONE：它们单文件传输
    //   时间短、窗口本来 ramp 不起来，h2 的连接复用反而省握手。
    curl_easy_setopt(easy, CURLOPT_HTTP_VERSION,
                     tune_throughput ? CURL_HTTP_VERSION_1_1 : CURL_HTTP_VERSION_NONE);

    // ⚠️ 2026-07-31：每主机 IP 地址族选择（PCL2 DNSLookup 等价物）。
    //   实测依据（真机 hdc，裸 openssl，零本引擎代码）：同一个 1.2MB 模组
    //     cdn-alt.modrinth.com -6 → 0 字节 / 137ms 立刻失败（复测两次一致）
    //     cdn-alt.modrinth.com -4 → 1,205,063 字节 / 27.6s、50.4s
    //   而设备 DNS 对 cdn.modrinth.com 首选返回 IPv6。此前本引擎从不干预地址族，
    //   libcurl 按系统顺序优先 IPv6，于是每段都先在死 IPv6 上烧掉一次连接。
    //   见 engine.h `ipResolveFor` 上方注释与 PCL2 ModNet.vb:314-358。
    std::string family_host = extractHostForSlot(actual_url);
    long ip_resolve = DownloadEngine::instance().ipResolveFor(family_host);
    curl_easy_setopt(easy, CURLOPT_IPRESOLVE, ip_resolve);

    // User-Agent（很多镜像站靠 UA 判断）。
    // ⚠️ 网关要求 UA 以 "amcl/" 开头（用来挡其他软件盗用），这里的前缀不能改。
    curl_easy_setopt(easy, CURLOPT_USERAGENT, "amcl/0.1 (OHOS; libcurl/8.10.1)");

    // 加速网关鉴权头：票据 + 本次请求的持有证明签名。
    // 用 RAII 守卫保证 curl_slist 活过整个 curl_easy_perform 且必被释放
    // （重定向循环里会重新构建，见下方 follow 分支）。
    struct HeaderList {
        curl_slist* h = nullptr;
        ~HeaderList() { if (h) curl_slist_free_all(h); }
        void add(const std::string& s) { if (!s.empty()) h = curl_slist_append(h, s.c_str()); }
        void reset() { if (h) { curl_slist_free_all(h); h = nullptr; } }
    } relay_headers;

    const auto applyRelayAuth = [&](const std::string& url_for_sig) -> bool {
        relay_headers.reset();
        std::string a, t, n, s;
        // 下载线程恒为 GET（没有设置 CURLOPT_NOBODY），签名里的方法名固定 GET
        if (!relayBuildAuthHeaders("GET", url_for_sig, a, t, n, s)) return false;
        relay_headers.add(a);
        relay_headers.add(t);
        relay_headers.add(n);
        relay_headers.add(s);
        curl_easy_setopt(easy, CURLOPT_HTTPHEADER, relay_headers.h);
        return true;
    };

    if (via_relay) {
        if (!applyRelayAuth(actual_url)) {
            // 拿不到鉴权头（票据刚过期等）→ 放弃加速，回退到原始官方 URL
            AMCL_LOG_W(LOG_TAG, "relay auth unavailable, falling back to direct: %{public}s",
                       source->url.c_str());
            actual_url = source->url;
            via_relay = false;
            curl_easy_setopt(easy, CURLOPT_URL, actual_url.c_str());
        }
    }

    state_.store(NetState::Reading, std::memory_order_release);

    char err_buf[CURL_ERROR_SIZE] = {0};
    curl_easy_setopt(easy, CURLOPT_ERRORBUFFER, err_buf);

    CURLcode rc = curl_easy_perform(easy);

    long http_code = 0;
    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &http_code);

    // v4.3: 手动处理 302/301/307/308 重定向
    // 在 follow 前检查目标主机是否在全局坏主机黑名单中
    for (int redir = 0; redir < 5 && rc == CURLE_OK
            && (http_code == 301 || http_code == 302 || http_code == 307 || http_code == 308);
         ++redir) {
        char* redir_url = nullptr;
        curl_easy_getinfo(easy, CURLINFO_REDIRECT_URL, &redir_url);
        if (!redir_url || redir_url[0] == '\0') break;

        // 从 redir_url 提取 host
        std::string rurl(redir_url);
        size_t hs = rurl.find("://");
        if (hs != std::string::npos) {
            hs += 3;
            size_t he = rurl.find('/', hs);
            size_t pe = rurl.find(':', hs);
            if (pe != std::string::npos && (he == std::string::npos || pe < he)) he = pe;
            std::string rhost = rurl.substr(hs, he == std::string::npos ? std::string::npos : he - hs);

            if (DownloadEngine::instance().isBadHost(rhost)) {
                // 目标主机在黑名单中，立即返回错误，不浪费时间连接
                AMCL_LOG_W(LOG_TAG, "redirect to bad host %{public}s, skip: %{public}s",
                            rhost.c_str(), rurl.c_str());
                // ⚠️ 2026-07-30：把**这个源**一起冷却到该坏主机恢复为止。
                //   否则会死循环：源 URL 每次都 3xx 到同一台连不上的主机，我们只报一个
                //   可重试的 ConnectionError，源本身从未被标记不可用，pickBestSource 下一轮
                //   又挑中它 → 再付一次重定向 + 6s connect timeout。
                //   真机实测（2026-07-30 22:57~23:01，sodium-neoforge 1.2MB）：
                //   cdn.modrinth.com 对本设备返回 307 → cdn-alt.modrinth.com，引擎在 4 分钟
                //   里反复重试同一条必然 307 的 URL，镜像源迟迟轮不上。
                //
                // ⚠️ 2026-07-31 更正：这条注释原先写"设备裸 openssl 对 cdn-alt 也是 0 字节
                //   立刻失败，确认是网络侧不可达" —— **结论是错的**。补做地址族分离实测后：
                //     cdn-alt.modrinth.com  -6 → 0 字节 / 137ms（复测两次一致）
                //     cdn-alt.modrinth.com  -4 → 1,205,063 字节 / 27.6s 与 50.4s
                //   即它只是 **IPv6 不可达**，IPv4 完全可用。之所以会误判成整台主机不可达，
                //   正是因为本引擎当时完全不干预地址族、libcurl 按系统顺序优先 IPv6。
                //   现已引入每主机地址族选择（见 DownloadEngine::ipResolveFor）+ 族特异性
                //   失败不计入熔断（见 performOnce 的 family_retry_pending_），此路径应
                //   显著少走。
                //   用 extendCooldownUntil 而不是 is_failed：冷却会随坏主机熔断到期自动恢复，
                //   不会把一个只是暂时抽风的官方源永久废掉。
                const int64_t host_ready =
                    DownloadEngine::instance().badHostReadyAtMs(rhost);
                if (host_ready > 0) source->extendCooldownUntil(host_ready);
                // AMCL 关键修复：在返回前重置 done + SHA1。否则本次 perform 已把 302
                // 响应体（如 ~116 字节的 "302 Found" HTML）经 onWrite 写进文件、done_ 也
                // 随之前移；run() 收到 ConnectionError 后走 continue（不 resetDone），
                // 下一个源便从被污染的偏移 Range 续传 → 文件大小正确但前段是 302 垃圾
                // → SHA1 终检失败（典型：guava 等库 done 比实际多下 ~116 字节）。
                resetDone();
                auto ex = std::make_shared<DownloadException>();
                ex->kind = ErrorKind::ConnectionError;
                ex->native_code = 0;
                ex->http_status = http_code;
                ex->url_context = source->url;
                ex->message = "redirect to blacklisted host: " + rhost;
                return ex;
            }
        }

        // 目标主机不在黑名单，正常 follow
        actual_url = rurl;
        // ⚠️ 2026-07-31：不再 resetDone()。3xx 响应体已由 onWrite 依据 hdr_status_code_
        //   丢弃，不会污染 done_/SHA1，因此无需归零。保留 done_ 让"续传请求经
        //   cdn.modrinth.com→307→cdn-alt"后仍从断点继续 Range，消除旧实现每次重定向
        //   都把已下字节清零、从头重下的进度倒退死循环（真机 sodium 1.2MB 单连接 646s 的
        //   主要放大器之一）。数据正确性仍由每跳 Content-Range 校验 + 全文件 SHA1 终检兜底。
        // 每个 HTTP hop 都有独立响应头。若不清零，最终 206 缺失/错误 Content-Range
        // 时可能误用上一跳留下的值并错误通过区间校验；resetResponseHeaders 同时清零
        // hdr_status_code_，使下一跳的状态码由其自身状态行重新决定。
        resetResponseHeaders();
        curl_easy_reset(easy);
        curl_easy_setopt(easy, CURLOPT_URL, actual_url.c_str());
        curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
        curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
        CURLSH* sh2 = DownloadEngine::instance().curlShare();
        if (sh2) curl_easy_setopt(easy, CURLOPT_SHARE, sh2);
        int64_t fsz2 = task_->fileSize();
        bool small2 = (fsz2 > 0 && fsz2 < 1024 * 1024);
        // 与首次请求同一套连接超时（8s/12s）。这一跳才是**真正搬数据**的那次请求
        // （cdn.modrinth.com→307→cdn-alt 正是本次问题原型），若这里仍用 6s，等于把上面
        // 放宽到 12s 的修复完全抵消。
        curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT, small2 ? 8L : 12L);
        // 与首次请求同一套低速策略（含"只剩一个源就退回 1KB/s 地板"）。
        curl_easy_setopt(easy, CURLOPT_LOW_SPEED_LIMIT, low_speed_floor_bps);
        curl_easy_setopt(easy, CURLOPT_LOW_SPEED_TIME, small2 ? 10L : 15L);
        if (small2) curl_easy_setopt(easy, CURLOPT_TIMEOUT, 20L);
        else curl_easy_setopt(easy, CURLOPT_TIMEOUT, 0L);
        curl_easy_setopt(easy, CURLOPT_FAILONERROR, 1L);
        if (task_->isHighParallel() && !is_single_full_get) {
            // 与首次请求一致：只对真正多 Range 路径放宽到 4KB/s×30s。
            curl_easy_setopt(easy, CURLOPT_LOW_SPEED_LIMIT, 4096L);
            curl_easy_setopt(easy, CURLOPT_LOW_SPEED_TIME, 30L);
        }
        // 2026-07-30：传输层调优与 HTTP 版本必须与首次请求同判据，否则 302 之后（BMCLAPI
        // 几乎总是 302 到镜像节点）真正搬数据的那一跳又退回 16KB 缓冲 + h2 小窗口。
        if (tune_throughput) {
            curl_easy_setopt(easy, CURLOPT_BUFFERSIZE, 512L * 1024L);
            curl_easy_setopt(easy, CURLOPT_TCP_NODELAY, 1L);
            curl_easy_setopt(easy, CURLOPT_SOCKOPTFUNCTION, sockoptEnlargeRcvbuf);
        }
        curl_easy_setopt(easy, CURLOPT_HTTP_VERSION,
                         tune_throughput ? CURL_HTTP_VERSION_1_1 : CURL_HTTP_VERSION_NONE);
        // 重定向目标是**另一台**主机（cdn.modrinth.com → cdn-alt.modrinth.com 正是
        // 本次问题的原型），必须按新主机重新挑地址族；curl_easy_reset 已清掉上一跳的
        // CURLOPT_IPRESOLVE，这里不重设就退回系统默认（本设备 = 优先 IPv6）。
        family_host = extractHostForSlot(actual_url);
        ip_resolve = DownloadEngine::instance().ipResolveFor(family_host);
        curl_easy_setopt(easy, CURLOPT_IPRESOLVE, ip_resolve);

        // curl_easy_reset 已清掉上一跳的 CURLOPT_HTTPHEADER。
        // 若这一跳仍指向我们的网关（正常不会——网关自己在服务端跟随重定向，
        // 不会把 3xx 透给客户端；但源 URL 302 到官方源、再被改写的情况要兜住），
        // 必须重新签名：签名绑定 path，换了 URL 旧签名一定失效。
        via_relay = relayIsRelayUrl(actual_url);
        if (via_relay && !applyRelayAuth(actual_url)) {
            AMCL_LOG_W(LOG_TAG, "relay auth unavailable after redirect, aborting relay attempt");
            via_relay = false;
        }

        // 重新设置 CA、Range、callbacks 等
        curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L);
        curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);
        std::string ca2 = getCaBundlePath();
        if (!ca2.empty()) {
            curl_easy_setopt(easy, CURLOPT_CAINFO, ca2.c_str());
        }
        // 3xx 响应体已由 onWrite（依据 hdr_status_code_）丢弃，done_ 只含有效字节；
        // 这里按保留的 done_ 重设 Range，从断点续传，并让 HTTP-200 错位守卫保持同步。
        applyCurrentRange();
        curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, onWrite);
        curl_easy_setopt(easy, CURLOPT_WRITEDATA, this);
        curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, onHeader);
        curl_easy_setopt(easy, CURLOPT_HEADERDATA, this);
        curl_easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, onProgress);
        curl_easy_setopt(easy, CURLOPT_XFERINFODATA, this);
        curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 0L);
        err_buf[0] = '\0';
        curl_easy_setopt(easy, CURLOPT_ERRORBUFFER, err_buf);

        rc = curl_easy_perform(easy);
        http_code = 0;
        curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &http_code);
    }
    curl_off_t reported_cl = -1;
    curl_easy_getinfo(easy, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &reported_cl);
    curl_off_t size_download = -1;
    curl_easy_getinfo(easy, CURLINFO_SIZE_DOWNLOAD_T, &size_download);
    // v7：curl 自测的本次连接吞吐（字节/秒）与总耗时（微秒）—— 干净的单连接速度，
    // 不受我们进度采样/分段聚合干扰，用于定位"为什么单连接比系统栈慢"。
    curl_off_t curl_speed = -1;
    curl_easy_getinfo(easy, CURLINFO_SPEED_DOWNLOAD_T, &curl_speed);
    curl_off_t total_us = -1;
    curl_easy_getinfo(easy, CURLINFO_TOTAL_TIME_T, &total_us);
    curl_off_t conn_us = -1;
    curl_easy_getinfo(easy, CURLINFO_CONNECT_TIME_T, &conn_us);
    curl_off_t starttransfer_us = -1;
    curl_easy_getinfo(easy, CURLINFO_STARTTRANSFER_TIME_T, &starttransfer_us);

    // ⚠️ 2026-07-31：记录本次尝试的地址族结果（PCL2 RecordIPReliability，
    //   ModNet.vb:368-375：成功 +0.5 / 失败 -0.7，v = v*0.5 + result*0.5）。
    //   family_host 在重定向循环里已被更新为**最后真正连接的那台主机**，正是要打分的对象。
    {
        auto& fam_engine = DownloadEngine::instance();
        const bool fam_got_bytes = size_download > 0;
        const bool fam_unresolvable = (rc == CURLE_COULDNT_RESOLVE_HOST);
        // 首次请求 ip_resolve 是 WHATEVER（不盲猜），靠实际连接的 IP 反推走了哪一族。
        char* primary_ip = nullptr;
        curl_easy_getinfo(easy, CURLINFO_PRIMARY_IP, &primary_ip);
        const std::string fam_ip = (primary_ip && primary_ip[0] != '\0') ? primary_ip : "";
        fam_engine.noteFamilyOutcome(family_host, ip_resolve, fam_ip,
                                     rc == CURLE_OK || fam_got_bytes, fam_unresolvable);
        const long fam_used =
            (ip_resolve == CURL_IPRESOLVE_V4 || ip_resolve == CURL_IPRESOLVE_V6)
                ? ip_resolve : DownloadEngine::familyFromIp(fam_ip);
        // "连都没连上、一个字节没拿到" 这类失败极可能是族特异性的（本设备 cdn-alt 的
        // IPv6 就是 137ms 立刻失败）。此时另一族若还没试过，应当换族重试，而**不是**
        // 把整台主机记进全局熔断 —— 对齐 PCL2 的源禁用条件（ModNet.vb:1158-1163，
        // 里面没有任何"某一族连不上就废掉源"的条目）。由 run() 的 penalize_host 消费。
        const bool fam_connect_class_failure =
            rc != CURLE_OK && !fam_got_bytes &&
            (rc == CURLE_COULDNT_CONNECT || rc == CURLE_COULDNT_RESOLVE_HOST ||
             rc == CURLE_OPERATION_TIMEDOUT || rc == CURLE_SSL_CONNECT_ERROR ||
             rc == CURLE_RECV_ERROR || rc == CURLE_SEND_ERROR ||
             rc == CURLE_GOT_NOTHING || rc == CURLE_PARTIAL_FILE);
        family_retry_pending_.store(
            fam_connect_class_failure && fam_engine.hasUntriedFamily(family_host, fam_used),
            std::memory_order_release);
    }

    // ============================================================
    //  加速网关健康记账（2026-08-01）
    // ============================================================
    // 网关失败（鉴权被拒 / 5xx / 连不上）时记一次失败：连续 5 次即熔断 60s，
    // 期间 relayRewriteUrl 返回空 → 自动回退直连。这样"网关出问题"最多损失
    // 几次尝试，不会把整个下载拖死。
    if (via_relay) {
        const bool relay_ok = (rc == CURLE_OK) && http_code > 0 && http_code < 400;
        if (relay_ok) {
            relayNoteSuccess();
        } else {
            relayNoteFailure(static_cast<int>(http_code));
            AMCL_LOG_W(LOG_TAG,
                "relay request failed: http=%{public}ld rc=%{public}d url=%{public}s",
                http_code, (int)rc, actual_url.c_str());
            // 鉴权类失败（401/403）说明票据/签名有问题，重签一次也没用：
            // 直接把本次尝试判为失败让 run() 换源重试，届时熔断可能已生效 → 走直连。
        }
    }

    // v4.10：统一读一次 atomic end（自适应分段可能在途中缩小它），后续判定都用这个快照。
    int64_t seg_end = end_.load(std::memory_order_acquire);
    int64_t expected_len = seg_end >= start_ ? (seg_end - start_ + 1) : -1;
    int64_t current_done = done_.load(std::memory_order_relaxed);

    // 全量模式（end_ < 0）但 NetFile 知道文件大小：用 file_size 当 expected
    // 这样即使 curl 错判 rc=OK（实测 Mojang piston-data 上会发生），我们也能
    // 从 Content-Length 层面捕获 "少下了" 的情况。
    if (expected_len < 0) {
        int64_t fsz = task_->fileSize();
        if (fsz > 0) expected_len = fsz;
    }

    AMCL_LOG_D(LOG_TAG, "perform detail: url=%{public}s rc=%{public}d http=%{public}ld "
                "cl=%{public}lld size_dl=%{public}lld done=%{public}lld expected=%{public}lld",
                source->url.c_str(), (int)rc, http_code,
                (long long)reported_cl, (long long)size_download,
                (long long)current_done, (long long)expected_len);
    AMCL_LOG_D(LOG_TAG, "perform PERF: %{public}s KBps=%{public}lld total_ms=%{public}lld "
                "connect_ms=%{public}lld ttfb_ms=%{public}lld",
                source->url.c_str(), (long long)(curl_speed / 1024),
                (long long)(total_us / 1000), (long long)(conn_us / 1000),
                (long long)(starttransfer_us / 1000));

    // 每个 Range 响应都必须证明服务端返回的字节窗口与 pwrite 偏移一致。
    // 仅看 206 或 Content-Length 无法防止错误代理返回错位区间。
    if (range_was_requested && http_code == 206) {
        ParsedContentRange range;
        range.start = response_content_range_start_.load(std::memory_order_acquire);
        range.end = response_content_range_end_.load(std::memory_order_acquire);
        range.total = response_content_range_total_.load(std::memory_order_acquire);
        // 校验发送时捕获的请求窗口，而不是可能已被 shrinkEndTo 缩短的写入窗口。
        // 后者只决定本线程何时主动停写；不能追溯改变已经在途的 HTTP Range。
        if (!response_content_range_seen_.load(std::memory_order_acquire) ||
            !response_content_range_valid_.load(std::memory_order_acquire) ||
            !contentRangeMatches(range, requested_offset, requested_end, task_->fileSize())) {
            source->no_range_support.store(true, std::memory_order_release);
            resetDone();
            auto ex = makeException(ErrorKind::SizeMismatch,
                "invalid Content-Range for requested offset " + std::to_string(requested_offset));
            ex->native_code = static_cast<int>(rc);
            ex->http_status = http_code;
            ex->url_context = source->url;
            return ex;
        }
        source->range_verified.store(true, std::memory_order_release);
    }

    // A 200 response ignores Range. It is only byte-aligned when the requested offset is
    // zero; for resumed/open-ended segments it would append a full object after the saved
    // prefix and could be accepted without a checker.
    if (http_code == 200 && range_was_requested && requested_offset > 0) {
        source->no_range_support.store(true, std::memory_order_release);
        resetDone();
        auto ex = makeException(ErrorKind::SizeMismatch,
            "server ignored Range header for resumed request at offset " +
            std::to_string(requested_offset));
        ex->native_code = static_cast<int>(rc);
        ex->http_status = http_code;
        ex->url_context = source->url;
        AMCL_LOG_W(LOG_TAG,
            "perform DATA MISALIGNED: HTTP 200 for resumed Range offset=%{public}lld url=%{public}s",
            (long long)requested_offset, source->url.c_str());
        return ex;
    }

    // 成功分支 1：curl rc=OK 且段完整写满（典型 206 Partial Content）
    // 成功分支 2：段完整写满但 rc=CURLE_WRITE_ERROR（server 返回 200 全量，
    //             我们 onWrite 填满后主动截断，curl 报 write error）
    //
    // v4.2 关键修复：HTTP 200 + Range 请求 + start_ > 0 = 数据错位！
    // 场景：BMCLAPI 对 Range 请求返回 HTTP 200（忽略 Range，从文件头发全量数据）。
    // onWrite 截断到段长度后 done_ == expected_len，看似"成功"。但 pwrite 把
    // 来自 offset 0 的数据写到了 start_ 位置 → 文件内容错乱 → ChecksumMismatch。
    // 只有 start_ == 0 的段 0 能安全使用 200 数据（碰巧 offset 一致）。
    if (expected_len > 0 && current_done >= expected_len) {
        // 检查 HTTP 200 + 非段 0 的数据错位
        if (http_code == 200 && start_ > 0 && seg_end >= start_) {
            AMCL_LOG_W(LOG_TAG, "perform DATA MISALIGNED: %{public}s returned HTTP 200 "
                        "(not 206) for Range [%{public}lld-%{public}lld], data starts from "
                        "offset 0 but was pwritten to %{public}lld — must retry with different source",
                        source->url.c_str(), (long long)start_, (long long)seg_end, (long long)start_);
            // v4.2: 标记该源不支持 Range，pickBestSource 对后续非段0下载跳过它
            source->no_range_support.store(true, std::memory_order_release);
            // 重置 done + SHA1：已写入的数据是错的，下次重试会覆盖
            resetDone();
            auto ex = std::make_shared<DownloadException>();
            ex->kind = ErrorKind::SizeMismatch;
            ex->native_code = static_cast<int>(rc);
            ex->http_status = http_code;
            ex->url_context = source->url;
            ex->message = "server ignored Range header (HTTP 200 instead of 206), "
                          "data misaligned for segment starting at " + std::to_string(start_);
            return ex;
        }
        // v4.2: 段 0 收到 200（而非 206）：数据碰巧正确（从 offset 0 开始），
        // 但必须标记源不支持 Range，让同文件其他段避开它。
        if (http_code == 200 && seg_end >= start_) {
            source->no_range_support.store(true, std::memory_order_release);
            AMCL_LOG_I(LOG_TAG, "perform OK but source has no Range support (HTTP 200): %{public}s",
                        source->url.c_str());
        }
        AMCL_LOG_D(LOG_TAG, "perform OK (seg filled): %{public}s [%{public}lld-%{public}lld] "
                     "http=%{public}ld rc=%{public}d done=%{public}lld",
                     source->url.c_str(), (long long)start_, (long long)seg_end,
                     http_code, (int)rc, (long long)current_done);
        return nullptr;
    }

    // curl rc=OK 但 done < expected：server 提前 EOF / 少发数据 → size 不匹配
    if (rc == CURLE_OK && expected_len > 0) {
        auto ex = std::make_shared<DownloadException>();
        ex->kind = ErrorKind::SizeMismatch;
        ex->native_code = 0;
        ex->http_status = http_code;
        ex->url_context = source->url;
        ex->message = "server sent " + std::to_string(current_done) +
                      " bytes, expected " + std::to_string(expected_len);
        AMCL_LOG_W(LOG_TAG, "perform truncated: %{public}s: %{public}s",
                    source->url.c_str(), ex->message.c_str());
        return ex;
    }

    // 未知大小段（end_ < 0），curl rc=OK 即认为成功
    if (rc == CURLE_OK) {
        AMCL_LOG_D(LOG_TAG, "perform OK (no range): %{public}s http=%{public}ld done=%{public}lld",
                     source->url.c_str(), http_code, (long long)current_done);
        return nullptr;
    }

    // 写回失败优先于 curl 的 CURLE_WRITE_ERROR 分类；这是本地故障，不得惩罚源。
    if (auto write_ex = writeFailure(source->url)) {
        return write_ex;
    }

    // 失败：构造异常
    auto ex = std::make_shared<DownloadException>();
    ex->kind = mapCurlCode(rc);
    ex->native_code = static_cast<int>(rc);
    ex->http_status = http_code;
    ex->url_context = source->url;
    ex->message = err_buf[0] ? err_buf : curl_easy_strerror(rc);

    // 主机熔断必须由 run() 在比较本次 attempt 前后 done_ 后决定。这里不能只看
    // CURLcode：真机上的 gh.ddlc.top 已交付 82 MiB 后才 rc=56，旧逻辑仍无条件
    // addBadHost，导致下一任务绕去 0B/5KB/s 的坏镜像并等待近一分钟。

    AMCL_LOG_W(LOG_TAG, "perform FAIL: %{public}s: %{public}s (done=%{public}lld/%{public}lld)",
                source->url.c_str(), ex->message.c_str(),
                (long long)current_done, (long long)expected_len);
    return ex;
}

// ----------------------------------------------------------------------------
// 线程主入口
// ----------------------------------------------------------------------------

void NetThread::run(CURL* reusable_easy) {
    if (aborted_.load(std::memory_order_relaxed)) {
        state_.store(NetState::Aborted, std::memory_order_release);
        task_->reportThreadFinished(this);
        return;
    }

    // 断点续传短路：restoreFromMeta 对"已完成"的段创建 NetThread 时把 done
    // 设成了 length，这里直接上报 Finished，避免白白 curl_easy_init + HEAD。
    // 条件 end_ >= 0 是为了排除 HEAD 未完成（未知大小）的场景。
    if (end_.load(std::memory_order_acquire) >= 0 &&
        done_.load(std::memory_order_relaxed) >= length()) {
        state_.store(NetState::Finished, std::memory_order_release);
        task_->reportThreadFinished(this);
        return;
    }

    state_.store(NetState::Connecting, std::memory_order_release);

    // v4.2: 延迟 fd 管理——在真正需要下载时才 acquireFd，避免一次性耗尽 fd 配额
    int fd = task_->acquireFd();
    if (fd < 0) {
        int e = task_->fdError();
        ErrorKind kind = e == ENOSPC ? ErrorKind::DiskFullError :
#ifdef EDQUOT
                         e == EDQUOT ? ErrorKind::QuotaExceededError :
#endif
                         e == EIO ? ErrorKind::StorageIoError : ErrorKind::FileIoError;
        auto ex = makeException(kind, "acquireFd failed: " + task_->stagingPath() +
                                      " errno=" + std::to_string(e));
        ex->native_code = e;
        setError(ex);
        state_.store(NetState::Failed, std::memory_order_release);
        task_->reportThreadFinished(this);
        return;
    }
    // 确保所有退出路径都 releaseFd（RAII guard）
    bool fd_released = false;
    auto releaseFdGuard = [&]() {
        if (!fd_released) {
            fd_released = true;
            task_->releaseFd();
        }
    };

    // v4.4: 复用外部传入的 easy handle（保留连接池），仅在未传入时自行创建
    bool owns_easy = (reusable_easy == nullptr);
    CURL* easy = reusable_easy ? reusable_easy : curl_easy_init();
    if (!easy) {
        setError(makeException(ErrorKind::InternalError, "curl_easy_init returned NULL"));
        state_.store(NetState::Failed, std::memory_order_release);
        releaseFdGuard();
        task_->reportThreadFinished(this);
        return;
    }

    DownloadExceptionPtr last_ex;
    int same_source_size_mismatch_retries = 0;
    constexpr int kSameSourceRetryLimit = 3;

    for (int attempt = 0; ; ++attempt) {
        int64_t retry_deadline = retryDeadlineMs();
        if (retryCount() >= 30 ||
            (retry_deadline > 0 && nowMs() >= retry_deadline)) {
            last_ex = makeException(ErrorKind::ConnectionError, "retry budget exhausted");
            break;
        }
        if (aborted_.load(std::memory_order_relaxed)) {
            if (owns_easy) curl_easy_cleanup(easy);
            state_.store(NetState::Aborted, std::memory_order_release);
            releaseFdGuard();
            task_->reportThreadFinished(this);
            return;
        }

        // v4.2: 非段 0 的分段下载需要 Range 支持，跳过不支持 Range 的源
        // v6: 首次尝试用本段的首选源（多源轮询，段i→源i）；重试时回退 -1 按评分选最优源。
        const bool needs_range = requiresRangeSupport();
        NetSourcePtr src = task_->pickBestSource(needs_range,
            /*preferred_idx=*/(attempt == 0) ? preferred_source_idx_ : -1);
        if (!src) {
            int64_t ready = task_->nextSourceReadyMs(needs_range);
            int64_t now = nowMs();
            if (ready > now) {
                int64_t deadline = retryDeadlineMs();
                if (deadline > 0 && ready > deadline) {
                    last_ex = makeException(ErrorKind::ConnectionError,
                                            "source cooldown exceeds retry deadline");
                    break;
                }
                const int64_t wait_until = deadline > 0 ? std::min(ready, deadline) : ready;
                while (!aborted_.load(std::memory_order_acquire) && now < wait_until) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(
                        std::min<int64_t>(100, wait_until - now)));
                    now = nowMs();
                }
                continue;
            }
            last_ex = makeException(ErrorKind::ConnectionError,
                                    "no available sources (all failed)");
            break;
        }

        // ⚠️ 2026-07-29：每主机并发闸门（防 HTTP 429）。JDK 的 16 段若全压同一个
        //   GitHub 代理必被限流（真机 570~887 条 429）。这里在真正发请求前占名额，
        //   占不到就短暂让行并重新选源（其它镜像可能还有名额）。
        //   MultiDownloader 早有同款 host_limit_，worker 池路径此前完全没有。
        //   注意：必须放在 tryBeginAttempt **之前** —— 否则每次让行都白耗一次重试预算
        //   （上限 30 次），高并发下会迅速把预算耗尽而误报 "retry attempts exhausted"。
        const std::string slot_host = extractHostForSlot(src->url);
        if (!DownloadEngine::instance().tryAcquireHostSlot(slot_host)) {
            if (aborted_.load(std::memory_order_acquire)) continue;
            std::this_thread::sleep_for(std::chrono::milliseconds(120));
            continue;
        }

        if (!tryBeginAttempt(30)) {
            DownloadEngine::instance().releaseHostSlot(slot_host, false);
            last_ex = makeException(ErrorKind::ConnectionError, "retry attempts exhausted");
            break;
        }

        // v6: 记录本段当前使用的源，供 maybeGrowThreads 避让（防同源并发 Range 损坏）。
        current_source_id_.store(src->id, std::memory_order_relaxed);
        const int64_t attempt_done_before = done_.load(std::memory_order_acquire);
        AMCL_LOG_D(LOG_TAG,
            "attempt begin: source=%{public}s done=%{public}lld retry=%{public}d",
            src->url.c_str(), (long long)attempt_done_before, retryCount());

        auto ex = performOnce(src, easy);
        const int64_t attempt_done_after = done_.load(std::memory_order_acquire);
        const int64_t attempt_bytes = attempt_done_after > attempt_done_before
            ? attempt_done_after - attempt_done_before : 0;
        const bool user_aborted = aborted_.load(std::memory_order_acquire);

        // progress callback 的主动 stall 中止不是用户取消，先归一成 Timeout，确保下面的
        // attempt 进度分类、主机熔断和源级策略看到的是同一种瞬时网络错误。
        if (ex && ex->kind == ErrorKind::AbortedByUser && !user_aborted) {
            ex->kind = ErrorKind::Timeout;
            ex->message = "stall detected (no data), retrying";
        }

        const bool transient_transport_error = ex &&
            (ex->kind == ErrorKind::ConnectionError ||
             ex->kind == ErrorKind::Timeout ||
             ex->kind == ErrorKind::SslError);
        constexpr int64_t kSubstantialAttemptProgressBytes = 1024 * 1024;
        const bool attempt_has_substantial_progress =
            transient_transport_error && attempt_bytes >= kSubstantialAttemptProgressBytes;
        const bool transport_healthy = !ex || attempt_has_substantial_progress;
        // ⚠️ 2026-07-30：新增"中性"档 —— 拿到了真实字节但不足 1MiB。
        //   旧逻辑只有健康/故障两档，于是低速掐断（慢但确实在传）也被记进全局熔断：
        //   真机 hdc 20:57:10 / 20:57:25 连续出现 `addBadHost: maven.neoforged.net fail 1/12`、
        //   `2/12`，而它是当时**唯一可用**的源 —— 惩罚唯一能用的主机没有任何收益。
        //   PCL2 的口径（ModNet.vb:1091）是"收到任何数据就把 source.FailCount 归零"，
        //   且它的源禁用条件（ModNet.vb:1158-1163）里根本没有低速超时这一项。
        //   这里折中：任何真实字节 → 不再累计熔断；但仍**不**据此 markHostHealthy
        //   （保留 1MiB 的强健康门槛，避免"278KiB/49s"这类劣质节点洗掉已有熔断）。
        const bool attempt_made_progress = transient_transport_error && attempt_bytes > 0;

        // slot_host 是直连源；effective_host 是跟随重定向后实际传输的主机。完整成功或
        // 单次已交付 >=1MiB 都是强健康证据；少量慢速数据（真机 gh-proxy 278KiB/49s）
        // 不足以洗掉故障。只有零/低进度瞬时错误才累计全局熔断。
        std::string effective_host = slot_host;
        char* effective_url = nullptr;
        curl_easy_getinfo(easy, CURLINFO_EFFECTIVE_URL, &effective_url);
        if (effective_url && effective_url[0] != '\0') {
            std::string parsed_host = extractHostForSlot(effective_url);
            if (!parsed_host.empty()) effective_host = std::move(parsed_host);
        }

        auto& engine = DownloadEngine::instance();
        engine.releaseHostSlot(slot_host, transport_healthy);
        // ⚠️ 2026-07-31：族特异性失败不计入全局主机熔断。
        //   真机实测 cdn-alt.modrinth.com 的 IPv6 是 0 字节 / 137ms 立刻失败，而 IPv4
        //   能完整下完 1,205,063 字节。旧逻辑把这种失败记成 addBadHost，于是重定向块
        //   看到"目标主机在黑名单"就把官方源整条冷却（真机 22:57~23:01 反复 4 分钟），
        //   镜像源迟迟轮不上 —— 而这台主机其实只是**一族**不可达。
        //   family_retry_pending_ 由 performOnce 置位（另一族尚未试过时才为真），
        //   下一次尝试 ipResolveFor 会自动翻到另一族。
        const bool family_retry = family_retry_pending_.load(std::memory_order_acquire);
        const bool penalize_host =
            !transport_healthy && transient_transport_error && !user_aborted
            && !attempt_made_progress && !family_retry;
        if (transport_healthy) {
            engine.markHostHealthy(slot_host);
            if (effective_host != slot_host) engine.markHostHealthy(effective_host);
        } else if (penalize_host) {
            engine.addBadHost(effective_host);
        }

        if (ex) {
            const int64_t deadline = retryDeadlineMs();
            AMCL_LOG_I(LOG_TAG,
                "attempt result: host=%{public}s bytes=%{public}lld healthy=%{public}d "
                "badhost=%{public}d famretry=%{public}d kind=%{public}d done=%{public}lld "
                "retry=%{public}d deadline_in_ms=%{public}lld",
                effective_host.c_str(), (long long)attempt_bytes,
                transport_healthy ? 1 : 0, penalize_host ? 1 : 0,
                family_retry ? 1 : 0,
                static_cast<int>(ex->kind),
                (long long)attempt_done_after, retryCount(),
                (long long)(deadline > 0 ? deadline - nowMs() : 0));
        }
        if (ex && ex->http_status == 429) {
            engine.penalizeHost(slot_host);
        }
        if (!ex) {
            src->recordSuccess();
            // AMCL: 记录交付字节的源，供 NetFile SHA1 终检失败时定位坏内容源 + 换源。
            {
                std::lock_guard<std::mutex> lk(last_used_source_mu_);
                last_used_source_ = src;
            }
            // Phase 8: 成功路径采样（RTT + 瞬时吞吐）供后续 pickBestSourceWeighted 用。
            // CONNECT_TIME_T 单位是 microseconds；SPEED_DOWNLOAD_T 是 B/s（过去整次请求的平均）。
            {
                curl_off_t connect_us = 0;
                curl_off_t speed_bps = 0;
                curl_easy_getinfo(easy, CURLINFO_CONNECT_TIME_T, &connect_us);
                curl_easy_getinfo(easy, CURLINFO_SPEED_DOWNLOAD_T, &speed_bps);
                if (connect_us > 0) {
                    int rtt_ms = static_cast<int>(connect_us / 1000);
                    src->recordSample(rtt_ms, static_cast<double>(speed_bps));
                }
            }
            state_.store(NetState::Finished, std::memory_order_release);
            if (owns_easy) curl_easy_cleanup(easy);
            releaseFdGuard();
            task_->reportThreadFinished(this);
            return;
        }

        // 如果是真正的用户取消，立即退出
        if (user_aborted) {
            if (owns_easy) curl_easy_cleanup(easy);
            state_.store(NetState::Aborted, std::memory_order_release);
            releaseFdGuard();
            task_->reportThreadFinished(this);
            return;
        }

        last_ex = ex;
        setError(ex);

        if (ex->kind == ErrorKind::DiskFullError ||
            ex->kind == ErrorKind::QuotaExceededError ||
            ex->kind == ErrorKind::StorageIoError ||
            ex->kind == ErrorKind::FileIoError) {
            break;
        }

        // SizeMismatch（server 提前 EOF / CDN 节点抖动）不是源的错。做法：
        //   1. 不调 recordFailure（避免 pickBestSource 错误地换到质量更差的源）
        //   2. 重置 done_ = 0 从段起点重下。不使用续传 Range（"X-Y" with X>start）
        //      因为实测某些 CDN（mojang piston-data）对续传 Range 返回 416，
        //      但对相同 Range 的第一次请求只返回 partial（提前 EOF）。
        //   3. 同一 source 最多重试 3 次，超过后才视为真实失败并换源
        if (ex->kind == ErrorKind::SizeMismatch) {
            same_source_size_mismatch_retries++;
            if (same_source_size_mismatch_retries < kSameSourceRetryLimit) {
                AMCL_LOG_I(LOG_TAG, "SizeMismatch retry %{public}d/%{public}d on same source: %{public}s (reset done 0)",
                            same_source_size_mismatch_retries, kSameSourceRetryLimit,
                            src->url.c_str());
                resetDone();
                continue;
            }
            AMCL_LOG_W(LOG_TAG, "SizeMismatch retry exhausted, failing source: %{public}s",
                        src->url.c_str());
            same_source_size_mismatch_retries = 0;
            resetDone();  // 也重置给下一个源
        }

        // 已交付至少 1MiB 后才发生的连接中断，证明该源与主机本轮实际可用。
        // 将重试计数解释为“连续无实质进度失败次数”：不禁用源、不污染熔断，并从当前
        // done_ 继续 Range。否则 117MiB 文件每隔一段时间断一次，最终仍会累计 30 次而失败。
        if (attempt_has_substantial_progress) {
            constexpr int64_t kRetryNoProgressLifetimeMs = 5 * 60 * 1000LL;
            src->recordSuccess();
            retry_count_.store(0, std::memory_order_release);
            retry_delay_ms_.store(0, std::memory_order_release);
            retry_not_before_ms_.store(0, std::memory_order_release);
            retry_deadline_ms_.store(nowMs() + kRetryNoProgressLifetimeMs,
                                     std::memory_order_release);
            AMCL_LOG_I(LOG_TAG,
                "retry budget renewed by progress: source=%{public}s bytes=%{public}lld done=%{public}lld",
                src->url.c_str(), (long long)attempt_bytes, (long long)attempt_done_after);
            continue;
        }

        // v4.3: 快速错误处理
        // ConnectionError (CURLE_COULDNT_CONNECT 等)：无实质进度时 1 次弃用。
        if (ex->kind == ErrorKind::ConnectionError) {
            src->recordFailure(ex, /*max_failures=*/1);
            continue;
        }

        // SslError：BMCLAPI CDN 间歇性路由到证书不匹配的节点（"no alternative
        // certificate subject name matches"），重试可能路由到好节点。容忍 3 次。
        // 200ms 延迟让 DNS/负载均衡路由到不同节点。
        if (ex->kind == ErrorKind::SslError) {
            src->recordFailure(ex, /*max_failures=*/3);
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            continue;
        }

        // Timeout：容忍 2 次（可能是临时网络波动）
        if (ex->kind == ErrorKind::Timeout) {
            src->recordFailure(ex, /*max_failures=*/2);
            continue;
        }

        // 4xx 错误处理：
        //   404/416 = 该源没此文件（镜像未同步），应换源重试（如 BMCLAPI → Mojang）
        //   403 = 可能是限流也可能是真没文件，3 次后换源
        //   408/429 = 临时限流/超时，应重试
        //   5xx = 服务端错误，应重试
        //   其他 4xx（400/401）= 不可重试，直接失败
        if (ex->kind == ErrorKind::ProtocolError) {
            long s = ex->http_status;
            if (s == 404 || s == 416) {
                src->recordFailure(ex, /*max_failures=*/1);
                continue;
            }
            if (s == 403) {
                src->recordFailure(ex, /*max_failures=*/3);
                continue;
            }
            // 408/429/503：所有源（包括 BMCLAPI）统一尊重 Retry-After 并进入冷却。
            // 即使服务端给出 Retry-After，也增加小幅 jitter，防止同批请求同时惊群重打。
            if (s == 408 || s == 429 || s == 503) {
                // ⚠️ 2026-07-29：429 过去只设 cooldown、不进评分惩罚（recordFailure 未调用 →
                //   fail_count 保持 0），而 computeScore 的惩罚项只有 fail_count。于是限流镜像
                //   「秒拒」带来的极低 RTT 反而让它评分最优：冷却一过立刻被重新选中 → 再 429，
                //   尾段在「拒绝→冷却→又选它」之间空转（hdc 实测 gh.ddlc.top 连续数十条 429，
                //   done=0 永不推进）。这里给限流源记一次**软失败**（阈值放宽到 6，远高于
                //   404 的 1 / 403 的 3），让它在评分里逐步退居其次而不至于被永久淘汰——
                //   限流是暂时的，仍要留作后备源。
                src->recordFailure(ex, /*max_failures=*/6);
                // 段级解钉：initSegments 把段按 i%nsrc 钉在固定镜像上（setPreferredSourceIdx）。
                // 若不解钉，本段每次 attempt==0 都回到同一个被限流的镜像。
                setPreferredSourceIdx(-1);
                // ⚠️ 2026-07-29：退避改为**主机级**（见 DownloadEngine::noteHostRateLimit）。
                //   旧实现按本段自己的 retryCount() 算 shift，首次 429 只睡 500ms；
                //   16 个段各睡 500ms 后同时重来，代理看到的依旧是 16 并发 → 立刻再 429。
                //   真机实测：55 秒内字节零增长，429 计数却从 272 涨到 294 —— 这就是
                //   「前面很快、后面只有几十 KB」的直接原因（尾段全在空转重试）。
                //   现在同一主机的连续 429 共享一条指数退避曲线（1s→2→4→…→45s 上限，
                //   尊重 Retry-After 且带 jitter），并同步写进 source cooldown，
                //   使 pickBestSource / nextSourceReadyMs 都能看到正确的"何时可再试"。
                constexpr int64_t kMaxDelayMs = 5 * 60 * 1000LL;
                int64_t retry_after = response_retry_after_ms_.load(std::memory_order_acquire);
                int64_t until = DownloadEngine::instance().noteHostRateLimit(slot_host, retry_after);
                int64_t delay_ms = until > nowMs() ? until - nowMs() : 0;
                if (delay_ms > 0 && !addRetryDelayMs(delay_ms, kMaxDelayMs)) break;
                // 同步到源级 cooldown：让选源与等待逻辑一致地跳过该源。
                src->extendCooldownUntil(until);
                while (!aborted_.load(std::memory_order_acquire) && nowMs() < until) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(
                        std::min<int64_t>(100, until - nowMs())));
                }
                continue;
            }
            // 其他 5xx 有限记错并使用短退避，避免立即热循环。
            if (s >= 500 && s < 600) {
                int64_t delay_ms = 300 + (retryCount() * 53 % 251);
                if (!addRetryDelayMs(delay_ms, 5 * 60 * 1000LL)) break;
                int64_t until = nowMs() + delay_ms;
                src->extendCooldownUntil(until);
                src->recordFailure(ex, /*max_failures=*/3);
                while (!aborted_.load(std::memory_order_acquire) && nowMs() < until) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(
                        std::min<int64_t>(100, until - nowMs())));
                }
                continue;
            }
            // 其他 4xx（400/401 等）：不可重试，直接失败换源。
            src->recordFailure(ex);
            break;
        }
        src->recordFailure(ex);
    }

    if (owns_easy) curl_easy_cleanup(easy);
    setError(last_ex ? last_ex
                     : makeException(ErrorKind::InternalError, "all attempts exhausted"));
    state_.store(NetState::Failed, std::memory_order_release);
    releaseFdGuard();
    task_->reportThreadFinished(this);
}

} // namespace download
