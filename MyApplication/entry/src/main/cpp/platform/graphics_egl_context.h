#pragma once
#include "graphics_runtime_export.h"
#include "desktop_egl_core.h"

namespace amcl::graphics {
struct GraphicsRuntimeBinding;
/** 窗口前端无关的EGL资源状态。句柄只在渲染owner线程修改，驱动操作失败必须保留原句柄。
 * nativeWindow只是已有broker租约的观察值；本结构不取得或释放NativeWindow/presentation权。
 * GLFW可以继承这些字段，SDL继续由自己的窗口适配器持有资源，不把SDL私有布局引入核心。
 */
using EglContextState = AmclGraphicsContextStateV1;

/** 已冻结的后端操作表。前端只传自己的资源状态和请求，不再逐操作重新按profile分支。
 * 返回false表示原句柄仍需owner继续清理；错误文本描述实际阶段，不授权同进程切换后端。
 */
struct EglContextOperations {
    const char* implementation;
    bool desktopApi;
    bool (*create)(const GraphicsRuntimeBinding&, EglContextState&, const amcl::desktop::ContextRequest&, int, std::string&);
    bool (*suspend)(const GraphicsRuntimeBinding&, EglContextState&, int, std::string&);
    bool (*attach)(const GraphicsRuntimeBinding&, EglContextState&, void*, int, int, int, std::string&);
    bool (*destroy)(const GraphicsRuntimeBinding&, EglContextState&, int, std::string&);
};
// 工厂注册处是后端实现与profile的唯一接线点；未知实现返回null，不能借默认GLES兜底。
AMCL_GRAPHICS_PUBLIC const EglContextOperations* FindEglContextOperations(const char* profile);
// 同一运行时的其他映像只通过该转发表使用公共C ABI，不直接访问owner的C++账本。
AMCL_GRAPHICS_PUBLIC const EglContextOperations* ForwardedEglContextOperations(bool desktopApi);
}
