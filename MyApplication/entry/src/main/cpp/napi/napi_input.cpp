#include "../input/runtime_desktop_capability.h"
/**
 * napi_input.cpp — 输入事件 / 控件区域 / XComponent 尺寸 NAPI 实现
 */
#include "napi_input.h"
#include "napi_helpers.h"

#include "../input/platform_input_ingress.h"
#include "../input/input_trace.h"
#include "../input/text_utf8_codec.h"
#include "../platform/input_channel_census.h"
#include "../platform/touch_input.h"
#include "../platform/cursor_lock.h"
#include "../platform/cursor_capture_policy.h"
#include "../platform/native_mouse_route_policy.h"
#include "../platform/product_input_policy.h"
#include "../platform/unicode_scalar.h"
#include "../platform/window_event_filter.h"
#if AMCL_INPUT_GATE0_TELEMETRY
#include "../platform/gate0_input_telemetry.h"
#endif

#include <hilog/log.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <utility>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "NAPI_INPUT"

namespace {

// --- 触摸事件（已改为 XComponent native DispatchTouchEvent 处理）---
napi_value SendTouchEvent(napi_env env, napi_callback_info info) {
    return amcl::napi::MakeUndefined(env);
}

// --- 虚拟按键事件注入（ArkTS 虚拟控件 → NAPI → input_bridge ring buffer）---
napi_value SendKeyEvent(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t key = 0, scancode = 0, action = 0, mods = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &key);
    if (argc >= 2) napi_get_value_int32(env, args[1], &scancode);
    if (argc >= 3) napi_get_value_int32(env, args[2], &action);
    if (argc >= 4) napi_get_value_int32(env, args[3], &mods);
    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) {
        if (amcl::input::PlatformInputShadowEnabled()) amcl::input::trace::RecordGateRejected();
        return amcl::napi::MakeUndefined(env);
    }
    ohos_send_key_event(key, scancode, action, mods);
    return amcl::napi::MakeUndefined(env);
}

// One physical-key publication: current gate validation, typed submit and
// legacy routing are indivisible with respect to surface destruction.
napi_value PhysicalKeyTransaction(napi_env env, napi_callback_info info) {
    size_t argc = 9;
    napi_value args[9];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint32_t key = 0, scan = 0, hid = 0, typedAction = 0, mods = 0, locks = 0;
    int64_t device = 0;
    int32_t mappedKey = 0, mappedAction = -1;
    if (argc >= 1) napi_get_value_uint32(env, args[0], &key);
    if (argc >= 2) napi_get_value_uint32(env, args[1], &scan);
    if (argc >= 3) napi_get_value_uint32(env, args[2], &hid);
    if (argc >= 4) napi_get_value_uint32(env, args[3], &typedAction);
    if (argc >= 5) napi_get_value_uint32(env, args[4], &mods);
    if (argc >= 6) napi_get_value_uint32(env, args[5], &locks);
    if (argc >= 7) napi_get_value_int64(env, args[6], &device);
    if (argc >= 8) napi_get_value_int32(env, args[7], &mappedKey);
    if (argc >= 9) napi_get_value_int32(env, args[8], &mappedAction);

    amcl::input::SurfaceInputGateTransaction gate;
    const AmclLegacyPhysicalOutcome outcome =
        amcl::input::PlatformInputPhysicalKeyTransaction(
        key, scan, hid, typedAction, mods, locks,
        static_cast<uint64_t>(device), mappedKey, mappedAction,
        static_cast<bool>(gate), ohos_route_physical_key_event_checked);
    napi_value out = nullptr;
    if (napi_create_int32(env, static_cast<int32_t>(outcome), &out) != napi_ok) {
        return amcl::napi::MakeUndefined(env);
    }
    return out;
}

// Physical device add/remove forwarded from ArkTS inputDevice.on('change').
//
// Not guarded by SurfaceInputGateTransaction on purpose: a removal must still
// release that device's held owners while a surface teardown is in flight —
// that is exactly when a stuck key would otherwise survive. Ingress already
// fails closed when no session/host is live, and core's per-device release is
// idempotent, so there is nothing for the gate to protect here.
napi_value PublishInputDeviceChange(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t device = 0;
    bool added = false;
    uint32_t capabilities = 0;
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
    if (argc >= 1) napi_get_value_int64(env, args[0], &device);
    if (argc >= 2) napi_get_value_bool(env, args[1], &added);
    if (argc >= 3) napi_get_value_uint32(env, args[2], &capabilities);
    if (argc >= 4) napi_get_value_uint32(env, args[3], &deviceClass);
    if (device <= 0) {
        // Negative/zero cannot name an owner domain. Let ingress own the
        // diagnostic so ArkTS and native producers are counted identically.
        amcl::input::PlatformInputDeviceChanged(
            0u, added, capabilities, deviceClass);
        return amcl::napi::MakeUndefined(env);
    }
    amcl::input::PlatformInputDeviceChanged(
        static_cast<uint64_t>(device), added, capabilities, deviceClass);
    return amcl::napi::MakeUndefined(env);
}

// Current Window/display context. Positional arguments avoid turning ArkTS
// property names into a second cross-language ABI; validFields is the protocol
// boundary for fields the platform actually proved.
napi_value PublishInputSurfaceContext(napi_env env, napi_callback_info info) {
    size_t argc = 11;
    napi_value args[11] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    AmclInputSurfaceContextPayload context{};
    double density = 0.0;
    double refreshRateHz = 0.0;
    int64_t generation = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &context.windowId);
    if (argc >= 2) napi_get_value_int32(env, args[1], &context.displayId);
    if (argc >= 3) napi_get_value_int32(env, args[2], &context.leftPx);
    if (argc >= 4) napi_get_value_int32(env, args[3], &context.topPx);
    if (argc >= 5) napi_get_value_uint32(env, args[4], &context.widthPx);
    if (argc >= 6) napi_get_value_uint32(env, args[5], &context.heightPx);
    if (argc >= 7) napi_get_value_double(env, args[6], &density);
    if (argc >= 8) napi_get_value_double(env, args[7], &refreshRateHz);
    if (argc >= 9) napi_get_value_uint32(env, args[8], &context.transform);
    if (argc >= 10) napi_get_value_uint32(env, args[9], &context.validFields);
    if (argc >= 11) napi_get_value_int64(env, args[10], &generation);
    context.density = static_cast<float>(density);
    context.refreshRateHz = static_cast<float>(refreshRateHz);
    context.generation = generation > 0
        ? static_cast<uint64_t>(generation) : 0u;

    napi_value out = nullptr;
    const bool accepted =
        amcl::input::PlatformInputSurfaceContextChanged(context);
    if (napi_get_boolean(env, accepted, &out) != napi_ok) {
        return amcl::napi::MakeUndefined(env);
    }
    return out;
}

AmclLegacyPhysicalOutcome RoutePhysicalRelativeChecked(double dx, double dy) {
    // The current bridge exposes a checked boolean, not a rich delivery code.
    // Finite validation and route selection already happened in ingress; false
    // therefore remains an observable enqueue failure and is never retried.
    return ohos_send_cursor_delta_checked(dx, dy)
        ? AMCL_LEGACY_PHYSICAL_EMITTED
        : AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED;
}

std::mutex gArktsPhysicalMotionMutex;
amcl::input::ArktsPhysicalMotionState gArktsPhysicalMotionState;

// Product source sets publish only (productKind, runtimeApi). Native derives
// every capability/allowlist decision again and latches it for the process, so
// a stale page cannot silently turn an API26 desktop session back into mobile
// touch semantics.
napi_value HardwareRawMouseAvailable(napi_env env, napi_callback_info) {
    napi_value out = nullptr;
    napi_get_boolean(env, amcl::input::RuntimeDesktopRawCapability(
        AMCL_GLFW_API26_RAW_MOUSE_MOTION != 0), &out);
    return out;
}

napi_value ConfigureInputProduct(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t product = -1;
    int32_t runtimeApi = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &product);
    if (argc >= 2) napi_get_value_int32(env, args[1], &runtimeApi);

    const auto result = amcl::input::ConfigureProductInputPolicy(
        static_cast<amcl::input::InputProductKind>(
            static_cast<uint32_t>(product)),
        static_cast<uint32_t>(runtimeApi));
    if (result == amcl::input::ProductInputConfigureResult::kApplied) {
        const auto policy = amcl::input::GetProductInputPolicy();
        OH_LOG_INFO(LOG_APP,
                    "Input product configured product=%{public}d api=%{public}u "
                    "formalDesktop=%{public}d compatDesktop=%{public}d "
                    "touchFallback=%{public}d relative=%{public}d cursorLock=%{public}d "
                    "hardwareRaw=%{public}d focus=%{public}d",
                    product, policy.runtimeApi,
                    policy.formalDesktop ? 1 : 0,
                    policy.compatibilityDesktop ? 1 : 0,
                    policy.mobileTouchFallback ? 1 : 0,
                    policy.supportsRelativeMouse ? 1 : 0,
                    policy.supportsCursorLock ? 1 : 0,
                    policy.supportsHardwareRawMouse ? 1 : 0,
                    policy.notifyBackendFocus ? 1 : 0);
    } else if (result == amcl::input::ProductInputConfigureResult::kInvalid ||
               result == amcl::input::ProductInputConfigureResult::kConflict) {
        OH_LOG_ERROR(LOG_APP,
                     "Input product configuration rejected result=%{public}d "
                     "product=%{public}d api=%{public}d",
                     static_cast<int32_t>(result), product, runtimeApi);
    }

    napi_value out = nullptr;
    if (napi_create_int32(env, static_cast<int32_t>(result), &out) != napi_ok) {
        return amcl::napi::MakeUndefined(env);
    }
    return out;
}

