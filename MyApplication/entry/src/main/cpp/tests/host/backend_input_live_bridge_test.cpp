// 实际backend pull bridge集成测试：只替换跨DSO发现为本测试的真实core地址，
// core/adapter/channel/编码均用生产实现，防止只验证encode而遗漏sink接线。
#include "../../input/amcl_input_host_descriptor.h"
#include "../../input/input_state_core.h"
#include "../../input/input_interaction_order.h"
#include "../../input/adapters/backend_input_bridge.h"
#include "../../platform/source_look_processor.h"
#include "../../platform/input_source.h"
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {
// 非空时解析器交出这张转发代理表（只替换 getSnapshot），其余时候交出真实表。
const AmclInputHostApiV1* gResolveOverride = nullptr;
}

extern "C" int32_t amclInputHostDescriptorResolveV1(const AmclInputHostApiV1** api) {
    if (!api) return AMCL_INPUT_HOST_DESCRIPTOR_ERROR_INVALID_ARGUMENT;
    *api = gResolveOverride ? gResolveOverride : amclInputGetHostApiV1();
    return AMCL_INPUT_HOST_DESCRIPTOR_OK;
}

namespace {
[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "LIVE BACKEND FAIL line " << line << ": " << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

// 第二个函数地址仅用于证明进程内注册不能被另一个写者静默替换。
bool OtherProcessor(int32_t, double, double, int64_t, double*, double*) { return false; }
unsigned resetCalls = 0u;
void ResetProcessor(int32_t source) {
    CHECK(source == AMCL_INPUT_SOURCE_PHYSICAL_KBM);
    ++resetCalls;
    amcl_reset_source_look_delta(source);
}
void OtherReset(int32_t) {}

std::vector<AmclBackendInputEvent> Drain(uint32_t backend = AMCL_BACKEND_INPUT_SDL3) {
    std::vector<AmclBackendInputEvent> events;
    AmclBackendInputEvent event{};
    int status = 0;
    while ((status = amclBackendInputNext(backend, &event)) ==
           AMCL_BACKEND_INPUT_EVENT) events.push_back(event);
    CHECK(status == AMCL_BACKEND_INPUT_EMPTY);
    return events;
}

AmclInputEvent Relative(uint64_t epoch) {
    AmclInputEvent event{};
    event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    event.header.structSize = static_cast<uint16_t>(sizeof(event));
    event.header.eventType = AMCL_INPUT_EVENT_POINTER_RELATIVE;
    event.header.sessionEpoch = epoch;
    event.header.source = AMCL_INPUT_SOURCE_MOUSE;
    event.header.deviceId = 8u;
    event.header.deviceClass = AMCL_INPUT_DEVICE_CLASS_MOUSE;
    event.payload.pointerRelative.rawDx = 10.0;
    event.payload.pointerRelative.rawDy = 20.0;
    return event;
}

// 自动重开期间鼠标仍在动：代理表的 getSnapshot（启动 drain 读空后、READY 前）先代生产者
// 写一条运动再转发。旧 core 会因这条记录拒绝 READY，重开失败、Next 返回 NOT_READY。
AmclInputHostApiV1 gReopenProxy{};
uint64_t gReopenEpoch = 0u;
bool gReopenMotionPending = false;
int32_t ReopenProxySnapshot(AmclInputSnapshotV1* output) {
    if (gReopenMotionPending) {
        gReopenMotionPending = false;
        const auto motion = Relative(gReopenEpoch);
        CHECK(amclInputGetHostApiV1()->submitEvent(&motion) == AMCL_INPUT_OK);
    }
    return amclInputGetHostApiV1()->getSnapshot(output);
}
void ArmReopenMotion(const AmclInputHostApiV1* api, uint64_t epoch) {
    gReopenProxy = *api;
    gReopenProxy.getSnapshot = ReopenProxySnapshot;
    gReopenEpoch = epoch;
    gReopenMotionPending = true;
    gResolveOverride = &gReopenProxy;
}

// 状态基线不是历史输入重放。SDL在core中因积压退休后，只继续原来的Next轮询，
// 不再次SetActive/Hide/Show，也不重建全局text token；新incarnation须恢复focus/capture
// 和当前文本会话，接收新键/同token commit，但不得伪造仍按住的旧W的第二次DOWN。
// motionDuringReopen：重开握手期间再注入一条运动，重开仍须一次成功且该运动在 READY 后送达。
void TestAutomaticPressureReopen(const AmclInputHostApiV1* api,
                                  uint64_t epoch, bool withText,
                                  bool motionDuringReopen) {
    amclBackendInputSetActive(AMCL_BACKEND_INPUT_LWJGL2, 1);
    Drain(AMCL_BACKEND_INPUT_LWJGL2);
    auto capture = Relative(epoch);
    capture.header.eventType = AMCL_INPUT_EVENT_CAPTURE_CHANGED;
    capture.payload = {};
    capture.payload.capture.requested = 1u;
    capture.payload.capture.active = 1u;
    capture.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
    CHECK(api->submitEvent(&capture) == AMCL_INPUT_OK);
    if (withText) {
        auto text = Relative(epoch);
        text.header.eventType = AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED;
        text.header.source = AMCL_INPUT_SOURCE_IME;
        text.header.deviceId = 0u;
        text.header.deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
        text.payload = {};
        text.payload.textSession.textSessionId = 77u;
        text.payload.textSession.change = AMCL_INPUT_TEXT_SESSION_STARTED;
        text.payload.textSession.reason = AMCL_INPUT_TEXT_SESSION_REASON_EXPLICIT;
        CHECK(api->submitEvent(&text) == AMCL_INPUT_OK);
    }
    Drain(); Drain(AMCL_BACKEND_INPUT_LWJGL2);
    auto key = Relative(epoch);
    key.header.eventType = AMCL_INPUT_EVENT_PHYSICAL_KEY;
    key.header.source = AMCL_INPUT_SOURCE_KEYBOARD;
    key.header.deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
    key.payload = {};
    key.payload.physicalKey.physicalKey = 2039u; // W保持在全局core里，不能被兄弟压力清掉。
    key.payload.physicalKey.action = AMCL_INPUT_ACTION_DOWN;
    CHECK(api->submitEvent(&key) == AMCL_INPUT_OK);
    Drain(); Drain(AMCL_BACKEND_INPUT_LWJGL2);
    for (unsigned i = 0u; i < 600u; ++i) {
        auto motion = Relative(epoch);
        CHECK(api->submitEvent(&motion) == AMCL_INPUT_OK);
        Drain(AMCL_BACKEND_INPUT_LWJGL2); // 活跃兄弟逐条消费，只有SDL停止拉取。
    }
    if (motionDuringReopen) ArmReopenMotion(api, epoch);
    const auto recovered = Drain(); // 内部遇STALE→Close→下次Next重新Open，真实生产链。
    gResolveOverride = nullptr;
    CHECK(!gReopenMotionPending); // 注入确实发生在重开握手之中。
    unsigned resets = 0u, focused = 0u, captured = 0u, currentText = 0u, relative = 0u;
    for (const auto& event : recovered) {
        resets += event.eventType == AMCL_BACKEND_INPUT_EVENT_RESET;
        focused += event.eventType == AMCL_BACKEND_INPUT_EVENT_FOCUS && event.action == 1u;
        captured += event.eventType == AMCL_BACKEND_INPUT_EVENT_CAPTURE && event.action == 1u;
        currentText += event.eventType == AMCL_BACKEND_INPUT_EVENT_TEXT_SESSION &&
            event.deviceId == 77u && event.code == AMCL_INPUT_TEXT_SESSION_STARTED;
        relative += event.eventType == AMCL_BACKEND_INPUT_EVENT_RELATIVE;
        CHECK(event.eventType != AMCL_BACKEND_INPUT_EVENT_KEY ||
              event.action == AMCL_BACKEND_INPUT_ACTION_UP);
    }
    CHECK(resets == 1u && focused == 1u && captured == 1u);
    CHECK(currentText == (withText ? 1u : 0u));
    CHECK(relative == (motionDuringReopen ? 1u : 0u));
    AmclInputSnapshotV1 snapshot{};
    snapshot.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    snapshot.structSize = static_cast<uint16_t>(sizeof(snapshot));
    CHECK(api->getSnapshot(&snapshot) == AMCL_INPUT_OK);
    CHECK(snapshot.heldControlCount == 1u && snapshot.captureActive == 1u);
    key.payload.physicalKey.physicalKey = 2017u;
    CHECK(api->submitEvent(&key) == AMCL_INPUT_OK);
    const auto freshKey = Drain();
    CHECK(freshKey.size() == 1u && freshKey[0].eventType == AMCL_BACKEND_INPUT_EVENT_KEY &&
          freshKey[0].action == AMCL_BACKEND_INPUT_ACTION_DOWN && freshKey[0].code == 4);
    Drain(AMCL_BACKEND_INPUT_LWJGL2);
    if (withText) {
        auto commit = Relative(epoch);
        commit.header.eventType = AMCL_INPUT_EVENT_TEXT_COMMIT;
        commit.header.source = AMCL_INPUT_SOURCE_IME;
        commit.header.deviceId = 0u;
        commit.header.deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
        commit.payload = {};
        commit.payload.textCommit.textSessionId = 77u;
        const uint8_t input[] = {'o', 'k'};
        CHECK(api->submitTextPacket(&commit, input, sizeof(input)) == AMCL_INPUT_OK);
        for (uint32_t backend : {AMCL_BACKEND_INPUT_SDL3, AMCL_BACKEND_INPUT_LWJGL2}) {
            const auto delivered = Drain(backend);
            CHECK(delivered.size() == 1u && delivered[0].eventType == AMCL_BACKEND_INPUT_EVENT_TEXT_COMMIT);
            uint8_t bytes[8]{};
            uint32_t count = 0u;
            CHECK(amclBackendInputReadText(backend, delivered[0].deviceId,
                                          bytes, sizeof(bytes), &count) == AMCL_BACKEND_INPUT_EVENT);
            CHECK(count == 2u && bytes[0] == 'o' && bytes[1] == 'k');
            CHECK(amclBackendInputReleaseText(backend, delivered[0].deviceId) == AMCL_BACKEND_INPUT_EVENT);
        }
    }
    CHECK(api->requestReset(AMCL_INPUT_RESET_EXPLICIT) == AMCL_INPUT_OK);
    Drain(); Drain(AMCL_BACKEND_INPUT_LWJGL2);
    amclBackendInputSetActive(AMCL_BACKEND_INPUT_LWJGL2, 0);
    Drain();
    std::cout << "automatic reopen withText=" << withText
              << " motionDuringReopen=" << motionDuringReopen
              << ": focus/capture restored, no historical DOWN, new key"
              << (withText ? "/same-token commit delivered" : " delivered") << '\n';
}
} // namespace

int main() {
#ifdef _WIN32
    CHECK(_putenv_s("AMCL_GLFW_INPUT_BACKEND", "typed") == 0);
#else
    CHECK(setenv("AMCL_GLFW_INPUT_BACKEND", "typed", 1) == 0);
#endif
    const auto* api = amclInputGetHostApiV1();
    uint64_t epoch = 0u;
    CHECK(api->beginSession(&epoch) == AMCL_INPUT_OK);
    CHECK(api->publishFocus(1u) == AMCL_INPUT_OK);
    // 内部基线的IME来源恢复不能扩展外部写入权限：伪造synthetic来源仍拒绝，
    // 即使来源正确，SYNTHETIC标志也不能绕过尚无READY后端的文本准入。
    auto forged = Relative(epoch);
    forged.header.eventType = AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED;
    forged.header.source = AMCL_INPUT_SOURCE_SYNTHETIC;
    forged.header.deviceId = 0u;
    forged.header.deviceClass = AMCL_INPUT_DEVICE_CLASS_UNKNOWN;
    forged.header.flags = AMCL_INPUT_EVENT_FLAG_SYNTHETIC;
    forged.payload = {};
    forged.payload.textSession.textSessionId = 99u;
    forged.payload.textSession.change = AMCL_INPUT_TEXT_SESSION_STARTED;
    forged.payload.textSession.reason = AMCL_INPUT_TEXT_SESSION_REASON_EXPLICIT;
    CHECK(api->submitEvent(&forged) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    forged.header.source = AMCL_INPUT_SOURCE_IME;
    CHECK(api->submitEvent(&forged) == AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    forged.header.flags = 0u;
    CHECK(api->submitEvent(&forged) == AMCL_INPUT_ERROR_BACKEND_NOT_READY);
    amclBackendInputSetActive(AMCL_BACKEND_INPUT_SDL3, 1);
    Drain(); // 实际baseline/READY握手，之后生产者准入才成立。
    auto event = Relative(epoch);
    CHECK(api->submitEvent(&event) == AMCL_INPUT_OK);
    // 未注册时必须明确丢弃而不是原量透传。
    for (const auto& missing : Drain()) {
        CHECK(missing.eventType != AMCL_BACKEND_INPUT_EVENT_RELATIVE);
    }
    CHECK(amclBackendInputSetLookProcessorV1(nullptr) == 0);
    CHECK(amclBackendInputSetLookProcessorV1(amcl_process_source_look_delta) == 1);
    CHECK(amclBackendInputSetLookProcessorV1(amcl_process_source_look_delta) == 1);
    CHECK(amclBackendInputSetLookProcessorV1(OtherProcessor) == 0);
    CHECK(amclBackendInputSetLookResetV1(nullptr) == 0);
    CHECK(amclBackendInputSetLookResetV1(ResetProcessor) == 1);
    CHECK(amclBackendInputSetLookResetV1(ResetProcessor) == 1);
    CHECK(amclBackendInputSetLookResetV1(OtherReset) == 0);
    CHECK(amcl_set_source_look_sensitivity(AMCL_INPUT_SOURCE_PHYSICAL_KBM, 2.0));
    CHECK(amcl_set_source_look_invert_y(AMCL_INPUT_SOURCE_PHYSICAL_KBM, true));
    CHECK(api->submitEvent(&event) == AMCL_INPUT_OK);
    const auto output = Drain();
    CHECK(output.size() == 1u);
    CHECK(output[0].eventType == AMCL_BACKEND_INPUT_EVENT_RELATIVE);
    CHECK(output[0].wheelX == 20.0f && output[0].wheelY == -40.0f);
    CHECK(output[0].deviceId == 8u);
    CHECK(output[0].resetReason == AMCL_INPUT_DEVICE_CLASS_MOUSE);
    CHECK(output[0].monotonicTimeNs != 0u);
    // SDL最终聚合需要保留每个物理identity：两只鼠标同键必须各出DOWN/UP，
    // 不能在本层只出A的DOWN和B的末UP，导致SDL source找不到配对持有。
    AmclInputEvent button{};
    button.header = event.header;
    button.header.eventType = AMCL_INPUT_EVENT_POINTER_BUTTON;
    button.payload.pointerButton.nativeButton = 1u;
    button.payload.pointerButton.action = AMCL_INPUT_ACTION_DOWN;
    button.header.deviceId = 41u;
    CHECK(api->submitEvent(&button) == AMCL_INPUT_OK);
    button.header.deviceId = 42u;
    CHECK(api->submitEvent(&button) == AMCL_INPUT_OK);
    const auto downs = Drain();
    CHECK(downs.size() == 2u);
    CHECK(downs[0].eventType == AMCL_BACKEND_INPUT_EVENT_BUTTON);
    CHECK(downs[0].deviceId == 41u && downs[1].deviceId == 42u);
    CHECK(downs[0].action == AMCL_BACKEND_INPUT_ACTION_DOWN &&
          downs[1].action == AMCL_BACKEND_INPUT_ACTION_DOWN);
    button.payload.pointerButton.action = AMCL_INPUT_ACTION_UP;
    button.header.deviceId = 41u;
    CHECK(api->submitEvent(&button) == AMCL_INPUT_OK);
    const auto firstUp = Drain();
    CHECK(firstUp.size() == 1u && firstUp[0].deviceId == 41u &&
          firstUp[0].action == AMCL_BACKEND_INPUT_ACTION_UP);
    button.header.deviceId = 42u;
    CHECK(api->submitEvent(&button) == AMCL_INPUT_OK);
    const auto lastUp = Drain();
    CHECK(lastUp.size() == 1u && lastUp[0].deviceId == 42u &&
          lastUp[0].action == AMCL_BACKEND_INPUT_ACTION_UP);
    // L2只负责离散事件，它自己的baseline/局部退出不得清GLFW/SDL的physical时钟。
    const unsigned beforeL2 = resetCalls;
    amclBackendInputSetActive(AMCL_BACKEND_INPUT_LWJGL2, 1);
    Drain(AMCL_BACKEND_INPUT_LWJGL2);
    amclBackendInputSetActive(AMCL_BACKEND_INPUT_LWJGL2, 0);
    Drain();
    CHECK(resetCalls == beforeL2);
    double dx = 0.0, dy = 0.0;
    CHECK(!amcl_process_source_look_delta(AMCL_INPUT_SOURCE_PHYSICAL_KBM,
                                         1.0, 1.0, 1, &dx, &dy));
    CHECK(amcl_process_source_look_delta(AMCL_INPUT_SOURCE_TOUCH_CONTROLS,
                                        10.0, 0.0, 1000000000, &dx, &dy));
    CHECK(api->requestReset(AMCL_INPUT_RESET_EXPLICIT) == AMCL_INPUT_OK);
    Drain();
    CHECK(resetCalls > beforeL2);
    CHECK(amcl_process_source_look_delta(AMCL_INPUT_SOURCE_PHYSICAL_KBM,
                                        1.0, 1.0, 1, &dx, &dy));
    CHECK(amcl_flush_source_look_delta(AMCL_INPUT_SOURCE_TOUCH_CONTROLS,
                                      true, &dx, &dy));
    CHECK(dx > 0.0); // SDL的physical reset没有连坐触控平滑尾量。
    // AR3：core尚未溢出的最大合法积压，pull桥必须逐条取走，不能因自己的128槽整批复位。
    for (unsigned count : {128u, 129u, 130u, 200u, 256u}) {
        for (unsigned i = 0; i < count; ++i) {
            const auto queued = Relative(epoch);
            CHECK(api->submitEvent(&queued) == AMCL_INPUT_OK);
        }
        const auto batch = Drain();
        CHECK(batch.size() == count);
        for (const auto& item : batch) CHECK(item.eventType == AMCL_BACKEND_INPUT_EVENT_RELATIVE);
    }
    TestAutomaticPressureReopen(api, epoch, false, false);
    // V1旧消费者仍取得core序号；只有新有序入口返回共同顺序，并严格保留fence外记录。
    for (unsigned i = 0; i < 10u; ++i) (void)amclInputNextInteractionOrder();
    const auto orderedMotion = Relative(epoch);
    CHECK(api->submitEvent(&orderedMotion) == AMCL_INPUT_OK);
    amcl::input::CoreObservabilityV1 observation{};
    CHECK(amcl::input::HostInputStateCore().GetObservability(&observation) == AMCL_INPUT_OK);
    AmclBackendInputEvent wire{};
    CHECK(amclBackendInputNext(AMCL_BACKEND_INPUT_SDL3, &wire) == AMCL_BACKEND_INPUT_EVENT);
    CHECK(wire.sequence == observation.lastSequence);
    CHECK(api->submitEvent(&orderedMotion) == AMCL_INPUT_OK);
    const uint64_t order = api->interactionFence();
    CHECK(amclBackendInputNextThrough(AMCL_BACKEND_INPUT_SDL3, &wire, order - 1u) == AMCL_BACKEND_INPUT_EMPTY);
    CHECK(amclBackendInputNextThrough(AMCL_BACKEND_INPUT_SDL3, &wire, order) == AMCL_BACKEND_INPUT_EVENT);
    CHECK(wire.sequence == order);
    TestAutomaticPressureReopen(api, epoch, true, false);
    TestAutomaticPressureReopen(api, epoch, false, true);
    TestAutomaticPressureReopen(api, epoch, true, true);
    amclBackendInputSetActive(AMCL_BACKEND_INPUT_SDL3, 0);
    AmclBackendInputEvent inactive{};
    CHECK(amclBackendInputNext(AMCL_BACKEND_INPUT_SDL3, &inactive) ==
          AMCL_BACKEND_INPUT_ERROR_NOT_READY);
    CHECK(api->endSession(epoch) == AMCL_INPUT_OK);
    std::cout << "backend_input_live_bridge_test: PASS\n";
}
