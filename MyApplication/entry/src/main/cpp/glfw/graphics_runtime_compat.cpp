// 旧GLFW前缀ABI只保留无状态转发。公共服务实际归属libamcl_graphics_runtime，
// 不在此处重新解析环境、装载翻译器、创建函数表或维护第二份呈现统计。
#include "../platform/graphics_runtime_binding.h"
#include "../platform/graphics_observation_abi.h"
extern "C" {
AMCL_GRAPHICS_PUBLIC int glfwOHOS_BindGraphicsRuntimeV1(const char* profile, const char* api, char* error, int capacity) {
    return amclGraphicsBindRuntimeV1(profile, api, error, capacity);
}
AMCL_GRAPHICS_PUBLIC void* glfwOHOS_GraphicsGlProcV1(const char* name) { return amclGraphicsGlProcV1(name); }
AMCL_GRAPHICS_PUBLIC void* glfwOHOS_GraphicsEglProcV1(const char* name) { return amclGraphicsEglProcV1(name); }
AMCL_GRAPHICS_PUBLIC const char* glfwOHOS_GraphicsBoundProfileV1() { return amclGraphicsBoundProfileV1(); }
AMCL_GRAPHICS_PUBLIC const char* glfwOHOS_GraphicsBoundApiV1() { return amclGraphicsBoundApiV1(); }
AMCL_GRAPHICS_PUBLIC int glfwOHOS_PublishGraphicsObserverV1() { return amclGraphicsPublishObserverV1(); }
AMCL_GRAPHICS_PUBLIC void glfwOHOS_GraphicsPresentedV1(const char* provider) { amclGraphicsPresentedV1(provider); }
AMCL_GRAPHICS_PUBLIC void glfwOHOS_GraphicsSwapV1(const char* provider, uint64_t elapsed, int success, uint32_t error) {
    amclGraphicsSwapV1(provider, elapsed, success, error);
}
AMCL_GRAPHICS_PUBLIC void glfwOHOS_GraphicsFatalV1(const char* stage, uint32_t error, uint64_t generation) {
    amclGraphicsFatalV1(stage, error, generation);
}
AMCL_GRAPHICS_PUBLIC void glfwOHOS_GraphicsForegroundV1(int visible) { amclGraphicsForegroundV1(visible); }
AMCL_GRAPHICS_PUBLIC const char* glfwOHOS_GraphicsRuntimeJsonV1() { return amclGraphicsRuntimeJsonV1(); }
AMCL_GRAPHICS_PUBLIC const char* glfwOHOS_GraphicsFailureJsonV1() { return amclGraphicsFailureJsonV1(); }
}
