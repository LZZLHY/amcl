/**
 * Windows真实双DLL控制器。它只调生产边缘包装，所有运输、资源、归约、票据与cursor
 * 演化在被加载的生产代码内完成。每个模式是独立进程，避免旧owner解析缓存掩盖late replay。
 */
#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <thread>
#include <chrono>
#define CHECK(v) do{if(!(v)){std::fprintf(stderr,"LOOK IMAGE FAIL %d: %s\n",__LINE__,#v);std::exit(1);}}while(false)
struct Image {
    HMODULE module;
    void(*publish)();void(*registerCallback)(int);void(*activate)(int);int(*submit)(double);int(*action)();void(*pump)();
    int(*sourceAction)();int(*processed)(double);int(*ready)();
    int(*observe)(uint64_t*,double*);
    explicit Image(const char* path){module=LoadLibraryA(path);CHECK(module);
#define LOAD(field,name) field=reinterpret_cast<decltype(field)>(GetProcAddress(module,name));CHECK(field)
        LOAD(publish,"lookFixturePublishOwner");LOAD(registerCallback,"lookFixtureRegister");LOAD(activate,"lookFixtureActivate");
        LOAD(submit,"lookFixtureSubmit");LOAD(action,"lookFixtureAction");LOAD(pump,"lookFixturePump");LOAD(observe,"lookFixtureObserve");
        LOAD(sourceAction,"lookFixtureSourceAction");LOAD(processed,"lookFixtureProcessed");LOAD(ready,"lookFixtureReady");
#undef LOAD
    }
};
int main(int argc,char** argv){CHECK(argc==4);Image owner(argv[1]),consumer(argv[2]);CHECK(owner.module!=consumer.module);
    const bool nullEarly=std::strcmp(argv[3],"early-null")==0;
    const bool shortOwner=std::strcmp(argv[3],"short")==0;
    const bool early=std::strcmp(argv[3],"early")==0||nullEarly;
    if(early)consumer.registerCallback(1);
    if(nullEarly)consumer.registerCallback(0);
    owner.publish();
    // 正常GLFW在look注册前已由其它legacy入口解析owner；这里用真实activation完成该解析，
    // 避免首次setter的late replay偶然替代显式注册，导致撤注册负控仍假通过。
    if(!early){consumer.activate(1);consumer.registerCallback(1);}consumer.activate(1);
    CHECK(owner.ready()==1&&consumer.ready()==0);
    std::puts("LOOK IMAGE Core hook readiness owner=1 consumer-local=0: actual publication authority differs");
    if(std::strcmp(argv[3],"no-callback")==0){
        auto clear=reinterpret_cast<void(*)()>(GetProcAddress(consumer.module,"lookFixtureNoGameCallback"));CHECK(clear);clear();
        CHECK(owner.submit(12)==1);consumer.pump();uint64_t values[7]{};double cursor[3]{};
        CHECK(consumer.observe(values,cursor)&&values[0]==0&&values[3]==1&&values[4]==0&&cursor[0]==112&&cursor[2]==112);
#if AMCL_INPUT_TRACE
        auto drain=reinterpret_cast<int(*)()>(GetProcAddress(consumer.module,"lookFixtureLatency"));CHECK(drain);CHECK(drain()==0);
#if AMCL_ILAT_EXPECT_AVAILABLE
        auto last=reinterpret_cast<void(*)(uint64_t*)>(GetProcAddress(consumer.module,"lookFixtureLatencyLast"));CHECK(last);
        uint64_t row[8]{};last(row);CHECK(row[0]==1&&row[1]==2&&row[2]==31&&row[3]==42&&row[4]>0);
#endif
#endif
        std::puts("LOOK IMAGE PASS no-callback: actual cache-only branch writes112 once, callback/return0; explicit terminal");return 0;
    }
#if AMCL_INPUT_TRACE && AMCL_ILAT_EXPECT_AVAILABLE
    if(std::strcmp(argv[3],"pre-dispatch-retire")==0){
        auto gate=reinterpret_cast<void(*)(int)>(GetProcAddress(owner.module,"lookFixtureCacheGate"));CHECK(gate);
        auto paused=reinterpret_cast<int(*)()>(GetProcAddress(owner.module,"lookFixtureCachePaused"));CHECK(paused);
        auto drain=reinterpret_cast<int(*)()>(GetProcAddress(consumer.module,"lookFixtureLatency"));CHECK(drain);
        gate(1);CHECK(owner.submit(12)==1);std::thread pumping([&]{consumer.pump();});
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
        while(!paused()){CHECK(std::chrono::steady_clock::now()<deadline);std::this_thread::yield();}
        consumer.activate(0);CHECK(drain()==0);gate(0);pumping.join();CHECK(drain()==1);
        auto last=reinterpret_cast<void(*)(uint64_t*)>(GetProcAddress(consumer.module,"lookFixtureLatencyLast"));CHECK(last);
        uint64_t row[8]{};last(row);CHECK(row[0]==1&&row[1]==6&&row[2]==63&&row[3]==42&&row[4]>0);
        // 现役cache后没有validate/skip分支；已捕获callback仍真实执行，不能为诊断改变此行为。
        std::puts("LOOK IMAGE PASS pre-dispatch-retire: real cache then deactivate before STATE_ONLY/callback; captured original callback returns; original POD survives");return 0;
    }
#endif
    if(std::strcmp(argv[3],"blocked")==0||std::strcmp(argv[3],"blocked-retire")==0){
        auto block=reinterpret_cast<void(*)(int)>(GetProcAddress(consumer.module,"lookFixtureBlockCallback"));CHECK(block);
        auto blocked=reinterpret_cast<int(*)()>(GetProcAddress(consumer.module,"lookFixtureCallbackBlocked"));CHECK(blocked);
        const bool retire=std::strcmp(argv[3],"blocked-retire")==0;
        if(retire){auto destroy=reinterpret_cast<void(*)()>(GetProcAddress(consumer.module,"lookFixtureDestroyOnCallback"));CHECK(destroy);destroy();}
        block(1);CHECK(owner.submit(12)==1);std::thread pumping([&]{consumer.pump();});
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
        while(!blocked()){CHECK(std::chrono::steady_clock::now()<deadline);std::this_thread::yield();}
        // 消费线程真实停在产品callback调用内；另一线程的实际owner尾导出不能以年龄或退休抢终态。
        std::this_thread::sleep_for(std::chrono::milliseconds(1100));
#if AMCL_INPUT_TRACE
        auto drain=reinterpret_cast<int(*)()>(GetProcAddress(consumer.module,"lookFixtureLatency"));CHECK(drain);
        CHECK(drain()==0);
        auto pendingLast=reinterpret_cast<void(*)(uint64_t*)>(GetProcAddress(consumer.module,"lookFixtureLatencyLast"));CHECK(pendingLast);
        uint64_t pendingRow[8]{};pendingLast(pendingRow);CHECK(pendingRow[0]==0); // 真记录数为0，不能只看complete数。
#endif
        block(0);pumping.join();
#if AMCL_INPUT_TRACE
#if AMCL_ILAT_EXPECT_AVAILABLE
        CHECK(drain()==1);
        auto last=reinterpret_cast<void(*)(uint64_t*)>(GetProcAddress(consumer.module,"lookFixtureLatencyLast"));CHECK(last);
        uint64_t row[8]{};last(row);CHECK(row[0]==1&&row[1]==(retire?6u:1u)&&row[2]==63&&row[3]==42&&row[4]>0);
#else
        CHECK(drain()==0);
#endif
#endif
        std::printf("LOOK IMAGE PASS blocked=%s: real callback >1s; concurrent drain=0; actual return retains original POD\n",retire?"retired-deleted-window":"active-window");return 0;
    }
    if(std::strcmp(argv[3],"full")==0||std::strcmp(argv[3],"busy")==0||std::strcmp(argv[3],"clock-fail")==0){
        auto repeat=reinterpret_cast<int(*)(double)>(GetProcAddress(owner.module,"lookFixtureRepeat"));CHECK(repeat);
        auto fault=reinterpret_cast<void(*)(int)>(GetProcAddress(owner.module,"lookFixtureDiagnosticFault"));CHECK(fault);
        if(std::strcmp(argv[3],"busy")==0)fault(2);if(std::strcmp(argv[3],"clock-fail")==0)fault(1);
        for(unsigned i=0;i<600;++i){CHECK(repeat(1)==1);consumer.pump();}
        fault(0);uint64_t values[7]{};double cursor[3]{};CHECK(consumer.observe(values,cursor));
        CHECK(values[0]==600&&values[3]==600&&values[4]==600&&cursor[0]==700&&cursor[2]==700);
        std::printf("LOOK IMAGE PASS stress=%s callbacks=600 cache=600 returned=600 cursor=700; diagnostic full/busy/clock never gates input\n",argv[3]);return 0;
    }
    if(std::strcmp(argv[3],"reentry")==0){
        auto destroy=reinterpret_cast<void(*)()>(GetProcAddress(consumer.module,"lookFixtureDestroyOnCallback"));CHECK(destroy);
        destroy();CHECK(owner.submit(12)==1);consumer.pump();
#if AMCL_INPUT_TRACE
        auto drain=reinterpret_cast<int(*)()>(GetProcAddress(consumer.module,"lookFixtureLatency"));CHECK(drain);
#if AMCL_ILAT_EXPECT_AVAILABLE
        CHECK(drain()==1);
#else
        CHECK(drain()==0);
#endif
#endif
        std::puts("LOOK IMAGE PASS reentry: callback really retired/deleted window; product returns with original POD only");return 0;
    }
    if(shortOwner){
        // 真实owner继续持原ring与资源；第二映像遇到短/未知尾部不得begin或在本地接受来源。
        CHECK(consumer.submit(12)==0&&consumer.action()==0&&consumer.sourceAction()==0&&consumer.processed(1)==0);consumer.pump();
        uint64_t values[7]{};double cursor[3]{};CHECK(!consumer.observe(values,cursor)&&values[0]==0&&cursor[0]==100);
        std::puts("LOOK IMAGE PASS short/version owner: delegate transport NotReady, no local acceptance or callback; host ABI only");return 0;
    }
    if(nullEarly){
        CHECK(owner.submit(12)==1);consumer.pump();uint64_t values[7]{};double cursor[3]{};
        CHECK(!consumer.observe(values,cursor)&&values[0]==0&&cursor[0]==100);
        consumer.registerCallback(1);CHECK(owner.submit(7)==1);consumer.pump();CHECK(consumer.observe(values,cursor));
        CHECK(values[0]==1&&values[3]==1&&values[4]==1&&cursor[0]==107);
        std::puts("LOOK IMAGE PASS early-null: latest NULL replayed, old prefix retired, fresh callback cursor=107; host ABI only");return 0;
    }
    // 第一笔从真实owner提交，原缺setter转发的代码能接受并排空但无callback，此断言重现它。
    CHECK(owner.submit(12)==1);consumer.pump();uint64_t values[7]{};double cursor[3]{};
    const int observed=consumer.observe(values,cursor);
    std::printf("LOOK IMAGE first mode=%s observed=%d callbacks=%llu consumer=%llu cache=%llu returned=%llu owner=%llu local=%llu cursor=%.3f/%.3f\n",
        argv[3],observed,(unsigned long long)values[0],(unsigned long long)values[2],(unsigned long long)values[3],
        (unsigned long long)values[4],(unsigned long long)values[5],(unsigned long long)values[6],cursor[0],cursor[2]);
    CHECK(observed&&values[0]==1&&values[3]==1&&values[4]==1&&values[5]!=values[6]&&cursor[0]==112&&cursor[2]==112);
    // 再从delegate提交，验证新组的resource、stream与运输均借真实owner，动作看见前一cursor。
    CHECK(consumer.submit(8)==1&&consumer.action()==1);consumer.pump();CHECK(consumer.observe(values,cursor));
    CHECK(values[0]==2&&values[1]==1&&values[3]==2&&values[4]==2&&cursor[0]==120&&cursor[1]==120&&cursor[2]==120);
    // NULL真实注销owner callback并退休该backend。排队的旧prefix不能借后来重新注册执行。
    // 留旧prefix排队直到重开后一起pump，直接证明旧token没有借新资格复活。
    CHECK(owner.submit(5)==1);consumer.registerCallback(0);
    consumer.registerCallback(1);consumer.activate(1);CHECK(owner.submit(7)==1);consumer.pump();CHECK(consumer.observe(values,cursor));
    std::printf("LOOK IMAGE after retirement callbacks=%llu cache=%llu returned=%llu cursor=%.3f ownerCursor=%.3f\n",
        (unsigned long long)values[0],(unsigned long long)values[3],(unsigned long long)values[4],cursor[0],cursor[2]);
    // backend重新激活重建本consumer统计基线；累计真实游戏callback仍为3，旧5像素不能补进新cursor。
    CHECK(values[0]==3&&cursor[0]==127&&values[3]==1&&values[4]==1);
    CHECK(consumer.processed(1)==1&&consumer.sourceAction()==1);consumer.pump();CHECK(consumer.observe(values,cursor));
    CHECK(values[0]==4&&values[1]==2&&cursor[0]==128&&cursor[1]==128&&cursor[2]==128);
    consumer.activate(0);consumer.registerCallback(0);
#if AMCL_INPUT_TRACE
    auto drain=reinterpret_cast<int(*)()>(GetProcAddress(consumer.module,"lookFixtureLatency"));CHECK(drain);
#if AMCL_ILAT_EXPECT_AVAILABLE
    CHECK(drain()>=2); // 真跨DLL cache/返回与prefix/ring两种order绑定，不能靠Ready文本。
#else
    CHECK(drain()==0); // 原输入输出照常通过；旧/OFF诊断tail只让观察缺席。
#endif
#endif
    std::printf("LOOK IMAGE PASS mode=%s callbacks=%llu consumer=%llu cache=%llu returned=%llu cursor=%.3f key=%.3f owner=%llu local=%llu; host ABI only\n",
        argv[3],(unsigned long long)values[0],(unsigned long long)values[2],(unsigned long long)values[3],(unsigned long long)values[4],
        cursor[0],cursor[1],(unsigned long long)values[5],(unsigned long long)values[6]);
    // 映像由进程pin，禁止以FreeLibrary制造借用callback或port的悬空安全错觉。
}
