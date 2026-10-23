#pragma once
// 宿主仅替换 HarmonyOS 日志接口，下载引擎、文件系统和 libcurl 使用真实实现。
#define LOG_APP 0
#define LOG_DOMAIN 0
#define OH_LOG_DEBUG(...) ((void)0)
#define OH_LOG_INFO(...) ((void)0)
#define OH_LOG_WARN(...) ((void)0)
#define OH_LOG_ERROR(...) ((void)0)
#define OH_LOG_FATAL(...) ((void)0)
#define LOG_DEBUG 3
#define LOG_INFO 4
#define LOG_WARN 5
#define LOG_ERROR 6
#define LOG_FATAL 7
inline int OH_LOG_Print(int, int, unsigned int, const char*, const char*, ...) { return 0; }
