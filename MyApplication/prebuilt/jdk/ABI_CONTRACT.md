# JDK 应用 C++ ABI 与完整输入契约

四代 JDK 的新配方使用同一目标 SDK 的 `libcxx-ohos` 头和
`libc++_shared.so`（`std::__n1`），并使用该 SDK 的真实 compiler-rt/CRT。
宿主编译器、boot JDK 仍绑定实际 Docker image ID。普通 Linux Clang 显式补齐
选定 SDK 编译器的 OHOS 平台宏，并关闭隐式宿主 C++ 头搜索，避免 `include_next`
跨到另一套 libc++。这不等于宣称两个编译器生成的全部代码字节相同。

`libcxxabi_shim.so` 的名字为兼容旧配方保留，内容只保留版本入口及 JDK8 的
独立 libc 名称兼容。它以 `DT_NEEDED` 依赖真实运行库，不能定义 guard、
异常、RTTI、new/delete 或 `_Unwind_*`。`eh_stubs.c` 明确拒绝旧构建调用。
仓库旧二进制仍是历史输入，不因此被改写成新来源或重新发布。

动态查询只暴露 `.dynsym` 中符合 binding/visibility 的定义，不从任意 `.symtab`
导出 local/hidden 名字。绝对符号按 SHN_ABS 解释，零地址命中与缺符号分开；普通
默认可见定义允许抢占，PROTECTED/LOCAL/HIDDEN 与 SYMBOLIC 保持本库绑定。
有 hash 的负查询保持 hash/bloom 路径，不在大型 JVM 上退化为逐符号线性扫描。

历史 `v17.0.13-ohos-5`、`v21.0.5-ohos-7`、`v25.0.4-ohos-2` 的 libjli 漏导出
`JLI_ManifestIterate`，以完整文件 SHA、固定函数范围和同一映射 fd 保留单符号
例外；25 原件另保留既有 `JLI_IsStaticallyLinked` 动态构建答案。新包已有正确
导出，不能扩大这个名单为任意同名库或未知局部符号。

完整 image 携带真实 provider 供独立 CLI 使用；在 AMCL 内嵌入时，加载器要求
复用 HAP 已由系统加载的 `libc++_shared.so`，不能再次映射下载包内副本，也不能
用系统 `libc++.so` 的 `__h` 域替代。新 `amcl_jvm_is_embedded` 入口限定路径注入和
JLI 的 re-exec 例外，独立 `exec` 后不会像环境变量一样被继承。尚需通过的宿主
版本资格必须阻止旧宿主误推荐依赖新入口的新包。

自加载 FDE 的资源失败修复采用[应用 ABI provider 配方](../abi/README.md)：保留
所选 SDK 的合并 libc++/libc++abi 静态归档，重建固定公开 vendor libunwind 并增加
可检查映像登记/注销状态。原 SDK 导出全部保持，当前 loader 在本批构造前完成
有界 EH 结构/索引校验和自动登记，准备失败撤销本批，物理回收前注销。应用链接
移除 SDK 默认提前加入的静态 libunwind，禁止同一应用 ABI 域出现第二份展开状态。
HAP 门禁同时检查公开导出、首方未剥离产物中的私有副本，以及 SDK 剥离前后的
实际 LOAD 字节一致性。当前平板已验证混合帧异常及损坏元数据拒绝；这仍不等于
完整 TLS/卸载、Java 功能或其他设备资格。供应者身份与四份 JDK 输入
身份分别记录，已证明 ABI 兼容的宿主修复不自动要求四份 JDK 再编译。

本轮早期四份完整候选仍携带原 SDK provider。最终 JDK 分发包还必须同步修复
独立 CLI 所消费的 provider，并记录新的不可变 ZIP 身份；不能只修 HAP 的嵌入
路径就将旧候选直接激活为完整修复预览。

`docker/project.py` 在构建前冻结被记录的配方、patch/shim、完整目标 sysroot、
C++ 头/provider、compiler-rt/CRT 及许可。复制中发生内容漂移立即失败；容器只读
快照，来源写入本次 `build-inputs.json` 和包内 `build.inputClosure`。三个旧 SDK
哨兵字段为旧消费方保留，不再被当作完整输入身份。新内容需要新输入身份，
不能通过改旧 marker 认领先前构建卷。

打包从最终 image 收集全部文件，包含 `bin`、工具库、头、模块与许可。JDK8
另验证 Applet 类层。工具/helper 校验 AArch64、ELF 类型、装载边界、入口及
系统解释器；ZIP 中工具保留执行位。该静态验证不代替设备沙箱 exec 资格。

现代 JMOD 必须同步最终重链 JLI、JVM、应用 ABI 与许可；字体 provider 及许可跟随
`java.desktop.jmod`。完整打包和 provider/font 再封包均执行同一同步/回读入口，
原模块描述符保持原字节。派生收据记录每个实际修改的 JMOD 和同步脚本，源码导出
携带当次原脚本。外层 image 通过不能替代 jlink image 的真实文件核验；跨架构
主机 jlink 创建成功也不代表目标已经执行。

