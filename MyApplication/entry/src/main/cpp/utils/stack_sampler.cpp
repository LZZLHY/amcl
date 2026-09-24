// stack_sampler.cpp — 渲染线程 native 栈采样器实现
// 见 stack_sampler.h 的设计说明。

#include "stack_sampler.h"

#include <hilog/log.h>
#include "jvm/jni.h"
#include "jvm/jvmti.h"
#include <atomic>
#include <thread>
#include <chrono>
#include <vector>
#include <string>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <csignal>
#include <ctime>
#include <cerrno>
#include <unistd.h>
#include <dlfcn.h>
#include <semaphore.h>
#include <sys/syscall.h>
#include <ucontext.h>

#undef LOG_TAG
#define LOG_TAG "AMCL_SMPL"

// libglfw.so 里 glfwOHOS_GetLastSwapTimeMs() 返回最后一次 swap 的时间戳（ms，
// 与本文件 nowMs() 同一时钟：steady_clock epoch）。用于判断渲染线程是否"停滞"。
extern "C" long long glfwOHOS_GetLastSwapTimeMs(void);

// ============================================================
//  AsyncGetCallTrace（ASGCT）—— HotSpot 内部异步取栈 API（async-profiler 同款）。
//  给定信号 ucontext，返回当前线程的 Java 调用栈（jmethodID + bci）。
//  结构体未在 jvmti.h 中声明，按 HotSpot 稳定 ABI 自行声明。
// ============================================================
typedef struct {
    jint lineno;          // 实为 bci（bytecode index）
    jmethodID method_id;
} ASGCT_CallFrame;
typedef struct {
    JNIEnv* env_id;
    jint num_frames;      // >0 帧数；<=0 为错误码（ticks_*）
    ASGCT_CallFrame* frames;
} ASGCT_CallTrace;
typedef void (*ASGCT_fn)(ASGCT_CallTrace*, jint, void*);

