/* 将系统真实呈现位置映射到用户PCM帧。系统帧包含为推进尾部而实际写入的静音，
 * 用户帧只由原PCM消费增长。一个callback生产者、一个Java lockNative控制消费者；
 * 连续PCM合并为一个活动区间，仅跨静音空隙时保存已关闭区间。回调无分配/锁/等待。
 * 有界区间队列满时不消费新用户PCM，控制侧取得真实位置后回收并继续，不能覆盖记录。
 */
#ifndef AMCL_OHOS_PLAYBACK_TIMELINE_H
#define AMCL_OHOS_PLAYBACK_TIMELINE_H
#include <stdint.h>
#include <string.h>

#define AMCL_PLAYBACK_CLOSED_SPANS 256
typedef struct {
    uint64_t begin, end, userBegin;
} AmclPlaybackSpan;

typedef struct {
    AmclPlaybackSpan spans[AMCL_PLAYBACK_CLOSED_SPANS];
    uint64_t head, tail;              /* 完成区间SPSC队列；发布tail后正文保持不变。 */
    uint64_t sequence;                /* 活动区间快照版本；正文也为原子，避免seqlock数据竞争。 */
    uint64_t activeBegin, activeEnd, activeUserBegin;
    uint64_t streamFrames, userFrames;
    uint64_t observedFrame, observedUser; /* 只有控制消费者更新，callback只读取。 */
    int needsObservation;             /* 有静音或队列压力时，允许已有line monitor查询位置。 */
} AmclPlaybackTimeline;

/** 仅在callback gate已停止且在途访问归零时重置，Flush后系统呈现坐标从0开始。 */
static inline void amcl_playback_reset(AmclPlaybackTimeline *timeline)
{ memset(timeline, 0, sizeof(*timeline)); }

/** 在复制用户字节前预留区间。失败返回0时调用方必须保留原软件队列，不能先消费再丢弃。 */
static inline int amcl_playback_reserve(AmclPlaybackTimeline *timeline, uint64_t frames)
{
    uint64_t stream = __atomic_load_n(&timeline->streamFrames, __ATOMIC_RELAXED);
    uint64_t users = __atomic_load_n(&timeline->userFrames, __ATOMIC_RELAXED);
    uint64_t begin = __atomic_load_n(&timeline->activeBegin, __ATOMIC_RELAXED);
    uint64_t end = __atomic_load_n(&timeline->activeEnd, __ATOMIC_RELAXED);
    uint64_t userBegin = __atomic_load_n(&timeline->activeUserBegin, __ATOMIC_RELAXED);
    if (!frames) return 1;
    if (frames > UINT64_MAX - stream || frames > UINT64_MAX - users) return 0;
    if (end > begin && end != stream) {
        /* 已经由控制侧确认全部呈现的活动区间无需再排队；发布观察帧前已发布用户计数。 */
        if (end > __atomic_load_n(&timeline->observedFrame, __ATOMIC_ACQUIRE)) {
            const uint64_t tail = __atomic_load_n(&timeline->tail, __ATOMIC_RELAXED);
            const uint64_t head = __atomic_load_n(&timeline->head, __ATOMIC_ACQUIRE);
            if (tail - head == AMCL_PLAYBACK_CLOSED_SPANS) {
                __atomic_store_n(&timeline->needsObservation, 1, __ATOMIC_RELEASE);
                return 0;
            }
            timeline->spans[tail % AMCL_PLAYBACK_CLOSED_SPANS].begin = begin;
            timeline->spans[tail % AMCL_PLAYBACK_CLOSED_SPANS].end = end;
            timeline->spans[tail % AMCL_PLAYBACK_CLOSED_SPANS].userBegin = userBegin;
            __atomic_store_n(&timeline->tail, tail + 1, __ATOMIC_RELEASE);
        }
        begin = stream; userBegin = users;
    } else if (end == begin) {
        begin = stream; userBegin = users;
    }
    __atomic_add_fetch(&timeline->sequence, UINT64_C(1), __ATOMIC_ACQ_REL);
    __atomic_store_n(&timeline->activeBegin, begin, __ATOMIC_RELAXED);
    __atomic_store_n(&timeline->activeEnd, stream + frames, __ATOMIC_RELAXED);
    __atomic_store_n(&timeline->activeUserBegin, userBegin, __ATOMIC_RELAXED);
    __atomic_store_n(&timeline->userFrames, users + frames, __ATOMIC_RELEASE);
    __atomic_add_fetch(&timeline->sequence, UINT64_C(1), __ATOMIC_RELEASE);
    return 1;
}

