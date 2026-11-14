/**
 * 真实生产 loader 的 AArch64 集成负例：只替换平台日志与无关 IPv6 文件合成。
 * 验证强/弱导入、依赖失败、整批回滚、构造时序、重复失败和历史 JLI 精确兼容。
 */
#include <sys/mman.h>
#include <cerrno>
#include <atomic>
#include <cstdlib>
#include <new>
#include <pthread.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <dlfcn.h>
static bool hidePrivateLeaf = false;
static void* namespace_dlopen(const char*, int);
static std::atomic<bool> failTlsObserver{false}, failTlsObservation{false};
static std::atomic<int> tlsAllocationBudget{-1};
static int probe_thread_create(pthread_t*, const pthread_attr_t*, void* (*)(void*), void*);
static void* probe_tls_allocate(size_t, void*) noexcept;
static int probe_tls_observe(pid_t, pid_t, void*) noexcept;
static std::atomic<int> allocationBudget{-1};
// 按真实 C++ 分配序列注入一次失败，覆盖部分注册后的统一回滚，不在产品添加测试分支。
void* operator new(size_t size) {
    if (allocationBudget.load() >= 0 && allocationBudget.fetch_sub(1) == 0) throw std::bad_alloc();
    if (void* result = malloc(size ? size : 1)) return result;
    throw std::bad_alloc();
}
void* operator new[](size_t size) { return ::operator new(size); }
void operator delete(void* value) noexcept { free(value); }
void operator delete(void* value, size_t) noexcept { free(value); }
void operator delete[](void* value) noexcept { free(value); }
void operator delete[](void* value, size_t) noexcept { free(value); }
static bool failProtection = false;
static int probe_mprotect(void* address, size_t length, int protection);
// 仅替换生产 loader 调用的 mprotect，系统 linker 仍走真实实现。
#define mprotect probe_mprotect
#define pthread_create probe_thread_create
#define dlopen namespace_dlopen
#include "../../entry/src/main/cpp/jvm/elf_loader.cpp"
#undef dlopen
#undef mprotect
#undef pthread_create
#include <cassert>
#include <fstream>
#include <iostream>
#include <thread>

/** 只限制本loader发出的NOLOAD，不阻止原生root的真实DT_NEEDED装载，也不伪造dlsym。
 * 这模拟商业目标的app→private命名空间边；PHDR、符号、TLS、IFUNC和寿命全由真实glibc执行。
 */
static void* namespace_dlopen(const char* path, int flags) {
    if (hidePrivateLeaf && path && (flags & RTLD_NOLOAD)) {
        const char* base = strrchr(path, '/');
        if (strcmp(base ? base + 1 : path, "libmixed_leaf.so") == 0) {
            errno = EACCES; return nullptr;
        }
    }
    return ::dlopen(path, flags);
}
static int probe_mprotect(void* address, size_t length, int protection) {
    if (failProtection) { errno = EACCES; return -1; }
    return ::mprotect(address, length, protection);
}
static void* probe_tls_allocate(size_t size, void*) noexcept {
    if (tlsAllocationBudget.load() >= 0 && tlsAllocationBudget.fetch_sub(1) == 0) return nullptr;
    return malloc(size);
}
static int probe_tls_observe(pid_t process, pid_t thread, void*) noexcept {
    if (failTlsObservation.load()) return EPERM;
    return amcl::tlsstorage::detail::observe(process, thread, nullptr);
}
static int probe_thread_create(pthread_t* thread, const pthread_attr_t* attributes, void* (*entry)(void*), void* argument) {
    return failTlsObserver.load() ? EAGAIN : ::pthread_create(thread, attributes, entry, argument);
}

static int marks = 0;
static std::string probePath;
static int concurrentProbes = 0;
static std::atomic<bool> scopeEntered{false}, scopeRelease{false};
static std::atomic<int> scopeConstructors{0};
static elf_handle_t* resolverOwner = nullptr;
static int resolverCalls = 0, resolverFinishes = 0;
static bool closeInsideResolver = false;
/** 系统 IFUNC 运行时让另一线程只读 custom，再从 resolver 关闭查询拥有者。
 * 只有真实原生 dlsym 能进入此回调，测试不直接调用它；注册锁和生命周期错误分别表现为
 * join 卡死或系统 fini 提前运行，不能通过伪造 resolver 返回值隐藏。 */
extern "C" void scope_resolver_probe(void) {
    ++resolverCalls;
    std::thread reader([] {
        auto* value = static_cast<int*>(elf_sym(resolverOwner, "mixed_resolver_visible"));
        assert(value && *value == 61);
    });
    reader.join();
    if (closeInsideResolver) {
        assert(elf_dlclose(resolverOwner) == 0);
        assert(resolverOwner->openReferences == 0 && resolverOwner->lookupReferences > 0);
        assert(resolverFinishes == 0 && is_elf_handle(resolverOwner));
    }
}
extern "C" void scope_resolver_finalized(void) { ++resolverFinishes; }
/** 与独立 glibc 参考共享同一真实 ctor 夹具，门释放前第二个 open 不得取得半初始化对象。 */
extern "C" void scope_initialization_gate(void) {
    scopeConstructors.fetch_add(1);
    scopeEntered.store(true, std::memory_order_release);
    while (!scopeRelease.load(std::memory_order_acquire)) std::this_thread::yield();
}
static const char* probeSymbol = "good_value";
static int probeExpected = 17;
/** 构造/析构等待独立只读查询线程；不把需要另一写事务的 dlopen 伪装为普通查询。 */
extern "C" void test_concurrent_probe(void) {
    std::thread probe{[] {
        // 系统 loader 自己可以持有其装载锁；这里只查询已发布的自定义对象，
        // 不把等待系统 dlsym 的应用层环错误归咎于我们的注册锁。
        auto* value = static_cast<int*>(elf_sym_global(probeSymbol));
        assert(value && *value == probeExpected);
        elf_handle_t* preparing = nullptr;
        {
            std::lock_guard<std::recursive_mutex> lock(g_loaderMutex);
            const auto found = g_byPath.find(probePath);
            if (found != g_byPath.end() && !found->second->published) preparing = found->second;
        }
        if (preparing) assert(!elf_sym(preparing, "not_yet_published"));
        ++concurrentProbes;
    }};
    probe.join();
}
static std::string reentrantPath;
static elf_handle_t* reopened = nullptr;
static bool allowReopen = true;
extern "C" void test_fini_reopen(void) {
    test_concurrent_probe();
    if (allowReopen && !reopened) reopened = elf_open(reentrantPath.c_str());
}
extern "C" void test_mark(int value) { marks += value; }
extern "C" void amclLogPrint(AmclLogLevel, unsigned int, const char*, const char*, ...) {}
extern "C" void amclLogWrite(AmclLogLevel, const char*, const char*, ...) {}
FILE* amclIfInet6ShimOpen(const char*, const char*) { return nullptr; }

