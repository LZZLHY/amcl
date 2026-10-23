// legacy_ring_discontinuity.h — legacy ring 丢历史之后，libentry 侧 legacy owner 的对账
//
// 背景：历史实现会在某个消费者落后时只清该消费者，producer账本却仍保留owner。
// 当前普通consumer overflow已改成从同锁生产镜像恢复当前aggregate held与严格cutoff，
// 因而不会推进全生产epoch；本服务只承接无法绑定可靠快照的真正全生产不连续。
// 旧问题中libentry这边的ExternalHeldRegistry、
// InputLedger、schema owner 却仍认为这些输出按着：同一输出有两个以上 owner 时，其中一个松开
// 再按下被 ledger 判为“已持有”而吞掉 PRESS，游戏侧这个键直到所有 owner 都离开才恢复。
//
// 契约（bridge 与 libentry 两侧）：
//   · bridge 在无法使用局部生产快照的真正不连续时把一个单调 epoch 加一，并经强链接的
//     `inputBridge_legacyRingDiscontinuityEpochV1` 无锁导出；生产者检测仍只置标志。
//   · libentry 只在自己的无锁入口与 250ms 心跳读 epoch（从不在 bridge 消费者线程、sendEvent、
//     ledger emit 或 grab trampoline 里读），发现变化后按全局锁序执行一次 legacy-only 复位：
//     external held → ledger → schema → 菜单 token → 仍按下的手指作废至 UP → 前端复位边界。
//   · 刻意不做：不清通道配对（typed 物理按钮的 UP 仍需配对才能进 core）、不复位 typed core、
//     不改 capture、不丢 look backlog（look 不经 ring）、不清 finger 注册表（平台仍会送来 UP）。
//   · 完整 `ohos_cancel_all_input` 覆盖它开始时读到的 epoch：只登记，不再重复复位。
//
// 本 TU 不含锁与日志：锁序与复位步骤的具体实现由 touch_input.cpp 提供，这里只固定判定与顺序，
// 从而能在 host 测试里直接链接产品代码验证（legacy_ring_discontinuity_test.cpp）。
#ifndef AMCL_PLATFORM_LEGACY_RING_DISCONTINUITY_H
#define AMCL_PLATFORM_LEGACY_RING_DISCONTINUITY_H

#include <atomic>
#include <cstddef>
#include <cstdint>

namespace amcl::input {

// 一次 legacy-only 复位的全部步骤。函数指针由 touch_input.cpp 绑定到文件级状态；
// 任何一项为空都视为装配错误，整次复位拒绝执行（见 LegacyRingResetStepsComplete）。
struct LegacyRingResetSteps {
    void* context = nullptr;
    void (*clearExternalHeld)(void* context) = nullptr;        // 第 1b 层：按端持有表整表清空
    void (*releaseLedgerOwners)(void* context) = nullptr;      // 第 2 层：RELEASE 经 ring 下发
    void (*resetSchemaTransient)(void* context) = nullptr;     // 第 1c 层：schema owner / WASD / 绑定
    void (*cancelMenuTransaction)(void* context) = nullptr;    // 以原 token 撤销菜单指针事务
    void (*retireFingersStillDown)(void* context) = nullptr;   // 仍按下的手指作废直到 UP
    void (*completeResetBoundary)(void* context) = nullptr;    // 推进前端复位 epoch，驱动 ArkTS 对账
};

bool LegacyRingResetStepsComplete(const LegacyRingResetSteps& steps);

// 按固定顺序执行全部步骤。调用方必须已持有 surface gate → touch state → schema →
// input transaction，并处在 LegacyPhysicalEdgeRouter 的复位围栏内。
void RunLegacyRingReset(const LegacyRingResetSteps& steps);

// 把“仍按下”的手指标成作废直到 UP；down 数组本身不改（平台仍会送来这些手指的 MOVE/UP）。
void MarkFingersDeadUntilUp(const bool* fingerDown, bool* fingerDead, size_t count);

class LegacyRingDiscontinuityTracker final {
public:
    // 无锁快速路径（任意 libentry 入口线程）：observed 与已消费值不同即需要进入慢路径。
    bool Changed(uint64_t observedEpoch) const;

    // 慢路径。observedEpoch 必须在调用方持锁之后重新读取；与已消费值相同（另一入口刚完成对账）
    // 返回 false 且不执行任何步骤；不同则执行 RunLegacyRingReset，完成后才登记为已消费。
    bool ReconcileLocked(uint64_t observedEpoch, const LegacyRingResetSteps& steps);

    // 完整生命周期 cancel 已清空全部 legacy 状态：登记它开始时读到的 epoch，不再重复复位。
    // 与 Changed 一样按“与已消费值不同”判定而不比较大小：epoch 只是不连续事件的身份标签。
    void AbsorbLocked(uint64_t observedEpoch);

    uint64_t ConsumedEpoch() const;
    uint64_t ResetCount() const;
    uint64_t AbsorbCount() const;

private:
    std::atomic<uint64_t> consumed_{0u};
    std::atomic<uint64_t> resets_{0u};
    std::atomic<uint64_t> absorbed_{0u};
};

}  // namespace amcl::input

#endif  // AMCL_PLATFORM_LEGACY_RING_DISCONTINUITY_H
