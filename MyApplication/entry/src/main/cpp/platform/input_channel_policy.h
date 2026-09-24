// input_channel_policy.h — 物理输入的"单一所有者"策略层
//
// ============================ 为什么需要这一层 ============================
// 同一个物理动作在 HarmonyOS 上会同时出现在多条应用可见的通道里，而且**哪几条真的
// 有数据是设备与系统版本相关的**（真机证据见 docs/refactor/实体键鼠输入架构重构计划.md
// §16、§34、§35）：
//
//   左键边沿   API 24 平板：只有"鼠标合成触摸"这一条（ArkUI onMouse 不报左键）
//              API 26 手机：ArkUI onMouse **会**报左键，native XComponent 也报，
//                           合成触摸那条同时还在 → 三条并存
//   滚轮       API 24 平板：native AXIS 注册成功但 0 样本；ArkTS onAxisEvent 零调用；
//                           实际只以"合成手指滑动"到达
//              API 26 手机：native AXIS 正常工作，同时合成滑动**照旧**存在 → 两条并存
//
// 旧实现让每条通道各自判断"要不要发"，再用一把 per-button 的
// "先到者独占 + 500ms 空窗交接" 原子闩锁去仲裁。这个设计有两个**结构性**缺陷，
// 已经分别在真机上造成过用户可见的故障，不是调参能救的：
//
//   1. **赢家由到达时序决定，因此设备相关、状态相关、不可复现。**
//      同一份代码在 API 24 上镜像赢、在 API 26 上仍然镜像赢（合成触摸比 onMouse 早），
//      于是 API 26 上本该带窗口坐标的 ArkUI 点击被挤掉，表现为**菜单点不动**
//      （日志 `btnMirror=10 btnRejected=20`，恒定 1:2）。
//   2. **press 与 release 可以属于不同的所有者。**
//      500ms 空窗一到就换人，于是"按下由 A 发、抬起被 B 吞"完全可能。MC 侧的后果是
//      左键**永久卡在按下态**，表现为**按住左键失效 / 一直在挖**
//      （日志 `wfLeftTaken` 与 `btnRejected` 逐秒交替）。
//
// 本模块把仲裁从"时间竞争"改成"显式策略"：
//   · 每个 aspect（左键 / 滚轮）在任意时刻只有**一个**所有者；
//   · 所有者由 **静态优先级 × 本设备实测能力** 决定，与到达时序无关；
//   · 能力靠"这条通道是否真的送来过样本"发现，而不是靠 API 版本猜；
//   · **左键的所有者只在 DOWN 边沿重算**，一对 press/release 由同一个所有者送完，
//      所以"抬起被吞"在结构上不可能发生。
//
// 这一层刻意**不**碰右键/中键/侧键：它们从上线起就只有一条通道，没有竞争，
// 不需要为了对称性把工作正常的东西也改掉。
#ifndef AMCL_PLATFORM_INPUT_CHANNEL_POLICY_H
#define AMCL_PLATFORM_INPUT_CHANNEL_POLICY_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 一条应用可见的输入通道。优先级由 .cpp 里的表决定 —— 但 ⚠️ **数值不是随意的**：ArkTS 侧镜像了 ARKTS_AXIS=5 / AXIS_PAN=6（McGamePage.ets），插入或重排即静默出错，无门禁可抓（规范 §4.0 跨语言镜像表）。
typedef enum {
    AMCL_INPUT_CHANNEL_NONE = 0,

    // ---- 左键边沿的候选通道 ----
    // ArkUI `onMouse` 的 Press/Release。**首选**：它是 ArkUI 平面的事件，与
    // `windowX/windowY`、`rawDelta` 出自同一个 MouseEvent，菜单点击的坐标语义正确。
    AMCL_INPUT_CHANNEL_ARKUI_MOUSE = 1,
    // XComponent 的 `DispatchMouseEvent`。次选：只有绝对坐标，但边沿可靠。
    AMCL_INPUT_CHANNEL_NATIVE_MOUSE = 2,
    // 平台把鼠标左键合成出来的 TouchEvent。**末选**：它是"未适配鼠标的应用"兜底路径，
    // 元数据与真手指难分，且在 API 24 上是唯一可用的左键载体，所以不能删，只能降级。
    AMCL_INPUT_CHANNEL_TOUCH_MIRROR = 3,

    // ---- 滚轮的候选通道 ----
    // XComponent `RegisterUIInputEventCallback(AXIS)`。首选：拿到的是轴角度原值。
    AMCL_INPUT_CHANNEL_NATIVE_AXIS = 4,
    // ArkTS `onAxisEvent`。次选，语义等价但多一次跨语言往返。
    AMCL_INPUT_CHANNEL_ARKTS_AXIS = 5,
    // 轴驱动的 PanGesture（`BaseGestureEvent.axisVertical` 有值那种）。三选。
    //
    // ⚠️ 这里曾写「**在两台真机上都可用**，是 API 24 的实际载体」。**两句都被真机否证**
    // （2026-08-22，计划 §71）：API 24 平板上这条通道**零触发**（`AMCL_WHEEL pan update`
    // 零条），实际载体是下面的 `TOUCH_WHEEL`（`wheel owner=touchWheel`）；API 26 手机上它
    // 只在 native AXIS 首次登记之前当过约 1ms 的所有者，此后永久让位。
    // ⇒ **它在两台已知设备上都从不产出格数。** 排在 TOUCH_WHEEL 之前的理由因此只剩
    // "它比运动学指纹可靠"这条先验，而不是任何实测覆盖面。留着是因为它可能是第三种
    // 设备的唯一载体；调整优先级或删除都需要先有那种设备的证据。
    AMCL_INPUT_CHANNEL_AXIS_PAN = 6,
    // 合成触摸流里用运动学指纹认出来的滚轮。末选：最脆弱，只在以上全都没有时才用。
    AMCL_INPUT_CHANNEL_TOUCH_WHEEL = 7,
} AmclInputChannel;

