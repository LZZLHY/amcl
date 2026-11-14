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
#include "elf_unwind_validation.h"
#include "tls_thread_storage.h"
#include "elf_symbol_versions.h"
#include "../../../../../prebuilt/abi/amcl_unwind_image.h"
#include "../download/hmac_sha256.h"  // 复用纯 SHA-256，精确识别历史 JLI 兼容输入。
#include "if_inet6_shim.h"   // fopen 插桩：为 JDK 合成 /proc/net/if_inet6（方案 §四·五 R1）

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdarg.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <elf.h>
#include <dlfcn.h>
#include <link.h>
#include <dirent.h>
#include <hilog/log.h>
#include "../utils/amcl_log.h"
#include <pthread.h>
#include <poll.h>
#include <signal.h>
#include <ucontext.h>
#include <vector>
#include <atomic>
#include <algorithm>
#include <mutex>
#include <memory>
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
#ifndef R_AARCH64_TLS_DTPMOD64
// glibc 宿主头使用不带 64 的同值名称；保持 AArch64 ABI 编号用于生产与交叉回归。
#define R_AARCH64_TLS_DTPMOD64 1028
#define R_AARCH64_TLS_DTPREL64 1029
#endif
#define R_AARCH64_TLS_TPREL64     1030
#define R_AARCH64_TLSDESC         1031
#define R_AARCH64_IRELATIVE       1032

/* ================================================================
 * Internal structures
 * ================================================================ */
struct LoadBatch;
struct tlsdesc_data;
struct LookupScope;
/** 查找边只记录 DT_NEEDED 顺序；重定位产生的保活边仍留在 dependencies，不能改变 BFS。 */
struct LookupDependency {
    elf_handle_t* custom = nullptr;
    size_t systemIndex = 0;
};
struct ElfMemorySpan { Elf64_Addr begin, end; };
/** 私有namespace映像不能取得独立native引用；在公开iterator的卸载锁内复制只读表，
 * 后续仅把这些数据用于BFS筛选，绝不直接由st_value构造并返回未授权符号地址。 */
struct SystemMetadataCopy {
    std::vector<Elf64_Sym> symbols;
    std::vector<char> strings;
    std::vector<uint32_t> sysv;
    std::vector<uint64_t> gnu;
    std::vector<Elf64_Half> versions;
};
/** 系统库仍由原生 loader 拥有；这里只保存公开 ELF 查询视图及 DT_NEEDED 的有序边。
 * 相应 systemDependencies 引用保持所有表地址有效，实际符号地址必须由原生 dlsym 产生。 */
struct SystemLookupImage {
    const void* identity = nullptr; // 已核同 PHDR 的 PT_DYNAMIC 地址，不解释 opaque handle 的位布局。
    uintptr_t loadBias = 0;
    Elf64_Dyn* dynamic = nullptr;
    std::string path;
    Elf64_Sym* symbols = nullptr;
    const char* strings = nullptr;
    const uint32_t* sysvHash = nullptr;
    const uint32_t* gnuHash = nullptr;
    const Elf64_Half* versions = nullptr;
    amcl::elfversions::Table versionTable; // 复制版本名/索引；与 native 授权查询共同决定 BFS 成员。
    size_t symbolCount = 0, stringBytes = 0, gnuBytes = 0, gnuSymbolEnd = 0;
    std::vector<std::string> neededNames;
    std::vector<size_t> dependencies;
    std::shared_ptr<const SystemMetadataCopy> metadataCopy;
    std::vector<void*> lookupHandles; // 可公开持有的原生祖先；private节点自身无伪造handle。
    std::vector<ElfMemorySpan> mappedSpans;
    uintptr_t tlsModule = 0;
    bool privateView = false;
};
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
    size_t      dynstrSize;
    // 解释输入在重定位前冻结，避免写入某个映射目标时改变后续解释的元数据。
    std::vector<Elf64_Dyn> dynamicStorage;
    std::vector<Elf64_Sym> symbolStorage;
    std::vector<char> stringStorage;
    std::vector<uint32_t> sysvStorage;
    std::vector<uint64_t> gnuStorage;
    std::vector<Elf64_Rela> relocations, pltRelocations;
    amcl::elfversions::Table symbolVersions; // 冻结的默认/显式版本身份，与动态符号同寿命。
    std::vector<ElfMemorySpan> fileSpans, readableFileSpans, memorySpans, executableSpans;
    Elf64_Addr ehFrameAddress, ehHeaderAddress;
    size_t ehFrameSize, ehHeaderSize;
    bool unwindRegistered; // 真实 provider 撤销成功后才允许释放此映射。
    size_t openReferences; // 只计公开 open；DT_NEEDED/重定位绑定由有向依赖边保持。
    size_t threadDestructorReferences; // 系统 C++ TLS 析构队列中尚未返回的自加载回调。
    size_t lookupReferences; // 注册表解锁进入系统 resolver 时暂时保活代码和系统依赖句柄。
    bool finalizing; // 正在执行本批任意 fini/系统关闭，期间整批代码必须仍可访问。
    bool finalized;  // 用户 fini 恰好一次；其中新登记 TLS 析构可延迟物理释放。
    bool nodelete;   // 仅调用方显式RTLD_NODELETE时成为进程期根，普通open不永久驻留。
    bool globalSymbols; // LOCAL 对象仅进入其加载组，不因“已发布”自动进入进程全局查找。
    uint64_t mappingIdentity; // 查找组使用弱成员；地址被复用时不得把新映像误认成旧成员。
    uint64_t initializationOrder;
    bool reachable;
    std::vector<elf_handle_t*> dependencies;
    std::vector<void*> systemDependencies; // private节点为nullptr；公开root引用保活其整个native闭包。
    std::vector<SystemLookupImage> systemImages; // 与系统引用同下标，包含其实际已加载子图。
    std::vector<LookupDependency> neededDependencies;
    std::shared_ptr<LookupScope> handleScope; // 本体与 DT_NEEDED 的缓存 BFS，供显式 handle 查询。
    std::shared_ptr<LookupScope> originScope; // 首次装载组，供调用者的 DEFAULT/NEXT 查询。

    /* Hash tables */
    const uint32_t* gnuHash;
    const uint32_t* svHash;     /* SysV DT_HASH */

    /* Init/fini */
    Elf64_Addr  initFunc;
    Elf64_Addr  finiFunc;
    bool        hasInitFunc, hasFiniFunc;
    Elf64_Addr* initArray;
    size_t      initArraySz;
    Elf64_Addr* finiArray;
    size_t      finiArraySz;
    bool        initialized;
    LoadBatch*  batch;         // 仅在本批链接期间使用；发布后清空。
    bool        constructing;  // 全批重定位完成后，同线程构造重入才可访问。
    bool        unloading;     // 终结期间不得再向调用者发布当前对象。
    bool        published;     // 整个依赖批次完成链接及构造后才能对其他线程可见。
    pthread_t   loadingThread; // 同线程的依赖环/构造重入可以查询本批对象。
    bool        legacyJliChecked;
    bool        legacyJliAllowed;
    Elf64_Addr  legacyManifestAddress; // 仅三个固定历史 libjli 的单符号兼容地址。
    bool        symbolic;             // DT_SYMBOLIC/DF_SYMBOLIC 保持本库定义优先。

    /* RELRO region */
    Elf64_Addr  relroStart;
    Elf64_Addr  relroEnd;

    /* TLS (Thread-Local Storage) */
    size_t      tlsSize;        /* PT_TLS p_memsz */
    size_t      tlsAlign;       /* PT_TLS p_align */
    size_t      tlsFileSize;    /* PT_TLS p_filesz (init image size) */
    void*       tlsInitImage;   /* pointer to TLS init data in mapped memory */
    amcl::tlsstorage::Module* tlsModule; // 复制已重定位模板；真正结束映像生命周期后释放creator。
    amcl::tlsstorage::PreparedBlock tlsPrepared; // 仅构造前失败可回滚，正常执行后不可使用。
    bool        hasTls;
    // 描述符由本映像独占；准备失败或实际映像释放时一并释放，不挂永久全局池。
    std::vector<std::unique_ptr<tlsdesc_data>> tlsDescriptors;

};

#define ELF_HANDLE_MAGIC 0xE1F10AD

/* Convert a virtual address to pointer in mapped memory */
static inline void* vaddr2ptr(elf_handle_t* h, Elf64_Addr vaddr) {
    return (char*)h->base + (vaddr - h->loadBias);
}

/* Forward declarations */
static bool needs_elf_loader(const char* path);
static std::string resolve_path(const char* name);
static void verify_legacy_jli_identity(elf_handle_t* h);
static void* resolve_legacy_manifest(elf_handle_t* h, const char* name);
static elf_handle_t* prepare_elf(const char* path);
static int hooked_cxa_thread_atexit(void (*destructor)(void*), void* object, void* cookie);
static void set_error(const char* fmt, ...);
static elf_handle_t* image_containing_address(const void* address);
static bool span_contains(const std::vector<ElfMemorySpan>& spans, Elf64_Addr address, size_t bytes);

/* ================================================================
 * Global state
 * ================================================================ */
static thread_local char g_error[512] = {0};
static thread_local bool g_errorPending = false;
// 注册表修改和普通符号查询互斥；任意库构造器在释放此锁后运行。
static std::recursive_mutex g_loaderMutex;
// 装载事务采用独立的可重入写者门：另一线程的同库 open 等到完整初始化后重用对象，
// 不返回“正在初始化”这一伪失败。同线程构造器重入仍可完成。此门不用于符号查询、
// TLS 访问或终结，因此 ctor/fini 等待查询线程时不持有注册表锁，也不阻塞这些读者。
// 真实 glibc 对照表明 ctor join 另线程 dlopen 自身本来就是循环等待，不能靠发布半成品解除。
static std::recursive_mutex g_openMutex;
/** 一次装载批次只取得一次系统 PHDR 快照；只复制公开字段，不保留 iterator 的临时指针。 */
struct SystemMappedImage {
    uintptr_t loadBias;
    std::string path;
    std::vector<Elf64_Phdr> headers;
};
/** 一次重定位批次内保活的原生候选视图。即使候选未被本次 dlsym 选中，真实 NOLOAD
 * 引用也保证后续符号查找时映像不会卸载或复用地址；不能只凭 path/裸 handle 缓存。
 * 析构经 SystemLoadScope 归还引用，既不永久 pin，也不携带注册锁执行原生 fini。 */
struct NativeBindingView {
    void* handle = nullptr;
    SystemLookupImage image;
    ~NativeBindingView();
};
struct LoadBatch {
    std::unique_lock<std::recursive_mutex>* registryLock;
    std::vector<elf_handle_t*> created;
    std::vector<elf_handle_t*> linked;
    bool systemSnapshotReady = false;
    std::vector<SystemMappedImage> systemSnapshot;
    std::vector<std::pair<void*, size_t>> systemViews; // 当前批次持有的真实句柄 -> 已核同 PHDR。
    // 只缓存不可变 ELF 元数据，不缓存符号结果、候选集合或缺失结论；每次仍由原生
    // iterator/dlsym 决定当前可见性、版本和选择顺序。构造器运行前显式清空。
    std::vector<std::unique_ptr<NativeBindingView>> nativeBindingViews;
};
static thread_local LoadBatch* g_loadBatch = nullptr;
class RegistryLock;
static thread_local RegistryLock* g_registryLocks = nullptr;
/** 跟踪当前线程真正持有的注册表锁，允许系统查询/IFUNC进入前释放所有递归层级。 */
class RegistryLock : public std::unique_lock<std::recursive_mutex> {
public:
    RegistryLock* previous;
    const void* suspendedBy = nullptr;
    RegistryLock() : std::unique_lock<std::recursive_mutex>(g_loaderMutex), previous(g_registryLocks) {
        g_registryLocks = this;
    }
    ~RegistryLock() { g_registryLocks = previous; }
    RegistryLock(const RegistryLock&) = delete;
    RegistryLock& operator=(const RegistryLock&) = delete;
};

/** 已完成批次可全局使用；同线程递归可引用已经登记的本批次对象。 */
static bool visible_to_caller(const elf_handle_t* h) {
    return !h->unloading && (h->published ||
        (g_loadBatch && h->batch == g_loadBatch) ||
        (h->constructing && pthread_equal(h->loadingThread, pthread_self())));
}
static std::vector<elf_handle_t*> g_loaded;  /* ordered by load time */
static std::atomic<uint64_t> g_initializationOrder{0};
static uint64_t g_mappingIdentity = 0;
struct LookupMember {
    elf_handle_t* owner;
    uint64_t identity;
    bool system;
    size_t systemIndex;
};
struct LookupScope { std::vector<LookupMember> members; };
static std::vector<LookupMember> g_globalScope;
static size_t g_lookupPins = 0;
static bool g_lookupCollectionPending = false;
static int collect_unreferenced_images(std::unique_lock<std::recursive_mutex>&, elf_handle_t*);

/** 系统查询可重入关闭任意对象；本次使用期间的图根不能随注册锁释放一起消失。 */
class LookupPin {
    elf_handle_t* image_;
public:
    explicit LookupPin(elf_handle_t* image) : image_(image) {
        if (image_) { ++image_->lookupReferences; ++g_lookupPins; }
    }
    ~LookupPin() {
        if (!image_) return;
        --image_->lookupReferences;
        --g_lookupPins;
        if (!g_lookupPins && g_lookupCollectionPending) {
            g_lookupCollectionPending = false;
            char saved[sizeof(g_error)]; memcpy(saved, g_error, sizeof(saved));
            const bool pending = g_errorPending;
            try {
                RegistryLock guard;
                if (collect_unreferenced_images(guard, nullptr) != 0) g_lookupCollectionPending = true;
            } catch (...) { g_lookupCollectionPending = true; }
            memcpy(g_error, saved, sizeof(saved)); g_errorPending = pending;
        }
    }
    LookupPin(const LookupPin&) = delete;
    LookupPin& operator=(const LookupPin&) = delete;
};

/** 注册表锁下校验弱成员，先确认指针仍在注册表，再读取身份，避免释放地址复用的 ABA。 */
static bool live_lookup_member(const LookupMember& member) {
    return std::find(g_loaded.begin(), g_loaded.end(), member.owner) != g_loaded.end() &&
        member.owner->mappingIdentity == member.identity && !member.owner->unloading;
}

/** 所有直接依赖先入队再展开下一层；该表在重定位前准备，查找热路径不分配容器。 */
static std::shared_ptr<LookupScope> build_lookup_scope(elf_handle_t* root) {
    auto scope = std::make_shared<LookupScope>();
    scope->members.push_back({root, root->mappingIdentity, false, 0});
    for (size_t at = 0; at < scope->members.size(); ++at) {
        const LookupMember current = scope->members[at];
        auto append = [&](const LookupMember& next) {
            const bool duplicate = std::any_of(scope->members.begin(), scope->members.end(), [&](const LookupMember& value) {
                if (next.system != value.system) return false;
                return next.system ? next.owner->systemImages[next.systemIndex].identity ==
                    value.owner->systemImages[value.systemIndex].identity : next.owner == value.owner;
            });
            if (!duplicate) scope->members.push_back(next);
        };
        if (current.system) {
            for (const size_t child : current.owner->systemImages[current.systemIndex].dependencies)
                append({current.owner, current.identity, true, child});
        } else {
            for (const auto& edge : current.owner->neededDependencies) {
                append(edge.custom ? LookupMember{edge.custom, edge.custom->mappingIdentity, false, 0}
                    : LookupMember{current.owner, current.identity, true, edge.systemIndex});
            }
        }
    }
    return scope;
}

/** GLOBAL 晋升保持调用时顺序；只追加尚未全局化的成员，不重排已有全局对象。 */
static void promote_lookup_scope(const std::shared_ptr<LookupScope>& scope) {
    if (!scope) return;
    g_globalScope.reserve(g_globalScope.size() + scope->members.size());
    for (const auto& member : scope->members) {
        if (!live_lookup_member(member)) continue;
        if (member.system) {
            const bool present = std::any_of(g_globalScope.begin(), g_globalScope.end(), [&](const LookupMember& value) {
                return value.system && value.owner == member.owner && value.identity == member.identity &&
                    value.systemIndex == member.systemIndex;
            });
            if (!present) g_globalScope.push_back(member);
        } else if (!member.owner->globalSymbols) {
            member.owner->globalSymbols = true;
            g_globalScope.push_back(member);
        }
    }
}

/** 同一依赖只保留一个图边，不把环的每条边错误计成永远无法归零的公开 open。 */
static void retain_dependency(elf_handle_t* owner, elf_handle_t* dependency) {
    if (!dependency || dependency == owner) return;
    if (std::find(owner->dependencies.begin(), owner->dependencies.end(), dependency) == owner->dependencies.end())
        owner->dependencies.push_back(dependency);
}

/**
 * 系统 dlopen 也可能执行构造器。暂时脱离当前链接批次并释放注册锁，允许构造器
 * 的工作线程查询 loader；尚未完整链接的外层批次仍不可见。返回后恢复原批次。
 */
struct SystemLoadScope {
    LoadBatch* saved;
    RegistryLock* locks;
    SystemLoadScope() : saved{g_loadBatch}, locks{g_registryLocks} {
        g_loadBatch = nullptr;
        for (auto* lock = locks; lock; lock = lock->previous) {
            if (lock->owns_lock()) { lock->suspendedBy = this; lock->unlock(); }
        }
    }
    ~SystemLoadScope() {
        // 嵌套系统回调可能又使用此协议；只恢复本次释放的层级，不提前恢复外层事务。
        for (auto* lock = locks; lock; lock = lock->previous) {
            if (lock->suspendedBy == this) { lock->lock(); lock->suspendedBy = nullptr; }
        }
        g_loadBatch = saved;
    }
};
NativeBindingView::~NativeBindingView() {
    if (!handle) return;
    SystemLoadScope callbacks;
    dlclose(handle);
}
static void* open_system_library(const char* path, int flags) {
    SystemLoadScope scope;
    return dlopen(path, flags);
}

/** 系统 dlsym 可能执行 IFUNC/resolver；与 dlopen 同样不能携带注册表锁进入任意代码。 */
static void* lookup_system_symbol(void* handle, const char* name, bool& found,
                                  const amcl::elfversions::Request* version = nullptr) {
    SystemLoadScope scope;
    dlerror();
    void* address = nullptr;
    if (version) {
        // 使用真实系统版本查找，不把版本需求降格为同名字命中。平台无入口时准确拒绝。
        using VersionLookup = void* (*)(void*, const char*, const char*);
        auto lookup = reinterpret_cast<VersionLookup>(dlsym(RTLD_DEFAULT, "dlvsym"));
        if (!lookup) { found = false; return nullptr; }
        dlerror();
        address = lookup(handle, name, version->name);
    } else address = dlsym(handle, name);
    found = dlerror() == nullptr;
    return address;
}

/** dlinfo 仅供诊断，不再是装载条件。OHOS 的 dlopen 可以返回随机 opaque handle，而
 * 同版本 dlinfo 仍按旧的直接 dso 指针验证；导出符号存在不能证明此组合可用。 */
#ifdef MC_OHOS_BUILD_TESTS
using SystemDlinfo = int (*)(void*, int, void*);
static SystemDlinfo system_dlinfo() {
    static std::atomic<SystemDlinfo> cached{nullptr};
    if (auto fn = cached.load(std::memory_order_acquire)) return fn;
    SystemLoadScope callbacks;
    Dl_info provider{};
    dladdr(reinterpret_cast<void*>(dlopen), &provider);
    for (const char* name : {provider.dli_fname, "libc.so", "libc.so.6", "libdl.so.2"}) {
        if (!name || !*name) continue;
        void* library = dlopen(name, RTLD_NOW | RTLD_NOLOAD);
        if (!library) continue;
        auto fn = reinterpret_cast<SystemDlinfo>(dlsym(library, "dlinfo"));
        dlclose(library); // provider 本身由宿主的 libc/libdl 依赖保持，不建立额外永久引用。
        if (fn) { cached.store(fn, std::memory_order_release); return fn; }
    }
    return nullptr;
}
#endif

/** 原生 iterator 回调只复制公开 PHDR；NOLOAD/close 必须在迭代返回后调用，避免系统
 * 读写锁升级。重复 open 同一实际对象应给出同一 opaque handle；这里逐次核同，绝不
 * 根据 basename、映射文件位置或随机 handle 的数值形状猜测映像身份。 */
