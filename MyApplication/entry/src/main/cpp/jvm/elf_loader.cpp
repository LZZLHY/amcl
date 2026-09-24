/**
 * elf_loader.cpp — HarmonyOS 签名绕过 ELF 共享库加载器
 *
 * 绕过内核 MAP_XPM 代码签名验证，使用匿名 mmap + pread + mprotect(EXEC)
 * 从 filesDir 加载外部下载的 .so 文件（如多版本 JDK）。
 *
 * 需要 ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY ACL 权限。
 *
 * 与 iOS Amethyst 的 dyld_bypass_validation 类似，但实现方式不同：
 * - iOS: patch dyld 用户态 mmap/fcntl syscall → dlopen 透明绕过
 * - OHOS: 内核 MAP_XPM 不可 patch → 完全绕过 dlopen，自己解析 ELF
 */

#include "elf_loader.h"
#include "elf_input_validation.h"
#include "if_inet6_shim.h"   // fopen 插桩：为 JDK 合成 /proc/net/if_inet6（方案 §四·五 R1）

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <elf.h>
#include <dlfcn.h>
#include <dirent.h>
#include <hilog/log.h>
#include "../utils/amcl_log.h"
#include <pthread.h>
#include <signal.h>
#include <ucontext.h>
#include <vector>
#include <atomic>
#include <string>
#include <unordered_map>

#undef LOG_TAG
#define LOG_TAG "ELF_LOADER"

/* ================================================================
 * Constants
 * ================================================================ */
#define PAGE_SZ         4096
#define PAGE_MASK       (PAGE_SZ - 1)
#define PAGE_ALIGN(x)   (((x) + PAGE_MASK) & ~PAGE_MASK)
#define PAGE_TRUNC(x)   ((x) & ~PAGE_MASK)
#define PFLAGS(f)       ((((f)&PF_R)?PROT_READ:0)|(((f)&PF_W)?PROT_WRITE:0)|(((f)&PF_X)?PROT_EXEC:0))

/* AArch64 relocation types */
#define R_AARCH64_NONE              0
#define R_AARCH64_ABS64           257
#define R_AARCH64_COPY            1024
#define R_AARCH64_GLOB_DAT        1025
#define R_AARCH64_JUMP_SLOT       1026
#define R_AARCH64_RELATIVE        1027
/* R_AARCH64_TLS_DTPREL64 (1029) and R_AARCH64_TLS_DTPMOD64 (1028) are defined in <elf.h> */
#define R_AARCH64_TLS_TPREL64     1030
#define R_AARCH64_TLSDESC         1031
#define R_AARCH64_IRELATIVE       1032

/* ================================================================
 * Internal structures
 * ================================================================ */
struct elf_handle {
    std::string name;
    std::string path;
    uint32_t    magic;          /* 0xE1F10AD for validity check */

    /* Memory mapping */
    void*       base;           /* mmap base address */
    size_t      mapSize;        /* total mmap size */
    size_t      loadBias;       /* min PT_LOAD vaddr (page-truncated) */

    /* File data (read via pread into malloc'd buffer for ELF header/phdr only) */
    Elf64_Ehdr  ehdr;
    Elf64_Phdr* phdr;           /* malloc'd copy of program headers */
    int         fd;             /* kept open for pread during load, closed after */

    /* Dynamic section */
    Elf64_Dyn*  dyn;            /* pointer into mapped memory */
    Elf64_Sym*  dynsym;
    const char* dynstr;
    size_t      dynsymCount;

    /* Hash tables */
    const uint32_t* gnuHash;
    const uint32_t* svHash;     /* SysV DT_HASH */

    /* Init/fini */
    Elf64_Addr  initFunc;
    Elf64_Addr* initArray;
    size_t      initArraySz;
    Elf64_Addr* finiArray;
    size_t      finiArraySz;
    bool        initialized;

    /* RELRO region */
    Elf64_Addr  relroStart;
    Elf64_Addr  relroEnd;

    /* TLS (Thread-Local Storage) */
    size_t      tlsSize;        /* PT_TLS p_memsz */
    size_t      tlsAlign;       /* PT_TLS p_align */
    size_t      tlsFileSize;    /* PT_TLS p_filesz (init image size) */
    void*       tlsInitImage;   /* pointer to TLS init data in mapped memory */
    pthread_key_t tlsKey;       /* per-thread TLS block key */
    bool        hasTls;

    /* .symtab 回退索引（懒构建）：某些 OHOS 交叉编译的 JDK 库把本应导出的符号编成
     * LOCAL、没进 .dynsym（如 libjli 的 JLI_ManifestIterate，被 lld --exclude-libs
     * 本地化）。libinstrument 引用它却动态解析落空 → GOT=0 → PC=0 死循环。为兜住这类
     * 导出缺口，在正常解析全失败后回退扫描各库 .symtab（含 LOCAL 定义符号）。 */
    std::unordered_map<std::string, uint64_t>* symtabIndex;  /* name -> st_value(ELF vaddr) */
    bool        symtabBuilt;
};

#define ELF_HANDLE_MAGIC 0xE1F10AD

/* Convert a virtual address to pointer in mapped memory */
static inline void* vaddr2ptr(elf_handle_t* h, Elf64_Addr vaddr) {
    return (char*)h->base + (vaddr - h->loadBias);
}

/* Forward declarations */
static bool needs_elf_loader(const char* path);
static std::string resolve_path(const char* name);

/* ================================================================
 * Global state
 * ================================================================ */
static char g_error[512] = {0};
static std::vector<elf_handle_t*> g_loaded;  /* ordered by load time */

/* JLI_Launch bypass: fake /proc/self/exe path.
 * JLI reads /proc/self/exe via readlink to get the exec path, then may re-exec.
 * On OHOS /proc/self/exe = /system/bin/appspawn → re-exec fails.
 * Set this to e.g. "/path/to/jdk/bin/java" before calling JLI_Launch to skip re-exec. */
static char g_fakeExePath[512] = {0};

extern "C" void elf_set_fake_exe_path(const char* path) {
    if (path) {
        strncpy(g_fakeExePath, path, sizeof(g_fakeExePath) - 1);
    } else {
        g_fakeExePath[0] = 0;
    }
}

/* Intercepted readlink: returns fake path for /proc/self/exe */
static ssize_t hooked_readlink(const char* pathname, char* buf, size_t bufsiz) {
    if (g_fakeExePath[0] && pathname &&
        (strcmp(pathname, "/proc/self/exe") == 0 || strcmp(pathname, "/proc/curproc/file") == 0)) {
        size_t len = strlen(g_fakeExePath);
        if (len > bufsiz) len = bufsiz;
        memcpy(buf, g_fakeExePath, len);
        return (ssize_t)len;
    }
    return readlink(pathname, buf, bufsiz);
}

static std::unordered_map<std::string, elf_handle_t*> g_byPath;
static std::unordered_map<std::string, elf_handle_t*> g_byName;
static std::string g_searchPaths;

/* Must be defined after g_loaded */
static inline bool is_elf_handle(void* p) {
    if (!p) return false;
    for (auto* h : g_loaded) {
        if ((void*)h == p) return true;
    }
    return false;
}

/* ================================================================
 * TLS (Thread-Local Storage) support
 *
 * TLSDESC on AArch64: each descriptor is {resolver_func_ptr, arg}.
 * Code does: blr resolver → returns offset from tp (tpidr_el0).
 * We allocate TLS blocks via pthread_key and return the block address
 * minus tp as the "offset", so tp + offset = block + var_offset.
 * ================================================================ */

static void tls_destructor(void* block) {
    free(block);
}

static void* tls_get_block(elf_handle_t* h) {
    if (!h->hasTls) return nullptr;
    void* block = pthread_getspecific(h->tlsKey);
    if (!block) {
        /* First access on this thread — allocate and init */
        size_t align = h->tlsAlign ? h->tlsAlign : 16;
        /* aligned_alloc requires size to be a multiple of alignment */
        size_t allocSize = (h->tlsSize + align - 1) & ~(align - 1);
        if (allocSize == 0) allocSize = align;
        block = aligned_alloc(align, allocSize);
        if (!block) return nullptr;
        memset(block, 0, allocSize);
        if (h->tlsInitImage && h->tlsFileSize > 0) {
            memcpy(block, h->tlsInitImage, h->tlsFileSize);
        }
        pthread_setspecific(h->tlsKey, block);
    }
    return block;
}

