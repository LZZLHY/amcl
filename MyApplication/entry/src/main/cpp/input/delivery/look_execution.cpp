/**
 * 三端唯一 look 执行 owner。速度积分、family 非线性加工、来源可撤余量和不可变前缀
 * 均在本模块；ABI 边缘只按冻结票更新自己的 cache 并报告实际完成层级。
 * 所有锁内操作仅操作值，Core/control 查询在锁外完成，绝不调用用户、JNI、SDL 或窗口。
 */
#include "look_execution.h"
#include "../input_latency_observation.h"
#include "look_execution_compat.h"
#include "../amcl_input_api.h"
#include "../amcl_input_host_descriptor.h"
#include "../input_surface_context_semantics.h"
#include "../input_look_core_hook.h"
#include "../../platform/input_source.h"
#include "../../platform/look_delta_math.h"
#include <array>
#include <map>
#include <set>
#include <mutex>
#include <atomic>
#include <cmath>
#include <new>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <chrono>
#include <limits>
#include <vector>
#ifdef _WIN32
#include <process.h>
#pragma comment(linker, "/export:amclLookExecutionGetPortV1")
#pragma comment(linker, "/export:amclLookExecutionPublishV1")
#else
#include <unistd.h>
#endif

extern "C" int amcl_input_owner_read_surface_context(AmclInputSurfaceContextPayload*);
namespace {
constexpr size_t kStreams=512,kPrefixes=2048,kConsumers=64,kTickets=2048;
uint32_t processId(){
#ifdef _WIN32
    return static_cast<uint32_t>(_getpid());
#else
    return static_cast<uint32_t>(getpid());
#endif
}
// PID先于registry构造且以后不改。fork拒绝在任何local-static guard和继承mutex之前。
const uint32_t ownerProcess=processId();
bool foreign(){return processId()!=ownerProcess;}
uint64_t ownerNow(){return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
    std::chrono::steady_clock::now().time_since_epoch()).count());}
struct Pair {double x=0,y=0;};
bool finite(Pair p){return std::isfinite(p.x)&&std::isfinite(p.y);}
struct Family {
    AmclLookPolicyV1 policy{sizeof(AmclLookPolicyV1),0,1.0,0.6,0.0};
    uint64_t policyEpoch=1;
    int64_t last=0;
    amcl::input::LookPipelineStats stats;
};
// 各流保存输出单位的pending/owed，不按新policy重算。family的gain/alpha只计算一次，
// 再线性分配到贡献，因此两设备相反速度和退一设备都不需要除以总和。
struct Stream {
    AmclLookStreamV1 description{};
    Pair pending{},owed{};
    uint64_t sample=0;
    uint64_t policyEpoch=0;
    bool active=true;
};
struct Prefix {AmclLookPrefixV1 identity{};std::map<uint64_t,Pair> contributions;uint32_t receivers=0;bool transported=false;};
struct Ticket {AmclLookEmissionV1 emission{};bool claimed=false,cached=false;uint64_t backendEpoch=0;};
struct Consumer {
    AmclLookSnapshotV1 stats{};
    uint64_t mode=0,lastOrder=0,backendEpoch=0;
    std::set<uint64_t> used;
    std::map<uint64_t,Ticket> tickets;
};
struct Registry {
    std::mutex mutex;
    std::array<Family,AMCL_INPUT_SOURCE_COUNT+1> families;
    std::map<uint64_t,Stream> streams;
    std::map<uint64_t,Prefix> prefixes;
    std::map<uint64_t,Consumer> consumers;
    std::map<uint64_t,uint64_t> physicalStreams,physicalFacts,physicalOrders;
    std::array<uint64_t,3> backendEpoch{1,1,1};
    uint32_t activeBackends=0;
    uint64_t session=0,mode=0,nextStream=1,nextPrefix=1,nextTicket=1;
    bool grabbed=false;
    double maxBacklog=0;
};
// 该owner/table进程pin，借用边缘可在global析构期间报告旧receipt。对象寿命必须覆盖它们；
// 分配失败明确终止初始化，不借空表，不靠停局/卸载来回收运行体。
Registry& state(){static Registry* const r=[](){Registry* created=new(std::nothrow) Registry;
    if(!created)std::abort();return created;}();return *r;}
bool validSource(int32_t source){return source>=0&&source<AMCL_INPUT_SOURCE_COUNT;}
size_t familyOf(const Stream& s){return s.description.kind==AMCL_LOOK_GYRO_DELTA?
    AMCL_INPUT_SOURCE_COUNT:s.description.source;}
bool validPolicy(const AmclLookPolicyV1* p){return p&&p->size==sizeof(*p)&&p->invertY<=1&&
    std::isfinite(p->sensitivity)&&p->sensitivity>=0.1&&p->sensitivity<=5&&
    std::isfinite(p->smoothing)&&p->smoothing>=0.1&&p->smoothing<=1&&
    std::isfinite(p->acceleration)&&p->acceleration>=0&&p->acceleration<=1;}
void backlog(Registry& r){Pair total{};for(const auto& entry:r.streams){total.x+=entry.second.pending.x;total.y+=entry.second.pending.y;}
    r.maxBacklog=std::max(r.maxBacklog,std::hypot(total.x,total.y));}
// 当前Core事实在look锁外取得。无capture要求：非物理world look使用逻辑grab，物理资格
// 由原typed ingress/consumer能力检查。context完整身份比较排除纯Hz元数据。
bool resourceCurrent(const AmclLookResourceV1& value){
    if(value.size!=sizeof(value)||!value.grabbed)return false;
    AmclInputLookCoreResourceV1 facts{};
    return amclInputOwnerReadLookResourceV1(&facts)&&facts.active&&
        value.sessionEpoch==facts.sessionEpoch&&value.surfaceEpoch==facts.surfaceEpoch&&
        value.focusEpoch==facts.focusEpoch&&amcl::input::SameInputSurfaceContextIdentity(facts.context,value.context);
}
bool modeCurrent(const Registry& r,const AmclLookResourceV1& value){return r.session==value.gameSession&&r.grabbed&&r.mode==value.modeEpoch;}
int32_t verify(uint64_t identity){if(foreign())return AMCL_LOOK_NOT_READY;const AmclInputHostApiV1* actual=nullptr;
    return identity&&amclInputHostDescriptorResolveV1(&actual)==AMCL_INPUT_HOST_DESCRIPTOR_OK&&
        actual==amclInputGetHostApiV1()&&identity==reinterpret_cast<uintptr_t>(actual)?0:AMCL_LOOK_NOT_READY;}
bool controlFacts(uint64_t handle,AmclControlSnapshotV1& out){if(foreign())return false;
    const auto* port=amclControlDeliveryGetPortV1();out.size=sizeof(out);return port&&port->snapshot(handle,&out)>=0;}
bool sameEmission(const AmclLookEmissionV1& a,const AmclLookEmissionV1& b){return a.size==sizeof(a)&&
    a.consumer==b.consumer&&a.activation==b.activation&&a.target==b.target&&a.ticket==b.ticket&&
    a.prefix==b.prefix&&a.order==b.order&&a.backend==b.backend&&a.dx==b.dx&&a.dy==b.dy&&a.x==b.x&&a.y==b.y;}
bool consumerCurrent(const Consumer& c,const AmclControlSnapshotV1& facts){return c.stats.gameSession==facts.gameSession&&
    c.stats.activation==facts.activation&&c.stats.target==facts.target&&c.stats.backend==facts.backend;}
