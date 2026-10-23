// 同TU引入完整生产owner，仅对真实私有registry做临界身份/继承锁故障注入。
// 不提供第二归约算法，也不给产品增加测试setter。
#include "../../input/delivery/control_delivery.cpp"
#include "../../input/adapters/glfw_source_plane_aggregate.cpp"
#include <iostream>
#include <thread>
#include <chrono>
#ifndef _WIN32
#include <sys/wait.h>
#include <signal.h>
#endif
#define CHECK(v) do{if(!(v)){std::cerr<<"CONTROL IDENTITY BOUNDARY "<<__LINE__<<": "<<#v<<'\n';std::exit(1);}}while(false)

int main(){
    const auto* p=amclControlDeliveryGetPortV1();amclControlDeliveryPublishV1();CHECK(p);
    uint64_t c=0;CHECK(p->open(1,42,&c)==0);AmclControlEmissionV1 down{};
    CHECK(p->apply(c,1,0,1,65,30,1,&down)==1);CHECK(p->claim(&down)==1);CHECK(p->complete(&down,3)==0);
    {
        auto& r=registry();std::lock_guard<std::mutex> lock(r.mutex);
        // 最后一个合法activation仍可发票；下一次全scope/target转换必须明确拒绝。
        r.consumers.at(c).stats.activation=UINT64_MAX;
    }
    CHECK(p->bindTarget(c,43)==AMCL_CONTROL_PRESSURE);
    CHECK(p->retire(c,AMCL_CONTROL_MASK_ALL,0,0)==AMCL_CONTROL_PRESSURE);
    AmclControlSnapshotV1 facts{};facts.size=sizeof(facts);CHECK(p->snapshot(c,&facts)==0);
    CHECK(facts.activation==UINT64_MAX&&facts.target==42&&p->query(c,1,65)==1);
    // 单kind退休不需要新activation，仍沿原identity完整释放。
    CHECK(p->retireKind(c,AMCL_CONTROL_MASK_ALL,0,0,1)==0);
    AmclControlEmissionV1 release{};CHECK(p->nextRetired(c,&release)==1);
    CHECK(release.activation==UINT64_MAX&&p->claim(&release)==1&&p->complete(&release,3)==0);
    p->abandon(c);CHECK(p->snapshot(c,&facts)==AMCL_CONTROL_STALE);
    uint64_t next=0;CHECK(p->open(1,42,&next)==0&&next!=c);p->close(next);
    {
        // 真实GLFW facade不可忽略bind压力，在新window目标上继续用旧票写cache。
        amcl::input::GlfwSourcePlaneAggregate aggregate;aggregate.BindTarget(42);
        int calls=0;amcl::input::GlfwAggregateSink sink{};sink.context=&calls;
        sink.key=[](void* value,const amcl::input::GlfwAggregateKeyEvent&){++*static_cast<int*>(value);};
        aggregate.SubmitKey(amcl::input::GlfwSourcePlane::kLegacy,70,0,
            amcl::input::GlfwAggregateAction::kPress,0,sink);
        CHECK(calls==1&&aggregate.Snapshot(facts));
        {
            auto& r=registry();std::lock_guard<std::mutex> lock(r.mutex);
            r.consumers.at(facts.consumer).stats.activation=UINT64_MAX;
        }
        aggregate.BindTarget(43);
        aggregate.SubmitKey(amcl::input::GlfwSourcePlane::kTyped,71,0,
            amcl::input::GlfwAggregateAction::kPress,0,sink);
        CHECK(calls==1&&p->query(facts.consumer,1,71)==0);
    }

#ifndef _WIN32
    CHECK(p->open(1,55,&c)==0);
    CHECK(p->apply(c,1,0,1,66,31,1,&down)==1);CHECK(p->claim(&down)==1);
    std::atomic<bool> held{false},unlock{false};
    std::thread blocker([&]{std::lock_guard<std::mutex> lock(registry().mutex);held.store(true,std::memory_order_release);
        while(!unlock.load(std::memory_order_acquire))std::this_thread::yield();});
    while(!held.load(std::memory_order_acquire))std::this_thread::yield();
    const pid_t child=fork();CHECK(child>=0);
    if(child==0){
        // child内只有fork发起线程。若任一入口先碰继承mutex，它不可能自己解锁。
        bool good=amclControlDeliveryGetPortV1()==nullptr&&amclControlDeliveryBindSessionV1(1)==AMCL_CONTROL_STALE;
        uint64_t opened=1;good=good&&p->open(1,55,&opened)==AMCL_CONTROL_NOT_READY&&opened==0;
        good=good&&p->verifyOwner(p->ownerHost)==AMCL_CONTROL_NOT_READY;
        good=good&&p->bindTarget(c,56)==AMCL_CONTROL_STALE&&p->apply(c,1,0,1,67,0,1,&release)==AMCL_CONTROL_STALE;
        good=good&&p->retire(c,15,0,0)==AMCL_CONTROL_STALE&&p->retireKind(c,15,0,0,1)==AMCL_CONTROL_STALE;
        good=good&&p->nextRetired(c,&release)==AMCL_CONTROL_STALE&&p->claim(&down)==AMCL_CONTROL_STALE;
        good=good&&p->validate(&down)==AMCL_CONTROL_STALE&&p->complete(&down,3)==AMCL_CONTROL_STALE;
        good=good&&p->query(c,1,66)==AMCL_CONTROL_STALE&&p->queryDelivered(c,1,66)==AMCL_CONTROL_STALE;
        const uint8_t view[1]{};good=good&&p->observePoll(c,1,66,0)==AMCL_CONTROL_STALE;
        good=good&&p->observePollView(c,1,view,1)==AMCL_CONTROL_STALE&&p->snapshot(c,&facts)==AMCL_CONTROL_STALE;
        p->close(c);p->abandon(c);amclControlDeliveryPublishV1();_exit(good?0:3);
    }
    int status=0;bool finished=false;
    for(int attempt=0;attempt<100;++attempt){if(waitpid(child,&status,WNOHANG)==child){finished=true;break;}
        std::this_thread::sleep_for(std::chrono::milliseconds(10));}
    if(!finished){kill(child,SIGKILL);waitpid(child,&status,0);}
    unlock.store(true,std::memory_order_release);blocker.join();
    CHECK(finished&&WIFEXITED(status)&&WEXITSTATUS(status)==0);
    // child拒绝不得损坏原进程的真实待交付票或函数表pid。
    CHECK(p->pid==pid()&&p->complete(&down,3)==0);p->close(c);
    std::cout<<"PASS bounded fork child: every inherited owner entry rejected before held mutex\n";
#endif
    std::cout<<"PASS activation MAX: no wrapping target/retire/abandon identity\n";
}
