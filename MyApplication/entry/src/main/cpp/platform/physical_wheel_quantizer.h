#ifndef AMCL_PHYSICAL_WHEEL_QUANTIZER_H
#define AMCL_PHYSICAL_WHEEL_QUANTIZER_H

#include <cstdint>

namespace amcl::input {

enum class PhysicalWheelQuantizeStatus : uint8_t {
    Accepted = 0,
    InvalidNumeric = 1,
    ResourceLimit = 2,
};

struct PhysicalWheelQuantizeResult {
    double remainder = 0.0;
    int32_t detents = 0;
};

// The typed ABI stores wheel axes as float. Validate the narrowing explicitly;
// a finite double such as DBL_MAX is not necessarily representable there.
bool IsFinitePhysicalWheelSample(double value);

// Pure, transactional accumulate-and-quantize step. `output` is written only on
// Accepted, so invalid arithmetic cannot mutate the caller's accumulator.
PhysicalWheelQuantizeStatus QuantizePhysicalWheelSample(
    double currentRemainder, double value, double step,
    uint32_t maxDetents, PhysicalWheelQuantizeResult* output);

// 跨过阈值之后剩下的零头怎么处置。这是**通道级契约**，不是实现细节：
// 规范《输入架构规范》§九 明写两条通道的残量策略相反，且两者都不是笔误。

enum class WheelRemainderPolicy : uint8_t {
    Carry = 0,
    DropOnCrossing = 1,
};

// 一条滚轮通道的完整分格契约。`detentLimit` 只是 int32 溢出护栏（超了 fail closed）；
// 表达"一个事件最多几格"的是 `maxDetentsPerEvent`，它做**截断**而不报错。

struct GlfwScrollPolicy {
    double stepPx = 1.0;
    uint32_t detentLimit = 1u << 20;
    uint32_t maxDetentsPerEvent = 1u;
    WheelRemainderPolicy remainder = WheelRemainderPolicy::DropOnCrossing;
};

// 物理滚轮：legacy native AXIS 与 typed 平面共用的**唯一**一份契约。此前 legacy 的
// `kWheelStepPx` 与 typed 的 `kTypedWheelStepPx` 是两份数值镜像，已收敛到这里。

inline constexpr GlfwScrollPolicy kGlfwPhysicalWheelPolicy{};

struct GlfwScrollFromPxResult {
    double remainder = 0.0;
    int32_t glfwY = 0;
};

// 入：像素位移（valuePx > 0 = 向下滚）。出：GLFW `yoffset` 的符号格数。事务式：
// 只有 Accepted 才写 `output`。⚠️ 取反被真机否证过，改它之前先读计划 §83。

PhysicalWheelQuantizeStatus GlfwScrollFromWheelPx(
    double currentRemainder, double valuePx, const GlfwScrollPolicy& policy,
    GlfwScrollFromPxResult* output);

// 一次物理滚轮样本的**完整**处置结果。两条平面共用，逐项含义见计划 §91.1。
enum class PhysicalWheelStepStatus : uint8_t {
    kEmit = 0,
    kAccumulated = 1,
    kZeroSample = 2,
    kRejectedAxis = 3,
    kRejectedValue = 4,
};

// `remainder` 必须被调用方**无条件**写回，拒绝路径也一样（那时它是 0.0）。
// 把"写回"变成无条件是刻意的：两条平面此前在拒绝路径上一个清零一个保留（计划 §91.2）。
struct PhysicalWheelStepOutcome {
    double remainder = 0.0;
    int32_t glfwY = 0;
    PhysicalWheelStepStatus status = PhysicalWheelStepStatus::kZeroSample;
};

// legacy native AXIS 与 typed 平面**唯一**的一步分格。两条平面必须调这一个函数 ——
// 否则"两条平面滚轮语义一致"只能靠读代码，而那条声称已经错过一次（计划 §91）。
void StepPhysicalWheel(double currentRemainder, double x, double y,
                       const GlfwScrollPolicy& policy,
                       PhysicalWheelStepOutcome* output);

// 已分好格的 GLFW yoffset → 平台侧样本值，经 `StepPhysicalWheel` 原样还原成同一个格。
// 谁需要它、为什么直接传 yoffset 会**反向**：计划 §95.2（负向对照在 host 断言里）。
double PlatformSampleFromGlfwScroll(int32_t glfwYOffset,
                                    const GlfwScrollPolicy& policy);

// 同上，但吃连续格数（后端 pull 通道里的滚轮就是连续的，见 `AmclBackendInputEvent`）。
double PlatformSampleFromGlfwScrollContinuous(double glfwYOffset,
                                              const GlfwScrollPolicy& policy);

// 入：平台样本 + 量纲位（`AMCL_INPUT_WHEEL_UNIT_*`）。出：px。未知量纲返回 false。
// 为什么必须共用而不是各写一遍：计划 §102.1（第三处副本已经静默按 px 解释过 DEGREE）。
bool WheelSamplePxFromUnit(double x, double y, uint32_t unit,
                           const GlfwScrollPolicy& policy,
                           double* outXPx, double* outYPx);

// px 样本 → **连续、不分格**的 yoffset 方向格数（向上为正）。非有限返回 false。
// ⚠️ 零产品调用方：只兑现契约一半（不截断、不留残量），出线一律用 `StepPhysicalWheel`。
bool GlfwScrollDetentsFromWheelPx(double xPx, double yPx,
                                  const GlfwScrollPolicy& policy,
                                  double* outX, double* outY);

}  // namespace amcl::input

#endif
