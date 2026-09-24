#include "../../input/adapters/glfw_source_plane_aggregate.h"

#include <cstdlib>
#include <iostream>
#include <map>
#include <vector>

using namespace amcl::input;

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "GLFW SOURCE AGGREGATE FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

struct RuntimeHarness {
    GlfwSourcePlaneAggregate* aggregate = nullptr;
    std::map<int32_t, int32_t> keyPolling;
    std::map<int32_t, int32_t> buttonPolling;
    std::vector<GlfwAggregateKeyEvent> keyCallbacks;
    std::vector<GlfwAggregateButtonEvent> buttonCallbacks;
    bool callbackObservedCommittedState = true;

    static void Key(void* context, const GlfwAggregateKeyEvent& event) {
        auto& self = *static_cast<RuntimeHarness*>(context);
        const bool pressed = event.action != GlfwAggregateAction::kRelease;
        self.keyPolling[event.key] = pressed ? 1 : 0;
        // This reentrant polling query proves the aggregate lock is not held
        // while application callbacks run and state was committed first.
        self.callbackObservedCommittedState &=
            self.aggregate->IsKeyPressed(event.key) == pressed;
        self.keyCallbacks.push_back(event);
    }

    static void Button(void* context,
                       const GlfwAggregateButtonEvent& event) {
        auto& self = *static_cast<RuntimeHarness*>(context);
        const bool pressed = event.action != GlfwAggregateAction::kRelease;
        self.buttonPolling[event.button] = pressed ? 1 : 0;
        self.callbackObservedCommittedState &=
            self.aggregate->IsButtonPressed(event.button) == pressed;
        self.buttonCallbacks.push_back(event);
    }

    GlfwAggregateSink Sink() { return {this, Key, Button}; }
};

struct Fixture {
    GlfwSourcePlaneAggregate aggregate;
    RuntimeHarness runtime;

    Fixture() { runtime.aggregate = &aggregate; }
};

void TestDefaultLegacyCallbackAndPolling() {
    Fixture f;
    const auto sink = f.runtime.Sink();
    f.aggregate.SubmitKey(GlfwSourcePlane::kLegacy, 65, 30,
                          GlfwAggregateAction::kPress, 1, sink);
    f.aggregate.SubmitKey(GlfwSourcePlane::kLegacy, 65, 30,
                          GlfwAggregateAction::kPress, 1, sink);
    f.aggregate.SubmitKey(GlfwSourcePlane::kLegacy, 65, 30,
                          GlfwAggregateAction::kRepeat, 1, sink);
    CHECK(f.runtime.keyCallbacks.size() == 2u);
    CHECK(f.runtime.keyCallbacks[0].action == GlfwAggregateAction::kPress);
    CHECK(f.runtime.keyCallbacks[1].action == GlfwAggregateAction::kRepeat);
    CHECK(f.runtime.keyPolling[65] == 1);

    f.aggregate.SubmitKey(GlfwSourcePlane::kLegacy, 65, 30,
                          GlfwAggregateAction::kRelease, 0, sink);
    CHECK(f.runtime.keyCallbacks.size() == 3u);
    CHECK(f.runtime.keyCallbacks.back().action ==
          GlfwAggregateAction::kRelease);
    CHECK(f.runtime.keyPolling[65] == 0);

    f.aggregate.SubmitButton(GlfwSourcePlane::kLegacy, 0,
                             GlfwAggregateAction::kPress, 0, sink);
    f.aggregate.SubmitButton(GlfwSourcePlane::kLegacy, 0,
                             GlfwAggregateAction::kRepeat, 0, sink);
    f.aggregate.SubmitButton(GlfwSourcePlane::kLegacy, 0,
                             GlfwAggregateAction::kRelease, 0, sink);
    CHECK(f.runtime.buttonCallbacks.size() == 3u);
    CHECK(f.runtime.buttonPolling[0] == 0);
    CHECK(f.runtime.callbackObservedCommittedState);
}

