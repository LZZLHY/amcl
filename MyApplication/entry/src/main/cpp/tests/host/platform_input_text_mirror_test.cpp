// ingress 文本会话镜像与 core 一致性（I27-12，T1–T3）的宿主回归。
//
// 同一份源码按三种进程配置各编译一次（见 CMakeLists 的 AMCL_TEXT_MIRROR_VARIANT）：
//   1 = legacy 物理路由 + shadow 对账开；2 = legacy + shadow 关；3 = typed + shadow 关。
// 三者都保留维护消费者，所以镜像规则必须在三种配置下同样成立。
//
// 每个场景都自带新 session（SurfaceCreated … SurfaceDestroyed），只用生产 ingress 入口与
// host 表直接调用（模拟另一个 DSO 在 ingress 背后改变 host 状态），断言三件事：
// epoch 恢复计数是否只统计真实恢复、前端 epoch 的推进次数、下一次 BEGIN 能否不靠
// XComponent 回调就成功。刻意不使用本轮新增的 ingress API，以便同一份测试对照编译到
// 修复前的 ingress 上作为负向对照（旧实现必须在这些断言上失败）。
#include "amcl_input_api.h"
#include "input_trace.h"
#include "platform_input_ingress.h"

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#ifndef AMCL_TEXT_MIRROR_VARIANT
#define AMCL_TEXT_MIRROR_VARIANT 1
#endif

