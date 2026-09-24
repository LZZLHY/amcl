#include "net_source.h"

#include <algorithm>
#include <chrono>

namespace download {

namespace {

int64_t steadyNowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

} // namespace

DownloadExceptionPtr NetSource::lastError() const {
    std::lock_guard<std::mutex> lk(last_error_mu_);
    return last_error_;
}

void NetSource::setLastError(DownloadExceptionPtr ex) {
    std::lock_guard<std::mutex> lk(last_error_mu_);
    last_error_ = std::move(ex);
}

bool NetSource::recordFailure(DownloadExceptionPtr ex, int max_failures) {
    // 通过 setLastError 走 mutex 保护，防止 shared_ptr 并发写撕裂 control block
    setLastError(ex);
    int new_count = fail_count.fetch_add(1, std::memory_order_acq_rel) + 1;
    if (new_count >= max_failures) {
        bool was_failed = is_failed.exchange(true, std::memory_order_acq_rel);
        return !was_failed;  // 只有首次翻转才返回 true（用于日志去重）
    }
    return false;
}

void NetSource::recordSuccess() {
    success_count.fetch_add(1, std::memory_order_acq_rel);
    fail_count.store(0, std::memory_order_release);
    // 不清 cooldown：同一源上的并发成功响应不得取消另一个请求刚设置的 Retry-After。
    // deadline 到期后 isAvailable() 会自动恢复，无需主动清零。
    failed_until_ms.store(0, std::memory_order_release);
}

void NetSource::extendCooldownUntil(int64_t deadline_ms) {
    int64_t old = cooldown_until_ms.load(std::memory_order_acquire);
    while (old < deadline_ms &&
           !cooldown_until_ms.compare_exchange_weak(old, deadline_ms,
                                                    std::memory_order_acq_rel,
                                                    std::memory_order_acquire)) {
    }
}

bool NetSource::isAvailable(int64_t now_ms) const {
    if (checksum_bad.load(std::memory_order_acquire)) return false;
    if (cooldown_until_ms.load(std::memory_order_acquire) > now_ms) return false;
    if (failed_until_ms.load(std::memory_order_acquire) > now_ms) return false;
    return !is_failed.load(std::memory_order_acquire);
}

int64_t NetSource::readyAtMs() const {
    return std::max(cooldown_until_ms.load(std::memory_order_acquire),
                    failed_until_ms.load(std::memory_order_acquire));
}

// ----------------------------------------------------------------------------
// Phase 8: 滑动窗口采样 + 综合评分
// ----------------------------------------------------------------------------

void NetSource::recordSample(int rtt_ms, double throughput_bps) {
    if (rtt_ms < 0) return;                  // 非法 RTT 忽略
    if (!(throughput_bps >= 0.0)) return;    // 非法吞吐忽略（同时 NaN 也会被排除）

    std::lock_guard<std::mutex> lk(sample_mu_);
    rtt_samples_[sample_next_]  = rtt_ms;
    tput_samples_[sample_next_] = throughput_bps;
    sample_next_ = (sample_next_ + 1) % kSampleWindowSize;
    if (sample_count_ < kSampleWindowSize) sample_count_++;
}

int NetSource::avgRttMs() const {
    std::lock_guard<std::mutex> lk(sample_mu_);
    if (sample_count_ == 0) return -1;
    int64_t sum = 0;
    for (size_t i = 0; i < sample_count_; ++i) sum += rtt_samples_[i];
    // 整除取近似值；用 (sum + count/2) / count 做四舍五入
    int64_t cnt = static_cast<int64_t>(sample_count_);
    return static_cast<int>((sum + cnt / 2) / cnt);
}

double NetSource::avgThroughputBps() const {
    std::lock_guard<std::mutex> lk(sample_mu_);
    if (sample_count_ == 0) return 0.0;
    double sum = 0.0;
    for (size_t i = 0; i < sample_count_; ++i) sum += tput_samples_[i];
    return sum / static_cast<double>(sample_count_);
}

double NetSource::computeScore() const {
    int rtt = avgRttMs();
    double thr = avgThroughputBps();
    int fails = fail_count.load(std::memory_order_relaxed);

    // 无数据时回退到中性默认（详见 header 注释）
    double rttMs = (rtt >= 0) ? static_cast<double>(rtt) : 200.0;
    double throughput = (thr > 0.0) ? thr : (512.0 * 1024.0);  // 0.5 MB/s

    constexpr double kRefBytesPerScoreUnit = 1024.0 * 1024.0;  // 1 MB / s

    return rttMs / 100.0
         + kRefBytesPerScoreUnit / throughput
         + static_cast<double>(fails);
}

// ----------------------------------------------------------------------------
// pickBestSourceWeighted — 命名空间级自由函数
// ----------------------------------------------------------------------------

NetSourcePtr pickBestSourceWeighted(const std::vector<NetSourcePtr>& sources) {
    NetSourcePtr best;
    double best_score = 0.0;
    int64_t now_ms = steadyNowMs();
    for (const auto& s : sources) {
        if (!s || !s->isAvailable(now_ms)) continue;
        double sc = s->computeScore();
        if (!best || sc < best_score
            || (sc == best_score && s->id < best->id)) {  // 同分按 id 稳定排序
            best = s;
            best_score = sc;
        }
    }
    return best;
}

} // namespace download
