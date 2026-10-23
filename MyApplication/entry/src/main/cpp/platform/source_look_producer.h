/** delta来源的薄stream租约，政策/加工/尾量只在neutral owner。 */
#ifndef AMCL_SOURCE_LOOK_PRODUCER_H
#define AMCL_SOURCE_LOOK_PRODUCER_H
#include <stdint.h>
bool amclSourceLookSubmit(int32_t source,double dx,double dy,int64_t sampleNs,bool gyro=false);
bool amclSourceLookFlush(int32_t source,bool emit);
#endif
