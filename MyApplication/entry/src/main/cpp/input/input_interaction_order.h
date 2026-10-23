#ifndef AMCL_INPUT_INTERACTION_ORDER_H
#define AMCL_INPUT_INTERACTION_ORDER_H

#include <stdint.h>

// typed core 与兼容 ring 使用同一进程 owner 的入队顺序。该序号只表达因果先后，
// 不替代采样时钟，也不替代 core 内用于绝对坐标授权的连续 sequence。
#ifdef __cplusplus
extern "C" {
#endif
uint64_t amclInputNextInteractionOrder(void);
uint64_t amclInputInteractionFence(void);
void amclInputBeginInteractionBatch(void);
void amclInputEndInteractionBatch(void);
#ifdef __cplusplus
}
namespace amcl::input {
// 调用者先取得自己的队列锁，再取本锁；持有本锁时不得取得其它通道的队列锁。
// 一批绝对坐标与按钮保持相邻，帧 fence 不会落进批次中间。递归锁允许逐记录分配。
class InteractionBatch final {
public:
    InteractionBatch() { amclInputBeginInteractionBatch(); }
    ~InteractionBatch() { amclInputEndInteractionBatch(); }
    InteractionBatch(const InteractionBatch&) = delete;
    InteractionBatch& operator=(const InteractionBatch&) = delete;
};
}
#endif
#endif
