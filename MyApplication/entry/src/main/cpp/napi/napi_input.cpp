#include "../platform/source_control_client.h"
#include "../input/runtime_desktop_capability.h"
/**
 * napi_input.cpp — 输入事件 / 控件区域 / XComponent 尺寸 NAPI 实现
 */
#include "napi_input.h"
#include "napi_helpers.h"

#include "../input/platform_input_ingress.h"
#include "../input/adapters/backend_input_bridge.h"
#include "../input/input_trace.h"
#include "../input/input_latency_observation.h"
#if AMCL_INPUT_TRACE
#include <atomic>
#endif
#include "../input/text_utf8_codec.h"
#include "../platform/input_channel_census.h"
#include "../platform/touch_input.h"
#include "../platform/touch_publication.h"
#include "../platform/cursor_lock.h"
#include "../platform/cursor_capture_policy.h"
#include "../platform/native_mouse_route_policy.h"
#include "../platform/pointer_device_registry.h"
#include "../platform/source_look_processor.h"
#include "../platform/mapped_look_producer.h"
#include "../input/delivery/look_execution.h"
#include "../input/source/source_control.h"
#include "../platform/product_input_policy.h"
#include "../platform/unicode_scalar.h"
#include "../jvm/game_gui_bridge.h"
#include "../jvm/game_gui_observation.h"
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
#include <memory>
#include <new>
#include <ctime>
#include <mutex>
#include <set>
#include <string>
#include <utility>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "NAPI_INPUT"

namespace {
// 数值/文本的菜单工具入口复用后文的有界UTF-8读取，不能为一段owner名分配任意大字符串。
bool ReadBoundedUtf8String(napi_env env,napi_value value,size_t maximumBytes,std::string& out);

// ADD/REMOVED 分类缓存与按钮释放在同一 surface gate 内串行；缓存只保留类别，
// 不把 inventory 的 id 猜测成 native XComponent 从未提供过的设备 id。
amcl::input::PointerDeviceRegistry gPointerDevices;

/** 生命周期事务也要在surface已失效时释放，因此只持gate锁，不以accepted作准入。 */
class SurfaceLifecycleLock final {
public:
    SurfaceLifecycleLock() { ohos_surface_input_gate_lock(); }
    ~SurfaceLifecycleLock() { ohos_surface_input_gate_unlock(); }
};

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
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t device = 0;
    bool added = false;
    uint32_t capabilities = 0;
    uint32_t deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
    int32_t pointerRemoval = -1;
    if (argc >= 1) napi_get_value_int64(env, args[0], &device);
    if (argc >= 2) napi_get_value_bool(env, args[1], &added);
    if (argc >= 3) napi_get_value_uint32(env, args[2], &capabilities);
    if (argc >= 4) napi_get_value_uint32(env, args[3], &deviceClass);
    if (argc >= 5) napi_get_value_int32(env, args[4], &pointerRemoval);
    if (device <= 0) {
        // Negative/zero cannot name an owner domain. Let ingress own the
        // diagnostic so ArkTS and native producers are counted identically.
        amcl::input::PlatformInputDeviceChanged(
            0u, added, capabilities, deviceClass);
        return amcl::napi::MakeUndefined(env);
    }
    // 分类和配对释放必须先于 core 的 DEVICE_REMOVED。surface teardown 已经发生时
    // gate 的 accepted 可为 false，但释放仍要执行；显式锁只用于串行，不能早退。
    SurfaceLifecycleLock lifecycleLock;
    using PointerKind = amcl::input::PointerDeviceRegistry::Kind;
    const uint64_t id = static_cast<uint64_t>(device);
    if (added) {
        const uint32_t pointerCaps = AMCL_INPUT_DEVICE_CAP_POINTER_ABSOLUTE |
            AMCL_INPUT_DEVICE_CAP_POINTER_RELATIVE | AMCL_INPUT_DEVICE_CAP_POINTER_BUTTONS |
            AMCL_INPUT_DEVICE_CAP_WHEEL | AMCL_INPUT_DEVICE_CAP_HOVER;
        const bool pointer = (capabilities & pointerCaps) != 0u ||
            deviceClass == AMCL_INPUT_DEVICE_CLASS_MOUSE ||
            deviceClass == AMCL_INPUT_DEVICE_CLASS_TOUCHPAD;
        gPointerDevices.Added(id, pointer ? PointerKind::Pointer
            : capabilities != 0u ? PointerKind::Other : PointerKind::Unknown);
    } else {
        const PointerKind overrideKind = pointerRemoval == 1 ? PointerKind::Pointer
            : pointerRemoval == 0 ? PointerKind::Other : PointerKind::Unknown;
        const auto removal = gPointerDevices.Removed(id, overrideKind);
        if (removal.classificationMissing) {
            OH_LOG_WARN(LOG_APP,
                "Pointer removal classification unavailable device=%{public}llu; "
                "release unknown pointer bucket, preserve other known devices",
                static_cast<unsigned long long>(id));
        }
        ohos_release_physical_pointer_device(id, removal.releaseUnknown);
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
    if (accepted && (context.validFields & AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY)) {
        amcl::input::TouchContextPolicyChanged(context.density,
            (context.validFields & AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM) ? context.transform : UINT32_MAX);
    }
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
    // Base 输入冷合同先核来源 owner，缺失/外来/旧表时不冻结 product，也不注册平台出口。
    // 返回5是本入口的 source contract 未准入；保留原0/1及2/3/4产品回执语义。
    // 这里只解析预线程发布的 port，不加载游戏类、不借 look supported 代替基础准入。
    if (!amclSourceControlPrepareV1()) {
        OH_LOG_ERROR(LOG_APP, "InputContractMismatch:source_owner");
        napi_value failure=nullptr;
        napi_create_int32(env,5,&failure);
        return failure;
    }
    // 所有产品都注册同一加工实现；共享runtime只保存回调，不反向链接entry UI。
    if (!amclBackendInputSetLookProcessorV1(amcl_process_source_look_delta)) {
        OH_LOG_ERROR(LOG_APP, "Source look processor registration rejected");
    }
    if (!amclBackendInputSetLookResetV1(amcl_reset_source_look_delta)) {
        OH_LOG_ERROR(LOG_APP, "Source look reset registration rejected");
    }
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
    if (gate) ohos_note_physical_pointer_visual();
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
    ohos_note_physical_pointer_visual();
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
    SurfaceLifecycleLock lifecycleLock;
    const AmclCursorLockResult result =
        amcl_cursor_lock_set(windowId, locked);
    const amcl::input::CursorCapturePublication publication =
        amcl::input::CursorCapturePublicationForResult(locked, result);
    // locked是本次平台操作，不是游戏requested intent。例如最后鼠标拔除时执行
    // unlock而游戏仍处于DISABLED；平台事实必须保留requested=true并发布active=false。
    amcl::input::PlatformInputCapturePlatformChanged(publication.active,
        !locked ? AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST : publication.reason);
    napi_value out = nullptr;
    if (napi_create_int32(env, static_cast<int32_t>(result), &out) != napi_ok) {
        return amcl::napi::MakeUndefined(env);
    }
    return out;
}

// The window manager drops the lock by itself when the window loses focus.
// ArkTS reports that edge so the next lock request is not treated as redundant.
napi_value NoteCursorLockFocusLost(napi_env env, napi_callback_info /*info*/) {
    SurfaceLifecycleLock lifecycleLock;
    amcl_cursor_lock_set_focus(false);
    amcl_cursor_lock_note_focus_lost();
    amcl::input::PlatformInputCapturePlatformChanged(false,
        AMCL_INPUT_CAPTURE_REASON_FOCUS_LOST);
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

/** 触控输出准入与owned文本职责分开。RELEASE允许收口，模态/发布不能清实体或映射手柄。 */
bool TouchSourceAdmission(int32_t source, bool releasing = false) {
    if (source != 1 || releasing) return true;
    const auto state = amcl::input::QueryTouchPublication();
    return state.context.surface != 0 && !state.fenced && state.modalCount == 0 &&
        state.status != amcl::input::TouchPublicationStatus::Stale &&
        state.status != amcl::input::TouchPublicationStatus::Unavailable;
}

// 返回给 ArkTS 的 bool 只回答“本端持有变更是否已生效”：PRESS 已登记、REPEAT 已送出、
// RELEASE 已摘除都返回 true，与别端聚合而没有发出最终边沿也算。false 表示 native 未改变本端
// 记录（端身份非法、surface 门关闭、bridge 未就绪、复位围栏、无配对记录或未知动作），
// 调用方据此保留自身按下态以便重试。判据由 ohos_send_source_key_event_checked 给出。
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
    if (!TouchSourceAdmission(source, action == 0)) return amcl::napi::MakeBoolResult(env, false);
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

// 返回值契约同 SendSourceKeyEvent；鼠标按钮只接受 PRESS / RELEASE，其它动作一律 false。
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
    if (!TouchSourceAdmission(source, action == 0)) return amcl::napi::MakeBoolResult(env, false);
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
    if (!TouchSourceAdmission(source)) return amcl::napi::MakeBoolResult(env, false);
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
/** 冷能力仅证明neutral生产端口存在；Host据此冻结模式，不能当游戏consumer Ready。 */
napi_value SharedLookExecutionSupported(napi_env env,napi_callback_info) {
    return amcl::napi::MakeBoolResult(env,amclMappedLookSupported());
}
/** device/connection用整数身份，Native入口采样owner monotonic；拒绝不更新已有速度事实。 */
napi_value SetMappedLookVelocity(napi_env env,napi_callback_info info) {
    if(!amclLookExecutionGetPortV1())return amcl::napi::MakeBoolResult(env,false);
    size_t argc=4;napi_value args[4]{};double device=0,connection=0,x=0,y=0;
    const bool valid=napi_get_cb_info(env,info,&argc,args,nullptr,nullptr)==napi_ok&&argc==4&&
        napi_get_value_double(env,args[0],&device)==napi_ok&&napi_get_value_double(env,args[1],&connection)==napi_ok&&
        napi_get_value_double(env,args[2],&x)==napi_ok&&napi_get_value_double(env,args[3],&y)==napi_ok&&
        std::isfinite(device)&&device>=0&&device<=4294967295.0&&std::floor(device)==device&&
        std::isfinite(connection)&&connection>0&&connection<=4294967295.0&&std::floor(connection)==connection;
    if(!valid)return amcl::napi::MakeBoolResult(env,false);amcl::input::SurfaceInputGateTransaction gate;
    return amcl::napi::MakeBoolResult(env,gate&&TouchSourceAdmission(2)&&
        amclMappedLookSet(static_cast<uint64_t>(device),static_cast<uint64_t>(connection),x,y));
}
/** timer是源执行维护，不依赖UI反馈订阅；准入失败不补后台dt。 */
napi_value AdvanceMappedLookExecution(napi_env env,napi_callback_info) {
    if(!amclLookExecutionGetPortV1())return amcl::napi::MakeBoolResult(env,false);
    amcl::input::SurfaceInputGateTransaction gate;
    return amcl::napi::MakeBoolResult(env,gate&&TouchSourceAdmission(2)&&amclMappedLookAdvance());
}
/** 停源不要求surface gate；先结束运动流，即使控制release被拒也不留下速率/尾量。 */
napi_value RetireMappedLookConnection(napi_env env,napi_callback_info info) {
    size_t argc=2;napi_value args[2]{};double device=0,connection=0;
    const bool valid=napi_get_cb_info(env,info,&argc,args,nullptr,nullptr)==napi_ok&&argc==2&&
        napi_get_value_double(env,args[0],&device)==napi_ok&&napi_get_value_double(env,args[1],&connection)==napi_ok&&
        std::isfinite(device)&&device>=0&&device<=4294967295.0&&std::floor(device)==device&&
        std::isfinite(connection)&&connection>0&&connection<=4294967295.0&&std::floor(connection)==connection;
    return amcl::napi::MakeBoolResult(env,valid&&amclMappedLookRetire(static_cast<uint64_t>(device),static_cast<uint64_t>(connection)));
}
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
    if (!TouchSourceAdmission(source)) return amcl::napi::MakeBoolResult(env, false);
    if (!gate) {
        if (amcl::input::PlatformInputShadowEnabled()) amcl::input::trace::RecordGateRejected();
        return amcl::napi::MakeBoolResult(env, false);
    }
    return amcl::napi::MakeBoolResult(
        env, ohos_send_source_cursor_delta_checked(source, dx, dy));
}

// 带采样时间的合成运动入口。拒绝非法时钟并沿用来源级单位/准入检查，绝不把ms当ns。
napi_value SendSourceCursorSample(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t source = 0;
    double dx = 0.0, dy = 0.0, timestamp = 0.0;
    if (argc != 4 || !ReadInputSourceArg(env, args[0], &source) ||
        napi_get_value_double(env, args[1], &dx) != napi_ok ||
        napi_get_value_double(env, args[2], &dy) != napi_ok ||
        napi_get_value_double(env, args[3], &timestamp) != napi_ok ||
        !std::isfinite(timestamp) || timestamp < 0.0 || timestamp >= 9223372036854775808.0 ||
        std::floor(timestamp) != timestamp) return amcl::napi::MakeBoolResult(env, false);
    amcl::input::SurfaceInputGateTransaction gate;
    if (!TouchSourceAdmission(source)) return amcl::napi::MakeBoolResult(env, false);
    if (!gate) return amcl::napi::MakeBoolResult(env, false);
    amcl::input::census::Bump(amcl::input::census::Channel::LookFromGamepad);
    return amcl::napi::MakeBoolResult(env,
        ohos_send_source_cursor_sample_checked(source, dx, dy, static_cast<int64_t>(timestamp)));
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
/** 不透明uint64采用十进制文本；拒绝符号、小数、溢出和任意超长分配。0仅供expected旧schema。 */
bool ReadTouchIdentity(napi_env env, napi_value value, uint64_t* out, bool allowZero = false) {
    std::string encoded;
    if (!out || !ReadBoundedUtf8String(env, value, 20, encoded) || encoded.empty()) return false;
    uint64_t parsed = 0;
    for (const char digit : encoded) {
        if (digit < '0' || digit > '9' || parsed > (UINT64_MAX - (digit - '0')) / 10) return false;
        parsed = parsed * 10 + static_cast<uint64_t>(digit - '0');
    }
    if (!allowZero && parsed == 0) return false;
    *out = parsed;
    return true;
}

/** 构造失败返回undefined，Native记录仍可按operation查询；不能回滚已完成的schema/owner事务。 */
napi_value TouchReceiptResult(napi_env env, const amcl::input::TouchPublicationReceipt& receipt) {
    napi_value result = nullptr;
    if (napi_create_object(env, &result) != napi_ok) return amcl::napi::MakeUndefined(env);
    const auto text = [&](const char* name, const std::string& value) {
        napi_value field = nullptr;
        return napi_create_string_utf8(env, value.data(), value.size(), &field) == napi_ok &&
            napi_set_named_property(env, result, name, field) == napi_ok;
    };
    const auto number = [&](const char* name, double value) {
        napi_value field = nullptr;
        return napi_create_double(env, value, &field) == napi_ok && napi_set_named_property(env, result, name, field) == napi_ok;
    };
    napi_value fenced = nullptr;
    if (!number("version", 1) || !text("status", amcl::input::TouchPublicationStatusName(receipt.status)) ||
        !text("surface", std::to_string(receipt.context.surface)) ||
        !text("session", std::to_string(receipt.context.session)) ||
        !text("policy", std::to_string(receipt.context.policy)) ||
        !text("grabEpoch", std::to_string(receipt.context.grabEpoch)) ||
        !text("schemaGeneration", std::to_string(receipt.context.schema)) ||
        !text("groupRevision", std::to_string(receipt.groupRevision)) ||
        !text("token", std::to_string(receipt.token)) || !text("operationId", receipt.operationId) ||
        !text("candidateId", receipt.candidateId) || !number("nativeTouches", receipt.context.nativeTouches) ||
        !number("density", receipt.context.density) || !number("transform", receipt.context.transform) ||
        !number("modalCount", receipt.modalCount) || napi_get_boolean(env, receipt.fenced, &fenced) != napi_ok ||
        napi_set_named_property(env, result, "fenced", fenced) != napi_ok) return amcl::napi::MakeUndefined(env);
    napi_value grabbed = nullptr;
    if (napi_get_boolean(env, receipt.context.grabbed, &grabbed) != napi_ok ||
        napi_set_named_property(env, result, "grabbed", grabbed) != napi_ok) return amcl::napi::MakeUndefined(env);
    return result;
}

/** 查询真实身份与当前操作，供Native安装后回执丢失、页面恢复及迟到回调进行幂等对账。 */
napi_value TouchPublicationState(napi_env env, napi_callback_info) {
    return TouchReceiptResult(env, amcl::input::QueryTouchPublication());
}

/** fence先生效，零触点在Native事务内核实；UI仍须验证自己已认领角色为零。 */
napi_value BeginTouchPublication(napi_env env, napi_callback_info info) {
    size_t argc = 7; napi_value args[7]{};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string operation, candidate;
    amcl::input::TouchPublicationContext expected;
    if (argc != 7 || !ReadBoundedUtf8String(env, args[0], 192, operation) ||
        !ReadBoundedUtf8String(env, args[1], 192, candidate) ||
        !ReadTouchIdentity(env, args[2], &expected.surface) ||
        !ReadTouchIdentity(env, args[3], &expected.session, true) ||
        !ReadTouchIdentity(env, args[4], &expected.policy, true) ||
        !ReadTouchIdentity(env, args[5], &expected.schema, true) ||
        !ReadTouchIdentity(env, args[6], &expected.grabEpoch, true)) {
        auto receipt = amcl::input::QueryTouchPublication();
        receipt.status = amcl::input::TouchPublicationStatus::Invalid;
        return TouchReceiptResult(env, receipt);
    }
    // density/transform也来自当前权威；policy身份仍由调用方带来的expected严格比较。
    const auto current = amcl::input::QueryTouchPublication();
    expected.density = current.context.density; expected.transform = current.context.transform;
    expected.grabbed = current.context.grabbed;
    return TouchReceiptResult(env, amcl::input::BeginTouchPublication(operation, candidate, expected));
}

napi_value ConfirmTouchPublication(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2]{}; std::string operation; uint64_t token = 0;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const bool valid = argc == 2 && ReadBoundedUtf8String(env, args[0], 192, operation) &&
        ReadTouchIdentity(env, args[1], &token);
    return amcl::napi::MakeBoolResult(env, valid && amcl::input::ConfirmTouchPublication(operation, token));
}
napi_value AbortTouchPublication(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1]{}; std::string operation;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc != 1 || !ReadBoundedUtf8String(env, args[0], 192, operation)) operation.clear();
    return TouchReceiptResult(env, amcl::input::AbortTouchPublication(operation));
}

