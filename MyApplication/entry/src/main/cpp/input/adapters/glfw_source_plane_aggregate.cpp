#include "glfw_source_plane_aggregate.h"

#include <array>
#include <cstddef>
#include <map>
#include <mutex>
#include <vector>

namespace amcl::input {
namespace {

constexpr size_t kPlaneCount = 2u;

bool PlaneIndex(GlfwSourcePlane plane, size_t* out) {
    if (!out) return false;
    const auto value = static_cast<uint32_t>(plane);
    if (value >= kPlaneCount) return false;
    *out = static_cast<size_t>(value);
    return true;
}

bool IsActionValid(GlfwAggregateAction action) {
    return action == GlfwAggregateAction::kRelease ||
           action == GlfwAggregateAction::kPress ||
           action == GlfwAggregateAction::kRepeat;
}

template <typename State>
bool AnyHeld(const State& state) {
    return state.held[0] || state.held[1];
}

void Dispatch(const GlfwAggregateSink& sink,
              const std::vector<GlfwAggregateKeyEvent>& keys,
              const std::vector<GlfwAggregateButtonEvent>& buttons) {
    for (const auto& event : keys) {
        if (sink.key) sink.key(sink.context, event);
    }
    for (const auto& event : buttons) {
        if (sink.button) sink.button(sink.context, event);
    }
}

}  // namespace

struct GlfwSourcePlaneAggregate::Impl {
    struct KeyState {
        std::array<bool, kPlaneCount> held{};
        int32_t scanCode = 0;
    };
    struct ButtonState {
        std::array<bool, kPlaneCount> held{};
    };

    mutable std::mutex mutex;
    std::map<int32_t, KeyState> keys;
    std::map<int32_t, ButtonState> buttons;
};

GlfwSourcePlaneAggregate::GlfwSourcePlaneAggregate()
    : impl_(std::make_unique<Impl>()) {}

GlfwSourcePlaneAggregate::~GlfwSourcePlaneAggregate() = default;

void GlfwSourcePlaneAggregate::SubmitKey(
        GlfwSourcePlane plane, int32_t key, int32_t scanCode,
        GlfwAggregateAction action, int32_t modifiers,
        const GlfwAggregateSink& sink) {
    size_t planeIndex = 0u;
    if (!PlaneIndex(plane, &planeIndex) || !IsActionValid(action)) return;

    std::vector<GlfwAggregateKeyEvent> emissions;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        auto found = impl_->keys.find(key);
        if (action == GlfwAggregateAction::kRelease) {
            if (found == impl_->keys.end() || !found->second.held[planeIndex]) {
                return;
            }
            found->second.held[planeIndex] = false;
            if (!AnyHeld(found->second)) {
                // Keep the aggregate's best nonzero scancode until the final
                // owner leaves. A virtual final release must not erase the raw
                // physical identity that established or joined this key.
                emissions.push_back({key, found->second.scanCode, action,
                                     modifiers});
                impl_->keys.erase(found);
            }
        } else if (action == GlfwAggregateAction::kPress) {
            auto [state, inserted] = impl_->keys.emplace(key, Impl::KeyState{});
            (void)inserted;
            if (state->second.held[planeIndex]) return;
            const bool wasHeld = AnyHeld(state->second);
            state->second.held[planeIndex] = true;
            if (scanCode != 0) state->second.scanCode = scanCode;
            if (!wasHeld) {
                emissions.push_back({key, state->second.scanCode, action,
                                     modifiers});
            }
        } else {
            // Repeat is an edge, never an owner acquisition. Accepting an
            // ownerless repeat would let a delayed old-plane packet enter the
            // new session without a matching PRESS.
            if (found == impl_->keys.end() || !found->second.held[planeIndex]) {
                return;
            }
            if (scanCode != 0) found->second.scanCode = scanCode;
            emissions.push_back({key, found->second.scanCode, action,
                                 modifiers});
        }
    }
    Dispatch(sink, emissions, {});
}

