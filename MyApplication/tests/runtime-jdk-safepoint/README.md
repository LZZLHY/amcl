# JDK25 有界 C2 安全点回归

本目录只保存独立 Java 夹具、宿主运行器、证据验证器和普通 QA 版本准备器。
JAR、class、编译 XML、运行日志、设备回收件及任务收据均由调用方写到显式仓外
目录，不随源码入库。脚本只依赖完整 JDK25 和 Python3 标准库。

夹具自身不依赖 Minecraft、Fabric 或 Create，也不调用它们的入口。普通 QA
版本方案使用真实 Minecraft 主 JAR 作为启动器可识别的载体，另以本地 library
交付夹具；这不等于运行了 Minecraft 的游戏、渲染或保存退出验收。运行时机制与
修复边界见[安全点修复方案](../../docs/adaptation/JDK25_SAFEPOINT_FREEZE_REPAIR.md)。

## 测量与准入

`SafepointRegression.hotLoop` 使用 `System.nanoTime`、`Thread.onSpinWait` 和数值
运算构成有限时间热循环，结果由 volatile checksum 消费。循环只按自身单调
时钟截止，不等待另一个可能已经被安全点暂停的线程改变标志。

默认四轮，每轮分别测一次真实 `Thread.getAllStackTraces()` 和一次 `System.gc()`，
共八个两秒热循环。请求发起时仍须有大于1500ms的热窗口，延时上限单独设为
750ms。Dump必须实际看到热线程的 `hotLoop` 帧；GC必须观察真实MXBean的
collection count增加。坏轮询页若使请求一直等到循环返回，应得到明确延时
失败，而非因为“最终返回了”被判成功。

运行器使用 `-Xbatch`、关闭分层编译和降低编译阈值，并禁止内联目标热方法。
最终验证还要求本次完整 `LogCompilation` XML存在目标方法的 `compiler=c2`
nmethod：它在首个测量前生成，且至少一份代码跨整个测量域没有被
`make_not_entrant` 撤下。仅有编译器名称或总编译时间增加不算C2证据。

fixture自报实际PID和自身CodeSource JAR的SHA256。验证器与编译XML的process和
实际JAR再次对账，并严格核对：

- 一个runId、唯一start和execution_result、完整连续序号。
- 奇数序号Dump、偶数序号GC，begin/result的kind一致。
- start.rounds与外部请求值、终态completed/expected与实际应有数量一致。
- 请求发起时热窗口充足、真实观测结果存在、延时达标、worker全部停止。

Java只报告执行结果，不自行宣布完整C2验收通过。两条worker完成join、终态
输出并flush后，夹具显式 `System.exit(0/2)`，让嵌入HotSpot关闭编译日志。
这属于独立夹具生命周期；不能把它记为Minecraft正常保存或退出通过。

Java线程计时无法保证在VM整体停止响应时工作。宿主运行器另设原生进程硬超时，
默认配置为41秒；只终止本次创建的Java进程。设备运行也必须由VM之外的负责人
对该独立PID实施有限看护，不能用另一个Java watchdog作为可靠硬超时。

## 宿主运行

在仓库根执行，先将路径变量设置为本机真实绝对路径。输出根必须在仓库之外；
每次会话使用不存在的新目录。脚本不会更改JAVA_HOME或用户全局临时目录。

```powershell
$Repo = (Get-Location).Path
$Tools = Join-Path $Repo 'tests/runtime-jdk-safepoint'
$Jdk25 = '<完整JDK25绝对路径>'
$OutputRoot = '<仓库之外的绝对输出根>'
$HostOut = Join-Path $OutputRoot 'host-001'
python (Join-Path $Tools 'run_host.py') --java-home $Jdk25 --output $HostOut
```

`--java-home`和`--output`均为必填项。运行器用JDK25 javac按release21生成独立
JAR，保存真实命令、版本、stdout、stderr、编译XML和收据。返回0并且收据为
`passed-host-c2-only`才表示宿主正例；不能代替OHOS设备旧/新运行时对照。

`--rounds`、`--hot-ms`、`--max-latency-ms`可调整规模，但验证回收证据时必须使用
同一轮数和延时阈值。夹具会拒绝非法范围，避免阈值大到覆盖整个热窗口。

