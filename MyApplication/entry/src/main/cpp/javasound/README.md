# JavaSound 的 OHOS DAUDIO 后端

本目录是 AMCL 自有平台适配源码，平台控制层编入四代 JDK 的 `libjsound`，同源的
数据回调另由正常签名的 HAP 宿主编译。PCM Playback 和 Capture 已有实现，设备播放、
用户授权后的真实录音、原生 MIDI 与 Ports 仍按各自证据验收，软件或宿主 mock 不授予设备资格。

## 文件与构建边界

| 文件 | 职责 |
| --- | --- |
| `ohos_daudio.c` | 实现四代完全相同的 18 个 DAUDIO 平台入口，使用官方 OHAudio C API |
| `ohos_daudio.h` | 只包含 OHOS 诊断状态入口，供原有 JNI 包装报告真实失败 |
| `ohos_daudio_callbacks.h` | 版本化 C POD、六个 SDK 强类型回调和表校验，JDK 与 HAP 同源 |
| `ohos_daudio_callbacks.c` | HAP 正常系统加载映像中的公开 getter，回调不转调自加载代码 |
| `ohos_capture_ring.h` | 无锁完整帧捕获覆盖环，溢出丢弃最旧数据，支持并行读取验证 |
| `ohos_playback_timeline.h` | 将实际系统帧映射回用户PCM区间，静音空隙不增加用户帧 |
| `tests/java-sound/JavaSoundQualification.java` | 原 JDK Java API 的软件资格与实际播放资格，两个结果分开 |
| `tests/java-sound/JavaSoundCaptureQualification.java` | 固定拒权或短录音入口，原始 PCM 不落盘、不回放 |
| `tests/java-sound/prepare-daudio-duplex-patches.py` | 在不可变 0023 上生成 0025 增量，保留每代原 Java/JNI 差异 |
| `tests/java-sound/prepare-daudio-timeline-patches.py` | 在不可变 0025 上生成 0028，修呈现时钟和宿主 ABI2 |

保留上游 DirectAudioDevice、DirectAudioDeviceProvider、JNI 格式转换、Clip 线程、
软件音量和 Java 阻塞写入循环。现代 JDK 原 0011 的通用 Linux 禁用标志需要在新补丁
中限定为 OHOS 选择；JDK8 恢复 DAUDIO feature 位并编译同一后端。四代 series 的
`0023-ohos-javasound-daudio-playback.patch` 保留已验证的历史实现，后续双向及宿主回调
由 `0025-ohos-javasound-duplex-host-callbacks.patch` 承接。共享源码的 hash 必须与生成
补丁和实际编译输入一致，更新后重新重放完整 series；不得手工维护四份独立实现。

## 系统回调与 CFI 边界

API26 设备已证实：自加载 `libjsound` 的 `render_data` 地址在 OHAudio 第一次调用时
被系统跨 DSO CFI 拒绝。0025 引入宿主数据边界，当前 0028 要求同一正常宿主映像导出
`amcl_javasound_callbacks_v2`，核对表版本、布局版本、line/context/capture-ring/timeline
数据结构大小及对齐；getter、
只读表和六个回调必须属于真实嵌入 marker 所在的宿主映像，并取得 `RTLD_NOLOAD` 引用。
缺失、错版或来自其他映像都在 Generate 前拒绝，不回退到已知失败地址。

六个系统入口完整执行宿主中的有界复制和原子状态更新，只访问共享 POD。没有从宿主
回调到自加载函数的泛型跳板，没有关闭 CFI、改写 shadow 或新增全局 broker/工作线程。
独立 CLI 仍使用由正常系统链接器登记的本库同源回调。关闭遵循同一 owner/active 合同，
正常释放宿主及 JNI 映像引用；Release 失败则保留两份真实代码租约。宿主资格只能证明
布局/选择/数据与寿命，系统 CFI 的最终通过以目标实际播放为准。

## 播放合同

* 路由查询有真实输出或输入设备后才枚举一个系统音频逻辑 mixer。系统负责扬声器、
  耳机与蓝牙的当前路由；这不是伪造硬件设备列表。打开仍逐项检查配置返回值和生成流
  的真实采样率、声道、格式、编码及回调帧数，资源不足按原 LineUnavailableException
  路径返回失败。
