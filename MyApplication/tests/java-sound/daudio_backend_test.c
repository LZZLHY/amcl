/* 实际 DAUDIO C 源的协议回归；SDK 原头声明约束所有 OHAudio 替身签名。
 * 替身有独立的已提交/已呈现计数，禁止将消费环形缓冲误判为物理播放。 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audio_routing_manager.h>
#include "DirectAudio.h"
#include "ohos_daudio.h"

struct OH_AudioStreamBuilderStruct {
    OH_AudioStream_Type type;
    int32_t rate, channels;
    OH_AudioStream_SampleFormat format;
    OH_AudioStream_EncodingType encoding;
    OH_AudioStream_LatencyMode latency;
    OH_AudioRenderer_OnWriteDataCallbackAdvanced data;
    OH_AudioRenderer_OnErrorCallback error;
    OH_AudioRenderer_OnInterruptCallback interrupt;
    OH_AudioCapturer_OnReadDataCallback captureData;
    OH_AudioCapturer_OnErrorCallback captureError;
    OH_AudioCapturer_OnInterruptCallback captureInterrupt;
    void *opaque;
};
struct OH_AudioRendererStruct {
    struct OH_AudioStreamBuilderStruct config;
    OH_AudioStream_State state;
    int64_t written, presented, positionOrigin;
    float volume;
#ifdef AMCL_DAUDIO_REAL_JNI
    pthread_t worker;
    int quit;
#endif
};
struct OH_AudioCapturerStruct {
    struct OH_AudioStreamBuilderStruct config;
    OH_AudioStream_State state;
};
struct OH_AudioRoutingManager { int alive; };
struct OH_AudioDeviceDescriptor { int alive; };
static struct OH_AudioRoutingManager routing = {1};
static struct OH_AudioDeviceDescriptor speaker = {1};
static OH_AudioDeviceDescriptor *descriptor[] = { &speaker };
static OH_AudioDeviceDescriptorArray deviceArray = {1, descriptor};
static OH_AudioRenderer *current;
static OH_AudioCapturer *currentCapture;
static int capturers, captureRoutePresent, captureAllowed = 1;
static int builders, renderers, routePresent = 1, fastUnavailable, mismatch, releaseFailure;
static int releases, lateCallbacks, formats, forcePauseOnStart;
static int64_t delayFrames;
static int64_t reportedTimestamp = 1000000;
static const char *failure;
#ifdef AMCL_DAUDIO_REAL_JNI
static char failureText[80];
static void *automatic_pump(void *opaque);
/* 实际 Java/JNI 资格只允许控制既定平台失败点，不改变生产 DAUDIO 源或增加测试分支。 */
void amcl_mock_failure(const char *name)
{
    assert(strlen(name) < sizeof(failureText));
    strcpy(failureText, name); failure = *name ? failureText : NULL;
    if (!strcmp(name, "AsyncError") && current)
        current->config.error(current, current->config.opaque, AUDIOSTREAM_ERROR_SYSTEM);
    if (!strcmp(name, "CaptureAsyncError") && currentCapture)
        currentCapture->config.captureError(currentCapture, currentCapture->config.opaque, AUDIOSTREAM_ERROR_SYSTEM);
}
void amcl_mock_stats(int *values)
{ values[0] = builders; values[1] = renderers; values[2] = releases; values[3] = lateCallbacks; }
void amcl_mock_capture_configure(int route, int allowed)
{ assert(!capturers); captureRoutePresent = route; captureAllowed = allowed; }
void amcl_mock_capture_feed(void *data, int bytes)
{
    assert(currentCapture && currentCapture->state == AUDIOSTREAM_STATE_RUNNING);
    currentCapture->config.captureData(currentCapture, currentCapture->config.opaque, data, bytes);
}
void amcl_mock_capture_stats(int *values)
{ values[0] = builders; values[1] = capturers; values[2] = !!currentCapture; }
void amcl_mock_delay_frames(int frames)
{ assert(!renderers && frames >= 0); __atomic_store_n(&delayFrames, frames, __ATOMIC_SEQ_CST); }
#endif

/* 同一个 OHAudio 原型始终执行实际状态检查；只在指定操作处注入精确平台错误。 */
static OH_AudioStream_Result step(const char *name)
{
    if (failure && !strcmp(failure, "Pause+Release") && (!strcmp(name, "Pause") || !strcmp(name, "Release")))
        return AUDIOSTREAM_ERROR_SYSTEM;
    return failure && strcmp(failure, name) == 0 ? AUDIOSTREAM_ERROR_SYSTEM : AUDIOSTREAM_SUCCESS;
}

