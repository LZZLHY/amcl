// xcomponent.cpp — XComponent 生命周期管理
// 职责：OnSurfaceCreated/Changed/Destroyed + NAPI 注册
// 通过环境变量将 NativeWindow 指针传递给 GLFW 兼容层

#include "xcomponent.h"
#include "../utils/amcl_log.h"
#include "../input/platform_input_ingress.h"
#include "glfw/glfw_compat.h"
#include "cursor_lock.h"
#include "input_foreground_gate.h"
#include "ohos_frame_rate_hint.h"
#include "ohos_native_window_telemetry.h"
#include "render_scale.h"
#include "touch_input.h"
#if AMCL_INPUT_GATE0_TELEMETRY
#include "gate0_input_telemetry.h"
#endif
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>
#include <hilog/log.h>
#include <climits>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <mutex>
#include <unistd.h>

#undef LOG_TAG
#define LOG_TAG "XCOMPONENT"

// Forward declaration — 触摸 / 鼠标处理在 touch_input.cpp
extern "C" void OnDispatchTouchEvent(OH_NativeXComponent* component, void* window);
extern "C" void OnDispatchMouseEvent(OH_NativeXComponent* component, void* window);
extern "C" void OnDispatchHoverEvent(OH_NativeXComponent* component, bool isHover);
extern "C" void OnDispatchAxisEvent(OH_NativeXComponent* component, ArkUI_UIInputEvent* event);

// 2026-05-29：UIInputEvent 回调适配器。RegisterUIInputEventCallback 的回调签名带
// ArkUI_UIInputEvent_Type，这里转调 OnDispatchAxisEvent（type=AXIS 时滚轮）。
static void OnUIInputEvent(OH_NativeXComponent* component, ArkUI_UIInputEvent* event,
                          ArkUI_UIInputEvent_Type type) {
    if (type == ARKUI_UIINPUTEVENT_TYPE_AXIS) {
        OnDispatchAxisEvent(component, event);
    }
}

// ==================== 全局状态 ====================
static OHNativeWindow* g_window = nullptr;
// g_width/g_height 是**发布尺寸**（渲染缩放生效时 = scaled buffer px）；
// real 尺寸另存于 g_realWidth/g_realHeight，供缩放重应用与比值映射发布使用。
static int g_width = 0;
static int g_height = 0;
static int g_realWidth = 0;
static int g_realHeight = 0;
// 供 amclRenderScaleReapplyForLaunch 重放 Changed 流程：surface gate 的
// update/accept 都要 component+window 成对身份，仅存 g_window 不够。
static OH_NativeXComponent* g_component = nullptr;

