/** 唯一来源贡献生产实现。既有 registry/ledger/router 算法只在本 neutral 映像运行。
 * 候选阶段可以分配，但不改正式来源状态；实际有序 ring 保全批预算并封旧 look 后，
 * 以节点交换提交候选，再复制全部边沿。消费者的缓存/回调收据仍归 control-v1。
 * 终端取消在运输不可用时可退休原来源；未送出的末松值有独立 deferred 集合，
 * 之后只在最终 desired 仍为 UP 时重送，绝不用旧取消扫同步回入的新持有。 */
#include "source_control.h"
#include "source_control_client.h"
#include "../amcl_input_api.h"
#include "../amcl_input_host_descriptor.h"
#include "../input_look_core_hook.h"
#include "../input_text_core_hook.h"
#include "../delivery/l2_keyboard_scope.h"
#include "../../platform/legacy_output_runtime.h"
#include "../../platform/legacy_output_code.h"
#include <atomic>
#include <map>
#include <vector>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <new>

#ifdef _WIN32
#pragma comment(linker, "/export:amclSourceControlGetPortV1")
#pragma comment(linker, "/export:amclSourceControlPublishV1")
#pragma comment(linker, "/export:amclSourceControlPrepareV1")
#pragma comment(linker, "/export:amclSourceControlCompatEdgeV1")
#pragma comment(linker, "/export:amclSourceControlDrainTerminalsV1")
#endif
extern "C" int inputBridge_beginSourceActionV1(uint32_t edges);
extern "C" void inputBridge_endLookActionV1(void);
// 唯一owner内的私有接受口携原scope，不经另一namespace/global current补戳。
extern "C" void inputBridge_pushKeyScopedV1(int,int,int,int,uint64_t);
#ifdef AMCL_INPUT_BRIDGE_HOST_TESTING
// 既有 host 配方把真正 C11 bridge 编成 C++，旧 pushEvent 保原 host 链接名。
void inputBridge_pushEvent(int,int,int,int,int);
#else
extern "C" void inputBridge_pushEvent(int,int,int,int,int);
#endif

