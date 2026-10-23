/**
 * GUI异步运行体：UI仅读缓存并投递固定容量工作，不持JNI mutex、不等待线程结束。
 * worker只在本进程存在一个，由entry/进程DSO owner保持代码和上下文到进程结束；stop
 * 退休scope/source/ticket且不join。HotSpot停机可能永久阻塞worker，但不能阻塞事件线程
 * 的原3s退出ACK。所有JNI调用都在registry锁之外，迟到结果不能写后来scope/资源。
 */
#include "game_gui_observation.h"
#include "game_process_exit.h"
#include "jvm_launcher.h"
#include "../input/amcl_input_api.h"
#include "../input/input_surface_context_snapshot.h"
#include "../input/input_surface_context_semantics.h"
#include "../platform/render_scale.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <thread>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

namespace {
using Clock=std::chrono::steady_clock;
constexpr size_t SourceCapacity=16;
int currentPid() {
#ifdef _WIN32
    return static_cast<int>(GetCurrentProcessId());
#else
    return static_cast<int>(getpid());
#endif
}
/** 当前Core会话/Surface/focus与真实Window坐标身份；Core会话可随同局Surface更换而变。 */
struct Resource {
    uint64_t session=0,surface=0,focus=0;
    AmclInputSurfaceContextPayload context{};
};
/** 两次core快照夹住context读取，拒绝混合旧surface与新context；不进入JVM。 */
bool resource(Resource& out) {
    const auto* api=amclInputGetHostApiV1();if(!api || !api->getSnapshot)return false;
    AmclInputSnapshotV1 before{},after{};
    before.abiVersion=after.abiVersion=AMCL_INPUT_HOST_API_VERSION;
    before.structSize=after.structSize=sizeof(before);
    if(api->getSnapshot(&before)!=AMCL_INPUT_OK || !before.sessionActive ||
       inputBridge_readSurfaceContextV1(&out.context)!=1 ||
       api->getSnapshot(&after)!=AMCL_INPUT_OK || !after.sessionActive || !before.focused || !after.focused ||
       before.sessionEpoch!=after.sessionEpoch || before.surfaceEpoch!=after.surfaceEpoch || before.focusEpoch!=after.focusEpoch ||
       out.context.windowId<=0 || out.context.generation==0 ||
       !(out.context.validFields&AMCL_INPUT_SURFACE_CONTEXT_FIELD_WINDOW))return false;
    out.session=after.sessionEpoch;out.surface=after.surfaceEpoch;out.focus=after.focusEpoch;return true;
}
/**
 * 比较两份已读取的资源事实，不取锁或借出Core对象。游戏scope与Core session分层：
 * 同局Surface重建可改变Core epoch，但旧请求必须因session/surface/focus或完整窗口
 * 坐标身份变化而失效。Hz按已有共用语义作为元数据例外，不误退休纯刷新率更新。
 */
bool same(const Resource& a,const Resource& b) {
    return a.session==b.session && a.surface==b.surface && a.focus==b.focus &&
        amcl::input::SameInputSurfaceContextIdentity(a.context,b.context);
}
/**
 * 本来源一票：result=1为Pending，javaId只在真实Java入队后存在；Native与Java ID分开。
 * deadline约束等待/排队。executing仅在全部Java阻塞读取结束、即将调用实际set时claim，
 * 不能再假定它是可撤销的排队动作；完成仍等待Java最终ACK，退休只撤原scope资格。
 */
struct Ticket {
    uint32_t id=0;uint64_t javaId=0;int scale=0,result=0;
    uint64_t revision=0;
    bool submitted=false,executing=false;
    Clock::time_point deadline{},nextPoll{};
};
/** 原scope拥有的16槽来源；id从不复用，binding仅随自己的实际资源身份改变递增。 */
struct Source {
    uint32_t id=0,binding=0;
    bool bound=false,queued=false;
    Resource resource{};
    amcl::gui::Request request{};
    std::array<double,AMCL_GAME_GUI_VALUE_COUNT> cache{};
    Ticket ticket{};
};
/** 进程owner保留worker/代码/存储；短mutex只保护固定槽，JNI期间不持它。 */
struct Runtime {
    const int pid=currentPid();
    std::mutex mutex;
    std::condition_variable wake;
    std::array<Source,SourceCapacity> sources{};
    uint32_t nextScope=0,nextSource=0,nextTicket=0,scope=0,legacy=0,restoreOwner=0;
    uint64_t activity=0;
    bool started=false,active=false;
    size_t cursor=0;
    uint32_t inFlight=0;
    uint64_t completed=0,discarded=0;
};
// 这些原子采用静态常量初始化，不经过函数局部static的隐藏guard mutex。PID在任何
// Runtime分配/构造之前先发布；fork child即使继承了“父正在new”的状态，也立即拒绝。
std::atomic<int> ownerPid{0};
std::atomic<Runtime*> ownerRuntime{nullptr};
static_assert(std::atomic<int>::is_always_lock_free && std::atomic<Runtime*>::is_always_lock_free,"GUI process owner must reject fork before locks");
/** 仅首次PID CAS获胜线程构造一次。同行看未发布指针立即降级，不等待初始化；失败也不换owner。 */
Runtime* runtime() {
    const int pid=currentPid();int fresh=0;
    if(!ownerPid.compare_exchange_strong(fresh,pid,std::memory_order_acq_rel)) {
        return fresh==pid?ownerRuntime.load(std::memory_order_acquire):nullptr;
    }
    Runtime* value=nullptr;try{value=new Runtime;}catch(...){return nullptr;}
    ownerRuntime.store(value,std::memory_order_release);return value;
}
/** 身份预算耗尽返回0，保持旧计数不回绕；没有编号就不能发布假scope/source/ticket。 */
uint32_t advance(uint32_t& value){return value==UINT32_MAX?0:++value;}
/** 仅查原生进程/JVM占用/退出事实；Creating/Fresh允许scope准备，JNI仍只由Ready worker进。 */
bool processLive(Runtime& r){return r.pid==currentPid() && r.active && jvmRuntimeState()!=3 && !amclGameExitPendingForCurrentProcess();}
/** 固定16槽精确找原source ID，不凭global current补齐后来来源。调用方须持registry锁。 */
Source* find(Runtime& r,uint32_t id){for(auto& s:r.sources)if(id && s.id==id)return &s;return nullptr;}
/**
 * 读取调用方已锁定的票副本/槽：非零id且result为Pending才在途。未认领的等待/排队
 * 受原2s绝对期限限制；executing表示Java已在阻塞读取后认领实际set调用，不能靠
 * 排队期限把已开始的执行伪造为取消或成功，仍须真实ACK或scope/resource退休。
 * 本函数仅比较原生状态与单调时钟，不进JNI、不等待执行，也不修改票据。
 */
bool ticketBusy(const Ticket& t){return t.id && t.result==1 && (t.executing || Clock::now()<t.deadline);}
/** JNI数值包仍须满足已有GUI前缀合同才授予恢复；坏尾表不否定合法只读前缀。 */
bool restorable(const Source& s) {
    const auto& v=s.cache;
    for(size_t i=0;i<13;i++)if(!std::isfinite(v[i]))return false;
    if(v[0]!=2 || v[1]<0 || v[1]>64 || std::floor(v[1])!=v[1] || v[2]<1 || v[2]>128 ||
       v[7]!=1 || v[9]!=1 || (v[12]!=0 && v[12]!=1) || v[8]<1 || v[8]>9007199254740991.0 || std::floor(v[8])!=v[8])return false;
    for(size_t i=3;i<=6;i++)if(v[i]<1 || v[i]>65535 || std::floor(v[i])!=v[i])return false;
    return true;
}
/** cache复制时提供本票回执，不把Java ID和Native入队ID混为相同身份。 */
void overlay(const Source& s,double* values) {
    if(!s.ticket.id){values[10]=0;values[11]=0;return;}
    values[10]=s.ticket.id;
    values[11]=s.ticket.result==1 && !s.ticket.executing && Clock::now()>=s.ticket.deadline?3:s.ticket.result;
}
/** 请求保原scope/binding；完成/Java写前只验证，不把旧工作改绑当前resource。 */
bool current(Runtime& r,const amcl::gui::Request& q) {
    Source* s=find(r,q.source);Resource now;
    return processLive(r) && q.scope==r.scope && s && s->bound && q.binding==s->binding &&
        resource(now) && same(now,s->resource);
}
/** 只抓原工作的副本；每源latest read+一票restore，轮转16槽，不能无限累积队列。 */
bool take(Runtime& r,amcl::gui::Request& q,bool& restore) {
    if(!processLive(r) || jvmRuntimeState()!=2)return false;
    // Java helper只有一份最新requestId/result。Native每源保票，但本局只有一个Java
    // 恢复交付owner，直到真实ACK已读入本源或退休才能交付下一票；仅QUEUED入队互斥
    // 不够，A已完成但ACK未读时B会覆盖A的id，让A永久Pending。同值恢复仍合法。
    if(r.restoreOwner) {
        Source* owner=nullptr;for(auto& s:r.sources)if(s.ticket.id==r.restoreOwner){owner=&s;break;}
        if(!owner || !ticketBusy(owner->ticket) || !current(r,amcl::gui::Request{r.scope,owner->id,owner->binding})) {
            if(owner && owner->ticket.result==1)owner->ticket.result=3;
            r.restoreOwner=0;
        }
    }
    for(size_t n=0;n<SourceCapacity;n++) {
        Source& s=r.sources[(r.cursor+n)%SourceCapacity];if(!s.id || !s.bound)continue;
        if(s.ticket.id && s.ticket.result==1 && !s.ticket.executing && Clock::now()>=s.ticket.deadline) {
            s.ticket.result=3;s.cache[10]=s.ticket.id;s.cache[11]=3;
        }
        const bool newRestore=ticketBusy(s.ticket) && !s.ticket.submitted && Clock::now()>=s.ticket.nextPoll &&
            (!r.restoreOwner || r.restoreOwner==s.ticket.id);
        const bool resultPoll=ticketBusy(s.ticket) && s.ticket.submitted && Clock::now()>=s.ticket.nextPoll;
        if(!newRestore && !resultPoll && !s.queued)continue;
        q=s.request;q.scope=r.scope;q.source=s.id;q.binding=s.binding;
        if(newRestore){q.ticket=s.ticket.id;q.scale=s.ticket.scale;q.revision=s.ticket.revision;s.ticket.submitted=true;r.restoreOwner=s.ticket.id;}
        else {q.ticket=0;s.queued=false;s.ticket.nextPoll=Clock::now()+std::chrono::milliseconds(100);}
        restore=newRestore;r.cursor=(r.cursor+n+1)%SourceCapacity;
        if(current(r,q))return true;
        // 真实资源失效只退休原绑定/本票，来源lease本身仍可等后续新资源显式读请求。
        s.bound=false;s.queued=false;s.cache={};s.ticket.result=3;
    }
    return false;
}
void run(Runtime* r) {
    for(;;) {
        amcl::gui::Request q;bool restore=false;
        {std::unique_lock<std::mutex> lock(r->mutex);
            if(!take(*r,q,restore)) {
                bool awaiting=false;for(const auto& s:r->sources)if(ticketBusy(s.ticket))awaiting=true;
                // 只有真实restore在途才有结果/期限维护；纯观察无工作时事件唤醒，关闭视觉
                // 订阅不会丢掉restore回执，也不凭一个常驻10Hz空轮询推进普通输入。
                if(awaiting)r->wake.wait_for(lock,std::chrono::milliseconds(100));else r->wake.wait(lock);
                continue;
            }
            r->inFlight=q.source;
        }
        // JNI可以阻塞，registry锁已经释放；UI getter、stop和Java资源回查仍可独立完成。
        int64_t javaId=0;std::array<double,AMCL_GAME_GUI_VALUE_COUNT> values{};
        if(restore)javaId=amcl::gui::RestoreOnWorker(q);
        else amcl::gui::PollOnWorker(q,values.data());
        std::lock_guard<std::mutex> lock(r->mutex);r->inFlight=0;++r->completed;
        if(!current(*r,q)){++r->discarded;continue;}
        Source* s=find(*r,q.source);if(!s)continue;
        if(restore) {
            if(s->ticket.id!=q.ticket)continue;
            if(javaId==-2) {
                // 原Java单任务读取尚在游戏队列，不能把运输Busy说成已失败/已完成；
                // 有界重试只保留本票，在最初Native2s截止前再次提交，同scope退休立即失效。
                s->ticket.submitted=false;s->ticket.nextPoll=Clock::now()+std::chrono::milliseconds(100);
            } else {
                s->ticket.javaId=javaId>0?static_cast<uint64_t>(javaId):0;s->ticket.nextPoll=Clock::now();
                if(javaId<=0)s->ticket.result=-1;
            }
        } else {
            s->cache=values;
            if(s->ticket.id && s->ticket.javaId && std::isfinite(values[10]) && values[10]>=1 && values[10]<=9007199254740991.0 &&
               std::floor(values[10])==values[10] && static_cast<uint64_t>(values[10])==s->ticket.javaId &&
               (values[11]==2 || values[11]==3 || values[11]==-1))s->ticket.result=static_cast<int>(values[11]);
        }
        overlay(*s,s->cache.data());
    }
}
/** 容量/编号都确认后才占槽；拒绝不修改已有来源和其在途工作。 */
uint32_t attach(Runtime& r){for(auto& s:r.sources)if(!s.id){uint32_t id=advance(r.nextSource);if(!id)return 0;s=Source{};s.id=id;return id;}return 0;}
/** scope准备只登记事实，直到Ready后的真实观察才创建worker，避免安装器Fresh阶段新增线程。 */
bool ensureWorker(Runtime& r){if(r.started)return true;if(jvmRuntimeState()!=2)return false;try{std::thread(run,&r).detach();r.started=true;return true;}catch(...){return false;}}
}

