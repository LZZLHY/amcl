#include "../../input/adapters/glfw_source_plane_aggregate.h"

#include "backend_input_bridge_host_stub.h"

#include <array>
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <thread>
#include <vector>

using namespace amcl::input;

using KeyCallback = void (*)(void*, int, int, int, int);
using ButtonCallback = void (*)(void*, int, int, int);
using CharCallback = void (*)(void*, unsigned int);
void inputBridge_setKeyCallback(KeyCallback callback);
void inputBridge_setMouseButtonCallback(ButtonCallback callback);
void* inputBridge_replaceCharCallback(void* callback);
void inputBridge_dispatchCharCodepoint(void* window, unsigned int codepoint);
void inputBridge_pushEvent(int type, int i1, int i2, int i3, int i4);
void inputBridgeStartPumping();
void inputBridgePumpEvents(void* window);
void inputBridgeStopPumping();
void inputBridge_notifyFramePresented();
void inputBridge_cancelAllState(void* window, int reason);
void inputBridge_addLookDelta(double dx, double dy);
void inputBridge_setMenuCursor(double x, double y);
void inputBridge_getCursorSnapshot(double* outX, double* outY);
void inputBridge_setLookCursor(double x, double y);
void inputBridge_setGrabState(int grabbing);
int inputBridge_beginPhysicalMotionTransaction(int* outGrabbing);
void inputBridge_endPhysicalMotionTransaction();
unsigned long long inputBridge_testInvalidCursorWriteCount();
unsigned long long inputBridge_testUnknownRingEventCount();
unsigned long long inputBridge_testLookLatencySamples();
int inputBridge_testLookLatencyPending();
unsigned long long inputBridge_testPumpCalls();
unsigned long long inputBridge_testDrainedRingEvents();
// ⚠️ 此前从未在测试里被调用 ⇒ 整条 cursor 上报路径零覆盖（计划 §107.12）。
void inputBridge_setCursorPosCallback(void (*cb)(void*, double, double));
unsigned int inputBridge_testGrabWriterWaiters();
int inputBridge_l2NextEvent(int* outType, int* o1, int* o2, int* o3, int* o4);
void inputBridge_sdlSetActive(int active);
void inputBridge_sdlNotifyFramePresented();
int inputBridge_sdlNextEvent(int* outType, int* o1, int* o2, int* o3, int* o4);

namespace {
constexpr int kKeyEvent = 1005;
constexpr int kButtonEvent = 1006;
constexpr int kMenuEvent = 1008;
constexpr int kInputResetEvent = 1009;
constexpr int kPress = 1;
constexpr int kRelease = 0;
constexpr int kMenuMove = 0;
constexpr int kMenuDown = 1;
constexpr int kMenuUp = 2;
constexpr int kMenuCancel = 3;

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "GLFW RUNTIME BRIDGE FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

struct Harness {
    GlfwSourcePlaneAggregate aggregate;
    std::array<int, 512> keys{};
    std::array<int, 16> buttons{};
    std::vector<GlfwAggregateKeyEvent> keyCallbacks;
    std::vector<GlfwAggregateButtonEvent> buttonCallbacks;
    bool committedBeforeCallback = true;
    // cursor 上报的观测面。⚠️ 在 look 时延用例之前，本套件**没有**注册 cursorPos 回调，
    // 于是 bridge 的 `g_invoke_CursorPos` 恒 NULL、整条上报路径不可达（计划 §107.12）。
    int cursorCallbacks = 0;
    double lastCursorX = 0.0;
    double lastCursorY = 0.0;
    std::vector<unsigned int> chars;

    static void Char(void* window, unsigned int codepoint) {
        if (!window) return;
        static_cast<Harness*>(window)->chars.push_back(codepoint);
    }

    static void LegacyCursorPos(void* window, double x, double y) {
        // bridge 用 `g_lastPumpWindow` 作为 window 实参，测试里就是 &harness。
        if (!window) return;
        auto& self = *static_cast<Harness*>(window);
        self.cursorCallbacks++;
        self.lastCursorX = x;
        self.lastCursorY = y;
    }

