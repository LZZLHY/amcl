// input_source.cpp — 输入端概念的实现。契约与理由见 .h。
#include "input_source.h"

#include <hilog/log.h>

#include <atomic>

#undef LOG_TAG
#define LOG_TAG "AMCL_INSRC"

namespace {

// 每端的复位次数、视角样本数、滚轮格数。只做诊断，不参与决策，因此 relaxed 足够。
std::atomic<unsigned> g_resetCount[AMCL_INPUT_SOURCE_COUNT];
std::atomic<unsigned> g_lookCount[AMCL_INPUT_SOURCE_COUNT];
std::atomic<unsigned> g_scrollCount[AMCL_INPUT_SOURCE_COUNT];

bool InRange(AmclInputSource source) {
    // 与 external_held_registry.cpp 同一写法，理由同上：枚举底层类型可能是无符号的，
    // 直接 `>= AMCL_INPUT_SOURCE_NONE` 在 clang/gcc 的 -Wextra 下是恒真比较告警。
    const int value = static_cast<int>(source);
    return value >= static_cast<int>(AMCL_INPUT_SOURCE_NONE) &&
           value < AMCL_INPUT_SOURCE_COUNT;
}

unsigned Load(const std::atomic<unsigned>* table, AmclInputSource source) {
    if (!InRange(source)) return 0u;
    return table[static_cast<int>(source)].load(std::memory_order_relaxed);
}

}  // namespace

extern "C" const char* amcl_input_source_name(AmclInputSource source) {
    switch (source) {
        case AMCL_INPUT_SOURCE_NONE:             return "none";
        case AMCL_INPUT_SOURCE_TOUCH_CONTROLS:   return "touchControls";
        case AMCL_INPUT_SOURCE_GAMEPAD:          return "gamepad";
        case AMCL_INPUT_SOURCE_PHYSICAL_KBM:     return "physicalKbm";
        case AMCL_INPUT_SOURCE_PLATFORM_GESTURE: return "platformGesture";
    }
    return "?";
}

extern "C" double amcl_input_source_look_scale(AmclInputSource source) {
    // ⚠️ 三端一律 1.0 —— 与引入本文件之前逐位相同。理由见 .h：
    // 现有手感已被用户验收，在拿到真机标定数据之前不动系数，
    // 否则"架构调整"与"手感回归"会混成一次无法判读的变更。
    //
    // 这个 switch 刻意写全，而不是直接 `return 1.0`：它就是那道接缝。
    // 将来标定时只改这里，三端各自独立，不需要碰 applyLookDelta 或任何调用点。
    switch (source) {
        case AMCL_INPUT_SOURCE_TOUCH_CONTROLS:
            // 触点差分，单位 surface 物理 px。
            return 1.0;
        case AMCL_INPUT_SOURCE_PHYSICAL_KBM:
            // rawDelta。官方：硬件原始值，且 API 26 之前被系统显示大小比例缩过。
            return 1.0;
        case AMCL_INPUT_SOURCE_GAMEPAD:
            // 摇杆归一量 × ArkTS 侧的 RIGHT_STICK_LOOK_GAIN，无物理长度含义。
            return 1.0;
        case AMCL_INPUT_SOURCE_PLATFORM_GESTURE:
            // 平台手势只产生按键 tap，**不该出现在 look 路径上**。出现即说明标注错了；
            // 返回 1.0 保证行为不变，真正的告警来自不变量自检里的 look 归属检查。
            return 1.0;
        case AMCL_INPUT_SOURCE_NONE:
            break;
    }
    return 1.0;
}

