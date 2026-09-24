#include "lwjgl2_event_translate.h"

// 分格与量纲只有一份契约，本文件不得再写一遍（计划 §91 / §102.1）。
#include "../../platform/physical_wheel_quantizer.h"

#include <cmath>

// 常量镜像必须有机械判据，否则它就是下一个"两处各说一套"。这四条把本 TU 写进线上的
// type 号与头文件里对外声明的那组钉在一起（Java 侧那三个 case 由门禁 check-lwjgl2-wire
// 之外的手段覆盖不到，因此这里至少保证 C 侧自身不漂）。
static_assert(AMCL_LWJGL2_WIRE_KEY_TYPED == 2005, "wire type drift");
static_assert(AMCL_LWJGL2_WIRE_MOUSE_BUTTON_TYPED == 2006, "wire type drift");
static_assert(AMCL_LWJGL2_WIRE_SCROLL_TYPED == 2007, "wire type drift");
static_assert(AMCL_LWJGL2_WIRE_RESET_TYPED == 2009, "wire type drift");

namespace {

// ⚠️ **未知 action fail closed，不当按下。** ABI 只定义 DOWN/REPEAT/UP 三个值，所以第四个
// 值只可能来自将来的 ABI 扩展；把它当按下会产出一个**没有配对 UP 的按下**，在游戏里读作
// "玩家一直按着"。这与 §102.1 那条"兜底分支把未知情况静默当成已知情况"是同一族。
bool Lwjgl2ActionFor(uint32_t action, int32_t* out) {
    switch (action) {
        case AMCL_BACKEND_INPUT_ACTION_UP: *out = AMCL_LWJGL2_ACTION_RELEASE; return true;
        case AMCL_BACKEND_INPUT_ACTION_REPEAT: *out = AMCL_LWJGL2_ACTION_REPEAT; return true;
        case AMCL_BACKEND_INPUT_ACTION_DOWN: *out = AMCL_LWJGL2_ACTION_PRESS; return true;
        default: return false;
    }
}

}  // namespace

extern "C" int amclTranslateBackendEventToLwjgl2(const AmclBackendInputEvent* event,
                                                double currentRemainder,
                                                double* outRemainder,
                                                AmclLwjgl2WireEvent* out) {
    // 出参本身缺失时无处写回，只能整条不产出 —— 这是唯一一条无法遵守"两种返回都写出参"的
    // 情形，所以它必须是不可达的（调用点两个出参都是栈上对象的地址）。
    if (!outRemainder || !out) return 0;
    // 非有限余量一律归零：可疑状态不得影响后续分格（与 StepPhysicalWheel 同一处置）。
    double remainder = std::isfinite(currentRemainder) ? currentRemainder : 0.0;
    AmclLwjgl2WireEvent wire{};

    if (!event) {
        *outRemainder = remainder;
        *out = wire;
        return 0;
    }

    switch (event->eventType) {
        case AMCL_BACKEND_INPUT_EVENT_KEY: {
            int32_t action = 0;
            if (!Lwjgl2ActionFor(event->action, &action)) {
                *outRemainder = remainder;
                *out = wire;
                return 0;
            }
            wire.type = AMCL_LWJGL2_WIRE_KEY_TYPED;
            wire.i1 = event->code;      // 已是 DirectInput 扫描码
            wire.i2 = event->rawCode;   // 平台硬件扫描码（LWJGL2 侧目前不读，留作诊断）
            wire.i3 = action;
            *outRemainder = remainder;
            *out = wire;
            return 1;
        }

        case AMCL_BACKEND_INPUT_EVENT_BUTTON: {
            int32_t action = 0;
            if (!Lwjgl2ActionFor(event->action, &action)) {
                *outRemainder = remainder;
                *out = wire;
                return 0;
            }
            wire.type = AMCL_LWJGL2_WIRE_MOUSE_BUTTON_TYPED;
            wire.i1 = event->code;
            // ⚠️ 按钮只有两态：LWJGL2 的 Mouse 没有"重复"概念，REPEAT 当按下处理。
            // 这一步只在 action **已知**之后做 —— 未知 action 已在上面整条拒掉。
            wire.i2 = action == AMCL_LWJGL2_ACTION_RELEASE ? 0 : 1;
            *outRemainder = remainder;
            *out = wire;
            return 1;
        }

        case AMCL_BACKEND_INPUT_EVENT_WHEEL: {
            // ⭐ 分格调**与两条 GLFW 平面同一个** StepPhysicalWheel，不自己写数学。
            // 那条纪律在 §91 立过，而本文件的第一版还是又手写了一遍 trunc —— 于是丢掉了
            // maxDetentsPerEvent 截断与 DropOnCrossing 两条通道契约（快滚一次甩出上百格）。
            // 横轴 fail closed、非有限拒收、**拒绝时余量归零**这三条也一并由它负责。
            //
            // 通道里的值是连续格数，StepPhysicalWheel 吃的是 px 样本，所以先做逆变换。
            // 余量因此与两条 GLFW 平面同为 **px** 量纲。
            const double xPx = amcl::input::PlatformSampleFromGlfwScrollContinuous(
                static_cast<double>(event->wheelX),
                amcl::input::kGlfwPhysicalWheelPolicy);
            const double yPx = amcl::input::PlatformSampleFromGlfwScrollContinuous(
                static_cast<double>(event->wheelY),
                amcl::input::kGlfwPhysicalWheelPolicy);
            amcl::input::PhysicalWheelStepOutcome step{};
            amcl::input::StepPhysicalWheel(
                remainder, xPx, yPx, amcl::input::kGlfwPhysicalWheelPolicy,
                &step);
            *outRemainder = step.remainder;
            if (step.status != amcl::input::PhysicalWheelStepStatus::kEmit) {
                *out = wire;
                return 0;
            }
            wire.type = AMCL_LWJGL2_WIRE_SCROLL_TYPED;
            // Java 侧把它乘 120（LWJGL2 每格 120），所以这里必须是**格**而不是 px。
            wire.i2 = step.glfwY;
            *out = wire;
            return 1;
        }

        case AMCL_BACKEND_INPUT_EVENT_RESET:
            // 复位必须清余量，否则跨会话残量让下一次会话的第一格提前触发（§86.5 同形：
            // typed 滚轮那半边此前一个复位点都没有）。
            wire.type = AMCL_LWJGL2_WIRE_RESET_TYPED;
            wire.i1 = static_cast<int32_t>(event->resetReason);
            *outRemainder = 0.0;
            *out = wire;
            return 1;

        case AMCL_BACKEND_INPUT_EVENT_TEXT_SESSION:
        case AMCL_BACKEND_INPUT_EVENT_TEXT_EDITING:
        case AMCL_BACKEND_INPUT_EVENT_TEXT_CANDIDATES:
        case AMCL_BACKEND_INPUT_EVENT_TEXT_SELECTION:
            // LWJGL2 has no preedit/candidate/selection ABI. The C bridge
            // consumes COMMIT packets before this pure translator and emits
            // one legacy CHAR (KEY_NONE+character) per Unicode scalar. Keep
            // these lifecycle/unsupported records explicit here so a future
            // caller cannot accidentally reinterpret session ids as keys.
            *outRemainder = remainder;
            *out = wire;
            return 0;

        default:
            // 未知类型丢弃而不是猜。余量原样保留：它与本事件无关。
            *outRemainder = remainder;
            *out = wire;
            return 0;
    }
}
