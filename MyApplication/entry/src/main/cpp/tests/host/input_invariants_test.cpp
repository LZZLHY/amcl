// input_invariants_test.cpp
//
// 被测对象是**告警系统本身**。它坏掉有两种方式，两种都很危险：
//   · 漏报 —— 账目已经失衡而它说没事，等于没有这套机制；
//   · 误报 —— 稳态下持续刷 error，下一轮判读会直接把 AMCL_INVARIANT 当噪声忽略掉，
//     而这个项目已经因为"计数器不可信"损失过整轮时间。
// 所以两个方向都要测：健康快照必须干净通过，每一条不变量都要能被单独触发。
#include "input_invariants.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

int g_failures = 0;

void Check(bool ok, const char* what, int line) {
    if (ok) return;
    std::fprintf(stderr, "FAIL line %d: %s\n", line, what);
    ++g_failures;
}

#define CHECK(expr) Check((expr), #expr, __LINE__)

constexpr int kTouch = (int)AMCL_INPUT_SOURCE_TOUCH_CONTROLS;
constexpr int kPad = (int)AMCL_INPUT_SOURCE_GAMEPAD;
constexpr int kKbm = (int)AMCL_INPUT_SOURCE_PHYSICAL_KBM;
constexpr int kGesture = (int)AMCL_INPUT_SOURCE_PLATFORM_GESTURE;
constexpr int kNone = (int)AMCL_INPUT_SOURCE_NONE;

// 一份"运行了一会儿、一切正常"的快照：三端都有活动，手势端只有按键（无 look/scroll），
// 持有账目平衡，untagged 全零。
AmclInputInvariantSnapshot HealthySnapshot() {
    AmclInputInvariantSnapshot s;
    std::memset(&s, 0, sizeof(s));
    s.lookPerSource[kTouch] = 500u;
    s.lookPerSource[kPad] = 120u;
    s.lookPerSource[kKbm] = 3400u;
    s.lookTotal = 500u + 120u + 3400u;
    s.scrollPerSource[kTouch] = 7u;
    s.scrollPerSource[kPad] = 3u;
    s.scrollPerSource[kKbm] = 41u;
    s.scrollTotal = 7u + 3u + 41u;
    // 触控端还按着两个键，手柄按着一个，键鼠端不走这张表。
    s.heldAcquired[kTouch] = 30u;
    s.heldReleased[kTouch] = 28u;
    s.heldLive[kTouch] = 2u;
    s.heldAcquired[kPad] = 11u;
    s.heldReleased[kPad] = 10u;
    s.heldLive[kPad] = 1u;
    // 手势端的 tap 进出成对。
    s.heldAcquired[kGesture] = 4u;
    s.heldReleased[kGesture] = 4u;
    s.heldLive[kGesture] = 0u;
    // ---- 2026-09-01：第 1a 层与第 2 层 ----
    // 上游共 4 个 owner（1b 层 3 条 + 1a 层 1 条物理身份），第 2 层必须至少覆盖它们。
    // 这里刻意让 `ledgerOwnerLive` **大于** 4：schema owner（第 1c 层）也在 ledger 里，
    // 而它不在本快照的可见范围内 —— 这正是新不变量只能是蕴含式、不能是等式的原因。
    s.physicalIdentityLive = 1u;
    s.ledgerOwnerLive = 6u;
    // 组合键让"按下的控件数"可以多于 owner 数（一个 owner 持有多个 output）。
    s.ledgerOutputLive = 8u;
    // 每个 (output, source) 各一条 —— 正常值。>1 是规范 §3.3 的幽灵 owner 特征，
    // 而它刻意不参与任何不变量位。
    s.maxSameSourceHeld = 1u;
    return s;
}

void TestHealthySnapshotIsClean() {
    const AmclInputInvariantSnapshot s = HealthySnapshot();
    CHECK(amcl_input_invariants_evaluate(&s) == 0u);
}

// 全零（刚启动、什么都没发生）必须干净 —— 否则启动瞬间就会刷一行假警报。
void TestZeroSnapshotIsClean() {
    AmclInputInvariantSnapshot s;
    std::memset(&s, 0, sizeof(s));
    CHECK(amcl_input_invariants_evaluate(&s) == 0u);
}

void TestNullSnapshotDoesNotAlarm() {
    // 无法判定时不报警：一个无法定位的警报比不报更糟。
    CHECK(amcl_input_invariants_evaluate(nullptr) == 0u);
}