    static void DispatchKey(void* context,
                            const GlfwAggregateKeyEvent& event) {
        auto& self = *static_cast<Harness*>(context);
        const bool pressed = event.action != GlfwAggregateAction::kRelease;
        self.keys[static_cast<size_t>(event.key)] = pressed ? 1 : 0;
        self.committedBeforeCallback &=
            self.aggregate.IsKeyPressed(event.key) == pressed;
        self.keyCallbacks.push_back(event);
    }

    static void DispatchButton(void* context,
                               const GlfwAggregateButtonEvent& event) {
        auto& self = *static_cast<Harness*>(context);
        const bool pressed = event.action != GlfwAggregateAction::kRelease;
        self.buttons[static_cast<size_t>(event.button)] = pressed ? 1 : 0;
        self.committedBeforeCallback &=
            self.aggregate.IsButtonPressed(event.button) == pressed;
        self.buttonCallbacks.push_back(event);
    }

    GlfwAggregateSink Sink() {
        return {this, DispatchKey, DispatchButton};
    }

    static void LegacyKey(void* context, int key, int scanCode,
                          int action, int modifiers) {
        auto& self = *static_cast<Harness*>(context);
        self.aggregate.SubmitKey(
            GlfwSourcePlane::kLegacy, key, scanCode,
            static_cast<GlfwAggregateAction>(action), modifiers, self.Sink());
    }

