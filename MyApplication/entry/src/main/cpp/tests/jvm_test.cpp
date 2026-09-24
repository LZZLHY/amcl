// jvm_test.cpp — JVM 嵌入可行性探测
// 验证 HarmonyOS NEXT 上运行 JVM 所需的所有系统能力

#include <napi/native_api.h>
#include <hilog/log.h>
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <setjmp.h>
#include <sys/mman.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <sstream>
#include <atomic>

#undef LOG_TAG
#define LOG_TAG "JVM_TEST"

static std::string g_jvmTestResult;

// ==================== 测试1: dlopen/dlsym 动态加载 ====================
struct DlopenTestResult {
    bool canDlopen = false;
    bool canDlsym = false;
    bool canCallFunction = false;
    bool canLoadFuncTable = false;
    std::string detail;
};

static DlopenTestResult TestDlopen(const char* libPath) {
    DlopenTestResult r;
    std::ostringstream ss;

    // 构造 libfakejvm.so 路径
    std::string soPath = std::string(libPath) + "/libfakejvm.so";

    // 尝试 dlopen
    void* handle = dlopen("libfakejvm.so", RTLD_NOW);
    if (!handle) {
        // 尝试绝对路径（应用沙箱内的 .so 可能在 libs 目录）
        handle = dlopen(soPath.c_str(), RTLD_NOW);
    }
    if (!handle) {
        ss << "dlopen FAIL: " << dlerror() << "\n";
        // 尝试从 nativeLibraryDir 加载
        ss << "尝试路径: " << soPath << "\n";
        r.detail = ss.str();
        return r;
    }
    r.canDlopen = true;
    ss << "dlopen OK\n";

    // dlsym 查找函数
    typedef const char* (*GetVersionFunc)();
    GetVersionFunc getVersion = (GetVersionFunc)dlsym(handle, "FakeJVM_GetVersion");
    if (!getVersion) {
        ss << "dlsym(FakeJVM_GetVersion) FAIL: " << dlerror() << "\n";
        dlclose(handle);
        r.detail = ss.str();
        return r;
    }
    r.canDlsym = true;
    ss << "dlsym OK\n";

    // 调用函数
    const char* version = getVersion();
    if (version) {
        r.canCallFunction = true;
        ss << "函数调用 OK: " << version << "\n";
    }

    // 测试 JNI 函数指针表
    typedef void* (*GetJNIFunc)();
    GetJNIFunc getJNI = (GetJNIFunc)dlsym(handle, "FakeJVM_GetJNIInterface");
    if (getJNI) {
        struct FakeJNI {
            int version;
            const char* (*GetVersion)(void);
            const char* (*RunHelloWorld)(void);
            const char* (*GetInfo)(void);
        };
        FakeJNI* jni = (FakeJNI*)getJNI();
        if (jni && jni->RunHelloWorld) {
            const char* hello = jni->RunHelloWorld();
            if (hello) {
                r.canLoadFuncTable = true;
                ss << "JNI 函数表调用 OK: " << hello << "\n";
            }
        }
        if (jni && jni->GetInfo) {
            ss << jni->GetInfo();
        }
    }

    // 测试模拟 JNI_CreateJavaVM
    typedef int (*CreateVMFunc)(void**, void**, void*);
    CreateVMFunc createVM = (CreateVMFunc)dlsym(handle, "FakeJVM_CreateJavaVM");
    if (createVM) {
        void* vm = nullptr;
        void* env = nullptr;
        int ret = createVM(&vm, &env, nullptr);
        ss << "模拟 JNI_CreateJavaVM: ret=" << ret << " vm=" << vm << " env=" << env << "\n";
    }

    dlclose(handle);
    r.detail = ss.str();
    return r;
}

// ==================== 测试2: pthread 线程能力 ====================
struct PthreadTestResult {
    bool canCreateThread = false;
    bool canUseMutex = false;
    bool canUseCond = false;
    bool canUseRWLock = false;
    bool canSetThreadName = false;
    int maxThreadsCreated = 0;
    std::string detail;
};

static std::atomic<int> g_threadCounter{0};

static void* ThreadFunc(void* arg) {
    g_threadCounter++;
    return (void*)(intptr_t)g_threadCounter.load();
}

