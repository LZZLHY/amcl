#include "../../platform/look_pipeline_stats.h"
#include "../../platform/look_delta_math.h"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>

using namespace amcl::input;

namespace {
[[noreturn]] void Fail(const char* expression, int line) {
    std::cerr << "LOOK PIPELINE STATS FAIL line " << line << ": "
              << expression << '\n';
    std::exit(1);
}
#define CHECK(e) do { if (!(e)) Fail(#e, __LINE__); } while (0)
}  // namespace

int main() {
    // 空快照必须自洽（0 == 0），否则"守恒"在第一帧就是假的。
    {
        LookPipelineStats stats;
        CHECK(stats.ConservationHolds(0.0));
        CHECK(stats.Snapshot().accepted == 0u);
    }

    // ⭐ 核心恒等式：Σemit + backlog + discarded == Σscaled（逐轴）。
    // 这条此前没有任何断言钉住，而它正是 applyLookDelta 头注释承诺的那句
    // "任意手势的总输出严格等于灵敏度/加速后的总输入"（计划 §88）。
    {
        LookPipelineStats stats;
        stats.NoteAccepted(10.0, -4.0, 6.0, -2.4, 4.0, -1.6);
        CHECK(stats.ConservationHolds(1e-12));
        stats.NoteAccepted(5.0, 0.0, 5.4, -0.96, 3.6, -0.64);
        CHECK(stats.ConservationHolds(1e-12));
        CHECK(stats.Snapshot().accepted == 2u);
        CHECK(stats.Snapshot().emitted == 2u);
    }

    // 正常 UP 补齐余量：backlog 归零、守恒仍然成立、且计入 emit 而不是 discard。
    {
        LookPipelineStats stats;
        stats.NoteAccepted(10.0, 0.0, 6.0, 0.0, 4.0, 0.0);
        stats.NoteFlush(true, 4.0, 0.0);
        CHECK(stats.ConservationHolds(1e-12));
        CHECK(stats.Snapshot().backlogDx == 0.0);
        CHECK(stats.Snapshot().flushEmit == 1u && stats.Snapshot().flushDiscard == 0u);
        CHECK(std::fabs(stats.Snapshot().emitDx - 10.0) < 1e-12);
        CHECK(stats.Snapshot().discardedDx == 0.0);
    }

    // ⭐ 边界丢弃：守恒**仍然成立**，但丢掉的量记在 discarded 上 —— 这是唯一能把
    // "位移被丢弃"与"通道根本没来"区分开的量，两者在今天的日志里长得一样。
    {
        LookPipelineStats stats;
        stats.NoteAccepted(10.0, 0.0, 6.0, 0.0, 4.0, 0.0);
        stats.NoteFlush(false, 4.0, 0.0);
        CHECK(stats.ConservationHolds(1e-12));
        CHECK(stats.Snapshot().flushDiscard == 1u);
        CHECK(std::fabs(stats.Snapshot().discardedDx - 4.0) < 1e-12);
        CHECK(std::fabs(stats.Snapshot().emitDx - 6.0) < 1e-12);
    }

    // emit 恒零的样本仍算 accepted，但不算 emitted（亚阈值/平滑首帧）。
    {
        LookPipelineStats stats;
        stats.NoteAccepted(1.0, 0.0, 0.0, 0.0, 1.0, 0.0);
        CHECK(stats.Snapshot().accepted == 1u && stats.Snapshot().emitted == 0u);
        CHECK(stats.ConservationHolds(1e-12));
    }

    // maxBacklog 只增不减：它是"平滑到底攒了多少"的唯一可见量。
    {
        LookPipelineStats stats;
        stats.NoteAccepted(10.0, 0.0, 6.0, 0.0, 4.0, 0.0);
        CHECK(std::fabs(stats.Snapshot().maxBacklog - 4.0) < 1e-12);
        stats.NoteAccepted(1.0, 0.0, 4.4, 0.0, 0.6, 0.0);
        CHECK(std::fabs(stats.Snapshot().maxBacklog - 4.0) < 1e-12);
        CHECK(std::fabs(stats.Snapshot().backlogDx - 0.6) < 1e-12);
    }

    // 非有限值绝不进累计量：一个 inf 会让整份快照此后永久不可读。
    {
        LookPipelineStats stats;
        stats.NoteAccepted(1.0, 0.0, 1.0, 0.0, 0.0, 0.0);
        const double before = stats.Snapshot().scaledDx;
        const double nan = std::numeric_limits<double>::quiet_NaN();
        const double inf = std::numeric_limits<double>::infinity();
        stats.NoteAccepted(nan, 0.0, 0.0, 0.0, 0.0, 0.0);
        stats.NoteAccepted(1.0, inf, 0.0, 0.0, 0.0, 0.0);
        stats.NoteAccepted(1.0, 0.0, nan, 0.0, 0.0, 0.0);
        stats.NoteAccepted(1.0, 0.0, 0.0, 0.0, inf, 0.0);
        stats.NoteFlush(true, nan, 0.0);
        CHECK(stats.Snapshot().scaledDx == before);
        CHECK(stats.Snapshot().accepted == 1u);
        CHECK(stats.Snapshot().rejected == 5u);
        CHECK(stats.ConservationHolds(1e-12));
    }

    // 负公差必须判假（而不是恰好因为差值是 0 而蒙对）。
    // ⭐ travel（Σ|scaled|）与 scaled（带符号净位移）必须是两个独立的量。
    // 这条用例存在的理由是一次真实误判：拿带符号的 scaled 跨包对比同一套手势，得到
    // 3069 vs 115 并据此怀疑链路有 20 倍缩放，而链路上一处缩放都没有 —— 差的全是
    // 来回扫互相抵消（计划 §90.4）。往复序列净位移为 0 而行程不为 0，正是这条区别。
    {
        LookPipelineStats stats;
        // 右 10、左 10：净位移 0，行程 20。
        stats.NoteAccepted(10.0, 0.0, 10.0, 0.0, 0.0, 0.0);
        stats.NoteAccepted(-10.0, 0.0, -10.0, 0.0, 0.0, 0.0);
        CHECK(std::fabs(stats.Snapshot().scaledDx) < 1e-12);
        CHECK(std::fabs(stats.Snapshot().travelDx - 20.0) < 1e-12);
        // 恒等式仍然只认带符号的那份，不受 travel 影响。
        CHECK(stats.ConservationHolds(1e-12));
        // 单向序列下两者必须相等 —— 否则 travel 自己就是错的。
        LookPipelineStats oneWay;
        oneWay.NoteAccepted(3.0, -4.0, 3.0, -4.0, 0.0, 0.0);
        oneWay.NoteAccepted(5.0, -6.0, 5.0, -6.0, 0.0, 0.0);
        CHECK(std::fabs(oneWay.Snapshot().travelDx - oneWay.Snapshot().scaledDx) < 1e-12);
        CHECK(std::fabs(oneWay.Snapshot().travelDy + oneWay.Snapshot().scaledDy) < 1e-12);
        // 非有限值被拒时 travel 不得被污染（与 scaled 同一条纪律）。
        const double before = stats.Snapshot().travelDx;
        stats.NoteAccepted(std::numeric_limits<double>::quiet_NaN(), 0.0,
                           0.0, 0.0, 0.0, 0.0);
        CHECK(stats.Snapshot().travelDx == before);
    }

    {
        LookPipelineStats stats;
        CHECK(!stats.ConservationHolds(-1.0));
        CHECK(!stats.ConservationHolds(std::numeric_limits<double>::quiet_NaN()));
    }

    // ⭐ 与真实 math 串起来：直接喂 ComputeLookDeltaMath 的输出，守恒必须成立。
    // 这一条把恒等式钉在**产品那份数学**上，而不是钉在我手写的数字上。
    {
        LookPipelineStats stats;
        LookDeltaMathInput input{};
        input.sensitivity = 1.5;
        input.smoothAlpha = 0.6;
        input.acceleration = 0.0;
        int64_t now = 1000000000LL;
        double pendingDx = 0.0;
        double pendingDy = 0.0;
        int64_t last = 0;
        for (int i = 0; i < 12; ++i) {
            input.dx = (i % 3 == 0) ? 7.0 : -2.5;
            input.dy = (i % 2 == 0) ? -1.25 : 3.0;
            input.pendingDx = pendingDx;
            input.pendingDy = pendingDy;
            input.lastTimeNs = last;
            input.nowTimeNs = now;
            LookDeltaMathOutput out{};
            CHECK(ComputeLookDeltaMath(input, &out));
            // scaled = 本次进入 backlog 的量 = emit + 新 pending - 旧 pending。
            const double scaledDx = out.emitDx + out.pendingDx - pendingDx;
            const double scaledDy = out.emitDy + out.pendingDy - pendingDy;
            stats.NoteAccepted(scaledDx, scaledDy, out.emitDx, out.emitDy,
                               out.pendingDx, out.pendingDy);
            CHECK(stats.ConservationHolds(1e-9));
            pendingDx = out.pendingDx;
            pendingDy = out.pendingDy;
            last = out.lastTimeNs;
            now += 16700000LL;
        }
        // 收尾补齐之后 backlog 必须归零，守恒仍成立。
        stats.NoteFlush(true, pendingDx, pendingDy);
        CHECK(stats.Snapshot().backlogDx == 0.0 && stats.Snapshot().backlogDy == 0.0);
        CHECK(stats.ConservationHolds(1e-9));
        CHECK(stats.Snapshot().accepted == 12u);
        // 灵敏度 1.5 全程生效 ⇒ Σscaled 必须是 Σ原始输入的 1.5 倍（本例 dy 亦然）。
        CHECK(std::fabs(stats.Snapshot().scaledDx - 1.5 * (4 * 7.0 + 8 * -2.5)) < 1e-9);
    }

    // Reset 必须把每一项归零，否则跨会话快照会互相污染。
    {
        LookPipelineStats stats;
        stats.NoteAccepted(3.0, 3.0, 1.0, 1.0, 2.0, 2.0);
        stats.NoteRejected();
        stats.Reset();
        CHECK(stats.Snapshot().accepted == 0u && stats.Snapshot().rejected == 0u);
        CHECK(stats.Snapshot().scaledDx == 0.0 && stats.Snapshot().maxBacklog == 0.0);
        // 新字段也必须被 Reset 归零，否则"逐项归零"这条断言对它是空真。
        CHECK(stats.Snapshot().travelDx == 0.0 && stats.Snapshot().travelDy == 0.0);
        CHECK(stats.ConservationHolds(0.0));
    }

    std::cout << "look_pipeline_stats_test: PASS\n";
    return 0;
}
