/*
 * 普通应用真实 OHAudio 设备 → JavaSound Port 快照。
 * 所有 SDK 数组在本次调用释放；内存仅保留必要的设备字符串副本和已打开 handle。
 * 无系统回调指针、后台线程或本地音量状态。请求失败与空设备列表是不同结果。
 */
#include "ports_ohos.h"
#include <ohaudio/native_audio_routing_manager.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 这些上限限制异常供应者数据的资源使用；超限明确失败，不截断名字或悄悄丢设备。 */
#define AMCL_PORTS_MAX_DEVICES 4096u
#define AMCL_PORTS_MAX_TEXT 65536u
#ifndef AMCL_PORTS_ALLOC
#define AMCL_PORTS_ALLOC calloc
#endif

__attribute__((used, section(".amcl.ports")))
static const char amcl_ports_marker[] = "AMCL_PORTS_OHOS_API20_DEVICES_V1";

typedef struct AmclPortHandle {
    uint64_t id;
    AmclPortInfo info;
    struct AmclPortHandle *next;
} AmclPortHandle;

static pthread_mutex_t ports_lock = PTHREAD_MUTEX_INITIALIZER;
static AmclPortInfo *current;
static size_t current_count;
static uint64_t current_generation;
static uint64_t next_token = 1, next_handle = 1;
static AmclPortHandle *handles;
static size_t handle_count;

/* SDK 名称是借用指针，ReleaseDevices 后失效。空名仍用实际 id/type/role 描述，
 * 不凭空补“speaker”等硬件；保留所有非空原文与非 BMP UTF-8。 */
static int copy_text(const char *value, char **copy)
{
    size_t size = 0;
    *copy = NULL;
    if (!value) return AMCL_PORTS_INVALID;
    while (size < AMCL_PORTS_MAX_TEXT && value[size]) ++size;
    if (size == AMCL_PORTS_MAX_TEXT) return AMCL_PORTS_INVALID;
    *copy = (char *)AMCL_PORTS_ALLOC(size + 1, 1);
    if (!*copy) return AMCL_PORTS_NO_MEMORY;
    memcpy(*copy, value, size + 1);
    return AMCL_PORTS_OK;
}

void amcl_ports_info_free(AmclPortInfo *info)
{
    if (!info) return;
    free(info->name); free(info->address); memset(info, 0, sizeof(*info));
}

static void free_list(AmclPortInfo *list, size_t count)
{
    size_t i;
    for (i = 0; i < count; ++i) amcl_ports_info_free(&list[i]);
    free(list);
}

static int clone_info(const AmclPortInfo *source, AmclPortInfo *target)
{
    int result;
    memset(target, 0, sizeof(*target));
    target->token = source->token; target->device_id = source->device_id;
    target->role = source->role; target->type = source->type;
    result = copy_text(source->name, &target->name);
    if (result == AMCL_PORTS_OK) result = copy_text(source->address, &target->address);
    if (result != AMCL_PORTS_OK) amcl_ports_info_free(target);
    return result;
}

/* id+role 决定排序，名称/类型/地址决定身份是否保持；不把同数目的换设备当作缓存命中。 */
static int compare_id(const void *left, const void *right)
{
    const AmclPortInfo *a = left, *b = right;
    if (a->device_id != b->device_id) return a->device_id < b->device_id ? -1 : 1;
    return a->role < b->role ? -1 : a->role > b->role;
}

static int same_device(const AmclPortInfo *a, const AmclPortInfo *b)
{
    return a->device_id == b->device_id && a->role == b->role && a->type == b->type &&
        strcmp(a->name, b->name) == 0 && strcmp(a->address, b->address) == 0;
}

/* mutex 内先构造完整候选，所有 SDK 返回值及描述符都核实后才发布。OOM、坏数组、
 * 重复身份或 ReleaseDevices 失败均保留原缓存并返回错误，绝不发布半份列表。 */
