# LWJGL GLFW 的 OHOS 桥接类

本目录的 [src/org/lwjgl/glfw/](src/org/lwjgl/glfw/) 包含 CallbackBridge.java 和 GLFWWindowProperties.java。工程保留上游 GLFW.class，在 Maven 原版 JAR 基础上注入这些桥接类，不维护手写的 GLFW API 子集。

Native GLFW C ABI 由应用构建的 libglfw.so 提供；实际 GL/EGL provider 与窗口生命周期按宿主运行计划处理。

在 MyApplication/ 完成公开依赖准备后，可以执行：

```powershell
node scripts/build-prebuilt-jars.mjs
node scripts/prepare-lwjgl-modern-slot.mjs --require-source
```

第一个命令编译并注入桥接类，第二个完成整个现代槽处理与校验；Hvigor 会调用相应准备链。baseline JAR 必须由锁定下载流程先取得，不能用缺失或其他版本的 lwjgl-glfw.jar 代替。

classes/ 与现代 jars/ 是本地生成/准备内容。公开快照保留源文件和 rawfile 输入，但不会把现代 jars/ 工作树作为可省略下载的保证。详细契约见 [LWJGL 3 说明](../README.md) 和 [公开构建步骤](../../../docs/BUILD_SNAPSHOT.md)。