/* TLSDESC on AArch64:
 * Each descriptor is {resolver_func_ptr, arg}.
 * Code does: ldr x0, [desc]; blr x0  → resolver returns offset from tp.
 * Final address = tpidr_el0 + returned_offset.
 *
 * CRITICAL: The resolver is called from ANY thread, not just the loading thread.
 * We CANNOT precompute absolute addresses — they'd be wrong for other threads.
 *
 * Our approach:
 *   arg = packed pointer to a tlsdesc_data struct {elf_handle*, tls_offset}
 *   resolver: calls a C helper to get the current thread's TLS block,
 *            computes block + offset - tp, returns that.
 *
 * Since the resolver must not clobber registers other than x0 (AArch64 TLSDESC ABI),
 * we use a trampoline that saves/restores all needed registers.
 */
struct tlsdesc_pair {
    void* resolver;
    uint64_t arg;
};

struct tlsdesc_data {
    elf_handle_t* handle;
    uint64_t offset;  /* offset within TLS block */
};

/* Pool of tlsdesc_data — kept alive for the library's lifetime */
static std::vector<tlsdesc_data*> g_tlsdescPool;

/* C helper called by the asm trampoline.
 * Returns: address_of_tls_var - tpidr_el0 */
extern "C" __attribute__((visibility("default")))
int64_t tlsdesc_resolve_helper(tlsdesc_data* data) {
    void* block = tls_get_block(data->handle);
    if (!block) {
        static std::atomic<unsigned> s_nullCount{0};
        if (s_nullCount.fetch_add(1, std::memory_order_relaxed) < 3)
            AMCL_LOG_E(LOG_TAG, "TLSDESC: NULL block! handle=%{public}p offset=%{public}llu tid=%{public}d",
                         (void*)data->handle, (unsigned long long)data->offset, (int)gettid());
        return 0;
    }
    uintptr_t varAddr = (uintptr_t)block + data->offset;
    uintptr_t tp;
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tp));
    int64_t result = (int64_t)(varAddr - tp);
    // 每个线程都会经过此入口；有界诊断计数不能引入数据竞争或持续写同一缓存行。
    static std::atomic<unsigned> s_callCount{0};
    if (s_callCount.load(std::memory_order_relaxed) < 5
        && s_callCount.fetch_add(1, std::memory_order_relaxed) < 5) {
        OH_LOG_INFO(LOG_APP, "TLSDESC: blk=%{public}lx off=%{public}llu var=%{public}lx tp=%{public}lx ret=%{public}lld tid=%{public}d",
                    (unsigned long)block, (unsigned long long)data->offset,
                    (unsigned long)varAddr, (unsigned long)tp, (long long)result, (int)gettid());
    }
    return result;
}

/**
 * AArch64 TLSDESC 使用比普通 C 调用更严格的保存约定：仅 x0 返回 TLS 偏移。
 * C helper 可以破坏 x1..x18 及向量寄存器（v8..v15 也只保留低 64 位），所以跳板
 * 必须保存 x1..x18、完整 q0..q31、帧/返回地址和原条件标志。旧跳板仅保存整数寄存器，
 * 在首次 TLS 分配/初始化调用 libc 时可能破坏调用方仍在使用的浮点数或向量化数据。
 * 栈帧 704 字节、16 字节对齐；192 字节整数/状态区后是 512 字节向量区。
 */
__attribute__((naked, visibility("default")))
void tlsdesc_resolver_asm() {
    __asm__ volatile(
        // BTI c 的兼容 hint 编码，旧 CPU 视为 NOP；间接调用在启用 BTI 时仍可进入。
        "hint #34\n"
        "sub sp, sp, #704\n"
        "stp x29, x30, [sp]\n"
        "stp x1, x2, [sp, #16]\n"
        "stp x3, x4, [sp, #32]\n"
        "stp x5, x6, [sp, #48]\n"
        "stp x7, x8, [sp, #64]\n"
        "stp x9, x10, [sp, #80]\n"
        "stp x11, x12, [sp, #96]\n"
        "stp x13, x14, [sp, #112]\n"
        "stp x15, x16, [sp, #128]\n"
        "stp x17, x18, [sp, #144]\n"
        "mrs x1, nzcv\n"
        "str x1, [sp, #160]\n"
        "mrs x1, fpcr\n"
        "str x1, [sp, #168]\n"
        "mrs x1, fpsr\n"
        "str x1, [sp, #176]\n"
        "stp q0, q1, [sp, #192]\n"
        "stp q2, q3, [sp, #224]\n"
        "stp q4, q5, [sp, #256]\n"
        "stp q6, q7, [sp, #288]\n"
        "stp q8, q9, [sp, #320]\n"
        "stp q10, q11, [sp, #352]\n"
        "stp q12, q13, [sp, #384]\n"
        "stp q14, q15, [sp, #416]\n"
        "stp q16, q17, [sp, #448]\n"
        "stp q18, q19, [sp, #480]\n"
        "stp q20, q21, [sp, #512]\n"
        "stp q22, q23, [sp, #544]\n"
        "stp q24, q25, [sp, #576]\n"
        "stp q26, q27, [sp, #608]\n"
        "stp q28, q29, [sp, #640]\n"
        "stp q30, q31, [sp, #672]\n"
        "ldr x0, [x0, #8]\n"
        "bl tlsdesc_resolve_helper\n"
        "ldp q0, q1, [sp, #192]\n"
        "ldp q2, q3, [sp, #224]\n"
        "ldp q4, q5, [sp, #256]\n"
        "ldp q6, q7, [sp, #288]\n"
        "ldp q8, q9, [sp, #320]\n"
        "ldp q10, q11, [sp, #352]\n"
        "ldp q12, q13, [sp, #384]\n"
        "ldp q14, q15, [sp, #416]\n"
        "ldp q16, q17, [sp, #448]\n"
        "ldp q18, q19, [sp, #480]\n"
        "ldp q20, q21, [sp, #512]\n"
        "ldp q22, q23, [sp, #544]\n"
        "ldp q24, q25, [sp, #576]\n"
        "ldp q26, q27, [sp, #608]\n"
        "ldp q28, q29, [sp, #640]\n"
        "ldp q30, q31, [sp, #672]\n"
        "ldr x1, [sp, #176]\n"
        "msr fpsr, x1\n"
        "ldr x1, [sp, #168]\n"
        "msr fpcr, x1\n"
        "ldr x1, [sp, #160]\n"
        "msr nzcv, x1\n"
        "ldp x17, x18, [sp, #144]\n"
        "ldp x15, x16, [sp, #128]\n"
        "ldp x13, x14, [sp, #112]\n"
        "ldp x11, x12, [sp, #96]\n"
        "ldp x9, x10, [sp, #80]\n"
        "ldp x7, x8, [sp, #64]\n"
        "ldp x5, x6, [sp, #48]\n"
        "ldp x3, x4, [sp, #32]\n"
        "ldp x1, x2, [sp, #16]\n"
        "ldp x29, x30, [sp]\n"
        "add sp, sp, #704\n"
        "ret\n"
    );
}

static void fill_tlsdesc(elf_handle_t* h, tlsdesc_pair* desc, uint64_t tls_offset) {
    /* Allocate a persistent data struct for this descriptor */
    tlsdesc_data* data = new tlsdesc_data();
    data->handle = h;
    data->offset = tls_offset;
    g_tlsdescPool.push_back(data);

    desc->resolver = (void*)tlsdesc_resolver_asm;
    desc->arg = (uint64_t)data;

    /* Ensure the loading thread's TLS block is allocated */
    tls_get_block(h);
}

static void set_error(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_error, sizeof(g_error), fmt, ap);
    va_end(ap);
    AMCL_LOG_E(LOG_TAG, "%{public}s", g_error);
}

/* ================================================================
 * GNU hash lookup (O(1) average for symbol search)
 * ================================================================ */
static uint32_t gnu_hash(const char* name) {
    uint32_t h = 5381;
    for (const unsigned char* p = (const unsigned char*)name; *p; p++)
        h = (h << 5) + h + *p;
    return h;
}

