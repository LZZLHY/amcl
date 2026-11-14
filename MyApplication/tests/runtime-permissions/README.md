# PERM-01 目标测量输入

这些固定测量输入已接入default/TestHooks的隔离Java资格入口；只在显式新nonce请求时运行，不会启用权限兼容。
目标为区分 zipfs 复制已存在权限元数据与真正修改执行位、收紧权限；所有结果都需在
应用实际 token 和实际选定存储根下采集，不能由 hdc shell 或目录名字替代。

## 最小运行组合

1. 宿主分别对真实 `filesDir` 和由现有 GameStorage 得到的已授权外部应用/游戏根调用
   `amcl::permissionprobe::Run(rootPath, freshNonce)`。每次 nonce 不同，目录已存在就拒绝。
   该函数只调用宿主真实 libc；不能从被 custom loader 重定位后的测试DSO间接调用，否则
   仍可能观察到旧的 blanket shim。保存完整返回JSON、设备/API/系统版本、HAP摘要和PID。
2. 在对应根下，用当前JDK运行 `PermissionCopyProbe <absoluteRoot> <freshNonce> <absoluteReportPath>`，
   独占创建 UTF-8 报告并保留异常栈。正式验证只读报告文件中的完整 `PERM_JAVA` / `PERM_JAVA_DIRECT`
   行；共享 stdout 可能被 `PrintCompilation` 插入，不能修剪或拼接后冒充结构化证据。
   源码兼容Java8，编译使用 `javac --release 8`，class major应为52。
3. Native记录与Java记录须来自同一设备/应用权限/根和相近会话。每个JDK的真实zipfs关闭
   都需要复验，不能用Native模式相等代替Java ZIP载荷/异常结果。

Native矩阵是3个API×5个请求：完整07777模式原样设置、翻转owner执行位、收紧到0600、
移除owner写位、设置0000。每项独占一个普通文本文件，不执行文件，不改变进程umask、
cwd或应用目录权限。结果包含真实errno、同一打开fd前后dev/ino/uid/gid/mode、路径当前
对象一致性、fstatfs身份/标志、目录fdinfo（可能包含mnt_id）和重新打开读写的实际结果。
禁止因观察到EPERM、FUSE编号或Download字样就认定请求无害。

Java矩阵比较普通ZIP与同目录 `Files.createTempFile` 的完整 `unix:mode`、dev/ino及
FileStore信息，然后写入真实zipfs并关闭，确认两个ZIP条目均存在。FileStore type只是
观察值，不自动证明POSIX权限无意义。旧shim仍存在时，Java成功明确报告
`nativePermissionResultKnown=false`，不能用它证明真实chmod成功。

## 判读门

- 如果外部根原ZIP与临时文件完整07777模式相等，且特殊位为0，则证实该次zipfs只是在
  重复请求已存在权限。可优先在zipfs元数据复制点避免冗余请求，Native权限API保持真实语义。
- 如果模式不同，不能扩大errno白名单来让测试通过；保留实际差异及所需功能，继续核实
  provider的文件创建/权限合同或复制策略。没有证据前不得宣布外部Download完成资格。
- 真实执行位变化/收紧失败必须报告原errno；即使stat显示执行位也不证明目标允许exec。
- fdinfo不可读、fstatfs失败、对象身份不稳定均记为未知；不使用旧缓存/路径名填补身份。
- 本次最小矩阵不证明相对dirfd、符号链接、AT_SYMLINK_NOFOLLOW/未知flags的额外行为。
  如选择保留Native fallback，它们必须另加正/负例；默认策略应原样透传这些调用。

探针生成的目录只含本次自有样本并保留证据。需清理时由任务负责人按报告中的精确目录
处理，不能递归扫描或清除用户既有游戏树。宿主/设备运行和四代资格分开记录。

## 新加载器的目标组合验收

PermissionCopyProbe现在另在每个根的5个独占样本上调用真实Files.setPosixFilePermissions，记录同值/执行位/0600/去写位/0000的真实成功或IOException，核实完整mode和对象未替换。宣称成功但mode未改变会立即失败，ZIPFS写回失败也不再只打印后返回0。Native入口要求Java权限夹具返回0。`verify-device.py --run <回收run-major目录> --report <新报告>`将Java与同PID、同根的宿主libc三API矩阵逐项比较，另验ZIPFS最终mode与生命周期。未知/缺失/旧观察夹具拒绝；NOT-RUN外部根保持未验，不向未测根转移资格。该校验不证明CLI可执行或跨设备权限合同。

## 文件时间与跨卷移动对照

`FileMoveProbe.java` 是独立、未内嵌进HAP的Java8/class52测量输入。它比较私有和公共根的
35项实际操作：分别设置原时间/mtime/atime/两者/creation、四方向普通复制/属性复制/
移动/原子移动/目标同目录暂存发布，以及已有目标和缺失源的拒绝。编译输出必须放仓外：

```powershell
# $ProbeOutput由调用者指定为全新仓外目录；不使用项目内临时目录或改全局TEMP。
javac -encoding UTF-8 --release 8 -d "$ProbeOutput/classes" tests/runtime-permissions/FileMoveProbe.java
java -cp "$ProbeOutput/classes" com.amcl.qa.FileMoveProbe $PrivateParent $ExternalParent $UniqueNonce
```

两个父目录须为已存在的普通绝对目录，每轮nonce唯一；程序只新建自己的
`amcl-nio-probe-<nonce>`目录，拒绝接管旧样本。真实启动器额外传入
`--width <正整数> --height <正整数>`时允许恰好7参数，尺寸只记录、不参与文件操作。
其他参数在创建样本前拒绝。可参考 `tests/runtime-jdk-safepoint/prepare_real_profile.py`
的独立真实客户端+本地library方式接入普通启动，不用小夹具JAR伪造Mojang客户端。
在不同MC版本上使用时必须保留该版本真实profile和客户端摘要，不直接套用26.2的路径门。

每项记录异常类型、原因、源/目标存在性、属性和SHA；读摘要可能改变atime，因此先记录
属性并另列读取后的atime。跨不同`unix:dev`的ATOMIC_MOVE预期拒绝，设备号读不到则
记unknown，不能用“发生异常”代替具体异常类型核验。creation返回正常不代表实际改值。
`completionProof`只证明43条JSONL/35项流程收敛，不等于兼容通过；程序会保留意外结果
或未知能力失败的现场。全部成功时仅逆序回收自有登记文件和目录，不递归清共享父目录。

2026-11-12实测四代JDK的公共目录改时和带属性复制有共同EPERM，细节见
[完整整合包与文件操作验收](../../docs/reports/2026-11-12_FULL_MODPACK_RUNTIME_ACCEPTANCE.md)。
该结果不能被编码成通用吞错规则，真实权限语义和完整游戏验收继续独立判断。
