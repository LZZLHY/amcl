// 三种实际ABI共用的末级控制贡献端口。只有neutral owner持有归约状态；调用者只保存
// 不复用consumer句柄、实际ABI缓存与回调。此私有C表不改变公共Core/旧事件的前缀语义。
#ifndef AMCL_CONTROL_DELIVERY_H
#define AMCL_CONTROL_DELIVERY_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#if defined(__GNUC__)
#define AMCL_CONTROL_PUBLIC __attribute__((visibility("default")))
#else
#define AMCL_CONTROL_PUBLIC
#endif
#define AMCL_CONTROL_MAGIC UINT64_C(0x414d434c434f4e31)
#define AMCL_CONTROL_VERSION 1u
#define AMCL_CONTROL_ENV "AMCL_CONTROL_DELIVERY_V1"
#define AMCL_CONTROL_PREFIX "AMCLCONTROL:1:"
enum AmclControlResult { AMCL_CONTROL_REJECTED=-1, AMCL_CONTROL_STALE=-2,
    AMCL_CONTROL_PRESSURE=-3, AMCL_CONTROL_NOT_READY=-4,
    AMCL_CONTROL_ACCEPTED_NO_EDGE=0, AMCL_CONTROL_EDGE=1 };
enum AmclControlKind { AMCL_CONTROL_KEY=1, AMCL_CONTROL_BUTTON=2 };
// 与GLFW/L2既有action一致；SDL只在此边缘把UP/DOWN转换，不能再次解释来源持有。
enum AmclControlAction { AMCL_CONTROL_UP=0, AMCL_CONTROL_DOWN=1, AMCL_CONTROL_REPEAT=2 };
// Aggregate表示上游已经汇总的一份贡献；SDL设备按钮与未来contact保留独立owner。
enum AmclControlClass { AMCL_CONTROL_LEGACY=1, AMCL_CONTROL_TYPED=2,
    AMCL_CONTROL_TYPED_DEVICE=3, AMCL_CONTROL_CONTACT=4 };
#define AMCL_CONTROL_MASK_LEGACY 1u
#define AMCL_CONTROL_MASK_TYPED 6u
#define AMCL_CONTROL_MASK_ALL 15u
// STATE_ONLY仅证明ABI缓存已应用且保留ticket；L2 enqueue不属于PULL_COMMITTED，
// 该端须直到真实Mouse/Keyboard next领取才终结。SDL的PULL_COMMITTED只证明其
// SDL_Send*队列/ABI出口交接，不能宣传为游戏SDL_PollEvent已经处理。
enum AmclControlCompletion { AMCL_CONTROL_STATE_ONLY=0, AMCL_CONTROL_CALLBACK_RETURNED=1,
    AMCL_CONTROL_PULL_COMMITTED=2, AMCL_CONTROL_STATE_FINAL=3,
    AMCL_CONTROL_UNCERTAIN=4, AMCL_CONTROL_DISCARDED=5 };