static Elf64_Sym* gnu_lookup(elf_handle_t* h, const char* name) {
    if (!h->gnuHash) return nullptr;
    const uint32_t* ht = h->gnuHash;
    uint32_t nbuckets  = ht[0];
    uint32_t symoffset = ht[1];
    uint32_t bloomSz   = ht[2];
    /* uint32_t bloomShift = ht[3]; */
    const uint64_t* bloom = (const uint64_t*)&ht[4];
    const uint32_t* buckets = (const uint32_t*)&bloom[bloomSz];
    const uint32_t* chain   = &buckets[nbuckets];

    uint32_t hv = gnu_hash(name);

    /* Bloom filter check */
    uint64_t word = bloom[(hv / 64) % bloomSz];
    uint64_t mask = (1ULL << (hv % 64)) | (1ULL << ((hv >> ht[3]) % 64));
    if ((word & mask) != mask) return nullptr;

    uint32_t idx = buckets[hv % nbuckets];
    if (idx < symoffset) return nullptr;

    for (;;) {
        uint32_t chv = chain[idx - symoffset];
        if ((hv | 1) == (chv | 1)) {
            Elf64_Sym* sym = &h->dynsym[idx];
            if (strcmp(h->dynstr + sym->st_name, name) == 0)
                return sym;
        }
        if (chv & 1) break;  /* end of chain */
        idx++;
    }
    return nullptr;
}

/* SysV hash fallback */
static uint32_t sysv_hash(const char* name) {
    uint32_t h = 0, g;
    for (const unsigned char* p = (const unsigned char*)name; *p; p++) {
        h = (h << 4) + *p;
        g = h & 0xf0000000;
        if (g) h ^= g >> 24;
        h &= ~g;
    }
    return h;
}

static Elf64_Sym* sysv_lookup(elf_handle_t* h, const char* name) {
    if (!h->svHash) return nullptr;
    uint32_t nbucket = h->svHash[0];
    uint32_t nchain  = h->svHash[1];
    const uint32_t* bucket = &h->svHash[2];
    const uint32_t* chain  = &bucket[nbucket];
    (void)nchain;

    for (uint32_t i = bucket[sysv_hash(name) % nbucket]; i != 0; i = chain[i]) {
        Elf64_Sym* sym = &h->dynsym[i];
        if (strcmp(h->dynstr + sym->st_name, name) == 0)
            return sym;
    }
    return nullptr;
}

/* ================================================================
 * Symbol resolution
 * ================================================================ */
static void* resolve_in_lib(elf_handle_t* h, const char* name) {
    Elf64_Sym* sym = gnu_lookup(h, name);
    if (!sym) sym = sysv_lookup(h, name);
    if (!sym) {
        /* Linear fallback for libs without hash tables */
        for (size_t i = 0; i < h->dynsymCount; i++) {
            if (h->dynsym[i].st_name == 0) continue;
            if (strcmp(h->dynstr + h->dynsym[i].st_name, name) == 0) {
                sym = &h->dynsym[i];
                break;
            }
        }
    }
    if (!sym) return nullptr;
    if (sym->st_shndx == SHN_UNDEF) return nullptr;
    if (ELF64_ST_TYPE(sym->st_info) == STT_TLS) return nullptr; /* TLS handled separately */
    return vaddr2ptr(h, sym->st_value);
}

/* ================================================================
 * dladdr compatibility — JVM uses dladdr extensively for stack traces
 * ================================================================ */
static int elf_dladdr_impl(const void* addr, Dl_info* info) {
    uintptr_t a = (uintptr_t)addr;
    for (auto* h : g_loaded) {
        uintptr_t base = (uintptr_t)h->base;
        if (a >= base && a < base + h->mapSize) {
            if (info) {
                info->dli_fname = h->path.c_str();
                info->dli_fbase = h->base;
                info->dli_sname = nullptr;
                info->dli_saddr = nullptr;
                /* Find nearest symbol */
                uintptr_t best_dist = (uintptr_t)-1;
                for (size_t i = 0; i < h->dynsymCount; i++) {
                    Elf64_Sym* s = &h->dynsym[i];
                    if (s->st_shndx == SHN_UNDEF || s->st_value == 0) continue;
                    if (ELF64_ST_TYPE(s->st_info) != STT_FUNC &&
                        ELF64_ST_TYPE(s->st_info) != STT_OBJECT) continue;
                    uintptr_t saddr = (uintptr_t)vaddr2ptr(h, s->st_value);
                    if (saddr <= a) {
                        uintptr_t dist = a - saddr;
                        if (dist < best_dist) {
                            best_dist = dist;
                            info->dli_sname = h->dynstr + s->st_name;
                            info->dli_saddr = (void*)saddr;
                        }
                    }
                }
            }
            return 1;
        }
    }
    /* Not in our loaded libs, fall through to system dladdr */
    return dladdr(addr, info);
}

/* Symbols exported from libentry.so that OHOS dlsym(RTLD_DEFAULT) may not find
 * due to linker namespace isolation. We resolve them via dlsym on our own handle. */
static void* s_entryHandle = nullptr;

static void* resolve_from_entry(const char* name) {
    if (!s_entryHandle) {
        /* Open ourselves — libentry.so is already loaded, this just gets a handle */
        s_entryHandle = dlopen("libentry.so", RTLD_NOW | RTLD_NOLOAD);
    }
    if (s_entryHandle) {
        void* p = dlsym(s_entryHandle, name);
        if (p) return p;
    }
    return nullptr;
}

/* Intercept abort/assert from ELF-loaded libraries */
static void elf_abort_impl() {
    OH_LOG_ERROR(LOG_APP, "!!! abort() called from ELF-loaded library !!!"); // 终止钩子由信号安全采集器持久化，不能递归进入 writer。
    abort();
}
static void elf_assert_fail(const char* expr, const char* file, int line, const char* func) {
    OH_LOG_ERROR(LOG_APP, "!!! ASSERT FAILED in ELF lib: %{public}s at %{public}s:%{public}d (%{public}s)", // 终止钩子不进入异步 writer。
                 expr ? expr : "?", file ? file : "?", line, func ? func : "?");
    abort();
}

/* System libraries that OHOS namespace isolation hides from RTLD_DEFAULT.
 * JDK libraries (libzip.so, libnet.so, etc.) depend on these but
 * dlsym(RTLD_DEFAULT) can't find their symbols due to namespace rules.
 * We explicitly dlopen them and search in them as fallback. */
static std::vector<void*> g_sysLibHandles;
static bool g_sysLibsLoaded = false;

static void ensure_sys_libs() {
    if (g_sysLibsLoaded) return;
    g_sysLibsLoaded = true;
    static const char* sysLibs[] = {
        "libz.so",            /* zlib: adler32, crc32, inflate*, deflate* */
        "libstdc++.so",       /* C++ stdlib */
        "libc++.so",          /* LLVM libc++ */
        nullptr
    };
    for (int i = 0; sysLibs[i]; i++) {
        void* h = dlopen(sysLibs[i], RTLD_NOW | RTLD_GLOBAL);
        if (h) {
            g_sysLibHandles.push_back(h);
            OH_LOG_INFO(LOG_APP, "sys lib loaded: %{public}s", sysLibs[i]);
        }
    }
}

/* ----------------------------------------------------------------
 * chmod/fchmod/fchmodat 垫片（沙箱外存储 / 公共下载目录适配）。
 *
 * 公共下载目录(Download/<包名>)是 sdcardfs/FUSE 式挂载：open/read/write/mkdir/unlink
 * 都可用，但**不支持 POSIX 权限位** —— chmod/fchmod 返回 EPERM。MC 的 Fabric 在重映射
 * game jar 时经 jdk.nio.zipfs.ZipFileSystem.sync → Files.setPosixFilePermissions → chmod
 * → EPERM → 启动崩（真机 JavaTrace 实测）。沙箱外的权限位本就是合成的、无实际意义，
 * 故把 EPERM/EACCES 视为成功（文件已按可用权限创建）。仅吞这两种错误，其它透传。
 * 沙箱(filesDir)内 chmod 正常成功(r==0)，wrapper 原样返回，不改变既有行为。
 * ---------------------------------------------------------------- */
typedef int (*chmod_fn)(const char*, mode_t);
typedef int (*fchmod_fn)(int, mode_t);
typedef int (*fchmodat_fn)(int, const char*, mode_t, int);

