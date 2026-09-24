/**
 * cxxabi_shim.cpp — Minimal C++ ABI shim for libjvm.so on HarmonyOS NEXT
 *
 * Build:
 *   /usr/bin/ohos-clang++ --target=aarch64-linux-ohos --sysroot=/ohos-sysroot-rw \
 *     -shared -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti \
 *     -o /tmp/libcxxabi_shim.so /tmp/cxxabi_shim.cpp \
 *     -fuse-ld=lld -Wl,-soname,libcxxabi_shim.so -nostdlib++ -nodefaultlibs -lc
 */

#include <stdlib.h>
#include <stddef.h>

#define SHIM_EXPORT __attribute__((visibility("default")))

// ============================================================
//  __cxa_* symbols (C++ ABI)
// ============================================================

extern "C" {

SHIM_EXPORT void __cxa_pure_virtual(void) { abort(); }

typedef struct { int done; int waiting; } guard_t;
SHIM_EXPORT int  __cxa_guard_acquire(guard_t* g) { if (g->done) return 0; g->done = 1; return 1; }
SHIM_EXPORT void __cxa_guard_release(guard_t* g) { g->done = 1; }
SHIM_EXPORT void __cxa_guard_abort(guard_t* g)   { g->done = 0; }

SHIM_EXPORT char* __cxa_demangle(const char* mangled, char* buf, unsigned long* len, int* status) {
    if (status) *status = -2;
    return (char*)0;
}

SHIM_EXPORT void* __cxa_begin_catch(void* exc) { return exc; }
SHIM_EXPORT void  __cxa_end_catch(void) {}
SHIM_EXPORT void  __cxa_rethrow(void) { abort(); }
SHIM_EXPORT void* __cxa_allocate_exception(unsigned long size) { return malloc(size); }
SHIM_EXPORT void  __cxa_free_exception(void* exc) { free(exc); }
SHIM_EXPORT void  __cxa_throw(void* exc, void* type, void (*dest)(void*)) { abort(); }

} // extern "C"

// ============================================================
//  std::nothrow
// ============================================================

namespace std {
    struct nothrow_t {};
    SHIM_EXPORT extern const nothrow_t nothrow;
    const nothrow_t nothrow = {};
}

// ============================================================
//  operator new/delete nothrow variants
// ============================================================

SHIM_EXPORT void* operator new(size_t size, const std::nothrow_t&) noexcept {
    return malloc(size);
}
SHIM_EXPORT void* operator new[](size_t size, const std::nothrow_t&) noexcept {
    return malloc(size);
}

// ============================================================
//  Plain operator new/delete and exception handling stubs
//  are now in eh_stubs.c (pure C, linked separately)
// ============================================================

// ============================================================
//  C++ RTTI vtable/typeinfo symbols via inline assembly
//
//  The compiler optimizes away extern "C" data arrays even with
//  __attribute__((used)). Use inline asm to emit them directly.
//
//  Itanium C++ ABI vtable layout:
//    [0] offset-to-top (0)
//    [1] typeinfo pointer
//    [2] virtual dtor 1
//    [3] virtual dtor 2
// ============================================================

// Stub destructor (just returns)
extern "C" SHIM_EXPORT void __shim_stub_dtor(void) {}

// Use asm to define the vtable and typeinfo symbols in .data section
// Each vtable has 4 entries (8 bytes each on aarch64 = 32 bytes)
// Each typeinfo has 2 entries (16 bytes)

