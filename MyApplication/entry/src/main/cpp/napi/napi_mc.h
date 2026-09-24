/**
 * napi_mc.h — Minecraft 启动器 NAPI 注册
 *
 * 暴露给 ArkTS 的方法：
 *   （⚰️ 2026-08-27：legacy "mcLaunch" 已退役，见 napi_mc.cpp 墓碑）
 *   - mcLaunchWithProfile      — v3 数据驱动启动（ArkTS 传入 LaunchProfile 字段）
 *   - mcLaunchWithProfileV2    — v4 参数协议（ArkTS 传 string[] 替代逗号拼接）
 *   - mcGetStatus              — 启动状态字符串
 *   - mcGetGraphicsLaunchFailure — 同线程同步图形失败快照（阶段、代码、进程重启边界）
 *   - mcCheckFiles             — 启动前文件完整性检查
 *   - mcIsRunning              — JVM 是否在运行
 *   - mcForceExit              — _exit 强制终止
 *   - mcReadLog                — 读 .minecraft/logs/latest.log 尾部
 *   - getDeviceMemoryMB        — 设备总内存
 *   - getRecommendedXmx        — 推荐 Xmx 值（基于设备内存）
 */
#pragma once

#include <napi/native_api.h>

namespace amcl::napi {

void registerMcNapi(napi_env env, napi_value exports);

} // namespace amcl::napi
