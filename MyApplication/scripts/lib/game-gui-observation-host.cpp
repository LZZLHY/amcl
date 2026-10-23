/**
 * 完整生产GUI/Java/Core/退出State + stock JNI组合。游戏对象仅提供成员和真实Executor，
 * GUI政策不在fixture重写；事件线程只能调用Native缓存/lease端口。所有游戏fixture推进
 * 都从独立真实JNI线程完成。参考组链接原45b同步GUI正文，原3s/code0轨迹必须可识别。
 */
#define NOMINMAX
#include <windows.h>
#include <direct.h>
#include <jni.h>
#include <array>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include "runtime_bootstrap_contract.h"
#include "game_process_exit_core.h"
#include "game_gui_observation.h"
#include "input_state_core.h"
#include "input_surface_context_snapshot.h"

namespace {
JavaVM* g_jvm=nullptr;
amcl::jvm::RuntimeOnce g_runtimeOnce;
amcl::gameexit::State state;
HANDLE pendingPublished=nullptr;
ULONGLONG start=0;
std::mutex logs;
void log(const char* event,long long value=0){std::lock_guard<std::mutex> guard(logs);std::printf("EVENT t_ms=%llu tid=%lu name=%s value=%lld\n",GetTickCount64()-start,GetCurrentThreadId(),event,value);std::fflush(stdout);}
[[noreturn]] void fail(const char* name){log("GUI_OBSERVATION_FAIL");std::fprintf(stderr,"GUI_OBSERVATION_FAIL %s\n",name);std::fflush(stderr);_exit(11);}
void check(bool value,const char* name){if(!value)fail(name);std::printf("CHECK %s\n",name);std::fflush(stdout);}
#include "game-gui-observation-test-io.h"
WindowsOperations operations;
}
// 真实RuntimeOnce/原exit State的薄入口，与生产forward相同；不是fakeJNI方法。
extern "C" int jvmRuntimeState(){return g_runtimeOnce.state();}
extern "C" void* jvmGetJavaVM(){return g_jvm;}
extern "C" bool amclGameExitPendingForCurrentProcess(void){return state.pending(operations);}
// 本宿主只有一个真实Core owner，无跨DSO桥委派对象；固定为生产公开入口的真实Core
// fallback分支。此处只去除namespace路由层，绝不伪造snapshot/context/生命周期。
extern "C" int inputBridge_readSurfaceContextV1(AmclInputSurfaceContextPayload* value){return amcl_input_owner_read_surface_context(value);}

