/**
 * 有锁的 OHAudio 系统替身：故障码、实际协商参数、系统暂停与迟到回调都可控制。
 * 不模拟混音算法，混音与后端来自生产 OpenAL；不访问物理音频设备。
 */
#include "ohaudio/native_audiostreambuilder.h"
#include <mutex>

#ifdef _WIN32
#define AUDIT_EXPORT __declspec(dllexport)
#else
#define AUDIT_EXPORT __attribute__((visibility("default")))
#endif

struct OH_AudioStreamBuilder {
    int rate=48000, channels=2, format=AUDIOSTREAM_SAMPLE_S16LE, latency=0;
    OH_AudioRenderer_OnWriteDataCallback write=nullptr;
    OH_AudioRenderer_OnInterruptCallback interrupt=nullptr;
    OH_AudioRenderer_OnErrorCallback error=nullptr;
    void *writeUser=nullptr, *interruptUser=nullptr, *errorUser=nullptr;
};
struct OH_AudioRenderer : OH_AudioStreamBuilder { OH_AudioStream_State state=AUDIOSTREAM_STATE_PREPARED; float volume=1; };
namespace {
std::mutex mutex;
OH_AudioRenderer* active=nullptr;
int fail=0, generateFastFailure=0, overrideFormat=-1, calls=0, builders=0, renderers=0, starts=0;
bool reject(int operation) { return fail==operation; }
OH_AudioRenderer_OnWriteDataCallback lateWrite=nullptr;
void* lateUser=nullptr;
}