    static void LegacyButton(void* context, int button, int action,
                             int modifiers) {
        auto& self = *static_cast<Harness*>(context);
        self.aggregate.SubmitButton(
            GlfwSourcePlane::kLegacy, button,
            static_cast<GlfwAggregateAction>(action), modifiers, self.Sink());
    }
};

void Pump(Harness& harness) {
    inputBridgeStartPumping();
    inputBridgePumpEvents(&harness);
    inputBridgeStopPumping();
}

void TestRealRingAndCrossPlaneOwnership(Harness& harness) {
    inputBridge_pushEvent(kKeyEvent, 65, 30, kPress, 1);
    inputBridge_pushEvent(kButtonEvent, 1, kPress, 2, 0);
    Pump(harness);
    CHECK(harness.keys[65] == 1);
    CHECK(harness.buttons[1] == 1);

    const size_t keyEdges = harness.keyCallbacks.size();
    harness.aggregate.SubmitKey(GlfwSourcePlane::kTyped, 65, 31,
                                GlfwAggregateAction::kPress, 0,
                                harness.Sink());
    CHECK(harness.keyCallbacks.size() == keyEdges);
    inputBridge_pushEvent(kKeyEvent, 65, 30, kRelease, 0);
    Pump(harness);
    CHECK(harness.keys[65] == 1);
    CHECK(harness.keyCallbacks.size() == keyEdges);
    harness.aggregate.SubmitKey(GlfwSourcePlane::kTyped, 65, 31,
                                GlfwAggregateAction::kRelease, 0,
                                harness.Sink());
    CHECK(harness.keys[65] == 0);

    inputBridge_pushEvent(kButtonEvent, 1, kRelease, 0, 0);
    Pump(harness);
    CHECK(harness.buttons[1] == 0);
}

void TestDirectTypedCommitCallback(Harness& harness) {
    (void)inputBridge_replaceCharCallback(
        reinterpret_cast<void*>(Harness::Char));
    inputBridge_dispatchCharCodepoint(&harness, 0x4e2du);
    inputBridge_dispatchCharCodepoint(&harness, 0x1f600u);
    CHECK(harness.chars.size() == 2u);
    CHECK(harness.chars[0] == 0x4e2du);
    CHECK(harness.chars[1] == 0x1f600u);
}

// 未知 ring 事件必须被数出来，而**刻意忽略的 1009 不能被算进去**（因果见计划 §107.5）。
void TestUnknownRingEventIsCountedButResetIsNot(Harness& harness) {
    const unsigned long long before = inputBridge_testUnknownRingEventCount();

    // 1009 刻意无操作 ⇒ 计数**不得**变化。
    inputBridge_pushEvent(kInputResetEvent, 0, 0, 0, 0);
    Pump(harness);
    CHECK(inputBridge_testUnknownRingEventCount() == before);

    // 1003 / 1004 是 Pojav 原版的 FramebufferSize / WindowSize，本项目刻意不从 ring 走
    // （尺寸回调由 glfw_compat 在接受 surface 对时直接发）⇒ 它们是真正的未知类型。
    inputBridge_pushEvent(1003, 1, 2, 3, 4);
    Pump(harness);
    CHECK(inputBridge_testUnknownRingEventCount() == before + 1u);

    // 越界值同样要被数到，而不是靠"不会有人推它"这个假设。
    inputBridge_pushEvent(424242, 0, 0, 0, 0);
    Pump(harness);
    CHECK(inputBridge_testUnknownRingEventCount() == before + 2u);

    // 未知类型不得污染任何轮询状态：它只该被数一下然后丢弃。
    CHECK(harness.keys[65] == 0);
    CHECK(harness.buttons[1] == 0);
}

// ⭐ GLFW3 pump 的端到端计数（AGENTS.md §二.3，因果见计划 §114）：在它之前，"pump 在跑
// 但 ring 里一条都没来过"与"工作正常"在日志与测试里都长得一模一样。
void TestPumpDrainCountersAreMonotonic(Harness& harness) {
    const unsigned long long pollsBefore = inputBridge_testPumpCalls();
    const unsigned long long drainedBefore = inputBridge_testDrainedRingEvents();

    // 空 ring：poll 计数照涨，出货计数必须一动不动 —— 这一对就是那个故障的指纹。
    Pump(harness);
    CHECK(inputBridge_testPumpCalls() == pollsBefore + 1u);
    CHECK(inputBridge_testDrainedRingEvents() == drainedBefore);

    inputBridge_pushEvent(kKeyEvent, 70, 36, kPress, 0);
    inputBridge_pushEvent(kKeyEvent, 70, 36, kRelease, 0);
    Pump(harness);
    CHECK(inputBridge_testPumpCalls() == pollsBefore + 2u);
    CHECK(inputBridge_testDrainedRingEvents() == drainedBefore + 2u);
    CHECK(harness.keys[70] == 0);

    // 数的是 ring 的流量，**不是**回调数（后者会被未注册回调 / grabbed / 菜单屏障等
    // 合法情形拉低）⇒ 刻意无操作的 1009 也必须计入。
    inputBridge_pushEvent(kInputResetEvent, 0, 0, 0, 0);
    Pump(harness);
    CHECK(inputBridge_testDrainedRingEvents() == drainedBefore + 3u);
}

// look 样本的 in→out 时延埋点（计划 §107.12）。三条判据都是设计要点，错一条这个量就没意义。
void TestLookLatencyMeasuresFirstQueuedSample(Harness& harness) {
    inputBridge_setGrabState(1);   // 前提：menu 态的快照读 g_menuX/Y，look 增量不会驱动上报
    Pump(harness);                 // 排掉进入本用例前可能压着的待报样本
    const unsigned long long before = inputBridge_testLookLatencySamples();

    // 判据①：一次真实位移 ⇒ 恰好结算一条，且 cursor 真的被上报了一次。
    const int cursorBefore = harness.cursorCallbacks;
    inputBridge_addLookDelta(12.0, 7.0);
    CHECK(inputBridge_testLookLatencyPending() == 1);
    Pump(harness);
    CHECK(harness.cursorCallbacks == cursorBefore + 1);   // 上报路径真的走到了
    CHECK(inputBridge_testLookLatencyPending() == 0);
    CHECK(inputBridge_testLookLatencySamples() == before + 1u);

    // 判据②：**一轮里的多个样本只算一条**（pending 只由第一个置位）。测的是"第一个样本
    // 等了多久"，若被后续样本覆盖，测出来的永远接近 0 —— 那个量没有判读价值。
    inputBridge_addLookDelta(1.0, 0.0);
    inputBridge_addLookDelta(1.0, 0.0);
    inputBridge_addLookDelta(1.0, 0.0);
    Pump(harness);
    CHECK(inputBridge_testLookLatencySamples() == before + 2u);

    // 判据③：零增量被去重吞掉时**不结算**，待报样本保留到下一次真上报。
    inputBridge_addLookDelta(0.0, 0.0);
    CHECK(inputBridge_testLookLatencyPending() == 1);
    Pump(harness);
    CHECK(inputBridge_testLookLatencyPending() == 1);           // 仍压着
    CHECK(inputBridge_testLookLatencySamples() == before + 2u); // 未结算
    inputBridge_addLookDelta(3.0, 0.0);
    Pump(harness);
    CHECK(inputBridge_testLookLatencyPending() == 0);
    CHECK(inputBridge_testLookLatencySamples() == before + 3u);
}

void TestPendingAndConsumedWindowCancel(Harness& harness) {
    const size_t beforePending = harness.keyCallbacks.size();
    inputBridge_pushEvent(kKeyEvent, 66, 32, kPress, 0);
    inputBridge_cancelAllState(&harness, 5);
    Pump(harness);
    CHECK(harness.keyCallbacks.size() == beforePending);
    CHECK(harness.keys[66] == 0);

    inputBridge_pushEvent(kKeyEvent, 67, 33, kPress, 0);
    Pump(harness);
    CHECK(harness.keys[67] == 1);
    const size_t beforeCancel = harness.keyCallbacks.size();
    inputBridge_cancelAllState(&harness, 5);
    CHECK(harness.keys[67] == 0);
    CHECK(harness.keyCallbacks.size() == beforeCancel + 1u);
    CHECK(harness.keyCallbacks.back().action ==
          GlfwAggregateAction::kRelease);
    Pump(harness);
    CHECK(harness.keyCallbacks.size() == beforeCancel + 1u);
}

void TestMenuAndOverflowRecovery(Harness& harness) {
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 10, 20, 77);
    Pump(harness);
    CHECK(harness.buttons[0] == 0);
    inputBridge_notifyFramePresented();
    inputBridge_notifyFramePresented();
    Pump(harness);
    CHECK(harness.buttons[0] == 1);
    inputBridge_cancelAllState(&harness, 5);
    CHECK(harness.buttons[0] == 0);

