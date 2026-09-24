// input_channel_policy_test.cpp
//
// 被测模块是**专门为修"左键卡死"而建的**（见 docs/refactor 第三十五节），却一直没有
// 任何测试覆盖。它守的两条性质坏了都是用户直接可感知的：
//   · 所有者由"静态优先级 × 实测能力"决定，与到达时序无关 → 坏了会"菜单点不动"；
//   · 一对 press/release 必须由同一条通道送完 → 坏了会"左键永久卡在按下态"。
//
// ⚠️ 本模块的能力位图是**进程级、只增不减**（没有清除 API，这是刻意的：设备能力不会因为
// 换了个 surface 就变化）。所以下面的用例**顺序即前提**：必须按优先级从低到高逐步"发现"
// 通道，每一步的期望值才是确定的。不要重排用例。
#include "input_channel_policy.h"

#include <cstdio>
#include <cstdlib>

namespace {

int g_failures = 0;

void Check(bool ok, const char* what, int line) {
    if (ok) return;
    std::fprintf(stderr, "FAIL line %d: %s\n", line, what);
    ++g_failures;
}

#define CHECK(expr) Check((expr), #expr, __LINE__)

// 步骤 1：全新状态。没有任何通道被观测到时，谁都不该拿到所有权 ——
// "先注册后观测"的顺序如果被写反，这一步会失败。
void TestPristineStateGrantsNothing() {
    CHECK(amcl_input_policy_wheel_owner() == AMCL_INPUT_CHANNEL_NONE);
    // 2026-09-01：左键这一侧此前没有 owner getter，于是这条对称的断言写不出来。
    CHECK(amcl_input_policy_left_owner() == AMCL_INPUT_CHANNEL_NONE);
    CHECK(!amcl_input_policy_wheel_accepts(AMCL_INPUT_CHANNEL_NATIVE_AXIS));
    CHECK(!amcl_input_policy_wheel_accepts(AMCL_INPUT_CHANNEL_TOUCH_WHEEL));
    CHECK(!amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    CHECK(!amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_TOUCH_MIRROR));
    CHECK(!amcl_input_policy_left_held());
    // NONE 永远不是合法通道。
    CHECK(!amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_NONE));
    CHECK(!amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_NONE));
    CHECK(!amcl_input_policy_wheel_accepts(AMCL_INPUT_CHANNEL_NONE));
    // note(NONE) 是无害的 no-op，不该凭空创造所有者。
    amcl_input_policy_note_left_channel(AMCL_INPUT_CHANNEL_NONE);
    amcl_input_policy_note_wheel_channel(AMCL_INPUT_CHANNEL_NONE);
    CHECK(amcl_input_policy_wheel_owner() == AMCL_INPUT_CHANNEL_NONE);
}

// 步骤 2：只发现末选通道（API 24 平板的真实情形 —— 左键只以合成触摸到达）。
void TestLowestPriorityChannelOwnsWhenAlone() {
    amcl_input_policy_note_left_channel(AMCL_INPUT_CHANNEL_TOUCH_MIRROR);
    CHECK(amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_TOUCH_MIRROR));
    CHECK(amcl_input_policy_left_held());
    // 同一通道的重复 DOWN（平台重发 / 合成流的 DOWN-MOVE-DOWN）不能再发一个 PRESS，
    // 否则 MC 侧按下计数失衡。
    CHECK(!amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_TOUCH_MIRROR));
    // 非持有者的抬起必须被拒。
    CHECK(!amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_NATIVE_MOUSE));
    CHECK(amcl_input_policy_left_held());
    CHECK(amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_TOUCH_MIRROR));
    CHECK(!amcl_input_policy_left_held());
    // 未配对的重复抬起（复位后到达的残包）必须被丢弃。
    CHECK(!amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_TOUCH_MIRROR));
}

// 步骤 3：**本模块存在的核心理由。**
// 按下期间发现了优先级更高的通道，这一次的抬起仍必须由按下的那一方送出。
// 旧的"500ms 空窗交接"在这里会换人，于是"按下由 A 发、抬起被 B 吞"，
// MC 侧表现为左键永久卡在按下态。
void TestReleaseHonoursPressHolderEvenWhenPriorityRises() {
    // 前提断言：本用例要求此刻左键赢家是 TOUCH_MIRROR（只发现了末选通道）。
    // 把"顺序即前提"写成断言，这样将来有人在前面插一个用例、或重排顺序时，
    // 失败信息会直接指向前提被破坏，而不是变成一个难解释的断言失败。
    CHECK(!amcl_input_policy_left_held());
    CHECK(!amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    CHECK(!amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_NATIVE_MOUSE));

    CHECK(amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_TOUCH_MIRROR));
    // 按住期间第一次观测到 native mouse（优先级高于合成触摸）。
    amcl_input_policy_note_left_channel(AMCL_INPUT_CHANNEL_NATIVE_MOUSE);
    // 新赢家不能抢走这一次的抬起。
    CHECK(!amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_NATIVE_MOUSE));
    CHECK(amcl_input_policy_left_held());
    // 原持有者仍然能正常收尾 —— 这就是"抬起被吞导致卡键"在结构上不可能发生的地方。
    CHECK(amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_TOUCH_MIRROR));
    CHECK(!amcl_input_policy_left_held());
}

