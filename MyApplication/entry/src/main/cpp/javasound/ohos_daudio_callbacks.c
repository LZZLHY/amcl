/* 系统CFI可识别的正常HAP映像边界。实现留在此SDK编译的libentry中，不能把系统
 * callback转调到自加载libjsound。共享头的六个严格类型函数只访问版本化POD与PCM环。
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "ohos_daudio_callbacks.h"
#include "../audio/audio_runtime.h"
#include <stdlib.h>
#ifdef MC_OHOS_BUILD_TESTS
#include "ohos_capture_diagnostics.h"
#endif

__attribute__((visibility("default")))
const AmclDAudioCallbackAbiV2* amcl_javasound_callbacks_v2(void) {
    /* 新HAP在首个JVM线程前发布统一PCM owner。旧R12只请求回调表，却自行创建和启动
     * Capturer，无法执行录音意图/前台撤销；因此该组合必须在Generate前拒绝旧表。
     * 0033后的内建provider会先走共享owner；启动器SPI也继续使用同一owner。没有共享
     * owner的历史宿主/独立验证仍保留原ABI2，不能通过删除env把失效owner伪装为旧模式。
     */
    if (getenv(AMCL_AUDIO_HOST_ENV) != NULL) return NULL;
#ifdef MC_OHOS_BUILD_TESTS
    /* 仅固定资格入口显式arm时换用同映像的有界统计表，未arm仍是原产品表。 */
    return amcl_capture_diagnostics_callbacks(amcl_daudio_local_callbacks_v2());
#else
    return amcl_daudio_local_callbacks_v2();
#endif
}