/**
 * 宿主以已验证的非零安全整数activity建立本局GUI scope，返回无回绕uint32身份。
 * 同一活跃activity幂等复用，异局抢占、已退休同activity、Spent/Pending、foreign PID、
 * owner未发布/分配失败或编号耗尽均返回0，不发布半scope或重置JVM占用事实。
 * 进程PID先于任何分配/锁取得，registry只登记固定来源表；本入口不进JNI、不创建
 * worker，首次Ready后的实际观察才启动进程worker。0只降级观察，不能阻断基本输入。
 */
uint32_t amcl_game_gui_start_session(uint64_t activity) {
    if(!activity || activity>9007199254740991ULL)return 0;
    Runtime* owner=runtime();if(!owner)return 0;Runtime& r=*owner;std::lock_guard<std::mutex> lock(r.mutex);
    if(r.pid!=currentPid() || amclGameExitPendingForCurrentProcess() || jvmRuntimeState()==3)return 0;
    if(r.active)return r.activity==activity?r.scope:0;
    // 结束的同一activity不能凭重建复活；后来scope使用新身份且只复用同一进程worker。
    if(r.activity==activity || !advance(r.nextScope))return 0;
    r.scope=r.nextScope;r.activity=activity;r.active=true;r.sources={};r.legacy=0;r.restoreOwner=0;
    r.wake.notify_one();return r.scope;
}
// PID检查必须先于mutex；fork子进程不碰可能从父线程继承为锁住的观察registry。
/** 只捕获已发布且活跃的原scope，准备中/foreign PID返回0，无JNI或等待初始化。 */
uint32_t amcl_game_gui_capture_session(){Runtime* owner=runtime();if(!owner)return 0;Runtime& r=*owner;std::lock_guard<std::mutex> lock(r.mutex);return processLive(r)?r.scope:0;}
/** 原scope幂等退休，清队列/票据/缓存；worker是进程寿命，不能join或把停止当JNI完成。 */
bool amcl_game_gui_stop_session(uint32_t scope){Runtime* owner=runtime();if(!owner)return false;Runtime& r=*owner;std::lock_guard<std::mutex> lock(r.mutex);if(!scope || scope!=r.scope)return false;r.active=false;r.sources={};r.legacy=0;r.restoreOwner=0;r.wake.notify_one();return true;}
/** 只有精确原scope可领来源；容量/编号失败返回0，不偷取current或占半槽。 */
uint32_t amcl_game_gui_attach_source(uint32_t scope){Runtime* owner=runtime();if(!owner)return 0;Runtime& r=*owner;std::lock_guard<std::mutex> lock(r.mutex);return processLive(r) && scope==r.scope?attach(r):0;}
/** 只撤原source及其票据；迟到worker副本靠原id/binding拒绝，其他来源保持。 */
bool amcl_game_gui_retire_source(uint32_t id){Runtime* owner=runtime();if(!owner)return false;Runtime& r=*owner;std::lock_guard<std::mutex> lock(r.mutex);Source* s=find(r,id);if(!s)return false;if(r.restoreOwner==s->ticket.id)r.restoreOwner=0;*s=Source{};r.wake.notify_one();return true;}

