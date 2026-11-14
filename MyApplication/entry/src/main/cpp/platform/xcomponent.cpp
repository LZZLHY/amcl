// xcomponent.cpp — XComponent 生命周期管理
// 职责：OnSurfaceCreated/Changed/Destroyed + NAPI 注册。NativeWindow、发布尺寸与输入前台位
// 都只经窗口宿主（租约快照 + broker 尾部）发布，本文件不写任何环境变量（I27-05）。
// 尺寸与身份都未变的真实 Changed 不推进代次（I27-04）。

#include "xcomponent.h"
#include "../utils/amcl_log.h"
#include "../input/platform_input_ingress.h"
#include "glfw/glfw_compat.h"
#include "cursor_lock.h"
#include "input_foreground_gate.h"
#include "window_host.h"
#include "ohos_frame_rate_hint.h"
#include "ohos_native_window_telemetry.h"
#include "render_scale.h"
#include "render_resolution_state.h"
#include "surface_republish_policy.h"
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
#include <atomic>
#include <sstream>
#include <chrono>
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
// 已应用显示几何与最新平台区域分开；UI只记录后者，活动生产者的修改交给owner安全点。
static int g_surfaceWidth = 0, g_surfaceHeight = 0;
static amcl::renderscale::ResolutionState g_resolution;
static std::atomic<uint32_t> g_resolutionWork{0};
static bool g_geometryClientRegistered = false;
static bool g_haveDrawableObservation = false;
static bool g_runtimeResolutionRequest = false;
static uint64_t g_timedRevision = 0;
static std::atomic<int64_t> g_resolutionChangedAtNs{0};
static int64_t ResolutionNowNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
static uint32_t ResolutionWorkFlags() { return g_resolutionWork.load(std::memory_order_acquire); }
static int ResolutionCheckpoint(void*, uint64_t, uint64_t);
static void ResolutionDrawableObserved(void*, uint64_t, uint64_t, int, int, uint32_t);
static const AmclWindowGeometryClientV1 g_geometryClient{
    sizeof(AmclWindowGeometryClientV1), 1, ResolutionWorkFlags, ResolutionCheckpoint, ResolutionDrawableObserved};
static void PublishResolutionWork() {
    const uint32_t flags = g_resolution.flags();
    if (flags != g_resolutionWork.load(std::memory_order_relaxed) || g_timedRevision != g_resolution.revision()) {
        g_timedRevision = g_resolution.revision();
        g_resolutionChangedAtNs.store(ResolutionNowNs(), std::memory_order_release);
    }
    g_resolutionWork.store(flags, std::memory_order_release);
}

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

