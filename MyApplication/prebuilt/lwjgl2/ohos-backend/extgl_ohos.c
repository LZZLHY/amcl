/*
 * extgl_ohos.c — LWJGL 2 GL 函数加载后端（HarmonyOS NEXT / AMCL 专用）
 *
 * 替代上游 src/native/linux/opengl/extgl_glx.c（其经 GLX/glXGetProcAddress 取桌面 GL 函数）。
 * OHOS 无 X11/GLX、无桌面 libGL，桌面 GL 由 gl4es（libgl4es.so，固定管线→GLES 翻译）提供。
 * 本文件把 LWJGL2 的 extgl 平台后端三件套（Open/Close/GetProcAddress）改为：
 *   - extgl_Open          : dlopen libgl4es.so（RTLD_GLOBAL，与 LWJGL3 路径同一实例）
 *   - extgl_GetProcAddress: 先 gl4es 的 GetProcAddress（若导出），再 dlsym(handle)，再 RTLD_DEFAULT
 *   - extgl_Close         : 不真正 dlclose（gl4es 单例随进程存活，避免悬空指针）
 *
 * 平台无关的 extgl_InitializeClass / extgl_InitializeFunctions / extgl_QueryExtension 仍由
 * src/native/common/opengl/extgl.c 提供（已在 P1 的 170 个 .o 内编译），本文件不重复定义。
 *
 * 方案见 docs/adaptation/LWJGL_MULTIVERSION_PLAN.md §11.13。
 */

#include <dlfcn.h>
#include <stddef.h>
#include "extgl.h"
/* gl4es 可选导出的解析器（Holy-GL4ES 提供）。运行时 dlsym 探测，不存在则回退 dlsym 符号表。 */
typedef void *(*gl4es_proc_resolver)(const char *name);

static void *s_gl4es_handle = NULL;
static gl4es_proc_resolver s_gl4es_resolver = NULL;

/* gl4es 库名：与 entry/libs/arm64-v8a/libgl4es.so 一致（HAP 签名 libs，系统 dlopen 可加载）。 */
#ifndef AMCL_GL4ES_SONAME
#define AMCL_GL4ES_SONAME "libgl4es.so"
#endif

bool extgl_Open(JNIEnv *env) {
    (void)env;
    if (s_gl4es_handle != NULL)
        return true;

    /* RTLD_NOLOAD 优先：若 mc_launcher 已 RTLD_GLOBAL 预加载 gl4es，则复用同一实例 */
    s_gl4es_handle = dlopen(AMCL_GL4ES_SONAME, RTLD_NOW | RTLD_GLOBAL | RTLD_NOLOAD);
    if (s_gl4es_handle == NULL)
        s_gl4es_handle = dlopen(AMCL_GL4ES_SONAME, RTLD_NOW | RTLD_GLOBAL);
    if (s_gl4es_handle == NULL)
        return false;

    /* 探测 gl4es 自带解析器（命名随 fork 可能不同，按优先级尝试）。 */
    s_gl4es_resolver = (gl4es_proc_resolver)dlsym(s_gl4es_handle, "gl4es_GetProcAddress");
    if (s_gl4es_resolver == NULL)
        s_gl4es_resolver = (gl4es_proc_resolver)dlsym(s_gl4es_handle, "gl4es_getProcAddress");
    return true;
}

void extgl_Close(void) {
    /* 故意不 dlclose：gl4es 是 RTLD_GLOBAL 单例，进程内 LWJGL3/老 MC 共用，
     * dlclose 会让已解析的 GL 函数指针悬空。随进程退出自然释放。 */
    s_gl4es_resolver = NULL;
    /* s_gl4es_handle 保留，便于二次 extgl_Open 复用 */
}

void *extgl_GetProcAddress(const char *name) {
    void *p;
    if (s_gl4es_handle == NULL) {
        if (!extgl_Open(NULL))
            return NULL;
    }
    /* 1) gl4es 自带解析器（最准，含其内部包装/扩展） */
    if (s_gl4es_resolver != NULL) {
        p = s_gl4es_resolver(name);
        if (p != NULL)
            return p;
    }
    /* 2) 直接从 gl4es 句柄符号表取（gl4es 直接导出 glBegin/glVertex3f 等桌面 GL 符号） */
    p = dlsym(s_gl4es_handle, name);
    if (p != NULL)
        return p;
    /* 3) 兜底：默认命名空间（极少用到） */
    return dlsym(RTLD_DEFAULT, name);
}
