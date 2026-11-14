/* JavaSound平台MIDI控制面。manager管理一个真实OH_MIDIClient及共享device；端口
 * 与Java可见设备分别用不复用的整数身份，既有对象不会因列表重新排序打开另一设备。
 * acquire/release跨整个JNI输入循环持有真实对象，但不持锁跨Java用户Receiver回调。
 */
#ifndef AMCL_MIDI_CORE_H
#define AMCL_MIDI_CORE_H
#include "midi_api.h"
#include "midi_callbacks.h"
#include "midi_stream.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct AmclMidiManager AmclMidiManager;
typedef struct AmclMidiUse AmclMidiUse;
typedef struct {
    int32_t token;
    OH_MIDIDeviceInformation device;
    OH_MIDIPortInformation port;
} AmclMidiEndpoint;
typedef struct {
    int isLong;
    uint32_t packed;
    int64_t microseconds;
    size_t length;
    uint8_t data[4096];
} AmclMidiMessage;
enum {
    AMCL_MIDI_STALE = -12101, AMCL_MIDI_MEMORY = -12102, AMCL_MIDI_CHANGED = -12103,
    AMCL_MIDI_INVALID = -12104, AMCL_MIDI_CLOSED = -12105, AMCL_MIDI_BUSY = -12106,
    AMCL_MIDI_TIMEOUT = -12107, AMCL_MIDI_ABI = -12108
};
/* api/table在manager成功销毁前均由调用方保活。失败Destroy可能已消费SDK句柄，
 * manager会记住该事实；不得重试原指针，返回非0时保留数据和两个映像租约。 */
int amcl_midi_manager_create(AmclMidiManager** output, const AmclMidiApi* api, const AmclMidiCallbackAbiV1* table);
int amcl_midi_manager_destroy(AmclMidiManager* manager);
int amcl_midi_snapshot(AmclMidiManager* manager, int direction, AmclMidiEndpoint** output, size_t* count);
int amcl_midi_open(AmclMidiManager* manager, int endpointToken, int direction, uint64_t* handle);
int amcl_midi_close(AmclMidiManager* manager, uint64_t handle);
AmclMidiUse* amcl_midi_acquire(AmclMidiManager* manager, uint64_t handle, int direction);
void amcl_midi_release(AmclMidiUse* use);
int amcl_midi_start(AmclMidiUse* use);
int amcl_midi_stop(AmclMidiUse* use);
int64_t amcl_midi_position(AmclMidiUse* use);
int amcl_midi_send_short(AmclMidiUse* use, uint32_t packed, int64_t microseconds);
int amcl_midi_send_long(AmclMidiUse* use, const uint8_t* bytes, size_t size, int64_t microseconds);
/* begin/end禁止同一端口出现两个读取者。next返回1消息/0已停/负或平台正错误码，
 * 只在成功情况下填写message。故障状态与“没有输入”不能混为一谈。 */
int amcl_midi_read_begin(AmclMidiUse* use);
void amcl_midi_read_end(AmclMidiUse* use);
int amcl_midi_next(AmclMidiUse* use, AmclMidiMessage* message);
#ifdef __cplusplus
}
#endif
#endif
