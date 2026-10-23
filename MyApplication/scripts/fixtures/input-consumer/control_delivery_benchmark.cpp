// 输入末级归约的宿主性能样本。链接完整生产facade；此sink只代替窗口缓存与用户回调，
// 因而结果是本机同步归约/完成开销，不是OHOS游戏、真实ABI或touch-to-photon时延。
#include "glfw_source_plane_aggregate.h"
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>
#include <string>
#ifdef AMCL_BENCH_CURRENT
#include "delivery/control_delivery_client.h"
#endif
using namespace amcl::input;
using Clock = std::chrono::steady_clock;
static GlfwSourcePlaneAggregate* aggregate = nullptr;
static int keys[512]{};
static uint64_t callbacks = 0;

// 两版都写同一模拟窗口cache并执行同样回调工作；新版额外按真实私有票报告实际完成。
// 不把Submit返回当已输出；每个测量批次最后检查cache与callback数量，禁止空操作变快。
static void keySink(void*, const GlfwAggregateKeyEvent& event) {
    keys[event.key] = event.action == GlfwAggregateAction::kRelease ? 0 : 1;
#ifdef AMCL_BENCH_CURRENT
    aggregate->Complete(event.receipt, AMCL_CONTROL_STATE_ONLY);
#endif
    ++callbacks;
#ifdef AMCL_BENCH_CURRENT
    aggregate->Complete(event.receipt, AMCL_CONTROL_CALLBACK_RETURNED);
#endif
}

// 同步真实facade接口，无producer队列或渲染等待；统计覆盖一次提交至sink/receipt结束。
static void submit(GlfwSourcePlane plane, int code, GlfwAggregateAction action,
                   const GlfwAggregateSink& sink) {
    aggregate->SubmitKey(plane, code, 30, action, 0, sink);
}

// 输出原始整数ns序列供外部计算分位数；不扣掉时钟开销、不因结果较慢而跳过样本。
// 单键路径与256键已持有的共持路径分别计时，真实NoEdge和首按末松均纳入，warmup排除。
static void measure(const char* name, bool crowded, unsigned count, const GlfwAggregateSink& sink) {
    aggregate->ClearAll(sink);
    callbacks = 0;
    if (crowded) for (int code = 1; code <= 256; ++code)
        submit(GlfwSourcePlane::kTyped, code, GlfwAggregateAction::kPress, sink);
    const uint64_t before = callbacks;
    std::vector<int64_t> samples;
    samples.reserve(count);
    for (unsigned index = 0; index < count + 1000; ++index) {
        const auto start = Clock::now();
        submit(GlfwSourcePlane::kLegacy, 65, GlfwAggregateAction::kPress, sink);
        submit(GlfwSourcePlane::kLegacy, 65, GlfwAggregateAction::kRelease, sink);
        const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now()-start).count();
        if (index >= 1000) samples.push_back(elapsed);
    }
    const uint64_t expected = crowded ? 0 : static_cast<uint64_t>(count + 1000) * 2;
    if (callbacks - before != expected || keys[65] != (crowded ? 1 : 0)) {
        std::cerr << "真实提交未产生预期cache/边沿，测量无效\n";
        std::exit(2);
    }
    std::cout << name << ' ' << samples.size();
    for (const auto value : samples) std::cout << ' ' << value;
    std::cout << '\n';
    aggregate->ClearAll(sink);
    for (const int held : keys) if (held != 0) std::exit(3);
}

// 单独保留两次时钟读取的原始开销和量化；不从业务样本扣除，也不将0ns解释为免费操作。
static void calibrateClock() {
    std::cout << "clock-read-pair 10000";
    for (unsigned index = 0; index < 10000; ++index) {
        const auto start = Clock::now();
        const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now()-start).count();
        std::cout << ' ' << elapsed;
    }
    std::cout << '\n';
}


#ifdef AMCL_BENCH_CURRENT
// 这些场景只属于当前中立端口，没有为旧facade编造同名功能。每个样本包含列明的
// 真实调用和结果检查；warmup不计入10000个样本，完整原值由父脚本保留，不扣时钟。
static void requireBench(bool value) {
    if (!value) { std::cerr << "当前生产热点结果不符，拒绝性能样本\n"; std::exit(4); }
}
template<class Work> static void measureCurrent(const char* name, Work work) {
    std::vector<int64_t> values; values.reserve(10000);
    for (unsigned i=0;i<11000;++i) {
        const auto start=Clock::now();work();
        const auto elapsed=std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now()-start).count();
        if(i>=1000)values.push_back(elapsed);
    }
    std::cout<<name<<' '<<values.size();for(auto value:values)std::cout<<' '<<value;std::cout<<'\n';
}