// One physical MOVE entry for every ArkTS sample. The page supplies all fields
// it observed but never selects the source plane. Native samples the bridge grab
// SSOT, surface generation and reset epoch inside one gate transaction, then
// routes exactly one of raw-relative, unverified fallback, legacy menu absolute
// or the verified native-absolute owner.
napi_value PhysicalPointerMotionTransaction(napi_env env,
                                             napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8] = {nullptr, nullptr, nullptr, nullptr, nullptr,
                          nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool rawDeltaPresent = false;
    double rawDx = 0.0;
    double rawDy = 0.0;
    // ⚠️ 这两个局部变量曾叫 `windowX` / `windowY`，而它们承载的是
    // **组件坐标系的 vp**（ArkTS 侧传 `MouseEvent.x` / `.y`，见 index.d.ts 的
    // `localVpX` / `localVpY` 与那里的警告"不要传 windowX/windowY"）。
    // 名字与契约相反是 §36 那次故障（菜单光标恒在左上角、点不中按钮、悬浮无高亮）
    // 的直接来源：当时排查时日志打的是 `windowX=…`，把人指向了错误的坐标系。
    // 语义一直是对的，只有命名在说谎 —— 而命名同样会被当成规格读。
    double localVpX = 0.0;
    double localVpY = 0.0;
    int64_t deviceId = 0;
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
    int64_t monotonicTimeNs = 0;
    if (argc >= 1) napi_get_value_bool(env, args[0], &rawDeltaPresent);
    if (argc >= 2) napi_get_value_double(env, args[1], &rawDx);
    if (argc >= 3) napi_get_value_double(env, args[2], &rawDy);
    if (argc >= 4) napi_get_value_double(env, args[3], &localVpX);
    if (argc >= 5) napi_get_value_double(env, args[4], &localVpY);
    if (argc >= 6) napi_get_value_int64(env, args[5], &deviceId);
    if (argc >= 7) napi_get_value_uint32(env, args[6], &deviceClass);
    if (argc >= 8) napi_get_value_int64(env, args[7], &monotonicTimeNs);
    const amcl::input::PlatformInputPointerIdentity pointerIdentity{
        deviceId > 0 ? static_cast<uint64_t>(deviceId) : 0u,
        deviceClass,
        monotonicTimeNs > 0 ? static_cast<uint64_t>(monotonicTimeNs) : 0u,
    };

    // ---- 决定性取证：按住左键期间 onMouse 到底还投不投（常开，逐秒一行）----
    //
    // 这是"光标钉住模式能否让拖动无界"的唯一判据，也是之前四轮反复误判的地方。
    // 旧版是"上限 30 条的逐条打印"，两个致命缺陷：
    //   1) 30 条很快被"没按键的自由移动"或右键样本吃光，真正想看的左键按住时段
    //      一条都留不下（census9 里只侥幸留下 3 条）；
    //   2) 它只在 mirror 活跃时打印，于是"按住期间 onMouse 一条都没来"与
    //      "日志上限用完了"在日志里完全无法区分 —— 而这两者的结论截然相反。
    //
    // 现在按"是否有镜像手势正在进行"（= 左键是否按住）把每一秒的样本分成两桶，
    // 各自统计到达数 / rawDelta 存在数 / rawDelta 非零数 / |dx|+|dy| 累计。
    // 判读方式（一行即可定论）：
    //   · hold 桶 move>0 且 rawNz>0  → 钉住模式下 onMouse 存活 ⇒ 拖动可以无界，成功；
    //   · hold 桶 move==0            → 平台仍然掐掉了 onMouse ⇒ 钉住模式无效，
    //                                   回退 follow=true 并按 §22.4 走产品层锁存方案；
    //   · hold 桶 move>0 但 rawNz==0 → 通道在但相对量为 0 ⇒ 那份旧推断其实是对的。
    {
        struct DragBucket {
            std::atomic<uint32_t> move{0};
            std::atomic<uint32_t> rawPresent{0};
            std::atomic<uint32_t> rawNonZero{0};
            std::atomic<uint64_t> travel{0};
        };
        static DragBucket hold;
        static DragBucket idle;
        static std::atomic<int64_t> nextFlushMs{0};

        const bool held = ohos_touch_mirror_gesture_active();
        DragBucket& bucket = held ? hold : idle;
        bucket.move.fetch_add(1, std::memory_order_relaxed);
        if (rawDeltaPresent) {
            bucket.rawPresent.fetch_add(1, std::memory_order_relaxed);
            if (rawDx != 0.0 || rawDy != 0.0) {
                bucket.rawNonZero.fetch_add(1, std::memory_order_relaxed);
            }
            const double mag = (rawDx < 0.0 ? -rawDx : rawDx) +
                               (rawDy < 0.0 ? -rawDy : rawDy);
            bucket.travel.fetch_add(static_cast<uint64_t>(mag),
                                    std::memory_order_relaxed);
        }

        struct timespec ts = {};
        int64_t nowMs = 0;
        if (clock_gettime(CLOCK_MONOTONIC_COARSE, &ts) == 0) {
            nowMs = static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
        }
        const int64_t due = nextFlushMs.load(std::memory_order_relaxed);
        if (due == 0) {
            nextFlushMs.store(nowMs + 1000, std::memory_order_relaxed);
        } else if (nowMs >= due) {
            nextFlushMs.store(nowMs + 1000, std::memory_order_relaxed);
            const uint32_t hm = hold.move.exchange(0, std::memory_order_relaxed);
            const uint32_t hp = hold.rawPresent.exchange(0, std::memory_order_relaxed);
            const uint32_t hn = hold.rawNonZero.exchange(0, std::memory_order_relaxed);
            const uint64_t ht = hold.travel.exchange(0, std::memory_order_relaxed);
            const uint32_t fm = idle.move.exchange(0, std::memory_order_relaxed);
            const uint32_t fp = idle.rawPresent.exchange(0, std::memory_order_relaxed);
            const uint32_t fn = idle.rawNonZero.exchange(0, std::memory_order_relaxed);
            const uint64_t ft = idle.travel.exchange(0, std::memory_order_relaxed);
            if (hm || fm) {
                OH_LOG_INFO(LOG_APP,
                            "AMCL_DRAG 1s hold[move=%{public}u rawPresent=%{public}u "
                            "rawNz=%{public}u travel=%{public}llu] "
                            "free[move=%{public}u rawPresent=%{public}u "
                            "rawNz=%{public}u travel=%{public}llu]",
                            hm, hp, hn, static_cast<unsigned long long>(ht),
                            fm, fp, fn, static_cast<unsigned long long>(ft));
            }
        }
    }

    // ---- 滚轮取证（常开，有上限）----
    // 现状：native UIInputEvent(AXIS) 注册成功但零样本；ArkTS onAxisEvent 也零调用
    //（本轮日志 0 条 AMCL_WHEEL）。两条轴通道都不来，滚轮却在转视角，那它只可能
    // 以**相对移动**的形式到达这里。滚轮一格的特征与手移动截然不同：横向分量恰好为 0、
    // 纵向有一个较大的离散值、且在时间上孤立。命中即整条打印，最多 40 条，此后静默。
    {
        static std::atomic<int64_t> lastMotionMs{0};
        static std::atomic<int> printed{0};
        struct timespec ts = {};
        int64_t nowMs = 0;
        if (clock_gettime(CLOCK_MONOTONIC_COARSE, &ts) == 0) {
            nowMs = static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
        }
        const int64_t prevMs = lastMotionMs.exchange(nowMs,
                                                     std::memory_order_relaxed);
        const int64_t gapMs = (prevMs == 0) ? 0 : (nowMs - prevMs);
        const double absDy = rawDy < 0.0 ? -rawDy : rawDy;
        if (rawDeltaPresent && rawDx == 0.0 && absDy >= 2.0 && gapMs >= 120 &&
            printed.load(std::memory_order_relaxed) < 40) {
            printed.fetch_add(1, std::memory_order_relaxed);
            OH_LOG_INFO(LOG_APP,
                        "AMCL_WHEEL candidate relative-move rawDy=%{public}f "
                        "gapMs=%{public}lld localVpX=%{public}f "
                        "localVpY=%{public}f",
                        rawDy, static_cast<long long>(gapMs), localVpX,
                        localVpY);
        }
    }

    amcl::input::SurfaceInputGateTransaction gate;
    amcl::input::AuthoritativeGrabInputTransaction grabTransaction(
        static_cast<bool>(gate));
    const bool grabStateKnown = static_cast<bool>(grabTransaction);
    const bool grabbed = grabTransaction.grabbed();
    const amcl::input::ArktsPhysicalMotionSample sample{
        gate.token(),
        amcl::input::PlatformInputResetEpoch(),
        grabStateKnown,
        grabbed,
        static_cast<bool>(gate) &&
            amcl::input::PlatformInputNativeAbsoluteRouteUsesTyped(),
        rawDeltaPresent,
        rawDx,
        rawDy,
        // ⚠️ `ArktsPhysicalMotionSample` 的这两个字段也叫 `windowX/windowY`
        // （见 `cpp/input/` 的结构体定义），但送进去的是**组件坐标系 vp**。
        // 那边的字段名同样与语义相反，本轮未改（跨 TU 重命名属独立清理）；
        // 这里显式点出来，避免下一个人以为需要在这里做窗口→组件的换算。
        localVpX,
        localVpY,
    };
    amcl::input::ArktsPhysicalMotionDecision decision;
    {
        std::lock_guard<std::mutex> lock(gArktsPhysicalMotionMutex);
        decision = gArktsPhysicalMotionState.Consume(sample);
    }

    if (!gate) {
        if (amcl::input::PlatformInputShadowEnabled()) {
            amcl::input::trace::RecordGateRejected();
        }
        return amcl::napi::MakeUndefined(env);
    }

    switch (decision.route) {
        case amcl::input::ArktsPhysicalMotionRoute::RawRelative:
            // 常开普查：ArkTS onMouse Move 是 grabbed 模式下唯一的合法视角来源。
            // 若"滚轮转视角"时这个计数随之上升，说明平台把滚轮也报成了 Move。
            amcl::input::census::Bump(
                amcl::input::census::Channel::LookFromArktsMotion);
            // 只有**真的带位移**才算这条通道活着。真机实测：按住左键期间 ArkTS 仍以
            // 26 次/秒投递 Move，但 rawDelta 恒为 0；若按"被调用过"就让镜像让位，
            // 结果是两条通道都不产出，拖动完全不动（§十九）。
            if (decision.first != 0.0 || decision.second != 0.0) {
                ohos_note_arkts_relative_motion();
            }
            (void)amcl::input::PlatformInputPhysicalRelativeTransaction(
                decision.first, decision.second, true,
                RoutePhysicalRelativeChecked, pointerIdentity);
            break;
        case amcl::input::ArktsPhysicalMotionRoute::UnverifiedRelativeFallback:
            // rawDelta 缺失时的分支（窗口坐标差分）。
            //
            // 更正上一版写在这里的注释：它声称"RawRelative 在产品构建里走不到"，那是**错的**。
            // ArktsPhysicalMotionState::Consume 里 RawRelative 的唯一条件是 rawDeltaPresent，
            // verifiedNativeAbsolute 只影响非 grabbed 的菜单分支；而 legacy 平面
            // （typedRoute 默认 OFF）照常把 delta 交给 enqueue 回调。真机普查
            // look == lookArkts 也反证了这一点：若真走本分支，光标锁下窗口坐标恒定、
            // 差分恒 0，look 只能是 0。两条分支打同一个计数，故普查目前不区分它们。
            amcl::input::census::Bump(
                amcl::input::census::Channel::LookFromArktsMotion);
            // 同上：零位移的样本不算通道活跃，否则会把唯一有数据的镜像通道压死。
            if (decision.first != 0.0 || decision.second != 0.0) {
                ohos_note_arkts_relative_motion();
            }
            (void)amcl::input::PlatformInputUnverifiedRelativeFallbackTransaction(
                decision.first, decision.second, true,
                ohos_send_cursor_delta_checked);
            break;
        case amcl::input::ArktsPhysicalMotionRoute::LegacyMenuAbsolute: {
            amcl::input::PlatformInputTraceUnverifiedAbsolute();
            // ---- vp → 组件内物理 px（2026-08-19，修"鼠标点不动菜单/无悬浮高亮"）----
            //
            // ArkTS 传来的是 `MouseEvent.x/y`，即**组件坐标系、单位 vp**（官方属性表
            // 明确标注 vp）。而 bridge 的 `setMenuCursor` 期望**组件内物理 px** ——
            // 手指那条菜单通道送的是 XComponent 触点坐标 `px/py`，本来就是 px。
            //
            // 此前这里直接把 vp 当 px 送下去，于是 MC 的菜单光标只落在正确位置的
            // 1/density 处（真机 density=3.25 ⇒ 约 31%，恒在左上角）。后果正是用户报的
            // 两条：**点不中菜单按钮**，而且**悬浮不出现高亮边框** —— 高亮取决于 MC 自己
            // 的光标位置，而那个位置一直不在按钮上。
            //
            // 密度由页面 aboutToAppear 无条件下发（display.densityPixels），
            // 未发布时返回 1.0，退化为旧行为而不是把坐标清零。
            const double density = ohos_display_density();
            (void)ohos_send_cursor_pos_checked(
                decision.first * density, decision.second * density);
            break;
        }
        case amcl::input::ArktsPhysicalMotionRoute::NativeMenuAbsoluteOwner:
            // ArkTS window coordinates remain observable as unverified, but are
            // never emitted once surface-local native absolute owns the plane.
            amcl::input::PlatformInputTraceUnverifiedAbsolute();
            break;
        case amcl::input::ArktsPhysicalMotionRoute::Drop:
            break;
    }
    return amcl::napi::MakeUndefined(env);
}