namespace {

struct InputForegroundGateState {
    bool surfacePublished = false;
    uint32_t abilityForegroundMask = 0u;
    amcl::ohos::ComponentFocus focus =
        amcl::ohos::ComponentFocus::Unknown;
    bool legacyWouldBe = false;
    bool havePublishedValue = false;
    bool publishedValue = false;
    uint64_t flips = 0u;
    uint64_t publications = 0u;
};

std::mutex g_inputForegroundGateMutex;
InputForegroundGateState g_inputForegroundGate;

const char* ComponentFocusName(amcl::ohos::ComponentFocus focus) {
    switch (focus) {
        case amcl::ohos::ComponentFocus::Unknown:
            return "unknown";
        case amcl::ohos::ComponentFocus::Focused:
            return "focused";
        case amcl::ohos::ComponentFocus::Blurred:
            return "blurred";
    }
    return "invalid";
}

// The only writer of AMCL_WINDOW_FOREGROUND. State mutation and publication
// stay under one lock so every log line is a coherent, countable snapshot.
void PublishInputForegroundGateLocked(const char* reason) {
    InputForegroundGateState& state = g_inputForegroundGate;
    const bool computed = amcl::ohos::ComputeInputForegroundGate(
        state.surfacePublished, state.abilityForegroundMask, state.focus);
    const int setResult =
        setenv("AMCL_WINDOW_FOREGROUND", computed ? "1" : "0", 1);
    const char* value = getenv("AMCL_WINDOW_FOREGROUND");
    const bool valueValid =
        value != nullptr &&
        (strcmp(value, "0") == 0 || strcmp(value, "1") == 0);
    const bool publishedValue = valueValid && strcmp(value, "1") == 0;

    state.publications += 1u;
    if (setResult == 0 && valueValid) {
        if (state.havePublishedValue &&
            state.publishedValue != publishedValue) {
            state.flips += 1u;
        }
        state.havePublishedValue = true;
        state.publishedValue = publishedValue;
    }

    OH_LOG_INFO(
        LOG_APP,
        "event=input-gate reason=%{public}s pid=%{public}d "
        "value=%{public}s computed=%{public}d legacyWouldBe=%{public}d "
        "surface=%{public}d abilityMask=%{public}u focus=%{public}s "
        "flips=%{public}llu publications=%{public}llu setResult=%{public}d",
        reason ? reason : "unknown", static_cast<int>(getpid()),
        value ? value : "missing", computed ? 1 : 0,
        state.legacyWouldBe ? 1 : 0, state.surfacePublished ? 1 : 0,
        state.abilityForegroundMask, ComponentFocusName(state.focus),
        static_cast<unsigned long long>(state.flips),
        static_cast<unsigned long long>(state.publications), setResult);
}

void PublishInputForegroundSurfaceState(bool published, const char* reason) {
    std::lock_guard<std::mutex> lock(g_inputForegroundGateMutex);
    InputForegroundGateState& state = g_inputForegroundGate;
    state.surfacePublished = published;
    // Focus belongs to one surface identity. Carrying Blurred into a newly
    // published generation would make that generation wait for another edge.
    state.focus = amcl::ohos::ComponentFocus::Unknown;
    state.legacyWouldBe = false;
    PublishInputForegroundGateLocked(reason);
}

void PublishInputForegroundFocusState(amcl::ohos::ComponentFocus focus,
                                      const char* reason) {
    std::lock_guard<std::mutex> lock(g_inputForegroundGateMutex);
    InputForegroundGateState& state = g_inputForegroundGate;
    state.focus = focus;
    state.legacyWouldBe = focus == amcl::ohos::ComponentFocus::Focused;
    PublishInputForegroundGateLocked(reason);
}

}  // namespace

void amcl::ohos::PublishInputForegroundGateForAbility(
        uint32_t abilityForegroundMask, const char* reason) {
    std::lock_guard<std::mutex> lock(g_inputForegroundGateMutex);
    g_inputForegroundGate.abilityForegroundMask = abilityForegroundMask;
    PublishInputForegroundGateLocked(reason);
}

class SurfaceInputGateTransaction {
public:
    SurfaceInputGateTransaction() { ohos_surface_input_gate_lock(); }
    ~SurfaceInputGateTransaction() { ohos_surface_input_gate_unlock(); }
    SurfaceInputGateTransaction(const SurfaceInputGateTransaction&) = delete;
    SurfaceInputGateTransaction& operator=(const SurfaceInputGateTransaction&) = delete;
};

static int CheckedSurfaceDimension(uint64_t value, const char* axis) {
    if (value > static_cast<uint64_t>(INT_MAX)) {
        OH_LOG_WARN(LOG_APP, "Surface %{public}s dimension %{public}llu is out of range; suspending",
                    axis, (unsigned long long)value);
        return 0;
    }
    return static_cast<int>(value);
}

// ==================== XComponent 回调 ====================

struct SurfacePublicationMutationContext {
    void* window;
    int width;
    int height;
};

static uint64_t PublishSurfaceMutation(void* opaque,
                                       uint64_t /*previousGeneration*/) {
    auto* context = static_cast<SurfacePublicationMutationContext*>(opaque);
    return glfwOHOS_PublishNativeWindow(context->window, context->width,
                                        context->height);
}

static uint64_t UpdateSurfaceMutation(void* opaque,
                                      uint64_t expectedGeneration) {
    auto* context = static_cast<SurfacePublicationMutationContext*>(opaque);
    return glfwOHOS_UpdateNativeWindowSize(
        context->window, expectedGeneration, context->width, context->height);
}

static uint64_t ClearSurfaceMutation(void* opaque,
                                     uint64_t expectedGeneration) {
    auto* context = static_cast<SurfacePublicationMutationContext*>(opaque);
    return glfwOHOS_ClearNativeWindow(context->window, expectedGeneration);
}