// ---------------------------------------------------------------------------
// 能力发现
//
// 通道在**真的收到一个可用样本**时调用一次（重复调用无害，只有第一次有成本）。
// 必须在询问 accepts/begin 之前调用，否则该通道会因为"从未被观测到"而永远拿不到
// 所有权 —— 这正是"先注册后观测"的正确顺序。
// ---------------------------------------------------------------------------

// 记录某条通道送来过**左键**边沿。按 aspect 分开记：一台设备可能 native 报得了
// 右键却从不报左键（API 24 实测），用一个全局 "seen" 会把它误判成可用。
void amcl_input_policy_note_left_channel(AmclInputChannel channel);

// 记录某条通道送来过**滚轮**样本。
void amcl_input_policy_note_wheel_channel(AmclInputChannel channel);

// ---------------------------------------------------------------------------
// 滚轮：单一所有者
// ---------------------------------------------------------------------------

// 当前的滚轮所有者 = 已被观测到的通道里优先级最高的那一条。
AmclInputChannel amcl_input_policy_wheel_owner(void);

// `channel` 此刻是否有权产出 scroll。非所有者一律 false（静默让位，不是错误）。
//
// 用法固定为两步，顺序不能颠倒：
//     amcl_input_policy_note_wheel_channel(ch);
//     if (!amcl_input_policy_wheel_accepts(ch)) return;   // 让位
bool amcl_input_policy_wheel_accepts(AmclInputChannel channel);

