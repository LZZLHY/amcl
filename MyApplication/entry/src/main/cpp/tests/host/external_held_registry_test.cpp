// external_held_registry_test.cpp
//
// 被测对象承载的是**静默**故障：抬起拿走别端的 owner 之后，聚合边沿仍然守恒，
// 计数器也全都正常，只有归属互换 —— 不崩、不报错，只在用户某天报告"卡键"时才暴露。
// 这类逻辑必须由测试锁住，不能靠读代码确认。
//
// 每个用例都对应一个真实的故障模式，用例名里写明了是哪一个。
#include "external_held_registry.h"

#include <cstdio>
#include <cstdlib>
#include <set>
#include <utility>

namespace {

int g_failures = 0;

void Check(bool ok, const char* what, int line) {
    if (ok) return;
    std::fprintf(stderr, "FAIL line %d: %s\n", line, what);
    ++g_failures;
}

#define CHECK(expr) Check((expr), #expr, __LINE__)

using amcl::input::ExternalHeldRegistry;
using amcl::input::Output;
using amcl::input::OutputKind;

constexpr Output kSpace{OutputKind::Key, 32};
constexpr Output kLeftButton{OutputKind::Mouse, 0};

// 故障模式：端 A 的抬起拿走端 B 的 owner（旧实现取队首，归属互换）。
// 这是"手柄 A 键与屏幕跳跃键都映射到空格"时最容易踩的一条。
void TestCrossSourceReleaseDoesNotSteal() {
    ExternalHeldRegistry registry;
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 100));
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_GAMEPAD, 200));
    CHECK(registry.LiveTotal() == 2u);

    // 手柄先抬：必须拿回 200，绝不能拿到触控端的 100。
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_GAMEPAD) == 200);
    // 触控端仍然持有 100（跨端共享同一个键是正确行为）。
    CHECK(registry.LiveCountForSource(AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 1u);
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 100);
    CHECK(registry.LiveTotal() == 0u);
}

// 故障模式：没有配对按下的抬起被当成有效释放。调用方靠返回 0 判断"该丢弃这条边沿"。
void TestUnpairedReleaseReturnsZero() {
    ExternalHeldRegistry registry;
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_GAMEPAD) == 0);
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_GAMEPAD, 7));
    // 别端的抬起：不许窃取，也不许改变持有集合。
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 0);
    CHECK(registry.LiveCountForSource(AMCL_INPUT_SOURCE_GAMEPAD) == 1u);
    // 另一个输出上的抬起同样不影响。
    CHECK(registry.TakeSameSource(kLeftButton, AMCL_INPUT_SOURCE_GAMEPAD) == 0);
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_GAMEPAD) == 7);
    // 第二次抬起已无配对。
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_GAMEPAD) == 0);
}

// 同端连续按下同一输出：LIFO。后按的先抬，与"最近一次按下"对应。
void TestSameSourceIsLifo() {
    ExternalHeldRegistry registry;
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 1));
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 2));
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 3));
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 3);
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 2);
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 1);
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 0);
}

// 中间夹着别端记录时，LIFO 必须跳过它们而不是停在那里。
void TestLifoSkipsForeignRecords() {
    ExternalHeldRegistry registry;
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 10));
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_GAMEPAD, 20));
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 30));
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_GAMEPAD, 40));
    // 触控端从后往前找，跳过 40，命中 30。
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 30);
    // 手柄端不受影响，仍然从后往前命中 40。
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_GAMEPAD) == 40);
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 10);
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_GAMEPAD) == 20);
    CHECK(registry.LiveTotal() == 0u);
}

// REPEAT 只读不消费：重复不该改变持有集合，否则一次自动重复就会吃掉一条持有记录。
void TestPeekDoesNotConsume() {
    ExternalHeldRegistry registry;
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_GAMEPAD, 55));
    CHECK(registry.PeekSameSource(kSpace, AMCL_INPUT_SOURCE_GAMEPAD) == 55);
    CHECK(registry.PeekSameSource(kSpace, AMCL_INPUT_SOURCE_GAMEPAD) == 55);
    CHECK(registry.LiveCountForSource(AMCL_INPUT_SOURCE_GAMEPAD) == 1u);
    // 别端的 REPEAT 拿不到东西。
    CHECK(registry.PeekSameSource(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 0);
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_GAMEPAD) == 55);
}

