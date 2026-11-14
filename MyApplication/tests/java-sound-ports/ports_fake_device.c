/* 不注册回调/不启动系统设备，只提供可控GetDevices结果以检验真正生产快照代码。 */
#include <ohaudio/native_audio_routing_manager.h>
#include "ports_fake_device.h"
#include <stdlib.h>
#include <string.h>

struct OH_AudioRoutingManager { int unused; };
struct OH_AudioDeviceDescriptor { uint32_t id; OH_AudioDevice_Role role; OH_AudioDevice_Type type; char *name; char *address; };
static struct OH_AudioRoutingManager manager;
static int scenario, arrays, calls, scenario_calls;
static char long_name[900];
static struct OH_AudioDeviceDescriptor devices[] = {
 {10,AUDIO_DEVICE_ROLE_OUTPUT,AUDIO_DEVICE_TYPE_SPEAKER,"扬声器🙂","local:10"},
 {20,AUDIO_DEVICE_ROLE_INPUT,AUDIO_DEVICE_TYPE_MIC,"麦克风🎤","local:20"},
 {30,AUDIO_DEVICE_ROLE_OUTPUT,AUDIO_DEVICE_TYPE_WIRED_HEADPHONES,"耳机","jack:30"},
 {40,AUDIO_DEVICE_ROLE_OUTPUT,(OH_AudioDevice_Type)777,long_name,"actual:40"},
 {1000,AUDIO_DEVICE_ROLE_OUTPUT,AUDIO_DEVICE_TYPE_DEFAULT,"Default",""}
};

void ports_fake_scenario(int value)
{
    size_t i;
    scenario=value;scenario_calls=0;
    static const char suffix[]="设备🙂";
    for(i=0;i<sizeof(long_name)-sizeof(suffix);++i)long_name[i]='a';
    memcpy(long_name+sizeof(long_name)-sizeof(suffix),suffix,sizeof(suffix));
    devices[0].name=value==2?"更换扬声器🙂":value==13?"\xf0\x28\x8c\xbc":"扬声器🙂";
    devices[0].role=value==6?(OH_AudioDevice_Role)99:AUDIO_DEVICE_ROLE_OUTPUT;
    devices[1].id=value==5?10:20;
    devices[1].role=value==5?AUDIO_DEVICE_ROLE_OUTPUT:AUDIO_DEVICE_ROLE_INPUT;
}
int ports_fake_arrays(void){return __atomic_load_n(&arrays,__ATOMIC_SEQ_CST);}
int ports_fake_calls(void){return __atomic_load_n(&calls,__ATOMIC_SEQ_CST);}

OH_AudioCommon_Result OH_AudioManager_GetAudioRoutingManager(OH_AudioRoutingManager **out)
{
    if(scenario==11){*out=NULL;return AUDIOCOMMON_RESULT_SUCCESS;}
    *out=&manager;return AUDIOCOMMON_RESULT_SUCCESS;
}
OH_AudioCommon_Result OH_AudioRoutingManager_GetDevices(OH_AudioRoutingManager *m,OH_AudioDevice_Flag flag,OH_AudioDeviceDescriptorArray **out)
{
    OH_AudioDeviceDescriptorArray *value;size_t i;
    int nth;
    (void)m;(void)flag;__atomic_add_fetch(&calls,1,__ATOMIC_SEQ_CST);nth=__atomic_add_fetch(&scenario_calls,1,__ATOMIC_SEQ_CST);
    if(scenario==7){*out=NULL;return AUDIOCOMMON_RESULT_SUCCESS;}
    value=calloc(1,sizeof(*value)); if(!value)return AUDIOCOMMON_RESULT_ERROR_NO_MEMORY;
    value->size=scenario==3?0:5;
    value->descriptors=calloc(5,sizeof(*value->descriptors));
    if(!value->descriptors){free(value);return AUDIOCOMMON_RESULT_ERROR_NO_MEMORY;}
    for(i=0;i<5;++i)value->descriptors[i]=&devices[scenario==1?4-i:i];
    if(scenario==8)value->size=4097;
    if(scenario==9)value->descriptors[0]=NULL;
    *out=value;__atomic_add_fetch(&arrays,1,__ATOMIC_SEQ_CST);
    return scenario==4||(scenario==12&&nth>=2)?AUDIOCOMMON_RESULT_ERROR_SYSTEM:AUDIOCOMMON_RESULT_SUCCESS;
}
OH_AudioCommon_Result OH_AudioRoutingManager_ReleaseDevices(OH_AudioRoutingManager *m,OH_AudioDeviceDescriptorArray *value)
{
    (void)m;free(value->descriptors);free(value);__atomic_sub_fetch(&arrays,1,__ATOMIC_SEQ_CST);
    return scenario==10?AUDIOCOMMON_RESULT_ERROR_SYSTEM:AUDIOCOMMON_RESULT_SUCCESS;
}
/* 五个SDK getter逐个失败，验证调用者不会继续消费输出或漏掉ReleaseDevices。 */
OH_AudioCommon_Result OH_AudioDeviceDescriptor_GetDeviceRole(OH_AudioDeviceDescriptor*d,OH_AudioDevice_Role*v){*v=d->role;return scenario==14?AUDIOCOMMON_RESULT_ERROR_SYSTEM:AUDIOCOMMON_RESULT_SUCCESS;}
OH_AudioCommon_Result OH_AudioDeviceDescriptor_GetDeviceType(OH_AudioDeviceDescriptor*d,OH_AudioDevice_Type*v){*v=d->type;return scenario==15?AUDIOCOMMON_RESULT_ERROR_SYSTEM:AUDIOCOMMON_RESULT_SUCCESS;}
OH_AudioCommon_Result OH_AudioDeviceDescriptor_GetDeviceId(OH_AudioDeviceDescriptor*d,uint32_t*v){*v=d->id;return scenario==16?AUDIOCOMMON_RESULT_ERROR_SYSTEM:AUDIOCOMMON_RESULT_SUCCESS;}
OH_AudioCommon_Result OH_AudioDeviceDescriptor_GetDeviceName(OH_AudioDeviceDescriptor*d,char**v){*v=d->name;return scenario==17?AUDIOCOMMON_RESULT_ERROR_SYSTEM:AUDIOCOMMON_RESULT_SUCCESS;}
OH_AudioCommon_Result OH_AudioDeviceDescriptor_GetDeviceAddress(OH_AudioDeviceDescriptor*d,char**v){*v=d->address;return scenario==18?AUDIOCOMMON_RESULT_ERROR_SYSTEM:AUDIOCOMMON_RESULT_SUCCESS;}
