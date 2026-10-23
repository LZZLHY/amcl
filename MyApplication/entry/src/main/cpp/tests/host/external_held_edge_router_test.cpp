// external_held_edge_router_test.cpp — NAPI 按端入口返回值契约（计划 §127）
//
// 直接链接产品 TU：external_held_edge_router.cpp + external_held_registry.cpp + input_ledger.cpp。
// touch_input.cpp 的 routerKey / routerMouse 交给 ArkTS 的 bool 就是
// ExternalHeldEdgeApplied(Route(...))，所以这里对 Route 结果的断言就是对 NAPI 返回值的断言；
// 复位围栏、bridge 就绪与 GLFW 动作码映射留在 touch_input.cpp，不在本测试范围。
//
// 被钉住的故障：旧实现把“是否发出最终聚合边沿”当作返回值。另一端已按住同一输出时，本端 PRESS
// 已登记却返回 false，ArkTS 不记按下态、松手也就不发 RELEASE ⇒ native 留下幽灵 owner，键在 MC
// 侧卡住；本端 RELEASE 已摘除却返回 false ⇒ ArkTS 保留按下态反复重试且每次被拒，该键在本端失灵。
// 负对照用旧判据（结果 == AppliedEmitted）驱动同一组 ArkTS 消费者模型，必须复现这两种泄漏。
#include "external_held_edge_router.h"
#include "external_held_registry.h"
#include "input_ledger.h"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
#include <mutex>
#include <vector>

namespace {

int g_failures = 0;

void Check(bool ok, const char* what, int line) {
    if (ok) return;
    std::fprintf(stderr, "FAIL line %d: %s\n", line, what);
    ++g_failures;
}

#define CHECK(expr) Check((expr), #expr, __LINE__)

using amcl::input::ExternalHeldAction;
using amcl::input::ExternalHeldEdgeApplied;
using amcl::input::ExternalHeldEdgeResult;
using amcl::input::ExternalHeldEdgeRouter;
using amcl::input::ExternalHeldRegistry;
using amcl::input::InputLedger;
using amcl::input::Output;
using amcl::input::OutputKind;
using amcl::input::OwnerToken;

constexpr Output kW{OutputKind::Key, 87};
constexpr Output kSpace{OutputKind::Key, 32};
constexpr Output kDigit1{OutputKind::Key, 49};
constexpr Output kLeftButton{OutputKind::Mouse, 0};

constexpr AmclInputSource kTouch = AMCL_INPUT_SOURCE_TOUCH_CONTROLS;
constexpr AmclInputSource kPad = AMCL_INPUT_SOURCE_GAMEPAD;
// 越界端身份取 COUNT 本身：仍在枚举的取值范围内（避免越界强转的未定义行为），但不是合法端。
constexpr AmclInputSource kBogusSource =
    static_cast<AmclInputSource>(AMCL_INPUT_SOURCE_COUNT);

// ledger emit 回调的动作码与 GLFW 一致：0 = RELEASE，1 = PRESS，2 = REPEAT。
constexpr int kEmitRelease = 0;
constexpr int kEmitPress = 1;
constexpr int kEmitRepeat = 2;

constexpr ExternalHeldEdgeResult kRejected = ExternalHeldEdgeResult::Rejected;
constexpr ExternalHeldEdgeResult kNoFinalEdge = ExternalHeldEdgeResult::AppliedNoFinalEdge;
constexpr ExternalHeldEdgeResult kEmitted = ExternalHeldEdgeResult::AppliedEmitted;

// NAPI 判据本身：只有 Rejected 报 false。编译期钉住，改动枚举或判据时直接编译失败。
static_assert(!ExternalHeldEdgeApplied(ExternalHeldEdgeResult::Rejected), "rejected");
static_assert(ExternalHeldEdgeApplied(ExternalHeldEdgeResult::AppliedNoFinalEdge), "shared");
static_assert(ExternalHeldEdgeApplied(ExternalHeldEdgeResult::AppliedEmitted), "emitted");

struct Edge {
    Output output{OutputKind::Key, 0};
    int action = -1;
};

bool SameOutput(const Output& a, const Output& b) {
    return !(a < b) && !(b < a);
}

// 与产品同构的夹具：一张 registry、一把 registry 锁、一本 ledger（emit 记进 edges），
// router 只借用三者。owner 与产品一样取自全局单调序列、从不复用。
// 成员声明顺序即构造顺序：edges 先于 ledger（emit 回调写它），router 最后。
class Fixture final {
public:
    Fixture()
        : ledger([this](const Output& output, int action) {
              edges.push_back(Edge{output, action});
          }),
          router(registry, registryMutex, ledger) {}

