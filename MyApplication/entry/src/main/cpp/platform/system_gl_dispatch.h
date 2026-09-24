#pragma once
#include "system_egl.h"

namespace amcl::desktop {
/**
 * 从创建context的同一系统EGL提供者解析GL函数，供NativeGL探针与冻结运行时共用。
 *
 * libGLv4导出的是包装函数，其线程GL表与Mesa的current context并非同一个状态。
 * EGL库先在UI线程加载、EglCoreInit随后在能力worker执行时，UI可能保留no-context表；
 * 直接dlsym得到的glGetString包装入口会经过这个旧表，即使eglMakeCurrent已经成功。
 * 使用系统eglGetProcAddress取得实际提供者的分派入口，避免跨线程误用包装层TLS。
 *
 * 本函数只消费已取得的只读EGL表，不绑定API、不切context、不装载私有系统驱动库。
 * EGL库的句柄由调用者保留到进程退出。缺入口时返回空，不再回退到libGLv4包装层。
 */
inline void* ResolveSystemGlProc(const SystemEglApi& egl, const char* name) {
    if (!egl.ready || !egl.eglGetProcAddress || !name || !*name) return nullptr;
    return reinterpret_cast<void*>(egl.eglGetProcAddress(name));
}
}
