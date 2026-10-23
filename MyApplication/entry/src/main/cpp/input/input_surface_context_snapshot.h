#ifndef AMCL_INPUT_SURFACE_CONTEXT_SNAPSHOT_H
#define AMCL_INPUT_SURFACE_CONTEXT_SNAPSHOT_H
#include "amcl_input_event.h"

#ifdef __cplusplus
extern "C" {
#endif
// 仅libamcl_input_runtime内部跨C/C++调用，版本脚本不导出；frontend必须走下面owner委派入口。
int amcl_input_owner_read_surface_context(AmclInputSurfaceContextPayload* outContext);
// 私有追加能力：读当前owner的元数据基线，不扩大公开104B snapshot或host函数表。
// 返回1才有current context，其余情况清出参；consumer已有有序cache时只合并同identity的Hz。
#if defined(__GNUC__)
__attribute__((visibility("default")))
#endif
int inputBridge_readSurfaceContextV1(AmclInputSurfaceContextPayload* outContext);
#ifdef __cplusplus
}
#endif
#endif
