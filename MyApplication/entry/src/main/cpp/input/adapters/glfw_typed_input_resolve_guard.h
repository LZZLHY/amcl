#ifndef AMCL_GLFW_TYPED_INPUT_RESOLVE_GUARD_H
#define AMCL_GLFW_TYPED_INPUT_RESOLVE_GUARD_H

#include "../amcl_input_host_descriptor.h"

#include <cstdint>
#include <mutex>

namespace amcl::input {

// Descriptor resolution and product route selection are deliberately separate
// outcomes. A valid host without the typed-physical capability is the expected
// legacy product. Any resolver error (or an impossible OK/null result) is a
// fail-closed typed-consumer fault and must remain operationally observable.
enum class GlfwTypedInputResolveOutcome : uint32_t {
    kTypedRoute = 0u,
    kLegacyCapability = 1u,
    kResolveFailure = 2u,
};

enum class GlfwTypedInputResolveFailure : uint32_t {
    kNone = 0u,
    kResolverStatus = 1u,
    kMissingHost = 2u,
};

struct GlfwTypedInputResolveDiagnostics {
    uint64_t failureCount = 0u;
    int32_t lastResolveStatus = AMCL_INPUT_HOST_DESCRIPTOR_OK;
    GlfwTypedInputResolveOutcome lastOutcome =
        GlfwTypedInputResolveOutcome::kLegacyCapability;
    GlfwTypedInputResolveFailure lastFailure =
        GlfwTypedInputResolveFailure::kNone;
};

struct GlfwTypedInputRetireOps {
    void* context = nullptr;
    // A failed Open/Close can deliberately retain a non-ready consumer so the
    // adapter can retry protocol cleanup.  Route loss must retire that handle
    // too; IsReady alone would orphan the core's lifecycle gate.
    bool (*hasConsumer)(void* context) = nullptr;
    int32_t (*close)(void* context) = nullptr;
};

struct GlfwTypedInputResolveResult {
    GlfwTypedInputResolveOutcome outcome =
        GlfwTypedInputResolveOutcome::kResolveFailure;
    GlfwTypedInputResolveFailure failure =
        GlfwTypedInputResolveFailure::kNone;
    uint64_t failureCount = 0u;
    bool adapterHadConsumer = false;
    bool closeInvoked = false;
    int32_t closeStatus = 0;
};

inline bool ShouldLogGlfwTypedInputResolveFailure(uint64_t count) {
    return count != 0u && (count & (count - 1u)) == 0u;
}

class GlfwTypedInputResolveGuard {
public:
    GlfwTypedInputResolveResult Apply(
            int32_t resolveStatus, const AmclInputHostApiV1* host,
            const GlfwTypedInputRetireOps& retireOps) {
        GlfwTypedInputResolveResult result{};
        if (resolveStatus != AMCL_INPUT_HOST_DESCRIPTOR_OK) {
            result.outcome = GlfwTypedInputResolveOutcome::kResolveFailure;
            result.failure = GlfwTypedInputResolveFailure::kResolverStatus;
        } else if (host == nullptr) {
            // ResolveV1 promises a host on success. Treat a violated promise as
            // a consumer fault, never as permission to enable legacy input.
            result.outcome = GlfwTypedInputResolveOutcome::kResolveFailure;
            result.failure = GlfwTypedInputResolveFailure::kMissingHost;
        } else if ((host->capabilityBits &
                    AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE) != 0u) {
            result.outcome = GlfwTypedInputResolveOutcome::kTypedRoute;
        } else {
            result.outcome = GlfwTypedInputResolveOutcome::kLegacyCapability;
        }

        if (result.outcome != GlfwTypedInputResolveOutcome::kTypedRoute &&
            retireOps.hasConsumer != nullptr) {
            result.adapterHadConsumer =
                retireOps.hasConsumer(retireOps.context);
            if (result.adapterHadConsumer && retireOps.close != nullptr) {
                result.closeInvoked = true;
                result.closeStatus = retireOps.close(retireOps.context);
            }
        }

        // Retiring can dispatch aggregate releases. Never invoke those callbacks
        // while holding the diagnostics mutex; publish one coherent observation
        // only after the adapter operation is complete.
        {
            std::lock_guard<std::mutex> lock(diagnosticsMutex_);
            diagnostics_.lastResolveStatus = resolveStatus;
            diagnostics_.lastOutcome = result.outcome;
            diagnostics_.lastFailure = result.failure;
            if (result.outcome ==
                GlfwTypedInputResolveOutcome::kResolveFailure) {
                ++diagnostics_.failureCount;
            }
            result.failureCount = diagnostics_.failureCount;
        }
        return result;
    }

    GlfwTypedInputResolveDiagnostics Snapshot() const {
        std::lock_guard<std::mutex> lock(diagnosticsMutex_);
        return diagnostics_;
    }

private:
    mutable std::mutex diagnosticsMutex_;
    GlfwTypedInputResolveDiagnostics diagnostics_{};
};

}  // namespace amcl::input

#endif  // AMCL_GLFW_TYPED_INPUT_RESOLVE_GUARD_H
