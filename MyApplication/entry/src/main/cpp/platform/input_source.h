// input_source.h — 输入端（control source）：本项目输入架构的第一级概念
//
// ============================ 两条正交的轴 ============================
// 本项目有三个**平级**的控制端，它们是并列的一等公民，不是"触摸链上挂了几个附件"：
//
//   1. 触控虚拟按键端（Control Schema）：屏幕上的摇杆 / 按钮 / 滚轮条 / 物品栏，手指驱动。
//   2. 手柄端（Gamepad）：按钮 / 摇杆 / 扳机 / HAT。
//   3. 物理键鼠端（Physical KB+M）：物理键盘 + 物理鼠标。
//
// 与之**正交**的第二条轴是"通道"（AmclInputChannel，见 input_channel_policy.h）：
// 同一个输入端内部，平台可能把**同一个物理动作**沿多条路径重复投递
// （例如物理左键同时出现在 ArkUI onMouse、XComponent native mouse、以及平台合成的
//  TouchEvent 上）。
//
// 两条轴的处置方式**完全相反**，把它们混在一起是本项目历史上多起故障的共同根源：
//
//   · 端之间**不仲裁**。三端可以同时产出，那是玩家真的同时在用两种设备。
//     "手指在虚拟滚轮条上滑" 与 "另一只手滚物理滚轮" 都切快捷栏，这是正确行为，
//     不是重复投递。
//   · 端内部的通道**必须仲裁**，且同一时刻只能有一条产出。否则一个物理动作会被算两次，
//     两条通道符号相反时甚至互相抵消（真机实测：一秒内 `nativeAxisScroll=9` 而
//     `scrollOut=19`，多出来的十格来自另一条通道，用户表现为"滚轮方向反了，
//     快速滚动又时好时坏"）。
//
// 因此本头文件只负责**端**这条轴：给端一个稳定身份、一处量纲归一的接缝、
// 以及按端划分的复位边界。通道仲裁仍然在 input_channel_policy 里。
//
// ============================ 为什么端必须成为显式概念 ============================
// 在引入本文件之前，"端"只存在于四套彼此不相关的影子里，没有一套是权威的：
//
//   · `InputModeManager.activeMode`（ArkTS，`'touch'|'mouseKbd'|'gamepad'`）：
//     看起来正是三端枚举，但 `notify('touch')` 全仓没有调用点，
//     而它唯一的读取方 `GameControls.currentInputMode` 又从不被读 —— 空抽象。
//     ⚠️ 这三个标识符**都已删除**，不要按名字去找：`activeMode` 与
//     `currentInputMode` 在 §45.8 删掉，承载它们的 `InputModeManager` 整个类
//     在 §50 / 提案 D2 拆成三个（见 `gamecontrol/Index.ets` 的墓碑注释）。
//     留在这里是因为它是"为什么端必须成为显式概念"的第一条论据。
//   · `DeviceCapability`：回答"现在物理上接了什么"，不是"哪个端在产出"。
//   · `AmclInputChannel`：只覆盖物理键鼠的左键与滚轮，不含另两端。
//   · census `Channel`：纯诊断，不参与决策。
//   · typed ABI 的 `header.source` 定义了 TOUCH/VIRTUAL/SYNTHETIC，
//     但只有 SYNTHETIC 有生产者。
//
// 后果是下游漏斗**全都不知道来源**：`applyLookDelta(dx,dy)` 同时接三端的位移却共用
// 一条灵敏度；`routerKey` 的 held FIFO 被手柄、菜单按钮、IME、抽屉按钮混用，
// RELEASE 取队首而不匹配生产者。本文件的作用就是把"端"从注释里提升成类型。
#ifndef AMCL_PLATFORM_INPUT_SOURCE_H
#define AMCL_PLATFORM_INPUT_SOURCE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 一个控制端。数值会进日志，但**不要**把它当位掩码用：端不是集合语义。
typedef enum {
    // 未标注来源。**这是一个告警值**：任何非零的 `untagged` 计数都意味着有调用点
    // 还没申报端身份，应当被追查。只允许出现在"还没接线"的过渡调用点上。
    //
    // ⚠️ 历史坑（2026-08-20 修）：`NONE` 曾同时承担两种含义 —— 上面这个告警语义，
    // 以及"系统返回键 / 返回手势"这种**正当的**平台手势来源。两者混在一栏里之后，
    // `untagged` 就再也无法当告警用（分不清"有人漏改"和"用户按了返回键"）。
    // 平台手势现在有自己的 `AMCL_INPUT_SOURCE_PLATFORM_GESTURE`。
    AMCL_INPUT_SOURCE_NONE = 0,
    // 触控虚拟按键端：屏幕控件表（AmclCtrlEntry）+ C 层解释器
    // （handleSchemaGrabbedTouch）。驱动者是真实手指。
    AMCL_INPUT_SOURCE_TOUCH_CONTROLS = 1,
    // 手柄端。状态机目前整体在 ArkTS（GamepadManager），native 只见到它的输出。
    AMCL_INPUT_SOURCE_GAMEPAD = 2,
    // 物理键鼠端：物理键盘 + 物理鼠标（含滚轮）。
    AMCL_INPUT_SOURCE_PHYSICAL_KBM = 3,
    // 平台手势：系统返回键 / 返回手势合成的 ESC 等。
    //
    // 它**不是第四个"端"** —— 没有配置、没有量纲系数、不参与 look 漏斗、不参与
    // 按端复位遍历（它产出的是 press/release 紧邻的瞬时 tap，不跨帧持有）。
    // 它存在的唯一目的是让"这条边沿有正当来源"可表达，从而把 `NONE` 还原成纯告警值。
    AMCL_INPUT_SOURCE_PLATFORM_GESTURE = 4,
} AmclInputSource;

