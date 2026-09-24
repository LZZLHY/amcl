// input_invariants.h — 输入子系统的不变量自检
//
// ============================ 为什么需要它 ============================
//
// 现有普查（input_channel_census.h）是**原始计数**：每条通道被调用了多少次。
// 它能回答"这条通道来没来"，这一点已经多次派上用场。但它回答不了"账对不对"，
// 而本项目二十多轮里遇到的故障**大多是关系失衡而不是通道缺失**：
//
//   · 抬起拿走了别端的 owner   → 两个计数都正常，只是归属互换
//   · 某个 look 生产者没申报端 → look 总数正常，只是各端之和少了一块
//   · 滚轮绕过按端入口         → scrollOut 正常，端计数对不上
//   · 复位之后仍有持有记录     → 复位计数正常，但表没空
//
// 这些都是**静默**的：不崩、不报错，只在用户某天报告"卡键 / 方向反了"时才暴露，
// 然后要花一整轮回溯。本模块把这些关系写成可判定的不变量，破坏时立刻打一行 error。
//
// ============================ 设计约束 ============================
//
// 求值器是**纯函数**：入参是一份快照，出参是被破坏的不变量位掩码。这样它可以在主机侧
// 被完整测试，而"怎么采样、什么时候打日志"这些不纯的部分留在调用方（touch_input.cpp）。
// 不要把 hilog 或全局状态读取放进本 TU。
#ifndef AMCL_PLATFORM_INPUT_INVARIANTS_H
#define AMCL_PLATFORM_INPUT_INVARIANTS_H

#include <stdint.h>

#include "input_source.h"

