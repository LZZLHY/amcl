// jvm_launcher.h — JVM 嵌入模块接口
#ifndef MC_OHOS_JVM_LAUNCHER_H
#define MC_OHOS_JVM_LAUNCHER_H

#ifdef __cplusplus
#include <string>
#include <vector>
extern "C" {
#endif

// 初始化一次 JVM；已创建/尝试创建过时返回 -7，必须更换进程；processor 正在 fork 返回 -8，可稍后重试。
// appFilesDir: 应用 filesDir 路径
// jdkVersion:  JDK 版本号（如 "17"），JDK 数据在 filesDir/jdk/<version>/
//              传 NULL 则使用默认路径 filesDir/jdk/（向后兼容）
// -9 表示用户/隐式环境参数违反 native 回调所有权；-10 表示隔离退出记录准备失败。
// 进入一次性创建事务后的失败不得在原进程重建 JVM，即使 JNI_CreateJavaVM 尚未返回成功。
int jvmInit(const char* appFilesDir, const char* jdkVersion);

// 运行时身份：0=Fresh，1=创建已开始，2=就绪，3=本局已结束，4=processor fork 保留中；DestroyJavaVM 不重置。
int jvmRuntimeState(void);
// 本局主函数返回/失败后退休 JVM，禁止再换 ClassLoader/游戏/运行槽重试。
void jvmRetireRuntime(void);

// 原子保留从 Fresh 到 fork 返回的窗口。0=已保留，-8=其他 fork 正在进行，-7=JVM 已被使用。
// 成功调用者必须恰好执行一次 fork，然后在父进程（包括 fork 失败）恰好释放一次。
int jvmReserveForFork(void);
// 父进程释放自己的保留；0=成功，-1=保留身份不匹配。不可在子进程调用此接口。
int jvmReleaseForkReservation(void);

// 设置当前游戏 stdout/stderr 文件，供 signal-safe crash tail 在 SIGABRT 时读取。
// 路径会复制到固定缓冲，handler 不触碰 std::string。
void jvmSetCrashOutputPath(const char* path);

// 调用 Java 静态方法 className.main(String[] args)
int jvmCallMain(const char* className, int argc, const char** argv);

// 销毁 JVM
void jvmDestroy();

// 获取最近一次操作的状态/错误信息
const char* jvmGetStatus();

// 在 jvmInit 之前调用，设置 JVM classpath（冒号分隔的 jar 路径）
void jvmSetClasspath(const char* classpath);

// 在 jvmInit 之前调用，设置额外的 native library 搜索路径
void jvmSetExtraLibPath(const char* path);

// 获取当前设置的额外 native library 搜索路径
const char* jvmGetExtraLibPath();

// 在 jvmInit 之前调用，设置 JVM 最大堆内存（MB）
void jvmSetXmx(int mb);

// fork 子进程模式（安装器 processor 专用）：在 jvmInit 之前调用，enabled!=0 时让 jvmInit
// 跳过【游戏主进程专属】的启动参数与诊断线程：
//   - -Djava.system.class.loader=com.amcl.launcher.AmclClassLoader（该类不在 processor
//     的干净 classpath 上，注入会令 JNI_CreateJavaVM 直接失败）
//   - -Dorg.lwjgl.* libname / glfw.checkThread0（渲染相关，构建工具用不到）
//   - 卡死诊断 watchdog 线程（processor 短命，不需要）
void jvmSetForkChildMode(int enabled);

// fork 子进程第一项运行时操作：验证继承的保留态以及 PID 变化，再清理无 JVM 的配置副本。
// 必须先于 fontconfig/ELF 等原生操作；0=成功，-7=身份非法，不可继续，也不可清零来绕过。
int jvmResetForForkChild(void);

// 在 jvmInit 之前调用，设置额外的 JVM 参数（逗号分隔）
// 用于模组加载器（Fabric: -DFabricMcEmu, Forge: -Dfml.earlyprogresswindow 等）
void jvmSetExtraArgs(const char* args);

// 获取 JVM 指针（用于 JNI 操作，如设置系统属性）
// 返回 NULL 如果 JVM 未初始化
void* jvmGetJavaVM();
void* jvmGetJNIEnv();

// 综合测试：探测 + 初始化 + HelloWorld（用于 UI 一键测试）
// 注意：此函数可能耗时较长（30秒+），不要在主线程调用
const char* jvmRunFullTest(const char* appFilesDir);

// 检查上次测试是否仍在运行
int jvmIsTestRunning(void);

// 检测 JIT (RWX mmap) 权限是否可用
// 返回 1 = 可用, 0 = 不可用
int jvmCheckJitAvailable(void);

#ifdef __cplusplus
}

// 新协议：结构化参数列表，避免逗号拼接导致参数拆裂
void jvmSetExtraArgsList(const std::vector<std::string>& args);
#endif

#endif // MC_OHOS_JVM_LAUNCHER_H
