/** 平台capture准入独立于游戏intent：Unknown初始可请求，明确失焦/暂停/无surface不可。 */
#include "cursor_capture_context.h"
#include "cursor_capture_policy.h"
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
    std::puts("cursor_capture_context_test: all checks passed");
}
