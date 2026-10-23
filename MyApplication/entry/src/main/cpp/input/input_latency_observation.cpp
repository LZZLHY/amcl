/** 固定诊断表，只有try-lock和原值复制；满/忙/时钟失败不进入生产返回值。
 * 不是另一输入owner：不产生consumer、prefix、ticket、production order或任何副作用。
 * 新诊断编号只用于记录，不复用；采样/导出不能控制实际运输或回调。
 */
#include "input_latency_observation.h"
#if AMCL_INPUT_TRACE
#include <array>
#include <atomic>
#include <mutex>
#include <chrono>
#include <limits>
#include <cstdio>
#include <cstring>
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#include <time.h>
#endif
#ifndef AMCL_INPUT_LATENCY_SAMPLE_INTERVAL
#define AMCL_INPUT_LATENCY_SAMPLE_INTERVAL 8u
#endif
namespace {
constexpr uint32_t kCapacity=512;
// phase 0无待调callback、1原捕获地址仍待派发、2已经进入实际callback调用。
// 原身份是否已复制独立于读钟成功：时点缺段不意味着可以借下一票/下一ring换标签。
// 两个私有事实只随真实Note首次复制/slot回收改变，不复用callbackPhase，不扩公开152B值。
struct Slot { AmclInputLatencyV1 value{}; bool live=false; uint8_t callbackPhase=0;
    bool ringBound=false,ticketBound=false,pullPending=false; uint32_t backend=0; };
struct PrefixIndex { uint64_t prefix=0,id=0; };
std::array<Slot,kCapacity> records;
std::array<PrefixIndex,kCapacity> prefixes;
std::mutex mutex;
uint64_t nextId=1,requests=0,exported=0;
// 选择只从原冻结InputPlan成功配置点来，0保留旧v1直接调用的未选择观测范围。
// 每个sample在Begin复制一次backend；后续其它consumer绝不替它改变身份或时点。
uint32_t selectedBackend=0;
uint64_t selectedSession=0;
std::atomic<uint64_t> full{0},busy{0},missing{0},clockFailures{0},sampled{0},skipped{0};
std::atomic<bool> counterUncertain{false};
thread_local uint64_t current=0;
// 固定表和索引的真实编译布局设置128KiB硬上限；平台mutex/原子对象布局仍需目标编译核实。
static_assert(sizeof(records)+sizeof(prefixes)+sizeof(mutex)+sizeof(nextId)+sizeof(requests)+sizeof(exported)+
    sizeof(full)+sizeof(busy)+sizeof(missing)+sizeof(clockFailures)+sizeof(sampled)+sizeof(skipped)+
    sizeof(counterUncertain)+sizeof(uint32_t)+sizeof(selectedBackend)+sizeof(selectedSession)<=128*1024,"fixed latency storage exceeds budget");
#ifdef AMCL_INPUT_LATENCY_HOST_TESTING
std::atomic<bool> testClockFailed{false};
std::atomic<void(*)()> testCacheGate{nullptr};
#endif
uint32_t pid(){
#ifdef _WIN32
return static_cast<uint32_t>(_getpid());
#else
return static_cast<uint32_t>(getpid());
#endif
}
const uint32_t ownerPid=pid();
/** 饱和诊断计数不回绕；最多一次CAS，竞争丢这次计数不影响任何输入。 */
void bump(std::atomic<uint64_t>& value){auto old=value.load(std::memory_order_relaxed);
    if(old==UINT64_MAX||!value.compare_exchange_strong(old,old+1,std::memory_order_relaxed))counterUncertain.store(true,std::memory_order_relaxed);}
/** 宿主clock仅验证机制；产品明确CLOCK_MONOTONIC，不推断SDK/sensor同域。 */
uint64_t now(){
#ifdef AMCL_INPUT_LATENCY_HOST_TESTING
if(testClockFailed.load(std::memory_order_relaxed))return 0;
#endif
#ifdef _WIN32
return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
#else
timespec value{};return clock_gettime(CLOCK_MONOTONIC,&value)==0&&value.tv_sec>=0?
    static_cast<uint64_t>(value.tv_sec)*UINT64_C(1000000000)+static_cast<uint64_t>(value.tv_nsec):0;
#endif
}
/** 原编号定位，不能因slot复用把旧prefix贴到后来记录。 */
Slot* byId(uint64_t id){auto& slot=records[id%kCapacity];return id&&slot.live&&slot.value.id==id?&slot:nullptr;}
/** 私有prefix索引只认原token；直接槽碰撞必须缺诊断，不能替别人换身份。 */
Slot* byPrefix(uint64_t prefix){auto& item=prefixes[prefix%kCapacity];return prefix&&item.prefix==prefix?byId(item.id):nullptr;}
/** 每段只第一次成功读钟；失败保留缺段位图，不能以0或导出时刻代填输入时点。 */
void stamp(Slot& slot,uint32_t stage){if(stage>5||slot.value.mask&(1u<<stage))return;
    const uint64_t ns=now();if(!ns){++slot.value.clockFailures;bump(clockFailures);return;}
    slot.value.ns[stage]=ns;slot.value.mask|=1u<<stage;}
/** 原终态转换只在已核资格之后调用；真正prefix退休仍保callback等待/返回。 */
void finishSlot(Slot* slot,uint32_t outcome){
        // 真实producer全prefix退休不表示SDL调用已返回或L2 view已读。已缓存原票
        // 等对应client真实终态/显式覆写/资源清理；缺client会占固定槽而只丢诊断。
        if(slot->backend==2||slot->backend==3){
            if(outcome!=AMCL_ILAT_RETIRED){bump(missing);return;}
            if(slot->pullPending)return;
            if(!slot->value.outcome)slot->value.outcome=slot->backend==3?AMCL_ILAT_SDL_RETIRED:AMCL_ILAT_L2_RETIRED;
            return;
        }
        // 明确未调用分支可以终结expected，不能永久等不存在的return；真正已开始的回调
        // 不由退休或缺日志猜结束。当前产品cache后捕获地址总会被调用；未来skip也必须显式finish。
        if(outcome==AMCL_ILAT_CALLBACK){
            // 真实finish只有callback语句已返回才传CALLBACK。RETURN note忙丢时仍可结束记录，
            // 但没有时点的mask仍保缺段，不能据这个终态补造第六段时刻。
            slot->callbackPhase=0;if(!slot->value.outcome||slot->value.outcome==AMCL_ILAT_RETIRED_WAIT_CALLBACK)
                slot->value.outcome=slot->value.outcome==AMCL_ILAT_RETIRED_WAIT_CALLBACK?AMCL_ILAT_CALLBACK_RETIRED:AMCL_ILAT_CALLBACK;
        }else if(slot->callbackPhase<2&&(outcome==AMCL_ILAT_NO_CALLBACK||outcome==AMCL_ILAT_SKIPPED||outcome==AMCL_ILAT_REJECTED)){
            slot->callbackPhase=0;if(!slot->value.outcome||slot->value.outcome==AMCL_ILAT_RETIRED_WAIT_CALLBACK)slot->value.outcome=outcome;
        }else if(!slot->value.outcome)slot->value.outcome=outcome==AMCL_ILAT_RETIRED&&slot->callbackPhase?AMCL_ILAT_RETIRED_WAIT_CALLBACK:outcome;
}
bool sameLatencyTicket(const AmclInputLatencyV1& a,const AmclInputLatencyV1& b){
    return b.prefix&&b.consumer&&b.activation&&b.target&&b.ticket&&a.prefix==b.prefix&&
        a.consumer==b.consumer&&a.activation==b.activation&&a.target==b.target&&a.ticket==b.ticket;
}
}
/** Native入口先建采样域并返回原TLS；失败/满/忙只置本域为空，不动原输入返回或顺序。 */
extern "C" uint64_t amclInputLatencyBeginV1(uint64_t stream){
    const uint64_t previous=current;current=0;if(pid()!=ownerPid)return previous;
    try{std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);if(!lock.owns_lock()){bump(busy);return previous;}
        if(requests!=UINT64_MAX)++requests;
        constexpr uint64_t interval=AMCL_INPUT_LATENCY_SAMPLE_INTERVAL;
        if constexpr(interval==0){bump(skipped);return previous;}
        else if(requests%interval!=1%interval){bump(skipped);return previous;}
        if(nextId==UINT64_MAX){bump(full);return previous;}
        const uint64_t id=nextId++;auto& slot=records[id%kCapacity];if(slot.live){bump(full);return previous;}
        slot={};slot.live=true;slot.backend=selectedBackend;slot.value.id=id;slot.value.stream=stream;stamp(slot,AMCL_ILAT_ENTRY);current=id;bump(sampled);
    }catch(...){bump(busy);}return previous;
}
extern "C" uint64_t amclInputLatencyCurrentV1(){return pid()==ownerPid?current:0;}
/** 原入口返回恢复重入前TLS；无绑定接受只能报INCOMPLETE，拒绝才用真实输入result标注。 */
extern "C" void amclInputLatencyEndV1(uint64_t previous,int result){const uint64_t id=current;current=previous;
    if(pid()!=ownerPid||!id)return;try{std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);if(!lock.owns_lock()){bump(busy);return;}
        // 接受但无可关联prefix既可能无emit，也可能Accept的try-lock丢诊断；此处只报缺段，
        // 不能把观测缺失断言成真实无callback。已有明确终态（例如索引满）不被覆盖。
        auto* slot=byId(id);if(slot&&!slot->value.prefix&&!slot->value.outcome){
            if(slot->backend==3)slot->value.outcome=result?AMCL_ILAT_SDL_INCOMPLETE:AMCL_ILAT_SDL_REJECTED;
            else if(slot->backend==2)slot->value.outcome=result?AMCL_ILAT_L2_INCOMPLETE:AMCL_ILAT_L2_REJECTED;
            else slot->value.outcome=result?AMCL_ILAT_INCOMPLETE:AMCL_ILAT_REJECTED;
        }
    }catch(...){bump(busy);}}