## 原生临时目录与工具发现

四代活动 `0030-ohos-native-temp-contract.patch` 与
`0031-ohos-perfdata-uid-identity.patch` 必须成对消费。OHOS 的原生临时根在
`os::init` 起点从启动 `TMPDIR` 冻结；getter 不再读可变环境、不分配或访问文件，
错误配置经现有 VM 初始化返回值拒绝。未配置时的 `/tmp` 仅是上游 fallback，
不保证应用 token 可用或独立 CLI 已合格。Java 默认 `java.io.tmpdir` 取同一冻结值，
普通显式 `-Djava.io.tmpdir` 仍按上游规则覆盖 Java 文件语义，不改变工具发现根。

Attach Java 端、原生监听端和 jvmstat/PerfData 使用同一 VMSupport/native 事实源，
客户端与目标须配置同一已验证根。现代 namespace 路径不再假定 `/tmp` 长度或固定
路径段数；原生 connect 按平台编码后的字节检查 `sun_path`，超限准确失败而不截断。
应用 UID 的 `getpwuid_r` 成功但无条目时，仅 PerfData 命名使用
`uid_<真实UID十进制>`；真实查询错误、异常空名字保留原失败路径，不改 NSS 或
`java.user.name`。原 owner、权限、符号链接、peer 凭据和原子发布规则仍成立。

新 libjvm 的 `.amcl.nativetemp` 节以正确的只读 LOAD 范围携带
`AMCL_OHOS_NATIVE_TMPDIR_V1`，经 GC/strip 后仍须存在。标记表示实现合同，来源
闭包仍须包含上述两个补丁，不能把标记单独当作目标能力或完整工具资格。
AMCL 在现有 JDK SH 租约内读取实际选中 libjvm，仅新合同包省略宿主自动加入的
`-XX:-UsePerfData` 和 `-XX:+DisableAttachMechanism`。合法无标记旧包保留原行为；
已声明标记但版本、属性或范围错误则拒绝，不能降为旧包绕过检查。

嵌入宿主只有 `jvmInit` 一个 `TMPDIR` 写者，从真实应用 `filesDir/tmp` 准备私有
目录。系统继承的 `TMPDIR` 不是应用用户的目录配置，不能因此改选权限不合格的缓存根；
宿主不识别或硬编码某一系统缓存路径，也不修改现有缓存权限。独立 JDK 仍按启动时
`TMPDIR` 冻结工具根；普通 `-Djava.io.tmpdir` 的覆盖语义不变。所选私有目录必须由当前
UID 拥有，权限与包含 namespace/监听临时名的 Unix 地址字节预算均合格。
发布前按持有 fd 重新核路径身份。创建认领之前只准备目录，
认领后、VM 线程出现前发布环境；进入 VM 之前失败恢复原缺席/空串/正文，进入后保持
一次性运行时的重启边界。原两参数 C ABI 和三参数 C++ 入口不变；只有安装资格 NCP
通过内部四参数入口分开传入 nonce 安装根与已核实的真实应用父根。manifest 和用户
显式参数保持原来源与末项覆盖顺序，不被条件默认去重吞掉。

私有目录的单进程 file/socket/mmap 前置观察不代替两个真实 VM 之间的 Attach 和共享
PerfData 验收。交付需新包实际 effective flags、有效共享正文和持续计数、只读跨 VM
请求及清理证据；旧候选的成绩不能回填到含新补丁的新 ZIP。

永久测试入口：

- `scripts/test-jdk-native-inputs.py`、`scripts/test-runtime-packaging.py` 验证身份、
  冻结后漂移、错误 ABI/ELF 等失败边界，接入 `runtime-foundation`。
- 固定 QA 的 `jdk-abi` 构建真实 AArch64 跨库测试；
  `jdk-abi-run --abi-artifacts ... --abi-libc ...` 在 QEMU 读取明确的实际 libc，
  验证并发 guard、构造失败重试、跨库异常/RTTI、TLS 析构和旧 guard 负控制。
- `runtime-io` 直接编译生产 IPv6 垫片，使用 ASan/UBSan/LSan 验证独占流、关闭、
  失败释放、并发、fork 和完整接口编号。
- `jni-invocation` 包含生产原生临时根的目录/环境生命周期，以及实际链接 ELF 的
  marker 正反例；`runtime-java` 保留 native-only 与新 C++ 入口的所有权边界。

这些测试不签发自定义 loader 的 TLS/卸载/FDE 资格，也不代替完整四版构建、
HAP 集成、平板和后续设备矩阵。当前阶段与失败更正见
[施工记录](../../docs/refactor/运行时与音频修复施工记录.md)。
