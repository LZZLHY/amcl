/**
 * engine.cpp — 全局下载引擎单例
 *
 * 懒启动：第一次 createTask() 时自动 start()，外部也可以显式 start({cfg})。
 *
 * WorkerPool：
 *   - N 个 worker 线程阻塞在 queue_cv_，有 pending thread 就拿一个跑 run()
 *   - NetThread 是一次性（run 完就报 done，不会重入），worker 只负责调 run()
 *
 * Ticker：
 *   - 一个独立线程，按 progress_tick_interval_ms 定时调所有 task 的 tickProgress
 *   - 按 meta_flush_interval_ms 定时 flush 所有活跃 NetFile 的 meta 到磁盘
 */
#include "engine.h"
#include "transport_policy.h"
#include "host_admission.h"

#include <curl/curl.h>
#include <fcntl.h>     // 2026-08-04：probeNextFreeFdForDiag 用 ::open 探 fd 水位
#include <hilog/log.h>
#include <unistd.h>    // 同上：::close

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <thread>

#include "config.h"
#include "download_meta.h"

#include "../utils/amcl_log.h"

#undef LOG_TAG
#define LOG_TAG "DL_ENGINE"

namespace download {

namespace {

/**
 * 从 URL 取 host，用作每主机地址族评分表的 key。
 * 与 net_thread.cpp 的 extractHostForSlot 同语义（取首个 host），两处 key 必须一致，
 * 否则下载路径积累的评分在元数据路径上查不到。
 */
std::string familyHostFromUrl(const std::string& url) { return transportHost(url); }

bool canonicalizeTaskPaths(LoaderDownload::Config& cfg, std::string& error) {
    namespace fs = std::filesystem;
    for (auto& file : cfg.files) {
        if (file.local_path.empty() || file.allowed_root.empty()) {
            error = "local_path and allowed_root are required";
            return false;
        }
        fs::path path(file.local_path);
        fs::path root(file.allowed_root);
        if (!path.is_absolute() || !root.is_absolute()) {
            error = "local_path and allowed_root must be absolute";
            return false;
        }
        std::error_code ec;
        root = fs::weakly_canonical(root, ec);
        if (ec || root.empty()) {
            error = "failed to canonicalize allowed_root";
            return false;
        }
        path = fs::weakly_canonical(path, ec);
        if (ec || path.empty() || path == root) {
            error = "failed to canonicalize local_path or path equals root";
            return false;
        }
        auto root_it = root.begin();
        auto path_it = path.begin();
        for (; root_it != root.end(); ++root_it, ++path_it) {
            if (path_it == path.end() || *root_it != *path_it) {
                error = "local_path escapes allowed_root";
                return false;
            }
        }
        file.local_path = path.string();
        file.allowed_root = root.string();
    }
    return true;
}

} // namespace

DownloadEngine& DownloadEngine::instance() {
    static DownloadEngine inst;
    return inst;
}

DownloadEngine::~DownloadEngine() {
    shutdown();
}

// curl 全局状态仅在 curl_init_mu_ 下改变；成功后才发布，失败允许后续重试。
bool DownloadEngine::ensureCurlInited(std::string* out_err_kind, std::string* out_err_msg) {
    std::lock_guard<std::mutex> lk(curl_init_mu_);
    if (shutdown_requested_.load(std::memory_order_acquire)) {
        if (out_err_kind) *out_err_kind = "Aborted";
        if (out_err_msg) *out_err_msg = "download engine is shut down";
        return false;
    }
    if (curl_inited_.load(std::memory_order_relaxed)) return true;

    CURLcode rc = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (rc != CURLE_OK) {
        AMCL_LOG_E(LOG_TAG, "curl_global_init failed: %{public}d (%{public}s)",
                     (int)rc, curl_easy_strerror(rc));
        if (out_err_kind) *out_err_kind = "Unknown";
        if (out_err_msg) {
            *out_err_msg = "curl_global_init failed: " + std::string(curl_easy_strerror(rc));
        }
        return false;
    }
    curl_inited_.store(true, std::memory_order_release);
    return true;
}

bool DownloadEngine::acquireCurlUse(std::string* out_err_kind, std::string* out_err_msg) {
    std::lock_guard<std::mutex> lk(curl_init_mu_);
    if (shutdown_requested_.load(std::memory_order_acquire)) {
        if (out_err_kind) *out_err_kind = "Aborted";
        if (out_err_msg) *out_err_msg = "download engine is shut down";
        return false;
    }
    if (!curl_inited_.load(std::memory_order_relaxed)) {
        CURLcode rc = curl_global_init(CURL_GLOBAL_DEFAULT);
        if (rc != CURLE_OK) {
            if (out_err_kind) *out_err_kind = "Unknown";
            if (out_err_msg) {
                *out_err_msg = "curl_global_init failed: " + std::string(curl_easy_strerror(rc));
            }
            return false;
        }
        curl_inited_.store(true, std::memory_order_release);
    }
    ++active_curl_users_;
    return true;
}

void DownloadEngine::releaseCurlUse() {
    std::lock_guard<std::mutex> lk(curl_init_mu_);
    if (active_curl_users_ > 0 && --active_curl_users_ == 0) curl_users_cv_.notify_all();
}

void DownloadEngine::reapCompletedStartupThreads_() {
    std::vector<std::thread> completed_threads;
    {
        std::lock_guard<std::mutex> lk(startup_mu_);
        auto it = startup_threads_.begin();
        while (it != startup_threads_.end()) {
            if (it->completed && it->completed->load(std::memory_order_acquire)) {
                completed_threads.push_back(std::move(it->thread));
                it = startup_threads_.erase(it);
            } else {
                ++it;
            }
        }
    }
    for (auto& thread : completed_threads) {
        if (thread.joinable()) thread.join();
    }
}

void DownloadEngine::finishStartup_(
        uint64_t task_id, const std::shared_ptr<std::atomic<bool>>& completed) {
    {
        std::lock_guard<std::mutex> lk(startup_mu_);
        auto it = active_startups_.find(task_id);
        if (it != active_startups_.end()) {
            if (it->second <= 1) active_startups_.erase(it);
            else --it->second;
        }
        completed->store(true, std::memory_order_release);
    }
}

DownloadEngine::TaskOperationGuard::~TaskOperationGuard() {
    if (engine) engine->finishTaskOperation_(task_id);
}

bool DownloadEngine::taskExecutionSettledLocked_(const LoaderDownloadPtr& task) {
    // 调用者已持 task_mu_，统一保持 task -> startup 锁序；不能从 startup_mu_ 反入。
    if (!task || active_task_operations_.count(task->taskId()) != 0) return false;
    std::lock_guard<std::mutex> startup_lk(startup_mu_);
    if (active_startups_.count(task->taskId()) != 0) return false;
    return task->isExecutionSettled();
}

bool DownloadEngine::reclaimTaskLocked_(uint64_t task_id) {
    auto it = tasks_.find(task_id);
    if (it == tasks_.end()) return false;
    const LoadState state = it->second->state();
    if ((state != LoadState::Finished && state != LoadState::Failed &&
         state != LoadState::Aborted) || !taskExecutionSettledLocked_(it->second)) return false;
    for (const auto& file : it->second->files()) {
        auto owner = path_owners_.find(file->localPath());
        if (owner != path_owners_.end() && owner->second == task_id) path_owners_.erase(owner);
    }
    // 自动回收与 purge 共享动作；从 tasks_ 摘走之前同时释放 SH，避免 ticker 永远
    // 再也找不到已移除任务、使更新安装的 EX 被无主读租约永久阻塞。
    update_read_leases_.erase(task_id);
    tasks_.erase(it);
    return true;
}

bool DownloadEngine::beginTaskOperation_(uint64_t task_id, LoaderDownloadPtr& task,
                                        TaskOperationGuard& guard, bool require_settled) {
    std::lock_guard<std::mutex> lifecycle_lk(lifecycle_mu_);
    if (lifecycle_state_ != LifecycleState::Running) return false;
    std::lock_guard<std::mutex> task_lk(task_mu_);
    auto it = tasks_.find(task_id);
    if (it == tasks_.end() || active_task_operations_.count(task_id) != 0) return false;
    // 已持有的快照可能来自旧一轮 ticker；不能让它作用于已被回收/替换的 owner。
    if (task && task != it->second) return false;
    if (require_settled && !taskExecutionSettledLocked_(it->second)) return false;
    active_task_operations_.insert(task_id);
    task = it->second;
    guard.engine = this;
    guard.task_id = task_id;
    return true;
}

void DownloadEngine::finishTaskOperation_(uint64_t task_id) {
    {
        std::lock_guard<std::mutex> task_lk(task_mu_);
        active_task_operations_.erase(task_id);
    }
    task_operations_cv_.notify_all();
    // startup 可同步结束（空任务/缓存命中/取消）；预占归还后唤醒最后一轮 SH 收尾。
    wakeTicker_();
}

void DownloadEngine::start() {
    Config defaults;
    start(defaults);
}

void DownloadEngine::start(const Config& cfg) {
    std::unique_lock<std::mutex> lifecycle_lk(lifecycle_mu_);
    if (lifecycle_state_ == LifecycleState::Running) return;
    if (lifecycle_state_ == LifecycleState::ShuttingDown ||
        lifecycle_state_ == LifecycleState::Shutdown) {
        AMCL_LOG_W(LOG_TAG, "DownloadEngine start rejected after shutdown");
        return;
    }

    cfg_ = cfg;
    warmed_up_.store(false, std::memory_order_release);
    active_threads_.store(0, std::memory_order_release);
    last_launch_us_.store(0, std::memory_order_release);

    if (!ensureCurlInited(nullptr, nullptr)) return;

    try {
        if (!curl_share_) {
            curl_share_ = curl_share_init();
            if (curl_share_) {
                curl_share_setopt(curl_share_, CURLSHOPT_SHARE, CURL_LOCK_DATA_DNS);
                curl_share_setopt(curl_share_, CURLSHOPT_LOCKFUNC, curlShareLock);
                curl_share_setopt(curl_share_, CURLSHOPT_UNLOCKFUNC, curlShareUnlock);
                curl_share_setopt(curl_share_, CURLSHOPT_USERDATA, this);
            }
        }

        // 线程在 running_ 发布后启动；shutdown 必须先取得 lifecycle_mu_，因此不会
        // 在本临界区内撤销这些资源。
        running_.store(true, std::memory_order_release);

        MultiDownloader::Config multi_cfg;
        multi_cfg.max_concurrent = 64;
        multi_cfg.connect_timeout_s = 10;
        multi_cfg.total_timeout_s = 30;
        multi_downloader_ = std::make_unique<MultiDownloader>(multi_cfg);
        multi_downloader_->start();

        int worker_count = std::max(1, cfg_.worker_pool_size);
        if (cfg_.cold_start_warm_threshold > worker_count) {
            AMCL_LOG_W(LOG_TAG,
                "cold_start_warm_threshold=%{public}d > worker_pool_size=%{public}d; clamped",
                cfg_.cold_start_warm_threshold, worker_count);
            cfg_.cold_start_warm_threshold = worker_count;
        }
        workers_.reserve(worker_count);
        for (int i = 0; i < worker_count; ++i) {
            workers_.emplace_back([this] { workerLoop(); });
        }
        ticker_ = std::thread([this] { tickerLoop(); });
        lifecycle_state_ = LifecycleState::Running;

        AMCL_LOG_I(LOG_TAG,
            "DownloadEngine started: multi_concurrent=%{public}d workers=%{public}d warm_threshold=%{public}d",
            multi_cfg.max_concurrent, worker_count, cfg_.cold_start_warm_threshold);
    } catch (const std::exception& ex) {
        running_.store(false, std::memory_order_release);
        queue_cv_.notify_all();
        wakeTicker_();
        if (multi_downloader_) {
            multi_downloader_->shutdown();
            multi_downloader_.reset();
        }
        for (auto& t : workers_) if (t.joinable()) t.join();
        workers_.clear();
        if (ticker_.joinable()) ticker_.join();
        if (curl_share_) {
            curl_share_cleanup(curl_share_);
            curl_share_ = nullptr;
        }
        lifecycle_state_ = LifecycleState::Stopped;
        AMCL_LOG_E(LOG_TAG, "DownloadEngine start failed: %{public}s", ex.what());
    }
}

void DownloadEngine::shutdown() {
    // 必须在取得锁、发布 ShuttingDown 之前拒绝内部同步反入；否则 operation/callback
    // 会等待自己，worker/startup/ticker/multi 会 join 自己，关闭本身的终态 callback
    // 再次 shutdown 还会等待尚未返回的首个调用。void/NAPI 合同保留，不抛跨边界异常。
    if (DownloadExecutionContext::active()) {
        AMCL_LOG_W(LOG_TAG, "shutdown rejected from internal download execution or synchronous callback; use external lifecycle owner");
        return;
    }
    DownloadExecutionContext shutdown_context;
    {
        std::unique_lock<std::mutex> lk(lifecycle_mu_);
        if (lifecycle_state_ == LifecycleState::Shutdown) return;
        if (lifecycle_state_ == LifecycleState::ShuttingDown) {
            lifecycle_cv_.wait(lk, [this] {
                return lifecycle_state_ == LifecycleState::Shutdown;
            });
            return;
        }
        lifecycle_state_ = LifecycleState::ShuttingDown;
        shutdown_requested_.store(true, std::memory_order_release);
        running_.store(false, std::memory_order_release);
    }

    // 不持 lifecycle_mu_ 调任务回调或 join，避免回调反入 Engine 造成死锁。
    std::vector<LoaderDownloadPtr> tasks;
    {
        std::lock_guard<std::mutex> lk(task_mu_);
        tasks.reserve(tasks_.size());
        for (auto& kv : tasks_) tasks.push_back(kv.second);
    }
    for (auto& task : tasks) task->abort();

    // start/delete/磁盘维护可能在 shutdown 发布前已经离开短临界区；必须等它们
    // 归还预占后再销毁 curl/队列/SH。此处不持 lifecycle_mu_，回调反入仍可返回。
    {
        std::unique_lock<std::mutex> task_lk(task_mu_);
        task_operations_cv_.wait(task_lk, [this] { return active_task_operations_.empty(); });
    }

    std::vector<ManagedStartupThread> startup_threads;
    {
        std::lock_guard<std::mutex> lk(startup_mu_);
        startup_threads.swap(startup_threads_);
    }
    for (auto& managed : startup_threads) {
        if (managed.thread.joinable()) managed.thread.join();
    }
    {
        std::lock_guard<std::mutex> lk(startup_mu_);
        active_startups_.clear();
    }

    if (multi_downloader_) {
        multi_downloader_->shutdown();
        multi_downloader_.reset();
    }

    std::vector<NetThreadPtr> pending;
    {
        std::lock_guard<std::mutex> lk(queue_mu_);
        for (auto& kv : pending_threads_by_task_) {
            while (!kv.second.empty()) {
                pending.push_back(std::move(kv.second.front()));
                kv.second.pop_front();
            }
        }
        pending_threads_by_task_.clear();
        pending_task_order_.clear();
    }
    settleThreadsAborted(std::move(pending));

    queue_cv_.notify_all();
    for (auto& t : workers_) if (t.joinable()) t.join();
    workers_.clear();

    wakeTicker_();
    if (ticker_.joinable()) ticker_.join();
    // 所有startup/multi/worker/ticker已退出，此时才释放残留SH租约；UI取消时不提前释放。
    { std::lock_guard<std::mutex> lock(task_mu_); update_read_leases_.clear(); }

    if (curl_share_) {
        curl_share_cleanup(curl_share_);
        curl_share_ = nullptr;
    }

    {
        std::unique_lock<std::mutex> curl_lk(curl_init_mu_);
        curl_users_cv_.wait(curl_lk, [this] { return active_curl_users_ == 0; });
        if (curl_inited_.exchange(false, std::memory_order_acq_rel)) curl_global_cleanup();
    }

    {
        std::lock_guard<std::mutex> lk(lifecycle_mu_);
        lifecycle_state_ = LifecycleState::Shutdown;
    }
    lifecycle_cv_.notify_all();
    AMCL_LOG_I(LOG_TAG, "DownloadEngine shutdown");
}

LoaderDownloadPtr DownloadEngine::createTask(LoaderDownload::Config cfg) {
    if (!running_.load(std::memory_order_acquire) &&
        !shutdown_requested_.load(std::memory_order_acquire)) {
        start();
    }

    cfg.task_id = next_task_id_.fetch_add(1, std::memory_order_acq_rel);
    std::string config_error;
    canonicalizeTaskPaths(cfg, config_error);
    auto task = std::make_shared<LoaderDownload>(std::move(cfg));

    std::string conflict_path;
    std::string conflict_reason = config_error;
    // 与新任务目标路径冲突、但已终态且执行未完全收敛的旧任务：在释放锁后请求其 abort，
    // 让其线程尽快退出并进入可回收状态。避免"上一次下载失败/停滞的任务永久占用文件路径，
    // 导致重下必须冷启动"。abort 不能在持锁时调用（回调可能反入 Engine 造成死锁）。
    std::vector<LoaderDownloadPtr> stale_owners_to_abort;
    {
        std::unique_lock<std::mutex> lifecycle_lk(lifecycle_mu_);
        if (lifecycle_state_ != LifecycleState::Running) {
            // reject 会同步转态并投递 callback；即使当前新任务通常尚无观察者，也不能
            // 把“暂无 callback”当作锁内调用的授权，必须沿用所有拒绝路径的锁外合同。
            lifecycle_lk.unlock();
            task->reject(makeException(ErrorKind::InternalError,
                "download engine is not accepting tasks after shutdown"));
            return task;
        }

        std::lock_guard<std::mutex> task_lk(task_mu_);
        std::unordered_set<std::string> unique_paths;
        unique_paths.reserve(task->files().size());
        if (conflict_reason.empty()) {
            for (const auto& file : task->files()) {
                const std::string& path = file->localPath();
                if (!unique_paths.insert(path).second) {
                    conflict_path = path;
                    conflict_reason = "duplicate final path in task";
                    break;
                }
                auto owner = path_owners_.find(path);
                if (owner == path_owners_.end() || owner->second == task->taskId()) continue;

                const uint64_t owner_id = owner->second;
                auto owner_it = tasks_.find(owner_id);
                if (owner_it == tasks_.end()) {
                    // 陈旧所有权：旧任务已不在 tasks_（已被 purge），条目残留 → 直接清理视为无主。
                    path_owners_.erase(owner);
                    continue;
                }

                const LoadState os = owner_it->second->state();
                const bool terminal = (os == LoadState::Finished || os == LoadState::Failed ||
                                       os == LoadState::Aborted);
                if (terminal && reclaimTaskLocked_(owner_id)) {
                    // 与 purge 同一完整屏障；旧 startup、完成回调或维护仍活跃时拒绝。
                    // path 现在无主，本轮循环末尾会统一登记给新任务。
                    continue;
                }

                // 旧任务仍活跃或正在收敛：不能立即回收（可能仍在写同一 staging，
                // 违反 C-01）。若已是终态则请求 abort 加速收敛；本次创建拒绝，调用方
                // 稍后重试即可回收成功（不再需要冷启动）。
                if (terminal) stale_owners_to_abort.push_back(owner_it->second);
                conflict_path = path;
                conflict_reason = "final path is already owned by task " +
                                  std::to_string(owner_id);
                break;
            }
        }

        // Keep rejected tasks queryable so NAPI create/register/start can settle and roll
        // the transaction back instead of returning an id that has no terminal snapshot.
        tasks_[task->taskId()] = task;
        if (conflict_reason.empty()) {
            for (const auto& path : unique_paths) path_owners_[path] = task->taskId();
        }
    }

    for (auto& stale : stale_owners_to_abort) {
        if (stale) stale->abort();
    }

    if (!conflict_reason.empty()) {
        const std::string detail = conflict_path.empty()
            ? conflict_reason : conflict_reason + ": " + conflict_path;
        task->reject(makeException(ErrorKind::InvalidConfig, detail));
    }
    return task;
}

bool DownloadEngine::startTask(uint64_t task_id) {
    reapCompletedStartupThreads_();

    LoaderDownloadPtr task;
    TaskOperationGuard operation;
    // 在检查 Waiting、取 SH 和 onStart 回调之前预占；不能等回调返回后才登记
    // startup，否则 cancel/create/purge 可在空线程表窗口内放走旧路径所有权。
    if (!beginTaskOperation_(task_id, task, operation, true)) return false;

    // onStart 会触发用户回调，不能持 lifecycle_mu_，否则回调反入 Engine 会死锁。
    if (task->state() != LoadState::Waiting) return false;
    auto file_lease = amcl::AcquireConfiguredUpdateReadLease();
    if (!file_lease) {
        task->reject(makeException(ErrorKind::InvalidConfig, "application installation fence blocks file tasks"));
        return false;
    }
    { std::lock_guard<std::mutex> lock(task_mu_); update_read_leases_[task_id] = std::move(file_lease); }
    task->onStart();
    // onStart可能同步完成空任务或被回调取消，仍要唤醒ticker释放安装读租约。
    // 此处不持task/lifecycle锁；等待方在ticker_mu_下检查谓词，握手防止丢通知。
    wakeTicker_();
    if (task->state() != LoadState::Loading) return true; // 空任务或并发取消已同步终态。
    const uint64_t epoch = task->selectionEpoch();

    AMCL_LOG_I(LOG_TAG, "startTask: scheduling managed startup (%{public}zu files, epoch=%{public}lu)",
                task->files().size(), (unsigned long)epoch);

    std::string schedule_error;
    {
        // 与 shutdown 的“拒绝新任务”发布原子化：只要成功登记到 startup_threads_，
        // shutdown 就一定能看到并 join；否则在锁内拒绝，不留下 detached 工作。
        std::lock_guard<std::mutex> lifecycle_lk(lifecycle_mu_);
        if (lifecycle_state_ != LifecycleState::Running ||
            !running_.load(std::memory_order_acquire)) {
            schedule_error = "download engine stopped during task startup";
        } else {
            std::lock_guard<std::mutex> startup_lk(startup_mu_);
            bool active_registered = false;
            try {
                startup_threads_.reserve(startup_threads_.size() + 1);
                auto completed = std::make_shared<std::atomic<bool>>(false);
                ++active_startups_[task_id];
                active_registered = true;
                std::thread thread([this, task, epoch, completed]() mutable {
                    try {
                        startupBody_(task, epoch);
                    } catch (const std::exception& ex) {
                        task->reject(makeException(ErrorKind::InternalError,
                            "download startup failed: " + std::string(ex.what())));
                    } catch (...) {
                        task->reject(makeException(ErrorKind::InternalError,
                            "download startup failed with unknown exception"));
                    }
                    finishStartup_(task->taskId(), completed);
                });
                startup_threads_.push_back({std::move(thread), std::move(completed)});
            } catch (const std::exception& ex) {
                if (active_registered) {
                    auto it = active_startups_.find(task_id);
                    if (it != active_startups_.end()) {
                        if (it->second <= 1) active_startups_.erase(it);
                        else --it->second;
                    }
                }
                schedule_error = "failed to create startup thread: " + std::string(ex.what());
            }
        }
    }

    if (!schedule_error.empty()) {
        task->reject(makeException(ErrorKind::InternalError, schedule_error));
        return false;
    }
    return true;
}

void DownloadEngine::startupBody_(LoaderDownloadPtr task, uint64_t epoch) {
    DownloadExecutionContext execution_context;
    // 活动账本：startup 是每个任务独立的受管理线程，整段只服务这一个任务，
    // 所以在函数最开头设一次就够（不像共享 worker 池要按活儿设）。
    //
    // 必须加：本函数里的 per-file preCheckExistingFile 会为每个文件写一行 DL_FILE
    // （5000+ 资源就是 5000+ 行），2026-08-01 真机实测发现这些行全部丢了归属 ——
    // 账本里只有 ArkTS 的阶段行，看不到「哪些文件跳过、哪些要重下」。
    // 必须在第一条 AMCL_LOG_I 之前。
    AmclActivityScope actScope(amclLedgerActivityOfTask(task ? task->taskId() : 0));

    AMCL_LOG_I(LOG_TAG,
        "startupBody_: %{public}zu files, epoch=%{public}lu (warm=%{public}d interval=%{public}dms)",
        task->files().size(), (unsigned long)epoch,
        cfg_.cold_start_warm_threshold, cfg_.cold_start_interval_ms);

    constexpr int64_t kSmallFileThreshold = 1024 * 1024;
    int multi_count = 0, worker_count = 0;

    const auto cancelled = [&]() {
        return task->isAbortRequested() ||
               !running_.load(std::memory_order_acquire) ||
               task->state() != LoadState::Loading;
    };
    const auto settle_unstarted_from = [&](size_t first) {
        for (size_t j = first; j < task->files().size(); ++j) {
            auto& remaining = task->files()[j];
            if (!task->shouldStartFile(remaining.get())) continue;
            NetState state = remaining->state();
            if (state == NetState::Finished || state == NetState::Failed ||
                state == NetState::Aborted) {
                task->reportFileFinished(remaining.get());
            } else {
                remaining->abort();
                auto pending = remaining->threadsToLaunch();
                if (!pending.empty()) settleThreadsAborted(std::move(pending));
                else task->reportFileAbortedBeforeStart(remaining.get());
            }
        }
    };

    for (size_t i = 0; i < task->files().size(); ++i) {
        auto& f = task->files()[i];

        // 旧 epoch 绝不参与新一轮 retry；当前 epoch 的未选文件已在任务层计为既有终态。
        if (task->selectionEpoch() != epoch) return;
        if (!task->shouldStartFile(f.get())) continue;
        if (cancelled()) {
            settle_unstarted_from(i);
            break;
        }

        auto ex = f->start();

        // NetFile::start 可能执行 HEAD/SHA1；返回后必须再次观察取消，避免把取消期间
        // 创建的 thread 送入下载器。
        if (task->selectionEpoch() != epoch) return;
        if (cancelled()) {
            f->abort();
            auto pending = f->threadsToLaunch();
            if (!pending.empty()) settleThreadsAborted(std::move(pending));
            else if (f->state() == NetState::Finished || f->state() == NetState::Failed ||
                     f->state() == NetState::Aborted) {
                task->reportFileFinished(f.get());
            } else {
                task->reportFileAbortedBeforeStart(f.get());
            }
            settle_unstarted_from(i + 1);
            break;
        }

        if (ex) {
            AMCL_LOG_W(LOG_TAG, "NetFile::start failed: %{public}s: %{public}s",
                        f->localPath().c_str(), ex->toString().c_str());
            task->reportFileFinished(f.get());
            continue;
        }
        if (f->state() == NetState::Finished) {
            task->reportFileFinished(f.get());
            continue;
        }

        auto threads = f->threadsToLaunch();
        if (threads.empty()) {
            // 空线程只可能由明确终态收敛；Downloading + empty 是状态机破坏，绝不能算成功。
            AMCL_LOG_E(LOG_TAG, "startup invariant failed: no threads state=%{public}d file=%{public}s",
                         (int)f->state(), f->localPath().c_str());
            task->reject(makeException(ErrorKind::InternalError,
                "download startup produced no threads: " + f->localPath()));
            break;
        }

        int64_t fsize = f->fileSize();
        bool use_multi = (fsize > 0 && fsize < kSmallFileThreshold &&
                          threads.size() == 1 && !f->isHighParallel());
        if (use_multi) {
            multi_count += static_cast<int>(threads.size());
            enqueueMulti(std::move(threads));
        } else {
            worker_count += static_cast<int>(threads.size());
            enqueueThreadsForTask(task->taskId(), std::move(threads));
        }
    }

    AMCL_LOG_I(LOG_TAG, "startupBody_ routed: multi=%{public}d worker=%{public}d",
                multi_count, worker_count);
}

bool DownloadEngine::cancelTask(uint64_t task_id) {
    LoaderDownloadPtr task;
    {
        std::lock_guard<std::mutex> lk(task_mu_);
        auto it = tasks_.find(task_id);
        if (it == tasks_.end()) return false;
        task = it->second;
    }
    task->abort();
    // abort 先发布各段取消令牌，再唤醒可能只剩长冷却 pending 的 multi 事件循环。
    // 沿用 enqueueMulti 的 lifecycle -> multi 锁顺序；ShuttingDown 已负责唤醒回收，
    // 不能在该阶段读取随后会被 shutdown 释放的 unique_ptr。
    {
        std::lock_guard<std::mutex> lifecycle_lk(lifecycle_mu_);
        if (lifecycle_state_ == LifecycleState::Running && multi_downloader_) {
            multi_downloader_->notifyCancellation();
        }
    }
    return true;
}

bool DownloadEngine::resumeTask(uint64_t task_id) {
    LoaderDownloadPtr task;
    {
        TaskOperationGuard operation;
        // 活跃 startup/transport/callback 时返回未就绪，不能在回调重入时等待自己。
        if (!beginTaskOperation_(task_id, task, operation, true)) return false;
        if (!task->resetToWaiting()) return false;
        for (auto& f : task->files()) {
            if (f->state() != NetState::Finished && !f->resetForRetry()) return false;
        }
    }
    // Waiting 不是可回收终态；归还复位预占后，startTask 原子取得自己的启动预占。
    return startTask(task_id);
}

int64_t DownloadEngine::deleteTaskFiles(uint64_t task_id) {
    LoaderDownloadPtr task;
    TaskOperationGuard operation;
    // 清理不以“UI 已取消”替代收敛；预占保持到全部 unlink/close 结束，期间 create
    // 不能自动回收同路径，resume/retry 也不能开始新一轮写入。
    if (!beginTaskOperation_(task_id, task, operation, true)) return 0;
    return task->deleteFilesOnDisk();
}

bool DownloadEngine::retryFailedFiles(uint64_t task_id,
                                      const std::vector<std::string>& local_paths) {
    LoaderDownloadPtr task;
    {
        TaskOperationGuard operation;
        if (!beginTaskOperation_(task_id, task, operation, true)) return false;
        if (!task->retryFailedFiles(local_paths)) return false;
    }
    return startTask(task_id);
}

bool DownloadEngine::purgeTask(uint64_t task_id) {
    std::lock_guard<std::mutex> lk(task_mu_);
    return reclaimTaskLocked_(task_id);
}

LoaderDownloadPtr DownloadEngine::getTask(uint64_t task_id) const {
    std::lock_guard<std::mutex> lk(task_mu_);
    auto it = tasks_.find(task_id);
    return (it != tasks_.end()) ? it->second : nullptr;
}

std::vector<LoaderDownloadPtr> DownloadEngine::listTasks() const {
    std::lock_guard<std::mutex> lk(task_mu_);
    std::vector<LoaderDownloadPtr> out;
    out.reserve(tasks_.size());
    for (const auto& kv : tasks_) out.push_back(kv.second);
    return out;
}

bool DownloadEngine::isTaskExecutionSettled(uint64_t task_id) {
    std::lock_guard<std::mutex> task_lk(task_mu_);
    auto it = tasks_.find(task_id);
    // 回收后的 ID 没有 Native 执行 owner；不能为查询临时占操作，否则将永远读成 false。
    return it == tasks_.end() || taskExecutionSettledLocked_(it->second);
}

void DownloadEngine::trackThreadsForProgress_(const std::vector<NetThreadPtr>& threads) {
    if (threads.empty()) return;
    std::unordered_map<uint64_t, std::pair<LoaderDownloadPtr, std::vector<NetThreadPtr>>> owned;
    {
        std::lock_guard<std::mutex> lk(task_mu_);
        for (const auto& thread : threads) {
            if (!thread || !thread->task()) continue;
            const auto* file = thread->task();
            auto task = tasks_.find(file->taskId());
            if (task == tasks_.end() || !file->ownedBy(task->second.get())) continue;
            auto& group = owned[task->first];
            group.first = task->second;
            group.second.push_back(thread);
        }
    }
    // 真实 file taskId 修复后可直接查 owner，构造时的指针身份再校验一次。原实现每个
    // asset 入队都会重建“所有任务的全部文件”集合，数千文件会变成二次扫描/分配成本。
    // 此处只处理实际入队段，锁外进入 Loader 的进度锁，不扩大 Engine 的临界区。
    for (auto& entry : owned) entry.second.first->trackThreadsForProgress(entry.second.second);
}

void DownloadEngine::settleThreadsAborted(std::vector<NetThreadPtr> threads, bool scheduling_failure) noexcept {
    for (auto& t : threads) {
        if (!t) continue;
        // 在 mark 移走 segment keepalive 之前持住文件；未入队段没有其他执行器替它
        // 发完成通知，不能只丢掉 vector 让 file<->segment 引用环永久悬挂。
        NetFilePtr file;
        LoaderDownloadPtr owner;
        try {
            file = t->task() ? t->task()->weak_from_this().lock() : nullptr;
            if (file) {
                owner = instance().getTask(file->taskId());
                if (owner && !file->ownedBy(owner.get())) owner.reset();
            }
            if (owner) {
                if (scheduling_failure) owner->failSchedulingWithoutAllocation();
                else owner->abort();
            } else if (file) file->abort();
        } catch (...) { AMCL_LOG_E(LOG_TAG, "unqueued owner notification unavailable; retaining terminal/query state"); }
        t->abort();
        t->setState(NetState::Aborted);
        try { t->markExecutionSettled(); }
        catch (...) { AMCL_LOG_E(LOG_TAG, "unqueued segment completion interrupted after transport settlement"); }
    }
}

void DownloadEngine::enqueueThreadsForTask(uint64_t task_id,
                                           std::vector<NetThreadPtr> threads) noexcept {
    if (threads.empty()) return;
    // 进度登记只是观察，不是执行所有权。弱引用/身份容器分配失败时仍允许传输调度；
    // 已登记子集保持有效，不得因为观察失败把真实执行引用直接丢掉。
    try { trackThreadsForProgress_(threads); }
    catch (...) { AMCL_LOG_W(LOG_TAG, "progress registration skipped after allocation failure"); }
    bool rejected = false;
    bool scheduling_failure = false;
    try {
        std::lock_guard<std::mutex> lifecycle_lk(lifecycle_mu_);
        if (lifecycle_state_ != LifecycleState::Running ||
            !running_.load(std::memory_order_acquire)) {
            rejected = true;
        } else {
            std::lock_guard<std::mutex> queue_lk(queue_mu_);
            auto inserted = pending_threads_by_task_.try_emplace(task_id);
            auto& queue = inserted.first->second;
            const size_t previous_size = queue.size();
            try {
                // 保留输入强引用到事务完整提交；不能 move 后才发现后面的 deque/order
                // 分配失败。worker 仍被同一 queue 锁挡住，回滚尾部不会接触已运行段。
                for (const auto& thread : threads) queue.push_back(thread);
                if (previous_size == 0) pending_task_order_.push_back(task_id);
            } catch (...) {
                while (queue.size() > previous_size) queue.pop_back();
                if (inserted.second && queue.empty()) pending_threads_by_task_.erase(inserted.first);
                throw;
            }
        }
    } catch (...) {
        rejected = true;
        scheduling_failure = true;
    }
    if (rejected) {
        AMCL_LOG_W(LOG_TAG, "worker enqueue rejected: threads=%{public}zu scheduling_failure=%{public}d",
                    threads.size(), scheduling_failure ? 1 : 0);
        settleThreadsAborted(std::move(threads), scheduling_failure);
        return;
    }
    queue_cv_.notify_all();
}

void DownloadEngine::enqueueThreads(std::vector<NetThreadPtr> threads) noexcept {
    // retry/grow 与 startup 使用同一真实任务身份。兼容调用可混入多个文件，因此
    // 先按所属 NetFile 的批次 ID 分组；只有无归属测试/兼容对象才进入队列 0。
    std::unordered_map<uint64_t, std::vector<NetThreadPtr>> groups;
    try {
        for (const auto& thread : threads) {
            const uint64_t id = thread && thread->task() ? thread->task()->taskId() : 0;
            groups[id].push_back(thread);
        }
    } catch (...) {
        // 分组尚未向任一队列发布，完整输入仍在；锁外逐段归还 owner/执行引用。
        settleThreadsAborted(std::move(threads), true);
        return;
    }
    for (auto& group : groups) enqueueThreadsForTask(group.first, std::move(group.second));
}

void DownloadEngine::enqueueMulti(std::vector<NetThreadPtr> threads) noexcept {
    if (threads.empty()) return;
    try { trackThreadsForProgress_(threads); }
    catch (...) { AMCL_LOG_W(LOG_TAG, "multi progress registration skipped after allocation failure"); }
    bool rejected = false;
    bool scheduling_failure = false;
    try {
        std::lock_guard<std::mutex> lifecycle_lk(lifecycle_mu_);
        if (lifecycle_state_ != LifecycleState::Running ||
            !running_.load(std::memory_order_acquire)) {
            rejected = true;
        } else if (multi_downloader_) {
            if (multi_downloader_->enqueue(threads)) return;
            rejected = true;
            scheduling_failure = true;
        }
    } catch (...) { rejected = true; scheduling_failure = true; }
    if (rejected) {
        AMCL_LOG_W(LOG_TAG, "multi enqueue rejected: threads=%{public}zu scheduling_failure=%{public}d",
                    threads.size(), scheduling_failure ? 1 : 0);
        settleThreadsAborted(std::move(threads), scheduling_failure);
        return;
    }
    enqueueThreadsForTask(0, std::move(threads));
}

// 单调微秒时间戳（用于 cold-start gate 的时间间隔判断，免受系统时钟回拨影响）
static inline int64_t nowMonotonicUs() {
    using namespace std::chrono;
    return duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count();
}

void DownloadEngine::workerLoop() {
    DownloadExecutionContext execution_context;
    // v4.5b: 每个 worker 线程持有一个长期存活的 CURL* easy handle。
    // curl_easy_reset() 重置选项但保留内部连接缓存（TCP + TLS session），
    // 同 host 的后续请求复用 TCP 连接，减少 TLS 握手次数。
    CURL* easy = curl_easy_init();

    while (true) {
        NetThreadPtr t;
        {
            std::unique_lock<std::mutex> lk(queue_mu_);
            queue_cv_.wait(lk, [this] {
                return !running_.load(std::memory_order_acquire) ||
                       !pending_task_order_.empty();
            });
            if (!running_.load(std::memory_order_acquire) && pending_task_order_.empty()) {
                break;
            }

            uint64_t task_id = pending_task_order_.front();
            auto it = pending_threads_by_task_.find(task_id);
            if (it == pending_threads_by_task_.end() || it->second.empty()) {
                pending_task_order_.pop_front();
                continue;
            }
            t = std::move(it->second.front());
            it->second.pop_front();
            if (it->second.empty()) {
                pending_threads_by_task_.erase(it);
                pending_task_order_.pop_front();
            } else {
                // round-robin 只轮转整数槽，不 pop 后重新 push（deque 末端扩容可抛出，
                // 丢掉仍有 pending 段的 task ID）。任务数通常很少，无分配轮转保持公平。
                std::rotate(pending_task_order_.begin(), pending_task_order_.begin() + 1,
                            pending_task_order_.end());
            }
        }

        // === v4.3 冷启动 ramp-up gate（对齐 v2 slidingDownload） ===
        if (t && !warmed_up_.load(std::memory_order_relaxed)
                && active_threads_.load(std::memory_order_relaxed)
                    < cfg_.cold_start_warm_threshold) {
            std::unique_lock<std::mutex> glk(launch_gate_mu_);
            if (!warmed_up_.load(std::memory_order_relaxed)
                    && active_threads_.load(std::memory_order_relaxed)
                        < cfg_.cold_start_warm_threshold) {
                int64_t now_us   = nowMonotonicUs();
                int64_t last_us  = last_launch_us_.load(std::memory_order_relaxed);
                int64_t need_us  = static_cast<int64_t>(cfg_.cold_start_interval_ms) * 1000;
                int64_t elapsed  = now_us - last_us;
                if (last_us != 0 && elapsed < need_us) {
                    glk.unlock();
                    std::this_thread::sleep_for(
                        std::chrono::microseconds(need_us - elapsed));
                    glk.lock();
                }
                last_launch_us_.store(nowMonotonicUs(), std::memory_order_relaxed);
            }
        }

        if (t) {
            int prev = active_threads_.fetch_add(1, std::memory_order_acq_rel);
            if (!warmed_up_.load(std::memory_order_relaxed)
                    && (prev + 1) >= cfg_.cold_start_warm_threshold) {
                warmed_up_.store(true, std::memory_order_release);
            }
            // 活动账本（L2-b）：worker 池是**共享**的，同一线程会先后处理不同任务的活儿，
            // 所以归属必须在「取到活儿时设、做完清」，不能在线程启动时设一次。
            // 这样这段 run() 期间该线程写的所有日志（含 DL_MULTI）都归到正确的活动。
            AmclActivityScope actScope(
                amclLedgerActivityOfTask(t->task() ? t->task()->taskId() : 0));
            try {
                t->run(easy);  // v4.5: 传入复用的 easy handle
            } catch (const std::exception& ex) {
                t->setError(makeException(ErrorKind::InternalError,
                    "worker execution threw: " + std::string(ex.what())));
                t->setState(NetState::Failed);
            } catch (...) {
                t->setError(makeException(ErrorKind::InternalError,
                    "worker execution threw unknown exception"));
                t->setState(NetState::Failed);
            }
            // run 已完成所有 task_/curl callback 访问；此后才能释放 NetFile keepalive
            // 并把本段计入文件 completion barrier。
            t->markExecutionSettled();
            active_threads_.fetch_sub(1, std::memory_order_acq_rel);
        }
    }

    if (easy) curl_easy_cleanup(easy);
}

void DownloadEngine::flushAllMeta() {
    std::vector<LoaderDownloadPtr> snapshot;
    {
        std::lock_guard<std::mutex> lk(task_mu_);
        snapshot.reserve(tasks_.size());
        for (const auto& kv : tasks_) snapshot.push_back(kv.second);
    }

    for (auto task : snapshot) {
        TaskOperationGuard operation;
        if (!beginTaskOperation_(task->taskId(), task, operation, false)) continue;
        if (task->state() != LoadState::Loading) continue;
        bool attempted = false;
        bool all_success = true;
        std::string first_failed_meta;
        for (auto& f : task->files()) {
            NetState fs = f->state();
            if (fs != NetState::Downloading && fs != NetState::Connecting &&
                fs != NetState::Reading) continue;

            // v4.2: 小文件（< 1MB）跳过 meta flush——重下成本远低于写 meta 的 IO 成本。
            // 消除 3000+ assets 下载时每 2s 几百次无意义的磁盘写操作。
            int64_t fsize = f->fileSize();
            if (fsize > 0 && fsize < 1024 * 1024) continue;

            auto snap = f->snapshotForMeta();
            if (!snap.execution_active) continue;
            bool has_progress = false;
            for (const auto& seg : snap.segments) {
                if (seg.done > 0) { has_progress = true; break; }
            }
            // 尚未创建 staging 的纯 Connecting 文件不写空恢复点，也不把 ENOENT
            // 误判为持久化故障。
            if (!has_progress) continue;

            attempted = true;
            std::string meta_path = f->localPath() + ".download-meta";
            DownloadMeta m;
            m.url_primary = f->sources().empty() ? "" : f->sources().front()->url;
            for (const auto& s : f->sources()) m.url_sources.push_back(s->url);
            m.file_size = snap.file_size;
            m.created_at = currentIso8601Utc();
            m.segments.reserve(snap.segments.size());
            for (const auto& seg : snap.segments) {
                SegmentMeta s;
                s.start = seg.start;
                s.end   = seg.end;
                s.done  = seg.done;
                m.segments.push_back(s);
            }
            m.check = f->checker();

            errno = 0;
            // NetFile 将 data fsync、可信 parent 上的 metaAt 写入与 commit/discard 串行；
            // storage generation 不符时跳过旧快照，绝不为新 part 声明上一轮 done。
            if (!f->persistResumeMeta(m, snap.storage_generation)) {
                // ⚠️ 2026-07-29：区分「meta 布局非法」与「真实存储故障」。
                //   writeMetaFile 在 validateMeta 失败时置 errno=EINVAL —— 那是**我们自己
                //   生成的段布局**不满足"严格连续升序覆盖 [0,file_size)"，属于引擎内部
                //   瞬时状态（如自适应切段并发进行中被采样到中间态），**不是磁盘写不进去**。
                //   meta 只是断点续传的优化，写不了最多丢失续传能力，绝不该据此把一个
                //   正在正常传输的任务判死。
                //   真机教训：切段爆炸期 3 次采样到非法布局 → StorageIoError → 94.5% 处
                //   整任务失败（用户侧表现为"卡在 86% 等很久然后失败"）。
                //   现在 EINVAL 只记警告并跳过本轮，不计入连续失败计数；ENOSPC/EIO 等
                //   真实存储错误仍照旧累计并在连败 3 次后判 StorageIoError。
                if (errno == EINVAL) {
                    AMCL_LOG_W(LOG_TAG,
                        "meta layout transiently invalid, skipping this flush (not a storage fault): %{public}s",
                        meta_path.c_str());
                } else {
                    all_success = false;
                    if (first_failed_meta.empty()) first_failed_meta = std::move(meta_path);
                }
            }
        }
        // A task contributes at most one success/failure sample per flush epoch. Otherwise
        // a later successful file could reset the counter after another file failed.
        if (attempted) task->reportMetaPersistenceResult(all_success, first_failed_meta);
    }
}

void DownloadEngine::tickAllProgress() {
    std::vector<LoaderDownloadPtr> snapshot;
    {
        std::lock_guard<std::mutex> lk(task_mu_);
        snapshot.reserve(tasks_.size());
        for (const auto& kv : tasks_) snapshot.push_back(kv.second);
    }
    for (auto task : snapshot) {
        {
            TaskOperationGuard operation;
            if (!beginTaskOperation_(task->taskId(), task, operation, false)) continue;
            if (task->state() == LoadState::Loading) task->tickProgress();
        }
        const auto state = task->state();
        if (state == LoadState::Finished || state == LoadState::Failed || state == LoadState::Aborted) {
            std::lock_guard<std::mutex> task_lock(task_mu_);
            if (taskExecutionSettledLocked_(task)) update_read_leases_.erase(task->taskId());
        }
    }
}

// v7.4：自适应分段调度。和 progress tick 同频（200ms）跑：对每个正在下载的大文件，
// 只要活跃段少于目标并发（target_connections_）就切最慢段补连接（详见 NetFile::maybeGrowThreads，
// 已从「慢于地板才补」改为目标并发驱动）。对快速下载（原版小资源）零影响——maybeGrowThreads
// 内的大小/无 checker/目标已满等护栏会直接跳过。
void DownloadEngine::growAllThreads() {
    std::vector<LoaderDownloadPtr> snapshot;
    {
        std::lock_guard<std::mutex> lk(task_mu_);
        snapshot.reserve(tasks_.size());
        for (const auto& kv : tasks_) snapshot.push_back(kv.second);
    }
    for (auto task : snapshot) {
        TaskOperationGuard operation;
        if (!beginTaskOperation_(task->taskId(), task, operation, false)) continue;
        if (task->state() != LoadState::Loading) continue;
        for (const auto& f : task->files()) {
            f->maybeGrowThreads();
        }
    }
}

bool DownloadEngine::hasTickerWork_() {
    std::lock_guard<std::mutex> lk(task_mu_);
    // tickAllProgress还负责等待真实执行收敛后释放安装读租约；仅看Loading会漏掉收尾。
    if (!update_read_leases_.empty()) return true;
    for (const auto& task : tasks_) {
        if (task.second->state() == LoadState::Loading) return true;
    }
    return false;
}

void DownloadEngine::wakeTicker_() {
    // 状态写入在前，锁握手在后。等待方不持ticker_mu_执行回调、IO或thread join。
    { std::lock_guard<std::mutex> lk(ticker_mu_); }
    ticker_cv_.notify_all();
}

void DownloadEngine::tickerLoop() {
    DownloadExecutionContext execution_context;
    auto last_meta = std::chrono::steady_clock::now();
    while (running_.load(std::memory_order_acquire)) {
        {
            std::unique_lock<std::mutex> lk(ticker_mu_);
            // 无业务且无租约时不设置超时。startTask以及退出必须通过wakeTicker_握手；
            // 新任务恢复后仍保持原进度周期，不能把网络/磁盘回调挪到调用者线程。
            ticker_cv_.wait(lk, [this] {
                return !running_.load(std::memory_order_acquire) || hasTickerWork_();
            });
            if (!running_.load(std::memory_order_acquire)) break;
            ticker_cv_.wait_for(lk, std::chrono::milliseconds(cfg_.progress_tick_interval_ms),
                [this] { return !running_.load(std::memory_order_acquire); });
        }
        if (!running_.load(std::memory_order_acquire)) break;

        tickAllProgress();
        growAllThreads();   // v4.10：慢速大文件自适应追加并行段

        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - last_meta).count()
                >= cfg_.meta_flush_interval_ms) {
            flushAllMeta();
            last_meta = now;
        }
    }
}

