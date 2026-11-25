/* Linux 下用真实 ELF 符号、flock 与 pread 验证跨 DSO 定位。仅把应用私有文件路由到匿名临时夹具。 */
#define _GNU_SOURCE
#include "../../platform/desktop_host_api.h"
#if defined(AMCL_GAMEPAD_FIXTURE)
int32_t amclGamepadRead(int32_t slot, AmclDesktopGamepad* out) {
    if (slot == -1 && !out) return 2;
    if (slot != 1 || !out) return 0;
    out->connected = 1;
    out->axes[0] = 0.5f;
    return 1;
}
#else
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
static int fixtureFd;
static int openFixture(const char* path, int flags) {
    char expected[160];
    snprintf(expected, sizeof(expected), "/data/storage/el2/base/files/.amcl_desktop_host_%d.lock", (int)getpid());
    return strcmp(path, expected) == 0 && flags == (O_RDONLY | O_CLOEXEC | O_NOFOLLOW) ? dup(fixtureFd) : -1;
}
#define open openFixture
#include "../../platform/gamepad_reader.h"
#undef open
#define REQUIRE(check) do { if (!(check)) { fprintf(stderr, "reader check failed at %d\n", __LINE__); exit(1); } } while (0)

static AmclGamepadReadFn resolve(AmclGamepadReaderDescriptor record, size_t bytes) {
    REQUIRE(ftruncate(fixtureFd, 0) == 0 && pwrite(fixtureFd, &record, bytes, 0) == (ssize_t)bytes);
    return amclResolveGamepadReader();
}

int main(int argc, char** argv) {
    REQUIRE(argc == 3);
    FILE* file = tmpfile();
    REQUIRE(file != NULL);
    fixtureFd = fileno(file);
    void* owner = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    void* foreign = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    REQUIRE(owner && foreign);
    AmclGamepadReaderDescriptor record = {0, 1, sizeof(AmclDesktopGamepad), (uint32_t)getpid(), 0};
    record.reader = (uintptr_t)dlsym(owner, "amclGamepadRead");
    AmclGamepadReadFn read = resolve(record, sizeof(record));
    AmclDesktopGamepad pad = {0};
    REQUIRE(read && read(-1, NULL) == 2 && read(1, &pad) == 1 && pad.axes[0] == 0.5f);
    REQUIRE(!resolve(record, sizeof(record.desktopGetter)));
    ++record.pid;
    REQUIRE(!resolve(record, sizeof(record)));
    --record.pid;
    --record.snapshotSize;
    REQUIRE(!resolve(record, sizeof(record)));
    ++record.snapshotSize;
    ++record.version;
    REQUIRE(!resolve(record, sizeof(record)));
    --record.version;
    ++record.reader;
    REQUIRE(!resolve(record, sizeof(record)));
    record.reader = (uintptr_t)dlsym(foreign, "amclGamepadRead");
    REQUIRE(record.reader && !resolve(record, sizeof(record)));
    fclose(file);
    dlclose(foreign);
    dlclose(owner);
    puts("gamepad reader PID / ABI / ELF owner / mapped snapshot PASS");
    return 0;
}
#endif
