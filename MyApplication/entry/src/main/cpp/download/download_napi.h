/**
 * download/download_napi.h — ArkTS ↔ DownloadEngine 桥接
 *
 * 暴露给 JS 的方法：
 *   downloadCreateTask(spec)         → number (taskId)
 *   downloadStart(taskId)            → boolean
 *   downloadCancel(taskId)           → boolean
 *   downloadOnProgress(taskId, cb)   → boolean
 *   downloadOnComplete(taskId, cb)   → boolean
 *   downloadListActive()             → TaskInfo[]
 *   downloadShutdown()               → void
 *
 * Spec 参数结构见 entry/src/main/cpp/types/libentry/index.d.ts
 *
 * 所有方法都是同步返回的。只有 onProgress / onComplete 的回调异步触发
 * （见 napi_bridge.h 的 threadsafe_function 机制）。
 */
#pragma once

#include <napi/native_api.h>

namespace download {

/**
 * 批量注册下载引擎相关 NAPI 方法到 `exports`。
 * 由 napi_entry.cpp 的 Init() 调用。
 */
void registerDownloadNapi(napi_env env, napi_value exports);

} // namespace download
