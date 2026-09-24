#include "amcl_input_api.h"
#include "input_trace.h"
#include "platform_input_ingress.h"

#include <cstdlib>
#include <iostream>
#include <limits>

namespace {
uint32_t gEnqueueCalls = 0;
uint32_t gPhysicalEnqueueCalls = 0;
uint32_t gKeyRouteCalls = 0;
uint32_t gButtonRouteCalls = 0;
uint32_t gWheelRouteCalls = 0;
double gLastDx = 0.0;
double gLastDy = 0.0;
int32_t gLastMappedControl = 0;
AmclLegacyPhysicalOutcome gNextKeyOutcome = AMCL_LEGACY_PHYSICAL_EMITTED;
AmclLegacyPhysicalOutcome gNextButtonOutcome = AMCL_LEGACY_PHYSICAL_EMITTED;

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "FAIL line " << line << ": " << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

bool AcceptRelativeFallback(double dx, double dy) {
    ++gEnqueueCalls;
    gLastDx = dx;
    gLastDy = dy;
    return true;
}

bool RejectRelativeFallback(double dx, double dy) {
    ++gEnqueueCalls;
    gLastDx = dx;
    gLastDy = dy;
    return false;
}

AmclLegacyPhysicalOutcome AcceptPhysicalRelative(double, double) {
    ++gPhysicalEnqueueCalls;
    return AMCL_LEGACY_PHYSICAL_EMITTED;
}

AmclLegacyPhysicalOutcome RejectPhysicalRelative(double, double) {
    ++gPhysicalEnqueueCalls;
    return AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED;
}

AmclLegacyPhysicalOutcome ControlledKeyRoute(
        uint64_t, uint32_t, int32_t mappedKey, int32_t, int32_t,
        int32_t, int32_t* routedMappedKey) {
    ++gKeyRouteCalls;
    gLastMappedControl = mappedKey;
    if (routedMappedKey) {
        *routedMappedKey =
            (gNextKeyOutcome == AMCL_LEGACY_PHYSICAL_EMITTED ||
             gNextKeyOutcome == AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE)
                ? 65
                : -1;
    }
    return gNextKeyOutcome;
}

AmclLegacyPhysicalOutcome ControlledButtonRoute(
        uint64_t, uint32_t, int32_t mappedButton, int32_t,
        int32_t* routedMappedButton) {
    ++gButtonRouteCalls;
    gLastMappedControl = mappedButton;
    if (routedMappedButton) {
        *routedMappedButton =
            (gNextButtonOutcome == AMCL_LEGACY_PHYSICAL_EMITTED ||
             gNextButtonOutcome == AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE)
                ? 0
                : -1;
    }
    return gNextButtonOutcome;
}

AmclLegacyPhysicalOutcome ControlledWheelRoute(
        double, double y, uint32_t* routedDetentCount) {
    ++gWheelRouteCalls;
    if (y < 8.0) {
        if (routedDetentCount) *routedDetentCount = 0u;
        return AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE;
    }
    if (routedDetentCount) *routedDetentCount = 1u;
    return AMCL_LEGACY_PHYSICAL_EMITTED;
}

void SelectLegacyWithoutShadow() {
#ifdef _WIN32
    CHECK(_putenv_s("AMCL_INPUT_SHADOW", "0") == 0);
    CHECK(_putenv_s("AMCL_GLFW_INPUT_BACKEND", "legacy") == 0);
#else
    CHECK(setenv("AMCL_INPUT_SHADOW", "0", 1) == 0);
    CHECK(setenv("AMCL_GLFW_INPUT_BACKEND", "legacy", 1) == 0);
#endif
}

AmclInputSnapshotV1 Snapshot(const AmclInputHostApiV1* api) {
    AmclInputSnapshotV1 value{};
    value.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    value.structSize = static_cast<uint16_t>(sizeof(value));
    CHECK(api->getSnapshot(&value) == AMCL_INPUT_OK);
    return value;
}

}  // namespace