napi_value PhysicalPointerRelativeTransaction(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double dx = 0.0, dy = 0.0;
    int64_t deviceId = 0;
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
    int64_t monotonicTimeNs = 0;
    if (argc >= 1) napi_get_value_double(env, args[0], &dx);
    if (argc >= 2) napi_get_value_double(env, args[1], &dy);
    if (argc >= 3) napi_get_value_int64(env, args[2], &deviceId);
    if (argc >= 4) napi_get_value_uint32(env, args[3], &deviceClass);
    if (argc >= 5) napi_get_value_int64(env, args[4], &monotonicTimeNs);
    const amcl::input::PlatformInputPointerIdentity identity{
        deviceId > 0 ? static_cast<uint64_t>(deviceId) : 0u,
        deviceClass,
        monotonicTimeNs > 0 ? static_cast<uint64_t>(monotonicTimeNs) : 0u,
    };

    amcl::input::SurfaceInputGateTransaction gate;
    (void)amcl::input::PlatformInputPhysicalRelativeTransaction(
        dx, dy, static_cast<bool>(gate), RoutePhysicalRelativeChecked,
        identity);
    return amcl::napi::MakeUndefined(env);
}

napi_value TraceUnverifiedCursorPosition(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    amcl::input::PlatformInputTraceUnverifiedAbsolute();
    return amcl::napi::MakeUndefined(env);
}

// Permanent, inert seam for a diagnostic-only implementation. Ordinary
// product builds return false and the ArkTS producer never crosses NAPI on the
// mouse hot path. The implementation and its per-sample logging translation
// unit are linked only when AMCL_INPUT_GATE0_TELEMETRY=ON.
napi_value Gate0InputTelemetryEnabled(napi_env env, napi_callback_info /*info*/) {
#if AMCL_INPUT_GATE0_TELEMETRY
    OH_LOG_INFO(LOG_APP, "AMCL_GATE0 telemetry capability queried enabled=1");
    return amcl::napi::MakeBoolResult(env, true);
#else
    return amcl::napi::MakeBoolResult(env, false);
#endif
}

napi_value TraceGate0ArktsMouse(napi_env env, napi_callback_info info) {
#if AMCL_INPUT_GATE0_TELEMETRY
    constexpr size_t kArgumentCount = 23u;
    size_t argc = kArgumentCount;
    napi_value args[kArgumentCount]{};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc != kArgumentCount) {
        return amcl::napi::MakeUndefined(env);
    }

    AmclGate0ArktsMouseSample sample{};
    int64_t timestamp = 0;
    bool mouseCapability = false;
    bool mcStarted = false;
    bool grabbed = false;
    const bool valid =
        napi_get_value_int64(env, args[0], &timestamp) == napi_ok &&
        napi_get_value_int64(env, args[1], &sample.deviceId) == napi_ok &&
        napi_get_value_int32(env, args[2], &sample.source) == napi_ok &&
        napi_get_value_int32(env, args[3], &sample.sourceTool) == napi_ok &&
        napi_get_value_int32(env, args[4], &sample.action) == napi_ok &&
        napi_get_value_int32(env, args[5], &sample.button) == napi_ok &&
        napi_get_value_uint32(env, args[6], &sample.presence) == napi_ok &&
        napi_get_value_uint32(env, args[7], &sample.pressedButtonCount) == napi_ok &&
        napi_get_value_bool(env, args[8], &mouseCapability) == napi_ok &&
        napi_get_value_bool(env, args[9], &mcStarted) == napi_ok &&
        napi_get_value_bool(env, args[10], &grabbed) == napi_ok &&
        napi_get_value_double(env, args[11], &sample.localX) == napi_ok &&
        napi_get_value_double(env, args[12], &sample.localY) == napi_ok &&
        napi_get_value_double(env, args[13], &sample.windowX) == napi_ok &&
        napi_get_value_double(env, args[14], &sample.windowY) == napi_ok &&
        napi_get_value_double(env, args[15], &sample.displayX) == napi_ok &&
        napi_get_value_double(env, args[16], &sample.displayY) == napi_ok &&
        napi_get_value_double(env, args[17], &sample.globalX) == napi_ok &&
        napi_get_value_double(env, args[18], &sample.globalY) == napi_ok &&
        napi_get_value_double(env, args[19], &sample.rawDx) == napi_ok &&
        napi_get_value_double(env, args[20], &sample.rawDy) == napi_ok &&
        napi_get_value_double(env, args[21], &sample.density) == napi_ok;
    uint32_t schemaVersion = 0u;
    const bool schemaVersionValid =
        napi_get_value_uint32(env, args[22], &schemaVersion) == napi_ok;
    if (!valid || !schemaVersionValid || timestamp < 0 || schemaVersion != 1u) {
        return amcl::napi::MakeUndefined(env);
    }
    sample.timestamp = static_cast<uint64_t>(timestamp);
    sample.mouseCapability = mouseCapability ? 1u : 0u;
    sample.mcStarted = mcStarted ? 1u : 0u;
    sample.grabbed = grabbed ? 1u : 0u;
    amcl_gate0_trace_arkts_mouse(&sample);
#else
    (void)info;
#endif
    return amcl::napi::MakeUndefined(env);
}

// Physical menu cursor producer.  The source-plane choice is made by the
// process-owner host capability in native code, not by an ArkTS boolean that
// could race host construction or be obfuscated independently.  Once verified
// native absolute owns the route, window-space ArkTS coordinates are discarded
// fail-closed; touch/menu and virtual-control producers keep their separate
// legacy transactions.
napi_value PhysicalMenuCursorPositionTransaction(
        napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double x = 0.0;
    double y = 0.0;
    if (argc >= 1) napi_get_value_double(env, args[0], &x);
    if (argc >= 2) napi_get_value_double(env, args[1], &y);

    if (amcl::input::PlatformInputNativeAbsoluteRouteUsesTyped()) {
        return amcl::napi::MakeUndefined(env);
    }

    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) {
        if (amcl::input::PlatformInputShadowEnabled()) {
            amcl::input::trace::RecordGateRejected();
        }
        return amcl::napi::MakeUndefined(env);
    }
    ohos_send_cursor_pos(x, y);
    return amcl::napi::MakeUndefined(env);
}

napi_value PhysicalPointerRelativeFallbackTransaction(napi_env env,
                                                      napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double dx = 0.0;
    double dy = 0.0;
    if (argc >= 1) napi_get_value_double(env, args[0], &dx);
    if (argc >= 2) napi_get_value_double(env, args[1], &dy);

    // Gate validation, the immutable typed/legacy route decision and the
    // compatibility enqueue are one transaction. A surface teardown therefore
    // cannot occur between deciding "legacy" and writing the legacy ring.
    amcl::input::SurfaceInputGateTransaction gate;
    (void)amcl::input::PlatformInputUnverifiedRelativeFallbackTransaction(
        dx, dy, static_cast<bool>(gate), ohos_send_cursor_delta_checked);
    return amcl::napi::MakeUndefined(env);
}

// Grabbed-mode cursor lock. Returns the AmclCursorLockResult so ArkTS can tell
// "this device has no such capability" apart from "the window manager refused",
// which are very different diagnoses for physical-mouse behaviour.
napi_value SetCursorLocked(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t windowId = 0;
    bool locked = false;
    if (argc >= 1) napi_get_value_int32(env, args[0], &windowId);
    if (argc >= 2) napi_get_value_bool(env, args[1], &locked);
    const AmclCursorLockResult result =
        amcl_cursor_lock_set(windowId, locked);
    const amcl::input::CursorCapturePublication publication =
        amcl::input::CursorCapturePublicationForResult(locked, result);
    amcl::input::PlatformInputCaptureChanged(
        publication.requested, publication.active, publication.reason);
    napi_value out = nullptr;
    if (napi_create_int32(env, static_cast<int32_t>(result), &out) != napi_ok) {
        return amcl::napi::MakeUndefined(env);
    }
    return out;
}

// The window manager drops the lock by itself when the window loses focus.
// ArkTS reports that edge so the next lock request is not treated as redundant.
napi_value NoteCursorLockFocusLost(napi_env env, napi_callback_info /*info*/) {
    amcl_cursor_lock_note_focus_lost();
    return amcl::napi::MakeUndefined(env);
}

napi_value IsCursorLockSupported(napi_env env, napi_callback_info /*info*/) {
    return amcl::napi::MakeBoolResult(env, amcl_cursor_lock_supported());
}

// 钉住模式看门狗。返回 true 表示刚刚降级到跟随模式，ArkTS 必须**重新加锁一次**
// （窗口管理器只在 lock 调用时读 isCursorFollowMovement）。
//
// 由页面既有的 250ms grab 对账轮询驱动，不新增定时器；稳态下只做几次原子读。
napi_value CursorLockWatchdogTick(napi_env env, napi_callback_info /*info*/) {
    return amcl::napi::MakeBoolResult(env, amcl_cursor_lock_watchdog_tick());
}

// 窗口级输入事件过滤器（路径 B）。返回 AmclWindowInputFilterResult，让 ArkTS 能把
// "本设备没有该能力（API<15）"、"窗口 id 非法"、"窗口管理器拒绝" 和 "已装但无法分类
// （API<24，只观测）" 分开诊断——这几种情况的处置完全不同。
napi_value InstallWindowInputFilters(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t windowId = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &windowId);
    const AmclWindowInputFilterResult result =
        amcl_window_input_filter_install(windowId);
    napi_value out = nullptr;
    if (napi_create_int32(env, static_cast<int32_t>(result), &out) != napi_ok) {
        return amcl::napi::MakeUndefined(env);
    }
    return out;
}

napi_value UninstallWindowInputFilters(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t windowId = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &windowId);
    const AmclWindowInputFilterResult result =
        amcl_window_input_filter_uninstall(windowId);
    napi_value out = nullptr;
    if (napi_create_int32(env, static_cast<int32_t>(result), &out) != napi_ok) {
        return amcl::napi::MakeUndefined(env);
    }
    return out;
}

// 是否**正在**掐断鼠标派生的合成触摸包。为 false 的原因可能是没装、API<24 无法分类，
// 或看门狗已降级（onMouse 未如推断那样恢复）。HUD/诊断据此显示真实通道状态。
napi_value WindowInputFilterActive(napi_env env, napi_callback_info /*info*/) {
    return amcl::napi::MakeBoolResult(env, amcl_window_input_filter_active());
}

// True once the native XComponent AXIS callback has actually delivered a wheel
// sample. ArkTS owns the wheel only while this stays false, so exactly one
// channel emits scroll and one detent never counts twice.
napi_value NativeWheelChannelActive(napi_env env, napi_callback_info /*info*/) {
    return amcl::napi::MakeBoolResult(env, ohos_native_wheel_channel_seen());
}

