#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/**
 * OHOS字典训练的内部排序适配，参数顺序与GNU qsort_r一致。仅在cover.c编译时改名调用；
 * 不导出qsort_r、不影响应用其它库。比较函数须正常返回，不能跨本函数longjmp或抛C++异常。
 */
void AmclZstdQsortR(void* base, size_t count, size_t width,
                   int (*compare)(const void*, const void*, void*), void* context);
#ifdef __cplusplus
}
#endif
