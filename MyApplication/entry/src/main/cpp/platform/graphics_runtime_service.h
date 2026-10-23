#pragma once
#include "graphics_runtime_abi.h"

/**
 * 同一进程跨 linker namespace 的唯一图形服务描述符。此 ABI 的生产者、发布/竞争与
 * 生命周期由 graphics_runtime_binding.cpp 管理；其它映像只借用 bound 的只读 C 表。
 * 单独放在头文件使晚加载 Java EGL 桥按同一布局验证，不能复制私有 C++ owner 对象，
 * 也不能因为 RTLD_DEFAULT 看不到首个映像就再次装入 provider 或创建第二个服务。
 */
#define AMCL_GRAPHICS_RUNTIME_SERVICE_ENV "AMCL_GRAPHICS_RUNTIME_SERVICE_V2"
struct AmclGraphicsRuntimeServiceV2 {
    uint32_t size, abi, publicApiSize;
    int pid;
    int (*bind)(const char*, const char*, char*, int);
    const AmclGraphicsRuntimeV1* (*bound)();
};

namespace amcl::graphics {
/** 仅在环境文本 PID 已与当前进程匹配后调用；不拥有/释放表，也不触发 bind 或初始化。 */
inline bool ValidGraphicsRuntimeServiceV2(const AmclGraphicsRuntimeServiceV2* owner, int pid) {
    return owner && owner->size >= sizeof(AmclGraphicsRuntimeServiceV2) && owner->abi == 2 &&
        owner->publicApiSize >= sizeof(AmclGraphicsRuntimeV1) && owner->pid == pid &&
        owner->bind && owner->bound;
}
}
