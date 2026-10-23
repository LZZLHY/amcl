/** 真Core/adapter/backend有序消费证明physical一次事实加工；不替代真实硬件Gate0或游戏tick。 */
#include "../../input/delivery/look_execution.h"
#include "../../input/input_look_core_hook.h"
#include "../../input/input_state_core.h"
#include "../../input/input_interaction_order.h"
#include "../../input/amcl_input_host_descriptor.h"
#include "../../input/adapters/glfw_input_adapter.h"
#include "../../input/adapters/backend_input_bridge.h"
#include "../../platform/source_look_processor.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <vector>
#define CHECK(v) do{if(!(v)){std::fprintf(stderr,"LOOK PHYSICAL FAIL %d: %s\n",__LINE__,#v);std::exit(1);}}while(false)
using namespace amcl::input;
GlfwInputAdapter glfw;
std::vector<GlfwRelativeSinkEvent> moves;
void relative(void*,const GlfwRelativeSinkEvent& event){moves.push_back(event);}
AmclInputEvent event(uint32_t type,uint64_t epoch){AmclInputEvent value{};value.header.abiVersion=1;
    value.header.structSize=sizeof(value);value.header.eventType=type;value.header.sessionEpoch=epoch;
    value.header.source=AMCL_INPUT_SOURCE_MOUSE;value.header.deviceId=8;value.header.deviceClass=AMCL_INPUT_DEVICE_CLASS_MOUSE;return value;}
void drain(uint32_t backend){AmclBackendInputEvent out{};for(unsigned i=0;i<64;++i){const int result=amclBackendInputNextThrough(backend,&out,UINT64_MAX);
    CHECK(result>=0);if(!result)return;}CHECK(false);}
