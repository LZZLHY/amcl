/**
 * download/net_file.h — 单文件下载协调器
 *
 * 对应 PCL2 `NetFile`。职责：
 *   1. 管理一组 sources（镜像 URL）
 *   2. HEAD 请求确定 file_size（如果 sha1 预检通过可跳过 HEAD）
 *   3. 分段切片：根据 size 和 FilePieceLimit 切成 N 段，每段一个 NetThread
 *   4. 维护 fd（按需 open/close，共享给所有 NetThread 做 pwrite）
 *   5. 合并进度（各 thread.done() 求和）
 *   6. 断点恢复：启动时读 .download-meta.json 重建分段状态
 *   7. 下载完成后触发 FileChecker 做 sha1 最终校验
 *
 * 线程安全：threads_ / state_ / download_done_ 等被多个 NetThread 读写，
 *          统一用 mu_ 保护或 atomic。
 *
 * fd 管理（v4.2 重写）：
 *   - start() 不再 open fd（避免 3000+ assets 一次性耗尽 fd 配额）
 *   - NetThread::run() 调 acquireFd() 获取 fd（首次调用自动 open + ftruncate）
 *   - NetThread::run() 结束调 releaseFd()（refcount 归零时自动 close）
 *   - 保证同一文件的多个 segment 共享同一 fd（refcount 保护生命周期）
 *
 * 关键不同于 PCL2：
 *   - 不用 .part + merge，直接 pwrite 到最终文件
 *   - 文件预分配（ftruncate）创建稀疏文件，不占物理空间直到写入
 *   - 中断恢复时，文件本身（非 meta）里已经有部分数据，就在正确的 offset
 */
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

#include "exception.h"
#include "file_checker.h"
#include "net_source.h"
#include "net_state.h"
#include "net_thread.h"

namespace download {

class LoaderDownload;  // 前向声明

class NetFile : public std::enable_shared_from_this<NetFile> {
public:
    struct Config {
        std::string              local_path;
        std::vector<std::string> urls;       // 声明顺序 = 优先级
        FileChecker              check;
        // Stable task identity and the trusted filesystem boundary. Defaults preserve
        // source compatibility; callers should set allowed_root for untrusted paths.
        uint64_t                 task_id = 0;
        std::string              allowed_root;
        // 并发段数上限。PCL2 默认 32，我们保守先 4 段。
        // 历史坑：之前 smoke test 的 expected_size 写错了（预估 25036598 实际 24445539），
        // 看到每段 5.4 MB 处 "truncate" 以为是 CDN bug，排查了很久才定位到是 size 错。
        // Range 本身是 OK 的，多线程分段下载也是 OK 的。
        int                      piece_limit = 4;
        int                      piece_min_bytes = 2 * 1024 * 1024;  // 小于此值不切片（v4.7: 1→2MB）。
        // max_connections 是调用方可选的连接硬上限：
        //   0：不设调用点上限，目标并发可由引擎按文件大小自适应；
        //   1..piece_limit：纯上限，保留默认 2MiB 分段、连接复用和动态最快源选择；
        //   >piece_limit：高并发模式，使用更细分段与多源轮询等调优。
        // 这一区分允许 client 限制到 4 连接而不被当作 Forge/模组高并发任务。
        // 完整性仍由下载结束的 SHA1/size 终检兜底。
        int                      max_connections = 0;
    };

    explicit NetFile(Config cfg);
    ~NetFile();

    NetFile(const NetFile&) = delete;
    NetFile& operator=(const NetFile&) = delete;

    // ---- 只读访问 ----
    const std::string& localPath() const { return cfg_.local_path; }
    const std::string& stagingPath() const { return staging_path_; }
    const std::vector<NetSourcePtr>& sources() const { return sources_; }
    const FileChecker& checker() const { return cfg_.check; }
    uint64_t taskId() const { return cfg_.task_id; }
    NetState state() const { return state_.load(std::memory_order_relaxed); }
    int64_t  fileSize() const { return file_size_.load(std::memory_order_relaxed); }
    // v6.1：真正的高并发模式只指显式上限高于默认 piece_limit 的路径（当前为 5..16）。
    // 1..piece_limit 仅是硬上限：继续复用连接、使用默认分段和动态最快源选择；这让 client
    // 可以钳制到 beta.5 的 4 连接规模，而不会意外启用多源轮询与高并发超时策略。
    bool     isHighParallel() const { return cfg_.max_connections > cfg_.piece_limit; }
    int64_t  downloadedBytes() const;
    double   progress() const;   // 0.0 ~ 1.0，size 未知时返回 0
    DownloadExceptionPtr error() const;