extern "C" {
/** 创建/销毁计数证明失败分支没有遗留本次 builder。 */
OH_AudioStream_Result OH_AudioStreamBuilder_Create(OH_AudioStreamBuilder** out, OH_AudioStream_Type) {
    std::lock_guard<std::mutex> lock{mutex};
    if(reject(100)) { *out=nullptr; return AUDIOSTREAM_ERROR_SYSTEM; }
    *out=new OH_AudioStreamBuilder; ++builders; return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_Destroy(OH_AudioStreamBuilder* p) {
    std::lock_guard<std::mutex> lock{mutex}; delete p; --builders; return AUDIOSTREAM_SUCCESS;
}

// 每一配置接口都能独立拒绝；后端必须检查结果，不得依赖此处默认值恰好可用。
#define SETTER(name,type,field,id) \
OH_AudioStream_Result name(OH_AudioStreamBuilder* p,type v) { \
    std::lock_guard<std::mutex> lock{mutex}; if(reject(id)) return AUDIOSTREAM_ERROR_INVALID_PARAM; \
    p->field=v; return AUDIOSTREAM_SUCCESS; }
SETTER(OH_AudioStreamBuilder_SetSamplingRate,int32_t,rate,1)
SETTER(OH_AudioStreamBuilder_SetChannelCount,int32_t,channels,2)
SETTER(OH_AudioStreamBuilder_SetSampleFormat,OH_AudioStream_SampleFormat,format,3)
SETTER(OH_AudioStreamBuilder_SetLatencyMode,OH_AudioStream_LatencyMode,latency,6)
OH_AudioStream_Result OH_AudioStreamBuilder_SetEncodingType(OH_AudioStreamBuilder*, OH_AudioStream_EncodingType) {
    std::lock_guard<std::mutex> lock{mutex}; return reject(4)?AUDIOSTREAM_ERROR_INVALID_PARAM:AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererInfo(OH_AudioStreamBuilder*, OH_AudioStream_Usage) {
    std::lock_guard<std::mutex> lock{mutex}; return reject(5)?AUDIOSTREAM_ERROR_INVALID_PARAM:AUDIOSTREAM_SUCCESS;
}
#define CALLBACK(name,type,field,user,id) \
OH_AudioStream_Result name(OH_AudioStreamBuilder* p,type callback,void* data) { \
    std::lock_guard<std::mutex> lock{mutex}; if(reject(id)) return AUDIOSTREAM_ERROR_INVALID_PARAM; \
    p->field=callback; p->user=data; return AUDIOSTREAM_SUCCESS; }
CALLBACK(OH_AudioStreamBuilder_SetRendererWriteDataCallback,OH_AudioRenderer_OnWriteDataCallback,write,writeUser,7)
CALLBACK(OH_AudioStreamBuilder_SetRendererInterruptCallback,OH_AudioRenderer_OnInterruptCallback,interrupt,interruptUser,8)
CALLBACK(OH_AudioStreamBuilder_SetRendererErrorCallback,OH_AudioRenderer_OnErrorCallback,error,errorUser,9)

/** 可以模拟 FAST 不可用，或系统协商出与请求不同但受支持的格式。 */
OH_AudioStream_Result OH_AudioStreamBuilder_GenerateRenderer(OH_AudioStreamBuilder* p, OH_AudioRenderer** out) {
    std::lock_guard<std::mutex> lock{mutex}; ++calls;
    if(reject(101) || (generateFastFailure && p->latency==AUDIOSTREAM_LATENCY_MODE_FAST)) { *out=nullptr; return AUDIOSTREAM_ERROR_SYSTEM; }
    active=new OH_AudioRenderer; static_cast<OH_AudioStreamBuilder&>(*active)=*p;
    if(overrideFormat>=0) active->format=overrideFormat;
    *out=active; ++renderers; return AUDIOSTREAM_SUCCESS;
}
#define GETTER(name,type,field,id) \
OH_AudioStream_Result name(OH_AudioRenderer* p,type* out) { \
    std::lock_guard<std::mutex> lock{mutex}; if(reject(id)) return AUDIOSTREAM_ERROR_SYSTEM; \
    *out=static_cast<type>(p->field); return AUDIOSTREAM_SUCCESS; }
GETTER(OH_AudioRenderer_GetSamplingRate,int32_t,rate,10)
GETTER(OH_AudioRenderer_GetChannelCount,int32_t,channels,11)
GETTER(OH_AudioRenderer_GetSampleFormat,OH_AudioStream_SampleFormat,format,12)
GETTER(OH_AudioRenderer_GetLatencyMode,OH_AudioStream_LatencyMode,latency,13)
GETTER(OH_AudioRenderer_GetCurrentState,OH_AudioStream_State,state,14)
OH_AudioStream_Result OH_AudioRenderer_GetUnderflowCount(OH_AudioRenderer*, uint32_t* out) { *out=0; return AUDIOSTREAM_SUCCESS; }
OH_AudioStream_Result OH_AudioRenderer_Start(OH_AudioRenderer* p) {
    std::lock_guard<std::mutex> lock{mutex}; if(reject(20)) return AUDIOSTREAM_ERROR_SYSTEM;
    p->state=AUDIOSTREAM_STATE_RUNNING; ++starts; return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioRenderer_Pause(OH_AudioRenderer* p) {
    std::lock_guard<std::mutex> lock{mutex}; if(reject(21)) return AUDIOSTREAM_ERROR_SYSTEM;
    p->state=AUDIOSTREAM_STATE_PAUSED; return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioRenderer_Stop(OH_AudioRenderer* p) {
    std::lock_guard<std::mutex> lock{mutex}; if(reject(22)) return AUDIOSTREAM_ERROR_SYSTEM;
    p->state=AUDIOSTREAM_STATE_STOPPED; return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioRenderer_SetVolume(OH_AudioRenderer* p, float volume) {
    std::lock_guard<std::mutex> lock{mutex}; p->volume=volume; return AUDIOSTREAM_SUCCESS;
}
/** Release 失败时仍保留平台回调，专门验证生产后端的 detached context。 */
OH_AudioStream_Result OH_AudioRenderer_Release(OH_AudioRenderer* p) {
    std::lock_guard<std::mutex> lock{mutex};
    if(reject(23)) { lateWrite=p->write; lateUser=p->writeUser; return AUDIOSTREAM_ERROR_ILLEGAL_STATE; }
    if(active==p) active=nullptr; delete p; --renderers; return AUDIOSTREAM_SUCCESS;
}

/** 设置单一故障，所有场景在独立宿主进程执行，避免 OpenAL 全局配置缓存互相干扰。 */
AUDIT_EXPORT void auditFault(int operation,int fastFailure,int format) {
    std::lock_guard<std::mutex> lock{mutex}; fail=operation; generateFastFailure=fastFailure; overrideFormat=format;
}
AUDIT_EXPORT int auditInfo(int field) {
    std::lock_guard<std::mutex> lock{mutex};
    if(field==8) return calls; if(field==9) return builders; if(field==10) return renderers; if(field==11) return starts;
    if(!active) return -1;
    switch(field) {
    case 0:return active->rate; case 1:return active->channels; case 2:return active->format;
    case 3:return active->latency; case 4:return active->state;
    case 5:return active->interrupt!=nullptr; case 6:return active->error!=nullptr;
    case 7:return static_cast<int>(active->volume*1000); default:return -1;
    }
}
/** 取回回调快照后解锁，不能持替身锁跨真实产品回调。 */
AUDIT_EXPORT int auditPump(void* data,int bytes,int late) {
    OH_AudioRenderer_OnWriteDataCallback fn=nullptr; void* user=nullptr; OH_AudioRenderer* renderer=nullptr;
    { std::lock_guard<std::mutex> lock{mutex};
      if(late) { fn=lateWrite;user=lateUser; }
      else if(active) { renderer=active;fn=active->write;user=active->writeUser; } }
    return fn?fn(renderer,user,data,bytes):-99;
}
AUDIT_EXPORT void auditInterrupt(int type,int hint) {
    OH_AudioRenderer_OnInterruptCallback fn=nullptr;void* user=nullptr;OH_AudioRenderer* renderer=nullptr;
    { std::lock_guard<std::mutex> lock{mutex}; if(!active) return;
      renderer=active;fn=active->interrupt;user=active->interruptUser;
      if(type==AUDIOSTREAM_INTERRUPT_FORCE && hint==AUDIOSTREAM_INTERRUPT_HINT_PAUSE) active->state=AUDIOSTREAM_STATE_PAUSED; }
    if(fn) fn(renderer,user,static_cast<OH_AudioInterrupt_ForceType>(type),static_cast<OH_AudioInterrupt_Hint>(hint));
}
AUDIT_EXPORT void auditError(int value) {
    OH_AudioRenderer_OnErrorCallback fn=nullptr;void* user=nullptr;OH_AudioRenderer* renderer=nullptr;
    { std::lock_guard<std::mutex> lock{mutex}; if(active) {renderer=active;fn=active->error;user=active->errorUser;} }
    if(fn) fn(renderer,user,static_cast<OH_AudioStream_Result>(value));
}
}
