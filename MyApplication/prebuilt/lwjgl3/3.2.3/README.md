# LWJGL 3.2.3 兼容槽

本槽与现代 LWJGL 3.4.2、LWJGL 2 共存，设备部署目录为 lwjgl-ohos-322。启动器按游戏声明的 LWJGL 依赖选择槽位，不仅依赖固定 Minecraft 版本区间。精确 JAR/Native 清单见 [legacy-slots.manifest.json](../legacy-slots.manifest.json) 与 [deps.lock](../../../deps.lock)。

Java 输入位于 [jars/](jars/)，Hvigor 同步到 rawfile/lwjgl-3.2.3/。核心库通过 org.lwjgl.libname 选择 liblwjgl_v322.so；opengl/stb/tinyfd 对应库名带 _v322 后缀，避免与现代槽冲突。GLFW 共用 libglfw.so 的窗口/输入 facade；实际图形 provider 由统一 GraphicsPlan 决定。

相关重建配方：

- [docker/build_dyncall_ohos.sh](../../../docker/build_dyncall_ohos.sh)：该代际所需 dyncall 输入。
- [docker/build_lwjgl_ohos.sh](../../../docker/build_lwjgl_ohos.sh)：设置对应 LWJGL_TAG 与 NATIVE_SUFFIX 等参数构建 Native。
- [docker/build_lwjgl322_jars.sh](../../../docker/build_lwjgl322_jars.sh)：旧槽 JAR 准备、模块名处理与桥接注入。

这些配方需要独立的 OHOS 容器及 sysroot，不由现代槽的 Maven 下载自动重建。普通 HAP 使用公开快照中保留的旧槽输入。具体准备范围与未完成的全栈重建验证见 [BUILD_SNAPSHOT.md](../../../docs/BUILD_SNAPSHOT.md)。
