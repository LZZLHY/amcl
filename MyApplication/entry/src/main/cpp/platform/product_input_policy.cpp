#include "product_input_policy.h"
#include "../input/runtime_desktop_capability.h"

#include <atomic>

#ifndef AMCL_INPUT_COMPILED_FORMAL_DESKTOP
#define AMCL_INPUT_COMPILED_FORMAL_DESKTOP 0
#endif
#ifndef AMCL_GLFW_API26_RAW_MOUSE_MOTION
#define AMCL_GLFW_API26_RAW_MOUSE_MOTION 0
#endif

namespace amcl::input {
namespace {

// 0 is the unconfigured sentinel.  API is restricted to 16 bits below, so the
// top marker makes every valid encoding non-zero and leaves comparison atomic.
constexpr uint64_t kConfiguredBit = uint64_t{1} << 63u;
constexpr uint64_t kProductShift = 32u;
constexpr uint32_t kMaxSupportedApiValue = 0xffffu;

std::atomic<uint64_t> gProductInputPolicy{0u};

bool IsKnownProduct(InputProductKind product) {
    return product == InputProductKind::kMobile ||
           product == InputProductKind::kDesktop ||
           product == InputProductKind::kDesktopTouch;
}

uint64_t Encode(InputProductKind product, uint32_t runtimeApi) {
    return kConfiguredBit |
           (static_cast<uint64_t>(product) << kProductShift) |
           static_cast<uint64_t>(runtimeApi);
}

ProductInputPolicySnapshot Decode(uint64_t encoded) {
    ProductInputPolicySnapshot policy;
    if ((encoded & kConfiguredBit) == 0u) return policy;

    policy.configured = true;
    policy.product = static_cast<InputProductKind>(
        static_cast<uint32_t>((encoded >> kProductShift) & 0xffu));
    policy.runtimeApi = static_cast<uint32_t>(encoded & 0xffffu);
    if (policy.product == InputProductKind::kMobile) {
        // Mobile/tablet keeps the existing touch frontend.  API 22 may improve
        // its external-mouse cursor lock, but it is not advertised as the
        // complete desktop raw-input product.
        policy.supportsRelativeMouse = policy.runtimeApi >= 22u;
        policy.supportsCursorLock = policy.runtimeApi >= 22u;
        return policy;
    }

    policy.formalDesktop = policy.runtimeApi >= 26u &&
        RuntimeDesktopRawCapability(AMCL_GLFW_API26_RAW_MOUSE_MOTION != 0);
    policy.compatibilityDesktop =
        policy.runtimeApi >= 22u && !policy.formalDesktop;
    policy.mobileTouchFallback = policy.runtimeApi < 22u;
    policy.acceptDirectTouchInGame = policy.mobileTouchFallback ||
        policy.product == InputProductKind::kDesktopTouch;
    policy.allowPlatformBackGesture = policy.acceptDirectTouchInGame;
    policy.supportsRelativeMouse = policy.runtimeApi >= 22u;
    policy.supportsCursorLock = policy.runtimeApi >= 22u;
    policy.supportsHardwareRawMouse = policy.formalDesktop;
    policy.notifyBackendFocus = policy.runtimeApi >= 22u;
    return policy;
}

} // namespace

ProductInputConfigureResult ConfigureProductInputPolicy(
    InputProductKind product, uint32_t runtimeApi) {
    if (!IsKnownProduct(product) || runtimeApi == 0u ||
        runtimeApi > kMaxSupportedApiValue) {
        return ProductInputConfigureResult::kInvalid;
    }
    if (!ProductInputPolicyMatchesCompiledProduct(product, runtimeApi)) {
        return ProductInputConfigureResult::kBuildMismatch;
    }

    const uint64_t desired = Encode(product, runtimeApi);
    uint64_t current = 0u;
    if (gProductInputPolicy.compare_exchange_strong(
            current, desired, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
        return ProductInputConfigureResult::kApplied;
    }
    return current == desired ? ProductInputConfigureResult::kUnchanged
                              : ProductInputConfigureResult::kConflict;
}

bool ProductInputPolicyMatchesCompiledProduct(
    InputProductKind product, uint32_t runtimeApi) {
#if AMCL_INPUT_COMPILED_FORMAL_DESKTOP
    return product == InputProductKind::kDesktop && runtimeApi >= 22u &&
           runtimeApi <= kMaxSupportedApiValue;
#else
    (void)product;
    (void)runtimeApi;
    return true;
#endif
}

ProductInputPolicySnapshot GetProductInputPolicy() {
    return Decode(gProductInputPolicy.load(std::memory_order_acquire));
}

bool ProductAcceptsDirectTouchInGame() {
    return GetProductInputPolicy().acceptDirectTouchInGame;
}

void ResetProductInputPolicyForTest() {
    gProductInputPolicy.store(0u, std::memory_order_release);
}

} // namespace amcl::input