/**
 * UI同步端口：调用方拥有非空19项输出和本前端原source ID，尺寸是实际Surface px，
 * version为最多96字节终止字符串。非法参数输出零状态；无来源/资源时只保合法尺寸
 * 的只读降级前缀，不创建假lease或授予恢复。有效请求在短registry锁内复制真实缓存，
 * 再覆盖该来源唯一latest观察请求并唤醒worker，不执行JNI或等候worker。
 * 实际窗口/epoch改变只重绑原source的资源binding，原票保Cancelled回执；scope不变
 * 不等于旧资源仍活着。旧完成须由worker按原binding拒绝。values只供本次NAPI拷贝，
 * 不借出槽/Java对象；恢复票最终状态来自本源真实ACK或原期限/退休事实。
 */
void amcl_read_game_gui_for_source(uint32_t id,int width,int height,const char* version,double* values,bool guide) {
    std::fill(values,values+AMCL_GAME_GUI_VALUE_COUNT,0.0);
    if(width<=0 || height<=0 || width>65535 || height>65535 || !version || !*version || std::strlen(version)>96)return;
    values[3]=std::lround(amcl::renderscale::MapX(width));values[4]=std::lround(amcl::renderscale::MapY(height));
    Runtime* owner=runtime();if(!owner)return;Runtime& r=*owner;Resource now;
    std::lock_guard<std::mutex> lock(r.mutex);Source* s=find(r,id);
    if(!processLive(r) || !s)return;
    if(!resource(now)) {
        s->bound=false;s->queued=false;s->cache={};
        if(s->ticket.id){if(r.restoreOwner==s->ticket.id)r.restoreOwner=0;s->ticket.result=3;s->ticket.javaId=0;s->ticket.executing=false;overlay(*s,values);}
        return;
    }
    if(!s->bound || !same(s->resource,now)) {
        if(s->binding==UINT32_MAX)return;
        ++s->binding;s->resource=now;s->bound=true;s->cache={};
        // 同一前端的真实窗口绑定更换须保留旧票Cancelled回执；原id不能消失让UI一直
        // 等待，也不能把旧Java完成映射给新资源。下一条用户恢复会另取全新的Native票。
        if(s->ticket.id){if(r.restoreOwner==s->ticket.id)r.restoreOwner=0;s->ticket.result=3;s->ticket.javaId=0;s->ticket.executing=false;s->ticket.submitted=false;}
    }
    std::copy(s->cache.begin(),s->cache.end(),values);overlay(*s,values);
    if(values[3]<=0 || values[4]<=0){values[3]=std::lround(amcl::renderscale::MapX(width));values[4]=std::lround(amcl::renderscale::MapY(height));}
    s->request.width=width;s->request.height=height;s->request.guide=guide;
    std::memcpy(s->request.version,version,std::strlen(version)+1);s->queued=true;
    if(ensureWorker(r))r.wake.notify_one();
}
/**
 * 用户命令端口只接受本source的当前可恢复缓存、精确revision和0..64目标档位；原
 * scope/binding/resource失效、坏前缀、同源已有在途票或编号耗尽返回0且不改旧票。
 * 成功在registry锁内发布本源唯一Native Pending票并从此时计原2s排队期限，返回
 * uint32仅表示Native接受；Java实际入队/认领/写入及ACK另行确认。本局Java恢复owner
 * 串行交付到真实ACK已捕获，防下一来源覆盖唯一Java结果；同值请求仍合法。
 * 不执行JNI、不等待setter或worker，也不把该票自动转给后来scope/新窗口。
 */
