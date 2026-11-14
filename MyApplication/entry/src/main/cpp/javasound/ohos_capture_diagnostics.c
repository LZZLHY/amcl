/* 仅固定TestHooks诊断使用的正常HAP typed入口。仍调用同映像同源capture_data，
 * 不转调自加载代码，不调整CFI，不修改PCM。未arm的getter返回原表，生产热路径零变化。
 * 单轮最多计算3200+9600个样本；统计之外所有后续callback仍原样交给实际PCM环。 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "ohos_capture_diagnostics.h"
#ifdef MC_OHOS_BUILD_TESTS
#include <string.h>

enum { BAD_FRAME = 1, BAD_LENGTH = 2, BAD_ORDER = 4, CONCURRENT = 8, OWNER_CHANGED = 16 };
typedef struct {
    AmclCaptureDiagnosticPass result;
    AmclCallback *context; /* 仅比较身份，不在callback寿命之外解引用。 */
    int busy;
} Pass;
static Pass passes[2];
static AmclDAudioCallbackAbiV2 tables[2];
static unsigned used, armed, selected, active, finishing;
#ifdef AMCL_CAPTURE_DIAGNOSTIC_TEST_HOOK
/* 仅宿主回归构建注入固定交错。正常SDK构建不定义，完全没有钩子/额外分支。 */
extern void AMCL_CAPTURE_DIAGNOSTIC_TEST_HOOK(unsigned phase, unsigned index);
#endif

/* 外层ctx.active涵盖统计全过程，避免capture_data返回后close释放line。
 * 全局active/armed均为seq_cst：Finish先撤arm后查active；任何看到旧armed的写者
 * 必已登记active，反过来晚到的callback只执行原capture_data、不再写统计。
 * 单pass busy保护普通统计字段；意外并发只原子置flag并继续原PCM行为，不能制造数据race。
 */
