// surface_republish_policy.h — 一次 surface 几何刷新是否需要新发布代次的纯判定（I27-04）。
//
// 背景：真实 OnSurfaceChanged 读取的是回调时刻的当前尺寸，两次布局合并后可能连续读到同一尺寸。
// 此时推进发布代次会让 input core 把它当作新 surface（SameSurface 比较 publicationGeneration），
// 发出 RESET(SURFACE_CHANGED)：释放全部 typed held、清 capture 与文本会话；图形侧对同指针同尺寸
// 也没有任何需要处理的变化。所以身份、真实尺寸、发布（渲染缩放后）尺寸三者都未变时不发布。
//
// 边界：
//   - 真实尺寸变了而发布尺寸因取整没变，仍须发布：输入映射比值 scaled/real 已经不同；
//   - density / transform 由窗口上下文路径独立重发布，不经过本判定；
//   - 零尺寸暂停的重复回调（0x0 → 0x0，同一窗口）没有新信息，同样视为未变；
//   - 当前没有已发布窗口时永远返回 false，调用方必须走正常发布或失败路径。
// 本头无任何 OHOS 依赖，由 tests/host/surface_republish_policy_test.cpp 钉住。
#pragma once

namespace amcl::ohos {

// 一次发布所需的全部几何事实。nativeWindow 只做身份比较，从不解引用。
struct SurfacePublicationGeometry {
    const void* nativeWindow;
    int realWidth;
    int realHeight;
    int publishedWidth;
    int publishedHeight;
};

// current 为当前已发布状态，next 为本次回调计算出的状态；返回 true 表示可以不推进代次。
constexpr bool SurfacePublicationUnchanged(const SurfacePublicationGeometry& current,
                                           const SurfacePublicationGeometry& next) {
    return current.nativeWindow != nullptr && current.nativeWindow == next.nativeWindow &&
           current.realWidth == next.realWidth && current.realHeight == next.realHeight &&
           current.publishedWidth == next.publishedWidth &&
           current.publishedHeight == next.publishedHeight;
}

}  // namespace amcl::ohos
