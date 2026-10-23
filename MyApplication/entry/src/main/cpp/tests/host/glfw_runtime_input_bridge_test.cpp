// 真实legacy bridge与最终来源平面聚合的宿主组合回归。
// ring、菜单present门、消费游标、overflow和activation均直接链接产品实现。
// 平台替身只提供pthread/日志和可编程typed通道，不能复制legacy状态转换。
// 新场景将生产InputLedger、producer不连续tracker与三consumer连在一起核对持有边沿。
// 回调先观察已提交polling/aggregate；同窗重入和局部恢复不得误清兄弟或typed持有。
#include "../../input/adapters/glfw_source_plane_aggregate.h"

#include "backend_input_bridge_host_stub.h"
#include "../../input/input_interaction_order.h"
#include "../../input/input_menu_cursor_snapshot.h"
#include "../../input/input_surface_context_snapshot.h"
#include "../../platform/input_ledger.h"
#include "../../platform/legacy_ring_discontinuity.h"
#include "../../platform/touch_publication_state.h"

#include <array>
#include <atomic>
#include <cstring>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <thread>
#include <vector>

using namespace amcl::input;

// 传统bridge-only目标不链接Core时，私有current明确无数据，不能伪造新鲜Hz。
// 共同control delivery组合目标链接真实Core/owner，必须使用其真实reader；未发布surface
// 时该reader同样返回无数据，不能保留同名stub遮蔽或复制owner来消除链接冲突。
#ifndef AMCL_CONTROL_DELIVERY_HOST_TESTING
extern "C" int amcl_input_owner_read_surface_context(AmclInputSurfaceContextPayload* outContext) {
    if (outContext) *outContext = {};
    return 0;
}
#endif

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
void inputBridge_pumpOrdered(void*, int (*)(void*, uint64_t), void*, uint64_t);
void inputBridge_publishMenuCursor(double, double);
void inputBridge_l2SetActive(int active);
void inputBridgeStopPumping();
void inputBridge_notifyFramePresented();
void inputBridge_cancelAllState(void* window, int reason);
void inputBridge_addLookDelta(double dx, double dy);
void inputBridge_addSourceLookDelta(int32_t source, double dx, double dy);
void inputBridge_sdlGetNonPhysicalCursorSnapshot(double* outX, double* outY);
void inputBridge_glfwSetActive(void* window, int active);
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
unsigned long long inputBridge_legacyRingDiscontinuityEpochV1();
void inputBridge_sdlNotifyFramePresented();
int inputBridge_sdlNextEvent(int* outType, int* o1, int* o2, int* o3, int* o4);
uint64_t inputBridge_sdlPeekOrder();
int inputBridge_sdlNextThrough(int*,int*,int*,int*,int*,uint64_t);
void inputBridge_retireTouchMenuScopeV1();
void inputBridge_retireTouchMenuToolScopeV1();
void inputBridge_testSetMenuNowNs(uint64_t now);
void inputBridge_pushTouchMenuToolV1(int code, int action);
void inputBridge_publishTouchMenuCursorV1(double x, double y);
void inputBridge_notifyFramePresentedForTargetV1(uint64_t window, uint64_t generation);
void inputBridge_sdlSetTargetV1(uint64_t window, uint64_t generation, uint64_t wsiIdentity);
void inputBridge_sdlNotifyFramePresentedForTargetV1(uint64_t window, uint64_t generation);
void inputBridge_glfwSetTargetV1(uint64_t window, uint64_t generation, uint64_t wsiIdentity);
void inputBridge_publishTouchMenuScrollV1(int dx,int dy);
void inputBridge_pushTouchMenuToolScrollV1(int dx,int dy);
void inputBridge_publishTouchMenuToolCursorV1(double x,double y);
void inputBridge_publishTouchMenuToolRelativeV1(double dx,double dy,double maxX,double maxY);
void inputBridge_publishTouchMenuRelativeV1(int phase,uint32_t token,double dx,double dy,double maxX,double maxY);
void inputBridge_setScrollCallback(void (*callback)(void*,double,double));
void inputBridge_testResetMenuCursorSelectionV1();

namespace {
constexpr int kKeyEvent = 1005;
constexpr int kButtonEvent = 1006;
constexpr int kMenuEvent = 1008;
constexpr int kScrollEvent = 1007;
constexpr int kInputResetEvent = 1009;
constexpr int kCursorEvent = 1010;
constexpr int kPress = 1;
constexpr int kRelease = 0;
constexpr int kMenuMove = 0;
constexpr int kMenuDown = 1;
constexpr int kMenuUp = 2;
constexpr int kMenuCancel = 3;
constexpr int kMenuBegin = 4;
constexpr int kMenuEnd = 5;

// 组合回归直接使用生产ledger出口生成ordinary边沿，菜单token则使用真实bridge事务协议。
// 这样两根手指的来源身份确实在消费侧相遇，不能用各层分别通过代替整链验证。

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "GLFW RUNTIME BRIDGE FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

/**
 * 最终消费轨迹只记录已经交付的出口，绝不重新解释触点或延期状态。
 * LEFT 来自 GLFW 真实 aggregate，或拉取后端实际收到的按钮边沿状态；x/y 来自
 * 同一出口载荷/生产 cursor snapshot。这样能区分“最终一按一松”和真正的拖动区间。
 */
struct CausalPulse {
    char kind = 'm'; // m位置、b按钮、k键盘、s滚轮；s的code/action分别为实际dx/dy。
    int code = 0;
    int action = -1;
    double x = 0;
    double y = 0;
    int left = 0;
};

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
    std::vector<std::pair<int,int>> rawHighKeyEdges;
    int expectedLeftShift = -1;
    // 真实legacy回调中触发Hide或Hide→Show，模拟GLFW的同步用户回调重入。
    int activationReentry = 0;
    int buttonActivationReentry = 0;
    int buttonScopeReentry = 0; // 1只取消工具并入队新工具；2完整scope退休并发布新菜单事务。
    std::vector<CausalPulse> causalPulses;

    // 按键回调采用当时生产快照，不能事后从全局“最新位置”反推源点。
    void RecordEdge(char kind, int code, int action) {
        double x = 0, y = 0;
        inputBridge_getCursorSnapshot(&x, &y);
        causalPulses.push_back({kind, code, action, x, y, buttons[0]});
    }

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
        self.causalPulses.push_back({'m', 0, -1, x, y, self.buttons[0]});
    }

    // 最终scroll回调只记录真实轴量与当前状态，不生成/合并任何滚轮事务。
    static void LegacyScroll(void* window,double dx,double dy){
        if(window)static_cast<Harness*>(window)->RecordEdge('s',static_cast<int>(dx),static_cast<int>(dy));
    }

    static void DispatchKey(void* context,
                            const GlfwAggregateKeyEvent& event) {
        auto& self = *static_cast<Harness*>(context);
        const bool pressed = event.action != GlfwAggregateAction::kRelease;
        self.keys[static_cast<size_t>(event.key)] = pressed ? 1 : 0;
        self.committedBeforeCallback &=
            self.aggregate.IsKeyPressed(event.key) == pressed;
        self.keyCallbacks.push_back(event);
        self.RecordEdge('k', event.key, static_cast<int>(event.action));
        if (event.key == 65 && event.action == GlfwAggregateAction::kPress && self.activationReentry) {
            const int action = self.activationReentry;
            self.activationReentry = 0;
            inputBridge_glfwSetActive(&self, 0);
            if (action == 2) inputBridge_glfwSetActive(&self, 1);
            // 新生代中的真实事件必须由下一次pump消费，不能被外层旧游标覆盖或提前派发。
            inputBridge_pushEvent(kKeyEvent, 67, 0, kPress, 0);
        }
    }

    static void DispatchButton(void* context,
                               const GlfwAggregateButtonEvent& event) {
        auto& self = *static_cast<Harness*>(context);
        const bool pressed = event.action != GlfwAggregateAction::kRelease;
        if(event.button==0&&event.action==GlfwAggregateAction::kPress&&self.expectedLeftShift>=0)
            CHECK(self.aggregate.IsKeyPressed(340)==(self.expectedLeftShift!=0));
        self.buttons[static_cast<size_t>(event.button)] = pressed ? 1 : 0;
        self.committedBeforeCallback &=
            self.aggregate.IsButtonPressed(event.button) == pressed;
        self.buttonCallbacks.push_back(event);
        self.RecordEdge('b', event.button, static_cast<int>(event.action));
        if(event.button==0&&event.action==GlfwAggregateAction::kPress&&self.buttonScopeReentry){
            const int scope=self.buttonScopeReentry;self.buttonScopeReentry=0;
            if(scope==1){inputBridge_retireTouchMenuToolScopeV1();inputBridge_pushTouchMenuToolV1(-1,kPress);}
            else{
                inputBridge_retireTouchMenuScopeV1();
                inputBridge_pushEvent(kMenuEvent,kMenuDown,501,601,12630);
                inputBridge_pushEvent(kMenuEvent,kMenuUp,501,601,12630);
                inputBridge_pushEvent(kKeyEvent,67,0,kPress,0);
            }
        }
        if (event.button == 0 && event.action == GlfwAggregateAction::kPress && self.buttonActivationReentry) {
            const int action = self.buttonActivationReentry; self.buttonActivationReentry = 0;
            inputBridge_glfwSetActive(&self, 0);
            if (action == 2) inputBridge_glfwSetActive(&self, 1);
            inputBridge_pushEvent(kKeyEvent, 67, 0, kPress, 0);
        }
    }

    GlfwAggregateSink Sink() {
        return {this, DispatchKey, DispatchButton};
    }

    static void LegacyKey(void* context, int key, int scanCode,
                          int action, int modifiers) {
        auto& self = *static_cast<Harness*>(context);
        // 511/512的原始legacy ABI边沿照常接收；末级GLFW标准polling范围另由aggregate判断。
        if(key==511||key==512) self.rawHighKeyEdges.emplace_back(key,action);
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

void TestActivationGenerationStopsReentrantBatch(Harness& harness) {
    for (int reentry : {1, 2}) {
        inputBridge_cancelAllState(&harness, 5);
        inputBridge_glfwSetActive(&harness, 1);
        harness.activationReentry = reentry;
        const size_t before = harness.keyCallbacks.size();
        inputBridge_pushEvent(kKeyEvent, 65, 0, kPress, 0);
        inputBridge_pushEvent(kKeyEvent, 66, 0, kPress, 0);
        Pump(harness);
        CHECK(harness.keys[65] == 0);
        CHECK(harness.keys[66] == 0);
        CHECK(harness.keys[67] == 0);
        CHECK(harness.keyCallbacks.size() == before + 2u); // A DOWN和同步失活RELEASE
        if (reentry == 1) {
            // 隐藏期间发布的C也要跳过；Show重建起点后才接受新C。
            inputBridge_glfwSetActive(&harness, 1);
            inputBridge_pushEvent(kKeyEvent, 67, 0, kPress, 0);
        }
        Pump(harness);
        CHECK(harness.keys[66] == 0 && harness.keys[67] == 1);
        inputBridge_pushEvent(kKeyEvent, 67, 0, kRelease, 0);
        Pump(harness);
        CHECK(harness.keys[67] == 0);
    }
}

void TestNonPhysicalCursorReanchorsOnlyOnGrabFlip() {
    amclBackendInputHostStubReset();
    inputBridge_setGrabState(0);
    inputBridge_setLookCursor(0, 0);
    inputBridge_setGrabState(1);
    const double large = std::numeric_limits<double>::max() * 0.5;
    inputBridge_addSourceLookDelta(1, large, 0);
    double x = 0.0, y = 0.0;
    inputBridge_sdlGetNonPhysicalCursorSnapshot(&x, &y);
    CHECK(x == large);
    inputBridge_setGrabState(0);
    inputBridge_setLookCursor(0, 0);
    inputBridge_setGrabState(1);
    inputBridge_addSourceLookDelta(1, 2, 3);
    inputBridge_sdlGetNonPhysicalCursorSnapshot(&x, &y);
    CHECK(x == 2 && y == 3);
    inputBridge_setGrabState(1); // 相同grab不是新epoch，不可丢掉当前累计。
    inputBridge_addSourceLookDelta(2, 1, 2);
    inputBridge_sdlGetNonPhysicalCursorSnapshot(&x, &y);
    CHECK(x == 3 && y == 5);
    inputBridge_setGrabState(0);
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
    Pump(harness); // 宿主容量8只限制每pump预算；当前10个held基线有界分两轮恢复。
    CHECK(harness.keys[68] == 1);
    for (int i = 0; i < 9; ++i) CHECK(harness.keys[80 + i] == 1);
    inputBridge_cancelAllState(&harness, 5);
    CHECK(harness.keys[68] == 0);
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

/** 将现役 1010 ABI 的四个整数原样还原为两个 double，不根据坐标猜测任何手势。 */
std::pair<double, double> DecodeCursorWire(int a, int b, int c, int d) {
    const int words[4] = {a, b, c, d};
    double position[2]{};
    static_assert(sizeof(words) == sizeof(position), "cursor wire payload drift");
    std::memcpy(position, words, sizeof(position));
    return {position[0], position[1]};
}

/**
 * GLFW 使用真实 callback/aggregate；SDL/L2 使用生产 Next 出口作为消费观察面。
 * pullLeft 只表示下游已收到的 LEFT 状态，正如实际 SDL/LWJGL 消费者维护自己的 polling
 * 状态；它不参与 bridge 的仲裁、取消、顺序或按下资格，也不能替代生产状态机。
 */
struct CausalConsumer {
    Harness& harness;
    int backend;
    int pullLeft = 0;
    std::vector<CausalPulse> pullPulses;
    bool ordered = false;

    explicit CausalConsumer(Harness& observed, int backendId)
        : harness(observed), backend(backendId) {}

    // typed替身提供真实序号；以下回调只完成GLFW末级来源提交，不重写公共顺序选择。
    static int DrainGlfwTyped(void* context, uint64_t ceiling) {
        auto& self = *static_cast<CausalConsumer*>(context);
        AmclBackendInputEvent event{};
        while (amclBackendInputNextThrough(AMCL_BACKEND_INPUT_LWJGL2, &event, ceiling) == AMCL_BACKEND_INPUT_EVENT) {
            if (event.eventType == AMCL_BACKEND_INPUT_EVENT_KEY) {
                const auto action = event.action == AMCL_BACKEND_INPUT_ACTION_UP
                    ? GlfwAggregateAction::kRelease : GlfwAggregateAction::kPress;
                self.harness.aggregate.SubmitKey(GlfwSourcePlane::kTyped, event.code, 0, action, 0, self.harness.Sink());
            }
        }
        return 1;
    }

    void Drain() {
        if (backend == 0) {
            if (ordered) {
                inputBridgeStartPumping();
                inputBridge_pumpOrdered(&harness, DrainGlfwTyped, this, amclInputInteractionFence());
                inputBridgeStopPumping();
            } else Pump(harness);
            return;
        }
        int type = 0, a = 0, b = 0, c = 0, d = 0;
        const uint64_t fence = amclInputInteractionFence();
        for (int budget = 0; budget < 64; ++budget) {
            uint64_t ceiling = UINT64_MAX;
            uint64_t legacyOrder = UINT64_MAX;
            if (backend == 2 && ordered) {
                legacyOrder = inputBridge_sdlPeekOrder();
                ceiling = legacyOrder < fence ? legacyOrder : fence;
                AmclBackendInputEvent event{};
                if (amclBackendInputNextThrough(AMCL_BACKEND_INPUT_SDL3, &event, ceiling) == AMCL_BACKEND_INPUT_EVENT) {
                    double x = 0, y = 0; inputBridge_getCursorSnapshot(&x, &y);
                    pullPulses.push_back({'k', event.code,
                        event.action == AMCL_BACKEND_INPUT_ACTION_UP ? kRelease : kPress, x, y, pullLeft});
                    continue;
                }
            }
            const bool got = backend == 1 ? inputBridge_l2NextEvent(&type, &a, &b, &c, &d) != 0
                : inputBridge_sdlNextThrough(&type, &a, &b, &c, &d, ceiling) != 0;
            if (!got) {
                // 与真实OPENHARMONY_PumpOrderedEvents保持同一消费循环：没有最终边沿
                // 不等于没有进展。pending超期/旧token退出会推进队首，必须重新peek后归并。
                // 若队首未变才结束本轮；上面的64预算保证异常队首不能无限忙循环。
                if (backend == 2 && ordered && inputBridge_sdlPeekOrder() != legacyOrder) continue;
                return;
            }
            if (type == kInputResetEvent) { pullLeft = 0; continue; }
            if (type == kCursorEvent) {
                const auto point = DecodeCursorWire(a, b, c, d);
                pullPulses.push_back({'m', 0, -1, point.first, point.second, pullLeft});
            } else if (type == kButtonEvent) {
                if (a == 0) pullLeft = b != kRelease;
                double x = 0, y = 0;
                inputBridge_getCursorSnapshot(&x, &y);
                pullPulses.push_back({'b', a, b, x, y, pullLeft});
            } else if (type == kKeyEvent || type == 2005) {
                double x = 0, y = 0;
                inputBridge_getCursorSnapshot(&x, &y);
                pullPulses.push_back({'k', a, c, x, y, pullLeft});
            } else if (type == kScrollEvent || type == 2007) {
                double x=0,y=0;inputBridge_getCursorSnapshot(&x,&y);
                pullPulses.push_back({'s',a,b,x,y,pullLeft});
            }
        }
        CHECK(false); // 有界输入必须完成；死循环或同一边沿重复交付不能被静默截断。
    }

    void Start() {
        inputBridge_cancelAllState(&harness, 5);
        inputBridge_setGrabState(0);
        amclBackendInputHostStubReset();
        if (backend == 0) inputBridge_glfwSetActive(&harness, 1);
        if (backend == 1) inputBridge_l2SetActive(1);
        if (backend == 2) inputBridge_sdlSetActive(1);
        Drain(); // 先真正消费旧 RESET，再清本例证据，避免把退休当成本例释放。
        harness.causalPulses.clear(); pullPulses.clear(); pullLeft = 0;
    }

    void Present() {
        if (backend == 0) { inputBridge_notifyFramePresented(); inputBridge_notifyFramePresented(); }
        if (backend == 2) inputBridge_sdlNotifyFramePresented();
        Drain();
    }

    const std::vector<CausalPulse>& Pulses() const {
        return backend == 0 ? harness.causalPulses : pullPulses;
    }

    int Left() const { return backend == 0 ? harness.buttons[0] : pullLeft; }
};

/** 基本鼠标合同：源点按下、每个目标位置到达时仍按住、最终坐标到达后才释放。 */
void CheckCausalDrag(const CausalConsumer& consumer, double ax, double ay,
                     double bx, double by, double cx, double cy) {
    const auto& pulses = consumer.Pulses();
    size_t press = pulses.size(), moveB = pulses.size(), moveC = pulses.size(), release = pulses.size();
    unsigned presses = 0, releases = 0;
    for (size_t i = 0; i < pulses.size(); ++i) {
        const auto& pulse = pulses[i];
        if (pulse.kind == 'b' && pulse.code == 0) {
            if (pulse.action == kPress) {
                ++presses; press = i;
                CHECK(pulse.x == ax && pulse.y == ay && pulse.left == 1);
            } else if (pulse.action == kRelease) {
                ++releases; release = i;
                CHECK(pulse.x == cx && pulse.y == cy && pulse.left == 0);
            }
        }
        if (pulse.kind == 'm' && pulse.x == bx && pulse.y == by) {
            CHECK(pulse.left == 1); moveB = i;
        }
        if (pulse.kind == 'm' && pulse.x == cx && pulse.y == cy) {
            CHECK(pulse.left == 1); moveC = i;
        }
    }
    CHECK(presses == 1 && releases == 1);
    CHECK(press < moveB && moveB < moveC && moveC < release);
    CHECK(consumer.Left() == 0);
}

/**
 * 生产 bridge 的新因果回归：同一批完成的拖动不能被折成终点点击，UP 独有的终点
 * 也必须作为 LEFT=1 的位置出口交付。每个后端都用自己的真实消费函数，不复制延期算法。
 */
void TestMenuCausalCoordinatesAndHeldInterval(Harness& harness) {
    for (int backend = 0; backend < 3; ++backend) {
        CausalConsumer consumer{harness, backend};
        // 第一组把整段输入放在呈现之前，专门覆盖旧代码“MOVE 全发生在 PRESS 之前”。
        consumer.Start();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 10, 20, 12001);
        inputBridge_pushEvent(kMenuEvent, kMenuMove, 300, 400, 12001);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 350, 450, 12001);
        consumer.Drain(); consumer.Present(); consumer.Drain();
        CheckCausalDrag(consumer, 10, 20, 300, 400, 350, 450);

        // 第二组按真实轮次投递：pending 期间首个 MOVE 不能改写冻结的源点。
        consumer.Start();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 11, 21, 12002); consumer.Drain();
        inputBridge_pushEvent(kMenuEvent, kMenuMove, 301, 401, 12002); consumer.Drain();
        consumer.Present();
        CHECK(consumer.Left() == 1);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 351, 451, 12002); consumer.Drain();
        CheckCausalDrag(consumer, 11, 21, 301, 401, 351, 451);

        // 无 MOVE 的输入仍可能在 UP 带来新坐标。不能先 RELEASE 再发布最终位置。
        consumer.Start();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 12, 22, 12003); consumer.Drain();
        consumer.Present();
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 302, 402, 12003); consumer.Drain();
        const auto& upOnly = consumer.Pulses();
        bool sourcePressed = false, heldEndPosition = false, released = false;
        for (const auto& pulse : upOnly) {
            if (pulse.kind == 'b' && pulse.action == kPress) {
                CHECK(pulse.x == 12 && pulse.y == 22); sourcePressed = true;
            }
            if (pulse.kind == 'm' && pulse.x == 302 && pulse.y == 402) {
                CHECK(sourcePressed && pulse.left == 1); heldEndPosition = true;
            }
            if (pulse.kind == 'b' && pulse.action == kRelease) {
                CHECK(heldEndPosition && pulse.x == 302 && pulse.y == 402); released = true;
            }
        }
        CHECK(sourcePressed && heldEndPosition && released && consumer.Left() == 0);

        // 取消已经排队且帧门恰好满足：尚未 commit 的候选不得抢先生成一次点击。
        consumer.Start();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 13, 23, 12004); consumer.Drain();
        inputBridge_pushEvent(kMenuEvent, kMenuCancel, 0, 0, 12004); consumer.Present();
        consumer.Drain();
        unsigned buttonEdges = 0;
        for (const auto& pulse : consumer.Pulses()) {
            if (pulse.kind == 'b' && pulse.code == 0) ++buttonEdges;
            CHECK(!(pulse.kind == 'm' && pulse.x == 0 && pulse.y == 0));
        }
        CHECK(buttonEdges == (backend == 1 ? 2u : 0u) && consumer.Left() == 0);

        // 新DOWN替换尚未commit的旧token；旧UP既不改新源点，也不退休新事务。
        consumer.Start();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 14, 24, 12005); consumer.Drain();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 314, 424, 12006);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 999, 999, 12005);
        consumer.Present(); consumer.Present();
        bool newSource = false;
        for (const auto& pulse : consumer.Pulses()) if (pulse.kind == 'b' && pulse.action == kPress) {
            if (backend != 1) CHECK(pulse.x != 14 || pulse.y != 24);
            if (pulse.x == 314 && pulse.y == 424) newSource = true;
        }
        CHECK(newSource && consumer.Left() == 1);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 314, 424, 12006); consumer.Drain();
        CHECK(consumer.Left() == 0);
        if (backend == 1) inputBridge_l2SetActive(0);
        if (backend == 2) inputBridge_sdlSetActive(0);
    }
}