extern "C" double amcl_input_source_look_smoothing(AmclInputSource source,
                                                  double globalAlpha) {
    switch (source) {
        case AMCL_INPUT_SOURCE_PHYSICAL_KBM:
            // ⚠️ **物理鼠标不做平滑，这是本函数存在的全部理由。**
            // 平滑要抑制的是**手指抖动**与触点量化噪声；rawDelta 是硬件计数器，不抖。
            // 对它做一阶低通只买到相位滞后（τ ≈ 18ms @ alpha=0.6），没换到任何东西 ——
            // 用户报的"视角有延迟感"就是它，完整量化见计划 §77.1。
            return 1.0;
        case AMCL_INPUT_SOURCE_TOUCH_CONTROLS:
            // 滑条的原始语义就是这一端（它来自虚拟按键布局），原样透传。
            return globalAlpha;
        case AMCL_INPUT_SOURCE_GAMEPAD:
            // ⚠️ **刻意跟随全局值，不要顺手也置 1.0。** 摇杆量是连续的模拟量，
            // 平滑对它可能是有意义的；而我们**没有手柄真机数据**（`AMCL_PADAXIS`
            // 至今 0 条）。在拿到数据之前改它属于凭感觉调手感。
            return globalAlpha;
        case AMCL_INPUT_SOURCE_PLATFORM_GESTURE:
        case AMCL_INPUT_SOURCE_NONE:
            // 这两个不该出现在 look 路径上（理由同 look_scale）。返回全局值保证
            // "标注错了"不会额外改变行为，告警仍由不变量自检的 look 归属检查给出。
            break;
    }
    return globalAlpha;
}

extern "C" void amcl_input_source_note_reset(AmclInputSource source) {
    if (!InRange(source)) return;
    g_resetCount[static_cast<int>(source)].fetch_add(1,
                                                     std::memory_order_relaxed);
}

extern "C" void amcl_input_source_note_look(AmclInputSource source) {
    if (!InRange(source)) return;
    g_lookCount[static_cast<int>(source)].fetch_add(1,
                                                    std::memory_order_relaxed);
}

extern "C" void amcl_input_source_note_scroll(AmclInputSource source) {
    if (!InRange(source)) return;
    g_scrollCount[static_cast<int>(source)].fetch_add(
        1, std::memory_order_relaxed);
}

extern "C" unsigned amcl_input_source_reset_count(AmclInputSource source) {
    return Load(g_resetCount, source);
}

extern "C" unsigned amcl_input_source_look_count(AmclInputSource source) {
    return Load(g_lookCount, source);
}

extern "C" unsigned amcl_input_source_scroll_count(AmclInputSource source) {
    return Load(g_scrollCount, source);
}

extern "C" void amcl_input_source_log_reset_state(void) {
    // 三段合一：resets 判读"哪个端漏了复位"，looks 判读"视角来源归属是否与通道普查一致"，
    // scrolls 判读"这一格快捷栏是哪个端切的"。
    //
    // `untagged` 是**告警栏**：非零即表示有调用点还没申报端身份。平台手势（返回键）
    // 有自己的 `gesture` 栏，所以不会再把这一栏染脏。
    OH_LOG_INFO(LOG_APP,
                "AMCL_INSRC resets touch=%{public}u pad=%{public}u kbm=%{public}u "
                "gesture=%{public}u untagged=%{public}u | "
                "looks touch=%{public}u pad=%{public}u kbm=%{public}u "
                "gesture=%{public}u untagged=%{public}u | "
                "scrolls touch=%{public}u pad=%{public}u kbm=%{public}u "
                "gesture=%{public}u untagged=%{public}u",
                Load(g_resetCount, AMCL_INPUT_SOURCE_TOUCH_CONTROLS),
                Load(g_resetCount, AMCL_INPUT_SOURCE_GAMEPAD),
                Load(g_resetCount, AMCL_INPUT_SOURCE_PHYSICAL_KBM),
                Load(g_resetCount, AMCL_INPUT_SOURCE_PLATFORM_GESTURE),
                Load(g_resetCount, AMCL_INPUT_SOURCE_NONE),
                Load(g_lookCount, AMCL_INPUT_SOURCE_TOUCH_CONTROLS),
                Load(g_lookCount, AMCL_INPUT_SOURCE_GAMEPAD),
                Load(g_lookCount, AMCL_INPUT_SOURCE_PHYSICAL_KBM),
                Load(g_lookCount, AMCL_INPUT_SOURCE_PLATFORM_GESTURE),
                Load(g_lookCount, AMCL_INPUT_SOURCE_NONE),
                Load(g_scrollCount, AMCL_INPUT_SOURCE_TOUCH_CONTROLS),
                Load(g_scrollCount, AMCL_INPUT_SOURCE_GAMEPAD),
                Load(g_scrollCount, AMCL_INPUT_SOURCE_PHYSICAL_KBM),
                Load(g_scrollCount, AMCL_INPUT_SOURCE_PLATFORM_GESTURE),
                Load(g_scrollCount, AMCL_INPUT_SOURCE_NONE));
}
