// window_event_filter.h — 窗口级多模输入事件过滤器（路径 B）
//
// ============================ 为什么需要这个模块 ============================
// 系统对"未适配鼠标的应用"提供兜底方案：把**鼠标左键的点击与滑动、以及轴（滚轮）
// 事件**额外合成为触摸事件下发。官方指南同时明确这是**并行合成第二路**，而不是把
// 鼠标事件那一路关掉（"按下鼠标左键点击、滑动，既可以接收到 Touch 事件，也可以接收到
// 鼠标事件"）。
//
// 这条兜底在本项目里造成两个无法用 ArkUI 属性消除的症状（真机证据见
// docs/refactor/实体键鼠输入架构重构计划.md §十八~§二十二）：
//   1. 滚轮被当成"手指向下滑"，落在 XComponent 空白区被解释成视角/摇杆；
//   2. 按住左键拖动时位移只以合成触摸包存在，而合成包的坐标就是被窗口夹取的指针
//      位置，于是拖动视角**有边界**。
// `easyGo.mouse2TouchEventMode: disabled` 是官方开关，但本机 API 24 未解析它。
//
// 本模块走的是另一条正式通道：`oh_window_event_filter.h` 的窗口级事件过滤器。
// 它的过滤点在**窗口层、ArkUI 组件分发之前**，回调返回 true 即"该事件不再向下分发"。
// 于是我们可以在合成触摸包进入 ArkUI/XComponent **之前**把它掐掉，让游戏内只剩
// 一条鼠标通道（ArkTS onMouse + rawDeltaX/Y，官方定义的硬件相对位移，无界）。
//
// 接口事实（已在本机 API 24 SDK 头逐字核对，避免重犯 §21.4 的 ABI 复刻错误）：
//   OH_NativeWindowManager_RegisterTouchEventFilter(int32_t, bool(*)(Input_TouchEvent*))
//   OH_NativeWindowManager_RegisterMouseEventFilter(int32_t, bool(*)(Input_MouseEvent*))
//     · @since 15，头文件**无 @permission**；
//     · @syscap SystemCapability.Window.SessionManager，libnative_window_manager.so；
//     · 返回 WindowManager_ErrorCode：OK=0 / INVAILD_WINDOW_ID=1000 / SERVICE_ERROR=2000；
//     · 一个 windowId 只允许一个回调，后注册覆盖先注册。
//   OH_Input_GetTouchEventToolType(const Input_TouchEvent*) -> Input_TouchEventToolType
//     · @since 24，**直接返回枚举值**（不是 out 参数 + Input_Result）；
//     · TOOL_TYPE_FINGER=0 … TOOL_TYPE_MOUSE=6，TOOL_TYPE_LENS=7。
// 符号一律 dlsym 解析：compatibleSdkVersion 低于 15/24 的设备上直接报告 unsupported，
// 不产生装载期依赖，也不会让 libentry.so 装载失败。
//
// ============================ 三条硬性安全边界 ============================
// 1. **只在游戏内（光标已锁）过滤。** 菜单态必须放行。
//    ⚠️ 这条的**理由**曾写作「本机左键从不出现在 onMouse（28/28 边沿全是右键掩码），
//    菜单里的左键点击只以合成触摸包存在」。那是 API 24 平板的实测，**在 API 26 手机上
//    已被证伪**：那里 ArkUI onMouse 确实报左键，`input_channel_policy` 也把它选为左键
//    aspect 的所有者（真机 `AMCL_INPOLICY left owner=arkuiMouse`，§51.3 ④）。
//    结论（菜单态放行）仍然正确，但依据要换成设备无关的那一条：**过滤是为游戏内的
//    相对视角服务的，菜单态需要的是绝对坐标点击，两者目标不同**；而在只有合成触摸
//    这一条载体的设备上无条件过滤会让玩家点不了任何菜单 —— 比原症状严重得多。
//    不要再把那个 28/28 的数字当成跨设备的硬事实。
// 2. **只过滤 tool == TOOL_TYPE_MOUSE 的包。** toolType getter 解析失败时永不过滤
//    （fail-closed 到"不改变现状"），因为分类不了就无法保证不误吞真手指。
// 3. **自愈看门狗。** "掐掉合成 touch 之后 onMouse 会恢复投递"是官方从未承诺的推断。
//    若连续若干次左键拖动都既没有合成包（被我们过滤）又没有 ArkTS 相对样本，说明
//    onMouse 并未恢复，此时**自动停止过滤**并把通道还给触摸镜像，宁可回到"有界但
//    可用"，也不留下"完全拖不动"。降级只发生在本进程内，并打一条醒目日志。
#ifndef AMCL_PLATFORM_WINDOW_EVENT_FILTER_H
#define AMCL_PLATFORM_WINDOW_EVENT_FILTER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    // 过滤器已安装（或已处于目标状态）。
    AMCL_WINDOW_INPUT_FILTER_OK = 0,
    // 已经是请求的状态，未触达窗口管理器。
    AMCL_WINDOW_INPUT_FILTER_UNCHANGED = 1,
    // 注册符号缺失（API < 15），本设备无此能力。
    AMCL_WINDOW_INPUT_FILTER_UNSUPPORTED = 2,
    // windowId 不是可用身份。
    AMCL_WINDOW_INPUT_FILTER_INVALID_ARGUMENT = 3,
    // 窗口管理器拒绝；具体平台码见 hilog。
    AMCL_WINDOW_INPUT_FILTER_PLATFORM_ERROR = 4,
    // 注册符号可用，但 OH_Input_GetTouchEventToolType 缺失（API < 24）。
    // 此时**只安装观测探针、永不过滤**：分类不了就不能保证不误吞真手指。
    AMCL_WINDOW_INPUT_FILTER_NO_TOOLTYPE = 5,
} AmclWindowInputFilterResult;