// ==================== 渲染分辨率缩放 ====================
// 应用缩放后的 buffer 几何并返回**发布尺寸**（scale==1 时 == real 且不触碰
// NativeWindow），同时发布输入坐标映射快照。契约与"为什么 SET_BUFFER_GEOMETRY
// 不受 telemetry 头 'active resize 不做查询' 警告约束"（SET 走 buffer queue
// 生产者配置、调用点全在 UI/JS 主线程序列且先于发布）的完整论证见
// render_scale.h 头注释。
static void ApplyRenderScaleGeometry(void* window, int realWidth, int realHeight,
                                     int* publishWidth, int* publishHeight) {
    *publishWidth = realWidth;
    *publishHeight = realHeight;

    bool scaleValid = false;
    const char* scaleText = getenv("AMCL_RENDER_SCALE");
    const double scale =
        amcl::renderscale::ParseScale(scaleText, &scaleValid);
    int scaledWidth = realWidth;
    int scaledHeight = realHeight;
    if (scaleValid && realWidth > 0 && realHeight > 0) {
        scaledWidth = amcl::renderscale::ScaledDimension(realWidth, scale);
        scaledHeight = amcl::renderscale::ScaledDimension(realHeight, scale);
    }

    const bool wantScale =
        scaledWidth != realWidth || scaledHeight != realHeight;
    // 上一次发布处于缩放态而本次回到恒等（进程内重启把 scale 改回 1）时，必须显式
    // 把几何 SET 回 real：BUFFER_GEOMETRY 是 NativeWindow 的持久状态，不还原就残留。
    const bool mustRestore =
        !wantScale && amcl::renderscale::MappingActive() && realWidth > 0 &&
        realHeight > 0;

    if ((wantScale || mustRestore) && window != nullptr) {
        // SET_BUFFER_GEOMETRY 变参序是 (width, height)——与 GET 的 (height, width) 相反。
        const int32_t rc = OH_NativeWindow_NativeWindowHandleOpt(
            static_cast<OHNativeWindow*>(window), SET_BUFFER_GEOMETRY,
            static_cast<int32_t>(wantScale ? scaledWidth : realWidth),
            static_cast<int32_t>(wantScale ? scaledHeight : realHeight));
        if (rc != 0) {
            // 失败按恒等发布：宁可不降分辨率，也不能让输入映射与真实 buffer 几何脱节。
            OH_LOG_WARN(LOG_APP,
                        "[AMCL-RENDER-SCALE] SET_BUFFER_GEOMETRY failed rc=%{public}d "
                        "requested=%{public}.4f real=%{public}dx%{public}d; staying at 1.0",
                        rc, scale, realWidth, realHeight);
        } else if (wantScale) {
            *publishWidth = scaledWidth;
            *publishHeight = scaledHeight;
            OH_LOG_INFO(LOG_APP,
                        "[AMCL-RENDER-SCALE] requested=%{public}.2f "
                        "real=%{public}dx%{public}d effective=%{public}dx%{public}d",
                        scale, realWidth, realHeight, scaledWidth, scaledHeight);
        } else {
            OH_LOG_INFO(LOG_APP,
                        "[AMCL-RENDER-SCALE] restored 1.0 real=%{public}dx%{public}d",
                        realWidth, realHeight);
        }
    }

    amcl::renderscale::PublishSnapshot(realWidth, realHeight, *publishWidth,
                                       *publishHeight);
}

static void DisableCurrentInputSurfaceAfterLifecycleFailure(
        OH_NativeXComponent* component, const char* reason) {
    SurfacePublicationMutationContext clearContext{g_window, 0, 0};
    uint64_t expectedGeneration = 0u;
    const uint64_t clearedGeneration =
        ohos_surface_input_gate_clear_active_transaction(
            g_window ? ClearSurfaceMutation : nullptr, &clearContext,
            &expectedGeneration);
    if (expectedGeneration == 0u) return;

    OH_LOG_ERROR(LOG_APP,
                 "Disabling current input surface after %{public}s "
                 "expectedGeneration=%{public}llu clearGeneration=%{public}llu",
                 reason ? reason : "lifecycle-failure",
                 (unsigned long long)expectedGeneration,
                 (unsigned long long)clearedGeneration);
    // The surface gate is already invalid. Close the SDL-visible activation
    // snapshot before any other lifecycle work can block or dispatch.
    PublishInputForegroundSurfaceState(false, reason);
    if (component) {
        amcl::ohos::SetFrameRateSurfaceReady(component, false, reason);
    }
    amcl::input::PlatformInputSurfaceDestroyed(
        clearedGeneration != 0u ? clearedGeneration : expectedGeneration);
    ohos_cancel_all_input(AMCL_INPUT_CANCEL_SURFACE_LOST);
    g_window = nullptr;
    g_width = 0;
    g_height = 0;
    g_realWidth = 0;
    g_realHeight = 0;
    g_component = nullptr;
    // 输入映射快照与 surface 同生命周期：surface 失效后没有任何坐标可映射。
    amcl::renderscale::ResetSnapshot();
    unsetenv("AMCL_NATIVE_WINDOW");
    unsetenv("AMCL_WINDOW_WIDTH");
    unsetenv("AMCL_WINDOW_HEIGHT");
    unsetenv("AMCL_WINDOW_GENERATION");
}

