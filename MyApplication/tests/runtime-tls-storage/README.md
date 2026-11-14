# 自加载 TLS 纯存储验证

本套件直接编译 `entry/src/main/cpp/jvm/tls_thread_storage.h`。它尚未接入 `elf_loader`、
TLSDESC 或宿主 `__cxa_thread_atexit_impl` trampoline；不是完整产品 TLS 资格。

`Coordinator` 必须由常驻系统 DSO 拥有，初始化由启动线程独占，寿命覆盖全部 Module、
Block、回调和观察者。`CreateModule` 复制初始化模板；创建者最终调用一次 `Retire`，
descriptor/callback 的额外外部引用用 `Retain/Release` 配对。这些引用不替代代码、
依赖或 EH pin。即使 Module 已 retired，仍合法持有外部引用的回调可取得存储。
创建者必须覆盖模块 fini 和全部合法入口，不能把一次公共 dlclose 当成 creator 的结束。
每次 API 调用及其地址的合法使用都必须有外部引用保护；Block 内部引用仅维持查找节点
指向的元数据，不能把已关闭的模块重新激活。`CreateModule` 应在 `.tdata` 重定位完成后
复制最终模板，以免固化重定位前的数据。最后外部引用关闭后，旧地址不再具有访问合同。

`GetBlock` 用16字节 `AddressResult` 返回稳定地址和错误，不再为普通取址复制准备ticket；
失败返回明确 error 和空地址，运行期由 caller 选择非返回失败。
`PrepareBlock` 仅在本次新建块时给出回滚 ticket；同线程、同 arena、同 module 与同次
block generation 且未被普通 GetBlock 发布时才能回滚。不能在用户构造/回调可能使用
地址后执行准备回滚。回滚后的空 arena 保留其线程身份，仅释放块和空哈希表。

权威线程指针为隐藏、零初始化、无构造/析构的系统 `thread_local` POD，注册前置
Constructing 标记防止分配重入把同一线程误识别为新 birth。最近模块缓存与线程内哈希表
使已有块的热命中不分配、不查询系统线程、不取 registry 锁。
目标编译必须明确使用原生ELF TLS并检查产物：OHOS clang默认emulated TLS会发出
`__emutls_get_address`，其pthread key清理不满足上述槽的寿命依据。SDK语法通过不能
替代该项；根集成须使用 `-fno-emulated-tls` 并验证真实目标TLS槽/退出顺序。

`Sweep` 仅将 tgkill 的 ESRCH 解释为线程不存在；同编号后来属于不使用 custom TLS 的
外部线程时，会保守延迟回收。空系统 TLS 的新线程注册同 pid/tid 时，可摘掉旧对象；
新对象与旧观察者按对象引用及 registry 锁串行，不按旧数字 ID 删除新对象。该依据仍需
目标 OS 和真实 ID 复用资格，不从宿主可控编号试验外推为目标内核已证明。

任何未知查询错误保留旧 arena，并通过 `expansionError` 拒绝新 Module/arena/block
扩张；已取得的块继续保持原址原值。除已经在途的有限分配和显式Retire/回滚外，长期未知
状态不会再静默积累本模块存储。`RecheckCapability` 用新一轮自己及全部登记对象观察显式
恢复扩张。旧存储保留并不是完整资源资格；失败必须由上层处理，不可忽略状态无限运行。

错误状态将失败代次与errno放入同一个64位原子量。相同errno的新失败也递增代次；重验
只可CAS清除其开始时观察的精确代次，不能以持registry锁掩盖锁外self/warm失败。代次饱和
后保持EOVERFLOW并拒绝自动恢复，不能回绕造成ABA。`recovery_race.cpp` 在一次成功查询
阻塞时注入相同errno的新失败，验证旧重验不能吞掉它；根任务可用保存的真实旧header作
负对照，`TLS_STORAGE_NEGATIVE_HEADER` 显式指定只读输入，仅约定77及反例正文算复现。

正常 pthread fork 的 child handler 先 poison 子进程，热路径在读取继承 arena/锁前拒绝；
冷路径另核 PID。继承状态不重置、不清理、不认领。绕过 pthread_atfork 的 raw fork/clone
不受该门保障，完整应用 fork/exec 合同仍由主工程另外验证。更早注册的 child handler
会在本模块 poison 之前执行，已有块的热读此时仍可见父进程 arena 的私有副本；这也是
明确未关闭窗口，不宣称覆盖全部atfork时刻。新块、准备回滚、metadata引用和Sweep等冷
操作另核真实PID并拒绝。测试让另一线程持有registry锁跨fork，核child的这些路径不会
等待继承锁，并明确输出更早handler的热读观察；不为隐藏该边界给热路径强加syscall。

模块外部引用和Block内部元数据引用分别计数。最后外部引用关闭时，registry锁下将该
模块全部payload的原子指针置空并取得唯一释放权，解锁后释放payload及初始化模板。
线程内哈希/最近命中缓存不被另一线程修改；原线程下次冷miss清理墓碑节点，或由明确OS
终态回收整张表。该arena的退休标记仅在实际产生墓碑时置位，没有退休的批量装载和其它
arena的退休均不触发全表扫描；热命中不检查或更新该标记。发生退休后的冷清理仍按本
arena的现有节点线性扫描，相关目标设备成本需随集成测量。

长寿线程64代各16KiB的合法module churn应立即释放全部payload，只保留至多最后一枚
小节点及元数据。测试同时覆盖独立callback引用跨creator退休保留晚析构原值、另一个
线程关闭最后入口时释放64KiB模板，以及退休与终态回收/准备回滚竞争不重复释放。
`module_churn.cpp` 可通过 `TLS_STORAGE_MODULE_NEGATIVE_HEADER` 对真实冻结旧header
运行相同合同；只接受退出77和精确资源反例正文，保留旧实现的1MiB增长证据。真实glibc
对照执行合法dlopen/use/dlclose，确认无handle后映像卸载并测量TLS地址复用/堆变化；
所有对照均不在close后调用旧函数或解引用旧TLS指针，也不靠永久pin解决资源问题。

上述为核心的存储合同与回归目标，尚未证明完整loader的引用是否覆盖全部合法入口，
也未取得目标设备的终止、析构和性能完整资格。分配、注册、回滚与显式关闭是普通冷
路径，不声称async-signal-safe；回收者只释放存储，绝不代替原线程补跑用户析构。

运行入口是 `run.sh`，由根任务协调接入标准 `amcl/qa` 服务；不要并行抢占共享容器。
输出在 `/output`，独立环境可设 `TLS_STORAGE_OUTPUT` 为仓外目录。ASan/UBSan/LSan
检查覆盖模板/对齐、跨块晚析构和TSD迭代、OOM/回滚、缓存、未知错误、detached/joined churn、
可控编号复用和 fork child 拒绝。`TLS_STORAGE_TSAN=1` 开启单独TSan，环境拒绝时保留原错误。
测试准备完毕不等于已经执行；实际结果和目标集成证据写外置任务记录。
