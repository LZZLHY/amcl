/**
 * fork_run_java.h — 在子进程中运行 Java 程序
 *
 * fork 子进程 → ELF loader 加载 libjvm.so → JNI_CreateJavaVM → 运行 main()
 * 用于 Forge/NeoForge 各 processor 等需要独立 JVM 实例的场景。
 * 子进程和主进程的 JVM 完全独立，不存在 classpath 冲突。
 */

#ifndef FORK_RUN_JAVA_H
#define FORK_RUN_JAVA_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * 在子进程中运行 Java 程序，使用**显式工作目录**。
 * 用于跑 Forge/NeoForge 的各 processor —— 每个 processor 一个干净 classpath（只含其声明的 jar）
 * 的独立 JVM；参数任意（输出路径/标志位等），cwd 显式设为 mcDir 最稳（processor 全用绝对路径）。
 *
 * @param filesDir     应用 filesDir（如 /data/.../files）
 * @param jdkVersion   JDK 版本（如 "17"）
 * @param classpath    Java classpath（冒号分隔）
 * @param mainClass    主类名
 * @param argc         main 方法参数个数
 * @param argv         main 方法参数数组
 * @param workDir      子进程 chdir 的目标目录（通常是 .minecraft 根）；NULL/空则不 chdir。
 * @param logFile      stdout/stderr 重定向到的日志文件路径（可为 NULL）
 * @param xmxMb        JVM 最大堆内存 MB
 * @return 子进程退出码（0=成功），-1=fork 失败，-2=JVM 创建失败
 */
int forkRunJavaCwd(const char* filesDir, const char* jdkVersion,
                   const char* classpath, const char* mainClass,
                   int argc, const char** argv,
                   const char* workDir,
                   const char* logFile, int xmxMb);

#ifdef __cplusplus
}
#endif

#endif // FORK_RUN_JAVA_H
