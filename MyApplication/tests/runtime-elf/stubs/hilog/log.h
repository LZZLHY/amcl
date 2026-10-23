#pragma once
// 宿主测试没有 OHOS 日志服务；保留生产 loader 的错误字符串作为断言对象。
#define LOG_APP 0
#define LOG_CORE 0
#define LOG_DOMAIN 0
#define OH_LOG_INFO(...) ((void)0)
#define OH_LOG_WARN(...) ((void)0)
#define OH_LOG_ERROR(...) ((void)0)
#define OH_LOG_DEBUG(...) ((void)0)
#define OH_LOG_FATAL(...) ((void)0)
