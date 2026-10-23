// 真实neutral/Core端口的可重放长序列。独立oracle只记录来源集合与夹具确实写过的
// ABI缓存，不复制生产revision/ticket归约算法；平台输出是显式替身，不能代证游戏或设备。
#include "delivery/control_delivery_client.h"
#include <array>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {
const AmclControlDeliveryPortV1* port=nullptr;
uint64_t seed=0;
uint32_t backend=0;
size_t step=0;
std::deque<std::string> trace;

// 失败始终保留种子、backend、步号与最后128条操作；Release也不依赖会被裁掉的assert。
[[noreturn]] void fail(int line,const char* condition){
    std::cerr<<"SEQUENCE FAIL seed="<<seed<<" backend="<<backend<<" step="<<step
        <<" line="<<line<<" condition="<<condition<<'\n';
    for(const auto& row:trace)std::cerr<<row<<'\n';
    std::exit(1);
}
#define CHECK(v) do{if(!(v))fail(__LINE__,#v);}while(false)
void record(const std::string& value){
    trace.push_back(std::to_string(step)+" "+value);if(trace.size()>128)trace.pop_front();
}

// 算法固定为xorshift64*，不依赖标准库distribution实现或墙钟；同seed跨宿主可重放。
struct Random {
    uint64_t state;
    uint64_t next(){state^=state>>12;state^=state<<25;state^=state>>27;return state*UINT64_C(2685821657736338717);}
    unsigned pick(unsigned bound){return static_cast<unsigned>(next()%bound);}
};
struct Source {uint32_t type;uint64_t id;};
constexpr Source sources[]={{1,0},{2,0},{3,101},{3,102},{4,201},{4,202}};
constexpr size_t controlCount=24;
uint32_t kind(size_t index){return index<16?AMCL_CONTROL_KEY:AMCL_CONTROL_BUTTON;}
int code(size_t index){return static_cast<int>(index<16?index:index-16);}
size_t indexOf(const AmclControlEmissionV1& e){
    CHECK((e.kind==1&&e.code>=0&&e.code<16)||(e.kind==2&&e.code>=0&&e.code<8));
    return static_cast<size_t>(e.code)+(e.kind==1?0:16);
}
struct Pending {AmclControlEmissionV1 emission{};bool claimed=false,written=false;};
struct Coverage {uint64_t accepted=0,rejected=0,failed=0,delayed=0,stale=0,
    retired=0,rebound=0,closed=0,tampered=0,polls=0;};
Coverage coverage;

