# OpenJDK 上游测试入口

本目录执行各 major 锁定源码中的原始测试，主要正确性依据来自上游测试集合。
项目专有 loader／安装／平台桥的最小反例继续保留，但不能代替上游语义覆盖。
源码固定点来自 `prebuilt/jdk/build-inputs.json`，harness 来源来自 `sources.json`。
测试正文、断言、WhiteBox、VM 参数、native agent 和 othervm/agentvm 不做平台简化。

## 工具构建与执行

先在工作区外登记并准备 `sources.json` 指定 commit 的干净 jtreg 源树，使用
JDK17+ 在 Linux/WSL 中执行 `prepare.py --source <固定源树> --host-jdk <宿主JDK>
--output <外置工具构建容器>`。它调用官方 `make/build.sh`，保留其依赖 checksum
校验，输出 image 与逐 JAR 摘要收据，不向项目或全局 TEMP 写中间物。

`run.py` 必须指定 major、锁定 OpenJDK source、实际被测 jdk、host-jdk、jtreg image、
harness-receipt 和外部 output。默认 `--role ohos-target --suite jdk --mode agentvm`，
选择原 `:tier1`。可重复传 `--test test/hotspot/jtreg/compiler`、`--vm-option=<参数>`，
并按上游要求传 `--native-path`。上游 ProblemList 只接受显式 `--exclude-list`，
正文与摘要入账，不自动加入本项目排除表，不默认跳过 headful/sound/进程能力。

先核真实 `bin/java -XshowSettings:properties -version` 的 major、OS 与映像摘要。
`host-reference` 只签发宿主参考结果；OHOS 目标不能偷偷使用宿主 JVM 或仅调用
某个 Java main 模拟完整 launcher。合法目标启动条件未闭合时记录环境阻断，
不会由工具存在或零测试退出 0 宣称通过。支持真实 CLI 的目标可直接运行同一入口。

每轮保留原 `.jtr`、JTreport、控制台、精确选择和 VM 选项；成功后只回收亲建
工作目录中的可再生 classes/tmp，失败现场保留。`PASS_SELECTED_TESTS` 仅指收据中
实际执行的原测试，完整平台资格还需逐项核对未运行/条件过滤/硬件等范围。

## 逐阶段验收

1. 各代对应 `jdk`、`hotspot`、`langtools` tier1，先验证真实工具运输与运行身份。
2. 适配触及的 compiler、runtime、GC、thread、NIO、Process、Attach、JFR、Sound、
   Font/ImageIO、jlink/native-agent 等原始目录，保留每代实际展开集合。
3. 使用上游 gtest 构建产物与 jcstress 运行并发语义，另记录工具/源码/参数身份；
   JDK8 不因现代版本具有某个测试框架就虚构对应构建产物。
4. 目标正确性、平台条件、测试框架错误、上游已知失败分别归因；不可修改断言或
   默认关闭 C2 来取得通过。TCK/JCK 与一般回归验证仍为不同资格。

当前接线状态由本轮实际收据决定；新增执行器本身不表示上述四阶段已经通过。

`run-native.py` 对 gtest 要求同次 `package_jdk_test_image.py` 收据，并核实际
正式libjvm和gtest可执行文件摘要，同时核验完整测试映像和相邻专用gtest libjvm。
后者由上游以同次HotSpot对象加原测试重新链接，必须优先加载，不能被普通产品VM替换。
现代显式test-image构建固定GoogleTest1.14.0原commit；缺少launcher/测试VM直接失败。
使用原 `-jdk` 和 XML 结果，不把零用例当通过。
`prepare-jcstress.py` 以锁定源执行原 Maven install（包括完整 verify；archetype子构建
需要前置core已安装到显式外置私有仓库）；`run-native.py` 运行原 tests-all
JAR，并通过原 DiskReadCollector/TestGrading 导出结果。API_MISMATCH 保留 NOT_RUN，
不能利用原框架对不适用API的忽略规则冒充全部并发语义通过。

2026-10-26 的首轮执行器接线使用 Windows Microsoft JDK21.0.3、锁定21u测试源，
CompletableFuture目录6项通过；这是 host-reference，不是同源码Linux对照或OHOS资格。
原 VMProps 的 IMPLEMENTOR 缺失提示保持原日志，未改测试或宿主release文件使其消失。
