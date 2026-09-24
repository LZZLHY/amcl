#include "platform_input_ingress.h"

#include "amcl_input_api.h"
// For AMCL_INPUT_HOST_REQUIRED_CAPABILITIES_V1. This TU used to keep its own
// hand-written copy of the same 11-bit list; see kRequiredCapabilities below.
#include "amcl_input_host_descriptor.h"
#include "input_shadow_consumer.h"
#include "input_trace.h"
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <hilog/log.h>
#include <limits>
#include <mutex>
#include <string>

#ifndef AMCL_INPUT_SHADOW
#define AMCL_INPUT_SHADOW 1
#endif

#undef LOG_TAG
#define LOG_TAG "INPUT_INGRESS"

namespace amcl::input {
namespace {
// ⚠️ 2026-08-20: this used to be a hand-written second copy of the same 11-bit
// list that `AMCL_INPUT_HOST_REQUIRED_CAPABILITIES_V1` already defines, with no
// "these two are mirrors" declaration on either side -- unlike the latch bits
// and device-capability bits, which do carry that declaration and were found to
// have zero drift precisely because of it (spec §4.0).
//
// Why the drift would actually have bitten here rather than being harmless:
// `ResolveApiLocked` calls `amclInputGetHostApiV1()` **directly**, not through
// `amclInputHostDescriptorResolveV1`. So this TU is the one consumer that the
// descriptor's own macro does not protect. Adding a 12th required bit to the
// macro without updating this copy would leave ingress accepting a host that the
// descriptor path rejects -- two components disagreeing about what "compatible
// host" means, with no compile error.
//
// Fixed by deleting the copy instead of documenting it. `glfw_input_adapter.cpp`
// keeps a third list, but that one is a deliberate *superset* and its host has
// already passed ResolveV1, so it is a narrowing check rather than a mirror.
constexpr uint32_t kRequiredCapabilities =
    AMCL_INPUT_HOST_REQUIRED_CAPABILITIES_V1;

struct State {
    // Lock ordering is ingress -> shadow::* maintenance consumer -> host core.
    // `shadow` is a historical namespace name: this consumer is unconditional
    // whenever PlatformInputCoreEnabled(), including typed+shadow0, because it
    // observes RESET/epoch boundaries and reclaims the shared queue. Only legacy
    // reconciliation is controlled by ShadowEnabled(). Recovery keeps this lock
    // for the whole snapshot/replace/baseline transaction so no callback can
    // publish with a half-refreshed epoch or maintenance consumer.
    std::mutex mutex;
    const AmclInputHostApiV1* api = nullptr;
    uint64_t sessionEpoch = 0;
    uint64_t focusEpoch = 0;
    uint64_t surfaceEpoch = 0;
    uint64_t publicationGeneration = 0;
    uint32_t widthPx = 0;
    uint32_t heightPx = 0;
    bool sessionActive = false;
    bool focused = false;
    // Tracks whether the host accepted a surface publication independently of
    // dimensions validity. A zero-sized surface is still a lifecycle object and
    // must receive an inactive publication before its session is ended.
    bool surfacePublished = false;
    bool surfaceActive = false;
    // Unlike the fields above, pendingSurfaceContext is page/window state and
    // deliberately survives a missing native session. McGamePage can publish
    // before XComponent OnSurfaceCreated; the first accepted surface then
    // carries its density/transform and is followed by the context event.
    bool hasPendingSurfaceContext = false;
    AmclInputSurfaceContextPayload pendingSurfaceContext{};
    uint64_t publishedSurfaceContextGeneration = 0;
    uint64_t textSessionId = 0;
    bool resetLatched = false;
};
State g;
// ArkTS keeps only a temporary modifier/repeat cache. Every authoritative core
// RESET and every completed legacy cancel advances this process-lifetime epoch,
// allowing the page to discard stale UI state before classifying its next key.
// Writers saturate rather than wrap: reaching UINT64_MAX would require an
// impossible number of lifecycle boundaries, while wrap could alias old state.
std::atomic<uint64_t> gFrontendResetEpoch{1u};
// GLFW/SDL grab intent is published on the MC thread, while the WindowManager
// result returns later on the UI thread.  Rejecting a result whose requested bit
// no longer matches prevents a late lock success from reactivating capture after
// the game already opened a menu.  The periodic reconciler will release any
// short-lived system lock produced by that race.
std::atomic<bool> gCaptureRequestedIntent{false};
std::atomic<uint64_t> gTextCandidatesUnsupported{0u};

void SaturatingIncrement(std::atomic<uint64_t>& value) {
    uint64_t current = value.load(std::memory_order_relaxed);
    while (current != UINT64_MAX &&
           !value.compare_exchange_weak(
               current, current + 1u, std::memory_order_release,
               std::memory_order_relaxed)) {}
}

void AdvanceFrontendResetEpoch() {
    uint64_t current = gFrontendResetEpoch.load(std::memory_order_relaxed);
    while (current != UINT64_MAX &&
           !gFrontendResetEpoch.compare_exchange_weak(
               current, current + 1u, std::memory_order_release,
               std::memory_order_relaxed)) {}
}
#ifdef AMCL_INPUT_HOST_TESTING
PlatformInputHostTestHook gBeforeRecoveryOpenHook = nullptr;
#endif
std::once_flag gShadowEnabledOnce;
bool gShadowEnabled = AMCL_INPUT_SHADOW != 0;

void InitializeShadowEnabled() {
    const char* value = std::getenv("AMCL_INPUT_SHADOW");
    if (!value) return;
    const std::string overrideValue(value);
    if (overrideValue == "0" || overrideValue == "false" ||
        overrideValue == "FALSE" || overrideValue == "off" ||
        overrideValue == "OFF" || overrideValue == "no" ||
        overrideValue == "NO") {
        gShadowEnabled = false;
    } else if (overrideValue == "1" || overrideValue == "true" ||
               overrideValue == "TRUE" || overrideValue == "on" ||
               overrideValue == "ON" || overrideValue == "yes" ||
               overrideValue == "YES") {
        gShadowEnabled = true;
    }
}

bool ShadowEnabled() {
    std::call_once(gShadowEnabledOnce, InitializeShadowEnabled);
    return gShadowEnabled;
}

bool IsCompleteApi(const AmclInputHostApiV1* api) {
    return api && api->magic == AMCL_INPUT_HOST_API_MAGIC &&
           api->abiVersion == AMCL_INPUT_HOST_API_VERSION &&
           api->structSize >= sizeof(AmclInputHostApiV1) &&
           api->generation == AMCL_INPUT_HOST_API_GENERATION &&
           (api->capabilityBits & kRequiredCapabilities) == kRequiredCapabilities &&
           api->beginSession && api->endSession && api->submitEvent &&
           api->submitBatch && api->submitTextPacket && api->publishSurface &&
           api->publishFocus && api->publishDeviceChange && api->requestReset &&
           api->openConsumer && api->nextEvent && api->readPacketBlob &&
           api->releasePacket && api->closeConsumer && api->getSnapshot;
}

bool ResolveApiLocked() {
    if (IsCompleteApi(g.api)) return true;
    const AmclInputHostApiV1* candidate = amclInputGetHostApiV1();
    if (!IsCompleteApi(candidate)) {
        trace::RecordUnsupported();
        g.api = nullptr;
        return false;
    }
    g.api = candidate;
    return true;
}
bool RefreshSnapshotLocked() {
    AmclInputSnapshotV1 snapshot{};
    snapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    snapshot.structSize = static_cast<uint16_t>(sizeof(snapshot));
    const int32_t result = g.api->getSnapshot(&snapshot);
    trace::RecordSubmitted(result);
    if (result != AMCL_INPUT_OK) return false;
    g.sessionEpoch = snapshot.sessionEpoch;
    g.focusEpoch = snapshot.focusEpoch;
    g.surfaceEpoch = snapshot.surfaceEpoch;
    g.sessionActive = snapshot.sessionActive != 0u;
    g.focused = snapshot.focused != 0u;
    return true;
}

bool IsAccepted(int32_t result) {
    return result == AMCL_INPUT_OK || result == AMCL_INPUT_OVERFLOW_RESET;
}

// For lifecycle calls OVERFLOW_RESET means the reset and transition were
// committed. For ordinary input it means only a fail-safe RESET was committed;
// the triggering event itself was dropped and must not enter typed held state.
bool IsTypedEventAccepted(int32_t result) {
    return result == AMCL_INPUT_OK;
}

bool IsEpochFailure(int32_t result) {
    return result == AMCL_INPUT_ERROR_STALE ||
           result == AMCL_INPUT_ERROR_SESSION;
}

bool IsSurfaceContextValid(const AmclInputSurfaceContextPayload& context) {
    if ((context.validFields &
         ~AMCL_INPUT_SURFACE_CONTEXT_FIELD_ALL) != 0u ||
        context.generation == 0u) {
        return false;
    }
    if ((context.validFields &
         AMCL_INPUT_SURFACE_CONTEXT_FIELD_WINDOW) != 0u &&
        context.windowId <= 0) {
        return false;
    }
    if ((context.validFields &
         AMCL_INPUT_SURFACE_CONTEXT_FIELD_DISPLAY) != 0u &&
        context.displayId < 0) {
        return false;
    }
    if ((context.validFields &
         AMCL_INPUT_SURFACE_CONTEXT_FIELD_RECT) != 0u &&
        (context.widthPx == 0u || context.heightPx == 0u)) {
        return false;
    }
    if ((context.validFields &
         AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY) != 0u &&
        (!std::isfinite(context.density) || context.density <= 0.0f)) {
        return false;
    }
    if ((context.validFields &
         AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM) != 0u &&
        context.transform > 3u) {
        return false;
    }
    return (context.validFields &
            AMCL_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE) == 0u ||
           (std::isfinite(context.refreshRateHz) &&
            context.refreshRateHz > 0.0f &&
            context.refreshRateHz <= 1000.0f);
}

bool SameSurfaceContext(const AmclInputSurfaceContextPayload& left,
                        const AmclInputSurfaceContextPayload& right) {
    if (left.generation != right.generation ||
        left.validFields != right.validFields) {
        return false;
    }
    const uint32_t valid = left.validFields;
    if ((valid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_WINDOW) != 0u &&
        left.windowId != right.windowId) {
        return false;
    }
    if ((valid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_DISPLAY) != 0u &&
        left.displayId != right.displayId) {
        return false;
    }
    if ((valid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_RECT) != 0u &&
        (left.leftPx != right.leftPx || left.topPx != right.topPx ||
         left.widthPx != right.widthPx || left.heightPx != right.heightPx)) {
        return false;
    }
    if ((valid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY) != 0u &&
        left.density != right.density) {
        return false;
    }
    if ((valid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM) != 0u &&
        left.transform != right.transform) {
        return false;
    }
    return (valid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE) == 0u ||
           left.refreshRateHz == right.refreshRateHz;
}

bool SameSurfaceEpochSemantics(const AmclInputSurfaceContextPayload* left,
                               const AmclInputSurfaceContextPayload& right) {
    const uint32_t semanticFields =
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY |
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM;
    if (!left) return (right.validFields & semanticFields) == 0u;
    const uint32_t leftValid = left->validFields & semanticFields;
    const uint32_t rightValid = right.validFields & semanticFields;
    if (leftValid != rightValid) return false;
    if ((leftValid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY) != 0u &&
        left->density != right.density) {
        return false;
    }
    return (leftValid & AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM) == 0u ||
           left->transform == right.transform;
}

void ClearSessionStateLocked() {
    g.sessionEpoch = 0;
    g.focusEpoch = 0;
    g.surfaceEpoch = 0;
    g.publicationGeneration = 0;
    g.widthPx = 0;
    g.heightPx = 0;
    g.sessionActive = false;
    g.focused = false;
    g.surfacePublished = false;
    g.surfaceActive = false;
    g.publishedSurfaceContextGeneration = 0;
    g.textSessionId = 0u;
    g.resetLatched = false;
}

// Counted here rather than at the call sites on purpose: this is the single
// funnel that discards the local session mirror, so a future fail-closed path
// cannot forget to record itself, and no comment has to carry a call-site count
// that would rot. Note this deliberately does NOT advance the frontend reset
// epoch -- failing closed proves nothing about the host, and telling ArkTS
// "drop everything" on an unproven boundary is the one direction that could
// lose held state that some plane still owns.
void FailClosedLocked() {
    trace::RecordSessionFailedClosed();
    shadow::CloseBestEffort(g.api);
    ClearSessionStateLocked();
}

void InvalidateSurfaceBindingLocked() {
    // A refreshed host epoch is not permission to relabel geometry sampled
    // under an older native publication. Only a later lifecycle callback that
    // supplies its publicationGeneration may establish a new binding.
    g.publicationGeneration = 0u;
    g.widthPx = 0u;
    g.heightPx = 0u;
    g.surfacePublished = false;
    g.surfaceActive = false;
    g.publishedSurfaceContextGeneration = 0u;
}

// The caller already owns g.mutex. Keep recovery atomic with every platform
// entrypoint: refresh host state first, then replace the historically named
// shadow::* maintenance consumer while following ingress -> maintenance -> host
// lock order. This replacement is required for typed+shadow0 as well; adding a
// ShadowEnabled guard would strand RESET/epoch observation and queue reclamation.
// The failed event is never available here, deliberately making replay into the
// new epoch impossible.
void RecoverEpochFailureLocked() {
    if (!g.api || !RefreshSnapshotLocked() || !g.sessionActive ||
        g.sessionEpoch == 0u || g.focusEpoch == 0u || g.surfaceEpoch == 0u) {
        FailClosedLocked();
        return;
    }

    InvalidateSurfaceBindingLocked();

    shadow::CloseBestEffort(g.api);
#ifdef AMCL_INPUT_HOST_TESTING
    if (gBeforeRecoveryOpenHook) {
        const PlatformInputHostTestHook hook = gBeforeRecoveryOpenHook;
        gBeforeRecoveryOpenHook = nullptr;
        hook();
    }
#endif
    if (!shadow::Open(g.api, true)) {
        FailClosedLocked();
        return;
    }
    const shadow::DrainResult baseline = shadow::Drain(g.api);
    if (!baseline.completed || baseline.staleConsumer ||
        !baseline.observedReset) {
        // CONSUMER_BASELINE is a required capability, not an optional hint. An
        // empty fresh drain means the host changed between snapshot and open;
        // accepting it would carry old reconciliation into an unproven epoch.
        FailClosedLocked();
        return;
    }
    // A fresh maintenance-consumer baseline is the authoritative RESET/epoch
    // boundary; when shadow reconciliation is enabled it is also that plane's
    // boundary. Old route completions and held contributors cannot cross into
    // the recovered host epoch; the failed event itself is never replayed.
    //
    // Both of the next two lines are required, and pairing them is the point.
    // `RecordAndDrainLocked` already emits exactly this pair whenever a drain
    // observes RESET; recovery cannot reuse that helper (it drains the *fresh*
    // consumer directly, outside the submit path), so the pair has to be written
    // out by hand here. It was written out incompletely until 2026-08-21: only
    // ResetReconciliation was, which left the process-lifetime frontend epoch
    // frozen across a boundary that the header contract
    // ("Core RESET advances it when observed") says must advance it, and that
    // this function itself refuses to accept without `baseline.observedReset`.
    // Consequence of the omission: ArkTS kept a held/repeat/modifier cache that
    // core had just discarded, and the only recovery was the next unrelated
    // reset boundary.
    trace::ResetReconciliation();
    AdvanceFrontendResetEpoch();
    trace::RecordEpochRecovered();
    g.resetLatched = baseline.observedResetState && baseline.resetLatched;
}

uint32_t NormalizePointerDeviceClass(uint32_t deviceClass) {
    if (deviceClass < AMCL_INPUT_DEVICE_CLASS_COUNT) return deviceClass;
    trace::RecordUnsupported();
    return AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
}

uint32_t PointerSourceForClass(uint32_t deviceClass) {
    switch (deviceClass) {
        case AMCL_INPUT_DEVICE_CLASS_MOUSE:
            return AMCL_INPUT_SOURCE_MOUSE;
        case AMCL_INPUT_DEVICE_CLASS_TOUCHPAD:
            return AMCL_INPUT_SOURCE_TOUCHPAD;
        default:
            // Identity unavailable is not evidence of a mouse. Keeping source
            // unknown prevents touchpads from being silently compressed into
            // the mouse bucket merely because an older callback omitted class.
            return AMCL_INPUT_SOURCE_UNKNOWN;
    }
}

PlatformInputPointerIdentity NormalizePointerIdentity(
        const PlatformInputPointerIdentity& identity) {
    PlatformInputPointerIdentity normalized = identity;
    normalized.deviceClass =
        NormalizePointerDeviceClass(identity.deviceClass);
    return normalized;
}

AmclInputEvent Event(uint32_t type, uint32_t source, uint64_t deviceId = 0,
                     uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN,
                     uint64_t monotonicTimeNs = 0u) {
    AmclInputEvent event{};
    event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    event.header.structSize = static_cast<uint16_t>(sizeof(event));
    event.header.eventType = type;
    event.header.source = source;
    event.header.deviceId = deviceId;
    event.header.deviceClass = deviceClass;
    if (monotonicTimeNs != 0u) {
        event.header.monotonicTimeNs = monotonicTimeNs;
        event.header.flags |= AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP;
    }
    event.header.sessionEpoch = g.sessionEpoch;
    event.header.focusEpoch = g.focusEpoch;
    event.header.surfaceEpoch = g.surfaceEpoch;
    return event;
}

shadow::DrainResult RecordAndDrainLocked(int32_t result, bool terminal = false) {
    trace::RecordSubmitted(result);
    const shadow::DrainResult drained = g.api
        ? shadow::Drain(g.api, terminal)
        : shadow::DrainResult{false, false, false, false, false};
    // RESET propagation is driven by what the authoritative consumer observed,
    // not by a caller guessing which host result might have emitted one. This
    // covers focus/surface/capture/overflow and keeps duplicate resets idempotent.
    if (drained.observedReset) {
        trace::ResetReconciliation();
        AdvanceFrontendResetEpoch();
        g.textSessionId = 0u;
    }
    if (drained.observedResetState) g.resetLatched = drained.resetLatched;
    return drained;
}

int32_t SubmitLocked(const AmclInputEvent& event) {
    if (!g.sessionActive || !g.api) {
        trace::RecordConsumerError(true);
        return AMCL_INPUT_ERROR_SESSION;
    }
    const int32_t result = g.api->submitEvent(&event);
    const shadow::DrainResult drained = RecordAndDrainLocked(result);
    if (IsEpochFailure(result) || drained.staleConsumer) {
        // The event belongs only to the epoch encoded in its header. Never
        // replay it after refreshing to a newer host epoch.
        RecoverEpochFailureLocked();
    }
    return result;
}

int32_t SubmitBatchLocked(const AmclInputEvent* events, uint32_t count) {
    if (!events || count == 0u || !g.sessionActive || !g.api) {
        trace::RecordConsumerError(true);
        return AMCL_INPUT_ERROR_SESSION;
    }
    const int32_t result = g.api->submitBatch(events, count);
    const shadow::DrainResult drained = RecordAndDrainLocked(result);
    if (IsEpochFailure(result) || drained.staleConsumer) {
        // The complete batch belongs to the binding in every event header.
        // Core rollback plus no replay prevents an absolute/button pair from
        // being split or retagged after epoch recovery.
        RecoverEpochFailureLocked();
    }
    return result;
}

int32_t SubmitTextPacketLocked(const AmclInputEvent& event,
                               const uint8_t* bytes, uint32_t byteCount) {
    if (!g.sessionActive || !g.api) {
        trace::RecordConsumerError(true);
        return AMCL_INPUT_ERROR_SESSION;
    }
    const int32_t result =
        g.api->submitTextPacket(&event, bytes, byteCount);
    const shadow::DrainResult drained = RecordAndDrainLocked(result);
    if (IsEpochFailure(result) || drained.staleConsumer) {
        RecoverEpochFailureLocked();
    } else if (result != AMCL_INPUT_OK && drained.observedReset) {
        g.textSessionId = 0u;
    }
    return result;
}

bool PublishPendingSurfaceContextLocked() {
    if (!g.hasPendingSurfaceContext) return true;
    const auto& context = g.pendingSurfaceContext;
    if (g.publishedSurfaceContextGeneration == context.generation) {
        return true;
    }
    if (!g.api || !g.sessionActive || !g.surfacePublished) return true;
    if ((g.api->capabilityBits & AMCL_INPUT_CAP_SURFACE_CONTEXT) == 0u) {
        // Additive V1 compatibility: an older host still receives verified
        // density/transform through SURFACE_CHANGED but has no context event.
        g.publishedSurfaceContextGeneration = context.generation;
        return true;
    }

    AmclInputEvent event = Event(
        AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED,
        AMCL_INPUT_SOURCE_UNKNOWN);
    event.payload.surfaceContext = context;
    const int32_t result = g.api->submitEvent(&event);
    const shadow::DrainResult drained = RecordAndDrainLocked(result);
    if (IsEpochFailure(result) || drained.staleConsumer) {
        RecoverEpochFailureLocked();
        return false;
    }
    // For a non-lifecycle record OVERFLOW_RESET means only the fail-safe RESET
    // committed; the context itself did not. Leave the generation unpublished
    // so the next heartbeat retries it.
    if (!IsTypedEventAccepted(result)) return false;
    g.publishedSurfaceContextGeneration = context.generation;
    return true;
}

bool PublishSurfaceLocked(bool active, uint32_t widthPx, uint32_t heightPx,
                          uint64_t publicationGeneration) {
    AmclInputSurfacePayload surface{};
    surface.widthPx = widthPx;
    surface.heightPx = heightPx;
    surface.active = active ? 1u : 0u;
    if (widthPx != 0u && heightPx != 0u) {
        surface.validFields = AMCL_INPUT_SURFACE_FIELD_DIMENSIONS;
    }
    if (g.hasPendingSurfaceContext) {
        const auto& context = g.pendingSurfaceContext;
        if ((context.validFields &
             AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY) != 0u) {
            surface.density = context.density;
            surface.validFields |= AMCL_INPUT_SURFACE_FIELD_DENSITY;
        }
        if ((context.validFields &
             AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM) != 0u) {
            surface.transform = context.transform;
            surface.validFields |= AMCL_INPUT_SURFACE_FIELD_TRANSFORM;
        }
    }
    if (publicationGeneration != 0u) {
        surface.validFields |=
            AMCL_INPUT_SURFACE_FIELD_PUBLICATION_GENERATION;
        surface.publicationGeneration = publicationGeneration;
    }
    if ((surface.validFields & AMCL_INPUT_SURFACE_FIELD_TRANSFORM) == 0u) {
        trace::RecordMissing(trace::MissingField::CursorTransform);
        trace::RecordUnsupported();
    }
    const int32_t result = g.api->publishSurface(&surface);
    const shadow::DrainResult drained = RecordAndDrainLocked(result);
    if (IsEpochFailure(result) || drained.staleConsumer) {
        RecoverEpochFailureLocked();
        return false;
    }
    // Ordinary host errors do not invalidate an otherwise current consumer.
    if (!IsAccepted(result)) return false;
    if (!RefreshSnapshotLocked()) {
        FailClosedLocked();
        return false;
    }
    if (!g.sessionActive) {
        FailClosedLocked();
        return false;
    }
    g.surfacePublished = active;
    g.surfaceActive = active &&
        (surface.validFields & AMCL_INPUT_SURFACE_FIELD_DIMENSIONS) != 0u;
    g.widthPx = widthPx;
    g.heightPx = heightPx;
    g.publicationGeneration = active ? publicationGeneration : 0u;
    // Every accepted SURFACE_CHANGED is a core RESET boundary.
    g.textSessionId = 0u;
    if (!active) return true;
    return PublishPendingSurfaceContextLocked();
}

int32_t SubmitPhysicalKeyLocked(
        uint32_t ohosKeyCode, uint32_t hardwareScanCode, uint32_t hidUsage,
        uint32_t action, uint32_t modifiers, uint32_t locks,
        uint64_t deviceId) {
    if (deviceId == 0) trace::RecordMissing(trace::MissingField::Device);
    if (hardwareScanCode == 0 && hidUsage == 0) {
        trace::RecordMissing(trace::MissingField::ScanCode);
    }
    // Latch snapshot gate. Two independent rules, both fail-closed:
    //
    // 1. Unknown bits mean the caller is not speaking this ABI (the realistic
    //    case is a modifier value reaching the adjacent `locks` parameter). Such
    //    a value is downgraded to "unknown" rather than partially trusted, and
    //    is reported as an unsupported field so the mistake stays visible. Core
    //    never repairs lockState, so the downgrade has to happen here — the
    //    only place that still knows the value came from the platform producer.
    // 2. "Missing" is decided by the VALID bit, not by `locks == 0`. A VALID
    //    snapshot whose three latch bits are all clear is a real answer ("all
    //    locks off"); counting it as missing would keep the diagnostic
    //    permanently non-zero on a correctly reporting device and hide a
    //    genuine regression.
    //
    // An unknown/invalid snapshot stays unknown all the way to the backend
    // adapters: deriving latches from held keys is forbidden (§5.2 / §10.1).
    if ((locks & ~AMCL_INPUT_LOCK_STATE_MASK) != 0u) {
        trace::RecordUnsupported();
        locks = 0u;
    }
    if ((locks & AMCL_INPUT_LOCK_STATE_VALID) == 0) {
        trace::RecordMissing(trace::MissingField::LockState);
    }
    AmclInputEvent event = Event(AMCL_INPUT_EVENT_PHYSICAL_KEY,
                                 AMCL_INPUT_SOURCE_KEYBOARD, deviceId);
    event.payload.physicalKey.physicalKey = ohosKeyCode;
    event.payload.physicalKey.hardwareScanCode = hardwareScanCode;
    event.payload.physicalKey.hidUsage = hidUsage;
    event.payload.physicalKey.action = action;
    event.payload.physicalKey.modifiersSnapshot = modifiers;
    event.payload.physicalKey.lockState = locks;
    return SubmitLocked(event);
}

int32_t SubmitPointerRelativeLocked(
        double rawDx, double rawDy,
        const PlatformInputPointerIdentity& rawIdentity) {
    const PlatformInputPointerIdentity identity =
        NormalizePointerIdentity(rawIdentity);
    if (identity.deviceId == 0u) {
        trace::RecordMissing(trace::MissingField::Device);
    }
    AmclInputEvent event = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE,
                                 PointerSourceForClass(identity.deviceClass),
                                 identity.deviceId, identity.deviceClass,
                                 identity.monotonicTimeNs);
    if (PlatformInputApi26RawMouseMotionSupported()) {
        event.header.flags |= AMCL_INPUT_EVENT_FLAG_HARDWARE_RAW;
    }
    event.payload.pointerRelative.rawDx = rawDx;
    event.payload.pointerRelative.rawDy = rawDy;
    return SubmitLocked(event);
}

int32_t SubmitPointerButtonLocked(uint64_t deviceId, uint32_t nativeButton,
                                  uint32_t action, uint32_t rawDeviceClass,
                                  uint64_t monotonicTimeNs) {
    if (deviceId == 0) trace::RecordMissing(trace::MissingField::Device);
    const uint32_t deviceClass =
        NormalizePointerDeviceClass(rawDeviceClass);
    AmclInputEvent event = Event(AMCL_INPUT_EVENT_POINTER_BUTTON,
                                 PointerSourceForClass(deviceClass), deviceId,
                                 deviceClass, monotonicTimeNs);
    event.payload.pointerButton.nativeButton = nativeButton;
    event.payload.pointerButton.action = action;
    return SubmitLocked(event);
}

int32_t SubmitPointerWheelLocked(
        float x, float y, bool precise,
        const PlatformInputPointerIdentity& rawIdentity) {
    const PlatformInputPointerIdentity identity =
        NormalizePointerIdentity(rawIdentity);
    if (identity.deviceId == 0u) {
        trace::RecordMissing(trace::MissingField::Device);
    }
    trace::RecordUnsupported();  // No verified horizontal-axis getter in this SDK.
    AmclInputEvent event = Event(AMCL_INPUT_EVENT_POINTER_WHEEL,
                                 PointerSourceForClass(identity.deviceClass),
                                 identity.deviceId, identity.deviceClass,
                                 identity.monotonicTimeNs);
    if (precise) event.header.flags |= AMCL_INPUT_EVENT_FLAG_PRECISE;
    event.payload.pointerWheel.x = x;
    event.payload.pointerWheel.y = y;
    // ⚠️ 2026-08-23 更正：此前硬编码 `DEGREE`，而唯一的产品生产者
    // （`touch_input.cpp` 的 native AXIS 路径）送来的是 `OH_ArkUI_AxisEvent_
    // GetVerticalAxisValue()` 的**像素**值。三处各说一套量纲曾被记成"当前无行为后果"，
    // 那句是假的：`glfw_compat.cpp` 的 `typedWheelSink` **就是**按 unit 分支换算的
    // （DEGREE ⇒ /15），于是 px 被当度用 ⇒ 一格永远累加不到 15 ⇒ 从不发 scroll。
    event.payload.pointerWheel.unit = AMCL_INPUT_WHEEL_UNIT_PIXEL;
    event.payload.pointerWheel.precise = precise ? 1u : 0u;
    return SubmitLocked(event);
}

bool IsKeyActionPair(uint32_t typedAction, int32_t mappedAction) {
    return (typedAction == AMCL_INPUT_ACTION_DOWN && mappedAction == 1) ||
           (typedAction == AMCL_INPUT_ACTION_REPEAT && mappedAction == 2) ||
           (typedAction == AMCL_INPUT_ACTION_UP && mappedAction == 0);
}

bool IsButtonActionPair(uint32_t typedAction, int32_t mappedAction) {
    return (typedAction == AMCL_INPUT_ACTION_DOWN && mappedAction == 1) ||
           (typedAction == AMCL_INPUT_ACTION_UP && mappedAction == 0);
}

bool IsFloatRepresentable(double value) {
    return std::isfinite(value) &&
           value <= static_cast<double>(std::numeric_limits<float>::max()) &&
           value >= -static_cast<double>(std::numeric_limits<float>::max());
}

AmclLegacyPhysicalOutcome NormalizeLegacyCallbackOutcome(
        AmclLegacyPhysicalOutcome outcome) {
    switch (outcome) {
        case AMCL_LEGACY_PHYSICAL_EMITTED:
        case AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE:
        case AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE:
        case AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED:
        case AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT:
        case AMCL_LEGACY_PHYSICAL_OWNERLESS_UP:
        case AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN:
        case AMCL_LEGACY_PHYSICAL_INVALID_ACTION:
        case AMCL_LEGACY_PHYSICAL_INVALID_VALUE:
        case AMCL_LEGACY_PHYSICAL_UNKNOWN_CONTROL:
        case AMCL_LEGACY_PHYSICAL_RESET_IN_PROGRESS:
            return outcome;
        case AMCL_LEGACY_PHYSICAL_GATE_REJECTED:
        case AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED:
        case AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED:
            // These are owned by ingress and may never be manufactured by a
            // legacy callback running after the gate/route decision.
            return AMCL_LEGACY_PHYSICAL_INVALID_VALUE;
    }
    return AMCL_LEGACY_PHYSICAL_INVALID_VALUE;
}

void FinalizeEdgeObservation(uint64_t observation,
                             trace::PhysicalIngressKind kind,
                             AmclLegacyPhysicalOutcome outcome,
                             int32_t mappedAction,
                             int32_t routedMapped) {
    if (observation == 0u) return;
    trace::LegacyResult result = trace::LegacyResult::LegacyFallback;
    int32_t finalAction = mappedAction;
    switch (outcome) {
        case AMCL_LEGACY_PHYSICAL_EMITTED:
            result = trace::LegacyResult::Exact;
            break;
        case AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE:
            // Another raw owner still holds the aggregate GLFW control. This is
            // exact, but there was deliberately no final backend transition.
            result = trace::LegacyResult::Exact;
            finalAction = -1;
            break;
        case AMCL_LEGACY_PHYSICAL_UNKNOWN_CONTROL:
            result = kind == trace::PhysicalIngressKind::Button
                ? trace::LegacyResult::UnknownButton
                : trace::LegacyResult::Unmapped;
            finalAction = -1;
            break;
        case AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE:
        case AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED:
            result = trace::LegacyResult::BridgeUnavailable;
            finalAction = -1;
            break;
        case AMCL_LEGACY_PHYSICAL_INVALID_ACTION:
        case AMCL_LEGACY_PHYSICAL_INVALID_VALUE:
            result = trace::LegacyResult::InvalidInput;
            finalAction = -1;
            break;
        case AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT:
        case AMCL_LEGACY_PHYSICAL_OWNERLESS_UP:
        case AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN:
        case AMCL_LEGACY_PHYSICAL_RESET_IN_PROGRESS:
        case AMCL_LEGACY_PHYSICAL_GATE_REJECTED:
        case AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED:
        case AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED:
            finalAction = -1;
            break;
    }
    trace::FinalizeObservation(
        observation, result, finalAction, 0u,
        routedMapped >= 0 ? routedMapped
                          : reconciliation::kNoLegacyMappedOverride);
}
}  // namespace

