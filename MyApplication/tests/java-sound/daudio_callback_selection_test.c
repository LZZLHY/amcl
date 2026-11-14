/* 真正DAUDIO_Open的宿主选择回归；平台仅替换OHAudio，版本/映像/租约仍用真实dl接口。 */
#define amcl_test_run amcl_original_backend_test
#include "daudio_backend_test.c"
#undef amcl_test_run
#include <dlfcn.h>
#include "ohos_daudio_callbacks.h"

int amcl_selection_test(int accepted)
{
    void *line;
    unsigned char input[16], output[32];
    const AmclDAudioCallbackAbiV2 *(*factory)(void);
    const AmclDAudioCallbackAbiV2 *table;
    for (unsigned i = 0; i < sizeof(input); ++i) input[i] = (unsigned char)(i + 11);
    line = open_line();
    if (!accepted) {
        assert(!line && !builders && !renderers && !capturers && !current);
        puts("PASS incompatible/missing/foreign host callbacks rejected before Generate");
        return 0;
    }
    assert(line);
    factory = (const AmclDAudioCallbackAbiV2 *(*)(void))dlsym(RTLD_DEFAULT, "amcl_javasound_callbacks_v2");
    assert(factory); table = factory();
    assert(current->config.data == table->renderData && current->config.error == table->renderError &&
           current->config.interrupt == table->renderInterrupt);
    /* 宿主入口确实消费libjsound所有的POD/PCM；不能仅证明返回表存在。 */
    assert(DAUDIO_Write(line, (char *)input, sizeof(input)) == sizeof(input));
    assert(DAUDIO_Start(line, TRUE));
    assert(pump(current, output, sizeof(output)) == sizeof(output) && !memcmp(input, output, sizeof(input)));
    for (unsigned i = sizeof(input); i < sizeof(output); ++i) assert(output[i] == 0);
    DAUDIO_Close(line, TRUE); clean();
    captureRoutePresent = 1;
    line = DAUDIO_Open(0, 0, FALSE, DAUDIO_PCM, 48000, 16, 4, 2, TRUE, FALSE, 32);
    assert(line && currentCapture->config.captureData == table->captureData &&
           currentCapture->config.captureError == table->captureError &&
           currentCapture->config.captureInterrupt == table->captureInterrupt);
    assert(DAUDIO_Start(line, FALSE));
    currentCapture->config.captureData(currentCapture, currentCapture->config.opaque, input, sizeof(input));
    assert(DAUDIO_Read(line, (char *)output, sizeof(output)) == sizeof(input) && !memcmp(input, output, sizeof(input)));
    DAUDIO_Close(line, FALSE); captureRoutePresent = 0; assert(!capturers && !currentCapture);
    puts("PASS actual DAUDIO uses host six typed callbacks; playback/capture bytes and normal close");
    /* 最后保留原完整并发/关闭故障回归，故意Release失败后主程序独立核两个DSO引用。 */
    return amcl_original_backend_test();
}
