#pragma once
#include <hilog/log.h>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

// GLFW 的 linker namespace 与 libentry 不同，不能反向强链接 writer 或靠
// RTLD_DEFAULT 猜地址。宿主初始化后发布带 PID 的回调描述符；fork 继承的旧
// 地址因 PID 不符拒绝调用。回调同步消费 va_list，正文仍由宿主唯一 writer 异步落盘。
using AmclExternalLogSink = void (*)(int, const char*, const char*, va_list);
/** 同一组实参分别交给 hilog 与宿主，避免 eglGetError/dlerror 等实参求值两次。 */
static inline void amclExternalLogWrite(int level, const char* tag, const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    va_list systemArgs;
    va_copy(systemArgs, args);
    // 桥同时承载低频环境事实，沿用实际级别，不能把正常 GPU 信息伪装成 WARN。
    OH_LOG_VPrint(LOG_APP, level >= 4 ? LOG_FATAL : level >= 3 ? LOG_ERROR
        : level == 2 ? LOG_WARN : level == 1 ? LOG_INFO : LOG_DEBUG, 0, tag, fmt, systemArgs);
    va_end(systemArgs);
    const char* descriptor = std::getenv("AMCL_LOG_SINK_V1");
    if (!descriptor) { va_end(args); return; }
    char* end = nullptr;
    const long owner = std::strtol(descriptor, &end, 10);
#ifdef _WIN32
    const long pid = _getpid();
#else
    const long pid = getpid();
#endif
    if (owner != pid || !end || *end != ':') { va_end(args); return; }
    char* addressEnd = nullptr;
    const auto address = std::strtoull(end + 1, &addressEnd, 16);
    if (!address || addressEnd == end + 1 || *addressEnd) { va_end(args); return; }
    reinterpret_cast<AmclExternalLogSink>(static_cast<uintptr_t>(address))(level, tag, fmt, args);
    va_end(args);
}

#define AMCL_EXTERNAL_LOG_W(tag, fmt, ...) amclExternalLogWrite(2, tag, fmt, ##__VA_ARGS__)
#define AMCL_EXTERNAL_LOG_E(tag, fmt, ...) amclExternalLogWrite(3, tag, fmt, ##__VA_ARGS__)