// 数学失败/overflow之前不改变family或stream。一次family采样先sum所有原增量，使用原
// math计算公共gain/alpha，再分到每流；pending单位固定，旧policy余量不会重新缩放。
// 同一数学实现接受完整表或栈上单流候选。常见样本不为一个raw值构造map节点，
// 多设备同族仍按原map顺序归约，保留抵消、平滑余量和舍入锚点。
using SingleStream = std::array<std::pair<uint64_t,Stream>,1>;
using SingleSample = std::array<std::pair<uint64_t,Pair>,1>;
Pair sampleFor(const std::map<uint64_t,Pair>& values,uint64_t id) {
    const auto found=values.find(id);return found==values.end()?Pair{}:found->second;
}
Pair sampleFor(const SingleSample& values,uint64_t id) {
    return values[0].first==id?values[0].second:Pair{};
}
SingleSample singleSample(uint64_t id,Pair value) {return {{{id,value}}};}
template<class Streams,class Samples>
bool processFamily(Family& f,Streams& streams,
        size_t index,const Samples& raw,int64_t ns){
    Pair input{},pending{};
    for(const auto& e:raw){input.x+=e.second.x;input.y+=e.second.y;}
    for(const auto& e:streams)if(e.second.active&&familyOf(e.second)==index){pending.x+=e.second.pending.x;pending.y+=e.second.pending.y;}
    const bool gyro=index==AMCL_INPUT_SOURCE_COUNT;
    amcl::input::LookDeltaMathInput math{};math.dx=input.x;math.dy=input.y;
    math.pendingDx=pending.x;math.pendingDy=pending.y;math.sensitivity=f.policy.sensitivity;
    math.smoothAlpha=gyro||index==AMCL_INPUT_SOURCE_PHYSICAL_KBM?1.0:f.policy.smoothing;
    math.acceleration=gyro?0.0:f.policy.acceleration;math.invertY=f.policy.invertY!=0;
    math.lastTimeNs=f.last;math.nowTimeNs=ns;amcl::input::LookDeltaMathOutput output{};
    if(!amcl::input::ComputeLookDeltaMath(math,&output))return false;
    Pair emitted{},remaining{};Stream* anchor=nullptr;
    for(auto& e:streams){auto& s=e.second;if(!s.active||familyOf(s)!=index)continue;
        const Pair sample=sampleFor(raw,e.first);
        const Pair total{s.pending.x+sample.x*output.appliedGain,
            s.pending.y+sample.y*output.appliedGain*(math.invertY?-1.0:1.0)};
        const Pair emit{total.x*output.appliedAlpha,total.y*output.appliedAlpha};
        const Pair rest{total.x-emit.x,total.y-emit.y};const Pair owed{s.owed.x+emit.x,s.owed.y+emit.y};
        if(!finite(total)||!finite(emit)||!finite(rest)||!finite(owed))return false;
        s.pending=rest;s.owed=owed;
        emitted.x+=emit.x;emitted.y+=emit.y;remaining.x+=rest.x;remaining.y+=rest.y;if(!anchor)anchor=&s;
    }
    // 线性分贡献会改变乘法/求和舍入顺序。把微小残差归给确定的同族anchor，使整体emit/
    // pending逐值回到旧“一次sum后math”输出，避免floor整数阈值因拆device改变一count。
    if(anchor){auto& s=*anchor;s.owed.x+=output.emitDx-emitted.x;s.owed.y+=output.emitDy-emitted.y;
        s.pending.x+=output.pendingDx-remaining.x;s.pending.y+=output.pendingDy-remaining.y;
        if(!finite(s.owed)||!finite(s.pending))return false;}
    f.last=output.lastTimeNs;f.stats.NoteAccepted(output.emitDx+output.pendingDx-pending.x,
        output.emitDy+output.pendingDy-pending.y,output.emitDx,output.emitDy,output.pendingDx,output.pendingDy);return true;
}
int32_t bindSession(uint64_t session){if(foreign())return AMCL_LOOK_NOT_READY;if(!session)return AMCL_LOOK_REJECTED;
    auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);if(r.session&&r.session!=session)return AMCL_LOOK_STALE;r.session=session;return 0;}
int32_t publishMode(uint64_t session,uint64_t epoch,uint32_t grabbed){if(foreign())return AMCL_LOOK_NOT_READY;
    if(!session||!epoch||grabbed>1)return AMCL_LOOK_REJECTED;auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);
    if(r.session!=session||epoch<r.mode)return AMCL_LOOK_STALE;if(epoch==r.mode)return r.grabbed==(grabbed!=0)?0:AMCL_LOOK_REJECTED;
    r.mode=epoch;r.grabbed=grabbed!=0;
    std::array<Pair,AMCL_INPUT_SOURCE_COUNT+1> discarded{};
    for(const auto& e:r.streams){discarded[familyOf(e.second)].x+=e.second.pending.x;discarded[familyOf(e.second)].y+=e.second.pending.y;}
    for(size_t i=0;i<discarded.size();++i)r.families[i].stats.NoteFlush(false,discarded[i].x,discarded[i].y);
#if AMCL_INPUT_TRACE
    // 原mode提交确实清除这些prefix，此时记录真实退休；诊断try-lock失败不延缓原清理。
    for(const auto& prefix:r.prefixes)amclInputLatencyFinishV1(prefix.first,AMCL_ILAT_RETIRED);
#endif
    r.prefixes.clear();r.streams.clear();r.physicalStreams.clear();r.physicalFacts.clear();r.physicalOrders.clear();for(auto& f:r.families)f.last=0;return 0;}
int32_t policy(int32_t source,const AmclLookPolicyV1* value){if(foreign())return AMCL_LOOK_NOT_READY;
    if((source!=-1&&!validSource(source))||!validPolicy(value))return AMCL_LOOK_REJECTED;
    auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);
    auto families=r.families;
    for(size_t i=0;i<families.size();++i)if(source==-1||i==static_cast<size_t>(source)||(source==1&&i==AMCL_INPUT_SOURCE_COUNT)){
        auto& f=families[i];const auto& old=f.policy;
        if(old.sensitivity!=value->sensitivity||old.invertY!=value->invertY||old.smoothing!=value->smoothing||old.acceleration!=value->acceleration){
            if(f.policyEpoch==UINT64_MAX)return AMCL_LOOK_PRESSURE;++f.policyEpoch;f.policy=*value;}}
    r.families=std::move(families);
    return 0;}
int32_t openStream(const AmclLookStreamV1* description,uint64_t* output){if(output)*output=0;
    if(foreign())return AMCL_LOOK_NOT_READY;if(!output||!description||description->size!=sizeof(*description)||
        !validSource(description->source)||(description->reserved&~AMCL_LOOK_STREAM_POLICY_LEASE)||description->kind<1||description->kind>5||
        ((description->reserved&AMCL_LOOK_STREAM_POLICY_LEASE)&&description->kind!=AMCL_LOOK_GYRO_DELTA)||
        description->unit<1||description->unit>5||description->clock<1||description->clock>4||
        description->kind==AMCL_LOOK_MAPPED_RATE||
        (description->device!=0&&description->connection==0)||
        (description->device==0&&description->connection!=0))return AMCL_LOOK_REJECTED;
    if(!resourceCurrent(description->resource))return AMCL_LOOK_NOT_READY;
    auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);if(!modeCurrent(r,description->resource))return AMCL_LOOK_STALE;
    if(r.streams.size()>=kStreams||r.nextStream==UINT64_MAX)return AMCL_LOOK_PRESSURE;
    try{Stream candidate;candidate.description=*description;candidate.policyEpoch=r.families[familyOf(candidate)].policyEpoch;const uint64_t handle=r.nextStream++;
        r.streams.emplace(handle,candidate);*output=handle;return 0;}catch(const std::bad_alloc&){return AMCL_LOOK_PRESSURE;}}
int32_t delta(uint64_t handle,double x,double y,uint64_t ns){if(foreign())return AMCL_LOOK_NOT_READY;
    if(!finite({x,y})||!ns||ns>INT64_MAX)return AMCL_LOOK_REJECTED;
    // 原resource副本先锁内取，锁外查询Core，再锁内复核同handle与mode，禁止锁反向进入Core。
    auto& r=state();AmclLookResourceV1 resource{};{std::lock_guard<std::mutex> lock(r.mutex);auto it=r.streams.find(handle);
        if(it==r.streams.end()||!it->second.active)return AMCL_LOOK_STALE;resource=it->second.description.resource;}
    if(!resourceCurrent(resource))return AMCL_LOOK_STALE;
    std::lock_guard<std::mutex> lock(r.mutex);auto it=r.streams.find(handle);
    if(it==r.streams.end()||!it->second.active||!modeCurrent(r,resource))return AMCL_LOOK_STALE;
    if(ns<it->second.sample)return AMCL_LOOK_REJECTED;
    if((it->second.description.reserved&AMCL_LOOK_STREAM_POLICY_LEASE)&&it->second.policyEpoch!=r.families[familyOf(it->second)].policyEpoch)return AMCL_LOOK_STALE;
    try{auto families=r.families;auto streams=r.streams;const size_t family=familyOf(it->second);
        // sample clock只检本流；family math使用接受时钟，避免同为ns的不同域相互拒绝/排序。
        const int64_t mathNs=it->second.description.clock==AMCL_LOOK_OWNER_MONOTONIC?static_cast<int64_t>(ns):
            static_cast<int64_t>(ownerNow());
        if(!processFamily(families[family],streams,family,singleSample(handle,{x,y}),mathNs))return AMCL_LOOK_REJECTED;
        streams.at(handle).sample=ns;r.families=std::move(families);r.streams=std::move(streams);backlog(r);return 0;
    }catch(const std::bad_alloc&){return AMCL_LOOK_PRESSURE;}}