// 故障模式：某个 look 生产者没申报端身份（例如新增入口时漏了 note_look）。
void TestLookSumMismatchDetected() {
    AmclInputInvariantSnapshot s = HealthySnapshot();
    s.lookTotal += 17u;   // 漏斗被调用了，但没有任何端记账
    const uint32_t broken = amcl_input_invariants_evaluate(&s);
    CHECK((broken & AMCL_INV_LOOK_SUM) != 0u);
    CHECK((broken & AMCL_INV_SCROLL_SUM) == 0u);
    CHECK((broken & AMCL_INV_HELD_BALANCE) == 0u);
}

// 反方向也要抓：端计数多于总数（例如同一次 look 被打了两次端计数）。
void TestLookSumOvercountDetected() {
    AmclInputInvariantSnapshot s = HealthySnapshot();
    s.lookPerSource[kPad] += 5u;
    CHECK((amcl_input_invariants_evaluate(&s) & AMCL_INV_LOOK_SUM) != 0u);
}

// 故障模式：某条滚轮通道绕过了按端入口（native AXIS 曾经就是这样）。
void TestScrollSumMismatchDetected() {
    AmclInputInvariantSnapshot s = HealthySnapshot();
    s.scrollTotal += 9u;
    const uint32_t broken = amcl_input_invariants_evaluate(&s);
    CHECK((broken & AMCL_INV_SCROLL_SUM) != 0u);
    CHECK((broken & AMCL_INV_LOOK_SUM) == 0u);
}

// 故障模式：释放路径漏了记账，或释放拿掉了一条不该拿的记录。
void TestHeldBalanceBrokenDetected() {
    AmclInputInvariantSnapshot s = HealthySnapshot();
    s.heldLive[kTouch] = 5u;   // 表里有 5 条，但账上只该有 2 条
    CHECK((amcl_input_invariants_evaluate(&s) & AMCL_INV_HELD_BALANCE) != 0u);
}

// released > acquired 时无符号相减会回绕成一个巨大的数，同样必须被抓住 ——
// 这条是刻意依赖回绕的，写成有符号比较反而会掩盖它。
void TestHeldReleasedExceedingAcquiredDetected() {
    AmclInputInvariantSnapshot s = HealthySnapshot();
    s.heldAcquired[kPad] = 3u;
    s.heldReleased[kPad] = 5u;
    s.heldLive[kPad] = 0u;
    CHECK((amcl_input_invariants_evaluate(&s) & AMCL_INV_HELD_BALANCE) != 0u);
}

// 任意一端失衡都要报，不能只看第一端。
void TestHeldBalanceCheckedForEverySource() {
    for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) {
        AmclInputInvariantSnapshot s = HealthySnapshot();
        s.heldLive[i] += 1u;
        const uint32_t broken = amcl_input_invariants_evaluate(&s);
        Check((broken & AMCL_INV_HELD_BALANCE) != 0u,
              "held balance must be checked for every source", __LINE__);
    }
}

// 故障模式：有调用点还在用未申报端身份的兼容入口。三条计数任一非零都要报。
void TestUntaggedDetected() {
    {
        AmclInputInvariantSnapshot s = HealthySnapshot();
        s.lookPerSource[kNone] = 1u;
        s.lookTotal += 1u;   // 保持 lookSum 成立，单独暴露 untagged
        const uint32_t broken = amcl_input_invariants_evaluate(&s);
        CHECK((broken & AMCL_INV_NO_UNTAGGED) != 0u);
        CHECK((broken & AMCL_INV_LOOK_SUM) == 0u);
    }
    {
        AmclInputInvariantSnapshot s = HealthySnapshot();
        s.scrollPerSource[kNone] = 2u;
        s.scrollTotal += 2u;
        CHECK((amcl_input_invariants_evaluate(&s) & AMCL_INV_NO_UNTAGGED) != 0u);
    }
    {
        AmclInputInvariantSnapshot s = HealthySnapshot();
        s.heldAcquired[kNone] = 1u;
        s.heldReleased[kNone] = 1u;   // 账目仍平衡，单独暴露 untagged
        const uint32_t broken = amcl_input_invariants_evaluate(&s);
        CHECK((broken & AMCL_INV_NO_UNTAGGED) != 0u);
        CHECK((broken & AMCL_INV_HELD_BALANCE) == 0u);
    }
}

