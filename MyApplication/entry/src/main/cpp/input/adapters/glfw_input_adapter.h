#ifndef AMCL_GLFW_INPUT_ADAPTER_H
#define AMCL_GLFW_INPUT_ADAPTER_H

#include "../amcl_input_api.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace amcl::input {

// These values intentionally match GLFW's public action ABI, but this adapter
// does not include or depend on glfw_compat. Runtime wiring selects the typed
// physical route from the host capability table; legacy remains a separate
// virtual/touch source plane and both meet only in the final GLFW aggregate.
enum class GlfwInputAction : int32_t {
    kRelease = 0,
    kPress = 1,
    kRepeat = 2,
};

enum class GlfwAdapterStatus : int32_t {
    kOk = 0,
    kNotReady,
    kInvalidConfiguration,
    kOpenFailed,
    kBaselineRejected,
    kHostError,
    kStale,
    kMalformedEvent,
    kUnsupportedText,
    kOverflowReset,
};

// `scanCode` 那个值来自**三个不同的编码空间**，而合并成一个 int32 之后消费者分不出来
// （SDL 把它当 evdev rawcode 用）。这个枚举把"它来自哪一个空间"变成可观测的 ——
// ⚠️ 目前**只用于诊断与计数**，没有进跨 DSO 的 `AmclBackendInputEvent`：那个结构固定 64 字节
// 且两侧都有 static_assert，改它要重建 SDL3；而在知道真机上三条分支各占多少之前就去改 ABI，
// 等于先付代价再看要不要付（计划 §106）。
enum class GlfwScanCodeSource : uint8_t {
    kNone = 0,
    kHardware = 1,  // 平台硬件扫描码（evdev 语义，SDL 想要的就是这个）
    kHidUsage = 2,  // 退回 HID usage —— **不是** evdev 码
    kRawIdentity = 3,  // 再退回 OHOS keyCode —— 与前两者都不同的第三个空间
};

struct GlfwMappedKey {
    int32_t key = 0;
    int32_t scanCode = 0;
    GlfwScanCodeSource scanCodeSource = GlfwScanCodeSource::kNone;
};

// scanCode 的三级 fallback：硬件扫描码 → HID usage → raw identity。三个后端 mapper 共用
// **这一个**定义。⚠️ 2026-08-25 之前有**两份**（`MapOhosKey` 里内联一份、backend_keymaps.cpp
// 里另有一份同名同义的私有函数），只是恰好等价 —— 与 §91 收敛滚轮分格前的形状逐字相同。
// 超出 int32 正域时归 0 而不是环绕成负数：负 scancode 会被下游当成"无扫描码"还是当成真值
// 取决于读者，两种都不该由一次静默环绕决定。
inline int32_t ScanCodeFromOhosIdentity(uint32_t physicalKey,
                                        uint32_t hardwareScanCode,
                                        uint32_t hidUsage,
                                        GlfwScanCodeSource* outSource) {
    uint32_t scan = physicalKey;
    GlfwScanCodeSource source = GlfwScanCodeSource::kRawIdentity;
    if (hardwareScanCode != 0u) {
        scan = hardwareScanCode;
        source = GlfwScanCodeSource::kHardware;
    } else if (hidUsage != 0u) {
        scan = hidUsage;
        source = GlfwScanCodeSource::kHidUsage;
    }
    if (scan > static_cast<uint32_t>(0x7FFFFFFF)) {
        if (outSource) *outSource = GlfwScanCodeSource::kNone;
        return 0;
    }
    if (outSource) *outSource = source;
    return static_cast<int32_t>(scan);
}

using GlfwMapKeyFn = bool (*)(void* context, uint64_t deviceId,
                              uint32_t physicalKey,
                              uint32_t hardwareScanCode, uint32_t hidUsage,
                              GlfwMappedKey* outKey);
using GlfwMapButtonFn = bool (*)(void* context, uint64_t deviceId,
                                 uint32_t nativeButton,
                                 int32_t* outButton);

struct GlfwInputMapper {
    void* context = nullptr;
    GlfwMapKeyFn mapKey = nullptr;
    GlfwMapButtonFn mapButton = nullptr;
};

// Backend-owned OHOS mapping. Platform ingress keeps raw OHOS identity; only
// this GLFW adapter translates it to GLFW key/button values. hardwareScanCode
// is preserved when available and raw identity is used only as a diagnostic
// scancode fallback.
GlfwInputMapper GlfwOhosInputMapper();

