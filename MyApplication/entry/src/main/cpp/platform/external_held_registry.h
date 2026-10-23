// external_held_registry.h — 经 NAPI 下来的"持续按下态"按端记账
//
// ============================ 它管什么 ============================
//
// 本项目有三个平级输入端（见 input_source.h）。其中**经 ArkTS/NAPI 产出**的那些持续
// 按下态汇集在这张表里：
//   · 手柄端         —— 按钮 / 扳机 / HAT / 左摇杆 WASD
//   · 触控虚拟按键端 —— 菜单态与 handledBy=arkts 的按钮
//   · 平台手势       —— 系统返回键合成的 ESC（瞬时 tap，进出成对）
// 物理键鼠端**不在**这里：它走 legacy_physical_edge_router 的专用身份
// （deviceId + 原生键码），有自己的 owner 域与测试。
//
// ============================ 为什么必须按端隔离 ============================
//
// 旧实现只存 `vector<OwnerToken>`，RELEASE 取队首。于是：
//   · 端 A 的抬起会拿走端 B 的 owner（聚合边沿仍守恒，但归属互换）；
//   · REPEAT 同样取队首，B 的重复会延长 A 的持有；
//   · **没有任何按端释放的能力** —— 拔一个手柄只能全局 releaseAll，
//     连带把屏幕虚拟按键的按下态一起放掉。
//
// 控件租约优先以source/device/control+token配对；旧匿名接口才使用下述兼容策略：
//   · RELEASE / REPEAT 只在**同端**的记录里找，找不到就是无配对边沿；
//   · 同端内部**从后往前**（LIFO）—— 同一端连续按下同一输出时，后按的先抬是更自然的
//     嵌套语义，且与"最近一次按下"对应，便于日志判读。
//
// ============================ 线程与纯度 ============================
//
// 本类**不含锁**：公共LegacyOutputRuntime借registryMutex串行化调用，
// 而那把锁是全局锁序里的最内层。把锁留在调用方是刻意的 —— 这样本类是纯数据结构，
// 可以在主机侧被完整测试；而它承载的正是"抬起拿错 owner"这类**静默**故障，
// 恰恰最需要测试覆盖。不要在这里加 mutex 或 hilog。
#ifndef AMCL_PLATFORM_EXTERNAL_HELD_REGISTRY_H
#define AMCL_PLATFORM_EXTERNAL_HELD_REGISTRY_H

#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include "input_ledger.h"
#include "input_source.h"

namespace amcl::input {

struct ExternalHeldRecord {
    AmclInputSource source = AMCL_INPUT_SOURCE_NONE;
    OwnerToken owner = 0;
    // 有身份的控件只能通过精确 token 释放，兼容 LIFO 接口不能认领它。
    bool controlled = false;
};

// 一个前端实例中的设备/控件身份；control 已由前端加实例命名空间，重建页面不会复用。
struct ExternalControlIdentity {
    AmclInputSource source;
    uint64_t device;
    std::string control;
    bool operator<(const ExternalControlIdentity& other) const {
        return std::tie(source, device, control) < std::tie(other.source, other.device, other.control);
    }
};
struct ExternalControlLease {
    OwnerToken owner = 0;
    std::vector<Output> outputs;
};
struct ExternalControlAcquire {
    OwnerToken owner = 0;
    bool created = false;
};

class ExternalHeldRegistry final {
public:
    // 输出在按下时冻结。重复同身份/同绑定返回原 token；持有期间改绑定必须先释放，
    // 不允许凭当前布局解释旧 UP。newOwner 必须由全局单调分配器产生，不能复用。
    ExternalControlAcquire AcquireControl(const ExternalControlIdentity& identity,
        const std::vector<Output>& outputs, OwnerToken newOwner);
    // 精确摘除旧租约并返回按下时输出；空结果是已被复位/释放，可幂等处理。
    std::vector<Output> TakeControl(OwnerToken owner);
    bool HasControl(OwnerToken owner) const;
    // 登记一次按下。`owner` 由调用方分配（全局单调），本类不生成 token。
    // owner==0 被拒绝：0 是"无 owner"的哨兵值，存进表里会让后续配对返回一个假成功。
    bool Acquire(const Output& output, AmclInputSource source, OwnerToken owner);