// 平台手势只产生按键 tap，出现在 look 路径上说明端标注错了。
void TestGestureLookDetected() {
    AmclInputInvariantSnapshot s = HealthySnapshot();
    s.lookPerSource[kGesture] = 1u;
    s.lookTotal += 1u;
    const uint32_t broken = amcl_input_invariants_evaluate(&s);
    CHECK((broken & AMCL_INV_GESTURE_NO_LOOK) != 0u);
    CHECK((broken & AMCL_INV_NO_UNTAGGED) == 0u);
}

// 手势端产生 scroll 目前没有生产者，但也没有理由禁止（例如将来把某个系统手势映射成
// 切快捷栏）。这里钉住"现有的五条都不报" —— 刻意**不**断言整个掩码为 0，
// 否则将来新增第六条不变量会让这个用例假失败。
void TestGestureScrollDoesNotTripExistingInvariants() {
    AmclInputInvariantSnapshot s = HealthySnapshot();
    s.scrollPerSource[kGesture] = 3u;
    s.scrollTotal += 3u;
    const uint32_t broken = amcl_input_invariants_evaluate(&s);
    CHECK((broken & AMCL_INV_SCROLL_SUM) == 0u);
    CHECK((broken & AMCL_INV_NO_UNTAGGED) == 0u);
    CHECK((broken & AMCL_INV_GESTURE_NO_LOOK) == 0u);
    CHECK((broken & AMCL_INV_HELD_BALANCE) == 0u);
    CHECK((broken & AMCL_INV_LOOK_SUM) == 0u);
}

// `AMCL_INV_ALL_BITS` 必须与"已命名的位"完全一致。
//
// 这条抓的是一个具体的失效模式：新增一条不变量却忘了更新 ALL_BITS —— 那么求值器会
// 报它，但 `ohos_input_invariant_tick` 的名字拼接循环上界是 ALL_BITS，**新位永远不会
// 出现在日志里**，等于加了一条查不到的警报。反过来，ALL_BITS 里有位却没命名，
// 日志会打出 "?"，同样无法定位。
void TestAllBitsMatchesNamedBits() {
    uint32_t named = 0u;
    for (uint32_t bit = 1u; bit != 0u; bit <<= 1) {
        if (std::strcmp(amcl_input_invariant_name(bit), "?") != 0) named |= bit;
    }
    CHECK(named == AMCL_INV_ALL_BITS);
}

// 多条同时破坏时必须全部上报，不能短路只报第一条。
void TestMultipleBreaksAllReported() {
    AmclInputInvariantSnapshot s = HealthySnapshot();
    s.lookTotal += 1u;
    s.scrollTotal += 1u;
    s.heldLive[kKbm] += 1u;
    const uint32_t broken = amcl_input_invariants_evaluate(&s);
    CHECK((broken & AMCL_INV_LOOK_SUM) != 0u);
    CHECK((broken & AMCL_INV_SCROLL_SUM) != 0u);
    CHECK((broken & AMCL_INV_HELD_BALANCE) != 0u);
    CHECK((broken & ~AMCL_INV_ALL_BITS) == 0u);
}

// ============ 上报滞回 ============
// 这段逻辑决定"到底打不打这行 error"，是整套机制里最该被测的部分。
// 它此前埋在 3700 行的 TU 里，与抽 ExternalHeldRegistry 之前的处境完全一样。

// 单次观测不上报：采样非原子，一次失衡可能只是窗口。
void TestHysteresisRequiresTwoConsecutiveObservations() {
    AmclInputInvariantHysteresis state{0u, 0u};
    CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_LOOK_SUM) == 0u);
    // 第二次仍然观测到 → 确认并上报。
    CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_LOOK_SUM) ==
          AMCL_INV_LOOK_SUM);
}

// 瞬时失衡（下一次自愈）必须完全不上报 —— 这正是滞回存在的理由。
void TestHysteresisSuppressesTransientBreak() {
    AmclInputInvariantHysteresis state{0u, 0u};
    CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_LOOK_SUM) == 0u);
    CHECK(amcl_input_invariants_confirm(&state, 0u) == 0u);
    CHECK(amcl_input_invariants_confirm(&state, 0u) == 0u);
    // 之后又出现一次瞬时的，同样不报。
    CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_SCROLL_SUM) == 0u);
    CHECK(amcl_input_invariants_confirm(&state, 0u) == 0u);
}

