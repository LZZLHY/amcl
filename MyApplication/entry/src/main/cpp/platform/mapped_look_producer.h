/** 手柄设备/连接租约薄适配；不积分，不保存pending，实际执行由neutral owner负责。 */
#ifndef AMCL_MAPPED_LOOK_PRODUCER_H
#define AMCL_MAPPED_LOOK_PRODUCER_H
#include <stdint.h>
bool amclMappedLookSupported();
bool amclMappedLookSet(uint64_t device,uint64_t connection,double vx,double vy);
bool amclMappedLookAdvance();
bool amclMappedLookRetire(uint64_t device,uint64_t connection);
/** Native来源复位兜底，JS drop不能使旧速率留在owner；不依赖控制release结果。 */
void amclMappedLookRetireAll();
#endif