// 步骤 4：能力发现之后，所有权按静态优先级重算，且只在 DOWN 边沿生效。
void TestOwnerFollowsStaticPriorityAfterDiscovery() {
    // 此刻已观测到 TOUCH_MIRROR + NATIVE_MOUSE，赢家应是 NATIVE_MOUSE。
    CHECK(!amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_TOUCH_MIRROR));
    CHECK(amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_NATIVE_MOUSE));
    CHECK(amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_NATIVE_MOUSE));

    // 再发现首选通道（API 26 手机的真实情形）。
    amcl_input_policy_note_left_channel(AMCL_INPUT_CHANNEL_ARKUI_MOUSE);
    CHECK(!amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_NATIVE_MOUSE));
    CHECK(!amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_TOUCH_MIRROR));
    CHECK(amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    CHECK(amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
}

// 步骤 5：复位只清 in-flight 配对，**保留**已发现的能力。
// 若能力也被清掉，"第一次点击又被末选通道抢走"这个 warm-up 问题会在每次失焦后复现。
void TestResetClearsPairingButKeepsCapabilities() {
    CHECK(amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    CHECK(amcl_input_policy_left_held());
    amcl_input_policy_reset_pairing();
    CHECK(!amcl_input_policy_left_held());
    // 复位后到达的残留抬起必须被丢弃（否则会释放一个已被复位释放过的按下）。
    CHECK(!amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    // 能力保留：首选通道仍然是赢家，末选仍然拿不到。
    CHECK(amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    CHECK(amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    CHECK(!amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_TOUCH_MIRROR));
}

// 步骤 6：滚轮 aspect，同样按优先级从低到高发现。
void TestWheelOwnerFollowsPriority() {
    // 前提断言：滚轮 aspect 此刻仍未发现任何通道（前五个用例只碰左键 aspect）。
    // 这同时是一条 aspect 隔离的检查：左键那边已经发现三条通道了。
    CHECK(amcl_input_policy_wheel_owner() == AMCL_INPUT_CHANNEL_NONE);

    amcl_input_policy_note_wheel_channel(AMCL_INPUT_CHANNEL_TOUCH_WHEEL);
    CHECK(amcl_input_policy_wheel_owner() == AMCL_INPUT_CHANNEL_TOUCH_WHEEL);
    CHECK(amcl_input_policy_wheel_accepts(AMCL_INPUT_CHANNEL_TOUCH_WHEEL));
    CHECK(!amcl_input_policy_wheel_accepts(AMCL_INPUT_CHANNEL_NATIVE_AXIS));

    amcl_input_policy_note_wheel_channel(AMCL_INPUT_CHANNEL_AXIS_PAN);
    CHECK(amcl_input_policy_wheel_owner() == AMCL_INPUT_CHANNEL_AXIS_PAN);
    CHECK(!amcl_input_policy_wheel_accepts(AMCL_INPUT_CHANNEL_TOUCH_WHEEL));

    amcl_input_policy_note_wheel_channel(AMCL_INPUT_CHANNEL_ARKTS_AXIS);
    CHECK(amcl_input_policy_wheel_owner() == AMCL_INPUT_CHANNEL_ARKTS_AXIS);

    amcl_input_policy_note_wheel_channel(AMCL_INPUT_CHANNEL_NATIVE_AXIS);
    CHECK(amcl_input_policy_wheel_owner() == AMCL_INPUT_CHANNEL_NATIVE_AXIS);
    CHECK(amcl_input_policy_wheel_accepts(AMCL_INPUT_CHANNEL_NATIVE_AXIS));
    CHECK(!amcl_input_policy_wheel_accepts(AMCL_INPUT_CHANNEL_AXIS_PAN));
}

// 两个 aspect 必须互相隔离：一台设备可能 native 报得了右键却从不报左键（API 24 实测），
// 用一个全局 "seen" 会把它误判成可用。这里用"把滚轮通道 note 到左键 aspect 上"来验证 ——
// 它会置一个位，但那个通道不在左键优先级表里，所以左键所有者不该变。
void TestAspectsAreIsolated() {
    // 左键当前赢家是 ARKUI_MOUSE。
    amcl_input_policy_note_left_channel(AMCL_INPUT_CHANNEL_NATIVE_AXIS);
    CHECK(amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    CHECK(amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    // 反向：把左键通道 note 到滚轮 aspect，不该改变滚轮赢家。
    amcl_input_policy_note_wheel_channel(AMCL_INPUT_CHANNEL_ARKUI_MOUSE);
    CHECK(amcl_input_policy_wheel_owner() == AMCL_INPUT_CHANNEL_NATIVE_AXIS);
    // 反向也不该让左键通道获得滚轮所有权。
    CHECK(!amcl_input_policy_wheel_accepts(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    // 日志接口只是打一行，不改状态。
    amcl_input_policy_log_state();
    CHECK(amcl_input_policy_wheel_owner() == AMCL_INPUT_CHANNEL_NATIVE_AXIS);
    CHECK(!amcl_input_policy_left_held());
}

// 步骤 8（2026-09-01）：**左键让位的四个成因必须可区分。**
// 这是 `amcl_input_policy_left_owner` 存在的全部理由 —— 在它之前调用方只看到一个 bool，
// 四个排查方向完全不同的成因被压进同一个 `btnYield` 计数。因果见计划 §107.4。
// 本用例钉住的是那段分类逻辑的**前提**（两个快照足以分开四者），而不是分类代码本身
// （它在 3700 行的产品 TU 里，主机侧构建拉不进来）。
void TestLeftYieldCausesAreDistinguishable() {
    // 前提：此刻三条左键通道都已被发现 ⇒ 赢家是首选的 ARKUI_MOUSE，且无按下在飞行。
    CHECK(amcl_input_policy_left_owner() == AMCL_INPUT_CHANNEL_ARKUI_MOUSE);
    CHECK(!amcl_input_policy_left_held());

    // 成因 ①「非所有者」：DOWN 被拒，且本通道不是赢家。
    CHECK(!amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_TOUCH_MIRROR));
    CHECK(amcl_input_policy_left_owner() != AMCL_INPUT_CHANNEL_TOUCH_MIRROR);
    CHECK(!amcl_input_policy_left_held());   // 被拒的 DOWN 不得留下按下态

    // 成因 ②「同通道重复 DOWN」：DOWN 被拒，但本通道**就是**赢家。
    // 与 ① 的判别维度正是 `amcl_input_policy_left_owner` —— 此前两者都只是一个 false。
    CHECK(amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    CHECK(amcl_input_policy_left_held());
    CHECK(!amcl_input_policy_left_begin(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    CHECK(amcl_input_policy_left_owner() == AMCL_INPUT_CHANNEL_ARKUI_MOUSE);

    // 成因 ④「持有者是另一条通道」：UP 被拒，而**有**按下在飞行。
    // ⚠️ 产品里按设计不可达（非赢家的 DOWN 进不来，所以它不会发 UP），
    // 所以这里是唯一能证明分类逻辑正确的地方；产品侧那个桶恒零，非零即真信号。
    CHECK(!amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_TOUCH_MIRROR));
    CHECK(amcl_input_policy_left_held());    // 被拒的 UP 不得清掉别人的按下态

    // 收尾：真正的持有者抬起。
    CHECK(amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    CHECK(!amcl_input_policy_left_held());

    // 成因 ③「无按下在飞行」：UP 被拒，且**没有**按下。
    // 与 ④ 的判别维度是 `amcl_input_policy_left_held`，而它必须在准入判定**之前**采样 ——
    // 成功的 `amcl_input_policy_left_end` 会把它清成 false，事后再读就分不出这两条。
    CHECK(!amcl_input_policy_left_end(AMCL_INPUT_CHANNEL_ARKUI_MOUSE));
    CHECK(!amcl_input_policy_left_held());

    // 四个成因两两之间至少有一个判别位不同 ⇒ 两个快照足以分开它们。
    // ①(owner≠self, held=false) ②(owner=self, held=true→拒)
    // ③(UP, held=false)          ④(UP, held=true)
}

}  // namespace

int main() {
    // 顺序即前提：能力只增不减，必须从低优先级往高走。
    TestPristineStateGrantsNothing();
    TestLowestPriorityChannelOwnsWhenAlone();
    TestReleaseHonoursPressHolderEvenWhenPriorityRises();
    TestOwnerFollowsStaticPriorityAfterDiscovery();
    TestResetClearsPairingButKeepsCapabilities();
    TestWheelOwnerFollowsPriority();
    TestAspectsAreIsolated();
    TestLeftYieldCausesAreDistinguishable();
    if (g_failures != 0) {
        std::fprintf(stderr, "input_channel_policy_test: %d failure(s)\n",
                     g_failures);
        return EXIT_FAILURE;
    }
    std::printf("input_channel_policy_test: all checks passed\n");
    return EXIT_SUCCESS;
}
