/* 正常动态加载HAP侧实际C源的独立DSO，所有typed地址和只读table必须属于该映像。
 * 用共享POD驱动真实六个回调，核对帧、事件、错误、Capture和owner撤销；不替换回调函数。
 * 宿主sanitizer验证内存/并发协议，不借此声称商业系统CFI或物理音频已经通过。
 */
#define _GNU_SOURCE
#include <assert.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../entry/src/main/cpp/javasound/ohos_daudio_callbacks.h"

static const AmclDAudioCallbackAbiV2* api;
static unsigned checks;
static void same_image(const void* address, void* expected) {
    Dl_info info;
    assert(dladdr(address, &info) && info.dli_fbase == expected);
    ++checks;
}
static void reject_bad_abi(void) {
    assert(!amcl_daudio_callbacks_valid_v2(NULL));
    AmclDAudioCallbackAbiV2 copy;
#define BAD_FIELD(field) do { copy = *api; ++copy.field; assert(!amcl_daudio_callbacks_valid_v2(&copy)); ++checks; } while (0)
    BAD_FIELD(abiVersion); BAD_FIELD(tableSize); BAD_FIELD(layoutVersion); BAD_FIELD(lineSize);
    BAD_FIELD(contextSize); BAD_FIELD(ringSize); BAD_FIELD(lineAlignment); BAD_FIELD(contextAlignment);
    BAD_FIELD(timelineSize); BAD_FIELD(timelineAlignment);
#undef BAD_FIELD
#define NULL_FIELD(field) do { copy = *api; copy.field = NULL; assert(!amcl_daudio_callbacks_valid_v2(&copy)); ++checks; } while (0)
    NULL_FIELD(renderData); NULL_FIELD(renderError); NULL_FIELD(renderInterrupt);
    NULL_FIELD(captureData); NULL_FIELD(captureError); NULL_FIELD(captureInterrupt);
#undef NULL_FIELD
}
static void playback(void) {
    unsigned char ring[32], data[18];
    for (unsigned i = 0; i < sizeof(ring); ++i) ring[i] = (unsigned char)i;
    AmclLine line = {0};
    AmclPlaybackTimeline timeline = {0};
    AmclCallback context = {0};
    line.isSource = 1; line.capacity = sizeof(ring); line.frameSize = 4;
    line.ring = ring; line.read = 28; line.written = 44; line.copyEnabled = 1;
    line.playback = &timeline;
    context.owner = &line; line.callback = &context;
    memset(data, 0xcc, sizeof(data));
    assert(api->renderData(NULL, &context, data, sizeof(data)) == 16);
    for (unsigned i = 0; i < 16; ++i) assert(data[i] == ring[(i + 28) % 32]);
    assert(data[16] == 0xcc && data[17] == 0xcc && line.read == 44);
    assert(amcl_playback_observe(&timeline, 4) == 4);
    assert(api->renderData(NULL, &context, data, sizeof(data)) == 0 && context.active == 0);
    line.written = 60;
    api->renderInterrupt(NULL, &context, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_PAUSE);
    assert(api->renderData(NULL, &context, data, sizeof(data)) == 0 && line.read == 44);
    api->renderInterrupt(NULL, &context, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_RESUME);
    assert(api->renderData(NULL, &context, data, sizeof(data)) == 16 && line.read == 60);
    api->renderInterrupt(NULL, &context, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_DUCK);
    assert(line.ducked == 1);
    api->renderInterrupt(NULL, &context, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_UNDUCK);
    assert(line.ducked == 0);
    api->renderError(NULL, &context, AUDIOSTREAM_SUCCESS);
    const int original = line.error;
    assert(original == AUDIOSTREAM_ERROR_ILLEGAL_STATE);
    api->renderError(NULL, &context, AUDIOSTREAM_ERROR_SYSTEM);
    assert(line.error == original && context.active == 0);
    context.owner = NULL;
    assert(api->renderData(NULL, &context, data, sizeof(data)) == 0);
    api->renderError(NULL, &context, AUDIOSTREAM_ERROR_SYSTEM);
    api->renderInterrupt(NULL, &context, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_STOP);
    assert(context.active == 0);
    checks += 12;
}
static void capture(void) {
    AmclLine line = {0};
    AmclCallback context = {0};
    unsigned char data[32], received[32];
    for (unsigned i = 0; i < sizeof(data); ++i) data[i] = (unsigned char)(i + 40);
    assert(amcl_capture_init(&line.capture, 64, 4, 16));
    line.copyEnabled = 1; context.owner = &line; line.callback = &context;
    api->captureData(NULL, &context, data, sizeof(data));
    assert(amcl_capture_read(&line.capture, received, sizeof(received)) == (int)sizeof(data));
    assert(memcmp(data, received, sizeof(data)) == 0 && context.active == 0);
    api->captureInterrupt(NULL, &context, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_MUTE);
    api->captureData(NULL, &context, data, 16);
    assert(amcl_capture_available(&line.capture) == 0);
    api->captureInterrupt(NULL, &context, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_UNMUTE);
    api->captureData(NULL, &context, data, 16);
    assert(amcl_capture_available(&line.capture) == 16);
    api->captureData(NULL, &context, data, 18);
    assert(line.error == AUDIOSTREAM_ERROR_ILLEGAL_STATE);
    api->captureError(NULL, &context, AUDIOSTREAM_ERROR_SYSTEM);
    assert(line.error == AUDIOSTREAM_ERROR_ILLEGAL_STATE);
    context.owner = NULL;
    amcl_capture_destroy(&line.capture);
    api->captureData(NULL, &context, data, 16);
    api->captureError(NULL, &context, AUDIOSTREAM_ERROR_SYSTEM);
    api->captureInterrupt(NULL, &context, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_STOP);
    assert(context.active == 0);
    checks += 8;
}