    ExternalHeldEdgeResult Press(AmclInputSource source, const Output& output) {
        return router.Route(source, output, ExternalHeldAction::Press, ++nextOwner);
    }
    ExternalHeldEdgeResult Repeat(AmclInputSource source, const Output& output) {
        return router.Route(source, output, ExternalHeldAction::Repeat, 0);
    }
    ExternalHeldEdgeResult Release(AmclInputSource source, const Output& output) {
        return router.Route(source, output, ExternalHeldAction::Release, 0);
    }

    // MC 侧该输出现在是否按下：按顺序重放全部边沿，与 GLFW 的键状态语义一致。
    bool PressedInBackend(const Output& output) const {
        bool pressed = false;
        for (const Edge& edge : edges) {
            if (!SameOutput(edge.output, output)) continue;
            if (edge.action == kEmitPress) pressed = true;
            if (edge.action == kEmitRelease) pressed = false;
        }
        return pressed;
    }

    std::size_t CountEdges(const Output& output, int action) const {
        std::size_t count = 0u;
        for (const Edge& edge : edges) {
            if (SameOutput(edge.output, output) && edge.action == action) ++count;
        }
        return count;
    }

    std::vector<Edge> edges;
    ExternalHeldRegistry registry;
    std::mutex registryMutex;
    InputLedger ledger;
    ExternalHeldEdgeRouter router;
    OwnerToken nextOwner = 0x400000000ull;
};

// “拒绝路径什么都没改”的判据：两本账的全部可观测量，加上已发出的边沿条数。
struct Snapshot {
    std::size_t liveTotal = 0u;
    std::uint32_t acquired[AMCL_INPUT_SOURCE_COUNT] = {};
    std::uint32_t released[AMCL_INPUT_SOURCE_COUNT] = {};
    std::size_t ledgerOwners = 0u;
    std::size_t ledgerOutputs = 0u;
    std::size_t edges = 0u;
};

Snapshot TakeSnapshot(const Fixture& f) {
    Snapshot s;
    s.liveTotal = f.registry.LiveTotal();
    for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) {
        const AmclInputSource source = static_cast<AmclInputSource>(i);
        s.acquired[i] = f.registry.AcquiredForSource(source);
        s.released[i] = f.registry.ReleasedForSource(source);
    }
    s.ledgerOwners = f.ledger.ownerCount();
    s.ledgerOutputs = f.ledger.outputCount();
    s.edges = f.edges.size();
    return s;
}

bool SameSnapshot(const Snapshot& a, const Snapshot& b) {
    for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) {
        if (a.acquired[i] != b.acquired[i] || a.released[i] != b.released[i]) return false;
    }
    return a.liveTotal == b.liveTotal && a.ledgerOwners == b.ledgerOwners &&
           a.ledgerOutputs == b.ledgerOutputs && a.edges == b.edges;
}

// 单端独占：PRESS / REPEAT / RELEASE 都是“已生效且发出最终边沿”，MC 收到完整三条。
void TestSoleOwnerTransitionsAreEmitted() {
    Fixture f;
    CHECK(f.Press(kPad, kSpace) == kEmitted);
    CHECK(f.Repeat(kPad, kSpace) == kEmitted);
    CHECK(f.Release(kPad, kSpace) == kEmitted);
    CHECK(f.edges.size() == 3u);
    CHECK(f.CountEdges(kSpace, kEmitPress) == 1u);
    CHECK(f.CountEdges(kSpace, kEmitRepeat) == 1u);
    CHECK(f.CountEdges(kSpace, kEmitRelease) == 1u);
    CHECK(f.registry.LiveTotal() == 0u);
    CHECK(f.ledger.ownerCount() == 0u);
    CHECK(f.ledger.outputCount() == 0u);
}