static void OnSurfaceCreated(OH_NativeXComponent* component, void* window) {
    SurfaceInputGateTransaction gateTransaction;
    AMCL_LOG_I(LOG_TAG, "OnSurfaceCreated");
    if (!component || !window) {
        OH_LOG_ERROR(LOG_APP,
                     "Refusing malformed SurfaceCreated component=%{public}p ptr=%{public}p",
                     component, window);
        DisableCurrentInputSurfaceAfterLifecycleFailure(
            component, "surface-create-malformed");
        return;
    }

    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    const int createdWidth = CheckedSurfaceDimension(w, "width");
    const int createdHeight = CheckedSurfaceDimension(h, "height");
    amcl::ohos::LogNativeWindowSnapshot(
        static_cast<OHNativeWindow*>(window), createdWidth, createdHeight,
        "surface-created");

    // 渲染缩放必须先于发布：渲染侧一旦看到本次发布，尺寸与 buffer 几何就得一致。
    // （首个 surface 建立时 AMCL_RENDER_SCALE 通常还未写入 —— startMC 在其后 ——
    //  由 amclRenderScaleReapplyForLaunch 在 env 写入后重放，见 render_scale.h。）
    int publishWidth = createdWidth;
    int publishHeight = createdHeight;
    ApplyRenderScaleGeometry(window, createdWidth, createdHeight,
                             &publishWidth, &publishHeight);

    SurfacePublicationMutationContext mutationContext{
        window, publishWidth, publishHeight};
    const uint64_t generation = ohos_surface_input_gate_publish_transaction(
        component, window, PublishSurfaceMutation, &mutationContext);
    if (generation == 0) {
        // Publication failure, a duplicate create, or reuse of a retired exact
        // pointer pair cannot establish a trustworthy new identity. The outer
        // lifecycle transaction therefore disables any previous input surface.
        OH_LOG_ERROR(LOG_APP,
                     "NativeWindow publication failed; disabling previous "
                     "input surface ptr=%{public}p",
                     window);
        DisableCurrentInputSurfaceAfterLifecycleFailure(
            component, "surface-create-failed");
        return;
    }

    // All parameters were validated before the callback. The gate transaction
    // installs this generation and its post-publication timestamp boundary
    // while still holding the lifecycle lock.
    g_window = static_cast<OHNativeWindow*>(window);
    g_width = publishWidth;
    g_height = publishHeight;
    g_realWidth = createdWidth;
    g_realHeight = createdHeight;
    g_component = component;
    AMCL_LOG_I(LOG_TAG, "Surface size: %{public}dx%{public}d generation=%{public}llu",
                g_width, g_height, (unsigned long long)generation);

    // 旧 SDL 仍通过环境变量跨 linker namespace 取窗口。尺寸与 generation 先发布，
    // pointer 最后发布；看到 pointer 的读取方不会再拿到上一代尺寸。
    char buf[64];
    snprintf(buf, sizeof(buf), "%d", g_width);
    setenv("AMCL_WINDOW_WIDTH", buf, 1);
    snprintf(buf, sizeof(buf), "%d", g_height);
    setenv("AMCL_WINDOW_HEIGHT", buf, 1);
    snprintf(buf, sizeof(buf), "%llu", (unsigned long long)generation);
    setenv("AMCL_WINDOW_GENERATION", buf, 1);
    snprintf(buf, sizeof(buf), "%llu", (unsigned long long)(uintptr_t)window);
    setenv("AMCL_NATIVE_WINDOW", buf, 1);
    // Recompute from current surface + Ability + three-valued focus state.
    // A new surface starts at Unknown (not explicitly blurred), so activation
    // cannot permanently depend on receiving one component-focus edge.
    PublishInputForegroundSurfaceState(true, "surface-created");
    AMCL_LOG_I(LOG_TAG, "NativeWindow set via env: ptr=%{public}p %{public}dx%{public}d",
                window, g_width, g_height);
    amcl::input::PlatformInputSurfaceCreated(
        static_cast<uint32_t>(g_width), static_cast<uint32_t>(g_height),
        generation);
    amcl::ohos::SetFrameRateSurfaceReady(component, true, "surface-created");
}

