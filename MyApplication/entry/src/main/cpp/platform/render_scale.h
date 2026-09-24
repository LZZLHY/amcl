// render_scale.h — 渲染分辨率缩放（-Damcl.render.scale）的解析、取整与坐标映射
//
// 动机（真机实证）：MC 26.3 在 Maleoon 920 平板（2800×1840）上 GPU-bound
//（渲染线程墙钟 30-50% 在 glClientWaitSync 等 GPU、glBlitFramebuffer 占整秒 29-47%），
// 降低渲染分辨率是当前最大的性能杠杆。
//
// 全链路契约（三段，谁在什么坐标系）：
//   1. 用户表达：自定义 JVM 参数 `-Damcl.render.scale=<v>`，合法域 [0.5, 1.0)，
//      非法/缺省 = 1.0（不缩放）。mc_launcher 在 JVM 创建前解析并写
//      env `AMCL_RENDER_SCALE`（无效时显式写 "1"，防进程内重启残留——纪律同 pacing）。
//   2. 生效点：xcomponent.cpp 在 surface 发布前对 NativeWindow 做
//      SET_BUFFER_GEOMETRY(scaledW, scaledH)，此后**所有发布一律用 scaled 尺寸**
//      （glfwOHOS_Publish/Update、AMCL_WINDOW_* env、typed ingress 的 surface 尺寸）。
//      显示 surface 仍是 real 尺寸（系统把 scaled buffer 拉伸上屏）。
//   3. 输入坐标：XComponent 触控/鼠标以 real 物理 px 上报，而 MC 窗口坐标系 = scaled。
//      所以**绝对坐标在进入 MC 侧（input_bridge/typed 绝对平面）的入口处**用精确比值
//      scaled/real 换算；相对量（鼠标 rawDelta、滚轮、dragLook 差分）不换算。
//      虚拟控件命中测试（schema rect）留在 real px —— 它比较的是触点与 ArkTS 布局，
//      与 MC 坐标系无关。
//
// SET_BUFFER_GEOMETRY 的线程安全论证（xcomponent.cpp 的 ApplyRenderScaleGeometry
// 引用至此）：ohos_native_window_telemetry.h 的"active resize 不做查询"警告针对
// 的是 GET 与 EGL 消费端并发的读竞争；SET 走 buffer queue 的生产者配置路径，由
// 队列自身串行化，生效点是下一次 dequeue。且其全部调用点（OnSurfaceCreated /
// OnSurfaceChanged / 启动时机重放）都在同一 UI/JS 主线程序列里、先于把新尺寸
// 发布给渲染侧 —— 消费端要么尚未存在，要么先看到几何变化再看到新发布尺寸，
// 不存在"用旧尺寸解释新 buffer"的窗口。
//
// 本头保持 host 可编译（无任何 OHOS 依赖），纯函数部分由
// tests/host/render_scale_test.cpp 钉住。

#ifndef AMCL_PLATFORM_RENDER_SCALE_H
#define AMCL_PLATFORM_RENDER_SCALE_H

namespace amcl::renderscale {

// 合法域 [kMinScale, 1.0)。1.0 本身不属于域：它就是"不缩放"的缺省语义。
inline constexpr double kMinScale = 0.5;

// 解析 env/JVM 参数的值部分。整串必须是一个有限小数且落在 [0.5, 1.0) 内才算有效；
// 其余（空串、nullptr、尾随垃圾、NaN/inf、越界）一律返回 1.0，*outValid=false。
// 调用方据 outValid 决定是否 WARN —— 解析器自身不打日志，保持 host 可测。
double ParseScale(const char* text, bool* outValid);

// real → scaled：round(real*scale) 后向下偶数对齐（YUV/压缩纹理族对奇数尺寸不友好，
// 偶数对齐是零代价的普适保险）。scale 无效或 real 非正时恒等返回。
int ScaledDimension(int real, double scale);

// 单轴绝对坐标映射。用精确比值 scaled/real 而不是 scale 本身：SET 的尺寸经过
// round+偶数对齐，比值才是真实生效的几何，用 scale 会产生累计 rounding 漂移。
double MapAxis(double value, int real, int scaled);

// ---- 运行时快照（由 xcomponent 在每次 SET_BUFFER_GEOMETRY 后发布）----
//
// 打包成单个 64 位原子（4×16bit 尺寸），读方一次 load 拿到一致的 real/scaled 对，
// 不存在跨多个原子的撕裂。实践中读写都发生在 UI/JS 主线程序列里，原子只是保险。
// 任一尺寸超出 16bit（>65535）时按恒等发布 —— 该防御分支不可达于现有设备。

// scaled==real（或尺寸非法）时发布恒等快照，映射退化为直通。
void PublishSnapshot(int realWidth, int realHeight, int scaledWidth, int scaledHeight);
void ResetSnapshot();

// 恒等快照时为 false；MapX/MapY 在 false 时原样返回（scale==1 零开销路径）。
bool MappingActive();

// 绝对坐标 real px → MC 窗口坐标（scaled px）。x 用 scaledW/realW，y 用 scaledH/realH。
double MapX(double x);
double MapY(double y);

}  // namespace amcl::renderscale

// 启动时机补偿：McGamePage 的顺序是 XComponent OnSurfaceCreated → startMC，
// 所以首个 surface 发布时 AMCL_RENDER_SCALE 还未写入。mc_launcher 写完 env 后调用
// 本函数（NAPI 同步调用，与 surface 回调同一 JS/UI 线程序列），由 xcomponent.cpp
// 对已存活的 surface 重新执行 SET_BUFFER_GEOMETRY + 按 scaled 尺寸重发布。
// surface 尚未创建/已销毁时是 no-op（之后的 OnSurfaceCreated 会读到刚写的 env）。
extern "C" void amclRenderScaleReapplyForLaunch(void);

#endif  // AMCL_PLATFORM_RENDER_SCALE_H
