/**
 * download/net_thread.h — 单个分段下载线程
 *
 * 对应 PCL2 `NetThread`。一个 NetThread 负责下载一个 [start, end] 字节区间，用独立的
 * CURL* easy handle 阻塞式 curl_easy_perform。
 *
 * 关键设计（不同于 PCL2）：
 *   - 不用 .part 临时文件 + 合并。直接 pwrite(fd, buf, n, start + offset) 到最终文件。
 *   - fd 由 NetFile 统一管理（一个 NetFile 的所有 NetThread 共享同一个 fd）。
 *     pwrite 是原子的（POSIX 保证），多线程并发写同一个 fd 的不同 offset 是安全的。
 *
 * 生命周期：
 *   ctor → run()（在 WorkerPool 的线程上被调用） → dtor
 *
 * run() 内部：
 *   1. 从 task->sources 里选一个可用 NetSource（RR 或按 IP 评分）
 *   2. curl_easy_init + 设置 URL / Range / write_callback / progress_callback
 *   3. curl_easy_perform（阻塞）
 *   4. 成功 → source->recordSuccess + state=Finished
 *      失败 → source->recordFailure + 选下一个源重试 + 重置 done=0
 *             所有源都挂 → state=Failed
 *   5. curl_easy_cleanup
 *
 * 取消：外部通过 abort() 设置 aborted_=true，progress_callback 返回非 0 让 curl 提前退出。
 */
#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

#include "exception.h"
#include "net_state.h"
#include "net_source.h"
#include "sha1.h"

// 前向声明 CURL（不 include <curl/curl.h> 污染本文件）
typedef void CURL;

namespace download {

class NetFile;  // 前向声明

/**
 * steady-clock 毫秒。与 net_thread.cpp 内部的 nowMs() 同源，供本头文件的内联成员函数使用。
 * 名字带 netThread 前缀：multi_downloader.cpp 有自己的 steadyNowMs()，同名会二义。
 */
inline int64_t netThreadSteadyNowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

class NetThread {
public:
    /**
     * 构造：
     *   @param task  所属文件；执行期间强持有，settled 后释放以打破 NetFile/NetThread 环
     *   @param start 区间起始字节偏移
     *   @param end   区间结束字节偏移（inclusive）；-1 表示"未知大小，下到 EOF"
     *   @param done  已下载字节数（用于断点恢复；新线程为 0）
     */
    NetThread(std::shared_ptr<NetFile> task, int64_t start, int64_t end, int64_t done);
    /** NetFile 内部兼容入口；构造时立即通过 shared_from_this 获取执行引用。 */
    NetThread(NetFile* task, int64_t start, int64_t end, int64_t done);
    ~NetThread();

    // 禁止复制 / 移动
    NetThread(const NetThread&) = delete;
    NetThread& operator=(const NetThread&) = delete;

    int64_t start() const { return start_; }
    int64_t end()   const { return end_.load(std::memory_order_acquire); }
    int64_t done()  const { return done_.load(std::memory_order_acquire); }
    int64_t length() const {
        int64_t e = end_.load(std::memory_order_acquire);
        return e < 0 ? -1 : e - start_ + 1;
    }

    /**
     * v4.10 自适应分段：把本段的 end 原子地缩小到 new_end（仅允许变小，单调）。
     *
     * 监控线程发现某文件下载偏慢时，会挑剩余最多的段调用本方法，让它提前在 new_end
     * 处收尾（onWrite 写满到 new_end 后返回 0 主动断流，performOnce 按"段已填满"判成功），
     * 腾出 (new_end, 旧end] 区间交给新拆出的并行线程下载 —— 对齐 PCL2 ModNet 的
     * "速度不足就拆最大碎片追加线程" 策略。
     *
     * end_ 用 atomic 保证无锁观察安全；真正的边界变更与 pwrite 由 write_boundary_mu_
     * 串行化。onWrite 在持锁写入前会二次读取最新 end，shrinkEndTo 返回后旧段不会再写入
     * (new_end, 旧end]，从而避免边界缩小后与新拆线程发生重叠写。
     *
     * @return 缩小成功返回缩小前的旧 end（供调用方构造新线程范围）；
     *         若 new_end 不落在 (start_+done_, 旧end) 之间（段已下过头/全量段/竞态）返回 -1。
     */
    int64_t shrinkEndTo(int64_t new_end);

    NetState state() const { return state_.load(std::memory_order_relaxed); }

