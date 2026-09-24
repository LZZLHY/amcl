/** 仅供 Windows 宿主 JNI 回归：将进程/环境 POSIX 接口映射到共享动态 CRT。 */
#ifndef AMCL_JNI_TEST_UNISTD_H
#define AMCL_JNI_TEST_UNISTD_H
#include <process.h>
#include <stdlib.h>
#define getpid _getpid
static inline int setenv(const char* key, const char* value, int overwrite) {
    return !overwrite && getenv(key) ? 0 : _putenv_s(key, value);
}
static inline int unsetenv(const char* key) { return _putenv_s(key, ""); }
#endif
