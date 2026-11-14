# JDK 8 AWT 加载 JNI 回归

`awt_jni_check_test.c` 直接包含固定 JDK 8 `awt_LoadLibrary.c`，分别编译上游原文和
正式 `0020-jni-font-library-exception-check.patch` 应用后的源码。替身只在 JNI、
`dladdr/realpath/dlopen` 等外部边界注入结果，初始化控制流和成功缓存由真实 C 源码执行。

上游固定为 `prebuilt/jdk/build-inputs.json` 中 JDK 8 commit
`35c254f58c70663df28cc7d15c9545c88250b6ce`。输入清单列出源码/所需头文件的
`source`、`revision`、`savedPath` 和 `sha256`，与 zipfs 回归的原文清单契约相同。
runner 核对 commit、全部原文字节及 AWT 原版固定 SHA，然后在全新仓外目录应用正式补丁。

Windows 可使用已安装的 WSL GCC；不创建或占用 Docker。示例中的路径需按实际环境指定：

```powershell
python tests/runtime-permissions/run-awt-jni-check.py `
  --source-manifest E:/AMCL/.workspace/run/jdk-impl-preview/jni-font-check/sources-with-headers.json `
  --output E:/AMCL/.workspace/run/jdk-impl-preview/jni-font-check/new-run `
  --wsl Ubuntu `
  --sdk-cc D:/Huawei/command-line-tools/sdk/default/hms/native/BiSheng/bin/clang.exe `
  --sdk-sysroot D:/Huawei/command-line-tools/sdk/default/openharmony/native/sysroot `
  --sdk-nm D:/Huawei/command-line-tools/sdk/default/openharmony/native/llvm/bin/llvm-nm.exe
```

Linux 宿主省略 `--wsl`，可用 `--cc` 指向现有 GCC。目标 SDK 三个参数一起提供或一起省略；
省略时收据明确记 `NOT-RUN`。所有输出、命令、时间、退出码和输入 SHA 留在指定外部目录。

回归验证这些独立行为：

- 上游原版的漏查 `CallStaticBooleanMethod` 和首次失败污染缓存，各自必须准确复现并退出
  `77`；断言失败、崩溃、超时均不算负例成功。原版负例未启用泄漏检测，因为它本身保留 local ref。
- 候选完整执行 headless/X11 两个分支以及 `System.setProperty` 合法 NULL/非 NULL 返回。
  18 个失败阶段覆盖原有 pending 异常、NULL env、类/方法查找异常与 NULL-only、布尔方法异常、
  字符串分配、属性设置、`System.load`、`dlopen`。每个阶段检查 `JNI_ERR`、首个异常身份、
  local ref 归零、没有清除异常/调用 FatalError，也没有越过失败继续普通 JNI 或加载后端。
- 9 种冷查询失败后必须能重试；失败不缓存默认 false。两种成功值共 20 万次热查询不再访问
  Java 或 `JNU_GetEnv`。同线程重入和 16 线程同时冷查询证明不持锁跨 Java，且使用各线程的 env。
- 候选用 ASan、UBSan、LSan 执行；目标 SDK 用实际固定头和 GNU C99 编译真实候选 C，检查
  原子缓存没有引入未经验证的 `__atomic_*`、`__sync_*` 或 `__aarch64_*` 运行时 helper。

修复边界：`AWT_OnLoad` 自身保留 pending 异常并返回 `JNI_ERR`；最终 JVM 如何向 Java
调用者呈现加载失败仍由原有 NativeLibrary/JVM 加载层决定。普通 `AWTIsHeadless` 在冷查询
失败时返回保守的 true，保留异常，避免未初始化 false 误入 X11；正常字体调用发生在 AWT
加载成功之后并命中成功缓存。未改变原有路径解析、X11/Headless 功能或 Java headless 决策。

本测试证明宿主上的真实 C 控制流和目标单文件编译，不能代替完整 JDK 链接与真机
`-Xcheck:jni` 字体资格测试。后者应使用含 `0020` 的新 JDK 8 产物，核对原设备日志中
`ClassLoader$NativeLibrary.load → FontManagerNativeLibrary` 的该漏查告警消失。
