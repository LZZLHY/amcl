#include "gate0_input_telemetry.h"

#include "gate0_sample_throttle.h"

#include <atomic>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "AMCL_GATE0_INPUT"

namespace {

// 限流策略的唯一真相在 gate0_sample_throttle.h，那里有 host 测试逐边界钉住。
// 这里只保留别名，禁止在本文件复制一份常量 —— 两份阈值一旦分叉，probe-ready 日志
// 报告的采样率就会与实际输出不符，取证时无法判断样本是不是完整的。
using amcl::gate0::kFullRateSampleLimit;
using amcl::gate0::kTailSampleStride;
using amcl::gate0::ShouldEmitSample;

std::atomic<uint64_t> gNativeMouseSequence{0u};
std::atomic<uint64_t> gArkTsMouseSequence{0u};
std::atomic<uint64_t> gTouchSourceSequence{0u};
std::atomic<uint64_t> gAxisSequence{0u};
std::atomic<uint64_t> gArkuiButtonSequence{0u};

bool ShouldEmit(uint64_t sequence) { return ShouldEmitSample(sequence); }

}  // namespace

extern "C" void amcl_gate0_trace_native_mouse(
        OH_NativeXComponent* component, const void* window,
        uint64_t publicationGeneration,
        const OH_NativeXComponent_MouseEvent* event) {
    if (!component || !window || !event || publicationGeneration == 0u) return;
    const uint64_t sequence =
        gNativeMouseSequence.fetch_add(1u, std::memory_order_relaxed) + 1u;
    if (!ShouldEmit(sequence)) return;

    uint64_t width = 0u;
    uint64_t height = 0u;
    double offsetX = 0.0;
    double offsetY = 0.0;
    const int32_t sizeResult = OH_NativeXComponent_GetXComponentSize(
        component, window, &width, &height);
    const int32_t offsetResult = OH_NativeXComponent_GetXComponentOffset(
        component, window, &offsetX, &offsetY);

    OH_LOG_INFO(
        LOG_APP,
        "AMCL_GATE0 sample kind=native seq=%{public}llu gen=%{public}llu "
        "ts=%{public}lld action=%{public}d button=%{public}d "
        "localX=%{public}.6f localY=%{public}.6f "
        "screenX=%{public}.6f screenY=%{public}.6f "
        "surfaceW=%{public}llu surfaceH=%{public}llu "
        "offsetX=%{public}.6f offsetY=%{public}.6f "
        "sizeRc=%{public}d offsetRc=%{public}d",
        static_cast<unsigned long long>(sequence),
        static_cast<unsigned long long>(publicationGeneration),
        static_cast<long long>(event->timestamp),
        static_cast<int>(event->action), static_cast<int>(event->button),
        static_cast<double>(event->x), static_cast<double>(event->y),
        static_cast<double>(event->screenX),
        static_cast<double>(event->screenY),
        static_cast<unsigned long long>(width),
        static_cast<unsigned long long>(height), offsetX, offsetY,
        sizeResult, offsetResult);
}

extern "C" void amcl_gate0_trace_arkts_mouse(
        const AmclGate0ArktsMouseSample* sample) {
    if (!sample) return;
    const uint64_t sequence =
        gArkTsMouseSequence.fetch_add(1u, std::memory_order_relaxed) + 1u;
    if (!ShouldEmit(sequence)) return;

    OH_LOG_INFO(
        LOG_APP,
        "AMCL_GATE0 sample kind=arkts seq=%{public}llu ts=%{public}llu "
        "presence=%{public}u deviceId=%{public}lld source=%{public}d "
        "tool=%{public}d action=%{public}d button=%{public}d "
        "pressed=%{public}u mouseCap=%{public}u mcStarted=%{public}u "
        "grabbed=%{public}u density=%{public}.6f "
        "localX=%{public}.6f localY=%{public}.6f "
        "windowX=%{public}.6f windowY=%{public}.6f "
        "displayX=%{public}.6f displayY=%{public}.6f "
        "globalX=%{public}.6f globalY=%{public}.6f "
        "rawDx=%{public}.6f rawDy=%{public}.6f",
        static_cast<unsigned long long>(sequence),
        static_cast<unsigned long long>(sample->timestamp), sample->presence,
        static_cast<long long>(sample->deviceId), sample->source,
        sample->sourceTool, sample->action, sample->button,
        sample->pressedButtonCount, sample->mouseCapability,
        sample->mcStarted, sample->grabbed, sample->density,
        sample->localX, sample->localY, sample->windowX, sample->windowY,
        sample->displayX, sample->displayY, sample->globalX,
        sample->globalY, sample->rawDx, sample->rawDy);
}

