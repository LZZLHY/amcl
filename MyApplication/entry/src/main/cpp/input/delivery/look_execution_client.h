/** 跨DSO look端口只读身份检查；复用control映像/可执行地址探针，不复制执行状态。 */
#ifndef AMCL_LOOK_EXECUTION_CLIENT_H
#define AMCL_LOOK_EXECUTION_CLIENT_H
#include "look_execution.h"
#include "control_delivery_client.h"
static inline int32_t amclLookExecutionResolveV1(const AmclLookExecutionPortV1** output){
    if(output)*output=NULL;if(!output)return AMCL_LOOK_REJECTED;
    const char* text=getenv(AMCL_LOOK_EXECUTION_ENV);if(!text)return AMCL_LOOK_NOT_READY;
    if(strncmp(text,AMCL_LOOK_EXECUTION_PREFIX,sizeof(AMCL_LOOK_EXECUTION_PREFIX)-1)!=0)return AMCL_LOOK_REJECTED;
    const char* number=text+sizeof(AMCL_LOOK_EXECUTION_PREFIX)-1;if(*number<'0'||*number>'9')return AMCL_LOOK_REJECTED;
    char* end=NULL;errno=0;const unsigned long long value=strtoull(number,&end,10);
    if(errno||end==number||*end||!value||value>=UINTPTR_MAX)return AMCL_LOOK_REJECTED;
    const uintptr_t address=(uintptr_t)value;uintptr_t base=0;uint32_t process=0;
#ifdef _WIN32
    HMODULE image=NULL;
    if(!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        (LPCSTR)address,&image)||(uintptr_t)GetProcAddress(image,"amclLookExecutionGetPortV1")!=address)return AMCL_LOOK_REJECTED;
    base=(uintptr_t)image;process=(uint32_t)_getpid();
#else
    Dl_info info;if(!dladdr((const void*)address,&info)||info.dli_saddr!=(void*)address||!info.dli_sname||
        strcmp(info.dli_sname,"amclLookExecutionGetPortV1")!=0)return AMCL_LOOK_REJECTED;
    const char* leaf=info.dli_fname?strrchr(info.dli_fname,'/'):NULL;leaf=leaf?leaf+1:info.dli_fname;
#ifndef AMCL_CONTROL_DELIVERY_HOST_TESTING
    if(!leaf||strcmp(leaf,"libamcl_input_runtime.so")!=0)return AMCL_LOOK_REJECTED;
#else
    (void)leaf;
#endif
    base=(uintptr_t)info.dli_fbase;process=(uint32_t)getpid();
#endif
    if(!amclControlAddressInOwner(address,base))return AMCL_LOOK_REJECTED;
    typedef const AmclLookExecutionPortV1*(*Getter)(void);const AmclLookExecutionPortV1* port=((Getter)address)();
    if(!port||port->magic!=AMCL_LOOK_EXECUTION_MAGIC||port->version!=1||port->size!=sizeof(*port)||
        port->pid!=process||!port->ownerHost)return AMCL_LOOK_REJECTED;
#define AMCL_LOOK_CHECK(name) if(!amclControlAddressInOwner((uintptr_t)port->name,base))return AMCL_LOOK_REJECTED
    AMCL_LOOK_CHECK(verifyOwner);AMCL_LOOK_CHECK(bindSession);AMCL_LOOK_CHECK(publishMode);AMCL_LOOK_CHECK(applyPolicy);
    AMCL_LOOK_CHECK(openStream);AMCL_LOOK_CHECK(submitDelta);AMCL_LOOK_CHECK(submitVelocity);AMCL_LOOK_CHECK(advance);
    AMCL_LOOK_CHECK(sealPrefix);AMCL_LOOK_CHECK(retireStream);AMCL_LOOK_CHECK(retirePrefix);AMCL_LOOK_CHECK(bindConsumer);
    AMCL_LOOK_CHECK(prepare);AMCL_LOOK_CHECK(claim);AMCL_LOOK_CHECK(validate);AMCL_LOOK_CHECK(complete);
    AMCL_LOOK_CHECK(observePoll);AMCL_LOOK_CHECK(snapshot);AMCL_LOOK_CHECK(closeConsumer);
    AMCL_LOOK_CHECK(abandonPrefix);
    AMCL_LOOK_CHECK(physicalPrefix);
    AMCL_LOOK_CHECK(physicalPrefixByOrder);AMCL_LOOK_CHECK(setBackendActive);
#undef AMCL_LOOK_CHECK
    // 唯一Core descriptor核验是独立必要条件，另一个真实DSO也不能借同PID/合法代码骗owner。
    const int32_t result=port->verifyOwner(port->ownerHost);if(result<0)return result;*output=port;return 0;
}
#endif