* 四个设备描述字段只使用自有 ASCII 常量，不把平台设备名当作 modified UTF-8 传入
  上游 `NewStringUTF`。当前未调用平台 `GetDeviceName`；今后显示真实 UTF-8 名称时须
  转成 UTF-16 后调用 `NewString`，含非 BMP 字符的名称不能直接透传。
* native 格式是 U8、S16LE、S24LE、S32LE，保留上游已有的 8 位符号及多字节端序转换。
  采样率/声道候选由 OHAudio builder 校验；不能静默修改调用者请求的音频格式。
  单帧字节数始终为完整声道数乘每样本字节数，溢出、半帧、负长度必须拒绝。
* 单条 Java line 的原 `lockNative` 串行化控制和写入；音频回调只访问自己的 SPSC
  环形队列与原子字段，不调用 JNI、分配、日志、停止/释放接口。API20 advanced
  callback 返回实际完整帧的字节数。仅在还有未确认呈现的用户数据时补实际静音，
  用户数据和静音分别计数；未启动、暂停、已确认完成或失败时返回 0。
* `write` 允许部分写与 0 字节，让上游 Java 循环保留原阻塞/停止语义。用户 `stop`
  对应平台 Pause，保留尚未播放的数据；`flush` 阻止新回调读取、等待在途复制结束后
  丢弃软件及平台队列，再按原运行意图恢复。不能将 flush 等同于 close/reopen。
* `drain` 和位置同时计算软件待提交和系统待呈现的用户帧。0028 使用 API15 的
  `GetAudioTimestampInfo`，以稀疏用户区间将系统帧映射回用户帧；连续数据合并成一段，
  空隙之后的新数据只有在真实呈现位置跨入其区间后才增长。关闭区间队列有界，满时
  保留用户PCM并背压，不能覆盖历史。仅依据真实位置及用户数据，不从墙钟推算。
  真机已证实 Flush 后呈现坐标归零而 FramesWritten 累计不清零，因此 Flush 在静止
  窗口清空本epoch。暂停只返回已确认位置，不调用只允许运行状态的时间戳接口。
  不明运行中回退保留已确认下界，不猜路由epoch并自动加offset；路由重置/中断的
  完整目标资格仍须实测，不能由本轮同一路由的尾部对照外推。
* 中断回调仅记录事件；原 Java line monitor 和正常 native 调用在控制侧处理暂停与
  恢复。用户已停止时不能由迟到恢复事件自动播放。永久错误保留原 OHAudio code，
  后续数据访问返回失败，不能无限吞错等待。`start/stop/flush` 的 JNI 返回值传播
  保持 Java 状态提交顺序；`close` 先完成 native wrapper 与 Java 所有权清理，再报告
  Release 失败。同次 stop 首错保留，后续清理错误按标准 `suppressed` 附加。
* 回调注册之前取得所在 libjsound 的额外代码引用，并以真实 JNI 出口地址核同映像。
  关闭先撤销 owner，Release 成功且在途回调退出后才释放回调上下文和代码引用。
  Release 失败仍保留该最小 detached 上下文与代码引用，释放已无回调可访问的环形
  缓冲；若回调尚未退出，则连同其可能访问的 line/ring 保留，不能伪称已释放。
  诊断在控制线程输出原始错误。

V1 旧产物继续记录 `playback-only-requires-device-test` 和 Capture 未实现。0025 的 V2
产物须具有明确只读 ELF 标记、真实 `libohaudio.so` 依赖以及播放/捕获必需强符号和 SDK
供应者，才记录 `duplex-requires-permission-and-device-test`；录音单项仍明确需要权限及
设备验证。0028 的 V3 另要求精确标记和 `GetAudioTimestampInfo` 强导入，宿主合同是
`signed-host-data-abi-v2-required`；V1/V2 的历史门和记录不改。新工具不能把旧 image
追认为新后端；MIDI/Ports 不随此项升级。

