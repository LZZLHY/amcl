cmake_minimum_required(VERSION 3.19)
# 将 shaderc 与其已有静态依赖组成单个 OHOS 动态库。LWJGL 的 Shaderc、GLSLang、
# ResourceLimits、SPV、SPVOptimizer 都从同一 SharedLibrary 取地址，因此不能仅满足
# MC 最常用的 shaderc_*。完整 C 接口的链接保留逻辑统一放在 complete-api.cmake。
project(amcl_shaderc LANGUAGES C CXX)
if(NOT IS_DIRECTORY "${AMCL_SHADERC_SOURCE}")
    message(FATAL_ERROR "AMCL_SHADERC_SOURCE 必须指向已核验的 shaderc 源码")
endif()
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "仅最终 shaderc 为共享库" FORCE)
set(SHADERC_SKIP_TESTS ON CACHE BOOL "不构建第三方测试依赖" FORCE)
set(SHADERC_SKIP_EXAMPLES ON CACHE BOOL "不构建示例" FORCE)
set(SHADERC_SKIP_EXECUTABLES ON CACHE BOOL "不构建宿主工具" FORCE)
set(SHADERC_SKIP_COPYRIGHT_CHECK ON CACHE BOOL "离线构建不运行版权扫描" FORCE)
# 保留上游的安装导出规则以闭合 glslang -> SPIRV-Tools-opt 的 CMake export 依赖。
# 构建脚本只指定 shaderc_shared 目标，不执行 install，也不会复制上游附加组件。
set(SHADERC_SKIP_INSTALL OFF CACHE BOOL "保持上游静态目标导出关系一致" FORCE)
set(SPIRV_SKIP_TESTS ON CACHE BOOL "不构建测试" FORCE)
set(SPIRV_SKIP_EXECUTABLES ON CACHE BOOL "仅构建真实库 API，不构建 CLI" FORCE)
set(GLSLANG_TESTS OFF CACHE BOOL "不构建测试" FORCE)
set(ENABLE_GLSLANG_BINARIES OFF CACHE BOOL "不构建 glslang CLI" FORCE)
add_subdirectory("${AMCL_SHADERC_SOURCE}" shaderc)
include("${CMAKE_CURRENT_LIST_DIR}/complete-api.cmake")
