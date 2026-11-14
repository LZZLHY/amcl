/* protocol1实际字段正反例，不以平台MIDI服务替身冒充硬件收发。
 * 覆盖全部MIDI1通道/系统短消息、SysEx六字节边界和超过UINT32的真实时间范围。
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../../entry/src/main/cpp/javasound/midi_ump.h"
int main(void) {
    uint32_t words[2];
    AmclMidiDecoded decoded;
    unsigned channel_cases = 0;
    assert(amcl_midi_short_to_ump(0x00643c90, 0, words) == AMCL_MIDI_UMP_SHORT && words[0] == 0x20903c64);
    assert(amcl_midi_short_to_ump(0x000000f8, 0, words) == AMCL_MIDI_UMP_SHORT && words[0] == 0x10f80000);
    for (unsigned status = 0x80; status < 0xf0; ++status) {
        for (unsigned group = 0; group < 16; ++group) {
            uint32_t packed = status | (uint32_t)37 << 8 | (amcl_midi_short_size((uint8_t)status) == 3 ? (uint32_t)126 << 16 : 0);
            assert(amcl_midi_short_to_ump(packed, group, words) == AMCL_MIDI_UMP_SHORT);
            assert(amcl_midi_from_ump(words, 1, &decoded) == AMCL_MIDI_UMP_SHORT);
            assert(decoded.packed == packed && decoded.group == group);
            ++channel_cases;
        }
    }
    const uint8_t system[] = {0xf1,0xf2,0xf3,0xf6,0xf8,0xfa,0xfb,0xfc,0xfe,0xff};
    for (unsigned i = 0; i < sizeof(system); ++i) {
        unsigned length = amcl_midi_short_size(system[i]);
        uint32_t packed = system[i] | (length > 1 ? 35u << 8 : 0) | (length > 2 ? 69u << 16 : 0);
        assert(amcl_midi_short_to_ump(packed, 0, words) == AMCL_MIDI_UMP_SHORT);
        assert(amcl_midi_from_ump(words, 1, &decoded) == AMCL_MIDI_UMP_SHORT && decoded.packed == packed);
    }
    const uint8_t bytes[] = {0x7e,0x7f,0x06,0x01,0x20,0x42};
    for (unsigned form = 0; form < 4; ++form) for (unsigned count = 0; count <= 6; ++count) {
        assert(amcl_midi_sysex7_to_ump(form, 3, bytes, count, words) == AMCL_MIDI_UMP_SYSEX7);
        assert(amcl_midi_from_ump(words, 2, &decoded) == AMCL_MIDI_UMP_SYSEX7);
        assert(decoded.sysexForm == form && decoded.group == 3 && decoded.payloadSize == count);
        assert(memcmp(decoded.payload, bytes, count) == 0);
        assert(amcl_midi_from_ump(words, 1, &decoded) == AMCL_MIDI_UMP_INVALID);
    }
    assert(amcl_midi_sysex7_to_ump(0, 0, bytes, 6, words) == 2);
    assert(words[0] == 0x30067e7f && words[1] == 0x06012042);
    /* 独立规范向量：Microsoft MIDI UMP primer 的 General MIDI On，
     * F0 7E 7F 09 01 F7 -> 30047E7F 09010000，避免只用同一实现自校。 */
    const uint8_t gm_on[] = {0x7e, 0x7f, 0x09, 0x01};
    assert(amcl_midi_sysex7_to_ump(0, 0, gm_on, sizeof(gm_on), words) == 2);
    assert(words[0] == 0x30047e7f && words[1] == 0x09010000);
    assert(amcl_midi_short_to_ump(0xf0, 0, words) < 0);
    assert(amcl_midi_short_to_ump(0xf7, 0, words) < 0);
    assert(amcl_midi_short_to_ump(0x00008090, 0, words) < 0);
    assert(amcl_midi_short_to_ump(0x90003c90, 0, words) < 0);
    assert(amcl_midi_sysex7_to_ump(4, 0, bytes, 1, words) < 0);
    assert(amcl_midi_sysex7_to_ump(0, 0, bytes, 7, words) < 0);
    assert(amcl_midi_sysex7_to_ump(0, 0, NULL, 1, words) < 0);
    words[0] = 0x40903c00; assert(amcl_midi_from_ump(words, 2, &decoded) == AMCL_MIDI_UMP_UNSUPPORTED);
    words[0] = 0x10f00000; assert(amcl_midi_from_ump(words, 1, &decoded) == AMCL_MIDI_UMP_INVALID);
    words[0] = 0x30178000; assert(amcl_midi_from_ump(words, 2, &decoded) == AMCL_MIDI_UMP_INVALID);
    uint64_t timestamp;
    const uint64_t epoch = UINT64_C(170000000000);
    const int64_t beyond32 = INT64_C(4294967296) + 987;
    assert(amcl_midi_time_to_ns(epoch, beyond32, &timestamp) == 0);
    assert(amcl_midi_time_from_ns(epoch, timestamp) == beyond32);
    assert(amcl_midi_time_to_ns(epoch, -1, &timestamp) == 0 && timestamp == 0);
    assert(amcl_midi_time_from_ns(epoch, 0) == -1);
    assert(amcl_midi_time_from_ns(epoch, epoch - 1) == -1);
    assert(amcl_midi_time_to_ns(UINT64_MAX - 999, 1, &timestamp) == -1);
    assert(amcl_midi_time_to_ns(epoch, INT64_MAX, &timestamp) == -1);
    printf("PASS MIDI1 UMP codec: %u channel/group cases, 10 system forms, 28 SysEx boundaries, invalid/truncated/unsupported cases and 64-bit timestamps\n", channel_cases);
}