// 持续破坏只报一次：它描述的是状态而不是事件，每 tick 刷一行会淹没日志。
void TestHysteresisReportsPersistentBreakOnlyOnce() {
    AmclInputInvariantHysteresis state{0u, 0u};
    CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_HELD_BALANCE) == 0u);
    CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_HELD_BALANCE) ==
          AMCL_INV_HELD_BALANCE);
    for (int i = 0; i < 100; ++i) {
        CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_HELD_BALANCE) == 0u);
    }
}

// A→B→A 交替不得每次都报。旧实现用 `exchange` 比较"与上次是否相同"，
// 这种交替会让它每 tick 都打一行。
void TestHysteresisDoesNotFlapOnAlternatingMasks() {
    AmclInputInvariantHysteresis state{0u, 0u};
    // 先各自确认一次（每条都需要连续两次）。
    CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_LOOK_SUM) == 0u);
    CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_LOOK_SUM) ==
          AMCL_INV_LOOK_SUM);
    CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_SCROLL_SUM) == 0u);
    CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_SCROLL_SUM) ==
          AMCL_INV_SCROLL_SUM);
    // 此后无论怎么交替都不再上报。
    for (int i = 0; i < 20; ++i) {
        CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_LOOK_SUM) == 0u);
        CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_SCROLL_SUM) == 0u);
    }
}

// 新增的破坏位要能在已有破坏之上被单独报出来，不能被"已报过"整体吞掉。
void TestHysteresisReportsNewlyAppearingBits() {
    AmclInputInvariantHysteresis state{0u, 0u};
    CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_LOOK_SUM) == 0u);
    CHECK(amcl_input_invariants_confirm(&state, AMCL_INV_LOOK_SUM) ==
          AMCL_INV_LOOK_SUM);
    // 现在又多了一条，两次观测后只报**新**的那条。
    const uint32_t both = AMCL_INV_LOOK_SUM | AMCL_INV_HELD_BALANCE;
    CHECK(amcl_input_invariants_confirm(&state, both) == 0u);
    CHECK(amcl_input_invariants_confirm(&state, both) == AMCL_INV_HELD_BALANCE);
}

void TestHysteresisNullStateIsSafe() {
    CHECK(amcl_input_invariants_confirm(nullptr, AMCL_INV_LOOK_SUM) == 0u);
}

// 每个位都要有可读名字：日志里出现 "?" 等于这条警报无法定位。
void TestEveryBitHasAName() {
    for (uint32_t bit = 1u; bit <= AMCL_INV_ALL_BITS; bit <<= 1) {
        if ((AMCL_INV_ALL_BITS & bit) == 0u) continue;
        const char* name = amcl_input_invariant_name(bit);
        CHECK(name != nullptr);
        CHECK(std::strcmp(name, "?") != 0);
    }
    CHECK(std::strcmp(amcl_input_invariant_name(1u << 20), "?") == 0);
}
// ---------------------------------------------------------------------------
// AMCL_INV_LEDGER_COVERS_OWNERS（2026-09-01 新增）
//
// 它覆盖的是规范 §二 那张六层表里此前**没有任何自检**的两层：第 1a 层（物理键鼠端唯一的
// 持有账本）与第 2 层（ledger）。下面五条用例分别钉住：两个上游各自都真的参与判定、
// 蕴含式的方向、以及"`maxSameSourceHeld` 刻意不参与任何位"这个**决定**。
// ---------------------------------------------------------------------------

// 第 1b 层还持有而 ledger 已归零 ⇒ 那些键在 MC 侧已经抬起，上游却还认为按着。
void TestLedgerEmptyWhileExternalHeldDetected() {
    AmclInputInvariantSnapshot s = HealthySnapshot();
    s.physicalIdentityLive = 0u;
    s.ledgerOwnerLive = 0u;   // ledger 被清空，而 heldLive 仍有 3 条
    s.ledgerOutputLive = 0u;
    const uint32_t broken = amcl_input_invariants_evaluate(&s);
    CHECK((broken & AMCL_INV_LEDGER_COVERS_OWNERS) != 0u);
    // 持有账目本身仍然自洽 —— 这正是为什么需要**另一条**位：`heldBalance` 抓不到它。
    CHECK((broken & AMCL_INV_HELD_BALANCE) == 0u);
}

