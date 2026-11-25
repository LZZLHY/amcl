#ifndef AMCL_WINDOW_HOST_H
#define AMCL_WINDOW_HOST_H
#include "../glfw/amcl_native_window_lease_broker_abi.h"

#if defined(AMCL_WINDOW_HOST_STATIC)
#define AMCL_WINDOW_EXPORT
#elif defined(_WIN32)
#define AMCL_WINDOW_EXPORT __declspec(dllexport)
#else
#define AMCL_WINDOW_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AmclWindowHostSnapshot {
    void* nativeWindow;
    uint64_t generation;
    int width;
    int height;
    AmclNativeWindowPublicationState state;
} AmclWindowHostSnapshot;
typedef void (*AmclWindowHostCommitFn)(const AmclWindowHostSnapshot*, void*);

/**
 * XComponent owner 注册的只读函数表，生命周期覆盖当前进程。flags不得加gate锁；
 * 其余回调由呈现线程进入，注册者自行串行化UI生命周期与政策，不能访问ArkUI对象。
 * 跨namespace只转发C接口，不复制输入映射或另建窗口owner；fork后必须重新注册。
 */
typedef struct AmclWindowGeometryClientV1 {
    uint32_t structSize;
    uint32_t abiVersion;
    uint32_t (*workFlags)(void);
    int (*checkpoint)(void*, uint64_t, uint64_t);
    void (*observe)(void*, uint64_t, uint64_t, int, int, uint32_t);
} AmclWindowGeometryClientV1;
AMCL_WINDOW_EXPORT int amclWindowHostRegisterGeometryClient(const AmclWindowGeometryClientV1* client);

typedef struct AmclWindowHostStats {
    uint64_t generation;
    uint64_t publications;
    uint64_t acquired;
    uint64_t reused;
    uint64_t released;
    uint64_t liveLeases;
    uint64_t livePresentationToken;
    uint64_t pendingRetirements;
    uint64_t referenceFailures;
    uint64_t unreferenceFailures;
    uint64_t rejectedReleases;
    uint64_t rejectedPresentations;
    uint32_t state;
    uint32_t publicationReference;
} AmclWindowHostStats;

AMCL_WINDOW_EXPORT uint64_t amclWindowHostNextGeneration(uint64_t current);
// The optional publisher callback runs inside the exclusive publication
// transaction before the generation commit. It must not re-enter this host.
AMCL_WINDOW_EXPORT uint64_t amclWindowHostPublish(void* nativeWindow, int width, int height,
    AmclWindowHostCommitFn beforeCommit, void* context);
AMCL_WINDOW_EXPORT uint64_t amclWindowHostUpdateSize(void* expectedWindow, uint64_t expectedGeneration, int width, int height);
AMCL_WINDOW_EXPORT uint64_t amclWindowHostClear(void* expectedWindow, uint64_t expectedGeneration);
AMCL_WINDOW_EXPORT int amclWindowHostReadSnapshot(AmclWindowHostSnapshot* snapshot);
AMCL_WINDOW_EXPORT uint64_t amclWindowHostPeekGeneration(void);
AMCL_WINDOW_EXPORT AmclNativeWindowPublicationState amclWindowHostPeekState(void);
AMCL_WINDOW_EXPORT const AmclNativeWindowLeaseBrokerV2* amclWindowHostGetBroker(void);
AMCL_WINDOW_EXPORT int amclWindowHostAcquire(void* retainedWindow, uint64_t retainedGeneration, void* retainedBroker,
    void** outWindow, int* outWidth, int* outHeight, uint64_t* outGeneration, void** outBroker);
AMCL_WINDOW_EXPORT void amclWindowHostRelease(void* nativeWindow, void* broker);
AMCL_WINDOW_EXPORT int amclWindowHostBeginInputPublication(int* outWidth, int* outHeight,
    uint64_t* outGeneration, void** outBroker);
AMCL_WINDOW_EXPORT void amclWindowHostEndInputPublication(void* broker);
AMCL_WINDOW_EXPORT void amclWindowHostGetStats(AmclWindowHostStats* stats);
AMCL_WINDOW_EXPORT int amclWindowHostRetryRetiredReferences(void);
// 在任何游戏/JVM 线程出现前发布进程 owner 与 v2 broker 两个环境描述符（每进程只写一次）。
// 返回 1：本映像是（或刚成为）owner；0：另一映像已是 owner 或已有不兼容的旧描述符。
// surface 状态不再镜像到环境变量，消费者只经 broker / ReadSnapshot 读取。
AMCL_WINDOW_EXPORT int amclWindowHostPublishOwner(void);
// 写入宿主输入前台门禁的当前值（非 0 视为前台），由 XComponent 所在映像在门禁锁内调用；
// 转发到进程 owner 映像，经 broker 的 peekInputForeground 尾部供 SDL 等消费者无锁读取。
// 返回 1：owner 已接受；0：owner/broker 描述符畸形（失败关闭，调用方记录）。
// 进程内初值为 0（与首个 surface 发布前的门禁计算结果一致）；fork 子进程从 0 重新开始。
AMCL_WINDOW_EXPORT int amclWindowHostSetInputForeground(int foreground);
// 唤醒只表示SDL文本需求发生变化；回调在窗口账本锁外执行，调用方按当前事实对账。
typedef void (*AmclWindowTextInputWakeFn)(void);
AMCL_WINDOW_EXPORT int amclWindowHostSetTextInputWake(AmclWindowTextInputWakeFn wake);
// 0 表示当前无需求；正数唯一标识本进程当前的一次SDL文本需求。
AMCL_WINDOW_EXPORT uint64_t amclWindowHostTextInputDemandIdentity(void);
// 在原SDL需求和真实发布同一事务内完成一次Native命令。命令不能再进入WindowHost写入口。
typedef int (*AmclWindowTextInputCommandFn)(void* context);
AMCL_WINDOW_EXPORT int amclWindowHostRunTextInputCommand(uint64_t demand, AmclWindowTextInputCommandFn command, void* context);


#if defined(AMCL_WINDOW_HOST_TESTING)
typedef int (*AmclWindowHostReferenceFn)(void*, void*);
AMCL_WINDOW_EXPORT int amclWindowHostSetReferenceDriver(AmclWindowHostReferenceFn reference,
    AmclWindowHostReferenceFn unreference, void* context);
AMCL_WINDOW_EXPORT void amclWindowHostTestOverridePid(uint64_t processId);
#endif

#ifdef __cplusplus
}
#endif
#endif
