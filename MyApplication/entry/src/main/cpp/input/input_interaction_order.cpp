#include "input_interaction_order.h"
#include <cstdlib>
#include <mutex>

namespace {
// 仅 owner runtime 使用此状态；跨 namespace 消费者通过已校验的 owner 函数表取 fence。
// 进程生命周期内不复用序号，避免重开 session 后旧队列与新队列比较时发生倒退。
std::recursive_mutex orderMutex;
uint64_t lastOrder = 0u;
}
extern "C" uint64_t amclInputNextInteractionOrder(void) {
    std::lock_guard<std::recursive_mutex> lock(orderMutex);
    // 0 留给基线/本地恢复，UINT64_MAX 留给“没有上限”。绝不回绕成旧记录。
    if (lastOrder >= UINT64_MAX - 1u) std::abort();
    return ++lastOrder;
}
extern "C" uint64_t amclInputInteractionFence(void) {
    std::lock_guard<std::recursive_mutex> lock(orderMutex);
    return lastOrder;
}
extern "C" void amclInputBeginInteractionBatch(void) { orderMutex.lock(); }
extern "C" void amclInputEndInteractionBatch(void) { orderMutex.unlock(); }
