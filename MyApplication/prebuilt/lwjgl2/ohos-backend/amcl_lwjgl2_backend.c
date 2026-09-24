/*
 * amcl_lwjgl2_backend.c — LWJGL 2 窗口/上下文后端（HarmonyOS NEXT / AMCL 专用）
 *
 * 实现 AMCLDisplay / AMCLContextImplementation 的 native 方法，桥接到 AMCL 既有
 * libglfw.so（GLFW C ABI + EGL + XComponent + 输入），而非像 FCL 那样从零写 bespoke EGL。
 * GL 函数翻译由 gl4es 提供（见 extgl_ohos.c）。LWJGL2 把 PeerInfo/Context/Window 分离，
 * 但 GLFW 窗口与上下文一体、MC 单窗口 → 这里用单例 GLFWwindow* 抹平（懒创建）。
 *
 * libglfw 的 glfwCreateWindow 内部读 env AMCL_NATIVE_WINDOW 取 OHOS 原生窗口（与 LWJGL3 路径
 * 同源、同一个 XComponent surface），并按 glfw_compat 的时序处理 EGL（创建后释放、渲染线程再绑定）。
 *
 * 见 docs/adaptation/LWJGL_MULTIVERSION_PLAN.md §11.13。
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE   /* setenv / dlfcn 扩展（-std=c99 下默认隐藏 POSIX 符号）*/
#endif

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <jni.h>

/* 诊断日志走 stderr（已被 JVM 输出捕获，见日志 MCEXIT 行）；避免引入 libhilog NEEDED 依赖。 */
#define A2LOG(...) do { fprintf(stderr, "[LWJGL2BK] "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); fflush(stderr); } while (0)

#include "org_lwjgl_opengl_AMCLDisplay.h"
#include "org_lwjgl_opengl_AMCLContextImplementation.h"
#include "org_lwjgl_DefaultSysImplementation.h"
#include "common_tools.h"

/* ---- libglfw 符号（运行时 dlsym 解析，避免 link-time 依赖与命名空间问题）---- */
typedef void* GLFWwindow;
typedef int  (*PFN_glfwInit)(void);
typedef GLFWwindow* (*PFN_glfwCreateWindow)(int, int, const char*, void*, void*);
typedef void (*PFN_glfwDestroyWindow)(GLFWwindow*);
typedef void (*PFN_glfwMakeContextCurrent)(GLFWwindow*);
typedef void (*PFN_glfwSwapBuffers)(GLFWwindow*);
typedef void (*PFN_glfwSwapInterval)(int);
typedef void (*PFN_glfwPollEvents)(void);
typedef int  (*PFN_glfwWindowShouldClose)(GLFWwindow*);
typedef void (*PFN_glfwSetWindowTitle)(GLFWwindow*, const char*);
typedef void (*PFN_glfwGetFramebufferSize)(GLFWwindow*, int*, int*);

static void *s_glfw = NULL;
static PFN_glfwInit                p_init = NULL;
static PFN_glfwCreateWindow        p_create = NULL;
static PFN_glfwDestroyWindow       p_destroy = NULL;
static PFN_glfwMakeContextCurrent  p_makecur = NULL;
static PFN_glfwSwapBuffers         p_swap = NULL;
static PFN_glfwSwapInterval        p_swapint = NULL;
static PFN_glfwPollEvents          p_poll = NULL;
static PFN_glfwWindowShouldClose   p_shouldclose = NULL;
static PFN_glfwSetWindowTitle      p_settitle = NULL;
static PFN_glfwGetFramebufferSize  p_fbsize = NULL;

static GLFWwindow* s_window = NULL;
static int s_width = 0, s_height = 0;
/* context handle 占位（NewDirectByteBuffer 需指向有效内存；单例模型内容无意义）。 */
static unsigned char s_ctx_handle[16];

#ifndef AMCL_GLFW_SONAME
#define AMCL_GLFW_SONAME "libglfw.so"
#endif

