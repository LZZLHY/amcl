# LWJGL 2：旧版 Minecraft 兼容槽

当前工程已经包含真正的 LWJGL 2 运行路径，不再是“尚未实现”或启动时统一拒绝的阶段。[LaunchProfileBuilder.ets](../../launch/src/main/ets/LaunchProfileBuilder.ets) 根据游戏依赖选择 lwjgl-ohos-2 槽；[RuntimeDeployer.ets](../../launch/src/main/ets/RuntimeDeployer.ets) 负责部署。实际兼容范围仍需按游戏、加载器和设备验证。

核心 Native 库使用 [liblwjgl_v2.so](../../entry/libs/arm64-v8a/liblwjgl_v2.so)，避免与 LWJGL 3 的同名库冲突。本目录保存 [ohos-backend/](ohos-backend/) 与 [patches/](patches/)；Java 运行资源位于 entry 的 rawfile 中，具体身份见 [legacy-slots.manifest.json](../lwjgl3/legacy-slots.manifest.json)。

独立重建入口为 [docker/build_lwjgl2_ohos.sh](../../docker/build_lwjgl2_ohos.sh)。其 LWJGL 2 生成器依赖 JDK 8，这是该历史依赖配方的要求；不要与普通 HAP 构建所需的主机 JDK 21+ 混淆。OHOS Native 编译还需要配方声明的工具链和 sysroot。

这个配方保留了分阶段构建逻辑，公开快照没有声明所有旧版 Native 输入已经完成从干净环境到相同字节产物的全流程重建验证。普通 HAP 使用快照内保留的 Native 输入，详见 [BUILD_SNAPSHOT.md](../../docs/BUILD_SNAPSHOT.md)。

GL 固定管线路线与 [gl4es](../gl4es/README.md) 配合，但选择由统一启动计划决定。来源与许可见 LWJGL 上游、文件头及 [CREDITS.md](../../docs/CREDITS.md)。