void TestTypedThenLegacyReleaseOrders() {
    {
        Fixture f;
        const auto sink = f.runtime.Sink();
        f.aggregate.SubmitKey(GlfwSourcePlane::kTyped, 87, 17,
                              GlfwAggregateAction::kPress, 0, sink);
        f.aggregate.SubmitKey(GlfwSourcePlane::kLegacy, 87, 0,
                              GlfwAggregateAction::kPress, 0, sink);
        f.aggregate.SubmitKey(GlfwSourcePlane::kTyped, 87, 17,
                              GlfwAggregateAction::kRelease, 0, sink);
        CHECK(f.runtime.keyCallbacks.size() == 1u);
        CHECK(f.runtime.keyPolling[87] == 1);
        f.aggregate.SubmitKey(GlfwSourcePlane::kLegacy, 87, 0,
                              GlfwAggregateAction::kRelease, 0, sink);
        CHECK(f.runtime.keyCallbacks.size() == 2u);
        CHECK(f.runtime.keyCallbacks.back().scanCode == 17);
        CHECK(f.runtime.keyPolling[87] == 0);
    }
    {
        Fixture f;
        const auto sink = f.runtime.Sink();
        f.aggregate.SubmitKey(GlfwSourcePlane::kLegacy, 87, 0,
                              GlfwAggregateAction::kPress, 0, sink);
        f.aggregate.SubmitKey(GlfwSourcePlane::kTyped, 87, 19,
                              GlfwAggregateAction::kPress, 0, sink);
        f.aggregate.SubmitKey(GlfwSourcePlane::kLegacy, 87, 0,
                              GlfwAggregateAction::kRelease, 0, sink);
        CHECK(f.runtime.keyCallbacks.size() == 1u);
        CHECK(f.runtime.keyPolling[87] == 1);
        f.aggregate.SubmitKey(GlfwSourcePlane::kTyped, 87, 19,
                              GlfwAggregateAction::kRelease, 0, sink);
        CHECK(f.runtime.keyCallbacks.size() == 2u);
        CHECK(f.runtime.keyCallbacks.back().scanCode == 19);
        CHECK(f.runtime.keyPolling[87] == 0);
    }
}

void TestButtonCrossPlaneAggregation() {
    Fixture f;
    const auto sink = f.runtime.Sink();
    f.aggregate.SubmitButton(GlfwSourcePlane::kLegacy, 1,
                             GlfwAggregateAction::kPress, 0, sink);
    f.aggregate.SubmitButton(GlfwSourcePlane::kTyped, 1,
                             GlfwAggregateAction::kPress, 0, sink);
    f.aggregate.SubmitButton(GlfwSourcePlane::kLegacy, 1,
                             GlfwAggregateAction::kRelease, 0, sink);
    CHECK(f.runtime.buttonCallbacks.size() == 1u);
    CHECK(f.runtime.buttonPolling[1] == 1);
    f.aggregate.SubmitButton(GlfwSourcePlane::kTyped, 1,
                             GlfwAggregateAction::kRelease, 0, sink);
    CHECK(f.runtime.buttonCallbacks.size() == 2u);
    CHECK(f.runtime.buttonCallbacks.back().action ==
          GlfwAggregateAction::kRelease);
    CHECK(f.runtime.buttonPolling[1] == 0);
}

void TestDeferredButtonCommit() {
    Fixture f;
    GlfwAggregateButtonEvent emission{};

    CHECK(f.aggregate.CommitButton(
        GlfwSourcePlane::kTyped, 2, GlfwAggregateAction::kPress, 7,
        &emission));
    CHECK(emission.button == 2);
    CHECK(emission.action == GlfwAggregateAction::kPress);
    CHECK(emission.modifiers == 7);
    CHECK(f.aggregate.IsButtonPressed(2));
    CHECK(f.runtime.buttonCallbacks.empty());

    // Runtime notification is deliberately separate and can reenter the
    // aggregate only after the internal ownership commit has completed.
    RuntimeHarness::Button(&f.runtime, emission);
    CHECK(f.runtime.buttonCallbacks.size() == 1u);
    CHECK(f.runtime.callbackObservedCommittedState);

    CHECK(!f.aggregate.CommitButton(
        GlfwSourcePlane::kTyped, 2, GlfwAggregateAction::kPress, 0,
        &emission));
    CHECK(!f.aggregate.CommitButton(
        GlfwSourcePlane::kLegacy, 2, GlfwAggregateAction::kPress, 0,
        &emission));
    CHECK(!f.aggregate.CommitButton(
        GlfwSourcePlane::kTyped, 2, GlfwAggregateAction::kRelease, 0,
        &emission));
    CHECK(f.aggregate.IsButtonPressed(2));
    CHECK(f.aggregate.CommitButton(
        GlfwSourcePlane::kLegacy, 2, GlfwAggregateAction::kRelease, 0,
        &emission));
    CHECK(!f.aggregate.IsButtonPressed(2));
    CHECK(emission.action == GlfwAggregateAction::kRelease);

    // A missing output target is rejected before ownership mutation.
    CHECK(!f.aggregate.CommitButton(
        GlfwSourcePlane::kTyped, 3, GlfwAggregateAction::kPress, 0,
        nullptr));
    CHECK(!f.aggregate.IsButtonPressed(3));
}