struct GlfwKeySinkEvent {
    int32_t key;
    int32_t scanCode;
    GlfwInputAction action;
    // ⚠️ Reader inventory (2026-08-20), because both of these look live and are
    // not. Annotated rather than deleted -- the reasoning differs per field:
    //
    //   `modifiers`  -- carried from AmclInputPhysicalKeyPayload.modifiersSnapshot,
    //     which has a live producer (ArkTS composeGlfwMods -> NAPI -> ingress).
    //     But `typedKeySink` forwards it into GlfwAggregateKeyEvent.modifiers,
    //     and the only consumer of *that* (`dispatchAggregateKey`) now computes
    //     mods unconditionally from `win->keys[]` and never reads it. So the
    //     chain is structurally dead at the GLFW end. That is deliberate: GLFW
    //     derives mods from its own key state, and `win->keys[]` is the only
    //     view that spans both source planes (physical + on-screen virtual
    //     modifier buttons + gamepad-mapped keys).
    //
    //   `lockState`  -- live producer (same path), **zero product readers**:
    //     `typedKeySink` does not forward it and GlfwAggregateKeyEvent has no
    //     such field. Only host tests read it.
    //
    // Neither may be removed: the refactor plan §6.2 lists both
    // `modifiersSnapshot` and `lockState` as members of the neutral `PhysicalKey`
    // event, and §7.2/§7.3 require the LWJGL2 and SDL3 backends to derive their
    // own modifier/keymap state from the same raw identity (SDL needs a platform
    // latch snapshot for SDL_GetModState). `lockState` is also the *only* carrier
    // of the §5.2 hard rule "Caps/Num/Scroll come from the platform latch
    // snapshot, never inferred from held keys" -- delete it and the only thing
    // left to do is infer, which is exactly what is forbidden.
    //
    // Debugging note that motivated writing this down: chasing "the Caps light
    // is on but MC does not see it" along this field leads all the way to
    // `typedKeySink` before the break becomes visible.
    uint32_t modifiers;
    uint32_t lockState;
    uint64_t deviceId;
    uint64_t sequence;
    // core 盖的单调时间戳，原样透传。**0 表示"没有平台时间戳"** —— 复位/设备移除时合成的
    // 那些 fail-safe 释放没有对应的平台事件，所以它们是 0 而不是"现在"。
    // ⚠️ 加这个字段的直接原因：后端 pull ABI 的同名字段声明"core 盖的时间戳"，而生产侧
    // 一行都没写过（恒 0），因为**这些 sink 结构里当时没有可搬的东西**（计划 §103.1）。
    uint64_t monotonicTimeNs;
    // `scanCode` 落在三个编码空间里的哪一个。⚠️ 合成的 fail-safe 释放没有走 mapper，
    // 所以它们是 `kNone` —— 那不是"未知"，是"这条边沿没有平台身份"。
    GlfwScanCodeSource scanCodeSource;
};

struct GlfwButtonSinkEvent {
    int32_t button;
    GlfwInputAction action;
    // ⚠️ **Structurally zero in product builds.** Read from
    // `AmclInputPointerButtonPayload.modifiersSnapshot`, which has **no product
    // writer** (only host tests set it; `SubmitPointerButtonLocked` and
    // `PlatformInputNativeSurfaceMouseTransaction` leave the zero-initialised
    // value alone). Unlike the key payload, `modifiersSnapshot` is NOT part of
    // the §6.2 `PointerButton` contract -- so this one is a genuine dead field
    // rather than protocol completeness.
    //
    // Not removed in this pass only because no record was found of why the
    // payload field was added (it may have been reserved for SDL3's
    // SDL_MouseButtonEvent). Treat the value as meaningless until that is
    // settled; do not build a diagnostic on it -- one such diagnostic already
    // silently stopped working (see the AMCL_KBD leftPress probe in
    // glfw_compat.cpp).
    uint32_t modifiers;
    uint64_t deviceId;
    uint64_t sequence;
    uint64_t surfaceEpoch;
    // Normal native physical button edges require the immediately preceding
    // accepted absolute sample.  Fail-safe releases generated by reset/close
    // deliberately do not, otherwise recovery could leave GLFW held forever.
    bool requiresAbsoluteAuthorization;
    // 见 `GlfwKeySinkEvent::monotonicTimeNs`：0 = 没有平台时间戳。
    uint64_t monotonicTimeNs;
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
};

struct GlfwAbsoluteSinkEvent {
    double x;
    double y;
    uint64_t deviceId;
    uint64_t sequence;
    uint64_t surfaceEpoch;
    uint64_t publicationGeneration;
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
};