/** 数学提交成功后绑定已经存在的prefix/order/session；原生产POD与配置均不扩字段。 */
extern "C" void amclInputLatencyAcceptV1(uint64_t prefix,uint64_t order,uint64_t session,uint32_t contributions){
    if(pid()!=ownerPid||!current)return;try{std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);if(!lock.owns_lock()){bump(busy);return;}
        auto* slot=byId(current);if(!slot)return;auto& index=prefixes[prefix%kCapacity];
        slot->value.prefix=prefix;slot->value.prefixOrder=order;slot->value.session=session;
        slot->value.contributions=contributions;stamp(*slot,AMCL_ILAT_ACCEPT);
        // 绑定失败仍导出已实取的原身份；不覆盖同模槽中的旧prefix，也不伪造后续时点。
        if(index.prefix&&byId(index.id)){bump(full);slot->value.outcome=slot->backend==3?AMCL_ILAT_SDL_INCOMPLETE:
            slot->backend==2?AMCL_ILAT_L2_INCOMPLETE:AMCL_ILAT_INCOMPLETE;return;}
        index={prefix,current};
    }catch(...){bump(busy);}}
/** 各真实边缘只复制原slot/票值；READ必须匹配ENQUEUE两种身份，CACHE之后禁止换票。 */
extern "C" void amclInputLatencyNoteV1(uint32_t stage,const AmclInputLatencyV1* value){
    if(pid()!=ownerPid||!value||stage>6)return;try{std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);if(!lock.owns_lock()){bump(busy);return;}
        auto* slot=byPrefix(value->prefix);if(!slot){bump(missing);return;}auto& out=slot->value;
        // 旧Note的READ/CACHE/RETURN仅来自GLFW。InputPlan已经选定pull ABI时，
        // 兄弟GLFW消费照原业务执行，但不偷该sample的后半段时间。
        if(slot->backend>1&&stage>=AMCL_ILAT_READ){bump(missing);return;}
        if(out.outcome&&out.outcome!=AMCL_ILAT_RETIRED_WAIT_CALLBACK)return;
        if(stage==AMCL_ILAT_ENQUEUE){
            // 再发布不能替换原ring身份；重复/冲突只计缺观察，不能反过来改变真实event。
            if(slot->ringBound&&(out.ringSequence!=value->ringSequence||out.ringOrder!=value->ringOrder)){bump(missing);return;}
            out.ringSequence=value->ringSequence;out.ringOrder=value->ringOrder;slot->ringBound=true;}
        // 只有确实复制过原ENQUEUE身份才能关联READ；0仍是原值/缺身份哨兵，不作输入准入判断。
        if(stage==AMCL_ILAT_READ&&(!slot->ringBound||out.ringSequence!=value->ringSequence||out.ringOrder!=value->ringOrder)){bump(missing);return;}
        if(stage>=AMCL_ILAT_CACHE){
            // cache一旦有原票就不能借同prefix的新票换标签；重入/再prepare只缺诊断，输入不受影响。
            // 原票首次由tuple-bearing边缘复制即冻结，包括CACHE读钟失败；全0/unbound由独立事实区分。
            if(slot->ticketBound&&(out.consumer!=value->consumer||out.activation!=value->activation||
               out.target!=value->target||out.ticket!=value->ticket)){bump(missing);return;}
            out.consumer=value->consumer;out.activation=value->activation;out.target=value->target;out.ticket=value->ticket;slot->ticketBound=true;}
        // cache携带原callback是否存在这一私有观察事实。STATE_ONLY只是生产cache的中间回执，
        // 真callback仍可能长时间执行；即便重入退休window，也必须留原POD等它实际返回。
        if(stage==AMCL_ILAT_CACHE)slot->callbackPhase=value->outcome==AMCL_ILAT_CALLBACK?1:0;
        if(stage==AMCL_ILAT_CALLBACK_BEGIN)slot->callbackPhase=2; // 不读钟，只在实际调用语句前记录。
        stamp(*slot,stage);if(stage==AMCL_ILAT_RETURN){slot->callbackPhase=0;
            out.outcome=out.outcome==AMCL_ILAT_RETIRED_WAIT_CALLBACK?AMCL_ILAT_CALLBACK_RETIRED:AMCL_ILAT_CALLBACK;}
#ifdef AMCL_INPUT_LATENCY_HOST_TESTING
        // 故障注入只存在宿主专用编译；实际生产ON/OFF都没有等待或这个hook对象/调用。
        // 先释放诊断mutex，另一线程才可真实退休/drain而不把try-lock busy误当生命周期证明。
        lock.unlock();if(stage==AMCL_ILAT_CACHE){const auto gate=testCacheGate.load();if(gate)gate();}
#endif
    }catch(...){bump(busy);}}
