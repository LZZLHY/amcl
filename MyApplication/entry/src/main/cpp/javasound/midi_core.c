/* 所有SDK调用位于普通控制/既有Java MIDI输入线程。系统回调只接触独立POD，
 * 因而manager锁不会与回调形成反向等待，也无需新增常驻broker线程。
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "midi_core.h"
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <time.h>

typedef struct AmclMidiDevice {
    int64_t id;
    OH_MIDIDevice* native;
    unsigned openPorts, references;
    struct AmclMidiDevice* next;
} AmclMidiDevice;
struct AmclMidiUse {
    AmclMidiManager* manager;
    AmclMidiDevice* device;
    uint64_t token, epoch;
    uint32_t port, closed, stopped, reading, disconnected;
    int direction, portOpen, everStarted, safe, error;
    unsigned references;
    pthread_mutex_t io;
    AmclMidiInputPod* input;
    AmclMidiStream stream;
    uint8_t receivingSysex[16];
    AmclMidiPacket pending;
    int hasPending;
    struct AmclMidiUse* next;
};
struct AmclMidiManager {
    pthread_mutex_t lock;
    const AmclMidiApi* api;
    const AmclMidiCallbackAbiV1* callbacks;
    OH_MIDIClient* client;
    AmclMidiClientPod* pod;
    AmclMidiEndpoint* endpoints;
    size_t count;
    uint64_t nextHandle, appliedEpoch;
    int32_t nextEndpoint;
    int destroying, destroyStatus, serviceReported, recreate;
    AmclMidiDevice* devices;
    AmclMidiUse *handles, *retired;
};

static uint64_t monotonic_ns(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return 0;
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}
/* SDK成功关闭后的在途计数等待；超时不释放它仍可访问的内存。SDK本身的关闭
 * 调用是否有界属于其合同，本函数不声称能给阻塞的系统IPC强行设墙钟期限。 */
static int quiescent(uint32_t* active) {
    uint64_t start = monotonic_ns();
    struct timespec pause = {0, 1000000};
    do {
        if (!__atomic_load_n(active, __ATOMIC_SEQ_CST)) return 1;
        nanosleep(&pause, NULL);
    } while (start && monotonic_ns() - start < UINT64_C(1000000000));
    return !__atomic_load_n(active, __ATOMIC_SEQ_CST);
}
static int manager_error(AmclMidiManager* m) {
    if (m->destroying || !m->client) return AMCL_MIDI_CLOSED;
    return __atomic_load_n(&m->pod->error, __ATOMIC_ACQUIRE);
}
int amcl_midi_manager_create(AmclMidiManager** output, const AmclMidiApi* api, const AmclMidiCallbackAbiV1* table) {
    if (!output || !api || !amcl_midi_callbacks_valid_v1(table)) return AMCL_MIDI_ABI;
    *output = NULL;
#define AMCL_MIDI_REQUIRE(field, symbol) if (!api->field) return AMCL_MIDI_ABI;
    AMCL_MIDI_API_MEMBERS(AMCL_MIDI_REQUIRE)
#undef AMCL_MIDI_REQUIRE
    AmclMidiManager* m = calloc(1, sizeof(*m));
    if (!m) return AMCL_MIDI_MEMORY;
    m->pod = calloc(1, sizeof(*m->pod));
    if (!m->pod) { free(m); return AMCL_MIDI_MEMORY; }
    if (pthread_mutex_init(&m->lock, NULL)) { free(m->pod); free(m); return AMCL_MIDI_MEMORY; }
    m->api = api; m->callbacks = table; m->nextHandle = 1; m->nextEndpoint = 1;
    amcl_midi_client_init(m->pod);
    OH_MIDICallbacks callbacks = { table->onDeviceChange, table->onError };
    int result = api->Create(&m->client, callbacks, m->pod);
    if (result || !m->client) {
        /* Create失败没有发布client；公开实现也销毁失败实例。同步回调必须先归零。 */
        __atomic_store_n(&m->pod->closing, 1u, __ATOMIC_RELEASE);
        if (quiescent(&m->pod->active)) { pthread_mutex_destroy(&m->lock); free(m->pod); free(m); }
        else *output = m; /* 未静止的异常路径让外层保留宿主/API引用。 */
        return result ? result : OH_MIDI_STATUS_SYSTEM_ERROR;
    }
    *output = m;
    return 0;
}

/* count只是预估；多留一个槽并在填满时扩容重试，避免热插拔计数竞态导致静默截断。
 * GetDeviceCount的公开实现曾吞内部错误，因此即使count=0也实际GetDeviceInfos。
 */
