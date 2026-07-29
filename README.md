<div align="center">
  <img src="./assets/agc-icon-216.png" width="128" height="128" alt="AMCL 图标">
  <h1>AMCL</h1>
  <p><strong>Axe Minecraft Launcher</strong></p>
  <p>面向 HarmonyOS NEXT 的第三方 Minecraft Java 版游戏管理器与启动器</p>
  <p>
    <img src="https://img.shields.io/badge/HarmonyOS-NEXT-008577?style=flat-square" alt="HarmonyOS NEXT">
    <img src="https://img.shields.io/github/stars/LZZLHY/amcl?style=flat-square&label=stars" alt="GitHub stars">
    <img src="https://img.shields.io/badge/Version-1.0.1-f29d38?style=flat-square" alt="Version 1.0.1">
  </p>
  <p><strong>简体中文</strong> · <a href="./README.en.md">English</a></p>
  <p>
    <a href="https://github.com/LZZLHY/amcl/releases/latest">下载最新版本</a> ·
    <a href="https://amcl.lovedhy.cn/docs/install-hokit">HoKit 安装指南</a> ·
    <a href="https://lzzlhy.github.io/amcl/">项目主页</a> ·
    <a href="https://lzzlhy.github.io/amcl/privacy-policy/">隐私政策</a> ·
    <a href="https://github.com/LZZLHY/amcl/issues">问题反馈</a>
  </p>
</div>

## 当前状态

| 项目 | 状态 |
|---|---|
| 最新稳定版 | **1.0.1**（versionCode `1000450`，2026-07-29） |
| 当前开发版本 | **1.0.2**（开发中） |
| 发布格式 | unsigned HAP，通过 GitHub Releases 发布 |
| 目标平台 | HarmonyOS NEXT，手机 / 平板 / 2in1 |
| 游戏类型 | Minecraft Java Edition |
| 内置运行时 | OpenJDK 8 / 17 / 21 / 25（HarmonyOS aarch64） |

AMCL（**Axe Minecraft Launcher**）由独立开发者维护，使用 ArkTS、HarmonyOS C/C++ SDK 与自研原生兼容层，让未经修改的 Minecraft Java 版客户端能够在 HarmonyOS NEXT 上运行。

本 `amcl-public` 仓库是 AMCL 的公开发布入口，托管 Release、更新清单、项目说明和隐私政策。应用源码不在本仓库中，后续公开安排以项目公告为准。

## 主要能力

### 游戏版本与加载器

- 安装和启动 Vanilla、Fabric、Forge 与 NeoForge 游戏实例。
- 同时提供 LWJGL 2 与 LWJGL 3 兼容路径，覆盖旧版与新版 Minecraft。
- 根据游戏版本自动选择 OpenJDK 8 / 17 / 21 / 25，也可在设置中手动调整。
- 支持版本隔离、独立 JVM 参数、游戏语言和存储位置配置。

### 账户与安全

- Microsoft 正版账户登录（OAuth 2.0 + PKCE、Xbox Live / XSTS / Mojang 链路）。
- 离线账户与 authlib-injector 第三方皮肤站账户。
- 敏感凭据使用 HarmonyOS HUKS AES-GCM-256 在设备本地加密。
- JDK 等关键运行时资源在使用前执行 SHA-256 完整性校验。

### 模组、资源与整合包

- 集成 Modrinth 与 CurseForge 浏览、搜索和安装。
- 支持模组依赖解析、兼容性提示、资源包和整合包安装。
- 支持公共下载目录存储；是否可用取决于设备授权与系统能力。

### 下载与诊断

- 统一下载管理器支持多镜像、并行分段、断点续传、任务取消与重试。
- 1.0.1 集中修复了 JDK 下载失败、尾段重复下载、取消后无法重试及 NeoForge 安装长时间停顿。
- 提供活动日志、网络诊断和本地游戏日志，便于定位安装与启动问题。

### 触控与布局

- 面向触屏重新设计的摇杆、按键、物品栏直点与菜单输入。
- 可视化布局编辑器支持吸附对齐、多选批量编辑、手机/平板预设和真实比例预览。
- 布局可导入、导出和通过 HarmonyOS 系统分享面板分享，也可从系统“打开方式”直接导入 JSON。

## 兼容范围

| 项目 | 当前状态 |
|---|---|
| Vanilla | 已支持 |
| Fabric | 已支持 |
| Forge | 已支持 |
| NeoForge | 已支持 |
| Quilt | 暂无内置一键安装流程 |
| OptiFine | 暂无内置一键安装流程 |
| Minecraft Bedrock Edition | 不支持 |

不同 Minecraft 版本、模组和设备驱动的组合很多，表中的“支持”表示 AMCL 已具备对应安装与启动链路，不代表所有第三方模组均经过验证。遇到问题请附上版本信息、操作步骤与相关日志提交 [Issue](https://github.com/LZZLHY/amcl/issues)。

## 下载与安装

1. 打开 [最新 Release](https://github.com/LZZLHY/amcl/releases/latest)。
2. 下载文件名以 `-unsigned.hap` 结尾的资产；1.0.1 对应 `amcl-v1.0.1-unsigned.hap`。
3. 按 [HoKit 安装指南](https://amcl.lovedhy.cn/docs/install-hokit) 完成签名和侧载。
4. 首次启动后按提示下载所需 JDK 与游戏资源。

> GitHub Release 提供的是 unsigned HAP。部分 JIT 能力依赖 HarmonyOS 受限权限，侧载包和不同设备上的实际能力可能存在差异。

## 1.0.1 紧急修复

- 修复 JDK 下载失败、卡住及取消后重试无响应。
- 修复下载尾段异常重下和 NeoForge 安装长时间停顿。
- 优化断点续传、动态分段调度、镜像健康判断与慢尾接管。
- 保留旧版 `v1.0.0` Release，便于校验与回溯。

完整资产与发布说明见 [AMCL v1.0.1](https://github.com/LZZLHY/amcl/releases/tag/v1.0.1)。

## 技术组成

- ArkTS / ArkUI：应用界面、状态管理与系统能力集成。
- HarmonyOS C/C++ SDK：游戏窗口、输入、音频、网络和 JVM 启动链路。
- OpenJDK HotSpot：针对 HarmonyOS NEXT（musl, aarch64）维护的运行时构建。
- GLFW → XComponent 兼容层、MobileGlues OpenGL → OpenGL ES 翻译层。
- OpenAL Soft + OHAudio 音频栈。
- 自研 ELF Loader：加载经过完整性校验的 JDK 原生库。

## 仓库内容

| 文件 | 用途 |
|---|---|
| [`update.json`](./update.json) | 应用内更新检查清单 |
| [`privacy-policy.html`](./privacy-policy.html) | 隐私政策与 GitHub Pages 页面 |
| [`index.html`](./index.html) | 中文优先、可切换英文的项目主页 |
| [`README.en.md`](./README.en.md) | 英文项目说明 |
| [`LICENSE`](./LICENSE) | 公开文档许可 |

## 说明与许可

- AMCL 不分发 Minecraft 客户端 JAR；游戏文件由用户设备按需从 Mojang 或用户选择的镜像下载。
- “Minecraft”是 Mojang Studios 的商标。AMCL 与 Mojang Studios、Microsoft Corporation、Xbox、网易公司和华为终端有限公司均无关联、无授权、无背书。
- 本仓库中的公开文档采用 [MIT License](./LICENSE)。各第三方组件遵循其各自许可证。