static int load_glfw(void) {
    if (s_glfw != NULL) return 1;
    s_glfw = dlopen(AMCL_GLFW_SONAME, RTLD_NOW | RTLD_GLOBAL | RTLD_NOLOAD);
    if (s_glfw == NULL) s_glfw = dlopen(AMCL_GLFW_SONAME, RTLD_NOW | RTLD_GLOBAL);
    if (s_glfw == NULL) return 0;
    p_init        = (PFN_glfwInit)dlsym(s_glfw, "glfwInit");
    p_create      = (PFN_glfwCreateWindow)dlsym(s_glfw, "glfwCreateWindow");
    p_destroy     = (PFN_glfwDestroyWindow)dlsym(s_glfw, "glfwDestroyWindow");
    p_makecur     = (PFN_glfwMakeContextCurrent)dlsym(s_glfw, "glfwMakeContextCurrent");
    p_swap        = (PFN_glfwSwapBuffers)dlsym(s_glfw, "glfwSwapBuffers");
    p_swapint     = (PFN_glfwSwapInterval)dlsym(s_glfw, "glfwSwapInterval");
    p_poll        = (PFN_glfwPollEvents)dlsym(s_glfw, "glfwPollEvents");
    p_shouldclose = (PFN_glfwWindowShouldClose)dlsym(s_glfw, "glfwWindowShouldClose");
    p_settitle    = (PFN_glfwSetWindowTitle)dlsym(s_glfw, "glfwSetWindowTitle");
    p_fbsize      = (PFN_glfwGetFramebufferSize)dlsym(s_glfw, "glfwGetFramebufferSize");
    return (p_create != NULL && p_makecur != NULL && p_swap != NULL);
}

static int env_dim(const char *name, int fallback) {
    const char *v = getenv(name);
    if (v == NULL || v[0] == '\0') return fallback;
    int n = atoi(v);
    return n > 0 ? n : fallback;
}

/* 懒创建单例窗口：context.create 早于 Display.createWindow，故首个需要时即建。 */
static int ensure_window(void) {
    if (s_window != NULL) return 1;
    if (!load_glfw()) return 0;
    if (p_init != NULL) p_init();
    if (s_width  <= 0) s_width  = env_dim("AMCL_WINDOW_WIDTH", 1280);
    if (s_height <= 0) s_height = env_dim("AMCL_WINDOW_HEIGHT", 720);
    /* libglfw 内部读 AMCL_NATIVE_WINDOW 取 OHOS 原生窗口 */
    s_window = p_create(s_width, s_height, "Minecraft", NULL, NULL);
    A2LOG("ensure_window: created=%p requested=%dx%d", s_window, s_width, s_height);
    return s_window != NULL;
}

/* 前置声明：输入桥接段在本文件下方，而窗口生命周期回调在它上面。
 * typed 通道的激活必须挂在**窗口**边沿上（见下方 l2SetTypedChannelActive 的说明），
 * 所以这两个符号要在这里先声明一次。 */
static void resolve_input(void);
static void l2SetTypedChannelActive(int active);