/** modal与publication分开：关闭自己的IME不会撤销别人编辑器或布局完成屏障。 */
napi_value AcquireTouchModal(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1]{}; std::string owner;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const uint64_t token = argc == 1 && ReadBoundedUtf8String(env, args[0], 192, owner)
        ? amcl::input::AcquireTouchModal(owner) : 0;
    return amcl::napi::WrapStringResult(env, token ? std::to_string(token).c_str() : "");
}
napi_value ReleaseTouchModal(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1]{}; uint64_t token = 0;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return amcl::napi::MakeBoolResult(env, argc == 1 && ReadTouchIdentity(env, args[0], &token) &&
        amcl::input::ReleaseTouchModal(token));
}
napi_value IsTouchPublicationCurrent(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1]{}; uint64_t token = 0;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return amcl::napi::MakeBoolResult(env, argc == 1 && ReadTouchIdentity(env, args[0], &token) &&
        amcl::input::AcceptTouchUiPublication(token));
}

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
napi_value GetInputResetDomains(napi_env env, napi_callback_info /*info*/) {
    const auto snapshot = amcl::input::PlatformInputResetDomains();
    char encoded[128] = {};
    std::snprintf(encoded, sizeof(encoded), "IRS1:%llu:%llu:%llu:%llu:%llu",
        static_cast<unsigned long long>(snapshot.epoch),
        static_cast<unsigned long long>(snapshot.touch),
        static_cast<unsigned long long>(snapshot.gamepad),
        static_cast<unsigned long long>(snapshot.physical),
        static_cast<unsigned long long>(snapshot.text));
    return amcl::napi::WrapStringResult(env, encoded);
}

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
//  环境纪律（I27-05）：句柄只含 trampoline 地址（进程常量），由 registerInputNapi 在模块
//  初始化时发布唯一一次；onGrabChange 只在 g_grabMutex 下换 tsfn，绝不碰 environ。
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

