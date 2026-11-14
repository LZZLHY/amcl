/*
 * AMCL JavaSound 的 OHOS 平台实现。此文件由四代 JDK 的 libjsound 编译，不属于 HAP。
 * 上游 Java lockNative 串行化每条 line 的普通入口；OHAudio 回调只做有界复制和原子
 * 状态记录。API20 advanced callback 保留部分帧数，欠载不伪造用户数据或播放进度。
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <limits.h>
#include <time.h>
#include <dlfcn.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiocapturer.h>
#include <ohaudio/native_audio_routing_manager.h>
#include "DirectAudio.h"
#include "ohos_daudio.h"
#include "ohos_daudio_callbacks.h"

#if USE_DAUDIO == TRUE
#include "ohos_daudio_host.h"

/* 新宿主存在时，内建 provider 与启动器 SPI 共享权限、前台和真实流 owner。
 * 无宿主的独立 CLI 保留下面完整原生后端；失效宿主不会回退绕过其撤销政策。 */
const char AMCL_DAudio_HostedIdentity[]
    __attribute__((section(".amcl.hostedpcm"), used, visibility("default"))) =
    "AMCL_DAUDIO_HOSTED_PCM_V1";

/* 打包门只凭实际 libjsound 的此只读标记、libohaudio 依赖及逐符号供应者联合认定
 * 后端已编译；它不授予设备资格。独立 ELF 节保留在正常 strip 后，不借文件名猜测。 */
const char AMCL_DAudio_BackendIdentity[]
    __attribute__((section(".amcl.daudio"), used, visibility("default"))) =
    "AMCL_DAUDIO_OHOS_API20_DUPLEX_V3";

int AMCL_DAudio_GetError(void *id)
{
    AmclLine *line = (AmclLine *)id;
    AmclHostedLine *host = amcl_hosted_line(id);
    if (host) {
        const int state = host->api->state(host->handle);
        if (state < 0 || (state & AMCL_AUDIO_FAILED)) record_error(line, state < 0 ? state : AMCL_AUDIO_PLATFORM);
    }
    return line ? __atomic_load_n(&line->error, __ATOMIC_SEQ_CST) : 0;
}

int AMCL_DAudio_GetPendingError(void *id)
{
    AmclLine *line = (AmclLine *)id;
    const int error = AMCL_DAudio_GetError(id);
    return line && !__atomic_load_n(&line->errorReported, __ATOMIC_ACQUIRE) ? error : 0;
}

void AMCL_DAudio_MarkErrorReported(void *id)
{
    AmclLine *line = (AmclLine *)id;
    if (line && AMCL_DAudio_GetError(line)) __atomic_store_n(&line->errorReported, 1, __ATOMIC_RELEASE);
}

/* 控制路径保持各自的强类型 OHOS handle；方向分支不进入 PCM 字块复制循环。 */
static OH_AudioStream_Result stream_start(AmclLine *line)
{ return line->isSource ? OH_AudioRenderer_Start(line->renderer) : OH_AudioCapturer_Start(line->capturer); }

static OH_AudioStream_Result stream_pause(AmclLine *line)
{ return line->isSource ? OH_AudioRenderer_Pause(line->renderer) : OH_AudioCapturer_Pause(line->capturer); }

static OH_AudioStream_Result stream_state(AmclLine *line, OH_AudioStream_State *state)
{ return line->isSource ? OH_AudioRenderer_GetCurrentState(line->renderer, state) :
                         OH_AudioCapturer_GetCurrentState(line->capturer, state); }

/* callback 代码必须与实际 JNI libjsound 同映像。NOLOAD 禁止为获取租约误装第二份库；
 * 不能以一个相同 SONAME 的其它文件、或无引用的 dladdr 结果代替真正的保活句柄。 */