// OnSurfaceChanged 与启动时机重放（amclRenderScaleReapplyForLaunch）共用的核心。
// 调用方必须持有 surface gate 锁且 accept 已通过；expectedGeneration 仅用于日志。
// skipIfUnchanged 只有重放路径传 true：真实 Changed 保持既有的"总是重发布"语义，
// 而重放在 scale 未改变发布尺寸时不得白白消耗一个 generation。
static void RefreshPublishedSurfaceGeometry(OH_NativeXComponent* component,
                                            void* window,
                                            uint64_t expectedGeneration,
                                            bool skipIfUnchanged,
                                            const char* reason) {
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    const int newWidth = CheckedSurfaceDimension(w, "width");
    const int newHeight = CheckedSurfaceDimension(h, "height");

    // 尺寸变化（折叠/键盘避让）同样先 SET 新几何再发布，纪律同 Created。
    int publishWidth = newWidth;
    int publishHeight = newHeight;
    ApplyRenderScaleGeometry(window, newWidth, newHeight, &publishWidth,
                             &publishHeight);

    if (skipIfUnchanged && newWidth == g_realWidth &&
        newHeight == g_realHeight && publishWidth == g_width &&
        publishHeight == g_height) {
        return;
    }

    SurfacePublicationMutationContext mutationContext{
        window, publishWidth, publishHeight};
    const uint64_t generation = ohos_surface_input_gate_update_transaction(
        component, window, UpdateSurfaceMutation, &mutationContext);
    if (generation == 0) {
        // This callback was already accepted as the current OS surface. Once
        // its geometry mutation fails, preserving the old gate would admit
        // later input under stale bounds/epoch. Reuse the authoritative clear
        // transaction: it invalidates the gate before its fallible broker
        // cleanup, so even generation exhaustion remains fail-closed.
        OH_LOG_ERROR(LOG_APP,
                     "SurfaceChanged mutation failed; input surface disabled "
                     "ptr=%{public}p expectedGeneration=%{public}llu "
                     "(%{public}dx%{public}d)",
                     window, (unsigned long long)expectedGeneration,
                     publishWidth, publishHeight);
        DisableCurrentInputSurfaceAfterLifecycleFailure(
            component, "surface-change-failed");
        return;
    }

    g_width = publishWidth;
    g_height = publishHeight;
    g_realWidth = newWidth;
    g_realHeight = newHeight;
    OH_LOG_INFO(LOG_APP,
                "Surface changed: %{public}dx%{public}d generation=%{public}llu",
                g_width, g_height, (unsigned long long)generation);

    // 更新环境变量，让 GLFW 兼容层能感知尺寸变化
    char buf[64];
    snprintf(buf, sizeof(buf), "%d", g_width);
    setenv("AMCL_WINDOW_WIDTH", buf, 1);
    snprintf(buf, sizeof(buf), "%d", g_height);
    setenv("AMCL_WINDOW_HEIGHT", buf, 1);
    snprintf(buf, sizeof(buf), "%llu", (unsigned long long)generation);
    setenv("AMCL_WINDOW_GENERATION", buf, 1);
    amcl::input::PlatformInputSurfaceChanged(
        static_cast<uint32_t>(g_width), static_cast<uint32_t>(g_height),
        generation);
    amcl::ohos::ApplyExpectedFrameRateHint(component, reason);
}

static void OnSurfaceChanged(OH_NativeXComponent* component, void* window) {
    SurfaceInputGateTransaction gateTransaction;
    const uint64_t expectedGeneration =
        ohos_surface_input_gate_accept(component, window);
    if (expectedGeneration == 0) {
        OH_LOG_WARN(LOG_APP,
                    "Ignoring stale SurfaceChanged gate identity "
                    "component=%{public}p ptr=%{public}p",
                    component, window);
        return;
    }
    RefreshPublishedSurfaceGeometry(component, window, expectedGeneration,
                                    false, "surface-changed");
}