// AMCL_GRAB_CB 的唯一写点，只经 registerInputNapi 的 call_once 进入（模块初始化、UI 线程、
// 早于任何游戏/JVM 线程）。不能挪回 onGrabChange：ArkTS 在 mcStarted 之后才注册，那时首次
// 写会新增名字、realloc environ，与游戏线程的启动写入相撞。读者（input_bridge_ohos.c 的
// resolveGrabChangeCb）因此可能在 ArkTS 注册前就解析到地址，这是安全的：tsfn 为空时
// trampoline 什么都不做。setenv 失败只记录，不重试（重试会落到游戏期间）。
void PublishGrabChangeTrampolineOnce() {
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu",
             (unsigned long long)(uintptr_t)&GrabChangeTrampoline);
    if (setenv("AMCL_GRAB_CB", buf, 1) != 0) {
        OH_LOG_ERROR(LOG_APP, "AMCL_GRAB_CB publication failed; grab-change callback stays unavailable");
    }
}
std::once_flag g_grabTrampolinePublished;

// onGrabChange(callback?) —— 注册 grabbed 变化回调；传空 / 非函数 = 注销。
// 只替换 g_grabMutex 保护的 tsfn 句柄；env 句柄已在模块初始化时发布，这里不写环境。
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
    return amcl::napi::MakeUndefined(env);
}

// ============================================================
//  按钮按下态推送（C 层触摸解释器 → ArkTS 更新高亮）
//  C 接管按钮后，键由 C 发；视觉高亮也须由 C 驱动，否则 ArkTS 自己的状态机会与 C 失步
//  （toggle/长按尤甚）。schemaDispatchButton 是所有按钮键事件的唯一出口，在其中推送 (id, pressed)。
// ============================================================
// 反馈的每次注册拥有独立上下文。替换时旧上下文先退休，TSFN最终drain只能读取旧容器，
// 绝不把旧状态或触觉转给最新页面。队列/最终状态容器有界，输入线程只nonblocking入队。
struct ButtonFeedbackContext {
    napi_threadsafe_function tsfn = nullptr;
    bool active = true, wakeQueued = false;
    std::map<std::string, int> pending;
};
struct HapticFeedbackContext {
    napi_threadsafe_function tsfn = nullptr;
    bool active = true;
    uint64_t registration = 0;
};
struct HapticFeedbackEvent {
    int strength = 0;
    // 输入线程载荷使用固定ID缓冲；nothrow new不能防止std::string构造再次抛bad_alloc。
    char controlId[AMCL_CONTROL_ID_MAX_BYTES + 1]{};
    uint64_t schema = 0, session = 0, grabEpoch = 0;
    int64_t generatedNs = 0;
};
ButtonFeedbackContext* g_btnFeedback = nullptr;
HapticFeedbackContext* g_hapticFeedback = nullptr;
std::mutex g_btnPressMutex, g_hapticMutex;
uint64_t g_feedbackRegistration = 0;

int64_t FeedbackNowNs() {
    timespec now{};
    return clock_gettime(CLOCK_MONOTONIC, &now) == 0 ?
        static_cast<int64_t>(now.tv_sec) * 1000000000 + now.tv_nsec : 0;
}
void FinalizeButtonFeedback(napi_env, void* data, void*) {
    auto* context = static_cast<ButtonFeedbackContext*>(data);
    std::lock_guard<std::mutex> lock(g_btnPressMutex);
    if (g_btnFeedback == context) g_btnFeedback = nullptr;
    delete context;
}
void FinalizeHapticFeedback(napi_env, void* data, void*) {
    auto* context = static_cast<HapticFeedbackContext*>(data);
    std::lock_guard<std::mutex> lock(g_hapticMutex);
    if (g_hapticFeedback == context) g_hapticFeedback = nullptr;
    delete context;
}

/** UI卡顿超过250ms丢触觉；旧注册/旧touch会话也丢，不等待输入或补发过期震动。 */
void HapticCallJsImpl(napi_env env, napi_value js_cb, void* rawContext, void* data) {
    std::unique_ptr<HapticFeedbackEvent> event(static_cast<HapticFeedbackEvent*>(data));
    auto* context = static_cast<HapticFeedbackContext*>(rawContext);
    if (!event || !context || !env || !js_cb) return;
    {
        std::lock_guard<std::mutex> lock(g_hapticMutex);
        if (!context->active || g_hapticFeedback != context) return;
    }
    const int64_t now = FeedbackNowNs();
    if (event->generatedNs <= 0 || now < event->generatedNs || now - event->generatedNs > 250000000 ||
        (event->session != 0 && event->session != amcl::input::PlatformInputResetDomains().touch)) return;
    napi_value args[2]{}, metadata = nullptr;
    if (napi_create_int32(env, event->strength, &args[0]) != napi_ok || napi_create_object(env, &metadata) != napi_ok) return;
    const auto text = [&](const char* name, const std::string& value) {
        napi_value field = nullptr;
        return napi_create_string_utf8(env, value.data(), value.size(), &field) == napi_ok &&
            napi_set_named_property(env, metadata, name, field) == napi_ok;
    };
    napi_value version = nullptr;
    if (napi_create_int32(env, 1, &version) != napi_ok || napi_set_named_property(env, metadata, "version", version) != napi_ok ||
        !text("registration", std::to_string(context->registration)) || !text("controlId", event->controlId) ||
        !text("schemaGeneration", std::to_string(event->schema)) || !text("session", std::to_string(event->session)) ||
        !text("grabEpoch", std::to_string(event->grabEpoch)) ||
        !text("generatedNs", std::to_string(event->generatedNs))) return;
    args[1] = metadata;
    napi_value undef = nullptr, result = nullptr;
    if (napi_get_undefined(env, &undef) == napi_ok) napi_call_function(env, undef, js_cb, 2, args, &result);
}
/** JS反馈构造失败只丢副作用；Impl中的unique_ptr在异常展开时仍收回已出队载荷。 */
void HapticCallJs(napi_env env, napi_value js_cb, void* rawContext, void* data) {
    try { HapticCallJsImpl(env, js_cb, rawContext, data); } catch (...) { /* 反馈失败不退出输入会话。 */ }
}

napi_value OnHaptic(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1]{}; napi_valuetype type = napi_undefined;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const bool hasFn = argc == 1 && napi_typeof(env, args[0], &type) == napi_ok && type == napi_function;
    HapticFeedbackContext* previous = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_hapticMutex);
        previous = g_hapticFeedback; g_hapticFeedback = nullptr;
        if (previous) previous->active = false;
    }
    // release在注册锁外，finalize即使同步回调也不会与本锁逆序；旧对象由TSFN最终完成后释放。
    if (previous) napi_release_threadsafe_function(previous->tsfn, napi_tsfn_release);
    if (!hasFn) return amcl::napi::MakeBoolResult(env, true);
    auto* context = new (std::nothrow) HapticFeedbackContext();
    if (!context) return amcl::napi::MakeBoolResult(env, false);
    {
        std::lock_guard<std::mutex> lock(g_hapticMutex);
        // 注册身份耗尽后永久拒绝，失败的create也消耗已分配身份，绝不回绕复用旧lease。
        if (g_feedbackRegistration == UINT64_MAX) {
            delete context; return amcl::napi::MakeBoolResult(env, false);
        }
        context->registration = ++g_feedbackRegistration;
    }
    napi_value name = nullptr;
    if (napi_create_string_utf8(env, "InputHaptic", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_threadsafe_function(env, args[0], nullptr, name, 16, 1, context,
            FinalizeHapticFeedback, context, HapticCallJs, &context->tsfn) != napi_ok) {
        delete context; return amcl::napi::MakeBoolResult(env, false);
    }
    {
        std::lock_guard<std::mutex> lock(g_hapticMutex);
        g_hapticFeedback = context;
    }
    return amcl::napi::MakeBoolResult(env, true);
}

/** wake只取本注册的最终状态；旧drain不会清掉新页面尚未投递的pending RELEASE。 */
void BtnPressCallJsImpl(napi_env env, napi_value js_cb, void* rawContext, void*) {
    auto* context = static_cast<ButtonFeedbackContext*>(rawContext);
    std::map<std::string, int> pending;
    {
        std::lock_guard<std::mutex> lock(g_btnPressMutex);
        if (!context || !context->active || g_btnFeedback != context) return;
        pending.swap(context->pending); context->wakeQueued = false;
    }
    if (!env || !js_cb) return;
    for (const auto& item : pending) {
        napi_value args[2]{}, undef = nullptr, result = nullptr;
        if (napi_create_string_utf8(env, item.first.c_str(), NAPI_AUTO_LENGTH, &args[0]) != napi_ok ||
            napi_get_boolean(env, item.second != 0, &args[1]) != napi_ok || napi_get_undefined(env, &undef) != napi_ok) continue;
        napi_call_function(env, undef, js_cb, 2, args, &result);
    }
}
/** SDK反馈对象失败不能逃逸到TSFN生命周期；当前视觉仍可由后续边沿/只读投影恢复。 */
void BtnPressCallJs(napi_env env, napi_value js_cb, void* rawContext, void* data) {
    try { BtnPressCallJsImpl(env, js_cb, rawContext, data); } catch (...) { /* 仅丢本次视觉通知。 */ }
}
napi_value OnButtonPressed(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1]{}; napi_valuetype type = napi_undefined;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const bool hasFn = argc == 1 && napi_typeof(env, args[0], &type) == napi_ok && type == napi_function;
    ButtonFeedbackContext* previous = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_btnPressMutex);
        previous = g_btnFeedback; g_btnFeedback = nullptr;
        if (previous) { previous->active = false; previous->pending.clear(); }
    }
    if (previous) napi_release_threadsafe_function(previous->tsfn, napi_tsfn_release);
    if (!hasFn) return amcl::napi::MakeBoolResult(env, true);
    auto* context = new (std::nothrow) ButtonFeedbackContext();
    if (!context) return amcl::napi::MakeBoolResult(env, false);
    napi_value name = nullptr;
    if (napi_create_string_utf8(env, "ButtonPressed", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_threadsafe_function(env, args[0], nullptr, name, 1, 1, context,
            FinalizeButtonFeedback, context, BtnPressCallJs, &context->tsfn) != napi_ok) {
        delete context; return amcl::napi::MakeBoolResult(env, false);
    }
    { std::lock_guard<std::mutex> lock(g_btnPressMutex); g_btnFeedback = context; }
    return amcl::napi::MakeBoolResult(env, true);
}


