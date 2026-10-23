/*
 * LWJGL2 的 GL 函数查询适配。窗口由 GLFW 管理，函数地址消费已冻结的中立运行时，
 * 保证旧版 JNI 与 GLFW context 属于同一 provider/对象域。本适配只接受已经支持的
 * gl4es 计划；不能通过改库名放开 LWJGL2/nativegl，也不回退全局符号表。
 * 运行库保留到进程退出，逻辑 close 不释放已经交给 Java 的函数地址。
 */
#include <dlfcn.h>
#include <stddef.h>
#include <string.h>
#include "extgl.h"

typedef void *(*amcl_gl_proc)(const char *name);
typedef const char *(*amcl_bound_profile)(void);
static void *s_runtime_handle = NULL;
static amcl_gl_proc s_runtime_proc = NULL;
static amcl_bound_profile s_runtime_profile = NULL;

/* 首次只装入中立 facade；另一 namespace 的映像仍通过公开 ABI 转发到本 PID
 * 唯一 owner。缺入口、未冻结或 profile 不符均失败，不装入另一翻译器。 */
bool extgl_Open(JNIEnv *env) {
    (void)env;
    if (s_runtime_handle == NULL)
        s_runtime_handle = dlopen("libamcl_graphics_runtime.so", RTLD_NOW | RTLD_LOCAL);
    if (s_runtime_handle == NULL) return false;
    if (s_runtime_proc == NULL)
        s_runtime_proc = (amcl_gl_proc)dlsym(s_runtime_handle, "amclGraphicsGlProcV1");
    if (s_runtime_profile == NULL)
        s_runtime_profile = (amcl_bound_profile)dlsym(s_runtime_handle, "amclGraphicsBoundProfileV1");
    const char *profile = s_runtime_profile != NULL ? s_runtime_profile() : NULL;
    return s_runtime_proc != NULL && profile != NULL && strcmp(profile, "gl4es") == 0;
}

/* LWJGL 的逻辑 close 不改变冻结身份；后续 open 仍验证 owner 的当前 PID/profile。
 * 不清空解析器、不 dlclose，避免在同一游戏进程中制造另一 provider 或悬空地址。 */
void extgl_Close(void) {
}

/* 每次查询先验证冻结身份；空名称或空函数地址原样拒绝，不能从系统或全局符号表
 * 捞取同名入口，否则 context 与 GL 指令会重新分裂到不同对象域。 */
void *extgl_GetProcAddress(const char *name) {
    if (name == NULL || name[0] == '\0' || !extgl_Open(NULL)) return NULL;
    return s_runtime_proc(name);
}
