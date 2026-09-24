/**
 * download_napi.cpp — NAPI 方法实现
 *
 * 职责：解析 napi_value → LoaderDownload::Config → 调 DownloadEngine。
 * 事件回调通过 NapiProgressBridge / NapiCompleteBridge 桥接（见 napi_bridge.h）。
 */
#include "download_napi.h"

#include <hilog/log.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "config.h"
#include "engine.h"
#include "file_checker.h"
#include "loader_download.h"
#include "napi_bridge.h"
#include "net_file.h"
#include "relay.h"

#include "../utils/amcl_log.h"

#undef LOG_TAG
#define LOG_TAG "DL_NAPI"

namespace download {

namespace {

// ============================================================================
// napi_value 读取工具
// ============================================================================

constexpr size_t kMaxTaskNameBytes = 256;
constexpr size_t kMaxPathBytes = 4096;
constexpr size_t kMaxUrlBytes = 8192;
constexpr size_t kMaxHeaderNameBytes = 256;
constexpr size_t kMaxHeaderValueBytes = 8192;
constexpr uint32_t kMaxTaskFiles = 16384;
constexpr uint32_t kMaxUrlsPerFile = 16;
constexpr uint32_t kMaxFetchMirrors = 16;
constexpr uint32_t kMaxRequestHeaders = 64;
constexpr int32_t kMinFetchTimeoutSeconds = 1;
constexpr int32_t kMaxFetchTimeoutSeconds = 300;
constexpr size_t kDefaultMaxFetchResponseBytes = 16U * 1024U * 1024U;
constexpr size_t kMaxFetchResponseBytes = 16U * 1024U * 1024U;
constexpr int64_t kMaxSafeJsInteger = 9007199254740991LL;

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif

bool hasNamedProp(napi_env env, napi_value obj, const char* key) {
    bool has = false;
    return napi_has_named_property(env, obj, key, &has) == napi_ok && has;
}

bool readBoundedString(napi_env env, napi_value value, size_t max_len,
                       std::string& out, bool allow_empty = true) {
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) return false;
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok ||
        len > max_len || (!allow_empty && len == 0)) {
        return false;
    }
    std::vector<char> buf(len + 1, 0);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, buf.data(), buf.size(), &copied) != napi_ok ||
        copied != len) {
        return false;
    }
    out.assign(buf.data(), copied);
    return out.find('\0') == std::string::npos;
}

bool readStringProp(napi_env env, napi_value obj, const char* key,
                    std::string& out, size_t max_len, bool allow_empty = true) {
    napi_value value = nullptr;
    return napi_get_named_property(env, obj, key, &value) == napi_ok &&
           readBoundedString(env, value, max_len, out, allow_empty);
}

bool readNumberProp(napi_env env, napi_value obj, const char* key, double& out) {
    napi_value value = nullptr;
    napi_valuetype type = napi_undefined;
    return napi_get_named_property(env, obj, key, &value) == napi_ok &&
           napi_typeof(env, value, &type) == napi_ok && type == napi_number &&
           napi_get_value_double(env, value, &out) == napi_ok && std::isfinite(out);
}

bool readStringArrayProp(napi_env env, napi_value obj, const char* key,
                         uint32_t max_count, size_t max_string_len,
                         std::vector<std::string>& out) {
    napi_value arr = nullptr;
    if (napi_get_named_property(env, obj, key, &arr) != napi_ok) return false;
    bool is_array = false;
    if (napi_is_array(env, arr, &is_array) != napi_ok || !is_array) return false;
    uint32_t len = 0;
    if (napi_get_array_length(env, arr, &len) != napi_ok || len > max_count) return false;
    out.clear();
    out.reserve(len);
    for (uint32_t i = 0; i < len; ++i) {
        napi_value item = nullptr;
        std::string value;
        if (napi_get_element(env, arr, i, &item) != napi_ok ||
            !readBoundedString(env, item, max_string_len, value, false)) {
            return false;
        }
        out.push_back(std::move(value));
    }
    return true;
}

bool containsControlChar(const std::string& value) {
    return std::any_of(value.begin(), value.end(), [](unsigned char c) {
        return c < 0x20 || c == 0x7f;
    });
}

