// neutral owner唯一的末级贡献状态。三个ABI只通过本C端口提交/领取，状态锁内不执行
// 回调、JNI、SDL或窗口查询。原目标资格与实际执行线程仍由各ABI自己的真实guard证明。
#include "control_delivery.h"
#include "l2_keyboard_scope.h"
#include "../source/source_control_client.h"
#include "../amcl_input_api.h"
#include "../amcl_input_host_descriptor.h"
#include <map>
#include <set>
#include <deque>
#include <mutex>
#include <atomic>
#include <limits>
#include <new>
#include <cstdio>
#include <cstdlib>
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

#ifdef _WIN32
#pragma comment(linker, "/export:amclControlDeliveryGetPortV1")
#pragma comment(linker, "/export:amclControlDeliveryBindSessionV1")
#pragma comment(linker, "/export:amclControlDeliveryPublishV1")
#pragma comment(linker, "/export:amclInputL2KeyboardGetPortV1")
#endif

namespace {
// 容量按每consumer分别约束；拒绝必须发生在贡献正式提交之前。
// 当前ABI的键/按钮集合远小于此界，测试仍覆盖耗尽时不得建立假owner的行为。
constexpr size_t kConsumers=64, kControls=1024, kOwners=512, kTickets=2048;
// 只读取OS事实。PID是进程owner的身份边界，不能用游戏session或窗口身份替代。
uint32_t pid() {
#ifdef _WIN32
    return static_cast<uint32_t>(_getpid());
#else
    return static_cast<uint32_t>(getpid());
#endif
}
// module装载时冻结进程身份；所有公开入口在registry首次初始化guard与继承mutex前检查。
const uint32_t ownerProcess=pid();
bool foreignOwner(){return pid()!=ownerProcess;}
// code已由ABI边缘完成一次编码：GLFW key/button、L2 key/button、SDL scancode/button。
// consumer隔离这些不同命名空间，common算法不会再做一轮键码/按钮翻译。
struct Control {
    uint32_t kind;
    int32_t code;
    bool operator<(const Control& b)const {
        return kind<b.kind||(kind==b.kind&&code<b.code);
    }
};
// type区分贡献职责，id区分该职责内的具体device/contact。已聚合的legacy/typed
// 使用id=0；真实typed device/contact必须非零。reset按此身份摘除，不能全局猜测来源。
struct Owner {
    uint32_t type;
    uint64_t id;
    bool operator<(const Owner& b)const {
        return type<b.type||(type==b.type&&id<b.id);
    }
};
// owners是已接受的desired贡献权威，空/非空决定最终UP/DOWN。
// observedHeld只承认实际ABI缓存的phase0/终结证据，不能把claim或队列入队冒充游戏领取。
// revision仅在最终desired变化时前进；共持加入/退出不能让唯一待交付PRESS失去资格。
struct Held {
    std::set<Owner> owners;
    int32_t scan=0;
    uint64_t revision=0;
    bool observedHeld=false;
};
// emission冻结consumer/activation/target/revision/ticket与ABI输出字段。
// claimed只表示边缘进入输出围栏；stateApplied另记真实cache事实。source仅用于核repeat
// 原来源仍持有，修复聚合DOWN时不要求触发修复的来源仍在owners中。
struct Ticket {
    AmclControlEmissionV1 emission{};
    bool claimed=false,stateApplied=false;
    Owner source{};
};
// 一个实际ABI消费者拥有自己的cache恢复上下文和交付统计。retired只保存尚待边缘领取的
// release计划，每次nextRetired都重新核票；它不是一份可以在重入后无条件输出的释放快照。
struct Consumer {
    AmclControlSnapshotV1 stats{};
    std::map<Control,Held> controls;
    std::map<uint64_t,Ticket> tickets;
    std::deque<AmclControlEmissionV1> retired;
    // 仅真实L2 Keyboard完整create登记的原lease；不复制key desired/cache/tickets。
    uint64_t keyboardGeneration=0;
};
// 唯一neutral owner的进程状态。mutex只保护内部值，锁内绝不调用窗口、用户callback、
// JNI或SDL。session是本局冻结身份；三个全局计数只递增、不回退、不因失败复用旧身份。
struct Registry {
    std::mutex mutex;std::map<uint64_t,Consumer> consumers;
    uint64_t session=0,nextConsumer=1,nextTicket=1,nextRevision=1,nextKeyboard=1;
    const uint32_t process=pid();
};
// 函数局部静态避免GLFW的进程静态facade早于另一个DSO的全局构造而访问未建好的状态。
// 中立owner与借出的表是进程期资源。global GLFW facade可在本TU首次使用之前构造；
// 普通function-static对象会在facade之前析构，facade末尾close将访问已释放map/mutex。
// 预线程发布初始化唯一对象，进程结束由OS回收；不借此允许停局卸载DSO或重建JVM。
// 分配失败明确终止初始化，绝不借nullptr表或创建第二owner。fork入口在调用此guard前拒绝。
Registry& registry(){static Registry* const value=[](){
    Registry* created=new(std::nothrow) Registry;
    if(!created)std::abort();
    return created;
}();return *value;}
// 本owner不支持fork继承：child可能继承另一线程持有的mutex，必须在任何加锁前拒绝。
// process在module早期发布点初始化后不可变；不清继承容器、不重建mutex、不改借出的表。
bool inherited(const Registry& r){return r.process!=pid();}
// 输入为port声明的公共Core表地址。必须通过既有跨DSO descriptor解析并与此映像真实
// Core表完全一致；magic/PID/可执行地址只作前置资格，不能证明唯一owner。
int32_t verify(uint64_t identity) {
    if(foreignOwner())return AMCL_CONTROL_NOT_READY;
    const AmclInputHostApiV1* actual=nullptr;
    return identity && amclInputHostDescriptorResolveV1(&actual)==AMCL_INPUT_HOST_DESCRIPTOR_OK &&
        identity==static_cast<uint64_t>(reinterpret_cast<uintptr_t>(actual)) && actual==amclInputGetHostApiV1()
        ? AMCL_CONTROL_ACCEPTED_NO_EDGE : AMCL_CONTROL_NOT_READY;
}
// 不解释ABI键码含义，只拒绝不属于key/button空间或无法由V1表示的负值/越界值。
bool validControl(uint32_t kind,int32_t code){return (kind==AMCL_CONTROL_KEY||kind==AMCL_CONTROL_BUTTON)&&code>=0&&code<=65535;}
// 仅在已持registry锁时取借用引用；close/abandon耗尽后旧id永远找不到。
// PID检查同时保留在各入口的加锁之前，此处是锁内一致性核对，不能替代前置检查。
Consumer* find(Registry& r,uint64_t id){
    if(r.process!=pid())return nullptr;
    auto it=r.consumers.find(id);
    return it==r.consumers.end()?nullptr:&it->second;
}
// 输入是已选定的最终ABI边沿；输出冻结所有身份，不执行ABI调用。
// 调用方必须先检查counter/容量，且在后续分配失败时不提交Ticket/owners；烧掉未借出的
// 单调序号是允许的，回退序号以求连续会使迟到旧票有机会混入新事务。
AmclControlEmissionV1 makeEmission(Registry& r,Consumer& c,const Control& control,Held& held,int32_t action){
    AmclControlEmissionV1 e{};e.size=sizeof(e);e.kind=control.kind;e.code=control.code;e.scanCode=held.scan;e.action=action;
    e.consumer=c.stats.consumer;e.activation=c.stats.activation;e.target=c.stats.target;e.revision=held.revision;e.ticket=r.nextTicket++;
    return e;
}
// claimed表示此消费线程已进入实际ABI调用围栏。同步回调重入按在途边沿的目标状态
// 决策，完成/观测计数仍须等待真正输出；未claimed的退休计划不能冒充已交付释放。
bool effectiveHeld(const Consumer& c,const Control& control,const Held& held){
    bool value=held.observedHeld;uint64_t latest=0;
    for(const auto& entry:c.tickets){const auto& t=entry.second;const auto& e=t.emission;
        // 重入中新边沿已经完成后，旧claimed票仍须保留到其真实callback返回，但它不再
        // 拥有当前activation/revision，不能盖掉新observedHeld并吞掉后续的新UP/DOWN。
        // apply在推进revision前查询，因此当前正在执行的原票仍能为首次重入提供投影。
        if(t.claimed&&!t.stateApplied&&e.activation==c.stats.activation&&e.revision==held.revision&&
           e.target==c.stats.target&&e.kind==control.kind&&e.code==control.code&&
           // repeat只代表原source；apply传入的是候选Held，不能去旧c.controls借已退休来源。
           // 普通聚合修复DOWN/UP继续只认最终职责，不要求触发它的source仍在owners中。
           (e.action!=AMCL_CONTROL_REPEAT||held.owners.count(t.source)!=0)&&e.ticket>latest){value=e.action!=0;latest=e.ticket;}}
    return value;
}
// 同desired/revision的未claim票已承担恢复职责，不重复创建另一个PRESS/UP。
// 共持NoEdge保留该票；真正desired改变推进revision后它会被claim/nextRetired拒绝。
bool pendingState(const Consumer& c,const Control& control,const Held& held,bool desired){
    for(const auto& entry:c.tickets){const auto& t=entry.second;const auto& e=t.emission;
        if(!t.claimed&&e.activation==c.stats.activation&&e.revision==held.revision&&e.kind==control.kind&&e.code==control.code&&
            e.action==(desired?1:0))return true;}
    return false;
}
// 退休只丢尚未进入ABI的计划；已claim票保留到真实completion，以便记录原activation
// 的callback/队列交接事实。保留并不意味着它还能写当前target：ticketCurrent另核。
void discardUnclaimed(Consumer& c){for(auto it=c.tickets.begin();it!=c.tickets.end();)if(!it->second.claimed)it=c.tickets.erase(it);else ++it;}
// 只读判定冻结票还能作用于当前消费上下文。DOWN/UP必须符合当前聚合desired；repeat
// 还必须证明其原source仍持有。无外部查询/回调，调用方须已持registry锁。
bool ticketCurrent(const Consumer& c,const AmclControlEmissionV1& e){
    if(e.activation!=c.stats.activation||e.target!=c.stats.target)return false;
    const auto it=c.controls.find({e.kind,e.code});
    if(it==c.controls.end()||it->second.revision!=e.revision)return false;
    if(e.action==2){auto t=c.tickets.find(e.ticket);return t!=c.tickets.end()&&it->second.owners.count(t->second.source)!=0;}
    return e.action==0?it->second.owners.empty():!it->second.owners.empty();
}
// 防止调用方只保ticket数值却改绑code/action/target/scan，旧票不能借新字段越域执行。
bool same(const AmclControlEmissionV1& a,const AmclControlEmissionV1& b){
    return a.size==sizeof(a)&&a.consumer==b.consumer&&a.activation==b.activation&&a.revision==b.revision&&
        a.ticket==b.ticket&&a.target==b.target&&a.kind==b.kind&&a.code==b.code&&a.scanCode==b.scanCode&&a.action==b.action;
}
// open输入真实backend枚举和逻辑target，输出不复用opaque handle。创建前核唯一Core
// owner及已冻结session；缺契约返回NOT_READY，容量/分配/计数耗尽返回PRESSURE。
// 所有失败先把*out清零，不把“平台/窗口存在”当消费者已Ready，也不进行ABI副作用。
int32_t open(uint32_t backend,uint64_t target,uint64_t* out){
    if(out)*out=0;if(!out||backend<1||backend>3)return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_NOT_READY;auto& r=registry();if(inherited(r))return AMCL_CONTROL_NOT_READY;
    if(verify(reinterpret_cast<uintptr_t>(amclInputGetHostApiV1()))<0)return AMCL_CONTROL_NOT_READY;
    std::lock_guard<std::mutex> lock(r.mutex);
    if(r.process!=pid()||!r.session)return AMCL_CONTROL_NOT_READY;
    if(r.consumers.size()>=kConsumers||r.nextConsumer==UINT64_MAX)return AMCL_CONTROL_PRESSURE;
    try {Consumer c;c.stats.size=sizeof(c.stats);c.stats.backend=backend;c.stats.gameSession=r.session;
        c.stats.consumer=r.nextConsumer++;c.stats.activation=1;c.stats.target=target;
        const uint64_t handle=c.stats.consumer;r.consumers.emplace(handle,std::move(c));*out=handle;return AMCL_CONTROL_ACCEPTED_NO_EDGE;
    }catch(const std::bad_alloc&){return AMCL_CONTROL_PRESSURE;}
}
/** 只有上游Keyboard完整create后的真实callback调用；不创建control consumer。
 * 单例L2窗口同时只允许一份active keyboard，必须先精确围栏旧lease；不自动改绑current。
 * generation由原registry分配，Core只镜像原子发布值，MAX拒绝且不回绕。
 */
int32_t keyboardCompleteCreate(uint64_t handle,AmclL2KeyboardLeaseV1* out){
    if(out)*out={};if(!out)return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_NOT_READY;auto& r=registry();if(inherited(r))return AMCL_CONTROL_NOT_READY;
    if(verify(reinterpret_cast<uintptr_t>(amclInputGetHostApiV1()))<0)return AMCL_CONTROL_NOT_READY;
    std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,handle);
    if(!c||c->stats.backend!=2||!c->stats.target||c->keyboardGeneration||amclInputOwnerL2KeyboardScopeV1())return AMCL_CONTROL_NOT_READY;
    if(r.nextKeyboard==UINT64_MAX)return AMCL_CONTROL_PRESSURE;
    const uint64_t generation=r.nextKeyboard++;
    if(!amclInputOwnerCompareL2KeyboardScopeV1(0,generation))return AMCL_CONTROL_NOT_READY;
    c->keyboardGeneration=generation;*out={sizeof(*out),2,handle,c->stats.target,generation};return AMCL_CONTROL_EDGE;
}
/** destroy/失败先撤资格；CAS不会让旧close清掉新scope。只退Keyboard事实，不关Mouse。
 * 原key contribution/ticket/queue的有界退休仍由既有retireKind/discardRecords维护。
 */
