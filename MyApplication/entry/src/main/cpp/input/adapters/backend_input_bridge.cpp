#include "backend_input_bridge.h"

#include "backend_keymaps.h"
#include "backend_input_event_encode.h"
#include "glfw_input_adapter.h"
#include "../text_utf8_codec.h"
#include "../amcl_input_api.h"
#include "../amcl_input_event.h"
// 跨 linker namespace 的 host table 解析。本 TU 不得用本地 getter，理由见 EnsureOpenLocked。
#include "../amcl_input_host_descriptor.h"
// 滚轮量纲与符号只有一份契约，本通道不得再写一遍（计划 §102.1）。
#include "../../platform/physical_wheel_quantizer.h"

#include <hilog/log.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "BACKEND_INPUT"

// 镜像常量必须有机械判据，否则它就是下一个"两处各说一套量纲"。
static_assert(AMCL_BACKEND_INPUT_LWJGL2 == AMCL_INPUT_BACKEND_LWJGL2_PHYSICAL,
              "LWJGL2 backend id mirror drifted");
static_assert(AMCL_BACKEND_INPUT_SDL3 == AMCL_INPUT_BACKEND_SDL3_PHYSICAL,
              "SDL3 backend id mirror drifted");
static_assert(AMCL_BACKEND_INPUT_ACTION_DOWN == AMCL_INPUT_ACTION_DOWN,
              "DOWN action mirror drifted");
static_assert(AMCL_BACKEND_INPUT_ACTION_REPEAT == AMCL_INPUT_ACTION_REPEAT,
              "REPEAT action mirror drifted");
static_assert(AMCL_BACKEND_INPUT_ACTION_UP == AMCL_INPUT_ACTION_UP,
              "UP action mirror drifted");
static_assert(AMCL_BACKEND_INPUT_DEVICE_ADDED == AMCL_INPUT_DEVICE_ADDED,
              "device-added mirror drifted");
static_assert(AMCL_BACKEND_INPUT_DEVICE_REMOVED == AMCL_INPUT_DEVICE_REMOVED,
              "device-removed mirror drifted");
static_assert(AMCL_BACKEND_INPUT_DEVICE_CLASS_UNKNOWN ==
                  AMCL_INPUT_DEVICE_CLASS_UNKNOWN &&
              AMCL_BACKEND_INPUT_DEVICE_CLASS_MOUSE ==
                  AMCL_INPUT_DEVICE_CLASS_MOUSE &&
              AMCL_BACKEND_INPUT_DEVICE_CLASS_TOUCHPAD ==
                  AMCL_INPUT_DEVICE_CLASS_TOUCHPAD,
              "device-class mirror drifted");
static_assert(
    AMCL_BACKEND_INPUT_SURFACE_CONTEXT_FIELD_WINDOW ==
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_WINDOW &&
    AMCL_BACKEND_INPUT_SURFACE_CONTEXT_FIELD_DISPLAY ==
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_DISPLAY &&
    AMCL_BACKEND_INPUT_SURFACE_CONTEXT_FIELD_RECT ==
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_RECT &&
    AMCL_BACKEND_INPUT_SURFACE_CONTEXT_FIELD_DENSITY ==
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY &&
    AMCL_BACKEND_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM ==
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM &&
    AMCL_BACKEND_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE ==
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE,
    "surface-context validity mirror drifted");
static_assert(sizeof(AmclBackendInputEvent) == 64,
              "backend input event ABI changed");

