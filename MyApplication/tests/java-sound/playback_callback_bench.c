/* 同进程匹配旧0-return参考与生产callback稳态成本。只测完整用户PCM持续供数，
 * 不调用OHAudio、不触碰设备；CPU时间和墙钟分开，不能外推为目标实时性能通过。 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "ohos_daudio_callbacks.h"
#include "daudio_zero_return_reference.h"

typedef int32_t (*Callback)(OH_AudioRenderer *, void *, void *, int32_t);
static unsigned long long checksum;

static uint64_t clock_ns(clockid_t clock)
{
    struct timespec value;
    if (clock_gettime(clock, &value)) abort();
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

/* 两个版本经过相同强类型间接调用、队列写入和数据校验；禁止编译器按调用点特化。 */
__attribute__((noinline)) static double measure(Callback callback, int bytes, double *wall)
{
    AmclLine line = {0};
    AmclCallback context = {0};
    AmclPlaybackTimeline timeline = {0};
    unsigned char *data;
    uint64_t rounds, startWall, start, finish;
    line.playback = &timeline; line.frameSize = 4; line.capacity = bytes * 4;
    line.copyEnabled = 1; line.isSource = 1;
    line.ring = malloc((size_t)line.capacity); data = malloc((size_t)bytes);
    if (!line.ring || !data) abort();
    memset(line.ring, 53, (size_t)line.capacity); context.owner = &line;
    rounds = UINT64_C(67108864) / (unsigned)bytes;
    startWall = clock_ns(CLOCK_MONOTONIC); start = clock_ns(CLOCK_PROCESS_CPUTIME_ID);
    for (uint64_t index = 0; index < rounds; ++index) {
        __atomic_store_n(&line.written, (index + 1) * (unsigned)bytes, __ATOMIC_RELEASE);
        if (callback(NULL, &context, data, bytes) != bytes) abort();
        checksum += data[0] + data[bytes - 1];
    }
    finish = clock_ns(CLOCK_PROCESS_CPUTIME_ID);
    *wall = (double)(clock_ns(CLOCK_MONOTONIC) - startWall) / (double)rounds;
    if (line.read != rounds * (unsigned)bytes || context.active) abort();
    free(line.ring); free(data);
    return (double)(finish - start) / (double)rounds;
}

static double median(double *values)
{
    for (unsigned i = 0; i < 5; ++i) for (unsigned j = i + 1; j < 5; ++j)
        if (values[j] < values[i]) { double before = values[i]; values[i] = values[j]; values[j] = before; }
    return values[2];
}

int main(void)
{
    const int sizes[] = {32, 960, 16384};
    for (unsigned size = 0; size < sizeof(sizes) / sizeof(sizes[0]); ++size) {
        double old[5], current[5], oldWall[5], newWall[5];
        for (unsigned sample = 0; sample < 5; ++sample) {
            /* 交错执行次序，减小升频/缓存/后台负载对固定先后版本造成的偏差。 */
            if (sample % 2) {
                current[sample] = measure(render_data, sizes[size], &newWall[sample]);
                old[sample] = measure(amcl_timing_zero_return_reference, sizes[size], &oldWall[sample]);
            } else {
                old[sample] = measure(amcl_timing_zero_return_reference, sizes[size], &oldWall[sample]);
                current[sample] = measure(render_data, sizes[size], &newWall[sample]);
            }
        }
        const double before = median(old), after = median(current);
        printf("bytes=%d oldCpuNs=%.2f newCpuNs=%.2f addedCpuNs=%.2f oldWallNs=%.2f newWallNs=%.2f timelineBytes=%zu checksum=%llu\n",
               sizes[size], before, after, after - before, median(oldWall), median(newWall), sizeof(AmclPlaybackTimeline), checksum);
        fflush(stdout);
    }
    return 0;
}