static void *acquire_code(void)
{
    Dl_info owner, exportedOwner;
    void *handle, *exported;
    if (!dladdr((void *)&render_data, &owner) || !owner.dli_fname || !owner.dli_fbase) return NULL;
    handle = dlopen(owner.dli_fname, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    if (!handle) return NULL;
    exported = dlsym(handle, "Java_com_sun_media_sound_DirectAudioDevice_nOpen");
    if (!exported || !dladdr(exported, &exportedOwner) || exportedOwner.dli_fbase != owner.dli_fbase) {
        dlclose(handle);
        return NULL;
    }
    return handle;
}

/* 嵌入JDK的映像不归系统动态链接器登记，系统CFI不能接受其中的回调地址。只有
 * 已签名、正常加载的同一宿主映像中的共享POD回调可注册；缺失/错版必须在Generate
 * 前失败，不回退到已实证会被CFI拒绝的匿名入口。独立CLI仍用本库的同源本地回调。 */
static const AmclDAudioCallbackAbiV2 *acquire_callbacks(AmclCallback *ctx)
{
    int (*embedded)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "amcl_jvm_is_embedded");
    const AmclDAudioCallbackAbiV2 *(*factory)(void);
    const AmclDAudioCallbackAbiV2 *table;
    Dl_info markerInfo, factoryInfo, addressInfo;
    void *host;
    const void *addresses[7];
    unsigned i;
    if (!embedded || !embedded()) return amcl_daudio_local_callbacks_v2();
    factory = (const AmclDAudioCallbackAbiV2 *(*)(void))dlsym(RTLD_DEFAULT, "amcl_javasound_callbacks_v2");
    if (!factory || !dladdr((void *)embedded, &markerInfo) || !markerInfo.dli_fbase ||
        !dladdr((void *)factory, &factoryInfo) || !factoryInfo.dli_fname ||
        factoryInfo.dli_fbase != markerInfo.dli_fbase) goto fail;
    host = dlopen(factoryInfo.dli_fname, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    if (!host) goto fail;
    /* NOLOAD句柄和全局解析必须是同一映像，不接受重名库或额外装载副本的getter。 */
    if (dlsym(host, "amcl_javasound_callbacks_v2") != (void *)factory) { dlclose(host); goto fail; }
    table = factory();
    if (!amcl_daudio_callbacks_valid_v2(table)) { dlclose(host); goto fail; }
    addresses[0] = table;
    addresses[1] = (const void *)table->renderData;
    addresses[2] = (const void *)table->renderError;
    addresses[3] = (const void *)table->renderInterrupt;
    addresses[4] = (const void *)table->captureData;
    addresses[5] = (const void *)table->captureError;
    addresses[6] = (const void *)table->captureInterrupt;
    for (i = 0; i < sizeof(addresses) / sizeof(addresses[0]); ++i) {
        if (!dladdr(addresses[i], &addressInfo) || addressInfo.dli_fbase != factoryInfo.dli_fbase) {
            dlclose(host); goto fail;
        }
    }
    ctx->hostLease = host;
    return table;
fail:
    fprintf(stderr, "AMCL JavaSound: embedded host callback ABI/identity unavailable; open rejected\n");
    return NULL;
}

/* 普通控制线程的有界退出等待。异常不退出的系统回调不能被当作可安全释放；调用方
 * 在失败时保留其仍可访问的数据。此处没有声称系统 Release 自身具有墙钟时间上限。 */
static int wait_callbacks(AmclCallback *ctx)
{
    struct timespec pause = { 0, 1000000 };
    int tries;
    for (tries = 0; tries < 1000; ++tries) {
        if (!__atomic_load_n(&ctx->active, __ATOMIC_SEQ_CST)) return 1;
        nanosleep(&pause, NULL);
    }
    return !__atomic_load_n(&ctx->active, __ATOMIC_SEQ_CST);
}

/* 系统默认输出是实际路由，不将本地硬编码数量冒充枚举结果。描述数组严格由官方
 * ReleaseDevices 配对释放；查询/释放失败均不发布可用 mixer。 */
static int has_route(int isSource)
{
    OH_AudioRoutingManager *manager = NULL;
    OH_AudioDeviceDescriptorArray *devices = NULL;
    int found = 0;
    if (OH_AudioManager_GetAudioRoutingManager(&manager) != AUDIOCOMMON_RESULT_SUCCESS || !manager) return 0;
    if ((isSource ? OH_AudioRoutingManager_GetPreferredOutputDevice(manager, AUDIOSTREAM_USAGE_MUSIC, &devices) :
                   OH_AudioRoutingManager_GetPreferredInputDevice(manager, AUDIOSTREAM_SOURCE_TYPE_MIC, &devices)) ==
        AUDIOCOMMON_RESULT_SUCCESS && devices && devices->size && devices->descriptors) {
        uint32_t i;
        for (i = 0; i < devices->size; ++i) if (devices->descriptors[i]) { found = 1; break; }
    }
    if (devices && OH_AudioRoutingManager_ReleaseDevices(manager, devices) != AUDIOCOMMON_RESULT_SUCCESS) found = 0;
    return found;
}

INT32 DAUDIO_GetDirectAudioDeviceCount(void) { return has_route(TRUE) || has_route(FALSE) ? 1 : 0; }

INT32 DAUDIO_GetDirectAudioDeviceDescription(INT32 index, DirectAudioDeviceDescription *description)
{
    if (index || !description || (!has_route(TRUE) && !has_route(FALSE))) return FALSE;
    memset(description, 0, sizeof(*description));
    description->deviceID = 0;
    description->maxSimulLines = -1; /* 资源配额由实际 GenerateRenderer 判定。 */
    strcpy(description->name, "OHAudio system audio");
    strcpy(description->vendor, "OpenHarmony");
    strcpy(description->description, "JavaSound PCM through current system output and microphone routes");
    strcpy(description->version, AMCL_DAudio_BackendIdentity);
    return TRUE;
}

/* 使用 builder 的真实校验枚举标准采样率及声道，而不是仅依据硬件当前 48 kHz 限制
 * 音频服务本来支持的重采样。最终打开仍须 Generate 与完整回读，不能静默降级格式。
 * Java 原生层继续补充符号/端序转换；PCM_FLOAT 不属于四代当前 DAUDIO encoding。 */
void DAUDIO_GetFormats(INT32 index, INT32 device, int isSource, void *creator)
{
    static const int rates[] = { 8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100,
                                48000, 64000, 88200, 96000, 176400, 192000, 384000 };
    static const int bits[] = { 8, 16, 24, 32 };
    OH_AudioStreamBuilder *builder = NULL;
    unsigned r, f;
    int channels;
    if (index || device || !creator || !has_route(isSource)) return;
    if (amcl_hosted_requested()) {
        void *lease = NULL;
        if (!amcl_hosted_acquire(&lease)) return;
        // 与宿主实际转换器合同一致；Java 保留上游符号/端序转换，不虚报更宽格式。
        for (r = 0; r < sizeof(rates) / sizeof(rates[0]); ++r)
            if (rates[r] <= 192000) for (channels = 1; channels <= 2; ++channels)
                for (f = 0; f < sizeof(bits) / sizeof(bits[0]); ++f)
                    DAUDIO_AddAudioFormat(creator, bits[f], channels * bits[f] / 8, channels,
                                          (float)rates[r], DAUDIO_PCM, bits[f] != 8, FALSE);
        dlclose(lease);
        return;
    }
    if (OH_AudioStreamBuilder_Create(&builder, isSource ? AUDIOSTREAM_TYPE_RENDERER : AUDIOSTREAM_TYPE_CAPTURER)
        != AUDIOSTREAM_SUCCESS || !builder) return;
    if (!isSource && OH_AudioStreamBuilder_SetCapturerInfo(builder, AUDIOSTREAM_SOURCE_TYPE_MIC) != AUDIOSTREAM_SUCCESS) {
        OH_AudioStreamBuilder_Destroy(builder);
        return;
    }
    for (r = 0; r < sizeof(rates) / sizeof(rates[0]); ++r) {
        if (OH_AudioStreamBuilder_SetSamplingRate(builder, rates[r]) != AUDIOSTREAM_SUCCESS) continue;
        for (channels = 1; channels <= 32; ++channels) {
            if (OH_AudioStreamBuilder_SetChannelCount(builder, channels) != AUDIOSTREAM_SUCCESS) continue;
            for (f = 0; f < sizeof(bits) / sizeof(bits[0]); ++f) {
                if (OH_AudioStreamBuilder_SetSampleFormat(builder, (OH_AudioStream_SampleFormat)f) == AUDIOSTREAM_SUCCESS)
                    DAUDIO_AddAudioFormat(creator, bits[f], channels * bits[f] / 8, channels,
                                          (float)rates[r], DAUDIO_PCM, bits[f] != 8, FALSE);
            }
        }
    }
    if (OH_AudioStreamBuilder_Destroy(builder) != AUDIOSTREAM_SUCCESS)
        fprintf(stderr, "AMCL JavaSound: format builder release failed\n");
}

/* 本函数也用于打开中途回滚。owner 撤销后才调用可能同步触发迟到回调的 Release。
 * Release 失败不释放 ctx/code；若回调已退出，仍可释放大块 ring/line，迟到者只见 NULL。 */
static int destroy_line(AmclLine *line)
{
    int released = 1, closeError = 0;
    AmclCallback *ctx = line->callback;
    __atomic_store_n(&line->copyEnabled, 0, __ATOMIC_SEQ_CST);
    if (ctx) __atomic_store_n(&ctx->owner, NULL, __ATOMIC_SEQ_CST);
    if (line->renderer) {
        OH_AudioStream_Result result = OH_AudioRenderer_Release(line->renderer);
        if (result != AUDIOSTREAM_SUCCESS) {
            released = 0;
            closeError = (int)result;
            fprintf(stderr, "AMCL JavaSound: renderer Release failed code=%d; callback/code retained\n", (int)result);
        }
    }
    if (line->capturer) {
        OH_AudioStream_Result result = OH_AudioCapturer_Release(line->capturer);
        if (result != AUDIOSTREAM_SUCCESS) {
            released = 0;
            closeError = (int)result;
            fprintf(stderr, "AMCL JavaSound: capturer Release failed code=%d; callback/code retained\n", (int)result);
        }
    }
    if (ctx && !wait_callbacks(ctx)) {
        fprintf(stderr, "AMCL JavaSound: callback did not quiesce; owner storage retained\n");
        return closeError ? closeError : AUDIOSTREAM_ERROR_ILLEGAL_STATE;
    }
    free(line->ring);
    free(line->playback);
    amcl_capture_destroy(&line->capture);
    free(line);
    if (ctx && released && !ctx->retainedBuilder) {
        void *lease = ctx->codeLease;
        void *hostLease = ctx->hostLease;
        free(ctx);
        if (hostLease) dlclose(hostLease);
        if (lease) dlclose(lease);
    }
    return closeError;
}

void *DAUDIO_Open(INT32 index, INT32 device, int isSource, int encoding, float sampleRate,
                 int bits, int frameSize, int channels, int isSigned, int isBigEndian, int bufferBytes)
{
    AmclLine *line;
    OH_AudioStreamBuilder *builder = NULL;
    OH_AudioStream_SampleFormat format, actualFormat;
    OH_AudioStream_EncodingType actualEncoding;
    OH_AudioStream_Result result;
    const AmclDAudioCallbackAbiV2 *callbacks;
    int32_t actualRate = 0, actualChannels = 0, callbackFrames = 0;
    int configured = 0;
    if (index || device || encoding != DAUDIO_PCM || channels < 1 ||
        !(sampleRate >= 1) || (double)sampleRate > INT_MAX || sampleRate != (float)(int)sampleRate ||
        (bits != 8 && bits != 16 && bits != 24 && bits != 32) ||
        (bits == 8 ? isSigned : (!isSigned || isBigEndian)) || channels > INT_MAX / (bits / 8) ||
        frameSize != channels * (bits / 8) || bufferBytes < frameSize || !has_route(isSource)) return NULL;
    if (amcl_hosted_requested()) return amcl_hosted_open(isSource, (int)sampleRate, bits, channels, bufferBytes);
    format = bits == 8 ? AUDIOSTREAM_SAMPLE_U8 : bits == 16 ? AUDIOSTREAM_SAMPLE_S16LE :
             bits == 24 ? AUDIOSTREAM_SAMPLE_S24LE : AUDIOSTREAM_SAMPLE_S32LE;
    line = (AmclLine *)calloc(1, sizeof(*line));
    if (!line) return NULL;
    line->isSource = !!isSource;
    line->capacity = bufferBytes - bufferBytes % frameSize;
    line->frameSize = frameSize;
    line->silenceByte = bits == 8 ? 0x80 : 0;
    if (isSource) line->ring = (unsigned char *)malloc((size_t)line->capacity);
    if (isSource) line->playback = (AmclPlaybackTimeline *)calloc(1, sizeof(*line->playback));
    line->callback = (AmclCallback *)calloc(1, sizeof(*line->callback));
    if ((isSource && (!line->ring || !line->playback)) || !line->callback) goto fail;
    line->callback->codeLease = acquire_code();
    if (!line->callback->codeLease) goto fail;
    callbacks = acquire_callbacks(line->callback);
    if (!callbacks) goto fail;
    __atomic_store_n(&line->callback->owner, line, __ATOMIC_SEQ_CST);
    if (OH_AudioStreamBuilder_Create(&builder, isSource ? AUDIOSTREAM_TYPE_RENDERER : AUDIOSTREAM_TYPE_CAPTURER)
        != AUDIOSTREAM_SUCCESS || !builder) goto fail;
    /* 任一步失败即回滚；不能“创建成功”掩盖回调未注册或格式设置失败。 */
#define AMCL_REQUIRE(call) do { result = (call); if (result != AUDIOSTREAM_SUCCESS) { record_error(line, result); goto fail; } } while (0)
    AMCL_REQUIRE(OH_AudioStreamBuilder_SetSamplingRate(builder, (int)sampleRate));
    AMCL_REQUIRE(OH_AudioStreamBuilder_SetChannelCount(builder, channels));
    AMCL_REQUIRE(OH_AudioStreamBuilder_SetSampleFormat(builder, format));
    AMCL_REQUIRE(OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW));
    if (isSource) {
        AMCL_REQUIRE(OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_MUSIC));
        AMCL_REQUIRE(OH_AudioStreamBuilder_SetRendererWriteDataCallbackAdvanced(builder, callbacks->renderData, line->callback));
        AMCL_REQUIRE(OH_AudioStreamBuilder_SetRendererErrorCallback(builder, callbacks->renderError, line->callback));
        AMCL_REQUIRE(OH_AudioStreamBuilder_SetRendererInterruptCallback(builder, callbacks->renderInterrupt, line->callback));
    } else {
        AMCL_REQUIRE(OH_AudioStreamBuilder_SetCapturerInfo(builder, AUDIOSTREAM_SOURCE_TYPE_MIC));
        AMCL_REQUIRE(OH_AudioStreamBuilder_SetCapturerReadDataCallback(builder, callbacks->captureData, line->callback));
        AMCL_REQUIRE(OH_AudioStreamBuilder_SetCapturerErrorCallback(builder, callbacks->captureError, line->callback));
        AMCL_REQUIRE(OH_AudioStreamBuilder_SetCapturerInterruptCallback(builder, callbacks->captureInterrupt, line->callback));
    }
    /* 请求低延迟；不支持该路径时保留相同格式走标准流，不缩减 Java 功能或强改采样率。 */
    result = OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);
    if (result == AUDIOSTREAM_SUCCESS)
        result = isSource ? OH_AudioStreamBuilder_GenerateRenderer(builder, &line->renderer) :
                            OH_AudioStreamBuilder_GenerateCapturer(builder, &line->capturer);
    if (result != AUDIOSTREAM_SUCCESS && !line->renderer && !line->capturer) {
        AMCL_REQUIRE(OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_NORMAL));
        AMCL_REQUIRE(isSource ? OH_AudioStreamBuilder_GenerateRenderer(builder, &line->renderer) :
                                OH_AudioStreamBuilder_GenerateCapturer(builder, &line->capturer));
    }
    if (result != AUDIOSTREAM_SUCCESS || (isSource ? !line->renderer : !line->capturer)) { record_error(line, result); goto fail; }
    if (isSource) {
        AMCL_REQUIRE(OH_AudioRenderer_SetVolume(line->renderer, 1.0f));
        AMCL_REQUIRE(OH_AudioRenderer_GetSamplingRate(line->renderer, &actualRate));
        AMCL_REQUIRE(OH_AudioRenderer_GetChannelCount(line->renderer, &actualChannels));
        AMCL_REQUIRE(OH_AudioRenderer_GetSampleFormat(line->renderer, &actualFormat));
        AMCL_REQUIRE(OH_AudioRenderer_GetEncodingType(line->renderer, &actualEncoding));
        AMCL_REQUIRE(OH_AudioRenderer_GetFrameSizeInCallback(line->renderer, &callbackFrames));
    } else {
        AMCL_REQUIRE(OH_AudioCapturer_GetSamplingRate(line->capturer, &actualRate));
        AMCL_REQUIRE(OH_AudioCapturer_GetChannelCount(line->capturer, &actualChannels));
        AMCL_REQUIRE(OH_AudioCapturer_GetSampleFormat(line->capturer, &actualFormat));
        AMCL_REQUIRE(OH_AudioCapturer_GetEncodingType(line->capturer, &actualEncoding));
        AMCL_REQUIRE(OH_AudioCapturer_GetFrameSizeInCallback(line->capturer, &callbackFrames));
    }
    if (actualRate != (int)sampleRate || actualChannels != channels || actualFormat != format ||
        actualEncoding != AUDIOSTREAM_ENCODING_TYPE_RAW || callbackFrames <= 0 ||
        callbackFrames > INT_MAX / frameSize) {
        record_error(line, AUDIOSTREAM_ERROR_ILLEGAL_STATE);
        goto fail;
    }
    if (!isSource) {
        if (!amcl_capture_init(&line->capture, line->capacity, frameSize, callbackFrames * frameSize)) goto fail;
        line->capacity = line->capture.capacity;
    }
    configured = !AMCL_DAudio_GetError(line);
