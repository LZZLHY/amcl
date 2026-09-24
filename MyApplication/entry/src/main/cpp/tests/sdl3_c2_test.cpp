// sdl3_c2_test.cpp — SDL3 移植 C2 关卡真机探针（在 AMCL 应用进程内运行）
//
// 方案出处：docs/adaptation/SDL3_MIGRATION_PLAN.md §四 C2 / §七 Phase 2 关卡
// 施工记录：docs/adaptation/SDL3_PORT_WORKLOG.md Task#10
//
// ============================================================================
// C2 是什么
// ============================================================================
// MC 26.3 的 com.mojang.renderpearl.backend.opengl.GlBackend.loadLibrary()
// 有一道硬校验（javap 逐条核实，见方案 §二·2.7）：
//
//     String path = ((SharedLibrary) GL.getFunctionProvider()).getPath();  // = libglfw.so
//     if (!SDLVideo.SDL_GL_LoadLibrary(path)) throw ... OPENGL_MISSING;
//     if (GL.getFunctionProvider().getFunctionAddress("glGetError")
//             != SDLVideo.SDL_GL_GetProcAddress("glGetError")) {
//         SDLVideo.SDL_GL_UnloadLibrary();
//         throw new BackendCreationException("glGetError mismatch", OPENGL_MISSING);
//     }
//
// 两边地址不等，OpenGL 后端直接被拒，游戏起不来。LWJGL 的 SharedLibrary 底层就是
// dlopen + dlsym，所以左边等价于 dlsym(dlopen(libglfw.so 绝对路径), "glGetError")。
//
// ============================================================================
// 为什么这个探针必须长在应用进程里，而不是一个命令行可执行文件
// ============================================================================
// 原本编了一个独立的 aarch64 可执行探针（docker/sdl3_c2probe.c），实测行不通：
//
//   HarmonyOS NEXT 5.x 真机（HongMeng Kernel 1.12.0）：
//     - hdc shell 身份 uid=2000(shell)，SELinux 域 u:r:sh:s0
//     - 推到 /data/local/tmp 的文件标签是 u:object_r:data_local_tmp:s0
//     - /data 挂载参数是 rw,nosuid,nodev,noatime…（**没有 noexec**）
//     - chmod +x 确实生效（ls -la 显示 -rwxr-xr-x）
//     - 但执行返回 126 / "Permission denied" ⇒ 是 SELinux 域策略拒绝，不是挂载问题
//   无 root 绕不过。
//
// 更根本的原因：**即便 shell 域能执行，结论也不能迁移到 MC 的运行环境**。
// HarmonyOS 的 linker namespace 是按应用配置的（应用私有 lib 与系统库分属不同
// namespace，dlopen/dlsym 的可见性由系统策略决定）。而 C2 里唯一无法离线推导的
// 变量恰恰就是 namespace 行为——在 shell 域测，测的是另一套 namespace。
//
// ⇒ 探针只有跑在 AMCL 应用进程里才有意义：这里的 namespace、库搜索路径、
//   已加载模块集合，与 MC 启动后完全一致。
//
// ============================================================================
// 离线已经证明到什么程度（所以这里只补最后一环）
// ============================================================================
//  1) libglfw.so 自己 DEFINED 3072 个 gl 前缀、35 个 egl 前缀、2 个 glX 前缀符号，
//     且未定义的 gl / egl 前缀符号均为 0——不依赖任何外部 GL/EGL 符号。
//     SDL_EGL_LoadLibraryOnly 需要的 19 个 egl 符号，19/19 全覆盖。
//  2) libSDL3.so 导出与未定义的 gl / egl 前缀符号都是 0——完全靠 dlopen+dlsym 取。
//  3) SDL_EGL_GetProcAddressInternal() 全文只有三条 if、两个来源：
//         eglGetProcAddress(proc)                     // dlsym(egl_dll_handle)
//         SDL_LoadFunction(opengl_dll_handle, proc)   // dlsym(具体 handle)
//     没有第三条路径，从不使用 RTLD_DEFAULT 或全局符号作用域。
//  4) SDL_LoadObject() = dlopen(sofile, RTLD_NOW | RTLD_LOCAL)
//     SDL_LoadFunction() = dlsym(具体 handle, name)
//  ⇒ 两条来源都指向同一个 libglfw.so handle 的同一个符号；libSDL3.so 的 NEEDED
//    里那个多余的 libGLESv2.so 也就无从干扰。
//
// 剩下的就是 namespace 这一环，本探针实测。
//
// ============================================================================
// 分层与容错
// ============================================================================
// 第 2 层要真的 SDL_Init + eglInitialize，在 NAPI 线程上有崩溃风险。所以每输出
// 一行就即时写 hilog + amcl_log 文件，进程万一挂了，前面的结论已经落盘。
//
// 注意 hilog 输出没有走 AMCL_LOG_I：那个宏的 fmt 里的 %s 没带 {public}，hilog 会
// 打成 <private>。这里把整行预格式化好，再用 %{public}s 输出。
#include "../glfw/glfw_compat.h"
#include "../utils/amcl_log.h"