// 滚轮通道申请：wheelChannelClaim(channel: number): boolean
//
// 一次调用同时完成"登记本通道确实送来过样本"与"询问它是否为当前所有者"，
// 因此 ArkTS 侧不可能把顺序写错（能力必须先登记，否则永远拿不到所有权）。
// channel 取 AmclInputChannel 的滚轮档：5=arktsAxis，6=axisPan。
//
// **每一个**滚轮产出点都必须先过这一关。ArkTS 的轴驱动 Pan 通道此前漏掉了这个询问，
// 于是与 native AXIS 同时产出且符号相反，用户表现为"滚轮方向反了，快速滚动又时好时坏"。
// 键盘自愈计数：ArkTS 发现自己的 held 缓存陈旧（中间的 UP 丢了）并按首次按下重发时调用。
// 单独一个计数器而不是复用 keyDown，是因为"自愈发生过"本身就是一条故障线索：
// 稳态下它应当恒为 0，一旦非零就说明某处在丢 UP，需要顺着焦点/生命周期边界去查。
napi_value NoteKeyRepeatSelfHealed(napi_env env, napi_callback_info /*info*/) {
    amcl::input::census::Bump(
        amcl::input::census::Channel::KeyRepeatSelfHealed);
    return amcl::napi::MakeUndefined(env);
}

napi_value WheelChannelClaim(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t channel = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &channel);
    return amcl::napi::MakeBoolResult(env, ohos_wheel_channel_claim(channel));
}

// default input-trace 滚轮取证入口（noteArktsAxisEvent(action, verticalValue, yielded)）。
//
// 本机滚轮的通道归属是最后一个盲区：native AXIS 回调注册成功但 0 样本，而 ArkTS
// onAxisEvent 是否被调用从未取证过。滚轮事件频率极低（一格一条），所以这里**逐条**
// 打印而不做聚合——需要看到 action 与 SDK 上报的原始数值本身，才能同时判定
// "通道是否活着"和"符号/单位契约"。普通产品中保留无操作接缝，不收集样本。
napi_value NoteArktsAxisEvent(napi_env env, napi_callback_info info) {
#if (AMCL_DIAGNOSTICS_MASK & 5) == 5
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t action = -1;
    double verticalValue = 0.0;
    bool yielded = false;
    if (argc >= 1) napi_get_value_int32(env, args[0], &action);
    if (argc >= 2) napi_get_value_double(env, args[1], &verticalValue);
    if (argc >= 3) napi_get_value_bool(env, args[2], &yielded);

    amcl::input::census::Bump(
        amcl::input::census::Channel::ArktsAxisCallback);
    if (yielded) {
        amcl::input::census::Bump(
            amcl::input::census::Channel::ArktsAxisYielded);
    } else if (verticalValue != 0.0) {
        amcl::input::census::Bump(
            amcl::input::census::Channel::ArktsAxisScroll);
    }
    OH_LOG_INFO(LOG_APP,
                "AMCL_WHEEL arkts axis action=%{public}d vertical=%{public}f "
                "yieldedToNative=%{public}d",
                action, verticalValue, yielded ? 1 : 0);
#endif
    return amcl::napi::MakeUndefined(env);
}

// 轴驱动 Pan（滚轮/触控板双指）的起止通知。语义与代价见 touch_input.h。
// 发布屏幕像素密度，用于把触摸流的 px 位移换算成 rawDelta 的量纲（见 touch_input.h）。
napi_value SetDisplayDensity(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double density = 0.0;
    if (argc >= 1) napi_get_value_double(env, args[0], &density);
    ohos_set_display_density(density);
    return amcl::napi::MakeUndefined(env);
}

napi_value NoteAxisPanActive(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool active = false;
    if (argc >= 1) napi_get_value_bool(env, args[0], &active);
    ohos_note_axis_pan_active(active ? 1 : 0);
    return amcl::napi::MakeUndefined(env);
}

napi_value PhysicalMouseButtonTransaction(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t deviceId = 0;
    int32_t arkuiButton = -1, action = -1, mods = 0;
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
    int64_t monotonicTimeNs = 0;
    if (argc >= 1) napi_get_value_int64(env, args[0], &deviceId);
    if (argc >= 2) napi_get_value_int32(env, args[1], &arkuiButton);
    if (argc >= 3) napi_get_value_int32(env, args[2], &action);
    if (argc >= 4) napi_get_value_int32(env, args[3], &mods);
    if (argc >= 5) napi_get_value_uint32(env, args[4], &deviceClass);
    if (argc >= 6) napi_get_value_int64(env, args[5], &monotonicTimeNs);
    ohos_route_arkui_physical_mouse_button(
        deviceId > 0 ? static_cast<uint64_t>(deviceId) : 0u,
        arkuiButton, action, mods, deviceClass,
        monotonicTimeNs > 0 ? static_cast<uint64_t>(monotonicTimeNs) : 0u);
    return amcl::napi::MakeUndefined(env);
}

napi_value SendMouseEvent(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t button = 0, action = 0, mods = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &button);
    if (argc >= 2) napi_get_value_int32(env, args[1], &action);
    if (argc >= 3) napi_get_value_int32(env, args[2], &mods);
    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) {
        if (amcl::input::PlatformInputShadowEnabled()) amcl::input::trace::RecordGateRejected();
        return amcl::napi::MakeUndefined(env);
    }
    ohos_send_mouse_event(button, action, mods);
    return amcl::napi::MakeUndefined(env);
}

napi_value SendScrollEvent(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t xoffset = 0, yoffset = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &xoffset);
    if (argc >= 2) napi_get_value_int32(env, args[1], &yoffset);
    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) {
        if (amcl::input::PlatformInputShadowEnabled()) amcl::input::trace::RecordGateRejected();
        return amcl::napi::MakeUndefined(env);
    }
    ohos_send_scroll_event(xoffset, yoffset);
    return amcl::napi::MakeUndefined(env);
}

// ============================================================
//  按端申报的输入注入入口
// ============================================================
//
// 三端平级（见 platform/input_source.h）意味着"哪个端产出的"必须是显式参数，而不是
// 由 native 从调用路径去猜。这一组与下方未申报端身份的 `sendKeyEvent` / `sendMouseEvent`
// / `sendCursorDelta` 并存：旧入口保留只为 fail-soft（漏改的调用点仍可用，且会在端级
// 复位日志的 untagged 一栏暴露出来），新调用点一律用这一组。
//
// 端身份带来三件实际能力：
//   1. 持有记录按端隔离 ⇒ RELEASE/REPEAT 只与同端配对，不会拿走别端的 owner；
//   2. 按端选择性释放（releaseSourceHeld）⇒ 拔一个手柄不再连带放掉屏幕虚拟按键；
//   3. 视角量纲按端归一 ⇒ 手柄摇杆增益与触控 dragLook 的 px 差分不再共用一个系数。
//
// `source` 的合法取值即 AmclInputSource：1=触控虚拟按键 2=手柄 3=物理键鼠。
// 物理键鼠端**不该**走这一组（它有专用身份的 physical* 事务），这里不做拒绝，
// 因为把它标进来只会让日志出现一栏异常计数，比静默丢事件更容易发现。
static bool ReadInputSourceArg(napi_env env, napi_value value, int32_t* out) {
    int32_t source = 0;
    if (napi_get_value_int32(env, value, &source) != napi_ok) return false;
    // 上界是 AMCL_INPUT_SOURCE_PLATFORM_GESTURE(4)。
    // NONE(0) 仍然接受：它是**告警值**（"这个调用点还没申报端身份"），拒绝它只会把
    // 一个可观测的问题变成静默丢事件。正当的平台手势有自己的值 4，不再挤在 0 里。
    if (source < 0 || source > 4) return false;
    *out = source;
    return true;
}

napi_value SendSourceKeyEvent(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t source = 0;
    if (argc < 1 || !ReadInputSourceArg(env, args[0], &source)) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    int32_t key = 0, scancode = 0, action = 0, mods = 0;
    if (argc >= 2) napi_get_value_int32(env, args[1], &key);
    if (argc >= 3) napi_get_value_int32(env, args[2], &scancode);
    if (argc >= 4) napi_get_value_int32(env, args[3], &action);
    if (argc >= 5) napi_get_value_int32(env, args[4], &mods);
    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) {
        if (amcl::input::PlatformInputShadowEnabled()) amcl::input::trace::RecordGateRejected();
        return amcl::napi::MakeBoolResult(env, false);
    }
    return amcl::napi::MakeBoolResult(
        env, ohos_send_source_key_event_checked(source, key, scancode, action, mods));
}

// ArkUI AxisEvent typed owner. Returning true means the startup-latched typed
// route owns this sample even when the gate/core rejects it; callers must not
// fall back to the legacy ring in that case or one wheel packet would cross the
// immutable source-plane boundary. Returning false means the process is on the
// legacy route and the existing sendSourceScrollEvent path remains authoritative.
napi_value PhysicalPointerWheelTransaction(napi_env env,
                                            napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {nullptr, nullptr, nullptr, nullptr,
                          nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double x = 0.0;
    double y = 0.0;
    bool precise = false;
    int64_t deviceId = 0;
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
    int64_t monotonicTimeNs = 0;
    if (argc >= 1) napi_get_value_double(env, args[0], &x);
    if (argc >= 2) napi_get_value_double(env, args[1], &y);
    if (argc >= 3) napi_get_value_bool(env, args[2], &precise);
    if (argc >= 4) napi_get_value_int64(env, args[3], &deviceId);
    if (argc >= 5) napi_get_value_uint32(env, args[4], &deviceClass);
    if (argc >= 6) napi_get_value_int64(env, args[5], &monotonicTimeNs);
    // The current ArkUI/native Axis getters are documented in px, so ingress
    // keeps the existing PIXEL contract and does not guess LINE/PAGE.

    const bool typedOwner =
        amcl::input::PlatformInputPhysicalRouteUsesTyped();
    if (typedOwner) {
        const amcl::input::PlatformInputPointerIdentity identity{
            deviceId > 0 ? static_cast<uint64_t>(deviceId) : 0u,
            deviceClass,
            monotonicTimeNs > 0
                ? static_cast<uint64_t>(monotonicTimeNs) : 0u,
        };
        amcl::input::SurfaceInputGateTransaction gate;
        (void)amcl::input::PlatformInputPhysicalWheelTransaction(
            x, y, precise, static_cast<bool>(gate), nullptr, identity);
    }
    return amcl::napi::MakeBoolResult(env, typedOwner);
}

napi_value SendSourceMouseEvent(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t source = 0;
    if (argc < 1 || !ReadInputSourceArg(env, args[0], &source)) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    int32_t button = 0, action = 0, mods = 0;
    if (argc >= 2) napi_get_value_int32(env, args[1], &button);
    if (argc >= 3) napi_get_value_int32(env, args[2], &action);
    if (argc >= 4) napi_get_value_int32(env, args[3], &mods);
    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) {
        if (amcl::input::PlatformInputShadowEnabled()) amcl::input::trace::RecordGateRejected();
        return amcl::napi::MakeBoolResult(env, false);
    }
    return amcl::napi::MakeBoolResult(
        env, ohos_send_source_mouse_event_checked(source, button, action, mods));
}