namespace {

// ============================================================
//  可调参数
// ============================================================
// 采样间隔（sampler 线程多久醒一次检查是否停滞）
//
// 2026-08-03 调低：原值 250 / 800 / 1000 是为「黑屏级」停滞（数秒不出帧）设的，
// 抓不到本轮要查的偶发卡顿 —— 真机实测渲染线程连续不出帧的段落为 p99 约 110 ms、
// 最长 513 ms，全部低于原来的 800 ms 判据，采样器一次都不会触发。
// 这些常量只在 -DAMCL_STACK_SAMPLER=ON 的诊断构建里起作用（生产构建整个采样器是空操作），
// 所以调低不影响发布版。正常出帧时（16~33 ms 一帧）仍然完全静默。
//
// 2026-08-07 再调低，理由是量出来的，不是猜的。MG 侧的每秒计数器把一帧的成本拆开之后，
// 82 fps 段与 21 fps 段的差额是这样分布的（单位：每帧毫秒）：
//     未记账（渲染线程 Java / 被抢占）  7.8 -> 32    +24
//     应用自己等 GPU 栅栏               3.9 -> 9.7   +5.8
//     MG 的 glCopyBufferSubData        0.45 -> 5.8  +5.3
// 也就是说帧率是被那 24 ms 决定的，而那 24 ms 恰好是 MG 的计数器看不见的部分。要知道它在哪，
// 只能给渲染线程做 profile —— 这也正是 docs/ohos/archive 里那句话说的：
//   "before either: profile the render thread. Every round in this area that started from a
//    mechanism instead of a profile has been wrong."
// 而用户报的抽帧是单帧 40~100 ms 的尖峰，150 ms 的判据一次都不会触发，50 ms 的唤醒间隔也
// 会因为相位而整段漏掉。所以：
//   判据 60 ms   —— 低于最小的尖峰。代价是在 21 fps 的窗口里（一帧 47 ms）也会偶尔触发，
//                   那不是误报，那些本来就是慢帧，正是要看的东西。
//   间隔 8 ms    —— 检测延迟上限 8 ms，一个 60 ms 的停滞至少被醒来 7 次看到。
//   限流 100 ms  —— 连续的慢帧各能采到一发，又不会把 hilog 冲掉。
// 三个值都只在诊断构建里存在。若要改，改这里重新构建即可（约一分钟），不做 env 旋钮是刻意的：
// 少一处可能设错的地方。
constexpr int kSampleIntervalMs = 8;
// 停滞判据：距上次出帧超过该毫秒数即视为"渲染线程卡住/空转"
constexpr long long kStuckThresholdMs = 60;
// 停滞时每隔多久真正打印一次完整 backtrace（限流，避免刷屏）
constexpr long long kEmitIntervalMs = 100;
// 单次回溯最多记录的帧数
constexpr int kMaxFrames = 48;
// 帧指针链合理跨度上限（防止把野指针当 fp 一路狂读）
constexpr uintptr_t kMaxStackSpan = 8ull * 1024 * 1024; // 8MB

// 采样信号：选用接近 SIGRTMAX 的实时信号，规避 HotSpot（SIGRTMIN+x 区间的
// suspend/resume）与 OHOS DFX（SIGDUMP=35 / SIGLEAK_STACK=42）。
// 处理器内会校验 tid == 目标渲染线程 且 g_expecting，非本采样请求则转交旧 handler。
int g_sampleSignal = 0; // 在 start() 里解析为 SIGRTMAX-3

// ============================================================
//  采样共享状态
// ============================================================
std::atomic<int> g_renderTid{0};
std::atomic<bool> g_running{false};
std::atomic<bool> g_started{false};

// 信号处理器与 sampler 线程之间的一次性交接
volatile sig_atomic_t g_expecting = 0;     // sampler 置 1 后才接受采样
volatile int g_expectTid = 0;              // 本次采样的目标 tid
uintptr_t g_frames[kMaxFrames];            // 处理器写、sampler 读
volatile int g_frameCount = 0;
sem_t g_sampleDone;                        // 处理器采完后 post
struct sigaction g_oldAction;              // 链式转交用

// ASGCT / JVMTI 句柄（懒解析）。
ASGCT_fn g_asgct = nullptr;
JavaVM* g_jvm = nullptr;
jvmtiEnv* g_jvmti = nullptr;
JNIEnv* g_renderEnv = nullptr;             // 渲染线程的 JNIEnv（在渲染线程上捕获）

// ---- JVMTI GetStackTrace 兜底 --------------------------------------------------------------
//
// 为什么需要兜底：2026-08-07 的会话里 ASGCT 对 **全部 254 次** 采样都返回 -1
// （ticks_no_Java_frame），Java 栈一帧都没拿到，于是渲染线程停滞里最大的未解释部分（26% 的
// 停滞样本栈里连一个 libglfw 帧都没有）到现在还没有名字。env_id 的捕获逻辑是对的
// （在绑定线程上 GetEnv，见 amcl_sampler_set_render_tid），所以原因在这个自建 aarch64 JDK 的
// ASGCT 实现里，而本仓库没有它的源码 —— 继续推理就是猜。
//
// 换成有文档保证的路：JVMTI GetStackTrace。
//   - 不需要 async-signal-safe，因为它在 sampler 线程上调用，不在信号处理器里。
//   - 阻塞在 native 里的线程对 safepoint 是安全的，Java 栈可以从 last-Java-frame 锚点走出来，
//     而这正是我们要采的状态（渲染线程卡在驱动的系统调用里）。
//   - 代价是它可能需要一次 handshake。限流后每秒最多 10 次，诊断构建可以接受；
//     但这也是为什么它只在 ASGCT 失败时才用，而不是无条件替换。
//
// jthread 是一个 jobject，必须在渲染线程上取全局引用（GetCurrentThread 返回的是局部引用）。
jobject g_renderThreadRef = nullptr;       // 渲染线程的 jthread 全局引用
std::atomic<bool> g_samplerAttached{false}; // sampler 线程是否已 attach 到 JVM
constexpr int kMaxJvmtiFrames = 80;
jvmtiFrameInfo g_jvmtiFrames[kMaxJvmtiFrames];
std::atomic<bool> g_jvmSymsTried{false};

// libentry.so 注入的函数指针（OHOS 命名空间隔离导致 libglfw 无法 dlopen/dlsym
// libentry，改由 libentry 在初始化时把这些指针推进来，见 glfwOHOS_samplerSetJvmHooks）。
typedef int   (*elf_dladdr_fn)(const void*, Dl_info*);
typedef void* (*elf_sym_global_fn)(const char*);
typedef void* (*get_jvm_fn)();
elf_dladdr_fn g_elfDladdr = nullptr;
elf_sym_global_fn g_elfSymGlobal = nullptr;
get_jvm_fn g_getJvm = nullptr;

// ASGCT 输出缓冲（处理器写、sampler 读）。
constexpr int kMaxJavaFrames = 80;
ASGCT_CallFrame g_javaFrames[kMaxJavaFrames];
volatile int g_javaNumFrames = 0;          // >0 帧数；<=0 错误码

inline long long nowMs() {
    auto now = std::chrono::steady_clock::now();
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               now.time_since_epoch()).count();
}

inline int sysGettid() { return (int)syscall(SYS_gettid); }

inline int sysTgkill(int tgid, int tid, int sig) {
    return (int)syscall(SYS_tgkill, tgid, tid, sig);
}