#ifdef __cplusplus
extern "C" {
#endif

// 一次采样。所有字段都是**累计值**（自进程启动起单调不减），除了 heldLive 是瞬时值。
typedef struct {
    // census 的 LookApplied：applyLookDelta 这个唯一漏斗被调用的总次数。
    unsigned lookTotal;
    // 按端的 look 计数（amcl_input_source_look_count）。
    unsigned lookPerSource[AMCL_INPUT_SOURCE_COUNT];
    // census 的 ScrollDelivered：进入 bridge ring 的 scroll 总格数。
    unsigned scrollTotal;
    // 按端的 scroll 计数（amcl_input_source_scroll_count）。
    unsigned scrollPerSource[AMCL_INPUT_SOURCE_COUNT];
    // external 持有表的瞬时存活数与累计登记/释放数（按端）。
    unsigned heldLive[AMCL_INPUT_SOURCE_COUNT];
    unsigned heldAcquired[AMCL_INPUT_SOURCE_COUNT];
    unsigned heldReleased[AMCL_INPUT_SOURCE_COUNT];

    // 六层持有关系的另外两层（2026-09-01）。上面三个数组只描述第 1b 层，
    // 而第 1a 层与第 2 层此前在产品里一个数都读不出来 —— 因果见计划 §107.1。
    unsigned physicalIdentityLive;   // 1a：LegacyPhysicalEdgeRouter 的持有身份数，瞬时值
    unsigned ledgerOwnerLive;        // 2：至少持有一个输出的 owner 数，瞬时值
    unsigned ledgerOutputLive;       // 2：MC 侧当前按下的控件数，瞬时值
    // 1b 的幽灵特征：同一 `(output, source)` 上的最大记录数（1 = 正常）。
    // ⚠️ **刻意不参与任何不变量位**，只入日志（理由见计划 §107.3，并有断言钉住这个决定）。
    unsigned maxSameSourceHeld;
} AmclInputInvariantSnapshot;

// look 总数必须等于各端之和。不等 ⇒ 有 look 生产者没经过按端计数。
#define AMCL_INV_LOOK_SUM        (1u << 0)
// scroll 总数必须等于各端之和。不等 ⇒ 有滚轮生产者绕过了按端入口。
#define AMCL_INV_SCROLL_SUM      (1u << 1)
// 每端：登记数 - 释放数 == 当前存活数。不等 ⇒ 持有记账漏了一条路径。
#define AMCL_INV_HELD_BALANCE    (1u << 2)
// `NONE` 栏必须恒为 0。非零 ⇒ 有调用点没申报端身份（平台手势有自己的栏）。
#define AMCL_INV_NO_UNTAGGED     (1u << 3)
// 平台手势不该出现在 look 路径上（它只产生按键 tap）。
#define AMCL_INV_GESTURE_NO_LOOK (1u << 4)
// 上游任一 owner 域（1a 物理身份 / 1b 端身份）非空 ⇒ ledger 必须非空。
// ⚠️ 刻意是**蕴含式而不是等式**：第 1c 层 schema owner 不在本快照里（在采样的锁序之外），
// 而它只会让 ledger 更多 ⇒ 只有这个方向结构性无误报，等式必然误报。
// ⚠️ 它抓的是规范 §3.3 的**镜像**（ledger 空了而上游还持有），**不是 §3.3 本体**
// （本体的账目全部自洽，观测面是 `maxSameSourceHeld`）。因果见计划 §107.2。
#define AMCL_INV_LEDGER_COVERS_OWNERS (1u << 5)

#define AMCL_INV_ALL_BITS        0x3Fu

// 返回被破坏的不变量位掩码。0 = 全部成立。`snapshot` 为 NULL 时返回 0（无法判定，
// 不报警 —— 报一个无法定位的警报比不报更糟）。
uint32_t amcl_input_invariants_evaluate(
    const AmclInputInvariantSnapshot* snapshot);

// 单个位的稳定短名，用于日志。未知位返回 "?"。
const char* amcl_input_invariant_name(uint32_t bit);

// ---------------------------------------------------------------------------
// 上报滞回
//
// 求值器给出的是"这一瞬间账目是否平衡"，但**采样本身不是原子的**：
// `census::Bump(LookApplied)` 与 `amcl_input_source_note_look()` 是两次独立的原子自增，
// 中间存在一个窗口；而 `Bump` 每秒会顺手执行一次 `Flush()`（几十路 snprintf + 一次
// hilog），把那个窗口从纳秒级拉到微秒级。采样跑在 ArkUI 主线程、look 跑在 XComponent
// 回调线程，是真并发 —— 于是"总数已加、端计数未加"会被采到，产生**瞬时假破坏**。
//
// 滤掉它的依据是这些计数器的性质：全部**累计且单调不减**，所以一条真实的破坏一旦发生就
// **永久成立**，下一次采样必然还在；而瞬时失衡会自愈。因此"连续两次观测都成立"既不会
// 漏掉真实破坏，也能完全消掉采样窗口造成的误报。代价只是发现延迟从一个 tick 变成两个。
//
// 为什么必须消掉误报而不是容忍：AMCL_INVARIANT 一旦出现过假阳性，下一轮判读就会把它当
// 噪声忽略，这套机制的全部价值随即归零 —— "计数器不可信比没有计数器更糟"这条教训本项目
// 已经付过一次学费。
//
// 本结构与函数是纯的（无锁、无全局），调用方持有状态并负责串行化。
// ---------------------------------------------------------------------------
typedef struct {
    // 上一次观测到的破坏位（未必已上报）。
    uint32_t lastObserved;
    // 已经上报过的破坏位。同一条破坏只报一次：它描述的是持续状态，不是一次性事件。
    uint32_t reported;
} AmclInputInvariantHysteresis;

// 输入本次观测结果，返回**本次应当上报**的位（0 = 不报）。
// 会就地更新 `state`。`state` 为 NULL 时返回 0。
uint32_t amcl_input_invariants_confirm(AmclInputInvariantHysteresis* state,
                                      uint32_t observed);

#ifdef __cplusplus
}
#endif

#endif  // AMCL_PLATFORM_INPUT_INVARIANTS_H
