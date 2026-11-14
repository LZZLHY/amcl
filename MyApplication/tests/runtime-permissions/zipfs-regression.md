# zipfs 权限复制回归

生产修改为四代 `0019-zipfs-permission-copy-transaction.patch`：只在原临时对象的完整
07777模式已经满足复制目标时跳过冗余设置；模式变化或Unix视图未知继续真实API。
权限操作早于原ZIP删除/挪动。新属性读取或权限步骤失败时显式关闭源通道，关闭失败
附在原异常的suppressed中，不能用资源泄漏换取旧ZIP保留。

`ZipfsPermissionRegression.java`直接构造并执行完整上游ZipFileSystem。ZIP字节真实
读写、删除和移动；自定义FileSystemProvider仅在POSIX属性、fileKey和错误边界注入。
每次实际打开的channel都计数并委托真实关闭。它不是重新写一份sync算法，也不能替代
目标文件系统语义、四份完整JDK构建或真实Fabric启动。

每个原版/候选执行11项：同值被拒、真实变化被拒、特殊位、缺Unix视图、缺fileKey、
身份变化、后期metadata拒绝、初始fileKey读取拒绝、权限失败同时close失败，以及两条
正常成功路径。失败候选必须保留原ZIP全部字节、关闭全部实际通道；同值路径不得调用
权限设置，真实变化不能跳过，关闭错误不得替换原来的AccessDeniedException。

运行示例（所有参数均为显式本机路径，输出目录必须全新且位于仓外）：

```text
python -B tests/runtime-permissions/run-zipfs-regression.py \
  --source-manifest <固定上游源码获取记录sources.json> \
  --jdk8-support-jar <同源完整JDK8中的zipfs.jar> \
  --java17 <Java17-home> --java21 <Java21-home> \
  --output <新的仓外运行目录>
```

可增加 `--java8` / `--java25` 使用真正对应major的宿主；未提供时明确以Java17运行8/17
源码、Java21运行21/25源码。这能验证源码逻辑和错误顺序，不能写成四种宿主VM或OHOS
全套资格通过。脚本不下载工具、不改SDK/活动源码，验证上游commit/SHA后在独占树中
执行`git apply --check`、应用正式补丁、编译完整类并保存每条命令和产物身份。

初版候选仅调整顺序时的真实通道泄漏反例，以及旧上游先删原ZIP再失败的对照均保留于
本轮外置PERM-01记录。最终候选已有两道独立回归：旧ZIP完整性与channel全部关闭。