static bool g_chmodEpermLogged = false;
static void log_chmod_swallow_once(const char* path) {
    if (!g_chmodEpermLogged) {
        g_chmodEpermLogged = true;
        OH_LOG_INFO(LOG_APP, "chmod EPERM on external mount swallowed (perms synthesized): %{public}s",
                    path ? path : "(fd)");
    }
}

static int amcl_chmod(const char* path, mode_t mode) {
    static chmod_fn real = (chmod_fn)dlsym(RTLD_DEFAULT, "chmod");
    if (!real) { errno = ENOSYS; return -1; }
    int r = real(path, mode);
    if (r != 0 && (errno == EPERM || errno == EACCES)) { log_chmod_swallow_once(path); return 0; }
    return r;
}
static int amcl_fchmod(int fd, mode_t mode) {
    static fchmod_fn real = (fchmod_fn)dlsym(RTLD_DEFAULT, "fchmod");
    if (!real) { errno = ENOSYS; return -1; }
    int r = real(fd, mode);
    if (r != 0 && (errno == EPERM || errno == EACCES)) { log_chmod_swallow_once(nullptr); return 0; }
    return r;
}
static int amcl_fchmodat(int dirfd, const char* path, mode_t mode, int flags) {
    static fchmodat_fn real = (fchmodat_fn)dlsym(RTLD_DEFAULT, "fchmodat");
    if (!real) { errno = ENOSYS; return -1; }
    int r = real(dirfd, path, mode, flags);
    if (r != 0 && (errno == EPERM || errno == EACCES)) { log_chmod_swallow_once(path); return 0; }
    return r;
}

/* ----------------------------------------------------------------
 * fopen 垫片（JDK 的 IPv6 能力探测适配）。
 *
 * HarmonyOS 应用沙箱拒绝读 /proc/net/if_inet6（真机 errno=13 EACCES），而上游
 * OpenJDK 的 Linux 分支用"能不能读到这个文件的第一行"回答"本机有没有 IPv6"
 * ⇒ Net.isIPv6Available() 恒 false ⇒ 连 IPv6 地址抛 UnsupportedAddressTypeException。
 * 该文件在 JDK 里有两个消费者（IPv6_supported 与 NetworkInterface 的枚举），
 * 喂饱文件同时喂饱两者。全部策略在 jvm/if_inet6_shim.cpp（含开关与 fail-safe）。
 *
 * 与上面 chmod 家族同一纪律：只处理那一个精确路径，其余原样透传，
 * 且垫片不接管时（返回 NULL）一律回落真 fopen —— 绝不 fail-open。
 * 见 docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §四·五 R1。
 * ---------------------------------------------------------------- */
typedef FILE* (*fopen_fn)(const char*, const char*);

static FILE* amcl_fopen(const char* path, const char* mode) {
    FILE* shimmed = amclIfInet6ShimOpen(path, mode);
    if (shimmed) return shimmed;
    static fopen_fn real = (fopen_fn)dlsym(RTLD_DEFAULT, "fopen");
    if (!real) { errno = ENOSYS; return nullptr; }
    return real(path, mode);
}

/* 懒构建某个已加载 ELF 库的 .symtab 名字→vaddr 索引（含 LOCAL 定义符号）。
 * .symtab 不在 PT_LOAD 段里，需从文件按节头读取。仅在正常解析全失败的回退路径调用，
 * 故一次性开销可接受。失败（文件被删/已 strip 掉 .symtab）则留空。 */
static void build_symtab_index(elf_handle_t* h) {
    if (h->symtabBuilt) return;
    h->symtabBuilt = true;
    int fd = open(h->path.c_str(), O_RDONLY);
    if (fd < 0) return;
    Elf64_Ehdr eh;
    if (pread(fd, &eh, sizeof(eh), 0) != (ssize_t)sizeof(eh)) { close(fd); return; }
    if (eh.e_shoff == 0 || eh.e_shnum == 0 || eh.e_shentsize != sizeof(Elf64_Shdr)) { close(fd); return; }
    size_t shsz = (size_t)eh.e_shnum * eh.e_shentsize;
    Elf64_Shdr* sh = (Elf64_Shdr*)malloc(shsz);
    if (!sh) { close(fd); return; }
    if (pread(fd, sh, shsz, (off_t)eh.e_shoff) != (ssize_t)shsz) { free(sh); close(fd); return; }
    for (int i = 0; i < eh.e_shnum; i++) {
        if (sh[i].sh_type != SHT_SYMTAB) continue;
        uint32_t linkStr = sh[i].sh_link;
        if (linkStr == 0 || linkStr >= (uint32_t)eh.e_shnum) break;
        size_t symBytes = (size_t)sh[i].sh_size;
        size_t strBytes = (size_t)sh[linkStr].sh_size;
        if (symBytes == 0 || strBytes == 0 || sh[i].sh_entsize != sizeof(Elf64_Sym)) break;
        Elf64_Sym* syms = (Elf64_Sym*)malloc(symBytes);
        char* strs = (char*)malloc(strBytes);
        if (syms && strs
            && pread(fd, syms, symBytes, (off_t)sh[i].sh_offset) == (ssize_t)symBytes
            && pread(fd, strs, strBytes, (off_t)sh[linkStr].sh_offset) == (ssize_t)strBytes) {
            h->symtabIndex = new std::unordered_map<std::string, uint64_t>();
            size_t n = symBytes / sizeof(Elf64_Sym);
            for (size_t k = 0; k < n; k++) {
                Elf64_Sym* s = &syms[k];
                if (s->st_shndx == SHN_UNDEF || s->st_value == 0) continue;
                unsigned t = ELF64_ST_TYPE(s->st_info);
                if (t != STT_FUNC && t != STT_OBJECT) continue;
                if ((size_t)s->st_name >= strBytes) continue;
                const char* nm = strs + s->st_name;
                if (nm[0]) h->symtabIndex->emplace(nm, (uint64_t)s->st_value);
            }
            OH_LOG_INFO(LOG_APP, "%{public}s: built .symtab fallback index (%{public}zu entries)",
                        h->name.c_str(), h->symtabIndex->size());
        }
        free(syms); free(strs);
        break;
    }
    free(sh);
    close(fd);
}

static void* resolve_in_symtab(elf_handle_t* h, const char* name) {
    if (!h->symtabBuilt) build_symtab_index(h);
    if (!h->symtabIndex) return nullptr;
    auto it = h->symtabIndex->find(name);
    if (it == h->symtabIndex->end()) return nullptr;
    return vaddr2ptr(h, (Elf64_Addr)it->second);
}