    /**
     * 聚合该文件所有 thread 的 recentSpeedBps（滑动窗口 200ms）。供
     * LoaderDownload::computeProgress 汇总成任务级速度。
     *
     * 语义：只累加 Downloading / Connecting / Reading 状态的 thread；
     *       已 Finished 或 Failed 的 thread 不计入（其 recentSpeedBps 也会
     *       自然退回 0，但显式跳过更稳）。
     */
    int64_t sumRecentSpeedBps() const;

    /**
     * 本文件近期的平均下载速度（B/s）——**按本文件累计已下载字节的时间差**计算。
     *
     * 与 sumRecentSpeedBps() 的本质区别（2026-07-31）：后者把各段的 200ms 瞬时速率**相加**，
     * 而 `NetThread::recentSpeedBps()` 在采样超过 1500ms 未更新时返回 0、瞬时速率为 0 时也
     * 返回 0。于是任意一段处于 TTFB / 重连 / TLS 握手（真机实测 TTFB 1~4.4s）期间，它对聚合
     * 速度的贡献就是 0；4 段里有两段在握手，显示速度就从 2MB/s 掉到几百 KB/s，全在握手时更是
     * 掉到 B 级 —— 这正是「一会 MB 一会 KB 甚至到 B」的来源，是**度量伪影**而不是真实吞吐。
     *
     * PCL2 从一开始就不是这么算的（`ModNet.vb:784-795` NetFile.Speed / `ModNet.vb:598-609`
     * NetThread.Speed 同款公式）：
     *     If GetTimeMs() - SpeedLastTime > 200 Then
     *         _Speed = (DownloadDone - SpeedLastDone) / (DeltaTime / 1000)
     *         SpeedLastDone = DownloadDone : SpeedLastTime += DeltaTime
     *     Return _Speed
     * 即「累计字节增量 ÷ 时间增量」，且**两次采样之间沿用上次的值**（没有"过期归零"这回事）。
     * 某条连接在握手时只是让字节增量小一点，绝不会把整体清零。
     *
     * 与 PCL2 的偏差：窗口取 500ms（PCL2 是 200ms）并叠一层轻度 EWMA。原因是这个值直接展示给
     * 用户，而 200ms 窗口在分段下载上本身就会因 curl 写回调的成批投递而忽高忽低。
     */
    int64_t recentFileSpeedBps() const;

    /**
     * Engine 按顺序调用的生命周期方法。每个步骤可能返回 error：
     *   start()       — 打开 meta / 预检 sha1 / 决定 skip-download / ftruncate / 初始化 threads_
     *   launchMissingThreads() — 把未启动的 thread 送 WorkerPool 跑
     *   finalize()    — 最终 sha1 校验 + close fd + 删 meta
     *   abort()       — 取消所有 thread + 保留 meta 给下次续传
     */
    DownloadExceptionPtr start();
    std::vector<NetThreadPtr> threadsToLaunch();  // 快照待启动线程列表
    DownloadExceptionPtr finalize();
    void                  abort();

    /**
     * v5: 删除本地文件 + .download-meta。
     * 仅在 Aborted / Failed 状态下允许调用。返回释放的字节数。
     * Finished 状态下拒绝（用户可能仍想保留下好的文件）。
     */
    int64_t deleteLocalAndMeta();

    /**
     * v5: 从 Aborted/Failed 状态重置为可 start 的状态。
     *   - 清 error_, threads_done_count_
     *   - 保留 threads_ 自身和 done_ 字段（配合断点续传）
     *   - 重置 retry_count_，允许新一轮全局 retry
     * 调用者负责接下来再调 start() 重建 segments 与入队。
     */
    bool resetForRetry();

    /** 所有 NetThread 结束后（无论成功失败）调用。内部判断下一步走 finalize 还是 Failed */
    void onAllThreadsDone();

    /**
     * v7.4 自适应分段（IDM/aria2 式「保持 N 条连接满负荷」）：由 Engine ticker 每 ~200ms
     * 以及每段完成（reportThreadFinished）时对正在下载的文件调用。
     *
     * 目标并发驱动（不再是「速度低于地板才追加」）：只要活跃段（下载中 + 准备中）少于
     * target_connections_（由 initSegments 按文件大小/模式设定），就挑 ETA 最差的「慢长杆」段，
     * 用 NetThread::shrinkEndTo 把它的尾部减半，并为腾出的区间新建一个并行下载线程入队 ——
     * 用更多并发连接持续打满带宽（尤其大文件 90%+ 只剩一条慢尾段时仍能补位）。
     *
     * 安全护栏（任一不满足即本轮不动作，确保对正常快速下载零影响）：
     *   - 文件状态必须是 Downloading（无锁快筛后在 mu_ 下重算）；
     *   - 必须有强完整性校验（needsAnyCheck）——无 SHA1/size 的文件不做动态重叠拆段；
     *   - 文件足够大（>= kAdaptiveMinFileBytes），小文件天然单段/多路并发，不参与；
     *   - 活跃段（不含已完成段）< target_connections_（≤ kAdaptiveMaxThreads 硬上限）；
     *   - 已有段在稳定下载、且"准备中"的段不多于"下载中"的段（避免一轮加太多、连接还没 ramp）；
     *   - 存在剩余 >= kAdaptiveMinSplitBytes 的可拆大段（且该段支持 Range，即 end>=start）。
     */
    void maybeGrowThreads();

