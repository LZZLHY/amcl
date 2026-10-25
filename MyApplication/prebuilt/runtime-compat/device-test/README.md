# Create 线程修复的隔离真机 QA

本目录是 test-only Fabric 模组源码，与正式 `src/`、`resources/` 分离。正式兼容 JAR
和 HAP 不得包含 `com/amcl/compat/probe`、`amcl_create_thread_probe` 或启用配置。
没有启用配置时不会运行；配置还必须匹配独立 `*-create-thread-qa` gameDir 和
`AMCL Create Thread QA` 开头的新建单人世界。

在相关完整实现和全部已报告代码问题复审关闭后，先核对正常产品构建与实际HAP，
再执行部署/游玩步骤。下面构建配方从仓库根运行；占位值必须换成当前环境的真实
绝对路径。输入缓存和QA输出均在仓外，本工作区按当前存储路由选择位置；独立
克隆/CI使用自己的仓外目录，不依赖维护者的AMCL根目录。

```powershell
# 仅把专用JDK交给兼容层，不修改全局JAVA_HOME。
$env:AMCL_COMPAT_JAVA_HOME = '<JDK25或更新版本的绝对路径>'
$compatInputs = '<仓外锁定输入缓存绝对路径>'
$compatProbeOutput = '<尚不存在的仓外本轮QA输出绝对路径>'

# 下载只在显式准备步骤发生；构建使用同一缓存逐文件核验，不隐式下载。
python -B scripts/prepare-game-compat-inputs.py --download --include-tests --output $compatInputs
python -B scripts/build-create-thread-device-probe.py --inputs $compatInputs --output $compatProbeOutput
```

已准备且摘要一致的缓存可复用；后续命令也可通过`AMCL_GAME_COMPAT_INPUTS`指定
同一缓存。显式`--output`必须不存在，脚本拒绝覆盖；省略它时，会在仓外任务
父目录下为每次调用原子分配全新会话，旧classes和证据不删除、不复用。编译器
要求JDK25+，输出为Java21 class65；游戏、Create和Mixin原包仅作编译输入。
输出包括test-only JAR、独立启用配置及build-receipt.json。构建脚本不安装、
不操作设备、不写正式rawfile/HAP，也不触发应用构建。

