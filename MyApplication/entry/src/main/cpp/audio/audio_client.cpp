/**
 * 跨namespace薄客户端。环境文本仅为发现线索：先核真实导出符号归属，再调用getter，
 * 最后核ABI/PID/session和整个函数表的代码映像。无宿主时明确失败，不初始化替代owner。
 */
#include "audio_client.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <unistd.h>
namespace amcl::audio {
const AmclAudioApiV1 *resolveAudioHost() noexcept {
    const char *text = std::getenv(AMCL_AUDIO_HOST_ENV);
    if (!text || std::strlen(text) > 100)
        return nullptr;
    unsigned version = 0, pid = 0;
    unsigned long long address = 0;
    char tail = 0;
    if (std::sscanf(text, "%u:%u:%llx%c", &version, &pid, &address, &tail) != 3 || version != 1 ||
        pid != static_cast<unsigned>(getpid()) || !address)
        return nullptr;
    const auto pointer = reinterpret_cast<void *>(static_cast<uintptr_t>(address));
    Dl_info owner{};
    if (!dladdr(pointer, &owner) || !owner.dli_sname || std::strcmp(owner.dli_sname, "amclAudioHostGetV1") ||
        owner.dli_saddr != pointer || !owner.dli_fbase)
        return nullptr;
    const auto getter = reinterpret_cast<const AmclAudioApiV1 *(*)(void)>(pointer);
    const auto *api = getter();
    if (!api || api->magic != AMCL_AUDIO_MAGIC || api->abi != AMCL_AUDIO_ABI ||
        api->size != sizeof(AmclAudioApiV1) || api->pid != pid || !api->session)
        return nullptr;
    const void *functions[]{
        reinterpret_cast<const void *>(api->open),         reinterpret_cast<const void *>(api->start),
        reinterpret_cast<const void *>(api->stop),         reinterpret_cast<const void *>(api->flush),
        reinterpret_cast<const void *>(api->drain),        reinterpret_cast<const void *>(api->close),
        reinterpret_cast<const void *>(api->read),         reinterpret_cast<const void *>(api->write),
        reinterpret_cast<const void *>(api->available),    reinterpret_cast<const void *>(api->bufferSize),
        reinterpret_cast<const void *>(api->state),        reinterpret_cast<const void *>(api->frameBytes),
        reinterpret_cast<const void *>(api->framePosition), reinterpret_cast<const void *>(api->requestFinish)};
    for (const auto *fn : functions) {
        Dl_info info{};
        if (!fn || !dladdr(fn, &info) || info.dli_fbase != owner.dli_fbase)
            return nullptr;
    }
    return api;
}
} // namespace amcl::audio
