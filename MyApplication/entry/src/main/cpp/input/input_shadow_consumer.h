#ifndef AMCL_INPUT_SHADOW_CONSUMER_H
#define AMCL_INPUT_SHADOW_CONSUMER_H

#include "amcl_input_api.h"

namespace amcl::input::shadow {

struct DrainResult {
    // completed is true only after nextEvent reaches EMPTY; every host error,
    // including STALE, leaves it false so recovery can fail closed.
    bool completed;
    bool observedResetState;
    bool observedReset;
    bool resetLatched;
    bool staleConsumer;
    // 最新 RESET 的全局权威代次；局部基线/退休重复原值。0 表示旧宿主不提供该信息。
    uint64_t resetAuthorityEpoch = 0u;
};

// forceReopen is used at session boundaries where a cached handle can no
// longer be proven to belong to the session being created.
bool Open(const AmclInputHostApiV1* api, bool forceReopen = false);
DrainResult Drain(const AmclInputHostApiV1* api, bool terminal = false);
// Best-effort host close followed by unconditional local state cleanup.
void CloseBestEffort(const AmclInputHostApiV1* api);
// Unconditional local cleanup when no host API can safely be called.
void Abandon();

// 维护消费者按队列顺序看到的 core 文本会话：RESET/END/ABORT 清空，STARTED 置位。
// 返回 true 表示最近一次完整读取后 core 仍有活动会话，其号写入 *textSessionId。
bool ObservedTextSession(uint64_t* textSessionId);

}  // namespace amcl::input::shadow

#endif