namespace {

using amcl::input::GlfwAdapterStatus;
using amcl::input::GlfwInputAdapter;
using amcl::input::GlfwInputSink;
using amcl::input::GlfwPumpResult;

// 队列容量。比 core 的 256 小是刻意的：这一层只是"后端还没来取的那几帧"，深了只会把
// 一次卡顿变成一串迟到的输入。满了投 RESET，与 legacy ring 同一条纪律。
constexpr size_t kQueueCapacity = 128u;
constexpr size_t kTextPacketCapacity = 128u;
constexpr size_t kTextByteCapacity = 1024u * 1024u;

struct BackendChannel {
    std::mutex mutex;
    GlfwInputAdapter adapter;
    std::deque<AmclBackendInputEvent> queue;
    std::map<uint64_t, std::vector<uint8_t>> textPackets;
    uint64_t nextTextPacket = 1u;
    size_t textPacketBytes = 0u;
    bool opened = false;
    bool active = false;
    // ⚠️ 墓碑: resetPending 已删除（三处写、零处读 —— 溢出时那条 RESET 本身就在队列里，
    // 这个布尔量没有第二个读者），详见计划 §103.1
    uint64_t droppedEvents = 0;
    uint64_t overflowCount = 0;
    // ⭐ 投递计数按类型分开，只为一件事：**真机上证明事件真的到了消费者手里。**
    // 在这之前本通道能打出来的最强一句是"consumer ready"，而那只证明 Open 成功 ——
    // "通道建起来了但一个事件都没流过"与"工作正常"在日志里长得一模一样，而前者恰好是
    // 本仓已经踩过七次的那一族（挂在一个不会被调用的地方）。⇒ 端到端验收的判据必须是
    // 一个**单调增长的计数**，不是一句一次性的就绪声明。
    uint64_t deliveredKeys = 0;
    uint64_t deliveredButtons = 0;
    uint64_t deliveredWheels = 0;
    uint64_t deliveredResets = 0;
    uint64_t deliveredFocus = 0;
    uint64_t deliveredCapture = 0;
    uint64_t deliveredRelative = 0;
    uint64_t deliveredDevices = 0;
    uint64_t deliveredSurfaceContexts = 0;
    uint64_t deliveredText = 0;
    // scanCode 三个编码空间各出现多少次，理由见 CountScanCodeSourceLocked。
    uint64_t scanSrcHardware = 0;
    uint64_t scanSrcHidUsage = 0;
    uint64_t scanSrcRawIdentity = 0;
    // ⭐ 滚轮**接受侧**的量级。**这是一条测量，不是一个修复。**
    //
    // 本通道此前只在**拒绝**时打日志（LogWheelReject），接受路径零埋点 ⇒ "一个平台样本
    // 变成了几格"在真机上不可观测。而这正好是 2026-09-05 那条"26.3 菜单滚轮一滑到底"
    // 唯一缺的那个数：`stepPx=1.0` 在 GLFW/LWJGL2 两条链上被 `maxDetentsPerEvent=1`
    // 截断吃掉，只有本通道把它当真正的换算系数用 ⇒ 平台样本多大，MC 就收到多少格。
    // ⚠️ 必须记**累计最大值**而不是只记最近一条：节流会让最大的那一条正好被跳过，
    // 而"最大一次滚出多少格"才是判据。
    uint64_t wheelSamples = 0;
    double wheelMaxAbsDetents = 0.0;
    // 本通道自己的 px 余量累加器。⚠️ **刻意不与 GLFW3 平面共享**：同一次滚动只会被一条
    // 消费链拥有，共享反而会让两条互相清零（与 `g_typedWheelRemainderPx` 同一条既有设计）。
    double wheelRemainderPx = 0.0;
    // 通道未激活导致的拉取拒绝数。⚠️ 它存在的理由是把一条**只能靠"日志里没有"来判定**的
    // 缺陷换成正向证据：`amclBackendInputSetActive` 从未被调用时，本函数每帧静默返回
    // NOT_READY，而"通道没激活"与"用户没按键"在日志里长得一模一样（规范 §八 纪律 5）。
    uint64_t inactivePulls = 0;
};

// 索引 0 = LWJGL2、1 = SDL3。GLFW3 不在这里：它有自己的 sink 直接进 GLFW 运行期状态。
BackendChannel g_channels[2];

BackendChannel* ChannelFor(uint32_t backend) {
    if (backend == AMCL_BACKEND_INPUT_LWJGL2) return &g_channels[0];
    if (backend == AMCL_BACKEND_INPUT_SDL3) return &g_channels[1];
    return nullptr;
}

uint32_t backendOf(const BackendChannel* channel) {
    return channel == &g_channels[0] ? AMCL_BACKEND_INPUT_LWJGL2
                                     : AMCL_BACKEND_INPUT_SDL3;
}

void CountScanCodeSourceLocked(BackendChannel* channel, uint32_t backend,
                               amcl::input::GlfwScanCodeSource source);

AmclBackendInputEvent BlankEvent(uint32_t type) {
    AmclBackendInputEvent event{};
    event.abiVersion = static_cast<uint16_t>(AMCL_BACKEND_INPUT_ABI_VERSION);
    event.structSize = static_cast<uint16_t>(sizeof(event));
    event.eventType = type;
    return event;
}

// 入队。**必须在 channel->mutex 内调用。** 溢出时整条清空并投一条 RESET：留下半截
// 序列比丢掉整段更糟 —— 消费者会拿到一批没有配对 UP 的 DOWN，在游戏里读作卡键。
void EnqueueLocked(BackendChannel* channel, const AmclBackendInputEvent& event) {
    if (channel->queue.size() >= kQueueCapacity) {
        channel->droppedEvents += channel->queue.size();
        channel->queue.clear();
        channel->textPackets.clear();
        channel->textPacketBytes = 0u;
        ++channel->overflowCount;
        AmclBackendInputEvent reset = BlankEvent(AMCL_BACKEND_INPUT_EVENT_RESET);
        reset.resetReason = AMCL_INPUT_RESET_QUEUE_OVERFLOW;
        channel->queue.push_back(reset);
        OH_LOG_ERROR(LOG_APP,
            "backend queue overflow backend-slot=%{public}d dropped=%{public}llu count=%{public}llu",
            static_cast<int>(channel - g_channels),
            static_cast<unsigned long long>(channel->droppedEvents),
            static_cast<unsigned long long>(channel->overflowCount));
        return;
    }
    channel->queue.push_back(event);
}

bool EnqueueTextLocked(BackendChannel* channel,
                       AmclBackendInputEvent event,
                       const std::vector<uint8_t>& bytes) {
    if (channel->nextTextPacket == 0u ||
        channel->nextTextPacket == UINT64_MAX ||
        channel->textPackets.size() >= kTextPacketCapacity ||
        bytes.size() > kTextByteCapacity - channel->textPacketBytes) {
        channel->droppedEvents += channel->queue.size() + 1u;
        channel->queue.clear();
        channel->textPackets.clear();
        channel->textPacketBytes = 0u;
        ++channel->overflowCount;
        AmclBackendInputEvent reset = BlankEvent(
            AMCL_BACKEND_INPUT_EVENT_RESET);
        reset.resetReason = AMCL_INPUT_RESET_BLOB_POOL_EXHAUSTED;
        channel->queue.push_back(reset);
        return false;
    }
    const uint64_t packetId = channel->nextTextPacket++;
    event.deviceId = packetId;
    event.code = static_cast<int32_t>(bytes.size());
    channel->textPacketBytes += bytes.size();
    channel->textPackets.emplace(packetId, bytes);
    EnqueueLocked(channel, event);
    return !channel->queue.empty() &&
        channel->queue.back().eventType == event.eventType;
}

// ── sink：把 adapter 产出的后端编码事件放进本后端的队列 ────────────────────────
//
// ⚠️ sink 在 adapter 的回调栏内被调用，而 `amclBackendInputNext` 已经持有
// channel->mutex 才去 Pump。所以这里**不能**再取同一把锁 —— 会自锁。契约写在
// 每个 sink 上方而不是只写在一处：漏读一个 sink 的代价是一次死锁而不是一次错值。

void KeySink(void* context, const amcl::input::GlfwKeySinkEvent& event) {
    // 已在 channel->mutex 内（调用链：amclBackendInputNext → Pump → 本函数）。
    auto* channel = static_cast<BackendChannel*>(context);
    AmclBackendInputEvent out = BlankEvent(AMCL_BACKEND_INPUT_EVENT_KEY);
    out.code = event.key;
    out.rawCode = event.scanCode;
    out.action = event.action == amcl::input::GlfwInputAction::kRelease
        ? AMCL_BACKEND_INPUT_ACTION_UP
        : (event.action == amcl::input::GlfwInputAction::kRepeat
               ? AMCL_BACKEND_INPUT_ACTION_REPEAT
               : AMCL_BACKEND_INPUT_ACTION_DOWN);
    // ⭐ 这三个字段是旧通道**装不下**的，也是本次迁移的实际收益之一：
    // `lockState` 是"Caps/Num/Scroll 只能来自平台锁存快照、禁止从 held 推断"的唯一载体
    // （计划 §5.2），SDL 的 SDL_GetModState 需要它。
    out.modifiers = event.modifiers;
    out.lockState = event.lockState;
    out.deviceId = event.deviceId;
    out.sequence = event.sequence;
    // ⚠️ 2026-08-24 之前这一行**不存在** ⇒ 字段恒 0，而声明写着"core 盖的时间戳"、SDL 侧
    // 三处当时间戳用。与 wheelX/wheelY 那条是同一族（声明说 A、实现做 B），只是它的表现
    // 更隐蔽：SDL 把 0 解释成"现在"，所以功能看起来是好的，丢掉的是时间精度与那句声明。
    out.monotonicTimeNs = event.monotonicTimeNs;
    CountScanCodeSourceLocked(channel, backendOf(channel), event.scanCodeSource);
    EnqueueLocked(channel, out);
}

void ButtonSink(void* context, const amcl::input::GlfwButtonSinkEvent& event) {
    // 已在 channel->mutex 内。
    auto* channel = static_cast<BackendChannel*>(context);
    AmclBackendInputEvent out = BlankEvent(AMCL_BACKEND_INPUT_EVENT_BUTTON);
    out.code = event.button;
    out.action = event.action == amcl::input::GlfwInputAction::kRelease
        ? AMCL_BACKEND_INPUT_ACTION_UP
        : AMCL_BACKEND_INPUT_ACTION_DOWN;
    out.deviceId = event.deviceId;
    out.resetReason = event.deviceClass;
    out.sequence = event.sequence;
    out.monotonicTimeNs = event.monotonicTimeNs;
    EnqueueLocked(channel, out);
}

// 被拒的滚轮样本计数（两条 channel 各有各的锁，所以这里必须是原子的）。
std::atomic<uint64_t> g_wheelRejectCount{0};
std::atomic<uint64_t> g_relativeRejectCount{0};

// ⭐ scanCode 三个来源各出现多少次。**这是一条测量，不是一个修复。**
//
// `scanCode` 合并了三个不同的编码空间（硬件扫描码 / HID usage / OHOS keyCode），而 SDL 把它
// 当 evdev rawcode 用 —— 只有第一支是 evdev 语义。给 ABI 加判别位要重建 SDL3（那个结构固定
// 64 字节、两侧都有 static_assert），而**在知道真机上三支各占多少之前就去改 ABI，等于先付
// 代价再看要不要付**。所以先量：若真机恒走 `kHardware`，这条缺口的实际影响是 0，可以带证据
// 关掉；若另两支真的出现，那时才知道 ABI 改动值不值。⇒ 判据：**给一条推断出来的缺口定优先级
// 之前，先让它变成一个可以数的数。**（计划 §106.2）
//
// **必须在 channel->mutex 内调用。** 节流同 `AMCL_BACKEND_DELIVERED`：按键计数的 2 的幂。
void CountScanCodeSourceLocked(BackendChannel* channel, uint32_t backend,
                               amcl::input::GlfwScanCodeSource source) {
    switch (source) {
        case amcl::input::GlfwScanCodeSource::kHardware:
            ++channel->scanSrcHardware; break;
        case amcl::input::GlfwScanCodeSource::kHidUsage:
            ++channel->scanSrcHidUsage; break;
        case amcl::input::GlfwScanCodeSource::kRawIdentity:
            ++channel->scanSrcRawIdentity; break;
        default:
            // kNone 只可能来自合成的 fail-safe 释放或溢出归零，不是一次平台身份 ⇒ 不计。
            return;
    }
    const uint64_t total = channel->scanSrcHardware +
        channel->scanSrcHidUsage + channel->scanSrcRawIdentity;
    if ((total & (total - 1u)) != 0u) return;
    OH_LOG_INFO(LOG_APP,
        "AMCL_BACKEND_SCANSRC backend=%{public}u hardware=%{public}llu "
        "hidUsage=%{public}llu rawIdentity=%{public}llu",
        backend,
        static_cast<unsigned long long>(channel->scanSrcHardware),
        static_cast<unsigned long long>(channel->scanSrcHidUsage),
        static_cast<unsigned long long>(channel->scanSrcRawIdentity));
}

void LogWheelReject(const char* why, uint32_t unit) {
    const uint64_t count =
        g_wheelRejectCount.fetch_add(1u, std::memory_order_relaxed) + 1u;
    if ((count & (count - 1u)) != 0u) return;
    OH_LOG_ERROR(LOG_APP,
        "backend wheel rejected why=%{public}s unit=%{public}u count=%{public}llu",
        why, unit, static_cast<unsigned long long>(count));
}

void WheelSink(void* context, const amcl::input::GlfwWheelSinkEvent& event) {
    // 已在 channel->mutex 内。
    auto* channel = static_cast<BackendChannel*>(context);
    // ⭐ 2026-09-05 重写。此前这里只换**量纲与符号**（`GlfwScrollDetentsFromWheelPx`），
    // 刻意不分格，理由写的是"SDL 的滚轮本来就是连续的"。**那个理由在本平台不成立，
    // 而代价是 45 倍放大**：
    //
    //   · `kGlfwPhysicalWheelPolicy` 有四个字段，这里只用了 `stepPx`，
    //     `maxDetentsPerEvent=1` 与 `DropOnCrossing` 两条通道契约整个被跳过；
    //   · 而 `stepPx = 1.0` **从来不是标定值**，它只是占位符 —— 它一直没出事，
    //     只因为另外两条链下游都有那道截断把它吃掉了。去掉截断，占位符就变成了真系数。
    //   · 真机实测（API 26，`AMCL_BACKEND_WHEELMAG`）：一个物理格 = **恒定 45.0 px**
    //     ⇒ SDL 每格收到 45 格 ⇒ 菜单一滑到底。**平台本身就是分好格的**（四条样本
    //     全是 45.0000，正反向对称），所谓"连续信号"在物理鼠标上并不存在。
    //
    // ⇒ 现在三条消费链（GLFW3 的 `typedWheelSink`、本通道、LWJGL2 出线）调**同一个**
    // `StepPhysicalWheel`，横轴 fail-closed、非有限拒收、拒绝时余量归零、分格与截断
    // 全部由它负责。等价性由 `wheel_dual_plane_differential_test` 的三消费端组钉住。
    //
    // ⚠️ 真触控板的连续滚动因此会被压成整格。本机无触控板证据，记为已知缺口：
    // 要恢复它必须按 `deviceClass`（MOUSE / TOUCHPAD）分流，而那需要触控板真机数据。
    double xPx = 0.0;
    double yPx = 0.0;
    if (!amcl::input::WheelSamplePxFromUnit(
            event.x, event.y, event.unit,
            amcl::input::kGlfwPhysicalWheelPolicy, &xPx, &yPx)) {
        // ⚠️ 未知量纲 fail closed。原实现连 unit 都没读 ⇒ LINE/PAGE 会被静默当 px，
        // 正是计划 §90 那次"量纲被静默误解"的形状在第三处重演。
        LogWheelReject("unit", event.unit);
        return;
    }
    amcl::input::PhysicalWheelStepOutcome step{};
    amcl::input::StepPhysicalWheel(
        channel->wheelRemainderPx, xPx, yPx,
        amcl::input::kGlfwPhysicalWheelPolicy, &step);
    // 无条件写回，拒绝路径也一样（那时它是 0.0）—— 与另外两条链逐字相同的纪律。
    channel->wheelRemainderPx = step.remainder;
    if (step.status == amcl::input::PhysicalWheelStepStatus::kRejectedAxis) {
        LogWheelReject("axis", event.unit);
        return;
    }
    if (step.status == amcl::input::PhysicalWheelStepStatus::kRejectedValue) {
        LogWheelReject("value", event.unit);
        return;
    }
    // 零样本与亚阈值累加都不投递：SDL 收到 0.0 会生成一个什么都不表示的滚轮事件。
    if (step.status != amcl::input::PhysicalWheelStepStatus::kEmit) return;
    const double detentsY = static_cast<double>(step.glfwY);
    // 接受侧量级测量（见 BackendChannel::wheelMaxAbsDetents）。已在 channel->mutex 内。
    ++channel->wheelSamples;
    const double absDetents = detentsY < 0.0 ? -detentsY : detentsY;
    if (absDetents > channel->wheelMaxAbsDetents) {
        channel->wheelMaxAbsDetents = absDetents;
    }
    if ((channel->wheelSamples & (channel->wheelSamples - 1u)) == 0u) {
        OH_LOG_INFO(LOG_APP,
            "AMCL_BACKEND_WHEELMAG backend=%{public}u unit=%{public}u "
            "sampleY=%{public}.4f px=%{public}.4f detents=%{public}.4f "
            "maxAbsDetents=%{public}.4f samples=%{public}llu",
            backendOf(channel), event.unit,
            static_cast<double>(event.y), yPx, detentsY,
            channel->wheelMaxAbsDetents,
            static_cast<unsigned long long>(channel->wheelSamples));
    }
    AmclBackendInputEvent out = BlankEvent(AMCL_BACKEND_INPUT_EVENT_WHEEL);
    out.wheelX = 0.0f;
    out.wheelY = static_cast<float>(detentsY);
    out.deviceId = event.deviceId;
    out.resetReason = event.deviceClass;
    out.sequence = event.sequence;
    out.monotonicTimeNs = event.monotonicTimeNs;
    EnqueueLocked(channel, out);
}

void ResetSink(void* context, const amcl::input::GlfwResetSinkEvent& event) {
    // 已在 channel->mutex 内。
    auto* channel = static_cast<BackendChannel*>(context);
    AmclBackendInputEvent out = BlankEvent(AMCL_BACKEND_INPUT_EVENT_RESET);
    out.resetReason = event.reason;
    out.sequence = event.sequence;
    out.monotonicTimeNs = event.monotonicTimeNs;
    EnqueueLocked(channel, out);
}

void FocusSink(void* context, const amcl::input::GlfwFocusSinkEvent& event) {
    // Already inside channel->mutex. Baseline focus=false is intentionally
    // delivered: a late backend must not initialize as focused.  Do not clear
    // owned text packets here: their queue records precede this focus edge and
    // remain readable until the backend explicitly releases each packet.
    auto* channel = static_cast<BackendChannel*>(context);
    EnqueueLocked(channel, amcl::input::EncodeBackendFocus(event));
}

void CaptureSink(void* context,
                 const amcl::input::GlfwCaptureSinkEvent& event) {
    // Already inside channel->mutex. Request and activation stay separate so an
    // asynchronous WindowManager rejection can unwind backend relative mode.
    auto* channel = static_cast<BackendChannel*>(context);
    EnqueueLocked(channel, amcl::input::EncodeBackendCapture(event));
}

void DeviceSink(void* context,
                const amcl::input::GlfwDeviceSinkEvent& event) {
    // LWJGL2 exposes one process-wide Mouse and has no device hotplug ABI. SDL3
    // does expose SDL_MouseID plus ADDED/REMOVED, so only that channel consumes
    // the additive record.
    auto* channel = static_cast<BackendChannel*>(context);
    if (backendOf(channel) != AMCL_BACKEND_INPUT_SDL3) return;
    const uint32_t pointerCapabilities =
        AMCL_INPUT_DEVICE_CAP_POINTER_ABSOLUTE |
        AMCL_INPUT_DEVICE_CAP_POINTER_RELATIVE |
        AMCL_INPUT_DEVICE_CAP_POINTER_BUTTONS |
        AMCL_INPUT_DEVICE_CAP_WHEEL |
        AMCL_INPUT_DEVICE_CAP_HOVER |
        AMCL_INPUT_DEVICE_CAP_CAPTURE;
    if ((event.capabilities & pointerCapabilities) == 0u &&
        event.deviceClass != AMCL_INPUT_DEVICE_CLASS_MOUSE &&
        event.deviceClass != AMCL_INPUT_DEVICE_CLASS_TOUCHPAD) {
        // Keyboard/touchscreen/gamepad DEVICE_CHANGED records share the core
        // registry. An UNKNOWN record with explicit pointer capabilities is
        // still forwarded: SDL keeps the class unknown and uses a generic
        // pointer name, so device removal can retire its source without
        // guessing Mouse vs Touchpad.
        return;
    }
    EnqueueLocked(channel, amcl::input::EncodeBackendDevice(event));
}

void RelativeSink(void* context,
                  const amcl::input::GlfwRelativeSinkEvent& event) {
    // Already inside channel->mutex. SDL owns the final relative-motion event;
    // this path must not feed the process-wide GLFW look accumulator as well.
    auto* channel = static_cast<BackendChannel*>(context);
    if (backendOf(channel) != AMCL_BACKEND_INPUT_SDL3) {
        return;  // LWJGL2 retains its existing accumulated-cursor owner.
    }
    AmclBackendInputEvent out{};
    if (!amcl::input::EncodeBackendRelative(event, &out)) {
        const uint64_t count =
            g_relativeRejectCount.fetch_add(1u, std::memory_order_relaxed) + 1u;
        if ((count & (count - 1u)) == 0u) {
            OH_LOG_ERROR(LOG_APP,
                "backend relative rejected float overflow count=%{public}llu",
                static_cast<unsigned long long>(count));
        }
        return;
    }
    EnqueueLocked(channel, out);
}

void SurfaceContextSink(
        void* context,
        const amcl::input::GlfwSurfaceContextSinkEvent& event) {
    // All slots below are event-type specific.  No field is reinterpreted as a
    // key/wheel packet once eventType says SURFACE_CONTEXT.
    auto* channel = static_cast<BackendChannel*>(context);
    EnqueueLocked(channel, amcl::input::EncodeBackendSurfaceContext(event));
}

void TextSessionSink(
        void* context,
        const amcl::input::GlfwTextSessionSinkEvent& event) {
    auto* channel = static_cast<BackendChannel*>(context);
    AmclBackendInputEvent out = BlankEvent(
        AMCL_BACKEND_INPUT_EVENT_TEXT_SESSION);
    out.deviceId = event.textSessionId;
    out.code = static_cast<int32_t>(event.change);
    out.action = event.reason;
    out.sequence = event.sequence;
    out.monotonicTimeNs = event.monotonicTimeNs;
    EnqueueLocked(channel, out);
}

void TextCommitSink(
        void* context,
        const amcl::input::GlfwTextCommitSinkEvent& event) {
    auto* channel = static_cast<BackendChannel*>(context);
    AmclBackendInputEvent out = BlankEvent(
        AMCL_BACKEND_INPUT_EVENT_TEXT_COMMIT);
    out.sequence = event.sequence;
    out.monotonicTimeNs = event.monotonicTimeNs;
    (void)EnqueueTextLocked(channel, out, event.utf8);
}

void TextEditingSink(
        void* context,
        const amcl::input::GlfwTextEditingSinkEvent& event) {
    auto* channel = static_cast<BackendChannel*>(context);
    AmclBackendInputEvent out = BlankEvent(
        AMCL_BACKEND_INPUT_EVENT_TEXT_EDITING);
    out.action = event.selectionStart;
    out.modifiers = event.selectionLength;
    out.sequence = event.sequence;
    out.monotonicTimeNs = event.monotonicTimeNs;
    (void)EnqueueTextLocked(channel, out, event.utf8);
}

void TextCandidatesSink(
        void* context,
        const amcl::input::GlfwTextCandidatesSinkEvent& event) {
    auto* channel = static_cast<BackendChannel*>(context);
    std::vector<amcl::input::TextUtf8Span> spans(event.items.size());
    for (size_t index = 0u; index < event.items.size(); ++index) {
        spans[index].data = reinterpret_cast<const uint8_t*>(
            event.items[index].data());
        spans[index].byteCount = event.items[index].size();
    }
    size_t byteCount = 0u;
    if (amcl::input::EncodeTextCandidateBlob(
            spans.empty() ? nullptr : spans.data(), spans.size(), nullptr, 0u,
            &byteCount) != amcl::input::TextUtf8CodecStatus::kOk) {
        return;
    }
    std::vector<uint8_t> encoded(byteCount);
    size_t filled = 0u;
    if (amcl::input::EncodeTextCandidateBlob(
            spans.empty() ? nullptr : spans.data(), spans.size(),
            encoded.data(), encoded.size(), &filled) !=
            amcl::input::TextUtf8CodecStatus::kOk || filled != byteCount) {
        return;
    }
    AmclBackendInputEvent out = BlankEvent(
        AMCL_BACKEND_INPUT_EVENT_TEXT_CANDIDATES);
    out.action = event.selected;
    out.modifiers = event.pageStart;
    out.lockState = event.pageSize;
    out.resetReason = static_cast<uint32_t>(event.items.size());
    out.sequence = event.sequence;
    out.monotonicTimeNs = event.monotonicTimeNs;
    (void)EnqueueTextLocked(channel, out, encoded);
}

void TextSelectionSink(
        void* context,
        const amcl::input::GlfwTextSelectionSinkEvent& event) {
    auto* channel = static_cast<BackendChannel*>(context);
    AmclBackendInputEvent out = BlankEvent(
        AMCL_BACKEND_INPUT_EVENT_TEXT_SELECTION);
    out.deviceId = event.textSessionId;
    out.code = static_cast<int32_t>(event.selectionStart);
    out.action = event.selectionLength;
    out.sequence = event.sequence;
    out.monotonicTimeNs = event.monotonicTimeNs;
    EnqueueLocked(channel, out);
}

GlfwInputSink SinkFor(BackendChannel* channel, bool physicalRouteActive) {
    GlfwInputSink sink{};
    sink.context = channel;
    if (physicalRouteActive) {
        sink.key = KeySink;
        sink.button = ButtonSink;
        sink.wheel = WheelSink;
        sink.relative = RelativeSink;
        sink.focus = FocusSink;
        sink.capture = CaptureSink;
        sink.device = DeviceSink;
        sink.surfaceContext = SurfaceContextSink;
    }
    sink.reset = ResetSink;
    sink.textSession = TextSessionSink;
    sink.textCommit = TextCommitSink;
    sink.textEditing = TextEditingSink;
    sink.textCandidates = TextCandidatesSink;
    sink.textSelection = TextSelectionSink;
    // 19 个 sink 字段里本装配点接 14 个（物理 9 + 文本 5），另外 5 个逐条的理由在
    // scripts/check-typed-sink-wiring.mjs 的 SinkFor 例外表里，由门禁按站点
    // 校验（清单腐烂 —— 例外字段被接上了、或已从结构删除 —— 同样会红）。
    // relative 于 desktop SDL typed 合同接通；LWJGL2 在 RelativeSink 内仍保持旧 owner。
    return sink;
}

// ⭐ 本通道只在 typed 物理路由生效时才存在。**这是防重复投递的唯一判据**，理由必须完整
// 记住，因为它反直觉：
//
//   · bit10 **开**：物理边沿只进 core，不进 legacy ring（ring 的唯一写者 `sendEvent` 只在
//     legacy 路由上被调）⇒ 本通道拿物理、ring 拿虚拟/触控/手柄/字符，两者**不重叠**，
//     消费者必须**两条都读**。
//   · bit10 **关**：物理边沿**同时**进 core 与 ring —— core 提交在路由分叉**之前**且无条件
//     （`PlatformInputPhysicalKeyTransaction` 里 `SubmitPhysicalKeyLocked` 先跑）⇒ 若本通道
//     此时仍然出货，消费者会把每个键**收到两次**。
//
// ⇒ 所以闸门不能是"本通道解析到了吗"，必须是"typed 物理路由生效吗"。
// 读的是 host table 的能力位而**不是** `PlatformInputPhysicalRouteUsesTyped()`：后者定义在
// libentry，而本 TU 在 libglfw，按符号名反向引用会留一个 UND 且链接静默通过（§85 的坑）。
bool TypedPhysicalRouteActive(const AmclInputHostApiV1* api) {
    return api != nullptr &&
        (api->capabilityBits & AMCL_INPUT_CAP_GLFW_TYPED_PHYSICAL_ROUTE) != 0u;
}

bool TypedTextRouteActive(const AmclInputHostApiV1* api) {
    return api != nullptr &&
        (api->capabilityBits & AMCL_INPUT_CAP_TEXT_INPUT_SESSION) != 0u;
}

// 三种"拿不到事件"的成因，返回值必须不同（见头文件 NOT_READY 那段）。
enum class OpenOutcome {
    kOpen,
    kRouteInactive,  // 结构上不适用 ⇒ 消费者永久闭锁
    kNotReady,       // 适用但还没就绪 ⇒ 消费者下一帧再来
};

OpenOutcome EnsureOpenLocked(BackendChannel* channel, uint32_t backend) {
    if (channel->opened) return OpenOutcome::kOpen;
    // ⭐⭐ **必须走 descriptor 解析，不能用 `amclInputGetHostApiV1()`。** 后者返回**本 DSO
    // 副本自己的**那张表，而 libglfw.so 在进程里存在**两份**：一份是 libentry 的 DT_NEEDED
    // 依赖（会话由 ArkTS ingress 建在它的 core 上），一份被 MC 的 class loader namespace
    // dlopen（LWJGL3/SDL3 用它当 GL 库）。`glfwInit` 与 `amclBackendInputPublishAddress`
    // 都在**后者**里跑 ⇒ SDL 经 env 拿到的函数地址属于后者 ⇒ 本函数此前解析出来的是那份
    // **私有、无会话**的 core。后果实测（2026-08-25 真机）：`OpenConsumer` 在无会话时
    // 不播种基线却仍返回 OK ⇒ 第一次 `nextEvent` 返回 EMPTY ⇒ Open 恒 kBaselineRejected
    // （site=2 detail=1），SDL3 那条链**从来没有真正接上过**。
    //
    // ⚠️ 而路由位的门禁**挡不住这件事**：bit10 是编译期决定，**每一份副本都是 1** ⇒
    // "能力位为真"无法区分"这是正确的 core"与"这是一份私有复制品"。这正是 descriptor 机制
    // 存在的理由（`glfw_compat.cpp` 的 `ensureTypedInputOpen` 一直用的就是 Resolve），
    // 而新通道当时没有用它。⇒ 判据：**凡要拿 host table，只能经 Resolve；本地 getter 只有
    // 发布者自己能用。** 详见计划 §105。
    const AmclInputHostApiV1* api = nullptr;
    if (amclInputHostDescriptorResolveV1(&api) !=
        AMCL_INPUT_HOST_DESCRIPTOR_OK) {
        api = nullptr;
    }
    // ⚠️ host table 还没发布 ≠ 路由位没开。前者会好，后者不会 —— 此前两者都报
    // UNAVAILABLE，于是"SDL 抢在宿主之前拉一次"会把通道永久关掉。
    if (!api) return OpenOutcome::kNotReady;
    const bool physicalRouteActive = TypedPhysicalRouteActive(api);
    if (!physicalRouteActive && !TypedTextRouteActive(api)) {
        return OpenOutcome::kRouteInactive;
    }
    const amcl::input::GlfwInputMapper mapper =
        backend == AMCL_BACKEND_INPUT_LWJGL2
            ? amcl::input::Lwjgl2OhosInputMapper()
            : amcl::input::Sdl3OhosInputMapper();
    const GlfwAdapterStatus status = channel->adapter.Open(
        api, mapper, SinkFor(channel, physicalRouteActive), backend);
    if (status != GlfwAdapterStatus::kOk) {
        // 惰性重试而不是缓存失败：会话可能还没建立（Open 要求当前 active session）。
        // 一次性放弃会让"MC 起得比 surface 早"这种正常时序变成永久无输入。
        // ⚠️ 计数器必须是原子的：两条 channel 各持一把**不同的**锁，共享一个非原子
        // 静态量就是一处数据竞争（同一个 TU 里 g_wheelRejectCount 因同样理由已是 atomic）。
        static std::atomic<uint64_t> failures{0};
        const uint64_t count = failures.fetch_add(1u, std::memory_order_relaxed) + 1u;
        if ((count & (count - 1u)) == 0u) {
            // ⚠️ `site`/`detail` 是 2026-08-25 真机排查停在 status=4 之后加的：那个状态码
            // 把六个成因 collapse 成一个值，光靠它查不下去（计划 §105）。
            OH_LOG_WARN(LOG_APP,
                "backend adapter open deferred backend=%{public}u status=%{public}d "
                "site=%{public}u detail=%{public}d count=%{public}llu",
                backend, static_cast<int>(status),
                static_cast<unsigned>(channel->adapter.LastOpenRejectSite()),
                channel->adapter.LastOpenRejectDetail(),
                static_cast<unsigned long long>(count));
        }
        // ⚠️ `kInvalidConfiguration` 是**永久**失败（sink 表与能力位不匹配，重试不会变），
        // 其余是时序失败。但这里仍然一律报 NOT_READY 而不是 UNAVAILABLE：让消费者闭锁一条
        // "配置写错了"的通道，等于把一次可以在日志里看见的构建期错误变成永久静默降级。
        // 真正的判据是那条 power-of-two WARN —— 它会一直打，而闭锁之后什么都不会打。
        return OpenOutcome::kNotReady;
    }
    channel->opened = true;
    OH_LOG_INFO(LOG_APP,
        "backend typed consumer ready backend=%{public}u", backend);
    return OpenOutcome::kOpen;
}

// 端到端证据。**必须在 channel->mutex 内调用**（与本文件各 sink 同一条契约）。
//
// 节流用的是**键的**计数而不是总数：真机上滚轮一转就是几十条，用总数会让键的第一条边沿
// 被淹在滚轮里，而"键到没到"恰好是本次迁移最需要证明的那一条。各类累计值每次都
// 一起打，所以任何一行都是一份完整快照 —— 验收只需要 grep 最后一行。
void CountDeliveredLocked(BackendChannel* channel, uint32_t backend,
                          uint32_t eventType) {
    switch (eventType) {
        case AMCL_BACKEND_INPUT_EVENT_KEY: ++channel->deliveredKeys; break;
        case AMCL_BACKEND_INPUT_EVENT_BUTTON: ++channel->deliveredButtons; break;
        case AMCL_BACKEND_INPUT_EVENT_WHEEL: ++channel->deliveredWheels; break;
        case AMCL_BACKEND_INPUT_EVENT_RESET: ++channel->deliveredResets; break;
        case AMCL_BACKEND_INPUT_EVENT_FOCUS: ++channel->deliveredFocus; break;
        case AMCL_BACKEND_INPUT_EVENT_CAPTURE: ++channel->deliveredCapture; break;
        case AMCL_BACKEND_INPUT_EVENT_RELATIVE: ++channel->deliveredRelative; break;
        case AMCL_BACKEND_INPUT_EVENT_DEVICE: ++channel->deliveredDevices; break;
        case AMCL_BACKEND_INPUT_EVENT_SURFACE_CONTEXT:
            ++channel->deliveredSurfaceContexts; break;
        case AMCL_BACKEND_INPUT_EVENT_TEXT_SESSION:
        case AMCL_BACKEND_INPUT_EVENT_TEXT_COMMIT:
        case AMCL_BACKEND_INPUT_EVENT_TEXT_EDITING:
        case AMCL_BACKEND_INPUT_EVENT_TEXT_CANDIDATES:
        case AMCL_BACKEND_INPUT_EVENT_TEXT_SELECTION:
            ++channel->deliveredText; break;
        default: return;
    }
    const uint64_t keys = channel->deliveredKeys;
    const bool firstOfOther = keys == 0u &&
        channel->deliveredButtons + channel->deliveredWheels +
        channel->deliveredResets + channel->deliveredFocus +
        channel->deliveredCapture + channel->deliveredRelative +
        channel->deliveredDevices + channel->deliveredSurfaceContexts +
        channel->deliveredText == 1u;
    if (!firstOfOther && (keys == 0u || (keys & (keys - 1u)) != 0u)) return;
    OH_LOG_INFO(LOG_APP,
        "AMCL_BACKEND_DELIVERED backend=%{public}u keys=%{public}llu "
        "buttons=%{public}llu wheels=%{public}llu resets=%{public}llu "
        "focus=%{public}llu capture=%{public}llu "
        "relative=%{public}llu devices=%{public}llu contexts=%{public}llu "
        "text=%{public}llu "
        "dropped=%{public}llu overflow=%{public}llu",
        backend,
        static_cast<unsigned long long>(keys),
        static_cast<unsigned long long>(channel->deliveredButtons),
        static_cast<unsigned long long>(channel->deliveredWheels),
        static_cast<unsigned long long>(channel->deliveredResets),
        static_cast<unsigned long long>(channel->deliveredFocus),
        static_cast<unsigned long long>(channel->deliveredCapture),
        static_cast<unsigned long long>(channel->deliveredRelative),
        static_cast<unsigned long long>(channel->deliveredDevices),
        static_cast<unsigned long long>(channel->deliveredSurfaceContexts),
        static_cast<unsigned long long>(channel->deliveredText),
        static_cast<unsigned long long>(channel->droppedEvents),
        static_cast<unsigned long long>(channel->overflowCount));
}

}  // namespace