    /** 供 NetThread 访问（pwrite fd、选源、报错） */
    /**
     * 延迟 fd 管理（v4.2）：
     *   acquireFd() — 首次调用自动 open+ftruncate，后续调用 refcount++
     *   releaseFd() — refcount--，归零时 close fd
     *   fd()        — 返回当前 fd（可能 -1，调用方应先 acquireFd）
     */
    int  acquireFd();
    void releaseFd();
    int  fd() const;
    int  fdError() const;
    /**
     * 把 snapshot 已观察到的 staging 字节推进到稳定存储。返回 0 成功，否则 errno。
     * 即使当前没有打开的写 fd，也会 no-follow 打开 staging 并 fsync（恢复提交路径）。
     */
    int  syncStagingDurable();
    NetSourcePtr pickBestSource(bool needs_range = false, int preferred_idx = -1);
    int64_t nextSourceReadyMs(bool needs_range = false) const;

    /**
     * 当前处于传输中（Connecting / Reading / Downloading）的段数。
     * NetThread::onProgress 用它判断「掐掉这条僵尾连接是否安全」——只有还有别的段在跑时
     * 才允许放弃当前连接，单段文件绝不自杀（对齐 PCL2 的单线程豁免）。
     */
    int activeSegmentCount() const;
    void reportThreadFinished(NetThread* thr);  // 仅接受 executionSettled 的线程

    /** 当前文件的所有已创建 segment 是否都已离开 worker/curl callback。 */
    bool isExecutionSettled() const;

    /** 序列化当前状态为 DownloadMeta（供 engine 定时 flush 到磁盘） */
    struct MetaSnapshot { std::vector<NetThread::Snapshot> segments; int64_t file_size; };
    MetaSnapshot snapshotForMeta() const;

    /** 指向所属任务的弱引用（不持所有权，任务必须 outlive file） */
    void setOwner(LoaderDownload* owner) { owner_ = owner; }

private:
    const Config                cfg_;
    const std::string           staging_path_;
    std::vector<NetSourcePtr>   sources_;

    // 状态
    std::atomic<NetState>       state_{NetState::WaitingForSchedule};
    std::atomic<int64_t>        file_size_{-1};  // -1 未知 / -2 server 不支持 Content-Length
    int                         fd_{-1};
    // root_fd_ 是**借用**的共享目录 fd（TrustedRootFdPool，见 net_file.cpp 的 fd 治理注释）。
    // 生命周期由 root_fd_holder_ 引用计数管理；本类不得直接 close root_fd_。
    // 之所以共享：每文件独占一个常驻目录 fd 会把进程 fd 推过 FD_SETSIZE(1024)，
    // 而随包 libcurl 未启用 poll，Curl_poll 走 select 分支，fd>=1024 即整个事件循环永久失败。
    int                         root_fd_{-1};
    std::shared_ptr<void>       root_fd_holder_;
    uint64_t                    root_device_{0};
    uint64_t                    root_inode_{0};
    // acquire and final release are serialized by the same mutex. This deliberately
    // avoids the former load-then-increment race with close/fd-number reuse.
    mutable std::mutex          fd_init_mu_;
    int                         fd_refcount_{0};
    int                         fd_error_{0};
    bool                        staging_identity_set_{false};
    uint64_t                    staging_device_{0};
    uint64_t                    staging_inode_{0};
    bool                        resume_from_meta_{false};
    mutable std::mutex          mu_;
    std::vector<NetThreadPtr>   threads_;        // 已分段的线程列表
    std::vector<NetThreadPtr>   threads_pending_launch_;
    // A NetThread may be observed by both queue teardown and curl completion paths.
    // Guard completion by identity so a segment contributes to the barrier once per run.
    std::unordered_set<NetThread*> completed_threads_;
    std::atomic<int>            threads_done_count_{0};
    // Owner notification is also exactly-once for each start/retry epoch.
    std::atomic<bool>           terminal_reported_{false};
    // v7.4：目标并发段数（IDM/aria2 式「始终保持 N 条连接满负荷」）。initSegments 按
    // 文件大小/模式设定；maybeGrowThreads 以此为目标持续补段（不再只在慢于地板时补）。
    // 0 = 未初始化（回退到 kAdaptiveMaxThreads）。
    int                         target_connections_{0};

