#ifndef AMCL_GLFW_TYPED_LOOK_ROUTE_H
#define AMCL_GLFW_TYPED_LOOK_ROUTE_H

#include <atomic>
#include <cstdint>

namespace amcl::input {

// 视角增量的加工**只有一份**，住在 libentry 的 `applyLookDelta` 漏斗里。typed 平面是
// 它的第二个**生产者**，不是第二套实现 —— 灵敏度 / 倒置 Y / 加速 / 端级量纲归一 /
// census / 端计数 / 守恒 backlog / 双坐标隔离 / grab 重锚 / floor 上报必须逐条共用，
// 否则"切到 typed 之后体验一模一样"这句话不成立。逐项对照见计划 §85。
//
// ⚠️ 为什么要一条 trampoline 而不是直接调：`typedRelativeSink` 住在 **libglfw.so**，
// 漏斗住在 **libentry.so**，而依赖方向是 libentry → libglfw。反向按符号名直接引用会
// 在 libglfw 里留一个 UND，而 glfw 目标的 link options **没有** `--no-undefined`
// ⇒ 链接静默通过、加载期才炸，且 `-fsyntax-only` 门禁抓不到（计划 §83.9.5 同型）。
// 仓里已有**三条**同方向 env trampoline：`AMCL_GRAB_CB`（`napi_input.cpp` 发布，
// `input_bridge_ohos.c` 的 `resolveGrabChangeCb` 消费）、`AMCL_TOUCH_GRAB_CB`、
// `AMCL_TOUCH_CANCEL_CB`。它们都是独立 env 变量、**不属于** v7 `OHOS_INPUT_BRIDGE`
// 那个 fail-closed 元组 ⇒ 加第四条**不需要升协议版本**。
// ⚠️ `AMCL_GRAB_CB` 尤其值得对照：它的发布点是一个 ArkTS 显式调用的 NAPI 方法，
// **本来就不在 `resolveBridge` 里** —— 那就是"publish 必须与 bridge-resolve 解耦"的
// 仓内既有先例（本条同样这么做，见 `publishReverseTrampolines`）。
using GlfwTypedLookSink = bool (*)(double dx, double dy);

enum class GlfwTypedLookStatus : uint8_t {
    kApplied = 0,
    kNoSink = 1,
    kNonFinite = 2,
    kSinkRejected = 3,
};

// 从 env 文本解析 trampoline 地址。0 = 拒绝。
// 单独抽出来的理由：**静默解析失败**正是这类反向通道最容易出的问题，而它可以 host 测。
uintptr_t ParseGlfwTypedLookTrampoline(const char* text);

// ⚠️ 线程契约（**上一版写错了，别照那句读**）：`Latch` / `Apply` 必须在 adapter 的
// `callbackMutex` 内调用 —— 让 `sink_` 非 atomic 合法的是**那把互斥量提供的
// happens-before**，不是"这条路上只有一个线程"。事实相反：`glfwPollEvents` 明确允许在
// ArkUI/主线程与渲染线程之间漂移（`glfw_compat.cpp` 自述），所以写者线程不唯一。
// `rejectCount_` 是 atomic，因为它**另有一个锁外读者**（诊断面 `glfwOHOS_GetCompatInfo`）。
class GlfwTypedLookRoute final {
public:
    // 一次性闭锁：解析成功后不接受被换掉，也不接受被 nullptr 清掉。须在 callbackMutex 内。
    bool Latch(GlfwTypedLookSink sink);
    bool HasSink() const;

    // 非有限值**绝不跨 DSO**：在这里 fail closed，漏斗的持久 backlog 不可被污染。
    // 须在 callbackMutex 内调用。
    GlfwTypedLookStatus Apply(double dx, double dy);

    // 唯一的拒绝计数。**刻意不另立一个** —— 同一件事有两个计数器、其中一个从诊断面取不到，
    // 是本仓已经清理过两次的形状（规范 §九 的两条墓碑）。可在锁外读。
    uint64_t RejectCount() const;

private:
    GlfwTypedLookSink sink_ = nullptr;
    std::atomic<uint64_t> rejectCount_{0u};
};

}  // namespace amcl::input

#endif
