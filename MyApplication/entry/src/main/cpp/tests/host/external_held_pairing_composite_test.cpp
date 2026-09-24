// external_held_pairing_composite_test.cpp
//
// ============================ 为什么需要第二个 registry 测试 ============================
//
// `external_held_registry_test.cpp` 只看 registry **一侧**：它断言 TakeSameSource 取回哪个
// token，但看不到"MC 到底有没有收到边沿"。而本项目真正会伤到用户的那类故障恰好只在
// **registry × ledger 复合**之后才显形：registry 侧完全正常（LIFO 正确、跨端不窃取、
// acquired-released==live 守恒），ledger 侧也完全正常（引用计数正确），组合起来却是一个
// 卡死的按键。两个单侧测试各自全绿，缺陷照样出厂。
//
// 本文件复刻 `touch_input.cpp` 的 `routerKey` / `routerOutput` /
// `ohos_release_input_source_held` 三段真实逻辑（只有三行，刻意不抽共享代码 —— 抽了就等于
// 让测试和产品共享同一个可能错的实现），因此它测的是产品语义而不是近似。
//
// ============================ 被钉住的故障（2026-08-21） ============================
//
// 驱动 ArkTS 对账的 reset epoch 有两个语义各异的推进点，其中"typed core 观测到自己的
// RESET"那一路**不**清 external held 与 ledger，而 surface 几何变化（平板分屏 / 悬浮窗 /
// 折叠屏形态切换）只产生那一路。于是 ArkTS 端把"我认为哪些键还按着"清空，native 这边
// 没动 —— 然后：
//
//   · 用户松手：端因为缓存已空而**不发** RELEASE ⇒ 那条 owner 永久留在表里；
//   · 再按一次：每次 PRESS 都分配**全新** owner，ledger 看到 byOutput_ 非空所以**不发 PRESS**；
//   · 再松手：LIFO 只取回新那条，旧 owner 压在栈底**永远取不走**，所以**也不发 RELEASE**。
//
// 净效果 = 该键在 MC 侧恒为按下，且此后按它完全没有反应。
// ⚠️ 这个状态**通不过任何现有告警**：registry 的 acquired-released==live 依然成立
//   （幽灵记录确实是 live 的），ledger 的引用计数也自洽。所以它只能靠测试锁住。
//
// TestStackedOwnerNeverRecoversWithoutDrain 断言缺陷本体（"没有按端释放就永远回不来"），
// TestDrainSourceRecoversStackedOwners 断言修法有效。**两个都必须在**：只留后者的话，
// 下一个人看不出"为什么非得在那条禁止副作用的路径上调释放"。
#include "external_held_registry.h"
#include "input_ledger.h"

#include <cstddef>
#include <cstdio>
#include <utility>
#include <vector>

namespace {

int g_failures = 0;

void Check(bool ok, const char* what, int line) {
    if (ok) return;
    std::fprintf(stderr, "FAIL line %d: %s\n", line, what);
    ++g_failures;
}

#define CHECK(expr) Check((expr), #expr, __LINE__)

using amcl::input::ExternalHeldRegistry;
using amcl::input::InputLedger;
using amcl::input::Output;
using amcl::input::OutputKind;
using amcl::input::OwnerToken;

constexpr Output kSpace{OutputKind::Key, 32};
constexpr Output kSneak{OutputKind::Key, 340};

constexpr int kRelease = 0;
constexpr int kPress = 1;
constexpr int kRepeat = 2;

struct Edge {
    Output output{OutputKind::Key, 0};
    int action = -1;
};

// registry + ledger 的复合平面，逐行对应产品实现：
//   Key()           == routerKey() 的 external 分支 + routerOutput()
//   ReleaseSource() == ohos_release_input_source_held()
//   CancelAll()     == ohos_cancel_all_input() 里那两行（Clear + releaseAll）
// 唯一简化是没有那三把锁 —— 本类是单线程的，而锁序由产品侧的调用点负责。
class ExternalPlane final {
public:
    ExternalPlane()
        : ledger_([this](const Output& output, int action) {
              edges_.push_back(Edge{output, action});
          }) {}

    // 返回值语义与 routerKey 一致：true == 本次调用向 MC 发出了一条聚合边沿。
    bool Key(AmclInputSource source, const Output& output, int action) {
        OwnerToken owner = 0;
        if (action == kPress) {
            const OwnerToken candidate = NextOwner();
            if (registry_.Acquire(output, source, candidate)) owner = candidate;
        } else if (action == kRepeat) {
            owner = registry_.PeekSameSource(output, source);
        } else {
            owner = registry_.TakeSameSource(output, source);
        }
        if (owner == 0) return false;
        if (action == kPress) return ledger_.acquire(owner, output);
        if (action == kRepeat) return ledger_.repeat(owner, output);
        return ledger_.release(owner, output);
    }