static void* resolve_global(const char* name) {
    /* 1) Intercept dlopen + dlsym + dlclose.
     * dlsym MUST be intercepted because elf_dlopen returns ELF handles
     * that system dlsym doesn't recognize.
     * BUT: elf_dlsym must correctly handle RTLD_NEXT by passing to system
     * dlsym directly (not searching ELF libs for it). */
    if (strcmp(name, "dlopen") == 0) return (void*)elf_dlopen;
    if (strcmp(name, "dlsym")  == 0) return (void*)elf_dlsym;
    if (strcmp(name, "dlclose") == 0) return (void*)elf_dlclose;
    if (strcmp(name, "dladdr") == 0) return (void*)elf_dladdr_impl;
    /* Intercept readlink so JLI_Launch reads our fake /proc/self/exe path
     * instead of /system/bin/appspawn, preventing unwanted re-exec */
    if (strcmp(name, "readlink") == 0 && g_fakeExePath[0]) return (void*)hooked_readlink;

    /* Intercept chmod family so MC running on the public Download mount works.
     * 见上方 amcl_chmod 注释：沙箱外挂载不支持 POSIX 权限位（chmod→EPERM），
     * Fabric 重映射 jar 时经 zipfs.setPosixFilePermissions 触发 → 启动崩。
     * 沙箱内 chmod 正常成功，wrapper 不改变其行为。 */
    if (strcmp(name, "chmod") == 0) return (void*)amcl_chmod;
    if (strcmp(name, "fchmod") == 0) return (void*)amcl_fchmod;
    if (strcmp(name, "fchmodat") == 0) return (void*)amcl_fchmodat;

    /* Intercept fopen so the JDK can answer "does this host have IPv6?".
     * 只有 /proc/net/if_inet6 会被接管，其余路径由 amcl_fopen 原样转给真 fopen。
     * 见上方 amcl_fopen 注释与 jvm/if_inet6_shim.cpp。
     * ⚠️ 四个版本的 libnet.so 都只导入 plain fopen（已逐个核对 .dynsym）；
     *    若将来某版本改用 fopen64，这里要补一条同款。 */
    if (strcmp(name, "fopen") == 0) return (void*)amcl_fopen;

    /* 2) Search in all ELF-loaded libraries (load order) */
    for (auto* h : g_loaded) {
        void* p = resolve_in_lib(h, name);
        if (p) return p;
    }

    /* 3) System libraries via RTLD_DEFAULT */
    void* p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;

    /* 4) Symbols from libentry.so (e.g. __clear_cache) that namespace isolation hides */
    p = resolve_from_entry(name);
    if (p) return p;

    /* 5) Fallback: search in explicitly opened system libs (OHOS namespace workaround) */
    ensure_sys_libs();
    for (auto* sh : g_sysLibHandles) {
        p = dlsym(sh, name);
        if (p) return p;
    }

    /* 6) LAST RESORT: 扫描各 ELF 库的 .symtab（含 LOCAL 定义符号）。
     *    修复 OHOS 交叉编译 JDK 库把本应导出的符号编成 LOCAL 的缺口——典型：libjli 的
     *    JLI_ManifestIterate 被 lld --exclude-libs 本地化、没进 .dynsym，libinstrument
     *    动态引用落空 → GOT=0 → Agent_OnLoad 调用 → 跳 PC=0 无限 SIGSEGV → 第三方皮肤站
     *    (-javaagent) 启动卡死。仅在前面全落空时才走这里，开销一次性。 */
    for (auto* h : g_loaded) {
        p = resolve_in_symtab(h, name);
        if (p) {
            AMCL_LOG_W(LOG_TAG, "resolve_global: '%{public}s' via .symtab fallback in %{public}s (%{public}p)",
                        name, h->name.c_str(), p);
            return p;
        }
    }

    return nullptr;
}

/* ================================================================
 * ELF loading core
 * ================================================================ */

/**
 * 对同一已打开 fd 精确读取，避免短读或 EINTR 被误判为损坏；真实 EOF 必须失败。
 * 输入范围先经纯核心校验，核心仍独立检查 off_t 溢出，防止未来调用方绕过前置条件。
 * 不关闭 fd、不改动句柄归属；失败后由 elf_open 的原有清理路径统一回收映射和 fd。
 */
static bool read_exact(elf_handle_t* h, void* destination, size_t bytes, uint64_t offset, const char* part) {
    using namespace amcl::elfinput;
    const ReadStatus status = ReadFully([h](unsigned char* target, size_t remaining, uint64_t position) {
        const ssize_t count = pread(h->fd, target, remaining, static_cast<off_t>(position));
        return ReadAttempt{static_cast<int64_t>(count), count < 0 && errno == EINTR};
    }, static_cast<unsigned char*>(destination), bytes, offset);
    if (status == ReadStatus::Ok) return true;
    const char* reason = "invalid read result";
    if (status == ReadStatus::EndOfFile) reason = "unexpected EOF (file truncated)";
    else if (status == ReadStatus::IoError) reason = strerror(errno);
    else if (status == ReadStatus::OffsetOverflow) reason = "file offset overflow";
    set_error("%s: pread %s at %llu (%zu bytes): %s", h->path.c_str(), part,
              static_cast<unsigned long long>(offset), bytes, reason);
    return false;
}

/**
 * 先验证文件与程序头，再提交映射布局，确保后续 native 结构体索引使用真实固定尺寸。
 * 不校验/改写节表、符号来源或 namespace；本批不把结构有效等同于可安全执行任意 ELF。
 */
static bool read_headers(elf_handle_t* h, const char* path) {
    static_assert(sizeof(Elf64_Ehdr) == amcl::elfinput::HeaderBytes, "ELF64 header layout changed");
    static_assert(sizeof(Elf64_Phdr) == amcl::elfinput::ProgramHeaderBytes, "ELF64 phdr layout changed");
    static_assert(sizeof(off_t) == sizeof(int64_t), "ELF loader requires 64-bit file offsets");
    h->fd = open(path, O_RDONLY);
    if (h->fd < 0) {
        set_error("open(%s): %s", path, strerror(errno));
        return false;
    }

    struct stat fileStat{};
    if (fstat(h->fd, &fileStat) != 0) {
        set_error("fstat(%s): %s", path, strerror(errno));
        return false;
    }
    if (!S_ISREG(fileStat.st_mode) || fileStat.st_size < static_cast<off_t>(sizeof(Elf64_Ehdr))) {
        set_error("%s: not a regular file or truncated ELF header", path);
        return false;
    }
    if (!read_exact(h, &h->ehdr, sizeof(h->ehdr), 0, "ELF header")) return false;

    amcl::elfinput::Header checkedHeader;
    const char* validationError = nullptr;
    const uint64_t fileBytes = static_cast<uint64_t>(fileStat.st_size);
    if (!amcl::elfinput::ValidateHeader(reinterpret_cast<const unsigned char*>(&h->ehdr), sizeof(h->ehdr),
                                       fileBytes, checkedHeader, validationError)) {
        set_error("%s: %s", path, validationError);
        return false;
    }
    h->phdr = (Elf64_Phdr*)malloc(checkedHeader.programBytes);
    if (!h->phdr) { set_error("malloc phdr"); return false; }
    if (!read_exact(h, h->phdr, checkedHeader.programBytes, checkedHeader.programOffset, "program headers")) return false;
    amcl::elfinput::Layout checkedLayout;
    if (!amcl::elfinput::ValidateProgramHeaders(reinterpret_cast<const unsigned char*>(h->phdr),
            checkedHeader.programBytes, fileBytes, PAGE_SZ, checkedLayout, validationError)) {
        set_error("%s: %s", path, validationError);
        return false;
    }
    h->loadBias = static_cast<size_t>(checkedLayout.loadBias);
    h->mapSize = static_cast<size_t>(checkedLayout.mapBytes);
    return true;
}

/**
 * 使用 read_headers 已验证的布局进行匿名映射；保留既有逐段装载和权限策略。
 * 零内存段没有待装载内容，必须跳过，避免 mmap(..., 0) 或覆盖相邻已装入页。
 * 每次读取仍精确检查 EOF，因此 fstat 后被截断的文件也不会带着不完整代码继续启动。
 */
