// mc_launcher.h — MC 启动器接口 (P6)
#ifndef MC_OHOS_MC_LAUNCHER_H
#define MC_OHOS_MC_LAUNCHER_H

#ifdef __cplusplus
extern "C" {
#endif

// ⚰️ 2026-08-27（加载链审查修复批次）：legacy mcLaunch() 已退役
//   （C 层拼 classpath、绕过 AmclClassLoader 隔离契约），
//   唯一启动入口 = mcLaunchWithProfileV2。

/**
 * 数据驱动启动 Minecraft（v3 架构）。
 * ArkTS 层解析 version.json 后构建所有参数，C 层纯执行。
 *
 * @param appFilesDir  应用 filesDir
 * @param gameDir      .minecraft 目录
 * @param jdkVersion   JDK 版本号
 * @param xmxMb        JVM Xmx（MB），0=自动
 * @param mainClass    主类名（如 "net.minecraft.client.main.Main"）
 * @param classpath    冒号分隔的 classpath（ArkTS 层已构建好）
 * @param mcArgsStr    MC 参数（逗号分隔，如 "--version,1.20.4,--gameDir,..."）
 * @return 0 成功（异步），负数失败
 */
int mcLaunchWithProfile(const char* appFilesDir, const char* gameDir,
                        const char* jdkVersion, int xmxMb,
                        const char* mainClass, const char* classpath,
                        const char* mcArgsStr,
                        const char* extraJvmArgs);

/**
 * 数据驱动启动 Minecraft（v4 参数协议）。
 * ArkTS 以字符串数组直传 MC 参数与 JVM 参数，避免逗号拼接拆分导致参数损坏。
 */
int mcLaunchWithProfileV2(const char* appFilesDir, const char* gameDir,
                          const char* jdkVersion, int xmxMb,
                          const char* mainClass, const char* classpath,
                          int mcArgc, const char* const* mcArgv,
                          int extraJvmArgc, const char* const* extraJvmArgv);

/**
 * 获取 MC 启动器状态（进度/错误信息）
 */
const char* mcGetStatus();

/**
 * 同步启动调用线程的结构化图形失败；返回 JSON schemaVersion=1 或空对象。
 * 必须在同一次 mcLaunchWithProfile 返回后、同线程读取；不读取后台 Java 运行故障。
 * 清空函数也由 NAPI 在参数校验之前调用，避免参数拒绝复用上一轮快照。
 */
const char* mcGetGraphicsLaunchFailure();
void mcClearGraphicsLaunchFailure();

/**
 * 检查 MC 游戏文件是否就绪
 * @param mcDir  .minecraft 目录路径
 * @param mcVersion  MC 版本号
 * @return JSON 格式的检查结果
 */
const char* mcCheckFiles(const char* mcDir, const char* mcVersion);

/**
   * MC 是否仍运行。隔离 JVM 已发布退出请求时返回 0，让现有 UI 轮询交还窗口；不重入 JVM。
 */
int mcIsRunning();

/**
   * 隔离退出请求存在时确认 UI 窗口交接，原 hook 保留原始退出码结束；否则沿用立即退出兜底。
 */
void mcForceExit();

/**
 * 获取设备总物理内存（MB）
 */
int mcGetDeviceMemoryMB();

/**
 * 获取推荐的 JVM 最大堆内存（MB）
 * 基于设备总内存的一半，对齐到 256MB；下限 512，上限为设备总内存的 80%
 */
int mcGetRecommendedXmx();

/**
 * 读取 MC 输出日志（最后 maxBytes 字节）
 */
const char* mcReadLog(const char* mcDir, int maxBytes);

#ifdef __cplusplus
}
#endif

#endif // MC_OHOS_MC_LAUNCHER_H