// 故障模式：拔一个手柄连带放掉屏幕虚拟按键的按下态（旧实现只有全局 releaseAll）。
void TestDrainSourceLeavesOtherSourcesAlone() {
    ExternalHeldRegistry registry;
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 1));
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_GAMEPAD, 2));
    CHECK(registry.Acquire(kLeftButton, AMCL_INPUT_SOURCE_GAMEPAD, 3));
    CHECK(registry.Acquire(kLeftButton, AMCL_INPUT_SOURCE_PHYSICAL_KBM, 4));

    const auto drained = registry.DrainSource(AMCL_INPUT_SOURCE_GAMEPAD);
    // 整集合比较而不是逐条 flag：契约不承诺顺序，但**内容必须精确**。
    // 用 flag 写法抓不到"多摘了一条别端记录"和"owner 与 Output 配错"这两种错误。
    std::set<std::pair<int, amcl::input::OwnerToken>> got;
    for (const auto& entry : drained) {
        got.insert({static_cast<int>(entry.first.kind) * 1000 + entry.first.code,
                    entry.second});
    }
    const std::set<std::pair<int, amcl::input::OwnerToken>> want{
        {static_cast<int>(OutputKind::Key) * 1000 + 32, 2},
        {static_cast<int>(OutputKind::Mouse) * 1000 + 0, 3},
    };
    CHECK(got == want);
    // 另两端一条都不许少。
    CHECK(registry.LiveCountForSource(AMCL_INPUT_SOURCE_GAMEPAD) == 0u);
    CHECK(registry.LiveCountForSource(AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 1u);
    CHECK(registry.LiveCountForSource(AMCL_INPUT_SOURCE_PHYSICAL_KBM) == 1u);
    CHECK(registry.LiveTotal() == 2u);
    // 幂等：再排一次是空的。
    CHECK(registry.DrainSource(AMCL_INPUT_SOURCE_GAMEPAD).empty());
}

// owner==0 是"无 owner"哨兵。若被存进表里，TakeSameSource 会返回 0（调用方判为无配对
// 并丢弃边沿）却已经摘掉一条记录，账目永久失衡。
void TestZeroOwnerRejected() {
    ExternalHeldRegistry registry;
    CHECK(!registry.Acquire(kSpace, AMCL_INPUT_SOURCE_GAMEPAD, 0));
    CHECK(registry.LiveTotal() == 0u);
    CHECK(registry.AcquiredForSource(AMCL_INPUT_SOURCE_GAMEPAD) == 0u);
}

// 越界端身份必须被拒，否则会产生一条**永远匹配不到任何按端释放**的幽灵持有记录，
// 只能靠全局 cancel 才清得掉。
void TestOutOfRangeSourceRejected() {
    ExternalHeldRegistry registry;
    const AmclInputSource bogus = static_cast<AmclInputSource>(99);
    CHECK(!registry.Acquire(kSpace, bogus, 5));
    CHECK(registry.LiveTotal() == 0u);
    CHECK(registry.PeekSameSource(kSpace, bogus) == 0);
    CHECK(registry.TakeSameSource(kSpace, bogus) == 0);
    CHECK(registry.DrainSource(bogus).empty());
    CHECK(registry.LiveCountForSource(bogus) == 0u);
}

