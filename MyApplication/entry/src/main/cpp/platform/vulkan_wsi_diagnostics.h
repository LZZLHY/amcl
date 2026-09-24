#pragma once

namespace amcl::graphics {
/**
 * Vulkan WSI 的资源调用诊断位，须与 ProductDiagnostics.cmake 和 diagnostic-profile.mjs
 * 末尾追加的 vulkan-trace 项一致。位 0 表示 default 开发产品，位 9 表示显式申请 trace；
 * 两位缺一不可，避免独立编译或仅误设 trace 位时把逐资源日志带入普通产品。
 * 本纯策略不读取环境、不缓存状态，也不改变任何 Vulkan 调用、返回值或资源所有权。
 */
constexpr unsigned kVulkanWsiTraceMask = 1u << 9;

/**
 * 只控制资源 begin/成功 end 与函数解析 trace。失败必须始终可见，不能因为诊断关闭而
 * 丢失 missing-proc、分配失败等证据；关键生命周期与低频 present 计数直接走常规日志。
 */
constexpr bool VulkanWsiTraceAllowed(unsigned diagnosticsMask, bool error) {
    return error || (diagnosticsMask & (1u | kVulkanWsiTraceMask)) == (1u | kVulkanWsiTraceMask);
}
}