// v4.3: curl share lock/unlock 回调
void DownloadEngine::curlShareLock(CURL* /*handle*/, curl_lock_data data,
                                    curl_lock_access /*access*/, void* userptr) {
    auto* engine = static_cast<DownloadEngine*>(userptr);
    if (data == CURL_LOCK_DATA_DNS) {
        engine->share_dns_mu_.lock();
    } else if (data == CURL_LOCK_DATA_SSL_SESSION) {
        engine->share_ssl_mu_.lock();
    }
}

void DownloadEngine::curlShareUnlock(CURL* /*handle*/, curl_lock_data data, void* userptr) {
    auto* engine = static_cast<DownloadEngine*>(userptr);
    if (data == CURL_LOCK_DATA_DNS) {
        engine->share_dns_mu_.unlock();
    } else if (data == CURL_LOCK_DATA_SSL_SESSION) {
        engine->share_ssl_mu_.unlock();
    }
}

void DownloadEngine::addBadHost(const std::string& host) {
    if (host.empty()) return;

    // v6 修复：保护"第一方内容 CDN"——它们是模组/资源/JDK 的最终来源，
    // 弱网下的单次超时/连接失败不能把它们永久拉黑（否则之后所有下载 302 到这些
    // CDN 都被"skip bad host"拒绝 → "no available sources"，全部失败）。
    static const char* kProtectedHostSubstr[] = {
        "modrinth.com", "mcimirror.top", "forgecdn.net", "curseforge.com",
        "minecraftforge.net", "fabricmc.net", "maven.neoforged.net",
        // 2026-07-29：源主机自身也纳入熔断后（见 net_thread.cpp 的 addBadHost 调用），
        // 必须豁免这些"唯一真源"，否则弱网下几次超时就会把它们封掉，导致
        // 「GitHub 源站」模式无源可用、Mojang 原版下载与 Gitee 分卷也会被自断。
        "github.com", "githubusercontent.com", "gitee.com",
        "piston-data.mojang.com", "piston-meta.mojang.com",
        "libraries.minecraft.net", "resources.download.minecraft.net",
        "bmclapi2.bangbang93.com",
    };
    // ⚠️ 2026-07-29 修正：受保护主机**不再无条件豁免**。
    //   无条件豁免会让"设备直连不通"的源站变成永久时间黑洞：github.com 每次
    //   connect 白等 6s、失败 49 次仍被反复重选，尾段因此长期卡住。
    //   改为"更宽容而非免疫"：受保护主机的熔断阈值放宽到 12 次（普通主机 3 次），
    //   足以吸收弱网抖动，又能在真的长时间不可达时让位给其它候选源；TTL 仍受
    //   下面的 45s 上限约束，恢复后能立刻重新参与。
    bool protected_host = false;
    for (const char* p : kProtectedHostSubstr) {
        if (host.find(p) != std::string::npos) { protected_host = true; break; }
    }

    // 连续失败达到阈值后按失败次数指数增加 TTL；半开探针失败会立即重新打开。
    //
    // ⚠️ 2026-07-29：TTL 上限从 5min 收到 45s。原因：NetThread 的重试预算
    //   kRetryLifetimeMs 也是 5min，而 pickBestSource 现在会在"全部源冷却/熔断"时
    //   如实返回 nullptr、由调用方等待到 nextSourceReadyMs。若某主机熔断 300s 且它是
    //   最后一个候选，`ready > deadline` 会让该段直接判死（"source cooldown exceeds
    //   retry deadline"）。45s 足以让死镜像歇够、又保证总能在重试预算内恢复候选资格。
    const int kBanThreshold = protected_host ? 12 : 3;
    constexpr int64_t kBaseTtlMs = 15 * 1000;
    constexpr int64_t kMaxTtlMs = 45 * 1000;
    const int64_t now_ms = nowMonotonicUs() / 1000;

    std::lock_guard<std::mutex> lk(bad_hosts_mu_);
    ++host_failure_generations_[host];
    int n = ++host_fail_counts_[host];
    if (n < kBanThreshold) {
        AMCL_LOG_W(LOG_TAG, "addBadHost: %{public}s fail %{public}d/%{public}d",
                    host.c_str(), n, kBanThreshold);
        return;
    }

    int shift = std::min(3, n - kBanThreshold);
    int64_t ttl_ms = std::min(kMaxTtlMs, kBaseTtlMs << shift);
    // 并发的较短失败不能缩短已经发布的开路时间；探针租约由真实请求归还。
    int64_t& open_until = bad_host_until_ms_[host];
    open_until = std::max(open_until, now_ms + ttl_ms);
    AMCL_LOG_W(LOG_TAG,
        "addBadHost: %{public}s circuit open %{public}lldms after %{public}d failures",
        host.c_str(), (long long)ttl_ms, n);
}