bool isHttpUrl(const std::string& url) {
    if (url.empty() || url.size() > kMaxUrlBytes || containsControlChar(url)) return false;
    std::string prefix = url.substr(0, std::min<size_t>(8, url.size()));
    std::transform(prefix.begin(), prefix.end(), prefix.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    size_t authority = std::string::npos;
    if (prefix.rfind("http://", 0) == 0) authority = 7;
    if (prefix.rfind("https://", 0) == 0) authority = 8;
    if (authority == std::string::npos || authority >= url.size()) return false;
    size_t authority_end = url.find_first_of("/?#", authority);
    return authority_end == std::string::npos ? authority < url.size()
                                               : authority_end > authority;
}

bool isSha1(const std::string& value) {
    return value.size() == 40 &&
           std::all_of(value.begin(), value.end(), [](unsigned char c) {
               return (c >= '0' && c <= '9') ||
                      (c >= 'a' && c <= 'f') ||
                      (c >= 'A' && c <= 'F');
           });
}

bool isValidHeaderName(const std::string& value) {
    if (value.empty() || value.size() > kMaxHeaderNameBytes) return false;
    return std::all_of(value.begin(), value.end(), [](unsigned char c) {
        // RFC 7230 token: visible ASCII excluding separators.
        if (c <= 0x20 || c >= 0x7f) return false;
        switch (c) {
            case '(': case ')': case '<': case '>': case '@': case ',':
            case ';': case ':': case '\\': case '"': case '/': case '[':
            case ']': case '?': case '=': case '{': case '}':
                return false;
            default:
                return true;
        }
    });
}

bool normalizeContainedPath(const std::string& local_path,
                            const std::string& allowed_root,
                            std::string& normalized_path,
                            std::string& normalized_root) {
    namespace fs = std::filesystem;
    if (local_path.empty() || allowed_root.empty() ||
        local_path.size() > kMaxPathBytes || allowed_root.size() > kMaxPathBytes ||
        containsControlChar(local_path) || containsControlChar(allowed_root)) {
        return false;
    }
    fs::path path(local_path);
    fs::path root(allowed_root);
    if (!path.is_absolute() || !root.is_absolute()) return false;

    std::error_code ec;
    root = fs::weakly_canonical(root, ec);
    if (ec || root.empty()) return false;
    path = fs::weakly_canonical(path, ec);
    if (ec || path.empty() || path == root) return false;

    auto root_it = root.begin();
    auto path_it = path.begin();
    for (; root_it != root.end(); ++root_it, ++path_it) {
        if (path_it == path.end() || *root_it != *path_it) return false;
    }
    normalized_path = path.string();
    normalized_root = root.string();
    return normalized_path.size() <= kMaxPathBytes && normalized_root.size() <= kMaxPathBytes;
}

/** 从 JS 参数取正的安全整数 taskId。 */
bool readTaskIdArg(napi_env env, napi_callback_info info, size_t expected_argc,
                   uint64_t& task_id, std::vector<napi_value>& argv) {
    size_t argc = expected_argc;
    argv.assign(expected_argc, nullptr);
    if (napi_get_cb_info(env, info, &argc, argv.data(), nullptr, nullptr) != napi_ok || argc < 1) {
        return false;
    }
    double value = 0;
    if (napi_get_value_double(env, argv[0], &value) != napi_ok || !std::isfinite(value) ||
        std::floor(value) != value || value <= 0 || value > kMaxSafeJsInteger) {
        return false;
    }
    task_id = static_cast<uint64_t>(value);
    return true;
}

// ============================================================================
// spec → LoaderDownload::Config 解析
// ============================================================================

bool parseFileConfig(napi_env env, napi_value js_file, NetFile::Config& out,
                     std::string& normalized_key, std::string& err) {
    napi_valuetype file_type = napi_undefined;
    if (napi_typeof(env, js_file, &file_type) != napi_ok || file_type != napi_object) {
        err = "file must be an object";
        return false;
    }

    std::string local_path;
    if (!readStringProp(env, js_file, "localPath", local_path, kMaxPathBytes, false)) {
        err = "file.localPath missing, empty, or too long";
        return false;
    }

    std::string allowed_root;
    if (!hasNamedProp(env, js_file, "allowedRoot") ||
        !readStringProp(env, js_file, "allowedRoot", allowed_root,
                        kMaxPathBytes, false)) {
        err = "file.allowedRoot is required and must be a non-empty bounded string";
        return false;
    }

    if (!normalizeContainedPath(local_path, allowed_root,
                                out.local_path, out.allowed_root)) {
        err = "file.localPath must be an absolute path strictly inside allowedRoot";
        return false;
    }
    normalized_key = out.local_path;

    std::vector<std::string> urls;
    if (!readStringArrayProp(env, js_file, "urls", kMaxUrlsPerFile,
                             kMaxUrlBytes, urls) || urls.empty()) {
        err = "file.urls must contain 1..16 bounded strings";
        return false;
    }
    for (const auto& url : urls) {
        if (!isHttpUrl(url)) {
            err = "file.urls only accepts valid http/https URLs";
            return false;
        }
    }
    out.urls = std::move(urls);

    if (hasNamedProp(env, js_file, "check")) {
        napi_value js_check = nullptr;
        napi_valuetype check_type = napi_undefined;
        if (napi_get_named_property(env, js_file, "check", &js_check) != napi_ok ||
            napi_typeof(env, js_check, &check_type) != napi_ok ||
            check_type != napi_object) {
            err = "file.check must be an object";
            return false;
        }
        if (hasNamedProp(env, js_check, "sha1")) {
            std::string sha1;
            if (!readStringProp(env, js_check, "sha1", sha1, 40, false) || !isSha1(sha1)) {
                err = "file.check.sha1 must be exactly 40 hexadecimal characters";
                return false;
            }
            std::transform(sha1.begin(), sha1.end(), sha1.begin(),
                           [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
            out.check.expected_sha1 = std::move(sha1);
        }
        if (hasNamedProp(env, js_check, "size")) {
            double size = 0;
            if (!readNumberProp(env, js_check, "size", size) || std::floor(size) != size ||
                size < -1 || size > static_cast<double>(kMaxDownloadFileBytes)) {
                err = "file.check.size must be an integer in [-1, 1 TiB]";
                return false;
            }
            out.check.expected_size = static_cast<int64_t>(size);
        }
    }

    if (hasNamedProp(env, js_file, "maxConnections")) {
        double max_conn = 0;
        if (!readNumberProp(env, js_file, "maxConnections", max_conn) ||
            std::floor(max_conn) != max_conn || max_conn < 1 || max_conn > 16) {
            err = "file.maxConnections must be an integer in [1, 16]";
            return false;
        }
        out.max_connections = static_cast<int>(max_conn); // checked range before cast
    }

    return true;
}

bool parseTaskConfig(napi_env env, napi_value js_spec, LoaderDownload::Config& out,
                     std::string& err) {
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, js_spec, &type) != napi_ok || type != napi_object) {
        err = "spec must be an object";
        return false;
    }

    if (hasNamedProp(env, js_spec, "name")) {
        if (!readStringProp(env, js_spec, "name", out.name,
                            kMaxTaskNameBytes, false) || containsControlChar(out.name)) {
            err = "spec.name must be a non-empty control-free string up to 256 bytes";
            return false;
        }
    } else {
        out.name = "DownloadTask";
    }

    napi_value js_files = nullptr;
    if (napi_get_named_property(env, js_spec, "files", &js_files) != napi_ok) {
        err = "spec.files missing";
        return false;
    }
    bool is_array = false;
    uint32_t file_count = 0;
    if (napi_is_array(env, js_files, &is_array) != napi_ok || !is_array ||
        napi_get_array_length(env, js_files, &file_count) != napi_ok ||
        file_count == 0 || file_count > kMaxTaskFiles) {
        err = "spec.files must contain 1..16384 files";
        return false;
    }

    std::unordered_set<std::string> normalized_paths;
    out.files.reserve(file_count);
    normalized_paths.reserve(file_count);
    for (uint32_t i = 0; i < file_count; ++i) {
        napi_value js_file = nullptr;
        if (napi_get_element(env, js_files, i, &js_file) != napi_ok) {
            err = "spec.files[" + std::to_string(i) + "]: unreadable item";
            return false;
        }
        NetFile::Config file_config;
        std::string normalized_key;
        std::string item_err;
        if (!parseFileConfig(env, js_file, file_config, normalized_key, item_err)) {
            err = "spec.files[" + std::to_string(i) + "]: " + item_err;
            return false;
        }
        if (!normalized_paths.insert(normalized_key).second) {
            err = "spec.files[" + std::to_string(i) + "]: duplicate normalized localPath";
            return false;
        }
        out.files.push_back(std::move(file_config));
    }

    return true;
}

napi_value throwErrorAndReturnNull(napi_env env, const std::string& msg) {
    napi_throw_type_error(env, nullptr, msg.c_str());
    napi_value null_val;
    napi_get_null(env, &null_val);
    return null_val;
}

void setStringProp(napi_env env, napi_value obj, const char* key, const std::string& value) {
    napi_value js_value = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &js_value);
    napi_set_named_property(env, obj, key, js_value);
}

