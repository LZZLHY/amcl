/**
 * download/net_source.h — 单个下载源（URL）的运行时状态
 *
 * 对应 PCL2 `NetSource`。一个 NetFile 有多个 NetSource（镜像站），引擎会按优先级和成功率
 * 动态选择。Stage 1b 的调度策略简化为"按声明顺序，失败累计 3 次标记为 failed"。
 * Phase 8（S3-1，2026-05-06）：新增滑动窗口 RTT/throughput 采样 + 综合评分，
 *   `pickBestSourceWeighted` 用于多源加权挑选（NetFile 现有 pickBestSource 暂保留旧策略）。
 *
 * 线程安全：fail_count / is_failed 是 atomic，多个 NetThread 可能同时对同一源做 +1 或
 *           标记失败（一个源被多个分段并行使用时）。
 *           sample window 由 sample_mu_ 保护（写入次数低，每 200ms 级别）。
 */
#pragma once

#include <atomic>
#include <cstddef>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "exception.h"

namespace download {

struct NetSource {
    int         id   = 0;   // 源的声明顺序序号
    std::string url;        // 原始 URL（用于日志 / meta 持久化）

    /**
     * fail_count：本次任务期间该源累计失败次数。达到阈值（默认 3）→ is_failed=true。
     * 注意：不同任务之间不共享，进程重启会清零。跨任务的"源黑名单"留给 Stage 1c 的
     *      IPReliability。
     */
    std::atomic<int>     fail_count{0};
    std::atomic<bool>    is_failed{false};
    std::atomic<int>     success_count{0};  // 成功的分段数，用于日志分析
    // v4.2: 该源对 Range 请求返回 HTTP 200（全量数据）而非 206，不支持分段。
    // pickBestSource 对 start_ > 0 的段会跳过此源。
    std::atomic<bool>    no_range_support{false};
    // 只有成功验证过 206 + 精确 Content-Range 后才置 true。Accept-Ranges 仅是提示，
    // 不作为分段安全依据；false 表示尚未验证，不等同于明确不支持。
    std::atomic<bool>    range_verified{false};

    // AMCL: 该源交付的内容 SHA1 终检失败（= 内容不对，非网络问题）。典型场景：某镜像
    // （如 Mojang libraries.minecraft.net 对 log4j 的 Log4Shell 安全补丁版）给的 jar 字节
    // 与 Forge 期望的 Maven Central 原版哈希不符。一旦标记，pickBestSource 永久跳过该源，
    // 让 NetFile 换到内容正确的源（如 Maven Central 原版）。区别于 is_failed：checksum_bad
    // 不会被 onAllThreadsDone 的"重置瞬时失败源"或 sha1 多段→单段退化逻辑清除（那些只重置
    // fail_count/is_failed/no_range_support），确保坏内容源在本文件生命周期内持续被排除。
    std::atomic<bool>    checksum_bad{false};

    // AMCL (#3 429退避): 该源被限流（HTTP 429/408）时设的"冷却截止时间"（epoch 毫秒）。
    // pickBestSource 在 now < cooldown_until_ms 时跳过该源，强制换到别的源（如 BMCLAPI
    // /libraries），避免对同一个被限流的源（典型 Maven Central）立即重打、雪上加霜。
    // 与 is_failed 区别：冷却是短暂的、会自动到期恢复，不永久禁用源。
    std::atomic<int64_t> cooldown_until_ms{0};
    // Transient circuit-open deadline. Unlike checksum_bad, network failures expire.
    std::atomic<int64_t> failed_until_ms{0};

    // === last_error: shared_ptr 必须 mutex 保护（C++17 起 std::atomic_load(shared_ptr*)
    // === 已 deprecated，C++20 之前没合法无锁路径）。多 NetThread 可能并发持有同一
    // === source（多段共享 source 场景），同时 recordFailure → 同时写 last_error_，
    // === aarch64 弱内存模型下 control block 撕裂读 → use-after-free / SIGSEGV。
    //
    // 字段改为 private，读写必须走 lastError() / setLastError()。
    /** 最后一次失败原因（可空，用于 UI 显示 "源 X 失败：Timeout"）；线程安全访问见 lastError() / setLastError() */
    DownloadExceptionPtr lastError() const;
    void                 setLastError(DownloadExceptionPtr ex);

