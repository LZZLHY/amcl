// stack_sampler.h — 渲染线程 native 栈采样器
//
// 目的：定位"渲染线程在 native 层 CPU 空转（黑屏 / 偶发崩）"的根因。
// Java 看门狗只抓"卡住不动"的线程，抓不到"满载在跑"的线程；非 root 消费机也
// 无法用 processdump / /proc/<tid>/stack 外部取栈。本采样器在 **进程内** 周期性
// 对渲染线程做 native backtrace（信号 + 帧指针链回溯），打到 hilog。
//
// 触发策略：仅在"渲染线程持有 GL context 且长时间没有出帧（glfwSwapBuffers 停滞）"
// 时才采样并打印——正常游戏出帧时完全静默，黑屏忙循环时自动激活。
//
// 取栈机制：sampler 线程用 tgkill 给渲染线程发实时信号，信号处理器里从 ucontext
// 取 PC + 走 x29(FP) 链拿各帧返回地址（只读栈内存 + 边界检查，async-signal-safe，
// 不调用 dladdr / _Unwind_Backtrace，避免 loader 锁死锁）。符号化（dladdr）在
// sampler 线程做。日志含 so 名 + 相对加载基址的偏移，可直接喂 addr2line。

#ifndef AMCL_STACK_SAMPLER_H
#define AMCL_STACK_SAMPLER_H

#ifdef __cplusplus
extern "C" {
#endif

// 设置渲染线程 tid（在 GL context 成功绑定到某线程时调用，gettid()）。
// 多次调用会更新为当前持有 context 的线程（context 跨线程转移时自动跟踪）。
void amcl_sampler_set_render_tid(int tid);

// 启动后台采样线程（幂等，重复调用无副作用）。
void amcl_sampler_start(void);

// 停止后台采样线程（渲染窗口真退出时调用）。
void amcl_sampler_stop(void);

// 由 libentry.so 在初始化时调用，注入它独占可见的函数指针：
//   elfDladdr     = &elf_dladdr       （地址→ELF-loaded 库符号反查）
//   elfSymGlobal  = &elf_sym_global   （按名在 ELF-loaded 库查符号，用于取 AsyncGetCallTrace）
//   getJavaVM     = &jvmGetJavaVM     （取 JavaVM*）
// OHOS linker namespace 隔离使 libglfw 无法 dlopen/dlsym libentry，故由 libentry
// 主动推入（libentry 依赖 libglfw，可直接调用此 glfw 前缀导出函数）。
void glfwOHOS_samplerSetJvmHooks(void* elfDladdr, void* elfSymGlobal, void* getJavaVM);

#ifdef __cplusplus
}
#endif

#endif // AMCL_STACK_SAMPLER_H
