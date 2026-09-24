/**
 * download/loader_download.h — 一个下载任务（一组文件的集合）
 *
 * 对应 PCL2 `LoaderDownload`。一个 LoaderDownload 代表 UI 上显示的一个"任务卡片"，
 * 内含一批 NetFile（例如"下载 Minecraft 1.20.4"可能包含 1 个 client.jar + N 个
 * libraries + N 个 assets，合起来几百个文件）。
 *
 * 对 ArkTS / UI 层提供的视图：
 *   - name：任务名（用于 UI 标题）
 *   - state：LoadState（Waiting/Loading/Finished/Failed/Aborted）
 *   - progress：0.0 ~ 1.0，所有文件字节加权平均
 *   - currentFile：正在活跃下载的第一个文件（展示用）
 *   - filesDone / filesTotal
 *   - recentSpeedBps：所有活跃 thread 的 recentSpeedBps 求和
 *
 * 对 Engine 的接口：
 *   - files()：获取文件列表（Engine 会遍历并启动各 NetFile）
 *   - reportFileFinished()：每个 NetFile finalize 后调
 *
 * 事件回调：
 *   - onStateChanged / onProgressChanged / onComplete
 *   - 在任意线程触发，NAPI 层 uv_async_send 到 UI 线程
 *   - onProgressChanged 由 Engine 的全局 progress tick 定时触发（不是 NetThread 每次）
 */
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

#include "exception.h"
#include "net_file.h"
#include "net_state.h"

namespace download {

struct TaskProgress {
    uint64_t             execution_epoch = 0;        // start/resume/retry generation
    double               overall_progress = 0.0;   // 0 ~ 1
    int64_t              speed_bps        = 0;
    int                  active_threads   = 0;
    std::string          current_file;             // 展示用：第一个未完成文件的 local_path
    int                  files_done       = 0;
    int                  files_total      = 0;
    int64_t              bytes_done       = 0;
    int64_t              bytes_total      = 0;     // -1 = 部分文件 size 未知
    // v5 新增：剩余秒数。-1 = 未知（bytes_total 未知或速度为 0）
    int64_t              eta_seconds      = -1;
    // v5 新增：当前活跃下载的文件 basename 列表（最多 3 个，展示用）
    std::vector<std::string> current_files;
};

/**
 * v5: 失败文件详情（供 UI 展示"哪个文件挂了、试过哪些源"）。
 * 仅 LoaderDownload 终态为 Failed 时通过 failedFiles() 聚合。
 */
struct FailedFileInfo {
    std::string              local_path;   // 完整路径（UI 可 basename）
    DownloadExceptionPtr     last_error;   // 最后一次错误（可能为空）
    std::vector<std::string> tried_urls;   // 所有试过的源 URL
};

class LoaderDownload : public std::enable_shared_from_this<LoaderDownload> {
public:
    // NAPI 层可能用的回调。无 thread affinity，内部会在 Engine 的线程里触发。
    using StateChangedCb    = std::function<void(LoadState old_state, LoadState new_state)>;
    using ProgressChangedCb = std::function<void(const TaskProgress&)>;
    // v5: 完成回调带 aborted 标志，用于 UI 区分"用户取消"和"下载失败"。
    //   success=true  / aborted=false → Finished
    //   success=false / aborted=true  → Aborted（用户主动取消）
    //   success=false / aborted=false → Failed
    // final_progress 是任务终态前的一次 computeProgress 快照（小文件秒下时 UI 直接用）。
    using CompleteCb        = std::function<void(bool success, bool aborted,
                                                 DownloadExceptionPtr err,
                                                 const TaskProgress& final_progress)>;

    struct Config {
        uint64_t                 task_id = 0;   // 由 Engine 生成
        std::string              name;
        std::vector<NetFile::Config> files;
    };

    explicit LoaderDownload(Config cfg);
    ~LoaderDownload();

    LoaderDownload(const LoaderDownload&) = delete;
    LoaderDownload& operator=(const LoaderDownload&) = delete;