static int device_infos(AmclMidiManager* m, OH_MIDIDeviceInformation** output, size_t* count) {
    size_t hint = 0;
    int result = m->api->GetDeviceCount(m->client, &hint);
    if (result) return result;
    if (hint == SIZE_MAX) return AMCL_MIDI_MEMORY;
    size_t capacity = hint + 1;
    for (unsigned retry = 0; retry < 5; ++retry) {
        if (capacity > SIZE_MAX / sizeof(**output)) return AMCL_MIDI_MEMORY;
        OH_MIDIDeviceInformation* infos = calloc(capacity, sizeof(*infos));
        if (!infos) return AMCL_MIDI_MEMORY;
        size_t actual = 0;
        result = m->api->GetDeviceInfos(m->client, infos, capacity, &actual);
        if (result || actual > capacity) { free(infos); return result ? result : AMCL_MIDI_INVALID; }
        if (actual < capacity) { *output = infos; *count = actual; return 0; }
        free(infos);
        if (capacity > SIZE_MAX / 2) return AMCL_MIDI_MEMORY;
        capacity *= 2;
    }
    return AMCL_MIDI_CHANGED;
}
static int port_infos(AmclMidiManager* m, int64_t id, OH_MIDIPortInformation** output, size_t* count) {
    size_t hint = 0;
    int result = m->api->GetPortCount(m->client, id, &hint);
    if (result) return result;
    if (hint == SIZE_MAX) return AMCL_MIDI_MEMORY;
    size_t capacity = hint + 1;
    for (unsigned retry = 0; retry < 5; ++retry) {
        if (capacity > SIZE_MAX / sizeof(**output)) return AMCL_MIDI_MEMORY;
        OH_MIDIPortInformation* infos = calloc(capacity, sizeof(*infos));
        if (!infos) return AMCL_MIDI_MEMORY;
        size_t actual = 0;
        result = m->api->GetPortInfos(m->client, id, infos, capacity, &actual);
        if (result || actual > capacity) { free(infos); return result ? result : AMCL_MIDI_INVALID; }
        if (actual < capacity) { *output = infos; *count = actual; return 0; }
        free(infos);
        if (capacity > SIZE_MAX / 2) return AMCL_MIDI_MEMORY;
        capacity *= 2;
    }
    return AMCL_MIDI_CHANGED;
}
static void apply_notices(AmclMidiManager* m) {
    uint64_t observed = __atomic_load_n(&m->pod->epoch, __ATOMIC_ACQUIRE);
    int all = __atomic_exchange_n(&m->pod->invalidated, 0u, __ATOMIC_ACQ_REL);
    if (all) {
        for (size_t i = 0; i < m->count; ++i) m->endpoints[i].token = 0;
        /* 通知溢出意味着无法再证明某个在用handle未经历断连/重连。不能只撤销
         * 下一份快照而让旧输入永久等待；现役端口明确报告Changed，用户关闭重开
         * 后由新的真实快照恢复。这里只表达身份不确定，不伪造“物理已断开”。 */
        for (AmclMidiUse* u = m->handles; u; u = u->next) {
            __atomic_store_n(&u->error, AMCL_MIDI_CHANGED, __ATOMIC_RELEASE);
            if (u->input) amcl_midi_input_error(u->input, AMCL_MIDI_CHANGED);
        }
    }
    AmclMidiNotice notice;
    while (amcl_midi_notice_pop(m->pod, &notice)) {
        if (notice.action != OH_MIDI_DEVICE_CHANGE_ACTION_DISCONNECTED) continue;
        for (size_t i = 0; i < m->count; ++i)
            if (m->endpoints[i].device.midiDeviceId == notice.deviceId) m->endpoints[i].token = 0;
        for (AmclMidiUse* u = m->handles; u; u = u->next) if (u->device->id == notice.deviceId) {
            __atomic_store_n(&u->disconnected, 1u, __ATOMIC_RELEASE);
            if (u->input) amcl_midi_input_error(u->input, OH_MIDI_STATUS_INVALID_DEVICE_HANDLE);
        }
    }
    __atomic_store_n(&m->appliedEpoch, observed, __ATOMIC_RELEASE);
}
static int same_endpoint(const AmclMidiEndpoint* a, const AmclMidiEndpoint* b) {
    return a->device.midiDeviceId == b->device.midiDeviceId && a->port.portIndex == b->port.portIndex &&
        a->port.direction == b->port.direction && a->device.deviceType == b->device.deviceType &&
        a->device.nativeProtocol == b->device.nativeProtocol && a->device.vendorId == b->device.vendorId &&
        a->device.productId == b->device.productId &&
        !strncmp(a->device.deviceName, b->device.deviceName, sizeof(a->device.deviceName)) &&
        !strncmp(a->device.deviceAddress, b->device.deviceAddress, sizeof(a->device.deviceAddress)) &&
        !strncmp(a->port.name, b->port.name, sizeof(a->port.name));
}
static void free_use_locked(AmclMidiUse* u);
/* 服务死亡首先作为真实错误交给调用方。所有旧端口/在途JNI退出后，下一次显式
 * 枚举可按SDK要求销毁并重建client，不需要重启JVM。失败Destroy已消费的原指针
 * 绝不重用；其quiescence不确定时保持错误和所有权，不能为了恢复伪造安全释放。 */