struct GlfwRelativeSinkEvent {
    double dx;
    double dy;
    uint64_t deviceId;
    uint64_t sequence;
    uint64_t monotonicTimeNs;
    // True only for API 26 complete hardware movement.  Compatibility relative
    // samples remain fully usable for look but cannot satisfy GLFW Raw Input.
    bool hardwareRaw;
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
};

struct GlfwWheelSinkEvent {
    double x;
    double y;
    uint32_t unit;
    bool precise;
    uint64_t deviceId;
    uint64_t sequence;
    // 见 `GlfwKeySinkEvent::monotonicTimeNs`：0 = 没有平台时间戳。
    uint64_t monotonicTimeNs;
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
};

struct GlfwFocusSinkEvent {
    bool focused;
    uint64_t focusEpoch;
    uint64_t sequence;
    uint64_t monotonicTimeNs;
    // Snapshot seed for a late consumer.  Runtime state must be initialized,
    // but user callbacks must not be manufactured for a state that predates it.
    bool baseline;
};

struct GlfwEnterSinkEvent {
    bool entered;
    uint64_t deviceId;
    uint64_t sequence;
};

struct GlfwCaptureSinkEvent {
    bool requested;
    bool active;
    uint32_t reason;
    uint64_t sequence;
    uint64_t monotonicTimeNs;
    bool baseline;
};

struct GlfwSurfaceSinkEvent {
    AmclInputSurfacePayload surface;
    uint64_t surfaceEpoch;
    uint64_t sequence;
};

struct GlfwSurfaceContextSinkEvent {
    AmclInputSurfaceContextPayload surfaceContext;
    uint64_t surfaceEpoch;
    uint64_t sequence;
    uint64_t monotonicTimeNs;
};

struct GlfwDeviceSinkEvent {
    uint64_t deviceId;
    uint32_t deviceClass;
    uint32_t change;
    uint32_t capabilities;
    uint64_t sequence;
    uint64_t monotonicTimeNs;
};

struct GlfwResetSinkEvent {
    uint32_t reason;
    uint64_t closingEpoch;
    uint64_t sequence;
    // 见 `GlfwKeySinkEvent::monotonicTimeNs`：0 = 没有平台时间戳。
    uint64_t monotonicTimeNs;
};

struct GlfwTextSessionSinkEvent {
    uint64_t textSessionId;
    uint32_t change;
    uint32_t reason;
    uint64_t sequence;
    uint64_t monotonicTimeNs;
};

struct GlfwTextCommitSinkEvent {
    uint64_t textSessionId;
    std::vector<uint8_t> utf8;
    uint64_t sequence;
    uint64_t monotonicTimeNs;
};

struct GlfwTextEditingSinkEvent {
    uint64_t textSessionId;
    std::vector<uint8_t> utf8;
    uint32_t selectionStart;
    uint32_t selectionLength;
    uint64_t sequence;
    uint64_t monotonicTimeNs;
};

struct GlfwTextCandidatesSinkEvent {
    uint64_t textSessionId;
    std::vector<std::string> items;
    uint32_t selected;
    uint32_t pageStart;
    uint32_t pageSize;
    uint64_t sequence;
    uint64_t monotonicTimeNs;
};

struct GlfwTextSelectionSinkEvent {
    uint64_t textSessionId;
    uint32_t selectionStart;
    uint32_t selectionLength;
    uint64_t sequence;
    uint64_t monotonicTimeNs;
};

enum class GlfwUnsupportedMappingKind : uint32_t {
    kKey = 1,
    kButton = 2,
};

// Mapping rejection is non-fatal because an unfamiliar physical control must
// not tear down unrelated held input. The raw, backend-neutral identity remains
// observable here, while no guessed GLFW control or contributor is created.
struct GlfwUnsupportedMappingSinkEvent {
    GlfwUnsupportedMappingKind kind;
    uint32_t rawControl;
    uint32_t action;
    uint64_t deviceId;
    uint32_t hardwareScanCode;
    uint32_t hidUsage;
    uint64_t sequence;
};