/** 真生产终态只结束诊断；已调用但未返回的callback保留原记录，不用退休猜测完成。 */
extern "C" void amclInputLatencyFinishV1(uint64_t prefix,uint32_t outcome){if(pid()!=ownerPid)return;
    try{std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);if(!lock.owns_lock()){bump(busy);return;}
        auto* slot=byPrefix(prefix);if(!slot)return;
        // 未CACHE绑定时也不能让旧consumer的prefix-only成功/skip/拒绝结束pull
        // 样本。唯一例外仍是真producer全prefix退休，而非任意旧终态翻译退休。
        if(slot->backend>1&&outcome!=AMCL_ILAT_RETIRED){bump(missing);return;}
        // v1签名保持；已有缓存票时，未知consumer的prefix-only终态不能越过CACHE的拒绝。
        // 真实producer全prefix退休仍使用此口；短/旧consumer仅缺诊断，不改变实际输入。
        if(outcome!=AMCL_ILAT_RETIRED&&slot->ticketBound){
            bump(missing);return;}
        finishSlot(slot,outcome);
    }catch(...){bump(busy);}}
/** 只允许原缓存票确认consumer终态；Note被拒/忙丢后不能退回prefix-only或另取latest。
 * callback进行中只接受原票真实返回，NO_CALLBACK/拒绝/skip不得覆盖活动callback Outcome。
 */