    inputBridge_pushEvent(kKeyEvent, 68, 34, kPress, 0);
    Pump(harness);
    CHECK(harness.keys[68] == 1);
    // Host target uses an eight-slot instance of the shipping ring. Nine
    // unconsumed events force the real StartPumping overflow recovery path.
    for (int i = 0; i < 9; ++i) {
        inputBridge_pushEvent(kKeyEvent, 80 + i, 0, kPress, 0);
    }
    Pump(harness);
    CHECK(harness.keys[68] == 0);
    for (int i = 0; i < 9; ++i) CHECK(harness.keys[80 + i] == 0);
}

void TestNonFiniteCursorWritesAreAtomic() {
    const double invalid[] = {
        std::numeric_limits<double>::quiet_NaN(),
        std::numeric_limits<double>::infinity(),
        -std::numeric_limits<double>::infinity(),
    };

    const unsigned long long invalidBefore =
        inputBridge_testInvalidCursorWriteCount();
    inputBridge_setLookCursor(100.0, 200.0);
    inputBridge_setGrabState(1);
    inputBridge_addLookDelta(3.0, -4.0);
    double x = 0.0;
    double y = 0.0;
    inputBridge_getCursorSnapshot(&x, &y);
    CHECK(x == 103.0 && y == 196.0);

    for (double value : invalid) {
        inputBridge_addLookDelta(value, 1.0);
        inputBridge_addLookDelta(1.0, value);
        inputBridge_setLookCursor(value, 9.0);
        inputBridge_setLookCursor(9.0, value);
        inputBridge_getCursorSnapshot(&x, &y);
        CHECK(x == 103.0 && y == 196.0);
    }
    inputBridge_addLookDelta(2.0, 5.0);
    inputBridge_getCursorSnapshot(&x, &y);
    CHECK(x == 105.0 && y == 201.0);

    const double large = std::numeric_limits<double>::max() * 0.75;
    inputBridge_setGrabState(0);
    inputBridge_setLookCursor(large, 20.0);
    inputBridge_setGrabState(1);
    inputBridge_addLookDelta(large, 1.0);  // X overflow: neither axis commits.
    inputBridge_getCursorSnapshot(&x, &y);
    CHECK(x == large && y == 20.0);
    inputBridge_addLookDelta(-large, 2.0);
    inputBridge_getCursorSnapshot(&x, &y);
    CHECK(x == 0.0 && y == 22.0);

    inputBridge_setGrabState(0);
    inputBridge_setMenuCursor(7.0, 8.0);
    inputBridge_getCursorSnapshot(&x, &y);
    CHECK(x == 7.0 && y == 8.0);
    for (double value : invalid) {
        inputBridge_setMenuCursor(value, 1.0);
        inputBridge_setMenuCursor(1.0, value);
        inputBridge_getCursorSnapshot(&x, &y);
        CHECK(x == 7.0 && y == 8.0);
    }
    inputBridge_setMenuCursor(9.0, 10.0);
    inputBridge_getCursorSnapshot(&x, &y);
    CHECK(x == 9.0 && y == 10.0);
    CHECK(inputBridge_testInvalidCursorWriteCount() ==
          invalidBefore + 19u);
}