namespace {
void JNICALL exitHook(jint code){
    log("exit_hook_code",code);log("exit_hook_ready",jvmRuntimeState());
    if(!state.emit(operations,code)){log("emit_failed");_exit(code);}
    SetEvent(pendingPublished);const auto began=GetTickCount64();const char* result=state.waitForHandoff(operations);
    log(result,GetTickCount64()-began);std::fflush(stdout);_exit(code);
}
/** JNI控制游戏fixture的线程与Native事件线程严格分开，所有调用是真实stock JNI。 */
int java(const char* name,const char* signature="()V",int argument=0){
    int value=0;std::thread work([&]{
        JNIEnv* env=nullptr;if(g_jvm->AttachCurrentThreadAsDaemon(reinterpret_cast<void**>(&env),nullptr)!=JNI_OK)fail("real fixture attach");
        jclass fixture=env->FindClass("net/minecraft/client/Minecraft");jmethodID method=env->GetStaticMethodID(fixture,name,signature);
        if(!method || env->ExceptionCheck())fail("real fixture method");
        if(std::strcmp(signature,"()I")==0)value=env->CallStaticIntMethod(fixture,method);
        else if(std::strcmp(signature,"(I)V")==0)env->CallStaticVoidMethod(fixture,method,argument);
        else env->CallStaticVoidMethod(fixture,method);
        if(env->ExceptionCheck()){env->ExceptionDescribe();fail("real fixture Java exception");}
        env->DeleteLocalRef(fixture);if(g_jvm->DetachCurrentThread()!=JNI_OK)fail("real fixture detach");
    });work.join();return value;
}
const AmclInputHostApiV1* api=nullptr;
uint64_t coreSession=0,resourceGeneration=0;
void publishWindow(){
    ++resourceGeneration;AmclInputSurfacePayload surface{};surface.active=1;surface.widthPx=1920;surface.heightPx=1080;
    surface.density=1;surface.validFields=AMCL_INPUT_SURFACE_FIELD_ALL;surface.publicationGeneration=resourceGeneration;
    check(api->publishSurface(&surface)>=AMCL_INPUT_OK,"real core surface published");
    AmclInputEvent event{};event.header.abiVersion=AMCL_INPUT_EVENT_ABI_VERSION;event.header.structSize=sizeof(event);
    event.header.eventType=AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED;event.header.sessionEpoch=coreSession;
    event.payload.surfaceContext.windowId=1;event.payload.surfaceContext.displayId=1;
    event.payload.surfaceContext.widthPx=1920;event.payload.surfaceContext.heightPx=1080;event.payload.surfaceContext.density=1;
    event.payload.surfaceContext.generation=resourceGeneration;event.payload.surfaceContext.validFields=AMCL_INPUT_SURFACE_CONTEXT_FIELD_ALL;
    event.payload.surfaceContext.refreshRateHz=60;
    check(api->submitEvent(&event)>=AMCL_INPUT_OK,"real core window identity published");
}
#ifndef AMCL_GUI_SYNC_REFERENCE
std::array<double,19> read(uint32_t source){std::array<double,19> values{};amcl_read_game_gui_for_source(source,1920,1080,"26.4-snapshot-1",values.data(),false);return values;}
bool until(const std::function<bool()>& predicate,int milliseconds=5000){const auto end=GetTickCount64()+milliseconds;do{if(predicate())return true;Sleep(10);}while(GetTickCount64()<end);return false;}
std::array<double,19> ready(uint32_t source,bool writable=true){std::array<double,19> values{};check(until([&]{values=read(source);java("runTasks");return values[0]==2 && values[9]==(writable?1:0);}),"real async GUI valid");return values;}
void liveCases(uint32_t& scope,uint32_t& source){
    auto values=ready(source);check(values[1]==4,"live actual GUI scale");
    // 两来源同revision恢复同值是合法操作。Java仅保最新ACK，Native必须先捕获A真实
    // 完成再交付B，不能由B覆盖A的Java ID而让A永久Executing/Pending。
    const uint32_t peer=amcl_game_gui_attach_source(scope);check(peer>0,"second real GUI source");
    auto peerValues=ready(peer);values=ready(source);
    check(until([&]{java("runTasks");auto work=amcl::gui::ReadDiagnostics();return work.inFlight==0 && work.queuedReads==0 && java("queued","()I")==0;}),"dual source observations drained");
    const uint32_t first=amcl_restore_game_gui_for_source(source,4,static_cast<uint64_t>(values[8]));
    check(first>0 && until([&]{return amcl::gui::ReadTicketDiagnostics(source).javaId>0;}),"A actual same-value Java request queued");
    const uint32_t second=amcl_restore_game_gui_for_source(peer,4,static_cast<uint64_t>(peerValues[8]));
    check(second>0 && second!=first,"B keeps independent Pending ticket");
    check(until([&]{java("runTasks");return amcl::gui::ReadTicketDiagnostics(peer).javaId>0;}),"B Java delivery eventually follows A");
    check(amcl::gui::ReadTicketDiagnostics(source).result==2,"A real ACK captured before B can overwrite Java latest ACK");
    check(until([&]{java("runTasks");return amcl::gui::ReadTicketDiagnostics(peer).result==2;}),"B own actual ACK completed");
    check(amcl::gui::ReadTicketDiagnostics(source).result==2 && java("scale","()I")==4,"both source ACKs retained and same-value restore legal");
    check(amcl_game_gui_retire_source(peer),"peer source retired independently");values=ready(source);
    uint32_t ticket=amcl_restore_game_gui_for_source(source,2,static_cast<uint64_t>(values[8]));check(ticket>0,"restore native enqueue ticket");
    values=read(source);check(values[10]==ticket && values[11]==1,"enqueue is Pending not completed");
    check(until([&]{java("runTasks");values=read(source);return values[10]==ticket && values[11]==2;}),"real Java ACK mapped to Native ticket");
    check(java("scale","()I")==2,"restore actual Java option written");

    // 关闭视觉读取后只让真实游戏线程推进，Native在途维护仍继续取结果。
    values=ready(source);ticket=amcl_restore_game_gui_for_source(source,3,static_cast<uint64_t>(values[8]));check(ticket>0,"no observer restore accepted");
    check(until([&]{java("runTasks");return java("scale","()I")==3;}),"without visual read source restore progresses");
    check(until([&]{auto ack=amcl::gui::ReadTicketDiagnostics(source);return ack.id==ticket && ack.result==2;}),"Native ACK maintained without visual subscriber");
    values=read(source);check(values[10]==ticket && values[11]==2,"source reads maintained ACK");

    // 真实Java执行队列尚未运行时退休window，原JNI native guard必须拒绝迟到写。
    values=ready(source);
    check(until([&]{java("runTasks");auto work=amcl::gui::ReadDiagnostics();return work.inFlight==0 && work.queuedReads==0 && java("queued","()I")==0;}),"prior observation tasks actually drained");
    const int before=java("scale","()I");ticket=amcl_restore_game_gui_for_source(source,2,static_cast<uint64_t>(values[8]));check(ticket>0,"window cancel restore queued");
    check(until([&]{return amcl::gui::ReadTicketDiagnostics(source).javaId>0;}),"real Java restore accepted but not executed");publishWindow();
    java("runTasks");check(java("scale","()I")==before,"retired real window rejects queued restore");
    values=read(source);check(values[10]==ticket && values[11]==3,"old resource ticket has Cancelled ACK");

    // 原2s队列预算在没有视觉读取时也成立；迟到游戏任务实际执行时不得写设置。
    values=ready(source);
    check(until([&]{java("runTasks");auto work=amcl::gui::ReadDiagnostics();return work.inFlight==0 && work.queuedReads==0 && java("queued","()I")==0;}),"deadline case observations drained");
    ticket=amcl_restore_game_gui_for_source(source,2,static_cast<uint64_t>(values[8]));check(ticket>0,"2s restore ticket accepted");
    check(until([&]{return amcl::gui::ReadTicketDiagnostics(source).javaId>0;}),"2s real Java task queued");
    const auto queuedAt=GetTickCount64();
    check(until([&]{return amcl::gui::ReadTicketDiagnostics(source).result==3;},3000),"2s queued deadline maintained without visual reads");
    log("queued_restore_deadline_ms",GetTickCount64()-queuedAt);
    java("runTasks");check(java("scale","()I")==before,"expired actual game task cannot write");

    // 用户已有更新必须由真实Java原值检查保留，不能因Native资源尚活着就覆盖。
    values=ready(source);
    check(until([&]{java("runTasks");auto work=amcl::gui::ReadDiagnostics();return work.inFlight==0 && work.queuedReads==0 && java("queued","()I")==0;}),"user-value case observations drained");
    ticket=amcl_restore_game_gui_for_source(source,2,static_cast<uint64_t>(values[8]));check(ticket>0,"user-value restore queued");
    check(until([&]{return amcl::gui::ReadTicketDiagnostics(source).javaId>0;}),"user-value real Java enqueue");
    java("chooseScale","(I)V",5);java("runTasks");
    check(until([&]{java("runTasks");values=read(source);return values[10]==ticket && values[11]==3;}),"Java original-value refusal maps to Cancelled");
    check(java("scale","()I")==5,"new user scale is never overwritten");

    // 复审真实反例：最后before=Option.get正在阻塞时，Native来源或window已经退休。
    // 必须在全部阻塞读取后才取得Begin；不是将早先Begin当成已经调用了实际set。
    for(int boundary=0;boundary<2;boundary++) {
        values=ready(source);
        check(until([&]{java("runTasks");auto work=amcl::gui::ReadDiagnostics();return work.inFlight==0 && work.queuedReads==0 && java("queued","()I")==0;}),"write boundary prior reads drained");
        const int retained=java("scale","()I");
        ticket=amcl_restore_game_gui_for_source(source,2,static_cast<uint64_t>(values[8]));check(ticket>0,"write boundary ticket queued");
        check(until([&]{return amcl::gui::ReadTicketDiagnostics(source).javaId>0;}),"write boundary actual Java restore queued");
        java("armGetterBlock","(I)V",3);
        std::thread game([]{java("runTasks");});
        check(until([&]{return java("getterBlocked","()I")==1;}),"actual last restore Option.get BLOCKED before set");
        if(boundary==0)check(amcl_game_gui_retire_source(source),"retire source before real set");else publishWindow();
        check(!amcl::gui::TicketCurrent(ticket),"original native write qualification retired");
        java("releaseGetter");game.join();
        check(java("scale","()I")==retained,boundary==0?"retired source cannot write after blocked get":"retired window cannot write after blocked get");
        if(boundary==0){source=amcl_game_gui_attach_source(scope);check(source>0,"new source after boundary cancellation");}
    }

    // worker已在真实Java monitor里忙，UI缓存读取、source/scope退休与下一scope注册不能等JNI。
    java("blockBridge");read(source);
    check(until([&]{return amcl::gui::ReadDiagnostics().inFlight!=0 && java("blockedObserver","()I")>0;}),"stock JVM confirms observer BLOCKED on held monitor");
    const auto begin=GetTickCount64();read(source);check(amcl_game_gui_retire_source(source),"source retired while JNI busy");
    check(amcl_game_gui_stop_session(scope),"session stopped without worker join");
    scope=amcl_game_gui_start_session(2);source=amcl_game_gui_attach_source(scope);
    check(scope && source,"new scope source attached while worker busy");
    check(GetTickCount64()-begin<100,"event ports bounded while worker busy");
    const auto discarded=amcl::gui::ReadDiagnostics().discarded;java("releaseBridge");
    check(until([&]{return amcl::gui::ReadDiagnostics().discarded>discarded;}),"old in-flight completion discarded after scope retirement");
    ready(source);
    check(amcl_game_gui_stop_session(scope),"scope closed for capacity case");scope=amcl_game_gui_start_session(3);
    std::array<uint32_t,16> leases{};for(auto& lease:leases)lease=amcl_game_gui_attach_source(scope);
    for(auto lease:leases)check(lease>0,"real source lease within capacity");
    check(amcl_game_gui_attach_source(scope)==0,"17th source explicitly rejected");
    source=leases[0];check(amcl_game_gui_attach_source(scope-1)==0,"old scope cannot acquire new source");ready(source);
}
#endif
}