fail:
    if (builder) {
        result = OH_AudioStreamBuilder_Destroy(builder);
        if (result != AUDIOSTREAM_SUCCESS) {
            record_error(line, result);
            if (line->callback) line->callback->retainedBuilder = builder;
            configured = 0;
        }
    }
    if (configured) return line;
    if (AMCL_DAudio_GetError(line))
        fprintf(stderr, "AMCL JavaSound: open failed code=%d\n", AMCL_DAudio_GetError(line));
    destroy_line(line);
    return NULL;
#undef AMCL_REQUIRE
}

/* 只在运行状态查询真实呈现时钟；暂停时API明确不可调用，保留已确认下界。
 * 不明运行中回退只保留已确认下界，不能猜测新epoch并自动加旧frame而提前计用户帧。
 * Flush另行在静止窗口清空此epoch，不能把累计FramesWritten当重置后的呈现基点。 */
static uint64_t observe_playback(AmclLine *line)
{
    int64_t frame = -1, timestamp = -1;
    uint64_t absolute;
    OH_AudioStream_Result result;
    if (!line->playback) return 0;
    if (!line->platformRunning || AMCL_DAudio_GetError(line) ||
        __atomic_load_n(&line->interrupt, __ATOMIC_SEQ_CST) == AUDIOSTREAM_INTERRUPT_HINT_PAUSE)
        return __atomic_load_n(&line->playback->observedUser, __ATOMIC_ACQUIRE);
    if (!__atomic_load_n(&line->playback->userFrames, __ATOMIC_ACQUIRE)) return 0;
    result = OH_AudioRenderer_GetAudioTimestampInfo(line->renderer, &frame, &timestamp);
    if (result != AUDIOSTREAM_SUCCESS || frame < 0 || timestamp < 0) {
        record_error(line, result == AUDIOSTREAM_SUCCESS ? AUDIOSTREAM_ERROR_ILLEGAL_STATE : result);
        return __atomic_load_n(&line->playback->observedUser, __ATOMIC_ACQUIRE);
    }
    line->lastRawFrame = frame;
    line->lastRawTimestamp = timestamp;
    line->hasTimestamp = 1;
    /* clockOrigin保持0；未证明的route重置不能通过FramesWritten/时间估算或猜offset补齐。 */
    absolute = (uint64_t)frame;
    return amcl_playback_observe(line->playback, absolute);
}