## 普通 QA 版本准备

当前产品的已安装版本扫描要求主JAR大于1MiB，小夹具不能直接冒充主程序。不要
填充JAR或伪造Mojang元数据。准备器要求显式给出：

- 完整、无继承链的真实26.2 QA profile。
- 与该profile的downloads.client摘要和大小匹配的真正Mojang client JAR。
- 本次已验证的夹具JAR。
- 全新的仓外输出目录、独立QA版本ID和已核设备绝对gameDir。

```powershell
$BaseProfile = '<已核完整26.2 QA JSON绝对路径>'
$ClientJar = '<真正MC26.2 client.jar绝对路径>'
$FixtureJar = Join-Path $HostOut 'amcl-safepoint-regression.jar'
$VersionId = '26.2-amcl-safepoint-qa-old'
$DeviceFiles = '<设备已核应用files绝对路径>'
$GameDir = "$DeviceFiles/.minecraft/versions/$VersionId"
$Stage = Join-Path $OutputRoot 'stage-old-001'
python (Join-Path $Tools 'prepare_real_profile.py') --base-profile $BaseProfile --client-jar $ClientJar --fixture-jar $FixtureJar --output $Stage --id $VersionId --game-dir $GameDir
```

准备器保留原真实主JAR、下载元数据、原libraries、logging和Java版本事实，只改
新版本ID/夹具入口/程序参数，并追加按自身SHA派生坐标的正常本地library。
它不发送设备文件、不写安装marker、不复制存档，也不安装额外模组。

LogFile必须是明确的设备绝对路径。JVM参数模板替换器不支持
`${game_directory}`，不能将它放入LogFile并假定会被替换；准备器直接使用
`--game-dir`下的compilation.xml。负责人通过正常UI重新扫描、选择独立QA版本
和JDK25、确认版本隔离后，仍须核实际resolved gameDir和最终JVM参数。

负责人按现有沙箱发送契约部署暂存内的versions与新增library。该入口不创建
GLFW窗口，界面可能留在启动页；以独立进程、日志、编译XML和返回码判定测试，
不以游戏画面为判据。预检失败应保留原文，不能跳过门禁或覆盖原MC实例。

## 同设备旧/新运行时对照

两轮使用相同夹具JAR和参数、同一设备、不同的独立进程与证据目录；每轮回收
实际使用的libjvm.so计算摘要，并绑定PID。不要只记录JDK槽目录名。旧库的延迟
失败和新库的及时完成都必须来自实际执行，不预填预期结果。

每轮回收目录应含：

```text
stdout.log                          原始console，不改事件正文
compilation.xml                     本轮完整封口的编译日志
amcl-safepoint-regression.jar        实际运行夹具JAR
```

调用同一个验证器，报告路径也必须在仓库之外且不存在：

```powershell
$Evidence = '<本轮回收证据目录绝对路径>'
$RuntimeSo = '<本轮实际回收libjvm.so绝对路径>'
$Report = Join-Path $OutputRoot 'old-verification.json'
python (Join-Path $Tools 'verify_run.py') --evidence $Evidence --report $Report --runtime-so $RuntimeSo --label device-old
```

新库使用独立目录、报告和label，不能覆盖旧证据。验证器只核输入原件，label
不是设备部署证明。缺C2、全Dump无GC、轮数或终态数量不符、超限延时、截断XML、
PID或JAR身份错配都应失败。直接_exit或force-stop留下的半截XML不拼接成通过。

## 既有应用 API 的边界

`runJvmEmbedTest`没有自定义JAR/mainClass/args参数，当前实现使用已存在的JVM运行
固定HelloWorld，不适合本测试，尤其不能向已经冻结的MC进程再注入诊断。

`runJavaProcessor(filesDir, jdkVersion, xmxMb, classpath, mainClass, args, workDir, logFile)`
能够fork独立JVM，但当前实现硬编码C1的TieredStopAtLevel=1，API不接受额外JVM
参数。不能把它当作已经完成此C2夹具的通路，也不能由NAPI导出推定存在可用的
外部宿主调用入口。正式设备C2测试使用上面的普通独立QA版本启动契约。