/** 同步用户button回调隐藏/重开窗口时，旧批次的MOVE/UP不能流入新窗口代次。 */
void TestMenuPressCallbackReentryRetiresOldBatch(Harness& harness) {
    for (int reentry : {1, 2}) {
        CausalConsumer consumer{harness, 0}; consumer.Start();
        const size_t beforeKeys = harness.keyCallbacks.size();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 24, 34, 12010);
        inputBridge_pushEvent(kMenuEvent, kMenuMove, 324, 434, 12010);
        inputBridge_pushEvent(kKeyEvent, 66, 0, kPress, 0);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 324, 434, 12010); consumer.Drain();
        harness.buttonActivationReentry = reentry; consumer.Present();
        CHECK(harness.buttons[0] == 0 && harness.keys[66] == 0 && harness.keys[67] == 0);
        for (const auto& pulse : consumer.Pulses())
            CHECK(!(pulse.kind == 'm' && pulse.x == 324 && pulse.y == 434));
        if (reentry == 1) {
            inputBridge_glfwSetActive(&harness, 1);
            inputBridge_pushEvent(kKeyEvent, 67, 0, kPress, 0);
        }
        consumer.Drain(); CHECK(harness.keys[67] == 1 && harness.keys[66] == 0);
        consumer.Drain(); CHECK(harness.keys[67] == 1 && harness.keys[66] == 0);
        unsigned newPresses = 0;
        for (size_t i = beforeKeys; i < harness.keyCallbacks.size(); ++i)
            if (harness.keyCallbacks[i].key == 67 && harness.keyCallbacks[i].action == GlfwAggregateAction::kPress) ++newPresses;
        CHECK(newPresses == 1); // 旧read cursor不能覆盖重入的新cutoff，让新键重放或旧B/KEY复活。
        inputBridge_pushEvent(kKeyEvent, 67, 0, kRelease, 0); consumer.Drain();
        inputBridge_pushEvent(kKeyEvent, 66, 0, kRelease, 0); consumer.Drain();
        CHECK(harness.keys[67] == 0);
    }
}

/** 新DOWN替换已按住事务时，旧RELEASE留在旧终点；新源点属于之后的独立操作。 */
void TestReplacementReleasesAtOldPositionBeforeNewSource(Harness& harness) {
    for (int backend = 0; backend < 3; ++backend) {
        CausalConsumer consumer{harness, backend}; consumer.Start();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 25, 35, 12020); consumer.Drain(); consumer.Present();
        inputBridge_pushEvent(kMenuEvent, kMenuMove, 125, 135, 12020); consumer.Drain();
        CHECK(consumer.Left() == 1);
        harness.causalPulses.clear(); consumer.pullPulses.clear();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 325, 435, 12021); consumer.Drain(); consumer.Present();
        bool oldReleased = false, newPressed = false;
        for (const auto& pulse : consumer.Pulses()) {
            if (pulse.kind == 'b' && pulse.code == 0 && pulse.action == kRelease) {
                CHECK(!newPressed && pulse.x == 125 && pulse.y == 135); oldReleased = true;
            }
            if (pulse.kind == 'm' && pulse.x == 325 && pulse.y == 435)
                CHECK(oldReleased && pulse.left == 0);
            if (pulse.kind == 'b' && pulse.code == 0 && pulse.action == kPress) {
                CHECK(oldReleased && pulse.x == 325 && pulse.y == 435); newPressed = true;
            }
        }
        CHECK(oldReleased && newPressed && consumer.Left() == 1);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 325, 435, 12021); consumer.Drain(); CHECK(consumer.Left() == 0);
        if (backend == 1) inputBridge_l2SetActive(0);
        if (backend == 2) inputBridge_sdlSetActive(0);
    }
}

/** 延期DOWN保留公共order：后来的legacy/typed键不能先于源点PRESS被最终消费。 */
void TestMenuPendingPreservesCommonOrder(Harness& harness) {
    for (int backend = 0; backend < 3; ++backend) for (bool typed : {false, true}) {
        CausalConsumer consumer{harness, backend}; consumer.ordered = true; consumer.Start();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 41, 51, 12100);
        if (typed) {
            AmclBackendInputEvent key{};
            key.eventType = AMCL_BACKEND_INPUT_EVENT_KEY;
            key.action = AMCL_BACKEND_INPUT_ACTION_DOWN;
            key.code = backend == 1 ? 30 : 65;
            amclBackendInputHostStubPush(&key);
        } else inputBridge_pushEvent(kKeyEvent, 65, 0, kPress, 0);
        consumer.Drain();
        if (backend != 1) {
            for (const auto& pulse : consumer.Pulses()) CHECK(pulse.kind != 'k');
            CHECK(consumer.Left() == 0);
        }
        consumer.Present();
        size_t press = consumer.Pulses().size(), key = consumer.Pulses().size();
        for (size_t i = 0; i < consumer.Pulses().size(); ++i) {
            const auto& pulse = consumer.Pulses()[i];
            if (pulse.kind == 'b' && pulse.code == 0 && pulse.action == kPress) {
                press = i; CHECK(pulse.x == 41 && pulse.y == 51);
            }
            if (pulse.kind == 'k' && pulse.action == kPress) key = i;
        }
        CHECK(press < key && key < consumer.Pulses().size() && consumer.Left() == 1);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 41, 51, 12100);
        if (typed) {
            AmclBackendInputEvent up{}; up.eventType = AMCL_BACKEND_INPUT_EVENT_KEY;
            up.action = AMCL_BACKEND_INPUT_ACTION_UP; up.code = backend == 1 ? 30 : 65;
            amclBackendInputHostStubPush(&up);
        } else inputBridge_pushEvent(kKeyEvent, 65, 0, kRelease, 0);
        consumer.Drain(); CHECK(consumer.Left() == 0);
        if (backend == 1) inputBridge_l2SetActive(0);
        if (backend == 2) inputBridge_sdlSetActive(0);
    }
}

/**
 * 任意线程scope退休通过生产epoch/cutoff撤销已结束和未消费的菜单事务；
 * 此边界只撤销菜单贡献，不能释放仍在持有的ordinary/typed输入域。
 */
void TestTouchScopeRetiresQueuedAndPendingMenuOnly(Harness& harness) {
    for (int backend = 0; backend < 3; ++backend) {
        CausalConsumer consumer{harness, backend};
        const auto buttonCount = [&]() {
            unsigned result = 0;
            for (const auto& pulse : consumer.Pulses()) if (pulse.kind == 'b' && pulse.code == 0) ++result;
            return result;
        };
        // 旧输入尚未被任何consumer读到：retirement必须按cutoff跳过它而非生成补偿点击。
        consumer.Start();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 61, 71, 12200);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 61, 71, 12200);
        inputBridge_retireTouchMenuScopeV1(); consumer.Drain(); consumer.Present();
        CHECK(buttonCount() == 0 && consumer.Left() == 0);
        // 手指已经UP但帧门未开：零前端触点不能使旧pending绕过模态/布局退休。
        consumer.Start();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 62, 72, 12201);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 62, 72, 12201); consumer.Drain();
        inputBridge_retireTouchMenuScopeV1(); consumer.Present(); consumer.Drain();
        CHECK(buttonCount() == (backend == 1 ? 2u : 0u) && consumer.Left() == 0);
        // 已commit菜单与面板共持：退休菜单后面板继续held，最后面板UP才出最终RELEASE。
        consumer.Start();
        InputLedger ordinary([](const Output& output, int action) {
            inputBridge_pushEvent(kButtonEvent, output.code, action, 0, 0);
        });
        CHECK(ordinary.acquire(12202, {OutputKind::Mouse, 0})); consumer.Drain();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 63, 73, 12203); consumer.Drain(); consumer.Present();
        CHECK(consumer.Left() == 1 && buttonCount() == 1);
        inputBridge_retireTouchMenuScopeV1(); consumer.Drain();
        CHECK(consumer.Left() == 1 && buttonCount() == 1);
        ordinary.releaseOwner(12202); consumer.Drain();
        CHECK(consumer.Left() == 0 && buttonCount() == 2);
        // cutoff之后的新事务正常工作；迟到旧token不会在新会话移动或释放。
        consumer.Start(); inputBridge_retireTouchMenuScopeV1();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 64, 74, 12204); consumer.Drain(); consumer.Present();
        CHECK(consumer.Left() == 1);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 999, 999, 12203); consumer.Drain();
        CHECK(consumer.Left() == 1);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 64, 74, 12204); consumer.Drain();
        CHECK(consumer.Left() == 0 && buttonCount() == 2);
        if (backend == 1) inputBridge_l2SetActive(0);
        if (backend == 2) inputBridge_sdlSetActive(0);
    }
}

