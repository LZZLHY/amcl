// 验证生产几何事务的反例：旧请求/旧代次、实际尺寸不匹配、有限恢复、零面积与新资源。
// 不模拟GPU成功；configured与observe分别调用，保证请求数字不能自行获得图像资格。
#include "render_resolution_state.h"
#include <iostream>
#include <limits>

namespace {
int failures = 0;
void check(bool condition, const char* message) {
    if (!condition) { ++failures; std::cerr << "resolution state: " << message << '\n'; }
}
}

int main() {
    using namespace amcl::renderscale;
    ResolutionState state;
    state.beginLaunch(1.0);
    check(!state.hasConfirmedDuringLaunch(), "cold load has no runtime timeout eligibility");
    check(!state.virtualWindowManaged(), "native-only session preserves normal game window sizing");
    check(state.request(1.0, 2688, 1216), "native policy accepted");
    check(state.flags() == 1 && state.actualWidth() == 0, "request is not actual image");
    const auto initial = state.revision();
    check(!state.configured(0, initial), "zero generation cannot be committed");
    check(state.configured(3, initial), "configured publication accepted");
    check(state.flags() == 2 && state.actualWidth() == 0, "SET does not prove a drawable");
    check(!state.hasConfirmedDuringLaunch(), "producer/configuration before first frame is still cold load");
    check(!state.observe(2, 2688, 1216, 1), "old observation cannot confirm current geometry");
    check(state.observe(3, 2688, 1216, 1) && state.phase() == ResolutionPhase::kConfirmed, "EGL confirms native image");
    check(state.hasConfirmedDuringLaunch(), "matching actual starts runtime recovery eligibility");
    check(state.request(0.75, 2688, 1216), "75 percent requested");
    check(state.virtualWindowManaged(), "scaled session separates game size and physical host window");
    const auto first = state.revision();
    check(state.target().width == 2016 && state.target().height == 912, "phone target computed");
    check(state.request(0.75, 2688, 1216) && state.revision() == first, "same pending request is coalesced");
    check(state.request(0.5, 2688, 1216), "newest request replaces pending request");
    check(!state.configured(4, first) && state.flags() == 1, "old owner ACK cannot commit a newer request");
    check(state.configured(4, state.revision()), "latest request commits");
    check(!state.observe(3, 1344, 608, 2), "even matching pixels with old generation are rejected");
    check(state.observe(4, 1344, 608, 2) && state.actualWidth() == 1344, "Vulkan creation confirms actual extent");
    check(state.request(0.75, 2688, 1216) && state.configured(5, state.revision()), "next live transaction starts");
    for (uint32_t n = 0; n < ResolutionState::kMaxObservationAttempts; ++n) state.observe(5, 2688, 1216, 1);
    check(state.flags() == 1 && state.restoring() && state.target().scale == 0.5, "mismatch schedules only confirmed previous policy");
    check(state.desiredScale() == 0.75, "failed user intent remains visible while restoring");
    check(state.configured(6, state.revision()), "restore creates a new publication");
    check(state.phase() == ResolutionPhase::kRestoring, "restore is not success before actual confirmation");
    state.observe(6, 1344, 608, 1);
    check(state.phase() == ResolutionPhase::kRejected && state.actualWidth() == 1344, "rejected target reports confirmed restored image");
    const auto rejectedRevision = state.revision();
    state.displayChanged(2688, 1216);
    check(state.revision() == rejectedRevision && state.phase() == ResolutionPhase::kRejected, "duplicate platform callback cannot retry failed policy");
    state.request(0.75, 2688, 1216);
    state.configured(7, state.revision());
    for (uint32_t n = 0; n < ResolutionState::kMaxObservationAttempts; ++n) state.observe(7, 0, 0, 0);
    state.configured(8, state.revision());
    for (uint32_t n = 0; n < ResolutionState::kMaxObservationAttempts; ++n) state.observe(8, 0, 0, 0);
    check(state.phase() == ResolutionPhase::kRestartRequired && state.flags() == 0, "failed restore is terminal and bounded");
    state.suspend();
    check(state.hasConfirmedDuringLaunch(), "Home/surface suspension preserves runtime timeout eligibility only");
    check(state.generation() == 0 && state.actualWidth() == 0 && state.flags() == 0, "surface loss retires actual evidence");
    state.displayChanged(1216, 2688);
    check(state.target().width == 912 && state.target().height == 2016, "new physical region recalculates the user policy");
    state.configured(9, state.revision());
    for (uint32_t n = 0; n < ResolutionState::kMaxObservationAttempts; ++n) state.observe(9, 1216, 2688, 1);
    check(state.phase() == ResolutionPhase::kRestartRequired, "old resource cannot be borrowed for new resource rollback");
    const auto revision = state.revision();
    check(!state.request(std::numeric_limits<double>::quiet_NaN(), 1216, 2688) && state.revision() == revision, "invalid request cannot change policy identity");
    state.beginLaunch(0.75);
    check(!state.hasConfirmedDuringLaunch(), "new launch clears prior runtime timeout eligibility");
    state.displayChanged(2688, 1216);
    state.nativeFallback(2688, 1216, "initial-geometry-rejected");
    state.configured(10, state.revision());
    check(state.desiredScale() == 0.75 && state.phase() == ResolutionPhase::kRestoring, "initial fallback preserves requested policy");
    state.observe(10, 2688, 1216, 1);
    check(state.phase() == ResolutionPhase::kRejected, "initial fallback reports actual native image without claiming target success");
    state.request(1.0, 2688, 1216);
    check(state.virtualWindowManaged(), "100 percent does not reinterpret old saved windowed game dimensions as physical");
    state.beginLaunch(1.0);
    check(!state.virtualWindowManaged(), "fresh native-only session releases the virtual window policy");
    if (!failures) std::cout << "render_resolution_state_test: OK\n";
    return failures ? 1 : 0;
}