// ⚠️ `registerButton` / `registerJoystick` / `clearButtons` / `clearJoystick` 四个入口
// 已删除。它们把矩形表填进 C 层，而那张表的唯一读取方位于一个永不执行的分支里 ——
// ArkTS 每次布局重建都在跨语言填一张没人读的表。触控虚拟按键端的权威表述是
// `setControlSchema`（含 hit-test、hitSlop、handledBy、四种 trigger）。

// 四项参数以一笔事务应用。参数缺失/类型错误/范围错误都返回false，调用方保留待应用版本重试。
napi_value ApplyLookConfiguration(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4]{};
    double sensitivity = 0, smoothing = 0, acceleration = 0;
    bool invertY = false;
    const bool valid = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) == napi_ok && argc == 4 &&
        napi_get_value_double(env, args[0], &sensitivity) == napi_ok &&
        napi_get_value_bool(env, args[1], &invertY) == napi_ok &&
        napi_get_value_double(env, args[2], &smoothing) == napi_ok &&
        napi_get_value_double(env, args[3], &acceleration) == napi_ok;
    return amcl::napi::MakeBoolResult(env, valid && amcl_apply_source_look_configuration(
        -1, sensitivity, invertY, smoothing, acceleration));
}

/**
 * 显式独立来源政策边界。source采用真实platform枚举：0未标记兼容、1触控、2映射手柄、
 * 3物理键鼠；4平台手势没有look政策，不允许被UI序号误选。四参数先一起验证，唯一
 * neutral owner再原子应用到这一来源；已加工尾量仍在原输出单位，不反向重新缩放。
 * false表示本域未确认应用，不能通过逐个void setter或偷偷全来源调用掩盖失败。
 */
napi_value ApplySourceLookConfiguration(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5]{};
    int32_t source = -1;
    double sensitivity = 0, smoothing = 0, acceleration = 0;
    bool invertY = false;
    double sourceNumber = -1;
    const bool valid = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) == napi_ok && argc == 5 &&
        napi_get_value_double(env, args[0], &sourceNumber) == napi_ok && std::isfinite(sourceNumber) &&
        sourceNumber >= 0 && sourceNumber <= 3 && std::floor(sourceNumber) == sourceNumber &&
        napi_get_value_double(env, args[1], &sensitivity) == napi_ok &&
        napi_get_value_bool(env, args[2], &invertY) == napi_ok &&
        napi_get_value_double(env, args[3], &smoothing) == napi_ok &&
        napi_get_value_double(env, args[4], &acceleration) == napi_ok;
    if (valid) source = static_cast<int32_t>(sourceNumber);
    return amcl::napi::MakeBoolResult(env, valid && amcl_apply_source_look_configuration(
        source, sensitivity, invertY, smoothing, acceleration));
}

// --- 视角灵敏度 / Y 轴倒置（旧单项接口保留，现役配置使用上面的原子事务） ---
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

/** 解析 v3 的完整交互配置；必须逐字段成功，不能把拼错/缺失参数当作 false。 */
static bool ReadTouchSchemaOptions(napi_env env, napi_value root, amcl::input::TouchInteractionConfig* out) {
    napi_value item;
    if (!out || !NamedValue(env, root, "touch", &item)) return false;
    auto& c = *out;
    if (!NamedInt(env,item,"version",&c.version) || !NamedBool(env,item,"touchpad",&c.touchpad) ||
        !NamedDouble(env,item,"menuSensitivity",&c.menuSensitivity) || !NamedBool(env,item,"menuScroll",&c.menuScroll) ||
        !NamedInt(env,item,"menuHoldMs",&c.menuHoldMs) || !NamedBool(env,item,"floatingJoystick",&c.floatingJoystick) ||
        !NamedBool(env,item,"sprint",&c.sprint) || !NamedBool(env,item,"autoWalk",&c.autoWalk) ||
        !NamedDouble(env,item,"sprintThreshold",&c.sprintThreshold) || !NamedBool(env,item,"hotbarSwap",&c.hotbarSwap) ||
        !NamedBool(env,item,"hotbarDrop",&c.hotbarDrop) || !NamedInt(env,item,"holdMs",&c.holdMs) ||
        !NamedInt(env,item,"gestureMode",&c.gestureMode)) return false;
    napi_value keys;
    bool array = false;
    uint32_t count = 0;
    if (!NamedValue(env,item,"actions",&keys) || napi_is_array(env,keys,&array) != napi_ok || !array ||
        napi_get_array_length(env,keys,&count) != napi_ok || count != amcl::input::TouchActionCount) return false;
    for (uint32_t i=0;i<count;++i) {
        napi_value value;
        if (napi_get_element(env,keys,i,&value) != napi_ok || !StrictInt(env,value,&c.actions[i])) return false;
    }
    return amcl::input::ValidTouchInteractionConfig(c);
}

/** 会话及来源维护显式调用；不创建引用/线程，不由观察者读取快照隐式触发生产副作用。 */
static napi_value MaintainTouchInput(napi_env env, napi_callback_info) {
    const bool maintained=ohos_touch_input_maintain();
#if AMCL_INPUT_TRACE
    // 必要维护已经返回且输入锁释放。沿原Host时钟至多7条记录+1条汇总、总4096字节，
    // 每条512字节先完整格式化再打印（低于HiLog官方4096字节单条上限），绝不发截断身份。
    // 所有格式化/IO都在非输入热路径；读失败/格式或日志异常只丢诊断，不改maintained。
    try {
        AmclInputLatencyV1 records[7]{};AmclInputLatencyStatsV1 stats{};
        const uint32_t count=inputBridge_drainInputLatencyV1(records,7,&stats);
        uint32_t bytes=0,failed=0;
        for(uint32_t i=0;i<count;++i){char text[512]{};const uint32_t length=inputBridge_formatInputLatencyV1(&records[i],text,sizeof(text));
            if(!length||length>=512||bytes+length+1>3584){++failed;continue;}
            // OH_LOG_INFO宏返回void，错误检测必须用原int接口；保原domain/tag与product_hilog策略。
            if(OH_LOG_Print(LOG_APP,LOG_INFO,LOG_DOMAIN,LOG_TAG,"%{public}s",text)<0)++failed;bytes+=length+1;}
        // 只因真实丢诊断计数变化补summary，避免全busy时永远无row而隐去缺口。
        // 空稳态不读新钟/不打印；原子仅保护多个NAPI调用者的观察状态，冗余summary不控制输入。
        static std::atomic<uint64_t> lastFull{0},lastBusy{0},lastMissing{0},lastClockFailures{0};
        static std::atomic<uint32_t> lastUncertain{0};bool dropsChanged=false;
        if(stats.capacity){dropsChanged|=lastFull.exchange(stats.full)!=stats.full;
            dropsChanged|=lastBusy.exchange(stats.busy)!=stats.busy;dropsChanged|=lastMissing.exchange(stats.missing)!=stats.missing;
            dropsChanged|=lastClockFailures.exchange(stats.clockFailures)!=stats.clockFailures;
            dropsChanged|=lastUncertain.exchange(stats.counterUncertain)!=stats.counterUncertain;}
        if(stats.capacity&&(count||failed||dropsChanged)){
            OH_LOG_INFO(LOG_APP,"ILAT1_SUM n=%{public}u bytes=%{public}u exportfail=%{public}u sampled=%{public}llu skipped=%{public}llu full=%{public}llu busy=%{public}llu unbound=%{public}llu clockfail=%{public}llu count_uncertain=%{public}u record_bytes=%{public}u capacity=%{public}u",
                count,bytes,failed,(unsigned long long)stats.sampled,(unsigned long long)stats.skipped,
                (unsigned long long)stats.full,(unsigned long long)stats.busy,(unsigned long long)stats.missing,
                (unsigned long long)stats.clockFailures,stats.counterUncertain,stats.recordBytes,stats.capacity);
        }
    }catch(...){} // 仅诊断异常；原维护结果在所有路径保持，不能牵连输入/停止。
#endif
    return amcl::napi::MakeBoolResult(env, maintained);
}

/** UI严格只读接受态视觉投影，仅读取不改变grab、持有、消费者游标或来源资格。 */
static napi_value TouchInteractionVisual(napi_env env, napi_callback_info) {
    double values[25]{};
    ohos_touch_interaction_visual(values,25);
    napi_value result;
    napi_create_array_with_length(env,25,&result);
    for (uint32_t i=0;i<25;++i) {
        napi_value value;
        napi_create_double(env,values[i],&value);
        napi_set_element(env,result,i,value);
    }
    return result;
}

/** 移动菜单虚拟鼠标，绝不把面板位移发送为游戏内视角。 */
static napi_value MoveTouchMenuPointer(napi_env env,napi_callback_info info) {
    size_t argc=4; napi_value args[4]{}; uint64_t token=0; double dx=0,dy=0; std::string prefix;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if(argc!=4 || !ReadBoundedUtf8String(env,args[3],192,prefix) || prefix.empty() || prefix.find('\0')!=std::string::npos ||
       !ReadTouchIdentity(env,args[2],&token) || napi_get_value_double(env,args[0],&dx)!=napi_ok ||
       napi_get_value_double(env,args[1],&dy)!=napi_ok) return amcl::napi::MakeBoolResult(env,false);
    amcl::input::SurfaceInputGateTransaction gate;
    amcl::input::AuthoritativeGrabInputTransaction mode(static_cast<bool>(gate));
    // 已确认旧UI的MOVE继续采用原token；新layout等待抬手的fence不应取消/吞掉这条已有输送。
    return amcl::napi::MakeBoolResult(env,gate && mode && !mode.grabbed() && amcl::input::AcceptTouchUiContinuation(token) && ohos_move_touch_menu_pointer(dx,dy,prefix.c_str(),token));
}

