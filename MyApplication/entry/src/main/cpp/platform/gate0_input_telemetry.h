#ifndef AMCL_GATE0_INPUT_TELEMETRY_H
#define AMCL_GATE0_INPUT_TELEMETRY_H

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Diagnostic-only observers. They never submit, enqueue, stop propagation or
// mutate the surface/input state. The implementation is linked only when the
// AMCL_INPUT_GATE0_TELEMETRY CMake option is ON.
enum AmclGate0ArktsMousePresence : uint32_t {
    AMCL_GATE0_ARKTS_DEVICE_PRESENT = 1u << 0,
    AMCL_GATE0_ARKTS_GLOBAL_PRESENT = 1u << 1,
    AMCL_GATE0_ARKTS_RAW_PRESENT = 1u << 2,
    AMCL_GATE0_ARKTS_PRESSED_BUTTONS_PRESENT = 1u << 3,
};

typedef struct AmclGate0ArktsMouseSample {
    uint64_t timestamp;
    int64_t deviceId;
    int32_t source;
    int32_t sourceTool;
    int32_t action;
    int32_t button;
    uint32_t presence;
    uint32_t pressedButtonCount;
    uint32_t mouseCapability;
    uint32_t mcStarted;
    uint32_t grabbed;
    double localX;
    double localY;
    double windowX;
    double windowY;
    double displayX;
    double displayY;
    double globalX;
    double globalY;
    double rawDx;
    double rawDy;
    double density;
} AmclGate0ArktsMouseSample;

// Observes how a TouchEvent packet was classified by source. This is the
// evidence needed to decide whether "mouse must never reach the virtual
// controls" can rely on the platform's tool/source metadata, or whether the
// metadata is unavailable and the packet falls into the touch-treated unknown
// bucket. Diagnostic only: it never changes the classification.
typedef struct AmclGate0TouchSourceSample {
    int32_t pointerId;
    int32_t eventType;
    int32_t numPoints;
    // 0 = the changed point could not be located in touchPoints[] (or numPoints
    // was unusable), which is an early exit that previously had no telemetry at
    // all and is the most likely landing spot for a synthesized mirror packet.
    int32_t changedIndexFound;
    int32_t toolQueryRc;
    int32_t toolType;
    int32_t sourceQueryRc;
    int32_t sourceType;
    int32_t classified;
    double x;
    double y;
} AmclGate0TouchSourceSample;

// Wheel channel liveness. Emitted on entry and at every early exit so a wheel
// that never reaches Minecraft can be told apart from one that is dropped by a
// gate, by pause, by a zero value, or by the sign/step conversion.
typedef struct AmclGate0AxisSample {
    int32_t gateAccepted;
    int32_t componentOnlySafe;
    int32_t touchPaused;
    int32_t typedRoute;
    int32_t axisAction;
    int32_t scrollStep;
    int32_t outcome;      // AmclLegacyPhysicalOutcome, -1 before routing
    uint64_t generation;
    double verticalValue;
    double horizontalValue;
} AmclGate0AxisSample;

// One ArkUI button edge exactly as received by native, plus the decision. This
// is where a device that reports MouseButton.None becomes visible.
typedef struct AmclGate0ArkuiButtonSample {
    int64_t deviceId;
    int32_t buttonMask;
    int32_t action;
    int32_t mappedGlfwButton;  // -1 = refused
    int32_t gateOk;
    int32_t claimed;
} AmclGate0ArkuiButtonSample;

void amcl_gate0_trace_native_mouse(
    OH_NativeXComponent* component, const void* window,
    uint64_t publicationGeneration,
    const OH_NativeXComponent_MouseEvent* event);
void amcl_gate0_trace_touch_source(const AmclGate0TouchSourceSample* sample);
void amcl_gate0_trace_axis(const AmclGate0AxisSample* sample);
void amcl_gate0_trace_arkui_button(const AmclGate0ArkuiButtonSample* sample);
void amcl_gate0_trace_arkts_mouse(const AmclGate0ArktsMouseSample* sample);
void amcl_gate0_trace_probe_ready(void);

#ifdef __cplusplus
}
#endif

#endif
