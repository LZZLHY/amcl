# AMCL 应用架构概览

AMCL 在 HarmonyOS NEXT 上管理并启动 Minecraft Java Edition。工程同时包含 ArkTS/ArkUI、Native C/C++、Java 启动层和第三方运行时输入；单独编译其中一层不能得到可运行的 HAP。

## 应用和游戏进程

[entry/src/main/ets/](../entry/src/main/ets/) 提供入口、页面、组件、系统窗口和运行时服务。EntryAbility 承载启动器界面；GameAbility 在 [entry/src/main/module.json5](../entry/src/main/module.json5) 中声明为 :game 私有进程内的单实例 Ability。游戏启动准备通过运行时快照把配置交给游戏进程，避免把两个进程的内存状态视为同一份状态。

| 模块 | 主要职责 |
|---|---|
| account | 账户数据、登录和账户选择 |
| commons | 公共类型、日志、文件与进程配置等基础能力 |
| feature_core | Minecraft 版本、下载和基础资源管理 |
| feature_system | 系统设置、偏好与运行环境能力 |
| gamecontrol | 输入、控制布局和产品运行策略 |
| launch | 游戏启动计划、JDK/运行时配置、兼容性处理 |
| mods | 模组及相关安装管理 |
| update | 应用更新与版本信息 |

这些模块以 HAR 组织，依赖关系由各模块的 oh-package.json5 定义。产品使用的页面和差异源码根由 [entry/build-profile.json5](../entry/build-profile.json5) 定义。

## Native 与 JVM

[entry/src/main/cpp/](../entry/src/main/cpp/) 包含以下主要部分：

- napi/：ArkTS 与 C/C++ 之间的调用入口。
- jvm/：加载 JDK、创建 JVM、冻结启动属性、交付 classpath 和启动 Minecraft。
- glfw/：面向 LWJGL 的窗口、输入、回调和 EGL 兼容层。
- input/、platform/：输入状态、系统窗口、图形 provider、设备能力与生命周期管理。
- download/：Native 下载能力，通过工程内的 libcurl 输入链接。
- openal/：OpenAL Soft 构建接入；上游源码由依赖准备步骤放入其 openal-soft/ 子目录。
- stubs/、third_party/、utils/：兼容实现、第三方头文件和公共工具。
- tests/：Native 测试及夹具，其中主机测试和设备相关测试的适用环境不同。

[entry/src/main/cpp/CMakeLists.txt](../entry/src/main/cpp/CMakeLists.txt) 决定实际的源文件、编译选项和链接目标。MobileGlues 从 prebuilt/mobileglues/mg_src/MobileGlues-cpp/ 接入编译图；MobileGL 是独立的 DSO，普通 HAP 使用 prebuilt/mobilegl/dist/ 中随快照保留并经校验的锁定输入，也保留独立源码重建配方。

[JavaApp/src/](../JavaApp/src/) 的 AmclLauncher、AmclClassLoader、LaunchConfig 和 ForgeHelper 等类在 JVM 内完成启动配置、类加载与兼容处理。[scripts/build-amcl-launcher.mjs](../scripts/build-amcl-launcher.mjs) 生成 amcl-launcher.jar，启动器主体采用 Java 8 目标字节码；同一构建入口还调用 [scripts/build-game-compat.py](../scripts/build-game-compat.py) 生成独立的 Fabric 兼容 JAR，该部分采用 Java 21 目标字节码。因此构建主机需要 JDK 21 或更高版本，不能从启动器的 Java 8 字节码目标推断主机只需要 JDK 8。

## 图形、音频与运行时输入

图形选择同时受产品、设备能力、游戏请求、库是否随包提供和实际窗口 provider 约束。MobileGlues、MobileGL、系统 OpenGL 与游戏 Vulkan 路线由共享的运行时配置和准入逻辑选择；携带某个库不表示每台设备或每个模组都能使用该路线。SDL3 与 GLFW 共享宿主窗口和输入契约，具体调用面仍按各自运行路径处理。

[config/products.json](../config/products.json) 定义 default、sideload、store 与 desktop 四个产品。default 用于开发，默认 debug；其余产品默认 release。desktop 只声明 2in1，其余产品声明 phone/tablet/2in1，store 另有分发设备约束。所有现役产品使用 graphicsArtifactSet=complete；MobileGL 的来源、dist 指纹和包内身份会在构建时检查。

[entry/libs/arm64-v8a/](../entry/libs/arm64-v8a/) 和 [entry/src/main/resources/rawfile/](../entry/src/main/resources/rawfile/) 中已纳入快照的 SO、JAR、证书包等是构建或运行时输入。Hvigor 在资源编译前准备产品资源、LWJGL 槽位和 Java 启动器；具体顺序见 [entry/hvigorfile.ts](../entry/hvigorfile.ts)。JDK 运行时压缩包、Minecraft 和模组资源另由应用的下载流程取得，不全部包含在源码仓库内。

## 阅读边界

本文件描述公开快照的结构。实际依赖来源和构建操作见 [CREDITS.md](CREDITS.md) 与 [BUILD_SNAPSHOT.md](BUILD_SNAPSHOT.md)。输入能力的默认编译配置还依赖 [gate0-evidence.lock](../gate0-evidence.lock) 和其引用的 [脱敏记录](testing/gate0-raw-relative-evidence.md)；它们保留原有批准与风险接受事实，并非新的设备验收。

公开快照不含原始设备日志。签名证书、独立设备验收和正式发布流程属于各开发者的构建及验证环境，不能由源码结构或脱敏记录推断其已完成。
