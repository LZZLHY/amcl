// 三种游戏输入 ABI 共用的指针事务归约器。它只决定一轮接触的阶段、冻结源点、
// 呈现等待和已提交按钮贡献；ring、窗口资格、最终 owner 并集及 ABI 副作用由调用者负责。
// 本文件是中立 runtime 的私有实现，不进入跨 DSO 函数表，兼容生产 C11 与宿主 C++17。
#ifndef AMCL_POINTER_TRANSACTION_H
#define AMCL_POINTER_TRANSACTION_H

#include <stdint.h>
#include <stdbool.h>
#include <string.h>

// 阶段数值与旧私有菜单槽一致。它们只在兼容边缘解码一次，不增加公开 ABI 能力。
enum AmclPointerPhase {
    AMCL_POINTER_MOVE = 0, AMCL_POINTER_DOWN = 1, AMCL_POINTER_UP = 2,
    AMCL_POINTER_CANCEL = 3, AMCL_POINTER_BEGIN = 4, AMCL_POINTER_END = 5
};

// 每个实际 consumer 独占一个实例，访问仍遵循其原有线程/锁合同。scope 与 targetEpoch
// 表达冻结的不同资源身份；真实窗口、WSI 和 activation 的核对留在 ABI 适配边缘。
typedef struct AmclPointerTransaction {
    uint32_t token;
    bool gestureBegun, pressPending, buttonDown;
    // DOWN 已接受后即冻结到 END/CANCEL；普通UP只结束贡献，不能再次授予同token的DOWN。
    bool downAccepted;
    bool releasePending, finalReleasePending, finalReleaseClosesGesture;
    bool sourceFrameBaselinePending;
    uint64_t pendingOrder, pendingSinceNs, pressAfterPresent;
    uint64_t scopeEpoch, inputTargetEpoch;
    double sourceX, sourceY;
} AmclPointerTransaction;

// presentFrames 是既有消费者政策：GLFW=2、SDL=1、L2=0。
// sourceBaselineOnNext 仅用于 SDL：1010 已交给 caller 后，下一次 Next 才可证明源点
// MOTION 已进入其同步 pump。splitRelease 保证 pull ABI 先领取终点位置，再领取 RELEASE。
typedef struct AmclPointerDeliveryPolicy {
    uint32_t presentFrames;
    bool sourceBaselineOnNext, splitRelease;
} AmclPointerDeliveryPolicy;

// contribution：-1 无变化，0 结束本接触贡献，1 建立本接触贡献。它不是最终按钮边沿，
// 必须经现有 owner 并集后才能调用 ABI；取消本接触不能释放物理或工具仍持有的 LEFT。
typedef struct AmclPointerPlan {
    bool accepted, position;
    int contribution;
} AmclPointerPlan;

// BEGIN 只建接触，首次 DOWN 可以沿同一 token 建立按钮意图；已经提交或正在等候的
// DOWN 不属于延续。队列准入/旧贡献退休与阶段归约必须共用此判别，不能各自解释重复按下。
static inline bool amclPointerIsContinuation(int phase, uint32_t token, uint32_t currentToken,
        bool begun, bool heldOrPending, bool downAccepted) {
    return phase == AMCL_POINTER_DOWN && token == currentToken && begun && !heldOrPending && !downAccepted;
}

// 清除事务身份不会回滚已交付坐标。返回的释放意图由原 consumer 在锁外交付；
// 未提交 PRESS 没有贡献，CANCEL 因而不能合成一次点击。
static inline AmclPointerPlan amclPointerRetire(AmclPointerTransaction* state) {
    AmclPointerPlan plan = {true, false, state->buttonDown ? 0 : -1};
    memset(state, 0, sizeof(*state));
    return plan;
}

// 平台线程只能撤销准入，pull consumer 才能领取末位 RELEASE。已提交贡献保留一条
// 具名退休计划；未提交动作立即清空。真实目标已毁的适配边缘仍须决定能否安全交付。
static inline void amclPointerRequestRetire(AmclPointerTransaction* state) {
    const bool held = state->buttonDown;
    (void)amclPointerRetire(state);
    state->buttonDown = held; state->releasePending = held;
}

// 普通 UP 保留 BEGIN 的正常结束身份，让随后 END 与 CANCEL 区分；旧无 BEGIN ABI
// 则由 UP 闭合。等待字段必须一起清理，不能让迟到的时钟重新建立旧贡献。
static inline void amclPointerFinishUp(AmclPointerTransaction* state) {
    state->buttonDown = state->pressPending = state->finalReleasePending = false;
    state->sourceFrameBaselinePending = false;
    state->pendingOrder = state->pendingSinceNs = state->pressAfterPresent = 0;
    if (!state->gestureBegun) memset(state, 0, sizeof(*state));
}

// 源点的实际输出完成后冻结呈现基线。GLFW 在 cursor callback 返回并重核 activation
// 后调用；SDL 在后继 Next 的具名维护点调用。不能把输出之前的并发帧算入等待。
static inline void amclPointerSourceDelivered(AmclPointerTransaction* state,
        uint64_t presentSerial, const AmclPointerDeliveryPolicy* policy) {
    if (!state->pressPending) return;
    state->pressAfterPresent = presentSerial + policy->presentFrames;
    state->sourceFrameBaselinePending = false;
}