/* Service 只在原 Java lockNative 下执行。事件回调从不持该锁或发起 Start/Pause。
 * 用户停止的 wantedRunning 始终优先于迟到的恢复提示。 */
void DAUDIO_Service(void *id, int isSource)
{
    if (amcl_hosted_line(id)) { (void)isSource; (void)AMCL_DAudio_GetError(id); return; }
    AmclLine *line = (AmclLine *)id;
    int hint;
    OH_AudioStream_Result result;
    if (!line || line->isSource != !!isSource || AMCL_DAudio_GetError(line)) return;
    hint = __atomic_load_n(&line->interrupt, __ATOMIC_SEQ_CST);
    if (hint == AUDIOSTREAM_INTERRUPT_HINT_PAUSE) {
        __atomic_store_n(&line->copyEnabled, 0, __ATOMIC_SEQ_CST);
        if (line->platformRunning) {
            OH_AudioStream_State state;
            result = stream_state(line, &state);
            if (result == AUDIOSTREAM_SUCCESS && state == AUDIOSTREAM_STATE_RUNNING)
                result = stream_pause(line);
            if (result != AUDIOSTREAM_SUCCESS) record_error(line, result);
            line->platformRunning = 0;
        }
    } else if (hint == AUDIOSTREAM_INTERRUPT_HINT_RESUME) {
        int expected = hint;
        if (__atomic_compare_exchange_n(&line->interrupt, &expected, AUDIOSTREAM_INTERRUPT_HINT_NONE,
                                        0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST) && line->wantedRunning &&
            (line->isSource || !__atomic_load_n(&line->muted, __ATOMIC_SEQ_CST))) {
            __atomic_store_n(&line->copyEnabled, 1, __ATOMIC_SEQ_CST);
            result = stream_start(line);
            if (result == AUDIOSTREAM_SUCCESS) line->platformRunning = line->everStarted = 1;
            else { __atomic_store_n(&line->copyEnabled, 0, __ATOMIC_SEQ_CST); record_error(line, result); }
        }
    }
    if (!line->isSource && !AMCL_DAudio_GetError(line)) {
        /* 共享 MUTE 提示停止真实捕获，不生成伪静音数据；解除后仅恢复用户仍要求的流。 */
        const int muted = __atomic_load_n(&line->muted, __ATOMIC_SEQ_CST);
        if (muted && line->platformRunning) {
            __atomic_store_n(&line->copyEnabled, 0, __ATOMIC_SEQ_CST);
            result = stream_pause(line);
            if (result != AUDIOSTREAM_SUCCESS) record_error(line, result);
            else line->platformRunning = 0;
        } else if (!muted && line->wantedRunning && !line->platformRunning &&
            __atomic_load_n(&line->interrupt, __ATOMIC_SEQ_CST) != AUDIOSTREAM_INTERRUPT_HINT_PAUSE) {
            __atomic_store_n(&line->copyEnabled, 1, __ATOMIC_SEQ_CST);
            result = stream_start(line);
            if (result == AUDIOSTREAM_SUCCESS) line->platformRunning = line->everStarted = 1;
            else { __atomic_store_n(&line->copyEnabled, 0, __ATOMIC_SEQ_CST); record_error(line, result); }
        }
    }
    if (line->isSource && !AMCL_DAudio_GetError(line)) {
        const int gain = __atomic_load_n(&line->muted, __ATOMIC_SEQ_CST) ? 2 :
                         __atomic_load_n(&line->ducked, __ATOMIC_SEQ_CST) ? 1 : 0;
        if (gain != line->appliedGain) {
            result = OH_AudioRenderer_SetVolume(line->renderer, gain == 2 ? 0.0f : gain == 1 ? 0.2f : 1.0f);
            if (result != AUDIOSTREAM_SUCCESS) record_error(line, result);
            else line->appliedGain = gain;
        }
        /* 用户未显式drain/查位置时，原line monitor也应停止已经无需继续的尾静音。
         * 200ms只限制后台查询频率；显式位置/drain仍直接读取系统，不用时间推算帧数。 */
        if (line->platformRunning && line->playback &&
            __atomic_load_n(&line->playback->needsObservation, __ATOMIC_ACQUIRE) &&
            amcl_playback_needs_padding(line->playback)) {
            struct timespec now;
            if (!clock_gettime(CLOCK_MONOTONIC, &now)) {
                const int64_t nanos = (int64_t)now.tv_sec * INT64_C(1000000000) + now.tv_nsec;
                if (nanos - line->lastServiceObservationNs >= INT64_C(200000000)) {
                    (void)observe_playback(line);
                    line->lastServiceObservationNs = nanos;
                }
            }
        }
    }
}

