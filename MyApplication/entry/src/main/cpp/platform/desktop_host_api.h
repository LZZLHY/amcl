#pragma once
#include <stddef.h>
#include <stdint.h>

// Process-local, immutable ABI. UI objects never cross this boundary.
#define AMCL_DESKTOP_HOST_MAGIC 0x414d434c44455331ULL
#define AMCL_DESKTOP_MAX_DISPLAYS 16
enum AmclDesktopCommandKind {
    AMCL_DESKTOP_RESIZE = 1, AMCL_DESKTOP_MOVE, AMCL_DESKTOP_FULLSCREEN,
    AMCL_DESKTOP_MINIMIZE, AMCL_DESKTOP_RESTORE, AMCL_DESKTOP_MAXIMIZE,
    AMCL_DESKTOP_SHOW, AMCL_DESKTOP_HIDE, AMCL_DESKTOP_TITLE,
    AMCL_DESKTOP_LIMITS, AMCL_DESKTOP_DECORATED, AMCL_DESKTOP_RESIZABLE, AMCL_DESKTOP_ASPECT,
    AMCL_DESKTOP_CLIPBOARD_PERMISSION
};
typedef struct AmclDesktopGamepad {
    uint64_t generation, events;
    int32_t connected;
    char id[128], name[128];
    float axes[6];
    unsigned char buttons[18], hats[1];
} AmclDesktopGamepad;
typedef struct AmclDesktopDisplay {
    int64_t id;
    int32_t x, y, width, height, workX, workY, workWidth, workHeight;
    float scale, refreshRate, widthMM, heightMM;
    char name[128];
} AmclDesktopDisplay;
typedef struct AmclDesktopSnapshot {
    uint64_t generation, accepted, completed, failed;
    int32_t active, windowId, status, decorated, resizable, lastError, closeRequested;
    int64_t displayId;
    int32_t x, y, width, height, displayCount;
    int32_t frameLeft, frameTop, frameRight, frameBottom;
    AmclDesktopDisplay displays[AMCL_DESKTOP_MAX_DISPLAYS];
} AmclDesktopSnapshot;
typedef struct AmclDesktopHostV1 {
    uint64_t magic;
    uint32_t size, pid;
    uint64_t (*submit)(int32_t, int32_t, int32_t, int32_t, int32_t, const char*);
    void (*snapshot)(AmclDesktopSnapshot*);
    void (*requestClose)(int32_t);
    int32_t (*clipboardRead)(char*, size_t);
    int32_t (*clipboardWrite)(const char*);
    int32_t (*gamepadRead)(int32_t, AmclDesktopGamepad*);
    uint64_t (*eventEpoch)();
    int32_t (*waitEvents)(uint64_t, int64_t);
    void (*wakeEvents)();
    int32_t (*takeDrop)(char*, size_t);
} AmclDesktopHostV1;

// Returns null on a mobile host or before desktop activation. A resolved API
// remains pinned for the process lifetime, even after its Window detaches.
#ifdef __cplusplus
extern "C"
#endif
#if defined(__GNUC__)
__attribute__((visibility("default")))
#endif
const AmclDesktopHostV1* amclDesktopHostResolve();
