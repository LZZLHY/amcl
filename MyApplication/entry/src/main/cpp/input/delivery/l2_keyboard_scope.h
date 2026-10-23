/** L2实际Keyboard资源的独立私有资格端口。
 * 它只登记真实上游create完整成功后的生命周期事实；desired/cache/ticket/next仍归
 * 原control owner。独立表与lease均为C POD，不改control/look或标准事件格式；
 * Source的owned键调用另外通过80字节私有尾传递接受前捕获的原Keyboard scope。
 */
#ifndef AMCL_L2_KEYBOARD_SCOPE_H
#define AMCL_L2_KEYBOARD_SCOPE_H
#include <stdint.h>
#include "../amcl_input_api.h"
#ifdef __cplusplus
extern "C" {
#endif
#define AMCL_L2_KEYBOARD_MAGIC 0x4c324b31u
#define AMCL_L2_KEYBOARD_PREFIX "AMCL_L2_KEYBOARD_V1:"
#define AMCL_L2_KEYBOARD_ENV "AMCL_L2_KEYBOARD_OWNER"
typedef struct AmclL2KeyboardLeaseV1 {
    uint32_t size,backend;
    uint64_t consumer,target,generation;
} AmclL2KeyboardLeaseV1;
typedef struct AmclL2KeyboardPortV1 {
    uint32_t magic,version,size,processId;
    uint64_t ownerHost;
    int32_t (*verifyOwner)(uint64_t);
    int32_t (*completeCreate)(uint64_t,AmclL2KeyboardLeaseV1*);
    int32_t (*fence)(const AmclL2KeyboardLeaseV1*);
    int32_t (*snapshot)(uint64_t,AmclL2KeyboardLeaseV1*);
    int32_t (*validate)(const AmclL2KeyboardLeaseV1*);
    int32_t (*readCoreStamp)(uint64_t,uint64_t,uint64_t*);
    /** 新资源只投影唯一Source/Core仍合法的当前持有，不重放点击、文字或旧队列。
     * 返回1持有、0未持有、负数原lease已失效；实现取事实锁时不调用Java或游戏。 */
    int32_t (*readHeldLegacy)(const AmclL2KeyboardLeaseV1*,int32_t);
    int32_t (*readHeldTyped)(const AmclL2KeyboardLeaseV1*,int32_t);
} AmclL2KeyboardPortV1;
AMCL_INPUT_PUBLIC const AmclL2KeyboardPortV1* amclInputL2KeyboardGetPortV1(void);
AMCL_INPUT_PUBLIC void amclInputL2KeyboardPublishV1(void);
/** Core只镜像唯一control owner的已发布事实；CAS使旧close不能清掉新Keyboard。
 * 无Core mutex，供Source/order事务最后围栏及Core接受处盖章；不是第二资格分配器。
 */
AMCL_INPUT_PUBLIC uint64_t amclInputOwnerL2KeyboardScopeV1(void);
AMCL_INPUT_PUBLIC int amclInputOwnerCompareL2KeyboardScopeV1(uint64_t expected,uint64_t desired);
AMCL_INPUT_PUBLIC void amclInputOwnerSelectKeyboardBackendV1(uint32_t backend);
AMCL_INPUT_PUBLIC uint32_t amclInputOwnerSelectedKeyboardBackendV1(void);
AMCL_INPUT_PUBLIC int amclInputOwnerReadL2KeyStampV1(uint64_t host,uint64_t consumer,uint64_t sequence,uint64_t* scope);
/** 仅查询当前原始物理键事实，并沿原L2 mapper映射；不改变held或任何消费队列。 */
AMCL_INPUT_PUBLIC int amclInputOwnerReadL2HeldKeyV1(int32_t key);
#ifdef __cplusplus
}
#endif
#endif
