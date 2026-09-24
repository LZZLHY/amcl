/**
 * download/napi_bridge.h — C++ 引擎事件 → JS callback 桥接
 *
 * Progress 使用容量 1 的 latest-value mailbox：native 侧始终覆盖旧快照，TSFN
 * 队列中最多保留一个唤醒信号。Complete 使用独立可靠通道；终态同时可由
 * downloadQueryTask/downloadListActive 查询，避免 env closing 时永久丢失。
 */
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>

#include <napi/native_api.h>

#include "exception.h"
#include "loader_download.h"

namespace download {

class NapiProgressBridge : public std::enable_shared_from_this<NapiProgressBridge> {
public:
    static std::shared_ptr<NapiProgressBridge> Create(
        napi_env env, napi_value js_callback, uint64_t task_id);
    ~NapiProgressBridge();

    NapiProgressBridge(const NapiProgressBridge&) = delete;
    NapiProgressBridge& operator=(const NapiProgressBridge&) = delete;

    bool valid() const;
    uint64_t generation() const { return generation_; }

    /** Registry 在安装时绑定；用于 native 侧拒绝旧 registration 的排队事件。 */
    void bindGenerationGuard(std::shared_ptr<std::atomic<uint64_t>> guard);
    bool isCurrentGeneration() const;

    /** 任意线程调用；只保留尚未送达的最新进度。 */
    void push(const TaskProgress& progress);

    /** 使旧 generation 失效并中止尚未调用的旧 callback。幂等。 */
    void close();

private:
    NapiProgressBridge(napi_env env, napi_value js_callback,
                       uint64_t task_id, uint64_t generation);

    napi_threadsafe_function tsfn_ = nullptr;
    uint64_t task_id_ = 0;
    uint64_t generation_ = 0;
    std::atomic<bool> active_{true};
    std::shared_ptr<std::atomic<uint64_t>> generation_guard_;

    mutable std::mutex tsfn_mu_;
    std::mutex progress_mu_;
    TaskProgress latest_progress_;
    uint64_t highest_progress_epoch_ = 0; // progress_mu_ 保护；旧 execution 不得覆盖 mailbox
    bool has_latest_ = false;
    bool signal_pending_ = false;

    static void callJs(napi_env env, napi_value js_callback,
                       void* context, void* data);
};

class NapiCompleteBridge : public std::enable_shared_from_this<NapiCompleteBridge> {
public:
    static std::shared_ptr<NapiCompleteBridge> Create(
        napi_env env, napi_value js_callback, uint64_t task_id);
    ~NapiCompleteBridge();

    NapiCompleteBridge(const NapiCompleteBridge&) = delete;
    NapiCompleteBridge& operator=(const NapiCompleteBridge&) = delete;

    bool valid() const;
    uint64_t generation() const { return generation_; }

    /** Registry 在安装时绑定；用于 native 侧拒绝旧 registration 的排队事件。 */
    void bindGenerationGuard(std::shared_ptr<std::atomic<uint64_t>> guard);
    bool isCurrentGeneration() const;

    /**
     * exactly-once 尝试投递。返回 false 表示 env/TSFN 已关闭；调用方可通过
     * downloadQueryTask 获取同一任务的持久终态快照，不会 silent drop。
     */
    bool push(bool success, bool aborted, DownloadExceptionPtr err,
              const TaskProgress& final_progress,
              std::vector<FailedFileInfo> failed_files,
              int64_t duration_ms);

    void close();

private:
    NapiCompleteBridge(napi_env env, napi_value js_callback,
                       uint64_t task_id, uint64_t generation);

    napi_threadsafe_function tsfn_ = nullptr;
    uint64_t task_id_ = 0;
    uint64_t generation_ = 0;
    std::atomic<bool> active_{true};
    // Complete 是低频可靠事件。用互斥量串行 claim/入队，使“已成功入队”与
    // “仅观察到该 epoch”可区分；同 epoch 只有真正 queued 后才返回 true。
    std::mutex completion_mu_;
    uint64_t highest_observed_epoch_ = 0;
    uint64_t queued_completion_epoch_ = 0;
    std::shared_ptr<std::atomic<uint64_t>> generation_guard_;
    mutable std::mutex tsfn_mu_;

    static void callJs(napi_env env, napi_value js_callback,
                       void* context, void* data);
};

using NapiProgressBridgePtr = std::shared_ptr<NapiProgressBridge>;
using NapiCompleteBridgePtr = std::shared_ptr<NapiCompleteBridge>;

} // namespace download
