// sdl3_c2probe.c — C2 真机探针（SDL3_MIGRATION_PLAN.md §四 C2 / §七 Phase 2 关卡）
//
// ############################################################################
// # 已被取代，不再维护。逻辑单一来源见：
// #     entry/src/main/cpp/tests/sdl3_c2_test.cpp   （DevTools「SDL3 C2 关卡」）
// #
// # 为什么：这个独立可执行文件在 HarmonyOS NEXT 真机上跑不起来。实测
// #   /data 挂载没有 noexec、chmod +x 也生效，但执行返回 126 Permission denied
// #   —— 是 SELinux 域策略拒绝（shell 域 u:r:sh:s0 对 u:object_r:data_local_tmp:s0
// #   没有 execute），无 root 绕不过。
// # 更根本的原因：HarmonyOS 的 linker namespace 按应用配置，而 C2 唯一无法离线
// #   推导的变量恰恰就是 namespace 行为。在 shell 域测的是另一套 namespace，
// #   结论不能迁移到 MC 的运行环境。
// #
// # 保留原因：在有 root 的设备/模拟器上仍可用；构建脚本里的 PT_INTERP 判据与
// #   SELinux 结论有文档价值。**但功能改进只做在 tests/sdl3_c2_test.cpp 里**，
// #   本文件缺少后者的多 driver 回退与「两个解析来源」推演层。
// #
// # 真机结论（2026-07-31 12:26，应用内探针）：C2 PASS，driver=ohos，
// #   A == C == 0x5a4c0539b8，抽查 6/6 同址。详见
// #   docs/adaptation/SDL3_PORT_WORKLOG.md 的 12:27:14 条目。
// ############################################################################
//
// 注：整个文件头用 `//` 行注释而不是块注释 —— 因为正文里要写 "gl*" 与 "egl*"，
// 一旦出现 "gl*/egl*" 这种写法，其中的 "*/" 会把块注释提前闭合（第一版就栽在这）。
//
// ============================================================================
// C2 是什么
// ============================================================================
// MC 26.3 的 com.mojang.renderpearl.backend.opengl.GlBackend.loadLibrary() 会做一次
// 硬校验（javap 逐条核实，见 §二·2.7）：
//
//     String path = ((SharedLibrary) GL.getFunctionProvider()).getPath();   // = libglfw.so
//     if (!SDLVideo.SDL_GL_LoadLibrary(path)) throw ... OPENGL_MISSING;
//     if (GL.getFunctionProvider().getFunctionAddress("glGetError")
//             != SDLVideo.SDL_GL_GetProcAddress("glGetError")) {
//         SDLVideo.SDL_GL_UnloadLibrary();
//         throw new BackendCreationException("glGetError mismatch", OPENGL_MISSING);
//     }
//
// 两边地址不等 ⇒ OpenGL 后端直接被拒、游戏起不来。
//
// ============================================================================
// 离线已经证明到什么程度（所以这个探针只补最后一环）
// ============================================================================
// 已确定的结构性事实：
//
//  1) libglfw.so 自己 DEFINED 了 3072 个 gl 前缀符号、35 个 egl 前缀符号、
//     2 个 glX 前缀符号，且**未定义的 gl 与 egl 前缀符号均为 0** ——
//     它不依赖任何外部 GL/EGL 符号。SDL_EGL_LoadLibraryOnly 需要的 19 个 egl
//     符号，它 19/19 全覆盖。
//
//  2) libSDL3.so 导出的 gl/egl 前缀符号为 0、未定义的也为 0 —— SDL 完全靠
//     dlopen + dlsym 取 EGL/GL，零静态符号依赖。
//
//  3) SDL_EGL_GetProcAddressInternal() 全文只有三条 if、两个来源：
//         eglGetProcAddress(proc)                    // 来自 dlsym(egl_dll_handle)
//         SDL_LoadFunction(opengl_dll_handle, proc)   // = dlsym(具体 handle)
//     没有第三条路径，**从不使用 RTLD_DEFAULT 或全局符号作用域**。
//
//  4) SDL_LoadObject() = dlopen(sofile, RTLD_NOW | **RTLD_LOCAL**)
//     ⇒ SDL 加载 libglfw.so 时不把它的符号放进全局作用域。
//     SDL_LoadFunction() = dlsym(handle, name)，具体 handle。
//
//  ⇒ 两条来源都指向同一个 libglfw.so handle 的同一个符号；
//     libSDL3.so 的 NEEDED 里那个多余的 libGLESv2.so 也就无从干扰。
//
// **唯一无法离线确认的是 HarmonyOS 的 linker namespace 行为** —— 应用私有 .so 与
// 系统 .so 分属不同 namespace，dlopen/dlsym 的可见性由系统策略决定。
// 这个探针就是为这一环写的：在真机上直接把地址打出来比。
//
// ============================================================================
// 怎么跑
// ============================================================================
//   编译：docker exec ohos-debug bash /host-docker/build_sdl3_c2probe_ohos.sh
//   推送与运行的完整命令见构建脚本末尾打印的 HOWTO。
//
// 退出码：0 = C2 成立（两侧同址）；1 = 不同址（C2 被证伪）；2 = 探测未完成。

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <unistd.h>