/**
 * 使用生产菜单时钟的可编程宿主边界验证精确500ms期限，不以sleep/调度抖动决定结果。
 * 停止渲染仅退休尚未commit的候选；已提交拖动持续按住到UP，不因拖动超过期限误松。
 */
void TestPausedRenderingCancelsOnlyUncommittedMenu(Harness& harness) {
    for (int backend : {0, 2}) {
        CausalConsumer consumer{harness, backend}; consumer.ordered = true;
        inputBridge_testSetMenuNowNs(1000000000ULL); consumer.Start();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 81, 91, 12300);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 81, 91, 12300);
        inputBridge_pushEvent(kKeyEvent, 65, 0, kPress, 0); consumer.Drain();
        inputBridge_testSetMenuNowNs(1499000000ULL); consumer.Drain();
        for (const auto& pulse : consumer.Pulses()) CHECK(pulse.kind != 'b' && pulse.kind != 'k');
        inputBridge_testSetMenuNowNs(1500000000ULL); consumer.Drain();
        bool laterKey = false;
        for (const auto& pulse : consumer.Pulses()) {
            CHECK(pulse.kind != 'b');
            if (pulse.kind == 'k' && pulse.action == kPress) laterKey = true;
        }
        if (!laterKey || consumer.Left() != 0) {
            // 失败时输出真实出口，方便区分不同后端、队首仍pending和source聚合；不改变判据。
            std::cerr << "paused-render backend=" << backend << " left=" << consumer.Left() << '\n';
            for (const auto& pulse : consumer.Pulses()) std::cerr << "  " << pulse.kind << ' ' << pulse.code
                << ' ' << pulse.action << " x=" << pulse.x << " y=" << pulse.y << " left=" << pulse.left << '\n';
        }
        CHECK(laterKey && consumer.Left() == 0);
        consumer.Present();
        for (const auto& pulse : consumer.Pulses()) CHECK(pulse.kind != 'b');
        inputBridge_pushEvent(kKeyEvent, 65, 0, kRelease, 0); consumer.Drain();

        inputBridge_testSetMenuNowNs(2000000000ULL); consumer.Start();
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 82, 92, 12301); consumer.Drain(); consumer.Present();
        CHECK(consumer.Left() == 1);
        inputBridge_testSetMenuNowNs(4000000000ULL);
        inputBridge_pushEvent(kMenuEvent, kMenuMove, 282, 292, 12301); consumer.Drain();
        CHECK(consumer.Left() == 1);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 382, 392, 12301); consumer.Drain();
        CheckCausalDrag(consumer, 82, 92, 282, 292, 382, 392);
        if (backend == 2) inputBridge_sdlSetActive(0);
    }
    inputBridge_testSetMenuNowNs(0);
}

/**
 * 面板的LEFT/RIGHT/Shift使用独立scope，但最终与ordinary保留首按末松并集。
 * scope退休无权释放其它域；退出后迟到的旧面板UP不会反转ordinary的真实持有。
 */
void TestMenuToolScopedContributions(Harness& harness) {
    for (int backend = 0; backend < 3; ++backend) for (int code : {-1, -2, 340}) {
        CausalConsumer consumer{harness, backend};
        const auto ordinary = [&](int action) {
            if (code == 340) inputBridge_pushEvent(kKeyEvent, 340, 0, action, 0);
            else inputBridge_pushEvent(kButtonEvent, code == -1 ? 0 : 1, action, 0, 0);
        };
        const auto edges = [&]() {
            std::vector<int> result;
            for (const auto& pulse : consumer.Pulses())
                if ((code == 340 && pulse.kind == 'k' && pulse.code == 340) ||
                    (code != 340 && pulse.kind == 'b' && pulse.code == (code == -1 ? 0 : 1)))
                    result.push_back(pulse.action);
            return result;
        };
        // scope推进可以退休还没有读到的工具动作，不生成按下/补偿释放。
        consumer.Start();
        inputBridge_pushTouchMenuToolV1(code, kPress);
        inputBridge_pushTouchMenuToolV1(code, kRelease);
        inputBridge_retireTouchMenuScopeV1(); consumer.Drain();
        CHECK(edges().empty());
        for (bool toolUpFirst : {false, true}) {
            consumer.Start(); ordinary(kPress); consumer.Drain();
            inputBridge_pushTouchMenuToolV1(code, kPress); consumer.Drain();
            CHECK(edges() == std::vector<int>{kPress});
            if (toolUpFirst) inputBridge_pushTouchMenuToolV1(code, kRelease);
            else ordinary(kRelease);
            consumer.Drain(); CHECK(edges() == std::vector<int>{kPress});
            if (toolUpFirst) ordinary(kRelease);
            else inputBridge_pushTouchMenuToolV1(code, kRelease);
            consumer.Drain(); CHECK(edges() == (std::vector<int>{kPress, kRelease}));
        }
        // 无工具UP的模态/布局退休同样只移除工具贡献。
        consumer.Start(); ordinary(kPress); consumer.Drain();
        inputBridge_pushTouchMenuToolV1(code, kPress); consumer.Drain();
        inputBridge_retireTouchMenuScopeV1(); consumer.Drain();
        CHECK(edges() == std::vector<int>{kPress});
        inputBridge_pushTouchMenuToolV1(code, kRelease); consumer.Drain();
        CHECK(edges() == std::vector<int>{kPress});
        ordinary(kRelease); consumer.Drain(); CHECK(edges() == (std::vector<int>{kPress, kRelease}));
        // GLFW实际typed aggregate保持实体贡献。L2 Java/SDL完整末级另有同一owner矩阵回归。
        if (backend == 0) {
            consumer.Start();
            if (code == 340) harness.aggregate.SubmitKey(GlfwSourcePlane::kTyped, 340, 0, GlfwAggregateAction::kPress, 0, harness.Sink());
            else harness.aggregate.SubmitButton(GlfwSourcePlane::kTyped, code == -1 ? 0 : 1, GlfwAggregateAction::kPress, 0, harness.Sink());
            ordinary(kPress); consumer.Drain(); inputBridge_pushTouchMenuToolV1(code, kPress); consumer.Drain();
            inputBridge_retireTouchMenuScopeV1(); consumer.Drain(); ordinary(kRelease); consumer.Drain();
            CHECK(edges() == std::vector<int>{kPress});
            harness.aggregate.ClearPlane(GlfwSourcePlane::kTyped, harness.Sink());
            CHECK(edges() == (std::vector<int>{kPress, kRelease}));
        }
        if (backend == 1) inputBridge_l2SetActive(0);
        if (backend == 2) inputBridge_sdlSetActive(0);
    }
}

/**
 * 工具CANCEL独立于正常UP：未poll候选不能补成点击，已提交工具只退休自己贡献。
 * 此作用域不包含直接MENU/菜单坐标/ordinary/typed，避免取消面板时误停另一根拖动手指。
 */
void TestMenuToolCancelDoesNotExpandScope(Harness& harness) {
    for (int backend = 0; backend < 3; ++backend) {
        CausalConsumer consumer{harness, backend};
        for (int code : {-1, -2, 340}) {
            consumer.Start();
            const double keptX=142+code; // 每例不同采样，避免GLFW合法同位置去重混入scope断言。
            inputBridge_pushTouchMenuToolV1(code, kPress);
            inputBridge_pushTouchMenuToolV1(code, kRelease);
            inputBridge_publishTouchMenuCursorV1(keptX, 242);
            inputBridge_retireTouchMenuToolScopeV1(); consumer.Drain();
            bool keptCursor=false;
            for (const auto& pulse : consumer.Pulses()) {
                CHECK(pulse.kind!='b'&&pulse.kind!='k');
                if(pulse.kind=='m'&&pulse.x==keptX&&pulse.y==242)keptCursor=true;
            }
            CHECK(keptCursor); // 工具取消不能把直接菜单指针scope一起退休。
            double keptSnapshotX=0,keptSnapshotY=0;inputBridge_getCursorSnapshot(&keptSnapshotX,&keptSnapshotY);
            CHECK(keptSnapshotX==keptX&&keptSnapshotY==242);
            // independent epoch已经前进，新工具动作正常首按末松。
            inputBridge_pushTouchMenuToolV1(code,kPress);consumer.Drain();
            inputBridge_pushTouchMenuToolV1(code,kRelease);consumer.Drain();
            unsigned edges=0;for(const auto& pulse:consumer.Pulses())if(pulse.kind=='b'||pulse.kind=='k')++edges;
            CHECK(edges==2);
        }
        consumer.Start();
        inputBridge_pushEvent(kMenuEvent,kMenuDown,101,201,12500);consumer.Drain();consumer.Present();
        inputBridge_pushTouchMenuToolV1(-1,kPress);consumer.Drain();
        inputBridge_retireTouchMenuToolScopeV1();consumer.Drain();CHECK(consumer.Left()==1);
        inputBridge_pushEvent(kMenuEvent,kMenuMove,301,401,12500);consumer.Drain();
        inputBridge_pushEvent(kMenuEvent,kMenuUp,351,451,12500);consumer.Drain();
        CheckCausalDrag(consumer,101,201,301,401,351,451);

        // 菜单尚未commit时取消工具，同样不能阻止直接DOWN之后自己的present资格。
        consumer.Start();inputBridge_pushEvent(kMenuEvent,kMenuDown,102,202,12501);consumer.Drain();
        inputBridge_pushTouchMenuToolV1(-1,kPress);inputBridge_retireTouchMenuToolScopeV1();consumer.Present();
        CHECK(consumer.Left()==1);
        inputBridge_pushEvent(kMenuEvent,kMenuUp,102,202,12501);consumer.Drain();CHECK(consumer.Left()==0);
        for(int code:{-1,-2,340}){
            consumer.Start();
            const auto ordinary=[&](int action){if(code==340)inputBridge_pushEvent(kKeyEvent,340,0,action,0);
                else inputBridge_pushEvent(kButtonEvent,code==-1?0:1,action,0,0);};
            ordinary(kPress);consumer.Drain();inputBridge_pushTouchMenuToolV1(code,kPress);consumer.Drain();
            inputBridge_retireTouchMenuToolScopeV1();consumer.Drain();
            unsigned edges=0;for(const auto& pulse:consumer.Pulses())if(pulse.kind=='b'||pulse.kind=='k')++edges;
            CHECK(edges==1);ordinary(kRelease);consumer.Drain();
            edges=0;for(const auto& pulse:consumer.Pulses())if(pulse.kind=='b'||pulse.kind=='k')++edges;CHECK(edges==2);
        }
        if(backend==0){
            consumer.Start();harness.aggregate.SubmitButton(GlfwSourcePlane::kTyped,0,GlfwAggregateAction::kPress,0,harness.Sink());
            inputBridge_pushEvent(kMenuEvent,kMenuDown,103,203,12502);consumer.Drain();consumer.Present();
            inputBridge_pushTouchMenuToolV1(-1,kPress);consumer.Drain();inputBridge_retireTouchMenuToolScopeV1();consumer.Drain();
            inputBridge_pushEvent(kMenuEvent,kMenuUp,103,203,12502);consumer.Drain();CHECK(harness.buttons[0]==1);
            harness.aggregate.ClearPlane(GlfwSourcePlane::kTyped,harness.Sink());CHECK(harness.buttons[0]==0);
        }else{
            // 慢consumer已经overflow时取消工具：恢复必须复制新tool epoch，不能重放旧PRESS。
            consumer.Start();inputBridge_glfwSetActive(&harness,1);
            inputBridge_pushTouchMenuToolV1(-1,kPress);Pump(harness);consumer.Drain();
            for(int i=0;i<9;++i){inputBridge_pushEvent(1007,0,1,0,0);Pump(harness);}
            inputBridge_retireTouchMenuToolScopeV1();Pump(harness);consumer.Drain();consumer.Drain();
            CHECK(consumer.Left()==0&&harness.buttons[0]==0);
            unsigned presses=0;for(const auto& pulse:consumer.Pulses())if(pulse.kind=='b'&&pulse.code==0&&pulse.action==kPress)++presses;
            CHECK(presses==1);
        }
        if(backend==1)inputBridge_l2SetActive(0);
        if(backend==2)inputBridge_sdlSetActive(0);
    }
}

/** PRESS用户回调同步退休scope：旧批次不能松掉下一poll的新工具/菜单，也不能倒退read cursor。 */
void TestScopeRetirementInsidePressCallback(Harness& harness){
    CausalConsumer consumer{harness,0};consumer.Start();harness.buttonScopeReentry=1;
    inputBridge_pushTouchMenuToolV1(-1,kPress);
    inputBridge_pushTouchMenuToolV1(-1,kRelease);consumer.Drain();CHECK(harness.buttons[0]==0);
    consumer.Drain();CHECK(harness.buttons[0]==1);consumer.Drain();CHECK(harness.buttons[0]==1);
    inputBridge_pushTouchMenuToolV1(-1,kRelease);consumer.Drain();CHECK(harness.buttons[0]==0);
    std::vector<int> toolEdges;for(const auto& pulse:consumer.Pulses())if(pulse.kind=='b'&&pulse.code==0)toolEdges.push_back(pulse.action);
    CHECK(toolEdges==(std::vector<int>{kPress,kRelease,kPress,kRelease}));

    consumer.Start();inputBridge_pushEvent(kMenuEvent,kMenuDown,151,251,12631);
    inputBridge_pushEvent(kMenuEvent,kMenuMove,351,451,12631);
    inputBridge_pushEvent(kMenuEvent,kMenuUp,351,451,12631);consumer.Drain();
    harness.buttonScopeReentry=2;consumer.Present();CHECK(harness.buttons[0]==0&&harness.keys[67]==0);
    for(const auto& pulse:consumer.Pulses())CHECK(!(pulse.kind=='m'&&pulse.x==351&&pulse.y==451));
    consumer.Drain();CHECK(harness.buttons[0]==0&&harness.keys[67]==0);
    consumer.Present();CHECK(harness.buttons[0]==0&&harness.keys[67]==1);
    std::vector<std::pair<int,int>> clicks;unsigned newKey=0;
    for(const auto& pulse:consumer.Pulses()){
        if(pulse.kind=='b'&&pulse.code==0)clicks.emplace_back(pulse.action,static_cast<int>(pulse.x));
        if(pulse.kind=='k'&&pulse.code==67&&pulse.action==kPress)++newKey;
    }
    CHECK(clicks==(std::vector<std::pair<int,int>>{{kPress,151},{kRelease,151},{kPress,501},{kRelease,501}})&&newKey==1);
    consumer.Drain();CHECK(harness.keys[67]==1);
    inputBridge_pushEvent(kKeyEvent,67,0,kRelease,0);consumer.Drain();CHECK(harness.keys[67]==0);
}