typedef struct AmclControlEmissionV1 {
    // ABI边缘只复制这份冻结记录，complete/validate不得换成current target/consumer。
    // size须为完整V1，code/scanCode是本consumer后端命名空间，action为最终交付边沿。
    uint32_t size,kind;
    int32_t code,scanCode,action;
    uint32_t reserved;
    uint64_t consumer,activation,revision,ticket,target;
} AmclControlEmissionV1;
typedef struct AmclControlSnapshotV1 {
    // 统计带原consumer/session/activation/target；计数分别表示cache、callback返回、
    // 实际pull出口/队列交接及合法getter读取，任何一列均不代替“游戏业务已经处理”。
    uint32_t size,backend;
    uint64_t consumer,gameSession,activation,target;
    uint64_t accepted,noEdge,edges,callbackReturned,pullCommitted,stateOnly;
    uint64_t legalPollReads,pollMismatches,staleCompletions,lastCompletedActivation,uncertain,discarded;
} AmclControlSnapshotV1;
typedef struct AmclControlDeliveryPortV1 {
    uint64_t magic;
    uint32_t version,size,pid,reserved;
    // 同一neutral owner的公共Core表身份；验证还必须经过既有owner descriptor，不能只核pid。
    uint64_t ownerHost;
    int32_t (*verifyOwner)(uint64_t ownerHost);
    // target为调用方真实逻辑目标；生命周期、publication和执行线程仍在ABI边缘核对。
    // open只登记consumer，不初始化SDK/设备或宣布Ready；失败清零输出，容量/身份耗尽为PRESSURE。
    int32_t (*open)(uint32_t backend,uint64_t target,uint64_t* consumer);
    // 关闭指定handle的内部上下文，不调用旧窗口或合成release；真实资源退休由边缘先处理。
    void (*close)(uint64_t consumer);
    // activation耗尽时返回PRESSURE且不改旧target；边缘必须停止向新目标交付。
    int32_t (*bindTarget)(uint64_t consumer,uint64_t target);
    // apply提交一份来源变化；Rejected不配对、NoEdge真实共持、Edge附须claim的冻结票。
    // 候选分配/容量失败不建立假owner；此处成功不证明cache/callback/queue/游戏读取成功。
    int32_t (*apply)(uint64_t consumer,uint32_t contributionClass,uint64_t owner,
        uint32_t kind,int32_t code,int32_t scanCode,int32_t action,AmclControlEmissionV1* emission);
    // retire先一次摘本批旧owner，nextRetired随后逐ticket核reentry新holder，不在锁内输出。
    int32_t (*retire)(uint64_t consumer,uint32_t classMask,uint64_t owner,int32_t onlyOwner);
    // L2 keyboard/mouse能力寿命独立：kind=0全部，1键盘，2鼠标；单kind不退休兄弟记录。
    int32_t (*retireKind)(uint64_t consumer,uint32_t classMask,uint64_t owner,int32_t onlyOwner,uint32_t kind);
    // 每次领取一张仍有效的退休计划；空为NoEdge，目标或贡献已变的旧计划在内部丢弃。
    int32_t (*nextRetired)(uint64_t consumer,AmclControlEmissionV1* emission);
    // 一次性执行围栏：完整记录/当前资格成立才Edge；重复claim拒绝，旧目标/activation为STALE。
    int32_t (*claim)(const AmclControlEmissionV1* emission);
    // 同步SDK hook可在缓存写回/Push之前再次只读核原ticket；不是重复领取或重新绑定。
    int32_t (*validate)(const AmclControlEmissionV1* emission);
    // 输入原票及真实完成阶段；phase0保票，终结阶段摘票。旧callback返回可记原事实，
    // 但不能覆盖重入后的observed状态；失败/不确定不伪造cache或事件交接。
    int32_t (*complete)(const AmclControlEmissionV1* emission,uint32_t phase);
    // 只读accepted desired（0/1）；负值明确失败，不应以C布尔转换把STALE解释为按住。
    int32_t (*query)(uint64_t consumer,uint32_t kind,int32_t code);
    // query为接受贡献，queryDelivered仅为已获phase0证据的ABI缓存，两种口径不可混用。
    int32_t (*queryDelivered)(uint64_t consumer,uint32_t kind,int32_t code);
    // 观测只计实际调用方已经执行的poll读取，永不推进事件或改变owner。
    int32_t (*observePoll)(uint64_t consumer,uint32_t kind,int32_t code,int32_t actualHeld);
    // 完整Keyboard/Mouse状态getter一次调用一次锁；只核已登记control的实际0/1缓存。
    // legalPollReads按getter调用计，mismatch按已登记control差异计，绝不推进owner或事件。
    int32_t (*observePollView)(uint64_t consumer,uint32_t kind,const uint8_t* states,uint32_t count);
    // 输出完整V1诊断快照，不消费任何队列或推进ticket；调用者须核返回结果，不用旧输出。
    int32_t (*snapshot)(uint64_t consumer,AmclControlSnapshotV1* output);
    // activation耗尽时永久关闭此handle；绝不回绕成旧activation。
    void (*abandon)(uint64_t consumer);
} AmclControlDeliveryPortV1;
// 表与registry在module早期发布时初始化，进程内不可变；fork child明确拒绝继承，
// Getter返回NULL，所有旧handle操作在任何继承mutex之前返回STALE/NOT_READY。
AMCL_CONTROL_PUBLIC const AmclControlDeliveryPortV1* amclControlDeliveryGetPortV1(void);
// 只由既有中立bridge的冻结游戏会话入口调用；重复同session幂等，不能换掉借出的owner。
AMCL_CONTROL_PUBLIC int32_t amclControlDeliveryBindSessionV1(uint64_t gameSession);
// module Init早于JVM线程的既有发布点调用；描述符只包含同owner getter地址，重复无写入。
AMCL_CONTROL_PUBLIC void amclControlDeliveryPublishV1(void);
#ifdef __cplusplus
}
#endif
#endif