void setInt64Prop(napi_env env, napi_value obj, const char* key, int64_t value) {
    napi_value js_value = nullptr;
    napi_create_int64(env, value, &js_value);
    napi_set_named_property(env, obj, key, js_value);
}

void setInt32Prop(napi_env env, napi_value obj, const char* key, int32_t value) {
    napi_value js_value = nullptr;
    napi_create_int32(env, value, &js_value);
    napi_set_named_property(env, obj, key, js_value);
}

void setDoubleProp(napi_env env, napi_value obj, const char* key, double value) {
    napi_value js_value = nullptr;
    napi_create_double(env, value, &js_value);
    napi_set_named_property(env, obj, key, js_value);
}

void setBoolProp(napi_env env, napi_value obj, const char* key, bool value) {
    napi_value js_value = nullptr;
    napi_get_boolean(env, value, &js_value);
    napi_set_named_property(env, obj, key, js_value);
}

napi_value createStringArray(napi_env env, const std::vector<std::string>& values) {
    napi_value array = nullptr;
    napi_create_array_with_length(env, values.size(), &array);
    for (size_t i = 0; i < values.size(); ++i) {
        napi_value value = nullptr;
        napi_create_string_utf8(env, values[i].c_str(), values[i].size(), &value);
        napi_set_element(env, array, static_cast<uint32_t>(i), value);
    }
    return array;
}

napi_value createErrorSnapshot(napi_env env, const DownloadExceptionPtr& error) {
    napi_value object = nullptr;
    if (!error) {
        napi_get_null(env, &object);
        return object;
    }
    napi_create_object(env, &object);
    setStringProp(env, object, "kind", errorKindToString(error->kind));
    setStringProp(env, object, "message", error->message);
    setInt32Prop(env, object, "nativeCode", error->native_code);
    setInt64Prop(env, object, "httpStatus", error->http_status);
    setStringProp(env, object, "url", error->url_context);
    napi_set_named_property(env, object, "triedUrls",
                            createStringArray(env, error->tried_urls));
    return object;
}

napi_value createFailedFilesSnapshot(napi_env env,
                                     const std::vector<FailedFileInfo>& failed_files) {
    napi_value array = nullptr;
    napi_create_array_with_length(env, failed_files.size(), &array);
    for (size_t i = 0; i < failed_files.size(); ++i) {
        const auto& failed = failed_files[i];
        napi_value object = nullptr;
        napi_create_object(env, &object);
        setStringProp(env, object, "localPath", failed.local_path);
        const size_t slash = failed.local_path.find_last_of("/\\");
        setStringProp(env, object, "basename",
                      slash == std::string::npos ? failed.local_path
                                                 : failed.local_path.substr(slash + 1));
        if (failed.last_error) {
            napi_set_named_property(env, object, "lastError",
                                    createErrorSnapshot(env, failed.last_error));
        }
        napi_set_named_property(env, object, "triedUrls",
                                createStringArray(env, failed.tried_urls));
        napi_set_element(env, array, static_cast<uint32_t>(i), object);
    }
    return array;
}

bool isTerminalState(LoadState state) {
    return state == LoadState::Finished || state == LoadState::Failed ||
           state == LoadState::Aborted;
}

napi_value createTaskSnapshot(napi_env env, const LoaderDownloadPtr& task) {
    napi_value object = nullptr;
    napi_create_object(env, &object);
    const TaskProgress progress = task->computeProgress();
    const LoadState state = task->state();

    setInt64Prop(env, object, "taskId", static_cast<int64_t>(task->taskId()));
    setInt64Prop(env, object, "executionEpoch",
                 static_cast<int64_t>(progress.execution_epoch));
    setStringProp(env, object, "name", task->name());
    setStringProp(env, object, "state", loadStateToString(state));
    setDoubleProp(env, object, "progress", progress.overall_progress); // compatibility
    setDoubleProp(env, object, "overallProgress", progress.overall_progress);
    setInt64Prop(env, object, "speedBps", progress.speed_bps);
    setInt32Prop(env, object, "activeThreads", progress.active_threads);
    setStringProp(env, object, "currentFile", progress.current_file);
    setInt32Prop(env, object, "filesDone", progress.files_done);
    setInt32Prop(env, object, "filesTotal", progress.files_total);
    setInt64Prop(env, object, "bytesDone", progress.bytes_done);
    setInt64Prop(env, object, "bytesTotal", progress.bytes_total);
    setInt64Prop(env, object, "etaSeconds", progress.eta_seconds);
    setInt64Prop(env, object, "durationMs", task->durationMs());
    setBoolProp(env, object, "terminal", isTerminalState(state));
    napi_set_named_property(env, object, "currentFiles",
                            createStringArray(env, progress.current_files));

    const auto error = task->error();
    if (error) {
        napi_set_named_property(env, object, "error", createErrorSnapshot(env, error));
    }
    napi_set_named_property(env, object, "failedFiles",
                            createFailedFilesSnapshot(env, task->failedFiles()));
    return object;
}

template<typename BridgePtr>
struct BridgeSlot {
    BridgePtr bridge;
    std::shared_ptr<std::atomic<uint64_t>> current_generation =
        std::make_shared<std::atomic<uint64_t>>(0);
};

struct EnvBridgeRegistry {
    explicit EnvBridgeRegistry(napi_env value) : env(value) {}
    napi_env env;
    std::mutex mutex;
    bool closing = false;
    std::unordered_map<uint64_t, BridgeSlot<NapiProgressBridgePtr>> progress;
    std::unordered_map<uint64_t, BridgeSlot<NapiCompleteBridgePtr>> complete;

