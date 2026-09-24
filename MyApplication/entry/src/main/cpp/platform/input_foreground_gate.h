#ifndef AMCL_INPUT_FOREGROUND_GATE_H
#define AMCL_INPUT_FOREGROUND_GATE_H

#include <cstdint>

namespace amcl::ohos {

// Focus is deliberately three-valued. Unknown means that no accepted component
// focus edge has been observed for the current surface; it must not be confused
// with an explicit blur or activation would once again depend on one lossy edge.
enum class ComponentFocus : uint8_t {
    Unknown,
    Focused,
    Blurred,
};

// The presented-input foreground gate follows the current-state contract from
// SDL3_OPENHARMONY_HYBRID_MULTI_WINDOW_PLAN.md §8.5. Component focus can
// explicitly veto input, but its absence is not a veto: Ability foreground and
// a published host surface are the continuously queryable activation authority.
constexpr bool ComputeInputForegroundGate(bool surfacePublished,
                                          uint32_t abilityForegroundMask,
                                          ComponentFocus focus) {
    if (!surfacePublished) return false;
    if (abilityForegroundMask == 0u) return false;
    return focus != ComponentFocus::Blurred;
}

// Ability lifecycle already owns the authoritative foreground source mask for
// frame-rate policy. Re-publish that same current value to the presented-input
// gate instead of creating a second ArkTS-to-native foreground channel.
void PublishInputForegroundGateForAbility(uint32_t abilityForegroundMask,
                                          const char* reason);

}  // namespace amcl::ohos

#endif  // AMCL_INPUT_FOREGROUND_GATE_H
