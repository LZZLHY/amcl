/* 只用于宿主选择负例的正常DSO。真实产品getter由ohos_daudio_callbacks.c构建。 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include "ohos_daudio_callbacks.h"
int amcl_jvm_is_embedded(void) { return 1; }

#if defined(AMCL_TEST_WRONG_ABI) || defined(AMCL_TEST_FOREIGN_CALLBACK)
const AmclDAudioCallbackAbiV2 *amcl_javasound_callbacks_v2(void)
{
    static AmclDAudioCallbackAbiV2 table;
    table = *amcl_daudio_local_callbacks_v2();
#ifdef AMCL_TEST_WRONG_ABI
    ++table.contextSize;
#else
    table.renderData = (OH_AudioRenderer_OnWriteDataCallbackAdvanced)dlsym(RTLD_DEFAULT, "amcl_foreign_render_data");
#endif
    return &table;
}
#endif