    bool installProgress(uint64_t task_id, NapiProgressBridgePtr bridge) {
        NapiProgressBridgePtr old;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (closing || !bridge) return false;
            auto& slot = progress[task_id];
            bridge->bindGenerationGuard(slot.current_generation);
            slot.current_generation->store(bridge->generation(), std::memory_order_release);
            old = std::move(slot.bridge);
            slot.bridge = std::move(bridge);
        }
        if (old) old->close();
        return true;
    }

    bool installComplete(uint64_t task_id, NapiCompleteBridgePtr bridge) {
        NapiCompleteBridgePtr old;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (closing || !bridge) return false;
            auto& slot = complete[task_id];
            bridge->bindGenerationGuard(slot.current_generation);
            slot.current_generation->store(bridge->generation(), std::memory_order_release);
            old = std::move(slot.bridge);
            slot.bridge = std::move(bridge);
        }
        if (old) old->close();
        return true;
    }

    void closeTask(uint64_t task_id) {
        NapiProgressBridgePtr old_progress;
        NapiCompleteBridgePtr old_complete;
        {
            std::lock_guard<std::mutex> lock(mutex);
            auto progress_it = progress.find(task_id);
            if (progress_it != progress.end()) {
                progress_it->second.current_generation->store(0, std::memory_order_release);
                old_progress = std::move(progress_it->second.bridge);
                progress.erase(progress_it);
            }
            auto complete_it = complete.find(task_id);
            if (complete_it != complete.end()) {
                complete_it->second.current_generation->store(0, std::memory_order_release);
                old_complete = std::move(complete_it->second.bridge);
                complete.erase(complete_it);
            }
        }
        if (old_progress) old_progress->close();
        if (old_complete) old_complete->close();
    }

    void closeAll() {
        std::unordered_map<uint64_t, BridgeSlot<NapiProgressBridgePtr>> old_progress;
        std::unordered_map<uint64_t, BridgeSlot<NapiCompleteBridgePtr>> old_complete;
        {
            std::lock_guard<std::mutex> lock(mutex);
            closing = true;
            for (auto& item : progress) {
                item.second.current_generation->store(0, std::memory_order_release);
            }
            for (auto& item : complete) {
                item.second.current_generation->store(0, std::memory_order_release);
            }
            old_progress.swap(progress);
            old_complete.swap(complete);
        }
        for (auto& item : old_progress) {
            if (item.second.bridge) item.second.bridge->close();
        }
        for (auto& item : old_complete) {
            if (item.second.bridge) item.second.bridge->close();
        }
    }
};

std::mutex g_registry_mutex;
std::unordered_map<napi_env, EnvBridgeRegistry*> g_registries;

void cleanupEnvRegistry(void* data) {
    auto* registry = static_cast<EnvBridgeRegistry*>(data);
    if (!registry) return;
    {
        std::lock_guard<std::mutex> lock(g_registry_mutex);
        auto it = g_registries.find(registry->env);
        if (it != g_registries.end() && it->second == registry) g_registries.erase(it);
    }
    registry->closeAll();
    delete registry;
}

EnvBridgeRegistry* getRegistry(napi_env env) {
    std::lock_guard<std::mutex> lock(g_registry_mutex);
    auto it = g_registries.find(env);
    return it == g_registries.end() ? nullptr : it->second;
}

EnvBridgeRegistry* ensureRegistry(napi_env env) {
    std::lock_guard<std::mutex> lock(g_registry_mutex);
    auto it = g_registries.find(env);
    if (it != g_registries.end()) return it->second;
    auto* registry = new EnvBridgeRegistry(env);
    if (napi_add_env_cleanup_hook(env, cleanupEnvRegistry, registry) != napi_ok) {
        delete registry;
        return nullptr;
    }
    g_registries.emplace(env, registry);
    return registry;
}

// ============================================================================
// NAPI 方法实现
// ============================================================================

napi_value DownloadCreateTask(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        return throwErrorAndReturnNull(env, "downloadCreateTask: missing spec argument");
    }

    LoaderDownload::Config cfg;
    std::string err;
    if (!parseTaskConfig(env, argv[0], cfg, err)) {
        return throwErrorAndReturnNull(env, "downloadCreateTask: " + err);
    }

    auto task = DownloadEngine::instance().createTask(std::move(cfg));
    AMCL_LOG_I(LOG_TAG, "createTask id=%{public}llu name='%{public}s' files=%{public}zu",
                (unsigned long long)task->taskId(), task->name().c_str(),
                task->files().size());

    napi_value result;
    napi_create_int64(env, static_cast<int64_t>(task->taskId()), &result);
    return result;
}

napi_value DownloadStart(napi_env env, napi_callback_info info) {
    uint64_t task_id = 0;
    std::vector<napi_value> argv;
    if (!readTaskIdArg(env, info, 1, task_id, argv)) {
        return throwErrorAndReturnNull(env, "downloadStart: invalid taskId");
    }

    bool ok = DownloadEngine::instance().startTask(task_id);
    napi_value r;
    napi_get_boolean(env, ok, &r);
    return r;
}

napi_value DownloadCancel(napi_env env, napi_callback_info info) {
    uint64_t task_id = 0;
    std::vector<napi_value> argv;
    if (!readTaskIdArg(env, info, 1, task_id, argv)) {
        return throwErrorAndReturnNull(env, "downloadCancel: invalid taskId");
    }

    bool ok = DownloadEngine::instance().cancelTask(task_id);
    napi_value r;
    napi_get_boolean(env, ok, &r);
    return r;
}

// v5: 暂停（语义=cancel，保留 meta 供 resume 续传）
napi_value DownloadPauseTask(napi_env env, napi_callback_info info) {
    uint64_t task_id = 0;
    std::vector<napi_value> argv;
    if (!readTaskIdArg(env, info, 1, task_id, argv)) {
        return throwErrorAndReturnNull(env, "downloadPauseTask: invalid taskId");
    }
    bool ok = DownloadEngine::instance().pauseTask(task_id);
    napi_value r;
    napi_get_boolean(env, ok, &r);
    return r;
}

// v5: 恢复 Aborted/Failed 任务 — 走断点续传
napi_value DownloadResumeTask(napi_env env, napi_callback_info info) {
    uint64_t task_id = 0;
    std::vector<napi_value> argv;
    if (!readTaskIdArg(env, info, 1, task_id, argv)) {
        return throwErrorAndReturnNull(env, "downloadResumeTask: invalid taskId");
    }
    bool ok = DownloadEngine::instance().resumeTask(task_id);
    napi_value r;
    napi_get_boolean(env, ok, &r);
    return r;
}

// v5: 清理磁盘残留（返回释放的字节数）
napi_value DownloadDeleteTaskFiles(napi_env env, napi_callback_info info) {
    uint64_t task_id = 0;
    std::vector<napi_value> argv;
    if (!readTaskIdArg(env, info, 1, task_id, argv)) {
        return throwErrorAndReturnNull(env, "downloadDeleteTaskFiles: invalid taskId");
    }
    int64_t freed = DownloadEngine::instance().deleteTaskFiles(task_id);
    napi_value r;
    napi_create_int64(env, freed, &r);
    return r;
}