void DownloadEngine::markHostHealthyLocked_(const std::string& host, uint64_t receipt) {
    auto admitted = host_admission_receipts_.find(receipt);
    const auto generation = host_failure_generations_.find(host);
    if (admitted == host_admission_receipts_.end() || admitted->second.host != host ||
        generation == host_failure_generations_.end() ||
        admitted->second.failure_generation != generation->second || admitted->second.healthy_reported) return;
    admitted->second.healthy_reported = true;
    // 健康只关闭本次收据获取时的故障代次。早先在途A的迟到正文/EOF，不能关闭
    // 后来故障产生的开路或探针B；名额仍由原收据在执行退出时归还。
    host_fail_counts_.erase(host);
    bad_host_until_ms_.erase(host);
    auto probe = bad_host_probe_tokens_.find(host);
    if (probe != bad_host_probe_tokens_.end() && probe->second == receipt)
        bad_host_probe_tokens_.erase(probe);
}

void DownloadEngine::markHostHealthy(const std::string& host, uint64_t receipt) {
    if (host.empty() || receipt == 0) return;
    std::lock_guard<std::mutex> lk(bad_hosts_mu_);
    markHostHealthyLocked_(host, receipt);
}

// ----------------------------------------------------------------------------
// worker 池路径的每主机并发闸门（2026-07-29，防 HTTP 429）
//
// 背景：MultiDownloader（小文件）早有 host_limit_ 自适应收缩，但大文件分段下载走
// enqueueThreads 工作线程池，此前对同一主机的并发**毫无限制** —— JDK 的 16 段全压
// 同一个 GitHub 代理，必然被限流（真机单次下载 570~887 条 429）。429 又只设 cooldown、
// 不减并发，于是冷却一过 16 段再次同时冲上去，循环限流 → 速度剧烈抖动、尾段几乎不动。
// 这里给 worker 路径补上同款「自适应每主机并发」：初始 4，429 减半（下限 1），
// 连续 8 次成功回升 1（上限 8）。
// ----------------------------------------------------------------------------
namespace {
// ⚠️ 2026-08-04：原来是 initial=4 / max=8，与 MultiDownloader 那两个值一起把 assets
//   的有效并发钉死在 8（4750 个 asset 全在 bmclapi2 一个主机上）。
//
//   PCL2 **没有** per-host 并发上限：ModNet.vb:1820-1842 的 ThreadStarter 只检查全局
//   `NetTaskThreadCount >= NetTaskThreadLimit`（= ToolDownloadThread 63 + 1 = 64）。
//   它控制的是**请求频率**：启动一条 bmclapi 线程后 `Thread.Sleep(100)`，两个
//   ThreadStarter 交错 ⇒ 有效 ~50ms/条。
//
//   所以稳态上限改为 = worker 池规模（等价"无 per-host 上限"），节流改用下面的
//   kThrottledHostStartIntervalMs。429 触发的减半收缩保留 —— 那是 PCL2 没有的额外保险，
//   下限 1，能在真被限流时自动退让。
constexpr int kWorkerHostInitialLimit = 64;
constexpr int kWorkerHostMaxLimit     = 64;
constexpr int kWorkerHostRecoverOk    = 8;

/** 对齐 PCL2 的 bmclapi Sleep(100) × 双 ThreadStarter 交错 ⇒ 有效 ~50ms/条。 */
constexpr int64_t kThrottledHostStartIntervalMs = 50;

/** PCL2 判据：`Url.Contains("bmclapi")`（ModNet.vb:1822/1842）。host 判断等价。 */
bool isThrottledHostName(const std::string& host) {
    return host.find("bmclapi") != std::string::npos;
}
}  // namespace

