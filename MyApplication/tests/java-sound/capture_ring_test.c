/* 共享覆盖环的真实 C 测试；序号样本证明不重复/倒序/半帧，精确交错证明检测到
 * 被覆盖快照后不提交错误字节。权限、设备和完整JNI另外验收，本文件不触麦克风。 */
#define _GNU_SOURCE
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static void after_word(void *ring);
#define AMCL_CAPTURE_TEST_AFTER_WORD(ring) after_word((void *)(ring))
#include "ohos_capture_ring.h"

static int overwrite_once;
static unsigned char replacement[8192];
static int replacement_size;

/* 在消费者已读到一个旧字、尚未复核时完成整个覆盖，原子数据访问仍遵守实际C模型。 */
static void after_word(void *opaque)
{
    if (overwrite_once) {
        overwrite_once = 0;
        assert(amcl_capture_push((AmclCaptureRing *)opaque, replacement, replacement_size) == 1);
    }
}

static void patterns(void)
{
    static const int frames[] = {1, 2, 3, 4, 6, 8, 12, 16, 24, 128};
    unsigned char input[32768], output[32768];
    unsigned f;
    for (f = 0; f < sizeof(frames) / sizeof(frames[0]); ++f) {
        AmclCaptureRing ring = {0};
        const int frame = frames[f];
        int i, total = 0, n;
        assert(amcl_capture_init(&ring, 17 * frame, frame, 5 * frame));
        assert(ring.capacity >= 17 * frame && ring.capacity % frame == 0 && ring.storage % 8 == 0);
        assert(amcl_capture_available(&ring) == 0 && amcl_capture_read(&ring, output, frame) == 0);
        for (i = 0; i < (int)sizeof(input); ++i) input[i] = (unsigned char)(i % 251);
        assert(amcl_capture_push(&ring, input, 7 * frame) == 1); total += 7 * frame;
        assert(amcl_capture_available(&ring) == 7 * frame);
        memset(output, 0xAA, sizeof(output));
        n = amcl_capture_read(&ring, output, 7 * frame);
        assert(n == 7 * frame && !memcmp(output, input, (size_t)n) && output[n] == 0xAA);
        /* 连续多次回绕且故意不读；最后一次 oversized callback 也保留最近capacity。 */
        for (i = 0; i < 40; ++i) {
            int count = i == 39 ? ring.storage * 3 : 9 * frame;
            int j;
            assert(count < (int)sizeof(input));
            for (j = 0; j < count; ++j) input[j] = (unsigned char)((total + j) % 251);
            assert(amcl_capture_push(&ring, input, count) == 1); total += count;
        }
        assert(amcl_capture_position(&ring) == (uint64_t)total);
        assert(amcl_capture_available(&ring) == ring.capacity);
        memset(output, 0xAA, sizeof(output));
        n = amcl_capture_read(&ring, output, ring.capacity);
        assert(n == ring.capacity && output[n] == 0xAA);
        for (i = 0; i < n; ++i) assert(output[i] == (unsigned char)((total - ring.capacity + i) % 251));
        assert(ring.overwritten > 0 && amcl_capture_available(&ring) == 0);
        assert(amcl_capture_push(&ring, input, frame) == 1);
        amcl_capture_flush(&ring);
        assert(amcl_capture_available(&ring) == 0 && amcl_capture_position(&ring) == (uint64_t)(total + frame));
        if (frame > 1) {
            assert(amcl_capture_push(&ring, input, frame - 1) == -1);
            assert(amcl_capture_read(&ring, output, frame - 1) == -1);
        }
        assert(amcl_capture_push(&ring, NULL, frame) == -1 && amcl_capture_read(&ring, NULL, frame) == -1);
        amcl_capture_destroy(&ring);
    }
}

static void exact_overlap(void)
{
    AmclCaptureRing ring = {0};
    unsigned char original[128], output[256];
    int n;
    memset(original, 0x11, sizeof(original)); memset(replacement, 0x77, sizeof(replacement));
    assert(amcl_capture_init(&ring, 128, 4, 32));
    assert(amcl_capture_push(&ring, original, sizeof(original)) == 1);
    replacement_size = ring.storage * 3; overwrite_once = 1;
    memset(output, 0xAA, sizeof(output));
    n = amcl_capture_read(&ring, output, 128);
    assert(!overwrite_once && n == 128);
    for (int i = 0; i < n; ++i) assert(output[i] == 0x77);
    assert(output[n] == 0xAA && ring.overwritten >= 128);
    amcl_capture_destroy(&ring);
}

typedef struct {
    AmclCaptureRing ring;
    int finished;
    uint64_t read_frames, last;
} Concurrent;

/* 同一 frame 的序号及反码必须同时成立；队列溢出允许跳号，但绝不接受倒序或混合字。 */
static void *produce(void *opaque)
{
    Concurrent *state = opaque;
    uint64_t samples[62];
    for (uint64_t begin = 1; begin <= 1000000; begin += 31) {
        int count = 1000001 - begin < 31 ? (int)(1000001 - begin) : 31;
        for (int i = 0; i < count; ++i) { samples[i * 2] = begin + (unsigned)i; samples[i * 2 + 1] = ~samples[i * 2]; }
        assert(amcl_capture_push(&state->ring, samples, count * 16) == 1);
    }
    __atomic_store_n(&state->finished, 1, __ATOMIC_RELEASE);
    return NULL;
}

static void concurrent(void)
{
    Concurrent state = {0};
    uint64_t output[126];
    pthread_t thread;
    assert(amcl_capture_init(&state.ring, 4096, 16, 31 * 16));
    assert(!pthread_create(&thread, NULL, produce, &state));
    while (!__atomic_load_n(&state.finished, __ATOMIC_ACQUIRE) || amcl_capture_available(&state.ring)) {
        int n = amcl_capture_read(&state.ring, output, sizeof(output));
        assert(n >= 0 && n % 16 == 0);
        for (int i = 0; i < n / 16; ++i) {
            assert(output[2 * i] > state.last && output[2 * i + 1] == ~output[2 * i]);
            state.last = output[2 * i]; ++state.read_frames;
        }
    }
    assert(!pthread_join(thread, NULL));
    assert(state.last == 1000000 && state.read_frames > 0 && amcl_capture_position(&state.ring) == 16000000);
    printf("PASS capture 1000000 produced frames: returned=%llu overwritten=%llu latest=%llu\n",
           (unsigned long long)state.read_frames, (unsigned long long)(state.ring.overwritten / 16),
           (unsigned long long)state.last);
    amcl_capture_destroy(&state.ring);
}

int main(void)
{
    patterns(); exact_overlap(); concurrent();
    puts("PASS capture full-frame formats, oldest-drop, wrap/oversize, flush, exact overwritten snapshot, untouched output tail");
    return 0;
}