// v5: 只重试指定文件（空数组=重试所有 Failed 文件）
napi_value DownloadRetryFailed(napi_env env, napi_callback_info info) {
    uint64_t task_id = 0;
    std::vector<napi_value> argv;
    if (!readTaskIdArg(env, info, 2, task_id, argv)) {
        return throwErrorAndReturnNull(env,
            "downloadRetryFailed: need a valid (taskId, [paths])");
    }

    std::vector<std::string> paths;
    if (argv.size() >= 2 && argv[1] != nullptr) {
        napi_valuetype type = napi_undefined;
        if (napi_typeof(env, argv[1], &type) != napi_ok) {
            return throwErrorAndReturnNull(env, "downloadRetryFailed: paths is unreadable");
        }
        if (type != napi_undefined) {
            bool is_array = false;
            uint32_t len = 0;
            if (napi_is_array(env, argv[1], &is_array) != napi_ok || !is_array ||
                napi_get_array_length(env, argv[1], &len) != napi_ok || len > kMaxTaskFiles) {
                return throwErrorAndReturnNull(env,
                    "downloadRetryFailed: paths must be an array with at most 16384 items");
            }
            paths.reserve(len);
            std::unordered_set<std::string> unique_paths;
            unique_paths.reserve(len);
            for (uint32_t i = 0; i < len; ++i) {
                napi_value item = nullptr;
                std::string path;
                if (napi_get_element(env, argv[1], i, &item) != napi_ok ||
                    !readBoundedString(env, item, kMaxPathBytes, path, false) ||
                    containsControlChar(path)) {
                    return throwErrorAndReturnNull(env,
                        "downloadRetryFailed: every path must be a non-empty bounded string");
                }
                if (unique_paths.insert(path).second) paths.push_back(std::move(path));
            }
        }
    }

    bool ok = DownloadEngine::instance().retryFailedFiles(task_id, paths);
    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

// v5: 从任务注册表移除终态任务 — 配合下载历史管理
napi_value DownloadPurgeTask(napi_env env, napi_callback_info info) {
    uint64_t task_id = 0;
    std::vector<napi_value> argv;
    if (!readTaskIdArg(env, info, 1, task_id, argv)) {
        return throwErrorAndReturnNull(env, "downloadPurgeTask: invalid taskId");
    }
    bool ok = DownloadEngine::instance().purgeTask(task_id);
    if (ok) {
        if (auto* registry = getRegistry(env)) registry->closeTask(task_id);
    }
    napi_value r;
    napi_get_boolean(env, ok, &r);
    return r;
}

napi_value DownloadOnProgress(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 2) {
        return throwErrorAndReturnNull(env, "downloadOnProgress: need (taskId, callback)");
    }

    double raw_id = 0;
    napi_valuetype type = napi_undefined;
    if (napi_get_value_double(env, argv[0], &raw_id) != napi_ok ||
        !std::isfinite(raw_id) || std::floor(raw_id) != raw_id || raw_id <= 0 ||
        raw_id > kMaxSafeJsInteger || napi_typeof(env, argv[1], &type) != napi_ok ||
        type != napi_function) {
        return throwErrorAndReturnNull(env,
            "downloadOnProgress: invalid taskId or callback");
    }

    const uint64_t task_id = static_cast<uint64_t>(raw_id);
    auto task = DownloadEngine::instance().getTask(task_id);
    auto* registry = getRegistry(env);
    auto bridge = task ? NapiProgressBridge::Create(env, argv[1], task_id) : nullptr;
    napi_value result = nullptr;
    if (!task || !registry || !bridge || !registry->installProgress(task_id, bridge)) {
        if (bridge) bridge->close();
        napi_get_boolean(env, false, &result);
        return result;
    }

    task->setOnProgressChanged([bridge](const TaskProgress& progress) {
        bridge->push(progress);
    });
    napi_get_boolean(env, true, &result);
    return result;
}

napi_value DownloadOnComplete(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 2) {
        return throwErrorAndReturnNull(env, "downloadOnComplete: need (taskId, callback)");
    }

    double raw_id = 0;
    napi_valuetype type = napi_undefined;
    if (napi_get_value_double(env, argv[0], &raw_id) != napi_ok ||
        !std::isfinite(raw_id) || std::floor(raw_id) != raw_id || raw_id <= 0 ||
        raw_id > kMaxSafeJsInteger || napi_typeof(env, argv[1], &type) != napi_ok ||
        type != napi_function) {
        return throwErrorAndReturnNull(env,
            "downloadOnComplete: invalid taskId or callback");
    }

    const uint64_t task_id = static_cast<uint64_t>(raw_id);
    auto task = DownloadEngine::instance().getTask(task_id);
    auto* registry = getRegistry(env);
    auto bridge = task ? NapiCompleteBridge::Create(env, argv[1], task_id) : nullptr;
    napi_value result = nullptr;
    if (!task || !registry || !bridge || !registry->installComplete(task_id, bridge)) {
        if (bridge) bridge->close();
        napi_get_boolean(env, false, &result);
        return result;
    }

    std::weak_ptr<LoaderDownload> weak_task = task;
    task->setOnComplete([bridge, weak_task](bool success, bool aborted,
                                            DownloadExceptionPtr error,
                                            const TaskProgress& final_progress) {
        std::vector<FailedFileInfo> failed;
        int64_t duration_ms = 0;
        if (auto current = weak_task.lock()) {
            failed = current->failedFiles();
            duration_ms = current->durationMs();
        }
        if (!bridge->push(success, aborted, std::move(error), final_progress,
                          std::move(failed), duration_ms)) {
            AMCL_LOG_E(LOG_TAG,
                "Complete callback unavailable; task terminal snapshot remains queryable");
        }
    });

    // 闭合“任务先终态、后注册”及注册/终态并发窗口。Bridge 内 exactly-once guard
    // 会去重与 transitTo callback 同时发生的双重 push。
    const LoadState state = task->state();
    if (isTerminalState(state)) {
        bridge->push(state == LoadState::Finished, state == LoadState::Aborted,
                     task->error(), task->computeProgress(), task->failedFiles(),
                     task->durationMs());
    }

    napi_get_boolean(env, true, &result);
    return result;
}

napi_value DownloadListActive(napi_env env, napi_callback_info /*info*/) {
    const auto tasks = DownloadEngine::instance().listTasks();
    napi_value array = nullptr;
    napi_create_array_with_length(env, tasks.size(), &array);
    for (size_t i = 0; i < tasks.size(); ++i) {
        napi_set_element(env, array, static_cast<uint32_t>(i),
                         createTaskSnapshot(env, tasks[i]));
    }
    return array;
}

napi_value DownloadQueryTask(napi_env env, napi_callback_info info) {
    uint64_t task_id = 0;
    std::vector<napi_value> argv;
    if (!readTaskIdArg(env, info, 1, task_id, argv)) {
        return throwErrorAndReturnNull(env, "downloadQueryTask: invalid taskId");
    }
    auto task = DownloadEngine::instance().getTask(task_id);
    if (!task) {
        napi_value null_value = nullptr;
        napi_get_null(env, &null_value);
        return null_value;
    }
    return createTaskSnapshot(env, task);
}