// 从进程内共享的 libc 环境变量读取 libentry 注入的函数指针。
// OHOS 命名空间隔离导致 libglfw 可能有两份 copy（libentry 依赖的 / LWJGL dlopen 的），
// 各自 globals 不共享；但整个进程单一 libc → 经 setenv/getenv 传指针可跨 copy。
// 见 napi_entry.cpp 的 AMCL_SMPL_HOOKS 设置。
void tryLoadHooksFromEnv() {
    if (g_getJvm && g_elfSymGlobal && g_elfDladdr) return;
    const char* s = getenv("AMCL_SMPL_HOOKS");
    if (!s || !*s) return;
    unsigned long a = 0, b = 0, c = 0;
    if (sscanf(s, "%lx:%lx:%lx", &a, &b, &c) == 3) {
        if (!g_elfDladdr)     g_elfDladdr     = reinterpret_cast<elf_dladdr_fn>(static_cast<uintptr_t>(a));
        if (!g_elfSymGlobal)  g_elfSymGlobal  = reinterpret_cast<elf_sym_global_fn>(static_cast<uintptr_t>(b));
        if (!g_getJvm)        g_getJvm        = reinterpret_cast<get_jvm_fn>(static_cast<uintptr_t>(c));
        OH_LOG_INFO(LOG_APP, "sampler: hooks loaded from env (elf_dladdr=%{public}s elf_sym_global=%{public}s getJavaVM=%{public}s)",
                    g_elfDladdr ? "ok" : "NULL", g_elfSymGlobal ? "ok" : "NULL", g_getJvm ? "ok" : "NULL");
    }
}

// 解析 ASGCT / JavaVM / JVMTI（在渲染线程上调用，可安全用 GetEnv）。
// 依赖 libentry.so 经 glfwOHOS_samplerSetJvmHooks 注入的函数指针（OHOS 命名空间
// 隔离使 libglfw 无法直接 dlsym libentry 的导出符号）。
void resolveJvmSyms() {
    bool expected = false;
    if (!g_jvmSymsTried.compare_exchange_strong(expected, true)) return;

    tryLoadHooksFromEnv();
    if (!g_getJvm || !g_elfSymGlobal) {
        OH_LOG_WARN(LOG_APP, "sampler: JVM hooks not injected yet (getJvm=%{public}s elfSymGlobal=%{public}s)",
                    g_getJvm ? "ok" : "NULL", g_elfSymGlobal ? "ok" : "NULL");
        g_jvmSymsTried.store(false); // 允许后续重试（等钩子注入后）
        return;
    }

    // JavaVM*
    g_jvm = reinterpret_cast<JavaVM*>(g_getJvm());

    // AsyncGetCallTrace（经 elf_sym_global 在 ELF-loaded 的 libjvm 里找）
    g_asgct = reinterpret_cast<ASGCT_fn>(g_elfSymGlobal("AsyncGetCallTrace"));

    // JVMTI env（用于把 jmethodID 解析成类名/方法名）
    if (g_jvm) {
        void* p = nullptr;
        if (g_jvm->GetEnv(&p, JVMTI_VERSION_1_2) == JNI_OK) {
            g_jvmti = reinterpret_cast<jvmtiEnv*>(p);
        }
    }
    OH_LOG_INFO(LOG_APP,
        "sampler: JVM syms — asgct=%{public}s jvmti=%{public}s",
        g_asgct ? "ok" : "NULL", g_jvmti ? "ok" : "NULL");
}