// 缺陷本体（§127）：另一端已按住同一输出时，本端 PRESS / RELEASE 都已生效，只是不发最终边沿。
// 两种按下顺序 × 两种松手顺序都要成立：MC 只见一对边沿，分别落在首个 PRESS 与末个 RELEASE。
void TestCrossSourceSharingAppliesEveryTransition() {
    const AmclInputSource orders[2][2] = {{kTouch, kPad}, {kPad, kTouch}};
    for (const auto& order : orders) {
        for (int variant = 0; variant < 2; ++variant) {
            Fixture f;
            const AmclInputSource early = order[0];
            const AmclInputSource late = order[1];
            const AmclInputSource releasedFirst = variant == 0 ? early : late;
            const AmclInputSource releasedLast = variant == 0 ? late : early;

            CHECK(f.Press(early, kW) == kEmitted);
            const ExternalHeldEdgeResult shared = f.Press(late, kW);
            CHECK(shared == kNoFinalEdge);
            CHECK(ExternalHeldEdgeApplied(shared));   // NAPI 返回 true：ArkTS 应记下按下态
            CHECK(f.registry.LiveCountForSource(late) == 1u);
            CHECK(f.ledger.ownerCount() == 2u);
            CHECK(f.CountEdges(kW, kEmitPress) == 1u);

            const ExternalHeldEdgeResult partial = f.Release(releasedFirst, kW);
            CHECK(partial == kNoFinalEdge);
            CHECK(ExternalHeldEdgeApplied(partial));  // 记录已摘除：ArkTS 应清掉按下态
            CHECK(f.registry.LiveCountForSource(releasedFirst) == 0u);
            CHECK(f.PressedInBackend(kW));             // 另一端仍按着 ⇒ MC 仍按下

            CHECK(f.Release(releasedLast, kW) == kEmitted);
            CHECK(!f.PressedInBackend(kW));
            CHECK(f.edges.size() == 2u);
            CHECK(f.CountEdges(kW, kEmitRelease) == 1u);
            CHECK(f.registry.LiveTotal() == 0u);
            CHECK(f.ledger.ownerCount() == 0u);
        }
    }
}

// 同一端两个控件映射同一个键（例如两个触控按钮都是空格）：第二次 PRESS 同样已生效，
// 两次 RELEASE 按 LIFO 摘除，只有最后一次发 RELEASE。
void TestSameSourceSecondPressIsApplied() {
    Fixture f;
    CHECK(f.Press(kTouch, kSpace) == kEmitted);
    CHECK(f.Press(kTouch, kSpace) == kNoFinalEdge);
    CHECK(f.registry.MaxRecordsForSameSource() == 2u);
    CHECK(f.Release(kTouch, kSpace) == kNoFinalEdge);
    CHECK(f.PressedInBackend(kSpace));
    CHECK(f.Release(kTouch, kSpace) == kEmitted);
    CHECK(!f.PressedInBackend(kSpace));
    CHECK(f.CountEdges(kSpace, kEmitPress) == 1u);
    CHECK(f.CountEdges(kSpace, kEmitRelease) == 1u);
}

// REPEAT 只认同端记录：别端按着同一个键不能让本端的 REPEAT 生效；两端都持有时各自的
// REPEAT 都送出（ledger 对有效 owner 的重复一律转发），且 REPEAT 不消费记录。
void TestRepeatNeedsSameSourceRecord() {
    Fixture f;
    CHECK(f.Press(kTouch, kSpace) == kEmitted);
    CHECK(f.Repeat(kPad, kSpace) == kRejected);
    CHECK(f.CountEdges(kSpace, kEmitRepeat) == 0u);
    CHECK(f.Press(kPad, kSpace) == kNoFinalEdge);
    CHECK(f.Repeat(kPad, kSpace) == kEmitted);
    CHECK(f.Repeat(kTouch, kSpace) == kEmitted);
    CHECK(f.CountEdges(kSpace, kEmitRepeat) == 2u);
    CHECK(f.registry.LiveTotal() == 2u);
}

