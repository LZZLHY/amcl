// lwjgl2_event_translate_test.cpp — LWJGL2 出线翻译的断言（计划 §102）
//
// ============================ 它证明什么 ============================
//
// TASK 6 把三个后端都切到 typed 通道之后，**两条新链的正确性只有"读代码"一个依据**。
// 这个文件把 LWJGL2 那一条里可判定的部分变成机械判据：
//   · action 三态映射（DOWN/REPEAT/UP → 1/2/0），且按钮**只有两态**；
//   · 滚轮亚阈值累加、跨阈值出格、向零取整；
//   · ⭐ 拒绝路径上余量**归零**。这一条是全文件最贵的：§91.2 抓到过的那条真缺陷正是
//     "一条平面清零、另一条保留" ⇒ 一个非法样本之后格数序列**永久错位**，而两边各自的
//     单元测试都是绿的。新写的这条链是第三处同形代码，没有断言就是第三次赌运气。
//   · 复位清余量（跨会话残量会让下一次会话的第一格提前触发）；
//   · 未知类型丢弃且**余量原样保留**（与拒绝路径刻意不同）；
//   · 两个出参在**两种返回值下都被写**。这条不是洁癖：调用点靠"无条件写回"来保证自己
//     没有可以做错的选择，而那个保证的另一半在这里。
//
// ============================ 它不证明什么 ============================
//
// ⚠️ **不覆盖调用点。** 真正的循环在 glfw/input_bridge_ohos.c 的 l2NextTypedEvent 里，
// 那个 TU 有 hilog/pthread/atomic，进不了 host 构建。"无条件写回余量"这一条因此仍然只有
// 产品 TU 语法门禁 + review 钉着（与 §91 的 StepPhysicalWheel 完全同一残留）。
//
// ⚠️ **不覆盖 Java 那一侧。** 2005/2006/2007/2009 四个 type 号在 AMCLDisplay 里读哪几个
// 字段，本文件只能断言 C 侧写了什么，读法一致性没有跨语言判据。
//
// ⚠️ **不覆盖 code 的取值。** 事件里的 code 已经是 DirectInput 扫描码，那一步的正确性由
// check-backend-keymap-parity 负责，本 TU 只做原样搬运。

#include "../../input/adapters/lwjgl2_event_translate.h"

#include "../../input/amcl_input_event.h"
#include "../../platform/physical_wheel_quantizer.h"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "LWJGL2 TRANSLATE FAIL line " << line << ": " << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

AmclBackendInputEvent MakeEvent(uint32_t type) {
    AmclBackendInputEvent ev{};
    ev.abiVersion = AMCL_BACKEND_INPUT_ABI_VERSION;
    ev.structSize = static_cast<uint16_t>(sizeof(AmclBackendInputEvent));
    ev.eventType = type;
    return ev;
}

// 每次调用前把出参涂成不可能的值，这样"没写"与"写了正确值"可以区分开。
struct Call {
    int emitted = 0;
    double remainder = 0.0;
    AmclLwjgl2WireEvent wire{};
};

Call Translate(const AmclBackendInputEvent* ev, double remainderIn) {
    Call c;
    c.remainder = -12345.0;
    c.wire.type = 0x5A5A;
    c.wire.i1 = 0x5A5A;
    c.wire.i2 = 0x5A5A;
    c.wire.i3 = 0x5A5A;
    c.wire.i4 = 0x5A5A;
    c.emitted = amclTranslateBackendEventToLwjgl2(ev, remainderIn, &c.remainder, &c.wire);
    // 两种返回值下两个出参都必须被写 —— 涂色值一个都不许活下来。
    if (c.remainder == -12345.0) Fail("remainder not written", __LINE__);
    if (c.wire.type == 0x5A5A) Fail("wire not written", __LINE__);
    return c;
}

}  // namespace

