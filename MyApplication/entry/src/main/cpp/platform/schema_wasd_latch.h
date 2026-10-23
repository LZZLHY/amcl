// schema_wasd_latch.h — native 触控摇杆 WASD 的 30ms 重按锁存与到期补发
//
// 职责：记住每个方向“是否已按下 / 最近一次想要什么 / 何时松开 / 何时可以补发”，把一次摇杆
// 采样变成最终的 PRESS / RELEASE 边沿。30ms 锁存用于吞掉扇区边界抖动：刚 RELEASE 的方向在
// 锁存窗内再次进入时不立即 PRESS。
//
// 为什么需要到期补发：旧实现只在下一次摇杆采样时重试被锁存吞掉的 PRESS。手指在 30ms 内
// 回到原方向后若静止不动（不再产生 MOVE），该方向会一直不按下 —— 摇杆可见地偏着、玩家不动，
// 直到手指再动或抬起。现在被吞掉的 PRESS 记一个期限（松开时刻 + 30ms），由既有的 schema
// deadline worker 在期限到达时补发；期限到时若手指已离开摇杆或不再想要该方向，只清期限。
//
// 线程与锁：纯状态机，不含锁与日志。产品里所有调用都在 s_schemaMutex 内（触摸 ingress、
// schema 替换、grab 翻转与 deadline worker 都持这把锁），边沿回调在同一锁内同步执行，
// 锁序与 longPress 相同：schema → input transaction → ledger → ring。
#ifndef AMCL_PLATFORM_SCHEMA_WASD_LATCH_H
#define AMCL_PLATFORM_SCHEMA_WASD_LATCH_H

namespace amcl::input {

class SchemaWasdLatch final {
public:
    static constexpr int kDirections = 4;                      // 0..3 = W / A / S / D
    static constexpr long long kRepressLockoutNs = 30000000LL;  // 30ms，与 ArkTS 摇杆同值

    // 应用一次摇杆采样。want 是本次扇区判定结果；emit(direction, press) 同步发出最终边沿。
    // 锁存窗内被吞掉的 PRESS 记下补发期限，调用方应随后唤醒 deadline worker。
    template <typename Emit>
    void Apply(const bool (&want)[kDirections], long long nowNs, Emit&& emit) {
        for (int i = 0; i < kDirections; ++i) {
            want_[i] = want[i];
            if (want[i] && !held_[i]) {
                // releaseNs_ 为 0 表示本方向从未松开过，没有需要去抖的边界。
                if (releaseNs_[i] != 0 && nowNs - releaseNs_[i] < kRepressLockoutNs) {
                    retryNs_[i] = releaseNs_[i] + kRepressLockoutNs;
                    continue;
                }
                emit(i, true);
                held_[i] = true;
                retryNs_[i] = 0;
            } else if (!want[i]) {
                if (held_[i]) {
                    emit(i, false);
                    held_[i] = false;
                    releaseNs_[i] = nowNs;
                }
                retryNs_[i] = 0;   // 不再想要该方向，挂起的补发作废
            }
        }
    }

    // 到期补发。只补发“期限已到、仍想要、仍未按下”的方向；fingerBound=false（摇杆手指已不在）
    // 时只清期限。每个到期方向的期限都会被清掉，因此 worker 不会对同一期限反复醒来。
    template <typename Emit>
    void PollDue(long long nowNs, bool fingerBound, Emit&& emit) {
        for (int i = 0; i < kDirections; ++i) {
            if (retryNs_[i] == 0 || nowNs < retryNs_[i]) continue;
            retryNs_[i] = 0;
            if (!fingerBound || !want_[i] || held_[i]) continue;
            emit(i, true);
            held_[i] = true;
        }
    }

    // 最近一个仍然有效的补发期限；0 表示没有。worker 用它计算下一次醒来的时刻。
    long long EarliestDeadline() const {
        long long earliest = 0;
        for (int i = 0; i < kDirections; ++i) {
            if (retryNs_[i] == 0 || !want_[i] || held_[i]) continue;
            if (earliest == 0 || retryNs_[i] < earliest) earliest = retryNs_[i];
        }
        return earliest;
    }

    // 复位全部方向且不发边沿：调用方（schema 替换 / grab 翻转 / 生命周期取消）已经在 ledger 里
    // 释放了 WASD 专用 owner，这里只清状态，防止旧期限在新 generation 里补发 PRESS。
    void Reset() {
        for (int i = 0; i < kDirections; ++i) {
            held_[i] = false;
            want_[i] = false;
            releaseNs_[i] = 0;
            retryNs_[i] = 0;
        }
    }

    bool held(int direction) const { return InRange(direction) && held_[direction]; }
    long long deadline(int direction) const {
        return InRange(direction) ? retryNs_[direction] : 0;
    }

private:
    static constexpr bool InRange(int direction) {
        return direction >= 0 && direction < kDirections;
    }

    bool held_[kDirections] = {false, false, false, false};
    bool want_[kDirections] = {false, false, false, false};
    long long releaseNs_[kDirections] = {0, 0, 0, 0};
    long long retryNs_[kDirections] = {0, 0, 0, 0};
};

}  // namespace amcl::input

#endif  // AMCL_PLATFORM_SCHEMA_WASD_LATCH_H
