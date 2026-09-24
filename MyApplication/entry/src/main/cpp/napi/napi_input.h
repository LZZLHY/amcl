/**
 * napi_input.h — 输入事件 / 控件区域 / XComponent 尺寸 NAPI 注册
 *
 * ⚠️ **这里曾有一份"暴露给 ArkTS 的方法"清单，已删除。** 它同时犯了两个方向的错：
 *
 *   - **列了已删除的入口**：`registerButton` / `registerJoystick` / `clearButtons` /
 *     `clearJoystick` 四个连同 native 侧的 legacy 矩形表在 §38.3 整体删除了
 *     （那是一条只写不读的活跃路径 —— 唯一读取方在 `s_schemaActive` 永为 true 造成的
 *     不可达分支里，而 ArkTS 每次布局重建都在跨语言填它）。照那份清单会去调不存在的方法。
 *   - **漏了绝大多数现存入口**：清单 15 项，实际注册 55 项。整组 `physical*Transaction`、
 *     `sendSource*`（按端申报）、光标锁、窗口过滤器、不变量心跳、census 打点全部缺席。
 *
 * 一份需要手工同步、且已经漂移到 15/55 的清单，比没有清单更容易误导 ——
 * 这正是 `输入架构规范.md` §八 第六条纪律的又一个实例。
 *
 * **权威来源只有两处，都是机器可校验的**：
 *   - `kInputDescriptors`（本模块 .cpp 末尾）—— 唯一的注册真相；
 *   - `cpp/types/libentry/index.d.ts` —— ArkTS 侧的类型契约，逐项带用法与单位说明。
 *
 * 两者的一致性由 `scripts/check-napi-obfuscation.mjs` 与 ArkTS 编译共同保证；
 * 要看"有哪些方法、怎么调"请读那两处，不要在本文件重建第三份清单。
 */
#pragma once

#include <napi/native_api.h>

namespace amcl::napi {

void registerInputNapi(napi_env env, napi_value exports);

} // namespace amcl::napi
