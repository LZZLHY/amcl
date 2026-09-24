#ifndef AMCL_GRAPHICS_CONTEXT_ABI_H
#define AMCL_GRAPHICS_CONTEXT_ABI_H
#include <stdint.h>
#ifdef __cplusplus
#define AMCL_CONTEXT_DEFAULT(value) = value
#else
#define AMCL_CONTEXT_DEFAULT(value)
#endif

/** 窗口前端与进程owner交换的C资源记录。只包含固定宽度数值、驱动句柄和进程期
 * 字符串指针，不包含std::string、智能指针、互斥或虚函数。调用期间由context owner
 * 线程独占；所有权仍留在窗口会话中，结构本身不取得NativeWindow引用。
 */
typedef struct AmclEglFailureV1 {
    const char* stage AMCL_CONTEXT_DEFAULT("");
    int32_t error AMCL_CONTEXT_DEFAULT(0x3000);
    uint32_t driverFailure AMCL_CONTEXT_DEFAULT(0);
} AmclEglFailureV1;
typedef struct AmclGraphicsContextStateV1 {
    int32_t width AMCL_CONTEXT_DEFAULT(0), height AMCL_CONTEXT_DEFAULT(0), shouldClose AMCL_CONTEXT_DEFAULT(0);
    int32_t swapInterval AMCL_CONTEXT_DEFAULT(0);
    uint32_t swapIntervalSet AMCL_CONTEXT_DEFAULT(0);
    void* display AMCL_CONTEXT_DEFAULT(0);
    void* surface AMCL_CONTEXT_DEFAULT(0);
    void* parkingSurface AMCL_CONTEXT_DEFAULT(0);
    void* context AMCL_CONTEXT_DEFAULT(0);
    void* shareContext AMCL_CONTEXT_DEFAULT(0);
    void* config AMCL_CONTEXT_DEFAULT(0);
    int32_t actualContextMajor AMCL_CONTEXT_DEFAULT(0), actualContextMinor AMCL_CONTEXT_DEFAULT(0);
    int32_t actualContextProfile AMCL_CONTEXT_DEFAULT(0), actualContextFlags AMCL_CONTEXT_DEFAULT(0);
    void* nativeWindow AMCL_CONTEXT_DEFAULT(0);
    int32_t contextOwnerTid AMCL_CONTEXT_DEFAULT(0);
    uint32_t eglSurfaceDetachPending AMCL_CONTEXT_DEFAULT(0), eglTeardownPending AMCL_CONTEXT_DEFAULT(0);
    uint32_t contextLostFatal AMCL_CONTEXT_DEFAULT(0), auxiliary AMCL_CONTEXT_DEFAULT(0);
    uint64_t shareGroup AMCL_CONTEXT_DEFAULT(0), contextPermit AMCL_CONTEXT_DEFAULT(0);
    AmclEglFailureV1 lastFailure;
} AmclGraphicsContextStateV1;

// 请求参数与资源状态分开；create只用context请求，attach只用新窗口及其权威几何。
typedef struct AmclGraphicsContextRequestV1 {
    int32_t major, minor, profile;
    uint32_t forward;
    void* nativeWindow;
    int32_t width, height;
} AmclGraphicsContextRequestV1;
#define AMCL_CONTEXT_CREATE 1u
#define AMCL_CONTEXT_SUSPEND 2u
#define AMCL_CONTEXT_ATTACH 3u
#define AMCL_CONTEXT_DESTROY 4u
#undef AMCL_CONTEXT_DEFAULT
#endif
