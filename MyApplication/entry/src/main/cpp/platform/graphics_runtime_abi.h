#ifndef AMCL_GRAPHICS_RUNTIME_ABI_H
#define AMCL_GRAPHICS_RUNTIME_ABI_H
#include <stdint.h>
#include <stddef.h>
#include "graphics_context_abi.h"
#include "sdl_aux_runtime_abi.h"
#define AMCL_GRAPHICS_RUNTIME_ENV "AMCL_GRAPHICS_RUNTIME_V1"
/** 冻结后发布的公共C描述符。字符串/函数指针由中立运行时保留到进程退出；消费者
 * 先校验环境中的PID，再解引用并核验尺寸/版本。无有效表时宿主路线必须拒绝启动，
 * 不能另选系统库。窗口前端不需要认识GLFW、C++类或另一个linker namespace。
 */
typedef struct AmclGraphicsRuntimeV1 {
    uint32_t structSize, abiVersion;
    uint64_t processId;
    const char* profile;
    const char* api;
    const char* contextApi;
    void* (*glProc)(const char*);
    void* (*eglProc)(const char*);
    // 兼容尾部：新context首次交付前的诊断，0表示临时资源无法安全退休，必须终止该局。
    int (*inspectContext)(void*, void*, void*, void*, int, int, int);
    // 可选尾部：只有需要独立present证据的翻译器提供。同线程swap前后比较，未增加
    // 表示暂缓，不得递增成功呈现/输入屏障。空指针表示普通EGL成功语义足够。
    uint64_t (*presentSequence)(void);
    // context创建事务：先预留资格再进入驱动，成功登记真实句柄；只有实际销毁成功
    // 才退休。相同context在多个surface之间切换不申请第二份资格，兼容SDL utility/main。
    uint64_t (*reserveContext)(void* shareContext);
    int (*commitContext)(uint64_t permit, void* context);
    int (*retireContext)(void* context);
    // 跨映像只传递C记录与有界错误缓冲区；实现和内部资源账本完全留在唯一owner。
    int (*contextOperation)(uint32_t operation, AmclGraphicsContextStateV1* state, uint32_t stateSize,
        const AmclGraphicsContextRequestV1* request, int32_t threadId, char* error, uint32_t errorCapacity);
    int (*auxiliaryVerified)(int shared);
    int (*cleanupSafe)(void);
    const char* (*featuresJson)(void);
    const char* implementationIdentity;
    void* (*providerProc)(const char* name);
    // 可选尾部：显式辅助SDL的会话、呈现线程证明与实际实例准入；不改变主输入/窗口。
    int (*sdlAuxOperation)(uint32_t operation,const AmclSdlAuxRequestV1*,AmclSdlAuxResultV1*);
} AmclGraphicsRuntimeV1;
// 旧完整V1前缀保持可用；仅使用辅助SDL的消费者要求新增尾部，不以新sizeof读取旧表。
#define AMCL_GRAPHICS_RUNTIME_V1_CORE_SIZE ((uint32_t)offsetof(AmclGraphicsRuntimeV1,sdlAuxOperation))
#define AMCL_GRAPHICS_RUNTIME_V1_SDL_AUX_SIZE ((uint32_t)(offsetof(AmclGraphicsRuntimeV1,sdlAuxOperation)+sizeof(((AmclGraphicsRuntimeV1*)0)->sdlAuxOperation)))
#endif