bool DownloadEngine::tryAcquireHostSlot(const std::string& host, uint64_t* receipt) {
    if (!receipt) return false;
    *receipt = 0;
    if (host.empty()) return false;
    std::lock_guard<std::mutex> lk(bad_hosts_mu_);
    const int64_t now = nowMonotonicUs() / 1000;
    auto rate = host_ratelimit_until_ms_.find(host);
    if (rate != host_ratelimit_until_ms_.end() && now < rate->second) return false;
    auto open = bad_host_until_ms_.find(host);
    if (open != bad_host_until_ms_.end() && now < open->second) return false;
    if (bad_host_probe_tokens_.count(host) != 0) return false;
    int& limit = worker_host_limit_[host];
    if (limit <= 0) limit = kWorkerHostInitialLimit;
    int& active = worker_host_active_[host];
    if (active >= limit) return false;
    worker_host_ok_streak_.try_emplace(host, 0);
    if (isThrottledHostName(host)) {
        auto slot = worker_host_next_start_ms_.find(host);
        if (slot != worker_host_next_start_ms_.end() && now < slot->second) return false;
        worker_host_next_start_ms_[host] = now + kThrottledHostStartIntervalMs;
    }
    const uint64_t generation = host_failure_generations_[host];
    uint64_t id = next_host_admission_receipt_++;
    while (id == 0 || host_admission_receipts_.count(id) != 0) id = next_host_admission_receipt_++;
    host_admission_receipts_.emplace(id, HostAdmissionRecord{host, generation, false});
    try {
        if (open != bad_host_until_ms_.end()) bad_host_probe_tokens_.emplace(host, id);
    } catch (...) {
        // 记录分配失败时尚未增加active，撤销已创建收据再交还异常，不遗留幽灵占位。
        host_admission_receipts_.erase(id); throw;
    }
    ++active;
    *receipt = id;
    return true;
}