static int recover_service_locked(AmclMidiManager* m) {
    int error = __atomic_load_n(&m->pod->error, __ATOMIC_ACQUIRE);
    if (error != OH_MIDI_STATUS_SERVICE_DIED && !m->recreate) return 0;
    if (!m->serviceReported) { m->serviceReported = 1; return OH_MIDI_STATUS_SERVICE_DIED; }
    if (m->handles) return OH_MIDI_STATUS_SERVICE_DIED;
    for (AmclMidiUse* u = m->retired; u; u = u->next) if (u->references) return OH_MIDI_STATUS_SERVICE_DIED;
    if (m->client) {
        __atomic_store_n(&m->pod->closing, 1u, __ATOMIC_RELEASE);
        m->destroyStatus = m->api->Destroy(m->client); m->client = NULL; m->recreate = 1;
    }
    if (m->destroyStatus) return m->destroyStatus;
    if (!quiescent(&m->pod->active)) return AMCL_MIDI_TIMEOUT;
    for (AmclMidiUse* u = m->retired; u; u = u->next)
        if (u->input && !quiescent(&u->input->active)) return AMCL_MIDI_TIMEOUT;
    while (m->retired) { m->retired->safe = 1; free_use_locked(m->retired); }
    free(m->endpoints); m->endpoints = NULL; m->count = 0;
    amcl_midi_client_init(m->pod); m->appliedEpoch = 0;
    OH_MIDICallbacks callbacks = {m->callbacks->onDeviceChange, m->callbacks->onError};
    int result = m->api->Create(&m->client, callbacks, m->pod);
    if (result || !m->client) { m->client = NULL; return result ? result : OH_MIDI_STATUS_SYSTEM_ERROR; }
    m->serviceReported = m->recreate = 0;
    return 0;
}
static int refresh_locked(AmclMidiManager* m) {
    int result = recover_service_locked(m);
    if (!result) result = manager_error(m);
    if (result) return result;
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
        apply_notices(m);
        uint64_t epoch = __atomic_load_n(&m->pod->epoch, __ATOMIC_ACQUIRE);
        OH_MIDIDeviceInformation* devices = NULL; size_t count = 0;
        AmclMidiEndpoint* endpoints = NULL; size_t size = 0;
        result = device_infos(m, &devices, &count);
        for (size_t i = 0; !result && i < count; ++i) {
            OH_MIDIDeviceInformation* device = &devices[i];
            if ((device->deviceType != OH_MIDI_DEVICE_TYPE_USB && device->deviceType != OH_MIDI_DEVICE_TYPE_BLE) ||
                (device->nativeProtocol != OH_MIDI_PROTOCOL_1_0 && device->nativeProtocol != OH_MIDI_PROTOCOL_2_0) ||
                !memchr(device->deviceName, 0, sizeof(device->deviceName)) ||
                !memchr(device->deviceAddress, 0, sizeof(device->deviceAddress))) { result = AMCL_MIDI_INVALID; break; }
            OH_MIDIPortInformation* ports = NULL; size_t portCount = 0;
            result = port_infos(m, device->midiDeviceId, &ports, &portCount);
            if (!result && portCount > SIZE_MAX / sizeof(*endpoints) - size) result = AMCL_MIDI_MEMORY;
            if (!result && portCount) {
                AmclMidiEndpoint* grown = realloc(endpoints, (size + portCount) * sizeof(*endpoints));
                if (!grown) result = AMCL_MIDI_MEMORY; else endpoints = grown;
            }
            for (size_t j = 0; !result && j < portCount; ++j) {
                if (ports[j].deviceId != device->midiDeviceId ||
                    (ports[j].direction != OH_MIDI_PORT_DIRECTION_INPUT && ports[j].direction != OH_MIDI_PORT_DIRECTION_OUTPUT) ||
                    !memchr(ports[j].name, 0, sizeof(ports[j].name))) { result = AMCL_MIDI_INVALID; break; }
                AmclMidiEndpoint endpoint = {0}; endpoint.device = *device; endpoint.port = ports[j];
                /* 同一个设备/端口/方向重复项不是两个真实端点，拒绝有歧义的SDK快照。 */
                for (size_t k = 0; k < size; ++k)
                    if (endpoints[k].device.midiDeviceId == device->midiDeviceId && endpoints[k].port.portIndex == ports[j].portIndex &&
                        endpoints[k].port.direction == ports[j].direction) { result = AMCL_MIDI_INVALID; break; }
                if (!result) endpoints[size++] = endpoint;
            }
            free(ports);
        }
        free(devices);
        if (result) { free(endpoints); return result; }
        if (epoch != __atomic_load_n(&m->pod->epoch, __ATOMIC_ACQUIRE)) { free(endpoints); continue; }
        for (size_t i = 0; i < size; ++i) {
            for (size_t j = 0; j < m->count; ++j)
                if (m->endpoints[j].token && same_endpoint(&endpoints[i], &m->endpoints[j])) { endpoints[i].token = m->endpoints[j].token; break; }
            if (!endpoints[i].token) {
                if (m->nextEndpoint <= 0 || m->nextEndpoint == INT_MAX) { free(endpoints); return AMCL_MIDI_MEMORY; }
                endpoints[i].token = m->nextEndpoint++;
            }
        }
        free(m->endpoints); m->endpoints = endpoints; m->count = size;
        return 0;
    }
    return AMCL_MIDI_CHANGED;
}
int amcl_midi_snapshot(AmclMidiManager* m, int direction, AmclMidiEndpoint** output, size_t* count) {
    if (!m || !output || !count || (direction != 0 && direction != 1)) return AMCL_MIDI_INVALID;
    *output = NULL; *count = 0; pthread_mutex_lock(&m->lock);
    int result = refresh_locked(m); size_t matches = 0;
    if (!result) {
        for (size_t i = 0; i < m->count; ++i) if ((int)m->endpoints[i].port.direction == direction) ++matches;
        if (matches) {
            *output = malloc(matches * sizeof(**output));
            if (!*output) result = AMCL_MIDI_MEMORY;
            else for (size_t i = 0; i < m->count; ++i)
                if ((int)m->endpoints[i].port.direction == direction) (*output)[(*count)++] = m->endpoints[i];
        }
    }
    pthread_mutex_unlock(&m->lock); return result;
}

