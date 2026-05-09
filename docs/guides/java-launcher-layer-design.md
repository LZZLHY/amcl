# AMCL Java 启动层规划文档（2026-04-10）

> **状态（2026-04-19）**：本方案已落地 —— `JavaApp/src/com/amcl/launcher/` 下 4 个类
> （`AmclLauncher` / `AmclClassLoader` / `LaunchConfig` / `ForgeHelper`）已实现，
> 通过 `-Djava.system.class.loader=com.amcl.launcher.AmclClassLoader` 接管系统 CL，
> 并在 mc_launcher.cpp Phase 5 反射调用。本文档保留作为设计背景阅读。

## 一、当前架构（AMCL）

### 启动链路

```
ArkTS (McGamePage)
  → LaunchProfileBuilder.build()    // 解析 version.json，构建 classpath/args
  → NAPI mcLaunchWithProfile()      // 传入所有参数
  → mc_launcher.cpp                 // C 层 6 阶段启动（Phase 0-5）
    Phase 0: validate()             // 检查 .minecraft/versions/<ver>/<ver>.jar 存在
    Phase 1: initJvm()              // JNI_CreateJavaVM（只能调用一次，含 sigchain）
    Phase 2: registerAllNatives()   // 注册 GLFW/OpenAL JNI（36 个方法）
    Phase 3: setProperties()        // System.setProperty（JNI 调用）
    Phase 4: redirectIO()           // stdout/stderr → mc_output.log
    Phase 5: launchMain()           // 反射调用 AmclLauncher.main(JSON)
```

### 核心问题

1. **classpath 在 JVM 创建时固定**：`JNI_CreateJavaVM` 的 `-Djava.class.path` 一旦设定无法修改。第二次启动不同版本时 classpath 不对。
2. **无 Java 中间层**：C 层直接反射调用 MC mainClass，无法在 Java 层做预处理（创建 fml.toml、设置属性、初始化 Cacio 等）。
3. **user.home 困境**：Forge Bootstrap 用 `user.home` 定位 `config/fml.toml`，但 `user.home` 必须等于 `gameDir` 才能找到文件，导致版本隔离下 `user.home` 不是应用根目录。
4. **类加载受限**：`SystemClassLoader.loadClass()` 只能加载 classpath 上的类，Forge 的 JPMS 模块需要 `--module-path` 在 JVM 创建时就设好。

## 二、Pojav 架构（Amethyst-iOS）

### 启动链路

```
Native (JavaLauncher.m)
  → JLI_Launch(argc, argv)          // 等价于命令行 java 命令
  → JVM 内部创建                     // JLI 自动调用 JNI_CreateJavaVM
  → PojavLauncher.main()            // Java 入口（不是 MC 的 main）
    → 初始化 Cacio AWT
    → 设置 UncaughtExceptionHandler
    → Tools.launchMinecraft()
      → PojavClassLoader 动态加载所有 jar
      → loader.loadClass(mainClass)
      → method.invoke(main)         // 反射调用真正的 MC main
```

### 关键组件

**PojavClassLoader**（自定义系统 ClassLoader）：
- 通过 `-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader` 注册
- 继承 URLClassLoader，支持 `addURL()` 动态添加 jar
- JVM 创建时 classpath 只需包含 launcher.jar 本身
- 所有 MC library jar 在 Java 层动态添加

**PojavLauncher.main()**（Java 入口）：
- 在 MC main() 之前执行任意 Java 逻辑
- 设置系统属性、创建配置文件、初始化 AWT
- 通过 PojavClassLoader 加载 MC mainClass

**Tools.java**（启动工具）：
- `generateLaunchClassPath()`：从 version.json 构建 classpath
- `launchMinecraft()`：动态加载 jar + 反射调用 main
- `getVersionInfo()`：解析 version.json（含继承链）

### 为什么 Pojav 能正确处理 user.home

Pojav 的 `user.home` = `POJAV_HOME`（应用根目录），`user.dir` = `gameDir`（版本隔离目录）。
Forge 的 `fml.toml` 查找路径基于 `user.dir`（即 gameDir），不依赖 `user.home`。
但 Pojav 的 Java 层在调用 MC main() 之前可以做任何预处理，包括在正确路径创建 fml.toml。

## 三、AMCL Java 启动层设计

### 设计原则

1. **不照搬 Pojav**：Pojav 有大量 iOS/Android 特有逻辑（UIKit 桥接、macOS 兼容 hack），我们不需要
2. **最小化改动**：保留现有 C 层 5 阶段架构，只在 Phase 5 改为调用 Java 中间层而非直接调用 MC main
3. **向后兼容**：原版 MC 和 Fabric 仍然可以走现有链路（不强制经过 Java 层）
4. **解决实际问题**：重点解决 classpath 动态化、user.home 解耦、Forge 预处理

