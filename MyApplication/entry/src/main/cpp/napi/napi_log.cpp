/**
 * napi_log.cpp — AMCL 日志系统 NAPI 实现
 */
#include "napi_log.h"
#include "napi_helpers.h"

#include "../utils/amcl_log.h"
#include <vector>
#include <algorithm>
#include <cmath>
#include <memory>
#include <new>

namespace {

napi_value AmclLogInit(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char logDir[512] = {0};
    size_t len = 0;
    napi_get_value_string_utf8(env, args[0], logDir, sizeof(logDir), &len);

    int32_t maxFileSize = 2 * 1024 * 1024;  // 默认 2MB
    int32_t maxFiles = 5;
    if (argc > 1) napi_get_value_int32(env, args[1], &maxFileSize);
    if (argc > 2) napi_get_value_int32(env, args[2], &maxFiles);

    amclLogInit(logDir, maxFileSize, maxFiles);

    return amcl::napi::MakeUndefined(env);
}

napi_value AmclLogShutdown(napi_env env, napi_callback_info info) {
    amclLogShutdown();
    return amcl::napi::MakeUndefined(env);
}

napi_value AmclLogRead(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t maxBytes = 32768;  // 默认 32KB
    if (argc > 0) napi_get_value_int32(env, args[0], &maxBytes);

    return amcl::napi::WrapStringResult(env, amclLogRead(maxBytes));
}

napi_value AmclLogFlush(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_get_boolean(env, amclLogFlushChecked() != 0, &result);
    return result;
}

/** 状态为稳定 JSON 字段，读取不触发写入或阻塞，失败由 ArkTS 按健康状态展示。 */
napi_value AmclLogGetStatus(napi_env env, napi_callback_info info) {
    return amcl::napi::WrapStringResult(env, amclLogGetStatus());
}

napi_value AmclLogGetPath(napi_env env, napi_callback_info info) {
    return amcl::napi::WrapStringResult(env, amclLogGetPath());
}

// ArkTS -> 持久化日志文件。签名: amclLogWrite(level:int, tag:string, message:string)
// level 对应 AmclLogLevel（0=DEBUG, 1=INFO, 2=WARN, 3=ERROR, 4=FATAL）
napi_value AmclLogWrite(napi_env env, napi_callback_info info) {
    // 2026-07-30（活动账本 · L1-a）：第 4 个可选参数 activityId。
    // ArkTS 侧**必须显式传**归属活动 —— 单 JS 线程上多个活动 async 交错，
    // native 的线程本地归属在这里会串味（详见 amcl_log.h 的说明）。
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t level = AMCL_LOG_LEVEL_INFO;
    if (argc >= 1) napi_get_value_int32(env, args[0], &level);

    // 先查询 UTF-8 字节数；桥层不再把完整堆栈静默缩成 4 KiB。
    // 单条极端输入的安全上限由统一 writer 执行并记录缺口。
    char tag[64] = {0};
    size_t len = 0;
    if (argc >= 2) napi_get_value_string_utf8(env, args[1], tag, sizeof(tag), &len);
    size_t messageLength = 0;
    if (argc >= 3) napi_get_value_string_utf8(env, args[2], nullptr, 0, &messageLength);
    // 在跨语言分配前限制大小；额外留完整 UTF-8 字符的四字节，保证桥层裁掉尾部时
    // 实际传给 writer 的正文仍大于 1 MiB，统一截断计数不会因字符边界回退而漏报。
    const size_t boundedLength = std::min(messageLength, static_cast<size_t>(1024 * 1024 + 4));
    std::vector<char> message(boundedLength + 1, '\0');
    if (argc >= 3) napi_get_value_string_utf8(env, args[2], message.data(), message.size(), &len);

    // activityId 用 double 收（JS number 是 double；毫秒时间戳 1.7e12 远在 2^53 内，无精度损失）
    double activityIdRaw = 0;
    if (argc >= 4) napi_get_value_double(env, args[3], &activityIdRaw);
    long long activityId = static_cast<long long>(activityIdRaw);

    // amclLogWrite 接受 printf 风格 fmt —— 这里 msg 已经是最终字符串，用 "%s" 转义
    // 防止 msg 里的 % 被当作格式化 specifier 误解析。
    amclLogWriteFor(activityId, (AmclLogLevel)level, tag[0] ? tag : "ArkTS", "%s", message.data());

    return amcl::napi::MakeUndefined(env);
}

// 签名: amclLedgerBegin(activityId:number, dir:string): boolean
napi_value AmclLedgerBegin(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double idRaw = 0;
    if (argc >= 1) napi_get_value_double(env, args[0], &idRaw);
    char dir[512] = {0};
    size_t len = 0;
    if (argc >= 2) napi_get_value_string_utf8(env, args[1], dir, sizeof(dir), &len);

    int ok = amclLedgerBegin(static_cast<long long>(idRaw), dir);
    napi_value out;
    napi_get_boolean(env, ok != 0, &out);
    return out;
}

// 签名: amclLedgerEnd(activityId:number): void
napi_value AmclLedgerEnd(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double idRaw = 0;
    if (argc >= 1) napi_get_value_double(env, args[0], &idRaw);
    amclLedgerEnd(static_cast<long long>(idRaw));
    return amcl::napi::MakeUndefined(env);
}

/**
 * 单次 scope 关闭工作。只保存数值主键和 NAPI 管理的 promise/work 句柄，
 * 不持有 ArkUI/Ability 对象或 napi_ref；成功排队后由 complete 唯一释放本结构。
 */
struct LedgerEndWork {
    long long activityId = 0;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    bool closed = false;
};

/** 取出本次SDK错误留下的异常；先清pending状态，后续reject才允许进入NAPI。 */
bool takeLedgerException(napi_env env, napi_value* value) {
    bool pending = false;
    return napi_is_exception_pending(env, &pending) == napi_ok && pending
        && napi_get_and_clear_last_exception(env, value) == napi_ok && *value != nullptr;
}

/** 只能在创建/完成的 JS 线程调用。错误构造本身可能留下pending exception，须取出清理后
 * 用原异常拒绝；只有没有异常值时才退回undefined/null。deferred只提交一次：SDK在
 * resolve/reject内部可能已经消费它，不能看到非ok后再用相同deferred重试造成二次释放。
 */
void rejectLedgerEnd(napi_env env, napi_deferred deferred, const char* message) {
    napi_value text = nullptr;
    napi_value error = nullptr;
    if (!takeLedgerException(env, &error)) {
        if (napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &text) != napi_ok
            || napi_create_error(env, nullptr, text, &error) != napi_ok) {
            error = nullptr;
            (void)takeLedgerException(env, &error);
        }
    }
    if (error == nullptr && napi_get_undefined(env, &error) != napi_ok) {
        error = nullptr;
        if (!takeLedgerException(env, &error)) (void)napi_get_null(env, &error);
    }
    if (error != nullptr) (void)napi_reject_deferred(env, deferred, error);
}

