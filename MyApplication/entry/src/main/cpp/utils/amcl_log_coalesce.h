#pragma once
/**
 * amcl_log_coalesce.h — 连续重复行合并的**纯策略**（日志系统重构 · P2）
 *
 * 解决的问题：一个调用点可以把共享保留预算整个吃掉。真机实测（施工记录 §S03.1）
 * 一句**逐字相同**的 INFO 心跳占了 amcl_launcher.log 的 72.9% 字节，把 12 MiB 预算的
 * 有效保留时长从 511 h 压到 143.9 h。同型事故这是第三次
 * （`[GLFW-DIAG] poll#` → `[MG-FRAME-*]` → 本次），前两次都是在下游再加一条字符串匹配。
 *
 * ⭐ 判据只用「连续 + 逐字相同」，**刻意不做数字归一化**。
 *   真机实测（施工记录 §S04.2）：心跳 7,491 次只有 21 种原文 ⇒ 逐字合并已压掉 99.7%；
 *   而 `display-change` 93 次有 36 种原文 ⇒ 归一化会把 36 个真实事件压成 1 条。
 *   逐字相同的行按定义不携带新信息，合并它是**无损**的；归一化是有损的。
 *
 * ⭐ 为什么是纯策略、不碰 IO：这样它能在宿主上直接跑用例
 *   （`tests/host/log_coalesce_test.cpp`），而 `amcl_log.cpp` 里的并发与文件 IO 不可测。
 *   与 `product_diagnostics.h` 同一形状。
 *
 * 时序约定：**先写首行，再抑制重复，变化时补一行计数。**
 *   ⇒ 进程随时被杀最多丢一个计数，绝不丢内容。
 */

#include <string.h>
#include <stdio.h>

#ifndef AMCL_COALESCE_TAG_MAX
#define AMCL_COALESCE_TAG_MAX 64
#endif
#ifndef AMCL_COALESCE_MSG_MAX
#define AMCL_COALESCE_MSG_MAX 4096
#endif

/** 攒够这么多条就先把计数落一次，避免长期不落地。 */
#define AMCL_COALESCE_MAX_RUN 4096u
/** 或者攒够这么久（秒）。读日志的人要能在合理时间内看到「它重复了多少次」。 */
#define AMCL_COALESCE_MAX_SECONDS 300

typedef struct {
    int active;                             /* 是否正攒着一段游程 */
    int level;                              /* 被合并行的级别 */
    long long activityId;                   /* 被合并行的活动归属 */
    char tag[AMCL_COALESCE_TAG_MAX];
    char message[AMCL_COALESCE_MSG_MAX];
    unsigned long repeats;                  /* 已抑制的条数，**不含首行** */
    long long firstTs;                      /* 本段计数的起点（秒） */
    long long lastTs;                       /* 最近一次重复的时间（秒） */
} AmclCoalesceState;

/** 清空状态。init / shutdown / fork 之后必须调，否则会拿上个生命周期的最后一行做比较。 */
static inline void amclCoalesceReset(AmclCoalesceState* st) {
    if (!st) return;
    st->active = 0;
    st->repeats = 0;
    st->level = 0;
    st->activityId = 0;
    st->tag[0] = '\0';
    st->message[0] = '\0';
    st->firstTs = 0;
    st->lastTs = 0;
}

/** 这条日志与正攒着的游程是否逐字相同（时间戳不参与比较）。 */
static inline int amclCoalesceMatches(const AmclCoalesceState* st, int level,
                                      long long activityId, const char* tag,
                                      const char* message) {
    if (!st || !st->active) return 0;
    if (st->level != level || st->activityId != activityId) return 0;
    if (strncmp(st->tag, tag ? tag : "", AMCL_COALESCE_TAG_MAX) != 0) return 0;
    if (strncmp(st->message, message ? message : "", AMCL_COALESCE_MSG_MAX) != 0) return 0;
    return 1;
}

/**
 * 记一次重复。
 * @return 1 = 已达上限，调用方应当**立即**把计数落盘（游程继续）；0 = 继续攒。
 */
static inline int amclCoalesceNoteRepeat(AmclCoalesceState* st, long long ts) {
    if (!st || !st->active) return 0;
    st->repeats++;
    st->lastTs = ts;
    if (st->repeats >= AMCL_COALESCE_MAX_RUN) return 1;
    if ((ts - st->firstTs) >= AMCL_COALESCE_MAX_SECONDS) return 1;
    return 0;
}

/** 开始新一段游程（调用方已把首行写出去了）。 */
static inline void amclCoalesceBegin(AmclCoalesceState* st, int level, long long activityId,
                                     const char* tag, const char* message, long long ts) {
    if (!st) return;
    st->active = 1;
    st->level = level;
    st->activityId = activityId;
    strncpy(st->tag, tag ? tag : "", AMCL_COALESCE_TAG_MAX - 1);
    st->tag[AMCL_COALESCE_TAG_MAX - 1] = '\0';
    strncpy(st->message, message ? message : "", AMCL_COALESCE_MSG_MAX - 1);
    st->message[AMCL_COALESCE_MSG_MAX - 1] = '\0';
    st->repeats = 0;
    st->firstTs = ts;
    st->lastTs = ts;
}

/** 有没有攒着尚未落盘的计数。 */
static inline int amclCoalescePending(const AmclCoalesceState* st) {
    return st && st->active && st->repeats > 0;
}

/**
 * 生成计数行的**正文**（不含时间戳 / 级别 / tag 前缀 —— 那些由 writer 拼）。
 * @return 写入的字符数；无待落计数时返回 0。
 */
static inline int amclCoalesceFormatBody(const AmclCoalesceState* st, char* out, int cap) {
    if (!amclCoalescePending(st) || !out || cap <= 0) return 0;
    long long span = st->lastTs - st->firstTs;
    if (span < 0) span = 0;
    int n = snprintf(out, (size_t)cap,
                     "previous line from [%s] repeated %lu more times over %lld s",
                     st->tag, st->repeats, span);
    if (n < 0) return 0;
    if (n > cap - 1) n = cap - 1;
    return n;
}

/**
 * 计数已落盘：清零重复数。
 * @param keepRun 非 0 = 因攒满上限而落地，游程继续（后续相同行继续被抑制）；
 *                0    = 因为来了不同的行 / 轮转 / 关停而收尾。
 */
static inline void amclCoalesceAfterFlush(AmclCoalesceState* st, int keepRun) {
    if (!st) return;
    st->repeats = 0;
    st->firstTs = st->lastTs;
    if (!keepRun) st->active = 0;
}
