/** 自有音频政策的 NAPI 注册；原生麦克风权限查询不经过 JavaScript 回调。 */
#pragma once
#include <napi/native_api.h>
namespace amcl::napi {
void registerAudioNapi(napi_env env, napi_value exports);
}