extern "C" void amclInputLatencyFinishTicketV1(const AmclInputLatencyV1* original,uint32_t outcome){
    if(pid()!=ownerPid||!original)return;
    if(outcome!=AMCL_ILAT_CALLBACK&&outcome!=AMCL_ILAT_NO_CALLBACK&&outcome!=AMCL_ILAT_REJECTED&&outcome!=AMCL_ILAT_SKIPPED)return;
    try{std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);if(!lock.owns_lock()){bump(busy);return;}
        auto* slot=byPrefix(original->prefix);if(!slot){bump(missing);return;}
        if(slot->backend>1){bump(missing);return;}
        if(!slot->ticketBound||!sameLatencyTicket(slot->value,*original)){bump(missing);return;}
        if(outcome!=AMCL_ILAT_CALLBACK&&slot->callbackPhase==2){bump(missing);return;}
        finishSlot(slot,outcome);
    }catch(...){bump(busy);}}
/** 原InputPlan成功边缘只冷冻结选择；任何冲突/忙丢只缺诊断，不返回输入资格。
 * 不允许同一process通过后来GUI或consumer活动重选backend/session。
 */
extern "C" void amclInputLatencyConfigureBackendV2(uint32_t backend,uint64_t session){
    if(pid()!=ownerPid||backend<1||backend>3||!session)return;
    try{std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);if(!lock.owns_lock()){bump(busy);return;}
        if(selectedSession){if(selectedBackend!=backend||selectedSession!=session)bump(missing);return;}
        // 真启动应早于生产；旧直接宿主/v1调用开始后不把在途记录重签为新ABI。
        if(requests){bump(missing);return;}selectedBackend=backend;selectedSession=session;
    }catch(...){bump(busy);}
}
/** backend与endpoint是一对已声明边界，不接受调用者用L2原票贴SDL ADD标签。 */
static bool pullEndpointMatches(uint32_t backend,uint32_t endpoint){
    return (backend==3&&endpoint==AMCL_ILAT_ENDPOINT_SDL_QUEUE_ADD)||
        (backend==2&&endpoint==AMCL_ILAT_ENDPOINT_L2_POLL_VIEW);
}
/** 真neutral READ保原ring身份；真实cache/终点保原完整票，均不推进输入或查latest。
 * 第六Native时点仅表示本表明确的SDK ADD或L2坐标view复制，永不调用v1 RETURN路径。
 */
