/* 系统可调用的MIDI边界。嵌入场景只把正常签名加载的HAP函数注册给OH_MIDI，
 * 函数仅修改本头定义的版本化POD并复制借用数据，不回调JDK代码、不进入JNI。
 * 独立CLI的相同源码由系统链接器正常登记，可用本地表。队列是多生产者/单消费者，
 * 回调无堆分配、无互斥锁、无阻塞等待；容量不足是可见错误，不覆盖未读音乐数据。
 */
#ifndef AMCL_MIDI_CALLBACKS_H
#define AMCL_MIDI_CALLBACKS_H
#include <ohmidi/native_midi_base.h>
#include <semaphore.h>
#include <string.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define AMCL_MIDI_CALLBACK_ABI 1u
#define AMCL_MIDI_POD_LAYOUT 1u
#define AMCL_MIDI_PACKET_CAPACITY 4096u
#define AMCL_MIDI_NOTICE_CAPACITY 128u
enum {
    AMCL_MIDI_BAD_PACKET = -12001,
    AMCL_MIDI_QUEUE_FULL = -12002,
    AMCL_MIDI_CALLBACK_CONTENTION = -12003,
    AMCL_MIDI_WAKE_FAILED = -12004
};
typedef struct {
    uint64_t timestamp;
    uint32_t words[2];
    uint32_t wordCount;
} AmclMidiPacket;
typedef struct { uint64_t sequence; AmclMidiPacket packet; } AmclMidiPacketSlot;
typedef struct {
    uint32_t layout, closing, active;
    int32_t error;
    uint32_t wakePending;
    uint64_t enqueue, dequeue, receivedPackets, receivedWords;
    sem_t wake;
    AmclMidiPacketSlot slots[AMCL_MIDI_PACKET_CAPACITY];
} AmclMidiInputPod;
typedef struct { int64_t deviceId; int32_t action; } AmclMidiNotice;
typedef struct { uint64_t sequence; AmclMidiNotice notice; } AmclMidiNoticeSlot;
typedef struct {
    uint32_t layout, closing, active, invalidated;
    int32_t error;
    uint64_t epoch, enqueue, dequeue;
    AmclMidiNoticeSlot slots[AMCL_MIDI_NOTICE_CAPACITY];
} AmclMidiClientPod;

/* 初始化/销毁仅由控制线程调用；sem_t属于公开libc ABI，表校验同时检查其外层
 * 结构大小/对齐。SDK成功CloseInputPort且active=0之后才允许sem_destroy/free。 */
static inline int amcl_midi_input_init(AmclMidiInputPod* pod) {
    memset(pod, 0, sizeof(*pod)); pod->layout = AMCL_MIDI_POD_LAYOUT;
    for (uint64_t i = 0; i < AMCL_MIDI_PACKET_CAPACITY; ++i) pod->slots[i].sequence = i;
    return sem_init(&pod->wake, 0, 0);
}
static inline void amcl_midi_client_init(AmclMidiClientPod* pod) {
    memset(pod, 0, sizeof(*pod)); pod->layout = AMCL_MIDI_POD_LAYOUT;
    for (uint64_t i = 0; i < AMCL_MIDI_NOTICE_CAPACITY; ++i) pod->slots[i].sequence = i;
}
static inline void amcl_midi_input_wake(AmclMidiInputPod* pod) {
    if (!__atomic_exchange_n(&pod->wakePending, 1u, __ATOMIC_ACQ_REL) && sem_post(&pod->wake) != 0)
        __atomic_store_n(&pod->error, AMCL_MIDI_WAKE_FAILED, __ATOMIC_RELEASE);
}
static inline void amcl_midi_input_error(AmclMidiInputPod* pod, int error) {
    int32_t expected = 0;
    __atomic_compare_exchange_n(&pod->error, &expected, error, 0, __ATOMIC_RELEASE, __ATOMIC_RELAXED);
    amcl_midi_input_wake(pod);
}

/* sequence发布在payload写完之后。CAS竞争有界，异常多生产者持续争抢会明确报错；
 * 回调不会等消费线程，也不会借用事件在返回之后失效的data指针。 */