/* 同一client同一device只OpenDevice一次，真实的多输入/多输出端口共享它。SDK的
 * portIndex直接来自快照，不假定连续，也不把input0/output1或BLE示例当设备事实。 */
int amcl_midi_open(AmclMidiManager* m, int token, int direction, uint64_t* handle) {
    if (!m || !handle || (direction != 0 && direction != 1)) return AMCL_MIDI_INVALID;
    *handle = 0; pthread_mutex_lock(&m->lock);
    int result = refresh_locked(m); const AmclMidiEndpoint* endpoint = NULL;
    if (!result) for (size_t i = 0; i < m->count; ++i)
        if (m->endpoints[i].token == token && (int)m->endpoints[i].port.direction == direction) { endpoint = &m->endpoints[i]; break; }
    if (!result && !endpoint) result = AMCL_MIDI_STALE;
    AmclMidiDevice* device = NULL; AmclMidiUse* use = NULL; int newDevice = 0;
    if (!result) {
        for (AmclMidiUse* u = m->handles; u; u = u->next)
            if (u->device->id == endpoint->device.midiDeviceId && u->port == endpoint->port.portIndex && u->direction == direction)
                result = OH_MIDI_STATUS_PORT_ALREADY_OPEN;
        for (device = m->devices; device && device->id != endpoint->device.midiDeviceId; device = device->next) {}
    }
    if (!result && !device) {
        device = calloc(1, sizeof(*device));
        if (!device) result = AMCL_MIDI_MEMORY;
        else {
            newDevice = 1; device->id = endpoint->device.midiDeviceId;
            result = m->api->OpenDevice(m->client, device->id, &device->native);
            if (!result && !device->native) result = OH_MIDI_STATUS_SYSTEM_ERROR;
        }
    }
    if (!result) {
        use = calloc(1, sizeof(*use));
        if (!use) result = AMCL_MIDI_MEMORY;
        else if (pthread_mutex_init(&use->io, NULL)) { free(use); use = NULL; result = AMCL_MIDI_MEMORY; }
    }
    if (!result) {
        use->manager = m; use->device = device; use->direction = direction; use->port = endpoint->port.portIndex;
        use->epoch = monotonic_ns(); use->references = 1; use->safe = 1; use->stopped = direction == 0;
        if (!use->epoch || m->nextHandle == UINT64_MAX) result = AMCL_MIDI_INVALID;
        else if (direction == 0) {
            use->input = calloc(1, sizeof(*use->input));
            if (!use->input) result = AMCL_MIDI_MEMORY;
            else if (amcl_midi_input_init(use->input)) { free(use->input); use->input = NULL; result = AMCL_MIDI_MEMORY; }
        } else {
            OH_MIDIPortDescriptor descriptor = { use->port, OH_MIDI_PROTOCOL_1_0 };
            result = m->api->OpenOutputPort(device->native, descriptor);
            if (!result) use->portOpen = 1;
        }
    }
    if (!result) {
        if (newDevice) { device->next = m->devices; m->devices = device; }
        ++device->references; ++device->openPorts;
        use->token = m->nextHandle++; use->next = m->handles; m->handles = use; *handle = use->token;
    } else {
        if (use) { if (use->input) { sem_destroy(&use->input->wake); free(use->input); } pthread_mutex_destroy(&use->io); free(use); }
        if (newDevice && device) { if (device->native) m->api->CloseDevice(m->client, device->native); free(device); }
    }
    pthread_mutex_unlock(&m->lock); return result;
}
AmclMidiUse* amcl_midi_acquire(AmclMidiManager* m, uint64_t token, int direction) {
    if (!m || !token) return NULL;
    pthread_mutex_lock(&m->lock); AmclMidiUse* found = NULL;
    for (AmclMidiUse* u = m->handles; u; u = u->next)
        if (u->token == token && u->direction == direction && !u->closed) { ++u->references; found = u; break; }
    pthread_mutex_unlock(&m->lock); return found;
}
static void free_use_locked(AmclMidiUse* u) {
    AmclMidiManager* m = u->manager;
    AmclMidiUse** link = &m->retired;
    while (*link && *link != u) link = &(*link)->next;
    if (*link == u) *link = u->next;
    if (u->input) { sem_destroy(&u->input->wake); free(u->input); }
    pthread_mutex_destroy(&u->io);
    if (!--u->device->references && !u->device->openPorts) free(u->device);
    free(u);
}
void amcl_midi_release(AmclMidiUse* u) {
    if (!u) return;
    AmclMidiManager* m = u->manager; pthread_mutex_lock(&m->lock);
    if (--u->references == 0 && u->closed && u->safe) free_use_locked(u);
    pthread_mutex_unlock(&m->lock);
}
static int use_error(AmclMidiUse* u) {
    if (__atomic_load_n(&u->closed, __ATOMIC_ACQUIRE)) return AMCL_MIDI_CLOSED;
    /* 热插拔无需等下一次Java枚举；既有输入线程的定期检查同样消费通知并结束
     * 已断开设备。回调只入队，实际handle状态修改仍在普通线程的manager锁下。 */
    if (__atomic_load_n(&u->manager->pod->epoch, __ATOMIC_ACQUIRE) !=
        __atomic_load_n(&u->manager->appliedEpoch, __ATOMIC_ACQUIRE)) {
        pthread_mutex_lock(&u->manager->lock); apply_notices(u->manager); pthread_mutex_unlock(&u->manager->lock);
    }
    int ownership = __atomic_load_n(&u->error, __ATOMIC_ACQUIRE);
    if (ownership) return ownership;
    if (__atomic_load_n(&u->disconnected, __ATOMIC_ACQUIRE)) return OH_MIDI_STATUS_INVALID_DEVICE_HANDLE;
    int result = __atomic_load_n(&u->manager->pod->error, __ATOMIC_ACQUIRE);
    if (!result && u->input) result = __atomic_load_n(&u->input->error, __ATOMIC_ACQUIRE);
    return result;
}
int amcl_midi_start(AmclMidiUse* u) {
    if (!u || u->direction != 0) return AMCL_MIDI_INVALID;
    pthread_mutex_lock(&u->io); int result = use_error(u);
    if (!result && !u->portOpen) {
        /* 同一handle的停止/重启仅在旧读取者离开后重置消费状态；普通Java重开会
         * 获得全新的handle，不能以join(1000)结束为旧Receiver已经返回的证明。 */
        if (u->everStarted && __atomic_load_n(&u->reading, __ATOMIC_ACQUIRE)) result = AMCL_MIDI_BUSY;
        else {
            if (u->everStarted) {
                while (amcl_midi_packet_pop(u->input, &u->pending)) {}
                u->hasPending = 0; memset(u->receivingSysex, 0, sizeof(u->receivingSysex));
            }
            __atomic_store_n(&u->input->closing, 0u, __ATOMIC_RELEASE);
            __atomic_store_n(&u->stopped, 0u, __ATOMIC_RELEASE);
            OH_MIDIPortDescriptor descriptor = { u->port, OH_MIDI_PROTOCOL_1_0 };
            result = u->manager->api->OpenInputPort(u->device->native, descriptor, u->manager->callbacks->onReceived, u->input);
            if (!result) u->portOpen = u->everStarted = 1;
            else { __atomic_store_n(&u->stopped, 1u, __ATOMIC_RELEASE); __atomic_store_n(&u->input->closing, 1u, __ATOMIC_RELEASE); }
        }
    }
    pthread_mutex_unlock(&u->io); return result;
}
int amcl_midi_stop(AmclMidiUse* u) {
    if (!u || u->direction != 0) return AMCL_MIDI_INVALID;
    __atomic_store_n(&u->stopped, 1u, __ATOMIC_RELEASE);
    __atomic_store_n(&u->input->closing, 1u, __ATOMIC_RELEASE); amcl_midi_input_wake(u->input);
    pthread_mutex_lock(&u->io); int result = 0;
    if (u->portOpen) {
        result = u->manager->api->CloseInputPort(u->device->native, u->port);
        u->portOpen = 0; /* 公开实现可在错误返回前消费端口，禁止重复使用旧port对象。 */
        if (result || !quiescent(&u->input->active)) u->safe = 0;
    }
    pthread_mutex_unlock(&u->io); return result ? result : u->safe ? 0 : AMCL_MIDI_TIMEOUT;
}
int amcl_midi_close(AmclMidiManager* m, uint64_t token) {
    if (!m || !token) return AMCL_MIDI_CLOSED;
    pthread_mutex_lock(&m->lock); AmclMidiUse** link = &m->handles;
    while (*link && (*link)->token != token) link = &(*link)->next;
    AmclMidiUse* u = *link;
    if (!u) { pthread_mutex_unlock(&m->lock); return AMCL_MIDI_CLOSED; }
    *link = u->next; u->next = m->retired; m->retired = u;
    __atomic_store_n(&u->closed, 1u, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&m->lock);
    int result = 0;
    if (u->input) result = amcl_midi_stop(u);
    else {
        pthread_mutex_lock(&u->io);
        if (u->portOpen) { result = m->api->CloseOutputPort(u->device->native, u->port); u->portOpen = 0; }
        pthread_mutex_unlock(&u->io);
    }
    pthread_mutex_lock(&m->lock);
    AmclMidiDevice* device = u->device;
    if (!--device->openPorts) {
        AmclMidiDevice** dlink = &m->devices;
        while (*dlink && *dlink != device) dlink = &(*dlink)->next;
        if (*dlink) *dlink = device->next;
        int closed = m->api->CloseDevice(m->client, device->native);
        device->native = NULL; /* 无论返回值，SDK可已消费该raw handle，不能重试它。 */
        if (!result) result = closed;
        if (!closed) for (AmclMidiUse* old = m->retired; old; old = old->next)
            if (old->device == device && (!old->input || quiescent(&old->input->active))) old->safe = 1;
    }
    if (--u->references == 0 && u->safe) free_use_locked(u);
    pthread_mutex_unlock(&m->lock); return result;
}
int64_t amcl_midi_position(AmclMidiUse* u) {
    uint64_t now = monotonic_ns();
    return !u || use_error(u) || now < u->epoch ? -1 : (int64_t)((now - u->epoch) / 1000);
}

