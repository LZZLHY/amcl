/** 唯一 neutral 来源贡献 owner 的私有 producer 端口。标准游戏/consumer ABI 不变。
 * 所有跨 DSO 参数都是值 POD；容器、锁、router 和 allocator 均留在 neutral 映像。
 * accepted 是源候选已提交，transportAccepted 是全部边沿已经进入真实有序运输；
 * 两者均不等于 consumer cache/callback/SDL ADD，更不等于游戏独立 tick 采用。 */
#ifndef AMCL_SOURCE_CONTROL_H
#define AMCL_SOURCE_CONTROL_H
#include <stdint.h>
#include "../input_text_core_hook.h"
#if defined(__GNUC__)
#define AMCL_SOURCE_PUBLIC __attribute__((visibility("default")))
#else
#define AMCL_SOURCE_PUBLIC
#endif
#ifdef __cplusplus
extern "C" {
#endif
#define AMCL_SOURCE_CONTROL_MAGIC 0x534f5531u
#define AMCL_SOURCE_CONTROL_ENV "AMCL_SOURCE_CONTROL_V1"
#define AMCL_SOURCE_CONTROL_PREFIX "AMCL_SOURCE_CONTROL_V1:"
enum { AMCL_SOURCE_ENTRY=1, AMCL_SOURCE_JAVA_COMPAT=2 };
enum { AMCL_SOURCE_ACQUIRE=1, AMCL_SOURCE_RELEASE=2, AMCL_SOURCE_ANONYMOUS=3,
    AMCL_SOURCE_OWNED_GROUP=4, AMCL_SOURCE_RELEASE_OWNER=5, AMCL_SOURCE_CANCEL_SOURCE=6,
    AMCL_SOURCE_PHYSICAL=7, AMCL_SOURCE_RESET_BEGIN=8, AMCL_SOURCE_RESET_END=9,
    AMCL_SOURCE_CLEAR_EXTERNAL=10, AMCL_SOURCE_CANCEL_ALL=11,
    AMCL_SOURCE_ISSUE_NATIVE=12, AMCL_SOURCE_OWNED_EDGE=13, AMCL_SOURCE_FLUSH_TERMINALS=14, AMCL_SOURCE_OWNED_TEXT_TAP=15 };
enum { AMCL_SOURCE_RETIRED_DEFERRED=2, AMCL_SOURCE_ACCEPTED_EDGE=1,
    AMCL_SOURCE_ACCEPTED_NO_EDGE=0, AMCL_SOURCE_REJECTED=-1,
    AMCL_SOURCE_NOT_READY=-2, AMCL_SOURCE_PRESSURE=-3 };
enum { AMCL_SOURCE_ALLOW_RETIRE=1u };
typedef struct AmclSourceOutputV1 { uint32_t kind; int32_t code; } AmclSourceOutputV1;
typedef struct AmclSourceRequestV1 {
    uint32_t size, operation;
    int32_t source, action;
    uint32_t count, flags;
    uint64_t owner, device;
    uint32_t rawControl, bridgeAvailable;
    int32_t scancode, mods;
    char control[513];
    AmclSourceOutputV1 outputs[6];
    /** 仅OWNED_TEXT_TAP使用的原Core文字scope；不是OS/device/owner token，不从current补填。 */
    uint64_t textScope;
    /** 新owned文字键的原Keyboard资源scope；仅L2使用，prepare前捕获，不从current补填。 */
    uint64_t keyboardScope;
} AmclSourceRequestV1;
typedef struct AmclSourceResultV1 {
    uint32_t size, accepted, sourceRetired, transportAccepted;
    uint32_t finalEdges, deferredEdges;
    int32_t status, physicalOutcome, routedCode;
    uint32_t reserved;
    uint64_t owner;
} AmclSourceResultV1;
/** 单次 query 在 source 事务锁下复制，计数不可把 desired held 当成实际输出缓存。 */
typedef struct AmclSourceSnapshotV1 {
    uint32_t size, resetting, owners, outputs, physical, maxSameSource, deferredEdges, owns;
    uint32_t held[5], acquired[5], released[5];
} AmclSourceSnapshotV1;
typedef struct AmclSourceControlPortV1 {
    uint32_t magic, version, size, pid;
    uint64_t ownerHost;
    int32_t (*verifyOwner)(uint64_t ownerHost);
    int32_t (*openProducer)(uint32_t role, uint64_t* producer);
    /** 只读已准入句柄；冷缺席返回 NotReady，不初始化 state 或分配 producer。 */
    int32_t (*preparedProducer)(uint32_t role, uint64_t* producer);
    int32_t (*transact)(uint64_t producer, const AmclSourceRequestV1*, AmclSourceResultV1*);
    int32_t (*query)(uint64_t producer, uint64_t owner, const AmclSourceOutputV1*, AmclSourceSnapshotV1*);
    /** 私有尾能力：原textSession资格的一次逻辑tap；Submitted只表示整pair运输接受，
     * 不代表cache/ADD/next/game采用。旧64字节表不得借作新72字节能力，冷混搭明确拒绝。 */
    int32_t (*ownedTextKeyTap)(uint64_t producer, uint64_t textSession, uint64_t textScope, int32_t key, AmclSourceResultV1*);
    /** 新80字节私有尾：同时冻结文字与L2键资源。旧72表/请求exact size冷拒。
     * 旧尾对L2明确NotReady，不能把缺少原key scope的调用静默贴到新Keyboard。 */
    int32_t (*ownedTextKeyTapForKeyboard)(uint64_t producer,uint64_t textSession,uint64_t textScope,uint64_t keyboardScope,int32_t key,AmclSourceResultV1*);
} AmclSourceControlPortV1;
AMCL_SOURCE_PUBLIC const AmclSourceControlPortV1* amclSourceControlGetPortV1(void);
AMCL_SOURCE_PUBLIC void amclSourceControlPublishV1(void);
/** 冷准备返回 1 已准入、0 未准入。只借预线程发布的唯一 port，不构造本 namespace owner。 */
AMCL_SOURCE_PUBLIC int amclSourceControlPrepareV1(void);
/** Java 固定兼容 source0，旧 NAPI source0 同一匿名持有权威。公开 Java 签名保留。 */
AMCL_SOURCE_PUBLIC int amclSourceControlCompatEdgeV1(uint32_t kind,int32_t code,int32_t scan,int32_t action,int32_t mods);
/** consumer 泵入口维护未交付 terminal，纯 query/getter 不推进状态。没有新按键也可恢复末松。 */
AMCL_SOURCE_PUBLIC int amclSourceControlDrainTerminalsV1(void);
/** 精确因原Keyboard资源退休而丢弃的末松计数；不计作真实consumer UP完成。 */
AMCL_SOURCE_PUBLIC uint64_t amclSourceControlRetiredKeyTerminalsV1(void);
/** neutral 内部 bridge 私有预算口，成功后须同线程调用既有 endLookAction。 */
AMCL_SOURCE_PUBLIC int inputBridge_beginSourceActionV1(uint32_t edges);
/** 已预留Source批内的key复制，显式携原Keyboard scope；不另取锁/不在途中通知。 */
AMCL_SOURCE_PUBLIC void inputBridge_pushKeyScopedV1(int key,int scan,int action,int mods,uint64_t originalScope);
#ifdef __cplusplus
}
#endif
#endif
