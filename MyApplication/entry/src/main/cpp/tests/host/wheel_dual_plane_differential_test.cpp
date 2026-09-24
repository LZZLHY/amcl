// wheel_dual_plane_differential_test.cpp — 滚轮两条平面的**差分**断言（计划 §91）
//
// ============================ 它证明什么 ============================
//
// 命题：**同一串滚轮样本喂给 legacy 与 typed 两条平面，产出的格数序列逐位相同。**
//
// 这条命题此前只能靠读代码，而那条声称已经错过一次：§83.9 之前有三处注释都写着
// "两条平面共用分格语义"，实际 legacy 是内联手写数学，一个字都没共用。收敛到
// `kGlfwPhysicalWheelPolicy` 之后仍然剩两处不对称，是 §91 的测绘才找出来的：
//   ① 拒绝路径上 legacy 把累加器**清零**、typed **保留** ⇒ 一个非法样本之后两条平面
//      的格数序列可以**永久分叉**，而两边各自的单元测试都是绿的。
//   ② 横轴与零样本的判定各写一遍，只是恰好等价。
// 现在两条平面调**同一个** `StepPhysicalWheel`，本文件把"同一个"变成可判定的。
//
// ============================ 它不证明什么（重要）============================
//
// ⚠️ **不是端到端等价。** `PlatformInputPhysicalRouteUsesTyped()` 读的是启动期闭锁的
// capability bit，**同一进程里两条平面结构上不能同时活**。所以"把同一串输入喂给两条完整
// ingress"在产品语义下**不存在** —— 那样写会得到一个断言了不可能发生的场景的测试，正是本仓
// 反复付学费的那一族。本文件刻意只在**加工段**（纯函数 + 各自累加器）这个层次做差分。
//
// ⚠️ **不覆盖到达时序。** legacy 在 NAPI 同步栈里逐样本进，typed 在 `glfwPollEvents` 里成批
// drain。host 里没有 ArkUI 派发节奏也没有帧节奏，构造出来的时序都是虚构的。滚轮不受影响
// （分格与时间无关），但视角受影响 —— 那条链的判据在计划 §89.7 / §90.4。
//
// ⚠️ **不覆盖 ABI 的 float 收窄。** typed 侧的 `pointerWheel.y` 是 `float`，legacy 侧是
// `double` 直传。`IsFinitePhysicalWheelSample` 保证收窄不溢出，但不保证**精确**：需要 24 位
// 以上尾数的值在两条平面会得到不同的 double。本文件因此只喂 float 可精确表示的值（物理滚轮
// 的 px 值都是小整数，这个前提在真机上成立），并把该残留显式记在这里而不是假装它不存在。

// ⭐ 2026-09-05 扩展：从"两条平面"扩到"三条消费端"。
// 原因写在第 13 组上方 —— 两条平面**都在 GLFW 里面**，而真正分叉的第三个维度
// （GLFW3 / LWJGL2 / SDL3）此前不在本文件的坐标系里，代价是一条 45 倍的可感知缺陷。

#include "../../platform/physical_wheel_quantizer.h"
#include "../../input/adapters/lwjgl2_event_translate.h"
#include "../../input/amcl_input_event.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

using namespace amcl::input;

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "WHEEL DUAL PLANE FAIL line " << line << ": " << expression
              << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

// 一条平面的完整状态：只有累加器。两条平面刻意各持一个（同一次滚动只会被一条平面拥有，
// 共享反而会让两条互相清零 —— 这条是产品的既有设计，不是测试的简化）。
struct Plane {
    double remainder = 0.0;
    std::vector<int32_t> detents;
    std::vector<PhysicalWheelStepStatus> statuses;

    void Feed(double x, double y) {
        PhysicalWheelStepOutcome step{};
        StepPhysicalWheel(remainder, x, y, kGlfwPhysicalWheelPolicy, &step);
        // 无条件写回 —— 与两个产品调用点逐字相同。若哪天有人在产品侧把它改成条件写回，
        // 本测试**抓不到**（它测的是共用函数）；抓那件事的是产品 TU 语法门禁与 code review。
        remainder = step.remainder;
        statuses.push_back(step.status);
        if (step.status == PhysicalWheelStepStatus::kEmit) {
            detents.push_back(step.glfwY);
        }
    }
};

