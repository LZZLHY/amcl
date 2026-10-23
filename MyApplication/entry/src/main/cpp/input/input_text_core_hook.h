/** 唯一Core给owned编辑键的私有原事实接缝，公开事件/host/control/look表不变。
 * resource在Core锁内读取；scope只是Core当前文本资格的发布围栏，不是第二文本registry。
 * Source持order/push时只复核原scope原子值，禁止反向获取Core mutex。
 */
#ifndef AMCL_INPUT_TEXT_CORE_HOOK_H
#define AMCL_INPUT_TEXT_CORE_HOOK_H
#include "input_look_core_hook.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct AmclInputTextCoreResourceV1 {
    uint32_t size, active;
    uint64_t textSession, scope;
    AmclInputLookCoreResourceV1 input;
} AmclInputTextCoreResourceV1;
/** 缺真实文本/后端/surface/focus时返回0；不安装Core、consumer或来源。 */
AMCL_INPUT_PUBLIC int amclInputOwnerReadTextResourceV1(AmclInputTextCoreResourceV1* resource);
/** 只核原scope发布值；调用者在原有order事务中线性化提交，不能把此值当新租约。 */
AMCL_INPUT_PUBLIC int amclInputOwnerValidateTextScopeV1(uint64_t scope);
#ifdef __cplusplus
}
#endif
#endif