static PthreadTestResult TestPthread() {
    PthreadTestResult r;
    std::ostringstream ss;

    // 基本线程创建
    pthread_t thread;
    g_threadCounter = 0;
    int ret = pthread_create(&thread, nullptr, ThreadFunc, nullptr);
    if (ret == 0) {
        void* retval;
        pthread_join(thread, &retval);
        r.canCreateThread = true;
        ss << "pthread_create OK (counter=" << g_threadCounter.load() << ")\n";
    } else {
        ss << "pthread_create FAIL: " << strerror(ret) << "\n";
    }

    // Mutex
    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    ret = pthread_mutex_lock(&mutex);
    if (ret == 0) {
        pthread_mutex_unlock(&mutex);
        r.canUseMutex = true;
        ss << "pthread_mutex OK\n";
    } else {
        ss << "pthread_mutex FAIL: " << strerror(ret) << "\n";
    }
    pthread_mutex_destroy(&mutex);

    // Condition variable
    pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
    pthread_mutex_t condMutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&condMutex);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_nsec += 1000000; // 1ms timeout
    if (ts.tv_nsec >= 1000000000) { ts.tv_sec++; ts.tv_nsec -= 1000000000; }
    ret = pthread_cond_timedwait(&cond, &condMutex, &ts);
    pthread_mutex_unlock(&condMutex);
    if (ret == ETIMEDOUT || ret == 0) {
        r.canUseCond = true;
        ss << "pthread_cond OK (timedwait returned " << ret << ")\n";
    } else {
        ss << "pthread_cond FAIL: " << strerror(ret) << "\n";
    }
    pthread_cond_destroy(&cond);
    pthread_mutex_destroy(&condMutex);

    // RWLock
    pthread_rwlock_t rwlock = PTHREAD_RWLOCK_INITIALIZER;
    ret = pthread_rwlock_rdlock(&rwlock);
    if (ret == 0) {
        pthread_rwlock_unlock(&rwlock);
        ret = pthread_rwlock_wrlock(&rwlock);
        if (ret == 0) {
            pthread_rwlock_unlock(&rwlock);
            r.canUseRWLock = true;
            ss << "pthread_rwlock OK\n";
        }
    }
    if (!r.canUseRWLock) ss << "pthread_rwlock FAIL\n";
    pthread_rwlock_destroy(&rwlock);

    // Thread name
    pthread_t self = pthread_self();
    ret = pthread_setname_np(self, "jvm-test");
    if (ret == 0) {
        char name[32] = {0};
        pthread_getname_np(self, name, sizeof(name));
        r.canSetThreadName = true;
        ss << "pthread_setname_np OK: \"" << name << "\"\n";
    } else {
        ss << "pthread_setname_np FAIL: " << strerror(ret) << "\n";
    }

    // 多线程压力测试（JVM 通常创建 10-20 个线程）
    const int MAX_TEST = 32;
    pthread_t threads[MAX_TEST];
    int created = 0;
    for (int i = 0; i < MAX_TEST; i++) {
        ret = pthread_create(&threads[i], nullptr, ThreadFunc, nullptr);
        if (ret != 0) break;
        created++;
    }
    for (int i = 0; i < created; i++) {
        pthread_join(threads[i], nullptr);
    }
    r.maxThreadsCreated = created;
    ss << "多线程: 成功创建 " << created << "/" << MAX_TEST << " 个线程\n";

    r.detail = ss.str();
    return r;
}

// ==================== 测试3: Signal 处理 ====================
struct SignalTestResult {
    bool canInstallHandler = false;
    bool canCatchSIGSEGV = false;
    bool canUseAltStack = false;
    std::string detail;
};

static volatile sig_atomic_t g_signalCaught = 0;
static sigjmp_buf g_jumpBuf;

static void SignalHandler(int sig) {
    g_signalCaught = sig;
    siglongjmp(g_jumpBuf, 1);
}

