#pragma once
// 公共运行时仅导出显式ABI和由同一工具链构建的会话类型；实现细节仍保持hidden。
// Windows宿主测试直接编入可执行文件，不需要DLL import/export装饰。
#if defined(_WIN32)
#define AMCL_GRAPHICS_PUBLIC
#else
#define AMCL_GRAPHICS_PUBLIC __attribute__((visibility("default")))
#endif