/** 临时覆盖层共用参数/归属校验；包括清除在内只允许当前token，不复位任何输入域。 */
static napi_value SetTouchOverlayBounds(napi_env env,napi_callback_info info,
                                       bool (*setter)(double,double,double,double)) {
    size_t argc=5; napi_value args[5]{}; double rect[4]{}; uint64_t token=0;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if(argc!=5 || !ReadTouchIdentity(env,args[4],&token)) return amcl::napi::MakeBoolResult(env,false);
    for(size_t i=0;i<4;i++) if(napi_get_value_double(env,args[i],&rect[i])!=napi_ok) return amcl::napi::MakeBoolResult(env,false);
    amcl::input::SurfaceInputGateTransaction gate;
    return amcl::napi::MakeBoolResult(env,gate && amcl::input::OwnsTouchUiPublicationToken(token) &&
        setter(rect[0],rect[1],rect[2],rect[3]));
}
/** 鼠标本体仅在菜单阻止新触点穿透，旧按住事件仍由自己的owner完成。 */
static napi_value SetTouchMenuMouseBounds(napi_env env,napi_callback_info info) {
    size_t argc=6; napi_value args[6]{}; double rect[4]{}; uint64_t token=0; std::string prefix;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    // 旧五参只保留几何接口；生产六参同时登记实际Entry实例。无prefix不能取得工具输出许可。
    if(argc==5) return SetTouchOverlayBounds(env,info,ohos_set_menu_mouse_bounds);
    if(argc!=6 || !ReadTouchIdentity(env,args[4],&token) || !ReadBoundedUtf8String(env,args[5],192,prefix) ||
       prefix.empty() || prefix.find('\0')!=std::string::npos) return amcl::napi::MakeBoolResult(env,false);
    for(size_t i=0;i<4;++i) if(napi_get_value_double(env,args[i],&rect[i])!=napi_ok) return amcl::napi::MakeBoolResult(env,false);
    amcl::input::SurfaceInputGateTransaction gate;
    return amcl::napi::MakeBoolResult(env,gate && amcl::input::OwnsTouchUiPublicationToken(token) &&
        ohos_set_menu_mouse_bounds_for_panel(rect[0],rect[1],rect[2],rect[3],prefix.c_str(),token));
}
/** 教学工具栏同时覆盖世界和菜单，但不能把显示状态当成游戏配置换代。 */
static napi_value SetTouchGuideBounds(napi_env env,napi_callback_info info) {
    return SetTouchOverlayBounds(env,info,ohos_set_touch_guide_bounds);
}

/** 菜单面板的左右键/Shift按端持有；释放始终允许，按下必须核实真实菜单状态。 */
static napi_value TouchMenuButton(napi_env env,napi_callback_info info) {
    size_t argc=4; napi_value args[4]{}; uint64_t token=0; std::string id; int32_t code=0; bool down=false;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if((argc!=3 && argc!=4) || !ReadBoundedUtf8String(env,args[0],192,id) || id.empty() || id.find('\0')!=std::string::npos ||
       napi_get_value_int32(env,args[1],&code)!=napi_ok || napi_get_value_bool(env,args[2],&down)!=napi_ok)
        return amcl::napi::MakeBoolResult(env,false);
    if(!down) return amcl::napi::MakeBoolResult(env,ohos_touch_menu_button(id.c_str(),code,false,0));
    if(argc!=4 || !ReadTouchIdentity(env,args[3],&token)) return amcl::napi::MakeBoolResult(env,false);
    amcl::input::SurfaceInputGateTransaction gate;
    amcl::input::AuthoritativeGrabInputTransaction mode(static_cast<bool>(gate));
    return amcl::napi::MakeBoolResult(env,gate && mode && !mode.grabbed() && amcl::input::AcceptTouchUiPublication(token) && ohos_touch_menu_button(id.c_str(),code,true,token));
}
/** 面板取消独立于publication准入；Native精确退休tool来源，不能以正常UP回放旧点击或清其他域。 */
static napi_value CancelTouchMenuMouse(napi_env env,napi_callback_info info) {
    size_t argc=1; napi_value args[1]{}; std::string prefix;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if(argc!=1 || !ReadBoundedUtf8String(env,args[0],192,prefix) || prefix.empty() || prefix.find('\0')!=std::string::npos)
        return amcl::napi::MakeBoolResult(env,false);
    // 取消允许旧publication失效，但必须携带实际面板实例；不能把旧onDisappear
    // 变成当前新panel的全域取消。Native在同一事务复核prefix认领并返回明确接受态。
    return amcl::napi::MakeBoolResult(env,ohos_cancel_touch_menu_mouse(prefix.c_str()));
}
/** 滚轮只准入菜单作用域；步进受限，不能由迟到的JS回调切换游戏内物品。 */
static napi_value TouchMenuScroll(napi_env env,napi_callback_info info) {
    size_t argc=3; napi_value args[3]{}; int32_t steps=0; uint64_t token=0; std::string prefix;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if(argc!=3 || !ReadBoundedUtf8String(env,args[2],192,prefix) || prefix.empty() || prefix.find('\0')!=std::string::npos ||
       !ReadTouchIdentity(env,args[1],&token) || napi_get_value_int32(env,args[0],&steps)!=napi_ok) return amcl::napi::MakeBoolResult(env,false);
    amcl::input::SurfaceInputGateTransaction gate;
    amcl::input::AuthoritativeGrabInputTransaction mode(static_cast<bool>(gate));
    // 与MOVE同一confirmed-token继续资格；NEW DOWN及新注册仍使用各自原有的严格资格。
    return amcl::napi::MakeBoolResult(env,gate && mode && !mode.grabbed() && amcl::input::AcceptTouchUiContinuation(token) && ohos_touch_menu_scroll(steps,prefix.c_str(),token));
}

/** 私有scope/source均为无回绕uint32，不允许小数截断、负数或不精确身份。 */
static bool GuiLeaseArgument(napi_env env,napi_value value,uint32_t& out,bool allowEmpty=false) {
    double raw=0;if(napi_get_value_double(env,value,&raw)!=napi_ok || !std::isfinite(raw) || raw<(allowEmpty?0:1) || raw>UINT32_MAX || std::floor(raw)!=raw)return false;
    out=static_cast<uint32_t>(raw);return true;
}
/** 公共旧入口与具名来源入口共用解析/数组出口，区别只有原lease；两者均不执行JNI。 */
static napi_value ReadGameGuiState(napi_env env,napi_callback_info info,bool scoped) {
    size_t argc=5; napi_value args[5]{};
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    int32_t w=0,h=0; double values[AMCL_GAME_GUI_VALUE_COUNT]{}; char version[128]{}; size_t length=0;
    const size_t offset=scoped?1:0;uint32_t source=0;bool guide=false;
    if(argc==offset+4 && napi_get_value_bool(env,args[offset+3],&guide)!=napi_ok) guide=false;
    if((argc==offset+3 || argc==offset+4) && (!scoped || GuiLeaseArgument(env,args[0],source,true)) &&
       napi_get_value_int32(env,args[offset],&w)==napi_ok && napi_get_value_int32(env,args[offset+1],&h)==napi_ok &&
       napi_get_value_string_utf8(env,args[offset+2],version,sizeof(version),&length)==napi_ok && length>0 && length<97 && w>0 && h>0) {
        if(scoped)amcl_read_game_gui_for_source(source,w,h,version,values,guide);
        else amcl_read_game_gui(w,h,version,values,guide);
    }
    napi_value result; napi_create_array_with_length(env,AMCL_GAME_GUI_VALUE_COUNT,&result);
    for(uint32_t i=0;i<AMCL_GAME_GUI_VALUE_COUNT;i++) { napi_value value; napi_create_double(env,values[i],&value); napi_set_element(env,result,i,value); }
    return result;
}
static napi_value GameGuiState(napi_env env,napi_callback_info info){return ReadGameGuiState(env,info,false);}
static napi_value GameGuiStateForSource(napi_env env,napi_callback_info info){return ReadGameGuiState(env,info,true);}

/** 本局scope仅由宿主显式建立/结束；source只能向构造时捕获的原scope申请。 */
static napi_value GameGuiStartSession(napi_env env,napi_callback_info info) {
    size_t argc=1;napi_value args[1]{};napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    double activity=0;uint32_t scope=0;
    if(argc==1 && napi_get_value_double(env,args[0],&activity)==napi_ok && std::isfinite(activity) && activity>=1 && activity<=9007199254740991.0 && std::floor(activity)==activity)
        scope=amcl_game_gui_start_session(static_cast<uint64_t>(activity));
    napi_value out;napi_create_uint32(env,scope,&out);return out;
}
static napi_value GameGuiCaptureSession(napi_env env,napi_callback_info){napi_value out;napi_create_uint32(env,amcl_game_gui_capture_session(),&out);return out;}
static napi_value GameGuiStopSession(napi_env env,napi_callback_info info) {
    size_t argc=1;napi_value args[1]{};uint32_t scope=0;napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    return amcl::napi::MakeBoolResult(env,argc==1 && GuiLeaseArgument(env,args[0],scope) && amcl_game_gui_stop_session(scope));
}
static napi_value GameGuiAttachSource(napi_env env,napi_callback_info info) {
    size_t argc=1;napi_value args[1]{};uint32_t scope=0,source=0;napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if(argc==1 && GuiLeaseArgument(env,args[0],scope))source=amcl_game_gui_attach_source(scope);
    napi_value out;napi_create_uint32(env,source,&out);return out;
}
static napi_value GameGuiRetireSource(napi_env env,napi_callback_info info) {
    size_t argc=1;napi_value args[1]{};uint32_t source=0;napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    return amcl::napi::MakeBoolResult(env,argc==1 && GuiLeaseArgument(env,args[0],source) && amcl_game_gui_retire_source(source));
}

