/**
 * AMCL 自有 CallbackBridge 的进程内宿主契约。
 *
 * 这里只发布 RegisterNatives 的原生能力，不加载 Java 类，也不持有第二份输入状态。
 * 环境字符串只是跨链接命名空间的发现线索：消费者必须先核对 PID、ABI、会话及
 * dladdr 返回的精确导出符号，再调用 getter；绝不能直接解引用环境变量中的地址。
 * 该机制不是不可信代码的安全隔离边界；同进程任意 native 代码本来就具有完整权限。
 */
#ifndef AMCL_CALLBACK_BRIDGE_HOST_H
#define AMCL_CALLBACK_BRIDGE_HOST_H

#include <stdint.h>
#include "jni.h"

#define AMCL_CALLBACK_BRIDGE_HOST_ABI 1u
#define AMCL_CALLBACK_BRIDGE_HOST_MAGIC UINT64_C(0x414D434C43425631)
#define AMCL_CALLBACK_BRIDGE_HOST_ENV "AMCL_CALLBACK_BRIDGE_HOST_V1"
#define AMCL_CALLBACK_BRIDGE_HOST_GETTER "amclCallbackBridgeHostGetV1"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 发布后只读的函数表；有效期截止到本局 main 返回或启动失败。
 * bind 只接受 JNI_OnLoad 取得的实际 Class，不再次 FindClass，不注册任何 LWJGL 方法。
 * 成功必须返回 JNI_OK；失败返回 JNI_ERR，并保留 JNI 原始异常供 JVM 报告。
 */
typedef struct AmclCallbackBridgeHostV1 {
    uint64_t magic;
    uint32_t abi;
    uint32_t size;
    uint32_t pid;
    uint32_t reserved;
    uint64_t launchId;
    jint (*bind)(JNIEnv* env, jclass actualClass);
} AmclCallbackBridgeHostV1;

typedef const AmclCallbackBridgeHostV1* (*AmclCallbackBridgeHostGetterV1)(void);

/** getter 不要求 Java 类已加载；已撤销或继承了其他 PID 描述符时返回 NULL。 */
JNIEXPORT const AmclCallbackBridgeHostV1* amclCallbackBridgeHostGetV1(void);

#ifdef __cplusplus
}
#endif
#endif
