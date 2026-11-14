// render_scale.h — 渲染分辨率缩放（-Damcl.render.scale）的解析、取整与坐标映射
//
// 降低整幅游戏图像的像素预算，保留宿主全屏显示区域。收益取决于实际瓶颈，
// 不以比例数值代替 GPU 成本或帧率实测。显示、游戏逻辑尺寸和实际图像分别确认。
//
// 全链路契约（三段，谁在什么坐标系）：
//   1. 用户表达：自定义 JVM 参数 `-Damcl.render.scale=<v>`，合法域 [0.5, 1.0]，
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
// NativeWindow 配置接口不因 UI 调用串行就自动与 EGL/Vulkan 生产者互斥。
// 启动期必须在生产者创建前配置；运行调整必须通过当前呈现 owner 的安全点。
// 配置成功只表示候选尺寸可发布，实际 EGL/交换链和游戏 framebuffer 仍须分别观测。
//
// 本头保持 host 可编译（无任何 OHOS 依赖），纯函数部分由
// tests/host/render_scale_test.cpp 钉住。

#ifndef AMCL_PLATFORM_RENDER_SCALE_H
#define AMCL_PLATFORM_RENDER_SCALE_H

#include <string>
#include <vector>

namespace amcl::renderscale {

// 合法域 [kMinScale, 1.0]；100% 是显式有效选择，与缺省/非法回退的来源不同。
inline constexpr double kMinScale = 0.5;

// 解析 env/JVM 参数的值部分。整串必须是一个有限小数且落在 [0.5, 1.0] 内才算有效；
// 其余（空串、nullptr、尾随垃圾、NaN/inf、越界）一律返回 1.0，*outValid=false。
// 调用方据 outValid 决定是否 WARN —— 解析器自身不打日志，保持 host 可测。
double ParseScale(const char* text, bool* outValid);

// real → scaled：round(real*scale) 后沿用已有偶数对齐政策；这不是所有 GL 目标
// 的格式要求。100% 保留原始奇数尺寸；scale 无效或 real 非正时恒等返回。
int ScaledDimension(int real, double scale);

// 在 JVM/游戏创建窗口前统一初始逻辑尺寸。width/height 来自平台已接受的发布，
// 不能继续把物理显示 P 传给采用低分辨率 L/F 的 SDL 或 LWJGL2。
// 仅移除这两个尺寸选项（兼容分离与等号形式），其余参数顺序/内容不变；
// 无有效尺寸时保持原数组，避免构造零尺寸。调用者负责绑定本次会话的窗口身份。
void SetInitialGameSize(std::vector<std::string>& arguments, int width, int height);

// 单轴绝对坐标映射。用精确比值 scaled/real 而不是 scale 本身：SET 的尺寸经过
// round+偶数对齐，比值才是真实生效的几何，用 scale 会产生累计 rounding 漂移。
double MapAxis(double value, int real, int scaled);

// ---- 运行时快照（由 xcomponent 在每次 SET_BUFFER_GEOMETRY 后发布）----
//
// 打包成单个 64 位原子（4×16bit 尺寸），读方一次 load 拿到一致的 real/scaled 对，
// 不存在跨多个原子的撕裂。写者由surface gate串行化，但可位于UI或呈现owner线程；
// GUI worker也会读取，所以原子是必要边界，工作线程必须使用成对映射接口。
// 任一尺寸超出 16bit（>65535）时按恒等发布 —— 该防御分支不可达于现有设备。

// scaled==real（或尺寸非法）时发布恒等快照，映射退化为直通。
void PublishSnapshot(int realWidth, int realHeight, int scaledWidth, int scaledHeight);
void ResetSnapshot();

// 恒等快照时为 false；MapX/MapY 在 false 时原样返回（scale==1 零开销路径）。
bool MappingActive();

// 绝对坐标 real px → MC 窗口坐标（scaled px）。x 用 scaledW/realW，y 用 scaledH/realH。
double MapX(double x);
double MapY(double y);
// 工作线程不持surface gate时必须成对读取；避免一次live resize夹在两个MapX/MapY之间。
// 非有限输入或空输出返回false且不改输出，恒等快照仍按同一接口直通。
bool MapWindowPoint(double x, double y, double* windowX, double* windowY);

// 成对逆变换：一次读取同一packed快照，将游戏window px还原为真实surface px。
// 调用者仍须绑定有效surface/尺寸/目标身份；本纯几何函数不替代生命周期准入。
// null输出或非有限输入返回false且不改输出；恒等快照保留原坐标。
bool UnmapWindowPoint(double x,double y,double* surfaceX,double* surfaceY);
// 同一个packed快照映射真实relative delta与viewport上界，输出供有序consumer做累加/clamp。
// 四个输出全部验证后才提交；不能将producer反馈坐标先clamp再反算delta。
bool MapPointerDelta(double dx,double dy,double maxX,double maxY,
                     double* windowDx,double* windowDy,double* windowMaxX,double* windowMaxY);

}  // namespace amcl::renderscale

// 启动时机补偿：McGamePage 的顺序是 XComponent OnSurfaceCreated → startMC，
// 所以首个 surface 发布时 AMCL_RENDER_SCALE 还未写入。mc_launcher 写完 env 后调用
// 本函数（NAPI 同步调用，与 surface 回调同一 JS/UI 线程序列），由 xcomponent.cpp
// 对已存活的 surface 重新执行 SET_BUFFER_GEOMETRY + 按 scaled 尺寸重发布。
// surface 尚未创建/已销毁时是 no-op（之后的 OnSurfaceCreated 会读到刚写的 env）。
extern "C" void amclRenderScaleReapplyForLaunch(void);

#endif  // AMCL_PLATFORM_RENDER_SCALE_H
