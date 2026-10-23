/**
 * 旧source视角ABI的薄适配。政策、时钟、pending和统计均由neutral look_execution拥有；
 * 此文件没有mutex/SourceState，旧调用与新stream不会建立第二套生产数学权威。
 */
#include "source_look_processor.h"
#include "../input/delivery/look_execution_compat.h"
extern "C" bool amcl_process_source_look_delta(int32_t source,double x,double y,int64_t ns,double* outX,double* outY){
    return amclLookCompatProcess(source,x,y,ns,outX,outY,false);}
extern "C" bool amcl_process_touch_gyro_delta(double x,double y,int64_t ns,double* outX,double* outY){
    return amclLookCompatProcess(1,x,y,ns,outX,outY,true);}
extern "C" bool amcl_flush_source_look_delta(int32_t source,bool emit,double* outX,double* outY){
    return amclLookCompatFlush(source,emit,outX,outY);}
extern "C" void amcl_reset_source_look_state(){amclLookCompatReset();}
extern "C" void amcl_reset_source_look_delta(int32_t source){double x=0,y=0;(void)amclLookCompatFlush(source,false,&x,&y);}
/** 单字段兼容setter在owner内原子读改整组，拒绝保持所有来源原值。 */
extern "C" bool amcl_set_source_look_sensitivity(int32_t source,double value){return amclLookCompatSet(source,0,value);}
extern "C" bool amcl_set_source_look_invert_y(int32_t source,bool value){return amclLookCompatSet(source,1,value?1:0);}
extern "C" bool amcl_set_source_look_smoothing(int32_t source,double value){return amclLookCompatSet(source,2,value);}
extern "C" bool amcl_set_source_look_acceleration(int32_t source,double value){return amclLookCompatSet(source,3,value);}
extern "C" bool amcl_apply_source_look_configuration(int32_t source,double sensitivity,bool invert,double smoothing,double acceleration){
    const AmclLookPolicyV1 value{sizeof(AmclLookPolicyV1),invert?1u:0u,sensitivity,smoothing,acceleration};
    const auto* owner=amclLookExecutionGetPortV1();return owner&&owner->applyPolicy(source,&value)>=0;}
namespace amcl::input {
/** 复制唯一owner的统计；没有适配器私有计数，不把前缀接受说成实际游戏读取。 */
LookPipelineSnapshot SourceLookPipelineSnapshot(){LookPipelineSnapshot output{};amclLookCompatSnapshot(&output);return output;}
}