int32_t keyboardFence(const AmclL2KeyboardLeaseV1* original){
    if(!original||original->size!=sizeof(*original)||original->backend!=2||!original->generation)return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;
    std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,original->consumer);
    if(!c||c->stats.target!=original->target)return AMCL_CONTROL_STALE;
    if(!c->keyboardGeneration)return AMCL_CONTROL_ACCEPTED_NO_EDGE;
    if(c->keyboardGeneration!=original->generation)return AMCL_CONTROL_STALE;
    (void)amclInputOwnerCompareL2KeyboardScopeV1(original->generation,0);c->keyboardGeneration=0;return AMCL_CONTROL_ACCEPTED_NO_EDGE;
}
int32_t keyboardSnapshot(uint64_t handle,AmclL2KeyboardLeaseV1* out){
    if(out)*out={};if(!out)return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_NOT_READY;auto& r=registry();if(inherited(r))return AMCL_CONTROL_NOT_READY;
    std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,handle);
    if(!c||c->stats.backend!=2||!c->keyboardGeneration||amclInputOwnerL2KeyboardScopeV1()!=c->keyboardGeneration)return AMCL_CONTROL_NOT_READY;
    *out={sizeof(*out),2,handle,c->stats.target,c->keyboardGeneration};return AMCL_CONTROL_EDGE;
}
// Java实际cache写前核完整原POD。Source最终事务只读Core原子generation，不调用此锁口。
// generation虽不复用，仍不能允许caller改consumer/target后借同号取得完整resource资格。
int32_t keyboardValidate(const AmclL2KeyboardLeaseV1* original){
    if(foreignOwner())return AMCL_CONTROL_STALE;
    if(!original||original->size!=sizeof(*original)||original->backend!=2||!original->generation)return AMCL_CONTROL_REJECTED;
    auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);
    const auto* c=find(r,original->consumer);
    return c&&c->stats.backend==2&&c->stats.target==original->target&&c->keyboardGeneration==original->generation&&
        amclInputOwnerL2KeyboardScopeV1()==original->generation?AMCL_CONTROL_EDGE:AMCL_CONTROL_STALE;
}
int32_t keyboardReadCoreStamp(uint64_t handle,uint64_t sequence,uint64_t* scope){
    if(foreignOwner())return AMCL_CONTROL_STALE;
    return amclInputOwnerReadL2KeyStampV1(reinterpret_cast<uintptr_t>(amclInputGetHostApiV1()),handle,sequence,scope)
        ?AMCL_CONTROL_EDGE:AMCL_CONTROL_STALE;
}
/** 当前持有基线只借唯一事实源，不在registry锁内反取Source/Core锁。
 * 读前后都核原lease；Java完整create仍持GlobalLock，基线写入与后继正常泵串行。
 * 期间合法UP仍可入新scope运输，随后按原有序链结束基线，不保存另一份desired。 */