/* 批量发送保留每个事件的原始单调时钟时间，按SDK written精确前进。一次batch
 * 最多64包，满缓冲只重试未接受部分；关闭和1秒单调期限可打断等待，绝不重新
 * 提交已接受前缀，也不把WOULD_BLOCK当成功。long消息本身无1024字节截断上限。 */
static int send_bytes(AmclMidiUse* u, const uint8_t* bytes, size_t size, int64_t micros) {
    if (!u || u->direction != 1 || (size && !bytes)) return AMCL_MIDI_INVALID;
    uint64_t timestamp;
    if (amcl_midi_time_to_ns(u->epoch, micros, &timestamp)) return AMCL_MIDI_INVALID;
    pthread_mutex_lock(&u->io);
    int result = use_error(u); size_t offset = 0;
    AmclMidiStream validation = u->stream; AmclMidiOutput ignored;
    unsigned group = u->port & 15u; /* 与SDK SendSysEx自身的group选择完全一致。 */
    while (!result) {
        int step = amcl_midi_stream_next(&validation, group, bytes, size, &offset, timestamp, &ignored);
        if (step < 0) result = AMCL_MIDI_INVALID;
        if (step <= 0) break;
    }
    offset = 0;
    while (!result) {
        AmclMidiStream states[64], candidate = u->stream;
        size_t offsets[64], cursor = offset;
        AmclMidiOutput packets[64]; OH_MIDIEvent events[64]; unsigned count = 0; int complete = 0;
        while (count < 64) {
            int step = amcl_midi_stream_next(&candidate, group, bytes, size, &cursor, timestamp, &packets[count]);
            if (step < 0) { result = AMCL_MIDI_INVALID; break; }
            if (!step) { complete = 1; break; }
            states[count] = candidate; offsets[count] = cursor;
            events[count].timestamp = packets[count].timestamp;
            events[count].length = packets[count].count; events[count].data = packets[count].words; ++count;
        }
        unsigned sent = 0; uint64_t started = monotonic_ns();
        while (!result && sent < count) {
            result = use_error(u); if (result) break;
            uint32_t written = 0;
            int status = u->manager->api->Send(u->device->native, u->port, events + sent, count - sent, &written);
            if (written > count - sent) { result = AMCL_MIDI_INVALID; break; }
            if (written) { sent += written; u->stream = states[sent - 1]; offset = offsets[sent - 1]; }
            if (status != OH_MIDI_STATUS_OK && status != OH_MIDI_STATUS_WOULD_BLOCK) { result = status; break; }
            if (sent == count) break;
            if (status == OH_MIDI_STATUS_OK && !written) { result = AMCL_MIDI_INVALID; break; }
            if (!started || monotonic_ns() - started >= UINT64_C(1000000000)) { result = AMCL_MIDI_TIMEOUT; break; }
            struct timespec pause = {0, 10000000}; nanosleep(&pause, NULL);
        }
        if (result) break;
        if (complete) { u->stream = candidate; break; }
    }
    pthread_mutex_unlock(&u->io); return result;
}
int amcl_midi_send_short(AmclMidiUse* u, uint32_t packed, int64_t micros) {
    unsigned size = amcl_midi_short_size((uint8_t)packed); uint32_t check;
    if (!size || amcl_midi_short_to_ump(packed, 0, &check) < 0) return AMCL_MIDI_INVALID;
    uint8_t bytes[3] = {(uint8_t)packed, (uint8_t)(packed >> 8), (uint8_t)(packed >> 16)};
    return send_bytes(u, bytes, size, micros);
}
int amcl_midi_send_long(AmclMidiUse* u, const uint8_t* bytes, size_t size, int64_t micros) {
    if (!bytes || !size || (bytes[0] != 0xf0 && bytes[0] != 0xf7)) return AMCL_MIDI_INVALID;
    if (bytes[0] == 0xf7 && size > 1) { ++bytes; --size; }
    return send_bytes(u, bytes, size, micros);
}
int amcl_midi_read_begin(AmclMidiUse* u) {
    if (!u || u->direction != 0) return AMCL_MIDI_INVALID;
    uint32_t expected = 0;
    return __atomic_compare_exchange_n(&u->reading, &expected, 1u, 0, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED) ? 0 : AMCL_MIDI_BUSY;
}
void amcl_midi_read_end(AmclMidiUse* u) { if (u) __atomic_store_n(&u->reading, 0u, __ATOMIC_RELEASE); }
int amcl_midi_next(AmclMidiUse* u, AmclMidiMessage* message) {
    if (!u || !message || u->direction != 0 || !u->reading) return AMCL_MIDI_INVALID;
    memset(message, 0, sizeof(*message)); unsigned group = 0;
    while (1) {
        if (__atomic_load_n(&u->stopped, __ATOMIC_ACQUIRE) || __atomic_load_n(&u->closed, __ATOMIC_ACQUIRE)) return message->length ? 1 : 0;
        int error = use_error(u); if (error) return error;
        AmclMidiPacket packet;
        if (u->hasPending) { packet = u->pending; u->hasPending = 0; }
        else if (!amcl_midi_packet_pop(u->input, &packet)) {
            if (message->length) return 1;
            __atomic_store_n(&u->input->wakePending, 0u, __ATOMIC_RELEASE);
            if (amcl_midi_packet_pop(u->input, &packet)) { u->pending = packet; u->hasPending = 1; continue; }
            if (__atomic_load_n(&u->stopped, __ATOMIC_ACQUIRE) || __atomic_load_n(&u->closed, __ATOMIC_ACQUIRE)) return 0;
            struct timespec deadline;
            if (clock_gettime(CLOCK_REALTIME, &deadline)) return OH_MIDI_STATUS_SYSTEM_ERROR;
            deadline.tv_nsec += 100000000;
            if (deadline.tv_nsec >= 1000000000) { ++deadline.tv_sec; deadline.tv_nsec -= 1000000000; }
            if (sem_timedwait(&u->input->wake, &deadline) && errno != ETIMEDOUT && errno != EINTR) return OH_MIDI_STATUS_SYSTEM_ERROR;
            continue; /* 定期检查client服务死亡；关闭由sem_post立即唤醒。 */
        }
        AmclMidiDecoded decoded;
        int kind = amcl_midi_from_ump(packet.words, packet.wordCount, &decoded);
        if (kind < 0) return AMCL_MIDI_BAD_PACKET;
        if (kind == AMCL_MIDI_UMP_UTILITY) continue;
        int64_t micros = amcl_midi_time_from_ns(u->epoch, packet.timestamp);
        if (message->length && (kind != AMCL_MIDI_UMP_SYSEX7 || decoded.group != group || micros != message->microseconds ||
            message->length + decoded.payloadSize + 1 > sizeof(message->data))) {
            u->pending = packet; u->hasPending = 1; return 1;
        }
        if (kind == AMCL_MIDI_UMP_SHORT) { message->packed = decoded.packed; message->microseconds = micros; return 1; }
        unsigned form = decoded.sysexForm; group = decoded.group;
        if ((form < 2 && u->receivingSysex[group]) || (form >= 2 && !u->receivingSysex[group])) return AMCL_MIDI_BAD_PACKET;
        if (!message->length) {
            message->isLong = 1; message->microseconds = micros;
            message->data[message->length++] = form < 2 ? 0xf0 : 0xf7;
        }
        memcpy(message->data + message->length, decoded.payload, decoded.payloadSize); message->length += decoded.payloadSize;
        u->receivingSysex[group] = form == 1 || form == 2;
        if (!u->receivingSysex[group]) { message->data[message->length++] = 0xf7; return 1; }
    }
}