    void ReleaseSource(AmclInputSource source) {
        const std::vector<std::pair<Output, OwnerToken>> drained =
            registry_.DrainSource(source);
        for (const std::pair<Output, OwnerToken>& entry : drained) {
            (void)ledger_.release(entry.second, entry.first);
        }
    }

    void CancelAll() {
        registry_.Clear();
        ledger_.releaseAll();
    }

    // 直接进 ledger、**不经** registry 的 owner。产品里 grabbed 下由 C 层解释器接管的
    // schema 控件就是这样的：它自己分配 owner 交给 ledger，registry 里没有它的记录。
    OwnerToken AcquireForeignOwner(const Output& output) {
        const OwnerToken owner = NextOwner();
        (void)ledger_.acquire(owner, output);
        return owner;
    }

    const std::vector<Edge>& edges() const { return edges_; }
    void ClearEdges() { edges_.clear(); }
    std::size_t liveTotal() const { return registry_.LiveTotal(); }
    std::size_t liveFor(AmclInputSource source) const {
        return registry_.LiveCountForSource(source);
    }

    // MC 侧那个键现在是按下还是抬起：重放全部边沿即可，与 GLFW 的语义一致。
    bool pressedInBackend(const Output& output) const {
        bool pressed = false;
        for (const Edge& edge : edges_) {
            if (edge.output < output || output < edge.output) continue;
            if (edge.action == kPress) pressed = true;
            if (edge.action == kRelease) pressed = false;
        }
        return pressed;
    }

private:
    OwnerToken NextOwner() { return ++nextOwner_; }