int32_t keyboardHeldLegacy(const AmclL2KeyboardLeaseV1* original,int32_t key){
    if(keyboardValidate(original)!=AMCL_CONTROL_EDGE)return AMCL_CONTROL_STALE;
    // 借唯一Source的既有只读query，不使control-only消费者反向强链接Source实现。
    const AmclSourceControlPortV1* source=nullptr;uint64_t producer=0;AmclSourceSnapshotV1 snapshot{};
    const AmclSourceOutputV1 value{0u,key};
    const int held=amclSourceControlResolveV1(&source)>=0&&source->preparedProducer(AMCL_SOURCE_ENTRY,&producer)>=0&&producer&&
        source->query(producer,0,&value,&snapshot)>=0&&snapshot.owns?1:0;
    return keyboardValidate(original)==AMCL_CONTROL_EDGE?held:AMCL_CONTROL_STALE;
}
int32_t keyboardHeldTyped(const AmclL2KeyboardLeaseV1* original,int32_t key){
    if(keyboardValidate(original)!=AMCL_CONTROL_EDGE)return AMCL_CONTROL_STALE;
    const int held=amclInputOwnerReadL2HeldKeyV1(key);
    return keyboardValidate(original)==AMCL_CONTROL_EDGE?held:AMCL_CONTROL_STALE;
}
/** 调用方已持registry锁，只撤本consumer的原Keyboard事实。CAS不清后来新scope。 */
void fenceKeyboardLocked(Consumer& c){
    if(c.keyboardGeneration)(void)amclInputOwnerCompareL2KeyboardScopeV1(c.keyboardGeneration,0);
    c.keyboardGeneration=0;
}
// close只结束指定consumer的内部上下文，不猜测可调用的旧窗口、不合成release。
// 真实ABI边缘负责在资源仍活着时retire/交付；已关闭资源则以旧票STALE收口。
void close(uint64_t handle){
    if(foreignOwner())return;auto& r=registry();if(inherited(r))return;
    std::lock_guard<std::mutex> lock(r.mutex);
    auto* c=find(r,handle);if(c)fenceKeyboardLocked(*c);
    r.consumers.erase(handle);
}
// abandon用于已证明无可交付资源的边界：结束贡献并推进activation，不输出事件。
// 已claim票保留真实完成事实；未claim计划退出。void接口在MAX时关闭handle，不能回绕。
void abandon(uint64_t handle){if(foreignOwner())return;auto& r=registry();if(inherited(r))return;std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,handle);if(!c)return;
    fenceKeyboardLocked(*c);
    // void退休口不能伪造下一activation。耗尽时永久关闭本handle，旧票只能返回STALE。
    if(c->stats.activation==UINT64_MAX){r.consumers.erase(handle);return;}
    ++c->stats.activation;c->controls.clear();discardUnclaimed(*c);c->retired.clear();}