static void observe(unsigned index, OH_AudioCapturer *capturer, void *opaque, void *data, int32_t bytes)
{
    AmclCallback *ctx = (AmclCallback *)opaque;
    AmclLine *line;
    Pass *pass = &passes[index];
    int expected = 0;
    __atomic_add_fetch(&active, 1U, __ATOMIC_SEQ_CST);
#ifdef AMCL_CAPTURE_DIAGNOSTIC_TEST_HOOK
    AMCL_CAPTURE_DIAGNOSTIC_TEST_HOOK(1, index);
#endif
    if (!__atomic_load_n(&armed, __ATOMIC_SEQ_CST)) {
        capture_data(capturer, opaque, data, bytes);
        __atomic_sub_fetch(&active, 1U, __ATOMIC_SEQ_CST);
        return;
    }
    line = enter_callback(ctx);
    if (!__atomic_compare_exchange_n(&pass->busy, &expected, 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
        __atomic_fetch_or(&pass->result.flags, CONCURRENT, __ATOMIC_RELAXED);
        capture_data(capturer, opaque, data, bytes);
    } else {
#ifdef AMCL_CAPTURE_DIAGNOSTIC_TEST_HOOK
        AMCL_CAPTURE_DIAGNOSTIC_TEST_HOOK(2, index);
#endif
        uint64_t before = line ? amcl_capture_position(&line->capture) : 0;
        capture_data(capturer, opaque, data, bytes);
        if (line) {
            AmclCaptureDiagnosticPass *result = &pass->result;
            const uint64_t after = amcl_capture_position(&line->capture);
            ++result->callbacks;
            if (pass->context && pass->context != ctx)
                __atomic_fetch_or(&result->flags, OWNER_CHANGED, __ATOMIC_RELAXED);
            pass->context = ctx;
            if (line->isSource || line->frameSize != 2 || line->capacity <= 0)
                __atomic_fetch_or(&result->flags, BAD_FRAME, __ATOMIC_RELAXED);
            result->frameSize = (uint32_t)line->frameSize;
            result->capacityBytes = (uint32_t)line->capacity;
            result->lineError = __atomic_load_n(&line->error, __ATOMIC_SEQ_CST);
            if (before != result->acceptedBytes || after < before)
                __atomic_fetch_or(&result->flags, BAD_ORDER, __ATOMIC_RELAXED);
            if (after > before) {
                if (!data || bytes <= 0 || bytes % 2 || after - before != (uint64_t)bytes)
                    __atomic_fetch_or(&result->flags, BAD_LENGTH, __ATOMIC_RELAXED);
                if (!__atomic_load_n(&result->flags, __ATOMIC_RELAXED)) {
                    const unsigned char *input = (const unsigned char *)data;
                    uint64_t count = (uint64_t)bytes / 2;
                    const uint64_t remaining = result->targetFrames - result->measuredFrames;
                    if (count > remaining) count = remaining;
                    for (uint64_t i = 0; i < count; ++i) {
                        const int32_t value = (int16_t)((uint32_t)input[i * 2] | ((uint32_t)input[i * 2 + 1] << 8));
                        const uint32_t absolute = (uint32_t)(value < 0 ? -value : value);
                        if (absolute > result->peak) result->peak = absolute;
                        result->sumSquares += (uint64_t)((int64_t)value * value);
                    }
                    result->measuredFrames += count;
                }
            }
            result->acceptedBytes = after;
        }
        __atomic_store_n(&pass->busy, 0, __ATOMIC_RELEASE);
    }
    leave_callback(ctx);
    __atomic_sub_fetch(&active, 1U, __ATOMIC_SEQ_CST);
}

/* 两个固定typed入口避免依赖已释放/被复用的ctx地址来推断pass；算法仅observe一份。
 * 表和入口都在正常HAP映像，JDK既有dladdr/ABI2验证继续原样生效。 */
static void first(OH_AudioCapturer *capturer, void *opaque, void *data, int32_t bytes)
{ observe(0, capturer, opaque, data, bytes); }
static void second(OH_AudioCapturer *capturer, void *opaque, void *data, int32_t bytes)
{ observe(1, capturer, opaque, data, bytes); }

int amcl_capture_diagnostics_begin(void)
{
    unsigned expected = 0;
    if (!__atomic_compare_exchange_n(&used, &expected, 1U, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) return 0;
    memset(passes, 0, sizeof(passes));
    passes[0].result.expectedRate = 16000; passes[0].result.targetFrames = 3200;
    passes[1].result.expectedRate = 48000; passes[1].result.targetFrames = 9600;
    tables[0] = tables[1] = *amcl_daudio_local_callbacks_v2();
    tables[0].captureData = first; tables[1].captureData = second;
    __atomic_store_n(&armed, 1U, __ATOMIC_SEQ_CST);
    return 1;
}

const AmclDAudioCallbackAbiV2 *amcl_capture_diagnostics_callbacks(const AmclDAudioCallbackAbiV2 *normal)
{
    if (!__atomic_load_n(&armed, __ATOMIC_SEQ_CST)) return normal;
    const unsigned index = __atomic_fetch_add(&selected, 1U, __ATOMIC_SEQ_CST);
    return index < 2 ? &tables[index] : NULL;
}

int amcl_capture_diagnostics_finish(AmclCaptureDiagnosticReport *report)
{
    unsigned expected = 0;
    if (!report) return 0;
    memset(report, 0, sizeof(*report)); report->version = 1;
    if (!__atomic_load_n(&used, __ATOMIC_SEQ_CST) ||
        !__atomic_compare_exchange_n(&finishing, &expected, 1U, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) return 0;
    __atomic_store_n(&armed, 0U, __ATOMIC_SEQ_CST);
    report->selectedTables = __atomic_load_n(&selected, __ATOMIC_SEQ_CST);
    if (__atomic_load_n(&active, __ATOMIC_SEQ_CST)) return 0;
    /* acquire/seq_cst观察所有已完成统计。晚到callback看到armed=false，不写任何result。
     * flags虽在callback内使用原子，但此时全部写者已静止，普通结构复制无并发访问。 */
    report->passes[0] = passes[0].result; report->passes[1] = passes[1].result;
    report->quiescent = 1;
    return 1;
}
#endif