/* ============================ AMCLDisplay ============================ */

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetDesktopWidth(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    return (jint)env_dim("AMCL_WINDOW_WIDTH", 1280);
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetDesktopHeight(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    return (jint)env_dim("AMCL_WINDOW_HEIGHT", 720);
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nCreateWindow(JNIEnv *env, jclass cls, jint width, jint height) {
    (void)env; (void)cls; (void)width; (void)height;
    /* 忽略 MC 请求的窗口尺寸：嵌入式全屏，窗口始终铺满 XComponent surface（env 提供的真实尺寸）。
     * libglfw 本就按真实 surface 建窗，这里用 env 尺寸保持 getWidth/Height 与之一致，避免 MC
     * 按小尺寸设 viewport 只渲染左下角。 */
    s_width = env_dim("AMCL_WINDOW_WIDTH", 1280);
    s_height = env_dim("AMCL_WINDOW_HEIGHT", 720);
    if (!ensure_window()) return JNI_FALSE;
    /* 窗口就绪之后才声明消费者活着：typed 通道会从"此刻"开始出货、不重放历史，
     * 所以这个边沿必须与窗口的存在对齐，而不是与第一次取事件对齐。 */
    l2SetTypedChannelActive(1);
    return JNI_TRUE;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nDestroyWindow(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    /* 先退订再销毁窗口：反过来会留下一个窗口已经不在、却仍在出货的通道。 */
    l2SetTypedChannelActive(0);
    if (s_window != NULL && p_destroy != NULL) {
        p_destroy(s_window);
        s_window = NULL;
    }
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nUpdate(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    if (p_poll != NULL) p_poll();
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nIsCloseRequested(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    if (s_window != NULL && p_shouldclose != NULL)
        return p_shouldclose(s_window) ? JNI_TRUE : JNI_FALSE;
    return JNI_FALSE;
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetWidth(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    /* 真实 surface 尺寸优先（env），保证 MC viewport 铺满；framebuffer 查询作兜底。 */
    int w = env_dim("AMCL_WINDOW_WIDTH", 0);
    if (w > 0) return (jint)w;
    if (s_window != NULL && p_fbsize != NULL) {
        int fw = 0, fh = 0; p_fbsize(s_window, &fw, &fh);
        if (fw > 0) return (jint)fw;
    }
    return (jint)(s_width > 0 ? s_width : 1280);
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetHeight(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    int h = env_dim("AMCL_WINDOW_HEIGHT", 0);
    if (h > 0) return (jint)h;
    if (s_window != NULL && p_fbsize != NULL) {
        int fw = 0, fh = 0; p_fbsize(s_window, &fw, &fh);
        if (fh > 0) return (jint)fh;
    }
    return (jint)(s_height > 0 ? s_height : 720);
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nSetTitle(JNIEnv *env, jclass cls, jstring title) {
    (void)cls;
    if (s_window == NULL || p_settitle == NULL || title == NULL) return;
    const char *t = (*env)->GetStringUTFChars(env, title, NULL);
    if (t != NULL) {
        p_settitle(s_window, t);
        (*env)->ReleaseStringUTFChars(env, title, t);
    }
}

/* ===================== 输入桥接（P2b）=====================
 * MC ≤1.12 用真·LWJGL2 的 poll+event 输入模型。这里桥接到 libglfw 的 input_bridge：
 *   - 当前光标：优先 dlsym inputBridge_getCursorSnapshot，一次取得同 epoch 的 X/Y；
 *     独立 X/Y getter 仅用于兼容旧 bridge。grab 状态仍由 inputBridge_setGrabState 统一管理。
 *   - 离散事件流（点击/按键/滚轮/字符）：dlsym inputBridge_l2NextEvent（LWJGL2 独立读序列，
 *     与 LWJGL3 pump 互不干扰）。
 *   - grab 切换汇入 bridge 权威状态；env 仅保留为旧组件镜像。
 * 键码翻译（GLFW→LWJGL2）与坐标系转换（absolute menu / grabbed poll-delta）保持在 Java 后端。 */
typedef double (*PFN_ib_getCursor)(void);
typedef void   (*PFN_ib_getCursorSnapshot)(double*, double*);
typedef int    (*PFN_ib_l2NextEvent)(int*, int*, int*, int*, int*);
typedef void   (*PFN_ib_setGrabState)(int);
typedef void   (*PFN_ib_l2SetActive)(int);
static PFN_ib_getCursorSnapshot p_ib_cursor_snapshot = NULL;
static PFN_ib_getCursor    p_ib_cx = NULL;
static PFN_ib_getCursor    p_ib_cy = NULL;
static PFN_ib_l2NextEvent  p_ib_next = NULL;
static PFN_ib_setGrabState p_ib_set_grab = NULL;
/* ⭐ typed 通道的显式激活（2026-09-05）。
 * 物理键/按钮/滚轮自 bit10 打开后**不再进 legacy ring**，它们只在宿主的 typed pull
 * 通道里；而那条通道要求消费者显式声明自己活着。SDL3 在它的 video init 里做这件事，
 * GLFW3 走自己的 ensureTypedInputOpen —— 只有本后端两者都不是，于是在
 * `1b6087d7` 删掉惰性激活兜底之后，MC ≤1.12 的实体键鼠**整体失效**
 * （真机 AMCL_BACKEND_INACTIVE backend=2 pulls=2048+，delivered 全程 0）。
 * ⚠️ 老宿主没有这个符号 ⇒ dlsym 返回 NULL ⇒ 调用点全部跳过，退化成改动前的行为。 */
static PFN_ib_l2SetActive  p_ib_l2_set_active = NULL;
/* Java 的所有调用点固定先读 X 再读 Y；X JNI 一次快照并缓存 Y，使两次 native 调用仍返回同一坐标 epoch。 */
static double s_cursor_snapshot_y = 0.0;
static int s_cursor_snapshot_y_valid = 0;
static int s_input_resolved = 0;

static void resolve_input(void) {
    if (s_input_resolved) return;
    if (!load_glfw()) return;
    p_ib_cursor_snapshot = (PFN_ib_getCursorSnapshot)dlsym(s_glfw, "inputBridge_getCursorSnapshot");
    p_ib_cx       = (PFN_ib_getCursor)dlsym(s_glfw, "inputBridge_getCursorX");
    p_ib_cy       = (PFN_ib_getCursor)dlsym(s_glfw, "inputBridge_getCursorY");
    p_ib_next     = (PFN_ib_l2NextEvent)dlsym(s_glfw, "inputBridge_l2NextEvent");
    p_ib_set_grab = (PFN_ib_setGrabState)dlsym(s_glfw, "inputBridge_setGrabState");
    p_ib_l2_set_active = (PFN_ib_l2SetActive)dlsym(s_glfw, "inputBridge_l2SetActive");
    s_input_resolved = 1;
    A2LOG("resolve_input: snapshot=%p cx=%p cy=%p next=%p setGrab=%p l2SetActive=%p",
          (void*)p_ib_cursor_snapshot, (void*)p_ib_cx, (void*)p_ib_cy,
          (void*)p_ib_next, (void*)p_ib_set_grab, (void*)p_ib_l2_set_active);
}

JNIEXPORT jdouble JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetCursorX(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    resolve_input();
    if (p_ib_cursor_snapshot != NULL) {
        double x = 0.0;
        p_ib_cursor_snapshot(&x, &s_cursor_snapshot_y);
        s_cursor_snapshot_y_valid = 1;
        return (jdouble)x;
    }
    return p_ib_cx != NULL ? (jdouble)p_ib_cx() : 0.0;
}

JNIEXPORT jdouble JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetCursorY(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    resolve_input();
    if (p_ib_cursor_snapshot != NULL) {
        if (s_cursor_snapshot_y_valid) {
            s_cursor_snapshot_y_valid = 0;
            return (jdouble)s_cursor_snapshot_y;
        }
        double x = 0.0, y = 0.0;
        p_ib_cursor_snapshot(&x, &y);
        return (jdouble)y;
    }
    return p_ib_cy != NULL ? (jdouble)p_ib_cy() : 0.0;
}

/* typed 通道的显式窗口生命周期边沿。老宿主没有这个符号 ⇒ 整条退化成改动前的行为
 * （届时物理键鼠仍然失效，但不会因为少一个符号而崩）。 */
static void l2SetTypedChannelActive(int active) {
    resolve_input();
    if (p_ib_l2_set_active == NULL) {
        A2LOG("l2SetTypedChannelActive(%d): host has no inputBridge_l2SetActive "
              "(old libglfw) -- physical keyboard/mouse/wheel will stay dead", active);
        return;
    }
    p_ib_l2_set_active(active);
    A2LOG("l2SetTypedChannelActive: %d", active);
}

/* 取下一个输入事件填入 out[0..4]={type,i1,i2,i3,i4}；有事件返回 true，队列空返回 false。 */
JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nNextEvent(JNIEnv *env, jclass cls, jintArray out) {
    (void)cls;
    resolve_input();
    if (p_ib_next == NULL) return JNI_FALSE;
    int t = 0, a = 0, b = 0, d = 0, f = 0;
    if (!p_ib_next(&t, &a, &b, &d, &f)) return JNI_FALSE;
    jint tmp[5];
    tmp[0] = (jint)t; tmp[1] = (jint)a; tmp[2] = (jint)b; tmp[3] = (jint)d; tmp[4] = (jint)f;
    (*env)->SetIntArrayRegion(env, out, 0, 5, tmp);
    return JNI_TRUE;
}

/* grab 切换：显式汇入 input_bridge 的唯一权威状态；env 只保留为旧组件镜像。 */
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nSetGrab(JNIEnv *env, jclass cls, jboolean grab) {
    (void)env; (void)cls;
    resolve_input();
    if (p_ib_set_grab != NULL) p_ib_set_grab(grab ? 1 : 0);
    setenv("AMCL_CURSOR_MODE", grab ? "grabbed" : "normal", 1);
    A2LOG("nSetGrab: %d (core=%s)", grab ? 1 : 0, p_ib_set_grab != NULL ? "yes" : "no");
}

/* ===================== AMCLContextImplementation ===================== */

JNIEXPORT jobject JNICALL Java_org_lwjgl_opengl_AMCLContextImplementation_nCreate(JNIEnv *env, jclass cls) {
    (void)cls;
    if (!ensure_window())
        return NULL;
    return (*env)->NewDirectByteBuffer(env, s_ctx_handle, (jlong)sizeof(s_ctx_handle));
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLContextImplementation_nSwapBuffers(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    if (s_window != NULL && p_swap != NULL) p_swap(s_window);
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLContextImplementation_nReleaseCurrentContext(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    if (p_makecur != NULL) p_makecur(NULL);
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLContextImplementation_nMakeCurrent(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    if (s_window != NULL && p_makecur != NULL) p_makecur(s_window);
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_AMCLContextImplementation_nIsCurrent(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    /* 单上下文模型：窗口存在即视为已绑定（精确判定可后续加 glfwGetCurrentContext）。 */
    return (s_window != NULL) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLContextImplementation_nSetSwapInterval(JNIEnv *env, jclass cls, jint value) {
    (void)env; (void)cls;
    if (p_swapint != NULL) p_swapint((int)value);
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLContextImplementation_nDestroy(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    /* 上下文随窗口；窗口在 nDestroyWindow 销毁。这里 no-op。 */
}

/* ================= DefaultSysImplementation（Sys 初始化必需）=================
 * 原在 linux/opengl/org_lwjgl_opengl_Display.c（X11 后端，已排除）里实现，故在此补齐。
 * getJNIVersion 必须与 AMCLSysImplementation.getRequiredJNIVersion() 一致 = 19。 */

JNIEXPORT jint JNICALL Java_org_lwjgl_DefaultSysImplementation_getJNIVersion(JNIEnv *env, jobject ignored) {
    (void)env; (void)ignored;
    return 19;
}

/* ================= OpenAL / OpenCL 平台实现（原在被排除的 native/linux/*）=================
 * P4（2026-06-13）：OpenAL 接上自带 libopenal.so（OpenAL-soft + OHAudio），见下方实现。
 * 缺这些符号时，common 里的 extal/extcl 引用是【未解析符号】，调用即跳非法地址 SIGSEGV
 * （1000164 真机实测崩点 = AL.nCreate → extal_LoadLibrary），故必须在此提供定义。 */

/* ================= OpenAL 平台实现（原在被排除的 native/linux/linux_al.c）=================
 * P4（2026-06-13）：接上自带的 libopenal.so（OpenAL-soft + OHAudio 后端，已随 HAP 打包到
 * bundle libs）。LWJGL2 的 org.lwjgl.openal.AL.create() 会用 getLibraryPaths 生成候选（含末尾
 * 裸 soname "libopenal.so"），逐个调 nCreate→extal_LoadLibrary；这里 dlopen 成功即把 AL/ALC
 * 函数指针经 extal_NativeGetFunctionPointer(dlsym) 解析出来。
 * 之前（1000164）为避开未解析符号 SIGSEGV 写成抛异常的桩 → 声音被 Paulscode 优雅禁用；现在
 * libopenal.so 已就绪，换成真实实现，老版本（≤1.12）即可出声。 */
static void *s_oal_handle = NULL;

void extal_LoadLibrary(JNIEnv *env, jstring path) {
    if (s_oal_handle != NULL) return;  /* 已加载（AL.create 循环候选，首个成功后无需重复）*/
    if (path != NULL) {
        const char *path_str = (*env)->GetStringUTFChars(env, path, NULL);
        if (path_str != NULL) {
            s_oal_handle = dlopen(path_str, RTLD_LAZY | RTLD_GLOBAL);
            A2LOG("extal_LoadLibrary: dlopen('%s') => %p", path_str, s_oal_handle);
            (*env)->ReleaseStringUTFChars(env, path, path_str);
        }
    }
    if (s_oal_handle == NULL) {
        /* 兜底：按 soname 直接 dlopen，OHOS 加载器在 app 命名空间查 libopenal.so（bundle libs）。 */
        s_oal_handle = dlopen("libopenal.so", RTLD_LAZY | RTLD_GLOBAL);
        A2LOG("extal_LoadLibrary: fallback dlopen('libopenal.so') => %p", s_oal_handle);
    }
    if (s_oal_handle == NULL) {
        /* 抛 LWJGLException → AL.create 捕获后尝试下一个候选；全失败才报 "Could not locate"。 */
        throwException(env, "Could not load OpenAL library (libopenal.so)");
    }
}

void *extal_NativeGetFunctionPointer(const char *function) {
    if (s_oal_handle == NULL) return NULL;
    return dlsym(s_oal_handle, function);
}

void extal_UnloadLibrary(void) {
    if (s_oal_handle != NULL) {
        dlclose(s_oal_handle);
        s_oal_handle = NULL;
    }
}

/* OpenCL（MC 不使用）：stub，避免未解析符号。 */
void *extcl_NativeGetFunctionPointer(const char *function) {
    (void)function;
    return NULL;
}
