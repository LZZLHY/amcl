# 扩展资格入口的固定源码依据

本模块的目标源码以 `prebuilt/jdk/build-inputs.json` 为准。宿主验证实际使用本机安装的
17.0.12 / 21.0.3，不能将其身份替换为目标 17u / 21u 的提交。下表是实现选择的依据，
源码可用性与实际功能运行分别计证。

| 项目 | 固定来源与调用选择 | 可证明范围 |
| --- | --- | --- |
| JavaCompiler / javadoc | `javax.tools.ToolProvider.getSystemJavaCompiler/getSystemDocumentationTool`，调用返回状态的 `Tool.run` | 编译 UTF-8 真实源并载入生成类；生成且读取实际 javadoc 类页面 |
| JDK8 jar | [8 的 Main.java](https://github.com/openjdk/jdk8u-dev/blob/35c254f58c70663df28cc7d15c9545c88250b6ce/jdk/src/share/classes/sun/tools/jar/Main.java)：构造 `Main(PrintStream,PrintStream,String)` 后调用 `run(String[])`；避开含退出调用的 main | 创建归档，逐字节核对资源和 class，再用独立 URLClassLoader 从 JAR 载入执行 |
| 现代 jar | [17](https://github.com/openjdk/jdk17u/blob/b7d004b4f2787ea49454291d48326ad1cd97c0d0/src/jdk.jartool/share/classes/sun/tools/jar/JarToolProvider.java)、[21](https://github.com/openjdk/jdk21u/blob/dfcd8d2eecfe62e91070244d8eb10906dc3c812d/src/jdk.jartool/share/classes/sun/tools/jar/JarToolProvider.java)、[25](https://github.com/openjdk/jdk25u/blob/e8f9ebe5ea813b675410a89fbfafa22e42c04e6a/src/jdk.jartool/share/classes/sun/tools/jar/JarToolProvider.java) 的公开工具 SPI | 真实返回状态，不执行 bin/jar，不推导目标 CLI exec 可用 |
| 8/17/21 keytool | 固定 Main 的 `run` 和 `tinyHelp` 均在 debug 状态抛异常；所有参数由夹具生成，首参固定 `-debug` | 生成两个独立 RSA 证书身份、导出 PEM、错误口令负例；不是任意参数工具入口 |
| 25 keytool | [25 Main.java](https://github.com/openjdk/jdk25u/blob/e8f9ebe5ea813b675410a89fbfafa22e42c04e6a/src/java.base/share/classes/sun/security/tools/keytool/Main.java) 已有公开 `int run(String[],PrintStream)` | 不调用根据非零返回码退出的 main；受控 run 返回值/异常均可观察 |
| 一般 JFR | [8 Recording](https://github.com/openjdk/jdk8u-dev/blob/35c254f58c70663df28cc7d15c9545c88250b6ce/jdk/src/share/classes/jdk/jfr/Recording.java) 和 [RecordingFile](https://github.com/openjdk/jdk8u-dev/blob/35c254f58c70663df28cc7d15c9545c88250b6ce/jdk/src/share/classes/jdk/jfr/consumer/RecordingFile.java) 已含公开录制、停止、dump 和 readAllEvents；跨代用反射保持 class52 | 必须读到本线程实际 ThreadSleep 事件，文件存在或类存在不能算通过 |
| 25 CPU 采样 | [25 元数据](https://github.com/openjdk/jdk25u/blob/e8f9ebe5ea813b675410a89fbfafa22e42c04e6a/src/hotspot/share/jfr/metadata/metadata.xml) 定义 `jdk.CPUTimeSample` 的 `throttle`、`eventThread`、`failed`、`stackTrace`；[sampler](https://github.com/openjdk/jdk25u/blob/e8f9ebe5ea813b675410a89fbfafa22e42c04e6a/src/hotspot/share/jfr/periodic/sampling/jfrCPUTimeThreadSampler.cpp) 按 Linux 条件实现 | 单独要求本线程、failed=false、非空栈的实际样本；普通 JFR 或原生 timer 投递成功不能替代它 |

8 的工具定位依据是 [langtools ToolProvider](https://github.com/openjdk/jdk8u-dev/blob/35c254f58c70663df28cc7d15c9545c88250b6ce/langtools/src/share/classes/javax/tools/ToolProvider.java)：
当 `java.home` 最后一级是 `jre`，它向上一级读取 `lib/tools.jar`。同一 image 的实取
`rt.jar` 已含工具 API 和 keytool/jar 类，`lib/tools.jar` 含 JavacTool。JFR 类位于
`jre/lib/jfr.jar`，[HotSpot os::set_boot_path](https://github.com/openjdk/jdk8u-dev/blob/35c254f58c70663df28cc7d15c9545c88250b6ce/hotspot/src/share/vm/runtime/os.cpp)
已将其列入默认 bootclasspath。因此只需正常经典 `java.home` 和本夹具 classpath，
不额外增补 JFR/tools bootpath 来掩盖安装布局错误。

本项目 25 活动 series 已用 `0015-ohos-jfr-thread-cpu-timer.patch` 替代 0009：它调用真实
线程 CPU timer，探测失败保留错误，arm 失败删除 timer，并在占用 SIGPROF 前探测。
已有 `napi_jdk_probe.cpp::timerProbe` 验证创建、投递到指定线程和删除，只是底层前置条件；
扩展模块仍须读取实际 JFR CPU 事件。Windows 25 对该事件单列平台不支持，OHOS 25
由 `amcl.platform.ohos=true` 进入必须验证的分支，不以真实 os.name 为 HarmonyOS 而跳过。

TLS 使用各 VM 的 KeyManagerFactory、TrustManagerFactory 和 SSLContext。正例仅信任
本次生成的 server 证书；错误证书正好信任另一独立身份，错误主机名使用 HTTPS 端点
识别。两个负例不仅要求 SSLHandshakeException，还要求异常链含证书验证原因，避免
把超时、重置或协议错误当成证书校验成功。完整数据帧与客户端/服务线程退出都要验证。

## ProcessBuilder 的实际机制与安全边界

[8 UNIXProcess](https://github.com/openjdk/jdk8u-dev/blob/35c254f58c70663df28cc7d15c9545c88250b6ce/jdk/src/solaris/classes/java/lang/UNIXProcess.java)
把 Linux 默认设为 VFORK，只允许 VFORK/FORK；其 helper 路径存在于类中不代表该机制
实际调用 helper。[17 ProcessImpl](https://github.com/openjdk/jdk17u/blob/b7d004b4f2787ea49454291d48326ad1cd97c0d0/src/java.base/unix/classes/java/lang/ProcessImpl.java)
默认 POSIX_SPAWN，[21](https://github.com/openjdk/jdk21u/blob/dfcd8d2eecfe62e91070244d8eb10906dc3c812d/src/java.base/unix/classes/java/lang/ProcessImpl.java)
与 [25](https://github.com/openjdk/jdk25u/blob/e8f9ebe5ea813b675410a89fbfafa22e42c04e6a/src/java.base/unix/classes/java/lang/ProcessImpl.java)
同样如此，现代 helper 位于 `<java.home>/lib/jspawnhelper`。属性在静态字段初始化时
确定，因此每个机制对照都必须使用新 VM，并核对实际字段而不只打印请求属性。

四代 libjava 的 fork-child 都进入受控 C `childProcess`，不在 child 创建 JVM 或运行
Java/JNI 初始化。但是 [25 childproc.c](https://github.com/openjdk/jdk25u/blob/e8f9ebe5ea813b675410a89fbfafa22e42c04e6a/src/java.base/unix/native/libjava/childproc.c)
以及固定 8/17/21 版本的 `closeDescriptors` 仍调用 opendir、readdir、strtol、closedir，
目录枚举失败后再调用 sysconf。它们不是已证明的严格 POSIX async-signal-safe 闭包；
不能因为是上游代码或固定 `/system/bin/true` 能运行就消除此边界。

本模块仅采集默认/FORK 的真实功能结果，不改生产默认。后续 OHOS 限定源补丁应单独
核实 close_range 或原始 getdents64 与有界栈缓冲，避免分配/锁和百万次 close 慢循环，
也不能只复制父进程 FD 快照而遗漏并发新打开的 FD。该候选方案不属于本夹具的既成能力。
