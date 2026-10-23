#pragma once
#include <cstdint>

// 系统替身的枚举值/函数签名与本机 API20+ SDK 核对；不提供真实系统音频。
struct OH_AudioStreamBuilder;
struct OH_AudioRenderer;
enum OH_AudioStream_Result { AUDIOSTREAM_SUCCESS=0, AUDIOSTREAM_ERROR_INVALID_PARAM=1,
    AUDIOSTREAM_ERROR_ILLEGAL_STATE=2, AUDIOSTREAM_ERROR_SYSTEM=3 };
enum OH_AudioStream_Type { AUDIOSTREAM_TYPE_RENDERER=1 };
enum OH_AudioStream_SampleFormat { AUDIOSTREAM_SAMPLE_U8=0, AUDIOSTREAM_SAMPLE_S16LE=1,
    AUDIOSTREAM_SAMPLE_S24LE=2, AUDIOSTREAM_SAMPLE_S32LE=3, AUDIOSTREAM_SAMPLE_F32LE=4 };
enum OH_AudioStream_EncodingType { AUDIOSTREAM_ENCODING_TYPE_RAW=0 };
enum OH_AudioStream_Usage { AUDIOSTREAM_USAGE_GAME=11 };
enum OH_AudioStream_LatencyMode { AUDIOSTREAM_LATENCY_MODE_NORMAL=0, AUDIOSTREAM_LATENCY_MODE_FAST=1 };
enum OH_AudioData_Callback_Result { AUDIO_DATA_CALLBACK_RESULT_INVALID=-1, AUDIO_DATA_CALLBACK_RESULT_VALID=0 };
using OH_AudioRenderer_OnWriteDataCallback = OH_AudioData_Callback_Result(*)(OH_AudioRenderer*, void*, void*, int32_t);
enum OH_AudioStream_State { AUDIOSTREAM_STATE_INVALID=-1, AUDIOSTREAM_STATE_NEW=0,
    AUDIOSTREAM_STATE_PREPARED=1, AUDIOSTREAM_STATE_RUNNING=2, AUDIOSTREAM_STATE_STOPPED=3,
    AUDIOSTREAM_STATE_RELEASED=4, AUDIOSTREAM_STATE_PAUSED=5 };
enum OH_AudioInterrupt_ForceType { AUDIOSTREAM_INTERRUPT_FORCE=0, AUDIOSTREAM_INTERRUPT_SHARE=1 };
enum OH_AudioInterrupt_Hint { AUDIOSTREAM_INTERRUPT_HINT_NONE=0, AUDIOSTREAM_INTERRUPT_HINT_RESUME=1,
    AUDIOSTREAM_INTERRUPT_HINT_PAUSE=2, AUDIOSTREAM_INTERRUPT_HINT_STOP=3,
    AUDIOSTREAM_INTERRUPT_HINT_DUCK=4, AUDIOSTREAM_INTERRUPT_HINT_UNDUCK=5 };
using OH_AudioRenderer_OnInterruptCallback = void(*)(OH_AudioRenderer*,void*,OH_AudioInterrupt_ForceType,OH_AudioInterrupt_Hint);
using OH_AudioRenderer_OnErrorCallback = void(*)(OH_AudioRenderer*,void*,OH_AudioStream_Result);
extern "C" {
OH_AudioStream_Result OH_AudioStreamBuilder_Create(OH_AudioStreamBuilder**, OH_AudioStream_Type);
OH_AudioStream_Result OH_AudioStreamBuilder_Destroy(OH_AudioStreamBuilder*);
OH_AudioStream_Result OH_AudioStreamBuilder_SetSamplingRate(OH_AudioStreamBuilder*, int32_t);
OH_AudioStream_Result OH_AudioStreamBuilder_SetChannelCount(OH_AudioStreamBuilder*, int32_t);
OH_AudioStream_Result OH_AudioStreamBuilder_SetSampleFormat(OH_AudioStreamBuilder*, OH_AudioStream_SampleFormat);
OH_AudioStream_Result OH_AudioStreamBuilder_SetEncodingType(OH_AudioStreamBuilder*, OH_AudioStream_EncodingType);
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererInfo(OH_AudioStreamBuilder*, OH_AudioStream_Usage);
OH_AudioStream_Result OH_AudioStreamBuilder_SetLatencyMode(OH_AudioStreamBuilder*, OH_AudioStream_LatencyMode);
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererWriteDataCallback(OH_AudioStreamBuilder*, OH_AudioRenderer_OnWriteDataCallback, void*);
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererInterruptCallback(OH_AudioStreamBuilder*, OH_AudioRenderer_OnInterruptCallback, void*);
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererErrorCallback(OH_AudioStreamBuilder*, OH_AudioRenderer_OnErrorCallback, void*);
OH_AudioStream_Result OH_AudioStreamBuilder_GenerateRenderer(OH_AudioStreamBuilder*, OH_AudioRenderer**);
}