#ifdef AMCL_INPUT_HOST_TESTING
void PlatformInputTestSetBeforeRecoveryOpenHook(
        PlatformInputHostTestHook hook) {
    std::lock_guard<std::mutex> lock(g.mutex);
    gBeforeRecoveryOpenHook = hook;
}
#endif

uint64_t PlatformInputResetEpoch() {
    return gFrontendResetEpoch.load(std::memory_order_acquire);
}

void PlatformInputCompleteResetBoundary() {
    // Called only after the legacy touch/schema/ledger transaction is empty.
    // It intentionally advances even when the typed core already emitted RESET:
    // a getter racing the earlier typed edge must still observe completion.
    AdvanceFrontendResetEpoch();
}

bool PlatformInputShadowEnabled() {
    return ShadowEnabled();
}

bool PlatformInputPhysicalRouteUsesTyped() {
    // The optional route bit is startup-latched in the single host table that
    // owns InputStateCore. Both this producer DSO and a namespace-duplicated
    // GLFW consumer therefore observe exactly one immutable source-plane
    // decision; an environment edit can no longer split a held edge.
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    return IsCompleteApi(api) &&
        (api->capabilityBits & AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE) != 0u;
}

bool PlatformInputRawRelativeVerified() {
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    return IsCompleteApi(api) &&
        (api->capabilityBits &
         AMCL_INPUT_CAP_VERIFIED_POINTER_RELATIVE) != 0u;
}

