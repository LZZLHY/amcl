# 实际 P3 交付、look-v1 之前的样本

这是维护者实际已交付的 `f63a44814671b63b0842079015b37a959106a438` backend 正文和
1908258 字节维护 JAR。它已经有 `AMCL_CONTROL_PROTOCOL`，尚无 `AMCL_LOOK_PROTOCOL`；
不能用更早的 pre-P3 样本代替“已有 control、缺新增 look”的真实混搭。

测试先校 manifest 中的完整原字节尺寸/SHA，再抽取真正旧 JNI 函数和用真正旧 JAR
加载器执行。独立 clone/CI 直接使用固定样本，不要求维护者 private git ref 或完整
历史。C 正文保原 LF，JAR 保二进制原字节；不更新样本以迎合新生产实现。