void DownloadEngine::releaseHostSlot(const std::string& host, bool healthy, uint64_t receipt) {
    if (host.empty() || receipt == 0) return;
    std::lock_guard<std::mutex> lk(bad_hosts_mu_);
    auto admitted = host_admission_receipts_.find(receipt);
    // 所有准入都有收据。跨host、重复归还、旧收据不能再减active或奖励成功曲线。
    if (admitted == host_admission_receipts_.end() || admitted->second.host != host) return;
    const auto generation = host_failure_generations_.find(host);
    const bool current = generation != host_failure_generations_.end() &&
                         admitted->second.failure_generation == generation->second;
    if (healthy && current) markHostHealthyLocked_(host, receipt);
    auto probe = bad_host_probe_tokens_.find(host);
    if (probe != bad_host_probe_tokens_.end() && probe->second == receipt)
        bad_host_probe_tokens_.erase(probe);
    host_admission_receipts_.erase(admitted);
    auto active = worker_host_active_.find(host);
    if (active != worker_host_active_.end() && active->second > 0) --active->second;
    if (!current) return;
    auto streak_it = worker_host_ok_streak_.find(host);
    if (!healthy) { if (streak_it != worker_host_ok_streak_.end()) streak_it->second = 0; return; }
    auto rl = host_ratelimit_streak_.find(host);
    if (rl != host_ratelimit_streak_.end() && rl->second > 0) --rl->second;
    if (streak_it == worker_host_ok_streak_.end()) return;
    int& streak = streak_it->second;
    if (++streak < kWorkerHostRecoverOk) return;
    streak = 0;
    auto limit_it = worker_host_limit_.find(host);
    if (limit_it != worker_host_limit_.end() && limit_it->second < kWorkerHostMaxLimit) ++limit_it->second;
}