/** 连续量也必须带作用域；取消旧工具滚轮/坐标不能误停直接菜单指针和拖动。 */
void TestMenuWheelAndToolCursorScopes(Harness& harness){
    for(int backend=0;backend<3;++backend){
        CausalConsumer consumer{harness,backend};
        const auto wheels=[&](){
            std::vector<int> values;
            for(const auto& pulse:consumer.Pulses()){
                if(pulse.kind=='s')values.push_back(pulse.action);
            }
            return values;
        };
        consumer.Start();inputBridge_publishTouchMenuScrollV1(0,1);
        inputBridge_pushTouchMenuToolScrollV1(0,2);inputBridge_pushEvent(kScrollEvent,0,3,0,0);
        inputBridge_retireTouchMenuScopeV1();inputBridge_pushEvent(kScrollEvent,0,4,0,0);consumer.Drain();
        CHECK(wheels()==(std::vector<int>{3,4})); // fullscope只撤销触控来源，ordinary历史也保留。

        consumer.Start();inputBridge_publishTouchMenuCursorV1(161,261);inputBridge_publishTouchMenuScrollV1(0,1);
        inputBridge_publishTouchMenuToolCursorV1(361,461);inputBridge_pushTouchMenuToolScrollV1(0,2);
        inputBridge_pushEvent(kScrollEvent,0,3,0,0);inputBridge_retireTouchMenuToolScopeV1();consumer.Drain();
        CHECK(wheels()==(std::vector<int>{1,3}));bool directPosition=false;
        for(const auto& pulse:consumer.Pulses()){
            CHECK(!(pulse.kind=='m'&&pulse.x==361&&pulse.y==461));
            if(pulse.kind=='m'&&pulse.x==161&&pulse.y==261)directPosition=true;
        }CHECK(directPosition);
        inputBridge_publishTouchMenuToolCursorV1(561,661);inputBridge_pushTouchMenuToolScrollV1(0,4);consumer.Drain();
        CHECK(wheels()==(std::vector<int>{1,3,4}));bool freshTool=false;
        for(const auto& pulse:consumer.Pulses()){
            if(pulse.kind=='m'&&pulse.x==561&&pulse.y==661)freshTool=true;
        }
        CHECK(freshTool);

        consumer.Start();inputBridge_pushEvent(kMenuEvent,kMenuDown,162,262,12640);consumer.Drain();consumer.Present();
        inputBridge_publishTouchMenuToolCursorV1(362,462);inputBridge_pushTouchMenuToolScrollV1(0,2);
        inputBridge_publishTouchMenuScrollV1(0,1);inputBridge_pushEvent(kMenuEvent,kMenuMove,262,362,12640);
        inputBridge_retireTouchMenuToolScopeV1();consumer.Drain();CHECK(consumer.Left()==1&&wheels()==std::vector<int>{1});
        for(const auto& pulse:consumer.Pulses())CHECK(!(pulse.kind=='m'&&pulse.x==362&&pulse.y==462));
        inputBridge_pushEvent(kMenuEvent,kMenuUp,462,562,12640);consumer.Drain();CheckCausalDrag(consumer,162,262,262,362,462,562);

        // 滚轮不是held状态，overflow只恢复当前owner，不能从快照重放过去的一次性滚动。
        consumer.Start();inputBridge_pushTouchMenuToolScrollV1(0,2);inputBridge_publishTouchMenuScrollV1(0,1);
        for(int i=0;i<9;++i)inputBridge_pushEvent(kScrollEvent,0,3,0,0);
        consumer.Drain();consumer.Drain();
        CHECK(wheels().empty());inputBridge_pushEvent(kScrollEvent,0,4,0,0);
        inputBridge_pushTouchMenuToolScrollV1(0,5);consumer.Drain();consumer.Drain();CHECK(wheels()==(std::vector<int>{4,5}));
        if(backend==1)inputBridge_l2SetActive(0);
        if(backend==2)inputBridge_sdlSetActive(0);
    }
}

/** 相对量是按共同顺序消费的delta，不能在producer用旧desired/ACK累计成会覆盖后到absolute的坐标。 */
void TestOrderedRelativeAndGestureCancellation(Harness& harness){
    for(int backend=0;backend<3;++backend){
        CausalConsumer consumer{harness,backend};consumer.Start();
        inputBridge_publishMenuCursor(10,20);consumer.Drain();
        inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);
        inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);consumer.Drain();
        double x=0,y=0;inputBridge_getCursorSnapshot(&x,&y);CHECK(x==12&&y==20);
        inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);
        inputBridge_publishMenuCursor(300,400);
        inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);consumer.Drain();
        inputBridge_getCursorSnapshot(&x,&y);CHECK(x==301&&y==400);
        inputBridge_publishTouchMenuToolRelativeV1(100,0,999,799);
        inputBridge_retireTouchMenuToolScopeV1();consumer.Drain();
        inputBridge_getCursorSnapshot(&x,&y);CHECK(x==301&&y==400);
        inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);consumer.Drain();
        inputBridge_getCursorSnapshot(&x,&y);CHECK(x==302&&y==400);
        inputBridge_publishTouchMenuToolRelativeV1(2000,-2000,999,799);consumer.Drain();
        inputBridge_getCursorSnapshot(&x,&y);CHECK(x==999&&y==0);

        // BEGIN只认领pointer-only手势；CANCEL在poll前到达时撤掉它的cursor/wheel/delta，不补LEFT。
        consumer.Start();inputBridge_publishMenuCursor(15,25);consumer.Drain();
        inputBridge_pushEvent(kMenuEvent,kMenuBegin,15,25,12700);
        inputBridge_pushEvent(kMenuEvent,kMenuMove,315,425,12700);
        inputBridge_publishTouchMenuScrollV1(0,1);
        inputBridge_pushEvent(kMenuEvent,kMenuCancel,0,0,12700);consumer.Drain();
        inputBridge_getCursorSnapshot(&x,&y);CHECK(x==15&&y==25);
        for(const auto& pulse:consumer.Pulses())CHECK(pulse.kind!='b'&&pulse.kind!='s');
        consumer.Start();inputBridge_publishMenuCursor(16,26);consumer.Drain();
        inputBridge_publishTouchMenuRelativeV1(kMenuBegin,12701,0,0,999,799);
        inputBridge_publishTouchMenuRelativeV1(kMenuMove,12701,50,10,999,799);
        inputBridge_publishTouchMenuRelativeV1(kMenuCancel,12701,0,0,999,799);consumer.Drain();
        inputBridge_getCursorSnapshot(&x,&y);CHECK(x==16&&y==26);
        for(const auto& pulse:consumer.Pulses())CHECK(pulse.kind!='b');

        // 两个已正常结束的短点必须保留，后来的BEGIN/DOWN不等同于取消上一项completed tap。
        consumer.Start();
        inputBridge_pushEvent(kMenuEvent,kMenuBegin,17,27,12702);
        inputBridge_pushEvent(kMenuEvent,kMenuDown,17,27,12702);
        inputBridge_pushEvent(kMenuEvent,kMenuUp,17,27,12702);
        inputBridge_pushEvent(kMenuEvent,kMenuEnd,17,27,12702);
        inputBridge_pushEvent(kMenuEvent,kMenuBegin,317,427,12703);
        inputBridge_pushEvent(kMenuEvent,kMenuDown,317,427,12703);
        inputBridge_pushEvent(kMenuEvent,kMenuUp,317,427,12703);
        inputBridge_pushEvent(kMenuEvent,kMenuEnd,317,427,12703);
        consumer.Drain();consumer.Present();consumer.Present();consumer.Drain();
        std::vector<std::pair<int,int>> clicks;
        for(const auto& pulse:consumer.Pulses())if(pulse.kind=='b'&&pulse.code==0)clicks.emplace_back(pulse.action,static_cast<int>(pulse.x));
        CHECK(clicks==(std::vector<std::pair<int,int>>{{kPress,17},{kRelease,17},{kPress,317},{kRelease,317}}));
        // 有BEGIN的UP只松LEFT，未END时仍可取消整个候选；L2已领取边沿不追溯撤回。
        consumer.Start();inputBridge_publishMenuCursor(15,25);consumer.Drain();
        inputBridge_pushEvent(kMenuEvent,kMenuBegin,18,28,12704);
        inputBridge_pushEvent(kMenuEvent,kMenuDown,18,28,12704);
        inputBridge_pushEvent(kMenuEvent,kMenuUp,18,28,12704);
        inputBridge_pushEvent(kMenuEvent,kMenuCancel,0,0,12704);consumer.Drain();consumer.Present();
        unsigned cancelledEdges=0;for(const auto& pulse:consumer.Pulses())if(pulse.kind=='b')++cancelledEdges;
        CHECK(cancelledEdges==0); // BEGIN预扫描在任何出口前见CANCEL，三个consumer都能撤完整span。
        // 已实际领取PRESS以后取消不能追溯撤回，仍要精确释放已提交的同一owner。
        consumer.Start();inputBridge_pushEvent(kMenuEvent,kMenuBegin,18,28,12705);
        inputBridge_pushEvent(kMenuEvent,kMenuDown,18,28,12705);consumer.Drain();consumer.Present();CHECK(consumer.Left()==1);
        inputBridge_pushEvent(kMenuEvent,kMenuUp,18,28,12705);inputBridge_pushEvent(kMenuEvent,kMenuCancel,0,0,12705);consumer.Drain();
        unsigned claimedEdges=0;for(const auto& pulse:consumer.Pulses())if(pulse.kind=='b')++claimedEdges;
        CHECK(claimedEdges==2&&consumer.Left()==0);
        // UP缺END属于仍active的旧gesture：新BEGIN可替换；正常END双tap样本在上面完整保留。
        consumer.Start();
        inputBridge_pushEvent(kMenuEvent,kMenuBegin,19,29,12706);
        inputBridge_pushEvent(kMenuEvent,kMenuDown,19,29,12706);
        inputBridge_pushEvent(kMenuEvent,kMenuUp,19,29,12706);
        inputBridge_pushEvent(kMenuEvent,kMenuBegin,319,429,12707);
        inputBridge_pushEvent(kMenuEvent,kMenuDown,319,429,12707);
        inputBridge_pushEvent(kMenuEvent,kMenuUp,319,429,12707);
        inputBridge_pushEvent(kMenuEvent,kMenuEnd,0,0,12707);consumer.Drain();consumer.Present();consumer.Present();
        clicks.clear();for(const auto& pulse:consumer.Pulses())if(pulse.kind=='b'&&pulse.code==0)clicks.emplace_back(pulse.action,static_cast<int>(pulse.x));
        const std::vector<std::pair<int,int>> completedNew{{kPress,319},{kRelease,319}};
        CHECK(clicks==completedNew); // 两span都未领取时，新BEGIN替换缺END旧gesture，所有后端同样撤旧。
        if(backend==1)inputBridge_l2SetActive(0);
        if(backend==2)inputBridge_sdlSetActive(0);
    }
}

/** 退休的面板坐标不能跨模态移动新场景；普通有序坐标和新scope坐标仍逐条接受。 */
void TestScopedMenuCursorRetirement(Harness& harness) {
    for (int backend = 0; backend < 3; ++backend) {
        CausalConsumer consumer{harness, backend}; consumer.Start();
        inputBridge_publishTouchMenuCursorV1(121, 221);
        inputBridge_retireTouchMenuScopeV1();
        inputBridge_publishMenuCursor(321, 421); consumer.Drain();
        for (const auto& pulse : consumer.Pulses())
            CHECK(!(pulse.kind == 'm' && pulse.x == 121 && pulse.y == 221));
        double x = 0, y = 0; inputBridge_getCursorSnapshot(&x, &y); CHECK(x == 321 && y == 421);
        inputBridge_publishTouchMenuCursorV1(521, 621); consumer.Drain();
        bool newScopePosition = false;
        for (const auto& pulse : consumer.Pulses())
            if (pulse.kind == 'm' && pulse.x == 521 && pulse.y == 621) newScopePosition = true;
        CHECK(newScopePosition);
        if (backend == 1) inputBridge_l2SetActive(0);
        if (backend == 2) inputBridge_sdlSetActive(0);
    }
}

/** 慢consumer恢复真实producer tool快照；scope换代后旧快照不复活，快GLFW持有不被误清。 */
void TestMenuToolOverflowSnapshotIsScopeBound(Harness& harness) {
    for (int backend : {1, 2}) for (int code : {-1, -2, 340}) {
        CausalConsumer consumer{harness, backend}; consumer.Start();
        inputBridge_glfwSetActive(&harness, 1);
        inputBridge_pushTouchMenuToolV1(code, kPress); Pump(harness); consumer.Drain();
        // 真实8槽ring：只让GLFW及时读，L2/SDL落后一圈触发自己的局部快照恢复。
        for (int i = 0; i < 9; ++i) { inputBridge_pushEvent(1007, 0, 1, 0, 0); Pump(harness); }
        consumer.Drain(); consumer.Drain();
        const auto count = [&](int action) {
            unsigned result = 0;
            for (const auto& pulse : consumer.Pulses()) if (pulse.action == action &&
                ((code == 340 && pulse.kind == 'k' && pulse.code == 340) ||
                 (code != 340 && pulse.kind == 'b' && pulse.code == (code == -1 ? 0 : 1)))) ++result;
            return result;
        };
        CHECK(count(kPress) == 2); // 最初按下与该慢consumer RESET后的真实当前快照。
        if (code == 340) CHECK(harness.keys[340] == 1);
        else CHECK(harness.buttons[code == -1 ? 0 : 1] == 1);
        inputBridge_retireTouchMenuScopeV1(); Pump(harness); consumer.Drain();
        CHECK(count(kRelease) == 1);
        if (code == 340) CHECK(harness.keys[340] == 0);
        else CHECK(harness.buttons[code == -1 ? 0 : 1] == 0);
        // 再次overflow时，producer镜像已移除旧scope；不能把旧tool PRESS还原。
        const unsigned before = count(kPress);
        for (int i = 0; i < 9; ++i) { inputBridge_pushEvent(1007, 0, 1, 0, 0); Pump(harness); }
        consumer.Drain(); consumer.Drain(); CHECK(count(kPress) == before);
        if (backend == 1) inputBridge_l2SetActive(0);
        if (backend == 2) inputBridge_sdlSetActive(0);
    }
}

/** 真正目标/代次的present才给候选资格；换目标退休，已绑定身份后匿名帧不能解锁。 */
void TestGlfwMenuPresentTargetIdentity(Harness& harness) {
    const uint64_t window = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(&harness));
    for (bool wrongWindow : {false, true}) {
        CausalConsumer consumer{harness, 0}; consumer.Start();
        inputBridge_notifyFramePresentedForTargetV1(window, 800);
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 91, 101, 12400); consumer.Drain();
        inputBridge_notifyFramePresentedForTargetV1(wrongWindow ? window + 1 : window, wrongWindow ? 800 : 801);
        consumer.Drain();
        inputBridge_notifyFramePresentedForTargetV1(window, 800);
        inputBridge_notifyFramePresentedForTargetV1(window, 800); consumer.Drain();
        for (const auto& pulse : consumer.Pulses()) CHECK(pulse.kind != 'b');
        CHECK(consumer.Left() == 0);
    }
    CausalConsumer consumer{harness, 0}; consumer.Start();
    inputBridge_notifyFramePresentedForTargetV1(window, 802);
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 92, 102, 12401); consumer.Drain();
    inputBridge_notifyFramePresented(); inputBridge_notifyFramePresented(); consumer.Drain();
    CHECK(consumer.Left() == 0);
    inputBridge_notifyFramePresentedForTargetV1(window, 802);
    inputBridge_notifyFramePresentedForTargetV1(window, 802); consumer.Drain();
    CHECK(consumer.Left() == 1);
    inputBridge_pushEvent(kMenuEvent, kMenuUp, 92, 102, 12401); consumer.Drain();
    CHECK(consumer.Left() == 0);
}

