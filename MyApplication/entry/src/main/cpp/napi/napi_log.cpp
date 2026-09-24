/**
 * napi_log.cpp — AMCL 日志系统 NAPI 实现
 */
#include "napi_log.h"
#include "napi_helpers.h"

#include "../utils/amcl_log.h"
#include <vector>
#include <algorithm>

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