OH_AudioCommon_Result OH_AudioManager_GetAudioRoutingManager(OH_AudioRoutingManager **out)
{ *out = &routing; return AUDIOCOMMON_RESULT_SUCCESS; }
OH_AudioCommon_Result OH_AudioRoutingManager_GetPreferredOutputDevice(OH_AudioRoutingManager *m,
    OH_AudioStream_Usage usage, OH_AudioDeviceDescriptorArray **out)
{
    assert(m == &routing && usage == AUDIOSTREAM_USAGE_MUSIC);
    deviceArray.size = routePresent ? 1 : 0; *out = &deviceArray; return AUDIOCOMMON_RESULT_SUCCESS;
}
OH_AudioCommon_Result OH_AudioRoutingManager_ReleaseDevices(OH_AudioRoutingManager *m,
    OH_AudioDeviceDescriptorArray *out)
{ assert(m == &routing && out == &deviceArray); return AUDIOCOMMON_RESULT_SUCCESS; }
OH_AudioCommon_Result OH_AudioRoutingManager_GetPreferredInputDevice(OH_AudioRoutingManager *m,
    OH_AudioStream_SourceType source, OH_AudioDeviceDescriptorArray **out)
{
    assert(m == &routing && source == AUDIOSTREAM_SOURCE_TYPE_MIC);
    deviceArray.size = captureRoutePresent ? 1 : 0; *out = &deviceArray; return AUDIOCOMMON_RESULT_SUCCESS;
}

