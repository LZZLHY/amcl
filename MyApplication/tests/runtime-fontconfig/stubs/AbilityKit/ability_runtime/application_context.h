/* 仅用于 Linux 宿主边界测试；目标编译使用实际 SDK 头，并在生产探针中 static_assert 签名。
 * 此替身不证明 HarmonyOS 上存在 Context 或文件权限。 */
#pragma once
#include <stdint.h>
typedef enum {
    ABILITY_RUNTIME_ERROR_CODE_NO_ERROR = 0,
    ABILITY_RUNTIME_ERROR_CODE_PARAM_INVALID = 401,
    ABILITY_RUNTIME_ERROR_CODE_CONTEXT_NOT_EXIST = 16000011
} AbilityRuntime_ErrorCode;
#ifdef __cplusplus
extern "C" {
#endif
AbilityRuntime_ErrorCode OH_AbilityRuntime_ApplicationContextGetCacheDir(char*, int32_t, int32_t*);
#ifdef __cplusplus
}
#endif
