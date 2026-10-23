// GLFW facade只保存neutral句柄和连接，不再保存或裁决来源持有；实际ABI回调在调用线程锁外执行。
#include "glfw_source_plane_aggregate.h"
#include <mutex>
#include <atomic>
#include "../delivery/control_delivery_client.h"
#include "../delivery/look_execution_client.h"
namespace amcl::input {
namespace {
uint32_t processId(){
#ifdef _WIN32
    return static_cast<uint32_t>(_getpid());
#else
    return static_cast<uint32_t>(getpid());
#endif
}
}
struct GlfwSourcePlaneAggregate::Impl {
    // port只指向已发布且经descriptor核验的neutral映像；consumer是该owner借出的opaque
    // handle。这里没有keys/buttons/owners表，不能变成第二个末级状态机。
    mutable const AmclControlDeliveryPortV1* port=nullptr;
    mutable std::atomic<const AmclLookExecutionPortV1*> look{nullptr};
    mutable std::mutex mutex;mutable uint64_t consumer=0;bool explicitTarget=false,targetRejected=false;
    const uint32_t process=processId();
    // mutex保护连接/句柄资格，不保护游戏cache。首次才解析端口，之后仅核handle仍活着；
    // fork先拒绝，target拒绝态在下一次明确BindTarget重试前不允许Submit越域交付。
    uint64_t ensure(uint64_t target=0,bool retryBinding=false) const {
        // neutral不支持fork继承，facade也必须先于自己可能继承的mutex拒绝child调用。
        if(process!=processId())return 0;
        std::lock_guard<std::mutex> lock(mutex);
        if(targetRejected&&!retryBinding)return 0;
        const uint32_t currentPid=processId();
        if(port&&port->pid!=currentPid){port=nullptr;consumer=0;}
#ifdef AMCL_CONTROL_DELIVERY_HOST_TESTING
        if(!port){(void)amclControlDeliveryGetPortV1();amclControlDeliveryPublishV1();}
#endif
        // 真正frontend必须取已发布owner，不用本image的本地getter代替跨namespace身份。
        if(!port&&amclControlDeliveryResolveV1(&port)<0)return 0;
        if(consumer){AmclControlSnapshotV1 current{};current.size=sizeof(current);
            if(port->snapshot(consumer,&current)==AMCL_CONTROL_STALE)consumer=0;}
        if(!consumer&&port->open(1,target,&consumer)<0)return 0;
        if(target&&!explicitTarget)(void)port->bindTarget(consumer,target);
        return consumer;
    }
};
namespace {
// 这里只转换来源职责枚举，键码/按钮码和first-down/last-up/repeat政策全部由neutral裁决。
uint32_t contribution(GlfwSourcePlane plane){return plane==GlfwSourcePlane::kLegacy?1u:plane==GlfwSourcePlane::kTyped?2u:0u;}
}
// 构造只建立本地连接对象，不抢先加载游戏class或声明consumerReady。
GlfwSourcePlaneAggregate::GlfwSourcePlaneAggregate():impl_(std::make_unique<Impl>()){}
// borrowed port映像由进程宿主持有；此处只close自身consumer，不卸载DSO。
GlfwSourcePlaneAggregate::~GlfwSourcePlaneAggregate(){if(impl_->port&&impl_->consumer)impl_->port->close(impl_->consumer);}
// 输入为实际GLFWwindow.windowId。同目标幂等；新目标被neutral拒绝时记录停发态，不能
// 忽略PRESSURE后在新窗口使用旧target receipt。0也不被当成一个虚构的新窗口。
void GlfwSourcePlaneAggregate::BindTarget(uint64_t target){const uint64_t handle=impl_->ensure(0,true);if(!handle)return;
    std::lock_guard<std::mutex> lock(impl_->mutex);impl_->explicitTarget=true;
    // 目标身份耗尽/拒绝时暂停本facade；不能忽略失败后把旧target ticket写进新window缓存。
    impl_->targetRejected=impl_->port->bindTarget(handle,target)<0;}
// 必须携原receipt报告真实cache/callback层级，不能在回调后重取currentconsumer来改绑旧事实。
void GlfwSourcePlaneAggregate::Complete(const AmclControlEmissionV1& receipt,uint32_t phase){
    if(receipt.ticket&&impl_->port)(void)impl_->port->complete(&receipt,phase);
}
// 缓存写入之前重核原票；false不进行ABI副作用，生产sink报告DISCARDED再结束该票。
bool GlfwSourcePlaneAggregate::Validate(const AmclControlEmissionV1& receipt)const{
    return receipt.ticket&&impl_->port&&impl_->port->validate(&receipt)==AMCL_CONTROL_EDGE;
}
// 输入已按GLFW编码的一份plane贡献。Rejected/NoEdge不输出，只有neutral Edge且claim
// 成功才在所有内部锁外调用sink。真实sink先报告cache，再在真正keyCb返回后报告callback；
// void sink早退必须先DISCARDED，不能让函数返回本身冒充cache写入。
void GlfwSourcePlaneAggregate::SubmitKey(GlfwSourcePlane plane,int32_t key,int32_t scan,
        GlfwAggregateAction action,int32_t mods,const GlfwAggregateSink& sink){
    const uint32_t type=contribution(plane);const uint64_t handle=impl_->ensure(reinterpret_cast<uintptr_t>(sink.context));if(!type||!handle)return;
    AmclControlEmissionV1 receipt{};
    if(impl_->port->apply(handle,type,0,1,key,scan,static_cast<int32_t>(action),&receipt)!=AMCL_CONTROL_EDGE||impl_->port->claim(&receipt)!=AMCL_CONTROL_EDGE)return;
    const GlfwAggregateKeyEvent event{receipt.code,receipt.scanCode,static_cast<GlfwAggregateAction>(receipt.action),mods,receipt};
    if(sink.key){sink.key(sink.context,event);Complete(receipt,AMCL_CONTROL_STATE_FINAL);}else Complete(receipt,AMCL_CONTROL_DISCARDED);
}
// typed按钮在真实window/publication guard内先领取票，调用者写cache并冻结callback后
// 释放guard，再调用用户代码。这里不接触窗口，不以CommitButton返回true冒充callback完成。
bool GlfwSourcePlaneAggregate::CommitButton(GlfwSourcePlane plane,int32_t button,
        GlfwAggregateAction action,int32_t mods,GlfwAggregateButtonEvent* event){
    if(!event)return false;
    *event={};const uint32_t type=contribution(plane);const uint64_t handle=impl_->ensure();if(!type||!handle)return false;
    AmclControlEmissionV1 receipt{};
    if(impl_->port->apply(handle,type,0,2,button,0,static_cast<int32_t>(action),&receipt)!=AMCL_CONTROL_EDGE||impl_->port->claim(&receipt)!=AMCL_CONTROL_EDGE)return false;
    *event={receipt.code,static_cast<GlfwAggregateAction>(receipt.action),mods,receipt};return true;
}
// legacy按钮采用同一neutral CommitButton，保留GLFW自身mods计算与实际button cache。
// 缺sink明确DISCARDED；合法sink在对应真实完成点报告事实，facade不另造一个回调计数。
void GlfwSourcePlaneAggregate::SubmitButton(GlfwSourcePlane plane,int32_t button,
        GlfwAggregateAction action,int32_t mods,const GlfwAggregateSink& sink){
    (void)impl_->ensure(reinterpret_cast<uintptr_t>(sink.context));GlfwAggregateButtonEvent event{};
    if(!CommitButton(plane,button,action,mods,&event))return;
    if(sink.button){sink.button(sink.context,event);Complete(event.receipt,AMCL_CONTROL_STATE_FINAL);}else Complete(event.receipt,AMCL_CONTROL_DISCARDED);
}
// neutral先一次摘本批旧集合，再逐ticket重核reentry；facade没有另一个释放vector或owner表。
// 只摘指定plane，其他来源共持时不release。压力拒绝不输出假成功，release回调重入新holder
// 后nextRetired/claim会拒绝旧票；每次SDK调用仍在neutral锁外。
void GlfwSourcePlaneAggregate::ClearPlane(GlfwSourcePlane plane,const GlfwAggregateSink& sink){
    const uint32_t type=contribution(plane);const uint64_t handle=impl_->ensure();if(!type||!handle)return;
    if(impl_->port->retire(handle,1u<<(type-1),0,0)<0)return;
    AmclControlEmissionV1 e{};
    while(impl_->port->nextRetired(handle,&e)==AMCL_CONTROL_EDGE){
        if(impl_->port->claim(&e)!=AMCL_CONTROL_EDGE)continue;
        if(e.kind==1&&sink.key)sink.key(sink.context,{e.code,e.scanCode,GlfwAggregateAction::kRelease,0,e});
        else if(e.kind==2&&sink.button)sink.button(sink.context,{e.code,GlfwAggregateAction::kRelease,0,e});
        else {Complete(e,AMCL_CONTROL_DISCARDED);continue;}
        Complete(e,AMCL_CONTROL_STATE_FINAL);
    }
}
// 实际GLFW窗口退休时摘本consumer全部贡献。不是按两个plane分别清：第一份release回调
// 可能建立新owner，第二轮独立clear会错误摘它，因此采用一次neutral事务。
void GlfwSourcePlaneAggregate::ClearAll(const GlfwAggregateSink& sink){
    const uint64_t handle=impl_->ensure();if(!handle||impl_->port->retire(handle,AMCL_CONTROL_MASK_ALL,0,0)<0)return;
    AmclControlEmissionV1 e{};
    while(impl_->port->nextRetired(handle,&e)==AMCL_CONTROL_EDGE){
        if(impl_->port->claim(&e)!=AMCL_CONTROL_EDGE)continue;
        if(e.kind==1&&sink.key)sink.key(sink.context,{e.code,e.scanCode,GlfwAggregateAction::kRelease,0,e});
        else if(e.kind==2&&sink.button)sink.button(sink.context,{e.code,GlfwAggregateAction::kRelease,0,e});
        else {Complete(e,AMCL_CONTROL_DISCARDED);continue;}
        Complete(e,AMCL_CONTROL_STATE_FINAL);
    }
}
// 仅用于无可交付window的既有边界，不合成callback。MAX会关闭旧handle，不回绕activation。
void GlfwSourcePlaneAggregate::Abandon(){const uint64_t handle=impl_->ensure();if(handle)impl_->port->abandon(handle);}
// 供内部查询聚合desired，不能把此查询称为游戏真实glfwGetKey/GetMouseButton读取。
bool GlfwSourcePlaneAggregate::IsKeyPressed(int32_t code)const{const uint64_t h=impl_->ensure();return h&&impl_->port->query(h,1,code)>0;}
bool GlfwSourcePlaneAggregate::IsButtonPressed(int32_t code)const{const uint64_t h=impl_->ensure();return h&&impl_->port->query(h,2,code)>0;}
// actual getter合法读完窗口cache后才调用；诊断反馈、ring取走、desired query都不调用此口。
void GlfwSourcePlaneAggregate::ObservePoll(uint32_t kind,int32_t code,int32_t held){const uint64_t h=impl_->ensure();if(h)(void)impl_->port->observePoll(h,kind,code,held);}
// 只读原consumer的统计；无Ready/旧handle返回false，不把UI反馈订阅当输入运行维护。
bool GlfwSourcePlaneAggregate::Snapshot(AmclControlSnapshotV1& out)const{const uint64_t h=impl_->ensure();out.size=sizeof(out);return h&&impl_->port->snapshot(h,&out)==0;}
/**
 * 视角与按键共用同一已核neutral连接。首次读取仍通过严格跨映像解析，并交叉核ownerHost；
 * 成功表不可变且由进程pin。每次prefix的bind/prepare/claim/validate仍由真实owner执行，
 * 这里不能把函数表可调用等同于窗口、焦点、模式或票据仍有效。fork先于任何本地锁拒绝。
 */
const AmclLookExecutionPortV1* GlfwSourcePlaneAggregate::LookPort()const{
    if(impl_->process!=processId())return nullptr;
    // 热路径只借用不可变表；当前consumer/窗口的事实仍由随后实际票据操作读取。
    // 不为取得函数地址再做一次facade锁和control snapshot。
    const auto* connected=impl_->look.load(std::memory_order_acquire);if(connected)return connected;
    if(!impl_->ensure())return nullptr;
    std::lock_guard<std::mutex> lock(impl_->mutex);
    connected=impl_->look.load(std::memory_order_acquire);
    if(!connected){
        const AmclLookExecutionPortV1* candidate=nullptr;
        if(amclLookExecutionResolveV1(&candidate)<0||candidate->ownerHost!=impl_->port->ownerHost)return nullptr;
        impl_->look.store(candidate,std::memory_order_release);connected=candidate;
    }
    return connected;
}
}