// 启动时机补偿入口（mc_launcher 在写完 AMCL_RENDER_SCALE 后同步调用，见
// render_scale.h）。与 surface 回调同一 JS/UI 线程序列，锁序也与回调一致。
extern "C" void amclRenderScaleReapplyForLaunch(void) {
    SurfaceInputGateTransaction gateTransaction;
    if (g_component == nullptr || g_window == nullptr) {
        // surface 尚未创建（或已销毁）：之后的 OnSurfaceCreated 会读到刚写的 env。
        return;
    }
    const uint64_t expectedGeneration =
        ohos_surface_input_gate_accept(g_component, g_window);
    if (expectedGeneration == 0) return;
    RefreshPublishedSurfaceGeometry(g_component, g_window, expectedGeneration,
                                    true, "render-scale-launch");
}

static void OnSurfaceDestroyed(OH_NativeXComponent* component, void* window) {
    SurfaceInputGateTransaction gateTransaction;
    AMCL_LOG_I(LOG_TAG, "OnSurfaceDestroyed");

    // OHOS supplies no publication token to this callback. Matching destroy is
    // accepted only for the active identity; once retired, the exact pointer
    // pair is quarantined and can never activate a later surface. This trades a
    // rare same-address recreation for deterministic fail-closed behavior.
    const uint64_t expectedGeneration =
        ohos_surface_input_gate_accept(component, window);
    if (expectedGeneration == 0) {
        OH_LOG_WARN(LOG_APP,
                    "Ignoring stale SurfaceDestroyed gate identity "
                    "component=%{public}p ptr=%{public}p",
                    component, window);
        return;
    }

    SurfacePublicationMutationContext mutationContext{window, 0, 0};
    const uint64_t generation = ohos_surface_input_gate_clear_transaction(
        component, window, ClearSurfaceMutation, &mutationContext);
    if (generation == 0) {
        // Identity acceptance above proves this is the current OS destroy, not a
        // stale callback. GLFW publication cleanup may have failed (notably at
        // generation exhaustion), but restoring the gate would admit input to a
        // dead surface. Continue typed/legacy teardown and clear compatibility
        // snapshots; the native publication remains an observable fail-closed
        // cleanup failure rather than being treated as a live surface.
        OH_LOG_ERROR(LOG_APP,
                     "SurfaceDestroyed publication clear failed; input remains "
                     "permanently inactive ptr=%{public}p expectedGeneration=%{public}llu",
                     window, (unsigned long long)expectedGeneration);
    }
    // ClearCurrent invalidated the authoritative surface identity before its
    // fallible broker mutation. Publish inactive immediately, even when the
    // broker cleanup above returned zero.
    PublishInputForegroundSurfaceState(false, "surface-destroyed");
    amcl::ohos::SetFrameRateSurfaceReady(component, false,
                                         "surface-destroyed");

    // The matching destroy always closes typed and legacy state, regardless of
    // publication cleanup success. The clear transaction invalidated the gate
    // before mutation, so no new callback can race this zero-held boundary.
    amcl::input::PlatformInputSurfaceDestroyed(
        generation != 0u ? generation : expectedGeneration);
    ohos_cancel_all_input(AMCL_INPUT_CANCEL_SURFACE_LOST);
    g_window = nullptr;
    g_width = 0;
    g_height = 0;
    g_realWidth = 0;
    g_realHeight = 0;
    g_component = nullptr;
    // 映射快照随 surface 一起失效；下一个 surface 的 Created 会重新发布。
    amcl::renderscale::ResetSnapshot();
    // Keep the environment variables only as a linker-namespace compatibility
    // fallback. Once the matching surface is gone they must not expose a stale
    // OHNativeWindow pointer to a later GLFW startup.
    unsetenv("AMCL_NATIVE_WINDOW");
    unsetenv("AMCL_WINDOW_WIDTH");
    unsetenv("AMCL_WINDOW_HEIGHT");
    unsetenv("AMCL_WINDOW_GENERATION");
    AMCL_LOG_I(LOG_TAG, "Surface snapshot cleared generation=%{public}llu",
                (unsigned long long)generation);
}