extern "C" void amcl_gate0_trace_touch_source(
        const AmclGate0TouchSourceSample* sample) {
    if (!sample) return;
    const uint64_t sequence =
        gTouchSourceSequence.fetch_add(1u, std::memory_order_relaxed) + 1u;
    if (!ShouldEmit(sequence)) return;

    OH_LOG_INFO(
        LOG_APP,
        "AMCL_GATE0 sample kind=touchsrc seq=%{public}llu id=%{public}d "
        "type=%{public}d points=%{public}d changedFound=%{public}d "
        "toolRc=%{public}d tool=%{public}d srcRc=%{public}d src=%{public}d "
        "classified=%{public}d x=%{public}.3f y=%{public}.3f",
        static_cast<unsigned long long>(sequence), sample->pointerId,
        sample->eventType, sample->numPoints, sample->changedIndexFound,
        sample->toolQueryRc, sample->toolType, sample->sourceQueryRc,
        sample->sourceType, sample->classified, sample->x, sample->y);
}

extern "C" void amcl_gate0_trace_axis(const AmclGate0AxisSample* sample) {
    if (!sample) return;
    const uint64_t sequence =
        gAxisSequence.fetch_add(1u, std::memory_order_relaxed) + 1u;
    if (!ShouldEmit(sequence)) return;

    OH_LOG_INFO(
        LOG_APP,
        "AMCL_GATE0 sample kind=axis seq=%{public}llu gate=%{public}d "
        "gen=%{public}llu componentSafe=%{public}d paused=%{public}d "
        "typedRoute=%{public}d axisAction=%{public}d vy=%{public}.6f "
        "vx=%{public}.6f scrollStep=%{public}d outcome=%{public}d",
        static_cast<unsigned long long>(sequence), sample->gateAccepted,
        static_cast<unsigned long long>(sample->generation),
        sample->componentOnlySafe, sample->touchPaused, sample->typedRoute,
        sample->axisAction, sample->verticalValue, sample->horizontalValue,
        sample->scrollStep, sample->outcome);
}

extern "C" void amcl_gate0_trace_arkui_button(
        const AmclGate0ArkuiButtonSample* sample) {
    if (!sample) return;
    const uint64_t sequence =
        gArkuiButtonSequence.fetch_add(1u, std::memory_order_relaxed) + 1u;
    if (!ShouldEmit(sequence)) return;

    OH_LOG_INFO(
        LOG_APP,
        "AMCL_GATE0 sample kind=arkuibtn seq=%{public}llu device=%{public}lld "
        "mask=%{public}d action=%{public}d mapped=%{public}d gate=%{public}d "
        "claimed=%{public}d",
        static_cast<unsigned long long>(sequence),
        static_cast<long long>(sample->deviceId), sample->buttonMask,
        sample->action, sample->mappedGlfwButton, sample->gateOk,
        sample->claimed);
}

extern "C" void amcl_gate0_trace_probe_ready(void) {
    OH_LOG_INFO(
        LOG_APP,
        "AMCL_GATE0 probe ready arktsProductionObserver=1 "
        "nativeMouseObserver=1 richNativeUiMouseObserver=0 "
        "fullRateLimit=%{public}llu tailStride=%{public}llu",
        static_cast<unsigned long long>(kFullRateSampleLimit),
        static_cast<unsigned long long>(kTailSampleStride));
}