static SignalTestResult TestSignal() {
    SignalTestResult r;
    std::ostringstream ss;

    // 安装 SIGSEGV handler
    struct sigaction sa = {};
    struct sigaction oldSa = {};
    sa.sa_handler = SignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;

    int ret = sigaction(SIGSEGV, &sa, &oldSa);
    if (ret == 0) {
        r.canInstallHandler = true;
        ss << "sigaction(SIGSEGV) OK\n";
    } else {
        ss << "sigaction(SIGSEGV) FAIL: " << strerror(errno) << "\n";
        r.detail = ss.str();
        return r;
    }

    // 触发 SIGSEGV 并捕获
    g_signalCaught = 0;
    if (sigsetjmp(g_jumpBuf, 1) == 0) {
        // 故意触发 SIGSEGV
        volatile int* badPtr = (volatile int*)0x1;
        (void)*badPtr; // 这会触发 SIGSEGV
    }

    if (g_signalCaught == SIGSEGV) {
        r.canCatchSIGSEGV = true;
        ss << "SIGSEGV 捕获 OK (JVM NullPointerException 机制可用)\n";
    } else {
        ss << "SIGSEGV 捕获 FAIL\n";
    }

    // 恢复原始 handler
    sigaction(SIGSEGV, &oldSa, nullptr);

    // 测试 alternate signal stack
    stack_t altStack;
    altStack.ss_sp = malloc(SIGSTKSZ);
    altStack.ss_size = SIGSTKSZ;
    altStack.ss_flags = 0;

    ret = sigaltstack(&altStack, nullptr);
    if (ret == 0) {
        r.canUseAltStack = true;
        ss << "sigaltstack OK (size=" << SIGSTKSZ << ")\n";
    } else {
        ss << "sigaltstack FAIL: " << strerror(errno) << "\n";
    }

    // 清理 alt stack
    stack_t disableStack;
    disableStack.ss_sp = nullptr;
    disableStack.ss_size = 0;
    disableStack.ss_flags = SS_DISABLE;
    sigaltstack(&disableStack, nullptr);
    free(altStack.ss_sp);

    r.detail = ss.str();
    return r;
}

// ==================== 测试4: 系统信息 ====================
static std::string GetSystemInfo() {
    std::ostringstream ss;

    ss << "页大小: " << sysconf(_SC_PAGESIZE) << " bytes\n";
    ss << "CPU 核心数: " << sysconf(_SC_NPROCESSORS_ONLN) << "\n";
    ss << "物理内存: " << (sysconf(_SC_PHYS_PAGES) * sysconf(_SC_PAGESIZE) / (1024*1024)) << " MB\n";
    ss << "最大打开文件数: " << sysconf(_SC_OPEN_MAX) << "\n";
    ss << "线程栈大小: " << sysconf(_SC_THREAD_STACK_MIN) << " bytes (min)\n";
    ss << "sizeof(void*): " << sizeof(void*) << " (" << (sizeof(void*)*8) << "-bit)\n";
    ss << "sizeof(long): " << sizeof(long) << "\n";
    ss << "sizeof(size_t): " << sizeof(size_t) << "\n";

    // 检查 /proc/self/maps 可读性
    FILE* f = fopen("/proc/self/maps", "r");
    if (f) {
        ss << "/proc/self/maps: 可读\n";
        // 读取前几行
        char line[256];
        int count = 0;
        while (fgets(line, sizeof(line), f) && count < 3) {
            ss << "  " << line;
            count++;
        }
        ss << "  ...\n";
        fclose(f);
    } else {
        ss << "/proc/self/maps: 不可读 (" << strerror(errno) << ")\n";
    }

    return ss.str();
}

