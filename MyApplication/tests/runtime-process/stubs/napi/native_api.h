// 仅补本测试使用的 SDK NAPI int32 声明；其他声明复用既有宿主 owner 替身。
// 正式 HAP 由真实 SDK 头编译，本目录不参与其 include 搜索。
#pragma once
#include "../../../jdk-probe/stubs/napi/native_api.h"
extern "C" {
napi_status napi_get_value_int32(napi_env, napi_value, int32_t*);
napi_status napi_create_int32(napi_env, int32_t, napi_value*);
}
