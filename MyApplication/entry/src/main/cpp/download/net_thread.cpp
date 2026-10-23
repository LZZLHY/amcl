/**
 * net_thread.cpp — 一个分段的worker执行与两执行器共用的正文回调。
 *
 * worker独占/复用它所在线程的easy；每个真实HTTP hop先取得Engine主机租约，再初始化
 * 请求时钟、响应及速度锚点。来源恢复保留有效前缀，仅明确错位/坏区间时重置内容。
 * pwrite写入NetFile拥有的staging fd；完整校验与最终发布仍由NetFile负责。
 *
 * UI终态与transport/completion两阶段收敛继续分开，不能由租约释放替代owner屏障。
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
#include "host_admission.h"
#include "transport_policy.h"
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
    return transportHost(url);
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
        if (!s->isAvailable(nowMs())) continue;
        const auto host = transportHost(s->url);
        if (DownloadEngine::instance().isBadHost(host) ||
            DownloadEngine::instance().hostRateLimitUntilMs(host) > nowMs()) continue;
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
    content_unknown_ = done > 0;
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

    // report可能分配完成集合或进入业务回调并抛出。transport已结算后，后续再次
    // mark会幂等返回，因此必须在当前栈无条件发布捕获epoch的completion屏障；
    // 外层原owner负责异常后的abort，不在OOM收尾中再分配另一份错误/任务。
    const auto publish_completion = [this, epoch](NetThread*) noexcept {
        uint64_t reported = completion_reported_epoch_.load(std::memory_order_acquire);
        while (reported < epoch && !completion_reported_epoch_.compare_exchange_weak(
            reported, epoch, std::memory_order_release, std::memory_order_acquire)) {}
    };
    std::unique_ptr<NetThread, decltype(publish_completion)> completion_guard(this, publish_completion);

    // 第一阶段：curl callback/worker 已退出，先移走本轮 keepalive。report 期间
    // completion_reported_epoch 仍落后，因此 Engine::purgeTask 不能销毁 LoaderDownload。
    // report 可能同步 prepare 新 epoch；下面只发布捕获到的旧 epoch，绝不污染新轮次。
    std::shared_ptr<NetFile> owner;
    {
        std::lock_guard<std::mutex> lk(execution_mu_);
        owner = std::move(task_keepalive_);
    }
    if (owner) owner->reportThreadFinished(this);

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
    admission_deadline_ms_.store(0, std::memory_order_release);
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
        const int64_t admission_deadline = admission_deadline_ms_.load(std::memory_order_acquire);
        if (admission_deadline > 0 && now >= admission_deadline) return false;
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

int64_t NetThread::schedulingDeadlineMs() {
    const int64_t active_deadline = retryDeadlineMs();
    if (active_deadline > 0) return active_deadline;
    int64_t deadline = admission_deadline_ms_.load(std::memory_order_acquire);
    if (deadline == 0) {
        const int64_t proposed = transportDeadlineAfter(nowMs(), 5 * 60 * 1000LL);
        if (admission_deadline_ms_.compare_exchange_strong(deadline, proposed,
                std::memory_order_acq_rel, std::memory_order_acquire)) deadline = proposed;
    }
    return deadline;
}

void NetThread::resetResponseHeaders() {
    response_retry_after_ms_.store(0, std::memory_order_release);
    response_content_range_seen_.store(false, std::memory_order_release);
    response_content_range_valid_.store(false, std::memory_order_release);
    response_content_range_start_.store(-1, std::memory_order_release);
    response_content_range_end_.store(-1, std::memory_order_release);
    response_content_range_total_.store(-1, std::memory_order_release);
    hdr_status_code_.store(0, std::memory_order_release);
}

void NetThread::beginTransportAttempt(HostAdmissionLease* admission) {
    // 保留断点 done，速度只计算本次新增字节。复用连接 connect_time=0 也是合法传输，
    // 不再用进程开机时间作为第一条速度采样的分母。
    const int64_t now = nowMs();
    attempt_admission_ = admission;
    attempt_initial_done_ = done();
    attempt_health_reported_ = false;
    transfer_start_ms_.store(now, std::memory_order_release);
    last_data_receive_ms_.store(0, std::memory_order_release);
    speed_.last_ts_ms.store(now, std::memory_order_release);
    speed_.last_done.store(done(), std::memory_order_release);
    speed_.last_speed_bps.store(0, std::memory_order_release);
    family_retry_pending_.store(false, std::memory_order_release);
    clearWriteErrno();
    resetResponseHeaders();
}

bool NetThread::prepareContentSource(const NetSourcePtr& source) {
    if (!source) {
        std::lock_guard<std::mutex> boundary_lk(write_boundary_mu_);
        attempt_content_source_.reset();
        return false;
    }
    bool rewind = false;
    {
        std::lock_guard<std::mutex> boundary_lk(write_boundary_mu_);
        rewind = task_->requiresSingleSourceRecheck() && done() > 0 &&
            (content_unknown_ || content_mixed_ || !content_source_ ||
             content_source_.get() != source.get() || source->no_range_support.load(std::memory_order_acquire));
    }
    // 此入口只在旧 HTTP 已退出、下次真实 HTTP 准入后调用；不与正文回调并发。
    // resetDone 自身取得相同边界锁，不能在上面的锁内递归调用。
    if (rewind) resetDone();
    {
        std::lock_guard<std::mutex> boundary_lk(write_boundary_mu_);
        attempt_content_source_ = source;
    }
    return rewind;
}

NetSourcePtr NetThread::provenSingleContentSource() const {
    std::lock_guard<std::mutex> boundary_lk(write_boundary_mu_);
    return content_unknown_ || content_mixed_ ? nullptr : content_source_;
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
    auto ex = makeException(kind, e == EFBIG ? "download staging exceeds supported 1 TiB byte limit"
        : "pwrite failed errno=" + std::to_string(e));
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
    // 供应方预算按网络正文累计，Range回退/本地done重置不能重置权限额度。
    if (!self->task_->consumeAuthorizedBytes(requested)) {
        self->setError(self->task_->authorizationFailure()); return 0;
    }

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
    // HEAD缺失或无授权的未知大小GET也必须有全局硬界。先拒绝再pwrite，不能让
    // 不可信正文无限延展staging；沿原本地失败出口停止，不靠换源绕过支持上限。
    if (offset < 0 || offset > kMaxDownloadFileBytes ||
        n > static_cast<uint64_t>(kMaxDownloadFileBytes - offset)) {
        self->write_errno_.store(EFBIG, std::memory_order_release);
        return 0;
    }

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
    if (written > 0) {
        if (!self->attempt_content_source_) self->content_unknown_ = true;
        else if (!self->content_source_) self->content_source_ = self->attempt_content_source_;
        else if (self->content_source_.get() != self->attempt_content_source_.get()) self->content_mixed_ = true;
    }
    if (!self->attempt_health_reported_ && self->done() - self->attempt_initial_done_ >= 1024 * 1024) {
        self->attempt_health_reported_ = true;
        if (self->attempt_admission_) self->attempt_admission_->noteHealthy();
    }

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
            if (code > 0) {
                self->resetResponseHeaders();
                self->hdr_status_code_.store(code, std::memory_order_release);
                self->task_->noteAuthorizedHeaders(code);
            }
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
    const int64_t delay_ms = parseTransportRetryAfter(value);
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
                // 聚合速度随分段数增长；直接与 sum 比较会把 16 条同样慢的连接全部
                // 当成“明显落后”。只与其余活跃段的平均速度比较，整条链路慢时不互杀。
                if (slowerThanTransportPeers(bps, file_bps, self->task_->activeSegmentCount())) {
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
    admission_deferred_ = false;
    family_retry_pending_.store(false, std::memory_order_release);
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
        std::string rewritten = task_->bearerToken().empty() ? relayRewriteUrl(actual_url) : "";
        if (!rewritten.empty()) {
            actual_url = rewritten;
            via_relay = true;
        }
    }
    curl_easy_setopt(easy, CURLOPT_URL, actual_url.c_str());
    // 短时令牌不在 URL 内，不经过加速网关；每次 curl_easy_reset 后只为原授权节点设置。
    if (!task_->bearerToken().empty()) {
        // 一次权限不可交给认证协商自动重发GET；也不复用可能已被服务端关闭的旧连接。
        curl_easy_setopt(easy, CURLOPT_FRESH_CONNECT, 1L);
        curl_easy_setopt(easy, CURLOPT_FORBID_REUSE, 1L);
    }
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);  // 不自动 follow
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);        // 多线程必须
    // 共享 DNS 缓存；SSL session 未在 Engine 注册共享，不能宣称其已被复用。
    CURLSH* sh = DownloadEngine::instance().curlShare();
    if (sh) {
        curl_easy_setopt(easy, CURLOPT_SHARE, sh);
    }
    // 把旧默认策略投影为一次请求 profile，首次与每个重定向 hop 使用完全同一份值。
    // 这里仅抽取既有数值：不改变 worker/multi 分流、线程数或 maxConnections 的含义。
    const bool is_single_full_get = start_ == 0 && end_.load(std::memory_order_acquire) < start_;
    const auto profile = workerRequestProfile(task_->fileSize(), task_->isHighParallel(),
                                             is_single_full_get, countUsableSources(task_) > 1);
    applyTransportProfile(easy, profile);
    if (profile.enlarge_socket_buffer)
        curl_easy_setopt(easy, CURLOPT_SOCKOPTFUNCTION, sockoptEnlargeRcvbuf);
    curl_easy_setopt(easy, CURLOPT_FAILONERROR, 1L);
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
        curl_easy_setopt(easy, CURLOPT_RANGE, range_was_requested ? range.c_str() : nullptr);
    };
    applyCurrentRange();

    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, &NetThread::onWrite);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, this);
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, &NetThread::onHeader);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, this);
    curl_easy_setopt(easy, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(easy, CURLOPT_XFERINFOFUNCTION, &NetThread::onProgress);
    curl_easy_setopt(easy, CURLOPT_XFERINFODATA, this);

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
    HeaderList authorized_headers;
    if (!task_->bearerToken().empty()) {
        authorized_headers.add("Authorization: Bearer " + task_->bearerToken());
        if (!authorized_headers.h) return makeException(ErrorKind::InternalError, "authorization header allocation failed");
        curl_easy_setopt(easy, CURLOPT_HTTPHEADER, authorized_headers.h);
    }

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

    CURLcode rc = CURLE_OK;
    long http_code = 0;
    // 所有实际 hop 共用 Engine 准入；relay 改写/鉴权回退以后才确定真实主机。
    // 等待名额不消费请求次数，也不启动首字节/低速计时。RAII 覆盖全部提前返回。
    const auto performHop = [&]() -> DownloadExceptionPtr {
        HostAdmissionLease admission;
        family_host = transportHost(actual_url);
        ip_resolve = DownloadEngine::instance().ipResolveFor(family_host);
        curl_easy_setopt(easy, CURLOPT_IPRESOLVE, ip_resolve);
        const int64_t admission_deadline = schedulingDeadlineMs();
        if (!admission.tryAcquire(family_host)) {
            if (isAborted()) return makeException(ErrorKind::AbortedByUser, "cancelled before HTTP admission");
            if (nowMs() >= admission_deadline)
                return makeRetryTerminationException(error(), "host admission exceeds retry deadline");
            // 实际CDN/relay可能限流，而原origin仍可选。把就绪时刻关联到本候选，
            // 回外层挑健康备源；只有全部候选都不可用时才有界等待，不钉住一台host。
            auto& engine = DownloadEngine::instance();
            const int64_t ready = std::max(transportDeadlineAfter(nowMs(), 50),
                std::max(engine.badHostReadyAtMs(family_host), engine.hostRateLimitUntilMs(family_host)));
            source->extendCooldownUntil(ready);
            admission_deferred_ = true;
            return makeException(ErrorKind::ConnectionError, "HTTP host admission deferred");
        }
        if (isAborted()) return makeException(ErrorKind::AbortedByUser, "cancelled before HTTP attempt");
        if (!tryBeginAttempt(30))
            return makeRetryTerminationException(error(), "retry attempts exhausted");
        if (auto denied = task_->beginAuthorizedRequest()) return denied;
        // actual hop 已准入并完成原授权计费；普通模式此调用只记录贡献来源。
        // 摘要证伪后的单源复验若换来源，从0开始并同步更新真正发出的 Range 窗口。
        if (prepareContentSource(source)) applyCurrentRange();
        beginTransportAttempt(&admission);
        const int64_t before = done();
        rc = curl_easy_perform(easy);
        endTransportAttempt();
        http_code = 0;
        curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &http_code);
        curl_off_t received = 0;
        curl_easy_getinfo(easy, CURLINFO_SIZE_DOWNLOAD_T, &received);
        char* primary = nullptr;
        curl_easy_getinfo(easy, CURLINFO_PRIMARY_IP, &primary);
        const std::string ip = primary ? primary : "";
        auto& engine = DownloadEngine::instance();
        // HTTP 错误也证明地址族连通；本地取消/磁盘写错不能伪造地址族失败。
        if (http_code > 0 || received > 0 || isFamilyConnectFailure(rc, http_code, received))
            engine.noteFamilyOutcome(family_host, ip_resolve, ip,
                                     http_code > 0 || received > 0,
                                     rc == CURLE_COULDNT_RESOLVE_HOST);
        const long used = ip_resolve == CURL_IPRESOLVE_WHATEVER
            ? DownloadEngine::familyFromIp(ip) : ip_resolve;
        const bool family_retry = isFamilyConnectFailure(rc, http_code, received) &&
            engine.hasUntriedFamily(family_host, used);
        family_retry_pending_.store(family_retry, std::memory_order_release);
        const int64_t progress = done() > before ? done() - before : 0;
        const bool local_failure = writeErrno() != 0 ||
            (error() && error()->needs_new_lease);
        const bool healthy = !isAborted() && !local_failure &&
            ((rc == CURLE_OK && http_code >= 200 && http_code < 400) || progress >= 1024 * 1024);
        admission.finish(healthy);
        if (!healthy && !isAborted() && !local_failure && !family_retry &&
                 isFamilyConnectFailure(rc, http_code, received)) engine.addBadHost(family_host);
        // 对中断且确实交付有效字节的请求也采样，避免评分永远冻结在早期快成功值。
        // 连接复用时 connect_time==0 合法，不应丢掉这次正文吞吐。
        if (progress > 0 && !isAborted() && !local_failure && http_code >= 200 && http_code < 300) {
            curl_off_t total_us = 0, connect_us = 0;
            curl_easy_getinfo(easy, CURLINFO_TOTAL_TIME_T, &total_us);
            curl_easy_getinfo(easy, CURLINFO_CONNECT_TIME_T, &connect_us);
            if (total_us > 0) source->recordSample(static_cast<int>(connect_us / 1000),
                static_cast<double>(progress) * 1000000.0 / static_cast<double>(total_us));
        }
        return nullptr;
    };
    if (auto denied = performHop()) return denied;

    // v4.3: 手动处理 302/301/307/308 重定向
    // 在 follow 前检查目标主机是否在全局坏主机黑名单中
    for (int redir = 0; redir < 5 && rc == CURLE_OK
            && (http_code == 301 || http_code == 302 || http_code == 307 || http_code == 308);
         ++redir) {
        if (!task_->bearerToken().empty()) break; // 节点改变必须重新授权，不能把 Bearer 带给另一主机。
        char* redir_url = nullptr;
        curl_easy_getinfo(easy, CURLINFO_REDIRECT_URL, &redir_url);
        if (!redir_url || redir_url[0] == '\0') break;

        // 从 redir_url 提取 host
        std::string rurl(redir_url);
        if (!isTransportHttpUrl(rurl)) {
            auto ex = makeException(ErrorKind::ProtocolError, "redirect protocol is not HTTP(S)");
            ex->http_status = http_code; ex->url_context = actual_url; return ex;
        }
        const std::string rhost = transportHost(rurl);
        if (!rhost.empty()) {

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
                // 3xx 正文由 onWrite 丢弃；候选被拒没有写入，必须保留原有效断点。
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
        resetResponseHeaders();
        // ⚠️ 2026-07-31：不再 resetDone()。3xx 响应体已由 onWrite 依据 hdr_status_code_
        //   丢弃，不会污染 done_/SHA1，因此无需归零。保留 done_ 让"续传请求经
        //   cdn.modrinth.com→307→cdn-alt"后仍从断点继续 Range，消除旧实现每次重定向
        //   都把已下字节清零、从头重下的进度倒退死循环（真机 sodium 1.2MB 单连接 646s 的
        //   主要放大器之一）。数据正确性仍由每跳 Content-Range 校验 + 全文件 SHA1 终检兜底。
        // 每个 HTTP hop 都有独立响应头。若不清零，最终 206 缺失/错误 Content-Range
        // 时可能误用上一跳留下的值并错误通过区间校验；resetResponseHeaders 同时清零
        // hdr_status_code_，使下一跳的状态码由其自身状态行重新决定。
        curl_easy_reset(easy);
        curl_easy_setopt(easy, CURLOPT_URL, actual_url.c_str());
        curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 0L);
        curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
        CURLSH* sh2 = DownloadEngine::instance().curlShare();
        if (sh2) curl_easy_setopt(easy, CURLOPT_SHARE, sh2);
        applyTransportProfile(easy, profile);
        if (profile.enlarge_socket_buffer)
            curl_easy_setopt(easy, CURLOPT_SOCKOPTFUNCTION, sockoptEnlargeRcvbuf);
        curl_easy_setopt(easy, CURLOPT_FAILONERROR, 1L);
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
            // 不得继续向网关发送缺少持有证明的请求，也不把上一跳凭据留给其他主机。
            auto ex = makeException(ErrorKind::ConnectionError, "relay authorization unavailable after redirect");
            ex->url_context = actual_url; return ex;
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

        if (auto denied = performHop()) return denied;
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

    // 每一跳的地址族与主机结果已在 performHop 按真实连接单独结算。

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

    if (isAborted()) return makeException(ErrorKind::AbortedByUser, "cancelled during HTTP");
    if (auto write_ex = writeFailure(actual_url)) return write_ex;
    if (auto denied = error(); denied && denied->needs_new_lease) return denied;
    if (rc == CURLE_OK && (http_code < 200 || http_code >= 300)) {
        auto ex = makeException(ErrorKind::ProtocolError, "HTTP response did not deliver artifact content");
        ex->http_status = http_code; ex->url_context = actual_url;
        if (!task_->bearerToken().empty() && http_code >= 300 && http_code < 400)
            return task_->authorizationFailure(ex);
        return ex;
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
    // 没发Range的full GET不能把意外206的部分对象当作完整EOF；尤其无checker的
    // 未知大小入口没有后续摘要可以兜底。保留失败事实，下一轮从零取完整对象。
    if (!range_was_requested && http_code == 206) {
        resetDone();
        auto ex = makeException(ErrorKind::SizeMismatch, "unsolicited partial response for full GET");
        ex->http_status = http_code; ex->url_context = source->url;
        return ex;
    }
    if (range_was_requested && http_code == 206) {
        ParsedContentRange range;
        range.start = response_content_range_start_.load(std::memory_order_acquire);
        range.end = response_content_range_end_.load(std::memory_order_acquire);
        range.total = response_content_range_total_.load(std::memory_order_acquire);
        // 校验发送时捕获的请求窗口，而不是可能已被 shrinkEndTo 缩短的写入窗口。
        // 后者只决定本线程何时主动停写；不能追溯改变已经在途的 HTTP Range。
        // 开放式 bytes=offset- 用于未知大小续传，完成必须抵达响应声明的对象末尾。
        // 仅 start 对齐且 curl 正常 EOF 仍可能只交付中间窗口（如 offset..offset+99），
        // 无 checker 时不能将它误当整文件。这里只校验该响应，不将 header 升格为
        // NetFile 权威总长；未知总长继续由最终校验与提交成功后确定。
        if (!response_content_range_seen_.load(std::memory_order_acquire) ||
            !response_content_range_valid_.load(std::memory_order_acquire) ||
            !contentRangeMatches(range, requested_offset, requested_end, task_->fileSize()) ||
            (requested_end < 0 && range.end != range.total - 1)) {
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
        // header 的末尾虽然正确，实际正文仍可能通过更短的 Content-Length 提前正常
        // EOF。未知总长不能只看 CURLE_OK；用本次已验证窗口算出该段应累计到的长度，
        // 交下方既有 short-read 判定。这里只影响本次响应，不污染下一候选的权威total。
        if (requested_end < 0 && expected_len < 0) expected_len = range.total - start_;
        if (requested_end < 0 && current_done > range.total - start_) {
            resetDone();
            auto ex = makeException(ErrorKind::SizeMismatch, "open-ended Range body exceeded declared object EOF");
            ex->http_status = http_code; ex->url_context = source->url;
            return ex;
        }
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

    if (auto budget = error(); budget && budget->needs_new_lease) return budget;
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
        // 用户取消由 Aborted 状态表达，不能继续携带此前换源产生的 HTTP 失败。
        setError(nullptr);
        state_.store(NetState::Aborted, std::memory_order_release);
        task_->reportThreadFinished(this);
        return;
    }

    // 断点续传短路：restoreFromMeta 对"已完成"的段创建 NetThread 时把 done
    // 设成了 length，这里直接上报 Finished，避免白白 curl_easy_init + HEAD。
    // 条件 end_ >= 0 是为了排除 HEAD 未完成（未知大小）的场景。
    if (end_.load(std::memory_order_acquire) >= 0 &&
        done_.load(std::memory_order_relaxed) >= length()) {
        // 已完成段的续传短路与真实传输成功保持一致，不留旧错误供快照误读。
        setError(nullptr);
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
    NetSourcePtr family_retry_source;
    int same_source_size_mismatch_retries = 0;
    constexpr int kSameSourceRetryLimit = 3;

    for (int attempt = 0; ; ++attempt) {
        int64_t retry_deadline = schedulingDeadlineMs();
        if (retryCount() >= 30 ||
            (retry_deadline > 0 && nowMs() >= retry_deadline)) {
            last_ex = makeRetryTerminationException(last_ex, "retry budget exhausted");
            break;
        }
        if (aborted_.load(std::memory_order_relaxed)) {
            if (owns_easy) curl_easy_cleanup(easy);
            setError(nullptr);
            state_.store(NetState::Aborted, std::memory_order_release);
            releaseFdGuard();
            task_->reportThreadFinished(this);
            return;
        }

        // v4.2: 非段 0 的分段下载需要 Range 支持，跳过不支持 Range 的源
        // v6: 首次尝试用本段的首选源（多源轮询，段i→源i）；重试时回退 -1 按评分选最优源。
        const bool needs_range = requiresRangeSupport() &&
            !(task_->requiresSingleSourceRecheck() && start_ == 0 && end() < start_);
        NetSourcePtr src = std::move(family_retry_source);
        if (!src || !src->isAvailable(nowMs())) src = task_->pickBestSource(needs_range,
            /*preferred_idx=*/((task_->requiresSingleSourceRecheck() ? retryCount() == 0 : attempt == 0)
                               ? preferred_source_idx_ : -1));
        if (!src) {
            int64_t ready = task_->nextSourceReadyMs(needs_range);
            int64_t now = nowMs();
            if (ready > now) {
                int64_t deadline = schedulingDeadlineMs();
                if (deadline > 0 && ready > deadline) {
                    last_ex = makeRetryTerminationException(last_ex,
                                            "source cooldown exceeds retry deadline");
                    break;
                }
                const int64_t wait_until = deadline > 0 ? std::min(ready, deadline) : ready;
                while (!aborted_.load(std::memory_order_acquire) && now < wait_until) {
                    // 半开探针可能已经真实成功。每次取消检查顺便读取最新 ready，
                    // 不能把先前捕获的45s租约整段睡满，耽误已经恢复的来源。
                    if (task_->nextSourceReadyMs(needs_range) <= now) break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(
                        std::min<int64_t>(100, wait_until - now)));
                    now = nowMs();
                }
                continue;
            }
            // 最近实际响应才是失败原因；“无源可选”只是调度终止条件。
            // 保留同一次 run 中最近的分类/状态/URL，不读取其他段或源的历史缓存。
            last_ex = makeRetryTerminationException(last_ex,
                                    "no available sources (all failed)");
            break;
        }

        // 请求准入和计数位于 performOnce 的真实 hop；此处尚未发生 HTTP。
        const std::string slot_host = transportHost(src->url);
        // v6: 记录本段当前使用的源，供 maybeGrowThreads 避让（防同源并发 Range 损坏）。
        current_source_id_.store(src->id, std::memory_order_relaxed);
        const int64_t attempt_done_before = done_.load(std::memory_order_acquire);
        AMCL_LOG_D(LOG_TAG,
            "attempt begin: source=%{public}s done=%{public}lld retry=%{public}d",
            src->url.c_str(), (long long)attempt_done_before, retryCount());

        auto ex = performOnce(src, easy);
        if (admission_deferred_) {
            current_source_id_.store(-1, std::memory_order_release);
            continue; // 未发生本hop HTTP，不扣来源/权限预算，不撤销有效前缀
        }
        const int64_t attempt_done_after = done_.load(std::memory_order_acquire);
        // 摘要证伪后的完整复验可能在 perform 内从0重做；该模式使用实际 HTTP 起点，
        // 不能从旧 prefix 相减而把本次新增字节误算为0。普通恢复保持原口径。
        const int64_t actual_base = task_->requiresSingleSourceRecheck() ? attempt_initial_done_ : attempt_done_before;
        const int64_t attempt_bytes = attempt_done_after > actual_base
            ? attempt_done_after - actual_base : 0;
        const bool user_aborted = aborted_.load(std::memory_order_acquire);

        // progress callback 的主动 stall 中止不是用户取消，先归一成 Timeout，确保下面的
        // attempt 进度分类、主机熔断和源级策略看到的是同一种瞬时网络错误。
        if (ex && ex->kind == ErrorKind::AbortedByUser && !user_aborted) {
            ex->kind = ErrorKind::Timeout;
            ex->message = "stall detected (no data), retrying";
        }

        const bool transient_transport_error = ex && isTransientTransportFailure(ex->kind);
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
        const bool family_retry = family_retry_pending_.load(std::memory_order_acquire);
        // 这里只用于日志；真实主机健康已在每个 hop 内按实际连接结算。
        const bool penalize_host = !transport_healthy && transient_transport_error &&
            !user_aborted && !attempt_made_progress && !family_retry;
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
            engine.penalizeHost(effective_host);
        }
        if (!ex) {
            src->recordSuccess();
            // AMCL: 记录交付字节的源，供 NetFile SHA1 终检失败时定位坏内容源 + 换源。
            {
                std::lock_guard<std::mutex> lk(last_used_source_mu_);
                last_used_source_ = src;
            }
            // 先清除本段此前失败，再发布 Finished；消费者不能看到成功段挂着旧 HTTP 错误。
            setError(nullptr);
            state_.store(NetState::Finished, std::memory_order_release);
            if (owns_easy) curl_easy_cleanup(easy);
            releaseFdGuard();
            task_->reportThreadFinished(this);
            return;
        }

        // 如果是真正的用户取消，立即退出
        if (user_aborted) {
            if (owns_easy) curl_easy_cleanup(easy);
            setError(nullptr);
            state_.store(NetState::Aborted, std::memory_order_release);
            releaseFdGuard();
            task_->reportThreadFinished(this);
            return;
        }

        last_ex = ex;
        ex->retry_after_ms = std::max(ex->retry_after_ms,
            response_retry_after_ms_.load(std::memory_order_acquire));
        // 一次性GET结束后不得进入普通EOF/Range/地址族重试；401/403也必须交业务层
        // 重新获取当前节点权限。这里保留本地I/O与用户取消的原分类，不热循环授权。
        const bool local_error = isLocalTransportFailure(ex->kind);
        if (task_->singleUseAuthorization() && !local_error) ex = task_->authorizationFailure(ex);
        else if (!task_->bearerToken().empty() && (ex->http_status == 401 || ex->http_status == 403 || ex->http_status == 429 || ex->http_status == 503)) ex = task_->authorizationFailure(ex);
        if (!task_->bearerToken().empty() && (ex->http_status == 429 || ex->http_status == 503)) ex->retry_after_ms = std::max<int64_t>(1000, ex->retry_after_ms);
        last_ex = ex;
        setError(ex);
        if (ex->needs_new_lease) {
            if ((ex->http_status == 429 || ex->http_status == 503) && ex->retry_after_ms > 0)
                engine.noteHostRateLimit(effective_host, ex->retry_after_ms);
            break;
        }

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
        // 未试另一地址族的连接失败只改变下一次连接选择，不能先把整个 URL 标死。
        // 同一权限仍由 beginAuthorizedRequest 计费；单次授权已在上面退出，不会绕过限制。
        if (family_retry) { family_retry_source = src; continue; }
        // 某个重定向目标正在临时熔断只决定 not-before，不把原 URL 永久标坏。
        if (ex->http_status >= 300 && ex->http_status < 400 && src->readyAtMs() > nowMs()) continue;
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
                int64_t until = DownloadEngine::instance().noteHostRateLimit(effective_host, retry_after);
                int64_t delay_ms = until > nowMs() ? until - nowMs() : 0;
                // 同步到源级 cooldown：让选源与等待逻辑一致地跳过该源。
                src->extendCooldownUntil(until);
                if (countUsableSources(task_) > 0) continue;
                if (delay_ms > 0 && !addRetryDelayMs(delay_ms, kMaxDelayMs)) break;
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
