/**
 * napi_helpers.h — NAPI 共享类型转换工具
 *
 * 由所有 napi/napi_*.cpp 模块共享。提供：
 *   - 读取 ArkTS 传入参数：ReadStringValue / ReadStringArrayValue / ReadStringArg
 *   - 包装 native 返回值：WrapStringResult / MakeIntResult / MakeBoolResult / MakeUndefined
 *
 * 历史：
 *   原本散在 napi_entry.cpp 内的 static 函数。重构后抽出到此处，
 *   消除 McLaunchWithProfile / McLaunchWithProfileV2 中 10 处复制粘贴的
 *   `napi_create_int32(env, -1, &fail); return fail;` 模式。
 *   详见 docs/guides/napi-layer-refactor-plan.md §五 Step 1。
 */
#pragma once

#include <napi/native_api.h>
#include <cstddef>
#include <string>
#include <vector>

namespace amcl::napi {

// 包装 C 字符串 → napi_value
napi_value WrapStringResult(napi_env env, const char* result);

// 读取 ArkTS string → std::string；失败返回 false
bool ReadStringValue(napi_env env, napi_value value, std::string& out);

// 读取 ArkTS string[] → std::vector<std::string>；失败返回 false
bool ReadStringArrayValue(napi_env env, napi_value value, std::vector<std::string>& out);

// 读取第一个 string 参数到 char buffer；返回是否成功（len > 0）
bool ReadStringArg(napi_env env, napi_callback_info info, char* buf, size_t bufSize);

// 创建 int32 napi_value（通常用于函数失败返回 -1）
napi_value MakeIntResult(napi_env env, int32_t value);

// 创建 boolean napi_value
napi_value MakeBoolResult(napi_env env, bool value);

// 创建 undefined napi_value（用于 void 返回的桥接）
napi_value MakeUndefined(napi_env env);

} // namespace amcl::napi
