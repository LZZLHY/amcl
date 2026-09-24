#pragma once

#include <cstdint>

namespace amcl::input {

// Build-product identity is supplied by the ArkTS product source set before the
// game surface can publish input.  Native computes the policy again instead of
// trusting a bag of booleans crossing N-API, so desktop/mobile cannot disagree
// about the API 26 boundary.
enum class InputProductKind : uint32_t {
    kMobile = 0u,
    kDesktop = 1u,
    kDesktopTouch = 2u,
};

enum class ProductInputConfigureResult : int32_t {
    kApplied = 0,
    kUnchanged = 1,
    kInvalid = 2,
    kConflict = 3,
    // The ArkTS profile is internally valid, but contradicts the native
    // product identity compiled into a formal desktop binary.
    kBuildMismatch = 4,
};

struct ProductInputPolicySnapshot {
    bool configured = false;
    InputProductKind product = InputProductKind::kMobile;
    uint32_t runtimeApi = 0u;
    bool formalDesktop = false;
    bool compatibilityDesktop = false;
    bool mobileTouchFallback = false;
    bool acceptDirectTouchInGame = true;
    bool allowPlatformBackGesture = true;
    bool supportsRelativeMouse = false;
    bool supportsCursorLock = false;
    bool supportsHardwareRawMouse = false;
    bool notifyBackendFocus = false;
};

// Process-latched and idempotent.  A second, different identity is rejected:
// one libentry process must never change product semantics while input owners
// from the first page/session may still exist.
ProductInputConfigureResult ConfigureProductInputPolicy(
    InputProductKind product, uint32_t runtimeApi);

// Pure query used by the product handshake and host tests.  Ordinary mobile
// and compatibility binaries intentionally remain permissive for legacy
// source sets; a formal desktop binary accepts only Desktop + API 26 or newer.
bool ProductInputPolicyMatchesCompiledProduct(
    InputProductKind product, uint32_t runtimeApi);

ProductInputPolicySnapshot GetProductInputPolicy();

// Hot-path helper used by native XComponent touch ingress.  Unconfigured state
// preserves the historical mobile behaviour; desktop config is published from
// McGamePage before surface/listener setup, and tests verify the latch.
bool ProductAcceptsDirectTouchInGame();

// Host-test seam only.  Production code must never reset the process latch.
void ResetProductInputPolicyForTest();

} // namespace amcl::input