int DAUDIO_Start(void *id, int isSource)
{
    AmclHostedLine *host = amcl_hosted_line(id);
    if (host) return host->line.isSource == !!isSource && amcl_hosted_result(host, host->api->start(host->handle));
    AmclLine *line = (AmclLine *)id;
    OH_AudioStream_Result result;
    if (!line || line->isSource != !!isSource || AMCL_DAudio_GetError(line)) return FALSE;
    DAUDIO_Service(line, isSource);
    if (AMCL_DAudio_GetError(line)) return FALSE;
    if (__atomic_load_n(&line->interrupt, __ATOMIC_SEQ_CST) == AUDIOSTREAM_INTERRUPT_HINT_PAUSE ||
        (!line->isSource && __atomic_load_n(&line->muted, __ATOMIC_SEQ_CST))) {
        line->wantedRunning = 1;
        return TRUE;
    }
    if (line->platformRunning) return TRUE;
    __atomic_store_n(&line->copyEnabled, 1, __ATOMIC_SEQ_CST);
    result = stream_start(line);
    if (result != AUDIOSTREAM_SUCCESS) {
        __atomic_store_n(&line->copyEnabled, 0, __ATOMIC_SEQ_CST);
        record_error(line, result);
        return FALSE;
    }
    line->wantedRunning = line->platformRunning = line->everStarted = 1;
    return AMCL_DAudio_GetError(line) ? FALSE : TRUE;
}

