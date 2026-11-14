/*
 * AMCL 的 PCM Capture 覆盖环，遵守 TargetDataLine 溢出丢最旧、保留最新的规则。
 * 一个系统回调生产者、一个由 Java lockNative 串行化的消费者；Flush/Destroy 由外层
 * callback gate 保证静止。回调不锁、不等待、不分配，消费者不会读到被覆盖的半个样本。
 * 此文件不依赖 JNI/OHAudio，实际平台后端与宿主并发测试共用同一份实现。
 */
#ifndef AMCL_OHOS_CAPTURE_RING_H
#define AMCL_OHOS_CAPTURE_RING_H

#include <stdint.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

/* 产品是 AArch64；64 位原子必须由机器指令完成，不能在音频回调中退化为库内锁。 */
#if !defined(__GCC_ATOMIC_LLONG_LOCK_FREE) || __GCC_ATOMIC_LLONG_LOCK_FREE != 2
#error "AMCL Capture requires always lock-free 64-bit atomics"
#endif

typedef struct {
    uint64_t *words;
    unsigned char *scratch;
    uint64_t reserved;       /* 在任何 PCM 写入之前发布本回调将推进到的绝对字节位置。 */
    uint64_t published;      /* 完整 PCM 写完后发布；只计真实完整帧，不靠时钟补进度。 */
    uint64_t consumed;       /* 只有消费者使用；落后时从仍然有效的最旧完整帧续读。 */
    uint64_t overwritten;    /* 消费侧实际跳过的过期字节数，不把允许的溢出当永久错误。 */
    int capacity;            /* 对 Java 报告的逻辑容量，始终为完整帧数。 */
    int storage;             /* 多留一个回调大小的物理空间，保护常见并行读/写的旧快照。 */
    int quantum;             /* 暂存块大小；一次 native Read 可累积多个块，不人工等待。 */
    int frame;
    int writing;             /* 同一 capturer 不允许并发数据回调；意外违反时显式拒绝。 */
} AmclCaptureRing;

/* 初始化可失败但不留下半构造对象；实际容量按 lcm(frame,8) 向上取整以支持 24-bit
 * 等非二次幂帧，又让原子字块自然对齐。额外空间不改变逻辑保留最新 capacity 的语义。 */
static inline int amcl_capture_init(AmclCaptureRing *ring, int requested, int frame, int callbackBytes)
{
    int divisor, remainder, alignment;
    uint64_t logical, physical;
    if (!ring || requested < frame || frame <= 0 || callbackBytes < frame || callbackBytes % frame) return 0;
    divisor = frame; remainder = 8;
    while (remainder) { int next = divisor % remainder; divisor = remainder; remainder = next; }
    alignment = frame / divisor;
    if (alignment > INT_MAX / 8) return 0;
    alignment *= 8;
    logical = ((uint64_t)requested + (unsigned)alignment - 1) / (unsigned)alignment * (unsigned)alignment;
    physical = (logical + (unsigned)callbackBytes + (unsigned)alignment - 1) / (unsigned)alignment * (unsigned)alignment;
    if (logical > INT_MAX || physical > INT_MAX) return 0;
    memset(ring, 0, sizeof(*ring));
    ring->capacity = (int)logical; ring->storage = (int)physical; ring->frame = frame;
    ring->quantum = callbackBytes < ring->capacity ? callbackBytes : ring->capacity;
    ring->words = (uint64_t *)calloc((size_t)ring->storage / 8, sizeof(uint64_t));
    ring->scratch = (unsigned char *)malloc((size_t)ring->quantum);
    if (!ring->words || !ring->scratch) {
        free(ring->words); free(ring->scratch); memset(ring, 0, sizeof(*ring)); return 0;
    }
    return 1;
}

/* 只在外层已经撤销 callback owner 并等在途访问归零后调用，不能用此函数代替 gate。 */
static inline void amcl_capture_destroy(AmclCaptureRing *ring)
{
    free(ring->words); free(ring->scratch); memset(ring, 0, sizeof(*ring));
}

/* 原子字块允许读/写重叠后安全检测并丢弃暂存结果；只靠 seqlock+普通 memcpy 会产生
 * C 数据竞争，事后检测到重叠也不能撤销 UB。这里只在头尾做读改写，整字块直接发布。 */
static inline void amcl_capture_store(AmclCaptureRing *ring, uint64_t position,
                                      const unsigned char *data, int count)
{
    while (count) {
        const int offset = (int)(position % (uint64_t)ring->storage);
        const int inside = offset % 8;
        int part = 8 - inside;
        uint64_t value;
        if (part > count) part = count;
        value = part == 8 ? 0 : __atomic_load_n(&ring->words[offset / 8], __ATOMIC_RELAXED);
        memcpy((unsigned char *)&value + inside, data, (size_t)part);
        __atomic_store_n(&ring->words[offset / 8], value, __ATOMIC_RELAXED);
        position += (unsigned)part; data += part; count -= part;
    }
}

/* 返回1表示已接收完整帧（包括按容量规则覆盖旧帧）；返回0表示无数据，-1表示调用
 * 合同损坏。回调大小超过声明 quantum 时也保留最近数据，不写越界或静默拆半帧。 */