// 这份模型不解释生产票据的资格。owners是六个外部来源的事实；cache只在夹具实际
// 完成当前输出时改变。目标重建会建立全新的空缓存，旧完成必须保持该事实不变。
struct Sequence {
    Random random;
    uint64_t consumer=0,target=100,guard=0,accepted=0,lastTicket=0;
    std::array<unsigned,controlCount> owners{};
    std::array<bool,controlCount> cache{};
    std::deque<Pending> pending;
    explicit Sequence(uint64_t value):random{value}{
        CHECK(port->open(backend,target,&consumer)==0&&consumer);
        CHECK(port->open(backend%3+1,target,&guard)==0&&guard!=consumer);
        AmclControlEmissionV1 e{};
        CHECK(port->apply(guard,1,0,1,0,0,1,&e)==1&&port->claim(&e)==1&&port->complete(&e,3)==0);
    }
    ~Sequence(){port->close(consumer);port->close(guard);}
    void enqueue(const AmclControlEmissionV1& e){
        CHECK(e.size==sizeof(e)&&e.consumer==consumer&&e.target==target&&e.ticket>lastTicket);
        CHECK(e.action==AMCL_CONTROL_REPEAT||((e.action!=0)==(owners[indexOf(e)]!=0)));
        lastTicket=e.ticket;pending.push_back({e,false,false});
    }
    // 每步检查双口径以及另一个consumer的同码持有，禁止取消/目标/句柄跨实例传播。
    void verify(){
        for(size_t i=0;i<controlCount;++i){
            CHECK(port->query(consumer,kind(i),code(i))==(owners[i]?1:0));
            CHECK(port->queryDelivered(consumer,kind(i),code(i))==(cache[i]?1:0));
        }
        CHECK(port->query(guard,1,0)==1&&port->queryDelivered(guard,1,0)==1);
        AmclControlSnapshotV1 stats{};stats.size=sizeof(stats);CHECK(port->snapshot(consumer,&stats)==0);
        CHECK(stats.consumer==consumer&&stats.backend==backend&&stats.target==target&&stats.accepted==accepted);
    }
    // 生产apply决定是否需要修复边沿；oracle只决定配对是否合法以及接受后的贡献集合。
    void apply(size_t i,unsigned source,int action){
        const auto owner=sources[source];const unsigned bit=1u<<source;
        const bool held=(owners[i]&bit)!=0;const bool legal=action==1?!held:held;
        AmclControlEmissionV1 e{};
        const int result=port->apply(consumer,owner.type,owner.id,kind(i),code(i),30+code(i),action,&e);
        record("apply c="+std::to_string(consumer)+" key="+std::to_string(i)+" owner="+
            std::to_string(source)+" action="+std::to_string(action)+" rc="+std::to_string(result));
        if(!legal){CHECK(result==AMCL_CONTROL_REJECTED&&e.ticket==0);++coverage.rejected;return;}
        // 随机部分只有24控件/6来源和有界待处理队列，容量压力不是可接受的随机噪声。
        CHECK(result==AMCL_CONTROL_EDGE||result==AMCL_CONTROL_ACCEPTED_NO_EDGE);
        if(action==1)owners[i]|=bit;else if(action==0)owners[i]&=~bit;
        ++accepted;++coverage.accepted;
        if(result==AMCL_CONTROL_EDGE)enqueue(e);else CHECK(e.ticket==0);
    }
    // 键/按钮、贡献职责及原owner三个轴独立归约，不按生产内部revision推导预期。
    void retire(uint32_t mask,uint64_t owner,int only,uint32_t selectedKind){
        record("retire mask="+std::to_string(mask)+" owner="+std::to_string(owner)+
            " only="+std::to_string(only)+" kind="+std::to_string(selectedKind));
        CHECK(port->retireKind(consumer,mask,owner,only,selectedKind)==0);
        for(size_t i=0;i<controlCount;++i)if(!selectedKind||kind(i)==selectedKind)
            for(unsigned s=0;s<6;++s)if((mask&(1u<<(sources[s].type-1)))&&(!only||sources[s].id==owner))owners[i]&=~(1u<<s);
        AmclControlEmissionV1 e{};int result;
        while((result=port->nextRetired(consumer,&e))==AMCL_CONTROL_EDGE)enqueue(e);
        CHECK(result==0);++coverage.retired;
    }
    // 外部ABI调度边缘：可延迟claim、延迟STATE_ONLY后的终结、丢弃/未知完成。每次写
    // 缓存前复核原票，失败只报告失败；绝不按后来target重签原票或让complete替代实际写入。
    void service(unsigned mode){
        if(pending.empty())return;
        auto item=pending.front();pending.pop_front();const auto& e=item.emission;
        record("service ticket="+std::to_string(e.ticket)+" mode="+std::to_string(mode)+
            " claimed="+std::to_string(item.claimed)+" written="+std::to_string(item.written));
        if(!item.claimed){
            if(mode==0){pending.push_back(item);++coverage.delayed;return;}
            const int result=port->claim(&e);
            if(result!=AMCL_CONTROL_EDGE){CHECK(result==AMCL_CONTROL_STALE||result==AMCL_CONTROL_REJECTED);++coverage.stale;return;}
            item.claimed=true;CHECK(port->claim(&e)==AMCL_CONTROL_REJECTED);
            if(mode==1){pending.push_back(item);++coverage.delayed;return;}
        }
        if(item.written){
            const int result=port->complete(&e,backend==1?AMCL_CONTROL_CALLBACK_RETURNED:AMCL_CONTROL_PULL_COMMITTED);
            CHECK(result==0||result==AMCL_CONTROL_STALE);if(result<0)++coverage.stale;
            CHECK(port->complete(&e,3)==AMCL_CONTROL_REJECTED||e.consumer!=consumer);return;
        }
        const int valid=port->validate(&e);
        CHECK(valid==AMCL_CONTROL_EDGE||valid==AMCL_CONTROL_STALE);
        if(valid==AMCL_CONTROL_STALE||mode==2||mode==3){
            const int result=port->complete(&e,mode==2?AMCL_CONTROL_UNCERTAIN:AMCL_CONTROL_DISCARDED);
            CHECK(result==(valid==AMCL_CONTROL_EDGE?0:AMCL_CONTROL_STALE));++coverage.failed;return;
        }
        CHECK(e.consumer==consumer&&e.target==target);
        CHECK(e.action==2||((e.action!=0)==(owners[indexOf(e)]!=0)));
        cache[indexOf(e)]=e.action!=0;
        CHECK(port->complete(&e,AMCL_CONTROL_STATE_ONLY)==0);
        CHECK(port->complete(&e,AMCL_CONTROL_STATE_ONLY)==0);
        item.written=true;
        if(mode==4){pending.push_back(item);++coverage.delayed;return;}
        CHECK(port->complete(&e,AMCL_CONTROL_STATE_FINAL)==0);
    }
    // 新资源拥有空的目标缓存；旧已claim回执仍在调度器里，用来检查迟到完成不能回灌。
    void reset(unsigned mode){
        record("resource-reset mode="+std::to_string(mode));
        if(mode==0){++target;CHECK(port->bindTarget(consumer,target)==0);++coverage.rebound;}
        else if(mode==1){port->abandon(consumer);++coverage.rebound;}
        else{
            const uint64_t old=consumer;port->close(old);CHECK(port->query(old,1,0)==AMCL_CONTROL_STALE);
            CHECK(port->open(backend,++target,&consumer)==0&&consumer!=old);accepted=0;++coverage.closed;
            // 已关闭consumer的所有票只能STALE，显式排除后续调度将旧缓存解释成新缓存。
            for(auto it=pending.begin();it!=pending.end();){
                if(it->emission.consumer==old){CHECK(port->validate(&it->emission)==AMCL_CONTROL_STALE);
                    CHECK(port->complete(&it->emission,3)==AMCL_CONTROL_STALE);it=pending.erase(it);}
                else ++it;
            }
        }
        owners.fill(0);cache.fill(false);
    }
    void tamper(){
        if(pending.empty())return;
        auto e=pending.front().emission;e.scanCode^=1;
        CHECK(port->claim(&e)<0&&port->validate(&e)<0&&port->complete(&e,0)<0);
        ++coverage.tampered;record("tamper original ticket="+std::to_string(e.ticket));
    }
    // 合法poll只观察，不能借读改变owner或消费票；完整视图和scalar计数单独可核对。
    void poll(){
        std::array<uint8_t,16> keys{};std::array<uint8_t,8> buttons{};
        for(size_t i=0;i<controlCount;++i)if(i<16)keys[i]=cache[i];else buttons[i-16]=cache[i];
        AmclControlSnapshotV1 before{},after{};before.size=after.size=sizeof(before);
        CHECK(port->snapshot(consumer,&before)==0);
        CHECK(port->observePollView(consumer,1,keys.data(),static_cast<uint32_t>(keys.size()))==0);
        CHECK(port->observePollView(consumer,2,buttons.data(),static_cast<uint32_t>(buttons.size()))==0);
        CHECK(port->observePoll(consumer,1,0,cache[0]?1:0)==0);
        CHECK(port->snapshot(consumer,&after)==0);
        CHECK(after.legalPollReads==before.legalPollReads+3&&after.pollMismatches==before.pollMismatches);
        ++coverage.polls;
    }
    void run(size_t steps){
        for(step=0;step<steps;++step){
            const auto op=random.pick(100);
            // C++函数实参求值顺序不固定，随机数必须先顺序取值再调用，才能跨编译器重放。
            if(op<55){const auto key=random.pick(controlCount);const auto source=random.pick(6);
                const int action=random.pick(10)==0?2:static_cast<int>(random.pick(2));apply(key,source,action);}
            else if(op<65)service(random.pick(7));
            else if(op<74){const uint32_t masks[]={1,6,8,15};const auto s=sources[random.pick(6)];
                const auto mask=masks[random.pick(4)];const auto only=random.pick(2);const auto selectedKind=random.pick(3);
                retire(mask,s.id,only,selectedKind);}
            else if(op==74)retire(15,0,0,0);
            else if(op<78)reset(op-75);
            else if(op<82)tamper();
            else if(op<86)poll();
            else if(op<90)service(4);
            else if(op<96){const auto key=random.pick(controlCount);const auto source=random.pick(6);apply(key,source,2);}
            if(step%3==0)service(random.pick(7));
            while(pending.size()>64)service(6);
            verify();
        }
        while(!pending.empty()){service(6);verify();}
        retire(15,0,0,0);while(!pending.empty()){service(6);verify();}
        verify();for(bool held:cache)CHECK(!held);
    }
};