/** 只接受菜单态、有效surface及精确代次；实际写入还在Java游戏线程重新核对页面与原值。 */
static napi_value RequestGameGuiRestore(napi_env env,napi_callback_info info,bool scoped) {
    size_t argc=3; napi_value args[3]{};
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    const size_t offset=scoped?1:0;uint32_t source=0;int32_t scale=-1; double revision=0; uint64_t request=0;
    if(argc==offset+2 && (!scoped || GuiLeaseArgument(env,args[0],source)) && napi_get_value_int32(env,args[offset],&scale)==napi_ok &&
       napi_get_value_double(env,args[offset+1],&revision)==napi_ok && std::isfinite(revision) &&
       revision>=1 && revision<=9007199254740991.0 && std::floor(revision)==revision) {
        bool allowed=false;
        { amcl::input::SurfaceInputGateTransaction gate;
          amcl::input::AuthoritativeGrabInputTransaction mode(static_cast<bool>(gate));
          allowed=gate && mode && !mode.grabbed(); }
        if(allowed)request=scoped?amcl_restore_game_gui_for_source(source,scale,static_cast<uint64_t>(revision)):amcl_restore_game_gui(scale,static_cast<uint64_t>(revision));
    }
    napi_value result; napi_create_double(env,static_cast<double>(request),&result); return result;
}
static napi_value RestoreGameGuiScale(napi_env env,napi_callback_info info){return RequestGameGuiRestore(env,info,false);}
static napi_value RestoreGameGuiScaleForSource(napi_env env,napi_callback_info info){return RequestGameGuiRestore(env,info,true);}

/** 传感器位移仅在真实游戏抓取事务内投递，不能绕过当前surface/产品/代次限制。 */
static napi_value SendTouchGyroSample(napi_env env,napi_callback_info info) {
    size_t argc=4; napi_value args[4]{};
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    double dx=0,dy=0,timeNs=0,generation=0;
    if (argc!=4 || napi_get_value_double(env,args[0],&dx)!=napi_ok ||
        napi_get_value_double(env,args[1],&dy)!=napi_ok || napi_get_value_double(env,args[2],&timeNs)!=napi_ok ||
        napi_get_value_double(env,args[3],&generation)!=napi_ok || !std::isfinite(timeNs) || timeNs<=0 ||
        timeNs>=9223372036854775808.0 || std::floor(timeNs)!=timeNs || !std::isfinite(generation) ||
        generation<1 || generation>9007199254740991.0 || std::floor(generation)!=generation)
        return amcl::napi::MakeBoolResult(env,false);
    amcl::input::SurfaceInputGateTransaction gate;
    amcl::input::AuthoritativeGrabInputTransaction mode(static_cast<bool>(gate));
    if (!gate || !mode || !mode.grabbed()) return amcl::napi::MakeBoolResult(env,false);
    return amcl::napi::MakeBoolResult(env,ohos_send_touch_gyro_sample_checked(dx,dy,
        static_cast<int64_t>(timeNs),static_cast<uint64_t>(generation)));
}
/** gyro lease能力是四个primitive函数整体合同，生产Entry缺项明确unavailable，不降回无lease。 */
static napi_value TouchGyroLeaseContext(napi_env env,napi_callback_info){
    if(!amclLookExecutionGetPortV1())return amcl::napi::WrapStringResult(env,"");
    amcl::input::SurfaceInputGateTransaction gate;amcl::input::AuthoritativeGrabInputTransaction mode(static_cast<bool>(gate));
    const std::string value=gate&&mode&&mode.grabbed()?ohos_touch_gyro_lease_context():std::string{};
    return amcl::napi::WrapStringResult(env,value.c_str());
}
static napi_value BeginTouchGyroLease(napi_env env,napi_callback_info info){
    if(!amclLookExecutionGetPortV1())return amcl::napi::WrapStringResult(env,"");
    size_t argc=1;napi_value args[1]{};double schema=0;
    if(napi_get_cb_info(env,info,&argc,args,nullptr,nullptr)!=napi_ok||argc!=1||napi_get_value_double(env,args[0],&schema)!=napi_ok||
        !std::isfinite(schema)||schema<1||schema>9007199254740991.0||std::floor(schema)!=schema)return amcl::napi::WrapStringResult(env,"");
    amcl::input::SurfaceInputGateTransaction gate;amcl::input::AuthoritativeGrabInputTransaction mode(static_cast<bool>(gate));
    const std::string value=gate&&mode&&mode.grabbed()?ohos_begin_touch_gyro_lease(static_cast<uint64_t>(schema)):std::string{};
    return amcl::napi::WrapStringResult(env,value.c_str());
}
static napi_value SubmitTouchGyroLease(napi_env env,napi_callback_info info){
    if(!amclLookExecutionGetPortV1())return amcl::napi::MakeBoolResult(env,false);
    size_t argc=4;napi_value args[4]{};char token[65]{};size_t length=0;double x=0,y=0,ns=0;
    if(napi_get_cb_info(env,info,&argc,args,nullptr,nullptr)!=napi_ok||argc!=4||
        napi_get_value_string_utf8(env,args[0],token,sizeof(token),&length)!=napi_ok||!length||length>=sizeof(token)||std::strlen(token)!=length||
        napi_get_value_double(env,args[1],&x)!=napi_ok||napi_get_value_double(env,args[2],&y)!=napi_ok||
        napi_get_value_double(env,args[3],&ns)!=napi_ok||!std::isfinite(ns)||ns<=0||ns>=9223372036854775808.0||std::floor(ns)!=ns)
        return amcl::napi::MakeBoolResult(env,false);
    amcl::input::SurfaceInputGateTransaction gate;amcl::input::AuthoritativeGrabInputTransaction mode(static_cast<bool>(gate));
    return amcl::napi::MakeBoolResult(env,gate&&mode&&mode.grabbed()&&ohos_submit_touch_gyro_lease(token,x,y,static_cast<int64_t>(ns)));
}
static napi_value RetireTouchGyroLease(napi_env env,napi_callback_info info){
    size_t argc=1;napi_value args[1]{};char token[65]{};size_t length=0;
    const bool valid=napi_get_cb_info(env,info,&argc,args,nullptr,nullptr)==napi_ok&&argc==1&&
        napi_get_value_string_utf8(env,args[0],token,sizeof(token),&length)==napi_ok&&length>0&&length<sizeof(token)&&std::strlen(token)==length;
    return amcl::napi::MakeBoolResult(env,valid&&ohos_retire_touch_gyro_lease(token));
}

#include "napi_touch_groups.inc"

napi_value SetControlSchemaImpl(napi_env env, napi_callback_info info, bool publication) {
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto reject = [&](const char* reason) -> napi_value {
        if (!publication) return RejectSchema(env, reason);
        OH_LOG_WARN(LOG_APP, "Touch publication invalid: %{public}s", reason);
        auto receipt = amcl::input::QueryTouchPublication();
        receipt.status = amcl::input::TouchPublicationStatus::Invalid;
        return TouchReceiptResult(env, receipt);
    };
    std::string operation;
    if (argc != (publication ? 2u : 1u) || (publication &&
        (!ReadBoundedUtf8String(env, args[1], 192, operation) || operation.empty()))) return reject("missing-message");

    napi_valuetype rootType;
    if (napi_typeof(env, args[0], &rootType) != napi_ok || rootType != napi_object)
        return reject("message-type");

    int32_t schemaVersion = 0;
    double compW = 0.0, compH = 0.0, deadZone = 0.0;
    bool grabbed = false;
    if (!NamedInt(env, args[0], "schemaVersion", &schemaVersion) ||
        (schemaVersion != 2 && schemaVersion != AMCL_CONTROL_SCHEMA_VERSION && !(publication && schemaVersion == 4))) return reject("unsupported-version");
    amcl::input::TouchInteractionConfig touchConfig;
    if (schemaVersion >= 3 && !ReadTouchSchemaOptions(env,args[0],&touchConfig))
        // 旧入口返回数值0；publication必须返回同操作的invalid回执，不能让JS误判结果未知并反复重试。
        return reject("touch-options");
    if (!NamedDouble(env, args[0], "compWidth", &compW) ||
        !NamedDouble(env, args[0], "compHeight", &compH) ||
        compW <= 0.0 || compH <= 0.0 || compW > 65536.0 || compH > 65536.0)
        return reject("component-size");
    if (!NamedBool(env, args[0], "grabbed", &grabbed)) return reject("grabbed");
    if (!NamedDouble(env, args[0], "deadZone", &deadZone) || deadZone <= 0.0 || deadZone >= 1.0)
        return reject("dead-zone");

    napi_value controlsValue;
    bool isControlsArray = false;
    if (!NamedValue(env, args[0], "controls", &controlsValue) ||
        napi_is_array(env, controlsValue, &isControlsArray) != napi_ok || !isControlsArray)
        return reject("controls-type");
    uint32_t count = 0;
    if (napi_get_array_length(env, controlsValue, &count) != napi_ok ||
        count > (schemaVersion == 2 ? 256u : AMCL_CONTROL_SCHEMA_MAX_CONTROLS)) return reject("control-count");

    std::vector<AmclCtrlEntry> entries;
    std::set<std::string> ids;
    entries.reserve(count);
    for (uint32_t i = 0; i < count; i++) {
        napi_value item;
        napi_valuetype itemType;
        if (napi_get_element(env, controlsValue, i, &item) != napi_ok ||
            napi_typeof(env, item, &itemType) != napi_ok || itemType != napi_object)
            return reject("control-type");

        AmclCtrlEntry entry{};
        napi_value idValue;
        napi_valuetype idType;
        size_t idBytes = 0;
        if (!NamedValue(env, item, "id", &idValue) || napi_typeof(env, idValue, &idType) != napi_ok ||
            idType != napi_string || napi_get_value_string_utf8(env, idValue, nullptr, 0, &idBytes) != napi_ok ||
            idBytes == 0 || idBytes > AMCL_CONTROL_ID_MAX_BYTES)
            return reject("id-length");
        size_t copied = 0;
        if (napi_get_value_string_utf8(env, idValue, entry.id, sizeof(entry.id), &copied) != napi_ok ||
            copied != idBytes || !ids.insert(std::string(entry.id, copied)).second)
            return reject("duplicate-or-invalid-id");

        if (!NamedInt(env, item, "kind", &entry.kind) || entry.kind < 0 || entry.kind > 4)
            return reject("kind");
        if (!NamedInt(env, item, "handledBy", &entry.handledBy) ||
            (entry.handledBy != 0 && entry.handledBy != 1)) return reject("handled-by");
        if (!NamedInt(env, item, "trigger", &entry.trigger) || entry.trigger < 0 || entry.trigger > 3)
            return reject("trigger");
        if (!NamedInt(env, item, "keyOrMouse", &entry.keyOrMouse)) return reject("key");

        double x = 0.0, y = 0.0, w = 0.0, h = 0.0, hitSlop = 0.0;
        if (!NamedDouble(env, item, "x", &x) || !NamedDouble(env, item, "y", &y) ||
            !NamedDouble(env, item, "w", &w) || !NamedDouble(env, item, "h", &h) ||
            !NamedDouble(env, item, "hitSlop", &hitSlop) || x < -1.0 || y < -1.0 ||
            w <= 0.0 || h <= 0.0 || x + w > compW + 1.0 || y + h > compH + 1.0 ||
            hitSlop < 0.0 || hitSlop > 256.0) return reject("rect");
        entry.x = static_cast<float>(x); entry.y = static_cast<float>(y);
        entry.w = static_cast<float>(w); entry.h = static_cast<float>(h);
        entry.hitSlop = static_cast<float>(hitSlop);

        bool dragLook = false, haptic = false;
        if (!NamedBool(env, item, "dragLook", &dragLook) || !NamedBool(env, item, "haptic", &haptic))
            return reject("boolean-field");
        entry.dragLook = dragLook ? 1 : 0;
        entry.haptic = haptic ? 1 : 0;
        // v2 无滑动组；v3 缺省 0 用于系统/抽屉等不可接力控件。
        napi_value swipeValue;
        if (schemaVersion >= 3 && NamedValue(env,item,"swipeGroup",&swipeValue) &&
            // 两种接口共用解析，但错误出口由reject选择数值或结构化协议；解析失败不安装表、不解发布屏障。
            !StrictInt(env,swipeValue,&entry.swipeGroup)) return reject("swipe-group");

        napi_value keysValue;
        bool isKeysArray = false;
        uint32_t keyCount = 0;
        if (!NamedValue(env, item, "keys", &keysValue) ||
            napi_is_array(env, keysValue, &isKeysArray) != napi_ok || !isKeysArray ||
            napi_get_array_length(env, keysValue, &keyCount) != napi_ok ||
            keyCount > AMCL_CONTROL_MAX_KEYS) return reject("keys");
        entry.keyCount = static_cast<int>(keyCount);
        for (uint32_t k = 0; k < keyCount; k++) {
            napi_value keyValue;
            if (napi_get_element(env, keysValue, k, &keyValue) != napi_ok ||
                !StrictInt(env, keyValue, &entry.keys[k])) return reject("key-value");
        }
        entries.push_back(entry);
    }

    amcl::input::TouchGroupSchema groupSchema;
    if (schemaVersion == 4 && !ReadGroupSchema(env,args[0],count,groupSchema)) return reject("group-schema");
    if (publication) {
        double density = 0; int32_t transform = -1;
        const auto current = amcl::input::QueryTouchPublication();
        if (!NamedDouble(env, args[0], "contextDensity", &density) ||
            !NamedInt(env, args[0], "contextTransform", &transform) ||
            density != current.context.density || transform < 0 ||
            static_cast<uint32_t>(transform) != current.context.transform) return reject("context-policy");
        return TouchReceiptResult(env, amcl::input::PublishTouchSchema(operation,
            entries.empty() ? nullptr : entries.data(), static_cast<int>(entries.size()),
            static_cast<float>(compW), static_cast<float>(compH), grabbed ? 1 : 0,
            static_cast<float>(deadZone), schemaVersion, &touchConfig, schemaVersion == 4 ? &groupSchema : nullptr));
    }
    const uint64_t generation = ohos_set_control_schema_v3(
        entries.empty() ? nullptr : entries.data(), static_cast<int>(entries.size()),
        static_cast<float>(compW), static_cast<float>(compH), grabbed ? 1 : 0,
        static_cast<float>(deadZone), schemaVersion, &touchConfig);
    return SchemaResult(env, generation);
}

