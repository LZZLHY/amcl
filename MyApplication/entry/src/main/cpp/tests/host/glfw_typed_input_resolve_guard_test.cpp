#include "../../input/adapters/glfw_typed_input_resolve_guard.h"

#include <atomic>
#include <cstdlib>
#include <iostream>
#include <thread>

using namespace amcl::input;

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "GLFW TYPED RESOLVE GUARD FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}

#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

struct FakeAdapter {
    bool hasConsumer = false;
    bool ready = false;
    int closeCalls = 0;
    int32_t closeStatus = 0;

    static bool HasConsumer(void* context) {
        return static_cast<FakeAdapter*>(context)->hasConsumer;
    }

    static int32_t Close(void* context) {
        auto& self = *static_cast<FakeAdapter*>(context);
        ++self.closeCalls;
        self.hasConsumer = false;
        self.ready = false;
        return self.closeStatus;
    }

    GlfwTypedInputRetireOps Ops() {
        return {this, HasConsumer, Close};
    }
};

void TestResolverFailureRetiresAndRecordsDiagnostics() {
    GlfwTypedInputResolveGuard guard;
    FakeAdapter adapter;
    adapter.hasConsumer = true;
    adapter.ready = true;
    adapter.closeStatus = 6;

    const GlfwTypedInputResolveResult result = guard.Apply(
        AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MALFORMED, nullptr, adapter.Ops());
    CHECK(result.outcome == GlfwTypedInputResolveOutcome::kResolveFailure);
    CHECK(result.failure == GlfwTypedInputResolveFailure::kResolverStatus);
    CHECK(result.failureCount == 1u);
    CHECK(result.adapterHadConsumer);
    CHECK(result.closeInvoked);
    CHECK(result.closeStatus == 6);
    CHECK(!adapter.ready);
    CHECK(!adapter.hasConsumer);
    CHECK(adapter.closeCalls == 1);

    const GlfwTypedInputResolveDiagnostics diagnostics = guard.Snapshot();
    CHECK(diagnostics.failureCount == 1u);
    CHECK(diagnostics.lastResolveStatus ==
          AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MALFORMED);
    CHECK(diagnostics.lastOutcome ==
          GlfwTypedInputResolveOutcome::kResolveFailure);
    CHECK(diagnostics.lastFailure ==
          GlfwTypedInputResolveFailure::kResolverStatus);
    CHECK(ShouldLogGlfwTypedInputResolveFailure(1u));
    CHECK(ShouldLogGlfwTypedInputResolveFailure(2u));
    CHECK(!ShouldLogGlfwTypedInputResolveFailure(3u));
    CHECK(ShouldLogGlfwTypedInputResolveFailure(4u));
    CHECK(!ShouldLogGlfwTypedInputResolveFailure(0u));
}

