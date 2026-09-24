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

#include <curl/curl.h>
#include <fcntl.h>     // 2026-08-04：probeNextFreeFdForDiag 用 ::open 探 fd 水位
#include <hilog/log.h>
#include <unistd.h>    // 同上：::close

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstring>
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
std::string familyHostFromUrl(const std::string& url) {
    size_t s = url.find("://");
    if (s == std::string::npos) return {};
    s += 3;
    size_t e = url.find('/', s);
    size_t p = url.find(':', s);
    if (p != std::string::npos && (e == std::string::npos || p < e)) e = p;
    if (e == std::string::npos) return url.substr(s);
    return url.substr(s, e - s);
}

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
    startup_cv_.notify_all();
}

void DownloadEngine::waitForStartupIdle_(uint64_t task_id) {
    std::unique_lock<std::mutex> lk(startup_mu_);
    startup_cv_.wait(lk, [this, task_id] {
        auto it = active_startups_.find(task_id);
        return it == active_startups_.end() || it->second == 0;
    });
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
        ticker_cv_.notify_all();
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
    startup_cv_.notify_all();

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

    ticker_cv_.notify_all();
    if (ticker_.joinable()) ticker_.join();

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
        std::lock_guard<std::mutex> lifecycle_lk(lifecycle_mu_);
        if (lifecycle_state_ != LifecycleState::Running) {
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
                if (terminal && owner_it->second->isExecutionSettled()) {
                    // 回收：占用该路径的旧任务已彻底结束（典型：上次下载失败后被保留）。
                    // 释放其全部路径所有权并从表移除，把该文件交给本次新任务重下——
                    // 无需 ArkTS 手动 purge，也不再需要冷启动。C-01 保护不受影响：
                    // 仅回收 terminal + execution-settled（可证明已停止写入）的旧任务。
                    for (const auto& f : owner_it->second->files()) {
                        auto o = path_owners_.find(f->localPath());
                        if (o != path_owners_.end() && o->second == owner_id) path_owners_.erase(o);
                    }
                    tasks_.erase(owner_it);
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
    {
        std::lock_guard<std::mutex> lifecycle_lk(lifecycle_mu_);
        if (lifecycle_state_ != LifecycleState::Running ||
            !running_.load(std::memory_order_acquire)) return false;
        std::lock_guard<std::mutex> task_lk(task_mu_);
        auto it = tasks_.find(task_id);
        if (it == tasks_.end()) return false;
        task = it->second;
    }

    // onStart 会触发用户回调，不能持 lifecycle_mu_，否则回调反入 Engine 会死锁。
    if (task->state() != LoadState::Waiting) return false;
    task->onStart();
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
                    startup_cv_.notify_all();
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
    // 活动账本：startup 是**每个任务独立 detach 的线程**，整段只服务这一个任务，
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
    return true;
}

bool DownloadEngine::resumeTask(uint64_t task_id) {
    LoaderDownloadPtr task;
    {
        std::lock_guard<std::mutex> lk(task_mu_);
        auto it = tasks_.find(task_id);
        if (it == tasks_.end()) return false;
        task = it->second;
    }

    LoadState s = task->state();
    if (s != LoadState::Aborted && s != LoadState::Failed) {
        AMCL_LOG_W(LOG_TAG, "resumeTask: rejected in state=%{public}d", (int)s);
        return false;
    }

    // 取消可能在旧 startup 的 SHA/HEAD 窗口内到达。必须等旧 epoch 完全退出后
    // 才能 reset NetFile，否则 resetForRetry 会与旧 NetFile::start 并发改同一组线程。
    waitForStartupIdle_(task_id);

    // 1. 任务级复位
    if (!task->resetToWaiting()) {
        AMCL_LOG_W(LOG_TAG, "resumeTask: resetToWaiting failed");
        return false;
    }

    // 2. 每个非 Finished 文件也要复位，让 start() 能重新触发 preCheck / meta 恢复
    for (auto& f : task->files()) {
        if (f->state() != NetState::Finished) {
            f->resetForRetry();
        }
    }

    // 3. 重走 startTask 流程
    return startTask(task_id);
}

int64_t DownloadEngine::deleteTaskFiles(uint64_t task_id) {
    LoaderDownloadPtr task;
    {
        std::lock_guard<std::mutex> lk(task_mu_);
        auto it = tasks_.find(task_id);
        if (it == tasks_.end()) return 0;
        task = it->second;
    }
    return task->deleteFilesOnDisk();
}

bool DownloadEngine::retryFailedFiles(uint64_t task_id,
                                      const std::vector<std::string>& local_paths) {
    LoaderDownloadPtr task;
    {
        std::lock_guard<std::mutex> lk(task_mu_);
        auto it = tasks_.find(task_id);
        if (it == tasks_.end()) return false;
        task = it->second;
    }

    // v5 Bug-2: 状态校验 + per-file reset 全部归位到 LoaderDownload::retryFailedFiles。
    // engine 只负责查表和重新入队。
    // subset retry 同样必须与旧 startup epoch 建立 happens-before，确保只会有
    // 本轮 selected set 对应的 NetFile::start 在运行。
    waitForStartupIdle_(task_id);

    if (!task->retryFailedFiles(local_paths)) {
        return false;
    }
    return startTask(task_id);
}

bool DownloadEngine::purgeTask(uint64_t task_id) {
    std::lock_guard<std::mutex> lk(task_mu_);
    auto it = tasks_.find(task_id);
    if (it == tasks_.end()) return false;
    // 只允许终态任务被 purge（防止清到还在跑的）
    LoadState s = it->second->state();
    if (s != LoadState::Finished && s != LoadState::Failed && s != LoadState::Aborted) {
        return false;
    }
    // 终态仅表示用户可观察状态；取消可能先于 curl/worker 真正退出。
    // path ownership 和对象销毁必须再通过 execution-settled barrier。
    if (!it->second->isExecutionSettled()) {
        return false;
    }
    for (const auto& file : it->second->files()) {
        auto owner = path_owners_.find(file->localPath());
        if (owner != path_owners_.end() && owner->second == task_id) {
            path_owners_.erase(owner);
        }
    }
    tasks_.erase(it);
    return true;
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

void DownloadEngine::trackThreadsForProgress_(const std::vector<NetThreadPtr>& threads) {
    if (threads.empty()) return;

    std::vector<LoaderDownloadPtr> tasks;
    {
        std::lock_guard<std::mutex> lk(task_mu_);
        tasks.reserve(tasks_.size());
        for (const auto& entry : tasks_) tasks.push_back(entry.second);
    }

    // enqueueThreads() 兼容入口没有 task id；用 NetThread::task() 的 NetFile 指针
    // 与任务文件表匹配。只在入队时执行，避免 progress tick 做全局反查。
    for (const auto& task : tasks) {
        std::unordered_set<const NetFile*> owned_files;
        owned_files.reserve(task->files().size());
        for (const auto& file : task->files()) owned_files.insert(file.get());

        std::vector<NetThreadPtr> owned_threads;
        for (const auto& thread : threads) {
            if (thread && owned_files.count(thread->task()) > 0) {
                owned_threads.push_back(thread);
            }
        }
        if (!owned_threads.empty()) task->trackThreadsForProgress(owned_threads);
    }
}

void DownloadEngine::settleThreadsAborted(std::vector<NetThreadPtr> threads) {
    for (auto& t : threads) {
        if (!t) continue;
        t->setState(NetState::Aborted);
        t->markExecutionSettled();
    }
}

void DownloadEngine::enqueueThreadsForTask(uint64_t task_id,
                                           std::vector<NetThreadPtr> threads) {
    if (threads.empty()) return;
    trackThreadsForProgress_(threads);
    bool rejected = false;
    {
        std::lock_guard<std::mutex> lifecycle_lk(lifecycle_mu_);
        if (lifecycle_state_ != LifecycleState::Running ||
            !running_.load(std::memory_order_acquire)) {
            rejected = true;
        } else {
            std::lock_guard<std::mutex> queue_lk(queue_mu_);
            auto& queue = pending_threads_by_task_[task_id];
            if (queue.empty()) pending_task_order_.push_back(task_id);
            for (auto& t : threads) queue.push_back(std::move(t));
        }
    }
    if (rejected) {
        AMCL_LOG_W(LOG_TAG, "worker enqueue rejected during shutdown: %{public}zu threads",
                    threads.size());
        settleThreadsAborted(std::move(threads));
        return;
    }
    queue_cv_.notify_all();
}

void DownloadEngine::enqueueThreads(std::vector<NetThreadPtr> threads) {
    // NetFile 内部 retry/grow 没有公开 taskId；归入兼容队列 0。startup 主路径使用
    // enqueueThreadsForTask(taskId, ...) 保持任务间 round-robin。
    enqueueThreadsForTask(0, std::move(threads));
}

void DownloadEngine::enqueueMulti(std::vector<NetThreadPtr> threads) {
    if (threads.empty()) return;
    trackThreadsForProgress_(threads);
    bool rejected = false;
    {
        std::lock_guard<std::mutex> lifecycle_lk(lifecycle_mu_);
        if (lifecycle_state_ != LifecycleState::Running ||
            !running_.load(std::memory_order_acquire)) {
            rejected = true;
        } else if (multi_downloader_) {
            multi_downloader_->enqueue(std::move(threads));
            return;
        }
    }
    if (rejected) {
        AMCL_LOG_W(LOG_TAG, "multi enqueue rejected during shutdown: %{public}zu threads",
                    threads.size());
        settleThreadsAborted(std::move(threads));
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
            pending_task_order_.pop_front();
            auto it = pending_threads_by_task_.find(task_id);
            if (it == pending_threads_by_task_.end() || it->second.empty()) continue;
            t = std::move(it->second.front());
            it->second.pop_front();
            if (it->second.empty()) pending_threads_by_task_.erase(it);
            else pending_task_order_.push_back(task_id);
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

    for (const auto& task : snapshot) {
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
            bool has_progress = false;
            for (const auto& seg : snap.segments) {
                if (seg.done > 0) { has_progress = true; break; }
            }
            // 尚未创建 staging 的纯 Connecting 文件不写空恢复点，也不把 ENOENT
            // 误判为持久化故障。
            if (!has_progress) continue;

            attempted = true;
            std::string meta_path = f->localPath() + ".download-meta";
            // crash-consistency 顺序必须是 data fsync -> meta tmp fsync -> meta rename。
            // done_ 在 pwrite 成功后以 release/acq_rel 发布；snapshot 的 acquire 读取保证
            // 这里的 fsync 覆盖 meta 将要声明的全部字节。
            if (int sync_error = f->syncStagingDurable(); sync_error != 0) {
                AMCL_LOG_E(LOG_TAG,
                    "staging fsync before meta failed errno=%{public}d: %{public}s",
                    sync_error, f->stagingPath().c_str());
                all_success = false;
                if (first_failed_meta.empty()) first_failed_meta = meta_path;
                continue;
            }

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
            if (!writeMetaFile(meta_path, m)) {
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
    for (const auto& task : snapshot) {
        if (task->state() == LoadState::Loading) task->tickProgress();
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
    for (const auto& task : snapshot) {
        if (task->state() != LoadState::Loading) continue;
        for (const auto& f : task->files()) {
            f->maybeGrowThreads();
        }
    }
}

void DownloadEngine::tickerLoop() {
    auto last_meta = std::chrono::steady_clock::now();
    while (running_.load(std::memory_order_acquire)) {
        {
            std::unique_lock<std::mutex> lk(ticker_mu_);
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
    int n = ++host_fail_counts_[host];
    if (n < kBanThreshold) {
        AMCL_LOG_W(LOG_TAG, "addBadHost: %{public}s fail %{public}d/%{public}d",
                    host.c_str(), n, kBanThreshold);
        return;
    }

    int shift = std::min(3, n - kBanThreshold);
    int64_t ttl_ms = std::min(kMaxTtlMs, kBaseTtlMs << shift);
    bad_host_until_ms_[host] = now_ms + ttl_ms;
    bad_host_probe_until_ms_.erase(host);
    AMCL_LOG_W(LOG_TAG,
        "addBadHost: %{public}s circuit open %{public}lldms after %{public}d failures",
        host.c_str(), (long long)ttl_ms, n);
}

void DownloadEngine::markHostHealthy(const std::string& host) {
    if (host.empty()) return;

    std::lock_guard<std::mutex> lk(bad_hosts_mu_);
    const bool had_failures = host_fail_counts_.erase(host) > 0;
    const bool was_open = bad_host_until_ms_.erase(host) > 0;
    const bool was_probe = bad_host_probe_until_ms_.erase(host) > 0;
    if (had_failures || was_open || was_probe) {
        AMCL_LOG_I(LOG_TAG,
            "markHostHealthy: %{public}s circuit closed by verified transfer progress",
            host.c_str());
    }
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

bool DownloadEngine::tryAcquireHostSlot(const std::string& host) {
    if (host.empty()) return true;   // 无法识别主机时不拦
    std::lock_guard<std::mutex> lk(bad_hosts_mu_);
    int& limit = worker_host_limit_[host];
    if (limit <= 0) limit = kWorkerHostInitialLimit;
    int& active = worker_host_active_[host];
    if (active >= limit) return false;
    // PCL2 的 bmclapi 频率节流：同一受限主机两条新连接之间至少隔 50ms。
    // 与 MultiDownloader 的实现理由相同 —— 这里也不能 sleep（会占住 worker 线程），
    // 改为"未到时刻就拒绝准入"，调用方本就会换源或稍后重试。
    if (isThrottledHostName(host)) {
        // 与本文件其它时刻记账（noteHostRateLimit / hostRateLimitUntilMs）同一口径。
        const int64_t now = nowMonotonicUs() / 1000;
        auto slot = worker_host_next_start_ms_.find(host);
        if (slot != worker_host_next_start_ms_.end() && now < slot->second) return false;
        worker_host_next_start_ms_[host] = now + kThrottledHostStartIntervalMs;
    }
    ++active;
    return true;
}

void DownloadEngine::releaseHostSlot(const std::string& host, bool ok) {
    if (host.empty()) return;
    std::lock_guard<std::mutex> lk(bad_hosts_mu_);
    auto it = worker_host_active_.find(host);
    if (it != worker_host_active_.end() && it->second > 0) --it->second;
    if (!ok) {
        worker_host_ok_streak_[host] = 0;
        return;
    }
    // 成功即衰减 429 连击，避免长期累积后退避永久处于高位。
    auto rl = host_ratelimit_streak_.find(host);
    if (rl != host_ratelimit_streak_.end() && rl->second > 0) --rl->second;
    int& streak = worker_host_ok_streak_[host];
    if (++streak < kWorkerHostRecoverOk) return;
    streak = 0;
    int& limit = worker_host_limit_[host];
    if (limit <= 0) limit = kWorkerHostInitialLimit;
    if (limit < kWorkerHostMaxLimit) {
        ++limit;
        AMCL_LOG_I(LOG_TAG, "hostSlot: %{public}s limit recovered to %{public}d",
                    host.c_str(), limit);
    }
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
    int& streak = host_ratelimit_streak_[host];
    if (streak < 6) ++streak;
    int64_t backoff = std::min(kCapMs, kBaseMs << (streak - 1));
    if (retry_after_ms > backoff) backoff = std::min(kCapMs, retry_after_ms);
    // jitter：0~400ms，避免同主机的多段在同一毫秒齐发。
    backoff += (static_cast<int64_t>(host.size()) * 37 + streak * 91) % 400;
    int64_t until = now_ms + backoff;
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
    auto probe = bad_host_probe_until_ms_.find(host);
    if (probe != bad_host_probe_until_ms_.end()) ready = std::max(ready, probe->second);
    return ready;
}

bool DownloadEngine::isBadHost(const std::string& host) const {
    if (host.empty()) return false;
    constexpr int64_t kHalfOpenProbeLeaseMs = 45 * 1000;
    const int64_t now_ms = nowMonotonicUs() / 1000;
    std::lock_guard<std::mutex> lk(bad_hosts_mu_);

    auto open_it = bad_host_until_ms_.find(host);
    if (open_it == bad_host_until_ms_.end()) {
        auto existing_probe = bad_host_probe_until_ms_.find(host);
        if (existing_probe == bad_host_probe_until_ms_.end()) {
            // 普通 closed host，或尚未达到熔断阈值。
            return false;
        }
        if (now_ms < existing_probe->second) return true;
        // 探针租约内没有 addBadHost 重新开路，视为探针成功并恢复 closed。
        bad_host_probe_until_ms_.erase(existing_probe);
        host_fail_counts_.erase(host);
        AMCL_LOG_I(LOG_TAG, "isBadHost: half-open probe succeeded, circuit closed for %{public}s",
                    host.c_str());
        return false;
    }
    if (now_ms < open_it->second) return true;
    bad_host_until_ms_.erase(open_it);

    auto probe_it = bad_host_probe_until_ms_.find(host);
    if (probe_it == bad_host_probe_until_ms_.end()) {
        // TTL 到期只放行一个探针；租约覆盖当前网络层 30s 总超时，防止并发文件
        // 在半开窗口同时冲向刚恢复/仍故障的节点。
        bad_host_probe_until_ms_[host] = now_ms + kHalfOpenProbeLeaseMs;
        auto count_it = host_fail_counts_.find(host);
        if (count_it != host_fail_counts_.end()) count_it->second = 2;
        AMCL_LOG_I(LOG_TAG, "isBadHost: TTL expired, single half-open probe allowed for %{public}s",
                    host.c_str());
        return false;
    }
    if (now_ms < probe_it->second) return true;

    // 探针租约内没有 addBadHost 重新开路，视为探针成功并恢复 closed。
    bad_host_probe_until_ms_.erase(probe_it);
    host_fail_counts_.erase(host);
    AMCL_LOG_I(LOG_TAG, "isBadHost: half-open probe succeeded, circuit closed for %{public}s",
                host.c_str());
    return false;
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

struct FetchWriteContext {
    std::string* body = nullptr;
    size_t max_bytes = kFetchBodyLimit;
    bool too_large = false;
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
    if (ctx->body->size() > ctx->max_bytes || total > ctx->max_bytes - ctx->body->size()) {
        ctx->too_large = true;
        return 0; // CURLE_WRITE_ERROR；调用方转换为明确的 ResponseTooLarge。
    }
    try {
        ctx->body->append(ptr, total);
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
    auto* hdrs = static_cast<std::map<std::string, std::string>*>(userdata);
    size_t total = size * nitems;
    if (total == 0 || !hdrs) return total;
    // libcurl 在 follow redirect 期间可能多次调本回调（每次跳转都来一遍 headers）。
    // 每次新 status line 都先 clear，让最终响应头胜出。
    if (total >= 5 && std::strncmp(buffer, "HTTP/", 5) == 0) {
        hdrs->clear();
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

/** 单个 URL 尝试：返回 0 = 成功，非 0 = 失败（填充 out_err_*） */
int fetchOnce(const std::string& url, int timeout_seconds,
              std::string& out_body,
              std::string& out_err_kind,
              std::string& out_err_msg) {
    CURL* easy = curl_easy_init();
    if (!easy) {
        out_err_kind = "Unknown";
        out_err_msg = "curl_easy_init returned null";
        return -1;
    }

    out_body.clear();

    curl_easy_setopt(easy, CURLOPT_URL, url.c_str());
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(easy, CURLOPT_MAXREDIRS, 5L);
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT, std::min(timeout_seconds, 15));
    curl_easy_setopt(easy, CURLOPT_TIMEOUT, (long)timeout_seconds);
    curl_easy_setopt(easy, CURLOPT_FAILONERROR, 1L);  // 4xx/5xx → CURLE_HTTP_RETURNED_ERROR
    curl_easy_setopt(easy, CURLOPT_USERAGENT, "amcl/0.1 (OHOS; libcurl/8.10.1)");
    curl_easy_setopt(easy, CURLOPT_ACCEPT_ENCODING, "");  // 启用 gzip/deflate 解压
    // 元数据请求同样走每主机地址族选择（见 ipResolveFor）。这条路径是"点安装后卡住"
    // 的主要嫌疑：manifest / API / .sha1 全在这里，若首选到不通的 IPv6 就要白等一次
    // connect timeout。结果也记账，让 IPv6-only 的主机能在一次失败后自动翻回去。
    const std::string fam_host = familyHostFromUrl(url);
    const long fam_resolve = DownloadEngine::instance().ipResolveFor(fam_host);
    curl_easy_setopt(easy, CURLOPT_IPRESOLVE, fam_resolve);

    // SSL 配置（与 NetThread 保持一致）
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);
    std::string ca_path = getCaBundlePath();
    if (!ca_path.empty()) {
        curl_easy_setopt(easy, CURLOPT_CAINFO, ca_path.c_str());
    }

    // Write callback（8 MiB 解压后正文硬上限）
    FetchWriteContext write_ctx{&out_body, kFetchBodyLimit, false};
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, fetchWriteCallback);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, &write_ctx);

    CURLcode rc = curl_easy_perform(easy);
    long http_code = 0;
    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &http_code);
    char* fam_ip_raw = nullptr;
    curl_easy_getinfo(easy, CURLINFO_PRIMARY_IP, &fam_ip_raw);
    const std::string fam_primary_ip = (fam_ip_raw && fam_ip_raw[0] != '\0') ? fam_ip_raw : "";
    curl_easy_cleanup(easy);
    // 记账地址族结果。注意 4xx/5xx 不算族的问题（连接是通的），只有真正的连接类
    // 失败才扣分，否则一个 404 会把好用的 IPv4 打成负分。
    {
        const bool fam_conn_ok = (rc == CURLE_OK || http_code > 0);
        DownloadEngine::instance().noteFamilyOutcome(
            fam_host, fam_resolve, fam_primary_ip, fam_conn_ok,
            rc == CURLE_COULDNT_RESOLVE_HOST);
    }

    if (write_ctx.too_large) {
        out_body.clear();
        out_err_kind = "ResponseTooLarge";
        out_err_msg = "response body exceeded 8 MiB limit";
        return -1;
    }
    if (rc == CURLE_OK && http_code >= 200 && http_code < 300) {
        return 0;
    }

    out_err_kind = curlcodeToKind(rc, http_code);
    if (rc != CURLE_OK) {
        out_err_msg = curlErrorMessage(rc);
        if (http_code > 0) {
            out_err_msg += " (http=" + std::to_string(http_code) + ")";
        }
    } else {
        // rc==OK 但 http_code 非 2xx
        out_err_msg = "HTTP " + std::to_string(http_code);
    }
    return -1;
}

/**
 * Phase 2.3 版 fetchOnce：附加 request_headers + 捕获 response_headers + 接受 304。
 * 返回 0 当且仅当 (rc==OK 且 (200-299 或 304))。其他情况返回 -1 且填充 err_*。
 */
int fetchOnceEx(const std::string& url,
                int timeout_seconds,
                const std::map<std::string, std::string>& request_headers,
                size_t max_response_bytes,
                FetchResponse& out) {
    CURL* easy = curl_easy_init();
    if (!easy) {
        out.err_kind = "Unknown";
        out.err_msg = "curl_easy_init returned null";
        return -1;
    }

    out.body.clear();
    out.headers.clear();
    out.status_code = 0;

    curl_easy_setopt(easy, CURLOPT_URL, url.c_str());
    curl_easy_setopt(easy, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(easy, CURLOPT_MAXREDIRS, 5L);
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT, std::min(timeout_seconds, 15));
    curl_easy_setopt(easy, CURLOPT_TIMEOUT, (long)timeout_seconds);
    // 关键差异：不设 FAILONERROR — 304/4xx 也要走完，让调用方拿 status + headers
    curl_easy_setopt(easy, CURLOPT_USERAGENT, "amcl/0.1 (OHOS; libcurl/8.10.1)");
    curl_easy_setopt(easy, CURLOPT_ACCEPT_ENCODING, "");
    // 与 fetchOnce 一致的每主机地址族选择（见 DownloadEngine::ipResolveFor）。
    const std::string fam_host = familyHostFromUrl(url);
    const long fam_resolve = DownloadEngine::instance().ipResolveFor(fam_host);
    curl_easy_setopt(easy, CURLOPT_IPRESOLVE, fam_resolve);

    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);
    std::string ca_path = getCaBundlePath();
    if (!ca_path.empty()) {
        curl_easy_setopt(easy, CURLOPT_CAINFO, ca_path.c_str());
    }

    // Write callback: enforce the limit before appending into the native string.
    FetchWriteContext write_ctx{&out.body, max_response_bytes, false};
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, fetchWriteCallback);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, &write_ctx);

    // Header callback (Phase 2.3: 捕获 ETag / Last-Modified / Content-Type 等)
    curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, fetchHeaderCallback);
    curl_easy_setopt(easy, CURLOPT_HEADERDATA, &out.headers);

    // 请求头列表（如 If-None-Match / If-Modified-Since）
    struct curl_slist* slist = nullptr;
    for (const auto& kv : request_headers) {
        if (kv.first.empty()) continue;
        // libcurl 期望 "Name: Value"；空 value 时 "Name:" 表示删除该头
        std::string line = kv.first;
        line += ": ";
        line += kv.second;
        slist = curl_slist_append(slist, line.c_str());
    }
    if (slist) curl_easy_setopt(easy, CURLOPT_HTTPHEADER, slist);

    CURLcode rc = curl_easy_perform(easy);
    long http_code = 0;
    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &http_code);
    out.status_code = static_cast<int>(http_code);
    char* fam_ip_raw = nullptr;
    curl_easy_getinfo(easy, CURLINFO_PRIMARY_IP, &fam_ip_raw);
    const std::string fam_primary_ip = (fam_ip_raw && fam_ip_raw[0] != '\0') ? fam_ip_raw : "";

    if (slist) curl_slist_free_all(slist);
    curl_easy_cleanup(easy);
    // 只有连接类失败才扣该族的分；304/4xx 说明链路是通的。
    {
        const bool fam_conn_ok = (rc == CURLE_OK || http_code > 0);
        DownloadEngine::instance().noteFamilyOutcome(
            fam_host, fam_resolve, fam_primary_ip, fam_conn_ok,
            rc == CURLE_COULDNT_RESOLVE_HOST);
    }

    if (write_ctx.too_large) {
        out.body.clear();
        out.err_kind = "ResponseTooLarge";
        out.err_msg = "response body exceeded " + std::to_string(max_response_bytes) +
                      " byte limit";
        return -1;
    }
    if (rc == CURLE_OK && ((http_code >= 200 && http_code < 300) || http_code == 304)) {
        return 0;
    }

    out.err_kind = curlcodeToKind(rc, http_code);
    if (rc != CURLE_OK) {
        out.err_msg = curlErrorMessage(rc);
        if (http_code > 0) out.err_msg += " (http=" + std::to_string(http_code) + ")";
    } else {
        out.err_msg = "HTTP " + std::to_string(http_code);
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

    if (timeout_seconds <= 0) timeout_seconds = 30;
    if (timeout_seconds > 300) timeout_seconds = 300;

    std::vector<std::string> urls;
    urls.reserve(1 + mirrors.size());
    urls.push_back(primary_url);
    for (const auto& m : mirrors) urls.push_back(m);

    out_err_kind.clear();
    out_err_msg.clear();
    int result = -1;
    for (const auto& url : urls) {
        if (url.empty()) continue;
        int rc = fetchOnce(url, timeout_seconds, out_body, out_err_kind, out_err_msg);
        if (rc == 0) {
            AMCL_LOG_D(LOG_TAG, "fetchToBuffer ok: %{public}s (%{public}zu bytes)",
                         url.c_str(), out_body.size());
            result = 0;
            break;
        }
        AMCL_LOG_D(LOG_TAG, "fetchToBuffer fail: %{public}s kind=%{public}s msg=%{public}s",
                     url.c_str(), out_err_kind.c_str(), out_err_msg.c_str());
    }

    if (result != 0 && (urls.empty() || (urls.size() == 1 && urls[0].empty()))) {
        out_err_kind = "Unknown";
        out_err_msg = "no URLs provided";
    }
    releaseCurlUse();
    return result;
}

int DownloadEngine::fetchToBufferEx(const std::string& primary_url,
                                     const std::vector<std::string>& mirrors,
                                     int timeout_seconds,
                                     const std::map<std::string, std::string>& request_headers,
                                     size_t max_response_bytes,
                                     FetchResponse& out_resp) {
    if (!acquireCurlUse(&out_resp.err_kind, &out_resp.err_msg)) return -1;

    if (timeout_seconds <= 0) timeout_seconds = 30;
    if (timeout_seconds > 300) timeout_seconds = 300;
    constexpr size_t kMaxConfigurableFetchBody = 16U * 1024U * 1024U;
    if (max_response_bytes == 0) max_response_bytes = 1;
    if (max_response_bytes > kMaxConfigurableFetchBody) {
        max_response_bytes = kMaxConfigurableFetchBody;
    }

    std::vector<std::string> urls;
    urls.reserve(1 + mirrors.size());
    urls.push_back(primary_url);
    for (const auto& m : mirrors) urls.push_back(m);

    out_resp.err_kind.clear();
    out_resp.err_msg.clear();
    int result = -1;
    for (const auto& url : urls) {
        if (url.empty()) continue;
        int rc = fetchOnceEx(url, timeout_seconds, request_headers,
                             max_response_bytes, out_resp);
        if (rc == 0) {
            AMCL_LOG_D(LOG_TAG, "fetchToBufferEx ok: %{public}s status=%{public}d (%{public}zu bytes)",
                         url.c_str(), out_resp.status_code, out_resp.body.size());
            result = 0;
            break;
        }
        AMCL_LOG_D(LOG_TAG, "fetchToBufferEx fail: %{public}s kind=%{public}s msg=%{public}s",
                     url.c_str(), out_resp.err_kind.c_str(), out_resp.err_msg.c_str());
    }

    if (result != 0 && (urls.empty() || (urls.size() == 1 && urls[0].empty()))) {
        out_resp.err_kind = "Unknown";
        out_resp.err_msg = "no URLs provided";
    }
    releaseCurlUse();
    return result;
}

} // namespace download
