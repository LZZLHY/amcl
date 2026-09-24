# ============================================================
# CMakeLists.txt — OpenAL Soft with OHAudio backend for OHOS
#
# 构建策略：
#   1. 通过 CMake cache 变量禁用所有不需要的后端
#   2. 用 add_subdirectory 编译 OpenAL Soft
#   3. 在编译后将 OHAudio 后端源码注入到 OpenAL Soft 目标中
#
# 注意：OpenAL Soft 源码在 openal-soft/ 子目录（gitignored）
#       OHAudio 后端代码在当前目录（ohaudio.cpp/h，tracked in git）
# ============================================================
cmake_minimum_required(VERSION 3.5.0)

# CMP0079: target_link_libraries on targets from other directories
# CMP0077: option() honors normal variables (needed for cache overrides)
cmake_policy(SET CMP0079 NEW)
cmake_policy(SET CMP0077 NEW)

set(OPENAL_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/openal-soft)

# ============================================================
# 禁用所有不需要的后端和功能
# ============================================================
set(ALSOFT_BACKEND_PIPEWIRE  OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_PULSEAUDIO OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_ALSA      OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_OSS       OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_SOLARIS   OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_SNDIO     OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_WASAPI    OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_DSOUND    OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_WINMM     OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_COREAUDIO OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_OPENSL    OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_OBOE      OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_PORTAUDIO OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_SDL2      OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_SDL3      OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_JACK      OFF CACHE BOOL "" FORCE)
set(ALSOFT_BACKEND_WAVE      OFF CACHE BOOL "" FORCE)

# 禁用不需要的功能以减小体积和编译时间
set(ALSOFT_UTILS             OFF CACHE BOOL "" FORCE)
set(ALSOFT_EXAMPLES          OFF CACHE BOOL "" FORCE)
set(ALSOFT_INSTALL           OFF CACHE BOOL "" FORCE)
set(ALSOFT_INSTALL_CONFIG    OFF CACHE BOOL "" FORCE)
set(ALSOFT_INSTALL_HRTF_DATA OFF CACHE BOOL "" FORCE)
set(ALSOFT_INSTALL_AMBDEC_PRESETS OFF CACHE BOOL "" FORCE)
set(ALSOFT_INSTALL_EXAMPLES  OFF CACHE BOOL "" FORCE)
set(ALSOFT_INSTALL_UTILS     OFF CACHE BOOL "" FORCE)
set(ALSOFT_UPDATE_BUILD_VERSION OFF CACHE BOOL "" FORCE)
set(ALSOFT_EAX               OFF CACHE BOOL "" FORCE)

# 构建为共享库
set(LIBTYPE "SHARED" CACHE STRING "" FORCE)

# ============================================================
# 添加 OpenAL Soft 子目录
# ============================================================
if(NOT EXISTS "${OPENAL_SRC_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
        "OpenAL Soft source not found at ${OPENAL_SRC_DIR}\n"
        "Run setup_deps.sh to clone it, or:\n"
        "  git clone --depth 1 https://github.com/kcat/openal-soft.git ${OPENAL_SRC_DIR}")
endif()

add_subdirectory(${OPENAL_SRC_DIR} ${CMAKE_CURRENT_BINARY_DIR}/openal-soft)

# ============================================================
# 注入 OHAudio 后端到 OpenAL Soft 目标
#
# OpenAL Soft 的 CMakeLists 会把所有 HAVE_XXX 重置为 0，
# 所以我们无法通过 CMake 变量传递 HAVE_OHAUDIO=1。
# 改用 target_compile_definitions 强制在编译器命令行定义
# HAVE_OHAUDIO=1，这会覆盖 config_backends.h 中的 #define。
# alc/alc.cpp 已被补丁，在 BackendList 中注册了 OHAudio。
# ============================================================

set(OPENAL_TARGET OpenAL)

# 强制启用 OHAudio 后端（覆盖 config_backends.h 的 HAVE_OHAUDIO 0）
target_compile_definitions(${OPENAL_TARGET} PRIVATE HAVE_OHAUDIO=1)

# 添加 OHAudio 后端源文件
target_sources(${OPENAL_TARGET} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/ohaudio.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/ohaudio.h
)

# OHAudio 后端头文件搜索路径
target_include_directories(${OPENAL_TARGET} PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# 链接 OHAudio 系统库
target_link_libraries(${OPENAL_TARGET} PRIVATE libohaudio.so)

# 设置输出名称为 openal（生成 libopenal.so）
set_target_properties(${OPENAL_TARGET} PROPERTIES
    OUTPUT_NAME "openal"
)
