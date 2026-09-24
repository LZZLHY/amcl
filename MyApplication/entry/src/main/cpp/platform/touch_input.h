// touch_input.h — 触摸输入处理
#ifndef MC_OHOS_TOUCH_INPUT_H
#define MC_OHOS_TOUCH_INPUT_H

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <arkui/ui_input_event.h>
#include <stdbool.h>
#include <stdint.h>

#include "../input/legacy_physical_outcome.h"

#ifdef __cplusplus
extern "C" {
#endif

// Surface input gate. Lifecycle transactions and native input callbacks share
// this recursive lock so a successful deactivate waits for every accepted
// callback to finish before typed lifecycle/cancel publication begins.
void ohos_surface_input_gate_lock(void);
void ohos_surface_input_gate_unlock(void);
uint64_t ohos_surface_input_gate_accept(OH_NativeXComponent* component, void* window);
uint64_t ohos_surface_input_gate_accept_component(OH_NativeXComponent* component);
// Records an OnFocus/OnBlur callback at its entry, before the caller performs
// the authoritative accept. The line includes both incoming and gate-owned
// identities plus monotonic entry/rejection counts so a missing callback and a
// pointer-mismatch rejection are distinguishable on device.
void ohos_surface_input_gate_log_focus_edge(
    bool focused, OH_NativeXComponent* component, void* window);
// Locks the current active publication until end_current_transaction. A zero
// token is fail-closed and does not retain the lock. Callers must never route
// typed and legacy physical ingress outside one successful transaction.
uint64_t ohos_surface_input_gate_begin_current_transaction(void);
void ohos_surface_input_gate_end_current_transaction(uint64_t token);

// Publication mutation seam. The gate lock is held while the callback runs.
// Publish/update preserve the previous gate on callback failure. A successful
// replacement retires the old pointer identity permanently; an exact reused
// pair cannot be distinguished by this callback ABI and therefore stays
// fail-closed. Clear is an authoritative lifecycle boundary once the current
// identity was accepted: it permanently invalidates the gate before mutation,
// and mutation failure stays fail-closed because the OS surface was destroyed.
typedef uint64_t (*OhosSurfacePublicationMutation)(
    void* context, uint64_t expectedPublicationGeneration);
uint64_t ohos_surface_input_gate_publish_transaction(
    OH_NativeXComponent* component, void* window,
    OhosSurfacePublicationMutation mutation, void* context);
uint64_t ohos_surface_input_gate_update_transaction(
    OH_NativeXComponent* component, void* window,
    OhosSurfacePublicationMutation mutation, void* context);
uint64_t ohos_surface_input_gate_clear_transaction(
    OH_NativeXComponent* component, void* window,
    OhosSurfacePublicationMutation mutation, void* context);
uint64_t ohos_surface_input_gate_clear_active_transaction(
    OhosSurfacePublicationMutation mutation, void* context,
    uint64_t* outExpectedPublicationGeneration);

// XComponent DispatchTouchEvent 回调（由 xcomponent.cpp 注册）
void OnDispatchTouchEvent(OH_NativeXComponent* component, void* window);

// 物理鼠标 / 悬浮 / 滚轮（native）回调（由 xcomponent.cpp 注册）
void OnDispatchMouseEvent(OH_NativeXComponent* component, void* window);
void OnDispatchHoverEvent(OH_NativeXComponent* component, bool isHover);
// 2026-05-29：滚轮经 UIInputEvent AxisEvent 上报（RegisterUIInputEventCallback type=AXIS）
void OnDispatchAxisEvent(OH_NativeXComponent* component, ArkUI_UIInputEvent* event);
// ArkUI MouseEvent button fallback. The implementation arbitrates against the
// native XComponent button channel before publishing one physical edge.
void ohos_route_arkui_physical_mouse_button(
    uint64_t deviceId, int32_t arkuiButton, int32_t action, int32_t mods,
    uint32_t deviceClass, uint64_t monotonicTimeNs);
// native XComponent 的 AXIS 回调是否为当前滚轮所有者（薄封装，真正的判定在
// input_channel_policy）。保留是为了不改动既有 NAPI 名字。
bool ohos_native_wheel_channel_seen(void);

// 滚轮通道申请：一次调用完成"登记本通道确实送来过样本" + "询问它是否为当前所有者"。
// 参数取 AmclInputChannel 里的滚轮档（NATIVE_AXIS / ARKTS_AXIS / AXIS_PAN /
// TOUCH_WHEEL）；未知取值 fail-closed 返回 false。
//
// **所有**滚轮产出点都必须先过这一关。此前 ArkTS 的轴驱动 Pan 通道漏掉了这个询问，
// 于是它与 native AXIS 同时产出且符号相反（真机一秒 `nativeAxisScroll=9` /
// `scrollOut=19`），用户表现为"滚轮方向是反的，但快速滚动有时又正常"。
bool ohos_wheel_channel_claim(int channel);

// 发布屏幕像素密度（display.densityPixels）。
//
// 用途：把"转换后的触摸流"里的位移（单位 = surface 物理 px）换算成与 ArkTS
// `rawDeltaX/Y` 相同的量纲。官方文档明确 rawDelta「API 26 之前返回的并非原始数据，
// 而是原始数据缩小了 X 倍，X 为系统的显示大小比例」，实测量子恰为 1/2.125。
// 两条视角来源若量纲不一致，按住左键拖动的手感会比平时快一倍多 —— 这正是
// "按住左键移动鼠标变得非常怪异"的可测成因之一。未发布时默认 1.0（不缩放）。
void ohos_set_display_density(double density);

// 已发布的屏幕像素密度；未发布或非法时返回 1.0（不缩放）。
//
// 菜单态绝对指针必须用它做 vp→px 换算：ArkUI 的 `MouseEvent.x/y` 单位是 **vp**
// （官方《支持鼠标输入事件》属性表明确标注），而 bridge 的 `setMenuCursor` 期望的是
// **组件内物理 px** —— 手指那条菜单通道送的就是 XComponent 触点的 px。
// 两者混用会让 MC 的菜单光标只落在正确位置的 1/density 处（本机 density=3.25，
// 即约 31%），表现为**鼠标点不动菜单、悬浮也没有高亮**。
double ohos_display_density(void);

// 标记"轴驱动的 Pan 手势（鼠标滚轮 / 触控板双指）正在进行"。
//
// 真机事实：本机滚轮既不走 native AXIS 回调（注册成功、零样本），也不走 ArkTS
// onAxisEvent（零调用），而是被 ArkUI 归一化成**合成的手指滑动**投给 XComponent
// （MMI 的 axis-begin/end 次数与触摸 DOWN/UP 次数 1:1 对齐，且期间触摸屏设备无任何
// 上报）。那条合成滑动落在虚拟控件之外时会被解释成空白 look —— 这就是"滚轮上下转视角"。
//
// ArkTS 侧用带 tag 的 PanGesture 认领它（`axisVertical` 仅在轴驱动时有值，SDK 明确），
// 并在手势期间通过本函数通知 native 抑制空白 look。为什么不只依赖手势竞争把触摸取消掉：
// 那要依赖"祖先手势胜出后子组件收到 CANCEL"这一未取证的行为；显式抑制窗口让修复
// 不依赖任何未验证前提。抑制只作用于**空白 look**，按钮/摇杆/滚轮区/物品栏不受影响。
void ohos_note_axis_pan_active(int active);

// 镜像手势（左键按住）是否正在进行。用于把"按住期间的 rawDelta 到底是不是 0"
// 这件事记进日志——它决定了光标锁能否用钉住模式。
int ohos_touch_mirror_gesture_active(void);

// 标记 ArkTS 相对移动通道刚投递过样本。
//
// 平台在"不按键移动"与"按住左键拖动"之间切换视角的承载通道（前者 ArkTS onMouse
// rawDelta，后者镜像 Touch MOVE）。触摸侧据此做空闲交接：ArkTS 通道活跃时镜像只更新
// 基准不产生视角，避免同一位移被两条通道各算一遍。
void ohos_note_arkts_relative_motion(void);

// ⚠️ 这里曾声明过三个窗口级过滤器的接管入口
// （`ohos_route_window_filter_left_button` / `ohos_release_window_filter_left_claim`
//   / `ohos_route_window_filter_wheel`）。**已按真机证据整体删除，不要再加回来。**
// 左键接管收益为零却与镜像通道互抢所有权导致左键卡死与菜单点不动；
// 轴事件接管在两台设备上都取到 0 个样本。理由与故障表现见
// window_event_filter.cpp 中 MouseEventFilter 上方的注释。

// ArkTS 相对通道最近是否投递过**非零**位移（判据与镜像交接窗口同一份，见实现）。
//
// 唯一用途是窗口级过滤器的自愈看门狗（window_event_filter.cpp）：掐断鼠标派生的
// 合成触摸包之后，"onMouse 会恢复投递"是官方从未承诺的推断。若一次左键拖动期间
// 既没有合成包（被我们掐了）又没有 ArkTS 相对样本，说明该推断在本设备不成立，
// 过滤必须自动停止并把视角通道还给触摸镜像。
//
// 返回 1 表示活跃。可从任意线程调用（内部只读一个原子时间戳）。
int ohos_arkts_relative_channel_live(void);
// NAPI 可调用函数（ArkTS → C 层）
// ⚠️ 这里曾声明 `ohos_register_button` / `ohos_register_joystick` /
// `ohos_clear_buttons` / `ohos_clear_joystick`。**已整体删除**（含 NAPI 入口、
// index.d.ts、obfuscation-rules 与 ArkTS 调用点）：它们维护的矩形表唯一读取方是
// `hitButton()`/`isInJoystick()`，而那两个函数只在一个永不执行的分支里被调用。
// 触控虚拟按键端的权威表述是 Control Schema（`ohos_set_control_schema`）。
//
// ⚠️ 墓碑: `ohos_set_comp_size` 已删除（2026-08-21，同一个形状的第二例）——
// 它写入的两个 static 终点零读者。组件尺寸经 `ohos_set_control_schema` 的
// `compW`/`compH` 形参传入，那两个形参是活的（矩形越界校验用），详见计划 §64.3。
void ohos_send_cursor_delta(double dx, double dy);
// 菜单模式下的光标绝对位置（组件内物理 px）。语义必须保持"绝对"：菜单里系统指针箭头可见
// 且我们无法移动它，菜单光标一旦与箭头分离，悬浮与点击就会落到别处。
void ohos_send_cursor_pos(double x, double y);
// Checked variants report whether the legacy bridge accepted the ingress.
// They preserve the same router/owner behavior as the void compatibility APIs.
bool ohos_send_cursor_delta_checked(double dx, double dy);
bool ohos_send_cursor_pos_checked(double x, double y);
// Publishes the libentry -> libglfw reverse trampolines. Idempotent. Call it at
// NAPI registration: the typed look consumer can be the very first input event,
// which is too early for the bridge-resolve path to have published anything.
void ohos_input_publish_trampolines(void);
// Logs one AMCL_LOOK snapshot: ingress/emit counts, backlog depth, boundary
// discards and whether the funnel's conservation identity currently holds.
// Look is structurally invisible to the channel census and the ledger, so this
// is the only observation surface it has.
void ohos_log_look_pipeline_state(void);
int ohos_is_grabbed(void);
// Samples the bridge's process-local grab SSOT. False means the bridge owner
// is unavailable and callers must fail closed instead of guessing menu mode.
bool ohos_sample_authoritative_grabbed_mode(bool* grabbed);
bool ohos_begin_authoritative_grab_input_transaction(bool* grabbed);
void ohos_end_authoritative_grab_input_transaction(void);
void ohos_send_key_event(int key, int scancode, int action, int mods);
void ohos_send_mouse_event(int button, int action, int mods);
void ohos_send_scroll_event(int xoffset, int yoffset);
// ---- 未申报端身份的兼容入口（fail-soft，勿用于新调用点）----
// 它们把持有记录标成 AMCL_INPUT_SOURCE_NONE，在端级复位日志的 untagged 一栏可见。
bool ohos_send_key_event_checked(int key, int scancode, int action, int mods);
bool ohos_send_mouse_event_checked(int button, int action, int mods);
bool ohos_send_scroll_event_checked(int xoffset, int yoffset);

// ---- 按端申报的入口（新调用点一律用这一组）----
//
// `source` 取 AmclInputSource（见 platform/input_source.h）。端身份决定：
//   · 持有记录归属哪个端 ⇒ RELEASE/REPEAT 只与同端配对，按端选择性释放才有可能；
//   · 视角走哪一端的量纲归一系数；
//   · 诊断计数落在端这条轴的哪一栏。
// 物理键鼠端**不走**这组入口：它有专用身份的 ohos_route_physical_* 系列。
bool ohos_send_source_key_event_checked(int source, int key, int scancode,
                                        int action, int mods);
bool ohos_send_source_mouse_event_checked(int source, int button, int action,
                                          int mods);
// 滚轮不进 owner 域（无持续按下态）；端身份在这里另有一个作用：**它选平面**。
// `AMCL_INPUT_SOURCE_PHYSICAL_KBM` + 路由位为真 ⇒ 走 typed 平面，此时 `gateAccepted`
// 必须如实报告调用方是否持有 SurfaceInputGateTransaction（与 key/button 两条事务同约束）；
// 其余端（虚拟滚轮条 / 手柄 L1R1）留在 legacy ring 上，不读该参数。详见计划 §95.1。
bool ohos_send_source_scroll_event_checked(int source, int xoffset, int yoffset,
                                          bool gateAccepted);
bool ohos_send_source_cursor_delta_checked(int source, double dx, double dy);

// 只释放 `source` 这一端在 external 表里持有的输出，其余端不受影响。
// 设备插拔与端级生命周期边界用它，取代"全局 releaseAll 连带误放其它端"。
void ohos_release_input_source_held(int source);

// ArkTS 侧的端自己复位之后记一笔，让端级复位日志各栏都有生产者。
void ohos_note_input_source_reset(int source);

// 输入不变量自检：采样进程状态、交给纯求值器判定、破坏时打一行 error。
// 稳态零输出，可以放在高频轮询里；同一条破坏只上报一次，不刷屏。
// **只在连续两次采样都看到同一条破坏时才报** —— 计数器是累计的，真实破坏永久成立，
// 而采样不是原子的（两个独立计数器之间存在微秒级窗口），瞬时失衡会自愈。
// 判定的关系与理由见 platform/input_invariants.h。
void ohos_input_invariant_tick(void);

// 把 external 持有账目（按端的 live / acquired / released）打成一行。
// 平台手势不产生 look/scroll、不参与按端复位遍历，持有账目是它唯一留下痕迹的地方；
// 同时它也是 `heldBalance` 不变量破坏后唯一能定位问题的三个数。
void ohos_log_external_held_state(void);
// Dedicated physical-key compatibility route. `deviceId + ohosKeyCode` is the
// lifecycle identity; mappedKey is captured only on Down. Repeat/Up use that
// snapshot so a transient missing mapper cannot release the wrong key or leave
// the original held. routedMappedKey is set to -1 unless a real transition was
// accepted; callers use the actual snapshot for reconciliation.
AmclLegacyPhysicalOutcome ohos_route_physical_key_event_checked(
    uint64_t deviceId, uint32_t ohosKeyCode, int mappedKey, int scancode,
    int action, int mods, int* routedMappedKey);
void ohos_send_char_event(int codepoint);             // 阶段 2.8：IME / 可打印字符
void ohos_send_char_mods_event(int codepoint, int mods);
void ohos_set_touch_paused(bool paused);

// 生命周期统一取消原因。数值只用于低频诊断，不影响释放策略；所有原因都必须让 ledger 归零。
typedef enum {
    AMCL_INPUT_CANCEL_PAUSE = 1,
    AMCL_INPUT_CANCEL_BACKGROUND = 2,
    AMCL_INPUT_CANCEL_SURFACE_LOST = 3,
    AMCL_INPUT_CANCEL_PAGE_DISPOSE = 4,
    AMCL_INPUT_CANCEL_WINDOW_RECREATE = 5,
    // Blur can suppress future UP events without destroying the surface, so it
    // needs its own diagnostic reason while sharing the release-all policy.
    AMCL_INPUT_CANCEL_FOCUS_LOST = 6
} AmclInputCancelReason;
void ohos_cancel_all_input(int reason);
void ohos_set_look_sensitivity(float v);  // 阶段 1.3：视角灵敏度（0.1..5.0，默认 1.0）
void ohos_set_invert_y(bool b);           // 阶段 1.3：Y 轴倒置
void ohos_set_look_smoothing(float alpha); // 守恒 backlog 响应系数（0.1..1.0，1.0=立即输出；正常 UP 补齐余量）
void ohos_set_look_accel(float v);          // 方案 C：视角加速强度（0..1，0=关闭）

// ==================== Control Schema v2 ====================
// 单个控件描述（物理 px，已含 density）。这是跨 NAPI/C 边界的 POD；任何新字段都必须
// 同步提升 AMCL_CONTROL_SCHEMA_VERSION，禁止用“结构尾部碰巧兼容”掩盖协议错配。
#define AMCL_CONTROL_SCHEMA_VERSION 2
#define AMCL_CONTROL_SCHEMA_MAX_CONTROLS 256
#define AMCL_CONTROL_ID_MAX_BYTES 23
#define AMCL_CONTROL_MAX_KEYS 6

typedef struct {
    char id[24];     // UTF-8 字节长度 1..23；NAPI/native 双层拒绝超长或重复，绝不静默截断
    int kind;        // ControlType：0=button 1=joystick 2=scroll 3=drawer 4=hotbar
    int handledBy;   // 0=native 1=arkts
    float x, y, w, h;
    // 明确以物理 px 下发的命中扩张量。ArkTS owner 强制按 exact rect，native owner 才使用此值。
    float hitSlop;
    int keyOrMouse;  // 首键（button/hotbar）；组合键场景仍填 keys[0]
    int trigger;     // 0=press 1=toggle 2=doubleTap 3=longPress
    int dragLook;    // 0/1
    int haptic;      // 0/1；键边沿由 native 产生，低频触觉请求回 UI 线程执行
    int keys[AMCL_CONTROL_MAX_KEYS];
    int keyCount;
} AmclCtrlEntry;

// handledBy=arkts 的控件仍由 ArkUI 的 exact visual rect 处理；保留该回调用于显式 native 激活场景。
void amcl_fire_control_activated(const char* id);
// native 是按钮输出与视觉边沿的单一真相源；TSFN 仅把最终状态投影到 UI。
void amcl_fire_button_pressed(const char* id, int pressed);
// native 线程只请求触觉，真正的系统触觉 API 必须在 ArkTS/UI 线程执行。
void amcl_fire_haptic(int strength);

// 整表替换是事务：先完整验证，失败返回 0 且不改变当前 generation；成功返回非 0 generation。
// 空表是合法的 fail-closed 发布，可用于清除旧热区。native 会再次验证所有字段，不能只信任 NAPI。
uint64_t ohos_set_control_schema(const AmclCtrlEntry* entries, int count,
                                 float compW, float compH, int grabbed, float deadZone,
                                 int schemaVersion);

#ifdef __cplusplus
}