    // REPEAT 用：读同端最近一条记录，**不消费**。重复不应改变持有集合。
    // 返回 0 = 该端在这个输出上没有配对的按下。
    OwnerToken PeekSameSource(const Output& output, AmclInputSource source) const;

    // RELEASE 用：取出并摘除同端最近一条记录。返回 0 = 无配对的按下（应丢弃该边沿）。
    OwnerToken TakeSameSource(const Output& output, AmclInputSource source);

    // PRESS 回滚专用：精确摘除 `(output, source, owner)` 这一条记录，用于 Acquire 之后
    // ledger 拒绝的情形（见 external_held_edge_router.h）。按 owner 匹配而不是 LIFO，
    // 不会误摘同端其它记录；计入 released，使 acquired - released == live 保持成立。
    // 返回 false = 表中没有这条记录，此时不改变任何状态。
    bool Forget(const Output& output, AmclInputSource source, OwnerToken owner);

    // 按端选择性释放：摘出该端**全部**记录并交给调用方逐个释放。
    // 调用方必须在放开锁之后再释放（ledger 的 emit 可能同步回调进来）。
    std::vector<std::pair<Output, OwnerToken>> DrainSource(AmclInputSource source);

    // 全清（生命周期 cancel）。不产生边沿，调用方负责 ledger 侧的 releaseAll。
    void Clear();

    // ---- 诊断读取口（供不变量自检） ----
    std::size_t LiveCountForSource(AmclInputSource source) const;
    std::size_t LiveTotal() const;

    // 当前同一(output,source)的最大记录数。0 = 表空；不同有身份控件可合法大于1。
    //
    // ⭐ **它是规范 §3.3 那条幽灵 owner 的直接特征量，而此前那个状态没有任何数能反映它。**
    // 因果回顾：surface 几何变化只推进 typed core 那一半的 reset epoch，本表不动 ⇒ 端侧
    // 丢缓存后不再发 RELEASE ⇒ 旧 owner 永久留下 ⇒ 下一次 PRESS 又 `Acquire` 一条**新**
    // owner（`nextOwnerToken()` 单调、无去重）⇒ 同一 `(output, source)` 变成 2 条，
    // 而 LIFO 只取回新那条，旧那条压在栈底永远取不走。
    // ⚠️ **那个状态下 `acquired - released == live` 依然成立**（幽灵记录确实是 live 的），
    // 所以 `AMCL_INV_HELD_BALANCE` 结构上抓不到它 —— 本函数是补上那个盲区的观测面。
    //
    // ⚠️ **刻意只做"可以数的数"，不直接做成告警位。** 依据 AGENTS.md §二.1：推断出的成因
    // 不得直接拿去改代码，先让它变成一个可以数的数。"同端多于一条是否在任何合法场景下都
    // 不可能"目前是 B 级判断（三端的 ArkTS 侧都有自己的按下态去重，但没有任何机械手段
    // 证明穷举完了）—— 而一个误报过的不变量位会让整套自检失去可信度。
    // ⇒ 先让它在 `AMCL_INSRC` 里可读，攒到真机证据再决定要不要升级成不变量。
    std::size_t MaxRecordsForSameSource() const;
    // 累计登记 / 释放次数。`Clear()` 计入 released（它确实让那些记录不再持有）。
    std::uint32_t AcquiredForSource(AmclInputSource source) const;
    std::uint32_t ReleasedForSource(AmclInputSource source) const;
    /** neutral 候选的正式提交只交换 map 节点与标量；不能用整个对象 std::swap，
     * MSVC 的 map move 构造可能新分配 sentinel，导致运输封存后再抛 bad_alloc。
     * 这里只在原 registry 事务锁覆盖下使用，不是跨 DSO ABI。 */
    void SwapState(ExternalHeldRegistry& candidate) noexcept;

private:
    static bool InRange(AmclInputSource source);

    std::map<Output, std::vector<ExternalHeldRecord>> byOutput_;
    std::map<ExternalControlIdentity, ExternalControlLease> controls_;
    std::uint32_t acquired_[AMCL_INPUT_SOURCE_COUNT] = {};
    std::uint32_t released_[AMCL_INPUT_SOURCE_COUNT] = {};
};

}  // namespace amcl::input

#endif  // AMCL_PLATFORM_EXTERNAL_HELD_REGISTRY_H