// 返回 false 的每一条路径都不得改变任何记录，否则 ArkTS 按“被拒、保留状态”处理之后，
// native 与 ArkTS 会重新分叉 —— 那正是本次要消除的幽灵 owner / 失灵键。
void TestRejectedRequestsChangeNothing() {
    Fixture f;
    CHECK(f.Press(kTouch, kW) == kEmitted);
    const Snapshot before = TakeSnapshot(f);

    // 无配对的 RELEASE / REPEAT：手柄端从未按下 W，触控端从未按下空格。
    CHECK(f.Release(kPad, kW) == kRejected);
    CHECK(f.Repeat(kPad, kW) == kRejected);
    CHECK(f.Release(kTouch, kSpace) == kRejected);
    // 非法 owner 与越界端身份：registry 拒绝，ledger 完全不被触碰。
    CHECK(f.router.Route(kPad, kW, ExternalHeldAction::Press, 0) == kRejected);
    CHECK(f.router.Route(kBogusSource, kW, ExternalHeldAction::Press, 0x999u) == kRejected);
    CHECK(f.router.Route(kBogusSource, kW, ExternalHeldAction::Release, 0) == kRejected);
    // 枚举之外的动作值只可能来自错误的强制转换，同样按“未改变任何记录”处理。
    CHECK(f.router.Route(kTouch, kW, static_cast<ExternalHeldAction>(7), 0x998u) ==
          kRejected);

    CHECK(SameSnapshot(before, TakeSnapshot(f)));
    CHECK(f.PressedInBackend(kW));
    // 触控端自己的记录完好：它仍能正常抬起。
    CHECK(f.Release(kTouch, kW) == kEmitted);
}

// ledger 拒绝 PRESS 时的精确回滚。产品里 owner 取自全局单调序列、从不复用，“ledger 已认该 owner
// 持有此输出”结构上不可达；这里人为制造它，验证返回 Rejected 时 registry 里没有残留记录。
void TestPressRollsBackWhenLedgerRejects() {
    Fixture f;
    const OwnerToken reused = 0x77u;
    CHECK(f.ledger.acquire(reused, kW));
    const std::size_t edgesBefore = f.edges.size();

    const ExternalHeldEdgeResult result =
        f.router.Route(kPad, kW, ExternalHeldAction::Press, reused);
    CHECK(result == kRejected);
    CHECK(!ExternalHeldEdgeApplied(result));
    CHECK(f.registry.LiveTotal() == 0u);
    // 回滚计入 released：acquired - released == live 在该端保持成立。
    CHECK(f.registry.AcquiredForSource(kPad) == 1u);
    CHECK(f.registry.ReleasedForSource(kPad) == 1u);
    CHECK(f.edges.size() == edgesBefore);
    // ledger 侧原有的持有不受影响。
    CHECK(f.ledger.owns(reused, kW));
    CHECK(f.ledger.ownerCount() == 1u);
    // 回滚后该端没有可配对的记录：随后的 RELEASE 必须被拒，不能去释放 ledger 里那个 owner。
    CHECK(f.Release(kPad, kW) == kRejected);
    CHECK(f.ledger.owns(reused, kW));
}

// registry 记录还在、ledger 已先行放掉该 owner（它当时已向 MC 发过 RELEASE）：本端 RELEASE
// 摘除记录即算生效，不补发第二条 RELEASE；若报 false，ArkTS 会拿着一条已不存在的记录无限重试。
void TestReleaseAfterLedgerDroppedOwnerIsApplied() {
    Fixture f;
    CHECK(f.Press(kPad, kW) == kEmitted);
    f.ledger.releaseAll();
    CHECK(!f.PressedInBackend(kW));
    const std::size_t edgesBefore = f.edges.size();

    const ExternalHeldEdgeResult result = f.Release(kPad, kW);
    CHECK(result == kNoFinalEdge);
    CHECK(ExternalHeldEdgeApplied(result));
    CHECK(f.edges.size() == edgesBefore);
    CHECK(f.registry.LiveTotal() == 0u);
    CHECK(f.Release(kPad, kW) == kRejected);
}