// 相同target绑定幂等，0不替代真实target；非零实际target变更精确退休旧上下文。
// MAX拒绝保持原状态，边缘必须停止向新target写cache（GLFW facade有对应拒绝态）。
int32_t bind(uint64_t handle,uint64_t target){if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,handle);if(!c)return AMCL_CONTROL_STALE;
    if(c->stats.target&&target&&c->stats.target!=target){
        // 新target即使因activation耗尽而拒绝，实际旧Keyboard资源也不能继续借其lease。
        // control原返回/目标保持契约不变；仅独立Keyboard事实在失效点立即围栏。
        fenceKeyboardLocked(*c);if(c->stats.activation==UINT64_MAX)return AMCL_CONTROL_PRESSURE;
        ++c->stats.activation;c->controls.clear();discardUnclaimed(*c);c->retired.clear();}
    if(target)c->stats.target=target;return AMCL_CONTROL_ACCEPTED_NO_EDGE;
}
// apply只接受一份来源贡献变化，返回Rejected / AcceptedNoEdge / Edge三种真实结果。
// 候选Held与Ticket所有可能的分配先完成再提交；PRESSURE不建立owner、不伪造已接受。
// Edge附冻结票，调用方仍须claim并执行合法ABI/cache，最后按真实层级complete；此函数
// 不承诺任何游戏callback、L2 next或SDL队列已经领取。scan=0不抹掉已知非零scancode。
int32_t apply(uint64_t handle,uint32_t type,uint64_t owner,uint32_t kind,int32_t code,int32_t scan,int32_t action,AmclControlEmissionV1* out){
    if(out)*out={};
    if(!out||type<1||type>4||!validControl(kind,code)||action<0||action>2||
       ((type==1||type==2)&&owner!=0)||((type==3||type==4)&&owner==0))return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,handle);if(!c)return AMCL_CONTROL_STALE;
    const Control control{kind,code};const Owner identity{type,owner};const auto it=c->controls.find(control);
    const bool owns=it!=c->controls.end()&&it->second.owners.count(identity)!=0;
    // 未知UP/repeat和重复DOWN是明确拒绝，不能以acceptedNoEdge掩盖错误的配对。
    if((action==0||action==2)?!owns:owns)return AMCL_CONTROL_REJECTED;
    if((it==c->controls.end()&&c->controls.size()>=kControls)||
       (action==1&&it!=c->controls.end()&&it->second.owners.size()>=kOwners)||
       r.nextRevision==UINT64_MAX||r.nextTicket==UINT64_MAX)return AMCL_CONTROL_PRESSURE;
    uint64_t createdTicket=0;
    try {
        Held next=it==c->controls.end()?Held{}:it->second;
        const bool before=!next.owners.empty();
        if(action==0)next.owners.erase(identity);else if(action==1)next.owners.insert(identity);
        if(scan!=0)next.scan=scan;
        const bool desired=!next.owners.empty();
        const bool edge=action==2||(desired!=effectiveHeld(*c,control,next)&&!pendingState(*c,control,next,desired));
        if(edge&&c->tickets.size()>=kTickets)return AMCL_CONTROL_PRESSURE;
        // 只在最终边沿变化时推进revision；兄弟owner加入/退出不能取消仍合法的首按计划。
        if(before!=desired)next.revision=r.nextRevision++;
        AmclControlEmissionV1 e{};
        // 失败/丢弃后，source UP也可能只撤一份owner，剩余desired仍是DOWN。
        // 恢复边沿按最终聚合目标生成，不能照搬source action并制造立即STALE的伪UP。
        const int32_t outputAction=action==2?2:(desired?1:0);
        if(edge){e=makeEmission(r,*c,control,next,outputAction);c->tickets.emplace(e.ticket,Ticket{e,false,false,identity});createdTicket=e.ticket;}
        // 所有可能分配的候选已经建好再提交。分配失败不把一次拒绝变成无release的持有。
        if(it==c->controls.end())c->controls.emplace(control,std::move(next));else it->second=std::move(next);
        ++c->stats.accepted;
        if(edge){++c->stats.edges;*out=e;return AMCL_CONTROL_EDGE;}
        ++c->stats.noEdge;return AMCL_CONTROL_ACCEPTED_NO_EDGE;
    }catch(const std::bad_alloc&){if(createdTicket)c->tickets.erase(createdTicket);return AMCL_CONTROL_PRESSURE;}
}
// 精确退休由classMask、可选owner与kind共同定义。keyboard/mouse分开退休不会清掉
// 兄弟队列；全scope才推进activation。先复制整个候选集合、摘本批旧owner、生成release
// 计划，全部成功才替换consumer；任何压力/分配失败保持旧集合，最多消耗未借出的序号。
// 真实SDK调用在nextRetired/claim之后锁外执行，新holder同步回入会使旧release票失效。
int32_t retireKind(uint64_t handle,uint32_t mask,uint64_t owner,int32_t only,uint32_t kind){
    if(!mask||(mask&~15u)||(only!=0&&only!=1)||kind>2)return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,handle);if(!c)return AMCL_CONTROL_STALE;
    if(mask==15u&&!only&&kind==0&&c->stats.activation==UINT64_MAX)return AMCL_CONTROL_PRESSURE;
    try {
        // 整个旧集合先用候选复制摘除；外部callback只能在正式提交后发生。
        Consumer candidate=*c;
        if(mask==15u&&!only&&kind==0){++candidate.stats.activation;candidate.retired.clear();discardUnclaimed(candidate);}
        for(auto& entry:candidate.controls){if(kind&&entry.first.kind!=kind)continue;auto& held=entry.second;const bool before=!held.owners.empty();
            for(auto it=held.owners.begin();it!=held.owners.end();){
                if((mask&(1u<<(it->type-1)))&&(!only||it->id==owner))it=held.owners.erase(it);else ++it;
            }
            // 全职责（或全键/全按钮资源）退休还须收口“UP计划已失败、desired已空，
            // 但ABI实际cache仍held”的恢复上下文。单来源/单owner退休不具有这份权限，
            // 不能因为它看见一个orphan cache就误松其他职责或实际资源的贡献。
            const bool wholeControlScope=mask==15u&&!only;
            const bool orphanApplied=wholeControlScope&&held.owners.empty()&&held.observedHeld;
            if((before&&held.owners.empty())||orphanApplied){
                if(candidate.tickets.size()>=kTickets||r.nextRevision==UINT64_MAX||r.nextTicket==UINT64_MAX)return AMCL_CONTROL_PRESSURE;
                // 只为确需退休的control扫描在途票，局部退休不替仍有owner的兄弟重复扫描。
                // candidate是原集合的复制，遍历中不增删control；原*c尚未提交，故同key的
                // 原Held必存在，且保留原source/revision。不能借已经摘owner的候选Held。
                // 已claim但尚无STATE_ONLY时，保守退休仍须保存原合法在途投影并安排UP；
                // 这只是owner合同推导，SDK是否写缓存由消费层另证，不能从observed=0猜测。
                const bool effectiveBefore=effectiveHeld(*c,entry.first,c->controls.at(entry.first));
                held.revision=r.nextRevision++;
                // 全scope撤销已claim的旧计划后，已证明cache held的事实不能被旧在途UP
                // 投影盖掉；该UP将被validate拒绝，必须由新退休票清实际状态。
                if(orphanApplied||effectiveBefore){
                    auto e=makeEmission(r,candidate,entry.first,held,0);
                    candidate.tickets.emplace(e.ticket,Ticket{e,false,false,{}});candidate.retired.push_back(e);++candidate.stats.edges;
                }
            }
        }
        *c=std::move(candidate);return AMCL_CONTROL_ACCEPTED_NO_EDGE;
    }catch(const std::bad_alloc&){return AMCL_CONTROL_PRESSURE;}
}
// class/owner范围保持相同，kind=0涵盖键与按钮；这只是同一生产退休算法的C端口入口。
int32_t retire(uint64_t handle,uint32_t mask,uint64_t owner,int32_t only){
    return retireKind(handle,mask,owner,only,0);
}
// 每次仅返回一张仍有当前资格的退休票，尚未claim；空计划为AcceptedNoEdge。
// 已被新贡献或目标退休淘汰的旧票在此丢弃，不能先拷贝整份release再忽略重入输出。
int32_t nextRetired(uint64_t handle,AmclControlEmissionV1* out){if(out)*out={};if(!out)return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,handle);if(!c)return AMCL_CONTROL_STALE;
    while(!c->retired.empty()){auto e=c->retired.front();c->retired.pop_front();
        if(ticketCurrent(*c,e)){*out=e;return AMCL_CONTROL_EDGE;}c->tickets.erase(e.ticket);}
    return AMCL_CONTROL_ACCEPTED_NO_EDGE;
}
// claim是一次性的执行围栏入口：完整字段相同且当前资格成立才返回Edge。
// 重复claim明确Rejected，旧activation/target/desired返回STALE并摘未执行票；进入围栏
// 后只能在ABI边缘调用，不能把这个结果计作cache/事件/游戏处理完成。
int32_t claim(const AmclControlEmissionV1* e){if(!e||e->size!=sizeof(*e))return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,e->consumer);if(!c)return AMCL_CONTROL_STALE;
    auto it=c->tickets.find(e->ticket);if(it==c->tickets.end()||!same(*e,it->second.emission)||it->second.claimed)return AMCL_CONTROL_REJECTED;
    if(!ticketCurrent(*c,*e)){c->tickets.erase(it);return AMCL_CONTROL_STALE;}it->second.claimed=true;return AMCL_CONTROL_EDGE;
}
// validate只读复核原票，不创建、不重复claim、不更新desired/observed。
// SDL同步touch/focus/watch hook或L2坐标查询返回后，缓存写回/事件序列化前可再次调用。
int32_t validate(const AmclControlEmissionV1* e){
    if(!e||e->size!=sizeof(*e))return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,e->consumer);if(!c)return AMCL_CONTROL_STALE;
    const auto it=c->tickets.find(e->ticket);if(it==c->tickets.end()||!same(*e,it->second.emission))return AMCL_CONTROL_REJECTED;
    return ticketCurrent(*c,*e)?AMCL_CONTROL_EDGE:AMCL_CONTROL_STALE;
}
// 输入必须是已claim原票及实际完成层级。phase0只记录cache且保票；callback returned
// 与真实L2 next才各计相应终结事实。SDL phase2仅为事件队列/ABI出口接受，未宣称
// 游戏SDL_PollEvent领取；UNCERTAIN/DISCARDED不伪造cache写入。
// 旧callback真的返回仍可计原identity，但STALE完成绝不能覆盖重入后的当前observed。
int32_t complete(const AmclControlEmissionV1* e,uint32_t phase){if(!e||e->size!=sizeof(*e)||phase>5)return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,e->consumer);if(!c)return AMCL_CONTROL_STALE;
    auto it=c->tickets.find(e->ticket);if(it==c->tickets.end()||!same(*e,it->second.emission)||!it->second.claimed)return AMCL_CONTROL_REJECTED;
    const bool current=ticketCurrent(*c,*e);
    // cache应用与事件领取分开。旧callback完成可以计原identity的事实，但不能覆盖重入后的新状态。
    if(phase<=3&&!it->second.stateApplied){
        if(current){auto h=c->controls.find({e->kind,e->code});h->second.observedHeld=e->action!=0;}
        it->second.stateApplied=true;++c->stats.stateOnly;
    }
    if(phase==0)return current?AMCL_CONTROL_ACCEPTED_NO_EDGE:AMCL_CONTROL_STALE;
    if(phase==1)++c->stats.callbackReturned;else if(phase==2)++c->stats.pullCommitted;
    else if(phase==4)++c->stats.uncertain;else if(phase==5)++c->stats.discarded;
    c->stats.lastCompletedActivation=e->activation;if(!current)++c->stats.staleCompletions;
    c->tickets.erase(it);return current?AMCL_CONTROL_ACCEPTED_NO_EDGE:AMCL_CONTROL_STALE;
}
// 返回已接受聚合desired（0/1），STALE/Rejected与布尔值区分；只读，不计游戏poll。
int32_t query(uint64_t handle,uint32_t kind,int32_t code){if(!validControl(kind,code))return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,handle);if(!c)return AMCL_CONTROL_STALE;
    auto it=c->controls.find({kind,code});return it!=c->controls.end()&&!it->second.owners.empty()?1:0;
}
// 返回具有实际cache证据的observed（0/1），与query的贡献意图不同。pre-cache在途claim
// 可以参与同步重入决策，但本函数不会把它投影成SDK已更新的缓存。
int32_t queryDelivered(uint64_t handle,uint32_t kind,int32_t code){
    if(!validControl(kind,code))return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,handle);if(!c)return AMCL_CONTROL_STALE;
    const auto it=c->controls.find({kind,code});return it!=c->controls.end()&&it->second.observedHeld?1:0;
}
// 真实scalar getter已经读完cache后报告0/1；核对observed并计读取/差异，不借读操作补发
// 边沿、不重写cache、不使未领取ticket终结。坏值或旧handle不计合法poll。
int32_t poll(uint64_t handle,uint32_t kind,int32_t code,int32_t value){if(!validControl(kind,code)||(value!=0&&value!=1))return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,handle);if(!c)return AMCL_CONTROL_STALE;
    auto it=c->controls.find({kind,code});const bool held=it!=c->controls.end()&&it->second.observedHeld;
    ++c->stats.legalPollReads;if(held!=(value!=0))++c->stats.pollMismatches;return AMCL_CONTROL_ACCEPTED_NO_EDGE;
}
// 完整Keyboard/Mouse getter以实际byte view一次加锁，避免512次单键调用造成热路径开销。
// count是调用方实际可读长度；只核本consumer已登记且view内的control，每次getter计一次
// legalPollReads、每个不符control计一次mismatch。坏字节先拒绝，不部分计成功。
int32_t pollView(uint64_t handle,uint32_t kind,const uint8_t* values,uint32_t count){
    if((kind!=1&&kind!=2)||count>65536||(!values&&count))return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,handle);if(!c)return AMCL_CONTROL_STALE;
    // 先验证这次实际view，不因为坏字节记一次假的合法poll。只访问调用方承诺的count。
    for(const auto& entry:c->controls){if(entry.first.kind!=kind||static_cast<uint32_t>(entry.first.code)>=count)continue;
        if(values[entry.first.code]>1)return AMCL_CONTROL_REJECTED;}
    ++c->stats.legalPollReads;
    for(const auto& entry:c->controls){if(entry.first.kind!=kind||static_cast<uint32_t>(entry.first.code)>=count)continue;
        if(entry.second.observedHeld!=(values[entry.first.code]!=0))++c->stats.pollMismatches;}
    return AMCL_CONTROL_ACCEPTED_NO_EDGE;
}
// 诊断读取只复制原consumer统计，调用方须提供完整V1输出空间；不消费任何ABI队列。
// 游戏读取完成由对应实际边缘报告，本getter存在或被UI订阅不构成游戏处理证据。
int32_t snapshot(uint64_t handle,AmclControlSnapshotV1* out){if(!out||out->size<sizeof(*out))return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);auto* c=find(r,handle);if(!c)return AMCL_CONTROL_STALE;*out=c->stats;return AMCL_CONTROL_ACCEPTED_NO_EDGE;
}
}
// 模块早期发布时构造const表与registry，借出后不改PID/owner/函数地址。fork继承会
// 带入另一线程持有的mutex，因此在任何锁前拒绝child；不宣称JVM fork输入可恢复。
extern "C" const AmclControlDeliveryPortV1* amclControlDeliveryGetPortV1(){
    if(foreignOwner())return nullptr;auto& r=registry();if(inherited(r))return nullptr;
    static const AmclControlDeliveryPortV1 port={AMCL_CONTROL_MAGIC,1,sizeof(AmclControlDeliveryPortV1),pid(),0,
        reinterpret_cast<uintptr_t>(amclInputGetHostApiV1()),verify,open,close,bind,apply,retire,retireKind,nextRetired,claim,validate,complete,query,queryDelivered,poll,pollView,snapshot,abandon};
#ifdef AMCL_CONTROL_DELIVERY_HOST_TESTING
    // 宿主仍发布真实Core owner表；此处仅建立测试的实际进程绑定，不替换归约算法或函数端口。
    (void)amclInputHostDescriptorPublishV1(amclInputGetHostApiV1());
    (void)amclControlDeliveryBindSessionV1(1);
#endif
    return &port;
}
// 真实会话冻结点调用，同session幂等；0或不同新session明确拒绝，不能趁游戏退出
// 重置进程owner/JVM占用事实。会话结束由实际consumer的retire/close分别收口。
extern "C" int32_t amclControlDeliveryBindSessionV1(uint64_t session){if(!session)return AMCL_CONTROL_REJECTED;
    if(foreignOwner())return AMCL_CONTROL_STALE;auto& r=registry();if(inherited(r))return AMCL_CONTROL_STALE;std::lock_guard<std::mutex> lock(r.mutex);if(r.session&&r.session!=session)return AMCL_CONTROL_STALE;
    r.session=session;return AMCL_CONTROL_ACCEPTED_NO_EDGE;
}
// 只允许既有module Init的pre-thread发布路径；成功后不再改环境。先构造owner/table，
// 再发布同映像getter地址；SDL/L2/GLFW薄client据此并经Core descriptor确认唯一owner。
// 发布失败不声称ready，保留原初始化重试资格；pump/config setter不得重新发布。
extern "C" void amclControlDeliveryPublishV1(){if(foreignOwner())return;static std::atomic<bool> published{false};if(published.load(std::memory_order_acquire))return;
    // module Init在JVM/游戏线程建立之前构造不可变registry/port；发布之后不支持fork继承。
    if(foreignOwner())return;auto& r=registry();if(inherited(r))return;(void)amclControlDeliveryGetPortV1();
    char desc[96]{};std::snprintf(desc,sizeof(desc),AMCL_CONTROL_PREFIX "%llu",static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&amclControlDeliveryGetPortV1)));
