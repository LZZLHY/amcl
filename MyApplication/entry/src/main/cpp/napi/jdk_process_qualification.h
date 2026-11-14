/** TestHooks专用：固定NCP退出动作矩阵及现有签名PIE/PT_INTERP执行观测。
 * 不启动Java，不接收任意命令或可执行路径；原始wait与NCP callbackSignal始终分开。
 */
#pragma once
#ifdef MC_OHOS_BUILD_TESTS
#include <napi/native_api.h>
/** filesDir、nonce、完成回调。回调中的 SDK 数值保持 callbackSignal，绝不解释成 waitpid 状态。 */
napi_value RunJdkProcessQualificationNapi(napi_env env, napi_callback_info info);
#endif