// 不变量自检依赖的等式：每端 acquired - released == live。
// 三条释放路径（Take / Drain / Clear）都必须记账，漏一条这个等式就会假报警。
void TestAccountingBalanceAcrossAllReleasePaths() {
    ExternalHeldRegistry registry;
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 1));
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 2));
    CHECK(registry.Acquire(kLeftButton, AMCL_INPUT_SOURCE_GAMEPAD, 3));
    CHECK(registry.Acquire(kLeftButton, AMCL_INPUT_SOURCE_PHYSICAL_KBM, 4));

    // 路径 1：Take
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 2);
    // 路径 2：Drain
    CHECK(registry.DrainSource(AMCL_INPUT_SOURCE_GAMEPAD).size() == 1u);
    // 路径 3：Clear（剩下触控 1 条 + 键鼠 1 条）
    registry.Clear();

    for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) {
        const AmclInputSource source = static_cast<AmclInputSource>(i);
        const unsigned acquired = registry.AcquiredForSource(source);
        const unsigned released = registry.ReleasedForSource(source);
        const unsigned live =
            static_cast<unsigned>(registry.LiveCountForSource(source));
        CHECK(acquired - released == live);
    }
    CHECK(registry.LiveTotal() == 0u);
    CHECK(registry.AcquiredForSource(AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 2u);
    CHECK(registry.ReleasedForSource(AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 2u);
    CHECK(registry.ReleasedForSource(AMCL_INPUT_SOURCE_PHYSICAL_KBM) == 1u);
}

// 越界端身份在产品路径上会先被 `normalizeInputSource` 收敛成 `NONE`（而不是被拒），
// 所以 `NONE` 的记录**必须**能被 `DrainSource(NONE)` 清掉 —— 否则它就成了一条只能靠
// 全局 cancel 才清得掉的幽灵持有记录，而幽灵记录会让 heldBalance 永久变红。
void TestNoneSourceRecordsAreDrainable() {
    ExternalHeldRegistry registry;
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_NONE, 9));
    CHECK(registry.LiveCountForSource(AMCL_INPUT_SOURCE_NONE) == 1u);
    // 别端拿不走它。
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_GAMEPAD) == 0);
    const auto drained = registry.DrainSource(AMCL_INPUT_SOURCE_NONE);
    CHECK(drained.size() == 1u);
    CHECK(drained[0].second == 9);
    CHECK(registry.LiveTotal() == 0u);
    CHECK(registry.AcquiredForSource(AMCL_INPUT_SOURCE_NONE) -
              registry.ReleasedForSource(AMCL_INPUT_SOURCE_NONE) == 0u);
}

// Clear 之后表必须仍然可用（复位不是销毁），且累计计数**不清零**
// —— 不变量用的是累计差值，清零会让它在复位后短暂失效。
void TestClearLeavesRegistryReusable() {
    ExternalHeldRegistry registry;
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_GAMEPAD, 1));
    registry.Clear();
    CHECK(registry.LiveTotal() == 0u);
    CHECK(registry.AcquiredForSource(AMCL_INPUT_SOURCE_GAMEPAD) == 1u);
    CHECK(registry.ReleasedForSource(AMCL_INPUT_SOURCE_GAMEPAD) == 1u);
    // 复位后照常工作。
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_GAMEPAD, 2));
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_GAMEPAD) == 2);
    CHECK(registry.AcquiredForSource(AMCL_INPUT_SOURCE_GAMEPAD) == 2u);
    CHECK(registry.ReleasedForSource(AMCL_INPUT_SOURCE_GAMEPAD) == 2u);
}

// Drain 之后同端的 Peek/Take 必须返回 0：调用方靠这个判断"这条边沿已无配对，丢弃"。
// 若 Drain 漏删了记录，后续抬起会释放一个 ledger 侧已经放过的 owner。
void TestPeekAfterDrainReturnsZero() {
    ExternalHeldRegistry registry;
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_GAMEPAD, 1));
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_GAMEPAD, 2));
    CHECK(registry.DrainSource(AMCL_INPUT_SOURCE_GAMEPAD).size() == 2u);
    CHECK(registry.PeekSameSource(kSpace, AMCL_INPUT_SOURCE_GAMEPAD) == 0);
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_GAMEPAD) == 0);
}

// 键与鼠标是两个独立的 Output 域：编码相同的数值不能互相干扰。
void TestKeyAndMouseOutputsAreDistinct() {
    ExternalHeldRegistry registry;
    const Output key0{OutputKind::Key, 0};
    const Output mouse0{OutputKind::Mouse, 0};
    CHECK(registry.Acquire(key0, AMCL_INPUT_SOURCE_GAMEPAD, 11));
    CHECK(registry.Acquire(mouse0, AMCL_INPUT_SOURCE_GAMEPAD, 22));
    CHECK(registry.TakeSameSource(key0, AMCL_INPUT_SOURCE_GAMEPAD) == 11);
    CHECK(registry.TakeSameSource(mouse0, AMCL_INPUT_SOURCE_GAMEPAD) == 22);
}

// ---------------------------------------------------------------------------
// MaxRecordsForSameSource（2026-09-01 新增）
//
// 它是规范 §3.3 那条幽灵 owner 的**直接特征量**：那个状态下 `acquired - released == live`
// 依然成立、ledger 引用计数也自洽，所以既有的任何一个数都反映不出它。本组用例钉住
// 三件事：正常态恒为 1、跨端共享**不算**异常、同端堆叠才算。
// ---------------------------------------------------------------------------

