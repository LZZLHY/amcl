/* 固定短录音诊断的私有宿主接口。仅TestHooks编译，不属于JDK共享POD/回调ABI。
 * Begin/Finish由同一资格控制线程调用；Finish只能在Java已关闭两条输入流后读取。
 * 此接口不申请权限、不创建流、不保留PCM，仅累计两段首200ms的帧数/峰值/RMS原料。 */
#ifndef AMCL_OHOS_CAPTURE_DIAGNOSTICS_H
#define AMCL_OHOS_CAPTURE_DIAGNOSTICS_H
#ifdef MC_OHOS_BUILD_TESTS
#include "ohos_daudio_callbacks.h"
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t expectedRate, targetFrames, frameSize, capacityBytes;
    uint32_t flags, peak;
    int32_t lineError;
    uint64_t callbacks, acceptedBytes, measuredFrames, sumSquares;
} AmclCaptureDiagnosticPass;

typedef struct {
    uint32_t version, selectedTables, quiescent;
    AmclCaptureDiagnosticPass passes[2];
} AmclCaptureDiagnosticReport;

/* 一进程最多arm一次，失败返回0；没有流/数据/SDK调用。 */
int amcl_capture_diagnostics_begin(void);
/* 未arm返回原表；显式arm的前两次open分别绑定固定pass，额外open返回NULL使其失败。 */
const AmclDAudioCallbackAbiV2 *amcl_capture_diagnostics_callbacks(const AmclDAudioCallbackAbiV2 *normal);
/* 返回1表示统计已静止并复制，0表示缺Begin/并发Finish/在途回调，绝不读取竞态统计。 */
int amcl_capture_diagnostics_finish(AmclCaptureDiagnosticReport *report);

#ifdef __cplusplus
}
#endif
#endif
#endif
