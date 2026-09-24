#pragma once
#include <cstdlib>
#include <cstring>

namespace amcl::graphics {
/** 只核对由AppScope提供的启动声明，不设置或修复进程环境。真实驱动选择在首次
 * EGL公开调用时已经锁存；当前值缺失说明产物/运行环境不满足契约，晚setenv不能补救。
 * 此标志只允许系统在支持的设备上启用GL能力，不决定Minecraft的实际profile/API。
 */
inline bool SystemGraphicsBootstrapConfigured() {
    const char* value = std::getenv("NEED_OPENGL");
    return value && std::strcmp(value, "1") == 0;
}
}
