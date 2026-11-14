/* 宿主测试的SDK接口声明子集。不是产品SDK替代；实际目标同时用原SDK头编译核签名。
 * 数值/签名来自已记录的API26公开头，所调用接口均since12，覆盖API20基线。 */
#ifndef AMCL_TEST_AUDIO_DEVICE_BASE_H
#define AMCL_TEST_AUDIO_DEVICE_BASE_H
#include <stdint.h>
typedef enum { AUDIOCOMMON_RESULT_SUCCESS=0, AUDIOCOMMON_RESULT_ERROR_INVALID_PARAM=6800101,
 AUDIOCOMMON_RESULT_ERROR_NO_MEMORY=6800102, AUDIOCOMMON_RESULT_ERROR_SYSTEM=6800301 } OH_AudioCommon_Result;
typedef enum { AUDIO_DEVICE_ROLE_INPUT=1, AUDIO_DEVICE_ROLE_OUTPUT=2 } OH_AudioDevice_Role;
typedef enum { AUDIO_DEVICE_TYPE_INVALID=0, AUDIO_DEVICE_TYPE_EARPIECE=1, AUDIO_DEVICE_TYPE_SPEAKER=2,
 AUDIO_DEVICE_TYPE_WIRED_HEADSET=3, AUDIO_DEVICE_TYPE_WIRED_HEADPHONES=4, AUDIO_DEVICE_TYPE_MIC=15,
 AUDIO_DEVICE_TYPE_USB_HEADSET=22, AUDIO_DEVICE_TYPE_DEFAULT=1000 } OH_AudioDevice_Type;
typedef enum { AUDIO_DEVICE_FLAG_NONE=0, AUDIO_DEVICE_FLAG_OUTPUT=1, AUDIO_DEVICE_FLAG_INPUT=2,
 AUDIO_DEVICE_FLAG_ALL=3 } OH_AudioDevice_Flag;
typedef struct OH_AudioDeviceDescriptor OH_AudioDeviceDescriptor;
typedef struct OH_AudioDeviceDescriptorArray { uint32_t size; OH_AudioDeviceDescriptor **descriptors; } OH_AudioDeviceDescriptorArray;
OH_AudioCommon_Result OH_AudioDeviceDescriptor_GetDeviceRole(OH_AudioDeviceDescriptor *,OH_AudioDevice_Role *);
OH_AudioCommon_Result OH_AudioDeviceDescriptor_GetDeviceType(OH_AudioDeviceDescriptor *,OH_AudioDevice_Type *);
OH_AudioCommon_Result OH_AudioDeviceDescriptor_GetDeviceId(OH_AudioDeviceDescriptor *,uint32_t *);
OH_AudioCommon_Result OH_AudioDeviceDescriptor_GetDeviceName(OH_AudioDeviceDescriptor *,char **);
OH_AudioCommon_Result OH_AudioDeviceDescriptor_GetDeviceAddress(OH_AudioDeviceDescriptor *,char **);
#endif
