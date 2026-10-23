// 跨namespace的薄C身份检查层，仅发现/验证neutral生产端口，不复制任何owner或归约状态。
// SDL/L2在自己的合法初始化点使用；缺席与损坏分开，坏描述符不能绕dlsym另开第二份owner。
#ifndef AMCL_CONTROL_DELIVERY_CLIENT_H
#define AMCL_CONTROL_DELIVERY_CLIENT_H
#include "control_delivery.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#ifdef _WIN32
#include <windows.h>
#include <process.h>
#else
#include <dlfcn.h>
#include <link.h>
#include <unistd.h>
#endif

#ifndef _WIN32
// dl_iterate_phdr的一次只读查询上下文：address为待调用函数地址，executable仅由
// 实际PT_LOAD/PF_X覆盖事实置true。不持有DSO引用，调用方另负责进程期pin。
typedef struct AmclControlAddressCheck {uintptr_t address;int executable;} AmclControlAddressCheck;
// 输入为加载器枚举的单个映像及上述上下文；找到可执行段就停止枚举并返回1。
// 段起点先防整数溢出，不按函数名/PID猜可执行资格，也不把未覆盖地址当成功。
static int amclControlVisitExecutable(struct dl_phdr_info* info,size_t size,void* data){
    AmclControlAddressCheck* check=(AmclControlAddressCheck*)data;(void)size;
    for(size_t i=0;i<info->dlpi_phnum;++i){const ElfW(Phdr)* p=&info->dlpi_phdr[i];
        if(p->p_type!=PT_LOAD||!(p->p_flags&PF_X)||p->p_vaddr>UINTPTR_MAX-(uintptr_t)info->dlpi_addr)continue;
        const uintptr_t start=(uintptr_t)info->dlpi_addr+(uintptr_t)p->p_vaddr;
        if(check->address>=start&&check->address-start<p->p_memsz){check->executable=1;return 1;}}
    return 0;
}
#endif
// 输入为函数地址和已经选定的neutral映像base，输出只表示同映像且可执行。
// Windows核实际HMODULE/提交页面权限，POSIX核dladdr base和真实ELF PT_LOAD/PF_X。
// 不打开/卸载库、不执行被检函数；借出的表/函数必须由既有进程owner保持活着。
static inline int amclControlAddressInOwner(uintptr_t address,uintptr_t expectedBase){
    if(!address)return 0;
#ifdef _WIN32
    HMODULE module=NULL;MEMORY_BASIC_INFORMATION region;
    if(!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCSTR)address,&module)||(uintptr_t)module!=expectedBase||!VirtualQuery((LPCVOID)address,&region,sizeof(region)))return 0;
    const DWORD access=region.Protect&0xff;
    return region.State==MEM_COMMIT&&(access==PAGE_EXECUTE||access==PAGE_EXECUTE_READ||access==PAGE_EXECUTE_READWRITE||access==PAGE_EXECUTE_WRITECOPY);
#else
    Dl_info info;AmclControlAddressCheck check={address,0};
    if(!dladdr((const void*)address,&info)||(uintptr_t)info.dli_fbase!=expectedBase)return 0;
    dl_iterate_phdr(amclControlVisitExecutable,&check);return check.executable;
#endif
}