### 新架构

```
ArkTS (McGamePage)
  → LaunchProfileBuilder.build()
  → NAPI mcLaunchWithProfileV2()
  → mc_launcher.cpp
    Phase 1: jvmInit()              // classpath 只含 amcl-launcher.jar
    Phase 2: registerAllNatives()
    Phase 3: setProperties()        // user.home = filesDir（安全）
    Phase 4: redirectIO()
    Phase 5: jvmCallMain("com.amcl.launcher.AmclLauncher")
      → AmclLauncher.main(args)    // ← 新增 Java 入口
        → 解析启动参数（JSON 格式）
        → 设置 Forge/Fabric 特有属性
        → 创建 fml.toml（如需要）
        → AmclClassLoader 动态加载所有 MC jar
        → loader.loadClass(mainClass).main(mcArgs)
```

### 与 Pojav 的关键差异

| 方面 | Pojav | AMCL（新） |
|------|-------|-----------|
| JVM 创建方式 | JLI_Launch（完整 java 命令） | JNI_CreateJavaVM（嵌入式） |
| 系统 ClassLoader | PojavClassLoader（替换默认） | 不替换，用独立 AmclClassLoader |
| 参数传递 | 命令行 argv | main(args) JSON 字符串 |
| version.json 解析 | Java 层（Tools.java） | ArkTS 层（已有 VersionParser） |
| classpath 构建 | Java 层（Tools.generateLaunchClassPath） | ArkTS 层（已有 LaunchProfileBuilder） |
| LWJGL 处理 | 不替换 | Forge 不替换，Fabric/原版替换 |
| Cacio AWT | Java 层初始化 | 不需要（OHOS 有原生 UI） |
| macOS hack | 有（Beans.setDesignTime 等） | 不需要 |

## 四、核心组件设计

### 4.1 AmclLauncher.java

```java
package com.amcl.launcher;

/**
 * AMCL Java 启动入口。
 * 由 C 层 jvmCallMain 调用，在 MC main() 之前执行预处理。
 *
 * 职责：
 * 1. 解析 C 层传入的启动参数（JSON 格式）
 * 2. 设置 Forge/Fabric 特有的系统属性和配置文件
 * 3. 通过 AmclClassLoader 动态加载所有 MC library jar
 * 4. 反射调用真正的 MC mainClass.main()
 */
public class AmclLauncher {
    public static void main(String[] args) throws Throwable {
        // args[0] = JSON 格式的启动配置
        // 包含：mainClass, classpath, mcArgs, gameDir, mcDir, filesDir 等
        LaunchConfig config = LaunchConfig.parse(args[0]);

        // 1. 设置系统属性（在 MC main 之前，Java 层设置更可靠）
        setupSystemProperties(config);

        // 2. Forge 预处理：创建 fml.toml 禁用 EarlyDisplay
        if (config.isForge()) {
            ForgeHelper.disableEarlyDisplay(config);
        }

        // 3. 创建 ClassLoader，动态加载所有 MC jar
        AmclClassLoader loader = new AmclClassLoader(
            config.getClasspathUrls(),
            AmclLauncher.class.getClassLoader()
        );
        Thread.currentThread().setContextClassLoader(loader);

        // 4. 加载并调用 MC mainClass
        Class<?> mainClass = loader.loadClass(config.mainClass);
        mainClass.getMethod("main", String[].class)
                 .invoke(null, (Object) config.mcArgs);
    }
}
```

### 4.2 AmclClassLoader.java

```java
package com.amcl.launcher;

import java.net.URL;
import java.net.URLClassLoader;

/**
 * AMCL 自定义 ClassLoader。
 * 不替换系统 ClassLoader（避免 -Djava.system.class.loader 的复杂性），
 * 而是作为独立的 URLClassLoader 使用。
 *
 * 与 PojavClassLoader 的区别：
 * - 不需要 appendToClassPathForInstrumentation（JDK 内部 API）
 * - 不替换系统 ClassLoader（更安全）
 * - 通过构造函数一次性传入所有 URL（不需要动态添加）
 */
public class AmclClassLoader extends URLClassLoader {
    public AmclClassLoader(URL[] urls, ClassLoader parent) {
        super(urls, parent);
    }

    // 允许后续动态添加 jar（模组可能需要）
    public void addJar(URL url) {
        addURL(url);
    }
}
```

### 4.3 LaunchConfig.java

