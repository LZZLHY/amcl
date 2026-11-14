#ifndef AMCL_SDL_AUX_RUNTIME_ABI_H
#define AMCL_SDL_AUX_RUNTIME_ABI_H
#include <stdint.h>

// 图形owner可选尾部使用的固定C记录。指针仅作为驱动/资源身份值，不能跨调用借用窗口对象。
// ABI1主SDL不调用本接口；ABI2辅助描述符必须有本表及已核同映像的SDK辅助协议。
#define AMCL_SDL_AUX_CONFIGURE 1u
#define AMCL_SDL_AUX_PUBLISH_EGL 2u
#define AMCL_SDL_AUX_REVOKE_EGL 3u
#define AMCL_SDL_AUX_CLAIM 4u
#define AMCL_SDL_AUX_QUIT 5u
#define AMCL_SDL_AUX_RETIRE_SESSION 6u
// 热路径只查询已锁定会话存活；SDK须先核自身固定pthread身份与PID，此查询不授予新owner。
#define AMCL_SDL_AUX_PEEK_ACTIVE 7u
#define AMCL_SDL_AUX_FIRST 1
#define AMCL_SDL_AUX_READY 2
#define AMCL_SDL_AUX_INVALID -1
#define AMCL_SDL_AUX_WRONG_PID -2
#define AMCL_SDL_AUX_WRONG_THREAD -3
#define AMCL_SDL_AUX_CHANGED -4
#define AMCL_SDL_AUX_RETIRED -5
#define AMCL_SDL_AUX_UNPROVEN -6
#define AMCL_SDL_AUX_FOREIGN_INSTANCE -7

typedef struct AmclSdlAuxRequestV1 {
    uint32_t structSize, abiVersion;
    uint64_t processId, sessionId, instanceCookie;
    int32_t launchThreadId;
    uint32_t reserved;
    void* display;
    void* context;
    void* drawSurface;
    void* nativeWindow;
    uint64_t contextPermit, presentationToken, generation, resourceEpoch;
    // configure绑定已cold核验的制品文件身份；claim的cookie还须由owner核到同一文件映像。
    uint64_t selectedFileDevice, selectedFileInode;
} AmclSdlAuxRequestV1;

typedef struct AmclSdlAuxResultV1 {
    uint32_t structSize, abiVersion;
    int32_t status, launchThreadId, ownerThreadId;
    uint32_t reserved;
    uint64_t sessionId, instanceCookie, proofGeneration;
} AmclSdlAuxResultV1;
#endif
