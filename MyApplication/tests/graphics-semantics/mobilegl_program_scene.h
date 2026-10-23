#pragma once
#include "depth_range_scene.h"

// 调用者在同一owner线程提供已冻结provider及合法current。本场景只建立自己的
// GL对象，不创建/切换/销毁context，不改全局函数表，不回退另一GL库。复用的
// DepthRangeResult只是JSONL容器，计数不并入depth83或initializer16。
namespace amcl::graphics_semantics {
// 由真实driver feature/既有资格证据指定，不从扩展广告或backend名字推断。
// Unsupported通过只证明明确拒绝，coreFP64Qualified始终false，不授予Core资格。
enum class Float64Expectation { Unsupported, Supported };
DepthRangeResult RunMobileGlProgramContract(ResolveProc resolve, void* user,
                                            Float64Expectation expectation);
// 完整阴性也可通过此结构检查；语义合同仍需failures=0。native的精度像素资格
// 与限制拒绝分别记录，不能只借退出0/completed授予完整FP64、pipeline或compute。
bool ValidateCompleteMobileGlProgramEvidence(const DepthRangeResult& result);
}
