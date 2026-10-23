# JDK25非活动安全点补丁

`0006-aarch64-elf-safepoint-fallback.patch`和`0007-safepoint-mechanism-mem-prot-read.patch`保留旧原字节，用于旧运行时来源追溯和真实源应用的负对照；二者不在活动`series`中，不能按`*.patch`通配应用。

0006在未识别poll故障时把共享坏页改READ并返回true，0007把bad polling page初始化为READ。它们绕过HotSpot的安全点协议，不能继续作为ELF装载兼容。新候选保持锁定上游安全点文件不变，由现有宿主四参数HotSpot接口转发合法信号。

`apply_jdk_patches.py`和`jdk_build_identity.py`按series选择活动补丁；Docker输入身份和源码导出还会包含本目录的历史文件。包含在来源归档中不表示仍然应用。旧的含两补丁工作卷不能被静默认领为新输入，须按构建契约建立新身份。

构建前与来源记录前的`verify_jdk25_safepoint.py`绑定锁定HEAD并比对真实安全点源码，活动补丁即使换名重新修改这两文件也会失败。补丁退役不是修复验收通过，阶段与矩阵见[专项方案](../../../../docs/adaptation/JDK25_SAFEPOINT_FREEZE_REPAIR.md)。
