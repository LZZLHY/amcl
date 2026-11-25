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
// -13 表示数字槽 journal 待恢复/不可核实，-14 表示字体配置或环境准备失败，
// -15 表示同步信号归一失败，-16 表示显式 MC 工作目录准备/进入失败，-17 表示原生临时根合同/目录/环境失败；这些错误不伪造 Java main 成功。
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
// 路径在handler登记前复制；登记后保持不可变，后续setter不覆盖。诊断FD/路径与
// 进程级handler同寿命，DestroyJavaVM不会提前关闭/清空；handler不触碰std::string。
void jvmSetCrashOutputPath(const char* path);

// 调用 Java 静态方法 className.main(String[] args)
int jvmCallMain(const char* className, int argc, const char** argv);

// 仅供独立 processor 在 main 返回后完成 VM 生命周期：等待非 daemon 工作、执行正常
// shutdown hooks，并检查 DestroyJavaVM 返回。返回 0 才能把正常结束报告给父进程；
// 没有超时保证，取消/超时应由进程监督者处理，不能用提前 _exit 截断合法工作。
int jvmFinishProcessor(void);

// 销毁前退休并停止/join本模块的 watchdog；自有 main/诊断仍在执行时拒绝销毁，
// DestroyJavaVM 失败保留 VM 身份和错误，不谎报成功。外部借用 JavaVM 的 GUI/采样/第三方
// native 所有者必须由会话先停止；此兼容 void 接口通过 jvmGetStatus 报告结果。
void jvmDestroy();

// 获取最近一次已发布操作的完整状态快照；返回缓冲属于调用线程，下次同线程查询前
// 有效。不同线程并发发布不会使已返回的 const char* 悬空，调用者仍不可跨线程保存。
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

#ifdef MC_OHOS_BUILD_TESTS
// 仅供Fresh独立资格进程选择固定CF三臂：省略本方自动项，由夹具显式提供完整策略。
// 不影响其它参数、不接受任意过滤规则或新增NAPI协议；普通产品不编译此入口。
int jvmSetQualificationCfExplicit(int enabled);
#endif

// fork 子进程第一项运行时操作：验证继承的保留态以及 PID 变化，再清理无 JVM 的配置副本。
// 必须先于 fontconfig/ELF 等原生操作；0=成功，-7=身份非法，不可继续，也不可清零来绕过。
int jvmResetForForkChild(void);

// 在 jvmInit 之前调用，设置额外的 JVM 参数（逗号分隔）
// 用于模组加载器（Fabric: -DFabricMcEmu, Forge: -Dfml.earlyprogresswindow 等）
void jvmSetExtraArgs(const char* args);

// 获取 JVM 指针（用于 JNI 操作，如设置系统属性）；未初始化时返回 NULL。
void* jvmGetJavaVM();
// 只返回当前已附加线程的 JNIEnv；未附加或本局已退休返回 NULL。不能跨线程保存该指针，
// 本接口不隐式附加线程；需要附加的调用者必须自行管理对应的 detach 所有权。
void* jvmGetJNIEnv();

// 诊断当前已就绪 JVM：系统属性、Runtime 及独立类加载器中的 HelloWorld。
// 不创建/重用另一 JVM，不修改已冻结的系统 classpath；重复调用由原子准入保护。
// 返回文本属于本次 native 调用线程，下一次同线程调用前有效；不要在 UI 主线程等待。
const char* jvmRunFullTest(const char* appFilesDir);

// 检查上次测试是否仍在运行
int jvmIsTestRunning(void);

// 检测 JIT (RWX mmap) 权限是否可用
// 返回 1 = 可用, 0 = 不可用
int jvmCheckJitAvailable(void);

#ifdef __cplusplus
}

// MC 专用 C++ 重载：仅真正启动游戏的共有 V1/V2 路线传入已选绝对 gameDir。
// 两参数 C ABI 保持原语义；processor/NCP/独立诊断不改变 cwd。目标目录在认领前打开，
// 实际进入只发生在现有一次性创建认领后、CreateJavaVM 紧前。无效路径在 VM 前拒绝，
// CreateJavaVM 一旦调用就保留本局 cwd 与不可重建状态；不猜测失败时没有遗留线程。
int jvmInit(const char* appFilesDir, const char* jdkVersion, const char* gameWorkingDirectory);

// 内部资格入口的runtimeFilesDir可能是独占安装根，真实appFilesDir由既有fd身份校验提供。
// 第4参只指定默认native/tool临时根的可信父目录；不改变JDK安装路径/Java文件属性/cwd，
// 不接受Want任意路径。现有2/3参入口传nullptr并保持原ABI，环境所有权都在同一主体。
int jvmInit(const char* runtimeFilesDir, const char* jdkVersion, const char* gameWorkingDirectory,
            const char* trustedAppFilesDir);

// 游戏入口显式选择手机正常退出冷启动；其他 JVM 调用仍走兼容重载。
int jvmInit(const char* runtimeFilesDir, const char* jdkVersion, const char* gameWorkingDirectory,
            const char* trustedAppFilesDir, bool returnToLauncherOnExit);

// 新协议：结构化参数列表，避免逗号拼接导致参数拆裂
void jvmSetExtraArgsList(const std::vector<std::string>& args);
#endif

#endif // MC_OHOS_JVM_LAUNCHER_H
