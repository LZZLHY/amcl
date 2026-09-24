# Forge / NeoForge 安装路径的历史目录

本目录曾存放 ForgeInstaller.java 和对应的 forge-install-bootstrapper.jar。当前工程不再编译或部署该 bootstrapper。

现役安装器位于 feature_core 模块中的 ForgelikeInstaller / ForgelikeProcessorRunner；processor 通过独立 Java 进程执行，具体入口可在 [feature_core/src/main/ets/](../../feature_core/src/main/ets/) 与 Native JVM 层中查找。

本目录不需要下载或生成新的 bootstrapper JAR。公开工程构建见 [BUILD_SNAPSHOT.md](../../docs/BUILD_SNAPSHOT.md)。
