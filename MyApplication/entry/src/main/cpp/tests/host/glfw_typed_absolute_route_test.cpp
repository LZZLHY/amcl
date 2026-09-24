#include "../../input/adapters/glfw_typed_absolute_route.h"

#include <cstdlib>
#include <iostream>

using namespace amcl::input;

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "FAIL line " << line << ": " << expression << '\n';
    std::exit(1);
}

#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

GlfwSurfaceSinkEvent Surface(uint64_t epoch, uint64_t publication,
                             uint32_t width, uint32_t height) {
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

GlfwAbsoluteSinkEvent Absolute(uint64_t sequence, uint64_t device,
                               uint64_t epoch, uint64_t publication) {
    return {12.5, 13.5, device, sequence, epoch, publication};
}

GlfwButtonSinkEvent Button(uint64_t sequence, uint64_t device,
                           uint64_t epoch, bool requiresAbsolute = true) {
    return {0, GlfwInputAction::kPress, 0u, device, sequence, epoch,
            requiresAbsolute};
}

void TestFailClosedAndTransactionOrdering() {
    GlfwTypedAbsoluteRoute route;
    CHECK(!route.AcceptAbsolute(Absolute(10u, 7u, 3u, 20u),
                                20u, 800u, 600u));

    GlfwSurfaceSinkEvent missingGeneration = Surface(3u, 0u, 800u, 600u);
    route.ConsumeSurface(missingGeneration);
    CHECK(!route.AcceptAbsolute(Absolute(11u, 7u, 3u, 20u),
                                20u, 800u, 600u));

    route.ConsumeSurface(Surface(3u, 20u, 800u, 600u));
    CHECK(!route.AcceptAbsolute(Absolute(12u, 7u, 2u, 20u),
                                20u, 800u, 600u));
    CHECK(!route.AcceptAbsolute(Absolute(13u, 7u, 3u, 20u),
                                21u, 800u, 600u));
    CHECK(!route.AcceptAbsolute(Absolute(14u, 7u, 3u, 20u),
                                20u, 801u, 600u));

    CHECK(route.AcceptAbsolute(Absolute(15u, 7u, 3u, 20u),
                               20u, 800u, 600u));
    CHECK(route.AcceptButton(Button(16u, 7u, 3u), 20u, 800u, 600u));
    CHECK(!route.AcceptButton(Button(17u, 7u, 3u), 20u, 800u, 600u));

    CHECK(route.AcceptAbsolute(Absolute(20u, 7u, 3u, 20u),
                               20u, 800u, 600u));
    CHECK(!route.AcceptButton(Button(22u, 7u, 3u), 20u, 800u, 600u));
    CHECK(route.AcceptAbsolute(Absolute(23u, 7u, 3u, 20u),
                               20u, 800u, 600u));
    CHECK(!route.AcceptButton(Button(24u, 8u, 3u), 20u, 800u, 600u));
}

void TestRepublishInvalidatesQueuedAbsoluteAndAuthorization() {
    GlfwTypedAbsoluteRoute route;
    route.ConsumeSurface(Surface(3u, 20u, 800u, 600u));
    CHECK(route.AcceptAbsolute(Absolute(30u, 7u, 3u, 20u),
                               20u, 800u, 600u));

    route.ConsumeSurface(Surface(4u, 21u, 800u, 600u));
    CHECK(!route.AcceptButton(Button(31u, 7u, 3u), 21u, 800u, 600u));
    CHECK(!route.AcceptAbsolute(Absolute(32u, 7u, 3u, 20u),
                                21u, 800u, 600u));
    CHECK(route.AcceptAbsolute(Absolute(33u, 7u, 4u, 21u),
                               21u, 800u, 600u));
    CHECK(route.AcceptButton(Button(34u, 7u, 4u), 21u, 800u, 600u));

    route.Reset();
    CHECK(!route.AcceptAbsolute(Absolute(35u, 7u, 4u, 21u),
                                21u, 800u, 600u));
    CHECK(route.AcceptButton(Button(0u, 7u, 0u, false), 0u, 0u, 0u));
    CHECK(route.DropCount() >= 3u);
}

}  // namespace

int main() {
    TestFailClosedAndTransactionOrdering();
    TestRepublishInvalidatesQueuedAbsoluteAndAuthorization();
    std::cout << "glfw_typed_absolute_route_test: PASS\n";
    return 0;
}
