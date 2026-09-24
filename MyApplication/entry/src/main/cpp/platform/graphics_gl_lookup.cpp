// LWJGL的libname只指向这个查询入口，不再次装入翻译器。多个namespace映像通过进程服务
// 找到同一provider，SDL_GL_GetProcAddress、GLFW与LWJGL得到相同真实函数地址/对象域。
// 本库是libentry的启动依赖，禁止导出系统同名EGL入口：游戏计划尚未绑定时我们的查询
// 会返回空值，ELF依赖闭包中的系统/UI调用却可能先解析到它，连RTLD_LOCAL也不隔离。
// Linux模式的LWJGL优先使用下面两个GLX查询名；宿主的EGL请求始终走amclGraphicsEglProcV1。
#include "graphics_runtime_binding.h"
/** 返回当前进程已冻结provider的GL函数；未绑定或名称无效时保留空结果，不隐式初始化。 */
extern "C" AMCL_GRAPHICS_PUBLIC void* glXGetProcAddress(const unsigned char* name) {
    return amclGraphicsGlProcV1(reinterpret_cast<const char*>(name));
}
/** LWJGL旧槽位使用的同语义别名，与主入口返回同一provider地址。 */
extern "C" AMCL_GRAPHICS_PUBLIC void* glXGetProcAddressARB(const unsigned char* name) {
    return glXGetProcAddress(name);
}