extern "C" AMCL_BACKEND_INPUT_PUBLIC int amclBackendInputNext(uint32_t backend,
                                    AmclBackendInputEvent* out) {
    if (!out) return AMCL_BACKEND_INPUT_ERROR_ARGUMENT;
    BackendChannel* channel = ChannelFor(backend);
    if (!channel) return AMCL_BACKEND_INPUT_ERROR_ARGUMENT;

    std::lock_guard<std::mutex> lock(channel->mutex);
    if (!channel->active) {
        /* Activation is an explicit presented-window lifecycle edge.  A pull
         * racing with SetActive(0) must never reopen the consumer and drain
         * input produced while the window is hidden or between generations. */
        // ⚠️ 这条早退**在 EnsureOpenLocked 之前**，所以它不会留下 `open deferred` 那一行。
        // 一个从未被激活的后端因此与"用户什么都没按"完全同形。计数在这里，让
        // "谁在拉、拉了多少次、一次都没被激活"变成可以数的数（AGENTS §二.3）。
        ++channel->inactivePulls;
        if ((channel->inactivePulls & (channel->inactivePulls - 1u)) == 0u) {
            OH_LOG_WARN(LOG_APP,
                "AMCL_BACKEND_INACTIVE backend=%{public}u pulls=%{public}llu "
                "(consumer is polling a channel nobody activated)",
                backend,
                static_cast<unsigned long long>(channel->inactivePulls));
        }
        return AMCL_BACKEND_INPUT_ERROR_NOT_READY;
    }
    switch (EnsureOpenLocked(channel, backend)) {
        case OpenOutcome::kOpen:
            break;
        case OpenOutcome::kRouteInactive:
            // 结构上不适用：legacy 路由，物理边沿在 ring 里 ⇒ 消费者只读 ring 并闭锁本通道。
            return AMCL_BACKEND_INPUT_ERROR_UNAVAILABLE;
        case OpenOutcome::kNotReady:
            // 适用但还没就绪 ⇒ 下一帧再来。两个消费者对"非 EVENT 且非 UNAVAILABLE"的处置
            // 都已经是"这一轮不取，下一轮再来"，所以这条不需要改它们任何一行。
            return AMCL_BACKEND_INPUT_ERROR_NOT_READY;
    }
    if (channel->queue.empty()) {
        // ⭐ pull 自己当泵。adapter 的 sink 在本调用栈里同步跑，所以 Pump 返回之后
        // 队列里就是本次新到的事件 —— 不需要常驻线程，也不依赖 glfwPollEvents
        // （SDL3 那条根本不调它）。
        const GlfwPumpResult pump = channel->adapter.Pump();
        if (pump.status != GlfwAdapterStatus::kOk &&
            pump.status != GlfwAdapterStatus::kOverflowReset) {
            /* A stale/session failure closes the adapter internally.  Do not
             * leave the channel's opened bit latched: the next active window
             * must establish a fresh consumer baseline instead of polling a
             * permanently not-ready adapter forever. */
            channel->opened = false;
        }
    }
    if (channel->queue.empty()) return AMCL_BACKEND_INPUT_EMPTY;
    *out = channel->queue.front();
    channel->queue.pop_front();
    CountDeliveredLocked(channel, backend, out->eventType);
    return AMCL_BACKEND_INPUT_EVENT;
}

