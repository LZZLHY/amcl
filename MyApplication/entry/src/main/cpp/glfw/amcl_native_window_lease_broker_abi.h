// amcl_native_window_lease_broker_abi.h
//
// Stable C ABI shared by the XComponent-owning host image and render backends
// loaded in another linker namespace. ABI v2 is append-only: consumers must
// validate structSize before reading tail fields. The SDL hybrid consumer
// requires the complete v2 descriptor, including the atomic peek pair; a
// core-only descriptor cannot provide safe steady-state recovery.

#ifndef AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_H
#define AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_H

#include <stddef.h>
#include <stdint.h>

#define AMCL_NATIVE_WINDOW_LEASE_BROKER_ENV "AMCL_NATIVE_WINDOW_LEASE_BROKER"
#define AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_VERSION 2u

// The generation is the publication commit token. A consumer that already
// owns generation N may stay on its lock-free steady path while peekGeneration
// still returns N. Once it changes, acquire() is the only authoritative way to
// obtain pointer/size/state and a new NativeWindow reference.
typedef uint32_t AmclNativeWindowPublicationState;
#define AMCL_NATIVE_WINDOW_PUBLICATION_UNPUBLISHED 0u
#define AMCL_NATIVE_WINDOW_PUBLICATION_READY       1u
#define AMCL_NATIVE_WINDOW_PUBLICATION_SUSPENDED   2u
#define AMCL_NATIVE_WINDOW_PUBLICATION_CLEARED     3u

// 新增可选 identity 尾部：publication token、资源生命周期与几何变化分别表达。
// acquireIdentity 在取得引用的同一把锁内填写全部字段，不能先 acquire 再另读 epoch 拼快照。
typedef struct AmclNativeWindowIdentityV1 {
    uint32_t structSize;
    uint32_t abiVersion;
    void* nativeWindow;
    uint64_t generation;
    uint64_t resourceEpoch;
    uint64_t geometryEpoch;
    int width;
    int height;
} AmclNativeWindowIdentityV1;

typedef struct AmclNativeWindowLeaseBrokerV2 {
    uint32_t abiVersion;
    uint32_t structSize;

    // Core v2 lease API. acquire() returns 0 when no ready publication exists,
    // 1 when it added a reference, or 2 when the caller's retained lease is
    // already the current publication and no reference was added.
    int (*acquire)(void* retainedNativeWindow,
                   uint64_t retainedGeneration,
                   void** outNativeWindow,
                   int* outWidth,
                   int* outHeight,
                   uint64_t* outGeneration);
    void (*release)(void* nativeWindow);
    int (*beginInputPublication)(int* outWidth,
                                 int* outHeight,
                                 uint64_t* outGeneration);
    void (*endInputPublication)(void);

    // Required fast path for the SDL hybrid consumer. peekGeneration() is an
    // acquire-load of the host's publication commit token and is sufficient
    // for the steady-state generation comparison. peekState() is
    // diagnostic/recovery state. Producers publish generation before state;
    // readers needing a consistent pair read generation, state, generation
    // and retry if the two generation reads differ. A newly observed generation
    // paired briefly with the previous state is conservative; the forbidden
    // tuple is an old generation paired with a new READY state.
    uint64_t (*peekGeneration)(void);
    AmclNativeWindowPublicationState (*peekState)(void);

    // Optional presentation tail. Unlike legacy pointer-only reference leases,
    // these opaque tokens identify one session in the host image across linker
    // namespaces. Claim is atomic with READY/pointer/generation validation.
    // A suspended session keeps its token until its resource owner confirms full
    // teardown. movePresentation is legal only after the old surface is retired
    // (or for a same-pointer metadata update). Stale releases cannot free a new
    // owner's token. api is 1=OpenGL, 2=Vulkan; it describes the game-facing API.
    int (*claimPresentation)(void* nativeWindow, uint64_t generation,
                             uint32_t api, uint64_t* outToken);
    int (*movePresentation)(uint64_t token, void* nativeWindow,
                            uint64_t generation);
    int (*releasePresentation)(uint64_t token);
    int (*acquireIdentity)(void* retainedNativeWindow, uint64_t retainedGeneration,
                           AmclNativeWindowIdentityV1* identity);
    // 只移动同一资源的元数据。宿主同时核验旧 token 代际、新发布代际和资源 epoch；
    // clear→publish 即使指针相同也拒绝。旧 V2 消费者不读尾部，继续保守重建。
    int (*movePresentationGeometry)(uint64_t token, void* nativeWindow,
                                    uint64_t oldGeneration, uint64_t newGeneration, uint64_t resourceEpoch);
    // 可选输入前台尾部（I27-05 之后替代每帧读取的 AMCL_WINDOW_FOREGROUND 环境变量）。
    // 返回 XComponent 宿主输入前台门禁的当前值：1 = surface 已发布、Ability 在前台且组件
    // 未失焦，0 = 其余情形（含宿主尚未算出过门禁）。实现只做一次 acquire 原子读，不加锁、
    // 不分配、不调用系统接口，可在任意线程逐帧调用。消费者必须先核验 structSize 覆盖到本字段、
    // 且指针非空才能调用；更短的描述符不能证明宿主授予输入资格，注入窗口必须保守停收。
    uint32_t (*peekInputForeground)(void);
} AmclNativeWindowLeaseBrokerV2;