// V1 表保留原序号供预编译消费者校验；已退休的映射操作没有可创建的流。
int32_t velocity(uint64_t,double,double,uint64_t){return AMCL_LOOK_REJECTED;}
int32_t advance(uint64_t,uint64_t){return AMCL_LOOK_REJECTED;}
/** 单流触摸/gyro的局部候选。只在同族唯一且无其它owed时使用；其它来源
 * pending保留原值。任何共同积分/多流求和仍走下方完整事务，不按当前流猜其它流已空。
 * 调用方持look锁；分配只发生在新增不可变prefix，成功前不改变数学、sample或token。 */
bool trySealSingle(Registry& r,uint64_t handle,double dx,double dy,uint64_t sampleNs,
        uint64_t order,uint64_t ns,uint32_t flush,AmclLookPrefixV1* output,bool processed,int32_t& result) {
    if (!handle || flush==1) return false;
    const auto found=r.streams.find(handle);
    if(found==r.streams.end()||!found->second.active) {result=AMCL_LOOK_STALE;return true;}
    const size_t family=familyOf(found->second);
    for(const auto& entry:r.streams) if(entry.second.active) {
        if(entry.first!=handle&&(familyOf(entry.second)==family||entry.second.owed.x!=0||entry.second.owed.y!=0)) return false;
    }
    auto families=r.families;
    SingleStream streams{{{handle,found->second}}};auto& current=streams[0].second;
    result=AMCL_LOOK_REJECTED;
    if(!modeCurrent(r,current.description.resource)) {result=AMCL_LOOK_STALE;return true;}
    if((current.description.reserved&AMCL_LOOK_STREAM_POLICY_LEASE)&&current.policyEpoch!=families[family].policyEpoch) {
        result=AMCL_LOOK_STALE;return true;
    }
    if(!finite({dx,dy})||(flush==2&&(dx!=0||dy!=0))) return true;
    if(flush!=2) {
        if(!sampleNs||sampleNs>INT64_MAX||sampleNs<current.sample) return true;
        if(processed) {current.owed.x+=dx;current.owed.y+=dy;if(!finite(current.owed))return true;}
        else if(!processFamily(families[family],streams,family,singleSample(handle,{dx,dy}),
            static_cast<int64_t>(current.description.kind==AMCL_LOOK_GYRO_DELTA?ns:sampleNs))) return true;
        current.sample=sampleNs;
    }
    Pair delivered=current.owed;
    if(flush==2) {delivered.x+=current.pending.x;delivered.y+=current.pending.y;}
    if(!finite(delivered)||std::abs(delivered.x)>std::numeric_limits<float>::max()||
        std::abs(delivered.y)>std::numeric_limits<float>::max())return true;
    if(flush==2&&(current.pending.x!=0||current.pending.y!=0))
        families[family].stats.NoteFlush(true,current.pending.x,current.pending.y);
    if(delivered.x!=0||delivered.y!=0) {
        Prefix prefix;prefix.identity.size=sizeof(AmclLookPrefixV1);prefix.identity.token=r.nextPrefix;
        prefix.identity.order=order;prefix.identity.gameSession=r.session;prefix.identity.resource=current.description.resource;
        prefix.contributions.emplace(handle,delivered);const auto identity=prefix.identity;
        r.prefixes.emplace(identity.token,std::move(prefix));
        ++r.nextPrefix;current.owed={};if(flush==2)current.pending={};*output=identity;
        result=AMCL_LOOK_PREFIX_READY;
#if AMCL_INPUT_TRACE
        amclInputLatencyAcceptV1(identity.token,identity.order,identity.gameSession,1);
#endif
    } else result=0;
    found->second=current;r.families[family]=families[family];
    return true;
}

int32_t sealCandidate(uint64_t handle,double dx,double dy,uint64_t sampleNs,uint64_t session,uint64_t order,uint64_t ns,uint32_t flush,AmclLookPrefixV1* output,bool processed=false){if(output)*output={};
    if(foreign())return AMCL_LOOK_NOT_READY;if(!output||!order||!ns||ns>INT64_MAX||flush>2||(flush==2&&!handle))return AMCL_LOOK_REJECTED;
    auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);if(r.session!=session||!r.grabbed)return AMCL_LOOK_STALE;
    // 运输方须先预留真实ring空间；prefix本身容量与所有候选分配也在数学提交之前核验。
    if(r.prefixes.size()>=kPrefixes||r.nextPrefix==UINT64_MAX)return AMCL_LOOK_PRESSURE;
    try{int32_t singleResult=0;
        if(trySealSingle(r,handle,dx,dy,sampleNs,order,ns,flush,output,processed,singleResult))return singleResult;
        auto families=r.families;auto streams=r.streams;
        if(handle){auto it=streams.find(handle);if(it==streams.end()||!it->second.active||!modeCurrent(r,it->second.description.resource))return AMCL_LOOK_STALE;
            if((it->second.description.reserved&AMCL_LOOK_STREAM_POLICY_LEASE)&&it->second.policyEpoch!=families[familyOf(it->second)].policyEpoch)return AMCL_LOOK_STALE;
            if(!finite({dx,dy}))return AMCL_LOOK_REJECTED;
            // flush2只封该流已经接受的owed/pending，不是新的零delta采样。idle/UP的owner
            // deadline不能覆盖原SDK sample或family.last；否则UI队列中更晚于上一SDK
            // sample、却早于deadline的合法事件会被拒，退休重开流仍会撞family数学时钟。
            // 这里保留原handle/资源/policy；非零delta不能借
            // seal-only绕过采样校验，必须显式拒绝。真正delta仍按原sample计算加速/平滑。
            if(flush==2){if(dx!=0||dy!=0)return AMCL_LOOK_REJECTED;}
            if(flush!=2){
                if(!sampleNs||sampleNs>INT64_MAX||sampleNs<it->second.sample)return AMCL_LOOK_REJECTED;
                if(processed){const Pair owed{it->second.owed.x+dx,it->second.owed.y+dy};if(!finite(owed))return AMCL_LOOK_REJECTED;it->second.owed=owed;}
                else {
                    // 手指/明确旧delta仍保原声明采样clock的加速与平滑系数；gyro STARTUP
                    // 只检本流次序并用owner接受clock即时线性处理，不把同ns数值强作同域。
                    const int64_t mathNs=it->second.description.kind==AMCL_LOOK_GYRO_DELTA?static_cast<int64_t>(ns):static_cast<int64_t>(sampleNs);
                    const size_t family=familyOf(it->second);
                    if(!processFamily(families[family],streams,family,singleSample(handle,{dx,dy}),mathNs))return AMCL_LOOK_REJECTED;
                }
                it->second.sample=sampleNs;}}
        std::array<Pair,AMCL_INPUT_SOURCE_COUNT+1> flushed{};
        Prefix candidate;Pair combined{};candidate.identity.size=sizeof(AmclLookPrefixV1);candidate.identity.order=order;candidate.identity.gameSession=session;
        for(auto& e:streams){auto& s=e.second;if(!s.active)continue;Pair delivered=s.owed;
            const bool flushThis=flush==1||(flush==2&&e.first==handle);
            if(flushThis){delivered.x+=s.pending.x;delivered.y+=s.pending.y;
                flushed[familyOf(s)].x+=s.pending.x;flushed[familyOf(s)].y+=s.pending.y;}
            if(!finite(delivered))return AMCL_LOOK_REJECTED;if(delivered.x==0&&delivered.y==0)continue;
            combined.x+=delivered.x;combined.y+=delivered.y;
            if(candidate.contributions.empty())candidate.identity.resource=s.description.resource;
            if(candidate.identity.resource.modeEpoch!=s.description.resource.modeEpoch||
                candidate.identity.resource.surfaceEpoch!=s.description.resource.surfaceEpoch||
                candidate.identity.resource.focusEpoch!=s.description.resource.focusEpoch)return AMCL_LOOK_STALE;
            candidate.contributions.emplace(e.first,delivered);s.owed={};if(flushThis)s.pending={};}
        // 先算完整净贡献再验边界，相反设备的合法抵消不能被中间部分和误拒；退一来源后的
        // 子集另由prepare检查，不把过大值送到某SDK才发现float溢出。
        if(!finite(combined)||std::abs(combined.x)>std::numeric_limits<float>::max()||std::abs(combined.y)>std::numeric_limits<float>::max())return AMCL_LOOK_REJECTED;
        for(size_t i=0;i<flushed.size();++i)if(flushed[i].x!=0||flushed[i].y!=0)families[i].stats.NoteFlush(true,flushed[i].x,flushed[i].y);
        if(candidate.contributions.empty()){r.families=std::move(families);r.streams=std::move(streams);return 0;}
        candidate.identity.token=r.nextPrefix;const auto identity=candidate.identity;r.prefixes.emplace(identity.token,std::move(candidate));++r.nextPrefix;
        r.families=std::move(families);r.streams=std::move(streams);*output=identity;
#if AMCL_INPUT_TRACE
        // 真候选成功后才记接受；此前失败不伪造接受。贡献范围尚未逐样本绑定，导出明确unknown。
        amclInputLatencyAcceptV1(identity.token,identity.order,identity.gameSession,static_cast<uint32_t>(r.prefixes.at(identity.token).contributions.size()));
#endif
        return AMCL_LOOK_PREFIX_READY;
    }catch(const std::bad_alloc&){return AMCL_LOOK_PRESSURE;}}
