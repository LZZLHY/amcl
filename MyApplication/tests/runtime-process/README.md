# NativeChildProcess 退出语义矩阵

此套件受 `MC_OHOS_BUILD_TESTS` 约束，只执行六个固定动作：入口返回、`_exit(0)`、
`_exit(7)`、`_exit(255)`、向本进程发送 SIGTERM、向本进程发送 SIGBUS。没有命令文本、
任意信号数值或可执行路径入口。

NAPI 接口为 `RunJdkProcessQualificationNapi(filesDir, nonce, callback)`，系统子入口为
`AmclJdkProcessQualificationMain`。输出只在 `filesDir/jdk-process-qualification/<nonce>`；
nonce 必须新建。每个动作先写入并 fsync 自身 PID/PPID 和 `before-action` marker，然后
才执行动作。marker 证明实际子进程已经到达该阶段，不证明后续调用一定完成。

父任务为每个动作创建新 NCP，10 秒 deadline 只用于这些短动作。超时或父侧异常调用
已核实提供者的官方 KillChildProcess，并一直持有任务到实际退出回调发生。提供者通过
Start 的 dladdr/RTLD_NOLOAD 显式句柄取得，Kill 必须与 Start 同属一个 DSO。子进程
owner 结束后才注销回调、释放提供者句柄；不使用裸 PID kill。

每行分别给出 `requestedMode`、`requestedExitCode`/`requestedSignal`、`childPid`、
`callbackObserved`、`callbackSignal`、`actualChildMarker`、`forcedTermination`。
`exitKind` 固定为 `unclassified`，没有伪造 waitpid 原始状态的字段。入口返回不是显式
`_exit(0)`，因此其 `requestedExitCode` 为 null。信号若被平台特殊处理器改写或吞掉，
保留真实回调/`signal-action-returned` 证据，不按请求内容改写结果。

需要单独实测的原因：官方 C API 文档把回调第二参定义为退出信号；公开 appspawn
源码的某版本却在 WIFSIGNALED 分支传 WTERMSIG、WIFEXITED 分支传 WEXITSTATUS，
后续 IPC 只留下同一个 `signal` 字段。因此 `exit(7)` 和 SIGBUS 的数值可能碰撞，不能
把公开源码或单个 callback=0 外推为当前商业系统上有完整 POSIX 退出状态。

`run-ncp.sh` 通过标准 `docker/project.py test --suite runtime-process` 执行，使用固定
Compose QA。ASan/UBSan/LSan 检查 7 个 provider 边界、11 个 NAPI 排队/完成故障和
busy/child owner 生命周期；另在单线程 Linux 测试进程中真实 fork/wait 六个固定动作，
核对它们自身的 marker、exit code 或终止信号。宿主 waitpid 证据不等于 OHOS NCP 回调
语义；最终设备报告必须独立保存。

原 `run-host.sh` 继续由 `--suite processor-setup` 执行原生产processor准备、NAPI、
信号、状态、取消/超时、fork入口与PID所有权回归；退出矩阵不替换这些测试。

## 固定签名PIE与实际解释器观测

原六个退出动作之后，另起固定 `exec-routes` NCP，并在应用父进程执行同一组观测。
两处都从本HAP固定入口的 `dladdr` 取得安装库目录，读取现有 `libamcl_exec_probe.so`，
校验真实AArch64 PIE/program headers并计算SHA；只使用其实际PT_INTERP，且该值必须等于
本SDK已核的 `/lib/ld-musl-aarch64.so.1`。不接收Want命令、不改权限、不复制/重签设备代码。

三条固定路线为 `/system/bin/true` 正控、直接执行已安装PIE，以及单次执行实际解释器并传入
同一PIE。每条保留精确argv、DAC/挂载事实、spawn错误、stdout、实际PID/PPID marker和
原始waitpid状态。每项5秒deadline只终止自己创建且尚未回收的直接子PID；输出洪泛持续
排空且保留上限，不能无限卡在drain里绕过deadline。NCP外层20秒监督与内部raw wait分开。

文件职责明确分离：

- `exec-routes.ncp-exit.json`：NCP退出回调观察，仍为unclassified。
- `exec-routes.child.json`：NCP内部的三条真实spawn/wait结果。
- `exec-routes.application-parent.json`：应用父进程内部的三条真实spawn/wait结果。
- `parent-report.json`：上述结果与原六动作的汇总。主进程与NCP、不同设备/API的许可不能互借。

`owner_test.cpp` 实际串联生产 `runParent → runMode → O_EXCL发布 → NAPI回调`，检查七份动作
观察与父进程exec报告不会发生命名碰撞。SDK边界在宿主仍明确拒绝NCP创建，不冒充平台进程。
可传一个外置目录保存 `parent-chain-report.json`，供独立JSON解析。

`exec_route_test.cpp` 直接编译 `processor_exec_probe.h`，配合真实宿主程序
`exec_route_child.c` 验证 exit7/255、SIGBUS、有限/无限输出、超时、关闭stdio、ENOENT及
坏ELF拒绝；实际AArch64产物在宿主只用于解析，不能当作目标执行通过。

当前生产 `fork_run_java.cpp` 尚未切换。新鲜NCP入口本身有多个线程，不能再fork后运行复杂
Java；官方NCP的设备范围/退出回调/终止API也不能被包装成已覆盖手机与最低API。
只有候选路径在对应设备成立并保持完整退出/取消语义后，才实施生产路线切换。