// 安装窗口级过滤器。幂等：同一 windowId 重复调用返回 UNCHANGED。
//
// 同时安装两个回调：
//   · touch filter —— 游戏内对 tool==MOUSE 的合成包返回 true（掐断）；
//   · mouse filter —— **永远返回 false**，只做"鼠标事件是否到过窗口层"的可见性探针
//     以及"窗口层收到过哪些 action 取值"的一次性取证。它是零风险的。
//
// ⚠️ 鼠标回调曾经额外做过两件"接管"（取走左键 DOWN/UP、取走轴事件），
// **两者都已按真机证据删除**，理由与故障表现见 .cpp 中 MouseEventFilter 上方的注释。
// 左键与滚轮的通道选择现在统一由 input_channel_policy 决定，本模块不参与。
AmclWindowInputFilterResult amcl_window_input_filter_install(int32_t windowId);

// 注销过滤器并清空看门狗状态。页面销毁/退出游戏必须调用，否则回调会在窗口之后
// 继续被系统持有。
AmclWindowInputFilterResult amcl_window_input_filter_uninstall(int32_t windowId);

// 本设备/系统版本是否解析到了注册符号。
bool amcl_window_input_filter_supported(void);

// 物理左键当前是否按住。
//
// 实现已转发到 input_channel_policy：那里按 press/release **配对**维护按住状态，
// 与具体哪条通道送出边沿无关，因此换设备/换系统版本都不会失真。
// 用途是把其它通道的样本按"左键按住 / 未按住"分桶取证 —— 例如 native XComponent
// mouse MOVE 在两种状态下的投递率差异，正是"平台在 Window→ArkUI 之间截断鼠标 MOVE"
// 的最小复现证据。
//
// 可从任意线程调用（内部只读一个原子量）。
bool amcl_window_filter_left_held(void);

// 当前是否真的处于"会掐断合成包"的状态。
// 要求：已安装 + toolType 可用 + 未被看门狗降级。它**不**包含光标锁条件，
// 因为那是逐事件判定的（菜单态放行）。
bool amcl_window_input_filter_active(void);

#ifdef __cplusplus
}
#endif

#endif  // AMCL_PLATFORM_WINDOW_EVENT_FILTER_H
