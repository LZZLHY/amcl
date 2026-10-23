// 直接驱动真实neutral/Core owner与跨模块端口，不在测试中重写贡献状态机。
#include "../../input/delivery/control_delivery_client.h"
#include <cstdlib>
#include <iostream>
#define CHECK(v) do{if(!(v)){std::cerr<<"CONTROL DELIVERY FAIL "<<__LINE__<<": "<<#v<<'\n';std::exit(1);}}while(false)
int main(){
    const auto* actual=amclControlDeliveryGetPortV1();amclControlDeliveryPublishV1();
    const AmclControlDeliveryPortV1* p=nullptr;CHECK(amclControlDeliveryResolveV1(&p)==0&&p==actual);
    CHECK(p->verifyOwner(p->ownerHost)==0&&p->verifyOwner(1)<0);
    uint64_t c=0;CHECK(p->open(1,42,&c)==0&&c);
    AmclControlEmissionV1 down{},ignored{},up{};
    // 唯一pending PRESS不能因另一路共持的NoEdge而失效。
    CHECK(p->apply(c,1,0,1,65,0,1,&down)==1);
    CHECK(p->apply(c,2,0,1,65,30,1,&ignored)==0&&ignored.ticket==0);
    CHECK(p->claim(&down)==1);CHECK(p->complete(&down,0)==0);CHECK(p->complete(&down,1)==0);
    CHECK(p->apply(c,2,0,1,65,0,1,&ignored)==AMCL_CONTROL_REJECTED);
    CHECK(p->apply(c,2,0,1,66,0,2,&ignored)==AMCL_CONTROL_REJECTED);
    CHECK(p->apply(c,1,0,1,66,0,0,&ignored)==AMCL_CONTROL_REJECTED);
    // 末级已交付按住，准备末松但新holder在释放执行前回入：不能补PRESS，也不能松新holder。
    CHECK(p->retire(c,AMCL_CONTROL_MASK_TYPED,0,0)==0);
    CHECK(p->retire(c,AMCL_CONTROL_MASK_LEGACY,0,0)==0);
    CHECK(p->apply(c,2,0,1,65,30,1,&ignored)==0);
    CHECK(p->nextRetired(c,&up)==0&&p->query(c,1,65)==1);
    CHECK(p->observePoll(c,1,65,1)==0);
    CHECK(p->apply(c,2,0,1,65,0,0,&up)==1);CHECK(p->claim(&up)==1);
    // 同步callback已经进入释放，重入的真实新DOWN必须在它后面形成新PRESS。
    CHECK(p->apply(c,1,0,1,65,0,1,&down)==1);CHECK(p->claim(&down)==1);
    CHECK(p->complete(&down,0)==0);CHECK(p->complete(&down,1)==0);
    CHECK(p->complete(&up,1)==AMCL_CONTROL_STALE&&p->query(c,1,65)==1);
    AmclControlSnapshotV1 stats{};stats.size=sizeof(stats);CHECK(p->snapshot(c,&stats)==0);
    CHECK(stats.callbackReturned==3&&stats.legalPollReads==1&&stats.staleCompletions==1);
    // 原target/consumer退休后，旧句柄不能作用于新目标或被query算成合法poll。
    CHECK(p->bindTarget(c,43)==0);CHECK(p->claim(&down)<0);CHECK(p->query(c,1,65)==0);
    p->close(c);CHECK(p->query(c,1,65)==AMCL_CONTROL_STALE);
    // 真实owner已claim但尚无STATE_ONLY回报；保守退休须保存原合法在途投影并产合法UP。
    // 本例只驱动真实owner，没有执行SDK缓存写入，也不证明实际消费层存在同步回报间隙。
    CHECK(p->open(3,87,&c)==0);
    CHECK(p->apply(c,1,0,1,68,31,1,&down)==1&&p->claim(&down)==1);
    CHECK(p->queryDelivered(c,1,68)==0);
    CHECK(p->retire(c,AMCL_CONTROL_MASK_ALL,0,0)==0);
    CHECK(p->nextRetired(c,&up)==1&&up.action==AMCL_CONTROL_UP&&p->claim(&up)==1);
    CHECK(p->complete(&up,3)==0&&p->queryDelivered(c,1,68)==0);
    CHECK(p->complete(&down,1)==AMCL_CONTROL_STALE);p->close(c);
    // 架构旧ResetBatch反例按新receipt表达：旧UP回调期间完整的新DOWN/UP脉冲结束后，
    // 旧完成依然失权，不能因最终desired同为0而偷回票据或多发一个尾UP。
    CHECK(p->open(1,88,&c)==0);
    CHECK(p->apply(c,1,0,1,69,31,1,&down)==1&&p->claim(&down)==1&&p->complete(&down,3)==0);
    CHECK(p->retire(c,AMCL_CONTROL_MASK_ALL,0,0)==0&&p->nextRetired(c,&up)==1&&p->claim(&up)==1);
    AmclControlEmissionV1 newUp{};
    CHECK(p->apply(c,2,0,1,69,31,1,&down)==1&&p->claim(&down)==1&&p->complete(&down,3)==0);
    const int newUpApply=p->apply(c,2,0,1,69,0,0,&newUp);
    const int newUpClaim=newUpApply==1?p->claim(&newUp):-999;
    const int newUpComplete=newUpClaim==1?p->complete(&newUp,3):-999;
    if(newUpApply!=1||newUpClaim!=1||newUpComplete!=0)std::cerr<<"new pulse: apply="<<newUpApply<<" claim="<<newUpClaim
        <<" complete="<<newUpComplete<<" desired="<<p->query(c,1,69)<<" delivered="<<p->queryDelivered(c,1,69)<<'\n';
    CHECK(newUpApply==1&&newUpClaim==1&&newUpComplete==0);
    CHECK(p->complete(&up,3)==AMCL_CONTROL_STALE&&p->query(c,1,69)==0&&p->queryDelivered(c,1,69)==0);
    CHECK(p->nextRetired(c,&up)==0);p->close(c);
    // 原target一次退休后，key与button的旧票都不能在后来target生效。
    CHECK(p->open(3,91,&c)==0);
    CHECK(p->apply(c,1,0,1,70,31,1,&down)==1&&p->claim(&down)==1&&p->complete(&down,3)==0);
    CHECK(p->apply(c,2,0,2,1,0,1,&down)==1&&p->claim(&down)==1&&p->complete(&down,3)==0);
    CHECK(p->retire(c,AMCL_CONTROL_MASK_ALL,0,0)==0&&p->nextRetired(c,&up)==1);
    // bind会直接丢弃尚未claim的旧票；已删除票可返回Rejected，仍必须严格拒绝执行。
    CHECK(p->bindTarget(c,92)==0&&p->claim(&up)<0);
    CHECK(p->query(c,1,70)==0&&p->query(c,2,1)==0&&p->nextRetired(c,&up)==0);p->close(c);
    // 独审交付的同revision repeat反例：A已退休、B desired仍held，但两次DOWN均未写cache。
    // 第三个合法owner必须得到修复DOWN，不能借失权A的repeat假装actual已held。
    // contact-key是owner ABI支持的合同输入，不据此宣称当前游戏键盘会产生该来源。
    CHECK(p->open(1,93,&c)==0);
    CHECK(p->apply(c,1,0,1,69,31,1,&down)==1&&p->claim(&down)==1&&p->complete(&down,AMCL_CONTROL_DISCARDED)==0);
    CHECK(p->apply(c,2,0,1,69,31,1,&down)==1&&p->claim(&down)==1&&p->complete(&down,AMCL_CONTROL_DISCARDED)==0);
    AmclControlEmissionV1 repeat{};
    CHECK(p->apply(c,1,0,1,69,31,2,&repeat)==1&&p->claim(&repeat)==1);
    CHECK(p->retire(c,AMCL_CONTROL_MASK_LEGACY,0,0)==0&&p->validate(&repeat)==AMCL_CONTROL_STALE);
    CHECK(p->apply(c,AMCL_CONTROL_CONTACT,77,1,69,31,1,&down)==1&&down.action==AMCL_CONTROL_DOWN);
    CHECK(p->claim(&down)==1&&p->complete(&down,AMCL_CONTROL_STATE_FINAL)==0&&p->queryDelivered(c,1,69)==1);
    CHECK(p->complete(&repeat,AMCL_CONTROL_DISCARDED)==AMCL_CONTROL_STALE);
    CHECK(p->apply(c,AMCL_CONTROL_CONTACT,77,1,69,0,0,&ignored)==0);
    CHECK(p->apply(c,2,0,1,69,0,0,&up)==1&&p->claim(&up)==1&&p->complete(&up,3)==0);p->close(c);
    // 两路首按均未交付时，退出其中一路仍应修复剩余holder的DOWN。
    // source UP不能成为伪UP票：它会被claim判STALE而使剩余贡献永远未交付。
    for(uint32_t failure: {uint32_t(AMCL_CONTROL_DISCARDED),uint32_t(AMCL_CONTROL_UNCERTAIN)}){
        CHECK(p->open(2,99,&c)==0);
        CHECK(p->apply(c,1,0,1,90,0,1,&down)==1&&p->claim(&down)==1&&p->complete(&down,failure)==0);
        CHECK(p->apply(c,2,0,1,90,30,1,&down)==1&&p->claim(&down)==1&&p->complete(&down,failure)==0);
        CHECK(p->query(c,1,90)==1&&p->queryDelivered(c,1,90)==0);
        CHECK(p->apply(c,1,0,1,90,0,0,&down)==1&&down.action==AMCL_CONTROL_DOWN);
        CHECK(p->claim(&down)==1&&p->complete(&down,3)==0);
        CHECK(p->query(c,1,90)==1&&p->queryDelivered(c,1,90)==1);
        CHECK(p->observePoll(c,1,90,1)==0);
        CHECK(p->apply(c,2,0,1,90,0,0,&up)==1&&up.action==AMCL_CONTROL_UP);
        CHECK(p->claim(&up)==1&&p->complete(&up,3)==0&&p->queryDelivered(c,1,90)==0);p->close(c);
    }
    // inverse恢复：DOWN真实写cache，最后UP未写cache而被丢弃，desired空≠实际已释放。
    // 三ABI同一规则：partial source无权松这个orphan，whole consumer资源退休必须收口。
    for(uint32_t backend=1;backend<=3;++backend)for(uint32_t kind=1;kind<=2;++kind){
        CHECK(p->open(backend,99,&c)==0);
        CHECK(p->apply(c,1,0,kind,1,0,1,&down)==1&&p->claim(&down)==1);
        CHECK(p->complete(&down,0)==0&&p->complete(&down,1)==0);
        CHECK(p->apply(c,1,0,kind,1,0,0,&up)==1&&p->claim(&up)==1&&p->complete(&up,5)==0);
        CHECK(p->query(c,kind,1)==0&&p->queryDelivered(c,kind,1)==1);
        CHECK(p->retire(c,AMCL_CONTROL_MASK_TYPED,0,0)==0&&p->nextRetired(c,&up)==0);
        CHECK(p->queryDelivered(c,kind,1)==1);
        CHECK(p->retire(c,AMCL_CONTROL_MASK_ALL,0,0)==0&&p->nextRetired(c,&up)==1);
        CHECK(up.action==AMCL_CONTROL_UP&&p->claim(&up)==1&&p->complete(&up,3)==0);
        CHECK(p->queryDelivered(c,kind,1)==0&&p->observePoll(c,kind,1,0)==0);p->close(c);
    }
    // 压力拒绝不建立假owner；释放后已有有效消费状态仍可合法poll，不重放历史click。
    CHECK(p->open(3,99,&c)==0);
    for(int code=0;code<1024;++code){CHECK(p->apply(c,1,0,1,1000+code,0,1,&down)==1);CHECK(p->claim(&down)==1);CHECK(p->complete(&down,3)==0);}
    CHECK(p->apply(c,1,0,1,3000,0,1,&down)==AMCL_CONTROL_PRESSURE);CHECK(p->query(c,1,3000)==0);
    CHECK(p->observePoll(c,1,1000,1)==0);CHECK(p->retire(c,15,0,0)==0);
    int releases=0;while(p->nextRetired(c,&up)==1){CHECK(p->claim(&up)==1);CHECK(p->complete(&up,3)==0);++releases;}
    CHECK(releases==1024&&p->query(c,1,1000)==0);p->close(c);
    std::cout<<"control_delivery_test: PASS\n";
}