本轮已有代码/host/default HAP和两次隔离真机受控探针证据，边界见[当前契约](../../../docs/guides/game-runtime-compatibility.md)与[专门方案§8](../../../docs/adaptation/CREATE_FLY_CLIENT_PACKET_THREADING_PLAN.md#8-实施分期与验收门)。两轮各为8批、1098次deferred、512/64次Hold、60个post tick，并在真实Knot定义47目标后取得临时对象清理/worker停止/JSONL提交的限定成功。真实设施、车厢连接件、正常保存退出/重进与后台恢复尚未通过；首轮成功后转后台发生系统PSS SIGKILL，不能把重新进入的新进程计为后台恢复。已有HAP对应其隔离基线与任务冻结输入，不能代替后来D整个HEAD的构建验证。

部署/游玩配方由负责人在正式产品构建和产物核验通过后执行：

1. 保留原版本、mods、options、存档和摘要，新建
   `fabric-loader-0.19.5-26.2-create-thread-qa` 实例。保留 MC26.2、Fabric0.19.5、
   官方旧 Create（SHA256 以 `threading-inputs.json` 为准）和必要 Fabric API；
   QA JAR 只加入这个新实例的 mods。
2. 把脚本外置输出的 `amcl-create-thread-probe.json` 放进该实例
   `config/amcl-create-thread-probe.json`。如产品实际 gameDir 末段不同，必须先
   核验隔离事实，再在配置中写真实 QA 名称（仍须以 `-create-thread-qa` 结尾）。
3. 通过 AMCL 正常 UI 选择这个 QA 实例、JDK25 和当前受测渲染器，核对启动日志
   `gameDir`，新建名称以 `AMCL Create Thread QA` 开头的世界后进入。
4. 保持游戏前台且正常游玩至少 30 秒；从 QA gameDir 回收
   `logs/amcl-create-thread-probe.jsonl`、`latest.log`、MC/Native/宿主输出，并保留
   所安装 HAP、兼容 JAR、QA JAR 和旧模组的字节身份。应有同一 runId 的
   `start`、`preflight_passed`、47 个 `knot_target_defined`、一个
   `knot_definition_gate`、8 个 `client_batch_submitted`、`server_done` 和唯一 `result`。
5. `result.passed=true`、`actualKnot=true`、`clientHolds=512`、`serverHolds=64`、`deferred=1098`
   （安全预检 1 + 客户端每批 129 × 8 + 服务器 65）、`postTicks>=60`、
   `workerStopped=true`、`evidence=jsonl_committed`、`trainAbsent=true`，且全程
   没有 `failure` 事件，才代表这组受控驱动通过。随后继续实际游玩、保存并正常
   返回主菜单；再次进入该 QA 世界核验可读性。任何 force-stop 都不能替代正常退出。

驱动通过实际加载的 AddTrain/RemoveTrain/S2CHold/C2SHold typed handle 和原生
bundle，使用真实 listener 和当前客户端/集成服务器 PacketProcessor。它覆盖
同线程直通、异线程停止原路径、同一个 Hold 连续投递、不去重、列车表添加/删除
顺序、原表迭代、原生包队列先于普通客户端任务、bundle 子包连续处理和完成后
清理。每批有界等待 worker 最多 1 秒，只用于确定队列尚未 drain 的观察点；不
用假的队列/线程替代游戏，也不自行调用 `processQueuedPackets()`。

列车测试前先用无业务副作用的真实 Hold 做异线程预检；兼容未生效会在此失败，
尚未放入测试 Train。预检后，从正式兼容 JAR 的 `CreateFlyThreadingProfile`
反射读取 targets/descriptor/id，不复制目标名单，也不把该 JAR 加为编译依赖。
47 个目标经真实 probe/Knot loader 以 `Class.forName(name,false,loader)` 定义，
并解析 typed handle、bridge、合并后的注入 handler，核对 loader 与 Create
CodeSource，逐项记录。此门只证明真实 Knot 组合下定义/链接成功，不代表 47 个
业务都已执行。

空车厢 Train 只在同一次 tick 或原生队列 drain 内短暂存在客户端临时表，返回
渲染阶段前清理（上游渲染器不能接收零车厢对象）。读取的是
`com.zurrtum.create.client.Create.RAILWAYS`，不会混用服务器同名管理器。不建
轨道/实体、不进入服务器铁路存档，也不修改玩家物品。除 tick/drain 的 finally
外，`renderFrame(Z)V` HEAD 还按本测试 UUID + 对象身份清理并把逃逸判失败，
覆盖 drain 后零次 tick 直接渲染的帧。每次投递前重检取消/interrupt；worker
finally 发布停止握手并把清理交回真实客户端。超时/异常/连接切换会取消，实际
worker 线程停止且清理后才发布终态；它未停止时不会先宣布测试结束。
为了避免异常扩大，回调中的断言记录失败，不向原生队列抛 `AssertionError`。

普通事件先写 JSONL，再镜像 stdout。最终 result 通过同目录私有 pending 文件
与 `ATOMIC_MOVE` 原子替换完整 JSONL，提交成功后才向 stdout 发布成功。文件
提交失败则唯一终态为 `passed=false`，并以 `evidence=stdout_only` 标识可用
通道，不输出成功后再悄悄设置失败状态；不支持原子移动也按失败处理。

这不能替代宿主的全部目标字节码覆盖、未知/新版本退场、关闭/拒绝/断线分支测试，
也不能冒充经网络编解码传输的完整服务器复现。没有真实车厢 mesh 和铁路设施的
受控测试不能证明列车渲染全部功能；另需类似 Create 世界的前台游玩证据。本模组
不为配置/PLAY 切换、真实服务器、多人传输、世界恢复或长时间稳定性作扩大结论。