// This mirrors a backend-neutral core drop (or the adapter's equivalent
// defensive finding from a foreign host). It deliberately contains no mapped
// GLFW control: a sink may log/count it, but cannot confuse it with input.
struct GlfwDiagnosticDropSinkEvent {
    uint32_t reason;
    uint32_t originalEventType;
    uint32_t rawControl;
    uint32_t action;
    uint32_t hardwareScanCode;
    uint32_t hidUsage;
    uint64_t deviceId;
    uint64_t sequence;
};
using GlfwKeySinkFn = void (*)(void*, const GlfwKeySinkEvent&);
using GlfwButtonSinkFn = void (*)(void*, const GlfwButtonSinkEvent&);
using GlfwAbsoluteSinkFn = void (*)(void*, const GlfwAbsoluteSinkEvent&);
using GlfwRelativeSinkFn = void (*)(void*, const GlfwRelativeSinkEvent&);
using GlfwWheelSinkFn = void (*)(void*, const GlfwWheelSinkEvent&);
using GlfwFocusSinkFn = void (*)(void*, const GlfwFocusSinkEvent&);
using GlfwEnterSinkFn = void (*)(void*, const GlfwEnterSinkEvent&);
using GlfwCaptureSinkFn = void (*)(void*, const GlfwCaptureSinkEvent&);
using GlfwSurfaceSinkFn = void (*)(void*, const GlfwSurfaceSinkEvent&);
using GlfwSurfaceContextSinkFn =
    void (*)(void*, const GlfwSurfaceContextSinkEvent&);
using GlfwDeviceSinkFn = void (*)(void*, const GlfwDeviceSinkEvent&);
using GlfwResetSinkFn = void (*)(void*, const GlfwResetSinkEvent&);
using GlfwUnsupportedMappingSinkFn =
    void (*)(void*, const GlfwUnsupportedMappingSinkEvent&);
using GlfwDiagnosticDropSinkFn =
    void (*)(void*, const GlfwDiagnosticDropSinkEvent&);

using GlfwTextSessionSinkFn =
    void (*)(void*, const GlfwTextSessionSinkEvent&);
using GlfwTextCommitSinkFn =
    void (*)(void*, const GlfwTextCommitSinkEvent&);
using GlfwTextEditingSinkFn =
    void (*)(void*, const GlfwTextEditingSinkEvent&);
using GlfwTextCandidatesSinkFn =
    void (*)(void*, const GlfwTextCandidatesSinkEvent&);
using GlfwTextSelectionSinkFn =
    void (*)(void*, const GlfwTextSelectionSinkEvent&);

// A plain function table keeps this boundary backend-neutral and avoids C++
// closure ownership crossing the future shared-library/runtime seam.
struct GlfwInputSink {
    void* context = nullptr;
    GlfwKeySinkFn key = nullptr;
    GlfwButtonSinkFn button = nullptr;
    GlfwAbsoluteSinkFn absolute = nullptr;
    GlfwRelativeSinkFn relative = nullptr;
    GlfwWheelSinkFn wheel = nullptr;
    GlfwFocusSinkFn focus = nullptr;
    GlfwEnterSinkFn enter = nullptr;
    GlfwCaptureSinkFn capture = nullptr;
    GlfwSurfaceSinkFn surface = nullptr;
    GlfwResetSinkFn reset = nullptr;
    // Diagnostics follow the same lock-free dispatch rule as ordinary events;
    // a callback may query adapter polling state but must not invent an input.
    GlfwUnsupportedMappingSinkFn unsupportedMapping = nullptr;
    GlfwDiagnosticDropSinkFn diagnosticDrop = nullptr;
    // DEVICE_REMOVED is dispatched after the synthetic release batch for that
    // device, so a backend cannot retire its device object before its held
    // controls have been unwound. Kept as an additive tail to preserve existing
    // aggregate source initializers of this internal C++ table.
    GlfwDeviceSinkFn device = nullptr;
    // Additive tail: Window/display context is independent from the retained
    // native render surface and is replayed between SURFACE and DEVICE records.
    GlfwSurfaceContextSinkFn surfaceContext = nullptr;
    // Additive typed-text tail. The vectors own copied host payload for the
    // synchronous callback; a sink retaining data must take its own copy.
    GlfwTextSessionSinkFn textSession = nullptr;
    GlfwTextCommitSinkFn textCommit = nullptr;
    GlfwTextEditingSinkFn textEditing = nullptr;
    GlfwTextCandidatesSinkFn textCandidates = nullptr;
    GlfwTextSelectionSinkFn textSelection = nullptr;
};

