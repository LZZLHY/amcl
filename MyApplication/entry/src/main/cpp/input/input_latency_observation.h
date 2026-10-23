/** 输入诊断私有值记录，公开事件/Core/control/look POD均不改变。
 * 采集实现仅诊断编译时存在；共同值声明供可选client读取。字段不是输入资格/策略，
 * 不记录文本、键码、坐标或用户配置。
 * 六时点同Native MONOTONIC，位图说明已知段；原SDK域与prefix贡献范围未证时明确unknown。
 */
#ifndef AMCL_INPUT_LATENCY_OBSERVATION_H
#define AMCL_INPUT_LATENCY_OBSERVATION_H
#include <stdint.h>
#if AMCL_INPUT_TRACE
#include "amcl_input_api.h" /* 仅owner声明复用可见性宏；client的POD/table不依赖Core API。 */
#endif
#ifdef __cplusplus
extern "C" {
#endif
enum { AMCL_ILAT_ENTRY=0, AMCL_ILAT_ACCEPT=1, AMCL_ILAT_ENQUEUE=2,
       AMCL_ILAT_READ=3, AMCL_ILAT_CACHE=4, AMCL_ILAT_RETURN=5,
       AMCL_ILAT_CALLBACK_BEGIN=6 }; /* BEGIN只标执行状态，不新增第七个时点。 */
/* NO_CALLBACK由真GLFW完成边缘证明；INCOMPLETE不能推断输入未接受或未回调。 */
enum { AMCL_ILAT_CALLBACK=1, AMCL_ILAT_NO_CALLBACK=2, AMCL_ILAT_RETIRED=3,
       AMCL_ILAT_REJECTED=4, AMCL_ILAT_INCOMPLETE=5, AMCL_ILAT_CALLBACK_RETIRED=6,
       AMCL_ILAT_RETIRED_WAIT_CALLBACK=7, AMCL_ILAT_SKIPPED=8 };
typedef struct AmclInputLatencyV1 {
    uint64_t id,session,stream,prefix,prefixOrder,ringSequence,ringOrder;
    uint64_t consumer,activation,target,ticket;
    uint64_t ns[6];
    uint32_t mask,outcome,contributions,clockFailures;
} AmclInputLatencyV1;
typedef struct AmclInputLatencyStatsV1 {
    uint64_t sampled,skipped,full,busy,missing,exported,clockFailures;
    uint32_t recordBytes,capacity,counterUncertain;
} AmclInputLatencyStatsV1;
/** 拉取型 ABI 的终点不能冒称 GLFW callback。沿同一152B输出记录用独立终态编码
 * 区分真实SDK ADD成功后返回adapter的回执、L2坐标view读回与无终点缓存；
 * SDL Native钟并非SDK内ADD语句的精确钟。原1–8及ILAT1格式保持原合同。 */
enum { AMCL_ILAT_SDL_QUEUE_COMMITTED=9, AMCL_ILAT_L2_POLL_VIEW_COPIED=10,
       AMCL_ILAT_SDL_CACHE_ONLY=11, AMCL_ILAT_L2_CACHE_UNOBSERVED=12,
       AMCL_ILAT_SDL_RETIRED=13, AMCL_ILAT_L2_RETIRED=14,
       AMCL_ILAT_SDL_INCOMPLETE=15, AMCL_ILAT_L2_INCOMPLETE=16,
       AMCL_ILAT_SDL_REJECTED=17, AMCL_ILAT_L2_REJECTED=18 };
enum { AMCL_ILAT_ENDPOINT_SDL_QUEUE_ADD=1, AMCL_ILAT_ENDPOINT_L2_POLL_VIEW=2 };
#define AMCL_INPUT_LATENCY_PORT_MAGIC_V2 UINT64_C(0x414d434c494c4132)
/** 私有可选表只借同一个已核look/Core映像。无独立owner/环境槽；client先核原
 * look/control ownerHost、PID和getter/全部函数的可执行地址，再冷借一次此表。
 * 声明在TRACE外供共用预编译client编译；OFF runtime不定义getter或采集实现。
 * note仅接CACHE/TERMINAL(ns[5])；finish无补钟，只结束原backend/原完整票诊断。
 */
typedef struct AmclInputLatencyPortV2 {
    uint64_t magic;
    uint32_t version,size,pid,reserved;
    uint64_t ownerHost;
    void (*note)(uint32_t stage,uint32_t backend,uint32_t endpoint,const AmclInputLatencyV1* original);
    void (*finish)(uint32_t backend,uint32_t endpoint,const AmclInputLatencyV1* original,uint32_t outcome);
} AmclInputLatencyPortV2;
#if AMCL_INPUT_TRACE
/** 下列入口只在唯一runtime内部调用；外部映像须经已校验的旧V1可选尾或新V2只读Port，不直调本地副本。 */
// runtime的既有amclInput*导出通配不能硬保证“内部”注释。只给这些诊断实现入口
// 显式hidden，阻止默认可见性ELF构建将它们作为可绕过bridge owner的动态ABI；不改变
// 整个target可见性，不影响其它现役C入口。MSVC没有dllexport的这些声明保持原内部链接消费。
#if defined(__GNUC__) || defined(__clang__)
#define AMCL_INPUT_LATENCY_INTERNAL __attribute__((visibility("hidden")))
#else
#define AMCL_INPUT_LATENCY_INTERNAL
#endif
AMCL_INPUT_LATENCY_INTERNAL uint64_t amclInputLatencyBeginV1(uint64_t stream);
AMCL_INPUT_LATENCY_INTERNAL void amclInputLatencyEndV1(uint64_t previous,int result);
AMCL_INPUT_LATENCY_INTERNAL uint64_t amclInputLatencyCurrentV1(void);
AMCL_INPUT_LATENCY_INTERNAL void amclInputLatencyAcceptV1(uint64_t prefix,uint64_t order,uint64_t session,uint32_t contributions);
AMCL_INPUT_LATENCY_INTERNAL void amclInputLatencyNoteV1(uint32_t stage,const AmclInputLatencyV1* original);
AMCL_INPUT_LATENCY_INTERNAL void amclInputLatencyFinishV1(uint64_t prefix,uint32_t outcome);
/** consumer终态必须携原缓存票；未知/冲突票只缺诊断，不借prefix/TLS/current结束另一票。 */
AMCL_INPUT_LATENCY_INTERNAL void amclInputLatencyFinishTicketV1(const AmclInputLatencyV1* original,uint32_t outcome);
/** 冻结InputPlan原成功点只登记诊断选择；失败/冲突不改变真实输入的准备结果。
 * configure须在该游戏输入生产前执行，同backend/session幂等，拒绝运行中换选择。 */
AMCL_INPUT_LATENCY_INTERNAL void amclInputLatencyConfigureBackendV2(uint32_t backend,uint64_t gameSession);
/** READ用于真neutral复制slot；CACHE/TERMINAL经已核可选client携原票返回同owner。 */
AMCL_INPUT_LATENCY_INTERNAL void amclInputLatencyNoteBackendV2(uint32_t stage,uint32_t backend,uint32_t endpoint,const AmclInputLatencyV1* original);
AMCL_INPUT_LATENCY_INTERNAL void amclInputLatencyFinishBackendV2(uint32_t backend,uint32_t endpoint,const AmclInputLatencyV1* original,uint32_t outcome);
/** try-drain只复制已有值，输出至调用方固定数组；不等待、不格式化、不推进输入。 */
AMCL_INPUT_LATENCY_INTERNAL uint32_t amclInputLatencyDrainV1(AmclInputLatencyV1* records,uint32_t capacity,AmclInputLatencyStatsV1* stats);
#undef AMCL_INPUT_LATENCY_INTERNAL
/** 非热路径固定格式：缺段输出“-”，SDK/贡献样本区间明确unknown；溢出返回0，不发截断记录。 */
AMCL_INPUT_PUBLIC uint32_t inputBridge_formatInputLatencyV1(const AmclInputLatencyV1* record,char* output,uint32_t capacity);
/** 真owner委派出口；旧/缺尾部只缺诊断。输出数组在同一PID地址空间中短期借用。 */
void inputBridge_noteInputLatencyV1(uint32_t stage,const AmclInputLatencyV1* original);
void inputBridge_finishInputLatencyV1(uint64_t prefix,uint32_t outcome);
/** 追加私有可选尾；旧owner缺此组只缺终态诊断，原输入/look能力不改变。 */
void inputBridge_finishInputLatencyTicketV1(const AmclInputLatencyV1* original,uint32_t outcome);
uint32_t inputBridge_drainInputLatencyV1(AmclInputLatencyV1* records,uint32_t capacity,AmclInputLatencyStatsV1* stats);
/** 仅TRACE runtime动态导出；旧/关闭提供者缺符号是诊断缺席，不是输入握手失败。 */
AMCL_INPUT_PUBLIC const AmclInputLatencyPortV2* inputBridge_getInputLatencyPortV2(void);
#ifdef AMCL_INPUT_LATENCY_HOST_TESTING
/** 仅宿主故障注入：真正hold同一诊断mutex、或关闭诊断clock，不改变生产输入时钟。 */
void amclInputLatencyTestHoldV1(int hold);
void amclInputLatencyTestClockV1(int failed);
uint32_t amclInputLatencyTestStorageV1(void);
/** 仅HOST在实际cache note退出诊断锁后暂停产品线程，用于派发前退休的竞争反例。 */
void amclInputLatencyTestCacheGateV1(void (*gate)(void));
#endif
#endif /* AMCL_INPUT_TRACE：共同POD/可选表声明始终可读，采集入口只在ON存在。 */
#ifdef __cplusplus
}
#endif
#endif