/** GLFW的WSI counter并非window指针；精确映射、pubgen退休和overflow快照共用实际出口验证。 */
void TestGlfwLogicalTargetMapsActualWsiIdentity(Harness& harness) {
    const uint64_t window = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(&harness));
    CausalConsumer consumer{harness, 0}; consumer.Start();
    const auto leftEdges = [&]() {
        unsigned result = 0;
        for (const auto& pulse : consumer.Pulses()) if (pulse.kind == 'b' && pulse.code == 0) ++result;
        return result;
    };
    inputBridge_glfwSetTargetV1(window, 900, 42);
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 95, 105, 12420); consumer.Drain();
    inputBridge_glfwSetTargetV1(window, 900, 42); // 完全相同重发幂等，不能撤销候选。
    inputBridge_notifyFramePresented(); inputBridge_notifyFramePresented();
    inputBridge_notifyFramePresentedForTargetV1(43, 500); consumer.Drain();
    CHECK(consumer.Left() == 0 && leftEdges() == 0);
    inputBridge_notifyFramePresentedForTargetV1(42, 500);
    inputBridge_notifyFramePresentedForTargetV1(42, 500); consumer.Drain();
    CHECK(consumer.Left() == 1 && leftEdges() == 1);
    inputBridge_pushEvent(kMenuEvent, kMenuUp, 95, 105, 12420); consumer.Drain();
    CHECK(consumer.Left() == 0 && leftEdges() == 2);

    consumer.Start(); inputBridge_glfwSetTargetV1(window, 901, 42);
    inputBridge_pushEvent(kButtonEvent, 1, kPress, 0, 0); consumer.Drain();
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 96, 106, 12421); consumer.Drain();
    inputBridge_glfwSetTargetV1(window, 902, 42);
    inputBridge_notifyFramePresentedForTargetV1(42, 501);
    inputBridge_notifyFramePresentedForTargetV1(42, 501); consumer.Drain();
    CHECK(consumer.Left() == 0 && leftEdges() == 0 && harness.buttons[1] == 1);
    inputBridge_pushEvent(kButtonEvent, 1, kRelease, 0, 0); consumer.Drain(); CHECK(harness.buttons[1] == 0);

    // pubgen变化只退休旧tool，不清producer其它域；旧tool firstAcquire在cutoff前，恢复必须排除。
    consumer.Start(); inputBridge_pushTouchMenuToolV1(-1, kPress); consumer.Drain();
    CHECK(consumer.Left() == 1);
    inputBridge_publishTouchMenuToolCursorV1(132, 232);
    inputBridge_pushTouchMenuToolScrollV1(0,6);
    inputBridge_pushEvent(kScrollEvent,0,7,0,0);
    inputBridge_glfwSetTargetV1(window, 903, 42);
    inputBridge_publishMenuCursor(332, 432); consumer.Drain();
    CHECK(consumer.Left() == 0 && leftEdges() == 2);
    for (const auto& pulse : consumer.Pulses()) CHECK(!(pulse.kind == 'm' && pulse.x == 132 && pulse.y == 232));
    std::vector<int> targetWheels;
    for(const auto& pulse:consumer.Pulses())if(pulse.kind=='s')targetWheels.push_back(pulse.action);
    CHECK(targetWheels==std::vector<int>{7});
    for (int i = 0; i < 9; ++i) inputBridge_pushEvent(1007, 0, 1, 0, 0);
    consumer.Drain(); consumer.Drain(); CHECK(consumer.Left() == 0 && leftEdges() == 2);
    for(const auto& pulse:consumer.Pulses())if(pulse.kind=='s')CHECK(pulse.action!=6);
    inputBridge_pushTouchMenuToolV1(-1, kRelease); consumer.Drain();
    inputBridge_pushTouchMenuToolV1(-1, kPress); consumer.Drain(); CHECK(consumer.Left() == 1 && leftEdges() == 3);
    inputBridge_glfwSetTargetV1(window, 903, 42); consumer.Drain(); CHECK(consumer.Left() == 1);
    inputBridge_pushTouchMenuToolV1(-1, kRelease); consumer.Drain(); CHECK(consumer.Left() == 0 && leftEdges() == 4);

    // 实际Vulkan worker可以在另一线程报告present；sole consumer仍只在当前线程操作菜单。
    // join提供明确先后关系，不用sleep猜测某一帧是否已被clock观察。
    consumer.Start(); inputBridge_glfwSetTargetV1(window, 904, 44);
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 97, 107, 12422); consumer.Drain();
    std::thread firstFrame([]{inputBridge_notifyFramePresentedForTargetV1(44, 502);}); firstFrame.join();
    consumer.Drain(); CHECK(consumer.Left() == 0);
    std::thread secondFrame([]{inputBridge_notifyFramePresentedForTargetV1(44, 502);}); secondFrame.join();
    consumer.Drain(); CHECK(consumer.Left() == 1);
    inputBridge_pushEvent(kMenuEvent, kMenuMove, 197, 207, 12422); consumer.Drain();
    inputBridge_pushEvent(kMenuEvent, kMenuUp, 397, 407, 12422); consumer.Drain();
    CheckCausalDrag(consumer, 97, 107, 197, 207, 397, 407);

    // worker已启动、尚未发帧时owner换target：旧/错误counter不能给新候选解锁。
    consumer.Start(); std::atomic<bool> report{false};
    std::thread retiredWorker([&]{while(!report.load(std::memory_order_acquire))std::this_thread::yield();
        inputBridge_notifyFramePresentedForTargetV1(44, 502);
        inputBridge_notifyFramePresentedForTargetV1(46, 503);});
    inputBridge_glfwSetTargetV1(window, 905, 45);
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 98, 108, 12423); consumer.Drain();
    report.store(true,std::memory_order_release);retiredWorker.join();consumer.Drain();
    CHECK(consumer.Left() == 0 && leftEdges() == 0);
    std::thread currentFrames([]{inputBridge_notifyFramePresentedForTargetV1(45, 503);
        inputBridge_notifyFramePresentedForTargetV1(45, 503);});currentFrames.join();consumer.Drain();
    CHECK(consumer.Left() == 1 && leftEdges() == 1);
    inputBridge_pushEvent(kMenuEvent, kMenuUp, 98, 108, 12423);consumer.Drain();CHECK(consumer.Left() == 0);
}

/**
 * SDL logical input target与真实render generation是两条身份，首帧前先绑定逻辑窗口。
 * 匿名/错误窗口不能贡献present，输入pubgen换代取消旧菜单/tool，ordinary与GLFW兄弟仍持有。
 */
void TestSdlMenuLogicalAndPresentedTargetIdentity(Harness& harness) {
    CausalConsumer consumer{harness, 2}; consumer.Start();
    const uint64_t wsiIdentity = 0x8000000000000042ULL; // 真实NativeWindow命名空间，与SDL logical id独立。
    const auto leftEdges = [&]() {
        unsigned result = 0;
        for (const auto& pulse : consumer.Pulses()) if (pulse.kind == 'b' && pulse.code == 0) ++result;
        return result;
    };
    inputBridge_sdlSetTargetV1(991, 77, wsiIdentity);
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 93, 103, 12410); consumer.Drain();
    inputBridge_sdlSetTargetV1(991, 77, wsiIdentity); // 同logical target重发幂等，不退休刚建立的候选。
    inputBridge_sdlNotifyFramePresented();
    inputBridge_sdlNotifyFramePresentedForTargetV1(992, 500); consumer.Drain();
    inputBridge_sdlNotifyFramePresentedForTargetV1(wsiIdentity + 1, 500); consumer.Drain();
    CHECK(consumer.Left() == 0 && leftEdges() == 0);
    // render generation=500与input generation=77无相等要求；实际首帧窗口必须991。
    inputBridge_sdlNotifyFramePresentedForTargetV1(wsiIdentity, 500); consumer.Drain();
    CHECK(consumer.Left() == 1 && leftEdges() == 1);
    inputBridge_pushEvent(kMenuEvent, kMenuUp, 93, 103, 12410); consumer.Drain();
    CHECK(consumer.Left() == 0 && leftEdges() == 2);

    consumer.Start(); inputBridge_sdlSetTargetV1(991, 78, wsiIdentity);
    inputBridge_pushEvent(kButtonEvent, 1, kPress, 0, 0); consumer.Drain();
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 94, 104, 12411); consumer.Drain();
    inputBridge_sdlSetTargetV1(991, 79, wsiIdentity);
    inputBridge_sdlNotifyFramePresentedForTargetV1(991, 500); consumer.Drain();
    CHECK(consumer.Left() == 0 && leftEdges() == 0);
    inputBridge_pushEvent(kButtonEvent, 1, kRelease, 0, 0); consumer.Drain();
    std::vector<int> right;
    for (const auto& pulse : consumer.Pulses()) if (pulse.kind == 'b' && pulse.code == 1) right.push_back(pulse.action);
    CHECK(right == (std::vector<int>{kPress, kRelease}));

    // 已held的tool跨target要释放且从慢SDL恢复快照中排除；兄弟GLFW没有被该局部边界清掉。
    consumer.Start(); inputBridge_glfwSetActive(&harness, 1);
    inputBridge_pushTouchMenuToolV1(-1, kPress); Pump(harness); consumer.Drain();
    CHECK(consumer.Left() == 1 && harness.buttons[0] == 1);
    inputBridge_publishTouchMenuToolCursorV1(131, 231);
    inputBridge_pushTouchMenuToolScrollV1(0,6);
    inputBridge_pushEvent(kScrollEvent,0,7,0,0);
    inputBridge_sdlSetTargetV1(991, 80, wsiIdentity);
    inputBridge_publishMenuCursor(331, 431); consumer.Drain();
    CHECK(consumer.Left() == 0 && leftEdges() == 2 && harness.buttons[0] == 1);
    for (const auto& pulse : consumer.Pulses()) CHECK(!(pulse.kind == 'm' && pulse.x == 131 && pulse.y == 231));
    std::vector<int> targetWheels;
    for(const auto& pulse:consumer.Pulses())if(pulse.kind=='s')targetWheels.push_back(pulse.action);
    CHECK(targetWheels==std::vector<int>{7});
    for (int i = 0; i < 9; ++i) { inputBridge_pushEvent(1007, 0, 1, 0, 0); Pump(harness); }
    consumer.Drain(); consumer.Drain(); CHECK(consumer.Left() == 0 && leftEdges() == 2);
    for(const auto& pulse:consumer.Pulses())if(pulse.kind=='s')CHECK(pulse.action!=6);
    inputBridge_pushTouchMenuToolV1(-1, kRelease); Pump(harness); consumer.Drain();
    inputBridge_pushTouchMenuToolV1(-1, kPress); Pump(harness); consumer.Drain();
    CHECK(consumer.Left() == 1 && harness.buttons[0] == 1 && leftEdges() == 3);
    inputBridge_sdlSetTargetV1(991, 80, wsiIdentity); consumer.Drain(); CHECK(consumer.Left() == 1); // 同代次不清新tool。
    inputBridge_pushTouchMenuToolV1(-1, kRelease); Pump(harness); consumer.Drain();
    CHECK(consumer.Left() == 0 && harness.buttons[0] == 0 && leftEdges() == 4);

    // Next返回源MOTION与SDK真正逐条投递MOTION之间，另一线程可能恰好呈现旧位置。
    // 此帧不能作为源点安全帧；后继Next才冻结基线，之后正确一帧仍保持原SDL+1合同。
    consumer.Start(); inputBridge_sdlSetTargetV1(991, 81, wsiIdentity);
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 99, 109, 12412);
    int type=0,a=0,b=0,c=0,d=0;
    CHECK(inputBridge_sdlNextEvent(&type,&a,&b,&c,&d)!=0&&type==kCursorEvent);
    const auto origin=DecodeCursorWire(a,b,c,d);CHECK(origin.first==99&&origin.second==109);
    std::thread earlyFrame([&]{inputBridge_sdlNotifyFramePresentedForTargetV1(wsiIdentity,501);});earlyFrame.join();
    CHECK(inputBridge_sdlNextEvent(&type,&a,&b,&c,&d)==0); // MOTION后继入口才冻结current serial+1。
    std::thread deliveredFrame([&]{inputBridge_sdlNotifyFramePresentedForTargetV1(wsiIdentity,501);});deliveredFrame.join();
    consumer.Drain();CHECK(consumer.Left()==1);
    inputBridge_pushEvent(kMenuEvent,kMenuUp,99,109,12412);consumer.Drain();CHECK(consumer.Left()==0);
    inputBridge_sdlSetActive(0);
}