static int running, ready;
static void* late_worker(void* opaque) {
    AmclCallback* context = opaque;
    unsigned char data[16];
    __atomic_store_n(&ready, 1, __ATOMIC_RELEASE);
    while (__atomic_load_n(&running, __ATOMIC_ACQUIRE))
        assert(api->renderData(NULL, context, data, sizeof(data)) == 0);
    // owner已撤销后继续真实跨DSO回调，证明不再访问已free的line/ring。
    for (int i = 0; i < 10000; ++i) assert(api->renderData(NULL, context, data, sizeof(data)) == 0);
    return NULL;
}
static void revoke_owner(void) {
    AmclLine* line = calloc(1, sizeof(*line));
    AmclCallback context = {0};
    assert(line);
    line->ring = calloc(1, 32); assert(line->ring);
    line->playback = calloc(1, sizeof(*line->playback)); assert(line->playback);
    line->capacity = 32; line->frameSize = 4; line->copyEnabled = 1;
    context.owner = line; line->callback = &context;
    running = 1; ready = 0;
    pthread_t worker; assert(pthread_create(&worker, NULL, late_worker, &context) == 0);
    while (!__atomic_load_n(&ready, __ATOMIC_ACQUIRE)) sched_yield();
    __atomic_store_n(&context.owner, NULL, __ATOMIC_SEQ_CST);
    while (__atomic_load_n(&context.active, __ATOMIC_SEQ_CST)) sched_yield();
    free(line->ring); free(line->playback); free(line);
    __atomic_store_n(&running, 0, __ATOMIC_RELEASE);
    assert(pthread_join(worker, NULL) == 0 && context.active == 0);
    ++checks;
}
int main(int argc, char** argv) {
    assert(argc == 2);
    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    assert(library);
    const AmclDAudioCallbackAbiV2* (*get)(void) = (const AmclDAudioCallbackAbiV2* (*)(void))dlsym(library, "amcl_javasound_callbacks_v2");
    assert(get);
    api = get();
    assert(amcl_daudio_callbacks_valid_v2(api));
    Dl_info owner; assert(dladdr((void*)get, &owner));
    same_image(api, owner.dli_fbase);
    same_image((void*)api->renderData, owner.dli_fbase);
    same_image((void*)api->renderError, owner.dli_fbase);
    same_image((void*)api->renderInterrupt, owner.dli_fbase);
    same_image((void*)api->captureData, owner.dli_fbase);
    same_image((void*)api->captureError, owner.dli_fbase);
    same_image((void*)api->captureInterrupt, owner.dli_fbase);
    reject_bad_abi(); playback(); capture(); revoke_owner();
    assert(dlclose(library) == 0);
    printf("PASS signed-host callback source/ABI: %u checks, six real DSO callbacks, complete frames, capture, first error, detached late callbacks; host sanitizer only\n", checks);
}