int main() {
    // 1. 按键 action 三态。
    {
        struct { uint32_t action; int32_t expect; } cases[] = {
            {AMCL_BACKEND_INPUT_ACTION_DOWN, AMCL_LWJGL2_ACTION_PRESS},
            {AMCL_BACKEND_INPUT_ACTION_REPEAT, AMCL_LWJGL2_ACTION_REPEAT},
            {AMCL_BACKEND_INPUT_ACTION_UP, AMCL_LWJGL2_ACTION_RELEASE},
        };
        for (const auto& c : cases) {
            AmclBackendInputEvent ev = MakeEvent(AMCL_BACKEND_INPUT_EVENT_KEY);
            ev.code = 0x11;      // DirectInput 'W'
            ev.rawCode = 2017;
            ev.action = c.action;
            const Call r = Translate(&ev, 0.25);
            CHECK(r.emitted == 1);
            CHECK(r.wire.type == AMCL_LWJGL2_WIRE_KEY_TYPED);
            CHECK(r.wire.i1 == 0x11);
            CHECK(r.wire.i2 == 2017);
            CHECK(r.wire.i3 == c.expect);
            // 按键不碰滚轮余量。
            CHECK(r.remainder == 0.25);
        }
    }

    // 2. ⭐ 未知 action **fail closed**：整条不产出，不猜成按下。ABI 只定义 1/2/3，所以
    //    第四个值只可能来自将来的扩展；猜成按下会产出一个**没有配对 UP 的按下**，在游戏里
    //    读作"玩家一直按着攻击"。键与按钮两条路都必须拒。
    {
        for (uint32_t bad : {0u, 4u, 99u}) {
            AmclBackendInputEvent key = MakeEvent(AMCL_BACKEND_INPUT_EVENT_KEY);
            key.action = bad;
            const Call rk = Translate(&key, 0.25);
            CHECK(rk.emitted == 0);
            CHECK(rk.wire.type == 0);
            CHECK(rk.remainder == 0.25);  // 与本事件无关的滚轮余量必须原样保留

            AmclBackendInputEvent button = MakeEvent(AMCL_BACKEND_INPUT_EVENT_BUTTON);
            button.action = bad;
            const Call rb = Translate(&button, 0.25);
            CHECK(rb.emitted == 0);
            CHECK(rb.wire.type == 0);
            CHECK(rb.remainder == 0.25);
        }
    }

    // 3. ⭐ 按钮只有两态：REPEAT 必须当按下，不得出现 2。
    {
        AmclBackendInputEvent down = MakeEvent(AMCL_BACKEND_INPUT_EVENT_BUTTON);
        down.code = 0;
        down.action = AMCL_BACKEND_INPUT_ACTION_DOWN;
        AmclBackendInputEvent repeat = down;
        repeat.action = AMCL_BACKEND_INPUT_ACTION_REPEAT;
        AmclBackendInputEvent up = down;
        up.action = AMCL_BACKEND_INPUT_ACTION_UP;

        const Call a = Translate(&down, 0.0);
        const Call b = Translate(&repeat, 0.0);
        const Call c = Translate(&up, 0.0);
        CHECK(a.emitted == 1 && b.emitted == 1 && c.emitted == 1);
        CHECK(a.wire.type == AMCL_LWJGL2_WIRE_MOUSE_BUTTON_TYPED);
        CHECK(a.wire.i2 == 1);
        CHECK(b.wire.i2 == 1);
        CHECK(c.wire.i2 == 0);
        CHECK(a.wire.i1 == 0);
    }

    // 4. 滚轮亚阈值累加：不足一格不出，余量攒着（余量是 **px** 量纲，符号与格数相反）。
    {
        AmclBackendInputEvent ev = MakeEvent(AMCL_BACKEND_INPUT_EVENT_WHEEL);
        ev.wheelY = 0.4f;
        Call r = Translate(&ev, 0.0);
        CHECK(r.emitted == 0);
        CHECK(r.remainder != 0.0);
        const double afterOne = r.remainder;
        r = Translate(&ev, r.remainder);
        CHECK(r.emitted == 0);
        CHECK(std::abs(r.remainder) > std::abs(afterOne));
        // 第三个样本跨阈值：出一格，零头按 DropOnCrossing 归零（通道契约，规范 §九）。
        r = Translate(&ev, r.remainder);
        CHECK(r.emitted == 1);
        CHECK(r.wire.type == AMCL_LWJGL2_WIRE_SCROLL_TYPED);
        CHECK(r.wire.i2 == 1);
        CHECK(r.remainder == 0.0);
    }

    // 5. 负向对称：方向必须原样传下去。滚轮反向这条本仓真机否证过一次（计划 §83）。
    {
        AmclBackendInputEvent ev = MakeEvent(AMCL_BACKEND_INPUT_EVENT_WHEEL);
        ev.wheelY = -1.0f;
        const Call r = Translate(&ev, 0.0);
        CHECK(r.emitted == 1);
        CHECK(r.wire.i2 == -1);
        CHECK(r.remainder == 0.0);
    }

    // 6. ⭐ 横轴非零：整包拒收，且余量**归零**。这是本文件最贵的一条 —— 保留余量会让
    //    此后每一格都错位（§91.2 的真缺陷形状）。
    {
        AmclBackendInputEvent ev = MakeEvent(AMCL_BACKEND_INPUT_EVENT_WHEEL);
        ev.wheelX = 1.0f;
        ev.wheelY = 3.0f;
        const Call r = Translate(&ev, 0.75);
        CHECK(r.emitted == 0);
        CHECK(r.remainder == 0.0);
    }

    // 7. ⭐ 非有限纵轴：同样拒收并归零。
    {
        AmclBackendInputEvent ev = MakeEvent(AMCL_BACKEND_INPUT_EVENT_WHEEL);
        ev.wheelY = std::numeric_limits<float>::quiet_NaN();
        const Call r = Translate(&ev, 0.75);
        CHECK(r.emitted == 0);
        CHECK(r.remainder == 0.0);

        AmclBackendInputEvent inf = MakeEvent(AMCL_BACKEND_INPUT_EVENT_WHEEL);
        inf.wheelY = std::numeric_limits<float>::infinity();
        const Call r2 = Translate(&inf, 0.75);
        CHECK(r2.emitted == 0);
        CHECK(r2.remainder == 0.0);
    }

    // 8. 非有限**入参余量**也归零：可疑状态不得影响后续分格。喂一个够一格的样本，
    //    若脏余量参与了加法结果就不是干净的一格。
    {
        AmclBackendInputEvent ev = MakeEvent(AMCL_BACKEND_INPUT_EVENT_WHEEL);
        ev.wheelY = 1.0f;
        const Call r = Translate(&ev, std::numeric_limits<double>::quiet_NaN());
        CHECK(r.emitted == 1);
        CHECK(r.wire.i2 == 1);
        CHECK(r.remainder == 0.0);
    }

    // 9. 零样本合法：不出格、余量**保留**（与拒绝路径刻意不同）。
    {
        AmclBackendInputEvent ev = MakeEvent(AMCL_BACKEND_INPUT_EVENT_WHEEL);
        ev.wheelY = 0.0f;
        const Call r = Translate(&ev, 0.75);
        CHECK(r.emitted == 0);
        CHECK(r.remainder == 0.75);
    }

    // 10. ⭐ 复位清余量。跨会话残量会让下一次会话的第一格提前触发。
    {
        AmclBackendInputEvent ev = MakeEvent(AMCL_BACKEND_INPUT_EVENT_RESET);
        ev.resetReason = 7;
        const Call r = Translate(&ev, 0.9);
        CHECK(r.emitted == 1);
        CHECK(r.wire.type == AMCL_LWJGL2_WIRE_RESET_TYPED);
        CHECK(r.wire.i1 == 7);
        CHECK(r.remainder == 0.0);
    }

    // 11. 未知类型丢弃，余量**原样保留**：它与本事件无关。
    {
        AmclBackendInputEvent ev = MakeEvent(0xDEAD);
        const Call r = Translate(&ev, 0.6);
        CHECK(r.emitted == 0);
        CHECK(r.remainder == 0.6);
        CHECK(r.wire.type == 0);
    }

    // Typed text is consumed by the runtime bridge (which owns the blob and
    // emits legacy CHAR records). The pure physical translator must never
    // reinterpret a session id or packet id as a DirectInput key.
    for (uint32_t type : {
             AMCL_BACKEND_INPUT_EVENT_TEXT_SESSION,
             AMCL_BACKEND_INPUT_EVENT_TEXT_EDITING,
             AMCL_BACKEND_INPUT_EVENT_TEXT_CANDIDATES,
             AMCL_BACKEND_INPUT_EVENT_TEXT_SELECTION}) {
        AmclBackendInputEvent ev = MakeEvent(type);
        ev.deviceId = 77u;
        const Call r = Translate(&ev, 0.6);
        CHECK(r.emitted == 0);
        CHECK(r.remainder == 0.6);
        CHECK(r.wire.type == 0);
    }

    // 12. fail closed：出参缺失整条不产出；event 缺失当作跳过并保留余量。
    {
        AmclBackendInputEvent ev = MakeEvent(AMCL_BACKEND_INPUT_EVENT_KEY);
        AmclLwjgl2WireEvent wire{};
        double rem = 0.5;
        CHECK(amclTranslateBackendEventToLwjgl2(&ev, 0.5, nullptr, &wire) == 0);
        CHECK(amclTranslateBackendEventToLwjgl2(&ev, 0.5, &rem, nullptr) == 0);
        CHECK(rem == 0.5);  // 出参不完整时一个字都不许写
        const Call r = Translate(nullptr, 0.6);
        CHECK(r.emitted == 0);
        CHECK(r.remainder == 0.6);
    }

    // 13. ⭐ 一个事件最多一格（`maxDetentsPerEvent = 1`）。**这一条是本文件的第一版会红的
    //     地方**：那一版自己手写 trunc，于是 5.0 直接出 5 格，Java 侧再乘 120 ⇒ 一次快滚
    //     在游戏里翻过整条物品栏。截断与 DropOnCrossing 都属通道契约，不是本 TU 的自由。
    {
        AmclBackendInputEvent ev = MakeEvent(AMCL_BACKEND_INPUT_EVENT_WHEEL);
        ev.wheelY = 5.0f;
        const Call r = Translate(&ev, 0.0);
        CHECK(r.emitted == 1);
        CHECK(r.wire.i2 == 1);
        CHECK(r.remainder == 0.0);
    }

    // 14. ⭐ 与两条 GLFW 平面**逐位一致**：同一个连续格数喂 StepPhysicalWheel 必须得到
    //     同一个 glfwY。这条把"三条平面共用一份分格"从读代码变成机械判据 —— §83.9 之前
    //     有三处注释都声称共用，实际一个字都没共用。
    {
        for (double detents : {1.0, -1.0, 0.4, -0.4, 3.0, -7.5}) {
            AmclBackendInputEvent ev = MakeEvent(AMCL_BACKEND_INPUT_EVENT_WHEEL);
            ev.wheelY = static_cast<float>(detents);
            const Call r = Translate(&ev, 0.0);

            amcl::input::PhysicalWheelStepOutcome step{};
            amcl::input::StepPhysicalWheel(
                0.0, 0.0,
                amcl::input::PlatformSampleFromGlfwScrollContinuous(
                    static_cast<double>(ev.wheelY),
                    amcl::input::kGlfwPhysicalWheelPolicy),
                amcl::input::kGlfwPhysicalWheelPolicy, &step);
            const int expectEmit =
                step.status == amcl::input::PhysicalWheelStepStatus::kEmit ? 1 : 0;
            CHECK(r.emitted == expectEmit);
            CHECK(r.remainder == step.remainder);
            if (expectEmit) CHECK(r.wire.i2 == step.glfwY);
        }
    }

    // 15. 量纲折算的往返恒等式：px ⇄ 连续格数。生产侧（backend_input_bridge 的 WheelSink）
    //     靠这一对函数把平台样本换成本 ABI 声明的量纲，2026-08-24 之前它一次都没换过。
    {
        const auto& policy = amcl::input::kGlfwPhysicalWheelPolicy;
        double px = 0.0;
        double pyIgnored = 0.0;
        CHECK(amcl::input::WheelSamplePxFromUnit(
            0.0, 63.0, AMCL_INPUT_WHEEL_UNIT_PIXEL, policy, &px, &pyIgnored));
        CHECK(pyIgnored == 63.0);
        // DEGREE 必须被折算，而不是当 px 用（计划 §90 的缺陷形状）。
        double dx = 0.0;
        double dy = 0.0;
        CHECK(amcl::input::WheelSamplePxFromUnit(
            0.0, 15.0, AMCL_INPUT_WHEEL_UNIT_DEGREE, policy, &dx, &dy));
        CHECK(std::abs(dy - policy.stepPx) < 1e-9);
        // LINE / PAGE / 未知一律 fail closed。
        for (uint32_t unit : {AMCL_INPUT_WHEEL_UNIT_LINE,
                              AMCL_INPUT_WHEEL_UNIT_PAGE, 0u, 99u}) {
            double a = -1.0;
            double b = -1.0;
            CHECK(!amcl::input::WheelSamplePxFromUnit(0.0, 1.0, unit, policy,
                                                      &a, &b));
        }
        // px → 连续格数：**取反**。不取反就是滚轮方向反过来。
        double cx = 0.0;
        double cy = 0.0;
        CHECK(amcl::input::GlfwScrollDetentsFromWheelPx(0.0, policy.stepPx,
                                                        policy, &cx, &cy));
        CHECK(cx == 0.0);
        CHECK(std::abs(cy + 1.0) < 1e-9);
        CHECK(!amcl::input::GlfwScrollDetentsFromWheelPx(
            0.0, std::numeric_limits<double>::quiet_NaN(), policy, &cx, &cy));
        // 往返：连续格数 → px → 连续格数 必须回到原值。
        for (double d : {1.0, -1.0, 0.25, -3.5}) {
            double bx = 0.0;
            double by = 0.0;
            CHECK(amcl::input::GlfwScrollDetentsFromWheelPx(
                0.0, amcl::input::PlatformSampleFromGlfwScrollContinuous(d, policy),
                policy, &bx, &by));
            CHECK(std::abs(by - d) < 1e-9);
        }
    }

    std::cout << "LWJGL2 EVENT TRANSLATE PASS\n";
    return 0;
}