// 只用到这几个 SDL 公开符号，全部 dlsym 取，不在编译期链接 libSDL3.so，
// 这样探针本身不带 NEEDED 依赖，路径完全由命令行给定。
typedef bool (*fn_SDL_Init)(unsigned int);
typedef void (*fn_SDL_Quit)(void);
typedef const char *(*fn_SDL_GetError)(void);
typedef bool (*fn_SDL_GL_LoadLibrary)(const char *);
typedef void *(*fn_SDL_GL_GetProcAddress)(const char *);
typedef void (*fn_SDL_GL_UnloadLibrary)(void);
typedef const char *(*fn_SDL_GetCurrentVideoDriver)(void);
typedef int (*fn_SDL_GetNumVideoDrivers)(void);
typedef const char *(*fn_SDL_GetVideoDriver)(int);
typedef void *(*fn_eglGetProcAddress)(const char *);

#define SDL_INIT_VIDEO 0x00000020u

static void *must_sym(void *h, const char *name, int *missing)
{
    void *p = dlsym(h, name);
    if (!p) {
        printf("    [!] dlsym(%s) 失败: %s\n", name, dlerror());
        (*missing)++;
    }
    return p;
}

int c2probe_main(const char *sdl3_path, const char *glfw_path)
{
    printf("======================================================\n");
    printf(" C2 probe - SDL_GL_GetProcAddress vs dlsym(libglfw.so)\n");
    printf("======================================================\n");
    printf("  libSDL3 : %s\n", sdl3_path);
    printf("  libglfw : %s\n", glfw_path);
    printf("\n");

    int rc = 2;

    // ---------------------------------------------------------------------
    // 第 1 层：dlsym 层的事实（不依赖 SDL 能不能起来）
    // ---------------------------------------------------------------------
    printf("[1] dlsym 层\n");

    // LWJGL 侧等价物：LWJGL 的 SharedLibrary 就是 dlopen + dlsym。
    void *h_glfw = dlopen(glfw_path, RTLD_NOW | RTLD_LOCAL);
    if (!h_glfw) {
        printf("    [X] dlopen(libglfw.so) 失败: %s\n", dlerror());
        return 2;
    }
    void *A = dlsym(h_glfw, "glGetError");
    printf("    A = dlsym(libglfw, glGetError)      = %p   <- LWJGL 侧会拿到的地址\n", A);
    if (!A) {
        printf("    [X] libglfw.so 没有导出 glGetError —— 与离线 ELF 结论矛盾，先查产物\n");
        return 2;
    }
    void *A_egl = dlsym(h_glfw, "eglGetProcAddress");
    void *A_glx = dlsym(h_glfw, "glXGetProcAddress");
    printf("    libglfw 的 eglGetProcAddress        = %p\n", A_egl);
    printf("    libglfw 的 glXGetProcAddress        = %p\n", A_glx);
    // 注意：这里只取地址、**不调用**。实调 MobileGlues 的 eglGetProcAddress 有崩溃
    // 风险（它可能要求 EGL 已初始化），所以推迟到第 5 层、核心判定拿到之后再做，
    // 万一崩了也不会带走 A/B/C 的结论。

    // 对照组：系统 libGLESv2 / libGLESv3 的 glGetError（应与 A 不同）
    const char *sys_gles[] = { "libGLESv3.so", "libGLESv2.so", NULL };
    void *B = NULL;
    for (int i = 0; sys_gles[i]; i++) {
        void *h = dlopen(sys_gles[i], RTLD_NOW | RTLD_LOCAL);
        if (!h) {
            printf("    dlopen(%s) 失败: %s\n", sys_gles[i], dlerror());
            continue;
        }
        void *b = dlsym(h, "glGetError");
        printf("    B = dlsym(%s, glGetError) = %p   <- 系统 GLES，对照组\n", sys_gles[i], b);
        if (b && !B) {
            B = b;
        }
    }
    if (!B) {
        printf("    (拿不到系统 GLES 的 glGetError —— 可能被 linker namespace 隔离，本身是好消息)\n");
    } else if (B == A) {
        printf("    [!] 系统 GLES 与 libglfw 的 glGetError 同址 —— 说明 libglfw 是转发而非自实现，\n");
        printf("        与离线 ELF 结论（自己 DEFINED 3072 个 gl 符号）矛盾，需复查产物\n");
    }

    // 全局作用域里 glGetError 解析到谁（验证 RTLD_LOCAL 的效果）
    void *G = dlsym(RTLD_DEFAULT, "glGetError");
    printf("    dlsym(RTLD_DEFAULT, glGetError)     = %p   %s\n", G,
           (G == NULL) ? "(全局没有 -> RTLD_LOCAL 生效)"
                       : ((G == A) ? "== A"
                                   : ((B && G == B) ? "== B (系统版在全局)" : "(第三方)")));

    // ---------------------------------------------------------------------
    // 第 2 层：走 SDL 的真实代码路径
    // ---------------------------------------------------------------------
    printf("\n[2] SDL 代码路径\n");

    void *h_sdl = dlopen(sdl3_path, RTLD_NOW | RTLD_LOCAL);
    if (!h_sdl) {
        printf("    [X] dlopen(libSDL3.so) 失败: %s\n", dlerror());
        printf("\n结论：第 1 层已给出 dlsym 层事实，但 SDL 侧未验证。\n");
        return 2;
    }

    int missing = 0;
    fn_SDL_Init                  p_Init     = (fn_SDL_Init)                  must_sym(h_sdl, "SDL_Init", &missing);
    fn_SDL_Quit                  p_Quit     = (fn_SDL_Quit)                 must_sym(h_sdl, "SDL_Quit", &missing);
    fn_SDL_GetError              p_GetError = (fn_SDL_GetError)              must_sym(h_sdl, "SDL_GetError", &missing);
    fn_SDL_GL_LoadLibrary        p_GLLoad   = (fn_SDL_GL_LoadLibrary)        must_sym(h_sdl, "SDL_GL_LoadLibrary", &missing);
    fn_SDL_GL_GetProcAddress     p_GLProc   = (fn_SDL_GL_GetProcAddress)     must_sym(h_sdl, "SDL_GL_GetProcAddress", &missing);
    fn_SDL_GL_UnloadLibrary      p_GLUnload = (fn_SDL_GL_UnloadLibrary)      must_sym(h_sdl, "SDL_GL_UnloadLibrary", &missing);
    fn_SDL_GetCurrentVideoDriver p_CurDrv   = (fn_SDL_GetCurrentVideoDriver) must_sym(h_sdl, "SDL_GetCurrentVideoDriver", &missing);
    fn_SDL_GetNumVideoDrivers    p_NumDrv   = (fn_SDL_GetNumVideoDrivers)    must_sym(h_sdl, "SDL_GetNumVideoDrivers", &missing);
    fn_SDL_GetVideoDriver        p_GetDrv   = (fn_SDL_GetVideoDriver)        must_sym(h_sdl, "SDL_GetVideoDriver", &missing);
    if (missing) {
        printf("    [X] 缺 %d 个 SDL 符号，中止\n", missing);
        return 2;
    }

    printf("    可用 video driver:");
    int nd = p_NumDrv();
    for (int i = 0; i < nd; i++) {
        printf(" %s", p_GetDrv(i));
    }
    printf("\n");

    // 关键：同时设 SDL_OPENGL_LIBRARY 与 SDL_EGL_LIBRARY 指向 libglfw.so。
    // Phase 0.3 新事实 A：opengl_dll_handle **只**来自 SDL_HINT_OPENGL_LIBRARY，
    // 不来自 SDL_GL_LoadLibrary 的 path 参数；egl_dll_handle 才用 path / SDL_EGL_LIBRARY。
    // 用 setenv 而不是 SDL_SetHint：Phase 0.2 已确认 SDL_GetHint 先读 env，
    // 且 SDL_SetHint 的默认 NORMAL 优先级覆盖不掉 env，所以 env 才是权威。
    setenv("SDL_OPENGL_LIBRARY", glfw_path, 1);
    setenv("SDL_EGL_LIBRARY", glfw_path, 1);
    // OHOS 的 ohos driver 需要 ArkTS 侧注册 XComponent，命令行跑不起来；
    // offscreen driver 走同一套通用 SDL_EGL 层，正好用来验 GetProcAddress 路径。
    if (!getenv("SDL_VIDEO_DRIVER")) {
        setenv("SDL_VIDEO_DRIVER", "offscreen", 1);
    }
    printf("    SDL_VIDEO_DRIVER   = %s\n", getenv("SDL_VIDEO_DRIVER"));
    printf("    SDL_OPENGL_LIBRARY = %s\n", getenv("SDL_OPENGL_LIBRARY"));
    printf("    SDL_EGL_LIBRARY    = %s\n", getenv("SDL_EGL_LIBRARY"));

    if (!p_Init(SDL_INIT_VIDEO)) {
        printf("    [X] SDL_Init(SDL_INIT_VIDEO) 失败: %s\n", p_GetError());
        printf("        (试试 SDL_VIDEO_DRIVER=dummy 看是否 driver 选择问题；\n");
        printf("         第 1 层的 dlsym 事实仍然有效)\n");
        return 2;
    }
    printf("    SDL_Init OK，当前 driver = %s\n", p_CurDrv());

    if (!p_GLLoad(glfw_path)) {
        printf("    [X] SDL_GL_LoadLibrary 失败: %s\n", p_GetError());
        printf("        这一步失败说明 SDL_EGL_LoadLibraryOnly 或 InitializeOffscreen 没过；\n");
        printf("        MC 在这里失败会抛 BackendCreationException(OPENGL_MISSING)。\n");
        p_Quit();
        return 2;
    }
    printf("    SDL_GL_LoadLibrary OK\n");

    void *C = p_GLProc("glGetError");
    printf("    C = SDL_GL_GetProcAddress(glGetError) = %p\n", C);

    // ---------------------------------------------------------------------
    // 判定
    // ---------------------------------------------------------------------
    printf("\n[3] 判定（MC 的校验就是 A == C）\n");
    printf("    A (dlsym libglfw)         = %p\n", A);
    printf("    C (SDL_GL_GetProcAddress) = %p\n", C);
    if (B) {
        printf("    B (系统 GLES，对照)       = %p\n", B);
    }

    if (C == NULL) {
        printf("\n    [FAIL] C == NULL：SDL 解析不到 glGetError。MC 会抛 glGetError mismatch。\n");
        rc = 1;
    } else if (C == A) {
        printf("\n    [PASS] A == C —— C2 成立，MC 的 glGetError 硬校验会通过。\n");
        rc = 0;
    } else if (B && C == B) {
        printf("\n    [FAIL] C == B：SDL 拿到的是**系统 GLES** 的 glGetError，不是 MobileGlues 的。\n");
        printf("           C2 被证伪。首查 SDL_OPENGL_LIBRARY / SDL_EGL_LIBRARY 是否真的生效，\n");
        printf("           其次查 libSDL3.so 的 NEEDED 里那个多余的 libGLESv2.so 是否把系统符号\n");
        printf("           抢先带进了可见范围（离线分析认为不会：两条解析路径都用具体 handle，\n");
        printf("           且 SDL_LoadObject 用 RTLD_LOCAL。若真发生，说明 HarmonyOS 的\n");
        printf("           linker namespace 行为与 POSIX 预期不同，需要 patch SDL 或去掉那个依赖）。\n");
        rc = 1;
    } else {
        printf("\n    [FAIL] A != C 且 C 不是系统 GLES —— 来自第三方库，需逐一排查。\n");
        rc = 1;
    }

    // 附加：多抽查几个 gl 符号，避免只有 glGetError 恰好对上
    printf("\n[4] 抽查其它 gl 符号是否同样同址\n");
    const char *more[] = { "glGetString", "glClear", "glViewport", "glGetIntegerv",
                           "glCreateShader", "glDrawArrays", NULL };
    int same = 0, total = 0;
    for (int i = 0; more[i]; i++) {
        void *a = dlsym(h_glfw, more[i]);
        void *c = p_GLProc(more[i]);
        total++;
        if (a && a == c) {
            same++;
        }
        printf("    %-16s dlsym=%p  SDL=%p  %s\n", more[i], a, c,
               (a && a == c) ? "同址 OK" : ((c == NULL) ? "SDL 解析不到 FAIL" : "不同址 FAIL"));
    }
    printf("    同址 %d/%d\n", same, total);
    if (rc == 0 && same != total) {
        printf("    [!] glGetError 对上了但其它符号没有 —— 解析来源不一致，仍需排查\n");
        rc = 1;
    }

    p_GLUnload();
    p_Quit();

    // ---------------------------------------------------------------------
    // 第 5 层：实调 MobileGlues 自己的 eglGetProcAddress（有崩溃风险，故放最后）
    //
    // Phase 0.5 的结论是 MobileGlues 内部那条链
    //   eglGetProcAddress -> glXGetProcAddress -> dlsym(self)
    // 最终落回自身符号。这里实测一次。SDL 已经 Quit，此时崩溃不影响上面的判定，
    // 但**退出码会丢**，所以先把结论刷到 stdout。
    // ---------------------------------------------------------------------
    printf("\n[5] 实调 libglfw 的 eglGetProcAddress（可选，崩溃不影响上面结论）\n");
    printf("    先记住上面的退出码 = %d\n", rc);
    fflush(stdout);
    if (A_egl) {
        void *via_egl = ((fn_eglGetProcAddress)A_egl)("glGetError");
        printf("    libglfw eglGetProcAddress(glGetError) = %p   %s\n",
               via_egl, (via_egl == A) ? "== A  OK" : "!= A  <-- 注意");
    } else {
        printf("    libglfw 没导出 eglGetProcAddress，跳过\n");
    }

    printf("\n退出码 %d（0=C2 成立 / 1=证伪 / 2=未完成）\n", rc);
    fflush(stdout);
    return rc;
}

// 供 noexec 场景使用：把整个探针的 stdout 重定向到 out_path，由 AMCL 的 native 层
// dlopen 本 .so 后调一次，再用 hdc file recv 取回报告。
// （构建脚本除可执行文件外还会产出 libsdl3_c2probe.so，导出本函数与 c2probe_main。）
int c2probe_main_to_file(const char *sdl3_path, const char *glfw_path, const char *out_path)
{
    fflush(stdout);
    int saved = dup(STDOUT_FILENO);
    if (saved < 0) {
        return 2;
    }
    FILE *f = freopen(out_path, "w", stdout);
    if (!f) {
        close(saved);
        return 2;
    }
    int rc = c2probe_main(sdl3_path, glfw_path);
    fflush(stdout);
    dup2(saved, STDOUT_FILENO);
    close(saved);
    clearerr(stdout);
    return rc;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "用法: %s <libSDL3.so 路径> <libglfw.so 路径>\n", argv[0]);
        fprintf(stderr, "可选环境变量: SDL_VIDEO_DRIVER（默认 offscreen）\n");
        return 2;
    }
    return c2probe_main(argv[1], argv[2]);
}