void CheckIdentical(const Plane& a, const Plane& b, int line) {
    if (a.detents.size() != b.detents.size()) Fail("detent count differs", line);
    for (size_t i = 0; i < a.detents.size(); ++i) {
        if (a.detents[i] != b.detents[i]) Fail("detent value differs", line);
    }
    if (a.statuses.size() != b.statuses.size()) Fail("status count differs", line);
    for (size_t i = 0; i < a.statuses.size(); ++i) {
        if (a.statuses[i] != b.statuses[i]) Fail("status differs", line);
    }
    if (a.remainder != b.remainder) Fail("remainder differs", line);
}

}  // namespace

int main() {
    const double kNotch = 134.0;  // API 26 手机一格 ≈ 63vp × 2.125，float 可精确表示

    // 1. 正常滚动：两条平面逐位相同。
    {
        Plane legacy;
        Plane typed;
        const double sequence[] = {kNotch, kNotch, -kNotch, kNotch,
                                   -kNotch, -kNotch, 0.0, kNotch};
        for (double y : sequence) {
            legacy.Feed(0.0, y);
            typed.Feed(0.0, y);
        }
        CheckIdentical(legacy, typed, __LINE__);
        // 一格一格滚必须一格一格出，不多不少。
        CHECK(legacy.detents.size() == 7u);
        CHECK(legacy.detents[0] == -1 && legacy.detents[2] == 1);
    }

    // 2. ⭐ 本文件的核心：**非法样本之后两条平面不得分叉。**
    //    这是修之前唯一会红的一条 —— legacy 清零、typed 保留 ⇒ 此后每一格都错位。
    {
        Plane legacy;
        Plane typed;
        // 先攒一点不足一格的余量，让"清零 vs 保留"能产生可观测差异。
        legacy.Feed(0.0, 0.4);
        typed.Feed(0.0, 0.4);
        CHECK(legacy.remainder == typed.remainder);
        CHECK(legacy.remainder != 0.0);
        // 一个非有限样本。
        const double nan = std::numeric_limits<double>::quiet_NaN();
        legacy.Feed(0.0, nan);
        typed.Feed(0.0, nan);
        CHECK(legacy.statuses.back() == PhysicalWheelStepStatus::kRejectedValue);
        // 拒绝之后余量必须归零，且两条平面一致。
        CHECK(legacy.remainder == 0.0);
        CHECK(typed.remainder == 0.0);
        // 之后继续滚，格数序列仍然逐位相同。
        for (int i = 0; i < 5; ++i) {
            legacy.Feed(0.0, kNotch);
            typed.Feed(0.0, kNotch);
        }
        CheckIdentical(legacy, typed, __LINE__);
        CHECK(legacy.detents.size() == 5u);
    }

    // 3. 横轴：两条平面必须都整包拒收，且都归零余量。
    {
        Plane legacy;
        Plane typed;
        legacy.Feed(0.0, 0.4);
        typed.Feed(0.0, 0.4);
        legacy.Feed(7.0, kNotch);
        typed.Feed(7.0, kNotch);
        CHECK(legacy.statuses.back() == PhysicalWheelStepStatus::kRejectedAxis);
        CHECK(typed.statuses.back() == PhysicalWheelStepStatus::kRejectedAxis);
        CHECK(legacy.detents.empty() && typed.detents.empty());
        CheckIdentical(legacy, typed, __LINE__);
    }

    // 4. 零样本是合法的、不发边沿、且**保留**余量（与拒绝路径刻意不同）。
    {
        Plane p;
        p.Feed(0.0, 0.4);
        const double before = p.remainder;
        p.Feed(0.0, 0.0);
        CHECK(p.statuses.back() == PhysicalWheelStepStatus::kZeroSample);
        CHECK(p.remainder == before);
        CHECK(p.detents.empty());
    }

    // 5. 亚阈值累加：`DropOnCrossing` 下跨阈值后零头归零（通道契约，规范 §九）。
    {
        Plane p;
        p.Feed(0.0, 0.4);
        CHECK(p.statuses.back() == PhysicalWheelStepStatus::kAccumulated);
        p.Feed(0.0, 0.4);
        CHECK(p.detents.empty());
        p.Feed(0.0, 0.4);
        CHECK(p.detents.size() == 1u);
        CHECK(p.remainder == 0.0);
    }

    // 6. 一个事件最多一格：快滚不得一次甩出一串（`maxDetentsPerEvent = 1`）。
    {
        Plane p;
        p.Feed(0.0, 250.0);
        CHECK(p.detents.size() == 1u);
        CHECK(p.detents[0] == -1);
        CHECK(p.remainder == 0.0);
    }

    // 7. 负向对称。
    {
        Plane p;
        p.Feed(0.0, -250.0);
        CHECK(p.detents.size() == 1u);
        CHECK(p.detents[0] == 1);
    }

    // 8. nullptr 与非有限余量都 fail-closed，不得写调用方状态。
    {
        StepPhysicalWheel(0.0, 0.0, 1.0, kGlfwPhysicalWheelPolicy, nullptr);
        PhysicalWheelStepOutcome step{};
        step.glfwY = 91;
        StepPhysicalWheel(std::numeric_limits<double>::infinity(), 0.0, 1.0,
                          kGlfwPhysicalWheelPolicy, &step);
        CHECK(step.status == PhysicalWheelStepStatus::kRejectedValue);
        CHECK(step.remainder == 0.0);
        CHECK(step.glfwY == 0);
    }

    // 9. ⭐ ArkTS 两条滚轮通道进 typed 平面的往返恒等式（计划 §95.2）。
    //    那两条通道自己已经分好格（只发方向 ±1），而 typed 入口吃平台侧样本值并会**再分
    //    一次格**。`PlatformSampleFromGlfwScroll` 是那一步的逆，本组把它钉住。
    {
        for (int32_t n : {1, -1}) {
            PhysicalWheelStepOutcome step{};
            StepPhysicalWheel(
                0.0, 0.0,
                PlatformSampleFromGlfwScroll(n, kGlfwPhysicalWheelPolicy),
                kGlfwPhysicalWheelPolicy, &step);
            CHECK(step.status == PhysicalWheelStepStatus::kEmit);
            // 一格进 ⇒ 恰好同一格出：既不丢、不翻倍，**也不反向**。
            CHECK(step.glfwY == n);
            // 已分好格的样本是 stepPx 的整数倍 ⇒ 不得留下任何残量给下一格。
            CHECK(step.remainder == 0.0);
        }
    }

    // 10. ⭐ 负向对照：**不做**这一步换算会反向。它证明第 9 组不是恒真的。
    //     "滚轮方向相反"这条本仓已经真机否证过一次（计划 §83），所以这条对照必须在。
    {
        PhysicalWheelStepOutcome step{};
        StepPhysicalWheel(0.0, 0.0, 1.0, kGlfwPhysicalWheelPolicy, &step);
        CHECK(step.status == PhysicalWheelStepStatus::kEmit);
        CHECK(step.glfwY == -1);  // 直接把 yoffset 当样本值传就是这个结果
    }

    // 11. 往返恒等式**不依赖** `stepPx == 1.0`。这一条挡的是"改了策略常数、ArkTS 滚轮
    //     静默失效"：换算走 policy，所以它必须对任意 stepPx 成立。
    {
        GlfwScrollPolicy scaled = kGlfwPhysicalWheelPolicy;
        scaled.stepPx = 63.0;
        for (int32_t n : {1, -1}) {
            PhysicalWheelStepOutcome step{};
            StepPhysicalWheel(0.0, 0.0, PlatformSampleFromGlfwScroll(n, scaled),
                              scaled, &step);
            CHECK(step.status == PhysicalWheelStepStatus::kEmit);
            CHECK(step.glfwY == n);
            CHECK(step.remainder == 0.0);
        }
    }

    // 12. yoffset == 0 换算出来是零样本：不发边沿、保留余量（与第 4 组同一契约）。
    {
        PhysicalWheelStepOutcome step{};
        step.glfwY = 91;
        StepPhysicalWheel(
            0.25, 0.0, PlatformSampleFromGlfwScroll(0, kGlfwPhysicalWheelPolicy),
            kGlfwPhysicalWheelPolicy, &step);
        CHECK(step.status == PhysicalWheelStepStatus::kZeroSample);
        CHECK(step.remainder == 0.25);
        CHECK(step.glfwY == 0);
    }

    // ========================================================================
    // 13. ⭐⭐ **三条消费端的出线等价**（2026-09-05 新增，§7.5 第 1 条）
    //
    // 上面 1–12 组比的是"两条平面"，而两条平面**都在 GLFW 里面** —— 真正会分叉的第三个
    // 维度（GLFW3 / LWJGL2 / SDL3 三条消费链）此前不在本文件的坐标系里。
    // 代价是一条 45 倍的用户可感知缺陷：`backend_input_bridge.cpp` 的 `WheelSink` 只读了
    // `kGlfwPhysicalWheelPolicy` 四个字段里的一个，而 1–12 组全绿。
    // ⇒ 本组把"同一个平台样本，三条链送给 MC 的格数必须一致"变成机械判据。
    // ========================================================================
    {
        // 真机实测值（API 26 手机，AMCL_BACKEND_WHEELMAG）：一个物理格 = 恒定 45.0 px。
        const double kDevicePx = 45.0;

        // —— 链 ①：GLFW3（glfw_compat.cpp 的 typedWheelSink）——
        double glfwRemainder = 0.0;
        double gx = 0.0;
        double gy = 0.0;
        CHECK(WheelSamplePxFromUnit(0.0, kDevicePx, AMCL_INPUT_WHEEL_UNIT_PIXEL,
                                    kGlfwPhysicalWheelPolicy, &gx, &gy));
        PhysicalWheelStepOutcome glfwStep{};
        StepPhysicalWheel(glfwRemainder, gx, gy, kGlfwPhysicalWheelPolicy,
                          &glfwStep);
        glfwRemainder = glfwStep.remainder;
        CHECK(glfwStep.status == PhysicalWheelStepStatus::kEmit);

        // —— 链 ②：宿主 pull 通道（backend_input_bridge.cpp 的 WheelSink）——
        //    修复后它与链 ① 调**同一个** StepPhysicalWheel，各持一个累加器。
        double pullRemainder = 0.0;
        double px = 0.0;
        double py = 0.0;
        CHECK(WheelSamplePxFromUnit(0.0, kDevicePx, AMCL_INPUT_WHEEL_UNIT_PIXEL,
                                    kGlfwPhysicalWheelPolicy, &px, &py));
        PhysicalWheelStepOutcome pullStep{};
        StepPhysicalWheel(pullRemainder, px, py, kGlfwPhysicalWheelPolicy,
                          &pullStep);
        pullRemainder = pullStep.remainder;
        CHECK(pullStep.status == PhysicalWheelStepStatus::kEmit);

        // SDL3 拿到的就是这个值（patch 里 SDL_SendMouseWheel(..., wheelY, ...) 直传）。
        const double sdl3Out = static_cast<double>(pullStep.glfwY);

        // —— 链 ③：LWJGL2 出线（lwjgl2_event_translate.cpp）——
        //    它吃的是链 ② 放进 ABI 的连续格数，再逆变换回 px 并**又分一次格**。
        AmclBackendInputEvent ev{};
        ev.abiVersion = static_cast<uint16_t>(AMCL_BACKEND_INPUT_ABI_VERSION);
        ev.structSize = static_cast<uint16_t>(sizeof(ev));
        ev.eventType = AMCL_BACKEND_INPUT_EVENT_WHEEL;
        ev.wheelX = 0.0f;
        ev.wheelY = static_cast<float>(pullStep.glfwY);
        double l2Remainder = 0.0;
        double l2Next = 0.0;
        AmclLwjgl2WireEvent wire{};
        CHECK(amclTranslateBackendEventToLwjgl2(&ev, l2Remainder, &l2Next,
                                                &wire) == 1);
        l2Remainder = l2Next;
        CHECK(wire.type == AMCL_LWJGL2_WIRE_SCROLL_TYPED);

        // ⭐ 等价：一个物理格进 ⇒ 三条链都恰好一格出，且**符号相同**。
        CHECK(glfwStep.glfwY == pullStep.glfwY);
        CHECK(static_cast<double>(glfwStep.glfwY) == sdl3Out);
        CHECK(wire.i2 == glfwStep.glfwY);
        CHECK(glfwStep.glfwY == -1);  // 45px 向下滚 ⇒ GLFW yoffset = -1

        // ⭐ **负向对照：证明本组不是恒真的。**
        // 这是修复前 SDL 那条链真正用的数学（GlfwScrollDetentsFromWheelPx，只兑现
        // policy 四个字段里的 stepPx）。它必须给出一个**与上面三条都不同**的值 ——
        // 否则本组就是一个"不可能失败的门禁"，而那比没有门禁更糟（规范 §八 纪律 5）。
        double bx = 0.0;
        double by = 0.0;
        CHECK(GlfwScrollDetentsFromWheelPx(0.0, kDevicePx,
                                           kGlfwPhysicalWheelPolicy, &bx, &by));
        CHECK(by == -kDevicePx);                      // 旧实现：一格 = 45 格
        CHECK(by != static_cast<double>(glfwStep.glfwY));
        // 放大倍数就是那条真机缺陷的量级，钉住它以免有人"顺手"改回连续透传。
        CHECK(by / static_cast<double>(glfwStep.glfwY) == kDevicePx);
    }

    // 14. 三条链在**一整串**样本上仍然逐位一致（单点相等可能是巧合）。
    //     含亚阈值、零样本、反向与快滚，覆盖 policy 的全部四个字段。
    {
        // ⚠️ 亚阈值那三个必须用 0.4 而**不能**用某个"小一点的 px 值"：
        // `stepPx == 1.0` 之下，任何 |y| >= 1 的样本都当场出一格，累加器**永远不留残量**。
        // 这正是那个占位符的另一面 —— 45.0 也好 12.0 也好，走的都是同一条"立刻出格"的路，
        // 拿它们当亚阈值样本会让本组悄悄漏掉 Carry/Drop 语义（第一版就是这么写错的）。
        const double seq[] = {45.0, 45.0, -45.0, 0.0, 0.4, 0.4, 0.4,
                              -300.0, 45.0};
        double glfwRem = 0.0;
        double pullRem = 0.0;
        double l2Rem = 0.0;
        std::vector<int32_t> glfwOut;
        std::vector<int32_t> sdlOut;
        std::vector<int32_t> l2Out;

        for (double sample : seq) {
            double ax = 0.0;
            double ay = 0.0;
            CHECK(WheelSamplePxFromUnit(0.0, sample, AMCL_INPUT_WHEEL_UNIT_PIXEL,
                                        kGlfwPhysicalWheelPolicy, &ax, &ay));

            PhysicalWheelStepOutcome g{};
            StepPhysicalWheel(glfwRem, ax, ay, kGlfwPhysicalWheelPolicy, &g);
            glfwRem = g.remainder;
            if (g.status == PhysicalWheelStepStatus::kEmit) {
                glfwOut.push_back(g.glfwY);
            }

            PhysicalWheelStepOutcome p{};
            StepPhysicalWheel(pullRem, ax, ay, kGlfwPhysicalWheelPolicy, &p);
            pullRem = p.remainder;
            if (p.status != PhysicalWheelStepStatus::kEmit) continue;
            sdlOut.push_back(p.glfwY);

            AmclBackendInputEvent ev{};
            ev.abiVersion = static_cast<uint16_t>(AMCL_BACKEND_INPUT_ABI_VERSION);
            ev.structSize = static_cast<uint16_t>(sizeof(ev));
            ev.eventType = AMCL_BACKEND_INPUT_EVENT_WHEEL;
            ev.wheelX = 0.0f;
            ev.wheelY = static_cast<float>(p.glfwY);
            double next = 0.0;
            AmclLwjgl2WireEvent w{};
            if (amclTranslateBackendEventToLwjgl2(&ev, l2Rem, &next, &w) == 1) {
                l2Out.push_back(w.i2);
            }
            l2Rem = next;
        }

        CHECK(glfwRem == pullRem);
        CHECK(glfwOut.size() == sdlOut.size());
        CHECK(glfwOut.size() == l2Out.size());
        for (size_t i = 0; i < glfwOut.size(); ++i) {
            CHECK(glfwOut[i] == sdlOut[i]);
            CHECK(glfwOut[i] == l2Out[i]);
        }
        // 9 个样本 ⇒ 6 格：3 个整格 + 1 个零样本(不出) + 3 个 0.4 攒成 1 格 + 快滚 1 格
        // + 末尾 1 格。**快滚那一条（-300px）只出一格** —— maxDetentsPerEvent 在三条链
        // 上都生效，而这正是修复前 SDL 那条会甩出 300 格的地方。
        CHECK(glfwOut.size() == 6u);
        for (int32_t d : glfwOut) CHECK(d == 1 || d == -1);
        // 逐位期望值写死，防止"总数对了但顺序/符号错了"。
        const int32_t expect[] = {-1, -1, 1, -1, 1, -1};
        for (size_t i = 0; i < glfwOut.size(); ++i) CHECK(glfwOut[i] == expect[i]);
    }

    std::cout << "WHEEL DUAL PLANE DIFFERENTIAL PASS\n";
    return 0;
}