#include <dlfcn.h>
#include <hilog/log.h>

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sstream>
#include <vector>

#undef LOG_TAG
#define LOG_TAG "SDL3_C2"

namespace {

constexpr unsigned int kSdlInitVideo = 0x00000020u;

// 只用到这几个 SDL 公开符号，全部 dlsym 取，libentry 不在编译期链接 libSDL3.so。
using fn_SDL_Init = bool (*)(unsigned int);
using fn_SDL_Quit = void (*)();
using fn_SDL_SetMainReady = void (*)();
using fn_SDL_GetError = const char *(*)();
using fn_SDL_GL_LoadLibrary = bool (*)(const char *);
using fn_SDL_GL_GetProcAddress = void *(*)(const char *);
using fn_SDL_GL_UnloadLibrary = void (*)();
using fn_SDL_GetCurrentVideoDriver = const char *(*)();
using fn_SDL_GetNumVideoDrivers = int (*)();
using fn_SDL_GetVideoDriver = const char *(*)(int);
using fn_eglGetProcAddress = void *(*)(const char *);

std::string g_report;

// 每行三写：报告字符串 + hilog（%{public}s，否则被打成 <private>）+ amcl_log 文件。
// 即时落盘，第 2 层万一崩溃也不丢前面的结论。
class Reporter {
public:
    void line(const std::string &s) {
        ss_ << s << "\n";
        OH_LOG_INFO(LOG_APP, "[SDL3_C2] %{public}s", s.c_str());
        amclLogWrite(AMCL_LOG_LEVEL_INFO, LOG_TAG, "%s", s.c_str());
    }

    void linef(const char *fmt, ...) {
        char buf[1024];
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        line(buf);
    }

    std::string str() const { return ss_.str(); }

private:
    std::ostringstream ss_;
};

// 从 /proc/self/maps 找已加载模块的绝对路径。
// dladdr 的 dli_fname 有时给的是 SONAME 而不是完整路径，所以用 maps 交叉验证：
// maps 里的路径就是 loader 实际映射的那个文件，也就是 LWJGL 的
// SharedLibrary.getPath() 在同一个进程里会拿到的同一个文件。
std::string findLoadedPath(const char *soname) {
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) {
        return std::string();
    }
    char lineBuf[4096];
    std::string found;
    while (fgets(lineBuf, sizeof(lineBuf), f)) {
        const char *hit = strstr(lineBuf, soname);
        if (!hit) {
            continue;
        }
        // maps 行尾就是路径，字段以空格分隔，路径本身从第一个 '/' 开始
        const char *slash = strchr(lineBuf, '/');
        if (!slash) {
            continue;
        }
        std::string p(slash);
        while (!p.empty() && (p.back() == '\n' || p.back() == '\r' || p.back() == ' ')) {
            p.pop_back();
        }
        // 只认真正以该 soname 结尾的（避免匹配到同名目录或 .so 的其它变体）
        if (p.size() >= strlen(soname) &&
            p.compare(p.size() - strlen(soname), strlen(soname), soname) == 0) {
            found = p;
            break;
        }
    }
    fclose(f);
    return found;
}

std::string describeMatch(void *v, void *A, void *B) {
    if (v == nullptr) {
        return "NULL";
    }
    if (v == A) {
        return "== A (libglfw)";
    }
    if (B && v == B) {
        return "== B (系统 GLES)";
    }
    return "(第三方)";
}

} // namespace