static const SystemMappedImage* system_view_for_handle(LoadBatch& batch, void* handle) {
    for (const auto& known : batch.systemViews)
        if (known.first == handle) return &batch.systemSnapshot[known.second];
    if (!batch.systemSnapshotReady) {
        struct Snapshot { std::vector<SystemMappedImage>* images; bool failed = false; } snapshot{&batch.systemSnapshot};
        dl_iterate_phdr([](dl_phdr_info* view, size_t, void* opaque) -> int {
            auto& target = *static_cast<Snapshot*>(opaque);
            try {
                if (view->dlpi_name && *view->dlpi_name)
                    target.images->push_back({view->dlpi_addr, view->dlpi_name,
                        std::vector<Elf64_Phdr>(view->dlpi_phdr, view->dlpi_phdr + view->dlpi_phnum)});
            } catch (const std::bad_alloc&) { target.failed = true; return 1; }
            return 0;
        }, &snapshot);
        if (snapshot.failed) throw std::bad_alloc();
        batch.systemSnapshotReady = true;
    }
    // 仅测试构建记录 dlinfo 的三个失败分支；正常产品不调用 SDK 未声明的诊断入口。
#ifdef MC_OHOS_BUILD_TESTS
    auto info = system_dlinfo();
    link_map* diagnosticMap = nullptr;
    dlerror();
    const int diagnosticResult = info ? info(handle, RTLD_DI_LINKMAP, &diagnosticMap) : -1;
    const char* diagnosticError = dlerror();
    if (!info || diagnosticResult != 0 || !diagnosticMap) {
        AMCL_LOG_W(LOG_TAG, "system view: optional dlinfo=%{public}s result=%{public}d detail=%{public}s",
            !info ? "symbol-unavailable" : (diagnosticResult != 0 ? "handle-rejected" : "null-linkmap"),
            diagnosticResult, diagnosticError ? diagnosticError : "none");
    }
#endif
    for (size_t index = 0; index < batch.systemSnapshot.size(); ++index) {
        const auto& view = batch.systemSnapshot[index];
        void* reopened = dlopen(view.path.c_str(), RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
        if (!reopened) continue;
        const bool same = reopened == handle;
        const int closed = dlclose(reopened);
        if (closed != 0) { set_error("system PHDR verification failed to release NOLOAD reference"); return nullptr; }
        if (same) {
            batch.systemViews.emplace_back(handle, index);
#ifdef MC_OHOS_BUILD_TESTS
            AMCL_LOG_I(LOG_TAG, "system view: PHDR/NOLOAD identity verified, stableHandle=%{public}p path=%{public}s",
                handle, view.path.c_str());
#endif
            return &view;
        }
    }
    set_error("system dependency handle has no matching accessible PHDR/NOLOAD instance (candidates=%zu)",
        batch.systemSnapshot.size());
    return nullptr;
}

/** 名称预筛只忽略版本选择，不忽略映像边界、定义和可见性；正式查找默认核对版本。 */
static bool system_image_defines(const SystemLookupImage& image, const char* name,
    const Elf64_Sym** definition = nullptr, const amcl::elfversions::Request* version = nullptr,
    bool checkVersion = true);

/** 仅在公开 PHDR 与输入真实句柄核同之后读取元数据。输入句柄仍由原装载事务保活，
 * 因此快照中的对应映像不能在读表期间卸载；其它未匹配快照地址从不解引用。 */
/** 只解释已由公开PHDR给出的映像范围；调用者负责持有原生引用或iterator卸载锁。 */
static bool describe_system_mapped_image(const SystemMappedImage& mapped, SystemLookupImage& image,
                                         bool reportFailure = true, const char* candidateName = nullptr) {
    image.loadBias = mapped.loadBias;
    image.path = mapped.path;
    struct { std::vector<ElfMemorySpan> readable; size_t dynamicBytes = 0; } probe;
    for (const auto& ph : mapped.headers) {
        if (ph.p_type == PT_DYNAMIC) {
            image.dynamic = reinterpret_cast<Elf64_Dyn*>(image.loadBias + ph.p_vaddr);
            image.identity = image.dynamic;
            probe.dynamicBytes = ph.p_memsz;
        }
        if (ph.p_type == PT_LOAD && (ph.p_flags & PF_R))
            probe.readable.push_back({image.loadBias + ph.p_vaddr, image.loadBias + ph.p_vaddr + ph.p_memsz});
        if (ph.p_type == PT_LOAD)
            image.mappedSpans.push_back({image.loadBias + ph.p_vaddr, image.loadBias + ph.p_vaddr + ph.p_memsz});
    }
    // GLOBAL候选枚举也会遇到无动态符号表的主映像。未命中候选不是装载失败，不能为
    // 每个重定位制造错误日志；真正必需的依赖仍默认报告，并由最终提供者资格失败关闭。
    auto reject = [&] {
        if (reportFailure) set_error("system dependency ELF view is incomplete: %s", image.path.c_str());
        return false;
    };
    if (!probe.dynamicBytes || !span_contains(probe.readable, reinterpret_cast<uintptr_t>(image.dynamic),
                                              probe.dynamicBytes)) return reject();
    std::unordered_map<Elf64_Sxword, Elf64_Xword> tags;
    std::vector<size_t> needed;
    bool terminated = false;
    for (size_t i = 0; i < probe.dynamicBytes / sizeof(Elf64_Dyn); ++i) {
        const auto& item = image.dynamic[i];
        if (item.d_tag == DT_NULL) { terminated = true; break; }
        if (item.d_tag == DT_NEEDED) needed.push_back(item.d_un.d_val);
        else tags[item.d_tag] = item.d_un.d_val;
    }
    if (!terminated || tags[DT_SYMENT] != sizeof(Elf64_Sym)) return reject();
    // glibc 会改写部分 DT_* 指针为绝对地址，musl 通常保留相对值；以可读映像范围辨别，
    // 不能仅按地址大小猜测，更不能对字符串偏移（DT_NEEDED/STRSZ）再加 load bias。
    auto pointer = [&](Elf64_Sxword tag, size_t bytes) -> uintptr_t {
        const auto at = tags.find(tag);
        if (at == tags.end()) return 0;
        const uintptr_t raw = at->second;
        if (span_contains(probe.readable, raw, bytes)) return raw;
        if (raw <= UINTPTR_MAX - image.loadBias &&
            span_contains(probe.readable, image.loadBias + raw, bytes)) return image.loadBias + raw;
        return 0;
    };
    image.stringBytes = tags[DT_STRSZ];
    image.strings = reinterpret_cast<const char*>(pointer(DT_STRTAB, image.stringBytes));
    if (!image.stringBytes || !image.strings) return reject();
    if (tags.count(DT_HASH)) {
        const auto table = pointer(DT_HASH, 2 * sizeof(uint32_t));
        if (!table) return reject();
        image.sysvHash = reinterpret_cast<const uint32_t*>(table);
        if (!image.sysvHash[0]) return reject();
        image.symbolCount = image.sysvHash[1];
        const uint64_t words = uint64_t{2} + image.sysvHash[0] + image.sysvHash[1];
        if (words > SIZE_MAX / sizeof(uint32_t) ||
            !span_contains(probe.readable, table, words * sizeof(uint32_t))) return reject();
    }
    if (tags.count(DT_GNU_HASH)) {
        const auto table = pointer(DT_GNU_HASH, 4 * sizeof(uint32_t));
        if (!table) return reject();
        image.gnuHash = reinterpret_cast<const uint32_t*>(table);
        const uint32_t buckets = image.gnuHash[0], first = image.gnuHash[1], bloom = image.gnuHash[2];
        const uint64_t prefix = 16 + uint64_t{bloom} * 8 + uint64_t{buckets} * 4;
        if (!buckets || !bloom || image.gnuHash[3] >= 32 || prefix > SIZE_MAX ||
            !span_contains(probe.readable, table, prefix)) return reject();
        const auto* bucket = reinterpret_cast<const uint32_t*>(table + 16 + size_t{bloom} * 8);
        size_t last = 0;
        for (size_t i = 0; i < buckets; ++i) last = std::max(last, size_t{bucket[i]});
        if (last && last < first) return reject();
        size_t count = first;
        if (last) {
            for (size_t index = last;; ++index) {
                if (index > (SIZE_MAX - prefix) / 4 || index < first) return reject();
                const uintptr_t chain = table + prefix + (index - first) * 4;
                if (!span_contains(probe.readable, chain, 4)) return reject();
                if (*reinterpret_cast<const uint32_t*>(chain) & 1) { count = index + 1; break; }
            }
        }
        if (image.symbolCount && count > image.symbolCount) return reject();
        image.gnuBytes = prefix + (count - first) * 4;
        image.gnuSymbolEnd = count;
        image.symbolCount = std::max(image.symbolCount, count);
    }
    if (!image.symbolCount || image.symbolCount > SIZE_MAX / sizeof(Elf64_Sym)) return reject();
    image.symbols = reinterpret_cast<Elf64_Sym*>(pointer(DT_SYMTAB, image.symbolCount * sizeof(Elf64_Sym)));
    if (!image.symbols) return reject();
    // GLOBAL枚举通常在数百个已加载映像中寻找一个名字。先用已经完整核界的hash、
    // dynsym和dynstr排除没有该定义的映像，避免为每个ABS64重定位反复复制并验证所有
    // 无关库的整张版本表。这里只做保守预筛：所有版本都允许成为候选；真正命中的
    // 映像仍完整解析版本表，且后续NOLOAD保活、native查询和提供者资格校验照常执行。
    // 不缓存未保活的指针，也不把预筛结果直接作为可绑定地址；显式依赖默认不预筛。
    if (candidateName && !system_image_defines(image, candidateName, nullptr, nullptr, false)) return false;
    if (tags.count(DT_VERSYM)) {
        image.versions = reinterpret_cast<const Elf64_Half*>(pointer(DT_VERSYM, image.symbolCount * sizeof(Elf64_Half)));
        if (!image.versions) return reject();
    }
    // native 动态表中的地址可能已由系统重定位。统一成实际指针，再复用有界解析；
    // 不直接把动态表里的 offset 当进程指针，也不只检查 VERSYM 的 hidden 位。
    auto normalizedVersions = tags;
    for (auto tag : {DT_VERSYM, DT_VERDEF, DT_VERNEED}) {
        if (tags.count(tag)) normalizedVersions[tag] = pointer(tag, 1);
    }
    const char* versionError = nullptr;
    if (!amcl::elfversions::parse(image.versionTable, normalizedVersions, image.symbols, image.symbolCount,
                                 image.strings, image.stringBytes,
        [&](uint64_t address, size_t bytes) -> const void* {
            return span_contains(probe.readable, address, bytes) ? reinterpret_cast<const void*>(address) : nullptr;
        }, versionError)) return reject();
    image.neededNames.reserve(needed.size());
    for (size_t offset : needed) {
        if (offset >= image.stringBytes || !memchr(image.strings + offset, 0, image.stringBytes - offset)) return reject();
        image.neededNames.emplace_back(image.strings + offset);
    }
    return true;
}

static bool describe_system_image(void* handle, SystemLookupImage& image) {
    LoadBatch* batch = g_loadBatch;
    if (!batch) { set_error("system ELF view requested outside its owning load transaction"); return false; }
    // 当前调用者已经持有一份成功 open 得到的 native 引用。若另一仍可见 owner 也持有
    // 同一真实 handle，其经过核同的只读表可以复用；两份引用共同排除卸载/地址复用。
    // 只复制表/名称，dependencies 是旧 owner 的数组下标，必须清空后按新 owner 重建。
    // 缓存自然随现有 owner 释放，不增设永久表或额外 native 引用；注册锁保持复制一致。
    for (auto* owner : g_loaded) {
        if (!visible_to_caller(owner)) continue;
        for (size_t index = 0; index < owner->systemImages.size() && index < owner->systemDependencies.size(); ++index) {
            if (owner->systemDependencies[index] != handle) continue;
            image = owner->systemImages[index];
            image.dependencies.clear();
            image.lookupHandles.clear();
            return true;
        }
    }
    SystemLoadScope callbacks;
    const auto* mapped = system_view_for_handle(*batch, handle);
    if (!mapped) return false;
    return describe_system_mapped_image(*mapped, image);
}

/** 在iterator锁仍有效时冻结私有表。shared storage使owner复制/数组扩容后指针仍指向
 * 同一不可变内容；真实代码寿命仍由公开root native引用管理，不由此快照延长。 */
static void freeze_system_metadata(SystemLookupImage& image) {
    auto copy = std::make_shared<SystemMetadataCopy>();
    copy->symbols.assign(image.symbols, image.symbols + image.symbolCount);
    copy->strings.assign(image.strings, image.strings + image.stringBytes);
    if (image.sysvHash) {
        const size_t words = size_t{2} + image.sysvHash[0] + image.sysvHash[1];
        copy->sysv.assign(image.sysvHash, image.sysvHash + words);
        image.sysvHash = copy->sysv.data();
    }
    if (image.gnuHash) {
        const size_t bytes = image.gnuBytes;
        copy->gnu.resize((bytes + 7) / 8);
        memcpy(copy->gnu.data(), image.gnuHash, bytes);
        image.gnuHash = reinterpret_cast<const uint32_t*>(copy->gnu.data());
    }
    if (image.versions) {
        copy->versions.assign(image.versions, image.versions + image.symbolCount);
        image.versions = copy->versions.data();
    }
    image.symbols = copy->symbols.data(); image.strings = copy->strings.data();
    image.metadataCopy = std::move(copy);
    image.privateView = true;
}

/** NOLOAD不可达不等于DT_NEEDED未安装。只从公开PHDR读取候选，不打开私有文件；
 * 元数据在iterator内复制，dlsym在回调外完成。多个同basename候选必须以公开祖先
 * 返回的实际普通定义地址区分，无法唯一核同就明确拒绝，不能任选同名映像。 */
static bool describe_private_system_image(const std::string& needed, const std::vector<void*>& roots,
                                          SystemLookupImage& result) {
    struct Snapshot {
        const std::string* needed;
        std::vector<SystemLookupImage> images;
        bool allocationFailed = false, malformed = false;
    } snapshot{&needed, {}};
    SystemLoadScope callbacks;
    dl_iterate_phdr([](dl_phdr_info* info, size_t bytes, void* opaque) -> int {
        auto& target = *static_cast<Snapshot*>(opaque);
        if (!info->dlpi_name || !*info->dlpi_name) return 0;
        const char* basename = strrchr(info->dlpi_name, '/');
        basename = basename ? basename + 1 : info->dlpi_name;
        if (*target.needed != basename) return 0;
        try {
            SystemMappedImage view{info->dlpi_addr, info->dlpi_name,
                std::vector<Elf64_Phdr>(info->dlpi_phdr, info->dlpi_phdr + info->dlpi_phnum)};
            SystemLookupImage image;
            if (!describe_system_mapped_image(view, image)) { target.malformed = true; return 1; }
            if (bytes >= offsetof(dl_phdr_info, dlpi_tls_modid) + sizeof(info->dlpi_tls_modid))
                image.tlsModule = info->dlpi_tls_modid;
            freeze_system_metadata(image);
            target.images.push_back(std::move(image));
        } catch (const std::bad_alloc&) { target.allocationFailed = true; return 1; }
        return 0;
    }, &snapshot);
    if (snapshot.allocationFailed) throw std::bad_alloc();
    if (snapshot.malformed) return false;
    if (snapshot.images.empty()) {
        set_error("private system dependency has no public PHDR view: %s", needed.c_str()); return false;
    }
    size_t selected = 0;
    if (snapshot.images.size() > 1) {
        size_t proven = 0;
        for (size_t candidate = 0; candidate < snapshot.images.size(); ++candidate) {
            const auto& image = snapshot.images[candidate];
            bool verified = false;
            unsigned attempts = 0;
            for (size_t i = 0; i < image.symbolCount && !verified && attempts < 32; ++i) {
                const auto& sym = image.symbols[i];
                const unsigned type = ELF64_ST_TYPE(sym.st_info), bind = ELF64_ST_BIND(sym.st_info);
                if (sym.st_shndx == SHN_UNDEF || sym.st_shndx == SHN_ABS || !sym.st_value ||
                    (type != STT_FUNC && type != STT_OBJECT) || bind != STB_GLOBAL ||
                    ELF64_ST_VISIBILITY(sym.st_other) != STV_DEFAULT ||
                    (image.versions && ((image.versions[i] & 0x8000) || image.versions[i] == 0)) ||
                    sym.st_name >= image.stringBytes ||
                    !memchr(image.strings + sym.st_name, 0, image.stringBytes - sym.st_name)) continue;
                ++attempts;
                for (void* handle : roots) {
                    bool found = false;
                    void* address = lookup_system_symbol(handle, image.strings + sym.st_name, found);
                    if (found && reinterpret_cast<uintptr_t>(address) == image.loadBias + sym.st_value) {
                        verified = true; break;
                    }
                }
            }
            if (verified) { selected = candidate; ++proven; }
        }
        if (proven != 1) {
            set_error("private system dependency public PHDR identity is ambiguous: %s (candidates=%zu proven=%zu)",
                      needed.c_str(), snapshot.images.size(), proven); return false;
        }
    }
    result = std::move(snapshot.images[selected]);
    result.lookupHandles = roots;
#ifdef MC_OHOS_BUILD_TESTS
    AMCL_LOG_I(LOG_TAG, "system namespace boundary: native-owned private view path=%{public}s roots=%{public}zu symbols=%{public}zu",
               result.path.c_str(), roots.size(), result.symbolCount);
#endif
    return true;
}

#ifdef MC_OHOS_BUILD_TESTS
/** 公开库跨到系统私有namespace的定向诊断，仅在已知失败边执行。
 * 不打开/读取私有DSO，不解释loader私有结构；iterator只复制公开PHDR身份，
 * 原生dlsym在迭代回调外运行，并暂放注册锁。只观察符号地址，不调用任何函数。
 * 诊断保持原装载失败，不能把一次公开API能查到解释成私有闭包已完成资格。
 */
static void diagnose_system_namespace_boundary(const SystemLookupImage& parent, void* handle, const char* needed) {
    struct View { uintptr_t base; std::string path; };
    struct Snapshot { std::vector<View> images; bool failed = false; } snapshot;
    SystemLoadScope callbacks;
    dl_iterate_phdr([](dl_phdr_info* information, size_t, void* opaque) -> int {
        auto& result = *static_cast<Snapshot*>(opaque);
        try {
            if (information->dlpi_name && information->dlpi_name[0])
                result.images.push_back({information->dlpi_addr, information->dlpi_name});
        } catch (...) { result.failed = true; return 1; }
        return 0;
    }, &snapshot);
    if (snapshot.failed) {
        AMCL_LOG_W(LOG_TAG, "system namespace boundary: PHDR snapshot allocation failed parent=%{public}s needed=%{public}s",
                   parent.path.c_str(), needed);
        return;
    }
    size_t candidates = 0;
    for (const auto& view : snapshot.images) {
        const char* basename = strrchr(view.path.c_str(), '/');
        basename = basename ? basename + 1 : view.path.c_str();
        if (strcmp(basename, needed) != 0) continue;
        ++candidates;
        AMCL_LOG_I(LOG_TAG, "system namespace boundary: needed=%{public}s publicPHDR=%{public}s base=%{public}p",
                   needed, view.path.c_str(), reinterpret_cast<void*>(view.base));
    }
    AMCL_LOG_I(LOG_TAG, "system namespace boundary: parent=%{public}s needed=%{public}s phdrCount=%{public}zu exactBasenameCandidates=%{public}zu",
               parent.path.c_str(), needed, snapshot.images.size(), candidates);
    unsigned definitions = 0, imports = 0;
    for (size_t i = 0; i < parent.symbolCount && (definitions < 2 || imports < 6); ++i) {
        const auto& symbol = parent.symbols[i];
        if (ELF64_ST_TYPE(symbol.st_info) != STT_FUNC || ELF64_ST_BIND(symbol.st_info) != STB_GLOBAL ||
            !symbol.st_name || symbol.st_name >= parent.stringBytes) continue;
        const char* name = parent.strings + symbol.st_name;
        if (!memchr(name, 0, parent.stringBytes - symbol.st_name)) continue;
        const bool defined = symbol.st_shndx != SHN_UNDEF;
        if (defined ? definitions >= 2 : imports >= 6) continue;
        if (defined) ++definitions; else ++imports;
        dlerror();
        void* address = dlsym(handle, name);
        const char* lookupError = dlerror();
        const bool found = lookupError == nullptr;
        const std::string detail = lookupError ? lookupError : "";
        Dl_info provider{};
        const bool identified = address && dladdr(address, &provider) != 0;
        size_t originMatches = 0;
        if (identified) {
            for (const auto& view : snapshot.images)
                if (reinterpret_cast<void*>(view.base) == provider.dli_fbase) ++originMatches;
        }
        AMCL_LOG_I(LOG_TAG, "system namespace boundary: kind=%{public}s symbol=%{public}s nativeFound=%{public}d address=%{public}p provider=%{public}s publicPHDRMatches=%{public}zu detail=%{public}s",
                   defined ? "definition" : "import", name, found, address,
                   identified && provider.dli_fname ? provider.dli_fname : "", originMatches, detail.c_str());
    }
}
#endif

/** 把已经由原生 loader 完成的依赖图加入现有 BFS。NOLOAD 只取得所有权，不加载新映像。
 * 子引用追加在全部原始 root 引用之后，因此回滚/正常关闭会先释放这些附加引用；
 * 真正的 root 仍保持其闭包，系统 fini 的顺序继续由原生 loader 决定。 */
static bool prepare_system_scopes(elf_handle_t* owner) {
    owner->systemImages.reserve(owner->systemDependencies.size());
    for (void* handle : owner->systemDependencies) {
        SystemLookupImage image;
        if (!describe_system_image(handle, image)) return false;
        image.lookupHandles.push_back(handle);
        image.dependencies.reserve(image.neededNames.size());
        owner->systemImages.push_back(std::move(image));
    }
    for (size_t index = 0; index < owner->systemImages.size(); ++index) {
        // systemImages 扩容可能移动当前元素，循环中始终通过下标重新取得它；只用公开
        // 已核同 PT_DYNAMIC 身份去重，不能把未核实的路径名字当成映像身份。
        const auto names = owner->systemImages[index].neededNames;
        for (const auto& name : names) {
            owner->systemDependencies.reserve(owner->systemDependencies.size() + 1);
            owner->systemImages.reserve(owner->systemImages.size() + 1);
            void* child = open_system_library(name.c_str(), RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
            // 原生root已经完成真实装载并保活整个系统闭包。private边没有app namespace
            // 独立句柄时保留显式节点和授权祖先，不能把缺NOLOAD误写成依赖未装/跳过图边。
            owner->systemDependencies.push_back(child); // 先交给事务，即使描述元数据分配失败也不会漏引用。
            SystemLookupImage candidate;
            if (child) {
                if (!describe_system_image(child, candidate)) return false;
                candidate.lookupHandles.push_back(child);
            } else if (!describe_private_system_image(name, owner->systemImages[index].lookupHandles, candidate)) {
#ifdef MC_OHOS_BUILD_TESTS
                if (owner->systemDependencies[index])
                    diagnose_system_namespace_boundary(owner->systemImages[index], owner->systemDependencies[index], name.c_str());
#endif
                return false;
            }
            auto existing = std::find_if(owner->systemImages.begin(), owner->systemImages.end(),
                [&](const SystemLookupImage& value) { return value.identity == candidate.identity; });
            size_t target;
            if (existing != owner->systemImages.end()) {
                target = existing - owner->systemImages.begin();
                owner->systemDependencies.pop_back();
                if (child && !owner->systemDependencies[target]) {
                    // 另一公开边能取得同一实际映像时升级为独立引用，不保留较弱的借用视图。
                    auto edges = std::move(existing->dependencies);
                    *existing = std::move(candidate);
                    existing->dependencies = std::move(edges);
                    owner->systemDependencies[target] = child;
                } else {
                    for (void* root : candidate.lookupHandles) {
                        auto& roots = owner->systemImages[target].lookupHandles;
                        if (std::find(roots.begin(), roots.end(), root) == roots.end()) roots.push_back(root);
                    }
                    if (child) { SystemLoadScope callbacks; dlclose(child); }
                }
            } else {
                target = owner->systemImages.size();
                candidate.dependencies.reserve(candidate.neededNames.size());
                owner->systemImages.push_back(std::move(candidate));
            }
            owner->systemImages[index].dependencies.push_back(target);
        }
    }
    // 同一private节点可能被多个公开root的不同路径触达；补齐授权上下文后再发布BFS。
    // 不能只沿第一次碰到的root查符号，否则另一namespace可合法访问的定义会被遗漏。
    bool changed;
    do {
        changed = false;
        for (const auto& parent : owner->systemImages) {
            for (size_t child : parent.dependencies) {
                if (!owner->systemImages[child].privateView) continue;
                auto& roots = owner->systemImages[child].lookupHandles;
                for (void* handle : parent.lookupHandles) {
                    if (std::find(roots.begin(), roots.end(), handle) == roots.end()) {
                        roots.push_back(handle); changed = true;
                    }
                }
            }
        }
    } while (changed);
    return true;
}

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
 * 块由系统原生POD TLS定位到当前线程arena；纯存储观察者确认OS线程消失后回收。
 * C++用户析构仍使用真实系统队列。不存在逐模块pthread-key提前释放普通TLS的问题。
 * ================================================================ */

alignas(amcl::tlsstorage::Coordinator) static unsigned char g_tlsStorageMemory[sizeof(amcl::tlsstorage::Coordinator)];
static amcl::tlsstorage::Coordinator* g_tlsStorage = nullptr;
static pthread_mutex_t g_tlsRuntimeMutex = PTHREAD_MUTEX_INITIALIZER;
static std::atomic<pid_t> g_tlsRuntimeProcess{0};
static bool g_tlsReaperRunning = false;

/** 常驻宿主的唯一纯存储观察线程。它不调用用户dtor/fini、不接触loader图或EH状态。
 * Coordinator用placement构造，不注册静态析构；不能在主线程退出时删除其它线程的TLS。
 * 明确未知的OS查询不会被当作终态；每秒独立重验能力，只有完整新观察成功才重新扩张。 */
static void* tls_storage_reaper(void* context) {
    auto* storage = static_cast<amcl::tlsstorage::Coordinator*>(context);
    unsigned retries = 0;
    for (;;) {
        storage->Sweep();
        const auto stats = storage->Snapshot();
        if (stats.expansionError && ++retries >= 10) {
            storage->RecheckCapability();
            retries = 0;
        } else if (!stats.expansionError) retries = 0;
        // 活跃时100ms观察；完全没有arena时只保留1Hz唤醒。具体CPU/峰值资格另由目标测量。
        int result;
        do { result = poll(nullptr, 0, stats.registeredArenas ? 100 : 1000); } while (result < 0 && errno == EINTR);
    }
    return nullptr;
}

/** 只在加载冷路径建立宿主观察者。启动失败可重试，不把一次EAGAIN变为永久不可用。
 * 测试可在首次初始化前传纯存储故障函数；生产始终使用默认真实分配和OS观察。
 * 在任何锁前核进程，避免fork child接管父进程线程/锁。普通resolver另由核心fork门拒绝。 */
static int ensure_tls_runtime(amcl::tlsstorage::Functions functions = {}) {
    const pid_t actual = getpid();
    pid_t expected = 0;
    if (!g_tlsRuntimeProcess.compare_exchange_strong(expected, actual) && expected != actual) return ECHILD;
    int error = pthread_mutex_lock(&g_tlsRuntimeMutex);
    if (error) return error;
    struct Unlock { ~Unlock() { pthread_mutex_unlock(&g_tlsRuntimeMutex); } } unlock;
    if (!g_tlsStorage) {
        auto* created = new(g_tlsStorageMemory) amcl::tlsstorage::Coordinator;
        error = created->Initialize(functions);
        if (error) return error;
        g_tlsStorage = created;
    }
    if (g_tlsReaperRunning) return 0;
    pthread_attr_t attributes;
    error = pthread_attr_init(&attributes);
    if (error) return error;
    struct Attributes { pthread_attr_t* value; ~Attributes() { pthread_attr_destroy(value); } } cleanup{&attributes};
    error = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    const long minimumStack = PTHREAD_STACK_MIN;
    if (!error && minimumStack <= 0) error = EINVAL;
    if (!error) error = pthread_attr_setstacksize(&attributes,
        std::max(size_t{64 * 1024}, static_cast<size_t>(minimumStack)));
    pthread_t observer;
    if (!error) error = pthread_create(&observer, &attributes, tls_storage_reaper, g_tlsStorage);
    if (!error) g_tlsReaperRunning = true;
    return error;
}

/**
 * 热命中仅访问当前线程的原生POD槽及缓存/哈希；无注册锁、系统调用或分配。
 * 失败只由返回error解释，不能把nullptr变成看似合法TP偏移。
 */
static void* tls_get_block(elf_handle_t* h) {
    if (!h->hasTls || !h->tlsModule) { errno = EINVAL; return nullptr; }
    const auto block = g_tlsStorage->GetBlock(h->tlsModule);
    if (!block.address) errno = block.error;
    return block.address;
}

/** PT_TLS模板可能包含RELATIVE/ABS64指针，必须等整批重定位完成后才复制/预热。
 * 失败仍在任何用户构造器之前，模块/预备块由正常批次回滚拥有。 */
static bool prepare_tls_storage(elf_handle_t* h) {
    if (!h->hasTls) return true;
    int error = ensure_tls_runtime();
    if (error) { set_error("%s: TLS observer: %s", h->name.c_str(), strerror(error)); return false; }
    h->tlsModule = g_tlsStorage->CreateModule(h->tlsInitImage, h->tlsFileSize, h->tlsSize, h->tlsAlign, error);
    if (!h->tlsModule) { set_error("%s: TLS template: %s", h->name.c_str(), strerror(error)); return false; }
    const auto prepared = g_tlsStorage->PrepareBlock(h->tlsModule);
    if (!prepared.address) { set_error("%s: TLS preparation: %s", h->name.c_str(), strerror(prepared.error)); return false; }
    h->tlsPrepared = prepared.rollback;
    return true;
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

/** 运行中 TLS 没有可返回的错误值；只用固定文本/write 诊断，避免 OOM 路径再次分配。 */
[[noreturn]] static void tls_resolution_failure() {
    static const char message[] = "AMCL: TLS allocation or registration failed; refusing invalid thread address\n";
    const ssize_t written = write(STDERR_FILENO, message, sizeof(message) - 1);
    (void)written;
    abort();
}

/* C helper called by the asm trampoline.
 * Returns: address_of_tls_var - tpidr_el0 */
extern "C" __attribute__((visibility("default")))
int64_t tlsdesc_resolve_helper(tlsdesc_data* data) {
    void* block = tls_get_block(data->handle);
    if (!block) tls_resolution_failure();
    uintptr_t varAddr = (uintptr_t)block + data->offset;
    uintptr_t tp;
    __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tp));
    int64_t result = (int64_t)(varAddr - tp);
    // 合法结果可能恰好为 0；只检查分配/登记结果，不把数值零本身当成错误。
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
    // vector 扩容抛错时 unique_ptr 仍回收尚未提交的节点，避免准备失败漏掉半个描述符。
    auto data = std::make_unique<tlsdesc_data>();
    data->handle = h;
    data->offset = tls_offset;
    const auto address = reinterpret_cast<uint64_t>(data.get());
    h->tlsDescriptors.push_back(std::move(data));
    desc->resolver = (void*)tlsdesc_resolver_asm;
    desc->arg = address;
}

static void set_error(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_error, sizeof(g_error), fmt, ap);
    va_end(ap);
    g_errorPending = true;
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

/** 过滤定义、可见性及 ELF 版本；在 hash 链遍历内执行，允许继续寻找同名默认版本。 */
static bool matches_export(elf_handle_t* h, size_t index, const char* name,
                           const amcl::elfversions::Request* version) {
    if (index >= h->dynsymCount) return false;
    const auto& symbol = h->dynsym[index];
    const unsigned binding = ELF64_ST_BIND(symbol.st_info), visibility = ELF64_ST_VISIBILITY(symbol.st_other);
    return symbol.st_shndx != SHN_UNDEF &&
        (binding == STB_GLOBAL || binding == STB_WEAK || binding == STB_GNU_UNIQUE) &&
        (visibility == STV_DEFAULT || visibility == STV_PROTECTED) &&
        h->symbolVersions.accepts(index, version) && strcmp(h->dynstr + symbol.st_name, name) == 0;
}
static Elf64_Sym* gnu_lookup(elf_handle_t* h, const char* name,
                            const amcl::elfversions::Request* version = nullptr) {
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
            if (matches_export(h, idx, name, version))
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

static Elf64_Sym* sysv_lookup(elf_handle_t* h, const char* name,
                             const amcl::elfversions::Request* version = nullptr) {
    if (!h->svHash) return nullptr;
    uint32_t nbucket = h->svHash[0];
    uint32_t nchain  = h->svHash[1];
    const uint32_t* bucket = &h->svHash[2];
    const uint32_t* chain  = &bucket[nbucket];
    (void)nchain;

    for (uint32_t i = bucket[sysv_hash(name) % nbucket]; i != 0; i = chain[i]) {
        Elf64_Sym* sym = &h->dynsym[i];
        if (matches_export(h, i, name, version))
            return sym;
    }
    return nullptr;
}

/** 原生 handle 的 dlsym 会继续搜索整棵子图，因此先确认当前 BFS 节点具有默认可见定义。
 * 这里只筛选定义，IFUNC resolver、TLS 地址、GNU unique 和版本选择仍由原生 dlsym 处理。 */
static bool system_image_defines(const SystemLookupImage& image, const char* name, const Elf64_Sym** definition,
                                 const amcl::elfversions::Request* version, bool checkVersion) {
    auto matches = [&](size_t index) {
        if (index >= image.symbolCount) return false;
        const auto& symbol = image.symbols[index];
        const unsigned binding = ELF64_ST_BIND(symbol.st_info), visibility = ELF64_ST_VISIBILITY(symbol.st_other);
        if (symbol.st_shndx == SHN_UNDEF ||
            (binding != STB_GLOBAL && binding != STB_WEAK && binding != STB_GNU_UNIQUE) ||
            (visibility != STV_DEFAULT && visibility != STV_PROTECTED)) return false;
        // 非默认的 foo@OLD 不能占用 foo 的 BFS 位置；继续同名 hash chain 才能找到 foo@@NEW。
        if (checkVersion && !image.versionTable.accepts(index, version)) return false;
        const bool matched = symbol.st_name < image.stringBytes &&
            memchr(image.strings + symbol.st_name, 0, image.stringBytes - symbol.st_name) &&
            strcmp(image.strings + symbol.st_name, name) == 0;
        if (matched && definition) *definition = &symbol;
        return matched;
    };
    if (const uint32_t* hash = image.gnuHash) {
        const uint32_t value = gnu_hash(name), first = hash[1];
        const auto* bloom = reinterpret_cast<const uint64_t*>(hash + 4);
        const uint64_t mask = (uint64_t{1} << (value % 64)) | (uint64_t{1} << ((value >> hash[3]) % 64));
        if ((bloom[(value / 64) % hash[2]] & mask) != mask) return false;
        const auto* buckets = reinterpret_cast<const uint32_t*>(bloom + hash[2]);
        const uint32_t* chain = buckets + hash[0];
        size_t index = buckets[value % hash[0]];
        if (index < first) return false;
        for (; index < image.symbolCount && index < image.gnuSymbolEnd; ++index) {
            const uint32_t current = chain[index - first];
            if ((value | 1) == (current | 1) && matches(index)) return true;
            if (current & 1) break;
        }
    } else if (const uint32_t* hash = image.sysvHash) {
        const uint32_t* bucket = hash + 2;
        const uint32_t* chain = bucket + hash[0];
        size_t remaining = image.symbolCount;
        for (size_t index = bucket[sysv_hash(name) % hash[0]];
             index && index < image.symbolCount && remaining--; index = chain[index])
            if (matches(index)) return true;
    }
    return false;
}

/** private metadata只决定BFS位置，命中必须来自持有公开祖先的原生dlsym。
 * 普通定义核对公开PHDR的实际地址；TLS核对公开模块TLS块；IFUNC/GNU unique结果
 * 保留系统选择，可落在另一映像、解析器生成的代码或为NULL；定义所在PHDR与native授权
 * 已分别核对，不能把合法IFUNC的返回实现强行限定在定义DSO内。
 * 从不调用私有resolver地址或直接返回st_value，错误namespace/隐藏版本仍由native拒绝。
 */
static bool private_result_matches(const SystemLookupImage& image, const Elf64_Sym& symbol, void* address) {
    const auto type = ELF64_ST_TYPE(symbol.st_info), bind = ELF64_ST_BIND(symbol.st_info);
    SystemLoadScope callbacks;
    if (type == STT_TLS) {
        struct Match { uintptr_t module, value; void* address; bool matched = false; } match{
            image.tlsModule, symbol.st_value, address};
        if (!match.module) return false;
        dl_iterate_phdr([](dl_phdr_info* view, size_t bytes, void* opaque) -> int {
            auto& target = *static_cast<Match*>(opaque);
            if (bytes < offsetof(dl_phdr_info, dlpi_tls_data) + sizeof(view->dlpi_tls_data) ||
                view->dlpi_tls_modid != target.module) return 0;
            target.matched = view->dlpi_tls_data &&
                reinterpret_cast<uintptr_t>(view->dlpi_tls_data) + target.value == reinterpret_cast<uintptr_t>(target.address);
            return 1;
        }, &match);
        return match.matched;
    }
    if (type == STT_GNU_IFUNC || bind == STB_GNU_UNIQUE) {
        if (!address) return true; // 合法IFUNC可返回NULL，native dlerror已经单独核过。
        Dl_info provider{};
        if (dladdr(address, &provider) != 0 && provider.dli_fbase != nullptr) return true;
        return type == STT_GNU_IFUNC && span_contains(image.mappedSpans, image.loadBias + symbol.st_value, 1);
    }
    if (symbol.st_shndx == SHN_ABS)
        return reinterpret_cast<uintptr_t>(address) == symbol.st_value;
    Dl_info provider{};
    return address && dladdr(address, &provider) != 0 &&
        reinterpret_cast<uintptr_t>(address) == image.loadBias + symbol.st_value &&
        reinterpret_cast<uintptr_t>(provider.dli_fbase) == image.loadBias;
}

/* ================================================================
 * Symbol resolution
 * ================================================================ */
/** 只查询可对外使用的动态定义；有 hash 时不退化为每次全表扫描。 */
static Elf64_Sym* exported_symbol(elf_handle_t* h, const char* name,
                                  const amcl::elfversions::Request* version = nullptr) {
    Elf64_Sym* sym = gnu_lookup(h, name, version);
    if (!sym && !h->gnuHash) sym = sysv_lookup(h, name, version);
    if (!sym && !h->gnuHash && !h->svHash) {
        // 无 hash 的已验证对象才使用线性查找；大型 libjvm 的负查询保持 bloom 快路径。
        for (size_t i = 0; i < h->dynsymCount; i++) {
            if (h->dynsym[i].st_name == 0) continue;
            if (matches_export(h, i, name, version)) {
                sym = &h->dynsym[i];
                break;
            }
        }
    }
    if (!sym) return nullptr;
    if (sym->st_shndx == SHN_UNDEF) return nullptr;
    const unsigned binding = ELF64_ST_BIND(sym->st_info);
    const unsigned visibility = ELF64_ST_VISIBILITY(sym->st_other);
    if ((binding != STB_GLOBAL && binding != STB_WEAK && binding != STB_GNU_UNIQUE) ||
        (visibility != STV_DEFAULT && visibility != STV_PROTECTED)) return nullptr;
    return sym;
}

/**
 * 地址为零的绝对符号仍是成功命中。将 found 与地址分开，避免把合法 SHN_ABS(0)
 * 误判为缺少强符号。TLS 与 IFUNC 的地址需要独立协议，不能把描述符/解析器当成结果。
 */
static void* resolve_in_lib(elf_handle_t* h, const char* name, bool* found = nullptr,
                            const amcl::elfversions::Request* version = nullptr) {
    if (found) *found = false;
    Elf64_Sym* sym = exported_symbol(h, name, version);
    if (!sym || ELF64_ST_TYPE(sym->st_info) == STT_TLS || ELF64_ST_TYPE(sym->st_info) == STT_GNU_IFUNC)
        return nullptr;
    if (found) *found = true;
    return sym->st_shndx == SHN_ABS ? reinterpret_cast<void*>(sym->st_value) : vaddr2ptr(h, sym->st_value);
}

/** 有序作用域查询与对象生命周期独立：只有仍属于同一映射身份且可见的成员才可访问。 */
enum class LookupDomain { All, Custom, System };
static void* resolve_lookup_scope(const std::vector<LookupMember>& members, const char* name, bool& found,
                                 elf_handle_t** supplier = nullptr, elf_handle_t* after = nullptr,
                                 LookupDomain domain = LookupDomain::All, elf_handle_t* bindingOwner = nullptr,
                                 const amcl::elfversions::Request* version = nullptr) {
    found = false;
    bool searching = after == nullptr;
    for (const auto& member : members) {
        if (!live_lookup_member(member)) continue;
        if (!searching) {
            if (!member.system && member.owner == after) searching = true;
            continue;
        }
        if ((domain == LookupDomain::Custom && member.system) ||
            (domain == LookupDomain::System && !member.system)) continue;
        if (!visible_to_caller(member.owner)) continue;
        if (member.system) {
            // resolver 可重入并扩展 owner 的系统引用数组；持有值快照，不能跨回调借 vector 元素。
            LookupPin owner(member.owner);
            const auto image = member.owner->systemImages[member.systemIndex];
            const Elf64_Sym* definition = nullptr;
            if (!system_image_defines(image, name, &definition, version)) continue;
            for (void* handle : image.lookupHandles) {
                bool matched = false;
                void* address = lookup_system_symbol(handle, name, matched, version);
                if (!matched || (image.privateView && !private_result_matches(image, *definition, address))) continue;
                // 无 DT_NEEDED 的另一个 custom 消费者也可能绑定 GLOBAL 系统定义；必须
                // 保留拥有该系统引用的真实 custom 节点，不能只记函数地址而让提供者提前关闭。
                // 此边在 LookupPin 结束之前形成：resolver 可能已关闭提供者最后一份公开引用。
                if (bindingOwner) retain_dependency(bindingOwner, member.owner);
                if (supplier) *supplier = member.owner;
                found = true; return address;
            }
        } else {
            void* address = resolve_in_lib(member.owner, name, &found, version);
            if (!found && !version) {
                address = resolve_legacy_manifest(member.owner, name);
                found = address != nullptr;
            }
            if (found) { if (supplier) *supplier = member.owner; return address; }
        }
    }
    return nullptr;
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
static void* g_processSymbolHandle = nullptr;

/** 在iterator仍保活映像时用原生hash的否定结果排除无关DSO，不分配或保存元数据。
 * true只表示“可能有定义”，必须继续完整描述、版本和引用校验；任何不完整/未知形状
 * 也返回true交给原校验器。false仅来自已核可读范围的GNU bloom或SysV空bucket。
 * 这避免每个AWT ABS64查询先扫描所有系统库的GNU buckets来计算完整符号数。
 */
static bool system_phdr_may_define(const dl_phdr_info& view, const char* name) {
    auto readable = [&](uintptr_t address, size_t bytes) {
        for (size_t i = 0; i < view.dlpi_phnum; ++i) {
            const auto& ph = view.dlpi_phdr[i];
            if (ph.p_type != PT_LOAD || !(ph.p_flags & PF_R) || ph.p_vaddr > UINTPTR_MAX - view.dlpi_addr) continue;
            const uintptr_t start = view.dlpi_addr + ph.p_vaddr;
            if (ph.p_memsz > UINTPTR_MAX - start) continue;
            if (address >= start && bytes <= ph.p_memsz && address - start <= ph.p_memsz - bytes) return true;
        }
        return false;
    };
    auto pointer = [&](uintptr_t raw, size_t bytes) -> uintptr_t {
        if (readable(raw, bytes)) return raw;
        if (raw <= UINTPTR_MAX - view.dlpi_addr && readable(view.dlpi_addr + raw, bytes)) return view.dlpi_addr + raw;
        return 0;
    };
    const Elf64_Dyn* dynamic = nullptr; size_t count = 0;
    for (size_t i = 0; i < view.dlpi_phnum; ++i) {
        const auto& ph = view.dlpi_phdr[i];
        if (ph.p_type != PT_DYNAMIC) continue;
        if (ph.p_vaddr > UINTPTR_MAX - view.dlpi_addr) return true;
        const uintptr_t address = view.dlpi_addr + ph.p_vaddr;
        if (!readable(address, ph.p_memsz)) return true;
        dynamic = reinterpret_cast<const Elf64_Dyn*>(address); count = ph.p_memsz / sizeof(Elf64_Dyn);
    }
    if (!dynamic) return true;
    uintptr_t gnu = 0, sysv = 0; bool terminated = false;
    for (size_t i = 0; i < count; ++i) {
        if (dynamic[i].d_tag == DT_NULL) { terminated = true; break; }
        if (dynamic[i].d_tag == DT_GNU_HASH) gnu = dynamic[i].d_un.d_ptr;
        if (dynamic[i].d_tag == DT_HASH) sysv = dynamic[i].d_un.d_ptr;
    }
    if (!terminated) return true;
    if (gnu) {
        const uintptr_t address = pointer(gnu, 4 * sizeof(uint32_t));
        if (!address) return true;
        const auto* hash = reinterpret_cast<const uint32_t*>(address);
        if (!hash[0] || !hash[2] || hash[3] >= 32) return true;
        const uint32_t value = gnu_hash(name);
        const uint64_t offset = 16 + uint64_t{(value / 64) % hash[2]} * 8;
        if (offset > UINTPTR_MAX - address || !readable(address + offset, sizeof(uint64_t))) return true;
        uint64_t word; memcpy(&word, reinterpret_cast<const void*>(address + offset), sizeof(word));
        const uint64_t mask = (uint64_t{1} << (value % 64)) | (uint64_t{1} << ((value >> hash[3]) % 64));
        return (word & mask) == mask;
    }
    if (sysv) {
        const uintptr_t address = pointer(sysv, 2 * sizeof(uint32_t));
        if (!address) return true;
        const auto* hash = reinterpret_cast<const uint32_t*>(address);
        if (!hash[0]) return true;
        const uint64_t offset = 8 + uint64_t{sysv_hash(name) % hash[0]} * 4;
        if (offset > UINTPTR_MAX - address || !readable(address + offset, sizeof(uint32_t))) return true;
        uint32_t bucket; memcpy(&bucket, reinterpret_cast<const void*>(address + offset), sizeof(bucket));
        return bucket != 0;
    }
    return true;
}

/**
 * 显式进程句柄保持全局查询次序，但不会让 glibc 的 RTLD_DEFAULT 分支把每个
 * 被查询插件永久挂到宿主上。目标 musl 对 head 句柄与 RTLD_DEFAULT 使用同一
 * caller namespace 分支；这里只缓存已存在的主对象，不执行新的库构造器。
 */
static void* resolve_system_global(const char* name, bool& found,
                                   const amcl::elfversions::Request* version = nullptr,
                                   elf_handle_t* bindingOwner = nullptr, bool* bindingRejected = nullptr) {
    if (bindingRejected) *bindingRejected = false;
    if (!g_processSymbolHandle) {
        void* handle = open_system_library(nullptr, RTLD_NOW);
        if (!g_processSymbolHandle) g_processSymbolHandle = handle;
        else if (handle) { SystemLoadScope scope; dlclose(handle); }
    }
    found = false;
    if (!g_processSymbolHandle) return nullptr;
    if (!bindingOwner) return lookup_system_symbol(g_processSymbolHandle, name, found, version);

    /** 强重定位与所属 DSO 内的 DEFAULT 查询必须拥有 native 提供者的引用。
     * 在执行 dlsym（可能运行 IFUNC）之前取得候选定义者引用；iterator 内只读公开
     * 元数据，NOLOAD/close 全在其返回后执行，且不持自定义注册锁。多个合法同名
     * 定义的保活仅到消费 DSO 关闭，不把任意查询结果永久挂在进程上。
     */
    struct NativeReferences {
        std::vector<void*> handles;
        std::vector<SystemLookupImage> images;
        ~NativeReferences() {
            SystemLoadScope callbacks;
            for (void* handle : handles) if (handle) dlclose(handle);
        }
    } references;
    struct Candidates {
        const char* name;
        const amcl::elfversions::Request* version;
        std::vector<std::string> paths;
        SystemLookupImage mainImage;
        bool mainDefines = false;
        bool failed = false;
    } candidates{name, version};
    {
        SystemLoadScope callbacks;
        dl_iterate_phdr([](dl_phdr_info* view, size_t, void* opaque) -> int {
            auto& state = *static_cast<Candidates*>(opaque);
            try {
                if (!system_phdr_may_define(*view, state.name)) return 0;
                SystemMappedImage mapped{view->dlpi_addr, view->dlpi_name ? view->dlpi_name : "",
                    std::vector<Elf64_Phdr>(view->dlpi_phdr, view->dlpi_phdr + view->dlpi_phnum)};
                SystemLookupImage image;
                if (describe_system_mapped_image(mapped, image, false, state.name) &&
                    system_image_defines(image, state.name, nullptr, state.version)) {
                    // 主可执行映像不能经 dlclose 卸载，显式进程句柄已提供其进程期根。
                    if (image.path.empty()) { state.mainImage = std::move(image); state.mainDefines = true; }
                    else state.paths.push_back(image.path);
                }
            } catch (...) { state.failed = true; return 1; }
            return 0;
        }, &candidates);
    }
    if (candidates.failed) {
        if (bindingRejected) *bindingRejected = true;
        set_error("native binding provider snapshot allocation failed"); return nullptr;
    }
    // 全部 reserve 在取得引用前完成；后续 push 不会因向量扩张遗失新取得的句柄。
    references.handles.reserve(candidates.paths.size());
    references.images.reserve(candidates.paths.size());
    for (const auto& path : candidates.paths) {
        void* handle = open_system_library(path.c_str(), RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
        if (!handle) continue; // 已卸载/不可见候选不重新装载，也不执行新的构造器。
        references.handles.push_back(handle);
        SystemLookupImage image;
        bool described = false;
        // 同一个消费DSO的强重定位会反复命中同一native提供者。已转交到owner的引用
        // 尚未关闭，因此这份已核同的只读视图不会经历卸载/地址复用；复用它避免每个
        // 符号重新遍历完整PHDR及namespace。此处注册锁已恢复，复制不与owner扩容并发。
        // 不建立进程期缓存，也不减少本次NOLOAD引用；异常仍由局部RAII归还新增引用。
        const auto owned = std::find(bindingOwner->systemDependencies.begin(),
                                     bindingOwner->systemDependencies.end(), handle);
        const bool ownerHasReference = owned != bindingOwner->systemDependencies.end();
        if (ownerHasReference) {
            const size_t index = static_cast<size_t>(owned - bindingOwner->systemDependencies.begin());
            if (index < bindingOwner->systemImages.size()) {
                image = bindingOwner->systemImages[index];
                image.dependencies.clear();
                image.lookupHandles.clear();
                described = true;
            }
        }
        if (!described && g_loadBatch) {
            // 同一个未选中的系统 C++ 候选也会被数百个 JVM 符号反复遇到。此前局部
            // snapshot 每次从头核对所有 PHDR/NOLOAD，形成十几秒启动空档；这里只在
            // 当前批次已经另持真实引用时复用视图，外部卸载不会使它变为悬空缓存。
            for (const auto& cached : g_loadBatch->nativeBindingViews) {
                if (cached->handle != handle) continue;
                image = cached->image;
                described = true;
                break;
            }
        }
        if (!described) {
            // DEFAULT/dlvsym 查询也可发生在装载批次之外。新快照在本次 NOLOAD 保活后
            // 取得，不能复用可能经历卸载/重开的旧批次 PHDR。
            SystemLoadScope callbacks;
            LoadBatch snapshot{};
            const auto* mapped = system_view_for_handle(snapshot, handle);
            described = mapped && describe_system_mapped_image(*mapped, image);
        }
        if (described && g_loadBatch && !ownerHasReference) {
            // 准备所有可抛异常的元数据后才取得额外引用。unique_ptr 负责 vector 扩容
            // 失败及普通退出的归还；本次查询的 references 仍单独拥有原引用，选中的
            // 提供者继续按既有流程转交 bindingOwner，不借用批次引用延长 DSO 生命周期。
            auto& cached = g_loadBatch->nativeBindingViews;
            const bool present = std::any_of(cached.begin(), cached.end(),
                [handle](const auto& item) { return item->handle == handle; });
            if (!present) {
                auto retained = std::make_unique<NativeBindingView>();
                retained->image = image;
                retained->handle = open_system_library(path.c_str(), RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
                // 平台若不给同一实例的稳定句柄，保留本次已核实的慢路径；不把名字或
                // 数值形状当身份，也不为缓存失败改变合法符号查询的原有结果。
                if (retained->handle == handle) cached.push_back(std::move(retained));
            }
        }
        if (!described ||
            !system_image_defines(image, name, nullptr, version)) {
            SystemLoadScope callbacks;
            dlclose(handle); references.handles.back() = nullptr;
            references.images.emplace_back();
            continue;
        }
        image.lookupHandles.push_back(handle);
        references.images.push_back(std::move(image));
    }
    void* result = lookup_system_symbol(g_processSymbolHandle, name, found, version);
    if (!found) return nullptr;
    bool qualified = false;
    if (candidates.mainDefines) {
        const Elf64_Sym* definition = nullptr;
        if (system_image_defines(candidates.mainImage, name, &definition, version))
            qualified = (result && span_contains(candidates.mainImage.mappedSpans, reinterpret_cast<uintptr_t>(result), 1)) ||
                (definition->st_shndx == SHN_ABS && reinterpret_cast<uintptr_t>(result) == definition->st_value);
    }
    for (size_t i = 0; i < references.handles.size(); ++i) {
        if (!references.handles[i]) continue;
        const auto& image = references.images[i];
        const Elf64_Sym* definition = nullptr;
        if (!system_image_defines(image, name, &definition, version)) continue;
        const unsigned type = ELF64_ST_TYPE(definition->st_info);
        // IFUNC 的实现地址可以在另一 DSO/生成代码中，原生闭包由定义者引用保活；
        // 不再次调用 resolver 来验证地址，避免把一个合法的有状态 resolver 执行两遍。
        const bool owns = type == STT_GNU_IFUNC || type == STT_TLS ||
            (definition->st_shndx == SHN_ABS && reinterpret_cast<uintptr_t>(result) == definition->st_value) ||
            (result && span_contains(image.mappedSpans, reinterpret_cast<uintptr_t>(result), 1));
        if (!owns) continue;
        qualified = true;
        if (std::find(bindingOwner->systemDependencies.begin(), bindingOwner->systemDependencies.end(),
                      references.handles[i]) != bindingOwner->systemDependencies.end()) continue;
        bindingOwner->systemDependencies.reserve(bindingOwner->systemDependencies.size() + 1);
        bindingOwner->systemImages.reserve(bindingOwner->systemImages.size() + 1);
        bindingOwner->systemImages.push_back(std::move(references.images[i]));
        bindingOwner->systemDependencies.push_back(references.handles[i]);
        references.handles[i] = nullptr; // 引用转交给原有关闭事务，析构不能重复消费。
    }
    if (!qualified) {
        found = false;
        if (bindingRejected) *bindingRejected = true;
        set_error("native GLOBAL binding lacks an owned provider: %s", name);
        return nullptr;
    }
    return result;
}

static void* resolve_from_entry(const char* name, bool& found,
                                const amcl::elfversions::Request* version = nullptr) {
    found = false;
    if (!s_entryHandle) {
        /* Open ourselves — libentry.so is already loaded, this just gets a handle */
        void* handle = open_system_library("libentry.so", RTLD_NOW | RTLD_NOLOAD);
        if (!s_entryHandle) s_entryHandle = handle;
        else if (handle) { SystemLoadScope scope; dlclose(handle); }
    }
    if (s_entryHandle) return lookup_system_symbol(s_entryHandle, name, found, version);
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
    static const char* sysLibs[] = {
        "libz.so",            /* zlib: adler32, crc32, inflate*, deflate* */
#if defined(__OHOS__)
        // 应用 __n1 域与系统 libc++.so 的 __h 域不能混作同一套 ABI。
        // libentry 已依赖应用运行库，此处取同一系统加载实例用于跨库查询。
        "libc++_shared.so",
#else
        "libstdc++.so.6",     /* 宿主回归使用其真实工具链的 C++ 域 */
#endif
        nullptr
    };
    // 解锁查询期间可能有另一线程准备同一缓存；先完整准备再一次性发布，不能把
    // g_sysLibsLoaded 提前置真或在读者解锁遍历时继续 push_back 使迭代器失效。
    std::vector<void*> staged;
    staged.reserve(2);
    try {
        for (int i = 0; sysLibs[i]; i++) {
            void* h = open_system_library(sysLibs[i], RTLD_NOW | RTLD_GLOBAL | RTLD_NOLOAD);
            if (h) staged.push_back(h);
        }
    } catch (...) {
        SystemLoadScope callbacks;
        for (void* h : staged) dlclose(h);
        throw;
    }
    if (!g_sysLibsLoaded) { g_sysLibHandles.swap(staged); g_sysLibsLoaded = true; }
    SystemLoadScope callbacks;
    for (void* duplicate : staged) dlclose(duplicate);
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
 * 只处理这一个精确路径，其余原样透传，
 * 精确路径由垫片负责一次真实打开与受限回落，其他路径直接执行真实 fopen。
 * 见 docs/adaptation/JDK_IPV6_ADAPTATION_PLAN.md §四·五 R1。
 * ---------------------------------------------------------------- */
typedef FILE* (*fopen_fn)(const char*, const char*);

static FILE* amcl_fopen(const char* path, const char* mode) {
    // 精确路径已经由垫片执行真实 fopen 并保留失败原因；不能二次打开把 ENOMEM
    // 等合成失败覆盖为权限错误。其他文件不经过合成、枚举或模式缓存。
    if (path && strcmp(path, "/proc/net/if_inet6") == 0) {
        return amclIfInet6ShimOpen(path, mode);
    }
    static fopen_fn real = (fopen_fn)dlsym(RTLD_DEFAULT, "fopen");
    if (!real) { errno = ENOSYS; return nullptr; }
    return real(path, mode);
}

static void* resolve_global(const char* name, bool* found = nullptr, elf_handle_t** supplier = nullptr,
                            const LookupScope* localScope = nullptr, elf_handle_t* bindingOwner = nullptr,
                            const amcl::elfversions::Request* version = nullptr, bool* lookupFailed = nullptr) {
    if (lookupFailed) *lookupFailed = false;
    // 平台桥接地址均非零；未命中分支最终重置 found，普通动态定义独立报告零地址成功。
    if (found) *found = true;
    if (supplier) *supplier = nullptr;
    // 平台桥仍必须满足调用方的显式 ELF 版本。未知版本不能仅凭名字拿到桥接地址，
    // 否则 dlvsym(...,"不存在的版本") 会假成功，强重定位也可能悄悄改变 ABI。
    if (version && (!strcmp(name, "dlopen") || !strcmp(name, "dlsym") || !strcmp(name, "dlvsym") ||
        !strcmp(name, "dlclose") || !strcmp(name, "dlerror") || !strcmp(name, "dladdr") ||
        !strcmp(name, "__cxa_thread_atexit") || !strcmp(name, "__cxa_thread_atexit_impl") ||
        !strcmp(name, "fopen") || (!strcmp(name, "readlink") && g_fakeExePath[0]))) {
        bool nativeFound = false, rejected = false;
        void* native = resolve_system_global(name, nativeFound, version, bindingOwner, &rejected);
        if (!nativeFound && !rejected) native = resolve_from_entry(name, nativeFound, version);
        if (!nativeFound || !native || rejected) {
            if (found) *found = false;
            if (lookupFailed) *lookupFailed = rejected;
            set_error("platform symbol version unavailable: %s@%s", name, version->name);
            return nullptr;
        }
    }
    // 系统 dlsym 不认识自加载句柄，因此整组API由宿主统一接管。NEXT的真实调用者
    // 必须在直接入口捕获，不能把本函数/libentry的位置冒充自加载库的调用位置。
    if (strcmp(name, "dlopen") == 0) return (void*)elf_dlopen;
    if (strcmp(name, "dlsym")  == 0) return (void*)elf_dlsym;
    if (strcmp(name, "dlvsym") == 0) return (void*)elf_dlvsym;
    if (strcmp(name, "dlclose") == 0) return (void*)elf_dlclose;
    if (strcmp(name, "dlerror") == 0) return (void*)elf_dlerror;
    if (strcmp(name, "dladdr") == 0) return (void*)elf_dladdr_impl;
    // 编译器生成的 C++ TLS 析构仍交给真实系统队列，只增加自加载映像所有权。
    if (strcmp(name, "__cxa_thread_atexit") == 0 || strcmp(name, "__cxa_thread_atexit_impl") == 0)
        return reinterpret_cast<void*>(hooked_cxa_thread_atexit);
    /* Intercept readlink so JLI_Launch reads our fake /proc/self/exe path
     * instead of /system/bin/appspawn, preventing unwanted re-exec */
    if (strcmp(name, "readlink") == 0 && g_fakeExePath[0]) return (void*)hooked_readlink;

    // chmod/fchmod/fchmodat 按普通系统符号解析，EPERM/EACCES 保留真实返回值与 errno。
    // ZIP 文件系统的“保留已经相同权限”属于已修复 JDK 的具体操作前提；全局 loader
    // 无法知道请求是否满足该前提，不能替所有 Java/JNI 权限请求伪造成功。

    /* Intercept fopen so the JDK can answer "does this host have IPv6?".
     * 只有 /proc/net/if_inet6 会被接管，其余路径由 amcl_fopen 原样转给真 fopen。
     * 见上方 amcl_fopen 注释与 jvm/if_inet6_shim.cpp。
     * ⚠️ 四个版本的 libnet.so 都只导入 plain fopen（已逐个核对 .dynsym）；
     *    若将来某版本改用 fopen64，这里要补一条同款。 */
    if (strcmp(name, "fopen") == 0) return (void*)amcl_fopen;

    // 保持现有跨域契约：自加载运行时的 GLOBAL 定义优先，随后才查询系统域。
    // 查询已发布的 custom 对象不能先进入系统 loader 锁：系统构造器可能正等待
    // 当前只读查询线程。LOCAL 的筛选改变可见性，不反转既有域间优先级。
    bool matched = false;
    void* p = resolve_lookup_scope(g_globalScope, name, matched, supplier, nullptr, LookupDomain::Custom, bindingOwner, version);
    if (matched) return p;
    bool systemFound = false;
    bool bindingRejected = false;
    p = resolve_system_global(name, systemFound, version, bindingOwner, &bindingRejected);
    // 已命中但不能证明提供者寿命是硬失败，不能再从另一作用域找同名地址掩盖错误。
    if (bindingRejected) {
        if (found) *found = false;
        if (lookupFailed) *lookupFailed = true;
        return nullptr;
    }
    if (systemFound) return p;

    /* 4) Symbols from libentry.so (e.g. __clear_cache) that namespace isolation hides */
    p = resolve_from_entry(name, systemFound, version);
    if (systemFound) return p;

    /* 5) Fallback: search in explicitly opened system libs (OHOS namespace workaround) */
    ensure_sys_libs();
    for (auto* sh : g_sysLibHandles) {
        p = lookup_system_symbol(sh, name, systemFound, version);
        if (systemFound) return p;
    }

    // 系统 resolver 可重入改变全局表；按本次快照遍历，不能持有可被重分配的 vector 迭代器。
    const auto systemScope = g_globalScope;
    p = resolve_lookup_scope(systemScope, name, matched, supplier, nullptr, LookupDomain::System, bindingOwner, version);
    if (matched) return p;
    if (localScope) {
        p = resolve_lookup_scope(localScope->members, name, matched, supplier, nullptr, LookupDomain::All, bindingOwner, version);
        if (matched) return p;
    }
    if (found) *found = false;

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
 * 从同一已打开文件取得 EH 精确范围。程序头给出运行时索引；节表存在时读取 .eh_frame
 * 的真实边界，避免把后续 rodata 当成无限长 DWARF。兼容 ELF 扩展节计数/名称索引。
 * 节表只用于界限，不导出其中的 LOCAL 符号；所有范围还要与真正 PT_LOAD 对账。
 */
static bool locate_unwind_sections(elf_handle_t* h, uint64_t fileBytes) {
    auto reject = [&](const char* why) { set_error("%s: invalid EH layout: %s", h->name.c_str(), why); return false; };
    auto inFile = [&](uint64_t offset, uint64_t bytes) { return offset <= fileBytes && bytes <= fileBytes - offset; };
    for (size_t i = 0; i < h->ehdr.e_phnum; ++i) {
        const auto& ph = h->phdr[i];
        if (ph.p_type != PT_GNU_EH_FRAME) continue;
        if (h->ehHeaderSize || ph.p_filesz != ph.p_memsz || !ph.p_filesz || !inFile(ph.p_offset, ph.p_filesz))
            return reject("duplicate or truncated GNU EH header");
        h->ehHeaderAddress = ph.p_vaddr;
        h->ehHeaderSize = ph.p_filesz;
    }
    if (!h->ehdr.e_shoff) return true; // 完全去节表的对象稍后按有界 EH header/终止项定位。
    if (h->ehdr.e_shentsize != sizeof(Elf64_Shdr) || !inFile(h->ehdr.e_shoff, sizeof(Elf64_Shdr)))
        return reject("section header extent");
    Elf64_Shdr first{};
    if (!read_exact(h, &first, sizeof(first), h->ehdr.e_shoff, "section zero")) return false;
    const uint64_t count = h->ehdr.e_shnum ? h->ehdr.e_shnum : first.sh_size;
    if (!count || count > SIZE_MAX / sizeof(Elf64_Shdr) || !inFile(h->ehdr.e_shoff, count * sizeof(Elf64_Shdr)))
        return reject("section count");
    std::vector<Elf64_Shdr> sections(static_cast<size_t>(count));
    if (!read_exact(h, sections.data(), sections.size() * sizeof(Elf64_Shdr), h->ehdr.e_shoff, "section headers")) return false;
    const uint64_t namesIndex = h->ehdr.e_shstrndx == SHN_XINDEX ? first.sh_link : h->ehdr.e_shstrndx;
    if (namesIndex == SHN_UNDEF) return true; // ELF 允许没有节名表，继续用程序头。
    if (namesIndex >= count) return reject("section name index");
    const auto& names = sections[namesIndex];
    if (names.sh_type != SHT_STRTAB || !names.sh_size || names.sh_size > SIZE_MAX || !inFile(names.sh_offset, names.sh_size))
        return reject("section name table");
    std::vector<char> strings(static_cast<size_t>(names.sh_size));
    if (!read_exact(h, strings.data(), strings.size(), names.sh_offset, "section names")) return false;
    if (strings.front() || strings.back()) return reject("unterminated section names");
    for (const auto& section : sections) {
        if (section.sh_name >= strings.size()) return reject("section name offset");
        if (std::strcmp(strings.data() + section.sh_name, ".eh_frame") != 0) continue;
        if (!section.sh_size) continue;
        if (h->ehFrameSize || section.sh_type != SHT_PROGBITS || !(section.sh_flags & SHF_ALLOC) ||
            section.sh_size > SIZE_MAX || !inFile(section.sh_offset, section.sh_size)) return reject("EH section extent/type");
        bool matches = false;
        for (size_t i = 0; i < h->ehdr.e_phnum; ++i) {
            const auto& load = h->phdr[i];
            if (load.p_type != PT_LOAD || !(load.p_flags & PF_R) || section.sh_addr < load.p_vaddr) continue;
            const auto delta = section.sh_addr - load.p_vaddr;
            if (delta <= load.p_filesz && section.sh_size <= load.p_filesz - delta &&
                delta <= UINT64_MAX - load.p_offset && load.p_offset + delta == section.sh_offset) matches = true;
        }
        if (!matches) return reject("EH section does not match readable file-backed LOAD");
        h->ehFrameAddress = section.sh_addr;
        h->ehFrameSize = section.sh_size;
    }
    return true;
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
    return locate_unwind_sections(h, fileBytes);
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

    // 一次建立清零的可写映射，再按真实段字节复制。两个 PT_LOAD 共用物理页时，
    // 逐段 MAP_FIXED 会把前一段已经复制的页内容清掉；页权限在完整重定位后统一收紧。
    // 构造器之前不会向其他线程发布本批对象，空洞最终恢复为 PROT_NONE。
    h->base = mmap(NULL, h->mapSize, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
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
        // 读取范围在映射前已验证；系统调用仍可短读或被信号打断，由共享循环处理。
        if (p->p_filesz > 0 && !read_exact(h, (char*)h->base + segOff,
                static_cast<size_t>(p->p_filesz), p->p_offset, "PT_LOAD")) {
            return false;
        }
        // 显式初始化本段 BSS，保持实际重叠地址按程序头顺序处理的语义，
        // 同时不触碰同页内属于其他段、但不在本段内存范围中的字节。
        if (p->p_memsz > p->p_filesz)
            memset(static_cast<char*>(h->base) + segOff + p->p_filesz, 0, p->p_memsz - p->p_filesz);
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

    // 精准历史例外必须核对本次映射使用的同一 fd，不能重新打开可能已被替换的路径。
    verify_legacy_jli_identity(h);
    close(h->fd);
    h->fd = -1;

    /* 这里只定位模板，尚未重定位，不能现在复制给任何线程。 */
    if (h->hasTls) {
        /* Find PT_TLS vaddr to locate init image in mapped memory */
        for (int i = 0; i < h->ehdr.e_phnum; i++) {
            if (h->phdr[i].p_type == PT_TLS && h->tlsFileSize) {
                h->tlsInitImage = vaddr2ptr(h, h->phdr[i].p_vaddr);
                break;
            }
        }
    }

    return true;
}

/** 合并已核对的加载区间；查询按二分完成，不随符号数重复扫描全部程序头。 */
static void merge_spans(std::vector<ElfMemorySpan>& spans) {
    std::sort(spans.begin(), spans.end(),
        [](const ElfMemorySpan& a, const ElfMemorySpan& b) { return a.begin < b.begin; });
    size_t kept = 0;
    for (const auto span : spans) {
        if (kept && span.begin <= spans[kept - 1].end)
            spans[kept - 1].end = std::max(spans[kept - 1].end, span.end);
        else spans[kept++] = span;
    }
    spans.resize(kept);
}

/** 返回连续有效区间的剩余字节；边界处的零长度对象允许取 one-past 地址。 */
static bool span_contains(const std::vector<ElfMemorySpan>& spans, Elf64_Addr address, size_t bytes) {
    auto it = std::upper_bound(spans.begin(), spans.end(), address,
        [](Elf64_Addr value, const ElfMemorySpan& span) { return value < span.begin; });
    if (it == spans.begin()) return false;
    --it;
    return address <= it->end && bytes <= it->end - address;
}
static size_t span_remaining(const std::vector<ElfMemorySpan>& spans, Elf64_Addr address) {
    auto it = std::upper_bound(spans.begin(), spans.end(), address,
        [](Elf64_Addr value, const ElfMemorySpan& span) { return value < span.begin; });
    if (it == spans.begin()) return 0;
    --it;
    return address < it->end ? static_cast<size_t>(it->end - address) : 0;
}

/**
 * 完整检查即将解释的动态表、hash、symbol、string、relocation 和 init/fini 数组边界。
 * 动态解释表复制到自身存储，重定位写入映射不会使后续索引变成攻击者控制的新值。
 * 失败只改变本批未发布对象，由原批次回滚负责回收；不执行任何构造器。
 */
static bool parse_dynamic(elf_handle_t* h) try {
    const Elf64_Phdr* dynamic = nullptr;
    for (size_t i = 0; i < h->ehdr.e_phnum; ++i) {
        const auto& p = h->phdr[i];
        if (p.p_type == PT_DYNAMIC) dynamic = &p;
        if (p.p_type != PT_LOAD) continue;
        if (p.p_filesz) h->fileSpans.push_back({p.p_vaddr, p.p_vaddr + p.p_filesz});
        if (p.p_filesz && (p.p_flags & PF_R)) h->readableFileSpans.push_back({p.p_vaddr, p.p_vaddr + p.p_filesz});
        if (p.p_memsz) h->memorySpans.push_back({p.p_vaddr, p.p_vaddr + p.p_memsz});
        if (p.p_memsz && (p.p_flags & PF_X)) h->executableSpans.push_back({p.p_vaddr, p.p_vaddr + p.p_memsz});
    }
    merge_spans(h->fileSpans); merge_spans(h->memorySpans); merge_spans(h->executableSpans);
    merge_spans(h->readableFileSpans);
    auto reject = [&](const char* detail) {
        set_error("%s: invalid dynamic metadata: %s", h->name.c_str(), detail);
        return false;
    };
    if (!dynamic || !span_contains(h->fileSpans, dynamic->p_vaddr, dynamic->p_filesz))
        return reject("dynamic table outside file-backed LOAD");
    h->dynamicStorage.resize(dynamic->p_filesz / sizeof(Elf64_Dyn));
    memcpy(h->dynamicStorage.data(), vaddr2ptr(h, dynamic->p_vaddr), dynamic->p_filesz);
    h->dyn = h->dynamicStorage.data();
    std::unordered_map<Elf64_Sxword, Elf64_Xword> tags;
    std::vector<size_t> needed;
    for (const auto& item : h->dynamicStorage) {
        if (item.d_tag == DT_NULL) break; // 外层已验证终止项位于本数组内。
        if (item.d_tag == DT_NEEDED) { needed.push_back(item.d_un.d_val); continue; }
        switch (item.d_tag) {
        case DT_SYMTAB: case DT_SYMENT: case DT_STRTAB: case DT_STRSZ:
        case DT_VERSYM: case DT_VERDEF: case DT_VERDEFNUM: case DT_VERNEED: case DT_VERNEEDNUM:
        case DT_HASH: case DT_GNU_HASH: case DT_RELA: case DT_RELASZ: case DT_RELAENT:
        case DT_JMPREL: case DT_PLTRELSZ: case DT_PLTREL:
        case DT_INIT: case DT_INIT_ARRAY: case DT_INIT_ARRAYSZ:
        case DT_FINI: case DT_FINI_ARRAY: case DT_FINI_ARRAYSZ: {
            const auto added = tags.emplace(item.d_tag, item.d_un.d_val);
            if (!added.second && added.first->second != item.d_un.d_val)
                return reject("conflicting singleton dynamic tag");
            break;
        }
        case DT_SYMBOLIC: h->symbolic = true; break;
        case DT_FLAGS: h->symbolic = (item.d_un.d_val & DF_SYMBOLIC) != 0 || h->symbolic; break;
        case DT_FLAGS_1:
            // 与显式 NODELETE 共用同一个生命周期根。DF_1_GLOBAL 不等于 dlopen GLOBAL：
            // 真实 glibc 对照在 RTLD_LOCAL 下不因此发布到全局，保持这一装载作用域语义。
            h->nodelete = h->nodelete || (item.d_un.d_val & DF_1_NODELETE);
            break;
        case DT_REL: case DT_RELSZ:
            if (item.d_un.d_val) return reject("unsupported REL relocation table");
            break;
        // AArch64 当前支持的发行协议为 RELA。不能默默跳过另一种动态重定位编码。
        case 35: case 36: case 37:
            if (item.d_un.d_val) return reject("unsupported RELR relocation table");
            break;
        default: break;
        }
    }
    auto value = [&](Elf64_Sxword tag, Elf64_Xword fallback = 0) -> Elf64_Xword {
        const auto found = tags.find(tag);
        return found == tags.end() ? fallback : found->second;
    };
    if (!tags.count(DT_SYMTAB) || !tags.count(DT_STRTAB) || !value(DT_STRSZ) ||
        value(DT_SYMENT, sizeof(Elf64_Sym)) != sizeof(Elf64_Sym))
        return reject("missing symbol/string table or invalid symbol stride");
    const Elf64_Addr symbolAddress = value(DT_SYMTAB);
    const size_t symbolLimit = span_remaining(h->fileSpans, symbolAddress) / sizeof(Elf64_Sym);
    if (!symbolLimit) return reject("symbol table outside file-backed LOAD");
    h->dynstrSize = value(DT_STRSZ);
    if (!span_contains(h->fileSpans, value(DT_STRTAB), h->dynstrSize))
        return reject("string table outside file-backed LOAD");
    h->stringStorage.resize(h->dynstrSize);
    memcpy(h->stringStorage.data(), vaddr2ptr(h, value(DT_STRTAB)), h->dynstrSize);
    h->dynstr = h->stringStorage.data();
    // ELF string table 首尾都是 NUL；索引在范围内即保证后续 strcmp 会有界终止。
    if (h->dynstr[0] || h->dynstr[h->dynstrSize - 1]) return reject("unterminated ELF string table");
    for (size_t offset : needed)
        if (offset >= h->dynstrSize || !h->dynstr[offset]) return reject("invalid NEEDED string index");

    size_t symbolCount = 0;
    if (tags.count(DT_HASH)) {
        const Elf64_Addr address = value(DT_HASH);
        if (!span_contains(h->fileSpans, address, 8)) return reject("truncated SysV hash header");
        uint32_t header[2]; memcpy(header, vaddr2ptr(h, address), sizeof(header));
        const uint64_t words = 2ULL + header[0] + header[1];
        if (!header[0] || !header[1] || header[1] > symbolLimit ||
            words > SIZE_MAX / sizeof(uint32_t) ||
            !span_contains(h->fileSpans, address, static_cast<size_t>(words * sizeof(uint32_t))))
            return reject("invalid SysV bucket/chain bounds");
        h->sysvStorage.resize(static_cast<size_t>(words));
        memcpy(h->sysvStorage.data(), vaddr2ptr(h, address), words * sizeof(uint32_t));
        h->svHash = h->sysvStorage.data();
        symbolCount = header[1];
        const uint32_t* buckets = h->svHash + 2;
        const uint32_t* chain = buckets + header[0];
        for (size_t i = 0; i < header[0]; ++i)
            if (buckets[i] >= symbolCount) return reject("SysV bucket symbol index");
        for (size_t i = 0; i < symbolCount; ++i)
            if (chain[i] >= symbolCount) return reject("SysV chain symbol index");
        // 每个链节点最多处理两次，检测环而不退化为每个 bucket 重扫整条链。
        std::vector<unsigned char> state(symbolCount, 0);
        state[0] = 2;
        for (uint32_t start = 1; start < symbolCount; ++start) {
            uint32_t cursor = start;
            while (state[cursor] == 0) { state[cursor] = 1; cursor = chain[cursor]; }
            if (state[cursor] == 1) return reject("cyclic SysV hash chain");
            cursor = start;
            while (state[cursor] == 1) { state[cursor] = 2; cursor = chain[cursor]; }
        }
    }
    if (tags.count(DT_GNU_HASH)) {
        const Elf64_Addr address = value(DT_GNU_HASH);
        if (!span_contains(h->fileSpans, address, 16)) return reject("truncated GNU hash header");
        uint32_t header[4]; memcpy(header, vaddr2ptr(h, address), sizeof(header));
        const size_t gnuSymbolLimit = symbolCount ? symbolCount : symbolLimit;
        const uint64_t prefix = 16ULL + 8ULL * header[2] + 4ULL * header[0];
        if (!header[0] || !header[1] || !header[2] || header[3] >= 32 ||
            header[1] > gnuSymbolLimit || prefix > SIZE_MAX ||
            !span_contains(h->fileSpans, address, static_cast<size_t>(prefix)))
            return reject("invalid GNU hash buckets/bloom/shift");
        // 先读 bucket 最大起点，仅从该起点寻末尾。更早的 bucket 也必在这一终止位前结束，
        // 避免恶意重复 bucket 使验证重复扫描同一条链。
        const char* raw = static_cast<const char*>(vaddr2ptr(h, address));
        uint32_t highest = 0;
        for (size_t i = 0; i < header[0]; ++i) {
            uint32_t bucket;
            memcpy(&bucket, raw + 16 + 8ULL * header[2] + 4 * i, sizeof(bucket));
            if (bucket && (bucket < header[1] || bucket >= gnuSymbolLimit))
                return reject("GNU bucket symbol index");
            highest = std::max(highest, bucket);
        }
        size_t gnuCount = header[1];
        if (highest) {
            const size_t chains = span_remaining(h->fileSpans, address + prefix) / sizeof(uint32_t);
            uint64_t cursor = highest;
            for (;;) {
                if (cursor >= gnuSymbolLimit || cursor - header[1] >= chains)
                    return reject("unterminated GNU hash chain");
                uint32_t hash;
                memcpy(&hash, raw + prefix + 4 * (cursor - header[1]), sizeof(hash));
                ++cursor;
                if (hash & 1) { gnuCount = static_cast<size_t>(cursor); break; }
            }
        }
        if (symbolCount && gnuCount > symbolCount) return reject("GNU hash exceeds SysV symbol count");
        if (!symbolCount) symbolCount = gnuCount;
        const uint64_t bytes = prefix + (gnuCount - header[1]) * sizeof(uint32_t);
        if (!span_contains(h->fileSpans, address, static_cast<size_t>(bytes)))
            return reject("GNU hash outside file-backed LOAD");
        h->gnuStorage.resize((bytes + 7) / 8); // 显式保证 bloom 的 64 位对齐。
        memcpy(h->gnuStorage.data(), raw, bytes);
        h->gnuHash = reinterpret_cast<const uint32_t*>(h->gnuStorage.data());
    }
    if (!symbolCount || symbolCount > symbolLimit) return reject("missing usable symbol count");
    h->symbolStorage.resize(symbolCount);
    memcpy(h->symbolStorage.data(), vaddr2ptr(h, symbolAddress), symbolCount * sizeof(Elf64_Sym));
    h->dynsym = h->symbolStorage.data(); h->dynsymCount = symbolCount;
    for (const auto& symbol : h->symbolStorage) {
        if (symbol.st_name >= h->dynstrSize) return reject("symbol name outside string table");
        if (symbol.st_shndx == SHN_UNDEF || symbol.st_shndx == SHN_ABS) continue;
        if (symbol.st_shndx == SHN_COMMON) return reject("unsupported dynamic COMMON symbol");
        if (ELF64_ST_TYPE(symbol.st_info) == STT_TLS) {
            if (!h->hasTls || symbol.st_value > h->tlsSize || symbol.st_size > h->tlsSize - symbol.st_value)
                return reject("TLS symbol outside TLS image");
        } else if (!span_contains(h->memorySpans, symbol.st_value, symbol.st_size))
            return reject("defined symbol outside LOAD");
    }
    const char* versionError = nullptr;
    if (!amcl::elfversions::parse(h->symbolVersions, tags, h->symbolStorage.data(), h->symbolStorage.size(), h->dynstr, h->dynstrSize,
        [&](uint64_t address, size_t bytes) -> const void* {
            return span_contains(h->fileSpans, address, bytes) ? vaddr2ptr(h, address) : nullptr;
        }, versionError)) return reject(versionError);
    auto copyRelocations = [&](Elf64_Sxword addressTag, Elf64_Sxword sizeTag,
                               std::vector<Elf64_Rela>& output) -> bool {
        const size_t bytes = value(sizeTag);
        if (!bytes) return true;
        if (!tags.count(addressTag) || bytes % sizeof(Elf64_Rela) ||
            !span_contains(h->fileSpans, value(addressTag), bytes)) return false;
        output.resize(bytes / sizeof(Elf64_Rela));
        memcpy(output.data(), vaddr2ptr(h, value(addressTag)), bytes);
        for (const auto& item : output) {
            const uint32_t type = ELF64_R_TYPE(item.r_info);
            if (type == R_AARCH64_NONE) continue;
            const size_t width = type == R_AARCH64_TLSDESC ? 16 : 8;
            if (!span_contains(h->memorySpans, item.r_offset, width) ||
                ELF64_R_SYM(item.r_info) >= symbolCount) return false;
            if (type == R_AARCH64_RELATIVE && ELF64_R_SYM(item.r_info) != 0) return false;
            if (type == R_AARCH64_TLSDESC && (item.r_addend < 0 ||
                static_cast<uint64_t>(item.r_addend) > h->tlsSize || !h->hasTls ||
                item.r_offset % alignof(tlsdesc_pair))) return false;
        }
        return true;
    };
    if (value(DT_RELAENT, sizeof(Elf64_Rela)) != sizeof(Elf64_Rela) ||
        (value(DT_PLTRELSZ) && value(DT_PLTREL) != DT_RELA) ||
        !copyRelocations(DT_RELA, DT_RELASZ, h->relocations) ||
        !copyRelocations(DT_JMPREL, DT_PLTRELSZ, h->pltRelocations))
        return reject("relocation stride, table, symbol or target bounds");
    auto array = [&](Elf64_Sxword addressTag, Elf64_Sxword sizeTag, Elf64_Addr*& pointer, size_t& count) {
        const size_t bytes = value(sizeTag);
        if (!bytes) return true;
        if (!tags.count(addressTag) || bytes % sizeof(Elf64_Addr) ||
            !span_contains(h->memorySpans, value(addressTag), bytes)) return false;
        if (value(addressTag) % alignof(Elf64_Addr)) return false;
        pointer = static_cast<Elf64_Addr*>(vaddr2ptr(h, value(addressTag)));
        count = bytes / sizeof(Elf64_Addr);
        return true;
    };
    h->hasInitFunc = tags.count(DT_INIT) != 0; h->initFunc = value(DT_INIT);
    h->hasFiniFunc = tags.count(DT_FINI) != 0; h->finiFunc = value(DT_FINI);
    if ((h->hasInitFunc && !span_contains(h->executableSpans, h->initFunc, 4)) ||
        (h->hasFiniFunc && !span_contains(h->executableSpans, h->finiFunc, 4)) ||
        !array(DT_INIT_ARRAY, DT_INIT_ARRAYSZ, h->initArray, h->initArraySz) ||
        !array(DT_FINI_ARRAY, DT_FINI_ARRAYSZ, h->finiArray, h->finiArraySz))
        return reject("init/fini range or alignment");
    return true;
} catch (const std::bad_alloc&) {
    set_error("%s: dynamic metadata allocation failed", h->name.c_str());
    return false;
}


/**
 * 装载 DT_NEEDED：必需依赖失败立即终止本批，不能留下可调用的未链接对象。
 * 已登记对象用于同线程依赖环；其他线程仍在初始化的对象明确返回暂不可用。
 */
static bool load_deps(elf_handle_t* h) {
    if (!h->dyn || !h->dynstr) return true;
    const size_t neededCount = std::count_if(h->dynamicStorage.begin(), h->dynamicStorage.end(),
        [](const Elf64_Dyn& item) { return item.d_tag == DT_NEEDED; });
    // 在取得系统引用前完成容量准备；成功 dlopen 后的 push 不再因分配失败丢失句柄。
    h->systemDependencies.reserve(neededCount);
    h->dependencies.reserve(neededCount);
    h->neededDependencies.reserve(neededCount);
    for (Elf64_Dyn* d = h->dyn; d->d_tag != DT_NULL; d++) {
        if (d->d_tag != DT_NEEDED) continue;
        const char* name = h->dynstr + d->d_un.d_val;
#if defined(__OHOS__)
        if (strcmp(name, "libc++_shared.so") == 0) {
            // 完整 ZIP 内携带 provider 供独立 CLI 使用；嵌入时必须复用 HAP 已加载
            // 的应用运行库，不能把 ZIP 中副本再次 mmap 成另一套 guard/EH/TLS 状态。
            // NOLOAD 不执行未知构造器，也不在当前加载事务中引入另一套 ABI。
            if (void* system = open_system_library(name, RTLD_NOW | RTLD_GLOBAL | RTLD_NOLOAD)) {
                h->systemDependencies.push_back(system);
                h->neededDependencies.push_back({nullptr, h->systemDependencies.size() - 1}); continue;
            }
            set_error("%s: application C++ ABI provider is not loaded", h->name.c_str());
            return false;
        }
#endif
        auto existing = g_byName.find(name);
        if (existing != g_byName.end()) {
            if (visible_to_caller(existing->second)) {
                retain_dependency(h, existing->second);
                h->neededDependencies.push_back({existing->second, 0}); continue;
            }
            set_error("%s: dependency %s is initializing on another thread", h->name.c_str(), name);
            return false;
        }
        const std::string resolved = resolve_path(name);
        if (!resolved.empty()) {
            if (auto* dependency = prepare_elf(resolved.c_str())) {
                retain_dependency(h, dependency); h->neededDependencies.push_back({dependency, 0}); continue;
            }
            // 已选中的自定义库失败不能偷偷换成系统同名库，也不覆盖其首个详细错误。
            return false;
        }
        void* system = open_system_library(name, RTLD_NOW | RTLD_LOCAL);
        if (!system) {
            const char* detail = dlerror();
            set_error("%s: required dependency %s: %s", h->name.c_str(), name, detail ? detail : "unavailable");
            return false;
        }
        h->systemDependencies.push_back(system);
        h->neededDependencies.push_back({nullptr, h->systemDependencies.size() - 1});
    }
    return true;
}

/** 上游 link_type.c 在动态构建中返回 JNI_FALSE；这里只为一个已出货的缺导出对象补足同一语义。 */
static unsigned char legacy_dynamic_jli() { return 0; }

/**
 * 只识别已出货三份 libjli 原件；其 JLI_ManifestIterate 被旧重链本地化。
 * 大小仅作廉价预筛，完整 SHA-256 命中才使用已核对的函数地址与 252 字节范围。
 * 身份读取使用映射同一 fd；新候选正常动态导出，不进入此兼容分支。
 */
static void verify_legacy_jli_identity(elf_handle_t* h) {
    if (h->legacyJliChecked) return;
    h->legacyJliChecked = true;
    if (h->name != "libjli.so" || h->fd < 0) return;
    struct LegacyJli { off_t bytes; const char* sha; Elf64_Addr manifest; bool needsLinkType; };
    static constexpr LegacyJli known[] = {
        {66080, "5bf38dca8d8f7e31e19d38b639f5b35d86d0dbc0118bdabaf4b5175b5a3350d1", 110616, false},
        {71240, "5c4cc1626ffef81278b242bf1fae467e48f12d4871f1e1d71afd144ca6c87666", 112220, false},
        {71984, "744b629a2b66c3b3b4aa7e1f639f54824531a1f7a87f54b062ab8caec8f0715b", 112444, true}
    };
    struct stat st{};
    if (fstat(h->fd, &st) != 0) return;
    const LegacyJli* candidate = nullptr;
    for (const auto& entry : known) if (st.st_size == entry.bytes) candidate = &entry;
    if (!candidate) return;
    download::Sha256 hash;
    unsigned char buffer[8192];
    off_t offset = 0;
    while (offset < st.st_size) {
        const ssize_t count = pread(h->fd, buffer, std::min<off_t>(sizeof(buffer), st.st_size - offset), offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return;
        hash.update(buffer, static_cast<size_t>(count));
        offset += count;
    }
    if (hash.finalizeHex() != candidate->sha) return;
    h->legacyManifestAddress = candidate->manifest;
    h->legacyJliAllowed = candidate->needsLinkType;
}

/** 不读取节表，也不将同文件内其他 LOCAL/HIDDEN 符号暴露给别的对象。 */
static void* resolve_legacy_manifest(elf_handle_t* h, const char* name) {
    if (strcmp(name, "JLI_ManifestIterate") != 0 || !h->legacyManifestAddress ||
        !span_contains(h->executableSpans, h->legacyManifestAddress, 252)) return nullptr;
    return vaddr2ptr(h, h->legacyManifestAddress);
}

/** 25 旧原件另缺少 link_type.o；保持已有精确动态构建返回值，不为其他输入伪造该导出。 */
static void* resolve_legacy_jli(elf_handle_t* h, const char* name) {
    if (strcmp(name, "JLI_IsStaticallyLinked") != 0) return nullptr;
    verify_legacy_jli_identity(h);
    return h->legacyJliAllowed ? reinterpret_cast<void*>(legacy_dynamic_jli) : nullptr;
}

/* Process relocations */
static bool apply_relocs(elf_handle_t* h) {
    int undefCount = 0;
    int totalCount = 0;
    int relativeCount = 0, globdatCount = 0, jmpslotCount = 0;
    int abs64Count = 0, tlsdescCount = 0, irelativeCount = 0, otherCount = 0;
    auto doRela = [&](Elf64_Rela* r, size_t count) -> bool {
        for (size_t i = 0; i < count; i++) {
            totalCount++;
            uint32_t type = ELF64_R_TYPE(r[i].r_info);
            uint32_t si   = ELF64_R_SYM(r[i].r_info);
            void* slot = vaddr2ptr(h, r[i].r_offset);
            int64_t  addend = r[i].r_addend;
            // ABS64 可以指向 packed 对象中的非对齐字段；按字节写避免 C++ 对齐 UB。
            auto storeAddress = [slot](uint64_t address) { memcpy(slot, &address, sizeof(address)); };

            switch (type) {
            case R_AARCH64_NONE:
                break;

            case R_AARCH64_RELATIVE: {
                relativeCount++;
                void* val = reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(h->base) +
                    static_cast<uint64_t>(addend) - h->loadBias);
                /* Check for suspicious values that might cause crashes */
                if ((uintptr_t)val == 0xFFFFFFFF || (uintptr_t)val == 0xFFFFFFFFFFFFFFFF) {
                    AMCL_LOG_E(LOG_TAG, "RELATIVE reloc #%{public}d: slot=%{public}p val=%{public}p addend=0x%{public}lx bias=0x%{public}lx",
                                 totalCount, (void*)slot, val, (unsigned long)addend, (unsigned long)h->loadBias);
                }
                storeAddress(reinterpret_cast<uintptr_t>(val));
                break;
            }

            case R_AARCH64_IRELATIVE: {
                // 现役 JDK 没有此模型；不能在全批强引用尚未验证时执行任意 resolver。
                // 后续支持须单独实现 resolver 顺序/生命周期，当前准确拒绝而非提前执行。
                set_error("%s: unsupported executable IRELATIVE relocation", h->name.c_str());
                return false;
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
                    // 符号 0 是 S=0；只有 RELATIVE 才采用 B+A，不能混用两种公式。
                    storeAddress(static_cast<uint64_t>(addend));
                    break;
                }
                Elf64_Sym* sym = &h->dynsym[si];
                const char* sn = h->dynstr + sym->st_name;

                void* sa = nullptr;
                const bool defined = sym->st_shndx != SHN_UNDEF;
                const unsigned visibility = ELF64_ST_VISIBILITY(sym->st_other);
                const bool bindLocally = defined && (h->symbolic ||
                    ELF64_ST_BIND(sym->st_info) == STB_LOCAL || visibility != STV_DEFAULT);
                bool resolved = false;
                // 默认可见定义允许早先全局定义抢占；PROTECTED/HIDDEN/LOCAL 和 SYMBOLIC
                // 保持自身定义。既有代码总是选择自身，破坏跨 DSO 对象与函数的地址一致性。
                elf_handle_t* supplier = nullptr;
                const auto requested = h->symbolVersions.required(si, defined);
                const auto* version = requested.name ? &requested : nullptr;
                bool lookupFailed = false;
                if (!bindLocally) sa = resolve_global(sn, &resolved, &supplier, h->originScope.get(), h, version, &lookupFailed);
                if (lookupFailed) return false; // 资源/所有权失败不能变为 weak 零地址或本库兜底。
                if (resolved) retain_dependency(h, supplier);
                if (!resolved && defined) {
                    if (ELF64_ST_TYPE(sym->st_info) == STT_GNU_IFUNC || ELF64_ST_TYPE(sym->st_info) == STT_TLS) {
                        set_error("%s: unsupported indirect ordinary symbol %s", h->name.c_str(), sn);
                        return false;
                    }
                    sa = sym->st_shndx == SHN_ABS ? reinterpret_cast<void*>(sym->st_value) : vaddr2ptr(h, sym->st_value);
                    resolved = true;
                }

                if (!resolved && !version) { sa = resolve_legacy_jli(h, sn); resolved = sa != nullptr; }
                if (!resolved && ELF64_ST_BIND(sym->st_info) != STB_WEAK) {
                    set_error("%s: unresolved required symbol %s (relocation %u)", h->name.c_str(), sn, type);
                    return false;
                }
                storeAddress(reinterpret_cast<uintptr_t>(sa) + static_cast<uint64_t>(addend));
                break;
            }

            case R_AARCH64_COPY:
                // 共享库装载器没有可验证的 executable COPY 所有权，不能伪造复制成功。
                set_error("%s: unsupported COPY relocation", h->name.c_str());
                return false;

            case R_AARCH64_TLSDESC: {
                tlsdescCount++;
                if (si != 0) {
                    set_error("%s: unsupported external-symbol TLSDESC", h->name.c_str());
                    return false;
                }
                /* TLSDESC: slot points to a 2-word descriptor {resolver, arg}.
                 * We fill it with our custom resolver + TLS offset. */
                tlsdesc_pair* desc = (tlsdesc_pair*)slot;
                fill_tlsdesc(h, desc, (uint64_t)addend);
                break;
            }

            case R_AARCH64_TLS_TPREL64:
            case R_AARCH64_TLS_DTPMOD64:
            case R_AARCH64_TLS_DTPREL64:
                // 现役受检 JDK 仅使用本库 TLSDESC；其他 TLS 模型须先建立独立 ABI 验收。
                set_error("%s: unsupported TLS relocation %u", h->name.c_str(), type);
                return false;

            default:
                otherCount++;
                set_error("%s: unsupported relocation %u", h->name.c_str(), type);
                return false;
            }
        }
        return true;
    };

    if (!doRela(h->relocations.data(), h->relocations.size()) ||
        !doRela(h->pltRelocations.data(), h->pltRelocations.size())) return false;
    // 后续查询只需 symbol/hash/string；立即释放重定位快照以恢复稳定内存占用。
    std::vector<Elf64_Rela>().swap(h->relocations);
    std::vector<Elf64_Rela>().swap(h->pltRelocations);
    OH_LOG_INFO(LOG_APP, "%{public}s: relocs done: total=%{public}d RELATIVE=%{public}d GLOB_DAT=%{public}d JUMP_SLOT=%{public}d ABS64=%{public}d TLSDESC=%{public}d IRELATIVE=%{public}d other=%{public}d undef=%{public}d",
                h->name.c_str(), totalCount, relativeCount, globdatCount, jmpslotCount,
                abs64Count, tlsdescCount, irelativeCount, otherCount, undefCount);
    return true;
}

/**
 * 以程序头边界扫描最终页权限，共页采用所需权限并集，再从 RELRO 的完整页移除写位。
 * 事件数量与程序头数量相关，不为稀疏大地址空间分配一份逐页数组。
 * 任一 mprotect/分配失败都拒绝本批装载；不能运行尚未具备正确权限的构造器。
 */
static bool protect_segments(elf_handle_t* h) {
    struct Boundary { size_t offset; int read, write, execute, relro; };
    std::vector<Boundary> boundaries;
    try {
        boundaries.reserve(static_cast<size_t>(h->ehdr.e_phnum) * 2 + 4);
        boundaries.push_back({0, 0, 0, 0, 0});
        boundaries.push_back({h->mapSize, 0, 0, 0, 0});
        for (int i = 0; i < h->ehdr.e_phnum; ++i) {
            const Elf64_Phdr& p = h->phdr[i];
            if (p.p_type != PT_LOAD || !p.p_memsz) continue;
            const size_t start = PAGE_TRUNC(p.p_vaddr - h->loadBias);
            const size_t end = PAGE_ALIGN(p.p_vaddr - h->loadBias + p.p_memsz);
            const int r = (p.p_flags & PF_R) != 0, w = (p.p_flags & PF_W) != 0, x = (p.p_flags & PF_X) != 0;
            boundaries.push_back({start, r, w, x, 0});
            boundaries.push_back({end, -r, -w, -x, 0});
        }
        if (h->relroStart < h->relroEnd) {
            if (h->relroStart < h->loadBias || h->relroEnd - h->loadBias > h->mapSize) {
                set_error("%s: RELRO outside mapped image", h->name.c_str()); return false;
            }
            const size_t start = PAGE_TRUNC(h->relroStart - h->loadBias);
            // 与系统 linker 一样只处理完整尾页，避免把后一段普通可写数据误设只读。
            const size_t end = PAGE_TRUNC(h->relroEnd - h->loadBias);
            if (start < end) {
                boundaries.push_back({start, 0, 0, 0, 1});
                boundaries.push_back({end, 0, 0, 0, -1});
            }
        }
    } catch (const std::bad_alloc&) {
        set_error("%s: permission map allocation failed", h->name.c_str()); return false;
    }
    std::sort(boundaries.begin(), boundaries.end(),
              [](const Boundary& a, const Boundary& b) { return a.offset < b.offset; });
    size_t previous = 0;
    int read = 0, write = 0, execute = 0, relro = 0;
    for (size_t i = 0; i < boundaries.size();) {
        const size_t end = boundaries[i].offset;
        if (end > previous) {
            int permissions = (read ? PROT_READ : 0) | (write ? PROT_WRITE : 0) | (execute ? PROT_EXEC : 0);
            if (relro && permissions) permissions = (permissions | PROT_READ) & ~PROT_WRITE;
            if (mprotect(static_cast<char*>(h->base) + previous, end - previous, permissions) != 0) {
                const int error = errno;
                set_error("%s: mprotect final pages [%zu,%zu): %s",
                          h->name.c_str(), previous, end, strerror(error));
                return false;
            }
        }
        do {
            read += boundaries[i].read; write += boundaries[i].write;
            execute += boundaries[i].execute; relro += boundaries[i].relro;
            ++i;
        } while (i < boundaries.size() && boundaries[i].offset == end);
        previous = end;
    }
    return true;
}

/** 系统代码区仅由公开 dl_iterate_phdr 读取，调用方不得持有自定义注册锁。 */
struct SystemExecutableSpans {
    std::vector<ElfMemorySpan> spans;
    std::vector<ElfMemorySpan> readable;
    bool complete = true;
};
static int collect_system_executable(dl_phdr_info* info, size_t, void* opaque) {
    auto& output = *static_cast<SystemExecutableSpans*>(opaque);
    try {
        for (size_t i = 0; i < info->dlpi_phnum; ++i) {
            const auto& ph = info->dlpi_phdr[i];
            if (ph.p_type != PT_LOAD || !ph.p_memsz) continue;
            const uintptr_t start = info->dlpi_addr + ph.p_vaddr;
            if (start > UINTPTR_MAX - ph.p_memsz) { output.complete = false; return 1; }
            if (ph.p_flags & PF_X) output.spans.push_back({start, start + ph.p_memsz});
            if (ph.p_flags & PF_R) output.readable.push_back({start, start + ph.p_memsz});
        }
    } catch (const std::bad_alloc&) {
        output.complete = false;
        return 1; // 不能让 C++ 异常穿过系统 C 回调的锁作用域。
    }
    return 0;
}
/** 构造器执行前验证已重定位的函数地址；允许本批依赖与真实系统代码，不接受数据页。 */
// 1=全部有效，0=需要系统代码区快照，-1=确定无效；通常构造/析构入口就在本库，
// 此时不进入系统 linker，也不增加一次全进程模块遍历。
static int validate_initializer_targets(const LoadBatch& batch, const SystemExecutableSpans* system) {
    bool needSystem = false;
    auto executable = [&](Elf64_Addr address) {
        if (address % 4) return false; // AArch64 指令地址必须四字节对齐。
        for (const auto* library : g_loaded) {
            if (library->unloading || (!library->published && library->batch != &batch)) continue;
            const uintptr_t start = reinterpret_cast<uintptr_t>(library->base);
            if (address < start || address - start >= library->mapSize) continue;
            if (span_contains(library->executableSpans,
                              address - start + library->loadBias, 4)) return true;
        }
        if (!system) { needSystem = true; return true; }
        return span_contains(system->spans, address, 4);
    };
    for (const auto* library : batch.linked) {
        for (const auto array : {std::make_pair(library->initArray, library->initArraySz),
                                 std::make_pair(library->finiArray, library->finiArraySz)}) {
            for (size_t i = 0; i < array.second; ++i) {
                const Elf64_Addr address = array.first[i];
                if (!address || address == UINT64_MAX) continue;
                if (!executable(address)) {
                    set_error("%s: invalid init/fini target", library->name.c_str());
                    return -1;
                }
            }
        }
    }
    return needSystem ? 0 : 1;
}

struct UnwindReadContext {
    elf_handle_t* owner;
    const LoadBatch* batch;
    const SystemExecutableSpans* system;
};
/** 已验证的只读输入范围；personality 间接槽可以属于本批依赖，不能读未映射空洞。 */
static bool unwind_readable(void* opaque, uintptr_t address, size_t bytes) {
    const auto& context = *static_cast<UnwindReadContext*>(opaque);
    const auto ownerBase = reinterpret_cast<uintptr_t>(context.owner->base);
    if (address >= ownerBase && address - ownerBase <= context.owner->mapSize &&
        span_contains(context.owner->readableFileSpans, address - ownerBase + context.owner->loadBias, bytes)) return true;
    for (const auto* library : g_loaded) {
        if (library == context.owner) continue;
        if (library->unloading || (!library->published && library->batch != context.batch)) continue;
        const auto base = reinterpret_cast<uintptr_t>(library->base);
        if (address >= base && address - base <= library->mapSize &&
            span_contains(library->readableFileSpans, address - base + library->loadBias, bytes)) return true;
    }
    return context.system && span_contains(context.system->readable, address, bytes);
}
/** FDE 的 PC 只能覆盖本映像；异常 personality 才使用下方跨依赖代码查询。 */
static bool unwind_owned_code(void* opaque, uintptr_t address, size_t bytes) {
    auto* owner = static_cast<UnwindReadContext*>(opaque)->owner;
    const auto base = reinterpret_cast<uintptr_t>(owner->base);
    return address >= base && address - base <= owner->mapSize &&
        span_contains(owner->executableSpans, address - base + owner->loadBias, bytes);
}
static bool unwind_code(void* opaque, uintptr_t address, size_t bytes) {
    if (address % 4) return false;
    const auto& context = *static_cast<UnwindReadContext*>(opaque);
    for (const auto* library : g_loaded) {
        if (library->unloading || (!library->published && library->batch != context.batch)) continue;
        const auto base = reinterpret_cast<uintptr_t>(library->base);
        if (address >= base && address - base <= library->mapSize &&
            span_contains(library->executableSpans, address - base + library->loadBias, bytes)) return true;
    }
    return context.system && span_contains(context.system->spans, address, bytes);
}

// 显式复用 HAP 已加载的唯一应用 ABI provider。该句柄是宿主常驻 ABI 所有权，
// 不随某个 JDK/JNI DSO 关闭；初始化和所有使用均在注册表锁内，不依赖坏的旧 guard。
static void* g_unwindProvider = nullptr;
static decltype(&amcl_unwind_register_image) g_registerUnwindImage = nullptr;
static decltype(&amcl_unwind_unregister_image) g_unregisterUnwindImage = nullptr;
/** 状态/锁损坏不能转成可恢复 OOM，也不能在登记是否仍存在不确定时解除映射。 */
[[noreturn]] static void unwind_protocol_failure() {
    static const char message[] = "AMCL: inconsistent unwind registry state; refusing unsafe unmap\n";
    const ssize_t written = write(STDERR_FILENO, message, sizeof(message) - 1);
    (void)written; // 终止状态不依赖日志 FD 是否仍可写，也不能在此递归进入分配型日志器。
    abort();
}
static bool prepare_unwind_provider() {
#if defined(__OHOS__)
    if (g_registerUnwindImage && g_unregisterUnwindImage) return true;
    if (!g_unwindProvider) g_unwindProvider = open_system_library("libc++_shared.so", RTLD_NOW | RTLD_NOLOAD);
    if (g_unwindProvider) {
        g_registerUnwindImage = reinterpret_cast<decltype(g_registerUnwindImage)>(dlsym(g_unwindProvider, "amcl_unwind_register_image"));
        g_unregisterUnwindImage = reinterpret_cast<decltype(g_unregisterUnwindImage)>(dlsym(g_unwindProvider, "amcl_unwind_unregister_image"));
    }
    if (!g_registerUnwindImage || !g_unregisterUnwindImage) {
        set_error("application ABI provider lacks checked unwind image registration");
        return false;
    }
#endif
    return true;
}

/**
 * 在任何本批构造器前，验证已重定位 EH/CIE/FDE/CFI 结构并登记真实映像索引。
 * 节表缺失时以可读 LOAD 为硬界，按记录长度找到零终止项；绝不使用 SIZE_MAX 扫描。
 * 普通宿主 ELF 回归只验证格式，真实 OHOS 注册/展开由 SDK 目标集成测试覆盖。
 */
static bool prepare_unwind_image(elf_handle_t* h, const LoadBatch& batch, const SystemExecutableSpans& system) {
    using namespace amcl::unwindinput;
    if (!h->ehFrameSize && !h->ehHeaderSize) return true;
    auto reject = [&](const char* reason) { set_error("%s: invalid EH metadata: %s", h->name.c_str(), reason); return false; };
    UnwindReadContext context{h, &batch, &system};
    Memory memory{&context, unwind_readable, unwind_code, unwind_owned_code};
    Address frameBegin = h->ehFrameSize ? reinterpret_cast<Address>(vaddr2ptr(h, h->ehFrameAddress)) : 0;
    Address headerBegin = 0;
    struct HeaderRow { Address pc, fde; };
    std::vector<HeaderRow> rows;
    bool indexed = false;
    if (h->ehHeaderSize) {
        if (h->ehHeaderSize > UINT32_MAX || !span_contains(h->readableFileSpans, h->ehHeaderAddress, h->ehHeaderSize))
            return reject("EH header outside readable file-backed LOAD");
        headerBegin = reinterpret_cast<Address>(vaddr2ptr(h, h->ehHeaderAddress));
        Cursor header(memory, headerBegin, headerBegin + h->ehHeaderSize);
        if (header.read<uint8_t>() != 1) return reject("EH header version");
        const auto frameEncoding = header.read<uint8_t>();
        const auto countEncoding = header.read<uint8_t>();
        const auto tableEncoding = header.read<uint8_t>();
        const auto declaredBegin = header.encoded(frameEncoding, headerBegin);
        if (header.failed || !declaredBegin || (frameBegin && declaredBegin != frameBegin)) return reject("EH section/index disagreement");
        frameBegin = declaredBegin;
        const auto count = countEncoding == 0xff ? 0 : header.encoded(countEncoding, headerBegin);
        if (header.failed) return reject("EH index count encoding");
        indexed = tableEncoding != 0xff && count != 0;
        if (indexed) {
            // 两个数即使采用单字节 LEB，也至少占两字节；随后每次读取继续精确验证。
            if (count > (header.limit - header.at) / 2) return reject("EH index count exceeds table");
            rows.reserve(count);
            for (size_t i = 0; i < count; ++i) {
                const Address pc = header.encoded(tableEncoding, headerBegin);
                const Address fde = header.encoded(tableEncoding, headerBegin);
                if (header.failed || (i && pc < rows.back().pc)) return reject("truncated or unordered EH index");
                rows.push_back({pc, fde});
            }
        }
    }
    const auto base = reinterpret_cast<Address>(h->base);
    if (frameBegin < base || frameBegin - base >= h->mapSize) return reject("EH frame pointer outside image");
    if (!h->ehFrameSize) {
        const auto frameAddress = frameBegin - base + h->loadBias;
        const auto remaining = span_remaining(h->readableFileSpans, frameAddress);
        if (remaining < 4 || remaining > UINTPTR_MAX - frameBegin) return reject("stripped EH extent");
        const Address maximum = frameBegin + remaining;
        Address cursor = frameBegin;
        while (cursor < maximum) {
            Cursor marker(memory, cursor, maximum);
            const auto length = marker.read<uint32_t>();
            if (marker.failed) return reject("stripped EH truncated length");
            if (!length) { cursor = marker.at; break; }
            Cursor payload(memory, cursor, maximum);
            if (!record(memory, cursor, maximum, payload)) return reject("stripped EH record extent");
            cursor = payload.limit;
        }
        h->ehFrameAddress = frameAddress;
        h->ehFrameSize = cursor - frameBegin;
    }
    if (!span_contains(h->readableFileSpans, h->ehFrameAddress, h->ehFrameSize)) return reject("EH frame outside readable image");
    std::vector<Frame> frames;
    frames.reserve(rows.size()); // 索引给出已核对的数量，避免大型 JVM 准备阶段反复扩容复制。
    const char* detail = nullptr;
    if (!validate(memory, frameBegin, h->ehFrameSize, frames, detail)) return reject(detail ? detail : "EH structure");
    for (const auto& row : rows) {
        const auto found = std::lower_bound(frames.begin(), frames.end(), row.fde,
            [](const Frame& frame, Address address) { return frame.record < address; });
        if (found == frames.end() || found->record != row.fde || found->begin != row.pc)
            return reject("EH index does not match validated FDE");
    }
    if (frames.empty()) return true;
    if (!prepare_unwind_provider()) return false;
#if defined(__OHOS__)
    const amcl_unwind_image_v1 image{base, h->mapSize, frameBegin, h->ehFrameSize,
        indexed ? headerBegin : 0, indexed ? h->ehHeaderSize : 0};
    const int status = g_registerUnwindImage(&image);
    if (status != 0) {
        if (status != AMCL_UNWIND_NOMEM && status != AMCL_UNWIND_INVALID) unwind_protocol_failure();
        set_error("%s: unwind registration failed (%d)", h->name.c_str(), status);
        return false;
    }
    h->unwindRegistered = true;
#endif
    return true;
}

/** 全批链接完成后执行初始化；提前标记仅防止同线程构造重入，不代表已向其他线程发布。 */
static void call_init(elf_handle_t* h) {
    if (h->initialized) return;
    SystemLoadScope callbacks; // 所有递归注册锁层级都不跨用户构造器。
    h->initialized = true;

    /* CRITICAL: .init and .init_array values have ALREADY been relocated by
     * R_AARCH64_RELATIVE — they are absolute addresses, NOT virtual addresses.
     * Do NOT use vaddr2ptr() on them! Cast directly to function pointer. */
    if (h->hasInitFunc) {
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

    h->initializationOrder = g_initializationOrder.fetch_add(1, std::memory_order_relaxed) + 1;
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
    g_globalScope.erase(std::remove_if(g_globalScope.begin(), g_globalScope.end(), [h](const LookupMember& value) {
        return value.owner == h && value.identity == h->mappingIdentity;
    }), g_globalScope.end());
    if (h->unwindRegistered) {
        if (!g_unregisterUnwindImage || g_unregisterUnwindImage(reinterpret_cast<uintptr_t>(h->base)) != 0)
            unwind_protocol_failure();
        h->unwindRegistered = false;
    }
    h->tlsDescriptors.clear();
    if (h->tlsModule) {
        if (!h->initialized && h->tlsPrepared.valid()) {
            const int rolledBack = g_tlsStorage->RollbackPrepared(h->tlsPrepared);
            if (rolledBack != 0) tls_resolution_failure();
        }
        if (g_tlsStorage->Retire(h->tlsModule) != 0) tls_resolution_failure();
        h->tlsModule = nullptr;
    }
    if (h->fd >= 0) { close(h->fd); h->fd = -1; }
    if (h->base) { munmap(h->base, h->mapSize); h->base = nullptr; }
    free(h->phdr); h->phdr = nullptr;
}

/** 摘除的必须仍是当前对象，不能删掉析构重入期间同路径新加载的实例。 */
static void detach_public_names(elf_handle_t* h) {
    const auto path = g_byPath.find(h->path);
    if (path != g_byPath.end() && path->second == h) g_byPath.erase(path);
    const auto named = g_byName.find(h->name);
    if (named == g_byName.end() || named->second != h) return;
    const auto replacement = std::find_if(g_loaded.begin(), g_loaded.end(), [h](const elf_handle_t* candidate) {
        return candidate != h && !candidate->unloading && candidate->name == h->name;
    });
    if (replacement == g_loaded.end()) g_byName.erase(named);
    else named->second = *replacement;
}

/** 系统 dlclose 可能执行任意析构，调用者必须已释放注册锁并保持本批映射仍存活。 */
static void close_one_system_dependency(elf_handle_t* h) {
    SystemLoadScope callbacks; // 系统 dlclose 也可能进入任意用户 fini。
    const auto dependency = h->systemDependencies.back();
    h->systemDependencies.pop_back(); // 本次唯一引用先交给系统，重入不能重复消费它。
    if (!dependency) return; // 私有节点只有只读元数据，其代码寿命由仍持有的公开祖先管理。
    if (dlclose(dependency) != 0) {
        static const char message[] = "AMCL: system dependency reference state is inconsistent\n";
        const ssize_t written = write(STDERR_FILENO, message, sizeof(message) - 1);
        (void)written;
        abort(); // 已经开始终结，不能伪造恢复为 LIVE 或继续解除可能仍被回调使用的映射。
    }
}
static void close_system_dependencies(elf_handle_t* h) {
    while (!h->systemDependencies.empty()) close_one_system_dependency(h);
}

/** 按公开持有者和准备/终结事务标记依赖闭包，纯依赖环不会因为边互相引用而永久存活。 */
static void mark_reachable_images() {
    for (auto* image : g_loaded)
        image->reachable = image->openReferences || image->lookupReferences || image->nodelete || image->batch || image->constructing ||
                           image->finalizing || image->threadDestructorReferences;
    bool changed;
    do {
        changed = false;
        for (const auto* image : g_loaded) {
            if (!image->reachable) continue;
            for (auto* dependency : image->dependencies) {
                if (!dependency->reachable) { dependency->reachable = true; changed = true; }
            }
        }
    } while (changed);
}

/** 终结入口不持注册锁；整个退休集合仍保留映射/EH，防止较晚析构调用较早对象代码。 */
static void call_fini(elf_handle_t* h) {
    SystemLoadScope callbacks; // 递归查询/延迟回收路径的外层注册锁也必须释放。
    for (size_t index = h->finiArraySz; index > 0; --index) {
        const auto address = h->finiArray[index - 1];
        if (address && address != UINT64_MAX) reinterpret_cast<void(*)()>(address)();
    }
    if (h->hasFiniFunc) reinterpret_cast<void(*)()>(vaddr2ptr(h, h->finiFunc))();
}

/**
 * 消费一个公开 open 引用；没有外部根的依赖集合在同一事务退休。容量准备在消费
 * 引用之前完成，分配失败保持句柄有效。TLS/退出回调的附加根由后续生命周期阶段接入。
 */
static int collect_unreferenced_images(std::unique_lock<std::recursive_mutex>& guard, elf_handle_t* closing = nullptr) {
    if (g_lookupPins) g_lookupCollectionPending = true;
    std::vector<elf_handle_t*> retired;
    try { retired.reserve(g_loaded.size()); }
    catch (const std::bad_alloc&) { set_error("ELF close preparation allocation failed"); return -1; }
    if (closing) --closing->openReferences;
    mark_reachable_images();
    for (auto* image : g_loaded) if (image->published && !image->reachable && !image->finalizing) retired.push_back(image);
    std::sort(retired.begin(), retired.end(), [](const elf_handle_t* left, const elf_handle_t* right) {
        return left->initializationOrder > right->initializationOrder;
    });
    for (auto* image : retired) { image->unloading = true; image->finalizing = true; }
    for (auto* image : retired) detach_public_names(image);
    for (;;) {
        // 本批保活只防止重入/并发回收，不能被误当成用户引用。持锁撤销它以重算真实根，
        // 其它终结事务的保活仍参与闭包；离开锁前恢复，保证本批指针始终由同一事务拥有。
        for (auto* image : retired) image->finalizing = false;
        mark_reachable_images();
        const auto next = std::find_if(retired.begin(), retired.end(), [](const elf_handle_t* image) {
            return !image->finalized && !image->reachable;
        });
        for (auto* image : retired) image->finalizing = true;
        if (next == retired.end()) break;
        auto* image = *next;
        guard.unlock();
        call_fini(image);
        guard.lock();
        image->finalized = true;
        // A.fini 可以首次登记依赖B的C++ TLS析构。必须在执行B.fini/CRT静态析构之前
        // 重新计算新增根；只保住映射而提前销毁B的静态资源，仍然违背晚TLS析构的寿命。
    }
    for (auto* image : retired) image->finalizing = false;
    mark_reachable_images();
    retired.erase(std::remove_if(retired.begin(), retired.end(), [](const elf_handle_t* image) {
        return image->reachable;
    }), retired.end());
    for (auto* image : retired) image->finalizing = true;
    for (;;) {
        for (auto* image : retired) image->finalizing = false;
        mark_reachable_images();
        const auto next = std::find_if(retired.begin(), retired.end(), [](const elf_handle_t* image) {
            return !image->reachable && !image->systemDependencies.empty();
        });
        for (auto* image : retired) image->finalizing = true;
        if (next == retired.end()) break;
        guard.unlock();
        close_one_system_dependency(*next);
        guard.lock();
        // 一个系统fini可能产生新回调根，后续尚未交给系统的引用须重新评估。
        // 已开始的系统fini遵循系统loader自己的合同，此处不声称能够撤销它。
    }
    for (auto* image : retired) image->finalizing = false;
    mark_reachable_images();
    for (auto* image : retired) {
        if (image->reachable) continue;
        g_loaded.erase(std::remove(g_loaded.begin(), g_loaded.end(), image), g_loaded.end());
        cleanup_handle(image);
        delete image;
    }
    return 0;
}

static int close_elf_locked(elf_handle_t* h, std::unique_lock<std::recursive_mutex>& guard) {
    if (!is_elf_handle(h) || !visible_to_caller(h) || !h->openReferences) {
        set_error("invalid or unowned ELF close handle"); return -1;
    }
    return collect_unreferenced_images(guard, h);
}

// 这是宿主真实 CRT 的对象标识，传给系统队列，使其保留执行 trampoline 的已安装 DSO。
extern "C" void* __dso_handle;
using SystemThreadDestructorRegistration = int (*)(void (*)(void*), void*, void*);
static std::atomic<SystemThreadDestructorRegistration> g_systemThreadDestructorRegistration{nullptr};
struct ThreadDestructorRecord {
    void (*function)(void*);
    void* object;
    pid_t process;
    elf_handle_t* owners[2];
    unsigned count;
};

/** 只查询本映像的实际地址范围，不根据文件名/上次加载的 raw handle 猜回调属于哪个实例。 */
static elf_handle_t* image_containing_address(const void* address) {
    const uintptr_t value = reinterpret_cast<uintptr_t>(address);
    for (auto* image : g_loaded) {
        const uintptr_t base = reinterpret_cast<uintptr_t>(image->base);
        if (image->base && value >= base && value - base < image->mapSize) return image;
    }
    return nullptr;
}

/** 在真实所属线程执行用户析构；这里不释放线程存储，更不在 reaper 上补跑用户析构。 */
static void run_thread_destructor(void* opaque) noexcept {
    auto* record = static_cast<ThreadDestructorRecord*>(opaque);
    if (record->process != getpid()) {
        // 多线程fork子分支只允许既定exec/_exit；不能执行继承的自加载回调，也不能
        // 先触碰可能由已消失父线程持有的注册锁。这个拒绝不冒称已完成用户析构。
        static const char message[] = "AMCL: refusing inherited custom TLS callbacks after fork\n";
        const ssize_t written = write(STDERR_FILENO, message, sizeof(message) - 1);
        (void)written;
        _exit(127);
    }
    record->function(record->object);
    RegistryLock guard;
    bool releasedRoot = false;
    for (unsigned index = 0; index < record->count; ++index) {
        if (!record->owners[index]->threadDestructorReferences) tls_resolution_failure();
        auto* owner = record->owners[index];
        --owner->threadDestructorReferences;
        releasedRoot = releasedRoot || (!owner->threadDestructorReferences && !owner->openReferences);
    }
    delete record;
    // 与目标系统队列减少 DSO 析构引用后的行为一致，最后回调完成可尝试延迟 close。
    // 准备 OOM 时保持映像，后续 close 可重试；此失败不凭空改变已经完成的用户析构。
    // 大量普通线程析构时映像通常仍由公开handle持有，或仍有其它callback根；根集合
    // 没有变化时不分配退休vector、不扫描全部映像。最后一个可能消失的根才触发收集。
    if (releasedRoot) collect_unreferenced_images(guard);
}

/**
 * 同一系统 C++ 队列维持系统/custom 回调的真实交错。记录只持实际 object-DSO 与
 * destructor-code-DSO 两个根，依赖闭包由已有图维护；分配及系统登记都不持注册锁。
 */
static int hooked_cxa_thread_atexit(void (*destructor)(void*), void* object, void* cookie) {
    auto system = g_systemThreadDestructorRegistration.load(std::memory_order_acquire);
    if (!system) {
        // OHOS app namespace中libc可以位于libentry之前；RTLD_NEXT只搜后续对象，
        // 因而不能证明系统没有此API。只查询已经加载的真实libc句柄，不另装第二份libc。
        // .so.6仅用于GNU宿主参考；成功后缓存的代码由libentry的libc依赖维持进程寿命。
        for (const char* name : {"libc.so", "libc.so.6"}) {
            void* library = dlopen(name, RTLD_NOW | RTLD_NOLOAD);
            if (!library) continue;
            system = reinterpret_cast<SystemThreadDestructorRegistration>(dlsym(library, "__cxa_thread_atexit_impl"));
            const int closed = dlclose(library);
            if (closed != 0) tls_resolution_failure();
            if (system) break;
        }
        if (!system) tls_resolution_failure();
        g_systemThreadDestructorRegistration.store(system, std::memory_order_release);
    }
    ThreadDestructorRecord staged{destructor, object, getpid(), {nullptr, nullptr}, 0};
    {
        RegistryLock guard;
        if (auto* owner = image_containing_address(cookie)) staged.owners[staged.count++] = owner;
        if (auto* code = image_containing_address(reinterpret_cast<void*>(destructor));
            code && (staged.count == 0 || staged.owners[0] != code)) staged.owners[staged.count++] = code;
        for (unsigned index = 0; index < staged.count; ++index) {
            if (staged.owners[index]->threadDestructorReferences == SIZE_MAX) tls_resolution_failure();
            ++staged.owners[index]->threadDestructorReferences;
        }
    }
    if (!staged.count) return system(destructor, object, cookie);
    auto* record = new (std::nothrow) ThreadDestructorRecord(staged);
    if (record && system(run_thread_destructor, record, &__dso_handle) == 0) return 0;
    {
        RegistryLock guard;
        for (unsigned index = 0; index < staged.count; ++index) --staged.owners[index]->threadDestructorReferences;
    }
    delete record;
    // 编译器不检查此 ABI 的返回码。对象已经构造后，不能静默丢失其析构义务。
    tls_resolution_failure();
}

/* ================================================================
 * Public C API
 * ================================================================ */

void elf_set_search_path(const char* paths) {
    RegistryLock guard;
    g_searchPaths = paths ? paths : "";
    OH_LOG_INFO(LOG_APP, "search paths: %{public}s", g_searchPaths.c_str());
}

/** 在一个尚未发布的依赖批次中完成映射和重定位，构造器统一延后。 */
static elf_handle_t* prepare_elf(const char* path) {
    if (!path || !path[0]) { set_error("null path"); return nullptr; }
    const std::string resolved = resolve_path(path);
    if (resolved.empty()) { set_error("%s: not found", path); return nullptr; }
    auto found = g_byPath.find(resolved);
    if (found != g_byPath.end()) {
        if (visible_to_caller(found->second)) return found->second;
        set_error("%s: library is initializing on another thread", path);
        return nullptr;
    }
    std::unique_ptr<elf_handle_t> pending(new elf_handle_t{});
    elf_handle_t* h = pending.get();
    h->magic = ELF_HANDLE_MAGIC;
    if (g_mappingIdentity == UINT64_MAX) { set_error("ELF mapping identity exhausted"); return nullptr; }
    h->mappingIdentity = ++g_mappingIdentity;
    h->fd = -1;
    h->path = resolved;
    const char* slash = strrchr(resolved.c_str(), '/');
    h->name = slash ? slash + 1 : resolved;
    h->loadingThread = pthread_self();
    h->batch = g_loadBatch;
    // 先将回收责任交给批次，再做映射/注册；任何一次容器分配失败都由同一回滚路径收口。
    g_loadBatch->created.push_back(h);
    pending.release();
    if (!read_headers(h, resolved.c_str()) || !map_segments(h) || !parse_dynamic(h)) {
        return nullptr;
    }
    // 先登记用于依赖环解析，但不标为 published，也不执行任何构造器。
    g_byPath[resolved] = h;
    g_byName.emplace(h->name, h);
    g_loaded.push_back(h);
    // 先完成全图映射，不能在 DFS 的第一个子树里重定位，否则后续直接兄弟依赖尚未
    // 注册，BFS 应命中的定义会被孙节点抢占，或者被错误报告成缺失。
    if (!load_deps(h)) return nullptr;
    g_loadBatch->linked.push_back(h);
    return h;
}

/**
 * 外层加载拥有整个依赖批次。任意链接失败回滚所有本批新对象；已有对象不动。
 * 链接全部成功后才释放注册锁并运行构造器，避免锁跨任意用户初始化回调。
 */
static elf_handle_t* open_elf_with_flags(const char* path, int flags) {
    // 嵌套准备复用外层唯一锁；系统构造回调期间 g_loadBatch 已被暂时清空。
    if (g_loadBatch) return prepare_elf(path);
    std::lock_guard<std::recursive_mutex> operation(g_openMutex);
    RegistryLock guard;
    g_error[0] = 0;
    g_errorPending = false;
    LoadBatch batch;
    batch.registryLock = &guard;
    g_loadBatch = &batch;
    elf_handle_t* result = nullptr;
    try {
        result = prepare_elf(path);
        if (result) {
            for (auto* image : batch.created) {
                if (!prepare_system_scopes(image)) { result = nullptr; break; }
            }
        }
        if (result) {
            for (auto* image : batch.created) image->handleScope = build_lookup_scope(image);
            for (auto* image : batch.created) image->originScope = result->handleScope;
            for (auto* image : batch.linked) {
                if (!apply_relocs(image) || !protect_segments(image)) { result = nullptr; break; }
            }
        }
    } catch (const std::bad_alloc&) {
        set_error("ELF preparation allocation failed"); result = nullptr;
    } catch (...) {
        set_error("ELF preparation failed before initialization"); result = nullptr;
    }
    g_loadBatch = nullptr;
    // 重定位已结束，选中的真实提供者已经交给各消费 DSO。先归还仅用于批次复用的
    // 候选引用，再采集 EH 依赖和调用用户构造器；失败路径也在此归还，异常展开时
    // LoadBatch 中的 unique_ptr 继续兜底，不能为启动缓存保留无关库到进程结束。
    batch.nativeBindingViews.clear();
    try {
        if (result) for (auto* image : batch.linked) {
            if (!prepare_tls_storage(image)) { result = nullptr; break; }
        }
        if (result && !batch.created.empty()) {
            const int checked = validate_initializer_targets(batch, nullptr);
            const bool hasUnwind = std::any_of(batch.created.begin(), batch.created.end(),
                [](const elf_handle_t* image) { return image->ehFrameSize || image->ehHeaderSize; });
            if (checked < 0) result = nullptr;
            else if (checked == 0 || hasUnwind) {
                SystemExecutableSpans system;
                guard.unlock();
                dl_iterate_phdr(collect_system_executable, &system);
                if (system.complete) { merge_spans(system.spans); merge_spans(system.readable); }
                guard.lock();
                if (!system.complete) { set_error("system executable snapshot allocation failed"); result = nullptr; }
                else if (validate_initializer_targets(batch, &system) < 0) result = nullptr;
                if (result) for (auto* image : batch.linked) {
                    if (!prepare_unwind_image(image, batch, system)) { result = nullptr; break; }
                }
            }
        }
        // 全局表的扩容在任何 ctor 之前完成；未成功链接的 LOCAL 组不会提前全局化。
        if (result && (flags & RTLD_GLOBAL))
            g_globalScope.reserve(g_globalScope.size() + result->handleScope->members.size());
    } catch (const std::bad_alloc&) {
        set_error("ELF unwind preparation allocation failed"); result = nullptr;
    } catch (...) {
        set_error("ELF unwind preparation failed before initialization"); result = nullptr;
    }
    if (!result) {
        // 在关闭系统依赖之前先将本批私有化，但仍保留为图根，确保系统析构期间
        // 已有依赖和本批代码不会被另一个关闭事务提前释放。
        for (auto* image : batch.created) image->unloading = true;
        for (auto* image : batch.created) detach_public_names(image);
        char savedError[sizeof(g_error)]; memcpy(savedError, g_error, sizeof(g_error));
        const bool savedPending = g_errorPending;
        guard.unlock();
        for (auto it = batch.created.rbegin(); it != batch.created.rend(); ++it) close_system_dependencies(*it);
        guard.lock();
        for (auto it = batch.created.rbegin(); it != batch.created.rend(); ++it) {
            elf_handle_t* h = *it;
            g_loaded.erase(std::remove(g_loaded.begin(), g_loaded.end(), h), g_loaded.end());
            cleanup_handle(h);
            delete h;
        }
        // 失败批次可能短暂保护了一个刚结束 TLS 回调的旧对象，删除绑定边后重新收敛。
        // 如回收准备本身资源不足，仍保留对象供下一次冷路径回收，并恢复最初装载错误。
        try { collect_unreferenced_images(guard); } catch (...) {}
        memcpy(g_error, savedError, sizeof(g_error)); g_errorPending = savedPending;
        return nullptr;
    }
    if (result->openReferences == SIZE_MAX) { set_error("ELF open reference limit reached"); return nullptr; }
    ++result->openReferences;
    if (flags & RTLD_GLOBAL) promote_lookup_scope(result->handleScope);
    if (flags & RTLD_NODELETE) result->nodelete = true;
    for (auto* h : batch.created) h->constructing = true;
    guard.unlock();
    for (auto* h : batch.linked) call_init(h);
    guard.lock();
    for (auto* h : batch.created) { h->published = true; h->constructing = false; h->batch = nullptr; }
    return result;
}

/** 旧显式宿主入口一直具有全局可见语义；有 flags 的透明入口单独保留 LOCAL/GLOBAL。 */
elf_handle_t* elf_open(const char* path) { return open_elf_with_flags(path, RTLD_NOW | RTLD_GLOBAL); }

/** C 查询边界把元数据快照/保活边分配失败转换为 dlerror；RAII 先归还临时引用与锁。
 * 不吞任意异常，尤其不干预系统线程取消的强制展开。正常 C/Java 调用者不接收 bad_alloc。 */
void* elf_sym(elf_handle_t* h, const char* name) try {
    RegistryLock guard;
    if (!is_elf_handle(h) || !name || !visible_to_caller(h)) return nullptr;
    LookupPin owner(h);
    const auto scope = h->handleScope;
    bool found = false;
    void* result = scope ? resolve_lookup_scope(scope->members, name, found) : nullptr;
    if (!found) set_error("%s: undefined symbol: %s", h->name.c_str(), name);
    return result;
} catch (const std::bad_alloc&) {
    set_error("ELF symbol query allocation failed"); return nullptr;
}

void* elf_sym_global(const char* name) try {
    RegistryLock guard;
    if (!name) { set_error("invalid global symbol query"); return nullptr; }
    return resolve_global(name);
} catch (const std::bad_alloc&) {
    set_error("ELF global symbol query allocation failed"); return nullptr;
}

void elf_close(elf_handle_t* h) {
    std::lock_guard<std::recursive_mutex> operation(g_openMutex);
    RegistryLock guard;
    if (h) close_elf_locked(h, guard);
}

const char* elf_error(void) {
    return g_error;
}

int elf_get_tls_stats(elf_tls_stats* stats) {
    if (!stats) return EINVAL;
    *stats = {};
    const pid_t process = g_tlsRuntimeProcess.load();
    if (!process) return 0;
    if (process != getpid()) return ECHILD; // fork后不能先等待继承的初始化锁。
    const int locked = pthread_mutex_lock(&g_tlsRuntimeMutex);
    if (locked) return locked;
    struct Unlock { ~Unlock() { pthread_mutex_unlock(&g_tlsRuntimeMutex); } } unlock;
    if (!g_tlsStorage) return 0;
    const auto source = g_tlsStorage->Snapshot();
    if (source.error) return source.error;
    *stats = {source.residentArenas, source.registeredArenas, source.blocks, source.payloads,
              source.storageBytes, source.moduleBytes, source.expansionError};
    return 0;
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

/** NOLOAD是纯查询加公开引用，不能为查询执行映射、依赖加载或构造器。
 * 使用已登记路径/名称，不要求已映射文件仍存在；成功后仍须与一次close配对。
 * NODELETE只响应明确请求并通过现有图根保持依赖，不改变普通模块的回收策略。
 */
static elf_handle_t* open_custom_with_flags(const char* path, int flags) {
    std::lock_guard<std::recursive_mutex> operation(g_openMutex);
    if (flags & RTLD_NOLOAD) {
        RegistryLock guard;
        g_error[0] = 0; g_errorPending = false;
        elf_handle_t* handle = nullptr;
        if (strchr(path, '/')) {
            const auto found = g_byPath.find(path);
            if (found != g_byPath.end()) handle = found->second;
        } else {
            const auto found = g_byName.find(path);
            if (found != g_byName.end()) handle = found->second;
        }
        if (!handle || !visible_to_caller(handle)) {
            set_error("%s: RTLD_NOLOAD object is not available", path); return nullptr;
        }
        if (handle->openReferences == SIZE_MAX) {
            set_error("ELF open reference limit reached"); return nullptr;
        }
        if (flags & RTLD_GLOBAL) {
            try { promote_lookup_scope(handle->handleScope); }
            catch (const std::bad_alloc&) { set_error("ELF global promotion allocation failed"); return nullptr; }
        }
        ++handle->openReferences;
        if (flags & RTLD_NODELETE) handle->nodelete = true;
        return handle;
    }
    return open_elf_with_flags(path, flags);
}

/**
 * 对外 dlopen 的系统分支也必须发布到同一线程错误槽。HotSpot 会先查询可选
 * JNI_OnLoad_<库名>，那次未命中不能盖住随后真实的路径/依赖装载失败。先清系统槽以隔离
 * 上次探测，失败后立即复制详情；日志只读副本，不能提前消费调用者应取得的 dlerror。
 * 成功仍返回系统原句柄，不添加搜索路径、自定义 ELF 回退或任何命名空间例外。
 */
static void* open_system_for_public_api(const char* path, int flags) {
    dlerror();
    void* result = open_system_library(path, flags);
    if (!result) {
        const char* detail = dlerror();
        if (detail) set_error("%s", detail);
        else set_error("system dlopen failed without diagnostic: %s", path ? path : "<process>");
        AMCL_LOG_W(LOG_TAG, "elf_dlopen(%{public}s) → NULL: %{public}s", path ? path : "<process>", g_error);
    }
    return result;
}

void* elf_dlopen(const char* path, int flags) {
    if (!path) {
        void* handle = open_system_for_public_api(nullptr, flags);
        if (handle) {
            RegistryLock guard;
            // 额外保留自身查询引用，调用者 close 返回句柄后内部全局查询仍持有有效 owner。
            if (!g_processSymbolHandle) {
                void* own = open_system_library(nullptr, RTLD_NOW);
                if (!g_processSymbolHandle) g_processSymbolHandle = own;
                else if (own) { SystemLoadScope callbacks; dlclose(own); }
            }
        }
        return handle;
    }

    OH_LOG_INFO(LOG_APP, "elf_dlopen: %{public}s (flags=0x%{public}x)", path, flags);

    if (flags & RTLD_NOLOAD) {
        // NOLOAD 查询的是“已经映射的对象”，不是“搜索目录里存在的文件”。必须先查
        // 自定义注册表，再直接问系统的已有实例；不能让磁盘上的同名候选遮住系统库，
        // 更不能为查询映射一个新对象。两侧返回都仍带一份需配对 close 的真实引用。
        {
            std::lock_guard<std::recursive_mutex> operation(g_openMutex);
            RegistryLock guard;
            const bool present = strchr(path, '/') ? g_byPath.find(path) != g_byPath.end()
                                                   : g_byName.find(path) != g_byName.end();
            if (present) return open_custom_with_flags(path, flags);
        }
        return open_system_for_public_api(path, flags);
    }

    if (needs_elf_loader(path)) {
        OH_LOG_INFO(LOG_APP, "elf_dlopen: using ELF loader for %{public}s", path);
        elf_handle_t* h = open_custom_with_flags(path, flags);
        return h ? (void*)h : nullptr;
    }

    /* Try our search paths for bare filenames */
    if (!strchr(path, '/')) {
        // 已登记对象即使源文件已删除，也必须满足NOLOAD查询；不能先stat再回落系统。
        if (flags & RTLD_NOLOAD) {
            RegistryLock guard;
            if (g_byName.find(path) != g_byName.end()) return open_custom_with_flags(path, flags);
        }
        std::string resolved = resolve_path(path);
        if (!resolved.empty() && needs_elf_loader(resolved.c_str())) {
            OH_LOG_INFO(LOG_APP, "elf_dlopen: resolved %{public}s → ELF loader", path);
            elf_handle_t* h = open_custom_with_flags(resolved.c_str(), flags);
            return h ? (void*)h : nullptr;
        }
    }

    return open_system_for_public_api(path, flags);
}

__attribute__((noinline)) void* elf_dlsym(void* handle, const char* name) try {
    // 在直接入口捕获真实 ELF 调用帧；不能在深层 helper 中取 libentry 自己的返回地址。
    const void* callerAddress = __builtin_extract_return_addr(__builtin_return_address(0));
    RegistryLock guard;
    if (!name) return nullptr;
    elf_handle_t* caller = image_containing_address(callerAddress);
    LookupPin callerOwner(caller);

    /* RTLD_DEFAULT / RTLD_NEXT: search ELF libs first, then system.
     * CRITICAL: we must NOT pass RTLD_NEXT to system dlsym from here,
     * because RTLD_NEXT is relative to the CALLER — and our caller is
     * libentry.so, not the original ELF-loaded library. */
    if (handle == RTLD_DEFAULT || handle == nullptr || handle == g_processSymbolHandle) {
        bool found = false;
        elf_handle_t* supplier = nullptr;
        void* p = resolve_global(name, &found, &supplier, caller ? caller->originScope.get() : nullptr, caller);
        if (caller && found) retain_dependency(caller, supplier);
        if (!found) set_error("undefined global symbol: %s", name);
        return p;
    }
    if (handle == RTLD_NEXT) {
        // glibc 真实对照：NEXT 在原调用者的装载组内跳过调用者，不能把后来无依赖的
        // GLOBAL 库拼接为“下一个”。系统调用者仍交系统；custom 调用者必须用自己的组。
        if (caller && caller->originScope) {
            bool found = false;
            elf_handle_t* supplier = nullptr;
            void* address = resolve_lookup_scope(caller->originScope->members, name, found, &supplier, caller,
                                                LookupDomain::All, caller);
            if (found) retain_dependency(caller, supplier);
            else set_error("%s: undefined next symbol: %s", caller->name.c_str(), name);
            return address;
        }
        bool found = false;
        void* address = lookup_system_symbol(RTLD_NEXT, name, found);
        if (!found) set_error("undefined system next symbol: %s", name);
        return address;
    }

    if (is_elf_handle(handle)) {
        return elf_sym((elf_handle_t*)handle, name);
    }
    bool found = false;
    void* address = lookup_system_symbol(handle, name, found);
    if (!found) set_error("undefined system symbol: %s", name);
    return address;
} catch (const std::bad_alloc&) {
    // function-try-block 保留真正调用帧，不能新增转发 wrapper 破坏 RTLD_NEXT 的起点。
    set_error("ELF dlsym allocation failed"); return nullptr;
}

/** 显式 ELF 版本查询沿用原始调用者的 DEFAULT/NEXT 范围，保留真实零地址命中。 */
__attribute__((noinline)) void* elf_dlvsym(void* handle, const char* name, const char* versionName) try {
    const void* callerAddress = __builtin_extract_return_addr(__builtin_return_address(0));
    RegistryLock guard;
    if (!name || !versionName || !*versionName) { set_error("invalid versioned symbol query"); return nullptr; }
    const amcl::elfversions::Request version{versionName, amcl::elfversions::hash(versionName), false};
    elf_handle_t* caller = image_containing_address(callerAddress);
    LookupPin callerOwner(caller);
    elf_handle_t* supplier = nullptr;
    bool found = false;
    void* address = nullptr;
    if (handle == RTLD_DEFAULT || handle == nullptr || handle == g_processSymbolHandle) {
        address = resolve_global(name, &found, &supplier, caller ? caller->originScope.get() : nullptr, caller, &version);
    } else if (handle == RTLD_NEXT && caller && caller->originScope) {
        address = resolve_lookup_scope(caller->originScope->members, name, found, &supplier, caller,
                                       LookupDomain::All, caller, &version);
    } else if (is_elf_handle(handle)) {
        auto* image = static_cast<elf_handle_t*>(handle);
        LookupPin imageOwner(image);
        if (image->handleScope)
            address = resolve_lookup_scope(image->handleScope->members, name, found, &supplier, nullptr,
                                           LookupDomain::All, caller, &version);
    } else address = lookup_system_symbol(handle, name, found, &version);
    if (caller && found) retain_dependency(caller, supplier);
    if (!found) set_error("undefined versioned symbol: %s@%s", name, versionName);
    return address;
} catch (const std::bad_alloc&) {
    set_error("ELF dlvsym allocation failed"); return nullptr;
}

int elf_dlclose(void* handle) {
    std::lock_guard<std::recursive_mutex> operation(g_openMutex);
    RegistryLock guard;
    if (!handle) { set_error("null close handle"); return -1; }
    if (is_elf_handle(handle)) {
        return close_elf_locked(static_cast<elf_handle_t*>(handle), guard);
    }
    guard.unlock(); // 系统析构不得在自定义注册锁内执行。
    SystemLoadScope callbacks;
    return dlclose(handle);
}

/** HotSpot/JNA 一次消费本线程最近的库或符号失败；没有自有待取错误时委托系统。 */
char* elf_dlerror(void) {
    if (g_errorPending) {
        g_errorPending = false;
        dlerror(); // 清掉同次系统尝试的陈旧错误，但保留本线程自定义详情。
        return g_error;
    }
    return dlerror();
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