bool PlatformInputApi26RawMouseMotionSupported() {
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    if (!IsCompleteApi(api)) return false;
    constexpr uint32_t required =
        AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE |
        AMCL_INPUT_CAP_VERIFIED_POINTER_RELATIVE |
        AMCL_INPUT_CAP_GLFW_API26_RAW_MOUSE_MOTION;
    return (api->capabilityBits & required) == required;
}

bool PlatformInputNativeAbsoluteRouteUsesTyped() {
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    return IsCompleteApi(api) &&
        (api->capabilityBits &
         AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ABSOLUTE_ROUTE) != 0u;
}

bool PlatformInputTextSessionSupported() {
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    return IsCompleteApi(api) &&
        (api->capabilityBits & AMCL_INPUT_CAP_TEXT_INPUT_SESSION) != 0u;
}

bool PlatformInputCoreEnabled() {
    // Shadow controls legacy-vs-typed reconciliation only. Once the single host
    // table selects typed physical input, producers and lifecycle must keep the
    // neutral core alive even when AMCL_INPUT_SHADOW=0; otherwise the producer
    // and consumer would disagree about the selected source plane.
    return ShadowEnabled() || PlatformInputPhysicalRouteUsesTyped();
}

static bool PlatformInputLifecycleEnabled() {
    // Typed text reuses the neutral session/focus/surface epochs even when the
    // physical source plane is legacy+shadow0. Keep physical mirroring gated by
    // PlatformInputCoreEnabled; only lifecycle and typed-text paths widen here.
    return PlatformInputCoreEnabled() || PlatformInputTextSessionSupported();
}

