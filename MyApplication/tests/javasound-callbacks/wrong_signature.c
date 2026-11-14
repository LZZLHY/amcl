/* 必须编译失败的边界对照：renderer高级回调返回int32_t，不能用void签名或强转混过。 */
#define _GNU_SOURCE
#include "../../entry/src/main/cpp/javasound/ohos_daudio_callbacks.h"
static void wrong_result(OH_AudioRenderer* renderer, void* opaque, void* data, int32_t size) {
    (void)renderer; (void)opaque; (void)data; (void)size;
}
OH_AudioRenderer_OnWriteDataCallbackAdvanced must_reject = wrong_result;