```java
package com.amcl.launcher;

/**
 * 启动配置，由 ArkTS 层 LaunchProfileBuilder 构建，
 * 序列化为 JSON 传给 AmclLauncher.main(args)。
 */
public class LaunchConfig {
    public String mainClass;      // MC 主类名
    public String[] mcArgs;       // MC 启动参数
    public String[] classpath;    // 所有 jar 路径
    public String gameDir;        // 版本隔离目录
    public String mcDir;          // .minecraft 根目录
    public String filesDir;       // 应用 files 目录
    public String assetsDir;      // assets 目录
    public boolean isForge;       // 是否为 Forge
    public boolean isFabric;      // 是否为 Fabric

    public static LaunchConfig parse(String json) { ... }
    public URL[] getClasspathUrls() { ... }
}
```

### 4.4 ForgeHelper.java

```java
package com.amcl.launcher;

/**
 * Forge 特有的预处理逻辑。
 * 在 Java 层执行，比 C 层更灵活可靠。
 */
public class ForgeHelper {
    /**
     * 禁用 Forge EarlyDisplay。
     * 在 gameDir/config/fml.toml 中写入 earlyWindowControl=false。
     * 因为在 Java 层执行，user.dir 已经正确设置，路径一定正确。
     */
    public static void disableEarlyDisplay(LaunchConfig config) {
        // 写入 gameDir/config/fml.toml
        // 写入 mcDir/config/fml.toml（如果不同）
        // 不需要写 filesDir/config/（user.home 问题已解决）
    }
}
```

## 五、C 层改动

### 5.1 jvmInit 的 classpath 变化

**现在**：classpath 包含所有 MC jar（可能上万字符）
**改后**：classpath 只包含 `amcl-launcher.jar`（几十 KB）

```cpp
// 现在
jvmSetClasspath(fullMcClasspath.c_str());  // 10000+ chars

// 改后
std::string launcherJar = filesDir + "/amcl-launcher.jar";
jvmSetClasspath(launcherJar.c_str());      // 100 chars
```

好处：JVM classpath 极短，所有 MC jar 由 Java 层 AmclClassLoader 动态加载。
JVM 重用时 classpath 不需要变（amcl-launcher.jar 始终在同一位置）。

### 5.2 jvmCallMain 的调用变化

**现在**：
```cpp
jvmCallMain("net.minecraftforge.bootstrap.ForgeBootstrap", mcArgc, mcArgv);
```

**改后**：
```cpp
// 将 LaunchProfile 序列化为 JSON，作为唯一参数传给 AmclLauncher
std::string configJson = buildLaunchConfigJson(profile);
const char* args[] = { configJson.c_str() };
jvmCallMain("com.amcl.launcher.AmclLauncher", 1, args);
```

### 5.3 phase_setProperties 的简化

大部分系统属性移到 Java 层 `AmclLauncher.setupSystemProperties()` 设置。
C 层只保留 JVM 级别的属性（os.name、java.library.path 等）。
Forge 特有属性（fml.earlyprogresswindow 等）完全由 Java 层处理。

### 5.4 user.home 问题的解决

```cpp
// C 层设置
setSystemProperty(env, "user.home", filesDir.c_str());  // 应用根目录
setSystemProperty(env, "user.dir", gameDir.c_str());     // 版本隔离目录
```

Java 层 `ForgeHelper.disableEarlyDisplay()` 在 MC main() 之前执行，
直接用 `System.getProperty("user.dir")` 获取 gameDir，在正确路径创建 fml.toml。
不再依赖 user.home 来定位 config 目录。

## 六、打包与部署

### amcl-launcher.jar 的构建

```
源码位置：MyApplication/JavaApp/src/com/amcl/launcher/
  ├── AmclLauncher.java
  ├── AmclClassLoader.java
  ├── LaunchConfig.java
  └── ForgeHelper.java

编译：javac -source 17 -target 17 *.java
打包：jar cf amcl-launcher.jar com/amcl/launcher/*.class
部署：放入 entry/src/main/resources/rawfile/amcl-launcher.jar
运行时：ensureRawFile 提取到 filesDir/amcl-launcher.jar
```

### 依赖

- 无外部依赖（纯 JDK 17 标准库）
- JSON 解析用 JDK 内置的简单字符串解析（避免引入 Gson 等库）
- 或用最小化的 JSON parser（< 200 行）

## 七、实施计划

