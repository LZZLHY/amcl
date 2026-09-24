#include <deviceinfo.h>
#include "desktop_host_api.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <atomic>

const AmclDesktopHostV1* amclDesktopHostResolve() {
    static const bool desktopDevice = [] { const char* type = OH_GetDeviceType(); return type && strcmp(type, "2in1") == 0; }();
    if (!desktopDevice) return nullptr;
    static std::atomic<const AmclDesktopHostV1*> cached{nullptr};
    static std::atomic<pid_t> owner{0};
    const pid_t pid = getpid();
    if (owner != pid) { cached = nullptr; owner = pid; }
    const auto* current = cached.load(std::memory_order_acquire);
    if (current) return current;
    char path[160]{};
    snprintf(path, sizeof(path), "/data/storage/el2/base/files/.amcl_desktop_host_%d.lock", pid);
    const int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return nullptr;
    uintptr_t address = 0;
    bool ok = false;
    if (flock(fd, LOCK_SH) == 0) {
        ok = pread(fd, &address, sizeof(address), 0) == sizeof(address);
        flock(fd, LOCK_UN);
    }
    close(fd);
    if (!ok || !address) return nullptr;
    // Reject stale/corrupt descriptors without dereferencing their contents.
    Dl_info symbol{};
    if (!dladdr(reinterpret_cast<void*>(address), &symbol) || !symbol.dli_sname ||
        strcmp(symbol.dli_sname, "amclDesktopHostGetV1") != 0 ||
        symbol.dli_saddr != reinterpret_cast<void*>(address)) return nullptr;
    const auto getter = reinterpret_cast<const AmclDesktopHostV1* (*)()>(address);
    const auto* api = getter();
    if (!api || api->magic != AMCL_DESKTOP_HOST_MAGIC || api->size != sizeof(*api) ||
        api->pid != static_cast<uint32_t>(pid) || !api->submit || !api->snapshot ||
        !api->gamepadRead || !api->requestClose || !api->clipboardRead || !api->clipboardWrite ||
        !api->eventEpoch || !api->waitEvents || !api->wakeEvents || !api->takeDrop) return nullptr;
    cached = api;
    return cached;
}
extern "C" void amclDesktopNotifyInput() {
    const auto* api = amclDesktopHostResolve();
    if (api) api->wakeEvents();
}
