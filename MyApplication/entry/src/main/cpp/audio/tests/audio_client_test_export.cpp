/** 仅测试跨动态链接namespace发现宿主：不包含核心、不创建owner。 */
#include "../audio_client.h"
#include <cstdlib>
extern "C" __attribute__((visibility("default"))) const AmclAudioApiV1 *testResolveAudio() {
    return amcl::audio::resolveAudioHost();
}
/** glibc dlmopen具有独立libc.environ；测试显式镜像早发布值以模拟OHOS稳定进程环境。 */
extern "C" __attribute__((visibility("default"))) void testInstallAudioDiscovery(const char *text) {
    setenv(AMCL_AUDIO_HOST_ENV, text, 1);
}
