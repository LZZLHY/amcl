// IME 编辑键与提交文本的交付顺序（I27-09）：生产 ingress → 生产 core → 三个真实消费者。
//
// 消费者全部是产品实现：GLFW3 用 GlfwInputAdapter + OHOS mapper（glfw_compat 的同一接线），
// SDL3/LWJGL2 用 backend_input_bridge 的真实通道（内部各自一个 adapter + 后端键表）。
// core 不带宿主测试开关编译，文本与物理键都要求真实 READY 后端，与产品准入一致。
//
// AMCL_TEXT_KEY_ORDER_TYPED=1：进程锁存 typed 物理路由，断言
//   · 退格/提交/回车/提交/前删/小键盘回车/Esc 在三个消费者上按提交顺序到达；
//   · 负向对照：按修复前的做法把编辑键放进“legacy ring”（这里用 FIFO 模拟，消费者按
//     glfw_compat / SDL 补丁 / input_bridge_ohos.c 的既定顺序先抽 typed 再抽 ring），
//     同一提交序列在消费侧被重排成“先文本后退格”；
//   · 同键实体按住期间的 IME 轻击被跨设备聚合吸收，重叠诊断计数；
//   · 白名单、配对、门禁、会话号与失焦的拒绝路径不向任何消费者泄漏事件。
// AMCL_TEXT_KEY_ORDER_TYPED=0：legacy 路由下只回答 NotTypedRoute（调用方回退 ring），
// 白名单拒绝与路由无关。
#include "../../input/amcl_input_host_descriptor.h"
#include "../../input/adapters/backend_input_bridge.h"
#include "../../input/adapters/glfw_input_adapter.h"
#include "../../input/platform_input_ingress.h"

#include <chrono>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#ifndef AMCL_TEXT_KEY_ORDER_TYPED
#define AMCL_TEXT_KEY_ORDER_TYPED 1
#endif

// backend 通道经描述符发现 host 表；测试进程内直接交出同一份生产 core 表。
#ifndef AMCL_TEXT_ORDER_REAL_DESCRIPTOR
extern "C" int32_t amclInputHostDescriptorResolveV1(
        const AmclInputHostApiV1** api) {
    if (!api) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INVALID_ARGUMENT;
    *api = amclInputGetHostApiV1();
    return AMCL_INPUT_HOST_DESCRIPTOR_OK;
}
#endif