napi_value DownloadDetachCallbacks(napi_env env, napi_callback_info /*info*/) {
    if (auto* registry = getRegistry(env)) registry->closeAll();
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value DownloadShutdown(napi_env env, napi_callback_info /*info*/) {
    DownloadEngine::instance().shutdown();
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

// ============================================================
//  Phase 3 (S2-2) + Phase 2.3 (P2-2): downloadFetchText — async URL → string
// ============================================================
//
// 协议（向后兼容 + 扩展）：
//   downloadFetchText(
//       primaryUrl: string,
//       mirrors?: string[],
//       timeoutSec?: number,
//       requestHeaders?: Record<string, string>  // Phase 2.3 新增（可选）
//   ) → Promise<{
//       ok: boolean,                              // status_code 200-299 或 304
//       body?: string,
//       statusCode?: number,                     // Phase 2.3 新增（始终填）
//       headers?: Record<string, string>,        // Phase 2.3 新增，key 小写
//       errorKind?: string,
//       errorMessage?: string,
//   }>
//
// 304 短路：调用方传 If-None-Match → 命中时返回 ok=true, statusCode=304, body=""，
// 调用方 (MetadataCacheStore) 据此决定使用本地 cache。

struct FetchTextData {
    std::string primary_url;
    std::vector<std::string> mirrors;
    int timeout_seconds = 30;
    size_t max_response_bytes = kDefaultMaxFetchResponseBytes;
    std::map<std::string, std::string> request_headers;

    // out（Phase 2.3 走 fetchToBufferEx，复用 FetchResponse 容器）
    FetchResponse resp;
    int rc = -1;

    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
};

void FetchTextExecute(napi_env /*env*/, void* data) {
    auto* d = static_cast<FetchTextData*>(data);
    d->rc = DownloadEngine::instance().fetchToBufferEx(
        d->primary_url, d->mirrors, d->timeout_seconds,
        d->request_headers, d->max_response_bytes, d->resp);
    // NAPI 边界的第二道防线：禁止再把超大 body 复制进 JS heap。
    // 真正的流式内存上限还必须由 engine.cpp 的 write callback 联动执行。
    if (d->rc == 0 && d->resp.body.size() > d->max_response_bytes) {
        d->resp.body.clear();
        d->resp.err_kind = "ResponseTooLarge";
        d->resp.err_msg = "response body exceeded NAPI maxResponseBytes";
        d->rc = -1;
    }
}

void FetchTextComplete(napi_env env, napi_status /*status*/, void* data) {
    auto* d = static_cast<FetchTextData*>(data);

    napi_value result;
    napi_create_object(env, &result);

    napi_value ok_val;
    napi_get_boolean(env, d->rc == 0, &ok_val);
    napi_set_named_property(env, result, "ok", ok_val);

    // statusCode 始终返回（即使失败也可能拿到 0/4xx/5xx）
    napi_value status_val;
    napi_create_int32(env, d->resp.status_code, &status_val);
    napi_set_named_property(env, result, "statusCode", status_val);

    if (d->rc == 0) {
        napi_value body_val;
        napi_create_string_utf8(env, d->resp.body.c_str(), d->resp.body.size(), &body_val);
        napi_set_named_property(env, result, "body", body_val);

        // Phase 2.3: headers 总是填（即便 304 也带 ETag）
        napi_value headers_obj;
        napi_create_object(env, &headers_obj);
        for (const auto& kv : d->resp.headers) {
            napi_value v;
            napi_create_string_utf8(env, kv.second.c_str(), kv.second.size(), &v);
            napi_set_named_property(env, headers_obj, kv.first.c_str(), v);
        }
        napi_set_named_property(env, result, "headers", headers_obj);
    } else {
        napi_value kind_val;
        napi_create_string_utf8(env, d->resp.err_kind.c_str(), d->resp.err_kind.size(), &kind_val);
        napi_set_named_property(env, result, "errorKind", kind_val);

        napi_value msg_val;
        napi_create_string_utf8(env, d->resp.err_msg.c_str(), d->resp.err_msg.size(), &msg_val);
        napi_set_named_property(env, result, "errorMessage", msg_val);
    }

    napi_resolve_deferred(env, d->deferred, result);
    napi_delete_async_work(env, d->work);
    delete d;
}

napi_value DownloadFetchText(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value argv[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1) {
        return throwErrorAndReturnNull(env,
            "downloadFetchText: need at least 1 arg (primaryUrl)");
    }

    auto* d = new FetchTextData();
    auto fail = [env, d](const std::string& message) -> napi_value {
        delete d;
        return throwErrorAndReturnNull(env, message);
    };

    if (!readBoundedString(env, argv[0], kMaxUrlBytes, d->primary_url, false) ||
        !isHttpUrl(d->primary_url)) {
        return fail("downloadFetchText: primaryUrl must be a bounded http/https URL");
    }

    // arg[1]: mirrors[] (可选，但提供后必须严格满足 schema)
    if (argc >= 2 && argv[1] != nullptr) {
        napi_valuetype type = napi_undefined;
        if (napi_typeof(env, argv[1], &type) != napi_ok) {
            return fail("downloadFetchText: mirrors is unreadable");
        }
        if (type != napi_undefined) {
            bool is_array = false;
            uint32_t count = 0;
            if (napi_is_array(env, argv[1], &is_array) != napi_ok || !is_array ||
                napi_get_array_length(env, argv[1], &count) != napi_ok ||
                count > kMaxFetchMirrors) {
                return fail("downloadFetchText: mirrors must contain at most 16 URLs");
            }
            std::unordered_set<std::string> unique_urls;
            unique_urls.insert(d->primary_url);
            d->mirrors.reserve(count);
            for (uint32_t i = 0; i < count; ++i) {
                napi_value item = nullptr;
                std::string url;
                if (napi_get_element(env, argv[1], i, &item) != napi_ok ||
                    !readBoundedString(env, item, kMaxUrlBytes, url, false) ||
                    !isHttpUrl(url)) {
                    return fail("downloadFetchText: every mirror must be a bounded http/https URL");
                }
                if (unique_urls.insert(url).second) d->mirrors.push_back(std::move(url));
            }
        }
    }

    // arg[2]: timeoutSec (可选安全整数 1..300)
    if (argc >= 3 && argv[2] != nullptr) {
        napi_valuetype type = napi_undefined;
        if (napi_typeof(env, argv[2], &type) != napi_ok) {
            return fail("downloadFetchText: timeoutSec is unreadable");
        }
        if (type != napi_undefined) {
            double timeout = 0;
            if (type != napi_number || napi_get_value_double(env, argv[2], &timeout) != napi_ok ||
                !std::isfinite(timeout) || std::floor(timeout) != timeout ||
                timeout < kMinFetchTimeoutSeconds || timeout > kMaxFetchTimeoutSeconds) {
                return fail("downloadFetchText: timeoutSec must be an integer in [1, 300]");
            }
            d->timeout_seconds = static_cast<int>(timeout);
        }
    }

    // arg[3]: requestHeaders (可选 Record<string, string>)
    if (argc >= 4 && argv[3] != nullptr) {
        napi_valuetype type = napi_undefined;
        if (napi_typeof(env, argv[3], &type) != napi_ok) {
            return fail("downloadFetchText: requestHeaders is unreadable");
        }
        if (type != napi_undefined) {
            if (type != napi_object) {
                return fail("downloadFetchText: requestHeaders must be an object");
            }
            napi_value keys = nullptr;
            uint32_t count = 0;
            if (napi_get_property_names(env, argv[3], &keys) != napi_ok ||
                napi_get_array_length(env, keys, &count) != napi_ok ||
                count > kMaxRequestHeaders) {
                return fail("downloadFetchText: requestHeaders has too many properties");
            }
            for (uint32_t i = 0; i < count; ++i) {
                napi_value key_value = nullptr;
                napi_value value = nullptr;
                std::string key;
                std::string header_value;
                if (napi_get_element(env, keys, i, &key_value) != napi_ok ||
                    !readBoundedString(env, key_value, kMaxHeaderNameBytes, key, false) ||
                    !isValidHeaderName(key) ||
                    napi_get_property(env, argv[3], key_value, &value) != napi_ok ||
                    !readBoundedString(env, value, kMaxHeaderValueBytes, header_value, true) ||
                    containsControlChar(header_value)) {
                    return fail("downloadFetchText: invalid bounded request header");
                }
                d->request_headers.emplace(std::move(key), std::move(header_value));
            }
        }
    }

    // arg[4]: maxResponseBytes（可选；默认/硬上限均为 16 MiB）
    if (argc >= 5 && argv[4] != nullptr) {
        napi_valuetype type = napi_undefined;
        if (napi_typeof(env, argv[4], &type) != napi_ok) {
            return fail("downloadFetchText: maxResponseBytes is unreadable");
        }
        if (type != napi_undefined) {
            double limit = 0;
            if (type != napi_number || napi_get_value_double(env, argv[4], &limit) != napi_ok ||
                !std::isfinite(limit) || std::floor(limit) != limit || limit < 1 ||
                limit > static_cast<double>(kMaxFetchResponseBytes)) {
                return fail("downloadFetchText: maxResponseBytes must be an integer in [1, 16777216]");
            }
            d->max_response_bytes = static_cast<size_t>(limit);
        }
    }

    napi_value promise = nullptr;
    napi_value resource_name = nullptr;
    if (napi_create_promise(env, &d->deferred, &promise) != napi_ok ||
        napi_create_string_utf8(env, "downloadFetchText", NAPI_AUTO_LENGTH,
                                &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name,
                               FetchTextExecute, FetchTextComplete, d, &d->work) != napi_ok) {
        return fail("downloadFetchText: failed to create async work");
    }
    if (napi_queue_async_work(env, d->work) != napi_ok) {
        napi_delete_async_work(env, d->work);
        d->work = nullptr;
        return fail("downloadFetchText: failed to queue async work");
    }
    return promise;
}

napi_value DownloadComputeFileSha1(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    std::string path;
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 1 ||
        !readBoundedString(env, argv[0], kMaxPathBytes, path, false) ||
        containsControlChar(path) || !std::filesystem::path(path).is_absolute()) {
        return throwErrorAndReturnNull(env,
            "downloadComputeFileSha1: path must be a bounded absolute path");
    }
    std::string digest = computeFileSha1(path);
    if (digest.empty()) {
        return throwErrorAndReturnNull(env, "downloadComputeFileSha1: safe hash failed");
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, digest.c_str(), digest.size(), &result);
    return result;
}

napi_value DownloadPublishNoReplace(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    std::string source;
    std::string destination;
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc < 2 ||
        !readBoundedString(env, argv[0], kMaxPathBytes, source, false) ||
        !readBoundedString(env, argv[1], kMaxPathBytes, destination, false) ||
        containsControlChar(source) || containsControlChar(destination)) {
        return throwErrorAndReturnNull(env,
            "downloadPublishNoReplace: paths must be bounded strings");
    }
    std::filesystem::path source_path(source);
    std::filesystem::path destination_path(destination);
    if (!source_path.is_absolute() || !destination_path.is_absolute() ||
        source_path.parent_path() != destination_path.parent_path()) {
        return throwErrorAndReturnNull(env,
            "downloadPublishNoReplace: source and destination must share a parent");
    }
    const std::string parent = source_path.parent_path().string();
    int parent_fd = ::open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC
#ifdef O_NOFOLLOW
                           | O_NOFOLLOW
#endif
    );
    bool ok = false;
    if (parent_fd >= 0) {
        const std::string source_name = source_path.filename().string();
        const std::string destination_name = destination_path.filename().string();
#if defined(SYS_renameat2)
        ok = ::syscall(SYS_renameat2, parent_fd, source_name.c_str(), parent_fd,
                       destination_name.c_str(), RENAME_NOREPLACE) == 0;
#else
        ok = ::linkat(parent_fd, source_name.c_str(), parent_fd, destination_name.c_str(), 0) == 0 &&
             ::unlinkat(parent_fd, source_name.c_str(), 0) == 0;
#endif
        if (ok) {
            int sync_result;
            do { sync_result = ::fsync(parent_fd); } while (sync_result != 0 && errno == EINTR);
            ok = sync_result == 0;
        }
        ::close(parent_fd);
    }
    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value DownloadSetCaBundle(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        return throwErrorAndReturnNull(env, "downloadSetCaBundle: need 1 arg (path)");
    }

    std::string path;
    if (!readBoundedString(env, argv[0], kMaxPathBytes, path, false) ||
        containsControlChar(path) || !std::filesystem::path(path).is_absolute()) {
        return throwErrorAndReturnNull(env,
            "downloadSetCaBundle: path must be a non-empty bounded absolute string");
    }

    setCaBundlePath(path);
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

