#pragma once
#define LOG_APP 0
#define LOG_DEBUG 3
#define LOG_INFO 4
#define LOG_DOMAIN 0
#define LOG_WARN 4
#define LOG_ERROR 5
#define LOG_FATAL 6
// 宿主不写系统日志，但保留实参求值；否则双写宏重复求值的负向用例会假通过。
template <typename... Args> inline void amclTestHilog(Args&&...) {}
#define OH_LOG_VPrint(...) amclTestHilog(__VA_ARGS__)
#define OH_LOG_DEBUG(...) amclTestHilog(__VA_ARGS__)
#define OH_LOG_INFO(...) amclTestHilog(__VA_ARGS__)
#define OH_LOG_WARN(...) amclTestHilog(__VA_ARGS__)
#define OH_LOG_ERROR(...) amclTestHilog(__VA_ARGS__)
#define OH_LOG_FATAL(...) amclTestHilog(__VA_ARGS__)