OH_AudioStream_Result OH_AudioStreamBuilder_Create(OH_AudioStreamBuilder **out, OH_AudioStream_Type type)
{
    assert(type == AUDIOSTREAM_TYPE_RENDERER || type == AUDIOSTREAM_TYPE_CAPTURER);
    if (step("Create")) return AUDIOSTREAM_ERROR_SYSTEM;
    *out = calloc(1, sizeof(**out)); assert(*out); (*out)->type = type; ++builders; return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_Destroy(OH_AudioStreamBuilder *b)
{ assert(b); free(b); --builders; return AUDIOSTREAM_SUCCESS; }

#define SETTER(name, type, member) \
OH_AudioStream_Result OH_AudioStreamBuilder_##name(OH_AudioStreamBuilder *b, type value) { \
    if (step(#name)) { return AUDIOSTREAM_ERROR_SYSTEM; } b->member = value; return AUDIOSTREAM_SUCCESS; }

OH_AudioStream_Result OH_AudioStreamBuilder_SetSamplingRate(OH_AudioStreamBuilder *b, int32_t value)
{
    if (step("SetSamplingRate")) return AUDIOSTREAM_ERROR_SYSTEM;
    if (value != 44100 && value != 48000) return AUDIOSTREAM_ERROR_INVALID_PARAM;
    b->rate = value; return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetChannelCount(OH_AudioStreamBuilder *b, int32_t value)
{
    if (step("SetChannelCount")) return AUDIOSTREAM_ERROR_SYSTEM;
    if (value != 1 && value != 2) return AUDIOSTREAM_ERROR_INVALID_PARAM;
    b->channels = value; return AUDIOSTREAM_SUCCESS;
}
SETTER(SetSampleFormat, OH_AudioStream_SampleFormat, format)
SETTER(SetEncodingType, OH_AudioStream_EncodingType, encoding)
SETTER(SetLatencyMode, OH_AudioStream_LatencyMode, latency)
#undef SETTER
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererInfo(OH_AudioStreamBuilder *b, OH_AudioStream_Usage usage)
{ assert(b && usage == AUDIOSTREAM_USAGE_MUSIC); return step("SetRendererInfo"); }
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererWriteDataCallbackAdvanced(OH_AudioStreamBuilder *b,
    OH_AudioRenderer_OnWriteDataCallbackAdvanced callback, void *opaque)
{
    if (step("SetRendererWriteDataCallbackAdvanced")) return AUDIOSTREAM_ERROR_SYSTEM;
    b->data = callback; b->opaque = opaque; return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererErrorCallback(OH_AudioStreamBuilder *b,
    OH_AudioRenderer_OnErrorCallback callback, void *opaque)
{
    if (step("SetRendererErrorCallback")) return AUDIOSTREAM_ERROR_SYSTEM;
    assert(b->opaque == opaque); b->error = callback; return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererInterruptCallback(OH_AudioStreamBuilder *b,
    OH_AudioRenderer_OnInterruptCallback callback, void *opaque)
{
    if (step("SetRendererInterruptCallback")) return AUDIOSTREAM_ERROR_SYSTEM;
    assert(b->opaque == opaque); b->interrupt = callback; return AUDIOSTREAM_SUCCESS;
}

/* Capturer 采用同一 SDK 声明但独立的强类型指针和权限/状态；不能复用 renderer 假装录音。 */
OH_AudioStream_Result OH_AudioStreamBuilder_SetCapturerInfo(OH_AudioStreamBuilder *b, OH_AudioStream_SourceType type)
{ assert(b->type == AUDIOSTREAM_TYPE_CAPTURER && type == AUDIOSTREAM_SOURCE_TYPE_MIC); return step("SetCapturerInfo"); }
OH_AudioStream_Result OH_AudioStreamBuilder_SetCapturerReadDataCallback(OH_AudioStreamBuilder *b,
    OH_AudioCapturer_OnReadDataCallback callback, void *opaque)
{
    if (step("SetCapturerReadDataCallback")) return AUDIOSTREAM_ERROR_SYSTEM;
    b->captureData = callback; b->opaque = opaque; return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetCapturerErrorCallback(OH_AudioStreamBuilder *b,
    OH_AudioCapturer_OnErrorCallback callback, void *opaque)
{
    if (step("SetCapturerErrorCallback")) return AUDIOSTREAM_ERROR_SYSTEM;
    assert(b->opaque == opaque); b->captureError = callback; return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetCapturerInterruptCallback(OH_AudioStreamBuilder *b,
    OH_AudioCapturer_OnInterruptCallback callback, void *opaque)
{
    if (step("SetCapturerInterruptCallback")) return AUDIOSTREAM_ERROR_SYSTEM;
    assert(b->opaque == opaque); b->captureInterrupt = callback; return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_GenerateCapturer(OH_AudioStreamBuilder *b, OH_AudioCapturer **out)
{
    if (!captureAllowed || step("GenerateCapturer")) return AUDIOSTREAM_ERROR_SYSTEM;
    assert(b->type == AUDIOSTREAM_TYPE_CAPTURER && b->captureData && b->captureError && b->captureInterrupt);
    *out = calloc(1, sizeof(**out)); assert(*out); (*out)->config = *b;
    (*out)->state = AUDIOSTREAM_STATE_PREPARED; currentCapture = *out; ++capturers;
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioCapturer_Start(OH_AudioCapturer *c)
{ if (step("CaptureStart")) return AUDIOSTREAM_ERROR_SYSTEM; c->state = AUDIOSTREAM_STATE_RUNNING; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_Pause(OH_AudioCapturer *c)
{ if (step("CapturePause")) return AUDIOSTREAM_ERROR_SYSTEM; c->state = AUDIOSTREAM_STATE_PAUSED; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_Flush(OH_AudioCapturer *c)
{ assert(c->state != AUDIOSTREAM_STATE_RUNNING); return step("CaptureFlush"); }
OH_AudioStream_Result OH_AudioCapturer_GetCurrentState(OH_AudioCapturer *c, OH_AudioStream_State *state)
{ if (step("CaptureState")) return AUDIOSTREAM_ERROR_SYSTEM; *state = c->state; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetSamplingRate(OH_AudioCapturer *c, int32_t *out)
{ if (step("CaptureRate")) return AUDIOSTREAM_ERROR_SYSTEM; *out = c->config.rate + mismatch; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetChannelCount(OH_AudioCapturer *c, int32_t *out)
{ if (step("CaptureChannels")) return AUDIOSTREAM_ERROR_SYSTEM; *out = c->config.channels; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetSampleFormat(OH_AudioCapturer *c, OH_AudioStream_SampleFormat *out)
{ if (step("CaptureFormat")) return AUDIOSTREAM_ERROR_SYSTEM; *out = c->config.format; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetEncodingType(OH_AudioCapturer *c, OH_AudioStream_EncodingType *out)
{ if (step("CaptureEncoding")) return AUDIOSTREAM_ERROR_SYSTEM; *out = c->config.encoding; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_GetFrameSizeInCallback(OH_AudioCapturer *c, int32_t *out)
{ assert(c); if (step("CaptureCallbackFrames")) return AUDIOSTREAM_ERROR_SYSTEM; *out = 64; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioCapturer_Release(OH_AudioCapturer *c)
{
    unsigned char late[16] = {0};
    c->config.captureData(c, c->config.opaque, late, sizeof(late));
    c->config.captureError(c, c->config.opaque, AUDIOSTREAM_ERROR_SYSTEM);
    if (step("CaptureRelease")) return AUDIOSTREAM_ERROR_SYSTEM;
    if (currentCapture == c) currentCapture = NULL;
    free(c); --capturers; return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_GenerateRenderer(OH_AudioStreamBuilder *b, OH_AudioRenderer **out)
{
    if (step("GenerateRenderer") || (fastUnavailable && b->latency == AUDIOSTREAM_LATENCY_MODE_FAST))
        return AUDIOSTREAM_ERROR_SYSTEM;
    assert(b->data && b->error && b->interrupt);
    *out = calloc(1, sizeof(**out)); assert(*out); (*out)->config = *b;
    (*out)->state = AUDIOSTREAM_STATE_PREPARED; current = *out; ++renderers;
#ifdef AMCL_DAUDIO_REAL_JNI
    assert(!pthread_create(&(*out)->worker, NULL, automatic_pump, *out));
#endif
    return AUDIOSTREAM_SUCCESS;
}

/* 替身只在明确调用 present() 后推进呈现位置。write callback 提交不能冒充播放。 */
static int pump(OH_AudioRenderer *r, unsigned char *bytes, int size)
{
    int n = r->config.data(r, r->config.opaque, bytes, size);
    const int frame = r->config.channels * (r->config.format + 1);
    assert(n >= 0 && n <= size && n % frame == 0);
    __atomic_add_fetch(&r->written, n / frame, __ATOMIC_SEQ_CST);
    return n;
}
static void present(OH_AudioRenderer *r)
{
    const int64_t written = __atomic_load_n(&r->written, __ATOMIC_SEQ_CST);
    const int64_t delay = __atomic_load_n(&delayFrames, __ATOMIC_SEQ_CST);
    __atomic_store_n(&r->presented, written > delay ? written - delay : 0, __ATOMIC_SEQ_CST);
}

#ifdef AMCL_DAUDIO_REAL_JNI
/* 只有测试平台在另一 pthread 消费用户 PCM；原 JNI/Java write、格式转换和 drain 全部真实执行。 */
static void *automatic_pump(void *opaque)
{
    OH_AudioRenderer *r = opaque;
    unsigned char buffer[384];
    const struct timespec delay = {0, 1000000};
    while (!__atomic_load_n(&r->quit, __ATOMIC_SEQ_CST)) {
        pump(r, buffer, sizeof(buffer)); present(r); nanosleep(&delay, NULL);
    }
    return NULL;
}
#endif

OH_AudioStream_Result OH_AudioRenderer_Release(OH_AudioRenderer *r)
{
    unsigned char guard[16];
    assert(r);
#ifdef AMCL_DAUDIO_REAL_JNI
    __atomic_store_n(&r->quit, 1, __ATOMIC_SEQ_CST);
    assert(!pthread_join(r->worker, NULL));
#endif
    memset(guard, 0xA5, sizeof(guard));
    /* Release 内同步回调模拟最危险的关闭交错：owner 必须已撤销，不能访问已销毁队列。 */
    assert(pump(r, guard, sizeof(guard)) == 0); assert(guard[0] == 0xA5); ++lateCallbacks;
    r->config.error(r, r->config.opaque, AUDIOSTREAM_ERROR_SYSTEM);
    ++releases;
    if (releaseFailure || step("Release")) return AUDIOSTREAM_ERROR_SYSTEM;
    if (current == r) current = NULL;
    free(r); --renderers; return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioRenderer_Start(OH_AudioRenderer *r)
{
    if (step("Start")) return AUDIOSTREAM_ERROR_SYSTEM;
    r->state = AUDIOSTREAM_STATE_RUNNING;
    if (forcePauseOnStart) {
        r->state = AUDIOSTREAM_STATE_PAUSED;
        r->config.interrupt(r, r->config.opaque, AUDIOSTREAM_INTERRUPT_FORCE, AUDIOSTREAM_INTERRUPT_HINT_PAUSE);
    }
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioRenderer_Pause(OH_AudioRenderer *r)
{ if (step("Pause")) return AUDIOSTREAM_ERROR_SYSTEM; r->state = AUDIOSTREAM_STATE_PAUSED; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioRenderer_Flush(OH_AudioRenderer *r)
{
    if (step("Flush")) return AUDIOSTREAM_ERROR_SYSTEM;
    assert(r->state != AUDIOSTREAM_STATE_RUNNING);
    /* 真机/SDK合同：FramesWritten累计不清零，GetTimestamp/GetAudioTimestampInfo呈现坐标归零。 */
    present(r);
    __atomic_store_n(&r->positionOrigin, __atomic_load_n(&r->written, __ATOMIC_SEQ_CST), __ATOMIC_SEQ_CST);
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioRenderer_GetCurrentState(OH_AudioRenderer *r, OH_AudioStream_State *out)
{ if (step("GetCurrentState")) return AUDIOSTREAM_ERROR_SYSTEM; *out = r->state; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioRenderer_GetSamplingRate(OH_AudioRenderer *r, int32_t *out)
{ if (step("GetSamplingRate")) return AUDIOSTREAM_ERROR_SYSTEM; *out = r->config.rate + mismatch; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioRenderer_GetChannelCount(OH_AudioRenderer *r, int32_t *out)
{ if (step("GetChannelCount")) return AUDIOSTREAM_ERROR_SYSTEM; *out = r->config.channels; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioRenderer_GetSampleFormat(OH_AudioRenderer *r, OH_AudioStream_SampleFormat *out)
{ if (step("GetSampleFormat")) return AUDIOSTREAM_ERROR_SYSTEM; *out = r->config.format; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioRenderer_GetEncodingType(OH_AudioRenderer *r, OH_AudioStream_EncodingType *out)
{ if (step("GetEncodingType")) return AUDIOSTREAM_ERROR_SYSTEM; *out = r->config.encoding; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioRenderer_GetFrameSizeInCallback(OH_AudioRenderer *r, int32_t *out)
{ assert(r); if (step("GetFrameSizeInCallback")) return AUDIOSTREAM_ERROR_SYSTEM; *out = 64; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioRenderer_SetVolume(OH_AudioRenderer *r, float value)
{ if (step("SetVolume")) return AUDIOSTREAM_ERROR_SYSTEM; r->volume = value; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioRenderer_GetFramesWritten(OH_AudioRenderer *r, int64_t *out)
{ if (step("GetFramesWritten")) return AUDIOSTREAM_ERROR_SYSTEM; *out = __atomic_load_n(&r->written, __ATOMIC_SEQ_CST); return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioRenderer_GetTimestamp(OH_AudioRenderer *r, clockid_t clock,
    int64_t *frame, int64_t *timestamp)
{
    assert(clock == CLOCK_MONOTONIC); if (step("GetTimestamp")) return AUDIOSTREAM_ERROR_SYSTEM;
    *frame = __atomic_load_n(&r->presented, __ATOMIC_SEQ_CST) - __atomic_load_n(&r->positionOrigin, __ATOMIC_SEQ_CST);
    if (*frame < 0) *frame = 0;
    *timestamp = __atomic_load_n(&reportedTimestamp, __ATOMIC_SEQ_CST); return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioRenderer_GetAudioTimestampInfo(OH_AudioRenderer *r, int64_t *frame, int64_t *timestamp)
{
    if (step("GetAudioTimestampInfo")) return AUDIOSTREAM_ERROR_SYSTEM;
    if (r->state != AUDIOSTREAM_STATE_RUNNING) return AUDIOSTREAM_ERROR_ILLEGAL_STATE;
    return OH_AudioRenderer_GetTimestamp(r, CLOCK_MONOTONIC, frame, timestamp);
}

#ifndef AMCL_DAUDIO_REAL_JNI
void DAUDIO_AddAudioFormat(void *creator, int bits, int frame, int channels, float rate, int encoding, int sign, int big)
{
    assert(creator == &formats && frame == channels * bits / 8 && encoding == DAUDIO_PCM);
    assert((rate == 44100 || rate == 48000) && (channels == 1 || channels == 2));
    assert(!big && sign == (bits != 8)); ++formats;
}

/* 代码租约验证必须看到与后端同映像的既有 JNI 符号，不靠测试分支绕过 acquire_code。 */
void Java_com_sun_media_sound_DirectAudioDevice_nOpen(void) {}

static void *open_line(void)
{ return DAUDIO_Open(0, 0, TRUE, DAUDIO_PCM, 48000, 16, 4, 2, TRUE, FALSE, 32); }

static void clean(void)
{
    assert(!builders && !renderers && !current); failure = NULL; fastUnavailable = mismatch = forcePauseOnStart = 0;
    __atomic_store_n(&reportedTimestamp, INT64_C(1000000), __ATOMIC_SEQ_CST);
}

/* 一百万完整立体声帧跨两个 pthread；数据自带序号，逐字节检查丢失、重排和重复。 */
typedef struct { OH_AudioRenderer *renderer; uint32_t expected; } Consumer;
static void *consume(void *arg)
{
    Consumer *c = arg;
    uint32_t data[17];
    while (c->expected < 1000000) {
        int n = pump(c->renderer, (unsigned char *)data, sizeof(data));
        int i;
        /* 用户序号从1开始；真实尾静音为0，允许它占平台帧但不占用户序号。 */
        for (i = 0; i < n / 4; ++i) if (data[i]) assert(data[i] == ++c->expected);
        present(c->renderer);
    }
    return NULL;
}

int amcl_test_run(void)
{
    static const char *failures[] = { "Create", "SetSamplingRate", "SetChannelCount", "SetSampleFormat",
        "SetEncodingType", "SetRendererInfo", "SetRendererWriteDataCallbackAdvanced", "SetRendererErrorCallback",
        "SetRendererInterruptCallback", "SetLatencyMode", "GenerateRenderer", "GetSamplingRate",
        "GetChannelCount", "GetSampleFormat", "GetEncodingType", "GetFrameSizeInCallback", "SetVolume" };
    unsigned char input[256], output[256];
    void *line;
    unsigned i;
    for (i = 0; i < sizeof(input); ++i) input[i] = (unsigned char)i;
    assert(DAUDIO_GetDirectAudioDeviceCount() == 1);
    routePresent = 0; assert(!DAUDIO_GetDirectAudioDeviceCount()); assert(!open_line()); routePresent = 1;
    DAUDIO_GetFormats(0, 0, TRUE, &formats); assert(formats == 16);
    formats = 0; DAUDIO_GetFormats(0, 0, FALSE, &formats); assert(!formats);
    for (i = 0; i < sizeof(failures) / sizeof(failures[0]); ++i) {
        failure = failures[i]; assert(!open_line()); clean();
    }
    mismatch = 1; assert(!open_line()); clean();
    /* 所有 native 整数格式和单/双声道逐字节跨尾部，24-bit 的 3/6 字节帧不能按 2^n 处理。 */
    {
        static const int sampleBits[] = {8, 16, 24, 32};
        int f, channels;
        for (f = 0; f < 4; ++f) for (channels = 1; channels <= 2; ++channels) {
            const int frame = sampleBits[f] / 8 * channels;
            line = DAUDIO_Open(0, 0, TRUE, DAUDIO_PCM, 44100, sampleBits[f], frame, channels,
                               sampleBits[f] != 8, FALSE, 9 * frame + frame - 1);
            assert(line && DAUDIO_GetBufferSize(line, TRUE) == 9 * frame);
            assert(DAUDIO_Write(line, (char *)input, 10 * frame) == 9 * frame);
            assert(DAUDIO_Start(line, TRUE));
            assert(pump(current, output, 7 * frame + (frame > 1 ? 1 : 0)) == 7 * frame);
            assert(!memcmp(output, input, (size_t)(7 * frame)));
            assert(DAUDIO_Write(line, (char *)input + 9 * frame, 2 * frame) == 2 * frame);
            assert(pump(current, output, 16 * frame) == 16 * frame);
            assert(!memcmp(output, input + 7 * frame, (size_t)(4 * frame)));
            for (int k = 4 * frame; k < 16 * frame; ++k) assert(output[k] == (sampleBits[f] == 8 ? 0x80 : 0));
            present(current); assert(DAUDIO_GetBytePosition(line, TRUE, 11 * frame) == 11 * frame);
            DAUDIO_Close(line, TRUE); clean();
        }
    }
    fastUnavailable = 1; line = open_line(); assert(line && current->config.latency == AUDIOSTREAM_LATENCY_MODE_NORMAL);
    DAUDIO_Close(line, TRUE); clean();
    line = open_line(); assert(line && DAUDIO_GetBufferSize(line, TRUE) == 32);
    assert(DAUDIO_Write(line, (char *)input, 33) == -1);
    assert(DAUDIO_Write(line, (char *)input, 48) == 32 && DAUDIO_GetAvailable(line, TRUE) == 0);
    assert(pump(current, output, 16) == 0); /* start 前只缓存，不偷偷播放。 */
    assert(DAUDIO_Start(line, TRUE));
    assert(pump(current, output, 19) == 16 && !memcmp(output, input, 16));
    assert(DAUDIO_StillDraining(line, TRUE) && DAUDIO_GetBytePosition(line, TRUE, 32) == 0);
    present(current); assert(DAUDIO_GetBytePosition(line, TRUE, 32) == 16);
    assert(DAUDIO_Write(line, (char *)input + 32, 16) == 16);
    assert(pump(current, output, 32) == 32 && !memcmp(output, input + 16, 32));
    assert(DAUDIO_StillDraining(line, TRUE)); present(current); assert(!DAUDIO_StillDraining(line, TRUE));
    assert(DAUDIO_GetBytePosition(line, TRUE, 48) == 48);
    assert(DAUDIO_Write(line, (char *)input, 32) == 32);
    assert(DAUDIO_Stop(line, TRUE)); assert(pump(current, output, 16) == 0 && DAUDIO_GetAvailable(line, TRUE) == 0);
    assert(DAUDIO_Start(line, TRUE)); assert(pump(current, output, 16) == 16 && !memcmp(output, input, 16));
    assert(DAUDIO_Flush(line, TRUE)); assert(DAUDIO_GetAvailable(line, TRUE) == 32);
    assert(!DAUDIO_StillDraining(line, TRUE)); assert(DAUDIO_GetBytePosition(line, TRUE, 80) == 80);
    assert(DAUDIO_Write(line, (char *)input + 48, 16) == 16);
    assert(pump(current, output, 16) == 16 && !memcmp(output, input + 48, 16));
    assert(DAUDIO_GetBytePosition(line, TRUE, 96) == 80);
    present(current); assert(DAUDIO_GetBytePosition(line, TRUE, 96) == 96);
    /* 系统暂停/恢复与用户 stop 交错：迟到 resume 不能重新启动用户已停止的 line。 */
    current->state = AUDIOSTREAM_STATE_PAUSED;
    current->config.interrupt(current, current->config.opaque, AUDIOSTREAM_INTERRUPT_FORCE, AUDIOSTREAM_INTERRUPT_HINT_PAUSE);
    DAUDIO_Service(line, TRUE); assert(current->state == AUDIOSTREAM_STATE_PAUSED);
    assert(DAUDIO_Stop(line, TRUE));
    current->config.interrupt(current, current->config.opaque, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_RESUME);
    DAUDIO_Service(line, TRUE); assert(current->state == AUDIOSTREAM_STATE_PAUSED);
    assert(DAUDIO_Start(line, TRUE));
    current->config.interrupt(current, current->config.opaque, AUDIOSTREAM_INTERRUPT_FORCE, AUDIOSTREAM_INTERRUPT_HINT_PAUSE);
    DAUDIO_Service(line, TRUE); assert(current->state == AUDIOSTREAM_STATE_PAUSED);
    current->config.interrupt(current, current->config.opaque, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_RESUME);
    DAUDIO_Service(line, TRUE); assert(current->state == AUDIOSTREAM_STATE_RUNNING);
    current->config.interrupt(current, current->config.opaque, AUDIOSTREAM_INTERRUPT_FORCE, AUDIOSTREAM_INTERRUPT_HINT_DUCK);
    DAUDIO_Service(line, TRUE); assert(current->volume == 1.0f);
    current->config.interrupt(current, current->config.opaque, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_DUCK);
    DAUDIO_Service(line, TRUE); assert(current->volume == 0.2f);
    current->config.interrupt(current, current->config.opaque, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_MUTE);
    DAUDIO_Service(line, TRUE); assert(current->volume == 0.0f);
    current->config.interrupt(current, current->config.opaque, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_UNMUTE);
    DAUDIO_Service(line, TRUE); assert(current->volume == 0.2f);
    current->config.interrupt(current, current->config.opaque, AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_UNDUCK);
    DAUDIO_Service(line, TRUE); assert(current->volume == 1.0f);
    DAUDIO_Close(line, TRUE); clean();
    /* Start/Pause/Flush/计数及异步错误均必须保留原始平台错误。 */
    line = open_line(); failure = "Start"; assert(!DAUDIO_Start(line, TRUE)); assert(AMCL_DAudio_GetError(line) == AUDIOSTREAM_ERROR_SYSTEM);
    assert(DAUDIO_Write(line, (char *)input, 4) == -1); DAUDIO_Close(line, TRUE); clean();
    line = open_line(); assert(DAUDIO_Start(line, TRUE)); failure = "Pause"; assert(!DAUDIO_Stop(line, TRUE));
    DAUDIO_Close(line, TRUE); clean();
    line = open_line(); failure = "Flush"; assert(DAUDIO_Flush(line, TRUE)); /* prepared 只有软件队列。 */
    failure = NULL; assert(DAUDIO_Start(line, TRUE)); assert(DAUDIO_Write(line, (char *)input, 4) == 4);
    assert(pump(current, output, 4) == 4); failure = "Flush"; assert(!DAUDIO_Flush(line, TRUE)); DAUDIO_Close(line, TRUE); clean();
    line = open_line(); assert(DAUDIO_Start(line, TRUE)); assert(DAUDIO_Write(line, (char *)input, 4) == 4);
    assert(pump(current, output, 4) == 4); failure = "GetFramesWritten";
    assert(DAUDIO_Flush(line, TRUE) && !AMCL_DAudio_GetError(line)); /* 不再用累计写入量决定呈现坐标。 */
    DAUDIO_Close(line, TRUE); clean();
    line = open_line(); assert(DAUDIO_Start(line, TRUE)); assert(DAUDIO_Write(line, (char *)input, 4) == 4);
    assert(pump(current, output, 4) == 4); failure = "GetAudioTimestampInfo"; assert(DAUDIO_StillDraining(line, TRUE));
    assert(AMCL_DAudio_GetError(line) == AUDIOSTREAM_ERROR_SYSTEM); DAUDIO_Close(line, TRUE); clean();
    line = open_line(); current->config.error(current, current->config.opaque, AUDIOSTREAM_ERROR_INVALID_PARAM);
    assert(!DAUDIO_Start(line, TRUE) && AMCL_DAudio_GetError(line) == AUDIOSTREAM_ERROR_INVALID_PARAM);
    DAUDIO_Close(line, TRUE); clean();
    line = DAUDIO_Open(0, 0, TRUE, DAUDIO_PCM, 48000, 16, 4, 2, TRUE, FALSE, 4096);
    assert(line && DAUDIO_Start(line, TRUE));
    {
        pthread_t worker;
        Consumer consumer = {current, 0};
        uint32_t next = 0, data[31];
        assert(!pthread_create(&worker, NULL, consume, &consumer));
        while (next < 1000000) {
            int count = 1000000 - next < 31 ? (int)(1000000 - next) : 31;
            int n, j;
            for (j = 0; j < count; ++j) data[j] = next + (uint32_t)j + 1;
            n = DAUDIO_Write(line, (char *)data, count * 4); assert(n >= 0);
            next += (uint32_t)(n / 4);
        }
        assert(!pthread_join(worker, NULL)); assert(consumer.expected == 1000000);
        assert(!DAUDIO_StillDraining(line, TRUE)); assert(DAUDIO_GetBytePosition(line, TRUE, 4000000) == 4000000);
    }
    DAUDIO_Close(line, TRUE); clean();
    printf("PASS DAUDIO actual C: formats, 17 open failures, readback mismatch, fallback, partial/wrap, presentation, pause/flush, interrupts/duck/mute, runtime failures, 1000000 ordered frames; releases=%d late=%d\n", releases, lateCallbacks);
    /* 最后才测试不能释放的系统对象；平台仍保留 ctx，LSan 根可达，不掩盖普通路径泄漏。 */
    line = open_line(); assert(line); releaseFailure = 1;
    assert(AMCL_DAudio_Close(line) == AUDIOSTREAM_ERROR_SYSTEM);
    assert(current && renderers == 1 && pump(current, output, 16) == 0);
    current->config.interrupt(current, current->config.opaque, AUDIOSTREAM_INTERRUPT_FORCE, AUDIOSTREAM_INTERRUPT_HINT_STOP);
    current->config.error(current, current->config.opaque, AUDIOSTREAM_ERROR_SYSTEM);
    puts("PASS DAUDIO Release failure: detached late callbacks retain only platform context/code lease");
    return 0;
}
#endif