static void OnFocus(OH_NativeXComponent* component, void* window) {
    SurfaceInputGateTransaction gateTransaction;
    ohos_surface_input_gate_log_focus_edge(true, component, window);
    if (ohos_surface_input_gate_accept(component, window) == 0) return;
    amcl::input::PlatformInputFocusChanged(true);
    PublishInputForegroundFocusState(amcl::ohos::ComponentFocus::Focused,
                                     "focus");
    amcl::ohos::SetFrameRateFocused(component, true, "focus");
}

static void OnBlur(OH_NativeXComponent* component, void* window) {
    SurfaceInputGateTransaction gateTransaction;
    ohos_surface_input_gate_log_focus_edge(false, component, window);
    if (ohos_surface_input_gate_accept(component, window) == 0) return;
    // Publish typed focus loss before releasing legacy owners while the same
    // surface gate transaction excludes new ingress. This ordering lets the
    // host synthesize typed releases/reset first, then cancelAll makes the
    // legacy ledger reach the same zero-held boundary before callbacks resume.
    amcl::input::PlatformInputFocusChanged(false);
    PublishInputForegroundFocusState(amcl::ohos::ComponentFocus::Blurred,
                                     "blur");
    ohos_cancel_all_input(AMCL_INPUT_CANCEL_FOCUS_LOST);
    // The window manager releases the cursor lock by itself on focus loss.
    // Record it here so the next lock request is not skipped as redundant;
    // this is the authoritative edge, earlier than any ArkTS observation.
    amcl_cursor_lock_note_focus_lost();
    amcl::ohos::SetFrameRateFocused(component, false, "blur");
}

// ==================== XComponent 回调表 ====================
static OH_NativeXComponent_Callback g_xcomponentCallbacks = {
    .OnSurfaceCreated = OnSurfaceCreated,
    .OnSurfaceChanged = OnSurfaceChanged,
    .OnSurfaceDestroyed = OnSurfaceDestroyed,
    .DispatchTouchEvent = OnDispatchTouchEvent,
};

// Phase E.2（键鼠适配 2026-05-29）：鼠标事件走专门通道。
// 之前注释里假设鼠标会经 DispatchTouchEvent 上报，真机日志证实**鼠标左键根本不会**
// 触发 onMouse（ArkUI 把鼠标左键当触摸事件路径）；要保证左键能在 grabbed 模式下
// 正常发到 MC，必须直接注册 native DispatchMouseEvent 回调。
static OH_NativeXComponent_MouseEvent_Callback g_mouseCallbacks = {
    .DispatchMouseEvent = OnDispatchMouseEvent,
    .DispatchHoverEvent = OnDispatchHoverEvent,
};

// ==================== NAPI 注册 ====================
static napi_value MakeBoolean(napi_env env, bool value) {
    napi_value result = nullptr;
    if (napi_get_boolean(env, value, &result) != napi_ok) {
        return nullptr;
    }
    return result;
}

static napi_value SetOhosFrameRateForeground(napi_env env,
                                             napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok ||
        argc != 2) {
        return MakeBoolean(env, false);
    }

    int32_t source = 0;
    bool foreground = false;
    if (napi_get_value_int32(env, argv[0], &source) != napi_ok ||
        napi_get_value_bool(env, argv[1], &foreground) != napi_ok ||
        source <= 0) {
        return MakeBoolean(env, false);
    }
    return MakeBoolean(env, amcl::ohos::SetFrameRateForegroundSource(
                                static_cast<uint32_t>(source), foreground,
                                foreground ? "ability-foreground"
                                           : "ability-background"));
}

static napi_value SetOhosFrameRateCap(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok ||
        argc != 1) {
        return MakeBoolean(env, false);
    }

    int32_t cap = 0;
    if (napi_get_value_int32(env, argv[0], &cap) != napi_ok) {
        return MakeBoolean(env, false);
    }
    return MakeBoolean(
        env, amcl::ohos::SetRuntimeFrameRateCap(cap, "runtime-cap"));
}

static napi_value RefreshOhosFrameRateHint(napi_env env,
                                           napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok ||
        argc > 1) {
        return MakeBoolean(env, false);
    }
    int32_t displayRate = 0;
    if (argc == 1 &&
        napi_get_value_int32(env, argv[0], &displayRate) != napi_ok) {
        return MakeBoolean(env, false);
    }
    return MakeBoolean(
        env, amcl::ohos::RefreshExpectedFrameRateHintForDisplayRate(
                 displayRate, "display-change"));
}