// ⚠️ **`trace::RecordGateRejected()` 的守卫一律是本函数，不是 `ShadowEnabled()`。**
//
// 2026-09-01 统一：六个 `*Transaction` 里此前有四个用 `ShadowEnabled()`、两个用本函数。
// 两者只在 **typed + `AMCL_INPUT_SHADOW=0`** 这个明确支持的回滚配置下不同（那时前者假、
// 后者真），于是同一件事（"gate 拒了一条边沿"）在两组入口里记不记账取决于走的是哪个入口。
//
// 选本函数的依据是**计数器的宿主**：`RecordGateRejected` 写的是 `input_trace` 的
// per-session 计数，而那个 session 由 `PlatformInputSurfaceCreated` → `trace::BeginSession`
// 建立，那一步的前置条件正是本函数。⇒ core 没启用时 session 根本不存在，记账无处可去；
// core 启用时 session 一定存在，就必须记。`ShadowEnabled()` 描述的是**对账平面**跑不跑，
// 与"这条计数器有没有宿主"无关 —— 它在这里是一个作用域用错了的判据
// （规范 §八 纪律 1：论证的作用域必须与结论的作用域一致）。
//
// 当前出货配置下两者同真（`AMCL_INPUT_SHADOW` 未被 build-profile 传入 ⇒ 默认 1），
// 所以这次统一**不改变出货行为**；它消掉的是回滚配置上的一处潜伏不一致。

void PlatformInputSurfaceCreated(uint32_t widthPx, uint32_t heightPx,
                                 uint64_t publicationGeneration) {
    if (!PlatformInputLifecycleEnabled()) return;
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!ResolveApiLocked()) {
        shadow::Abandon();
        ClearSessionStateLocked();
        return;
    }
    if (g.sessionActive) {
        if (!g.surfacePublished || g.widthPx != widthPx ||
            g.heightPx != heightPx ||
            g.publicationGeneration != publicationGeneration) {
            PublishSurfaceLocked(
                true, widthPx, heightPx, publicationGeneration);
        }
        return;
    }

    // A previous ingress may have lost its epoch while the host retained (or
    // replaced) the session. Always use a fresh snapshot to decide recovery.
    AmclInputSnapshotV1 snapshot{};
    snapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    snapshot.structSize = static_cast<uint16_t>(sizeof(snapshot));
    const int32_t snapshotResult = g.api->getSnapshot(&snapshot);
    trace::RecordSubmitted(snapshotResult);
    if (snapshotResult != AMCL_INPUT_OK) {
        FailClosedLocked();
        return;
    }
    if (snapshot.sessionActive != 0u) {
        const int32_t endResult = g.api->endSession(snapshot.sessionEpoch);
        trace::RecordSubmitted(endResult);
        if (!IsAccepted(endResult)) {
            // Do not begin behind a host session that could not be ended. The
            // next SurfaceCreated snapshots again and can retry safely.
            RecoverEpochFailureLocked();
            return;
        }
    }

    // Session boundaries never reuse an unproven maintenance consumer, even when
    // a prior local handle survived an interrupted destroy path. `shadow::Open`
    // is historical naming, not a ShadowEnabled gate: typed+shadow0 also needs
    // its RESET/epoch baseline and queue reclamation before publishing events.
    if (!shadow::Open(g.api, true)) {
        ClearSessionStateLocked();
        return;
    }
    uint64_t epoch = 0;
    const int32_t result = g.api->beginSession(&epoch);
    const shadow::DrainResult drained = RecordAndDrainLocked(result);
    if (IsEpochFailure(result) || drained.staleConsumer) {
        RecoverEpochFailureLocked();
        return;
    }
    if (!IsAccepted(result) || !RefreshSnapshotLocked() || !g.sessionActive) {
        FailClosedLocked();
        return;
    }
    g.resetLatched = false;
    trace::BeginSession(g.api->generation, g.sessionEpoch);
    OH_LOG_INFO(LOG_APP,
        "neutral input session begin epoch=%{public}llu shadow=%{public}d; "
        "density/transform are invalid until verified",
        (unsigned long long)g.sessionEpoch,
        ShadowEnabled() ? 1 : 0);
    PublishSurfaceLocked(true, widthPx, heightPx, publicationGeneration);
}
void PlatformInputSurfaceChanged(uint32_t widthPx, uint32_t heightPx,
                                 uint64_t publicationGeneration) {
    if (!PlatformInputLifecycleEnabled()) return;
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!g.sessionActive || !g.api) {
        trace::RecordConsumerError(true);
        return;
    }
    if (g.surfacePublished && g.widthPx == widthPx &&
        g.heightPx == heightPx &&
        g.publicationGeneration == publicationGeneration) {
        return;
    }
    PublishSurfaceLocked(true, widthPx, heightPx, publicationGeneration);
}

bool PlatformInputSurfaceContextChanged(
        const AmclInputSurfaceContextPayload& context) {
    if (!IsSurfaceContextValid(context)) {
        trace::RecordUnsupported();
        return false;
    }
    std::lock_guard<std::mutex> lock(g.mutex);
    const bool hadPrevious = g.hasPendingSurfaceContext;
    const AmclInputSurfaceContextPayload previous = g.pendingSurfaceContext;
    if (hadPrevious) {
        if (context.generation < previous.generation) return false;
        if (context.generation == previous.generation) {
            if (!SameSurfaceContext(previous, context)) return false;
            if (!PlatformInputLifecycleEnabled() || !g.sessionActive ||
                !g.surfacePublished) {
                return true;
            }
            return PublishPendingSurfaceContextLocked();
        }
    }

    const bool sameSurfaceSemantics = SameSurfaceEpochSemantics(
        hadPrevious ? &previous : nullptr, context);
    g.pendingSurfaceContext = context;
    g.hasPendingSurfaceContext = true;

    // Window state is allowed to arrive before the XComponent/session.  Cache
    // it without producing consumer-error noise; SurfaceCreated will publish
    // the native surface first and this context second.
    if (!PlatformInputLifecycleEnabled() || !g.sessionActive || !g.api ||
        !g.surfacePublished) {
        return true;
    }
    if (!sameSurfaceSemantics) {
        // Density/transform change the meaning of surface-local coordinates.
        // Re-publishing the existing native surface advances surfaceEpoch and
        // emits RESET -> SURFACE; PublishSurfaceLocked then emits this context.
        return PublishSurfaceLocked(true, g.widthPx, g.heightPx,
                                    g.publicationGeneration);
    }
    // Position, display, rect and refresh-only updates do not invalidate held
    // input or absolute authorization. They advance only context generation.
    return PublishPendingSurfaceContextLocked();
}

