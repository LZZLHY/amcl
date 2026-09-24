# 模组 Native 运行时输入

本目录保存为 OHOS arm64 提供的模组 JNI 输入及配方。登记项、版本、来源、加载方式和排除扩展见 [manifest.json](manifest.json)；目前登记 imgui-java，Native 文件名为 libimgui-java64.so。

对应源码在 [imgui-java/jni/](imgui-java/jni/)，配方为 [imgui-java/build-ohos.sh](imgui-java/build-ohos.sh)，普通 HAP 使用 [entry/libs/arm64-v8a/libimgui-java64.so](../../entry/libs/arm64-v8a/libimgui-java64.so)。清单登记了 Dear ImGui 1.86 及所包含/排除的扩展，不能由一个库文件推断支持全部 ImGui 扩展。

imgui-java 的加载契约先尝试 System.loadLibrary，AMCL 将 HAP Native 目录加入 Java 库路径。其他模组的加载器可能有不同规则，不能推广为所有模组都只需复制一个 SO。

独立重编需要 build-ohos.sh 指定的 OHOS clang wrapper 和 sysroot。脚本支持 OHOS_GXX、OHOS_CLANG、OHOS_SYSROOT_RW 等环境变量；使用者须配置实际工具路径。Android Native 库不能直接替代 OHOS 输入。

变更后需核对目标 ABI、ELF NEEDED、JNI 方法与目标 Java 依赖版本，并在使用该库的模组上验证。编译成功不代表完成运行验收。完整范围与许可入口见 [BUILD_SNAPSHOT.md](../../docs/BUILD_SNAPSHOT.md) 和 [CREDITS.md](../../docs/CREDITS.md)。
