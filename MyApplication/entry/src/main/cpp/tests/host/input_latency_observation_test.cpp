/** 真固定诊断表的故障/输出边界；不把这些宿主值称目标设备输入性能。
 * busy来自另一线程真正持同一mutex；clock失败只用HOST私有hook，生产时钟未变。
 */
#include "input/input_latency_observation.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <atomic>
#include <new>
#include <limits>
#include <chrono>
#ifndef _WIN32
#include <unistd.h>
#include <sys/wait.h>
#endif
static bool forbidAllocation=false;
/** 独立diagnostic热调用期间禁止真实堆申请；线程资源在开关开启前准备。 */
void* operator new(std::size_t size){if(forbidAllocation)throw std::bad_alloc();if(auto* value=std::malloc(size))return value;throw std::bad_alloc();}
void operator delete(void* value)noexcept{std::free(value);}
void operator delete(void* value,std::size_t)noexcept{std::free(value);}
static void check(bool good,const char* why){if(!good){std::fprintf(stderr,"LATENCY CHECK %s\n",why);std::exit(2);}}
/** 原id与不同po/ro完整经过所有阶段，随后测试导出固定长度/缺时点而非重写采集算法。 */
static void submit(uint64_t prefix){const auto previous=amclInputLatencyBeginV1(prefix+10);amclInputLatencyAcceptV1(prefix,prefix*2,7,2);
    AmclInputLatencyV1 note{};note.prefix=prefix;note.ringSequence=prefix+1;note.ringOrder=prefix*2+1;
    amclInputLatencyNoteV1(AMCL_ILAT_ENQUEUE,&note);amclInputLatencyNoteV1(AMCL_ILAT_READ,&note);
    note.consumer=1;note.activation=2;note.target=3;note.ticket=4;
    note.outcome=AMCL_ILAT_CALLBACK;amclInputLatencyNoteV1(AMCL_ILAT_CACHE,&note);
    amclInputLatencyNoteV1(AMCL_ILAT_CALLBACK_BEGIN,&note);amclInputLatencyNoteV1(AMCL_ILAT_RETURN,&note);amclInputLatencyEndV1(previous,1);}
