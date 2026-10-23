/** 直接编译生产collector的两pull ABI身份/终态反例。
 * 每个backend由独立进程在生产前冷选择，不添加生产reset；原v1另由原测试验证。
 * 故障注入只用既有HOST clock/mutex hook；本测试不授SDK/Java或设备实际执行。
 */
#include "input/input_latency_observation.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <atomic>
#include <new>
static bool allocationForbidden=false;
void* operator new(std::size_t bytes){if(allocationForbidden)throw std::bad_alloc();if(auto p=std::malloc(bytes))return p;throw std::bad_alloc();}
void operator delete(void* p)noexcept{std::free(p);}
void operator delete(void* p,std::size_t)noexcept{std::free(p);}
static void check(bool ok,const char* why){if(!ok){std::fprintf(stderr,"BACKEND LATENCY CHECK %s\n",why);std::exit(1);}}
static uint32_t backend,endpoint,success;
static AmclInputLatencyV1 rows[8];
static AmclInputLatencyStatsV1 stats;
/** 这些值均作为原值提交给真正表；po与ro故意不相等，不能用相同数伪关联。 */
static AmclInputLatencyV1 begin(uint64_t prefix){
    auto previous=amclInputLatencyBeginV1(prefix+100);
    amclInputLatencyAcceptV1(prefix,prefix*3,7,1);
    AmclInputLatencyV1 original{};original.prefix=prefix;original.ringSequence=prefix+17;original.ringOrder=prefix*3+1;
    amclInputLatencyNoteV1(AMCL_ILAT_ENQUEUE,&original);amclInputLatencyEndV1(previous,1);
    original.consumer=41;original.activation=23;original.target=59;original.ticket=prefix+101;
    return original;
}
static void readCache(const AmclInputLatencyV1& original){
    amclInputLatencyNoteBackendV2(AMCL_ILAT_READ,backend,endpoint,&original);
    amclInputLatencyNoteBackendV2(AMCL_ILAT_CACHE,backend,endpoint,&original);
}
static void terminal(const AmclInputLatencyV1& original){
    amclInputLatencyNoteBackendV2(AMCL_ILAT_RETURN,backend,endpoint,&original);
    amclInputLatencyFinishBackendV2(backend,endpoint,&original,success);
}
/** 另一真实线程持同一生产诊断mutex；不拿单线程假忙标志代锁竞争。 */
template<class F>static void whileBusy(F action){
    std::atomic<bool> held{false},release{false};
    std::thread owner([&]{amclInputLatencyTestHoldV1(1);held=true;while(!release.load())std::this_thread::yield();amclInputLatencyTestHoldV1(0);});
    while(!held.load())std::this_thread::yield();action();release=true;owner.join();
}
int main(int argc,char** argv){
    check(argc==2||argc==3,"EXPLICIT_BACKEND_PROCESS");backend=static_cast<uint32_t>(std::atoi(argv[1]));check(backend==2||backend==3,"SUPPORTED_BACKEND");
    endpoint=backend==3?AMCL_ILAT_ENDPOINT_SDL_QUEUE_ADD:AMCL_ILAT_ENDPOINT_L2_POLL_VIEW;
    success=backend==3?AMCL_ILAT_SDL_QUEUE_COMMITTED:AMCL_ILAT_L2_POLL_VIEW_COPIED;
    const uint32_t other=backend==3?2:3,otherEndpoint=backend==3?AMCL_ILAT_ENDPOINT_L2_POLL_VIEW:AMCL_ILAT_ENDPOINT_SDL_QUEUE_ADD;
    if(argc==3){
        // 冷配置忙丢或生产已开始，只保旧未选择v1观测，不授新pull选择成功。
        const bool busy=std::strcmp(argv[2],"busy-configure")==0;
        check(busy||std::strcmp(argv[2],"late-configure")==0,"EXPLICIT_CONFIGURE_FAILURE_CASE");
        if(busy)whileBusy([&]{amclInputLatencyConfigureBackendV2(backend,7);});
        auto unknown=begin(19);
        if(!busy)amclInputLatencyConfigureBackendV2(backend,7);
        readCache(unknown);terminal(unknown);
        check(amclInputLatencyDrainV1(rows,8,&stats)==0,"UNSELECTED_V1_RECORD_CANNOT_BECOME_PULL");
        amclInputLatencyFinishV1(unknown.prefix,AMCL_ILAT_RETIRED);
        check(amclInputLatencyDrainV1(rows,8,&stats)==1&&rows[0].outcome==AMCL_ILAT_RETIRED&&rows[0].mask==7,"FAILED_CONFIGURE_REMAINS_LEGACY_UNKNOWN_SCOPE");
        char unknownText[512];check(inputBridge_formatInputLatencyV1(&rows[0],unknownText,sizeof(unknownText))>0&&std::strncmp(unknownText,"ILAT1 ",6)==0,"UNKNOWN_SCOPE_NOT_FORGED_PULL_FORMAT");
        std::puts("BACKEND CONFIGURE PASS missing selection only; no input qualification change");return 0;
    }
    amclInputLatencyConfigureBackendV2(backend,7);
    amclInputLatencyConfigureBackendV2(other,7); // 冲突不能重签后来的sample。
    allocationForbidden=true;
    auto original=begin(1);
    amclInputLatencyFinishV1(original.prefix,AMCL_ILAT_CALLBACK);
    amclInputLatencyFinishV1(original.prefix,AMCL_ILAT_SKIPPED);
    check(amclInputLatencyDrainV1(rows,8,&stats)==0,"OLD_PREFIX_TERMINAL_CANNOT_RETIRE_SELECTED_PULL_BEFORE_CACHE");
    auto wrongRing=original;++wrongRing.ringSequence;
    amclInputLatencyNoteBackendV2(AMCL_ILAT_READ,backend,endpoint,&wrongRing);
    amclInputLatencyNoteBackendV2(AMCL_ILAT_READ,other,otherEndpoint,&original);
    amclInputLatencyNoteBackendV2(AMCL_ILAT_CACHE,other,otherEndpoint,&original);
    amclInputLatencyNoteBackendV2(AMCL_ILAT_RETURN,other,otherEndpoint,&original);
    amclInputLatencyFinishBackendV2(other,otherEndpoint,&original,other==3?AMCL_ILAT_SDL_QUEUE_COMMITTED:AMCL_ILAT_L2_POLL_VIEW_COPIED);
    amclInputLatencyNoteV1(AMCL_ILAT_READ,&original);
    amclInputLatencyNoteV1(AMCL_ILAT_CACHE,&original);
    amclInputLatencyNoteV1(AMCL_ILAT_RETURN,&original);
    check(amclInputLatencyDrainV1(rows,8,&stats)==0,"OLD_GLFW_OR_OTHER_BACKEND_CANNOT_STEAL_TIMESTAMPS");
    readCache(original);
    auto wrongTicket=original;++wrongTicket.ticket;
    amclInputLatencyNoteBackendV2(AMCL_ILAT_CACHE,backend,endpoint,&wrongTicket);
    terminal(wrongTicket);
    amclInputLatencyFinishTicketV1(&original,AMCL_ILAT_CALLBACK);
    amclInputLatencyFinishBackendV2(backend,endpoint,&original,backend==3?AMCL_ILAT_L2_POLL_VIEW_COPIED:AMCL_ILAT_SDL_QUEUE_COMMITTED);
    amclInputLatencyFinishV1(original.prefix,AMCL_ILAT_RETIRED);
    check(amclInputLatencyDrainV1(rows,8,&stats)==0,"NO_ENDPOINT_YET_RETIRED_PREFIX_OR_WRONG_TICKET_CANNOT_DRAIN");
    terminal(original);
    check(amclInputLatencyDrainV1(rows,8,&stats)==1&&rows[0].outcome==success&&rows[0].mask==63&&rows[0].ticket==original.ticket,"REAL_EXACT_TICKET_TERMINAL_SIX_POINTS");
    char text[512]{};check(inputBridge_formatInputLatencyV1(&rows[0],text,sizeof(text))>0,"PULL_FORMAT");
    check(std::strncmp(text,"ILAT2 ",6)==0&&std::strstr(text,backend==3?"ILAT2 b=3 e=1":"ILAT2 b=2 e=2"),"EXPLICIT_BACKEND_ENDPOINT_NOT_CALLBACK");
    auto oldCache=begin(2);readCache(oldCache);
    amclInputLatencyFinishBackendV2(backend,endpoint,&oldCache,AMCL_ILAT_SKIPPED);
    check(amclInputLatencyDrainV1(rows,8,&stats)==1&&rows[0].mask==31&&rows[0].outcome==(backend==3?AMCL_ILAT_SDL_CACHE_ONLY:AMCL_ILAT_L2_CACHE_UNOBSERVED),"OVERWRITTEN_CACHE_NOT_POLL_OR_QUEUE_ACK");
    auto retired=begin(3);readCache(retired);
    amclInputLatencyFinishBackendV2(backend,endpoint,&retired,AMCL_ILAT_RETIRED);
    check(amclInputLatencyDrainV1(rows,8,&stats)==1&&rows[0].mask==31&&rows[0].outcome==(backend==3?AMCL_ILAT_SDL_RETIRED:AMCL_ILAT_L2_RETIRED),"EXPLICIT_LIFECYCLE_DIAGNOSTIC_RELEASE_WITHOUT_ENDPOINT");
    allocationForbidden=false;
    auto busyEnd=begin(4);readCache(busyEnd);
    whileBusy([&]{amclInputLatencyNoteBackendV2(AMCL_ILAT_RETURN,backend,endpoint,&busyEnd);});
    amclInputLatencyFinishBackendV2(backend,endpoint,&busyEnd,success);
    check(amclInputLatencyDrainV1(rows,8,&stats)==1&&rows[0].outcome==success&&rows[0].mask==31,"BUSY_TERMINAL_NOTE_SUCCESS_FINISH_CLOSES_WITHOUT_FABRICATING_TIME");
    auto clockGap=begin(5);
    amclInputLatencyNoteBackendV2(AMCL_ILAT_READ,backend,endpoint,&clockGap);
    amclInputLatencyTestClockV1(1);amclInputLatencyNoteBackendV2(AMCL_ILAT_CACHE,backend,endpoint,&clockGap);amclInputLatencyTestClockV1(0);
    auto changed=clockGap;++changed.target;
    terminal(changed);check(amclInputLatencyDrainV1(rows,8,&stats)==0,"CACHE_CLOCK_GAP_STILL_FREEZES_ORIGINAL_TUPLE");
    terminal(clockGap);
    check(amclInputLatencyDrainV1(rows,8,&stats)==1&&rows[0].mask==47&&rows[0].clockFailures==1&&rows[0].target==clockGap.target,"REAL_CLOCK_GAP_IS_MISSING_NOT_REBOUND");
    AmclInputLatencyV1 maximum{};maximum.id=maximum.session=maximum.stream=maximum.prefix=maximum.prefixOrder=maximum.ringSequence=
        maximum.ringOrder=maximum.consumer=maximum.activation=maximum.target=maximum.ticket=UINT64_MAX;
    for(auto& t:maximum.ns)t=UINT64_MAX;maximum.mask=63;maximum.outcome=success;maximum.contributions=maximum.clockFailures=UINT32_MAX;
    check(inputBridge_formatInputLatencyV1(&maximum,text,sizeof(text))>0,"MAX_PULL_RECORD_BOUNDED_512_BYTES");
    check(sizeof(AmclInputLatencyV1)==152&&amclInputLatencyTestStorageV1()<=128*1024,"POD_AND_FIXED_STORAGE_BUDGET");
    std::printf("BACKEND LATENCY PASS backend=%u endpoint=%u rowBytes=%zu storage=%u; collector mechanisms, not SDK/device performance\n",backend,endpoint,sizeof(AmclInputLatencyV1),amclInputLatencyTestStorageV1());
}