extern "C" AMCL_BACKEND_INPUT_PUBLIC int amclBackendInputReadText(
        uint32_t backend, uint64_t packetId, uint8_t* outBytes,
        uint32_t capacity, uint32_t* outByteCount) {
    if (!outByteCount || (!outBytes && capacity != 0u) || packetId == 0u) {
        return AMCL_BACKEND_INPUT_ERROR_ARGUMENT;
    }
    BackendChannel* channel = ChannelFor(backend);
    if (!channel) return AMCL_BACKEND_INPUT_ERROR_ARGUMENT;
    std::lock_guard<std::mutex> lock(channel->mutex);
    const auto found = channel->textPackets.find(packetId);
    if (found == channel->textPackets.end()) {
        return AMCL_BACKEND_INPUT_ERROR_NOT_FOUND;
    }
    *outByteCount = static_cast<uint32_t>(found->second.size());
    if (capacity < found->second.size() ||
        (!outBytes && !found->second.empty())) {
        return AMCL_BACKEND_INPUT_ERROR_BUFFER_TOO_SMALL;
    }
    if (!found->second.empty()) {
        std::memcpy(outBytes, found->second.data(), found->second.size());
    }
    return AMCL_BACKEND_INPUT_EVENT;
}

extern "C" AMCL_BACKEND_INPUT_PUBLIC int amclBackendInputReadTextScalars(
        uint32_t backend, uint64_t packetId, uint32_t* outScalars,
        uint32_t capacity, uint32_t* outScalarCount) {
    if (!outScalarCount || (!outScalars && capacity != 0u) ||
        packetId == 0u) {
        return AMCL_BACKEND_INPUT_ERROR_ARGUMENT;
    }
    BackendChannel* channel = ChannelFor(backend);
    if (!channel) return AMCL_BACKEND_INPUT_ERROR_ARGUMENT;
    std::lock_guard<std::mutex> lock(channel->mutex);
    const auto found = channel->textPackets.find(packetId);
    if (found == channel->textPackets.end()) {
        return AMCL_BACKEND_INPUT_ERROR_NOT_FOUND;
    }
    size_t scalarCount = 0u;
    const amcl::input::TextUtf8CodecStatus status =
        amcl::input::DecodeTextUtf8Scalars(
            found->second.data(), found->second.size(), outScalars,
            static_cast<size_t>(capacity), &scalarCount);
    *outScalarCount = static_cast<uint32_t>(scalarCount);
    if (status == amcl::input::TextUtf8CodecStatus::kOutputTooSmall) {
        return AMCL_BACKEND_INPUT_ERROR_BUFFER_TOO_SMALL;
    }
    if (status != amcl::input::TextUtf8CodecStatus::kOk) {
        return AMCL_BACKEND_INPUT_ERROR_MALFORMED;
    }
    return AMCL_BACKEND_INPUT_EVENT;
}