    std::vector<Edge> edges_;
    ExternalHeldRegistry registry_;
    InputLedger ledger_;
    // 与产品一致：全局单调，**从不复用**。owner 去重不存在，这正是故障的成因之一。
    OwnerToken nextOwner_ = 0x400000000ull;
};

// 缺陷本体：ArkTS 缓存被清而 native 未清之后，该键永远回不到抬起态，
// 而且此后每一次按下/抬起都是静默空转。
void TestStackedOwnerNeverRecoversWithoutDrain() {
    ExternalPlane plane;
    CHECK(plane.Key(AMCL_INPUT_SOURCE_GAMEPAD, kSpace, kPress));
    CHECK(plane.edges().size() == 1u);
    CHECK(plane.pressedInBackend(kSpace));

    // === 这里发生了一次只清 typed core 的 RESET ===
    // ArkTS 端把自己的 pressedButtons 清空；native 的两张表按当时的实现没有被触碰。
    plane.ClearEdges();

    // 用户松手：端已经不认为它按着，所以**根本不会调下来**。native 侧一条边沿都没有。
    CHECK(plane.edges().empty());
    CHECK(plane.liveFor(AMCL_INPUT_SOURCE_GAMEPAD) == 1u);

    // 之后无论按多少轮，MC 都收不到任何东西：按下被 byOutput_ 非空吞掉，
    // 抬起被 LIFO 吞掉（取回的是新 owner，栈底那条纹丝不动）。
    for (int round = 0; round < 3; ++round) {
        CHECK(!plane.Key(AMCL_INPUT_SOURCE_GAMEPAD, kSpace, kPress));
        CHECK(!plane.Key(AMCL_INPUT_SOURCE_GAMEPAD, kSpace, kRelease));
    }
    CHECK(plane.edges().empty());
    // 幽灵记录仍然是**唯一**一条 —— 每轮加一条又减同一条，栈底那条永远在。
    CHECK(plane.liveFor(AMCL_INPUT_SOURCE_GAMEPAD) == 1u);

    // 重放整段边沿：MC 那边这个键从头到尾就没有被抬起过。
    ExternalPlane replay;
    CHECK(replay.Key(AMCL_INPUT_SOURCE_GAMEPAD, kSpace, kPress));
    for (int round = 0; round < 3; ++round) {
        (void)replay.Key(AMCL_INPUT_SOURCE_GAMEPAD, kSpace, kPress);
        (void)replay.Key(AMCL_INPUT_SOURCE_GAMEPAD, kSpace, kRelease);
    }
    CHECK(replay.pressedInBackend(kSpace));
}

// 修法验收：按端释放原语把幽灵记录清干净，并且**正好发一条** RELEASE。
void TestDrainSourceRecoversStackedOwners() {
    ExternalPlane plane;
    CHECK(plane.Key(AMCL_INPUT_SOURCE_GAMEPAD, kSpace, kPress));
    // 模拟"缓存被清 + 用户按了几轮"之后的堆叠状态。
    for (int round = 0; round < 3; ++round) {
        (void)plane.Key(AMCL_INPUT_SOURCE_GAMEPAD, kSpace, kPress);
        (void)plane.Key(AMCL_INPUT_SOURCE_GAMEPAD, kSpace, kRelease);
    }
    plane.ClearEdges();

    plane.ReleaseSource(AMCL_INPUT_SOURCE_GAMEPAD);
    CHECK(plane.edges().size() == 1u);
    CHECK(plane.edges()[0].action == kRelease);
    CHECK(!plane.pressedInBackend(kSpace));
    CHECK(plane.liveTotal() == 0u);

    // 释放之后这个键必须重新可用：下一次按下要真的发 PRESS。
    plane.ClearEdges();
    CHECK(plane.Key(AMCL_INPUT_SOURCE_GAMEPAD, kSpace, kPress));
    CHECK(plane.pressedInBackend(kSpace));
}

// 放在"禁止副作用"的对账路径上的前提：正常情况下它必须是 no-op。
// 否则每次 epoch 变化都会往 MC 灌一批无配对边沿，把真正的失步淹掉。
void TestDrainSourceIsIdempotentWhenAlreadyEmpty() {
    ExternalPlane plane;
    plane.ReleaseSource(AMCL_INPUT_SOURCE_GAMEPAD);
    CHECK(plane.edges().empty());

    // 完整 cancel 之后再对账（这正是 (ii) 那条路径的时序）：同样一条边沿都不该有。
    CHECK(plane.Key(AMCL_INPUT_SOURCE_TOUCH_CONTROLS, kSpace, kPress));
    plane.CancelAll();
    plane.ClearEdges();
    plane.ReleaseSource(AMCL_INPUT_SOURCE_TOUCH_CONTROLS);
    plane.ReleaseSource(AMCL_INPUT_SOURCE_GAMEPAD);
    plane.ReleaseSource(AMCL_INPUT_SOURCE_PHYSICAL_KBM);
    CHECK(plane.edges().empty());
    CHECK(plane.liveTotal() == 0u);
}

// 按端释放不得越端。对账路径会对三个真实端各调一次，若越端就会把别端仍然
// 按着的键放掉 —— 那是把一个卡键换成另一个卡键。
void TestDrainSourceDoesNotCrossSources() {
    ExternalPlane plane;
    CHECK(plane.Key(AMCL_INPUT_SOURCE_TOUCH_CONTROLS, kSpace, kPress));
    // 同一个输出被两个端同时按住是**正确**的（跨端共享键），聚合只发一条 PRESS。
    CHECK(!plane.Key(AMCL_INPUT_SOURCE_GAMEPAD, kSpace, kPress));
    CHECK(plane.Key(AMCL_INPUT_SOURCE_GAMEPAD, kSneak, kPress));
    plane.ClearEdges();

    plane.ReleaseSource(AMCL_INPUT_SOURCE_GAMEPAD);
    // 手柄端的两条记录都走了，但 kSpace 上触控端还按着 ⇒ kSpace 不许发 RELEASE，
    // 只有手柄独占的 kSneak 才发。
    CHECK(plane.edges().size() == 1u);
    CHECK(plane.edges()[0].action == kRelease);
    CHECK(plane.liveFor(AMCL_INPUT_SOURCE_GAMEPAD) == 0u);
    CHECK(plane.liveFor(AMCL_INPUT_SOURCE_TOUCH_CONTROLS) == 1u);

    // 触控端仍能正常抬起自己那条。
    CHECK(plane.Key(AMCL_INPUT_SOURCE_TOUCH_CONTROLS, kSpace, kRelease));
    CHECK(plane.liveTotal() == 0u);
}

// 按端释放不得跨 owner 域。grabbed 下 C 层接管的 schema owner 直接进 ledger、
// 不经 registry，所以它必须完全不受按端释放影响 —— 这是"修法不越端"的另一半，
// 也是为什么这条修复可以放在 grabbed 状态下运行的对账路径上。
void TestDrainSourceLeavesForeignOwnerDomainAlone() {
    ExternalPlane plane;
    const OwnerToken schemaOwner = plane.AcquireForeignOwner(kSpace);
    CHECK(schemaOwner != 0);
    CHECK(plane.pressedInBackend(kSpace));
    plane.ClearEdges();

    plane.ReleaseSource(AMCL_INPUT_SOURCE_TOUCH_CONTROLS);
    plane.ReleaseSource(AMCL_INPUT_SOURCE_GAMEPAD);
    plane.ReleaseSource(AMCL_INPUT_SOURCE_PHYSICAL_KBM);
    // 一条边沿都不许发，schema 那个键仍然按着。
    CHECK(plane.edges().empty());

    ExternalPlane replay;
    (void)replay.AcquireForeignOwner(kSpace);
    CHECK(replay.pressedInBackend(kSpace));
}

}  // namespace

int main() {
    TestStackedOwnerNeverRecoversWithoutDrain();
    TestDrainSourceRecoversStackedOwners();
    TestDrainSourceIsIdempotentWhenAlreadyEmpty();
    TestDrainSourceDoesNotCrossSources();
    TestDrainSourceLeavesForeignOwnerDomainAlone();
    if (g_failures != 0) {
        std::fprintf(stderr, "external held pairing composite test FAILED (%d)\n",
                     g_failures);
        return 1;
    }
    std::printf("external held pairing composite test passed\n");
    return 0;
}