    /**
     * 本轮 transfer 起点（steady-clock 毫秒，0=尚未开始）。
     * NetFile::maybeGrowThreads 用它 + done()==0 判定「停滞段」（久未取得任何字节，
     * 典型是被 HTTP 429 反复拒绝），从而把它从并发名额中剔除并优先切分。
     */
    int64_t transferStartMs() const { return transfer_start_ms_.load(std::memory_order_relaxed); }
    DownloadExceptionPtr error() const;

    /**
     * 200ms 滑动窗口速度（bytes/sec）。progress_callback 刷新 done_tick_ 后计算。
     * 未开始下载 / 刚结束几秒内都可能返回 0。
     */
    int64_t recentSpeedBps() const;

    /**
     * 不做新鲜度衰减的原始值（最后一次 progress_callback 算出的 bps）。
     * 仅供诊断/日志使用；聚合展示与 ETA 一律用 recentSpeedBps()，
     * 否则会把已停止推进的连接的历史峰值计入总速度（见 .cpp 注释）。
     */
    int64_t recentSpeedBpsRaw() const;

    /**
     * 线程主函数。WorkerPool 通过 std::thread 调用。
     * 内部会循环尝试多个 source，直到成功或全部失败。
     *
     * v4.4: 接受外部传入的 CURL* easy handle 以复用连接池。
     * worker 线程持有一个长期存活的 easy handle，跨文件复用 TCP 连接。
     * curl_easy_reset() 重置选项但保留内部连接缓存。
     * 传 nullptr 则内部创建（向后兼容）。
     */
    void run(CURL* reusable_easy = nullptr);

    /** 外部取消。curl_easy_perform 会在下一次 progress_callback 检测到并中止。 */
    void abort();

    /**
     * 执行侧已不再持有 curl callback/worker 栈引用时调用。幂等；首次调用会释放
     * NetFile keepalive，并在 keepalive 仍有效期间向文件 completion barrier 上报。
     */
    void markExecutionSettled();
    bool executionSettled() const {
        const uint64_t epoch = execution_epoch_.load(std::memory_order_acquire);
        return transport_settled_epoch_.load(std::memory_order_acquire) >= epoch &&
               completion_reported_epoch_.load(std::memory_order_acquire) >= epoch;
    }
    bool executionTransportSettled() const {
        const uint64_t epoch = execution_epoch_.load(std::memory_order_acquire);
        return transport_settled_epoch_.load(std::memory_order_acquire) >= epoch;
    }

    /** 文件级 retry 复用同一 segment 前开启新执行轮次；只允许 transport-settled -> active。 */
    bool prepareForRetryExecution();

    bool isAborted() const { return aborted_.load(std::memory_order_relaxed); }

    /** 用于 meta 序列化：快照当前段的 { start, end, done } */
    struct Snapshot { int64_t start, end, done; };
    Snapshot snapshot() const { return { start_, end_.load(std::memory_order_acquire), done() }; }

    // ---- v4.5: MultiDownloader 需要的公共接口 ----

    /** 所属 NetFile（MultiDownloader 需要 acquireFd/releaseFd/pickBestSource/fileSize） */
    NetFile* task() const { return task_; }

    /** 重置已下载字节数（重试时从头开始）+ 重置 stall 计时器 + 重置增量 SHA1 */
    void resetDone() {
        done_.store(0, std::memory_order_release);
        last_data_receive_ms_.store(0, std::memory_order_relaxed);
        // 把 stall 看门狗基线重新压到"现在"，而不是留成 0。留 0 会让
        // progress_callback 在首字节到达前失去唯一的计时基准，"连上却不吐字节"的段
        // 于是永不返回、文件永不收敛（进度卡死 + 速度 0 + 重试仍卡同一处）。
        transfer_start_ms_.store(netThreadSteadyNowMs(), std::memory_order_relaxed);
        // C-3 修复：用显式 reset() 替代 `= Sha1()`；语义清晰，避免将来 Sha1
        // 加入 RAII 资源时拷贝赋值悄悄泄漏
        sha1_hasher_.reset();
        write_errno_.store(0, std::memory_order_release);
    }

    /**
     * v4.6: 获取下载过程中增量计算的 SHA1（40 字符小写 hex）。
     * 仅对单段文件（start_==0 && 完整下载）有意义。
     * 多段文件的各段 SHA1 不等于整文件 SHA1，需要走传统 re-read 校验。
     */
    std::string finalSha1() { return sha1_hasher_.finalizeHex(); }
    bool isSingleSegment() const { return start_ == 0; }
    bool canUseFastHash() const { return start_ == 0 && initial_done_ == 0; }
    bool requiresRangeSupport() const {
        return start_ > 0 || done_.load(std::memory_order_acquire) > 0;
    }