/** 用已发布库原字节验证兼容分支；改动一个字节后必须拒绝，不依赖库内代码执行。 */
static void check_legacy(const std::string& path) {
    if (path.empty()) return;
    elf_handle_t h{};
    h.name = "libjli.so";
    h.path = path;
    h.fd = open(path.c_str(), O_RDONLY);
    assert(h.fd >= 0);
    auto fn = reinterpret_cast<unsigned char(*)()>(resolve_legacy_jli(&h, "JLI_IsStaticallyLinked"));
    assert(fn && fn() == 0);
    assert(!resolve_legacy_jli(&h, "unrelated_symbol"));
    close(h.fd);
    elf_handle_t other{};
    other.name = "unrelated.so";
    other.path = path;
    assert(!resolve_legacy_jli(&other, "JLI_IsStaticallyLinked"));
}

/** 已发布原件与单字节变异共享同样 ELF 布局，只有完整身份一致才准许历史单符号补充。 */
static void check_legacy_manifest(const std::string& fixtures) {
    std::ifstream paths(fixtures + "/legacy-jli/list.txt");
    if (!paths) return; // 独立 CI 可以只运行源码生成的反例；发行资格必须提供真实历史样本。
    std::string relative;
    size_t checked = 0;
    while (std::getline(paths, relative)) {
        elf_handle_t image{};
        image.fd = -1; image.name = "libjli.so";
        image.path = fixtures + "/legacy-jli/" + relative;
        assert(read_headers(&image, image.path.c_str()) && map_segments(&image) && parse_dynamic(&image));
        const bool mutated = relative.find("-mutated/") != std::string::npos;
        assert((resolve_legacy_manifest(&image, "JLI_ManifestIterate") != nullptr) == !mutated);
        assert(!resolve_legacy_manifest(&image, "JLI_Launch"));
        const bool needsLinkType = relative.find("25-original/") != std::string::npos;
        assert((resolve_legacy_jli(&image, "JLI_IsStaticallyLinked") != nullptr) == needsLinkType);
        cleanup_handle(&image); ++checked;
    }
    assert(checked == 6);
    std::cout << "PASS exact legacy JLI identity: 3 original, 3 one-byte negative controls\n";
}

/** 真实 mapper 的共页反例：第二个段不能清空同页内先前段的字节。 */
static void check_shared_page(const std::string& root) {
    const std::string path = root + "/shared-page-input";
    const int fd = open(path.c_str(), O_CREAT | O_EXCL | O_RDWR, 0600);
    assert(fd >= 0);
    char bytes[512]{};
    memset(bytes, 'A', 128);
    memset(bytes + 256, 'B', 128);
    assert(write(fd, bytes, sizeof(bytes)) == sizeof(bytes));
    Elf64_Phdr headers[2]{};
    for (int i = 0; i < 2; ++i) {
        headers[i].p_type = PT_LOAD;
        headers[i].p_vaddr = headers[i].p_offset = i * 256;
        headers[i].p_filesz = headers[i].p_memsz = 128;
        headers[i].p_flags = i ? PF_R | PF_X : PF_R;
    }
    elf_handle_t image{};
    image.fd = fd; image.mapSize = PAGE_SZ; image.phdr = headers; image.ehdr.e_phnum = 2;
    assert(map_segments(&image));
    assert(!memcmp(image.base, bytes, 128));
    assert(!memcmp(static_cast<char*>(image.base) + 256, bytes + 256, 128));
    assert(protect_segments(&image));
    assert(!memcmp(image.base, bytes, 128));
    munmap(image.base, image.mapSize);
}

/** 每个故障在尚未初始化宿主TLS的独立fork分支执行，不能把继承状态拒绝错算为OOM通过。
 * core的真实malloc/OS观察注入只在初始化时指定，生产加载/descriptor/回滚保持原样。 */
