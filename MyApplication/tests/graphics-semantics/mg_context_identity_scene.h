#pragma once
#include "depth_range_scene.h"
#include "graphics_runtime_binding.h"

// caller先在干净诊断进程冻结真实runtime，提供固定同映像resolver和全部I/O/RETURN。
// 本函数不FreezeRuntime、不装全局GL表；只用生产contextOperations创建两个独立
// heap-owned auxiliary context并切换查询。失败退休的状态保留到已claimed进程重启。
namespace amcl::graphics_semantics {
DepthRangeResult RunMgContextIdentity(const amcl::graphics::GraphicsRuntimeBinding& runtime,
                                     bool highFirst, ResolveProc resolve, void* user);
// 只检查固定4turn与setup/retire的结构完整性；语义通过另需failures=0。
bool ValidateCompleteMgContextIdentityEvidence(const DepthRangeResult& result);
}
