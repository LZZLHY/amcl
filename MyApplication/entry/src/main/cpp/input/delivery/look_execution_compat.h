/** 旧加工 ABI 的内部接缝。状态只在 look_execution.cpp，适配器不建第二套时钟或余量。 */
#ifndef AMCL_LOOK_EXECUTION_COMPAT_H
#define AMCL_LOOK_EXECUTION_COMPAT_H
#include "look_execution.h"
#include "../../platform/look_pipeline_stats.h"
#ifdef __cplusplus
extern "C" {
#endif
/** 兼容调用返回已加工量；生产运输在队列容量预留后调用，失败保持数学状态。 */
AMCL_CONTROL_PUBLIC bool amclLookCompatProcess(int32_t source,double dx,double dy,int64_t ns,
    double* outX,double* outY,bool gyro);
/** emit=false 丢弃指定来源；触控取消包含 gyro，普通 UP 不重置 gyro 的独立时钟。 */
AMCL_CONTROL_PUBLIC bool amclLookCompatFlush(int32_t source,bool emit,double* outX,double* outY);
AMCL_CONTROL_PUBLIC void amclLookCompatReset(void);
/** 单字段旧 setter 仍在 owner 锁内读取其余字段后整体应用，避免 read/modify/write 丢更新。 */
AMCL_CONTROL_PUBLIC bool amclLookCompatSet(int32_t source,uint32_t field,double value);
AMCL_CONTROL_PUBLIC void amclLookCompatSnapshot(amcl::input::LookPipelineSnapshot* output);
/**
 * producer已持surface/模式资格并预留真实运输容量后调用的无外调提交口。
 * stream=0只推进已知速度；其余delta与封存使用同一候选提交，Pressure/Rejected不改时钟。
 * order由真实运输批次预留，ownerNs只用Native单调域；sampleNs仅校验该流采样顺序。
 */
AMCL_CONTROL_PUBLIC int32_t amclLookExecutionCommitV1(uint64_t stream,double dx,double dy,uint64_t sampleNs,
    uint64_t gameSession,uint64_t order,uint64_t ownerNs,uint32_t flush,AmclLookPrefixV1* output);
#ifdef __cplusplus
}
#endif
#endif
