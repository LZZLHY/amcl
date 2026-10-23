/** 生产视角processor回归：按端时钟/尾量隔离、配置共享、物理立即输出、失败不污染。 */
#include "source_look_processor.h"
#include "input_source.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); std::exit(1); } } while (0)
static bool Near(double a, double b) { return std::abs(a - b) < 1e-8; }
int main() {
    double x = 0.0, y = 0.0;
    CHECK(amcl_set_source_look_sensitivity(-1, 2.0));
    CHECK(amcl_set_source_look_invert_y(-1, true));
    CHECK(amcl_set_source_look_smoothing(-1, 0.5));
    CHECK(amcl_set_source_look_acceleration(-1, 0.0));
    CHECK(amcl_process_source_look_delta(AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 10, 6, 1000000000, &x, &y));
    CHECK(Near(x, 10) && Near(y, -6));
    // 物理alpha=1只处理自己的样本，不能带走刚留下的touch尾量。
    CHECK(amcl_process_source_look_delta(AMCL_INPUT_SOURCE_PHYSICAL_KBM, 3, 4, 1000000001, &x, &y));
    CHECK(Near(x, 6) && Near(y, -8));
    CHECK(amcl_flush_source_look_delta(AMCL_INPUT_SOURCE_PHYSICAL_KBM, true, &x, &y));
    CHECK(Near(x, 0) && Near(y, 0));
    CHECK(amcl_flush_source_look_delta(AMCL_INPUT_SOURCE_TOUCH_CONTROLS, true, &x, &y));
    CHECK(Near(x, 10) && Near(y, -6));

    // 不同source的时钟不相互比较，手柄首样本可以早于刚消费的physical事件。
    CHECK(amcl_process_source_look_delta(AMCL_INPUT_SOURCE_GAMEPAD, 5, 0, 900000000, &x, &y));
    CHECK(Near(x, 5));
    CHECK(!amcl_process_source_look_delta(AMCL_INPUT_SOURCE_GAMEPAD,
        std::numeric_limits<double>::infinity(), 0, 900000001, &x, &y));
    CHECK(Near(x, 0));
    CHECK(amcl_flush_source_look_delta(AMCL_INPUT_SOURCE_GAMEPAD, true, &x, &y));
    CHECK(Near(x, 5));
    CHECK(!amcl_set_source_look_sensitivity(-1, std::numeric_limits<double>::quiet_NaN()));
    CHECK(amcl_process_source_look_delta(AMCL_INPUT_SOURCE_PHYSICAL_KBM, 1, 1, 2000000000, &x, &y));
    CHECK(Near(x, 2) && Near(y, -2));

    // 单端配置可覆盖共享默认，而不改其它来源；既有量纲系数保持1。
    CHECK(amcl_set_source_look_sensitivity(AMCL_INPUT_SOURCE_GAMEPAD, 1.0));
    CHECK(amcl_set_source_look_smoothing(AMCL_INPUT_SOURCE_GAMEPAD, 1.0));
    CHECK(amcl_process_source_look_delta(AMCL_INPUT_SOURCE_GAMEPAD, 2, 0, 3000000000, &x, &y));
    CHECK(Near(x, 2));
    CHECK(amcl_process_source_look_delta(AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 2, 0, 3000000000, &x, &y));
    amcl_reset_source_look_state();
    CHECK(amcl_flush_source_look_delta(AMCL_INPUT_SOURCE_TOUCH_CONTROLS, true, &x, &y));
    CHECK(Near(x, 0));
    const auto stats = amcl::input::SourceLookPipelineSnapshot();
    CHECK(Near(stats.scaledDx, stats.emitDx + stats.backlogDx + stats.discardedDx));
    CHECK(Near(stats.scaledDy, stats.emitDy + stats.backlogDy + stats.discardedDy));
    // 全部参数同一事务：任一字段非法时不能先改灵敏度或倒置，已加工余量也不重算。
    CHECK(amcl_apply_source_look_configuration(-1, 3.0, false, 1.0, 0.0));
    CHECK(!amcl_apply_source_look_configuration(-1, 4.0, true, 9.0, 0.0));
    CHECK(amcl_process_source_look_delta(AMCL_INPUT_SOURCE_PHYSICAL_KBM, 2, 3, 4000000000, &x, &y));
    CHECK(Near(x, 6) && Near(y, 9));
    // 陀螺仪即时输出且时钟与手指分开；不拿走手指平滑尾量，也不继承其加速dt。
    amcl_reset_source_look_state();
    CHECK(amcl_apply_source_look_configuration(AMCL_INPUT_SOURCE_TOUCH_CONTROLS,2,false,.5,0));
    CHECK(amcl_process_source_look_delta(AMCL_INPUT_SOURCE_TOUCH_CONTROLS,10,0,6000000000,&x,&y));
    CHECK(Near(x,10));
    CHECK(amcl_process_touch_gyro_delta(3,4,5000000000,&x,&y));
    CHECK(Near(x,6)&&Near(y,8));
    CHECK(amcl_flush_source_look_delta(AMCL_INPUT_SOURCE_TOUCH_CONTROLS,true,&x,&y));
    CHECK(Near(x,10)&&Near(y,0));
    CHECK(amcl_process_touch_gyro_delta(1,0,5001000000,&x,&y)&&Near(x,2));
    std::puts("source_look_processor_test: all checks passed");
}
