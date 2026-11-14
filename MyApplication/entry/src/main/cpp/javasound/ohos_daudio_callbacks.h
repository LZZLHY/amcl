/* JavaSound系统回调的共享、版本化C ABI。
 * HAP与独立CLI从同一份POD/函数体编译。系统只调用正常HAP加载的typed入口；
 * 回调只原子访问此POD和有界复制，不存储/调用自加载函数指针，不触碰CFI状态。
 * 控制、分配、Release和代码租约仍由DAUDIO管理。布局变更必须递增layoutVersion，
 * 宿主表与JDK的版本/尺寸不符时不得注册回调或回退到已知不安全的嵌入本地路径。
 */
#ifndef AMCL_OHOS_DAUDIO_CALLBACKS_H
#define AMCL_OHOS_DAUDIO_CALLBACKS_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <time.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiocapturer.h>
#include "ohos_capture_ring.h"
#include "ohos_playback_timeline.h"
#ifdef __cplusplus
extern "C" {
#define AMCL_DAUDIO_ALIGNOF(type) alignof(type)
#else
#define AMCL_DAUDIO_ALIGNOF(type) _Alignof(type)
#endif

typedef struct AmclLine AmclLine;
/* ctx 的寿命独立于 line：Release 失败时只保留 ctx、系统对象与代码引用。
 * active/owner 使用顺序一致性，使“先登记再读 owner”与“先清 owner 再等退出”形成
 * 明确交接。读取 NULL 的迟到回调不接触已经释放的 line/ring。 */
typedef struct {
    AmclLine *owner;
    unsigned active;
    void *codeLease;
    void *hostLease; /* 嵌入模式中持有正常加载回调表所属宿主；仅控制侧Release后释放。 */
    OH_AudioStreamBuilder *retainedBuilder; /* Destroy 异常失败时保留其回调参数，不能制造悬空指针。 */
} AmclCallback;

struct AmclLine {
    OH_AudioRenderer *renderer;
    OH_AudioCapturer *capturer;
    AmclCallback *callback;
    AmclCaptureRing capture;
    int isSource;                    /* 创建后不变，控制入口必须与 JNI 传入方向一致。 */
    unsigned char *ring;
    uint64_t written;                 /* 只有控制/写入线程推进，release 发布 PCM。 */
    uint64_t read;                    /* 只有音频线程推进；flush 在静止窗口丢弃。 */
    uint64_t epochRead;               /* flush 静止窗口记录；read-epochRead 是有效提交字节。 */
    AmclPlaybackTimeline *playback;   /* 播放独立记录用户区间；Capture为NULL，不额外分配。 */
    int64_t lastServiceObservationNs; /* 仅控制线程使用；只节流后台查询，不推算呈现位置。 */
    uint64_t clockOrigin;             /* 本ABI2保留为0，不能据未证明的路由回退推断写入offset。 */
    int64_t lastRawFrame, lastRawTimestamp;
    int hasTimestamp;
    int capacity;
    int frameSize;
    int silenceByte;                 /* U8的静音为0x80，其它整数PCM为0。 */
    int copyEnabled;
    int copyBusy;
    int error;                       /* 首个错误保持，后续关闭错误另行记录。 */
    int errorReported;               /* 控制JNI已报告首错后，清理用位置查询不重复制造同一异常。 */
    int interrupt;                   /* 只保存暂停/恢复/停止，不由回调调用控制 API。 */
    int ducked;
    int muted;
    int appliedGain;                 /* 0=正常，1=duck，2=mute；只改本 renderer 的增益。 */
    int wantedRunning;
    int platformRunning;
    int everStarted;
};

/* 所有错误记录只保留首因。平台 error callback 传 0 也是非法的错误通知，归为状态错。 */
static inline void record_error(AmclLine *line, int error)
{
    int expected = 0;
    if (!error) error = AUDIOSTREAM_ERROR_ILLEGAL_STATE;
    __atomic_compare_exchange_n(&line->error, &expected, error, 0,
                                __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}

static inline AmclLine *enter_callback(AmclCallback *ctx)
{
    __atomic_add_fetch(&ctx->active, 1, __ATOMIC_SEQ_CST);
    return __atomic_load_n(&ctx->owner, __ATOMIC_SEQ_CST);
}

static inline void leave_callback(AmclCallback *ctx)
{
    __atomic_sub_fetch(&ctx->active, 1, __ATOMIC_SEQ_CST);
}

/* 复制按完整frame执行；用户帧和平台帧分别记账。真实设备在0返回后可能不再推进尾部
 * 呈现时钟，故仅有未确认呈现的用户数据时补实际静音；静音不能增长read或用户位置。
 * 连续用户区间合并，空隙单独保留；区间满时保留用户PCM背压。回调无等待/分配/JNI。 */
static inline int32_t render_data(OH_AudioRenderer *renderer, void *opaque, void *data, int32_t byteSize)
{
    AmclCallback *ctx = (AmclCallback *)opaque;
    AmclLine *line = enter_callback(ctx);
    int bytes = 0, result = 0, expected = 0;
    (void)renderer;
    if (line && line->playback && data && byteSize > 0 &&
        __atomic_load_n(&line->copyEnabled, __ATOMIC_SEQ_CST) &&
        !__atomic_load_n(&line->error, __ATOMIC_SEQ_CST) &&
        __atomic_load_n(&line->interrupt, __ATOMIC_SEQ_CST) != AUDIOSTREAM_INTERRUPT_HINT_PAUSE &&
        __atomic_compare_exchange_n(&line->copyBusy, &expected, 1, 0,
                                    __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
        const uint64_t read = __atomic_load_n(&line->read, __ATOMIC_RELAXED);
        const uint64_t written = __atomic_load_n(&line->written, __ATOMIC_ACQUIRE);
        const uint64_t available = written - read;
        int limit = byteSize - byteSize % line->frameSize;
        bytes = available < (uint64_t)limit ? (int)available : limit;
        if (bytes && !amcl_playback_reserve(line->playback, (uint64_t)(bytes / line->frameSize))) bytes = 0;
        if (bytes) {
            const int offset = (int)(read % (uint64_t)line->capacity);
            int first = line->capacity - offset;
            if (first > bytes) first = bytes;
            memcpy(data, line->ring + offset, (size_t)first);
            if (first < bytes) memcpy((char *)data + first, line->ring, (size_t)(bytes - first));
            /* 一个计数同时代表已消费和待平台呈现，避免读取两个原子造成重复/遗漏计数。 */
            __atomic_store_n(&line->read, read + (uint64_t)bytes, __ATOMIC_RELEASE);
        }
        result = bytes;
        if (amcl_playback_needs_padding(line->playback) && result < limit) {
            memset((char *)data + result, line->silenceByte, (size_t)(limit - result));
            result = limit;
            __atomic_store_n(&line->playback->needsObservation, 1, __ATOMIC_RELEASE);
        }
        amcl_playback_commit(line->playback, (uint64_t)(result / line->frameSize));
        __atomic_store_n(&line->copyBusy, 0, __ATOMIC_RELEASE);
    }
    leave_callback(ctx);
    return result;
}

static inline void render_error(OH_AudioRenderer *renderer, void *opaque, OH_AudioStream_Result error)
{
    AmclCallback *ctx = (AmclCallback *)opaque;
    AmclLine *line = enter_callback(ctx);
    (void)renderer;
    if (line) record_error(line, (int)error);
    leave_callback(ctx);
}

static inline void render_interrupt(OH_AudioRenderer *renderer, void *opaque,
                             OH_AudioInterrupt_ForceType force, OH_AudioInterrupt_Hint hint)
{
    AmclCallback *ctx = (AmclCallback *)opaque;
    AmclLine *line = enter_callback(ctx);
    (void)renderer;
    if (line) {
        if (hint == AUDIOSTREAM_INTERRUPT_HINT_STOP) record_error(line, AUDIOSTREAM_ERROR_ILLEGAL_STATE);
        if (hint == AUDIOSTREAM_INTERRUPT_HINT_PAUSE || hint == AUDIOSTREAM_INTERRUPT_HINT_RESUME ||
            hint == AUDIOSTREAM_INTERRUPT_HINT_STOP)
            __atomic_store_n(&line->interrupt, (int)hint, __ATOMIC_SEQ_CST);
        /* FORCE 已由平台执行；SHARE 是应用需处理的提示，不能把它当作已经完成。
         * 这里只投递本流增益意图，Java 软件音量仍保留，绝不更改系统/应用全局音量。 */
        if (hint == AUDIOSTREAM_INTERRUPT_HINT_DUCK && force == AUDIOSTREAM_INTERRUPT_SHARE)
            __atomic_store_n(&line->ducked, 1, __ATOMIC_SEQ_CST);
        else if (hint == AUDIOSTREAM_INTERRUPT_HINT_UNDUCK)
            __atomic_store_n(&line->ducked, 0, __ATOMIC_SEQ_CST);
        if (hint == AUDIOSTREAM_INTERRUPT_HINT_MUTE && force == AUDIOSTREAM_INTERRUPT_SHARE)
            __atomic_store_n(&line->muted, 1, __ATOMIC_SEQ_CST);
        else if (hint == AUDIOSTREAM_INTERRUPT_HINT_UNMUTE)
            __atomic_store_n(&line->muted, 0, __ATOMIC_SEQ_CST);
    }
    leave_callback(ctx);
}

/* 捕获回调只处理平台交付的完整 PCM 帧。未启动/已暂停/已撤销 owner 时不计进度；
 * 覆盖环按 Java 合同保留最新数据，任何无效长度都锁存真实失败而非补零伪造输入。 */
static inline void capture_data(OH_AudioCapturer *capturer, void *opaque, void *data, int32_t byteSize)
{
    AmclCallback *ctx = (AmclCallback *)opaque;
    AmclLine *line = enter_callback(ctx);
    (void)capturer;
    if (line && !line->isSource && __atomic_load_n(&line->copyEnabled, __ATOMIC_SEQ_CST) &&
        !__atomic_load_n(&line->error, __ATOMIC_SEQ_CST) &&
        !__atomic_load_n(&line->muted, __ATOMIC_SEQ_CST) &&
        __atomic_load_n(&line->interrupt, __ATOMIC_SEQ_CST) != AUDIOSTREAM_INTERRUPT_HINT_PAUSE) {
        if (amcl_capture_push(&line->capture, data, byteSize) < 0)
            record_error(line, AUDIOSTREAM_ERROR_ILLEGAL_STATE);
    }
    leave_callback(ctx);
}

/* 两种流的事件 ABI 类型不同，但内部 owner/错误/中断合同完全相同，不强转函数指针。 */
static inline void capture_error(OH_AudioCapturer *capturer, void *opaque, OH_AudioStream_Result error)
{ (void)capturer; render_error(NULL, opaque, error); }

static inline void capture_interrupt(OH_AudioCapturer *capturer, void *opaque,
                             OH_AudioInterrupt_ForceType force, OH_AudioInterrupt_Hint hint)
{ (void)capturer; render_interrupt(NULL, opaque, force, hint); }

/* table和POD各自版本化。全部函数指针使用SDK的精确类型，没有void(*)泛型转跳。
 * line/context/ring尺寸及对齐在注册前互检，正常音频回调不增加逐帧ABI分支。
 */
#define AMCL_DAUDIO_CALLBACK_ABI_V2 UINT32_C(2)
#define AMCL_DAUDIO_CALLBACK_LAYOUT_V2 UINT32_C(2)
typedef struct {
    uint32_t abiVersion;
    uint32_t tableSize;
    uint32_t layoutVersion;
    uint32_t lineSize;
    uint32_t contextSize;
    uint32_t ringSize;
    uint32_t timelineSize;
    uint32_t timelineAlignment;
    uint32_t lineAlignment;
    uint32_t contextAlignment;
    OH_AudioRenderer_OnWriteDataCallbackAdvanced renderData;
    OH_AudioRenderer_OnErrorCallback renderError;
    OH_AudioRenderer_OnInterruptCallback renderInterrupt;
    OH_AudioCapturer_OnReadDataCallback captureData;
    OH_AudioCapturer_OnErrorCallback captureError;
    OH_AudioCapturer_OnInterruptCallback captureInterrupt;
} AmclDAudioCallbackAbiV2;

/* 独立CLI用此本地表；HAP getter也返回此表，确保六个实现及其类型只有一个事实源。 */
static inline const AmclDAudioCallbackAbiV2* amcl_daudio_local_callbacks_v2(void) {
    static const AmclDAudioCallbackAbiV2 table = {
        AMCL_DAUDIO_CALLBACK_ABI_V2, sizeof(AmclDAudioCallbackAbiV2),
        AMCL_DAUDIO_CALLBACK_LAYOUT_V2, sizeof(AmclLine), sizeof(AmclCallback), sizeof(AmclCaptureRing),
        sizeof(AmclPlaybackTimeline), AMCL_DAUDIO_ALIGNOF(AmclPlaybackTimeline),
        AMCL_DAUDIO_ALIGNOF(AmclLine), AMCL_DAUDIO_ALIGNOF(AmclCallback),
        render_data, render_error, render_interrupt, capture_data, capture_error, capture_interrupt
    };
    return &table;
}

/* 所有声明字段逐项检查，不能仅检查函数地址非零或依赖偶然相同的总大小。 */
static inline int amcl_daudio_callbacks_valid_v2(const AmclDAudioCallbackAbiV2* table) {
    return table && table->abiVersion == AMCL_DAUDIO_CALLBACK_ABI_V2 &&
        table->tableSize == sizeof(*table) && table->layoutVersion == AMCL_DAUDIO_CALLBACK_LAYOUT_V2 &&
        table->lineSize == sizeof(AmclLine) && table->contextSize == sizeof(AmclCallback) &&
        table->ringSize == sizeof(AmclCaptureRing) && table->timelineSize == sizeof(AmclPlaybackTimeline) &&
        table->timelineAlignment == AMCL_DAUDIO_ALIGNOF(AmclPlaybackTimeline) &&
        table->lineAlignment == AMCL_DAUDIO_ALIGNOF(AmclLine) &&
        table->contextAlignment == AMCL_DAUDIO_ALIGNOF(AmclCallback) &&
        table->renderData && table->renderError && table->renderInterrupt &&
        table->captureData && table->captureError && table->captureInterrupt;
}

/* 正常SDK加载的宿主libentry公开入口；只返回只读表，不建立全局line registry或新线程。 */
__attribute__((visibility("default")))
const AmclDAudioCallbackAbiV2* amcl_javasound_callbacks_v2(void);
#ifdef __cplusplus
}
#endif
#undef AMCL_DAUDIO_ALIGNOF
#endif
