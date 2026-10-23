/** 宿主身份fixture：只提供同映像getter/建窗地址锚点，不冒充真正GLFW窗口资格。
 * 两个CMake target由同源码生成不同DSO；missing版本不导出identity getter。
 * fixture的文本输入仅由测试显式设置，不是生产配置域或生产setter。 */
#include <stddef.h>

static const char* identity = NULL;

/** 文本由冷进程中的静态字符串持有，覆盖该进程全部卸载调用；NULL测空返回。 */
__attribute__((visibility("default")))
void auditSetDiagnosticIdentity(const char* value) { identity = value; }

#ifndef AMCL_TEST_NO_IDENTITY
/** 地址与本DSO的glfwCreateWindow相同归属；只返回被测canonical或非法原文。 */
__attribute__((visibility("default")))
const char* amclDiagnosticBuildIdentity(void) { return identity; }
#endif

/** 从未被调用创建窗口；真实函数地址仅用于生产dladdr的provider归属检查。 */
__attribute__((visibility("default")))
void* glfwCreateWindow(int width, int height, const char* title, void* monitor, void* share) {
    (void)width; (void)height; (void)title; (void)monitor; (void)share;
    return NULL;
}