int main(){
    const auto* api=amclInputGetHostApiV1();CHECK(amclInputHostDescriptorPublishV1(api)==0);
    uint64_t epoch=0;CHECK(api->beginSession(&epoch)==0&&api->publishFocus(1)==0);
    AmclInputSurfacePayload surface{};surface.active=1;surface.widthPx=640;surface.heightPx=480;surface.density=1;
    surface.validFields=AMCL_INPUT_SURFACE_FIELD_ALL;surface.publicationGeneration=1;CHECK(api->publishSurface(&surface)==0);
    auto context=event(AMCL_INPUT_EVENT_SURFACE_CONTEXT_CHANGED,epoch);context.header.source=AMCL_INPUT_SOURCE_SYNTHETIC;
    context.payload.surfaceContext.generation=1;context.payload.surfaceContext.windowId=42;context.payload.surfaceContext.displayId=1;
    context.payload.surfaceContext.widthPx=640;context.payload.surfaceContext.heightPx=480;context.payload.surfaceContext.density=1;
    context.payload.surfaceContext.validFields=AMCL_INPUT_SURFACE_CONTEXT_FIELD_WINDOW|AMCL_INPUT_SURFACE_CONTEXT_FIELD_DISPLAY|
        AMCL_INPUT_SURFACE_CONTEXT_FIELD_RECT|AMCL_INPUT_SURFACE_CONTEXT_FIELD_DENSITY|AMCL_INPUT_SURFACE_CONTEXT_FIELD_TRANSFORM;
    CHECK(api->submitEvent(&context)==0);
    const auto* control=amclControlDeliveryGetPortV1();CHECK(control&&amclControlDeliveryBindSessionV1(1)==0);
    const auto* look=amclLookExecutionGetPortV1();CHECK(look->bindSession(1)==0&&look->publishMode(1,1,1)==0);
    amclLookExecutionPublishV1();CHECK(amclInputOwnerLookCommitReadyV1());
    uint64_t consumers[3]{};for(uint32_t backend=1;backend<=3;++backend){CHECK(control->open(backend,42,&consumers[backend-1])==0);
        CHECK(look->bindConsumer(consumers[backend-1],0,0)==0&&look->setBackendActive(backend,1)==0&&look->bindConsumer(consumers[backend-1],0,0)==0);}
    GlfwInputSink sink{};sink.relative=relative;const GlfwInputMapper mapper=GlfwOhosInputMapper();
    CHECK(glfw.Open(api,mapper,sink)==GlfwAdapterStatus::kOk);
    amclBackendInputSetActive(2,1);amclBackendInputSetActive(3,1);drain(2);drain(3);glfw.Pump();
    auto capture=event(AMCL_INPUT_EVENT_CAPTURE_CHANGED,epoch);capture.header.source=AMCL_INPUT_SOURCE_SYNTHETIC;
    capture.payload.capture.requested=1;capture.payload.capture.active=1;capture.payload.capture.reason=AMCL_INPUT_CAPTURE_REASON_GRANTED;
    CHECK(api->submitEvent(&capture)==0);
    glfw.Pump();drain(2);drain(3);
    const AmclLookPolicyV1 policy{sizeof(policy),1,2,.1,.5};CHECK(look->applyPolicy(3,&policy)==0);
    // 制造Coreseq/order真实分歧：private lookup绝不凭相同数值猜二者同域。
    for(unsigned i=0;i<9;++i)(void)amclInputNextInteractionOrder();
    auto motion=event(AMCL_INPUT_EVENT_POINTER_RELATIVE,epoch);motion.payload.pointerRelative.rawDx=10;motion.payload.pointerRelative.rawDy=3;
    const auto before=SourceLookPipelineSnapshot();CHECK(api->submitEvent(&motion)==0);
    const auto accepted=SourceLookPipelineSnapshot();CHECK(accepted.accepted==before.accepted+1);
    CHECK(glfw.Pump().status==GlfwAdapterStatus::kOk&&moves.size()==1);
    uint64_t token=0;CHECK(look->physicalPrefix(moves.back().sequence,&token)==1&&token);
    AmclBackendInputEvent sdl{},l2{};CHECK(amclBackendInputNextThrough(3,&sdl,UINT64_MAX)==1&&sdl.eventType==AMCL_BACKEND_INPUT_EVENT_RELATIVE);
    CHECK(amclBackendInputNextThrough(2,&l2,UINT64_MAX)==1&&l2.eventType==AMCL_BACKEND_INPUT_EVENT_RELATIVE);
    uint64_t sdlToken=0,l2Token=0;CHECK(sdl.sequence==l2.sequence&&sdl.sequence!=moves.back().sequence);
    CHECK(look->physicalPrefixByOrder(sdl.sequence,&sdlToken)==1&&look->physicalPrefixByOrder(l2.sequence,&l2Token)==1&&sdlToken==token&&l2Token==token);
    CHECK(sdl.wheelX==10&&sdl.wheelY==3&&moves.back().dx==10&&moves.back().dy==3); // 原公开raw字段保全
    CHECK(SourceLookPipelineSnapshot().accepted==accepted.accepted); // 三端领取不二次加工/推进accelerator clock
    for(uint32_t backend=1;backend<=3;++backend){AmclLookEmissionV1 out{};CHECK(look->prepare(consumers[backend-1],token,&out)==1);
        CHECK(std::abs(out.dx-20)<1e-8&&std::abs(out.dy+6)<1e-8); // physical alpha1，不继承触控滑条
        CHECK(look->claim(&out)==1&&look->complete(&out,AMCL_CONTROL_STATE_FINAL)==0);}
    // 私有memo/float边界拒绝整Core接受批，不留下前一条数学或source时钟。
    CoreObservabilityV1 coreBefore{};CHECK(HostInputStateCore().GetObservability(&coreBefore)==0);
    const auto mathBefore=SourceLookPipelineSnapshot();auto huge=motion;huge.payload.pointerRelative.rawDx=std::numeric_limits<float>::max();
    const AmclInputEvent batch[]{motion,huge};CHECK(api->submitBatch(batch,2)==AMCL_INPUT_ERROR_INVALID_ARGUMENT);
    CoreObservabilityV1 coreAfter{};CHECK(HostInputStateCore().GetObservability(&coreAfter)==0);
    CHECK(coreBefore.lastSequence==coreAfter.lastSequence&&coreBefore.accepted==coreAfter.accepted&&SourceLookPipelineSnapshot().accepted==mathBefore.accepted);
    // device removal在Core接受点立即撤原尚未cache贡献；同id新事实不认旧handle。
    CHECK(api->submitEvent(&motion)==0);CHECK(glfw.Pump().status==GlfwAdapterStatus::kOk&&moves.size()==2);
    CHECK(look->physicalPrefix(moves.back().sequence,&token)==1);
    CHECK(api->publishDeviceChange(8,AMCL_INPUT_DEVICE_REMOVED,AMCL_INPUT_DEVICE_CAP_POINTER_RELATIVE)==0);
    AmclLookEmissionV1 dropped{};CHECK(look->prepare(consumers[0],token,&dropped)==1&&dropped.dx==0&&dropped.dy==0);
    CHECK(look->claim(&dropped)==1&&look->complete(&dropped,AMCL_CONTROL_STATE_FINAL)==0);
    CHECK(api->publishDeviceChange(8,AMCL_INPUT_DEVICE_ADDED,AMCL_INPUT_DEVICE_CAP_POINTER_RELATIVE)==0);
    CHECK(api->submitEvent(&motion)==0);CHECK(glfw.Pump().status==GlfwAdapterStatus::kOk&&moves.size()==3);
    CHECK(look->physicalPrefix(moves.back().sequence,&token)==1&&look->prepare(consumers[0],token,&dropped)==1&&dropped.dx>0);
    // 新inactive surface即便保留metadata也不能登记新的look流，capture不代理活surface。
    surface.active=0;CHECK(api->publishSurface(&surface)==0);AmclInputLookCoreResourceV1 unavailable{};
    CHECK(amclInputOwnerReadLookResourceV1(&unavailable)==0);
    std::puts("LOOK PHYSICAL PASS: actual Core+three adapters/order-vs-core/memo once/batch rollback/device/inactive surface");
}
