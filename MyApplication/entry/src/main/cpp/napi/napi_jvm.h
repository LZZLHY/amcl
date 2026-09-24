/**
 * napi_jvm.h — JVM / GPU / 下载引擎 probe 相关 NAPI 注册
 *
 * 暴露给 ArkTS 的方法（与重构前 napi_entry.cpp 字面量逐字节一致）：
 *   - jvmInit                  — JVM 嵌入式初始化
 *   - getGpuInfo               — GPU 厂商/型号字符串
 *   - getVulkanInfo            — Vulkan 能力探针报告（Phase 0，dlopen libvulkan 只读盘点）
 *   - getVulkanCapabilityJson  — Vulkan 能力门控 JSON（§十，ArkTS 选 26.2+ 时静默调用）
 *   - runVulkanSelfTest        — Vulkan 实战自检（Phase B，端到端 surface→swapchain→present）
 *   - runJvmEmbedTest          — JVM 完整诊断（异步回调）
 *   - isJvmTestRunning         — 当前是否有 JVM 测试在跑
 *   - checkJitAvailable        — JIT 权限检测
 *   - getCommonJvmArgs         — SSOT: amcl::getCommonJvmArgs() 暴露
 *   - downloadEngineProbe      — libcurl 加载验证（启动时 banner）
 *   - downloadEngineSelfTest   — libcurl curl_global_init 完整自检
 */
#pragma once

#include <napi/native_api.h>

namespace amcl::napi {

void registerJvmNapi(napi_env env, napi_value exports);

} // namespace amcl::napi