uint32_t amcl_restore_game_gui_for_source(uint32_t id,int scale,uint64_t revision) {
    if(scale<0 || scale>64 || !revision || revision>9007199254740991ULL)return 0;
    Runtime* owner=runtime();if(!owner)return 0;Runtime& r=*owner;std::lock_guard<std::mutex> lock(r.mutex);Source* s=find(r,id);
    if(!s || !current(r,amcl::gui::Request{r.scope,s->id,s->binding}) || !restorable(*s) ||
       s->cache[8]!=static_cast<double>(revision) || ticketBusy(s->ticket))return 0;
    uint32_t ticket=advance(r.nextTicket);if(!ticket)return 0;
    s->ticket={};s->ticket.id=ticket;s->ticket.scale=scale;s->ticket.revision=revision;s->ticket.result=1;
    s->ticket.deadline=Clock::now()+std::chrono::seconds(2);overlay(*s,s->cache.data());r.wake.notify_one();return ticket;
}
/** 旧公共ABI只使用独立legacy observer lease，不能拿具名UI来源的票据或回执。 */
void amcl_read_game_gui(int w,int h,const char* v,double* values,bool guide){Runtime* owner=runtime();uint32_t id=0;if(owner){Runtime& r=*owner;std::lock_guard<std::mutex> lock(r.mutex);if(processLive(r) && !r.legacy)r.legacy=attach(r);id=r.legacy;}amcl_read_game_gui_for_source(id,w,h,v,values,guide);}
uint64_t amcl_restore_game_gui(int scale,uint64_t revision){Runtime* owner=runtime();if(!owner)return 0;Runtime& r=*owner;uint32_t id;{std::lock_guard<std::mutex> lock(r.mutex);id=r.legacy;}return amcl_restore_game_gui_for_source(id,scale,revision);}