// caller 先完成 scope/target/高水位准入，并在替换旧 token 前退休原贡献；本函数不重绑
// 陈旧载荷、不读取 current 全局，也不执行任何外部回调。Down 冻结源点和接受 order，
// Move/Up 只能作用于原 token。UP 末点先行由 plan.position 与 splitRelease 保证。
static inline AmclPointerPlan amclPointerAccept(AmclPointerTransaction* state,
        const AmclPointerDeliveryPolicy* policy, int phase, uint32_t token,
        double x, double y, bool endMoves, uint64_t order, uint64_t nowNs,
        uint64_t scopeEpoch, uint64_t targetEpoch) {
    AmclPointerPlan plan = {false, false, -1};
    if (!token || phase < AMCL_POINTER_MOVE || phase > AMCL_POINTER_END) return plan;
    if (phase == AMCL_POINTER_BEGIN || phase == AMCL_POINTER_DOWN) {
        const bool continuation = amclPointerIsContinuation(phase, token, state->token,
            state->gestureBegun, state->buttonDown || state->pressPending, state->downAccepted);
        // 高水位准入在 adapter 已校验；归约器也拒同token的非法重启，避免未来调用者
        // 略过外层检查时丢掉已经交付的贡献。新token替换仍由原目标先退休，再进入这里。
        if (token == state->token && !continuation) return plan;
        if (!continuation) memset(state, 0, sizeof(*state));
        state->token = token; state->scopeEpoch = scopeEpoch; state->inputTargetEpoch = targetEpoch;
        if (phase == AMCL_POINTER_BEGIN) state->gestureBegun = true;
        if (phase == AMCL_POINTER_DOWN) {
            state->downAccepted = true;
            state->sourceX = x; state->sourceY = y;
            if (policy->presentFrames) {
                state->pressPending = true; state->pendingOrder = order; state->pendingSinceNs = nowNs;
                state->sourceFrameBaselinePending = policy->sourceBaselineOnNext;
            } else { state->buttonDown = true; plan.contribution = 1; }
        }
    } else if (token != state->token) return plan;
    plan.accepted = true;
    plan.position = phase != AMCL_POINTER_CANCEL && (phase != AMCL_POINTER_END || endMoves);
    if (phase == AMCL_POINTER_UP || phase == AMCL_POINTER_END) {
        if (policy->splitRelease && state->buttonDown && plan.position) {
            state->finalReleasePending = true; state->finalReleaseClosesGesture = phase == AMCL_POINTER_END;
            state->pendingOrder = order;
        } else if (phase == AMCL_POINTER_UP) {
            plan.contribution = state->buttonDown ? 0 : -1; amclPointerFinishUp(state);
        } else {
            const AmclPointerPlan retired = amclPointerRetire(state); plan.contribution = retired.contribution;
        }
    } else if (phase == AMCL_POINTER_CANCEL) {
        const AmclPointerPlan retired = amclPointerRetire(state); plan.contribution = retired.contribution;
    }
    return plan;
}

enum AmclPointerAdvanceKind { AMCL_POINTER_WAIT, AMCL_POINTER_ACQUIRE,
    AMCL_POINTER_RELEASE, AMCL_POINTER_RESTORE_SOURCE, AMCL_POINTER_RETIRED };

// 推进待交付计划的唯一生产算法。invalid/取消/超时优先于普通 maxOrder，因它们撤销
// 资格而非把后来的数据插队。短 tap 的正常 END 不属于取消，调用者的扫描须保留该区别。
// current 是本 consumer 的实际基点；回调曾 warp 时先恢复冻结源点再重新跨真实帧。
static inline enum AmclPointerAdvanceKind amclPointerAdvance(AmclPointerTransaction* state,
        const AmclPointerDeliveryPolicy* policy, bool invalid, bool cancelled, bool expired,
        uint64_t maxOrder, uint64_t presentSerial, double currentX, double currentY) {
    if (invalid || state->releasePending || (state->pressPending && (cancelled || expired))) {
        const AmclPointerPlan retired = amclPointerRetire(state);
        return retired.contribution == 0 ? AMCL_POINTER_RELEASE : AMCL_POINTER_RETIRED;
    }
    if (state->finalReleasePending && state->pendingOrder <= maxOrder) {
        if (state->finalReleaseClosesGesture) amclPointerRetire(state);
        else amclPointerFinishUp(state);
        return AMCL_POINTER_RELEASE;
    }
    if (!state->pressPending) {
        if (state->token && !state->buttonDown && cancelled) {
            amclPointerRetire(state); return AMCL_POINTER_RETIRED;
        }
        return AMCL_POINTER_WAIT;
    }
    if (state->sourceFrameBaselinePending) {
        amclPointerSourceDelivered(state, presentSerial, policy); return AMCL_POINTER_WAIT;
    }
    if (state->pendingOrder > maxOrder || presentSerial < state->pressAfterPresent) return AMCL_POINTER_WAIT;
    if (currentX != state->sourceX || currentY != state->sourceY) {
        state->sourceFrameBaselinePending = policy->sourceBaselineOnNext;
        return AMCL_POINTER_RESTORE_SOURCE;
    }
    state->pressPending = false; state->pendingOrder = 0; state->buttonDown = true;
    return AMCL_POINTER_ACQUIRE;
}

#endif