实际 API26 因果对照中，旧0返回路线在用户11025帧全部提交后，旧/新时间戳分别停在
5513/4631；单换API没有解决。第二段实际再提交11025帧静音后，两者达到16538/15656，
真实越过用户结束，同时用户计数保持11025。0028仍需完整新JDK目标播放通过，不能把
该原生探针对照或宿主成功当成最终Java播放资格。固定旧实验输入仅保留在TestHooks的
`daudio_zero_return_reference.h`，没有维护第二套可选产品回调算法。

## 捕获合同

输入由真实首选麦克风路由和独立 Capturer 创建，OHAudio 的实际权限结果始终有效，
设置页显示的权限状态不代替平台授权检查。仅调用公开 API20 及以前接口。读取保留原
TargetDataLine 的阻塞、停止、格式转换语义；JNI 只转换实际读取的字节数，空读和未写入
数组尾部不变，释放 Java 数组后再传播首个平台错误。

环形队列遵守 TargetDataLine 的溢出规则，丢弃最旧、保留最新完整帧。额外物理存储为
一个回调窗口，消费者使用一次分配的回调大小暂存块；原子字块及写入前预留/写入后发布
保证检测到覆盖时不把半写样本提交给 Java。24-bit 等非二次幂帧按完整帧与 8 字节的
最小公倍数对齐，报告真实缓冲容量。回调无分配、锁、等待、日志或 JNI；位置仅按实际
回调帧增长，暂停/flush 不伪造数据。SHARE MUTE 停止交付，不用补零冒充麦克风样本。

宿主资格覆盖十种帧大小、一百万并发完整帧、精确覆写交错、超大回调、部分/空读、
端序转换、拒权、打开/启动/暂停/flush/读错/释放失败及关闭回滚。成本测量使用生产
push/read，并报告当前宿主耗时与分配量；它不替代目标实时回调时延与物理信号验收。

## 分层验证与首个目标入口

宿主测试编译实际 `ohos_daudio.c` 与 SDK 的 OHAudio 声明；注入真实函数接口的
成功、格式回读不匹配、各步骤失败、部分帧、并发写/回调、暂停、flush、延迟呈现、
中断、迟到回调、Release 失败及重复关闭场景。测试替身只证明本模块协议，不能证明
设备播放。目标编译使用真实 SDK clang、未改写的 sysroot、API20 可用性告警作为错误。

目标使用同一 JDK 的 `JavaSoundQualification`，参数为
`[runPath, major, "playback"]`；17/21/25 追加
`--add-opens=java.desktop/com.sun.media.sound=ALL-UNNAMED`。固定低幅度 PCM 分别为
44.1 kHz/16 bit/双声道和 48 kHz/16 bit/单声道，每段 250 ms，要求打开/完整写入/
drain/位置前进/停止/flush/close/重开，并保存原始异常、阶段和完成 token。
Java 的数据消费结果与物理听感分开。该类已接入实际 JAR；0028 仍需完整重建对应 JDK，
在应用真实 NCP/Java 资格入口运行；旧 software token 不可当作 Playback PASS。

## 录音、MIDI 和 Ports

Capture 固定入口为 `JavaSoundCaptureQualification [runPath, major, denied|capture]`，
现代 JDK 使用相同 add-opens。`denied` 仅尝试打开，不启动采集，失败原因须与宿主当前
权限证据绑定；缺少 TargetDataLine 是验收失败，不能当作拒权通过。`capture` 仅在用户
明确同意短录音并完成 OS 授权后执行，16/48 kHz 单声道各 200 ms，仅输出帧数和幅度统计，
不保存 PCM。安静或全零信号单列，不冒充物理输入证明。设备上当前仍为 DENIED，未录音。

OH_MIDI 原生接口始于 API24，使用 UMP。API20 不能直接链接这些符号；真实外部 MIDI
需运行时能力选择、设备枚举、MIDI1 数据转换与连接生命周期，不能以已有软件 Sequencer
完成代替。Ports 涉及实际设备/音量控制，需继续核对公开 API 与每种控件的语义；没有
公开等价能力的项应明确列为平台边界，不能伪造 mixer 或控制值。

官方依据：SDK `ohaudio/native_audiorenderer.h`、`native_audiostreambuilder.h`、
`native_audio_routing_manager.h`；[renderer API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/capi-native-audiorenderer-h)、
[MIDI API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/capi-native-midi-h)。