static inline int amcl_midi_packet_push(AmclMidiInputPod* pod, const OH_MIDIEvent* event,
                                        size_t offset, unsigned words) {
    uint64_t position = __atomic_load_n(&pod->enqueue, __ATOMIC_RELAXED);
    for (unsigned retry = 0; retry < 128; ++retry) {
        AmclMidiPacketSlot* slot = &pod->slots[position & (AMCL_MIDI_PACKET_CAPACITY - 1u)];
        uint64_t sequence = __atomic_load_n(&slot->sequence, __ATOMIC_ACQUIRE);
        int64_t delta = (int64_t)(sequence - position);
        if (delta < 0) return AMCL_MIDI_QUEUE_FULL;
        if (delta == 0 && __atomic_compare_exchange_n(&pod->enqueue, &position, position + 1,
                                                     1, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
            slot->packet.timestamp = event->timestamp;
            slot->packet.wordCount = words;
            slot->packet.words[0] = event->data[offset];
            slot->packet.words[1] = words == 2 ? event->data[offset + 1] : 0;
            __atomic_store_n(&slot->sequence, position + 1, __ATOMIC_RELEASE);
            __atomic_add_fetch(&pod->receivedPackets, 1, __ATOMIC_RELAXED);
            __atomic_add_fetch(&pod->receivedWords, words, __ATOMIC_RELAXED);
            return 0;
        }
        position = __atomic_load_n(&pod->enqueue, __ATOMIC_RELAXED);
    }
    return AMCL_MIDI_CALLBACK_CONTENTION;
}
/* 单消费线程取得的是自有副本，随后立即归还槽位，不持队列槽跨Java用户回调。 */
static inline int amcl_midi_packet_pop(AmclMidiInputPod* pod, AmclMidiPacket* packet) {
    uint64_t position = pod->dequeue;
    AmclMidiPacketSlot* slot = &pod->slots[position & (AMCL_MIDI_PACKET_CAPACITY - 1u)];
    if (__atomic_load_n(&slot->sequence, __ATOMIC_ACQUIRE) != position + 1) return 0;
    *packet = slot->packet;
    __atomic_store_n(&slot->sequence, position + AMCL_MIDI_PACKET_CAPACITY, __ATOMIC_RELEASE);
    pod->dequeue = position + 1;
    return 1;
}
static inline int amcl_midi_notice_pop(AmclMidiClientPod* pod, AmclMidiNotice* notice) {
    uint64_t position = pod->dequeue;
    AmclMidiNoticeSlot* slot = &pod->slots[position & (AMCL_MIDI_NOTICE_CAPACITY - 1u)];
    if (__atomic_load_n(&slot->sequence, __ATOMIC_ACQUIRE) != position + 1) return 0;
    *notice = slot->notice;
    __atomic_store_n(&slot->sequence, position + AMCL_MIDI_NOTICE_CAPACITY, __ATOMIC_RELEASE);
    pod->dequeue = position + 1;
    return 1;
}

/* 这些精确SDK签名直接放入函数指针表，不能用void*万能跳板接受任意函数地址。 */
static inline void amcl_midi_on_device_change(void* user, OH_MIDIDeviceChangeAction action,
                                               OH_MIDIDeviceInformation info) {
    AmclMidiClientPod* pod = (AmclMidiClientPod*)user;
    if (!pod) return;
    __atomic_add_fetch(&pod->active, 1u, __ATOMIC_SEQ_CST);
    if (!__atomic_load_n(&pod->closing, __ATOMIC_ACQUIRE) && pod->layout == AMCL_MIDI_POD_LAYOUT) {
        uint64_t position = __atomic_load_n(&pod->enqueue, __ATOMIC_RELAXED);
        int published = 0;
        for (unsigned retry = 0; retry < 128; ++retry) {
            AmclMidiNoticeSlot* slot = &pod->slots[position & (AMCL_MIDI_NOTICE_CAPACITY - 1u)];
            int64_t delta = (int64_t)(__atomic_load_n(&slot->sequence, __ATOMIC_ACQUIRE) - position);
            if (delta < 0) break;
            if (delta == 0 && __atomic_compare_exchange_n(&pod->enqueue, &position, position + 1,
                                                         1, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
                slot->notice.deviceId = info.midiDeviceId; slot->notice.action = (int32_t)action;
                __atomic_store_n(&slot->sequence, position + 1, __ATOMIC_RELEASE);
                published = 1; break;
            }
            position = __atomic_load_n(&pod->enqueue, __ATOMIC_RELAXED);
        }
        if (!published) __atomic_store_n(&pod->invalidated, 1u, __ATOMIC_RELEASE);
        __atomic_add_fetch(&pod->epoch, 1, __ATOMIC_RELEASE);
    }
    __atomic_sub_fetch(&pod->active, 1u, __ATOMIC_SEQ_CST);
}
static inline void amcl_midi_on_error(void* user, OH_MIDIStatusCode code) {
    AmclMidiClientPod* pod = (AmclMidiClientPod*)user;
    if (!pod) return;
    __atomic_add_fetch(&pod->active, 1u, __ATOMIC_SEQ_CST);
    if (!__atomic_load_n(&pod->closing, __ATOMIC_ACQUIRE) && pod->layout == AMCL_MIDI_POD_LAYOUT) {
        int32_t expected = 0;
        __atomic_compare_exchange_n(&pod->error, &expected, (int32_t)code, 0, __ATOMIC_RELEASE, __ATOMIC_RELAXED);
        __atomic_add_fetch(&pod->epoch, 1, __ATOMIC_RELEASE);
    }
    __atomic_sub_fetch(&pod->active, 1u, __ATOMIC_SEQ_CST);
}
static inline void amcl_midi_on_received(void* user, const OH_MIDIEvent* events, size_t count) {
    AmclMidiInputPod* pod = (AmclMidiInputPod*)user;
    if (!pod) return;
    __atomic_add_fetch(&pod->active, 1u, __ATOMIC_SEQ_CST);
    if (__atomic_load_n(&pod->closing, __ATOMIC_ACQUIRE) || pod->layout != AMCL_MIDI_POD_LAYOUT) goto done;
    if ((!events && count) || count > AMCL_MIDI_PACKET_CAPACITY) {
        amcl_midi_input_error(pod, AMCL_MIDI_BAD_PACKET); goto done;
    }
    for (size_t i = 0; i < count; ++i) {
        if (!events[i].data || !events[i].length || events[i].length > 128) {
            amcl_midi_input_error(pod, AMCL_MIDI_BAD_PACKET); break;
        }
        for (size_t offset = 0; offset < events[i].length;) {
            unsigned type = events[i].data[offset] >> 28;
            unsigned words = type <= 2 ? 1u : type == 3 ? 2u : 0u;
            if (!words || words > events[i].length - offset) {
                amcl_midi_input_error(pod, AMCL_MIDI_BAD_PACKET); goto done;
            }
            int result = amcl_midi_packet_push(pod, &events[i], offset, words);
            if (result) { amcl_midi_input_error(pod, result); goto done; }
            offset += words;
        }
    }
    if (count) amcl_midi_input_wake(pod);
done:
    __atomic_sub_fetch(&pod->active, 1u, __ATOMIC_SEQ_CST);
}

typedef struct {
    uint32_t abiVersion, tableSize, layoutVersion;
    uint32_t clientSize, inputSize, clientAlignment, inputAlignment;
    OH_MIDICallback_OnDeviceChange onDeviceChange;
    OH_MIDICallback_OnError onError;
    OH_MIDIDevice_OnReceived onReceived;
} AmclMidiCallbackAbiV1;
static inline const AmclMidiCallbackAbiV1* amcl_midi_local_callbacks_v1(void) {
    static const AmclMidiCallbackAbiV1 table = {
        AMCL_MIDI_CALLBACK_ABI, sizeof(AmclMidiCallbackAbiV1), AMCL_MIDI_POD_LAYOUT,
        sizeof(AmclMidiClientPod), sizeof(AmclMidiInputPod),
        __alignof__(AmclMidiClientPod), __alignof__(AmclMidiInputPod),
        amcl_midi_on_device_change, amcl_midi_on_error, amcl_midi_on_received
    };
    return &table;
}
static inline int amcl_midi_callbacks_valid_v1(const AmclMidiCallbackAbiV1* table) {
    return table && table->abiVersion == AMCL_MIDI_CALLBACK_ABI && table->tableSize == sizeof(*table) &&
        table->layoutVersion == AMCL_MIDI_POD_LAYOUT && table->clientSize == sizeof(AmclMidiClientPod) &&
        table->inputSize == sizeof(AmclMidiInputPod) && table->clientAlignment == __alignof__(AmclMidiClientPod) &&
        table->inputAlignment == __alignof__(AmclMidiInputPod) && table->onDeviceChange && table->onError && table->onReceived;
}
__attribute__((visibility("default"))) const AmclMidiCallbackAbiV1* amcl_javasound_midi_callbacks_v1(void);
#ifdef __cplusplus
}
#endif
#endif