struct GlfwPumpResult {
    GlfwAdapterStatus status = GlfwAdapterStatus::kOk;
    uint32_t eventsDrained = 0;
    // Records already fetched from the host but deliberately discharged without
    // a sink callback, because a synchronous Close fenced the mapper or because
    // protocol recovery abandoned the incarnation.
    //
    // ⚠️ This is the count **attributable to this Pump call**, not a process
    // total, and two exits deliberately report 0 rather than a running figure:
    //   · `kStale` returns 0 because the nested `Close()` it performs does its
    //     own discarding, and attributing that to the pump would double-count
    //     against `DiscardedFetchedEventCount()`;
    //   · `abandonCleanup` discards through `AbandonIncarnation` and drops the
    //     out-param on the floor.
    // Use `DiscardedFetchedEventCount()` when you want the process-lifetime
    // figure. The previous wording ("Exact count") read as a guarantee that
    // neither of those exits keeps.
    uint32_t eventsDiscarded = 0;
    bool abandoned = false;
    int32_t recoveryHostStatus = AMCL_INPUT_OK;
};

#if defined(AMCL_GLFW_INPUT_ADAPTER_TESTING)
enum class GlfwInputAdapterTestSeam : uint32_t {
    kAfterNextEvent = 1u,
    kAfterCommitBeforeDispatch = 2u,
    kAfterFetchRegistered = 3u,
};
using GlfwInputAdapterTestHook =
    void (*)(void* context, GlfwInputAdapterTestSeam seam);
void GlfwInputAdapterSetTestHook(GlfwInputAdapterTestHook hook,
                                 void* context);
#endif

// Open 被拒的具体站点。⚠️ 只进诊断日志，不参与判定 —— 加它的理由见 `LastOpenRejectSite`。
enum class GlfwOpenRejectSite : uint32_t {
    kNone = 0u,
    kOpenConsumer = 1u,
    kBaselineEvent = 2u,
    kBaselineIncarnation = 3u,
    kStartupRecordKind = 4u,
    kStartupProcess = 5u,
    kSnapshot = 6u,
    kReadySubmit = 7u,
    kReadyIncarnation = 8u,
};

class GlfwInputAdapter final {
public:
    GlfwInputAdapter();
    ~GlfwInputAdapter();
    GlfwInputAdapter(const GlfwInputAdapter&) = delete;
    GlfwInputAdapter& operator=(const GlfwInputAdapter&) = delete;

    // Open is fail-closed: it replaces any prior consumer, calls openConsumer,
    // and becomes ready only after a validated baseline RESET for the current
    // active session. The injected table is borrowed and must remain stable.
    //
    // `backend` selects which AMCL_INPUT_BACKEND_* READY/RETIRE slot this
    // instance claims in the core. The whole class is backend-parameterised:
    // `mapper` decides which encoding raw OHOS identity becomes, `backend`
    // decides whose retire barrier it owns. They must agree -- a LWJGL2 mapper
    // opened under the GLFW3 backend id would take GLFW3's slot and both
    // adapters would believe they are the current backend.
    GlfwAdapterStatus Open(const AmclInputHostApiV1* api,
                           const GlfwInputMapper& mapper,
                           const GlfwInputSink& sink,
                           uint32_t backend =
                               AMCL_INPUT_BACKEND_GLFW_PHYSICAL);

    // Pump performs no background work. nextEvent, mapper callbacks and sink
    // callbacks run synchronously on the calling thread. No adapter or host-call
    // lock is held while a mapper or sink is entered. Queries and Close may be
    // called synchronously from either callback; Open/Pump remain non-reentrant.
    GlfwPumpResult Pump();

    // A ready backend is explicitly retired, drained (including owned blobs),
    // and only then closed. A cleanup failure retains the remote handle so a
    // later Close/Open can retry instead of orphaning the core's retire gate.
    GlfwAdapterStatus Close();

    bool IsReady() const;
    bool IsKeyPressed(int32_t mappedKey) const;
    bool IsButtonPressed(int32_t mappedButton) const;
    uint64_t SessionEpoch() const;
    bool HasConsumer() const;

    // 上一次 Open 被拒的**站点**与一个站点专属的细节码。⚠️ 纯诊断，不参与任何判定。
    // 为什么必须有：`kBaselineRejected` 把六个互不相同的成因 collapse 成一个返回值，
    // 而真机日志里只有那一个值 —— 2026-08-25 实测 SDL3 那条链恒 `status=4`，六个站点在
    // 设备上分不出来，排查直接停在这里（计划 §105）。成功的 Open 会把它清回 kNone，
    // 所以它读的永远是"最近一次尝试"而不是"历史上曾经"。
    GlfwOpenRejectSite LastOpenRejectSite() const;
    int32_t LastOpenRejectDetail() const;
    uint64_t DiscardedFetchedEventCount() const;
    uint64_t AbandonCount() const;
    uint64_t AbsoluteRouteDropCount() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace amcl::input

#endif
