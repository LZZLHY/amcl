/* JavaSound MIDI1与OH_MIDI protocol1 UMP之间的无状态编解码。
 * 本模块不调用平台/Java，不申请内存；动态收发、SysEx跨包状态和错误传播由控制侧负责。
 * SDK明确protocol1仍使用MT1/MT2/MT3 UMP，不能把原始MIDI字节数组直接作为UMP发送。
 */
#ifndef AMCL_MIDI_UMP_H
#define AMCL_MIDI_UMP_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

enum {
    AMCL_MIDI_UMP_UNSUPPORTED = -2,
    AMCL_MIDI_UMP_INVALID = -1,
    AMCL_MIDI_UMP_UTILITY = 0,
    AMCL_MIDI_UMP_SHORT = 1,
    AMCL_MIDI_UMP_SYSEX7 = 2
};
typedef struct {
    uint32_t packed;       /* Java平台顺序：status | data1<<8 | data2<<16。 */
    uint8_t group;
    uint8_t sysexForm;     /* 0完整、1开始、2继续、3结束；F0/F7由上层按此恢复。 */
    uint8_t payloadSize;
    uint8_t payload[6];
} AmclMidiDecoded;

/* 返回MIDI1短消息总字节数；未定义status、F0/F7或数据字节返回0。 */
unsigned amcl_midi_short_size(uint8_t status);
int amcl_midi_short_to_ump(uint32_t packed, unsigned group, uint32_t* output);
int amcl_midi_sysex7_to_ump(unsigned form, unsigned group, const uint8_t* bytes, size_t count, uint32_t output[2]);
/* 只识别protocol1约定的消息类型；未知类型返回0，调用者不得猜长度跨越后续数据。 */
unsigned amcl_midi_protocol1_words(uint32_t first);
int amcl_midi_from_ump(const uint32_t* words, size_t available, AmclMidiDecoded* output);

/* Java时间戳以设备open时基为微秒，OH_MIDI以CLOCK_MONOTONIC纳秒为基准。
 * 负Java时间戳表示立即发送；0 native接收时间表示未知，不伪造成软件收到时刻。
 */
int amcl_midi_time_to_ns(uint64_t epochNs, int64_t microseconds, uint64_t* output);
int64_t amcl_midi_time_from_ns(uint64_t epochNs, uint64_t timestampNs);
#ifdef __cplusplus
}
#endif
#endif