static int refresh_locked(int *native_error)
{
    OH_AudioRoutingManager *manager = NULL;
    OH_AudioDeviceDescriptorArray *array = NULL;
    AmclPortInfo *candidate = NULL;
    size_t count = 0, i, j;
    int result = AMCL_PORTS_OK, changed;
    OH_AudioCommon_Result status;
    *native_error = 0;
    status = OH_AudioManager_GetAudioRoutingManager(&manager);
    if (status != AUDIOCOMMON_RESULT_SUCCESS || !manager) {
        *native_error = (int)status; return AMCL_PORTS_PLATFORM_ERROR;
    }
    status = OH_AudioRoutingManager_GetDevices(manager, AUDIO_DEVICE_FLAG_ALL, &array);
    if (status != AUDIOCOMMON_RESULT_SUCCESS) { *native_error = (int)status; result = AMCL_PORTS_PLATFORM_ERROR; goto done; }
    if (!array || array->size > AMCL_PORTS_MAX_DEVICES || (array->size && !array->descriptors)) {
        result = AMCL_PORTS_INVALID; goto done;
    }
    if (array->size) {
        candidate = AMCL_PORTS_ALLOC(array->size, sizeof(*candidate));
        if (!candidate) { result = AMCL_PORTS_NO_MEMORY; goto done; }
    }
    for (i = 0; i < array->size; ++i) {
        OH_AudioDeviceDescriptor *descriptor = array->descriptors[i];
        OH_AudioDevice_Role role;
        OH_AudioDevice_Type type;
        uint32_t id;
        char *name = NULL, *address = NULL;
        AmclPortInfo *entry;
        char unnamed[96];
        if (!descriptor) { result = AMCL_PORTS_INVALID; goto done; }
#define GET_DEVICE(call) do { status = (call); if (status != AUDIOCOMMON_RESULT_SUCCESS) { \
    *native_error = (int)status; result = AMCL_PORTS_PLATFORM_ERROR; goto done; } } while (0)
        GET_DEVICE(OH_AudioDeviceDescriptor_GetDeviceRole(descriptor, &role));
        GET_DEVICE(OH_AudioDeviceDescriptor_GetDeviceType(descriptor, &type));
        GET_DEVICE(OH_AudioDeviceDescriptor_GetDeviceId(descriptor, &id));
        /* DEFAULT/INVALID 是选择占位符，不是具体硬件端口。其他真实类型保留为未知typed Port。 */
        if (type == AUDIO_DEVICE_TYPE_INVALID || type == AUDIO_DEVICE_TYPE_DEFAULT) continue;
        if (role != AUDIO_DEVICE_ROLE_INPUT && role != AUDIO_DEVICE_ROLE_OUTPUT) { result = AMCL_PORTS_INVALID; goto done; }
        GET_DEVICE(OH_AudioDeviceDescriptor_GetDeviceName(descriptor, &name));
        GET_DEVICE(OH_AudioDeviceDescriptor_GetDeviceAddress(descriptor, &address));
#undef GET_DEVICE
        if (!name || !address) { result = AMCL_PORTS_INVALID; goto done; }
        if (!name[0]) {
            snprintf(unnamed, sizeof(unnamed), "OHAudio device %u (type %d, role %d)", id, (int)type, (int)role);
            name = unnamed;
        }
        entry = &candidate[count++]; entry->device_id = id; entry->type = (int)type; entry->role = (int)role;
        result = copy_text(name, &entry->name);
        if (result == AMCL_PORTS_OK) result = copy_text(address, &entry->address);
        if (result != AMCL_PORTS_OK) goto done;
    }
done:
    if (array) {
        status = OH_AudioRoutingManager_ReleaseDevices(manager, array);
        if (status != AUDIOCOMMON_RESULT_SUCCESS && result == AMCL_PORTS_OK) {
            *native_error = (int)status; result = AMCL_PORTS_PLATFORM_ERROR;
        }
    }
    if (result != AMCL_PORTS_OK) { free_list(candidate, count); return result; }
    if (count > 1) qsort(candidate, count, sizeof(*candidate), compare_id);
    for (i = 1; i < count; ++i) if (compare_id(&candidate[i - 1], &candidate[i]) == 0) {
        free_list(candidate, count); return AMCL_PORTS_INVALID;
    }
    changed = current_generation == 0 || count != current_count;
    /* 两份列表按真实id/role排序，用线性合并保持token，避免设备数增长时二次扫描。 */
    j = 0;
    for (i = 0; i < count; ++i) {
        while (j < current_count && compare_id(&current[j], &candidate[i]) < 0) ++j;
        if (j < current_count && same_device(&candidate[i], &current[j])) candidate[i].token = current[j].token;
        if (!candidate[i].token) {
            /* Java使用有符号jlong；到正数边界明确失败，不能转换为负值或复用旧token。 */
            if (next_token >= INT64_MAX) { free_list(candidate, count); return AMCL_PORTS_INVALID; }
            candidate[i].token = next_token++; changed = 1;
        }
    }
    if (changed && current_generation >= INT64_MAX) { free_list(candidate, count); return AMCL_PORTS_INVALID; }
    if (changed) ++current_generation;
    free_list(current, current_count); current = candidate; current_count = count;
    return AMCL_PORTS_OK;
}

int amcl_ports_refresh(size_t *count, uint64_t *generation, int *native_error)
{
    int result;
    if (!count || !generation || !native_error) return AMCL_PORTS_INVALID;
    pthread_mutex_lock(&ports_lock); result = refresh_locked(native_error);
    if (result == AMCL_PORTS_OK) { *count = current_count; *generation = current_generation; }
    pthread_mutex_unlock(&ports_lock); return result;
}

