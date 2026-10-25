# 实际旧LWJGL2交付反控

这两份文件来自真实代码提交 `45b47d0f42b1b98e79f951e727a9d0b90b109d8c` 的完整交付JAR和
Native生产源码，保持原字节。`manifest.json` 固定来源、原路径、尺寸和SHA；测试先核身份。
它们用于old-old校准及new Java/old JNI、old Java/new JNI双向混搭拒绝，不能写入产品rawfile
或作为新制品的重建输入，也不能修改旧源码来迎合反控。

固定完整样本让独立公开快照和浅克隆不依赖维护者的历史Git对象或AMCL外部目录。新rawfile
已带私有握手，不能用它冒充旧JAR。Native旧函数从完整原文提取，平台/运输边缘显式替换；
真正Java类来自完整旧JAR，不模拟“缺marker”类。已有来源和许可证随JAR/原源码保留。