void TestMaxRecordsForSameSourceIsOneWhenHealthy() {
    ExternalHeldRegistry registry;
    CHECK(registry.MaxRecordsForSameSource() == 0u);   // 空表
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 1));
    CHECK(registry.Acquire(kLeftButton, AMCL_INPUT_SOURCE_PHYSICAL_KBM, 2));
    CHECK(registry.MaxRecordsForSameSource() == 1u);
}

// ⭐ 跨端共享同一个输出是**正确行为**（规范 §二 的核心推论：手柄 A 与屏幕跳跃键都映射空格时
// 两端同时持有，ledger 聚合成一对边沿）。若判据数的是整个 vector 的长度而不是按端分桶，
// 这个完全正常的场景就会被报成异常 —— 那正是"一个误报过的观测量比没有观测量更糟"。
void TestCrossSourceSharingIsNotCountedAsStacking() {
    ExternalHeldRegistry registry;
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 1));
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_GAMEPAD, 2));
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_PHYSICAL_KBM, 3));
    CHECK(registry.LiveTotal() == 3u);
    CHECK(registry.MaxRecordsForSameSource() == 1u);
}

// §3.3 的形状本体：同一端在同一个输出上堆了两条 owner。LIFO 只取回后来那条，
// 先来那条永远取不走 —— 而在这个查询之前，那个状态没有任何数能反映它。
void TestSameSourceStackingIsVisible() {
    ExternalHeldRegistry registry;
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 1));
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS, 2));
    CHECK(registry.MaxRecordsForSameSource() == 2u);
    // 守恒式对这个状态**完全自洽** —— 这就是为什么需要一个独立的特征量。
    CHECK(registry.AcquiredForSource(AMCL_INPUT_SOURCE_TOUCH_CONTROLS) -
              registry.ReleasedForSource(AMCL_INPUT_SOURCE_TOUCH_CONTROLS) ==
          registry.LiveCountForSource(AMCL_INPUT_SOURCE_TOUCH_CONTROLS));
    // 取回一条之后回落到正常值：它是瞬时特征，不是累计量。
    CHECK(registry.TakeSameSource(kSpace, AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 2);
    CHECK(registry.MaxRecordsForSameSource() == 1u);
    // 而先来那条仍在表里 —— 幽灵 owner 的本体。
    CHECK(registry.LiveCountForSource(AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 1u);
}

// 取全表最大值而不是某一个输出的：一个输出正常、另一个堆叠时必须报后者。
void TestMaxRecordsScansEveryOutput() {
    ExternalHeldRegistry registry;
    CHECK(registry.Acquire(kSpace, AMCL_INPUT_SOURCE_GAMEPAD, 1));
    CHECK(registry.Acquire(kLeftButton, AMCL_INPUT_SOURCE_GAMEPAD, 2));
    CHECK(registry.Acquire(kLeftButton, AMCL_INPUT_SOURCE_GAMEPAD, 3));
    CHECK(registry.Acquire(kLeftButton, AMCL_INPUT_SOURCE_GAMEPAD, 4));
    CHECK(registry.MaxRecordsForSameSource() == 3u);
    registry.Clear();
    CHECK(registry.MaxRecordsForSameSource() == 0u);
}

}  // namespace

int main() {
    TestCrossSourceReleaseDoesNotSteal();
    TestUnpairedReleaseReturnsZero();
    TestSameSourceIsLifo();
    TestLifoSkipsForeignRecords();
    TestPeekDoesNotConsume();
    TestDrainSourceLeavesOtherSourcesAlone();
    TestZeroOwnerRejected();
    TestOutOfRangeSourceRejected();
    TestAccountingBalanceAcrossAllReleasePaths();
    TestNoneSourceRecordsAreDrainable();
    TestClearLeavesRegistryReusable();
    TestPeekAfterDrainReturnsZero();
    TestKeyAndMouseOutputsAreDistinct();
    TestMaxRecordsForSameSourceIsOneWhenHealthy();
    TestCrossSourceSharingIsNotCountedAsStacking();
    TestSameSourceStackingIsVisible();
    TestMaxRecordsScansEveryOutput();
    if (g_failures != 0) {
        std::fprintf(stderr, "external_held_registry_test: %d failure(s)\n",
                     g_failures);
        return EXIT_FAILURE;
    }
    std::printf("external_held_registry_test: all checks passed\n");
    return EXIT_SUCCESS;
}