static inline int amcl_capture_push(AmclCaptureRing *ring, const void *data, int count)
{
    uint64_t previous, end;
    int expected = 0, kept;
    if (!ring || !ring->words || count < 0 || (count && !data) || count % ring->frame) return -1;
    if (!count) return 0;
    if (!__atomic_compare_exchange_n(&ring->writing, &expected, 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) return -1;
    previous = __atomic_load_n(&ring->published, __ATOMIC_RELAXED);
    if (UINT64_MAX - previous < (uint64_t)count) {
        __atomic_store_n(&ring->writing, 0, __ATOMIC_RELEASE); return -1;
    }
    end = previous + (unsigned)count;
    __atomic_store_n(&ring->reserved, end, __ATOMIC_RELAXED);
    /* 与消费者读取过任何新原子字后的 acquire fence 配对：其最终 reserved 观察必须
     * 包含这次覆盖范围，不能拿旧范围批准混合数据。completed 发布另用 release。 */
    __atomic_thread_fence(__ATOMIC_RELEASE);
    kept = count < ring->storage ? count : ring->storage;
    amcl_capture_store(ring, end - (unsigned)kept, (const unsigned char *)data + count - kept, kept);
    __atomic_store_n(&ring->published, end, __ATOMIC_RELEASE);
    __atomic_store_n(&ring->writing, 0, __ATOMIC_RELEASE);
    return 1;
}

/* 逻辑溢出和正在进行的物理覆盖分别约束最旧有效位置；常见一回调额外空间使 append
 * 不会无端阻塞 reader。所有位置都是 frame 的整数倍，因此截取不会破坏样本边界。 */
static inline uint64_t amcl_capture_begin(AmclCaptureRing *ring, uint64_t published, uint64_t reserved)
{
    uint64_t begin = ring->consumed;
    const uint64_t logical = published > (uint64_t)ring->capacity ? published - (unsigned)ring->capacity : 0;
    const uint64_t physical = reserved > (uint64_t)ring->storage ? reserved - (unsigned)ring->storage : 0;
    if (begin < logical) begin = logical;
    if (begin < physical) begin = physical;
    return begin;
}

static inline int amcl_capture_available(AmclCaptureRing *ring)
{
    const uint64_t end = __atomic_load_n(&ring->published, __ATOMIC_ACQUIRE);
    const uint64_t begin = amcl_capture_begin(ring, end, __atomic_load_n(&ring->reserved, __ATOMIC_ACQUIRE));
    return begin < end ? (int)(end - begin) : 0;
}

/* 只读原子字到私有预分配区；未通过覆盖范围复核的数据绝不提交到调用者数组。 */
static inline void amcl_capture_snapshot(AmclCaptureRing *ring, uint64_t position, int count)
{
    unsigned char *output = ring->scratch;
    while (count) {
        const int offset = (int)(position % (uint64_t)ring->storage);
        const int inside = offset % 8;
        const uint64_t value = __atomic_load_n(&ring->words[offset / 8], __ATOMIC_RELAXED);
#ifdef AMCL_CAPTURE_TEST_AFTER_WORD
        /* 仅测试编译注入精确覆盖交错；产品未定义此宏时没有调用或分支。 */
        AMCL_CAPTURE_TEST_AFTER_WORD(ring);
#endif
        int part = 8 - inside;
        if (part > count) part = count;
        memcpy(output, (const unsigned char *)&value + inside, (size_t)part);
        position += (unsigned)part; output += part; count -= part;
    }
}

/* 非阻塞 native Read。最多读取入口时已经有的字节，按 quantum 验证后累积提交，
 * 不因内部的小暂存块迫使原 Java read 循环每块都 sleep。真正等输入仍由原 Java 承担。
 * 每块最多重试3次，恶劣抢占/持续覆盖时返回已经完成的部分；没有 callback 内等待。 */
static inline int amcl_capture_read(AmclCaptureRing *ring, void *output, int count)
{
    int total = 0, limit;
    if (!ring || !ring->words || count < 0 || (count && !output) || count % ring->frame) return -1;
    limit = amcl_capture_available(ring);
    if (limit > count) limit = count;
    while (total < limit) {
        int attempt, accepted = 0;
        for (attempt = 0; attempt < 3; ++attempt) {
            const uint64_t end = __atomic_load_n(&ring->published, __ATOMIC_ACQUIRE);
            const uint64_t begin = amcl_capture_begin(ring, end, __atomic_load_n(&ring->reserved, __ATOMIC_ACQUIRE));
            uint64_t reserved, oldest;
            int part = limit - total;
            if (begin >= end) return total;
            if ((uint64_t)part > end - begin) part = (int)(end - begin);
            if (part > ring->quantum) part = ring->quantum;
            amcl_capture_snapshot(ring, begin, part);
            __atomic_thread_fence(__ATOMIC_ACQUIRE);
            reserved = __atomic_load_n(&ring->reserved, __ATOMIC_RELAXED);
            oldest = reserved > (uint64_t)ring->storage ? reserved - (unsigned)ring->storage : 0;
            if (begin < oldest) continue;
            /* linearization 在快照复核处；若之后才覆盖，私有 scratch 仍保持本次数据。 */
            memcpy((unsigned char *)output + total, ring->scratch, (size_t)part);
            if (begin > ring->consumed) ring->overwritten += begin - ring->consumed;
            ring->consumed = begin + (unsigned)part;
            total += part; accepted = 1; break;
        }
        if (!accepted) break;
    }
    return total;
}

/* 外层静止窗口内丢弃已有输入；累计真实捕获位置保留，不能用 flush 伪造新输入。 */
static inline void amcl_capture_flush(AmclCaptureRing *ring)
{ ring->consumed = __atomic_load_n(&ring->published, __ATOMIC_ACQUIRE); }

static inline uint64_t amcl_capture_position(AmclCaptureRing *ring)
{ return __atomic_load_n(&ring->published, __ATOMIC_ACQUIRE); }

#endif
