/* 内建 DirectAudioDevice 与启动器 SPI 共用已签名的 PCM owner。
 * 此文件只编入 libjsound。已有 ABI2 AmclLine 保持原布局；托管 line 的扩展只由本
 * 文件使用，不注册旧数据回调。上游 lockNative 串行访问 line，系统回调仍留在宿主。
 */
#ifndef AMCL_OHOS_DAUDIO_HOST_H
#define AMCL_OHOS_DAUDIO_HOST_H
#include <unistd.h>
#include <math.h>
#include "../audio/audio_runtime.h"

#define AMCL_HOSTED_LINE_TAG 0x41484f53
typedef struct {
    AmclLine line; /* 首成员地址就是 JNI 的不透明句柄，ABI2 回调布局没有改变。 */
    const AmclAudioApiV1 *api;
    void *lease;
    uint64_t handle, submittedFrames;
    int bits, channels, scratchFrames;
    float *scratch;
} AmclHostedLine;

static AmclHostedLine *amcl_hosted_line(void *id)
{
    AmclLine *line = (AmclLine *)id;
    return line && line->hasTimestamp == AMCL_HOSTED_LINE_TAG ? (AmclHostedLine *)id : NULL;
}

/* 仅作为模式判据；存在但失效的宿主不能悄悄退回独立捕获绕过录音意图/前台撤销。 */
static int amcl_hosted_requested(void) { return getenv(AMCL_AUDIO_HOST_ENV) != NULL; }

