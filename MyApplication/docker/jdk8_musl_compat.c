/*
 * jdk8_musl_compat.c — musl 兼容垫片：补 JDK 8 native 层引用、但 musl 不提供的 glibc 符号。
 *
 * 编进 libcxxabi_shim.so（JDK 8 的 hotspot/jdk 链接行已带 -lcxxabi_shim），
 * 故无需改 configure 即可对全部 jdk native 库生效。
 * 函数显式 default 可见性，确保被导出。
 *
 * 已知缺失符号（随 build 逐步补充）：
 *   - isnanf / isinff      : musl 无单精度变体（ObjectOutputStream.c 等）
 *   - __xpg_strerror_r     : glibc 的 XSI strerror_r 名；musl 的 strerror_r 即 XSI 版
 */
#include <math.h>
#include <string.h>
#include <stddef.h>

#define EXPORT __attribute__((visibility("default")))

EXPORT int isnanf(float f) { return isnan(f); }
EXPORT int isinff(float f) { return isinf(f); }

EXPORT int __xpg_strerror_r(int errnum, char *buf, size_t buflen) {
    return strerror_r(errnum, buf, buflen);
}

/*
 * JAWT (java.awt 原生接口) 入口符号：JDK 8 headless 构建里这些只存在于 X11 的
 * libawt_xawt（headless 不编），导致 libjawt.so 链接缺符号。MC 不用 JAWT，
 * 这里给空实现满足链接；运行时永不被调用。
 */
EXPORT void  awt_Lock(void *env) { (void)env; }
EXPORT void  awt_Unlock(void *env) { (void)env; }
EXPORT void *awt_GetComponent(void *env, void *p) { (void)env; (void)p; return 0; }
EXPORT void *awt_GetDrawingSurface(void *env, void *p) { (void)env; (void)p; return 0; }
EXPORT void  awt_FreeDrawingSurface(void *p) { (void)p; }
