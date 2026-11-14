# 双 NCP/VM Attach 与共享 PerfData 资格

该模式固定为 `native-temp-vms`。target 独占安装本 nonce 的完整候选；client 只读复用同槽，各自创建真实 VM 并取得生产 use.SH。它不调用 shell/JLI、不录音、不写用户世界，不授予 CLI 或其他设备资格。

## 宿主验证

沿用 `docker/project.py test --suite runtime-java`。原完整 TU/Job 测试保留全部旧用例，补 TSFN/hook 创建失败、排队失败、取消、真实 execute→complete 和 complete 后环境关闭；`run-pair-host.py` 直接提取生产 session 正文，不复制调度算法，再跑固定两 owner、迟到退出、生命周期故障以及合成协议/driver 回归。输出随本次 QA 外置。

合成协议资料显式标记 syntheticOnly，不作为目标设备数据。测试变异包括两个角色的版本、nonce、PID、归档、JAR、有效 flags、Java/native 临时根、Attach、共享计数、发现、完成标记、退出、清理和跨文件摘要。driver 测试替换的是外部命令执行器；生产脚本没有跳过身份或资格检查的开关。

## 真机驱动

使用 `run-vm-pair-device.py`，必填参数包括设备 serial、物理 app files 根、major、新 nonce、HAP/归档/JAR 文件及各自 SHA、对应部署收据、两个临时根预期和新的外部输出目录。USB 与 TCP 均按明确 `-t` 传入，不发现/切换其他设备。

`expected-native-root` 是实际应用私有 `files/tmp`，必须与两个 VM 的 TMPDIR/VMSupport 一致。`expected-java-root` 是本次宿主传给 jvmInit 的 nonce 安装根，例如 `.../files/jdk-runtime-qualification/<nonce>`；既有 `-Djava.io.tmpdir` 具有独立 Java 文件语义。两者可以不同，不能为了通过夹具改变产品默认值。

驱动先核实际 HAP/归档/JAR SHA 以及 HAP 中嵌入的完整 JAR，再证明设备 nonce 不存在；只发送 SHA 侧车和归档。启动前运行正常 `power-shell wakeup`、前台 EntryAbility，再只读查询 `PowerManagerService`。AWAKE 未确认或观察到此前导致冻结的 10000ms 临时覆盖时拒绝本轮启动，不修改电源/超时设置。

只发送一次带固定 profile 的 Want。驱动等待父报告和 `owner-reclaimed.json`，随后回读 `run-native-temp-vms/{target,client}`。每次轮询使用独立文件，失败输出保留；不用旧文件或单 VM verifier 代证。读取报告中的实际父 PID 后记录 `/proc/<pid>/cgroup`；本设备已观察到的 `/Thawed` 与 Linux v1 不可冻结根组 `/` 分别登记，Frozen、缺失、重复或未知状态不能资格通过，也不能当作性能样本。根组语义依据 [Linux 官方文档](https://docs.kernel.org/admin-guide/cgroup-v1/freezer-subsystem.html)，不是把所有未命名状态默认当成功。

## 独立验收

`verify-vm-pair.py` 要求同一组独立预期参数。它只读并拒绝重复 JSON/Properties 键、损坏行、缺失文件、路径越界及矛盾身份，核两个实际 PID、正常 init/main/Destroy、四个完成 token、完整 JAR、安装所有权、有效 flags、标准只读 Attach、共享 nonce/递增计数和 jvmstat 发现。

两个 SDK 退出事件、正常 owner 注销回收及按确切路径检查的退出后文件消失必须同时成立。`callbackSignal=0` 不被解释成 OS exitCode；输出仍为 `osExitStatus:null`。`postExitFilesAbsent=false` 即便两 VM 的 Java/Destroy 都正常也必须拒绝，不能删除残留文件迎合条件。

父报告的 `transportOk` 只表示结果返回。`owner-cleanup-failed.json`、未知退出、poisoned PID、异常注销、超时、冻结或清理缺失都不能成为通过。普通 `tests/runtime-java/verify-device.py` 明确拒绝本 profile。


## 0032 正常 VM 终结源码消费者

`attach-exit-consumer.py` 与 `attach_exit_consumer.cpp.inc` 直接消费明确 JDK 源码树中的
平台 owner/init/cleanup/stop/restart 正文；测试只在最后发布前注入受控暂停点，不复制
生产生命周期算法。命令必须提供源码根、主版本及独立输出，例如：

```sh
python3 tests/runtime-native-temp/attach-exit-consumer.py --source-root /source --major 25 --output /output/attach-exit-25
```

Linux 宿主需已有 g++、ASan/UBSan；不会自动安装工具。短 AF_UNIX 夹具父目录可用
`--fixture-parent` 指定，缺省 `/tmp`，不改变全局临时目录；失败保留确切夹具根及记录。
`--prepare-only` 只生成输入和 SHA，绝不标记测试通过。

夹具核对 init 最后发布与终结互斥、终结后拒绝 init/restart、native 重启等待结束、
fatal 自锁避免、重复正常结束与 atexit、listener FD 保留和新同名对象不误删、EINTR
后成功、非 ENOENT 失败仍保留文件及诊断。正常 atexit 和 quick_exit 路径分别执行；
关闭 OHOS 条件编译的 quick_exit 对照应保留 socket，证明检查能识别原缺口。

该测试只授源码消费者边界；四代完整 OHOS 构建与目标双 VM 回归仍分别执行。