// 端计数数组的尺寸。新增枚举值时只需改这里与 amcl_input_source_name。
#define AMCL_INPUT_SOURCE_COUNT 5

// 端的稳定短名，用于日志与普查。绝不返回 nullptr。
const char* amcl_input_source_name(AmclInputSource source);

// ---------------------------------------------------------------------------
// 视角量纲归一（本文件存在的第二个理由）
//
// `applyLookDelta` 是三端共用的唯一视角漏斗，但三端喂进去的**量纲互不相同**：
//
//   触控端    : XComponent 触点坐标差分，单位 = surface 物理 px
//   物理键鼠端: ArkUI `MouseEvent.rawDeltaX/Y`。官方明确它是「鼠标硬件的原始移动
//               数据……并非屏幕的物理/逻辑像素」，且 **API 26.0.0 之前上报的是原始值
//               缩小了 X 倍（X = 系统显示大小比例）**，26.0.0 起为原始值。
//   手柄端    : 摇杆归一化量 × RIGHT_STICK_LOOK_GAIN，无物理长度含义。
//
// 三者共用同一条 `s_lookSensitivity` / 加速曲线 / 守恒 backlog，于是任何一端调优
// 都会破坏另外两端 —— 这是一个结构性缺陷，不是手感问题。
//
// 本函数是修这件事的**接缝**：每个端在进入公共漏斗之前先乘上自己的归一系数。
//
// ⚠️ 当前三端一律返回 1.0，即**行为与引入本文件之前逐位相同**。这是刻意的：
// 现有手感是用户已经验收过的，在没有真机标定数据之前改动系数只会把"架构调整"
// 和"手感回归"混成一次无法判读的变更。标定方法与官方给的换算手段（
// `UIContext.px2vp(rawDelta)` 配合 `getWindowDensityInfo()`）记在
// docs/refactor/实体键鼠输入架构重构计划.md 的优化清单里。
// ---------------------------------------------------------------------------
double amcl_input_source_look_scale(AmclInputSource source);

