/**
 * napi_log.h — AMCL 日志系统 NAPI 注册
 *
 * 暴露给 ArkTS 的方法（与重构前 napi_entry.cpp 字面量逐字节一致）：
 *   - amclLogInit         — 初始化日志目录与轮转参数
 *   - amclLogShutdown     — 关闭日志（flush + 释放）
 *   - amclLogRead         — 读取最新日志尾部 N 字节
 *   - amclLogFlush        — 强制刷盘
 *   - amclLogGetPath      — 获取当前活动日志文件路径
 *   - amclLogWrite        — ArkTS 写入持久化日志（level/tag/message）
 */
#pragma once

#include <napi/native_api.h>

namespace amcl::napi {

void registerLogNapi(napi_env env, napi_value exports);

} // namespace amcl::napi