void DownloadEngine::penalizeHost(const std::string& host) {
    if (host.empty()) return;
    std::lock_guard<std::mutex> lk(bad_hosts_mu_);
    int& limit = worker_host_limit_[host];
    if (limit <= 0) limit = kWorkerHostInitialLimit;
    int old = limit;
    limit = std::max(1, limit / 2);
    worker_host_ok_streak_[host] = 0;
    if (limit != old) {
        AMCL_LOG_W(LOG_TAG, "hostSlot: %{public}s got 429, limit %{public}d -> %{public}d",
                    host.c_str(), old, limit);
    }
}

int64_t DownloadEngine::noteHostRateLimit(const std::string& host, int64_t retry_after_ms) {
    if (host.empty()) return 0;
    // 主机级指数退避：同一主机连续 429 时间隔按 2^n 拉长（1s → 2 → 4 → 8 → 16 → 32，上限 45s）。
    // 服务端给了 Retry-After 就尊重它（取两者较大值），并叠加 jitter 防惊群。
    constexpr int64_t kBaseMs = 1000;
    constexpr int64_t kCapMs  = 45 * 1000;
    std::lock_guard<std::mutex> lk(bad_hosts_mu_);
    const int64_t now_ms = nowMonotonicUs() / 1000;
    ++host_failure_generations_[host];
    int& streak = host_ratelimit_streak_[host];
    if (streak < 6) ++streak;
    int64_t backoff = std::min(kCapMs, kBaseMs << (streak - 1));
    if (retry_after_ms > backoff) backoff = retry_after_ms;
    // jitter：0~400ms，避免同主机的多段在同一毫秒齐发。
    backoff = transportDeadlineAfter(backoff,
        (static_cast<int64_t>(host.size()) * 37 + streak * 91) % 400);
    int64_t until = transportDeadlineAfter(now_ms, backoff);
    int64_t& slot = host_ratelimit_until_ms_[host];
    if (until > slot) slot = until;
    AMCL_LOG_W(LOG_TAG,
        "hostRateLimit: %{public}s 429 streak=%{public}d backoff=%{public}lldms",
        host.c_str(), streak, (long long)backoff);
    return slot;
}

int64_t DownloadEngine::hostRateLimitUntilMs(const std::string& host) const {
    if (host.empty()) return 0;
    std::lock_guard<std::mutex> lk(bad_hosts_mu_);
    auto it = host_ratelimit_until_ms_.find(host);
    return it == host_ratelimit_until_ms_.end() ? 0 : it->second;
}

int64_t DownloadEngine::badHostReadyAtMs(const std::string& host) const {
    if (host.empty()) return 0;
    std::lock_guard<std::mutex> lk(bad_hosts_mu_);
    int64_t ready = 0;
    auto it = bad_host_until_ms_.find(host);
    if (it != bad_host_until_ms_.end()) ready = std::max(ready, it->second);
    // 探针到期但真实执行尚未退出时，不允许新探针，也不给等待方返回已经过去的
    // 时刻使其误判为无源/热循环。短暂重查只存在真实在途探针期间，完全空闲仍事件等待。
    if (bad_host_probe_tokens_.count(host) != 0)
        ready = std::max(ready, nowMonotonicUs() / 1000 + 100);
    return ready;
}

bool DownloadEngine::isBadHost(const std::string& host) const {
    if (host.empty()) return false;
    const int64_t now_ms = nowMonotonicUs() / 1000;
    std::lock_guard<std::mutex> lk(bad_hosts_mu_);
    // 只读候选事实。TTL 到期允许候选进入实际准入竞争，但不在这里占探针，
    // 也不把“未收到失败/租约到期”冒充已恢复；真实结算来自对应请求。
    if (bad_host_probe_tokens_.count(host) != 0) return true;
    auto open = bad_host_until_ms_.find(host);
    return open != bad_host_until_ms_.end() && now_ms < open->second;
}

// ============================================================
//  每主机 IP 地址族选择 —— PCL2 DNSLookup 等价物
//  移植自 PCL2 Modules/Base/ModNet.vb:314-358 / :368-375
//  设计与实测依据见 engine.h 中 ipResolveFor 上方的注释块。
// ============================================================

long DownloadEngine::pickFamilyLocked(const HostFamilyScore& s, int64_t now_ms) {
    const bool v4_blocked = s.v4_unresolvable_until_ms > now_ms;
    const bool v6_blocked = s.v6_unresolvable_until_ms > now_ms;
    // 某一族当前解析不出 → 只能用另一族；两族都不行则交回系统解析器。
    if (v4_blocked && v6_blocked) return CURL_IPRESOLVE_WHATEVER;
    if (v4_blocked) return CURL_IPRESOLVE_V6;
    if (v6_blocked) return CURL_IPRESOLVE_V4;
    // 安全阀（PCL2 没有，属于我们的加强）：两族都已被打成明显负分时，说明"挑哪一族"
    // 这个前提已经不成立（多半是主机自身故障或整条链路抖动）。此时强锁任一族只会
    // 让 libcurl 少一半机会，交回系统解析器让它按 Happy Eyeballs 并行试两族更稳。
    // 阈值 -0.3：单次失败即 0 → -0.35，故"两族各失败过至少一次"就会命中。
    constexpr double kBothFamiliesBadScore = -0.3;
    if (s.v4 <= kBothFamiliesBadScore && s.v6 <= kBothFamiliesBadScore) {
        return CURL_IPRESOLVE_WHATEVER;
    }
    // 对齐 PCL2 ModNet.vb:348 `If IPv4Reliability >= IPv6Reliability Then IPv4Targets`
    // —— 平手（含两族都是初始 0）时走 IPv4 分支。
    return (s.v4 >= s.v6) ? CURL_IPRESOLVE_V4 : CURL_IPRESOLVE_V6;
}

long DownloadEngine::familyFromIp(const std::string& ip) {
    if (ip.empty()) return CURL_IPRESOLVE_WHATEVER;
    // IPv6 字面量必然含 ':'（含 v4-mapped 的 ::ffff:1.2.3.4，那条链路走的也是 v6 socket）；
    // IPv4 点分十进制不含 ':'。
    return (ip.find(':') != std::string::npos) ? CURL_IPRESOLVE_V6 : CURL_IPRESOLVE_V4;
}

long DownloadEngine::ipResolveFor(const std::string& host) const {
    if (host.empty()) return CURL_IPRESOLVE_WHATEVER;
    const int64_t now_ms = nowMonotonicUs() / 1000;
    std::lock_guard<std::mutex> lk(host_family_mu_);
    auto it = host_family_.find(host);
    // 首次遇到这台主机：不猜，交给系统解析器（见 engine.h 上方注释里的实测理由）。
    if (it == host_family_.end()) return CURL_IPRESOLVE_WHATEVER;
    const HostFamilyScore& s = it->second;
    // 两族都还没有任何证据（例如上一次是 WHATEVER 且拿不到 PRIMARY_IP）→ 仍不猜。
    if (!s.v4_tried && !s.v6_tried &&
        s.v4_unresolvable_until_ms <= now_ms && s.v6_unresolvable_until_ms <= now_ms) {
        return CURL_IPRESOLVE_WHATEVER;
    }
    return pickFamilyLocked(s, now_ms);
}

void DownloadEngine::noteFamilyOutcome(const std::string& host, long ipresolve,
                                       const std::string& primary_ip,
                                       bool ok, bool unresolvable) {
    if (host.empty()) return;
    // 本次到底走了哪一族：显式锁定过就用它，否则靠实际连接的 IP 反推。
    long family = (ipresolve == CURL_IPRESOLVE_V4 || ipresolve == CURL_IPRESOLVE_V6)
        ? ipresolve : familyFromIp(primary_ip);
    if (family != CURL_IPRESOLVE_V4 && family != CURL_IPRESOLVE_V6) return;
    const bool is_v4 = (family == CURL_IPRESOLVE_V4);
    // PCL2 RecordIPReliability (ModNet.vb:368-375)：成功 +0.5，失败 -0.7，
    // 更新式 `v = v*0.5 + result*0.5`。
    const double result = ok ? 0.5 : -0.7;

    // PCL2 DNSFailureRecord 的 TTL（ModNet.vb:322 `New TimeSpan(0, 1, 0)`）。
    constexpr int64_t kUnresolvableTtlMs = 60 * 1000;
    const int64_t now_ms = nowMonotonicUs() / 1000;

    double before = 0.0;
    double after = 0.0;
    long pick_before = 0;
    long pick_after = 0;
    {
        std::lock_guard<std::mutex> lk(host_family_mu_);
        HostFamilyScore& s = host_family_[host];
        pick_before = pickFamilyLocked(s, now_ms);

        double& score = is_v4 ? s.v4 : s.v6;
        before = score;
        if (is_v4) {
            s.v4_tried = true;
            s.v4_unresolvable_until_ms = unresolvable ? now_ms + kUnresolvableTtlMs : 0;
        } else {
            s.v6_tried = true;
            s.v6_unresolvable_until_ms = unresolvable ? now_ms + kUnresolvableTtlMs : 0;
        }
        score = score * 0.5 + result * 0.5;
        after = score;
        pick_after = pickFamilyLocked(s, now_ms);
    }
    if (pick_before != pick_after) {
        const auto famName = [](long r) {
            return r == CURL_IPRESOLVE_V4 ? "IPv4" : (r == CURL_IPRESOLVE_V6 ? "IPv6" : "auto");
        };
        AMCL_LOG_I(LOG_TAG,
            "family switch: host=%{public}s tried=%{public}s ok=%{public}d "
            "score=%{public}.3f->%{public}.3f unresolvable=%{public}d pick %{public}s->%{public}s",
            host.c_str(), is_v4 ? "IPv4" : "IPv6", ok ? 1 : 0,
            before, after, unresolvable ? 1 : 0,
            famName(pick_before), famName(pick_after));
    }
}

bool DownloadEngine::hasUntriedFamily(const std::string& host, long tried_ipresolve) const {
    if (host.empty()) return false;
    if (tried_ipresolve != CURL_IPRESOLVE_V4 && tried_ipresolve != CURL_IPRESOLVE_V6) return false;
    const int64_t now_ms = nowMonotonicUs() / 1000;
    std::lock_guard<std::mutex> lk(host_family_mu_);
    auto it = host_family_.find(host);
    if (it == host_family_.end()) return true;
    const HostFamilyScore& s = it->second;
    if (tried_ipresolve == CURL_IPRESOLVE_V4) {
        return !s.v6_tried && s.v6_unresolvable_until_ms <= now_ms;
    }
    return !s.v4_tried && s.v4_unresolvable_until_ms <= now_ms;
}

// ============================================================
//  Phase 3 (S2-2)：fetchToBuffer — 元数据走 NAPI 引擎
// ============================================================