// ============================================================
//  信号处理器：从 ucontext 取 PC，走 x29(FP) 链取各帧返回地址。
//  全程只读栈内存 + 边界检查，不调用 dladdr / malloc / _Unwind_*，
//  async-signal-safe。
// ============================================================
void sampleSignalHandler(int sig, siginfo_t* info, void* ucv) {
    // 非本采样请求（信号被别的子系统复用，或打到了非目标线程）→ 转交旧 handler。
    if (!g_expecting || sysGettid() != g_expectTid) {
        if (g_oldAction.sa_flags & SA_SIGINFO) {
            if (g_oldAction.sa_sigaction) g_oldAction.sa_sigaction(sig, info, ucv);
        } else {
            if (g_oldAction.sa_handler != SIG_IGN &&
                g_oldAction.sa_handler != SIG_DFL &&
                g_oldAction.sa_handler != nullptr) {
                g_oldAction.sa_handler(sig);
            }
        }
        return;
    }

    int n = 0;
    auto* uc = static_cast<ucontext_t*>(ucv);
#if defined(__aarch64__)
    const mcontext_t& mc = uc->uc_mcontext;
    uintptr_t pc = (uintptr_t)mc.pc;
    uintptr_t fp = (uintptr_t)mc.regs[29]; // x29 frame pointer
    uintptr_t lr = (uintptr_t)mc.regs[30]; // x30 link register
    uintptr_t sp = (uintptr_t)mc.sp;

    if (pc) g_frames[n++] = pc;
    // 叶子帧的返回地址在 LR（尚未压栈），先记一笔（去重：与 pc 不同才记）。
    if (lr && lr != pc && n < kMaxFrames) g_frames[n++] = lr;

    // 栈向低地址增长：合法 fp 必须 >= sp 且在 sp+kMaxStackSpan 内、16 字节对齐。
    uintptr_t lo = sp;
    uintptr_t hi = sp + kMaxStackSpan;
    uintptr_t cur = fp;
    while (n < kMaxFrames && cur >= lo && cur < hi && (cur & 0xF) == 0) {
        uintptr_t next = *reinterpret_cast<uintptr_t*>(cur);      // [fp]   = 上一帧 fp
        uintptr_t ret  = *reinterpret_cast<uintptr_t*>(cur + 8);  // [fp+8] = 返回地址
        if (ret) g_frames[n++] = ret;
        if (next <= cur) break;        // fp 必须单调递增，否则停止（防环/野指针）
        cur = next;
    }
#else
    // 仅 arm64 设备目标；其它架构只记 PC（理论上不会走到）。
    (void)uc;
#endif

    g_frameCount = n;

    // ASGCT：取 Java 调用栈（jmethodID + bci）。在信号处理器中按 ucontext 解析，
    // async-signal-safe（async-profiler 同款用法）。结果存全局，sampler 线程解析名字。
    g_javaNumFrames = 0;
    if (g_asgct) {
        ASGCT_CallTrace tr;
        tr.env_id = g_renderEnv;
        tr.frames = g_javaFrames;
        tr.num_frames = 0;
        g_asgct(&tr, kMaxJavaFrames, ucv);
#if defined(__aarch64__)
        // 栈顶可能落在无 safepoint 的计数循环里（无 PcDesc）→ ASGCT 无法解码栈顶帧、
        // 整体返回错误码（<=0）。此时用【调用者帧】（call site，必有 PcDesc）合成一个
        // ucontext 副本重试：跳过不可解码的叶子，从调用链上一层开始解，仍能拿到递归方法名。
        // 关键：合成在副本上做，绝不改真实 uc（内核 sigreturn 会用它恢复线程）。
        if (tr.num_frames <= 0 && fp >= sp && fp < sp + kMaxStackSpan && (fp & 0xF) == 0) {
            uintptr_t cfp = *reinterpret_cast<uintptr_t*>(fp);
            uintptr_t cpc = *reinterpret_cast<uintptr_t*>(fp + 8);
            if (cpc && cfp > fp && cfp < sp + kMaxStackSpan) {
                ucontext_t copy = *uc;
                copy.uc_mcontext.pc = cpc;
                copy.uc_mcontext.sp = fp + 16;
                copy.uc_mcontext.regs[29] = cfp;
                tr.num_frames = 0;
                g_asgct(&tr, kMaxJavaFrames, &copy);
            }
        }
#endif
        g_javaNumFrames = tr.num_frames;
    }

    sem_post(&g_sampleDone); // async-signal-safe
}

// 安装信号处理器（仅一次）。
bool installHandler() {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = sampleSignalHandler;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    if (sigaction(g_sampleSignal, &sa, &g_oldAction) != 0) {
        OH_LOG_ERROR(LOG_APP, "sampler: sigaction(%{public}d) failed: %{public}s",
                     g_sampleSignal, strerror(errno));
        return false;
    }
    return true;
}

// ============================================================
//  符号化辅助（在 sampler 线程执行，可安全用 dladdr / 读文件）
// ============================================================

// elf_dladdr：libentry.so 注入（自定义 ELF loader 的 dladdr 兼容），能解析
// ELF loader 匿名映射加载的 libjvm.so 等 JDK 库；普通 dladdr 对这些区域无效。
elf_dladdr_fn resolveElfDladdr() {
    static bool logged = false;
    if (!g_elfDladdr) tryLoadHooksFromEnv();
    if (!logged && g_elfDladdr) {
        logged = true;
        OH_LOG_INFO(LOG_APP, "sampler: elf_dladdr injected (JVM frames symbolizable)");
    }
    return g_elfDladdr;
}

struct MapEntry {
    uintptr_t start = 0;
    uintptr_t end = 0;
    uintptr_t fileOff = 0;
    char perms[8] = {0};
    std::string path; // 可能为空（匿名映射）
};

