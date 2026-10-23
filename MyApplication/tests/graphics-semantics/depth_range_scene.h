#pragma once

#include <cstdint>
#include <array>
#include <string>

// 深度范围的共享真实绘制场景。此头文件不依赖 GL/EGL 平台头，OHOS 宿主与
// Linux 参考运行器都通过自己的生产 provider 解析函数；场景不安装全局函数表，
// 不创建、切换或销毁 context。调用者必须先建立专用、合法 current 的 context。
namespace amcl::graphics_semantics {

// resolver 返回已冻结 provider 的函数地址。禁止遇到缺符号后到另一 GL 库补齐。
// user 仅属于该次测试；回调与整个场景都在拥有 current context 的同一线程执行。
using ResolveProc = void* (*)(void* user, const char* name);

// raw GLES 参考使用 GLES100；桌面参考和 MG 翻译器按真实输入 API 选择桌面语言。
enum class ShaderDialect { Gles100, Desktop120, Desktop330 };

// 资格判定必须覆盖这组固定场景，而非仅看exitCode/completed。列表同时供宿主
// 和OHOS验证逐项查询/像素记录，缺任一项都不能输出PASS。
inline constexpr std::array<const char*, 13> RequiredDepthRangeCases{
    "initial-context", "double-nondefault", "float-nondefault", "double-reversed",
    "float-after-double", "double-clamp-low", "float-clamp-high", "double-clamp-reversed",
    "float-reversed", "double-huge-finite", "double-equal-endpoints", "float-restores-default",
    "double-after-float"};

// evidence 是逐项 JSONL：查询值、固定像素判据、错误与资源阶段均保留。
// completed=false 表示缺函数、shader/FBO/GL 错误等环境或路径失败，不能把它
// 当作“成功检出旧 stub”。failures=0、completed=true 才表示完整场景通过。
struct DepthRangeResult {
    std::uint32_t checks = 0;
    std::uint32_t queryChecks = 0;
    std::uint32_t pixelChecks = 0;
    std::uint32_t failures = 0;
    bool completed = false;
    std::string evidence;
};

// 只操作本次新建的 64×64 RGBA/DEPTH_COMPONENT16 FBO、shader、VBO/VAO。
// 测试固定内点 8×8 区域，排除边缘覆盖歧义；深度比较阈值预先写死，绝不从
// 被测查询值生成预期像素。调用者负责检查函数映像、保留证据、释放专用 context。
DepthRangeResult RunDepthRange(ResolveProc resolve, void* user,
                              ShaderDialect dialect = ShaderDialect::Desktop330);

// 独立核对每个必需场景的查询与像素条目、实际check/failure数量及唯一末尾marker。
// 校准负控可完整执行但failures非0；此函数只证明证据完整，语义PASS仍需failures=0。
bool ValidateCompleteDepthRangeEvidence(const DepthRangeResult& result);

// 声明初值使用与depth同一resolver/current owner，独立对象和独立计数。desktop330
// 输入先在link成功后、UseProgram及任何setter之前查询，再验证RGBA8默认绘制；
// 同program的合法手动setter与绿色读回校准真实uniform/像素路径。这里的result
// 复用JSONL容器类型，不将其计数加入depth83/26/24或当作完整shader能力资格。
DepthRangeResult RunUniformInitializer(ResolveProc resolve, void* user);
bool ValidateCompleteUniformInitializerEvidence(const DepthRangeResult& result);

}  // namespace amcl::graphics_semantics
