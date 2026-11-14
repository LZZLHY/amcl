#pragma once
#ifdef MC_OHOS_BUILD_TESTS
#include <napi/native_api.h>
/** 异步、单进程一次的真实平台验证入口；只在 default/TestHooks 注册。 */
napi_value RunJdkPlatformProbeNapi(napi_env env, napi_callback_info info);
#endif