namespace {
using namespace amcl::input;

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "TEXT KEY ORDER FAIL typed=" << AMCL_TEXT_KEY_ORDER_TYPED
              << " line " << line << ": " << expression << '\n';
    // CHECK是宿主探针的致命出口，尤其用于故意撤回判据的负对照。此时真实backend可能仍READY，
    // std::exit不会展开局部对象，却会析构全局backend/core；静态顺序可能先销毁core的consumer表，
    // 再由adapter析构回调Close访问它。实取栈已证明会在已销毁unordered_map.find中异常重入/超时。
    // 先明确flush断言证据，再立即以非零结束测试进程；成功路径仍走正常Close/SurfaceDestroyed，
    // runner仍要求本CHECK文本及完成退出，超时/编译失败绝不能计作负对照通过。
    std::cerr.flush();
    std::cout.flush();
    std::_Exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

void SelectRoute() {
    const char* route = AMCL_TEXT_KEY_ORDER_TYPED ? "typed" : "legacy";
#ifdef _WIN32
    CHECK(_putenv_s("AMCL_INPUT_SHADOW", "0") == 0);
    CHECK(_putenv_s("AMCL_GLFW_INPUT_BACKEND", route) == 0);
#else
    CHECK(setenv("AMCL_INPUT_SHADOW", "0", 1) == 0);
    CHECK(setenv("AMCL_GLFW_INPUT_BACKEND", route, 1) == 0);
#endif
}

// 一条消费侧可见的输入：键（映射后的键码 + 按下/抬起）或一段提交文本。
struct Delivered {
    bool text = false;
    int32_t code = 0;
    bool down = false;
    std::string utf8;
    bool operator==(const Delivered& other) const {
        return text == other.text && code == other.code &&
               down == other.down && utf8 == other.utf8;
    }
};
Delivered Key(int32_t code, bool down) {
    Delivered value;
    value.code = code;
    value.down = down;
    return value;
}
Delivered Text(const char* utf8) {
    Delivered value;
    value.text = true;
    value.utf8 = utf8;
    return value;
}

// GLFW3 消费者：记录 adapter 在一次 Pump 里按 core 序号分发的键与文本回调。
struct GlfwRecorder {
    std::vector<Delivered> delivered;
    std::vector<uint64_t> sequences;
    static void OnKey(void* context, const GlfwKeySinkEvent& event) {
        auto& self = *static_cast<GlfwRecorder*>(context);
        if (event.action == GlfwInputAction::kRepeat) return;
        self.delivered.push_back(
            Key(event.key, event.action == GlfwInputAction::kPress));
        self.sequences.push_back(event.sequence);
    }
    static void OnText(void* context, const GlfwTextCommitSinkEvent& event) {
        auto& self = *static_cast<GlfwRecorder*>(context);
        self.delivered.push_back(Text(std::string(
            event.utf8.begin(), event.utf8.end()).c_str()));
        self.sequences.push_back(event.sequence);
    }
    static void OnTextSession(void*, const GlfwTextSessionSinkEvent&) {}
    GlfwInputSink Sink() {
        GlfwInputSink sink{};
        sink.context = this;
        sink.key = OnKey;
        sink.textSession = OnTextSession;
        sink.textCommit = OnText;
        return sink;
    }
};

void PumpAll(GlfwInputAdapter& adapter) {
    for (int guard = 0; guard < 64; ++guard) {
        const GlfwPumpResult result = adapter.Pump();
        CHECK(result.status == GlfwAdapterStatus::kOk);
        if (result.eventsDrained == 0u) return;
    }
    Fail("GLFW pump did not reach EMPTY", __LINE__);
}

// SDL3/LWJGL2 消费者：按通道 FIFO 顺序取出键与提交文本（文本包复制后立即释放）。
std::vector<Delivered> DrainBackend(uint32_t backend,
                                    std::vector<uint64_t>* keyDevices = nullptr) {
    std::vector<Delivered> delivered;
    uint64_t lastSequence = 0u;
    for (int guard = 0; guard < 512; ++guard) {
        AmclBackendInputEvent event{};
        const int status = amclBackendInputNext(backend, &event);
        if (status == AMCL_BACKEND_INPUT_EMPTY) return delivered;
        CHECK(status == AMCL_BACKEND_INPUT_EVENT);
        const bool ordered = event.eventType == AMCL_BACKEND_INPUT_EVENT_KEY ||
            event.eventType == AMCL_BACKEND_INPUT_EVENT_TEXT_COMMIT;
        if (ordered) {
            // 键与提交文本都带 core 序号：同一通道内严格递增即“按提交顺序交付”。
            CHECK(event.sequence > lastSequence);
            lastSequence = event.sequence;
        }
        if (event.eventType == AMCL_BACKEND_INPUT_EVENT_KEY) {
            if (event.action == AMCL_BACKEND_INPUT_ACTION_REPEAT) continue;
            delivered.push_back(Key(event.code,
                event.action == AMCL_BACKEND_INPUT_ACTION_DOWN));
            if (keyDevices) keyDevices->push_back(event.deviceId);
        } else if (event.eventType == AMCL_BACKEND_INPUT_EVENT_TEXT_COMMIT) {
            char bytes[64] = {};
            uint32_t count = 0u;
            CHECK(amclBackendInputReadText(
                      backend, event.deviceId, reinterpret_cast<uint8_t*>(bytes),
                      static_cast<uint32_t>(sizeof(bytes) - 1u), &count) ==
                  AMCL_BACKEND_INPUT_EVENT);
            CHECK(amclBackendInputReleaseText(backend, event.deviceId) ==
                  AMCL_BACKEND_INPUT_EVENT);
            delivered.push_back(Text(std::string(bytes, count).c_str()));
        }
    }
    Fail("backend channel did not reach EMPTY", __LINE__);
}

PlatformInputTextKeyTapResult Tap(uint64_t session, uint32_t ohos,
                                  int32_t glfw, bool gate = true) {
    return PlatformInputTextSessionKeyTap(session, ohos, glfw, gate);
}

bool Commit(uint64_t session, const char* text) {
    return PlatformInputTextCommit(session,
        reinterpret_cast<const uint8_t*>(text),
        static_cast<uint32_t>(std::string(text).size()));
}

#if AMCL_TEXT_KEY_ORDER_TYPED
constexpr uint32_t kOhosBackspace = 2055u;
constexpr uint32_t kOhosDelete = 2071u;
constexpr uint32_t kOhosEnter = 2054u;
constexpr uint32_t kOhosNumpadEnter = 2119u;
constexpr uint32_t kOhosEscape = 2070u;

struct Consumers {
    GlfwInputAdapter glfw;
    GlfwRecorder recorder;
};

void DrainEverything(Consumers& consumers) {
    PumpAll(consumers.glfw);
    (void)DrainBackend(AMCL_BACKEND_INPUT_SDL3);
    (void)DrainBackend(AMCL_BACKEND_INPUT_LWJGL2);
    consumers.recorder.delivered.clear();
    consumers.recorder.sequences.clear();
}

// 同一提交序列在三个消费者上保持顺序；键事件携带保留的 IME 设备身份。
void TestOrderAcrossConsumers(Consumers& consumers, uint64_t session) {
    CHECK(Tap(session, kOhosBackspace, 259) == PlatformInputTextKeyTapResult::Submitted);
    CHECK(Tap(session, kOhosBackspace, 259) == PlatformInputTextKeyTapResult::Submitted);
    CHECK(Commit(session, "ab"));
    CHECK(Tap(session, kOhosEnter, 257) == PlatformInputTextKeyTapResult::Submitted);
    CHECK(Commit(session, "c"));
    CHECK(Tap(session, kOhosDelete, 261) == PlatformInputTextKeyTapResult::Submitted);
    CHECK(Tap(session, kOhosNumpadEnter, 335) == PlatformInputTextKeyTapResult::Submitted);
    CHECK(Tap(session, kOhosEscape, 256) == PlatformInputTextKeyTapResult::Submitted);

    PumpAll(consumers.glfw);
    const std::vector<Delivered> glfwExpected = {
        Key(259, true), Key(259, false), Key(259, true), Key(259, false),
        Text("ab"), Key(257, true), Key(257, false), Text("c"),
        Key(261, true), Key(261, false), Key(335, true), Key(335, false),
        Key(256, true), Key(256, false)};
    CHECK(consumers.recorder.delivered == glfwExpected);
    for (size_t i = 1; i < consumers.recorder.sequences.size(); ++i) {
        CHECK(consumers.recorder.sequences[i] > consumers.recorder.sequences[i - 1]);
    }

    std::vector<uint64_t> sdlDevices;
    const std::vector<Delivered> sdlExpected = {
        Key(42, true), Key(42, false), Key(42, true), Key(42, false),
        Text("ab"), Key(40, true), Key(40, false), Text("c"),
        Key(76, true), Key(76, false), Key(88, true), Key(88, false),
        Key(41, true), Key(41, false)};
    CHECK(DrainBackend(AMCL_BACKEND_INPUT_SDL3, &sdlDevices) == sdlExpected);
    for (uint64_t device : sdlDevices) CHECK(device == kPlatformInputTextKeyDeviceId);

    const std::vector<Delivered> lwjgl2Expected = {
        Key(14, true), Key(14, false), Key(14, true), Key(14, false),
        Text("ab"), Key(28, true), Key(28, false), Text("c"),
        Key(211, true), Key(211, false), Key(156, true), Key(156, false),
        Key(1, true), Key(1, false)};
    CHECK(DrainBackend(AMCL_BACKEND_INPUT_LWJGL2) == lwjgl2Expected);
    consumers.recorder.delivered.clear();
    consumers.recorder.sequences.clear();
    std::cout << "ordered IME edit keys + commits on GLFW/SDL3/LWJGL2: PASS\n";
}

// 负向对照：修复前 IME 编辑键走 sendSourceKeyEvent → legacy ring，提交走 typed core。
// ring 记录只有五个整数、没有 core 序号，消费者无法与 typed 合并；三种消费者都先抽完
// typed 再抽 ring（glfw_compat 的 pumpTypedInput → inputBridgePumpEvents、SDL 补丁的
// PumpTypedEvents → PumpHostEvents、input_bridge_ohos.c 的 l2NextTypedEvent 优先）。
// 这里用一个 FIFO 模拟 ring，typed 半边用真实 SDL3 通道：“先退格后提交”被重排。
void TestLegacyRingTapsReorder(Consumers& consumers, uint64_t session) {
    std::deque<Delivered> legacyRing;
    legacyRing.push_back(Key(42, true));   // 旧路径：deleteLeft(1) 的 PRESS
    legacyRing.push_back(Key(42, false));  // 旧路径：同一轻击的 RELEASE
    CHECK(Commit(session, "x"));           // 随后同一 IME 回合的 insertText
    std::vector<Delivered> frame = DrainBackend(AMCL_BACKEND_INPUT_SDL3);
    frame.insert(frame.end(), legacyRing.begin(), legacyRing.end());
    (void)DrainBackend(AMCL_BACKEND_INPUT_LWJGL2);
    const std::vector<Delivered> reordered = {
        Text("x"), Key(42, true), Key(42, false)};
    CHECK(frame == reordered);

    // 同一顺序改走本轮入口：同一个消费模型（typed 先、ring 后且为空）保持原顺序。
    CHECK(Tap(session, kOhosBackspace, 259) == PlatformInputTextKeyTapResult::Submitted);
    CHECK(Commit(session, "x"));
    const std::vector<Delivered> ordered = {
        Key(42, true), Key(42, false), Text("x")};
    CHECK(DrainBackend(AMCL_BACKEND_INPUT_SDL3) == ordered);
    DrainEverything(consumers);
    std::cout << "negative control: legacy ring taps reorder, typed taps do not: PASS\n";
}

// 同键实体按住期间的 IME 轻击：core 按 (设备, 键) 分别记账，adapter 跨设备聚合，
// 各消费者只看到实体键的一次按下与一次抬起；重叠诊断在窗口内计数、窗口外不计。
void TestNestedPhysicalHoldIsAbsorbed(Consumers& consumers, uint64_t session) {
    constexpr uint64_t kKeyboard = 5u;
    // 先离开上一场景最后一次 IME 退格的 50ms 窗口，保证下面恰好只数到一次重叠。
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    const PlatformInputTextDiagnostics before = PlatformInputTextDiagnosticsSnapshot();
    CHECK(PlatformInputPhysicalKeyTransaction(
              kOhosBackspace, 0u, 0u, AMCL_INPUT_ACTION_DOWN, 0u, 0u,
              kKeyboard, 259, 1, true, nullptr) ==
          AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(Tap(session, kOhosBackspace, 259) == PlatformInputTextKeyTapResult::Submitted);
    CHECK(PlatformInputPhysicalKeyTransaction(
              kOhosBackspace, 0u, 0u, AMCL_INPUT_ACTION_UP, 0u, 0u,
              kKeyboard, 259, 0, true, nullptr) ==
          AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    PumpAll(consumers.glfw);
    const std::vector<Delivered> once = {Key(259, true), Key(259, false)};
    CHECK(consumers.recorder.delivered == once);
    const std::vector<Delivered> sdlOnce = {Key(42, true), Key(42, false)};
    CHECK(DrainBackend(AMCL_BACKEND_INPUT_SDL3) == sdlOnce);
    const std::vector<Delivered> l2Once = {Key(14, true), Key(14, false)};
    CHECK(DrainBackend(AMCL_BACKEND_INPUT_LWJGL2) == l2Once);
    const PlatformInputTextDiagnostics overlap = PlatformInputTextDiagnosticsSnapshot();
    CHECK(overlap.keyTapPhysicalOverlap == before.keyTapPhysicalOverlap + 1u);
    consumers.recorder.delivered.clear();

    // 窗口外（>50ms）的 IME 轻击不是重叠：只投递、不计数。
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    CHECK(Tap(session, kOhosBackspace, 259) == PlatformInputTextKeyTapResult::Submitted);
    CHECK(PlatformInputTextDiagnosticsSnapshot().keyTapPhysicalOverlap ==
          overlap.keyTapPhysicalOverlap);
    DrainEverything(consumers);
    std::cout << "nested physical hold absorbs IME tap; overlap counted once: PASS\n";
}

// 拒绝路径：返回 Rejected，且没有任何事件到达任何消费者。
void TestRejectionsLeakNothing(Consumers& consumers, uint64_t session) {
    const PlatformInputTextDiagnostics before = PlatformInputTextDiagnosticsSnapshot();
    CHECK(Tap(session, 2017u, 65) == PlatformInputTextKeyTapResult::Rejected);
    CHECK(Tap(session, kOhosBackspace, 257) == PlatformInputTextKeyTapResult::Rejected);
    CHECK(Tap(session, kOhosBackspace, 259, false) == PlatformInputTextKeyTapResult::Rejected);
    CHECK(Tap(session + 1u, kOhosBackspace, 259) == PlatformInputTextKeyTapResult::Rejected);
    CHECK(Tap(0u, kOhosBackspace, 259) == PlatformInputTextKeyTapResult::Rejected);
    PumpAll(consumers.glfw);
    CHECK(consumers.recorder.delivered.empty());
    CHECK(DrainBackend(AMCL_BACKEND_INPUT_SDL3).empty());
    CHECK(DrainBackend(AMCL_BACKEND_INPUT_LWJGL2).empty());
    const PlatformInputTextDiagnostics after = PlatformInputTextDiagnosticsSnapshot();
    CHECK(after.keyTapRejected == before.keyTapRejected + 5u);
    CHECK(after.keyTapSubmitted == before.keyTapSubmitted);

    // 失焦：core RESET 丢弃文本会话，镜像随排空清零；旧会话号的编辑键被拒。
    PlatformInputFocusChanged(false);
    CHECK(Tap(session, kOhosEnter, 257) == PlatformInputTextKeyTapResult::Rejected);
    PlatformInputFocusChanged(true);
    DrainEverything(consumers);
    std::cout << "key/pair/gate/session/focus rejections leak nothing: PASS\n";
}

/** owned编辑键穿过触控模态的前提是仍有效的文本租约；旧号、END/ABORT/失焦不可复用。 */
void TestOwnedTextLeaseBoundaries(Consumers& consumers) {
    constexpr uint64_t first=181u,second=182u,third=183u;
    CHECK(!PlatformInputOwnedTextSessionMatches(0u));
    CHECK(!PlatformInputOwnedTextSessionMatches(first));
    CHECK(PlatformInputTextSessionBegin(first));
    CHECK(PlatformInputOwnedTextSessionMatches(first));
    CHECK(!PlatformInputOwnedTextSessionMatches(second));
    CHECK(!PlatformInputTextSessionEnd(second));
    CHECK(PlatformInputOwnedTextSessionMatches(first));
    CHECK(PlatformInputTextSessionEnd(first));
    CHECK(!PlatformInputOwnedTextSessionMatches(first));
    CHECK(PlatformInputTextSessionBegin(second));
    CHECK(!PlatformInputOwnedTextSessionMatches(first));
    CHECK(PlatformInputOwnedTextSessionMatches(second));
    CHECK(PlatformInputTextSessionAbort(second));
    CHECK(!PlatformInputOwnedTextSessionMatches(second));
    CHECK(PlatformInputTextSessionBegin(third));
    PlatformInputFocusChanged(false);
    CHECK(!PlatformInputOwnedTextSessionMatches(third));
    PlatformInputFocusChanged(true);
    CHECK(!PlatformInputOwnedTextSessionMatches(third));
    DrainEverything(consumers);
    std::cout<<"owned text lease matches only current live session across END/ABORT/focus: PASS\n";
}
#endif
}  // namespace

int main() {
    SelectRoute();
    const AmclInputHostApiV1* api = amclInputGetHostApiV1();
    CHECK(api != nullptr);
    CHECK(PlatformInputPhysicalRouteUsesTyped() == (AMCL_TEXT_KEY_ORDER_TYPED != 0));
    PlatformInputSurfaceCreated(800u, 600u, 21u);
#if AMCL_TEXT_KEY_ORDER_TYPED
    Consumers consumers;
    CHECK(consumers.glfw.Open(api, GlfwOhosInputMapper(),
                              consumers.recorder.Sink()) == GlfwAdapterStatus::kOk);
    amclBackendInputSetActive(AMCL_BACKEND_INPUT_SDL3, 1);
    amclBackendInputSetActive(AMCL_BACKEND_INPUT_LWJGL2, 1);
    DrainEverything(consumers);  // 两个 backend 通道在首次 Next 时完成 baseline/READY 握手
    TestOwnedTextLeaseBoundaries(consumers);
    constexpr uint64_t kSession = 77u;
    CHECK(PlatformInputTextSessionBegin(kSession));
    DrainEverything(consumers);
    TestOrderAcrossConsumers(consumers, kSession);
    TestLegacyRingTapsReorder(consumers, kSession);
    TestNestedPhysicalHoldIsAbsorbed(consumers, kSession);
    TestRejectionsLeakNothing(consumers, kSession);
    amclBackendInputSetActive(AMCL_BACKEND_INPUT_LWJGL2, 0);
    amclBackendInputSetActive(AMCL_BACKEND_INPUT_SDL3, 0);
    CHECK(consumers.glfw.Close() == GlfwAdapterStatus::kOk);
#else
    // legacy 路由：路由判断先于门禁与会话号，调用方据此回退原 ring 按键对。
    const PlatformInputTextDiagnostics before = PlatformInputTextDiagnosticsSnapshot();
    CHECK(PlatformInputTextSessionKeyTap(0u, 2055u, 259, true) ==
          PlatformInputTextKeyTapResult::NotTypedRoute);
    CHECK(PlatformInputTextSessionKeyTap(9u, 2054u, 257, false) ==
          PlatformInputTextKeyTapResult::NotTypedRoute);
    CHECK(PlatformInputTextSessionKeyTap(9u, 2017u, 65, true) ==
          PlatformInputTextKeyTapResult::Rejected);
    const PlatformInputTextDiagnostics after = PlatformInputTextDiagnosticsSnapshot();
    CHECK(after.keyTapNotTypedRoute == before.keyTapNotTypedRoute + 2u);
    CHECK(after.keyTapRejected == before.keyTapRejected + 1u);
    CHECK(after.keyTapSubmitted == before.keyTapSubmitted);
    std::cout << "legacy route answers NotTypedRoute; whitelist still enforced: PASS\n";
#endif
    PlatformInputSurfaceDestroyed(21u);
    std::cout << "platform_input_text_key_order_test typed="
              << AMCL_TEXT_KEY_ORDER_TYPED << " passed\n";
    return 0;
}