std::vector<MapEntry> g_maps;

void reloadMaps() {
    g_maps.clear();
    FILE* f = fopen("/proc/self/maps", "re");
    if (!f) return;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        MapEntry e;
        unsigned long start = 0, end = 0, off = 0;
        char perms[8] = {0};
        char pathBuf[400] = {0};
        // 格式: start-end perms offset dev inode pathname
        int n = sscanf(line, "%lx-%lx %7s %lx %*s %*s %399[^\n]",
                       &start, &end, perms, &off, pathBuf);
        if (n >= 4) {
            e.start = start; e.end = end; e.fileOff = off;
            strncpy(e.perms, perms, sizeof(e.perms) - 1);
            // 去掉 pathname 前导空格
            char* p = pathBuf;
            while (*p == ' ') p++;
            e.path = p;
            g_maps.push_back(e);
        }
    }
    fclose(f);
}

const MapEntry* findMap(uintptr_t pc) {
    for (const auto& e : g_maps) {
        if (pc >= e.start && pc < e.end) return &e;
    }
    return nullptr;
}

// 对一帧地址做符号化并打印。
// 优先 elf_dladdr（覆盖 libjvm 等 ELF-loaded 库），再 /proc/self/maps 标注区域。
void emitFrame(int idx, uintptr_t pc) {
    Dl_info di;
    memset(&di, 0, sizeof(di));
    bool resolved = false;
    elf_dladdr_fn ef = resolveElfDladdr();
    if (ef && ef(reinterpret_cast<void*>(pc), &di) && di.dli_fname) {
        resolved = true;
    } else {
        memset(&di, 0, sizeof(di));
        if (dladdr(reinterpret_cast<void*>(pc), &di) && di.dli_fname) {
            resolved = true;
        }
    }

    if (resolved) {
        const char* path = di.dli_fname;
        const char* base = strrchr(path, '/');
        const char* so = base ? base + 1 : path;
        uintptr_t loadBase = reinterpret_cast<uintptr_t>(di.dli_fbase);
        uintptr_t off = (pc >= loadBase) ? (pc - loadBase) : 0; // 喂 addr2line -e <so>
        if (di.dli_sname) {
            uintptr_t symBase = reinterpret_cast<uintptr_t>(di.dli_saddr);
            uintptr_t symOff = (pc >= symBase) ? (pc - symBase) : 0;
            OH_LOG_INFO(LOG_APP,
                "  #%{public}02d  %{public}s+0x%{public}lx  (%{public}s+0x%{public}lx)  pc=0x%{public}lx",
                idx, so, (unsigned long)off, di.dli_sname, (unsigned long)symOff, (unsigned long)pc);
        } else {
            OH_LOG_INFO(LOG_APP,
                "  #%{public}02d  %{public}s+0x%{public}lx  (no symbol)  pc=0x%{public}lx",
                idx, so, (unsigned long)off, (unsigned long)pc);
        }
        return;
    }

    // 未解析：用 maps 区域信息标注（区分 JIT 代码缓存 vs 匿名映射的 libjvm 等）。
    const MapEntry* m = findMap(pc);
    if (m) {
        uintptr_t regionOff = pc - m->start;
        const char* path = m->path.empty() ? "[anon]" : m->path.c_str();
        const char* base = strrchr(path, '/');
        const char* name = base ? base + 1 : path;
        OH_LOG_INFO(LOG_APP,
            "  #%{public}02d  %{public}s [%{public}s] region+0x%{public}lx (fileoff 0x%{public}lx)  pc=0x%{public}lx",
            idx, name, m->perms, (unsigned long)regionOff, (unsigned long)(m->fileOff + regionOff),
            (unsigned long)pc);
    } else {
        OH_LOG_INFO(LOG_APP, "  #%{public}02d  ??? (no map)  pc=0x%{public}lx", idx, (unsigned long)pc);
    }
}

