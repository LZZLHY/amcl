#ifndef AMCL_INPUT_SURFACE_CONTEXT_SEMANTICS_H
#define AMCL_INPUT_SURFACE_CONTEXT_SEMANTICS_H
#include "amcl_input_event.h"

namespace amcl::input {
/** 同一input generation的唯一元数据例外：Hz及其valid位不改变坐标/窗口/单位身份。
 * 所有其它数值和有效位逐项一致；不能把未验证坐标、密度或新window伪装成刷新率更新。
 * 此私有比较由ingress与core共同使用，不新增公共payload/host ABI字段。
 */
inline bool SameInputSurfaceContextIdentity(const AmclInputSurfaceContextPayload& a,
                                           const AmclInputSurfaceContextPayload& b) {
    const uint32_t metadata = AMCL_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE;
    return a.generation == b.generation && (a.validFields & ~metadata) == (b.validFields & ~metadata) &&
        a.windowId == b.windowId && a.displayId == b.displayId &&
        a.leftPx == b.leftPx && a.topPx == b.topPx && a.widthPx == b.widthPx && a.heightPx == b.heightPx &&
        a.density == b.density && a.transform == b.transform;
}
/** 元数据缓存也保留最新未valid的原值，valid位决定能否解释；不能靠generation去重隐藏变化。 */
inline bool SameInputSurfaceContextMetadata(const AmclInputSurfaceContextPayload& a,
                                           const AmclInputSurfaceContextPayload& b) {
    return (a.validFields & AMCL_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE) ==
               (b.validFields & AMCL_INPUT_SURFACE_CONTEXT_FIELD_REFRESH_RATE) &&
        a.refreshRateHz == b.refreshRateHz;
}
}
#endif