static void check_tls_failures(const std::string& root) {
    const std::string path = root + "/libtls_failure.so";
    const int before = marks;
    assert(!g_tlsStorage && g_tlsRuntimeProcess.load() == 0);
    for (int mode = 0; mode < 5; ++mode) {
        const pid_t child = fork(); assert(child >= 0);
        if (child == 0) {
            const rlimit noCore{0, 0}; setrlimit(RLIMIT_CORE, &noCore);
            amcl::tlsstorage::Functions functions;
            functions.allocate = probe_tls_allocate; functions.observe = probe_tls_observe;
            if (mode == 0) {
                failTlsObserver = true;
                assert(!elf_open(path.c_str()) && strstr(elf_error(), "TLS observer"));
                assert(marks == before && g_loaded.empty());
                failTlsObserver = false;
                auto* retry = elf_open(path.c_str()); assert(retry && marks == before + 1);
                elf_close(retry); assert(g_loaded.empty() && g_tlsStorage->Snapshot().payloads == 0);
                _exit(0);
            }
            assert(ensure_tls_runtime(functions) == 0);
            if (mode < 3) {
                tlsAllocationBudget = mode == 1 ? 0 : 1; // 模板分配，或模板成功后的首arena分配。
                assert(!elf_open(path.c_str()) && strstr(elf_error(), "TLS"));
                const auto stats = g_tlsStorage->Snapshot();
                assert(marks == before && g_loaded.empty() && stats.modules == 0 && stats.payloads == 0);
                _exit(0);
            }
            auto* image = elf_open(path.c_str()); assert(image && marks == before + 1);
            if (mode == 3) tlsAllocationBudget = 0; else failTlsObservation = true;
            pthread_t thread;
            const int created = pthread_create(&thread, nullptr, [](void* data) -> void* {
                tlsdesc_resolve_helper(static_cast<tlsdesc_data*>(data));
                _exit(99); // 旧错误偏移返回会到这里；修复必须先 SIGABRT。
            }, image->tlsDescriptors.front().get());
            if (created != 0) _exit(98);
            pthread_join(thread, nullptr); _exit(97);
        }
        int status = 0;
        assert(waitpid(child, &status, 0) == child);
        if (mode < 3) assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
        else assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
    }
    auto* image = elf_open(path.c_str());
    assert(image && image->tlsDescriptors.size() == 1 && marks == before + 1);
    auto address = reinterpret_cast<int*(*)()>(elf_sym(image, "tls_address"));
    assert(address && *address() == 37);
    assert(elf_dlclose(image) == 0 && g_loaded.empty());
    assert(g_tlsStorage->Snapshot().payloads == 0); // 无测试侧free/key delete，生产Retire完成回收。
    marks = before;
    std::cout << "PASS TLS observer retry/template/arena rollback and 2 runtime non-return failures\n";
}

/** 真系统 C++ 队列尚有回调时 close 不执行 fini；fini 新建 TLS 也不能被立即 unmap。 */
static void check_thread_destructor_ownership(const std::string& root) {
    ThreadDestructorRecord inherited{[](void*) { _exit(99); }, nullptr, getpid(), {nullptr, nullptr}, 0};
    const pid_t forked = fork(); assert(forked >= 0);
    if (forked == 0) run_thread_destructor(&inherited);
    int inheritedStatus = 0;
    assert(waitpid(forked, &inheritedStatus, 0) == forked && WIFEXITED(inheritedStatus) && WEXITSTATUS(inheritedStatus) == 127);
    const std::string path = root + "/libthread_destructor.so";
    const int before = marks;
    auto* image = elf_open(path.c_str());
    assert(image && marks == before + 1);
    auto touch = reinterpret_cast<int(*)()>(elf_sym(image, "touch_thread_tls"));
    assert(touch);
    std::atomic<bool> ready{false}, leave{false};
    std::thread worker([&] {
        assert(touch() == 37);
        ready.store(true, std::memory_order_release);
        while (!leave.load(std::memory_order_acquire)) std::this_thread::yield();
    });
    while (!ready.load(std::memory_order_acquire)) std::this_thread::yield();
    assert(image->threadDestructorReferences == 1 && elf_dlclose(image) == 0);
    assert(g_loaded.size() == 1 && marks == before + 1); // 析构对象还活着，静态 fini 不能提前发生。
    leave.store(true, std::memory_order_release); worker.join();
    assert(g_loaded.empty() && marks == before + 111);
    assert(g_tlsStorage->Snapshot().payloads == 0);

    std::thread late([&] {
        auto* current = elf_open(path.c_str()); assert(current);
        auto enable = reinterpret_cast<void(*)()>(elf_sym(current, "enable_late_tls")); assert(enable); enable();
        assert(elf_dlclose(current) == 0);
        assert(current->finalized && current->threadDestructorReferences == 1 && g_loaded.size() == 1);
    });
    late.join();
    assert(g_loaded.empty() && marks == before + 222); // fini和对象析构分别恰好一次。
    assert(g_tlsStorage->Snapshot().payloads == 0);
    marks = before;
    std::cout << "PASS real C++ TLS queue pins custom DSO and handles TLS first created by fini\n";
}

/** 查询缺失库不能执行构造；查询成功仍拥有独立引用。显式NODELETE仅在隔离进程
 * 检验，以免该正确的进程期根干扰其他测试对普通模块完整回收的断言。
 */
