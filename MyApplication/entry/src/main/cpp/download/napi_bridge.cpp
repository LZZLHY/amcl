/**
 * napi_bridge.cpp — Progress / Complete 事件桥接实现
 */
#include "napi_bridge.h"

#include <hilog/log.h>

#include <cstdio>
#include <cstring>

#include "../utils/amcl_log.h"

#undef LOG_TAG
#define LOG_TAG "DL_NAPI_BR"

namespace download {

namespace {

// ---------- 进度数据载荷（从 C++ 线程传给 JS 线程） ----------

std::atomic<uint64_t> g_bridge_generation{1};

struct ProgressSignal {
    NapiProgressBridgePtr bridge;
    uint64_t generation = 0;
};

struct ProgressPayload {
    uint64_t    task_id;
    uint64_t    generation;
    uint64_t    execution_epoch;
    double      overall_progress;
    int64_t     speed_bps;
    int         active_threads;
    std::string current_file;
    int         files_done;
    int         files_total;
    int64_t     bytes_done;
    int64_t     bytes_total;
    // v5 新增
    int64_t                   eta_seconds;
    std::vector<std::string>  current_files;
};

/** v5: 失败文件详情的 JS 友好副本（string 拷贝避免跨线程生命周期） */
struct FailedFilePayload {
    std::string               local_path;
    std::string               basename;
    // 错误字段（展开，避免引用 DownloadException 指针）
    bool                      has_error = false;
    std::string               err_kind;
    std::string               err_message;
    long                      err_http_status = 0;
    int                       err_native_code = 0;
    std::vector<std::string>  tried_urls;
};

struct CompletePayload {
    NapiCompleteBridgePtr   bridge;
    uint64_t                task_id;
    uint64_t                generation;
    uint64_t                execution_epoch;
    bool                    success;
    bool                    aborted = false;      // v5: 用户主动取消 vs 失败
    // 序列化 DownloadException 的快照（避免在 JS 线程访问可能已销毁的异常对象）
    std::string             error_message;
    std::string             error_kind;
    int                     native_code;
    long                    http_status;
    std::string             url_context;
    bool                    has_error;
    std::vector<std::string> error_tried_urls;    // v5: 顶层 error 的试过源
    // 最终进度快照（在 C++ 线程 computeProgress，JS 侧免除再次跨线程拉取）
    double                  final_overall_progress;
    int64_t                 final_speed_bps;
    std::string             final_current_file;
    int                     final_files_done;
    int                     final_files_total;
    int64_t                 final_bytes_done;
    int64_t                 final_bytes_total;
    int64_t                 final_eta_seconds = -1;              // v5
    std::vector<std::string> final_current_files;                 // v5
    // v5: 失败文件列表 + 任务耗时
    std::vector<FailedFilePayload> failed_files;
    int64_t                        duration_ms = 0;
};

/** v5: 工具 — 取最后一个 / 或 \ 之后的部分 */
std::string basenameOf(const std::string& path) {
    if (path.empty()) return {};
    auto pos = path.find_last_of("/\\");
    if (pos == std::string::npos) return path;
    return path.substr(pos + 1);
}

// 工具：设置 JS object 的 string/number/int 属性

void setStringProp(napi_env env, napi_value obj, const char* key, const std::string& v) {
    napi_value s;
    napi_create_string_utf8(env, v.c_str(), v.size(), &s);
    napi_set_named_property(env, obj, key, s);
}
void setDoubleProp(napi_env env, napi_value obj, const char* key, double v) {
    napi_value n;
    napi_create_double(env, v, &n);
    napi_set_named_property(env, obj, key, n);
}
void setInt64Prop(napi_env env, napi_value obj, const char* key, int64_t v) {
    napi_value n;
    napi_create_int64(env, v, &n);
    napi_set_named_property(env, obj, key, n);
}
void setInt32Prop(napi_env env, napi_value obj, const char* key, int32_t v) {
    napi_value n;
    napi_create_int32(env, v, &n);
    napi_set_named_property(env, obj, key, n);
}
void setBoolProp(napi_env env, napi_value obj, const char* key, bool v) {
    napi_value b;
    napi_get_boolean(env, v, &b);
    napi_set_named_property(env, obj, key, b);
}

} // namespace

// ============================================================================
// NapiProgressBridge
// ============================================================================

NapiProgressBridgePtr NapiProgressBridge::Create(
        napi_env env, napi_value js_callback, uint64_t task_id) {
    const uint64_t generation = g_bridge_generation.fetch_add(1, std::memory_order_relaxed);
    auto bridge = NapiProgressBridgePtr(
        new NapiProgressBridge(env, js_callback, task_id, generation));
    return bridge->valid() ? bridge : nullptr;
}

NapiProgressBridge::NapiProgressBridge(napi_env env, napi_value js_callback,
                                       uint64_t task_id, uint64_t generation)
    : task_id_(task_id), generation_(generation) {
    napi_value name_val = nullptr;
    napi_status st = napi_create_string_utf8(
        env, "DownloadProgress", NAPI_AUTO_LENGTH, &name_val);
    if (st == napi_ok) {
        st = napi_create_threadsafe_function(
            env, js_callback, nullptr, name_val,
            1, // queue 中最多一个 signal；payload 在 latest-value mailbox 中合并
            1, nullptr, nullptr, nullptr,
            &NapiProgressBridge::callJs, &tsfn_);
    }
    if (st != napi_ok) {
        active_.store(false, std::memory_order_release);
        tsfn_ = nullptr;
        AMCL_LOG_E(LOG_TAG,
            "NapiProgressBridge: create failed status=%{public}d", static_cast<int>(st));
    }
}

NapiProgressBridge::~NapiProgressBridge() {
    close();
}

bool NapiProgressBridge::valid() const {
    std::lock_guard<std::mutex> lk(tsfn_mu_);
    return active_.load(std::memory_order_acquire) && tsfn_ != nullptr;
}

void NapiProgressBridge::bindGenerationGuard(
        std::shared_ptr<std::atomic<uint64_t>> guard) {
    std::lock_guard<std::mutex> lk(tsfn_mu_);
    generation_guard_ = std::move(guard);
}

bool NapiProgressBridge::isCurrentGeneration() const {
    std::shared_ptr<std::atomic<uint64_t>> guard;
    {
        std::lock_guard<std::mutex> lk(tsfn_mu_);
        guard = generation_guard_;
    }
    return guard && guard->load(std::memory_order_acquire) == generation_;
}

void NapiProgressBridge::close() {
    active_.store(false, std::memory_order_release);
    {
        std::lock_guard<std::mutex> lk(progress_mu_);
        has_latest_ = false;
        signal_pending_ = false;
    }
    std::lock_guard<std::mutex> lk(tsfn_mu_);
    if (tsfn_) {
        napi_release_threadsafe_function(tsfn_, napi_tsfn_abort);
        tsfn_ = nullptr;
    }
}

void NapiProgressBridge::push(const TaskProgress& progress) {
    if (!active_.load(std::memory_order_acquire) || !isCurrentGeneration()) return;
    {
        std::lock_guard<std::mutex> lk(progress_mu_);
        if (!active_.load(std::memory_order_relaxed) || progress.execution_epoch == 0 ||
            progress.execution_epoch < highest_progress_epoch_) {
            return;
        }
        if (progress.execution_epoch > highest_progress_epoch_) {
            highest_progress_epoch_ = progress.execution_epoch;
        }
        latest_progress_ = progress; // 同 epoch 合并；新 epoch 可覆盖，旧 epoch 永不反向覆盖
        has_latest_ = true;
        if (signal_pending_) return;
        signal_pending_ = true;
    }

    auto* signal = new ProgressSignal{shared_from_this(), generation_};
    napi_status st = napi_closing;
    {
        std::lock_guard<std::mutex> lk(tsfn_mu_);
        if (active_.load(std::memory_order_acquire) && tsfn_) {
            st = napi_call_threadsafe_function(tsfn_, signal, napi_tsfn_nonblocking);
        }
    }
    if (st != napi_ok) {
        {
            std::lock_guard<std::mutex> lk(progress_mu_);
            signal_pending_ = false;
        }
        delete signal;
        AMCL_LOG_D(LOG_TAG,
            "NapiProgressBridge: signal not queued status=%{public}d", static_cast<int>(st));
    }
}

void NapiProgressBridge::callJs(napi_env env, napi_value js_callback,
                                void* /*context*/, void* data) {
    std::unique_ptr<ProgressSignal> signal(static_cast<ProgressSignal*>(data));
    if (!signal || !signal->bridge) return;

    auto bridge = signal->bridge;
    TaskProgress progress;
    bool deliver = false;
    {
        std::lock_guard<std::mutex> lk(bridge->progress_mu_);
        bridge->signal_pending_ = false;
        if (bridge->active_.load(std::memory_order_acquire) &&
            bridge->isCurrentGeneration() &&
            signal->generation == bridge->generation_ && bridge->has_latest_) {
            progress = bridge->latest_progress_;
            bridge->has_latest_ = false;
            deliver = true;
        }
    }
    if (!deliver || !env || !js_callback) return;

    auto* payload = new ProgressPayload{
        bridge->task_id_, bridge->generation_, progress.execution_epoch,
        progress.overall_progress, progress.speed_bps, progress.active_threads,
        progress.current_file, progress.files_done, progress.files_total,
        progress.bytes_done, progress.bytes_total, progress.eta_seconds,
        progress.current_files,
    };

    napi_value js_progress;
    napi_create_object(env, &js_progress);

    setInt64Prop (env, js_progress, "taskId",          static_cast<int64_t>(payload->task_id));
    setInt64Prop (env, js_progress, "registrationGeneration",
                  static_cast<int64_t>(payload->generation));
    setInt64Prop (env, js_progress, "executionEpoch",
                  static_cast<int64_t>(payload->execution_epoch));
    setDoubleProp(env, js_progress, "overallProgress", payload->overall_progress);
    setInt64Prop (env, js_progress, "speedBps",        payload->speed_bps);
    setInt32Prop (env, js_progress, "activeThreads",   payload->active_threads);
    setStringProp(env, js_progress, "currentFile",     payload->current_file);
    setInt32Prop (env, js_progress, "filesDone",       payload->files_done);
    setInt32Prop (env, js_progress, "filesTotal",      payload->files_total);
    setInt64Prop (env, js_progress, "bytesDone",       payload->bytes_done);
    setInt64Prop (env, js_progress, "bytesTotal",      payload->bytes_total);
    // v5
    setInt64Prop (env, js_progress, "etaSeconds",      payload->eta_seconds);
    {
        napi_value arr;
        napi_create_array_with_length(env, payload->current_files.size(), &arr);
        for (size_t i = 0; i < payload->current_files.size(); ++i) {
            napi_value s;
            napi_create_string_utf8(env, payload->current_files[i].c_str(),
                                    payload->current_files[i].size(), &s);
            napi_set_element(env, arr, static_cast<uint32_t>(i), s);
        }
        napi_set_named_property(env, js_progress, "currentFiles", arr);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_value result;
    napi_status rc = napi_call_function(env, undefined, js_callback, 1, &js_progress, &result);
    if (rc != napi_ok) {
        AMCL_LOG_W(LOG_TAG, "NapiProgressBridge: call_function failed: %{public}d", (int)rc);
    }

    delete payload;
}

// ============================================================================
// NapiCompleteBridge
// ============================================================================

NapiCompleteBridgePtr NapiCompleteBridge::Create(
        napi_env env, napi_value js_callback, uint64_t task_id) {
    const uint64_t generation = g_bridge_generation.fetch_add(1, std::memory_order_relaxed);
    auto bridge = NapiCompleteBridgePtr(
        new NapiCompleteBridge(env, js_callback, task_id, generation));
    return bridge->valid() ? bridge : nullptr;
}

NapiCompleteBridge::NapiCompleteBridge(napi_env env, napi_value js_callback,
                                       uint64_t task_id, uint64_t generation)
    : task_id_(task_id), generation_(generation) {
    napi_value name_val = nullptr;
    napi_status st = napi_create_string_utf8(
        env, "DownloadComplete", NAPI_AUTO_LENGTH, &name_val);
    if (st == napi_ok) {
        // Complete 独占 TSFN，每个 registration exactly-once，队列容量 1 即足够。
        // blocking 保证 env 可用时可靠入队；env closing 则由 query API 恢复终态。
        st = napi_create_threadsafe_function(
            env, js_callback, nullptr, name_val, 1, 1,
            nullptr, nullptr, nullptr,
            &NapiCompleteBridge::callJs, &tsfn_);
    }
    if (st != napi_ok) {
        active_.store(false, std::memory_order_release);
        tsfn_ = nullptr;
        AMCL_LOG_E(LOG_TAG,
            "NapiCompleteBridge: create failed status=%{public}d", static_cast<int>(st));
    }
}

NapiCompleteBridge::~NapiCompleteBridge() {
    close();
}

bool NapiCompleteBridge::valid() const {
    std::lock_guard<std::mutex> lk(tsfn_mu_);
    return active_.load(std::memory_order_acquire) && tsfn_ != nullptr;
}

void NapiCompleteBridge::bindGenerationGuard(
        std::shared_ptr<std::atomic<uint64_t>> guard) {
    std::lock_guard<std::mutex> lk(tsfn_mu_);
    generation_guard_ = std::move(guard);
}

bool NapiCompleteBridge::isCurrentGeneration() const {
    std::shared_ptr<std::atomic<uint64_t>> guard;
    {
        std::lock_guard<std::mutex> lk(tsfn_mu_);
        guard = generation_guard_;
    }
    return guard && guard->load(std::memory_order_acquire) == generation_;
}

void NapiCompleteBridge::close() {
    active_.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lk(tsfn_mu_);
    if (tsfn_) {
        napi_release_threadsafe_function(tsfn_, napi_tsfn_abort);
        tsfn_ = nullptr;
    }
}

bool NapiCompleteBridge::push(bool success, bool aborted, DownloadExceptionPtr err,
                              const TaskProgress& final_progress,
                              std::vector<FailedFileInfo> failed_files,
                              int64_t duration_ms) {
    if (!active_.load(std::memory_order_acquire) || !isCurrentGeneration()) {
        return false;
    }
    const uint64_t execution_epoch = final_progress.execution_epoch;
    if (execution_epoch == 0) return false;

    // 串行化 claim 到 TSFN 入队的整个事务。highest_observed_epoch_ 单调前进，
    // 因此即使新 epoch 入队失败，随后到达的旧终态也不能覆盖它；同一 epoch
    // 只有在 queued_completion_epoch_ 已确认后才可作为重复成功返回。
    std::unique_lock<std::mutex> completion_lk(completion_mu_);
    if (execution_epoch < highest_observed_epoch_) return false;
    if (execution_epoch == queued_completion_epoch_) return true;
    if (execution_epoch > highest_observed_epoch_) {
        highest_observed_epoch_ = execution_epoch;
    }
    if (!active_.load(std::memory_order_acquire) || !isCurrentGeneration()) {
        return false;
    }

    auto* payload = new CompletePayload{};
    payload->bridge = shared_from_this();
    payload->task_id = task_id_;
    payload->generation = generation_;
    payload->execution_epoch = execution_epoch;
    payload->success = success;
    payload->aborted = aborted;
    payload->has_error = static_cast<bool>(err);
    if (err) {
        payload->error_kind   = errorKindToString(err->kind);
        payload->error_message= err->message;
        payload->native_code  = err->native_code;
        payload->http_status  = err->http_status;
        payload->url_context  = err->url_context;
        payload->error_tried_urls = err->tried_urls;
    }
    payload->final_overall_progress = final_progress.overall_progress;
    payload->final_speed_bps        = final_progress.speed_bps;
    payload->final_current_file     = final_progress.current_file;
    payload->final_files_done       = final_progress.files_done;
    payload->final_files_total      = final_progress.files_total;
    payload->final_bytes_done       = final_progress.bytes_done;
    payload->final_bytes_total      = final_progress.bytes_total;
    payload->final_eta_seconds      = final_progress.eta_seconds;
    payload->final_current_files    = final_progress.current_files;
    payload->duration_ms            = duration_ms;

    // v5: 把 FailedFileInfo 转成线程安全的 POD Payload（不跨线程传 shared_ptr<DownloadException>）
    payload->failed_files.reserve(failed_files.size());
    for (auto& ff : failed_files) {
        FailedFilePayload fp;
        fp.local_path = ff.local_path;
        fp.basename = basenameOf(ff.local_path);
        fp.tried_urls = std::move(ff.tried_urls);
        if (ff.last_error) {
            fp.has_error = true;
            fp.err_kind = errorKindToString(ff.last_error->kind);
            fp.err_message = ff.last_error->message;
            fp.err_http_status = ff.last_error->http_status;
            fp.err_native_code = ff.last_error->native_code;
        }
        payload->failed_files.push_back(std::move(fp));
    }

    napi_status st = napi_closing;
    napi_threadsafe_function acquired_tsfn = nullptr;
    {
        std::lock_guard<std::mutex> lk(tsfn_mu_);
        if (active_.load(std::memory_order_acquire) && tsfn_ &&
            napi_acquire_threadsafe_function(tsfn_) == napi_ok) {
            acquired_tsfn = tsfn_;
        }
    }
    if (acquired_tsfn) {
        // 不持有 tsfn_mu_ 进行 blocking 投递：close/env cleanup 可并发 abort，
        // 临时 thread-count 引用保证调用期间句柄仍有效，避免互等死锁。
        st = napi_call_threadsafe_function(
            acquired_tsfn, payload, napi_tsfn_blocking);
        napi_release_threadsafe_function(acquired_tsfn, napi_tsfn_release);
    }
    if (st != napi_ok) {
        delete payload;
        // 没有成功入队：保留 highest_observed_epoch_ 防止旧轮次倒灌，但不写
        // queued_completion_epoch_，因此同一 execution epoch 可以安全重试。
        AMCL_LOG_E(LOG_TAG,
            "NapiCompleteBridge: terminal event not queued status=%{public}d; "
            "recover with downloadQueryTask(%{public}llu)",
            static_cast<int>(st), static_cast<unsigned long long>(task_id_));
        return false;
    }
    queued_completion_epoch_ = execution_epoch;
    return true;
}

void NapiCompleteBridge::callJs(napi_env env, napi_value js_callback,
                                void* /*context*/, void* data) {
    auto* payload = static_cast<CompletePayload*>(data);
    if (!payload) return;
    if (!env || !js_callback || !payload->bridge ||
        !payload->bridge->valid() ||
        !payload->bridge->isCurrentGeneration() ||
        payload->generation != payload->bridge->generation()) {
        delete payload;
        return;
    }

    napi_value js_result;
    napi_create_object(env, &js_result);
    setInt64Prop(env, js_result, "taskId",     static_cast<int64_t>(payload->task_id));
    setInt64Prop(env, js_result, "registrationGeneration",
                 static_cast<int64_t>(payload->generation));
    setInt64Prop(env, js_result, "executionEpoch",
                 static_cast<int64_t>(payload->execution_epoch));
    setBoolProp (env, js_result, "success",    payload->success);
    setBoolProp (env, js_result, "aborted",    payload->aborted);       // v5
    setInt64Prop(env, js_result, "durationMs", payload->duration_ms);   // v5

    if (payload->has_error) {
        napi_value js_error;
        napi_create_object(env, &js_error);
        setStringProp(env, js_error, "kind",       payload->error_kind);
        setStringProp(env, js_error, "message",    payload->error_message);
        setInt32Prop (env, js_error, "nativeCode", payload->native_code);
        setInt64Prop (env, js_error, "httpStatus", payload->http_status);
        setStringProp(env, js_error, "url",        payload->url_context);
        // v5: 试过的源列表
        napi_value urls;
        napi_create_array_with_length(env, payload->error_tried_urls.size(), &urls);
        for (size_t i = 0; i < payload->error_tried_urls.size(); ++i) {
            napi_value s;
            napi_create_string_utf8(env, payload->error_tried_urls[i].c_str(),
                                    payload->error_tried_urls[i].size(), &s);
            napi_set_element(env, urls, static_cast<uint32_t>(i), s);
        }
        napi_set_named_property(env, js_error, "triedUrls", urls);
        napi_set_named_property(env, js_result, "error", js_error);
    }

    // v5: 失败文件列表（供 UI "3 个文件失败 ⚠️ xxx.jar (SSL错误)" 的详情展示）
    {
        napi_value js_failed;
        napi_create_array_with_length(env, payload->failed_files.size(), &js_failed);
        for (size_t i = 0; i < payload->failed_files.size(); ++i) {
            const auto& ff = payload->failed_files[i];
            napi_value obj;
            napi_create_object(env, &obj);
            setStringProp(env, obj, "localPath", ff.local_path);
            setStringProp(env, obj, "basename",  ff.basename);
            if (ff.has_error) {
                napi_value err;
                napi_create_object(env, &err);
                setStringProp(env, err, "kind",       ff.err_kind);
                setStringProp(env, err, "message",    ff.err_message);
                setInt64Prop (env, err, "httpStatus", ff.err_http_status);
                setInt32Prop (env, err, "nativeCode", ff.err_native_code);
                napi_set_named_property(env, obj, "lastError", err);
            }
            napi_value urls;
            napi_create_array_with_length(env, ff.tried_urls.size(), &urls);
            for (size_t j = 0; j < ff.tried_urls.size(); ++j) {
                napi_value s;
                napi_create_string_utf8(env, ff.tried_urls[j].c_str(),
                                        ff.tried_urls[j].size(), &s);
                napi_set_element(env, urls, static_cast<uint32_t>(j), s);
            }
            napi_set_named_property(env, obj, "triedUrls", urls);
            napi_set_element(env, js_failed, static_cast<uint32_t>(i), obj);
        }
        napi_set_named_property(env, js_result, "failedFiles", js_failed);
    }

    // 终态时一并送回最终进度快照，UI 在 onComplete 里直接拿到完整数据，
    // 无需依赖 onProgress 事件是否已经到达（小文件秒下时可能来不及触发）。
    napi_value js_final;
    napi_create_object(env, &js_final);
    setDoubleProp(env, js_final, "overallProgress", payload->final_overall_progress);
    setInt64Prop (env, js_final, "speedBps",        payload->final_speed_bps);
    setStringProp(env, js_final, "currentFile",     payload->final_current_file);
    setInt32Prop (env, js_final, "filesDone",       payload->final_files_done);
    setInt32Prop (env, js_final, "filesTotal",      payload->final_files_total);
    setInt64Prop (env, js_final, "bytesDone",       payload->final_bytes_done);
    setInt64Prop (env, js_final, "bytesTotal",      payload->final_bytes_total);
    setInt64Prop (env, js_final, "etaSeconds",      payload->final_eta_seconds);  // v5
    {
        napi_value arr;
        napi_create_array_with_length(env, payload->final_current_files.size(), &arr);
        for (size_t i = 0; i < payload->final_current_files.size(); ++i) {
            napi_value s;
            napi_create_string_utf8(env, payload->final_current_files[i].c_str(),
                                    payload->final_current_files[i].size(), &s);
            napi_set_element(env, arr, static_cast<uint32_t>(i), s);
        }
        napi_set_named_property(env, js_final, "currentFiles", arr);
    }
    napi_set_named_property(env, js_result, "finalProgress", js_final);

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_value result;
    napi_status rc = napi_call_function(env, undefined, js_callback, 1, &js_result, &result);
    if (rc != napi_ok) {
        AMCL_LOG_W(LOG_TAG, "NapiCompleteBridge: call_function failed: %{public}d", (int)rc);
    }

    delete payload;
}

} // namespace download