// 滚轮没有持续按下态，所以不需要按端记账；但**普查**需要按端可分，否则
// "手柄 L1 切快捷栏" 与 "屏幕滚轮条滑动" 在日志里无法区分。
napi_value SendSourceScrollEvent(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t source = 0;
    if (argc < 1 || !ReadInputSourceArg(env, args[0], &source)) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    int32_t xoffset = 0, yoffset = 0;
    if (argc >= 2) napi_get_value_int32(env, args[1], &xoffset);
    if (argc >= 3) napi_get_value_int32(env, args[2], &yoffset);
    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) {
        if (amcl::input::PlatformInputShadowEnabled()) amcl::input::trace::RecordGateRejected();
        return amcl::napi::MakeBoolResult(env, false);
    }
    // gate 在本作用域内存活到调用返回，所以 gateAccepted 传 true 是如实的 ——
    // 这与 PhysicalKeyTransaction / 物理按钮那两条事务是同一条约束。
    return amcl::napi::MakeBoolResult(
        env, ohos_send_source_scroll_event_checked(source, xoffset, yoffset, true));
}

// 按端的视角增量。这条入口的存在就是为了替掉 `sendCursorDelta` —— 后者一个入口同时
// 服务手柄右摇杆与触控端 dragLook，两者量纲不同却共用一个端标注。
napi_value SendSourceCursorDelta(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t source = 0;
    if (argc < 1 || !ReadInputSourceArg(env, args[0], &source)) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    double dx = 0, dy = 0;
    if (argc >= 2) napi_get_value_double(env, args[1], &dx);
    if (argc >= 3) napi_get_value_double(env, args[2], &dy);
    // 通道普查仍按旧枚举记（`lookPad` 现在真的只是手柄 + 触控 dragLook 两条合成通道），
    // 端普查由 native 的 amcl_input_source_note_look 负责。两条轴分别记账是刻意的。
    amcl::input::census::Bump(amcl::input::census::Channel::LookFromGamepad);
    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) {
        if (amcl::input::PlatformInputShadowEnabled()) amcl::input::trace::RecordGateRejected();
        return amcl::napi::MakeBoolResult(env, false);
    }
    return amcl::napi::MakeBoolResult(
        env, ohos_send_source_cursor_delta_checked(source, dx, dy));
}

// 只释放某一端持有的输出。设备插拔与端级生命周期边界用它。
napi_value ReleaseSourceHeld(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t source = 0;
    if (argc < 1 || !ReadInputSourceArg(env, args[0], &source)) {
        return amcl::napi::MakeUndefined(env);
    }
    // 刻意**不**要求 surface gate：这是释放路径。gate 被拒时正是最需要放键的时刻
    // （surface 已失效 / 正在换代），此时若把释放也一起丢掉，按下态就永久悬空了。
    // 这与 ohos_cancel_all_input 的纪律一致：RELEASE 在复位期间始终合法。
    ohos_release_input_source_held(source);
    return amcl::napi::MakeUndefined(env);
}

// ArkTS 侧的端自己复位之后记一笔，让端级复位日志三栏都有生产者。
napi_value NoteSourceReset(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t source = 0;
    if (argc < 1 || !ReadInputSourceArg(env, args[0], &source)) {
        return amcl::napi::MakeUndefined(env);
    }
    ohos_note_input_source_reset(source);
    return amcl::napi::MakeUndefined(env);
}

// 输入不变量自检的心跳。挂在 ArkTS 已有的 250ms grabbed 兜底轮询上，不新开定时器。
//
// 为什么由 ArkTS 驱动而不是 native 自己起线程：这个项目已经删掉过两个"常驻 worker +
// mutex + condvar"的子系统（mouseSynth tap 状态机），代价是它们把自己拉进了全局锁序。
// 复用现成的心跳既不新增线程，也让"多久检查一次"这件事在 ArkTS 侧可见可调。
napi_value InputInvariantTick(napi_env env, napi_callback_info info) {
    size_t argc = 0;
    napi_get_cb_info(env, info, &argc, nullptr, nullptr, nullptr);
    // 刻意不要求 surface gate：这是纯观测，gate 被拒的时刻恰恰最需要看到账目。
    ohos_input_invariant_tick();
    return amcl::napi::MakeUndefined(env);
}

// --- 合成视角增量（仅 touch controls / gamepad）---
// ⚠️ 未申报端身份的兼容入口，行为按手柄端处理。新调用点用 `sendSourceCursorDelta`。
// Physical mouse input must use physicalPointerRelative*Transaction so the
// typed/legacy route gate remains unique. Remove this compatibility entry in
// Phase 7 after the remaining synthetic producers have backend adapters.
napi_value SendCursorDelta(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double dx = 0, dy = 0;
    if (argc >= 1) napi_get_value_double(env, args[0], &dx);
    if (argc >= 2) napi_get_value_double(env, args[1], &dy);
    // 合成视角来源（手柄右摇杆 + 虚拟按钮的 dragLook）。此前从未打点，导致
    // "look 总数 = 各来源之和"在用手柄或 dragLook 时必然对不上，普查失真。
    amcl::input::census::Bump(amcl::input::census::Channel::LookFromGamepad);
    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) {
        if (amcl::input::PlatformInputShadowEnabled()) amcl::input::trace::RecordGateRejected();
        return amcl::napi::MakeUndefined(env);
    }
    ohos_send_cursor_delta(dx, dy);
    return amcl::napi::MakeUndefined(env);
}

// --- 光标绝对坐标设置 ---
napi_value SendCursorPos(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double x = 0, y = 0;
    if (argc >= 1) napi_get_value_double(env, args[0], &x);
    if (argc >= 2) napi_get_value_double(env, args[1], &y);
    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) {
        if (amcl::input::PlatformInputShadowEnabled()) amcl::input::trace::RecordGateRejected();
        return amcl::napi::MakeUndefined(env);
    }
    ohos_send_cursor_pos(x, y);
    return amcl::napi::MakeUndefined(env);
}

// --- 编辑模式暂停触摸 ---
napi_value SetTouchPaused(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool paused = false;
    if (argc >= 1) napi_get_value_bool(env, args[0], &paused);
    ohos_set_touch_paused(paused);
    return amcl::napi::MakeUndefined(env);
}

// --- 生命周期统一取消：page/background/surface 等边界共用 native OutputLedger 清理 ---
napi_value CancelAllInput(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t reason = AMCL_INPUT_CANCEL_PAGE_DISPOSE;
    if (argc >= 1) napi_get_value_int32(env, args[0], &reason);
    ohos_cancel_all_input(reason);
    return amcl::napi::MakeUndefined(env);
}

// Exact decimal transport avoids losing uint64 epoch identity through a JS
// double after long process lifetimes. ArkTS only compares this opaque value;
// it never parses it or infers lifecycle ordering from the numeric magnitude.
napi_value GetInputResetEpoch(napi_env env, napi_callback_info info) {
    (void)info;
    char text[32]{};
    const int length = std::snprintf(
        text, sizeof(text), "%llu",
        static_cast<unsigned long long>(
            amcl::input::PlatformInputResetEpoch()));
    napi_value result = nullptr;
    if (length <= 0 || static_cast<size_t>(length) >= sizeof(text) ||
        napi_create_string_utf8(env, text, static_cast<size_t>(length),
                                &result) != napi_ok) {
        return amcl::napi::MakeUndefined(env);
    }
    return result;
}

// --- 查询 grabbed 状态 ---
napi_value IsGrabbed(napi_env env, napi_callback_info info) {
    return amcl::napi::MakeBoolResult(env, ohos_is_grabbed() != 0);
}

// ============================================================
//  方案 B：grabbed 变化回调（native 即时推送 → ArkTS，取代 300ms 轮询）
//
//  链路：libglfw.so nativeSetGrabbing（MC 线程）→ 经 env 句柄 AMCL_GRAB_CB 拿到
//        下面 GrabChangeTrampoline 的地址并调用 → trampoline 把 grabbing 排队进
//        napi threadsafe function → NAPI runtime 回到 ArkTS(UI) 线程执行 GrabCallJs
//        → 调用注册的 JS 回调。
//
//  跨 .so 方向说明：libentry→libglfw 读 grab 用 dlsym（touch_input，已验证可用）；
//  libglfw→libentry 推回调用 env 句柄（与 OHOS_INPUT_BRIDGE 同机制，规避反向 dlsym 不可靠）。
// ============================================================
napi_threadsafe_function g_grabTsfn = nullptr;
// 保护 g_grabTsfn 的注册（UI 线程）与调用（MC 线程）不重叠，杜绝 check-then-use 竞争。
// 临界区都很短（一次 tsfn 创建 / 一次 nonblocking 入队），grab 翻转低频，无性能影响。
std::mutex g_grabMutex;

void GrabCallJs(napi_env env, napi_value js_cb, void* /*context*/, void* data) {
    if (!env || !js_cb) return;
    bool grabbed = (data != nullptr);
    napi_value arg;
    napi_get_boolean(env, grabbed, &arg);
    napi_value undef;
    napi_get_undefined(env, &undef);
    napi_value result;
    napi_call_function(env, undef, js_cb, 1, &arg, &result);
}

// 由 libglfw.so 经 env 句柄取址后在 grab 翻转时调用（MC 线程）。仅把状态排队到
// JS 线程；tsfn 为空（未注册 / 已注销）时安全 no-op。地址稳定，可长期发布给 libglfw。
void GrabChangeTrampoline(int grabbing) {
    std::lock_guard<std::mutex> lk(g_grabMutex);
    if (!g_grabTsfn) return;
    napi_call_threadsafe_function(
        g_grabTsfn, grabbing ? reinterpret_cast<void*>(1) : nullptr, napi_tsfn_nonblocking);
}

// onGrabChange(callback?) —— 注册 grabbed 变化回调；传空 / 非函数 = 注销。
napi_value OnGrabChange(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    bool hasFn = false;
    if (argc >= 1) {
        napi_valuetype vt;
        napi_typeof(env, args[0], &vt);
        hasFn = (vt == napi_function);
    }

    {
        std::lock_guard<std::mutex> lk(g_grabMutex);
        // 先释放旧 tsfn（重复注册 / 注销都经此）。释放后 trampoline 立即变 no-op。
        if (g_grabTsfn) {
            napi_release_threadsafe_function(g_grabTsfn, napi_tsfn_release);
            g_grabTsfn = nullptr;
        }
        if (!hasFn) {
            return amcl::napi::MakeUndefined(env);   // 注销
        }
        napi_value name;
        napi_create_string_utf8(env, "GrabChange", NAPI_AUTO_LENGTH, &name);
        napi_status st = napi_create_threadsafe_function(
            env, args[0], nullptr, name, 0, 1,
            nullptr, nullptr, nullptr, &GrabCallJs, &g_grabTsfn);
        if (st != napi_ok) {
            g_grabTsfn = nullptr;
            return amcl::napi::MakeUndefined(env);
        }
    }

    // 把 trampoline 地址经 env 发布给 libglfw.so（幂等：地址稳定，重复 set 无副作用）。
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu",
             (unsigned long long)(uintptr_t)&GrabChangeTrampoline);
    setenv("AMCL_GRAB_CB", buf, 1);
    return amcl::napi::MakeUndefined(env);
}