static void check_open_lifetime_flags(const std::string& root) {
    void* system = ::dlopen((root + "/system-only/libscope_shadow.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    assert(system);
    void* existingSystem = elf_dlopen("libscope_shadow.so", RTLD_NOW | RTLD_NOLOAD);
    assert(existingSystem == system && g_loaded.empty());
    assert(elf_dlclose(existingSystem) == 0 && ::dlclose(system) == 0);
    const auto path = root + "/libgood.so";
    const int before = marks;
    assert(!elf_dlopen(path.c_str(), RTLD_NOW | RTLD_NOLOAD));
    assert(marks == before && g_loaded.empty() && strstr(elf_error(), "RTLD_NOLOAD"));
    auto* first = elf_dlopen(path.c_str(), RTLD_NOW);
    assert(first && marks == before + 1);
    auto* second = elf_dlopen("libgood.so", RTLD_NOW | RTLD_NOLOAD);
    assert(second == first && marks == before + 1);
    assert(elf_dlclose(first) == 0 && marks == before + 1);
    assert(*static_cast<int*>(elf_dlsym(second, "good_value")) == 17);
    assert(elf_dlclose(second) == 0 && marks == before + 1001 && g_loaded.empty());
    assert(!elf_dlopen(path.c_str(), RTLD_NOW | RTLD_NOLOAD) && g_loaded.empty());
    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        const int prior = marks;
        auto* persistent = elf_dlopen(path.c_str(), RTLD_NOW | RTLD_NODELETE);
        assert(persistent && marks == prior + 1);
        auto* value = static_cast<int*>(elf_dlsym(persistent, "good_value"));
        assert(value && *value == 17); *value = 29;
        assert(elf_dlclose(persistent) == 0 && marks == prior + 1 && *value == 29);
        auto* again = elf_dlopen(path.c_str(), RTLD_NOW | RTLD_NOLOAD);
        assert(again == persistent && *static_cast<int*>(elf_dlsym(again, "good_value")) == 29);
        assert(elf_dlclose(again) == 0 && marks == prior + 1);
        _exit(0);
    }
    int status = -1;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    assert(g_loaded.empty());
    std::cout << "PASS real RTLD_NOLOAD absence/reference and explicit NODELETE state preservation\n";
}

/** 第二线程进入 open 后，ctor 保持门关闭；只允许一个完整对象完成并返回两份独立引用。 */
static void check_concurrent_initialization(const std::string& root) {
    const std::string path = root + "/libscope_wait.so";
    std::atomic<bool> secondEntered{false}, secondDone{false};
    elf_handle_t *first = nullptr, *second = nullptr;
    std::thread a([&] { first = elf_open(path.c_str()); });
    while (!scopeEntered.load(std::memory_order_acquire)) std::this_thread::yield();
    std::thread b([&] {
        secondEntered.store(true, std::memory_order_release);
        second = elf_open(path.c_str());
        secondDone.store(true, std::memory_order_release);
    });
    while (!secondEntered.load(std::memory_order_acquire)) std::this_thread::yield();
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    assert(!secondDone.load(std::memory_order_acquire));
    scopeRelease.store(true, std::memory_order_release);
    a.join(); b.join();
    assert(first && first == second && scopeConstructors.load() == 1 && first->openReferences == 2);
    assert(*static_cast<int*>(elf_sym(second, "scope_initialized")) == 123);
    elf_close(first); elf_close(second);
    assert(g_loaded.empty());
    std::cout << "PASS concurrent same-object open waits for one complete initialization\n";
}

/** 和 glibc 对照共享真实 DSO，验证 LOCAL/GLOBAL、依赖 BFS 及原调用者 NEXT 的边界。 */
static void check_lookup_scopes(const std::string& root) {
    auto open = [&](const char* name, int flags) {
        void* result = elf_dlopen((root + "/" + name).c_str(), flags);
        if (!result) std::cerr << "scope open " << name << ": " << elf_error() << '\n';
        assert(result); return result;
    };
    void* top = open("libscope_root.so", RTLD_NOW | RTLD_LOCAL);
    int* chosen = static_cast<int*>(elf_dlsym(top, "scope_choice"));
    assert(chosen && *chosen == 42);
    assert(reinterpret_cast<int(*)()>(elf_dlsym(top, "root_relocated_choice"))() == 42);
    assert(!elf_sym_global("scope_choice"));
    elf_dlclose(top);
    void* local = open("libscope_local.so", RTLD_NOW | RTLD_LOCAL);
    assert(!elf_dlsym(RTLD_DEFAULT, "scope_local"));
    assert(!elf_dlopen((root + "/libscope_consumer.so").c_str(), RTLD_NOW | RTLD_LOCAL));
    void* promoted = open("libscope_local.so", RTLD_NOW | RTLD_NOLOAD | RTLD_GLOBAL);
    assert(promoted == local && elf_dlsym(RTLD_DEFAULT, "scope_local"));
    void* process = elf_dlopen(nullptr, RTLD_NOW);
    assert(process && elf_dlsym(process, "scope_local"));
    elf_dlclose(process);
    void* consumer = open("libscope_consumer.so", RTLD_NOW | RTLD_LOCAL);
    assert(reinterpret_cast<int(*)()>(elf_dlsym(consumer, "read_scope_local"))() == 91);
    elf_dlclose(consumer); elf_dlclose(promoted); elf_dlclose(local);
    void* wrapper = open("libscope_next.so", RTLD_NOW | RTLD_GLOBAL);
    void* later = open("libscope_later.so", RTLD_NOW | RTLD_GLOBAL);
    assert(reinterpret_cast<int(*)()>(elf_dlsym(wrapper, "read_next_marker"))() == -1);
    elf_dlclose(later); elf_dlclose(wrapper);
    wrapper = open("libscope_next_dependency.so", RTLD_NOW | RTLD_GLOBAL);
    assert(reinterpret_cast<int(*)()>(elf_dlsym(wrapper, "read_next_marker"))() == 2);
    elf_dlclose(wrapper);
    void* dynamicGlobal = open("libscope_dynamic_global.so", RTLD_NOW | RTLD_LOCAL);
    assert(!elf_dlsym(RTLD_DEFAULT, "scope_dynamic_global"));
    elf_dlclose(dynamicGlobal);
    const pid_t child = fork(); assert(child >= 0);
    if (child == 0) {
        void* keep = open("libscope_dynamic_nodelete.so", RTLD_NOW | RTLD_LOCAL);
        *static_cast<int*>(elf_dlsym(keep, "scope_dynamic_nodelete")) = 76;
        assert(elf_dlclose(keep) == 0);
        void* again = open("libscope_dynamic_nodelete.so", RTLD_NOW | RTLD_NOLOAD);
        assert(*static_cast<int*>(elf_dlsym(again, "scope_dynamic_nodelete")) == 76);
        assert(elf_dlclose(again) == 0);
        _exit(0);
    }
    int status; assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    assert(g_loaded.empty() && g_globalScope.empty());
    std::cout << "PASS custom lookup scopes: dependency BFS, LOCAL/GLOBAL promotion, caller NEXT and dynamic NODELETE\n";
}

/** 原始同一 DSO 图在 glibc 对照中为 42/7/13；这里把其中 B/D 交给真实系统 loader。 */
static void check_mixed_lookup(const std::string& root) {
    for (const auto& row : {std::pair<const char*, int>{"libmixed_root.so", 42},
            {"libmixed_root_deep.so", 7}, {"libmixed_root_own.so", 13}}) {
        auto* image = static_cast<elf_handle_t*>(elf_dlopen((root + "/" + row.first).c_str(), RTLD_NOW | RTLD_LOCAL));
        if (!image) std::cerr << "mixed open: " << elf_error() << '\n';
        assert(image);
        auto* value = static_cast<int*>(elf_sym(image, "mixed_choice"));
        assert(value && *value == row.second);
        assert(reinterpret_cast<int(*)()>(elf_sym(image, "mixed_relocated_choice"))() == row.second);
        elf_close(image);
        assert(g_loaded.empty());
        void* leaked = ::dlopen("libmixed_left.so", RTLD_NOW | RTLD_NOLOAD);
        assert(!leaked);
    }
    std::cout << "PASS mixed custom/system dependency BFS: sibling=42, system-grandchild=7, system-own=13\n";
    // 两个 owner 的原生依赖下标不同；第一个关闭后，第二个必须靠自己已取得的引用维持
    // 复制的只读表与子依赖，不能依赖旧 owner 的地址/数组或新增永久 native 保活。
    auto* cachedOwner = static_cast<elf_handle_t*>(elf_dlopen((root + "/libmixed_root_shared.so").c_str(), RTLD_NOW | RTLD_LOCAL));
    assert(cachedOwner);
    auto* copiedOwner = static_cast<elf_handle_t*>(elf_dlopen((root + "/libmixed_root_deep.so").c_str(), RTLD_NOW | RTLD_LOCAL));
    assert(copiedOwner);
    elf_close(cachedOwner);
    assert(!is_elf_handle(cachedOwner));
    assert(*static_cast<int*>(elf_sym(copiedOwner, "mixed_choice")) == 7);
    assert(reinterpret_cast<int(*)()>(elf_sym(copiedOwner, "mixed_relocated_choice"))() == 7);
    elf_close(copiedOwner);
    assert(g_loaded.empty());
    assert(!::dlopen("libmixed_leaf.so", RTLD_NOW | RTLD_NOLOAD));
    std::cout << "PASS reused native metadata has independent owner indices and releases with the last real owner\n";
    for (bool closeDuring : {false, true}) {
        resolverCalls = resolverFinishes = 0;
        closeInsideResolver = closeDuring;
        resolverOwner = static_cast<elf_handle_t*>(elf_dlopen((root + "/libmixed_ifunc_user.so").c_str(), RTLD_NOW | RTLD_LOCAL));
        assert(resolverOwner);
        void* address = elf_sym(resolverOwner, "mixed_ifunc");
        assert(address && resolverCalls == 1);
        if (!closeDuring) {
            assert(reinterpret_cast<int(*)()>(address)() == 73);
            elf_close(resolverOwner);
        } // resolver 已主动关闭最后 handle；地址归属已经结束，此分支不能再执行返回的代码。
        assert(g_loaded.empty() && resolverFinishes == 1);
        resolverOwner = nullptr;
    }
    closeInsideResolver = false;
    std::cout << "PASS real system IFUNC joins custom query and closes its owner only after lookup returns\n";
    resolverFinishes = 0;
    auto* provider = static_cast<elf_handle_t*>(elf_dlopen((root + "/libmixed_ifunc_user.so").c_str(), RTLD_NOW | RTLD_GLOBAL));
    assert(provider);
    auto* bound = static_cast<elf_handle_t*>(elf_dlopen((root + "/libmixed_global_consumer.so").c_str(), RTLD_NOW | RTLD_LOCAL));
    assert(bound);
    elf_close(provider);
    assert(is_elf_handle(provider) && resolverFinishes == 0);
    assert(reinterpret_cast<int(*)()>(elf_sym(bound, "mixed_bound_anchor"))() == 8);
    elf_close(bound);
    assert(g_loaded.empty() && g_globalScope.empty() && resolverFinishes == 1);
    std::cout << "PASS GLOBAL native definition binding retains actual owning custom image\n";
    resolverCalls = resolverFinishes = 0;
    closeInsideResolver = true;
    resolverOwner = static_cast<elf_handle_t*>(elf_dlopen((root + "/libmixed_ifunc_user.so").c_str(), RTLD_NOW | RTLD_GLOBAL));
    assert(resolverOwner);
    auto* resolvedConsumer = static_cast<elf_handle_t*>(elf_dlopen((root + "/libmixed_resolver_consumer.so").c_str(), RTLD_NOW | RTLD_LOCAL));
    assert(resolvedConsumer && resolverCalls == 1 && resolverFinishes == 0 && is_elf_handle(resolverOwner));
    assert(reinterpret_cast<int(*)()>(elf_sym(resolvedConsumer, "mixed_bound_ifunc"))() == 73);
    elf_close(resolvedConsumer);
    resolverOwner = nullptr; closeInsideResolver = false;
    assert(g_loaded.empty() && g_globalScope.empty() && resolverFinishes == 1);
    std::cout << "PASS IFUNC binding retains provider before resolver-triggered last-close collection\n";
}

/** 每个实际 C++ 分配点失败一次，覆盖原生元数据描述/附加 NOLOAD 引用/混合 scope 队列。
 * 第一轮不触发失败的成功预算界定本次真实分配序列，不能只测试较早 80 个旧分配点。 */
static void check_mixed_allocation_rollback(const std::string& root) {
    const std::string path = root + "/libmixed_root.so";
    size_t failures = 0;
    bool reachedSuccess = false;
    for (int position = 0; position < 1024; ++position) {
        allocationBudget = position;
        auto* image = static_cast<elf_handle_t*>(elf_dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL));
        const bool injected = allocationBudget.load() < 0;
        allocationBudget = -1;
        if (image) {
            elf_close(image);
            reachedSuccess = !injected;
        } else { assert(injected && elf_error()[0]); ++failures; }
        assert(g_loaded.empty() && g_byPath.empty() && g_byName.empty() && g_globalScope.empty());
        for (const char* name : {"libmixed_left.so", "libmixed_leaf.so"}) {
            void* leaked = ::dlopen(name, RTLD_NOW | RTLD_NOLOAD);
            assert(!leaked);
        }
        if (reachedSuccess) break;
    }
    assert(reachedSuccess && failures > 61);
    std::cout << "PASS mixed system metadata/scope allocation rollback: " << failures << " injected failures\n";
}

