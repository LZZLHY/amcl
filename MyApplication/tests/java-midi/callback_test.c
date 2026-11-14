/* 正常dlopen的真实宿主源码回归：临时数据复制、并发生产、满队列显式失败、
 * 热插拔同数量替换通知、关闭后迟到回调及实际sem唤醒。不把故障注入称为设备收发。 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <assert.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include "../../entry/src/main/cpp/javasound/midi_callbacks.h"
static const AmclMidiCallbackAbiV1* callbacks;
static AmclMidiInputPod* input;
static void* producer(void* argument) {
    uintptr_t index = (uintptr_t)argument;
    for (unsigned i = 0; i < 1000; ++i) {
        uint32_t word = 0x20903c64;
        OH_MIDIEvent event = { .timestamp = index * 1000 + i + 1, .length = 1, .data = &word };
        callbacks->onReceived(input, &event, 1);
        word = 0; /* 返回后立即覆盖原缓冲，消费方必须读到独立的复制。 */
    }
    return NULL;
}
int main(int argc, char** argv) {
    assert(argc == 2);
    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    assert(library);
    const AmclMidiCallbackAbiV1* (*getter)(void) = dlsym(library, "amcl_javasound_midi_callbacks_v1");
    assert(getter && amcl_midi_callbacks_valid_v1(callbacks = getter()));
    Dl_info owner, address;
    assert(dladdr((void*)getter, &owner));
    const void* addresses[] = { callbacks, (void*)callbacks->onDeviceChange, (void*)callbacks->onError, (void*)callbacks->onReceived };
    for (unsigned i = 0; i < sizeof(addresses)/sizeof(addresses[0]); ++i)
        assert(dladdr(addresses[i], &address) && address.dli_fbase == owner.dli_fbase);
    AmclMidiCallbackAbiV1 wrong = *callbacks;
    wrong.layoutVersion++; assert(!amcl_midi_callbacks_valid_v1(&wrong));
    wrong = *callbacks; wrong.inputSize--; assert(!amcl_midi_callbacks_valid_v1(&wrong));
    wrong = *callbacks; wrong.inputAlignment++; assert(!amcl_midi_callbacks_valid_v1(&wrong));
    input = calloc(1, sizeof(*input)); assert(input && !amcl_midi_input_init(input));
    pthread_t threads[4];
    for (uintptr_t i = 0; i < 4; ++i) assert(!pthread_create(&threads[i], NULL, producer, (void*)i));
    for (unsigned i = 0; i < 4; ++i) assert(!pthread_join(threads[i], NULL));
    assert(!input->error && input->receivedPackets == 4000 && input->receivedWords == 4000 && !input->active);
    assert(sem_trywait(&input->wake) == 0);
    unsigned char seen[4000] = {0};
    AmclMidiPacket packet;
    for (unsigned i = 0; i < 4000; ++i) {
        assert(amcl_midi_packet_pop(input, &packet));
        assert(packet.wordCount == 1 && packet.words[0] == 0x20903c64 && !packet.words[1]);
        assert(packet.timestamp >= 1 && packet.timestamp <= 4000 && !seen[packet.timestamp-1]);
        seen[packet.timestamp-1] = 1;
    }
    assert(!amcl_midi_packet_pop(input, &packet));
    uint32_t data[] = {0x30047e7f, 0x09010000, 0x10f80000};
    OH_MIDIEvent event = { .timestamp = UINT64_C(4294967296999), .length = 3, .data = data };
    callbacks->onReceived(input, &event, 1); memset(data, 0, sizeof(data));
    assert(amcl_midi_packet_pop(input, &packet) && packet.wordCount == 2 && packet.words[1] == 0x09010000);
    assert(packet.timestamp == UINT64_C(4294967296999));
    assert(amcl_midi_packet_pop(input, &packet) && packet.words[0] == 0x10f80000);
    data[0] = 0x20903c64; event.length = 1;
    for (unsigned i = 0; i < AMCL_MIDI_PACKET_CAPACITY; ++i) callbacks->onReceived(input, &event, 1);
    assert(!input->error);
    callbacks->onReceived(input, &event, 1); assert(input->error == AMCL_MIDI_QUEUE_FULL);
    for (unsigned i = 0; i < AMCL_MIDI_PACKET_CAPACITY; ++i)
        assert(amcl_midi_packet_pop(input, &packet) && packet.words[0] == 0x20903c64);
    assert(!amcl_midi_packet_pop(input, &packet));
    input->error = 0; data[0] = 0x30047e7f; callbacks->onReceived(input, &event, 1);
    assert(input->error == AMCL_MIDI_BAD_PACKET);
    input->error = 0; data[0] = 0x40903c64; callbacks->onReceived(input, &event, 1);
    assert(input->error == AMCL_MIDI_BAD_PACKET);
    input->closing = 1; uint64_t received = input->receivedPackets;
    for (unsigned i = 0; i < 10000; ++i) callbacks->onReceived(input, &event, 1);
    assert(!input->active && input->receivedPackets == received);
    assert(!sem_destroy(&input->wake)); free(input);
    AmclMidiClientPod* client = calloc(1, sizeof(*client)); assert(client); amcl_midi_client_init(client);
    OH_MIDIDeviceInformation info = {0}; info.midiDeviceId = 72; info.deviceType = OH_MIDI_DEVICE_TYPE_BLE;
    callbacks->onDeviceChange(client, OH_MIDI_DEVICE_CHANGE_ACTION_DISCONNECTED, info);
    callbacks->onDeviceChange(client, OH_MIDI_DEVICE_CHANGE_ACTION_CONNECTED, info);
    AmclMidiNotice notice;
    assert(amcl_midi_notice_pop(client, &notice) && notice.deviceId == 72 && notice.action == OH_MIDI_DEVICE_CHANGE_ACTION_DISCONNECTED);
    assert(amcl_midi_notice_pop(client, &notice) && notice.action == OH_MIDI_DEVICE_CHANGE_ACTION_CONNECTED);
    assert(!amcl_midi_notice_pop(client, &notice) && client->epoch == 2);
    for (unsigned i = 0; i <= AMCL_MIDI_NOTICE_CAPACITY; ++i) callbacks->onDeviceChange(client, OH_MIDI_DEVICE_CHANGE_ACTION_CONNECTED, info);
    assert(client->invalidated);
    callbacks->onError(client, OH_MIDI_STATUS_SERVICE_DIED); assert(client->error == OH_MIDI_STATUS_SERVICE_DIED);
    client->closing = 1; uint64_t epoch = client->epoch;
    callbacks->onError(client, OH_MIDI_STATUS_SYSTEM_ERROR);
    callbacks->onDeviceChange(client, OH_MIDI_DEVICE_CHANGE_ACTION_DISCONNECTED, info);
    assert(client->epoch == epoch && !client->active);
    free(client); dlclose(library);
    puts("PASS MIDI typed callbacks: real DSO identity, 4000 concurrent copied packets, SysEx/clock/time, overflow, malformed packets, hotplug, service error and 10000 late callbacks");
}