// 把一个 jmethodID 解析成 类名 方法名签名 并打印一行。ASGCT 与 JVMTI 两条路共用。
void emitOneJavaFrame(int i, jmethodID m, jint bci, const char* prefix) {
    if (!m) { OH_LOG_INFO(LOG_APP, "  %{public}s#%{public}02d  <null method>", prefix, i); return; }
    char* name = nullptr; char* sig = nullptr; char* gen = nullptr;
    char* csig = nullptr; char* cgen = nullptr;
    jclass cls = nullptr;
    const char* mName = "?";
    const char* mSig = "";
    const char* clsName = "?";
    if (g_jvmti->GetMethodName(m, &name, &sig, &gen) == JVMTI_ERROR_NONE) {
        mName = name ? name : "?";
        mSig = sig ? sig : "";
    }
    if (g_jvmti->GetMethodDeclaringClass(m, &cls) == JVMTI_ERROR_NONE && cls) {
        if (g_jvmti->GetClassSignature(cls, &csig, &cgen) == JVMTI_ERROR_NONE && csig) {
            clsName = csig;
        }
    }
    OH_LOG_INFO(LOG_APP, "  %{public}s#%{public}02d  %{public}s %{public}s%{public}s  bci=%{public}d",
                prefix, i, clsName, mName, mSig, bci);
    if (name) g_jvmti->Deallocate(reinterpret_cast<unsigned char*>(name));
    if (sig) g_jvmti->Deallocate(reinterpret_cast<unsigned char*>(sig));
    if (gen) g_jvmti->Deallocate(reinterpret_cast<unsigned char*>(gen));
    if (csig) g_jvmti->Deallocate(reinterpret_cast<unsigned char*>(csig));
    if (cgen) g_jvmti->Deallocate(reinterpret_cast<unsigned char*>(cgen));
}

// ASGCT 失败时的兜底：用 JVMTI GetStackTrace 直接向 VM 要渲染线程的 Java 栈。
// 在 sampler 线程上调用，不在信号处理器里，所以不受 async-signal-safe 约束。
// 前置条件由 amcl_sampler_start / amcl_sampler_set_render_tid 建立：sampler 线程已 attach，
// 渲染线程的 jthread 全局引用已取到。
void emitJavaStackViaJvmti() {
    if (!g_jvmti || !g_renderThreadRef) {
        OH_LOG_INFO(LOG_APP, "  ---- JVMTI fallback unavailable (jvmti=%{public}s ref=%{public}s) ----",
                    g_jvmti ? "ok" : "NULL", g_renderThreadRef ? "ok" : "NULL");
        return;
    }
    jint count = 0;
    const jvmtiError err =
        g_jvmti->GetStackTrace(static_cast<jthread>(g_renderThreadRef), 0, kMaxJvmtiFrames,
                               g_jvmtiFrames, &count);
    if (err != JVMTI_ERROR_NONE) {
        // 错误码原样打出来，不做解释 —— 猜错误码的含义正是这一整轮要避免的事。
        OH_LOG_INFO(LOG_APP, "  ---- JVMTI GetStackTrace failed, error=%{public}d ----", (int)err);
        return;
    }
    OH_LOG_INFO(LOG_APP, "  ---- Java frames (JVMTI, %{public}d) ----", count);
    for (jint i = 0; i < count && i < kMaxJvmtiFrames; i++) {
        emitOneJavaFrame((int)i, g_jvmtiFrames[i].method, (jint)g_jvmtiFrames[i].location, "V");
    }
}

// 把 ASGCT 取到的 Java 帧（jmethodID + bci）解析为 类名.方法名 并打印。
// 在 sampler 线程执行，可安全调用 JVMTI。
void emitJavaStack() {
    int num = g_javaNumFrames;
    if (num > 0 && g_jvmti) {
        OH_LOG_INFO(LOG_APP, "  ---- Java frames (ASGCT, %{public}d) ----", num);
        if (num > kMaxJavaFrames) num = kMaxJavaFrames;
        for (int i = 0; i < num; i++) {
            jmethodID m = g_javaFrames[i].method_id;
            jint bci = g_javaFrames[i].lineno;
            if (!m) { OH_LOG_INFO(LOG_APP, "  J#%{public}02d  <null method>", i); continue; }
            char* name = nullptr; char* sig = nullptr; char* gen = nullptr;
            char* csig = nullptr; char* cgen = nullptr;
            jclass cls = nullptr;
            const char* clsName = "?";
            const char* mName = "?";
            const char* mSig = "";
            if (g_jvmti->GetMethodName(m, &name, &sig, &gen) == JVMTI_ERROR_NONE) {
                mName = name ? name : "?";
                mSig = sig ? sig : "";
            }
            if (g_jvmti->GetMethodDeclaringClass(m, &cls) == JVMTI_ERROR_NONE && cls) {
                if (g_jvmti->GetClassSignature(cls, &csig, &cgen) == JVMTI_ERROR_NONE && csig) {
                    clsName = csig;
                }
            }
            OH_LOG_INFO(LOG_APP, "  J#%{public}02d  %{public}s %{public}s%{public}s  bci=%{public}d",
                        i, clsName, mName, mSig, bci);
            if (name) g_jvmti->Deallocate(reinterpret_cast<unsigned char*>(name));
            if (sig) g_jvmti->Deallocate(reinterpret_cast<unsigned char*>(sig));
            if (gen) g_jvmti->Deallocate(reinterpret_cast<unsigned char*>(gen));
            if (csig) g_jvmti->Deallocate(reinterpret_cast<unsigned char*>(csig));
            if (cgen) g_jvmti->Deallocate(reinterpret_cast<unsigned char*>(cgen));
        }
    } else if (num <= 0) {
        // ASGCT 错误码：-1 ticks_no_Java_frame, -2 ticks_no_class_load, -5 ticks_not_walkable_Java ...
        OH_LOG_INFO(LOG_APP, "  ---- Java frames: ASGCT returned %{public}d (no Java stack) ----", num);
        emitJavaStackViaJvmti();
    }
}