    // Attempt state belongs to one file execution epoch. resetDone() only rewinds segment
    // contents and intentionally preserves it; prepareForRetryExecution() starts a new file-level
    // retry epoch and resets the consecutive no-progress budget before the segment is re-enqueued.
    bool tryBeginAttempt(int max_attempts = 30);
    int retryCount() const { return retry_count_.load(std::memory_order_acquire); }
    int64_t cumulativeRetryDelayMs() const { return retry_delay_ms_.load(std::memory_order_acquire); }
    bool addRetryDelayMs(int64_t delay_ms, int64_t total_budget_ms);
    void deferUntilMs(int64_t when_ms);
    int64_t retryNotBeforeMs() const { return retry_not_before_ms_.load(std::memory_order_acquire); }
    int64_t retryDeadlineMs() const { return retry_deadline_ms_.load(std::memory_order_acquire); }
    int writeErrno() const { return write_errno_.load(std::memory_order_acquire); }
    void clearWriteErrno() { write_errno_.store(0, std::memory_order_release); }
    DownloadExceptionPtr writeFailure(const std::string& url_context = {}) const;

    /** 设置 state（MultiDownloader 管理状态转换） */
    void setState(NetState s) { state_.store(s, std::memory_order_release); }

    /** 设置错误 */
    void setError(DownloadExceptionPtr ex);

    /**
     * v6（PCL2 对齐）：多源轮询——给本段指定一个"首选下载源"序号。
     * 高并发模式（max_connections>0）下，initSegments 会把不同段分配到不同源
     * （段0→源0、段1→源1…），让多个段同时从 官方CDN + 镜像 拉取，带宽相加；
     * 且同一个源不会被同一文件的多段并发 Range 命中，规避缓存代理（mcimirror）
     * 对并发 Range 返回不一致字节导致的拼接损坏。失败后重试会回退到 -1（按评分选最优源）。
     */
    void setPreferredSourceIdx(int idx) { preferred_source_idx_ = idx; }
    int  preferredSourceIdx() const { return preferred_source_idx_; }

    /**
     * v6（PCL2 加线程安全网）：本段当前正在使用的源序号（-1=未在下载）。
     * maybeGrowThreads 用它避免把新线程分到"已被本文件其他段并发使用"的源上，
     * 防止同一源被同一文件多段并发 Range 命中（mcimirror 等缓存代理会因此返回不一致字节）。
     */
    int  currentSourceId() const { return current_source_id_.load(std::memory_order_relaxed); }

    // curl callbacks（静态，通过 userdata=NetThread* 拿到 this）
    // MultiDownloader 也需要用，所以 public
    static size_t onWrite(char* ptr, size_t sz, size_t nmemb, void* userdata);
    static size_t onHeader(char* ptr, size_t sz, size_t nmemb, void* userdata);
    static int    onProgress(void* userdata, int64_t dltotal, int64_t dlnow,
                             int64_t ultotal, int64_t ulnow);

private:
    mutable std::mutex          execution_mu_;
    std::shared_ptr<NetFile>    task_keepalive_;
    NetFile* const              task_;
    std::atomic<uint64_t>       execution_epoch_{1};
    std::atomic<uint64_t>       transport_settled_epoch_{0};
    std::atomic<uint64_t>       completion_reported_epoch_{0};
    const int64_t           start_;
    const int64_t           initial_done_;
    // Boundary changes and writes share this mutex, so a successful split cannot
    // overlap any subsequent write from the old segment.
    mutable std::mutex      write_boundary_mu_;
    uint64_t                boundary_generation_{0};  // 仅在 write_boundary_mu_ 下访问
    // v4.10：end_ 改为 atomic —— 监控线程可能在 worker 下载途中调 shrinkEndTo 缩小它
    // 来做自适应分段（见 shrinkEndTo 注释）。只会变小，单调。
    std::atomic<int64_t>    end_;   // 可能在 HEAD 响应后才确定；自适应分段时会被缩小
    std::atomic<int64_t>    done_{0};

    std::atomic<NetState>   state_{NetState::WaitingForSchedule};
    std::atomic<bool>       aborted_{false};
    // 上一次 performOnce 是否"疑似族特异性失败且另一族还没试过"。
    // performOnce 置位、run() 的主机熔断判定消费 —— IPv6 不通不该拉黑整台主机。
    // 见 performOnce 里 noteFamilyOutcome 附近注释与 engine.h ipResolveFor。
    std::atomic<bool>       family_retry_pending_{false};
    // v6: 多源轮询的首选源序号（-1 = 无偏好，按评分选最优）。见 setPreferredSourceIdx。
    int                     preferred_source_idx_ = -1;
    // v6: 本段当前正在使用的源序号（performOnce 前置位，供 maybeGrowThreads 避让）。
    std::atomic<int>        current_source_id_{-1};

