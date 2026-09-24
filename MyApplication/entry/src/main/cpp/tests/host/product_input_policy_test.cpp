#include "../../platform/product_input_policy.h"
#include "host_test_check.h"
#include "../../input/runtime_desktop_capability.h"

#include <cstdlib>
#include <iostream>

using amcl::input::ConfigureProductInputPolicy;
using amcl::input::GetProductInputPolicy;
using amcl::input::InputProductKind;
using amcl::input::ProductAcceptsDirectTouchInGame;
using amcl::input::ProductInputConfigureResult;
using amcl::input::ResetProductInputPolicyForTest;

namespace {

void ExpectFormalDesktopApi26() {
    ResetProductInputPolicyForTest();
    CHECK(ConfigureProductInputPolicy(InputProductKind::kDesktop, 26u) ==
           ProductInputConfigureResult::kApplied);
    const auto p = GetProductInputPolicy();
    CHECK(p.configured);
    CHECK(p.formalDesktop);
    CHECK(!p.compatibilityDesktop);
    CHECK(!p.mobileTouchFallback);
    CHECK(!p.acceptDirectTouchInGame);
    CHECK(!p.allowPlatformBackGesture);
    CHECK(p.supportsRelativeMouse);
    CHECK(p.supportsCursorLock);
    CHECK(p.supportsHardwareRawMouse);
    CHECK(p.notifyBackendFocus);
    CHECK(!ProductAcceptsDirectTouchInGame());
}

void ExpectDesktopCompatibilityApi22To25() {
    for (uint32_t api = 22u; api <= 25u; ++api) {
        ResetProductInputPolicyForTest();
        CHECK(ConfigureProductInputPolicy(InputProductKind::kDesktop, api) ==
               ProductInputConfigureResult::kApplied);
        const auto p = GetProductInputPolicy();
        CHECK(!p.formalDesktop);
        CHECK(p.compatibilityDesktop);
        CHECK(!p.mobileTouchFallback);
        CHECK(!p.acceptDirectTouchInGame);
        CHECK(!p.allowPlatformBackGesture);
        CHECK(p.supportsRelativeMouse);
        CHECK(p.supportsCursorLock);
        CHECK(!p.supportsHardwareRawMouse);
        CHECK(p.notifyBackendFocus);
    }
}

void ExpectOldDesktopMobileFallback() {
    ResetProductInputPolicyForTest();
    CHECK(ConfigureProductInputPolicy(InputProductKind::kDesktop, 21u) ==
           ProductInputConfigureResult::kApplied);
    const auto p = GetProductInputPolicy();
    CHECK(!p.formalDesktop);
    CHECK(!p.compatibilityDesktop);
    CHECK(p.mobileTouchFallback);
    CHECK(p.acceptDirectTouchInGame);
    CHECK(p.allowPlatformBackGesture);
    CHECK(!p.supportsRelativeMouse);
    CHECK(!p.supportsCursorLock);
    CHECK(!p.supportsHardwareRawMouse);
    CHECK(!p.notifyBackendFocus);
}

void ExpectMobileDoesNotBecomeDesktopOnApi26() {
    ResetProductInputPolicyForTest();
    CHECK(ConfigureProductInputPolicy(InputProductKind::kMobile, 26u) ==
           ProductInputConfigureResult::kApplied);
    const auto p = GetProductInputPolicy();
    CHECK(!p.formalDesktop);
    CHECK(!p.compatibilityDesktop);
    CHECK(!p.mobileTouchFallback);
    CHECK(p.acceptDirectTouchInGame);
    CHECK(p.allowPlatformBackGesture);
    CHECK(p.supportsRelativeMouse);
    CHECK(p.supportsCursorLock);
    CHECK(!p.supportsHardwareRawMouse);
    CHECK(!p.notifyBackendFocus);
}

void ExpectLatchAndValidation() {
    ResetProductInputPolicyForTest();
    CHECK(ProductAcceptsDirectTouchInGame());
    CHECK(ConfigureProductInputPolicy(InputProductKind::kDesktop, 0u) ==
           ProductInputConfigureResult::kInvalid);
    CHECK(ConfigureProductInputPolicy(
               static_cast<InputProductKind>(99u), 26u) ==
           ProductInputConfigureResult::kInvalid);
    CHECK(ConfigureProductInputPolicy(InputProductKind::kDesktop, 26u) ==
           ProductInputConfigureResult::kApplied);
    CHECK(ConfigureProductInputPolicy(InputProductKind::kDesktop, 26u) ==
           ProductInputConfigureResult::kUnchanged);
    CHECK(ConfigureProductInputPolicy(InputProductKind::kMobile, 26u) ==
           ProductInputConfigureResult::kConflict);
    CHECK(GetProductInputPolicy().formalDesktop);
}

} // namespace

int main() {
    CHECK(amcl::input::DesktopRawCapabilityAllowed(true, 26, "2in1"));
    CHECK(!amcl::input::DesktopRawCapabilityAllowed(false, 26, "2in1"));
    CHECK(!amcl::input::DesktopRawCapabilityAllowed(true, 25, "2in1"));
    CHECK(!amcl::input::DesktopRawCapabilityAllowed(true, 26, "phone"));
    CHECK(!amcl::input::DesktopRawCapabilityAllowed(true, 26, nullptr));
    ResetProductInputPolicyForTest();
    CHECK(ConfigureProductInputPolicy(InputProductKind::kDesktopTouch, 26u) ==
          ProductInputConfigureResult::kApplied);
    CHECK(GetProductInputPolicy().acceptDirectTouchInGame);
    CHECK(GetProductInputPolicy().supportsHardwareRawMouse);
    ExpectFormalDesktopApi26();
    ExpectDesktopCompatibilityApi22To25();
    ExpectOldDesktopMobileFallback();
    ExpectMobileDoesNotBecomeDesktopOnApi26();
    ExpectLatchAndValidation();
    std::cout << "product_input_policy_test: PASS\n";
    return 0;
}