// 固定前缀把反控绑定到明确不变量。编译成功后的旧完成越权、跨source清空及重复claim
// 必须命中这些断言；不能用编译错误或未知崩溃充当测试会报错的证明。
void directed(){
    uint64_t c=0;CHECK(port->open(1,42,&c)==0);AmclControlEmissionV1 down{},up{},ignored{};
    CHECK(port->apply(c,1,0,1,0,0,1,&down)==1&&port->claim(&down)==1);
    CHECK(port->claim(&down)==AMCL_CONTROL_REJECTED);
    CHECK(port->apply(c,1,0,1,0,0,0,&up)==1&&port->claim(&up)==1&&port->complete(&up,3)==0);
    CHECK(port->complete(&down,1)==AMCL_CONTROL_STALE);
    CHECK(port->queryDelivered(c,1,0)==0);
    CHECK(port->apply(c,1,0,1,0,0,1,&down)==1&&port->claim(&down)==1&&port->complete(&down,3)==0);
    CHECK(port->apply(c,2,0,1,0,0,1,&ignored)==0);
    CHECK(port->retire(c,AMCL_CONTROL_MASK_TYPED,0,0)==0&&port->query(c,1,0)==1);
    port->close(c);
}

// 真实2048票容量耗尽与最后UP失败组合：拒绝不得摘掉原owner或建立新control的假owner。
// 逐一真实claim/终结释放票后，原UP与新control恢复可用，证明长序列不是靠重启掩盖泄漏。
void pressure(){
    uint64_t c=0;CHECK(port->open(3,99,&c)==0);AmclControlEmissionV1 e{};
    CHECK(port->apply(c,1,0,1,0,0,1,&e)==1&&port->claim(&e)==1&&port->complete(&e,3)==0);
    std::vector<AmclControlEmissionV1> tickets;
    for(size_t i=0;i<2048;++i){CHECK(port->apply(c,1,0,1,0,0,2,&e)==1);tickets.push_back(e);}
    CHECK(port->apply(c,2,0,1,1,0,1,&e)==AMCL_CONTROL_PRESSURE&&e.ticket==0&&port->query(c,1,1)==0);
    CHECK(port->apply(c,1,0,1,0,0,0,&e)==AMCL_CONTROL_PRESSURE&&port->query(c,1,0)==1);
    for(const auto& ticket:tickets)CHECK(port->claim(&ticket)==1&&port->complete(&ticket,5)==0);
    CHECK(port->apply(c,1,0,1,0,0,0,&e)==1&&port->claim(&e)==1&&port->complete(&e,3)==0);
    CHECK(port->queryDelivered(c,1,0)==0);
    CHECK(port->apply(c,2,0,1,1,0,1,&e)==1&&port->claim(&e)==1&&port->complete(&e,3)==0);
    port->close(c);
}

