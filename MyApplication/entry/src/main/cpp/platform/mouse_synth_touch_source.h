// mouse_synth_touch_source.h — "这个触摸包其实是鼠标吗"的分类器
//
// 属于**物理键鼠端**（AMCL_INPUT_SOURCE_PHYSICAL_KBM，见 input_source.h）的元数据判定。
//
// 为什么需要它：系统对"未适配鼠标的应用"提供兜底方案，把**鼠标左键的点击与滑动、以及
// 轴（滚轮）事件**额外合成成 TouchEvent 下发（官方《支持触屏输入事件》）。于是同一个物理
// 鼠标动作会同时以"鼠标事件"和"触摸事件"两种形态到达应用，而触摸那一路必须被识别出来 ——
// 否则鼠标会去按虚拟摇杆和虚拟按键，那是三端平级模型里绝对不允许的串台。
//
// 真机事实（两台设备，结论不同，必须靠运行期判定而不是 API 版本判断）：
//   · MRDI-W10 / API 24：`OH_NativeXComponent_GetTouchEventSourceType` 对 618/618 个包
//     全报 TOUCHSCREEN，
//     鼠标合成包也一样 ⇒ 本分类器在该机上永远得不到 kMouseSynth，调用方必须另有兜底判据。
//   · CLS-AL00 / API 26：正确报 MOUSE（`source=1 tool=0`），真手指报 `source=2 tool=1`
//     ⇒ 分类器在该机上可用，且优于任何启发式。
//
// ⚠️ 本文件是从 `mouse_synth_tap_state_machine.{h,cpp}` 拆出来的。那个文件同时装着
// 分类器与一套"延迟 300ms 合成左键点击"的 tap 识别器；后者在产品路径上**已不可达**
// （左键改由镜像/ArkUI/native 三通道经 input_channel_policy 直接透传），却仍带着一个常驻
// 线程、一个 mutex + condvar，并把 `s_grabAnnouncementMutex` 拉进全局锁序。
// tap 识别器已整体删除，只留下这里真正还在用的分类器。
#ifndef AMCL_PLATFORM_MOUSE_SYNTH_TOUCH_SOURCE_H
#define AMCL_PLATFORM_MOUSE_SYNTH_TOUCH_SOURCE_H

#include <cstdint>

namespace amcl::input {

// 触摸包的动作。保留在这里是因为触摸 ingress 用它把 XComponent 的 type 归一化，
// 镜像分支（物理左键边沿）也读它。本枚举没有任何 OHOS / bridge / 时钟依赖。
enum class MouseSynthTouchAction : uint8_t {
    kDown,
    kMove,
    kUp,
    kCancel,
};

enum class MouseSynthTouchSource : uint8_t {
    // 有些 UP/CANCEL 包不带 changed point 元数据。Unknown 只允许用于**已经绑定**的触点，
    // 永远不能作为"这是鼠标"的判据。
    kUnknown,
    kMouseSynth,
    kOther,
};

// 把平台元数据转成保守的来源模型。
//
// 只有在**两个 getter 都成功**、changed point 匹配、tool 明确为 UNKNOWN、且 XComponent
// 把事件源报成 MOUSE 时才判为 kMouseSynth。元数据不全一律 kUnknown ——
// 它可以给一个已绑定的触点收尾，但绝不能开启一次新的判定。
//
// 这条严格性是有代价的（API 24 上永不成立），但反过来更危险：把真手指误判成鼠标会让
// 玩家的虚拟摇杆整根失效，而漏判只是让鼠标多走一次触摸路径。fail-closed 方向选后者。
MouseSynthTouchSource ClassifyMouseSynthTouchSource(
    bool changedPointMatched, bool toolQuerySucceeded, bool toolIsUnknown,
    bool sourceQuerySucceeded, bool sourceIsMouse);

}  // namespace amcl::input

#endif  // AMCL_PLATFORM_MOUSE_SYNTH_TOUCH_SOURCE_H