void PlatformInputSurfaceDestroyed(uint64_t publicationGeneration) {
    if (!PlatformInputLifecycleEnabled()) return;
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!g.api) {
        shadow::Abandon();
        ClearSessionStateLocked();
        return;
    }
    if (!g.sessionActive) {
        shadow::CloseBestEffort(g.api);
        ClearSessionStateLocked();
        return;
    }
    if (g.surfacePublished) {
        PublishSurfaceLocked(false, g.widthPx, g.heightPx,
                             publicationGeneration != 0u
                                 ? publicationGeneration
                                 : g.publicationGeneration);
        if (!g.sessionActive) return;  // stale path already failed closed
    }
    const int32_t result = g.api->endSession(g.sessionEpoch);
    const shadow::DrainResult drained = RecordAndDrainLocked(result, true);
    if (!IsAccepted(result) || drained.staleConsumer) {
        // The snapshot tells us whether the host retained/replaced the session;
        // local ownership is discarded either way and create will re-check it.
        RefreshSnapshotLocked();
    }
    shadow::CloseBestEffort(g.api);
    trace::ResetReconciliation();
    trace::LogSessionSummary("surface-destroyed");
    ClearSessionStateLocked();
}

void PlatformInputFocusChanged(bool focused) {
    if (!PlatformInputLifecycleEnabled()) return;
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!g.sessionActive || !g.api) {
        trace::RecordConsumerError(true);
        return;
    }
    const int32_t result = g.api->publishFocus(focused ? 1u : 0u);
    const shadow::DrainResult drained = RecordAndDrainLocked(result);
    if (IsEpochFailure(result) || drained.staleConsumer) {
        RecoverEpochFailureLocked();
        return;
    }
    if (!IsAccepted(result)) return;
    if (!focused) g.textSessionId = 0u;
    if (!RefreshSnapshotLocked() || !g.sessionActive) FailClosedLocked();
}

void PlatformInputDeviceChanged(uint64_t deviceId, bool added,
                                 uint32_t capabilities,
                                 uint32_t rawDeviceClass) {
    if (!PlatformInputCoreEnabled()) return;
    // deviceId 0 is not a usable owner domain: core keys held owners by
    // (deviceId, control), so a removal for 0 would try to release the exact
    // bucket that "identity unavailable" edges share. Reject it as a countable
    // field gap instead of releasing unrelated owners.
    if (deviceId == 0u) {
        trace::RecordMissing(trace::MissingField::Device);
        trace::RecordUnsupported();
        return;
    }
    // Unknown capability bits mean the producer is not speaking this ABI. Drop
    // the unknown part rather than forwarding it: capabilities are advisory for
    // backends, so a fail-closed mask keeps a future producer bug from being
    // interpreted as a capability the platform never proved (notably
    // POINTER_RELATIVE and CAPTURE, which Gate 0 has not established).
    if ((capabilities & ~AMCL_INPUT_DEVICE_CAP_MASK) != 0u) {
        trace::RecordUnsupported();
        capabilities &= AMCL_INPUT_DEVICE_CAP_MASK;
    }
    const uint32_t deviceClass =
        NormalizePointerDeviceClass(rawDeviceClass);
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!g.sessionActive || !g.api) {
        trace::RecordConsumerError(true);
        return;
    }
    // Core owns the release transaction for REMOVED: it emits a deterministic UP
    // for every owner of exactly this device and leaves other devices' owners
    // untouched (§6.4). Publishing is therefore the authoritative fail-safe even
    // when the producer already synthesized UP edges for the legacy plane; the
    // core-side release is idempotent when no owner remains.
    int32_t result = AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    if ((g.api->capabilityBits & AMCL_INPUT_CAP_DEVICE_CLASS) != 0u) {
        AmclInputEvent event = Event(
            AMCL_INPUT_EVENT_DEVICE_CHANGED,
            PointerSourceForClass(deviceClass), deviceId, deviceClass);
        event.payload.device.change =
            added ? AMCL_INPUT_DEVICE_ADDED : AMCL_INPUT_DEVICE_REMOVED;
        event.payload.device.capabilities = capabilities;
        result = g.api->submitEvent(&event);
    } else {
        // Older V1 hosts have the same table layout but no semantics for the
        // former reserved header word. Preserve their established callback and
        // degrade class to UNKNOWN instead of requiring a V2 function table.
        result = g.api->publishDeviceChange(
            deviceId,
            added ? AMCL_INPUT_DEVICE_ADDED : AMCL_INPUT_DEVICE_REMOVED,
            capabilities);
    }
    const shadow::DrainResult drained = RecordAndDrainLocked(result);
    if (IsEpochFailure(result) || drained.staleConsumer) {
        // The change belongs only to the epoch it was submitted against. Never
        // replay it into a refreshed epoch: the new epoch starts with no owners,
        // so a replayed removal would have nothing to release anyway.
        RecoverEpochFailureLocked();
        return;
    }
    if (!IsAccepted(result)) return;
    if (!RefreshSnapshotLocked() || !g.sessionActive) FailClosedLocked();
}

void PlatformInputCaptureRequested(bool requested) {
    // GLFW/SDL cursor mode is intent, not a platform result.  Publish a pending
    // (or voluntarily released) tuple; SetCursorLocked later publishes the
    // authoritative WindowManager outcome through PlatformInputCaptureChanged.
    gCaptureRequestedIntent.store(requested, std::memory_order_release);
    PlatformInputCaptureChanged(requested, false,
                                AMCL_INPUT_CAPTURE_REASON_NONE);
}

void PlatformInputCaptureChanged(bool requested, bool active,
                                 uint32_t reason) {
    if (requested !=
        gCaptureRequestedIntent.load(std::memory_order_acquire)) {
        return;
    }
    if (!PlatformInputCoreEnabled()) return;
    std::lock_guard<std::mutex> lock(g.mutex);
    if (requested && !g.focused &&
        (active || reason != AMCL_INPUT_CAPTURE_REASON_NONE)) {
        return;
    }
    AmclInputEvent event = Event(AMCL_INPUT_EVENT_CAPTURE_CHANGED,
                                 AMCL_INPUT_SOURCE_MOUSE);
    event.payload.capture.requested = requested ? 1u : 0u;
    event.payload.capture.active = active ? 1u : 0u;
    event.payload.capture.reason = reason;
    if (reason == AMCL_INPUT_CAPTURE_REASON_UNSUPPORTED) {
        trace::RecordUnsupported();
    }
    SubmitLocked(event);
}

// 文本提交被拒的观测面。**必须在 g.mutex 内调用**（读 g 的三个字段）。
// 节流用 2 的幂：一次中文候选可以是几十条 commit，不节流会淹掉别的行。
void TextCommitRejected(bool hasApi, bool sessionActive,
                        uint64_t currentSessionId, uint64_t requestedId) {
    static uint64_t rejected = 0u;
    ++rejected;
    if ((rejected & (rejected - 1u)) != 0u) return;
    OH_LOG_WARN(LOG_APP,
        "AMCL_TEXTCOMMIT rejected api=%{public}d sessionActive=%{public}d "
        "current=%{public}llu requested=%{public}llu count=%{public}llu",
        hasApi ? 1 : 0, sessionActive ? 1 : 0,
        static_cast<unsigned long long>(currentSessionId),
        static_cast<unsigned long long>(requestedId),
        static_cast<unsigned long long>(rejected));
}

void PlatformInputRequestReset(uint32_t reason) {
    if (!PlatformInputLifecycleEnabled()) return;
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!g.sessionActive || !g.api) {
        trace::RecordConsumerError(true);
        return;
    }
    if (g.resetLatched) {
        // Core is already reset, but a legacy route may have finalized after the
        // observed overflow RESET. Re-clear reconciliation so duplicate
        // lifecycle cancellation cannot leave that post-reset compatibility
        // edge held; ResetHeld is intentionally idempotent.
        trace::ResetReconciliation();
        g.textSessionId = 0u;
        return;
    }
    const int32_t result = g.api->requestReset(reason);
    const shadow::DrainResult drained = RecordAndDrainLocked(result);
    if (IsEpochFailure(result) || drained.staleConsumer) {
        RecoverEpochFailureLocked();
        return;
    }
    // A conforming host emits RESET to the open maintenance consumer (the
    // shadow::* name is historical). This remains mandatory in typed+shadow0;
    // ShadowEnabled controls only legacy reconciliation. Keep an explicit
    // fail-safe for an accepted request whose drain completed without that edge;
    // ResetHeld is idempotent.
    if (IsAccepted(result) && !drained.observedReset) trace::ResetReconciliation();
    if (IsAccepted(result)) g.textSessionId = 0u;
}

bool PlatformInputTextSessionBegin(uint64_t textSessionId) {
    if (textSessionId == 0u || !PlatformInputTextSessionSupported()) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!g.api || !g.sessionActive || !g.focused || !g.surfaceActive ||
        (g.textSessionId != 0u && g.textSessionId != textSessionId)) {
        return false;
    }
    AmclInputEvent event = Event(
        AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED, AMCL_INPUT_SOURCE_IME);
    event.payload.textSession.textSessionId = textSessionId;
    event.payload.textSession.change = AMCL_INPUT_TEXT_SESSION_STARTED;
    event.payload.textSession.reason = AMCL_INPUT_TEXT_SESSION_REASON_EXPLICIT;
    const int32_t result = SubmitLocked(event);
    if (result != AMCL_INPUT_OK) return false;
    g.textSessionId = textSessionId;
    return true;
}

bool PlatformInputTextSessionEnd(uint64_t textSessionId) {
    if (textSessionId == 0u) return false;
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!g.api || !g.sessionActive || g.textSessionId != textSessionId) {
        return false;
    }
    AmclInputEvent event = Event(
        AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED, AMCL_INPUT_SOURCE_IME);
    event.payload.textSession.textSessionId = textSessionId;
    event.payload.textSession.change = AMCL_INPUT_TEXT_SESSION_ENDED;
    event.payload.textSession.reason = AMCL_INPUT_TEXT_SESSION_REASON_EXPLICIT;
    const int32_t result = SubmitLocked(event);
    if (result != AMCL_INPUT_OK) return false;
    g.textSessionId = 0u;
    return true;
}

bool PlatformInputTextSessionAbort(uint64_t textSessionId) {
    if (textSessionId == 0u) return false;
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!g.api || !g.sessionActive || g.textSessionId != textSessionId) {
        return false;
    }
    AmclInputEvent event = Event(
        AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED, AMCL_INPUT_SOURCE_IME);
    event.payload.textSession.textSessionId = textSessionId;
    event.payload.textSession.change = AMCL_INPUT_TEXT_SESSION_ABORTED;
    event.payload.textSession.reason = AMCL_INPUT_TEXT_SESSION_REASON_EXPLICIT;
    const int32_t result = SubmitLocked(event);
    if (result != AMCL_INPUT_OK) return false;
    g.textSessionId = 0u;
    return true;
}