static bool map_segments(elf_handle_t* h) {
    const size_t minva = h->loadBias;
    const size_t maxva = minva + h->mapSize;

    for (int i = 0; i < h->ehdr.e_phnum; i++) {
        Elf64_Phdr* p = &h->phdr[i];
        if (p->p_type == PT_GNU_RELRO) {
            h->relroStart = p->p_vaddr;
            h->relroEnd   = p->p_vaddr + p->p_memsz;
        }
        if (p->p_type == PT_TLS) {
            h->tlsSize     = p->p_memsz;
            h->tlsFileSize = p->p_filesz;
            h->tlsAlign    = p->p_align;
            h->hasTls      = true;
            /* tlsInitImage will be set after segments are loaded */
        }
    }

    OH_LOG_INFO(LOG_APP, "%{public}s: vaddr range [0x%{public}lx - 0x%{public}lx], mapSize=%{public}zu KB, loadBias=0x%{public}lx",
                h->name.c_str(), (unsigned long)minva, (unsigned long)maxva,
                h->mapSize / 1024, (unsigned long)h->loadBias);

    /* Reserve address range */
    h->base = mmap(NULL, h->mapSize, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (h->base == MAP_FAILED) {
        h->base = nullptr;
        set_error("mmap reserve %zu: %s", h->mapSize, strerror(errno));
        return false;
    }

    /* Load each segment */
    for (int i = 0; i < h->ehdr.e_phnum; i++) {
        Elf64_Phdr* p = &h->phdr[i];
        if (p->p_type != PT_LOAD || p->p_memsz == 0) continue;

        size_t segOff  = p->p_vaddr - minva;
        size_t pageOff = segOff & PAGE_MASK;
        size_t mapOff  = segOff - pageOff;
        size_t mapLen  = PAGE_ALIGN(p->p_memsz + pageOff);
        void*  addr    = (char*)h->base + mapOff;

        /* Map anonymous RW */
        void* m = mmap(addr, mapLen, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
        if (m == MAP_FAILED) {
            set_error("mmap segment %d: %s", i, strerror(errno));
            return false;
        }

        // 读取范围在映射前已验证；系统调用仍可短读或被信号打断，由共享循环处理。
        if (p->p_filesz > 0 && !read_exact(h, (char*)h->base + segOff,
                static_cast<size_t>(p->p_filesz), p->p_offset, "PT_LOAD")) {
            return false;
        }
        /* BSS is already zero from MAP_ANONYMOUS */
    }

    // 原有后续动态表迭代以 DT_NULL 结束。先在已装入的文件模板长度内确认终止项，
    // 避免缺少终止项时穿过段边界；只验证外层表，不改变其中符号/重定位的解释。
    for (int i = 0; i < h->ehdr.e_phnum; i++) {
        const Elf64_Phdr* p = &h->phdr[i];
        if (p->p_type == PT_DYNAMIC && !amcl::elfinput::HasDynamicTerminator(
                static_cast<const unsigned char*>(vaddr2ptr(h, p->p_vaddr)), static_cast<size_t>(p->p_filesz))) {
            set_error("%s: PT_DYNAMIC has no in-range DT_NULL", h->path.c_str());
            return false;
        }
    }

    /* Close fd — all data is in anonymous memory now */
    close(h->fd);
    h->fd = -1;

    /* Initialize TLS if PT_TLS was found */
    if (h->hasTls && h->tlsSize > 0) {
        /* Find PT_TLS vaddr to locate init image in mapped memory */
        for (int i = 0; i < h->ehdr.e_phnum; i++) {
            if (h->phdr[i].p_type == PT_TLS) {
                h->tlsInitImage = vaddr2ptr(h, h->phdr[i].p_vaddr);
                break;
            }
        }
        pthread_key_create(&h->tlsKey, tls_destructor);
        /* Pre-allocate TLS block for current thread */
        tls_get_block(h);
        OH_LOG_INFO(LOG_APP, "%{public}s: TLS block allocated (%zu bytes, align %zu)",
                    h->name.c_str(), h->tlsSize, h->tlsAlign);
    }

    return true;
}

/* Parse PT_DYNAMIC */
static bool parse_dynamic(elf_handle_t* h) {
    h->dyn = nullptr;
    for (int i = 0; i < h->ehdr.e_phnum; i++) {
        if (h->phdr[i].p_type == PT_DYNAMIC) {
            h->dyn = (Elf64_Dyn*)vaddr2ptr(h, h->phdr[i].p_vaddr);
            break;
        }
    }
    if (!h->dyn) { set_error("no PT_DYNAMIC"); return false; }

    Elf64_Addr symtab = 0, strtab = 0;
    size_t strsz = 0;
    Elf64_Addr relaAddr = 0, relaSz = 0;
    Elf64_Addr pltRelAddr = 0, pltRelSz = 0;
    Elf64_Addr initA = 0, initArr = 0, initArrSz = 0;
    Elf64_Addr finiArr = 0, finiArrSz = 0;

    for (Elf64_Dyn* d = h->dyn; d->d_tag != DT_NULL; d++) {
        switch (d->d_tag) {
        case DT_SYMTAB:       symtab = d->d_un.d_ptr; break;
        case DT_STRTAB:       strtab = d->d_un.d_ptr; break;
        case DT_STRSZ:        strsz  = d->d_un.d_val; break;
        case DT_RELA:         relaAddr = d->d_un.d_ptr; break;
        case DT_RELASZ:       relaSz   = d->d_un.d_val; break;
        case DT_JMPREL:       pltRelAddr = d->d_un.d_ptr; break;
        case DT_PLTRELSZ:     pltRelSz   = d->d_un.d_val; break;
        case DT_INIT:         initA = d->d_un.d_ptr; break;
        case DT_INIT_ARRAY:   initArr = d->d_un.d_ptr; break;
        case DT_INIT_ARRAYSZ: initArrSz = d->d_un.d_val; break;
        case DT_FINI_ARRAY:   finiArr = d->d_un.d_ptr; break;
        case DT_FINI_ARRAYSZ: finiArrSz = d->d_un.d_val; break;
        case DT_GNU_HASH:     h->gnuHash = (uint32_t*)vaddr2ptr(h, d->d_un.d_ptr); break;
        case DT_HASH:         h->svHash  = (uint32_t*)vaddr2ptr(h, d->d_un.d_ptr); break;
        }
    }

    if (symtab) h->dynsym = (Elf64_Sym*)vaddr2ptr(h, symtab);
    if (strtab) h->dynstr = (const char*)vaddr2ptr(h, strtab);

    /* Symbol count from SysV hash or GNU hash */
    if (h->svHash) {
        h->dynsymCount = h->svHash[1]; /* nchain */
    } else if (h->gnuHash) {
        /* Walk GNU hash to find max index */
        uint32_t nbuckets  = h->gnuHash[0];
        uint32_t symoffset = h->gnuHash[1];
        uint32_t bloomSz   = h->gnuHash[2];
        const uint64_t* bloom = (const uint64_t*)&h->gnuHash[4];
        const uint32_t* buckets = (const uint32_t*)&bloom[bloomSz];
        const uint32_t* chain   = &buckets[nbuckets];
        uint32_t maxIdx = symoffset;
        for (uint32_t b = 0; b < nbuckets; b++) {
            uint32_t idx = buckets[b];
            if (idx == 0) continue;
            if (idx > maxIdx) maxIdx = idx;
            /* Walk chain to find true max */
            while (!(chain[idx - symoffset] & 1)) idx++;
            if (idx + 1 > maxIdx) maxIdx = idx + 1;
        }
        h->dynsymCount = maxIdx;
    } else {
        h->dynsymCount = 0;
    }

    h->initFunc = initA;
    if (initArr) {
        h->initArray = (Elf64_Addr*)vaddr2ptr(h, initArr);
        h->initArraySz = initArrSz / sizeof(Elf64_Addr);
    }
    if (finiArr) {
        h->finiArray = (Elf64_Addr*)vaddr2ptr(h, finiArr);
        h->finiArraySz = finiArrSz / sizeof(Elf64_Addr);
    }
    return true;
}

/* Load DT_NEEDED dependencies */
static bool load_deps(elf_handle_t* h) {
    if (!h->dyn || !h->dynstr) return true;

    for (Elf64_Dyn* d = h->dyn; d->d_tag != DT_NULL; d++) {
        if (d->d_tag != DT_NEEDED) continue;
        const char* depName = h->dynstr + d->d_un.d_val;

        /* Already loaded by us? */
        if (g_byName.count(depName)) continue;

        /* Try our loader first (only if in search paths) */
        std::string depResolved = resolve_path(depName);
        if (!depResolved.empty()) {
            elf_handle_t* dep = elf_open(depResolved.c_str());
            if (dep) continue;
        }

        /* Fall back to system dlopen (normal for system libs like libc.so) */
        void* sys = dlopen(depName, RTLD_NOW | RTLD_GLOBAL);
        if (!sys) {
            AMCL_LOG_W(LOG_TAG, "dep %{public}s: %{public}s (continuing)", depName, dlerror());
        }
    }
    return true;
}

/* Process relocations */
static bool apply_relocs(elf_handle_t* h) {
    Elf64_Addr relaAddr = 0, relaSz = 0;
    Elf64_Addr pltAddr = 0, pltSz = 0;

    for (Elf64_Dyn* d = h->dyn; d->d_tag != DT_NULL; d++) {
        switch (d->d_tag) {
        case DT_RELA:     relaAddr = d->d_un.d_ptr; break;
        case DT_RELASZ:   relaSz   = d->d_un.d_val; break;
        case DT_JMPREL:   pltAddr  = d->d_un.d_ptr; break;
        case DT_PLTRELSZ: pltSz    = d->d_un.d_val; break;
        }
    }

    int undefCount = 0;
    int totalCount = 0;
    int relativeCount = 0, globdatCount = 0, jmpslotCount = 0;
    int abs64Count = 0, tlsdescCount = 0, irelativeCount = 0, otherCount = 0;
    auto doRela = [&](Elf64_Rela* r, size_t count) -> bool {
        for (size_t i = 0; i < count; i++) {
            totalCount++;
            uint32_t type = ELF64_R_TYPE(r[i].r_info);
            uint32_t si   = ELF64_R_SYM(r[i].r_info);
            void**   slot = (void**)vaddr2ptr(h, r[i].r_offset);
            int64_t  addend = r[i].r_addend;

            switch (type) {
            case R_AARCH64_NONE:
                break;

            case R_AARCH64_RELATIVE: {
                relativeCount++;
                void* val = (char*)h->base + (addend - (int64_t)h->loadBias);
                /* Check for suspicious values that might cause crashes */
                if ((uintptr_t)val == 0xFFFFFFFF || (uintptr_t)val == 0xFFFFFFFFFFFFFFFF) {
                    AMCL_LOG_E(LOG_TAG, "RELATIVE reloc #%{public}d: slot=%{public}p val=%{public}p addend=0x%{public}lx bias=0x%{public}lx",
                                 totalCount, (void*)slot, val, (unsigned long)addend, (unsigned long)h->loadBias);
                }
                *slot = val;
                break;
            }

            case R_AARCH64_IRELATIVE: {
                irelativeCount++;
                typedef void* (*ifunc_t)(void);
                ifunc_t resolver = (ifunc_t)((char*)h->base + (addend - (int64_t)h->loadBias));
                *slot = resolver();
                break;
            }

            case R_AARCH64_GLOB_DAT:
                globdatCount++;
                goto do_sym_reloc;
            case R_AARCH64_JUMP_SLOT:
                jmpslotCount++;
                goto do_sym_reloc;
            case R_AARCH64_ABS64:
                abs64Count++;
            do_sym_reloc: {
                if (si == 0) {
                    *slot = (char*)h->base + (addend - (int64_t)h->loadBias);
                    break;
                }
                Elf64_Sym* sym = &h->dynsym[si];
                const char* sn = h->dynstr + sym->st_name;

                void* sa = nullptr;
                if (sym->st_shndx != SHN_UNDEF && sym->st_value != 0) {
                    sa = vaddr2ptr(h, sym->st_value);
                } else {
                    sa = resolve_global(sn);
                }

                if (!sa && ELF64_ST_BIND(sym->st_info) != STB_WEAK) {
                    undefCount++;
                    if (undefCount <= 10) // 只打印前10个
                        AMCL_LOG_W(LOG_TAG, "undef sym: %{public}s", sn);
                }
                *slot = sa ? (void*)((char*)sa + addend) : nullptr;
                break;
            }

            case R_AARCH64_COPY: {
                if (si == 0) break;
                Elf64_Sym* sym = &h->dynsym[si];
                const char* sn = h->dynstr + sym->st_name;
                void* src = resolve_global(sn);
                if (src && sym->st_size > 0) {
                    memcpy(slot, src, sym->st_size);
                }
                break;
            }

            case R_AARCH64_TLSDESC: {
                tlsdescCount++;
                /* TLSDESC: slot points to a 2-word descriptor {resolver, arg}.
                 * We fill it with our custom resolver + TLS offset. */
                tlsdesc_pair* desc = (tlsdesc_pair*)slot;
                fill_tlsdesc(h, desc, (uint64_t)addend);
                break;
            }

            case R_AARCH64_TLS_TPREL64: {
                /* Static TLS offset from tp. We compute: block_addr + addend - tp */
                void* block = tls_get_block(h);
                if (block) {
                    uintptr_t tp;
                    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tp));
                    *(uint64_t*)slot = (uint64_t)((uintptr_t)block + addend - tp);
                } else {
                    *(uint64_t*)slot = 0;
                }
                break;
            }

            case R_AARCH64_TLS_DTPMOD64:
                /* Module ID — we use 1 for all our loaded libs */
                *(uint64_t*)slot = 1;
                break;

            case R_AARCH64_TLS_DTPREL64:
                /* Offset within TLS block */
                *(uint64_t*)slot = (uint64_t)addend;
                break;

            default:
                otherCount++;
                AMCL_LOG_W(LOG_TAG, "unhandled reloc type %{public}u in %{public}s", type, h->name.c_str());
                break;
            }
        }
        return true;
    };

    if (relaAddr && relaSz) {
        Elf64_Rela* r = (Elf64_Rela*)vaddr2ptr(h, relaAddr);
        if (!doRela(r, relaSz / sizeof(Elf64_Rela))) return false;
    }
    if (pltAddr && pltSz) {
        Elf64_Rela* r = (Elf64_Rela*)vaddr2ptr(h, pltAddr);
        if (!doRela(r, pltSz / sizeof(Elf64_Rela))) return false;
    }
    OH_LOG_INFO(LOG_APP, "%{public}s: relocs done: total=%{public}d RELATIVE=%{public}d GLOB_DAT=%{public}d JUMP_SLOT=%{public}d ABS64=%{public}d TLSDESC=%{public}d IRELATIVE=%{public}d other=%{public}d undef=%{public}d",
                h->name.c_str(), totalCount, relativeCount, globdatCount, jmpslotCount,
                abs64Count, tlsdescCount, irelativeCount, otherCount, undefCount);
    return true;
}

