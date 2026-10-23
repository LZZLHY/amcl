/** 两份实际生产 DLL：从第二 namespace 借第一 owner，而第二本地 Core 表不得冒充。
 * 表方法、getter、Core/PID/executable 检查直接用生产 client；不伪造 ABI 或卸载借用 DSO。 */
#include "../../input/source/source_control_client.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#define CHECK(v) do{if(!(v)){std::fprintf(stderr,"SOURCE IDENTITY FAIL %d: %s\n",__LINE__,#v);std::exit(1);}}while(false)
/** 事务专用入口与普通解析器共用环境/PID/映像防线；拒绝时不能发号或产生运输效果。 */
static void rejectedPreparedTransaction(){
    AmclSourceRequestV1 request{};request.size=sizeof(request);request.operation=AMCL_SOURCE_ISSUE_NATIVE;
    AmclSourceResultV1 result{};
    CHECK(amclSourceControlTransactPreparedV1(AMCL_SOURCE_ENTRY,&request,&result)<0);
    CHECK(!result.accepted&&!result.transportAccepted&&!result.owner);
}
int main(int argc,char** argv){CHECK(argc==3);
#ifdef _WIN32
    const auto first=LoadLibraryA(argv[1]),second=LoadLibraryA(argv[2]);CHECK(first&&second&&first!=second);
    using Getter=const AmclSourceControlPortV1*(*)();using Publisher=void(*)();using Prepare=int(*)();
    const auto getFirst=reinterpret_cast<Getter>(GetProcAddress(first,"amclSourceControlGetPortV1"));
    const auto getSecond=reinterpret_cast<Getter>(GetProcAddress(second,"amclSourceControlGetPortV1"));
    const auto publish=reinterpret_cast<Publisher>(GetProcAddress(first,"amclSourceControlPublishV1"));
    const auto prepareFirst=reinterpret_cast<Prepare>(GetProcAddress(first,"amclSourceControlPrepareV1"));
    const auto prepareSecond=reinterpret_cast<Prepare>(GetProcAddress(second,"amclSourceControlPrepareV1"));
    CHECK(getFirst&&getSecond&&publish&&prepareFirst&&prepareSecond);CHECK(!prepareFirst()&&!prepareSecond());
    publish();const auto* owner=getFirst();const AmclSourceControlPortV1* resolved=nullptr;
    CHECK(amclSourceControlResolveV1(&resolved)==0&&resolved==owner&&prepareFirst()&&prepareSecond());
    uint64_t firstProducer=0,borrowedProducer=0;CHECK(owner->openProducer(1,&firstProducer)==0);
    CHECK(resolved->openProducer(1,&borrowedProducer)==0&&firstProducer==borrowedProducer);
    const std::string good=getenv(AMCL_SOURCE_CONTROL_ENV);
    for(const auto* bad:{"AMCL_SOURCE_CONTROL_V2:1","AMCL_SOURCE_CONTROL_V1:","AMCL_SOURCE_CONTROL_V1:+1",
        "AMCL_SOURCE_CONTROL_V1:-1","AMCL_SOURCE_CONTROL_V1:01","AMCL_SOURCE_CONTROL_V1:1x",
        "AMCL_SOURCE_CONTROL_V1:0","AMCL_SOURCE_CONTROL_V1:18446744073709551616"}){
        _putenv_s(AMCL_SOURCE_CONTROL_ENV,bad);CHECK(amclSourceControlResolveV1(&resolved)<0&&!resolved&&!prepareFirst());
        rejectedPreparedTransaction();}
    char text[96]{};std::snprintf(text,sizeof(text),AMCL_SOURCE_CONTROL_PREFIX "%u:%llu",(unsigned)_getpid(),(unsigned long long)reinterpret_cast<uintptr_t>(publish));
    _putenv_s(AMCL_SOURCE_CONTROL_ENV,text);CHECK(amclSourceControlResolveV1(&resolved)<0&&!resolved);
    rejectedPreparedTransaction();
    // PID不匹配甚至配未映射地址，必须在模块/指针检查之前直接NotReady。
    std::snprintf(text,sizeof(text),AMCL_SOURCE_CONTROL_PREFIX "%u:1",(unsigned)_getpid()+1u);
    _putenv_s(AMCL_SOURCE_CONTROL_ENV,text);CHECK(amclSourceControlResolveV1(&resolved)==AMCL_SOURCE_NOT_READY&&!resolved);
    rejectedPreparedTransaction();
    const auto* other=getSecond();CHECK(other&&other->ownerHost!=owner->ownerHost&&other->verifyOwner(other->ownerHost)<0);
    // 第二映像借到的是第一owner的prepared句柄；它本地的同形表绝不能接受这个句柄。
    AmclSourceRequestV1 foreignRequest{};foreignRequest.size=sizeof(foreignRequest);foreignRequest.operation=AMCL_SOURCE_ISSUE_NATIVE;
    AmclSourceResultV1 foreignResult{};
    CHECK(other->transact(firstProducer,&foreignRequest,&foreignResult)<0&&!foreignResult.accepted);
    std::snprintf(text,sizeof(text),AMCL_SOURCE_CONTROL_PREFIX "%u:%llu",(unsigned)_getpid(),(unsigned long long)reinterpret_cast<uintptr_t>(getSecond));
    _putenv_s(AMCL_SOURCE_CONTROL_ENV,text);CHECK(amclSourceControlResolveV1(&resolved)<0&&!resolved&&!prepareFirst()&&!prepareSecond());
    rejectedPreparedTransaction();
    _putenv_s(AMCL_SOURCE_CONTROL_ENV,good.c_str());CHECK(amclSourceControlResolveV1(&resolved)==0&&resolved==owner&&prepareSecond());
    std::puts("SOURCE IDENTITY PASS: cold missing/foreign/exact image/Core/borrow same producer/no local fallback/no unload");
#else
    (void)argv;return 2;
#endif
}