    // 错误由 last_error_mu_ 保护，因为是 shared_ptr 不是 atomic
    mutable std::mutex      last_error_mu_;
    DownloadExceptionPtr    last_error_;

    // AMCL: 最近一次成功交付字节的源（shared_ptr 需 mutex 保护）。SHA1 终检失败时
    // NetFile 据此定位坏内容源并 checksum_bad 排除 + 换源。
    mutable std::mutex      last_used_source_mu_;
    NetSourcePtr            last_used_source_;

    // 速度滑动窗口（由 progress_callback 写，recentSpeedBps 读）
    struct SpeedWindow {
        std::atomic<int64_t> last_ts_ms{0};
        std::atomic<int64_t> last_done{0};
        std::atomic<int64_t> last_speed_bps{0};
    };
    mutable SpeedWindow speed_;

    // v4.5b: 5 秒无数据主动断线（PCL2 §4.5）
    // onWrite 收到数据时更新，onProgress 检测超时后返回 1 让 curl 中止
    std::atomic<int64_t> last_data_receive_ms_{0};
    // 本次 transfer 的起点（performOnce 每次尝试前置）。作为 stall 看门狗在**首字节到达前**
    // 的基线：只有 last_data_receive_ms_ 时，"连上却一直不吐字节"的连接会让看门狗彻底失效，
    // 段永不返回 → 文件永不收敛（表现为进度卡在最后几十 KB、速度 0、重试仍卡同一处）。
    std::atomic<int64_t> transfer_start_ms_{0};
    std::atomic<int>     write_errno_{0};
    std::atomic<int>     retry_count_{0};
    std::atomic<int64_t> retry_delay_ms_{0};
    // 连续无有效进度的 steady-clock 截止时间：首次尝试建立；onWrite 持续推进，
    // prepareForRetryExecution 开启新的文件重试 epoch 时清零重建。
    std::atomic<int64_t> retry_deadline_ms_{0};
    std::atomic<int64_t> retry_not_before_ms_{0};
    std::atomic<int64_t> response_retry_after_ms_{0};
    std::atomic<bool> response_content_range_seen_{false};
    std::atomic<bool> response_content_range_valid_{false};
    std::atomic<int64_t> response_content_range_start_{-1};
    std::atomic<int64_t> response_content_range_end_{-1};
    std::atomic<int64_t> response_content_range_total_{-1};
    // 本次 HTTP 响应的状态码（onHeader 解析状态行填入；performOnce 及每个重定向跳前清零）。
    // 用途：onWrite 依据它丢弃 3xx 重定向响应体。手动 follow（CURLOPT_FOLLOWLOCATION=0）时，
    // 3xx 的响应体（如 "302 Found" HTML）会经 onWrite 混入 done_/SHA1，旧实现被迫在 follow
    // 时 resetDone() 归零——续传场景下这会把上一 attempt 已下的有效字节一起丢弃，表现为
    // 用户可见的"进度条倒退 + 反复从头下载"（真机 cdn.modrinth.com→307→cdn-alt 每次续传都触发）。
    // PCL2 用 HttpClient 自动 follow，302 响应体不进应用层，天然无此问题；这里对齐其语义。
    std::atomic<long> hdr_status_code_{0};

    // v4.6: 增量 SHA1 — 在 onWrite 中同步更新，下载完成时直接取结果，
    // 避免 onAllThreadsDone 在事件循环线程重新 fopen+fread+sha1+fclose
    Sha1 sha1_hasher_;

    /** 用指定 source 做一次完整的 curl_easy_perform；返回失败异常（空 = 成功） */
    DownloadExceptionPtr performOnce(NetSourcePtr source, CURL* easy);

public:
    /**
     * AMCL: 返回最近一次成功交付字节的源（run() 成功路径里记录）。供 NetFile 在 SHA1
     * 终检失败时定位"是哪个源给了内容不对的文件"，从而把它标记 checksum_bad 并换源重下。
     * 未成功交付过时返回 nullptr。线程安全（last_used_source_mu_ 保护 shared_ptr）。
     */
    NetSourcePtr lastUsedSource() const;

    /**
     * AMCL: 记录最近一次成功交付字节的源。worker 路径在 run() 内设置；multi（小文件单段）
     * 路径必须在 handleSuccess 里显式调用，否则 SHA1 终检失败时 NetFile 无法定位坏内容源，
     * 单段小文件的 checksum_bad 换源逻辑会静默失效。线程安全。
     */
    void setLastUsedSource(NetSourcePtr src);
};

using NetThreadPtr = std::shared_ptr<NetThread>;

} // namespace download