// 解析唯一预线程发布描述符，输出经过完整资格核验的借用表。*out先清空，缺席为
// NOT_READY，畸形/版本/映像/函数资格错误明确Rejected，坏描述符不得dlsym fallback。
// decimal地址严格全串解析，errno检查溢出；getter须为准确导出的同owner可执行函数。
// 表随后核完整V1布局、当前OS PID、逐函数同映像/exec，并通过公共Core descriptor
// verifyOwner确认唯一owner。成功只证明port可借，不证明资源/游戏消费者Ready。
// 不增加DSO引用，因此调用者只能在进程宿主pin该映像的既有寿命内使用返回指针。
static inline int32_t amclControlDeliveryResolveV1(const AmclControlDeliveryPortV1** out){
    if(out)*out=NULL;if(!out)return AMCL_CONTROL_REJECTED;
    const char* description=getenv(AMCL_CONTROL_ENV);if(!description)return AMCL_CONTROL_NOT_READY;
    if(strncmp(description,AMCL_CONTROL_PREFIX,sizeof(AMCL_CONTROL_PREFIX)-1)!=0)return AMCL_CONTROL_REJECTED;
    const char* number=description+sizeof(AMCL_CONTROL_PREFIX)-1;
    if(*number<'0'||*number>'9')return AMCL_CONTROL_REJECTED;
    char* end=NULL;errno=0;const unsigned long long parsed=strtoull(number,&end,10);
    if(errno||end==number||*end||!parsed||parsed>=UINTPTR_MAX)return AMCL_CONTROL_REJECTED;
    const uintptr_t address=(uintptr_t)parsed;uintptr_t base=0;uint32_t process=0;
#ifdef _WIN32
    HMODULE module=NULL;
    if(!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,(LPCSTR)address,&module)||
       (uintptr_t)GetProcAddress(module,"amclControlDeliveryGetPortV1")!=address)return AMCL_CONTROL_REJECTED;
    base=(uintptr_t)module;process=(uint32_t)_getpid();
#else
    Dl_info info;
    if(!dladdr((const void*)address,&info)||info.dli_saddr!=(void*)address||!info.dli_sname||strcmp(info.dli_sname,"amclControlDeliveryGetPortV1")!=0)return AMCL_CONTROL_REJECTED;
    const char* leaf=info.dli_fname?strrchr(info.dli_fname,'/'):NULL;leaf=leaf?leaf+1:info.dli_fname;
#ifndef AMCL_CONTROL_DELIVERY_HOST_TESTING
    if(!leaf||strcmp(leaf,"libamcl_input_runtime.so")!=0)return AMCL_CONTROL_REJECTED;
#else
    (void)leaf;
#endif
    base=(uintptr_t)info.dli_fbase;process=(uint32_t)getpid();
#endif
    if(!amclControlAddressInOwner(address,base))return AMCL_CONTROL_REJECTED;
    typedef const AmclControlDeliveryPortV1* (*Getter)(void);
    const AmclControlDeliveryPortV1* port=((Getter)address)();
    // getter已严格归属真正owner的代码段；它返回的只读表还需版本/完整字段及逐函数资格核对。
    if(!port||port->magic!=AMCL_CONTROL_MAGIC||port->version!=1||port->size!=sizeof(*port)||port->pid!=process||!port->ownerHost)return AMCL_CONTROL_REJECTED;
#define AMCL_CONTROL_CHECK_FUNCTION(name) if(!amclControlAddressInOwner((uintptr_t)port->name,base))return AMCL_CONTROL_REJECTED
    AMCL_CONTROL_CHECK_FUNCTION(verifyOwner);AMCL_CONTROL_CHECK_FUNCTION(open);AMCL_CONTROL_CHECK_FUNCTION(close);
    AMCL_CONTROL_CHECK_FUNCTION(bindTarget);AMCL_CONTROL_CHECK_FUNCTION(apply);AMCL_CONTROL_CHECK_FUNCTION(retire);AMCL_CONTROL_CHECK_FUNCTION(retireKind);
    AMCL_CONTROL_CHECK_FUNCTION(nextRetired);AMCL_CONTROL_CHECK_FUNCTION(claim);AMCL_CONTROL_CHECK_FUNCTION(validate);AMCL_CONTROL_CHECK_FUNCTION(complete);
    AMCL_CONTROL_CHECK_FUNCTION(query);AMCL_CONTROL_CHECK_FUNCTION(queryDelivered);AMCL_CONTROL_CHECK_FUNCTION(observePoll);AMCL_CONTROL_CHECK_FUNCTION(observePollView);AMCL_CONTROL_CHECK_FUNCTION(snapshot);AMCL_CONTROL_CHECK_FUNCTION(abandon);
#undef AMCL_CONTROL_CHECK_FUNCTION
    const int32_t ownership=port->verifyOwner(port->ownerHost);if(ownership<0)return ownership;
    *out=port;return AMCL_CONTROL_ACCEPTED_NO_EDGE;
}
#endif
