/* 完整消息和跨调用分段使用同一转换路径，保留原MIDI时间戳。SysEx的六字节暂存
 * 只为确定Start/Complete形式，不限制整条消息大小；任意长度由多个UMP连续发送。
 * UMP规范7.7允许Start/Continue携带0..6字节，因此实时消息和调用边界之前可先
 * 发布已有SysEx，既不移动时间也不将时钟消息排到先前的SysEx数据之前。
 */
#include "midi_stream.h"
#include <string.h>
int amcl_midi_stream_next(AmclMidiStream* s, unsigned group, const uint8_t* data,
                         size_t length, size_t* offset, uint64_t timestamp, AmclMidiOutput* out) {
    if (!s || !offset || !out || group > 15 || (*offset > length) || (length && !data)) return -1;
    out->count = 0;
    while (*offset < length) {
        uint8_t b = data[*offset];
        /* 实时消息允许插入SysEx和未完成的短消息，不能取消其状态。 */
        if (b >= 0xf8) {
            if (s->sysexOpen && (s->sysexSize || !s->sysexSent)) {
                if (amcl_midi_sysex7_to_ump(s->sysexSent ? 2 : 1, group, s->sysex, s->sysexSize, out->words) < 0) return -1;
                out->count = 2; out->timestamp = s->timestamp;
                s->sysexSent = 1; s->sysexSize = 0; s->timestamp = timestamp;
                return 1;
            }
            if (amcl_midi_short_to_ump(b, group, out->words) < 0) return -1;
            ++*offset; out->count = 1; out->timestamp = timestamp; return 1;
        }
        if (s->sysexOpen) {
            if (b == 0xf7) {
                if (amcl_midi_sysex7_to_ump(s->sysexSent ? 3 : 0, group, s->sysex,
                                           s->sysexSize, out->words) < 0) return -1;
                out->count = 2; out->timestamp = s->timestamp;
                s->sysexOpen = s->sysexSent = s->sysexSize = 0; ++*offset; return 1;
            }
            if (b >= 0x80) return -1;
            if (s->sysexSize == 6) {
                if (amcl_midi_sysex7_to_ump(s->sysexSent ? 2 : 1, group, s->sysex, 6, out->words) < 0) return -1;
                out->count = 2; out->timestamp = s->timestamp;
                s->sysexSent = 1; s->sysexSize = 0; s->timestamp = timestamp;
                return 1; /* 本字节尚未消费，交给下一包。 */
            }
            if (!s->sysexSize && s->sysexSent) s->timestamp = timestamp;
            s->sysex[s->sysexSize++] = b; ++*offset; continue;
        }
        if (b == 0xf0) {
            if (s->status) return -1;
            s->running = 0; s->sysexOpen = 1; s->sysexSent = s->sysexSize = 0;
            s->timestamp = timestamp; ++*offset; continue;
        }
        if (b >= 0x80) {
            unsigned total = amcl_midi_short_size(b);
            if (!total || s->status) return -1;
            s->status = b; s->running = b < 0xf0 ? b : 0;
            s->have = 0; s->need = (uint8_t)(total - 1); s->timestamp = timestamp; ++*offset;
        } else {
            if (!s->status) {
                if (!s->running) return -1;
                s->status = s->running; s->have = 0;
                s->need = (uint8_t)(amcl_midi_short_size(s->status) - 1); s->timestamp = timestamp;
            }
            if (s->have >= s->need || s->have >= sizeof(s->data)) return -1;
            s->data[s->have++] = b; ++*offset;
        }
        if (s->have == s->need) {
            uint32_t packed = s->status | (s->need ? (uint32_t)s->data[0] << 8 : 0) |
                (s->need > 1 ? (uint32_t)s->data[1] << 16 : 0);
            if (amcl_midi_short_to_ump(packed, group, out->words) < 0) return -1;
            out->count = 1; out->timestamp = s->timestamp;
            s->status = s->have = s->need = 0; return 1;
        }
    }
    if (s->sysexOpen && (s->sysexSize || !s->sysexSent)) {
        if (amcl_midi_sysex7_to_ump(s->sysexSent ? 2 : 1, group, s->sysex, s->sysexSize, out->words) < 0) return -1;
        out->count = 2; out->timestamp = s->timestamp;
        s->sysexSent = 1; s->sysexSize = 0; return 1;
    }
    return 0;
}
