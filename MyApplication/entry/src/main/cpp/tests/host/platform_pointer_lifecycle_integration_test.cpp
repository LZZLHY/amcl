/**
 * F03-F06出货typed平面组合回归。实际policy→ingress→core经过backend READY握手，
 * 检查全部物理UP后held为0、拔除保留其它设备，以及平台解锁不会被requested intent拒收。
 */
#include "amcl_input_api.h"
#include "platform_input_ingress.h"
#include "input_channel_policy.h"
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
using namespace amcl::input;
#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "FAIL %d: %s\n", __LINE__, #x); std::exit(1); } } while (0)

struct Fixture {
    const AmclInputHostApiV1* api = nullptr;
    AmclInputConsumerHandle consumer = 0u;
    void Drain() {
        AmclInputEvent event{};
        int result;
        while ((result = api->nextEvent(consumer, &event)) == AMCL_INPUT_OK) {
            // 此真实消费者领取过的文本包必须交还自己的引用，不能让上一场景的包池占用
            // 混入下一场景；RESET撤销的未领取旧包由Core负责，无需伪造一次release。
            uint64_t packet = 0u;
            if (event.header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT) packet = event.payload.textCommit.utf8Blob.packetId;
            if (event.header.eventType == AMCL_INPUT_EVENT_TEXT_EDITING) packet = event.payload.textEditing.utf8Blob.packetId;
            if (event.header.eventType == AMCL_INPUT_EVENT_TEXT_CANDIDATES) packet = event.payload.textCandidates.itemsBlob.packetId;
            if (packet != 0u) CHECK(api->releasePacket(consumer, packet) == AMCL_INPUT_OK);
        }
        CHECK(result == AMCL_INPUT_EMPTY);
    }
    AmclInputSnapshotV1 Snapshot() {
        AmclInputSnapshotV1 value{};
        value.abiVersion = AMCL_INPUT_HOST_API_VERSION;
        value.structSize = sizeof(value);
        CHECK(api->getSnapshot(&value) == AMCL_INPUT_OK);
        return value;
    }
    bool Edge(AmclInputChannel channel, uint64_t device, uint32_t button, bool down) {
        const bool accepted = down ? amcl_input_policy_button_begin(channel, device, button)
                                   : amcl_input_policy_button_end(channel, device, button);
        if (!accepted) return false;
        CHECK(PlatformInputPhysicalButtonTransaction(device, button,
            down ? AMCL_INPUT_ACTION_DOWN : AMCL_INPUT_ACTION_UP, 0, down ? 1 : 0,
            true, nullptr) == AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
        Drain();
        return true;
    }
    static void Removed(uint64_t device, uint32_t button, void* opaque) {
        auto& fixture = *static_cast<Fixture*>(opaque);
        CHECK(PlatformInputPhysicalButtonTransaction(device, button,
            AMCL_INPUT_ACTION_UP, 0, 0, true, nullptr) == AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
        fixture.Drain();
    }
};

/**
 * 沿真实ingress/Core固定当前保守复位政策：两台键盘共持同码，同时保有预编辑包，
 * 窗口始终有焦点。主动撤回捕获与仍有请求的平台丢失分别保留真实原因，但当前公共
 * RESET都清全部held/文本。这个反例只证明现行范围，不能把它当局部隔离已经成立。
 */
void VerifyCaptureResetPolicy(Fixture& fixture, bool voluntary) {
    PlatformInputCaptureRequested(true);
    PlatformInputCapturePlatformChanged(true, AMCL_INPUT_CAPTURE_REASON_GRANTED);
    fixture.Drain();
    CHECK(PlatformInputPhysicalKeyTransaction(2017u, 17u, 26u, AMCL_INPUT_ACTION_DOWN,
        0u, 0u, 31u, 87, 1, true, nullptr) == AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(PlatformInputPhysicalKeyTransaction(2017u, 17u, 26u, AMCL_INPUT_ACTION_DOWN,
        0u, 0u, 32u, 87, 1, true, nullptr) == AMCL_LEGACY_PHYSICAL_TYPED_ROUTE_HANDLED);
    CHECK(fixture.Snapshot().heldControlCount == 2u);
    fixture.Drain();
    const uint64_t editor = voluntary ? 9001u : 9002u;
    CHECK(PlatformInputTextSessionBegin(editor));
    fixture.Drain();
    const uint8_t bytes[] = {'a'};
    CHECK(PlatformInputTextEditing(editor, bytes, 1u, 0u, 1u));
    if (fixture.Snapshot().blobBytes != 1u) {
        const auto observed = fixture.Snapshot();
        std::fprintf(stderr, "capture-policy voluntary=%d held=%llu blobs=%llu queued=%llu consumers=%llu epoch=%llu\n",
            voluntary, static_cast<unsigned long long>(observed.heldControlCount),
            static_cast<unsigned long long>(observed.blobBytes), static_cast<unsigned long long>(observed.queuedEventCount),
            static_cast<unsigned long long>(observed.consumerCount), static_cast<unsigned long long>(observed.sessionEpoch));
    }
    CHECK(fixture.Snapshot().blobBytes == 1u);
    const auto before = fixture.Snapshot();
    if (voluntary) PlatformInputCaptureRequested(false);
    PlatformInputCapturePlatformChanged(false, AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST);
    const auto after = fixture.Snapshot();
    CHECK(after.focused == 1u && after.focusEpoch == before.focusEpoch);
    CHECK(after.heldControlCount == 0u && after.blobBytes == 0u);
    CHECK(!PlatformInputOwnedTextSessionMatches(editor));
    CHECK(after.captureRequested == (voluntary ? 0u : 1u));
    CHECK(after.captureReason == (voluntary ? AMCL_INPUT_CAPTURE_REASON_NONE : AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST));
    unsigned releases = 0u, resets = 0u;
    AmclInputEvent event{};
    int result;
    while ((result = fixture.api->nextEvent(fixture.consumer, &event)) == AMCL_INPUT_OK) {
        CHECK(event.header.eventType != AMCL_INPUT_EVENT_FOCUS_CHANGED);
        if (event.header.eventType == AMCL_INPUT_EVENT_PHYSICAL_KEY) {
            CHECK(event.payload.physicalKey.action == AMCL_INPUT_ACTION_UP);
            CHECK(event.header.deviceId == 31u || event.header.deviceId == 32u);
            ++releases;
        }
        if (event.header.eventType == AMCL_INPUT_EVENT_RESET) {
            CHECK(event.payload.reset.reason == AMCL_INPUT_RESET_CAPTURE_LOST);
            ++resets;
        }
    }
    CHECK(result == AMCL_INPUT_EMPTY && releases == 2u && resets == 1u);
    CHECK(!PlatformInputTextCommit(editor, bytes, 1u));
    CHECK(PlatformInputTextSessionBegin(editor + 100u));
    CHECK(PlatformInputTextCommit(editor + 100u, bytes, 1u));
    CHECK(PlatformInputTextSessionAbort(editor + 100u));
    fixture.Drain();
}

int main() {
#ifdef _WIN32
    CHECK(_putenv_s("AMCL_GLFW_INPUT_BACKEND", "typed") == 0);
    CHECK(_putenv_s("AMCL_INPUT_SHADOW", "0") == 0);
#else
    CHECK(setenv("AMCL_GLFW_INPUT_BACKEND", "typed", 1) == 0);
    CHECK(setenv("AMCL_INPUT_SHADOW", "0", 1) == 0);
#endif
    Fixture fixture;
    fixture.api = amclInputGetHostApiV1();
    PlatformInputSurfaceCreated(800u, 600u);
    PlatformInputFocusChanged(true);
    CHECK(fixture.api->openConsumer(&fixture.consumer) == AMCL_INPUT_OK);
    AmclInputEvent baseline{};
    CHECK(fixture.api->nextEvent(fixture.consumer, &baseline) == AMCL_INPUT_OK);
    fixture.Drain();
    AmclInputEvent ready{};
    ready.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    ready.header.structSize = sizeof(ready);
    ready.header.eventType = AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE;
    ready.header.sessionEpoch = baseline.header.sessionEpoch;
    ready.payload.backendConsumerState.state = AMCL_INPUT_BACKEND_CONSUMER_READY;
    ready.payload.backendConsumerState.backend = AMCL_INPUT_BACKEND_GLFW_PHYSICAL;
    ready.payload.backendConsumerState.consumer = fixture.consumer;
    ready.payload.backendConsumerState.generation = AMCL_INPUT_HOST_API_GENERATION;
    ready.payload.backendConsumerState.baselineSequence = baseline.header.sequence;
    CHECK(fixture.api->submitEvent(&ready) == AMCL_INPUT_OK);

    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, true));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 22u, 1u, true));
    CHECK(fixture.Snapshot().heldControlCount == 2u);
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 22u, 1u, false));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, false));
    CHECK(fixture.Snapshot().heldControlCount == 0u);
    for (uint32_t button : {2u, 8u, 16u}) {
        CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, button, true));
        CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, button, true));
        CHECK(!fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, button, false));
        CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, button, false));
        CHECK(fixture.Snapshot().heldControlCount == 0u);
    }

    PlatformInputDeviceChanged(11u, true, AMCL_INPUT_DEVICE_CAP_POINTER_BUTTONS,
        AMCL_INPUT_DEVICE_CLASS_MOUSE);
    fixture.Drain();
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_NATIVE_MOUSE, 0u, 4u, true));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 11u, 1u, true));
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 22u, 1u, true));
    amcl_input_policy_release_pointer_device(11u, true, Fixture::Removed, &fixture);
    PlatformInputDeviceChanged(11u, false, 0u, AMCL_INPUT_DEVICE_CLASS_UNKNOWN);
    fixture.Drain();
    CHECK(fixture.Snapshot().heldControlCount == 1u);
    CHECK(fixture.Edge(AMCL_INPUT_CHANNEL_ARKUI_MOUSE, 22u, 1u, false));
    CHECK(fixture.Snapshot().heldControlCount == 0u);

    PlatformInputCaptureRequested(true);
    PlatformInputCapturePlatformChanged(true, AMCL_INPUT_CAPTURE_REASON_GRANTED);
    fixture.Drain();
    CHECK(fixture.Snapshot().captureActive == 1u);
    // 普通开菜单先撤回游戏意图，再收到平台解锁；最终元组必须与SDL消费者的校验一致。
    PlatformInputCaptureRequested(false);
    PlatformInputCapturePlatformChanged(false, AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST);
    fixture.Drain();
    const auto unlockedSnapshot = fixture.Snapshot();
    CHECK(unlockedSnapshot.captureRequested == 0u && unlockedSnapshot.captureActive == 0u);
    CHECK(unlockedSnapshot.captureReason == AMCL_INPUT_CAPTURE_REASON_NONE);
    // 重新建立真实捕获，再验证下面仍有请求的设备丢失分支没有被规范化吞掉。
    PlatformInputCaptureRequested(true);
    PlatformInputCapturePlatformChanged(true, AMCL_INPUT_CAPTURE_REASON_GRANTED);
    fixture.Drain();
    // 平台因设备能力消失而unlock，游戏仍requested=true；本事实必须到达core。
    PlatformInputCapturePlatformChanged(false, AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST);
    fixture.Drain();
    auto snapshot = fixture.Snapshot();
    CHECK(snapshot.captureRequested == 1u && snapshot.captureActive == 0u);
    CHECK(snapshot.captureReason == AMCL_INPUT_CAPTURE_REASON_PLATFORM_LOST);
    PlatformInputCapturePlatformChanged(true, AMCL_INPUT_CAPTURE_REASON_GRANTED);
    PlatformInputFocusChanged(false);
    fixture.Drain();
    PlatformInputCapturePlatformChanged(true, AMCL_INPUT_CAPTURE_REASON_GRANTED);
    CHECK(fixture.Snapshot().captureActive == 0u);
    PlatformInputFocusChanged(true);
    PlatformInputCapturePlatformChanged(true, AMCL_INPUT_CAPTURE_REASON_GRANTED);
    fixture.Drain();
    CHECK(fixture.Snapshot().captureActive == 1u);
    VerifyCaptureResetPolicy(fixture, true);
    VerifyCaptureResetPolicy(fixture, false);
    std::puts("platform_pointer_lifecycle_integration_test: all checks passed");
}