int32_t seal(uint64_t session,uint64_t order,uint64_t ns,uint32_t flush,AmclLookPrefixV1* output){
    return sealCandidate(0,0,0,0,session,order,ns,flush,output);}
int32_t retireStream(uint64_t handle){if(foreign())return AMCL_LOOK_NOT_READY;auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);
    auto it=r.streams.find(handle);if(it==r.streams.end()||!it->second.active)return AMCL_LOOK_STALE;
    // 已进入ABI的运动不逆向回滚，所有未来prepare只读取仍active的原贡献。
    // owed已经记作processor emit；撤运输由consumer另记discard，不能再次当数学pending丢弃。
    auto& s=it->second;r.families[familyOf(s)].stats.NoteFlush(false,s.pending.x,s.pending.y);
    // prefix只存handle/输出贡献，未应用贡献可由handle缺席判退休；无须保留已退流占容量。
    r.streams.erase(it);return 0;}
int32_t retirePrefix(uint64_t token){if(foreign())return AMCL_LOOK_NOT_READY;auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);
    const auto prefix=r.prefixes.find(token);if(prefix!=r.prefixes.end()&&prefix->second.receivers)return AMCL_LOOK_NOT_READY;
    if(!r.prefixes.erase(token))return AMCL_LOOK_STALE;
#if AMCL_INPUT_TRACE
    amclInputLatencyFinishV1(token,AMCL_ILAT_RETIRED);
#endif
    for(auto& c:r.consumers)c.second.used.erase(token);
    // 退役流只有在所有原prefix已离开运输后才回收，handle计数保持单调，设备热插不耗尽槽。
    for(auto s=r.streams.begin();s!=r.streams.end();){bool referenced=false;
        if(!s->second.active)for(const auto& p:r.prefixes)if(p.second.contributions.count(s->first)){referenced=true;break;}
        if(!s->second.active&&!referenced)s=r.streams.erase(s);else ++s;}return 0;}
int32_t bindConsumer(uint64_t handle,double x,double y){if(foreign())return AMCL_LOOK_NOT_READY;
    if(!finite({x,y}))return AMCL_LOOK_REJECTED;AmclControlSnapshotV1 facts{};if(!controlFacts(handle,facts)||!facts.target)return AMCL_LOOK_NOT_READY;
    auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);if(facts.gameSession!=r.session)return AMCL_LOOK_STALE;
    const auto it=r.consumers.find(handle);if(it!=r.consumers.end()&&consumerCurrent(it->second,facts)&&it->second.mode==r.mode&&
        it->second.backendEpoch==r.backendEpoch[facts.backend-1])return 0;
    // 重锚是真实consumer/target/activation退休点。旧backend运输位必须退出，不能把尚未
    // 消费、仍为兄弟ABI保留的old token认领到同宽高的新target。首个consumer允许启动前缀。
    // 只有同一control consumer的完整事实和mode仍相同、仅backendEpoch发生变化，才是
    // 真实backend退休后的重开。setBackendActive已清旧prefix的接收位，不能在此把重开后
    // 新产生的首笔prefix再次清掉。target/activation/session/mode换代仍按原替换合同退休。
    const bool backendRestartOnly=it!=r.consumers.end()&&consumerCurrent(it->second,facts)&&
        it->second.mode==r.mode&&it->second.backendEpoch!=r.backendEpoch[facts.backend-1];
    bool replacing=it!=r.consumers.end()&&!backendRestartOnly;
    for(const auto& old:r.consumers)if(old.first!=handle&&old.second.stats.backend==facts.backend)replacing=true;
    if(it==r.consumers.end()&&r.consumers.size()>=kConsumers)return AMCL_LOOK_PRESSURE;
    try{Consumer c;c.stats.size=sizeof(c.stats);c.stats.backend=facts.backend;c.stats.consumer=handle;c.stats.gameSession=facts.gameSession;
        c.stats.activation=facts.activation;c.stats.target=facts.target;c.stats.x=x;c.stats.y=y;c.mode=r.mode;c.backendEpoch=r.backendEpoch[facts.backend-1];
        // 已claim的SDK调用可能同步重入换target，原票保留到真实返回，只记录旧事实而不写新cursor。
        // 所有可能分配先建候选，Pressure不能先清旧运输位/旧上下文。
        if(it!=r.consumers.end())for(const auto& old:it->second.tickets)if(old.second.claimed)c.tickets.emplace(old.first,old.second);
        r.consumers[handle]=std::move(c);
        if(replacing)for(auto& prefix:r.prefixes)prefix.second.receivers&=~(1u<<(facts.backend-1));
        return 0;
    }catch(const std::bad_alloc&){return AMCL_LOOK_PRESSURE;}}
