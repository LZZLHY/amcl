#ifndef AMCL_INPUT_CANCEL_REASON_H
#define AMCL_INPUT_CANCEL_REASON_H

// 各原因都释放已有输入。几何暂停保留尚存的 surface 身份及组件焦点。
typedef enum {
    AMCL_INPUT_CANCEL_PAUSE = 1,
    AMCL_INPUT_CANCEL_BACKGROUND = 2,
    AMCL_INPUT_CANCEL_SURFACE_LOST = 3,
    AMCL_INPUT_CANCEL_PAGE_DISPOSE = 4,
    AMCL_INPUT_CANCEL_WINDOW_RECREATE = 5,
    AMCL_INPUT_CANCEL_FOCUS_LOST = 6,
    AMCL_INPUT_CANCEL_GEOMETRY_CHANGED = 7
} AmclInputCancelReason;

#ifdef __cplusplus
namespace amcl::input {
// 仅实际 surface 退休或页面销毁撤销原捕获表面的生命周期资格。
constexpr bool InputCancelRetiresCaptureSurface(int reason) {
    return reason == AMCL_INPUT_CANCEL_SURFACE_LOST || reason == AMCL_INPUT_CANCEL_PAGE_DISPOSE;
}
}
#endif

#endif
