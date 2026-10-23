/** 直接驱动真实三owner。断言接受前缀与consumer完成口径，不模拟游戏camera/attack。 */
#include "../../input/delivery/look_execution.h"
#include "../../input/amcl_input_api.h"
#include "../../input/amcl_input_host_descriptor.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
#define CHECK(v) do{if(!(v)){std::fprintf(stderr,"LOOK EXECUTION FAIL %d: %s\n",__LINE__,#v);std::exit(1);}}while(false)
bool near(double x,double y){return std::abs(x-y)<1e-8;}
int main(){
    const auto* core=amclInputGetHostApiV1();CHECK(amclInputHostDescriptorPublishV1(core)==0);
    uint64_t epoch=0;CHECK(core->beginSession(&epoch)==0);CHECK(core->publishFocus(1)==0);
    AmclInputSurfacePayload surface{};surface.active=1;surface.widthPx=1280;surface.heightPx=720;surface.density=1;
    surface.validFields=AMCL_INPUT_SURFACE_FIELD_ALL;surface.publicationGeneration=1;CHECK(core->publishSurface(&surface)==0);
    AmclInputEvent context{};context.header.abiVersion=1;context.header.structSize=sizeof(context);
    context.header.eventType=AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED;context.header.source=AMCL_INPUT_SOURCE_SYNTHETIC;
    context.payload.surfaceContext.generation=1;context.payload.surfaceContext.windowId=42;context.payload.surfaceContext.displayId=1;
    context.payload.surfaceContext.widthPx=1280;context.payload.surfaceContext.heightPx=720;context.payload.surfaceContext.density=1;
    context.payload.surfaceContext.validFields=AMCL_INPUT_SURFACE_CONTEXT_FIELD_WINDOW|AMCL_INPUT_SURFACE_CONTEXT_FIELD_DISPLAY|
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_RECT|AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY|AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM;
    CHECK(core->submitEvent(&context)==0);
    const auto* control=amclControlDeliveryGetPortV1();CHECK(control);CHECK(amclControlDeliveryBindSessionV1(1)==0);
    const auto* look=amclLookExecutionGetPortV1();CHECK(look&&look->verifyOwner(look->ownerHost)==0);
    CHECK(look->bindSession(1)==0&&look->publishMode(1,1,1)==0);
    for(uint32_t backend=1;backend<=3;++backend)CHECK(look->setBackendActive(backend,1)==0);
    AmclInputSnapshotV1 facts{};facts.abiVersion=1;facts.structSize=sizeof(facts);CHECK(core->getSnapshot(&facts)==0);
    AmclLookStreamV1 stream{};stream.size=sizeof(stream);stream.source=2;stream.kind=AMCL_LOOK_MAPPED_RATE;
    stream.unit=AMCL_LOOK_VIRTUAL_COUNTS_PER_SECOND;stream.clock=AMCL_LOOK_OWNER_MONOTONIC;stream.device=7;stream.connection=1;
    stream.resource.size=sizeof(stream.resource);stream.resource.grabbed=1;stream.resource.gameSession=1;
    stream.resource.modeEpoch=1;stream.resource.sessionEpoch=facts.sessionEpoch;stream.resource.surfaceEpoch=facts.surfaceEpoch;
    stream.resource.focusEpoch=facts.focusEpoch;stream.resource.context=context.payload.surfaceContext;
    uint64_t a=0,b=0;CHECK(look->openStream(&stream,&a)==0&&a);stream.device=8;CHECK(look->openStream(&stream,&b)==0&&b!=a);
    const AmclLookPolicyV1 policy{sizeof(policy),0,1,0.6,0};CHECK(look->applyPolicy(-1,&policy)==0);
    // 轴t0→动作t10→timer t16：首动作只封10ms；旧pending在action处flush，未来6ms在另一prefix。
    CHECK(look->submitVelocity(a,1080,0,1000000000)==0);
    CHECK(look->submitVelocity(b,0,0,1000000000)==0);
    AmclLookPrefixV1 first{},second{};CHECK(look->sealPrefix(1,1,1010000000,1,&first)==1);
    CHECK(look->sealPrefix(1,2,1016000000,1,&second)==1&&second.token!=first.token);
    for(uint32_t backend=1;backend<=3;++backend){uint64_t c=0;CHECK(control->open(backend,42,&c)==0);CHECK(look->bindConsumer(c,100,50)==0);
        AmclLookEmissionV1 e{};CHECK(look->prepare(c,first.token,&e)==1&&near(e.dx,10.8)&&near(e.x,110.8));
        CHECK(look->claim(&e)==1&&look->claim(&e)==AMCL_LOOK_REJECTED);CHECK(look->complete(&e,0)==0);
        CHECK(look->observePoll(c,e.x,e.y)==0);CHECK(look->complete(&e,backend==1?1:2)==0);
        CHECK(look->prepare(c,first.token,&e)==AMCL_LOOK_REJECTED);
        CHECK(look->prepare(c,second.token,&e)==1&&near(e.dx,6.48)&&near(e.x,117.28));
        CHECK(look->claim(&e)==1);CHECK(control->bindTarget(c,43)==0);
        CHECK(look->validate(&e)==AMCL_LOOK_STALE&&look->complete(&e,5)==AMCL_LOOK_STALE);
        look->closeConsumer(c);control->close(c);}
    // 一设备退休不丢兄弟速率；相反设备的总和为零也不靠除法分配。
    CHECK(look->retireStream(a)==0);CHECK(look->submitVelocity(b,1080,0,1016000000)==0);
    AmclLookPrefixV1 sibling{};CHECK(look->sealPrefix(1,3,1026000000,1,&sibling)==1);
    uint64_t c=0;CHECK(control->open(1,42,&c)==0&&look->bindConsumer(c,0,0)==0);
    AmclLookEmissionV1 e{};CHECK(look->prepare(c,sibling.token,&e)==1&&near(e.dx,10.8));
    CHECK(look->claim(&e)==1&&look->complete(&e,3)==0);
    // prepare后热拔一来源：旧票未claim仍能准确撤销，不清兄弟；GC等实际consumer最终完成。
    stream.device=10;uint64_t extra=0;CHECK(look->openStream(&stream,&extra)==0);
    CHECK(look->submitVelocity(extra,1080,0,1026000000)==0);
    AmclLookPrefixV1 shared{};CHECK(look->sealPrefix(1,4,1036000000,1,&shared)==1);
    amclLookExecutionSetRecipientsV1(shared.token,1);CHECK(look->prepare(c,shared.token,&e)==1&&near(e.dx,21.6));
    CHECK(look->retireStream(extra)==0&&look->claim(&e)==AMCL_LOOK_STALE);
    CHECK(look->complete(&e,AMCL_CONTROL_DISCARDED)==0&&look->retirePrefix(shared.token)==AMCL_LOOK_NOT_READY);
    CHECK(look->prepare(c,shared.token,&e)==1&&near(e.dx,10.8));
    CHECK(look->claim(&e)==1&&look->complete(&e,AMCL_CONTROL_STATE_FINAL)==0&&look->retirePrefix(shared.token)==0);
    // L2 Mouse独立关闭/重建不能重新领取仍为SDL保留的旧token，不影响同control的Keyboard。
    uint64_t mouse=0,sdl=0;CHECK(control->open(2,42,&mouse)==0&&look->bindConsumer(mouse,0,0)==0);
    AmclLookPrefixV1 oldMouse{};CHECK(look->sealPrefix(1,5,1046000000,1,&oldMouse)==1);
    amclLookExecutionSetRecipientsV1(oldMouse.token,6);look->closeConsumer(mouse);
    CHECK(look->bindConsumer(mouse,0,0)==0&&look->prepare(mouse,oldMouse.token,&e)==AMCL_LOOK_STALE);
    CHECK(look->retirePrefix(oldMouse.token)==AMCL_LOOK_NOT_READY);
    CHECK(control->open(3,42,&sdl)==0&&look->bindConsumer(sdl,0,0)==0&&look->prepare(sdl,oldMouse.token,&e)==1);
    CHECK(look->claim(&e)==1&&look->complete(&e,AMCL_CONTROL_STATE_FINAL)==0&&look->retirePrefix(oldMouse.token)==0);
    // strict gyro租约只比较自己的STARTUP样本时序，不将数值小的sensor ns与mapped MONO排序。
    AmclLookStreamV1 gyro{};gyro.size=sizeof(gyro);gyro.source=1;gyro.kind=AMCL_LOOK_GYRO_DELTA;
    gyro.unit=AMCL_LOOK_VIRTUAL_COUNTS;gyro.clock=AMCL_LOOK_SENSOR_STARTUP;gyro.reserved=AMCL_LOOK_STREAM_POLICY_LEASE;
    gyro.resource=stream.resource;uint64_t gyroHandle=0;CHECK(look->openStream(&gyro,&gyroHandle)==0);
    const uint64_t policyEpoch=amclLookPolicyEpochV1(1);CHECK(policyEpoch&&look->applyPolicy(1,&policy)==0&&amclLookPolicyEpochV1(1)==policyEpoch);
    CHECK(look->submitDelta(gyroHandle,3,4,1)==0);AmclLookPrefixV1 gyroPrefix{};CHECK(look->sealPrefix(1,6,1046000000,1,&gyroPrefix)==1);
    CHECK(look->prepare(c,gyroPrefix.token,&e)==1&&near(e.dx,3)&&near(e.dy,4)); // 无重复dt/accel/smooth
    CHECK(look->claim(&e)==1&&look->complete(&e,AMCL_CONTROL_STATE_FINAL)==0);
    const AmclLookPolicyV1 changed{sizeof(changed),1,2,.1,1};CHECK(look->applyPolicy(1,&changed)==0&&amclLookPolicyEpochV1(1)>policyEpoch);
    CHECK(look->submitDelta(gyroHandle,2,0,2)==AMCL_LOOK_STALE&&look->retireStream(gyroHandle)==0);
    CHECK(look->openStream(&gyro,&gyroHandle)==0&&look->submitDelta(gyroHandle,2,3,3)==0);
    CHECK(look->sealPrefix(1,7,1046000000,1,&gyroPrefix)==1&&look->prepare(c,gyroPrefix.token,&e)==1&&near(e.dx,4)&&near(e.dy,-6));
    CHECK(look->claim(&e)==1&&look->complete(&e,AMCL_CONTROL_STATE_FINAL)==0);
    CHECK(look->publishMode(1,2,0)==0&&look->submitVelocity(b,1,0,1030000000)==AMCL_LOOK_STALE);
    // 超过固定容量的正常热插/模式次数不永久耗尽流槽，单调handle仍不复用。
    CHECK(look->publishMode(1,3,1)==0);stream.resource.modeEpoch=3;stream.device=0;
    uint64_t lastHandle=0;for(uint64_t connection=1;connection<=700;++connection){stream.connection=connection;uint64_t value=0;
        CHECK(look->openStream(&stream,&value)==0&&value>lastHandle&&look->retireStream(value)==0);lastHandle=value;}
    std::puts("LOOK EXECUTION PASS: real owner velocity/prefix/three consumer identities/retire/reentry");
}
