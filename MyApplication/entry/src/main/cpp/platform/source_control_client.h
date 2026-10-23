/** 平台解释器的值适配：保留既有 Output/owner 调用语义，却不借 neutral 的锁、容器或
 * C++ router 对象。每个方法只构造 POD 请求并核同 Core 的已发布 source 端口。
 * 平台递归锁仍用于 schema/finger/menu 状态；跨生产者事务锁只在 neutral 实现内部。
 * 所有 Getter 都复制值快照，desired held 与 consumer 实际输出不能混为一层。 */
#ifndef AMCL_PLATFORM_SOURCE_CONTROL_CLIENT_H
#define AMCL_PLATFORM_SOURCE_CONTROL_CLIENT_H
#include "../input/source/source_control_client.h"
#include "../input/delivery/l2_keyboard_scope.h"
#include "legacy_physical_edge_router.h"
#include "external_held_edge_router.h"
#include <cstring>
#include <algorithm>
namespace amcl::input {
inline AmclSourceOutputV1 SourceOutput(const Output& value){return {value.kind==OutputKind::Key?0u:1u,value.code};}
inline bool SourcePort(const AmclSourceControlPortV1** port,uint64_t* producer){
    return BorrowSourceConnection(AMCL_SOURCE_ENTRY,port,producer);
}
inline AmclSourceResultV1 SourceTransaction(AmclSourceRequestV1 request){
    // 连接资格与一次输入的资源资格分别处理；首次SourcePort严格核Core/映像，热路径
    // 借原prepared句柄。transact仍核PID、生产者、焦点/Surface、文字scope和运输预算。
    request.size=sizeof(request);AmclSourceResultV1 result{};result.status=AMCL_SOURCE_NOT_READY;
    const AmclSourceControlPortV1* port=nullptr;uint64_t producer=0;
    if(SourcePort(&port,&producer))(void)port->transact(producer,&request,&result);return result;
}
inline AmclSourceSnapshotV1 SourceSnapshot(OwnerToken owner=0,const Output* value=nullptr){
    const AmclSourceControlPortV1* port=nullptr;uint64_t producer=0;AmclSourceSnapshotV1 snapshot{};
    const AmclSourceOutputV1 encoded=value?SourceOutput(*value):AmclSourceOutputV1{};
    if(SourcePort(&port,&producer))(void)port->query(producer,owner,value?&encoded:nullptr,&snapshot);return snapshot;
}
/** owned文字能力独立于物理路由。只借已prepared原Source，空/旧scope/压力准确拒绝；
 * 不 fallback匿名按键、不分两笔、不把整pair入运输当consumer完成。 */
inline bool SourceOwnedTextKeyTap(const AmclInputTextCoreResourceV1& original,int32_t key,uint64_t originalKeyboardScope=0) {
    const AmclSourceControlPortV1* port=nullptr;uint64_t producer=0;AmclSourceResultV1 result{};
    if(!original.active||!original.textSession||!original.scope||!SourcePort(&port,&producer))return false;
    // 新尾把调用前冻结的键资源交给唯一Source；不会在可能等待的prepare之后补current。
    (void)port->ownedTextKeyTapForKeyboard(producer,original.textSession,original.scope,originalKeyboardScope,key,&result);
    // 外部Notify可在整批已提交后异常；admission字段是原提交事实，不能把后置错误改成
    // 未接受而授权重发。这里仍不宣称callback/queue/cache完成，未提交时这两位保持0。
    return result.size==sizeof(result)&&result.accepted&&result.transportAccepted;
}
inline OwnerToken SourceNextNativeOwner(){AmclSourceRequestV1 request{};request.operation=AMCL_SOURCE_ISSUE_NATIVE;return SourceTransaction(request).owner;}
inline bool SourceOwnedGroup(OwnerToken owner,const Output* values,uint32_t count,int action){
    if(!values||!count||count>6)return false;AmclSourceRequestV1 request{};request.operation=AMCL_SOURCE_OWNED_GROUP;
    request.source=AMCL_INPUT_SOURCE_TOUCH_CONTROLS;request.owner=owner;request.count=count;request.action=action;
    // 终端必须收原 owner。无运输时明确排 terminal 待恢复，不能按当前 schema 重算旧输出。
    if(action==0)request.flags=AMCL_SOURCE_ALLOW_RETIRE;
    for(uint32_t i=0;i<count;++i)request.outputs[i]=SourceOutput(values[i]);
    const auto result=SourceTransaction(request);return result.accepted!=0;
}
inline OwnerToken SourceAcquireControl(const ExternalControlIdentity& identity,const std::vector<Output>& values){
    if(values.empty()||values.size()>6||identity.control.empty()||identity.control.size()>512)return 0;
    AmclSourceRequestV1 request{};request.operation=AMCL_SOURCE_ACQUIRE;request.source=identity.source;
    request.device=identity.device;request.count=static_cast<uint32_t>(values.size());
    std::memcpy(request.control,identity.control.c_str(),identity.control.size()+1);
    for(uint32_t i=0;i<request.count;++i)request.outputs[i]=SourceOutput(values[i]);
    const auto result=SourceTransaction(request);return result.accepted?result.owner:0;
}
inline bool SourceReleaseControl(OwnerToken owner){AmclSourceRequestV1 request{};request.operation=AMCL_SOURCE_RELEASE;
    request.owner=owner;const auto result=SourceTransaction(request);return result.accepted!=0;}
inline size_t SourceReleaseSource(AmclInputSource source){AmclSourceRequestV1 request{};request.operation=AMCL_SOURCE_CANCEL_SOURCE;
    request.source=source;request.flags=AMCL_SOURCE_ALLOW_RETIRE;const auto before=SourceSnapshot();const auto result=SourceTransaction(request);
    return result.accepted?before.held[source]:0;}
class SourceLedgerProxy final {
    bool edge(OwnerToken owner,const Output& value,int action){AmclSourceRequestV1 request{};request.operation=AMCL_SOURCE_OWNED_EDGE;
        request.source=AMCL_INPUT_SOURCE_TOUCH_CONTROLS;request.owner=owner;request.action=action;request.count=1;request.outputs[0]=SourceOutput(value);
        if(action==0)request.flags=AMCL_SOURCE_ALLOW_RETIRE;return SourceTransaction(request).accepted!=0;}
public:
    bool acquire(OwnerToken owner,const Output& value){return edge(owner,value,1);}
    bool repeat(OwnerToken owner,const Output& value){return edge(owner,value,2);}
    bool release(OwnerToken owner,const Output& value){return edge(owner,value,0);}
    void releaseOwner(OwnerToken owner){AmclSourceRequestV1 request{};request.operation=AMCL_SOURCE_RELEASE_OWNER;
        request.owner=owner;request.flags=AMCL_SOURCE_ALLOW_RETIRE;(void)SourceTransaction(request);}
    void releaseAll(){AmclSourceRequestV1 request{};request.operation=AMCL_SOURCE_CANCEL_ALL;
        request.flags=AMCL_SOURCE_ALLOW_RETIRE;(void)SourceTransaction(request);}
    bool owns(OwnerToken owner,const Output& value)const{return SourceSnapshot(owner,&value).owns!=0;}
    bool isHeld(const Output& value)const{return SourceSnapshot(0,&value).owns!=0;}
    size_t ownerCount()const{return SourceSnapshot().owners;}
    size_t outputCount()const{return SourceSnapshot().outputs;}
};
class SourceRegistryProxy final {
public:
    void Clear(){AmclSourceRequestV1 request{};request.operation=AMCL_SOURCE_CLEAR_EXTERNAL;(void)SourceTransaction(request);}
    size_t MaxRecordsForSameSource()const{return SourceSnapshot().maxSameSource;}
    size_t LiveCountForSource(AmclInputSource source)const{return SourceSnapshot().held[source];}
    uint32_t AcquiredForSource(AmclInputSource source)const{return SourceSnapshot().acquired[source];}
    uint32_t ReleasedForSource(AmclInputSource source)const{return SourceSnapshot().released[source];}
};
class SourceExternalProxy final {
public:
    ExternalHeldEdgeResult Route(AmclInputSource source,const Output& value,ExternalHeldAction action,OwnerToken){
        AmclSourceRequestV1 request{};request.operation=AMCL_SOURCE_ANONYMOUS;request.source=source;request.count=1;
        request.outputs[0]=SourceOutput(value);request.action=action==ExternalHeldAction::Press?1:action==ExternalHeldAction::Repeat?2:0;
        const auto result=SourceTransaction(request);return !result.accepted?ExternalHeldEdgeResult::Rejected:
            result.finalEdges?ExternalHeldEdgeResult::AppliedEmitted:ExternalHeldEdgeResult::AppliedNoFinalEdge;
    }
};
class SourcePhysicalProxy final {
public:
    AmclLegacyPhysicalOutcome Route(bool ready,const LegacyPhysicalIdentity& identity,const Output* mapped,
            LegacyPhysicalAction action,OwnerToken,int* routed=nullptr){
        if(routed)*routed=-1;AmclSourceRequestV1 request{};request.operation=AMCL_SOURCE_PHYSICAL;
        request.source=identity.kind==OutputKind::Key?0:1;request.device=identity.deviceId;request.rawControl=identity.rawControl;
        request.bridgeAvailable=ready;request.count=mapped?1u:0u;if(mapped)request.outputs[0]=SourceOutput(*mapped);
        request.action=action==LegacyPhysicalAction::Down?1:action==LegacyPhysicalAction::Repeat?2:0;
        const auto result=SourceTransaction(request);if(routed)*routed=result.routedCode;
        if(result.status<0)return result.physicalOutcome?static_cast<AmclLegacyPhysicalOutcome>(result.physicalOutcome):AMCL_LEGACY_PHYSICAL_ENQUEUE_FAILED;
        return static_cast<AmclLegacyPhysicalOutcome>(result.physicalOutcome);
    }
    template<class Work> void Reset(Work&& work){AmclSourceRequestV1 request{};request.operation=AMCL_SOURCE_RESET_BEGIN;
        request.flags=AMCL_SOURCE_ALLOW_RETIRE;const auto result=SourceTransaction(request);if(!result.accepted)return;
        // neutral 已先摘完整旧集合且升 reset 围栏；平台回调不持任何借出的 neutral mutex。
        // 同步回入的新 PRESS 被围栏拒绝，旧 token 的 terminal 仍能幂等清理。
        struct Finish {~Finish(){AmclSourceRequestV1 end{};end.operation=AMCL_SOURCE_RESET_END;(void)SourceTransaction(end);}} finish;
        work();
    }
    bool ResetInProgress()const{return SourceSnapshot().resetting!=0;}
    size_t HeldIdentityCount()const{return SourceSnapshot().physical;}
};
}
#endif
