// input_invariants.cpp — 不变量求值器。纯函数，无 hilog、无全局状态。契约见 .h。
#include "input_invariants.h"

extern "C" uint32_t amcl_input_invariants_evaluate(
        const AmclInputInvariantSnapshot* snapshot) {
    if (snapshot == 0) return 0u;
    uint32_t broken = 0u;

    unsigned lookSum = 0u;
    unsigned scrollSum = 0u;
    for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) {
        lookSum += snapshot->lookPerSource[i];
        scrollSum += snapshot->scrollPerSource[i];
    }
    if (lookSum != snapshot->lookTotal) broken |= AMCL_INV_LOOK_SUM;
    if (scrollSum != snapshot->scrollTotal) broken |= AMCL_INV_SCROLL_SUM;

    for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) {
        // 无符号相减在这里是**故意**的：acquired 恒 >= released（释放路径都要先找到
        // 一条记录），若因为某个 bug 反过来了，差值会回绕成一个巨大的数、与 live
        // 不可能相等，于是同样被这条不变量抓住。写成有符号比较反而会掩盖那种情况。
        const unsigned outstanding =
            snapshot->heldAcquired[i] - snapshot->heldReleased[i];
        if (outstanding != snapshot->heldLive[i]) {
            broken |= AMCL_INV_HELD_BALANCE;
            break;
        }
    }

    const int none = (int)AMCL_INPUT_SOURCE_NONE;
    if (snapshot->lookPerSource[none] != 0u ||
        snapshot->scrollPerSource[none] != 0u ||
        snapshot->heldAcquired[none] != 0u) {
        broken |= AMCL_INV_NO_UNTAGGED;
    }

    const int gesture = (int)AMCL_INPUT_SOURCE_PLATFORM_GESTURE;
    if (snapshot->lookPerSource[gesture] != 0u) {
        broken |= AMCL_INV_GESTURE_NO_LOOK;
    }

    // 蕴含式而非等式：第 1c 层（schema owner）不在快照里，它只会让 ledger 更多，
    // 所以只有"上游非空 ⇒ ledger 非空"这个方向结构性无误报。理由详见 .h。
    unsigned heldLiveSum = 0u;
    for (int i = 0; i < AMCL_INPUT_SOURCE_COUNT; ++i) {
        heldLiveSum += snapshot->heldLive[i];
    }
    const unsigned upstreamOwners = heldLiveSum + snapshot->physicalIdentityLive;
    if (upstreamOwners != 0u && snapshot->ledgerOwnerLive == 0u) {
        broken |= AMCL_INV_LEDGER_COVERS_OWNERS;
    }

    return broken;
}

extern "C" uint32_t amcl_input_invariants_confirm(
        AmclInputInvariantHysteresis* state, uint32_t observed) {
    if (state == 0) return 0u;
    // 连续两次都观测到才算确认。真实破坏是永久的（计数器累计单调），所以这条不会漏；
    // 采样窗口造成的瞬时失衡会在下一次自愈，所以这条能完全滤掉误报。
    const uint32_t confirmed = observed & state->lastObserved;
    state->lastObserved = observed;
    const uint32_t fresh = confirmed & ~state->reported;
    state->reported |= confirmed;
    return fresh;
}

extern "C" const char* amcl_input_invariant_name(uint32_t bit) {
    switch (bit) {
        case AMCL_INV_LOOK_SUM:        return "lookSum";
        case AMCL_INV_SCROLL_SUM:      return "scrollSum";
        case AMCL_INV_HELD_BALANCE:    return "heldBalance";
        case AMCL_INV_NO_UNTAGGED:     return "untagged";
        case AMCL_INV_GESTURE_NO_LOOK: return "gestureLook";
        case AMCL_INV_LEDGER_COVERS_OWNERS: return "ledgerCoversOwners";
        default:                       return "?";
    }
}