// 鼠标按钮是独立的 Output 域，契约与键相同；同编码的键 0 不受影响。
void TestMouseButtonSharesTheSameContract() {
    Fixture f;
    const Output key0{OutputKind::Key, 0};
    CHECK(f.Press(kTouch, kLeftButton) == kEmitted);
    CHECK(f.Press(kPad, kLeftButton) == kNoFinalEdge);
    CHECK(f.Release(kTouch, kLeftButton) == kNoFinalEdge);
    CHECK(f.PressedInBackend(kLeftButton));
    CHECK(f.Release(kPad, kLeftButton) == kEmitted);
    CHECK(!f.PressedInBackend(kLeftButton));
    CHECK(f.CountEdges(kLeftButton, kEmitPress) == 1u);
    CHECK(f.CountEdges(kLeftButton, kEmitRelease) == 1u);
    CHECK(f.CountEdges(key0, kEmitPress) == 0u);
    CHECK(f.CountEdges(key0, kEmitRelease) == 0u);
}

// ---------------------------------------------------------------------------
// ArkTS 消费者模型。下面三种写法逐条对应现有调用方对返回值的处理方式；它们是模型而非
// ArkTS 源码本身，被测的仍是产品 Route 在这些调用序列下留下的账目与边沿。
// ---------------------------------------------------------------------------

// ArkTS 如何解读 NAPI 返回值。AcceptApplied 是修复后 routerKey 的返回；
// AcceptEmittedOnly 是修复前的返回（只有发出最终边沿才报 true），只用于负对照。
using AcceptFn = bool (*)(ExternalHeldEdgeResult);
bool AcceptApplied(ExternalHeldEdgeResult result) { return ExternalHeldEdgeApplied(result); }
bool AcceptEmittedOnly(ExternalHeldEdgeResult result) { return result == kEmitted; }

// 持有型：对应 GameControls 摇杆的 activeKeys、GamepadManager.applyMoveKey 与按钮路径的
// setControlContributor —— 想按且未记 → 发 PRESS，被接受才记下；想松且已记 → 发 RELEASE，
// 被接受才删除，否则保留以便重试。连续采样时每个样本都重跑一次（摇杆），按钮只跑一次。
class HeldKeyConsumer final {
public:
    HeldKeyConsumer(Fixture& fixture, AmclInputSource source, AcceptFn accept)
        : fixture_(fixture), source_(source), accept_(accept) {}

    void Sample(const Output& output, bool want) {
        if (want && !held_) {
            if (accept_(fixture_.Press(source_, output))) held_ = true;
        } else if (!want && held_) {
            if (accept_(fixture_.Release(source_, output))) held_ = false;
        }
    }

    bool held() const { return held_; }

private:
    Fixture& fixture_;
    AmclInputSource source_;
    AcceptFn accept_;
    bool held_ = false;
};

struct SharedKeyOutcome {
    bool firstHeld = false;       // 先按那一端的 ArkTS 最终是否仍认为按着
    bool secondHeld = false;
    bool backendPressed = false;  // MC 侧最终是否仍按下
    std::size_t firstRecords = 0u;
    std::size_t secondRecords = 0u;
    std::size_t maxStack = 0u;    // 全程观察到的同端最大堆叠
    std::size_t pressEdges = 0u;
    std::size_t releaseEdges = 0u;
};

// 跨端同键时序：first 按下 → second 按下 → first 松开 → second 松开，每个阶段连续 samples 个
// 输入样本（1 = 按钮事件，3 = 摇杆连续采样）。
SharedKeyOutcome RunSharedKeyScenario(AcceptFn accept, AmclInputSource firstSource,
                                      AmclInputSource secondSource, int samples) {
    Fixture f;
    HeldKeyConsumer first(f, firstSource, accept);
    HeldKeyConsumer second(f, secondSource, accept);
    SharedKeyOutcome out;
    const auto phase = [&](HeldKeyConsumer& who, bool want) {
        for (int i = 0; i < samples; ++i) {
            who.Sample(kW, want);
            const std::size_t stack = f.registry.MaxRecordsForSameSource();
            if (stack > out.maxStack) out.maxStack = stack;
        }
    };
    phase(first, true);
    phase(second, true);
    phase(first, false);
    phase(second, false);
    out.firstHeld = first.held();
    out.secondHeld = second.held();
    out.backendPressed = f.PressedInBackend(kW);
    out.firstRecords = f.registry.LiveCountForSource(firstSource);
    out.secondRecords = f.registry.LiveCountForSource(secondSource);
    out.pressEdges = f.CountEdges(kW, kEmitPress);
    out.releaseEdges = f.CountEdges(kW, kEmitRelease);
    return out;
}