void TestLegacyCapabilityRetiresWithoutFault() {
    GlfwTypedInputResolveGuard guard;
    FakeAdapter adapter;
    AmclInputHostApiV1 legacyHost{};
    legacyHost.capabilityBits = 0u;
    // Cleanup authority follows the actual handle, not READY.  This models an
    // interrupted Open/Close that retained a consumer for a later retry.
    adapter.hasConsumer = true;
    adapter.ready = false;

    const GlfwTypedInputResolveResult result = guard.Apply(
        AMCL_INPUT_HOST_DESCRIPTOR_OK, &legacyHost, adapter.Ops());
    CHECK(result.outcome ==
          GlfwTypedInputResolveOutcome::kLegacyCapability);
    CHECK(result.failure == GlfwTypedInputResolveFailure::kNone);
    CHECK(result.failureCount == 0u);
    CHECK(result.adapterHadConsumer);
    CHECK(result.closeInvoked);
    CHECK(!adapter.ready);
    CHECK(!adapter.hasConsumer);
    CHECK(adapter.closeCalls == 1);

    const GlfwTypedInputResolveDiagnostics diagnostics = guard.Snapshot();
    CHECK(diagnostics.failureCount == 0u);
    CHECK(diagnostics.lastResolveStatus == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(diagnostics.lastOutcome ==
          GlfwTypedInputResolveOutcome::kLegacyCapability);
    CHECK(diagnostics.lastFailure == GlfwTypedInputResolveFailure::kNone);
}

void TestTypedCapabilityStaysOpen() {
    GlfwTypedInputResolveGuard guard;
    FakeAdapter adapter;
    AmclInputHostApiV1 typedHost{};
    typedHost.capabilityBits = AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE;
    adapter.hasConsumer = true;
    adapter.ready = true;

    const GlfwTypedInputResolveResult result = guard.Apply(
        AMCL_INPUT_HOST_DESCRIPTOR_OK, &typedHost, adapter.Ops());
    CHECK(result.outcome == GlfwTypedInputResolveOutcome::kTypedRoute);
    CHECK(result.failureCount == 0u);
    CHECK(!result.adapterHadConsumer);
    CHECK(!result.closeInvoked);
    CHECK(adapter.ready);
    CHECK(adapter.hasConsumer);
    CHECK(adapter.closeCalls == 0);
}

void TestImpossibleOkNullFailsClosed() {
    GlfwTypedInputResolveGuard guard;
    FakeAdapter adapter;
    adapter.hasConsumer = true;
    adapter.ready = true;

    const GlfwTypedInputResolveResult result = guard.Apply(
        AMCL_INPUT_HOST_DESCRIPTOR_OK, nullptr, adapter.Ops());
    CHECK(result.outcome == GlfwTypedInputResolveOutcome::kResolveFailure);
    CHECK(result.failure == GlfwTypedInputResolveFailure::kMissingHost);
    CHECK(result.failureCount == 1u);
    CHECK(result.closeInvoked);
    CHECK(!adapter.ready);

    const GlfwTypedInputResolveDiagnostics diagnostics = guard.Snapshot();
    CHECK(diagnostics.failureCount == 1u);
    CHECK(diagnostics.lastResolveStatus == AMCL_INPUT_HOST_DESCRIPTOR_OK);
    CHECK(diagnostics.lastFailure ==
          GlfwTypedInputResolveFailure::kMissingHost);
}

void TestConcurrentSnapshotIsCoherent() {
    GlfwTypedInputResolveGuard guard;
    AmclInputHostApiV1 legacyHost{};
    legacyHost.capabilityBits = 0u;
    const GlfwTypedInputRetireOps noAdapter{};
    std::atomic<bool> done{false};
    std::atomic<bool> invalidSnapshot{false};

    std::thread writer([&]() {
        for (int i = 0; i < 10000; ++i) {
            if ((i & 1) == 0) {
                (void)guard.Apply(AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MISSING,
                                  nullptr, noAdapter);
            } else {
                (void)guard.Apply(AMCL_INPUT_HOST_DESCRIPTOR_OK, &legacyHost,
                                  noAdapter);
            }
        }
        done.store(true, std::memory_order_release);
    });

    do {
        const GlfwTypedInputResolveDiagnostics snapshot = guard.Snapshot();
        const bool validFailure =
            snapshot.lastOutcome ==
                GlfwTypedInputResolveOutcome::kResolveFailure &&
            snapshot.lastFailure ==
                GlfwTypedInputResolveFailure::kResolverStatus &&
            snapshot.lastResolveStatus ==
                AMCL_INPUT_HOST_DESCRIPTOR_ERROR_MISSING;
        const bool validLegacy =
            snapshot.lastOutcome ==
                GlfwTypedInputResolveOutcome::kLegacyCapability &&
            snapshot.lastFailure == GlfwTypedInputResolveFailure::kNone &&
            snapshot.lastResolveStatus == AMCL_INPUT_HOST_DESCRIPTOR_OK;
        if (!validFailure && !validLegacy) {
            invalidSnapshot.store(true, std::memory_order_relaxed);
        }
    } while (!done.load(std::memory_order_acquire));

    writer.join();
    CHECK(!invalidSnapshot.load(std::memory_order_relaxed));
    const GlfwTypedInputResolveDiagnostics final = guard.Snapshot();
    CHECK(final.failureCount == 5000u);
    CHECK(final.lastOutcome ==
          GlfwTypedInputResolveOutcome::kLegacyCapability);
    CHECK(final.lastFailure == GlfwTypedInputResolveFailure::kNone);
}

}  // namespace

int main() {
    TestResolverFailureRetiresAndRecordsDiagnostics();
    TestLegacyCapabilityRetiresWithoutFault();
    TestTypedCapabilityStaysOpen();
    TestImpossibleOkNullFailsClosed();
    TestConcurrentSnapshotIsCoherent();
    std::cout << "glfw_typed_input_resolve_guard_test: PASS\n";
    return 0;
}
