// cursor_lock.h — grabbed-mode system cursor lock.
//
// A physical mouse can only be a first-class input source, parallel to the
// on-screen virtual controls, if the system cursor is taken out of the picture
// while the game holds the pointer. Hiding it is not enough: an unlocked cursor
// still travels, clamps at the display edge (which silently truncates relative
// motion) and still sits over ArkUI controls, so a drag can press a virtual
// button. OH_WindowManager_LockCursor with isCursorFollowMovement=false pins it.
//
// Availability: the platform symbol exists since API 22 while this module's
// compatibleSdkVersion is lower, so it is resolved with dlopen/dlsym instead of
// being linked directly. On an older device the lock is simply reported as
// unsupported and the caller keeps the previous behaviour.
#ifndef AMCL_CURSOR_LOCK_H
#define AMCL_CURSOR_LOCK_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    // The request was applied by the window manager.
    AMCL_CURSOR_LOCK_OK = 0,
    // Already in the requested state; no platform call was made.
    AMCL_CURSOR_LOCK_UNCHANGED = 1,
    // Symbol missing (API < 22) or the device reports no capability.
    AMCL_CURSOR_LOCK_UNSUPPORTED = 2,
    // windowId was not a usable identity.
    AMCL_CURSOR_LOCK_INVALID_ARGUMENT = 3,
    // The window manager rejected the call; see the logged platform code.
    AMCL_CURSOR_LOCK_PLATFORM_ERROR = 4,
    // The public API exists, but the application does not hold
    // ohos.permission.LOCK_WINDOW_CURSOR.
    AMCL_CURSOR_LOCK_PERMISSION_DENIED = 5,
} AmclCursorLockResult;

// Requests the grabbed-mode cursor lock for `windowId`.
//
// `locked` true pins the cursor inside the focused window and stops it from
// following mouse movement; false releases it. Repeated identical requests are
// cheap and return AMCL_CURSOR_LOCK_UNCHANGED without calling the platform.
//
// The window manager only accepts this from the focused window and drops the
// lock automatically on focus loss, so callers must re-apply after regaining
// focus. `amcl_cursor_lock_note_focus_lost` records that system-side release so
// the next lock request is not skipped as redundant.
AmclCursorLockResult amcl_cursor_lock_set(int32_t windowId, bool locked);

// Marks the cached lock state as released because the platform auto-unlocked on
// focus loss. Does not call the window manager.
void amcl_cursor_lock_note_focus_lost(void);

// True when this build/device resolved the platform lock symbols at all.
bool amcl_cursor_lock_supported(void);

// True when the cursor is currently believed to be locked by this process.
// Used to decide that absolute pointer coordinates carry no motion information.
bool amcl_cursor_lock_active(void);

// 相对位移通道刚投递过一个**非零**样本。给钉住模式的自愈看门狗喂数据。
//
// 为什么需要：钉住(follow=false)是"鼠标飘出窗口 / 视角到边就停"的正确修复，
// 但"钉住之后 rawDelta 仍然照常上报"这件事只在部分设备上验证过。若某台设备钉住后
// 连相对量也停了，视角会完全消失 —— 那比有边界严重得多。本函数让看门狗能区分
// "玩家还没动鼠标"和"这台设备钉住后就没有相对量了"。
//
// 热路径安全：稳态下只做一次 relaxed 原子读。可从任意线程调用。
void amcl_cursor_lock_note_relative_sample(void);

// 窗口层看到了一个鼠标事件。由 window_event_filter 的鼠标过滤回调调用。
//
// 它回答的是"鼠标到底有没有在动"，而不是"我们收到了什么"—— 窗口过滤器位于 ArkUI
// 分发之前，不受任何门控/转换影响，所以是这件事最可靠的信号。
//
// 看门狗需要它是因为第一版少了这条判据：只看"有没有相对样本"会把**玩家静止不动**
// 误判成"设备在钉住模式下没有 rawDelta 能力"，从而永久降级回跟随模式（真机已复现）。
void amcl_cursor_lock_note_pointer_activity(void);

// 看门狗检查。返回 true 表示**刚刚降级**到跟随模式，调用方必须重新加锁一次，
// 新模式才会生效（窗口管理器只在 lock 调用时读这个参数）。
//
// 由 ArkTS 既有的 250ms grab 对账轮询调用，不新增定时器。降级是一次性的：
// 反复在两种模式间切换会让手感忽好忽坏，比稳定在跟随模式更糟。
bool amcl_cursor_lock_watchdog_tick(void);