// 修复后：两端 ArkTS 状态与 native 记录始终一致，MC 收到恰好一对边沿，无任何残留。
void TestSharedKeyConsumersDoNotLeak() {
    const AmclInputSource orders[2][2] = {{kTouch, kPad}, {kPad, kTouch}};
    for (int samples : {1, 3}) {
        for (const auto& order : orders) {
            const SharedKeyOutcome out =
                RunSharedKeyScenario(AcceptApplied, order[0], order[1], samples);
            CHECK(!out.firstHeld);
            CHECK(!out.secondHeld);
            CHECK(!out.backendPressed);
            CHECK(out.firstRecords == 0u);
            CHECK(out.secondRecords == 0u);
            CHECK(out.maxStack == 1u);
            CHECK(out.pressEdges == 1u);
            CHECK(out.releaseEdges == 1u);
        }
    }
}

// 负对照：同一时序、同一产品 Route，只把判据换回“是否发出最终边沿”，泄漏必须复现。
// 若这个用例不再失败于旧判据，说明夹具或模型已经测不到 §127 的缺陷，正向用例也就失去意义。
void TestEmittedOnlyContractReproducesLeak() {
    for (int samples : {1, 3}) {
        const SharedKeyOutcome out =
            RunSharedKeyScenario(AcceptEmittedOnly, kTouch, kPad, samples);
        // 后按的一端：每个样本的 PRESS 都已登记却被判为拒绝 ⇒ 留下 samples 条幽灵 owner。
        // samples == 1 时没有同端堆叠（maxStack == 1），MaxRecordsForSameSource 看不到它。
        CHECK(!out.secondHeld);
        CHECK(out.secondRecords == static_cast<std::size_t>(samples));
        CHECK(out.maxStack == static_cast<std::size_t>(samples));
        // 先按的一端：RELEASE 已摘除记录却被判为拒绝，之后每次重试都无配对 ⇒ 该端在此键上失灵。
        CHECK(out.firstHeld);
        CHECK(out.firstRecords == 0u);
        // MC 侧恒为按下：一条 RELEASE 都没有发出。
        CHECK(out.backendPressed);
        CHECK(out.pressEdges == 1u);
        CHECK(out.releaseEdges == 0u);
    }
}

// 点按型：对应 GameControls.sendHotbarSlot —— PRESS 被判为拒绝就直接返回、不发 RELEASE；
// RELEASE 被判为拒绝才请求按端强制释放。返回值 = 是否请求了强制释放。
bool HotbarTap(Fixture& f, AmclInputSource source, const Output& output, AcceptFn accept) {
    if (!accept(f.Press(source, output))) return false;
    return !accept(f.Release(source, output));
}

void TestHotbarTapWhileOtherSourceHoldsKey() {
    {
        // 修复后：手柄按住映射到快捷栏 1 的键时，触控点按快捷栏 1 既不触发强制释放、也不留记录。
        Fixture f;
        CHECK(f.Press(kPad, kDigit1) == kEmitted);
        CHECK(!HotbarTap(f, kTouch, kDigit1, AcceptApplied));
        CHECK(f.registry.LiveCountForSource(kTouch) == 0u);
        CHECK(f.Release(kPad, kDigit1) == kEmitted);
        CHECK(!f.PressedInBackend(kDigit1));
    }
    {
        // 负对照：旧判据把已登记的 PRESS 当成拒绝，点按提前返回，触控端记录成了幽灵 owner，
        // 手柄松手也放不掉该键。
        Fixture f;
        CHECK(f.Press(kPad, kDigit1) == kEmitted);
        CHECK(!HotbarTap(f, kTouch, kDigit1, AcceptEmittedOnly));
        CHECK(f.registry.LiveCountForSource(kTouch) == 1u);
        CHECK(f.Release(kPad, kDigit1) == kNoFinalEdge);
        CHECK(f.PressedInBackend(kDigit1));
    }
}