    // ---- 只读 ----
    uint64_t                   taskId() const { return cfg_.task_id; }
    const std::string&         name() const { return cfg_.name; }
    LoadState                  state() const { return state_.load(std::memory_order_relaxed); }
    TaskProgress               computeProgress() const;
    DownloadExceptionPtr       error() const;
    const std::vector<NetFilePtr>& files() const { return files_; }
    /** v5: 任务启动到当前（或终态）的毫秒数；未启动返回 0 */
    int64_t                    durationMs() const;
    /** v5: 聚合所有 NetState::Failed 的文件（last_error + tried_urls），供 UI 展示 */
    std::vector<FailedFileInfo> failedFiles() const;

    // ---- 生命周期 ----
    /** Engine 启动时调用：创建 NetFile + 设置 state=Loading */
    void onStart();
    /** 单个文件完成（成功或失败）；仅接受终态文件，按 NetFile* exactly-once。 */
    void reportFileFinished(NetFile* f);
    /** Engine startup 在取消发生于 NetFile::start 前时，用逻辑 Aborted 收敛该文件。 */
    void reportFileAbortedBeforeStart(NetFile* f);
    /** Engine 在实际入队时登记 NetThread，供 active_threads 做严格线程态统计。 */
    void trackThreadsForProgress(const std::vector<NetThreadPtr>& threads);
    /** 外部取消 */
    void abort();
    bool isAbortRequested() const { return abort_requested_.load(std::memory_order_acquire); }
    /** 所有文件的 worker/multi 执行引用均已释放；purge/retry 的硬门禁。 */
    bool isExecutionSettled() const;

    /** Engine startup/retry 用：当前 epoch 是否允许启动该文件。 */
    bool shouldStartFile(const NetFile* file) const;
    uint64_t selectionEpoch() const { return selection_epoch_.load(std::memory_order_acquire); }

    /** Engine 内部错误通道：连续 meta 持久化失败会让任务明确失败而非静默丢恢复点。 */
    void reportMetaPersistenceResult(bool success, const std::string& meta_path);

    /** Engine 注册的独立终态观察者，不会被 NAPI 的 onComplete 覆盖。 */
    void setOnTerminal(std::function<void(uint64_t)> cb);

    /** 创建阶段配置/ownership 冲突的可观察拒绝。 */
    void reject(DownloadExceptionPtr ex);
    /**
     * v5: 清理磁盘残留（Aborted / Failed 状态下才允许调用）。
     * 对每个非 Finished 的文件 unlink(local) + unlink(.download-meta)。
     * 返回释放的字节数。调 cancel + 用户选"清理"路径。
     */
    int64_t deleteFilesOnDisk();
    /**
     * v5: 从 Aborted 状态复位成 Waiting，重置失败计数、清理 error_，
     * 配合 engine.resumeTask 使用。仅当状态是 Aborted 时有效。
     * 文件级状态保留（meta/local 不动），配合断点续传。
     */
    bool resetToWaiting();
    /**
     * v5: 只重试指定路径的失败文件。
     * 把目标文件里 Failed/Aborted 的线程清 error、重置状态入队。
     * 对成功的文件不动。任务整体状态若为 Failed/Aborted 会被拉回 Loading。
     */
    bool retryFailedFiles(const std::vector<std::string>& local_paths);

    // ---- 回调注册 ----
    void setOnStateChanged(StateChangedCb cb);
    void setOnProgressChanged(ProgressChangedCb cb);
    void setOnComplete(CompleteCb cb);

    /** Engine 定时触发：调 computeProgress 并且如果变化超过阈值就 fire callback */
    void tickProgress();

private:
    const Config             cfg_;
    std::vector<NetFilePtr>  files_;