/** callback真实返回给系统的帧数才进入平台坐标。静音和用户PCM都计平台帧，分别记账。 */
static inline void amcl_playback_commit(AmclPlaybackTimeline *timeline, uint64_t frames)
{
    const uint64_t before = __atomic_load_n(&timeline->streamFrames, __ATOMIC_RELAXED);
    __atomic_store_n(&timeline->streamFrames, before + frames, __ATOMIC_RELEASE);
}

static inline int amcl_playback_needs_padding(AmclPlaybackTimeline *timeline)
{
    return __atomic_load_n(&timeline->userFrames, __ATOMIC_ACQUIRE) >
           __atomic_load_n(&timeline->observedUser, __ATOMIC_ACQUIRE);
}

/** frame来自成功的真实系统查询；绝不使用FramesWritten或墙钟推算。取不到一致活动
 * 快照时保留已确认下界，下一次查询再推进。只有完整通过的关闭区间才允许重用其槽。 */
static inline uint64_t amcl_playback_observe(AmclPlaybackTimeline *timeline, uint64_t frame)
{
    const uint64_t submitted = __atomic_load_n(&timeline->streamFrames, __ATOMIC_ACQUIRE);
    const uint64_t previous = __atomic_load_n(&timeline->observedFrame, __ATOMIC_RELAXED);
    uint64_t users = __atomic_load_n(&timeline->observedUser, __ATOMIC_RELAXED);
    uint64_t head = __atomic_load_n(&timeline->head, __ATOMIC_RELAXED);
    const uint64_t tail = __atomic_load_n(&timeline->tail, __ATOMIC_ACQUIRE);
    unsigned retry;
    if (frame > submitted) frame = submitted;
    if (frame < previous) frame = previous; /* Flush通过reset显式开始新坐标，不倒退已确认用户位置。 */
    while (head != tail) {
        const AmclPlaybackSpan span = timeline->spans[head % AMCL_PLAYBACK_CLOSED_SPANS];
        if (frame > span.begin) {
            const uint64_t end = frame < span.end ? frame : span.end;
            const uint64_t value = span.userBegin + end - span.begin;
            if (value > users) users = value;
        }
        if (frame < span.end) break;
        ++head;
    }
    __atomic_store_n(&timeline->head, head, __ATOMIC_RELEASE);
    for (retry = 0; retry < 3; ++retry) {
        const uint64_t first = __atomic_load_n(&timeline->sequence, __ATOMIC_ACQUIRE);
        uint64_t begin, end, userBegin, value;
        if (first & 1) continue;
        begin = __atomic_load_n(&timeline->activeBegin, __ATOMIC_RELAXED);
        end = __atomic_load_n(&timeline->activeEnd, __ATOMIC_RELAXED);
        userBegin = __atomic_load_n(&timeline->activeUserBegin, __ATOMIC_RELAXED);
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        if (first != __atomic_load_n(&timeline->sequence, __ATOMIC_ACQUIRE)) continue;
        if (end > begin && frame > begin) {
            if (end > frame) end = frame;
            value = userBegin + end - begin;
            if (value > users) users = value;
        }
        break;
    }
    /* 先发布用户下界，后发布对应平台帧，producer才可依据平台帧省去已完成历史区间。 */
    __atomic_store_n(&timeline->observedUser, users, __ATOMIC_RELEASE);
    __atomic_store_n(&timeline->observedFrame, frame, __ATOMIC_RELEASE);
    return users;
}
#endif
