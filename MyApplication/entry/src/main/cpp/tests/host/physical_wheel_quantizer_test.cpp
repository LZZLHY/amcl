#include "../../platform/physical_wheel_quantizer.h"

#include <cstdlib>
#include <iostream>
#include <limits>

using namespace amcl::input;

namespace {
[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "PHYSICAL WHEEL QUANTIZER FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)
}  // namespace

int main() {
    PhysicalWheelQuantizeResult output{91.0, 91};
    const double invalid[] = {
        std::numeric_limits<double>::quiet_NaN(),
        std::numeric_limits<double>::infinity(),
        -std::numeric_limits<double>::infinity(),
        std::numeric_limits<double>::max(),
    };
    for (double value : invalid) {
        CHECK(!IsFinitePhysicalWheelSample(value));
        CHECK(QuantizePhysicalWheelSample(
                  3.0, value, 8.0, 256u, &output) ==
              PhysicalWheelQuantizeStatus::InvalidNumeric);
        CHECK(output.remainder == 91.0 && output.detents == 91);
    }

    CHECK(QuantizePhysicalWheelSample(
              3.0, 13.0, 8.0, 256u, &output) ==
          PhysicalWheelQuantizeStatus::Accepted);
    CHECK(output.remainder == 0.0 && output.detents == 2);
    CHECK(QuantizePhysicalWheelSample(
              output.remainder, -9.0, 8.0, 256u, &output) ==
          PhysicalWheelQuantizeStatus::Accepted);
    CHECK(output.remainder == -1.0 && output.detents == -1);

    const PhysicalWheelQuantizeResult beforeLimit = output;
    CHECK(QuantizePhysicalWheelSample(
              output.remainder, 4096.0, 8.0, 256u, &output) ==
          PhysicalWheelQuantizeStatus::ResourceLimit);
    CHECK(output.remainder == beforeLimit.remainder);
    CHECK(output.detents == beforeLimit.detents);
    CHECK(QuantizePhysicalWheelSample(
              output.remainder, 9.0, 8.0, 256u, &output) ==
          PhysicalWheelQuantizeStatus::Accepted);
    CHECK(output.remainder == 0.0 && output.detents == 1);

    // 共用契约的默认值就是物理滚轮那条通道的契约（计划 §83.9）。

    constexpr GlfwScrollPolicy kWheel = kGlfwPhysicalWheelPolicy;
    static_assert(kWheel.stepPx == 1.0);
    static_assert(kWheel.maxDetentsPerEvent == 1u);
    static_assert(kWheel.remainder == WheelRemainderPolicy::DropOnCrossing);

    GlfwScrollFromPxResult glfw{-7.0, -7};

    // 方向：向下/向后滚（vy 正）必须得到 GLFW -1，MC 侧 selected+1 ⇒ 快捷栏 1→2。
    CHECK(GlfwScrollFromWheelPx(0.0, 1.0, kWheel, &glfw) ==
          PhysicalWheelQuantizeStatus::Accepted);
    CHECK(glfw.glfwY == -1 && glfw.remainder == 0.0);

    // 向前/向上滚（vy 负）必须得到 GLFW +1。
    CHECK(GlfwScrollFromWheelPx(0.0, -1.0, kWheel, &glfw) ==
          PhysicalWheelQuantizeStatus::Accepted);
    CHECK(glfw.glfwY == 1 && glfw.remainder == 0.0);

    // 亚阈值必须累加、不得产出边沿 —— 这一条直接否掉"px 当度除以 15"那种实现。

    CHECK(GlfwScrollFromWheelPx(0.0, 0.4, kWheel, &glfw) ==
          PhysicalWheelQuantizeStatus::Accepted);
    CHECK(glfw.glfwY == 0 && glfw.remainder == 0.4);
    CHECK(GlfwScrollFromWheelPx(glfw.remainder, 0.4, kWheel, &glfw) ==
          PhysicalWheelQuantizeStatus::Accepted);
    CHECK(glfw.glfwY == 0 && glfw.remainder == 0.8);
    CHECK(GlfwScrollFromWheelPx(glfw.remainder, 0.4, kWheel, &glfw) ==
          PhysicalWheelQuantizeStatus::Accepted);

    // ⭐ 跨阈值就丢零头（0.8+0.4=1.2 ⇒ 一格，余 0.2 不携带）。理由见计划 §83.9。
    CHECK(glfw.glfwY == -1 && glfw.remainder == 0.0);

    // ⭐ 一个物理事件最多一格：快速滚动的多余像素不得排队成额外的快捷栏跳格。
    CHECK(GlfwScrollFromWheelPx(0.0, -3.0, kWheel, &glfw) ==
          PhysicalWheelQuantizeStatus::Accepted);
    CHECK(glfw.glfwY == 1 && glfw.remainder == 0.0);
    CHECK(GlfwScrollFromWheelPx(0.0, 250.0, kWheel, &glfw) ==
          PhysicalWheelQuantizeStatus::Accepted);
    CHECK(glfw.glfwY == -1 && glfw.remainder == 0.0);

    // Carry 与放宽上限仍可配置：另一类通道（位置累计量）需要它，规范 §九。
    constexpr GlfwScrollPolicy kPan{1.0, 1u << 20, 256u,
                                    WheelRemainderPolicy::Carry};
    CHECK(GlfwScrollFromWheelPx(0.0, -3.4, kPan, &glfw) ==
          PhysicalWheelQuantizeStatus::Accepted);
    CHECK(glfw.glfwY == 3);
    CHECK(glfw.remainder < -0.39 && glfw.remainder > -0.41);

    // ⭐ Carry 与截断同时发生：被夹掉的格必须退回残量。理由见计划 §86.4。
    CHECK(GlfwScrollFromWheelPx(0.0, 1000.5, kPan, &glfw) ==
          PhysicalWheelQuantizeStatus::Accepted);
    CHECK(glfw.glfwY == -256);
    CHECK(glfw.remainder > 744.49 && glfw.remainder < 744.51);

    // Drop 下同一个输入仍然只出一格、残量归零（两条策略在这里必须分道）。
    CHECK(GlfwScrollFromWheelPx(0.0, 1000.5, kWheel, &glfw) ==
          PhysicalWheelQuantizeStatus::Accepted);
    CHECK(glfw.glfwY == -1 && glfw.remainder == 0.0);

    // 事务性：无效输入与资源上限都不得污染调用方累加器。
    const GlfwScrollFromPxResult before = glfw;
    CHECK(GlfwScrollFromWheelPx(
              glfw.remainder, std::numeric_limits<double>::quiet_NaN(),
              kWheel, &glfw) ==
          PhysicalWheelQuantizeStatus::InvalidNumeric);
    CHECK(glfw.glfwY == before.glfwY && glfw.remainder == before.remainder);
    constexpr GlfwScrollPolicy kTight{1.0, 256u, 1u,
                                      WheelRemainderPolicy::DropOnCrossing};
    CHECK(GlfwScrollFromWheelPx(0.0, 4096.0, kTight, &glfw) ==
          PhysicalWheelQuantizeStatus::ResourceLimit);
    CHECK(glfw.glfwY == before.glfwY && glfw.remainder == before.remainder);

    // 退化配置 fail closed：maxDetentsPerEvent == 0 会吞掉一切，必须拒绝而不是静默。
    constexpr GlfwScrollPolicy kZero{1.0, 256u, 0u,
                                     WheelRemainderPolicy::DropOnCrossing};
    CHECK(GlfwScrollFromWheelPx(0.0, 1.0, kZero, &glfw) ==
          PhysicalWheelQuantizeStatus::InvalidNumeric);
    CHECK(GlfwScrollFromWheelPx(0.0, 1.0, kWheel, nullptr) ==
          PhysicalWheelQuantizeStatus::InvalidNumeric);

    std::cout << "physical_wheel_quantizer_test: PASS\n";
    return 0;
}