// The core prefix is retained for append-only ABI accounting. SDL's hybrid
// validation additionally requires V2_PEEK_SIZE, because accepting a producer
// without the peek pair would silently disable generation recovery.
#define AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_CORE_SIZE \
    ((uint32_t)(offsetof(AmclNativeWindowLeaseBrokerV2, endInputPublication) + \
                sizeof(((AmclNativeWindowLeaseBrokerV2*)0)->endInputPublication)))
#define AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PEEK_SIZE \
    ((uint32_t)(offsetof(AmclNativeWindowLeaseBrokerV2, peekState) + \
                sizeof(((AmclNativeWindowLeaseBrokerV2*)0)->peekState)))
#define AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PRESENTATION_SIZE \
    ((uint32_t)(offsetof(AmclNativeWindowLeaseBrokerV2, releasePresentation) + \
                sizeof(((AmclNativeWindowLeaseBrokerV2*)0)->releasePresentation)))
#define AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_IDENTITY_SIZE \
    ((uint32_t)(offsetof(AmclNativeWindowLeaseBrokerV2, movePresentationGeometry) + \
                sizeof(((AmclNativeWindowLeaseBrokerV2*)0)->movePresentationGeometry)))
// 输入前台尾部的最小 structSize：消费者据此判定 peekInputForeground 是否存在。
#define AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_INPUT_FOREGROUND_SIZE \
    ((uint32_t)(offsetof(AmclNativeWindowLeaseBrokerV2, peekInputForeground) + \
                sizeof(((AmclNativeWindowLeaseBrokerV2*)0)->peekInputForeground)))

#if defined(__cplusplus)
static_assert(offsetof(AmclNativeWindowLeaseBrokerV2, acquire) ==
                  sizeof(uint32_t) * 2,
              "NativeWindow lease ABI acquire offset drifted");
static_assert(AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_CORE_SIZE <=
                  sizeof(AmclNativeWindowLeaseBrokerV2),
              "NativeWindow lease ABI core prefix is too large");
static_assert(AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PEEK_SIZE <=
                  sizeof(AmclNativeWindowLeaseBrokerV2),
              "NativeWindow lease ABI peek tail is not append-only");
static_assert(AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PRESENTATION_SIZE <=
                  sizeof(AmclNativeWindowLeaseBrokerV2),
              "NativeWindow presentation tail is not append-only");
// 新尾部只能追加在 identity 尾部之后：SDL 私有镜像按同一顺序声明，并由宿主测试核对偏移。
static_assert(offsetof(AmclNativeWindowLeaseBrokerV2, peekInputForeground) ==
                  AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_IDENTITY_SIZE,
              "NativeWindow input-foreground tail must follow the identity tail");
#else
_Static_assert(offsetof(AmclNativeWindowLeaseBrokerV2, acquire) ==
                   sizeof(uint32_t) * 2,
               "NativeWindow lease ABI acquire offset drifted");
_Static_assert(AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_CORE_SIZE <=
                   sizeof(AmclNativeWindowLeaseBrokerV2),
               "NativeWindow lease ABI core prefix is too large");
_Static_assert(AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PEEK_SIZE <=
                  sizeof(AmclNativeWindowLeaseBrokerV2),
              "NativeWindow lease ABI peek tail is not append-only");
_Static_assert(AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_PRESENTATION_SIZE <=
                   sizeof(AmclNativeWindowLeaseBrokerV2),
               "NativeWindow presentation tail is not append-only");
_Static_assert(offsetof(AmclNativeWindowLeaseBrokerV2, peekInputForeground) ==
                   AMCL_NATIVE_WINDOW_LEASE_BROKER_V2_IDENTITY_SIZE,
               "NativeWindow input-foreground tail must follow the identity tail");
#endif

#endif // AMCL_NATIVE_WINDOW_LEASE_BROKER_ABI_H
