// touch_input.cpp — 触摸输入处理（Native XComponent + Control Schema v2）
//
// 当前架构：
// - 全屏 XComponent 是平台触摸 ingress，native 以 finger owner/schema generation 解释 grabbed 输入；
// - native 接管摇杆、普通按钮、滚轮、hotbar 与空白 look，并通过 OutputLedger 管理持续输出；
// - handledBy=arkts 的 IME、drawer 及抽屉子项仍由 ArkUI exact rect 处理，不能被 native slop 扩张；
// - normal 模式触摸由 native 菜单事务映射为绝对指针；ArkTS 仅观察 grab 并负责 UI/lifecycle 发布。
//
// ⚠️ 这里曾写着「legacy registerButton/registerJoystick 只保留为 schema 不可用时的命中过滤
// 兼容表，不产生输出」。**那张表连同四个入口已在 §38.3 整体删除**（`ohos_register_button` /
// `ohos_register_joystick` / `ohos_clear_buttons` / `ohos_clear_joystick`、`s_buttons`、
// `ButtonRect`、`hitButton()`、`isInJoystick()`、对应 NAPI 与 ArkTS 调用点，全部）。
// 删除理由：唯一读取方在 `s_schemaActive` 永为 true 造成的不可达分支里，而 ArkTS 每次布局
// 重建都在跨语言填一张没人读的表。
//
// 触控虚拟按键端**当前唯一的权威表述是 Control Schema**（`ohos_set_control_schema`）。
//
// 这一句必须改掉的原因不只是它过期：文件头是全 TU 最权威的位置，而下方 `:2793` 附近的墓碑
// 注释还写着「详见**文件上方的说明**」——它指向的正是这一句相反的话（真正的说明在
// `s_buttons` 原址那段）。一个被别处显式指为权威来源的假注释，形状与 §51.1 完全一致。

#include "touch_input.h"
#include "control_schema_contract.h"
#include "touch_publication.h"
#include "../utils/amcl_log.h"
#include "cursor_lock.h"
#include "surface_input_gate_state.h"
#include "../input/amcl_input_event.h"
#include "../input/platform_input_ingress.h"
#include "../input/input_menu_cursor_snapshot.h"
#include "../input/input_trace.h"
#include "input_channel_census.h"
#include "input_channel_policy.h"
#include "input_ledger.h"
#include "source_control_client.h"
#include "legacy_physical_edge_router.h"
#include "look_delta_math.h"
#include "look_pipeline_stats.h"
#include "source_look_processor.h"
#include "mapped_look_producer.h"
#include "source_look_producer.h"
#include "../input/delivery/look_transport.h"
#include "input_source.h"
#include "external_held_registry.h"
#include "external_held_edge_router.h"
#include "grab_announcement_queue.h"
#include "input_invariants.h"
#include "joystick_sector.h"
#include "legacy_output_code.h"
#include "legacy_ring_discontinuity.h"
#include "schema_wasd_latch.h"
#include "mouse_synth_touch_source.h"
#include "native_mouse_route_policy.h"
#include "physical_wheel_quantizer.h"
#include "product_input_policy.h"
#include "render_scale.h"
#include "window_event_filter.h"
#if AMCL_INPUT_GATE0_TELEMETRY
#include "gate0_input_telemetry.h"
#endif
#include <hilog/log.h>
#include <arkui/ui_input_event.h>
#include <cstdlib>
#include <algorithm>
#include <cstring>
#include <cstdio>
#include <cmath>
#include <cstdint>
#include <ctime>
#include <atomic>
#include <dlfcn.h>
#include <unistd.h>
#include <vector>
#include <deque>
#include <string>
#include <map>
#include <set>
#include <mutex>

// 共享 runtime 的强链接 C ABI；bridge 自己负责 owner image 转发。这里只提交已经
// 加工完成的一份位移，并保留来源供 SDL 独立读取非物理累计，绝不重复提交 typed raw。
extern "C" void inputBridge_addSourceLookDelta(int32_t source, double dx, double dy);
// legacy ring 不连续 epoch（强链接 C ABI，bridge 负责 owner image 转发）。只做一次原子读，
// 不取任何 bridge 锁；对账逻辑见下方 reconcileLegacyRingDiscontinuity。
extern "C" unsigned long long inputBridge_legacyRingDiscontinuityEpochV1(void);
// 菜单触控作用域的退休属于中立 bridge 的生产身份，而不是当前手指 token。
// UP 后本文件会清掉 token，但同一事务仍可能排在消费者队列里；单发旧 token 的
// CANCEL 无法覆盖这些已结束记录。此 ABI 在公共 order 事务内推进菜单 epoch，
// 消费者在自己的线程拒绝旧前缀并释放已提交的菜单贡献，不清 ordinary/typed 持有。
// 该入口没有 Native 回调，可在 surface→mode→touch→schema 的锁序内调用。
extern "C" void inputBridge_retireTouchMenuScopeV1(void);
// 显式菜单工具有独立的菜单来源贡献。只能发送 Left(-1)、Right(-2)、LeftShift(340)
// 的首按/末松；bridge 冻结菜单 epoch，再与 ordinary/typed 合并。不能把 common
// ledger 的最终边沿贴上 Touch 标签，否则共持时无法区分应退休的真实来源。
extern "C" void inputBridge_pushTouchMenuToolV1(int code, int action);
// 面板CANCEL只退休工具子域；直接屏幕菜单事务、空闲菜单位置及其他来源均保持。
// 与正常UP的末松不同，独立tool epoch会撤销尚未消费的PRESS/RELEASE历史，不能补出点击。
extern "C" void inputBridge_retireTouchMenuToolScopeV1(void);
// 无按钮的触控菜单位置也必须绑定菜单epoch；物理绝对指针仍用普通setMenuCursor。
extern "C" void inputBridge_publishTouchMenuCursorV1(double x, double y);
// 指针/滚轮同样保留真实触控来源：工具CANCEL只能撤工具位置/滚动，不能撤直接菜单。
extern "C" void inputBridge_publishTouchMenuToolCursorV1(double x, double y);
extern "C" void inputBridge_publishTouchMenuScrollV1(int dx, int dy);
extern "C" void inputBridge_pushTouchMenuToolScrollV1(int dx, int dy);
extern "C" void inputBridge_publishTouchMenuToolRelativeV1(double dx,double dy,double maxX,double maxY);
extern "C" void inputBridge_publishTouchMenuRelativeV1(int phase,uint32_t token,double dx,double dy,double maxX,double maxY);
static void retireTouchMenuSurfaceScope(); // caller持surface gate；内部按touch→transaction退休。

#undef LOG_TAG
#define LOG_TAG "TOUCH_INPUT"

// ==================== Surface callback input gate ====================
// Window-bearing OHOS callbacks carry component/window pointers but no
// publication generation; hover/axis carry only component. A retired pointer
// pair is therefore quarantined for the process lifetime, and component-only
// typed callbacks lose implicit authority after the first generation. A resize
// also advances a monotonic timestamp boundary; verified native-absolute input
// rejects an older queued sample before it can borrow the new generation. The
// optional capability remains build-gated until device evidence establishes
// the platform's coordinate and timestamp contracts.
using SurfaceInputGateState = amcl::input::surface_gate::State;

static std::recursive_mutex s_surfaceInputGateMutex;
static SurfaceInputGateState s_surfaceInputGate;
static uint64_t s_surfaceFocusEntryCount = 0u;
static uint64_t s_surfaceBlurEntryCount = 0u;
static uint64_t s_surfaceFocusGateRejectCount = 0u;
static uint64_t s_surfaceBlurGateRejectCount = 0u;

// 限流谓词：首次 + 之后每逢 2 的幂。本文件五处诊断共用它（look/menu/wheel/surface gate），
// 定义放在这里是因为 surface gate 那两条是最早的使用点。
static bool firstOrPowerOfTwo(uint64_t count) {
    return count == 1u || (count & (count - 1u)) == 0u;
}

// 时钟读取失败的次数（2026-09-01 新增可观测性）。
static std::atomic<uint64_t> s_surfaceGateClockFailureCount{0u};
// 墓碑池低水位告警只打一次（在 gate 锁内访问，非原子足够；用 atomic 只为省掉
// "它到底在不在锁内"这个问题）。
static std::atomic<bool> s_surfaceGateRetiredLowWarned{false};

// ⚠️ **返回 `UINT64_MAX` 表示失败，而这个失败此前完全无声**（2026-09-01 补日志）。
//
// 后果必须写清，因为它**不是**"gate 不激活"这么直白：`Activate` 只检查
// `notBeforeEventTimestampNs != 0`，所以 `UINT64_MAX` 会被接受 ⇒ gate 正常激活、
// legacy 平面照常工作，而 `AcceptEventTimestamp` 的 `eventTimestampNs > UINT64_MAX`
// **恒假** ⇒ **typed 绝对路由对该 publication 永久静默拒绝**，直到下一次 surface 更替。
//
// ⚠️ **刻意不改控制流**（不让 `Activate` 拒绝 `UINT64_MAX`）：那会让整个 gate 不激活，
// 于是**每一条**输入都被 `GATE_REJECTED` 掉 —— 用一个"输入全死"换掉一个"菜单绝对坐标
// 在 typed 下不工作"，方向是错的。所以这里只补观测面。
// （当前 bit14 未授权 ⇒ typed 绝对路由本就不可达 ⇒ 这条失败今天没有行为后果；
//  但它属于"依赖某条路径还没被打开"的无害结论，按规范 §九 的纪律必须写成待爆而不是无害。）
static uint64_t currentMonotonicTimestampNsOrFailClosed() {
    struct timespec now = {};
    const auto failClosed = [](const char* reason) -> uint64_t {
        const uint64_t count = s_surfaceGateClockFailureCount.fetch_add(
            1u, std::memory_order_relaxed) + 1u;
        if (firstOrPowerOfTwo(count)) {
            AMCL_LOG_E(LOG_TAG,
                "AMCL_SURFGATE monotonic clock unusable reason=%{public}s "
                "count=%{public}llu -- the typed absolute route will silently "
                "reject every sample for this publication (legacy is unaffected)",
                reason, static_cast<unsigned long long>(count));
        }
        return UINT64_MAX;
    };
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0 ||
        now.tv_nsec < 0 || now.tv_nsec >= 1000000000L) {
        return failClosed("clock_gettime");
    }
    const uint64_t seconds = static_cast<uint64_t>(now.tv_sec);
    const uint64_t nanoseconds = static_cast<uint64_t>(now.tv_nsec);
    if (seconds > (UINT64_MAX - nanoseconds) / 1000000000ULL) {
        return failClosed("overflow");
    }
    const uint64_t value = seconds * 1000000000ULL + nanoseconds;
    return value == 0u ? 1u : value;
}

// 墓碑池水位的可观测性。调用方必须已持 gate 锁。
//
// 阈值分两档，因为两个状态的严重度差一个数量级：
//   · 剩余 ≤ 32：**还能工作**，但正在走向死亡 ⇒ 打一次 warn 就够（再打就是刷屏）；
//   · 剩余 == 0：`CanActivate` 已经对任何身份返回 false ⇒ **输入已经全死**，
//     此后每一次 publish 尝试都打 error。这一档刻意不限流：此刻没有任何输入能进来，
//     不存在"把别的证据淹没"的风险，而"用户报输入全失灵"时这一行是唯一的直接答案。
static void noteSurfaceGateRetiredCapacityLocked() {
    const std::size_t remaining =
        amcl::input::surface_gate::RetiredCapacityRemaining(s_surfaceInputGate);
    if (remaining == 0u) {
        AMCL_LOG_E(LOG_TAG,
            "AMCL_SURFGATE retired-identity pool exhausted (capacity=%{public}zu) "
            "-- the input gate can no longer activate ANY surface; every physical "
            "edge from here on is GATE_REJECTED until the process restarts",
            static_cast<std::size_t>(
                SurfaceInputGateState::kRetiredIdentityCapacity));
        return;
    }
    if (remaining <= 32u &&
        !s_surfaceGateRetiredLowWarned.exchange(
            true, std::memory_order_relaxed)) {
        AMCL_LOG_W(LOG_TAG,
            "AMCL_SURFGATE retired-identity pool low remaining=%{public}zu "
            "of %{public}zu (each surface identity change consumes one; "
            "exhaustion permanently kills the input gate)",
            remaining,
            static_cast<std::size_t>(
                SurfaceInputGateState::kRetiredIdentityCapacity));
    }
}

static uint64_t acceptSurfaceInputGateLocked(OH_NativeXComponent* component,
                                             void* window,
                                             bool requireWindow) {
    return amcl::input::surface_gate::Accept(
        s_surfaceInputGate, component, window, requireWindow);
}

extern "C" void ohos_surface_input_gate_lock(void) {
    s_surfaceInputGateMutex.lock();
}

extern "C" void ohos_surface_input_gate_unlock(void) {
    s_surfaceInputGateMutex.unlock();
}

extern "C" uint64_t ohos_surface_input_gate_accept(
    OH_NativeXComponent* component, void* window) {
    std::lock_guard<std::recursive_mutex> lock(s_surfaceInputGateMutex);
    return acceptSurfaceInputGateLocked(component, window, true);
}

extern "C" uint64_t ohos_surface_input_gate_accept_component(
    OH_NativeXComponent* component) {
    std::lock_guard<std::recursive_mutex> lock(s_surfaceInputGateMutex);
    return acceptSurfaceInputGateLocked(component, nullptr, false);
}

extern "C" void ohos_surface_input_gate_log_focus_edge(
        bool focused, OH_NativeXComponent* component, void* window) {
    std::lock_guard<std::recursive_mutex> lock(s_surfaceInputGateMutex);
    uint64_t& entryCount = focused ? s_surfaceFocusEntryCount
                                   : s_surfaceBlurEntryCount;
    entryCount += 1u;
    const uint64_t acceptedGeneration =
        acceptSurfaceInputGateLocked(component, window, true);
    uint64_t& rejectCount = focused ? s_surfaceFocusGateRejectCount
                                    : s_surfaceBlurGateRejectCount;
    if (acceptedGeneration == 0u) rejectCount += 1u;
    OH_LOG_INFO(
        LOG_APP,
        "event=input-focus-edge edge=%{public}s count=%{public}llu "
        "gateRejects=%{public}llu focusGateRejects=%{public}llu "
        "blurGateRejects=%{public}llu component=%{public}p window=%{public}p "
        "gateActive=%{public}d gateComponent=%{public}p gateWindow=%{public}p "
        "gateGeneration=%{public}llu acceptedGeneration=%{public}llu",
        focused ? "focus" : "blur",
        static_cast<unsigned long long>(entryCount),
        static_cast<unsigned long long>(rejectCount),
        static_cast<unsigned long long>(s_surfaceFocusGateRejectCount),
        static_cast<unsigned long long>(s_surfaceBlurGateRejectCount),
        component, window, s_surfaceInputGate.active ? 1 : 0,
        s_surfaceInputGate.component, s_surfaceInputGate.window,
        static_cast<unsigned long long>(
            s_surfaceInputGate.publicationGeneration),
        static_cast<unsigned long long>(acceptedGeneration));
}

extern "C" uint64_t ohos_surface_input_gate_begin_current_transaction(void) {
    s_surfaceInputGateMutex.lock();
    if (!s_surfaceInputGate.active || !s_surfaceInputGate.component ||
        !s_surfaceInputGate.window || s_surfaceInputGate.publicationGeneration == 0) {
        s_surfaceInputGateMutex.unlock();
        return 0;
    }
    return s_surfaceInputGate.publicationGeneration;
}

extern "C" void ohos_surface_input_gate_end_current_transaction(uint64_t token) {
    if (token == 0) return;
    s_surfaceInputGateMutex.unlock();
}

extern "C" uint64_t ohos_surface_input_gate_publish_transaction(
    OH_NativeXComponent* component, void* window,
    OhosSurfacePublicationMutation mutation, void* context) {
    std::lock_guard<std::recursive_mutex> lock(s_surfaceInputGateMutex);
    // 水位检查必须在 `CanActivate` **之前**：池耗尽正是让 `CanActivate` 返回 false 的成因，
    // 放在后面就永远打不出那条 error（下面是 `return 0`）—— 这与"只在空闲时刻打印的
    // 计数器等于没有计数器"是同一个形状（规范 §八 纪律 5）。
    noteSurfaceGateRetiredCapacityLocked();
    if (!mutation || !amcl::input::surface_gate::CanActivate(
                         s_surfaceInputGate, component, window)) {
        return 0;
    }

    // 新呈现目标开始安装之前先撤销旧菜单前缀，不能等 JS 重发 schema 或下一次
    // DOWN 才清理。此时 gate 已阻止新的平台入口，消费者也能立即看到退休 epoch；
    // 即使 broker 安装失败，旧菜单操作也不能在随后失效/恢复的窗口上补出点击。
    retireTouchMenuSurfaceScope();

    // Keep the old gate fully active while the broker retain/publication runs.
    // A new identity never inherits the old generation. After success, sample
    // the boundary before activation while this same lock still excludes every
    // native input callback.
    const uint64_t previousGeneration = 0u;
    const uint64_t publicationGeneration =
        mutation(context, previousGeneration);
    if (publicationGeneration == 0) return 0;
    const uint64_t boundary = currentMonotonicTimestampNsOrFailClosed();
    const bool activated = amcl::input::surface_gate::Activate(
               s_surfaceInputGate, component, window,
               publicationGeneration, boundary);
    if (activated) {
        // 新surface不能继承旧窗口的锁或明确失焦状态；初始Unknown焦点由平台最终授权。
        amcl_cursor_lock_set_surface(false);
        amcl_cursor_lock_set_surface(true);
    }
    return activated ? publicationGeneration : 0u;
}

extern "C" uint64_t ohos_surface_input_gate_update_transaction(
    OH_NativeXComponent* component, void* window,
    OhosSurfacePublicationMutation mutation, void* context) {
    std::lock_guard<std::recursive_mutex> lock(s_surfaceInputGateMutex);
    if (!mutation) return 0;
    const uint64_t expectedGeneration =
        acceptSurfaceInputGateLocked(component, window, true);
    if (expectedGeneration == 0u) return 0u;
    // 几何或 render-scale 的真实重发布改变了菜单坐标含义。这里覆盖“手指已经
    // 抬起、Native token 已清零、旧鼠标事务尚未消费”的空档，不能用零触点放行它。
    retireTouchMenuSurfaceScope();
    const uint64_t publicationGeneration =
        mutation(context, expectedGeneration);
    if (publicationGeneration == 0u) return 0u;
    const uint64_t boundary = currentMonotonicTimestampNsOrFailClosed();
    return amcl::input::surface_gate::CommitCurrentUpdate(
        s_surfaceInputGate, component, window, expectedGeneration,
        publicationGeneration, boundary);
}

extern "C" uint64_t ohos_surface_input_gate_clear_transaction(
    OH_NativeXComponent* component, void* window,
    OhosSurfacePublicationMutation mutation, void* context) {
    std::lock_guard<std::recursive_mutex> lock(s_surfaceInputGateMutex);
    if (!mutation) return 0;
    // SurfaceDestroyed is authoritative once the current component/window was
    // accepted. ClearCurrent invalidates every identity before touching GLFW
    // publication, so a zero mutation result remains fail-closed.
    if (acceptSurfaceInputGateLocked(component, window, true) != 0u) {
        // 先让消费者退休旧菜单，再进行可能失败的清窗；无效旧 destroy 不拥有此权限。
        retireTouchMenuSurfaceScope();
        amcl_cursor_lock_set_surface(false);
        amcl::input::PlatformInputCapturePlatformChanged(
            false, AMCL_INPUT_CAPTURE_REASON_SURFACE_LOST);
    }
    return amcl::input::surface_gate::ClearCurrent(
        s_surfaceInputGate, component, window, mutation, context);
}

extern "C" uint64_t ohos_surface_input_gate_clear_active_transaction(
        OhosSurfacePublicationMutation mutation, void* context,
        uint64_t* outExpectedPublicationGeneration) {
    std::lock_guard<std::recursive_mutex> lock(s_surfaceInputGateMutex);
    if (s_surfaceInputGate.active && mutation) {
        // 生命周期失败的 clear-active 也可能没有尚按住的手指，仍须撤销消费端旧菜单。
        retireTouchMenuSurfaceScope();
        amcl_cursor_lock_set_surface(false);
        amcl::input::PlatformInputCapturePlatformChanged(
            false, AMCL_INPUT_CAPTURE_REASON_SURFACE_LOST);
    }
    return amcl::input::surface_gate::ClearActive(
        s_surfaceInputGate, mutation, context,
        outExpectedPublicationGeneration);
}

class SurfaceInputGateCallbackScope {
public:
    SurfaceInputGateCallbackScope(OH_NativeXComponent* component, void* window,
                                  bool requireWindow)
        : acceptedGeneration_(0) {
        ohos_surface_input_gate_lock();
        acceptedGeneration_ = requireWindow
            ? ohos_surface_input_gate_accept(component, window)
            : ohos_surface_input_gate_accept_component(component);
    }

    ~SurfaceInputGateCallbackScope() {
        ohos_surface_input_gate_unlock();
    }

    bool accepted() const { return acceptedGeneration_ != 0; }
    uint64_t generation() const { return acceptedGeneration_; }
    bool acceptsEventTimestamp(int64_t eventTimestampNs) const {
        return amcl::input::surface_gate::AcceptEventTimestamp(
            s_surfaceInputGate, acceptedGeneration_, eventTimestampNs);
    }
    bool componentOnlyGenerationSafe() const {
        return amcl::input::surface_gate::AcceptComponentOnlyGeneration(
            s_surfaceInputGate, acceptedGeneration_);
    }

private:
    uint64_t acceptedGeneration_;
};

// ==================== 重构 Phase 1：grab 翻转 cancelPendingActions（复刻 Pojav）====================
// 根因（Phase 0 实证）：MC 按钮在 PRESS 即触发关菜单 → grab 在“点菜单的手指仍按着”时翻转；这根跨模式手指
//   ① 其 normal 模式 LEFT PRESS 收不到 RELEASE（UP 落到 grabbed 分支）→ 卡左键；
//   ② 带着过期/未初始化的每指状态进入新模式 → 偶发被当成 look → 间歇视角瞬移。
// 解决：grab 翻转时（在触摸线程，与所有每指写串行、无竞态）执行“取消未决”——补发卡住的 LEFT RELEASE、
//   清 look 平滑基准、并把翻转瞬间仍按着的**非 carried（keepHeld 之外）**手指标记为“作废，直到抬起”，
//   使跨翻转手指绝不在新模式里被重新解释成 look/点击。
// 注：依赖 MAX_FINGERS 的数组声明移到其 #define 之后（见下方 s_fingerDead / s_fingerDown 附近）。
// 两个基准只在 s_touchStateMutex 内由 consumeGrabEpochLocked 读写（ohos_set_control_schema 在 bridge
// 尚未加载时也在同一把锁内初始化它们）。
static bool s_grabFlipLastState = false;
static bool s_grabFlipInit = false;
// libglfw 在真实 grab 翻转时同步调用此轻量 trampoline；只入队公告，不跨线程修改每指数组。
// 下一个触摸 ingress 或 schema 发布边界在写当前 fingerDown / 替换 generation **之前**经
// consumeGrabEpochLocked 应用翻转，先作废旧菜单层手指或承接仍由物理手指持有的 owner。
// 公告队列与“最新公告状态”在同一把锁里读写（grab_announcement_queue.h），消费方只使用
// ApplyGrabAnnouncements 返回的生效状态，因此不存在“先读状态、后取队列”之间的窗口。
// ⚠️ 墓碑: `s_consumedGrabAnnouncementEpoch` 已删除（只写不读，公告状态改由 Take 在同一临界区读出），详见计划 §129。
static std::mutex s_grabAnnouncementMutex;   // 叶子锁，只包住公告队列与状态
static amcl::input::GrabAnnouncementQueue s_grabAnnouncements(s_grabAnnouncementMutex);
static void schemaNotifyDeadlineWorkerNonblocking();
extern "C" void amcl_touch_on_grab_changed(int grabbing) {
    const bool state = grabbing != 0;
    // 队列锁是叶子锁：Announce 返回之后才调用 ingress，持队列锁时绝不进入 ingress / touchState /
    // ledger。本函数运行在 bridge 的物理运动锁内，所以也不在这里对账 ring 不连续 epoch ——
    // 对账要取 surface gate 与 touchState，与 ingress → grab 事务的锁序相反。
    s_grabAnnouncements.Announce(state);
    // 公告已经在线性化点成立；只唤醒已初始化的condition，不取得touch/schema锁或等待UI。
    schemaNotifyDeadlineWorkerNonblocking();
    // A grab request is only intent in Phase 1B. No platform capture proof exists,
    // so the typed stream must publish active=false/reason=UNSUPPORTED.
    amcl::input::PlatformInputCaptureRequested(state);
}

// GLFW window recreate 在旧 window 仍有效的 MC 线程同步调用。这里必须进入同一个 cancelAll，
// 不能只清 bridge ring：OutputLedger/finger owner 位于 libentry，遗漏它们会在新窗口再次发出旧 RELEASE。
extern "C" void amcl_touch_cancel_from_bridge(int reason) {
    ohos_cancel_all_input(reason);
}

// Must match input_bridge_ohos.c GLFWInputEvent and constants
struct TouchInputEvent { int type; int i1, i2, i3, i4; };
#define EVENT_TYPE_KEY          1005
#define EVENT_TYPE_MOUSE_BUTTON 1006
#define EVENT_TYPE_SCROLL       1007
// 菜单指针事务：坐标与 DOWN/MOVE/UP 进入同一有序 ring，消费端按不可变载荷提交。
#define EVENT_TYPE_MENU_POINTER 1008
#define MENU_POINTER_MOVE        0
#define MENU_POINTER_DOWN        1
#define MENU_POINTER_UP          2
#define MENU_POINTER_CANCEL      3
#define MENU_POINTER_BEGIN       4
#define MENU_POINTER_END         5
#define GLFW_PRESS   1
#define GLFW_RELEASE 0
#define GLFW_REPEAT  2
#define GLFW_MOUSE_BUTTON_LEFT  0
#define GLFW_MOUSE_BUTTON_RIGHT 1

// ==================== Input bridge v7 函数 ABI ====================
// libentry 只持有四个操作函数和一对 grab 事务函数，不再持有 libglfw 的坐标/ring 内存地址。这样所有跨线程坐标写入
// 都经过 bridge 自己的 mutex，所有事件都经过 bridge producer lock；ABI 解析失败时输入 fail closed，
// 绝不回退到会合并 menu/look 或无锁写 ring 的 v1-v5。
typedef void (*InputBridgeAddLookDeltaFn)(double dx, double dy);
typedef void (*InputBridgeSetMenuCursorFn)(double x, double y);
typedef bool (*InputBridgeIsGrabbingFn)(void);
typedef void (*InputBridgePushEventFn)(int type, int i1, int i2, int i3, int i4);
typedef int (*InputBridgeBeginPhysicalMotionFn)(int* outGrabbing);
typedef void (*InputBridgeEndPhysicalMotionFn)(void);

static InputBridgeAddLookDeltaFn s_addLookDeltaFn = nullptr;
static InputBridgeSetMenuCursorFn s_setMenuCursorFn = nullptr;
static InputBridgeIsGrabbingFn s_isGrabbingFn = nullptr;
static InputBridgePushEventFn s_pushEventFn = nullptr;
static InputBridgeBeginPhysicalMotionFn s_beginPhysicalMotionFn = nullptr;
static InputBridgeEndPhysicalMotionFn s_endPhysicalMotionFn = nullptr;
static std::atomic<bool> s_bridgeResolved(false);
static std::mutex s_bridgeResolveMutex;
static std::atomic<uint64_t> s_invalidLookDeltaCount(0u);
static std::atomic<uint64_t> s_nonFiniteMenuPositionCount(0u);

// ⚠️ 墓碑: `firstOrPowerOfTwo` 的定义已上移到本文件早期（surface gate 那一段之前），
// 因为 2026-09-01 新增的 `AMCL_SURFGATE` 诊断是它的第一个使用点。**只有一份定义** ——
// 刻意不在上面复制第二份：限流形状漂移会让两组诊断的"打了几条"含义不同，
// 而那是判读时最容易误信的一类差异。

static bool finitePair(double x, double y) {
    return std::isfinite(x) && std::isfinite(y);
}

static void recordInvalidLookDelta() {
    const uint64_t count = s_invalidLookDeltaCount.fetch_add(
        1u, std::memory_order_relaxed) + 1u;
    if (firstOrPowerOfTwo(count)) {
        AMCL_LOG_E(LOG_TAG,
            "Look delta rejected before persistent backlog (non-finite/overflow) count=%{public}llu",
            (unsigned long long)count);
    }
}

static void recordNonFiniteMenuPosition() {
    const uint64_t count = s_nonFiniteMenuPositionCount.fetch_add(
        1u, std::memory_order_relaxed) + 1u;
    if (firstOrPowerOfTwo(count)) {
        AMCL_LOG_E(LOG_TAG,
            "Menu cursor rejected before persistent state count=%{public}llu",
            (unsigned long long)count);
    }
}

#define INPUT_BRIDGE_PROTO_MAGIC "AMCLINPV"
#define INPUT_BRIDGE_PROTO_VERSION 7

// libentry → libglfw 的三条反向 trampoline。方向是刻意的：libglfw 反向按符号名解析
// libentry 不可靠（不同 linker namespace），所以由 libentry 把地址经 env 推过去。
//
// ⚠️ **必须与 `resolveBridge` 解耦、且尽早发布。** 前两条的消费者（grab 翻转、窗口重建）
// 都发生在输入已经跑起来之后，所以搭在 `resolveBridge` 里没暴露过问题；但第三条
// （`AMCL_LOOK_DELTA_CB`）的消费者是 typed 平面的**第一个**相对样本 —— 而 typed 路由下
// `PlatformInputPhysicalRelativeTransaction` 根本不会走 legacy 回调，于是可能一次
// `resolveBridge()` 都还没发生。那样 typed 视角会永久落在 `kNoSink`（有计数、不静默，
// 但功能是死的）。因此本函数也在 `registerInputNapi` 时被无条件调用一次。
// 三个值都是本 image 的函数地址（进程常量）：只在首次调用时写 environ，此后 `resolveBridge`
// 首次成功时的再次调用是空操作，避免游戏期间 setenv 释放读者持有的旧串（I27-05）。
static std::once_flag s_reverseTrampolinesPublished;
static void publishReverseTrampolinesOnce() {
    // bridge 只写 atomic announcement；finger 迁移仍在 touchStateMutex 下由触摸入口完成，
    // 避免 MC 线程直接修改 registry。
    char grabCbBuf[32];
    snprintf(grabCbBuf, sizeof(grabCbBuf), "%llu",
             (unsigned long long)(uintptr_t)&amcl_touch_on_grab_changed);
    setenv("AMCL_TOUCH_GRAB_CB", grabCbBuf, 1);

    // Window destroy/recreate 需要同步进入 libentry 的完整 owner 取消事务；与 grab
    // announcement 分开，因为单纯发布 grab=false 只会在下个触摸事件迁移 epoch，无法保证
    // glfwDestroyWindow 返回时 ledger 已空。
    char cancelCbBuf[32];
    snprintf(cancelCbBuf, sizeof(cancelCbBuf), "%llu",
             (unsigned long long)(uintptr_t)&amcl_touch_cancel_from_bridge);
    setenv("AMCL_TOUCH_CANCEL_CB", cancelCbBuf, 1);

    // typed 平面的相对样本必须进**同一条**视角漏斗。它自己实现一遍的话，切到 typed 的
    // 当天灵敏度 / 倒置 Y / 加速 / 端级归一 / census / 守恒 backlog / 双坐标隔离 /
    // grab 重锚会一起失效，而其中"倒置 Y 失效"零日志（计划 §85）。
    char lookCbBuf[32];
    snprintf(lookCbBuf, sizeof(lookCbBuf), "%llu",
             (unsigned long long)(uintptr_t)&ohos_send_cursor_delta_checked);
    setenv("AMCL_LOOK_DELTA_CB", lookCbBuf, 1);
    // V2单独发布，旧二参数地址绝不能被解释为三参数ABI；进程常量仍只在早期发布一次。
    snprintf(lookCbBuf, sizeof(lookCbBuf), "%llu",
             (unsigned long long)(uintptr_t)&ohos_send_cursor_delta_at_time_checked);
    setenv("AMCL_LOOK_DELTA_V2_CB", lookCbBuf, 1);
}

static void publishReverseTrampolines() {
    std::call_once(s_reverseTrampolinesPublished, publishReverseTrampolinesOnce);
}

extern "C" void ohos_input_publish_trampolines(void) {
    publishReverseTrampolines();
}

static void resolveBridge() {
    if (s_bridgeResolved.load(std::memory_order_acquire)) return;
    std::lock_guard<std::mutex> lock(s_bridgeResolveMutex);
    if (s_bridgeResolved.load(std::memory_order_relaxed)) return;

    const char* env = getenv("OHOS_INPUT_BRIDGE");
    if (!env) return; // libglfw 尚未 publish；下一次输入再尝试，不把“未加载”永久缓存为失败

    unsigned long long addLook = 0, setMenu = 0, isGrab = 0, pushEvent = 0;
    unsigned long long beginPhysicalMotion = 0, endPhysicalMotion = 0;
    int windowSize = 0;
    int version = 0;
    char magic[16] = {};
    const int fields = sscanf(
        env, "%15[^:]:%d:%llu,%llu,%llu,%llu,%llu,%llu,%d",
        magic, &version, &addLook, &setMenu, &isGrab, &pushEvent,
        &beginPhysicalMotion, &endPhysicalMotion, &windowSize);
    if (fields != 9 || strcmp(magic, INPUT_BRIDGE_PROTO_MAGIC) != 0 ||
        version != INPUT_BRIDGE_PROTO_VERSION || addLook == 0 || setMenu == 0 ||
        isGrab == 0 || pushEvent == 0 || beginPhysicalMotion == 0 ||
        endPhysicalMotion == 0 || windowSize <= 0) {
        // 旧 ABI 不是“功能较少”而是会破坏双坐标/多生产者安全，因此必须拒绝，不能静默 fallback。
        AMCL_LOG_E(LOG_TAG,
            "Touch: bridge ABI rejected fields=%{public}d version=%{public}d (required v7)",
            fields, version);
        return;
    }

    s_addLookDeltaFn = reinterpret_cast<InputBridgeAddLookDeltaFn>((uintptr_t)addLook);
    s_setMenuCursorFn = reinterpret_cast<InputBridgeSetMenuCursorFn>((uintptr_t)setMenu);
    s_isGrabbingFn = reinterpret_cast<InputBridgeIsGrabbingFn>((uintptr_t)isGrab);
    s_pushEventFn = reinterpret_cast<InputBridgePushEventFn>((uintptr_t)pushEvent);
    s_beginPhysicalMotionFn = reinterpret_cast<InputBridgeBeginPhysicalMotionFn>(
        (uintptr_t)beginPhysicalMotion);
    s_endPhysicalMotionFn = reinterpret_cast<InputBridgeEndPhysicalMotionFn>(
        (uintptr_t)endPhysicalMotion);

    publishReverseTrampolines();

    s_bridgeResolved.store(true, std::memory_order_release);
    OH_LOG_INFO(LOG_APP, "Touch: Input bridge v7 resolved (windowSize=%{public}d)", windowSize);
}

static inline bool bridgeReady() {
    return s_bridgeResolved.load(std::memory_order_acquire) && s_addLookDeltaFn &&
           s_setMenuCursorFn && s_isGrabbingFn && s_pushEventFn &&
           s_beginPhysicalMotionFn && s_endPhysicalMotionFn;
}

static void sendEvent(int type, int i1, int i2, int i3, int i4) {
    if (s_pushEventFn) s_pushEventFn(type, i1, i2, i3, i4);
}

static bool isGrabbedMode() {
    resolveBridge();
    return s_isGrabbingFn ? s_isGrabbingFn() : false;
}

extern "C" bool ohos_sample_authoritative_grabbed_mode(bool* grabbed) {
    if (!ohos_begin_authoritative_grab_input_transaction(grabbed)) {
        return false;
    }
    ohos_end_authoritative_grab_input_transaction();
    return true;
}

extern "C" bool ohos_begin_authoritative_grab_input_transaction(
        bool* grabbed) {
    if (!grabbed) return false;
    resolveBridge();
    if (!s_beginPhysicalMotionFn || !s_endPhysicalMotionFn) return false;
    int value = 0;
    if (s_beginPhysicalMotionFn(&value) == 0) return false;
    *grabbed = value != 0;
    return true;
}

extern "C" void ohos_end_authoritative_grab_input_transaction(void) {
    if (s_endPhysicalMotionFn) s_endPhysicalMotionFn();
}

static inline void setMenuCursor(double x, double y) {
    if (!finitePair(x, y)) {
        recordNonFiniteMenuPosition();
        return;
    }
    if (s_setMenuCursorFn) s_setMenuCursorFn(x, y);
}

#include <vector>
#include <pthread.h>

// ⚠️ 这里曾有 legacy 的"按钮矩形 / 摇杆矩形"注册表（`ButtonRect` / `s_buttons` /
// `s_buttonsMutex` / `s_joyX..s_joyH` / `s_joyRegistered`）。**已整体删除。**
//
// 它的唯一读取方是 `hitButton()` / `isInJoystick()`，而那两个函数只在
// `grabbed && !s_schemaActive` 分支里被调用 —— `s_schemaActive` 是永为 true 的常量，
// 该分支自上线起从未执行。于是这张表成了一条**只写不读**的活跃路径：
// ArkTS 每次布局重建（插拔设备、grab 翻转、可见性档位、编辑器保存…）都跨 NAPI
// 调 clearButtons + clearJoystick + 逐个 registerButton 把它填满，而没有任何消费者。
//
// 触控虚拟按键端现在的唯一权威表述是 Control Schema（`s_schema` + `AmclCtrlEntry`），
// 命中判定、hitSlop、handledBy、四种 trigger 全在 `handleSchemaGrabbedTouch` 里。
// 删除范围一并覆盖 touch_input.h 的声明、NAPI 的四个入口、index.d.ts、
// obfuscation-rules 与 ArkTS 侧的全部调用点。

// ⚠️ 墓碑: `s_compWidth` / `s_compHeight` 与整条 `setCompSize` 跨语言写入链已删除
// （零读取点，与 §38.3 删掉的 legacy 矩形表同一个形状），详见计划 §64.3。
//
// ⚠️ 墓碑: `HIT_PAD_BUTTON_PX` / `HIT_PAD_JOYSTICK_PX` 已删除（零使用点）。命中扩张现由
// Control Schema 的 per-entry `hitSlop` 决定，不再有全局 padding 常量，详见计划 §64.4。

// ==================== 编辑模式暂停标志 ====================
// UI/lifecycle 线程写，XComponent touch/mouse/axis 线程读；atomic 只保护门控值，具体 finger/output
// 清理由 cancelAll 在状态锁内完成，不能把 atomic 当作取消事务本身。
static std::atomic<bool> s_touchPaused(false);

// ==================== LookProcessor（grabbed 模式）====================
// processor按source持有参数、速度时钟和守恒backlog；本mutex只串行legacy累计投递与idle。
// SDL typed物理直接调用同一processor后投递，不进入此累计入口，也不会重复提交位移。
// 平滑系数是参考 60Hz 的响应速度，1.0 表示立即输出。实现平滑的是下方守恒 backlog，
// 而不是直接 EMA 每个 delta；因此平滑只改变位移到达时间，不改变手势总灵敏度。
static pthread_mutex_t s_lookMutex = PTHREAD_MUTEX_INITIALIZER;
// 无显式 UP 的物理鼠标/手柄也必须满足位移守恒。单一空闲 worker 在最后一批 delta 后阻塞等待
// 20ms，再补齐 backlog；持续输入只会重排同一个 deadline，不创建线程/任务。condition 使用
// CLOCK_MONOTONIC，系统时间修改不会让尾量提前或永久滞留。初始化失败时 applyLookDelta 会在
// 当前调用内立即补齐，牺牲平滑延迟但绝不牺牲 Σoutput == Σaccepted input。
static pthread_cond_t s_lookIdleCond;
static pthread_once_t s_lookIdleOnce = PTHREAD_ONCE_INIT;
static std::atomic<bool> s_lookIdleWorkerReady(false);
static int64_t s_lookIdleDeadlineNs[AMCL_INPUT_SOURCE_COUNT]{};
static const int64_t kLookIdleFlushDelayNs = 20000000LL;
// 平滑 backlog 保存“已经接受但尚未输出”的位移，而不是上一事件的 delta。每次 MOVE 输出 backlog 的一部分，
// 正常 UP 时再 flush 余量，因此任意手势的总输出严格等于灵敏度/加速后的总输入；采样率只影响到达时间，
// 不再静默改变有效灵敏度。grab/lifecycle 边界会显式 discard，避免旧 epoch 尾量泄漏到新相机基准。

// 方案 C：视角加速强度 0..1（0 = 关闭，默认关闭以尊重老用户手感）。由 ohos_set_look_accel 写。
// 加速按"瞬时物理手速（px/s）"提升增益：手速越快、增益越高，慢速微调保持 1:1。
// 方案 C：上次 look 事件的单调时间戳（ns），用于算 dt（基于时间的平滑 + 加速，与事件密度/帧率解耦）。
// 0 = 无上次事件（首个事件 / 抬手 / 暂停后重置），此时按 60Hz 估算 dt。

// 单调时钟纳秒（方案 C）
static int64_t nowMonotonicNs() {
    struct timespec ts{};
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

/** 每个source独立计算idle尾量期限，物理样本不再推迟触控/手柄的收尾。 */
static void* lookIdleWorkerMain(void*) {
    pthread_mutex_lock(&s_lookMutex);
    for (;;) {
        int64_t nearest = 0;
        for (const int64_t due : s_lookIdleDeadlineNs) {
            if (due > 0 && (nearest == 0 || due < nearest)) nearest = due;
        }
        if (nearest == 0) {
            pthread_cond_wait(&s_lookIdleCond, &s_lookMutex);
            continue;
        }
        const int64_t now = nowMonotonicNs();
        if (now == 0 || now < nearest) {
            struct timespec deadline{};
            deadline.tv_sec = static_cast<time_t>(nearest / 1000000000LL);
            deadline.tv_nsec = static_cast<long>(nearest % 1000000000LL);
            pthread_cond_timedwait(&s_lookIdleCond, &s_lookMutex, &deadline);
            continue;
        }
        for (int32_t source = 0; source < AMCL_INPUT_SOURCE_COUNT; ++source) {
            if (s_lookIdleDeadlineNs[source] == 0 || s_lookIdleDeadlineNs[source] > now) continue;
            // 容量压力保原tail并有界重试；idle不先清余量再调用void accumulator丢输出。
            const bool flushed=amclSourceLookFlush(source,true);
            s_lookIdleDeadlineNs[source]=flushed?0:now+kLookIdleFlushDelayNs;
        }
    }
    return nullptr;
}
static void lookInitIdleWorker() {
    pthread_condattr_t attr;
    int rc = pthread_condattr_init(&attr);
    if (rc != 0) {
        AMCL_LOG_E(LOG_TAG, "Look idle worker disabled: condattr init rc=%{public}d", rc);
        return;
    }
    rc = pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
    if (rc != 0) {
        pthread_condattr_destroy(&attr);
        AMCL_LOG_E(LOG_TAG, "Look idle worker disabled: monotonic clock rc=%{public}d", rc);
        return;
    }
    rc = pthread_cond_init(&s_lookIdleCond, &attr);
    pthread_condattr_destroy(&attr);
    if (rc != 0) {
        AMCL_LOG_E(LOG_TAG, "Look idle worker disabled: cond init rc=%{public}d", rc);
        return;
    }

    pthread_t thread;
    rc = pthread_create(&thread, nullptr, lookIdleWorkerMain, nullptr);
    if (rc != 0) {
        AMCL_LOG_E(LOG_TAG, "Look idle worker create failed rc=%{public}d; using immediate conservation", rc);
        return;
    }
    pthread_detach(thread);
    s_lookIdleWorkerReady.store(true, std::memory_order_release);
}

// 视角增量的唯一漏斗。三个**平级输入端**（触控虚拟按键 / 手柄 / 物理键鼠）都从这里进，
// 统一加工：灵敏度、Y 倒置、基于速度的加速、位移守恒 backlog。平滑只改变到达时间，
// 正常触摸 UP 会补齐尾量，不再直接对 delta 做会丢失短手势位移的 EMA。
//
// 入参 dx/dy 是**该端的原始增量**，不要在调用方预乘灵敏度。
//
// `source` 是 2026-08-19 新增的必填参数，理由见 input_source.h：三端喂进来的量纲互不
// 相同（触控端是 surface 物理 px、键鼠端是 rawDelta 硬件原始值、手柄端是无物理长度含义的
// 摇杆量），而此前它们共用同一条灵敏度且**下游完全不知道来源** —— 任何一端调优都会破坏
// 另两端。现在每端先过一次 `amcl_input_source_look_scale()` 归一，那道接缝是结构性的；
// 当前三端系数一律 1.0，因此**行为与引入该参数之前逐位相同**。
/** legacy/touch/gamepad的加工后投递入口；typed物理由后端调用相同processor并直接投递。 */
static bool applyLookDelta(AmclInputSource source, double dx, double dy,
                           int64_t sampleTimeNs = 0) {
    if (!finitePair(dx, dy)) { recordInvalidLookDelta(); return false; }
    resolveBridge();
    if (!s_addLookDeltaFn) return false;
    pthread_once(&s_lookIdleOnce, lookInitIdleWorker);
    const bool idleWorkerReady = s_lookIdleWorkerReady.load(std::memory_order_acquire);
    pthread_mutex_lock(&s_lookMutex);
    const int64_t now = nowMonotonicNs();
    // deadline以处理时刻为准，运动速度以采样时刻为准，两种时钟用途不能混淆。
    const int64_t motionTime = sampleTimeNs > 0 ? sampleTimeNs : now;
    if (!amclSourceLookSubmit(static_cast<int32_t>(source),dx,dy,motionTime)) {
        pthread_mutex_unlock(&s_lookMutex);
        recordInvalidLookDelta();
        return false;
    }
    amcl::input::census::Bump(amcl::input::census::Channel::LookApplied);
    amcl_input_source_note_look(source);
    // neutral在真实队列容量预留后已原子接受数学和prefix，不再写全局future累计。
    if (idleWorkerReady) {
        s_lookIdleDeadlineNs[static_cast<int32_t>(source)] = now + kLookIdleFlushDelayNs;
    } else {
        // 无idle worker时即时补齐本端尾量，守恒且不冲掉其它source的平滑状态。
        (void)amclSourceLookFlush(static_cast<int32_t>(source),true);
    }
    pthread_mutex_unlock(&s_lookMutex);
    if (idleWorkerReady) pthread_cond_signal(&s_lookIdleCond);
    return true;
}
// 视角管线快照。⚠️ 每个数字都带 `{public}`：缺它 hilog 打成 `<private>`，于是日志只能证明
// "这行被打过"，证明不了任何取值 —— 四件套的三个 setter 曾整批栽在这上面（计划 §78.4）。
extern "C" void ohos_log_look_pipeline_state(void) {
    amcl::input::LookPipelineSnapshot snapshot{};
    bool conserved = false;
    snapshot = amcl::input::SourceLookPipelineSnapshot();
    conserved = std::abs(snapshot.emitDx + snapshot.backlogDx + snapshot.discardedDx -
                         snapshot.scaledDx) <= 1e-6 &&
                std::abs(snapshot.emitDy + snapshot.backlogDy + snapshot.discardedDy -
                         snapshot.scaledDy) <= 1e-6;
    // ⚠️ `travel` 是 Σ|scaled|（行程），`scaled` 是带符号净位移。跨包对比手势**只能用
    // travel** —— 净位移会因来回扫互相抵消，实测两个包 3069 vs 115 而链路上一处缩放都没有
    // （计划 §90.4）。恒等式仍然只认带符号的那份。
    OH_LOG_INFO(LOG_APP,
        "AMCL_LOOK accepted=%{public}llu rejected=%{public}llu emitted=%{public}llu "
        "flushEmit=%{public}llu flushDrop=%{public}llu "
        "scaled=(%{public}.3f,%{public}.3f) travel=(%{public}.3f,%{public}.3f) "
        "out=(%{public}.3f,%{public}.3f) "
        "backlog=(%{public}.3f,%{public}.3f) maxBacklog=%{public}.3f "
        "dropped=(%{public}.3f,%{public}.3f) conserved=%{public}d",
        (unsigned long long)snapshot.accepted,
        (unsigned long long)snapshot.rejected,
        (unsigned long long)snapshot.emitted,
        (unsigned long long)snapshot.flushEmit,
        (unsigned long long)snapshot.flushDiscard,
        snapshot.scaledDx, snapshot.scaledDy,
        snapshot.travelDx, snapshot.travelDy,
        snapshot.emitDx, snapshot.emitDy,
        snapshot.backlogDx, snapshot.backlogDy, snapshot.maxBacklog,
        snapshot.discardedDx, snapshot.discardedDy, conserved ? 1 : 0);
}

/** source=-1是整局边界；真实触摸UP只收尾触控source，不能刷新手柄/物理的时间状态。 */
static void flushLookPending(bool emit, int32_t source = -1) {
    const bool idleWorkerReady = s_lookIdleWorkerReady.load(std::memory_order_acquire);
    pthread_mutex_lock(&s_lookMutex);
    const int32_t first = source < 0 ? 0 : source;
    const int32_t end = source < 0 ? AMCL_INPUT_SOURCE_COUNT : source + 1;
    for (int32_t index = first; index < end; ++index) {
        const bool flushed=amclSourceLookFlush(index,emit);
        // 正常UP的Pressure保tail直到idle重试；取消只撤本source，不触兄弟设备stream。
        s_lookIdleDeadlineNs[index]=flushed||!emit?0:nowMonotonicNs()+kLookIdleFlushDelayNs;
    }
    pthread_mutex_unlock(&s_lookMutex);
    if (idleWorkerReady) pthread_cond_signal(&s_lookIdleCond);
}
// ==================== 每指坐标基准 ====================
//
// ⚠️ 墓碑: `enum FingerRole` / `FingerState::role` / `FingerState::buttonIndex` /
// `s_fingerUsed[]` / `initFingers()` 已删除（全部零读取或零调用），详见计划 §64.4。
// 手指的"角色"现在由 Control Schema 的 `SchemaFingerRole` 单独表达（见下方 `s_schemaFingers`）——
// 这里剩下的只是坐标基准。⚠️ 那是**另一个**符号，名字相近但不可混用。
struct FingerState {
    float lastX, lastY;
};

#define MAX_FINGERS 10
static FingerState s_fingers[MAX_FINGERS];  // 下标 = finger id

// 跨场景保留真实手指的dead/down状态；菜单事务token由统一MenuTouchInteraction出口独立管理。
static bool s_fingerDead[MAX_FINGERS] = { false };   // 跨 grab 翻转仍按着的手指 → 忽略其后续事件直到抬起
static bool s_fingerDown[MAX_FINGERS] = { false };   // 物理按下跟踪（任意模式，DOWN 置 / UP 清）：翻转时判定谁在按

// XComponent 回调线程与 NAPI/lifecycle 线程都会触碰 finger、dead、normal-menu owner 和 grab epoch。
// 这些状态由 touchStateMutex 统一串行，不能只依赖“平台通常按单线程派发”。固定锁顺序为：
//   surface gate → authoritative mode fence → touchState → schema → legacy transaction → ledger
// deadline扫描只取得schema；执行时先释放扫描锁，再从surface开始取得完整事务。
// bridge公告和TSFN不得同步反向进入touch/schema；生命周期取消等到事件完整提交后再归零。
static std::mutex s_touchStateMutex;

// ⚠️ 墓碑: `initFingers()` 已删除（全仓零调用方）。它只清 `role` 与 `s_fingerUsed`，
// 两者都已判死；`s_fingers[].lastX/lastY` 从来不需要预清 —— 每条 look 增量都在
// DOWN 时先写基准再用（见 SCHEMA_FINGER_LOOK 分支），详见计划 §64.4。

static bool pointInRect(float px, float py, float rx, float ry, float rw, float rh, float pad) {
    return px >= rx - pad && px <= rx + rw + pad &&
           py >= ry - pad && py <= ry + rh + pad;
}

// Phase 3.3a mouseSynth classification. API 12+ exposes a stable event-source
// query, so pressure/tool heuristics are no longer allowed to start a fallback
// click. The changed point must match the top-level id, report tool UNKNOWN,
// and report source MOUSE. Missing metadata stays Unknown and can only finish an
// already-bound terminal edge; stylus/finger/touchpad packets fail closed.
using amcl::input::ClassifyMouseSynthTouchSource;
using amcl::input::MouseSynthTouchSource;
struct ChangedTouchPointSource {
    MouseSynthTouchSource source = MouseSynthTouchSource::kUnknown;
    OH_NativeXComponent_TouchPointToolType tool =
        OH_NATIVEXCOMPONENT_TOOL_TYPE_UNKNOWN;
};

static ChangedTouchPointSource classifyChangedTouchPoint(
    OH_NativeXComponent* component,
    const OH_NativeXComponent_TouchEvent& ev) {
    ChangedTouchPointSource result;
    const size_t capacity = sizeof(ev.touchPoints) / sizeof(ev.touchPoints[0]);
    const size_t count = static_cast<size_t>(ev.numPoints);

#if AMCL_INPUT_GATE0_TELEMETRY
    // Both early exits below used to return kUnknown with no telemetry at all,
    // which made them the blind spot in this whole investigation: a synthesized
    // mirror packet most plausibly lands here and is then handled as a finger.
    auto emitEarlyExit = [&ev](int32_t numPoints) {
        const AmclGate0TouchSourceSample diagnostic{
            ev.id,
            static_cast<int32_t>(ev.type),
            numPoints,
            0,
            -1,
            static_cast<int32_t>(OH_NATIVEXCOMPONENT_TOOL_TYPE_UNKNOWN),
            -1,
            static_cast<int32_t>(OH_NATIVEXCOMPONENT_SOURCE_TYPE_UNKNOWN),
            static_cast<int32_t>(MouseSynthTouchSource::kUnknown),
            static_cast<double>(ev.x),
            static_cast<double>(ev.y),
        };
        amcl_gate0_trace_touch_source(&diagnostic);
    };
#endif

    if (count == 0 || count > capacity) {
#if AMCL_INPUT_GATE0_TELEMETRY
        emitEarlyExit(static_cast<int32_t>(ev.numPoints));
#endif
        return result;
    }

    size_t changedIndex = capacity;
    for (size_t i = 0; i < count; ++i) {
        if (ev.touchPoints[i].id == ev.id) {
            changedIndex = i;
            break;
        }
    }
    if (changedIndex == capacity) {
#if AMCL_INPUT_GATE0_TELEMETRY
        emitEarlyExit(static_cast<int32_t>(ev.numPoints));
#endif
        return result;
    }

    const bool toolQuerySucceeded =
        OH_NativeXComponent_GetTouchPointToolType(
            component, static_cast<uint32_t>(changedIndex), &result.tool) == 0;
    OH_NativeXComponent_EventSourceType eventSource =
        OH_NATIVEXCOMPONENT_SOURCE_TYPE_UNKNOWN;
    const bool sourceQuerySucceeded =
        OH_NativeXComponent_GetTouchEventSourceType(
            component, ev.id, &eventSource) == 0;
    result.source = ClassifyMouseSynthTouchSource(
        true, toolQuerySucceeded,
        result.tool == OH_NATIVEXCOMPONENT_TOOL_TYPE_UNKNOWN,
        sourceQuerySucceeded,
        eventSource == OH_NATIVEXCOMPONENT_SOURCE_TYPE_MOUSE);

    // ---- 常开取证：source 与 tool 两个 getter 的返回码与取值同时打印 ----
    //
    // 为什么必须常开、且必须两个一起打：OpenHarmony-SIG 的 Flutter 鸿蒙适配就是靠
    // `GetTouchEventSourceType(...) == SOURCE_TYPE_MOUSE` 丢弃鼠标派生的 TouchEvent，
    // 这是官方框架实际采用过的隔离手段。但本机 618/618 个包全部返回 TOUCHSCREEN，
    // 该判据永不成立。要把这件事作为**平台缺陷证据**提交，必须能区分两种情况：
    //   · source=TOUCHSCREEN 而 tool=MOUSE  ⇒ 只有 source 元数据被改坏，tool 仍保留鼠标身份；
    //   · source=TOUCHSCREEN 且 tool=FINGER ⇒ 整个 mouse→touch 转换把输入彻底重写成
    //     真实触屏语义，应用层再无任何可判别字段。后者是最强的工单证据。
    // 同时打印两个 getter 的返回码，用来排除"参数传错导致失败"这一解释
    // （rc 非 0 才是用法问题，rc=0 且值为 TOUCHSCREEN 就是平台如实这么报的）。
    //
    // 每个 (rcSource, source, rcTool, tool) 组合只打一条：组合数极少，稳态零开销。
    {
        static std::atomic<uint32_t> s_seenMask{0};
        const int32_t s = sourceQuerySucceeded
                              ? static_cast<int32_t>(eventSource) : 7;
        const int32_t t = toolQuerySucceeded
                              ? static_cast<int32_t>(result.tool) : 7;
        const uint32_t bit =
            1u << static_cast<uint32_t>(((s & 3) << 3) | (t & 7));
        uint32_t seen = s_seenMask.load(std::memory_order_relaxed);
        if ((seen & bit) == 0u &&
            s_seenMask.compare_exchange_strong(seen, seen | bit,
                                               std::memory_order_acq_rel,
                                               std::memory_order_relaxed)) {
            OH_LOG_INFO(LOG_APP,
                        "AMCL_TOUCHSRC rcSource=%{public}d source=%{public}d "
                        "rcTool=%{public}d tool=%{public}d evId=%{public}d "
                        "changedIdx=%{public}d numPoints=%{public}d "
                        "classified=%{public}d",
                        sourceQuerySucceeded ? 0 : -1,
                        static_cast<int32_t>(eventSource),
                        toolQuerySucceeded ? 0 : -1,
                        static_cast<int32_t>(result.tool),
                        ev.id, static_cast<int32_t>(changedIndex),
                        static_cast<int32_t>(ev.numPoints),
                        static_cast<int32_t>(result.source));
        }
    }
#if AMCL_INPUT_GATE0_TELEMETRY
    {
        // Evidence for "can the platform tell us a packet came from the mouse".
        // Emitted after classification so the log shows the exact inputs and the
        // resulting bucket; it never influences the decision.
        const AmclGate0TouchSourceSample diagnostic{
            ev.id,
            static_cast<int32_t>(ev.type),
            static_cast<int32_t>(ev.numPoints),
            1,
            toolQuerySucceeded ? 0 : -1,
            static_cast<int32_t>(result.tool),
            sourceQuerySucceeded ? 0 : -1,
            static_cast<int32_t>(eventSource),
            static_cast<int32_t>(result.source),
            static_cast<double>(ev.x),
            static_cast<double>(ev.y),
        };
        amcl_gate0_trace_touch_source(&diagnostic);
    }
#endif
    return result;
}

// ⚠️ `isInJoystick()` 与 `hitButton()` 已删除（随 legacy 注册表一起，理由见文件上方
// 那段说明）。它们是那张表的唯一读取方，而调用它们的分支永不执行。
// 触控端的命中判定现在只有一处：`schemaHitTestLocked`（Control Schema）。

// ==================== 触控虚拟按键端：Control Schema + C 层解释器 ====================
//
// 这是**三个平级输入端**之一（见 platform/input_source.h）。
// ArkTS 下发整份控件表存进 s_schema（见 ohos_set_control_schema）；grabbed 触摸由本 C 层
// 解释器（handleSchemaGrabbedTouch）**单一**处理，按 s_schemaTakeover 掩码逐类接管：
//   摇杆 8 向 WASD、四种 trigger 的按钮、滚轮条、物品栏直点、dragLook、空白 look。
// ArkTS 侧对已接管类型只保留视觉（按下高亮经 onButtonPressed 回调驱动），不再发事件。
// 已覆盖（A.2/A.3/A.4）：摇杆 8 向 WASD + 30ms 方向锁存、press/toggle/doubleTap/longPress 四模式按钮、
//   按钮占用集合去重（双指交替按同键）、滚轮、物品栏直点、look 落点、dragLook（按住保持 PRESS + 拖动转视角）、
//   ime_chat/drawer（handledBy=arkts → amcl_fire_control_activated 回调 ArkTS）、
//   摇杆死区取全局 profile（s_schemaDeadZone）。至此已达成与 ArkTS 旧路径的行为对齐。
// longPress 由单一、按 CLOCK_MONOTONIC 休眠的 deadline worker 驱动。worker 在没有 deadline 时阻塞，
// 不做轮询；它只在持有 s_schemaMutex 时改变 trigger runtime，输出边沿再由 owner-aware ledger 去重。
// 因而“单指静止按住”也会准时触发，同时不会为每个按钮创建线程或持续唤醒 CPU。
//
// grab 翻转不再等待 ArkTS 重推 schema，也不再用按住时长猜测是否 carry。GrabEpochCoordinator 在 native
// announcement 后、下一条触摸事件记账前同步检查“物理 finger 仍 down 且 owner 确实持有输出”，将这些
// finger 绑定到同一 carried owner；末指 UP 才释放。Schema replacement 只取消旧 generation 的 owner，
// carried owner 则继续由物理生命周期收尾。此顺序是防止已抬手被错误保留和共享键提前 RELEASE 的核心不变量。
static std::vector<AmclCtrlEntry> s_schema;
static pthread_mutex_t s_schemaMutex = PTHREAD_MUTEX_INITIALIZER;
static bool s_schemaActive = true;    // A.6 真机分阶段激活：C 层接管 grabbed 触摸（按 s_schemaTakeover 掩码逐类型）
// A.6 接管类型掩码（bit = 1<<kind）：命中该类 native 控件才由 C 处理，否则标 -4 交回 ArkTS。
// 分阶段打开：阶段1 仅摇杆(1<<1)；后续逐步 |= 按钮(1<<0)/滚轮(1<<2)/物品栏(1<<4)。ArkTS 侧须同步门控停发。
static int s_schemaTakeover = (1 << 1) | (1 << 0) | (1 << 2) | (1 << 4);   // 阶段3：摇杆+按钮+滚轮+物品栏
// ⚠️ 墓碑: `s_schemaCompW` / `s_schemaCompH` / `s_schemaGrabbed` 已删除（各一写零读），
// 详见计划 §64.4。⚠️ **不要**据此以为这三个量没被用到 —— 死的只是"存进 TU 静态"这一步。
// `ohos_set_control_schema` 的三个**形参**都是活的：`compW`/`compH` 用于逐控件矩形越界
// 校验（`schemaEntriesValid`），`grabbed` 用于取值校验、以及 bridge 尚未加载时初始化
// `s_grabFlipLastState` 这一个 grab epoch 基准。
static float s_schemaDeadZone = 0.18f;   // A.4-part2：全局摇杆死区（由 ArkTS profile 下发）

static uint64_t s_schemaGeneration = 0;
// 发布记录和模态只在surface gate保护下读写；实际schema/触指采样仍另持touch→schema锁。
static amcl::input::TouchPublicationState s_touchAdmission;
/** 组态由同一 schema 临界区拥有；通知只唤醒 UI，失败后由原 reconcile 查询恢复。 */
static amcl::input::TouchGroupState s_touchGroups;
static uint64_t s_touchGroupSequence = 0;
/** UI 来源仍走原 Source token；固定槽位仅记录成员归属，隐藏时可精确退休而不清整个来源。 */
struct GroupUiOwner { uint64_t token = 0; int control = -1; };
static std::array<GroupUiOwner, 512> s_groupUiOwners{};
static std::string s_groupMouseMember;
static int s_groupMouseControl = -1;
extern "C" void amcl_notify_touch_groups();
static void schemaAdvanceGroupsLocked();
static uint64_t s_touchContextPolicy = 1;
static uint32_t s_touchContextTransform = 0;
static double s_touchContextDensity = 1.0;
static uint64_t s_schemaContextPolicy = 0;
// grab场景是独立身份，不能混入会使schema完整退休的单位policy或typed/text复位代次。
static uint64_t s_touchPublicationGrabEpoch = 0;
/** caller已持gate→touch；在direct-touch准入前核实Native当前身份，不依赖UI下一次轮询。 */
namespace {
amcl::input::TouchPublicationContext touchPublicationContextLocked();
bool touchAdmissionBlocksNewTouchLocked();
bool touchAdmissionAcceptsUiContinuationLocked(uint64_t token); // caller持gate→mode/touch→schema
}
// 这两项参与真正的定义比较；相同表重发保持finger/owner，实际几何变化仍建立新一代。
static float s_schemaWidthPx = 0.0f;
static float s_schemaHeightPx = 0.0f;
// 交互策略与几何同属 schema generation；仅在 schema 锁内访问，包括唯一 deadline worker。
static amcl::input::TouchInteractionConfig s_touchConfig;
static amcl::input::MenuTouchInteraction s_menuTouch;
// 写入沿用各出口的touch/schema锁，读取同时持两锁；它只记录真实接受态，不产生任何输入。
static amcl::input::TouchGuideSignals s_touchGuide;
// 本体跟随指针时只移动ArkUI排除区，不能重发整个schema导致正在拖动的鼠标键被释放。
// 仅在菜单分支、持schema锁时读取；命中的触点继续冻结为ARKTS直到UP/CANCEL。
static double s_menuMouseBounds[4]{};
// 教学工具栏只拦截新DOWN；显示/关闭不属于游戏控件配置变化，不能取消摇杆、锁定键或菜单拖动。
static double s_touchGuideBounds[4]{};

/** 两种临时覆盖层共用半开边界；读取方持schema锁，认领后的触点不随矩形更新改换角色。 */
static bool touchOverlayContains(const double bounds[4],double x,double y) {
    return bounds[2]>0 && bounds[3]>0 && x>=bounds[0] && y>=bounds[1] &&
        x<bounds[0]+bounds[2] && y<bounds[1]+bounds[3];
}
static amcl::input::TouchJoystickInteraction s_touchJoystick;
static std::string s_touchJoystickId;
static uint32_t s_touchMenuToken = 0;
static uint32_t s_touchMenuNextToken = 0x40000000u;
static std::atomic<bool> s_touchMenuCursorVisible{false};
// 菜单工具按控件冻结独立来源租约，不进入 common ledger。每个 control 只有一个
// 全局不复用 owner 与按下时 code；同码多 owner 在本来源首按末松，然后由 bridge
// 与其它来源聚合。写入、统计读取同持公共 transaction，触控入口外层仍持 touch。
struct MenuToolOwner { uint64_t token = 0; int code = 0; };
static std::map<std::string,MenuToolOwner> s_menuToolOwners;
// 工具域在Native只有一个当前panel实例。正常UP归零仍保留prefix，便于撤销该实例
// 已结束但尚未消费的1011；新实例接管/全scope退休才换身份，旧销毁不能取消新面板。
static std::string s_menuToolPanelPrefix;
// 注册绑定真实UI publication；同publication的Entry序号单调水位保留到新publication/PID，
// 不保存无限旧prefix集合，也不能因零held允许旧实例重新抢占当前可视面板。
static uint64_t s_menuToolRegistrationPublication = 0, s_menuToolPanelWatermark = 0;
static uint32_t s_menuToolAcquired = 0, s_menuToolReleased = 0;
static pid_t s_menuToolProcess = 0;
static void releaseMenuToolControls(bool retireRegistration = true); // 调用者持s_touchStateMutex。
static bool menuToolMouseHeldLocked(); // 调用者持touch；内部仅取得更内层transaction。
static void emitMenuInteraction(amcl::input::MenuTouchAction action, double x, double y);

// OwnerToken 是跨 schema generation 追踪持续输出的稳定身份。using 必须位于所有
// runtime/binding 结构之前：这些结构保存的是 owner，而不是可漂移的 vector 下标。
using amcl::input::InputLedger;
using amcl::input::LegacyPhysicalAction;
using amcl::input::LegacyPhysicalEdgeRouter;
using amcl::input::LegacyPhysicalIdentity;
using amcl::input::Output;
using amcl::input::OutputKind;
using amcl::input::OwnerToken;

enum SchemaFingerRole {
    SCHEMA_FINGER_NONE = 0,
    SCHEMA_FINGER_LOOK,
    SCHEMA_FINGER_ARKTS,
    SCHEMA_FINGER_JOYSTICK,
    SCHEMA_FINGER_BUTTON,
    SCHEMA_FINGER_SCROLL,
    SCHEMA_FINGER_HOTBAR,
    SCHEMA_FINGER_IGNORED
};

struct SchemaFingerBinding {
    SchemaFingerRole role = SCHEMA_FINGER_NONE;
    uint64_t generation = 0;
    OwnerToken owner = 0;
    AmclCtrlEntry control{}; // DOWN 时的不可变快照；MOVE/UP 不再查询当前 schema
    // 可选空白手势/快捷栏长按的原始几何和期限；输出仍使用本指 owner，取消时一起退休。
    double startX = 0, startY = 0;
    int64_t startNs = 0, deadlineNs = 0;
    int initialSlot = -1;
    bool moved = false, holdFired = false;
};

struct SchemaButtonRuntime {
    AmclCtrlEntry control{};
    std::set<int> fingers;
    OwnerToken owner = 0;
    bool outputDown = false;
    bool toggled = false;
    bool longFired = false;
    long long lastTapNs = 0;
    long long longDeadlineNs = 0;
    /** v4 四阶段分别持有，不借普通 outputDown 表示多份键输出。 */
    int groupControl = -1;
    uint64_t groupEligibility = 0;
    std::array<OwnerToken, 4> phaseOwners{};
    std::array<bool, 4> phaseHeld{};
    int64_t groupDownNs = 0;
    bool groupMoved = false;
};

struct SchemaCarriedOwner {
    std::string id;
    OwnerToken owner = 0;
    std::set<int> fingers;
    /** 原组身份独立于菜单场景投影；显式隐藏组仍须退休这项已承接贡献。 */
    std::string groupId;
};

static SchemaFingerBinding s_schemaFingers[MAX_FINGERS];
static std::map<std::string, SchemaButtonRuntime> s_schemaButtons;
static std::map<OwnerToken, SchemaCarriedOwner> s_schemaCarriedOwners;
static std::map<int, OwnerToken> s_schemaCarriedByFinger;
// 摇杆 WASD 的按下 / 期望 / 松开时刻 / 补发期限（schema_wasd_latch.h）。只在 s_schemaMutex 内访问；
// 被 30ms 锁存吞掉的 PRESS 由 deadline worker 在期限到达时补发。
static amcl::input::SchemaWasdLatch s_schemaWasdLatch;
static int s_schemaJoyFinger = -1;
static int s_schemaLookFinger = -1;
static float s_schemaScrollLastY[MAX_FINGERS];
static float s_schemaScrollAccum[MAX_FINGERS];

static int s_schemaHotbarLastSlot[MAX_FINGERS];
static int s_touchLastTapSlot = -1;
static int64_t s_touchLastTapNs = 0;
static std::string s_touchLastTapControl;
static float s_schemaDragLastX[MAX_FINGERS];
static float s_schemaDragLastY[MAX_FINGERS];

// 触点用surface px，12vp阈值在采样时按宿主密度换算，不能固定假设density=3。
static float schemaScrollStepPx() { return amcl::input::ControlScrollStepPx(ohos_display_density()); }
#define SCHEMA_HOTBAR_SLOTS 9
#define SCHEMA_GLFW_KEY_1 49
#define SCHEMA_DOUBLETAP_NS 300000000LL
#define SCHEMA_LONGPRESS_NS 200000000LL

static long long schemaNowNs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec;
}

// ==================== owner-aware OutputLedger ====================
// 所有持续输出都由 OwnerToken 持有；第一个 owner 获取时发 PRESS，最后一个 owner 消失时发 RELEASE。
// schema owner 与兼容 ArkTS owner 隔离，统一 cancelAll 可一次性释放全部来源。

static constexpr OwnerToken OWNER_SCHEMA_WASD = 0x300000001ULL;
// 平台只锁自己的解释器/诊断采样，不借 neutral mutex。来源候选与运输由 POD port
// 内部唯一事务串行；Java 与其它 namespace 也必须走该 port，不能依赖这里的本地锁。
static std::mutex s_externalInputMutex;

// ==================== external held：**按端**记账 ====================
//
// 记账逻辑与配对规则已抽到 platform/external_held_registry.{h,cpp}（纯数据结构、
// 无锁无日志、有 host test 覆盖）。抽出的理由：这块承载的是"抬起拿错 owner"这类
// **静默**故障 —— 不崩不报错，只在用户报告"卡键"时才暴露 —— 恰恰最需要测试覆盖，
// 而它原先埋在这个三千多行的 TU 里，主机侧构建拉不进来。
//
// neutral SourceControl facade 拥有注册表；这里是值 proxy。平台的 external 采样锁只串行
// 本模块诊断步骤，不承担跨生产者权威；每次 proxy query 返回独立的完整值快照。
static amcl::input::SourceRegistryProxy s_externalHeld;

// 把任意整数收敛到合法端身份。越界值一律记作 NONE 而不是原样存进表里 ——
// 一条 source=7 的记录永远不会被任何 `ohos_release_input_source_held` 匹配到，
// 就成了一个只能靠全局 cancel 才清得掉的幽灵持有记录。NAPI 层已经校验过，
// 这里是跨 .so 边界的第二道，直接调 C API 的调用方同样受保护。
static AmclInputSource normalizeInputSource(int value) {
    switch (value) {
        case AMCL_INPUT_SOURCE_TOUCH_CONTROLS:
        case AMCL_INPUT_SOURCE_GAMEPAD:
        case AMCL_INPUT_SOURCE_PHYSICAL_KBM:
        case AMCL_INPUT_SOURCE_PLATFORM_GESTURE:
            return static_cast<AmclInputSource>(value);
        default:
            return AMCL_INPUT_SOURCE_NONE;
    }
}
static std::mutex s_physicalInputMutex;
static double s_axisVAccum = 0.0;
static std::atomic<uint64_t> s_invalidPhysicalWheelCount(0u);
// 这是 touch/schema/menu 平台状态的递归锁，永远不把地址传过 DSO 边界。
static std::recursive_mutex s_inputTransactionMutex;

/** 菜单工具的完整诊断投影；outputMask 按 Left/Right/Shift 表示集合，不能直接与common数量相加。 */
struct MenuToolHeldSnapshot {
    unsigned live = 0, acquired = 0, released = 0, maxSameCode = 0, outputMask = 0;
};

/** 同一PID内只由touch→transaction写入；fork后的复制租约不是新进程的用户按下。caller持transaction。 */
static void reconcileMenuToolProcessLocked() {
    const pid_t process = getpid();
    if (s_menuToolProcess == process) return;
    if (s_menuToolProcess != 0) {
        // 先退休新进程bridge中的继承前缀，随后丢弃Native继承租约；不重放旧PRESS或
        // 用旧token发送RELEASE。计数从本PID开始，避免把父进程操作写入子进程统计。
        inputBridge_retireTouchMenuScopeV1();
        s_menuToolOwners.clear();
        s_menuToolPanelPrefix.clear();
        s_menuToolRegistrationPublication = s_menuToolPanelWatermark = 0;
        s_menuToolAcquired = s_menuToolReleased = 0;
    }
    s_menuToolProcess = process;
}

/** 统计与持有变化共用transaction，单次复制完整源状态；不反取touch锁，取消内部调用也安全。 */
static MenuToolHeldSnapshot menuToolHeldSnapshot() {
    std::lock_guard<std::recursive_mutex> transaction(s_inputTransactionMutex);
    reconcileMenuToolProcessLocked();
    MenuToolHeldSnapshot snapshot;
    unsigned counts[3]{};
    for (const auto& item : s_menuToolOwners) {
        const int index = item.second.code == -1 ? 0 : item.second.code == -2 ? 1 : 2;
        ++counts[index];
    }
    snapshot.live = static_cast<unsigned>(s_menuToolOwners.size());
    snapshot.acquired = s_menuToolAcquired; snapshot.released = s_menuToolReleased;
    for (unsigned i = 0; i < 3; ++i) {
        if (counts[i] != 0) snapshot.outputMask |= 1u << i;
        snapshot.maxSameCode = std::max(snapshot.maxSameCode, counts[i]);
    }
    return snapshot;
}

/** 显式工具LEFT/RIGHT已被认领时，普通屏幕手指只移动指针；Shift不占鼠标按钮角色。 */
static bool menuToolMouseHeldLocked() {
    return (menuToolHeldSnapshot().outputMask & 3u) != 0;
}

/** Entry实例前缀是规范的mouse-panel-N:，N必须是ArkTS可精确表示的正整数，不接受溢出/前导零。 */
static bool parseMenuToolPanelPrefix(const char* prefix,uint64_t* identity) {
    if (!prefix || !identity) return false;
    const std::string value(prefix), marker="mouse-panel-";
    if (value.size()<=marker.size()+1 || value.size()>192 || value.compare(0,marker.size(),marker)!=0 || value.back()!=':') return false;
    uint64_t serial=0;
    for(size_t i=marker.size();i+1<value.size();++i) {
        const unsigned char digit=static_cast<unsigned char>(value[i]);
        if(digit<'0' || digit>'9' || (i==marker.size() && digit=='0')) return false;
        const uint64_t next=digit-'0';
        if(serial>(UINT64_C(9007199254740991)-next)/10) return false;
        serial=serial*10+next;
    }
    if(serial==0) return false;
    *identity=serial;return true;
}

/** caller持touch→transaction；仅已由实际可视bounds注册的实例可产生工具输入，动作自身不能接管。 */
static bool menuToolPanelMatchesLocked(const char* prefix,uint64_t publication) {
    uint64_t identity=0;
    return parseMenuToolPanelPrefix(prefix,&identity) && !s_menuToolPanelPrefix.empty() &&
        s_menuToolPanelPrefix==prefix && publication!=0 && s_menuToolRegistrationPublication==publication;
}

/** 直接与工具滚轮共用统计出口，但投递到不同scope；不借ordinary1007丢失取消权限。 */
static bool emitScopedMenuScroll(int dx,int dy,bool tool) {
    if(dx==0 && dy==0) return false;
    if(tool) inputBridge_pushTouchMenuToolScrollV1(dx,dy);
    else inputBridge_publishTouchMenuScrollV1(dx,dy);
    amcl::input::census::Bump(amcl::input::census::Channel::ScrollDelivered);
    amcl_input_source_note_scroll(AMCL_INPUT_SOURCE_TOUCH_CONTROLS);
    return true;
}

/** 有效surface/schema下，一次packed快照映射未clamp的真实delta及同一viewport边界。caller持gate→touch→schema。 */
static bool mapMenuRelativePayload(double dx,double dy,double* x,double* y,double* maxX,double* maxY) {
    return s_schemaWidthPx>0 && s_schemaHeightPx>0 && amcl::renderscale::MapPointerDelta(dx,dy,
        std::max(0.0,static_cast<double>(s_schemaWidthPx)-1),std::max(0.0,static_cast<double>(s_schemaHeightPx)-1),x,y,maxX,maxY);
}

/** UI反馈与取消只承接选定实际consumer的ACK；不读取任何latest producer位置，也不改direct冻结手势。 */
static bool adoptCommittedMenuCursorLocked() {
    if(s_menuTouch.DirectActive() || !s_surfaceInputGate.active) return false;
    AmclCommittedMenuCursorV1 point{};point.structSize=sizeof(point);
    if(inputBridge_getCommittedMenuCursorV1(&point)!=1 || point.abiVersion!=AMCL_MENU_CURSOR_SNAPSHOT_VERSION ||
       point.flags!=AMCL_MENU_CURSOR_COMMITTED || point.processId!=static_cast<uint64_t>(getpid()) ||
       point.gameSession==0 || point.logicalTarget==0 || point.inputPublication!=s_surfaceInputGate.publicationGeneration) return false;
    double x=0,y=0;
    if(!amcl::renderscale::UnmapWindowPoint(point.x,point.y,&x,&y)) return false;
    s_menuTouch.AdoptConsumedCursor(x,y);return true;
}

/** 工具出口传真实relative delta；无论反馈clamp/ACK怎样改变投影，都不从absolute差分推导输入。 */
static void emitMenuToolPosition(amcl::input::MenuTouchAction action,double x,double y) {
    if(action!=amcl::input::MenuTouchAction::RelativePosition) return;
    double dx=0,dy=0,maxX=0,maxY=0;
    if(mapMenuRelativePayload(x,y,&dx,&dy,&maxX,&maxY)) inputBridge_publishTouchMenuToolRelativeV1(dx,dy,maxX,maxY);
}

// HarmonyOS devices can expose both XComponent and ArkUI button callbacks for
// one physical mouse, or register the native callback successfully while
// reporting only NONE/NONE edges. Arbitration is lifecycle-scoped but kept
// per button: a device may expose one button through native and another only
// through ArkUI. The losing source for that button is dropped before either
// typed or legacy state is touched.
// 全部按钮现在由 input_channel_policy 保存(device,button,DOWN channel)配对。
// 不再用500ms静默推断通道死亡：长按本来就可以长时间没有边沿，超时换源会把
// device=0 的 native DOWN 和有真实 deviceId 的 ArkUI UP 拆成两个永久失配的身份。

// ==================== ArkTS 相对样本的活跃时间戳 ====================
//
// ⚠️ 这一段曾叫"相对移动通道交接"，并声称：镜像 MOVE 是按住左键期间的视角来源、
// 「这正是必须由镜像 MOVE 补上的那一段」、两条通道用一个 64ms 空闲窗互相交接、
// 「ArkTS 停止投递超过该窗口后，**镜像立刻接管**」。
//
// **那套交接机制已经不存在了。** 镜像视角通道在 §30.2 按用户要求整体删除，
// 视角**唯一来源是 ArkTS rawDelta**（见本文件 mirrorPacket 分支里的删除记录）。
// 所以这个时间戳当前**不控制任何交接** —— 它只剩两个消费者：
//   ① `amcl_cursor_lock_note_relative_sample()`（钉住模式看门狗的唯一输入）；
//   ② `ohos_arkts_relative_channel_live()` → `window_event_filter.cpp` 的看门狗记账。
// 两者都只是"这条通道最近活着吗"的探针，不参与视角路由。
//
// 必须改掉的原因：旧措辞会让人相信"按住左键时还有一条兜底视角通道"，
// 而代码**刻意**让那种状态没有生产者（那正是用户要求的可判读性 —— 视角不动就是
// 一个干净的否证信号，而不是一段手感突变的位移）。
// `kArktsRelativeHandoverIdleNs`（64ms）现在的语义只是"多久没有非零样本算这条通道死了"。

static std::atomic<int64_t> s_arktsRelativeMotionLastNs(0);

extern "C" void ohos_note_arkts_relative_motion(void) {
    s_arktsRelativeMotionLastNs.store(nowMonotonicNs(),
                                      std::memory_order_release);
    // 同一个"非零相对样本"事实也是光标锁钉住模式看门狗的唯一输入：钉住之后如果
    // 一个相对样本都不来，说明这台设备钉住后连 rawDelta 也停了，必须降级回跟随模式，
    // 否则视角会完全消失。调用方已保证只在位移非零时进来。
    amcl_cursor_lock_note_relative_sample();
}



// 屏幕像素密度。触摸流里的坐标是 surface 物理 px，而 ArkTS rawDelta 已被系统按
// 显示大小比例缩小过；两者要喂进同一个 applyLookDelta，必须先统一量纲。
static std::atomic<double> s_displayDensity(1.0);

extern "C" void ohos_set_display_density(double density) {
    if (!(density > 0.0) || !std::isfinite(density)) return;
    // density即使未改变px视口也会改变菜单阈值/单位。策略事务同步缓存并只退休touch域。
    amcl::input::TouchContextPolicyChanged(density, UINT32_MAX);
}

// ⚠️ 这里曾写着「视角现在唯一来自 ArkTS rawDelta，与触摸流的 px 量纲不再混用，因此
// 这里不再需要换算」。**第一句在删掉触摸镜像视角通道（§30.2）之后对物理鼠标成立，
// 但推不出第二句** —— 触控端的 look 一直是活的：`handleSchemaGrabbedTouch` 仍在调
// `applyLookDelta(AMCL_INPUT_SOURCE_TOUCH_CONTROLS, ...)`，量纲是 surface 物理 px
// （见那里的注释与 census 的 `lookSchema`，真机日志有计数）。
//
// 所以真实状态是：**两种量纲仍在共用同一条 `s_lookSensitivity`**，
// 这正是 `输入架构规范.md` §五 与 §九 记录的已知缺口
// （`amcl_input_source_look_scale` 三端都返回 1.0，
// 接缝在但未标定）。照这段旧注释会得出"密度不参与视角换算、可以放心动"的错误结论，
// 而 `McGamePage` 里 `setDisplayDensity` 调用点的注释说的正相反 —— 同一个变量两处描述冲突。
//
// 密度仍然接收并保留：菜单绝对指针的 vp→px 换算（§36）是它当前的**生产依赖**，
// 不是"供后续使用"。接口不能删。
extern "C" double ohos_display_density(void) {
    const double d = s_displayDensity.load(std::memory_order_acquire);
    return (d > 0.0 && std::isfinite(d)) ? d : 1.0;
}

double amclDisplayDensityForDiagnostics() {
    const double d = s_displayDensity.load(std::memory_order_acquire);
    return (d > 0.0 && std::isfinite(d)) ? d : 1.0;
}

// 轴驱动 Pan（滚轮/触控板）抑制窗。手势结束后再保留一小段，覆盖平台的惯性尾包。
static constexpr int64_t kAxisPanLookSuppressTailNs = 150000000LL;
static std::atomic<int64_t> s_axisPanActiveSinceNs(0);
static std::atomic<int64_t> s_axisPanEndedAtNs(0);

extern "C" void ohos_note_axis_pan_active(int active) {
    const int64_t now = nowMonotonicNs();
    if (active) {
        s_axisPanActiveSinceNs.store(now, std::memory_order_release);
        s_axisPanEndedAtNs.store(0, std::memory_order_release);
    } else {
        s_axisPanActiveSinceNs.store(0, std::memory_order_release);
        s_axisPanEndedAtNs.store(now, std::memory_order_release);
    }
}

static bool axisPanLookSuppressed(int64_t nowNs) {
    if (s_axisPanActiveSinceNs.load(std::memory_order_acquire) != 0) return true;
    const int64_t ended = s_axisPanEndedAtNs.load(std::memory_order_acquire);
    if (ended == 0) return false;
    return (nowNs - ended) < kAxisPanLookSuppressTailNs;
}

// "这条 ArkTS 相对通道最近还活着吗"的判定窗口。
//
// ⚠️ 这里曾写着「**视角双通道的交接窗。必须存在**：按住左键期间 ArkTS rawDelta 与
// 镜像位置差分都可能投递同一帧的位移……若两者都产出，该帧位移被算两遍」。
// **镜像位置差分那条通道已在 §30.2 删除**（见本文件 `s_arktsRelativeMotionLastNs`
// 上方与 mirrorPacket 分支的记录），所以"双通道"与"交接"都不存在了，
// 也不存在"算两遍"的风险 —— 只有一个生产者。
//
// 现在它唯一的作用是给两个**看门狗**提供"活跃/沉默"判据（光标锁钉住模式降级、
// 窗口级过滤器降级）。窗口值 64ms 沿用不变：鼠标采样约 7~8ms 一个，所以它仍然是
// "沉默了好几个采样周期"的合理阈值。
//
// 判据是"最近是否投递过**非零**位移"（见 napi_input.cpp 的调用点）：
// 只被调用、位移为 0 的样本不算活跃。这一条**必须保留** —— 它是 §24 那次
// "钉住模式下完全拖不动"的直接成因：零位移样本把判据刷成"活跃"，
// 于是看门狗永远不降级，而实际一个像素都没动。
static constexpr int64_t kArktsRelativeHandoverIdleNs = 64000000LL;

static bool arktsRelativeChannelLive(int64_t nowNs) {
    const int64_t last =
        s_arktsRelativeMotionLastNs.load(std::memory_order_acquire);
    if (last == 0) return false;
    return (nowNs - last) < kArktsRelativeHandoverIdleNs;
}

// 窗口级过滤器的看门狗判据。
//
// ⚠️ 原文说它"刻意复用与**镜像交接**完全同一份判据"，而镜像交接已不存在（见上）。
// 复用同一份判据这件事本身仍然成立且仍然重要，只是理由要换：现在的两个消费者是
// **两个看门狗**（光标锁降级、窗口过滤器降级）。若它们用不同的宽松度，就会出现
// "一个认为通道活着、另一个认为已死"，两边各自做出相反的降级决定，
// 而日志里看不出是谁在冲突。
extern "C" int ohos_arkts_relative_channel_live(void) {
    return arktsRelativeChannelLive(nowMonotonicNs()) ? 1 : 0;
}

// 转换后滚轮手势的识别状态（每 finger 一份）。只在触摸回调线程访问。
static bool s_wheelGestureActive[MAX_FINGERS];
static bool s_wheelGestureIntegral[MAX_FINGERS];
static float s_wheelGestureAnchorX[MAX_FINGERS];
static float s_wheelGestureLastY[MAX_FINGERS];
// 未兑换成"格"的纵向残量（px）。见 kWheelNotchPx 的说明。
static float s_wheelGestureResidualPx[MAX_FINGERS];

// 一格滚轮在这条合成触摸流里的纵向阶跃量（px）。真机实测约 90px（≈42vp，
// density 2.125）。分格用"累计位移 / 一格"而不是"每个超过识别阈值的包发一格"：
// 后者在一格被拆成 3 个 30px 包时会发 3 格，在两格合并成 1 个 180px 包时只发 1 格。
static constexpr float kWheelNotchPx = 90.0f;
// 识别阈值：单帧 |Δy| 达到此值才认定这条手势是滚轮而不是手指。取 1/3 格，
// 远大于手指的逐帧位移，又小到不会漏掉被拆包的一格。
static constexpr float kWheelIdentifyPx = 30.0f;
// 单包最多兑换的格数，防止惯性尾包一次甩出一串。
static constexpr int kWheelMaxStepsPerPacket = 3;

// 判定一个触摸 DOWN 是否其实是"平台把鼠标转换出来的合成包"。
// 定义在 s_ptrOffset* 状态之后；只在触摸回调线程调用（持 s_touchStateMutex）。
static bool pointerDerivedDownAt(float px, float py);

// 镜像手势（= 物理左键按住）是否正在进行。只在触摸回调线程访问（持 s_touchStateMutex）。
//
// 2026-08-19：这里曾额外保存一份坐标基准，用于把合成触点的位置差分当作视角来源。
// 那条通道**有界**（坐标被 LockCursor 夹在窗口内）且**手感与 rawDelta 不同量纲**，
// 已按用户要求整体移除，只留下这个布尔量。它的唯一用途是诊断分桶：把 `AMCL_DRAG`
// 的样本分成 hold（左键按住）与 free（未按键）两桶，从而直接读出"按住期间 onMouse
// 到底有没有投递 rawDelta"——那是判断平台缺口是否已被消除的唯一判据。
static bool s_mirrorGestureActive = false;

// 手势状态必须在**每一个**会让"下一次 MOVE 与上一次不再属于同一段因果链"的边界上
// 复位：暂停/恢复、grab 翻转、surface 丢失、schema 替换、生命周期 cancel。
// 漏掉任何一个的后果是诊断分桶把两段手势混算，而不是视角跳变（视角已不由它驱动）。
static void resetMirrorGestureStateLocked() {
    s_mirrorGestureActive = false;
}

// 镜像手势是否正在进行（左键按住期间）。供 NAPI 侧的取证打点使用。
extern "C" int ohos_touch_mirror_gesture_active(void) {
    return s_mirrorGestureActive ? 1 : 0;
}

// 前向声明：触摸镜像分支（OnDispatchTouchEvent，本文件上方）需要在定义点之前
// 就能把左键交给同一套 source 仲裁与 legacy 边沿路由。二者的定义仍在下方原处，
// 这里只声明，避免为了顺序而搬动整块状态机。

// 左键边沿的通道选择统一走策略层：先登记"这条通道确实送来过左键边沿"（能力发现必须
// 发生在询问之前），再按 press/release **配对**申请。返回 false = 本次边沿应当被静默
// 丢弃（不是所有者，或者是一个没有配对按下的抬起）。
//
// 为什么左键要单独一套：见 input_channel_policy.h 的开头。简言之，左键是唯一同时出现
// 在三条通道上的按钮，而它的赢家在 API 24 与 API 26 上不同；用时间竞争仲裁会让
// press 与 release 归属不同通道，MC 侧表现为左键永久卡在按下态。
static bool acceptPhysicalButtonEdge(AmclInputChannel channel,
        uint64_t deviceId, uint32_t nativeButton, bool press) {
    if (nativeButton == 1u && press) amcl_input_policy_note_left_channel(channel);
    // 成因归属所需的两个快照，**必须在准入判定之前取**：成功的
    // `amcl_input_policy_left_begin` / `amcl_input_policy_left_end` 会改变按住态，
    // 事后再读就分不出"进来之前有没有按下在飞行"。两次都是 relaxed 原子读。
    // ⚠️ 只服务**诊断归属**，不参与准入 —— 准入由紧随的那一次原子操作独占决定
    // （极窄窗口下归属偏向保守那一桶，理由见 `amcl_input_policy_left_owner`）。
    const bool wasOwner = amcl_input_policy_left_owner() == channel;
    const bool wasHeld = amcl_input_policy_left_held();
    const bool accepted = press
        ? amcl_input_policy_button_begin(channel, deviceId, nativeButton)
        : amcl_input_policy_button_end(channel, deviceId, nativeButton);
    if (!accepted && nativeButton == 1u) {
        using amcl::input::census::Bump;
        using amcl::input::census::Channel;
        // 总数保留原语义（规范 §6.3 的判读规则建立在它上面）；四个细分之和必须等于它。
        Bump(Channel::LeftEdgeYielded);
        if (press) {
            // DOWN 只有两个成因，且 `amcl_input_policy_left_begin` 的实现顺序就是
            // 先判所有者再 CAS，所以这个分类与它逐一对应，不是猜的。
            Bump(wasOwner ? Channel::LeftEdgeYieldedDupDown
                          : Channel::LeftEdgeYieldedNotOwner);
        } else {
            // UP 失败的两个成因由"进来之前有没有按下在飞行"分开：无按下 = 抬起多于按下；
            // 有按下却 CAS 不掉 = 持有者是另一条通道，而那**按设计不可达**（见 census 那处）。
            Bump(wasHeld ? Channel::LeftEdgeYieldedOtherOwner
                         : Channel::LeftEdgeYieldedNoPress);
        }
    }
    return accepted;
}
/** 下游没有接纳 DOWN 时撤销策略预留；已聚合或重复的合法 DOWN 仍保留配对。 */
static void finishPhysicalButtonAdmission(AmclInputChannel channel,
        uint64_t deviceId, uint32_t nativeButton, bool press,
        AmclLegacyPhysicalOutcome outcome) {
    if (!press) return;
    if (outcome == AMCL_LEGACY_PHYSICAL_EMITTED ||
        outcome == AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE ||
        outcome == AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN ||
        outcome == AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED) return;
    amcl_input_policy_button_abort(channel, deviceId, nativeButton);
}
static AmclLegacyPhysicalOutcome routePhysicalButtonEventChecked(
    uint64_t deviceId, uint32_t nativeButton, int mappedButton,
    int action, int* routedMappedButton);

static void recordInvalidPhysicalWheel(const char* reason) {
    const uint64_t count = s_invalidPhysicalWheelCount.fetch_add(
        1u, std::memory_order_relaxed) + 1u;
    if (firstOrPowerOfTwo(count)) {
        AMCL_LOG_E(LOG_TAG,
            "Physical wheel sample rejected reason=%{public}s count=%{public}llu",
            reason, (unsigned long long)count);
    }
}

static amcl::input::SourceLedgerProxy& inputLedger() {
    static amcl::input::SourceLedgerProxy proxy;return proxy;
}

static OwnerToken nextOwnerToken() {
    return amcl::input::SourceNextNativeOwner();
}

static amcl::input::SourcePhysicalProxy& physicalEdgeRouter() {
    static amcl::input::SourcePhysicalProxy proxy;return proxy;
}

// 对已经解码的 ledger 输出执行一次 owner 转换。调用方负责输出取值合法（schema 编码经
// DecodeLegacySchemaOutputCode，按端释放直接用 registry 里保存的 Output）。
static bool routerOutputDirect(OwnerToken owner, const Output& output, int action) {
    std::lock_guard<std::recursive_mutex> transactionLock(
        s_inputTransactionMutex);
    // RELEASE remains legal while cancel is draining existing owners. Every
    // edge that could create/extend held state is fenced until the full reset
    // callback (not merely the physical-owner loop) has completed.
    if (action != GLFW_RELEASE && physicalEdgeRouter().ResetInProgress()) {
        return false;
    }
    // POD 单码事务内部先核实际预算并封 look，再提交候选；合法共持返回源接受成功。
    if (action == GLFW_PRESS) return inputLedger().acquire(owner, output);
    if (action == GLFW_REPEAT) return inputLedger().repeat(owner, output);
    if (action == GLFW_RELEASE) return inputLedger().release(owner, output);
    return false;
}

// schema 路径的持续输出：code 沿用“正数=键、负数=-(按钮+1)”的符号编码（schema 表、hotbar、WASD）。
// 越界编码直接拒绝且不触碰 ledger；发布校验已用同一判据拦截，这里是结构性的第二道。
static bool routerOutput(OwnerToken owner, int code, int action) {
    Output output{OutputKind::Key, 0};
    if (!amcl::input::DecodeLegacySchemaOutputCode(code, &output)) return false;
    return routerOutputDirect(owner, output, action);
}

using amcl::input::ExternalHeldAction;
using amcl::input::ExternalHeldEdgeRouter;

// 经 NAPI 下来的按端边沿只适配为 POD。neutral 复用原 registry×ledger 规则，平台
// 不借任何 source 容器/锁；proxy 本身为空对象，首次构造不创建来源 owner 或准入资格。
static amcl::input::SourceExternalProxy& externalHeldEdgeRouter() {
    static amcl::input::SourceExternalProxy proxy;return proxy;
}

// GLFW 动作码 → 按端持有动作。allowRepeat=false 用于鼠标按钮：它没有 REPEAT 语义。
// 未知动作返回 false，调用方据此直接拒绝，不分配 owner token、不触碰任何账本。
static bool externalHeldActionFromGlfw(int action, bool allowRepeat,
                                       ExternalHeldAction* out) {
    if (action == GLFW_PRESS) { *out = ExternalHeldAction::Press; return true; }
    if (action == GLFW_RELEASE) { *out = ExternalHeldAction::Release; return true; }
    if (action == GLFW_REPEAT && allowRepeat) { *out = ExternalHeldAction::Repeat; return true; }
    return false;
}

// 经 NAPI 下来的键输出。`source` 是**申报的端身份**，用于把持有记录按端隔离
// （见 ExternalHeldRecord 上方的说明）。多个端同时按住同一个键是**正确**的：
// ledger 按引用计数聚合，第一个 owner 发 PRESS、最后一个 owner 消失才发 RELEASE，
// 所以 MC 只看到一对边沿，而任一端还按着键就保持按下。
// 返回值表示本端持有变更是否已生效（含与其它端聚合、未发最终边沿）；false 表示本端记录
// 未改变，ArkTS 调用方据此保留自身状态以便重试。旧实现把“是否发出最终边沿”当作返回值，
// 跨端同键时会被误读成拒绝，因果见计划 §127。
// 越界键码在分配 owner 之前就拒绝（返回 false = 本端记录未改变），且直接构造键输出，
// 不再经过符号编码：负键码因此不会变成鼠标按钮，INT_MIN 也不会被取负。
static bool routerKey(AmclInputSource source, int key, int /*scancode*/,
                      int action, int /*mods*/) {
    if (!amcl::input::LegacyKeyCodeValid(key)) return false;
    std::lock_guard<std::recursive_mutex> transactionLock(s_inputTransactionMutex);
    // 复位围栏：cancel 正在清账时只放行 RELEASE，可能新建或延长持有的边沿一律拒绝。
    if (action != GLFW_RELEASE && physicalEdgeRouter().ResetInProgress()) {
        return false;
    }
    ExternalHeldAction edge = ExternalHeldAction::Release;
    if (!externalHeldActionFromGlfw(action, true, &edge)) return false;
    // 普通匿名 owner 在 neutral 候选中单调分配；平台不能先烧一枚 Native 专用租约。
    return amcl::input::ExternalHeldEdgeApplied(externalHeldEdgeRouter().Route(
        source, Output{OutputKind::Key, key}, edge, 0));
}

// 经 NAPI 下来的鼠标按钮输出，规则与返回值契约同 routerKey；鼠标按钮不接受 REPEAT。
// 按钮号按 GLFW 编号直接进 Output，越界（含负数，负数此前会被符号编码解释成键盘键）一律拒绝。
static bool routerMouse(AmclInputSource source, int button, int action,
                        int /*mods*/) {
    if (!amcl::input::LegacyMouseButtonValid(button)) return false;
    std::lock_guard<std::recursive_mutex> transactionLock(s_inputTransactionMutex);
    if (action != GLFW_RELEASE && physicalEdgeRouter().ResetInProgress()) {
        return false;
    }
    ExternalHeldAction edge = ExternalHeldAction::Release;
    if (!externalHeldActionFromGlfw(action, false, &edge)) return false;
    return amcl::input::ExternalHeldEdgeApplied(externalHeldEdgeRouter().Route(
        source, Output{OutputKind::Mouse, button}, edge, 0));
}

// 按端选择性释放：只放掉 `source` 这一端在 external 表里持有的输出，其余端不受影响。
//
// 这是"三端平级"在复位路径上的直接体现。此前唯一的释放手段是全局
// `s_externalHeld.clear() + releaseAll()`，于是拔掉一个手柄会连带放掉屏幕虚拟按键的
// 按下态；双手柄拔一个也会误放另一个。现在拔设备只影响它自己那个端。
//
// 释放走正常的 `routerOutput(RELEASE)`，因此 ledger 的引用计数语义不变：只有当这个
// 输出的最后一个 owner 消失时才真的向 MC 发 RELEASE。
extern "C" void ohos_release_input_source_held(int sourceValue) {
    // 越界值被 normalize 成 NONE，所以这里不再需要单独的合法性分支：
    // 释放 NONE 端是有意义的操作（平台手势的残留记录也该能被清）。
    const AmclInputSource source = normalizeInputSource(sourceValue);
    if(source==AMCL_INPUT_SOURCE_TOUCH_CONTROLS) {
        std::lock_guard<std::mutex> lock(s_touchStateMutex);
        // 单端释放也是菜单作用域退出；已经UP的tool/direct记录也必须作废，不能仅
        // 释放Native当前owner，再让旧PRESS/RELEASE流入新模态或新UI。
        inputBridge_retireTouchMenuScopeV1();
        releaseMenuToolControls();
    }
    if(source==AMCL_INPUT_SOURCE_GAMEPAD)amclMappedLookRetireAll();
    const size_t retired = amcl::input::SourceReleaseSource(source);
    // 刻意**不**在这里 note_reset：本函数是释放原语，记账由 ohos_note_input_source_reset
    // 负责（调用方 InputSourceRegistry 两个都调）。两处都记会让端级复位计数翻倍，
    // 而一个数值不可信的计数器比没有计数器更糟 —— 它会把下一轮判读带向错误方向。
    if (retired != 0u) {
        OH_LOG_INFO(LOG_APP,
                    "AMCL_INSRC released source=%{public}s held=%{public}zu",
                    amcl_input_source_name(source), retired);
    }
}

// ==================== 不变量自检（采样 + 日志） ====================
//
// 求值器是纯函数（platform/input_invariants.{h,cpp}，有 host test）；这里只负责
// 采样进程状态并在破坏时打一行 error。
//
// 为什么需要它：既有普查是**原始计数**，能回答"这条通道来没来"，但回答不了"账对不对"。
// 而本项目遇到的故障大多是**关系失衡**：抬起拿错 owner、某个 look 生产者没申报端、
// 滚轮绕过按端入口、复位后表没空 —— 全都不崩不报错，只在用户报告时才暴露。
// 这里把这些关系写成可判定的不变量，稳态零输出，破坏时立刻可见。
static void sampleInputInvariants(AmclInputInvariantSnapshot* out) {
    if (!out) return;
    *out = AmclInputInvariantSnapshot{};
    out->lookTotal = amcl::input::census::g_counters[static_cast<int>(
        amcl::input::census::Channel::LookApplied)].load(
            std::memory_order_relaxed);
    out->scrollTotal = amcl::input::census::g_counters[static_cast<int>(
        amcl::input::census::Channel::ScrollDelivered)].load(
            std::memory_order_relaxed);
    for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) {
        const AmclInputSource source = static_cast<AmclInputSource>(i);
        out->lookPerSource[i] = amcl_input_source_look_count(source);
        out->scrollPerSource[i] = amcl_input_source_scroll_count(source);
    }
    // 当前函数只观察持有事实，不执行取消，也不凭零快照宣布清理完成。
    // 菜单工具集合属于平台transaction；普通来源属于唯一neutral Source owner。保持
    // 原transaction→external锁序，在这一采样scope中只读取一次经过严格owner解析的
    // 现有POD快照，然后投影所有普通来源字段，避免每个字段重新解析descriptor/扫maps。
    // Source不可用时helper仍返回原零快照；菜单工具的独立加数继续按原事实保留。
    // 这里一致的是同一Source owner内的整份stats；menuTools与随后定向isHeld仍在
    // 各自原采样点观察，不能把跨owner/查询窗口宣传成全输入同一瞬间的原子快照。
    std::lock_guard<std::recursive_mutex> transaction(s_inputTransactionMutex);
    const MenuToolHeldSnapshot menuTools = menuToolHeldSnapshot();
    const AmclSourceSnapshotV1 sourceSnapshot = amcl::input::SourceSnapshot();
    out->physicalIdentityLive = sourceSnapshot.physical;
    out->ledgerOwnerLive = sourceSnapshot.owners + menuTools.live;
    out->ledgerOutputLive = sourceSnapshot.outputs;
    // 这至多三次是必要的定向输出交集查询，不是重复统计读取：现有POD的outputs总数
    // 不能回答LEFT/RIGHT/Shift是否已被common持有，必须保原isHeld判据以免同持双计。
    // 它们沿原实际查询获取资格，不从统计值推测，也不增公共ABI或跨scope缓存。
    const Output toolOutputs[3]{{OutputKind::Mouse,0},{OutputKind::Mouse,1},{OutputKind::Key,340}};
    for (unsigned i=0; i<3; ++i)
        if ((menuTools.outputMask & (1u << i)) && !inputLedger().isHeld(toolOutputs[i])) ++out->ledgerOutputLive;
    std::lock_guard<std::mutex> lock(s_externalInputMutex);
    out->maxSameSourceHeld = sourceSnapshot.maxSameSource;
    for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) {
        out->heldLive[i] = sourceSnapshot.held[i];
        out->heldAcquired[i] = sourceSnapshot.acquired[i];
        out->heldReleased[i] = sourceSnapshot.released[i];
    }
    const unsigned touch = AMCL_INPUT_SOURCE_TOUCH_CONTROLS;
    out->heldLive[touch] += menuTools.live;
    out->heldAcquired[touch] += menuTools.acquired;
    out->heldReleased[touch] += menuTools.released;
    out->maxSameSourceHeld = std::max(out->maxSameSourceHeld,menuTools.maxSameCode);
}

static unsigned sumPerSource(const unsigned* table) {
    unsigned total = 0u;
    for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) total += table[i];
    return total;
}

// 六层持有关系里此前**一个数都读不出来**的那两层（2026-09-01）。
//
// 规范 §二 那张表有六层，而在这一行之前产品日志只能看到第 1b 层（`AMCL_INSRC held ...`）。
// 于是"卡键有六个可能宿主"这句话在真机判读时**只有一个宿主是可观测的** —— 剩下五层里，
// 第 0 层靠 `AMCL_INPOLICY owner=` 间接可见，第 3 层靠 aggregate 的行为间接可见，
// 而**第 1a 层（物理键鼠端唯一的持有账本）与第 2 层（ledger）完全不可见**。
//
// 判读方式（三条，按排查频度排序）：
//   · `phys>0` 而用户报"某个物理键卡住" ⇒ 第 1a 层有残留身份，查 `LegacyPhysicalEdgeRouter`
//     的 `Reset` 是否被跳过（`AMCL_LEGACY_PHYSICAL_RESET_IN_PROGRESS` 计数应同期上升）；
//   · `sameSrcMax>1` ⇒ **规范 §3.3 那条幽灵 owner 的直接特征**。它在 `heldBalance`
//     与 ledger 引用计数上都是自洽的，所以此前只能靠用户报"这个键恒按下且没反应"。
//     ⚠️ 它刻意**不是**告警位，理由见 `external_held_registry.h`；看到 >1 请先查 §3.3
//     的四步因果，不要直接当 bug 提交；
//   · `owners < phys + Σheld` ⇒ ledger 与上游失步，`AMCL_INV_LEDGER_COVERS_OWNERS`
//     只在 ledger **归零**那一档才报（蕴含式无误报的代价），中间档只能靠这一行看出来。
//
// ⚠️ 参数是一份**已经采好**的快照，本函数自己**不取任何锁** —— 采样的锁序约束写在
// `sampleInputInvariants` 里，在这里重新取一遍会把那条约束复制成两份。
static void logHeldLayerState(const AmclInputInvariantSnapshot& s) {
    OH_LOG_INFO(LOG_APP,
                "AMCL_HELDLAYERS phys=%{public}u extLive=%{public}u "
                "sameSrcMax=%{public}u ledgerOwners=%{public}u "
                "ledgerOutputs=%{public}u",
                s.physicalIdentityLive, sumPerSource(s.heldLive),
                s.maxSameSourceHeld, s.ledgerOwnerLive, s.ledgerOutputLive);
}

// ==================== 端级状态的**周期性**输出 ====================
//
// 存在理由是一次真机判读的失败（2026-08-20，手机 3AP0224B08027377）：
// `AMCL_INSRC` 的两行原先**只在 ohos_cancel_all_input 里打**，而 cancel 集中发生在
// 会话的开头与结尾。那份日志里最后一条 AMCL_INSRC 在 20:52:38，玩家真正操作的
// 20:53:13–20:54:31 整段**一行按端计数都没有留下** —— looks/scrolls 全零不是因为账错了，
// 而是因为打印时机早于操作。于是按端账目在"正在使用"这个唯一重要的时刻是不可观测的，
// 连"平台手势有没有进持有账目"这条自定判据都无法执行。
//
// 修法刻意不新开线程/定时器：挂在既有的 250ms 心跳（ohos_input_invariant_tick）上，
// 用两道闸控制音量 ——
//   ① **变化闸**：指纹（累计量之和）不变就不打。空闲时零输出，不刷屏。
//   ② **节流闸**：最短 5 秒。持续操作时每 5 秒一组，足够看趋势又不淹没普查行。
// cancel 路径仍**无条件**打（那一刻的快照有独立价值），并顺手推进节流状态，
// 避免紧随其后的心跳重复一组。
static std::mutex s_sourceStateLogMutex;
static int64_t s_sourceStateLastLogNs = 0;
static unsigned s_sourceStateFingerprint = 0u;
static bool s_sourceStateLoggedOnce = false;

static constexpr int64_t SOURCE_STATE_LOG_MIN_INTERVAL_NS = 5000000000LL;  // 5s

// 指纹只用**累计且单调不减**的量（复位次数 / look / scroll / acquired / released），
// 刻意不含 heldLive：live 是"当前按住几个"，按一下键就回到原值，用它做指纹会漏报
// "按了一串键但每次都松开"这种最常见的活动模式。
static unsigned sourceStateFingerprint(const AmclInputInvariantSnapshot& s) {
    unsigned fp = s.lookTotal + s.scrollTotal;
    fp += sumPerSource(s.heldAcquired) + sumPerSource(s.heldReleased);
    for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) {
        fp += amcl_input_source_reset_count(static_cast<AmclInputSource>(i));
    }
    return fp;
}

// 无条件输出之后调用，把节流基准推到现在。给 cancel 路径用。
static void noteSourceStateLogged(const AmclInputInvariantSnapshot& s) {
    std::lock_guard<std::mutex> lock(s_sourceStateLogMutex);
    s_sourceStateLastLogNs = nowMonotonicNs();
    s_sourceStateFingerprint = sourceStateFingerprint(s);
    s_sourceStateLoggedOnce = true;
}

// 两道闸都放行时输出一组端级状态。调用方必须**不持有** s_externalInputMutex
// （amcl_input_source_log_reset_state 不需要它，ohos_log_external_held_state 会自己取）。
static void maybeLogSourceStatePeriodic(const AmclInputInvariantSnapshot& s) {
    const unsigned fp = sourceStateFingerprint(s);
    {
        std::lock_guard<std::mutex> lock(s_sourceStateLogMutex);
        const int64_t now = nowMonotonicNs();
        // 首次：无条件放行一组基线，否则"从进程启动到第一次活动"之间无从判断计数器是否在动。
        if (s_sourceStateLoggedOnce) {
            if (fp == s_sourceStateFingerprint) return;
            if (now - s_sourceStateLastLogNs < SOURCE_STATE_LOG_MIN_INTERVAL_NS) return;
        }
        s_sourceStateLastLogNs = now;
        s_sourceStateFingerprint = fp;
        s_sourceStateLoggedOnce = true;
    }
    amcl_input_source_log_reset_state();
    ohos_log_external_held_state();
    logHeldLayerState(s);
}

// 只在**连续两次采样都看到同一条破坏**时才报。
//
// 依据是这些计数器的性质：它们全是**累计且单调不减**的，所以一条真实的破坏
// （例如某个 look 生产者漏了端标注）一旦发生就**永久成立**，下一次采样必然还在。
// 反过来，采样本身不是原子的 —— `census::Bump(LookApplied)` 与
// `amcl_input_source_note_look()` 是两次独立的原子自增，中间存在一个窗口；
// 更糟的是 `Bump` 每秒会顺手执行一次 `Flush()`（几十路 snprintf + 一次 hilog），
// 把那个窗口从纳秒级拉到微秒级。而本函数跑在 ArkUI 主线程、look 跑在 XComponent
// 回调线程，是真并发。于是"总数已加、端计数未加"会被采到，产生**瞬时假破坏**。
//
// 为什么必须消掉假报警而不是容忍：一旦 AMCL_INVARIANT 出现过假阳性，下一轮判读就会
// 把它当噪声忽略掉，这套机制的全部价值随即归零 —— 而"计数器不可信比没有计数器更糟"
// 这条教训这个项目已经付过一次学费。用"连续两次"过滤，代价是把发现延迟从 250ms 变成
// 500ms，对一个永久性破坏毫无影响。
static void runInputInvariantTick() {
    AmclInputInvariantSnapshot snapshot{};
    sampleInputInvariants(&snapshot);
    // 周期性端级输出借用同一次采样。放在求值之前是刻意的：不变量破坏时那一行 error 需要
    // 紧邻的 AMCL_INSRC 做上下文，先打状态再打告警，判读顺序与因果顺序一致。
    // 注意 sampleInputInvariants 的 lock_guard 是函数作用域，此处 s_externalInputMutex
    // 已释放，下面这个会重新取它的调用不会自死锁（那把锁非递归）。
    maybeLogSourceStatePeriodic(snapshot);
    const uint32_t observed = amcl_input_invariants_evaluate(&snapshot);

    // 滞回逻辑抽在 input_invariants.cpp（纯函数，有 host test）。这里只提供状态与串行化：
    // tick 的两个调用点（250ms 心跳在 ArkUI 主线程、cancel 末尾在任意线程）可能并发，
    // 用一把小锁保证滞回状态的读改写是原子的 —— 用两个独立 atomic 做不到这一点
    // （旧版就是那样，双线程同时 tick 时会丢或重复一次报告）。
    static std::mutex s_invariantMutex;
    static AmclInputInvariantHysteresis s_hysteresis{0u, 0u};
    uint32_t fresh = 0u;
    {
        std::lock_guard<std::mutex> lock(s_invariantMutex);
        fresh = amcl_input_invariants_confirm(&s_hysteresis, observed);
    }
    if (fresh == 0u) return;

    char names[128];
    size_t used = 0u;
    for (uint32_t bit = 1u; bit <= AMCL_INV_ALL_BITS; bit <<= 1) {
        if ((fresh & bit) == 0u) continue;
        const int written = snprintf(names + used, sizeof(names) - used, " %s",
                                     amcl_input_invariant_name(bit));
        if (written <= 0 ||
            used + static_cast<size_t>(written) >= sizeof(names)) {
            break;
        }
        used += static_cast<size_t>(written);
    }
    names[used] = '\0';
    // 打全 acquired/released 而不只打 live：`heldBalance` 是唯一需要这三个数才能定位的
    // 位，只打 live 等于报了一个无法追查的警报。
    AMCL_LOG_E(LOG_TAG,
                 "AMCL_INVARIANT broken=0x%{public}x%{public}s | "
                 "look total=%{public}u sum=%{public}u | "
                 "scroll total=%{public}u sum=%{public}u | "
                 "held live=%{public}u acq=%{public}u rel=%{public}u | "
                 "live touch=%{public}u pad=%{public}u kbm=%{public}u "
                 "gesture=%{public}u untagged=%{public}u",
                 fresh, names,
                 snapshot.lookTotal, sumPerSource(snapshot.lookPerSource),
                 snapshot.scrollTotal, sumPerSource(snapshot.scrollPerSource),
                 sumPerSource(snapshot.heldLive),
                 sumPerSource(snapshot.heldAcquired),
                 sumPerSource(snapshot.heldReleased),
                 snapshot.heldLive[AMCL_INPUT_SOURCE_TOUCH_CONTROLS],
                 snapshot.heldLive[AMCL_INPUT_SOURCE_GAMEPAD],
                 snapshot.heldLive[AMCL_INPUT_SOURCE_PHYSICAL_KBM],
                 snapshot.heldLive[AMCL_INPUT_SOURCE_PLATFORM_GESTURE],
                 snapshot.heldLive[AMCL_INPUT_SOURCE_NONE]);
}

static void reconcileLegacyRingDiscontinuity();   // 定义在 GrabEpochCoordinator 之后

// 250ms 心跳入口（NAPI InputInvariantTick，ArkUI 主线程，不持任何输入锁）。先对账 ring 不连续
// epoch 再采样：纯触摸 + 手柄的会话里可能很久没有别的入口被调用，心跳是收敛的兜底。
// cancel 末尾调用 runInputInvariantTick 而不经这里：那里已持有 touchState，而且可能跑在
// MC 线程（窗口重建经 bridge 回调进来），在那里对账会自锁或落到消费者线程上。
extern "C" void ohos_input_invariant_tick(void) {
    reconcileLegacyRingDiscontinuity();
    runInputInvariantTick();
}

// 端级持有账目的定期可读输出。
//
// 存在理由是一条我自己定的判据没达成：`AMCL_INSRC` 的 resets/looks/scrolls 三段里
// `gesture` 栏**结构性恒零** —— 平台手势不产生 look、不产生 scroll，也不参与按端复位
// 遍历，所以那三段永远看不到返回键。而 `input_source.h` 里写着"各栏都必须有生产者，
// 否则恒零无法区分'没漏'与'没记'"。
//
// 持有账目正是它唯一留下痕迹的地方（返回键的 ESC 是一对进出成对的 tap）。把它打出来
// 同时解决第二件事：`heldBalance` 破坏时需要 acquired/released 才能定位。
extern "C" void ohos_log_external_held_state(void) {
    unsigned live[AMCL_INPUT_SOURCE_COUNT] = {};
    unsigned acquired[AMCL_INPUT_SOURCE_COUNT] = {};
    unsigned released[AMCL_INPUT_SOURCE_COUNT] = {};
    // 先取panel完整源快照，再取更内层external，保持transaction→external锁序。
    const MenuToolHeldSnapshot menuTools = menuToolHeldSnapshot();
    {
        std::lock_guard<std::mutex> lock(s_externalInputMutex);
        // 保原采样锁与菜单工具加数，仅在本scope取一次真实Source POD。五来源的live/
        // acquired/released来自同一份快照，缺资格仍沿原零值语义；日志不代替cancel回执。
        // 此一致性仅属于Source owner；此前菜单快照与此处Source读取之间仍有原观测窗口。
        const AmclSourceSnapshotV1 sourceSnapshot = amcl::input::SourceSnapshot();
        for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) {
            live[i] = sourceSnapshot.held[i];
            acquired[i] = sourceSnapshot.acquired[i];
            released[i] = sourceSnapshot.released[i];
        }
    }
    live[AMCL_INPUT_SOURCE_TOUCH_CONTROLS] += menuTools.live;
    acquired[AMCL_INPUT_SOURCE_TOUCH_CONTROLS] += menuTools.acquired;
    released[AMCL_INPUT_SOURCE_TOUCH_CONTROLS] += menuTools.released;
    OH_LOG_INFO(LOG_APP,
                "AMCL_INSRC held live[t/p/k/g/u]=%{public}u/%{public}u/%{public}u/"
                "%{public}u/%{public}u acq=%{public}u/%{public}u/%{public}u/"
                "%{public}u/%{public}u rel=%{public}u/%{public}u/%{public}u/"
                "%{public}u/%{public}u",
                live[AMCL_INPUT_SOURCE_TOUCH_CONTROLS],
                live[AMCL_INPUT_SOURCE_GAMEPAD],
                live[AMCL_INPUT_SOURCE_PHYSICAL_KBM],
                live[AMCL_INPUT_SOURCE_PLATFORM_GESTURE],
                live[AMCL_INPUT_SOURCE_NONE],
                acquired[AMCL_INPUT_SOURCE_TOUCH_CONTROLS],
                acquired[AMCL_INPUT_SOURCE_GAMEPAD],
                acquired[AMCL_INPUT_SOURCE_PHYSICAL_KBM],
                acquired[AMCL_INPUT_SOURCE_PLATFORM_GESTURE],
                acquired[AMCL_INPUT_SOURCE_NONE],
                released[AMCL_INPUT_SOURCE_TOUCH_CONTROLS],
                released[AMCL_INPUT_SOURCE_GAMEPAD],
                released[AMCL_INPUT_SOURCE_PHYSICAL_KBM],
                released[AMCL_INPUT_SOURCE_PLATFORM_GESTURE],
                released[AMCL_INPUT_SOURCE_NONE]);
}

// ArkTS 侧的端（手柄状态机、触控端的 ArkTS 兼容态）在自己复位之后调用这里记一笔。
// native 的 cancelAllInput 触达不到那些状态，缺了这条记账，端级复位日志里手柄那栏恒为零，
// 而恒零无法区分"没漏"与"没记"。
extern "C" void ohos_note_input_source_reset(int sourceValue) {
    amcl_input_source_note_reset(normalizeInputSource(sourceValue));
}

// 滚轮不进 owner 域（无持续按下态），但**端身份是必填的**：它是"scrollOut 等于各端之和"
// 这条不变量的唯一来源。把 note_scroll 放在这里而不是各调用点，是为了让等式**结构性**成立
// —— 只要走了 routerScroll 就一定被按端计过一次，不可能出现"新增一个滚轮生产者忘了打点"。
// 本进程内 AXIS_PAN 通道产出过的物理滚轮格数（含被拒的那一格）。计划 §90.8。
static std::atomic<uint64_t> s_axisPanPhysicalDetentCount{0u};

static bool routerScroll(AmclInputSource source, int xoffset, int yoffset,
                         bool gateAccepted) {
    amcl::input::census::Bump(amcl::input::census::Channel::ScrollDelivered);
    amcl_input_source_note_scroll(source);
    // 本进程**第一格** AXIS_PAN 物理滚轮必须拒掉。它挡的是一个幻影输入（计划 §90.8）。
    //
    // 成因是 `PickOwner` 在会话起点的结构性竞态：第一格滚轮时 native AXIS 还没送过样本
    // ⇒ 首选通道尚未被登记 ⇒ `AMCL_INPUT_CHANNEL_AXIS_PAN` **合法**拿到约 1ms 所有权并发出
    // 一格；1ms 后 native AXIS 夺权，**同一个物理格**又发一格 ⇒ 会话第一格走两格。
    // ⚠️ 它是 §90.2 修好累加器基准之后**新出现**的：此前"抢权窗不会误发"靠的是首个 update
    // `delta` 恒为 0，而那是基准取错的副作用，不是设计。
    //
    // ⚠️ **判据刻意与平面无关。** 上一版限定了 `PlatformInputPhysicalRouteUsesTyped()`，
    // 那是错的 —— 竞态在 `PickOwner` 里，与走哪条平面无关，**legacy 出货包同样发生**
    // （用户实测：legacy 轮 `wheel owner=axisPan → nativeAxis` 而 refused 计数 0 条）。
    // ⇒ 那个基准修复曾经把这个回归带进出货路径，本条把它修回去。
    //
    // 为什么只拒**第一格**而不是全部：在 AXIS_PAN 是唯一载体的设备上全拒等于滚轮全死。
    // 一旦 native AXIS 送过样本，能力位图单调，AXIS_PAN 此后永远赢不了 ⇒ 拒一次就够。
    // 代价上界因此是"每进程最多丢一格"，且只发生在 AXIS_PAN 真的赢过的设备上。
    // ⭐ 取"丢一格"而不是"多一格"是刻意的：游戏里**幻影输入比漏输入贵**（误切物品栏）。
    //
    // 判据用"此刻有一个轴驱动 Pan 正在进行"（`s_axisPanActiveSinceNs`）—— 那个窗本来就是
    // 为"合成触摸包与真手指不可区分"建的，复用它而不是新造标志。刻意**不用**
    // `axisPanLookSuppressed()`：它带 150ms 惯性尾，那条尾巴是给**空白 look** 的，语义不同。
    if (source == AMCL_INPUT_SOURCE_PHYSICAL_KBM &&
        s_axisPanActiveSinceNs.load(std::memory_order_acquire) != 0) {
        const uint64_t count = s_axisPanPhysicalDetentCount.fetch_add(
                                   1u, std::memory_order_relaxed) + 1u;
        if (count == 1u) {
            AMCL_LOG_W(LOG_TAG,
                "AMCL_WHEEL refused the first AXIS_PAN detent of this process "
                "(phantom first-notch from the PickOwner startup race; "
                "see plan section 90.8)");
            return false;
        }
    }
    std::lock_guard<std::recursive_mutex> transactionLock(s_inputTransactionMutex);
    if (physicalEdgeRouter().ResetInProgress()) return false;
    // ⭐ 平面分叉点。**刻意放在这里**而不是放在各个调用点上：普查
    // （`ScrollDelivered` + `amcl_input_source_note_scroll`）、幻影首格守卫与
    // `ResetInProgress` 三样都在上面，放到调用点会让 typed 那条把三样一起绕过 ——
    // 而"守卫连同兜底一起消失"正是 1000530 付过一次学费的形状（那次是修好累加器基准
    // 之后抢权窗真的开始误发幻影格）。
    //
    // ⚠️ 只有 `AMCL_INPUT_SOURCE_PHYSICAL_KBM` 走 typed：虚拟滚轮条
    // （`AMCL_INPUT_SOURCE_TOUCH_CONTROLS`）与手柄 L1/R1（`AMCL_INPUT_SOURCE_GAMEPAD`）
    // 按架构留在 legacy 兼容 ring 上，直到它们自己那一批迁移（ingress 头文件原话）。
    // 本进程内 `PlatformInputPhysicalRouteUsesTyped()` 不可变，所以这里读一次、
    // 事务里再读一次不构成竞态。
    if (source == AMCL_INPUT_SOURCE_PHYSICAL_KBM &&
        amcl::input::PlatformInputPhysicalRouteUsesTyped()) {
        if (xoffset != 0) {
            // 横轴 fail closed，与两条平面的既有判定一致（本 SDK 无经验证的横向 getter）。
            recordInvalidPhysicalWheel("arkts-horizontal-axis");
            return false;
        }
        // ⚠️ ArkTS 两条通道送来的是**已分好格**的 GLFW yoffset（只有方向），而 typed
        // 平面入口吃的是平台侧样本值并会再分一次格。`PlatformSampleFromGlfwScroll`
        // 是那一步的逆，恒等式由 host 断言钉住 —— 直接把 yoffset 当样本值传会**符号
        // 反过来**，而"滚轮方向相反"这条本仓已经真机否证过一次（计划 §83）。
        const double platformSample = amcl::input::PlatformSampleFromGlfwScroll(
            yoffset, amcl::input::kGlfwPhysicalWheelPolicy);
        // route 传 nullptr：typedRoute 为真时事务在读它之前就已返回。
        const AmclLegacyPhysicalOutcome outcome =
            amcl::input::PlatformInputPhysicalWheelTransaction(
                0.0, platformSample, true, gateAccepted, nullptr);
        return outcome == AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED;
    }
    // 普通world滚轮也封已知look前缀；运输容量失败不让滚轮越过未交付视角。
    if(!inputBridge_beginLookActionV1())return false;
    sendEvent(EVENT_TYPE_SCROLL, xoffset, yoffset, 0, 0);
    inputBridge_endLookActionV1();
    return true;
}

// ⚠️ 这里曾是 "mouseSynth tap fallback" 子系统：一套把"鼠标合成的触摸手势"延迟 300ms
// 识别成左键点击的状态机，外加一个常驻 deadline worker、一个 mutex + condvar，
// 并把 s_grabAnnouncementMutex 拉进全局锁序。**已整体删除。**
//
// 删除依据：它的候选起点要求 `source == kMouseSynth`，而 OnDispatchTouchEvent 在把包判为
// mirrorPacket 之后就 return 了，那个分支根本到不了识别器；同时左键早已改由
// input_channel_policy 在三条通道里选一条**立即透传**（延迟 300ms 正是用户当初反馈的
// "按下有迟滞"，而且只在 UP 后发一次 press+release，根本没法实现"按住左键连续挖矿"）。
// 于是它成了一条既不可达、又持续占着线程与锁序的子系统。
//
// 分类器 `ClassifyMouseSynthTouchSource` 与 `MouseSynthTouchAction` 是仍在用的部分，
// 已按职责拆到 platform/mouse_synth_touch_source.{h,cpp}。
using amcl::input::MouseSynthTouchAction;
using amcl::input::MouseSynthTouchSource;

static void schemaApplyWasd(bool w, bool a, bool s, bool d);   // 前置声明（定义在下方）

// schema 按钮输出必须携带稳定 owner；组合键作为同一 owner 的多个 Output 获取/释放。
/** schema锁内冻结反馈元组，只读取touch复位域的原子快照，绝不反向取得touch锁。 */
static void schemaFireHaptic(int strength, const char* controlId) {
    amcl_fire_haptic_tagged(strength,controlId,s_schemaGeneration,
        amcl::input::PlatformInputResetDomains().touch,schemaNowNs(),s_touchPublicationGrabEpoch);
}

static bool schemaDispatchButton(const AmclCtrlEntry& e, OwnerToken owner, int action) {
    const int cap = (int)(sizeof(e.keys) / sizeof(e.keys[0]));
    const int n = (e.keyCount > 0 && e.keyCount <= cap) ? e.keyCount : 0;
    Output outputs[6]{};uint32_t count=0;
    if(n>6)return false;
    for(int i=0;i<(n?n:1);++i){Output value{};
        if(!amcl::input::DecodeLegacySchemaOutputCode(n?e.keys[i]:e.keyOrMouse,&value))return false;
        bool duplicate=false;for(uint32_t j=0;j<count;++j)duplicate|=outputs[j].kind==value.kind&&outputs[j].code==value.code;
        if(!duplicate)outputs[count++]=value;
    }
    // 一次六码候选、一份真实 ring 预算、一批 look/action。PRESS 拒绝不改 button/haptic。
    // terminal 按原 owner 输出集合退休，运输暂不可用时 neutral 独立记录未交付末松。
    if(!amcl::input::SourceOwnedGroup(owner,outputs,count,action))return false;
    amcl_fire_button_pressed(e.id, action == GLFW_PRESS ? 1 : 0);
    // 键/鼠标输出必须留在 native owner ledger；这里只把低频触觉请求投递回 UI。
    // haptic 是 schema 快照的一部分，因此布局切换不会让活动 finger 读取到新 profile 的开关。
    if (action == GLFW_PRESS && e.haptic != 0) schemaFireHaptic(8,e.id);
    return true;
}

static void schemaWakeDeadlineWorker();

/** 普通 release 暂拒时保留槽位；显式退休允许中立端保存 Deferred 末松，避免丢掉清理责任。 */
static void schemaRetireGroupUiOwnersLocked(bool all = false) {
    for (auto& owner : s_groupUiOwners) {
        if (owner.token == 0 || (!all && s_touchGroups.Visible(owner.control))) continue;
        AmclSourceRequestV1 request{}; request.operation = AMCL_SOURCE_RELEASE;
        request.owner = owner.token; request.flags = AMCL_SOURCE_ALLOW_RETIRE;
        if (amcl::input::SourceTransaction(request).accepted) owner = GroupUiOwner{};
    }
}

/** 只在离散认领/命令边界定位 ID；持续 MOVE 使用 state 中冻结的下标和资格。 */
static int schemaGroupControlIndex(const char* id) {
    if (!s_touchGroups.Enabled() || !id) return -1;
    for (size_t i = 0; i < s_schema.size(); ++i) if (std::strcmp(id, s_schema[i].id) == 0) return static_cast<int>(i);
    return -1;
}

static bool schemaUsesGroupPhases(const SchemaButtonRuntime& state) {
    return state.groupControl >= 0 && static_cast<size_t>(state.groupControl) < s_touchGroups.Definition().controls.size() &&
        s_touchGroups.Definition().controls[state.groupControl].phases;
}

/** 组合动作预留先于键输出，所有目标冻结后进入同一 FIFO；空 keys 不制造假 owner。 */
static bool schemaGroupPhase(SchemaButtonRuntime& state, int phase, uint64_t producer = 1, uint64_t sequence = 0) {
    if (!schemaUsesGroupPhases(state) || phase < 0 || phase >= 4 ||
        !s_touchGroups.Visible(state.groupControl) || s_touchGroups.Epoch(state.groupControl) != state.groupEligibility) return false;
    const auto& binding = s_touchGroups.Definition().controls[state.groupControl].bindings[phase];
    if (!binding.Active()) return true;
    if (sequence == 0) {
        if (s_touchGroupSequence == UINT64_MAX) return false;
        sequence = ++s_touchGroupSequence;
    }
    amcl::input::TouchGroupCommand command;
    command.producer=producer; command.sequence=sequence; command.control=state.groupControl; command.eligibility=state.groupEligibility;
    // 先分配并冻结队列项，分配异常在输出前终止；按键拒绝仍保留同命令的拒绝回执。
    try { command.actions=binding.actions; if (!s_touchGroups.Accept(command)) return false; } catch (...) { return false; }
    bool accepted = true;
    if (!binding.keys.empty()) {
        AmclCtrlEntry output = state.control;
        output.keyCount = static_cast<int>(binding.keys.size()); output.keyOrMouse = binding.keys[0];
        std::copy(binding.keys.begin(), binding.keys.end(), output.keys);
        const bool release = binding.autoKeep && state.phaseHeld[phase];
        if (!release) state.phaseOwners[phase] = nextOwnerToken();
        accepted = state.phaseOwners[phase] != 0 && schemaDispatchButton(output, state.phaseOwners[phase], release ? GLFW_RELEASE : GLFW_PRESS);
        if (accepted) {
            state.phaseHeld[phase] = !release;
            if (!binding.autoKeep && phase >= 2) {
                (void)schemaDispatchButton(output, state.phaseOwners[phase], GLFW_RELEASE);
                state.phaseHeld[phase] = false;
            }
        }
    }
    // 四阶段共用同一按钮外观。某个click脉冲或autoKeep解锁结束，不代表其它阶段也已松开；
    // 覆盖通用单owner派发的反馈，以此按钮仍持有的阶段并集作为最终高亮事实。
    amcl_fire_button_pressed(state.control.id,
        std::any_of(state.phaseHeld.begin(), state.phaseHeld.end(), [](bool held) { return held; }) ? 1 : 0);
    if (!accepted) s_touchGroups.RejectReserved(command);
    return accepted;
}

/** 取消、隐藏或真正绑定失效都精确退休这四个 owner，期限随后由原 state 清理。 */
static void schemaRetireGroupPhaseOwners(SchemaButtonRuntime& state, const std::set<OwnerToken>* keep = nullptr) {
    bool hadPhaseOwner = false, keptHeld = false;
    for (size_t phase = 0; phase < state.phaseOwners.size(); ++phase) {
        hadPhaseOwner |= state.phaseOwners[phase] != 0;
        keptHeld |= state.phaseHeld[phase] && keep && keep->count(state.phaseOwners[phase]) != 0;
        if (state.phaseOwners[phase] != 0 && (!keep || keep->count(state.phaseOwners[phase]) == 0))
            inputLedger().releaseOwner(state.phaseOwners[phase]);
        state.phaseOwners[phase] = 0; state.phaseHeld[phase] = false;
    }
    // 定向退休也必须结束本控件的视觉；保留到真实UP的carried owner仍保持按下反馈。
    // 旧解释器没有阶段owner，不能在这里抢先清掉它独立处理的高亮。
    if (hadPhaseOwner) amcl_fire_button_pressed(state.control.id, keptHeld ? 1 : 0);
}

/** 正常 UP 的保持释放与取消分开：只有正常合格 UP 才触发 click/doubleClick。 */
static void schemaGroupLastUp(SchemaButtonRuntime& state, bool cancelled) {
    if (!schemaUsesGroupPhases(state)) return;
    const auto& definition = s_touchGroups.Definition().controls[state.groupControl];
    if (cancelled) { schemaRetireGroupPhaseOwners(state); state.lastTapNs = 0; }
    else {
        for (size_t phase = 0; phase < 2; ++phase) {
            if (!definition.bindings[phase].autoKeep && state.phaseHeld[phase]) {
                inputLedger().releaseOwner(state.phaseOwners[phase]); state.phaseHeld[phase] = false;
            }
        }
        const int64_t now = schemaNowNs();
        const int64_t clickLimit = definition.fcl ? 100000000LL : SCHEMA_DOUBLETAP_NS;
        const int64_t doubleLimit = definition.fcl ? 400000000LL : SCHEMA_DOUBLETAP_NS;
        if (!state.groupMoved && !state.longFired && now >= state.groupDownNs && now-state.groupDownNs <= clickLimit) {
            (void)schemaGroupPhase(state, 2);
            if (state.lastTapNs > 0 && now-state.lastTapNs < doubleLimit) {
                (void)schemaGroupPhase(state, 3); state.lastTapNs = 0;
            } else state.lastTapNs = now;
        }
    }
    // 直接退休ledger只处理输入所有权，不自动发UI反馈；普通UP和Cancel均补齐聚合末态。
    amcl_fire_button_pressed(state.control.id,
        std::any_of(state.phaseHeld.begin(), state.phaseHeld.end(), [](bool held) { return held; }) ? 1 : 0);
    state.longDeadlineNs = 0; state.longFired = false;
}

static void schemaTriggerFirstDown(SchemaButtonRuntime& state) {
    const AmclCtrlEntry& e = state.control;
    const long long now = schemaNowNs();
    state.groupControl = schemaGroupControlIndex(e.id);
    state.groupEligibility = state.groupControl < 0 ? 0 : s_touchGroups.Epoch(state.groupControl);
    if (schemaUsesGroupPhases(state)) {
        state.groupDownNs = now; state.groupMoved = false; state.longFired = false;
        const auto& definition = s_touchGroups.Definition().controls[state.groupControl];
        if (definition.bindings[1].Active()) {
            state.longDeadlineNs = now + (definition.fcl ? 400000000LL : SCHEMA_LONGPRESS_NS);
            schemaWakeDeadlineWorker();
        }
        (void)schemaGroupPhase(state, 0);
        return;
    }
    switch (e.trigger) {
        case 1: // toggle
            if (state.outputDown) {
                if(schemaDispatchButton(e,state.owner,GLFW_RELEASE)){state.outputDown=false;state.toggled=false;}
            } else {
                state.owner = nextOwnerToken();
                if(schemaDispatchButton(e,state.owner,GLFW_PRESS)){state.outputDown=true;state.toggled=true;}
            }
            break;
        case 2: // double tap
            if (state.lastTapNs != 0 && now - state.lastTapNs < SCHEMA_DOUBLETAP_NS) {
                const OwnerToken tapOwner = nextOwnerToken();
                if(schemaDispatchButton(e,tapOwner,GLFW_PRESS))(void)schemaDispatchButton(e,tapOwner,GLFW_RELEASE);
                state.lastTapNs = 0;
            } else {
                state.lastTapNs = now;
            }
            break;
        case 3: // long press：登记单调时钟 deadline，并唤醒唯一 worker；不依赖后续 MOVE/UP 才触发
            state.owner = nextOwnerToken();
            state.longDeadlineNs = now + SCHEMA_LONGPRESS_NS;
            state.longFired = false;
            schemaWakeDeadlineWorker();
            break;
        default: // press
            state.owner = nextOwnerToken();
            state.outputDown=schemaDispatchButton(e,state.owner,GLFW_PRESS);
            break;
    }
}

static void schemaTriggerLastUp(SchemaButtonRuntime& state, bool cancelled = false) {
    if (schemaUsesGroupPhases(state)) { schemaGroupLastUp(state, cancelled); return; }
    const AmclCtrlEntry& e = state.control;
    if (e.trigger == 0 && state.outputDown) {
        if(schemaDispatchButton(e,state.owner,GLFW_RELEASE))state.outputDown=false;
    } else if (e.trigger == 3) {
        if (state.longFired && state.outputDown) {
            if(schemaDispatchButton(e,state.owner,GLFW_RELEASE))state.outputDown=false;
        }
        state.longFired = false;
        state.longDeadlineNs = 0;
    }
}

/** 菜单策略的唯一平台出口。源点、移动和终点进入共同顺序，不在平台端补点或等待图形帧。 */
static void emitMenuInteraction(amcl::input::MenuTouchAction action, double x, double y) {
    using amcl::input::MenuTouchAction;
    if (action == MenuTouchAction::Scroll) {
        if(emitScopedMenuScroll(static_cast<int>(x),static_cast<int>(y),false)) {
            ++s_touchGuide.scroll; s_touchGuide.scrollAmount+=y;
        }
        return;
    }
    const bool relative=action==MenuTouchAction::RelativeBegin || action==MenuTouchAction::RelativePosition ||
        action==MenuTouchAction::RelativeDown || action==MenuTouchAction::RelativeUp ||
        action==MenuTouchAction::RelativeEnd || action==MenuTouchAction::RelativeCancel;
    if(action==MenuTouchAction::Begin || action==MenuTouchAction::RelativeBegin) {
        // 整段pointer事务从first DOWN取得不可复用token；LEFT未确认的candidate/scroll同样可精确取消。
        if(s_touchMenuNextToken==0) return; // 耗尽永久失败关闭，不能让旧token再次获得新手势。
        s_touchMenuToken=s_touchMenuNextToken;
        s_touchMenuNextToken=s_touchMenuNextToken==0x7fffffffu ? 0 : s_touchMenuNextToken+1;
    }
    if(relative) {
        if(s_touchMenuToken==0) return;
        const int phase=action==MenuTouchAction::RelativeBegin ? MENU_POINTER_BEGIN :
            action==MenuTouchAction::RelativeDown ? MENU_POINTER_DOWN : action==MenuTouchAction::RelativeUp ? MENU_POINTER_UP :
            action==MenuTouchAction::RelativeEnd ? MENU_POINTER_END : action==MenuTouchAction::RelativeCancel ? MENU_POINTER_CANCEL : MENU_POINTER_MOVE;
        double dx=0,dy=0,maxX=0,maxY=0;
        if(phase==MENU_POINTER_CANCEL || mapMenuRelativePayload(x,y,&dx,&dy,&maxX,&maxY))
            inputBridge_publishTouchMenuRelativeV1(phase,s_touchMenuToken,dx,dy,maxX,maxY);
        // UP只松LEFT，仍保留整个pointer事务；所有残余指END或真正CANCEL才结束身份。
        if(phase==MENU_POINTER_END || phase==MENU_POINTER_CANCEL) s_touchMenuToken=0;
        return;
    }
    const int mx = static_cast<int>(std::lround(amcl::renderscale::MapX(x)));
    const int my = static_cast<int>(std::lround(amcl::renderscale::MapY(y)));
    if (action == MenuTouchAction::Position) {
        if (s_touchMenuToken != 0) sendEvent(EVENT_TYPE_MENU_POINTER,MENU_POINTER_MOVE,mx,my,s_touchMenuToken);
        else inputBridge_publishTouchMenuCursorV1(mx,my);
    } else if (action == MenuTouchAction::Begin || action == MenuTouchAction::Down) {
        if(s_touchMenuToken!=0) sendEvent(EVENT_TYPE_MENU_POINTER,
            action==MenuTouchAction::Begin ? MENU_POINTER_BEGIN : MENU_POINTER_DOWN,mx,my,s_touchMenuToken);
    } else if (s_touchMenuToken != 0) {
        sendEvent(EVENT_TYPE_MENU_POINTER,action == MenuTouchAction::Up ? MENU_POINTER_UP :
                  action == MenuTouchAction::End ? MENU_POINTER_END : MENU_POINTER_CANCEL,
                  mx,my,s_touchMenuToken);
        if(action==MenuTouchAction::End || action==MenuTouchAction::Cancel) s_touchMenuToken=0;
    }
}

/** 快捷栏的可选长按共用现有 deadline worker，按指 owner 释放，0 绑定不发送。 */
static void schemaPollTouchHoldsLocked(int64_t eventTimeNs = 0) {
    // worker按当前单调时间执行；真实事件补轮询时以原采样时间为上界。终止事件可能
    // 因线程调度/等锁而晚派发，不能把派发等待误算成手指仍在按住的额外时间。
    const int64_t now = eventTimeNs > 0 ? std::min<int64_t>(eventTimeNs,schemaNowNs()) : schemaNowNs();
    s_menuTouch.SetExternalButtonsHeld(inputLedger().isHeld({OutputKind::Mouse,0}) ||
                                       inputLedger().isHeld({OutputKind::Mouse,1}) || menuToolMouseHeldLocked());
    s_menuTouch.Tick(now,emitMenuInteraction);
    for (auto& binding : s_schemaFingers) {
        if (binding.deadlineNs <= 0 || binding.moved || binding.holdFired || now < binding.deadlineNs) continue;
        // 空白区只产生视角；可选长按只属于快捷栏丢弃。
        if (binding.role != SCHEMA_FINGER_HOTBAR) { binding.deadlineNs=0; continue; }
        const int action = amcl::input::TouchDrop;
        binding.deadlineNs = 0;
        binding.holdFired = true;
        const int key = s_touchConfig.actions[action];
        if (key != 0) routerOutput(binding.owner,key,GLFW_PRESS);
        if (binding.control.haptic != 0) schemaFireHaptic(10,binding.control.id);
    }
}

/** 触控新增状态在既有复位域内退休。按钮跨 grab 承接的 owner 例外仍由调用方显式提供。 */
static void schemaRetireTouchPolicyLocked(const std::set<OwnerToken>& keepOwners) {
    s_touchMenuCursorVisible.store(false,std::memory_order_release);
    // policy/grab/modal/lifecycle 的完整退休必须先撤销消费者的全部旧菜单身份。
    // 不能以 s_menuTouch.Active() 或 s_touchMenuToken!=0 作条件：短点正常 UP 后这两项
    // 都已归零，而原 DOWN/UP 可能仍在 ring 等待消费。仅退出菜单贡献，保留其它来源。
    inputBridge_retireTouchMenuScopeV1();
    // 完整policy退休同时结束panel原生租约；旧UI acknowledgeReset无需再发送旧UP，
    // 后来的旧UP只遇到空map，不会释放新作用域的菜单贡献。
    releaseMenuToolControls();
    s_menuTouch.Cancel(emitMenuInteraction);
    s_touchJoystick.Reset();
    s_touchJoystickId.clear();
    for (const auto& binding : s_schemaFingers) {
        if (binding.owner != 0 && keepOwners.count(binding.owner) == 0) inputLedger().releaseOwner(binding.owner);
    }
    // 每个方向独立 owner，两个方向改成同一输出时末方向退出才释放；+4 是疾跑修饰键。
    for (int i=1;i<=4;++i) inputLedger().releaseOwner(OWNER_SCHEMA_WASD + i);
    s_touchLastTapSlot = -1; s_touchLastTapNs = 0; s_touchLastTapControl.clear();
}

static void schemaPollLongPressLocked(int64_t eventTimeNs = 0) {
    // 与空白/快捷栏期限采用相同时间边界：无事件的worker使用now，事件入口只能
    // 补发在该事件真实发生之前已经到期的长按，不能因UP/CANCEL排队而制造新按下。
    const long long now = eventTimeNs > 0 ? std::min<int64_t>(eventTimeNs,schemaNowNs()) : schemaNowNs();
    for (auto& item : s_schemaButtons) {
        SchemaButtonRuntime& state = item.second;
        if ((!schemaUsesGroupPhases(state) && state.control.trigger != 3) || state.fingers.empty() || state.longFired ||
            state.longDeadlineNs == 0 || now < state.longDeadlineNs) continue;
        // deadline 到期只提出候选。预算/资源拒绝不能凭 void emit 宣告长按已经按下，
        // 也不发送 button/haptic 成功反馈；本次 deadline 终结，下一真实触点可重新尝试。
        const bool phased = schemaUsesGroupPhases(state);
        const bool accepted=phased ? schemaGroupPhase(state, 1) : schemaDispatchButton(state.control,state.owner,GLFW_PRESS);
        if (!phased) state.outputDown=accepted;
        state.longFired=accepted;
        state.longDeadlineNs = 0;
    }
}

// 摇杆 WASD 边沿的唯一出口：direction 0..3 对应 GLFW 的 W/A/S/D，owner 固定为 OWNER_SCHEMA_WASD。
// 调用方持 s_schemaMutex，输出经 routerOutput 进入 transaction → ledger → ring（与 longPress 同锁序）。
static void schemaEmitWasd(int direction, bool press) {
    if (direction < 0 || direction >= amcl::input::SchemaWasdLatch::kDirections) return;
    const int code = s_touchConfig.actions[direction];
    if (code != 0 && routerOutput(OWNER_SCHEMA_WASD + direction,code,press ? GLFW_PRESS : GLFW_RELEASE) && press)
        ++s_touchGuide.movement;
}

// 30ms 锁存期限到达后补发被吞掉的 PRESS；摇杆手指已不在或方向已不再想要时只清期限。
// deadline worker 与触摸入口（worker 不可用时的降级路径）共用，调用方持 s_schemaMutex。
static void schemaPollWasdLatchLocked() {
    s_schemaWasdLatch.PollDue(schemaNowNs(), s_schemaJoyFinger != -1 || s_touchJoystick.Locked(), schemaEmitWasd);
}

// ==================== SchemaDeadlineWorker ====================
// 只有这一根常驻线程负责 schema 的两类 deadline：longPress 触发，以及摇杆 WASD 的 30ms 锁存补发。
// 它绝大部分时间阻塞在 condition variable，不轮询、不耗电；新 longPress、新的锁存期限、取消、
// schema replace 只需 signal 让它重新计算最近 deadline。condition 使用 CLOCK_MONOTONIC，避免用户
// 改系统时间导致阈值漂移。所有 runtime 访问仍受 s_schemaMutex 保护。
static pthread_cond_t s_schemaDeadlineCond;
static pthread_once_t s_schemaDeadlineOnce = PTHREAD_ONCE_INIT;
// false 表示 worker/condition 未可用；触摸入口仍会调用 schemaPollLongPressLocked() 与
// schemaPollWasdLatchLocked()，因此线程创建失败只降级为“下一次输入事件触发”，
// 不会对未初始化 condition 做 signal 或造成 native 崩溃。
static std::atomic<bool> s_schemaDeadlineWorkerReady(false);

static bool consumeGrabEpochLocked(bool fallbackGrabbed);

/**
 * 期限执行的生产事务。扫描阶段只决定何时醒来，所有候选必须在重新取锁后重读。
 * surface→mode→touch→schema→legacy的顺序与真实grab写入共用mode fence：
 * worker先赢时PRESS和runtime标记同时成立，后续翻转可carry；grab先赢时先退休旧候选。
 * gate/mode不可用只返回失败，绝不假设发出输出；worker负责有界重试避免过期期限忙循环。
 */
static bool schemaExecuteDueDeadlines() {
    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) return false;
    amcl::input::AuthoritativeGrabInputTransaction mode;
    if (!mode) return false;
    std::lock_guard<std::mutex> touchLock(s_touchStateMutex);
    const bool grabbed = consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    if (!s_touchPaused.load(std::memory_order_acquire)) {
        // 普通菜单按钮也由Native认领，静止长按必须由同一期限线程触发，不能等MOVE/UP补发。
        // 原mode/surface围栏先消费grab公告，已失效的候选仍在这里之前被退休。
        schemaPollLongPressLocked();
        if (grabbed) schemaPollWasdLatchLocked();
        schemaAdvanceGroupsLocked();
        // 菜单期限也属于同一touch会话；grab公告先取消旧菜单，再允许当前策略Tick。
        schemaPollTouchHoldsLocked();
    }
    pthread_mutex_unlock(&s_schemaMutex);
    return true;
}

/** MC线程的公告通知不得初始化线程、取schema锁或等待回调，只signal已有condition。 */
static void schemaNotifyDeadlineWorkerNonblocking() {
    if (s_schemaDeadlineWorkerReady.load(std::memory_order_acquire))
        pthread_cond_signal(&s_schemaDeadlineCond);
}

static void* schemaDeadlineWorkerMain(void*) {
    pthread_mutex_lock(&s_schemaMutex);
    for (;;) {
        long long earliest = 0;
        for (const auto& item : s_schemaButtons) {
            const SchemaButtonRuntime& state = item.second;
            if ((!schemaUsesGroupPhases(state) && state.control.trigger != 3) || state.fingers.empty() || state.longFired ||
                state.longDeadlineNs == 0) continue;
            if (earliest == 0 || state.longDeadlineNs < earliest) earliest = state.longDeadlineNs;
        }
        const long long wasdDeadline = s_schemaWasdLatch.EarliestDeadline();
        if (wasdDeadline != 0 && (earliest == 0 || wasdDeadline < earliest)) earliest = wasdDeadline;
        const int64_t menuDeadline = s_menuTouch.Deadline();
        if (menuDeadline > 0 && (earliest == 0 || menuDeadline < earliest)) earliest = menuDeadline;
        for (const auto& binding : s_schemaFingers) {
            if (binding.deadlineNs > 0 && (earliest == 0 || binding.deadlineNs < earliest)) earliest = binding.deadlineNs;
        }

        if (earliest == 0) {
            pthread_cond_wait(&s_schemaDeadlineCond, &s_schemaMutex);
            continue;
        }
        const long long now = schemaNowNs();
        if (earliest <= now) {
            // 禁止持schema反向取得surface/mode/touch；解锁后不保留任何map引用或迭代器。
            pthread_mutex_unlock(&s_schemaMutex);
            const bool executed = schemaExecuteDueDeadlines();
            pthread_mutex_lock(&s_schemaMutex);
            if (!executed) {
                // 暂时没有surface或mode服务时保留候选，最多20Hz重试；通知可提前唤醒。
                // 不能继续以已经过期的原期限timedwait，否则会形成零等待忙循环。
                const long long retry = schemaNowNs() + 50000000LL;
                struct timespec retryDeadline{(time_t)(retry / 1000000000LL), (long)(retry % 1000000000LL)};
                pthread_cond_timedwait(&s_schemaDeadlineCond, &s_schemaMutex, &retryDeadline);
            }
            continue;
        }
        struct timespec deadline;
        deadline.tv_sec = (time_t)(earliest / 1000000000LL);
        deadline.tv_nsec = (long)(earliest % 1000000000LL);
        pthread_cond_timedwait(&s_schemaDeadlineCond, &s_schemaMutex, &deadline);
    }
    return nullptr;
}

static void schemaInitDeadlineWorker() {
    pthread_condattr_t attr;
    int rc = pthread_condattr_init(&attr);
    if (rc != 0) {
        AMCL_LOG_E(LOG_TAG, "LongPress worker disabled: condattr init rc=%{public}d", rc);
        return;
    }
    rc = pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
    if (rc != 0) {
        // deadline 数值来自 CLOCK_MONOTONIC；不能拿它喂给默认 CLOCK_REALTIME condition，
        // 否则改系统时间或不同 epoch 会导致立即超时/永久等待。宁可退回事件入口轮询。
        pthread_condattr_destroy(&attr);
        AMCL_LOG_E(LOG_TAG, "LongPress worker disabled: monotonic clock rc=%{public}d", rc);
        return;
    }
    rc = pthread_cond_init(&s_schemaDeadlineCond, &attr);
    pthread_condattr_destroy(&attr);
    if (rc != 0) {
        AMCL_LOG_E(LOG_TAG, "LongPress worker disabled: cond init rc=%{public}d", rc);
        return;
    }

    pthread_t thread;
    rc = pthread_create(&thread, nullptr, schemaDeadlineWorkerMain, nullptr);
    if (rc != 0) {
        AMCL_LOG_E(LOG_TAG, "LongPress worker create failed rc=%{public}d; using input-event fallback", rc);
        return;
    }
    pthread_detach(thread);
    s_schemaDeadlineWorkerReady.store(true, std::memory_order_release);
}

static void schemaWakeDeadlineWorker() {
    pthread_once(&s_schemaDeadlineOnce, schemaInitDeadlineWorker);
    if (s_schemaDeadlineWorkerReady.load(std::memory_order_acquire)) {
        pthread_cond_signal(&s_schemaDeadlineCond);
    }
}

// ==================== GrabEpoch：同步承接仍被物理按住的按钮 owner ====================
//
// 关键时序：grab 状态先在 MC 线程改变，ArkTS 的显隐/schema 回调稍后才到。真正的 owner 迁移因此
// 必须在触摸入口观察到新 epoch 时、处理该次 UP/CANCEL 之前完成，绝不能等待 setControlSchema()。
//
// 承接规则不再猜测“按了多久”：只看明确因果——该按钮当前确实持有输出，且至少一根 owner finger
// 在 s_fingerDown 中仍为 down。F3、F4 等都可被短暂承接；触发翻转的 F4 会在紧随其后的物理 UP
// 立即释放，不会因 150ms 启发式被误判。多个手指共享同一个 OwnerToken，只有最后一指抬起才 RELEASE。
// 调用方必须持有 s_schemaMutex。
static std::set<OwnerToken> schemaCaptureHeldOwnersLocked() {
    std::set<OwnerToken> keepOwners;
    s_schemaCarriedOwners.clear();
    s_schemaCarriedByFinger.clear();

    for (auto& item : s_schemaButtons) {
        SchemaButtonRuntime& state = item.second;
        std::string groupId;
        if (state.groupControl >= 0 && static_cast<size_t>(state.groupControl) < s_touchGroups.Definition().controls.size()) {
            const int group=s_touchGroups.Definition().controls[state.groupControl].group;
            if (group >= 0) groupId=s_touchGroups.Definition().groups[group].id;
        }
        if (schemaUsesGroupPhases(state)) {
            // 同一手指可同时持有 press 与 longPress。每阶段独立承接，UP 必须收齐全部 owner。
            const auto& bindings=s_touchGroups.Definition().controls[state.groupControl].bindings;
            for (size_t phase=0; phase<2; ++phase) {
                if (!state.phaseHeld[phase] || bindings[phase].autoKeep || state.phaseOwners[phase] == 0) continue;
                SchemaCarriedOwner carried; carried.id=state.control.id; carried.owner=state.phaseOwners[phase]; carried.groupId=groupId;
                for (int fid : state.fingers) if (fid >= 0 && fid < MAX_FINGERS && s_fingerDown[fid]) {
                    carried.fingers.insert(fid); s_schemaCarriedByFinger[fid]=carried.owner;
                }
                if (!carried.fingers.empty()) { keepOwners.insert(carried.owner); s_schemaCarriedOwners[carried.owner]=std::move(carried); }
            }
            continue;
        }
        const bool carryable = state.outputDown &&
            (state.control.trigger == 0 || (state.control.trigger == 3 && state.longFired));
        if (!carryable || state.owner == 0) continue;

        SchemaCarriedOwner carried;
        carried.id = state.control.id;
        carried.groupId = groupId;
        carried.owner = state.owner;
        for (int fid : state.fingers) {
            if (fid < 0 || fid >= MAX_FINGERS || !s_fingerDown[fid]) continue;
            carried.fingers.insert(fid);
            s_schemaCarriedByFinger[fid] = state.owner;
        }
        if (!carried.fingers.empty()) {
            keepOwners.insert(state.owner);
            s_schemaCarriedOwners[state.owner] = carried;
        }
    }
    return keepOwners;
}

/** 原手指结束时收齐所有阶段的承接项；只搬移对象，实际来源释放仍在 schema 锁外执行。 */
static bool schemaCollectCarriedUpLocked(int fid, bool ended,
        std::array<SchemaCarriedOwner, MAX_FINGERS * 4>& released, size_t& count) {
    if (s_schemaCarriedByFinger.find(fid) == s_schemaCarriedByFinger.end()) return false;
    if (!ended) return true;
    s_schemaCarriedByFinger.erase(fid);
    for (auto it=s_schemaCarriedOwners.begin(); it!=s_schemaCarriedOwners.end();) {
        if (it->second.fingers.erase(fid) && it->second.fingers.empty()) {
            // 每指最多一个按钮及四阶段，整个接触表至多 MAX_FINGERS*4 项。
            if (count < released.size()) released[count++]=std::move(it->second);
            it=s_schemaCarriedOwners.erase(it);
        } else ++it;
    }
    return true;
}

// 清除 schema 解释器的瞬时状态。keepOwners 只用于 grabbed→menu 的物理承接。
// This boundary owns only schema owners: physical keyboard/mouse and external
// ArkTS/gamepad owners must survive a grab/schema flip. Full lifecycle cancel
// separately fences the physical router and calls InputLedger::releaseAll().
// 调用方必须持有 s_schemaMutex。
static void schemaResetTransientStateLocked(const std::set<OwnerToken>& keepOwners) {
    s_touchGroups.RetireTransactions();
    schemaRetireGroupUiOwnersLocked(true);
    schemaRetireTouchPolicyLocked(keepOwners);
    for (auto& item : s_schemaButtons) {
        SchemaButtonRuntime& state = item.second;
        schemaRetireGroupPhaseOwners(state, &keepOwners);
        if (state.owner != 0 && keepOwners.count(state.owner) == 0) {
            inputLedger().releaseOwner(state.owner);
        }
        if (state.outputDown && keepOwners.count(state.owner) == 0) {
            amcl_fire_button_pressed(state.control.id, 0);
        }
    }
    s_schemaButtons.clear();
    // Joystick WASD uses one stable schema-only owner and is never carried by
    // the button/finger hand-off table.
    inputLedger().releaseOwner(OWNER_SCHEMA_WASD);
    // owner 已释放，锁存只清状态与补发期限，不再发边沿；worker 醒来后看不到旧期限。
    s_schemaWasdLatch.Reset();
    schemaWakeDeadlineWorker();

    s_schemaJoyFinger = -1;
    s_schemaLookFinger = -1;
    for (int i = 0; i < MAX_FINGERS; i++) {
        s_schemaFingers[i] = SchemaFingerBinding{};
        s_schemaScrollLastY[i] = 0.0f;
        s_schemaScrollAccum[i] = 0.0f;
        s_schemaHotbarLastSlot[i] = -1;
        s_schemaDragLastX[i] = 0.0f;
        s_schemaDragLastY[i] = 0.0f;
    }

    if (keepOwners.empty()) {
        for (const auto& item : s_schemaCarriedOwners) {
            inputLedger().releaseOwner(item.first);
            amcl_fire_button_pressed(item.second.id.c_str(), 0);
        }
        s_schemaCarriedOwners.clear();
        s_schemaCarriedByFinger.clear();
    }
}

// 全局策略/视口替换只撤销schema自己的owner，不能误松物理/ArkTS兼容来源；局部表差异另按控件退休。
// carried owner已脱离旧generation，仍保留到原物理UP；完整取消结束全部schema快照再发布新全局策略。
static void schemaCancelGenerationLocked() {
    s_touchGroups.RetireTransactions();
    schemaRetireGroupUiOwnersLocked(true);
    schemaRetireTouchPolicyLocked({});
    for (auto& item : s_schemaButtons) {
        SchemaButtonRuntime& state = item.second;
        schemaRetireGroupPhaseOwners(state);
        if (state.owner != 0) inputLedger().releaseOwner(state.owner);
        if (state.outputDown) amcl_fire_button_pressed(state.control.id, 0);
    }
    s_schemaButtons.clear();
    inputLedger().releaseOwner(OWNER_SCHEMA_WASD);
    // 旧 generation 的锁存期限不得在新表上补发 PRESS（末尾的 wake 让 worker 重新计算期限）。
    s_schemaWasdLatch.Reset();

    s_schemaJoyFinger = -1;
    s_schemaLookFinger = -1;
    for (int i = 0; i < MAX_FINGERS; i++) {
        s_schemaFingers[i] = SchemaFingerBinding{};
        s_schemaScrollAccum[i] = 0.0f;
        s_schemaHotbarLastSlot[i] = -1;
        s_schemaDragLastX[i] = 0.0f;
        s_schemaDragLastY[i] = 0.0f;
    }
    schemaWakeDeadlineWorker();
}

// 候选表已校验且调用方持schema锁。旧owner/接触只按动作与命中绑定生存，反馈变化
// 不退休旧快照；新表仍通过完整定义比较安装，使后来DOWN取得最新haptic。
static bool schemaControlSurvivesLocked(const AmclCtrlEntry& control,
                                        const AmclCtrlEntry* entries, int count) {
    for (int i = 0; i < count; ++i)
        if (amcl::input::SameControlSchemaBinding(control, entries[i])) return true;
    return false;
}

// 在schema锁内取真实原生活动触点数，发布前后以同一事务快照记录；不把表换代或就绪声明当作保持成功。
static int schemaNativeFingerCountLocked() {
    int count = 0;
    for (const auto& binding : s_schemaFingers)
        if (binding.role == SCHEMA_FINGER_BUTTON || binding.role == SCHEMA_FINGER_JOYSTICK ||
            binding.role == SCHEMA_FINGER_SCROLL || binding.role == SCHEMA_FINGER_HOTBAR ||
            binding.role == SCHEMA_FINGER_LOOK) ++count;
    return count;
}

// 局部表变化只退休已变化的控件；调用方持touch→schema锁，且视口/全局策略已确认不变。
// 快照未变的按钮、期限、摇杆及空白look保留；carried owner已脱离schema，仍由原物理UP收尾。
static void schemaRetireChangedControlsLocked(const AmclCtrlEntry* entries, int count) {
    for (auto it = s_schemaButtons.begin(); it != s_schemaButtons.end();) {
        if (schemaControlSurvivesLocked(it->second.control, entries, count)) { ++it; continue; }
        schemaRetireGroupPhaseOwners(it->second);
        if (it->second.owner != 0) inputLedger().releaseOwner(it->second.owner);
        if (it->second.outputDown) amcl_fire_button_pressed(it->second.control.id, 0);
        it = s_schemaButtons.erase(it); // 同时撤销长按/双击期限，不能在新绑定上补发旧动作。
    }
    bool retireJoystick = false;
    if (!s_touchJoystickId.empty()) {
        // 自动前进可在没有活动手指时持有方向，不能只遍历finger来判断摇杆是否删除。
        const auto old = std::find_if(s_schema.begin(), s_schema.end(), [](const AmclCtrlEntry& e) {
            return s_touchJoystickId == e.id;
        });
        retireJoystick = old == s_schema.end() || !schemaControlSurvivesLocked(*old, entries, count);
    }
    for (int fid = 0; fid < MAX_FINGERS; ++fid) {
        auto& binding = s_schemaFingers[fid];
        // 空白look没有控件ID，角色已在DOWN冻结；新增UI区域不能抢走正在滑动的手指。
        if (binding.role == SCHEMA_FINGER_NONE || binding.role == SCHEMA_FINGER_IGNORED ||
            (binding.role == SCHEMA_FINGER_LOOK && binding.control.id[0] == '\0') ||
            schemaControlSurvivesLocked(binding.control, entries, count)) continue;
        if (binding.role == SCHEMA_FINGER_JOYSTICK) retireJoystick = true;
        if (binding.owner != 0) inputLedger().releaseOwner(binding.owner);
        if (s_schemaLookFinger == fid) s_schemaLookFinger = -1;
        binding = SchemaFingerBinding{}; // 迟到MOVE/UP不重新hit-test，不变成新控件的点击。
        s_schemaScrollAccum[fid] = 0; s_schemaHotbarLastSlot[fid] = -1;
        s_schemaDragLastX[fid] = s_schemaDragLastY[fid] = 0;
    }
    if (retireJoystick) {
        for (int i = 0; i <= 4; ++i) inputLedger().releaseOwner(OWNER_SCHEMA_WASD + i);
        s_schemaWasdLatch.Reset(); s_touchJoystick.Reset(); s_touchJoystickId.clear(); s_schemaJoyFinger = -1;
    }
    // 双击物品栏的历史也属于原控件定义；删除/改变该定义后不能与新表第一次点击配对。
    if (!s_touchLastTapControl.empty()) {
        const auto old = std::find_if(s_schema.begin(), s_schema.end(), [](const AmclCtrlEntry& e) {
            return s_touchLastTapControl == e.id;
        });
        if (old == s_schema.end() || !schemaControlSurvivesLocked(*old, entries, count)) {
            s_touchLastTapControl.clear(); s_touchLastTapNs = 0; s_touchLastTapSlot = -1;
        }
    }
    schemaWakeDeadlineWorker(); // 唤醒只重新计算剩余期限，未变长按不能被重置计时。
}

/**
 * 已接受动作在事件末端提交，避开正在解释的 state/finger 引用。仅把最终可见成员作为
 * “仍存活”集合交给原差异退休函数；背景触点与物理/手柄 owner 不进入该集合。
 * mask 和退休位于同一锁内，UI 在此之后才能读回；通知失败仍保留 pending 可查询事实。
 */
static void schemaAdvanceGroupsLocked() {
    if (!s_touchGroups.Enabled()) return;
    const uint64_t before = s_touchGroups.Revision();
    std::set<size_t> hidden;
    try { hidden = s_touchGroups.Advance(); } catch (...) { return; }
    if (!hidden.empty()) {
        // 提交后不再分配容器，避免 mask 已隐藏而分配失败跳过必需的 owner 退休。
        std::array<AmclCtrlEntry, AMCL_CONTROL_SCHEMA_MAX_CONTROLS> visible{};
        int count = 0;
        for (size_t i = 0; i < s_schema.size(); ++i) if (s_touchGroups.Visible(i)) visible[count++] = s_schema[i];
        schemaRetireChangedControlsLocked(visible.data(), count);
        for (auto it=s_schemaCarriedOwners.begin(); it!=s_schemaCarriedOwners.end();) {
            bool retire=false;
            for (size_t group : hidden) retire |= it->second.groupId == s_touchGroups.Definition().groups[group].id;
            if (retire) {
                inputLedger().releaseOwner(it->first); amcl_fire_button_pressed(it->second.id.c_str(),0);
                it=s_schemaCarriedOwners.erase(it);
            } else ++it;
        }
        if (s_groupMouseControl >= 0 && !s_touchGroups.Visible(s_groupMouseControl)) {
            inputBridge_retireTouchMenuToolScopeV1();
            releaseMenuToolControls();
            std::fill(s_menuMouseBounds,s_menuMouseBounds+4,0.0);
            s_groupMouseControl=-1; s_groupMouseMember.clear();
        }
    }
    schemaRetireGroupUiOwnersLocked();
    if (s_touchGroups.Revision() != before) amcl_notify_touch_groups();
}

// 一次摇杆采样 → 最终 WASD 边沿。30ms 锁存（刚 RELEASE 的方向在窗口内不 PRESS，去扇区边界抖动）
// 吞掉的 PRESS 会留下补发期限；这里唤醒 deadline worker，让手指静止时也能在期限到达时按下。
// 调用方持 s_schemaMutex。
static void schemaApplyWasd(bool w, bool a, bool s, bool d) {
    const bool want[amcl::input::SchemaWasdLatch::kDirections] = { w, a, s, d };
    s_schemaWasdLatch.Apply(want, schemaNowNs(), schemaEmitWasd);
    if (s_schemaWasdLatch.EarliestDeadline() != 0) schemaWakeDeadlineWorker();
}

static void schemaJoystick(float px, float py, const AmclCtrlEntry& j) {
    (void)j; // 几何在 DOWN 冻结到策略实例；MOVE 不再根据可变视图位置重算中心。
    s_touchJoystick.Move(px,py);
    const double dx = s_touchJoystick.X(), dy = s_touchJoystick.Y();
    const float deadZone = s_schemaDeadZone;   // A.4-part2：取全局 profile.joystickDeadZone（下发时存入）
    // 扇区判定已抽到 platform/joystick_sector.{h,cpp}（纯函数，有 host test）。
    // 抽出的理由不是这段代码难懂，而是同一张扇区表在本项目里写了三遍
    // （native 触控 / 手柄端 ArkTS / 触控端 ArkTS 兼容路径），谁改一份另两份不会有任何
    // 提示，表现为"同一个八向摇杆在三端手感不同"。现在两侧各有测试按同一张规格表断言。
    // 方向锁存（30ms 重按抑制）仍留在 schemaApplyWasd —— 它有状态且三端策略不同。
    const AmclJoystickSector sector =
        amcl_joystick_sector((double)dx, (double)dy, (double)deadZone);
    schemaApplyWasd(sector.w, sector.a, sector.s, sector.d);
    const int sprint = s_touchConfig.actions[amcl::input::TouchSprint];
    if (sprint != 0) routerOutput(OWNER_SCHEMA_WASD + 4,sprint,s_touchJoystick.Sprint() ? GLFW_PRESS : GLFW_RELEASE);
}

// ============ 指针位置判据（含自学习的窗口偏移）============
//
// 为什么需要"位置"这条判据，而不能只靠"坐标是整数"：真手指的坐标实测落在 1/8 像素
// 栅格上（1959.375 / 737.625 / 1065.875 / 817.625），所以单看"两个坐标都是整数"
// 每根手指约有 1/8 × 1/8 = 1/64 ≈ 1.6% 的概率被误判。1.6% 的虚拟按键点击丢失是
// 无法接受的回归，因此必须再要求"落点就在系统指针处"。
//
// 坐标系问题：触摸包的 px/py 是 XComponent 局部物理像素，而
// OH_Input_GetPointerLocation 返回 display 物理像素。全屏沉浸式窗口下两者偏移为 0，
// 但这是**假设**而不是事实，所以这里不硬编码 0，而是自学习：
//   · 偏移接近 0 → 直接采纳 0（预期路径，无学习期）；
//   · 否则对四舍五入后的偏移投票，同一个值出现 3 次即采纳，并打日志；
//   · 学习期内保守返回 false（宁可暂时保留旧的滚轮症状，也不误吞真手指）。
static constexpr double kPointerMatchTolerancePx = 4.0;
static bool s_ptrOffsetAdopted = false;
static double s_ptrOffsetX = 0.0;
static double s_ptrOffsetY = 0.0;
static int s_ptrOffsetVotes = 0;
static double s_ptrOffsetCandX = 0.0;
static double s_ptrOffsetCandY = 0.0;

static bool pointerDerivedDownAt(float px, float py) {
    double ptrX = 0.0;
    double ptrY = 0.0;
    if (!amcl_pointer_location_query(&ptrX, &ptrY)) {
        // 无法读到指针位置就没有鼠标派生证据；整数坐标也可能来自真实手指或触摸注入。
        // 明确MOUSE/UNKNOWN镜像在上游独立处理，这里不能再靠“锁能打开”误丢触控DOWN。
        return false;
    }
    const double dx = ptrX - static_cast<double>(px);
    const double dy = ptrY - static_cast<double>(py);
    if (s_ptrOffsetAdopted) {
        return std::fabs(dx - s_ptrOffsetX) <= kPointerMatchTolerancePx &&
               std::fabs(dy - s_ptrOffsetY) <= kPointerMatchTolerancePx;
    }
    if (std::fabs(dx) <= kPointerMatchTolerancePx &&
        std::fabs(dy) <= kPointerMatchTolerancePx) {
        s_ptrOffsetAdopted = true;
        s_ptrOffsetX = 0.0;
        s_ptrOffsetY = 0.0;
        OH_LOG_INFO(LOG_APP,
                    "AMCL_PTRLOC window offset adopted as zero "
                    "(touch=%{public}.1f,%{public}.1f pointer=%{public}.1f,%{public}.1f)",
                    (double)px, (double)py, ptrX, ptrY);
        return true;
    }
    const double roundedX = std::floor(dx + 0.5);
    const double roundedY = std::floor(dy + 0.5);
    if (s_ptrOffsetVotes > 0 &&
        std::fabs(roundedX - s_ptrOffsetCandX) <= kPointerMatchTolerancePx &&
        std::fabs(roundedY - s_ptrOffsetCandY) <= kPointerMatchTolerancePx) {
        s_ptrOffsetVotes++;
    } else {
        s_ptrOffsetCandX = roundedX;
        s_ptrOffsetCandY = roundedY;
        s_ptrOffsetVotes = 1;
    }
    if (s_ptrOffsetVotes >= 3) {
        s_ptrOffsetAdopted = true;
        s_ptrOffsetX = s_ptrOffsetCandX;
        s_ptrOffsetY = s_ptrOffsetCandY;
        OH_LOG_INFO(LOG_APP,
                    "AMCL_PTRLOC window offset learned=%{public}.1f,%{public}.1f",
                    s_ptrOffsetX, s_ptrOffsetY);
        return true;
    }
    OH_LOG_INFO(LOG_APP,
                "AMCL_PTRLOC offset candidate=%{public}.1f,%{public}.1f votes=%{public}d "
                "(touch=%{public}.1f,%{public}.1f pointer=%{public}.1f,%{public}.1f)",
                roundedX, roundedY, s_ptrOffsetVotes, (double)px, (double)py,
                ptrX, ptrY);
    return false;
}

// 物品栏直点（kind=4）：按触点在控件内的横向位置算槽位，发数字键 tap（扫选去重）。
static void schemaHotbarTap(float px, float py, const AmclCtrlEntry& e, int fid) {
    const int slot = amcl::input::ControlHotbarSlot(e, px, py);
    if (slot < 0) { s_schemaHotbarLastSlot[fid] = -1; return; }
    if (slot == s_schemaHotbarLastSlot[fid]) return;   // 跨格才发
    s_schemaHotbarLastSlot[fid] = slot;
    const int key = s_touchConfig.actions[amcl::input::TouchHotbar1 + slot];
    if (key == 0) return; // 玩家显式解除绑定，不回退到数字键。
    // Hotbar 是无持续状态的 tap，但仍分配独立 owner，避免与“按住数字键”的其他控件互相提前释放。
    const OwnerToken tapOwner = nextOwnerToken();
    const bool pressed=routerOutput(tapOwner, key, GLFW_PRESS);
    const bool released=routerOutput(tapOwner, key, GLFW_RELEASE);
    if(pressed && released) { ++s_touchGuide.hotbar; s_touchGuide.slot=slot; }
    if (e.haptic != 0) schemaFireHaptic(8,e.id);
}

// 滚轮（kind=2）：纵向累计位移，每 schemaScrollStepPx() 触发一次 scroll（上滑=+1/下滑=-1）。
static void schemaScrollMove(float py, int fid) {
    amcl::input::census::Bump(amcl::input::census::Channel::SchemaTouchScroll);
    const float dy = py - s_schemaScrollLastY[fid];
    s_schemaScrollLastY[fid] = py;
    s_schemaScrollAccum[fid] += dy;
    // gateAccepted=true：本函数只从 OnDispatchTouchEvent 的 SurfaceInputGateCallbackScope
    // 里被调到（唯一调用点）。⚠️ 该端是 TOUCH_CONTROLS ⇒ 留在 legacy ring 上，
    // typed 分叉只认 PHYSICAL_KBM，所以这个实参在本通道上不会被读到。
    while (s_schemaScrollAccum[fid] <= -schemaScrollStepPx()) { routerScroll(AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 0, 1, true);  s_schemaScrollAccum[fid] += schemaScrollStepPx(); }
    while (s_schemaScrollAccum[fid] >=  schemaScrollStepPx()) { routerScroll(AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 0, -1, true); s_schemaScrollAccum[fid] -= schemaScrollStepPx(); }
}

// 新DOWN与显式连滑共用命中policy：UI专属exact先让出解释权，再沿原Native exact→slop规则。
// UI根/抽屉孩子由RuntimeTouchLayout放在Native视觉之后；独立Native Dispatch不受ArkUI Block
// 阻断，故不能仅靠显示层级或最近中心保护UI。UI命中返回ARKTS域，调用方不得继续world/look fallback。
// Native域内保留最近中心与等距首项手感，UI仍只有真实矩形；返回UI id仅供冻结排除角色，
// 不合成UI动作，也不声称它就是ArkUI选中的最上层节点。普通MOVE/UP仍消费DOWN快照。
// 调用方必须持有 s_schemaMutex。
static bool schemaHitTestLocked(float px, float py, AmclCtrlEntry& out) {
    int best = -1;
    double bestDist = 0.0;
    for (int pass = 0; pass < 3; pass++) {
        best = -1;
        for (size_t i = 0; i < s_schema.size(); i++) {
            const AmclCtrlEntry& e = s_schema[i];
            if (!s_touchGroups.Visible(i)) continue;
            if (!s_touchGroups.Enabled()) {
                if (pass == 0 && e.handledBy == 0) continue;
                if (pass != 0 && e.handledBy != 0) continue;
            } else {
                // 新组方案显式 rank 同时控制绘制和命中；exact 先于 slop，UI 不扩张。
                if (pass == 1 || (pass == 2 && e.handledBy != 0)) continue;
            }
            // 物品栏没有普通按钮的扩张区；边缘外的DOWN交回空白look，不绑首末格。
            if (e.kind == 4 && amcl::input::ControlHotbarSlot(e, px, py) < 0) continue;
            const float pad = pass == 2 ? e.hitSlop : 0.0f;
            if (!pointInRect(px, py, e.x, e.y, e.w, e.h, pad)) continue;
            const double dx = (double)px - ((double)e.x + (double)e.w * 0.5);
            const double dy = (double)py - ((double)e.y + (double)e.h * 0.5);
            const double dist = dx * dx + dy * dy;
            const bool higherRank = s_touchGroups.Enabled() && best >= 0 &&
                s_touchGroups.Definition().controls[i].rank > s_touchGroups.Definition().controls[best].rank;
            const bool sameRank = !s_touchGroups.Enabled() || best < 0 ||
                s_touchGroups.Definition().controls[i].rank == s_touchGroups.Definition().controls[best].rank;
            if (best < 0 || higherRank || (sameRank && dist < bestDist)) {
                best = (int)i;
                bestDist = dist;
            }
        }
        if (best >= 0) {
            out = s_schema[(size_t)best];
            return true;
        }
    }
    return false;
}

// schema 主解释器的不变量：
/** 为快捷栏增强建立候选；不创建新线程，期限交给已有 worker。调用方已冻结该指角色。 */
/** 菜单与世界共用普通按钮认领。调用方持schema锁；旧触点继续原owner，只有DOWN命中新按钮。
 * 系统控件与辅助面板仍属于UI排除域，既不补发按键，也不把连续MOVE重新解释为背景点击。
 */
static bool schemaOwnsMenuButtonLocked(int fid, bool down, float x, float y) {
    if (fid < 0 || fid >= MAX_FINGERS) return false;
    if (s_schemaFingers[fid].role == SCHEMA_FINGER_BUTTON) return true;
    if (!down || touchOverlayContains(s_menuMouseBounds,x,y) || touchOverlayContains(s_touchGuideBounds,x,y)) return false;
    AmclCtrlEntry hit{};
    return schemaHitTestLocked(x,y,hit) && hit.kind == 0 && hit.handledBy == 0;
}

static void schemaBeginTouchCandidate(SchemaFingerBinding& binding,float x,float y) {
    binding.startX = x; binding.startY = y; binding.startNs = schemaNowNs();
    binding.owner = nextOwnerToken();
    if (binding.role == SCHEMA_FINGER_HOTBAR) {
        binding.initialSlot = amcl::input::ControlHotbarSlot(binding.control,x,y);
        if (s_touchConfig.hotbarDrop && binding.initialSlot >= 0)
            binding.deadlineNs = binding.startNs + static_cast<int64_t>(s_touchConfig.holdMs) * 1000000;
    }
    if (binding.deadlineNs > 0) schemaWakeDeadlineWorker();
}

/** 位移检测只看原始surface坐标，不乘镜头灵敏度；快捷栏跨格即退出长按候选。 */
static void schemaMoveTouchCandidate(SchemaFingerBinding& binding,float x,float y) {
    if (binding.role == SCHEMA_FINGER_LOOK && !binding.holdFired && axisPanLookSuppressed(nowMonotonicNs())) {
        binding.moved = true; binding.deadlineNs = 0;
    }
    const double slop = 6 * std::max(1.0,ohos_display_density());
    if (std::hypot(x-binding.startX,y-binding.startY) > slop ||
        (binding.role == SCHEMA_FINGER_HOTBAR &&
         amcl::input::ControlHotbarSlot(binding.control,x,y) != binding.initialSlot)) {
        binding.moved = true; binding.deadlineNs = 0;
        // 丢弃触发后移动不应继续按住Q扫过其它物品。视角长按允许持续转动，直到真实终止边沿。
        if (binding.role == SCHEMA_FINGER_HOTBAR && binding.holdFired) inputLedger().releaseOwner(binding.owner);
    }
}

/** 真实 UP 才能完成候选；CANCEL 只退休持有。双击身份同时包含控件、槽位和单调时间。 */
static void schemaFinishTouchCandidate(SchemaFingerBinding& binding,bool cancelled,float x,float y) {
    const int64_t now = schemaNowNs();
    // 平台允许合并MOVE；UP本身必须按原始落点重新核实，不能把“没有MOVE标记”当作静止。
    const double slop = 6 * std::max(1.0,ohos_display_density());
    const bool endpointValid = std::hypot(x-binding.startX,y-binding.startY) <= slop;
    const bool tap = !cancelled && !binding.moved && !binding.holdFired &&
        endpointValid &&
        now >= binding.startNs && now-binding.startNs <= SCHEMA_DOUBLETAP_NS &&
        !(binding.role == SCHEMA_FINGER_LOOK && axisPanLookSuppressed(nowMonotonicNs()));
    int key = 0;
    if (binding.role == SCHEMA_FINGER_HOTBAR) {
        const int slot = amcl::input::ControlHotbarSlot(binding.control,x,y);
        if (tap && slot == binding.initialSlot && slot >= 0 && s_touchConfig.hotbarSwap) {
            if (s_touchLastTapControl == binding.control.id && s_touchLastTapSlot == slot &&
                now >= s_touchLastTapNs && now-s_touchLastTapNs <= SCHEMA_DOUBLETAP_NS) {
                key = s_touchConfig.actions[amcl::input::TouchSwap];
                s_touchLastTapSlot = -1; s_touchLastTapNs = 0;
            } else {
                s_touchLastTapControl = binding.control.id; s_touchLastTapSlot = slot; s_touchLastTapNs = now;
            }
        } else { s_touchLastTapSlot = -1; s_touchLastTapNs = 0; }
    }
    if (key != 0) routerOutput(binding.owner,key,GLFW_PRESS);
    if (binding.owner != 0) inputLedger().releaseOwner(binding.owner);
    binding.deadlineNs = 0;
}

// 连滑先使用同一DOWN命中规则选候选：同控件边缘微动不松开/重按，精确命中新控件才优先接力。
// 新候选仅靠slop相交时保留原有效热区，避免邻键扩张区交界抖动；不同组/ArkUI精确目标仍阻挡接力。
static void schemaSwipeButtonLocked(SchemaFingerBinding& binding,int fid,float x,float y) {
    if (binding.control.swipeGroup == 0) return;
    AmclCtrlEntry hit{};
    const bool hasHit = schemaHitTestLocked(x,y,hit);
    const bool inCurrent = pointInRect(x,y,binding.control.x,binding.control.y,
                                      binding.control.w,binding.control.h,binding.control.hitSlop);
    const bool exactTarget = hasHit && pointInRect(x,y,hit.x,hit.y,hit.w,hit.h,0);
    if (binding.owner != 0 && inCurrent &&
        (!hasHit || std::strcmp(hit.id,binding.control.id) == 0 || !exactTarget)) return;
    auto old = s_schemaButtons.find(binding.control.id);
    if (old != s_schemaButtons.end() && old->second.fingers.erase(fid) && old->second.fingers.empty())
        schemaTriggerLastUp(old->second);
    binding.owner = 0;
    if (!hasHit || hit.kind != 0 || hit.handledBy != 0 ||
        hit.swipeGroup != binding.control.swipeGroup || hit.trigger != 0 || hit.dragLook) return;
    if (s_touchGroups.Enabled()) {
        const int from = schemaGroupControlIndex(binding.control.id), to = schemaGroupControlIndex(hit.id);
        if (from < 0 || to < 0 || s_touchGroups.Definition().controls[from].group != s_touchGroups.Definition().controls[to].group ||
            s_touchGroups.BlocksPoint(x, y, s_schema)) return;
    }
    auto& state = s_schemaButtons[hit.id];
    const bool empty = state.fingers.empty();
    // 连滑进入的是新gesture时才采纳当前表的反馈；仍被其它手指持有的同一gesture
    // 继续使用首指冻结快照。真实动作/命中变化已由发布差异退休，不能在这里改绑旧贡献。
    if (empty) state.control = hit;
    state.fingers.insert(fid);
    if (empty) schemaTriggerFirstDown(state);
    binding.control = hit; binding.owner = state.owner;
}

// 1. DOWN 做 hit-test，并把 ControlSnapshot 复制到 finger binding；显式滑动组可在同代内有序接力。
// 2. MOVE/UP 只解释该快照，schema 重排或替换绝不会把旧 finger 指向另一个控件；
// 3. 每根 finger 最多拥有一个角色，空白 look 也只允许一个 owner；
// 4. 按钮输出由 SchemaButtonRuntime.owner 持有，多指共享 owner，末指才释放。
static SchemaFingerRole handleSchemaGrabbedTouch(
    const OH_NativeXComponent_TouchEvent& ev, float px, float py, int fid) {
    bool emitLook = false;
    SchemaFingerRole eventRole = SCHEMA_FINGER_NONE;
    // 1=物理 UP：补齐守恒 backlog；-1=系统 CANCEL：旧手势已失去可靠终点，只能丢弃。
    // 二者不能合并处理，否则 surface/grab 取消会把旧 epoch 尾量注入新相机基准。
    int lookFinishMode = 0;
    float lookDx = 0.0f, lookDy = 0.0f;

    pthread_mutex_lock(&s_schemaMutex);
    SchemaFingerBinding& binding = s_schemaFingers[fid];
    const bool normalUp = ev.type == OH_NATIVEXCOMPONENT_UP;
    const bool cancelled = ev.type != OH_NATIVEXCOMPONENT_DOWN && ev.type != OH_NATIVEXCOMPONENT_MOVE && !normalUp;

    if (ev.type == OH_NATIVEXCOMPONENT_DOWN) {
        // 同一 fid 连续两次 DOWN 而中间没有 UP（平台复用 fid、或终止边沿丢失）时，
        // 旧 binding 的输出必须先撤销，否则：
        //   · 旧角色是 JOYSTICK → `s_schemaJoyFinger` 仍等于 fid，下面的
        //     `s_schemaJoyFinger == -1` 判定失败 → 本次被判 IGNORED，而 UP 到达时
        //     `role == JOYSTICK` 也不成立 → **WASD 永久按住，且此后每根摇杆手指都被
        //     判 IGNORED，虚拟摇杆彻底失效**，直到 schema 重新下发或 cancelAll；
        //   · 旧角色是 BUTTON → 该按钮的 finger 集合里残留本 fid，引用计数永不归零，
        //     按键卡住。
        // 这里在同一把 s_schemaMutex 下就地撤销，不调用会重新加锁的辅助函数。
        if (binding.role == SCHEMA_FINGER_JOYSTICK) {
            if (s_schemaJoyFinger == fid) {
                s_schemaJoyFinger = -1;
                s_touchJoystick.Reset();
                inputLedger().releaseOwner(OWNER_SCHEMA_WASD + 4);
                schemaApplyWasd(false, false, false, false);
            }
        } else if (binding.role == SCHEMA_FINGER_BUTTON) {
            auto stale = s_schemaButtons.find(binding.control.id);
            if (stale != s_schemaButtons.end()) {
                SchemaButtonRuntime& state = stale->second;
                state.fingers.erase(fid);
                // 末指离开走正常 lastUp，保持 InputLedger 引用计数守恒。
                if (state.fingers.empty()) schemaTriggerLastUp(state, true);
            }
        }
        if (s_schemaLookFinger == fid) s_schemaLookFinger = -1;
        if (binding.role == SCHEMA_FINGER_LOOK || binding.role == SCHEMA_FINGER_HOTBAR)
            schemaFinishTouchCandidate(binding,true,px,py);

        binding = SchemaFingerBinding{};
        binding.generation = s_schemaGeneration;
        binding.startX = px; binding.startY = py;

        AmclCtrlEntry hit{};
        if (touchOverlayContains(s_touchGuideBounds,px,py)) {
            binding.role = SCHEMA_FINGER_ARKTS;
        } else if (!schemaHitTestLocked(px, py, hit)) {
            // 多指同时划空白区时只认第一根 look finger，避免两根手指交错污染位移基准。
            if (s_schemaLookFinger == -1) {
                s_schemaLookFinger = fid;
                binding.role = SCHEMA_FINGER_LOOK;
                s_fingers[fid].lastX = px;
                s_fingers[fid].lastY = py;
                schemaBeginTouchCandidate(binding,px,py);
            } else {
                binding.role = SCHEMA_FINGER_IGNORED;
            }
        } else {
            binding.control = hit; // 稳定快照：后续不再读取 s_schema 下标
            const bool validNativeKind = (hit.kind == 0 || hit.kind == 1 || hit.kind == 2 || hit.kind == 4);
            const bool takeover = hit.handledBy == 0 && validNativeKind &&
                hit.kind >= 0 && hit.kind < 31 && ((s_schemaTakeover >> hit.kind) & 1) != 0;
            if (!takeover) {
                binding.role = SCHEMA_FINGER_ARKTS;
            } else if (hit.kind == 1) {
                if (s_schemaJoyFinger == -1) {
                    s_schemaJoyFinger = fid;
                    binding.role = SCHEMA_FINGER_JOYSTICK;
                    binding.owner = OWNER_SCHEMA_WASD;
                    // 自动前进转回手指控制也要先退出旧方向，避免新中心与旧方向并存一帧。
                    schemaApplyWasd(false,false,false,false);
                    s_touchJoystick.Begin(px,py,hit.x,hit.y,hit.w,hit.h,s_touchConfig,s_schemaDeadZone);
                    s_touchJoystickId = hit.id;
                    schemaJoystick(px, py, binding.control);
                } else {
                    binding.role = SCHEMA_FINGER_IGNORED;
                }
            } else if (hit.kind == 0) {
                binding.role = SCHEMA_FINGER_BUTTON;
                SchemaButtonRuntime& state = s_schemaButtons[hit.id];
                const bool wasEmpty = state.fingers.empty();
                // 每次新的gesture读取当前表，避免feedback-only保活后永久沿用旧haptic。
                // 多指共持时保留原gesture快照；toggle旧owner的有效输入绑定已在发布时
                // 验证未变，所以下一次DOWN关闭它仍释放原输出，而新反馈只作用于新动作。
                if (wasEmpty) state.control = hit;
                state.fingers.insert(fid);
                if (wasEmpty) schemaTriggerFirstDown(state);
                binding.owner = state.owner;
                if (hit.dragLook) {
                    s_schemaDragLastX[fid] = px;
                    s_schemaDragLastY[fid] = py;
                    if (s_schemaLookFinger == -1) s_schemaLookFinger = fid;
                }
            } else if (hit.kind == 2) {
                binding.role = SCHEMA_FINGER_SCROLL;
                s_schemaScrollLastY[fid] = py;
                s_schemaScrollAccum[fid] = 0.0f;
            } else if (hit.kind == 4) {
                binding.role = SCHEMA_FINGER_HOTBAR;
                s_schemaHotbarLastSlot[fid] = -1;
                schemaHotbarTap(px, py, binding.control, fid);
                schemaBeginTouchCandidate(binding,px,py);
            }
        }
    } else if (ev.type == OH_NATIVEXCOMPONENT_MOVE || normalUp) {
        // 正常UP是原接触的最后一个真实位置样本，与MOVE归约同一角色。先采终点并
        // 取消越阈值的候选，再考虑到期动作及末松；CANCEL/unknown没有可靠终点，
        // 绝不走此分支。普通按钮只补dragLook末段，不在抬指时接力按下另一个按钮。
        switch (binding.role) {
            case SCHEMA_FINGER_JOYSTICK:
                if (fid == s_schemaJoyFinger) schemaJoystick(px, py, binding.control);
                break;
            case SCHEMA_FINGER_SCROLL:
                schemaScrollMove(py, fid);
                break;
            case SCHEMA_FINGER_HOTBAR:
                schemaMoveTouchCandidate(binding,px,py);
                schemaHotbarTap(px, py, binding.control, fid);
                break;
            case SCHEMA_FINGER_BUTTON:
                {
                    auto found = s_schemaButtons.find(binding.control.id);
                    if (found != s_schemaButtons.end() && schemaUsesGroupPhases(found->second)) {
                        auto& state = found->second;
                        const bool fcl = s_touchGroups.Definition().controls[state.groupControl].fcl;
                        const double limit = fcl ? 10.0 : 12.0 * s_touchContextDensity;
                        const bool outside=std::abs(px-binding.startX) > limit || std::abs(py-binding.startY) > limit;
                        // FCL click 使用最终落点，允许100ms内短暂离开再返回；原生策略保持越界取消。
                        state.groupMoved=fcl ? outside : (state.groupMoved || outside);
                        const double longLimit = fcl ? 2.0 : limit;
                        if ((!fcl || schemaNowNs()-state.groupDownNs < 400000000LL) &&
                            (std::abs(px-binding.startX) > longLimit || std::abs(py-binding.startY) > longLimit)) state.longDeadlineNs = 0;
                    }
                }
                if (!normalUp) schemaSwipeButtonLocked(binding,fid,px,py);
                if (binding.control.dragLook && s_schemaLookFinger == fid) {
                    lookDx = px - s_schemaDragLastX[fid];
                    lookDy = py - s_schemaDragLastY[fid];
                    s_schemaDragLastX[fid] = px;
                    s_schemaDragLastY[fid] = py;
                    emitLook = (lookDx != 0.0f || lookDy != 0.0f);
                }
                break;
            case SCHEMA_FINGER_LOOK:
                schemaMoveTouchCandidate(binding,px,py);
                if (s_schemaLookFinger == fid) {
                    lookDx = px - s_fingers[fid].lastX;
                    lookDy = py - s_fingers[fid].lastY;
                    s_fingers[fid].lastX = px;
                    s_fingers[fid].lastY = py;
                    emitLook = (lookDx != 0.0f || lookDy != 0.0f);
                    // 空白 look 是滚轮合成滑动的落点：本机滚轮以 tool=FINGER 的
                    // DOWN/MOVE/UP 到达，元数据与真手指不可区分，只有"此刻有一个
                    // 轴驱动 Pan 正在进行"这个事实能把它认出来（见
                    // ohos_note_axis_pan_active）。基准照常更新，只是不产出视角，
                    // 这样抑制窗结束后不会残留一个跨越整段滚动的差分。
                    if (emitLook && axisPanLookSuppressed(nowMonotonicNs())) {
                        emitLook = false;
                    }
                }
                break;
            default:
                break;
        }
    }
    // 已知look先于由同一采样确认的离散动作进入原运输，UP末段也保持这一顺序。
    // 运输口只复制队列，不调用游戏；仍在原schema事务内，不让其它线程插到两者之间。
    if (emitLook) {
        amcl::input::census::Bump(amcl::input::census::Channel::LookFromSchemaTouch);
        applyLookDelta(AMCL_INPUT_SOURCE_TOUCH_CONTROLS, (double)lookDx,
                       (double)lookDy, ev.timeStamp > 0 ? ev.timeStamp : 0);
    }
    if (!cancelled) {
        // worker暂未执行时仍保留事件入口补轮询，但MOVE/UP先按真实终点撤销旧候选。
        // CANCEL一旦先取得此事务，只退休原持有，不得在退休前补发任何过期候选；
        // 已由worker先提交的真实持有则沿下面的原owner正常释放，不尝试回滚游戏动作。
        schemaPollLongPressLocked(ev.timeStamp);
        schemaPollWasdLatchLocked();
        schemaPollTouchHoldsLocked(ev.timeStamp);
    }
    if (normalUp || cancelled) {
        eventRole = binding.role;
        if (binding.role == SCHEMA_FINGER_JOYSTICK && fid == s_schemaJoyFinger) {
            s_schemaJoyFinger = -1;
            s_touchJoystick.End(ev.type != OH_NATIVEXCOMPONENT_UP);
            schemaApplyWasd(s_touchJoystick.Locked(),false,false,false);
            if (!s_touchJoystick.Sprint()) inputLedger().releaseOwner(OWNER_SCHEMA_WASD + 4);
        } else if (binding.role == SCHEMA_FINGER_BUTTON) {
            auto it = s_schemaButtons.find(binding.control.id);
            if (it != s_schemaButtons.end()) {
                SchemaButtonRuntime& state = it->second;
                state.fingers.erase(fid);
                if (state.fingers.empty()) schemaTriggerLastUp(state, cancelled);
            }
        }
        if (binding.role == SCHEMA_FINGER_LOOK || binding.role == SCHEMA_FINGER_HOTBAR)
            schemaFinishTouchCandidate(binding,ev.type != OH_NATIVEXCOMPONENT_UP,px,py);
        if (s_schemaLookFinger == fid) {
            s_schemaLookFinger = -1;
            lookFinishMode = (ev.type == OH_NATIVEXCOMPONENT_UP) ? 1 : -1;
        }
        binding = SchemaFingerBinding{};
    }
    if (ev.type == OH_NATIVEXCOMPONENT_DOWN ||
        ev.type == OH_NATIVEXCOMPONENT_MOVE) {
        eventRole = binding.role;
    }
    if (lookFinishMode != 0) flushLookPending(lookFinishMode > 0, AMCL_INPUT_SOURCE_TOUCH_CONTROLS);
    schemaAdvanceGroupsLocked();
    pthread_mutex_unlock(&s_schemaMutex);
    return eventRole;
}

// ==================== GrabEpochCoordinator ====================
// libglfw 在真正的 cursor mode 翻转时只发布原子 announcement；本函数在持有 touchStateMutex 的
// 第一个边界（触摸 ingress 或 schema 发布）消费它。触摸路径保证在更新 s_fingerDown 之前迁移；若
// “下一次事件”正是旧手指的 UP，capture 仍能先看到它在旧 epoch 中为 down，然后同一次入口马上按
// carried owner 释放。schema 路径则防止 ArkTS 回调抢先替换 generation、提前释放本应 carry 的 owner。
static void onGrabFlipCancel(bool nowGrabbed) {
    if (s_touchPublicationGrabEpoch != UINT64_MAX) ++s_touchPublicationGrabEpoch;
    // Native首次吸收真实grab公告时，也在面板任何释放之前撤销旧scope前缀。
    // consumer真实mode边界已有同等保护，此处不能依赖某后端碰巧先完成清理。
    inputBridge_retireTouchMenuScopeV1();
    releaseMenuToolControls();
    // grab 翻转会让旧 epoch 的左键按住状态失去配对的抬起边沿，必须就地复位，
    // 否则诊断分桶会把菜单/游戏切换之后的样本继续算进上一段 hold。
    resetMirrorGestureStateLocked();

    // The candidate belongs to the old grab epoch. Retaining it until its
    // deadline could inject LEFT after the menu/game transition; the observed
    // native-left latch remains valid for this surface lifecycle.

    // schemaResetTransientStateLocked 会退休完整菜单作用域，再用原 token 取消当前
    // 解释器；普通 LEFT RELEASE 不能撤销已 UP、尚未消费的旧菜单队列前缀。

    // grab epoch 已改变，旧手势的平滑余量不能跨 Minecraft 中心重锚继续输出。
    flushLookPending(false);

    pthread_mutex_lock(&s_schemaMutex);
    if (!nowGrabbed) {
        // 游戏→菜单：仅承接“仍由物理手指按住”的 press/已触发 longPress owner，其余输出同步释放。
        const std::set<OwnerToken> keepOwners = schemaCaptureHeldOwnersLocked();
        schemaResetTransientStateLocked(keepOwners);
    } else {
        // 菜单→游戏：旧菜单手指绝不能在新 epoch 被重新解释为 look。先释放全部输出，再标 dead 至 UP。
        schemaResetTransientStateLocked({});
        for (int i = 0; i < MAX_FINGERS; i++) {
            if (s_fingerDown[i]) s_fingerDead[i] = true;
        }
    }
    pthread_mutex_unlock(&s_schemaMutex);
}

// 消费 grab announcement 的唯一入口。调用方必须持有 s_touchStateMutex；这样触摸事件与 ArkTS
// schema 发布无论谁先到，都先完成旧 epoch 的 carry/cancel，再允许新 generation 替换。只在
// OnDispatchTouchEvent 消费会留下一个竞态：grab TSFN 可能先触发 sendControlSchema，旧 generation
// 会在 owner 尚未 carry 前被 schemaCancelGenerationLocked 直接释放，破坏 F3+F4 等跨 grab 按住语义。
// announcement 仍由 libglfw 的真实 cursor-mode 翻转产生，ArkTS 的 grabbed 字段不是权威状态源。
// 返回值是本次事件应使用的生效 grab 状态（公告在取队列的同一临界区读出；进程内尚无公告时
// 才用 fallbackGrabbed）。调用方必须用它解释当前事件，不能再单独读一次公告状态。
static bool consumeGrabEpochLocked(bool fallbackGrabbed) {
    // 关键顺序：先取消/迁移旧 epoch，再由调用方登记当前 touch 或发布新 schema。
    return amcl::input::ApplyGrabAnnouncements(
        s_grabFlipLastState, s_grabFlipInit, s_grabAnnouncements.Take(),
        fallbackGrabbed, [](bool announced) { onGrabFlipCancel(announced); });
}

// ==================== legacy ring 不连续对账 ====================
// bridge局部overflow已由同锁生产镜像/cutoff重建该consumer，不推进此全生产epoch。
// 只有无法绑定可靠快照的真正不连续仍推进epoch；libentry在自己的无锁入口
// （按端键/鼠标、触摸 dispatch、schema 发布、250ms 心跳）发现变化后执行一次 legacy-only 复位；
// 判定与步骤顺序在 legacy_ring_discontinuity.cpp（直接链接进 host 测试），这里只绑定文件级状态。
// 绝不在 sendEvent / ledger emit / grab trampoline / bridge 消费者线程里对账：那些位置要么已持
// 更内层的锁，要么运行在 MC 线程，进入这里就是锁序反转。
static amcl::input::LegacyRingDiscontinuityTracker s_legacyRingTracker;

static void legacyRingClearExternalHeld(void*) {
    std::lock_guard<std::mutex> lock(s_externalInputMutex);
    s_externalHeld.Clear();
}
static void legacyRingReleaseLedger(void*) {
    inputLedger().releaseAll();
}
// 调用方已持 s_schemaMutex；空 keepOwners 连同 carried owner 一起清掉。
static void legacyRingResetSchema(void*) {
    schemaResetTransientStateLocked({});
    // 生产schema退休已先推进菜单epoch并清panel；这个幂等释放也兼容旧空schema测试入口。
    releaseMenuToolControls();
}
// 以原 token 撤销菜单事务：丢过历史的消费者已自行作废该 token（token 不匹配，CANCEL 是空操作），
// 没有溢出的兄弟消费者靠它结束同一事务、补发已可见 PRESS 的 RELEASE。
static void legacyRingCancelMenu(void*) {
    s_menuTouch.Cancel(emitMenuInteraction);
}
// 只标 dead、不清 s_fingerDown：平台仍会送来这些手指的 MOVE/UP，UP 时由 dead 分支收尾。
static void legacyRingRetireFingers(void*) {
    amcl::input::MarkFingersDeadUntilUp(s_fingerDown, s_fingerDead, MAX_FINGERS);
}
static void legacyRingCompleteBoundary(void*) {
    // ring不连续只撤销兼容来源；typed实体持有及其IME会话仍由core管理。
    const uint32_t domains = amcl::input::kInputResetTouch | amcl::input::kInputResetGamepad |
        (amcl::input::PlatformInputPhysicalRouteUsesTyped() ? 0u : amcl::input::kInputResetPhysical);
    amcl::input::PlatformInputCompleteResetBoundary(domains);
}

static const amcl::input::LegacyRingResetSteps kLegacyRingResetSteps{
    nullptr, legacyRingClearExternalHeld, legacyRingReleaseLedger,
    legacyRingResetSchema, legacyRingCancelMenu, legacyRingRetireFingers,
    legacyRingCompleteBoundary};

// 快速路径只有一次原子读与一次比较；变化时按全局锁序 surface gate → touch state → schema →
// input transaction 取锁（gate 递归，NAPI / 触摸入口已持有也安全），持锁后重读 epoch 再判定，
// 并把全部步骤放进 LegacyPhysicalEdgeRouter 的复位围栏：围栏先释放 legacy 物理身份，且在步骤
// 执行期间拒绝任何同步回入重新建立持有。刻意不清通道配对、不复位 typed core、不改 capture、
// 不丢 look backlog（这些都不经 legacy ring，理由见 legacy_ring_discontinuity.h）。
static void reconcileLegacyRingDiscontinuity() {
    if (!s_legacyRingTracker.Changed(inputBridge_legacyRingDiscontinuityEpochV1())) return;
    uint64_t observed = 0u;
    bool reset = false;
    {
        std::lock_guard<std::recursive_mutex> gateLock(s_surfaceInputGateMutex);
        std::lock_guard<std::mutex> touchStateLock(s_touchStateMutex);
        pthread_mutex_lock(&s_schemaMutex);
        {
            std::lock_guard<std::recursive_mutex> transactionLock(s_inputTransactionMutex);
            observed = inputBridge_legacyRingDiscontinuityEpochV1();
            if (s_legacyRingTracker.Changed(observed)) {
                physicalEdgeRouter().Reset([observed, &reset]() {
                    reset = s_legacyRingTracker.ReconcileLocked(observed, kLegacyRingResetSteps);
                });
            }
        }
        pthread_mutex_unlock(&s_schemaMutex);
    }
    if (reset) {
        // 与 bridge 的 "InputBridge ring overflow recovered" 成对判读：每次丢历史恰好对应一行。
        AMCL_LOG_W(LOG_TAG,
            "AMCL_RINGGAP legacy-only reset epoch=%{public}llu resets=%{public}llu "
            "absorbedByCancel=%{public}llu (external/ledger/schema/menu cleared, "
            "down fingers retired; pairing/core/capture/look untouched)",
            static_cast<unsigned long long>(observed),
            static_cast<unsigned long long>(s_legacyRingTracker.ResetCount()),
            static_cast<unsigned long long>(s_legacyRingTracker.AbsorbCount()));
    }
}

// ==================== XComponent 触摸回调 ====================
extern "C" void OnDispatchTouchEvent(OH_NativeXComponent* component, void* window) {
    SurfaceInputGateCallbackScope gate(component, window, true);
    if (!gate.accepted()) return;
    // ring 不连续对账必须在取 touchState 之前：它自己按 gate → touch → schema → transaction 取锁
    // （gate 是递归锁，这里已持有也安全）。之后本事件看到的是已复位的 legacy owner 状态。
    reconcileLegacyRingDiscontinuity();

    OH_NativeXComponent_TouchEvent touchEvent;
    int32_t ret = OH_NativeXComponent_GetTouchEvent(component, window, &touchEvent);
    if (ret != 0) return;

    // 事件入口降级轮询与worker使用同一mode fence；否则线程创建失败时旧期限仍可跨grab首次触发。
    amcl::input::AuthoritativeGrabInputTransaction grabTransaction;
    if (!grabTransaction) return;

    // 从读取完平台事件到 owner/角色处理结束保持同一 ingress 临界区。生命周期 cancel 会等待本事件
    // 完整提交或释放后再归零，因而不存在“cancel 清了一半、MOVE 又写回一半”的撕裂状态。
    std::lock_guard<std::mutex> touchStateLock(s_touchStateMutex);

    // 暂停时不产生任何新输出，但仍消费 UP/CANCEL 做物理 finger bookkeeping。
    // 否则暂停期间抬手会被完全吞掉，恢复后同 fid 可能永远保持 dead/down。
    if (s_touchPaused.load(std::memory_order_acquire)) {
        // 暂停期间的边沿被整段丢弃，因此恢复后不能仍然认为左键还按着：
        // 那会让诊断分桶把恢复后的样本继续算进上一段 hold。
        resetMirrorGestureStateLocked();
        const int32_t pausedFid = touchEvent.id;
        if (pausedFid >= 0 && pausedFid < MAX_FINGERS &&
            (touchEvent.type == OH_NATIVEXCOMPONENT_UP || touchEvent.type == OH_NATIVEXCOMPONENT_CANCEL)) {
            s_fingerDown[pausedFid] = false;
            s_fingerDead[pausedFid] = false;
            // Schema replacement/longPress worker uses s_schemaMutex; paused bookkeeping follows the global
            // touch→schema order rather than writing the binding through a second, unsynchronised path.
            pthread_mutex_lock(&s_schemaMutex);
            s_schemaFingers[pausedFid] = SchemaFingerBinding{};
            pthread_mutex_unlock(&s_schemaMutex);
        }
        return;
    }

    // Use the touchPoints[] entry whose id matches the top-level changed id.
    // point[0] can belong to another finger, so it is only a compatibility
    // fallback for the early tool-type exclusion and never starts a synthetic
    // tap candidate.
    const ChangedTouchPointSource changedPoint =
        classifyChangedTouchPoint(component, touchEvent);
    OH_NativeXComponent_TouchPointToolType toolType = changedPoint.tool;
    if (toolType == OH_NATIVEXCOMPONENT_TOOL_TYPE_UNKNOWN) {
        OH_NativeXComponent_GetTouchPointToolType(component, 0, &toolType);
    }
    if (toolType == OH_NATIVEXCOMPONENT_TOOL_TYPE_MOUSE ||
        toolType == OH_NATIVEXCOMPONENT_TOOL_TYPE_LENS) {
        // An explicitly mouse/lens packet belongs to the native mouse channel.
        // It cannot complete a previously inferred fallback gesture.
        amcl::input::census::Bump(
            amcl::input::census::Channel::TouchToolMouseDropped);
        return;
    }

    // Mouse-mirror detection happens after the grab epoch is consumed below, so
    // the recognizer's epoch/generation stamps stay coherent. See mirrorPacket.

    resolveBridge();
    if (!bridgeReady()) return;

    int32_t fid = touchEvent.id;
    float px = touchEvent.x;
    float py = touchEvent.y;

    const bool evIsDown = (touchEvent.type == OH_NATIVEXCOMPONENT_DOWN);
    const bool evIsUp   = (touchEvent.type == OH_NATIVEXCOMPONENT_UP || touchEvent.type == OH_NATIVEXCOMPONENT_CANCEL);
    // 无论下一边界是物理触摸还是 ArkTS schema 重推，都经同一 helper 消费真实 native epoch。
    // 当前事件的 fingerDown 尚未更新，因此旧手指的 UP 仍可先被正确 capture，再立即释放 carried owner。
    // 本事件一律按 helper 返回的生效状态分类：公告在取队列的同一临界区读出，isGrabbedMode 只是
    // 进程内尚无公告时的兜底读数；此后到达的翻转属于下一个事件。
    const bool grabbed = consumeGrabEpochLocked(grabTransaction.grabbed());

    // ==================== 鼠标镜像包 ====================
    // ⚠️ **两个析取项各在一台真机上承重，谁都不能删**（2026-08-22，计划 §76）：
    //   · API 26 手机：`GetTouchEventSourceType` **如实报 MOUSE**，第一析取项**是活的**，
    //     而且是这台设备上唯一起作用的那条（`AMCL_TOUCHSRC source=1 … classified=1`，
    //     且在光标锁**关闭**的时段同样成立 ⇒ 与第二析取项无关）；
    //   · API 24 平板：该 API 对 618/618 个包一律返回 TOUCHSCREEN，第一析取项恒假，
    //     唯一有区分度的是 toolType（真手指 FINGER(1)、鼠标镜像 UNKNOWN(0)）。
    // ⚠️ 这段曾断言「src==MOUSE 永不成立，那条判定自上线起就是死代码」——**已被 API 26
    // 真机否证**。它的证据只来自一台 API 24 设备，却写成了跨设备的现在时结论（规范 §八
    // 第一条：结论的作用域不得大于证据的作用域）。删掉第一析取项会让手机侧分类整条失效。
    //
    // "tool 未知即鼠标"单独使用是危险的（某些固件对真手指也可能报 UNKNOWN），所以该规则
    // 只在**光标锁生效**时启用：光标锁仅在检测到物理鼠标且进入游戏后才建立，纯触摸设备
    // 永远走不到这一分支，触摸屏不可能因此失效。
    const bool mirrorPacket =
        changedPoint.source == MouseSynthTouchSource::kMouseSynth ||
        (amcl_cursor_lock_active() &&
         changedPoint.tool == OH_NATIVEXCOMPONENT_TOOL_TYPE_UNKNOWN);

    // ---- deviceId 取证（常开，每个新组合只打一条）----
    //
    // 为什么值得专门取一次证：目前"这个触摸包是鼠标派生还是真手指"用的是一串启发式
    // （source → 已证伪、tool → 只能区分 UNKNOWN、位置 → 两类包锚点完全相同），每加一条
    // 启发式就多一个假阳性面。而 OH_NativeXComponent_TouchEvent 自带 `deviceId`
    // （SDK 头 native_interface_xcomponent.h:306），代码从未读过它。若鼠标派生包的
    // deviceId 等于 ArkUI onMouse 上报的那个（实测 11）、而触摸屏是另一个值，
    // 那么"鼠标身份"就从推断升级为**确定字段**，整套启发式可以一次性收敛掉。
    // SDK 没有承诺合成事件填什么，所以这只能由真机回答。
    {
        // 组合 = deviceId × tool × 是否被当作镜像。数量极少（个位数），
        // 记住已打印过的组合即可，稳态零日志。
        struct SeenKey { int64_t device; int tool; int mirror; };
        static SeenKey s_seen[12] = {};
        static int s_seenCount = 0;
        const int toolNow = static_cast<int>(changedPoint.tool);
        const int mirrorNow = mirrorPacket ? 1 : 0;
        bool known = false;
        for (int i = 0; i < s_seenCount; ++i) {
            if (s_seen[i].device == touchEvent.deviceId &&
                s_seen[i].tool == toolNow && s_seen[i].mirror == mirrorNow) {
                known = true;
                break;
            }
        }
        if (!known && s_seenCount < 12) {
            s_seen[s_seenCount].device = touchEvent.deviceId;
            s_seen[s_seenCount].tool = toolNow;
            s_seen[s_seenCount].mirror = mirrorNow;
            ++s_seenCount;
            OH_LOG_INFO(LOG_APP,
                        "AMCL_TOUCHID new combo deviceId=%{public}lld "
                        "tool=%{public}d mirrorClassified=%{public}d "
                        "cursorLock=%{public}d x=%{public}f y=%{public}f",
                        static_cast<long long>(touchEvent.deviceId), toolNow,
                        mirrorNow, amcl_cursor_lock_active() ? 1 : 0,
                        static_cast<double>(px), static_cast<double>(py));
        }
    }

    // 常开普查：把"这个物理动作到底以什么形态到达触摸层"记成聚合计数。
    // 滚轮是否被平台镜像成触摸 MOVE，是本机唯一还没取证的通道分工。
    {
        using amcl::input::census::Bump;
        using amcl::input::census::Channel;
        if (touchEvent.type == OH_NATIVEXCOMPONENT_DOWN) {
            Bump(mirrorPacket ? Channel::TouchMirrorDown
                              : Channel::TouchFingerDown);
        } else if (touchEvent.type == OH_NATIVEXCOMPONENT_MOVE) {
            Bump(mirrorPacket ? Channel::TouchMirrorMove
                              : Channel::TouchFingerMove);
        } else {
            Bump(mirrorPacket ? Channel::TouchMirrorUp : Channel::TouchFingerUp);
        }
    }

    if (mirrorPacket) {
        // 镜像包**不进虚拟控件层**（鼠标与虚拟按键是并列输入源）。
        // 它当前**只承担一件事：左键边沿**。
        //
        // ⚠️ 这段曾写着「它承担**两件事**：1) 左键边沿；2) 按住左键拖动时的视角……
        // **故 2) 必须还回来**」。**第 2 件已在 §30.2 按用户明确要求整体删除**，
        // 本块往下约 60 行有完整的删除理由与"不要再加回来"的记录，代码侧这个分支
        // 也确实没有任何 `applyLookDelta`。
        //
        // 这条比一般的过期注释更危险，因为它是**祈使句**：照它做会重新引入那条
        // 有界（坐标被 LockCursor 夹在窗口内）且与 rawDelta 不同量纲的视角通道 ——
        // 正是用户说"完全无用甚至是副作用"的那个方案。
        //
        // 另外原文里「本设备的左键在 native 与 ArkUI onMouse 上都不存在（28/28 条全是右键）」
        // 缺**设备限定**：那是 API 24 平板的实测，API 26 手机上 ArkUI onMouse 确实报左键
        // （真机 `AMCL_INPOLICY left owner=arkuiMouse`）。镜像是左键的**末选**通道，
        // 只在本设备两条真鼠标通道都没送来过左键边沿时才真的产出。
        MouseSynthTouchAction mirrorAction = MouseSynthTouchAction::kCancel;
        if (touchEvent.type == OH_NATIVEXCOMPONENT_DOWN) {
            mirrorAction = MouseSynthTouchAction::kDown;
        } else if (touchEvent.type == OH_NATIVEXCOMPONENT_MOVE) {
            mirrorAction = MouseSynthTouchAction::kMove;
        } else if (touchEvent.type == OH_NATIVEXCOMPONENT_UP) {
            mirrorAction = MouseSynthTouchAction::kUp;
        }
        // 左键**立即**透传：镜像 DOWN 即按下、UP/CANCEL 即抬起。
        //
        // 上一版复用 mouseSynthTap 识别器有两个问题：它刻意等到 DOWN+300ms 才发
        // （这就是你感到的迟滞），而且只在 UP 之后发一次 press+release —— 那样
        // "按住左键连续挖矿"根本不可能实现。
        //
        // 立即透传的安全性由真机数据支撑：镜像 DOWN 与最近的 ArkUI 按钮边沿相距
        // ≥1166ms，两者从不配对，即左键只走镜像、右键只走 ArkUI，不存在双发；
        // 而滚轮的 6 格滚动没有产生任何镜像 DOWN/UP，也不会被误判成点击。
        if (mirrorAction == MouseSynthTouchAction::kDown ||
            mirrorAction == MouseSynthTouchAction::kUp ||
            mirrorAction == MouseSynthTouchAction::kCancel) {
            const bool press = mirrorAction == MouseSynthTouchAction::kDown;
            // ⚠️ 下面这段记录的是"**按下时动态切换**光标模式"这个做法被否证。
            // 它**不是**在说"默认应该是 follow=true" —— 当前默认是 `false`（钉住），
            // 见 `cursor_lock.cpp` 的 `g_followMovement{false}` 与 `cursor_lock.h` 顶部。
            // 原文末尾那句「保持 follow=true」已作废（它属于 §23/§24 的状态，
            // 那时视角还来自镜像坐标差分；镜像视角通道删除后前提消失，§35.6 据此改为钉住）。
            // 仍然有效的结论只有一条：**不要再按下时动态切换模式**。
            // 这里曾在按下时把光标钉住（amcl_cursor_lock_set_follow(false)），
            // 想让 rawDelta 接管拖动位移。**真机已否证，不要再加回来。**
            // 证据（census11，逐秒分桶，`AMCL_CURSORFOLLOW` 打出 24 条 follow=0/1
            // 交替证明模式确实切过去了）：
            //     AMCL_DRAG 1s hold[move=0 rawPresent=0 rawNz=0 travel=0]
            //                  free[move=97 rawPresent=97 rawNz=97 travel=1090]
            // 即：按住左键期间 ArkUI onMouse **零投递**，与光标是否钉住无关；
            // 而钉住又让合成触点坐标恒定，于是两条通道同时没有数据 → 视角完全不动。
            // 保持 follow=true：拖动有界，但至少可用。
            // 平台层的解法只有 easyGo.mouse2TouchEventMode:disabled（本机 API 24 未解析），
            // 产品层的解法见 docs §22.4 的"锁存挖掘"。
            // 镜像是左键的**末选**通道（input_channel_policy.h 的优先级表）。
            // 只有当本设备的 ArkUI onMouse 与 native XComponent 都从未送来过左键边沿时
            // 它才会真的产出 —— 那正是 API 24 平板的情形。
            //
            // 这条降级是"菜单点不动"的修复：API 26 修好了 GetTouchEventSourceType 之后，
            // 上面的 `mirrorPacket` 第一析取项（source==MOUSE）在**菜单态也成立**，
            // 于是镜像每次都比 onMouse 先到并抢走 LEFT，把本该带 windowX/windowY 的
            // ArkUI 点击整批挤掉（真机 `btnMirror=10 btnRejected=20`，恒定 1:2）。
            // 改成按优先级决定所有者之后，有真鼠标通道的设备上镜像自动让位。
            if (acceptPhysicalButtonEdge(AMCL_INPUT_CHANNEL_TOUCH_MIRROR, 0u,
                    OH_NATIVEXCOMPONENT_LEFT_BUTTON, press)) {
                amcl::input::census::Bump(
                    amcl::input::census::Channel::ButtonFromTouchMirror);
                // 已在 SurfaceInputGateCallbackScope 内，故 gateAccepted=true；
                // 锁序仍是 surface gate → touch state → input transaction。
                const AmclLegacyPhysicalOutcome outcome =
                    amcl::input::PlatformInputPhysicalButtonTransaction(
                    0u, static_cast<uint32_t>(OH_NATIVEXCOMPONENT_LEFT_BUTTON),
                    press ? AMCL_INPUT_ACTION_DOWN : AMCL_INPUT_ACTION_UP,
                    GLFW_MOUSE_BUTTON_LEFT,
                    press ? GLFW_PRESS : GLFW_RELEASE, true,
                    routePhysicalButtonEventChecked);
                finishPhysicalButtonAdmission(AMCL_INPUT_CHANNEL_TOUCH_MIRROR,
                    0u, OH_NATIVEXCOMPONENT_LEFT_BUTTON, press, outcome);
            } else {
                amcl::input::census::Bump(
                    amcl::input::census::Channel::ButtonRejectedByClaim);
            }
        }
        // ---- 镜像流**不再产生视角**（2026-08-19 起，按用户决定移除）----
        //
        // 曾经这里用"合成触点坐标的逐帧差分"当作按住左键期间的视角来源。它能动，
        // 但两个缺陷是结构性的、无法靠调参消除：
        //   1. **有界**。合成触点的坐标就是被 LockCursor 夹在窗口内的指针位置，
        //      拖到窗口边缘位移即为 0，视角停住；
        //   2. **手感与正常移动不同**。它是"位置差分 × 1/density"，而不按键时走的是
        //      ArkTS rawDelta（硬件相对量，且 API 24 上还被系统按显示大小比例缩过）。
        //      两条通道的增益、采样率与加速度曲线都不一致，切换瞬间必然突变。
        // 用户明确要求摒弃这个有界方案：它每次都会把"到底哪条通道在工作"这件事搅浑，
        // 让人误以为左键拖动"基本可用"，从而掩盖真正的缺口。
        //
        // 现在的不变量：**视角只有一个来源 = ArkTS rawDelta**（无界、单一量纲）。
        // 因此如果按住左键时视角不动，那就是一个干净、可判读的否证信号，而不是
        // 一段"感觉怪但能用"的位移。
        //
        // 已经查清并写死的事实（不要再走这些路）：
        //   · 兜底转换只吃"鼠标左键事件 + 轴事件"，右键按住拖动的 onMouse + rawDelta
        //     完全正常且无界（真机：windowX 夹死在 1317.176 时 rawDx 仍报 13~14）；
        //   · 合成触摸包是在**窗口级事件过滤器的下游**（ArkUI 内部）生成的 ——
        //     真机 `wfTouch` 在左键拖动期间完全缺席而 `mirrorMove≈100/s`，
        //     所以 OH_NativeWindowManager_RegisterTouchEventFilter 掐不掉它；
        //   · 但同期 `wfMouse≈110~120/s` 证明**鼠标事件本身以全速到达窗口层**，
        //     即"平台不投递"是错的，是 ArkUI 选择了转换而不是投递 onMouse；
        //   · Input_MouseEvent 没有任何相对量 getter，故窗口层拿到的只有被夹取的绝对坐标。
        // 镜像包在此之后只保留一个职责：左键边沿（上面那段）。
        if (mirrorAction == MouseSynthTouchAction::kDown) {
            s_mirrorGestureActive = true;
        } else if (mirrorAction == MouseSynthTouchAction::kUp ||
                   mirrorAction == MouseSynthTouchAction::kCancel) {
            s_mirrorGestureActive = false;
            // 镜像终止边沿刻意不收口任何 look 尾量。镜像包本身不产生视角；同期唯一的视角来源是
            // rawDelta（PHYSICAL_KBM），它的平滑恒为 1.0、没有尾量，停投由 idle worker 收口。
            // 触控 source 的尾量属于同时在做 dragLook / 空白 look 的真手指（DesktopTouch 混用），
            // 在这里 flush 会提前补发（UP）或整段丢弃（CANCEL）它，并重置它的速度时钟。
        }

        // 识别器不再参与左键；保持它为空状态，避免旧候选在生命周期里残留。
        return;
    }

    if (fid >= 0 && fid < MAX_FINGERS && evIsDown) s_fingerDown[fid] = true;
    if (fid >= 0 && fid < MAX_FINGERS && evIsUp) s_fingerDown[fid] = false;

    // GrabEpoch carried owner 在普通 grabbed/normal 分支之前消费。MOVE 被吞掉；UP/CANCEL 只移除本 finger，
    // 共享该按钮 owner 的最后一根 finger 消失时才 releaseOwner，因此双指共享键不会提前 RELEASE。
    if (s_schemaActive && fid >= 0 && fid < MAX_FINGERS) {
        std::array<SchemaCarriedOwner, MAX_FINGERS * 4> released{};
        size_t releasedCount=0;
        pthread_mutex_lock(&s_schemaMutex);
        const bool isCarried=schemaCollectCarriedUpLocked(fid,evIsUp,released,releasedCount);
        pthread_mutex_unlock(&s_schemaMutex);
        if (isCarried) {
            for (size_t i=0; i<releasedCount; ++i) {
                inputLedger().releaseOwner(released[i].owner);
                amcl_fire_button_pressed(released[i].id.c_str(),0);
            }
            return;
        }
    }

    // ============ 指针派生的合成触摸包（滚轮 / 部分左键流）============
    //
    // 平台把**鼠标左键事件与轴（滚轮）事件**转换成触摸事件下发（官方指南
    // 《支持鼠标输入事件》§鼠标事件转换原文："系统提供兜底方案，会默认将鼠标左键
    // 事件、轴事件转换成触摸事件发送给应用"）。转换后它与真手指的元数据**完全
    // 相同**：source=TOUCHSCREEN、tool=FINGER（**API 24 平板**实测 618/618；
    // ⚠️ API 26 手机上 `source` 已恢复为 MOUSE，见 §34.3 —— 这条不可跨设备外推）。
    // ⚠️ 原文还写了「deviceId=0（三者均已实测）」：**deviceId 那一项当时没有被测过**，
    // 本文件下方为它专门加了 `AMCL_TOUCHID` 探针，至今未取到数据。不要当成已知事实。
    // 关闭它的 easyGo.mouse2TouchEventMode 在本机未被解析（module.json5 参考文档：
    // "easyGo 当前仅支持平行视界分栏能力"）。
    //
    // ⚠️ 上一版的致命顺序错误：分类只在 **MOVE** 上做，DOWN 一律放行进 schema。
    // 而 schema 在 DOWN 就做 hit-test 并**立刻发键**（handleSchemaGrabbedTouch 的
    // DOWN 分支）。LockCursor 把指针钉在屏幕某点，那点可以落在摇杆/按钮矩形内
    // （真机合成包坐标 48/1839 就在左下摇杆区），于是：
    //   滚轮 → 合成 DOWN → 绑成 JOYSTICK → 立刻 WASD PRESS → MOVE 才认出是滚轮。
    // 这就是"滚轮会轻微触发虚拟摇杆"。同理它也会按下指针下方的任意虚拟按键、
    // 直点物品栏槽位、触发长按。
    //
    // 现在**在 DOWN 就分类，判为指针派生的包根本不进 schema**（"鼠标绝不能点虚拟
    // 按键"这条规则对这条通道同样无条件成立）。DOWN 时可用的判据：
    //   1) 光标锁生效 —— 锁只在检测到物理鼠标并进入游戏后建立，纯触摸设备永不进入；
    //   2) 坐标是整数 —— 合成包通常为整数，手指也可能恰好落在整数位置。
    //      亚像素坐标只能排除这一条兼容候选，整数本身不能证明它来自物理鼠标；
    //   3) 落点与系统指针当前位置重合 —— OH_Input_GetPointerLocation（API 20，
    //      **无需权限**，仅要求本应用获焦）。这是一条与 1)/2) 独立的判据；该接口
    //      不可用时保留正常触控，不以1)+2)的弱证据丢掉手指DOWN。
    //
    // 误判的代价被刻意做小：判为指针派生的 finger 只是**不绑控件**；一旦后续样本
    // 出现分数坐标或横向位移（真手指的确定特征），立刻放行（census ptrDerivedPromoted），
    // 该 finger 从下一个包起按普通触摸处理。
    if (fid >= 0 && fid < MAX_FINGERS) {
        const bool integralPoint =
            px == std::floor(px) && py == std::floor(py);
        if (touchEvent.type == OH_NATIVEXCOMPONENT_DOWN) {
            s_wheelGestureActive[fid] = false;
            s_wheelGestureAnchorX[fid] = px;
            s_wheelGestureLastY[fid] = py;
            s_wheelGestureResidualPx[fid] = 0.0f;
            s_wheelGestureIntegral[fid] =
                amcl_cursor_lock_active() && integralPoint &&
                pointerDerivedDownAt(px, py);
            if (s_wheelGestureIntegral[fid]) {
                amcl::input::census::Bump(
                    amcl::input::census::Channel::TouchPointerDerivedDown);
                // DOWN 也必须 return：schema 的角色绑定与发键都在 DOWN 里。
                return;
            }
        } else if (s_wheelGestureIntegral[fid] &&
                   touchEvent.type == OH_NATIVEXCOMPONENT_MOVE) {
            const float wheelDy = py - s_wheelGestureLastY[fid];
            // ⚠️ 一旦本手势已被认定为滚轮（s_wheelGestureActive），就**不再允许放行**。
            // 真机 census11 显示 `ptrDerivedPromoted` 与 `ptrDerivedDown` 几乎逐条相等
            // （2/2、3/3），也就是说几乎每次滚轮都在滚到一半时被"放行"回普通触摸，
            // 于是后半段进了 schema —— 这就是"滚轮有时候还是会触发触屏"的原因。
            // 平台的合成滑动在收尾/惯性阶段会出现分数坐标或极小的横向抖动，
            // 而放行判据把这当成了"真手指的确定特征"。已经发出过 scroll 的手势
            // 不可能是手指，所以认定后一律锁定到终止边沿。
            const bool stillPointerDerived =
                s_wheelGestureActive[fid] ||
                (amcl_cursor_lock_active() && integralPoint &&
                 px == s_wheelGestureAnchorX[fid]);
            if (!stillPointerDerived) {
                // 分数坐标或横向位移 ⇒ 确定是真手指，判错了。放行并留下证据。
                s_wheelGestureIntegral[fid] = false;
                s_wheelGestureActive[fid] = false;
                s_wheelGestureResidualPx[fid] = 0.0f;
                s_wheelGestureLastY[fid] = py;
                amcl::input::census::Bump(
                    amcl::input::census::Channel::TouchPointerDerivedPromoted);
                // 不 return：本包起按普通触摸处理。DOWN 已被吞掉，所以它没有
                // schema binding，会被 MOVE 的 default 分支忽略，抬起后重按即恢复
                // 完整角色。宁可少一根手指的一次手势，也不能让鼠标按下虚拟键。
            } else {
                // 纵向阶跃达到识别阈值即认定为滚轮，此后整条手势锁定。
                if (!s_wheelGestureActive[fid] &&
                    (wheelDy >= kWheelIdentifyPx ||
                     wheelDy <= -kWheelIdentifyPx)) {
                    s_wheelGestureActive[fid] = true;
                    s_wheelGestureResidualPx[fid] = 0.0f;
                }
                s_wheelGestureLastY[fid] = py;
                if (s_wheelGestureActive[fid]) {
                    s_wheelGestureResidualPx[fid] += wheelDy;
                    // 分格 = 累计位移 ÷ 一格，残量留给下一包。旧实现"每个单帧
                    // ≥30px 的包发一格、其余包位移丢弃"在一格被拆包时会多发格数，
                    // 在两格合并成一个大包时又只发一格。
                    //
                    // 符号：官方指南《支持鼠标输入事件》§处理滚轮说明 PanGesture
                    // 语义下"向前滚动 offsetY 为正"；转换出的触摸流与之同向
                    // （都是内容跟手），故 Δy>0 = 向前滚 = GLFW +1。
                    // 运动学指纹是滚轮的**末选**通道（最脆弱：靠整数坐标与阶跃
                    // 幅度猜）。只有当 native AXIS、ArkTS onAxisEvent、轴驱动 Pan
                    // 三条都没在本设备上出现过时它才真的产出。
                    //
                    // 注意：让位只影响**是否发 scroll**，不影响上面的识别与抑制 ——
                    // 识别出来的滚轮包无论如何都不能落进虚拟摇杆/空白 look，
                    // 否则"滚轮转视角"会立刻回归。
                    const bool wheelOwned =
                        ohos_wheel_channel_claim(AMCL_INPUT_CHANNEL_TOUCH_WHEEL);
                    int emitted = 0;
                    while (s_wheelGestureResidualPx[fid] >= kWheelNotchPx &&
                           emitted < kWheelMaxStepsPerPacket) {
                        s_wheelGestureResidualPx[fid] -= kWheelNotchPx;
                        if (wheelOwned) {
                            amcl::input::census::Bump(
                                amcl::input::census::Channel::TouchWheelScroll);
                            // ⚠️ 本通道（TOUCH_WHEEL）自报 PHYSICAL_KBM —— 它**就是**
                            // 物理滚轮，只是被平台镜像成触摸包。所以路由位为真时它
                            // 与 ArkTS 两条通道一起走 typed 平面。**API 24 平板的滚轮
                            // 载体正是这一条**（计划 §94.3 实测），所以这是本批唯一
                            // 会改变平板行为的调用点。
                            // gateAccepted=true：已在 SurfaceInputGateCallbackScope 内
                            // （与上方 TOUCH_MIRROR 左键那处同一个先例）。
                            routerScroll(AMCL_INPUT_SOURCE_PHYSICAL_KBM, 0, 1,
                                         true);
                        }
                        emitted++;
                    }
                    while (s_wheelGestureResidualPx[fid] <= -kWheelNotchPx &&
                           emitted < kWheelMaxStepsPerPacket) {
                        s_wheelGestureResidualPx[fid] += kWheelNotchPx;
                        if (wheelOwned) {
                            amcl::input::census::Bump(
                                amcl::input::census::Channel::TouchWheelScroll);
                            routerScroll(AMCL_INPUT_SOURCE_PHYSICAL_KBM, 0, -1,
                                         true);
                        }
                        emitted++;
                    }
                    // 常开取证（上限 40 条）：用它校准 kWheelNotchPx。
                    static std::atomic<int> wheelProbe{0};
                    if (wheelProbe.fetch_add(1, std::memory_order_relaxed) < 40) {
                        OH_LOG_INFO(LOG_APP,
                                    "AMCL_WHEEL touch dy=%{public}.1f "
                                    "residual=%{public}.1f steps=%{public}d "
                                    "y=%{public}.1f",
                                    (double)wheelDy,
                                    (double)s_wheelGestureResidualPx[fid],
                                    emitted, (double)py);
                    }
                }
                return;  // 指针派生：绝不进 schema，也绝不产生视角
            }
        } else if (s_wheelGestureIntegral[fid]) {
            // UP / CANCEL / unknown —— 终止边沿一律在这里收口并清状态。
            //
            // ⚠️ 旧代码写的是 `else if (evIsUp)`，而 evIsUp 只含 UP/CANCEL；
            // type 为 unknown 时既进不了这里、又被下面那句守卫 return 掉，
            // schema 永远收不到终止边沿。现在把 unknown 一并归到终止分支
            // （handleSchemaGrabbedTouch 的注释本来就承诺"unknown 是不安全的终止边沿"）。
            s_wheelGestureActive[fid] = false;
            s_wheelGestureIntegral[fid] = false;
            s_wheelGestureResidualPx[fid] = 0.0f;
            // DOWN 已被吞掉 ⇒ 这个 fid 在 schema 里没有 binding，无需 detach；
            // 但 s_fingerDown 等触摸层记账仍要走完，故不 return。
        }
    }

    // desktop API22+ is a physical-device product.  Mouse-derived packets were
    // deliberately handled above (explicit mirror identity first, pointer-
    // derived wheel fallback second); every remaining packet is direct screen
    // touch/pen and must not enter either Control Schema or Minecraft's menu
    // pointer transaction.  API<22 desktopLegacy keeps the mobile fallback,
    // and all phone/tablet products preserve the historical touch frontend.
    if (!amcl::input::ProductAcceptsDirectTouchInGame()) {
        static std::atomic<uint64_t> rejectedDirectTouch{0u};
        const uint64_t count = rejectedDirectTouch.fetch_add(
            1u, std::memory_order_relaxed) + 1u;
        if (firstOrPowerOfTwo(count)) {
            const auto policy = amcl::input::GetProductInputPolicy();
            OH_LOG_INFO(LOG_APP,
                        "AMCL_DESKTOP_TOUCH rejected=%{public}llu "
                        "api=%{public}u fid=%{public}d type=%{public}d",
                        static_cast<unsigned long long>(count),
                        policy.runtimeApi, fid,
                        static_cast<int>(touchEvent.type));
        }
        return;
    }

    // 先按已核实的物理镜像/滚轮分类，再关闭direct touch的新DOWN。被围栏丢弃的整段
    // 接触保持dead到真实UP，解除围栏后MOVE不能补领新schema。旧角色MOVE/UP继续原链路。
    if (evIsDown && touchAdmissionBlocksNewTouchLocked()) {
        if (fid >= 0 && fid < MAX_FINGERS) s_fingerDead[fid] = true;
        return;
    }
    if (evIsDown) {
        pthread_mutex_lock(&s_schemaMutex);
        const bool groupBlocked = s_touchGroups.BlocksPoint(px, py, s_schema);
        pthread_mutex_unlock(&s_schemaMutex);
        if (groupBlocked) {
            if (fid >= 0 && fid < MAX_FINGERS) s_fingerDead[fid] = true;
            return;
        }
    }

    // Phase 1：跨 grab 翻转仍按着的（非 carried）手指——忽略其后续事件直到抬起，杜绝其在新模式里被
    // 重新解释成 look/点击（根除直接点菜单按钮返回游戏的视角瞬移 + 卡键）。抬起时清状态、恢复该 fid。
    if (fid >= 0 && fid < MAX_FINGERS && s_fingerDead[fid]) {
        if (evIsUp) {
            s_fingerDead[fid] = false;
            // lifecycle/schema NAPI 可与触摸回调并发；即使 binding 通常已在 grab reset 中清空，
            // 这里仍必须遵守 touch→schema 锁序，不能在 schema replace 正遍历/重置时裸写数组。
            pthread_mutex_lock(&s_schemaMutex);
            s_schemaFingers[fid] = SchemaFingerBinding{};
            pthread_mutex_unlock(&s_schemaMutex);
        }
        return;
    }

    // 触控解释权的未来扩展点：物理镜像和失效手指已被过滤，尚未认领本次DOWN。
    // TouchController接入应在此按已握手的surface/session选择唯一解释器，并冻结到UP/CANCEL；
    // 不能放到菜单分支或发键之后，不能在MOVE中途切换。当前只接内建解释器，无外部代理。
    if (grabbed) {
        // ====== Grabbed 模式：视角增量，但过滤掉摇杆/按钮区域的触摸 ======
        // ArkTS hitTestBehavior.Block 无法阻止 Native DispatchTouchEvent
        // 所以必须在 C 层检查坐标，忽略落在 UI 控件区域的手指
        if (fid < 0 || fid >= MAX_FINGERS) return;

        // 触控虚拟按键端的唯一解释器。
        //
        // ⚠️ 2026-08-19：这里曾有一个 `if (s_schemaActive) { ...; return; } else { 旧 s_buttons
        // 分支 }`。`s_schemaActive` 定义为 `static bool = true` 且**全仓没有任何赋值点**，
        // 所以那个 else 分支自上线起从未执行过。连带死掉的还有 `isInJoystick` / `hitButton`
        // / `s_buttons` / `s_joy*` 以及 ArkTS 每次布局重建都在调用的
        // `registerButton` / `registerJoystick` / `clearButtons` / `clearJoystick`
        // ——那是一条"每次 rebuild 都跨 NAPI 填一张没人读的表"的活跃写路径。
        // 整条 legacy 回退已删除；保留一个恒真分支只会让下次读代码的人以为存在两种模式。
        (void)handleSchemaGrabbedTouch(touchEvent, px, py, fid);
        return;
    } else {
        // 所有菜单模式共用认领规则；默认直触也必须尊重显式右键、UI面板和取消。
        // 只更新指针的手指不能额外按下左键，ArkUI认领的手指全程不穿透到游戏。
        pthread_mutex_lock(&s_schemaMutex);
        // 普通按钮在菜单也由同一 Native 手势解释器处理，ArkUI 只绘制。系统入口
        // 仍属于 UI；背景菜单继续原 MenuTouchInteraction，不复制点击/视角解释器。
        const bool groupButton = schemaOwnsMenuButtonLocked(fid,evIsDown,px,py);
        if (groupButton) {
            pthread_mutex_unlock(&s_schemaMutex);
            (void)handleSchemaGrabbedTouch(touchEvent,px,py,fid);
            return;
        }
        if (fid >= 0 && fid < MAX_FINGERS) {
            if (touchEvent.type == OH_NATIVEXCOMPONENT_DOWN || touchEvent.type == OH_NATIVEXCOMPONENT_MOVE)
                s_touchMenuCursorVisible.store(true,std::memory_order_release);
            auto& binding = s_schemaFingers[fid];
            AmclCtrlEntry hit{};
            const bool overOverlay = touchOverlayContains(s_menuMouseBounds,px,py) || touchOverlayContains(s_touchGuideBounds,px,py);
            if (touchEvent.type == OH_NATIVEXCOMPONENT_DOWN && (overOverlay || schemaHitTestLocked(px,py,hit))) {
                binding = SchemaFingerBinding{};
                binding.role = SCHEMA_FINGER_ARKTS;
            } else if (binding.role != SCHEMA_FINGER_ARKTS) {
                const auto phase = touchEvent.type == OH_NATIVEXCOMPONENT_DOWN ? amcl::input::TouchPhase::Down :
                    touchEvent.type == OH_NATIVEXCOMPONENT_MOVE ? amcl::input::TouchPhase::Move :
                    touchEvent.type == OH_NATIVEXCOMPONENT_UP ? amcl::input::TouchPhase::Up : amcl::input::TouchPhase::Cancel;
                s_menuTouch.SetExternalButtonsHeld(inputLedger().isHeld({OutputKind::Mouse,0}) ||
                                                   inputLedger().isHeld({OutputKind::Mouse,1}) || menuToolMouseHeldLocked());
                s_menuTouch.Event(phase,fid,px,py,touchEvent.timeStamp > 0 ? touchEvent.timeStamp : schemaNowNs(),
                                  emitMenuInteraction);
                if (s_menuTouch.Deadline() > 0) schemaWakeDeadlineWorker();
            }
            if (evIsUp) binding = SchemaFingerBinding{};
        }
        pthread_mutex_unlock(&s_schemaMutex);
    }
}

// ==================== NAPI 可调用函数 ====================

/** 有界临时热区独立于schema代次；只更新新触点命中，不触碰当前控件、菜单事务或持有账本。 */
static bool setTouchOverlayBounds(double bounds[4],double x,double y,double w,double h) {
    if(!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(w) || !std::isfinite(h) ||
       x<0 || y<0 || w<0 || h<0 || x+w>65535 || y+h>65535 || ((w==0)!=(h==0))) return false;
    std::lock_guard<std::mutex> touchLock(s_touchStateMutex);
    pthread_mutex_lock(&s_schemaMutex);
    bounds[0]=x; bounds[1]=y; bounds[2]=w; bounds[3]=h;
    pthread_mutex_unlock(&s_schemaMutex);
    return true;
}

/** 菜单鼠标移动/关闭不退休拖动；世界分支不读取这一菜单专用区域。 */
extern "C" bool ohos_set_menu_mouse_bounds(double x,double y,double w,double h) {
    return setTouchOverlayBounds(s_menuMouseBounds,x,y,w,h);
}

/**
 * 实际面板bounds与实例认领同事务提交；NAPI已核publication归属，此处再次用不透明身份绑定。
 * 合法非零bounds是唯一注册入口，同实例的几何移动保持held；新实例只可在零held接管，
 * 且同publication须超过单调水位。旧实例迟到clear/重发均不能把当前面板注销或反抢。
 * 按touch→schema→transaction取锁，避免登记时从transaction反向进入schema setter。
 */
extern "C" bool ohos_set_menu_mouse_bounds_for_panel(double x,double y,double w,double h,
        const char* prefix,uint64_t publication) {
    uint64_t identity=0;
    if(publication==0 || !parseMenuToolPanelPrefix(prefix,&identity) || !std::isfinite(x) || !std::isfinite(y) ||
       !std::isfinite(w) || !std::isfinite(h) || x<0 || y<0 || w<0 || h<0 || x+w>65535 || y+h>65535 || ((w==0)!=(h==0))) return false;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    pthread_mutex_lock(&s_schemaMutex);
    // 新登记必须仍属于实际打开面板的组入口，不能由隐藏后的旧面板重新认领本体。
    // 空矩形清理始终允许继续，直到原工具作用域确认结束。
    if (w > 0 && s_touchGroups.Enabled() && (s_groupMouseControl < 0 ||
        !s_touchGroups.Visible(s_groupMouseControl) || s_touchGroups.BlocksControl(s_groupMouseControl,s_schema))) {
        pthread_mutex_unlock(&s_schemaMutex); return false;
    }
    bool accepted=false;
    {
        std::lock_guard<std::recursive_mutex> transaction(s_inputTransactionMutex);
        reconcileMenuToolProcessLocked();
        const bool samePrefix=s_menuToolPanelPrefix==prefix;
        const bool samePublication=s_menuToolRegistrationPublication==publication;
        if(w==0) {
            if(samePrefix) {
                inputBridge_retireTouchMenuToolScopeV1();releaseMenuToolControls();accepted=true;
            } else if(s_menuToolPanelPrefix.empty() && s_menuToolOwners.empty()) {
                // 按端reset/grab已先退休登记时，空域的清除是幂等成功，同时去掉旧热区。
                // 不再推进工具epoch；若已有另一实例登记仍拒绝，旧UI不能清掉新面板。
                // 明确回执让Entry结束关闭重试，否则此正常先后次序会每16ms重新取整条锁链。
                accepted=true;
            }
        } else if(samePrefix || (s_menuToolOwners.empty() && (!samePublication || identity>=s_menuToolPanelWatermark))) {
            if(!samePrefix) {inputBridge_retireTouchMenuToolScopeV1();releaseMenuToolControls();}
            if(!samePublication) s_menuToolPanelWatermark=0;
            s_menuToolRegistrationPublication=publication;
            s_menuToolPanelWatermark=std::max(s_menuToolPanelWatermark,identity);
            s_menuToolPanelPrefix=prefix;accepted=true;
        }
        if(accepted) {s_menuMouseBounds[0]=x;s_menuMouseBounds[1]=y;s_menuMouseBounds[2]=w;s_menuMouseBounds[3]=h;}
    }
    pthread_mutex_unlock(&s_schemaMutex);
    return accepted;
}

/** 教学工具栏在世界和菜单共用，隐藏、后台或销毁均发布空矩形。 */
extern "C" bool ohos_set_touch_guide_bounds(double x,double y,double w,double h) {
    return setTouchOverlayBounds(s_touchGuideBounds,x,y,w,h);
}

// ⚠️ `ohos_register_button` / `ohos_register_joystick` / `ohos_set_comp_size` 已删除
// （连同 NAPI 入口与 ArkTS 调用点）。它们写入的表/变量没有任何读取方，
// 详见文件上方的墓碑与计划 §64.3。

// 物理键鼠端的视角入口。
//
// 它被 ingress 以**函数指针**注入（`PlatformInputUnverifiedRelativeFallbackTransaction`
// 的签名是 `bool(double,double)`），所以签名不能加参数 —— 端身份在函数体里给定。
// 这条路径的两个 ingress 使用点都是物理鼠标 rawDelta，不存在其它端复用。
extern "C" bool ohos_send_cursor_delta_checked(double dx, double dy) {
    // Checked bridge boundary is independently hardened even though physical
    // NAPI rejects earlier. Synthetic/direct callers cannot turn a NaN/Inf into
    // a generic bridge failure or reach applyLookDelta's persistent state.
    if (!finitePair(dx, dy)) {
        recordInvalidLookDelta();
        return false;
    }
    resolveBridge();
    if (!s_addLookDeltaFn) return false;
    // 三端共用灵敏度、倒置、加速与守恒 backlog；端级量纲归一在 applyLookDelta 内部完成。
    // 调用方只传原始增量，不得自行改写 bridge 坐标。
    return applyLookDelta(AMCL_INPUT_SOURCE_PHYSICAL_KBM, dx, dy);
}

extern "C" bool ohos_send_cursor_delta_at_time_checked(
        double dx, double dy, uint64_t monotonicTimeNs) {
    if (monotonicTimeNs == 0u || monotonicTimeNs > INT64_MAX || !finitePair(dx, dy)) return false;
    return applyLookDelta(AMCL_INPUT_SOURCE_PHYSICAL_KBM, dx, dy,
                          static_cast<int64_t>(monotonicTimeNs));
}

// 合成视角增量入口，**按端申报**。
//
// 这条入口同时服务两个端：手柄右摇杆，以及触控虚拟按键端里 `handledBy=arkts` 按钮的
// dragLook。手柄是轴速度积分后的virtual px；dragLook已在ArkUI入口由vp转换为surface px，
// 所以端身份必须由调用方给出，不能在 native 猜。
//
// 旧实现把两者一律标成手柄端。当时没有行为后果（三端的 look_scale 都是 1.0），
// 但它让 `lookPad` 计数实际变成"手柄 + 触控 dragLook"，一旦开始做量纲标定就会把
// 触控端的位移按手柄系数缩放。端拆开之后，量纲标定可以逐端独立进行。
extern "C" bool ohos_send_source_cursor_delta_checked(int source, double dx,
                                                      double dy) {
    return ohos_send_source_cursor_sample_checked(source, dx, dy, 0);
}

extern "C" bool ohos_send_source_cursor_sample_checked(int source, double dx,
                                                       double dy, int64_t sampleTimeNs) {
    // 实体鼠标必须走自己的通道资格及采样事务，不能借合成入口绕过typed/legacy仲裁。
    if ((source != AMCL_INPUT_SOURCE_TOUCH_CONTROLS && source != AMCL_INPUT_SOURCE_GAMEPAD) ||
        sampleTimeNs < 0) return false;
    if (!finitePair(dx, dy)) {
        recordInvalidLookDelta();
        return false;
    }
    resolveBridge();
    if (!s_addLookDeltaFn) return false;
    return applyLookDelta(normalizeInputSource(source), dx, dy, sampleTimeNs);
}

// ⚠️ 未申报端身份的兼容入口，保留只为 fail-soft；新调用点一律用
// `ohos_send_source_cursor_delta_checked`。
//
// 标 `AMCL_INPUT_SOURCE_NONE` 而不是沿用旧行为的 `AMCL_INPUT_SOURCE_GAMEPAD`：
// 这条入口的全部价值就是**让漏改的调用点
// 可被发现**。标成手柄端的话，一个忘了申报的 look 生产者会伪装成正常的手柄 look，
// 在端普查里完全看不出来 —— 那就等于没有 fail-soft。标 NONE 会让它出现在
// `AMCL_INSRC looks untagged` 一栏。行为无变化：三端与 NONE 的 look_scale 都是 1.0。
extern "C" void ohos_send_cursor_delta(double dx, double dy) {
    (void)ohos_send_source_cursor_delta_checked(AMCL_INPUT_SOURCE_NONE, dx, dy);
}

// 物理鼠标端在菜单模式下的唯一入口。参数是系统指针在组件内的**绝对位置**（物理 px），
// 语义就是"菜单光标应当在这里"。
//
// ⚠️ 不要再试图把它改成增量/带偏移的语义。菜单模式下系统指针箭头是可见的，而我们无法移动它；
// 一旦菜单光标与箭头分离，MC 的悬浮高亮与点击判定就会落到箭头之外。已实测并回退，
// 详见 input_bridge_ohos.c 的"菜单光标必须是绝对映射"一节。
//
// 绝对位置只进入菜单坐标；v7 ABI 从类型层面禁止它覆盖 grabbed look 累加量。
//
// 渲染缩放：本入口的调用方（NAPI 的 LegacyMenuAbsolute vp×density 及兼容入口）
// 一律传 real surface 物理 px；bridge 侧的 g_menuX/Y 属 MC 窗口坐标系（= 缩放后
// buffer px），换算在此单点完成（scale==1 时恒等直通）。
extern "C" bool ohos_send_cursor_pos_checked(double x, double y) {
    if (!finitePair(x, y)) {
        recordNonFiniteMenuPosition();
        return false;
    }
    resolveBridge();
    if (!s_setMenuCursorFn) return false;
    setMenuCursor(amcl::renderscale::MapX(x), amcl::renderscale::MapY(y));
    // 此入口是已接受的外部绝对位置；相对触摸板空闲时承接它，下一次落指不跳回旧位置。
    pthread_mutex_lock(&s_schemaMutex);
    s_menuTouch.AdoptCursor(x,y);
    pthread_mutex_unlock(&s_schemaMutex);
    return true;
}

extern "C" void ohos_send_cursor_pos(double x, double y) {
    (void)ohos_send_cursor_pos_checked(x, y);
}

extern "C" int ohos_is_grabbed() {
    return isGrabbedMode() ? 1 : 0;
}

// 方案 D（②）：ArkTS 侧发事件（菜单按钮 / ime_chat / 抽屉子按钮 / 手柄 / 物理键盘 / IME）也经 InputRouter，
// 使"当前按下集合"成为唯一真相（含 C 解释器 + ArkTS 两路），routerReleaseAll 覆盖全部来源、单一 release-all。
// ⚠️ 未申报端身份的兼容入口。新调用点一律用 `ohos_send_source_key_event_checked`。
// 保留它是为了 fail-soft：漏改的调用点仍然可用，只是持有记录标成 NONE，
// 在端级复位日志的 `untagged` 一栏里可见。
extern "C" bool ohos_send_key_event_checked(int key, int scancode, int action, int mods) {
    return ohos_send_source_key_event_checked(AMCL_INPUT_SOURCE_NONE, key,
                                              scancode, action, mods);
}

// 调用方（NAPI）至多持有递归的 surface gate，因此可以在路由之前对账 ring 不连续 epoch：
// 丢过历史之后的第一次按下落在已复位的账本上，才能真正发出 PRESS。
extern "C" bool ohos_send_source_key_event_checked(
        int source, int key, int scancode, int action, int mods) {
    reconcileLegacyRingDiscontinuity();
    resolveBridge();
    if (!bridgeReady()) return false;
    return routerKey(normalizeInputSource(source), key, scancode,
                     action, mods);
}

extern "C" uint64_t ohos_acquire_source_control(int source, uint64_t deviceId,
        const char* controlId, const int* codes, uint32_t count) {
    std::lock_guard<std::recursive_mutex> gateLock(s_surfaceInputGateMutex);
    if (source == AMCL_INPUT_SOURCE_TOUCH_CONTROLS && s_touchAdmission.BlocksNewTouch()) return 0;
    reconcileLegacyRingDiscontinuity();
    resolveBridge();
    if (!bridgeReady() || !controlId || !codes || count == 0u || count > 6u ||
        (source != AMCL_INPUT_SOURCE_TOUCH_CONTROLS && source != AMCL_INPUT_SOURCE_GAMEPAD &&
         source != AMCL_INPUT_SOURCE_PLATFORM_GESTURE)) return 0u;
    std::vector<Output> outputs;
    for (uint32_t i = 0; i < count; ++i) {
        Output output{};
        if (!amcl::input::DecodeLegacySchemaOutputCode(codes[i], &output)) return 0u;
        // 组合键保留首次出现顺序；重复码只持有一次，避免合法旧布局被新token边界拒绝。
        const bool duplicate = std::any_of(outputs.begin(), outputs.end(), [&output](const Output& prior) {
            return prior.kind == output.kind && prior.code == output.code;
        });
        if (!duplicate) outputs.push_back(output);
    }
    const amcl::input::ExternalControlIdentity identity{
        normalizeInputSource(source), deviceId, controlId};
    return amcl::input::SourceAcquireControl(identity,outputs);
}

extern "C" bool ohos_release_source_control(uint64_t token) {
    // 释放不要求 surface/bridge 就绪：失焦后仍须收回账本，已复位的旧 token 是幂等成功。
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    const bool released = amcl::input::SourceReleaseControl(token);
    if (released) for (auto& owner : s_groupUiOwners) if (owner.token == token) owner = GroupUiOwner{};
    return released;
}

static void releaseMenuToolControls(bool retireRegistration) {
    // 原生owner与累计统计在同一公共事务里退休；先清完整集合，再发每码一次末松，
    // 旧UI的重复UP只能得到幂等成功。调用方先持touch，scope退休时还已推进bridge epoch。
    std::lock_guard<std::recursive_mutex> transaction(s_inputTransactionMutex);
    reconcileMenuToolProcessLocked();
    bool left=false,right=false,shift=false;
    for(const auto& item:s_menuToolOwners) {
        left |= item.second.code == -1; right |= item.second.code == -2; shift |= item.second.code == 340;
    }
    s_menuToolReleased += static_cast<uint32_t>(s_menuToolOwners.size());
    s_menuToolOwners.clear();
    if(retireRegistration) s_menuToolPanelPrefix.clear();
    // 鼠标先松、修饰键末松。neutral只改变tool贡献，ordinary/typed同码仍按首按末松持有。
    if(left) inputBridge_pushTouchMenuToolV1(-1,GLFW_RELEASE);
    if(right) inputBridge_pushTouchMenuToolV1(-2,GLFW_RELEASE);
    if(shift) inputBridge_pushTouchMenuToolV1(340,GLFW_RELEASE);
}

/** 真实surface切换先撤销消费队列，再关闭Native工具租约；无触点也不可继承旧pending工具输入。 */
static void retireTouchMenuSurfaceScope() {
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    inputBridge_retireTouchMenuScopeV1();
    releaseMenuToolControls();
}

/**
 * 面板的显式取消事务：在surface→touch→transaction内先退休neutral工具epoch，
 * 再闭合Native冻结owner集合和累计统计。普通UP仍调用ohos_touch_menu_button(false)，
 * 不能把CANCEL解释成一对正常点击；已经UP但尚未poll的1011也由此退休。
 * 本入口不要求surface仍活跃、菜单模式或旧publication仍有效，取消必须能独立收口。
 * true表示本prefix原租约已同步退休，或其旧域已经结束；不匹配的新面板可能仍持有。
 * 消费者在自己的线程释放已提交贡献，不把返回值宣称为游戏线程已经收到UP。
 * direct/ordinary/typed及全touch会话不换代。
 */
extern "C" bool ohos_cancel_touch_menu_mouse(const char* panelPrefix) {
    if (!panelPrefix || !*panelPrefix || std::strlen(panelPrefix)>192) return false;
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    pthread_mutex_lock(&s_schemaMutex);
    bool accepted=true;
    {
        std::lock_guard<std::recursive_mutex> transaction(s_inputTransactionMutex);
        reconcileMenuToolProcessLocked();
        // 旧实例只确认自己的域已结束，不推进新epoch；当前实例先退输入再承接实际已消费反馈。
        if(!s_menuToolPanelPrefix.empty() && s_menuToolPanelPrefix==panelPrefix) {
            inputBridge_retireTouchMenuToolScopeV1();releaseMenuToolControls(false);
            if(!s_menuTouch.DirectActive() && !adoptCommittedMenuCursorLocked())
                s_touchMenuCursorVisible.store(false,std::memory_order_release);
            accepted=s_menuToolOwners.empty();
        }
    }
    pthread_mutex_unlock(&s_schemaMutex);
    return accepted;
}

/**
 * 成对菜单工具持有，只管理Left/Right/Shift独立来源。control由面板实例加命名空间，
 * 按下冻结全局不复用token与code；最多32个owner。同码首按末松后通过scoped TOOL
 * 发布，禁止进入common ledger，否则模态不能撤销本来源而保留实体/手柄同码持有。
 * UP只解释原code；退休后的旧UP幂等且不会补发点击。函数始终按touch→schema→transaction取锁。
 */
extern "C" bool ohos_touch_menu_button(const char* control,int code,bool down,uint64_t publication) {
    if(!control || !*control || std::strlen(control)>192 || (code!=-1 && code!=-2 && code!=340)) return false;
    // 不连续对账自身会取得touch锁，必须在菜单事务锁外完成，不能从Acquire包装入口重入。
    if(down) { reconcileLegacyRingDiscontinuity(); resolveBridge(); if(!bridgeReady()) return false; }
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    std::lock_guard<std::mutex> lock(s_touchStateMutex);
    // 真实grab公告可能进入schema→transaction退休，必须先消费，再取更内层transaction。
    if(down && (s_touchPaused.load(std::memory_order_acquire) || consumeGrabEpochLocked(isGrabbedMode()))) return false;
    if(down) {
        // Native边界也核真实current与已确认token，不能只凭前一次NAPI检查或未刷新的fenced布尔值。
        // 原新DOWN资格保持严格：待发布fence关闭所有新owner，continuation例外不用于按下。
        pthread_mutex_lock(&s_schemaMutex);
        const auto current = touchPublicationContextLocked();
        (void)s_touchAdmission.Query(current);
        const bool allowed = current.surface != 0 && !current.grabbed && s_touchAdmission.AcceptsUiToken(publication);
        pthread_mutex_unlock(&s_schemaMutex);
        if(!allowed) return false;
    }
    std::lock_guard<std::recursive_mutex> transaction(s_inputTransactionMutex);
    reconcileMenuToolProcessLocked();
    const auto found=s_menuToolOwners.find(control);
    if(!down) {
        if(found==s_menuToolOwners.end()) return true;
        // 释放使用冻结绑定，不读本次code。先摘old owner，检查同码剩余引用后再发末松。
        const int oldCode=found->second.code;
        s_menuToolOwners.erase(found); ++s_menuToolReleased;
        const bool stillHeld=std::any_of(s_menuToolOwners.begin(),s_menuToolOwners.end(),
            [oldCode](const auto& item){return item.second.code==oldCode;});
        if(!stillHeld) inputBridge_pushTouchMenuToolV1(oldCode,GLFW_RELEASE);
        return true;
    }
    // DOWN只使用可视bounds注册的实例，不以“零held”作新实例认领许可。
    const std::string controlIdentity(control);
    const auto delimiter=controlIdentity.find(':');
    if(delimiter==std::string::npos || !menuToolPanelMatchesLocked(controlIdentity.substr(0,delimiter+1).c_str(),publication)) return false;
    // 同身份重试也必须先通过实例/publication准入，再接受原绑定；不能用旧租约
    // 绕过新publication尚未重新注册的边界，持有期间改码仍然拒绝。
    if(found!=s_menuToolOwners.end()) return found->second.code==code;
    if(s_menuToolOwners.size()>=32) return false;
    const uint64_t owner=amcl::input::SourceNextNativeOwner();
    if(!owner) return false;
    const bool alreadyHeld=std::any_of(s_menuToolOwners.begin(),s_menuToolOwners.end(),
        [code](const auto& item){return item.second.code==code;});
    s_menuToolOwners.emplace(control,MenuToolOwner{owner,code}); ++s_menuToolAcquired;
    if(!alreadyHeld) inputBridge_pushTouchMenuToolV1(code,GLFW_PRESS);
    if(code<0) { ++s_touchGuide.mouseButton; s_touchGuide.mouseCode=code; }
    return true;
}

/** 滚轮与指针一样只准入菜单，JS抓取回调迟到时也不能滚动游戏快捷栏。 */
extern "C" bool ohos_touch_menu_scroll(int steps,const char* prefix,uint64_t publication) {
    if(steps==0 || steps < -32 || steps > 32 || s_touchPaused.load(std::memory_order_acquire)) return false;
    reconcileLegacyRingDiscontinuity(); resolveBridge(); if(!bridgeReady()) return false;
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    std::lock_guard<std::mutex> lock(s_touchStateMutex);
    if(consumeGrabEpochLocked(isGrabbedMode())) return false;
    pthread_mutex_lock(&s_schemaMutex);
    bool accepted=false;
    {
        std::lock_guard<std::recursive_mutex> transaction(s_inputTransactionMutex);
        reconcileMenuToolProcessLocked();
        // 只延续已确认token和已登记prefix；不会为pending新UI登记实例或取得新的按钮owner。
        accepted=touchAdmissionAcceptsUiContinuationLocked(publication) &&
            menuToolPanelMatchesLocked(prefix,publication) && emitScopedMenuScroll(0,steps,true);
    }
    pthread_mutex_unlock(&s_schemaMutex);
    return accepted;
}

extern "C" void ohos_send_key_event(int key, int scancode, int action, int mods) {
    (void)ohos_send_key_event_checked(key, scancode, action, mods);
}

// ⚠️ 同上：未申报端身份的兼容入口，新调用点用 `ohos_send_source_mouse_event_checked`。
extern "C" bool ohos_send_mouse_event_checked(int button, int action, int mods) {
    return ohos_send_source_mouse_event_checked(AMCL_INPUT_SOURCE_NONE, button,
                                                action, mods);
}

extern "C" bool ohos_send_source_mouse_event_checked(
        int source, int button, int action, int mods) {
    reconcileLegacyRingDiscontinuity();   // 同 ohos_send_source_key_event_checked
    resolveBridge();
    if (!bridgeReady()) return false;
    return routerMouse(normalizeInputSource(source), button, action,
                       mods);
}

extern "C" void ohos_send_mouse_event(int button, int action, int mods) {
    (void)ohos_send_mouse_event_checked(button, action, mods);
}

// ⚠️ 未申报端身份的兼容入口，新调用点用 `ohos_send_source_scroll_event_checked`。
// gateAccepted 传 false 是**如实**的：本入口不持有 SurfaceInputGateTransaction。
// 它只会送 `AMCL_INPUT_SOURCE_NONE`，而 typed 分叉只认
// `AMCL_INPUT_SOURCE_PHYSICAL_KBM`，所以该值在本入口上不会被读到。
extern "C" bool ohos_send_scroll_event_checked(int xoffset, int yoffset) {
    return ohos_send_source_scroll_event_checked(AMCL_INPUT_SOURCE_NONE, xoffset,
                                                yoffset, false);
}

// 滚轮不进 owner 域（无持续按下态），端身份在这里只用于**普查可分**：
// "这一格快捷栏是手柄 L1 切的、屏幕滚轮条滑的、还是物理滚轮滚的"必须能在日志里区分，
// 否则"滚轮方向反了 / 时好时坏"这类问题又只能靠猜（§35 就是这么查了整轮）。
// ⚠️ `gateAccepted` 只在 typed 分叉上被读到（`AMCL_INPUT_SOURCE_PHYSICAL_KBM` +
// 路由位为真），调用方必须在
// 整个调用期间持有它所报告的那个 SurfaceInputGateTransaction —— 与 key/button 两条
// 事务同一条约束。legacy 分支不读它（legacy ring 的门在 `physicalEdgeRouter` 那边）。
// ⚠️ 已知耦合（不是本批修）：下面的 `bridgeReady()` 是 **legacy ring** 的前置，而 typed
// 那条不写 ring ⇒ 桥没解析出来时 typed 滚轮会被这一句一起挡掉。真实会话里它恒为真
// （游戏跑起来的前提），保留是为了不在无法真机复测的地方改控制流。见计划 §95.3。
extern "C" bool ohos_send_source_scroll_event_checked(int source, int xoffset,
                                                      int yoffset,
                                                      bool gateAccepted) {
    resolveBridge();
    if (!bridgeReady()) return false;
    return routerScroll(normalizeInputSource(source), xoffset, yoffset,
                        gateAccepted);
}

extern "C" void ohos_send_scroll_event(int xoffset, int yoffset) {
    (void)ohos_send_scroll_event_checked(xoffset, yoffset);
}

extern "C" AmclLegacyPhysicalOutcome
ohos_route_physical_key_event_checked(
        uint64_t deviceId, uint32_t ohosKeyCode, int mappedKey,
        int /*scancode*/, int action, int /*mods*/, int* routedMappedKey) {
    if (routedMappedKey) *routedMappedKey = -1;
    resolveBridge();

    LegacyPhysicalAction routeAction;
    if (action == GLFW_PRESS) {
        routeAction = LegacyPhysicalAction::Down;
    } else if (action == GLFW_REPEAT) {
        routeAction = LegacyPhysicalAction::Repeat;
    } else if (action == GLFW_RELEASE) {
        routeAction = LegacyPhysicalAction::Up;
    } else {
        return AMCL_LEGACY_PHYSICAL_INVALID_ACTION;
    }

    // ---- 键盘普查（2026-08-19 新增）----
    // 此前整条键盘链**没有任何计数器**，于是"ESC 快按之后失灵"这类问题在日志里完全
    // 不可见，只能靠读代码猜。判读方式见 input_channel_census.h 的 KeyDown 一段。
    using amcl::input::census::Bump;
    using amcl::input::census::Channel;
    if (routeAction == LegacyPhysicalAction::Down) {
        Bump(Channel::KeyDown);
    } else if (routeAction == LegacyPhysicalAction::Repeat) {
        Bump(Channel::KeyRepeat);
    } else {
        Bump(Channel::KeyUp);
    }

    const Output mappedOutput{OutputKind::Key, mappedKey};
    const Output* mapped = mappedKey > 0 ? &mappedOutput : nullptr;
    const LegacyPhysicalIdentity identity{
        OutputKind::Key, deviceId, ohosKeyCode};
    const AmclLegacyPhysicalOutcome outcome = physicalEdgeRouter().Route(
        bridgeReady(), identity, mapped, routeAction,
        routeAction == LegacyPhysicalAction::Down ? nextOwnerToken() : 0,
        routedMappedKey);

    // ownerless 边沿：ArkTS 判成 Repeat/Up，但 native 这边该身份已经没有 owner
    // ⇒ 两侧状态失步，这个键从此不再产生 PRESS（用户表现为"这个键失灵了"）。
    // 常开计数 + 限量日志，让下一轮真机能一眼看出是不是这条。
    if (outcome == AMCL_LEGACY_PHYSICAL_OWNERLESS_REPEAT ||
        outcome == AMCL_LEGACY_PHYSICAL_OWNERLESS_UP ||
        outcome == AMCL_LEGACY_PHYSICAL_DUPLICATE_DOWN) {
        Bump(Channel::KeyOwnerlessEdge);
        static std::atomic<int> logged{0};
        if (logged.fetch_add(1, std::memory_order_relaxed) < 20) {
            AMCL_LOG_W(LOG_TAG,
                        "AMCL_KBD ownerless edge ohosKey=%{public}u glfwKey=%{public}d "
                        "action=%{public}d deviceId=%{public}llu "
                        "(ArkTS held cache is out of sync with native owners; "
                        "this key stops producing PRESS until it resyncs)",
                        ohosKeyCode, mappedKey, action,
                        static_cast<unsigned long long>(deviceId));
        }
    }
    return outcome;
}

static AmclLegacyPhysicalOutcome routePhysicalButtonEventChecked(
        uint64_t deviceId, uint32_t nativeButton, int mappedButton,
        int action, int* routedMappedButton) {
    if (routedMappedButton) *routedMappedButton = -1;
    resolveBridge();

    LegacyPhysicalAction routeAction;
    if (action == GLFW_PRESS) {
        routeAction = LegacyPhysicalAction::Down;
    } else if (action == GLFW_RELEASE) {
        routeAction = LegacyPhysicalAction::Up;
    } else {
        return AMCL_LEGACY_PHYSICAL_INVALID_ACTION;
    }

    const Output mappedOutput{OutputKind::Mouse, mappedButton};
    const Output* mapped = mappedButton >= 0 ? &mappedOutput : nullptr;
    const LegacyPhysicalIdentity identity{
        OutputKind::Mouse, deviceId, nativeButton};
    return physicalEdgeRouter().Route(
        bridgeReady(), identity, mapped, routeAction,
        routeAction == LegacyPhysicalAction::Down ? nextOwnerToken() : 0,
        routedMappedButton);
}

/**
 * 热拔除使用 DOWN 时保存的 native button/device 身份补 UP。policy 已先摘配对，
 * 本函数只走现役 typed/legacy 单平面事务；不经全局 reset，不误放其它鼠标或虚拟键。
 */
static void releaseRemovedPointerButton(uint64_t deviceId,
        uint32_t nativeButton, void*) {
    int mapped = -1;
    switch (nativeButton) {
        case 1u: mapped = 0; break;
        case 2u: mapped = 1; break;
        case 4u: mapped = 2; break;
        case 8u: mapped = 3; break;
        case 16u: mapped = 4; break;
        default: return;
    }
    (void)amcl::input::PlatformInputPhysicalButtonTransaction(
        deviceId, nativeButton, AMCL_INPUT_ACTION_UP, mapped, GLFW_RELEASE,
        true, routePhysicalButtonEventChecked);
}

extern "C" void ohos_release_physical_pointer_device(
        uint64_t deviceId, bool releaseUnknown) {
    if (deviceId == 0u) return;
    // 已消失的 surface 不得拦住释放；只拿同一递归锁，禁止拔除与新 DOWN 交叉。
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    amcl_input_policy_release_pointer_device(deviceId, releaseUnknown,
        releaseRemovedPointerButton, nullptr);
}

// 窗口级过滤器取走的左键边沿（window_event_filter.cpp 调用，位于 ArkUI 分发之前）。
//
// 为什么需要它：本机左键在 ArkUI onMouse 与 native XComponent mouse 回调上**都不存在**
// （28/28 条 ArkUI 边沿全是右键），唯一载体是系统合成的触摸流；而那条流的坐标被
// LockCursor 夹在窗口内，导致"按住左键拖动视角有边界"。窗口级过滤器在 ArkUI 之前，
// 因此可以把左键 DOWN/UP 取走并由这里直接路由，让 ArkUI 永远不知道左键被按下，
// 从而不触发"鼠标左键转触摸"的兜底转换 —— MOVE 事件仍放行给 ArkUI，rawDelta 继续流。
//
// 返回 1 表示本次边沿已被本进程接管（调用方应过滤该事件），0 表示被 source 仲裁拒绝
// （另一通道正持有左键），此时调用方必须放行，否则左键会整体失效。
// 释放窗口级过滤器对左键的 source 所有权。
//
// 必须存在的理由（真机 bug，API 26 手机实测）：游戏内过滤器接管左键后成为 LEFT 的
// owner；退出到菜单时它不再接管（菜单态必须放行，否则点不了菜单），但所有权仍挂在
// WindowFilter 上。于是镜像通道投来的菜单点击全部撞上 `claimPhysicalMouseButtonSource`
// 的先到者独占规则被拒 —— 日志表现为 `btnMirror=6 btnRejected=12`，用户表现为
// **鼠标点不动菜单里的按钮**。500ms 空窗交接不足以救它：菜单里每次点击都会刷新
// lastEdge，反而让空窗永不成立。
//
// 因此过滤器一旦停止接管，就必须主动交还所有权。只清 WindowFilter 自己持有的那一份，
// 不影响 ArkUI/native/镜像三方之间的既有仲裁。
// ⚠️ 这里曾有 `ohos_release_window_filter_left_claim()` 与
// `ohos_route_window_filter_left_button()`：窗口级过滤器在 ArkUI 之前取走左键
// DOWN/UP 并自行路由。**已按真机证据整体删除，不要再加回来。**
//
//   收益：零。取走 DOWN 之后合成触摸确实消失（`mirrorMove` 归零），但按住左键期间
//         `lookArkts` 依然缺席 ⇒ ArkUI 的转换门控读的是每个 MOVE 自带的
//         `pressedButtons`，不是它自己累积的按键状态。
//   代价：它与镜像通道逐秒互抢 LEFT（`wfLeftTaken` 与 `btnRejected` 同时出现），
//         于是"按下由一方送出、抬起被另一方吞掉"，MC 侧左键永久卡在按下态；
//         退出到菜单时所有权不交还，菜单点击又被整批拒绝。
//
// 左键的通道选择现在由 input_channel_policy 统一决定，并且 press/release 由同一个
// 所有者配对送完，"抬起被吞"在结构上不可能再发生。

// ⚠️ 这里还曾有 `ohos_route_window_filter_wheel()`：在窗口层取走 `Input_MouseEvent`
// 的真实轴事件来兑换滚轮格数。**已按真机证据删除。**
// 两台设备上 `wfAxisTaken` 全程为 0 —— 窗口层根本没有 AXIS_* 可取（现由
// window_event_filter.cpp 的 action 探针给出直接证据）。它没有产出，却让"滚轮"
// 多了一条会与 native AXIS 抢符号的候选通道。滚轮所有者现由 input_channel_policy 决定。

extern "C" void ohos_route_arkui_physical_mouse_button(
        uint64_t deviceId, int32_t arkuiButtonMask, int32_t action,
        int32_t /*mods*/, uint32_t deviceClass,
        uint64_t monotonicTimeNs) {
    // ArkUI MouseButton is a BIT MASK, not a sequential index, and its values
    // are identical to the XComponent button bits:
    //   Left=0x01 Right=0x02 Middle=0x04 Back=0x08 Forward=0x10, None=0.
    // Treating it as 0..4 and shifting it again mapped a left click onto RIGHT,
    // right onto MIDDLE, dropped the side buttons and — worst — let a
    // button-less None edge through as a fabricated LEFT. Passing the mask
    // straight through also makes the ArkUI and native channels agree on one
    // legacy owner identity instead of two.
    int glfwButton = -1;
    switch (arkuiButtonMask) {
        case OH_NATIVEXCOMPONENT_LEFT_BUTTON:
            glfwButton = GLFW_MOUSE_BUTTON_LEFT; break;
        case OH_NATIVEXCOMPONENT_RIGHT_BUTTON:   glfwButton = 1; break;
        case OH_NATIVEXCOMPONENT_MIDDLE_BUTTON:  glfwButton = 2; break;
        case OH_NATIVEXCOMPONENT_BACK_BUTTON:    glfwButton = 3; break;
        case OH_NATIVEXCOMPONENT_FORWARD_BUTTON: glfwButton = 4; break;
        default:
            // None (0), a combination, or a future bit. Guessing LEFT here is
            // what produced phantom clicks, so this stays refused — but the
            // refusal must still be observable, hence the trace below runs
            // before the return.
            break;
    }
    if (action != GLFW_PRESS && action != GLFW_RELEASE) glfwButton = -1;
#if AMCL_INPUT_GATE0_TELEMETRY
    if (glfwButton < 0) {
        const AmclGate0ArkuiButtonSample refused{
            static_cast<int64_t>(deviceId), arkuiButtonMask, action, -1, -1, 0,
        };
        amcl_gate0_trace_arkui_button(&refused);
    }
#endif
    if (glfwButton < 0) return;
    amcl::input::SurfaceInputGateTransaction gate;
    // 全部按钮按device/button/DOWN-channel配对，长按不会因静默时间而换源。
    // API 26 实测 ArkUI onMouse **会**报左键 Press/Release（`actions=[0,1,1,...]`），
    // 只是此前每次都被更早到达的合成触摸镜像抢走所有权，所以 `btnArkui` 恒为 0，
    // 让人误以为这条通道不存在左键。
    const bool claimed = static_cast<bool>(gate) &&
        acceptPhysicalButtonEdge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, deviceId,
            static_cast<uint32_t>(arkuiButtonMask), action == GLFW_PRESS);
#if AMCL_INPUT_GATE0_TELEMETRY
    {
        const AmclGate0ArkuiButtonSample diagnostic{
            static_cast<int64_t>(deviceId), arkuiButtonMask, action,
            glfwButton, static_cast<bool>(gate) ? 1 : 0, claimed ? 1 : 0,
        };
        amcl_gate0_trace_arkui_button(&diagnostic);
    }
#endif
    if (!claimed) {
        amcl::input::census::Bump(
            amcl::input::census::Channel::ButtonRejectedByClaim);
        return;
    }
    amcl::input::census::Bump(amcl::input::census::Channel::ButtonFromArkui);

    const uint32_t nativeButton = static_cast<uint32_t>(arkuiButtonMask);
    const uint32_t typedAction = action == GLFW_PRESS
        ? AMCL_INPUT_ACTION_DOWN : AMCL_INPUT_ACTION_UP;
    if (glfwButton == GLFW_MOUSE_BUTTON_LEFT) {
        // Cancel a delayed source=MOUSE Touch tap before it can duplicate this
        // ArkUI edge. The gate establishes the global surface -> touch order.
        std::lock_guard<std::mutex> touchStateLock(s_touchStateMutex);
    }
    const AmclLegacyPhysicalOutcome outcome =
        amcl::input::PlatformInputPhysicalButtonTransaction(
        deviceId, nativeButton, typedAction, glfwButton, action,
        static_cast<bool>(gate), routePhysicalButtonEventChecked,
        deviceClass, monotonicTimeNs);
    finishPhysicalButtonAdmission(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, deviceId,
        nativeButton, action == GLFW_PRESS, outcome);
}

// ==================== 统一生命周期取消边界 ====================
// 任何会让后续 UP/CANCEL 不可靠到达的边界都必须调用同一入口。顺序固定为：
// 1) 持 surface gate 并发布/确认 typed reset；2) 在 touch/schema/input transaction 锁下释放
// OutputLedger、external/physical owner；3) 清 schema runtime/deadline/carried；
// 4) 清 finger registry 与 look backlog。返回时 neutral core 与 legacy 输出都位于零状态。
extern "C" void ohos_cancel_all_input(int reason) {
    // 此兜底先结束mapped速率，再走原控制清理；停源不依赖release成功或UI仍持连接句柄。
    amclMappedLookRetireAll();
    // Every caller, including NAPI/pause/window-recreate paths, joins the same
    // surface transaction used by native callbacks. The mutex is recursive so
    // blur/destroy may safely call this while already holding the gate. Global
    // order is surface gate -> ingress -> touch state -> schema -> input
    // transaction -> external/physical/ledger; no accepted physical ingress can cross
    // the reset/release boundary or repopulate owners before this function returns.
    std::lock_guard<std::recursive_mutex> surfaceGateLock(
        s_surfaceInputGateMutex);
    // 生命周期已在线性化点取得 gate，先退休消费端菜单作用域，再做平台锁、typed
    // reset 和各 owner 的可能回调。否则这些清理步骤执行期间，已经 UP 的旧点击仍可
    // 被消费。后面的 schema 退休再次推进 epoch 是幂等的安全边界，不会恢复旧记录。
    inputBridge_retireTouchMenuScopeV1();
    // 与deadline/触点相同的真实grab围栏；即使服务尚未加载也继续安全复位，
    // 因为不可用的mode会同时阻止worker产生新的期限输出。
    amcl::input::AuthoritativeGrabInputTransaction grabTransaction;
    // 完整取消拥有平台锁的释放责任。游戏requested intent仍由backend掌握；这里只
    // 发布实际active=false，不能伪装成游戏主动结束grab。pause/focus/surface的准入
    // 状态会继续挡住迟到心跳，普通reset则允许下一次有效对账重新授权。
    if (reason == AMCL_INPUT_CANCEL_FOCUS_LOST) {
        amcl_cursor_lock_set_focus(false);
    } else if (reason == AMCL_INPUT_CANCEL_SURFACE_LOST || reason == AMCL_INPUT_CANCEL_PAGE_DISPOSE) {
        amcl_cursor_lock_set_surface(false);
    }
    // BACKGROUND只撤销实际锁；foreground准入由现有Ability OR-mask发布器关闭/恢复，
    // 不能在此伪造组件Blurred，否则不派发新Focus的前台恢复会永久失去capture。
    (void)amcl_cursor_lock_set(0, false);
    uint32_t resetReason = AMCL_INPUT_RESET_EXPLICIT;
    switch (reason) {
        case AMCL_INPUT_CANCEL_BACKGROUND:
            resetReason = AMCL_INPUT_RESET_APPLICATION_BACKGROUND;
            break;
        case AMCL_INPUT_CANCEL_SURFACE_LOST:
            resetReason = AMCL_INPUT_RESET_SURFACE_CHANGED;
            break;
        case AMCL_INPUT_CANCEL_WINDOW_RECREATE:
            resetReason = AMCL_INPUT_RESET_SESSION_CHANGED;
            break;
        case AMCL_INPUT_CANCEL_FOCUS_LOST:
            // Focus publication already emitted the typed focus-lost reset;
            // this explicit mapping keeps direct callers semantically correct,
            // while resetLatched suppresses a duplicate in the normal blur path.
            resetReason = AMCL_INPUT_RESET_FOCUS_LOST;
            break;
        default:
            resetReason = AMCL_INPUT_RESET_EXPLICIT;
            break;
    }
    // The neutral reset drives the typed adapter when selected; in shadow mode its
    // maintenance consumer observes it without duplicating legacy GLFW output.
    // Ingress suppresses duplicates and classifies resets after lifecycle closure as stale.
    amcl::input::PlatformInputRequestReset(resetReason);
    amcl::input::PlatformInputCapturePlatformChanged(false,
        reason == AMCL_INPUT_CANCEL_FOCUS_LOST || reason == AMCL_INPUT_CANCEL_BACKGROUND
            ? AMCL_INPUT_CAPTURE_REASON_FOCUS_LOST
            : reason == AMCL_INPUT_CANCEL_SURFACE_LOST || reason == AMCL_INPUT_CANCEL_PAGE_DISPOSE
                ? AMCL_INPUT_CAPTURE_REASON_SURFACE_LOST : AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST);
    resolveBridge();

    // lifecycle/NAPI 线程必须先与正在执行的 XComponent 事件汇合，再按 touch→schema→transaction→ledger
    // 顺序释放。锁覆盖完整取消事务，保证返回时 finger registry 与 OutputLedger 同时处于零状态。
    std::lock_guard<std::mutex> touchStateLock(s_touchStateMutex);
    // 生命周期取消同时退休精细鼠标与原生鼠标镜像，避免旧菜单持有流入新的页面。
    releaseMenuToolControls();
    // 同一个边界也必须复位镜像手势状态：cancel 之后不会再有配对的抬起边沿到达。
    resetMirrorGestureStateLocked();
    // Take schema before the router transaction, matching every schema output
    // path. This stops the deadline worker before Reset begins and avoids a
    // schema->transaction / transaction->schema inversion during cancellation.
    pthread_mutex_lock(&s_schemaMutex);
    std::lock_guard<std::recursive_mutex> cancelTransactionLock(
        s_inputTransactionMutex);
    // 本次完整复位覆盖此刻之前发生的全部 legacy ring 不连续：复位结束后登记这个值，之后的入口
    // 不再为同一次丢历史重复做 legacy-only 复位（那会平白推进前端 epoch、丢掉新按下的缓存）。
    // 读取是一次原子 load，本函数即使经 bridge 回调跑在 MC 线程上也不会进入 bridge 锁。
    const uint64_t ringEpochCovered = inputBridge_legacyRingDiscontinuityEpochV1();
    // The router owns the transaction mutex for the entire callback. Its reset
    // fence is deliberately wider than the physical-owner releases: sendEvent,
    // UI projection and reset-completion callbacks may synchronously re-enter
    // this module, and no such callback may recreate a physical identity before
    // the full lifecycle boundary has reached zero state.
    physicalEdgeRouter().Reset([&]() {
        {
            std::lock_guard<std::mutex> externalLock(s_externalInputMutex);
            s_externalHeld.Clear();
        }
        {
            std::lock_guard<std::mutex> physicalLock(s_physicalInputMutex);
            s_axisVAccum = 0.0;
        }
        inputLedger().releaseAll();
        // 左键的 in-flight 配对也必须清：否则复位后到达的残留 UP 会被当成
        // "有配对的抬起"，而复位已经把 MC 侧的按下态释放过一次。
        // 只清配对、保留已发现的设备能力（理由见 input_channel_policy.h）。
        amcl_input_policy_reset_pairing();
        schemaResetTransientStateLocked({});

                for (int i = 0; i < MAX_FINGERS; i++) {
            s_fingerDown[i] = false;
            s_fingerDead[i] = false;
            // ---- P0 修复：滚轮手势识别状态此前**不在**本函数的复位集合里 ----
            //
            // 本函数的注释承诺"返回时 finger registry 与 OutputLedger 同时处于零状态"，
            // 但 s_wheelGesture* 只在同一 fid 的下一个 DOWN 或终止边沿才复位。
            // 于是生命周期 cancel（失焦 / 切后台 / surface 换代）若落在一次滚轮手势中段，
            // 该 fid 的 `Integral` 会保持 true —— 恢复之后它的每个 MOVE 都被当成
            // "指针派生包"整段吞掉，直到用户重新按一次。这是可观测、可复现的卡死。
            s_wheelGestureActive[i] = false;
            s_wheelGestureIntegral[i] = false;
            s_wheelGestureAnchorX[i] = 0.0f;
            s_wheelGestureLastY[i] = 0.0f;
            s_wheelGestureResidualPx[i] = 0.0f;
        }
        // 生命周期取消后 Minecraft 可能重建窗口/中心，旧 look backlog 只能丢弃，不能延迟补发。
        flushLookPending(false);
        // Publish completion only after every legacy owner/finger/backlog is empty.
        // The core may have advanced once for its typed RESET; this second edge is
        // deliberate so an ArkTS getter racing that earlier edge cannot retain a
        // stale repeat/modifier cache across the completed cancellation boundary.
        amcl::input::PlatformInputCompleteResetBoundary();
    });
    s_legacyRingTracker.AbsorbLocked(ringEpochCovered);
    pthread_mutex_unlock(&s_schemaMutex);
    // 端级记账：本函数覆盖的是**触控端与物理键鼠端**在 native 侧的全部状态。
    // 手柄端的状态机整体在 ArkTS（GamepadManager 的 pressedButtons / activeMoveKeys /
    // triggerDown），本函数**碰不到它**。
    //
    // ⚠️ 这段注释曾接着写：「而 onPageHide 与两个 Ability 的 onBackground 只调本函数、
    // 不调 GamepadManager.releaseAll()，那段窗口内 ArkTS 手柄状态会与 native ledger 失步」。
    // **那已经不成立**，而且它描述的是一个 §45/§46 就消灭掉的故障：
    // 三个边界现在都**先**走 `getInputSourceRegistry().releaseAllEnds(reason)`
    // （McGamePage.onPageHide / GameAbility.onBackground / EntryAbility.onBackground），
    // 而它会调到 `GamepadManager.releaseAllInputs()` → `releaseAll()`，
    // 三个集合全清。真机已确认：那三个边界的日志都打 `ends=3`（§51.3 ①）。
    // 留着这句会让下一个人去"补一条手柄释放"——那要么双发，要么把 §46 拆掉的 UI 副作用
    // 耦合重新引进来。
    //
    // 把三端的复位次数打成一行仍然有价值：它让"某个端漏了复位"在日志里可见，
    // 而不是靠读三个文件互相比对。
    //
    // 注意下面只 note 了两端 —— 这是**正确**的，不是漏写：本函数确实碰不到手柄端，
    // 手柄端的复位由 `ohos_note_input_source_reset(Gamepad)` 从 ArkTS 侧记账。
    amcl_input_source_note_reset(AMCL_INPUT_SOURCE_TOUCH_CONTROLS);
    amcl_input_source_note_reset(AMCL_INPUT_SOURCE_PHYSICAL_KBM);
    amcl_input_source_log_reset_state();
    // 持有账目：`AMCL_INSRC` 的另外三段里 gesture 栏结构性恒零（平台手势不产生
    // look/scroll、不参与按端复位），持有账目是它唯一留下痕迹的地方。
    ohos_log_external_held_state();
    // 视角管线快照：复位边界正是它最该被读的时刻 —— `dropped` 那两个数在这一刻会跳，
    // 而它是唯一能把"位移被边界丢弃"与"通道根本没来"区分开的量。
    ohos_log_look_pipeline_state();
    // 上面两行是**无条件**的（复位那一刻的快照有独立判读价值）。把周期性输出的节流基准
    // 推到现在，否则紧随其后的 ohos_input_invariant_tick 会立刻重复同一组数字。
    {
        AmclInputInvariantSnapshot cancelSnapshot{};
        sampleInputInvariants(&cancelSnapshot);
        // 复位边界是这三层最该被读的一刻：本函数的头注释承诺"返回时 native core 与 legacy
        // 输出都位于零状态"，而在这一行之前那句承诺**只有第 1b 层是可核对的**。
        // 现在 `phys` 与 `ledgerOwners` 也在同一行里 ⇒ 那句承诺变成三层都可当场读出的事实。
        logHeldLayerState(cancelSnapshot);
        noteSourceStateLogged(cancelSnapshot);
    }
    // 复位刚完成是不变量最该成立的一刻（本函数的注释承诺"返回时处于零状态"）。
    // 在这里检查一次，等于把那句承诺变成可执行的断言而不是注释里的声明。
    // 注意它需要连续两次观测才会上报，所以单次复位不会因为一个瞬时窗口而误报。
    // 走不带 ring 对账的内部入口：本函数仍持 touchState，且可能运行在 MC 线程。
    runInputInvariantTick();
    OH_LOG_INFO(LOG_APP, "Input cancelAll reason=%{public}d", reason);
}

extern "C" void ohos_set_touch_paused(bool paused) {
    std::lock_guard<std::recursive_mutex> surfaceGateLock(s_surfaceInputGateMutex);
    amcl_cursor_lock_set_paused(paused);
    if (paused && !s_touchPaused.load(std::memory_order_acquire)) {
        // 必须先 cancel，再禁止入口；反过来会吞掉负责释放的 UP/CANCEL。
        ohos_cancel_all_input(AMCL_INPUT_CANCEL_PAUSE);
    }
    s_touchPaused.store(paused, std::memory_order_release);
    OH_LOG_INFO(LOG_APP, "TouchPaused: %{public}s", paused ? "true" : "false");
}

// ⚠️ `ohos_clear_buttons` / `ohos_clear_joystick` 已删除。它们的存在理由是"rebuild 前清掉
// 旧矩形，避免 native look 路径被错误过滤"，而那条过滤路径（hitButton/isInJoystick）
// 本身已不可达，所以这两个入口连带失去意义。

// ==================== 视角灵敏度 / 倒置 Y ====================

extern "C" void ohos_set_look_sensitivity(float v) {
    if (v < 0.1f) v = 0.1f;
    if (v > 5.0f) v = 5.0f;
    if (!amcl_set_source_look_sensitivity(-1, v)) return;
    // ⚠️ `{public}` 是必须的：缺它 hilog 打成 `<private>`，于是真机日志只能证明
    // "这个 setter 被调过一次"，**证明不了生效的数值**（计划 §77.6）。四件套的三个
    // 浮点 setter 都曾缺它，导致 §77 判读时无法核对两台设备的实际取值。
    OH_LOG_INFO(LOG_APP, "LookSensitivity = %{public}.2f", v);
}

extern "C" void ohos_set_invert_y(bool b) {
    amcl_set_source_look_invert_y(-1, b);
    OH_LOG_INFO(LOG_APP, "InvertY = %{public}s", b ? "true" : "false");
}

// 平滑系数控制守恒 backlog 的到达速度。1.0 表示立即输出；小于 1 只延迟位移，正常手势
// UP 会补齐余量，因此不能再把它描述为“直接 EMA delta”或允许改变总灵敏度。
//
// ⚠️ **这个值不再对物理键鼠端生效**（2026-08-22，计划 §78）：它来自虚拟按键布局
// （`ControlLayout.ets` 的 `DEFAULT_LOOK_SMOOTHING`），语义是抑制**手指抖动**，而物理鼠标
// 不抖 —— 对它做低通只买到相位滞后。按端解析在 `amcl_input_source_look_smoothing()`。
extern "C" void ohos_set_look_smoothing(float alpha) {
    if (alpha < 0.1f) alpha = 0.1f;
    if (alpha > 1.0f) alpha = 1.0f;
    if (!amcl_set_source_look_smoothing(-1, alpha)) return;
    OH_LOG_INFO(LOG_APP, "LookSmoothing alpha = %{public}.2f (touch/gamepad only)",
                alpha);
}

// 视角加速强度（0..1，0 = 关闭）。对触摸 / 鼠标 rawDelta / 手柄右摇杆三源统一生效
// （都经 applyLookDelta）。加速按瞬时物理手速提升增益，慢速微调保持 1:1。
extern "C" void ohos_set_look_accel(float v) {
    if (v < 0.0f) v = 0.0f;
    if (v > 1.0f) v = 1.0f;
    if (!amcl_set_source_look_acceleration(-1, v)) return;
    OH_LOG_INFO(LOG_APP, "LookAccel = %{public}.2f", v);
}

// ==================== SchemaStore：不可变 generation 整表发布 ====================
// ArkTS 的 grabbed 字段只描述该表对应的可见场景；真正的 GrabEpoch 由 bridge announcement 驱动。
// 协议边界采用“先验证临时表、后一次性发布”：任一字段非法时旧 generation 完全不变，避免 UI 已更新
// 而 native 留下一张半解析热区。NAPI 做第一层友好校验，这里仍做第二层，因为 C ABI 不能信任调用方。
// 取值范围与 routerKey / routerMouse 共用 legacy_output_code.h 的同一组判据（键 1..512、
// 按钮 0..15 即 schema 编码 -1..-16），与 ArkTS 的 validOutputCode 逐值一致。
static bool schemaOutputCodeValid(int code) {
    return amcl::input::LegacySchemaOutputCodeValid(code);
}

static bool schemaEntriesValid(const AmclCtrlEntry* entries, int count,
                               float compW, float compH, int grabbed, float deadZone,
                               int schemaVersion, const char** reason, const amcl::input::TouchGroupSchema* groups = nullptr) {
    if (schemaVersion != 2 && schemaVersion != AMCL_CONTROL_SCHEMA_VERSION && schemaVersion != 4) { *reason = "unsupported-version"; return false; }
    if (schemaVersion != 4 && groups && groups->Enabled()) { *reason = "group-schema-version"; return false; }
    if (schemaVersion == 4 && (!groups || !amcl::input::ValidTouchGroupSchema(*groups, count))) {
        *reason = "group-schema"; return false;
    }
    if (count < 0 || count > (schemaVersion == 2 ? 256 : AMCL_CONTROL_SCHEMA_MAX_CONTROLS)) {
        *reason = "control-count"; return false;
    }
    if (count > 0 && entries == nullptr) { *reason = "null-entries"; return false; }
    if (!std::isfinite(compW) || !std::isfinite(compH) || compW <= 0.0f || compH <= 0.0f ||
        compW > 65536.0f || compH > 65536.0f) { *reason = "component-size"; return false; }
    if (grabbed != 0 && grabbed != 1) { *reason = "grabbed"; return false; }
    if (!std::isfinite(deadZone) || deadZone <= 0.0f || deadZone >= 1.0f) { *reason = "dead-zone"; return false; }

    std::set<std::string> ids;
    for (int i = 0; i < count; i++) {
        const AmclCtrlEntry& e = entries[i];
        const void* nul = memchr(e.id, '\0', sizeof(e.id));
        if (!nul) { *reason = "id-not-terminated"; return false; }
        const size_t idLen = static_cast<const char*>(nul) - e.id;
        if (idLen == 0 || idLen > AMCL_CONTROL_ID_MAX_BYTES) { *reason = "id-length"; return false; }
        if (!ids.insert(std::string(e.id, idLen)).second) { *reason = "duplicate-id"; return false; }
        if (e.kind < 0 || e.kind > 4) { *reason = "kind"; return false; }
        if (e.handledBy != 0 && e.handledBy != 1) { *reason = "handled-by"; return false; }
        if (e.trigger < 0 || e.trigger > 3) { *reason = "trigger"; return false; }
        if ((e.dragLook != 0 && e.dragLook != 1) || (e.haptic != 0 && e.haptic != 1)) {
            *reason = "boolean-field"; return false;
        }
        if (!std::isfinite(e.x) || !std::isfinite(e.y) || !std::isfinite(e.w) || !std::isfinite(e.h) ||
            !std::isfinite(e.hitSlop) || e.x < -1.0f || e.y < -1.0f || e.w <= 0.0f || e.h <= 0.0f ||
            e.x + e.w > compW + 1.0f || e.y + e.h > compH + 1.0f ||
            e.hitSlop < 0.0f || e.hitSlop > 256.0f) { *reason = "rect"; return false; }
        if (e.keyCount < 0 || e.keyCount > AMCL_CONTROL_MAX_KEYS) { *reason = "key-count"; return false; }
        if (e.swipeGroup < 0 || e.swipeGroup > 256 || (e.swipeGroup != 0 &&
            (schemaVersion < 3 || e.kind != 0 || e.handledBy != 0 || e.trigger != 0 || e.dragLook != 0))) {
            *reason = "swipe-group"; return false;
        }

        // 只有 native button 产生任意键/鼠标持续输出；其它 kind 的兼容 keyOrMouse 可为 0。
        if (e.handledBy == 0 && e.kind == 0) {
            if (schemaVersion == 4 && groups->Enabled() && groups->controls[i].phases) continue;
            if (e.keyCount == 0) {
                if (!schemaOutputCodeValid(e.keyOrMouse)) { *reason = "button-key"; return false; }
            } else {
                for (int k = 0; k < e.keyCount; k++) {
                    if (!schemaOutputCodeValid(e.keys[k])) { *reason = "button-keys"; return false; }
                }
            }
        }
    }
    return true;
}

static uint64_t setControlSchemaWithGroups(const AmclCtrlEntry* entries, int count,
                                              float compW, float compH, int grabbed, float deadZone,
                                              int schemaVersion, const amcl::input::TouchInteractionConfig* config,
                                              const amcl::input::TouchGroupSchema* groups) {
    // 旧数值协议也加入surface事务，不能绕过新发布接口正在执行的零触点安装边界。
    std::lock_guard<std::recursive_mutex> publicationGate(s_surfaceInputGateMutex);
    const amcl::input::TouchInteractionConfig candidate = config ? *config : amcl::input::TouchInteractionConfig{};
    if ((schemaVersion >= 3 && !config) || !amcl::input::ValidTouchInteractionConfig(candidate)) return 0;
    const amcl::input::TouchGroupSchema groupDefinition = groups ? *groups : amcl::input::TouchGroupSchema{};
    const char* reason = "unknown";
    if (!schemaEntriesValid(entries, count, compW, compH, grabbed, deadZone, schemaVersion, &reason, groups)) {
        AMCL_LOG_W(LOG_TAG, "ControlSchema rejected: reason=%{public}s version=%{public}d count=%{public}d",
                    reason, schemaVersion, count);
        return 0;
    }

    // Schema 发布与触摸 ingress 共用 touch→schema 锁序。grab 的 native TSFN 通常先于下一次触摸
    // 抵达 ArkTS；若这里不先消费 announcement，schemaCancelGenerationLocked 会在 carry 发生前释放
    // 旧 owner，使“按住 F3 跨 ungrab”退化。持有 touch 锁直到新 generation 完整发布，也禁止 MOVE/UP
    // 落在“旧 epoch 已迁移、但新表尚未安装”的半事务窗口。
    resolveBridge();
    // ring 不连续对账先于 touchState：新 generation 必须建立在已经与 ring 对齐的 owner 状态上。
    reconcileLegacyRingDiscontinuity();
    std::lock_guard<std::mutex> touchStateLock(s_touchStateMutex);
    // A candidate is bound to the old schema generation and its stable look
    // role. Replacement invalidates that role but keeps a previously observed
    // native-left channel authoritative until a full lifecycle reset.
    // 公告状态由 consumeGrabEpochLocked 在取队列的同一临界区读出；这里的无锁读只决定“要不要消费”，
    // 有公告时回退值不参与判定。
    if (s_grabAnnouncements.AnnouncedState() >= 0 || s_isGrabbingFn) {
        (void)consumeGrabEpochLocked(s_isGrabbingFn ? s_isGrabbingFn() : (grabbed != 0));
    } else if (!s_grabFlipInit) {
        // bridge 尚未加载时只初始化空 epoch；没有 bridge 就不可能已有已发送的 schema 输出。
        s_grabFlipLastState = (grabbed != 0);
        s_grabFlipInit = true;
    }

    pthread_mutex_lock(&s_schemaMutex);
    if (s_schemaGeneration != 0 && s_schemaContextPolicy == s_touchContextPolicy && s_schemaWidthPx == compW && s_schemaHeightPx == compH &&
        s_schemaDeadZone == deadZone && amcl::input::SameTouchInteractionConfig(s_touchConfig,candidate) &&
        amcl::input::SameControlSchemaEntries(s_schema, entries, count) && s_touchGroups.Definition() == groupDefinition) {
        const uint64_t unchanged = s_schemaGeneration;
        pthread_mutex_unlock(&s_schemaMutex);
        return unchanged;
    }
    // 表内容变化与全局策略变化分开：新增UI让出区、隐藏单键、重排不应退休未变的持续输入。
    const bool samePolicy = s_schemaGeneration != 0 && s_schemaContextPolicy == s_touchContextPolicy && s_schemaWidthPx == compW && s_schemaHeightPx == compH &&
        s_schemaDeadZone == deadZone && amcl::input::SameTouchInteractionConfig(s_touchConfig,candidate);
    // 完整扩展先在副本上分配；失败在任何输入退休/表交换之前返回。
    amcl::input::TouchGroupState nextGroups;
    try { nextGroups = s_touchGroups; nextGroups.Install(groupDefinition); }
    catch (...) { pthread_mutex_unlock(&s_schemaMutex); return 0; }
    const int nativeFingersBefore = schemaNativeFingerCountLocked();
    if (samePolicy && s_touchGroups.Definition() == groupDefinition) {
        const bool sameBindings = amcl::input::SameControlSchemaBindings(s_schema, entries, count);
        schemaRetireChangedControlsLocked(entries, count);
        // schema计数只包含grabbed角色，不代表direct菜单已零触点；必须再核菜单解释器
        // 与tool完整快照。仍贴屏或显式持有的未变角色保持，已抬手的旧前缀不继承新表。
        // 完整等价表已在上方返回。纯反馈虽需安装新表，却没有改变菜单作用域的输入绑定，
        // 不能撤销已UP但尚未消费的合法短tap；真实绑定变化仍保留原完成边界和资源核验。
        if (!sameBindings && nativeFingersBefore == 0 && !s_menuTouch.Active() && menuToolHeldSnapshot().live == 0)
            inputBridge_retireTouchMenuScopeV1();
    } else schemaCancelGenerationLocked();
    s_touchConfig = candidate;
    s_touchGroups = std::move(nextGroups);
    // Configure会取消菜单事务；仅真正的策略/视口变更才调用，纯UI表更新保留当前双指/拖动。
    if (!samePolicy) s_menuTouch.Configure(compW,compH,ohos_display_density(),candidate,emitMenuInteraction);
    if (count > 0) s_schema.assign(entries, entries + count);
    else s_schema.clear();
    s_groupMouseControl=schemaGroupControlIndex(s_groupMouseMember.c_str());
    if (s_touchGroups.Enabled() && !s_groupMouseMember.empty() && s_groupMouseControl < 0) {
        inputBridge_retireTouchMenuToolScopeV1(); releaseMenuToolControls();
        std::fill(s_menuMouseBounds,s_menuMouseBounds+4,0.0); s_groupMouseMember.clear();
    }
    s_schemaGeneration++;
    // 0 被 NAPI/ArkTS 保留作失败哨兵；uint64 回绕在实际生命周期不可达，仍防御一次。
    if (s_schemaGeneration == 0) s_schemaGeneration = 1;
    s_schemaDeadZone = deadZone;
    s_schemaWidthPx = compW;
    s_schemaHeightPx = compH;
    s_schemaContextPolicy = s_touchContextPolicy;
    const uint64_t generation = s_schemaGeneration;
    const int nativeFingersAfter = schemaNativeFingerCountLocked();
    pthread_mutex_unlock(&s_schemaMutex);

    // 同一发布事务的计数同时落文件，hilog配额/轮转丢行不能使持有验收只剩“换代成功”。
    // 锁已释放，异步日志不阻塞schema临界区；只记录数量与尺寸，不记录键位或用户文本。
    AMCL_LOG_I(LOG_TAG,
        "ControlSchema published: generation=%{public}llu entries=%{public}d "
        "(comp=%.0fx%.0f grabbed=%{public}d dz=%.2f) samePolicy=%{public}d native_fingers_before=%{public}d native_fingers_after=%{public}d",
        (unsigned long long)generation, count, compW, compH, grabbed, deadZone,
        samePolicy ? 1 : 0, nativeFingersBefore, nativeFingersAfter);
    return generation;
}

/** 旧数值入口只接受原 v2/v3；新能力只能经带扩展与确认身份的 publication 安装。 */
extern "C" uint64_t ohos_set_control_schema_v3(const AmclCtrlEntry* entries, int count,
        float width, float height, int grabbed, float deadZone, int version,
        const amcl::input::TouchInteractionConfig* config) {
    if (version != 2 && version != 3) return 0;
    return setControlSchemaWithGroups(entries,count,width,height,grabbed,deadZone,version,config,nullptr);
}

/** 旧 v2 调用保持可用；不从另一个可变配置对象偷偷继承 v3 的新手势。 */
extern "C" uint64_t ohos_set_control_schema(const AmclCtrlEntry* entries,int count,float compW,float compH,
                                           int grabbed,float deadZone,int schemaVersion) {
    if (schemaVersion != 2) return 0;
    return ohos_set_control_schema_v3(entries,count,compW,compH,grabbed,deadZone,schemaVersion,nullptr);
}

/**
 * 会话及触控来源的显式生产维护。沿既有surface→mode→touch→schema锁序吸收真实grab公告，
 * 退休静止旧接触，并把消费者已交付光标投影到反馈状态。它不依赖UI/教学是否订阅读快照。
 * false只表示当前缺少真实mode事务；公告与安全退休仍沿已有fallback合同处理，不伪造Ready。
 */
extern "C" bool ohos_touch_input_maintain() {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    amcl::input::AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touchLock(s_touchStateMutex);
    const bool grabbed=consumeGrabEpochLocked(mode ? mode.grabbed() : isGrabbedMode());
    pthread_mutex_lock(&s_schemaMutex);
    if (mode && !s_touchPaused.load(std::memory_order_acquire)) schemaAdvanceGroupsLocked();
    if(!grabbed && !s_menuTouch.DirectActive() && !adoptCommittedMenuCursorLocked())
        s_touchMenuCursorVisible.store(false,std::memory_order_release);
    pthread_mutex_unlock(&s_schemaMutex);
    return static_cast<bool>(mode);
}

/**
 * 严格只读的接受态视觉投影。只取已被生产入口/显式维护确认的状态，不消费grab公告、不采用
 * consumer ACK、不触发释放或手势解释。进度按单调时钟计算输出值，读取不推进生产状态。
 */
extern "C" void ohos_touch_interaction_visual(double* values,int count) {
    if (!values || count < 14) return;
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    std::lock_guard<std::mutex> touchLock(s_touchStateMutex);
    const bool grabbed=s_grabFlipInit && s_grabFlipLastState;
    pthread_mutex_lock(&s_schemaMutex);
    values[0]=s_menuTouch.X(); values[1]=s_menuTouch.Y();
    values[2]=s_touchMenuCursorVisible.load(std::memory_order_acquire) ? 1 : 0;
    values[3]=s_touchJoystick.CenterX(); values[4]=s_touchJoystick.CenterY();
    values[5]=s_touchJoystick.X(); values[6]=s_touchJoystick.Y();
    values[7]=s_touchJoystick.Locked() ? 1 : 0; values[8]=s_touchJoystick.Armed() ? 1 : 0;
    values[9]=0; values[10]=s_schemaJoyFinger >= 0 ? 1 : 0; values[11]=0;
    values[12]=static_cast<double>(s_schemaGeneration); values[13]=-1;
    if(count>14) values[14]=s_menuTouch.Active() ? 1 : 0;
    if(count>=25) {
        values[15]=static_cast<double>(s_touchGuide.movement);
        values[16]=static_cast<double>(s_touchGuide.hotbar); values[17]=s_touchGuide.slot;
        values[18]=static_cast<double>(s_touchGuide.scroll); values[19]=s_touchGuide.scrollAmount;
        values[20]=static_cast<double>(s_touchGuide.mouseMove);
        values[21]=static_cast<double>(s_touchGuide.mouseButton); values[22]=s_touchGuide.mouseCode;
        values[23]=0;
        for(int i=0;i<MAX_FINGERS;i++) if(s_fingerDown[i] && !s_fingerDead[i]) values[23]+=1;
        values[24]=grabbed ? 1 : 0;
    }
    for (size_t i=0;i<s_schema.size();++i)
        if (s_touchJoystickId == s_schema[i].id) { values[13]=static_cast<double>(i); break; }
    const int64_t now=schemaNowNs();
    for (const auto& binding:s_schemaFingers) {
        if (binding.role==SCHEMA_FINGER_LOOK || binding.role==SCHEMA_FINGER_HOTBAR) {
            if (!binding.moved && binding.deadlineNs > 0) values[9]=std::max(values[9],std::clamp(
                static_cast<double>(now-binding.startNs)/(s_touchConfig.holdMs*1000000.0),0.0,1.0));
            // moved只撤销尚未完成的长按候选。战斗长按已认领Use后允许继续拖动，
            // 直到原UP/CANCEL释放；辅助瞄准必须跟随这份持有，而不能因拖动关掉。
        }
    }
    for (const auto& item:s_schemaButtons) {
        if (!item.second.outputDown) continue;
        const auto& control=item.second.control;
        if (control.keyCount==0 && control.keyOrMouse==s_touchConfig.actions[amcl::input::TouchUse]) values[11]=1;
        for (int i=0;i<control.keyCount;++i)
            if(control.keys[i]==s_touchConfig.actions[amcl::input::TouchUse]) values[11]=1;
    }
    pthread_mutex_unlock(&s_schemaMutex);
}

extern "C" void ohos_note_physical_pointer_visual(void) {
    s_touchMenuCursorVisible.store(false,std::memory_order_release);
}

/** 面板指针与直接/触摸板共享同一菜单位置；对抓取态和活跃背景触点拒绝抢占。 */
extern "C" bool ohos_move_touch_menu_pointer(double dx,double dy,const char* prefix,uint64_t publication) {
    if (!finitePair(dx,dy) || s_touchPaused.load(std::memory_order_acquire)) return false;
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    std::lock_guard<std::mutex> touchLock(s_touchStateMutex);
    if (consumeGrabEpochLocked(isGrabbedMode())) return false;
    pthread_mutex_lock(&s_schemaMutex);
    bool accepted=false;
    {
        std::lock_guard<std::recursive_mutex> transaction(s_inputTransactionMutex);
        reconcileMenuToolProcessLocked();
        // pending只关闭新DOWN；旧confirmed UI的move仍在真实模式/身份及原注册域内校验。
        if(touchAdmissionAcceptsUiContinuationLocked(publication) && menuToolPanelMatchesLocked(prefix,publication)) {
            accepted=s_menuTouch.MoveCursor(dx,dy,emitMenuToolPosition);
            if(accepted && (dx!=0 || dy!=0)) ++s_touchGuide.mouseMove;
            if(accepted) s_touchMenuCursorVisible.store(true,std::memory_order_release);
        }
    }
    pthread_mutex_unlock(&s_schemaMutex);
    return accepted;
}

/** 陀螺仪与手指共属触控端，但采样加工独立；延迟到达的旧schema/取消前样本必须拒绝。 */
extern "C" bool ohos_send_touch_gyro_sample_checked(double dx,double dy,int64_t timeNs,uint64_t generation) {
    if (!finitePair(dx,dy) || timeNs <= 0 || !amcl::input::ProductAcceptsDirectTouchInGame() ||
        s_touchPaused.load(std::memory_order_acquire) || s_touchAdmission.BlocksNewTouch()) return false;
    resolveBridge();
    if (!s_addLookDeltaFn) return false;
    std::lock_guard<std::mutex> touchLock(s_touchStateMutex);
    if (!consumeGrabEpochLocked(isGrabbedMode())) return false;
    pthread_mutex_lock(&s_schemaMutex);
    // 新surface可能在ArkTS还未查询之前已经生效，旧schema数字相同也不能授权旧gyro。
    (void)s_touchAdmission.Query(touchPublicationContextLocked());
    if (s_touchAdmission.BlocksNewTouch()) {
        pthread_mutex_unlock(&s_schemaMutex); return false;
    }
    // 旧无lease入口只能核schema/准入的弱兼容边界。sensor STARTUP ns与Native policy-start
    // 未证明同域，绝不再用这两个数值比较伪造旧样本围栏；新生产路径使用下面的私有lease。
    if (generation != s_schemaGeneration) {
        pthread_mutex_unlock(&s_schemaMutex); return false;
    }
    pthread_mutex_lock(&s_lookMutex);
    const bool accepted=amclSourceLookSubmit(AMCL_INPUT_SOURCE_TOUCH_CONTROLS,dx,dy,timeNs,true);
    if (accepted) {
        amcl::input::census::Bump(amcl::input::census::Channel::LookApplied);
        amcl_input_source_note_look(AMCL_INPUT_SOURCE_TOUCH_CONTROLS);
    }
    pthread_mutex_unlock(&s_lookMutex);
    pthread_mutex_unlock(&s_schemaMutex);
    return accepted;
}

namespace {
/** 仅保存租约身份；gyro积分/参数/pending仍只在neutral owner，不再存第二个采样clock。 */
struct GyroLeaseState {uint64_t stream=0,schema=0,touchPolicy=0,lookPolicy=0;AmclLookResourceV1 resource{};};
std::mutex gyroLeaseMutex;
std::map<std::string,GyroLeaseState> gyroLeases;
uint64_t nextGyroLease=1;
/** 只认本Native连续签发的canonical token；不把其它stream号/陌生字符串当已退休成功。 */
bool gyroLeaseNumber(const std::string& token,uint64_t* output){if(output)*output=0;
    if(!output||token.size()<=6||token.size()>26||token.compare(0,6,"GYRO1:")!=0||token[6]<'1'||token[6]>'9')return false;
    uint64_t value=0;for(size_t i=6;i<token.size();++i){if(token[i]<'0'||token[i]>'9')return false;
        const uint64_t digit=static_cast<uint64_t>(token[i]-'0');if(value>(UINT64_MAX-digit)/10)return false;value=value*10+digit;}
    *output=value;return true;
}
/** 只读序列化完整资源身份，Hz数值/valid位是明确元数据例外，不让Hz更新重启gyro。 */
std::string gyroContext(const AmclLookResourceV1& r,uint64_t policy,uint64_t touchPolicy,uint64_t schema){
    char result[512]{};uint32_t density=0;static_assert(sizeof(density)==sizeof(r.context.density));std::memcpy(&density,&r.context.density,sizeof(density));
    std::snprintf(result,sizeof(result),"GYROCTX1:%llu:%llu:%llu:%llu:%llu:%llu:%llu:%llu:%llu:%d:%d:%d:%d:%u:%u:%llu:%u:%u",
        (unsigned long long)r.gameSession,(unsigned long long)r.sessionEpoch,(unsigned long long)r.surfaceEpoch,
        (unsigned long long)r.focusEpoch,(unsigned long long)r.modeEpoch,(unsigned long long)policy,(unsigned long long)touchPolicy,
        (unsigned long long)schema,(unsigned long long)r.context.generation,r.context.windowId,r.context.displayId,r.context.leftPx,r.context.topPx,
        r.context.widthPx,r.context.heightPx,(unsigned long long)density,r.context.transform,
        r.context.validFields&~AMCL_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE);
    return result;
}
}
std::string ohos_touch_gyro_lease_context(){const auto* look=amclLookExecutionGetPortV1();if(!look)return {};
    AmclLookResourceV1 resource{};if(!inputBridge_getLookResourceV1(&resource))return {};
    std::lock_guard<std::mutex> touch(s_touchStateMutex);pthread_mutex_lock(&s_schemaMutex);
    const auto context=gyroContext(resource,amclLookPolicyEpochV1(1),s_touchContextPolicy,s_schemaGeneration);
    pthread_mutex_unlock(&s_schemaMutex);return context;
}
std::string ohos_begin_touch_gyro_lease(uint64_t schema){const auto* look=amclLookExecutionGetPortV1();if(!look||!schema)return {};
    if(!amcl::input::ProductAcceptsDirectTouchInGame()||s_touchPaused.load(std::memory_order_acquire))return {};
    AmclLookResourceV1 resource{};if(!inputBridge_getLookResourceV1(&resource))return {};
    std::lock_guard<std::mutex> touch(s_touchStateMutex);if(!consumeGrabEpochLocked(isGrabbedMode()))return {};
    pthread_mutex_lock(&s_schemaMutex);(void)s_touchAdmission.Query(touchPublicationContextLocked());
    if(s_touchAdmission.BlocksNewTouch()||schema!=s_schemaGeneration){pthread_mutex_unlock(&s_schemaMutex);return {};}
    AmclLookStreamV1 stream{};stream.size=sizeof(stream);stream.source=1;stream.kind=AMCL_LOOK_GYRO_DELTA;
    stream.unit=AMCL_LOOK_VIRTUAL_COUNTS;stream.clock=AMCL_LOOK_SENSOR_STARTUP;stream.reserved=AMCL_LOOK_STREAM_POLICY_LEASE;stream.resource=resource;
    uint64_t handle=0;if(look->openStream(&stream,&handle)<0){pthread_mutex_unlock(&s_schemaMutex);return {};}
    std::string token;
    try{const GyroLeaseState state{handle,schema,s_touchContextPolicy,amclLookPolicyEpochV1(1),resource};
        std::lock_guard<std::mutex> lock(gyroLeaseMutex);if(gyroLeases.size()>=64||nextGyroLease==UINT64_MAX){(void)look->retireStream(handle);pthread_mutex_unlock(&s_schemaMutex);return {};}
        token="GYRO1:"+std::to_string(nextGyroLease);gyroLeases.emplace(token,state);++nextGyroLease;
    }catch(const std::bad_alloc&){(void)look->retireStream(handle);pthread_mutex_unlock(&s_schemaMutex);return {};}
    pthread_mutex_unlock(&s_schemaMutex);return token;
}
bool ohos_submit_touch_gyro_lease(const std::string& token,double dx,double dy,int64_t sensorNs){
    const auto* look=amclLookExecutionGetPortV1();if(!look||!finitePair(dx,dy)||sensorNs<=0)return false;
    if(!amcl::input::ProductAcceptsDirectTouchInGame()||s_touchPaused.load(std::memory_order_acquire))return false;
    AmclLookResourceV1 resource{};if(!inputBridge_getLookResourceV1(&resource))return false;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);if(!consumeGrabEpochLocked(isGrabbedMode()))return false;
    pthread_mutex_lock(&s_schemaMutex);(void)s_touchAdmission.Query(touchPublicationContextLocked());
    std::lock_guard<std::mutex> lease(gyroLeaseMutex);const auto it=gyroLeases.find(token);
    const bool valid=it!=gyroLeases.end()&&!s_touchAdmission.BlocksNewTouch()&&it->second.schema==s_schemaGeneration&&
        it->second.touchPolicy==s_touchContextPolicy&&it->second.lookPolicy==amclLookPolicyEpochV1(1)&&
        gyroContext(it->second.resource,it->second.lookPolicy,it->second.touchPolicy,it->second.schema)==
            gyroContext(resource,amclLookPolicyEpochV1(1),s_touchContextPolicy,s_schemaGeneration);
    // completed delta只应用一次敏感/倒置；owner用接受时钟加工，sensorNs仅检查原STARTUP流次序。
    const bool accepted=valid&&inputBridge_submitLookV1(it->second.stream,dx,dy,static_cast<uint64_t>(sensorNs),0)!=0;
    pthread_mutex_unlock(&s_schemaMutex);return accepted;
}
bool ohos_retire_touch_gyro_lease(const std::string& token){const auto* look=amclLookExecutionGetPortV1();uint64_t number=0;
    if(!look||!gyroLeaseNumber(token,&number))return false;
    // 停源不要求surface/前台；精确token幂等，不释放后来同schema的另一流。
    std::lock_guard<std::mutex> lock(gyroLeaseMutex);if(number>=nextGyroLease)return false;
    const auto it=gyroLeases.find(token);if(it==gyroLeases.end())return true; // 只有连续已签发的原token可证明重复退休。
    const int result=look->retireStream(it->second.stream);
    if(result!=AMCL_LOOK_ACCEPTED_NO_MOTION&&result!=AMCL_LOOK_STALE)return false;
    gyroLeases.erase(it);return true;
}

// ==================== 阶段 2.8：char 事件（IME / 物理键盘可打印字符）====================

extern "C" void ohos_send_char_event(int codepoint) {
    resolveBridge();
    if (!bridgeReady()) return;
    // EVENT_TYPE_CHAR = 1000（与 input_bridge_ohos.c 同步）
    sendEvent(1000, codepoint, 0, 0, 0);
}

extern "C" void ohos_send_char_mods_event(int codepoint, int mods) {
    resolveBridge();
    if (!bridgeReady()) return;
    // EVENT_TYPE_CHAR_MODS = 1001
    sendEvent(1001, codepoint, mods, 0, 0);
}

// ==================== Phase E.2 鼠标 native 回调 ====================
//
// ⚠️ **这一段的前提只对 API 24 平板成立，不要当成跨设备的硬事实。**
// 原文写的是「ArkUI 的 .onMouse 回调**只会**触发右键/中键/Move/Hover……鼠标左键
// **根本不进 .onMouse**」。API 26 手机上**已被证伪**：那里 ArkUI onMouse 确实报左键，
// 且 `input_channel_policy` 把它选为左键 aspect 的所有者
// （真机 `AMCL_INPOLICY left owner=arkuiMouse`，三行 warm-up 序列见计划文档 §52.4）。
// 当前全部按钮使用同一按设备配对协议，不能按API版本断言某条通道不存在。
//
// 所以现在的正确读法是：**左键在哪条通道上出现是设备相关的**，这也正是
// `input_channel_policy` 用"能力发现"（这条通道是否真的送来过样本）而不是版本判断
// 来选所有者的原因。下面这段作为 API 24 的实测记录保留：
//
// 真机回归发现（**API 24 平板**）：ArkUI 的 .onMouse 回调只会触发右键 / 中键 / Move /
// Hover 等"非主要点击"事件；鼠标左键被 ArkUI 当成"等价于触摸点击"路径，不进 .onMouse。
// 之前 OnDispatchTouchEvent 又会把鼠标左键当 LOOK 视角增量处理（grabbed 模式下）
// 导致 MC 既看不到 MOUSE_BUTTON_LEFT Press、又被左键意外转视角。
//
// Phase E.3（2026-05-30）：分工修订——
//   - 鼠标按键（Press/Release）→ native DispatchMouseEvent（这里）
//   - Gate-0 native absolute build flag 关闭时，鼠标视角增量（Move）仍走 ArkTS
//     .onMouse 的 rawDeltaX/Y（McGamePage::handleMouseEvent）；该默认路径不变。
//   - 只有 immutable host capability 明确启用 verified native absolute，且本次回调
//     从 bridge grab SSOT 采样为 normal/menu 时，native MOVE 才提交 surface-local
//     absolute，PRESS/RELEASE 才同批提交 absolute+button。grabbed 始终保留
//     ArkTS raw-relative MOVE + native button-only 的既有分工。
//     * native MouseEvent.x/y 是绝对坐标，不能用相邻位置差伪装 relative input。
//     * rawDeltaX/Y 只是当前平台暴露的相对字段；它是否等价于 raw HID、在窗口边缘
//       或 surface 外是否连续，仍须 Gate 0 真机证据，不能由本实现宣称。
//   - 触摸路径 OnDispatchTouchEvent 用 toolType 过滤掉鼠标，避免双发
//   - OnDispatchHoverEvent 仅做状态重置

extern "C" void OnDispatchMouseEvent(OH_NativeXComponent* component, void* window) {
    SurfaceInputGateCallbackScope gate(component, window, true);
    if (!gate.accepted()) {
        // Do not dereference a stale component/window merely to recover event
        // fields. The transaction records GateRejected before consulting any
        // other argument or callback, including in legacy+shadow0.
        if (amcl::input::PlatformInputNativeAbsoluteRouteUsesTyped()) {
            (void)amcl::input::PlatformInputNativeSurfaceMouseTransaction(
                0u, 0.0, 0.0, 0u, 0u, 0u, false);
        } else {
            (void)amcl::input::PlatformInputPhysicalButtonTransaction(
                0u, 0u, 0u, -1, GLFW_RELEASE, false, nullptr);
        }
        return;
    }

    OH_NativeXComponent_MouseEvent ev;
    int32_t r = OH_NativeXComponent_GetMouseEvent(component, window, &ev);
    if (r != 0) return;
#if AMCL_INPUT_GATE0_TELEMETRY
    amcl_gate0_trace_native_mouse(component, window, gate.generation(), &ev);
#endif
    const bool nativeAbsoluteRoute =
        amcl::input::PlatformInputNativeAbsoluteRouteUsesTyped();
    if (nativeAbsoluteRoute && !gate.acceptsEventTimestamp(ev.timestamp)) {
        // The XComponent ABI has no lifecycle token. For the optional native
        // plane, the build evidence that enables bit14 must also establish that
        // this field shares CLOCK_MONOTONIC's nanosecond domain; only then can
        // it reject a callback queued before the latest publication boundary.
        // Invalid/unknown timestamps always fail closed instead of being
        // relabelled with the current generation.
        (void)amcl::input::PlatformInputNativeSurfaceMouseTransaction(
            0u, 0.0, 0.0, 0u, 0u, 0u, false);
        return;
    }
    if (s_touchPaused.load(std::memory_order_acquire)) return;
    ohos_note_physical_pointer_visual();
    if (nativeAbsoluteRoute && !isGrabbedMode() && finitePair(ev.x,ev.y)) {
        // 只有经Gate F确认的原生绝对坐标才用于承接；兼容路线由其已接受的ArkTS位置入口更新。
        pthread_mutex_lock(&s_schemaMutex);
        s_menuTouch.AdoptCursor(ev.x,ev.y);
        pthread_mutex_unlock(&s_schemaMutex);
    }

    uint32_t typedAction = 0u;
    int legacyAction = GLFW_RELEASE;
    amcl::input::NativeMouseSampleKind sampleKind;
    if (ev.action == OH_NATIVEXCOMPONENT_MOUSE_MOVE) {
        sampleKind = amcl::input::NativeMouseSampleKind::Move;
        // 常开取证：native XComponent 的 mouse MOVE 在"左键按住"与"未按住"两种状态下
        // 各自的投递率。这是 ArkUI onMouse 之外**另一条独立**的鼠标通道
        // （官方 XComponent 示例就是把 Touch 与 Mouse 两套 callback 分开注册的）。
        //
        // 判读方式：若按住左键期间 nativeMouseMoveHeld 也为 0，而同期窗口层
        // wfMouse≈110~120/s，则"应用层还有别的写法能救回来"这个解释空间就被彻底排除，
        // 构成华为工单的最小复现证据。左键按住状态取自我们自己在窗口层的闩锁
        // （amcl_window_filter_left_held），不依赖任何被转换的通道。
        amcl::input::census::Bump(
            amcl_window_filter_left_held()
                ? amcl::input::census::Channel::NativeMouseMoveWhileLeftHeld
                : amcl::input::census::Channel::NativeMouseMove);
    } else if (ev.action == OH_NATIVEXCOMPONENT_MOUSE_PRESS) {
        sampleKind = amcl::input::NativeMouseSampleKind::ButtonEdge;
        typedAction = AMCL_INPUT_ACTION_DOWN;
        legacyAction = GLFW_PRESS;
    } else if (ev.action == OH_NATIVEXCOMPONENT_MOUSE_RELEASE) {
        sampleKind = amcl::input::NativeMouseSampleKind::ButtonEdge;
        typedAction = AMCL_INPUT_ACTION_UP;
    } else {
        return;
    }

    int glfwButton = -1;
    switch (ev.button) {
        case OH_NATIVEXCOMPONENT_LEFT_BUTTON:    glfwButton = 0; break;
        case OH_NATIVEXCOMPONENT_RIGHT_BUTTON:   glfwButton = 1; break;
        case OH_NATIVEXCOMPONENT_MIDDLE_BUTTON:  glfwButton = 2; break;
        case OH_NATIVEXCOMPONENT_BACK_BUTTON:    glfwButton = 3; break;
        case OH_NATIVEXCOMPONENT_FORWARD_BUTTON: glfwButton = 4; break;
        default:                                 break;
    }
    if (sampleKind == amcl::input::NativeMouseSampleKind::ButtonEdge) {
        // 全部按钮按device/button/DOWN-channel配对，长按不会因静默时间而换源。
        // glfwButton < 0 时（API 24 实测存在 NONE/NONE 边沿）不能进策略层：
        // 那不是左键，也不该抢任何按钮。
        const bool accepted = glfwButton >= 0 && acceptPhysicalButtonEdge(
            AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u,
            static_cast<uint32_t>(ev.button), legacyAction == GLFW_PRESS);
        if (!accepted) {
            // A registered callback can still report NONE/NONE on API 24. It
            // must not steal this button from a valid ArkUI Press/Release
            // channel.
            amcl::input::census::Bump(
                amcl::input::census::Channel::ButtonRejectedByClaim);
            return;
        }
        amcl::input::census::Bump(
            amcl::input::census::Channel::ButtonFromNativeMouse);
    }

    // Snapshot the bridge's process-local grab SSOT in this callback. An
    // unresolved bridge is unknown, not proof of normal/menu mode, and thus
    // fails closed to the established relative/button-only routes.
    amcl::input::AuthoritativeGrabInputTransaction grabTransaction;
    const bool grabStateKnown = static_cast<bool>(grabTransaction);
    const bool grabbed = grabTransaction.grabbed();
    const amcl::input::NativeMouseDispatchRoute route =
        amcl::input::DecideNativeMouseDispatchRoute(
            nativeAbsoluteRoute,
            grabStateKnown, grabbed, sampleKind);

    // Only the normal/menu dispositions enter the absolute source plane. MOVE
    // is one event; a button edge is [absolute, button] in one core batch. The
    // gate token is the publication generation sampled with ev, so ingress can
    // bind the callback to its exact surfaceEpoch without retagging it later.
    if (route == amcl::input::NativeMouseDispatchRoute::MenuAbsoluteMove ||
        route ==
            amcl::input::NativeMouseDispatchRoute::MenuAbsoluteButtonBatch) {
        if (sampleKind == amcl::input::NativeMouseSampleKind::ButtonEdge &&
            ev.button == OH_NATIVEXCOMPONENT_LEFT_BUTTON) {
            // Once the verified native plane owns this click, an ArkUI
            // mouseSynth touch must never manufacture a second left edge even
            // when the typed batch is rejected by a stale surface/backend gate.
            std::lock_guard<std::mutex> touchStateLock(s_touchStateMutex);
        }
        // 渲染缩放：native MouseEvent.x/y 是 real surface 物理 px；typed 绝对平面
        // 面向 MC 窗口坐标系（= 缩放后 buffer px），在此第一入口换算一次
        //（scale==1 恒等直通）。该路由由 bit14 门禁，当前产品构建不可达，
        // 但坐标契约必须与 legacy 菜单平面保持一致，否则开启证据位时会静默偏移。
        (void)amcl::input::PlatformInputNativeSurfaceMouseTransaction(
            gate.generation(), amcl::renderscale::MapX(static_cast<double>(ev.x)),
            amcl::renderscale::MapY(static_cast<double>(ev.y)), 0u,
            static_cast<uint32_t>(ev.button), typedAction, true,
            AMCL_INPUT_DEVICE_CLASS_UNKNOWN,
            ev.timestamp > 0 ? static_cast<uint64_t>(ev.timestamp) : 0u);
        return;
    }

    if (route == amcl::input::NativeMouseDispatchRoute::RelativeMoveOwner) {
        // In grabbed mode ArkTS rawDelta owns movement. Submitting native
        // absolute here would both pollute the camera coordinate model and
        // double-route one physical sample.
        return;
    }

    if (glfwButton == GLFW_MOUSE_BUTTON_LEFT) {
        // Native LEFT and synthesized touch have no shared device/sequence id.
        // Latch the native channel before either typed or legacy routing so a
        // pending/future fallback cannot double-fire the same physical click.
        // Surface gate is already held; taking touch here follows the global
        // surface -> touch order used by lifecycle reset and the deadline worker.
        std::lock_guard<std::mutex> touchStateLock(s_touchStateMutex);
    }

    // This XComponent mouse callback exposes no stable hardware identifier;
    // pass the explicit unknown-device identity instead of conflating it with a raw button.
    const AmclLegacyPhysicalOutcome outcome =
        amcl::input::PlatformInputPhysicalButtonTransaction(
        0u, static_cast<uint32_t>(ev.button), typedAction, glfwButton,
        legacyAction, true, routePhysicalButtonEventChecked,
        AMCL_INPUT_DEVICE_CLASS_UNKNOWN,
        ev.timestamp > 0 ? static_cast<uint64_t>(ev.timestamp) : 0u);
    finishPhysicalButtonAdmission(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u,
        static_cast<uint32_t>(ev.button), legacyAction == GLFW_PRESS, outcome);
}

extern "C" void OnDispatchHoverEvent(OH_NativeXComponent* component, bool isHover) {
    SurfaceInputGateCallbackScope gate(component, nullptr, false);
    if (!gate.accepted()) return;
    if (amcl::input::PlatformInputPhysicalRouteUsesTyped() &&
        !gate.componentOnlyGenerationSafe()) {
        // Hover ABI carries no window or sample timestamp. After any surface
        // update/reuse it cannot be attributed to the current typed epoch.
        //
        // ⚠️ 但 backlog 仍必须丢弃：**无法归属更是丢弃的理由，不是保留的理由。**
        // 早退时把余量留下，会被 idle worker 在没有任何物理来源时补发成一次视角
        // 移动 —— 正是本函数末尾那行注释禁止的事。而 backlog 是三端共用一份标量，
        // 所以这条泄漏与 typed 平面自己有没有产出无关（计划 §85.2）。
        flushLookPending(false);
        return;
    }

    amcl::input::PlatformInputPointerEnter(isHover);
    // 指针离开 surface 后后续 MOVE/UP 不可靠，按 epoch 取消处理：丢弃 backlog，而不是把旧余量
    // 留到下次 hover 进入后补发成一次无物理来源的视角移动。
    if (!isHover) flushLookPending(false);
}

// ==================== 2026-05-29：物理鼠标滚轮（native UIInputEvent / AxisEvent）====================
//
// 输入路由根因修复：滚轮**不在** OH_NativeXComponent_MouseEvent（该结构体只有 x/y/action/button，
// 无滚轮字段），而是经 OH_NativeXComponent_RegisterUIInputEventCallback(type=AXIS) 上报，
// 用 OH_ArkUI_AxisEvent_GetVerticalAxisValue 读取。
//
// ⚠️ 这里曾接着写「SDK 文档明确：鼠标滚轮 → 纵向 scroll 轴，**单位为度，正=向前滚**、
// 负=向后滚」。**量纲与符号两个都是错的**，而且**本注释块往下 10 行就写着相反的正确值**
// （见下面那段编号 1)/3) 的 SDK 契约：单位是 **px**、符号是 **正=向下滑**）。
// 只读块头前三行的人会同时拿到错的量纲和错的符号 —— 而滚轮方向与格数正是本项目
// 反复出问题的地方（§18 / §32 / §35 各占一轮）。正确值以下面那段为准，代码也与它一致
// （`kGlfwPhysicalWheelPolicy.stepPx = 1.0` 是 px 语义；累计到 -1px 时 GLFW +1，
// 即 vy 负 → GLFW +1）。
//
// 之前没注册这个回调，滚轮的物理移动被 DispatchTouchEvent 当成手指 MOVE → grabbed 模式累加进
// cursor → "滚轮让视角上下动"。注册 native AxisEvent 通道后，滚轮直接变 GLFW scroll 事件，
// MC 用来切 hotbar。
//
// SDK 契约（arkui/ui_input_event.h，OH_ArkUI_AxisEvent_GetVerticalAxisValue）：
//   1) 值的单位是 **px**，是增量滚动量，不是总量；
//   2) 值**不包含**用户的滚动行数设置（另有 OH_ArkUI_AxisEvent_GetScrollStep）；
//   3) 符号：**正 = 向下滑，负 = 向上滑**；且受系统"自然滚动"设置影响。
//
// 旧实现把它当作"度"并以 15°/格 累加，单位从根上就是错的：一个滚轮格的 px 值永远累加
// 不到 15 → detents 恒为 0 → **从不发 scroll**（真机表现为"滚轮不切快捷栏"）。同时
// direction 取 sign(value) 与 GLFW 约定相反（GLFW 向上滚为 +1）。
//
// 物理滚轮每一格产生一个 AXIS 事件，所以一个事件就对应一格快捷栏。触摸板的亚像素抖动
// 由累加器吸收，不会每个样本都切一格。分格契约见 `kGlfwPhysicalWheelPolicy`
// （stepPx=1.0、一个事件最多一格、跨阈值后丢残量），typed 平面共用同一份。

// 滚轮的通道归属已收敛到 input_channel_policy。这里只保留一个薄封装，
// 语义是"native AXIS 是否为当前所有者"。
extern "C" bool ohos_native_wheel_channel_seen(void) {
    return amcl_input_policy_wheel_owner() == AMCL_INPUT_CHANNEL_NATIVE_AXIS;
}

// ArkTS 侧的滚轮通道申请入口：一次调用完成"登记能力 + 询问是否为所有者"，
// 把顺序错误的可能性从调用点消掉（能力必须先登记，否则永远拿不到所有权）。
//
// 这是"滚轮反向且时好时坏"的修复。此前 ArkTS 的轴驱动 Pan 通道**从不询问**所有者，
// 于是它与 native AXIS 同时产出：真机一秒内 `nativeAxisScroll=9` 而 `scrollOut=19`，
// 多出来的十格全是 Pan 发的，而两条通道的符号相反 —— 慢滚一方赢、快滚另一方赢，
// 用户看到的就是"方向是反的，但快速滚动有时又正常"。
extern "C" bool ohos_wheel_channel_claim(int channel) {
    const AmclInputChannel ch = static_cast<AmclInputChannel>(channel);
    switch (ch) {
        case AMCL_INPUT_CHANNEL_NATIVE_AXIS:
        case AMCL_INPUT_CHANNEL_ARKTS_AXIS:
        case AMCL_INPUT_CHANNEL_AXIS_PAN:
        case AMCL_INPUT_CHANNEL_TOUCH_WHEEL:
            break;
        default:
            // 未知取值 fail-closed：宁可这一格不发，也不要让一个拼错的常量
            // 悄悄变成"第五条滚轮通道"。
            return false;
    }
    amcl_input_policy_note_wheel_channel(ch);
    const bool accepted = amcl_input_policy_wheel_accepts(ch);
    if (!accepted) {
        amcl::input::census::Bump(amcl::input::census::Channel::WheelYielded);
    }
    return accepted;
}

static AmclLegacyPhysicalOutcome routePhysicalWheelEventChecked(
        double x, double y, uint32_t* routedDetentCount) {
    if (routedDetentCount) *routedDetentCount = 0u;
    std::lock_guard<std::recursive_mutex> transactionLock(
        s_inputTransactionMutex);
    if (physicalEdgeRouter().ResetInProgress()) {
        return AMCL_LEGACY_PHYSICAL_RESET_IN_PROGRESS;
    }
    // 横轴 / 非有限 / 零样本三道判定已收进 `StepPhysicalWheel`，与 typed 平面共用同一份
    // （计划 §91）。此前它们在两条平面各写一遍，只是恰好等价。
    if (x != 0.0 || !amcl::input::IsFinitePhysicalWheelSample(y)) {
        recordInvalidPhysicalWheel("non-finite-or-float-overflow");
        return AMCL_LEGACY_PHYSICAL_INVALID_VALUE;
    }
    if (y == 0.0) {
        return AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE;
    }

    resolveBridge();
    if (!bridgeReady()) {
        return AMCL_LEGACY_PHYSICAL_BRIDGE_UNAVAILABLE;
    }

    int direction = 0;
    {
        std::lock_guard<std::mutex> lock(s_physicalInputMutex);
        // 分格、截断、取反、残量与拒绝时的余量处置全部在共用的一步里。
        amcl::input::PhysicalWheelStepOutcome step{};
        amcl::input::StepPhysicalWheel(
            s_axisVAccum, 0.0, y, amcl::input::kGlfwPhysicalWheelPolicy, &step);
        // 无条件写回：拒绝路径上它是 0.0，两条平面因此不可能在这里分叉。
        s_axisVAccum = step.remainder;
        if (step.status == amcl::input::PhysicalWheelStepStatus::kRejectedValue ||
            step.status == amcl::input::PhysicalWheelStepStatus::kRejectedAxis) {
            // 横轴与数值两类成因分开记：排查方向完全不同（计划 §83.9.3 / §91.1）。
            recordInvalidPhysicalWheel(
                step.status ==
                        amcl::input::PhysicalWheelStepStatus::kRejectedAxis
                    ? "unsupported-horizontal-axis"
                    : "accumulator-overflow");
            return AMCL_LEGACY_PHYSICAL_INVALID_VALUE;
        }
        direction = step.glfwY;
    }
    if (direction == 0) {
        return AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE;
    }

    amcl::input::census::Bump(amcl::input::census::Channel::NativeAxisScroll);
    // 本函数刻意绕过 routerScroll（它已持有同一把递归 transaction 锁），因此
    // ScrollDelivered 与**按端计数**都必须在这里补记，否则 scrollOut 会漏掉 native AXIS
    // 的每一格，"scrollOut = 各端之和"这条闭环等式就不成立，普查会自己骗自己。
    // 这条 native AXIS 通道属于物理键鼠端（它就是物理滚轮）。
    amcl::input::census::Bump(amcl::input::census::Channel::ScrollDelivered);
    amcl_input_source_note_scroll(AMCL_INPUT_SOURCE_PHYSICAL_KBM);
    sendEvent(EVENT_TYPE_SCROLL, 0, direction, 0, 0);
    // ⚠️ 不要写死 1：那是 `kGlfwPhysicalWheelPolicy.maxDetentsPerEvent` 的镜像。这个 out
    // 参数存在的唯一目的是让账目可对，把上限改成 2 时它会第一个坏（计划 §86.12）。
    if (routedDetentCount) {
        *routedDetentCount =
            static_cast<uint32_t>(direction < 0 ? -direction : direction);
    }
    return AMCL_LEGACY_PHYSICAL_EMITTED;
}

extern "C" void OnDispatchAxisEvent(OH_NativeXComponent* component, ArkUI_UIInputEvent* event) {
    // 常开普查：这条回调在本机注册成功却 0 样本。任何"滚轮行为变了"的复测都要先
    // 回答它是否被调用，否则无法区分"通道没来"与"路由写错"。
    amcl::input::census::Bump(amcl::input::census::Channel::NativeAxisCallback);
    SurfaceInputGateCallbackScope gate(component, nullptr, false);
#if AMCL_INPUT_GATE0_TELEMETRY
    // Liveness first: if this callback is never entered at all, no amount of
    // routing work downstream can make the wheel reach Minecraft, and that is
    // indistinguishable from a routing bug without this line.
    {
        AmclGate0AxisSample entry{};
        entry.gateAccepted = gate.accepted() ? 1 : 0;
        entry.generation = gate.generation();
        entry.componentOnlySafe = gate.componentOnlyGenerationSafe() ? 1 : 0;
        entry.touchPaused = s_touchPaused.load(std::memory_order_acquire) ? 1 : 0;
        entry.typedRoute =
            amcl::input::PlatformInputPhysicalRouteUsesTyped() ? 1 : 0;
        entry.axisAction = event ? OH_ArkUI_AxisEvent_GetAxisAction(event) : -1;
        entry.scrollStep = event ? OH_ArkUI_AxisEvent_GetScrollStep(event) : -1;
        entry.verticalValue =
            event ? OH_ArkUI_AxisEvent_GetVerticalAxisValue(event) : 0.0;
        entry.horizontalValue =
            event ? OH_ArkUI_AxisEvent_GetHorizontalAxisValue(event) : 0.0;
        entry.outcome = -1;
        amcl_gate0_trace_axis(&entry);
    }
#endif
    if (!gate.accepted()) {
        (void)amcl::input::PlatformInputPhysicalWheelTransaction(
            0.0, 0.0, true, false, nullptr);
        return;
    }

    if (!event) return;

    const int32_t rawDeviceId =
        OH_ArkUI_UIInputEvent_GetDeviceId(event);
    const int32_t toolType =
        OH_ArkUI_UIInputEvent_GetToolType(event);
    const int64_t eventTime =
        OH_ArkUI_UIInputEvent_GetEventTime(event);
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
    if (toolType == UI_INPUT_EVENT_TOOL_TYPE_MOUSE) {
        deviceClass = AMCL_INPUT_DEVICE_CLASS_MOUSE;
    } else if (toolType == UI_INPUT_EVENT_TOOL_TYPE_TOUCHPAD) {
        deviceClass = AMCL_INPUT_DEVICE_CLASS_TOUCHPAD;
    }
    const amcl::input::PlatformInputPointerIdentity pointerIdentity{
        rawDeviceId > 0 ? static_cast<uint64_t>(rawDeviceId) : 0u,
        deviceClass,
        eventTime > 0 ? static_cast<uint64_t>(eventTime) : 0u,
    };

    // The wheel needs no cross-channel suppression window: its Touch mirror is
    // refused by source in OnDispatchTouchEvent, so this callback is the single
    // owner of wheel input.
    //
    // ⚠️ 这里曾有一条 `typedRoute && !gate.componentOnlyGenerationSafe()` 早退。
    // **2026-08-24 真机否证并删除**（计划 §90）。它的前提为真、推论错：AXIS 回调的
    // 时间戳确实不能借用 NativeXComponent MouseEvent 的时间契约，但**滚轮从来不借它**
    // —— ingress 的 `SubmitPointerWheelLocked` 一个字段都不填 `header.monotonicTimeNs`
    // （那是 core 自己盖的），全仓没有任何提交期校验读它，而 stale 判定只读
    // session/focus/surface 三个 epoch。⇒ 那条早退挡不住任何它声称要挡的东西。
    //
    // 代价却是致命的，而且是结构性的：`componentOnlyGenerationSafe` 是**单向棘轮**
    // （只有 `OnSurfaceCreated` 能置真，`OnSurfaceChanged` 置假且永不恢复 ——
    // `input_reconciliation_test` 已把这三条钉死），而游戏页起来的过程必然至少一次
    // SurfaceChanged ⇒ typed 下这条回调**整场被丢弃**。更糟的是该早退位于下面
    // `ohos_wheel_channel_claim(NATIVE_AXIS)` **之上** ⇒ 首选通道连"送来过样本"这一位
    // 都不会被置上 ⇒ `PickOwner` 落到第三优先的 `AXIS_PAN`，而那条通道的标定是错的。
    // 真机症状：慢滚一格不动、快滚跳格（用户报，计划 §90.1 逐行对上）。
    if (s_touchPaused.load(std::memory_order_acquire)) return;

    const double vy = OH_ArkUI_AxisEvent_GetVerticalAxisValue(event);
    if (vy == 0.0) return;
    // 登记能力并申请所有权。native AXIS 是优先级最高的滚轮通道，所以一旦它真的
    // 送来样本就必然成为所有者，ArkTS 的两条通道随后自动让位。
    // API 24 平板上本回调注册成功却 0 样本，那里所有者会落到轴驱动 Pan。
    if (!ohos_wheel_channel_claim(AMCL_INPUT_CHANNEL_NATIVE_AXIS)) return;
    // ⚠️ 这段英文注释有两处不实，已就地更正：
    //
    //   ① 「legacy-only **15-degree quantization** lives in the checked callback」——
    //      本 TU 里**没有任何 15°/格 的量化**。全部滚轮常量是
    //      `kGlfwPhysicalWheelPolicy.stepPx = 1.0`（本条通道）、`kWheelNotchPx = 90.0f` /
    //      `kWheelIdentifyPx = 30.0f`（合成触摸运动学指纹）、`schemaScrollStepPx()`
    //      （虚拟滚轮条）。15°/格 是**旧实现**的做法，它把这个值当"度"用，
    //      而一格滚轮的 px 值永远累加不到 15 ⇒ 从不发 scroll（真机"滚轮不切快捷栏"）。
    //   ② 「and is **never invoked by** the typed source plane」——
    //      恰恰相反：`routePhysicalWheelEventChecked` 就是**下一行**作为第五个实参
    //      传进 `PlatformInputPhysicalWheelTransaction` 的那个回调。
    //
    // 仍然成立的只有中间那句：本 SDK 没有经过验证的横向 getter，所以 x 显式传 0。
    //
    // ⚠️ 2026-08-23：三处量纲分歧已消掉，并纠正这里原有的一句**假注释**。原文写
    // 「目前没有观察到消费者真的按 unit 做换算（只做范围校验），所以当前无行为后果」
    // —— 那句是错的：`glfw_compat.cpp` 的 `typedWheelSink` **就是**按 unit 分支换算的
    // （DEGREE ⇒ 除以 15），于是 px 被当度用 ⇒ 一格永远累加不到 15 ⇒ **从不发 scroll**，
    // 正是上方那句「真机滚轮不切快捷栏」的同一个形状。它没有暴露只是因为 typed 平面
    // 还没被打开 —— 属"从未被执行的代码不是能工作的代码"（计划 §82.4 的同一条纪律）。
    // 现在：ingress 改标 `PIXEL`；本通道与 `typedWheelSink` 都调
    // `GlfwScrollFromWheelPx(kGlfwPhysicalWheelPolicy)`。⚠️ 这句在 2026-08-23 首版里
    // 写成"共用"时**并不成立**（legacy 当时仍是内联手写数学），已随 §83.9 一并纠正。
    (void)amcl::input::PlatformInputPhysicalWheelTransaction(
        0.0, vy, true, true, routePhysicalWheelEventChecked,
        pointerIdentity);
}

// ==================== 触控发布/模态扩展v1（libentry内部） ====================
namespace {
/** 低频发布收据日志只记录不透明身份与计数，不记录布局名称、绑定键值或用户文本。caller持gate。 */
void logTouchPublicationReceipt(const char* phase, const amcl::input::TouchPublicationReceipt& receipt) {
    static uint64_t sequence = 0;
    if (sequence != UINT64_MAX) ++sequence;
    AMCL_LOG_I(LOG_TAG, "AMCL_TOUCH_PUBLICATION seq=%{public}llu phase=%{public}s status=%{public}s "
        "surface=%{public}llu session=%{public}llu policy=%{public}llu schema=%{public}llu grabEpoch=%{public}llu "
        "token=%{public}llu fenced=%{public}d contacts=%{public}d modals=%{public}u",
        static_cast<unsigned long long>(sequence), phase, amcl::input::TouchPublicationStatusName(receipt.status),
        static_cast<unsigned long long>(receipt.context.surface), static_cast<unsigned long long>(receipt.context.session),
        static_cast<unsigned long long>(receipt.context.policy), static_cast<unsigned long long>(receipt.context.schema),
        static_cast<unsigned long long>(receipt.context.grabEpoch),
        static_cast<unsigned long long>(receipt.token), receipt.fenced ? 1 : 0, receipt.context.nativeTouches, receipt.modalCount);
}
/** caller持gate→touch→schema；只取值，不借出任何可变引用或跨解锁迭代器。 */
amcl::input::TouchPublicationContext touchPublicationContextLocked() {
    amcl::input::TouchPublicationContext context;
    context.surface = s_surfaceInputGate.active ? s_surfaceInputGate.publicationGeneration : 0;
    context.session = amcl::input::PlatformInputResetDomains().touch;
    context.policy = s_touchContextPolicy;
    context.schema = s_schemaGeneration;
    context.grabEpoch = s_touchPublicationGrabEpoch;
    context.grabbed = s_grabFlipLastState;
    context.density = s_touchContextDensity;
    context.transform = s_touchContextTransform;
    for (int i = 0; i < MAX_FINGERS; ++i) {
        // 显式mouse镜像在登记fingerDown前已返回；滚轮兼容包有独立标记，不算direct-touch角色。
        if (s_fingerDown[i] && !s_wheelGestureIntegral[i]) ++context.nativeTouches;
    }
    return context;
}

/** 当前OS publication或touch会话改变，立即关闭新角色，不等JS获知该边界。 */
bool touchAdmissionBlocksNewTouchLocked() {
    pthread_mutex_lock(&s_schemaMutex);
    (void)s_touchAdmission.Query(touchPublicationContextLocked());
    const bool blocked = s_touchAdmission.BlocksNewTouch();
    pthread_mutex_unlock(&s_schemaMutex);
    return blocked;
}

/** caller持gate→touch→schema，身份来自Native现值；无SDK/游戏回调，不借出可变引用。
 * paused与mode/context分别拒绝，不能把layout fence例外扩大成后台或真实模态恢复。
 */
bool touchAdmissionAcceptsUiContinuationLocked(uint64_t token) {
    const auto current = touchPublicationContextLocked();
    (void)s_touchAdmission.Query(current);
    return !s_touchPaused.load(std::memory_order_acquire) && s_touchAdmission.AcceptsUiContinuation(token,current);
}

/** scope仅触控：schema/carried、菜单、面板和touch尾量退休；实体、手柄、text/capture保持。 */
void retireTouchScopeLocked() {
    // schema 的第一步就撤销中立 bridge 菜单身份；必须先于面板/ledger 释放，
    // 避免释放过程中同步回调或另一消费者把旧已结束点击提交到新模态。
    schemaCancelGenerationLocked();
    releaseMenuToolControls();
    s_menuTouch.Cancel(emitMenuInteraction);
    amcl::input::SourceReleaseSource(AMCL_INPUT_SOURCE_TOUCH_CONTROLS);
    for (int i = 0; i < MAX_FINGERS; ++i) {
        if (s_fingerDown[i] && !s_wheelGestureIntegral[i]) s_fingerDead[i] = true;
    }
    flushLookPending(false, AMCL_INPUT_SOURCE_TOUCH_CONTROLS);
    amcl::input::PlatformInputCompleteResetBoundary(amcl::input::kInputResetTouch);
}
}

namespace amcl::input {
/** 以下组端口与原 publication 使用完全相同锁序，不在等待 UI 时持锁。 */
static bool groupPublicationCurrentLocked(uint64_t token) {
    const auto receipt = s_touchAdmission.Query(touchPublicationContextLocked());
    return receipt.context.surface != 0 && receipt.status != TouchPublicationStatus::Stale &&
        !s_touchPaused.load(std::memory_order_acquire) && s_touchAdmission.AcceptsUiToken(token);
}

TouchGroupReceipt ReadTouchGroups(uint64_t token) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    TouchGroupReceipt result;
    try {
        const auto publication = s_touchAdmission.Query(touchPublicationContextLocked());
        if (mode && token != 0 && publication.token == token && publication.context.surface != 0 &&
            publication.status != TouchPublicationStatus::Stale) {
            result.token = token; result.revision = s_touchGroups.Revision(); result.enabled = s_touchGroups.Enabled();
            result.pending = s_touchGroups.PendingPresentation(); result.mask = s_touchGroups.Mask(); result.epochs = s_touchGroups.Epochs();
        }
    } catch (...) { pthread_mutex_unlock(&s_schemaMutex); throw; }
    pthread_mutex_unlock(&s_schemaMutex); return result;
}

bool ConfirmTouchGroups(uint64_t token, uint64_t revision) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    const bool confirmed = mode && groupPublicationCurrentLocked(token) && s_touchGroups.Confirm(revision);
    if (confirmed) schemaAdvanceGroupsLocked();
    pthread_mutex_unlock(&s_schemaMutex); return confirmed;
}

bool AcceptTouchGroupControl(uint64_t token, const std::string& control, uint64_t eligibility) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    const int index = schemaGroupControlIndex(control.c_str());
    const bool accepted = mode && groupPublicationCurrentLocked(token) && (!s_touchGroups.Enabled() ||
        (index >= 0 && eligibility != 0 && s_touchGroups.Visible(index) && s_touchGroups.Epoch(index) == eligibility && !s_touchGroups.BlocksControl(index,s_schema)));
    pthread_mutex_unlock(&s_schemaMutex); return accepted;
}

bool BindTouchGroupMouseOwner(uint64_t token, const std::string& control, uint64_t eligibility) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    if (!AcceptTouchGroupControl(token,control,eligibility)) return false;
    if (!s_touchGroups.Enabled()) return true;
    const int index=schemaGroupControlIndex(control.c_str());
    if (index < 0 || !s_touchGroups.Definition().controls[index].mouseTool) return false;
    s_groupMouseMember=control; s_groupMouseControl=index; return true;
}

uint64_t AcquireTouchGroupSourceControl(uint64_t publication, const std::string& member, uint64_t eligibility,
        uint64_t device, const std::string& sourceControl, const int* codes, uint32_t count) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    if (!AcceptTouchGroupControl(publication,member,eligibility)) return 0;
    if (!s_touchGroups.Enabled()) return ohos_acquire_source_control(1,device,sourceControl.c_str(),codes,count);
    // gate 排除所有组提交/结构变化，固定槽位在实际获取来源前预留，不在 keydown 后分配。
    auto slot = std::find_if(s_groupUiOwners.begin(),s_groupUiOwners.end(),[](const GroupUiOwner& value){ return value.token == 0; });
    if (slot == s_groupUiOwners.end()) return 0;
    const int index = schemaGroupControlIndex(member.c_str());
    const uint64_t owner = ohos_acquire_source_control(1,device,sourceControl.c_str(),codes,count);
    if (owner) *slot = {owner,index};
    return owner;
}

TouchGroupResult InvokeTouchGroupControl(uint64_t token, const std::string& control, uint64_t eligibility,
        uint64_t producer, uint64_t sequence, int phase) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    TouchGroupResult result;
    try {
        const auto publication=s_touchAdmission.Query(touchPublicationContextLocked());
        if (token == 0 || publication.token != token || publication.status == TouchPublicationStatus::Stale) {
            result.status=TouchGroupCommandStatus::Stale; pthread_mutex_unlock(&s_schemaMutex); return result;
        }
        const int index = schemaGroupControlIndex(control.c_str());
        if (index >= 0 && phase >= 0 && phase < 4 && producer > 1 && sequence > 0 &&
            s_touchGroups.Definition().controls[index].phases) {
            const TouchGroupCommand command{producer,sequence,index,eligibility,s_touchGroups.Definition().controls[index].bindings[phase].actions};
            result = s_touchGroups.Query(command);
            if (mode && groupPublicationCurrentLocked(token) && !s_touchGroups.BlocksControl(index,s_schema) && s_touchGroups.CanAccept(command)) {
                // 无障碍激活拥有独立运行记录，不能覆盖真实手指已冻结的 phase owner。
                const std::string uiKey = control + ":ui:" + std::to_string(producer);
                if (s_schemaButtons.size() >= 512 && s_schemaButtons.find(uiKey) == s_schemaButtons.end()) {
                    pthread_mutex_unlock(&s_schemaMutex); return result;
                }
                auto& state = s_schemaButtons[uiKey]; state.control = s_schema[index];
                state.groupControl = index; state.groupEligibility = eligibility;
                if (schemaGroupPhase(state,phase,producer,sequence)) {
                    // 无障碍离散激活没有未来 UP；非锁存阶段在同一操作中结束自己的持有。
                    const auto& binding = s_touchGroups.Definition().controls[index].bindings[phase];
                    if (!binding.autoKeep && state.phaseHeld[phase]) {
                        inputLedger().releaseOwner(state.phaseOwners[phase]); state.phaseHeld[phase] = false;
                        // 无障碍离散动作没有后续UP，同样在本次操作结束时发布实际聚合高亮。
                        amcl_fire_button_pressed(state.control.id,
                            std::any_of(state.phaseHeld.begin(), state.phaseHeld.end(), [](bool held) { return held; }) ? 1 : 0);
                    }
                    schemaAdvanceGroupsLocked();
                }
                result = s_touchGroups.Query(command);
                const auto remaining = s_schemaButtons.find(uiKey);
                if (remaining != s_schemaButtons.end() && std::none_of(remaining->second.phaseHeld.begin(),remaining->second.phaseHeld.end(),[](bool held){return held;}))
                    s_schemaButtons.erase(remaining);
            }
        }
    } catch (...) { pthread_mutex_unlock(&s_schemaMutex); throw; }
    pthread_mutex_unlock(&s_schemaMutex); return result;
}

TouchGroupResult RestoreTouchGroups(uint64_t token, uint64_t producer, uint64_t sequence) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    TouchGroupResult result;
    try {
        TouchGroupCommand command; command.producer = producer; command.sequence = sequence;
        for (size_t i = 0; i < s_touchGroups.Definition().groups.size(); ++i) command.actions.push_back({static_cast<uint32_t>(i),
            s_touchGroups.Definition().groups[i].initialVisible ? TouchGroupOperation::Show : TouchGroupOperation::Hide});
        if (mode && producer > 1 && groupPublicationCurrentLocked(token)) {
            result = s_touchGroups.Query(command);
            const bool accepted = result.status == TouchGroupCommandStatus::Pending || result.status == TouchGroupCommandStatus::Committed ||
                result.status == TouchGroupCommandStatus::Presented || s_touchGroups.Accept(command);
            if (accepted) { schemaAdvanceGroupsLocked(); result = s_touchGroups.Query(command); }
        } else result = {command, TouchGroupCommandStatus::Stale, s_touchGroups.Revision()};
    } catch (...) { pthread_mutex_unlock(&s_schemaMutex); throw; }
    pthread_mutex_unlock(&s_schemaMutex); return result;
}

TouchPublicationReceipt QueryTouchPublication() {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    auto receipt = s_touchAdmission.Query(touchPublicationContextLocked());
    if (!mode) receipt.status = TouchPublicationStatus::Unavailable;
    receipt.groupRevision = s_touchGroups.Revision();
    pthread_mutex_unlock(&s_schemaMutex);
    return receipt;
}

TouchPublicationReceipt BeginTouchPublication(const std::string& operation, const std::string& candidate,
        const TouchPublicationContext& expected) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    const auto context = touchPublicationContextLocked();
    const uint64_t beforeToken = s_touchAdmission.Query(context).token;
    auto receipt = s_touchAdmission.Begin(operation, candidate, expected, context);
    if (receipt.token != beforeToken && receipt.operationId == operation) s_touchGroups.RetireTransactions();
    if (!mode) receipt.status = TouchPublicationStatus::Unavailable;
    pthread_mutex_unlock(&s_schemaMutex);
    if (receipt.token != beforeToken && receipt.operationId == operation) logTouchPublicationReceipt("begin", receipt);
    schemaWakeDeadlineWorker();
    return receipt;
}

TouchPublicationReceipt PublishTouchSchema(const std::string& operation, const AmclCtrlEntry* entries,
        int count, float width, float height, int grabbed, float deadZone, int schemaVersion,
        const TouchInteractionConfig* config, const TouchGroupSchema* groups) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    AuthoritativeGrabInputTransaction mode;
    // 在gate内先prepare，随后安装沿用生产校验/差异退休。整个间隔无新触点、生命周期或
    // 其它发布可进入；touch/schema锁在旧函数重入前释放，绝不反向取得非递归touch锁。
    TouchPublicationReceipt receipt;
    {
        std::lock_guard<std::mutex> touch(s_touchStateMutex);
        if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
        pthread_mutex_lock(&s_schemaMutex);
        const auto context = touchPublicationContextLocked();
        receipt = s_touchAdmission.Prepare(operation, context);
        if (!mode) receipt.status = TouchPublicationStatus::Unavailable;
        else if ((grabbed != 0) != mode.grabbed()) receipt.status = TouchPublicationStatus::Stale;
        if (receipt.status == TouchPublicationStatus::Committed || receipt.status == TouchPublicationStatus::Unchanged) {
            // 幂等只对同一有效定义成立。不能重复operation却偷偷换一套键位或几何。
            if (!config || count < 0 || count > AMCL_CONTROL_SCHEMA_MAX_CONTROLS ||
                width != s_schemaWidthPx || height != s_schemaHeightPx || deadZone != s_schemaDeadZone ||
                !SameTouchInteractionConfig(s_touchConfig, *config) ||
                !SameControlSchemaEntries(s_schema, entries, count) ||
                !(s_touchGroups.Definition() == (groups ? *groups : TouchGroupSchema{}))) receipt.status = TouchPublicationStatus::Invalid;
            pthread_mutex_unlock(&s_schemaMutex);
            return receipt;
        }
        pthread_mutex_unlock(&s_schemaMutex);
    }
    if (receipt.status != TouchPublicationStatus::Fenced) return receipt;
    const uint64_t before = receipt.context.schema;
    const uint64_t generation = setControlSchemaWithGroups(entries, count, width, height, grabbed,
        deadZone, schemaVersion, config, groups);
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    pthread_mutex_lock(&s_schemaMutex);
    const auto current = touchPublicationContextLocked();
    receipt = generation != 0 ? s_touchAdmission.Complete(current, before == generation)
        : s_touchAdmission.Reject(current);
    pthread_mutex_unlock(&s_schemaMutex);
    logTouchPublicationReceipt("install", receipt);
    return receipt;
}

bool ConfirmTouchPublication(const std::string& operation, uint64_t token) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    const bool accepted = mode && s_touchAdmission.Confirm(operation, token, touchPublicationContextLocked());
    const auto receipt = s_touchAdmission.Query(touchPublicationContextLocked());
    pthread_mutex_unlock(&s_schemaMutex);
    if (accepted) logTouchPublicationReceipt("ui-confirm", receipt);
    return accepted;
}
TouchPublicationReceipt AbortTouchPublication(const std::string& operation) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    const auto receipt = s_touchAdmission.Abort(operation, touchPublicationContextLocked());
    pthread_mutex_unlock(&s_schemaMutex);
    logTouchPublicationReceipt("abort", receipt);
    return receipt;
}
bool AcceptTouchUiPublication(uint64_t token) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    const auto receipt = s_touchAdmission.Query(touchPublicationContextLocked());
    const bool accepted = mode && receipt.status != TouchPublicationStatus::Stale &&
        receipt.context.surface != 0 && s_touchAdmission.AcceptsUiToken(token);
    pthread_mutex_unlock(&s_schemaMutex);
    return accepted;
}
bool AcceptTouchUiContinuation(uint64_t token) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    const bool accepted = mode && !mode.grabbed() && touchAdmissionAcceptsUiContinuationLocked(token);
    pthread_mutex_unlock(&s_schemaMutex);
    return accepted;
}
bool OwnsTouchUiPublicationToken(uint64_t token) {
    const auto receipt = QueryTouchPublication();
    // Query在同一递归gate内取快照，调用方NAPI继续持gate直到写覆盖区，不能check后换目标。
    return token != 0 && receipt.token == token && receipt.context.surface != 0 &&
        (receipt.status == TouchPublicationStatus::Committed || receipt.status == TouchPublicationStatus::Unchanged ||
         (receipt.status == TouchPublicationStatus::Idle && !receipt.fenced));
}

uint64_t AcquireTouchModal(const std::string& owner) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    const bool alreadyModal = s_touchAdmission.HasModal();
    const uint64_t token = s_touchAdmission.AcquireModal(owner);
    if (token && !alreadyModal) retireTouchScopeLocked();
    const auto receipt = s_touchAdmission.Query(touchPublicationContextLocked());
    pthread_mutex_unlock(&s_schemaMutex);
    if (token) logTouchPublicationReceipt("modal-enter", receipt);
    schemaWakeDeadlineWorker();
    return token;
}
bool ReleaseTouchModal(uint64_t token) {
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    // 只解除本租约，不重发被模态退休的按键，也不清别人publication或modal。
    const bool released = s_touchAdmission.ReleaseModal(token);
    if (released) logTouchPublicationReceipt("modal-exit", QueryTouchPublication());
    return released;
}

void TouchContextPolicyChanged(double density, uint32_t transform) {
    if (!std::isfinite(density) || density <= 0 || density > 16) return;
    std::lock_guard<std::recursive_mutex> gate(s_surfaceInputGateMutex);
    if (transform == UINT32_MAX) transform = s_touchContextTransform;
    if (density == s_touchContextDensity && transform == s_touchContextTransform) return;
    AuthoritativeGrabInputTransaction mode;
    std::lock_guard<std::mutex> touch(s_touchStateMutex);
    if (mode) (void)consumeGrabEpochLocked(mode.grabbed());
    pthread_mutex_lock(&s_schemaMutex);
    retireTouchScopeLocked();
    s_touchContextDensity = density;
    s_touchContextTransform = transform;
    s_displayDensity.store(density, std::memory_order_release);
    if (s_touchContextPolicy != UINT64_MAX) ++s_touchContextPolicy;
    // 菜单缓存立即更新，不能等下一次像素尺寸改变才得到新阈值；invalid零视口仍安全。
    s_menuTouch.Configure(s_schemaWidthPx, s_schemaHeightPx, density, s_touchConfig, emitMenuInteraction);
    (void)s_touchAdmission.Query(touchPublicationContextLocked());
    pthread_mutex_unlock(&s_schemaMutex);
    schemaWakeDeadlineWorker();
}
}
