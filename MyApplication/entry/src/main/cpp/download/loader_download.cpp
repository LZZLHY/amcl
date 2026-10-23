/**
 * loader_download.cpp — 任务级封装
 */
#include "loader_download.h"
#include "download_execution_context.h"
#include "engine.h"

#include <hilog/log.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <unordered_set>

#include "../utils/amcl_log.h"

#undef LOG_TAG
#define LOG_TAG "DL_TASK"

namespace download {

namespace {

/** 获取 basename（最后一个 / 或 \ 之后的部分） */
std::string basenameOf(const std::string& path) {
    if (path.empty()) return {};
    auto pos = path.find_last_of("/\\");
    if (pos == std::string::npos) return path;
    return path.substr(pos + 1);
}

/** 当前 steady_clock 时间戳（毫秒） */
int64_t nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

bool isTerminalFileState(NetState state) {
    return state == NetState::Finished || state == NetState::Failed || state == NetState::Aborted;
}

} // namespace

LoaderDownload::LoaderDownload(Config cfg) : cfg_(std::move(cfg)) {
    files_.reserve(cfg_.files.size());
    for (auto fc : cfg_.files) {
        // cfg_ 是不可变任务规格；必须复制到可写文件规格后显式传入真实批次 ID。
        // 旧 SFINAE 对 const Config 的赋值不成立，会静默落到空重载，导致文件 ID 为 0，
        // 后续 multi 公平队列、worker retry/grow 和活动归属失去原批次身份。
        fc.task_id = cfg_.task_id;
        auto f = std::make_shared<NetFile>(std::move(fc));
        f->setOwner(this);
        files_.push_back(f);
    }
}

LoaderDownload::~LoaderDownload() = default;

DownloadExceptionPtr LoaderDownload::error() const {
    std::lock_guard<std::mutex> lk(mu_);
    return error_;
}

void LoaderDownload::setError(DownloadExceptionPtr ex) {
    std::lock_guard<std::mutex> lk(mu_);
    error_ = std::move(ex);
}

void LoaderDownload::onStart() {
    // 每个 start/retry 都发布新选择 epoch；startup 线程可据此只启动本轮文件。
    selection_epoch_.fetch_add(1, std::memory_order_acq_rel);

    // 保留兼容缓存；computeProgress 会在每次快照中使用 HEAD/fileSize 动态重算。
    int64_t total = 0;
    bool all_known = true;
    for (const auto& f : files_) {
        int64_t sz = f->fileSize();
        if (sz <= 0) sz = f->checker().expected_size;
        if (sz > 0) total += sz;
        else all_known = false;
    }
    bytes_total_precomputed_ = total;
    all_sizes_known_ = all_known;

    started_at_ms_.store(nowMs(), std::memory_order_release);
    finished_at_ms_.store(0, std::memory_order_release);
    consecutive_meta_failures_.store(0, std::memory_order_release);

    transitTo(LoadState::Loading);
    LoadState preserved_result = LoadState::Waiting;
    {
        std::lock_guard<std::mutex> completion_lk(completion_mu_);
        // 取消可在最后一个文件已 Finished、Loader 聚合尚未完成时获胜；resume 保留
        // 全部成功文件后 startup 不会再收到 callback，须在这里按已归集结果同步收敛。
        // 同样检查失败/取消分类，不能把子集 retry 保留的失败文件一并洗成成功。
        if (completed_files_.size() == files_.size()) {
            if (abort_requested_.load(std::memory_order_acquire) || files_aborted_count_.load() > 0)
                preserved_result = LoadState::Aborted;
            else if (files_failed_count_.load() > 0) preserved_result = LoadState::Failed;
            else preserved_result = LoadState::Finished;
        }
    }
    if (preserved_result != LoadState::Waiting) transitTo(preserved_result);
}

void LoaderDownload::setOnStateChanged(StateChangedCb cb) {
    std::lock_guard<std::mutex> lk(mu_);
    on_state_changed_ = std::move(cb);
}

void LoaderDownload::setOnProgressChanged(ProgressChangedCb cb) {
    std::lock_guard<std::mutex> lk(mu_);
    on_progress_changed_ = std::move(cb);
}

void LoaderDownload::setOnComplete(CompleteCb cb) {
    std::lock_guard<std::mutex> lk(mu_);
    on_complete_ = std::move(cb);
}

void LoaderDownload::setOnTerminal(std::function<void(uint64_t)> cb) {
    std::lock_guard<std::mutex> lk(mu_);
    on_terminal_ = std::move(cb);
}

void LoaderDownload::trackThreadsForProgress(const std::vector<NetThreadPtr>& threads) {
    if (threads.empty()) return;
    std::lock_guard<std::mutex> lk(progress_threads_mu_);
    // 先扩充弱引用容器，再修改身份集合；否则 push 分配失败会留下“集合已登记但
    // 向量无此段”的半条观察记录。后续 pair/weak_ptr 复制不分配，失败可安全跳过观察。
    const size_t required = tracked_threads_.size() + threads.size();
    if (required > tracked_threads_.capacity()) {
        // 保留 vector 的几何增长特性；若每个 asset 都 reserve(size+1)，数千小文件
        // 会反复复制整张观察表，重新引入二次成本。只在容量不足时扩充。
        const size_t capacity = tracked_threads_.capacity();
        const size_t doubled = capacity <= tracked_threads_.max_size() / 2
            ? capacity * 2 : tracked_threads_.max_size();
        tracked_threads_.reserve(std::max(required, std::max<size_t>(8, doubled)));
    }
    for (const auto& thread : threads) {
        if (!thread || !tracked_thread_ids_.insert(thread.get()).second) continue;
        tracked_threads_.push_back({thread.get(), thread});
    }
}

bool LoaderDownload::isExecutionSettled() const {
    // 用户可见终态先发布，随后才同步投递 state/complete/owner 回调；这些回调也可能
    // 反入 Engine。全部退出前不得 purge、复位 epoch 或释放 final-path 所有权。
    if (active_callbacks_.load(std::memory_order_acquire) != 0) return false;
    return std::all_of(files_.begin(), files_.end(), [](const NetFilePtr& file) {
        return !file || file->isExecutionSettled();
    });
}

bool LoaderDownload::shouldStartFile(const NetFile* file) const {
    if (!file) return false;
    std::lock_guard<std::mutex> lk(completion_mu_);
    if (completed_files_.count(file) > 0) return false;
    return !selection_enabled_ || selected_retry_paths_.count(file->localPath()) > 0;
}

void LoaderDownload::reportMetaPersistenceResult(bool success, const std::string& meta_path) {
    if (success) {
        consecutive_meta_failures_.store(0, std::memory_order_release);
        return;
    }
    constexpr int kFailureLimit = 3;
    int failures = consecutive_meta_failures_.fetch_add(1, std::memory_order_acq_rel) + 1;
    if (failures >= kFailureLimit) {
        reject(makeException(ErrorKind::StorageIoError,
            "download meta persistence repeatedly failed: " + meta_path));
    }
}

void LoaderDownload::reject(DownloadExceptionPtr ex) {
    LoadState cur = state_.load(std::memory_order_acquire);
    if (cur == LoadState::Finished || cur == LoadState::Failed || cur == LoadState::Aborted) return;
    infrastructure_failure_.store(true, std::memory_order_release);
    setError(ex ? std::move(ex) : makeException(ErrorKind::InternalError, "download task rejected"));
    for (auto& f : files_) f->abort();
    transitTo(LoadState::Failed);
}

void LoaderDownload::failSchedulingWithoutAllocation() noexcept {
    const auto current = state();
    if (current == LoadState::Finished || current == LoadState::Failed || current == LoadState::Aborted) return;
    infrastructure_failure_.store(true, std::memory_order_release);
    // 这里不能再次 makeException/string 拼接以“处理”分配失败。先取消所有实际执行，
    // transitTo 在 callback 快照分配前就发布 Failed；即使持续 OOM 导致观察未送达，
    // Native 查询仍读到失败且完整执行屏障仍阻止提前释放。不是全系统 OOM 恢复框架。
    for (auto& file : files_) {
        try { file->abort(); } catch (...) { /* 保留 owner，真实执行仍由屏障约束。 */ }
    }
    try { transitTo(LoadState::Failed); }
    catch (...) { AMCL_LOG_E(LOG_TAG, "scheduling failure: terminal snapshot unavailable; query retains Failed state"); }
    // Failed 已发布，cancelTask 的 Loader.abort 因终态而幂等，不会改成用户取消；仍沿
    // 现有 Engine 通道唤醒多路循环，避免另一文件卡在 120s Retry-After 睡眠直到旧期限。
    // 所有调用点均在 lifecycle/task/file 锁外进入此降级方法。
    try { DownloadEngine::instance().cancelTask(cfg_.task_id); }
    catch (...) { AMCL_LOG_E(LOG_TAG, "scheduling failure cancellation wake unavailable; execution remains guarded"); }
}

void LoaderDownload::transitTo(LoadState new_state) {
    DownloadExecutionContext callback_context;
    // 在终态 CAS 之前占用回调屏障，消除“已读到终态但回调尚未登记”的回收窗口。
    // 局部守卫保证重复转移、异常退出也归还计数，且整个回调过程不持 Loader 的锁。
    struct CallbackGuard {
        std::atomic<unsigned>& count;
        explicit CallbackGuard(std::atomic<unsigned>& value) : count(value) {
            count.fetch_add(1, std::memory_order_acq_rel);
        }
        ~CallbackGuard() { count.fetch_sub(1, std::memory_order_release); }
    } callback_guard(active_callbacks_);
    // L-4 修复：终态吸收 — 一旦进入 Finished/Failed/Aborted 任一终态，
    // 拒绝再次 transitTo。原实现仅判 `old == new_state`，可能从 Finished
    // 被误转到 Failed/Aborted（外部调用方或后续逻辑误触），导致 onComplete
    // 重复触发 / UI 看到任务"先成功又失败"的诡异状态。
    //
    // 用 compare_exchange_strong 而非 exchange：
    //   - 读 old；
    //   - 若 old 已是终态 → 直接 return，不动 state_；
    //   - 若 old 非终态 → CAS 写入 new_state；CAS 失败说明并发者已抢先
    //     转走（也大概率是终态），同样 return。
    LoadState old = state_.load(std::memory_order_acquire);
    while (true) {
        if (old == new_state) return;
        if (old == LoadState::Finished || old == LoadState::Failed
                || old == LoadState::Aborted) {
            AMCL_LOG_W(LOG_TAG,
                "transitTo rejected: already terminal old=%{public}d, attempted=%{public}d",
                (int)old, (int)new_state);
            return;
        }
        if (state_.compare_exchange_weak(old, new_state,
                                         std::memory_order_acq_rel,
                                         std::memory_order_acquire)) {
            break;
        }
        // CAS 失败：old 已被并发更新，重读后再判。loop 会自然处理新 old。
    }

    bool is_terminal = (new_state == LoadState::Finished ||
                        new_state == LoadState::Failed ||
                        new_state == LoadState::Aborted);

    // v5: 终态时记录完成时间戳，durationMs 从此使用 finished_at 而非当前时间
    if (is_terminal) {
        finished_at_ms_.store(nowMs(), std::memory_order_release);
    }

    StateChangedCb sc;
    CompleteCb cc;
    std::function<void(uint64_t)> terminal_cb;
    DownloadExceptionPtr err;
    {
        std::lock_guard<std::mutex> lk(mu_);
        sc = on_state_changed_;
        cc = on_complete_;
        terminal_cb = on_terminal_;
        err = error_;
    }

    if (sc) sc(old, new_state);

    if (is_terminal) {
        // 在 C++ 线程里抢先拿一个 final progress 快照。UI 在 onComplete 里
        // 直接从 ev.finalProgress 读完整数据，不再依赖 onProgress 是否触发。
        TaskProgress final_p = computeProgress();
        bool success = (new_state == LoadState::Finished);
        bool aborted = (new_state == LoadState::Aborted);
        if (cc) cc(success, aborted, err, final_p);
        // 独立 owner 通道与 UI callback 解耦，并由终态 CAS 保证 exactly-once。
        if (terminal_cb) terminal_cb(cfg_.task_id);
    }
}

int64_t LoaderDownload::durationMs() const {
    int64_t start = started_at_ms_.load(std::memory_order_relaxed);
    if (start == 0) return 0;
    int64_t finish = finished_at_ms_.load(std::memory_order_relaxed);
    if (finish == 0) finish = nowMs();
    return finish - start;
}

TaskProgress LoaderDownload::computeProgress() const {
    TaskProgress p;
    p.execution_epoch = selection_epoch_.load(std::memory_order_acquire);
    p.files_total = static_cast<int>(files_.size());
    p.files_done = files_done_count_.load(std::memory_order_relaxed);

    int64_t done_bytes = 0;
    int64_t total_bytes = 0;
    int64_t speed = 0;
    bool all_known = true;
    constexpr size_t kMaxCurrentFiles = 3;
    p.current_files.reserve(kMaxCurrentFiles);

    for (const auto& f : files_) {
        NetState st = f->state();
        int64_t size = f->fileSize();
        if (size <= 0) size = f->checker().expected_size;
        // 缓存命中且无 expected size 时用实际 regular-file 大小补齐汇总。
        if (size <= 0 && st == NetState::Finished) {
            struct stat sb {};
            if (::stat(f->localPath().c_str(), &sb) == 0 && S_ISREG(sb.st_mode)) {
                size = static_cast<int64_t>(sb.st_size);
            }
        }
        if (size > 0) total_bytes += size;
        else all_known = false;

        if (st == NetState::Finished) {
            if (size > 0) done_bytes += size;
            continue;
        }

        bool active = (st == NetState::Downloading || st == NetState::Connecting ||
                       st == NetState::Reading || st == NetState::CheckingLocal);
        bool has_bytes = active || st == NetState::FinalCheck || st == NetState::Failed ||
                         st == NetState::Aborted;
        if (has_bytes) done_bytes += std::max<int64_t>(0, f->downloadedBytes());

        if (active) {
            // 2026-07-31：从 sumRecentSpeedBps()（各段 200ms 瞬时速率求和、过期归零）改为
            // recentFileSpeedBps()（按本文件累计字节的时间差算，PCL2 NetFile.Speed 同款）。
            // 前者在任意一段处于 TTFB/重连时就把该段算作 0，真机 TTFB 实测 1~4.4s，于是
            // UI 速度在 MB/KB/B 之间反复跳 —— 那是度量伪影，不是真实吞吐波动。
            speed += f->recentFileSpeedBps();
            if (p.current_file.empty()) p.current_file = f->localPath();
            if (p.current_files.size() < kMaxCurrentFiles) {
                p.current_files.push_back(basenameOf(f->localPath()));
            }
        }
    }

    {
        std::lock_guard<std::mutex> lk(progress_threads_mu_);
        auto it = tracked_threads_.begin();
        while (it != tracked_threads_.end()) {
            auto thread = it->second.lock();
            if (!thread) {
                tracked_thread_ids_.erase(it->first);
                it = tracked_threads_.erase(it);
                continue;
            }
            NetState thread_state = thread->state();
            if (thread_state == NetState::Connecting || thread_state == NetState::Reading ||
                thread_state == NetState::Downloading) {
                ++p.active_threads;
            }
            ++it;
        }
    }

    p.bytes_total = all_known ? total_bytes : -1;
    p.bytes_done = done_bytes;
    if (all_known && total_bytes > 0) {
        p.overall_progress = static_cast<double>(done_bytes) / static_cast<double>(total_bytes);
    } else {
        p.overall_progress = p.files_total > 0
            ? static_cast<double>(p.files_done) / p.files_total : 0.0;
    }
    p.overall_progress = std::max(0.0, std::min(1.0, p.overall_progress));
    p.speed_bps = speed;

    if (p.bytes_total > 0 && p.speed_bps > 0) {
        int64_t remaining = p.bytes_total - p.bytes_done;
        p.eta_seconds = remaining > 0 ? (remaining / p.speed_bps) : 0;
    }

    // 成功终态规范化为 100%，避免本地缓存或最后一次 tick 时序导致 UI 小于 100%。
    if (state_.load(std::memory_order_acquire) == LoadState::Finished) {
        p.files_done = p.files_total;
        p.overall_progress = 1.0;
        if (p.bytes_total >= 0) p.bytes_done = p.bytes_total;
        p.speed_bps = 0;
        p.active_threads = 0;
        p.eta_seconds = 0;
        p.current_file.clear();
        p.current_files.clear();
    }
    return p;
}

void LoaderDownload::settleFile_(NetFile* f, NetState terminal_state,
                                 bool require_file_terminal) {
    if (!f) {
        AMCL_LOG_E(LOG_TAG, "settleFile rejected null file");
        return;
    }

    NetState observed = f->state();
    if (require_file_terminal && !isTerminalFileState(observed)) {
        AMCL_LOG_E(LOG_TAG,
            "reportFileFinished rejected non-terminal file state=%{public}d: %{public}s",
            (int)observed, f->localPath().c_str());
        return;
    }
    if (isTerminalFileState(observed)) terminal_state = observed;

    bool owned = false;
    for (const auto& candidate : files_) {
        if (candidate.get() == f) { owned = true; break; }
    }
    if (!owned) {
        AMCL_LOG_E(LOG_TAG, "settleFile rejected foreign file");
        return;
    }

    LoadState final_state = LoadState::Waiting;
    bool all_done = false;
    // 文件异常先按 NetFile 自身的锁复制，不能持 Loader.mu_ 反向进入 NetFile；后面
    // 统一按 completion_mu_ -> mu_ 归集。reset 的 mu_/completion 两段从不嵌套。
    DownloadExceptionPtr file_error = terminal_state == NetState::Failed ? f->error() : nullptr;
    {
        std::lock_guard<std::mutex> lk(completion_mu_);
        if (!completed_files_.insert(f).second) {
            AMCL_LOG_W(LOG_TAG, "file completion duplicate ignored: %{public}s",
                        f->localPath().c_str());
            return;
        }
        // 不能先发布 done 再登记 failed/error：失败 A 在 done++ 后被抢占时，最后
        // 成功的 B 会误判 failed=0 并发出 Finished。身份去重、分类、异常、done 和
        // 最终结果必须形成同一个临界区的完整收据，之后才允许锁外发回调。
        if (terminal_state == NetState::Failed) {
            files_failed_count_.fetch_add(1, std::memory_order_relaxed);
            std::lock_guard<std::mutex> error_lk(mu_);
            if (!error_) error_ = std::move(file_error);
        } else if (terminal_state == NetState::Aborted) {
            files_aborted_count_.fetch_add(1, std::memory_order_relaxed);
        }
        const size_t new_done = completed_files_.size();
        files_done_count_.store(static_cast<int>(new_done), std::memory_order_release);
        all_done = new_done == files_.size();
        if (all_done) {
            if (abort_requested_.load(std::memory_order_acquire) ||
                files_aborted_count_.load(std::memory_order_relaxed) > 0) final_state = LoadState::Aborted;
            else if (files_failed_count_.load(std::memory_order_relaxed) > 0) final_state = LoadState::Failed;
            else final_state = LoadState::Finished;
        }
    }
    if (all_done) transitTo(final_state);
}

void LoaderDownload::reportFileFinished(NetFile* f) {
    settleFile_(f, f ? f->state() : NetState::Failed, true);
}

void LoaderDownload::reportFileAbortedBeforeStart(NetFile* f) {
    // NetFile::abort() 同时记录文件 token 和取消已有段；尚未 start 的文件没有执行
    // 侧终态 callback，由任务层记录逻辑 Aborted，保证 files_done 与取消收敛完整。
    settleFile_(f, NetState::Aborted, false);
}

void LoaderDownload::abort() {
    LoadState cur = state_.load(std::memory_order_acquire);
    if (cur == LoadState::Finished || cur == LoadState::Failed || cur == LoadState::Aborted) return;

    // 先发布 cancel token，startup 在每个文件 start 前后都检查；再立即让任务收敛，
    // 避免“尚未启动的文件永远不会回调”导致取消 Promise pending。
    abort_requested_.store(true, std::memory_order_release);
    for (auto& f : files_) f->abort();
    transitTo(LoadState::Aborted);
}

std::vector<FailedFileInfo> LoaderDownload::failedFiles() const {
    std::vector<FailedFileInfo> out;
    for (const auto& f : files_) {
        NetState fs = f->state();
        if (fs != NetState::Failed) continue;

        FailedFileInfo info;
        info.local_path = f->localPath();
        info.last_error = f->error();

        // 去重收集试过的源 URL
        std::unordered_set<std::string> seen;
        for (const auto& s : f->sources()) {
            if (seen.insert(s->url).second) {
                info.tried_urls.push_back(s->url);
            }
        }
        // 如果 error 对象里还有 tried_urls（理论可能额外有 302 跳转到的镜像域名），补进去
        if (info.last_error) {
            for (const auto& u : info.last_error->tried_urls) {
                if (seen.insert(u).second) {
                    info.tried_urls.push_back(u);
                }
            }
        }
        out.push_back(std::move(info));
    }
    return out;
}

int64_t LoaderDownload::deleteFilesOnDisk() {
    // 必须在 Aborted / Failed 状态才允许清理，避免误删正在写入的文件
    LoadState cur = state_.load(std::memory_order_acquire);
    if (cur != LoadState::Aborted && cur != LoadState::Failed) {
        AMCL_LOG_W(LOG_TAG, "deleteFilesOnDisk rejected in state=%{public}d", (int)cur);
        return 0;
    }

    int64_t freed = 0;
    for (auto& f : files_) {
        // 只清理非 Finished 的文件（成功的不碰 — 用户可能仍想保留）
        if (f->state() == NetState::Finished) continue;
        freed += f->deleteLocalAndMeta();
    }
    AMCL_LOG_I(LOG_TAG, "deleteFilesOnDisk: freed=%{public}lld bytes", (long long)freed);
    return freed;
}

bool LoaderDownload::resetToWaiting() {
    // 仅 Aborted / Failed 可 reset
    LoadState cur = state_.load(std::memory_order_acquire);
    if (cur != LoadState::Aborted && cur != LoadState::Failed) {
        AMCL_LOG_W(LOG_TAG, "resetToWaiting rejected in state=%{public}d", (int)cur);
        return false;
    }
    if (!isExecutionSettled()) {
        AMCL_LOG_W(LOG_TAG, "resetToWaiting rejected: native execution still active");
        return false;
    }
    // 清 error、files_done_count_、files_failed_count_
    // H-5 修复：error_ 和 last_pushed_* 都由 mu_ 保护；统一在同一临界区清，
    // 避免与 tickProgress（同样需要 mu_ 读 last_pushed_*）发生撕裂读写。
    {
        std::lock_guard<std::mutex> lk(mu_);
        error_.reset();
        last_pushed_progress_ = -1.0;
        last_pushed_files_done_ = -1;
        last_pushed_speed_bps_ = -1;
        last_pushed_eta_seconds_ = -2;
        last_pushed_active_threads_ = -1;
        last_pushed_current_file_.clear();
        last_pushed_current_files_.clear();
        last_pushed_bytes_done_ = -1;
        last_pushed_bytes_total_ = -2;
        last_push_at_ms_ = 0;
    }
    int preserved_finished = 0;
    {
        std::lock_guard<std::mutex> lk(completion_mu_);
        completed_files_.clear();
        selected_retry_paths_.clear();
        selection_enabled_ = false;
        // resume/retry 不应重新启动已成功文件；它们在新 epoch 中仍是已收敛成功。
        for (const auto& f : files_) {
            if (f->state() == NetState::Finished) {
                completed_files_.insert(f.get());
                ++preserved_finished;
            }
        }
    }
    files_done_count_.store(preserved_finished, std::memory_order_release);
    files_failed_count_.store(0, std::memory_order_release);
    files_aborted_count_.store(0, std::memory_order_release);  // H-4 修复：retry/resume 时也清零
    abort_requested_.store(false, std::memory_order_release);
    infrastructure_failure_.store(false, std::memory_order_release);
    consecutive_meta_failures_.store(0, std::memory_order_release);
    finished_at_ms_.store(0, std::memory_order_release);

    // 注意：不清 started_at_ms_，durationMs 视为"续上的总时长"
    state_.store(LoadState::Waiting, std::memory_order_release);
    return true;
}

bool LoaderDownload::retryFailedFiles(const std::vector<std::string>& local_paths) {
    LoadState cur = state_.load(std::memory_order_acquire);
    if (cur != LoadState::Aborted && cur != LoadState::Failed) {
        AMCL_LOG_W(LOG_TAG, "retryFailedFiles rejected in state=%{public}d", (int)cur);
        return false;
    }

    std::unordered_set<std::string> requested(local_paths.begin(), local_paths.end());
    const bool retry_all = requested.empty();
    std::unordered_set<std::string> selected;
    for (const auto& f : files_) {
        NetState fs = f->state();
        if (fs != NetState::Failed && fs != NetState::Aborted) continue;
        if (retry_all || requested.count(f->localPath()) > 0) selected.insert(f->localPath());
    }
    if (selected.empty()) {
        AMCL_LOG_W(LOG_TAG, "retryFailedFiles: no retryable file selected");
        return false;
    }

    if (!resetToWaiting()) return false;

    int done_count = 0;
    int failed_count = 0;
    int aborted_count = 0;
    int retry_count = 0;
    {
        std::lock_guard<std::mutex> lk(completion_mu_);
        selected_retry_paths_ = selected;
        selection_enabled_ = true;
        for (auto& f : files_) {
            if (selected.count(f->localPath()) > 0) {
                f->resetForRetry();
                ++retry_count;
                continue;
            }
            NetState fs = f->state();
            if (isTerminalFileState(fs)) {
                completed_files_.insert(f.get());
                ++done_count;
                if (fs == NetState::Failed) ++failed_count;
                else if (fs == NetState::Aborted) ++aborted_count;
            }
        }
    }
    files_done_count_.store(done_count, std::memory_order_release);
    files_failed_count_.store(failed_count, std::memory_order_release);
    files_aborted_count_.store(aborted_count, std::memory_order_release);

    AMCL_LOG_I(LOG_TAG,
        "retryFailedFiles: task_id=%{public}lu settled=%{public}d selected=%{public}d epoch(next)=%{public}lu",
        (unsigned long)cfg_.task_id, done_count, retry_count,
        (unsigned long)(selection_epoch_.load(std::memory_order_acquire) + 1));
    return true;
}

void LoaderDownload::tickProgress() {
    // 直接 C++ 调用 tickProgress 也遵循同步 callback 的 shutdown 防重入合同。
    DownloadExecutionContext callback_context;
    ProgressChangedCb cb;
    {
        std::lock_guard<std::mutex> lk(mu_);
        cb = on_progress_changed_;
    }
    if (!cb) return;

    TaskProgress p = computeProgress();
    constexpr int64_t kMaxSilentMs = 1000;
    int64_t now = nowMs();
    {
        std::lock_guard<std::mutex> lk(mu_);
        bool progress_changed = last_pushed_progress_ < 0.0 ||
            std::fabs(p.overall_progress - last_pushed_progress_) >= 0.001;
        bool details_changed = p.files_done != last_pushed_files_done_ ||
            p.speed_bps != last_pushed_speed_bps_ ||
            p.eta_seconds != last_pushed_eta_seconds_ ||
            p.active_threads != last_pushed_active_threads_ ||
            p.current_file != last_pushed_current_file_ ||
            p.current_files != last_pushed_current_files_ ||
            p.bytes_done != last_pushed_bytes_done_ ||
            p.bytes_total != last_pushed_bytes_total_;
        bool silence_expired = last_push_at_ms_ == 0 || now - last_push_at_ms_ >= kMaxSilentMs;
        if (!progress_changed && !details_changed && !silence_expired) return;

        last_pushed_progress_ = p.overall_progress;
        last_pushed_files_done_ = p.files_done;
        last_pushed_speed_bps_ = p.speed_bps;
        last_pushed_eta_seconds_ = p.eta_seconds;
        last_pushed_active_threads_ = p.active_threads;
        last_pushed_current_file_ = p.current_file;
        last_pushed_current_files_ = p.current_files;
        last_pushed_bytes_done_ = p.bytes_done;
        last_pushed_bytes_total_ = p.bytes_total;
        last_push_at_ms_ = now;
    }
    cb(p);
}

} // namespace download
