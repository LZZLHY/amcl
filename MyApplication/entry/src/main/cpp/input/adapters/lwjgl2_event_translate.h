#ifndef AMCL_LWJGL2_EVENT_TRANSLATE_H
#define AMCL_LWJGL2_EVENT_TRANSLATE_H

#include "backend_input_bridge.h"

// LWJGL2 后端的出线翻译：一个中立 typed 事件 → 零或一个 LWJGL2 线上事件。
//
// ⚠️ **纯函数、无全局状态、C ABI**，三条都是刻意的：
//   · 纯 —— 它才能进 host 构建并被断言。宿主那边真正的调用点在
//     `glfw/input_bridge_ohos.c`，那个 TU 有 hilog/pthread/atomic，拉不进 host
//     （与 §91 把 `StepPhysicalWheel` 抽出来完全同一手法）。
//   · 无状态 —— 滚轮余量由调用方持有并**无条件写回**，`kSkip` 也一样。把写回变成有条件的
//     就给了调用点一个可以做错的选择，而两条滚轮平面此前正是在那里永久分叉的（§91.2）。
//   · C ABI —— 调用点是 C。
#ifdef __cplusplus
extern "C" {
#endif

// **编码判别靠 type 号**：2xxx 段表示 `i1` 已经是 LWJGL2（DirectInput）编码，1xxx 段仍是
// GLFW 编码。刻意不复用同一组 type 号再加一个"编码"字段 —— 两个方向都必须自动退化正确：
// 老宿主永不发 2xxx；老 Java 收到 2xxx 落进 switch 的 default（丢弃，**不会错译**）。
// 加字段做不到后一半：老 Java 读不到那个字段，会把 DirectInput 码当 GLFW 码再翻一遍，
// 那是"看起来在工作但每个键都错"的形状，比丢事件难查得多。
#define AMCL_LWJGL2_WIRE_KEY_TYPED 2005
#define AMCL_LWJGL2_WIRE_MOUSE_BUTTON_TYPED 2006
#define AMCL_LWJGL2_WIRE_SCROLL_TYPED 2007
#define AMCL_LWJGL2_WIRE_RESET_TYPED 2009

// LWJGL2 的 action 编码（宿主补丁里 AMCLDisplay.drainEvents 的读法）。
#define AMCL_LWJGL2_ACTION_RELEASE 0
#define AMCL_LWJGL2_ACTION_PRESS 1
#define AMCL_LWJGL2_ACTION_REPEAT 2

typedef struct AmclLwjgl2WireEvent {
    int32_t type;
    int32_t i1;
    int32_t i2;
    int32_t i3;
    int32_t i4;
} AmclLwjgl2WireEvent;

// 返回 1 = 产出一个线上事件；0 = 本事件不产出（亚阈值滚轮 / 横轴 / 非有限 / 未知类型），
// 调用方应继续取下一个。**`*outRemainder` 与 `*out` 两个出参在两种返回值下都会被写**，
// 所以调用点没有"要不要写回"这个选择。
int amclTranslateBackendEventToLwjgl2(const AmclBackendInputEvent* event,
                                      double currentRemainder,
                                      double* outRemainder,
                                      AmclLwjgl2WireEvent* out);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif
