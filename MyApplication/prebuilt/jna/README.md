# JNA Native dispatch 输入

本目录保留 [libjnidispatch.so](libjnidispatch.so)，HAP 使用的副本位于 [entry/libs/arm64-v8a/libjnidispatch.so](../../entry/libs/arm64-v8a/libjnidispatch.so)。目录中的来源记录指向 JNA 5.14.0 的 linux-aarch64 归档输入；AMCL 的运行环境适配不改变其第三方属性。

Java 侧 JNA 与 Native dispatch 的协议版本需要匹配。更换上游版本时应检查对应 JAR 的 Native 输入和加载协议，并对目标 Forge/模组依赖验证；不能只用同名 SO 替换后认为兼容。

Hvigor 当前的资源同步任务处理 JAR，不自动把本目录所有 SO 复制到 entry/libs。公开快照已经保留需要的工程输入；自行更新时应明确同步目标并核对来源、产物指纹和 ELF 依赖。

JNA 的许可见相应上游归档的 LICENSE/NOTICE；本文件不声明这些正文已收齐在公开 docs/。工程构建与第三方范围见 [BUILD_SNAPSHOT.md](../../docs/BUILD_SNAPSHOT.md) 和 [CREDITS.md](../../docs/CREDITS.md)。