// ============================================================
//  按钮按下态推送（C 层触摸解释器 → ArkTS 更新高亮）
//  C 接管按钮后，键由 C 发；视觉高亮也须由 C 驱动，否则 ArkTS 自己的状态机会与 C 失步
//  （toggle/长按尤甚）。schemaDispatchButton 是所有按钮键事件的唯一出口，在其中推送 (id, pressed)。
// ============================================================
napi_threadsafe_function g_btnPressTsfn = nullptr;
std::mutex g_btnPressMutex;
std::map<std::string, int> g_btnPendingState;
bool g_btnWakeQueued = false;

// 触觉不是输入状态，只是 PRESS 边沿的低频 UI 副作用。队列显式限制为 16：UI 卡顿时允许丢反馈，
// 但绝不能像旧的无界视觉队列那样积压并在数秒后补震。data 直接承载小整数，不分配堆内存。
napi_threadsafe_function g_hapticTsfn = nullptr;
std::mutex g_hapticMutex;

void HapticCallJs(napi_env env, napi_value js_cb, void* /*context*/, void* data) {
    if (!env || !js_cb) return;
    napi_value arg;
    napi_create_int32(env, static_cast<int32_t>(reinterpret_cast<intptr_t>(data)), &arg);
    napi_value undef; napi_get_undefined(env, &undef);
    napi_value result;
    napi_call_function(env, undef, js_cb, 1, &arg, &result);
}

napi_value OnHaptic(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool hasFn = false;
    if (argc >= 1) {
        napi_valuetype type;
        napi_typeof(env, args[0], &type);
        hasFn = (type == napi_function);
    }
    std::lock_guard<std::mutex> lock(g_hapticMutex);
    if (g_hapticTsfn) {
        napi_release_threadsafe_function(g_hapticTsfn, napi_tsfn_release);
        g_hapticTsfn = nullptr;
    }
    if (!hasFn) return amcl::napi::MakeBoolResult(env, true);
    napi_value name;
    if (napi_create_string_utf8(
            env, "InputHaptic", NAPI_AUTO_LENGTH, &name) != napi_ok) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    napi_status status = napi_create_threadsafe_function(
        env, args[0], nullptr, name, 16, 1,
        nullptr, nullptr, nullptr, &HapticCallJs, &g_hapticTsfn);
    if (status != napi_ok) g_hapticTsfn = nullptr;
    return amcl::napi::MakeBoolResult(env, status == napi_ok);
}

// 视觉只关心每个 id 的“最终状态”，不需要重放中间动画。native 线程把状态合并进 map，并只排队
// 一个 wake token；UI 醒来后一次性取走快照。这样队列容量恒为 1，UI 卡顿不会无限吃内存，且最后的
// RELEASE 不会被旧 PRESS 队列淹没。锁只保护 map/TSFN 句柄，调用 JS 时已经释放。
void BtnPressCallJs(napi_env env, napi_value js_cb, void* /*context*/, void* /*data*/) {
    std::map<std::string, int> pending;
    {
        std::lock_guard<std::mutex> lock(g_btnPressMutex);
        pending.swap(g_btnPendingState);
        g_btnWakeQueued = false;
    }
    if (!env || !js_cb) return;
    for (const auto& item : pending) {
        napi_value args[2];
        if (napi_create_string_utf8(env, item.first.c_str(), NAPI_AUTO_LENGTH, &args[0]) != napi_ok) continue;
        napi_get_boolean(env, item.second != 0, &args[1]);
        napi_value undef; napi_get_undefined(env, &undef);
        napi_value result;
        napi_call_function(env, undef, js_cb, 2, args, &result);
    }
}

// onButtonPressed(callback?) —— 注册按钮按下态回调；传空 / 非函数 = 注销。
napi_value OnButtonPressed(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool hasFn = false;
    if (argc >= 1) {
        napi_valuetype vt; napi_typeof(env, args[0], &vt);
        hasFn = (vt == napi_function);
    }
    std::lock_guard<std::mutex> lk(g_btnPressMutex);
    if (g_btnPressTsfn) {
        napi_release_threadsafe_function(g_btnPressTsfn, napi_tsfn_release);
        g_btnPressTsfn = nullptr;
    }
    g_btnPendingState.clear();
    g_btnWakeQueued = false;
    if (!hasFn) return amcl::napi::MakeBoolResult(env, true);
    napi_value name;
    if (napi_create_string_utf8(
            env, "ButtonPressed", NAPI_AUTO_LENGTH, &name) != napi_ok) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    napi_status st = napi_create_threadsafe_function(
        env, args[0], nullptr, name, 1, 1,
        nullptr, nullptr, nullptr, &BtnPressCallJs, &g_btnPressTsfn);
    if (st != napi_ok) g_btnPressTsfn = nullptr;
    return amcl::napi::MakeBoolResult(env, st == napi_ok);
}

// ⚠️ `registerButton` / `registerJoystick` / `clearButtons` / `clearJoystick` 四个入口
// 已删除。它们把矩形表填进 C 层，而那张表的唯一读取方位于一个永不执行的分支里 ——
// ArkTS 每次布局重建都在跨语言填一张没人读的表。触控虚拟按键端的权威表述是
// `setControlSchema`（含 hit-test、hitSlop、handledBy、四种 trigger）。

// --- 视角灵敏度 / Y 轴倒置 ---
napi_value SetLookSensitivity(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double v = 1.0;
    if (argc >= 1) napi_get_value_double(env, args[0], &v);
    ohos_set_look_sensitivity((float)v);
    return amcl::napi::MakeUndefined(env);
}

napi_value SetInvertY(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool b = false;
    if (argc >= 1) napi_get_value_bool(env, args[0], &b);
    ohos_set_invert_y(b);
    return amcl::napi::MakeUndefined(env);
}

// --- R2：look 平滑系数（EMA alpha，0.1..1.0；1.0=关闭平滑） ---
napi_value SetLookSmoothing(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double v = 0.6;
    if (argc >= 1) napi_get_value_double(env, args[0], &v);
    ohos_set_look_smoothing((float)v);
    return amcl::napi::MakeUndefined(env);
}

// --- 方案 C：视角加速强度（0..1，0=关闭） ---
napi_value SetLookAccel(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    double v = 0.0;
    if (argc >= 1) napi_get_value_double(env, args[0], &v);
    ohos_set_look_accel((float)v);
    return amcl::napi::MakeUndefined(env);
}

// --- Control Schema v2：严格、事务化协议边界 ---
// 这里先为 ArkTS 提供可诊断的拒绝结果；touch_input.cpp 仍会独立复验，防止未来新增的 C 调用方
// 绕过 NAPI。任何失败都返回 0，且绝不能调用发布函数，因此当前 native generation 保持原样。
static napi_value SchemaResult(napi_env env, uint64_t generation) {
    napi_value result;
    napi_create_double(env, static_cast<double>(generation), &result);
    return result;
}

static napi_value RejectSchema(napi_env env, const char* reason) {
    OH_LOG_WARN(LOG_APP, "ControlSchema NAPI rejected: %{public}s", reason);
    return SchemaResult(env, 0);
}

static bool NamedValue(napi_env env, napi_value obj, const char* name, napi_value* out) {
    bool has = false;
    return napi_has_named_property(env, obj, name, &has) == napi_ok && has &&
           napi_get_named_property(env, obj, name, out) == napi_ok;
}

static bool StrictInt(napi_env env, napi_value value, int32_t* out) {
    napi_valuetype type;
    double number = 0.0;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_number ||
        napi_get_value_double(env, value, &number) != napi_ok || !std::isfinite(number) ||
        number < static_cast<double>(INT32_MIN) || number > static_cast<double>(INT32_MAX) ||
        std::floor(number) != number) return false;
    *out = static_cast<int32_t>(number);
    return true;
}

static bool NamedInt(napi_env env, napi_value obj, const char* name, int32_t* out) {
    napi_value value;
    return NamedValue(env, obj, name, &value) && StrictInt(env, value, out);
}

static bool NamedDouble(napi_env env, napi_value obj, const char* name, double* out) {
    napi_value value;
    napi_valuetype type;
    return NamedValue(env, obj, name, &value) && napi_typeof(env, value, &type) == napi_ok &&
           type == napi_number && napi_get_value_double(env, value, out) == napi_ok && std::isfinite(*out);
}

static bool NamedBool(napi_env env, napi_value obj, const char* name, bool* out) {
    napi_value value;
    napi_valuetype type;
    return NamedValue(env, obj, name, &value) && napi_typeof(env, value, &type) == napi_ok &&
           type == napi_boolean && napi_get_value_bool(env, value, out) == napi_ok;
}