int main(int argc,char** argv){
    if(argc!=6)return 2;start=GetTickCount64();const std::string mode=argv[1],dll=argv[2],classPath=argv[3];
    operations.initialize(argv[4]);check(state.authorize(operations,operations.logical.c_str(),std::atoi(argv[5]),operations.lock)==0,"original exit authority");
    check(state.prepare(operations,operations.logical.c_str(),1791418000000LL)==0,"original exit State prepared");
    pendingPublished=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    auto module=LoadLibraryExA(dll.c_str(),nullptr,LOAD_WITH_ALTERED_SEARCH_PATH);if(!module)fail("load actual jvm.dll");
    char loaded[4096]{};GetModuleFileNameA(module,loaded,sizeof(loaded));std::printf("LOADED_JVM %s\n",loaded);std::fflush(stdout);
    auto create=reinterpret_cast<jint(JNICALL*)(JavaVM**,void**,void*)>(GetProcAddress(module,"JNI_CreateJavaVM"));
    check(g_runtimeOnce.begin(),"original RuntimeOnce claim");
    std::thread creator([&]{JNIEnv* env=nullptr;std::string cp="-Djava.class.path="+classPath;
        JavaVMOption options[3]{{cp.data(),nullptr},{const_cast<char*>("-Xmx64m"),nullptr},{const_cast<char*>("exit"),reinterpret_cast<void*>(exitHook)}};
        JavaVMInitArgs args{};args.version=JNI_VERSION_1_8;args.nOptions=3;args.options=options;
        if(create(&g_jvm,reinterpret_cast<void**>(&env),&args)!=JNI_OK)fail("real JNI create");
        g_runtimeOnce.ready();jclass game=env->FindClass("net/minecraft/client/Minecraft");
        if(!game || env->ExceptionCheck())fail("real initialized game fixture");
        // FindClass只保证loaded；真正读取静态单例，证明JVMTI准入前已INITIALIZED。
        jfieldID singleton=env->GetStaticFieldID(game,"INSTANCE","Lnet/minecraft/client/Minecraft;");
        jobject instance=singleton?env->GetStaticObjectField(game,singleton):nullptr;
        if(!instance || env->ExceptionCheck())fail("real fixture initialized singleton");env->DeleteLocalRef(instance);env->DeleteLocalRef(game);
        check(g_jvm->DetachCurrentThread()==JNI_OK,"creator actual detach");
    });creator.join();
    api=amclInputGetHostApiV1();check(api && api->beginSession(&coreSession)==AMCL_INPUT_OK,"real Core session");publishWindow();
#ifndef AMCL_GUI_SYNC_REFERENCE
    uint32_t scope=amcl_game_gui_start_session(1),source=amcl_game_gui_attach_source(scope);check(scope && source,"GUI session/source explicit");
    if(mode=="live")liveCases(scope,source);
    else if(mode=="old-helper"){auto values=ready(source,false);check(amcl_restore_game_gui_for_source(source,2,static_cast<uint64_t>(values[8]))==0,"old helper observes but cannot scoped restore");}
    else ready(source);
    // 在实际Java monitor内保留JNI工作再触发System.exit，证明不是仅Pending if避开JNI的结果。
    java("blockBridge");read(source);check(until([&]{return amcl::gui::ReadDiagnostics().inFlight!=0 && java("blockedObserver","()I")>0;}),"shutdown stock JVM observer BLOCKED before Pending");
#else
    double live[19]{};amcl_read_game_gui(1920,1080,"26.4-snapshot-1",live,false);java("runTasks");
    amcl_read_game_gui(1920,1080,"26.4-snapshot-1",live,false);check(live[0]==2,"original sync GUI live calibrated");
#endif
    std::thread exiting([]{JNIEnv* env=nullptr;g_jvm->AttachCurrentThreadAsDaemon(reinterpret_cast<void**>(&env),nullptr);
        jclass system=env->FindClass("java/lang/System");jmethodID exit=env->GetStaticMethodID(system,"exit","(I)V");
        log("real_System_exit",0);env->CallStaticVoidMethod(system,exit,static_cast<jint>(0));fail("unexpected System.exit return");});exiting.detach();
    check(WaitForSingleObject(pendingPublished,6000)==WAIT_OBJECT_0,"original native Pending published");log("event_pending",amclGameExitPendingForCurrentProcess());
#ifdef AMCL_GUI_SYNC_REFERENCE
    log("original_pending_gui_enter");double values[19]{};amcl_read_game_gui(1920,1080,"26.4-snapshot-1",values,false);log("unexpected_original_gui_return");
#else
    auto begin=GetTickCount64();read(source);check(amcl_game_gui_stop_session(scope),"stop UI lease while VM stopped");
    log("async_event_getter_returned",GetTickCount64()-begin);check(GetTickCount64()-begin<100,"stopped JVM cannot block event ports");
#endif
    Sleep(1000);log("same_event_thread_exit_poll",amclGameExitPendingForCurrentProcess());int code=0;
    check(state.acknowledge(operations,code)==amcl::gameexit::Acknowledgement::Owned && code==0,"original same-thread ACK code0");
    Sleep(3500);fail("exit hook did not terminate");
}