// ---------------------------------------------------------------------------
// 左键：所有者 + press/release 配对
//
// 这两个函数是本模块存在的核心理由。规则：
//   · `begin` 只在 DOWN 边沿调用。它重算所有者；只有胜出的通道得到 true，
//     并且该通道被记为"这一次按下的持有者"。
//   · `end` 在 UP/CANCEL 边沿调用。它**只认持有者**，与当前优先级无关 ——
//     即使期间发现了优先级更高的通道，这一次的抬起也必须由按下的那一方送出。
//     这就是"抬起被吞导致左键卡住"在结构上不可能发生的原因。
//   · 未配对的 UP（例如生命周期复位之后到达的残包）返回 false 并被丢弃。
// ---------------------------------------------------------------------------

bool amcl_input_policy_left_begin(AmclInputChannel channel);
bool amcl_input_policy_left_end(AmclInputChannel channel);

// 左键当前是否处于"已由某条通道送出 DOWN、尚未送出 UP"的状态。
// 这是本进程唯一不依赖被转换通道的左键按住状态，供分桶取证使用。
bool amcl_input_policy_left_held(void);

// 左键当前的**优先级所有者**（按已发现的能力位图现算）。无任何通道被观测到时返回 `NONE`。
//
// 存在理由（2026-09-01）：滚轮那一侧一直有 `amcl_input_policy_wheel_owner()`，左键这一侧
// 只有内部的 `LeftOwnerLocked()` —— 于是 `left_begin` 返回 false 时调用方**无法区分**
// 「我不是所有者」与「我是所有者但已有一次按下在飞行中（同通道重复 DOWN）」。
// 那两个成因的排查方向完全不同（前者查优先级表与能力发现，后者查平台重发/合成流的
// DOWN/MOVE/DOWN 序列），而它们此前共用同一个 `btnYield` 计数。
// ⇒ AGENTS.md §二.9：一个错误码把 N 个成因合并成一个值，代价不是"少一点信息"，
//    而是到了真机就查不下去。
//
// ⚠️ **它是快照，不是锁。** 与 `left_begin` 之间存在一个窗口（另一条更高优先级的通道可能
// 恰好在两次调用之间首次 `note`）。这只影响**诊断归属**，不影响功能：真正的准入判定始终
// 由 `left_begin` 自己那次原子操作做出。能力位图单调只增，所以窗口内 owner 只会往更高
// 优先级变，归属最多偏向"非所有者"那一桶 —— 而那正是保守方向。
AmclInputChannel amcl_input_policy_left_owner(void);

// 生命周期复位（surface 换代、失焦、取消全部输入）。清空 in-flight 的按下持有者，
// **但保留已发现的能力** —— 设备能力不会因为换了个 surface 就变化，重新发现只会
// 让"第一次点击又被末选通道抢走"这个 warm-up 问题反复出现。
void amcl_input_policy_reset_pairing(void);

// 把当前策略状态**一次性**写一行 hilog（`AMCL_INPOLICY left=.. wheel=.. leftHeld=..`）。
//
// ⚠️ **当前没有生产调用方**（2026-08-20 全仓核实，只有定义、本声明与 host test）。
// 这一行原先写的是「只在所有者发生变化时调用，稳态零成本」——那描述了一条**没有人遵守
// 的纪律**。所有者变化时真正会打日志的是本模块内部的 `LogOwnerChange`，它的格式是
// 两行独立的 `AMCL_INPOLICY left owner=..` / `AMCL_INPOLICY wheel owner=..`
// （真机已确认出现，见计划文档 §51/§52）。
//
// 因此判读时注意区分两种格式：带 `owner=` 的是**自动**打的、真的存在；
// 本函数那种 `left=.. wheel=..` 单行格式在产品里**永远不会出现**。
// 计划文档 §35.7 曾按后者写过判读指令，那条指令是错的。
// 保留本函数是因为它零成本、且在需要"当场取一次快照"时（例如将来接到某个诊断入口）
// 正是要用的东西；但不要再声称有人在调它。
void amcl_input_policy_log_state(void);

#ifdef __cplusplus
}
#endif

#endif  // AMCL_PLATFORM_INPUT_CHANNEL_POLICY_H
