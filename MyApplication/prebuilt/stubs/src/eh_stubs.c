/* eh_stubs.c — C stubs for C++ exception handling and operator new/delete
 *
 * These symbols are needed by libjimage.so and other JDK .so files
 * that use C++ exceptions. Since we compile with -nostdlib++,
 * we provide minimal stubs that abort on actual exception use.
 *
 * Using pure C avoids name mangling issues with the C++ compiler.
 */
#include <stdlib.h>

#define EH_EXPORT __attribute__((visibility("default")))

/* __gxx_personality_v0 - C++ exception personality function */
EH_EXPORT int __gxx_personality_v0(int version, int actions,
    unsigned long long exceptionClass, void* exceptionObject,
    void* context) {
    abort();
    return 0;
}

/* _Unwind_Resume - resume exception unwinding */
EH_EXPORT void _Unwind_Resume(void* exc) {
    abort();
}

/* _ZSt9terminatev = std::terminate() */
EH_EXPORT void _ZSt9terminatev(void) {
    abort();
}

/* _ZdlPv = operator delete(void*) */
EH_EXPORT void _ZdlPv(void* p) { free(p); }

/* _ZdaPv = operator delete[](void*) */
EH_EXPORT void _ZdaPv(void* p) { free(p); }

/* _Znwm = operator new(unsigned long) */
EH_EXPORT void* _Znwm(unsigned long size) {
    void* p = malloc(size);
    if (!p) abort();
    return p;
}

/* _Znam = operator new[](unsigned long) */
EH_EXPORT void* _Znam(unsigned long size) {
    void* p = malloc(size);
    if (!p) abort();
    return p;
}

/* _ZdlPvm = operator delete(void*, unsigned long) */
EH_EXPORT void _ZdlPvm(void* p, unsigned long s) { free(p); }

/* _ZdaPvm = operator delete[](void*, unsigned long) */
EH_EXPORT void _ZdaPvm(void* p, unsigned long s) { free(p); }