int32_t prepare(uint64_t handle,uint64_t token,AmclLookEmissionV1* output){if(output)*output={};if(foreign())return AMCL_LOOK_NOT_READY;
    if(!output)return AMCL_LOOK_REJECTED;AmclControlSnapshotV1 facts{};if(!controlFacts(handle,facts))return AMCL_LOOK_STALE;
    auto& r=state();AmclLookResourceV1 resource{};{std::lock_guard<std::mutex> lock(r.mutex);auto p=r.prefixes.find(token);
        if(p==r.prefixes.end())return AMCL_LOOK_STALE;resource=p->second.identity.resource;}
    if(!resourceCurrent(resource))return AMCL_LOOK_STALE;
    std::lock_guard<std::mutex> lock(r.mutex);auto c=r.consumers.find(handle);auto p=r.prefixes.find(token);
    if(c==r.consumers.end()||p==r.prefixes.end()||!consumerCurrent(c->second,facts)||!modeCurrent(r,resource))return AMCL_LOOK_STALE;
    if(c->second.used.count(token))return AMCL_LOOK_REJECTED;
    if(!(r.activeBackends&(1u<<(facts.backend-1)))||c->second.backendEpoch!=r.backendEpoch[facts.backend-1])return AMCL_LOOK_STALE;
    // Mouse独立关闭后不能借仍因兄弟消费者保留的old token重放到新Mouse；保留位是
    // 真实运输接收者的寿命证明。直接owner数值测试未运输的prefix不伪造这份证明。
    if(p->second.transported&&!(p->second.receivers&(1u<<(facts.backend-1))))return AMCL_LOOK_STALE;
    if(p->second.identity.order<=c->second.lastOrder)return AMCL_LOOK_STALE;
    for(const auto& pending:c->second.tickets)if(pending.second.emission.prefix==token)return AMCL_LOOK_REJECTED;
    if(c->second.tickets.size()>=kTickets||r.nextTicket==UINT64_MAX)return AMCL_LOOK_PRESSURE;
    Pair motion{};for(const auto& contribution:p->second.contributions){auto s=r.streams.find(contribution.first);
        if(s!=r.streams.end()&&s->second.active){motion.x+=contribution.second.x;motion.y+=contribution.second.y;}}
    const Pair cursor{c->second.stats.x+motion.x,c->second.stats.y+motion.y};
    if(!finite(motion)||!finite(cursor)||std::abs(motion.x)>std::numeric_limits<float>::max()||std::abs(motion.y)>std::numeric_limits<float>::max())return AMCL_LOOK_REJECTED;
    AmclLookEmissionV1 e{};e.size=sizeof(e);e.backend=facts.backend;e.consumer=handle;e.activation=facts.activation;e.target=facts.target;
    e.prefix=token;e.order=p->second.identity.order;e.dx=motion.x;e.dy=motion.y;e.x=cursor.x;e.y=cursor.y;e.ticket=r.nextTicket++;
    // 完成口必须无分配：used槽与ticket在实际ABI写cache之前一并预留。
    try{c->second.used.insert(token);c->second.tickets.emplace(e.ticket,Ticket{e,false,false,r.backendEpoch[facts.backend-1]});++c->second.stats.accepted;*output=e;return 1;
    }catch(const std::bad_alloc&){c->second.used.erase(token);return AMCL_LOOK_PRESSURE;}}
int32_t ticketCheck(const AmclLookEmissionV1* e,bool claim){if(foreign())return AMCL_LOOK_NOT_READY;
    if(!e||e->size!=sizeof(*e))return AMCL_LOOK_REJECTED;AmclControlSnapshotV1 facts{};if(!controlFacts(e->consumer,facts))return AMCL_LOOK_STALE;
    auto& r=state();AmclLookResourceV1 resource{};
    {std::lock_guard<std::mutex> lock(r.mutex);const auto prefix=r.prefixes.find(e->prefix);
        if(prefix==r.prefixes.end())return AMCL_LOOK_STALE;resource=prefix->second.identity.resource;}
    // SDK transform/watcher可在prepare之后同步撤focus/context，claim与validate必须重读
    // 原Core资源。查询在look锁外，随后再核原票/mode，不形成Core→look锁反转。
    if(!resourceCurrent(resource))return AMCL_LOOK_STALE;
    std::lock_guard<std::mutex> lock(r.mutex);auto c=r.consumers.find(e->consumer);if(c==r.consumers.end())return AMCL_LOOK_STALE;
    auto t=c->second.tickets.find(e->ticket);if(t==c->second.tickets.end()||!sameEmission(t->second.emission,*e))return AMCL_LOOK_REJECTED;
    auto p=r.prefixes.find(e->prefix);if(!consumerCurrent(c->second,facts)||p==r.prefixes.end()||!modeCurrent(r,p->second.identity.resource))return AMCL_LOOK_STALE;
    if(!(r.activeBackends&(1u<<(e->backend-1)))||t->second.backendEpoch!=r.backendEpoch[e->backend-1])return AMCL_LOOK_STALE;
    // 停源可发生在prepare/claim和实际SDK写cache之间。原票含已经退休贡献时拒绝；
    // 边缘discard后可重新prepare同prefix，仅交付仍active的兄弟贡献，不逆向回滚已写cache。
    if(!t->second.cached){Pair current{};for(const auto& contribution:p->second.contributions){const auto s=r.streams.find(contribution.first);
            if(s!=r.streams.end()&&s->second.active){current.x+=contribution.second.x;current.y+=contribution.second.y;}}
        if(current.x!=e->dx||current.y!=e->dy)return AMCL_LOOK_STALE;}
    if(claim){if(t->second.claimed)return AMCL_LOOK_REJECTED;t->second.claimed=true;}return 1;}
int32_t claim(const AmclLookEmissionV1* e){return ticketCheck(e,true);}
int32_t validate(const AmclLookEmissionV1* e){return ticketCheck(e,false);}
int32_t complete(const AmclLookEmissionV1* e,uint32_t phase){if(foreign())return AMCL_LOOK_NOT_READY;
    if(!e||e->size!=sizeof(*e)||phase>5)return AMCL_LOOK_REJECTED;AmclControlSnapshotV1 facts{};const bool exists=controlFacts(e->consumer,facts);
    auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);auto c=r.consumers.find(e->consumer);if(c==r.consumers.end())return AMCL_LOOK_STALE;
    auto t=c->second.tickets.find(e->ticket);if(t==c->second.tickets.end()||(!t->second.claimed&&phase!=AMCL_CONTROL_DISCARDED)||!sameEmission(t->second.emission,*e))return AMCL_LOOK_REJECTED;
    const bool current=exists&&consumerCurrent(c->second,facts)&&r.prefixes.count(e->prefix)&&
        (r.activeBackends&(1u<<(e->backend-1)))&&t->second.backendEpoch==r.backendEpoch[e->backend-1];
    if(phase<=3&&current&&!t->second.cached){
        c->second.stats.x=e->x;c->second.stats.y=e->y;c->second.stats.availablePrefix=e->prefix;c->second.lastOrder=e->order;
        ++c->second.stats.cacheReady;t->second.cached=true;}
    if(!current)++c->second.stats.stale;if(phase==0)return current?0:AMCL_LOOK_STALE;
    if(phase==1)++c->second.stats.callbackReturned;else if(phase==2)++c->second.stats.queueAccepted;
    else if(phase==4)++c->second.stats.uncertain;else if(phase==5)++c->second.stats.discarded;
    // 未写cache且明确丢弃可重新prepare兄弟贡献；uncertain不重放可能已写的运动。
    if(phase==5&&!t->second.cached)c->second.used.erase(e->prefix);
    const auto prefix=r.prefixes.find(e->prefix);
    // 未cache且target当前的discard仅撤准备票，保运输持有供原consumer有界重试，GC不能抢token。
    // 最终不再重试时必须abandonPrefix；closeConsumer/资源stale同样可以真实结束此接收者。
    if(prefix!=r.prefixes.end()&&(phase!=AMCL_CONTROL_DISCARDED||t->second.cached||!current))prefix->second.receivers&=~(1u<<(e->backend-1));
    c->second.tickets.erase(t);return current?0:AMCL_LOOK_STALE;}
int32_t poll(uint64_t handle,double x,double y){if(foreign())return AMCL_LOOK_NOT_READY;if(!finite({x,y}))return AMCL_LOOK_REJECTED;
    AmclControlSnapshotV1 facts{};if(!controlFacts(handle,facts))return AMCL_LOOK_STALE;
    auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);auto c=r.consumers.find(handle);
    if(c==r.consumers.end()||!consumerCurrent(c->second,facts)||!(r.activeBackends&(1u<<(facts.backend-1)))||
        c->second.backendEpoch!=r.backendEpoch[facts.backend-1])return AMCL_LOOK_STALE;++c->second.stats.legalPollReads;return 0;}
int32_t snapshot(uint64_t handle,AmclLookSnapshotV1* out){if(foreign())return AMCL_LOOK_NOT_READY;
    if(!out||out->size!=sizeof(*out))return AMCL_LOOK_REJECTED;auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);
    auto c=r.consumers.find(handle);if(c==r.consumers.end())return AMCL_LOOK_STALE;*out=c->second.stats;return 0;}
void closeConsumer(uint64_t handle){if(foreign())return;auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);
    const auto c=r.consumers.find(handle);if(c!=r.consumers.end())for(auto& p:r.prefixes)p.second.receivers&=~(1u<<(c->second.stats.backend-1));
    r.consumers.erase(handle);}
