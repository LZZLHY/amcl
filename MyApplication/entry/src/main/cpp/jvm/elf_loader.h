/**
 * elf_loader.h — HarmonyOS 签名绕过 ELF 共享库加载器
 *
 * 绕过内核 MAP_XPM 代码签名验证，从 filesDir 加载外部 .so 文件。
 * 原理：匿名 mmap + pread + mprotect(PROT_EXEC)
 * 需要 ALLOW_WRITABLE_CODE_MEMORY ACL 权限。
 *
 * 用于运行时下载并加载多版本 JDK（libjvm.so 等）。
 */

#ifndef ELF_LOADER_H
#define ELF_LOADER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 不透明句柄 */
typedef struct elf_handle elf_handle_t;

/**
 * 设置库搜索路径（冒号分隔）。
 * 当 elf_open 传入不含 '/' 的文件名时，按此路径搜索。
 * 示例: "/data/.../jdk/17/lib:/data/.../jdk/17/lib/server"
 */
void elf_set_search_path(const char* paths);

/**
 * 设置假的 /proc/self/exe 路径（JLI_Launch bypass）。
 * JLI 通过 readlink(/proc/self/exe) 获取可执行文件路径，在 OHOS 上读到
 * /system/bin/appspawn 导致 re-exec 失败。设置此路径后 ELF loader 拦截
 * readlink 返回假路径，让 JLI 跳过 re-exec。
 * @param path  例如 "/path/to/jdk/17/bin/java"，传 NULL 清除。
 */
void elf_set_fake_exe_path(const char* path);

/**
 * 加载 ELF 共享库。
 * @param path  库文件路径（全路径）或文件名（按搜索路径查找）
 * @return 句柄，失败返回 NULL。用 elf_error() 获取错误信息。
 */
elf_handle_t* elf_open(const char* path);

/**
 * 查找已加载库中的符号。
 * @param h     elf_open 返回的句柄
 * @param name  符号名
 * @return 符号地址，未找到返回 NULL
 */
void* elf_sym(elf_handle_t* h, const char* name);

/**
 * 在所有已加载的 ELF 库和系统库中查找符号。
 * 查找顺序：ELF 已加载库（按加载顺序） → dlsym(RTLD_DEFAULT)
 */
void* elf_sym_global(const char* name);

/**
 * 卸载库并释放资源。
 */
void elf_close(elf_handle_t* h);

/**
 * 获取最后一次错误信息（线程不安全，类似 dlerror）。
 */
const char* elf_error(void);

/* ================================================================
 * HotSpot 集成 API — dlopen/dlsym 的透明替代
 * HotSpot 的 os::dll_load() 调用这些函数。
 * 对于 HAP 内的库自动 fallback 到系统 dlopen。
 * ================================================================ */

/**
 * 智能加载：filesDir 路径 → ELF loader，其他 → dlopen。
 */
void* elf_dlopen(const char* path, int flags);

/**
 * 智能查找：先检查是否为 ELF 句柄，否则 dlsym。
 */
void* elf_dlsym(void* handle, const char* name);

/**
 * 智能卸载。
 */
void  elf_dlclose(void* handle);

/**
 * 加载一个目录下所有 .so 文件。
 * @return 成功加载的库数量
 */
int elf_load_directory(const char* dir);

/**
 * dladdr 兼容：解析地址到库名和符号名。
 * 先搜索 ELF-loaded 库，未找到则 fallback 到系统 dladdr。
 */
int elf_dladdr(const void* addr, void* info);

#ifdef __cplusplus
}
#endif

#endif /* ELF_LOADER_H */
