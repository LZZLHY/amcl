# 四代 JDK 的真实 Java 资格夹具

固定`native-file-times`是独立原生观察模式：从已有permission-roots协议验证真实filesDir
和GameStorage外部根，在官方NCP中直接调用系统futimens/utimensat/futimes/utimes及可用的
futimesat；不安装JDK、不写qualification.jar、不创建VM。结果位于
`run-native-file-times/native-file-times.json`，独立完成协议为
`AMCL_NATIVE_FILE_TIMES_RESULT_V1`，父侧沿用有界10秒期限和实际NCP退出监督。
它记录每项错误/属性而不吞错；观察完成不授予Java、文件系统或游戏资格。major仅为旧
入口的有界参数，不代表调用了该JDK。缺根/根错位必须失败，不能回落为沙箱冒充外部对照。

`RuntimeQualification.java` 是 Java 8 API / class 52 的唯一源码，供 JDK 8、17、21、25 共用。
`build-fixture.py` 用明确的 `javac --release 8` 编译，检查每个 class 版本，生成时间固定的 JAR、
带源/JAR 摘要的 `napi/jdk_java_fixture.h` 与外置构建收据。头仅由 `MC_OHOS_BUILD_TESTS` TU 引用。

宿主把完整候选 `runtime.zip` 与严格的 `archive-sha256.txt`（64 个小写 hex 加换行）投放到
`filesDir/jdk-runtime-qualification/<nonce>/`，然后调用
`RunJdkJavaQualificationNapi(filesDir, nonce, major, profile, callback)`。major 只接受 8/17/21/25。
每个 nonce/major 新建 `run-<major>`；已存在即拒绝，不能复用之前的成功证据。

固定 `native-temp` 是上述Java流程的明确例外：仍复用同一NAPI/官方NCP/目录fd与退出所有者，
但新建 `run-native-temp`，不要求或投放runtime.zip、归档摘要、qualification.jar，不安装JDK、不创建VM。
major仅为兼容既有调用参数，不表示实际使用该JDK。nonce仅接受最多32字节的小写字母/数字/连字符。
子入口先校验目录对象与宿主Fresh状态，在任何JAR检查、stdio/cwd准备、字体/权限矩阵或installCandidate前
调用固定OS前置helper并返回。`native-temp-main`阶段及整个native-only父等待各限10秒，超时仍按真实NCP身份Kill并监督退出。
报告只授实际同进程文件/rename/Unix peer/mmap前提，不授双VM Attach、跨进程mmap或CLI能力。
`tests/runtime-native-temp/verify-device.py`单独验收，普通Java verifier明确拒绝此profile。

官方 NativeChildProcess 子入口 `AmclJdkJavaQualificationMain` 在专属根中完成真实
CreateInstallStage / Extract / Seal / Publish，前后完整 ZIP 与 sidecar 不变；writer/use.EX 关闭后，
再由生产 jvmInit 取得 use.SH。它不调用 fork、不清零继承状态，也不覆盖用户现役 JDK 槽。
使用既有独立工具参数模式跳过游戏专用 ClassLoader 和 watchdog；保留生产默认 GC/JIT，
不采用安装器尚在专项验证中的 TieredStopAtLevel=1。额外只启用 JNI 检查和编译日志。

Java 夹具实际检查版本身份、经过 JNI 的中文/emoji 字符串、反射及异常栈、8 个线程的
32768 次 ThreadLocal 操作、Unicode NIO 写入/改名/枚举、60000 次可观察热循环与真实 GC，
以及 Java Font 的中文 glyph、绘图和 ImageIO PNG 逐像素往返。`PrintCompilation` 原始输出
保存在 `stdout.log`，须由宿主额外确认 hotLoop 出现 C2/tier4；总编译时间不能独自证明 C2。
JIT 循环校验和由独立无符号 64 位算法计算为 `678318003988397421`。

main 返回后 native 才创建 `destroy-started.txt`；非daemon随后join执行main的原Java线程，并核isAlive为false，写`main-thread-ended.txt`后才提交worker文件。
shutdown hook 再核对 worker 的文件，随后创建自己的文件。native 检查 jvmCallMain 结果、
真实 DestroyJavaVM 返回，以及 `fixture-pass.txt` / `non-daemon.txt` / `shutdown-hook.txt`
及`main-thread-ended.txt`共四个文件，写 `result.json`。所有资源失败都保留失败阶段；不会把 main 返回视为正常关闭。

