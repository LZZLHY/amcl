<div align="center">
  <img src="./assets/agc-icon-216.png" width="112" height="112" alt="AMCL 图标">
  <h1>AMCL · Axe Minecraft Launcher</h1>
  <p>在 HarmonyOS NEXT 设备上运行 Minecraft Java Edition</p>
  <p><strong>简体中文</strong> · <a href="README.en.md" lang="en">English</a></p>
  <p><a href="https://amcl.lovedhy.cn/download">官网下载</a> · <a href="https://github.com/LZZLHY/amcl/releases/latest">GitHub 稳定版</a> · <a href="https://amcl.lovedhy.cn/docs/getting-started">快速开始</a> · <a href="docs/compatibility-and-feedback.md">兼容性与故障反馈</a></p>
</div>

AMCL 是面向鸿蒙手机、平板和电脑的 Minecraft Java 版启动器。你可以在设备上下载游戏、安装模组、管理不同版本的存档和配置，再用触控布局或实体键鼠进入世界。游戏在设备本机的 OpenJDK 中运行。

## 第一次进入游戏

1. **安装通用侧载包。** 在官网下载页选稳定版，或在 GitHub 稳定版的附件里下载名称含 `sideload` 和 `unsigned.hap` 的文件。首次安装需要用自己的签名将 HAP 装到设备上，官网有带截图的操作步骤。想体验预览版时，可在发行列表中找标有 **Pre-release** 的版本。[侧载安装图文](https://amcl.lovedhy.cn/docs/install-hokit) · [全部发行版本](https://github.com/LZZLHY/amcl/releases)
2. **选择游戏账号。** 点首页的头像或用户名打开账号列表，可以添加微软正版账户、第三方皮肤站账户，或创建用于本地游玩的离线账户。
3. **下载一个游戏版本。** 在「下载 → 版本」选一个 Minecraft 正式版。第一次可以保留「原版」，点「开始下载」。想玩模组时，再按模组要求为实例选择游戏版本和加载器。
4. **启动并准备 Java。** 回首页选中刚装好的版本，点「启动游戏」。如果启动前检查提示缺少 Java，就点它推荐的下载按钮，例如「一同下载 JDK 21」。也可以提前在「下载 → JDK」安装。AMCL 提供适配鸿蒙的 OpenJDK 8、17、21、25，按实例需要下载，独立于启动器更新。[Java 运行时目录](https://amcl.lovedhy.cn/runtimes)

## 模组、整合包与操控

- **搭配自己的模组。** 可以安装 Fabric、Forge 或 NeoForge，再从 Modrinth、CurseForge 浏览匹配的模组、光影和资源包。已有整合包也可以导入为游戏实例，之后单独管理其中的模组和配置。
- **在触屏上安排按键。** 手机和平板可以编辑虚拟按键布局，调整摇杆、视角和按键组，也可以导入其他玩家分享的方案。通用包在鸿蒙电脑上提供键鼠交互。[按键方案与导入说明](https://amcl.lovedhy.cn/docs/controls-market)
- **查自己的组合能否运行。** 游戏版本、Java、加载器、模组和图形后端都会影响结果。指南列出了在具体设备上完成建档和读档的组合，也说明了启动检查失败、进世界黑屏或闪退时该看哪一次日志。[兼容性与故障反馈指南](docs/compatibility-and-feedback.md)

## 源码与贡献

启动器界面使用 ArkTS 和 ArkUI。启动游戏时，AMCL 准备游戏及依赖并创建 JVM，Java 启动层加载 Minecraft。窗口和输入通过 GLFW 或 SDL 等适配接入鸿蒙，图形层按设备和游戏选择后端，游戏声音通过 OpenAL Soft 接入 OHAudio。[应用架构](MyApplication/docs/architecture.md)

公开应用工程位于 `MyApplication/`。维护者随版本发布同步源码和构建输入，每次快照的应用版本及来源提交可在清单中核对。欢迎提交复现步骤、文档改进和代码修复。[快照清单](MyApplication/SOURCE_SNAPSHOT.json) · [从源码构建](MyApplication/docs/BUILD_SNAPSHOT.md) · [贡献指南](CONTRIBUTING.md) · [GitHub Issues](https://github.com/LZZLHY/amcl/issues)

AMCL 自有代码采用 GPL-3.0-only，第三方组件保留各自的许可与版权。AMCL 与 Mojang、Microsoft、网易及华为无关联或背书。[许可证](LICENSE) · [第三方来源与许可](MyApplication/docs/CREDITS.md) · [NOTICE](MyApplication/NOTICE)

本 README 由 AI 编写。
