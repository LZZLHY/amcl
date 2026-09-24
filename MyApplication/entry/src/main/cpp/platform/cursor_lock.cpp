#include "cursor_lock.h"

#include <dlfcn.h>
#include <hilog/log.h>
#include <time.h>

#include <atomic>
#include <mutex>

#undef LOG_TAG
#define LOG_TAG "AMCL_CURSOR_LOCK"

namespace {

using LockCursorFn = int32_t (*)(int32_t, bool);
using UnlockCursorFn = int32_t (*)(int32_t);

// OH_WindowManager_LockCursor is introduced in API 22 and this module targets a
// lower compatible version, so the symbols must not create a load-time
// dependency. dlopen keeps an older device loading normally and simply reporting
// "unsupported" instead of failing to start.
struct Resolver {
    LockCursorFn lock = nullptr;
    UnlockCursorFn unlock = nullptr;
    bool attempted = false;
};

std::mutex g_mutex;
Resolver g_resolver;
bool g_locked = false;
int32_t g_lockedWindowId = 0;
// Read from the input hot path without taking the mutex.
std::atomic<bool> g_lockedFlag{false};

// ---------------------------------------------------------------------------
// isCursorFollowMovement：钉住(false) 还是跟随(true)
//
// 2026-08-19 改为**默认钉住(false)**，并配一个自愈看门狗。理由链：
//
//   · 跟随模式下系统指针照旧移动。视角唯一来源是 `rawDelta`，而 rawDelta 只在指针
//     位置发生变化时才有非零值 —— 指针一旦漂到屏幕边缘就不再变化，MOVE 停止上报，
//     视角随之卡死。这同时解释了用户报的两件事：「鼠标飘在外面」与「转视角有边界」。
//   · 钉住模式让指针不动，因此永远不会抵达边缘，相对量可以无限持续 —— 这就是桌面端
//     pointer capture 的标准做法。
//   · 曾经否证过钉住模式（§23/§24），但那次的否证前提是"按住左键期间的视角来自
//     **镜像触点坐标**"，钉住会让那条坐标恒定。**镜像视角通道已于本轮之前删除**，
//     视角只剩 rawDelta 一条，所以那条否证不再适用。这是前提变了，不是结论反复。
//
// 风险与兜底：如果某台设备在钉住模式下连 rawDelta 都不再上报，那视角会完全消失 ——
// 比"有边界"严重得多。因此看门狗在"**确实有鼠标活动**却拿不到相对样本"时降级回跟随模式。
//
// ⚠️ 2026-08-19 修正一个真机误触发：第一版的判据是"加锁后 2s 内没有相对样本"，
// 但**玩家只是没动鼠标**时也满足这个条件 —— 于是看门狗把"没有活动"误判成"设备没有能力"，
// 永久降级回跟随模式，指针重新开始漂移。真机日志：
//     E AMCL_CURSOR_LOCK: cursor lock watchdog: no relative sample within 2000 ms ...
// 而同期玩家只是静止不动。
//
// 正确判据必须**同时**满足两条：
//   1. 窗口层确实看到了鼠标事件（`amcl_cursor_lock_note_pointer_activity()`，由
//      window_event_filter 的鼠标过滤回调喂 —— 它在 ArkUI 之前，不受任何门控影响，
//      是"鼠标到底有没有在动"最可靠的信号）；
//   2. 且这些活动**没有**转化成任何非零相对样本。
// 只有活动量越过阈值仍无相对样本，才说明钉住模式在本设备上真的取不到 rawDelta。
std::atomic<bool> g_followMovement{false};
// 本次加锁之后是否见过相对样本。
std::atomic<bool> g_sawRelativeSample{false};
// 本次加锁之后窗口层看到的鼠标事件数。只有它越过阈值，"没有相对样本"才有判定意义。
std::atomic<int32_t> g_pointerActivitySinceLock{0};
// 阈值：鼠标移动时窗口层约 110~127 事件/秒（真机实测），30 个事件≈0.25 秒的真实移动。
// 取这么小是因为它只需要区分"完全没动"与"动了"，不需要区分动多少。
constexpr int32_t kActivityRequiredForFallback = 30;
// 本次加锁的时间点（CLOCK_MONOTONIC ns）。0 = 未加锁。
std::atomic<int64_t> g_lockedAtNs{0};
// 已经降级过就不再重试：反复切换模式会让手感忽好忽坏，比稳定在跟随模式更糟。
std::atomic<bool> g_followFallbackLatched{false};
// 2s：足够覆盖"进入游戏后玩家先看一眼再动鼠标"的空档，又不至于让真正的失效拖太久。
constexpr int64_t kFollowFallbackWindowNs = 2000000000LL;

// WindowManager_ErrorCode values are stable public ABI values.  They are kept
// local because this compatibility build targets an SDK predating oh_window.h;
// including that header would turn the dlsym fallback into a load-time API-22
// dependency.
constexpr int32_t kWindowManagerNoPermission = 201;
constexpr int32_t kWindowManagerInvalidParam = 401;
constexpr int32_t kWindowManagerDeviceNotSupported = 801;
constexpr int32_t kWindowManagerInvalidWindowId = 1000;

AmclCursorLockResult CursorLockFailureResult(int32_t code) {
    if (code == kWindowManagerNoPermission) {
        return AMCL_CURSOR_LOCK_PERMISSION_DENIED;
    }
    if (code == kWindowManagerDeviceNotSupported) {
        return AMCL_CURSOR_LOCK_UNSUPPORTED;
    }
    if (code == kWindowManagerInvalidParam ||
        code == kWindowManagerInvalidWindowId) {
        return AMCL_CURSOR_LOCK_INVALID_ARGUMENT;
    }
    return AMCL_CURSOR_LOCK_PLATFORM_ERROR;
}

int64_t MonotonicNs() {
    struct timespec ts = {};
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

const Resolver& ResolveLocked() {
    if (g_resolver.attempted) return g_resolver;
    g_resolver.attempted = true;
    // RTLD_DEFAULT first: when the platform library is already part of the
    // process image there is no reason to bump its reference count.
    auto lock = reinterpret_cast<LockCursorFn>(
        dlsym(RTLD_DEFAULT, "OH_WindowManager_LockCursor"));
    auto unlock = reinterpret_cast<UnlockCursorFn>(
        dlsym(RTLD_DEFAULT, "OH_WindowManager_UnlockCursor"));
    if (!lock || !unlock) {
        void* handle = dlopen("libnative_window_manager.so", RTLD_NOW);
        if (handle) {
            lock = reinterpret_cast<LockCursorFn>(
                dlsym(handle, "OH_WindowManager_LockCursor"));
            unlock = reinterpret_cast<UnlockCursorFn>(
                dlsym(handle, "OH_WindowManager_UnlockCursor"));
            // The handle is deliberately never closed: the resolved pointers
            // must stay valid for the process lifetime.
        }
    }
    // Both directions are required. Keeping only one would let the process lock
    // the cursor with no way to release it.
    if (!lock || !unlock) {
        g_resolver.lock = nullptr;
        g_resolver.unlock = nullptr;
        OH_LOG_WARN(LOG_APP,
                    "cursor lock unavailable (lock=%{public}d unlock=%{public}d); "
                    "grabbed mode keeps the unlocked system cursor",
                    lock != nullptr ? 1 : 0, unlock != nullptr ? 1 : 0);
        return g_resolver;
    }
    g_resolver.lock = lock;
    g_resolver.unlock = unlock;
    OH_LOG_INFO(LOG_APP, "cursor lock symbols resolved");
    return g_resolver;
}

}  // namespace

extern "C" AmclCursorLockResult amcl_cursor_lock_set(int32_t windowId,
                                                    bool locked) {
    std::lock_guard<std::mutex> guard(g_mutex);
    const Resolver& resolver = ResolveLocked();
    if (!resolver.lock || !resolver.unlock) {
        return AMCL_CURSOR_LOCK_UNSUPPORTED;
    }
    // Unlock may legitimately target the previously locked window even if the
    // caller no longer knows a valid id, so only locking requires one.
    if (locked && windowId <= 0) {
        OH_LOG_WARN(LOG_APP, "refusing cursor lock for windowId=%{public}d",
                    windowId);
        return AMCL_CURSOR_LOCK_INVALID_ARGUMENT;
    }

    if (locked && g_locked && g_lockedWindowId == windowId) {
        return AMCL_CURSOR_LOCK_UNCHANGED;
    }
    if (!locked && !g_locked) {
        return AMCL_CURSOR_LOCK_UNCHANGED;
    }

    if (locked) {
        // 模式默认钉住（follow=false），依据与兜底见文件顶部 g_followMovement 的说明。
        // 一旦看门狗降级过就固定用跟随模式，不再反复切换。
        const bool follow = g_followMovement.load(std::memory_order_acquire);
        const int32_t code = resolver.lock(windowId, follow);
        if (code != 0) {
            OH_LOG_WARN(LOG_APP,
                        "OH_WindowManager_LockCursor(%{public}d) failed code=%{public}d",
                        windowId, code);
            return CursorLockFailureResult(code);
        }
        g_locked = true;
        g_lockedWindowId = windowId;
        g_lockedFlag.store(true, std::memory_order_release);
        // 看门狗计时从加锁成功那一刻开始，活动计数同时归零。
        g_sawRelativeSample.store(false, std::memory_order_release);
        g_pointerActivitySinceLock.store(0, std::memory_order_release);
        g_lockedAtNs.store(MonotonicNs(), std::memory_order_release);
        // ⚠️ multimodalinput 的原始输入通道（Monitor / Interceptor）**已被永久排除**，
        // 不要再往这里接。两条独立的证据链：
        //
        //   1) `OH_Input_AddMouseEventMonitor` 的 201 与权限无关，是设计如此。
        //      NDK 客户端在任何 IPC 之前先拦一道
        //      （frameworks/native/input/oh_input_manager.cpp）：
        //          if (!VerifySystemApp()) { if (!IsScreenCaptureWorking())
        //              return INPUT_PERMISSION_DENIED; }
        //      官方 C API 文档同样明写"该接口处于录屏场景时才允许调用"。
        //      本应用 accessTokenIdEx=0x8_200DFD7D，bit32=0 ⇒ 非系统应用；
        //      而 `atm dump -t` 确认 INPUT_MONITORING grantStatus=0（已授予）。
        //      即：权限没问题，是"非系统应用且未在录屏"这道门。
        //
        //   2) 即使打通也没用。`Input_MouseEvent` 的 getter 全集是
        //      DisplayX/Y、GlobalX/Y、Button、Action、AxisType、AxisValue、
        //      ActionTime、WindowId、DisplayId、CursorInfo —— **没有任何相对量**。
        //      所以 MMI 原始流在结构上就不可能提供无界位移，拦截器同理。
        //
        // 本机唯一的无界相对量是 ArkUI 的 `MouseEvent.rawDeltaX/rawDeltaY`（API 15）
        // 及其 native 等价物 `OH_ArkUI_MouseEvent_GetRawDeltaX/Y`。
        OH_LOG_INFO(LOG_APP,
                    "cursor locked to window %{public}d follow=%{public}d "
                    "(follow=0 pins the pointer so rawDelta never runs out of "
                    "screen; watchdog falls back to 1 if no relative sample "
                    "arrives)",
                    windowId, follow ? 1 : 0);
        return AMCL_CURSOR_LOCK_OK;
    }


    const int32_t releaseWindowId = g_lockedWindowId != 0 ? g_lockedWindowId : windowId;
    const int32_t code = resolver.unlock(releaseWindowId);
    // Clear local state regardless: the platform also drops the lock on focus
    // loss, so a failure here must not leave this process believing it still
    // owns a lock it cannot release.
    g_locked = false;
    g_lockedWindowId = 0;
    g_lockedFlag.store(false, std::memory_order_release);
    g_lockedAtNs.store(0, std::memory_order_release);
    if (code != 0) {
        OH_LOG_WARN(LOG_APP,
                    "OH_WindowManager_UnlockCursor(%{public}d) failed code=%{public}d",
                    releaseWindowId, code);
        return CursorLockFailureResult(code);
    }
    OH_LOG_INFO(LOG_APP, "cursor unlocked from window %{public}d",
                releaseWindowId);
    return AMCL_CURSOR_LOCK_OK;
}

extern "C" void amcl_cursor_lock_note_focus_lost(void) {
    std::lock_guard<std::mutex> guard(g_mutex);
    if (!g_locked) return;
    // The window manager already released it; only the cached state is stale.
    g_locked = false;
    g_lockedWindowId = 0;
    g_lockedFlag.store(false, std::memory_order_release);
    g_lockedAtNs.store(0, std::memory_order_release);
    OH_LOG_INFO(LOG_APP, "cursor lock released by focus loss");
}

extern "C" void amcl_cursor_lock_note_relative_sample(void) {
    // 热路径：绝不加锁。绝大多数调用只做一次 relaxed 读并直接返回。
    const int64_t lockedAt = g_lockedAtNs.load(std::memory_order_acquire);
    if (lockedAt == 0) return;  // 未加锁，看门狗不参与。
    if (g_sawRelativeSample.load(std::memory_order_relaxed)) return;
    g_sawRelativeSample.store(true, std::memory_order_release);
}

extern "C" void amcl_cursor_lock_note_pointer_activity(void) {
    // 由窗口级鼠标过滤回调调用（ArkUI 之前，不受任何门控影响）。
    // 稳态成本：一次 relaxed 读 + 未饱和时一次 relaxed 自增。
    if (g_lockedAtNs.load(std::memory_order_relaxed) == 0) return;
    if (g_pointerActivitySinceLock.load(std::memory_order_relaxed) >=
        kActivityRequiredForFallback) {
        return;  // 已经足够判定，不必继续累加。
    }
    g_pointerActivitySinceLock.fetch_add(1, std::memory_order_relaxed);
}

extern "C" bool amcl_cursor_lock_watchdog_tick(void) {
    // 由 ArkTS 的既有对账轮询（250ms）调用，不新开定时器。
    if (g_followFallbackLatched.load(std::memory_order_acquire)) return false;
    if (g_followMovement.load(std::memory_order_acquire)) return false;
    const int64_t lockedAt = g_lockedAtNs.load(std::memory_order_acquire);
    if (lockedAt == 0) return false;
    if (g_sawRelativeSample.load(std::memory_order_acquire)) return false;
    // **关键的第二条判据**：必须确实有鼠标活动。玩家静止不动同样"没有相对样本"，
    // 但那是没有输入，不是设备没有能力 —— 第一版少了这一条，导致只要进游戏后
    // 静止两秒就永久降级回跟随模式（真机已复现）。
    if (g_pointerActivitySinceLock.load(std::memory_order_acquire) <
        kActivityRequiredForFallback) {
        return false;
    }
    const int64_t now = MonotonicNs();
    if (now == 0 || now - lockedAt < kFollowFallbackWindowNs) return false;

    // 有实际鼠标活动、却一个相对样本都没有 ⇒ 本设备在钉住模式下确实不上报 rawDelta。
    // 视角完全消失比"有边界"严重得多，因此降级回跟随模式并闩住。
    bool expected = false;
    if (!g_followFallbackLatched.compare_exchange_strong(
            expected, true, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
        return false;
    }
    g_followMovement.store(true, std::memory_order_release);
    OH_LOG_ERROR(LOG_APP,
                 "cursor lock watchdog: %{public}d pointer events reached the "
                 "window layer within %{public}lld ms of pinning yet not one "
                 "produced a relative sample; falling back to follow=1 (the "
                 "cursor will drift again, but look keeps working)",
                 g_pointerActivitySinceLock.load(std::memory_order_relaxed),
                 static_cast<long long>(kFollowFallbackWindowNs / 1000000));
    // 调用方需要重新加锁一次，新模式才会真正生效。
    return true;
}



extern "C" bool amcl_cursor_lock_supported(void) {
    std::lock_guard<std::mutex> guard(g_mutex);
    const Resolver& resolver = ResolveLocked();
    return resolver.lock != nullptr && resolver.unlock != nullptr;
}

extern "C" bool amcl_cursor_lock_active(void) {
    return g_lockedFlag.load(std::memory_order_acquire);
}

// ---------------------------------------------------------------------------
// 指针位置查询（OH_Input_GetPointerLocation，@since 20，无权限）
//
// 同样用 dlopen("libohinput.so") 而不是链接：某些设备/系统版本没有该库时，
// 直接链接会让整个 libentry.so 装载失败，连触摸都没了。
// ---------------------------------------------------------------------------
namespace {

using GetPointerLocationFn = int32_t (*)(int32_t*, double*, double*);

std::mutex g_pointerMutex;
GetPointerLocationFn g_getPointerLocation = nullptr;
bool g_pointerAttempted = false;
// 只在第一次成功/失败各打一条，避免每个 DOWN 一行日志。
bool g_pointerLoggedOk = false;
bool g_pointerLoggedFail = false;

}  // namespace

extern "C" bool amcl_pointer_location_query(double* displayX, double* displayY) {
    if (!displayX || !displayY) return false;
    std::lock_guard<std::mutex> guard(g_pointerMutex);
    if (!g_pointerAttempted) {
        g_pointerAttempted = true;
        g_getPointerLocation = reinterpret_cast<GetPointerLocationFn>(
            dlsym(RTLD_DEFAULT, "OH_Input_GetPointerLocation"));
        if (!g_getPointerLocation) {
            void* handle = dlopen("libohinput.so", RTLD_NOW);
            if (handle) {
                g_getPointerLocation = reinterpret_cast<GetPointerLocationFn>(
                    dlsym(handle, "OH_Input_GetPointerLocation"));
                // handle 故意不 close：解析出的指针要在进程生命周期内保持有效。
            }
        }
        OH_LOG_INFO(LOG_APP,
                    "AMCL_PTRLOC OH_Input_GetPointerLocation resolved=%{public}d",
                    g_getPointerLocation != nullptr ? 1 : 0);
    }
    if (!g_getPointerLocation) return false;

    int32_t displayId = 0;
    double x = 0.0;
    double y = 0.0;
    const int32_t rc = g_getPointerLocation(&displayId, &x, &y);
    if (rc != 0) {
        if (!g_pointerLoggedFail) {
            g_pointerLoggedFail = true;
            // 3900009 = INPUT_APP_NOT_FOCUSED，3900010 = INPUT_DEVICE_NO_POINTER。
            OH_LOG_WARN(LOG_APP,
                        "AMCL_PTRLOC query failed rc=%{public}d "
                        "(3900009=notFocused 3900010=noPointer); "
                        "falling back to the integral-coordinate test only",
                        rc);
        }
        return false;
    }
    if (!g_pointerLoggedOk) {
        g_pointerLoggedOk = true;
        OH_LOG_INFO(LOG_APP,
                    "AMCL_PTRLOC first ok display=%{public}d at=%{public}.1f,%{public}.1f",
                    displayId, x, y);
    }
    *displayX = x;
    *displayY = y;
    return true;
}
