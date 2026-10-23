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
#include "control_delivery_client.h"

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
/* checked 入口与标准 GLFW 入口执行同一绑定核心，额外返回本次操作是否成功。
 * 不能用 GetCurrentContext 推断重复绑定的返回值：失败时原 context 仍可能 current。 */
typedef int (*PFN_glfwMakeContextCurrentChecked)(GLFWwindow*);
typedef GLFWwindow* (*PFN_glfwGetCurrentContext)(void);
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
static PFN_glfwMakeContextCurrentChecked p_makecur_checked = NULL;
static PFN_glfwGetCurrentContext   p_getcurrent = NULL;
static PFN_glfwSwapBuffers         p_swap = NULL;
static PFN_glfwSwapInterval        p_swapint = NULL;
static PFN_glfwPollEvents          p_poll = NULL;
static PFN_glfwWindowShouldClose   p_shouldclose = NULL;
static PFN_glfwSetWindowTitle      p_settitle = NULL;
static PFN_glfwGetFramebufferSize  p_fbsize = NULL;
// 建窗前从owner桥取成对尺寸，建窗后以GLFW已接纳的framebuffer为准，不再读可变env。
static void (*p_window_size_snapshot)(int*, int*) = NULL;

static GLFWwindow* s_window = NULL;
/* 真实L2输入初始化登记原窗口；上游GlobalLock串行跨线程API，只存lease/函数表。 */
static const AmclControlDeliveryPortV1* s_control_port = NULL;
static uint64_t s_control_consumer = 0;
static uint64_t s_control_target = 0;
/* 独立于旧Sys JNI版本的私有输入配对协议；仅实际AMCLDisplay初始化成功后置ready。
 * 不FindClass探测Display，不提前初始化游戏类，不把GLFW窗口存在当配对成功。 */
#define AMCL_L2_CONTROL_PROTOCOL ((jint)0x4c324431)
static int s_input_contract_ready = 0;

static int l2_require_input_class(JNIEnv* env, jclass cls) {
    jfieldID marker = (*env)->GetStaticFieldID(env, cls, "AMCL_CONTROL_PROTOCOL", "I");
    if (marker == NULL) {
        /* 缺字段是明确旧Java，不泄漏lookup异常后再继续旧transitionPlane路线。 */
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        throwException(env, "InputContractMismatch: LWJGL2 Java delivery marker missing");
        return 0;
    }
    if ((*env)->GetStaticIntField(env, cls, marker) != AMCL_L2_CONTROL_PROTOCOL) {
        throwException(env, "InputContractMismatch: LWJGL2 Java delivery protocol differs");
        return 0;
    }
    return 1;
}

static int l2_require_input_ready(JNIEnv* env) {
    if (s_input_contract_ready) return 1;
    throwException(env, "InputContractMismatch: LWJGL2 delivery handshake not initialized");
    return 0;
}
static int s_width = 0, s_height = 0;
/* context handle 占位（NewDirectByteBuffer 需指向有效内存；单例模型内容无意义）。 */
static unsigned char s_ctx_handle[16];

#ifndef AMCL_GLFW_SONAME
#define AMCL_GLFW_SONAME "libglfw.so"
#endif

static int load_glfw(void) {
    /* 库句柄存在不代表必需 ABI 已完整解析；缺少 checked/current 入口时拒绝创建，
     * 避免新 JNI 与旧 GLFW 混装后又退回无法反馈失败的 void 调用。句柄保留到进程退出。 */
    if (s_glfw != NULL)
        return p_create != NULL && p_makecur_checked != NULL && p_getcurrent != NULL && p_swap != NULL;
    s_glfw = dlopen(AMCL_GLFW_SONAME, RTLD_NOW | RTLD_GLOBAL | RTLD_NOLOAD);
    if (s_glfw == NULL) s_glfw = dlopen(AMCL_GLFW_SONAME, RTLD_NOW | RTLD_GLOBAL);
    if (s_glfw == NULL) return 0;
    p_init        = (PFN_glfwInit)dlsym(s_glfw, "glfwInit");
    p_create      = (PFN_glfwCreateWindow)dlsym(s_glfw, "glfwCreateWindow");
    p_destroy     = (PFN_glfwDestroyWindow)dlsym(s_glfw, "glfwDestroyWindow");
    p_makecur_checked = (PFN_glfwMakeContextCurrentChecked)dlsym(s_glfw, "glfwOHOS_MakeContextCurrentChecked");
    p_getcurrent  = (PFN_glfwGetCurrentContext)dlsym(s_glfw, "glfwGetCurrentContext");
    p_swap        = (PFN_glfwSwapBuffers)dlsym(s_glfw, "glfwSwapBuffers");
    p_swapint     = (PFN_glfwSwapInterval)dlsym(s_glfw, "glfwSwapInterval");
    p_poll        = (PFN_glfwPollEvents)dlsym(s_glfw, "glfwPollEvents");
    p_shouldclose = (PFN_glfwWindowShouldClose)dlsym(s_glfw, "glfwWindowShouldClose");
    p_settitle    = (PFN_glfwSetWindowTitle)dlsym(s_glfw, "glfwSetWindowTitle");
    p_fbsize      = (PFN_glfwGetFramebufferSize)dlsym(s_glfw, "glfwGetFramebufferSize");
    p_window_size_snapshot = (void (*)(int*, int*))dlsym(s_glfw, "inputBridge_getWindowSizeSnapshot");
    return p_create != NULL && p_makecur_checked != NULL && p_getcurrent != NULL && p_swap != NULL;
}

