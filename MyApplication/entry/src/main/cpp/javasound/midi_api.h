/* OH_MIDI API24 的精确可选接口。只在控制线程加载和解析，不产生 libohmidi 的
 * DT_NEEDED；API20 无此库时返回明确 unavailable，不能提高整个应用的最低API。
 * 每个函数指针直接由当前SDK声明派生，参数/返回值漂移会由编译器检查。
 */
#ifndef AMCL_MIDI_API_H
#define AMCL_MIDI_API_H
#include <ohmidi/native_midi.h>
#ifdef __cplusplus
extern "C" {
#endif
#define AMCL_MIDI_API_MEMBERS(X) \
    X(Create, OH_MIDIClient_Create) \
    X(Destroy, OH_MIDIClient_Destroy) \
    X(GetDeviceCount, OH_MIDIClient_GetDeviceCount) \
    X(GetDeviceInfos, OH_MIDIClient_GetDeviceInfos) \
    X(GetPortCount, OH_MIDIClient_GetPortCount) \
    X(GetPortInfos, OH_MIDIClient_GetPortInfos) \
    X(OpenDevice, OH_MIDIClient_OpenDevice) \
    X(CloseDevice, OH_MIDIClient_CloseDevice) \
    X(OpenInputPort, OH_MIDIDevice_OpenInputPort) \
    X(OpenOutputPort, OH_MIDIDevice_OpenOutputPort) \
    X(CloseInputPort, OH_MIDIDevice_CloseInputPort) \
    X(CloseOutputPort, OH_MIDIDevice_CloseOutputPort) \
    X(Send, OH_MIDIDevice_Send) \
    X(FlushOutputPort, OH_MIDIDevice_FlushOutputPort)
typedef struct {
    void* library;
#define AMCL_MIDI_API_FIELD(field, symbol) __typeof__(&symbol) field;
    AMCL_MIDI_API_MEMBERS(AMCL_MIDI_API_FIELD)
#undef AMCL_MIDI_API_FIELD
} AmclMidiApi;
enum { AMCL_MIDI_API_OK = 0, AMCL_MIDI_API_UNAVAILABLE = 1, AMCL_MIDI_API_BROKEN = -1 };
/* load只接固定平台库名；测试故障库由独立进程的受控动态搜索目录提供。error必须
 * 由调用方拥有，生命周期不依赖线程局部dlerror缓冲。close仅在client全部结束后用。 */
int amcl_midi_api_load(AmclMidiApi* api, char* error, size_t errorSize);
void amcl_midi_api_close(AmclMidiApi* api);
#ifdef __cplusplus
}
#endif
#endif
