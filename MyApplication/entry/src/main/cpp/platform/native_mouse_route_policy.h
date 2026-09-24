#ifndef AMCL_NATIVE_MOUSE_ROUTE_POLICY_H
#define AMCL_NATIVE_MOUSE_ROUTE_POLICY_H

#include <cstdint>

namespace amcl::input {

enum class NativeMouseSampleKind : uint8_t {
    Move = 0,
    ButtonEdge = 1,
};

enum class NativeMouseDispatchRoute : uint8_t {
    // The existing ArkTS raw-relative path owns movement. Native must emit no
    // absolute event, otherwise a grabbed sample can move the camera twice.
    RelativeMoveOwner = 0,
    // Existing physical-button ingress: one button event, no position binding.
    ButtonOnly = 1,
    // Verified normal/menu path: one surface-local POINTER_ABSOLUTE event.
    MenuAbsoluteMove = 2,
    // Verified normal/menu path: atomic [absolute, button] typed batch.
    MenuAbsoluteButtonBatch = 3,
};

// ArkTS observes physical mouse MOVE samples, but it is not authoritative for
// grab state. Every sample crosses one native transaction and is classified
// against the bridge SSOT, the current surface generation and reset epoch.
enum class ArktsPhysicalMotionRoute : uint8_t {
    Drop = 0,
    RawRelative = 1,
    UnverifiedRelativeFallback = 2,
    LegacyMenuAbsolute = 3,
    NativeMenuAbsoluteOwner = 4,
};

struct ArktsPhysicalMotionSample {
    uint64_t surfaceGeneration = 0;
    uint64_t resetEpoch = 0;
    bool grabStateKnown = false;
    bool grabbed = false;
    bool verifiedNativeAbsolute = false;
    bool rawDeltaPresent = false;
    double rawDx = 0.0;
    double rawDy = 0.0;
    double windowX = 0.0;
    double windowY = 0.0;
};

struct ArktsPhysicalMotionDecision {
    ArktsPhysicalMotionRoute route = ArktsPhysicalMotionRoute::Drop;
    double first = 0.0;
    double second = 0.0;
};

class ArktsPhysicalMotionState final {
public:
    ArktsPhysicalMotionDecision Consume(
        const ArktsPhysicalMotionSample& sample);
    void Reset();

private:
    uint64_t surfaceGeneration_ = 0;
    uint64_t resetEpoch_ = 0;
    bool modeKnown_ = false;
    bool grabbed_ = false;
    bool windowBaselineValid_ = false;
    double windowX_ = 0.0;
    double windowY_ = 0.0;
};

// This is a synchronous callback policy, not a page/UI capability guess.
// `grabStateKnown` is true only when inputBridge_isGrabbing() was resolved and
// sampled. Unknown state fails closed to the established move/button routes.
NativeMouseDispatchRoute DecideNativeMouseDispatchRoute(
    bool verifiedNativeAbsolute, bool grabStateKnown, bool grabbed,
    NativeMouseSampleKind sampleKind);

// ⚠️ 这里曾有 `SuppressNormalMouseSynthTouch(verifiedNativeAbsolute, grabbed,
// sourceIsMouseSynth)`，自身注释已标为 "SUPERSEDED — no product caller"，只被测试引用。
// **已删除。**
//
// 删除理由不只是"没人调"：它把"鼠标绝不能驱动虚拟控件"这条**三端隔离的硬约束**
// 做成了条件式 —— 依赖一个默认关闭的构建期证据位，并且完全豁免 grabbed 模式。
// 那正是当初鼠标能按下虚拟按键的原因。现在 OnDispatchTouchEvent 对任何被判为鼠标的包
// **在两种模式下都无条件拒收**，与构建开关无关。保留一个反面示例的声明只会让人以为
// 那条约束仍有可配置空间。

}  // namespace amcl::input

#endif
