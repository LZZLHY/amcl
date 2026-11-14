/* 只声明生产核心实际调用的SDK函数；故障供应者在独立测试文件实现。 */
#ifndef AMCL_TEST_AUDIO_ROUTING_H
#define AMCL_TEST_AUDIO_ROUTING_H
#include "native_audio_device_base.h"
typedef struct OH_AudioRoutingManager OH_AudioRoutingManager;
OH_AudioCommon_Result OH_AudioManager_GetAudioRoutingManager(OH_AudioRoutingManager **);
OH_AudioCommon_Result OH_AudioRoutingManager_GetDevices(OH_AudioRoutingManager *,OH_AudioDevice_Flag,OH_AudioDeviceDescriptorArray **);
OH_AudioCommon_Result OH_AudioRoutingManager_ReleaseDevices(OH_AudioRoutingManager *,OH_AudioDeviceDescriptorArray *);
#endif