// ⚠️ 关于 `isCursorFollowMovement` 的取值 —— **当前默认是 `false`（钉住）**，
// 见 `cursor_lock.cpp` 的 `std::atomic<bool> g_followMovement{false}`。
//
// 这一行曾写作「已有真机定论，**不要再改成 false**：follow=true（跟随，**现行**）」——
// 那是 §23/§24 时期的状态，**与现在的代码正好相反**，而且是祈使句：照它做会把默认值
// 改回跟随，重新引入用户报过的「鼠标飘在外面 + 转视角还是有边界」。
// （同族的第二处在 `touch_input.cpp` 的镜像分支里：「保持 follow=true」，同样已更正。）
//
// 下面两段仍然有效，但要按"钉住是现行默认"来读：
//
//   follow=true（跟随，**已不是默认**）：平台把"鼠标左键的点击与滑动、以及轴事件"转成触摸事件时，
//     合成触点的坐标就是光标位置，所以坐标会真实变化。滚轮正是靠这个纵向位移被识别
//     出来的（touch_input.cpp 的运动学指纹）。代价是光标会走到窗口边缘被夹住，
//     "按住左键拖动"到边缘就停 —— 因为那段位移只以合成触点坐标存在。
//
//   follow=false（钉住，**2026-08-19 起为默认**）：光标不动，因此永远不会抵达屏幕边缘，
//     `rawDelta` 可以无限持续 —— 这就是桌面端 pointer capture 的标准做法。
//
// ⚠️ 关于这条取值的历史，必须连着前提一起读，否则会看成结论反复：
//
//   §23/§24 曾**否证**过钉住模式。但那次否证的前提是"按住左键期间的视角来自**镜像
//   触点坐标**"——钉住会让那条坐标恒定，于是视角完全不动。该前提在本轮之前已经消失：
//   镜像视角通道已按用户要求整体删除，视角**唯一来源是 rawDelta**。
//   前提变了，所以结论必须重算，而不是沿用。
//
//   反过来，跟随模式在新前提下有一个此前被镜像通道掩盖的缺陷：系统指针照旧移动，
//   一旦漂到屏幕边缘就不再变化 ⇒ MOVE 停止上报 ⇒ rawDelta 断流 ⇒ 视角卡死。
//   用户报的「鼠标飘在外面」与「转视角还是有边界」是同一件事的两个侧面。
//
// 兜底：`amcl_cursor_lock_watchdog_tick()`。若钉住后 2s 内一个相对样本都没有，
// 说明该设备钉住后连 rawDelta 也停了（视角全无，比有边界严重得多），
// 此时一次性降级回 follow=true 并打 ERROR 日志。降级只在本进程内生效。

// 查询系统指针当前所在的 display 坐标。
//
// 为什么需要它：平台把鼠标左键与滚轮**转换成触摸事件**下发，而转换后的包与真手指
// 在元数据上难以区分。唯一可靠的区别是**位置**：合成包的坐标就是指针位置。
//
// ⚠️ 这里曾写作「真机 618/618 个包 source 都是 TOUCHSCREEN、tool 都是 FINGER、
// **deviceId 都是 0**」，且**没有设备限定**。两处需要更正：
//   ① 那是 **API 24 平板**的实测。API 26 手机上
//      `OH_NativeXComponent_GetTouchEventSourceType` 已恢复正常
//      （鼠标合成包报 `source=MOUSE`，真手指报 `TOUCHSCREEN`，见计划文档 §34.3）；
//   ② 「deviceId 都是 0」这一条**当时并没有被测过** —— `touch_input.cpp` 自己写着
//      "`OH_NativeXComponent_TouchEvent.deviceId` 存在但**代码从未读过它**，只能由真机
//      回答"，并为此新增了 `AMCL_TOUCHID` 探针。把未测的字段写成"已实测为 0"，
//      会让下一个人认为它没有区分度、从而删掉那个刚加的探针。
// 触摸层据此拒绝把这类包绑到虚拟控件上（"鼠标绝不能点虚拟按键"）。
//
// `OH_Input_GetPointerLocation`（@since 20）不需要任何权限，但要求本应用是获焦应用
// （否则返回 INPUT_APP_NOT_FOCUSED=3900009），且设备当前有指针设备
// （否则 INPUT_DEVICE_NO_POINTER=3900010）。符号用 dlsym 探测，缺失即返回 false，
// 调用方退回"整数坐标"这一条较弱的判据，行为不会变差。
//
// 返回 true 时 *displayX/*displayY 有效。线程安全。
bool amcl_pointer_location_query(double* displayX, double* displayY);

#ifdef __cplusplus
}
#endif

#endif  // AMCL_CURSOR_LOCK_H
