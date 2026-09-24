#ifndef AMCL_GRAPHICS_OBSERVATION_ABI_H
#define AMCL_GRAPHICS_OBSERVATION_ABI_H
#include <stdint.h>
#include "graphics_runtime_export.h"
#define AMCL_GRAPHICS_OBSERVER_ENV "AMCL_GRAPHICS_OBSERVER_V1"
#if defined(_WIN32)
#define AMCL_GRAPHICS_OBSERVATION_PUBLIC __declspec(dllexport)
#else
#define AMCL_GRAPHICS_OBSERVATION_PUBLIC __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
// 输入订阅者只推进对应窗口的呈现屏障，不得递归报告呈现。回调必须在进程期保持有效，
// 由实际输入 owner 注册；window/generation 是本次呈现的身份，0 表示旧兼容入口未提供。
typedef void (*AmclGraphicsPresentSinkV1)(uint64_t window, uint64_t generation);
/** 进程期只读观测与呈现分发描述符。跨 linker namespace 与 SDL 使用同一 owner；
 * PID 不匹配先拒绝解引用，调用者不得释放表。图形事实先记录，再通知输入订阅者。
 */
typedef struct AmclGraphicsObserverV1 {
    uint32_t structSize, abiVersion;
    uint64_t processId;
    void (*presented)(const char* provider);
    void (*swapped)(const char* provider, uint64_t elapsedNs, int success, uint32_t error);
    void (*fatal)(const char* stage, uint32_t error, uint64_t generation);
    void (*foreground)(int visible);
    // 返回调用线程借用的字符串，仅有效到该线程下一次snapshot；跨调用比较/保留必须复制。
    const char* (*snapshot)(int failuresOnly);
    // 兼容追加的只读能力尾部；旧SDL只使用上面的前缀，新消费者可在关闭观测时跳过计时。
    int (*samplesEnabled)();
    // 追加尾部：纯观测 presented 前缀保持不变；完整呈现边界调用这里，避免依赖输入 active。
    void (*dispatchPresent)(const char* provider, uint64_t window, uint64_t generation);
    int (*registerPresentSink)(const char* provider, AmclGraphicsPresentSinkV1 sink);
} AmclGraphicsObserverV1;
AMCL_GRAPHICS_OBSERVATION_PUBLIC int amclGraphicsPublishObserverV1(void);
AMCL_GRAPHICS_OBSERVATION_PUBLIC void amclGraphicsPresentedV1(const char* provider);
// 返回0表示尚无公共owner；输入兼容入口此时只推进自己的屏障，不能伪造观测已就绪。
AMCL_GRAPHICS_OBSERVATION_PUBLIC int amclGraphicsDispatchPresentV1(const char* provider, uint64_t window, uint64_t generation);
AMCL_GRAPHICS_OBSERVATION_PUBLIC int amclGraphicsRegisterPresentSinkV1(const char* provider, AmclGraphicsPresentSinkV1 sink);
AMCL_GRAPHICS_OBSERVATION_PUBLIC void amclGraphicsSwapV1(const char* provider, uint64_t elapsedNs, int success, uint32_t error);
AMCL_GRAPHICS_OBSERVATION_PUBLIC void amclGraphicsFatalV1(const char* stage, uint32_t error, uint64_t generation);
AMCL_GRAPHICS_OBSERVATION_PUBLIC void amclGraphicsForegroundV1(int visible);
AMCL_GRAPHICS_OBSERVATION_PUBLIC const char* amclGraphicsRuntimeJsonV1(void);
AMCL_GRAPHICS_OBSERVATION_PUBLIC const char* amclGraphicsFailureJsonV1(void);
AMCL_GRAPHICS_OBSERVATION_PUBLIC int amclGraphicsObservationEnabledV1(void);
AMCL_GRAPHICS_OBSERVATION_PUBLIC const char* amclGraphicsBoundProfileV1(void);
AMCL_GRAPHICS_OBSERVATION_PUBLIC const char* amclGraphicsBoundApiV1(void);
#ifdef __cplusplus
}
#endif
#endif
