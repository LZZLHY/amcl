/**
 * 真实 glibc 对照，不链接/包含生产 loader。证明查找顺序和初始化等待语义；构造器
 * join 另一线程 dlopen 自身的循环在隔离子进程中由 alarm 结束，不能挂死测试服务。
 */
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <dlfcn.h>
#include <signal.h>
#include <string>
#include <sys/wait.h>
#include <thread>
#include <utility>
#include <unistd.h>

static std::atomic<bool> entered{false}, releaseGate{false};
static std::atomic<int> constructors{0};
static bool cyclicJoin = false;
static std::string initializingPath;
static int resolverCalls = 0, resolverFinishes = 0;
extern "C" void scope_resolver_probe() { ++resolverCalls; }
extern "C" void scope_resolver_finalized() { ++resolverFinishes; }
extern "C" void scope_initialization_gate() {
    constructors.fetch_add(1);
    entered.store(true, std::memory_order_release);
    if (cyclicJoin) {
        std::thread child([] { dlopen(initializingPath.c_str(), RTLD_NOW | RTLD_LOCAL); });
        child.join();
    } else {
        while (!releaseGate.load(std::memory_order_acquire)) std::this_thread::yield();
    }
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    assert(argc == 2);
    const std::string root(argv[1]);
    auto open = [&](const char* name, int flags) {
        void* result = dlopen((root + "/" + name).c_str(), flags);
        if (!result) std::fprintf(stderr, "%s\n", dlerror());
        assert(result); return result;
    };
    // 系统子库 B -> D 与同层 C、较深 C -> E -> F 交错，不能把 B 的整棵子树当一个节点。
    for (const auto& row : {std::pair<const char*, int>{"libmixed_root.so", 42},
            {"libmixed_root_deep.so", 7}, {"libmixed_root_own.so", 13}}) {
        void* mixed = open(row.first, RTLD_NOW | RTLD_LOCAL);
        assert(*static_cast<int*>(dlsym(mixed, "mixed_choice")) == row.second);
        assert(reinterpret_cast<int(*)()>(dlsym(mixed, "mixed_relocated_choice"))() == row.second);
        dlclose(mixed);
        std::printf("REFERENCE mixedBfs %s=%d\n", row.first, row.second);
    }
    void* resolverUser = open("libmixed_ifunc_user.so", RTLD_NOW | RTLD_LOCAL);
    assert(reinterpret_cast<int(*)()>(dlsym(resolverUser, "mixed_ifunc"))() == 73 && resolverCalls == 1);
    dlclose(resolverUser);
    assert(resolverFinishes == 1);
    std::puts("REFERENCE systemIfuncResolverAndFini=1");
    void* top = open("libscope_root.so", RTLD_NOW | RTLD_LOCAL);
    int* chosen = static_cast<int*>(dlsym(top, "scope_choice"));
    assert(chosen && *chosen == 42); // root -> left/right -> leaf，right 在 leaf 之前。
    assert(reinterpret_cast<int(*)()>(dlsym(top, "root_relocated_choice"))() == 42);
    std::puts("REFERENCE handleBfs=42");
    dlclose(top);
    void* local = open("libscope_local.so", RTLD_NOW | RTLD_LOCAL);
    assert(dlsym(RTLD_DEFAULT, "scope_local") == nullptr);
    void* hiddenConsumer = dlopen((root + "/libscope_consumer.so").c_str(), RTLD_NOW | RTLD_LOCAL);
    assert(!hiddenConsumer);
    void* promoted = open("libscope_local.so", RTLD_NOW | RTLD_NOLOAD | RTLD_GLOBAL);
    assert(promoted == local && dlsym(RTLD_DEFAULT, "scope_local"));
    void* consumer = open("libscope_consumer.so", RTLD_NOW | RTLD_LOCAL);
    assert(reinterpret_cast<int(*)()>(dlsym(consumer, "read_scope_local"))() == 91);
    dlclose(consumer); dlclose(promoted); dlclose(local);
    std::puts("REFERENCE localIsolation=1 globalPromotion=1");
    void* wrapper = open("libscope_next.so", RTLD_NOW | RTLD_GLOBAL);
    void* later = open("libscope_later.so", RTLD_NOW | RTLD_GLOBAL);
    const int unrelatedNext = reinterpret_cast<int(*)()>(dlsym(wrapper, "read_next_marker"))();
    std::printf("REFERENCE nextUnrelatedLaterGlobal=%d\n", unrelatedNext);
    dlclose(later); dlclose(wrapper);
    wrapper = open("libscope_next_dependency.so", RTLD_NOW | RTLD_GLOBAL);
    assert(reinterpret_cast<int(*)()>(dlsym(wrapper, "read_next_marker"))() == 2);
    dlclose(wrapper);
    std::puts("REFERENCE nextCallerOrder=2");
    void* flagsGlobal = open("libscope_dynamic_global.so", RTLD_NOW | RTLD_LOCAL);
    std::printf("REFERENCE dynamicFlagGlobalVisible=%d\n", dlsym(RTLD_DEFAULT, "scope_dynamic_global") != nullptr);
    dlclose(flagsGlobal);
    void* persistent = open("libscope_dynamic_nodelete.so", RTLD_NOW | RTLD_LOCAL);
    *static_cast<int*>(dlsym(persistent, "scope_dynamic_nodelete")) = 76;
    dlclose(persistent);
    void* retained = open("libscope_dynamic_nodelete.so", RTLD_NOW | RTLD_NOLOAD);
    assert(*static_cast<int*>(dlsym(retained, "scope_dynamic_nodelete")) == 76);
    dlclose(retained);
    std::puts("REFERENCE dynamicFlagNodeleteRetainsState=1");
    initializingPath = root + "/libscope_wait.so";
    std::atomic<bool> secondEntered{false}, secondDone{false};
    void *first = nullptr, *second = nullptr;
    std::thread a([&] { first = dlopen(initializingPath.c_str(), RTLD_NOW | RTLD_LOCAL); });
    while (!entered.load(std::memory_order_acquire)) std::this_thread::yield();
    std::thread b([&] {
        secondEntered.store(true, std::memory_order_release);
        second = dlopen(initializingPath.c_str(), RTLD_NOW | RTLD_LOCAL);
        secondDone.store(true, std::memory_order_release);
    });
    while (!secondEntered.load(std::memory_order_acquire)) std::this_thread::yield();
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    assert(!secondDone.load(std::memory_order_acquire));
    releaseGate.store(true, std::memory_order_release);
    a.join(); b.join();
    assert(first && first == second && constructors.load() == 1);
    dlclose(second); dlclose(first);
    std::puts("REFERENCE concurrentSameObjectWaits=1 constructors=1");
    const pid_t child = fork(); assert(child >= 0);
    if (child == 0) {
        cyclicJoin = true;
        alarm(1);
        dlopen(initializingPath.c_str(), RTLD_NOW | RTLD_LOCAL);
        _exit(77); // 若实际成功，不能把正常返回误判成参考死锁。
    }
    int status; assert(waitpid(child, &status, 0) == child);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGALRM);
    std::puts("REFERENCE ctorJoinThreadOpeningSelf=blocked-until-alarm");
}