extern "C" AMCL_BACKEND_INPUT_PUBLIC int amclBackendInputReleaseText(
        uint32_t backend, uint64_t packetId) {
    BackendChannel* channel = ChannelFor(backend);
    if (!channel || packetId == 0u) {
        return AMCL_BACKEND_INPUT_ERROR_ARGUMENT;
    }
    std::lock_guard<std::mutex> lock(channel->mutex);
    const auto found = channel->textPackets.find(packetId);
    if (found == channel->textPackets.end()) {
        return AMCL_BACKEND_INPUT_ERROR_NOT_FOUND;
    }
    channel->textPacketBytes -= found->second.size();
    channel->textPackets.erase(found);
    return AMCL_BACKEND_INPUT_EVENT;
}

extern "C" AMCL_BACKEND_INPUT_PUBLIC void amclBackendInputSetActive(uint32_t backend, int active) {
    BackendChannel* channel = ChannelFor(backend);
    if (!channel) return;
    std::lock_guard<std::mutex> lock(channel->mutex);
    channel->active = active != 0;
    if (!channel->active) {
        /* Retire the adapter consumer as well as this small output queue.  Merely
         * clearing the queue leaves GlfwInputAdapter's host cursor and held
         * aggregates alive; a later reactivation would replay edges produced
         * while the SDL window was hidden or between surface generations. */
        const GlfwAdapterStatus close_status = channel->adapter.Close();
        channel->opened = false;
        if (close_status != GlfwAdapterStatus::kOk) {
            OH_LOG_WARN(LOG_APP,
                        "backend input deactivate cleanup deferred backend-slot=%{public}d status=%{public}d",
                        static_cast<int>(channel - g_channels),
                        static_cast<int>(close_status));
        }
    }
    // 对齐到"此刻"：丢掉尚未被取的历史事件。**不重放**是刻意的 —— 重放会把 SDL 初始化
    // 之前按下的键注入进去，而那些键的 UP 早已过去。
    channel->droppedEvents += channel->queue.size();
    channel->queue.clear();
    channel->textPackets.clear();
    channel->textPacketBytes = 0u;
    // 滚轮余量同属"此刻之前的历史"：留着它会让下一次会话的第一格提前或延后到达。
    channel->wheelRemainderPx = 0.0;
}

