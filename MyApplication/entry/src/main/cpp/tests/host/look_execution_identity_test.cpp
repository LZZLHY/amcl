/** 加载实际两个生产DLL，验证getter/代码映像/唯一Core与畸形描述符，绝不伪造port表。 */
#include "../../input/delivery/look_execution_client.h"
#include "../../input/amcl_input_host_descriptor.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#define CHECK(v) do{if(!(v)){std::fprintf(stderr,"LOOK IDENTITY FAIL %d: %s\n",__LINE__,#v);std::exit(1);}}while(false)
int main(int argc,char** argv){CHECK(argc==3);
#ifdef _WIN32
    auto first=LoadLibraryA(argv[1]);auto second=LoadLibraryA(argv[2]);CHECK(first&&second&&first!=second);
    using Getter=const AmclLookExecutionPortV1*(*)();using Publisher=void(*)();
    const auto getFirst=reinterpret_cast<Getter>(GetProcAddress(first,"amclLookExecutionGetPortV1"));
    const auto getSecond=reinterpret_cast<Getter>(GetProcAddress(second,"amclLookExecutionGetPortV1"));
    const auto publish=reinterpret_cast<Publisher>(GetProcAddress(first,"amclLookExecutionPublishV1"));
    using CorePublisher=int32_t(*)(const AmclInputHostApiV1*);
    const auto publishCore=reinterpret_cast<CorePublisher>(GetProcAddress(first,"amclInputHostDescriptorPublishV1"));
    CHECK(getFirst&&getSecond&&publish&&publishCore);const auto* actual=getFirst();CHECK(actual&&actual->pid==(uint32_t)_getpid());
    CHECK(publishCore(reinterpret_cast<const AmclInputHostApiV1*>(actual->ownerHost))==0);publish();
    const AmclLookExecutionPortV1* resolved=nullptr;CHECK(amclLookExecutionResolveV1(&resolved)==0&&resolved==actual);
    const std::string good=getenv(AMCL_LOOK_EXECUTION_ENV);
    for(const auto* invalid:{"AMCLLOOK:2:1","AMCLLOOK:1:","AMCLLOOK:1:-1","AMCLLOOK:1:+1","AMCLLOOK:1:1x",
        "AMCLLOOK:1:18446744073709551616","AMCLLOOK:1:0","AMCLLOOK:1:1"}){
        _putenv_s(AMCL_LOOK_EXECUTION_ENV,invalid);CHECK(amclLookExecutionResolveV1(&resolved)==AMCL_LOOK_REJECTED&&resolved==nullptr);}
    char description[96]{};std::snprintf(description,sizeof(description),AMCL_LOOK_EXECUTION_PREFIX "%llu",
        (unsigned long long)reinterpret_cast<uintptr_t>(publish));_putenv_s(AMCL_LOOK_EXECUTION_ENV,description);
    CHECK(amclLookExecutionResolveV1(&resolved)==AMCL_LOOK_REJECTED);
    const auto* other=getSecond();CHECK(other&&other!=actual&&other->ownerHost!=actual->ownerHost);
    CHECK(other->verifyOwner(other->ownerHost)==AMCL_LOOK_NOT_READY);
    std::snprintf(description,sizeof(description),AMCL_LOOK_EXECUTION_PREFIX "%llu",(unsigned long long)reinterpret_cast<uintptr_t>(getSecond));
    _putenv_s(AMCL_LOOK_EXECUTION_ENV,description);CHECK(amclLookExecutionResolveV1(&resolved)==AMCL_LOOK_NOT_READY&&resolved==nullptr);
    _putenv_s(AMCL_LOOK_EXECUTION_ENV,good.c_str());CHECK(amclLookExecutionResolveV1(&resolved)==0&&resolved==actual);
    // 进程owner的DSO/JVM寿命固定；本测试不FreeLibrary，不用卸载制造借用pointer安全错觉。
    std::puts("LOOK IDENTITY PASS: actual two owner DLLs/malformed/getter executable/uniqueCore/no unload");
#else
    (void)argv;return 2;
#endif
}