int DAUDIO_Stop(void *id, int isSource)
{
    AmclHostedLine *host = amcl_hosted_line(id);
    if (host) return host->line.isSource == !!isSource && amcl_hosted_result(host, host->api->stop(host->handle));
    AmclLine *line = (AmclLine *)id;
    OH_AudioStream_Result result = AUDIOSTREAM_SUCCESS;
    if (!line || line->isSource != !!isSource) return FALSE;
    if (line->isSource && line->platformRunning) (void)observe_playback(line);
    line->wantedRunning = 0;
    __atomic_store_n(&line->copyEnabled, 0, __ATOMIC_SEQ_CST);
    if (line->platformRunning) {
        OH_AudioStream_State state;
        result = stream_state(line, &state);
        if (result == AUDIOSTREAM_SUCCESS && state == AUDIOSTREAM_STATE_RUNNING)
            result = stream_pause(line);
    }
    if (result != AUDIOSTREAM_SUCCESS) { record_error(line, result); return FALSE; }
    line->platformRunning = 0;
    if (!wait_callbacks(line->callback)) { record_error(line, AUDIOSTREAM_ERROR_ILLEGAL_STATE); return FALSE; }
    return TRUE;
}

void DAUDIO_Close(void *id, int isSource)
{
    (void)isSource;
    (void)AMCL_DAudio_Close(id);
}

