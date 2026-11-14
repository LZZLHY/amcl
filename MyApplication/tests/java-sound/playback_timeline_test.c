/* 系统呈现帧与用户帧的独立oracle：真实静音占系统坐标但永不增长用户进度。
 * 包含连续数据合并、多个空隙/部分呈现、队列满背压、Flush和并发保守快照。 */
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include "../../entry/src/main/cpp/javasound/ohos_playback_timeline.h"

static void gaps(void)
{
    AmclPlaybackTimeline t = {0};
    assert(amcl_playback_reserve(&t, 4)); amcl_playback_commit(&t, 8);
    assert(amcl_playback_observe(&t, 2) == 2);
    assert(amcl_playback_observe(&t, 6) == 4); /* 前一段后的静音不能推进用户帧。 */
    assert(amcl_playback_reserve(&t, 3)); amcl_playback_commit(&t, 7);
    assert(amcl_playback_observe(&t, 7) == 4); /* 新PCM已提交，但物理位置仍在前一空隙。 */
    assert(amcl_playback_observe(&t, 9) == 5);
    assert(amcl_playback_observe(&t, 11) == 7 && !amcl_playback_needs_padding(&t));
    assert(amcl_playback_observe(&t, 999) == 7 && t.observedFrame == 15);
    amcl_playback_reset(&t);
    assert(!t.userFrames && !t.streamFrames && !t.head && !t.tail);
    assert(amcl_playback_reserve(&t, 2)); amcl_playback_commit(&t, 2);
    assert(amcl_playback_observe(&t, 2) == 2);
}

static void full(void)
{
    AmclPlaybackTimeline t = {0};
    for (unsigned i = 0; i <= AMCL_PLAYBACK_CLOSED_SPANS; ++i) {
        assert(amcl_playback_reserve(&t, 1)); amcl_playback_commit(&t, 2);
    }
    uint64_t users = t.userFrames, stream = t.streamFrames;
    assert(!amcl_playback_reserve(&t, 1) && t.userFrames == users && t.streamFrames == stream);
    assert(t.tail - t.head == AMCL_PLAYBACK_CLOSED_SPANS && t.needsObservation);
    assert(amcl_playback_observe(&t, 1) == 1);
    assert(amcl_playback_reserve(&t, 1)); amcl_playback_commit(&t, 2);
    assert(amcl_playback_observe(&t, t.streamFrames) == users + 1);
    amcl_playback_reset(&t);
    for (unsigned i = 0; i < 1000000; ++i) {
        assert(amcl_playback_reserve(&t, 1)); amcl_playback_commit(&t, 1);
    }
    assert(t.tail == 0 && amcl_playback_observe(&t, 1000000) == 1000000);
}

static void oracle(void)
{
    AmclPlaybackTimeline t = {0};
    uint64_t expected[200001], position = 0, users = 0, seed = 31337, observed = 0;
    expected[0] = 0;
    for (unsigned step = 0; step < 10000; ++step) {
        seed = seed * UINT64_C(6364136223846793005) + 1;
        unsigned data = (unsigned)(seed >> 32) % 9 + 1;
        unsigned silence = (unsigned)(seed >> 40) % 9;
        if (!amcl_playback_reserve(&t, data)) {
            assert(amcl_playback_observe(&t, position) == users);
            assert(amcl_playback_reserve(&t, data));
        }
        for (unsigned i = 0; i < data; ++i) expected[++position] = ++users;
        for (unsigned i = 0; i < silence; ++i) expected[++position] = users;
        amcl_playback_commit(&t, data + silence);
        if (step % 3 == 0) {
            uint64_t next = position > 30 ? position - 30 : 0;
            if (next < observed) next = observed;
            assert(amcl_playback_observe(&t, next) == expected[next]); observed = next;
        }
    }
    assert(amcl_playback_observe(&t, position) == users);
}

typedef struct { AmclPlaybackTimeline t; int finished; } Concurrent;
static void *produce(void *opaque)
{
    Concurrent *c = opaque;
    for (unsigned i = 0; i < 125000; ++i) {
        while (!amcl_playback_reserve(&c->t, 5)) sched_yield();
        amcl_playback_commit(&c->t, 8);
    }
    __atomic_store_n(&c->finished, 1, __ATOMIC_RELEASE);
    return NULL;
}
static void concurrent(void)
{
    Concurrent c = {0}; pthread_t thread; uint64_t last = 0;
    assert(!pthread_create(&thread, NULL, produce, &c));
    while (!__atomic_load_n(&c.finished, __ATOMIC_ACQUIRE)) {
        uint64_t frame = __atomic_load_n(&c.t.streamFrames, __ATOMIC_ACQUIRE);
        if (frame > 64) frame -= 64; else frame = 0;
        uint64_t expected = frame / 8 * 5 + (frame % 8 < 5 ? frame % 8 : 5);
        uint64_t actual = amcl_playback_observe(&c.t, frame);
        assert(actual >= last && actual <= expected); last = actual;
    }
    assert(!pthread_join(thread, NULL));
    assert(amcl_playback_observe(&c.t, 1000000) == 625000);
}

int main(void)
{
    gaps(); full(); oracle(); concurrent();
    puts("PASS user/system frames: sparse gaps, later-user not early, bounded backpressure, million-frame contiguous merge, reset and concurrent snapshots");
}