void GlfwSourcePlaneAggregate::SubmitButton(
        GlfwSourcePlane plane, int32_t button, GlfwAggregateAction action,
        int32_t modifiers, const GlfwAggregateSink& sink) {
    GlfwAggregateButtonEvent emission{};
    if (CommitButton(plane, button, action, modifiers, &emission) &&
        sink.button) {
        sink.button(sink.context, emission);
    }
}

bool GlfwSourcePlaneAggregate::CommitButton(
        GlfwSourcePlane plane, int32_t button, GlfwAggregateAction action,
        int32_t modifiers, GlfwAggregateButtonEvent* emission) {
    size_t planeIndex = 0u;
    if (!emission || !PlaneIndex(plane, &planeIndex) ||
        !IsActionValid(action)) {
        return false;
    }
    *emission = {};

    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        auto found = impl_->buttons.find(button);
        if (action == GlfwAggregateAction::kRelease) {
            if (found == impl_->buttons.end() ||
                !found->second.held[planeIndex]) {
                return false;
            }
            found->second.held[planeIndex] = false;
            if (!AnyHeld(found->second)) {
                *emission = {button, action, modifiers};
                impl_->buttons.erase(found);
                return true;
            }
        } else if (action == GlfwAggregateAction::kPress) {
            auto [state, inserted] = impl_->buttons.emplace(
                button, Impl::ButtonState{});
            (void)inserted;
            if (state->second.held[planeIndex]) return false;
            const bool wasHeld = AnyHeld(state->second);
            state->second.held[planeIndex] = true;
            if (!wasHeld) {
                *emission = {button, action, modifiers};
                return true;
            }
        } else {
            if (found == impl_->buttons.end() ||
                !found->second.held[planeIndex]) {
                return false;
            }
            *emission = {button, action, modifiers};
            return true;
        }
    }
    return false;
}

void GlfwSourcePlaneAggregate::ClearPlane(
        GlfwSourcePlane plane, const GlfwAggregateSink& sink) {
    size_t planeIndex = 0u;
    if (!PlaneIndex(plane, &planeIndex)) return;

    std::vector<GlfwAggregateKeyEvent> keys;
    std::vector<GlfwAggregateButtonEvent> buttons;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        for (auto it = impl_->keys.begin(); it != impl_->keys.end();) {
            if (!it->second.held[planeIndex]) {
                ++it;
                continue;
            }
            it->second.held[planeIndex] = false;
            if (AnyHeld(it->second)) {
                ++it;
                continue;
            }
            keys.push_back({it->first, it->second.scanCode,
                            GlfwAggregateAction::kRelease, 0});
            it = impl_->keys.erase(it);
        }
        for (auto it = impl_->buttons.begin(); it != impl_->buttons.end();) {
            if (!it->second.held[planeIndex]) {
                ++it;
                continue;
            }
            it->second.held[planeIndex] = false;
            if (AnyHeld(it->second)) {
                ++it;
                continue;
            }
            buttons.push_back({it->first, GlfwAggregateAction::kRelease, 0});
            it = impl_->buttons.erase(it);
        }
    }
    Dispatch(sink, keys, buttons);
}

void GlfwSourcePlaneAggregate::ClearAll(const GlfwAggregateSink& sink) {
    std::vector<GlfwAggregateKeyEvent> keys;
    std::vector<GlfwAggregateButtonEvent> buttons;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        for (const auto& entry : impl_->keys) {
            keys.push_back({entry.first, entry.second.scanCode,
                            GlfwAggregateAction::kRelease, 0});
        }
        for (const auto& entry : impl_->buttons) {
            buttons.push_back({entry.first, GlfwAggregateAction::kRelease, 0});
        }
        impl_->keys.clear();
        impl_->buttons.clear();
    }
    Dispatch(sink, keys, buttons);
}

void GlfwSourcePlaneAggregate::Abandon() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->keys.clear();
    impl_->buttons.clear();
}

bool GlfwSourcePlaneAggregate::IsKeyPressed(int32_t key) const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const auto found = impl_->keys.find(key);
    return found != impl_->keys.end() && AnyHeld(found->second);
}

bool GlfwSourcePlaneAggregate::IsButtonPressed(int32_t button) const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const auto found = impl_->buttons.find(button);
    return found != impl_->buttons.end() && AnyHeld(found->second);
}

}  // namespace amcl::input
