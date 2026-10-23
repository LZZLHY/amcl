/**
 * LWJGL Java EGL 的晚加载查询桥：本 DSO 不拥有 display/context/surface，也不依赖
 * EGL、GLFW 或图形 runtime。只有 Java 首次使用 EGL 时才按包内绝对路径装入它；即使
 * ClassLoader 在另一个 namespace 装出桥的副本，也没有第二份翻译器或图形状态。
 *
 * LWJGL EGL.java 首先从本库查 eglGetProcAddress，随后用它查询 EGL 入口。唯一导出
 * 仅经跨 namespace 服务表向进程已冻结 runtime 的 eglProc 查询；未初始化/不支持的入口返回
 * null，由 LWJGL 正常处理。禁止主动 dlopen provider 或回退系统 EGL，否则 MG 的虚拟
 * 句柄可能被传入另一对象域。不得把本库加入 entry/GLFW 的 DT_NEEDED：公开 EGL 名字
 * 必须在 Java 晚加载后才出现，避免应用 UI 初始装载时抢占系统 EGL 的同名符号。
 */
#include "graphics_runtime_service.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

namespace {
// 与 Khronos __eglMustCastToProperFunctionPointerType 完全相同的 C ABI；使用无参数
// 函数指针避免为单纯查询桥引入平台 EGL 头和相应的意外链接依赖。
using EglFunction = void (*)();
}

/**
 * 查询当前进程 owner 的真实 EGL 入口。每次查询读取既有只读 C ABI，不缓存缺失结果；
 * 早于 owner 绑定的失败不能让后续合法初始化永久失效。生产 owner 自己校验 PID，fork
 * 子进程也不能借桥重新使用父进程的 provider。此函数不解释或制造任何 EGL 资源句柄。
 */
extern "C" __attribute__((visibility("default"))) EglFunction eglGetProcAddress(const char* name) {
    // EGL 契约也允许查询 gl* 等客户端 API 符号，不能按名字前缀过滤。是否存在可调用的
    // 客户端 API 仍由 owner provider 与调用线程的真实 current context 决定。
    if (!name || !*name) return nullptr;
    const char* encoded = std::getenv(AMCL_GRAPHICS_RUNTIME_SERVICE_ENV);
    if (!encoded || !*encoded) return nullptr;
    const int pid = static_cast<int>(getpid());
    int ownerPid = 0, end = 0;
    void* address = nullptr;
    // 必须先检查文本 PID 再解引用；fork 继承的地址和损坏/尾随文本不能成为有效表。
    if (std::sscanf(encoded, "2:%d:%p%n", &ownerPid, &address, &end) != 2 || encoded[end] ||
        ownerPid != pid || !address) return nullptr;
    const auto* owner = static_cast<const AmclGraphicsRuntimeServiceV2*>(address);
    if (!amcl::graphics::ValidGraphicsRuntimeServiceV2(owner, pid)) return nullptr;
    const auto* api = owner->bound();
    if (!api || api->structSize < sizeof(AmclGraphicsRuntimeV1) || api->abiVersion != 1 ||
        api->processId != static_cast<uint64_t>(pid) || !api->eglProc) return nullptr;
    return reinterpret_cast<EglFunction>(api->eglProc(name));
}