int main() {
    SelectLegacyWithoutShadow();
    CHECK(!amcl::input::PlatformInputShadowEnabled());
    CHECK(!amcl::input::PlatformInputPhysicalRouteUsesTyped());
    CHECK(!amcl::input::PlatformInputCoreEnabled());
    CHECK(amcl::input::PlatformInputTextSessionSupported());
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    const auto before = Snapshot(api);

    amcl::input::PlatformInputSurfaceCreated(640u, 480u);
    amcl::input::PlatformInputSurfaceChanged(800u, 600u);
    amcl::input::PlatformInputFocusChanged(false);
    amcl::input::PlatformInputCaptureRequested(true);
    amcl::input::PlatformInputRequestReset(AMCL_INPUT_RESET_EXPLICIT);
    CHECK(amcl::input::PlatformInputPhysicalKey(
              1u, 2u, 3u, AMCL_INPUT_ACTION_DOWN, 4u, 5u, 6u, 7) == 0u);
    CHECK(amcl::input::PlatformInputPointerRelative(1.0, -1.0) == 0u);
    CHECK(amcl::input::PlatformInputPointerButton(
              6u, 1u, AMCL_INPUT_ACTION_DOWN, 0) == 0u);
    CHECK(amcl::input::PlatformInputPointerWheel(1.0f, -1.0f, true) == 0u);
    amcl::input::PlatformInputPointerEnter(true);
    amcl::input::PlatformInputTraceUnverifiedAbsolute();

    // Operational outcomes are process-wide and do not depend on a neutral
    // session. Unknown UP must still reach the identity helper in shadow0.
    using amcl::input::trace::PhysicalIngressKind;
    gNextKeyOutcome = AMCL_LEGACY_PHYSICAL_OWNERLESS_UP;
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              10u, 20u, 0u, AMCL_INPUT_ACTION_UP, 0u, 0u, 30u,
              0, 0, true, ControlledKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_OWNERLESS_UP);
    CHECK(gKeyRouteCalls == 1u);
    CHECK(gLastMappedControl == -1);
    CHECK(amcl::input::trace::TestPhysicalMappingUnavailableCount(
              PhysicalIngressKind::Key) == 1u);

    gNextKeyOutcome = AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT;
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              10u, 20u, 0u, AMCL_INPUT_ACTION_REPEAT, 0u, 0u, 30u,
              65, 2, true, ControlledKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT);
    gNextKeyOutcome = AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN;
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              10u, 20u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u, 30u,
              65, 1, true, ControlledKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN);
    const uint32_t keyCallsBeforeReject = gKeyRouteCalls;
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              10u, 20u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u, 30u,
              65, 0, true, ControlledKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_INVALID_ACTION);
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              10u, 20u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u, 30u,
              65, 1, false, ControlledKeyRoute) ==
          AMCL_LEGACY_PHYSICAL_GATE_REJECTED);
    CHECK(gKeyRouteCalls == keyCallsBeforeReject);
    CHECK(amcl::input::PlatformInputPhysicalKeyTransaction(
              10u, 20u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u, 30u,
              65, 1, true, nullptr) ==
          AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Key,
              AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT) == 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Key,
              AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN) == 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Key,
              AMCL_LEGACY_PHYSICAL_GATE_REJECTED) == 1u);

    gNextButtonOutcome = AMCL_LEGACY_PHYSICAL_UNKNOWN_CONTROL;
    CHECK(amcl::input::PlatformInputPhysicalButtonTransaction(
              31u, 2u, AMCL_INPUT_ACTION_DOWN, -1, 1, true,
              ControlledButtonRoute) == AMCL_LEGACY_PHYSICAL_UNKNOWN_CONTROL);
    CHECK(gButtonRouteCalls == 1u && gLastMappedControl == -1);
    CHECK(amcl::input::trace::TestPhysicalMappingUnavailableCount(
              PhysicalIngressKind::Button) == 1u);
    gNextButtonOutcome = AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE;
    CHECK(amcl::input::PlatformInputPhysicalButtonTransaction(
              31u, 2u, AMCL_INPUT_ACTION_UP, 0, 0, true,
              ControlledButtonRoute) ==
          AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE);
    CHECK(amcl::input::PlatformInputPhysicalButtonTransaction(
              31u, 2u, AMCL_INPUT_ACTION_UP, 0, 0, false,
              ControlledButtonRoute) == AMCL_LEGACY_PHYSICAL_GATE_REJECTED);
    CHECK(gButtonRouteCalls == 2u);

    CHECK(amcl::input::PlatformInputPhysicalWheelTransaction(
              0.0, 4.0, true, true, ControlledWheelRoute) ==
          AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE);
    CHECK(amcl::input::PlatformInputPhysicalWheelTransaction(
              0.0, 9.0, true, true, ControlledWheelRoute) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(amcl::input::PlatformInputPhysicalWheelTransaction(
              0.0, 9.0, true, true, nullptr) ==
          AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE);
    CHECK(amcl::input::PlatformInputPhysicalWheelTransaction(
              0.0, 9.0, true, false, ControlledWheelRoute) ==
          AMCL_LEGACY_PHYSICAL_GATE_REJECTED);
    CHECK(gWheelRouteCalls == 2u);

    const double invalid[] = {
        std::numeric_limits<double>::quiet_NaN(),
        std::numeric_limits<double>::infinity(),
        -std::numeric_limits<double>::infinity(),
    };
    for (double value : invalid) {
        CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
                  value, 1.0, true, AcceptPhysicalRelative) ==
              AMCL_LEGACY_PHYSICAL_INVALID_VALUE);
        CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
                  1.0, value, true, AcceptPhysicalRelative) ==
              AMCL_LEGACY_PHYSICAL_INVALID_VALUE);
    }
    CHECK(gPhysicalEnqueueCalls == 0u);
    auto physical =
        amcl::input::trace::TestPhysicalRelativeIngressSnapshot();
    CHECK(physical.invalidDelta == 6u);
    CHECK(physical.enqueueFailed == 0u);
    CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
              2.0, -3.0, true, AcceptPhysicalRelative) ==
          AMCL_LEGACY_PHYSICAL_EMITTED);
    CHECK(gPhysicalEnqueueCalls == 1u);
    CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
              -4.0, 5.0, true, RejectPhysicalRelative) ==
          AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED);
    CHECK(gPhysicalEnqueueCalls == 2u);
    CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
              4.0, 5.0, false, AcceptPhysicalRelative) ==
          AMCL_LEGACY_PHYSICAL_GATE_REJECTED);
    CHECK(amcl::input::PlatformInputPhysicalRelativeTransaction(
              4.0, 5.0, true, nullptr) ==
          AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE);
    CHECK(gPhysicalEnqueueCalls == 2u);
    physical = amcl::input::trace::TestPhysicalRelativeIngressSnapshot();
    CHECK(physical.invalidDelta == 6u);
    CHECK(physical.enqueueFailed == 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Relative,
              AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED) == 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Relative,
              AMCL_LEGACY_PHYSICAL_GATE_REJECTED) == 1u);
    CHECK(amcl::input::trace::TestPhysicalIngressOutcomeCount(
              PhysicalIngressKind::Relative,
              AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE) == 1u);

    using FallbackResult = amcl::input::PlatformInputRelativeFallbackResult;
    for (double value : invalid) {
        CHECK(amcl::input::PlatformInputUnverifiedRelativeFallbackTransaction(
                  value, 1.0, true, AcceptRelativeFallback) ==
              FallbackResult::InvalidDelta);
        CHECK(amcl::input::PlatformInputUnverifiedRelativeFallbackTransaction(
                  1.0, value, true, AcceptRelativeFallback) ==
              FallbackResult::InvalidDelta);
    }
    CHECK(gEnqueueCalls == 0u);
    CHECK(amcl::input::PlatformInputUnverifiedRelativeFallbackTransaction(
              4.5, -2.25, true, AcceptRelativeFallback) ==
          FallbackResult::Enqueued);
    CHECK(gEnqueueCalls == 1u && gLastDx == 4.5 && gLastDy == -2.25);
    CHECK(amcl::input::PlatformInputUnverifiedRelativeFallbackTransaction(
              0.0, 0.0, true, AcceptRelativeFallback) ==
          FallbackResult::ZeroDelta);
    CHECK(gEnqueueCalls == 1u);  // zero is selected but never injected
    CHECK(amcl::input::PlatformInputUnverifiedRelativeFallbackTransaction(
              -8.0, 3.0, true, RejectRelativeFallback) ==
          FallbackResult::EnqueueFailed);
    CHECK(gEnqueueCalls == 2u && gLastDx == -8.0 && gLastDy == 3.0);
    CHECK(amcl::input::PlatformInputUnverifiedRelativeFallbackTransaction(
              1.0, 1.0, false, AcceptRelativeFallback) ==
          FallbackResult::GateRejected);
    CHECK(gEnqueueCalls == 2u);  // rejected gate cannot select or inject a route

    const auto fallback = amcl::input::trace::TestRelativeFallbackSnapshot();
    CHECK(fallback.selected == 3u);
    CHECK(fallback.enqueued == 1u);
    CHECK(fallback.enqueueFailed == 1u);
    CHECK(fallback.zeroDelta == 1u);
    CHECK(fallback.typedRouteRejected == 0u);
    CHECK(fallback.gateRejected == 1u);
    CHECK(fallback.invalidDelta == 6u);
    CHECK(amcl::input::trace::TestReconciliationSnapshot().legacyFallback == 0u);
    amcl::input::PlatformInputSurfaceDestroyed();

    const auto after = Snapshot(api);
    // Typed text keeps only neutral lifecycle alive in legacy+shadow0; physical
    // transactions remain legacy-only; destroy closes text epoch + maintenance consumer.
    CHECK(after.sessionEpoch > before.sessionEpoch);
    CHECK(after.sessionActive == 0u);
    CHECK(after.consumerCount == 0u);
    CHECK(after.heldControlCount == 0u);
    CHECK(after.blobBytes == 0u);
    CHECK(before.sessionActive == 0u);
    CHECK(before.consumerCount == 0u);
    CHECK(before.heldControlCount == 0u);
    std::cout << "platform shadow-disabled test passed\n";
    return 0;
}
