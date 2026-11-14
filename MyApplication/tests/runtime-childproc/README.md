# OHOS childproc 独立候选资格

本目录保留独立候选、锁定上游源码及现役 `0024-ohos-childproc-safe-fork.patch`
的源码/分派回归。现役补丁已进入四代 series；完整构建与目标设备资格仍按各包证据单独登记。
closeDescriptors 是四代上游 childProcess 的一部分；
修复它不能代替 JDK_execvpe、环境、PATH、信号和失败管道的完整源码审查。

child_fd_cleanup_candidate.h 是 C11/C++ 共用的小型清理候选：

- 只保留调用者约定的低位 FD；固定探针使用 0、1、2 和失败报告 FD3。
- 优先 syscall(SYS_close_range, 4, UINT_MAX, 0)；返回错误后读取 child 自己的
  /proc/self/fd，使用 4 KiB 对齐栈缓冲与严格的 linux_dirent64 解码。
- 目录记录、十进制溢出、真实系统调用失败均向调用者返回失败。保存第一 errno，
  尝试回收目录 FD；不在失败后继续 exec，也不吞掉目录读取错误。
- 不调用 opendir/readdir/strtol/closedir，不申请堆，不使用 child 中的 sysconf，
  不按高 RLIMIT 盲目循环，也不拿父侧 FD 快照替代 child 内核表。
- 目前使用 Linux close 的 EINTR 后 FD 已释放语义；候选面向 OHOS/Linux ABI。
  其他系统不能只复用这一个判断而宣称可移植。

fd_probe.hpp 在 fork 前准备报告、稠密 FD、稀疏高 FD，以及晚于初始集合创建的 FD；
child 只运行 syscall/POD 路径。PR_SET_PDEATHSIG(SIGKILL) 加实际 PPID 核对用于外层
NCP 被终止时回收内层 child。父侧分别观察强制 close_range、强制 getdents64 与 AUTO，
每行有独立 5 秒 deadline，终止仍拥有的直接 child 后实际 waitpid 回收。
父侧 JSON/RAII 从不进入 child 分支，AArch64 对象的未定义符号也要独立检查。

输出区分内部真实 waitStatus/exitCode/terminationSignal 与外层 NCP 的未分类
callbackSignal。close_range 遭 SIGSYS、内核返回 errno、父侧准备失败都保留原貌，
AUTO 成功不能遮蔽强制分支失败。每行核对已知 FD 已关闭、stdio/FD3 保持、父 FD 仍开放，
同时记录实际 syscall 次数；这是一项功能对照，不是完整性能基准。

标准入口为 docker/project.py test --suite runtime-process，经既有 run-ncp.sh
追加本目录 run-host.sh。原 tests/runtime-process/run-host.sh 的七组
processor-setup 回归保持独立。故障解析用 ASan/UBSan；真实 fork 内核轨不启用会向
child 代码插入运行时回调的 sanitizer。

固定 TestHooks 模式 fd-cleanup 追加在原六退出动作及 exec-routes 之后。
同一个 process Want 即可触发；不接受任意代码、命令、文件路径或动态信号。
目标产物为 fd-cleanup.marker.json、fd-cleanup.child.json 和 fd-cleanup.ncp-exit.json，
总报告中分别为 fdCleanup 与 fdCleanupNcpExitObservation。
所有名称与既有退出/exec 文件分离。

宿主通过只证明该宿主内核与测试输入；SDK 编译只证明 SDK ABI。只有绑定实际 HAP、
设备系统、原始报告与退出记录之后，才能授予该目标的资格。手机/API20、JDK bin 的
exec 可用性和完整 fork-child 安全闭包均不由本探针自动获得。

## Java ProcessBuilder 数据与取消资格

`JavaProcessQualification.java` 是独立 class52 入口，调用固定为
`JavaProcessQualification.main(new String[]{existingAbsoluteRunDir, major})`。
run 目录须已存在、绝对且规范；主版本必须与实际 VM 一致。它独占创建
`java-process/`，不复用已有同名目录，也不调用父 VM 的 `System.exit`。
主流程负责将源码加入固定资格 JAR、接入独立 profile 和最外层 NCP deadline；
本目录不修改 NativeJava、Want、既有 Extended 入口或 JAR。

目标分支要求真实 `os.name` 为 HarmonyOS/OHOS，执行固定 `/system/bin/sh` 与内置
字面量脚本。脚本只用 `read`、`printf`、`pwd`、`trap` 等 shell builtin，没有外部工具
或孙进程。运行目录只作为 `ProcessBuilder.directory`，不拼进脚本。Windows 宿主用
当前 Java 的固定嵌套 `Child` 类，Linux 宿主用 `/bin/sh`；报告明确区分这些平台。
仅 Windows child 的退出码夹具使用 `System.exit(7/255)`，父资格入口没有退出调用。

固定检查包含：默认机制属性未被覆盖；8192 条多脚本 UTF-8、emoji 和 shell 元字符行的
stdin/stdout/stderr 并发泵送；每个主要数据流超过 1 MiB，完整字节比对并保留各自 SHA；
独立 child 环境与 Unicode cwd；退出码 7/255；不存在程序、非执行文件、cwd 为文件和
不存在 cwd 的原始 `IOException`（POSIX 另核原 errno）；准备协议之后先有界 wait，
分别 destroy 和 destroyForcibly，再实际 wait、exitValue、isAlive 与线程 join；父环境
及 `user.dir` 原样保留。它不修改 JIT/CF 选项或全局启动机制。

每个启动、等待及 I/O join 有时限，失败仍由同一个 child owner 回收。
迟到的 start 看到取消标记会 kill/wait；任何未回收进程、未结束线程或证据写入失败都
保持 FAIL 并停止后续启动。Java 无法安全终止卡死在 native start/close 的线程，
所以最外层仍须由独立 NCP owner 硬性终止；完成 marker 不证明这层 owner 已被验证。
这些脚本没有孙进程，正常回收证据明确是对本次直接 child 的 Java wait/reaper 观察。

结果为 `java-process/result.json`，进展为逐项 force 的 `progress.jsonl`，结束文件为
`complete.json`（绑定 result SHA 和 passed）。失败也能生成完成文件，不能把文件存在
当作 PASS。独立 `verify-java-process.py` 逐字节重建期望数据、读取真实 `.bin` 流、
校验全部退出/异常/回收/父状态与 progress；不只相信 Java 报告的布尔值。
拉回真机材料后，显式传该次 native 约定的目标 run 根，不能从待验报告自取信任值：

```text
python verify-java-process.py --directory <本地拉回的java-process目录> --major 17 --platform ohos \
  --expected-run-directory <本次固定目标run绝对目录> --output <新的验收报告.json>
```

Windows 宿主固定入口为 `run-java-host.py --javac <明确javac> --java <明确java17>
--java <明确java21> --output <全新外置目录>`；它冻结源码、以 `--release 8 -encoding UTF-8`
编译，逐 class 检查 52，并验证错主版本及重复目录拒绝。正常运行不添加任何 VM 选项。
Linux 由标准 `runtime-childproc` suite 的 `run-qualification-host.sh` 末尾调用
`run-java-host.sh`，继续保留前面的源码和真实类分派回归。验证器另有真实报告正控、
同步改写外层 SHA 后的语义负控，以及实际 stdout 字节破坏负控。

本项只证明指定平台、指定包和固定 direct-child 命令的 ProcessBuilder 行为；不授予
JDK `bin/java` 独立 exec、任意命令许可、其他设备、完整性能或全 JDK 功能资格。