static constexpr napi_property_descriptor kOhosRuntimeDescriptors[] = {
    {"setOhosFrameRateForeground", nullptr, SetOhosFrameRateForeground,
     nullptr, nullptr, nullptr, napi_default, nullptr},
    {"setOhosFrameRateCap", nullptr, SetOhosFrameRateCap, nullptr, nullptr,
     nullptr, napi_default, nullptr},
    {"refreshOhosFrameRateHint", nullptr, RefreshOhosFrameRateHint, nullptr,
     nullptr, nullptr, napi_default, nullptr},
};

extern "C" void RegisterXComponent(napi_env env, napi_value exports) {
    const napi_status runtimeStatus = napi_define_properties(
        env, exports,
        sizeof(kOhosRuntimeDescriptors) / sizeof(kOhosRuntimeDescriptors[0]),
        kOhosRuntimeDescriptors);
    if (runtimeStatus != napi_ok) {
        OH_LOG_WARN(LOG_APP,
                    "OHOS runtime NAPI registration failed (status=%{public}d)",
                    static_cast<int>(runtimeStatus));
    }

    napi_value exportInstance = nullptr;
    OH_NativeXComponent* nativeXComponent = nullptr;

    napi_status status = napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance);
    if (status != napi_ok) {
        OH_LOG_WARN(LOG_APP, "No XComponent object found in exports, skipping registration (status=%{public}d)", (int)status);
        return;
    }

    napi_valuetype type = napi_undefined;
    napi_typeof(env, exportInstance, &type);
    if (type == napi_undefined || type == napi_null) {
        OH_LOG_WARN(LOG_APP, "XComponent export is undefined/null, skipping");
        return;
    }

    void* nativePtr = nullptr;
    status = napi_unwrap(env, exportInstance, &nativePtr);
    if (status != napi_ok || nativePtr == nullptr) {
        OH_LOG_WARN(LOG_APP, "napi_unwrap failed (status=%{public}d), skipping XComponent registration", (int)status);
        return;
    }
    nativeXComponent = (OH_NativeXComponent*)nativePtr;

    amcl::ohos::RegisterFrameRateComponent(nativeXComponent);
    OH_NativeXComponent_RegisterCallback(nativeXComponent, &g_xcomponentCallbacks);
    // Phase E.2：注册 native 鼠标 / 悬浮通道。部分 API 24 设备会注册成功却为按钮
    // 上报 NONE/NONE；按钮边沿因此还要与 ArkUI onMouse 做 first-valid-source 仲裁，
    // 不能再把 mr==0 当作 native 按钮一定可用。
    int32_t mr = OH_NativeXComponent_RegisterMouseEventCallback(nativeXComponent, &g_mouseCallbacks);
    // 2026-05-29：注册 UIInputEvent(AXIS) 回调收滚轮。鼠标滚轮不在 MouseEvent 结构体里
    // （它只有 x/y/action/button），必须走这条 axis 通道，否则滚轮的物理移动会被
    // DispatchTouchEvent 当触摸 MOVE → grabbed 模式转视角（"滚轮上下移动视角"的真凶）。
    int32_t ar = OH_NativeXComponent_RegisterUIInputEventCallback(
        nativeXComponent, OnUIInputEvent, ARKUI_UIINPUTEVENT_TYPE_AXIS);
#if AMCL_INPUT_GATE0_TELEMETRY
    // The API-23 SDK contract says RegisterUIInputEventCallback currently
    // supports AXIS only. Rich mouse fields therefore come from the exact
    // production ArkTS .onMouse callback through a read-only NAPI probe.
    amcl_gate0_trace_probe_ready();
#endif
    const int32_t focusResult =
        OH_NativeXComponent_RegisterFocusEventCallback(nativeXComponent, OnFocus);
    const int32_t blurResult =
        OH_NativeXComponent_RegisterBlurEventCallback(nativeXComponent, OnBlur);
    // No frame callback is registered: focus, Ability and surface transitions
    // update one scheduler hint around Minecraft's existing render loop.
    OH_LOG_INFO(LOG_APP,
                "XComponent callbacks registered (mouse=%{public}d, "
                "axis=%{public}d, focus=%{public}d, blur=%{public}d)",
                mr, ar, focusResult, blurResult);
}