napi_value SetControlSchema(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc != 1) return RejectSchema(env, "missing-message");

    napi_valuetype rootType;
    if (napi_typeof(env, args[0], &rootType) != napi_ok || rootType != napi_object)
        return RejectSchema(env, "message-type");

    int32_t schemaVersion = 0;
    double compW = 0.0, compH = 0.0, deadZone = 0.0;
    bool grabbed = false;
    if (!NamedInt(env, args[0], "schemaVersion", &schemaVersion) ||
        schemaVersion != AMCL_CONTROL_SCHEMA_VERSION) return RejectSchema(env, "unsupported-version");
    if (!NamedDouble(env, args[0], "compWidth", &compW) ||
        !NamedDouble(env, args[0], "compHeight", &compH) ||
        compW <= 0.0 || compH <= 0.0 || compW > 65536.0 || compH > 65536.0)
        return RejectSchema(env, "component-size");
    if (!NamedBool(env, args[0], "grabbed", &grabbed)) return RejectSchema(env, "grabbed");
    if (!NamedDouble(env, args[0], "deadZone", &deadZone) || deadZone <= 0.0 || deadZone >= 1.0)
        return RejectSchema(env, "dead-zone");

    napi_value controlsValue;
    bool isControlsArray = false;
    if (!NamedValue(env, args[0], "controls", &controlsValue) ||
        napi_is_array(env, controlsValue, &isControlsArray) != napi_ok || !isControlsArray)
        return RejectSchema(env, "controls-type");
    uint32_t count = 0;
    if (napi_get_array_length(env, controlsValue, &count) != napi_ok ||
        count > AMCL_CONTROL_SCHEMA_MAX_CONTROLS) return RejectSchema(env, "control-count");

    std::vector<AmclCtrlEntry> entries;
    std::set<std::string> ids;
    entries.reserve(count);
    for (uint32_t i = 0; i < count; i++) {
        napi_value item;
        napi_valuetype itemType;
        if (napi_get_element(env, controlsValue, i, &item) != napi_ok ||
            napi_typeof(env, item, &itemType) != napi_ok || itemType != napi_object)
            return RejectSchema(env, "control-type");

        AmclCtrlEntry entry{};
        napi_value idValue;
        napi_valuetype idType;
        size_t idBytes = 0;
        if (!NamedValue(env, item, "id", &idValue) || napi_typeof(env, idValue, &idType) != napi_ok ||
            idType != napi_string || napi_get_value_string_utf8(env, idValue, nullptr, 0, &idBytes) != napi_ok ||
            idBytes == 0 || idBytes > AMCL_CONTROL_ID_MAX_BYTES)
            return RejectSchema(env, "id-length");
        size_t copied = 0;
        if (napi_get_value_string_utf8(env, idValue, entry.id, sizeof(entry.id), &copied) != napi_ok ||
            copied != idBytes || !ids.insert(std::string(entry.id, copied)).second)
            return RejectSchema(env, "duplicate-or-invalid-id");

        if (!NamedInt(env, item, "kind", &entry.kind) || entry.kind < 0 || entry.kind > 4)
            return RejectSchema(env, "kind");
        if (!NamedInt(env, item, "handledBy", &entry.handledBy) ||
            (entry.handledBy != 0 && entry.handledBy != 1)) return RejectSchema(env, "handled-by");
        if (!NamedInt(env, item, "trigger", &entry.trigger) || entry.trigger < 0 || entry.trigger > 3)
            return RejectSchema(env, "trigger");
        if (!NamedInt(env, item, "keyOrMouse", &entry.keyOrMouse)) return RejectSchema(env, "key");

        double x = 0.0, y = 0.0, w = 0.0, h = 0.0, hitSlop = 0.0;
        if (!NamedDouble(env, item, "x", &x) || !NamedDouble(env, item, "y", &y) ||
            !NamedDouble(env, item, "w", &w) || !NamedDouble(env, item, "h", &h) ||
            !NamedDouble(env, item, "hitSlop", &hitSlop) || x < -1.0 || y < -1.0 ||
            w <= 0.0 || h <= 0.0 || x + w > compW + 1.0 || y + h > compH + 1.0 ||
            hitSlop < 0.0 || hitSlop > 256.0) return RejectSchema(env, "rect");
        entry.x = static_cast<float>(x); entry.y = static_cast<float>(y);
        entry.w = static_cast<float>(w); entry.h = static_cast<float>(h);
        entry.hitSlop = static_cast<float>(hitSlop);

        bool dragLook = false, haptic = false;
        if (!NamedBool(env, item, "dragLook", &dragLook) || !NamedBool(env, item, "haptic", &haptic))
            return RejectSchema(env, "boolean-field");
        entry.dragLook = dragLook ? 1 : 0;
        entry.haptic = haptic ? 1 : 0;

        napi_value keysValue;
        bool isKeysArray = false;
        uint32_t keyCount = 0;
        if (!NamedValue(env, item, "keys", &keysValue) ||
            napi_is_array(env, keysValue, &isKeysArray) != napi_ok || !isKeysArray ||
            napi_get_array_length(env, keysValue, &keyCount) != napi_ok ||
            keyCount > AMCL_CONTROL_MAX_KEYS) return RejectSchema(env, "keys");
        entry.keyCount = static_cast<int>(keyCount);
        for (uint32_t k = 0; k < keyCount; k++) {
            napi_value keyValue;
            if (napi_get_element(env, keysValue, k, &keyValue) != napi_ok ||
                !StrictInt(env, keyValue, &entry.keys[k])) return RejectSchema(env, "key-value");
        }
        entries.push_back(entry);
    }

    const uint64_t generation = ohos_set_control_schema(
        entries.empty() ? nullptr : entries.data(), static_cast<int>(entries.size()),
        static_cast<float>(compW), static_cast<float>(compH), grabbed ? 1 : 0,
        static_cast<float>(deadZone), schemaVersion);
    return SchemaResult(env, generation);
}

bool ReadTextSessionId(napi_env env, napi_value value, uint64_t* out) {
    if (!out) return false;
    int64_t signedId = 0;
    if (napi_get_value_int64(env, value, &signedId) != napi_ok ||
        signedId <= 0) {
        return false;
    }
    *out = static_cast<uint64_t>(signedId);
    return true;
}

// Query the encoded length before allocating.  ReadStringValue is appropriate
// for ordinary UI strings, but typed input is an untrusted packet boundary: a
// JavaScript string can be arbitrarily large and must not force an equally
// large native allocation merely so the core can reject it afterwards.
bool ReadBoundedUtf8String(napi_env env, napi_value value,
                           size_t maximumBytes, std::string& out) {
    size_t byteCount = 0u;
    if (napi_get_value_string_utf8(env, value, nullptr, 0u, &byteCount) !=
            napi_ok ||
        byteCount > maximumBytes) {
        return false;
    }
    std::vector<char> buffer(byteCount + 1u, '\0');
    size_t copiedBytes = 0u;
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(),
                                   &copiedBytes) != napi_ok ||
        copiedBytes != byteCount) {
        return false;
    }
    out.assign(buffer.data(), copiedBytes);
    return true;
}

// Candidate lists arrive from ArkTS as an arbitrary JS array.  Bound the
// container before reserving/decoding it so a hostile or accidentally huge
// NAPI call cannot allocate unbounded memory merely to receive a packet that
// the core would reject later.  The codec remains the second, authoritative
// validation layer for UTF-8, scalar count, and wire-size arithmetic.
bool ReadBoundedTextCandidateArray(
        napi_env env, napi_value value, std::vector<std::string>& out) {
    bool isArray = false;
    uint32_t count = 0u;
    if (napi_is_array(env, value, &isArray) != napi_ok || !isArray ||
        napi_get_array_length(env, value, &count) != napi_ok ||
        static_cast<size_t>(count) > amcl::input::kTextCandidateMaxItems) {
        return false;
    }
    out.clear();
    out.reserve(count);
    size_t totalBytes = amcl::input::kTextCandidateBlobHeaderBytes;
    for (uint32_t index = 0u; index < count; ++index) {
        napi_value item = nullptr;
        std::string text;
        if (totalBytes > amcl::input::kTextCandidateMaxBlobBytes -
                             amcl::input::kTextCandidateLengthBytes) {
            return false;
        }
        const size_t aggregateRemaining =
            amcl::input::kTextCandidateMaxBlobBytes - totalBytes -
            amcl::input::kTextCandidateLengthBytes;
        const size_t itemLimit =
            aggregateRemaining < amcl::input::kTextCandidateMaxUtf8Bytes
                ? aggregateRemaining
                : amcl::input::kTextCandidateMaxUtf8Bytes;
        if (napi_get_element(env, value, index, &item) != napi_ok ||
            !ReadBoundedUtf8String(env, item, itemLimit, text)) {
            return false;
        }
        totalBytes += amcl::input::kTextCandidateLengthBytes + text.size();
        out.push_back(std::move(text));
    }
    return true;
}

napi_value TextInputSessionSupported(napi_env env,
                                     napi_callback_info /*info*/) {
    return amcl::napi::MakeBoolResult(
        env, amcl::input::PlatformInputTextSessionSupported());
}

napi_value BeginTextInputSession(napi_env env, napi_callback_info info) {
    size_t argc = 1u;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint64_t id = 0u;
    if (argc != 1u || !ReadTextSessionId(env, args[0], &id)) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    amcl::input::SurfaceInputGateTransaction gate;
    return amcl::napi::MakeBoolResult(
        env, gate && amcl::input::PlatformInputTextSessionBegin(id));
}

napi_value EndTextInputSession(napi_env env, napi_callback_info info) {
    size_t argc = 1u;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint64_t id = 0u;
    if (argc != 1u || !ReadTextSessionId(env, args[0], &id)) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    amcl::input::SurfaceInputGateTransaction gate;
    return amcl::napi::MakeBoolResult(
        env, gate && amcl::input::PlatformInputTextSessionEnd(id));
}

napi_value AbortTextInputSession(napi_env env, napi_callback_info info) {
    size_t argc = 1u;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint64_t id = 0u;
    if (argc != 1u || !ReadTextSessionId(env, args[0], &id)) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    amcl::input::SurfaceInputGateTransaction gate;
    return amcl::napi::MakeBoolResult(
        env, gate && amcl::input::PlatformInputTextSessionAbort(id));
}

napi_value CommitTextInput(napi_env env, napi_callback_info info) {
    size_t argc = 2u;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint64_t id = 0u;
    std::string text;
    if (argc != 2u || !ReadTextSessionId(env, args[0], &id) ||
        !ReadBoundedUtf8String(env, args[1],
                               amcl::input::kTextCandidateMaxUtf8Bytes,
                               text) ||
        text.empty()) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    amcl::input::SurfaceInputGateTransaction gate;
    return amcl::napi::MakeBoolResult(
        env, gate && amcl::input::PlatformInputTextCommit(
            id, reinterpret_cast<const uint8_t*>(text.data()),
            static_cast<uint32_t>(text.size())));
}

napi_value UpdateTextInputEditing(napi_env env, napi_callback_info info) {
    size_t argc = 4u;
    napi_value args[4] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint64_t id = 0u;
    uint32_t start = 0u;
    uint32_t length = 0u;
    std::string text;
    if (argc != 4u || !ReadTextSessionId(env, args[0], &id) ||
        !ReadBoundedUtf8String(env, args[1],
                               amcl::input::kTextCandidateMaxUtf8Bytes,
                               text) ||
        napi_get_value_uint32(env, args[2], &start) != napi_ok ||
        napi_get_value_uint32(env, args[3], &length) != napi_ok) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    amcl::input::SurfaceInputGateTransaction gate;
    return amcl::napi::MakeBoolResult(
        env, gate && amcl::input::PlatformInputTextEditing(
            id, reinterpret_cast<const uint8_t*>(text.data()),
            static_cast<uint32_t>(text.size()), start, length));
}

napi_value UpdateTextInputSelection(napi_env env, napi_callback_info info) {
    size_t argc = 3u;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint64_t id = 0u;
    uint32_t start = 0u;
    uint32_t length = 0u;
    if (argc != 3u || !ReadTextSessionId(env, args[0], &id) ||
        napi_get_value_uint32(env, args[1], &start) != napi_ok ||
        napi_get_value_uint32(env, args[2], &length) != napi_ok) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    amcl::input::SurfaceInputGateTransaction gate;
    return amcl::napi::MakeBoolResult(
        env, gate && amcl::input::PlatformInputTextSelection(
            id, start, length));
}

napi_value SubmitTextInputCandidates(napi_env env,
                                     napi_callback_info info) {
    size_t argc = 5u;
    napi_value args[5] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint64_t id = 0u;
    uint32_t selected = 0u;
    uint32_t pageStart = 0u;
    uint32_t pageSize = 0u;
    std::vector<std::string> items;
    if (argc != 5u || !ReadTextSessionId(env, args[0], &id) ||
        !ReadBoundedTextCandidateArray(env, args[1], items) ||
        napi_get_value_uint32(env, args[2], &selected) != napi_ok ||
        napi_get_value_uint32(env, args[3], &pageStart) != napi_ok ||
        napi_get_value_uint32(env, args[4], &pageSize) != napi_ok) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    std::vector<amcl::input::TextUtf8Span> spans(items.size());
    for (size_t index = 0u; index < items.size(); ++index) {
        spans[index].data = reinterpret_cast<const uint8_t*>(
            items[index].data());
        spans[index].byteCount = items[index].size();
    }
    size_t encodedBytes = 0u;
    const amcl::input::TextUtf8CodecStatus sizeStatus =
        amcl::input::EncodeTextCandidateBlob(
            spans.empty() ? nullptr : spans.data(), spans.size(), nullptr, 0u,
            &encodedBytes);
    if (sizeStatus != amcl::input::TextUtf8CodecStatus::kOk ||
        encodedBytes > UINT32_MAX) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    std::vector<uint8_t> encoded(encodedBytes);
    size_t filledBytes = 0u;
    const amcl::input::TextUtf8CodecStatus encodeStatus =
        amcl::input::EncodeTextCandidateBlob(
            spans.empty() ? nullptr : spans.data(), spans.size(),
            encoded.data(), encoded.size(), &filledBytes);
    if (encodeStatus != amcl::input::TextUtf8CodecStatus::kOk ||
        filledBytes != encodedBytes) {
        return amcl::napi::MakeBoolResult(env, false);
    }
    amcl::input::SurfaceInputGateTransaction gate;
    return amcl::napi::MakeBoolResult(
        env, gate && amcl::input::PlatformInputTextCandidates(
            id, encoded.data(), static_cast<uint32_t>(encoded.size()),
            selected, pageStart, pageSize,
            static_cast<uint32_t>(items.size())));
}

