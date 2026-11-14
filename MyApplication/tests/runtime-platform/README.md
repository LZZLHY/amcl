# 真实系统身份与内部后端分派

四代 `java_props_md.c` 的 `uname` 结果保持原样。补丁 `0017` 只让精确的 `HarmonyOS`、
`OpenHarmony`、`OHOS` 选择当前 OHOS 目标已编译的 Linux/POSIX 后端，不匹配任意名字前缀，
不改 `os.name`、`os.version`，不改变 Process 的默认启动机制、用户权限检查或实际能力检测。

JDK 8 修复字体、默认 headless、进程、三个 NIO 工厂、端口配置及仍按名字分派的打印、
GSS/SDP、X11 和诊断路径；JDK 17 的 NIO/headless 已按构建平台选择，只补字体、进程、
端口/扩展套接字、jlink/jpackage 和其它仍按名字选择的入口。四代 SA 工厂仍需要具名识别；
JDK 25 的 JLine FFM 终端还同时检查 `OSUtils.IS_LINUX` 和 `CLibrary`，两处一起修复。
JDK 21/25 的基础 Process/NIO/FontUtilities/OSInfo 已依赖 `OperatingSystem` 构建常量，不复制旧版修复。

`dispatch-cases.json` 绑定锁定上游文件与补丁身份。`run-tests.py` 从显式外置 Git 克隆读取
真实对象，在新外置目录逐项 `git apply --check` 并重放**完整 series**，然后将实际补前/补后
谓词及 jlink 工厂编译执行。覆盖三种具名平台、原 Linux/Windows/macOS/SunOS/AIX/BSD，
以及似是而非的名称前缀和未知名称。原源码负控必须复现具名平台未识别，且其它平台结果不变。
这只证明源码重放及分类语义，不授予真实 CLI、ProcessBuilder、字体、打印、GSS、SDP、
终端或 attach 资格；对应实际功能及权限仍需在完整重建包上验证。

JVMCI 的 `linuxOs` 在 AArch64 还控制 x18 是否作为普通寄存器，不能把这类 ABI 决策当作
名字别名一起替换。17/21 的这段保持原样；25 已按构建常量启用 Linux 行为。是否保留 x18
须由 OHOS ABI 与实际编译配置单独核定，不能从 `os.name` 或这组谓词测试推断。

示例（参数均显式；`output` 不可已存在）：

```text
python tests/runtime-platform/run-tests.py --source-root E:/AMCL/.workspace/wt --javac <host-javac> --java <host-java> --output <external-new-output>
```
