#include "adapters/glfw_typed_runtime_dispatch.h"

#include <cstdlib>
#include <iostream>
#include <mutex>
#include <shared_mutex>

using namespace amcl::input;

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "FAIL line " << line << ": " << expression << '\n';
    std::exit(1);
}

#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

struct DummyWindow {
    double cursorX = -1.0;
    double cursorY = -1.0;
    int mouseButtons[8]{};
};

struct LifecycleLocks {
    std::shared_mutex binding;
    std::shared_mutex publication;
    bool callbackRan = false;
    bool writerReentered = false;
    bool destroySimulated = false;
};

GlfwSurfaceSinkEvent Surface(uint64_t epoch, uint64_t publication,
                             uint32_t width = 800u,
                             uint32_t height = 600u) {
    GlfwSurfaceSinkEvent event{};
    event.surface.active = 1u;
    event.surface.widthPx = width;
    event.surface.heightPx = height;
    event.surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS |
        AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION;
    event.surface.publicationGeneration = publication;
    event.surfaceEpoch = epoch;
    event.sequence = 1u;
    return event;
}

GlfwAbsoluteSinkEvent Absolute(uint64_t sequence, uint64_t epoch,
                               uint64_t publication) {
    return {12.5, 13.5, 7u, sequence, epoch, publication};
}

GlfwButtonSinkEvent Button(int32_t button, GlfwInputAction action,
                           uint64_t sequence, uint64_t epoch,
                           bool requiresAbsolute) {
    return {button, action, 0u, 7u, sequence, epoch,
            requiresAbsolute};
}

GlfwTypedRuntimeTarget Target(DummyWindow& window, uint64_t generation,
                              uint32_t width = 800u,
                              uint32_t height = 600u,
                              bool active = true) {
    return {&window, &window.cursorX, &window.cursorY, window.mouseButtons,
            8u, generation, width, height, active};
}

GlfwTypedRuntimePublication Publication(uint64_t generation,
                                        uint32_t width = 800u,
                                        uint32_t height = 600u,
                                        bool active = true) {
    return {generation, width, height, active};
}

void SimulateDeferredDestroy(LifecycleLocks& locks, void* target) {
    locks.callbackRan = true;
    std::unique_lock<std::shared_mutex> binding(
        locks.binding, std::try_to_lock);
    std::unique_lock<std::shared_mutex> publication(
        locks.publication, std::try_to_lock);
    locks.writerReentered = binding.owns_lock() && publication.owns_lock();
    locks.destroySimulated = locks.writerReentered && target != nullptr;
}

