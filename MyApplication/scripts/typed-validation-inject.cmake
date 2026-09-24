# scripts/typed-validation-inject.cmake
#
# typed 验证包的注入点。经 `-DCMAKE_PROJECT_INCLUDE=<本文件>` 传入，CMake 在顶层
# `project()` 之后立刻处理它 —— 也就是在 toolchain 文件之后、任何 add_library /
# target_compile_definitions 之前。只由 scripts/build-typed-validation-hap.ps1 使用。
#
# 为什么是这条通道（前两条都试过并被实测否证）：
#   ✗ 环境变量 CXXFLAGS —— ohos.toolchain.cmake:281 用不带 FORCE 的
#     `set(CMAKE_CXX_FLAGS "" CACHE STRING ...)` 在 toolchain 阶段抢先把 cache 建成空，
#     而那早于 CMake 从 CXXFLAGS 初始化 ⇒ env 被吃掉。**实测过一次完整构建**：七阶段
#     全过、产物却与出货包等价，是脚本里的正向证据门把它拦下的。
#   ✗ -DCMAKE_CXX_FLAGS=-include <path> —— 值里带空格，而 hvigor 把 arguments 按空白
#     切成多个 cmake 参数 ⇒ 路径会变成一个独立参数（被当成源码目录）。
#   ✓ -DCMAKE_PROJECT_INCLUDE=<本文件> —— 单 token 无空格，且本文件里可以自由用空格与引号。
#
# 为什么用 add_compile_options 而不是 add_compile_definitions：
# Ninja 的命令段顺序是 `$DEFINES $INCLUDES $FLAGS`。两种 add_compile_* 里只有
# **options** 落在 FLAGS 段，也就是 target_compile_definitions 注入的那些 `=0` **之后**
# ⇒ 覆盖才会赢。写成 definitions 会落进 DEFINES 段的前半，反被 target 那份覆盖回 0。

get_filename_component(AMCL_TYPED_VALIDATION_HEADER
    "${CMAKE_CURRENT_LIST_DIR}/typed-validation-overrides.h" ABSOLUTE)
if(NOT EXISTS "${AMCL_TYPED_VALIDATION_HEADER}")
    message(FATAL_ERROR
        "typed validation override header missing: ${AMCL_TYPED_VALIDATION_HEADER}")
endif()

# 目录级 compile options 对本目录及其子目录中**之后创建**的所有目标生效，
# 因此 entry / glfw 两个 DSO 都会拿到（bit10/bit13 必须两边一致：一半 typed 一半 legacy
# 会让一次 DOWN/UP 被劈到两条平面上，正是那两个一次性闭锁存在的理由）。
add_compile_options("-include" "${AMCL_TYPED_VALIDATION_HEADER}")

message(STATUS
    "AMCL typed validation overrides injected: ${AMCL_TYPED_VALIDATION_HEADER}")
message(WARNING
    "This build asserts Gate 0 bit13 with NO device evidence. "
    "It is a validation artifact and must not be distributed.")