// ---------------------------------------------------------------------------
// 按端的**平滑系数**（本文件存在的第三个理由，2026-08-22 / 计划 §78）
//
// 与上面的量纲系数是同一个问题的第二个面：四件套（灵敏度 / Y 倒置 / 平滑 / 加速）
// 此前也是三端共享的**一份**全局值，而 `s_lookSmoothAlpha` 的默认 0.6 来自
// 虚拟按键布局（`ControlLayout.ets` 的 `DEFAULT_LOOK_SMOOTHING`）——
// 它要抑制的是**手指抖动**与触点量化噪声。
//
// 物理鼠标不抖：`rawDelta` 是硬件计数器。对它做一阶低通只买到相位滞后
// （τ = -16.7/ln(1-0.6) ≈ **18.2 ms**），换不到任何东西；而 backlog 留下的
// (1-alpha) 尾量还要等 idle worker 的 **20 ms** 才发出（物理鼠标没有 UP 边沿，
// 走不到 `flushLookPending`）。用户报的"视角有延迟感"就是这两条，量化见计划 §77.1。
//
// ⚠️ **本函数是"按端配置模型"（提案 C2）的第一片，不是它的全部。**
// 现在只做 native 侧解析：滑条值仍然只有一份，KBM 端**忽略**它。
// 真正的按端可配置（三端各存一份、带迁移与 UI）仍未做。
//
// ⚠️ **共享 backlog 的已知交互**：`s_lookPendingDx/Dy` 是三端共用的**一份**标量余量。
// 于是当触控端刚留下余量、紧接着一个 KBM 样本到达时，KBM 的 alpha=1.0 会把那份
// 触控余量一起冲出去（比它自己的节奏早约 18ms）。**这是安全的** ——
// 位移守恒（Σoutput == Σinput）不变、不会重复计数，只是到达时间提前。
// 要彻底分开需要三份 backlog + 给 `flushLookPending` 加端参数，那是 C2 的后续。
//
// @param globalAlpha 用户滑条的当前值（触控端语义），调用方从 atomic 读一次快照。
// @return 该端应当使用的 alpha。1.0 = 不平滑（立即输出，backlog 恒为 0）。
// ---------------------------------------------------------------------------
double amcl_input_source_look_smoothing(AmclInputSource source,
                                        double globalAlpha);

// ---------------------------------------------------------------------------
// 按端的视角计数
//
// census 的 look 枚举是按**通道**切的（LookFromSchemaTouch / LookFromArktsMotion /
// LookFromGamepad），而通道与端并非一一对应 —— 触控端的 ArkTS
// dragLook 曾被记进 `lookPad`，于是"手柄 look 计数"实际是"手柄 + 触控 dragLook"。
// 这个函数补上**端**这条轴上的计数，两条轴各记各的，交叉比对才能定位归属错误。
// ---------------------------------------------------------------------------
void amcl_input_source_note_look(AmclInputSource source);

// 按端的滚轮计数。滚轮没有持续按下态，所以它不进 owner 域；但"这一格是手柄 L1 切的、
// 还是屏幕滚轮条滑的、还是物理滚轮滚的"必须可分，否则"滚轮方向反了"这类问题又要靠猜。
void amcl_input_source_note_scroll(AmclInputSource source);

// ---------------------------------------------------------------------------
// 按端划分的复位边界
//
// 现状（已测绘）：`ohos_cancel_all_input` 覆盖 ledger、external held、物理 owner、
// schema runtime、finger registry、look backlog —— 但**完全不触碰手柄端在 ArkTS 里的
// 内部状态**（pressedButtons / activeMoveKeys / triggerDown）。而 `onPageHide`、
// `GameAbility.onBackground`、`EntryAbility.onBackground` 这三个边界只调 native cancel，
// 于是那段窗口内 ArkTS 手柄状态与 native ledger 失步：native 已归零，ArkTS 仍认为按着，
// 随后的 UP 会发出一个"已经被释放过"的 RELEASE。
//
// 本函数记录"某个端刚刚被复位过"，供诊断读取；它**不代替**各端自己的释放动作，
// 目的是让"哪个端漏了复位"在日志里可见，而不是继续靠读三个文件互相比对。
//
// 手柄端的生产者是 ArkTS 侧的 InputSourceRegistry（经 NAPI `noteSourceReset`）——
// native 的 `ohos_cancel_all_input` 触达不到那个状态机，所以它只为自己覆盖到的两端记账。
// 三端计数**必须**都有生产者，否则这条日志就退化成"两端可读、一端恒零"，
// 而恒零无法区分"没漏"与"没记"。
// ---------------------------------------------------------------------------
void amcl_input_source_note_reset(AmclInputSource source);

// 把各端的复位 / 视角 / 滚轮计数打成一行 hilog。生命周期 cancel 时调用一次。
void amcl_input_source_log_reset_state(void);

// ---------------------------------------------------------------------------
// 计数读取口
//
// 供不变量自检（input_invariants.h）交叉核对用：例如 census 的 `look` 总数必须等于
// 各端 look 之和，不等就说明有 look 生产者没申报端身份。计数器本身只做诊断，
// 所以这里返回快照值，不保证与另一个计数器的读取严格同时。
// ---------------------------------------------------------------------------
unsigned amcl_input_source_reset_count(AmclInputSource source);
unsigned amcl_input_source_look_count(AmclInputSource source);
unsigned amcl_input_source_scroll_count(AmclInputSource source);

#ifdef __cplusplus
}
#endif

#endif  // AMCL_PLATFORM_INPUT_SOURCE_H