/** 应用NOLOAD不可达的依赖仍由公开root真实持有；重复glibc对照图以防退回子树抢先。
 * 另外核对TLS按线程、隐藏定义、IFUNC重入关owner和同basename二映像归属，原生dlsym不替换。
 */
static void check_private_namespace(const std::string& root) {
    hidePrivateLeaf = true;
    check_mixed_lookup(root);
    for (bool closeDuring : {false, true}) {
        resolverCalls = resolverFinishes = 0; closeInsideResolver = closeDuring;
        resolverOwner = static_cast<elf_handle_t*>(elf_dlopen((root + "/libmixed_root_deep.so").c_str(), RTLD_NOW | RTLD_LOCAL));
        assert(resolverOwner);
        auto* tls = static_cast<int*>(elf_sym(resolverOwner, "mixed_private_tls"));
        assert(tls && *tls == 57);
        std::thread second([] {
            auto* other = static_cast<int*>(elf_sym(resolverOwner, "mixed_private_tls"));
            assert(other && *other == 57); *other = 93;
        });
        second.join(); assert(*tls == 57);
        assert(!elf_sym(resolverOwner, "mixed_private_hidden"));
        void* implementation = elf_sym(resolverOwner, "mixed_private_ifunc");
        assert(implementation && resolverCalls == 1);
        if (!closeDuring) {
            assert(reinterpret_cast<int(*)()>(implementation)() == 73);
            elf_close(resolverOwner);
        }
        resolverOwner = nullptr;
        assert(g_loaded.empty() && g_globalScope.empty());
        assert(!::dlopen("libmixed_leaf.so", RTLD_NOW | RTLD_NOLOAD));
    }
    closeInsideResolver = false;
    // 同名而非同映像：先保持正确root，再加载另一份相同SONAME；native地址证据必须选对。
    void* nativeRoot = ::dlopen("libmixed_left.so", RTLD_NOW | RTLD_LOCAL);
    assert(nativeRoot);
    void* unrelated = ::dlopen((root + "/duplicate-private/libmixed_leaf.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    assert(unrelated);
    auto* image = static_cast<elf_handle_t*>(elf_dlopen((root + "/libmixed_root_deep.so").c_str(), RTLD_NOW | RTLD_LOCAL));
    assert(image);
    assert(*static_cast<int*>(elf_sym(image, "mixed_choice")) == 7);
    elf_close(image); assert(g_loaded.empty());
    assert(::dlclose(unrelated) == 0 && ::dlclose(nativeRoot) == 0);
    assert(!::dlopen("libmixed_leaf.so", RTLD_NOW | RTLD_NOLOAD));
    check_mixed_allocation_rollback(root);
    hidePrivateLeaf = false;
    std::cout << "PASS private namespace PHDR/native authorization: BFS, per-thread TLS, hidden symbol, IFUNC lifetime, same-name identity, rollback\n";
}

/** 在隔离子进程降权，对 root 创建的 memfd 触发真实 EPERM、对 /root 路径触发 EACCES。
 * 不依赖 Windows bind mount 的合成模式位，也不把宿主故障注入冒充真实内核权限拒绝。 */
static void check_permission_errors(const std::string& root) {
    auto* image = static_cast<elf_handle_t*>(elf_dlopen((root + "/libmixed_permission.so").c_str(), RTLD_NOW | RTLD_LOCAL));
    assert(image);
    auto pathCall = reinterpret_cast<int(*)(const char*, int*)>(elf_sym(image, "permission_path"));
    auto fdCall = reinterpret_cast<int(*)(int, int*)>(elf_sym(image, "permission_fd"));
    auto atCall = reinterpret_cast<int(*)(int, const char*, int*)>(elf_sym(image, "permission_at"));
    assert(pathCall && fdCall && atCall);
    for (const char* name : {"chmod", "fchmod", "fchmodat"}) assert(elf_sym_global(name) == ::dlsym(RTLD_DEFAULT, name));
    const int fd = syscall(SYS_memfd_create, "amcl-permission-reference", 0);
    assert(fd >= 0 && geteuid() == 0);
    int error = -1;
    assert(fdCall(fd, &error) == 0 && error == 0);
    const std::string path = "/proc/self/fd/" + std::to_string(fd);
    struct stat rootStatus{};
    assert(stat("/root", &rootStatus) == 0 && rootStatus.st_uid == 0 && (rootStatus.st_mode & 7) == 0);
    const pid_t child = fork(); assert(child >= 0);
    if (child == 0) {
        assert(setgid(65534) == 0 && setuid(65534) == 0);
        assert(pathCall(path.c_str(), &error) == -1 && error == EPERM);
        assert(fdCall(fd, &error) == -1 && error == EPERM);
        assert(atCall(AT_FDCWD, path.c_str(), &error) == -1 && error == EPERM);
        assert(pathCall("/root/amcl-permission-reference", &error) == -1 && error == EACCES);
        assert(atCall(AT_FDCWD, "/root/amcl-permission-reference", &error) == -1 && error == EACCES);
        _exit(0);
    }
    int status;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    close(fd); elf_close(image);
    assert(g_loaded.empty());
    std::cout << "PASS real chmod/fchmod/fchmodat success, EPERM and EACCES survive production relocation\n";
}

/**
 * 复现 HotSpot 先查询可选 JNI_OnLoad_*、再系统装载库的顺序。失败信息必须属于最后一次
 * 真正失败的 dlopen，且只消费一次；日志输出不能先取走系统错误。使用真实 glibc 装载器，
 * 不模拟错误字符串，也不放宽生产库选择或命名空间规则。
 */
static void check_system_open_error_delivery() {
    while (elf_dlerror()) {}
    assert(!elf_dlsym(nullptr, "amcl_missing_optional_jni_probe"));
    const char* missing = "/amcl-test-missing/system-library.so";
    assert(!elf_dlopen(missing, RTLD_NOW));
    const char* error = elf_dlerror();
    assert(error && strstr(error, missing));
    assert(!strstr(error, "amcl_missing_optional_jni_probe"));
    assert(!elf_dlerror());
    // 没有此前的自定义错误时，也必须保住系统 dlopen 的真实报错。
    assert(!elf_dlopen(missing, RTLD_NOW));
    error = elf_dlerror();
    assert(error && strstr(error, missing) && !elf_dlerror());
    // 系统 NOLOAD 的“没有该对象”可能不提供 dlerror 详情，必须产出本次查询的可读
    // 原因；不能重新返回旧的可选 JNI 探测，也不能为查询加载该不存在文件。
    assert(!elf_dlsym(nullptr, "amcl_missing_optional_noload_probe"));
    assert(!elf_dlopen(missing, RTLD_NOW | RTLD_NOLOAD));
    error = elf_dlerror();
    assert(error && strstr(error, missing) && !strstr(error, "amcl_missing_optional_noload_probe"));
    assert(!elf_dlerror());
    // 成功的系统装载保持真实句柄和 close 协议，不制造新的失败状态。
    void* library = elf_dlopen("libm.so.6", RTLD_NOW);
    assert(library && !elf_dlerror());
    assert(elf_dlclose(library) == 0);
    std::cout << "PASS real system dlopen latest failure replaces optional symbol probe; error consumed once\n";
}

int main(int argc, char** argv) {
    std::cout.setf(std::ios::unitbuf); // 即使死锁由外部超时终止，也保留已经完成的阶段证据。
    assert(argc >= 2);
    if (strcmp(argv[1], "--system-errors-only") == 0) {
        check_system_open_error_delivery();
        return 0;
    }
    check_system_open_error_delivery();
    const std::string root = argv[1];
    if (const char* fixtures = getenv("AMCL_ELF_FIXTURES")) {
        std::ifstream paths(std::string(fixtures) + "/list.txt");
        std::string relative;
        size_t inspected = 0;
        while (std::getline(paths, relative)) {
            if (!relative.empty() && relative.back() == '\r') relative.pop_back();
            auto* image = new elf_handle_t{};
            image->fd = -1;
            image->path = std::string(fixtures) + "/" + relative;
            image->name = relative;
            if (!read_headers(image, image->path.c_str()) || !map_segments(image) ||
                !parse_dynamic(image) || !protect_segments(image)) {
                std::cerr << "Actual candidate rejected: " << relative << ": " << elf_error() << "\n";
                abort();
            }
            cleanup_handle(image); delete image; ++inspected;
        }
        assert(inspected > 0);
        std::cout << "PASS actual candidate mapping/metadata/protection: " << inspected
                  << " ELF files; no candidate code executed\n";
        check_legacy_manifest(fixtures);
    }
    check_shared_page(root);
    elf_set_search_path(root.c_str());
    check_open_lifetime_flags(root);
    check_concurrent_initialization(root);
    check_lookup_scopes(root);
    check_mixed_lookup(root);
    check_mixed_allocation_rollback(root);
    check_private_namespace(root);
    check_permission_errors(root);
    check_tls_failures(root);
    check_thread_destructor_ownership(root);
    const std::string allocationPath = root + "/libgood.so";
    size_t allocationFailures = 0;
    for (int position = 0; position < 80; ++position) {
        const int before = marks;
        allocationBudget = position;
        auto* image = elf_open(allocationPath.c_str());
        allocationBudget = -1;
        if (image) {
            assert(marks == before + 1);
            elf_close(image);
        } else {
            assert(marks == before && elf_error()[0] && !g_loadBatch);
            ++allocationFailures;
        }
        assert(g_loaded.empty() && g_byPath.empty() && g_byName.empty());
    }
    assert(allocationFailures >= 12);
    marks = 0;
    std::cout << "PASS allocation failure rollback: " << allocationFailures << " injected failures\n";
    // 所有样本必须在构造器之前拒绝；每个失败后的注册表仍应为空。
    std::ifstream malformed(root + "/bad-dynamic-cases.txt");
    std::string caseName;
    int malformedCount = 0;
    while (std::getline(malformed, caseName)) {
        assert(!elf_open((root + "/libbad-dynamic-" + caseName + ".so").c_str()));
        assert(strstr(elf_error(), caseName == "init-target" ? "invalid init/fini target" : "invalid dynamic metadata"));
        assert(marks == 0 && g_loaded.empty());
        ++malformedCount;
    }
    assert(malformedCount == 22);
    auto* visibility = elf_open((root + "/libvisibility.so").c_str());
    assert(visibility && !elf_sym(visibility, "local_only") && !elf_sym(visibility, "missing_platform_function"));
    bool foundZero = false;
    assert(!resolve_global("absolute_zero", &foundZero) && foundZero);
    assert(reinterpret_cast<uintptr_t>(elf_sym(visibility, "absolute_number")) == 123);
    // 旧版全局 .symtab 兜底会错误命中 missing_platform_function，令下方损坏库进入构造。
    for (const auto& item : {std::pair<const char*, int>{"binding", 31}, {"protected", 5}, {"symbolic", 5}}) {
        auto* binding = elf_open((root + "/lib" + item.first + ".so").c_str());
        assert(binding);
        assert(reinterpret_cast<int(*)()>(elf_sym(binding, "read_collision"))() == item.second);
        assert(reinterpret_cast<long(*)()>(elf_sym(binding, "read_absolute"))() == 7);
        elf_close(binding);
    }
    for (int n = 0; n < 2; ++n) {
        assert(!elf_open((root + "/libmissing.so").c_str()));
        assert(strstr(elf_error(), "missing_platform_function"));
        assert(marks == 0);
        assert(!elf_sym_global("bad_export"));
    }
    assert(!elf_open((root + "/libparent.so").c_str()));
    assert(marks == 0); // 依赖 good 已链接但构造尚未执行。
    assert(!elf_sym_global("good_value"));
    auto* bindingOwner = elf_open((root + "/libbinding.so").c_str());
    assert(bindingOwner);
    elf_close(visibility); // 仅由重定位绑定保持，没有 DT_NEEDED 也必须存活。
    assert(reinterpret_cast<int(*)()>(elf_sym(bindingOwner, "read_collision"))() == 31);
    elf_close(bindingOwner);
    assert(!elf_sym_global("collision_value"));
    failProtection = true;
    assert(!elf_open((root + "/libgood.so").c_str()));
    assert(strstr(elf_error(), "mprotect final pages"));
    assert(marks == 0 && !elf_sym_global("good_value"));
    failProtection = false;
    auto* good = elf_open((root + "/libgood.so").c_str());
    assert(good && marks == 1);
    assert(*static_cast<int*>(elf_sym(good, "good_value")) == 17);
    for (int kind : {1024, 1028, 1029, 1030, 1032, 4095}) {
        assert(!elf_open((root + "/libunsupported-" + std::to_string(kind) + ".so").c_str()));
        assert(strstr(elf_error(), "unsupported"));
        assert(marks == 1);
    }
    auto* weak = elf_open((root + "/libweak.so").c_str());
    assert(weak && reinterpret_cast<int(*)()>(elf_sym(weak, "weak_value"))() == 0);
    assert(reinterpret_cast<long(*)()>(elf_sym(weak, "weak_addend"))() == 5);
    auto* cycle = elf_open((root + "/libcycle_a.so").c_str());
    assert(cycle && marks == 19);
    assert(reinterpret_cast<int(*)()>(elf_sym(cycle, "cycle_sum"))() == 18);
    probePath = root + "/libconcurrent.so";
    auto* concurrent = elf_open(probePath.c_str());
    assert(concurrent && concurrentProbes == 1);
    probeSymbol = "concurrent_value"; probeExpected = 3;
    probePath = root + "/libneeds_system.so";
    auto* system = elf_open(probePath.c_str());
    assert(system && concurrentProbes == 2);
    assert(reinterpret_cast<int(*)()>(elf_sym(system, "read_system_value"))() == 34);
    if (argc > 2) check_legacy(argv[2]);
    const int beforeFini = marks;
    auto* fini = elf_open((root + "/libfini.so").c_str());
    assert(fini && marks == beforeFini);
    auto* finiAgain = elf_open((root + "/libfini.so").c_str());
    assert(finiAgain == fini);
    allocationBudget = 0;
    assert(elf_dlclose(fini) == -1); // 关闭准备失败不能偷偷消费一个 open 引用。
    allocationBudget = -1;
    assert(marks == beforeFini && strstr(elf_error(), "close preparation allocation failed"));
    assert(elf_dlclose(fini) == 0 && marks == beforeFini);
    assert(elf_sym(finiAgain, "finish_library"));
    assert(elf_dlclose(finiAgain) == 0);
    assert(marks == beforeFini + 100);
    auto* firstParent = elf_open((root + "/libdependent.so").c_str());
    auto* secondParent = elf_open((root + "/libdependent_second.so").c_str());
    assert(firstParent && secondParent);
    const int beforeDependencies = marks;
    elf_close(good);
    assert(marks == beforeDependencies);
    elf_close(firstParent);
    assert(marks == beforeDependencies + 2000);
    assert(reinterpret_cast<int(*)()>(elf_sym(secondParent, "dependency_value"))() == 17);
    elf_close(secondParent);
    assert(marks == beforeDependencies + 5000 && !elf_sym_global("good_value"));
    elf_close(cycle);
    assert(!elf_sym_global("cycle_a_value") && !elf_sym_global("cycle_b_value"));
    const int beforeSystem = marks;
    elf_close(system);
    std::cout << "system close delta=" << marks - beforeSystem << " query callbacks=" << concurrentProbes << '\n';
    assert(marks == beforeSystem + 4000 && concurrentProbes == 3);
    elf_close(weak);
    assert(g_loaded.size() == 1 && is_elf_handle(concurrent));
    reentrantPath = root + "/libreentrant_fini.so";
    auto* original = elf_open(reentrantPath.c_str());
    assert(original);
    elf_close(original);
    assert(reopened && reopened != original && *static_cast<int*>(elf_sym(reopened, "reentrant_value")) == 23);
    auto* extraOpen = elf_open(reentrantPath.c_str());
    assert(extraOpen == reopened);
    elf_close(extraOpen);
    allowReopen = false;
    elf_close(reopened);
    elf_close(concurrent);
    assert(g_loaded.empty() && g_byPath.empty() && g_byName.empty());
    assert(elf_dlclose(nullptr) == -1 && elf_dlerror());
    std::cout << "PASS open references, shared/bound dependencies, cycles, system fini and reentrant reopen\n";
    std::cout << "PASS real AArch64 ELF linking, rollback, weak imports and cyclic constructors\n";
}
