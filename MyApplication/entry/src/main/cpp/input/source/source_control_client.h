/** source 私有端口只读解析：核 exact getter 导出、同映像可执行方法、PID 和原 Core。
 * 环境缺失、旧表、外来表均 fail closed，不允许平台 namespace 创建新 singleton。 */
#ifndef AMCL_SOURCE_CONTROL_CLIENT_H
#define AMCL_SOURCE_CONTROL_CLIENT_H
#include "source_control.h"
#include "../delivery/control_delivery_client.h"
/** 冷连接/显式重查始终核PID、exact getter、ABI、方法映像与真实Core。
 * 返回表服从进程期pin契约；成功连接可复用表，但业务Ready只能由各方法的活资源检查确定。 */
static inline int32_t amclSourceControlResolveV1(const AmclSourceControlPortV1** output) {
    if(output)*output=NULL;if(!output)return AMCL_SOURCE_REJECTED;
    const char* text=getenv(AMCL_SOURCE_CONTROL_ENV);if(!text)return AMCL_SOURCE_NOT_READY;
    if(strncmp(text,AMCL_SOURCE_CONTROL_PREFIX,sizeof(AMCL_SOURCE_CONTROL_PREFIX)-1))return AMCL_SOURCE_REJECTED;
    const char* number=text+sizeof(AMCL_SOURCE_CONTROL_PREFIX)-1;
    if(*number<'1'||*number>'9')return AMCL_SOURCE_REJECTED;
    char* end=NULL;errno=0;const unsigned long long announcedPid=strtoull(number,&end,10);
    if(errno||end==number||*end!=':'||!announcedPid||announcedPid>UINT32_MAX)return AMCL_SOURCE_REJECTED;
    // 环境描述符在预线程发布 PID，fork 子进程在任何 dladdr/loader/helper mutex 前拒绝。
#ifdef _WIN32
    const uint32_t process=(uint32_t)_getpid();
#else
    const uint32_t process=(uint32_t)getpid();
#endif
    if(announcedPid!=process)return AMCL_SOURCE_NOT_READY;
    number=end+1;if(*number<'1'||*number>'9')return AMCL_SOURCE_REJECTED;
    errno=0;const unsigned long long value=strtoull(number,&end,10);
    if(errno||end==number||*end||!value||value>=UINTPTR_MAX)return AMCL_SOURCE_REJECTED;
    const uintptr_t address=(uintptr_t)value;uintptr_t base=0;
#ifdef _WIN32
    HMODULE image=NULL;
    if(!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        (LPCSTR)address,&image)||(uintptr_t)GetProcAddress(image,"amclSourceControlGetPortV1")!=address)return AMCL_SOURCE_REJECTED;
    base=(uintptr_t)image;
#else
    Dl_info info;if(!dladdr((const void*)address,&info)||info.dli_saddr!=(void*)address||!info.dli_sname||
        strcmp(info.dli_sname,"amclSourceControlGetPortV1"))return AMCL_SOURCE_REJECTED;
    const char* leaf=info.dli_fname?strrchr(info.dli_fname,'/'):NULL;leaf=leaf?leaf+1:info.dli_fname;
#ifndef AMCL_CONTROL_DELIVERY_HOST_TESTING
    if(!leaf||strcmp(leaf,"libamcl_input_runtime.so"))return AMCL_SOURCE_REJECTED;
#else
    (void)leaf;
#endif
    base=(uintptr_t)info.dli_fbase;
#endif
    if(!amclControlAddressInOwner(address,base))return AMCL_SOURCE_REJECTED;
    typedef const AmclSourceControlPortV1*(*Getter)(void);
    const AmclSourceControlPortV1* port=((Getter)address)();
    if(!port||port->magic!=AMCL_SOURCE_CONTROL_MAGIC||port->version!=1||port->size!=sizeof(*port)||
        port->pid!=process||!port->ownerHost)return AMCL_SOURCE_REJECTED;
#define AMCL_SOURCE_CHECK(name) if(!amclControlAddressInOwner((uintptr_t)port->name,base))return AMCL_SOURCE_REJECTED
    AMCL_SOURCE_CHECK(verifyOwner);AMCL_SOURCE_CHECK(openProducer);AMCL_SOURCE_CHECK(preparedProducer);
    AMCL_SOURCE_CHECK(transact);AMCL_SOURCE_CHECK(query);AMCL_SOURCE_CHECK(ownedTextKeyTap);AMCL_SOURCE_CHECK(ownedTextKeyTapForKeyboard);
#undef AMCL_SOURCE_CHECK
    const int32_t result=port->verifyOwner(port->ownerHost);if(result<0)return result;
    *output=port;return 0;
}
/** 无持久连接的单次调用保留完整握手，不把未经Core核验的port交给调用者。
 * preparedProducer只读已准备职责，不初始化/改状态；平台高频调用使用原已验证连接，
 * 不能为省成本直接调用未完成首次握手的namespace本地getter。 */
static inline int32_t amclSourceControlTransactPreparedV1(uint32_t role,
        const AmclSourceRequestV1* request,AmclSourceResultV1* result) {
    if(!result)return AMCL_SOURCE_REJECTED;
    memset(result,0,sizeof(*result));result->status=AMCL_SOURCE_NOT_READY;
    const AmclSourceControlPortV1* port=NULL;uint64_t producer=0;
    const int32_t resolved=amclSourceControlResolveV1(&port);
    if(resolved<0)return resolved;
    const int32_t prepared=port->preparedProducer(role,&producer);
    if(prepared<0||!producer)return AMCL_SOURCE_NOT_READY;
    return port->transact(producer,request,result);
}
#ifdef __cplusplus
#include <atomic>
namespace amcl::input {
/**
 * C++高频边缘复用已完整握手的进程期连接；Entry和重复namespace中的Java桥均借同一
 * 已发布owner，不能把本地getter或prepared数组当作全进程唯一来源。这里只缓存不可变表，
 * 不缓存失败、会话Ready或活资源。原子槽常量初始化，无可继承的初始化mutex；fork先
 * 读取表内固定PID并拒绝，再允许任何方法调用。并发冷握手只能发布同一合法owner。
 */
inline bool BorrowSourceConnection(uint32_t role,const AmclSourceControlPortV1** port,uint64_t* producer){
    if(!port||!producer)return false;*port=nullptr;*producer=0;
    static std::atomic<const AmclSourceControlPortV1*> connected{nullptr};
    const AmclSourceControlPortV1* current=connected.load(std::memory_order_acquire);
    const bool cold=current==nullptr;
#ifdef _WIN32
    const uint32_t process=static_cast<uint32_t>(_getpid());
#else
    const uint32_t process=static_cast<uint32_t>(getpid());
#endif
    if(current&&current->pid!=process)return false;
    if(!current&&amclSourceControlResolveV1(&current)<0)return false;
    if(current->preparedProducer(role,producer)<0||!*producer)return false;
    // warm读取不再写同一共享cache line，避免并行来源反复使对方CPU缓存失效。
    if(cold)connected.store(current,std::memory_order_release);
    *port=current;return true;
}
}
#endif
#endif