extern "C" {

// sdl3PathHint：可选。给绝对路径就用它，否则按名字 dlopen("libSDL3.so")，
// 让 loader 在应用 namespace 的默认搜索路径（HAP 的 libs/arm64）里找。
const char *runSdl3C2Test(const char *sdl3PathHint) {
    Reporter r;
    int rc = 2; // 0=C2 成立 1=证伪 2=未完成

    r.line("========================================");
    r.line("  SDL3 C2 关卡真机探针");
    r.line("  SDL_GL_GetProcAddress vs dlsym(libglfw.so)");
    r.line("========================================");
    r.line("");
    r.line("MC 的硬校验：dlsym(libglfw,glGetError) 必须 == SDL_GL_GetProcAddress(glGetError)");
    r.line("跑在 AMCL 应用进程里 —— linker namespace 与 MC 启动后一致。");
    r.line("");

    // ---------------------------------------------------------------------
    // 第 0 层：定位 libglfw.so —— 必须是 MC 那边会拿到的同一个文件
    // ---------------------------------------------------------------------
    r.line("[0] 定位 libglfw.so");

    std::string glfwPath = findLoadedPath("libglfw.so");
    if (glfwPath.empty()) {
        r.line("    /proc/self/maps 里没有 libglfw.so —— 尝试 dladdr(&glfwInit)");
    } else {
        r.linef("    maps 路径   = %s", glfwPath.c_str());
    }

    // dladdr 交叉验证：libentry 编译期就链接了 libglfw，&glfwInit 必定落在它里面。
    Dl_info info;
    std::memset(&info, 0, sizeof(info));
    if (dladdr(reinterpret_cast<void *>(&glfwInit), &info) && info.dli_fname) {
        r.linef("    dladdr      = %s", info.dli_fname);
        if (glfwPath.empty()) {
            glfwPath = info.dli_fname;
        } else if (std::string(info.dli_fname) != glfwPath) {
            r.line("    [!] dladdr 与 maps 路径不一致（dladdr 可能只给了 SONAME），以 maps 为准");
        }
    } else {
        r.line("    dladdr(&glfwInit) 失败");
    }

    if (glfwPath.empty()) {
        r.line("    [X] 定位不到 libglfw.so，无法继续");
        r.line("");
        r.line("C2 判定: INCOMPLETE（探针自身前提不成立）");
        g_report = r.str();
        return g_report.c_str();
    }
    r.linef("    采用        = %s", glfwPath.c_str());
    r.line("");

    // ---------------------------------------------------------------------
    // 第 1 层：dlsym 层的事实（零风险，不依赖 SDL 能否起来）
    // ---------------------------------------------------------------------
    r.line("[1] dlsym 层（LWJGL 侧等价物）");

    // LWJGL 的 SharedLibrary 就是 dlopen(绝对路径) + dlsym。这里逐字复刻。
    void *h_glfw = dlopen(glfwPath.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!h_glfw) {
        r.linef("    [X] dlopen(%s) 失败: %s", glfwPath.c_str(), dlerror());
        r.line("");
        r.line("C2 判定: INCOMPLETE（探测中断，见上）");
        g_report = r.str();
        return g_report.c_str();
    }

    void *A = dlsym(h_glfw, "glGetError");
    r.linef("    A = dlsym(libglfw, glGetError)        = %p   <- MC/LWJGL 侧会拿到这个", A);

    // 交叉验证：按绝对路径 dlopen 拿到的，和进程里已加载的那份，是不是同一个模块。
    // 如果 namespace 让同一个文件被加载两次，地址会不同，那 C2 直接完蛋。
    void *h_noload = dlopen(glfwPath.c_str(), RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    if (h_noload) {
        void *A2 = dlsym(h_noload, "glGetError");
        r.linef("    dlopen(RTLD_NOLOAD) 同一 handle       = %s, glGetError %s",
                (h_noload == h_glfw) ? "是" : "**否**",
                (A2 == A) ? "同址" : "**不同址**");
    } else {
        r.line("    [!] RTLD_NOLOAD 拿不到 handle —— 说明刚才那次 dlopen 是首次加载");
    }
    // 编译期直连的 glfwInit 与 dlsym 取到的是否同址（再确认一次没有重复加载）
    void *sym_init_dl = dlsym(h_glfw, "glfwInit");
    void *sym_init_link = reinterpret_cast<void *>(&glfwInit);
    r.linef("    glfwInit: 编译期直连 %p / dlsym %p  %s",
            sym_init_link, sym_init_dl,
            (sym_init_dl == sym_init_link) ? "同址 OK" : "**不同址（模块被加载了两份）**");

    void *A_egl = dlsym(h_glfw, "eglGetProcAddress");
    void *A_glx = dlsym(h_glfw, "glXGetProcAddress");
    r.linef("    libglfw eglGetProcAddress             = %p", A_egl);
    r.linef("    libglfw glXGetProcAddress             = %p", A_glx);
    // 只取地址不调用：实调 MobileGlues 的 eglGetProcAddress 有崩溃风险
    // （可能要求 EGL 已初始化），推迟到最后一层。

    if (!A) {
        r.line("    [X] libglfw.so 没有导出 glGetError —— 与离线 ELF 结论矛盾，先查产物");
        r.line("");
        r.line("C2 判定: INCOMPLETE（探测中断，见上）");
        g_report = r.str();
        return g_report.c_str();
    }

    // 对照组：系统 GLES 的 glGetError，应当与 A 不同址
    const char *sysGles[] = {"libGLESv3.so", "libGLESv2.so"};
    void *B = nullptr;
    for (const char *name : sysGles) {
        void *h = dlopen(name, RTLD_NOW | RTLD_LOCAL);
        if (!h) {
            r.linef("    dlopen(%s) 失败: %s", name, dlerror());
            continue;
        }
        void *b = dlsym(h, "glGetError");
        r.linef("    B = dlsym(%s, glGetError)   = %p   <- 系统 GLES，对照组", name, b);
        if (b && !B) {
            B = b;
        }
    }
    if (!B) {
        r.line("    (拿不到系统 GLES 的 glGetError —— 可能被 namespace 隔离，这本身是好消息)");
    } else if (B == A) {
        r.line("    [!] 系统 GLES 与 libglfw 的 glGetError 同址 —— 说明 libglfw 是转发而非自实现，");
        r.line("        与离线 ELF 结论（自己 DEFINED 3072 个 gl 符号）矛盾，需复查产物");
    }

    // 全局作用域解析到谁：验证 RTLD_LOCAL 的效果
    void *G = dlsym(RTLD_DEFAULT, "glGetError");
    r.linef("    dlsym(RTLD_DEFAULT, glGetError)       = %p   %s", G,
            (G == nullptr) ? "(全局没有 -> RTLD_LOCAL 生效)" : describeMatch(G, A, B).c_str());
    if (G && G != A) {
        r.line("    [重要] 全局作用域给的不是 libglfw 的那个。所以 SDL 若在任何地方用");
        r.line("           RTLD_DEFAULT / 全局符号解析 gl*，C2 必然失败。离线已逐行确认");
        r.line("           SDL_EGL_GetProcAddressInternal 不走全局作用域，这条真机数据");
        r.line("           说明那个确认是必要的，不是多余的谨慎。");
    }
    r.line("");

    // ---------------------------------------------------------------------
    // 第 1.5 层：不依赖 SDL 能否初始化，直接推演 SDL 会拿到什么
    //
    // SDL_EGL_GetProcAddressInternal() 全文只有两个来源（源码逐行核实）：
    //     (a) _this->egl_data->eglGetProcAddress(proc)        // EGL>=1.5 优先，<=1.4 兜底
    //     (b) SDL_LoadFunction(opengl_dll_handle, proc)       // = dlsym(具体 handle, proc)
    // 我们把 SDL_EGL_LIBRARY 与 SDL_OPENGL_LIBRARY 都指向 libglfw.so，于是
    //     (a) 就是 libglfw 的 eglGetProcAddress(proc)
    //     (b) 就是 dlsym(libglfw, proc) —— 也就是第 1 层的 A
    // 两者都能在这里直接量出来。只要都等于 A，SDL 无论走哪条 if 都只能返回 A。
    // 这一层不碰 SDL，所以 SDL 的 driver 起不来也不影响结论。
    // ---------------------------------------------------------------------
    r.line("[1.5] 推演 SDL 的两个解析来源（不依赖 SDL 初始化）");
    void *srcB = A; // 来源 (b) 就是 dlsym(libglfw)，即 A
    r.linef("    来源(b) SDL_LoadFunction(opengl_dll_handle) = %p   %s",
            srcB, (srcB == A) ? "== A" : "!= A");

    void *srcA = nullptr;
    bool srcAUsable = false;
    if (A_egl) {
        // 实调 MobileGlues 自己的 eglGetProcAddress。它内部那条链是
        // eglGetProcAddress -> glXGetProcAddress -> dlsym(self)，理论上落回自身符号。
        // 有崩溃风险（可能要求 EGL 已初始化），所以先把前面的结论刷到 hilog + 文件。
        amclLogFlush();
        srcA = reinterpret_cast<fn_eglGetProcAddress>(A_egl)("glGetError");
        srcAUsable = true;
        r.linef("    来源(a) libglfw eglGetProcAddress(glGetError) = %p   %s", srcA,
                (srcA == A) ? "== A" : (srcA == nullptr ? "NULL（SDL 会回落到来源 b）"
                                                        : describeMatch(srcA, A, B).c_str()));
    } else {
        r.line("    来源(a) libglfw 没导出 eglGetProcAddress —— SDL 只会走来源 (b)");
    }

    // 结构性结论：SDL 的两条来源分别是什么
    bool structuralPass = (srcB == A) && (!srcAUsable || srcA == nullptr || srcA == A);
    if (structuralPass) {
        r.line("    => 两个来源都指向 libglfw 的 glGetError，SDL_GL_GetProcAddress 只能返回 A。");
    } else {
        r.line("    => [!] 至少一个来源不是 A，SDL 走到那条 if 时会返回错的地址。");
    }
    r.line("");

    // ---------------------------------------------------------------------
    // 第 2 层：走 SDL 的真实代码路径（有崩溃风险，前面结论已落盘）
    //
    // driver 依次试 openharmony / ohos / offscreen / dummy：
    //   openharmony —— icculus/SDL sdl3-harmonyos 分支的注册名（2026-07-31 起的新基线）。
    //                  它的 GL_GetProcAddress 同样走 SDL_EGL_GetProcAddressInternal，
    //                  所以 C2 结论可以直接迁移。
    //   ohos        —— AMCL 自有 fork（LZZLHY/SDL ohos）的注册名。两个名字都试，
    //                  这样探针对「当前打进 HAP 的是哪个基线」不敏感。
    //                  OHOS_VideoInit 无条件成功，OHOS_GLES_LoadLibrary 用
    //                  EGL_DEFAULT_DISPLAY，不需要 XComponent。
    //   offscreen   —— 实测在真机上失败：SDL_EGL_InitializeOffscreen 要求
    //                  EGL_EXT_device_enumeration（eglQueryDevicesEXT），MobileGlues 没实现。
    //   dummy       —— 没有 GL_LoadLibrary 回调，SDL_GL_LoadLibrary 必然失败，仅作兜底记录。
    // 不存在的 driver 名会让 SDL_Init 直接失败并进入下一轮，代价只是一条日志，
    // 所以同时列两个名字是安全的。
    // 注意 SDL_GL_LoadLibrary 失败时公共入口会调 GL_UnloadLibrary 且不递增
    // driver_loaded，之后 SDL_GL_GetProcAddress 一定返回 NULL，所以必须换 driver 重试。
    // ---------------------------------------------------------------------
    r.line("[2] SDL 代码路径");

    std::string sdl3Path = (sdl3PathHint && sdl3PathHint[0]) ? sdl3PathHint : "libSDL3.so";
    r.linef("    dlopen 目标 = %s", sdl3Path.c_str());

    void *h_sdl = dlopen(sdl3Path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!h_sdl) {
        r.linef("    [X] dlopen 失败: %s", dlerror());
        r.line("        （libSDL3.so 需先就位于 entry/libs/arm64-v8a/ 并打进 HAP）");
        r.line("");
        r.line("第 1 层的 dlsym 事实仍然有效，但 SDL 侧未验证。");
        r.line("C2 判定: INCOMPLETE（探测中断，见上）");
        g_report = r.str();
        return g_report.c_str();
    }
    {
        std::string loaded = findLoadedPath("libSDL3.so");
        if (!loaded.empty()) {
            r.linef("    实际加载   = %s", loaded.c_str());
        }
    }

    struct SymSpec {
        const char *name;
        void **slot;
    };
    void *pInit = nullptr, *pQuit = nullptr, *pGetError = nullptr, *pGLLoad = nullptr;
    void *pGLProc = nullptr, *pGLUnload = nullptr, *pCurDrv = nullptr;
    void *pNumDrv = nullptr, *pGetDrv = nullptr, *pSetMainReady = nullptr;
    const SymSpec specs[] = {
        {"SDL_Init", &pInit},
        {"SDL_Quit", &pQuit},
        {"SDL_GetError", &pGetError},
        {"SDL_GL_LoadLibrary", &pGLLoad},
        {"SDL_GL_GetProcAddress", &pGLProc},
        {"SDL_GL_UnloadLibrary", &pGLUnload},
        {"SDL_GetCurrentVideoDriver", &pCurDrv},
        {"SDL_GetNumVideoDrivers", &pNumDrv},
        {"SDL_GetVideoDriver", &pGetDrv},
    };
    // SDL_SetMainReady 单独取，**不计入必需集** —— 它缺失只影响第 2 层能否初始化，
    // 不影响第 1 / 1.5 层的 dlsym 事实，没有理由让整个探针中止。
    pSetMainReady = dlsym(h_sdl, "SDL_SetMainReady");
    int missing = 0;
    for (const SymSpec &s : specs) {
        *s.slot = dlsym(h_sdl, s.name);
        if (!*s.slot) {
            r.linef("    [!] dlsym(%s) 失败", s.name);
            missing++;
        }
    }
    if (missing) {
        r.linef("    [X] 缺 %d 个 SDL 符号，中止", missing);
        r.line("");
        r.line("C2 判定: INCOMPLETE（探测中断，见上）");
        g_report = r.str();
        return g_report.c_str();
    }

    {
        std::ostringstream drv;
        drv << "    可用 video driver:";
        int nd = reinterpret_cast<fn_SDL_GetNumVideoDrivers>(pNumDrv)();
        for (int i = 0; i < nd; i++) {
            drv << " " << reinterpret_cast<fn_SDL_GetVideoDriver>(pGetDrv)(i);
        }
        r.line(drv.str());
    }

    // 关键：同时设 SDL_OPENGL_LIBRARY 与 SDL_EGL_LIBRARY 指向 libglfw.so。
    // Phase 0.3 新事实 A：opengl_dll_handle **只**来自 SDL_HINT_OPENGL_LIBRARY，
    // 不来自 SDL_GL_LoadLibrary 的 path 参数；egl_dll_handle 才用 path/SDL_EGL_LIBRARY。
    // 用 setenv 而不是 SDL_SetHint：Phase 0.2 已确认 SDL_GetHint 先读 env，
    // 且 SDL_SetHint 的默认 NORMAL 优先级覆盖不掉 env，所以 env 才是权威来源。
    setenv("SDL_OPENGL_LIBRARY", glfwPath.c_str(), 1);
    setenv("SDL_EGL_LIBRARY", glfwPath.c_str(), 1);
    // 不让 SDL 抢 AMCL/JVM 的信号处理器（MC 自己也设这个 hint）
    setenv("SDL_NO_SIGNAL_HANDLERS", "1", 1);
    r.linef("    SDL_OPENGL_LIBRARY = %s", getenv("SDL_OPENGL_LIBRARY"));
    r.linef("    SDL_EGL_LIBRARY    = %s", getenv("SDL_EGL_LIBRARY"));

    // 允许外部指定单一 driver（调试用）；否则依次尝试
    const char *driverList[] = {"openharmony", "ohos", "offscreen", "dummy"};
    std::vector<const char *> drivers;
    const char *forced = getenv("AMCL_SDL3_C2_DRIVER");
    if (forced && forced[0]) {
        drivers.push_back(forced);
    } else {
        for (const char *d : driverList) {
            drivers.push_back(d);
        }
    }

    void *C = nullptr;
    bool sdlPathOk = false;
    std::string okDriver;

    // ---------------------------------------------------------------------
    // 必须先 SDL_SetMainReady()，否则 SDL_Init 在 icculus 基线上必然失败。
    //
    // 2026-07-31 22:46 平板实测：不调它时，4 个 driver 全部报同一个错 ——
    //   "Application didn't initialize properly, did you include SDL_main.h ..."
    // 与 driver 名毫无关系。根因链（见 SDL3_MIGRATION_PLAN.md §C1.1）：
    //   · icculus 分支 include/SDL3/SDL_main.h:198 对 SDL_PLATFORM_OPENHARMONY
    //     定义了 SDL_MAIN_NEEDED（自有 fork 没有这一处，只有上游原本的 4 处）
    //   · src/SDL_internal.h:250-254 会把 SDL_main.h 拉进来，所以编译 SDL.c 时该宏可见
    //   · 于是 src/SDL.c:188-192 令 SDL_MainIsReady 初值为 false
    //   · SDL_InitSubSystem（src/SDL.c:330-332）开头即：
    //         if (!SDL_MainIsReady) return SDL_SetError("Application didn't initialize...")
    // icculus 的默认路径靠 SDL_RunApp → SDL_CallMainFunction 替你调掉；
    // 而我们（以及将来 AMCL 的模式 B）是从宿主线程直接调 SDL_Init，没人替我们调。
    //
    // 顺带的好处：SDL_SetMainReady() 会把 SDL_MainThreadID 设成**当前线程**
    // （src/SDL.c:262-268，带 if (MainThreadID == 0) 保护，谁先调谁定），
    // 所以在这里调 = 把探针所在线程登记为主线程，语义正确。
    // 这一步同时**实证了 AMCL 模式 B 可行**：宿主自己调它就能让 SDL_Init 工作。
    if (pSetMainReady) {
        reinterpret_cast<fn_SDL_SetMainReady>(pSetMainReady)();
        r.line("    SDL_SetMainReady() 已调用（icculus 基线上这是 SDL_Init 的前置条件）");
    } else {
        r.line("    [!] 没找到 SDL_SetMainReady —— 若 SDL_Init 报 "
               "\"didn't initialize properly\"，原因就在这里");
    }

    for (const char *drv : drivers) {
        setenv("SDL_VIDEO_DRIVER", drv, 1);
        r.linef("    --- 尝试 driver = %s ---", drv);

        if (!reinterpret_cast<fn_SDL_Init>(pInit)(kSdlInitVideo)) {
            r.linef("        SDL_Init 失败: %s", reinterpret_cast<fn_SDL_GetError>(pGetError)());
            continue;
        }
        const char *cur = reinterpret_cast<fn_SDL_GetCurrentVideoDriver>(pCurDrv)();
        r.linef("        SDL_Init OK，当前 driver = %s", cur ? cur : "(null)");

        if (!reinterpret_cast<fn_SDL_GL_LoadLibrary>(pGLLoad)(glfwPath.c_str())) {
            r.linef("        SDL_GL_LoadLibrary 失败: %s",
                    reinterpret_cast<fn_SDL_GetError>(pGetError)());
            // 失败时公共入口已经 GL_UnloadLibrary 且没递增 driver_loaded，
            // 此时 SDL_GL_GetProcAddress 必然返回 NULL，换下一个 driver。
            reinterpret_cast<fn_SDL_Quit>(pQuit)();
            continue;
        }
        r.line("        SDL_GL_LoadLibrary OK");

        C = reinterpret_cast<fn_SDL_GL_GetProcAddress>(pGLProc)("glGetError");
        r.linef("        C = SDL_GL_GetProcAddress(glGetError) = %p", C);
        sdlPathOk = true;
        okDriver = cur ? cur : drv;
        break;
    }

    if (!sdlPathOk) {
        r.line("    所有 driver 都没能走通 SDL_GL_LoadLibrary。");
        r.line("    MC 走的是 OHOS driver（openharmony / ohos）+ 真实 XComponent，与这里的条件不同；");
        r.line("    第 1 / 1.5 层的结论不依赖 SDL 初始化，仍然有效。");
    }
    r.line("");

    // ---------------------------------------------------------------------
    // 第 3 层：判定
    // ---------------------------------------------------------------------
    r.line("[3] 判定（MC 的校验就是 A == C）");
    r.linef("    A (dlsym libglfw)         = %p", A);
    if (B) {
        r.linef("    B (系统 GLES，对照)       = %p", B);
    }

    if (!sdlPathOk) {
        // SDL 的 video driver 在 DevTools 这条路径上起不来（没有 XComponent），
        // 但第 1.5 层已经把 SDL 的两个解析来源都直接量出来了，结论是确定的。
        r.line("    C 未能取得：SDL 的 video driver 在本上下文起不来（无 XComponent）。");
        r.linef("    改用第 1.5 层的推演：两个来源 %s",
                structuralPass ? "都等于 A" : "至少一个不等于 A");
        if (structuralPass) {
            r.line("    ✅ 结构上 C2 成立：SDL_GL_GetProcAddress 的两条来源都只能返回 A。");
            r.line("       仍需在带 XComponent 的真实渲染路径上复测一次（Phase 2 关卡）。");
            rc = 3; // 结构成立、SDL 端到端未验
        } else {
            r.line("    ❌ 结构上 C2 有问题，见第 1.5 层。");
            rc = 1;
        }
    } else {
        r.linef("    C (SDL_GL_GetProcAddress) = %p   [driver=%s]", C, okDriver.c_str());
    }

    if (!sdlPathOk) {
        // 判定已在上面给出，跳过后面基于 C 的分支
    } else if (C == nullptr) {
        r.line("    ❌ [FAIL] C == NULL：SDL 解析不到 glGetError，MC 会抛 glGetError mismatch。");
        rc = 1;
    } else if (C == A) {
        r.line("    ✅ [PASS] A == C —— C2 成立，MC 的 glGetError 硬校验会通过。");
        rc = 0;
    } else if (B && C == B) {
        r.line("    ❌ [FAIL] C == B：SDL 拿到的是**系统 GLES** 的 glGetError，不是 MobileGlues 的。");
        r.line("           首查 SDL_OPENGL_LIBRARY / SDL_EGL_LIBRARY 是否真的生效；");
        r.line("           其次查 libSDL3.so 的 NEEDED 里那个多余的 libGLESv2.so 是否把系统符号");
        r.line("           抢先带进了可见范围（离线分析认为不会：两条解析路径都用具体 handle，");
        r.line("           且 SDL_LoadObject 用 RTLD_LOCAL）。若真发生，说明 HarmonyOS 的");
        r.line("           namespace 行为与 POSIX 预期不同，需要 patch SDL 或去掉那个链接依赖。");
        rc = 1;
    } else {
        r.line("    ❌ [FAIL] A != C 且 C 不是系统 GLES —— 来自第三方库，需逐一排查。");
        rc = 1;
    }
    r.line("");

    // ---------------------------------------------------------------------
    // 第 4 层：抽查其它 gl 符号，避免只有 glGetError 恰好对上
    // ---------------------------------------------------------------------
    r.line("[4] 抽查其它 gl 符号（避免只有 glGetError 恰好对上）");
    const char *more[] = {"glGetString", "glClear", "glViewport",
                          "glGetIntegerv", "glCreateShader", "glDrawArrays"};
    int same = 0;
    int total = 0;
    for (const char *name : more) {
        void *a = dlsym(h_glfw, name);
        total++;
        if (sdlPathOk) {
            void *c = reinterpret_cast<fn_SDL_GL_GetProcAddress>(pGLProc)(name);
            bool ok = (a != nullptr && a == c);
            if (ok) {
                same++;
            }
            r.linef("    %-16s dlsym=%p  SDL=%p  %s", name, a, c,
                    ok ? "同址 OK" : (c == nullptr ? "SDL 解析不到 FAIL" : "不同址 FAIL"));
        } else {
            // 没有 SDL 侧地址可比，就走第 1.5 层同样的推演：
            // 来源(b) 就是 dlsym，来源(a) 是 libglfw 的 eglGetProcAddress。
            void *viaEgl = A_egl ? reinterpret_cast<fn_eglGetProcAddress>(A_egl)(name) : nullptr;
            bool ok = (a != nullptr) && (viaEgl == nullptr || viaEgl == a);
            if (ok) {
                same++;
            }
            r.linef("    %-16s dlsym=%p  eglGetProcAddress=%p  %s", name, a, viaEgl,
                    ok ? "两来源一致 OK" : "两来源不一致 FAIL");
        }
    }
    r.linef("    一致 %d/%d", same, total);
    if ((rc == 0 || rc == 3) && same != total) {
        r.line("    [!] glGetError 对上了但其它符号没有 —— 解析来源不一致，仍需排查");
        rc = 1;
    }
    r.line("");

    if (sdlPathOk) {
        reinterpret_cast<fn_SDL_GL_UnloadLibrary>(pGLUnload)();
        reinterpret_cast<fn_SDL_Quit>(pQuit)();
    }
    // 刻意不 dlclose(h_sdl)：SDL_Quit 之后 dlclose 可能触发 atexit/pthread_key
    // 析构顺序问题，而 DevTools 这条路径一次只跑一遍，留在进程里无害。

    r.line("========================================");
    if (rc == 0) {
        r.linef("C2 判定: PASS ✅ —— A == C（driver=%s），MC 的 glGetError 硬校验会通过",
                okDriver.c_str());
    } else if (rc == 3) {
        r.line("C2 判定: STRUCTURAL-PASS ✅ —— SDL 的两条解析来源都只能返回 libglfw 的地址");
        r.line("         （SDL video driver 在无 XComponent 的上下文起不来，端到端待 Phase 2 复测）");
    } else if (rc == 1) {
        r.line("C2 判定: FAIL ❌ —— 需要 patch，详见上面排查线索");
    } else {
        r.line("C2 判定: INCOMPLETE（探测中断，见上）");
    }
    r.line("========================================");

    amclLogFlush();
    g_report = r.str();
    return g_report.c_str();
}

} // extern "C"
