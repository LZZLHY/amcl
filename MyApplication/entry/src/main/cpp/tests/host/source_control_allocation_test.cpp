/** 实际 allocator 故障注入，不修改 owner 算法：冷 Source Runtime 顶层分配或 MSVC
 * 默认 map 构造的后续分配失败，必须返回 NotReady，不 abort、不借空引用/半 singleton。
 * 两种模式各在干净 OS 子进程执行，不能把已经成功的进程 pin 当成冷初始化反例。 */
#include "../../input/source/source_control.h"
#include "../../platform/legacy_output_runtime.h"
#include <atomic>
#include <new>
#include <cstdlib>
#include <cstdio>
#include <cstring>
static std::atomic<int> failureMode{0};static std::atomic<bool> injected{false};
void* operator new(std::size_t bytes){
    const int mode=failureMode.load(std::memory_order_relaxed);
    if((mode==1&&bytes==sizeof(amcl::input::LegacyOutputRuntime))||
       (mode==2&&bytes!=sizeof(amcl::input::LegacyOutputRuntime))){injected.store(true);throw std::bad_alloc();}
    void* value=std::malloc(bytes?bytes:1);if(!value)throw std::bad_alloc();return value;
}
void operator delete(void* value) noexcept {std::free(value);}
void operator delete(void* value,std::size_t) noexcept {std::free(value);}
void* operator new(std::size_t bytes,const std::nothrow_t&) noexcept {try{return ::operator new(bytes);}catch(...){return nullptr;}}
void operator delete(void* value,const std::nothrow_t&) noexcept {std::free(value);}
#define CHECK(v) do{if(!(v)){std::fprintf(stderr,"SOURCE ALLOCATION FAIL %d: %s\n",__LINE__,#v);return 1;}}while(false)
int main(int argc,char** argv){CHECK(argc==2);const int mode=std::strcmp(argv[1],"constructor")==0?2:1;
    // 先实际发布 Core/source 的进程常量描述符，但不打开 producer 或初始化 source state。
    amclSourceControlPublishV1();const auto* port=amclSourceControlGetPortV1();CHECK(port);
    failureMode.store(mode);uint64_t coldHandle=123;AmclSourceSnapshotV1 snapshot{};
    CHECK(port->preparedProducer(AMCL_SOURCE_ENTRY,&coldHandle)==AMCL_SOURCE_NOT_READY&&coldHandle==0);
    CHECK(port->query(0,0,nullptr,&snapshot)==AMCL_SOURCE_NOT_READY&&!injected.load());
    const int prepared=amclSourceControlPrepareV1();failureMode.store(0);
    CHECK(injected.load()&&prepared==0);uint64_t producer=123;
    CHECK(port->openProducer(AMCL_SOURCE_ENTRY,&producer)==AMCL_SOURCE_NOT_READY&&producer==0);
    CHECK(amclSourceControlPrepareV1()==0);
    std::puts("SOURCE ALLOCATION PASS: actual cold allocator/constructor failure returns NotReady; no half singleton/abort");
}