void TestIndependentResetAndOverflowPlanes() {
    Fixture f;
    const auto sink = f.runtime.Sink();
    f.aggregate.SubmitKey(GlfwSourcePlane::kTyped, 65, 30,
                          GlfwAggregateAction::kPress, 0, sink);
    f.aggregate.SubmitKey(GlfwSourcePlane::kLegacy, 65, 0,
                          GlfwAggregateAction::kPress, 0, sink);
    f.aggregate.SubmitButton(GlfwSourcePlane::kTyped, 0,
                             GlfwAggregateAction::kPress, 0, sink);
    f.aggregate.SubmitButton(GlfwSourcePlane::kLegacy, 0,
                             GlfwAggregateAction::kPress, 0, sink);

    f.aggregate.ClearPlane(GlfwSourcePlane::kTyped, sink);
    CHECK(f.runtime.keyCallbacks.size() == 1u);
    CHECK(f.runtime.buttonCallbacks.size() == 1u);
    CHECK(f.runtime.keyPolling[65] == 1);
    CHECK(f.runtime.buttonPolling[0] == 1);

    f.aggregate.ClearPlane(GlfwSourcePlane::kLegacy, sink);
    CHECK(f.runtime.keyCallbacks.size() == 2u);
    CHECK(f.runtime.buttonCallbacks.size() == 2u);
    CHECK(f.runtime.keyPolling[65] == 0);
    CHECK(f.runtime.buttonPolling[0] == 0);

    // Reversing the reset order has the same single final RELEASE invariant.
    f.aggregate.SubmitKey(GlfwSourcePlane::kTyped, 66, 31,
                          GlfwAggregateAction::kPress, 0, sink);
    f.aggregate.SubmitKey(GlfwSourcePlane::kLegacy, 66, 0,
                          GlfwAggregateAction::kPress, 0, sink);
    f.aggregate.ClearPlane(GlfwSourcePlane::kLegacy, sink);
    CHECK(f.runtime.keyPolling[66] == 1);
    f.aggregate.ClearPlane(GlfwSourcePlane::kTyped, sink);
    CHECK(f.runtime.keyPolling[66] == 0);
}

void TestFailSafeAndUnknownEdges() {
    Fixture f;
    const auto sink = f.runtime.Sink();
    f.aggregate.SubmitKey(GlfwSourcePlane::kTyped, 70, 40,
                          GlfwAggregateAction::kRelease, 0, sink);
    f.aggregate.SubmitKey(GlfwSourcePlane::kTyped, 70, 40,
                          GlfwAggregateAction::kRepeat, 0, sink);
    CHECK(f.runtime.keyCallbacks.empty());

    f.aggregate.SubmitKey(GlfwSourcePlane::kTyped, 70, 40,
                          GlfwAggregateAction::kPress, 0, sink);
    f.aggregate.SubmitButton(GlfwSourcePlane::kLegacy, 4,
                             GlfwAggregateAction::kPress, 0, sink);
    f.aggregate.ClearAll(sink);
    CHECK(!f.aggregate.IsKeyPressed(70));
    CHECK(!f.aggregate.IsButtonPressed(4));
    CHECK(f.runtime.keyCallbacks.back().action ==
          GlfwAggregateAction::kRelease);
    CHECK(f.runtime.buttonCallbacks.back().action ==
          GlfwAggregateAction::kRelease);
    CHECK(f.runtime.callbackObservedCommittedState);

    f.aggregate.SubmitKey(GlfwSourcePlane::kLegacy, 71, 0,
                          GlfwAggregateAction::kPress, 0, sink);
    f.aggregate.Abandon();
    CHECK(!f.aggregate.IsKeyPressed(71));
}

}  // namespace

int main() {
    TestDefaultLegacyCallbackAndPolling();
    TestTypedThenLegacyReleaseOrders();
    TestButtonCrossPlaneAggregation();
    TestDeferredButtonCommit();
    TestIndependentResetAndOverflowPlanes();
    TestFailSafeAndUnknownEdges();
    std::cout << "glfw_source_plane_aggregate_test: PASS\n";
    return 0;
}