static void read_dimensions(int *outWidth, int *outHeight) {
    int width = 0, height = 0;
    if (load_glfw()) {
        if (s_window != NULL && p_fbsize != NULL) p_fbsize(s_window, &width, &height);
        else if (p_window_size_snapshot != NULL) p_window_size_snapshot(&width, &height);
    }
    *outWidth = width > 0 ? width : 1280;
    *outHeight = height > 0 ? height : 720;
}

/* 懒创建单例窗口：context.create 早于 Display.createWindow，故首个需要时即建。 */
static int ensure_window(void) {
    if (s_window != NULL) return 1;
    if (!load_glfw()) return 0;
    if (p_init != NULL) p_init();
    if (s_width <= 0 || s_height <= 0) read_dimensions(&s_width, &s_height);
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

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nInputContract(JNIEnv* env, jclass cls, jint protocol) {
    if (!l2_require_input_class(env, cls)) return 0;
    if (protocol != AMCL_L2_CONTROL_PROTOCOL) {
        throwException(env, "InputContractMismatch: LWJGL2 native delivery protocol differs");
        return 0;
    }
    s_input_contract_ready = 1;
    return AMCL_L2_CONTROL_PROTOCOL;
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetDesktopWidth(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    int width = 0, height = 0; read_dimensions(&width, &height);
    return (jint)width;
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetDesktopHeight(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    int width = 0, height = 0; read_dimensions(&width, &height);
    return (jint)height;
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nCreateWindow(JNIEnv *env, jclass cls, jint width, jint height) {
    (void)env; (void)cls; (void)width; (void)height;
    if (!l2_require_input_class(env, cls) || !l2_require_input_ready(env)) return JNI_FALSE;
    /* 忽略 MC 请求的窗口尺寸：嵌入式全屏，窗口始终铺满 XComponent surface（owner API 提供的真实尺寸）。
     * libglfw 本就按真实 surface 建窗，这里用成对快照保持 getWidth/Height 与之一致，避免 MC
     * 按小尺寸设 viewport 只渲染左下角。 */
    read_dimensions(&s_width, &s_height);
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
    /* Java正常先报告每条未读记录discarded；异常销毁仍关闭原consumer，旧票不能重绑新窗口。 */
    if (s_control_port != NULL && s_control_consumer != 0) {
        s_control_port->abandon(s_control_consumer);
        s_control_port->close(s_control_consumer);
        s_control_consumer = 0;
        s_control_target = 0;
    }
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
    int width = 0, height = 0;
    read_dimensions(&width, &height);
    return (jint)width;
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nGetHeight(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    int width = 0, height = 0;
    read_dimensions(&width, &height);
    return (jint)height;
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
    if (!l2_require_input_class(env, cls) || !l2_require_input_ready(env)) return JNI_FALSE;
    resolve_input();
    if (p_ib_next == NULL) return JNI_FALSE;
    int t = 0, a = 0, b = 0, d = 0, f = 0;
    if (!p_ib_next(&t, &a, &b, &d, &f)) return JNI_FALSE;
    jint tmp[5];
    tmp[0] = (jint)t; tmp[1] = (jint)a; tmp[2] = (jint)b; tmp[3] = (jint)d; tmp[4] = (jint)f;
    (*env)->SetIntArrayRegion(env, out, 0, 5, tmp);
    return JNI_TRUE;
}

/* ===================== 末级控制私有JNI =====================
 * Java一次完成legacy编码，再把backend-native control送给neutral唯一owner。
 * emission旁带完整保留consumer/activation/revision/ticket/target，旧五整数Next不改义。
 * STATE_ONLY由Java真实缓存write后报告，PULL_COMMITTED只由实际Keyboard/Mouse next报告。
 */

/* 转换只负责ABI字节，不在JNI维护按键数组；输出长度不符拒绝而不截断ticket身份。 */
static int control_write_emission(JNIEnv* env, jlongArray output, const AmclControlEmissionV1* e) {
    if (output == NULL || (*env)->GetArrayLength(env, output) != 9) return 0;
    const jlong values[9] = {(jlong)e->kind, (jlong)e->code, (jlong)e->scanCode, (jlong)e->action,
        (jlong)e->consumer, (jlong)e->activation, (jlong)e->revision, (jlong)e->ticket, (jlong)e->target};
    (*env)->SetLongArrayRegion(env, output, 0, 9, values);
    return !(*env)->ExceptionCheck(env);
}

static int control_read_emission(JNIEnv* env, jlongArray input, AmclControlEmissionV1* e) {
    if (input == NULL || (*env)->GetArrayLength(env, input) != 9) return 0;
    jlong values[9];
    (*env)->GetLongArrayRegion(env, input, 0, 9, values);
    if ((*env)->ExceptionCheck(env)) return 0;
    memset(e, 0, sizeof(*e)); e->size = sizeof(*e);
    e->kind = (uint32_t)values[0]; e->code = (int32_t)values[1];
    e->scanCode = (int32_t)values[2]; e->action = (int32_t)values[3];
    e->consumer = (uint64_t)values[4]; e->activation = (uint64_t)values[5];
    e->revision = (uint64_t)values[6]; e->ticket = (uint64_t)values[7]; e->target = (uint64_t)values[8];
    return 1;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nControlOpen(JNIEnv* env, jclass cls) {
    (void)env; (void)cls;
    if (!l2_require_input_class(env, cls) || !l2_require_input_ready(env)) return 0;
    if (s_window == NULL) return 0;
    if (s_control_consumer != 0) return s_control_target == (uint64_t)(uintptr_t)s_window ? (jlong)s_control_consumer : 0;
    /* 坏描述符必须失败，不经dlsym另寻fallback；表和逐函数身份均由薄client验证。 */
    if (amclControlDeliveryResolveV1(&s_control_port) < 0) return 0;
    if (s_control_port->open(2, (uint64_t)(uintptr_t)s_window, &s_control_consumer) < 0) return 0;
    s_control_target = (uint64_t)(uintptr_t)s_window;
    return (jlong)s_control_consumer;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nControlClose(JNIEnv* env, jclass cls, jlong consumer) {
    (void)env; (void)cls;
    if (s_control_port == NULL || (uint64_t)consumer != s_control_consumer) return;
    s_control_port->abandon(s_control_consumer); s_control_port->close(s_control_consumer);
    s_control_consumer = 0; s_control_target = 0;
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nControlApply(JNIEnv* env, jclass cls,
        jlong consumer, jint plane, jint kind, jint code, jint scan, jint action, jlongArray output) {
    (void)cls;
    if (s_control_port == NULL || s_window == NULL || s_control_target != (uint64_t)(uintptr_t)s_window ||
        (uint64_t)consumer != s_control_consumer) return AMCL_CONTROL_STALE;
    if ((plane != 1 && plane != 2) || (kind != 1 && kind != 2) || code < 0 ||
        (kind == 1 ? code >= 256 : code >= 16) || output == NULL ||
        (*env)->GetArrayLength(env, output) != 9) return AMCL_CONTROL_REJECTED;
    AmclControlEmissionV1 emission;
    int32_t result = s_control_port->apply((uint64_t)consumer, (uint32_t)plane, 0,
        (uint32_t)kind, code, scan, action, &emission);
    if (result == AMCL_CONTROL_EDGE) {
        result = s_control_port->claim(&emission);
        if (result == AMCL_CONTROL_EDGE && !control_write_emission(env, output, &emission)) {
            s_control_port->complete(&emission, AMCL_CONTROL_DISCARDED);
            return AMCL_CONTROL_REJECTED;
        }
    }
    return result;
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nControlRetire(JNIEnv* env, jclass cls,
        jlong consumer, jint mask, jint kind) {
    (void)env; (void)cls;
    if (s_control_port == NULL || s_window == NULL || s_control_target != (uint64_t)(uintptr_t)s_window ||
        (uint64_t)consumer != s_control_consumer) return AMCL_CONTROL_STALE;
    return s_control_port->retireKind((uint64_t)consumer, (uint32_t)mask, 0, 0, (uint32_t)kind);
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nControlNextRetired(JNIEnv* env, jclass cls,
        jlong consumer, jlongArray output) {
    (void)cls;
    if (s_control_port == NULL || s_window == NULL || s_control_target != (uint64_t)(uintptr_t)s_window ||
        (uint64_t)consumer != s_control_consumer) return AMCL_CONTROL_STALE;
    if (output == NULL || (*env)->GetArrayLength(env, output) != 9) return AMCL_CONTROL_REJECTED;
    AmclControlEmissionV1 emission;
    int32_t result = s_control_port->nextRetired((uint64_t)consumer, &emission);
    if (result == AMCL_CONTROL_EDGE) {
        result = s_control_port->claim(&emission);
        if (result == AMCL_CONTROL_EDGE && !control_write_emission(env, output, &emission)) {
            s_control_port->complete(&emission, AMCL_CONTROL_DISCARDED);
            return AMCL_CONTROL_REJECTED;
        }
    }
    return result;
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nControlComplete(JNIEnv* env, jclass cls,
        jlongArray input, jint phase) {
    (void)cls; AmclControlEmissionV1 emission;
    /* 上游真实poll/next/create/destroy共用GlobalLock，沿旧API允许不同线程串行执行。
     * 只报告原票事实，不添加创建线程权限；旧完成不能覆盖reentry或新target的实际缓存。 */
    if (s_control_port == NULL || !control_read_emission(env, input, &emission))
        return AMCL_CONTROL_STALE;
    /* 旧票完成按它原consumer计事实；port不会让旧cache覆盖reentry或新activation。 */
    return s_control_port->complete(&emission, (uint32_t)phase);
}

/* JNI坐标查询可同步重入；序列化前只读核旧ticket，不重复claim、不改绑当前窗口。 */
JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nControlValidate(JNIEnv* env, jclass cls,
        jlongArray input) {
    (void)cls; AmclControlEmissionV1 emission;
    if (s_control_port == NULL || s_window == NULL || s_control_target != (uint64_t)(uintptr_t)s_window ||
        !control_read_emission(env, input, &emission)) return AMCL_CONTROL_STALE;
    return s_control_port->validate(&emission);
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nControlObservePoll(JNIEnv* env, jclass cls,
        jlong consumer, jint kind, jint code, jboolean held) {
    (void)env; (void)cls;
    if (s_control_port == NULL || (uint64_t)consumer != s_control_consumer)
        return AMCL_CONTROL_STALE;
    return s_control_port->observePoll((uint64_t)consumer, (uint32_t)kind, code, held ? 1 : 0);
}

/* 真正Keyboard/Mouse.poll取得direct缓存后一次观测；不复制Java状态、不循环JNI/owner锁。
 * offset/count是原ByteBuffer实际view，容量检查先于指针偏移，不能把原buffer游标偷改为零。 */
JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nControlObservePollView(JNIEnv* env, jclass cls,
        jlong consumer, jint kind, jobject buffer, jint offset, jint count) {
    (void)cls;
    if (s_control_port == NULL || (uint64_t)consumer != s_control_consumer)
        return AMCL_CONTROL_STALE;
    if (buffer == NULL || (kind != 1 && kind != 2) || offset < 0 || count < 0 ||
        (kind == 1 ? count > 256 : count > 16)) return AMCL_CONTROL_REJECTED;
    const jlong capacity = (*env)->GetDirectBufferCapacity(env, buffer);
    const uint8_t* states = (const uint8_t*)(*env)->GetDirectBufferAddress(env, buffer);
    if (states == NULL || capacity < offset || capacity - offset < count) return AMCL_CONTROL_REJECTED;
    return s_control_port->observePollView((uint64_t)consumer, (uint32_t)kind, states + offset, (uint32_t)count);
}

/* 只读测试/诊断快照不推进owner或next；字段顺序与私有SnapshotV1对应。 */
JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nControlSnapshot(JNIEnv* env, jclass cls,
        jlong consumer, jlongArray output) {
    (void)cls;
    if (s_control_port == NULL || output == NULL || (*env)->GetArrayLength(env, output) != 14)
        return AMCL_CONTROL_REJECTED;
    AmclControlSnapshotV1 snapshot; memset(&snapshot, 0, sizeof(snapshot)); snapshot.size = sizeof(snapshot);
    const int32_t result = s_control_port->snapshot((uint64_t)consumer, &snapshot);
    if (result < 0) return result;
    const jlong values[14] = {(jlong)snapshot.consumer, (jlong)snapshot.activation,
        (jlong)snapshot.accepted, (jlong)snapshot.noEdge, (jlong)snapshot.edges,
        (jlong)snapshot.callbackReturned, (jlong)snapshot.pullCommitted, (jlong)snapshot.stateOnly,
        (jlong)snapshot.legalPollReads, (jlong)snapshot.pollMismatches, (jlong)snapshot.staleCompletions,
        (jlong)snapshot.lastCompletedActivation, (jlong)snapshot.uncertain, (jlong)snapshot.discarded};
    (*env)->SetLongArrayRegion(env, output, 0, 14, values); return result;
}

/* grab 切换：显式汇入 input_bridge 的唯一权威状态；不再维护无读者的环境变量镜像。 */
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLDisplay_nSetGrab(JNIEnv *env, jclass cls, jboolean grab) {
    (void)env; (void)cls;
    resolve_input();
    if (p_ib_set_grab != NULL) p_ib_set_grab(grab ? 1 : 0);
    A2LOG("nSetGrab: %d (core=%s)", grab ? 1 : 0, p_ib_set_grab != NULL ? "yes" : "no");
}

/* ===================== AMCLContextImplementation ===================== */

JNIEXPORT jobject JNICALL Java_org_lwjgl_opengl_AMCLContextImplementation_nCreate(JNIEnv *env, jclass cls) {
    (void)cls;
    /* Context懒建窗虽早于Display.createWindow，但合法Display静态初始化已实际握手。
     * 旧Java不能由Context路径绕开AMCLDisplay配对检查；此处不加载另一个游戏类。 */
    if (!l2_require_input_ready(env)) return NULL;
    if (!ensure_window())
        return NULL;
    return (*env)->NewDirectByteBuffer(env, s_ctx_handle, (jlong)sizeof(s_ctx_handle));
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLContextImplementation_nSwapBuffers(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    if (s_window != NULL && p_swap != NULL) p_swap(s_window);
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLContextImplementation_nReleaseCurrentContext(JNIEnv *env, jclass cls) {
    (void)cls;
    /* release 在调用线程执行；失败必须保持 Java 的 TLS/owner，因此通过既有
     * LWJGLException 通道中止上层提交。其他窗口的 current 不属于此单例，不越权释放。 */
    if (p_makecur_checked == NULL || p_getcurrent == NULL) {
        throwException(env, "AMCL LWJGL2: checked context ABI unavailable");
        return;
    }
    GLFWwindow* current = p_getcurrent();
    if (current != NULL && current != s_window) {
        throwException(env, "AMCL LWJGL2: refusing to release another window context");
        return;
    }
    if (!p_makecur_checked(NULL) || p_getcurrent() != NULL)
        throwException(env, "AMCL LWJGL2: context release failed; ownership retained");
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_AMCLContextImplementation_nMakeCurrent(JNIEnv *env, jclass cls) {
    (void)cls;
    /* 只有驱动操作成功且 GLFW 的本线程 current 与单例相符才向 Java 返回成功。
     * 包含原本已绑定目标的重复调用失败；不临时替换进程级错误回调，也不读遗留 EGL 错误。 */
    if (s_window == NULL || p_makecur_checked == NULL || p_getcurrent == NULL) {
        throwException(env, "AMCL LWJGL2: context or checked binding ABI unavailable");
        return;
    }
    if (!p_makecur_checked(s_window) || p_getcurrent() != s_window)
        throwException(env, "AMCL LWJGL2: context binding failed; ownership unchanged");
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_AMCLContextImplementation_nIsCurrent(JNIEnv *env, jclass cls) {
    (void)cls;
    /* 窗口存在只证明资源已创建；current 属于线程。成功 release 或从未绑定的线程
     * 必须得到 false，且不能把另一个 GLFW 窗口的 context 当作 LWJGL2 单例。 */
    if (s_window == NULL) return JNI_FALSE;
    if (p_getcurrent == NULL) {
        throwException(env, "AMCL LWJGL2: current-context query ABI unavailable");
        return JNI_FALSE;
    }
    return p_getcurrent() == s_window ? JNI_TRUE : JNI_FALSE;
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