/** 真正ACK只来自本局选定consumer的不可撤回出口；producer desired/common写点没有这个资格。 */
// 本宿主可用test-only入口分别检查三种cursor选择，但仍处于同一个真实进程，
// 共同look owner的会话不能随测试循环改绑；保留超过JS安全整数的原64位样本。
constexpr uint64_t kFixtureProcessSession = 9007199254740994ULL;
void TestCommittedMenuCursorAuthorityAndCancellation(Harness& harness){
    const uint64_t logical=static_cast<uint64_t>(reinterpret_cast<uintptr_t>(&harness));
    for(int backend=0;backend<3;++backend){
        inputBridge_testResetMenuCursorSelectionV1();
        inputBridge_glfwSetActive(&harness,0);inputBridge_l2SetActive(0);inputBridge_sdlSetActive(0);
        CausalConsumer consumer{harness,backend};consumer.Start();
        const uint32_t selected=static_cast<uint32_t>(backend+1);
        const uint64_t session=kFixtureProcessSession;
        CHECK(inputBridge_configureMenuCursorConsumerV1(selected,session)==1);
        CHECK(inputBridge_configureMenuCursorConsumerV1(selected,session)==1);
        CHECK(inputBridge_configureMenuCursorConsumerV1(selected,session+1)==0);
        CHECK(inputBridge_configureMenuCursorConsumerV1(selected==1?2:1,session)==0);
        inputBridge_glfwSetTargetV1(logical,4000+selected,50+selected);
        if(backend==2)inputBridge_sdlSetTargetV1(992,4000+selected,0x8000000000000050ULL+selected);
        const auto point=[&](){AmclCommittedMenuCursorV1 value{};value.structSize=sizeof(value);
            CHECK(inputBridge_getCommittedMenuCursorV1(&value)==1);return value;};
        const auto absent=[&](){AmclCommittedMenuCursorV1 value{};value.structSize=sizeof(value);value.flags=UINT32_MAX;
            CHECK(inputBridge_getCommittedMenuCursorV1(&value)==0&&value.flags==0);};
        absent();inputBridge_publishMenuCursor(20,30);consumer.Drain();
        auto original=point();CHECK(original.backend==selected&&original.gameSession==session&&original.x==20&&original.y==30);
        CHECK(original.inputPublication==4000+selected&&original.logicalTarget==(backend==2?992:logical));
        CHECK(original.structSize==sizeof(original)&&original.abiVersion==1&&original.flags==AMCL_MENU_CURSOR_COMMITTED&&original.processId!=0&&original.interactionOrder!=0);
        inputBridge_setMenuCursor(900,700); // 兼容低层write只是common值；不模拟真实consumer领取。
        CHECK(point().x==20&&point().y==30&&point().interactionOrder==original.interactionOrder);
        inputBridge_publishTouchMenuToolCursorV1(320,430); // queued B尚未poll；撤销后ACK仍A。
        inputBridge_retireTouchMenuToolScopeV1();consumer.Drain();CHECK(point().x==20&&point().y==30);
        inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);consumer.Drain();CHECK(point().x==21&&point().y==30);
        inputBridge_publishTouchMenuToolCursorV1(100,200);consumer.Drain();CHECK(point().x==100&&point().y==200);
        inputBridge_publishTouchMenuToolCursorV1(500,600);inputBridge_retireTouchMenuToolScopeV1();consumer.Drain();
        CHECK(point().x==100&&point().y==200);
        inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);consumer.Drain();CHECK(point().x==101&&point().y==200);
        inputBridge_retireTouchMenuScopeV1();absent();
        inputBridge_publishTouchMenuToolRelativeV1(1,0,999,799);consumer.Drain();CHECK(point().x==102&&point().y==200);

        // 兄弟GLFW消费B不得污染已选定L2/SDL的C。fullscope只撤交付资格，仍需在本consumer的
        // current C释放工具，随后按共同order领取普通B；不能因ACK失效退回common最新B释放。
        if(backend!=0){
            inputBridge_pushTouchMenuToolV1(-1,kPress);consumer.Drain();CHECK(consumer.Left()==1);
            inputBridge_glfwSetActive(&harness,1);inputBridge_publishMenuCursor(900,700);Pump(harness);
            CHECK(point().x==102&&point().y==200);
            inputBridge_retireTouchMenuScopeV1();absent();
            double currentX=0,currentY=0;inputBridge_getCursorSnapshot(&currentX,&currentY);
            CHECK(currentX==102&&currentY==200);
            const size_t beforeRelease=consumer.Pulses().size();consumer.Drain();
            CHECK(consumer.Left()==0&&point().x==900&&point().y==700);
            bool releasedAtC=false,movedToB=false;
            for(size_t i=beforeRelease;i<consumer.Pulses().size();++i){const auto& pulse=consumer.Pulses()[i];
                if(pulse.kind=='b'&&pulse.code==0&&pulse.action==kRelease){
                    CHECK(!movedToB&&pulse.x==102&&pulse.y==200);releasedAtC=true;}
                if(pulse.kind=='m'&&pulse.x==900&&pulse.y==700){CHECK(releasedAtC);movedToB=true;}
            }
            CHECK(releasedAtC&&movedToB);inputBridge_glfwSetActive(&harness,0);
        }
        inputBridge_setGrabState(1);absent();inputBridge_setGrabState(0);absent();
        inputBridge_publishMenuCursor(22,32);consumer.Drain();CHECK(point().x==22);
        if(backend==2)inputBridge_sdlSetTargetV1(992,5000+selected,0x8000000000000050ULL+selected);
        else inputBridge_glfwSetTargetV1(logical,5000+selected,50+selected);
        absent();inputBridge_publishMenuCursor(23,33);consumer.Drain();CHECK(point().inputPublication==5000+selected);
        inputBridge_cancelAllState(&harness,5);consumer.Drain();absent();
        if(backend==0)inputBridge_glfwSetActive(&harness,0);
        if(backend==1)inputBridge_l2SetActive(0);
        if(backend==2)inputBridge_sdlSetActive(0);
    }
    inputBridge_testResetMenuCursorSelectionV1();
}

/** L2真实provider target换代后的工具退休不能在局部overflow snapshot中恢复，ordinary继续持有。 */
void TestL2TargetRetiredToolNotReplayedByOverflow(Harness& harness){
    inputBridge_testResetMenuCursorSelectionV1();inputBridge_glfwSetActive(&harness,0);
    inputBridge_l2SetActive(0);CausalConsumer consumer{harness,1};consumer.Start();
    CHECK(inputBridge_configureMenuCursorConsumerV1(AMCL_MENU_CURSOR_BACKEND_LWJGL2,kFixtureProcessSession)==1);
    const uint64_t logical=static_cast<uint64_t>(reinterpret_cast<uintptr_t>(&harness));
    inputBridge_glfwSetTargetV1(logical,6000,62);
    inputBridge_pushEvent(kButtonEvent,1,kPress,0,0);inputBridge_pushTouchMenuToolV1(-1,kPress);consumer.Drain();CHECK(consumer.Left()==1);
    inputBridge_glfwSetTargetV1(logical,6001,62);consumer.Drain();CHECK(consumer.Left()==0);
    for(int i=0;i<9;++i)inputBridge_pushEvent(kScrollEvent,0,1,0,0);
    consumer.Drain();consumer.Drain();
    unsigned leftPresses=0,rightPresses=0,rightReleases=0;
    for(const auto& pulse:consumer.Pulses())if(pulse.kind=='b'){
        if(pulse.code==0&&pulse.action==kPress)++leftPresses;
        if(pulse.code==1&&pulse.action==kPress)++rightPresses;
        if(pulse.code==1&&pulse.action==kRelease)++rightReleases;
    }
    CHECK(consumer.Left()==0&&leftPresses==1&&rightPresses==2&&rightReleases==0);
    inputBridge_pushEvent(kButtonEvent,1,kRelease,0,0);consumer.Drain();
    CHECK(!consumer.Pulses().empty()&&consumer.Pulses().back().kind=='b'&&consumer.Pulses().back().code==1&&consumer.Pulses().back().action==kRelease);
    inputBridge_l2SetActive(0);inputBridge_testResetMenuCursorSelectionV1();
}

/** L2完整reset必须成对退休token与gestureBegun，否则新旧ABI raw UP不能结束误继承的BEGIN身份。 */
void TestL2ResetDoesNotCarryGestureBegun(Harness& harness){
    for(int boundary=0;boundary<3;++boundary){
        CausalConsumer consumer{harness,1};consumer.Start();
        const int oldToken=12800+boundary*2,newToken=oldToken+1;
        inputBridge_pushEvent(kMenuEvent,kMenuBegin,40,50,oldToken);consumer.Drain();
        if(boundary==0)inputBridge_cancelAllState(&harness,5);
        if(boundary==1){inputBridge_l2SetActive(0);inputBridge_l2SetActive(1);}
        if(boundary==2)for(int i=0;i<9;++i)inputBridge_pushEvent(kScrollEvent,0,1,0,0);
        consumer.Drain();consumer.Drain();
        inputBridge_pushEvent(kMenuEvent,kMenuDown,30,40,newToken);consumer.Drain();CHECK(consumer.Left()==1);
        inputBridge_pushEvent(kMenuEvent,kMenuUp,31,41,newToken);consumer.Drain();CHECK(consumer.Left()==0);
        inputBridge_pushEvent(kMenuEvent,kMenuMove,631,741,newToken);consumer.Drain();
        double x=0,y=0;inputBridge_getCursorSnapshot(&x,&y);CHECK(x==31&&y==41);
        inputBridge_l2SetActive(0);
    }
}

/** 同一生产事务在三 ABI 的正常END和退休后不能留下旧阶段：LEFT已交付后UP携
 * 终点，再END正常闭合；旧token MOVE必须拒绝，新token立即能开始新操作。这里通过
 * callback/Next观察真实bridge，既不实例化替代状态机，也不把最终状态代替事件轨迹。 */
void TestCommonTransactionEndAndFreshContact(Harness& harness) {
    for (int backend = 0; backend < 3; ++backend) {
        CausalConsumer consumer{harness, backend}; consumer.Start();
        const int first = 12850 + backend * 2, second = first + 1;
        inputBridge_pushEvent(kMenuEvent, kMenuBegin, 41, 51, first);
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 41, 51, first);
        consumer.Drain(); consumer.Present();
        CHECK(consumer.Left() == 1);
        // BEGIN 后的首个 DOWN 已经成立；重复同 token 的 DOWN 不能再次等待呈现，
        // 也不能把 hostile 坐标当新源点。这与原有真实UP/END闭合一起检查同一生产接线。
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 841, 851, first); consumer.Drain();
        double duplicateX = 0, duplicateY = 0;
        inputBridge_getCursorSnapshot(&duplicateX, &duplicateY);
        CHECK(duplicateX == 41 && duplicateY == 51 && consumer.Left() == 1);
        inputBridge_pushEvent(kMenuEvent, kMenuUp, 341, 451, first);
        consumer.Drain(); CHECK(consumer.Left() == 0);
        // UP 已结束按钮角色，END 尚未到达；同 token 的迟到 DOWN 仍不能变成第二次点击。
        // 保留 BEGIN 的结束身份不代表重新授予按钮认领资格。
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 541, 551, first); consumer.Drain();
        inputBridge_getCursorSnapshot(&duplicateX, &duplicateY);
        CHECK(duplicateX == 341 && duplicateY == 451 && consumer.Left() == 0);
        inputBridge_pushEvent(kMenuEvent, kMenuEnd, 0, 0, first);
        consumer.Drain(); consumer.Drain(); CHECK(consumer.Left() == 0);
        bool endpointHeld = false, releasedAfterEndpoint = false;
        for (const auto& pulse : consumer.Pulses()) {
            if (pulse.kind == 'm' && pulse.x == 341 && pulse.y == 451) {
                CHECK(pulse.left == 1); endpointHeld = true;
            }
            if (pulse.kind == 'b' && pulse.code == 0 && pulse.action == kRelease) {
                CHECK(endpointHeld); releasedAfterEndpoint = true;
            }
        }
        CHECK(endpointHeld && releasedAfterEndpoint);
        inputBridge_pushEvent(kMenuEvent, kMenuMove, 941, 951, first); consumer.Drain();
        double x = 0, y = 0; inputBridge_getCursorSnapshot(&x, &y); CHECK(x == 341 && y == 451);
        inputBridge_pushEvent(kMenuEvent, kMenuDown, 61, 71, second);
        consumer.Drain(); consumer.Present(); CHECK(consumer.Left() == 1);
        inputBridge_pushEvent(kMenuEvent, kMenuCancel, 0, 0, second);
        consumer.Drain(); CHECK(consumer.Left() == 0);
        if (backend == 1) inputBridge_l2SetActive(0);
        if (backend == 2) inputBridge_sdlSetActive(0);
    }
}

/** 输入资源publication与Touch UI token/schema是独立身份。Native schema生产反例单独
 * 证明feedback-only不退休menu scope；此处用真实TouchPublicationState及完整shipping
 * bridge验证其之后仍待消费的END前缀，不能只用“退休计数没有增加”代替实际最终边沿。
 * 平台边界提供未变的真实target tuple和帧；实际资源publication变更仍必须拒绝旧前缀。
 */
void TestCompletedMenuPrefixSurvivesFeedbackPublication(Harness& harness) {
    const uint64_t window=static_cast<uint64_t>(reinterpret_cast<uintptr_t>(&harness));
    for(int backend=0;backend<3;++backend) {
        CausalConsumer consumer{harness,backend};consumer.Start();
        const uint64_t resourcePublication=31000+backend,wsi=32000+backend;
        inputBridge_glfwSetTargetV1(window,resourcePublication,wsi);
        if(backend==2)inputBridge_sdlSetTargetV1(991,resourcePublication,wsi);
        TouchPublicationState ui;
        TouchPublicationContext context;context.surface=resourcePublication;context.session=3;
        context.policy=1;context.schema=10;context.grabEpoch=1;context.nativeTouches=0;
        const auto initial=ui.Begin("feedback-base","feedback-base-candidate",context,context);
        CHECK(initial.status==TouchPublicationStatus::Fenced);
        CHECK(ui.Prepare("feedback-base",context).status==TouchPublicationStatus::Fenced);
        ui.Complete(context,false);CHECK(ui.Confirm("feedback-base",initial.token,context));

        // 源动作已正常END但尚未进行第一次consumer poll；反馈发布不能改写/撤销该合法tap。
        const int gesture=13100+backend*2;
        inputBridge_pushEvent(kMenuEvent,kMenuBegin,71,81,gesture);
        inputBridge_pushEvent(kMenuEvent,kMenuDown,71,81,gesture);
        inputBridge_pushEvent(kMenuEvent,kMenuUp,73,83,gesture);
        inputBridge_pushEvent(kMenuEvent,kMenuEnd,0,0,gesture);
        const auto feedback=ui.Begin("feedback-next","feedback-next-candidate",context,context);
        CHECK(feedback.status==TouchPublicationStatus::Fenced&&feedback.token!=initial.token);
        CHECK(ui.Prepare("feedback-next",context).status==TouchPublicationStatus::Fenced);
        ++context.schema;ui.Complete(context,false);
        CHECK(!ui.Confirm("feedback-base",initial.token,context));
        CHECK(ui.Confirm("feedback-next",feedback.token,context));
        CHECK(ui.Query(context).context.surface==resourcePublication);

        for(int poll=0;poll<3;++poll) {
            consumer.Drain();
            if(backend==2)inputBridge_sdlNotifyFramePresentedForTargetV1(wsi,700+backend);
            else {
                inputBridge_notifyFramePresentedForTargetV1(wsi,700+backend);
                inputBridge_notifyFramePresentedForTargetV1(wsi,700+backend);
            }
        }
        consumer.Drain();unsigned presses=0,releases=0;
        for(const auto& pulse:consumer.Pulses())if(pulse.kind=='b'&&pulse.code==0) {
            if(pulse.action==kPress){++presses;CHECK(pulse.x==71&&pulse.y==81);}
            if(pulse.action==kRelease){++releases;CHECK(pulse.x==73&&pulse.y==83);}
        }
        CHECK(presses==1&&releases==1&&consumer.Left()==0);

        // 真实资源变化不是反馈：同样已经END的旧前缀不得被新target接收或补成新点击。
        inputBridge_pushEvent(kMenuEvent,kMenuBegin,171,181,gesture+1);
        inputBridge_pushEvent(kMenuEvent,kMenuDown,171,181,gesture+1);
        inputBridge_pushEvent(kMenuEvent,kMenuUp,173,183,gesture+1);
        inputBridge_pushEvent(kMenuEvent,kMenuEnd,0,0,gesture+1);
        inputBridge_glfwSetTargetV1(window,resourcePublication+100,wsi);
        if(backend==2)inputBridge_sdlSetTargetV1(991,resourcePublication+100,wsi);
        consumer.Drain();
        if(backend==2)inputBridge_sdlNotifyFramePresentedForTargetV1(wsi,700+backend);
        else {inputBridge_notifyFramePresentedForTargetV1(wsi,700+backend);inputBridge_notifyFramePresentedForTargetV1(wsi,700+backend);}
        consumer.Drain();unsigned finalEdges=0;
        for(const auto& pulse:consumer.Pulses())if(pulse.kind=='b'&&pulse.code==0)++finalEdges;
        CHECK(finalEdges==2&&consumer.Left()==0);
    }
    std::cout<<"PASS completed menu prefix survives new feedback UI token/schema through three shipping consumers; resource change rejects old prefix\n";
}