// 同端/同输出的两个控件必须保留独立身份。旧 LIFO 出口不能偷走租约，旧 token 在
// 复位后迟到也不能撤销同名控件的新租约；绑定在按下时冻结，释放不读新映射。
void TestControlLeasesKeepIdentityAndGeneration() {
    Fixture f;
    const amcl::input::ExternalControlIdentity a{kTouch, 7u, "client:1:A"};
    const amcl::input::ExternalControlIdentity b{kTouch, 8u, "client:1:A"};
    const auto first = f.router.AcquireControl(a, {kW, kLeftButton}, ++f.nextOwner);
    const auto second = f.router.AcquireControl(b, {kW}, ++f.nextOwner);
    CHECK(first != 0u && second != 0u && first != second);
    CHECK(f.router.AcquireControl(a, {kW, kLeftButton}, ++f.nextOwner) == first);
    CHECK(f.router.AcquireControl(a, {kSpace}, ++f.nextOwner) == 0u);
    CHECK(f.Release(kTouch, kW) == kRejected);
    CHECK(f.router.ReleaseControl(first));
    CHECK(f.PressedInBackend(kW) && !f.PressedInBackend(kLeftButton));
    CHECK(f.CountEdges(kW, kEmitPress) == 1u);
    f.registry.Clear(); f.ledger.releaseAll();
    const auto replacement = f.router.AcquireControl(b, {kW}, ++f.nextOwner);
    CHECK(replacement != second && f.router.ReleaseControl(second));
    CHECK(f.ledger.owns(replacement, kW));
    CHECK(f.router.ReleaseControl(replacement));
    CHECK(f.registry.LiveTotal() == 0u && f.ledger.ownerCount() == 0u);
    CHECK(f.registry.AcquiredForSource(kTouch) == f.registry.ReleasedForSource(kTouch));
}

void TestControlLeaseResetDuringFirstChordEdge() {
    ExternalHeldRegistry registry;
    std::mutex mutex;
    InputLedger* current = nullptr;
    unsigned presses = 0u;
    InputLedger ledger([&](const Output&, int action) {
        if (action == kEmitPress && ++presses == 1u) {
            // 模拟 emit 同步触发生命周期撤销，余下组合键不能在复位之后继续按下。
            registry.Clear(); current->releaseAll();
        }
    });
    current = &ledger;
    ExternalHeldEdgeRouter router(registry, mutex, ledger);
    CHECK(router.AcquireControl({kPad, 1u, "reset-in-emit"}, {kW, kSpace}, 99u) == 0u);
    CHECK(presses == 1u && registry.LiveTotal() == 0u && ledger.ownerCount() == 0u);
}

}  // namespace

int main() {
    TestControlLeasesKeepIdentityAndGeneration();
    TestControlLeaseResetDuringFirstChordEdge();
    TestSoleOwnerTransitionsAreEmitted();
    TestCrossSourceSharingAppliesEveryTransition();
    TestSameSourceSecondPressIsApplied();
    TestRepeatNeedsSameSourceRecord();
    TestRejectedRequestsChangeNothing();
    TestPressRollsBackWhenLedgerRejects();
    TestReleaseAfterLedgerDroppedOwnerIsApplied();
    TestMouseButtonSharesTheSameContract();
    TestSharedKeyConsumersDoNotLeak();
    TestEmittedOnlyContractReproducesLeak();
    TestHotbarTapWhileOtherSourceHoldsKey();
    if (g_failures != 0) {
        std::fprintf(stderr, "external_held_edge_router_test: %d failure(s)\n", g_failures);
        return EXIT_FAILURE;
    }
    std::printf("external_held_edge_router_test: all checks passed\n");
    return EXIT_SUCCESS;
}
