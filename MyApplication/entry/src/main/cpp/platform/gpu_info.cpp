// gpu_info.cpp — GPU 信息查询
// 职责：提供 GPU/EGL 信息字符串（供 ArkTS UI 显示）

#include "gpu_info.h"
#include "native_gl.h"
#include "system_egl.h"
#include "graphics_runtime_binding.h"
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <cstdint>   // uintptr_t：用于过滤被当成指针的 GL 枚举值（见 safeGlString）
#include <string>
#include <sstream>

namespace {

// glGetString 只有在**存在 current context** 时才有定义。没有 context 时它的返回值
// 不可信 —— 2026-08-01 真机实证：在本项目的 GL 栈上它会返回**入参本身**
// （未实现的 stub 不设返回值，x0 里残留第一个参数），于是 `p ? p : ""` 这类
// NULL 检查完全挡不住，随后 std::string 构造里的 strlen 直接踩空：
//     SIGSEGV(SEGV_MAPERR)@0x0000000000001f03
//     #00 strlen+16 → #01 char_traits::length → #02 basic_string(char const*)
//     #03 getGpuInfo+472
// 0x1F03 正是 GL_EXTENSIONS 的枚举值，这就是"返回入参"的铁证。
// 触发路径是 RenderPage.onLoad 里的 setTimeout(1500) → refreshGpuInfo()：
// 那一页的 XComponent 只建 surface、不建 GL context，所以永远没有 current context。
//
// 两层防御：
//   ① 先确认 current display + context 都在，否则一个 GL 查询都不发；
//   ② 即便有 context，也过滤掉明显不是字符串地址的返回值（低地址页），
//      这样将来换别的 GL 实现踩到同类 stub 也不会崩。
const char* safeGlString(unsigned int name) {
    using GetString = const unsigned char* (*)(unsigned);
    // 只观察本局已绑定 provider；不在设置/UI 线程偷偷初始化默认 MG。
    const auto getString = reinterpret_cast<GetString>(amclGraphicsGlProcV1("glGetString"));
    const char* p = getString ? reinterpret_cast<const char*>(getString(name)) : nullptr;
    if (reinterpret_cast<uintptr_t>(p) < 0x10000u) {
        return nullptr;  // NULL，或被当成指针的枚举值/错误码
    }
    return p;
}

} // namespace

extern "C" const char* getGpuInfo() {
    static thread_local std::string info;
    std::ostringstream ss;

    // 查询当前 EGL display 信息
    using GetDisplay = EGLDisplay (*)();
    using GetContext = EGLContext (*)();
    using QueryString = const char* (*)(EGLDisplay, EGLint);
    const auto getDisplay = reinterpret_cast<GetDisplay>(amclGraphicsEglProcV1("eglGetCurrentDisplay"));
    const auto getContext = reinterpret_cast<GetContext>(amclGraphicsEglProcV1("eglGetCurrentContext"));
    const auto queryString = reinterpret_cast<QueryString>(amclGraphicsEglProcV1("eglQueryString"));
    EGLDisplay display = getDisplay ? getDisplay() : EGL_NO_DISPLAY;
    const char* eglVendor = display != EGL_NO_DISPLAY && queryString ? queryString(display, EGL_VENDOR) : nullptr;
    const char* eglVersion = display != EGL_NO_DISPLAY && queryString ? queryString(display, EGL_VERSION) : nullptr;
    const bool hasGlContext = (display != EGL_NO_DISPLAY) && getContext && getContext() != EGL_NO_CONTEXT;

    // 查询 GL 信息：必须有 current context，否则一律视为不可用（见上方注释）
    const char* vendor = hasGlContext ? safeGlString(GL_VENDOR) : nullptr;
    const char* renderer = hasGlContext ? safeGlString(GL_RENDERER) : nullptr;
    const char* version = hasGlContext ? safeGlString(GL_VERSION) : nullptr;
    std::string extStr;
    // 现代 GL/GLES 使用索引扩展枚举；旧 context 没有该接口时才读取旧扩展字符串。
    if (hasGlContext) {
        using GetInt = void (*)(unsigned,int*);
        using GetStringi = const unsigned char* (*)(unsigned,unsigned);
        const auto getInt = reinterpret_cast<GetInt>(amclGraphicsGlProcV1("glGetIntegerv"));
        const auto getStringi = reinterpret_cast<GetStringi>(amclGraphicsGlProcV1("glGetStringi"));
        if (getInt && getStringi) {
            int count = 0; getInt(GL_NUM_EXTENSIONS,&count);
            for (int i=0;i<count && i<16384;++i) {
                const auto name = getStringi(GL_EXTENSIONS,static_cast<unsigned>(i));
                if (name) { extStr += reinterpret_cast<const char*>(name); extStr += ' '; }
            }
        } else {
            const char* extensions = safeGlString(GL_EXTENSIONS);
            extStr = extensions ? extensions : "";
        }
    }

    ss << "===== GPU / 渲染信息 =====\n\n";
    if (!hasGlContext) {
        ss << "⚠️ 当前线程没有 current GL context，GL 查询全部跳过。\n";
        ss << "   （本页的 XComponent 只创建 surface，不创建 GL context；\n";
        ss << "     GL 信息要在真正建过 context 的路径上看，例如 MC 运行中。）\n\n";
    }
    ss << "EGL 厂商: " << (eglVendor ? eglVendor : "N/A") << "\n";
    ss << "EGL 版本: " << (eglVersion ? eglVersion : "N/A") << "\n\n";
    ss << "GPU 厂商: " << (vendor ? vendor : "N/A") << "\n";
    ss << "GPU 型号: " << (renderer ? renderer : "N/A") << "\n";
    ss << "GL 版本: " << (version ? version : "N/A") << "\n\n";

    // 检查关键扩展
    ss << "===== 关键扩展检查 =====\n\n";
    auto hasExt = [&](const char* ext) {
        return extStr.find(ext) != std::string::npos;
    };
    ss << "GL_OES_vertex_array_object: " << (hasExt("GL_OES_vertex_array_object") ? "YES" : "NO") << "\n";
    ss << "GL_EXT_texture_compression_s3tc: " << (hasExt("GL_EXT_texture_compression_s3tc") ? "YES" : "NO") << "\n";
    ss << "GL_OES_texture_float: " << (hasExt("GL_OES_texture_float") ? "YES" : "NO") << "\n";
    ss << "GL_EXT_color_buffer_float: " << (hasExt("GL_EXT_color_buffer_float") ? "YES" : "NO") << "\n";
    ss << "GL_OES_geometry_shader: " << (hasExt("GL_OES_geometry_shader") ? "YES" : "NO") << "\n";
    ss << "GL_OES_tessellation_shader: " << (hasExt("GL_OES_tessellation_shader") ? "YES" : "NO") << "\n";

    ss << "\n===== Minecraft 兼容性评估 =====\n\n";
    std::string verStr = version ? version : "";
    if (verStr.find("OpenGL ES 3.2") != std::string::npos) {
        ss << "OpenGL ES 3.2: YES - 最佳兼容性\n";
    } else if (verStr.find("OpenGL ES 3.1") != std::string::npos) {
        ss << "OpenGL ES 3.1: YES - 良好兼容性\n";
    } else if (verStr.find("OpenGL ES 3.0") != std::string::npos) {
        ss << "OpenGL ES 3.0: YES - 基础兼容性\n";
    }

    info = ss.str();
    return info.c_str();
}
