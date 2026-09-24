/**
 * 仅供 Windows 宿主 JNI 回归的 dladdr 对应实现。
 * 用真实模块映射和 GetProcAddress 校验 getter 导出，不把测试地址一律当成有效。
 * 产品代码在 OHOS 使用系统 dladdr；此文件不会进入 CMake 的产品 include 路径。
 */
#ifndef AMCL_JNI_TEST_DLFCN_H
#define AMCL_JNI_TEST_DLFCN_H
#include <windows.h>
#include <string.h>
typedef struct {
    const char* dli_fname;
    void* dli_fbase;
    const char* dli_sname;
    void* dli_saddr;
} Dl_info;

static inline int dladdr(const void* address, Dl_info* info) {
    HMODULE module = NULL;
    MEMORY_BASIC_INFORMATION mapping;
    if (!VirtualQuery(address, &mapping, sizeof(mapping)) || mapping.State != MEM_COMMIT ||
        !(mapping.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) ||
        !GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)address, &module)) return 0;
    memset(info, 0, sizeof(*info));
    info->dli_fname = "host-fixture.dll";
    info->dli_fbase = module;
    const void* getter = (const void*)GetProcAddress(module, "amclCallbackBridgeHostGetV1");
    if (getter == address) {
        info->dli_sname = "amclCallbackBridgeHostGetV1";
        info->dli_saddr = (void*)getter;
    }
    return 1;
}
#endif