/** 工作线程只调用原生 writer 关闭协议，不触碰 env、JS 值或 UI 状态。 */
void executeLedgerEnd(napi_env, void* data) {
    auto* task = static_cast<LedgerEndWork*>(data);
    try { task->closed = amclLedgerEndChecked(task->activityId) != 0; }
    catch (...) { task->closed = false; } // C++ 异常不得穿越 NAPI 工作回调边界。
}

/** 成功、取消或原生失败都回到 owner 线程完成，并成对删除异步工作和 native 数据。 */
void completeLedgerEnd(napi_env env, napi_status status, void* data) {
    std::unique_ptr<LedgerEndWork> task(static_cast<LedgerEndWork*>(data));
    if (env == nullptr) return; // 环境销毁后不调用 JS API；native 数据仍由 RAII 释放。
    napi_value pending = nullptr;
    // get_undefined本身不检查lastException，但resolve的SDK入口会检查；必须在settlement前
    // 处理原异常，不能等resolve失败后重用一个可能已消费的deferred。
    if (takeLedgerException(env, &pending)) {
        (void)napi_reject_deferred(env, task->deferred, pending);
    } else if (status == napi_ok && task->closed) {
        napi_value result = nullptr;
        if (napi_get_undefined(env, &result) == napi_ok) (void)napi_resolve_deferred(env, task->deferred, result);
        else rejectLedgerEnd(env, task->deferred, "活动日志关闭结果无法发布，请稍后重试");
    } else {
        rejectLedgerEnd(env, task->deferred, "活动日志尚未完成有序关闭，原件已保留，请稍后重试");
    }
    if (task->work != nullptr) (void)napi_delete_async_work(env, task->work);
}

/** ArkTS → Promise<void>：UI线程只校验和排队，writer关闭等待在工作线程执行。
 * 条件变量的单轮等待预算为500ms；互斥锁、stdio与状态持久写不据此宣称相同总耗时上限。
 * queue/create 失败仍返回已拒绝 promise；排队前数据由 unique_ptr 管理，失败不会遗留 work。
 */
