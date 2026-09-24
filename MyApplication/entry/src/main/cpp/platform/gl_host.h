#pragma once
#include <stdint.h>
#if defined(_WIN32)
#define AMCL_GL_HOST_PUBLIC __declspec(dllexport)
#else
#define AMCL_GL_HOST_PUBLIC __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef struct AmclGlHostInitReportV1 {
    uint32_t structSize;
    uint32_t abiVersion;
    int32_t state;
    int32_t error;
    char stage[64];
} AmclGlHostInitReportV1;
AMCL_GL_HOST_PUBLIC int amclGlHostInitializeV1(AmclGlHostInitReportV1* report);
AMCL_GL_HOST_PUBLIC int amclGlHostGetInitReportV1(AmclGlHostInitReportV1* report);
AMCL_GL_HOST_PUBLIC void* amclGlHostGetProcAddressV1(const char* name);
AMCL_GL_HOST_PUBLIC void* amclGlHostGetEglProcAddressV1(const char* name);
AMCL_GL_HOST_PUBLIC const char* amclGlHostSourceIdentityV1(void);
AMCL_GL_HOST_PUBLIC int amclGlHostMobileGluesBenchmarkProgressV1(void);
AMCL_GL_HOST_PUBLIC const char* amclGlHostMobileGluesBenchmarkRunV1(int startSections, int maxSections);
#ifdef __cplusplus
}
#endif