extern "C" void amclInputLatencyNoteBackendV2(uint32_t stage,uint32_t backend,uint32_t endpoint,const AmclInputLatencyV1* original){
    if(pid()!=ownerPid||!original||!pullEndpointMatches(backend,endpoint)||
        (stage!=AMCL_ILAT_READ&&stage!=AMCL_ILAT_CACHE&&stage!=AMCL_ILAT_RETURN))return;
    try{std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);if(!lock.owns_lock()){bump(busy);return;}
        auto* slot=byPrefix(original->prefix);
        if(!slot||slot->backend!=backend||slot->value.outcome){bump(missing);return;}
        auto& out=slot->value;
        if(stage==AMCL_ILAT_READ){
            if(!slot->ringBound||out.ringSequence!=original->ringSequence||out.ringOrder!=original->ringOrder){bump(missing);return;}
            stamp(*slot,AMCL_ILAT_READ);return;
        }
        if(!original->consumer||!original->activation||!original->target||!original->ticket||
            (slot->ticketBound&&!sameLatencyTicket(out,*original))){bump(missing);return;}
        if(stage==AMCL_ILAT_CACHE){
            out.consumer=original->consumer;out.activation=original->activation;
            out.target=original->target;out.ticket=original->ticket;slot->ticketBound=true;
            slot->pullPending=true;stamp(*slot,AMCL_ILAT_CACHE);return;
        }
        if(!slot->ticketBound||!slot->pullPending||!sameLatencyTicket(out,*original)){bump(missing);return;}
        stamp(*slot,AMCL_ILAT_RETURN);slot->pullPending=false;
        out.outcome=backend==3?AMCL_ILAT_SDL_QUEUE_COMMITTED:AMCL_ILAT_L2_POLL_VIEW_COPIED;
    }catch(...){bump(busy);}
}
/** 未取得实际终点时，只用原完整缓存票显式结束诊断，且不读钟补造ns[5]。
 * NO_CALLBACK/SKIPPED在此仅指未取得本pull终点；不能写ILAT1 callback终态。
 * 独立成功finish只授调用者已实际证明的终点；Note忙丢时ns[5]仍缺，不按此补钟。
 */