napi_value AmclLedgerEndAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    double id = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1
        || napi_get_value_double(env, args[0], &id) != napi_ok || !std::isfinite(id)
        || id <= 0 || id > 9007199254740991.0 || std::floor(id) != id) {
        (void)napi_throw_type_error(env, nullptr, "活动主键必须是有效的正安全整数");
        return nullptr;
    }
    std::unique_ptr<LedgerEndWork> task(new (std::nothrow) LedgerEndWork());
    if (!task) { (void)napi_throw_error(env, nullptr, "活动日志异步关闭分配失败"); return nullptr; }
    task->activityId = static_cast<long long>(id);
    napi_value promise = nullptr;
    if (napi_create_promise(env, &task->deferred, &promise) != napi_ok) {
        (void)napi_throw_error(env, nullptr, "活动日志异步关闭无法创建完成凭据"); return nullptr;
    }
    napi_value resource = nullptr;
    napi_status status = napi_create_string_utf8(env, "amclLedgerEndAsync", NAPI_AUTO_LENGTH, &resource);
    if (status == napi_ok) status = napi_create_async_work(env, nullptr, resource, executeLedgerEnd,
        completeLedgerEnd, task.get(), &task->work);
    if (status == napi_ok) status = napi_queue_async_work(env, task->work);
    if (status != napi_ok) {
        if (task->work != nullptr) (void)napi_delete_async_work(env, task->work);
        rejectLedgerEnd(env, task->deferred, "活动日志异步关闭未能排队，原件已保留");
    } else {
        (void)task.release(); // 只在SDK接管工作后移交；complete是此后唯一native数据释放者。
    }
    return promise;
}

// 签名: amclLedgerEndAll(): void
napi_value AmclLedgerEndAll(napi_env env, napi_callback_info info) {
    amclLedgerEndAll();
    return amcl::napi::MakeUndefined(env);
}

// 签名: amclLedgerUnbindTask(taskId:number): void
// 任务终态时解绑，避免 32 槽关联表被占满 —— 一次 MC 版本下载会创建 3+ 个 native
// 任务（client.jar / libraries / assets），只绑不解十来次下载就填满，之后新关联被
// 静默丢弃、DL_MULTI 日志再也归属不上。（2026-08-01 自审发现的缺陷 2）
napi_value AmclLedgerUnbindTask(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double idRaw = 0;
    if (argc >= 1) napi_get_value_double(env, args[0], &idRaw);
    amclLedgerUnbindTask(static_cast<unsigned long long>(idRaw));
    return amcl::napi::MakeUndefined(env);
}

// 签名: amclLedgerSetLaunchActivity(activityId:number): void
// 设置后续 MC 启动线程的日志归属（游戏会话账本，L3）
napi_value AmclLedgerSetLaunchActivity(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double idRaw = 0;
    if (argc >= 1) napi_get_value_double(env, args[0], &idRaw);
    amclLedgerSetLaunchActivity(static_cast<long long>(idRaw));
    return amcl::napi::MakeUndefined(env);
}

// 签名: amclLedgerBindTask(taskId:number, activityId:number): void
// activityId 传 0 = 解除关联
napi_value AmclLedgerBindTask(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double taskRaw = 0;
    double actRaw = 0;
    if (argc >= 1) napi_get_value_double(env, args[0], &taskRaw);
    if (argc >= 2) napi_get_value_double(env, args[1], &actRaw);
    amclLedgerBindTask(static_cast<unsigned long long>(taskRaw),
                       static_cast<long long>(actRaw));
    return amcl::napi::MakeUndefined(env);
}

#define NAPI_FUNC(name, fn) \
    { name, nullptr, fn, nullptr, nullptr, nullptr, napi_default, nullptr }

constexpr napi_property_descriptor kLogDescriptors[] = {
    NAPI_FUNC("amclLogInit",     AmclLogInit),
    NAPI_FUNC("amclLogShutdown", AmclLogShutdown),
    NAPI_FUNC("amclLogRead",     AmclLogRead),
    NAPI_FUNC("amclLogFlush",    AmclLogFlush),
    NAPI_FUNC("amclLogGetStatus", AmclLogGetStatus),
    NAPI_FUNC("amclLogGetPath",  AmclLogGetPath),
    NAPI_FUNC("amclLogWrite",    AmclLogWrite),
    // 活动账本（L1-a）
    NAPI_FUNC("amclLedgerBegin",  AmclLedgerBegin),
    NAPI_FUNC("amclLedgerEnd",    AmclLedgerEnd),
    NAPI_FUNC("amclLedgerEndAsync", AmclLedgerEndAsync),
    NAPI_FUNC("amclLedgerEndAll", AmclLedgerEndAll),
    NAPI_FUNC("amclLedgerBindTask", AmclLedgerBindTask),
    NAPI_FUNC("amclLedgerUnbindTask", AmclLedgerUnbindTask),
    NAPI_FUNC("amclLedgerSetLaunchActivity", AmclLedgerSetLaunchActivity),
};

#undef NAPI_FUNC

} // anonymous namespace

namespace amcl::napi {

void registerLogNapi(napi_env env, napi_value exports) {
    napi_define_properties(env, exports,
                           sizeof(kLogDescriptors) / sizeof(kLogDescriptors[0]),
                           kLogDescriptors);
}

} // namespace amcl::napi