namespace {

constexpr size_t kFetchBodyLimit = 8U * 1024U * 1024U;

/**
 * 一次metadata候选的真实正文进展。候选链共用steady截止时间；有下一候选时才开启
 * 短无进展窗口，单源的大manifest仍保留调用者完整预算。重定向错误页不算有效正文。
 */
struct FetchProgressContext {
    const std::atomic<bool>* cancelled = nullptr;
    int64_t last_body_progress_ms = 0;
    int64_t idle_limit_ms = 0;
    bool idle_expired = false;
};

struct FetchWriteContext {
    std::string* body = nullptr;
    size_t max_bytes = kFetchBodyLimit;
    bool too_large = false;
    const long* response_status = nullptr;
    FetchProgressContext* progress = nullptr;
};

/** 响应头与状态属于当前metadata hop；不借用上一次响应或另一请求的可变状态。 */
struct FetchHeaderContext {
    std::map<std::string, std::string>* headers = nullptr;
    long status = 0;
};

/** curl WRITEFUNCTION 回调：限制解压后的响应正文，避免异常 manifest 耗尽内存。 */
size_t fetchWriteCallback(char* ptr, size_t size, size_t nmemb, void* userdata) {
    auto* ctx = static_cast<FetchWriteContext*>(userdata);
    if (!ctx || !ctx->body) return 0;
    if (size != 0 && nmemb > std::numeric_limits<size_t>::max() / size) {
        ctx->too_large = true;
        return 0;
    }
    const size_t total = size * nmemb;
    // 手动follow与curl原自动follow一样丢弃3xx正文；它不属于元数据，也不能挤占
    // 最终响应的解压后正文额度。错误页仍受正常max_bytes限制。
    if (ctx->response_status && *ctx->response_status >= 300 && *ctx->response_status < 400)
        return total;
    if (ctx->body->size() > ctx->max_bytes || total > ctx->max_bytes - ctx->body->size()) {
        ctx->too_large = true;
        return 0; // CURLE_WRITE_ERROR；调用方转换为明确的 ResponseTooLarge。
    }
    try {
        ctx->body->append(ptr, total);
        // 错误页仍受限长约束，但404/429/503滴流不是可交付metadata的有效进展，
        // 不能靠持续喂错误页占满总预算并阻止健康后继；Retry-After仍在完成处入账。
        if (total > 0 && ctx->progress && ctx->response_status &&
            *ctx->response_status >= 200 && *ctx->response_status < 300)
            ctx->progress->last_body_progress_ms = nowMonotonicUs() / 1000;
    } catch (const std::bad_alloc&) {
        return 0;
    }
    return total;
}

/**
 * Phase 2.3：curl HEADERFUNCTION 回调。每次一行（含尾部 CRLF）：
 *   - "HTTP/1.1 200 OK\r\n"           — status line（跳过）
 *   - "Header-Name: value\r\n"        — 解析为 (lowercase_name, value)
 *   - "\r\n"                          — headers 结束（保留默认行为）
 * 返回 size*nitems = 不出错；返回其它值会触发 CURLE_WRITE_ERROR。
 */
size_t fetchHeaderCallback(char* buffer, size_t size, size_t nitems, void* userdata) {
    auto* ctx = static_cast<FetchHeaderContext*>(userdata);
    auto* hdrs = ctx ? ctx->headers : nullptr;
    if (size != 0 && nitems > std::numeric_limits<size_t>::max() / size) return 0;
    size_t total = size * nitems;
    if (total == 0 || !hdrs) return total;
    // libcurl 在 follow redirect 期间可能多次调本回调（每次跳转都来一遍 headers）。
    // 每次新 status line 都先 clear，让最终响应头胜出。
    if (total >= 5 && std::strncmp(buffer, "HTTP/", 5) == 0) {
        hdrs->clear();
        const std::string status_line(buffer, total);
        const auto space = status_line.find(' ');
        ctx->status = space == std::string::npos ? 0 : std::strtol(status_line.c_str() + space + 1, nullptr, 10);
        return total;
    }
    // 找冒号
    size_t colon = 0;
    bool found = false;
    for (size_t i = 0; i < total; ++i) {
        if (buffer[i] == ':') { colon = i; found = true; break; }
    }
    if (!found) return total;  // 不是 "Name: value" 格式（比如 "\r\n" 行尾）
    // 截取 name + 转小写
    std::string name(buffer, colon);
    for (auto& c : name) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    // 截取 value，跳过冒号后的空白和尾部 CRLF
    size_t vstart = colon + 1;
    while (vstart < total && (buffer[vstart] == ' ' || buffer[vstart] == '\t')) vstart++;
    size_t vend = total;
    while (vend > vstart && (buffer[vend - 1] == '\r' || buffer[vend - 1] == '\n'
                             || buffer[vend - 1] == ' ' || buffer[vend - 1] == '\t')) vend--;
    if (vend <= vstart) {
        (*hdrs)[name] = std::string();
    } else {
        (*hdrs)[name] = std::string(buffer + vstart, vend - vstart);
    }
    return total;
}

/** 把 CURLcode 翻译成 errKind 字符串（与 net_thread.cpp 保持风格一致） */
const char* curlcodeToKind(CURLcode rc, long http_code) {
    if (rc == CURLE_OK) {
        if (http_code >= 200 && http_code < 300) return "Ok";
        if (http_code == 304) return "Ok";  // 条件请求命中 — 不算错误
        return "HttpStatus";
    }
    switch (rc) {
        case CURLE_COULDNT_RESOLVE_HOST: return "DnsFail";
        case CURLE_COULDNT_CONNECT:      return "ConnectFail";
        case CURLE_OPERATION_TIMEDOUT:   return "Timeout";
        case CURLE_SSL_CONNECT_ERROR:
        case CURLE_PEER_FAILED_VERIFICATION:
        case CURLE_SSL_CACERT_BADFILE:
        case CURLE_SSL_CIPHER:
        case CURLE_SSL_CERTPROBLEM:      return "SslFail";
        case CURLE_HTTP_RETURNED_ERROR:  return "HttpStatus";
        case CURLE_WRITE_ERROR:          return "PerformFail";
        case CURLE_RECV_ERROR:           return "PerformFail";
        case CURLE_SEND_ERROR:           return "PerformFail";
        // 2026-08-04：curl_easy_perform 返回 BAD_FUNCTION_ARGUMENT 时，选项其实都是对的。
        // libcurl 的 easy_transfer() 把内部 multi 的任何非 OOM 错误统一映射成这个码，
        // 实际含义几乎总是 CURLM_UNRECOVERABLE_POLL —— 随包 libcurl 未启用 poll，
        // Curl_poll 走 select 分支，fd >= FD_SETSIZE(1024) 就直接 EINVAL。
        // 单独分一个 kind，避免再被当成"未知网络错误"排查。
        case CURLE_BAD_FUNCTION_ARGUMENT: return "FdLimitExceeded";
        default:                         return "Unknown";
    }
}

/** 探测"下一个可用 fd 号" = 进程 fd 水位；失败返回 -1。 */
int probeNextFreeFdForDiag() {
    int fd = ::open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ::close(fd);
    return fd;
}

/**
 * 把 CURLcode 翻成人类可读消息。对 CURLE_BAD_FUNCTION_ARGUMENT 附上 fd 水位，
 * 因为 libcurl 自带的 "A libcurl function was given a bad argument" 完全指错了方向
 * （2026-08-04 就是被这句话误导了很久）。
 */
std::string curlErrorMessage(CURLcode rc) {
    if (rc != CURLE_BAD_FUNCTION_ARGUMENT) return std::string(curl_easy_strerror(rc));
    return "libcurl select/poll failed (fd >= FD_SETSIZE): next_free_fd=" +
           std::to_string(probeNextFreeFdForDiag()) +
           " — process fd watermark crossed 1024 and the bundled libcurl has no poll();"
           " every transfer and metadata fetch stays broken until restart";
}

/** metadata承接Engine shutdown及候选正文无进展窗口；没有另造JS/env取消通道。 */
int fetchProgressCallback(void* userdata, curl_off_t, curl_off_t, curl_off_t, curl_off_t) {
    auto* progress = static_cast<FetchProgressContext*>(userdata);
    if (!progress) return 0;
    if (progress->cancelled && progress->cancelled->load(std::memory_order_acquire)) return 1;
    if (progress->idle_limit_ms > 0 &&
        nowMonotonicUs() / 1000 - progress->last_body_progress_ms >= progress->idle_limit_ms) {
        progress->idle_expired = true;
        return 1;
    }
    return 0;
}

/** 规范化origin用于敏感头隔离，端口也属于凭据边界。 */
std::string fetchOrigin(const std::string& url) {
    CURLU* parsed = curl_url();
    if (!parsed) return {};
    std::string result;
    if (curl_url_set(parsed, CURLUPART_URL, url.c_str(), 0) == CURLUE_OK) {
        char *scheme = nullptr, *host = nullptr, *port = nullptr;
        if (curl_url_get(parsed, CURLUPART_SCHEME, &scheme, 0) == CURLUE_OK &&
            curl_url_get(parsed, CURLUPART_HOST, &host, 0) == CURLUE_OK &&
            curl_url_get(parsed, CURLUPART_PORT, &port, CURLU_DEFAULT_PORT) == CURLUE_OK) {
            result = std::string(scheme) + "://" + host + ":" + port;
            for (char& c : result) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        }
        curl_free(scheme); curl_free(host); curl_free(port);
    }
    curl_url_cleanup(parsed);
    return result;
}

/**
 * 共用metadata GET执行。所有候选沿用同一steady截止时间，最多5跳重定向；
 * 每hop最多补一次尚未试过的地址族，实际HTTP均取得Engine名额和server not-before。
 * body与headers只来自最终响应；304、解压后大小上限、CA和条件请求语义保持。
 */
int fetchOnceEx(const std::string& url, int64_t deadline, int64_t idle_limit_ms,
                const std::map<std::string, std::string>& request_headers,
                size_t max_response_bytes, FetchResponse& out,
                const std::atomic<bool>* cancelled) {
    out.body.clear(); out.headers.clear(); out.status_code = 0;
    out.err_kind.clear(); out.err_msg.clear();
    std::unique_ptr<CURL, decltype(&curl_easy_cleanup)> easy(curl_easy_init(), curl_easy_cleanup);
    if (!easy) { out.err_kind = "Unknown"; out.err_msg = "curl_easy_init returned null"; return -1; }
    FetchProgressContext progress{cancelled, nowMonotonicUs() / 1000, idle_limit_ms, false};
    const std::string original_origin = fetchOrigin(url);
    std::string actual_url = url;
    int redirects = 0;
    bool family_retry_consumed = false;
    while (true) {
        if (cancelled && cancelled->load(std::memory_order_acquire)) {
            out.err_kind = "Aborted"; out.err_msg = "download engine shutdown before metadata HTTP"; return -1;
        }
        if (!isTransportHttpUrl(actual_url)) {
            out.err_kind = "HttpStatus"; out.err_msg = "metadata URL protocol must be HTTP(S)"; return -1;
        }
        const std::string host = familyHostFromUrl(actual_url);
        auto& engine = DownloadEngine::instance();
        HostAdmissionLease admission;
        while (!admission.tryAcquire(host)) {
            if (cancelled && cancelled->load(std::memory_order_acquire)) {
                out.err_kind = "Aborted"; out.err_msg = "download engine shutdown before metadata HTTP"; return -1;
            }
            const int64_t now = nowMonotonicUs() / 1000;
            const int64_t ready = std::max(engine.badHostReadyAtMs(host), engine.hostRateLimitUntilMs(host));
            // 下一候选可用时不占着本次metadata在已知冷却主机前排队，也不绕过冷却发HTTP。
            if (idle_limit_ms > 0 && ready > now) {
                out.err_kind = "RetryAfter"; out.err_msg = "metadata candidate host is cooling down"; return -1;
            }
            // 名额/半开探针被占也没有正文进展。有后继时，候选的空闲窗必须覆盖
            // 准入排队，不能等整条deadline后才让一个本来健康的镜像获得尝试机会。
            if (idle_limit_ms > 0 && now - progress.last_body_progress_ms >= idle_limit_ms) {
                out.err_kind = "Timeout"; out.err_msg = "metadata candidate host remained busy before fallback budget"; return -1;
            }
            if (now >= deadline || ready > deadline) {
                out.err_kind = ready > deadline ? "RetryAfter" : "Timeout";
                out.err_msg = "metadata host admission exceeds request deadline"; return -1;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(25));
        }
        const int64_t remaining = deadline - nowMonotonicUs() / 1000;
        if (remaining <= 0) { out.err_kind = "Timeout"; out.err_msg = "metadata request deadline exhausted"; return -1; }
        curl_easy_reset(easy.get());
        out.body.clear(); out.headers.clear(); out.status_code = 0;
        curl_easy_setopt(easy.get(), CURLOPT_URL, actual_url.c_str());
        curl_easy_setopt(easy.get(), CURLOPT_FOLLOWLOCATION, 0L);
        curl_easy_setopt(easy.get(), CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(easy.get(), CURLOPT_CONNECTTIMEOUT_MS, static_cast<long>(std::min<int64_t>(remaining, 15000)));
        curl_easy_setopt(easy.get(), CURLOPT_TIMEOUT_MS, static_cast<long>(remaining));
        // 保持Ex可观察304/4xx的能力；普通入口在wrapper中继续拒绝304。
        curl_easy_setopt(easy.get(), CURLOPT_FAILONERROR, 0L);
        curl_easy_setopt(easy.get(), CURLOPT_USERAGENT, "amcl/0.1 (OHOS; libcurl/8.10.1)");
        curl_easy_setopt(easy.get(), CURLOPT_ACCEPT_ENCODING, "");
        const long family = engine.ipResolveFor(host);
        curl_easy_setopt(easy.get(), CURLOPT_IPRESOLVE, family);
        curl_easy_setopt(easy.get(), CURLOPT_SSL_VERIFYPEER, 1L);
        curl_easy_setopt(easy.get(), CURLOPT_SSL_VERIFYHOST, 2L);
        const std::string ca_path = getCaBundlePath();
        if (!ca_path.empty()) curl_easy_setopt(easy.get(), CURLOPT_CAINFO, ca_path.c_str());
        // metadata允许在Engine.start之前执行。保持它原来的独立easy连接缓存，
        // 不在此借用可能同时创建/销毁的Engine CURLSH裸指针。
        FetchHeaderContext header_ctx{&out.headers, 0};
        FetchWriteContext write_ctx{&out.body, max_response_bytes, false, &header_ctx.status, &progress};
        curl_easy_setopt(easy.get(), CURLOPT_WRITEFUNCTION, fetchWriteCallback);
        curl_easy_setopt(easy.get(), CURLOPT_WRITEDATA, &write_ctx);
        curl_easy_setopt(easy.get(), CURLOPT_HEADERFUNCTION, fetchHeaderCallback);
        curl_easy_setopt(easy.get(), CURLOPT_HEADERDATA, &header_ctx);
        curl_easy_setopt(easy.get(), CURLOPT_NOPROGRESS, 0L);
        curl_easy_setopt(easy.get(), CURLOPT_XFERINFOFUNCTION, fetchProgressCallback);
        curl_easy_setopt(easy.get(), CURLOPT_XFERINFODATA, &progress);
        std::unique_ptr<curl_slist, decltype(&curl_slist_free_all)> headers(nullptr, curl_slist_free_all);
        const bool same_origin = !original_origin.empty() && fetchOrigin(actual_url) == original_origin;
        for (const auto& kv : request_headers) {
            if (kv.first.empty()) continue;
            std::string name = kv.first;
            for (char& c : name) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            // curl自动follow原本会隔离跨origin凭据；改为手动hop后必须明确保留该边界。
            if (!same_origin && (name == "authorization" || name == "proxy-authorization" ||
                name == "cookie" || name == "host")) continue;
            const std::string line = kv.first + ": " + kv.second;
            curl_slist* appended = curl_slist_append(headers.get(), line.c_str());
            if (!appended) { out.err_kind = "Unknown"; out.err_msg = "metadata header allocation failed"; return -1; }
            headers.release(); headers.reset(appended);
        }
        if (headers) curl_easy_setopt(easy.get(), CURLOPT_HTTPHEADER, headers.get());
        const CURLcode rc = curl_easy_perform(easy.get());
        long http = 0; curl_easy_getinfo(easy.get(), CURLINFO_RESPONSE_CODE, &http);
        out.status_code = static_cast<int>(http);
        char* raw_ip = nullptr; curl_easy_getinfo(easy.get(), CURLINFO_PRIMARY_IP, &raw_ip);
        const std::string ip = raw_ip ? raw_ip : "";
        const bool reachable = http > 0;
        const bool connection_failure = isFamilyConnectFailure(rc, http, static_cast<int64_t>(out.body.size()));
        if (reachable || connection_failure)
            engine.noteFamilyOutcome(host, family, ip, reachable, rc == CURLE_COULDNT_RESOLVE_HOST);
        const long used = family == CURL_IPRESOLVE_WHATEVER ? DownloadEngine::familyFromIp(ip) : family;
        const bool try_family = connection_failure && !family_retry_consumed && engine.hasUntriedFamily(host, used);
        // HTTP响应本身证明metadata主机可连通；超响应上限/取消不是网络质量失败。
        admission.finish(reachable && !write_ctx.too_large && rc != CURLE_ABORTED_BY_CALLBACK);
        if (!reachable && connection_failure && !try_family) engine.addBadHost(host);
        if (http == 408 || http == 429 || http == 503) {
            const auto retry = out.headers.find("retry-after");
            engine.noteHostRateLimit(host, retry == out.headers.end() ? 0 : parseTransportRetryAfter(retry->second));
            if (http == 429) engine.penalizeHost(host);
        }
        if (write_ctx.too_large) {
            out.body.clear(); out.err_kind = "ResponseTooLarge";
            out.err_msg = "response body exceeded " + std::to_string(max_response_bytes) + " byte limit"; return -1;
        }
        if (rc == CURLE_ABORTED_BY_CALLBACK && cancelled && cancelled->load(std::memory_order_acquire)) {
            out.err_kind = "Aborted"; out.err_msg = "download engine shutdown during metadata HTTP"; return -1;
        }
        if (progress.idle_expired) {
            out.err_kind = "Timeout"; out.err_msg = "metadata candidate made no body progress before fallback budget";
            AMCL_LOG_D(LOG_TAG, "metadata idle fallback: host=%{public}s idle_limit_ms=%{public}lld",
                       host.c_str(), (long long)idle_limit_ms);
            return -1;
        }
        if (try_family) { family_retry_consumed = true; continue; }
        if (rc == CURLE_OK && (http == 301 || http == 302 || http == 307 || http == 308)) {
            char* raw_redirect = nullptr; curl_easy_getinfo(easy.get(), CURLINFO_REDIRECT_URL, &raw_redirect);
            const std::string next = raw_redirect ? raw_redirect : "";
            if (redirects++ < 5 && isTransportHttpUrl(next)) {
                actual_url = next; family_retry_consumed = false; continue;
            }
        }
        if (rc == CURLE_OK && ((http >= 200 && http < 300) || http == 304)) return 0;
        out.err_kind = curlcodeToKind(rc, http);
        out.err_msg = rc == CURLE_OK ? "HTTP " + std::to_string(http) : curlErrorMessage(rc);
        if (rc != CURLE_OK && http > 0) out.err_msg += " (http=" + std::to_string(http) + ")";
        return -1;
    }
}

/**
 * 两个公开metadata入口共用候选选择和总预算。过滤空/重复候选，避免别名重复耗时；
 * 有后继候选时无正文进展最多等5秒，并按剩余候选数量预留回退机会。持续有效正文
 * 不会被固定5秒总时长截断，仍受整条请求deadline约束；最后/唯一候选使用剩余预算。
 */
int fetchCandidates(const std::string& primary, const std::vector<std::string>& mirrors,
                    int timeout_seconds, const std::map<std::string, std::string>& headers,
                    size_t max_bytes, bool accept_not_modified, FetchResponse& out,
                    const std::atomic<bool>* cancelled) {
    const int seconds = timeout_seconds <= 0 ? 30 : std::min(timeout_seconds, 300);
    const int64_t deadline = transportDeadlineAfter(nowMonotonicUs() / 1000, static_cast<int64_t>(seconds) * 1000);
    std::vector<std::string> urls;
    const auto append = [&urls](const std::string& url) {
        if (!url.empty() && std::find(urls.begin(), urls.end(), url) == urls.end()) urls.push_back(url);
    };
    append(primary);
    for (const auto& mirror : mirrors) append(mirror);
    out = FetchResponse{};
    if (urls.empty()) { out.err_kind = "Unknown"; out.err_msg = "no URLs provided"; return -1; }
    for (size_t index = 0; index < urls.size(); ++index) {
        if (cancelled && cancelled->load(std::memory_order_acquire)) {
            out.err_kind = "Aborted"; out.err_msg = "download engine shutdown"; return -1;
        }
        const int64_t remaining = deadline - nowMonotonicUs() / 1000;
        if (remaining <= 0) {
            out.err_kind = "Timeout"; out.err_msg = "metadata candidate chain deadline exhausted"; return -1;
        }
        const bool has_fallback = index + 1 < urls.size();
        const int64_t idle = has_fallback ? std::min<int64_t>(5000,
            std::max<int64_t>(1, remaining / static_cast<int64_t>(urls.size() - index))) : 0;
        const int64_t started = nowMonotonicUs() / 1000;
        const int result = fetchOnceEx(urls[index], deadline, idle, headers, max_bytes, out, cancelled);
        if (result == 0 && (accept_not_modified || out.status_code != 304)) {
            AMCL_LOG_D(LOG_TAG, "metadata candidate ok: index=%{public}zu count=%{public}zu host=%{public}s status=%{public}d elapsed_ms=%{public}lld bytes=%{public}zu",
                       index, urls.size(), familyHostFromUrl(urls[index]).c_str(), out.status_code,
                       (long long)(nowMonotonicUs() / 1000 - started), out.body.size());
            return 0;
        }
        if (result == 0) { out.err_kind = "HttpStatus"; out.err_msg = "HTTP 304"; }
        AMCL_LOG_D(LOG_TAG, "metadata candidate failed: index=%{public}zu count=%{public}zu host=%{public}s elapsed_ms=%{public}lld kind=%{public}s msg=%{public}s",
                   index, urls.size(), familyHostFromUrl(urls[index]).c_str(),
                   (long long)(nowMonotonicUs() / 1000 - started), out.err_kind.c_str(), out.err_msg.c_str());
    }
    return -1;
}

}  // anonymous namespace

int DownloadEngine::fetchToBuffer(const std::string& primary_url,
                                   const std::vector<std::string>& mirrors,
                                   int timeout_seconds,
                                   std::string& out_body,
                                   std::string& out_err_kind,
                                   std::string& out_err_msg) {
    if (!acquireCurlUse(&out_err_kind, &out_err_msg)) return -1;
    // 立即建立不分配内存的作用域归还。reserve/string/map/执行中的异常同样必须
    // 撤销active_curl_users，不能让随后shutdown永久等待一个已退出的调用。
    const auto release_use = [this](DownloadEngine*) noexcept { releaseCurlUse(); };
    std::unique_ptr<DownloadEngine, decltype(release_use)> curl_use(this, release_use);

    FetchResponse response;
    const int result = fetchCandidates(primary_url, mirrors, timeout_seconds, {}, kFetchBodyLimit, false,
                                       response, &shutdown_requested_);
    out_body = std::move(response.body);
    out_err_kind = std::move(response.err_kind); out_err_msg = std::move(response.err_msg);
    return result;
}

int DownloadEngine::fetchToBufferEx(const std::string& primary_url,
                                     const std::vector<std::string>& mirrors,
                                     int timeout_seconds,
                                     const std::map<std::string, std::string>& request_headers,
                                     size_t max_response_bytes,
                                     FetchResponse& out_resp) {
    if (!acquireCurlUse(&out_resp.err_kind, &out_resp.err_msg)) return -1;
    const auto release_use = [this](DownloadEngine*) noexcept { releaseCurlUse(); };
    std::unique_ptr<DownloadEngine, decltype(release_use)> curl_use(this, release_use);

    constexpr size_t kMaxConfigurableFetchBody = 16U * 1024U * 1024U;
    if (max_response_bytes == 0) max_response_bytes = 1;
    if (max_response_bytes > kMaxConfigurableFetchBody) {
        max_response_bytes = kMaxConfigurableFetchBody;
    }

    return fetchCandidates(primary_url, mirrors, timeout_seconds, request_headers, max_response_bytes, true,
                           out_resp, &shutdown_requested_);
}

} // namespace download
