/**
 * look_execution.h — 中立运行体拥有的视角执行与动作可见前缀私有端口。
 *
 * 此表不改变公共Core事件、GLFW/LWJGL2/SDL标准ABI，也不改变control-v1贡献合同。
 * producer提交的设备事实、加工pending与consumer已经可用的cursor分别有权威；
 * 不可变prefix将已接受的look与后续action连接，禁止再读未来的全局累计坐标。
 * 三ABI只转换自己的坐标/记录格式及报告真实完成点，不能各自复制积分或尾量状态机。
 */
#ifndef AMCL_INPUT_LOOK_EXECUTION_H
#define AMCL_INPUT_LOOK_EXECUTION_H
#include <stdint.h>
#include <stddef.h>
#include "control_delivery.h"
#include "../amcl_input_event.h"
#ifdef __cplusplus
extern "C" {
#endif

#define AMCL_LOOK_EXECUTION_MAGIC UINT64_C(0x414d434c4c4f4f31)
#define AMCL_LOOK_EXECUTION_VERSION 1u
#define AMCL_LOOK_EXECUTION_ENV "AMCL_LOOK_EXECUTION_V1"
#define AMCL_LOOK_EXECUTION_PREFIX "AMCLLOOK:1:"

/** 结果区分来源事实接受、可交付前缀、暂缺资格与容量失败，不能转bool混淆负值。 */
enum AmclLookResult {
    AMCL_LOOK_REJECTED=-1,AMCL_LOOK_STALE=-2,AMCL_LOOK_PRESSURE=-3,
    AMCL_LOOK_NOT_READY=-4,AMCL_LOOK_ACCEPTED_NO_MOTION=0,AMCL_LOOK_PREFIX_READY=1
};
/** 单位随流冻结。virtual counts没有物理长度/角度承诺，raw counts保持平台能力声明。 */
enum AmclLookUnit {
    AMCL_LOOK_SURFACE_PIXELS=1,AMCL_LOOK_VIRTUAL_COUNTS=2,
    AMCL_LOOK_HARDWARE_COUNTS=3,AMCL_LOOK_VIRTUAL_COUNTS_PER_SECOND=4,
    AMCL_LOOK_PLATFORM_RELATIVE_COUNTS=5
};
/** 仅显式同域时间能积分；同为ns不证明sensor startup与ACTIVE/Native monotonic同域。 */
enum AmclLookClock {
    AMCL_LOOK_OWNER_MONOTONIC=1,AMCL_LOOK_ACTIVE_UPTIME=2,
    AMCL_LOOK_SENSOR_STARTUP=3,AMCL_LOOK_PLATFORM_SAMPLE=4
};
/** 已积分gyro保持独立无平滑时钟；手指与gyro共用触控政策但不是同一个运动流。 */
enum AmclLookStreamKind {
    AMCL_LOOK_TOUCH_DELTA=1,AMCL_LOOK_MAPPED_RATE=2,
    AMCL_LOOK_PHYSICAL_DELTA=3,AMCL_LOOK_GYRO_DELTA=4,AMCL_LOOK_COMPAT_DELTA=5
};
/** 仅新gyro私有lease冻结policy；旧无lease符号明确弱兼容，不能假用跨域时间拒旧样本。 */
#define AMCL_LOOK_STREAM_POLICY_LEASE 1u
/**
 * 真实资源事实由owner Core和模式公告核验。context比较沿既有完整身份规则，Hz仍只是
 * 元数据；modeEpoch不能由物理captureActive替代，非物理world look使用实际逻辑grab。
 */
typedef struct AmclLookResourceV1 {
    uint32_t size,grabbed;
    uint64_t gameSession,sessionEpoch,surfaceEpoch,focusEpoch,modeEpoch;
    AmclInputSurfaceContextPayload context;
} AmclLookResourceV1;
/**
 * 来源流首次登记冻结device/connection、单位、时钟与资源，失败清零handle。设备0是
 * 明确兼容桶而非已验证硬件身份；mapped兼容桶也拥有非零逻辑connection，其他0桶为0。
 * source使用platform AmclInputSource，不能拿typed
 * event的source枚举替换。handle不回绕/复用，迟到提交不能认领后来同编号设备。
 */
typedef struct AmclLookStreamV1 {
    uint32_t size,source,kind,unit,clock,reserved;
    uint64_t device,connection;
    AmclLookResourceV1 resource;
} AmclLookStreamV1;
/** 完整兼容政策一次验证/应用；旧pending已经在输出单位中，不被新参数重新缩放。 */
typedef struct AmclLookPolicyV1 {
    uint32_t size,invertY;
    double sensitivity,smoothing,acceleration;
} AmclLookPolicyV1;
/**
 * producer只运输opaque prefix token和因果order。其数值/贡献/原资源存于唯一owner，
 * immutable记录存在固定容量预算；排队接受、consumer cache可用、callback/ADD及
 * 游戏实际读取是不同完成点，不能把prefix创建成功说成游戏已转动相机。
 */
typedef struct AmclLookPrefixV1 {
    uint32_t size,reserved;
    uint64_t token,order,gameSession;
    AmclLookResourceV1 resource;
} AmclLookPrefixV1;
/**
 * 本consumer一次执行票。current是按该consumer已应用前缀演化的cursor，delta仅含
 * 本次尚未应用部分；ABI边缘不得改target/activation或重新从future desired计算delta。
 */
typedef struct AmclLookEmissionV1 {
    uint32_t size,backend;
    uint64_t consumer,activation,target,ticket,prefix,order;
    double dx,dy,x,y;
} AmclLookEmissionV1;
/** 私有只读观测；cacheReady说明API数据可用，不声称Minecraft camera/attack已采纳。 */
typedef struct AmclLookSnapshotV1 {
    uint32_t size,backend;
    uint64_t consumer,gameSession,activation,target,availablePrefix;
    uint64_t accepted,cacheReady,callbackReturned,queueAccepted,legalPollReads;
    uint64_t stale,discarded,uncertain;
    double x,y;
} AmclLookSnapshotV1;
/**
 * table/ownerHost/PID在预线程module发布后不可变，所有借用遵守Core descriptor与原
 * 映像可执行地址检查。fork foreign PID在任何registry mutex/首次初始化之前拒绝。
 */
typedef struct AmclLookExecutionPortV1 {
    uint64_t magic;
    uint32_t version,size,pid,reserved;
    uint64_t ownerHost;
    int32_t (*verifyOwner)(uint64_t ownerHost);
    /** 同一实际启动身份绑定一次；准备不创建worker、不装游戏类、不假宣布consumer Ready。 */
    int32_t (*bindSession)(uint64_t gameSession);
    /** 只接受实际bridge模式发布，模式退休丢旧未交付量，不把它补进新world基准。 */
    int32_t (*publishMode)(uint64_t gameSession,uint64_t modeEpoch,uint32_t grabbed);
    /** 保存完整兼容政策，source=-1全来源；拒绝任何字段时不应用半份参数。 */
    int32_t (*applyPolicy)(int32_t source,const AmclLookPolicyV1* policy);
    int32_t (*openStream)(const AmclLookStreamV1* stream,uint64_t* handle);
    /** delta已经按该流单位给出；gyro不得再按dt积分，physical不得套映射gain。 */
    int32_t (*submitDelta)(uint64_t stream,double dx,double dy,uint64_t sampleNs);
    /** 先将旧速度推进到此样本边界，再安装新速度；重复时刻不双积分。 */
    int32_t (*submitVelocity)(uint64_t stream,double xPerSecond,double yPerSecond,uint64_t sampleNs);
    /** timer/事件只推进已有速率。长期间隔采用明确最多50ms政策，不补后台时间。 */
    int32_t (*advance)(uint64_t gameSession,uint64_t ownerMonotonicNs);
    /**
     * action/tick封已知前缀；flushPending只取已接受旧尾量，不外推未来sensor样本。
     * 与实际运输容量预留同批提交才可称接受，取消/Pressure不得发布假token。
     */
    int32_t (*sealPrefix)(uint64_t gameSession,uint64_t order,uint64_t ownerMonotonicNs,
        uint32_t flushPending,AmclLookPrefixV1* prefix);
    /** 仅源自己的未应用贡献退休；已写ABI的运动不逆向回滚，也不清同目标兄弟来源。 */
    int32_t (*retireStream)(uint64_t stream);
    /** producer运输确认或撤销原token；不得释放后来prefix，源退休仍可撤其尚未交付部分。 */
    int32_t (*retirePrefix)(uint64_t token);
    /**
     * 借用实际control consumer身份，snapshot验证其kind/session/activation/target；不
     * 再建控制owner。basis来自原ABI模式/合法warp基线，新target不继承历史look。
     */
    int32_t (*bindConsumer)(uint64_t controlConsumer,double basisX,double basisY);
    int32_t (*prepare)(uint64_t controlConsumer,uint64_t prefix,AmclLookEmissionV1* emission);
    int32_t (*claim)(const AmclLookEmissionV1* emission);
    int32_t (*validate)(const AmclLookEmissionV1* emission);
    /** completion沿control阶段名称，SDL queue只证明真实ADD，L2实际poll/next另观测。 */
    int32_t (*complete)(const AmclLookEmissionV1* emission,uint32_t completion);
    int32_t (*observePoll)(uint64_t controlConsumer,double actualX,double actualY);
    int32_t (*snapshot)(uint64_t controlConsumer,AmclLookSnapshotV1* snapshot);
    void (*closeConsumer)(uint64_t controlConsumer);
    /** 有界重试最终放弃仅本consumer的此token运输。必须先撤原票，不终结在途SDK调用。 */
    int32_t (*abandonPrefix)(uint64_t controlConsumer,uint64_t prefix);
    /**
     * typed relative原Core sequence关联一次接受时加工的独立physical prefix。
     * 不重新加工raw、不合并虚拟prefix；SDL沿原record device映射MouseID，公开raw字段不变。
     */
    int32_t (*physicalPrefix)(uint64_t coreSequence,uint64_t* prefix);
    /** ordered backend envelope的sequence是interactionOrder，必须显式选此索引，不能猜同值。 */
    int32_t (*physicalPrefixByOrder)(uint64_t interactionOrder,uint64_t* prefix);
    /** 实际look出口能力寿命，L2 Mouse独立于Keyboard；停止仅退出本backend，不关控制owner。 */
    int32_t (*setBackendActive)(uint32_t backend,uint32_t active);
} AmclLookExecutionPortV1;

AMCL_CONTROL_PUBLIC const AmclLookExecutionPortV1* amclLookExecutionGetPortV1(void);
AMCL_CONTROL_PUBLIC void amclLookExecutionPublishV1(void);
/** 无外部查询的producer事务口；真实队列先预留容量，再原子提交数学和不可变token。 */
AMCL_CONTROL_PUBLIC int32_t amclLookExecutionCommitV1(uint64_t stream,double dx,double dy,uint64_t sampleNs,
    uint64_t gameSession,uint64_t order,uint64_t ownerNs,uint32_t flush,AmclLookPrefixV1* output);
/** 明确旧processed兼容路径：不再次应用policy，仍与真实运输一批提交。 */
AMCL_CONTROL_PUBLIC int32_t amclLookExecutionCommitProcessedV1(uint64_t stream,double dx,double dy,
    uint64_t gameSession,uint64_t order,uint64_t ownerNs,AmclLookPrefixV1* output);
/** ring当前实际接收者按位冻结；取得ring记录不等于完成，终结或明确退休才解除保留。 */
AMCL_CONTROL_PUBLIC void amclLookExecutionSetRecipientsV1(uint64_t token,uint32_t backendMask);
/** 只读完整source政策代次；参数相同幂等不推进，0表示不可用/非法source。 */
AMCL_CONTROL_PUBLIC uint64_t amclLookPolicyEpochV1(int32_t source);
#ifdef __cplusplus
}
#endif
#endif
