// 多消费者生命周期的生产core回归。保留默认256槽，不缩容量、不用替身core：
// 一个活跃消费者每条都drain时，兄弟的退出/队列或blob积压不得释放它的物理键、
// 撤销capture或终止IME token。最后active退出和真实焦点边界仍须完整收口。
#include "../../input/input_state_core.h"
#include "../../input/adapters/glfw_backend_lifecycle.h"

#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

namespace {
using amcl::input::InputStateCore;
[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "CONSUMER ISOLATION FAIL line " << line << ": " << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)
constexpr uint64_t kTextSession = 91u;

// 每个样本均走公开POD输入协议，字段赋名避免把backend与state等相同类型误对调。
AmclInputEvent Event(uint32_t type, uint64_t epoch) {
    AmclInputEvent event{};
    event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    event.header.structSize = static_cast<uint16_t>(sizeof(event));
    event.header.eventType = type;
    event.header.sessionEpoch = epoch;
    return event;
}
AmclInputEvent Control(uint32_t state, uint32_t backend, uint64_t consumer,
                       uint64_t epoch, uint64_t baseline = 0u) {
    auto event = Event(AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE, epoch);
    event.payload.backendConsumerState.state = state;
    event.payload.backendConsumerState.backend = backend;
    event.payload.backendConsumerState.consumer = consumer;
    event.payload.backendConsumerState.generation = AMCL_INPUT_HOST_API_GENERATION;
    event.payload.backendConsumerState.baselineSequence = baseline;
    return event;
}

struct DrainResult {
    int32_t terminal = AMCL_INPUT_EMPTY;
    std::vector<AmclInputEvent> events;
};

// 完整复制/释放owned blob，模拟正常消费者；releaseBlobs=false仅用来模拟
// 事件已取走但忘记归还包的故障端，验证blob压力与队列压力是两条独立边界。
DrainResult Drain(InputStateCore& core, uint64_t consumer, bool releaseBlobs = true) {
    DrainResult result;
    AmclInputEvent event{};
    while ((result.terminal = core.NextEvent(consumer, &event)) == AMCL_INPUT_OK) {
        result.events.push_back(event);
        uint64_t packet = 0u;
        if (event.header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT) {
            packet = event.payload.textCommit.utf8Blob.packetId;
        }
        if (packet != 0u && releaseBlobs) {
            uint8_t bytes[4096]{};
            uint32_t count = 0u;
            CHECK(core.ReadPacketBlob(consumer, &event.payload.textCommit.utf8Blob,
                                      bytes, sizeof(bytes), &count) == AMCL_INPUT_OK);
            CHECK(core.ReleasePacket(consumer, packet) == AMCL_INPUT_OK);
        }
    }
    CHECK(result.terminal == AMCL_INPUT_EMPTY || result.terminal == AMCL_INPUT_ERROR_STALE);
    return result;
}

struct Harness {
    InputStateCore core{true, true};
    uint64_t epoch = 0u;
    Harness() {
        CHECK(core.BeginSession(&epoch) == AMCL_INPUT_OK);
        CHECK(core.PublishFocus(1u) == AMCL_INPUT_OK);
        CHECK(Snapshot().queueCapacity == 256u);
    }
    AmclInputSnapshotV1 Snapshot() {
        AmclInputSnapshotV1 value{};
        value.abiVersion = AMCL_INPUT_HOST_API_VERSION;
        value.structSize = static_cast<uint16_t>(sizeof(value));
        CHECK(core.GetSnapshot(&value) == AMCL_INPUT_OK);
        return value;
    }
    // §11 计数（C++ 内部面）：用来区分全局复位与局部压力退休。
    amcl::input::CoreObservabilityV1 Obs() {
        amcl::input::CoreObservabilityV1 value{};
        CHECK(core.GetObservability(&value) == AMCL_INPUT_OK);
        return value;
    }
    int32_t Motion() {
        auto motion = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE, epoch);
        motion.header.source = AMCL_INPUT_SOURCE_MOUSE;
        motion.header.deviceId = 8u;
        motion.payload.pointerRelative.rawDx = 1.0;
        return core.SubmitEvent(&motion);
    }
    int32_t KeyDown(uint32_t raw) {
        auto key = Event(AMCL_INPUT_EVENT_PHYSICAL_KEY, epoch);
        key.header.source = AMCL_INPUT_SOURCE_KEYBOARD;
        key.header.deviceId = 7u;
        key.payload.physicalKey.physicalKey = raw;
        key.payload.physicalKey.action = AMCL_INPUT_ACTION_DOWN;
        return core.SubmitEvent(&key);
    }
    uint64_t Open(uint32_t backend) {
        uint64_t consumer = 0u;
        CHECK(core.OpenConsumer(&consumer) == AMCL_INPUT_OK);
        const auto baseline = Drain(core, consumer);
        CHECK(!baseline.events.empty());
        CHECK(baseline.events.front().payload.reset.reason == AMCL_INPUT_RESET_CONSUMER_BASELINE);
        if (backend != 0u) {
            auto ready = Control(AMCL_INPUT_BACKEND_CONSUMER_READY, backend,
                                 consumer, epoch, baseline.events.front().header.sequence);
            CHECK(core.SubmitEvent(&ready) == AMCL_INPUT_OK);
        }
        return consumer;
    }
    void HoldAndCaptureAndText() {
        auto key = Event(AMCL_INPUT_EVENT_PHYSICAL_KEY, epoch);
        key.header.source = AMCL_INPUT_SOURCE_KEYBOARD;
        key.header.deviceId = 7u;
        key.payload.physicalKey.physicalKey = 2039u;
        key.payload.physicalKey.action = AMCL_INPUT_ACTION_DOWN;
        CHECK(core.SubmitEvent(&key) == AMCL_INPUT_OK);
        auto capture = Event(AMCL_INPUT_EVENT_CAPTURE_CHANGED, epoch);
        capture.header.source = AMCL_INPUT_SOURCE_MOUSE;
        capture.payload.capture.requested = 1u;
        capture.payload.capture.active = 1u;
        capture.payload.capture.reason = AMCL_INPUT_CAPTURE_REASON_GRANTED;
        CHECK(core.SubmitEvent(&capture) == AMCL_INPUT_OK);
        auto text = Event(AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED, epoch);
        text.header.source = AMCL_INPUT_SOURCE_IME;
        text.payload.textSession.textSessionId = kTextSession;
        text.payload.textSession.change = AMCL_INPUT_TEXT_SESSION_STARTED;
        text.payload.textSession.reason = AMCL_INPUT_TEXT_SESSION_REASON_EXPLICIT;
        CHECK(core.SubmitEvent(&text) == AMCL_INPUT_OK);
    }
    int32_t Text(uint32_t bytes = 1u) {
        auto text = Event(AMCL_INPUT_EVENT_TEXT_COMMIT, epoch);
        text.header.source = AMCL_INPUT_SOURCE_IME;
        text.payload.textCommit.textSessionId = kTextSession;
        std::vector<uint8_t> utf8(bytes, 'a');
        return core.SubmitTextPacket(&text, utf8.data(), bytes);
    }
    void AssertLive() {
        const auto state = Snapshot();
        CHECK(state.heldControlCount == 1u);
        CHECK(state.captureRequested == 1u && state.captureActive == 1u);
        CHECK(Text() == AMCL_INPUT_OK); // 证明原token继续可提交，而不只看本地布尔。
    }
};