extern "C" void amclInputLatencyFinishBackendV2(uint32_t backend,uint32_t endpoint,const AmclInputLatencyV1* original,uint32_t outcome){
    const bool success=(backend==3&&outcome==AMCL_ILAT_SDL_QUEUE_COMMITTED)||
        (backend==2&&outcome==AMCL_ILAT_L2_POLL_VIEW_COPIED);
    if(pid()!=ownerPid||!original||!pullEndpointMatches(backend,endpoint)||
        (!success&&outcome!=AMCL_ILAT_NO_CALLBACK&&outcome!=AMCL_ILAT_SKIPPED&&outcome!=AMCL_ILAT_RETIRED&&outcome!=AMCL_ILAT_REJECTED))return;
    try{std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);if(!lock.owns_lock()){bump(busy);return;}
        auto* slot=byPrefix(original->prefix);
        if(!slot||slot->backend!=backend||!slot->ticketBound||!sameLatencyTicket(slot->value,*original)){bump(missing);return;}
        if(slot->value.outcome){if(!success||slot->value.outcome!=outcome)bump(missing);return;}
        slot->pullPending=false;
        if(success)slot->value.outcome=outcome;
        else if(outcome==AMCL_ILAT_RETIRED)slot->value.outcome=backend==3?AMCL_ILAT_SDL_RETIRED:AMCL_ILAT_L2_RETIRED;
        else if(outcome==AMCL_ILAT_REJECTED)slot->value.outcome=backend==3?AMCL_ILAT_SDL_REJECTED:AMCL_ILAT_L2_REJECTED;
        else slot->value.outcome=backend==3?AMCL_ILAT_SDL_CACHE_ONLY:AMCL_ILAT_L2_CACHE_UNOBSERVED;
    }catch(...){bump(busy);}
}
/** 原维护锁外导出最多8项；只复制固定表已有终态，长等待/未返回不能被导出释放。 */
extern "C" uint32_t amclInputLatencyDrainV1(AmclInputLatencyV1* output,uint32_t capacity,AmclInputLatencyStatsV1* stats){
    if(pid()!=ownerPid||!output||capacity>8||!stats)return 0;uint32_t count=0;
    try{std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);if(!lock.owns_lock()){bump(busy);return 0;}
        // 长等待是本测量必须保留的对象，不能按年龄抢先退休，否则低FPS尾部被系统性截断。
        // 仅导出真实终态；失去终态记录会占有固定槽，新样本满时只丢诊断，不覆盖旧记录。
        // drain不读钟，导出等待时间从未计入任何输入段。
        for(auto& slot:records){if(!slot.live||!slot.value.outcome||slot.callbackPhase||slot.pullPending)continue;if(count==capacity)break;
            output[count++]=slot.value;auto& index=prefixes[slot.value.prefix%kCapacity];
            if(index.id==slot.value.id)index={};slot={};if(exported!=UINT64_MAX)++exported;}
        *stats={sampled.load(),skipped.load(),full.load(),busy.load(),missing.load(),exported,clockFailures.load(),sizeof(AmclInputLatencyV1),kCapacity,counterUncertain.load()?1u:0u};
    }catch(...){bump(busy);}return count;
}
/** 锁外有界文本格式；512字节数组可容所有原字段极值，任何格式溢出只丢诊断。 */
extern "C" uint32_t inputBridge_formatInputLatencyV1(const AmclInputLatencyV1* value,char* output,uint32_t capacity){
    if(!value||!output||capacity<512)return 0;char times[6][21]{},identities[9][21]{};
    const uint64_t originalIds[9]={value->session,value->prefix,value->prefixOrder,value->ringSequence,value->ringOrder,
        value->consumer,value->activation,value->target,value->ticket};
    // 原POD的0是“没有对应身份”哨兵，显示缺失而不把它冒称实测身份。stream是Native原入参，
    // 0可表示无指定stream的真实flush，仍保原值；时钟失败计数和贡献个数也保真实计数。
    for(uint32_t i=0;i<9;++i){if(originalIds[i])std::snprintf(identities[i],sizeof(identities[i]),"%llu",(unsigned long long)originalIds[i]);
        else {identities[i][0]='-';identities[i][1]=0;}}
    for(uint32_t i=0;i<6;++i){if(value->mask&(1u<<i))std::snprintf(times[i],sizeof(times[i]),"%llu",(unsigned long long)value->ns[i]);
        else {times[i][0]='-';times[i][1]=0;}}
    // 新pull终态使用独立版本和明确端点。旧1–8与未知旧值继续原ILAT1格式，
    // 不改变旧callback解析器行为；旧parser不会把ILAT2静默猜成callback数据。
    const bool pull=value->outcome>=AMCL_ILAT_SDL_QUEUE_COMMITTED&&value->outcome<=AMCL_ILAT_L2_REJECTED;
    char prefix[96]="ILAT1";
    if(pull){const bool sdl=(value->outcome&1u)!=0;
        // b=2为LWJGL2、3为SDL3；e=1为SDL ADD成功后回到adapter的回执，
        // e=2为实际L2 viewcopy，e=0为未观察到这两个终点。紧凑数字标签保
        // 原512字节极值预算；含完整身份/时间的长标签不能靠截断来通过门禁。
        const uint32_t endpoint=value->outcome==AMCL_ILAT_SDL_QUEUE_COMMITTED?1u:
            value->outcome==AMCL_ILAT_L2_POLL_VIEW_COPIED?2u:0u;
        std::snprintf(prefix,sizeof(prefix),"ILAT2 b=%u e=%u",sdl?3u:2u,endpoint);
    }
    const int size=std::snprintf(output,capacity,
        "ILAT1 id=%llu ses=%s stream=%llu pfx=%s po=%s seq=%s ro=%s c=%s a=%s tgt=%s ticket=%s ns=%s/%s/%s/%s/%s/%s mask=%u outcome=%u srcs=%u clockfail=%u sample_range=unknown sdk_clock=unknown",
        (unsigned long long)value->id,identities[0],(unsigned long long)value->stream,
        identities[1],identities[2],identities[3],identities[4],identities[5],identities[6],identities[7],identities[8],
        times[0],times[1],times[2],times[3],times[4],times[5],
        value->mask,value->outcome,value->contributions,value->clockFailures);
    if(size<=0||static_cast<uint32_t>(size)>=capacity){output[0]=0;return 0;}
    if(!pull)return static_cast<uint32_t>(size);
    // 保原ILAT1全格式字面量和输出；只有新终态替换版本前缀。包含NUL的原后缀
    // 先算最终长度，再有界memmove，容量不足返回0，不输出可被误解析的半行。
    const size_t prefixBytes=std::strlen(prefix),suffixBytes=static_cast<size_t>(size)-5;
    const size_t total=prefixBytes+suffixBytes;
    if(total>=capacity){output[0]=0;return 0;}
    std::memmove(output+prefixBytes,output+5,suffixBytes+1);
    std::memcpy(output,prefix,prefixBytes);return static_cast<uint32_t>(total);
}
#ifdef AMCL_INPUT_LATENCY_HOST_TESTING
/** 宿主只读存储证明：返回真实对象sizeof之和，不把MSVC布局冒称目标SDK布局。 */
extern "C" uint32_t amclInputLatencyTestStorageV1(){return sizeof(records)+sizeof(prefixes)+sizeof(mutex)+
    sizeof(nextId)+sizeof(requests)+sizeof(exported)+sizeof(full)+sizeof(busy)+sizeof(missing)+
    sizeof(clockFailures)+sizeof(sampled)+sizeof(skipped)+sizeof(counterUncertain)+sizeof(ownerPid)+sizeof(selectedBackend)+sizeof(selectedSession);}
extern "C" void amclInputLatencyTestCacheGateV1(void(*gate)()){testCacheGate.store(gate);}
extern "C" void amclInputLatencyTestHoldV1(int hold){if(hold)mutex.lock();else mutex.unlock();}
extern "C" void amclInputLatencyTestClockV1(int failed){testClockFailed.store(failed!=0,std::memory_order_relaxed);}
#endif
#endif
