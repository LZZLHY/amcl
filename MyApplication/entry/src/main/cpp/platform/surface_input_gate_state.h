#ifndef AMCL_SURFACE_INPUT_GATE_STATE_H
#define AMCL_SURFACE_INPUT_GATE_STATE_H

#include <array>
#include <cstddef>
#include <cstdint>

namespace amcl::input::surface_gate {

struct State {
    static constexpr std::size_t kRetiredIdentityCapacity = 256u;

    struct RetiredIdentity {
        void* component = nullptr;
        void* window = nullptr;
    };

    void* component = nullptr;
    void* window = nullptr;
    uint64_t publicationGeneration = 0;
    bool active = false;
    uint64_t notBeforeEventTimestampNs = 0;
    bool componentOnlyGenerationSafe = false;
    std::array<RetiredIdentity, kRetiredIdentityCapacity> retired{};
    std::size_t retiredCount = 0u;
};

// 墓碑池剩余容量。0 = 已耗尽 ⇒ `CanActivate` 对**任何**身份返回 false ⇒ 输入 gate 永久死亡
// （每条物理边沿都被 `GATE_REJECTED`），而那个状态此前零计数零日志。
// 阈值告警属调用方（`touch_input.cpp`）：本 TU 无锁、无 hilog，可主机侧完整测试。
// 因果、可达性与两档告警的理由见计划 §107.6。
inline std::size_t RetiredCapacityRemaining(const State& state) {
    return State::kRetiredIdentityCapacity >= state.retiredCount
        ? State::kRetiredIdentityCapacity - state.retiredCount
        : 0u;
}

inline bool IsRetired(const State& state, void* component, void* window) {
    for (std::size_t i = 0u; i < state.retiredCount; ++i) {
        const auto& identity = state.retired[i];
        if (identity.component == component && identity.window == window) {
            return true;
        }
    }
    return false;
}

inline bool IsRetiredComponent(const State& state, void* component) {
    if (!component) return false;
    for (std::size_t i = 0u; i < state.retiredCount; ++i) {
        if (state.retired[i].component == component) return true;
    }
    return false;
}

inline bool CanActivate(const State& state, void* component, void* window) {
    if (!component || !window ||
        state.retiredCount >= State::kRetiredIdentityCapacity ||
        IsRetired(state, component, window)) {
        return false;
    }
    // A second create for the exact active identity is indistinguishable from
    // pointer ABA because the platform callback carries no lifecycle token.
    return !state.active || state.component != component ||
           state.window != window;
}

inline void RetireCurrent(State& state) {
    if (state.component && state.window &&
        !IsRetired(state, state.component, state.window)) {
        if (state.retiredCount < State::kRetiredIdentityCapacity) {
            state.retired[state.retiredCount++] = {
                state.component, state.window};
        }
    }
    state.component = nullptr;
    state.window = nullptr;
    state.publicationGeneration = 0u;
    state.active = false;
    state.notBeforeEventTimestampNs = 0u;
    state.componentOnlyGenerationSafe = false;
}

inline bool Activate(State& state, void* component, void* window,
                     uint64_t publicationGeneration,
                     uint64_t notBeforeEventTimestampNs) {
    if (!CanActivate(state, component, window) ||
        publicationGeneration == 0u || notBeforeEventTimestampNs == 0u) {
        return false;
    }
    if (state.active) RetireCurrent(state);
    state.component = component;
    state.window = window;
    state.publicationGeneration = publicationGeneration;
    state.active = true;
    state.notBeforeEventTimestampNs = notBeforeEventTimestampNs;
    // A callback that carries only component can prove its generation solely
    // on the component's first surface identity. Reusing that component with a
    // new window remains ambiguous even though window-bearing callbacks are
    // protected by the full identity tombstone.
    state.componentOnlyGenerationSafe =
        !IsRetiredComponent(state, component);
    return true;
}

inline uint64_t Accept(const State& state, void* component, void* window,
                       bool requireWindow) {
    if (!state.active || !component || state.component != component ||
        state.publicationGeneration == 0) {
        return 0;
    }
    if (requireWindow && (!window || state.window != window)) return 0;
    return state.publicationGeneration;
}

inline void Invalidate(State& state) {
    // Destroy acceptance is authoritative. Erasing identity as well as active
    // prevents stale callbacks from passing if addresses are later reused.
    RetireCurrent(state);
}

inline bool AcceptEventTimestamp(const State& state,
                                 uint64_t acceptedGeneration,
                                 int64_t eventTimestampNs) {
    return state.active && acceptedGeneration != 0u &&
           state.publicationGeneration == acceptedGeneration &&
           state.notBeforeEventTimestampNs != 0u &&
           eventTimestampNs > 0 &&
           static_cast<uint64_t>(eventTimestampNs) >
               state.notBeforeEventTimestampNs;
}

inline bool AcceptComponentOnlyGeneration(const State& state,
                                          uint64_t acceptedGeneration) {
    return state.active && acceptedGeneration != 0u &&
           state.publicationGeneration == acceptedGeneration &&
           state.componentOnlyGenerationSafe;
}

using ClearMutation = uint64_t (*)(void* context,
                                   uint64_t expectedGeneration);

inline uint64_t CommitCurrentUpdate(
        State& state, void* component, void* window,
        uint64_t expectedGeneration, uint64_t nextGeneration,
        uint64_t notBeforeEventTimestampNs) {
    if (Accept(state, component, window, true) != expectedGeneration ||
        expectedGeneration == 0u || nextGeneration == 0u ||
        nextGeneration == expectedGeneration ||
        notBeforeEventTimestampNs == 0u) {
        return 0u;
    }
    state.publicationGeneration = nextGeneration;
    state.notBeforeEventTimestampNs = notBeforeEventTimestampNs;
    // A component-only callback has no token that distinguishes work queued
    // before this update from work sampled afterwards. Callers may re-authorize
    // timestamp-bearing events against the strict boundary; tokenless hover
    // remains fail-closed for typed routing.
    state.componentOnlyGenerationSafe = false;
    return nextGeneration;
}

inline uint64_t UpdateCurrent(State& state, void* component, void* window,
                              ClearMutation mutation, void* context,
                              uint64_t notBeforeEventTimestampNs) {
    if (!mutation) return 0;
    const uint64_t expected = Accept(state, component, window, true);
    if (expected == 0) return 0;
    const uint64_t next = mutation(context, expected);
    return CommitCurrentUpdate(
        state, component, window, expected, next,
        notBeforeEventTimestampNs);
}

inline uint64_t ClearCurrent(State& state, void* component, void* window,
                             ClearMutation mutation, void* context) {
    if (!mutation) return 0;
    const uint64_t expected = Accept(state, component, window, true);
    if (expected == 0) return 0;
    // Invalidate before the fallible publication mutation. Returning zero must
    // never resurrect a gate for an OS surface already reported destroyed.
    Invalidate(state);
    return mutation(context, expected);
}

// Authoritative replacement failure: an OS create/change has already said the
// old surface can no longer be trusted, but the new publication could not be
// installed. Identity matching is intentionally skipped; callers must use this
// only while holding the lifecycle gate lock. The old gate is invalidated even
// when broker cleanup itself fails.
inline uint64_t ClearActive(State& state, ClearMutation mutation, void* context,
                            uint64_t* outExpectedGeneration) {
    if (outExpectedGeneration) *outExpectedGeneration = 0u;
    if (!state.active || state.publicationGeneration == 0u) return 0u;
    const uint64_t expected = state.publicationGeneration;
    if (outExpectedGeneration) *outExpectedGeneration = expected;
    Invalidate(state);
    return mutation ? mutation(context, expected) : 0u;
}

}  // namespace amcl::input::surface_gate

#endif
