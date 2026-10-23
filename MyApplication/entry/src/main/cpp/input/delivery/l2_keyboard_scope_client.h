// 独立Keyboard私有client：严格预线程PID、同module/exec/sizeof与原Core owner；不创建Ready。
/** Keyboard私有端口只读解析：核 exact getter 导出、同映像可执行方法、PID 和原 Core。
 * 环境缺失、旧表、外来表均 fail closed，不允许平台 namespace 创建新 singleton。 */
#ifndef AMCL_L2_KEYBOARD_SCOPE_CLIENT_H
#define AMCL_L2_KEYBOARD_SCOPE_CLIENT_H
#include "l2_keyboard_scope.h"
#include "control_delivery_client.h"
static inline int32_t amclL2KeyboardResolveV1(const AmclL2KeyboardPortV1** output) {
    if(output)*output=NULL;if(!output)return AMCL_CONTROL_REJECTED;
    const char* text=getenv(AMCL_L2_KEYBOARD_ENV);if(!text)return AMCL_CONTROL_NOT_READY;
    if(strncmp(text,AMCL_L2_KEYBOARD_PREFIX,sizeof(AMCL_L2_KEYBOARD_PREFIX)-1))return AMCL_CONTROL_REJECTED;
    const char* number=text+sizeof(AMCL_L2_KEYBOARD_PREFIX)-1;
    if(*number<'1'||*number>'9')return AMCL_CONTROL_REJECTED;
    char* end=NULL;errno=0;const unsigned long long announcedPid=strtoull(number,&end,10);
    if(errno||end==number||*end!=':'||!announcedPid||announcedPid>UINT32_MAX)return AMCL_CONTROL_REJECTED;
    // 环境描述符在预线程发布 PID，fork 子进程在任何 dladdr/loader/helper mutex 前拒绝。
#ifdef _WIN32
    const uint32_t process=(uint32_t)_getpid();
#else
    const uint32_t process=(uint32_t)getpid();
#endif
    if(announcedPid!=process)return AMCL_CONTROL_NOT_READY;
    number=end+1;if(*number<'1'||*number>'9')return AMCL_CONTROL_REJECTED;
    errno=0;const unsigned long long value=strtoull(number,&end,10);
    if(errno||end==number||*end||!value||value>=UINTPTR_MAX)return AMCL_CONTROL_REJECTED;
    const uintptr_t address=(uintptr_t)value;uintptr_t base=0;
#ifdef _WIN32
    HMODULE image=NULL;
    if(!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        (LPCSTR)address,&image)||(uintptr_t)GetProcAddress(image,"amclInputL2KeyboardGetPortV1")!=address)return AMCL_CONTROL_REJECTED;
    base=(uintptr_t)image;
#else
    Dl_info info;if(!dladdr((const void*)address,&info)||info.dli_saddr!=(void*)address||!info.dli_sname||
        strcmp(info.dli_sname,"amclInputL2KeyboardGetPortV1"))return AMCL_CONTROL_REJECTED;
    const char* leaf=info.dli_fname?strrchr(info.dli_fname,'/'):NULL;leaf=leaf?leaf+1:info.dli_fname;
#ifndef AMCL_CONTROL_DELIVERY_HOST_TESTING
    if(!leaf||strcmp(leaf,"libamcl_input_runtime.so"))return AMCL_CONTROL_REJECTED;
#else
    (void)leaf;
#endif
    base=(uintptr_t)info.dli_fbase;
#endif
    if(!amclControlAddressInOwner(address,base))return AMCL_CONTROL_REJECTED;
    typedef const AmclL2KeyboardPortV1*(*Getter)(void);
    const AmclL2KeyboardPortV1* port=((Getter)address)();
    if(!port||port->magic!=AMCL_L2_KEYBOARD_MAGIC||port->version!=1||port->size!=sizeof(*port)||
        port->processId!=process||!port->ownerHost)return AMCL_CONTROL_REJECTED;
#define AMCL_KEYBOARD_CHECK(name) if(!amclControlAddressInOwner((uintptr_t)port->name,base))return AMCL_CONTROL_REJECTED
    AMCL_KEYBOARD_CHECK(verifyOwner);AMCL_KEYBOARD_CHECK(completeCreate);AMCL_KEYBOARD_CHECK(fence);
    AMCL_KEYBOARD_CHECK(snapshot);AMCL_KEYBOARD_CHECK(validate);AMCL_KEYBOARD_CHECK(readCoreStamp);
    AMCL_KEYBOARD_CHECK(readHeldLegacy);AMCL_KEYBOARD_CHECK(readHeldTyped);
#undef AMCL_KEYBOARD_CHECK
    const int32_t result=port->verifyOwner(port->ownerHost);if(result<0)return result;*output=port;return 0;
}
#endif