void TestGrabTransactionSerializesWriter() {
    inputBridge_setGrabState(0);
    int grabbed = -1;
    CHECK(inputBridge_beginPhysicalMotionTransaction(&grabbed) == 1);
    CHECK(grabbed == 0);

    std::atomic<bool> writerStarted{false};
    std::atomic<bool> writerFinished{false};
    std::thread writer([&]() {
        writerStarted.store(true, std::memory_order_release);
        inputBridge_setGrabState(1);
        writerFinished.store(true, std::memory_order_release);
    });
    while (!writerStarted.load(std::memory_order_acquire)) {
        std::this_thread::yield();
    }
    for (size_t attempt = 0;
         attempt < 1000000u && inputBridge_testGrabWriterWaiters() == 0u;
         ++attempt) {
        std::this_thread::yield();
    }
    CHECK(inputBridge_testGrabWriterWaiters() == 1u);
    CHECK(!writerFinished.load(std::memory_order_acquire));

    inputBridge_endPhysicalMotionTransaction();
    writer.join();
    CHECK(writerFinished.load(std::memory_order_acquire));
    CHECK(inputBridge_testGrabWriterWaiters() == 0u);

    grabbed = -1;
    CHECK(inputBridge_beginPhysicalMotionTransaction(&grabbed) == 1);
    CHECK(grabbed == 1);
    inputBridge_endPhysicalMotionTransaction();
    inputBridge_setGrabState(0);
}

struct SdlWire {
    int type = 0;
    int i1 = 0;
    int i2 = 0;
    int i3 = 0;
    int i4 = 0;
};

bool NextSdl(SdlWire* wire) {
    return inputBridge_sdlNextEvent(&wire->type, &wire->i1, &wire->i2,
                                    &wire->i3, &wire->i4) != 0;
}

void CheckSdlButton(const SdlWire& wire, int action) {
    CHECK(wire.type == kButtonEvent);
    CHECK(wire.i1 == 0);
    CHECK(wire.i2 == action);
    CHECK(wire.i3 == 0);
    CHECK(wire.i4 == 0);
}

