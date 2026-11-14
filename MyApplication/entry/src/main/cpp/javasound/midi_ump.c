/* 字段按UMP数值位序构造，和主机字节序无关；不通过未对齐指针读取MIDI字节。 */
#include "midi_ump.h"
#include <limits.h>

unsigned amcl_midi_short_size(uint8_t status) {
    if (status < 0x80) return 0;
    if (status < 0xf0) return (status >> 4) == 0xc || (status >> 4) == 0xd ? 2 : 3;
    switch (status) {
        case 0xf1: case 0xf3: return 2;
        case 0xf2: return 3;
        case 0xf6: case 0xf8: case 0xfa: case 0xfb: case 0xfc: case 0xfe: case 0xff: return 1;
        default: return 0;
    }
}
int amcl_midi_short_to_ump(uint32_t packed, unsigned group, uint32_t* output) {
    const uint8_t status = (uint8_t)packed;
    const unsigned size = amcl_midi_short_size(status);
    const uint32_t first = (packed >> 8) & 255, second = (packed >> 16) & 255;
    if (!output || group > 15 || (packed >> 24) || !size || (size > 1 && first > 127) ||
        (size > 2 && second > 127)) return AMCL_MIDI_UMP_INVALID;
    *output = (status < 0xf0 ? UINT32_C(0x20000000) : UINT32_C(0x10000000)) |
        ((uint32_t)group << 24) | ((uint32_t)status << 16) |
        (size > 1 ? first << 8 : 0) | (size > 2 ? second : 0);
    return AMCL_MIDI_UMP_SHORT;
}
int amcl_midi_sysex7_to_ump(unsigned form, unsigned group, const uint8_t* bytes, size_t count, uint32_t output[2]) {
    if (!output || form > 3 || group > 15 || count > 6 || (count && !bytes)) return AMCL_MIDI_UMP_INVALID;
    uint32_t first = UINT32_C(0x30000000) | ((uint32_t)group << 24) | ((uint32_t)form << 20) | ((uint32_t)count << 16);
    uint32_t second = 0;
    for (size_t i = 0; i < count; ++i) {
        if (bytes[i] > 127) return AMCL_MIDI_UMP_INVALID;
        if (i < 2) first |= (uint32_t)bytes[i] << ((1 - (unsigned)i) * 8);
        else second |= (uint32_t)bytes[i] << ((5 - (unsigned)i) * 8);
    }
    output[0] = first; output[1] = second;
    return AMCL_MIDI_UMP_SYSEX7;
}
unsigned amcl_midi_protocol1_words(uint32_t first) {
    const unsigned type = first >> 28;
    return type <= 2 ? 1 : type == 3 ? 2 : 0;
}
int amcl_midi_from_ump(const uint32_t* words, size_t available, AmclMidiDecoded* output) {
    if (!words || !available || !output) return AMCL_MIDI_UMP_INVALID;
    const unsigned type = words[0] >> 28, size = amcl_midi_protocol1_words(words[0]);
    if (!size) return AMCL_MIDI_UMP_UNSUPPORTED;
    if (available < size) return AMCL_MIDI_UMP_INVALID;
    output->packed = 0; output->group = (uint8_t)((words[0] >> 24) & 15);
    output->sysexForm = 0; output->payloadSize = 0;
    if (type == 0) return AMCL_MIDI_UMP_UTILITY;
    if (type < 3) {
        const uint8_t status = (uint8_t)(words[0] >> 16);
        const unsigned bytes = amcl_midi_short_size(status);
        const uint32_t a = (words[0] >> 8) & 255, b = words[0] & 255;
        if (!bytes || (type == 1 ? status < 0xf0 : status >= 0xf0) ||
            (bytes > 1 && a > 127) || (bytes > 2 && b > 127)) return AMCL_MIDI_UMP_INVALID;
        output->packed = status | (bytes > 1 ? a << 8 : 0) | (bytes > 2 ? b << 16 : 0);
        return AMCL_MIDI_UMP_SHORT;
    }
    const unsigned form = (words[0] >> 20) & 15, count = (words[0] >> 16) & 15;
    if (form > 3 || count > 6) return AMCL_MIDI_UMP_INVALID;
    output->sysexForm = (uint8_t)form; output->payloadSize = (uint8_t)count;
    for (unsigned i = 0; i < count; ++i) {
        const uint8_t byte = (uint8_t)(i < 2 ? words[0] >> ((1 - i) * 8) : words[1] >> ((5 - i) * 8));
        if (byte > 127) return AMCL_MIDI_UMP_INVALID;
        output->payload[i] = byte;
    }
    return AMCL_MIDI_UMP_SYSEX7;
}
int amcl_midi_time_to_ns(uint64_t epochNs, int64_t microseconds, uint64_t* output) {
    if (!output) return -1;
    if (microseconds < 0) { *output = 0; return 0; }
    if ((uint64_t)microseconds > (UINT64_MAX - epochNs) / 1000) return -1;
    *output = epochNs + (uint64_t)microseconds * 1000;
    return 0;
}
int64_t amcl_midi_time_from_ns(uint64_t epochNs, uint64_t timestampNs) {
    if (!timestampNs || timestampNs < epochNs) return -1;
    return (int64_t)((timestampNs - epochNs) / 1000);
}
