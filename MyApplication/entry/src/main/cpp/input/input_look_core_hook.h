/**
 * Core接受事务与唯一look owner的内部接缝。原公共事件/函数表完全不变；hook只在预线程
 * owner发布时登记，不从consumer加工同一个physical样本。Core批失败不调用commit，
 * owner候选失败则Core整批回滚。hook锁内不外调Core/ABI/窗口，避免锁反转与半次数学接受。
 */
#ifndef AMCL_INPUT_LOOK_CORE_HOOK_H
#define AMCL_INPUT_LOOK_CORE_HOOK_H
#include "amcl_input_api.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct AmclInputLookFactV1 {
    AmclInputEvent event;
    AmclInputSurfaceContextPayload context;
    uint64_t interactionOrder;
    uint32_t backendMask,reserved;
} AmclInputLookFactV1;
/** 实际活surface/context/focus同一次Core锁快照，不能拼两次公共查询或拿capture代替surface。 */
typedef struct AmclInputLookCoreResourceV1 {
    uint32_t size,active;
    uint64_t sessionEpoch,surfaceEpoch,focusEpoch;
    AmclInputSurfaceContextPayload context;
} AmclInputLookCoreResourceV1;
typedef int32_t (*AmclInputLookCommitV1)(const AmclInputLookFactV1* facts,uint32_t count);
/** 同PID同函数幂等，其他函数/线程期改owner拒绝；实例寿命与Core/DSO进程pin合同一致。 */
AMCL_INPUT_PUBLIC int amclInputOwnerInstallLookCommitV1(AmclInputLookCommitV1 commit);
/** 只读实际登记资格，缺hook是明确旧能力，不在consumer第一次移动时惰性登记。 */
AMCL_INPUT_PUBLIC int amclInputOwnerLookCommitReadyV1(void);
AMCL_INPUT_PUBLIC int amclInputOwnerReadLookResourceV1(AmclInputLookCoreResourceV1* resource);
#ifdef __cplusplus
}
#endif
#endif
