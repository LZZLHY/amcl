#ifndef AMCL_HOST_TEST_HILOG_LOG_H
#define AMCL_HOST_TEST_HILOG_LOG_H

#include <utility>

namespace amcl_hilog_stub {
template <typename... Args>
inline void Log(Args&&...) {}
}  // namespace amcl_hilog_stub

#define LOG_APP 0
#define OH_LOG_INFO(...) ::amcl_hilog_stub::Log(__VA_ARGS__)
#define OH_LOG_WARN(...) ::amcl_hilog_stub::Log(__VA_ARGS__)
#define OH_LOG_ERROR(...) ::amcl_hilog_stub::Log(__VA_ARGS__)
#define OH_LOG_DEBUG(...) ::amcl_hilog_stub::Log(__VA_ARGS__)

#endif