#ifdef _WIN32
    const int status=_putenv_s(AMCL_CONTROL_ENV,desc);
#else
    const int status=setenv(AMCL_CONTROL_ENV,desc,1);
#endif
    if(status==0){published.store(true,std::memory_order_release);amclInputL2KeyboardPublishV1();}
}
extern "C" const AmclL2KeyboardPortV1* amclInputL2KeyboardGetPortV1(){
    if(foreignOwner())return nullptr;
    static const AmclL2KeyboardPortV1 port={AMCL_L2_KEYBOARD_MAGIC,1,sizeof(AmclL2KeyboardPortV1),ownerProcess,
        reinterpret_cast<uintptr_t>(amclInputGetHostApiV1()),verify,keyboardCompleteCreate,keyboardFence,keyboardSnapshot,keyboardValidate,keyboardReadCoreStamp,keyboardHeldLegacy,keyboardHeldTyped};
    return &port;
}
/** module预线程发布只公布最大端口能力，active仍是0；不加载游戏类或推断Keyboard成功。 */
extern "C" void amclInputL2KeyboardPublishV1(){
    if(foreignOwner())return;char descriptor[96]{};
    std::snprintf(descriptor,sizeof(descriptor),AMCL_L2_KEYBOARD_PREFIX "%u:%llu",ownerProcess,
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(&amclInputL2KeyboardGetPortV1)));
#ifdef _WIN32
    (void)_putenv_s(AMCL_L2_KEYBOARD_ENV,descriptor);
#else
    (void)setenv(AMCL_L2_KEYBOARD_ENV,descriptor,1);
#endif
}