int AMCL_DAudio_Close(void *id)
{
    AmclHostedLine *host = amcl_hosted_line(id);
    return host ? amcl_hosted_close(host) : id ? destroy_line((AmclLine *)id) : 0;
}

/* 上游负责 Java 数组及转换；这里只有 native 完整帧复制，不保留传入缓冲的借用指针。 */
int DAUDIO_Write(void *id, char *data, int byteSize)
{
    AmclHostedLine *host = amcl_hosted_line(id);
    if (host) return amcl_hosted_io(host, (unsigned char *)data, byteSize, TRUE);
    AmclLine *line = (AmclLine *)id;
    uint64_t written, read, space;
    int bytes, offset, first;
    if (!line || !line->isSource || byteSize < 0 || (byteSize && !data) || byteSize % line->frameSize) return -1;
    DAUDIO_Service(line, TRUE);
    if (AMCL_DAudio_GetError(line)) return -1;
    written = __atomic_load_n(&line->written, __ATOMIC_RELAXED);
    read = __atomic_load_n(&line->read, __ATOMIC_ACQUIRE);
    space = (uint64_t)line->capacity - (written - read);
    bytes = space < (uint64_t)byteSize ? (int)space : byteSize;
    if (!bytes) return 0;
    offset = (int)(written % (uint64_t)line->capacity);
    first = line->capacity - offset;
    if (first > bytes) first = bytes;
    memcpy(line->ring + offset, data, (size_t)first);
    if (first < bytes) memcpy(line->ring, data + first, (size_t)(bytes - first));
    __atomic_store_n(&line->written, written + (uint64_t)bytes, __ATOMIC_RELEASE);
    return bytes;
}

/* 捕获只返回已经完整发布且未被覆盖的实际 PCM；无数据返回0，原 Java read 循环负责等待。 */
int DAUDIO_Read(void *id, char *data, int byteSize)
{
    AmclHostedLine *host = amcl_hosted_line(id);
    if (host) return amcl_hosted_io(host, (unsigned char *)data, byteSize, FALSE);
    AmclLine *line = (AmclLine *)id;
    if (!line || line->isSource) return -1;
    DAUDIO_Service(line, FALSE);
    if (AMCL_DAudio_GetError(line)) return -1;
    return amcl_capture_read(&line->capture, data, byteSize);
}

int DAUDIO_GetBufferSize(void *id, int isSource)
{
    AmclLine *line = (AmclLine *)id;
    return line && line->isSource == !!isSource ? line->capacity : 0;
}

int DAUDIO_GetAvailable(void *id, int isSource)
{
    AmclHostedLine *host = amcl_hosted_line(id);
    if (host) {
        if (host->line.isSource != !!isSource) return 0;
        const int available = host->api->available(host->handle);
        return amcl_hosted_result(host, available) ? available / (host->channels * 4) * host->line.frameSize : 0;
    }
    AmclLine *line = (AmclLine *)id;
    if (!line || line->isSource != !!isSource) return 0;
    DAUDIO_Service(line, isSource);
    if (AMCL_DAudio_GetError(line)) return 0;
    if (!line->isSource) return amcl_capture_available(&line->capture);
    return line->capacity - (int)(__atomic_load_n(&line->written, __ATOMIC_ACQUIRE) -
                                  __atomic_load_n(&line->read, __ATOMIC_ACQUIRE));
}

/* 软件排队与系统待呈现的用户PCM分别计数。真实静音只推进平台坐标，不能减少用户
 * pending直到系统呈现位置实际跨过对应用户区间；跨空隙的新数据也不会提前完成。 */