__asm__(
    // ---- std::type_info ----
    ".section .data\n"
    ".balign 8\n"

    // typeinfo name string
    "_ZTSSt9type_info_name:\n"
    ".asciz \"St9type_info\"\n"
    ".balign 8\n"

    // _ZTISt9type_info (typeinfo for std::type_info)
    ".global _ZTISt9type_info\n"
    ".type _ZTISt9type_info, @object\n"
    "_ZTISt9type_info:\n"
    ".xword 0\n"                              // vtable ptr (self-referential, simplified)
    ".xword _ZTSSt9type_info_name\n"          // name
    ".size _ZTISt9type_info, .-_ZTISt9type_info\n"

    // _ZTVSt9type_info (vtable for std::type_info)
    ".global _ZTVSt9type_info\n"
    ".type _ZTVSt9type_info, @object\n"
    "_ZTVSt9type_info:\n"
    ".xword 0\n"                              // offset-to-top
    ".xword _ZTISt9type_info\n"               // typeinfo
    ".xword __shim_stub_dtor\n"               // dtor1
    ".xword __shim_stub_dtor\n"               // dtor2
    ".size _ZTVSt9type_info, .-_ZTVSt9type_info\n"

    // ---- __cxxabiv1::__class_type_info ----
    ".balign 8\n"
    "_ZTSN10__cxxabiv117__class_type_infoE_name:\n"
    ".asciz \"N10__cxxabiv117__class_type_infoE\"\n"
    ".balign 8\n"

    ".global _ZTIN10__cxxabiv117__class_type_infoE\n"
    ".type _ZTIN10__cxxabiv117__class_type_infoE, @object\n"
    "_ZTIN10__cxxabiv117__class_type_infoE:\n"
    ".xword _ZTVSt9type_info + 16\n"          // vtable ptr (points past offset-to-top and typeinfo)
    ".xword _ZTSN10__cxxabiv117__class_type_infoE_name\n"
    ".size _ZTIN10__cxxabiv117__class_type_infoE, .-_ZTIN10__cxxabiv117__class_type_infoE\n"

    ".global _ZTVN10__cxxabiv117__class_type_infoE\n"
    ".type _ZTVN10__cxxabiv117__class_type_infoE, @object\n"
    "_ZTVN10__cxxabiv117__class_type_infoE:\n"
    ".xword 0\n"
    ".xword _ZTIN10__cxxabiv117__class_type_infoE\n"
    ".xword __shim_stub_dtor\n"
    ".xword __shim_stub_dtor\n"
    ".size _ZTVN10__cxxabiv117__class_type_infoE, .-_ZTVN10__cxxabiv117__class_type_infoE\n"

    // ---- __cxxabiv1::__si_class_type_info ----
    ".balign 8\n"
    "_ZTSN10__cxxabiv120__si_class_type_infoE_name:\n"
    ".asciz \"N10__cxxabiv120__si_class_type_infoE\"\n"
    ".balign 8\n"

    ".global _ZTIN10__cxxabiv120__si_class_type_infoE\n"
    ".type _ZTIN10__cxxabiv120__si_class_type_infoE, @object\n"
    "_ZTIN10__cxxabiv120__si_class_type_infoE:\n"
    ".xword _ZTVSt9type_info + 16\n"
    ".xword _ZTSN10__cxxabiv120__si_class_type_infoE_name\n"
    ".size _ZTIN10__cxxabiv120__si_class_type_infoE, .-_ZTIN10__cxxabiv120__si_class_type_infoE\n"

    ".global _ZTVN10__cxxabiv120__si_class_type_infoE\n"
    ".type _ZTVN10__cxxabiv120__si_class_type_infoE, @object\n"
    "_ZTVN10__cxxabiv120__si_class_type_infoE:\n"
    ".xword 0\n"
    ".xword _ZTIN10__cxxabiv120__si_class_type_infoE\n"
    ".xword __shim_stub_dtor\n"
    ".xword __shim_stub_dtor\n"
    ".size _ZTVN10__cxxabiv120__si_class_type_infoE, .-_ZTVN10__cxxabiv120__si_class_type_infoE\n"

    // ---- __cxxabiv1::__vmi_class_type_info ----
    ".balign 8\n"
    "_ZTSN10__cxxabiv121__vmi_class_type_infoE_name:\n"
    ".asciz \"N10__cxxabiv121__vmi_class_type_infoE\"\n"
    ".balign 8\n"

    ".global _ZTIN10__cxxabiv121__vmi_class_type_infoE\n"
    ".type _ZTIN10__cxxabiv121__vmi_class_type_infoE, @object\n"
    "_ZTIN10__cxxabiv121__vmi_class_type_infoE:\n"
    ".xword _ZTVSt9type_info + 16\n"
    ".xword _ZTSN10__cxxabiv121__vmi_class_type_infoE_name\n"
    ".size _ZTIN10__cxxabiv121__vmi_class_type_infoE, .-_ZTIN10__cxxabiv121__vmi_class_type_infoE\n"

    ".global _ZTVN10__cxxabiv121__vmi_class_type_infoE\n"
    ".type _ZTVN10__cxxabiv121__vmi_class_type_infoE, @object\n"
    "_ZTVN10__cxxabiv121__vmi_class_type_infoE:\n"
    ".xword 0\n"
    ".xword _ZTIN10__cxxabiv121__vmi_class_type_infoE\n"
    ".xword __shim_stub_dtor\n"
    ".xword __shim_stub_dtor\n"
    ".size _ZTVN10__cxxabiv121__vmi_class_type_infoE, .-_ZTVN10__cxxabiv121__vmi_class_type_infoE\n"

    // ---- __cxxabiv1::__fundamental_type_info ----
    ".balign 8\n"
    "_ZTSN10__cxxabiv123__fundamental_type_infoE_name:\n"
    ".asciz \"N10__cxxabiv123__fundamental_type_infoE\"\n"
    ".balign 8\n"

    ".global _ZTIN10__cxxabiv123__fundamental_type_infoE\n"
    ".type _ZTIN10__cxxabiv123__fundamental_type_infoE, @object\n"
    "_ZTIN10__cxxabiv123__fundamental_type_infoE:\n"
    ".xword _ZTVSt9type_info + 16\n"
    ".xword _ZTSN10__cxxabiv123__fundamental_type_infoE_name\n"
    ".size _ZTIN10__cxxabiv123__fundamental_type_infoE, .-_ZTIN10__cxxabiv123__fundamental_type_infoE\n"

    ".global _ZTVN10__cxxabiv123__fundamental_type_infoE\n"
    ".type _ZTVN10__cxxabiv123__fundamental_type_infoE, @object\n"
    "_ZTVN10__cxxabiv123__fundamental_type_infoE:\n"
    ".xword 0\n"
    ".xword _ZTIN10__cxxabiv123__fundamental_type_infoE\n"
    ".xword __shim_stub_dtor\n"
    ".xword __shim_stub_dtor\n"
    ".size _ZTVN10__cxxabiv123__fundamental_type_infoE, .-_ZTVN10__cxxabiv123__fundamental_type_infoE\n"

    // ---- __cxxabiv1::__pointer_type_info ----
    ".balign 8\n"
    "_ZTSN10__cxxabiv119__pointer_type_infoE_name:\n"
    ".asciz \"N10__cxxabiv119__pointer_type_infoE\"\n"
    ".balign 8\n"

    ".global _ZTIN10__cxxabiv119__pointer_type_infoE\n"
    ".type _ZTIN10__cxxabiv119__pointer_type_infoE, @object\n"
    "_ZTIN10__cxxabiv119__pointer_type_infoE:\n"
    ".xword _ZTVSt9type_info + 16\n"
    ".xword _ZTSN10__cxxabiv119__pointer_type_infoE_name\n"
    ".size _ZTIN10__cxxabiv119__pointer_type_infoE, .-_ZTIN10__cxxabiv119__pointer_type_infoE\n"

    ".global _ZTVN10__cxxabiv119__pointer_type_infoE\n"
    ".type _ZTVN10__cxxabiv119__pointer_type_infoE, @object\n"
    "_ZTVN10__cxxabiv119__pointer_type_infoE:\n"
    ".xword 0\n"
    ".xword _ZTIN10__cxxabiv119__pointer_type_infoE\n"
    ".xword __shim_stub_dtor\n"
    ".xword __shim_stub_dtor\n"
    ".size _ZTVN10__cxxabiv119__pointer_type_infoE, .-_ZTVN10__cxxabiv119__pointer_type_infoE\n"
);
