# 现代 JDK 安全点与普通信号源码契约

本契约覆盖 17、21、25 的受控源码构建，不代替完整包、HAP 或设备验收。
JDK8 的经典实现保持独立，不适用下列现代源文件列表。

三个主版本的 `0005`、`0006`、`0007` 已从活动 `patches/series` 移除：

- `0005` 令普通 `void javaSignalHandler` 丢弃未识别结果，可能重复执行同步故障指令；
  恢复上游 fatal 入口。AMCL 的四参数宿主信号桥另有处理结果与链顺序，不在这里删除。
- `0006` 在未取得正常处理 stub 时放开共享坏轮询页并返回成功，未完成安全点协议。
- `0007` 把 bad polling page 从不可读改为可读，使真实页读取不再按协议触发协调。

原 patch 文件保留原字节用于既有发行来源与负对照；只能按活动 series 应用。
旧 `port_jdk21_patches.sh`、`port_jdk25_patches.sh` 已成为明确拒绝执行的退役入口，
不会再重置源码或生成危险 diff。维护者应在独占的锁定源树中创作、审查新增补丁，
再由 `prepare_jdk_source.py` 和 `apply_jdk_patches.py` 重放完整活动集。

`docker/scripts/verify_jdk25_safepoint.py` 的历史文件名保留兼容，
`--major 17|21|25` 选择真正主版本，省略时仍为 25。构建前和来源落盘前分别核对：

1. `prebuilt/jdk/build-inputs.json` 的官方仓库、完整 commit 与真实 Git HEAD 一致。
2. 活动 series 无退役编号、越界、重复或缺失文件。
3. 下列完整文件与**该主版本自己的固定上游**逐字节相同：
   `safepointMechanism.cpp`、`os_linux_aarch64.cpp`、`signals_posix.cpp`。

因此换名补丁、保留 `NONE` 字符串的条件绕过也会失败；不能只依靠编号规则。
未来确需对这三个文件做合法平台适配，先重新审查协议及负例，不能单纯放宽守卫。
正常 ret/JNI/隐式异常与未知同步故障的运行行为仍须分别验收。

静态检查：

```text
python -B scripts/test-jdk25-safepoint-contract.py --major 17
python -B scripts/test-jdk25-safepoint-contract.py --major 21
python -B scripts/test-jdk25-safepoint-contract.py --major 25
```

追加 `--source <已经应用当前活动集的真实锁定源树>` 时，测试在仓外副本分别应用
历史 0005、0006、0007 及其组合，要求生产守卫命中正确拒绝分支。还包括改名旧补丁、
错误 HEAD 等负对照。测试不修改传入源树，不从这些源码结果推定 C2/设备通过。

实施进度见 [施工记录](../../docs/refactor/运行时与音频修复施工记录.md)；
完整功能、ABI 和发布范围见 [总方案](../../docs/adaptation/JDK_ADAPTATION_AUDIT_REPAIR_UPDATE_PLAN.md)。