namespace amcl::input {
class AuthoritativeGrabInputTransaction final {
public:
    explicit AuthoritativeGrabInputTransaction(bool enabled = true)
        : active_(enabled &&
                  ohos_begin_authoritative_grab_input_transaction(&grabbed_)) {}
    ~AuthoritativeGrabInputTransaction() {
        if (active_) ohos_end_authoritative_grab_input_transaction();
    }
    AuthoritativeGrabInputTransaction(
        const AuthoritativeGrabInputTransaction&) = delete;
    AuthoritativeGrabInputTransaction& operator=(
        const AuthoritativeGrabInputTransaction&) = delete;
    explicit operator bool() const { return active_; }
    bool grabbed() const { return grabbed_; }
private:
    bool grabbed_ = false;
    bool active_ = false;
};

class SurfaceInputGateTransaction final {
public:
    SurfaceInputGateTransaction()
        : token_(ohos_surface_input_gate_begin_current_transaction()) {}
    ~SurfaceInputGateTransaction() {
        ohos_surface_input_gate_end_current_transaction(token_);
    }
    SurfaceInputGateTransaction(const SurfaceInputGateTransaction&) = delete;
    SurfaceInputGateTransaction& operator=(const SurfaceInputGateTransaction&) = delete;
    explicit operator bool() const { return token_ != 0; }
    uint64_t token() const { return token_; }
private:
    uint64_t token_;
};
}  // namespace amcl::input
#endif

#endif // MC_OHOS_TOUCH_INPUT_H