namespace amcl::gui {
/** Java写/回滚前的原票资格查询；Pending期限/原scope/source/resource均须仍成立。 */
bool TicketCurrent(uint32_t ticket){Runtime* owner=runtime();if(!owner)return false;Runtime& r=*owner;std::lock_guard<std::mutex> lock(r.mutex);for(auto& s:r.sources)if(ticket && s.ticket.id==ticket)return ticketBusy(s.ticket) && current(r,Request{r.scope,s.id,s.binding});return false;}
/** 全部Java读取结束后的实际set调用认领；只能本局Java交付owner取一次，不当作最终ACK。 */
bool BeginRestore(uint32_t ticket){Runtime* owner=runtime();if(!owner)return false;Runtime& r=*owner;std::lock_guard<std::mutex> lock(r.mutex);for(auto& s:r.sources)if(ticket && s.ticket.id==ticket){if(r.restoreOwner!=ticket || !ticketBusy(s.ticket) || s.ticket.executing || !current(r,Request{r.scope,s.id,s.binding}))return false;s.ticket.executing=true;return true;}return false;}
#ifdef AMCL_GUI_OBSERVATION_HOST_TESTING
/**
 * 私有宿主只读诊断：返回当前真实槽、latest请求数及worker dispatch/完成/丢弃计数。
 * owner未发布或foreign PID返回空值，锁内按值复制、不借出槽；不触发GUI请求、JNI或
 * 生命周期推进。inFlight只证明原生dispatch，真实JNI阻塞另由stock JVM线程状态校准。
 */
Diagnostics ReadDiagnostics(){Runtime* owner=runtime();if(!owner)return {};Runtime& r=*owner;std::lock_guard<std::mutex> lock(r.mutex);Diagnostics out;for(const auto& s:r.sources)if(s.id){++out.sources;if(s.queued)++out.queuedReads;}out.inFlight=r.inFlight;out.completed=r.completed;out.discarded=r.discarded;return out;}
/**
 * 按精确原source读取Native票id/result和已接受的Java ID，供宿主验证真实队列/ACK。
 * 不存在/未发布/foreign PID返回空结构，不补current来源；锁内只复制数值，不等待
 * worker、不让测试修改票。javaId非零是入队证据，result终态须分别按真实ACK解释。
 */
TicketDiagnostics ReadTicketDiagnostics(uint32_t source){Runtime* owner=runtime();if(!owner)return {};Runtime& r=*owner;std::lock_guard<std::mutex> lock(r.mutex);Source* s=find(r,source);return s?TicketDiagnostics{s->ticket.id,s->ticket.result,s->ticket.javaId}:TicketDiagnostics{};}
#endif
}