// 触发一次采样并打印 backtrace。返回是否成功取到栈。
bool captureAndEmit(int tid, long long stuckMs) {
    g_frameCount = 0;
    g_expectTid = tid;
    g_expecting = 1;

    int tgid = getpid();
    if (sysTgkill(tgid, tid, g_sampleSignal) != 0) {
        g_expecting = 0;
        // ESRCH：线程已不存在（窗口已退出）→ 清空 renderTid，安静停采。
        if (errno == ESRCH) {
            OH_LOG_INFO(LOG_APP, "sampler: render tid %{public}d gone (ESRCH), clearing", tid);
            g_renderTid.store(0);
        } else {
            OH_LOG_WARN(LOG_APP, "sampler: tgkill(%{public}d) failed: %{public}s",
                        tid, strerror(errno));
        }
        return false;
    }

    // 等处理器采完（最多 500ms）。
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_nsec += 500L * 1000 * 1000;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec += 1; ts.tv_nsec -= 1000000000L; }
    int rc = sem_timedwait(&g_sampleDone, &ts);
    g_expecting = 0;
    if (rc != 0) {
        OH_LOG_WARN(LOG_APP, "sampler: sem_timedwait timeout/err for tid %{public}d", tid);
        return false;
    }

    int count = g_frameCount;
    reloadMaps(); // 刷新映射表（JIT 代码缓存会动态增长）
    OH_LOG_INFO(LOG_APP,
        "==== RENDER THREAD SPIN backtrace (tid=%{public}d, stalled %{public}lldms, %{public}d frames) ====",
        tid, stuckMs, count);
    for (int i = 0; i < count; i++) {
        emitFrame(i, g_frames[i]);
    }
    emitJavaStack();
    OH_LOG_INFO(LOG_APP, "==== end backtrace (tid=%{public}d) ====", tid);
    return true;
}

void samplerLoop() {
    OH_LOG_INFO(LOG_APP, "sampler: loop started (signal=%{public}d, interval=%{public}dms, stuck>%{public}lldms)",
                g_sampleSignal, kSampleIntervalMs, kStuckThresholdMs);

    // 把 sampler 线程 attach 到 JVM，供 JVMTI GetStackTrace 兜底使用。
    // AsDaemon 是关键：非 daemon 的 attach 会让 JVM 在退出时等这个线程，游戏就关不掉了。
    // 失败不致命 —— 只是失去兜底，native 栈照旧可用。
    if (g_jvm && !g_samplerAttached.load()) {
        JNIEnv* env = nullptr;
        const jint rc = g_jvm->AttachCurrentThreadAsDaemon(reinterpret_cast<void**>(&env), nullptr);
        g_samplerAttached.store(rc == JNI_OK);
        OH_LOG_INFO(LOG_APP, "sampler: AttachCurrentThreadAsDaemon rc=%{public}d (JVMTI fallback %{public}s)",
                    (int)rc, rc == JNI_OK ? "available" : "unavailable");
    }
    long long lastEmitMs = 0;
    long long stuckSinceMs = 0;
    bool wasStuck = false;

    while (g_running.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(kSampleIntervalMs));
        int tid = g_renderTid.load();
        if (tid == 0) { wasStuck = false; continue; }

        long long now = nowMs();
        long long lastSwap = glfwOHOS_GetLastSwapTimeMs();
        // lastSwap==0：渲染线程持有 context 但从未出过帧（"从不渲染"型黑屏）→ 也算停滞。
        long long sinceSwap = (lastSwap > 0) ? (now - lastSwap) : (kStuckThresholdMs + 1);
        bool stuck = sinceSwap >= kStuckThresholdMs;

        if (!stuck) {
            if (wasStuck) {
                OH_LOG_INFO(LOG_APP, "sampler: render thread recovered (frames flowing again)");
            }
            wasStuck = false;
            continue;
        }

        if (!wasStuck) {
            wasStuck = true;
            stuckSinceMs = now;
            lastEmitMs = 0; // 进入停滞立即采一发
            OH_LOG_WARN(LOG_APP, "sampler: render thread STALL detected (no swap for %{public}lldms)", sinceSwap);
        }

        if (now - lastEmitMs >= kEmitIntervalMs) {
            lastEmitMs = now;
            captureAndEmit(tid, now - stuckSinceMs);
        }
    }
    OH_LOG_INFO(LOG_APP, "sampler: loop exited");
}

} // namespace