int32_t abandonPrefix(uint64_t handle,uint64_t token){if(foreign())return AMCL_LOOK_NOT_READY;
    auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);const auto c=r.consumers.find(handle);const auto p=r.prefixes.find(token);
    if(c==r.consumers.end()||p==r.prefixes.end())return AMCL_LOOK_STALE;
    for(const auto& t:c->second.tickets)if(t.second.emission.prefix==token)return AMCL_LOOK_NOT_READY;
    p->second.receivers&=~(1u<<(c->second.stats.backend-1));++c->second.stats.discarded;return 0;}
// 已连接的实体流按原 map 顺序参与同族汇总；常用的一至两只指针只需栈上候选。
// 独立暂存同族拥有的状态，稍后一次提交，历史 prefix 和其它族不因多接一只设备而复制。
using PhysicalIterator = decltype(Registry::streams)::iterator;
struct PhysicalCandidate {
    uint64_t first;
    Stream second;
    Stream* original;
    explicit PhysicalCandidate(PhysicalIterator it) : first(it->first), second(it->second), original(&it->second) {}
};
struct PhysicalStreamView {
    PhysicalCandidate* data;
    size_t count;
    auto begin() const {return data;}
    auto end() const {return data+count;}
};
bool tryPhysicalSample(Registry& r,const AmclInputLookFactV1& fact,int32_t& result) {
    const auto& event=fact.event;
    const auto device=r.physicalStreams.find(event.header.deviceId);
    if(device==r.physicalStreams.end())return false;
    const auto found=r.streams.find(device->second);
    if(found==r.streams.end()||!found->second.active)return false;
    const uint64_t handle=found->first;
    if(r.prefixes.size()>=kPrefixes||r.nextPrefix==UINT64_MAX)return false;
    const auto& old=found->second.description.resource;
    if(old.sessionEpoch!=event.header.sessionEpoch||old.surfaceEpoch!=event.header.surfaceEpoch||
        old.focusEpoch!=event.header.focusEpoch||!modeCurrent(r,old)||
        !amcl::input::SameInputSurfaceContextIdentity(old.context,fact.context))return false;
    result=AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    if(event.header.eventType!=AMCL_INPUT_EVENT_POINTER_RELATIVE||!event.header.sequence||!fact.interactionOrder||
        !event.header.monotonicTimeNs||event.header.monotonicTimeNs>INT64_MAX||!fact.context.generation||
        r.physicalFacts.count(event.header.sequence)||r.physicalOrders.count(fact.interactionOrder))return true;
    const Pair raw{event.payload.pointerRelative.rawDx,event.payload.pointerRelative.rawDy};
    if(!finite(raw)||std::abs(raw.x)>std::numeric_limits<float>::max()||std::abs(raw.y)>std::numeric_limits<float>::max())return true;
    const auto accept = [&](PhysicalStreamView streams, size_t currentIndex) {
        Family family=r.families[3];
        if(!processFamily(family,streams,3,singleSample(handle,raw),static_cast<int64_t>(event.header.monotonicTimeNs)))return true;
        auto& current=streams.data[currentIndex].second;const Pair delivered=current.owed;
        if(!finite(delivered)||std::abs(delivered.x)>std::numeric_limits<float>::max()||std::abs(delivered.y)>std::numeric_limits<float>::max())return true;
        const uint64_t token=r.nextPrefix;
        Prefix prefix;prefix.identity.size=sizeof(AmclLookPrefixV1);prefix.identity.token=token;
        prefix.identity.order=fact.interactionOrder;prefix.identity.gameSession=r.session;prefix.identity.resource=old;
        // 元数据沿本次Core接受快照，不能冻结成最初一条样本的Hz/validBits。
        prefix.identity.resource.context=fact.context;
        prefix.contributions.emplace(handle,delivered);prefix.transported=true;prefix.receivers=fact.backendMask&r.activeBackends&7u;
        struct InsertRollback {
            Registry& registry;uint64_t token,sequence,order;bool prefix=false,fact=false,ordered=false,committed=false;
            ~InsertRollback(){if(!committed){if(ordered)registry.physicalOrders.erase(order);
                if(fact)registry.physicalFacts.erase(sequence);if(prefix)registry.prefixes.erase(token);}}
        } rollback{r,token,event.header.sequence,fact.interactionOrder};
        rollback.prefix=r.prefixes.emplace(token,std::move(prefix)).second;
        if(!rollback.prefix)return true;
        rollback.fact=r.physicalFacts.emplace(event.header.sequence,token).second;
        if(!rollback.fact)return true;
        rollback.ordered=r.physicalOrders.emplace(fact.interactionOrder,token).second;
        if(!rollback.ordered)return true;
        current.owed={};current.sample=event.header.monotonicTimeNs;
        // 三个新增索引均已成功，才公开这次样本及其它同族流的数学余量。
        for(const auto& entry:streams)*entry.original=entry.second;
        r.families[3]=family;++r.nextPrefix;rollback.committed=true;
        // 稳态只回收队首最多8个完成项，不每个MOVE扫描全部积压；被慢消费者挡住时，
        // 容量门会进入原完整候选回收/压力路径，未消费记录不被提前抹去。
        for(size_t n=0;n<8&&!r.physicalFacts.empty();++n) {
            const auto first=r.physicalFacts.begin();if(first->first==event.header.sequence)break;
            const auto prior=r.prefixes.find(first->second);
            if(prior!=r.prefixes.end()&&prior->second.receivers)break;
            const uint64_t retired=first->second;
            if(prior!=r.prefixes.end()){r.physicalOrders.erase(prior->second.identity.order);r.prefixes.erase(prior);}
            r.physicalFacts.erase(first);
            for(auto& consumer:r.consumers)consumer.second.used.erase(retired);
        }
        result=AMCL_INPUT_OK;return true;
    };
    // 先判定同族 sibling 数。独鼠直接复制 found 一份，无多余 Stream 初始化或写回查树。
    auto sibling=r.streams.end();
    if (r.streams.size()!=1) {
        for (auto it=r.streams.begin(); it!=r.streams.end(); ++it) {
            if (it==found || !it->second.active || familyOf(it->second)!=3) continue;
            if (sibling!=r.streams.end()) {
                // 三只及以上才需要可变长候选；已有 map 节点在本锁内稳定，可直接用于末尾提交。
                std::vector<PhysicalCandidate> several;
                size_t currentIndex=0;
                for (auto source=r.streams.begin(); source!=r.streams.end(); ++source) {
                    if (!source->second.active || familyOf(source->second)!=3) continue;
                    if (source==found) currentIndex=several.size();
                    several.emplace_back(source);
                }
                return accept({several.data(),several.size()},currentIndex);
            }
            sibling=it;
        }
    }
    if (sibling==r.streams.end()) {
        PhysicalCandidate only(found);
        return accept({&only,1},0);
    }
    const bool first=found->first < sibling->first;
    PhysicalCandidate pair[]{PhysicalCandidate(first?found:sibling),PhysicalCandidate(first?sibling:found)};
    return accept({pair,2},first?0:1);
}

/** Core持自己的接受mutex调用本hook；这里从不反查Core/ABI。整个physical批次以候选提交，
 * 任一数学/容量/浮点边界失败保持所有family/stream/memo原值，由Core回滚其完整接受事务。 */
