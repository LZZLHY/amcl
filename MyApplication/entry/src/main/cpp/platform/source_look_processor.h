#ifndef AMCL_SOURCE_LOOK_PROCESSOR_H
#define AMCL_SOURCE_LOOK_PROCESSOR_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 输入端视角加工 ABI。source 使用 AmclInputSource 数值；monotonicNs<=0 时拒绝。
 * 成功时返回明确旧兼容调用的加工量，失败输出归零且数学状态不变。薄适配只转唯一
 * neutral look owner，不建第二份mutex/clock/pending；不调用bridge/core/ABI。
 * 现役typed physical在Core接受事务一次加工，consumer使用memo，不能再调用本接口复算。
 *
 * 状态和配置按 source 隔离；归一系数沿用既有值，物理鼠标始终不平滑。触控/手柄的
 * 未输出尾量由其生产者在正常UP/idle调用 flush，失焦/模式边界调用 reset 丢弃。
 */
bool amcl_process_source_look_delta(int32_t source, double dx, double dy,
    int64_t monotonicNs, double* outDx, double* outDy);
/** 陀螺仪已按时间积分；复用触控的灵敏度/倒置，但独立时钟且不叠加手指加速和平滑。 */
bool amcl_process_touch_gyro_delta(double dx, double dy, int64_t monotonicNs, double* outDx, double* outDy);
bool amcl_flush_source_look_delta(int32_t source, bool emit,
    double* outDx, double* outDy);
void amcl_reset_source_look_state(void);
/** 后端独立RESET仅清其对应source，不能连带丢掉另一平面仍有效的触控/手柄尾量。 */
void amcl_reset_source_look_delta(int32_t source);

/** source=-1 更新所有端的兼容配置；单端更新预留给按端输入配置发布，均幂等且原子。 */
bool amcl_set_source_look_sensitivity(int32_t source, double value);
bool amcl_set_source_look_invert_y(int32_t source, bool value);
bool amcl_set_source_look_smoothing(int32_t source, double value);
bool amcl_set_source_look_acceleration(int32_t source, double value);
/** 原子配置：先校验全部字段，再在同一把processor锁内应用；拒绝时任何字段都不变。
 * 已加工pending保持原输出单位，不按新参数重新缩放。source=-1应用全部真实来源。 */
bool amcl_apply_source_look_configuration(int32_t source, double sensitivity,
    bool invertY, double smoothing, double acceleration);

#ifdef __cplusplus
}
#include "look_pipeline_stats.h"
namespace amcl::input {
/** 只读聚合快照；内部自行同步，不能在外部持有 processor 锁。 */
LookPipelineSnapshot SourceLookPipelineSnapshot();
}
#endif
#endif