// ==================== 测试5: mmap 高级特性 ====================
static std::string TestMmapAdvanced() {
    std::ostringstream ss;
    size_t pageSize = sysconf(_SC_PAGESIZE);

    // MAP_ANONYMOUS + PROT_READ|PROT_WRITE (JVM heap)
    void* heap = mmap(nullptr, pageSize * 256, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (heap != MAP_FAILED) {
        memset(heap, 0, pageSize * 256);
        ss << "大块匿名内存 (1MB): OK\n";
        munmap(heap, pageSize * 256);
    } else {
        ss << "大块匿名内存: FAIL (" << strerror(errno) << ")\n";
    }

    // madvise (JVM GC 使用)
    void* mem = mmap(nullptr, pageSize * 4, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem != MAP_FAILED) {
        int ret = madvise(mem, pageSize * 4, MADV_DONTNEED);
        if (ret == 0) {
            ss << "madvise(MADV_DONTNEED): OK (GC 可用)\n";
        } else {
            ss << "madvise(MADV_DONTNEED): FAIL (" << strerror(errno) << ")\n";
        }
        munmap(mem, pageSize * 4);
    }

    // mprotect 切换权限 (JVM safepoint)
    mem = mmap(nullptr, pageSize, PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem != MAP_FAILED) {
        int ret = mprotect(mem, pageSize, PROT_NONE);
        if (ret == 0) {
            mprotect(mem, pageSize, PROT_READ | PROT_WRITE);
            ss << "mprotect(PROT_NONE→RW): OK (safepoint 可用)\n";
        } else {
            ss << "mprotect(PROT_NONE): FAIL (" << strerror(errno) << ")\n";
        }
        munmap(mem, pageSize);
    }

    return ss.str();
}

// ==================== 汇总运行所有测试 ====================
extern "C" {

const char* runJvmFeasibilityTests(const char* appDir) {
    std::ostringstream ss;
    ss << "========================================\n";
    ss << "  JVM 嵌入可行性探测报告\n";
    ss << "========================================\n\n";

    // 系统信息
    ss << "===== 系统信息 =====\n\n";
    ss << GetSystemInfo() << "\n";

    // dlopen 测试
    ss << "===== dlopen/dlsym 测试 =====\n\n";
    auto dlopenResult = TestDlopen(appDir);
    ss << dlopenResult.detail;
    ss << "结论: dlopen=" << (dlopenResult.canDlopen ? "YES" : "NO")
       << " dlsym=" << (dlopenResult.canDlsym ? "YES" : "NO")
       << " 函数调用=" << (dlopenResult.canCallFunction ? "YES" : "NO")
       << " JNI函数表=" << (dlopenResult.canLoadFuncTable ? "YES" : "NO") << "\n\n";

    // pthread 测试
    ss << "===== pthread 线程测试 =====\n\n";
    auto pthreadResult = TestPthread();
    ss << pthreadResult.detail;
    ss << "结论: 线程=" << (pthreadResult.canCreateThread ? "YES" : "NO")
       << " 互斥锁=" << (pthreadResult.canUseMutex ? "YES" : "NO")
       << " 条件变量=" << (pthreadResult.canUseCond ? "YES" : "NO")
       << " 读写锁=" << (pthreadResult.canUseRWLock ? "YES" : "NO")
       << " 最大线程=" << pthreadResult.maxThreadsCreated << "\n\n";

    // Signal 测试
    ss << "===== Signal 信号测试 =====\n\n";
    auto signalResult = TestSignal();
    ss << signalResult.detail;
    ss << "结论: handler=" << (signalResult.canInstallHandler ? "YES" : "NO")
       << " SIGSEGV捕获=" << (signalResult.canCatchSIGSEGV ? "YES" : "NO")
       << " altstack=" << (signalResult.canUseAltStack ? "YES" : "NO") << "\n\n";

    // mmap 高级测试
    ss << "===== mmap 高级特性 =====\n\n";
    ss << TestMmapAdvanced() << "\n";

    // 总结
    ss << "========================================\n";
    ss << "  综合评估\n";
    ss << "========================================\n\n";

    int score = 0;
    int total = 10;

    if (dlopenResult.canDlopen) score++;
    if (dlopenResult.canDlsym) score++;
    if (dlopenResult.canCallFunction) score++;
    if (dlopenResult.canLoadFuncTable) score++;
    if (pthreadResult.canCreateThread) score++;
    if (pthreadResult.canUseMutex && pthreadResult.canUseCond) score++;
    if (pthreadResult.maxThreadsCreated >= 16) score++;
    if (signalResult.canInstallHandler) score++;
    if (signalResult.canCatchSIGSEGV) score++;
    if (signalResult.canUseAltStack) score++;

    ss << "得分: " << score << "/" << total << "\n\n";

    if (score >= 9) {
        ss << "评估: 优秀 — JVM 嵌入完全可行\n";
        ss << "建议: 可以直接尝试嵌入 Alpine musl OpenJDK 17\n";
    } else if (score >= 7) {
        ss << "评估: 良好 — JVM 嵌入基本可行，部分功能可能需要适配\n";
    } else if (score >= 5) {
        ss << "评估: 一般 — JVM 嵌入有风险，需要大量适配工作\n";
    } else {
        ss << "评估: 困难 — JVM 嵌入可能不可行，建议考虑替代方案\n";
    }

    g_jvmTestResult = ss.str();
    return g_jvmTestResult.c_str();
}

} // extern "C"
