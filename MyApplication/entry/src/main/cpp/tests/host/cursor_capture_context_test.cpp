/** 平台capture准入独立于游戏intent：Unknown初始可请求，明确失焦/暂停/无surface不可。 */
#include "cursor_capture_context.h"
#include "cursor_capture_policy.h"
#include "input_cancel_reason.h"
#include "surface_input_gate_state.h"
#include "../../input/adapters/glfw_backend_lifecycle.h"
#include <cstdio>
#include <cstdlib>
#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); std::exit(1); } } while (0)
int main() {
    amcl::input::CursorCaptureContext context;
    CHECK(!context.CanLock());
    context.Surface(true);
    CHECK(context.CanLock());
    CHECK(!context.CanLock(false));
    CHECK(context.CanLock(true)); // Ability恢复，无额外component focus边沿。
    context.Focused(false);
    CHECK(!context.CanLock());
    CHECK(!context.CanLock(true)); // 明确组件blur仍有独立否决权。
    context.Focused(true);
    CHECK(context.CanLock());
    context.Paused(true);
    CHECK(!context.CanLock());
    context.Focused(true);
    CHECK(!context.CanLock());
    context.Paused(false);
    CHECK(context.CanLock());
    context.Surface(false);
    CHECK(!context.CanLock());
    context.Surface(true);
    CHECK(context.CanLock());
    const auto blocked = amcl::input::CursorCapturePublicationForResult(
        true, AMCL_CURSOR_LOCK_CONTEXT_INACTIVE);
    CHECK(blocked.requested && !blocked.active);
    CHECK(blocked.reason == AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST);

    namespace gate = amcl::input::surface_gate;
    gate::State surface;
    int component = 0, window = 0;
    CHECK(gate::Activate(surface, &component, &window, 1u, 1u));
    context.Focused(true);
    const auto canDeliverRelative = [&](bool foreground = true) {
        const auto result = gate::CurrentInputGeneration(surface) && context.CanLock(foreground)
            ? AMCL_CURSOR_LOCK_OK : AMCL_CURSOR_LOCK_CONTEXT_INACTIVE;
        const auto capture = amcl::input::CursorCapturePublicationForResult(true, result);
        amcl::input::GlfwBackendCaptureState backend{};
        amcl::input::GlfwApplyCaptureState(&backend, capture.requested, capture.active);
        return amcl::input::GlfwShouldDispatchRelative(backend, true, true);
    };
    CHECK(canDeliverRelative());
    // 同尺寸重放只暂停采样。复用生产取消判定，防止再次退休仍在使用的捕获表面。
    surface.geometryPending = true;
    if (amcl::input::InputCancelRetiresCaptureSurface(AMCL_INPUT_CANCEL_GEOMETRY_CHANGED)) {
        context.Surface(false);
    }
    CHECK(gate::Accept(surface, &component, &window, true) == 1u);
    CHECK(!canDeliverRelative());
    surface.geometryPending = false;
    CHECK(gate::CurrentInputGeneration(surface) == 1u);
    CHECK(!canDeliverRelative(false));
    CHECK(canDeliverRelative());

    // 期间收到的真实失焦独立生效，随后同一 surface 的新几何确认不能代替获焦。
    surface.geometryPending = true;
    context.Focused(false);
    CHECK(gate::CommitCurrentUpdate(surface, &component, &window, 1u, 2u, 2u) == 2u);
    CHECK(!canDeliverRelative());
    surface.geometryPending = false;
    CHECK(!canDeliverRelative());
    context.Focused(true);
    CHECK(canDeliverRelative());

    // 终局或真正销毁仍撤销捕获表面，清除几何暂停也不能恢复旧资格。
    CHECK(amcl::input::InputCancelRetiresCaptureSurface(AMCL_INPUT_CANCEL_SURFACE_LOST));
    CHECK(amcl::input::InputCancelRetiresCaptureSurface(AMCL_INPUT_CANCEL_PAGE_DISPOSE));
    context.Surface(false);
    CHECK(!canDeliverRelative());
    gate::Invalidate(surface);
    CHECK(gate::CurrentInputGeneration(surface) == 0u);
    std::puts("cursor_capture_context_test: all checks passed");
}