void CheckNoResetOrRelease(const DrainResult& result) {
    for (const auto& event : result.events) {
        CHECK(event.header.eventType != AMCL_INPUT_EVENT_RESET);
        CHECK(event.header.eventType != AMCL_INPUT_EVENT_PHYSICAL_KEY ||
              event.payload.physicalKey.action != AMCL_INPUT_ACTION_UP);
    }
}

// 活跃sibling收到原始按下后，另一个consumer的RETIRE/ABANDON只影响自己。
// RETIRE还必须保持旧数据→定向RESET的顺序，不能先reset再重放旧DOWN。
void TestLocalRetirement(uint32_t exitKind) {
    Harness h;
    const auto sdl = h.Open(AMCL_INPUT_BACKEND_SDL3_PHYSICAL);
    const auto glfw = h.Open(AMCL_INPUT_BACKEND_GLFW_PHYSICAL);
    const auto maintenance = h.Open(0u);
    h.HoldAndCaptureAndText();
    Drain(h.core, sdl);
    Drain(h.core, maintenance);
    const auto exit = Control(exitKind, AMCL_INPUT_BACKEND_GLFW_PHYSICAL, glfw, h.epoch);
    CHECK(h.core.SubmitEvent(&exit) == AMCL_INPUT_OK);
    h.AssertLive();
    CheckNoResetOrRelease(Drain(h.core, sdl));
    CheckNoResetOrRelease(Drain(h.core, maintenance));
    if (exitKind == AMCL_INPUT_BACKEND_CONSUMER_RETIRE) {
        const auto old = Drain(h.core, glfw);
        CHECK(old.events.front().header.eventType == AMCL_INPUT_EVENT_PHYSICAL_KEY);
        CHECK(old.events.back().header.eventType == AMCL_INPUT_EVENT_RESET);
        for (size_t i = 1u; i < old.events.size(); ++i) {
            CHECK(old.events[i - 1u].header.sequence < old.events[i].header.sequence);
        }
        CHECK(h.core.CloseConsumer(glfw) == AMCL_INPUT_OK);
    }
    // 最后active退出仍是全局边界，不能为隔离兄弟而永久留下无人消费的按下态。
    const auto last = Control(AMCL_INPUT_BACKEND_CONSUMER_RETIRE,
                             AMCL_INPUT_BACKEND_SDL3_PHYSICAL, sdl, h.epoch);
    CHECK(h.core.SubmitEvent(&last) == AMCL_INPUT_OK);
    CHECK(h.Snapshot().heldControlCount == 0u && h.Snapshot().captureActive == 0u);
    CHECK(h.Text() == AMCL_INPUT_ERROR_STALE);
    const auto closing = Drain(h.core, sdl);
    CHECK(closing.events.back().header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(h.core.CloseConsumer(sdl) == AMCL_INPUT_OK);
}

// 使用production 256槽。SDL每个样本立即drain；另一个READY或普通observer不读。
// 旧实现在256附近全局reset，本断言要求只退休积压者并允许正常端继续持有。
void TestQueuePressure(uint32_t lagBackend) {
    Harness h;
    const auto sdl = h.Open(AMCL_INPUT_BACKEND_SDL3_PHYSICAL);
    const auto lag = h.Open(lagBackend);
    const auto maintenance = h.Open(0u);
    h.HoldAndCaptureAndText();
    Drain(h.core, sdl);
    Drain(h.core, lag);
    Drain(h.core, maintenance);
    const auto before = h.Obs();
    const uint64_t globalBefore = h.Snapshot().overflowResetCount;
    for (unsigned i = 0; i < 600u; ++i) {
        CHECK(h.Motion() == AMCL_INPUT_OK);
        CheckNoResetOrRelease(Drain(h.core, sdl));
        CheckNoResetOrRelease(Drain(h.core, maintenance));
    }
    // 计数拆分：一次局部退休只进 queue 压力计数，全局复位计数（含 V1 快照字段）不动。
    const auto after = h.Obs();
    CHECK(after.pressureRetirementsQueue == before.pressureRetirementsQueue + 1u);
    CHECK(after.pressureRetirementsBlob == before.pressureRetirementsBlob);
    CHECK(after.queueOverflowResets == before.queueOverflowResets);
    CHECK(h.Snapshot().overflowResetCount == globalBefore);
    h.AssertLive();
    CheckNoResetOrRelease(Drain(h.core, sdl));
    CheckNoResetOrRelease(Drain(h.core, maintenance));
    const auto dropped = Drain(h.core, lag);
    CHECK(dropped.events.size() == 1u);
    CHECK(dropped.events[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    CHECK(dropped.events[0].payload.reset.reason == AMCL_INPUT_RESET_QUEUE_OVERFLOW);
    CHECK(dropped.terminal == AMCL_INPUT_ERROR_STALE);
    if (lagBackend != 0u) {
        const auto abandon = Control(AMCL_INPUT_BACKEND_CONSUMER_ABANDON,
                                     lagBackend, lag, h.epoch);
        CHECK(h.core.SubmitEvent(&abandon) == AMCL_INPUT_OK);
    } else {
        CHECK(h.core.CloseConsumer(lag) == AMCL_INPUT_OK);
    }
    h.AssertLive();
    CheckNoResetOrRelease(Drain(h.core, sdl));
    // 新incarnation只接当前baseline/text token，不重放已经失去完整边界的历史DOWN。
    const auto replacement = h.Open(lagBackend);
    CHECK(replacement != lag);
    CHECK(h.Text() == AMCL_INPUT_OK);
    CheckNoResetOrRelease(Drain(h.core, sdl));
    const auto fresh = Drain(h.core, replacement);
    CHECK(fresh.events.size() == 1u);
    CHECK(fresh.events[0].header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT);
}

void TestBlobPressure() {
    Harness h;
    const auto sdl = h.Open(AMCL_INPUT_BACKEND_SDL3_PHYSICAL);
    const auto lag = h.Open(AMCL_INPUT_BACKEND_GLFW_PHYSICAL);
    h.HoldAndCaptureAndText(); Drain(h.core, sdl); Drain(h.core, lag);
    const auto before = h.Obs();
    bool retired = false;
    for (unsigned i = 0; i < 40u; ++i) {
        CHECK(h.Text(4096u) == AMCL_INPUT_OK);
        CheckNoResetOrRelease(Drain(h.core, sdl));
        if (!retired) {
            const auto result = Drain(h.core, lag, false);
            retired = result.terminal == AMCL_INPUT_ERROR_STALE;
            if (retired) {
                CHECK(result.events.size() == 1u);
                CHECK(result.events[0].payload.reset.reason == AMCL_INPUT_RESET_BLOB_POOL_EXHAUSTED);
            }
        }
    }
    CHECK(retired);
    CHECK(h.Obs().pressureRetirementsBlob == before.pressureRetirementsBlob + 1u);
    CHECK(h.Obs().queueOverflowResets == before.queueOverflowResets);
    h.AssertLive(); CheckNoResetOrRelease(Drain(h.core, sdl));
    CHECK(h.Snapshot().blobBytes == 0u);
    // 焦点是全局真实边界：隔离机制不能把失焦误当某个consumer自己的故障。
    CHECK(h.core.PublishFocus(0u) == AMCL_INPUT_OK);
    CHECK(h.Snapshot().heldControlCount == 0u && h.Snapshot().captureActive == 0u);
    CHECK(h.Text() == AMCL_INPUT_ERROR_STALE);
}

void TestPresentedQualification() {
    using amcl::input::GlfwHasPresentedInputTarget;
    CHECK(!GlfwHasPresentedInputTarget(false, false, false, false, false));
    CHECK(!GlfwHasPresentedInputTarget(true, true, true, true, false));
    CHECK(!GlfwHasPresentedInputTarget(true, false, false, true, false));
    CHECK(!GlfwHasPresentedInputTarget(true, false, true, false, false));
    CHECK(!GlfwHasPresentedInputTarget(true, false, true, true, true));
    CHECK(GlfwHasPresentedInputTarget(true, false, true, true, false));
}

// 序列空间极限：压力隔离的私有RESET不能侵占一笔多边沿操作的预算；
// 批次后续失败则连consumer角色/定向控制记录一起回滚，保持可重新drain的旧事实。
void TestIsolationSequenceBudgetAndBatchRollback() {
    for (bool batch : {false, true}) {
        Harness h;
        const auto sdl = h.Open(AMCL_INPUT_BACKEND_SDL3_PHYSICAL);
        const auto lag = h.Open(AMCL_INPUT_BACKEND_GLFW_PHYSICAL);
        h.HoldAndCaptureAndText(); Drain(h.core, sdl); Drain(h.core, lag);
        if (!batch) {
            // 同一device再持有两个键，使REMOVED需要3条UP+1条DEVICE。
            for (uint32_t key : {2017u, 2018u}) {
                auto down = Event(AMCL_INPUT_EVENT_PHYSICAL_KEY, h.epoch);
                down.header.source = AMCL_INPUT_SOURCE_KEYBOARD;
                down.header.deviceId = 7u;
                down.payload.physicalKey.physicalKey = key;
                down.payload.physicalKey.action = AMCL_INPUT_ACTION_DOWN;
                CHECK(h.core.SubmitEvent(&down) == AMCL_INPUT_OK);
            }
            Drain(h.core, sdl); Drain(h.core, lag);
        }
        for (unsigned i = 0; i < 256u; ++i) {
            auto motion = Event(AMCL_INPUT_EVENT_POINTER_RELATIVE, h.epoch);
            motion.header.source = AMCL_INPUT_SOURCE_MOUSE;
            motion.header.deviceId = 8u;
            motion.payload.pointerRelative.rawDx = 1.0;
            CHECK(h.core.SubmitEvent(&motion) == AMCL_INPUT_OK);
            Drain(h.core, sdl);
        }
        h.core.TestSetNextSequence(std::numeric_limits<uint64_t>::max() - (batch ? 3u : 4u));
        if (batch) {
            AmclInputEvent events[3]{};
            for (uint32_t i = 0; i < 3u; ++i) {
                events[i] = Event(AMCL_INPUT_EVENT_PHYSICAL_KEY, h.epoch);
                events[i].header.source = AMCL_INPUT_SOURCE_KEYBOARD;
                events[i].header.deviceId = 7u;
                events[i].payload.physicalKey.physicalKey = 2017u + i;
                events[i].payload.physicalKey.action = AMCL_INPUT_ACTION_DOWN;
            }
            CHECK(h.core.SubmitBatch(events, 3u) == AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED);
            CHECK(Drain(h.core, sdl).events.empty());
            const auto old = Drain(h.core, lag);
            CHECK(old.terminal == AMCL_INPUT_EMPTY && old.events.size() == 256u);
            CheckNoResetOrRelease(old);
            CHECK(h.Snapshot().heldControlCount == 1u && h.Snapshot().captureActive == 1u);
            const auto retire = Control(AMCL_INPUT_BACKEND_CONSUMER_RETIRE,
                                         AMCL_INPUT_BACKEND_SDL3_PHYSICAL, sdl, h.epoch);
            CHECK(h.core.SubmitEvent(&retire) == AMCL_INPUT_OK);
            CHECK(h.Snapshot().heldControlCount == 1u); // GLFW的READY槽也必须恢复。
        } else {
            CHECK(h.core.PublishDeviceChange(7u, AMCL_INPUT_DEVICE_REMOVED, 0u) == AMCL_INPUT_OVERFLOW_RESET);
            const auto reset = Drain(h.core, sdl);
            CHECK(reset.events.size() == 1u && reset.events[0].header.eventType == AMCL_INPUT_EVENT_RESET);
            CHECK(h.Snapshot().heldControlCount == 0u); // 预算不足走完整恢复，绝不交付半批UP。
        }
    }
}

// 两个READY后端欠着同一批记录：退休任何一个都腾不出槽位（另一个仍欠）。只允许一次
// 全局复位：两边各收到同一条RESET后仍是READY(EMPTY而非STALE)，压力计数不变。
// 旧实现先私有退休其一、再全局复位，本用例对旧实现失败（该端读到STALE）。
void TestBothReadyLagSingleGlobalReset() {
    Harness h;
    const auto sdl = h.Open(AMCL_INPUT_BACKEND_SDL3_PHYSICAL);
    const auto glfw = h.Open(AMCL_INPUT_BACKEND_GLFW_PHYSICAL);
    const auto maintenance = h.Open(0u);
    h.HoldAndCaptureAndText();
    Drain(h.core, sdl); Drain(h.core, glfw); Drain(h.core, maintenance);
    const auto before = h.Obs();
    const uint64_t globalBefore = h.Snapshot().overflowResetCount;
    for (unsigned i = 0; i < 256u; ++i) {
        CHECK(h.Motion() == AMCL_INPUT_OK);
        CheckNoResetOrRelease(Drain(h.core, maintenance));
    }
    CHECK(h.Motion() == AMCL_INPUT_OVERFLOW_RESET);
    for (const uint64_t consumer : {sdl, glfw, maintenance}) {
        const auto result = Drain(h.core, consumer);
        CHECK(result.terminal == AMCL_INPUT_EMPTY);
        CHECK(result.events.size() == 1u);
        CHECK(result.events[0].header.eventType == AMCL_INPUT_EVENT_RESET);
        CHECK(result.events[0].payload.reset.reason == AMCL_INPUT_RESET_QUEUE_OVERFLOW);
    }
    const auto after = h.Obs();
    CHECK(after.queueOverflowResets == before.queueOverflowResets + 1u);
    CHECK(after.pressureRetirementsQueue == before.pressureRetirementsQueue);
    CHECK(after.resetsEmitted == before.resetsEmitted + 1u);
    CHECK(h.Snapshot().overflowResetCount == globalBefore + 1u);
    CHECK(h.Snapshot().heldControlCount == 0u && h.Snapshot().captureActive == 0u);
    // 两端都无需重握手：新按键照常同时送达。
    CHECK(h.KeyDown(2017u) == AMCL_INPUT_OK);
    CHECK(Drain(h.core, sdl).events.size() == 1u);
    CHECK(Drain(h.core, glfw).events.size() == 1u);
}

// 第二个后端握手时生产者闸门早已打开：基线读空之后、READY之前写入的记录不再让READY
// STALE，READY后按序送达且不重放基线前的DOWN。负向对照：基线未读、已被压力退休、
// 持有“非最近读走”的未归还文本包时READY仍须STALE。
void TestReadyAcceptsPostBaselineBacklog() {
    Harness h;
    const auto sdl = h.Open(AMCL_INPUT_BACKEND_SDL3_PHYSICAL);
    h.HoldAndCaptureAndText(); // 2039在基线之前按下，是历史DOWN。
    Drain(h.core, sdl);

    uint64_t unread = 0u;
    CHECK(h.core.OpenConsumer(&unread) == AMCL_INPUT_OK);
    auto unreadReady = Control(AMCL_INPUT_BACKEND_CONSUMER_READY,
                               AMCL_INPUT_BACKEND_LWJGL2_PHYSICAL, unread, h.epoch, 1u);
    CHECK(h.core.SubmitEvent(&unreadReady) == AMCL_INPUT_ERROR_STALE);
    CHECK(h.core.CloseConsumer(unread) == AMCL_INPUT_OK);

    uint64_t late = 0u;
    CHECK(h.core.OpenConsumer(&late) == AMCL_INPUT_OK);
    const auto baseline = Drain(h.core, late);
    CHECK(baseline.terminal == AMCL_INPUT_EMPTY);
    CHECK(h.KeyDown(2017u) == AMCL_INPUT_OK); // 基线EMPTY之后、READY之前注入。
    auto ready = Control(AMCL_INPUT_BACKEND_CONSUMER_READY,
                         AMCL_INPUT_BACKEND_LWJGL2_PHYSICAL, late, h.epoch,
                         baseline.events.front().header.sequence);
    CHECK(h.core.SubmitEvent(&ready) == AMCL_INPUT_OK);
    const auto delivered = Drain(h.core, late);
    CHECK(delivered.terminal == AMCL_INPUT_EMPTY && delivered.events.size() == 1u);
    CHECK(delivered.events[0].header.eventType == AMCL_INPUT_EVENT_PHYSICAL_KEY);
    CHECK(delivered.events[0].payload.physicalKey.physicalKey == 2017u);
    CHECK(delivered.events[0].payload.physicalKey.action == AMCL_INPUT_ACTION_DOWN);
    CheckNoResetOrRelease(Drain(h.core, sdl));
    CHECK(h.Snapshot().heldControlCount == 2u);

    uint64_t carrier = 0u;
    CHECK(h.core.OpenConsumer(&carrier) == AMCL_INPUT_OK);
    const auto carrierBaseline = Drain(h.core, carrier);
    CHECK(h.Text() == AMCL_INPUT_OK);
    CHECK(h.Text() == AMCL_INPUT_OK);
    Drain(h.core, sdl); Drain(h.core, late);
    AmclInputEvent first{};
    AmclInputEvent second{};
    CHECK(h.core.NextEvent(carrier, &first) == AMCL_INPUT_OK);
    CHECK(h.core.NextEvent(carrier, &second) == AMCL_INPUT_OK);
    CHECK(first.header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT);
    CHECK(second.header.eventType == AMCL_INPUT_EVENT_TEXT_COMMIT);
    auto carrierReady = Control(AMCL_INPUT_BACKEND_CONSUMER_READY,
                                AMCL_INPUT_BACKEND_GLFW_PHYSICAL, carrier, h.epoch,
                                carrierBaseline.events.front().header.sequence);
    CHECK(h.core.SubmitEvent(&carrierReady) == AMCL_INPUT_ERROR_STALE);
    // 归还较早的包后，只剩“最近读走、交给首次Pump”的那一条，READY放行。
    CHECK(h.core.ReleasePacket(carrier, first.payload.textCommit.utf8Blob.packetId) ==
          AMCL_INPUT_OK);
    CHECK(h.core.SubmitEvent(&carrierReady) == AMCL_INPUT_OK);
    CHECK(h.core.ReleasePacket(carrier, second.payload.textCommit.utf8Blob.packetId) ==
          AMCL_INPUT_OK);

    uint64_t lagging = 0u;
    CHECK(h.core.OpenConsumer(&lagging) == AMCL_INPUT_OK);
    const auto laggingBaseline = Drain(h.core, lagging);
    for (unsigned i = 0; i < 300u; ++i) {
        CHECK(h.Motion() == AMCL_INPUT_OK);
        Drain(h.core, sdl); Drain(h.core, late); Drain(h.core, carrier);
    }
    auto laggingReady = Control(AMCL_INPUT_BACKEND_CONSUMER_READY,
                                AMCL_INPUT_BACKEND_GLFW_PHYSICAL, lagging, h.epoch,
                                laggingBaseline.events.front().header.sequence);
    CHECK(h.core.SubmitEvent(&laggingReady) == AMCL_INPUT_ERROR_STALE);
    CHECK(h.core.CloseConsumer(lagging) == AMCL_INPUT_OK);
    // 整个过程中全局 held/capture/text 都没有被任何一次拒绝或隔离清掉。
    CHECK(h.Snapshot().heldControlCount == 2u && h.Snapshot().captureActive == 1u);
    CHECK(h.Text() == AMCL_INPUT_OK);
}

// 最后一个active独占包池时没有可隔离者：全局复位成功即返回OVERFLOW_RESET（旧实现在
// 复位已发生后仍报RESOURCE_EXHAUSTED），held/文本包全部收口，只有一条BLOB RESET。
void TestLastActiveBlobExhaustionReturnsOverflowReset() {
    Harness h;
    const auto sdl = h.Open(AMCL_INPUT_BACKEND_SDL3_PHYSICAL);
    h.HoldAndCaptureAndText(); Drain(h.core, sdl);
    const auto before = h.Obs();
    for (unsigned i = 0; i < 16u; ++i) {
        CHECK(h.Text(4096u) == AMCL_INPUT_OK);
        Drain(h.core, sdl, false);
    }
    CHECK(h.Snapshot().blobBytes == 65536u);
    CHECK(h.Text(4096u) == AMCL_INPUT_OVERFLOW_RESET);
    CHECK(h.Snapshot().blobBytes == 0u && h.Snapshot().heldControlCount == 0u);
    const auto reset = Drain(h.core, sdl);
    CHECK(reset.terminal == AMCL_INPUT_EMPTY && reset.events.size() == 1u);
    CHECK(reset.events[0].payload.reset.reason == AMCL_INPUT_RESET_BLOB_POOL_EXHAUSTED);
    CHECK(h.Obs().queueOverflowResets == before.queueOverflowResets + 1u);
    CHECK(h.Obs().pressureRetirementsBlob == before.pressureRetirementsBlob);
}
} // namespace

int main() {
    TestPresentedQualification();
    TestLocalRetirement(AMCL_INPUT_BACKEND_CONSUMER_RETIRE);
    TestLocalRetirement(AMCL_INPUT_BACKEND_CONSUMER_ABANDON);
    TestQueuePressure(AMCL_INPUT_BACKEND_GLFW_PHYSICAL);
    TestQueuePressure(0u);
    TestBlobPressure();
    TestIsolationSequenceBudgetAndBatchRollback();
    TestBothReadyLagSingleGlobalReset();
    TestReadyAcceptsPostBaselineBacklog();
    TestLastActiveBlobExhaustionReturnsOverflowReset();
    std::cout << "input_consumer_isolation_test: PASS\n";
}
