# AMCL MyApplication 公开代码快照

本目录是面向 HarmonyOS NEXT 的 AMCL 应用工程。公开仓库根目录同时承载应用更新清单与版本记录；在 DevEco Studio 中导入工程时，请选择本目录。

首次构建请按 [docs/BUILD_SNAPSHOT.md](docs/BUILD_SNAPSHOT.md) 操作。该文档提供克隆、工具链配置、依赖准备、构建、结果检查和故障定位的完整顺序。

## 工程内容

| 路径 | 内容 |
|---|---|
| [entry/](entry/) | ArkTS/ArkUI 应用、产品差异源码、Native NAPI 桥接和 HAP 资源 |
| account/、commons/、feature_core/、feature_system/、gamecontrol/、launch/、mods/、update/ | 账户、公共能力、版本与下载、设置、操控、启动、模组和更新 HAR 模块 |
| [JavaApp/src/](JavaApp/src/) | JVM 内的启动器、classloader、版本兼容与辅助 Java 源码 |
| [prebuilt/](prebuilt/) | 第三方配方、补丁、来源清单及随快照保留的构建输入；上游大型源码通过 Git 子模块或准备脚本获取 |
| [entry/libs/arm64-v8a/](entry/libs/arm64-v8a/) | 已纳入快照的第三方 Native 输入，不能当作普通缓存批量删除 |
| [prebuilt/mobilegl/dist/](prebuilt/mobilegl/dist/) | 普通 HAP 使用的锁定 MobileGL 两份库与构建来源记录，无需先从源码重编 |
| [docker/](docker/)、[scripts/](scripts/)、[tools/](tools/) | 构建配方、资源生成器、检查脚本和开发辅助工具 |
| [config/products.json](config/products.json)、[deps.lock](deps.lock)、[toolchain.lock](toolchain.lock) | 产品定义、第三方依赖身份和工具链基线 |
| [SOURCE_SNAPSHOT.json](SOURCE_SNAPSHOT.json) | 源仓库提交、同步时的工作区状态、快照文件清单与 SHA-256 |
| [gate0-evidence.lock](gate0-evidence.lock)、[脱敏输入能力记录](docs/testing/gate0-raw-relative-evidence.md) | 默认 Native 配置所需的能力批准与文档身份输入；保留原风险接受事实及未闭合缺口 |
| [docs/](docs/) | 为公开快照编写的架构、构建与来源说明 |

仓库根目录的 [.gitmodules](../.gitmodules) 和 Git 索引共同记录本工程三个上游子模块；[deps.lock](deps.lock) 补充版本、源码与产物指纹。不要只复制本目录而丢失外层 Git 仓库，也不要把依赖的默认分支当作锁定版本。

## 构建范围

公开快照保留应用源码、必要脚本、运行时资源和第三方适配材料，不携带作者的证书、私钥、密码、IDE/Agent 配置、设备原始日志与本地构建缓存。构建 HAP 需要自行安装 HarmonyOS 工具链，并通过构建说明准备第三方源码；安装签名包还需要开发者自己的签名配置。

快照仅包含构建所需的脱敏输入能力记录，不包含原始设备日志。Gate 0 文件保留原批准状态、日期、G1–G7 未闭合缺口和风险接受事实，脱敏导出不构成新的设备验收。该锁及其引用文档是默认 Native 构建的必要输入，不能当作可选历史记录删除。

项目内的 build-hap.ps1 是主开发仓库的完整验收与发布入口，包含依赖内部证据文档和源仓库状态的检查。公开快照的常规工程构建采用构建说明中的 DevEco/Hvigor 入口。编译成功不等于所有设备和游戏版本都已通过运行验证，也不等于重现官方签名 Release 的字节内容。

## 阅读与许可

- [架构概览](docs/architecture.md)：源码职责、游戏进程和 JVM/Native 链路。
- [构建说明](docs/BUILD_SNAPSHOT.md)：从克隆到 HAP 的操作步骤及第三方重建范围。
- [第三方组件说明](docs/CREDITS.md)：依赖来源、补丁与产物的查找入口。
- [LICENSE](LICENSE) 与 [NOTICE](NOTICE)：AMCL 自有代码的 GPL-3.0-only 条款和第三方边界。

第三方文件保留各自许可和版权归属；目录所在位置、文件扩展名或随 HAP 打包都不会改变它们的第三方属性。