/** 数值v2/v3旧入口保留；触控发布扩展显式使用独立API和v1身份回执。 */
napi_value SetControlSchema(napi_env env, napi_callback_info info) { return SetControlSchemaImpl(env, info, false); }
napi_value PublishTouchSchema(napi_env env, napi_callback_info info) {
    try { return SetControlSchemaImpl(env, info, true); }
    catch (...) {
        // Native可能已完成安装而回执复制失败。保留操作记录/fence，JS以同operation查询恢复，
        // 绝不在异常分支换空表或推断旧schema仍在；固定文本不把布局/键值写入日志。
        OH_LOG_ERROR(LOG_APP, "Touch publication outcome unknown; query retained operation");
        return amcl::napi::MakeUndefined(env);
    }
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

// 控件租约 NAPI：限制身份/组合键长度并拒绝小数、NaN、NUL，所有校验完成后才进入
// surface gate。token 用十进制字符串传输，避免 JS number 截断 64 位身份。
napi_value AcquireSourceControl(napi_env env, napi_callback_info info) {
    size_t argc = 7;
    napi_value args[7] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t source = 0;
    double device = 0.0;
    std::string control;
    bool array = false;
    uint32_t count = 0u;
    if ((argc != 4 && argc != 5 && argc != 7) || !ReadInputSourceArg(env, args[0], &source) ||
        napi_get_value_double(env, args[1], &device) != napi_ok ||
        !std::isfinite(device) || std::floor(device) != device || device < -1.0 ||
        device > 9007199254740991.0 ||
        !ReadBoundedUtf8String(env, args[2], 192u, control) || control.empty() ||
        control.find('\0') != std::string::npos ||
        napi_is_array(env, args[3], &array) != napi_ok || !array ||
        napi_get_array_length(env, args[3], &count) != napi_ok || count == 0u || count > 6u) {
        return amcl::napi::WrapStringResult(env, "");
    }
    int codes[6] = {};
    for (uint32_t i = 0; i < count; ++i) {
        napi_value item = nullptr;
        double code = 0.0;
        if (napi_get_element(env, args[3], i, &item) != napi_ok ||
            napi_get_value_double(env, item, &code) != napi_ok || !std::isfinite(code) ||
            std::floor(code) != code || code < -16.0 || code > 512.0 || code == 0.0) {
            return amcl::napi::WrapStringResult(env, "");
        }
        codes[i] = static_cast<int>(code);
    }
    amcl::input::SurfaceInputGateTransaction gate;
    if (!gate) return amcl::napi::WrapStringResult(env, "");
    uint64_t publicationToken = 0;
    if (source == 1 && ((argc != 5 && argc != 7) || !ReadTouchIdentity(env, args[4], &publicationToken) ||
        !amcl::input::AcceptTouchUiPublication(publicationToken))) return amcl::napi::WrapStringResult(env, "");
    if (source == 1) {
        std::string member; uint64_t eligibility = 0;
        if (argc == 7 && (!ReadBoundedUtf8String(env,args[5],23,member) || !ReadTouchIdentity(env,args[6],&eligibility)))
            return amcl::napi::WrapStringResult(env, "");
        const uint64_t owner = amcl::input::AcquireTouchGroupSourceControl(publicationToken,member,eligibility,
            device >= 0.0 ? static_cast<uint64_t>(device) : UINT64_MAX,control,codes,count);
        return amcl::napi::WrapStringResult(env,owner ? std::to_string(owner).c_str() : "");
    }
    const uint64_t token = ohos_acquire_source_control(source,
        device >= 0.0 ? static_cast<uint64_t>(device) : UINT64_MAX,
        control.c_str(), codes, count);
    const std::string encoded = token ? std::to_string(token) : std::string();
    return amcl::napi::WrapStringResult(env, encoded.c_str());
}

napi_value ReleaseSourceControl(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string encoded;
    if (argc != 1 || !ReadBoundedUtf8String(env, args[0], 20u, encoded) || encoded.empty())
        return amcl::napi::MakeBoolResult(env, false);
    uint64_t token = 0u;
    for (const char digit : encoded) {
        if (digit < '0' || digit > '9' || token > (UINT64_MAX - (digit - '0')) / 10u)
            return amcl::napi::MakeBoolResult(env, false);
        token = token * 10u + static_cast<uint64_t>(digit - '0');
    }
    // 释放不持有效 surface 准入：失焦/销毁时仍允许退休 token。
    return amcl::napi::MakeBoolResult(env, ohos_release_source_control(token));
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

// textInputKeyTap(generation, ohosKeyCode, glfwKey) → 0/1/2（数值语义见 ingress 头的
// PlatformInputTextKeyTapResult）。参数读取失败一律 Rejected（2），不让调用方误以为
// 可以回退 ring。generation 允许为 0：宿主会话尚未重建时仍要先回答是否在 typed 路由，
// legacy 路由下 ArkTS 才能改走原 ring；ingress 在路由判断之后才拒绝 0 号会话。
// 门禁事务覆盖整个调用，与 commitTextInput 同一条 surface 拆除互斥约束。
napi_value TextInputKeyTap(napi_env env, napi_callback_info info) {
    size_t argc = 3u;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t generation = -1;
    uint32_t ohosKeyCode = 0u;
    int32_t glfwKey = 0;
    int32_t outcome = static_cast<int32_t>(
        amcl::input::PlatformInputTextKeyTapResult::Rejected);
    if (argc == 3u &&
        napi_get_value_int64(env, args[0], &generation) == napi_ok &&
        generation >= 0 &&
        napi_get_value_uint32(env, args[1], &ohosKeyCode) == napi_ok &&
        napi_get_value_int32(env, args[2], &glfwKey) == napi_ok) {
        amcl::input::SurfaceInputGateTransaction gate;
        // 在任何Source loader/descriptor潜在等待之前捕获原Core资格；同ID重开也有新scope。
        AmclInputTextCoreResourceV1 originalText{};
        const uint64_t originalKeyboardScope=gate?amclInputOwnerL2KeyboardScopeV1():0;
        if(gate)(void)amclInputOwnerReadTextResourceV1(&originalText);
        outcome = static_cast<int32_t>(
            amcl::input::PlatformInputTextSessionKeyTap(
                static_cast<uint64_t>(generation), ohosKeyCode, glfwKey,
                static_cast<bool>(gate)));
        // 有效owned文本属于编辑职责，模态门不能仅凭旧TouchControls来源标记误封它。
        // 未拥有Native文本租约的旧调用仍得到NotTypedRoute，其普通触控fallback服从modal准入。
        if (gate && outcome == static_cast<int32_t>(amcl::input::PlatformInputTextKeyTapResult::NotTypedRoute) &&
            amcl::input::PlatformInputOwnedTextSessionMatches(static_cast<uint64_t>(generation))) {
            // 不以物理legacy选择关闭owned文字键能力。一次Source候选/全批预算保整对；
            // prepare之后原Core文字scope再次复核，拒绝不会留下匿名Touch DOWN。
            const bool accepted = (originalText.textSession == static_cast<uint64_t>(generation) && amcl::input::SourceOwnedTextKeyTap(originalText, glfwKey, originalKeyboardScope));
            outcome = static_cast<int32_t>(accepted
                ? amcl::input::PlatformInputTextKeyTapResult::Submitted
                : amcl::input::PlatformInputTextKeyTapResult::Rejected);
        }
    }
    return amcl::napi::MakeIntResult(env, outcome);
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
    NAPI_FUNC("acquireSourceControl",  AcquireSourceControl),
    NAPI_FUNC("releaseSourceControl",  ReleaseSourceControl),
    NAPI_FUNC("sendSourceMouseEvent",  SendSourceMouseEvent),
    NAPI_FUNC("sendSourceScrollEvent", SendSourceScrollEvent),
    NAPI_FUNC("sendSourceCursorDelta", SendSourceCursorDelta),
    NAPI_FUNC("sendSourceCursorSample", SendSourceCursorSample),
    NAPI_FUNC("releaseSourceHeld",     ReleaseSourceHeld),
    NAPI_FUNC("noteSourceReset",       NoteSourceReset),
    NAPI_FUNC("inputInvariantTick",    InputInvariantTick),
    NAPI_FUNC("sendCursorPos",       SendCursorPos),
    NAPI_FUNC("textInputSessionSupported", TextInputSessionSupported),
    NAPI_FUNC("beginTextInputSession", BeginTextInputSession),
    NAPI_FUNC("endTextInputSession", EndTextInputSession),
    NAPI_FUNC("abortTextInputSession", AbortTextInputSession),
    NAPI_FUNC("commitTextInput", CommitTextInput),
    NAPI_FUNC("textInputKeyTap", TextInputKeyTap),
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
    NAPI_FUNC("getInputResetDomains", GetInputResetDomains),
    NAPI_FUNC("setLookSensitivity",  SetLookSensitivity),
    NAPI_FUNC("applyLookConfiguration", ApplyLookConfiguration),
    NAPI_FUNC("applySourceLookConfiguration", ApplySourceLookConfiguration),
    NAPI_FUNC("sharedLookExecutionSupported", SharedLookExecutionSupported),
    NAPI_FUNC("setMappedLookVelocity", SetMappedLookVelocity),
    NAPI_FUNC("advanceMappedLookExecution", AdvanceMappedLookExecution),
    NAPI_FUNC("retireMappedLookConnection", RetireMappedLookConnection),
    NAPI_FUNC("setInvertY",          SetInvertY),
    NAPI_FUNC("setLookSmoothing",    SetLookSmoothing),
    NAPI_FUNC("setLookAccel",        SetLookAccel),
    NAPI_FUNC("setControlSchema",    SetControlSchema),
    NAPI_FUNC("touchPublicationState", TouchPublicationState),
    NAPI_FUNC("readTouchGroups", ReadTouchGroups),
    NAPI_FUNC("confirmTouchGroups", ConfirmTouchGroups),
    NAPI_FUNC("isTouchGroupControlCurrent", IsTouchGroupControlCurrent),
    NAPI_FUNC("bindTouchGroupMouseOwner", BindTouchGroupMouseOwner),
    NAPI_FUNC("invokeTouchGroupControl", InvokeTouchGroupControl),
    NAPI_FUNC("restoreTouchGroups", RestoreTouchGroups),
    NAPI_FUNC("onTouchGroupsChanged", OnTouchGroupsChanged),
    NAPI_FUNC("beginTouchPublication", BeginTouchPublication),
    NAPI_FUNC("publishTouchSchema", PublishTouchSchema),
    NAPI_FUNC("confirmTouchPublication", ConfirmTouchPublication),
    NAPI_FUNC("abortTouchPublication", AbortTouchPublication),
    NAPI_FUNC("acquireTouchModal", AcquireTouchModal),
    NAPI_FUNC("releaseTouchModal", ReleaseTouchModal),
    NAPI_FUNC("isTouchPublicationCurrent", IsTouchPublicationCurrent),
    NAPI_FUNC("maintainTouchInput", MaintainTouchInput),
    NAPI_FUNC("touchInteractionVisual", TouchInteractionVisual),
    NAPI_FUNC("gameGuiState", GameGuiState),
    NAPI_FUNC("gameGuiStateForSource", GameGuiStateForSource),
    NAPI_FUNC("gameGuiStartSession", GameGuiStartSession),
    NAPI_FUNC("gameGuiCaptureSession", GameGuiCaptureSession),
    NAPI_FUNC("gameGuiStopSession", GameGuiStopSession),
    NAPI_FUNC("gameGuiAttachSource", GameGuiAttachSource),
    NAPI_FUNC("gameGuiRetireSource", GameGuiRetireSource),
    NAPI_FUNC("moveTouchMenuPointer", MoveTouchMenuPointer),
    NAPI_FUNC("touchMenuButton", TouchMenuButton),
    NAPI_FUNC("cancelTouchMenuMouse", CancelTouchMenuMouse),
    NAPI_FUNC("touchMenuScroll", TouchMenuScroll),
    NAPI_FUNC("setTouchMenuMouseBounds", SetTouchMenuMouseBounds),
    NAPI_FUNC("setTouchGuideBounds", SetTouchGuideBounds),
    NAPI_FUNC("restoreGameGuiScale", RestoreGameGuiScale),
    NAPI_FUNC("restoreGameGuiScaleForSource", RestoreGameGuiScaleForSource),
    NAPI_FUNC("sendTouchGyroSample", SendTouchGyroSample),
    NAPI_FUNC("touchGyroLeaseContext", TouchGyroLeaseContext),
    NAPI_FUNC("beginTouchGyroLease", BeginTouchGyroLease),
    NAPI_FUNC("submitTouchGyroLease", SubmitTouchGyroLease),
    NAPI_FUNC("retireTouchGyroLease", RetireTouchGyroLease),
};

#undef NAPI_FUNC

} // anonymous namespace

// 由 touch_input.cpp 的 schemaDispatchButton / hotbar tap 在 native 输入线程调用。
// nonblocking + bounded queue：队列满时允许丢本次反馈；输入 PRESS/RELEASE 绝不依赖触觉成功，
// 也不能为了等待 UI 线程而阻塞 XComponent/MC 输入线程。
/** 生成时冻结源/控件/会话与时间；排队失败立即释放有界载荷，不影响输入边沿。 */
extern "C" void amcl_fire_haptic_tagged(int strength, const char* controlId, uint64_t schemaGeneration,
        uint64_t touchResetEpoch, int64_t monotonicTimeNs, uint64_t grabEpoch) {
    if (strength <= 0 || strength > 3 || !controlId || std::strlen(controlId) > AMCL_CONTROL_ID_MAX_BYTES) return;
    std::lock_guard<std::mutex> lock(g_hapticMutex);
    auto* context = g_hapticFeedback;
    if (!context || !context->active) return;
    auto* event = new (std::nothrow) HapticFeedbackEvent();
    if (!event) return;
    event->strength = strength;
    std::memcpy(event->controlId, controlId, std::strlen(controlId) + 1);
    event->schema = schemaGeneration; event->session = touchResetEpoch; event->generatedNs = monotonicTimeNs;
    event->grabEpoch = grabEpoch;
    if (napi_call_threadsafe_function(context->tsfn, event, napi_tsfn_nonblocking) != napi_ok) delete event;
}
/** 旧调用点仍冻结本次注册和生成时钟；正式schema出口使用有身份的tagged入口。 */
extern "C" void amcl_fire_haptic(int strength) {
    amcl_fire_haptic_tagged(strength, "", 0, 0, FeedbackNowNs(), 0);
}
/** 按注册上下文合并最终状态，最大控件数沿用schema预算；满容器不会新增未知ID。 */
extern "C" void amcl_fire_button_pressed(const char* id, int pressed) {
    if (!id || !id[0] || std::strlen(id) > AMCL_CONTROL_ID_MAX_BYTES) return;
    std::lock_guard<std::mutex> lock(g_btnPressMutex);
    auto* context = g_btnFeedback;
    if (!context || !context->active) return;
    try {
        const std::string key(id);
        if (context->pending.size() >= AMCL_CONTROL_SCHEMA_MAX_CONTROLS && context->pending.find(key) == context->pending.end()) return;
        context->pending[key] = pressed != 0 ? 1 : 0;
    } catch (...) {
        // 视觉map分配失败不能逃逸到ledger/schema事务，造成PRESS已成立却outputDown未标记。
        // 本次反馈允许丢弃，实际按键和owner仍由既有输入链完成，后续当前状态可重新投影。
        return;
    }
    if (!context->wakeQueued && napi_call_threadsafe_function(context->tsfn, nullptr, napi_tsfn_nonblocking) == napi_ok)
        context->wakeQueued = true;
}

/** 只投递有界唤醒；结果仍从当前 token 查询。通知失败不撤销已提交动作或解除呈现门。 */
extern "C" void amcl_notify_touch_groups() {
    std::lock_guard<std::mutex> lock(g_groupNotificationMutex);
    auto* context = g_groupNotification;
    if (context && context->active && !context->queued &&
        napi_call_threadsafe_function(context->tsfn,nullptr,napi_tsfn_nonblocking) == napi_ok) context->queued = true;
}

namespace amcl::napi {

void registerInputNapi(napi_env env, napi_value exports) {
    // 反向 trampoline 必须在任何输入事件之前就位。typed 视角的消费者可以是**第一个**
    // 相对样本，那时 bridge-resolve 路径可能一次都还没跑过（理由见 touch_input.cpp 的
    // publishReverseTrampolines 注释）。这里发布是幂等的，不依赖 libglfw 是否已加载。
    ohos_input_publish_trampolines();
    // grab 变化回调句柄同样只在模块初始化发布一次（I27-05），onGrabChange 不再写环境。
    std::call_once(g_grabTrampolinePublished, PublishGrabChangeTrampolineOnce);
    napi_define_properties(env, exports,
                           sizeof(kInputDescriptors) / sizeof(kInputDescriptors[0]),
                           kInputDescriptors);
}

} // namespace amcl::napi