父任务的 180 秒 deadline 包含真实解压与 Java 执行；超时或父侧 C++ 异常使用官方
KillChildProcess，并持续持有任务直到 SDK 回报该子 PID 的实际退出事件。API22 之前缺少
该身份约束终止接口时本测试入口明确拒绝运行，不改变普通产品功能。退出回调里的 signal
从来不是 waitpid exit code。设备通过要求同时满足：最终 native 收据 passed=true、实际
退出事件 observed=true、signal=0、timedOut=false，以及宿主回收的 C2/字体/产物证据。

终止入口从静态依赖 `OH_Ability_StartNativeChildProcess` 的真实 `dladdr` 提供者中查找：
只用 `RTLD_NOLOAD` 获取已加载实例，校验 Kill 与 Start 同属一个 DSO，并持有其句柄直到
子进程 owner 与退出回调结束。不能因系统 namespace 中 `RTLD_DEFAULT` 查找不到导出就
误报 API 缺失。提供者缺失、缺少符号、归属错误仍在创建子进程前拒绝，禁止退回裸 PID kill。

`run-host-fixture.py` 在指定宿主 JDK 上执行同一 JAR并校验错误 major 的负例。它用 CLI
进程验证夹具自身，不能代替 OHOS/JNI Destroy 顺序。`run-host.sh` 使用 SDK/NAPI 边界替身
测试真实资格入口的输入、排队、回调失败和 child owner 的异常清理，并运行 ASan/UBSan/LSan。
其中所有 JavaVM 替身均拒绝被调用；不能把这些边界测试当作实际目标 JVM 运行结果。
另有 7 个 provider 查找用例覆盖缺失/错误归属/别名回退；宿主 SDK 边界夹具以独立真实
DSO 导出 Start/Kill，验证已加载句柄的查找与释放，不模拟真实目标进程执行。

本夹具不覆盖完整 CLI、子进程启动、网络、音频、游戏或 GUI 输入，相关专项须独立验收。

固定profile为basic/broad/c2-only/full；默认basic保持已有夹具。CF三臂先执行同一合并JAR中的CompletableFutureQualification，再运行原生命周期夹具，等待真实Destroy及退出后由runtime-jit/cf_evidence.py验证完整XML。8的c2-only在输入层拒绝；full只经TestHooks跳过精确outer-CF规则。现代v2的full/C2-only先追加固定精确Exclude=false，同时解除外部调用者的旧内联排除；仅C2-only消费内嵌cf_c2_only_v2_directives.json，full不再用旧JSON。Want不接受任意路径或VM选项。180秒总期限包含安装和全部执行，不因CF心跳延长。宿主验证器使用相同字节的cf-qualification.jar回收副本；native passed字段并不替代CF编译/内联/性能证据。

扩展profile为extended/extended-fork及sound-software/sound-playback，全部在独立新VM执行，保持生产CF策略。extended调用固定工具/TLS/网络/JFR夹具并记录ProcessBuilder；fork对照只追加固定launchMechanism参数，不宣称childproc已async-signal-safe。音频软件与真实PCM播放分别验收，software完成不能给playback授权。额外module export/open仅在对应TestHooks profile；夹具通过之后仍须原RuntimeQualification的完整worker/hook/Destroy/真实退出证明。

process-java单独执行JavaProcessQualification的真实默认ProcessBuilder数据、环境、退出及有界取消矩阵；不附加launchMechanism或CF选项。宿主须另用runtime-childproc/verify-java-process.py验证每流原始字节、精确错误与回收及完整完成摘要，Native main成功不替代这些证据。测试结束仍运行原Java/Destroy/实际退出夹具。

sound-capture-denied仅观察真实TargetDataLine打开拒绝，绝不start，必须另绑定新鲜系统权限证据；任意LineUnavailable不自动证明拒权原因。sound-capture只在用户明确同意短录音且完成系统授权后由宿主选择，两个格式各200ms，夹具仅保留计数/峰值/RMS、不保存原始PCM。两种模式独立完成标记，零设备或未加载后端仍失败，完整VM/实际退出要求不变。