// ============================================================================
//  加速网关配置注入（2026-08-01）
//    downloadSetRelay(base, ticket, sessionKey, requireProof, expiresAtMs)
//    downloadClearRelay()
//    downloadRelayStats() -> { requests, failures, authRejects, tripped }
//
//  ArkTS 侧（RelayClient.ets）完成握手后调用；native 只消费配置，不自己发起握手。
//  ⚠️ sessionKey 是敏感值：这里既不落盘也不打日志（日志只打长度）。
// ============================================================================

napi_value DownloadSetRelay(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value argv[5];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 5) {
        return throwErrorAndReturnNull(env,
            "downloadSetRelay: need 5 args (base, ticket, sessionKey, requireProof, expiresAtMs)");
    }

    constexpr size_t kMaxTokenBytes = 4096;
    RelayConfig cfg;
    if (!readBoundedString(env, argv[0], kMaxPathBytes, cfg.base, false) ||
        containsControlChar(cfg.base) || cfg.base.rfind("https://", 0) != 0) {
        return throwErrorAndReturnNull(env, "downloadSetRelay: base must be a non-empty https URL");
    }
    if (!readBoundedString(env, argv[1], kMaxTokenBytes, cfg.ticket, false) ||
        containsControlChar(cfg.ticket)) {
        return throwErrorAndReturnNull(env, "downloadSetRelay: ticket must be a non-empty bounded string");
    }
    // sessionKey 允许为空（服务端 requireProof=false 时）
    if (!readBoundedString(env, argv[2], kMaxTokenBytes, cfg.session_key, true) ||
        containsControlChar(cfg.session_key)) {
        return throwErrorAndReturnNull(env, "downloadSetRelay: sessionKey must be a bounded string");
    }

    napi_valuetype t = napi_undefined;
    bool require_proof = true;
    if (napi_typeof(env, argv[3], &t) != napi_ok || t != napi_boolean ||
        napi_get_value_bool(env, argv[3], &require_proof) != napi_ok) {
        return throwErrorAndReturnNull(env, "downloadSetRelay: requireProof must be a boolean");
    }
    cfg.require_proof = require_proof;

    double expires = 0;
    if (napi_typeof(env, argv[4], &t) != napi_ok || t != napi_number ||
        napi_get_value_double(env, argv[4], &expires) != napi_ok || !std::isfinite(expires) ||
        expires < 0 || expires > kMaxSafeJsInteger) {
        return throwErrorAndReturnNull(env, "downloadSetRelay: expiresAtMs must be a finite non-negative number");
    }
    cfg.expires_at_ms = static_cast<int64_t>(expires);

    if (cfg.require_proof && cfg.session_key.empty()) {
        return throwErrorAndReturnNull(env, "downloadSetRelay: sessionKey required when requireProof=true");
    }

    cfg.enabled = true;
    relaySetConfig(cfg);

    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

