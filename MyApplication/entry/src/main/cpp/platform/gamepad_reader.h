#pragma once
// GLFW 与 SDL 共用的 C ABI。前缀沿用原桌面宿主文件，尾部只授予手柄快照读取能力。
#include "desktop_host_api.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

typedef int32_t (*AmclGamepadReadFn)(int32_t, AmclDesktopGamepad*);
typedef struct AmclGamepadReaderDescriptor {
    uintptr_t desktopGetter;
    uint32_t version, snapshotSize, pid;
    uintptr_t reader;
} AmclGamepadReaderDescriptor;

// 跨 DSO 的 libc 环境不可作为权威源。同 PID 下用已有私有文件的 flock 线性读写。
static inline void amclGamepadReaderPath(char* path, size_t capacity) {
    snprintf(path, capacity, "/data/storage/el2/base/files/.amcl_desktop_host_%d.lock", (int)getpid());
}

// 只接受实际 libentry 的精确导出和当前快照大小。应用进程常驻该 NAPI 映像，调用方可缓存成功结果。
// 负返回表示原生路由不可用。(-1,NULL) 返回在线槽位 bitmask，其余合法槽正返回才是有效快照。
static inline AmclGamepadReadFn amclResolveGamepadReader(void) {
    char path[160];
    amclGamepadReaderPath(path, sizeof(path));
    const int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return NULL;
    AmclGamepadReaderDescriptor descriptor = {0};
    int complete = 0;
    if (flock(fd, LOCK_SH) == 0) {
        complete = pread(fd, &descriptor, sizeof(descriptor), 0) == (ssize_t)sizeof(descriptor);
        flock(fd, LOCK_UN);
    }
    close(fd);
    if (!complete || descriptor.version != 1 || descriptor.snapshotSize != sizeof(AmclDesktopGamepad) ||
        descriptor.pid != (uint32_t)getpid() || !descriptor.reader) return NULL;
    void* address = (void*)descriptor.reader;
    Dl_info owner;
    if (!dladdr(address, &owner) || !owner.dli_fname || !owner.dli_fbase || owner.dli_saddr != address ||
        !owner.dli_sname || strcmp(owner.dli_sname, "amclGamepadRead") != 0) return NULL;
    const char* name = strrchr(owner.dli_fname, '/');
    if (strcmp(name ? name + 1 : owner.dli_fname, "libentry.so") != 0) return NULL;
    return (AmclGamepadReadFn)address;
}