napi_value NoteTextInputCandidatesUnsupported(
        napi_env env, napi_callback_info /*info*/) {
    amcl::input::PlatformInputNoteCandidatesUnsupported();
    return amcl::napi::MakeUndefined(env);
}

napi_value GetTextInputCandidatesUnsupportedCount(
        napi_env env, napi_callback_info /*info*/) {
    napi_value out = nullptr;
    if (napi_create_double(
            env, static_cast<double>(
                amcl::input::PlatformInputCandidatesUnsupportedCount()),
            &out) != napi_ok) {
        return amcl::napi::MakeUndefined(env);
    }
    return out;
}

// --- 阶段 2.8：char 事件（IME / 物理键盘可打印字符） ---
// This is only a Phase 6 TextInputSession compatibility guard. Per-codepoint
// legacy routing remains intentionally distinct from a future owned, atomic
// text packet/session design and must not be presented as that final solution.
napi_value SendCharEvent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t codepoint = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &codepoint);
    if (!amcl::input::IsUnicodeScalarValue(codepoint)) {
        amcl::input::trace::RecordUnsupported();
        return amcl::napi::MakeUndefined(env);
    }
    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) {
        // Character callbacks can race surface teardown just like key ingress;
        // reject before touching the legacy ring and account only when shadow
        // tracing is compiled/enabled.
        if (amcl::input::PlatformInputShadowEnabled()) {
            amcl::input::trace::RecordGateRejected();
        }
        return amcl::napi::MakeUndefined(env);
    }
    ohos_send_char_event(codepoint);
    return amcl::napi::MakeUndefined(env);
}

napi_value SendCharModsEvent(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t codepoint = 0, mods = 0;
    if (argc >= 1) napi_get_value_int32(env, args[0], &codepoint);
    if (argc >= 2) napi_get_value_int32(env, args[1], &mods);
    if (!amcl::input::IsUnicodeScalarValue(codepoint)) {
        amcl::input::trace::RecordUnsupported();
        return amcl::napi::MakeUndefined(env);
    }
    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) {
        // Keep modified characters under the same current-surface transaction;
        // otherwise a stale callback could write after teardown cancellation.
        if (amcl::input::PlatformInputShadowEnabled()) {
            amcl::input::trace::RecordGateRejected();
        }
        return amcl::napi::MakeUndefined(env);
    }
    ohos_send_char_mods_event(codepoint, mods);
    return amcl::napi::MakeUndefined(env);
}

// ⚠️ 墓碑: `SetCompSize` / `setCompSize` 已删除（写入的 native static 终点零读者），
// 详见计划 §64.3。组件尺寸由 `SetControlSchema` 的 `compWidth`/`compHeight` 携带 ——
// 那两个字段是活的，本文件 :1243-1246 与 :1295 就在用它们做越界校验。

#define NAPI_FUNC(name, fn) \
    { name, nullptr, fn, nullptr, nullptr, nullptr, napi_default, nullptr }

constexpr napi_property_descriptor kInputDescriptors[] = {
    NAPI_FUNC("sendTouchEvent",      SendTouchEvent),
    NAPI_FUNC("sendKeyEvent",        SendKeyEvent),
    NAPI_FUNC("configureInputProduct", ConfigureInputProduct),
    NAPI_FUNC("hardwareRawMouseAvailable", HardwareRawMouseAvailable),
    NAPI_FUNC("physicalKeyTransaction", PhysicalKeyTransaction),
    NAPI_FUNC("physicalMouseButtonTransaction", PhysicalMouseButtonTransaction),
    NAPI_FUNC("setCursorLocked", SetCursorLocked),
    NAPI_FUNC("noteCursorLockFocusLost", NoteCursorLockFocusLost),
    NAPI_FUNC("isCursorLockSupported", IsCursorLockSupported),
    NAPI_FUNC("cursorLockWatchdogTick", CursorLockWatchdogTick),
    NAPI_FUNC("installWindowInputFilters", InstallWindowInputFilters),
    NAPI_FUNC("uninstallWindowInputFilters", UninstallWindowInputFilters),
    NAPI_FUNC("windowInputFilterActive", WindowInputFilterActive),
    NAPI_FUNC("nativeWheelChannelActive", NativeWheelChannelActive),
    NAPI_FUNC("wheelChannelClaim", WheelChannelClaim),
    NAPI_FUNC("noteKeyRepeatSelfHealed", NoteKeyRepeatSelfHealed),
    NAPI_FUNC("noteArktsAxisEvent", NoteArktsAxisEvent),
    NAPI_FUNC("noteAxisPanActive", NoteAxisPanActive),
    NAPI_FUNC("setDisplayDensity", SetDisplayDensity),
    NAPI_FUNC("publishInputDeviceChange", PublishInputDeviceChange),
    NAPI_FUNC("publishInputSurfaceContext", PublishInputSurfaceContext),
    NAPI_FUNC("physicalPointerMotionTransaction", PhysicalPointerMotionTransaction),
    NAPI_FUNC("physicalPointerRelativeTransaction", PhysicalPointerRelativeTransaction),
    NAPI_FUNC("physicalPointerWheelTransaction", PhysicalPointerWheelTransaction),
    NAPI_FUNC("physicalPointerRelativeFallbackTransaction", PhysicalPointerRelativeFallbackTransaction),
    NAPI_FUNC("physicalMenuCursorPositionTransaction", PhysicalMenuCursorPositionTransaction),
    NAPI_FUNC("traceUnverifiedCursorPosition", TraceUnverifiedCursorPosition),
    NAPI_FUNC("gate0InputTelemetryEnabled", Gate0InputTelemetryEnabled),
    NAPI_FUNC("traceGate0ArktsMouse", TraceGate0ArktsMouse),
    NAPI_FUNC("sendMouseEvent",      SendMouseEvent),
    NAPI_FUNC("sendScrollEvent",     SendScrollEvent),
    NAPI_FUNC("sendCursorDelta",     SendCursorDelta),
    // ---- 按端申报的一组（三端平级架构的 NAPI 接缝）----
    NAPI_FUNC("sendSourceKeyEvent",    SendSourceKeyEvent),
    NAPI_FUNC("sendSourceMouseEvent",  SendSourceMouseEvent),
    NAPI_FUNC("sendSourceScrollEvent", SendSourceScrollEvent),
    NAPI_FUNC("sendSourceCursorDelta", SendSourceCursorDelta),
    NAPI_FUNC("releaseSourceHeld",     ReleaseSourceHeld),
    NAPI_FUNC("noteSourceReset",       NoteSourceReset),
    NAPI_FUNC("inputInvariantTick",    InputInvariantTick),
    NAPI_FUNC("sendCursorPos",       SendCursorPos),
    NAPI_FUNC("textInputSessionSupported", TextInputSessionSupported),
    NAPI_FUNC("beginTextInputSession", BeginTextInputSession),
    NAPI_FUNC("endTextInputSession", EndTextInputSession),
    NAPI_FUNC("abortTextInputSession", AbortTextInputSession),
    NAPI_FUNC("commitTextInput", CommitTextInput),
    NAPI_FUNC("updateTextInputEditing", UpdateTextInputEditing),
    NAPI_FUNC("updateTextInputSelection", UpdateTextInputSelection),
    NAPI_FUNC("submitTextInputCandidates", SubmitTextInputCandidates),
    NAPI_FUNC("noteTextInputCandidatesUnsupported",
              NoteTextInputCandidatesUnsupported),
    NAPI_FUNC("getTextInputCandidatesUnsupportedCount",
              GetTextInputCandidatesUnsupportedCount),
    NAPI_FUNC("sendCharEvent",       SendCharEvent),
    NAPI_FUNC("sendCharModsEvent",   SendCharModsEvent),
    NAPI_FUNC("isGrabbed",           IsGrabbed),
    NAPI_FUNC("onGrabChange",        OnGrabChange),
    NAPI_FUNC("onButtonPressed",     OnButtonPressed),
    NAPI_FUNC("onHaptic",           OnHaptic),
    // registerButton / registerJoystick / clearButtons / clearJoystick / setCompSize
    // 已删除，见上方说明（只写不读的跨语言写入链，权威表述是 setControlSchema）。
    NAPI_FUNC("setTouchPaused",      SetTouchPaused),
    NAPI_FUNC("cancelAllInput",       CancelAllInput),
    NAPI_FUNC("getInputResetEpoch",   GetInputResetEpoch),
    NAPI_FUNC("setLookSensitivity",  SetLookSensitivity),
    NAPI_FUNC("setInvertY",          SetInvertY),
    NAPI_FUNC("setLookSmoothing",    SetLookSmoothing),
    NAPI_FUNC("setLookAccel",        SetLookAccel),
    NAPI_FUNC("setControlSchema",    SetControlSchema),
};

#undef NAPI_FUNC

} // anonymous namespace

// 由 touch_input.cpp 的 schemaDispatchButton / hotbar tap 在 native 输入线程调用。
// nonblocking + bounded queue：队列满时允许丢本次反馈；输入 PRESS/RELEASE 绝不依赖触觉成功，
// 也不能为了等待 UI 线程而阻塞 XComponent/MC 输入线程。
extern "C" void amcl_fire_haptic(int strength) {
    if (strength <= 0) return;
    std::lock_guard<std::mutex> lock(g_hapticMutex);
    if (!g_hapticTsfn) return;
    napi_call_threadsafe_function(g_hapticTsfn, reinterpret_cast<void*>(static_cast<intptr_t>(strength)),
                                  napi_tsfn_nonblocking);
}

// 由 touch_input.cpp 的 schemaDispatchButton 在按钮状态变化时调用。只记录该 id 的最终状态并
// 尝试排队一个 wake token；若 UI 线程尚未消费，上一次 token 会负责带走最新 map，不再重复排队。
extern "C" void amcl_fire_button_pressed(const char* id, int pressed) {
    if (!id || !id[0]) return;
    std::lock_guard<std::mutex> lock(g_btnPressMutex);
    if (!g_btnPressTsfn) return;
    g_btnPendingState[std::string(id)] = pressed != 0 ? 1 : 0;
    if (g_btnWakeQueued) return;
    if (napi_call_threadsafe_function(g_btnPressTsfn, nullptr, napi_tsfn_nonblocking) == napi_ok) {
        g_btnWakeQueued = true;
    }
}

namespace amcl::napi {

void registerInputNapi(napi_env env, napi_value exports) {
    // 反向 trampoline 必须在任何输入事件之前就位。typed 视角的消费者可以是**第一个**
    // 相对样本，那时 bridge-resolve 路径可能一次都还没跑过（理由见 touch_input.cpp 的
    // publishReverseTrampolines 注释）。这里发布是幂等的，不依赖 libglfw 是否已加载。
    ohos_input_publish_trampolines();
    napi_define_properties(env, exports,
                           sizeof(kInputDescriptors) / sizeof(kInputDescriptors[0]),
                           kInputDescriptors);
}

} // namespace amcl::napi
