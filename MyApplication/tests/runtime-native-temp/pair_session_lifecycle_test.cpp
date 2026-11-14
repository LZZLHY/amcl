/**
 * 直接包含r3真实session正文。替身只控制SDK/NAPI事件顺序与错误，不宣称真机/VM通过。
 * 检查固定两个owner、8秒清理边界、正常迟到回收、env关闭后禁用投递，以及创建失败反向释放。
 * 计数覆盖provider、TSFN、cleanup hook和真实打开的FD；失败现场留在独占宿主输出目录。
 */
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <poll.h>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include <dirent.h>
#include "../../entry/src/main/cpp/napi/jdk_native_temp_pair_owner.h"
#include "platform/jdk_install_io.h"
using Clock=std::chrono::steady_clock;
namespace io=amcl::jdk::io;
using napi_env=void*;using napi_value=void*;using ExitFn=void(*)(int32_t,int32_t);
enum napi_status{napi_ok,napi_generic_failure,napi_closing,napi_queue_full};
enum napi_threadsafe_function_call_mode{napi_tsfn_nonblocking};
enum napi_threadsafe_function_release_mode{napi_tsfn_release,napi_tsfn_abort};
using CallJs=void(*)(napi_env,napi_value,void*,void*);using Finalize=void(*)(napi_env,void*,void*);
struct FakeTsfn{
 std::atomic<int> references{1},inCall{0};std::atomic<bool> closing{false};
 void* data;void* context;Finalize finalize;CallJs invoke;
};
using napi_threadsafe_function=FakeTsfn*;
static std::atomic<int> tsfnAlive{0},providers{0},unregistered{0},kills{0},napiCalls{0};
static std::atomic<bool> active{false},blockAcquire{false},acquireEntered{false},resumeAcquire{false};
static bool failCreate=false,failHookAdd=false,failHookRemove=false,failUnref=false,failAcquire=false,failCall=false;
static bool failNativeThread=false;
static int unregisterCode=0;
static std::atomic<int> nativeThreads{0};
static thread_local bool inSdkCallback=false;
static std::mutex sdkMutex;static std::condition_variable sdkCondition;static int sdkActive=0;
static std::mutex fakeMutex;static FakeTsfn* pending=nullptr;
static void(*environmentHook)(void*)=nullptr;static void* hookData=nullptr;
static int killStub(int32_t){++kills;return 77;}
struct ChildProcessProvider{
 ChildProcessProvider(){++providers;}~ChildProcessProvider(){assert(!inSdkCallback);--providers;}
 int(*function()const)(int32_t){return killStub;}
};
int OH_Ability_UnregisterNativeChildProcessExitCallback(ExitFn){
 assert(!inSdkCallback);std::unique_lock<std::mutex>g(sdkMutex);sdkCondition.wait(g,[]{return sdkActive==0;});++unregistered;return unregisterCode;
}
static void destroy(FakeTsfn* f){assert(f->references==0 && f->inCall==0);f->finalize(nullptr,f->data,nullptr);delete f;--tsfnAlive;}
napi_status napi_create_threadsafe_function(napi_env,napi_value,napi_value,napi_value,size_t,size_t,void* data,Finalize finalize,void* context,CallJs invoke,FakeTsfn** out){
 ++napiCalls;if(failCreate)return napi_generic_failure;
 *out=new FakeTsfn;(*out)->data=data;(*out)->context=context;(*out)->finalize=finalize;(*out)->invoke=invoke;++tsfnAlive;return napi_ok;
}
napi_status napi_add_env_cleanup_hook(napi_env,void(*fn)(void*),void* data){
 ++napiCalls;if(failHookAdd)return napi_generic_failure;assert(!environmentHook);environmentHook=fn;hookData=data;return napi_ok;
}
napi_status napi_remove_env_cleanup_hook(napi_env,void(*fn)(void*),void* data){
 ++napiCalls;if(failHookRemove)return napi_generic_failure;assert(environmentHook==fn && hookData==data);environmentHook=nullptr;hookData=nullptr;return napi_ok;
}
napi_status napi_unref_threadsafe_function(napi_env,FakeTsfn*){++napiCalls;return failUnref?napi_generic_failure:napi_ok;}
napi_status napi_acquire_threadsafe_function(FakeTsfn* f){
 ++napiCalls;if(failAcquire)return napi_generic_failure;
 if(blockAcquire){acquireEntered=true;while(!resumeAcquire)std::this_thread::yield();}
 assert(f->references>0);if(f->closing)return napi_closing;++f->references;return napi_ok;
}
napi_status napi_release_threadsafe_function(FakeTsfn* f,napi_threadsafe_function_release_mode mode){
 ++napiCalls;std::lock_guard<std::mutex>g(fakeMutex);
 if(mode==napi_tsfn_abort){f->closing=true;if(pending==f)pending=nullptr;}
 assert(f->references>0);if(--f->references==0 && pending!=f)destroy(f);return napi_ok;
}
napi_status napi_call_threadsafe_function(FakeTsfn* f,void*,napi_threadsafe_function_call_mode){
 ++napiCalls;if(failCall)return napi_generic_failure;std::lock_guard<std::mutex>g(fakeMutex);
 if(f->closing)return napi_closing;
 if(pending)return napi_queue_full;
 ++f->inCall;pending=f;--f->inCall;return napi_ok;
}
void writeNew(int root,const std::string& name,const std::string& text){
 io::Fd fd(openat(root,name.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600));assert(fd.get()>=0);io::Write(fd.get(),text.data(),text.size());
}
struct NativeTempPairSession;struct Job{std::shared_ptr<NativeTempPairSession> pair;};
static int testPthreadCreate(pthread_t* thread,const pthread_attr_t* attrs,void*(*fn)(void*),void* data){
 if(failNativeThread)return EAGAIN;
 ++nativeThreads;return pthread_create(thread,attrs,fn,data);
}
#define pthread_create testPthreadCreate
#include AMCL_PAIR_SESSION_BODY
#undef pthread_create
static napi_env env=reinterpret_cast<void*>(1);
static void handleJs(){FakeTsfn* p;{std::lock_guard<std::mutex>g(fakeMutex);p=pending;pending=nullptr;}assert(p);p->invoke(env,nullptr,p->context,nullptr);}
static void closeEnv(){assert(environmentHook);auto fn=environmentHook;auto data=hookData;environmentHook=nullptr;hookData=nullptr;fn(data);}
static void deliverExit(int32_t pid){
 {std::lock_guard<std::mutex>g(sdkMutex);++sdkActive;}inSdkCallback=true;nativeTempPairExit(pid,0);inSdkCallback=false;
 {std::lock_guard<std::mutex>g(sdkMutex);--sdkActive;}sdkCondition.notify_all();
}
static int fdCount(){DIR* d=opendir("/proc/self/fd");assert(d);int count=0;while(readdir(d))++count;closedir(d);return count;}
static std::shared_ptr<NativeTempPairSession> create(const std::string& out){
 Job j;assert(prepareNativeTempPair(env,nullptr,j)==napi_ok);auto s=j.pair;
 s->provider.reset(new ChildProcessProvider);assert(mkdir(out.c_str(),0700)==0);s->pairDirectory=io::Directory(out);s->registered=true;
 for(auto& fd:s->readers)fd=io::Fd(open("/dev/null",O_RDONLY|O_CLOEXEC));
 {std::lock_guard<std::mutex>g(pairCallbackMutex);assert(!pairCallbackOwner);pairCallbackOwner=s;}active=true;
 assert(s->exits.start(0,[](int32_t*p){*p=101;return 0;})==0);assert(s->exits.start(1,[](int32_t*p){*p=102;return 0;})==0);return s;
}
static void seal(const std::shared_ptr<NativeTempPairSession>& s){s->exits.seal();s->exits.releaseWorker();}
static void completed(){assert(!active && !pairCallbackOwner && !environmentHook && !pending && providers==0 && tsfnAlive==0);}
static void waitCompleted(){const auto limit=Clock::now()+std::chrono::seconds(2);while(active && Clock::now()<limit)std::this_thread::yield();completed();}
// 仅宿主用：模拟进程重启释放静态owner。产品路径不会把此动作包装成回收成功。
static void simulatedParentExit(std::shared_ptr<NativeTempPairSession>& s){
 assert(s->environmentClosed && s->dispatchFailed && active && !pending && !environmentHook && tsfnAlive==0);
 pairCallbackOwner.reset();s.reset();active=false;completed();
}
int main(int argc,char**argv){
 assert(argc==2);std::string root=argv[1];const int baseline=fdCount();
 {
  auto s=create(root+"/late");std::weak_ptr<NativeTempPairSession>w=s;auto before=Clock::now();s->stopBounded();
  const auto seconds=std::chrono::duration<double>(Clock::now()-before).count();assert(seconds>=8 && seconds<9 && s->cleanupIncomplete && kills>0);
  s->exits.releaseWorker();s.reset();assert(!w.expired() && active && providers==1 && tsfnAlive==1);
  nativeTempPairExit(101,0);assert(!pending);nativeTempPairExit(102,0);handleJs();assert(w.expired());completed();assert(fdCount()==baseline);
 }
 for(int round=0;round<200;++round){
  auto s=create(root+"/normal-"+std::to_string(round));seal(s);
  std::thread a([]{nativeTempPairExit(101,0);}),b([]{nativeTempPairExit(102,0);});a.join();b.join();
  handleJs();assert(s->exits.snapshot().reclaimed);s.reset();completed();assert(fdCount()==baseline);
 }
 {
  Job j;assert(prepareNativeTempPair(env,nullptr,j)==napi_ok);std::weak_ptr<NativeTempPairSession>w=j.pair;
  cancelUnstartedNativeTempPair(env,j);assert(w.expired());completed();
 }
 for(int kind=0;kind<3;++kind){
  failCreate=kind==0;failHookAdd=kind==1;failUnref=kind==2;
  Job j;assert(prepareNativeTempPair(env,nullptr,j)!=napi_ok && !j.pair);completed();
  failCreate=failHookAdd=failUnref=false;
 }
 {
  auto s=create(root+"/env-before-exit");seal(s);closeEnv();const auto calls=napiCalls.load();
  deliverExit(101);deliverExit(102);waitCompleted();assert(s->exits.allExited() && napiCalls==calls && s->exits.snapshot().reclaimed);
  s.reset();assert(fdCount()==baseline);
 }
 {
  auto s=create(root+"/queued-then-env");seal(s);nativeTempPairExit(101,0);nativeTempPairExit(102,0);assert(pending);closeEnv();
  waitCompleted();assert(!pending && s->exits.snapshot().reclaimed);s.reset();assert(fdCount()==baseline);
  // 官方TSFN先finalizer再以空env清剩余队列；传失效context也不得解引用。
  reclaimNativeTempPair(nullptr,nullptr,reinterpret_cast<void*>(1),nullptr);
 }
 {
  // 精确卡在acquire内部：env hook必须等投递临界区完成，不能释放那个已读出的TSFN。
  auto s=create(root+"/acquire-vs-env");seal(s);nativeTempPairExit(101,0);
  blockAcquire=true;acquireEntered=false;resumeAcquire=false;std::atomic<bool> closeStarted{false},closeDone{false};
  std::thread sdk([]{deliverExit(102);});while(!acquireEntered)std::this_thread::yield();
  std::thread teardown([&]{closeStarted=true;closeEnv();closeDone=true;});while(!closeStarted)std::this_thread::yield();
  std::this_thread::sleep_for(std::chrono::milliseconds(10));assert(!closeDone && tsfnAlive==1);
  resumeAcquire=true;sdk.join();teardown.join();blockAcquire=false;assert(closeDone);waitCompleted();s.reset();assert(fdCount()==baseline);
 }
 for(int kind=0;kind<3;++kind){
  auto s=create(root+"/dispatch-failure-"+std::to_string(kind));seal(s);
  failAcquire=kind==0;failCall=kind==1;failHookRemove=kind==2;
  nativeTempPairExit(101,0);nativeTempPairExit(102,0);if(kind==2)handleJs();
  assert(s->dispatchFailed && active && pairCallbackOwner && !s->exits.snapshot().reclaimed);
  failAcquire=failCall=failHookRemove=false;closeEnv();waitCompleted();s.reset();assert(fdCount()==baseline);
 }
 {
  auto s=create(root+"/thread-create-failure");seal(s);closeEnv();failNativeThread=true;
  deliverExit(101);deliverExit(102);assert(s->reclaimThreadError==EAGAIN && !s->exits.snapshot().reclaimed && active);
  const auto failure=io::SmallFile(s->pairDirectory.get(),"owner-cleanup-failed.json",4096);
  assert(failure.find("\"threadCreateResult\":"+std::to_string(EAGAIN))!=std::string::npos && failure.find("\"restartRequired\":true")!=std::string::npos);
  // 无实际线程创建即失败，不能自动循环重试；只有真实外部重启能收尾这一失败现场。
  failNativeThread=false;simulatedParentExit(s);assert(fdCount()==baseline);
 }
 {
  auto s=create(root+"/unregister-failure");seal(s);unregisterCode=77;
  nativeTempPairExit(101,0);nativeTempPairExit(102,0);handleJs();assert(s->dispatchFailed && s->exits.snapshot().reclaimed);
  assert(active && !pairCallbackOwner && !environmentHook && !pending && providers==0 && tsfnAlive==0);
  const auto proof=io::SmallFile(AT_FDCWD,root+"/unregister-failure/owner-reclaimed.json",4096);
  assert(proof.find("\"unregisterResult\":77")!=std::string::npos && proof.find("\"restartRequired\":true")!=std::string::npos);
  s.reset();unregisterCode=0;active=false;completed();assert(fdCount()==baseline);
 }
 printf("PASS actual r3 session: 200 normal races; bounded 8s late exits; cancel; create/add-hook/unref errors; env before/after queue; acquire-versus-env; one-shot native cleanup=%d; native thread creation failure; dispatch errors; SDK unregister waiting/error; null-env invalid context; FD baseline=%d\n",nativeThreads.load(),baseline);
}
