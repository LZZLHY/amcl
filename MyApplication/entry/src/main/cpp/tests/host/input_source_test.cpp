// input_source_test.cpp — 按端的两个系数表（量纲 + 平滑）。计划 §78。
//
// 为什么这一小片值得一个独立目标：这两个 switch 是"三端各自的手感"唯一的收口点，
// 而它们的失效**不报错、不崩溃、也不改变任何计数器** —— 只是某一端的手感变了。
// 具体到本轮：`amcl_input_source_look_smoothing(PHYSICAL_KBM, ...)` 一旦跟随全局值，
// 物理鼠标就重新背上 τ ≈ 18.2ms 的相位滞后 + idle worker 的 20ms 尾量
// （= 用户报的"视角有延迟感"，量化见计划 §77.1）。那种回归在日志里看不出来。
//
// 本目标同时**钉住当前的标定状态**：量纲系数三端仍一律 1.0。将来改它必须是刻意的
// （改了这里就会有一条测试失败），而不是顺手调手感。

#include "../../platform/input_source.h"

#include <cstdlib>
#include <iostream>

namespace {
[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "INPUT SOURCE FAIL line " << line << ": " << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

// 滑条的合法取值域是 [0.1, 1.0]（`ohos_set_look_smoothing` 的 clamp）。
constexpr double kSliderValues[] = {0.1, 0.35, 0.6, 0.9, 1.0};
}  // namespace

int main() {
    // ---- 平滑：物理键鼠端**无条件** 1.0（不平滑），与滑条取值无关 ----
    // 这是本文件最承重的一条。1.0 让 `ComputeLookDeltaMath` 的
    // `if (smoothAlpha < 0.999)` 为假 ⇒ emit = pending + scaled、余量恒 0
    // ⇒ 连 idle worker 那条 20ms 尾量也一起消失（它只在余量非零时才发）。
    for (double slider : kSliderValues) {
        CHECK(amcl_input_source_look_smoothing(AMCL_INPUT_SOURCE_PHYSICAL_KBM,
                                              slider) == 1.0);
    }

    // ---- 平滑：其余端原样透传滑条值 ----
    // 触控端是滑条的原始语义（抑制手指抖动）；手柄端**刻意**跟随而不是也置 1.0 ——
    // 摇杆是连续模拟量，而我们没有手柄真机数据（`AMCL_PADAXIS` 至今 0 条）。
    for (double slider : kSliderValues) {
        CHECK(amcl_input_source_look_smoothing(
                  AMCL_INPUT_SOURCE_TOUCH_CONTROLS, slider) == slider);
        CHECK(amcl_input_source_look_smoothing(AMCL_INPUT_SOURCE_GAMEPAD,
                                              slider) == slider);
        // 这两个不该出现在 look 路径上；返回全局值保证"标注错了"不额外改变行为。
        CHECK(amcl_input_source_look_smoothing(
                  AMCL_INPUT_SOURCE_PLATFORM_GESTURE, slider) == slider);
        CHECK(amcl_input_source_look_smoothing(AMCL_INPUT_SOURCE_NONE,
                                              slider) == slider);
    }

    // ---- 只有物理键鼠端与其它端不同：这条是"分桶真的分开了"的直接断言 ----
    // 若有人把按端解析改回"三端共享一份 alpha"，下面这条会失败。
    CHECK(amcl_input_source_look_smoothing(AMCL_INPUT_SOURCE_PHYSICAL_KBM, 0.6) !=
          amcl_input_source_look_smoothing(AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 0.6));

    // ---- 量纲：三端仍一律 1.0（钉住当前标定状态）----
    // ⚠️ 这不是"应该永远是 1.0"，而是"现在是 1.0，改它必须刻意"。
    // 已知缺口：`rawDelta` 的量纲在 HarmonyOS 7.0 上变过（计划 §76.8），
    // 物理键鼠端将来很可能不再是 1.0 —— 到那时改这里并同步改这条断言。
    CHECK(amcl_input_source_look_scale(AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 1.0);
    CHECK(amcl_input_source_look_scale(AMCL_INPUT_SOURCE_PHYSICAL_KBM) == 1.0);
    CHECK(amcl_input_source_look_scale(AMCL_INPUT_SOURCE_GAMEPAD) == 1.0);
    CHECK(amcl_input_source_look_scale(AMCL_INPUT_SOURCE_PLATFORM_GESTURE) == 1.0);
    CHECK(amcl_input_source_look_scale(AMCL_INPUT_SOURCE_NONE) == 1.0);

    // ---- 端名绝不返回 nullptr（.h 的承诺）----
    for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) {
        const char* name =
            amcl_input_source_name(static_cast<AmclInputSource>(i));
        CHECK(name != nullptr);
        CHECK(name[0] != '\0');
    }
    // 越界值同样不得返回 nullptr（调用方可能传进未来才加的枚举值）。
    CHECK(amcl_input_source_name(static_cast<AmclInputSource>(99)) != nullptr);

    std::cout << "input_source_test: PASS\n";
    return 0;
}