// ============================================================
//  公开接口
// ============================================================
extern "C" void amcl_sampler_set_render_tid(int tid) {
#ifndef AMCL_STACK_SAMPLER
    (void)tid; return; // 采样器未启用（生产默认）：空操作
#else
    int prev = g_renderTid.exchange(tid);
    if (prev != tid) {
        OH_LOG_INFO(LOG_APP, "sampler: render tid = %{public}d (was %{public}d)", tid, prev);
    }
    // 在渲染线程上解析 ASGCT / JVMTI（一次性，线程无关）。
    resolveJvmSyms();
    // 渲染线程的 JNIEnv 必须【每次】在当前绑定线程上重新捕获：context 可能先在
    // Thread-0（Forge EarlyDisplay）绑定、再转移到真正的 Render thread。本函数运行在
    // 当前绑定线程上，GetEnv 返回的就是该线程（= 即将被采样的 g_renderTid）的 env，
    // 保证 ASGCT 的 env_id 与采样目标线程一致（否则 ASGCT 取错线程返回错误码）。
    if (g_jvm) {
        void* e = nullptr;
        if (g_jvm->GetEnv(&e, JNI_VERSION_1_6) == JNI_OK) {
            g_renderEnv = reinterpret_cast<JNIEnv*>(e);

            // 同时取渲染线程 jthread 的全局引用，供 JVMTI GetStackTrace 兜底使用。
            // 必须在渲染线程上做：GetCurrentThread 返回的是「当前线程」，而本函数正运行在
            // 即将被采样的那个线程上。旧引用先释放 —— context 可能从 Thread-0 转移过来，
            // 那时这里会被再调用一次，漏删就是泄漏一个全局引用。
            if (g_jvmti) {
                jthread self = nullptr;
                if (g_jvmti->GetCurrentThread(&self) == JVMTI_ERROR_NONE && self) {
                    jobject prevRef = g_renderThreadRef;
                    g_renderThreadRef = g_renderEnv->NewGlobalRef(self);
                    if (prevRef) g_renderEnv->DeleteGlobalRef(prevRef);
                    g_renderEnv->DeleteLocalRef(self);
                }
                OH_LOG_INFO(LOG_APP, "sampler: render jthread global ref = %{public}s",
                            g_renderThreadRef ? "ok" : "NULL");
            }
        }
    }
#endif
}

extern "C" void amcl_sampler_start(void) {
#ifndef AMCL_STACK_SAMPLER
    return; // 采样器未启用（生产默认）：不起线程、不装信号处理器，零开销
#else
    bool expected = false;
    if (!g_started.compare_exchange_strong(expected, true)) {
        return; // 已启动
    }
    g_sampleSignal = SIGRTMAX - 3;
    if (sem_init(&g_sampleDone, 0, 0) != 0) {
        OH_LOG_ERROR(LOG_APP, "sampler: sem_init failed: %{public}s", strerror(errno));
        g_started.store(false);
        return;
    }
    if (!installHandler()) {
        g_started.store(false);
        return;
    }
    g_running.store(true);
    std::thread(samplerLoop).detach();
    OH_LOG_INFO(LOG_APP, "sampler: started");
#endif
}

extern "C" void amcl_sampler_stop(void) {
    g_running.store(false);
}

// libentry.so 在初始化时调用，注入它独占可见的函数指针（OHOS 命名空间隔离下
// libglfw 无法 dlopen/dlsym libentry）。三个参数分别是 elf_dladdr / elf_sym_global /
// jvmGetJavaVM 的地址。命名带 glfw 前缀以匹配 version script 的导出规则。
extern "C" void glfwOHOS_samplerSetJvmHooks(void* elfDladdr, void* elfSymGlobal, void* getJavaVM) {
    g_elfDladdr = reinterpret_cast<elf_dladdr_fn>(elfDladdr);
    g_elfSymGlobal = reinterpret_cast<elf_sym_global_fn>(elfSymGlobal);
    g_getJvm = reinterpret_cast<get_jvm_fn>(getJavaVM);
    OH_LOG_INFO(LOG_APP, "sampler: JVM hooks injected (elf_dladdr=%{public}s elf_sym_global=%{public}s getJavaVM=%{public}s)",
                elfDladdr ? "ok" : "NULL", elfSymGlobal ? "ok" : "NULL", getJavaVM ? "ok" : "NULL");
}