/* 恢复 PT_LOAD 的既有段权限；空段与 map_segments 一致跳过，不对相邻页施加权限。 */
static void protect_segments(elf_handle_t* h) {
    for (int i = 0; i < h->ehdr.e_phnum; i++) {
        Elf64_Phdr* p = &h->phdr[i];
        if (p->p_type != PT_LOAD || p->p_memsz == 0) continue;

        size_t segOff  = p->p_vaddr - h->loadBias;
        size_t start   = PAGE_TRUNC(segOff);
        size_t end     = PAGE_ALIGN(segOff + p->p_memsz);
        int    prot    = PFLAGS(p->p_flags);

        if (mprotect((char*)h->base + start, end - start, prot) != 0) {
            AMCL_LOG_W(LOG_TAG, "mprotect seg %d: %{public}s", i, strerror(errno));
        }
    }

    /* Apply RELRO if present */
    if (h->relroStart < h->relroEnd) {
        size_t start = PAGE_TRUNC(h->relroStart - h->loadBias);
        size_t end   = PAGE_ALIGN(h->relroEnd - h->loadBias);
        mprotect((char*)h->base + start, end - start, PROT_READ);
    }
}

/* Call constructors.
 * Skip .init for libjvm.so — its static constructors are heavy and
 * JNI_CreateJavaVM handles all necessary initialization.
 * Also prevents SIGSEGV from safepoint polling before sigchain is set up. */
static void call_init(elf_handle_t* h) {
    if (h->initialized) return;
    h->initialized = true;

    /* CRITICAL: .init and .init_array values have ALREADY been relocated by
     * R_AARCH64_RELATIVE — they are absolute addresses, NOT virtual addresses.
     * Do NOT use vaddr2ptr() on them! Cast directly to function pointer. */
    if (h->initFunc) {
        /* initFunc was stored as raw vaddr from DT_INIT, NOT yet relocated.
         * DT_INIT is a dynamic tag value, not in a relocation section. */
        void (*initFn)() = (void(*)())vaddr2ptr(h, h->initFunc);
        OH_LOG_INFO(LOG_APP, "%{public}s: calling .init at %{public}p", h->name.c_str(), (void*)initFn);
        initFn();
    }
    if (h->initArray) {
        OH_LOG_INFO(LOG_APP, "%{public}s: calling %{public}zu .init_array entries", h->name.c_str(), h->initArraySz);
        for (size_t i = 0; i < h->initArraySz; i++) {
            /* initArray[i] is ALREADY an absolute address (relocated by R_AARCH64_RELATIVE) */
            void (*fn)() = (void(*)())h->initArray[i];
            if (i < 3 || i % 100 == 0 || i >= h->initArraySz - 3)
                OH_LOG_INFO(LOG_APP, "%{public}s: .init_array[%{public}zu]=%{public}p", h->name.c_str(), i, (void*)fn);
            if (fn && fn != (void(*)())(uintptr_t)-1)
                fn();
        }
    }

}

/* Resolve a file name against search paths */
static std::string resolve_path(const char* name) {
    /* Already absolute */
    if (strchr(name, '/')) {
        struct stat st;
        if (stat(name, &st) == 0) return name;
        return "";
    }

    /* Search paths */
    std::string paths = g_searchPaths;
    if (paths.empty()) return "";

    char* buf = strdup(paths.c_str());
    char* saveptr = nullptr;
    std::string result;
    for (char* dir = strtok_r(buf, ":", &saveptr); dir; dir = strtok_r(nullptr, ":", &saveptr)) {
        std::string candidate = std::string(dir) + "/" + name;
        struct stat st;
        if (stat(candidate.c_str(), &st) == 0) {
            result = candidate;
            break;
        }
    }
    free(buf);
    return result;
}

