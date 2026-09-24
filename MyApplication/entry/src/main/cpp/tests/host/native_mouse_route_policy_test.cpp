#include "../../platform/native_mouse_route_policy.h"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>

using namespace amcl::input;

namespace {
[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "NATIVE MOUSE ROUTE POLICY FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)
}  // namespace

int main() {
    // Product/default capability OFF preserves both established source planes.
    CHECK(DecideNativeMouseDispatchRoute(
              false, true, false, NativeMouseSampleKind::Move) ==
          NativeMouseDispatchRoute::RelativeMoveOwner);
    CHECK(DecideNativeMouseDispatchRoute(
              false, true, false, NativeMouseSampleKind::ButtonEdge) ==
          NativeMouseDispatchRoute::ButtonOnly);

    // The optional absolute route is menu/normal only.
    CHECK(DecideNativeMouseDispatchRoute(
              true, true, false, NativeMouseSampleKind::Move) ==
          NativeMouseDispatchRoute::MenuAbsoluteMove);
    CHECK(DecideNativeMouseDispatchRoute(
              true, true, false, NativeMouseSampleKind::ButtonEdge) ==
          NativeMouseDispatchRoute::MenuAbsoluteButtonBatch);

    // Grabbed movement remains owned by raw relative; clicks remain button-only.
    CHECK(DecideNativeMouseDispatchRoute(
              true, true, true, NativeMouseSampleKind::Move) ==
          NativeMouseDispatchRoute::RelativeMoveOwner);
    CHECK(DecideNativeMouseDispatchRoute(
              true, true, true, NativeMouseSampleKind::ButtonEdge) ==
          NativeMouseDispatchRoute::ButtonOnly);

    // A missing bridge/SSOT snapshot never guesses that the menu is active.
    CHECK(DecideNativeMouseDispatchRoute(
              true, false, false, NativeMouseSampleKind::Move) ==
          NativeMouseDispatchRoute::RelativeMoveOwner);
    CHECK(DecideNativeMouseDispatchRoute(
              true, false, false, NativeMouseSampleKind::ButtonEdge) ==
          NativeMouseDispatchRoute::ButtonOnly);

    // SuppressNormalMouseSynthTouch 的四条断言已随该函数删除。它把"鼠标绝不能驱动
    // 虚拟控件"做成了依赖构建期证据位、且豁免 grabbed 模式的条件式；现在该约束在
    // OnDispatchTouchEvent 里无条件成立，没有可配置空间需要测试。

    ArktsPhysicalMotionState motion;
    ArktsPhysicalMotionSample sample{};
    sample.surfaceGeneration = 10u;
    sample.resetEpoch = 20u;
    sample.grabStateKnown = true;
    sample.windowX = 100.0;
    sample.windowY = 200.0;

    // Normal/menu routing is selected from the synchronous native SSOT, not an
    // asynchronous page observer. Verified native absolute suppresses ArkTS
    // window coordinates; default/off preserves the legacy menu position.
    auto decision = motion.Consume(sample);
    CHECK(decision.route == ArktsPhysicalMotionRoute::LegacyMenuAbsolute);
    CHECK(decision.first == 100.0 && decision.second == 200.0);
    sample.verifiedNativeAbsolute = true;
    decision = motion.Consume(sample);
    CHECK(decision.route ==
          ArktsPhysicalMotionRoute::NativeMenuAbsoluteOwner);

    // The same next sample becomes raw-relative immediately when the native
    // grab SSOT flips, even if ArkTS has not observed that transition yet.
    sample.grabbed = true;
    sample.rawDeltaPresent = true;
    sample.rawDx = 3.5;
    sample.rawDy = -4.5;
    sample.windowX = 103.5;
    sample.windowY = 195.5;
    decision = motion.Consume(sample);
    CHECK(decision.route == ArktsPhysicalMotionRoute::RawRelative);
    CHECK(decision.first == 3.5 && decision.second == -4.5);

    // If raw fields disappear, the baseline captured in the same authoritative
    // epoch yields only the explicitly unverified fallback.
    sample.rawDeltaPresent = false;
    sample.windowX = 105.0;
    sample.windowY = 198.0;
    decision = motion.Consume(sample);
    CHECK(decision.route ==
          ArktsPhysicalMotionRoute::UnverifiedRelativeFallback);
    CHECK(decision.first == 1.5 && decision.second == 2.5);

    // Surface, reset and grab-mode changes invalidate a derived baseline. The
    // first fallback sample after each boundary establishes position and drops.
    ++sample.surfaceGeneration;
    decision = motion.Consume(sample);
    CHECK(decision.route == ArktsPhysicalMotionRoute::Drop);
    sample.windowX = 108.0;
    decision = motion.Consume(sample);
    CHECK(decision.route ==
          ArktsPhysicalMotionRoute::UnverifiedRelativeFallback);
    CHECK(decision.first == 3.0 && decision.second == 0.0);
    ++sample.resetEpoch;
    decision = motion.Consume(sample);
    CHECK(decision.route == ArktsPhysicalMotionRoute::Drop);

    // Unknown grab state cannot guess menu mode, and a later known grabbed
    // fallback still starts with a new baseline.
    sample.grabStateKnown = false;
    decision = motion.Consume(sample);
    CHECK(decision.route == ArktsPhysicalMotionRoute::Drop);
    sample.grabStateKnown = true;
    decision = motion.Consume(sample);
    CHECK(decision.route == ArktsPhysicalMotionRoute::Drop);

    // Policy never sanitizes invalid producer values. It forwards them to the
    // selected ingress finite gate so diagnostics remain observable.
    sample.rawDeltaPresent = true;
    sample.rawDx = std::numeric_limits<double>::quiet_NaN();
    decision = motion.Consume(sample);
    CHECK(decision.route == ArktsPhysicalMotionRoute::RawRelative);
    CHECK(std::isnan(decision.first));
    sample.rawDeltaPresent = false;
    sample.windowX = std::numeric_limits<double>::infinity();
    decision = motion.Consume(sample);
    CHECK(decision.route ==
          ArktsPhysicalMotionRoute::UnverifiedRelativeFallback);
    CHECK(std::isinf(decision.first));

    std::cout << "native_mouse_route_policy_test: PASS\n";
    return 0;
}
