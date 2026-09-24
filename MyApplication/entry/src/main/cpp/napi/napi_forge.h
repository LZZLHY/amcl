/**
 * napi_forge.h — Forge/NeoForge 安装 NAPI 注册（异步 fork+JVM）
 *
 * 暴露给 ArkTS 的方法：
 *   - runJavaProcessor — 异步执行单个 processor（干净 classpath 独立 JVM，返回 Promise<int>）
 */
#pragma once

#include <napi/native_api.h>

namespace amcl::napi {

void registerForgeNapi(napi_env env, napi_value exports);

} // namespace amcl::napi