    static constexpr int    kDefaultMaxFailures = 3;
    /** 滑动窗口容量（Phase 8）。8 是经验值：足够平滑，又能让最近事件迅速主导。 */
    static constexpr size_t kSampleWindowSize = 8;

    NetSource() = default;
    /** Phase 8 测试便利构造：仅给 url，id 默认 0 */
    explicit NetSource(std::string url_) : url(std::move(url_)) {}
    NetSource(int id_, std::string url_) : id(id_), url(std::move(url_)) {}

    // 禁止复制（atomic 不能 copy），只用 shared_ptr 传递
    NetSource(const NetSource&) = delete;
    NetSource& operator=(const NetSource&) = delete;

    /** 记录一次失败；返回是否刚刚被标记为 failed（用于日志触发） */
    bool recordFailure(DownloadExceptionPtr ex, int max_failures = kDefaultMaxFailures);
    void recordSuccess();

    /** 单调延长源冷却时间；并发响应不得用较短 deadline 覆盖较长 cooldown。 */
    void extendCooldownUntil(int64_t deadline_ms);
    bool isAvailable(int64_t now_ms) const;
    int64_t readyAtMs() const;

    // ---------------- Phase 8: 滑动窗口采样 + 评分 ----------------

    /**
     * 记录一次性能采样。多线程安全。
     * @param rtt_ms          连接耗时（毫秒）；负数会被忽略
     * @param throughput_bps  瞬时吞吐（字节/秒）；负数或非法值会被忽略
     */
    void recordSample(int rtt_ms, double throughput_bps);

    /** 当前窗口内 RTT 平均值（毫秒）。窗口为空返回 -1。 */
    int    avgRttMs() const;

    /** 当前窗口内吞吐平均值（字节/秒）。窗口为空返回 0.0。 */
    double avgThroughputBps() const;

    /**
     * 综合评分（越低越优）。公式：
     *   score = avgRtt / 100.0           — RTT 项（50ms→0.5）
     *         + 1MB / avgThroughputBps   — 吞吐项（10MB/s→0.1, 1MB/s→1.0）
     *         + fail_count               — 失败惩罚（线性）
     *
     * 无数据回退："中性" RTT=200ms，吞吐=512KB/s（让无数据源比"高速好源"差，
     * 但比"高失败源"好）。详见 Phase 8 测试 `test_score_no_data_neutral`。
     */
    double computeScore() const;

private:
    // last_error_ 由 last_error_mu_ 保护（与 NetThread::last_error_ 同构）
    mutable std::mutex   last_error_mu_;
    DownloadExceptionPtr last_error_;

    mutable std::mutex sample_mu_;
    int    rtt_samples_[kSampleWindowSize] = {0};
    double tput_samples_[kSampleWindowSize] = {0};
    size_t sample_count_ = 0;       // 已写入的样本数（封顶 kSampleWindowSize）
    size_t sample_next_ = 0;        // 下一次写入位置（环形）
};

using NetSourcePtr = std::shared_ptr<NetSource>;

/**
 * Phase 8: 在多个候选源中挑评分最低的（不含 is_failed=true）。
 *   - 空数组 / 全部 is_failed → 返回 nullptr
 *   - 评分相同时按声明顺序（id 小的优先）
 *
 * 集成状态（Phase 8.3b 已完成）：NetFile::pickBestSource 已切换到 NetSource::computeScore()，
 *       即"按 RTT/吞吐量加权打分 + 失败次数惩罚"的新策略；本函数与之等价，仅作为可独立测试的 API 暴露。
 */
NetSourcePtr pickBestSourceWeighted(const std::vector<NetSourcePtr>& sources);

} // namespace download
