#pragma once
#include <hilog/log.h>
#include <atomic>
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

// 解析缓存（I27-05）：描述符每进程只发布一次，游戏线程的错误日志不必每条都遍历 environ。
// 只缓存本 PID 解析成功的回调；缺席、PID 不符、格式错误都不缓存，下一条日志重新解析。
// static inline ⇒ 每个包含本头的 TU 一份缓存，互不共享也无需跨 TU 同步。
struct AmclExternalLogSinkCache {
    std::atomic<long> pid{0};
    std::atomic<AmclExternalLogSink> sink{nullptr};
};
static inline AmclExternalLogSinkCache& amclExternalLogSinkCache() {
    static AmclExternalLogSinkCache cache;
    return cache;
}
static inline AmclExternalLogSink amclExternalLogResolveSink(long pid) {
    auto& cache = amclExternalLogSinkCache();
    if (cache.pid.load(std::memory_order_acquire) == pid) return cache.sink.load(std::memory_order_relaxed);
    const char* descriptor = std::getenv("AMCL_LOG_SINK_V1");
    if (!descriptor) return nullptr;
    char* end = nullptr;
    const long owner = std::strtol(descriptor, &end, 10);
    if (owner != pid || !end || *end != ':') return nullptr;
    char* addressEnd = nullptr;
    const auto address = std::strtoull(end + 1, &addressEnd, 16);
    if (!address || addressEnd == end + 1 || *addressEnd) return nullptr;
    const auto sink = reinterpret_cast<AmclExternalLogSink>(static_cast<uintptr_t>(address));
    cache.sink.store(sink, std::memory_order_relaxed);
    cache.pid.store(pid, std::memory_order_release);
    return sink;
}
#if defined(AMCL_LOG_BRIDGE_TESTING)
// 仅宿主测试：清空本 TU 的缓存，以便再次验证“PID 不符/格式错误”在解析阶段失败关闭。
static inline void amclExternalLogResetSinkCache() {
    amclExternalLogSinkCache().pid.store(0, std::memory_order_release);
    amclExternalLogSinkCache().sink.store(nullptr, std::memory_order_relaxed);
}
#endif

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
#ifdef _WIN32
    const long pid = _getpid();
#else
    const long pid = getpid();
#endif
    const AmclExternalLogSink sink = amclExternalLogResolveSink(pid);
    if (sink) sink(level, tag, fmt, args);
    va_end(args);
}

#define AMCL_EXTERNAL_LOG_W(tag, fmt, ...) amclExternalLogWrite(2, tag, fmt, ##__VA_ARGS__)
#define AMCL_EXTERNAL_LOG_E(tag, fmt, ...) amclExternalLogWrite(3, tag, fmt, ##__VA_ARGS__)