namespace {
using namespace amcl::input;
uint32_t sourcePid(){
#ifdef _WIN32
    return static_cast<uint32_t>(_getpid());
#else
    return static_cast<uint32_t>(getpid());
#endif
}
// 在 module 装载线程冻结；每个入口先检查 PID，再触及 static 初始化 guard/继承 mutex。
const uint32_t sourceProcess=sourcePid();
bool foreign(){return sourcePid()!=sourceProcess;}
// hot consumer 维护在无 terminal 时不解析描述符/不取锁；计数只由唯一 owner 正式提交更新。
std::atomic<uint32_t> terminalPending{0};
std::atomic<uint64_t> preparedRoles[3]{};
constexpr uint64_t kNativeFirst=0x6000000000000000ULL;
constexpr uint64_t kNativeLimit=0x7000000000000000ULL;
struct Edge {Output output;int action;uint64_t keyboardScope=0;};
struct State {
    explicit State(LegacyOutputRuntime& value):runtime(value){}
    LegacyOutputRuntime& runtime;
    uint64_t nextNative=kNativeFirst;
    uint64_t producers[3]{};
    bool resetting=false;
    uint64_t retiredKeyTerminals=0;
    std::map<Output,Edge> deferred;
    // Native schema 组的绑定顺序在 DOWN 冻结，不把当前 UP 参数当新定义解释。
    std::map<OwnerToken,std::vector<Output>> nativeGroups;
};
State* state(){
    // 与 Core/control owner 同样进程 pin，平台退出清理不能遇到先析构的来源账本。
    static State* pinned=[]() noexcept -> State* {
        try {auto* runtime=TryProcessLegacyOutputRuntime();return runtime?new(std::nothrow) State(*runtime):nullptr;}
        catch(const std::bad_alloc&){return nullptr;}
    }();
    return pinned;
}
int32_t verify(uint64_t identity){
    if(foreign())return AMCL_SOURCE_NOT_READY;
    const AmclInputHostApiV1* actual=nullptr;
    return identity&&amclInputHostDescriptorResolveV1(&actual)==AMCL_INPUT_HOST_DESCRIPTOR_OK&&
        actual==amclInputGetHostApiV1()&&identity==reinterpret_cast<uintptr_t>(actual)
        ? AMCL_SOURCE_ACCEPTED_NO_EDGE:AMCL_SOURCE_NOT_READY;
}
bool valid(const AmclSourceOutputV1& value){
    return (value.kind==0&&LegacyKeyCodeValid(value.code))||
        (value.kind==1&&LegacyMouseButtonValid(value.code));
}
Output output(const AmclSourceOutputV1& value){return {value.kind?OutputKind::Mouse:OutputKind::Key,value.code};}
bool nativeOwner(const State& s,uint64_t owner){
    // 固定 WASD 五位只授予 Entry 的 Native 解释器；普通 token 域与兼容/SourceControl 不重叠。
    return (owner>=0x300000001ULL&&owner<=0x300000005ULL)||
        (owner>=kNativeFirst&&owner<s.nextNative);
}
int32_t open(uint32_t role,uint64_t* handle){
    if(handle)*handle=0;if(foreign()||!handle||role<1||role>2)return AMCL_SOURCE_REJECTED;
    if(verify(reinterpret_cast<uintptr_t>(amclInputGetHostApiV1()))<0)return AMCL_SOURCE_NOT_READY;
    auto* storage=state();if(!storage)return AMCL_SOURCE_NOT_READY;auto& s=*storage;
    std::unique_lock<std::recursive_mutex> lock(s.runtime.TransactionMutex());
    if(!s.producers[role])s.producers[role]=s.runtime.NextOwner();
    if(!s.producers[role])return AMCL_SOURCE_PRESSURE;
    preparedRoles[role].store(s.producers[role],std::memory_order_release);*handle=s.producers[role];return 0;
}
int32_t prepared(uint32_t role,uint64_t* handle){
    if(handle)*handle=0;if(foreign()||!handle||role<1||role>2)return AMCL_SOURCE_REJECTED;
    *handle=preparedRoles[role].load(std::memory_order_acquire);
    return *handle?AMCL_SOURCE_ACCEPTED_NO_EDGE:AMCL_SOURCE_NOT_READY;
}
uint32_t roleFor(const State& s,uint64_t producer){
    for(uint32_t role=1;role<=2;++role)if(producer&&producer==s.producers[role])return role;return 0;
}
bool hasPreparedHandle(uint64_t producer){
    return producer&&(preparedRoles[1].load(std::memory_order_acquire)==producer||
        preparedRoles[2].load(std::memory_order_acquire)==producer);
}
// 预留后的 key/button 出口仅执行 C 值复制与单调 order；桥已禁止批内通知，不能分配
// 或执行用户 callback。显式 noexcept 防止以后把可抛工作误塞在正式 swap 之后。
void publish(const Edge& edge,const AmclSourceRequestV1& request) noexcept {
    const bool original=request.operation==AMCL_SOURCE_ANONYMOUS&&request.source==0&&request.count==1&&
        edge.output.kind==output(request.outputs[0]).kind&&edge.output.code==request.outputs[0].code;
    if(edge.output.kind==OutputKind::Key)inputBridge_pushKeyScopedV1(edge.output.code,
        original?request.scancode:0,edge.action,original?request.mods:0,edge.keyboardScope);
    else inputBridge_pushEvent(1006,edge.output.code,edge.action,original?request.mods:0,0);
}
int32_t transact(uint64_t producer,const AmclSourceRequestV1* request,AmclSourceResultV1* result){
    if(result){std::memset(result,0,sizeof(*result));result->size=sizeof(*result);result->status=AMCL_SOURCE_REJECTED;result->routedCode=-1;}
    if(foreign()||!request||!result||request->size!=sizeof(*request)||request->count>6||
        request->flags&~AMCL_SOURCE_ALLOW_RETIRE)return AMCL_SOURCE_REJECTED;
    if(!hasPreparedHandle(producer))return AMCL_SOURCE_REJECTED;
    // prepared句柄仅由open在完整Core握手后发出，且属于本进程pin的唯一owner。
    // 不把初始化运输的文件锁/maps扫描搬进每次输入；以下真实Core资源、scope、reset
    // 及最终提交围栏仍逐次核验。描述符Clear仅影响后来的握手，不撤销已借出的函数表。
    const bool creates=(request->operation==AMCL_SOURCE_ACQUIRE)||(request->operation==AMCL_SOURCE_OWNED_TEXT_TAP)||
        ((request->operation==AMCL_SOURCE_ANONYMOUS||request->operation==AMCL_SOURCE_OWNED_EDGE||request->operation==AMCL_SOURCE_OWNED_GROUP||request->operation==AMCL_SOURCE_PHYSICAL)&&request->action!=0);
    // 准入先捕原资源，再取Source/order锁。普通key贡献也不能因Mouse先建而获得Keyboard资格。
    const bool l2=amclInputOwnerSelectedKeyboardBackendV1()==2u;
    const uint64_t originalKeyboardScope=request->operation==AMCL_SOURCE_OWNED_TEXT_TAP
        ?request->keyboardScope:amclInputOwnerL2KeyboardScopeV1();
    bool createsKey=false;
    if(creates)for(uint32_t i=0;i<request->count;++i)createsKey|=request->outputs[i].kind==0u;
    if(l2&&createsKey&&(!originalKeyboardScope||originalKeyboardScope!=amclInputOwnerL2KeyboardScopeV1()))
        return result->status=AMCL_SOURCE_NOT_READY;
    AmclInputLookCoreResourceV1 admitted{};
    // 新贡献/重复必须有真实 Core surface/focus，cohold 的零边沿不等于无资源准入。
    // 冷 open/issue 和原 token terminal 不要求活 surface；这次读取仍在 Source 锁之前。
    if(creates&&(!amclInputOwnerReadLookResourceV1(&admitted)||!admitted.active))return result->status=AMCL_SOURCE_NOT_READY;
    // 私有文字scope从唯一Core捕获，必须在Source锁之前；不能反链Entry或拼global current。
    AmclInputTextCoreResourceV1 textResource{};
    if(request->operation==AMCL_SOURCE_OWNED_TEXT_TAP&&
       (!amclInputOwnerReadTextResourceV1(&textResource)||textResource.textSession!=request->owner||textResource.scope!=request->textScope))
        return result->status=AMCL_SOURCE_NOT_READY;
    auto* storage=state();if(!storage)return result->status=AMCL_SOURCE_NOT_READY;auto& s=*storage;
    std::unique_lock<std::recursive_mutex> lock(s.runtime.TransactionMutex());
    const uint32_t role=roleFor(s,producer);if(!role)return AMCL_SOURCE_REJECTED;
    if(role==AMCL_SOURCE_JAVA_COMPAT&&(request->operation!=AMCL_SOURCE_ANONYMOUS||request->source!=0||request->count!=1))return AMCL_SOURCE_REJECTED;
    for(uint32_t i=0;i<request->count;++i)if(!valid(request->outputs[i]))return AMCL_SOURCE_REJECTED;
    if(request->source<0||request->source>=AMCL_INPUT_SOURCE_COUNT)return AMCL_SOURCE_REJECTED;
    if(s.resetting&&creates)return result->status=AMCL_SOURCE_NOT_READY;
    if(request->operation==AMCL_SOURCE_ISSUE_NATIVE){
        if(role!=AMCL_SOURCE_ENTRY||s.nextNative==kNativeLimit)return AMCL_SOURCE_REJECTED;
        result->owner=s.nextNative++;result->accepted=result->transportAccepted=1;return result->status=0;
    }
    if(request->operation==AMCL_SOURCE_RESET_END){s.resetting=false;result->accepted=result->transportAccepted=1;return result->status=0;}
    if(request->operation==AMCL_SOURCE_FLUSH_TERMINALS&&s.deferred.empty()){
        result->accepted=result->transportAccepted=1;return result->status=0;
    }
    // 摇杆每次MOVE会报告疾跑的期望状态。已有同owner/code的DOWN或不存在持有的UP
    // 是幂等读：在身份、Core准入、reset和参数校验以后直接确认，避免复制整份来源
    // 账本、争用运输锁及通知消费者。这里只处理单码owned边沿；真实变化、REPEAT、
    // 多码组及待补发terminal仍走原候选事务，不能把共持数量变化误当成无操作。
    if(request->operation==AMCL_SOURCE_OWNED_EDGE&&role==AMCL_SOURCE_ENTRY&&
       nativeOwner(s,request->owner)&&request->count==1&&
       (request->action==0||request->action==1)&&s.deferred.empty()&&
       s.runtime.Ledger().owns(request->owner,output(request->outputs[0]))==(request->action==1)){
        if(l2&&createsKey&&amclInputOwnerL2KeyboardScopeV1()!=originalKeyboardScope)
            return result->status=AMCL_SOURCE_NOT_READY;
        result->accepted=result->transportAccepted=1;
        result->sourceRetired=request->action==0?1u:0u;
        return result->status=AMCL_SOURCE_ACCEPTED_NO_EDGE;
    }
    try {
        std::vector<Edge> edges;
        LegacyOutputRuntime candidate([&](const Output& value,int action){edges.push_back({value,action,l2?originalKeyboardScope:0});});
        candidate.CopyStateFrom(s.runtime);
        auto nativeGroups=s.nativeGroups;
        uint64_t token=0;bool applied=true,retired=false;int physicalOutcome=0;
        switch(request->operation){
        case AMCL_SOURCE_ACQUIRE: {
            if((request->source!=1&&request->source!=2&&request->source!=4)||!request->count||!request->control[0]||!std::memchr(request->control,0,sizeof(request->control)))return AMCL_SOURCE_REJECTED;
            std::vector<Output> values;for(uint32_t i=0;i<request->count;++i){const Output value=output(request->outputs[i]);
                bool duplicate=false;for(const auto& prior:values)duplicate|=prior.kind==value.kind&&prior.code==value.code;
                if(!duplicate)values.push_back(value);}
            token=candidate.External().AcquireControl({static_cast<AmclInputSource>(request->source),request->device,request->control},values,s.runtime.NextOwner());
            applied=token!=0;break;
        }
        case AMCL_SOURCE_RELEASE:
            // SourceControl 原冻结 token 释放；不接受 Native 专用 owner 域。
            if(request->owner<0x400000000ULL||request->owner>=kNativeFirst)return AMCL_SOURCE_REJECTED;
            applied=candidate.ReleaseControl(request->owner);retired=applied;break;
        case AMCL_SOURCE_ANONYMOUS: {
            if(request->count!=1||request->action<0||request->action>2||(request->outputs[0].kind&&request->action==2))return AMCL_SOURCE_REJECTED;
            const auto source=static_cast<AmclInputSource>(request->source);const Output value=output(request->outputs[0]);
            // 公共 Java 没有 device/contact 身份；source0 每输出只有一份匿名兼容持有。
            // 重复 DOWN 幂等，JNI 和 NAPI 不能互相累积两个无法配对的兼容 owner。
            if(request->source==0&&request->action==1&&candidate.Registry().PeekSameSource(value,source))break;
            const auto action=request->action==1?ExternalHeldAction::Press:request->action==2?ExternalHeldAction::Repeat:ExternalHeldAction::Release;
            applied=ExternalHeldEdgeApplied(candidate.External().Route(source,value,action,
                request->action==1?s.runtime.NextOwner():0));retired=applied&&request->action==0;break;
        }
        case AMCL_SOURCE_OWNED_TEXT_TAP: {
            // 原会话独立owned临时贡献，不认领/撤销Touch匿名桶；同码兄弟保持首按末松。
            // owner只在整candidate及运输成功后消耗，压力/旧scope不留下假owner或半DOWN。
            if(role!=AMCL_SOURCE_ENTRY||request->count!=1||request->outputs[0].kind!=0||s.nextNative==kNativeLimit)
                return AMCL_SOURCE_REJECTED;
            const int key=request->outputs[0].code;
            if(key!=259&&key!=261&&key!=257&&key!=335&&key!=256)return AMCL_SOURCE_REJECTED;
            token=s.nextNative;const Output value=output(request->outputs[0]);
            applied=candidate.Ledger().acquireTransition(token,value)!=LedgerTransitionResult::Rejected;
            if(applied)(void)candidate.Ledger().releaseTransition(token,value);
            break;
        }
        case AMCL_SOURCE_OWNED_GROUP:
        case AMCL_SOURCE_OWNED_EDGE: {
            if(role!=AMCL_SOURCE_ENTRY||!nativeOwner(s,request->owner)||!request->count||request->action<0||request->action>2)return AMCL_SOURCE_REJECTED;
            if(request->operation==AMCL_SOURCE_OWNED_GROUP){
                auto found=nativeGroups.find(request->owner);
                if(request->action==0){
                    if(found!=nativeGroups.end()){const auto frozen=found->second;nativeGroups.erase(found);
                        for(auto it=frozen.rbegin();it!=frozen.rend();++it)(void)candidate.Ledger().releaseTransition(request->owner,*it);}
                    retired=true;break;
                }
                std::vector<Output> values;for(uint32_t i=0;i<request->count;++i){const auto value=output(request->outputs[i]);
                    bool duplicate=false;for(const auto& prior:values)duplicate|=prior.kind==value.kind&&prior.code==value.code;
                    if(!duplicate)values.push_back(value);}
                if(found!=nativeGroups.end()){
                    if(found->second.size()!=values.size())return AMCL_SOURCE_REJECTED;
                    for(size_t i=0;i<values.size();++i)if(found->second[i].kind!=values[i].kind||found->second[i].code!=values[i].code)return AMCL_SOURCE_REJECTED;
                }else nativeGroups.emplace(request->owner,std::move(values));
            }
            for(uint32_t i=0;i<request->count;++i){const auto value=output(request->outputs[i]);
                if(request->action==1){if(!candidate.Ledger().owns(request->owner,value))applied&=candidate.Ledger().acquireTransition(request->owner,value)!=LedgerTransitionResult::Rejected;}
                else if(request->action==2)applied&=candidate.Ledger().repeatTransition(request->owner,value)!=LedgerTransitionResult::Rejected;
                else {if(candidate.Ledger().owns(request->owner,value))(void)candidate.Ledger().releaseTransition(request->owner,value);retired=true;}}
            break;
        }
        case AMCL_SOURCE_RELEASE_OWNER:
            if(role!=AMCL_SOURCE_ENTRY||!nativeOwner(s,request->owner))return AMCL_SOURCE_REJECTED;
            {auto found=nativeGroups.find(request->owner);if(found!=nativeGroups.end()){
                const auto frozen=found->second;nativeGroups.erase(found);
                for(auto it=frozen.rbegin();it!=frozen.rend();++it)(void)candidate.Ledger().releaseTransition(request->owner,*it);}
            candidate.Ledger().releaseOwner(request->owner);retired=true;break;}
        case AMCL_SOURCE_CANCEL_SOURCE:
            candidate.ReleaseSource(static_cast<AmclInputSource>(request->source));retired=true;break;
        case AMCL_SOURCE_PHYSICAL: {
            if(role!=AMCL_SOURCE_ENTRY||request->count>1||request->source>1||request->action<0||request->action>2)return AMCL_SOURCE_REJECTED;
            const Output mapped=request->count?output(request->outputs[0]):Output{OutputKind::Key,0};
            const LegacyPhysicalIdentity identity{static_cast<OutputKind>(request->source),request->device,request->rawControl};
            const auto action=request->action==1?LegacyPhysicalAction::Down:request->action==2?LegacyPhysicalAction::Repeat:LegacyPhysicalAction::Up;
            physicalOutcome=candidate.Physical().Route(request->bridgeAvailable!=0,identity,request->count?&mapped:nullptr,
                action,request->action==1?s.runtime.NextOwner():0,&result->routedCode);
            applied=physicalOutcome==AMCL_LEGACY_PHYSICAL_EMITTED||physicalOutcome==AMCL_LEGACY_PHYSICAL_HANDLED_NO_FINAL_EDGE;
            retired=applied&&request->action==0;break;
        }
        case AMCL_SOURCE_RESET_BEGIN:
        case AMCL_SOURCE_CANCEL_ALL:
            candidate.Physical().Reset();candidate.Registry().Clear();candidate.Ledger().releaseAll();nativeGroups.clear();retired=true;break;
        case AMCL_SOURCE_CLEAR_EXTERNAL:
            // 旧 reset 分步入口现在由 RESET_BEGIN 整批完成；不得单独先摘 registry 留半账。
            if(!s.resetting)return AMCL_SOURCE_REJECTED;break;
        case AMCL_SOURCE_FLUSH_TERMINALS:break;
        default:return AMCL_SOURCE_REJECTED;
        }
        result->physicalOutcome=physicalOutcome;if(!applied)return AMCL_SOURCE_REJECTED;
        // 先复制恢复集合；这里任何分配失败都发生在实际 source/look/ring 变更之前。
        auto pending=s.deferred;
        uint64_t retiredKeyTerminals=0;
        // 旧末松永久携原Keyboard身份。失权后只精确撤该key终端，不能补新current送到新资源。
        // Mouse及其它后端的终端寿命不变；该丢弃不是consumer实际UP完成。
        for(auto it=pending.begin();it!=pending.end();){
            if(l2&&it->first.kind==OutputKind::Key&&(!it->second.keyboardScope||it->second.keyboardScope!=amclInputOwnerL2KeyboardScopeV1())){
                ++retiredKeyTerminals;it=pending.erase(it);
            }
            else ++it;
        }
        for(auto it=pending.begin();it!=pending.end();){if(candidate.Ledger().isHeld(it->first))it=pending.erase(it);else ++it;}
        std::vector<Edge> batch;batch.reserve(pending.size()+edges.size());
        for(const auto& item:pending)batch.push_back(item.second);
        for(const auto& edge:edges){
            // 旧deferred UP只可吸收其后尚未出现新DOWN的同码UP。owned tap是
            // DOWN→UP整对：一旦新DOWN进入本批，末UP属于新脉冲，不能借旧UP去重。
            // batch已保留旧UP；摘的是本地去重资格，不改变运输前的原deferred集合。
            // 因而真实预算是旧UP+新DOWN+新UP三槽，压力拒绝仍不提交任何新DOWN。
            if(edge.action==1)pending.erase(edge.output);
            if(edge.action==0&&pending.count(edge.output))continue;
            batch.push_back(edge);
        }
        // deferred 集合只存仍为 UP 的 terminal，键空间固定，不能积成无限事件历史。
        for(const auto& edge:edges)if(edge.action==0)pending[edge.output]=edge;
        const bool transported=inputBridge_beginSourceActionV1(static_cast<uint32_t>(batch.size()))!=0;
        if(!transported&&!(retired&&(request->flags&AMCL_SOURCE_ALLOW_RETIRE)))return result->status=AMCL_SOURCE_PRESSURE;
        // 正常与异常退出都结束真实 fence，且 End/notify 之前先放 Source 锁。当前 swap
        // 和 publish 已证明不分配/不失败；此 guard 同时防止后续维护遗漏配对导致永久锁住。
        struct FinishBatch {
            std::unique_lock<std::recursive_mutex>& sourceLock;bool active;
            ~FinishBatch(){if(active){if(sourceLock.owns_lock())sourceLock.unlock();inputBridge_endLookActionV1();}}
            void finish(){if(active){active=false;if(sourceLock.owns_lock())sourceLock.unlock();inputBridge_endLookActionV1();}}
        } finish{lock,transported};
        // Source已经持原order/push，但这里只原子核Core发布围栏，绝不回取Core mutex。
        // 合法end/RESET/后端最后退休先封scope；Notify回入只在整批提交且全部锁释放后发生。
        if(request->operation==AMCL_SOURCE_OWNED_TEXT_TAP&&
           !amclInputOwnerValidateTextScopeV1(textResource.scope))return result->status=AMCL_SOURCE_NOT_READY;
        // Source候选/运输最终提交再核同原keygen，等待期间create/destroy不能替它换标签。
        if(l2&&createsKey&&amclInputOwnerL2KeyboardScopeV1()!=originalKeyboardScope)return result->status=AMCL_SOURCE_NOT_READY;
        s.runtime.SwapState(candidate);
        // 只在候选实际提交后记资源退休原因，压力拒绝不得伪报已丢弃终端；计数饱和非身份。
        s.retiredKeyTerminals=UINT64_MAX-s.retiredKeyTerminals<retiredKeyTerminals?UINT64_MAX:s.retiredKeyTerminals+retiredKeyTerminals;
        s.nativeGroups.swap(nativeGroups);
        if(request->operation==AMCL_SOURCE_OWNED_TEXT_TAP)++s.nextNative;
        if(request->operation==AMCL_SOURCE_RESET_BEGIN)s.resetting=true;
        result->accepted=1;result->sourceRetired=retired?1u:0u;result->owner=token;
        result->finalEdges=static_cast<uint32_t>(edges.size());result->transportAccepted=transported?1u:0u;
        if(transported){
            s.deferred.clear();terminalPending.store(0,std::memory_order_release);for(const auto& edge:batch)publish(edge,*request);
            result->deferredEdges=0;result->status=batch.empty()?0:1;
            // 全批 slot 已写、source 已提交。先释放 source 锁，再释放 order→push 并通知；
            // 任何 SDK/game callback 或同步通知回入都看见完整新状态，且不持 source mutex。
            finish.finish();return result->status;
        }
        s.deferred.swap(pending);result->deferredEdges=static_cast<uint32_t>(s.deferred.size());
        terminalPending.store(result->deferredEdges,std::memory_order_release);
        return result->status=AMCL_SOURCE_RETIRED_DEFERRED;
    }catch(const std::bad_alloc&){return result->status=AMCL_SOURCE_PRESSURE;}
}
int32_t query(uint64_t producer,uint64_t owner,const AmclSourceOutputV1* value,AmclSourceSnapshotV1* snapshot){
    if(snapshot)std::memset(snapshot,0,sizeof(*snapshot));if(foreign()||!snapshot)return AMCL_SOURCE_NOT_READY;
    if(!hasPreparedHandle(producer))return AMCL_SOURCE_NOT_READY;
    auto* storage=state();if(!storage)return AMCL_SOURCE_NOT_READY;auto& s=*storage;
    std::lock_guard<std::recursive_mutex> lock(s.runtime.TransactionMutex());if(!roleFor(s,producer))return AMCL_SOURCE_REJECTED;
    snapshot->size=sizeof(*snapshot);snapshot->resetting=s.resetting; snapshot->owners=static_cast<uint32_t>(s.runtime.Ledger().ownerCount());
    snapshot->outputs=static_cast<uint32_t>(s.runtime.Ledger().outputCount());snapshot->physical=static_cast<uint32_t>(s.runtime.Physical().HeldIdentityCount());
    snapshot->maxSameSource=static_cast<uint32_t>(s.runtime.Registry().MaxRecordsForSameSource());snapshot->deferredEdges=static_cast<uint32_t>(s.deferred.size());
    if(value&&valid(*value))snapshot->owns=owner?s.runtime.Ledger().owns(owner,output(*value)):s.runtime.Ledger().isHeld(output(*value));
    for(int i=0;i<AMCL_INPUT_SOURCE_COUNT;++i){const auto source=static_cast<AmclInputSource>(i);snapshot->held[i]=static_cast<uint32_t>(s.runtime.Registry().LiveCountForSource(source));
        snapshot->acquired[i]=s.runtime.Registry().AcquiredForSource(source);snapshot->released[i]=s.runtime.Registry().ReleasedForSource(source);}
    return 0;
}
/** 尾方法就是明示的owned键能力；资格和真实receiver仍由transact逐次准入，不能当Ready。 */
int32_t ownedTextKeyTap(uint64_t producer,uint64_t textSession,uint64_t textScope,int32_t key,AmclSourceResultV1* result) {
    // 旧72尾从未接受原Keyboard资格；L2必须走新尾，不能对迟到调用补current。
    if(amclInputOwnerSelectedKeyboardBackendV1()==2u){
        if(result){std::memset(result,0,sizeof(*result));result->size=sizeof(*result);result->status=AMCL_SOURCE_NOT_READY;}
        return AMCL_SOURCE_NOT_READY;
    }
    AmclSourceRequestV1 request{};request.size=sizeof(request);request.operation=AMCL_SOURCE_OWNED_TEXT_TAP;
    request.source=AMCL_INPUT_SOURCE_TOUCH_CONTROLS;request.owner=textSession;request.textScope=textScope;
    request.count=1;request.outputs[0]={0u,key};return transact(producer,&request,result);
}
int32_t ownedTextKeyTapForKeyboard(uint64_t producer,uint64_t textSession,uint64_t textScope,uint64_t keyboardScope,int32_t key,AmclSourceResultV1* result){
    AmclSourceRequestV1 request{};request.size=sizeof(request);request.operation=AMCL_SOURCE_OWNED_TEXT_TAP;
    request.source=AMCL_INPUT_SOURCE_TOUCH_CONTROLS;request.owner=textSession;request.textScope=textScope;
    request.keyboardScope=keyboardScope;request.count=1;request.outputs[0]={0u,key};return transact(producer,&request,result);
}
}
extern "C" uint64_t amclSourceControlRetiredKeyTerminalsV1(){
    if(foreign())return 0;auto* storage=state();if(!storage)return 0;auto& s=*storage;
    std::lock_guard<std::recursive_mutex> lock(s.runtime.TransactionMutex());return s.retiredKeyTerminals;
}
extern "C" const AmclSourceControlPortV1* amclSourceControlGetPortV1(){
    if(foreign())return nullptr;
    static const AmclSourceControlPortV1 port={AMCL_SOURCE_CONTROL_MAGIC,1,sizeof(AmclSourceControlPortV1),sourceProcess,
        reinterpret_cast<uintptr_t>(amclInputGetHostApiV1()),verify,open,prepared,transact,query,ownedTextKeyTap,ownedTextKeyTapForKeyboard};
    return &port;
}
extern "C" void amclSourceControlPublishV1(){
    if(foreign())return;static std::atomic<bool> published{false};if(published.load(std::memory_order_acquire))return;
    if(amclInputHostDescriptorPublishV1(amclInputGetHostApiV1())<0)return;
    char text[96]{};std::snprintf(text,sizeof(text),AMCL_SOURCE_CONTROL_PREFIX "%u:%llu",sourceProcess,
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&amclSourceControlGetPortV1)));
#ifdef _WIN32
    const int code=_putenv_s(AMCL_SOURCE_CONTROL_ENV,text);
