/**
 * 触摸、gyro和明确legacy physical的source接缝。不复制加工，只保存各来源的opaque流。
 * 设备0是既有未携设备号的明确兼容桶，模式/资源改变时退休原桶再开新桶；mapped device
 * 流采用另一严格connection入口，不能借这里自动改绑旧设备连接。
 */
#include "source_look_producer.h"
#include "input_source.h"
#include "../input/delivery/look_transport.h"
#include "../input/amcl_input_api.h"
#include <array>
#include <mutex>
#include <chrono>
namespace {
struct Lease {uint64_t handle=0;AmclLookResourceV1 resource{};};
std::array<Lease,AMCL_INPUT_SOURCE_COUNT+1> leases;
std::mutex leaseMutex;
uint64_t now(){return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
    std::chrono::steady_clock::now().time_since_epoch()).count());}
bool same(const AmclLookResourceV1& a,const AmclLookResourceV1& b){return a.gameSession==b.gameSession&&
    a.sessionEpoch==b.sessionEpoch&&a.surfaceEpoch==b.surfaceEpoch&&a.focusEpoch==b.focusEpoch&&a.modeEpoch==b.modeEpoch;}
}
bool amclSourceLookSubmit(int32_t source,double dx,double dy,int64_t sampleNs,bool gyro){
    const auto* port=amclLookExecutionGetPortV1();if(!port||source<0||source>=AMCL_INPUT_SOURCE_COUNT)return false;
    AmclLookResourceV1 resource{};if(!inputBridge_getLookResourceV1(&resource))return false;
    const size_t index=gyro?AMCL_INPUT_SOURCE_COUNT:static_cast<size_t>(source);
    std::lock_guard<std::mutex> lock(leaseMutex);auto& lease=leases[index];
    if(lease.handle&&!same(lease.resource,resource)){(void)port->retireStream(lease.handle);lease={};}
    if(!lease.handle){AmclLookStreamV1 description{};description.size=sizeof(description);description.source=source;
        description.kind=gyro?AMCL_LOOK_GYRO_DELTA:source==3?AMCL_LOOK_PHYSICAL_DELTA:AMCL_LOOK_TOUCH_DELTA;
        const auto* core=amclInputGetHostApiV1();
        description.unit=source==3?(core&&(core->capabilityBits&AMCL_INPUT_CAP_GLFW_API26_RAW_MOUSE_MOTION)?
            AMCL_LOOK_HARDWARE_COUNTS:AMCL_LOOK_PLATFORM_RELATIVE_COUNTS):gyro||source==2?AMCL_LOOK_VIRTUAL_COUNTS:AMCL_LOOK_SURFACE_PIXELS;
        description.clock=gyro?AMCL_LOOK_SENSOR_STARTUP:sampleNs>0?AMCL_LOOK_PLATFORM_SAMPLE:AMCL_LOOK_OWNER_MONOTONIC;
        description.resource=resource;if(port->openStream(&description,&lease.handle)<0)return false;lease.resource=resource;}
    return inputBridge_submitLookV1(lease.handle,dx,dy,sampleNs>0?static_cast<uint64_t>(sampleNs):now(),0)!=0;
}
bool amclSourceLookFlush(int32_t source,bool emit){const auto* port=amclLookExecutionGetPortV1();
    if(!port||source<0||source>=AMCL_INPUT_SOURCE_COUNT)return false;std::lock_guard<std::mutex> lock(leaseMutex);
    auto& lease=leases[static_cast<size_t>(source)];bool accepted=true;
    if(lease.handle){if(emit)accepted=inputBridge_submitLookV1(lease.handle,0,0,now(),2)!=0;
        else{(void)port->retireStream(lease.handle);lease={};}}
    // 手指正常UP不清gyro时钟；取消触控域时才精确退休独立gyro流。
    if(source==1&&!emit&&leases[AMCL_INPUT_SOURCE_COUNT].handle){(void)port->retireStream(leases[AMCL_INPUT_SOURCE_COUNT].handle);leases[AMCL_INPUT_SOURCE_COUNT]={};}
    return accepted;
}