正向Capture从Native capture-main阶段单独计10秒预算，父侧超时发官方Kill请求并等实际退出；重复阶段标记不延长预算。安装/普通Java仍沿原180秒预算，完成Capture后解除短预算。系统终止请求失败仍明确保留并重试，不能把10秒请求时点写成精确的物理设备关闭时刻。

sound-timing在候选JDK加载前通过正常系统libohaudio执行固定两段250ms低幅度PCM，观察FramesWritten、两个呈现时钟、Pause/Flush/Start、数据回调与真实API返回值。它只消费固定代码与PCM，不接受外部路径或参数；独占audio-timing-report.json并由Native阶段流绑定完整摘要。OBSERVED只表示观测完成，Native整体成功仍需原Java生命周期，任何此类成功都不授予JavaSound播放资格。

sound-capture-diagnostic使用与正向Capture相同的用户明确授权和10秒阶段期限，仅在TestHooks且显式一次arm时选用正常HAP内的typed统计回调。每格式仍只读取200ms，诊断逻辑缓冲为400ms；不改变FAST、共享POD或生产回调热路径，也不保存原始PCM。Java记录实际hardwareFormat/conversionSize/缓冲和帧位置，回调仅统计最前3200/9600帧的峰值、能量及边界计数。main返回且line关闭后独占写capture-diagnostic-report.json，Native阶段流绑定正文SHA。只有已静止、两次固定表、无错误且总接收未超容量时才可比较同一前缀；OBSERVED及峰值/RMS相等都不能证明逐样本相等或物理信号保真。每批结束恢复录音前权限状态。

sound-capture-native在加载候选VM之前，经正常HAP与真实libohaudio逐次创建相同48kHz/S16LE/mono/MIC/RAW的NORMAL/FAST流，各仅统计首9600帧；前一流Stop/Release完成后才进入下一流。回读实际格式/source/LatencyMode/FastStatus、回调帧大小/overflow及Stop后FramesRead，只有真实形成NORMAL→FAST才报告modeContrastObserved。S16BE/F32仅为同一前缀的解释负控，只存数量/峰值/RMS，无原始样本；signalQualified始终false。固定capture-native-report.json按完整SHA写入阶段流，所有API/期限/回调/关闭失败先保留FAILED再抛异常。内部与父进程同为10秒预算，仍需明确授权并批后恢复权限；该profile不能被用作更长录音或外部参数通道。

sound-capture-layout复用同一生命周期，两臂固定FAST/48kHz/S16LE/mono/MIC/RAW，首臂调用SetChannelLayout(CH_LAYOUT_MONO)，次臂保留builder默认值；各统计首9600帧，另按5×1920帧保存连续40ms窗口，首窗不得省略。固定capture-layout-report.json使用AMCL_CAPTURE_LAYOUT_V1，阶段流绑定正文SHA；实际两臂FAST才置bothFastObserved。SDK没有Capturer的layout getter，所以requestedChannelLayout与layoutSetterCalled只表示请求/真实调用，不能替代平台converter的有效布局。仍需每格式200ms范围内明确授权、10秒阶段预算及批后权限恢复，不改变生产流策略或授予信号质量资格。

sound-capture-startup是必须单独获得一次一秒录音同意的固定观察：单流FAST/48kHz/S16LE/mono/MIC/RAW，
保留builder默认layout，只统计首48000帧及25×1920帧连续窗口，包含最初样本，不预录/不丢帧、不存原始PCM。
原native/layout两个200ms入口的9600帧合同不变。startup仍在加载VM前进入原capture-main/capture-main-return阶段，
父进程10秒预算始终生效；固定capture-startup-report.json使用AMCL_CAPTURE_STARTUP_V1，capture-startup-observed绑定完整正文SHA。
普通Java verifier对该profile显式调用tests/java-sound/verify-capture-startup.py，核单流、全窗口、实际FAST、API/关闭/静止回调、
预算与VM前阶段顺序。OBSERVED和后段低RMS均不代表信号质量；验收器没有主观音量阈值，也不推断直流或根因。
该profile完成后仍执行既有Java生命周期夹具；这一事实与原生录音观察分别记录，批后权限恢复由设备任务所有者完成。