#else
    const int code=setenv(AMCL_SOURCE_CONTROL_ENV,text,1);
#endif
    if(code==0)published.store(true,std::memory_order_release);
}
extern "C" int amclSourceControlPrepareV1(){
    if(foreign())return 0;
    const AmclSourceControlPortV1* port=nullptr;uint64_t producer=0;
    if(amclSourceControlResolveV1(&port)<0||port->openProducer(AMCL_SOURCE_ENTRY,&producer)<0||!producer)return 0;
    // Base 冷资格一次准备两种固定生产职责，JNI 第一个动作只借 handle，不再首次创建服务。
    return port->openProducer(AMCL_SOURCE_JAVA_COMPAT,&producer)>=0&&producer?1:0;
}
extern "C" int amclSourceControlCompatEdgeV1(uint32_t kind,int32_t code,int32_t scan,int32_t action,int32_t mods){
    if(foreign())return 0;
    // JNI可能经另一namespace的桥进入；复用冷握手得到的真正owner，不能改用本地副本。
    const AmclSourceControlPortV1* port=nullptr;uint64_t producer=0;
    if(!amcl::input::BorrowSourceConnection(AMCL_SOURCE_JAVA_COMPAT,&port,&producer))return 0;
    AmclSourceRequestV1 request{};request.size=sizeof(request);request.operation=AMCL_SOURCE_ANONYMOUS;
    request.count=1;request.action=action;request.scancode=scan;request.mods=mods;request.outputs[0]={kind,code};
    if(action==0)request.flags=AMCL_SOURCE_ALLOW_RETIRE;
    AmclSourceResultV1 result{};return port->transact(producer,&request,&result)>=0&&result.accepted?1:0;
}
extern "C" int amclSourceControlDrainTerminalsV1(){
    if(foreign())return 0;if(!terminalPending.load(std::memory_order_acquire))return 1;
    // 恢复原末松也沿已验证的来源连接，不在队列压力期间重复进入跨映像发现流程。
    const AmclSourceControlPortV1* port=nullptr;uint64_t producer=0;
    if(!amcl::input::BorrowSourceConnection(AMCL_SOURCE_ENTRY,&port,&producer))return 0;
    AmclSourceRequestV1 request{};request.size=sizeof(request);request.operation=AMCL_SOURCE_FLUSH_TERMINALS;
    AmclSourceResultV1 result{};return port->transact(producer,&request,&result)>=0&&result.transportAccepted?1:0;
}