/**
 * 停止普通消费后验证原目标退休与目标替换的不同收束权限。未claim的满票可由已有
 * 全域退休撤销并产生原目标UP；已claim的副作用不能假装取消，只能明确压力拒绝，
 * 待真实资源替换后围栏旧完成。兄弟consumer始终保持自己的同码持有。
 */
void pressureRetirement(){
    for(bool claimed: {false,true}){
        uint64_t c=0,sibling=0;AmclControlEmissionV1 down{},edge{};
        CHECK(port->open(3,99,&c)==0&&port->open(1,88,&sibling)==0);
        CHECK(port->apply(c,1,0,1,0,0,1,&down)==1&&port->claim(&down)==1&&port->complete(&down,3)==0);
        CHECK(port->apply(sibling,1,0,1,0,0,1,&edge)==1&&port->claim(&edge)==1&&port->complete(&edge,3)==0);
        std::vector<AmclControlEmissionV1> tickets;
        for(size_t i=0;i<2048;++i){
            CHECK(port->apply(c,1,0,1,0,0,2,&edge)==1);
            if(claimed)CHECK(port->claim(&edge)==1);
            tickets.push_back(edge);
        }
        CHECK(port->apply(c,1,0,1,0,0,0,&edge)==AMCL_CONTROL_PRESSURE);
        if(!claimed){
            // 无新正常输入、无普通票完成：现有全域退休回收未进入ABI的计划，原目标可送UP。
            CHECK(port->retire(c,AMCL_CONTROL_MASK_ALL,0,0)==0);
            CHECK(port->nextRetired(c,&edge)==1&&edge.action==AMCL_CONTROL_UP&&edge.target==99);
            CHECK(port->claim(&edge)==1&&port->complete(&edge,3)==0);
            CHECK(port->queryDelivered(c,1,0)==0&&port->nextRetired(c,&edge)==0);
            for(const auto& old:tickets)CHECK(port->claim(&old)<0);
        }else{
            // 全部票已进入ABI时仍诚实拒绝；不能把实际可能在执行的旧副作用伪报成释放。
            CHECK(port->retire(c,AMCL_CONTROL_MASK_ALL,0,0)==AMCL_CONTROL_PRESSURE);
            CHECK(port->query(c,1,0)==1&&port->queryDelivered(c,1,0)==1);
            CHECK(port->bindTarget(c,100)==0);
            CHECK(port->complete(&tickets.front(),AMCL_CONTROL_CALLBACK_RETURNED)==AMCL_CONTROL_STALE);
            CHECK(port->apply(c,2,0,1,0,0,1,&edge)==1&&edge.target==100);
            CHECK(port->claim(&edge)==1&&port->complete(&edge,3)==0);
            for(size_t i=1;i<tickets.size();++i)
                CHECK(port->complete(&tickets[i],AMCL_CONTROL_CALLBACK_RETURNED)==AMCL_CONTROL_STALE);
            CHECK(port->query(c,1,0)==1&&port->queryDelivered(c,1,0)==1);
            CHECK(port->nextRetired(c,&edge)==0);
        }
        CHECK(port->query(sibling,1,0)==1&&port->queryDelivered(sibling,1,0)==1);
        port->close(c);port->close(sibling);
    }
}
}

