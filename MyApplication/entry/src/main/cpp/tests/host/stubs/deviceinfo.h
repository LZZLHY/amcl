#pragma once

/** 宿主测试仅替代 SDK 的设备类型查询，保持其 C ABI。 */
#ifdef __cplusplus
extern "C" {
#endif
const char* OH_GetDeviceType(void);
#ifdef __cplusplus
}
#endif
