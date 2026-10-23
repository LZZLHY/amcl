/**
 * SDL/LWJGL2 私有诊断借用层。
 * 只在原 control/look 冷握手已成功之后解析一次可选诊断表；不创建输入 owner、
 * 不重新读取环境描述符、不加载或 pin DSO。缺席、旧版本、foreign provider 与 PID
 * 不符都只关闭诊断，原 prepare/claim/cache/complete/poll 返回值继续由原端口裁决。
 */
#ifndef AMCL_INPUT_LATENCY_CLIENT_H
#define AMCL_INPUT_LATENCY_CLIENT_H
#include "input_latency_observation.h"
#include "delivery/look_execution_client.h"

/** fork 后旧表不复活；只读 PID 用于丢诊断，不参与原输入资格或线程裁决。 */
static inline uint32_t amclInputLatencyClientPidV2(void) {
#ifdef _WIN32
    return (uint32_t)_getpid();
#else
    return (uint32_t)getpid();
#endif
}

/**
 * verifiedLook/verifiedControl 必须是调用方已经通过原 resolver 全部验证的同 owner
 * 表；本函数不替代原握手。先定位该 look 的真实代码映像，再从同一映像借新 getter。
 * 成功只借一个只读表；调用方保存 attempted 事实，缺席不在输入热路径循环重试。
 * output 总是先清空，所有失败返回 0；它从不成为生产 input NotReady/Rejected。
 */
static inline int amclInputLatencyResolveV2(const AmclLookExecutionPortV1* verifiedLook,
        const AmclControlDeliveryPortV1* verifiedControl, const AmclInputLatencyPortV2** output) {
    uintptr_t base = 0, address = 0;
    uint32_t process = 0;
    typedef const AmclInputLatencyPortV2* (*Getter)(void);
    if (output) *output = NULL;
    if (!output || !verifiedLook || !verifiedControl || !verifiedLook->ownerHost ||
        verifiedLook->ownerHost != verifiedControl->ownerHost || !verifiedLook->verifyOwner) return 0;
#ifdef _WIN32
    HMODULE image = NULL;
    if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCSTR)(uintptr_t)verifiedLook->verifyOwner, &image)) return 0;
    base = (uintptr_t)image;
    address = (uintptr_t)GetProcAddress(image, "inputBridge_getInputLatencyPortV2");
    process = (uint32_t)_getpid();
#else
    Dl_info original = {0}, getter = {0};
    if (!dladdr((const void*)verifiedLook->verifyOwner, &original) || !original.dli_fbase) return 0;
    base = (uintptr_t)original.dli_fbase;
    /* RTLD_DEFAULT 不新开 handle；不同 namespace 未暴露 getter 时保守关闭诊断。
     * 即使同名导出先解析到另一个真实映像，也须先拒绝，绝不能调用 foreign getter。 */
    address = (uintptr_t)dlsym(RTLD_DEFAULT, "inputBridge_getInputLatencyPortV2");
    if (!address || !dladdr((const void*)address, &getter) || getter.dli_fbase != original.dli_fbase ||
        getter.dli_saddr != (void*)address || !getter.dli_sname ||
        strcmp(getter.dli_sname, "inputBridge_getInputLatencyPortV2") != 0) return 0;
    process = (uint32_t)getpid();
#endif
    if (!address || !amclControlAddressInOwner(address, base)) return 0;
    const AmclInputLatencyPortV2* port = ((Getter)address)();
    if (!port || port->magic != AMCL_INPUT_LATENCY_PORT_MAGIC_V2 || port->version != 2 ||
        port->size != sizeof(*port) || port->pid != process ||
        port->ownerHost != verifiedLook->ownerHost ||
        !amclControlAddressInOwner((uintptr_t)port->note, base) ||
        !amclControlAddressInOwner((uintptr_t)port->finish, base)) return 0;
    *output = port;
    return 1;
}
#endif
