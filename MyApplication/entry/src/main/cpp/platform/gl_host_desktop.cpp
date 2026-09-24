#include "gl_host.h"
#include <dlfcn.h>
#include <cstring>

extern "C" int amclGlHostInitializeV1(AmclGlHostInitReportV1* report) {
    if (report && report->structSize >= sizeof(AmclGlHostInitReportV1)) {
        report->abiVersion = 1; report->state = 1; report->error = 0;
        std::strncpy(report->stage, "desktop-system-provider", sizeof(report->stage) - 1);
        report->stage[sizeof(report->stage) - 1] = 0;
    }
    return 1;
}
extern "C" int amclGlHostGetInitReportV1(AmclGlHostInitReportV1* report) {
    return amclGlHostInitializeV1(report);
}
extern "C" void* amclGlHostGetProcAddressV1(const char* name) {
    if (!name) return nullptr;
    static void* library = dlopen("libGLv4.so", RTLD_NOW | RTLD_LOCAL);
    return library ? dlsym(library, name) : nullptr;
}
extern "C" void* amclGlHostGetEglProcAddressV1(const char* name) {
    return amclGlHostGetProcAddressV1(name);
}
extern "C" const char* amclGlHostSourceIdentityV1(void) {
    return "system-desktop-provider";
}