extern "C" AMCL_BACKEND_INPUT_PUBLIC void amclBackendInputPublishAddress(void) {
    // 格式："AMCLBEIV:<ver>:<next>,<setActive>"（十进制 uintptr_t）。magic 与版本由
    // 消费侧严格校验：不匹配意味着两边版本不同，猜字段顺序等于调用任意代码。
    char buffer[128];
    std::snprintf(buffer, sizeof(buffer), "AMCLBEIV:%u:%llu,%llu",
                  AMCL_BACKEND_INPUT_ABI_VERSION,
                  static_cast<unsigned long long>(
                      reinterpret_cast<uintptr_t>(&amclBackendInputNext)),
                  static_cast<unsigned long long>(
                      reinterpret_cast<uintptr_t>(&amclBackendInputSetActive)));
    char textBuffer[192];
    std::snprintf(textBuffer, sizeof(textBuffer),
                  "AMCLBETV:%u:%llu,%llu,%llu",
                  AMCL_BACKEND_INPUT_ABI_VERSION,
                  static_cast<unsigned long long>(
                      reinterpret_cast<uintptr_t>(&amclBackendInputReadText)),
                  static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(
                      &amclBackendInputReadTextScalars)),
                  static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(
                      &amclBackendInputReleaseText)));
    setenv("AMCL_BACKEND_TEXT_BRIDGE", textBuffer, 1);
    // Publish the owned-packet descriptor first. A consumer that observes the
    // legacy descriptor is then guaranteed to find read/release functions too;
    // older hosts simply omit this independent variable and never emit text
    // packet event types.
    setenv("AMCL_BACKEND_INPUT_BRIDGE", buffer, 1);
    OH_LOG_INFO(LOG_APP,
        "backend input bridge published ver=%{public}u", AMCL_BACKEND_INPUT_ABI_VERSION);
}