    // 上次自适应切段的时刻（steady-clock 毫秒，mu_ 保护）。
    // maybeGrowThreads 会被多个 worker 的 reportThreadFinished 与 ticker 的
    // growAllThreads 并发进入；仅靠"每次调用至多切 1 条"不足以限速——并发调用会在
    // 同一毫秒各切一条（真机实测同毫秒 8 次 adaptive split，段数爆炸后 meta 校验
    // 持续失败、任务被判 StorageIoError）。用最小间隔把切分全局节流。
    int64_t                     last_split_ms_{0};
    // Range 能力按 NetSource 记录。只有所有可用源都已明确不支持时才单段退化，
    // 不能再把首个探测源的结论提升为整个文件的 capability。
    bool                        all_sources_range_unsupported_{false};

    // recentFileSpeedBps() 的采样锚点。独立小锁，绝不与 mu_ 嵌套（downloadedBytes() 会取 mu_，
    // 所以 recentFileSpeedBps 必须在**不持有 mu_** 的位置调用）。
    mutable std::mutex          speed_sample_mu_;
    mutable int64_t             speed_sample_ms_{0};
    mutable int64_t             speed_sample_bytes_{0};
    mutable int64_t             speed_cached_bps_{0};

    // 自校准补段地板用的历史速度峰值（详见 maybeGrowThreads 里"速度门控"注释）。无锁读写。
    std::atomic<int64_t>        peak_speed_bps_{0};
    DownloadExceptionPtr        error_;

    LoaderDownload*             owner_{nullptr};

    // v4.6: 全局重试机会（对齐 HMCL/PCL2 多轮重试）
    // 所有 thread 都 Failed + 所有 source 都 is_failed 时，重置瞬时失败源重来。
    // 允许 kMaxFileRetries 轮重试，每轮只重置非 404 源。
    // v4.8 (2026-06-05)：3→8。实测 BMCLAPI /maven 节点抖动会 302→后端节点返回 403
    // （HMCL issue #4010 同款），官方 Forge maven 又会 5s 无数据 stall；二者都是"瞬时
    // 失败"，需要更多轮重试轮换节点/续传分段才能成功（Forge installer 实测官方源已完成
    // 3/4 分段，仅差 1 段因 stall 被 3 轮用尽而整体失败）。HMCL 的可靠性正来自多轮重试。
    static constexpr int        kMaxFileRetries = 8;
    int                         retry_count_{0};

    // v4.7: 多段 SHA1 失败 → 单段退化重试（最多 1 次）
    int                         sha1_fallback_to_single_{0};

    // AMCL (2026-07-16 实测 forgecdn 对含 '+' 文件名对象 Range 返回 404、整文件 GET 返回 200):
    // 分段下载彻底失败后的"末路兜底"——退化为单段整文件 GET 再试一次。整文件 GET 兼容性最强，
    // 能救回"HEAD/整文件 GET 正常、但对 Range 报错"的源。一次性，避免病态循环。
    bool                        single_segment_fullget_tried_{false};

    // AMCL: SHA1 终检失败换源 —— 当前源交付的内容哈希不符（典型：某镜像给了 Log4Shell
    // 打补丁后的 log4j jar，而 Forge 期望 Maven Central 原版哈希）。把交付坏内容的源标记
    // checksum_bad（pickBestSource 永久跳过），重建单段从下一个未排除源重下。bounded：
    // 最多 kMaxChecksumSourceSwaps 次，且无可用源时直接判失败，杜绝病态循环。
    static constexpr int        kMaxChecksumSourceSwaps = 6;
    int                         checksum_source_swaps_{0};

    // ---- 内部步骤 ----
    DownloadExceptionPtr preCheckExistingFile();  // sha1 命中则跳过下载
    DownloadExceptionPtr determineFileSize();     // HEAD 请求到 file_size
    void                 initSegments();           // 切片 + 创建 NetThread
    void                 restoreFromMeta(const struct DownloadMeta& meta);
    std::string          metaPath() const { return cfg_.local_path + ".download-meta"; }
    int                  openAndTruncate();
    DownloadExceptionPtr validatePaths() const;
    DownloadExceptionPtr syncCloseAndCommit();
    void                 discardStaging();
    void                 rebuildSingleSegment();
    void                 reportTerminalOnce();
};

using NetFilePtr = std::shared_ptr<NetFile>;

} // namespace download
