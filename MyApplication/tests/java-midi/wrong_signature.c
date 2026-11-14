/* 故意错误的返回类型，必须由真实SDK的typedef在编译期拒绝。 */
#include "../../entry/src/main/cpp/javasound/midi_callbacks.h"
static int wrong(void* user, const OH_MIDIEvent* events, size_t count) {
    (void)user; (void)events; (void)count; return 0;
}
OH_MIDIDevice_OnReceived invalid_callback = wrong;