void TestSdlMenuPointerPresentBarrier(Harness& harness) {
    // SDL owns a dedicated consumer session. Starting it aligns to “now”, so no event from the
    // preceding GLFW tests can be mistaken for input belonging to this SDL window.
    inputBridge_sdlSetActive(1);
    inputBridge_setGrabState(0);
    SdlWire wire;

    // Regression for the 26.3 double-tap bug: DOWN updates the absolute cursor but cannot return PRESS in the
    // same pump — the patched SDL backend publishes that cursor at pump end, and only a successful SDL present makes PRESS eligible in the next pump.
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 101, 202, 5001);
    CHECK(!NextSdl(&wire));
    double x = 0.0;
    double y = 0.0;
    inputBridge_getCursorSnapshot(&x, &y);
    CHECK(x == 101.0 && y == 202.0);
    CHECK(!NextSdl(&wire));
    inputBridge_sdlNotifyFramePresented();
    CHECK(NextSdl(&wire));
    CheckSdlButton(wire, kPress);

    inputBridge_pushEvent(kMenuEvent, kMenuMove, 111, 212, 5001);
    CHECK(!NextSdl(&wire));
    inputBridge_getCursorSnapshot(&x, &y);
    CHECK(x == 111.0 && y == 212.0);
    inputBridge_pushEvent(kMenuEvent, kMenuUp, 112, 213, 5001);
    CHECK(NextSdl(&wire));
    CheckSdlButton(wire, kRelease);

    // A quick tap ends before the present barrier. It must remain one paired click, not disappear
    // and not release before its delayed press.
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 301, 402, 5002);
    inputBridge_pushEvent(kMenuEvent, kMenuUp, 302, 403, 5002);
    CHECK(!NextSdl(&wire));
    inputBridge_sdlNotifyFramePresented();
    CHECK(NextSdl(&wire));
    CheckSdlButton(wire, kPress);
    CHECK(NextSdl(&wire));
    CheckSdlButton(wire, kRelease);
    CHECK(!NextSdl(&wire));

    // CANCEL is never a click, even when the present epoch has advanced. Its placeholder 0,0 also
    // must not move the visible menu cursor.
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 501, 602, 5003);
    inputBridge_pushEvent(kMenuEvent, kMenuCancel, 0, 0, 5003);
    CHECK(!NextSdl(&wire));
    inputBridge_sdlNotifyFramePresented();
    CHECK(!NextSdl(&wire));
    inputBridge_getCursorSnapshot(&x, &y);
    CHECK(x == 501.0 && y == 602.0);

    // A stale token cannot release the current transaction. The matching CANCEL must release an
    // already-visible button exactly once.
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 701, 802, 5004);
    inputBridge_pushEvent(kMenuEvent, kMenuUp, 702, 803, 4999);
    CHECK(!NextSdl(&wire));
    inputBridge_sdlNotifyFramePresented();
    CHECK(NextSdl(&wire));
    CheckSdlButton(wire, kPress);
    inputBridge_pushEvent(kMenuEvent, kMenuCancel, 0, 0, 5004);
    CHECK(NextSdl(&wire));
    CheckSdlButton(wire, kRelease);
    CHECK(!NextSdl(&wire));

    // Switching to relative mode is a lifecycle boundary. A visible menu button gets one deferred
    // release; a not-yet-visible press is discarded and can never close the new screen later.
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 901, 902, 5005);
    CHECK(!NextSdl(&wire));
    inputBridge_sdlNotifyFramePresented();
    CHECK(NextSdl(&wire));
    CheckSdlButton(wire, kPress);
    inputBridge_setGrabState(1);
    CHECK(NextSdl(&wire));
    CheckSdlButton(wire, kRelease);
    inputBridge_setGrabState(0);

    inputBridge_pushEvent(kMenuEvent, kMenuDown, 1001, 1002, 5006);
    CHECK(!NextSdl(&wire));
    inputBridge_setGrabState(1);
    inputBridge_sdlNotifyFramePresented();
    CHECK(!NextSdl(&wire));
    inputBridge_setGrabState(0);

    // Window cancellation resets the transaction before returning RESET. A later present cannot
    // resurrect a click from the old window generation.
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 1101, 1102, 5007);
    CHECK(!NextSdl(&wire));
    inputBridge_cancelAllState(&harness, 5);
    CHECK(NextSdl(&wire));
    CHECK(wire.type == kInputResetEvent);
    inputBridge_sdlNotifyFramePresented();
    CHECK(!NextSdl(&wire));
    inputBridge_sdlSetActive(0);
}