void TestSdlMenuPointerPresentBarrier(Harness& harness) {
    CausalConsumer consumer{harness, 2};
    const auto buttons = [&]() {
        std::vector<int> edges;
        for (const auto& pulse : consumer.Pulses())
            if (pulse.kind == 'b' && pulse.code == 0) edges.push_back(pulse.action);
        return edges;
    };
    // SDL 在自己的呈现会话消费，位置出口可以立即发布，PRESS 仍必须等真实帧资格。
    // 此处检查按钮合同，不能再把“没有任何输出”当作屏障，因为有序1010也属于合法输出。
    consumer.Start();
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 101, 202, 5001);
    consumer.Drain();
    CHECK(buttons().empty() && consumer.Left() == 0);
    double x = 0, y = 0;
    inputBridge_getCursorSnapshot(&x, &y);
    CHECK(x == 101.0 && y == 202.0);
    consumer.Drain(); CHECK(buttons().empty());
    consumer.Present(); CHECK(buttons() == std::vector<int>{kPress});
    inputBridge_pushEvent(kMenuEvent, kMenuMove, 111, 212, 5001);
    consumer.Drain(); CHECK(consumer.Left() == 1);
    inputBridge_pushEvent(kMenuEvent, kMenuUp, 112, 213, 5001);
    consumer.Drain();
    CheckCausalDrag(consumer, 101, 202, 111, 212, 112, 213);

    // 帧门前结束的短点保留原源坐标，终点轻微抖动也先作为按住位置交付再松键。
    consumer.Start();
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 301, 402, 5002);
    inputBridge_pushEvent(kMenuEvent, kMenuUp, 302, 403, 5002);
    consumer.Drain(); CHECK(buttons().empty());
    consumer.Present();
    CHECK(buttons() == (std::vector<int>{kPress, kRelease}) && consumer.Left() == 0);
    for (const auto& pulse : consumer.Pulses()) if (pulse.kind == 'b' && pulse.action == kPress)
        CHECK(pulse.x == 301 && pulse.y == 402);

    // 取消占位0,0不能改变cursor；尚未提交的候选不因后来的present重新生成点击。
    consumer.Start();
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 501, 602, 5003);
    inputBridge_pushEvent(kMenuEvent, kMenuCancel, 0, 0, 5003);
    consumer.Drain(); consumer.Present(); CHECK(buttons().empty());
    inputBridge_getCursorSnapshot(&x, &y);
    CHECK(x == 501.0 && y == 602.0);

    // 迟到旧token既不能移动当前源点，也不能释放新事务；匹配CANCEL只退休一次。
    consumer.Start();
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 701, 802, 5004);
    inputBridge_pushEvent(kMenuEvent, kMenuUp, 702, 803, 4999);
    consumer.Drain(); consumer.Present(); CHECK(consumer.Left() == 1);
    inputBridge_getCursorSnapshot(&x, &y); CHECK(x == 701 && y == 802);
    inputBridge_pushEvent(kMenuEvent, kMenuCancel, 0, 0, 5004);
    consumer.Drain(); CHECK(buttons() == (std::vector<int>{kPress, kRelease}));
    consumer.Drain(); CHECK(buttons().size() == 2);

    // grab换代退休已提交的LEFT，并丢弃旧pending；帧恢复不能在新场景补点。
    consumer.Start();
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 901, 902, 5005);
    consumer.Drain(); consumer.Present(); CHECK(consumer.Left() == 1);
    inputBridge_setGrabState(1);
    consumer.Drain(); CHECK(buttons() == (std::vector<int>{kPress, kRelease}));
    inputBridge_setGrabState(0);
    consumer.Start();
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 1001, 1002, 5006);
    consumer.Drain(); CHECK(buttons().empty());
    inputBridge_setGrabState(1);
    consumer.Present(); CHECK(buttons().empty());
    inputBridge_setGrabState(0);

    // 窗口取消先退休整个会话；新窗口的present不能复活旧token。
    consumer.Start();
    inputBridge_pushEvent(kMenuEvent, kMenuDown, 1101, 1102, 5007);
    consumer.Drain(); CHECK(buttons().empty());
    inputBridge_cancelAllState(&harness, 5);
    consumer.Drain(); consumer.Present(); CHECK(buttons().empty() && consumer.Left() == 0);
    inputBridge_sdlSetActive(0);
}

/** 真实ledger→ring→三consumer验证菜单与面板LEFT共持、pending和token替换。 */
void TestMenuAndOrdinaryContributions(Harness& harness) {
    for (int consumer = 0; consumer < 3; ++consumer) {
        const auto start = [&]() {
            inputBridge_cancelAllState(&harness, 5);
            inputBridge_setGrabState(0);
            if (consumer == 0) inputBridge_glfwSetActive(&harness, 1);
            if (consumer == 1) inputBridge_l2SetActive(1);
            if (consumer == 2) inputBridge_sdlSetActive(1);
        };
        std::vector<int> finalEdges;
        const auto drain = [&]() {
            if (consumer == 0) {
                const size_t before = harness.buttonCallbacks.size();
                Pump(harness);
                for (size_t i = before; i < harness.buttonCallbacks.size(); ++i)
                    if (harness.buttonCallbacks[i].button == 0)
                        finalEdges.push_back(static_cast<int>(harness.buttonCallbacks[i].action));
            } else {
                int type = 0, button = 0, action = 0, c = 0, d = 0;
                for (int budget = 0; budget < 32; ++budget) {
                    const int got = consumer == 1 ? inputBridge_l2NextEvent(&type,&button,&action,&c,&d)
                        : inputBridge_sdlNextEvent(&type,&button,&action,&c,&d);
                    if (!got) break;
                    if (type == kButtonEvent && button == 0) finalEdges.push_back(action);
                }
            }
        };
        const auto present = [&]() {
            if (consumer == 0) { inputBridge_notifyFramePresented(); inputBridge_notifyFramePresented(); }
            if (consumer == 2) inputBridge_sdlNotifyFramePresented();
            drain();
        };
        InputLedger ordinary([](const Output& output, int action) {
            CHECK(output.kind == OutputKind::Mouse && output.code == 0);
            inputBridge_pushEvent(kButtonEvent, 0, action, 0, 0);
        });
        for (bool menuUpFirst : {false, true}) {
            start(); finalEdges.clear();
            inputBridge_pushEvent(kMenuEvent,kMenuDown,100,200,8100); drain(); present();
            CHECK(finalEdges == std::vector<int>{kPress});
            CHECK(ordinary.acquire(9000,{OutputKind::Mouse,0})); drain();
            CHECK(finalEdges.size() == 1u);
            if (menuUpFirst) inputBridge_pushEvent(kMenuEvent,kMenuUp,100,200,8100);
            else ordinary.releaseOwner(9000);
            drain(); CHECK(finalEdges.size() == 1u);
            if (menuUpFirst) ordinary.releaseOwner(9000);
            else inputBridge_pushEvent(kMenuEvent,kMenuUp,100,200,8100);
            drain(); CHECK(finalEdges == (std::vector<int>{kPress,kRelease}));
            if (consumer == 0) CHECK(harness.buttons[0] == 0);
        }
        // pending保留公共原始order；后到ordinary不能越过候选，但它的UP也不能取消菜单。
        if (consumer != 1) {
            start(); finalEdges.clear();
            inputBridge_pushEvent(kMenuEvent,kMenuDown,300,400,8101); drain(); CHECK(finalEdges.empty());
            CHECK(ordinary.acquire(9001,{OutputKind::Mouse,0})); drain();
            ordinary.releaseOwner(9001); drain();
            CHECK(finalEdges.empty());
            present(); CHECK(finalEdges == std::vector<int>{kPress});
            inputBridge_pushEvent(kMenuEvent,kMenuCancel,0,0,8101); drain();
            CHECK(finalEdges == (std::vector<int>{kPress,kRelease}));
        }
        // 新token替换旧menu时，仍持有的ordinary持续按下；迟到旧UP不得退休新token。
        start(); finalEdges.clear();
        CHECK(ordinary.acquire(9002,{OutputKind::Mouse,0})); drain();
        inputBridge_pushEvent(kMenuEvent,kMenuDown,10,20,8102); drain(); present();
        inputBridge_pushEvent(kMenuEvent,kMenuDown,30,40,8103); drain(); present();
        inputBridge_pushEvent(kMenuEvent,kMenuUp,10,20,8102); drain();
        ordinary.releaseOwner(9002); drain(); CHECK(finalEdges == std::vector<int>{kPress});
        inputBridge_pushEvent(kMenuEvent,kMenuUp,30,40,8103); drain();
        CHECK(finalEdges == (std::vector<int>{kPress,kRelease}));
        // 快速tap仍按各consumer原present门配对；CANCEL在pending期间不能合成点击。
        start(); finalEdges.clear();
        inputBridge_pushEvent(kMenuEvent,kMenuDown,50,60,8105);
        inputBridge_pushEvent(kMenuEvent,kMenuUp,50,60,8105); drain(); present(); drain();
        CHECK(finalEdges == (std::vector<int>{kPress,kRelease}));
        start(); finalEdges.clear();
        inputBridge_pushEvent(kMenuEvent,kMenuDown,50,60,8106);
        inputBridge_pushEvent(kMenuEvent,kMenuCancel,0,0,8106); drain(); present();
        CHECK(finalEdges == (consumer == 1 ? std::vector<int>{kPress,kRelease} : std::vector<int>{}));
        if (consumer == 1) inputBridge_l2SetActive(0);
        if (consumer == 2) inputBridge_sdlSetActive(0);
    }
    // typed物理LEFT保持最终另一plane；两个legacy贡献退休不得松掉实体鼠标。
    inputBridge_cancelAllState(&harness,5); inputBridge_glfwSetActive(&harness,1);
    harness.aggregate.SubmitButton(GlfwSourcePlane::kTyped,0,GlfwAggregateAction::kPress,0,harness.Sink());
    inputBridge_pushEvent(kMenuEvent,kMenuDown,10,20,8104); Pump(harness);
    inputBridge_notifyFramePresented(); inputBridge_notifyFramePresented(); Pump(harness);
    inputBridge_pushEvent(kButtonEvent,0,kPress,0,0); Pump(harness);
    inputBridge_pushEvent(kMenuEvent,kMenuUp,10,20,8104); Pump(harness);
    inputBridge_pushEvent(kButtonEvent,0,kRelease,0,0); Pump(harness);
    CHECK(harness.buttons[0] == 1);
    harness.aggregate.ClearPlane(GlfwSourcePlane::kTyped,harness.Sink()); CHECK(harness.buttons[0] == 0);

    // L2单独落后并overflow时，L3一直及时drain且已commit的菜单贡献必须保持。
    inputBridge_cancelAllState(&harness,5); inputBridge_glfwSetActive(&harness,1);
    inputBridge_l2SetActive(1);
    inputBridge_pushEvent(kMenuEvent,kMenuDown,10,20,8107); Pump(harness);
    inputBridge_notifyFramePresented(); inputBridge_notifyFramePresented(); Pump(harness);
    for(int i=0;i<9;++i) { inputBridge_pushEvent(1000,65,0,0,0); Pump(harness); }
    CHECK(harness.buttons[0] == 1);
    int type=0,a=0,b=0,c=0,d=0;
    CHECK(inputBridge_l2NextEvent(&type,&a,&b,&c,&d)&&type==kInputResetEvent);
    Pump(harness); CHECK(harness.buttons[0] == 1);
    inputBridge_pushEvent(kMenuEvent,kMenuUp,10,20,8107); Pump(harness);
    CHECK(harness.buttons[0] == 0); inputBridge_l2SetActive(0);
}

/**
 * producer ledger→快consumer→慢consumer overflow→生产入口对账→cutoff后RELEASE。
 * 真实tracker绑定真实ledger，证明局部恢复不能触发releaseAll；恢复基线保留scan/mods，
 * 基线之后的边沿仍从ring交付，不能用一次“兄弟暂时还按着”掩盖下一入口造成的误释放。
 */
