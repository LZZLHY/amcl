// ohos_surface_state.h - pure NativeWindow generation transition policy.
#ifndef AMCL_OHOS_SURFACE_STATE_H
#define AMCL_OHOS_SURFACE_STATE_H

#include <cstdint>

namespace amcl::ohos {

enum class SurfaceTransition {
    Unchanged,
    Lost,
    Acquired,
    Replaced,
    Resized,
    MetadataOnly,
};

struct SurfaceState {
    uintptr_t window;
    int width;
    int height;
    uint64_t generation;
};

constexpr bool IsPublishedSurfaceReady(const SurfaceState &state) {
    return state.window != 0 && state.width > 0 && state.height > 0;
}

constexpr SurfaceTransition
DecideSurfaceTransition(const SurfaceState &consumed,
                        const SurfaceState &published) {
    if (published.generation == 0 ||
        published.generation <= consumed.generation) {
        return SurfaceTransition::Unchanged;
    }
    if (!IsPublishedSurfaceReady(published)) {
        return SurfaceTransition::Lost;
    }
    if (consumed.window == 0) {
        return SurfaceTransition::Acquired;
    }
    if (consumed.window != published.window) {
        return SurfaceTransition::Replaced;
    }
    if (consumed.width != published.width ||
        consumed.height != published.height) {
        return SurfaceTransition::Resized;
    }
    return SurfaceTransition::MetadataOnly;
}

// A failed attach must remain retryable even after its publication generation
// has already been consumed.
// ⚰️ 墓碑: 参数 contextOwned/presentationCheckpoint/zinkBackend 已删除（zink 退役后
//    zinkBackend 恒 false，另两个不再被读取），详见施工记录 §S7.2。
constexpr bool ShouldRetrySurfaceAttach(SurfaceTransition transition,
                                        bool publishedReady,
                                        bool backendReady) {
    const bool sameEpoch = transition == SurfaceTransition::Unchanged ||
                           transition == SurfaceTransition::MetadataOnly;
    return publishedReady && sameEpoch && !backendReady;
}

// ⚰️ 墓碑: ShouldClearContextOwnerOnSurfaceLoss(bool) 已删除（zink 退役后恒真，
//    调用点改为无条件 clear），详见施工记录 §S7.2。

static_assert(DecideSurfaceTransition({1, 1920, 1080, 4}, {1, 1920, 1080, 4}) ==
                  SurfaceTransition::Unchanged,
              "an already-consumed generation must be idempotent");
static_assert(DecideSurfaceTransition({1, 1920, 1080, 4}, {0, 0, 0, 5}) ==
                  SurfaceTransition::Lost,
              "a newer empty snapshot must suspend presentation");
static_assert(DecideSurfaceTransition({0, 0, 0, 5}, {2, 2560, 1600, 6}) ==
                  SurfaceTransition::Acquired,
              "a surface published after loss must be acquired");
static_assert(DecideSurfaceTransition({1, 1920, 1080, 4}, {2, 1920, 1080, 5}) ==
                  SurfaceTransition::Replaced,
              "a pointer change must rebind the native surface");
static_assert(
    DecideSurfaceTransition({1, 1920, 1080, 4}, {1, 1280, 720, 5}) ==
        SurfaceTransition::Resized,
    "a same-surface size change must not be mistaken for replacement");
// 下面 5 条刻意写满简化后的真值表（§S7.2：简化谓词时最容易丢的是负向分支）。
static_assert(
    ShouldRetrySurfaceAttach(SurfaceTransition::MetadataOnly, true, false),
    "a failed same-surface attach must remain retryable");
static_assert(
    ShouldRetrySurfaceAttach(SurfaceTransition::Unchanged, true, false),
    "an already-consumed generation with an unready backend must retry");
static_assert(
    !ShouldRetrySurfaceAttach(SurfaceTransition::Unchanged, true, true),
    "a ready backend must not be re-attached");
static_assert(
    !ShouldRetrySurfaceAttach(SurfaceTransition::Acquired, true, false),
    "a new epoch takes the normal attach path, not the recovery edge");
static_assert(
    !ShouldRetrySurfaceAttach(SurfaceTransition::MetadataOnly, false, false),
    "an unpublished surface must never be attached");

} // namespace amcl::ohos

#endif // AMCL_OHOS_SURFACE_STATE_H