/* 环境文本只帮助发现：先核真实导出，再持有同一系统映像，最后核全部 C 函数与会话。 */
static const AmclAudioApiV1 *amcl_hosted_acquire(void **lease)
{
    const char *text = getenv(AMCL_AUDIO_HOST_ENV);
    unsigned version = 0, pid = 0;
    unsigned long long raw = 0;
    char tail;
    Dl_info identity, check;
    const AmclAudioApiV1 *(*getter)(void);
    const AmclAudioApiV1 *api;
    const void *functions[14];
    unsigned i;
    *lease = NULL;
    if (!text || strlen(text) > 100 || sscanf(text, "%u:%u:%llx%c", &version, &pid, &raw, &tail) != 3 ||
        version != 1 || pid != (unsigned)getpid() || !raw) return NULL;
    getter = (const AmclAudioApiV1 *(*)(void))(uintptr_t)raw;
    if (!dladdr((void *)getter, &identity) || !identity.dli_fname || !identity.dli_fbase ||
        !identity.dli_sname || strcmp(identity.dli_sname, "amclAudioHostGetV1") ||
        identity.dli_saddr != (void *)getter) return NULL;
    *lease = dlopen(identity.dli_fname, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    if (!*lease || dlsym(*lease, "amclAudioHostGetV1") != (void *)getter) goto fail;
    api = getter();
    if (!api || api->magic != AMCL_AUDIO_MAGIC || api->abi != AMCL_AUDIO_ABI ||
        api->size != sizeof(*api) || api->pid != pid || !api->session) goto fail;
    functions[0] = (void *)api->open; functions[1] = (void *)api->start;
    functions[2] = (void *)api->stop; functions[3] = (void *)api->flush;
    functions[4] = (void *)api->drain; functions[5] = (void *)api->close;
    functions[6] = (void *)api->read; functions[7] = (void *)api->write;
    functions[8] = (void *)api->available; functions[9] = (void *)api->bufferSize;
    functions[10] = (void *)api->state; functions[11] = (void *)api->frameBytes;
    functions[12] = (void *)api->framePosition; functions[13] = (void *)api->requestFinish;
    for (i = 0; i < 14; ++i)
        if (!functions[i] || !dladdr(functions[i], &check) || check.dli_fbase != identity.dli_fbase) goto fail;
    return api;
fail:
    if (*lease) dlclose(*lease);
    *lease = NULL;
    return NULL;
}

static int amcl_hosted_result(AmclHostedLine *line, int result)
{
    if (result < 0) record_error(&line->line, result);
    return result >= 0;
}

/* 保持 Java 整数 PCM 的原始帧大小/字节位置，宿主仅接受统一的交错 F32LE。
 * 8位是无符号，16/24/32位是有符号little-endian；不把32位整数错误解释为float位型。
 */
static float amcl_pcm_decode(const unsigned char *source, int bits)
{
    uint32_t value = source[0];
    unsigned i;
    if (bits == 8) return ((int)value - 128) / 128.0f;
    for (i = 1; i < (unsigned)bits / 8; ++i) value |= (uint32_t)source[i] << (i * 8);
    const int64_t signedValue = (value & (UINT32_C(1) << (bits - 1)))
        ? (int64_t)value - (INT64_C(1) << bits) : (int64_t)value;
    return (float)((double)signedValue / (double)(INT64_C(1) << (bits - 1)));
}

static int amcl_pcm_encode(unsigned char *target, int bits, float sample)
{
    unsigned i;
    int64_t value;
    /* 无法表示的真实平台样本明确失败，不用填零掩盖输入质量或触发整数转换未定义行为。 */
    if (!isfinite(sample)) return 0;
    const int64_t scale = INT64_C(1) << (bits - 1);
    value = sample <= -1 ? -scale : sample >= 1 ? scale - 1 : (int64_t)((double)sample * (double)scale);
    if (bits == 8) value += 128;
    const uint32_t raw = (uint32_t)value;
    for (i = 0; i < (unsigned)bits / 8; ++i) target[i] = (unsigned char)(raw >> (i * 8));
    return 1;
}

static void *amcl_hosted_open(int isSource, int rate, int bits, int channels, int bufferBytes)
{
    void *lease = NULL;
    const AmclAudioApiV1 *api = amcl_hosted_acquire(&lease);
    AmclHostedLine *line;
    int frames, result;
    if (!api) return NULL;
    if (rate < 8000 || rate > 192000 || channels < 1 || channels > 2 ||
        (bits != 8 && bits != 16 && bits != 24 && bits != 32) || bufferBytes < channels * (bits / 8)) goto fail;
    frames = bufferBytes / (channels * (bits / 8));
    if (frames > (8 * 1024 * 1024) / (channels * 4)) frames = (8 * 1024 * 1024) / (channels * 4);
    line = (AmclHostedLine *)calloc(1, sizeof(*line));
    if (!line) goto fail;
    line->api = api; line->lease = lease; line->bits = bits; line->channels = channels;
    line->scratchFrames = frames < 4096 ? frames : 4096;
    line->scratch = (float *)malloc((size_t)line->scratchFrames * channels * sizeof(float));
    if (!line->scratch) { free(line); goto fail; }
    result = api->open(!isSource, rate, channels, AMCL_AUDIO_F32LE, frames * channels * 4, &line->handle);
    if (result < 0 || !line->handle) { free(line->scratch); free(line); goto fail; }
    line->line.hasTimestamp = AMCL_HOSTED_LINE_TAG;
    line->line.isSource = !!isSource;
    line->line.frameSize = channels * (bits / 8);
    line->line.capacity = frames * line->line.frameSize;
    return line;
fail:
    dlclose(lease);
    return NULL;
}

/* 所有借用都在本次调用内结束；每次最多转换4096帧，不在系统回调分配/访问Java。 */
static int amcl_hosted_io(AmclHostedLine *line, unsigned char *data, int bytes, int writing)
{
    int frames, available, converted, i, result;
    if (!data || bytes < 0 || bytes % line->line.frameSize || line->line.isSource != !!writing) return -1;
    if (__atomic_load_n(&line->line.error, __ATOMIC_ACQUIRE)) return -1;
    frames = bytes / line->line.frameSize;
    if (frames > line->scratchFrames) frames = line->scratchFrames;
    available = line->api->available(line->handle);
    if (!amcl_hosted_result(line, available)) return -1;
    if (frames > available / (line->channels * 4)) frames = available / (line->channels * 4);
    if (!frames) return 0;
    converted = frames * line->channels;
    if (writing) {
        for (i = 0; i < converted; ++i) line->scratch[i] = amcl_pcm_decode(data + i * (line->bits / 8), line->bits);
        result = line->api->write(line->handle, line->scratch, converted * 4);
    } else result = line->api->read(line->handle, line->scratch, converted * 4, 0);
    if (!amcl_hosted_result(line, result)) return -1;
    if (result > converted * 4 || result % (line->channels * 4)) {
        record_error(&line->line, AMCL_AUDIO_PLATFORM); return -1;
    }
    frames = result / (line->channels * 4);
    if (writing) line->submittedFrames += (uint64_t)frames;
    else for (i = 0; i < frames * line->channels; ++i)
        if (!amcl_pcm_encode(data + i * (line->bits / 8), line->bits, line->scratch[i])) {
            record_error(&line->line, AMCL_AUDIO_PLATFORM); return -1;
        }
    return frames * line->line.frameSize;
}

static uint64_t amcl_hosted_pending(AmclHostedLine *line)
{
    const int64_t position = line->api->framePosition(line->handle);
    if (position < 0) { record_error(&line->line, AMCL_AUDIO_PLATFORM); return 0; }
    return (uint64_t)position < line->submittedFrames ? line->submittedFrames - (uint64_t)position : 0;
}

static int amcl_hosted_close(AmclHostedLine *line)
{
    const int result = line->api->close(line->handle);
    void *lease = line->lease;
    free(line->scratch); free(line);
    // 音频owner负责保全平台Release失败的回调资源；本适配层没有平台注册的裸回调。
    dlclose(lease);
    return result < 0 ? result : 0;
}
#endif
