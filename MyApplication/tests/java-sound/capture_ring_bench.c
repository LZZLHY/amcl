/* 覆盖环的宿主成本测量：真实生产push/read，固定格式/回调粒度，不宣称目标音频时延。
 * 报告生产者/消费者合计成本、回调周期占比和实际存储，不把宿主速度外推为设备通过。 */
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdio.h>
#include <time.h>
#include "ohos_capture_ring.h"

static uint64_t now_ns(void)
{
    struct timespec value;
    assert(!clock_gettime(CLOCK_MONOTONIC, &value));
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (unsigned long)value.tv_nsec;
}

static void bench(int rate, int channels, int bits, int frames)
{
    AmclCaptureRing ring = {0};
    int frame = channels * bits / 8, bytes = frames * frame;
    unsigned char *input = malloc((size_t)bytes), *output = malloc((size_t)bytes);
    uint64_t rounds = UINT64_C(268435456) / (unsigned)bytes, elapsed[5], checksum = 0;
    assert(input && output && amcl_capture_init(&ring, 4 * bytes, frame, bytes));
    for (int i = 0; i < bytes; ++i) input[i] = (unsigned char)i;
    for (unsigned sample = 0; sample < 5; ++sample) {
        uint64_t begin = now_ns();
        for (uint64_t n = 0; n < rounds; ++n) {
            input[0] = (unsigned char)n;
            assert(amcl_capture_push(&ring, input, bytes) == 1);
            assert(amcl_capture_read(&ring, output, bytes) == bytes);
            checksum += output[0] + output[bytes - 1];
        }
        elapsed[sample] = now_ns() - begin;
    }
    for (unsigned i = 0; i < 5; ++i) for (unsigned j = i + 1; j < 5; ++j)
        if (elapsed[j] < elapsed[i]) { uint64_t value = elapsed[i]; elapsed[i] = elapsed[j]; elapsed[j] = value; }
    double nanos = (double)elapsed[2] / (double)rounds;
    printf("rate=%d channels=%d bits=%d callbackFrames=%d bytes=%d medianPushReadNs=%.1f "
           "pcmMiBPerSecond=%.2f callbackPeriodShare=%.6f allocatedBytes=%d checksum=%llu\n",
           rate, channels, bits, frames, bytes, nanos, (double)bytes * 1e9 / nanos / 1048576.0,
           nanos / ((double)frames / rate * 1e9), ring.storage + ring.quantum, (unsigned long long)checksum);
    assert(!memcmp(input, output, (size_t)bytes));
    amcl_capture_destroy(&ring); free(input); free(output);
}

int main(void)
{
    bench(48000, 2, 16, 240);
    bench(96000, 8, 32, 480);
    bench(192000, 32, 32, 480);
    return 0;
}