namespace {
const AmclInputHostApiV1* gApi = nullptr;
uint64_t gNextPublication = 1000u;

[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "TEXT MIRROR FAIL variant=" << AMCL_TEXT_MIRROR_VARIANT
              << " line " << line << ": " << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)

// host 表在第一次调用时锁存路由，所以必须在任何 ingress/host 调用之前设置环境。
void SelectVariant() {
    const char* shadow = AMCL_TEXT_MIRROR_VARIANT == 1 ? "1" : "0";
    const char* route = AMCL_TEXT_MIRROR_VARIANT == 3 ? "typed" : "legacy";
#ifdef _WIN32
    CHECK(_putenv_s("AMCL_INPUT_SHADOW", shadow) == 0);
    CHECK(_putenv_s("AMCL_GLFW_INPUT_BACKEND", route) == 0);
#else
    CHECK(setenv("AMCL_INPUT_SHADOW", shadow, 1) == 0);
    CHECK(setenv("AMCL_GLFW_INPUT_BACKEND", route, 1) == 0);
#endif
}

AmclInputSnapshotV1 Snapshot() {
    AmclInputSnapshotV1 value{};
    value.abiVersion = AMCL_INPUT_HOST_API_VERSION;
    value.structSize = static_cast<uint16_t>(sizeof(value));
    CHECK(gApi->getSnapshot(&value) == AMCL_INPUT_OK);
    return value;
}

std::vector<AmclInputEvent> Drain(AmclInputConsumerHandle consumer) {
    std::vector<AmclInputEvent> events;
    for (;;) {
        AmclInputEvent event{};
        const int32_t result = gApi->nextEvent(consumer, &event);
        if (result == AMCL_INPUT_EMPTY) return events;
        CHECK(result == AMCL_INPUT_OK);
        events.push_back(event);
    }
}

bool HasReset(const std::vector<AmclInputEvent>& events) {
    for (const auto& event : events) {
        if (event.header.eventType == AMCL_INPUT_EVENT_RESET) return true;
    }
    return false;
}

bool HasTextSession(const std::vector<AmclInputEvent>& events,
                    uint32_t change, uint64_t id) {
    for (const auto& event : events) {
        if (event.header.eventType == AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED &&
            event.payload.textSession.change == change &&
            event.payload.textSession.textSessionId == id) {
            return true;
        }
    }
    return false;
}

// 以 host 当前 epoch 直接提交文本会话事件，模拟 ingress 之外的写入者。
void SubmitExternalTextSession(uint64_t id, uint32_t change) {
    const AmclInputSnapshotV1 snapshot = Snapshot();
    AmclInputEvent event{};
    event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    event.header.structSize = static_cast<uint16_t>(sizeof(event));
    event.header.eventType = AMCL_INPUT_EVENT_TEXT_SESSION_CHANGED;
    event.header.source = AMCL_INPUT_SOURCE_IME;
    event.header.sessionEpoch = snapshot.sessionEpoch;
    event.header.focusEpoch = snapshot.focusEpoch;
    event.header.surfaceEpoch = snapshot.surfaceEpoch;
    event.payload.textSession.textSessionId = id;
    event.payload.textSession.change = change;
    event.payload.textSession.reason = AMCL_INPUT_TEXT_SESSION_REASON_EXPLICIT;
    CHECK(gApi->submitEvent(&event) == AMCL_INPUT_OK);
}

AmclInputEvent BackendState(uint32_t state, AmclInputConsumerHandle consumer,
                            uint64_t baselineSequence) {
    AmclInputEvent event{};
    event.header.abiVersion = AMCL_INPUT_EVENT_ABI_VERSION;
    event.header.structSize = static_cast<uint16_t>(sizeof(event));
    event.header.eventType = AMCL_INPUT_EVENT_BACKEND_CONSUMER_STATE;
    event.header.sessionEpoch = Snapshot().sessionEpoch;
    event.payload.backendConsumerState.state = state;
    event.payload.backendConsumerState.backend =
        AMCL_INPUT_BACKEND_GLFW_PHYSICAL;
    event.payload.backendConsumerState.consumer = consumer;
    event.payload.backendConsumerState.generation =
        AMCL_INPUT_HOST_API_GENERATION;
    event.payload.backendConsumerState.baselineSequence = baselineSequence;
    return event;
}

bool Commit(uint64_t id, char value) {
    const uint8_t text[] = {static_cast<uint8_t>(value)};
    return amcl::input::PlatformInputTextCommit(id, text, 1u);
}

// 每个场景一份新 publication，避免与前一场景的 surface 绑定混淆。
uint64_t StartSession() {
    const uint64_t publication = ++gNextPublication;
    amcl::input::PlatformInputSurfaceCreated(640u, 480u, publication);
    CHECK(Snapshot().sessionActive != 0u);
    return publication;
}

void CloseObserver(AmclInputConsumerHandle consumer) {
    for (int attempt = 0; attempt < 4; ++attempt) {
        (void)Drain(consumer);
        const int32_t result = gApi->closeConsumer(consumer);
        if (result == AMCL_INPUT_OK) return;
        CHECK(result == AMCL_INPUT_DRAIN_REQUIRED);
    }
    Fail("observer close did not converge", __LINE__);
}

uint64_t Recovered() {
    return amcl::input::trace::TestEpochRecoverySnapshot().recovered;
}

// T1：最后一个 READY 后端退休让 core 清掉文本会话；随后旧号提交得到 STALE。
// 这是文本归属不符而非 epoch 失败：不计 epoch 恢复，前端 epoch 只因那次真实 RESET
// 推进一次，surface 绑定保留，下一次 BEGIN 不需要 surface 回调。
void TestRetireThenCommitIsOwnerMismatch() {
    const uint64_t publication = StartSession();
    AmclInputConsumerHandle observer = 0u;
    CHECK(gApi->openConsumer(&observer) == AMCL_INPUT_OK);
    const auto baseline = Drain(observer);
    CHECK(!baseline.empty() && baseline[0].header.eventType == AMCL_INPUT_EVENT_RESET);
    const AmclInputEvent ready = BackendState(
        AMCL_INPUT_BACKEND_CONSUMER_READY, observer, baseline[0].header.sequence);
    CHECK(gApi->submitEvent(&ready) == AMCL_INPUT_OK);
    CHECK(amcl::input::PlatformInputTextSessionBegin(101u));
    (void)Drain(observer);

    const uint64_t epochBefore = amcl::input::PlatformInputResetEpoch();
    const uint64_t recoveredBefore = Recovered();
    const AmclInputEvent retire =
        BackendState(AMCL_INPUT_BACKEND_CONSUMER_RETIRE, observer, 0u);
    CHECK(gApi->submitEvent(&retire) == AMCL_INPUT_OK);
    CHECK(!Commit(101u, 'x'));
    CHECK(amcl::input::PlatformInputResetEpoch() == epochBefore + 1u);
    CHECK(Recovered() == recoveredBefore);
    CHECK(amcl::input::PlatformInputTextSessionBegin(102u));
    CHECK(Commit(102u, 'y'));
    CloseObserver(observer);
    amcl::input::PlatformInputSurfaceDestroyed(publication);
    std::cout << "T1 retire -> owner mismatch without recovery: PASS\n";
}

// T1b：会话在 ingress 背后被中止且没有 RESET。ArkTS 仍握着旧宿主号，必须恰好推进
// 一次前端 epoch 让它重新 BEGIN；旧号此后在本地就被拒，不会再推进。
void TestSilentLossAdvancesEpochOnce() {
    const uint64_t publication = StartSession();
    CHECK(amcl::input::PlatformInputTextSessionBegin(111u));
    SubmitExternalTextSession(111u, AMCL_INPUT_TEXT_SESSION_ABORTED);
    const uint64_t epochBefore = amcl::input::PlatformInputResetEpoch();
    const uint64_t recoveredBefore = Recovered();
    CHECK(!Commit(111u, 'a'));
    CHECK(amcl::input::PlatformInputResetEpoch() == epochBefore + 1u);
    CHECK(Recovered() == recoveredBefore);
    CHECK(!Commit(111u, 'b'));
    CHECK(amcl::input::PlatformInputResetEpoch() == epochBefore + 1u);
    CHECK(amcl::input::PlatformInputTextSessionBegin(112u));
    CHECK(Commit(112u, 'c'));
    amcl::input::PlatformInputSurfaceDestroyed(publication);
    std::cout << "T1b silent loss -> exactly one frontend epoch: PASS\n";
}

// T2：surface 发布后的 RESET 让复位锁存为真。BEGIN 成功后取消（RequestReset +
// CompleteResetBoundary，ohos_cancel_all_input 的顺序）必须真的让 core 复位并丢弃会话，
// 不能只清 ingress 镜像；否则下一次 BEGIN 撞上 core 孤儿（SESSION → 多余恢复）。
void TestLatchedCancelLeavesNoOrphan() {
    const uint64_t publication = StartSession();
    AmclInputConsumerHandle observer = 0u;
    CHECK(gApi->openConsumer(&observer) == AMCL_INPUT_OK);
    (void)Drain(observer);
    CHECK(amcl::input::PlatformInputTextSessionBegin(121u));
    CHECK(HasTextSession(Drain(observer), AMCL_INPUT_TEXT_SESSION_STARTED, 121u));
    const uint64_t epochBefore = amcl::input::PlatformInputResetEpoch();
    const uint64_t recoveredBefore = Recovered();
    amcl::input::PlatformInputRequestReset(AMCL_INPUT_RESET_EXPLICIT);
    amcl::input::PlatformInputCompleteResetBoundary();
    CHECK(HasReset(Drain(observer)));
    CHECK(amcl::input::PlatformInputResetEpoch() == epochBefore + 2u);
    CHECK(amcl::input::PlatformInputTextSessionBegin(122u));
    CHECK(Recovered() == recoveredBefore);
    CHECK(HasTextSession(Drain(observer), AMCL_INPUT_TEXT_SESSION_STARTED, 122u));
    CloseObserver(observer);
    amcl::input::PlatformInputSurfaceDestroyed(publication);
    std::cout << "T2 latched cancel -> core reset, no orphan: PASS\n";
}

// T2b：core 残留一个 ingress 从未建立的会话（孤儿）。BEGIN 得到 SESSION 且 epoch 未变：
// 中止孤儿后同一次调用内重试成功；不推进前端 epoch，不计 epoch 恢复。
void TestBeginRepairsOrphan() {
    const uint64_t publication = StartSession();
    AmclInputConsumerHandle observer = 0u;
    CHECK(gApi->openConsumer(&observer) == AMCL_INPUT_OK);
    (void)Drain(observer);
    SubmitExternalTextSession(131u, AMCL_INPUT_TEXT_SESSION_STARTED);
    const uint64_t epochBefore = amcl::input::PlatformInputResetEpoch();
    const uint64_t recoveredBefore = Recovered();
    CHECK(amcl::input::PlatformInputTextSessionBegin(132u));
    CHECK(amcl::input::PlatformInputResetEpoch() == epochBefore);
    CHECK(Recovered() == recoveredBefore);
    const auto events = Drain(observer);
    CHECK(HasTextSession(events, AMCL_INPUT_TEXT_SESSION_ABORTED, 131u));
    CHECK(HasTextSession(events, AMCL_INPUT_TEXT_SESSION_STARTED, 132u));
    CHECK(Commit(132u, 'd'));
    CloseObserver(observer);
    amcl::input::PlatformInputSurfaceDestroyed(publication);
    std::cout << "T2b begin aborts orphan and retries once: PASS\n";
}

// T3：外部焦点翻转让 ingress 的焦点 epoch 过期 → 真实 epoch 恢复。会话与 surface
// epoch 未变，恢复不得让 surface 绑定失效：随后的 BEGIN 无需 XComponent 回调即成功。
void TestRecoveryKeepsUnchangedSurfaceBinding() {
    const uint64_t publication = StartSession();
    CHECK(amcl::input::PlatformInputTextSessionBegin(141u));
    const AmclInputSnapshotV1 before = Snapshot();
    CHECK(gApi->publishFocus(0u) == AMCL_INPUT_OK);
    CHECK(gApi->publishFocus(1u) == AMCL_INPUT_OK);
    const uint64_t epochBefore = amcl::input::PlatformInputResetEpoch();
    const auto domainsBefore = amcl::input::PlatformInputResetDomains();
    const uint64_t recoveredBefore = Recovered();
    CHECK(!Commit(141u, 'e'));
    CHECK(Recovered() == recoveredBefore + 1u);
    // 真正focus复位只确认一次；维护消费者重新握手重放同一authorityEpoch，不再虚增边界。
    CHECK(amcl::input::PlatformInputResetEpoch() == epochBefore + 1u);
    const auto domainsAfter = amcl::input::PlatformInputResetDomains();
    CHECK(domainsAfter.touch == domainsBefore.touch && domainsAfter.gamepad == domainsBefore.gamepad);
    CHECK(domainsAfter.text == domainsBefore.text + 1u);
    CHECK(domainsAfter.physical == domainsBefore.physical + (AMCL_TEXT_MIRROR_VARIANT == 3 ? 1u : 0u));
    const AmclInputSnapshotV1 after = Snapshot();
    CHECK(after.sessionEpoch == before.sessionEpoch);
    CHECK(after.surfaceEpoch == before.surfaceEpoch);
    CHECK(after.focusEpoch != before.focusEpoch);
    CHECK(amcl::input::PlatformInputTextSessionBegin(142u));
    CHECK(Commit(142u, 'f'));
    amcl::input::PlatformInputSurfaceDestroyed(publication);
    std::cout << "T3 recovery keeps unchanged surface binding: PASS\n";
}

// T3b：恢复的新基线里仍有一个活动会话（ArkTS 已不再持有）。恢复必须在 core 中止它，
// 而且中止本身不再推进前端 epoch（仍只有“排空 RESET + 恢复”两次）。
void TestRecoveryAbortsSurvivingSession() {
    const uint64_t publication = StartSession();
    AmclInputConsumerHandle observer = 0u;
    CHECK(gApi->openConsumer(&observer) == AMCL_INPUT_OK);
    (void)Drain(observer);
    CHECK(amcl::input::PlatformInputTextSessionBegin(151u));
    CHECK(gApi->publishFocus(0u) == AMCL_INPUT_OK);
    CHECK(gApi->publishFocus(1u) == AMCL_INPUT_OK);
    SubmitExternalTextSession(152u, AMCL_INPUT_TEXT_SESSION_STARTED);
    (void)Drain(observer);
    const uint64_t epochBefore = amcl::input::PlatformInputResetEpoch();
    const uint64_t recoveredBefore = Recovered();
    CHECK(!Commit(151u, 'g'));
    CHECK(Recovered() == recoveredBefore + 1u);
    CHECK(amcl::input::PlatformInputResetEpoch() == epochBefore + 2u);
    CHECK(HasTextSession(Drain(observer), AMCL_INPUT_TEXT_SESSION_ABORTED, 152u));
    CHECK(amcl::input::PlatformInputTextSessionBegin(153u));
    CHECK(Commit(153u, 'h'));
    CloseObserver(observer);
    amcl::input::PlatformInputSurfaceDestroyed(publication);
    std::cout << "T3b recovery aborts surviving session without extra epoch: PASS\n";
}

struct Scenario {
    const char* name;
    void (*run)();
};
const Scenario kScenarios[] = {
    {"t1", TestRetireThenCommitIsOwnerMismatch},
    {"t1b", TestSilentLossAdvancesEpochOnce},
    {"t2", TestLatchedCancelLeavesNoOrphan},
    {"t2b", TestBeginRepairsOrphan},
    {"t3", TestRecoveryKeepsUnchangedSurfaceBinding},
    {"t3b", TestRecoveryAbortsSurvivingSession},
};
}  // namespace

// 无参数时按顺序跑全部场景（CTest 的用法）；给出场景名时只跑那一个，
// 便于对照编译到修复前的 ingress 上逐项确认每个场景都会失败。
int main(int argc, char** argv) {
    SelectVariant();
    gApi = amclInputGetHostApiV1();
    CHECK(amcl::input::PlatformInputTextSessionSupported());
    CHECK(amcl::input::PlatformInputPhysicalRouteUsesTyped() ==
          (AMCL_TEXT_MIRROR_VARIANT == 3));
    CHECK(amcl::input::PlatformInputShadowEnabled() ==
          (AMCL_TEXT_MIRROR_VARIANT == 1));
    const std::string only = argc > 1 ? argv[1] : "";
    bool ran = false;
    for (const Scenario& scenario : kScenarios) {
        if (!only.empty() && only != scenario.name) continue;
        scenario.run();
        ran = true;
    }
    CHECK(ran);
    std::cout << "platform_input_text_mirror_test variant="
              << AMCL_TEXT_MIRROR_VARIANT << " passed\n";
    return 0;
}
