/* 独立libohmidi.so测试供应者：动态解析真正经过生产midi_api.c。控制只有固定
 * 场景编号，不接受路径/代码/任意函数地址；用于JNI功能和错误闭包，不代表OHOS。 */
#include "fake_provider.h"
__attribute__((constructor)) static void initialize_provider(void) { fixtures(); }
#define EXPORT_AS(native, implementation) extern __typeof__(native) native __attribute__((alias(#implementation)));
EXPORT_AS(OH_MIDIClient_Create, create_client)
EXPORT_AS(OH_MIDIClient_Destroy, destroy_client)
EXPORT_AS(OH_MIDIClient_GetDeviceCount, get_count)
EXPORT_AS(OH_MIDIClient_GetDeviceInfos, get_infos)
EXPORT_AS(OH_MIDIClient_GetPortCount, port_count)
EXPORT_AS(OH_MIDIClient_GetPortInfos, port_infos)
EXPORT_AS(OH_MIDIClient_OpenDevice, open_device)
EXPORT_AS(OH_MIDIClient_CloseDevice, close_device)
EXPORT_AS(OH_MIDIDevice_OpenInputPort, input_open)
EXPORT_AS(OH_MIDIDevice_OpenOutputPort, output_open)
EXPORT_AS(OH_MIDIDevice_CloseInputPort, input_close)
EXPORT_AS(OH_MIDIDevice_CloseOutputPort, output_close)
#ifndef AMCL_MIDI_TEST_MISSING_SEND
EXPORT_AS(OH_MIDIDevice_Send, send_events)
#endif
EXPORT_AS(OH_MIDIDevice_FlushOutputPort, flush)
#undef EXPORT_AS

/* 正确typed签名但故意来自另一个DSO，负例必须在地址归属门拒绝而非真正调用。 */
void amcl_fake_foreign_received(void* user, const OH_MIDIEvent* events, size_t count) {
    (void)user; (void)events; (void)count; abort();
}
int64_t amcl_midi_fake_control(int mode) {
    (void)&api;
    switch (mode) {
        case 0: fixtures(); return 0;
        case 1: {
            assert(opened[0] && opened[0]->inputOpen);
            uint32_t word = 0x20903c64; OH_MIDIEvent event = {0, 1, &word};
            opened[0]->received(opened[0]->user, &event, 1); word = 0; return 0;
        }
        case 2: {
            assert(opened[0] && opened[0]->inputOpen);
            OH_MIDIEvent events[500]; uint32_t words[500][2];
            for (unsigned i = 0; i < 500; ++i) {
                unsigned form = i == 0 ? 1 : i == 499 ? 3 : 2;
                words[i][0] = 0x30067d7d | (form << 20); words[i][1] = 0x7d7d7d7d;
                events[i] = (OH_MIDIEvent){0, 2, words[i]};
            }
            opened[0]->received(opened[0]->user, events, 500);
            memset(words, 0, sizeof(words)); return 0;
        }
        case 3: sendError = 1; return 0;
        case 4: infoError = 1; return 0;
        case 5: sendError = infoError = 0; return 0;
        case 6:
            assert(client && !opened[0]);
            client->callbacks.onDeviceChange(client->user, OH_MIDI_DEVICE_CHANGE_ACTION_DISCONNECTED, infos[0]);
            client->callbacks.onDeviceChange(client->user, OH_MIDI_DEVICE_CHANGE_ACTION_CONNECTED, infos[0]); return 0;
        case 7: return (int64_t)atomic_load(&openCalls);
        case 8: return (int64_t)atomic_load(&closeCalls);
        case 9: return (int64_t)atomic_load(&sentCount);
        case 10: {
            unsigned n = atomic_load(&sentCount); assert(n >= 2);
            return (int64_t)(sent[n-1].timestamp - sent[n-2].timestamp);
        }
        case 11: assert(client); client->callbacks.onError(client->user, OH_MIDI_STATUS_SERVICE_DIED); return 0;
        default: abort();
    }
}
