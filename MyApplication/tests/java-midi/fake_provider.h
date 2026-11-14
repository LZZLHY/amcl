/* 有状态SDK供应者，仅用于宿主故障注入。签名直接服从固定真实SDK声明，
 * 与实际平台服务和硬件资格分开；core与JNI两层回归共同消费同一个供应者。 */
#ifndef AMCL_MIDI_FAKE_PROVIDER_H
#define AMCL_MIDI_FAKE_PROVIDER_H
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../entry/src/main/cpp/javasound/midi_core.h"
struct OH_MIDIClientStruct { OH_MIDICallbacks callbacks; void* user; };
struct OH_MIDIDeviceStruct {
    int64_t id;
    OH_MIDIDevice_OnReceived received;
    void* user;
    int inputOpen, outputOpen;
};
static OH_MIDIDeviceInformation infos[2];
static OH_MIDIPortInformation ports[4];
static OH_MIDIClient* client;
static OH_MIDIDevice* opened[2];
static _Atomic unsigned openCalls, closeCalls, destroyCalls, sendCalls, sentCount;
static AmclMidiPacket sent[2000];
static int infoError, duplicatePort, partial, closePortError, destroyError, createError, sendError;
static _Atomic int blockSend;
static int which(int64_t id) { return id == infos[0].midiDeviceId ? 0 : id == infos[1].midiDeviceId ? 1 : -1; }
static OH_MIDIStatusCode create_client(OH_MIDIClient** out, OH_MIDICallbacks callbacks, void* user) {
    if (createError) return OH_MIDI_STATUS_GENERIC_IPC_FAILURE;
    assert(!client); client = calloc(1, sizeof(*client)); assert(client);
    client->callbacks = callbacks; client->user = user; *out = client; return 0;
}
static OH_MIDIStatusCode destroy_client(OH_MIDIClient* current) {
    assert(current == client && !opened[0] && !opened[1]); ++destroyCalls;
    free(client); client = NULL; return destroyError ? OH_MIDI_STATUS_GENERIC_IPC_FAILURE : 0;
}
static OH_MIDIStatusCode get_count(const OH_MIDIClient* current, size_t* count) {
    assert(current == client); *count = 0; return 0; /* 故意模拟不可靠的计数预估。 */
}
static OH_MIDIStatusCode get_infos(const OH_MIDIClient* current, OH_MIDIDeviceInformation* out, size_t capacity, size_t* count) {
    assert(current == client && capacity > 0);
    if (infoError) return OH_MIDI_STATUS_GENERIC_IPC_FAILURE;
    *count = capacity < 2 ? capacity : 2; memcpy(out, infos, *count * sizeof(*out)); return 0;
}
static OH_MIDIStatusCode port_count(const OH_MIDIClient* current, int64_t id, size_t* count) {
    assert(current == client); if (which(id) < 0) return OH_MIDI_STATUS_INVALID_DEVICE_HANDLE; *count = 1; return 0;
}
static OH_MIDIStatusCode port_infos(const OH_MIDIClient* current, int64_t id, OH_MIDIPortInformation* out, size_t capacity, size_t* count) {
    assert(current == client); int i = which(id); if (i < 0) return OH_MIDI_STATUS_INVALID_DEVICE_HANDLE;
    *count = capacity < 2 ? capacity : 2; memcpy(out, ports + i*2, *count * sizeof(*out));
    if (duplicatePort && *count == 2) out[1] = out[0];
    return 0;
}
static OH_MIDIStatusCode open_device(OH_MIDIClient* current, int64_t id, OH_MIDIDevice** out) {
    assert(current == client); int index = which(id); if (index < 0) return OH_MIDI_STATUS_INVALID_DEVICE_HANDLE;
    if (opened[index]) return OH_MIDI_STATUS_DEVICE_ALREADY_OPEN;
    opened[index] = calloc(1, sizeof(**out)); assert(opened[index]); opened[index]->id = id;
    *out = opened[index]; ++openCalls; return 0;
}
static OH_MIDIStatusCode close_device(OH_MIDIClient* current, OH_MIDIDevice* device) {
    assert(current == client); int index = -1;
    for (int i = 0; i < 2; ++i) if (opened[i] == device) index = i;
    assert(index >= 0); free(device); opened[index] = NULL; ++closeCalls; return 0;
}
static OH_MIDIStatusCode input_open(OH_MIDIDevice* device, OH_MIDIPortDescriptor descriptor,
                                   OH_MIDIDevice_OnReceived callback, void* user) {
    assert(descriptor.protocol == OH_MIDI_PROTOCOL_1_0 && descriptor.portIndex == ports[which(device->id)*2].portIndex);
    assert(!device->inputOpen); device->received = callback; device->user = user; device->inputOpen = 1; return 0;
}
static OH_MIDIStatusCode output_open(OH_MIDIDevice* device, OH_MIDIPortDescriptor descriptor) {
    assert(descriptor.protocol == OH_MIDI_PROTOCOL_1_0 && descriptor.portIndex == ports[which(device->id)*2+1].portIndex);
    assert(!device->outputOpen); device->outputOpen = 1; return 0;
}
static OH_MIDIStatusCode input_close(OH_MIDIDevice* device, uint32_t port) {
    (void)port; assert(device->inputOpen); device->inputOpen = 0;
    return closePortError ? OH_MIDI_STATUS_GENERIC_IPC_FAILURE : 0;
}
static OH_MIDIStatusCode output_close(OH_MIDIDevice* device, uint32_t port) {
    (void)port; assert(device->outputOpen); device->outputOpen = 0; return 0;
}
static OH_MIDIStatusCode send_events(OH_MIDIDevice* device, uint32_t port, const OH_MIDIEvent* events,
                                    uint32_t count, uint32_t* written) {
    assert(device->outputOpen && port == ports[which(device->id)*2+1].portIndex); ++sendCalls;
    if (sendError) { *written = 0; return OH_MIDI_STATUS_PERMISSION_DENIED; }
    if (atomic_load(&blockSend)) { *written = 0; return OH_MIDI_STATUS_WOULD_BLOCK; }
    *written = partial && count > 7 ? 7 : count;
    for (unsigned i = 0; i < *written; ++i) {
        assert(sentCount < sizeof(sent)/sizeof(sent[0]) && events[i].length <= 2);
        AmclMidiPacket* p = &sent[sentCount++]; p->timestamp = events[i].timestamp; p->wordCount = (uint32_t)events[i].length;
        memcpy(p->words, events[i].data, p->wordCount*sizeof(uint32_t));
    }
    int wasPartial = partial; partial = 0; return wasPartial ? OH_MIDI_STATUS_WOULD_BLOCK : 0;
}
static OH_MIDIStatusCode flush(OH_MIDIDevice* device, uint32_t port) { (void)device; (void)port; return 0; }
static AmclMidiApi api = {
    .Create=create_client,.Destroy=destroy_client,.GetDeviceCount=get_count,.GetDeviceInfos=get_infos,
    .GetPortCount=port_count,.GetPortInfos=port_infos,.OpenDevice=open_device,.CloseDevice=close_device,
    .OpenInputPort=input_open,.OpenOutputPort=output_open,.CloseInputPort=input_close,.CloseOutputPort=output_close,
    .Send=send_events,.FlushOutputPort=flush
};
static void fixtures(void) {
    memset(infos,0,sizeof(infos)); memset(ports,0,sizeof(ports));
    infos[0].midiDeviceId=40; infos[0].deviceType=OH_MIDI_DEVICE_TYPE_USB; infos[0].nativeProtocol=OH_MIDI_PROTOCOL_2_0;
    strcpy(infos[0].deviceName,"USB-\xe4\xb9\x90\xe5\x99\xa8-\xf0\x9f\x8e\xb9");
    infos[1].midiDeviceId=72; infos[1].deviceType=OH_MIDI_DEVICE_TYPE_BLE; infos[1].nativeProtocol=OH_MIDI_PROTOCOL_1_0;
    strcpy(infos[1].deviceName,"BLE keyboard");strcpy(infos[1].deviceAddress,"02:01:02:03:04:05");
    for(unsigned i=0;i<4;++i) { ports[i].deviceId=infos[i/2].midiDeviceId; ports[i].direction=i%2;
        ports[i].portIndex=(uint32_t[]){9,27,4,41}[i]; snprintf(ports[i].name,sizeof(ports[i].name),"real-port-%u",ports[i].portIndex); }
}

#endif
