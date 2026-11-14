# OHOS JavaSound MIDI 的实现与独立资格

本模块实现四代 OpenJDK 原生 MIDI 输入/输出，沿用上游 `MidiInDevice`、
`MidiOutDevice`、Provider、Receiver/Transmitter 与软件 MIDI 外观。0026 只替换
OHOS 的 native 适配单元，其它平台继续使用原后端。它不建立新的 JavaSound 层，
也不增加常驻 broker 线程。

`entry/src/main/cpp/javasound/midi_*.c/.h` 是自有事实源。`make-patches.py` 从
`reference/source.json` 锁定的四代原文重放 0001–0025，再生成
`0026-ohos-javasound-native-midi.patch`。JDK 只消费 API、core、stream、UMP、JNI
及共享回调头；`midi_callbacks.c` 仅进入正常签名加载的 HAP。

## 平台与身份合同

- 产品最低 API 保持 20；OH_MIDI provider 从 API24 起可选，通过固定库名
  `libohmidi.so` 和 `midi_api.h` 的 14 个精确 SDK 符号动态解析。没有静态
  `DT_NEEDED libohmidi` 或直接 `OH_MIDI*` 导入。
- provider 缺失时，两个原生 Provider 返回零可见设备并输出不可用原因。库已存在
  但符号缺失、SDK 创建失败、枚举失败等保持真实错误，不冒充“无设备”。
- 一个惰性 client 管理多个真实 device/port。同设备输入和输出共享一次
  `OpenDevice`；端口编号和方向来自 SDK，不假定连续，也不写死为 0/1。
- Java 数组位置与不可复用 native token 分离。快照在一次 JNI 调用内返回完整
  UTF-16 名称与身份；同数量替换也能撤销旧 Info。多个 Provider 实例用同一个
  类锁维护上游静态缓存，不把同名字符串或重排后的下标当设备身份。
- BLE 只使用系统已经连接、当前应用有权枚举的设备。公开服务会在没有
  `ACCESS_BLUETOOTH` 时过滤 BLE；数量为零不能推断所有硬件不存在。客户端设置页
  提供显式授权入口，不在启动或枚举时申请，不增加 MAC 扫描/配对 API。

## 数据、线程与释放

系统始终传输 UMP，即使端口选择 MIDI1 协议也不能直接发送原始字节数组。
JavaSound MIDI1 使用 MT1 系统消息、MT2 通道消息及 MT3 SysEx7。输出 group 采用
SDK 自身 `MidiOutputPort::SendSysEx` 的 `portIndex & 0x0f` 规则；真实多端口外设
仍须单独验证。时间戳按设备打开时的 `CLOCK_MONOTONIC` 原点转换，保留完整
`jlong` 微秒；负值为立即发送，未知输入时间保持 -1。

长 SysEx 不受上游旧 1024 字节缓冲限制。转换保留 Java 的 F0/F7 分段、逃逸字节流、
running status 与实时消息；Start/Continue 合法携带 0–6 字节，因此调用边界和
实时消息之前可提交已有数据，不移动原时间。每批最多 64 个事件，严格按 SDK
`written` 前进，`WOULD_BLOCK` 只重试未接受部分，并检查关闭及单调时钟期限。
输入在既有 Java MIDI 线程重组成有界的合法 SysEx/continuation 块，保持全部字节。

嵌入 JDK 的三个系统回调只来自正常加载的签名 HAP：
`amcl_javasound_midi_callbacks_v1`，ABI/layout 均为 1。工厂、只读表与三个函数
必须和宿主标记位于同一映像，并持有实际 NOLOAD 引用。回调仅写原子状态、复制
暂借 UMP 到预分配队列并 `sem_post`，不调用 JDK 函数、JNI 或用户 Receiver。
独立 CLI 使用正常系统加载映像中的同源函数；不修改 CFI shadow 或关闭 CFI。

JNI 输入调用持有真实端口对象和实际 JNI 映像引用，生命周期覆盖用户 Receiver
回调。close 撤回新的获取后，旧持有者可安全返回；Java 的一秒 join 超时不等于
可以 free。每个 OHOS 输入线程绑定本次 handle，旧线程不能消费重新打开的新
handle。用户异常原样传播并关闭本次设备，所有 JNI 查找/数组/回调均立即验错。
用户代码本身无限阻塞时，不能宣称其 Java 线程已结束。

