/**
 * 导出专用异步job桥：每env独立registry，返回jobId+Promise，查询不跨env借用ID。
 * 执行线程只持plain C++参数；所有JS/NAPI调用都留owner线程。Promise结算早于页面清理，
 * 但必须晚于worker join/文件关闭和settled发布；release不凭可见终态抢先归还owner。
 */
#include "napi_export.h"
#include "../export/export_trusted_io.h"
#include <atomic>
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <memory>
#include <thread>
#include <unordered_map>
#include <unistd.h>

namespace amcl::napi {
namespace {
using namespace amcl::exporter;
std::atomic<uint64_t> nextJob{1};
struct Job {
    uint64_t id; std::string operation; Operation core; napi_async_work pendingCleanup = nullptr;
    napi_deferred deferred = nullptr; bool pendingDelivery = false, delivering = false, deliveryFailed = false;
    napi_status deliveryStatus = napi_ok;
};
struct Holder;
struct Context {
    napi_env env; const std::thread::id owner = std::this_thread::get_id();
    const pid_t pid = ::getpid();
    std::atomic<bool> closing{false};
    Holder* cleanupOwner = nullptr;
    napi_async_cleanup_hook_handle cleanupHandle = nullptr;
    std::unordered_map<uint64_t, std::shared_ptr<Job>> jobs;
    // 连续退役ID压缩；多env交错/未发布ID间隙最多保留256个近期区间。过旧receipt
    // 失效后返回unknown，不能猜它已经退出；父wrapper只在持有本ID时即时正向释放。
    std::map<uint64_t, uint64_t> retired;
    bool wasRetired(uint64_t id) const { auto next = retired.upper_bound(id); return next != retired.begin() && std::prev(next)->second >= id; }
    void retire(uint64_t id) {
        auto next = retired.upper_bound(id);
        if (next != retired.begin()) {
            auto previous = std::prev(next);
            if (previous->second + 1 >= id) {
                previous->second = std::max(previous->second, id);
                if (next != retired.end() && previous->second + 1 >= next->first) { previous->second = next->second; retired.erase(next); }
                return;
            }
        }
        if (next != retired.end() && id + 1 == next->first) { const auto end = next->second; retired.emplace(id, end); retired.erase(next); }
        else retired.emplace(id, id);
        while (retired.size() > 256) retired.erase(retired.begin());
    }
};
/** cleanup只撤销环境的发布权和登记；在途work仍以shared_ptr持有所有Native资源直到真实结束。 */
struct Holder { std::shared_ptr<Context> context; };
struct Work {
    std::shared_ptr<Context> context; std::shared_ptr<Job> job;
    ArchiveSpec archive; Fd hashFd; uint64_t hashSize = 0; bool hashSha1 = true, hashSha256 = true;
    napi_async_work work = nullptr;
};

void Ok(napi_status status) { if (status != napi_ok) throw Failure("BridgeError", "export NAPI operation failed"); }
/** 单entry的临时JS句柄及时回收；只把已复制的plain C++字段送worker，不保留napi_value。 */
class HandleScope {
    napi_env env_; napi_handle_scope scope_ = nullptr;
public:
    explicit HandleScope(napi_env env) : env_(env) { Ok(napi_open_handle_scope(env_, &scope_)); }
    ~HandleScope() { if (scope_) (void)napi_close_handle_scope(env_, scope_); }
    void close() { const auto scope = scope_; scope_ = nullptr; Ok(napi_close_handle_scope(env_, scope)); }
};
napi_value Object(napi_env env) { napi_value out = nullptr; Ok(napi_create_object(env, &out)); return out; }
void Set(napi_env env, napi_value object, const char* name, napi_value value) { Ok(napi_set_named_property(env, object, name, value)); }
void Number(napi_env env, napi_value object, const char* name, uint64_t number) { napi_value value; Ok(napi_create_double(env, static_cast<double>(number), &value)); Set(env, object, name, value); }
void Boolean(napi_env env, napi_value object, const char* name, bool flag) { napi_value value; Ok(napi_get_boolean(env, flag, &value)); Set(env, object, name, value); }
void String(napi_env env, napi_value object, const char* name, const std::string& text) { napi_value value; Ok(napi_create_string_utf8(env, text.data(), text.size(), &value)); Set(env, object, name, value); }
napi_value Get(napi_env env, napi_value object, const char* name) { napi_value value; Ok(napi_get_named_property(env, object, name, &value)); return value; }
bool Has(napi_env env, napi_value object, const char* name) { bool result = false; Ok(napi_has_named_property(env, object, name, &result)); return result; }
std::string Text(napi_env env, napi_value value, size_t maximum) {
    size_t size = 0; Ok(napi_get_value_string_utf8(env, value, nullptr, 0, &size));
    if (size > maximum) throw Failure("InvalidConfig", "export string exceeds its bound");
    std::string text(size + 1, '\0'); size_t actual = 0; Ok(napi_get_value_string_utf8(env, value, text.data(), text.size(), &actual));
    if (actual != size) throw Failure("InvalidConfig", "export string changed during conversion");
    text.resize(actual); if (text.find('\0') != std::string::npos) throw Failure("InvalidConfig", "export string contains NUL"); return text;
}
uint64_t Integer(napi_env env, napi_value value, uint64_t minimum, uint64_t maximum) {
    double number = 0; Ok(napi_get_value_double(env, value, &number));
    if (!std::isfinite(number) || number < minimum || number > maximum || std::floor(number) != number)
        throw Failure("InvalidConfig", "export number must be a bounded safe integer");
    return static_cast<uint64_t>(number);
}
bool Flag(napi_env env, napi_value value) { bool result = false; Ok(napi_get_value_bool(env, value, &result)); return result; }

/** 同env正常退出或SDK排队失败都保存真实退役事实；未知ID不伪装成已释放。 */
std::shared_ptr<Context> Owner(napi_env env, napi_callback_info info, napi_value& argument) {
    size_t count = 1; void* raw = nullptr; Ok(napi_get_cb_info(env, info, &count, &argument, nullptr, &raw));
    auto* holder = static_cast<Holder*>(raw);
    if (count != 1 || !holder || !holder->context || holder->context->env != env ||
        holder->context->owner != std::this_thread::get_id() || holder->context->pid != ::getpid() || holder->context->closing)
        throw Failure("InvalidOwner", "export job owner or argument is invalid");
    return holder->context;
}
void Throw(napi_env env, const char* code, const char* message) noexcept {
    bool pending = false; if (napi_is_exception_pending(env, &pending) == napi_ok && pending) return;
    (void)napi_throw_error(env, code, message);
}
/** 返回false表示连异常状态也未能可靠读取；此时尚未提交deferred，可由稍后query重试准备。 */
bool PendingException(napi_env env, napi_value& error) noexcept {
    bool pending = false; error = nullptr;
    if (napi_is_exception_pending(env, &pending) != napi_ok) return false;
    return !pending || (napi_get_and_clear_last_exception(env, &error) == napi_ok && error != nullptr);
}
/** 只准备拒绝值，不消费deferred；构造失败后优先取SDK原异常，再用undefined/null兜底。 */
napi_value ErrorValue(napi_env env, const char* code, const char* message) noexcept {
    napi_value error = nullptr;
    if (!PendingException(env, error)) return nullptr;
    if (error) return error;
    napi_value text = nullptr, name = nullptr;
    if (napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &text) == napi_ok &&
        napi_create_string_utf8(env, code, NAPI_AUTO_LENGTH, &name) == napi_ok &&
        napi_create_error(env, name, text, &error) == napi_ok && error) return error;
    if (!PendingException(env, error)) return nullptr;
    if (error) return error;
    if (napi_get_undefined(env, &error) == napi_ok && error) return error;
    if (!PendingException(env, error)) return nullptr;
    if (error) return error;
    return napi_get_null(env, &error) == napi_ok ? error : nullptr;
}

/** Unicode折叠仍与ArkTS String.toLowerCase同语义；只在owner线程转换，worker不调用JS。 */
std::string Fold(napi_env env, const std::string& path) {
    napi_value raw, boxed, method, result;
    Ok(napi_create_string_utf8(env, path.data(), path.size(), &raw)); Ok(napi_coerce_to_object(env, raw, &boxed));
    Ok(napi_get_named_property(env, boxed, "toLowerCase", &method)); Ok(napi_call_function(env, boxed, method, 0, nullptr, &result));
    return Text(env, result, 65535);
}
ArchiveSpec ParseArchive(napi_env env, napi_value value) {
    ArchiveSpec spec;
    spec.filesDir = Text(env, Get(env, value, "filesDir"), 4096); spec.jobRelative = Text(env, Get(env, value, "jobRelative"), 4096);
    spec.snapshotRelative = Text(env, Get(env, value, "snapshotRelative"), 4096); spec.archiveRelative = Text(env, Get(env, value, "archiveRelative"), 4096);
    if (Has(env, value, "workerCount")) spec.workers = Integer(env, Get(env, value, "workerCount"), 1, 4);
    const auto entries = Get(env, value, "entries"); bool array = false; Ok(napi_is_array(env, entries, &array));
    if (!array) throw Failure("InvalidConfig", "export entries must be an array");
    uint32_t count = 0; Ok(napi_get_array_length(env, entries, &count));
    if (!count || count > kMaxEntries) throw Failure("InvalidConfig", "export entry count exceeds bound");
    spec.entries.reserve(count);
    size_t names = 0;
    for (uint32_t i = 0; i < count; ++i) {
        HandleScope scope(env);
        napi_value object; Ok(napi_get_element(env, entries, i, &object)); Entry entry;
        entry.directory = Flag(env, Get(env, object, "directory"));
        entry.path = SafeRelative(Text(env, Get(env, object, "path"), 65535), entry.directory);
        entry.size = Integer(env, Get(env, object, "size"), 0, kSafeInteger); entry.sha256 = Text(env, Get(env, object, "sha256"), 64);
        names += entry.path.size(); if (names > 32 * 1024 * 1024) throw Failure("InvalidConfig", "export names exceed memory bound");
        entry.foldedPath = Fold(env, entry.path); spec.entries.push_back(std::move(entry)); scope.close();
    }
    ValidateSpec(spec); return spec;
}

void Execute(napi_env, void* data) {
    auto* work = static_cast<Work*>(data);
    if (work->job->operation == "hash") RunHash(work->hashFd.release(), work->hashSize, work->hashSha1, work->hashSha256, work->job->core);
    else if (work->job->operation == "write") RunWrite(std::move(work->archive), work->job->core);
    else RunVerify(std::move(work->archive), work->job->core);
}
/** 删除失败绝不伪造settled；SDK work留在同env记录，由release/teardown再次正向清理。 */
bool SettleSdk(napi_env env, Job& job) noexcept {
    if (!job.core.coreFinished.load(std::memory_order_acquire)) return false;
    if (job.pendingCleanup) {
        if (!env || napi_delete_async_work(env, job.pendingCleanup) != napi_ok) {
            job.core.fail("BridgeError", "export async work cleanup failed; owner retained"); job.core.finish(); return false;
        }
        job.pendingCleanup = nullptr;
    }
    job.core.settled.store(true, std::memory_order_release); return true;
}
/** 异步cleanup hook保持env存活到所有job真实结束；只有全部正向删除后才释放SDK屏障。 */
void FinishCleanup(const std::shared_ptr<Context>& context) noexcept {
    if (!context->closing || !context->cleanupOwner) return;
    for (auto& pair : context->jobs) {
        // teardown后没有页面query可驱动；SDK短暂回收失败只在owner线程有界重试。
        // 真正仍在execute的job没有pendingCleanup，必须等其complete，不能靠重试假定结束。
        for (unsigned attempt = 0; !pair.second->core.settled && pair.second->pendingCleanup && attempt < 3; ++attempt)
            SettleSdk(context->env, *pair.second);
        if (!pair.second->core.settled) return;
    }
    bool removed = false;
    for (unsigned attempt = 0; attempt < 3 && !removed; ++attempt)
        removed = napi_remove_async_cleanup_hook(context->cleanupHandle) == napi_ok;
    if (!removed) return; // 持续SDK损坏保留屏障，绝不先释放仍可能被SDK访问的holder。
    auto* holder = context->cleanupOwner; context->cleanupOwner = nullptr; context->cleanupHandle = nullptr;
    context->jobs.clear(); context->retired.clear(); delete holder;
}
/**
 * ArkTS的resolve/reject会同步执行微任务，因此任何NAPI调用前先占有交付权。
 * 守卫覆盖对象准备和SDK提交全过程；微任务重入Query/Release不能再次交付或擦除此job。
 */
class DeliveryGuard {
    Job& job_;
public:
    explicit DeliveryGuard(Job& job) : job_(job) { job_.delivering = true; }
    ~DeliveryGuard() { job_.delivering = false; }
};
/**
 * deferred是一次性能力。SDK内部先Resolve/Reject并delete NativeDeferred，再返回状态；
 * 即使返回非ok，也不能把同一指针用于Reject或下一次query重试。调用前先撤销发布权。
 */
void Submit(napi_env env, Job& job, napi_value value, bool reject) noexcept {
    const auto deferred = job.deferred; job.deferred = nullptr; job.pendingDelivery = false;
    const auto status = reject ? napi_reject_deferred(env, deferred, value) : napi_resolve_deferred(env, deferred, value);
    if (status != napi_ok) {
        job.deliveryFailed = true; job.deliveryStatus = status;
        job.core.fail("DeliveryFailed", "export Promise submission failed after one-shot deferred handoff"); job.core.finish();
    }
}
/** completion只在真实settled后交付；只重试尚未消费deferred的准备，不重试SDK提交。 */
void Deliver(napi_env env, Job& job) noexcept {
    auto& core = job.core;
    if (!core.settled || !job.pendingDelivery || job.delivering || !job.deferred) return;
    DeliveryGuard guard(job);
    napi_value pending = nullptr;
    if (!PendingException(env, pending)) return;
    if (pending) { Submit(env, job, pending, true); return; }
    if (core.state == State::Succeeded) {
        try {
            const auto& result = core.result; const auto value = Object(env);
            Number(env, value, "jobId", job.id); String(env, value, "operation", job.operation);
            Number(env, value, "files", result.files); Number(env, value, "size", result.size); Number(env, value, "payloadBytes", result.payloadBytes);
            Number(env, value, "archiveBytes", result.archiveBytes); String(env, value, "sha1", result.sha1); String(env, value, "sha256", result.sha256);
            if (!PendingException(env, pending)) return;
            Submit(env, job, pending ? pending : value, pending != nullptr); return;
        } catch (...) {
            const auto error = ErrorValue(env, "BridgeError", "export completion result unavailable");
            if (error) Submit(env, job, error, true);
            return;
        }
    }
    try {
        std::string code, message; core.error(code, message);
        if (code.empty()) { code = "Cancelled"; message = "export operation cancelled after actual IO settlement"; }
        const auto error = ErrorValue(env, code.c_str(), message.c_str());
        if (error) Submit(env, job, error, true);
    } catch (...) {
        const auto error = ErrorValue(env, "NativeError", "export completion error unavailable");
        if (error) Submit(env, job, error, true);
    }
}
/** complete回到owner后已无任何worker/IO；无env时不访问失效JS，不伪造SDK收敛。 */
void Complete(napi_env env, napi_status status, void* data) {
    std::unique_ptr<Work> work(static_cast<Work*>(data)); auto& core = work->job->core;
    // SDK取消一个尚未执行的work也必须关闭调用时dup的hash fd。
    try { work->hashFd.closeChecked(); }
    catch (const Failure& error) { core.fail(error.code, error.what(), error.nativeCode); }
    if (!core.coreFinished) { core.cancel(); core.finish(); }
    if (status != napi_ok && core.state == State::Succeeded) { core.fail("BridgeError", "export async completion failed"); core.finish(); }
    work->job->pendingCleanup = work->work; work->work = nullptr;
    SettleSdk(env, *work->job);
    if (!env || work->context->closing) { FinishCleanup(work->context); return; }
    Deliver(env, *work->job);
}

/** 返回值和Promise先全部构造，SDK成功接管后才释放work，杜绝隐藏在途owner。 */
napi_value Start(napi_env env, napi_callback_info info, const char* operation) {
    try {
        napi_value argument; auto context = Owner(env, info, argument);
        if (context->jobs.size() >= 128) throw Failure("Busy", "export pending job record limit reached; release settled jobs");
        auto work = std::make_unique<Work>(); work->context = context; work->job = std::make_shared<Job>(); work->job->operation = operation;
        if (std::strcmp(operation, "hash") == 0) {
            const auto fd = static_cast<int>(Integer(env, Get(env, argument, "fd"), 0, INT32_MAX));
            work->hashSize = Integer(env, Get(env, argument, "size"), 0, kSafeInteger);
            work->hashSha1 = Has(env, argument, "sha1") ? Flag(env, Get(env, argument, "sha1")) : true;
            work->hashSha256 = Has(env, argument, "sha256") ? Flag(env, Get(env, argument, "sha256")) : true;
            // 用途不改变文件权限/身份合同；双false在dup、job登记、SDK work等副作用之前拒绝。
            if (!work->hashSha1 && !work->hashSha256) throw Failure("InvalidConfig", "export hash requires at least one digest");
            work->hashFd = Fd(::fcntl(fd, F_DUPFD_CLOEXEC, 0));
            if (work->hashFd.get() < 0) throw Failure("FileIo", "export hash fd dup failed", errno);
            work->job->core.filesTotal = 1; work->job->core.bytesTotal = work->hashSize;
        } else {
            work->archive = ParseArchive(env, argument); work->job->core.filesTotal = work->archive.entries.size();
            uint64_t total = 0; for (const auto& entry : work->archive.entries) total += entry.size; work->job->core.bytesTotal = total;
        }
        const uint64_t id = nextJob.fetch_add(1); if (!id || id > kSafeInteger) throw Failure("InvalidConfig", "export job identity exhausted"); work->job->id = id;
        napi_value promise; Ok(napi_create_promise(env, &work->job->deferred, &promise));
        work->job->pendingDelivery = true;
        const auto handle = Object(env); Number(env, handle, "jobId", id); Set(env, handle, "completion", promise);
        napi_value name; Ok(napi_create_string_utf8(env, "AMCL_EXPORT_NATIVE_V1", NAPI_AUTO_LENGTH, &name));
        // registry分配先于SDK work创建。若emplace抛出，尚无SDK句柄，RAII即可完全收回fd。
        context->jobs.emplace(id, work->job);
        napi_status status = napi_create_async_work(env, nullptr, name, Execute, Complete, work.get(), &work->work);
        if (status == napi_ok) status = napi_queue_async_work(env, work->work);
        if (status != napi_ok) {
            work->job->pendingCleanup = work->work; work->work = nullptr;
            try { work->hashFd.closeChecked(); }
            catch (const Failure& error) { work->job->core.fail(error.code, error.what(), error.nativeCode); }
            work->job->core.fail("BridgeError", "export async job could not be queued"); work->job->core.finish();
            SettleSdk(env, *work->job);
            // 记录可能尚未插入；幂等release仍必须能识别已经正常撤销的合法id。
            if (work->job->core.settled) {
                Deliver(env, *work->job);
                if (!work->job->pendingDelivery && !work->job->deliveryFailed) {
                    // receipt分配失败保留已有registry，不会为了错误分支再分配另一份owner。
                    try { context->retire(id); context->jobs.erase(id); } catch (...) {}
                }
            }
            return handle;
        }
        (void)work.release(); return handle;
    } catch (const Failure& error) { Throw(env, error.code, error.what()); }
    catch (const std::exception& error) { Throw(env, "NativeError", error.what()); }
    catch (...) { Throw(env, "NativeError", "export start failed"); }
    return nullptr;
}
napi_value WriteStart(napi_env e, napi_callback_info i) { return Start(e, i, "write"); }
napi_value VerifyStart(napi_env e, napi_callback_info i) { return Start(e, i, "verify"); }
napi_value HashStart(napi_env e, napi_callback_info i) { return Start(e, i, "hash"); }
napi_value Query(napi_env env, napi_callback_info info) {
    try {
        napi_value argument; auto context = Owner(env, info, argument); const auto id = Integer(env, argument, 1, kSafeInteger);
        const auto found = context->jobs.find(id);
        // NAPI对象准备和Promise微任务都可重入；固定shared owner，不跨NAPI持有map iterator。
        const auto job = found == context->jobs.end() ? std::shared_ptr<Job>{} : found->second;
        // Parent在等待completion期间每125ms query；该owner入口重试SDK回收，不依赖尚未开始的release。
        if (job) {
            if (job->pendingCleanup) SettleSdk(env, *job);
            Deliver(env, *job);
        }
        const bool exists = context->jobs.find(id) != context->jobs.end();
        const auto value = Object(env);
        const bool retired = !exists && context->wasRetired(id); Number(env, value, "jobId", id); Boolean(env, value, "exists", exists); Boolean(env, value, "released", retired);
        const auto* core = exists && job ? &job->core : nullptr;
        String(env, value, "operation", core ? job->operation : ""); String(env, value, "state", core ? StateName(core->state.load()) : retired ? "released" : "unknown");
        Number(env, value, "filesDone", core ? core->filesDone.load() : 0); Number(env, value, "filesTotal", core ? core->filesTotal.load() : 0);
        Number(env, value, "bytesDone", core ? core->bytesDone.load() : 0); Number(env, value, "bytesTotal", core ? core->bytesTotal.load() : 0);
        Number(env, value, "archiveBytes", core ? core->archiveBytes.load() : 0); Boolean(env, value, "settled", core ? core->settled.load() : retired);
        std::string code, message; if (core) core->error(code, message);
        if (core && job->deliveryFailed) {
            message = "Promise deferred consumed once; SDK status=" + std::to_string(job->deliveryStatus) + "; original=" + code + ": " + message;
            code = "DeliveryFailed";
        }
        String(env, value, "errorCode", code); String(env, value, "errorMessage", message); return value;
    } catch (const Failure& error) { Throw(env, error.code, error.what()); } catch (...) { Throw(env, "NativeError", "export query failed"); } return nullptr;
}
napi_value Cancel(napi_env env, napi_callback_info info) {
    try { napi_value argument; auto context = Owner(env, info, argument); const auto id = Integer(env, argument, 1, kSafeInteger);
        const auto found = context->jobs.find(id); const bool active = found != context->jobs.end() && !found->second->core.settled;
        if (active) found->second->core.cancel();
        napi_value value; Ok(napi_get_boolean(env, active, &value)); return value;
    } catch (const Failure& error) { Throw(env, error.code, error.what()); } catch (...) { Throw(env, "NativeError", "export cancel failed"); } return nullptr;
}
napi_value Release(napi_env env, napi_callback_info info) {
    try { napi_value argument; auto context = Owner(env, info, argument); const auto id = Integer(env, argument, 1, kSafeInteger);
        const auto found = context->jobs.find(id);
        const auto job = found == context->jobs.end() ? std::shared_ptr<Job>{} : found->second;
        bool released = false;
        if (!job) released = context->wasRetired(id);
        else if (job->core.settled || (job->pendingCleanup && SettleSdk(env, *job))) {
            Deliver(env, *job);
            if (!job->pendingDelivery && !job->delivering) {
                const auto current = context->jobs.find(id);
                if (current != context->jobs.end() && current->second == job) { context->retire(id); context->jobs.erase(current); released = true; }
                else released = context->wasRetired(id);
            }
        }
        napi_value value; Ok(napi_get_boolean(env, released, &value)); return value;
    } catch (const Failure& error) { Throw(env, error.code, error.what()); } catch (...) { Throw(env, "NativeError", "export release failed"); } return nullptr;
}
void Cleanup(napi_async_cleanup_hook_handle handle, void* data) {
    auto* holder = static_cast<Holder*>(data); auto context = holder->context;
    context->closing.store(true, std::memory_order_release);
    context->cleanupOwner = holder; context->cleanupHandle = handle;
    for (auto& pair : context->jobs) {
        pair.second->core.cancel();
        if (pair.second->pendingCleanup) SettleSdk(context->env, *pair.second);
    }
    FinishCleanup(context);
}
}
void registerExportNapi(napi_env env, napi_value exports) {
    try {
    auto holder = std::make_unique<Holder>(); holder->context = std::make_shared<Context>(); holder->context->env = env;
    napi_property_descriptor methods[] = {
        {"exportArchiveStart", nullptr, WriteStart, nullptr, nullptr, nullptr, napi_default, holder.get()},
        {"exportArchiveVerifyStart", nullptr, VerifyStart, nullptr, nullptr, nullptr, napi_default, holder.get()},
        {"exportFileHashStart", nullptr, HashStart, nullptr, nullptr, nullptr, napi_default, holder.get()},
        {"exportJobQuery", nullptr, Query, nullptr, nullptr, nullptr, napi_default, holder.get()},
        {"exportJobCancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, holder.get()},
        {"exportJobRelease", nullptr, Release, nullptr, nullptr, nullptr, napi_default, holder.get()},
    };
    if (napi_add_async_cleanup_hook(env, Cleanup, holder.get(), nullptr) != napi_ok) { Throw(env, "BridgeError", "export async env cleanup registration failed"); return; }
    auto* registered = holder.release(); // cleanup hook现在唯一拥有holder；注册失败也由同一env收回。
    const auto status = napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
    if (status != napi_ok) { registered->context->closing = true; Throw(env, "BridgeError", "export API registration failed"); }
    } catch (...) { Throw(env, "NativeError", "export API registration allocation failed"); }
}
} // namespace amcl::napi
