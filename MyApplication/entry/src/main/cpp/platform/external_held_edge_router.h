// external_held_edge_router.h — 经 NAPI 下来的按端持有边沿：registry × ledger 组合事务
//
// 职责：把一次“端 + 输出 + 动作”请求同时落到两本账上，并如实报告两件不同的事：
//   · 本端的持有变更是否已经生效（NAPI 按端入口返回给 ArkTS 的只有这一件）；
//   · 是否因此向游戏发出了最终聚合边沿（只供诊断与测试，不外传）。
// 两本账：ExternalHeldRegistry 按 (Output, AmclInputSource) 配对本端记录（规范 §二 第 1b 层），
// InputLedger 按 Output 对全部 owner 做引用计数（第 2 层）。二者此前由同一个 bool 表达，
// 另一端已持有同一输出时本端登记成功却报 false，ArkTS 判为“被拒”，于是留下幽灵 owner
// 或让该键此后失灵。因果与取舍见计划 §127。
//
// 线程与锁：本 TU 不含 hilog，也不拥有锁。registryMutex 由调用方传入，只包住 registry 操作；
// ledger 转换与 emit 在该锁之外执行（emit 可能同步回入输入模块，而该锁是全局锁序最内层）。
// 事务锁与复位围栏由调用方负责：touch_input.cpp 在 s_inputTransactionMutex 内、
// 且确认 ResetInProgress 已放行之后才调用 Route。
#ifndef AMCL_PLATFORM_EXTERNAL_HELD_EDGE_ROUTER_H
#define AMCL_PLATFORM_EXTERNAL_HELD_EDGE_ROUTER_H

#include <cstdint>
#include <mutex>

#include "external_held_registry.h"
#include "input_ledger.h"
#include "input_source.h"

namespace amcl::input {

// 请求动作，与 GLFW 动作码解耦；GLFW 值到本枚举的映射与“未知动作拒绝”由调用方完成。
enum class ExternalHeldAction : uint8_t {
    Press = 0,
    Repeat = 1,
    Release = 2,
};

// 一次请求的结果。Rejected 意味着本端在 registry 中的记录没有任何改变；
// 其余两个值都表示本端持有变更已经生效，差别只在是否发出了最终聚合边沿。
enum class ExternalHeldEdgeResult : uint8_t {
    Rejected = 0,
    // 已生效但没有最终边沿：另一 owner 仍持有该输出，或 ledger 早已不再持有被摘除的 owner。
    AppliedNoFinalEdge = 1,
    // 已生效且发出了最终边沿：首个 owner 的 PRESS、同端记录的 REPEAT、末位 owner 的 RELEASE。
    AppliedEmitted = 2,
};

// NAPI 按端入口的唯一判据：本端持有变更是否已生效。调用方据 false 保留自身状态以便重试。
constexpr bool ExternalHeldEdgeApplied(ExternalHeldEdgeResult result) {
    return result != ExternalHeldEdgeResult::Rejected;
}

class ExternalHeldEdgeRouter final {
public:
    // 有身份控件的整组绑定事务。调用者持 inputTransaction 递归锁；内部 registry 锁
    // 只用于记账，任何 ledger emit 均在它之外，允许同步生命周期回调。
    OwnerToken AcquireControl(const ExternalControlIdentity& identity,
        const std::vector<Output>& outputs, OwnerToken newOwner);
    bool ReleaseControl(OwnerToken owner);
    // 三个引用都必须指向同一个 neutral LegacyOutputRuntime 的内部对象或其事务候选，
    // 本类只借用、不拷贝，也不管理它们的生命周期。
    ExternalHeldEdgeRouter(ExternalHeldRegistry& registry, std::mutex& registryMutex,
                           InputLedger& ledger);

    // 处理一次按端请求，规则逐条：
    //   · Press：先以 pressOwner 登记本端记录，再交 ledger 获取；pressOwner 由调用方从全局单调
    //     序列分配，0 视为非法。ledger 拒绝时（新 token 下结构上不可达）精确回滚刚登记的记录。
    //   · Repeat：只读同端最近一条记录、不消费，交 ledger 送 REPEAT；ledger 不认该 owner 即拒绝。
    //   · Release：先摘除同端最近一条记录，再交 ledger 释放；记录已摘除即视为生效。
    // 无配对记录、越界端身份、非法 owner 一律 Rejected，且不触碰 ledger。
    ExternalHeldEdgeResult Route(AmclInputSource source, const Output& output,
                                 ExternalHeldAction action, OwnerToken pressOwner);

private:
    ExternalHeldEdgeResult Press(AmclInputSource source, const Output& output,
                                 OwnerToken owner);
    ExternalHeldEdgeResult Repeat(AmclInputSource source, const Output& output);
    ExternalHeldEdgeResult Release(AmclInputSource source, const Output& output);

    ExternalHeldRegistry& registry_;
    std::mutex& registryMutex_;
    InputLedger& ledger_;
};

}  // namespace amcl::input

#endif  // AMCL_PLATFORM_EXTERNAL_HELD_EDGE_ROUTER_H