void TestConsumerRecoveryUsesProducerSnapshot(Harness& harness) {
    for (bool sdl : {false,true}) {
        inputBridge_cancelAllState(&harness,5); inputBridge_glfwSetActive(&harness,1);
        if(sdl) inputBridge_sdlSetActive(1); else inputBridge_l2SetActive(1);
        InputLedger ordinary([](const Output& output,int action) {
            if(output.kind==OutputKind::Key) inputBridge_pushEvent(kKeyEvent,output.code,21,action,1);
            else inputBridge_pushEvent(kButtonEvent,output.code,action,2,0);
        });
        LegacyRingDiscontinuityTracker producerEntry;
        producerEntry.AbsorbLocked(inputBridge_legacyRingDiscontinuityEpochV1());
        struct Context { InputLedger* ledger; int completed=0; } context{&ordinary};
        const auto noop=[](void*){};
        LegacyRingResetSteps steps{&context,noop,[](void* raw){static_cast<Context*>(raw)->ledger->releaseAll();},
            noop,noop,noop,[](void* raw){++static_cast<Context*>(raw)->completed;}};
        CHECK(ordinary.acquire(9200,{OutputKind::Key,87}));
        CHECK(ordinary.acquire(9200,{OutputKind::Mouse,0})); Pump(harness);
        int type=0,a=0,b=0,c=0,d=0;
        const auto next=[&](){ return sdl?inputBridge_sdlNextEvent(&type,&a,&b,&c,&d)
            :inputBridge_l2NextEvent(&type,&a,&b,&c,&d); };
        while(next()){}
        // typed sibling平面一直保持SHIFT；慢consumer的1009只属于其legacy平面。
        harness.aggregate.SubmitKey(GlfwSourcePlane::kTyped,341,0,GlfwAggregateAction::kPress,0,harness.Sink());
        for(int i=0;i<9;++i){inputBridge_pushEvent(1007,0,1,0,0);Pump(harness);}
        inputBridge_pushEvent(kKeyEvent,69,44,2,0);Pump(harness); // 无owner的REPEAT不能进入恢复held镜像。
        CHECK(next()&&type==kInputResetEvent);
        const uint64_t epoch=inputBridge_legacyRingDiscontinuityEpochV1();
        CHECK(!producerEntry.ReconcileLocked(epoch,steps)&&context.completed==0);
        CHECK(ordinary.owns(9200,{OutputKind::Key,87})&&harness.keys[87]==1&&harness.buttons[0]==1);
        // 相同键的第二owner取得后退出原owner：W不松，LEFT在snapshot后真实释放。
        ordinary.acquire(9201,{OutputKind::Key,87}); CHECK(ordinary.owns(9201,{OutputKind::Key,87}));
        ordinary.releaseOwner(9200); Pump(harness);
        CHECK(harness.keys[87]==1&&harness.buttons[0]==0&&harness.keys[341]==1);
        std::vector<int> buttons;bool restoredKey=false;
        for(int frame=0;frame<2;++frame){
            // L2第一轮保留overflow时冻结的fence；cutoff之后的新UP在下一轮poll消费。
            for(int budget=0;budget<32&&next();++budget){
                if(type==kKeyEvent&&a==87){CHECK(b==21&&c==kPress&&d==1);restoredKey=true;}
                CHECK(!(type==kKeyEvent&&a==69&&c==kPress));
                if(type==kButtonEvent&&a==0)buttons.push_back(b);
            }
        }
        CHECK(restoredKey&&buttons==(std::vector<int>{kPress,kRelease}));
        ordinary.releaseOwner(9201);Pump(harness);CHECK(harness.keys[87]==0);
        bool finalRelease=false;while(next())if(type==kKeyEvent&&a==87&&c==kRelease)finalRelease=true;
        CHECK(finalRelease&&producerEntry.ResetCount()==0&&ordinary.ownerCount()==0);
        harness.aggregate.ClearPlane(GlfwSourcePlane::kTyped,harness.Sink());
        if(sdl)inputBridge_sdlSetActive(0);else inputBridge_l2SetActive(0);
    }
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
    // Java drain以EMPTY结束一帧；下一批生产发生在该边界之后。
    CHECK(!NextL2(&wire));

    // 6. 复位事件出货，且把余量清干净 —— 复位后重新攒三次才应该再出一格。
    AmclBackendInputEvent reset{};
    reset.eventType = AMCL_BACKEND_INPUT_EVENT_RESET;
    amclBackendInputHostStubPush(&wheel);
    amclBackendInputHostStubPush(&reset);
    CHECK(NextL2(&wire));
    CHECK(wire.type == 2009);
    CHECK(!NextL2(&wire));
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

struct OrderedProbe {
    Harness* harness;
    bool modifiedKey = false;
    unsigned clicks = 0u;
};

int PumpOrderedProbe(void* context, uint64_t ceiling) {
    auto& probe = *static_cast<OrderedProbe*>(context);
    auto& h = *probe.harness;
    AmclBackendInputEvent event{};
    while (amclBackendInputNextThrough(AMCL_BACKEND_INPUT_LWJGL2, &event, ceiling) == AMCL_BACKEND_INPUT_EVENT) {
        const auto action = event.action == AMCL_BACKEND_INPUT_ACTION_UP ? GlfwAggregateAction::kRelease
            : event.action == AMCL_BACKEND_INPUT_ACTION_REPEAT ? GlfwAggregateAction::kRepeat : GlfwAggregateAction::kPress;
        if (event.eventType == AMCL_BACKEND_INPUT_EVENT_KEY) {
            if (event.code == 65 && action == GlfwAggregateAction::kPress) {
                CHECK(h.aggregate.IsKeyPressed(340)); probe.modifiedKey = true;
            }
            h.aggregate.SubmitKey(GlfwSourcePlane::kTyped, event.code, 0, action, 0, h.Sink());
        } else if (event.eventType == AMCL_BACKEND_INPUT_EVENT_BUTTON) {
            if (action == GlfwAggregateAction::kPress) {
                CHECK(h.lastCursorX == 123.25 && h.lastCursorY == 45.5); ++probe.clicks;
            }
            h.aggregate.SubmitButton(GlfwSourcePlane::kTyped, event.code, action, 0, h.Sink());
        }
    }
    return 1;
}

/** snapshot的普通PRESS重放在capture fence处，未消费typed修饰键必须先交付；RESET可先行。 */
void TestRecoveryBaselineFollowsPendingTyped(Harness& h) {
    for(int consumer=0;consumer<3;++consumer)for(bool shiftReleased:{false,true}){
        inputBridge_cancelAllState(&h,5);inputBridge_glfwSetActive(&h,1);amclBackendInputHostStubReset();
        if(consumer==1)inputBridge_l2SetActive(1);if(consumer==2)inputBridge_sdlSetActive(1);
        h.expectedLeftShift=shiftReleased?0:1;
        // 已冻结的物理编码：GLFW 340、L2左Shift 42、SDL左Shift scancode225。
        const int shiftCode=consumer==0?340:consumer==1?42:225;
        auto shift=TypedKey(shiftCode,AMCL_BACKEND_INPUT_ACTION_DOWN);amclBackendInputHostStubPush(&shift);
        InputLedger ordinary([](const Output& output,int action){inputBridge_pushEvent(kButtonEvent,output.code,action,0,0);});
        CHECK(ordinary.acquire(9400,{OutputKind::Mouse,0}));
        if(shiftReleased){shift.action=AMCL_BACKEND_INPUT_ACTION_UP;amclBackendInputHostStubPush(&shift);}
        for(int i=0;i<9;++i)inputBridge_pushEvent(1007,0,1,0,0);
        if(consumer==0){
            OrderedProbe probe{&h};inputBridgeStartPumping();
            inputBridge_pumpOrdered(&h,PumpOrderedProbe,&probe,amclInputInteractionFence());inputBridgeStopPumping();
        }else{
            int type=0,a=0,b=0,c=0,d=0;
            for(int budget=0;budget<64;++budget){
                if(consumer==2){
                    // 与现役SDL ordered pump同样先按legacy队首/帧fence抽typed，再抽一条legacy。
                    const uint64_t order=inputBridge_sdlPeekOrder();AmclBackendInputEvent event{};
                    if(amclBackendInputNextThrough(AMCL_BACKEND_INPUT_SDL3,&event,order)==AMCL_BACKEND_INPUT_EVENT){
                        h.aggregate.SubmitKey(GlfwSourcePlane::kTyped,340,0,
                            event.action==AMCL_BACKEND_INPUT_ACTION_UP?GlfwAggregateAction::kRelease:GlfwAggregateAction::kPress,0,h.Sink());
                        continue;
                    }
                    if(!inputBridge_sdlNextThrough(&type,&a,&b,&c,&d,order))break;
                }else if(!inputBridge_l2NextEvent(&type,&a,&b,&c,&d))break;
                if(type==2005)h.aggregate.SubmitKey(GlfwSourcePlane::kTyped,340,0,
                    c==0?GlfwAggregateAction::kRelease:GlfwAggregateAction::kPress,0,h.Sink());
                else if(type==kButtonEvent)h.aggregate.SubmitButton(GlfwSourcePlane::kLegacy,a,
                    b==0?GlfwAggregateAction::kRelease:GlfwAggregateAction::kPress,0,h.Sink());
                else if(type==kInputResetEvent)h.aggregate.ClearPlane(GlfwSourcePlane::kLegacy,h.Sink());
            }
        }
        CHECK(h.buttons[0]==1&&h.keys[340]==(shiftReleased?0:1));h.expectedLeftShift=-1;
        ordinary.releaseOwner(9400);
        if(consumer==0){OrderedProbe probe{&h};inputBridgeStartPumping();inputBridge_pumpOrdered(&h,PumpOrderedProbe,&probe,UINT64_MAX);inputBridgeStopPumping();}
        else{int type=0,a=0,b=0,c=0,d=0;for(int frame=0;frame<2;++frame)
            while(consumer==1?inputBridge_l2NextEvent(&type,&a,&b,&c,&d):inputBridge_sdlNextEvent(&type,&a,&b,&c,&d))
                if(type==kButtonEvent)h.aggregate.SubmitButton(GlfwSourcePlane::kLegacy,a,
                    b==0?GlfwAggregateAction::kRelease:GlfwAggregateAction::kPress,0,h.Sink());}
        CHECK(h.buttons[0]==0);h.aggregate.ClearPlane(GlfwSourcePlane::kTyped,h.Sink());
        if(consumer==1)inputBridge_l2SetActive(0);if(consumer==2)inputBridge_sdlSetActive(0);
    }
}

/** 生产ledger允许511/512；两者的当前持有及末owner RELEASE都必须在overflow后保留原始ABI。 */
void TestHighLegacyKeyRecovery(Harness& h){
    for(int consumer=0;consumer<3;++consumer){
        inputBridge_cancelAllState(&h,5);inputBridge_glfwSetActive(&h,1);amclBackendInputHostStubReset();
        if(consumer==1)inputBridge_l2SetActive(1);if(consumer==2)inputBridge_sdlSetActive(1);
        h.rawHighKeyEdges.clear();std::vector<std::pair<int,int>>wireEdges;
        InputLedger ordinary([](const Output& output,int action){inputBridge_pushEvent(kKeyEvent,output.code,31,action,0);});
        ordinary.acquire(9500,{OutputKind::Key,511});ordinary.acquire(9500,{OutputKind::Key,512});
        ordinary.acquire(9501,{OutputKind::Key,512});
        for(int i=0;i<9;++i)inputBridge_pushEvent(1007,0,1,0,0);
        const auto drain=[&](){if(consumer==0){Pump(h);Pump(h);return;}
            for(int frame=0;frame<2;++frame){int type=0,a=0,b=0,c=0,d=0;
                while(consumer==1?inputBridge_l2NextEvent(&type,&a,&b,&c,&d):inputBridge_sdlNextEvent(&type,&a,&b,&c,&d))
                    if(type==kKeyEvent&&(a==511||a==512))wireEdges.emplace_back(a,c);}};
        drain();const auto&edges=consumer==0?h.rawHighKeyEdges:wireEdges;
        CHECK(edges==(std::vector<std::pair<int,int>>{{511,1},{512,1}}));
        ordinary.releaseOwner(9500);drain();CHECK(edges.back()==std::make_pair(511,0));
        CHECK(ordinary.owns(9501,{OutputKind::Key,512}));ordinary.releaseOwner(9501);drain();
        CHECK(edges.back()==std::make_pair(512,0)&&ordinary.ownerCount()==0);
        if(consumer==1)inputBridge_l2SetActive(0);if(consumer==2)inputBridge_sdlSetActive(0);
    }
}

// 执行真实ring与其有序泵，typed边界替身只提供带生产序号的记录。按回调当时的公开
// 状态断言修饰键及坐标，不能只检查最终released而漏掉途中错误点击。
void TestCommonOrderAndFrameFence(Harness& h) {
    inputBridge_cancelAllState(&h, 5); inputBridge_glfwSetActive(&h, 1);
    inputBridge_setGrabState(0); amclBackendInputHostStubReset();
    inputBridge_pushEvent(kKeyEvent, 340, 0, kPress, 0);
    auto key = TypedKey(65, AMCL_BACKEND_INPUT_ACTION_DOWN); amclBackendInputHostStubPush(&key);
    inputBridge_pushEvent(kKeyEvent, 340, 0, kRelease, 0);
    key.action = AMCL_BACKEND_INPUT_ACTION_UP; amclBackendInputHostStubPush(&key);
    inputBridge_publishMenuCursor(123.25, 45.5);
    AmclBackendInputEvent button{}; button.eventType = AMCL_BACKEND_INPUT_EVENT_BUTTON;
    button.action = AMCL_BACKEND_INPUT_ACTION_DOWN; amclBackendInputHostStubPush(&button);
    inputBridge_publishMenuCursor(456.0, 300.0);
    button.action = AMCL_BACKEND_INPUT_ACTION_UP; amclBackendInputHostStubPush(&button);
    const uint64_t fence = amclInputInteractionFence();
    inputBridge_pushEvent(kKeyEvent, 67, 0, kPress, 0);
    key = TypedKey(68, AMCL_BACKEND_INPUT_ACTION_DOWN); amclBackendInputHostStubPush(&key);
    OrderedProbe probe{&h};
    inputBridgeStartPumping(); inputBridge_pumpOrdered(&h, PumpOrderedProbe, &probe, fence); inputBridgeStopPumping();
    CHECK(probe.modifiedKey && probe.clicks == 1u && !h.keys[67] && !h.keys[68]);
    inputBridgeStartPumping(); inputBridge_pumpOrdered(&h, PumpOrderedProbe, &probe, amclInputInteractionFence()); inputBridgeStopPumping();
    CHECK(h.keys[67] && h.keys[68]);
    inputBridge_pushEvent(kKeyEvent, 67, 0, kRelease, 0);
    key.action = AMCL_BACKEND_INPUT_ACTION_UP; amclBackendInputHostStubPush(&key);
    inputBridgeStartPumping(); inputBridge_pumpOrdered(&h, PumpOrderedProbe, &probe, amclInputInteractionFence()); inputBridgeStopPumping();
    CHECK(!h.keys[67] && !h.keys[68]);

    // L2的连续Next调用共享同一fence，帧中途新到达的键只能在EMPTY之后的下一轮出现。
    inputBridge_l2SetActive(1); amclBackendInputHostStubReset();
    inputBridge_pushEvent(kKeyEvent, 70, 0, kPress, 0);
    int type = 0, a = 0, b = 0, c = 0, d = 0;
    CHECK(inputBridge_l2NextEvent(&type, &a, &b, &c, &d) == 1 && a == 70);
    inputBridge_pushEvent(kKeyEvent, 71, 0, kPress, 0);
    CHECK(inputBridge_l2NextEvent(&type, &a, &b, &c, &d) == 0);
    CHECK(inputBridge_l2NextEvent(&type, &a, &b, &c, &d) == 1 && a == 71);
    CHECK(inputBridge_l2NextEvent(&type, &a, &b, &c, &d) == 0);
    inputBridge_cancelAllState(&h, 5);
}

}  // namespace

int main() {
    Harness harness;
    inputBridge_setKeyCallback(Harness::LegacyKey);
    inputBridge_setMouseButtonCallback(Harness::LegacyButton);
    // ⚠️ 补上此前缺失的这一个：没有它，bridge 的 cursor 上报路径整条不可达（见 Harness）。
    inputBridge_setCursorPosCallback(Harness::LegacyCursorPos);
    inputBridge_setScrollCallback(Harness::LegacyScroll);
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
    TestMenuCausalCoordinatesAndHeldInterval(harness);
    TestCommonTransactionEndAndFreshContact(harness);
    TestMenuPressCallbackReentryRetiresOldBatch(harness);
    TestReplacementReleasesAtOldPositionBeforeNewSource(harness);
    TestMenuPendingPreservesCommonOrder(harness);
    TestTouchScopeRetiresQueuedAndPendingMenuOnly(harness);
    TestPausedRenderingCancelsOnlyUncommittedMenu(harness);
    TestMenuToolScopedContributions(harness);
    TestMenuToolCancelDoesNotExpandScope(harness);
    TestScopeRetirementInsidePressCallback(harness);
    TestMenuWheelAndToolCursorScopes(harness);
    TestOrderedRelativeAndGestureCancellation(harness);
    TestScopedMenuCursorRetirement(harness);
    TestMenuToolOverflowSnapshotIsScopeBound(harness);
    TestSdlMenuPointerPresentBarrier(harness);
    TestMenuAndOrdinaryContributions(harness);
    TestConsumerRecoveryUsesProducerSnapshot(harness);
    TestLwjgl2TypedAndRingAreBothDrained();
    TestActivationGenerationStopsReentrantBatch(harness);
    TestNonPhysicalCursorReanchorsOnlyOnGrabFlip();
    TestCommonOrderAndFrameFence(harness);
    TestRecoveryBaselineFollowsPendingTyped(harness);
    TestHighLegacyKeyRecovery(harness);
    // 真实bridge来源切分：总流保留实体量，SDL累计流只保留触控/手柄，legacy路线仍读总流。
    amclBackendInputHostStubReset();
    inputBridge_setLookCursor(0, 0);
    inputBridge_setGrabState(1);
    double totalX = 0, totalY = 0, otherX = 0, otherY = 0;
    inputBridge_getCursorSnapshot(&totalX, &totalY);
    inputBridge_sdlGetNonPhysicalCursorSnapshot(&otherX, &otherY);
    inputBridge_addSourceLookDelta(1, 8.0, 4.0);
    inputBridge_addSourceLookDelta(3, 10.0, 20.0);
    inputBridge_addSourceLookDelta(2, 6.0, -2.0);
    double x = 0, y = 0;
    inputBridge_getCursorSnapshot(&x, &y);
    CHECK(x - totalX == 24.0 && y - totalY == 22.0);
    inputBridge_sdlGetNonPhysicalCursorSnapshot(&x, &y);
    CHECK(x - otherX == 14.0 && y - otherY == 2.0);
    amclBackendInputHostStubSetUnavailable(1);
    inputBridge_sdlGetNonPhysicalCursorSnapshot(&x, &y);
    CHECK(x - totalX == 24.0 && y - totalY == 22.0);
    amclBackendInputHostStubReset();
    inputBridge_setGrabState(0);
    // 此例建立已知present身份，放在所有匿名兼容入口样本之后，避免污染其测试前提。
    TestGlfwMenuPresentTargetIdentity(harness);
    TestGlfwLogicalTargetMapsActualWsiIdentity(harness);
    TestSdlMenuLogicalAndPresentedTargetIdentity(harness);
    TestCompletedMenuPrefixSurvivesFeedbackPublication(harness);
    TestCommittedMenuCursorAuthorityAndCancellation(harness);
    TestL2TargetRetiredToolNotReplayedByOverflow(harness);
    TestL2ResetDoesNotCarryGestureBegun(harness);
    CHECK(harness.committedBeforeCallback);
    std::cout << "glfw_runtime_input_bridge_test: PASS\n";
    return 0;
}
