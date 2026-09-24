/**
 * JNI bridge 宿主生命周期接口：启动线程只发布原生能力，实际消费者负责首次 Java 绑定。
 * 发布应在调用游戏加载器之前完成，撤销应在 main 返回/启动失败之后执行。
 * 一局生命周期内不可重复发布；同 PID 也不可通过撤销后重新发布来复用已污染 JVM。
 */

#ifndef JNI_REGISTRY_H
#define JNI_REGISTRY_H

#include "callback_bridge_host.h"

#ifdef __cplusplus
extern "C" {
#endif

/** launchId 必须非零；成功为 JNI_OK，重复发布、环境写入失败等均返回 JNI_ERR。 */
int publishCallbackBridgeHostV1(uint64_t launchId);

/** 撤销原生入口和环境发现线索；不 UnregisterNatives，也不假装能卸载已经运行的 JVM。 */
void revokeCallbackBridgeHostV1(void);

#ifdef __cplusplus
}
#endif

#endif // JNI_REGISTRY_H
