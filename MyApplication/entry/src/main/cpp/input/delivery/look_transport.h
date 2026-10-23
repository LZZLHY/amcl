/** neutral运输的私有接缝。所有功能由真实bridge ring承载，不重用公开physical raw事件。 */
#ifndef AMCL_LOOK_TRANSPORT_H
#define AMCL_LOOK_TRANSPORT_H
#include "look_execution.h"
#ifdef __cplusplus
extern "C" {
#endif
#define AMCL_LOOK_PREFIX_EVENT 1020
/** bridge实例V1的可选look整组尾部版本；长度与全部方法一起协商，不修改旧前缀。 */
#define AMCL_LOOK_TRANSPORT_VERSION 1u
/** Resource在任何order/queue锁前读取；caller的surface/mode gate覆盖实际提交。 */
AMCL_CONTROL_PUBLIC int inputBridge_getLookResourceV1(AmclLookResourceV1* output);
/** 先保真实ring容量再提交delta+prefix，返回1只证明源/运输接受。stream=0只advance。 */
AMCL_CONTROL_PUBLIC int inputBridge_submitLookV1(uint64_t stream,double dx,double dy,uint64_t sampleNs,uint32_t flush);
/** 同一批封旧look再调用ledger的action输出。嵌套sendData借原锁，不再取push造成死锁。 */
AMCL_CONTROL_PUBLIC int inputBridge_beginLookActionV1(void);
AMCL_CONTROL_PUBLIC void inputBridge_endLookActionV1(void);
/** 正式GLFW注册自己实际target/control consumer的prefix执行边缘，函数在look锁外调用。 */
typedef int (*AmclLookPrefixCallbackV1)(void* window,uint64_t prefix);
AMCL_CONTROL_PUBLIC void inputBridge_setLookPrefixCallbackV1(AmclLookPrefixCallbackV1 callback);
/** 旧processed aliases进入明确prefix运输，不再写future全局累计；false保持源余量待重试。 */
AMCL_CONTROL_PUBLIC int inputBridge_submitProcessedLookV1(int32_t source,double dx,double dy);
#ifdef __cplusplus
}
#endif
#endif