bool PlatformInputTextCommit(uint64_t textSessionId,
                             const uint8_t* utf8, uint32_t byteCount) {
    if (textSessionId == 0u || !utf8 || byteCount == 0u) return false;
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!g.api || !g.sessionActive || g.textSessionId != textSessionId) {
        // ⭐ 2026-09-05 探针。这条早退此前完全静默，而它有三个成因（无 api / 会话已结束 /
        // 会话号不匹配），其中"号不匹配"意味着中途有过一次 reset 把 g.textSessionId 清零
        // （`PlatformInputRequestReset` 会这么做）—— 那和"从没建立过会话"是两回事。
        TextCommitRejected(g.api != nullptr, g.sessionActive,
                           g.textSessionId, textSessionId);
        return false;
    }
    AmclInputEvent event = Event(
        AMCL_INPUT_EVENT_TEXT_COMMIT, AMCL_INPUT_SOURCE_IME);
    event.payload.textCommit.textSessionId = textSessionId;
    return SubmitTextPacketLocked(event, utf8, byteCount) == AMCL_INPUT_OK;
}

bool PlatformInputTextEditing(uint64_t textSessionId,
                              const uint8_t* utf8, uint32_t byteCount,
                              uint32_t selectionStart,
                              uint32_t selectionLength) {
    if (textSessionId == 0u || (!utf8 && byteCount != 0u)) return false;
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!g.api || !g.sessionActive || g.textSessionId != textSessionId) {
        return false;
    }
    AmclInputEvent event = Event(
        AMCL_INPUT_EVENT_TEXT_EDITING, AMCL_INPUT_SOURCE_IME);
    event.payload.textEditing.textSessionId = textSessionId;
    event.payload.textEditing.selectionStart = selectionStart;
    event.payload.textEditing.selectionLength = selectionLength;
    return SubmitTextPacketLocked(event, utf8, byteCount) == AMCL_INPUT_OK;
}

bool PlatformInputTextSelection(uint64_t textSessionId,
                                uint32_t selectionStart,
                                uint32_t selectionLength) {
    if (textSessionId == 0u) return false;
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!g.api || !g.sessionActive || g.textSessionId != textSessionId) {
        return false;
    }
    AmclInputEvent event = Event(
        AMCL_INPUT_EVENT_TEXT_SELECTION, AMCL_INPUT_SOURCE_IME);
    event.payload.textSelection.textSessionId = textSessionId;
    event.payload.textSelection.selectionStart = selectionStart;
    event.payload.textSelection.selectionLength = selectionLength;
    return SubmitLocked(event) == AMCL_INPUT_OK;
}

bool PlatformInputTextCandidates(uint64_t textSessionId,
                                 const uint8_t* encoded,
                                 uint32_t encodedByteCount,
                                 uint32_t selected, uint32_t pageStart,
                                 uint32_t pageSize, uint32_t itemCount) {
    if (textSessionId == 0u || !encoded || encodedByteCount == 0u) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g.mutex);
    if (!g.api || !g.sessionActive || g.textSessionId != textSessionId) {
        return false;
    }
    AmclInputEvent event = Event(
        AMCL_INPUT_EVENT_TEXT_CANDIDATES, AMCL_INPUT_SOURCE_IME);
    event.payload.textCandidates.textSessionId = textSessionId;
    event.payload.textCandidates.selected = selected;
    event.payload.textCandidates.pageStart = pageStart;
    event.payload.textCandidates.pageSize = pageSize;
    event.payload.textCandidates.itemCount = itemCount;
    return SubmitTextPacketLocked(
               event, encoded, encodedByteCount) == AMCL_INPUT_OK;
}

void PlatformInputNoteCandidatesUnsupported() {
    SaturatingIncrement(gTextCandidatesUnsupported);
    OH_LOG_WARN(LOG_APP,
        "InputMethodController candidate callback unsupported; "
        "candidate list not fabricated count=%{public}llu",
        (unsigned long long)gTextCandidatesUnsupported.load(
            std::memory_order_acquire));
}

uint64_t PlatformInputCandidatesUnsupportedCount() {
    return gTextCandidatesUnsupported.load(std::memory_order_acquire);
}
#ifdef AMCL_INPUT_HOST_TESTING
// Host-test-only seam. See the guarded block in the header for why all four of
// these are compiler-enforced rather than comment-enforced.
uint64_t PlatformInputPhysicalKey(uint32_t ohosKeyCode, uint32_t hardwareScanCode,
                                  uint32_t hidUsage, uint32_t action,
                                  uint32_t modifiers, uint32_t locks,
                                  uint64_t deviceId, int32_t mappedGlfwKey) {
    if (!PlatformInputCoreEnabled()) return 0;
    std::lock_guard<std::mutex> lock(g.mutex);
    const int32_t result = SubmitPhysicalKeyLocked(
        ohosKeyCode, hardwareScanCode, hidUsage, action, modifiers, locks,
        deviceId);
    if (PlatformInputPhysicalRouteUsesTyped()) return 0;
    return trace::BeginKeyObservation(deviceId, ohosKeyCode, action,
                                      mappedGlfwKey,
                                      IsTypedEventAccepted(result));
}
#endif  // AMCL_INPUT_HOST_TESTING

AmclLegacyPhysicalOutcome PlatformInputPhysicalKeyTransaction(
        uint32_t ohosKeyCode, uint32_t hardwareScanCode, uint32_t hidUsage,
        uint32_t action, uint32_t modifiers, uint32_t locks,
        uint64_t deviceId, int32_t mappedGlfwKey,
        int32_t mappedGlfwAction, bool gateAccepted,
        PlatformInputPhysicalKeyRoute route) {
    const auto record = [&](AmclLegacyPhysicalOutcome outcome) {
        trace::RecordPhysicalIngressOutcome(
            trace::PhysicalIngressKind::Key, outcome, deviceId,
            ohosKeyCode, action);
    };

    if (!gateAccepted) {
        record(AMCL_LEGACY_PHYSICAL_GATE_REJECTED);
        if (PlatformInputCoreEnabled()) trace::RecordGateRejected();
        return AMCL_LEGACY_PHYSICAL_GATE_REJECTED;
    }
    if (!IsKeyActionPair(action, mappedGlfwAction)) {
        record(AMCL_LEGACY_PHYSICAL_INVALID_ACTION);
        return AMCL_LEGACY_PHYSICAL_INVALID_ACTION;
    }

    const bool typedRoute = PlatformInputPhysicalRouteUsesTyped();
    const bool reconcile = ShadowEnabled();
    int32_t coreResult = AMCL_INPUT_OK;
    uint64_t observation = 0u;
    if (PlatformInputCoreEnabled()) {
        std::lock_guard<std::mutex> lock(g.mutex);
        coreResult = SubmitPhysicalKeyLocked(
            ohosKeyCode, hardwareScanCode, hidUsage, action, modifiers,
            locks, deviceId);
        if (!typedRoute && reconcile) {
            observation = trace::BeginKeyObservation(
                deviceId, ohosKeyCode, action,
                mappedGlfwKey > 0 ? mappedGlfwKey : -1,
                IsTypedEventAccepted(coreResult));
        }
    }

    if (typedRoute) {
        const AmclLegacyPhysicalOutcome outcome =
            IsTypedEventAccepted(coreResult)
                ? AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED
                : AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED;
        record(outcome);
        return outcome;
    }

    const bool mappingAvailable = mappedGlfwKey > 0;
    if (!mappingAvailable) {
        trace::RecordPhysicalMappingUnavailable(
            trace::PhysicalIngressKind::Key, deviceId, ohosKeyCode, action);
    }
    int32_t routedMappedKey = -1;
    AmclLegacyPhysicalOutcome outcome = route
        ? route(deviceId, ohosKeyCode,
                mappingAvailable ? mappedGlfwKey : -1,
                static_cast<int32_t>(hardwareScanCode), mappedGlfwAction,
                static_cast<int32_t>(modifiers), &routedMappedKey)
        : AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE;
    outcome = NormalizeLegacyCallbackOutcome(outcome);
    if ((outcome == AMCL_LEGACY_PHYSICAL_EMITTED ||
         outcome == AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE) &&
        routedMappedKey < 0) {
        outcome = AMCL_LEGACY_PHYSICAL_INVALID_VALUE;
    }
    if (reconcile) {
        FinalizeEdgeObservation(observation, trace::PhysicalIngressKind::Key,
                                outcome, mappedGlfwAction, routedMappedKey);
    }
    record(outcome);
    return outcome;
}

AmclLegacyPhysicalOutcome PlatformInputPhysicalButtonTransaction(
        uint64_t deviceId, uint32_t nativeButton, uint32_t typedAction,
        int32_t mappedGlfwButton, int32_t mappedGlfwAction,
        bool gateAccepted, PlatformInputPhysicalButtonRoute route,
        uint32_t deviceClass, uint64_t monotonicTimeNs) {
    const auto record = [&](AmclLegacyPhysicalOutcome outcome) {
        trace::RecordPhysicalIngressOutcome(
            trace::PhysicalIngressKind::Button, outcome, deviceId,
            nativeButton, typedAction);
    };
    if (!gateAccepted) {
        record(AMCL_LEGACY_PHYSICAL_GATE_REJECTED);
        if (PlatformInputCoreEnabled()) trace::RecordGateRejected();
        return AMCL_LEGACY_PHYSICAL_GATE_REJECTED;
    }
    if (!IsButtonActionPair(typedAction, mappedGlfwAction)) {
        record(AMCL_LEGACY_PHYSICAL_INVALID_ACTION);
        return AMCL_LEGACY_PHYSICAL_INVALID_ACTION;
    }

    const bool typedRoute = PlatformInputPhysicalRouteUsesTyped();
    const bool reconcile = ShadowEnabled();
    int32_t coreResult = AMCL_INPUT_OK;
    uint64_t observation = 0u;
    if (PlatformInputCoreEnabled()) {
        std::lock_guard<std::mutex> lock(g.mutex);
        coreResult = SubmitPointerButtonLocked(
            deviceId, nativeButton, typedAction, deviceClass,
            monotonicTimeNs);
        if (!typedRoute && reconcile) {
            observation = trace::BeginButtonObservation(
                deviceId, nativeButton, typedAction, mappedGlfwButton,
                IsTypedEventAccepted(coreResult));
        }
    }
    if (typedRoute) {
        const AmclLegacyPhysicalOutcome outcome =
            IsTypedEventAccepted(coreResult)
                ? AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED
                : AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED;
        record(outcome);
        return outcome;
    }

    const bool mappingAvailable = mappedGlfwButton >= 0;
    if (!mappingAvailable) {
        trace::RecordPhysicalMappingUnavailable(
            trace::PhysicalIngressKind::Button, deviceId, nativeButton,
            typedAction);
    }
    int32_t routedMappedButton = -1;
    AmclLegacyPhysicalOutcome outcome = route
        ? route(deviceId, nativeButton,
                mappingAvailable ? mappedGlfwButton : -1,
                mappedGlfwAction, &routedMappedButton)
        : AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE;
    outcome = NormalizeLegacyCallbackOutcome(outcome);
    if ((outcome == AMCL_LEGACY_PHYSICAL_EMITTED ||
         outcome == AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE) &&
        routedMappedButton < 0) {
        outcome = AMCL_LEGACY_PHYSICAL_INVALID_VALUE;
    }
    if (reconcile) {
        FinalizeEdgeObservation(observation, trace::PhysicalIngressKind::Button,
                                outcome, mappedGlfwAction,
                                routedMappedButton);
    }
    record(outcome);
    return outcome;
}

