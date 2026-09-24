// Builds and exercises input_trace.cpp with AMCL_INPUT_TRACE_SAMPLE_INTERVAL=0.
//
// Why this target exists: the periodic §11 sample line runs on the platform input
// callback, and the interval is the only thing keeping hilog from being written at
// input rate. The knob that silences it is compile-time, so without a target that
// actually sets it to 0 the "sampling can be turned off" claim would rest on
// reading the source rather than on a build. It also pins the behavioural
// contract that matters: disabling the periodic line must not change any counter,
// because §11 failures are reported through summaries and anomaly logs, which are
// not sampled. If turning sampling off could also suppress a counter, the knob
// would be a way to hide a regression.
//
// Deliberately does NOT assert anything about hilog output: the host build stubs
// OH_LOG_* to a no-op, so emission is unobservable here either way.

#include "input_trace.h"

#include "amcl_input_api.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "SAMPLE INTERVAL FAIL line " << line << ": " << expression
              << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

using amcl::input::trace::PhysicalIngressKind;

}  // namespace

int main() {
    static_assert(AMCL_INPUT_TRACE_SAMPLE_INTERVAL == 0,
                  "this target exists to cover the sampling-disabled build");

    amcl::input::trace::BeginSession(1u, 1u);

    // Every one of these calls MaybeSample() internally. With the interval at 0
    // the sample tick is never advanced and no periodic line is emitted, but the
    // counters behind the summary must be untouched by that.
    // Comfortably more than the default interval (256), so a build that ignored
    // the knob would have crossed the sampling boundary several times.
    const uint64_t iterations = 1000u;
    for (uint64_t i = 0; i < iterations; ++i) {
        amcl::input::trace::RecordSubmitted(AMCL_INPUT_OK);
        amcl::input::trace::RecordConsumed();
    }
    const auto submission =
        amcl::input::trace::TestCoreSubmissionSnapshot();
    CHECK(submission.submitted == iterations);
    CHECK(submission.errors == 0u);

    // Error and per-field accounting must survive with sampling off as well.
    amcl::input::trace::RecordSubmitted(AMCL_INPUT_ERROR_STALE);
    amcl::input::trace::RecordUnsupported();
    amcl::input::trace::RecordDiagnosticDrop();
    amcl::input::trace::RecordMissing(
        amcl::input::trace::MissingField::Device);
    const auto diagnostics =
        amcl::input::trace::TestCoreDiagnosticSnapshot();
    CHECK(diagnostics.unsupported == 1u);
    CHECK(diagnostics.diagnosticDrops == 1u);
    CHECK(amcl::input::trace::TestMissingFieldSnapshot().device == 1u);

    // Per-action bucketing is independent of sampling.
    amcl::input::trace::RecordPhysicalIngressOutcome(
        PhysicalIngressKind::Key, AMCL_LEGACY_PHYSICAL_EMITTED, 7u, 30u,
        AMCL_INPUT_ACTION_DOWN);
    amcl::input::trace::RecordPhysicalIngressOutcome(
        PhysicalIngressKind::Key, AMCL_LEGACY_PHYSICAL_EMITTED, 7u, 30u,
        AMCL_INPUT_ACTION_UP);
    amcl::input::trace::RecordPhysicalIngressOutcome(
        PhysicalIngressKind::Key, AMCL_LEGACY_PHYSICAL_INVALID_ACTION, 7u, 30u,
        99u);
    CHECK(amcl::input::trace::TestPhysicalActionCount(
              PhysicalIngressKind::Key, AMCL_INPUT_ACTION_DOWN) == 1u);
    CHECK(amcl::input::trace::TestPhysicalActionCount(
              PhysicalIngressKind::Key, AMCL_INPUT_ACTION_UP) == 1u);
    CHECK(amcl::input::trace::TestPhysicalActionCount(
              PhysicalIngressKind::Key, 0u) == 1u);

    // BeginSession clears everything, sampling state included.
    amcl::input::trace::BeginSession(1u, 2u);
    CHECK(amcl::input::trace::TestCoreSubmissionSnapshot().submitted == 0u);
    CHECK(amcl::input::trace::TestPhysicalActionCount(
              PhysicalIngressKind::Key, AMCL_INPUT_ACTION_DOWN) == 0u);
    CHECK(amcl::input::trace::TestPhysicalActionCount(
              PhysicalIngressKind::Key, 0u) == 0u);

    // Must remain callable with sampling disabled.
    amcl::input::trace::LogSessionSummary("sample-interval-zero");

    std::cout << "input trace sample interval zero test passed\n";
    return 0;
}