// 输入前台门禁的唯一发布者。状态变更与发布在同一把锁内，每条日志都是可计数的一致快照。
// 结果写进窗口宿主 broker 的前台尾部（owner 映像内一个原子量），SDL 经已缓存的 broker
// 无锁读取；不写环境变量，不存在读者持有的字符串被释放的问题（I27-05）。
// broker=1 表示 owner 已接受；0 表示窗口宿主描述符畸形、未发布，此时 value=unpublished。
void PublishInputForegroundGateLocked(const char* reason) {
    InputForegroundGateState& state = g_inputForegroundGate;
    const bool computed = amcl::ohos::ComputeInputForegroundGate(
        state.surfacePublished, state.abilityForegroundMask, state.focus);
    const int storeResult = amclWindowHostSetInputForeground(computed ? 1 : 0);
    const bool stored = storeResult == 1;

    state.publications += 1u;
    if (stored) {
        if (state.havePublishedValue && state.publishedValue != computed) {
            state.flips += 1u;
        }
        state.havePublishedValue = true;
        state.publishedValue = computed;
    }

    OH_LOG_INFO(
        LOG_APP,
        "event=input-gate reason=%{public}s pid=%{public}d "
        "value=%{public}s computed=%{public}d legacyWouldBe=%{public}d "
        "surface=%{public}d abilityMask=%{public}u focus=%{public}s "
        "flips=%{public}llu publications=%{public}llu broker=%{public}d",
        reason ? reason : "unknown", static_cast<int>(getpid()),
        stored ? (computed ? "1" : "0") : "unpublished", computed ? 1 : 0,
        state.legacyWouldBe ? 1 : 0, state.surfacePublished ? 1 : 0,
        state.abilityForegroundMask, ComponentFocusName(state.focus),
        static_cast<unsigned long long>(state.flips),
        static_cast<unsigned long long>(state.publications), storeResult);
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
    // 恢复前台重新给owner完整确认窗口；不把后台停帧时间算作几何失败。
    // 只写单个原子时点，不在foreground锁内反向取得surface gate。
    if (g_inputForegroundGate.abilityForegroundMask == 0 && abilityForegroundMask != 0)
        g_resolutionChangedAtNs.store(ResolutionNowNs(), std::memory_order_release);
    g_inputForegroundGate.abilityForegroundMask = abilityForegroundMask;
    // 同一OR-mask同时驱动输入可见性和capture准入；只写原子位，不在frame-rate
    // 发布锁内调用窗口管理器。Unknown组件焦点在前台恢复后仍然有效。
    amcl_cursor_lock_set_foreground(abilityForegroundMask != 0u);
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
// 仅在首次生产者出现前或真实呈现owner的安全点调用。两个平台操作均不具备跨线程
// 自动互斥保证；成功只是配置候选，映射要与后续broker/input发布一起提交。
static bool ApplyRenderScaleGeometry(void* window, const amcl::renderscale::ResolutionTarget& target, uint64_t revision) {
    if (!window || target.displayWidth <= 0 || target.displayHeight <= 0) return false;
    auto* native = static_cast<OHNativeWindow*>(window);
    // 原生尺寸不需要缩放能力；可选缩放模式失败不能阻断100%的原有基线。
    const bool scaled = target.width != target.displayWidth || target.height != target.displayHeight;
    const int32_t scaling = scaled ? OH_NativeWindow_NativeWindowSetScalingModeV2(native, OH_SCALING_MODE_SCALE_TO_WINDOW_V2) : 0;
    const int32_t geometry = scaling == 0 ? OH_NativeWindow_NativeWindowHandleOpt(
        native, SET_BUFFER_GEOMETRY, target.width, target.height) : scaling;
    if (scaling != 0 || geometry != 0) {
        OH_LOG_ERROR(LOG_APP, "[AMCL-RESOLUTION] configure-failed scaling=%{public}d geometry=%{public}d request=%{public}llu",
            scaling, geometry, static_cast<unsigned long long>(revision));
        return false;
    }
    OH_LOG_INFO(LOG_APP, "[AMCL-RESOLUTION] configured request=%{public}llu scale=%{public}.4f display=%{public}dx%{public}d logical=%{public}dx%{public}d actual=pending",
        static_cast<unsigned long long>(revision), target.scale, target.displayWidth, target.displayHeight, target.width, target.height);
    return true;
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
    g_resolution.suspend();
    g_surfaceWidth = g_surfaceHeight = 0;
    g_haveDrawableObservation = false;
    PublishResolutionWork();
    ohos_surface_input_gate_set_geometry_pending(false);
}

// 2 的幂节流：只在第 1、2、4、8… 次记录重复事件，计数本身仍逐次累加供诊断。
static bool FirstOrPowerOfTwo(uint64_t count) {
    return count != 0u && (count & (count - 1u)) == 0u;
}

// 发布尺寸只经窗口宿主快照/租约提供：SDL VideoInit 读 broker 快照，LWJGL2 读
// glfwGetFramebufferSize，打包的 HAP 中没有其他读者，所以这里不再维护尺寸环境槽位。
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
    AmclWindowHostStats createdOwner{};
    amclWindowHostGetStats(&createdOwner);
    if (ohos_surface_input_gate_accept(component, window) != 0 ||
        (window == g_window && createdOwner.livePresentationToken != 0)) {
        // 重复/歧义Create不能在UI线程配置一个已有producer的NativeWindow。
        DisableCurrentInputSurfaceAfterLifecycleFailure(component, "surface-create-occupied");
        g_resolution.requireRestart("surface-create-occupied");
        PublishResolutionWork();
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
    g_geometryClientRegistered = amclWindowHostRegisterGeometryClient(&g_geometryClient) == 1;
    if (!g_geometryClientRegistered) {
        DisableCurrentInputSurfaceAfterLifecycleFailure(component, "geometry-client-conflict");
        g_resolution.requireRestart("geometry-client-conflict");
        PublishResolutionWork();
        return;
    }
    // 新资源必须撤销旧actual证据；即使物理尺寸相同，也要重新配置和确认。
    g_resolution.suspend();
    g_resolution.displayChanged(createdWidth, createdHeight);
    if (createdWidth > 0 && createdHeight > 0 &&
        !ApplyRenderScaleGeometry(window, g_resolution.target(), g_resolution.revision())) {
        g_resolution.nativeFallback(createdWidth, createdHeight, "initial-geometry-rejected");
        if (!ApplyRenderScaleGeometry(window, g_resolution.target(), g_resolution.revision())) {
            DisableCurrentInputSurfaceAfterLifecycleFailure(component, "initial-geometry-failed");
            return;
        }
    }
    if (createdWidth > 0 && createdHeight > 0) {
        publishWidth = g_resolution.target().width;
        publishHeight = g_resolution.target().height;
    }

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
    g_surfaceWidth = createdWidth;
    g_surfaceHeight = createdHeight;
    g_haveDrawableObservation = false;
    if (createdWidth > 0 && createdHeight > 0) g_resolution.configured(generation, g_resolution.revision());
    amcl::renderscale::PublishSnapshot(createdWidth, createdHeight, publishWidth, publishHeight);
    PublishResolutionWork();
    // 创建成功只是发布了配置；首次 actual 之前同样停收游戏输入，避免低分辨率映射
    // 已更新而游戏 drawable 尚未建立。独立 ArkUI 护栏不经过这个游戏输入门。
    ohos_surface_input_gate_set_geometry_pending(true);
    AMCL_LOG_I(LOG_TAG, "Surface size: %{public}dx%{public}d generation=%{public}llu",
                g_width, g_height, (unsigned long long)generation);

    // 由当前 surface + Ability + 三值焦点重新计算。新 surface 从 Unknown（不是显式失焦）
    // 开始，激活不会永久依赖收到一次组件焦点边沿。窗口指针只经窗口宿主发布，没有环境镜像。
    PublishInputForegroundSurfaceState(true, "surface-created");
    AMCL_LOG_I(LOG_TAG, "NativeWindow published via window host: ptr=%{public}p %{public}dx%{public}d",
                window, g_width, g_height);
    amcl::input::PlatformInputSurfaceCreated(
        static_cast<uint32_t>(g_width), static_cast<uint32_t>(g_height),
        generation);
    amcl::ohos::SetFrameRateSurfaceReady(component, true, "surface-created");
}

// 刷新几何的触发者。两者都在“身份、真实尺寸、发布尺寸全都未变”时不推进 generation；
// 区别只在未变时是否仍重设帧率提示：真实回调要重设（语义同一次尺寸事件），重放不需要。
enum class SurfaceRefreshCause { kSurfaceChanged, kLaunchReplay };

// I27-04：身份与尺寸都未变的真实 OnSurfaceChanged 次数。只在 UI 线程、gate 锁内读写。
static uint64_t g_idempotentSurfaceChanges = 0u;

// OnSurfaceChanged 与启动时机重放（amclRenderScaleReapplyForLaunch）共用的核心。
// 调用方必须持有surface gate且accept已通过；expectedGeneration绑定无变更确认和错误。
// ownerCheckpoint仅使用已采样P；alreadyConfigured只能由同一revision完成SET后再次CAS的owner传入。
// 未变判定见 surface_republish_policy.h：新代次会让 input core 当作新 surface 复位
// （释放全部 held、清 capture/文本会话），而图形侧此时没有任何需要处理的变化。
static void RefreshPublishedSurfaceGeometry(OH_NativeXComponent* component,
                                            void* window,
                                            uint64_t expectedGeneration,
                                            SurfaceRefreshCause cause,
                                            const char* reason,
                                            int suppliedWidth = -1, int suppliedHeight = -1,
                                            bool ownerCheckpoint = false, bool alreadyConfigured = false) {
    uint64_t w = 0, h = 0;
    // owner线程只消费UI已经采样的物理区域，不能跨线程调用XComponent尺寸接口。
    if (!ownerCheckpoint) OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    const int newWidth = ownerCheckpoint ? suppliedWidth : CheckedSurfaceDimension(w, "width");
    const int newHeight = ownerCheckpoint ? suppliedHeight : CheckedSurfaceDimension(h, "height");
    g_surfaceWidth = newWidth;
    g_surfaceHeight = newHeight;
    g_resolution.displayChanged(newWidth, newHeight);
    if (newWidth <= 0 || newHeight <= 0) {
        ohos_cancel_all_input(AMCL_INPUT_CANCEL_SURFACE_LOST);
        ohos_surface_input_gate_set_geometry_pending(true);
        g_haveDrawableObservation = false;
    }
    if (newWidth > 0 && newHeight > 0 && !(g_resolution.flags() & 1u)) {
        if (!ownerCheckpoint && cause == SurfaceRefreshCause::kSurfaceChanged)
            amcl::ohos::ApplyExpectedFrameRateHint(component, reason);
        return;
    }
    AmclWindowHostStats ownerStats{};
    amclWindowHostGetStats(&ownerStats);
    if (!ownerCheckpoint && cause == SurfaceRefreshCause::kSurfaceChanged &&
        newWidth > 0 && newHeight > 0 && ownerStats.livePresentationToken != 0) {
        // producer token 也会在首次 shader/资源加载前建立。只有本局曾确认目标 drawable
        // 才把系统尺寸变化视为有界运行事务；首帧前转向不能意外启用 30 秒终局。
        g_runtimeResolutionRequest = g_resolution.hasConfirmedDuringLaunch();
        // 物理区域已变时先退休旧held并暂停新输入；producer在下一安全点配置和发布。
        if (g_realWidth != newWidth || g_realHeight != newHeight) {
            ohos_cancel_all_input(AMCL_INPUT_CANCEL_SURFACE_LOST);
            ohos_surface_input_gate_set_geometry_pending(true);
        }
        // 零面积时owner可能已经停车，单纯等待swap会互等。先发布最后一次已配置的
        // 非零逻辑尺寸唤醒前端，保持输入暂停；不在UI线程改NativeWindow，也不宣称
        // 旧GPU资源仍可用。原resourceEpoch变化继续要求owner按既有流程退休/重建。
        const auto previous = g_resolution.applied();
        if ((g_width <= 0 || g_height <= 0) && previous.width > 0 && previous.height > 0) {
            SurfacePublicationMutationContext resume{window, previous.width, previous.height};
            const uint64_t resumed = ohos_surface_input_gate_update_transaction(component, window, UpdateSurfaceMutation, &resume);
            if (!resumed) {
                DisableCurrentInputSurfaceAfterLifecycleFailure(component, "resolution-resume-publication");
                return;
            }
            g_width = previous.width;
            g_height = previous.height;
            g_realWidth = newWidth;
            g_realHeight = newHeight;
            amcl::renderscale::PublishSnapshot(newWidth, newHeight, g_width, g_height);
            amcl::input::PlatformInputSurfaceChanged(static_cast<uint32_t>(g_width), static_cast<uint32_t>(g_height), resumed);
        }
        PublishResolutionWork();
        amcl::ohos::ApplyExpectedFrameRateHint(component, reason);
        return;
    }
    if (newWidth > 0 && newHeight > 0) {
        // prelaunch 重放和无 producer 的初始化也遵守“确认后恢复”规则。这里仍持 gate，
        // 先退休 held，再配置/发布；SET 失败分支只在旧 actual 仍有效时允许继续输入。
        ohos_cancel_all_input(AMCL_INPUT_CANCEL_SURFACE_LOST);
        ohos_surface_input_gate_set_geometry_pending(true);
    }
    int publishWidth = newWidth;
    int publishHeight = newHeight;
    if (newWidth > 0 && newHeight > 0) {
        publishWidth = g_resolution.target().width;
        publishHeight = g_resolution.target().height;
    }
    bool geometryConfigured = alreadyConfigured || newWidth <= 0 || newHeight <= 0 ||
        ApplyRenderScaleGeometry(window, g_resolution.target(), g_resolution.revision());
    // 尚无生产者时可以明确尝试原生候选；它也必须成功SET并在首次呈现后确认。
    // 不把失败返回当作“系统应该仍是原生尺寸”。
    if (!geometryConfigured && ownerStats.livePresentationToken == 0 && g_resolution.target().scale != 1.0) {
        g_resolution.nativeFallback(newWidth, newHeight, "initial-geometry-rejected");
        publishWidth = g_resolution.target().width;
        publishHeight = g_resolution.target().height;
        geometryConfigured = ApplyRenderScaleGeometry(window, g_resolution.target(), g_resolution.revision());
    }
    if (!geometryConfigured) {
        g_resolution.rejected("geometry-configure-failed");
        if (g_realWidth != newWidth || g_realHeight != newHeight || !g_resolution.hasConfirmedDrawable())
            g_resolution.requireRestart("physical-geometry-unconfirmed");
        ohos_surface_input_gate_set_geometry_pending(g_resolution.phase() == amcl::renderscale::ResolutionPhase::kRestartRequired);
        PublishResolutionWork();
        return;
    }

    const amcl::ohos::SurfacePublicationGeometry current{
        g_window, g_realWidth, g_realHeight, g_width, g_height};
    const amcl::ohos::SurfacePublicationGeometry next{
        window, newWidth, newHeight, publishWidth, publishHeight};
    if (amcl::ohos::SurfacePublicationUnchanged(current, next)) {
        if (newWidth > 0 && newHeight > 0) g_resolution.configured(expectedGeneration, g_resolution.revision());
        PublishResolutionWork();
        if (cause == SurfaceRefreshCause::kSurfaceChanged && !ownerCheckpoint) {
            const uint64_t count = ++g_idempotentSurfaceChanges;
            if (FirstOrPowerOfTwo(count)) {
                OH_LOG_INFO(LOG_APP,
                            "event=surface-changed-idempotent count=%{public}llu "
                            "generation=%{public}llu real=%{public}dx%{public}d "
                            "published=%{public}dx%{public}d",
                            (unsigned long long)count,
                            (unsigned long long)expectedGeneration, newWidth,
                            newHeight, publishWidth, publishHeight);
            }
            if (!ownerCheckpoint) amcl::ohos::ApplyExpectedFrameRateHint(component, reason);
        }
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
    amcl::renderscale::PublishSnapshot(newWidth, newHeight, publishWidth, publishHeight);
    if (newWidth > 0 && newHeight > 0) g_resolution.configured(generation, g_resolution.revision());
    PublishResolutionWork();
    OH_LOG_INFO(LOG_APP,
                "Surface changed: %{public}dx%{public}d generation=%{public}llu",
                g_width, g_height, (unsigned long long)generation);

    amcl::input::PlatformInputSurfaceChanged(
        static_cast<uint32_t>(g_width), static_cast<uint32_t>(g_height),
        generation);
    if (!ownerCheckpoint) amcl::ohos::ApplyExpectedFrameRateHint(component, reason);
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
                                    SurfaceRefreshCause::kSurfaceChanged,
                                    "surface-changed");
}

// 启动时机补偿入口（mc_launcher 在写完 AMCL_RENDER_SCALE 后同步调用，见
// render_scale.h）。与 surface 回调同一 JS/UI 线程序列，锁序也与回调一致。
extern "C" void amclRenderScaleReapplyForLaunch(void) {
    SurfaceInputGateTransaction gateTransaction;
    bool valid = false;
    g_resolution.beginLaunch(amcl::renderscale::ParseScale(getenv("AMCL_RENDER_SCALE"), &valid));
    g_haveDrawableObservation = false;
    g_runtimeResolutionRequest = false;
    PublishResolutionWork();
    if (g_component == nullptr || g_window == nullptr) {
        // surface 尚未创建（或已销毁）：之后的 OnSurfaceCreated 会读到刚写的 env。
        return;
    }
    const uint64_t expectedGeneration =
        ohos_surface_input_gate_accept(g_component, g_window);
    if (expectedGeneration == 0) return;
    RefreshPublishedSurfaceGeometry(g_component, g_window, expectedGeneration,
                                    SurfaceRefreshCause::kLaunchReplay,
                                    "render-scale-launch");
}

/** 渲染安全点不运行游戏回调；旧token和旧surface在gate内复核后才允许改变几何。 */
static int ResolutionCheckpoint(void* window, uint64_t generation, uint64_t token) {
    amcl::renderscale::ResolutionTarget candidate{};
    uint64_t revision = 0;
    {
        SurfaceInputGateTransaction transaction;
        AmclWindowHostStats stats{};
        amclWindowHostGetStats(&stats);
        if (!g_component || window != g_window || token != stats.livePresentationToken ||
            ohos_surface_input_gate_accept(g_component, window) != generation || !(g_resolution.flags() & 1u)) return 0;
        candidate = g_resolution.target();
        revision = g_resolution.revision();
        ohos_cancel_all_input(AMCL_INPUT_CANCEL_SURFACE_LOST);
        ohos_surface_input_gate_set_geometry_pending(true);
    }
    // 调用方仍持强引用和当前呈现资格。驱动操作不占surface/input gate，UI不会因
    // producer配置等待而被锁住。期间UI可合并新请求/退休窗口；下面必须重新CAS。
    const bool configured = ApplyRenderScaleGeometry(window, candidate, revision);
    SurfaceInputGateTransaction transaction;
    AmclWindowHostStats stats{};
    amclWindowHostGetStats(&stats);
    if (!g_component || window != g_window || token != stats.livePresentationToken ||
        ohos_surface_input_gate_accept(g_component, window) != generation ||
        revision != g_resolution.revision() || !(g_resolution.flags() & 1u)) return 0;
    if (!configured) {
        g_resolution.rejected("geometry-configure-failed");
        if (g_realWidth != candidate.displayWidth || g_realHeight != candidate.displayHeight || !g_resolution.hasConfirmedDrawable())
            g_resolution.requireRestart("physical-geometry-unconfirmed");
        ohos_surface_input_gate_set_geometry_pending(g_resolution.phase() == amcl::renderscale::ResolutionPhase::kRestartRequired);
        PublishResolutionWork();
        return -1;
    }
    RefreshPublishedSurfaceGeometry(g_component, window, generation, SurfaceRefreshCause::kSurfaceChanged,
        "render-scale-owner", candidate.displayWidth, candidate.displayHeight, true, true);
    return g_resolution.phase() == amcl::renderscale::ResolutionPhase::kAwaitingDrawable ||
        g_resolution.phase() == amcl::renderscale::ResolutionPhase::kRestoring ? 1 : -1;
}

/** 只在变化事务中接收同代实际图像；正常稳定帧不查询EGL、不加本gate锁。 */
static void ResolutionDrawableObserved(void* window, uint64_t generation, uint64_t token,
                                       int width, int height, uint32_t source) {
    SurfaceInputGateTransaction transaction;
    AmclWindowHostStats stats{};
    amclWindowHostGetStats(&stats);
    if (!g_component || window != g_window || token != stats.livePresentationToken ||
        ohos_surface_input_gate_accept(g_component, window) != generation) return;
    if (!g_resolution.observe(generation, width, height, source)) return;
    // 正尺寸但不匹配目标不能开放第一笔手动事务；先让初始确认/有限恢复闭环。
    if (g_resolution.hasConfirmedDrawable()) g_haveDrawableObservation = true;
    PublishResolutionWork();
    const auto phase = g_resolution.phase();
    if (phase == amcl::renderscale::ResolutionPhase::kConfirmed || phase == amcl::renderscale::ResolutionPhase::kRejected)
        ohos_surface_input_gate_set_geometry_pending(false);
    else if (phase == amcl::renderscale::ResolutionPhase::kRestartRequired) {
        ohos_cancel_all_input(AMCL_INPUT_CANCEL_SURFACE_LOST);
        ohos_surface_input_gate_set_geometry_pending(true);
    }
    if (!(g_resolution.flags() & 2u)) OH_LOG_INFO(LOG_APP,
        "[AMCL-RESOLUTION] observed request=%{public}llu generation=%{public}llu source=%{public}u actual=%{public}dx%{public}d phase=%{public}d reason=%{public}s",
        static_cast<unsigned long long>(g_resolution.revision()), static_cast<unsigned long long>(generation),
        source, width, height, static_cast<int>(phase), g_resolution.reason());
}

extern "C" bool amclResolutionRequestPercent(double percent) {
    SurfaceInputGateTransaction transaction;
    if (!g_geometryClientRegistered || !g_haveDrawableObservation || !g_component || !g_window ||
        g_resolution.phase() == amcl::renderscale::ResolutionPhase::kRestartRequired ||
        ohos_surface_input_gate_accept(g_component, g_window) == 0) return false;
    const bool accepted = g_resolution.request(percent / 100.0, g_surfaceWidth, g_surfaceHeight);
    if (accepted) g_runtimeResolutionRequest = true;
    PublishResolutionWork();
    return accepted;
}

extern "C" const char* amclResolutionStatusJson(void) {
    SurfaceInputGateTransaction transaction;
    // 手动/活动窗口事务不能无限挂起。只在Ability确实前台时计入此结束边界；
    // 首次游戏加载的shader/资源准备不受30秒限制，也不因后台停帧误判失败。
    bool foreground = false;
    { std::lock_guard<std::mutex> lock(g_inputForegroundGateMutex); foreground = g_inputForegroundGate.abilityForegroundMask != 0; }
    if (g_runtimeResolutionRequest && g_resolution.flags() != 0u && foreground &&
        ResolutionNowNs() - g_resolutionChangedAtNs.load(std::memory_order_acquire) > INT64_C(30000000000)) {
        g_resolution.requireRestart("geometry-confirmation-timeout");
        ohos_cancel_all_input(AMCL_INPUT_CANCEL_SURFACE_LOST);
        ohos_surface_input_gate_set_geometry_pending(true);
        PublishResolutionWork();
    }
    static thread_local std::string result;
    const char* phaseNames[] = {"idle", "pending", "awaiting-drawable", "confirmed", "rejected", "restoring", "restart-required", "suspended"};
    const auto& applied = g_resolution.applied();
    std::ostringstream json;
    json << "{\"schema\":1,\"requestId\":\"" << g_resolution.revision() << "\",\"generation\":\"" << g_resolution.generation()
         << "\",\"phase\":\"" << phaseNames[static_cast<unsigned>(g_resolution.phase())]
         << "\",\"requestedPercent\":" << g_resolution.desiredScale() * 100.0
         << ",\"configuredPercent\":" << applied.scale * 100.0
         << ",\"displayWidth\":" << g_surfaceWidth << ",\"displayHeight\":" << g_surfaceHeight
         << ",\"logicalWidth\":" << applied.width << ",\"logicalHeight\":" << applied.height
         << ",\"actualWidth\":" << g_resolution.actualWidth() << ",\"actualHeight\":" << g_resolution.actualHeight()
         << ",\"actualSource\":" << g_resolution.observationSource()
         << ",\"canRequest\":" << (g_geometryClientRegistered && g_haveDrawableObservation ? "true" : "false")
         << ",\"virtualWindowManaged\":" << (g_resolution.virtualWindowManaged() ? "true" : "false")
         << ",\"reason\":\"" << g_resolution.reason() << "\"}";
    result = json.str();
    return result.c_str();
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
    // 销毁不触碰环境（I27-05）：窗口指针与尺寸都只在窗口宿主快照里，清除快照即可。
    amcl::renderscale::ResetSnapshot();
    g_resolution.suspend();
    g_surfaceWidth = g_surfaceHeight = 0;
    g_haveDrawableObservation = false;
    PublishResolutionWork();
    ohos_surface_input_gate_set_geometry_pending(false);
    AMCL_LOG_I(LOG_TAG, "Surface snapshot cleared generation=%{public}llu",
                (unsigned long long)generation);
}

static void OnFocus(OH_NativeXComponent* component, void* window) {
    SurfaceInputGateTransaction gateTransaction;
    ohos_surface_input_gate_log_focus_edge(true, component, window);
    if (ohos_surface_input_gate_accept(component, window) == 0) return;
    amcl_cursor_lock_set_focus(true);
    amcl::input::PlatformInputFocusChanged(true);
    PublishInputForegroundFocusState(amcl::ohos::ComponentFocus::Focused,
                                     "focus");
    amcl::ohos::SetFrameRateFocused(component, true, "focus");
}

static void OnBlur(OH_NativeXComponent* component, void* window) {
    SurfaceInputGateTransaction gateTransaction;
    ohos_surface_input_gate_log_focus_edge(false, component, window);
    if (ohos_surface_input_gate_accept(component, window) == 0) return;
    // 组件失焦先关闭原生capture准入；窗口仍获焦也不能被迟到的ArkTS心跳再次加锁。
    amcl_cursor_lock_set_focus(false);
    // Publish typed focus loss before releasing legacy owners while the same
    // surface gate transaction excludes new ingress. This ordering lets the
    // host synthesize typed releases/reset first, then cancelAll makes the
    // legacy ledger reach the same zero-held boundary before callbacks resume.
    amcl::input::PlatformInputFocusChanged(false);
    PublishInputForegroundFocusState(amcl::ohos::ComponentFocus::Blurred,
                                     "blur");
    ohos_cancel_all_input(AMCL_INPUT_CANCEL_FOCUS_LOST);
    // XComponent失焦并不证明系统窗口失焦；上面的主动解锁若失败，保留原窗口清理目标。
    // 只有真实窗口失焦通知才可确认平台自动释放，不能在这里把待办当成已经完成。
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
    // 进程级环境（重启标记槽位与各描述符）已由 napi_entry.cpp 的 Init 第一步发布（I27-05），
    // 早于下面注册的任何 surface 回调；这里只注册回调，不触碰进程环境的名字集合。
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
