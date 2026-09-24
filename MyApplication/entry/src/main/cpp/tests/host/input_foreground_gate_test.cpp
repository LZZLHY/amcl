#include "input_foreground_gate.h"

#include <cstddef>
#include <cstdio>
#include <iterator>

namespace {

using amcl::ohos::ComponentFocus;
using amcl::ohos::ComputeInputForegroundGate;

struct GateCase {
    bool surfacePublished;
    uint32_t abilityForegroundMask;
    ComponentFocus focus;
    bool expected;
};

constexpr GateCase kCases[] = {
    {false, 0u, ComponentFocus::Unknown, false},
    {false, 0u, ComponentFocus::Focused, false},
    {false, 0u, ComponentFocus::Blurred, false},
    {false, 1u, ComponentFocus::Unknown, false},
    {false, 1u, ComponentFocus::Focused, false},
    {false, 1u, ComponentFocus::Blurred, false},
    {true, 0u, ComponentFocus::Unknown, false},
    {true, 0u, ComponentFocus::Focused, false},
    {true, 0u, ComponentFocus::Blurred, false},
    {true, 1u, ComponentFocus::Unknown, true},
    {true, 1u, ComponentFocus::Focused, true},
    {true, 1u, ComponentFocus::Blurred, false},
    // Multiple Ability owners are still one current-state predicate: nonzero.
    {true, 3u, ComponentFocus::Unknown, true},
};

constexpr bool TruthTableMatches() {
    for (const GateCase& item : kCases) {
        if (ComputeInputForegroundGate(item.surfacePublished,
                                       item.abilityForegroundMask,
                                       item.focus) != item.expected) {
            return false;
        }
    }
    return true;
}

static_assert(TruthTableMatches(),
              "presented-input foreground truth table changed");

}  // namespace

int main() {
    for (std::size_t i = 0u; i < std::size(kCases); ++i) {
        const GateCase& item = kCases[i];
        const bool actual = ComputeInputForegroundGate(
            item.surfacePublished, item.abilityForegroundMask, item.focus);
        if (actual != item.expected) {
            std::fprintf(stderr,
                         "input foreground gate case %zu failed: got=%d expected=%d\n",
                         i, actual ? 1 : 0, item.expected ? 1 : 0);
            return 1;
        }
    }
    std::printf("input foreground gate: %zu cases passed\n",
                std::size(kCases));
    return 0;
}
