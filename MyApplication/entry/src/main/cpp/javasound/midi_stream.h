/* Java SysexMessage 的F0/F7分段及F7逃逸字节流转换。状态在控制线程/发送锁下使用，
 * 与系统实时回调无关；Send成功之前只修改副本，拒绝或WOULD_BLOCK不提前消费字节。
 */
#ifndef AMCL_MIDI_STREAM_H
#define AMCL_MIDI_STREAM_H
#include "midi_ump.h"
typedef struct {
    uint8_t running, status, have, need;
    uint8_t data[2];
    uint8_t sysexOpen, sysexSent, sysexSize, sysex[6];
    uint64_t timestamp;
} AmclMidiStream;
typedef struct { uint32_t words[2]; unsigned count; uint64_t timestamp; } AmclMidiOutput;
/* 返回1=形成一个UMP，0=本段已耗尽且可能仍有跨段消息，负值=非法MIDI字节序列。
 * SysEx Start/Continue合法携带0..6字节；本段结束即提交已有数据，不能为了凑满
 * 六字节延迟原Java时间戳。调用方应持续调用至返回0，而不是只检查offset。
 * 调用方负责跳过Java长消息的首个F7 continuation marker（长度>1时），真实末尾
 * EOX仍通过此解析器。running status只允许通道消息，System Common会取消它。
 */
int amcl_midi_stream_next(AmclMidiStream* state, unsigned group, const uint8_t* data,
                         size_t length, size_t* offset, uint64_t timestamp, AmclMidiOutput* output);
#endif
