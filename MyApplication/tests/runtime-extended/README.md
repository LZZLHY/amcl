# 独立扩展 Java 资格模块

`ExtendedRuntimeQualification` 统一编译为 Java 8 class52；独立宿主 runner 生成自己的 JAR，
目标侧由 `runtime-java/build-fixture.py` 纳入同一可追溯 JAR，并通过固定 extended profile 接入。
两种运行方式都保留独立输出，不把源码通过视为目标执行成功。固定入口：

```java
ExtendedRuntimeQualification.main(new String[] { absoluteExistingRunDirectory, "17" });
```

第二参只能为 `8 / 17 / 21 / 25`，必须与实际 VM 主版本一致。入口只新建
`runDirectory/extended-runtime/`，已存在便拒绝覆盖；不调用 `System.exit`。
进程 owner 必须提供 180 秒硬时限，并在超时后确认实际进程回收。socket 自带五秒
连接/accept/读写时限，所有分支 close 后有限 join；工具/JFR 库无法由 Java 线程中断
证明强制退出，因此宿主 runner 与目标 NCP owner 是最外层期限的责任方。

现代资格 profile 的模块访问只包含
`--add-exports=java.base/sun.security.tools.keytool=ALL-UNNAMED`（受控 keytool）和
`--add-opens=java.base/java.lang=ALL-UNNAMED`（读取实际 ProcessImpl 的机制/helper字段）。
不把它加入生产公共参数。8 的完整经典布局保留 `<jdk>/lib/tools.jar`，固定源码中的
ToolProvider 从 `<java.home>/../lib/tools.jar` 自动加载；实际 OHOS `java.home` 为
`<jdk>/jre`。同版 HotSpot `os::set_boot_path` 已列入 `<java.home>/lib/jfr.jar`，
实取经典 image 也含该 JAR。因此 8 的唯一 classpath 是本测试 JAR，无需追加 tools.jar
或修改 bootclasspath；真实设备仍需验证实际工具/JFR执行，不能以布局证明执行通过。

测试实际执行 UTF-8 JavaCompiler 编译与载入、jar 工具创建并再次从 JAR 载入、javadoc
文档生成、keytool 生成/导出证书和错误口令拒绝、固定程序的 ProcessBuilder 真执行、IPv4/IPv6 回环字节往返、TLS 1.2/1.3
受控信任握手、错误证书和错误主机名拒绝，以及 JFR 录制后读取本线程 ThreadSleep 事件。
JDK25 的 CPUTimeSample 独立检查实际本线程可用样本；固定上游仅实现 Linux 路径，
OHOS 按本项目 0015 恢复 timer。Windows 或旧主版本的该项单列 `NOT_SUPPORTED`，
不能由普通 JFR PASS 推导 CPU 采样 PASS。没有 trust-all，也没有外网依赖。

工具入口根据 `prebuilt/jdk/build-inputs.json` 的四个固定源码版本审核：

- JavaCompiler 与 DocumentationTool 使用 `javax.tools.ToolProvider` 公共 API。
- 17/21/25 jar 使用 `java.util.spi.ToolProvider`；8 使用 `sun.tools.jar.Main.run`，不调用会退出的 main。
- 8/17/21 keytool 将 `-debug` 放首参，固定源码中的 run/tinyHelp 失败均改为抛异常；25 使用公开返回 int 的 `Main.run`。
- 25 的 `0009` 已退役，当前活动 `0015` 与实际线程 CPU timer 探针不能被旧文件的存在覆盖。

主要产物为 `progress.jsonl`、`result.json`、`tools/`、`security/`、`process.json`、`process/`、`network.json`、
`recording.jfr` 和 `jfr-events.json`。每个项目区分 `PASS / FAIL / NOT_SUPPORTED / NOT_RUN`；
必须项不可用仍使总体资格失败。证书和 PKCS12 仅为本次测试生成，固定公开测试口令不能
作为真实凭据使用。JDK bin 工具的 CLI 执行、外网可达性、其他设备和生产 Java Sound 均不由本模块声明。

ProcessBuilder 在 OHOS 仅执行固定 `/system/bin/true`，Linux 宿主为 `/bin/true`，Windows
宿主执行同一 java.home 的 `java.exe -version`。stdout/stderr 直接重定向到新私有文件，
五秒 wait 超时则 destroyForcibly 后再次真实 wait；异常路径也回收已创建进程。Java 8 的
`start()` 本身没有超时 API，最外层进程 owner 的硬期限仍然必要。报告记录请求属性、
实际静态 launchMechanism/helper、启动 IOException、wait 与真实退出；helper存在性只作诊断。

若 OHOS 默认 POSIX_SPAWN 因下载槽 jspawnhelper 不能执行而失败，独立新 VM 才能使用
测试专属 `-Djdk.lang.Process.launchMechanism=FORK` 作对照；不能在本 VM 类初始化后改
属性。宿主 runner 的 `--launch-mechanism FORK` 仅接受 POSIX 宿主。8 的固定 Linux
默认是 VFORK，不等于现代默认。FORK 成功不证明子分支严格 async-signal-safe：四代上游
仍有 opendir/readdir/strtol/closedir 和 sysconf 路径，这个后续修复缺口必须保留，生产
默认与 patch series 均未在本模块更改。

宿主入口明确指定现有工具和仓外新目录，例如：

```powershell
D:/Python313/python.exe tests/runtime-extended/run-host.py `
  --javac E:/Minecraft/java/jdk-17.0.12/bin/javac.exe `
  --java-home E:/Minecraft/java/jdk-17.0.12 `
  --java-home E:/Minecraft/java/jdk21 `
  --output D:/dhao1/desktop/AMCL/.workspace/run/jdk-finish/runtime-extended/host-next
```

runner 使用与当前独立目标通道一致的 64–256 MiB 堆、保留正常优化，并冻结实际源字节、
校验所有 class52、生成确定性 JAR，记录工具 SHA、命令、
真实进程返回状态、超时及回收。未提供的 8/25 home 保留在 `untestedMajors`，不会因
17/21 通过而填成四代通过。宿主子进程环境只清除可能偷偷注入 JVM 参数的三个变量，
保留原用户环境在主进程中的值；没有禁优化、限制为 C1 或跳过失败的开关。