### 阶段 1：基础框架（最小可用）
1. 创建 AmclLauncher.java + AmclClassLoader.java + LaunchConfig.java
2. 编译打包为 amcl-launcher.jar
3. 修改 C 层：jvmInit classpath 改为只含 amcl-launcher.jar
4. 修改 C 层：jvmCallMain 改为调用 AmclLauncher
5. 修改 ArkTS 层：LaunchProfile 序列化为 JSON
6. 验证：原版 MC 能正常启动

### 阶段 2：Forge 支持
1. 实现 ForgeHelper.disableEarlyDisplay()
2. 修改 C 层：user.home 改为 filesDir
3. 验证：Forge 能正常启动 + 版本隔离正确

### 阶段 3：清理与优化
1. 移除 C 层 jvmCallMain 中的 URLClassLoader fallback（不再需要）
2. 移除 LaunchProfileBuilder 中的 disableForgeEarlyDisplay（移到 Java 层）
3. 移除 C 层 phase_setProperties 中的 Forge 特有逻辑
4. 简化 filterJvmArgs（Forge 属性由 Java 层处理）

## 八、风险评估

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| AmclClassLoader 与 Forge Bootstrap 的 ClassLoader 冲突 | Forge 无法加载模组 | 测试 parent delegation 行为，必要时调整 |
| JSON 参数传递的字符串长度限制 | classpath 可能超长 | 用文件传递替代（写临时 JSON 文件） |
| amcl-launcher.jar 提取失败 | 启动失败 | 复用现有 ensureRawFile 机制 |
| JVM 重用时 AmclClassLoader 状态残留 | 第二次启动失败 | 每次创建新的 AmclClassLoader 实例 |
| Fabric 的 Knot ClassLoader 与 AmclClassLoader 冲突 | Fabric 无法启动 | 测试 Fabric 兼容性，必要时 Fabric 走旧链路 |

## 九、全面 Java 化可行性评估

### 9.1 不可替换的 C 层组件

| 组件 | 原因 | 结论 |
|------|------|------|
| ELF Loader | OHOS MAP_XPM 代码签名限制，系统 dlopen 拒绝未签名 .so | 必须保留 |
| JNI_CreateJavaVM | fork 子进程无法使用 XComponent surface，游戏必须在同一进程 | 必须保留 |
| sigchain handler | OHOS DFX 会拦截 SIGSEGV 杀进程，必须在 C 层注册 pre-JVM handler | 必须保留 |
| RegisterNatives | GLFW/OpenAL JNI 函数在 libentry.so 中，需要 C 层 env->RegisterNatives | 建议保留 |
| freopen IO 重定向 | Java System.setOut 只影响 Java 输出，native printf 需要 C 层 freopen | 建议保留 |

### 9.2 可以移到 Java 层的组件

| 组件 | 当前位置 | Java 化收益 | 风险 |
|------|----------|------------|------|
| System.setProperty | C 层 phase_setProperties | 时机更精确，Forge 预处理更灵活 | 低 |
| mainClass 加载与调用 | C 层 jvmCallMain | 动态 classpath，解决 JVM 重用问题 | 低 |
| fml.toml 创建 | ArkTS 层 disableForgeEarlyDisplay | 在 Java 层执行，路径一定正确 | 低 |
| Forge splash.properties | 未实现 | 和 Pojav 一致，禁用 Forge splash | 低 |
| classpath 动态加载 | C 层 URLClassLoader fallback | AmclClassLoader 更干净 | 中 |

### 9.3 替换系统 ClassLoader 的风险分析

Pojav 用 `-Djava.system.class.loader` 替换系统 ClassLoader。我们不这样做的原因：

1. Forge 的 securejarhandler 检查 ClassLoader 层级，替换可能破坏安全检查
2. Fabric 的 Knot ClassLoader 假设系统 ClassLoader 是标准 AppClassLoader
3. JDK ServiceLoader 等内部机制依赖系统 ClassLoader 行为
4. 调试 ClassLoader 问题极其困难（错误信息隐晦）

如果全面覆盖（替换系统 ClassLoader）：
- 优点：所有 Class.forName 自动走 AmclClassLoader
- 缺点：Forge/Fabric ClassLoader 层级被打乱，模组加载可能失败
- 结论：风险大于收益，不推荐

### 9.4 推荐方案：关键路径 Java 化

保留 C 层基础设施（ELF Loader、JVM 创建、sigchain、RegisterNatives、IO 重定向），
将启动逻辑的"最后一公里"移到 Java 层（属性设置、Forge 预处理、动态类加载、mainClass 调用）。

改动量：约 500 行 Java + 100 行 C 修改
可行性：85%（主要风险在 ClassLoader 兼容性）
收益：彻底解决 user.home、动态 classpath、Forge 预处理三大问题
