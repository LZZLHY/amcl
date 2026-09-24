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
// 配对规则（本文件的全部策略）：
//   · RELEASE / REPEAT 只在**同端**的记录里找，找不到就是无配对边沿；
//   · 同端内部**从后往前**（LIFO）—— 同一端连续按下同一输出时，后按的先抬是更自然的
//     嵌套语义，且与"最近一次按下"对应，便于日志判读。
//
// ============================ 线程与纯度 ============================
//
// 本类**不含锁**：调用方（touch_input.cpp）在 `s_externalInputMutex` 下使用它，
// 而那把锁是全局锁序里的最内层。把锁留在调用方是刻意的 —— 这样本类是纯数据结构，
// 可以在主机侧被完整测试；而它承载的正是"抬起拿错 owner"这类**静默**故障，
// 恰恰最需要测试覆盖。不要在这里加 mutex 或 hilog。
#ifndef AMCL_PLATFORM_EXTERNAL_HELD_REGISTRY_H
#define AMCL_PLATFORM_EXTERNAL_HELD_REGISTRY_H

#include <cstddef>
#include <cstdint>
#include <map>
#include <utility>
#include <vector>

#include "input_ledger.h"
#include "input_source.h"

namespace amcl::input {

struct ExternalHeldRecord {
    AmclInputSource source = AMCL_INPUT_SOURCE_NONE;
    OwnerToken owner = 0;
};

class ExternalHeldRegistry final {
public:
    // 登记一次按下。`owner` 由调用方分配（全局单调），本类不生成 token。
    // owner==0 被拒绝：0 是"无 owner"的哨兵值，存进表里会让后续配对返回一个假成功。
    bool Acquire(const Output& output, AmclInputSource source, OwnerToken owner);

    // REPEAT 用：读同端最近一条记录，**不消费**。重复不应改变持有集合。
    // 返回 0 = 该端在这个输出上没有配对的按下。
    OwnerToken PeekSameSource(const Output& output, AmclInputSource source) const;

    // RELEASE 用：取出并摘除同端最近一条记录。返回 0 = 无配对的按下（应丢弃该边沿）。
    OwnerToken TakeSameSource(const Output& output, AmclInputSource source);

    // 按端选择性释放：摘出该端**全部**记录并交给调用方逐个释放。
    // 调用方必须在放开锁之后再释放（ledger 的 emit 可能同步回调进来）。
    std::vector<std::pair<Output, OwnerToken>> DrainSource(AmclInputSource source);

    // 全清（生命周期 cancel）。不产生边沿，调用方负责 ledger 侧的 releaseAll。
    void Clear();

    // ---- 诊断读取口（供不变量自检） ----
    std::size_t LiveCountForSource(AmclInputSource source) const;
    std::size_t LiveTotal() const;

    // 当前"同一个 `(output, source)` 上堆了几条记录"的最大值。1 = 正常，0 = 表空。
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

private:
    static bool InRange(AmclInputSource source);

    std::map<Output, std::vector<ExternalHeldRecord>> byOutput_;
    std::uint32_t acquired_[AMCL_INPUT_SOURCE_COUNT] = {};
    std::uint32_t released_[AMCL_INPUT_SOURCE_COUNT] = {};
};

}  // namespace amcl::input

#endif  // AMCL_PLATFORM_EXTERNAL_HELD_REGISTRY_H