static void cleanup_handle(elf_handle_t* h) {
    if (h->fd >= 0) { close(h->fd); h->fd = -1; }
    if (h->base) { munmap(h->base, h->mapSize); h->base = nullptr; }
    free(h->phdr); h->phdr = nullptr;
}

/* ================================================================
 * Public C API
 * ================================================================ */

void elf_set_search_path(const char* paths) {
    g_searchPaths = paths ? paths : "";
    OH_LOG_INFO(LOG_APP, "search paths: %{public}s", g_searchPaths.c_str());
}

elf_handle_t* elf_open(const char* path) {
    if (!path || !path[0]) { set_error("null path"); return nullptr; }

    /* Resolve path */
    std::string resolved = resolve_path(path);
    if (resolved.empty()) {
        set_error("%s: not found", path);
        return nullptr;
    }

    /* Already loaded? */
    auto it = g_byPath.find(resolved);
    if (it != g_byPath.end()) return it->second;

    OH_LOG_INFO(LOG_APP, "loading %{public}s", resolved.c_str());

    elf_handle_t* h = new elf_handle_t{};
    /* Note: value-init {} zeroes all POD members while properly constructing
     * std::string members. Do NOT use memset on structs with C++ objects! */
    h->magic = ELF_HANDLE_MAGIC;
    h->fd = -1;
    h->path = resolved;
    const char* slash = strrchr(resolved.c_str(), '/');
    h->name = slash ? (slash + 1) : resolved;

    if (!read_headers(h, resolved.c_str())) goto fail;
    if (!map_segments(h)) goto fail;
    if (!parse_dynamic(h)) goto fail;

    /* Register before loading deps (avoids cycles) */
    g_byPath[resolved] = h;
    g_byName[h->name] = h;
    g_loaded.push_back(h);

    if (!load_deps(h)) goto fail_unreg;
    if (!apply_relocs(h)) goto fail_unreg;

    protect_segments(h);
    call_init(h);

    OH_LOG_INFO(LOG_APP, "loaded %{public}s at %{public}p (%zu bytes, %zu syms)",
                h->name.c_str(), h->base, h->mapSize, h->dynsymCount);
    return h;

fail_unreg:
    g_byPath.erase(resolved);
    g_byName.erase(h->name);
    g_loaded.erase(std::remove(g_loaded.begin(), g_loaded.end(), h), g_loaded.end());
fail:
    cleanup_handle(h);
    delete h;
    return nullptr;
}

void* elf_sym(elf_handle_t* h, const char* name) {
    if (!h || !name) return nullptr;
    return resolve_in_lib(h, name);
}

void* elf_sym_global(const char* name) {
    return resolve_global(name);
}

void elf_close(elf_handle_t* h) {
    if (!h) return;
    /* Call fini_array */
    if (h->finiArray) {
        for (size_t i = h->finiArraySz; i > 0; i--) {
            /* finiArray values are already relocated (absolute addresses) */
            void (*fn)() = (void(*)())h->finiArray[i - 1];
            if (fn && fn != (void(*)())(uintptr_t)-1) fn();
        }
    }
    g_byPath.erase(h->path);
    g_byName.erase(h->name);
    g_loaded.erase(std::remove(g_loaded.begin(), g_loaded.end(), h), g_loaded.end());
    cleanup_handle(h);
    delete h;
}

const char* elf_error(void) {
    return g_error;
}

/* ================================================================
 * HotSpot integration API — transparent dlopen/dlsym replacement
 * ================================================================ */

static bool needs_elf_loader(const char* path) {
    if (!path) return false;
    /* Files in el2 (user data partition) are NOT code-signed → need ELF loader */
    if (strstr(path, "/data/storage/el2/") != nullptr ||
        strstr(path, "/data/app/el2/") != nullptr)
        return true;
    /* Check if the path is within our ELF loader search paths */
    if (!g_searchPaths.empty() && path[0] == '/') {
        char* buf = strdup(g_searchPaths.c_str());
        char* saveptr = nullptr;
        bool match = false;
        for (char* dir = strtok_r(buf, ":", &saveptr); dir; dir = strtok_r(nullptr, ":", &saveptr)) {
            if (strncmp(path, dir, strlen(dir)) == 0) {
                match = true;
                break;
            }
        }
        free(buf);
        if (match) return true;
    }
    return false;
}

void* elf_dlopen(const char* path, int flags) {
    if (!path) return dlopen(nullptr, flags);

    OH_LOG_INFO(LOG_APP, "elf_dlopen: %{public}s (flags=0x%{public}x)", path, flags);

    if (needs_elf_loader(path)) {
        OH_LOG_INFO(LOG_APP, "elf_dlopen: using ELF loader for %{public}s", path);
        elf_handle_t* h = elf_open(path);
        return h ? (void*)h : nullptr;
    }

    /* Try our search paths for bare filenames */
    if (!strchr(path, '/')) {
        std::string resolved = resolve_path(path);
        if (!resolved.empty() && needs_elf_loader(resolved.c_str())) {
            OH_LOG_INFO(LOG_APP, "elf_dlopen: resolved %{public}s → ELF loader", path);
            elf_handle_t* h = elf_open(resolved.c_str());
            if (h) return (void*)h;
        }
    }

    void* ret = dlopen(path, flags);
    if (!ret) {
        AMCL_LOG_W(LOG_TAG, "elf_dlopen(%{public}s) → NULL: %{public}s", path, dlerror());
    }
    return ret;
}

void* elf_dlsym(void* handle, const char* name) {
    if (!name) return nullptr;

    /* RTLD_DEFAULT / RTLD_NEXT: search ELF libs first, then system.
     * CRITICAL: we must NOT pass RTLD_NEXT to system dlsym from here,
     * because RTLD_NEXT is relative to the CALLER — and our caller is
     * libentry.so, not the original ELF-loaded library. */
    if (handle == RTLD_DEFAULT || handle == nullptr) {
        /* Search our ELF-loaded libs first */
        void* p = elf_sym_global(name);
        if (p) return p;
        return dlsym(RTLD_DEFAULT, name);
    }
    if (handle == RTLD_NEXT) {
        /* RTLD_NEXT: caller wants the NEXT library's symbol (skip itself).
         * Key case: libjsig.so calls dlsym(RTLD_NEXT, "sigaction") to get
         * the REAL sigaction from libc, skipping its own wrapper.
         *
         * We use dlsym(RTLD_NEXT, name) from libentry.so's perspective —
         * this searches system libs after libentry.so, which correctly
         * skips all ELF-loaded libs (they're not in the system linker's list).
         * This gives libjsig.so the real libc sigaction, not its own. */
        return dlsym(RTLD_NEXT, name);
    }

    if (is_elf_handle(handle)) {
        return elf_sym((elf_handle_t*)handle, name);
    }
    return dlsym(handle, name);
}

void elf_dlclose(void* handle) {
    if (!handle) return;
    if (is_elf_handle(handle)) {
        elf_close((elf_handle_t*)handle);
    } else {
        dlclose(handle);
    }
}

int elf_dladdr(const void* addr, void* info_ptr) {
    Dl_info* info = (Dl_info*)info_ptr;
    return elf_dladdr_impl(addr, info);
}

int elf_load_directory(const char* dirPath) {
    if (!dirPath) return 0;
    DIR* dir = opendir(dirPath);
    if (!dir) { set_error("opendir(%s): %s", dirPath, strerror(errno)); return 0; }

    int count = 0;
    struct dirent* ent;
    while ((ent = readdir(dir)) != nullptr) {
        size_t len = strlen(ent->d_name);
        if (len < 4 || strcmp(ent->d_name + len - 3, ".so") != 0) continue;
        char full[512];
        snprintf(full, sizeof(full), "%s/%s", dirPath, ent->d_name);
        if (elf_open(full)) count++;
    }
    closedir(dir);
    OH_LOG_INFO(LOG_APP, "loaded %d libs from %{public}s", count, dirPath);
    return count;
}