数据队列满或格式不合法会显式报错，不覆盖未读消息。热插拔通知环溢出时，快照
token 和在用端口的身份都不能继续信任；两个方向返回 `AMCL_MIDI_CHANGED`，
由关闭、重新枚举及打开恢复。服务死亡先向 Java 报告真实错误，旧端口及在途
持有者结束后，下一次枚举可在成功 Destroy 后重新 Create，并分配新 token。
SDK 错误返回可能已经消费 raw handle，禁止重试旧指针；无法证明静止时保留
数据/映像租约，不用假释放换取“零泄漏”。

## 可复现验证

标准工具链镜像包含四代 boot JVM，仍复用固定 `amcl/qa` 服务：

```powershell
python -B docker/project.py test --state-dir <既有状态目录> --suite runtime-midi
```

独立宿主 C 验证可显式给固定 SDK 声明和仓外输出：

```text
python3 -B tests/java-midi/run-host.py --sdk-headers tests/java-midi/reference/sdk --out <仓外新目录>
```

覆盖内容包括：外部标准 UMP 向量、全部通道/系统短消息、3000 字节 SysEx、
完整 64 位时间、真实 DSO typed 回调归属、4000 个并发复制包、队列溢出、
瞬时数据覆盖、迟到回调、真实 SDK 签名负控；控制核心包括不连续端口、USB/BLE
身份、共享 device、计数竞态、部分 Send、取消、在途 JNI 持有、同数量热插拔、
通知溢出、服务重建与已消费句柄的 Destroy 失败。正常路径开启 ASan/UBSan/LSan；
故意保留所有权的失败路径在独立子进程检查，范围单列。

`run-jni-host.py` 使用四代完整上游候选 Java 类和生产 JNI，并用明确的
`RegisterNatives` 与独立有状态 SDK 测试库绑定。每代分别执行正常、签名宿主
typed、旧零设备负控、错布局、外来回调、缺 provider、缺 Send 符号七个独立 VM。
JNI Invocation 启动器逐步验错，`-Xcheck:jni` 全程开启，保持正常 JIT 优化。

`make-patches.py --out <仓外新目录>` 生成、重放并逐字节比较草稿；只有显式传
`--write-patches` 才写正式补丁文件，它不修改 series。JDK8 两份显式 mapfile
另补新 JNI 导出，主库还包含生命周期及只读身份导出；不能只看 `JNIEXPORT`。

## 交付门与资格边界

实际 `libjsound` 必须含只读 `.amcl.midi` 标记
`AMCL_MIDI_OHOS_API24_OPTIONAL_V1`，14 个动态 API 名字必须位于只读 PT_LOAD，
必需 JNI/lifecycle 函数必须为非零且实际 PF_X 映射内的 FUNC/IFUNC 定义，
身份对象必须可解析。`docker/scripts/midi_runtime_gate.py` 与发布仓独立
`tools/runtime-midi.mjs` 分别核实际 SDK provider 和精确能力合同：

- capability：`ohmidi-api24-optional-midi1`。
- backend：`ohos-midi1-ump-v1`；minimumApi 20，providerMinimumApi 24。
- binding：`optional-dlopen`；embeddedCallbacks：`signed-host-midi-abi-v1-required`。
- qualification：`implemented-requires-device-test`；SDK SHA 绑定本次编译声明/供应者，
  不冒充商业设备系统库的 SHA。

宿主、SDK 链接和二进制正负控没有授予目标外设资格。完整四代 JDK 构建、HAP
实际 provider/枚举、API20 缺 provider 设备，以及 USB/BLE 的硬件收发、未来时间、
长 SysEx、热插拔与关闭重开仍按相应原件验收。没有外设时只报告真实可见设备
和 SDK 调用结果；软件 Synthesizer/Sequencer 不是原生端口传输证据。

本轮原始证据放在工作区 `run/jdk-finish/java-midi/`，总冻结清单关联各阶段输出；
旧失败、旧源码与更正分别保留，不重写历史收据。