static uint64_t pending_bytes(AmclLine *line)
{
    const uint64_t read = __atomic_load_n(&line->read, __ATOMIC_ACQUIRE);
    const uint64_t submitted = read - line->epochRead;
    const uint64_t queued = __atomic_load_n(&line->written, __ATOMIC_ACQUIRE) - read;
    uint64_t presented = observe_playback(line);
    /* callback可能在前面的read快照后继续提交，不能因更新较新的观察结果而unsigned下溢。 */
    if (presented > submitted / (uint64_t)line->frameSize) presented = submitted / (uint64_t)line->frameSize;
    return queued + submitted - presented * (uint64_t)line->frameSize;
}

int DAUDIO_StillDraining(void *id, int isSource)
{
    AmclHostedLine *host = amcl_hosted_line(id);
    if (host) {
        if (host->line.isSource != !!isSource) return FALSE;
        if (!isSource) return DAUDIO_GetAvailable(id, isSource) > 0;
        if (!amcl_hosted_result(host, host->api->requestFinish(host->handle))) return FALSE;
        return amcl_hosted_pending(host) != 0;
    }
    AmclLine *line = (AmclLine *)id;
    if (!line || line->isSource != !!isSource) return FALSE;
    DAUDIO_Service(line, isSource);
    if (!line->isSource) return amcl_capture_available(&line->capture) != 0;
    return pending_bytes(line) != 0;
}

INT64 DAUDIO_GetBytePosition(void *id, int isSource, INT64 javaBytePos)
{
    AmclHostedLine *host = amcl_hosted_line(id);
    if (host) {
        if (host->line.isSource != !!isSource) return javaBytePos;
        if (!isSource) {
            const int64_t frames = host->api->framePosition(host->handle);
            if (frames < 0 || frames > INT64_MAX / host->line.frameSize) {
                record_error(&host->line, AMCL_AUDIO_PLATFORM); return 0;
            }
            return frames * host->line.frameSize;
        }
        const uint64_t pending = amcl_hosted_pending(host);
        return javaBytePos >= 0 && pending <= (uint64_t)javaBytePos / host->line.frameSize
            ? javaBytePos - (INT64)(pending * host->line.frameSize) : 0;
    }
    AmclLine *line = (AmclLine *)id;
    uint64_t pending;
    if (!line || line->isSource != !!isSource) return javaBytePos;
    DAUDIO_Service(line, isSource);
    if (!line->isSource) return (INT64)amcl_capture_position(&line->capture);
    pending = pending_bytes(line);
    return javaBytePos >= 0 && pending <= (uint64_t)javaBytePos ? javaBytePos - (INT64)pending : 0;
}

int DAUDIO_Flush(void *id, int isSource)
{
    AmclHostedLine *host = amcl_hosted_line(id);
    if (host) {
        if (host->line.isSource != !!isSource || !amcl_hosted_result(host, host->api->flush(host->handle))) return FALSE;
        const int64_t frames = host->api->framePosition(host->handle);
        if (frames < 0) { record_error(&host->line, AMCL_AUDIO_PLATFORM); return FALSE; }
        host->submittedFrames = (uint64_t)frames;
        return TRUE;
    }
    AmclLine *line = (AmclLine *)id;
    int resume;
    OH_AudioStream_Result result;
    if (!line || line->isSource != !!isSource || AMCL_DAudio_GetError(line)) return FALSE;
    resume = line->wantedRunning;
    if (!DAUDIO_Stop(line, isSource)) return FALSE;
    if (!line->isSource) {
        if (line->everStarted) {
            result = OH_AudioCapturer_Flush(line->capturer);
            if (result != AUDIOSTREAM_SUCCESS) { record_error(line, result); return FALSE; }
        }
        amcl_capture_flush(&line->capture);
        return !resume || DAUDIO_Start(line, isSource);
    }
    /* 从未提交平台数据的 prepared 流可能不接受 Flush；此时只存在自有软件队列。
     * 已提交过用户帧才调用真实Flush。成功后系统呈现坐标归零，累计写入数无关。 */
    if (__atomic_load_n(&line->read, __ATOMIC_ACQUIRE) != line->epochRead) {
        result = OH_AudioRenderer_Flush(line->renderer);
        if (result != AUDIOSTREAM_SUCCESS) { record_error(line, result); return FALSE; }
    }
    line->epochRead = __atomic_load_n(&line->written, __ATOMIC_ACQUIRE);
    __atomic_store_n(&line->read, line->epochRead, __ATOMIC_RELEASE);
    amcl_playback_reset(line->playback);
    line->clockOrigin = 0;
    line->lastRawFrame = line->lastRawTimestamp = line->lastServiceObservationNs = 0;
    line->hasTimestamp = 0;
    return !resume || DAUDIO_Start(line, isSource);
}

/* Clip 的 Java bytePosition 已包含 seek/repeat 偏移；此入口无需修改平台 PCM 时钟。 */
void DAUDIO_SetBytePosition(void *id, int isSource, INT64 javaBytePos)
{ (void)id; (void)isSource; (void)javaBytePos; }

int DAUDIO_RequiresServicing(void *id, int isSource)
{ return id && ((AmclLine *)id)->isSource == !!isSource; }

#endif
