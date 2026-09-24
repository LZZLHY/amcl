#pragma once

#include <cstdio>
#include <ctime>
#include <cstddef>

/**
 * 将已经采集的 epoch 秒格式化为明确带 Z 的 UTC 日志时间。
 * 日志 writer 与 JVM/渲染器环境配置线程并发运行，不能调用会隐式遍历 environ 的
 * localtime_r/tzset，也不能使用依赖全局 locale 的 strftime。gmtime_r 只转换传入秒数，
 * 输出仍由调用方提供的缓冲区持有；Windows 宿主测试使用同义的 gmtime_s。
 * 不修改进程 TZ，不缓存某次启动的时区偏移，因而不受用户改时区或夏令时切换影响。
 */
static inline bool amclFormatLogTime(time_t timestamp, char* output, size_t capacity) {
    if (output == nullptr || capacity == 0) return false;
    output[0] = '\0';
    struct tm fields{};
#ifdef _WIN32
    const bool converted = gmtime_s(&fields, &timestamp) == 0;
#else
    const bool converted = gmtime_r(&timestamp, &fields) != nullptr;
#endif
    // 保持固定四位年份的 ISO 8601 形状。无法表达时保留原始 epoch，不伪造当前时间。
    if (!converted || fields.tm_year < -1900 || fields.tm_year > 8099) {
        std::snprintf(output, capacity, "epoch:%lld", static_cast<long long>(timestamp));
        return false;
    }
    const int written = std::snprintf(output, capacity, "%04d-%02d-%02dT%02d:%02d:%02dZ",
        fields.tm_year + 1900, fields.tm_mon + 1, fields.tm_mday,
        fields.tm_hour, fields.tm_min, fields.tm_sec);
    return written > 0 && static_cast<size_t>(written) < capacity;
}