// ⭐ typed 与 legacy ring 在 `inputBridge_l2NextEvent` 里的**合并**：两条都必须 drain。
// 为什么这条一定要有断言（f5dc4eb 曾写成二选一）见计划 §102.2。
struct Lwjgl2Wire {
    int type = 0;
    int i1 = 0;
    int i2 = 0;
    int i3 = 0;
    int i4 = 0;
};

bool NextL2(Lwjgl2Wire* wire) {
    return inputBridge_l2NextEvent(&wire->type, &wire->i1, &wire->i2,
                                   &wire->i3, &wire->i4) != 0;
}

AmclBackendInputEvent TypedKey(int32_t code, uint32_t action) {
    AmclBackendInputEvent event{};
    event.eventType = AMCL_BACKEND_INPUT_EVENT_KEY;
    event.code = code;
    event.rawCode = code + 1000;
    event.action = action;
    return event;
}

void DrainL2() {
    Lwjgl2Wire wire;
    for (int i = 0; i < 64 && NextL2(&wire); ++i) {}
}

void TestLwjgl2TypedAndRingAreBothDrained() {
    amclBackendInputHostStubReset();
    DrainL2();

    // 1. typed 有事件时先出 typed，编码走 2xxx 段。
    const AmclBackendInputEvent typed = TypedKey(0x11, AMCL_BACKEND_INPUT_ACTION_DOWN);
    amclBackendInputHostStubPush(&typed);
    inputBridge_pushEvent(kKeyEvent, 90, 40, kPress, 0);
    Lwjgl2Wire wire;
    CHECK(NextL2(&wire));
    CHECK(wire.type == 2005);
    CHECK(wire.i1 == 0x11);
    CHECK(wire.i3 == 1);

    // 2. ⭐ typed 空了之后**必须继续读 ring**。二选一的实现在这里返回 0，ring 里那条
    //    虚拟按键就永远出不来。
    CHECK(NextL2(&wire));
    CHECK(wire.type == kKeyEvent);
    CHECK(wire.i1 == 90);

    // 3. 两条都空 ⇒ 返回 0。
    CHECK(!NextL2(&wire));

    // Typed commit is decoded once into KEY_NONE+character-style legacy CHAR
    // records. It never expands inside the 128-record backend physical queue.
    const uint8_t committed[] = {
        0xe4u, 0xb8u, 0xadu, 0xf0u, 0x9fu, 0x98u, 0x80u, 0x40u};
    AmclBackendInputEvent text{};
    text.eventType = AMCL_BACKEND_INPUT_EVENT_TEXT_COMMIT;
    text.deviceId = 700u;
    text.code = static_cast<int32_t>(sizeof(committed));
    amclBackendInputHostStubSetTextPacket(
        text.deviceId, committed, static_cast<uint32_t>(sizeof(committed)));
    amclBackendInputHostStubPush(&text);
    CHECK(NextL2(&wire));
    CHECK(wire.type == 1000 && wire.i1 == 0x4e2d);
    CHECK(NextL2(&wire));
    CHECK(wire.type == 1000 && wire.i1 == 0x1f600);
    CHECK(NextL2(&wire));
    CHECK(wire.type == 1000 && wire.i1 == 0x40);
    CHECK(!NextL2(&wire));
    CHECK(amclBackendInputReleaseText(
              AMCL_BACKEND_INPUT_LWJGL2, text.deviceId) ==
          AMCL_BACKEND_INPUT_ERROR_NOT_FOUND);

    // LWJGL2 has no preedit/candidate/selection API. Those packets are named
    // degradations and are still released rather than leaked or mislabelled.
    text.eventType = AMCL_BACKEND_INPUT_EVENT_TEXT_EDITING;
    text.deviceId = 701u;
    amclBackendInputHostStubSetTextPacket(
        text.deviceId, committed, static_cast<uint32_t>(sizeof(committed)));
    amclBackendInputHostStubPush(&text);
    CHECK(!NextL2(&wire));
    CHECK(amclBackendInputReleaseText(
              AMCL_BACKEND_INPUT_LWJGL2, text.deviceId) ==
          AMCL_BACKEND_INPUT_ERROR_NOT_FOUND);

    // 4. ⭐ UNAVAILABLE（legacy 路由生效）必须与 EMPTY 区分：此时物理边沿在 ring 里，
    //    把 UNAVAILABLE 当错误直接返回会丢掉**全部**输入。
    amclBackendInputHostStubSetUnavailable(1);
    inputBridge_pushEvent(kKeyEvent, 91, 41, kPress, 0);
    inputBridge_pushEvent(kButtonEvent, 2, kPress, 0, 0);
    CHECK(NextL2(&wire));
    CHECK(wire.type == kKeyEvent);
    CHECK(wire.i1 == 91);
    CHECK(NextL2(&wire));
    CHECK(wire.type == kButtonEvent);
    CHECK(!NextL2(&wire));
    amclBackendInputHostStubSetUnavailable(0);

    // 5. 滚轮亚阈值不出货，跨阈值出一格。宿主侧的余量是**跨调用**持有的，所以三次
    //    独立调用才是这条链的真实形状（单次调用测不出余量有没有被写回）。
    AmclBackendInputEvent wheel{};
    wheel.eventType = AMCL_BACKEND_INPUT_EVENT_WHEEL;
    wheel.wheelY = 0.4f;
    for (int i = 0; i < 2; ++i) {
        amclBackendInputHostStubPush(&wheel);
        CHECK(!NextL2(&wire));
    }
    amclBackendInputHostStubPush(&wheel);
    CHECK(NextL2(&wire));
    CHECK(wire.type == 2007);
    CHECK(wire.i2 == 1);

    // 6. 复位事件出货，且把余量清干净 —— 复位后重新攒三次才应该再出一格。
    AmclBackendInputEvent reset{};
    reset.eventType = AMCL_BACKEND_INPUT_EVENT_RESET;
    amclBackendInputHostStubPush(&wheel);
    amclBackendInputHostStubPush(&reset);
    CHECK(NextL2(&wire));
    CHECK(wire.type == 2009);
    for (int i = 0; i < 2; ++i) {
        amclBackendInputHostStubPush(&wheel);
        CHECK(!NextL2(&wire));
    }
    amclBackendInputHostStubPush(&wheel);
    CHECK(NextL2(&wire));
    CHECK(wire.type == 2007);

    amclBackendInputHostStubReset();
    DrainL2();
}

}  // namespace