int main(){AmclInputLatencyV1 rows[8]{};AmclInputLatencyStatsV1 stats{};
    forbidAllocation=true;submit(1);forbidAllocation=false;
    check(amclInputLatencyDrainV1(rows,8,&stats)==1,"FIRST_REAL_ROW");check(rows[0].mask==63&&rows[0].prefixOrder!=rows[0].ringOrder,"ORIGINAL_PO_RO");
    char text[512]{};check(inputBridge_formatInputLatencyV1(&rows[0],text,sizeof(text))>0,"FORMAT_COMPLETE");
    check(std::strstr(text,"sample_range=unknown")!=nullptr,"UNKNOWN_SAMPLE_RANGE_NOT_FORGED");
    // 超过旧候选1秒年龄仍保留原未完成记录；只有真实终态才能释放槽，防止长尾被导出裁掉。
    const auto oldPending=amclInputLatencyBeginV1(30);amclInputLatencyAcceptV1(3,6,7,1);amclInputLatencyEndV1(oldPending,1);
    std::this_thread::sleep_for(std::chrono::milliseconds(1100));
    check(amclInputLatencyDrainV1(rows,8,&stats)==0,"LONG_PENDING_NOT_AGED_OUT");
    amclInputLatencyFinishV1(3,AMCL_ILAT_RETIRED);
    check(amclInputLatencyDrainV1(rows,8,&stats)==1&&rows[0].prefix==3&&rows[0].outcome==AMCL_ILAT_RETIRED,"REAL_TERMINAL_RELEASES_PENDING");
    // 这是collector故障机制反例；当前产品cache后没有这个skip分支，不能冒称设备生命周期。
    auto skippedOld=amclInputLatencyBeginV1(40);amclInputLatencyAcceptV1(4,8,7,1);
    AmclInputLatencyV1 skippedNote{};skippedNote.prefix=4;skippedNote.consumer=1;skippedNote.activation=2;skippedNote.target=3;skippedNote.ticket=4;
    skippedNote.outcome=AMCL_ILAT_CALLBACK;amclInputLatencyNoteV1(AMCL_ILAT_CACHE,&skippedNote);amclInputLatencyEndV1(skippedOld,1);
    // 已缓存的原票必须显式确认未调用分支；原prefix-only只供producer全prefix退休。
    amclInputLatencyFinishTicketV1(&skippedNote,AMCL_ILAT_SKIPPED);
    check(amclInputLatencyDrainV1(rows,8,&stats)==1&&rows[0].outcome==AMCL_ILAT_SKIPPED&&(rows[0].mask&32)==0,"KNOWN_SKIP_DOES_NOT_WAIT_FOR_UNCALLED_RETURN");
    amclInputLatencyTestClockV1(1);submit(2);amclInputLatencyTestClockV1(0);
    check(amclInputLatencyDrainV1(rows,8,&stats)==1,"CLOCK_FAILURE_STILL_TERMINATES");
    check(rows[0].mask==0&&rows[0].clockFailures==6,"CLOCK_MISSING_MASK");
    check(inputBridge_formatInputLatencyV1(&rows[0],text,sizeof(text))>0&&std::strstr(text,"ns=-/-/-/-/-/-"),"MISSING_NOT_ZERO");
    std::atomic<bool> locked{false},release{false};std::thread holder([&]{amclInputLatencyTestHoldV1(1);locked=true;while(!release.load())std::this_thread::yield();amclInputLatencyTestHoldV1(0);});
    while(!locked.load())std::this_thread::yield();const auto previous=amclInputLatencyBeginV1(3);check(amclInputLatencyCurrentV1()==0,"REAL_BUSY_DROPS_ONLY_DIAG");amclInputLatencyEndV1(previous,1);
    release=true;holder.join();check(amclInputLatencyDrainV1(rows,8,&stats)==0&&stats.busy>0,"REAL_BUSY_COUNT");
#ifndef _WIN32
    // 真fork时另一线程持诊断mutex；子进程必须先拒父PID记录，不能试锁继承的死mutex，
    // 不能读取父样本/建第二observer owner。此例只证collector隔离，不代替生产冷owner门。
    std::atomic<bool> forkHeld{false},forkRelease{false};std::thread forkHolder([&]{amclInputLatencyTestHoldV1(1);forkHeld=true;
        while(!forkRelease.load())std::this_thread::yield();amclInputLatencyTestHoldV1(0);});
    while(!forkHeld.load())std::this_thread::yield();const pid_t child=fork();check(child>=0,"REAL_FORK_CREATED");
    if(child==0){alarm(5);const auto inherited=amclInputLatencyBeginV1(99);amclInputLatencyEndV1(inherited,1);
        AmclInputLatencyV1 childRows[8]{};AmclInputLatencyStatsV1 childStats{};
        const bool isolated=amclInputLatencyCurrentV1()==0&&amclInputLatencyDrainV1(childRows,8,&childStats)==0;
        _exit(isolated?0:2);}
    int childStatus=0;check(waitpid(child,&childStatus,0)==child&&WIFEXITED(childStatus)&&WEXITSTATUS(childStatus)==0,"INHERITED_PID_REFUSES_BEFORE_DEAD_MUTEX");
    forkRelease=true;forkHolder.join();std::puts("LATENCY FORK PASS real child PID refuses inherited locked table before lock/clock; collector boundary only");
#endif
    for(uint64_t i=10;i<600;++i)submit(i);unsigned total=0;while(auto count=amclInputLatencyDrainV1(rows,8,&stats))total+=count;
    check(total<=512&&stats.full>0,"FIXED_CAPACITY_NO_OVERWRITE");
    AmclInputLatencyV1 maximum{};maximum.id=maximum.session=maximum.stream=maximum.prefix=maximum.prefixOrder=maximum.ringSequence=
        maximum.ringOrder=maximum.consumer=maximum.activation=maximum.target=maximum.ticket=UINT64_MAX;
    for(auto& value:maximum.ns)value=UINT64_MAX; // 按原类型赋值，避免把布局/别名未证当极值测试。
    maximum.mask=63;maximum.outcome=UINT32_MAX;maximum.contributions=UINT32_MAX;maximum.clockFailures=UINT32_MAX;
    const auto length=inputBridge_formatInputLatencyV1(&maximum,text,sizeof(text));check(length>0&&length<512,"MAX_RECORD_FITS_NO_TRUNCATION");
    const auto storage=amclInputLatencyTestStorageV1();check(storage<=128*1024,"BOUNDED_HOST_STORAGE");
    std::printf("LATENCY PASS rowBytes=%u capacity=%u storageObjectBytes=%u tlsPerThreadBytes=%zu maxLineBytes=%u full=%llu busy=%llu; host mechanisms only\n",stats.recordBytes,stats.capacity,storage,sizeof(uint64_t),length,(unsigned long long)stats.full,(unsigned long long)stats.busy);
}