// 可显式指定十进制/0x种子及步数重放。默认12个固定种子分别跑三个backend身份；这些
// 数字只选择端口命名空间，不代表这里调用了真实GLFW/SDL/JNI消费链。
int main(int argc,char** argv){
    size_t steps=10000;std::vector<uint64_t> seeds={1,7,19,73,101,313,997,4099,
        UINT64_C(0x123456789),UINT64_C(0x1badf00d),UINT64_C(0x9e3779b97f4a7c15),UINT64_C(0xfeedface)};
    if(argc!=1&&argc!=3){std::cerr<<"usage: sequence [seed steps]\n";return 2;}
    if(argc==3){char* end=nullptr;const auto value=std::strtoull(argv[1],&end,0);
        if(!value||!end||*end)return 2;seeds={value};steps=std::strtoull(argv[2],&end,0);
        if(!steps||steps>1000000||!end||*end)return 2;}
    const auto* actual=amclControlDeliveryGetPortV1();amclControlDeliveryPublishV1();
    CHECK(amclControlDeliveryResolveV1(&port)==0&&port==actual&&port->verifyOwner(port->ownerHost)==0);
    directed();pressure();pressureRetirement();
    for(auto value:seeds)for(backend=1;backend<=3;++backend){
        seed=value;trace.clear();Sequence sequence(seed);sequence.run(steps);
        std::cout<<"PASS seed="<<seed<<" backend="<<backend<<" steps="<<steps<<'\n';
    }
    CHECK(coverage.accepted&&coverage.rejected&&coverage.failed&&coverage.delayed&&coverage.stale&&
        coverage.retired&&coverage.rebound&&coverage.closed&&coverage.tampered&&coverage.polls);
    std::cout<<"SEQUENCE PASS events="<<seeds.size()*3*steps<<" accepted="<<coverage.accepted
        <<" rejected="<<coverage.rejected<<" failed="<<coverage.failed<<" delayed="<<coverage.delayed
        <<" stale="<<coverage.stale<<" retired="<<coverage.retired<<" rebound="<<coverage.rebound
        <<" closed="<<coverage.closed<<" tampered="<<coverage.tampered<<" polls="<<coverage.polls<<'\n';
}