int amcl_midi_manager_destroy(AmclMidiManager* m) {
    if (!m) return 0;
    /* 调用方停止发布manager后进入此处。关闭动作仍可让已持有的JNI循环自然离开。 */
    for (;;) {
        pthread_mutex_lock(&m->lock); uint64_t token = m->handles ? m->handles->token : 0; pthread_mutex_unlock(&m->lock);
        if (!token) break;
        amcl_midi_close(m, token);
    }
    pthread_mutex_lock(&m->lock);
    for (AmclMidiUse* u = m->retired; u; u = u->next)
        if (u->references) { pthread_mutex_unlock(&m->lock); return AMCL_MIDI_BUSY; }
    m->destroying = 1; __atomic_store_n(&m->pod->closing, 1u, __ATOMIC_RELEASE);
    int result = m->destroyStatus;
    if (m->client) { result = m->api->Destroy(m->client); m->client = NULL; m->destroyStatus = result; }
    if (!result && !quiescent(&m->pod->active)) result = AMCL_MIDI_TIMEOUT;
    if (!result) {
        for (AmclMidiUse* u = m->retired; u; u = u->next)
            if (u->input && !quiescent(&u->input->active)) { result = AMCL_MIDI_TIMEOUT; break; }
    }
    if (result) { pthread_mutex_unlock(&m->lock); return result; }
    while (m->retired) { m->retired->safe = 1; free_use_locked(m->retired); }
    free(m->endpoints); free(m->pod);
    pthread_mutex_unlock(&m->lock); pthread_mutex_destroy(&m->lock); free(m); return 0;
}