napi_value DownloadClearRelay(napi_env env, napi_callback_info /*info*/) {
    relayDisable();
    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}

napi_value DownloadRelayStats(napi_env env, napi_callback_info /*info*/) {
    RelayStats s = relayStats();
    napi_value obj;
    napi_create_object(env, &obj);
    auto setNum = [&](const char* k, int64_t v) {
        napi_value n;
        napi_create_double(env, static_cast<double>(v), &n);
        napi_set_named_property(env, obj, k, n);
    };
    setNum("requests", s.requests);
    setNum("failures", s.failures);
    setNum("fallbacks", s.fallbacks);
    setNum("authRejects", s.auth_rejects);
    napi_value tripped;
    napi_get_boolean(env, relayTripped(), &tripped);
    napi_set_named_property(env, obj, "tripped", tripped);
    napi_value usable;
    napi_get_boolean(env, relayUsable(), &usable);
    napi_set_named_property(env, obj, "usable", usable);
    return obj;
}

#define DL_NAPI_FUNC(name, fn) \
    { name, nullptr, fn, nullptr, nullptr, nullptr, napi_default, nullptr }

} // namespace

// ============================================================================
// Public: 注册
// ============================================================================

void registerDownloadNapi(napi_env env, napi_value exports) {
    // 每个 napi_env 持有独立 bridge registry。env cleanup 只 detach/abort 旧 TSFN，
    // 不 shutdown 进程级 DownloadEngine，后台任务可在新 Ability/env 中重新 attach。
    if (!ensureRegistry(env)) {
        AMCL_LOG_E(LOG_TAG, "Download NAPI bridge registry initialization failed");
    }
    napi_property_descriptor desc[] = {
        DL_NAPI_FUNC("downloadCreateTask",      DownloadCreateTask),
        DL_NAPI_FUNC("downloadStart",           DownloadStart),
        DL_NAPI_FUNC("downloadCancel",          DownloadCancel),
        DL_NAPI_FUNC("downloadOnProgress",      DownloadOnProgress),
        DL_NAPI_FUNC("downloadOnComplete",      DownloadOnComplete),
        DL_NAPI_FUNC("downloadListActive",      DownloadListActive),
        DL_NAPI_FUNC("downloadQueryTask",       DownloadQueryTask),
        DL_NAPI_FUNC("downloadDetachCallbacks", DownloadDetachCallbacks),
        DL_NAPI_FUNC("downloadShutdown",        DownloadShutdown),
        DL_NAPI_FUNC("downloadSetCaBundle",     DownloadSetCaBundle),
        DL_NAPI_FUNC("downloadComputeFileSha1", DownloadComputeFileSha1),
        DL_NAPI_FUNC("downloadPublishNoReplace", DownloadPublishNoReplace),
        // Phase 3 (S2-2): metadata fetch through engine
        DL_NAPI_FUNC("downloadFetchText",       DownloadFetchText),
        // v5: 扩展 API — 暂停 / 继续 / 清理 / 重试 / Purge
        DL_NAPI_FUNC("downloadPauseTask",       DownloadPauseTask),
        DL_NAPI_FUNC("downloadResumeTask",      DownloadResumeTask),
        DL_NAPI_FUNC("downloadDeleteTaskFiles", DownloadDeleteTaskFiles),
        DL_NAPI_FUNC("downloadRetryFailed",     DownloadRetryFailed),
        DL_NAPI_FUNC("downloadPurgeTask",       DownloadPurgeTask),
        // 加速网关（票据由 ArkTS 握手后注入；native 负责 URL 改写与每请求签名）
        DL_NAPI_FUNC("downloadSetRelay",        DownloadSetRelay),
        DL_NAPI_FUNC("downloadClearRelay",      DownloadClearRelay),
        DL_NAPI_FUNC("downloadRelayStats",      DownloadRelayStats),
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    AMCL_LOG_I(LOG_TAG, "Download NAPI registered (v5)");
}

} // namespace download

#undef DL_NAPI_FUNC
