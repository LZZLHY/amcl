#include "frame_stats_core.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>

namespace {

void require(bool condition, const char* message) {
    if (condition) return;
    std::cerr << "mg_frame_stats_core_test: FAIL: " << message << '\n';
    std::exit(1);
}

} // namespace

int main() {
    using mg::frame_stats::Category;
    using mg::frame_stats::ClientWaitFlagsClass;
    using mg::frame_stats::ClientWaitResultClass;
    using mg::frame_stats::ClientWaitTimeoutClass;
    using mg::frame_stats::Collector;
    using mg::frame_stats::Report;
    using mg::frame_stats::category;

    // A short interval keeps the test readable; production uses one second.
    Collector collector(50);
    Report report{};

    collector.presentBegin(90);
    require(!collector.presentEnd(100, report), "first present must only establish a frame boundary");

    collector.glEnter(110, "glDrawElementsInstancedBaseVertex");
    collector.glEnter(112, "glBufferSubData"); // nested forwarding must not become a second GL call
    collector.recordBufferBytes(999);
    collector.glExit(113);
    collector.glExit(120);

    collector.glEnter(130, "glNamedBufferSubData");
    collector.recordBufferBytes(4096);
    collector.glEnter(132, "glBufferSubData");
    collector.recordBufferBytes(4096); // inner annotation must not double-count
    collector.glExit(140);
    collector.glExit(150);

    collector.presentBegin(160);
    require(collector.presentEnd(170, report), "70 ns window must cross the 50 ns reporting interval");
    require(report.frames == 1, "one complete frame expected");
    require(report.frame_total_ns == 70, "frame boundary duration must be exact");
    require(report.counters.gl.calls == 2, "only outer public GL calls must be counted");
    require(report.counters.gl.total_ns == 30, "GL time must sum the two outer scopes");
    require(report.counters.outside_gl_ns == 30, "between-GL time must cover all three gaps");
    require(report.counters.present.total_ns == 10, "present duration must be measured separately");
    require(category(report, Category::Draw).calls == 1 && category(report, Category::Draw).total_ns == 10,
            "draw attribution must retain its duration");
    require(category(report, Category::BufferSubData).calls == 1 &&
                category(report, Category::BufferSubData).total_ns == 20,
            "nested buffer forwarding must remain one transfer");
    require(report.counters.buffer_bytes == 4096, "nested byte annotations must use first-writer ownership");
    require(report.sequence == 1, "the first completed reporting window must use sequence 1");

    Report next_report{};
    collector.presentBegin(220);
    require(collector.presentEnd(230, next_report), "the next reporting window must complete independently");
    require(next_report.sequence == 2, "report sequences must increase monotonically per collector");

    // Classification coverage for the synchronization groups used by the device
    // profiler. Each interval is one independent frame so the aggregate is clear.
    Collector sync_collector(1);
    sync_collector.presentBegin(0);
    require(!sync_collector.presentEnd(10, report), "sync collector first present primes only");
    sync_collector.glEnter(11, "glFenceSync");
    sync_collector.glExit(12);
    sync_collector.glEnter(13, "glClientWaitSync");
    sync_collector.glExit(15);
    sync_collector.glEnter(16, "glWaitSync");
    sync_collector.glExit(19);
    sync_collector.glEnter(20, "glFinish");
    sync_collector.glExit(24);
    sync_collector.presentBegin(25);
    require(sync_collector.presentEnd(30, report), "sync frame must report");
    require(category(report, Category::Fence).total_ns == 1, "fence duration classification");
    require(category(report, Category::ClientWait).total_ns == 2, "client-wait duration classification");
    require(category(report, Category::ServerWait).total_ns == 3, "server-wait duration classification");
    require(category(report, Category::Finish).total_ns == 4, "finish duration classification");

    // Every client-wait dimension receives the same elapsed sample. Cover all
    // timeout/flags/result classes, the fail-visible unclassified path, nested
    // wrapper ownership and first-writer semantics, then prove conservation back
    // to the legacy Category::ClientWait aggregate.
    constexpr std::uint32_t glAlreadySignaled = 0x911AU;
    constexpr std::uint32_t glTimeoutExpired = 0x911BU;
    constexpr std::uint32_t glConditionSatisfied = 0x911CU;
    constexpr std::uint32_t glWaitFailed = 0x911DU;
    constexpr std::uint64_t int64Max =
        static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
    constexpr std::uint64_t timeoutIgnored = std::numeric_limits<std::uint64_t>::max();

    Collector wait_collector(1);
    wait_collector.presentBegin(0);
    require(!wait_collector.presentEnd(10, report), "wait collector first present primes only");

    wait_collector.glEnter(11, "glClientWaitSync");
    wait_collector.recordClientWait(0, 0, glTimeoutExpired);
    wait_collector.glExit(13); // zero: 2 ns

    wait_collector.glEnter(14, "glClientWaitSync");
    wait_collector.recordClientWait(0, 17, glConditionSatisfied);
    wait_collector.glExit(17); // finite: 3 ns

    wait_collector.glEnter(18, "glClientWaitSync");
    wait_collector.recordClientWait(1, int64Max, glAlreadySignaled);
    wait_collector.glExit(22); // Long.MAX_VALUE: 4 ns

    wait_collector.glEnter(23, "glClientWaitSync");
    wait_collector.recordClientWait(1, timeoutIgnored, glWaitFailed);
    wait_collector.glExit(28); // GL_TIMEOUT_IGNORED: 5 ns

    wait_collector.glEnter(29, "glClientWaitSync");
    wait_collector.recordClientWait(2, int64Max + 1, 0xDEADU);
    wait_collector.glExit(35); // unusual-but-preserved values: 6 ns

    wait_collector.glEnter(36, "glClientWaitSync");
    wait_collector.glExit(43); // missing wrapper annotation: 7 ns

    wait_collector.glEnter(44, "glClientWaitSync");
    wait_collector.glEnter(45, "glClientWaitSync");
    wait_collector.recordClientWait(1, timeoutIgnored, glWaitFailed); // nested annotation must be ignored
    wait_collector.glExit(46);
    wait_collector.recordClientWait(0, 0, glConditionSatisfied);
    wait_collector.recordClientWait(1, timeoutIgnored, glWaitFailed); // first outer annotation wins
    wait_collector.glExit(52); // outer zero: 8 ns

    wait_collector.presentBegin(60);
    require(wait_collector.presentEnd(70, report), "client-wait frame must report");
    const auto& wait_total = category(report, Category::ClientWait);
    require(wait_total.calls == 7 && wait_total.total_ns == 35 && wait_total.max_ns == 8,
            "legacy client-wait aggregate must retain all samples");

    const auto& zero_wait = mg::frame_stats::clientWaitTimeout(report.counters, ClientWaitTimeoutClass::Zero);
    const auto& finite_wait = mg::frame_stats::clientWaitTimeout(report.counters, ClientWaitTimeoutClass::Finite);
    const auto& int64_wait = mg::frame_stats::clientWaitTimeout(report.counters, ClientWaitTimeoutClass::Int64Max);
    const auto& ignored_wait = mg::frame_stats::clientWaitTimeout(report.counters, ClientWaitTimeoutClass::Ignored);
    const auto& other_wait = mg::frame_stats::clientWaitTimeout(report.counters, ClientWaitTimeoutClass::Other);
    const auto& unknown_wait =
        mg::frame_stats::clientWaitTimeout(report.counters, ClientWaitTimeoutClass::Unclassified);
    require(zero_wait.calls == 2 && zero_wait.total_ns == 10 && zero_wait.max_ns == 8,
            "zero-timeout waits must include the nested-owner sample");
    require(finite_wait.calls == 1 && finite_wait.total_ns == 3, "finite timeout classification");
    require(int64_wait.calls == 1 && int64_wait.total_ns == 4, "Long.MAX_VALUE timeout classification");
    require(ignored_wait.calls == 1 && ignored_wait.total_ns == 5, "ignored timeout classification");
    require(other_wait.calls == 1 && other_wait.total_ns == 6, "other timeout classification");
    require(unknown_wait.calls == 1 && unknown_wait.total_ns == 7, "unclassified timeout visibility");

    const auto& flags_none = mg::frame_stats::clientWaitFlags(report.counters, ClientWaitFlagsClass::None);
    const auto& flags_flush = mg::frame_stats::clientWaitFlags(report.counters, ClientWaitFlagsClass::Flush);
    const auto& flags_other = mg::frame_stats::clientWaitFlags(report.counters, ClientWaitFlagsClass::Other);
    const auto& flags_unknown =
        mg::frame_stats::clientWaitFlags(report.counters, ClientWaitFlagsClass::Unclassified);
    require(flags_none.calls == 3 && flags_none.total_ns == 13, "flags=0 classification");
    require(flags_flush.calls == 2 && flags_flush.total_ns == 9, "flush flag classification");
    require(flags_other.calls == 1 && flags_other.total_ns == 6, "unexpected flags classification");
    require(flags_unknown.calls == 1 && flags_unknown.total_ns == 7, "unclassified flags visibility");

    const auto& already =
        mg::frame_stats::clientWaitResult(report.counters, ClientWaitResultClass::AlreadySignaled);
    const auto& satisfied =
        mg::frame_stats::clientWaitResult(report.counters, ClientWaitResultClass::ConditionSatisfied);
    const auto& timed_out =
        mg::frame_stats::clientWaitResult(report.counters, ClientWaitResultClass::TimeoutExpired);
    const auto& failed = mg::frame_stats::clientWaitResult(report.counters, ClientWaitResultClass::WaitFailed);
    const auto& result_other = mg::frame_stats::clientWaitResult(report.counters, ClientWaitResultClass::Other);
    const auto& result_unknown =
        mg::frame_stats::clientWaitResult(report.counters, ClientWaitResultClass::Unclassified);
    require(already.calls == 1 && already.total_ns == 4, "already-signaled result classification");
    require(satisfied.calls == 2 && satisfied.total_ns == 11, "condition-satisfied result classification");
    require(timed_out.calls == 1 && timed_out.total_ns == 2, "timeout result classification");
    require(failed.calls == 1 && failed.total_ns == 5, "wait-failed result classification");
    require(result_other.calls == 1 && result_other.total_ns == 6, "other result classification");
    require(result_unknown.calls == 1 && result_unknown.total_ns == 7, "unclassified result visibility");

    const auto requireConserved = [&wait_total](const auto& buckets, const char* message) {
        std::uint64_t calls = 0;
        std::uint64_t total_ns = 0;
        std::uint64_t max_ns = 0;
        for (const auto& bucket : buckets) {
            calls += bucket.calls;
            total_ns += bucket.total_ns;
            max_ns = std::max(max_ns, bucket.max_ns);
        }
        require(calls == wait_total.calls && total_ns == wait_total.total_ns && max_ns == wait_total.max_ns, message);
    };
    requireConserved(report.counters.client_wait.timeouts, "timeout buckets must conserve legacy aggregate");
    requireConserved(report.counters.client_wait.flags, "flags buckets must conserve legacy aggregate");
    requireConserved(report.counters.client_wait.results, "result buckets must conserve legacy aggregate");

    // Persistent staging was absent from the original targeted observer. Verify
    // map/flush/unmap attribution and byte ownership independently.
    Collector mapping_collector(1);
    mapping_collector.presentBegin(0);
    require(!mapping_collector.presentEnd(10, report), "mapping collector first present primes only");
    mapping_collector.glEnter(11, "glMapBufferRange");
    mapping_collector.recordBufferBytes(8192);
    mapping_collector.recordPersistentMap();
    mapping_collector.glExit(13);
    require(mapping_collector.causalCaptureActive(), "persistent map must arm causal capture");
    require(mapping_collector.shouldObserveCausal("glDrawElements"),
            "persistent map must expose its dependent draw window");
    mapping_collector.glEnter(14, "glFlushMappedBufferRange");
    mapping_collector.recordBufferBytes(4096);
    mapping_collector.recordExplicitFlush(false);
    mapping_collector.glExit(17);
    require(mapping_collector.causalCaptureActive(), "explicit flush must preserve causal capture");
    mapping_collector.glEnter(18, "glUnmapBuffer");
    mapping_collector.glExit(20);
    mapping_collector.presentBegin(21);
    require(mapping_collector.presentEnd(30, report), "mapping frame must report");
    require(category(report, Category::BufferMap).total_ns == 2 && report.counters.map_bytes == 8192,
            "map duration and bytes must be independent");
    require(category(report, Category::BufferFlush).total_ns == 3 && report.counters.flush_bytes == 4096,
            "flush duration and bytes must be visible");
    require(category(report, Category::BufferUnmap).total_ns == 2, "unmap duration classification");
    require((report.counters.event_mask & mg::frame_stats::EventPersistentMap) != 0 &&
                (report.counters.event_mask & mg::frame_stats::EventExplicitFlush) != 0,
            "persistent-map and explicit-flush events must survive reporting");

    // Terrain activity arms only causal groups. Ordinary state calls remain
    // untimed even inside the short window, while draw/FBO/dispatch become visible.
    Collector causal_collector(1);
    mg::frame_stats::FrameTrace trace{};
    causal_collector.presentBegin(0);
    require(!causal_collector.presentEnd(10, report, &trace), "causal collector first present primes only");
    require(!causal_collector.causalCaptureActive(), "capture starts disarmed");
    causal_collector.glEnter(11, "glBufferSubData");
    causal_collector.recordTerrainUpload(2048);
    causal_collector.glExit(12);
    require(causal_collector.causalCaptureActive(), "terrain upload must arm causal capture");
    require(causal_collector.shouldObserveCausal("glDrawElements"), "draw must be observed while armed");
    require(causal_collector.shouldObserveCausal("glBindFramebuffer"), "FBO bind must be observed while armed");
    require(!causal_collector.shouldObserveCausal("glUniform1f"), "ordinary state must stay unobserved");
    causal_collector.glEnter(13, "glDrawElements");
    causal_collector.glExit(20);
    causal_collector.presentBegin(25'000'000);
    require(causal_collector.presentEnd(30'000'010, report, &trace), "causal slow frame must report");
    require(trace.valid && trace.frame_ns == 30'000'000, "armed frame over 25 ms must produce a trace");
    require(trace.counters.terrain_calls == 1 && trace.counters.terrain_bytes == 2048,
            "trace must retain terrain trigger identity");
    require(category(trace, Category::Draw).calls == 1, "causal trace must include the dependent draw");
    require(trace.counters.slowest.name != nullptr, "trace must name the slowest observed operation");

    // A pre-1.20 vanilla client writes buffers only through glBufferData and
    // produces none of the four armCapture() signals, so while
    // Category::BufferAllocation was causal-only such a client reported
    // observed=0% with no way to attribute a slow frame. The category is
    // always-on now: timed with no window open, and able to arm the window
    // itself so the dependent draw becomes attributable.
    Collector alloc_collector(1);
    alloc_collector.presentBegin(0);
    require(!alloc_collector.presentEnd(10, report), "alloc collector first present primes only");
    require(!alloc_collector.causalCaptureActive(), "capture starts disarmed");
    require(!alloc_collector.shouldObserveCausal("glBufferData"),
            "allocation must not wait for a causal window to be timed");
    // kSlowSelectedCallNs is 1 ms, so this allocation is a slow selected call.
    alloc_collector.glEnter(11, "glBufferData");
    alloc_collector.glExit(1'000'011);
    require(alloc_collector.causalCaptureActive(),
            "a slow allocation must arm causal capture on an old-version client");
    require(alloc_collector.shouldObserveCausal("glDrawElements"),
            "the dependent draw must become observable after a slow allocation");
    require(!alloc_collector.shouldObserveCausal("glBufferData"),
            "always-on and causal policies must stay disjoint for one category");
    alloc_collector.presentBegin(1'000'020);
    require(alloc_collector.presentEnd(1'000'030, report), "allocation frame must report");
    require(category(report, Category::BufferAllocation).calls == 1 &&
                category(report, Category::BufferAllocation).total_ns == 1'000'000,
            "allocation duration must be timed without a causal window");

    // A slow frame containing no GL activity whatsoever must still arm the window.
    // This is precisely the case the four GL-event triggers cannot reach, and the
    // one measured on device: a 4315 ms frame whose 4239 ms was a single gap with
    // no always-on GL call in it. kUnarmedTraceFrameNs already traced such frames,
    // but with nothing armed every causal category in the trace read zero.
    Collector slow_frame_collector(1);
    slow_frame_collector.presentBegin(0);
    require(!slow_frame_collector.presentEnd(10, report), "slow-frame collector first present primes only");
    require(!slow_frame_collector.causalCaptureActive(), "capture starts disarmed");
    // No glEnter/glExit, no terrain upload, no persistent map, no explicit flush.
    slow_frame_collector.presentBegin(mg::frame_stats::kSlowFrameNs);
    require(slow_frame_collector.presentEnd(mg::frame_stats::kSlowFrameNs + 10, report),
            "slow frame must report");
    require(slow_frame_collector.causalCaptureActive(),
            "a slow frame with no GL events at all must arm the window by itself");
    require(slow_frame_collector.shouldObserveCausal("glDrawElements"),
            "the next frame's draws must become observable after a slow frame");
    require(!slow_frame_collector.shouldObserveCausal("glUniform1f"),
            "ordinary state must stay unobserved even inside a slow-frame window");

    // The bound that stops slow-frame arming from degenerating into exhaustive
    // timing. Every frame below is slow, so this also proves a sustained low-fps
    // client cannot hold the window permanently open: observation stays at
    // kCaptureFrames/(kCaptureFrames + kCaptureCooldownFrames) of frames.
    std::uint64_t at = mg::frame_stats::kSlowFrameNs + 10;
    const auto slowFrame = [&at, &slow_frame_collector, &report]() {
        at += mg::frame_stats::kSlowFrameNs;
        slow_frame_collector.presentBegin(at);
        slow_frame_collector.presentEnd(at + 10, report);
        at += 10;
    };
    slowFrame();
    require(slow_frame_collector.causalCaptureActive(), "the window must still be open on its second frame");
    slowFrame();
    require(!slow_frame_collector.causalCaptureActive(),
            "the window must close after kCaptureFrames frames");
    for (std::uint32_t i = 0; i + 1 < mg::frame_stats::kCaptureCooldownFrames; ++i) {
        slowFrame();
        require(!slow_frame_collector.causalCaptureActive(),
                "the cooldown must suppress re-arming even while frames stay slow");
    }
    slowFrame();
    require(slow_frame_collector.causalCaptureActive(),
            "the frame that ends the cooldown may arm again");

    std::cout << "mg_frame_stats_core_test: PASS\n";
    return 0;
}