    std::atomic<LoadState>   state_{LoadState::Waiting};
    std::atomic<int>         files_done_count_{0};
    // v4.1 fix：单 file Failed 不再 cascading abort 整个任务。每个 file 收敛时走
    // reportFileFinished，若是 Failed 则 files_failed_count_++，其他 file 继续
    // 跑。所有 file 都收敛（done_count == files_.size()）后才做整体判定：
    //   - failed == 0   → LoadState::Finished
    //   - failed >  0   → LoadState::Failed（保留首个 error_ 用于上报）
    //   - 外部 abort() 已经 transit 到 Aborted，本函数尊重
    // 这是 v4 文档 § 二 gap #1 "cascading abort" 的修复，也是 3805/3805 全败的
    // 直接根因。
    std::atomic<int>         files_failed_count_{0};
    // H-4 修复：单文件 Aborted（不走 task->abort() 的边缘路径，例如 Engine shutdown
    // 直接把 multi 池里的 thread 都置 Aborted）需要被 task 终态识别。否则任务会
    // 误判为 Finished，UI 报告下载成功。
    std::atomic<int>         files_aborted_count_{0};
    // v5 bugfix: abort() 设此 flag 而非直接 store Aborted（避免 transitTo 的
    // exchange 判重跳过 onComplete 回调）。reportFileFinished 收敛时检查此 flag。
    std::atomic<bool>        abort_requested_{false};
    std::atomic<bool>        infrastructure_failure_{false};
    std::atomic<int>         consecutive_meta_failures_{0};

    // 每个 retry epoch 的启动选择与 exactly-once 文件收敛守卫。
    mutable std::mutex       completion_mu_;
    std::unordered_set<const NetFile*> completed_files_;
    std::unordered_set<std::string> selected_retry_paths_;
    bool                     selection_enabled_{false};
    std::atomic<uint64_t>    selection_epoch_{0};

    // Threads are registered exactly once when Engine enqueues them. Weak references avoid
    // extending segment lifetime; the set prevents retry/requeue from double-counting.
    mutable std::mutex progress_threads_mu_;
    mutable std::vector<std::pair<const NetThread*, std::weak_ptr<NetThread>>> tracked_threads_;
    mutable std::unordered_set<const NetThread*> tracked_thread_ids_;

    mutable std::mutex       mu_;
    DownloadExceptionPtr     error_;

    // v4.2 P1: 预计算缓存，避免每次 tick 遍历全部文件
    int64_t                  bytes_total_precomputed_{0};  // onStart 时一次性算好
    bool                     all_sizes_known_{true};       // 是否所有文件都有 expected_size

    // 上次 tick 推送给 UI 的数据，用于比较是否值得再推
    // H-5 修复：由 mu_ 保护（与 error_ 同 mutex）。ticker 线程 + NAPI 线程
    // 都会写此字段（tickProgress 写、resetToWaiting 写），非原子 double/int 在
    // aarch64 弱内存模型下会撕裂读 → 节流逻辑误判。
    double                   last_pushed_progress_ = -1.0;
    int                      last_pushed_files_done_ = -1;
    int64_t                  last_pushed_speed_bps_ = -1;
    int64_t                  last_pushed_eta_seconds_ = -2;
    int                      last_pushed_active_threads_ = -1;
    std::string              last_pushed_current_file_;
    std::vector<std::string> last_pushed_current_files_;
    int64_t                  last_pushed_bytes_done_ = -1;
    int64_t                  last_pushed_bytes_total_ = -2;
    int64_t                  last_push_at_ms_ = 0;

    // v5: 任务启动/终态的 steady_clock 时间戳（毫秒）。onStart 时设，
    // transitTo 到终态时 stop，供 NAPI 层算 durationMs 字段。
    std::atomic<int64_t>     started_at_ms_{0};
    std::atomic<int64_t>     finished_at_ms_{0};

    StateChangedCb           on_state_changed_;
    ProgressChangedCb        on_progress_changed_;
    CompleteCb               on_complete_;
    std::function<void(uint64_t)> on_terminal_;

    void transitTo(LoadState new_state);
    void setError(DownloadExceptionPtr ex);
    void settleFile_(NetFile* f, NetState terminal_state, bool require_file_terminal);
};

using LoaderDownloadPtr = std::shared_ptr<LoaderDownload>;

} // namespace download