// 第 1a 层单独非空也必须被抓 —— 物理键鼠端不走 external 表，若判定只看 heldLive
// 就会对整个物理端失明，而那正是本次补完要消掉的盲区。
void TestLedgerEmptyWhilePhysicalIdentityHeldDetected() {
    AmclInputInvariantSnapshot s;
    std::memset(&s, 0, sizeof(s));
    s.physicalIdentityLive = 2u;   // 两个物理键身份，external 表全空
    s.ledgerOwnerLive = 0u;
    const uint32_t broken = amcl_input_invariants_evaluate(&s);
    CHECK((broken & AMCL_INV_LEDGER_COVERS_OWNERS) != 0u);
    // 其余四条不受影响：这份快照在它们看来完全干净。
    CHECK((broken & ~AMCL_INV_LEDGER_COVERS_OWNERS) == 0u);
}

// 蕴含式的方向：ledger 里的 owner **多于**可见上游是**正常**的（第 1c 层 schema owner
// 不在快照里）。写成等式就会在每一次虚拟按键按下时误报。
void TestLedgerHavingMoreOwnersThanUpstreamIsClean() {
    AmclInputInvariantSnapshot s;
    std::memset(&s, 0, sizeof(s));
    s.physicalIdentityLive = 1u;
    s.ledgerOwnerLive = 99u;   // schema 那一层的 owner 全在这里面
    CHECK(amcl_input_invariants_evaluate(&s) == 0u);
}

// 上游全空时 ledger 非空同样干净（纯 schema 输入：只按屏幕虚拟键）。
void TestLedgerOwnersWithoutUpstreamIsClean() {
    AmclInputInvariantSnapshot s;
    std::memset(&s, 0, sizeof(s));
    s.ledgerOwnerLive = 4u;
    s.ledgerOutputLive = 4u;
    CHECK(amcl_input_invariants_evaluate(&s) == 0u);
}

// ⭐ 把"`maxSameSourceHeld` 刻意不做成告警位"这个**决定**钉成断言。
//
// 它是规范 §3.3 幽灵 owner 的直接特征量，看起来非常适合做成一条不变量 —— 而刻意没做，
// 因为"同一端在同一个 output 上不可能有多于一条"当前只是 B 级判断（三端的 ArkTS 侧各有
// 自己的按下态去重，但没有任何机械手段证明穷举完了），而一个误报过的不变量位会让整套
// 自检失去可信度（本仓已为"计数器不可信比没有计数器更糟"付过学费）。
// 没有这条断言，下一个人"顺手"把它接进求值器时不会有任何东西变红。
void TestMaxSameSourceHeldNeverTripsAnyInvariant() {
    for (unsigned depth = 0u; depth <= 8u; ++depth) {
        AmclInputInvariantSnapshot s = HealthySnapshot();
        s.maxSameSourceHeld = depth;
        Check(amcl_input_invariants_evaluate(&s) == 0u,
              "maxSameSourceHeld must stay observation-only", __LINE__);
    }
}

}  // namespace

int main() {
    TestHealthySnapshotIsClean();
    TestZeroSnapshotIsClean();
    TestNullSnapshotDoesNotAlarm();
    TestLookSumMismatchDetected();
    TestLookSumOvercountDetected();
    TestScrollSumMismatchDetected();
    TestHeldBalanceBrokenDetected();
    TestHeldReleasedExceedingAcquiredDetected();
    TestHeldBalanceCheckedForEverySource();
    TestUntaggedDetected();
    TestGestureLookDetected();
    TestGestureScrollDoesNotTripExistingInvariants();
    TestLedgerEmptyWhileExternalHeldDetected();
    TestLedgerEmptyWhilePhysicalIdentityHeldDetected();
    TestLedgerHavingMoreOwnersThanUpstreamIsClean();
    TestLedgerOwnersWithoutUpstreamIsClean();
    TestMaxSameSourceHeldNeverTripsAnyInvariant();
    TestAllBitsMatchesNamedBits();
    TestMultipleBreaksAllReported();
    TestHysteresisRequiresTwoConsecutiveObservations();
    TestHysteresisSuppressesTransientBreak();
    TestHysteresisReportsPersistentBreakOnlyOnce();
    TestHysteresisDoesNotFlapOnAlternatingMasks();
    TestHysteresisReportsNewlyAppearingBits();
    TestHysteresisNullStateIsSafe();
    TestEveryBitHasAName();
    if (g_failures != 0) {
        std::fprintf(stderr, "input_invariants_test: %d failure(s)\n",
                     g_failures);
        return EXIT_FAILURE;
    }
    std::printf("input_invariants_test: all checks passed\n");
    return EXIT_SUCCESS;
}