void TestExactCommitAndDeferredNotification() {
    GlfwTypedAbsoluteRoute route;
    GlfwSourcePlaneAggregate aggregate;
    DummyWindow window;
    LifecycleLocks locks;
    route.ConsumeSurface(Surface(3u, 20u));

    GlfwTypedRuntimeAbsoluteCommit absoluteCommit{};
    CHECK(GlfwTypedRuntimeCommitAbsolute(
              route, Absolute(10u, 3u, 20u), Target(window, 20u),
              Publication(19u), absoluteCommit) ==
          GlfwTypedRuntimeCommitStatus::kTargetPublicationMismatch);
    CHECK(!absoluteCommit.notify);
    CHECK(window.cursorX == -1.0 && window.cursorY == -1.0);

    CHECK(GlfwTypedRuntimeCommitAbsolute(
              route, Absolute(11u, 3u, 20u), Target(window, 20u),
              Publication(20u, 801u, 600u), absoluteCommit) ==
          GlfwTypedRuntimeCommitStatus::kTargetPublicationMismatch);
    CHECK(!absoluteCommit.notify);
    CHECK(window.cursorX == -1.0 && window.cursorY == -1.0);

    {
        std::shared_lock<std::shared_mutex> binding(locks.binding);
        std::shared_lock<std::shared_mutex> publication(locks.publication);
        CHECK(GlfwTypedRuntimeCommitAbsolute(
                  route, Absolute(12u, 3u, 20u), Target(window, 20u),
                  Publication(20u), absoluteCommit) ==
              GlfwTypedRuntimeCommitStatus::kCommitted);
        CHECK(absoluteCommit.notify);
        CHECK(absoluteCommit.target == &window);
        CHECK(window.cursorX == 12.5 && window.cursorY == 13.5);
        // The shipping seam is callback-free: user notification is still
        // pending while both lifecycle read guards are held.
        CHECK(!locks.callbackRan);
    }
    SimulateDeferredDestroy(locks, absoluteCommit.target);
    CHECK(locks.callbackRan);
    CHECK(locks.writerReentered);
    CHECK(locks.destroySimulated);

    // A new surface publication between the accepted absolute sample and its
    // position-bound button clears the old authorization. The exact new target
    // cannot make the queued old-epoch button valid again.
    route.ConsumeSurface(Surface(4u, 21u));
    GlfwTypedRuntimeButtonCommit buttonCommit{};
    CHECK(GlfwTypedRuntimeCommitButton(
              route, aggregate, Button(0, GlfwInputAction::kPress,
                                       13u, 3u, true),
              Target(window, 21u), Publication(21u), buttonCommit) ==
          GlfwTypedRuntimeCommitStatus::kRouteRejected);
    CHECK(!buttonCommit.notify);
    CHECK(window.mouseButtons[0] == 0);
    CHECK(!aggregate.IsButtonPressed(0));

    // Even with an exact publication tuple, a BOUND mapping outside the
    // target polling array is rejected before aggregate ownership can change.
    CHECK(GlfwTypedRuntimeCommitAbsolute(
              route, Absolute(14u, 4u, 21u), Target(window, 21u),
              Publication(21u), absoluteCommit) ==
          GlfwTypedRuntimeCommitStatus::kCommitted);
    CHECK(GlfwTypedRuntimeCommitButton(
              route, aggregate, Button(8, GlfwInputAction::kPress,
                                       15u, 4u, true),
              Target(window, 21u), Publication(21u), buttonCommit) ==
          GlfwTypedRuntimeCommitStatus::kTargetPublicationMismatch);
    CHECK(!buttonCommit.notify);
    CHECK(!aggregate.IsButtonPressed(8));

    CHECK(GlfwTypedRuntimeCommitAbsolute(
              route, Absolute(20u, 4u, 21u), Target(window, 21u),
              Publication(21u), absoluteCommit) ==
          GlfwTypedRuntimeCommitStatus::kCommitted);
    locks.callbackRan = false;
    locks.writerReentered = false;
    locks.destroySimulated = false;
    {
        std::shared_lock<std::shared_mutex> binding(locks.binding);
        std::shared_lock<std::shared_mutex> publication(locks.publication);
        CHECK(GlfwTypedRuntimeCommitButton(
                  route, aggregate, Button(0, GlfwInputAction::kPress,
                                           21u, 4u, true),
                  Target(window, 21u), Publication(21u), buttonCommit) ==
              GlfwTypedRuntimeCommitStatus::kCommitted);
        CHECK(buttonCommit.notify);
        CHECK(window.mouseButtons[0] == 1);
        CHECK(!locks.callbackRan);
    }
    SimulateDeferredDestroy(locks, buttonCommit.target);
    CHECK(locks.writerReentered && locks.destroySimulated);

    // Grabbed/relative-mode physical buttons are intentionally unflagged. They
    // remain deliverable with no surface publication and also cancel any stale
    // absolute authorization.
    GlfwTypedRuntimeTarget unbound = Target(window, 0u, 0u, 0u, false);
    CHECK(GlfwTypedRuntimeCommitButton(
              route, aggregate, Button(1, GlfwInputAction::kPress,
                                       30u, 0u, false),
              unbound, {}, buttonCommit) ==
          GlfwTypedRuntimeCommitStatus::kCommitted);
    CHECK(buttonCommit.notify);
    CHECK(buttonCommit.target == &window);
    CHECK(buttonCommit.event.button == 1);
    CHECK(window.mouseButtons[1] == 1);

    CHECK(GlfwTypedRuntimeCommitButton(
              route, aggregate, Button(1, GlfwInputAction::kRelease,
                                       31u, 0u, false),
              unbound, {}, buttonCommit) ==
          GlfwTypedRuntimeCommitStatus::kCommitted);
    CHECK(buttonCommit.notify && window.mouseButtons[1] == 0);
    CHECK(GlfwTypedRuntimeCommitButton(
              route, aggregate, Button(0, GlfwInputAction::kRelease,
                                       32u, 0u, false),
              unbound, {}, buttonCommit) ==
          GlfwTypedRuntimeCommitStatus::kCommitted);
    CHECK(buttonCommit.notify && window.mouseButtons[0] == 0);

    // A missing target may discharge a teardown RELEASE, but it cannot create
    // an invisible typed owner that would suppress a later visible PRESS.
    CHECK(GlfwTypedRuntimeCommitButton(
              route, aggregate, Button(2, GlfwInputAction::kPress,
                                       40u, 0u, false),
              {}, {}, buttonCommit) ==
          GlfwTypedRuntimeCommitStatus::kTargetUnavailable);
    CHECK(!buttonCommit.notify);
    CHECK(!aggregate.IsButtonPressed(2));
    CHECK(GlfwTypedRuntimeCommitButton(
              route, aggregate, Button(2, GlfwInputAction::kPress,
                                       41u, 0u, false),
              unbound, {}, buttonCommit) ==
          GlfwTypedRuntimeCommitStatus::kCommitted);
    CHECK(buttonCommit.notify && aggregate.IsButtonPressed(2));
    CHECK(GlfwTypedRuntimeCommitButton(
              route, aggregate, Button(2, GlfwInputAction::kRelease,
                                       42u, 0u, false),
              {}, {}, buttonCommit) ==
          GlfwTypedRuntimeCommitStatus::kCommitted);
    CHECK(!buttonCommit.notify);
    CHECK(!aggregate.IsButtonPressed(2));
}

}  // namespace

int main() {
    TestExactCommitAndDeferredNotification();
    std::cout << "glfw_typed_runtime_dispatch_test: PASS\n";
    return 0;
}