uint64_t amcl_ports_generation(void)
{
    uint64_t generation;
    pthread_mutex_lock(&ports_lock); generation = current_generation; pthread_mutex_unlock(&ports_lock);
    return generation;
}

int amcl_ports_info_at(size_t index, uint64_t generation, AmclPortInfo *info)
{
    int result;
    if (!info) return AMCL_PORTS_INVALID;
    memset(info, 0, sizeof(*info)); pthread_mutex_lock(&ports_lock);
    result = generation != current_generation || index >= current_count ? AMCL_PORTS_STALE : clone_info(&current[index], info);
    pthread_mutex_unlock(&ports_lock); return result;
}

int amcl_ports_open(uint64_t token, uint64_t *handle, int *native_error)
{
    int result;
    size_t i;
    AmclPortHandle *entry = NULL;
    if (!token || !handle || !native_error) return AMCL_PORTS_INVALID;
    *handle = 0; pthread_mutex_lock(&ports_lock); result = refresh_locked(native_error);
    if (result != AMCL_PORTS_OK) goto done;
    for (i = 0; i < current_count && current[i].token != token; ++i) { }
    if (i == current_count) { result = AMCL_PORTS_STALE; goto done; }
    if (next_handle >= INT64_MAX || handle_count >= AMCL_PORTS_MAX_DEVICES) { result = AMCL_PORTS_INVALID; goto done; }
    entry = AMCL_PORTS_ALLOC(1, sizeof(*entry));
    if (!entry) { result = AMCL_PORTS_NO_MEMORY; goto done; }
    result = clone_info(&current[i], &entry->info);
    if (result != AMCL_PORTS_OK) { free(entry); goto done; }
    entry->id = next_handle++; entry->next = handles; handles = entry; ++handle_count; *handle = entry->id;
done:
    pthread_mutex_unlock(&ports_lock); return result;
}

int amcl_ports_close(uint64_t handle)
{
    AmclPortHandle **link, *entry; int found;
    pthread_mutex_lock(&ports_lock); link = &handles;
    while (*link && (*link)->id != handle) link = &(*link)->next;
    entry = *link; found = entry != NULL;
    if (entry) { *link = entry->next; --handle_count; amcl_ports_info_free(&entry->info); free(entry); }
    pthread_mutex_unlock(&ports_lock);
    return found ? AMCL_PORTS_OK : AMCL_PORTS_STALE;
}

int amcl_ports_handle_info(uint64_t handle, AmclPortInfo *info)
{
    AmclPortHandle *entry; int result;
    if (!info) return AMCL_PORTS_INVALID;
    memset(info, 0, sizeof(*info)); pthread_mutex_lock(&ports_lock);
    for (entry = handles; entry && entry->id != handle; entry = entry->next) { }
    result = entry ? clone_info(&entry->info, info) : AMCL_PORTS_STALE;
    pthread_mutex_unlock(&ports_lock); return result;
}

int amcl_ports_check_present(uint64_t handle, int *native_error)
{
    AmclPortHandle *entry; size_t i; int result;
    if (!native_error) return AMCL_PORTS_INVALID;
    pthread_mutex_lock(&ports_lock); result = refresh_locked(native_error);
    if (result != AMCL_PORTS_OK) goto done;
    for (entry = handles; entry && entry->id != handle; entry = entry->next) { }
    if (!entry) { result = AMCL_PORTS_STALE; goto done; }
    for (i = 0; i < current_count && current[i].token != entry->info.token; ++i) { }
    if (i == current_count) result = AMCL_PORTS_STALE;
done:
    pthread_mutex_unlock(&ports_lock); return result;
}

/* 真正模块卸载释放有界缓存和所有剩余句柄；正常调用由Java close同步保护。
 * 不注册应用生命周期回调，不延长系统descriptor寿命。 */
__attribute__((destructor)) static void release_ports_cache(void)
{
    AmclPortHandle *entry;
    pthread_mutex_lock(&ports_lock);
    while ((entry = handles) != NULL) { handles = entry->next; amcl_ports_info_free(&entry->info); free(entry); }
    free_list(current, current_count); current = NULL; current_count = 0; handle_count = 0; current_generation = 0;
    pthread_mutex_unlock(&ports_lock);
}

#ifdef AMCL_PORTS_TEST
void amcl_ports_test_reset(void) { release_ports_cache(); }
size_t amcl_ports_test_handles(void) { size_t n; pthread_mutex_lock(&ports_lock); n=handle_count; pthread_mutex_unlock(&ports_lock); return n; }
uint64_t amcl_ports_test_handle_sequence(void) { uint64_t n; pthread_mutex_lock(&ports_lock); n=next_handle-1; pthread_mutex_unlock(&ports_lock); return n; }
#endif
