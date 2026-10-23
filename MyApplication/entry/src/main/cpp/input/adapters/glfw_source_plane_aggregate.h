#ifndef AMCL_GLFW_SOURCE_PLANE_AGGREGATE_H
#define AMCL_GLFW_SOURCE_PLANE_AGGREGATE_H

#include <cstdint>
#include <memory>
#include "../delivery/control_delivery.h"
#include "../delivery/look_execution.h"

namespace amcl::input {

// Source planes are deliberately coarser than physical contributors. The typed
// adapter already aggregates (deviceId, rawControl); this final GLFW boundary
// only prevents that typed aggregate and the legacy virtual/touch aggregate
// from releasing the same mapped GLFW control out from under each other.
enum class GlfwSourcePlane : uint32_t {
    kLegacy = 0,
    kTyped = 1,
};

enum class GlfwAggregateAction : int32_t {
    kRelease = 0,
    kPress = 1,
    kRepeat = 2,
};

struct GlfwAggregateKeyEvent {
    int32_t key;
    int32_t scanCode;
    GlfwAggregateAction action;
    int32_t modifiers;
    // 冻结的neutral receipt；实际ABI缓存与callback完成后报告，不改绑current。
    AmclControlEmissionV1 receipt{};
};

struct GlfwAggregateButtonEvent {
    int32_t button;
    GlfwAggregateAction action;
    int32_t modifiers;
    AmclControlEmissionV1 receipt{};
};

using GlfwAggregateKeySink = void (*)(
    void* context, const GlfwAggregateKeyEvent& event);
using GlfwAggregateButtonSink = void (*)(
    void* context, const GlfwAggregateButtonEvent& event);

struct GlfwAggregateSink {
    void* context = nullptr;
    GlfwAggregateKeySink key = nullptr;
    GlfwAggregateButtonSink button = nullptr;
};

// GLFW薄facade只借用neutral的opaque consumer，不再拥有另一份mapped-control归约状态。
// neutral先提交贡献，再在锁外调用实际GLFW出口；Minecraft可同步重入poll/input-mode。
// 未知UP、重复DOWN和未知repeat由共同owner明确Rejected；facade不伪造成功或额外边沿。
class GlfwSourcePlaneAggregate final {
public:
    GlfwSourcePlaneAggregate();
    ~GlfwSourcePlaneAggregate();
    GlfwSourcePlaneAggregate(const GlfwSourcePlaneAggregate&) = delete;
    GlfwSourcePlaneAggregate& operator=(
        const GlfwSourcePlaneAggregate&) = delete;

    void SubmitKey(GlfwSourcePlane plane, int32_t key, int32_t scanCode,
                   GlfwAggregateAction action, int32_t modifiers,
                   const GlfwAggregateSink& sink);
    void SubmitButton(GlfwSourcePlane plane, int32_t button,
                      GlfwAggregateAction action, int32_t modifiers,
                      const GlfwAggregateSink& sink);

    // Commits one button edge without invoking external code. This is the
    // publication-guarded runtime seam: callers may update GLFW polling state
    // and capture a callback while their target is protected, then notify the
    // user only after every lifecycle/publication guard has been released.
    bool CommitButton(GlfwSourcePlane plane, int32_t button,
                      GlfwAggregateAction action, int32_t modifiers,
                      GlfwAggregateButtonEvent* emission);

    // Clears only one source plane: a RELEASE is emitted only when the other
    // plane does not still own the mapped control.
    //
    // ⚠️ **Zero product callers (verified 2026-08-20).** The wording this
    // replaces -- "This models typed or legacy overflow/reset" -- was present
    // tense and therefore read as "this is how the two planes are reset". They
    // are not: both planes reset by emitting **per-control RELEASE edges** that
    // go through the ordinary Submit path.
    //   * typed  : `GlfwInputAdapter::Impl::ClearAggregatesLocked` emits one
    //              GlfwKeySinkEvent/GlfwButtonSinkEvent{kRelease} per held
    //              control, which lands in SubmitKey/CommitButton(kTyped, ...).
    //   * legacy : the ledger emits RELEASE -> routerKey -> bridgeKeyCallback ->
    //              SubmitKey(kLegacy, ...).
    // `glfw_compat.cpp` only ever calls ClearAll (window teardown) and Abandon
    // (proven no-window boundary). The only ClearPlane callers are host tests.
    //
    // Kept rather than deleted because it is the correct primitive if a plane
    // ever needs a bulk reset without per-control edges, and it is covered by
    // tests. But do not describe it as the current mechanism -- that is what
    // sent this audit looking for a reset path that does not exist.
    void ClearPlane(GlfwSourcePlane plane, const GlfwAggregateSink& sink);
    void ClearAll(const GlfwAggregateSink& sink);

    // Initialization may have no valid GLFWwindow callback target. Abandon is
    // therefore the only silent clear and is restricted to a proven no-window
    // boundary; runtime lifecycle uses ClearAll while the old window is alive.
    void Abandon();

    bool IsKeyPressed(int32_t key) const;
    bool IsButtonPressed(int32_t button) const;
    void BindTarget(uint64_t target);
    void ObservePoll(uint32_t kind,int32_t code,int32_t actualHeld);
    void Complete(const AmclControlEmissionV1& receipt,uint32_t phase);
    bool Validate(const AmclControlEmissionV1& receipt) const;
    bool Snapshot(AmclControlSnapshotV1& output) const;
    // 首次完整验证与control相同owner的look表；以后只复用进程期连接，不缓存窗口/票据Ready。
    const AmclLookExecutionPortV1* LookPort() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace amcl::input

#endif