sound-capture-channels是另行取得一次明确授权的通道对照，不能复用startup一秒授权。沿同一Native生命周期，
固定stereo-first/mono-second两条48kHz/S16LE/MIC/RAW/FAST流、默认layout，各仅统计首9600帧和5×1920帧窗口。
prepared/started/stopped实际getter必须分别为2/1通道且FAST，streamId在每臂内稳定、两臂不同，状态正确且无overflow；
不满足只是对照前提失败，不能将创建失败或回落当作mono幅度异常的根因。每通道与逐帧double算术平均只输出count/peak/RMS，
不丢首帧、不预录、不保存/播放PCM；平均不是生产转换输出，signalQualified始终false。callback必须整帧对齐，末callback超出前缀部分不计入，
Stop/Release后静止再读统计。固定capture-channels-report.json为AMCL_CAPTURE_CHANNELS_V1，capture-channels-observed绑定正文SHA，
普通Java verifier精确分派到tests/java-sound/verify-capture-channels.py，核两流/窗口/前缀/关闭/真实getter与VM前阶段。
该模式仍进入capture-main的父10秒预算、之后保留原Java/main.join/Destroy/实际退出；不得用普通180秒总预算代替录音期限。
本机runner要求新的固定channels授权文件及显式完整SHA，绑定实际HAP/设备和两个200ms合同；文件缺失、身份不符或一次claim已存在均拒绝start。
该授权文件只能在本次用户明确同意后记录，不用测试合成授权替代。批后恢复DENIED由设备任务所有者完成；已有native/layout/startup范围保持。

时钟报告schema2的第一段保留用户数据耗尽后返回0；第二段至多再真实提交250ms静音，分别记录user/silence/总返回字节，用户read不会因静音增长。此固定因果对照用于区分呈现时钟停顿与回调未消费，不把FramesWritten、墙钟或静音长度直接视为用户已呈现帧。暂停/清空后的实际坐标仍原样记录。

native-sound-devices先核Platform原生加载与MIDI/Ports门，再以标准ServiceLoader调用两个真实MIDI Provider的getDeviceInfo；不打开MIDI端口、不发送事件。Ports仅使用已核实只读设备快照的PortMixer执行typed port open/query/close并要求无伪造Control，零Ports明确失败。Native要求精确AMCL_NATIVE_SOUND_DEVICES_V1完成记录、正Port数量与独占JSONL全文SHA；独立verify-native-devices.py再验证事件顺序、关闭配对和本轮原生MIDI成功Create日志。零MIDI端点只记录当前枚举，midiIoQualified始终false；没有Capture/PCM请求。专项之后仍须原Java/main.join/Destroy/实际退出资格。
# 手机共享工具资格

手机的 NativeChildProcess 函数存在官方设备类型限制，不能把创建子进程失败当作 JDK 失败。
default TestHooks 提供固定 `shared-basic`、`shared-extended` 两项，经原 `jdkJava` 注册表和
NAPI async worker 复用同一候选安装、JAR、`jvmInit`、Java main 和 `jvmFinishProcessor`。
结果明确标为 `shared-tool`，没有 NCP 启动/退出事件，也不授予正常游戏或跨 VM 工具资格。

每次必须是无游戏、无 VM 的冷启动应用。受理后即封住普通 JVM/游戏入口，成功、失败或
排队失败都不解除，下一代必须重启应用。共享流程保存并恢复 stdout/stderr，不改 CWD，
不运行会清空全进程环境的独立字体上下文观察。扩展 Java、字体和正常生命周期仍执行；
不包含麦克风或任意 profile、参数和 URL。

宿主必须实施 200 秒上限，记录冷启动 PID/进程身份，在取得完整结果后结束该测试进程。
`verify-device.py` 对 shared 独立检查主进程身份、Fresh→退休、main/worker/hook 四个标记、
完整扩展结果、stdio 恢复，以及 `supervisor.json` 绑定的四次实际 PID 读回。外部 force-stop
只证明最终进程回收，不能替代正常 Destroy，也不记作 NCP 或 OS 的成功退出码。