int main() {
    Harness harness;
    inputBridge_setKeyCallback(Harness::LegacyKey);
    inputBridge_setMouseButtonCallback(Harness::LegacyButton);
    // ⚠️ 补上此前缺失的这一个：没有它，bridge 的 cursor 上报路径整条不可达（见 Harness）。
    inputBridge_setCursorPosCallback(Harness::LegacyCursorPos);
    TestRealRingAndCrossPlaneOwnership(harness);
    TestDirectTypedCommitCallback(harness);
    // 顺序即前提：本用例断言未知事件不污染轮询状态，需要上一个用例已把 keys[65] /
    // buttons[1] 收回到 0（它结尾正是那个状态）。
    TestUnknownRingEventIsCountedButResetIsNot(harness);
    // 顺序即前提：上一个用例结尾 ring 已排空，本用例的第一条断言正是"空 ring 的 pump
    // 不得推进出货计数"。
    TestPumpDrainCountersAreMonotonic(harness);
    TestLookLatencyMeasuresFirstQueuedSample(harness);
    TestPendingAndConsumedWindowCancel(harness);
    TestMenuAndOverflowRecovery(harness);
    TestNonFiniteCursorWritesAreAtomic();
    TestGrabTransactionSerializesWriter();
    TestSdlMenuPointerPresentBarrier(harness);
    TestLwjgl2TypedAndRingAreBothDrained();
    CHECK(harness.committedBeforeCallback);
    std::cout << "glfw_runtime_input_bridge_test: PASS\n";
    return 0;
}
