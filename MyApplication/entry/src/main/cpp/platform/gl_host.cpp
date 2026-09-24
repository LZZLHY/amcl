#include "gl_host.h"
#include "amcl_mg_source_identity.h"
#include <MG/init.h>
#include <EGL/egl.h>
#include <cstring>
#include <dlfcn.h>

#ifndef AMCL_MG_BENCHMARK_ENABLED
#define AMCL_MG_BENCHMARK_ENABLED 0
#endif
#if AMCL_MG_BENCHMARK_ENABLED
extern "C" int mg_multidraw_bench_progress(void);
extern "C" const char* mg_multidraw_bench_run(int, int);
#endif

extern "C" void* amclMgRawGlXGetProcAddress(const char*);
extern "C" void* amclMgRawGlXGetProcAddressARB(const char*);
extern "C" __eglMustCastToProperFunctionPointerType amclMgRawEglGetProcAddress(const char*);
extern "C" AMCL_GL_HOST_PUBLIC void* glXGetProcAddress(const char*);
extern "C" AMCL_GL_HOST_PUBLIC void* glXGetProcAddressARB(const char*);

namespace {
void copyReport(AmclGlHostInitReportV1* target, const mg_init_report_v1& source) {
    if (!target || target->structSize < sizeof(AmclGlHostInitReportV1)) return;
    target->structSize = sizeof(AmclGlHostInitReportV1);
    target->abiVersion = 1;
    target->state = source.state;
    target->error = source.error;
    std::memcpy(target->stage, source.stage, sizeof(target->stage));
    target->stage[sizeof(target->stage) - 1] = 0;
}
void* resolverSelf(const char* name) {
    if (!name) return nullptr;
    if (std::strcmp(name, "glXGetProcAddress") == 0) return reinterpret_cast<void*>(&glXGetProcAddress);
    if (std::strcmp(name, "glXGetProcAddressARB") == 0) return reinterpret_cast<void*>(&glXGetProcAddressARB);
    if (std::strcmp(name, "eglGetProcAddress") == 0) return reinterpret_cast<void*>(&eglGetProcAddress);
    return nullptr;
}
void* owned(void* address) {
    if (!address) return nullptr;
    Dl_info owner{}, self{};
    if (!dladdr(address, &owner) || !dladdr(reinterpret_cast<void*>(&amclGlHostSourceIdentityV1), &self)) return nullptr;
    return owner.dli_fbase == self.dli_fbase ? address : nullptr;
}
}
extern "C" int amclGlHostInitializeV1(AmclGlHostInitReportV1* report) {
    mg_init_report_v1 value{sizeof(mg_init_report_v1), MG_INIT_ABI_VERSION, MG_INIT_STATE_COLD, MG_INIT_ERROR_NONE, {0}};
    const int ready = mg_initialize_v1(&value);
    copyReport(report, value);
    return ready;
}
extern "C" int amclGlHostGetInitReportV1(AmclGlHostInitReportV1* report) {
    mg_init_report_v1 value{sizeof(mg_init_report_v1), MG_INIT_ABI_VERSION, MG_INIT_STATE_COLD, MG_INIT_ERROR_NONE, {0}};
    const int state = mg_get_init_report_v1(&value);
    copyReport(report, value);
    return state;
}
extern "C" void* amclGlHostGetProcAddressV1(const char* name) {
    if (void* self = resolverSelf(name)) return self;
    return name ? owned(amclMgRawGlXGetProcAddress(name)) : nullptr;
}
extern "C" void* amclGlHostGetEglProcAddressV1(const char* name) {
    if (void* self = resolverSelf(name)) return self;
    return name ? owned(reinterpret_cast<void*>(amclMgRawEglGetProcAddress(name))) : nullptr;
}
extern "C" const char* amclGlHostSourceIdentityV1(void) { return AMCL_MG_BUILD_IDENTITY; }
extern "C" int amclGlHostMobileGluesBenchmarkProgressV1(void) {
#if AMCL_MG_BENCHMARK_ENABLED
    return mg_multidraw_bench_progress();
#else
    return 0;
#endif
}
extern "C" const char* amclGlHostMobileGluesBenchmarkRunV1(int startSections, int maxSections) {
#if AMCL_MG_BENCHMARK_ENABLED
    return mg_multidraw_bench_run(startSections, maxSections);
#else
    (void)startSections; (void)maxSections; return nullptr;
#endif
}
extern "C" AMCL_GL_HOST_PUBLIC void* glXGetProcAddress(const char* name) { return amclGlHostGetProcAddressV1(name); }
extern "C" AMCL_GL_HOST_PUBLIC void* glXGetProcAddressARB(const char* name) { return amclGlHostGetProcAddressV1(name); }
extern "C" AMCL_GL_HOST_PUBLIC EGLAPI __eglMustCastToProperFunctionPointerType EGLAPIENTRY eglGetProcAddress(const char* name) {
    return reinterpret_cast<__eglMustCastToProperFunctionPointerType>(amclGlHostGetEglProcAddressV1(name));
}