#ifdef AMCL_INPUT_HOST_TESTING
// Direct core-submission seam for physical relative samples, compiled **only**
// for host tests.
//
// Why it is compile-gated instead of merely documented as unused: shipping ArkTS
// goes through PlatformInputPhysicalRelativeTransaction, which additionally owns
// the surface gate and the legacy enqueue. A public entry point that skips both
// is a standing invitation for a future caller to bypass them, and "no product
// caller" written in a comment cannot enforce that. Excluding it from the product
// translation unit makes the compiler the enforcer: adding a product caller now
// fails to link instead of silently acquiring a weaker path.
//
// The evidence rejection below must still enter the per-kind outcome matrix.
// §11 forbids silent drops, and a seam that only bumps the generic `unsupported`
// counter makes "Gate 0 evidence missing" indistinguishable from "no horizontal
// wheel getter" in operational summaries.
uint64_t PlatformInputPointerRelative(
        double rawDx, double rawDy,
        const PlatformInputPointerIdentity& identity) {
    const auto record = [](AmclLegacyPhysicalOutcome outcome) {
        trace::RecordPhysicalIngressOutcome(
            trace::PhysicalIngressKind::Relative, outcome);
    };
    if (!PlatformInputCoreEnabled()) {
        // Deliberately unrecorded. In legacy+shadow0 the neutral core is absent
        // by configuration, and this seam owns no legacy enqueue, so there is no
        // input edge whose fate could be reported. Classifying it would overload
        // BRIDGE_UNAVAILABLE, which the transaction already uses for the distinct
        // "legacy bridge callback missing" fault; two causes behind one code is
        // exactly the ambiguity §11 asks us to avoid. The absence itself is
        // observable through PlatformInputCoreEnabled().
        return 0;
    }
    const bool typedRoute = PlatformInputPhysicalRouteUsesTyped();
    // Order matters and must match PlatformInputPhysicalRelativeTransaction:
    // finiteness first, capability second. The transaction states the rule as "a
    // malformed value never becomes a capability diagnosis"; if this seam checked
    // capability first, the very same NaN sample would be filed as
    // CAPABILITY_REJECTED here and INVALID_VALUE there, and `invalidDelta` would
    // move on one path only. Two buckets for one input is precisely the ambiguity
    // the per-kind matrix exists to remove.
    if (!std::isfinite(rawDx) || !std::isfinite(rawDy)) {
        // Submit only when there is authority to do so, exactly as the
        // transaction does: with evidence present (or on the legacy route) the
        // core keeps its established INVALID_ARGUMENT accounting; without
        // evidence the typed core must not see the sample at all.
        if (!typedRoute || PlatformInputRawRelativeVerified()) {
            std::lock_guard<std::mutex> lock(g.mutex);
            (void)SubmitPointerRelativeLocked(rawDx, rawDy, identity);
        }
        trace::RecordPhysicalRelativeInvalidDelta();
        record(AMCL_LEGACY_PHYSICAL_INVALID_VALUE);
        return 0;
    }
    if (typedRoute && !PlatformInputRawRelativeVerified()) {
        // Evidence is a prerequisite, not a fallback selector, so reject before
        // touching any state owner.
        trace::RecordUnsupported();
        record(AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED);
        return 0;
    }
    int32_t result = AMCL_INPUT_OK;
    {
        std::lock_guard<std::mutex> lock(g.mutex);
        result = SubmitPointerRelativeLocked(rawDx, rawDy, identity);
    }
    if (typedRoute) {
        record(IsTypedEventAccepted(result)
                   ? AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED
                   : AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED);
        return 0;
    }
    // Legacy route: intentionally no matrix entry here. The final outcome is
    // decided by the caller's FinalizeObservation on the returned token, and the
    // reconciliation plane is that record. Stamping an outcome now would either
    // double-count or reuse HANDLED_NO_FINAL_EDGE, whose established meaning is
    // "another raw owner still holds the aggregate control" — a notion that does
    // not exist for a relative delta.
    return trace::BeginRelativeObservation(IsTypedEventAccepted(result));
}
#endif  // AMCL_INPUT_HOST_TESTING

AmclLegacyPhysicalOutcome PlatformInputPhysicalRelativeTransaction(
        double dx, double dy, bool gateAccepted,
        PlatformInputRelativeEnqueue enqueue,
        const PlatformInputPointerIdentity& identity) {
    const auto record = [&](AmclLegacyPhysicalOutcome outcome) {
        trace::RecordPhysicalIngressOutcome(
            trace::PhysicalIngressKind::Relative, outcome);
    };
    if (!gateAccepted) {
        record(AMCL_LEGACY_PHYSICAL_GATE_REJECTED);
        if (PlatformInputCoreEnabled()) trace::RecordGateRejected();
        return AMCL_LEGACY_PHYSICAL_GATE_REJECTED;
    }

    // Route and evidence are immutable host-table decisions. Validation occurs
    // before the evidence rejection below; a certified route additionally lets
    // the core record INVALID_ARGUMENT for malformed values.
    const bool coreEnabled = PlatformInputCoreEnabled();
    const bool reconcile = ShadowEnabled();
    const bool typedRoute = PlatformInputPhysicalRouteUsesTyped();
    const bool finite = std::isfinite(dx) && std::isfinite(dy);
    if (!finite) {
        // A malformed value never becomes a capability diagnosis. When Gate 0
        // evidence is present, preserve the established core-side validation
        // and submission/error counters; without evidence there is no authority
        // to submit even an intentionally invalid platform sample.
        if (coreEnabled && (!typedRoute || PlatformInputRawRelativeVerified())) {
            std::lock_guard<std::mutex> lock(g.mutex);
            const int32_t coreResult =
                SubmitPointerRelativeLocked(dx, dy, identity);
            if (!typedRoute && reconcile) {
                const uint64_t token = trace::BeginRelativeObservation(
                    IsTypedEventAccepted(coreResult));
                if (token != 0u) {
                    trace::FinalizeObservation(
                        token, trace::LegacyResult::InvalidInput);
                }
            }
        }
        trace::RecordPhysicalRelativeInvalidDelta();
        record(AMCL_LEGACY_PHYSICAL_INVALID_VALUE);
        return AMCL_LEGACY_PHYSICAL_INVALID_VALUE;
    }
    if (typedRoute && !PlatformInputRawRelativeVerified()) {
        // Gate 0 evidence is a prerequisite, not a fallback selector. Mixing a
        // legacy delta into a typed physical session would split one device
        // across source planes, so reject before either state owner is touched.
        trace::RecordUnsupported();
        record(AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED);
        return AMCL_LEGACY_PHYSICAL_CAPABILITY_REJECTED;
    }
    int32_t coreResult = AMCL_INPUT_OK;
    uint64_t token = 0u;
    if (coreEnabled) {
        std::lock_guard<std::mutex> lock(g.mutex);
        coreResult = SubmitPointerRelativeLocked(dx, dy, identity);
        if (!typedRoute && reconcile) {
            token = trace::BeginRelativeObservation(
                IsTypedEventAccepted(coreResult));
        }
    }
    if (typedRoute) {
        const AmclLegacyPhysicalOutcome outcome =
            IsTypedEventAccepted(coreResult)
                ? AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED
                : AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED;
        record(outcome);
        return outcome;
    }

    AmclLegacyPhysicalOutcome outcome = enqueue
        ? NormalizeLegacyCallbackOutcome(enqueue(dx, dy))
        : AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE;
    if (reconcile && token != 0u) {
        trace::LegacyResult result = trace::LegacyResult::LegacyFallback;
        if (outcome == AMCL_LEGACY_PHYSICAL_EMITTED ||
            outcome == AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE) {
            result = trace::LegacyResult::Exact;
        } else if (outcome == AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE ||
                   outcome == AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED) {
            result = trace::LegacyResult::BridgeUnavailable;
        } else if (outcome == AMCL_LEGACY_PHYSICAL_INVALID_ACTION ||
                   outcome == AMCL_LEGACY_PHYSICAL_INVALID_VALUE) {
            result = trace::LegacyResult::InvalidInput;
        }
        trace::FinalizeObservation(token, result);
    }
    if (outcome == AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED) {
        trace::RecordPhysicalRelativeEnqueueFailed();
    }
    record(outcome);
    return outcome;
}

#ifdef AMCL_INPUT_HOST_TESTING
// Host-test-only seams (see the guarded block in the header).
uint64_t PlatformInputPointerButton(uint64_t deviceId, uint32_t nativeButton,
                                    uint32_t action, int32_t mappedGlfwButton,
                                    uint32_t deviceClass,
                                    uint64_t monotonicTimeNs) {
    if (!PlatformInputCoreEnabled()) return 0;
    std::lock_guard<std::mutex> lock(g.mutex);
    const int32_t result = SubmitPointerButtonLocked(
        deviceId, nativeButton, action, deviceClass, monotonicTimeNs);
    if (PlatformInputPhysicalRouteUsesTyped()) return 0;
    return trace::BeginButtonObservation(deviceId, nativeButton, action,
                                         mappedGlfwButton,
                                         IsTypedEventAccepted(result));
}

uint64_t PlatformInputPointerWheel(
        float x, float y, bool precise,
        const PlatformInputPointerIdentity& identity) {
    if (!PlatformInputCoreEnabled()) return 0;
    std::lock_guard<std::mutex> lock(g.mutex);
    const int32_t result = SubmitPointerWheelLocked(x, y, precise, identity);
    if (PlatformInputPhysicalRouteUsesTyped()) return 0;
    return trace::BeginWheelObservation(IsTypedEventAccepted(result));
}
#endif  // AMCL_INPUT_HOST_TESTING