int32_t acceptPhysical(const AmclInputLookFactV1* facts,uint32_t count){if(foreign())return AMCL_INPUT_ERROR_BACKEND_NOT_READY;
    if(!facts||!count||count>kPrefixes)return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
    auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);
    if(count==1&&facts[0].event.header.eventType==AMCL_INPUT_EVENT_DEVICE_CHANGED&&facts[0].event.payload.device.change==AMCL_INPUT_DEVICE_REMOVED){
        // Core已接受真实设备移除；清理不分配、不依赖release成功。prefix的该handle缺席即
        // 表示未cache贡献退休，已写过的运动不回滚；同号ReAdd将在下一事实取得新stream。
        const auto device=r.physicalStreams.find(facts[0].event.header.deviceId);
        if(device!=r.physicalStreams.end()){r.streams.erase(device->second);r.physicalStreams.erase(device);}return AMCL_INPUT_OK;
    }
    if(!r.session||!r.grabbed)return AMCL_INPUT_ERROR_BACKEND_NOT_READY;
    try{
        int32_t singleResult=0;
        if(count==1&&tryPhysicalSample(r,facts[0],singleResult))return singleResult;
        // 已终结physical memo在下一接受点回收，ring prefix由原ring GC负责；共享预算不得无界涨。
        auto prefixes=r.prefixes;auto physicalFacts=r.physicalFacts;auto orders=r.physicalOrders;std::vector<uint64_t> reclaimed;
        for(auto it=physicalFacts.begin();it!=physicalFacts.end();){const auto prefix=prefixes.find(it->second);
            if(prefix==prefixes.end()||!prefix->second.receivers){reclaimed.push_back(it->second);if(prefix!=prefixes.end()){orders.erase(prefix->second.identity.order);prefixes.erase(prefix);}it=physicalFacts.erase(it);}else ++it;}
        if(prefixes.size()>kPrefixes-count||r.nextPrefix>UINT64_MAX-count||r.nextStream>UINT64_MAX-count)
            return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
        auto families=r.families;auto streams=r.streams;auto devices=r.physicalStreams;
        uint64_t nextStream=r.nextStream,nextPrefix=r.nextPrefix;
        for(uint32_t index=0;index<count;++index){const auto& fact=facts[index];const auto& event=fact.event;
            if(event.header.eventType!=AMCL_INPUT_EVENT_POINTER_RELATIVE||!event.header.sequence||!fact.interactionOrder||
                !event.header.monotonicTimeNs||event.header.monotonicTimeNs>INT64_MAX||!fact.context.generation)
                return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
            if(physicalFacts.count(event.header.sequence))return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
            AmclLookResourceV1 resource{};resource.size=sizeof(resource);resource.grabbed=1;resource.gameSession=r.session;
            resource.sessionEpoch=event.header.sessionEpoch;resource.surfaceEpoch=event.header.surfaceEpoch;
            resource.focusEpoch=event.header.focusEpoch;resource.modeEpoch=r.mode;resource.context=fact.context;
            auto device=devices.find(event.header.deviceId);uint64_t handle=device==devices.end()?0:device->second;
            auto stream=streams.find(handle);
            if(stream==streams.end())handle=0;
            if(stream!=streams.end()&&(stream->second.description.resource.sessionEpoch!=resource.sessionEpoch||
                stream->second.description.resource.surfaceEpoch!=resource.surfaceEpoch||stream->second.description.resource.focusEpoch!=resource.focusEpoch||
                !amcl::input::SameInputSurfaceContextIdentity(stream->second.description.resource.context,resource.context))){
                streams.erase(stream);handle=0;families[3].last=0;}
            if(!handle){if(streams.size()>=kStreams)return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;
                Stream candidate;candidate.description.size=sizeof(AmclLookStreamV1);candidate.description.source=3;
                candidate.description.kind=AMCL_LOOK_PHYSICAL_DELTA;
                candidate.description.unit=(event.header.flags&AMCL_INPUT_EVENT_FLAG_HARDWARE_RAW)?AMCL_LOOK_HARDWARE_COUNTS:AMCL_LOOK_PLATFORM_RELATIVE_COUNTS;
                candidate.description.clock=AMCL_LOOK_PLATFORM_SAMPLE;candidate.description.device=event.header.deviceId;
                candidate.description.connection=event.header.deviceId?event.header.sessionEpoch:0;candidate.description.resource=resource;
                candidate.policyEpoch=families[3].policyEpoch;handle=nextStream++;streams.emplace(handle,candidate);devices[event.header.deviceId]=handle;}
            // 原typed raw单位/硬件完整性仍由public record声明；数学只取同一次接受事实，alpha固定1。
            const Pair raw{event.payload.pointerRelative.rawDx,event.payload.pointerRelative.rawDy};
            // 旧64-byte backend保原raw字段，而SDK读取使用float。raw本身也必须先可编码，
            // 不能靠低sensitivity把非法raw缩小后假接受，随后EncodeRaw丢记录却留下memo保留位。
            if(!finite(raw)||std::abs(raw.x)>std::numeric_limits<float>::max()||std::abs(raw.y)>std::numeric_limits<float>::max())
                return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
            if(!processFamily(families[3],streams,3,singleSample(handle,raw),static_cast<int64_t>(event.header.monotonicTimeNs)))
                return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
            auto& current=streams.at(handle);const Pair delivered=current.owed;
            // 三消费者最窄SDL float边界在接受前统一拒绝，不能加工成功后到某consumer才溢出。
            if(!finite(delivered)||std::abs(delivered.x)>std::numeric_limits<float>::max()||std::abs(delivered.y)>std::numeric_limits<float>::max())
                return AMCL_INPUT_ERROR_INVALID_ARGUMENT;
            current.owed={};current.sample=event.header.monotonicTimeNs;
            Prefix prefix;prefix.identity.size=sizeof(AmclLookPrefixV1);prefix.identity.token=nextPrefix++;
            prefix.identity.order=fact.interactionOrder;prefix.identity.gameSession=r.session;prefix.identity.resource=resource;
            prefix.contributions.emplace(handle,delivered);prefix.transported=true;prefix.receivers=fact.backendMask&r.activeBackends&7u;
            physicalFacts.emplace(event.header.sequence,prefix.identity.token);orders.emplace(fact.interactionOrder,prefix.identity.token);
            prefixes.emplace(prefix.identity.token,std::move(prefix));
        }
        r.families=std::move(families);r.streams=std::move(streams);r.physicalStreams=std::move(devices);r.prefixes=std::move(prefixes);
        r.physicalFacts=std::move(physicalFacts);r.physicalOrders=std::move(orders);r.nextStream=nextStream;r.nextPrefix=nextPrefix;
        for(const auto token:reclaimed)for(auto& consumer:r.consumers)consumer.second.used.erase(token);
        return AMCL_INPUT_OK;
    }catch(const std::bad_alloc&){return AMCL_INPUT_ERROR_RESOURCE_EXHAUSTED;}}
int32_t physicalPrefix(uint64_t sequence,uint64_t* output){if(output)*output=0;if(foreign())return AMCL_LOOK_NOT_READY;
    if(!output||!sequence)return AMCL_LOOK_REJECTED;auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);
    const auto fact=r.physicalFacts.find(sequence);if(fact==r.physicalFacts.end()||!r.prefixes.count(fact->second))return AMCL_LOOK_STALE;
    *output=fact->second;return AMCL_LOOK_PREFIX_READY;}
int32_t physicalPrefixByOrder(uint64_t order,uint64_t* output){if(output)*output=0;if(foreign())return AMCL_LOOK_NOT_READY;
    if(!output||!order)return AMCL_LOOK_REJECTED;auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);
    const auto fact=r.physicalOrders.find(order);if(fact==r.physicalOrders.end()||!r.prefixes.count(fact->second))return AMCL_LOOK_STALE;
    *output=fact->second;return AMCL_LOOK_PREFIX_READY;}
int32_t setBackendActive(uint32_t backend,uint32_t active){if(foreign())return AMCL_LOOK_NOT_READY;
    if(backend<1||backend>3||active>1)return AMCL_LOOK_REJECTED;auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);
    const uint32_t bit=1u<<(backend-1);const bool previous=(r.activeBackends&bit)!=0;if(previous==(active!=0))return 0;
    if(active&&r.backendEpoch[backend-1]==UINT64_MAX)return AMCL_LOOK_PRESSURE;
    if(r.backendEpoch[backend-1]!=UINT64_MAX)++r.backendEpoch[backend-1];
    const bool restartingAll=active&&r.activeBackends==0;
    if(active)r.activeBackends|=bit;else r.activeBackends&=~bit;
    for(auto& prefix:r.prefixes){prefix.second.receivers&=~bit;
#if AMCL_INPUT_TRACE
        if(!active&&backend==1)amclInputLatencyFinishV1(prefix.first,AMCL_ILAT_RETIRED);
#endif
    }
    if(!r.activeBackends||restartingAll){std::array<Pair,AMCL_INPUT_SOURCE_COUNT+1> discarded{};
        for(auto& source:r.streams){discarded[familyOf(source.second)].x+=source.second.pending.x;
            discarded[familyOf(source.second)].y+=source.second.pending.y;source.second.pending={};source.second.owed={};source.second.sample=0;}
        for(size_t i=0;i<discarded.size();++i){r.families[i].stats.NoteFlush(false,discarded[i].x,discarded[i].y);r.families[i].last=0;}}
    return 0;}
}