// descriptor完整Resolve、scalar/整view观察和在途票数量分别测量。这里只用已接纳的
// 256键缓存及0/64/1024张原claim票作为负载；不触碰队列上限、不引入生产测量hook。
static void measureNeutralHotpaths() {
    const AmclControlDeliveryPortV1* port=nullptr;
    requireBench(amclControlDeliveryResolveV1(&port)==0&&port!=nullptr);
    measureCurrent("current-port-resolve",[&] {
        const AmclControlDeliveryPortV1* resolved=nullptr;
        requireBench(amclControlDeliveryResolveV1(&resolved)==0&&resolved==port);
    });
    uint64_t consumer=0;requireBench(port->open(1,314,&consumer)==0);
    uint8_t view[512]{};
    for(int key=1;key<=256;++key) {
        AmclControlEmissionV1 e{};
        requireBench(port->apply(consumer,2,0,1,key,30,1,&e)==1&&port->claim(&e)==1&&port->complete(&e,3)==0);
        view[key]=1;
    }
    measureCurrent("current-delivered-query",[&] {requireBench(port->queryDelivered(consumer,1,65)==1);});
    AmclControlSnapshotV1 before{},after{};before.size=after.size=sizeof(before);
    requireBench(port->snapshot(consumer,&before)==0);
    measureCurrent("current-scalar-observe",[&] {requireBench(port->observePoll(consumer,1,65,1)==0);});
    measureCurrent("current-view-observe-256",[&] {requireBench(port->observePollView(consumer,1,view,512)==0);});
    requireBench(port->snapshot(consumer,&after)==0&&after.legalPollReads-before.legalPollReads==22000&&after.pollMismatches==0);
    std::vector<AmclControlEmissionV1> pending;
    for(unsigned count:{0u,64u,1024u}) {
        while(pending.size()<count) {
            AmclControlEmissionV1 e{};
            requireBench(port->apply(consumer,2,0,1,1,30,2,&e)==1&&port->claim(&e)==1);pending.push_back(e);
        }
        const std::string name="current-shared-pair-pending-"+std::to_string(count);
        measureCurrent(name.c_str(),[&] {
            AmclControlEmissionV1 e{};
            requireBench(port->apply(consumer,1,0,1,65,30,1,&e)==0);
            requireBench(port->apply(consumer,1,0,1,65,30,0,&e)==0);
        });
        requireBench(port->query(consumer,1,65)==1&&port->queryDelivered(consumer,1,65)==1);
    }
    // 在途票确实结束后再退休实际缓存；不能靠close丢掉状态而谎称测量执行了完整清理。
    for(const auto& e:pending)requireBench(port->complete(&e,AMCL_CONTROL_DISCARDED)==0);
    requireBench(port->retire(consumer,15,0,0)==0);AmclControlEmissionV1 e{};unsigned releases=0;
    while(port->nextRetired(consumer,&e)==1){requireBench(port->claim(&e)==1&&port->complete(&e,3)==0);++releases;}
    requireBench(releases==256&&port->queryDelivered(consumer,1,65)==0);port->close(consumer);
}
#endif

// 新版初始化真实Core/neutral进程身份，旧版使用其完整旧生产归约。两版相同场景与优化。
// 单进程不并行跑两版，父编排交替执行顺序；这里不修改墙钟或平台全局环境。
int main() {
#ifdef AMCL_BENCH_CURRENT
    amclControlDeliveryPublishV1();
#endif
    GlfwSourcePlaneAggregate value;
    aggregate = &value;
#ifdef AMCL_BENCH_CURRENT
    value.BindTarget(42);
#endif
    int context = 42;
    GlfwAggregateSink sink{&context, keySink, nullptr};
    calibrateClock();
    measure("single-key-pair", false, 10000, sink);
    measure("shared-key-pair-256-held", true, 10000, sink);
#ifdef AMCL_BENCH_CURRENT
    measureNeutralHotpaths();
#endif
}