AmclLegacyPhysicalOutcome PlatformInputPhysicalWheelTransaction(
        double x, double y, bool precise, bool gateAccepted,
        PlatformInputPhysicalWheelRoute route,
        const PlatformInputPointerIdentity& identity) {
    const auto record = [&](AmclLegacyPhysicalOutcome outcome) {
        trace::RecordPhysicalIngressOutcome(
            trace::PhysicalIngressKind::Wheel, outcome);
    };
    if (!gateAccepted) {
        record(AMCL_LEGACY_PHYSICAL_GATE_REJECTED);
        if (PlatformInputCoreEnabled()) trace::RecordGateRejected();
        return AMCL_LEGACY_PHYSICAL_GATE_REJECTED;
    }
    if (!IsFloatRepresentable(x) || !IsFloatRepresentable(y)) {
        record(AMCL_LEGACY_PHYSICAL_INVALID_VALUE);
        return AMCL_LEGACY_PHYSICAL_INVALID_VALUE;
    }

    const bool typedRoute = PlatformInputPhysicalRouteUsesTyped();
    const bool reconcile = ShadowEnabled();
    int32_t coreResult = AMCL_INPUT_OK;
    uint64_t observation = 0u;
    if (PlatformInputCoreEnabled()) {
        std::lock_guard<std::mutex> lock(g.mutex);
        coreResult = SubmitPointerWheelLocked(
            static_cast<float>(x), static_cast<float>(y), precise, identity);
        if (!typedRoute && reconcile) {
            observation = trace::BeginWheelObservation(
                IsTypedEventAccepted(coreResult));
        }
    }
    if (typedRoute) {
        const AmclLegacyPhysicalOutcome outcome =
            IsTypedEventAccepted(coreResult)
                ? AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED
                : AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED;
        record(outcome);
        return outcome;
    }

    uint32_t detentCount = 0u;
    AmclLegacyPhysicalOutcome outcome = route
        ? NormalizeLegacyCallbackOutcome(route(x, y, &detentCount))
        : AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE;
    if ((outcome == AMCL_LEGACY_PHYSICAL_EMITTED && detentCount == 0u) ||
        (outcome == AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE &&
         detentCount != 0u)) {
        outcome = AMCL_LEGACY_PHYSICAL_INVALID_VALUE;
        detentCount = 0u;
    }
    if (reconcile && observation != 0u) {
        trace::LegacyResult result = trace::LegacyResult::LegacyFallback;
        if (outcome == AMCL_LEGACY_PHYSICAL_EMITTED ||
            outcome == AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE) {
            result = trace::LegacyResult::Quantized;
        } else if (outcome == AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE ||
                   outcome == AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED) {
            result = trace::LegacyResult::BridgeUnavailable;
        } else if (outcome == AMCL_LEGACY_PHYSICAL_INVALID_ACTION ||
                   outcome == AMCL_LEGACY_PHYSICAL_INVALID_VALUE) {
            result = trace::LegacyResult::InvalidInput;
        }
        trace::FinalizeObservation(observation, result, -1, detentCount);
    }
    record(outcome);
    return outcome;
}
void PlatformInputPointerEnter(bool entered) {
    if (!PlatformInputCoreEnabled()) return;
    std::lock_guard<std::mutex> lock(g.mutex);
    AmclInputEvent event = Event(AMCL_INPUT_EVENT_POINTER_ENTER,
                                 AMCL_INPUT_SOURCE_MOUSE);
    event.payload.pointerEnter.entered = entered ? 1u : 0u;
    SubmitLocked(event);
}

void PlatformInputTraceUnverifiedAbsolute() {
    if (!PlatformInputCoreEnabled()) return;
    trace::RecordMissing(trace::MissingField::CursorTransform);
    trace::RecordUnsupported();
}

PlatformInputNativeMouseResult PlatformInputNativeSurfaceMouseTransaction(
        uint64_t sampledPublicationGeneration, double localPxX,
        double localPxY, uint64_t deviceId, uint32_t nativeButton,
        uint32_t typedButtonAction, bool gateAccepted,
        uint32_t rawDeviceClass, uint64_t monotonicTimeNs) {
    // This optional route is immutable in the process-owner host table. Its
    // absence is not an error: the caller continues the established physical
    // button path and native MOVE remains non-routing.
    if (!PlatformInputNativeAbsoluteRouteUsesTyped()) {
        return PlatformInputNativeMouseResult::RouteInactive;
    }
    // Gate rejection has priority over every sample field. A stale callback is
    // not allowed to dereference or diagnose coordinates from a dead surface.
    if (!gateAccepted) {
        if (PlatformInputCoreEnabled()) trace::RecordGateRejected();
        return PlatformInputNativeMouseResult::GateRejected;
    }
    if (sampledPublicationGeneration == 0u ||
        !std::isfinite(localPxX) || !std::isfinite(localPxY) ||
        (typedButtonAction != 0u &&
         typedButtonAction != AMCL_INPUT_ACTION_DOWN &&
         typedButtonAction != AMCL_INPUT_ACTION_UP) ||
        (typedButtonAction != 0u && nativeButton == 0u)) {
        return PlatformInputNativeMouseResult::InvalidSample;
    }

    std::lock_guard<std::mutex> lock(g.mutex);
    // publicationGeneration and surfaceEpoch are different domains. The first
    // proves which retained native window supplied this sample; the second is
    // the core lifecycle epoch accepted with that exact publication. Comparing
    // before constructing the event prevents a delayed callback from borrowing
    // the current epoch after resize/recreate.
    if (!g.api || !g.sessionActive || !g.surfacePublished ||
        !g.surfaceActive || g.publicationGeneration == 0u ||
        g.publicationGeneration != sampledPublicationGeneration ||
        g.surfaceEpoch == 0u || g.widthPx == 0u || g.heightPx == 0u) {
        return PlatformInputNativeMouseResult::StaleSurface;
    }
    if (localPxX < 0.0 || localPxY < 0.0 ||
        localPxX >= static_cast<double>(g.widthPx) ||
        localPxY >= static_cast<double>(g.heightPx)) {
        return PlatformInputNativeMouseResult::InvalidSample;
    }

    const uint32_t deviceClass =
        NormalizePointerDeviceClass(rawDeviceClass);
    const auto boundEvent = [&](uint32_t eventType) {
        AmclInputEvent event{};
        event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
        event.header.structSize = static_cast<uint16_t>(sizeof(event));
        event.header.eventType = eventType;
        event.header.source = PointerSourceForClass(deviceClass);
        event.header.deviceId = deviceId;
        event.header.deviceClass = deviceClass;
        if (monotonicTimeNs != 0u) {
            event.header.monotonicTimeNs = monotonicTimeNs;
            event.header.flags |= AMCL_INPUT_EVENT_FLAG_PLATFORM_TIMESTAMP;
        }
        event.header.sessionEpoch = g.sessionEpoch;
        event.header.focusEpoch = g.focusEpoch;
        event.header.surfaceEpoch = g.surfaceEpoch;
        return event;
    };

    AmclInputEvent absolute = boundEvent(AMCL_INPUT_EVENT_POINTER_ABSOLUTE);
    absolute.payload.pointerAbsolute.localPxX = localPxX;
    absolute.payload.pointerAbsolute.localPxY = localPxY;
    if (typedButtonAction == 0u) {
        return SubmitLocked(absolute) == AMCL_INPUT_OK
            ? PlatformInputNativeMouseResult::Submitted
            : PlatformInputNativeMouseResult::SubmitFailed;
    }

    AmclInputEvent events[2] = {
        absolute, boundEvent(AMCL_INPUT_EVENT_POINTER_BUTTON)};
    events[1].header.flags |=
        AMCL_INPUT_EVENT_FLAG_ABSOLUTE_POSITION_BOUND;
    events[1].payload.pointerButton.nativeButton = nativeButton;
    events[1].payload.pointerButton.action = typedButtonAction;
    if (deviceId == 0u) trace::RecordMissing(trace::MissingField::Device);
    return SubmitBatchLocked(events, 2u) == AMCL_INPUT_OK
        ? PlatformInputNativeMouseResult::Submitted
        : PlatformInputNativeMouseResult::SubmitFailed;
}

PlatformInputRelativeFallbackResult
PlatformInputUnverifiedRelativeFallbackTransaction(
        double dx, double dy, bool gateAccepted,
        PlatformInputRelativeFallbackEnqueue enqueue) {
    if (!gateAccepted) {
        // Teardown won the SurfaceInputGate race, so neither route selection nor
        // enqueue may run. Keep both the fallback-specific count and the
        // reconciliation classification (when core is live) observable.
        trace::RecordRelativeFallbackDisposition(
            trace::RelativeFallbackDisposition::GateRejected);
        if (PlatformInputCoreEnabled()) trace::RecordGateRejected();
        return PlatformInputRelativeFallbackResult::GateRejected;
    }

    // The host table owns the immutable source-plane decision. Invalid numeric
    // input is classified before that route disposition: neither a typed-route
    // rejection nor a selected legacy route may hide NaN/Inf diagnostics.
    const bool typedRoute = PlatformInputPhysicalRouteUsesTyped();
    const bool shadowEnabled = ShadowEnabled();
    const bool coreEnabled = shadowEnabled || typedRoute;
    if (coreEnabled) trace::RecordMissing(trace::MissingField::RawDelta);
    if (!std::isfinite(dx) || !std::isfinite(dy)) {
        trace::RecordRelativeFallbackDisposition(
            trace::RelativeFallbackDisposition::InvalidDelta);
        return PlatformInputRelativeFallbackResult::InvalidDelta;
    }
    if (typedRoute) {
        trace::RecordUnsupported();
        trace::RecordRelativeFallbackDisposition(
            trace::RelativeFallbackDisposition::TypedRouteRejected);
        return PlatformInputRelativeFallbackResult::TypedRouteRejected;
    }

    // Legacy+shadow-off still records the full outcome. It has no neutral
    // session teardown summary, so input_trace also rate-limits immediate
    // enqueue-failure diagnostics for that rollback configuration.
    trace::RecordRelativeFallbackSelected(shadowEnabled);
    if (dx == 0.0 && dy == 0.0) {
        trace::RecordRelativeFallbackDisposition(
            trace::RelativeFallbackDisposition::ZeroDelta);
        return PlatformInputRelativeFallbackResult::ZeroDelta;
    }

    // Checked enqueue is invoked at most once. A missing callback and a bridge
    // refusal have the same fail-closed result; neither is retried because the
    // callback may already have observable side effects before returning.
    if (!enqueue || !enqueue(dx, dy)) {
        trace::RecordRelativeFallbackDisposition(
            trace::RelativeFallbackDisposition::EnqueueFailed);
        return PlatformInputRelativeFallbackResult::EnqueueFailed;
    }
    trace::RecordRelativeFallbackDisposition(
        trace::RelativeFallbackDisposition::Enqueued);
    return PlatformInputRelativeFallbackResult::Enqueued;
}

}  // namespace amcl::input