extern "C" const AmclLookExecutionPortV1* amclLookExecutionGetPortV1(){if(foreign())return nullptr;(void)state();
    static const AmclLookExecutionPortV1 port={AMCL_LOOK_EXECUTION_MAGIC,1,sizeof(AmclLookExecutionPortV1),ownerProcess,0,
        reinterpret_cast<uintptr_t>(amclInputGetHostApiV1()),verify,bindSession,publishMode,policy,openStream,delta,velocity,advance,seal,
        retireStream,retirePrefix,bindConsumer,prepare,claim,validate,complete,poll,snapshot,closeConsumer,abandonPrefix,physicalPrefix,
        physicalPrefixByOrder,setBackendActive};return &port;}
extern "C" int32_t amclLookExecutionCommitV1(uint64_t stream,double dx,double dy,uint64_t sampleNs,
        uint64_t session,uint64_t order,uint64_t ownerNs,uint32_t flush,AmclLookPrefixV1* output){
    return sealCandidate(stream,dx,dy,sampleNs,session,order,ownerNs,flush,output);}
extern "C" int32_t amclLookExecutionCommitProcessedV1(uint64_t stream,double dx,double dy,
        uint64_t session,uint64_t order,uint64_t ns,AmclLookPrefixV1* output){
    return sealCandidate(stream,dx,dy,ns,session,order,ns,0,output,true);}
extern "C" void amclLookExecutionSetRecipientsV1(uint64_t token,uint32_t mask){if(foreign())return;auto& r=state();
    std::lock_guard<std::mutex> lock(r.mutex);const auto p=r.prefixes.find(token);if(p!=r.prefixes.end()){p->second.receivers=mask&r.activeBackends&7u;p->second.transported=true;}}
extern "C" uint64_t amclLookPolicyEpochV1(int32_t source){if(foreign()||!validSource(source))return 0;auto& r=state();
    std::lock_guard<std::mutex> lock(r.mutex);return r.families[static_cast<size_t>(source)].policyEpoch;}
extern "C" void amclLookExecutionPublishV1(){if(foreign())return;static std::atomic<bool> published{false};
    if(published.load(std::memory_order_acquire))return;(void)amclLookExecutionGetPortV1();
    // 唯一Core的真实接受事务登记同owner算法，不能在consumer/pump线程换回调或另建memo。
    if(!amclInputOwnerInstallLookCommitV1(acceptPhysical))return;char desc[96]{};
    std::snprintf(desc,sizeof(desc),AMCL_LOOK_EXECUTION_PREFIX "%llu",static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&amclLookExecutionGetPortV1)));
#ifdef _WIN32
    const int status=_putenv_s(AMCL_LOOK_EXECUTION_ENV,desc);
#else
    const int status=setenv(AMCL_LOOK_EXECUTION_ENV,desc,1);
#endif
    if(status==0)published.store(true,std::memory_order_release);}

// 下列旧接口是neutral owner的同状态接缝。它们供尚未迁运输的兼容调用使用；新生产
// 流走stream/prefix，不能同时把同一加工结果再次投入兼容累计。没有单独entry桶。
extern "C" bool amclLookCompatProcess(int32_t source,double x,double y,int64_t ns,double* outX,double* outY,bool gyro){
    if(outX)*outX=0;if(outY)*outY=0;if(foreign()||!outX||!outY||!validSource(source)||ns<=0||!finite({x,y}))return false;
    auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);const size_t index=gyro?AMCL_INPUT_SOURCE_COUNT:static_cast<size_t>(source);
    // 每兼容族固定一个独立保留handle，不与设备流混名；首次候选分配失败保持旧状态。
    const uint64_t id=UINT64_MAX-index;
    try{auto families=r.families;auto streams=r.streams;auto& s=streams[id];s.active=true;s.description.source=source;
        s.description.kind=gyro?AMCL_LOOK_GYRO_DELTA:AMCL_LOOK_COMPAT_DELTA;
        const Pair before=s.owed;if(!processFamily(families[index],streams,index,singleSample(id,{x,y}),ns))return false;
        const Pair output{streams.at(id).owed.x-before.x,streams.at(id).owed.y-before.y};streams.at(id).owed=before;
        r.families=std::move(families);r.streams=std::move(streams);backlog(r);*outX=output.x;*outY=output.y;return true;
    }catch(const std::bad_alloc&){return false;}}
extern "C" bool amclLookCompatFlush(int32_t source,bool emit,double* outX,double* outY){if(outX)*outX=0;if(outY)*outY=0;
    if(foreign()||!outX||!outY||!validSource(source))return false;auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);
    for(auto& e:r.streams){auto& s=e.second;const size_t i=familyOf(s);if(i!=static_cast<size_t>(source)&&!(source==1&&!emit&&i==AMCL_INPUT_SOURCE_COUNT))continue;
        r.families[i].stats.NoteFlush(emit,s.pending.x,s.pending.y);if(emit){*outX+=s.pending.x;*outY+=s.pending.y;}s.pending={};
        if(!emit){s.owed={};s.sample=0;}r.families[i].last=0;}return true;}
extern "C" void amclLookCompatReset(){if(foreign())return;auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);
    for(auto& e:r.streams){auto& s=e.second;r.families[familyOf(s)].stats.NoteFlush(false,s.pending.x,s.pending.y);s.pending={};s.owed={};s.sample=0;}
    for(auto& f:r.families)f.last=0;
#if AMCL_INPUT_TRACE
    // reset的既有prefix清理是实际终态，不能靠诊断年龄猜测退休；不读取window或票对象。
    for(const auto& prefix:r.prefixes)amclInputLatencyFinishV1(prefix.first,AMCL_ILAT_RETIRED);
#endif
    r.prefixes.clear();}
extern "C" bool amclLookCompatSet(int32_t source,uint32_t field,double value){if(foreign()||(source!=-1&&!validSource(source))||field>3)return false;
    auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);auto families=r.families;
    for(size_t i=0;i<families.size();++i){if(source!=-1&&i!=static_cast<size_t>(source)&&!(source==1&&i==AMCL_INPUT_SOURCE_COUNT))continue;
        auto& p=families[i].policy;if(field==0)p.sensitivity=value;else if(field==1){if(value!=0&&value!=1)return false;p.invertY=value!=0;}
        else if(field==2)p.smoothing=value;else p.acceleration=value;if(!validPolicy(&p))return false;
        const auto& old=r.families[i].policy;if(old.sensitivity!=p.sensitivity||old.invertY!=p.invertY||old.smoothing!=p.smoothing||old.acceleration!=p.acceleration){
            if(families[i].policyEpoch==UINT64_MAX)return false;++families[i].policyEpoch;}}
    r.families=std::move(families);return true;}
extern "C" void amclLookCompatSnapshot(amcl::input::LookPipelineSnapshot* output){if(!output)return;*output={};if(foreign())return;
    auto& r=state();std::lock_guard<std::mutex> lock(r.mutex);for(const auto& f:r.families){const auto& v=f.stats.Snapshot();
        output->accepted+=v.accepted;output->rejected+=v.rejected;output->emitted+=v.emitted;output->flushEmit+=v.flushEmit;
        output->flushDiscard+=v.flushDiscard;output->scaledDx+=v.scaledDx;output->scaledDy+=v.scaledDy;output->travelDx+=v.travelDx;
        output->travelDy+=v.travelDy;output->emitDx+=v.emitDx;output->emitDy+=v.emitDy;output->backlogDx+=v.backlogDx;
        output->backlogDy+=v.backlogDy;output->discardedDx+=v.discardedDx;output->discardedDy+=v.discardedDy;}
    // family末次flush不能把同族兄弟pending写成零，实际backlog始终由唯一stream贡献求和。
    output->backlogDx=0;output->backlogDy=0;for(const auto& s:r.streams){output->backlogDx+=s.second.pending.x;output->backlogDy+=s.second.pending.y;}
    output->maxBacklog=r.maxBacklog;}
