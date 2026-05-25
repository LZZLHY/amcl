# AMCL — Axe Minecraft Launcher for HarmonyOS NEXT

**简体中文** · [English](./README.md)

> 面向鸿蒙 HarmonyOS NEXT（华为手机 / 平板）的第三方 Minecraft Java 版启动器。

## 1. 项目简介

AMCL（**A**xe **M**inecraft **C**lient **L**auncher）是个人开发者发起的独立项目，目标是把未经修改的 Minecraft Java 版客户端运行在 HarmonyOS NEXT 上。整体方案直接基于 HarmonyOS NEXT C/C++ SDK 与 ArkTS UI 框架从零搭建，内嵌：

- 为 HarmonyOS NEXT (musl, aarch64) 交叉编译的 OpenJDK HotSpot 运行时（含定制 patch）
- GLFW → XComponent 兼容层
- MobileGlues GL → GLES 3.2 翻译层（运行于 Maleoon GPU）
- OpenAL Soft + OHAudio 音频栈
- 绕过 HarmonyOS `MAP_XPM`（不可写可执行内存）签名约束的自定义 ELF loader

项目处于 **v1.0 之前的活跃开发期**。本 `amcl-public` 仓库**仅托管公开文档与技术规范** —— 完整应用源代码暂存于私有仓库，**将在项目达到正式稳定版后再行开源**。

## 2. 适用范围

| 维度 | 支持范围 |
|---|---|
| 操作系统 | HarmonyOS NEXT，API 等级 20（SDK 6.0.0）或更新 |
| 设备 | 搭载 Maleoon 系列 GPU 的华为手机 / 平板（已在 HUAWEI Mate 70 上验证）|
| 游戏 | 仅 Minecraft Java 版（不支持基岩版，也无此规划）|
| 账户 | 微软正版登录（OAuth 2.0 Auth Code + PKCE；Xbox Live → XSTS → Mojang 链路）；离线账户仅用于开发调试 |
| 网络 | Mojang 官方服务器直连；BMCLAPI 镜像（需用户授权）|

AMCL 仅供持有 Minecraft Java 版正版账户的用户使用，**不分发** Minecraft 客户端 `.jar`，所有游戏文件在运行时从官方服务器下载。

## 3. 适配进度

### 3.1 模组加载器

| Loader | 状态 |
|---|---|
| 原版 Vanilla | ✅ 已支持 |
| Fabric | ✅ 已支持 |
| Forge | ✅ 已支持 |
| NeoForge | ❌ 暂不支持 —— 仅有数据层（模组浏览可用，安装服务未实现）|
| Quilt | ❌ 暂不支持 |
| OptiFine | ❌ 暂不支持 |

### 3.2 JDK 运行时

AMCL 提供两个为 HarmonyOS NEXT (musl, aarch64) 交叉编译的 OpenJDK 构建，运行时产物按需从专用资源仓的 GitHub Releases 下载到设备：

**JDK 仓库**：<https://github.com/LZZLHY/mc-ohos-resources/releases>

| 运行时 | Release tag | 资产 | 状态 |
|---|---|---|---|
| OpenJDK 17 | `v17.0.13-ohos-4` | `jdk17-ohos-full-v4.zip` (≈109 MB) | ✅ 稳定 |
| OpenJDK 21 | `v21.0.5-ohos-6` | `jdk21-ohos-full.zip` (≈113 MB) | ⚠️ 实验性 |

### 3.3 Minecraft 版本覆盖

MC 版本与 JDK 的映射沿用 Mojang 官方 `java-runtime` 配置（参考 [Minecraft Wiki](https://minecraft.wiki/w/Tutorial:Update_Java)）：

| MC 版本区间 | 需要 JDK | AMCL 适配状态 |
|---|---|---|
| ≤ 1.12.2 | Java 8 + LWJGL 2.x | ❌ 暂未适配 |
| 1.13 – 1.16.5 | Java 8 + LWJGL 3 | ❌ 暂未适配 |
| 1.17 | Java 16 | ❌ 暂未适配 |
| 1.18 – 1.20.4 | Java 17 | ✅ 已适配（已在 1.20.4 验证）|
| 1.20.5 – 1.21.x | Java 21 | ✅ 已适配（实验性）|
| 26.1 及之后 | Java 25 | ❌ 暂未适配 |

说明：

- 自 Minecraft Java 版 **26.1** 起，Mojang 官方启动器随包附带 Java SE 25。
- AMCL 会根据所选 MC 版本自动路由对应的 JDK（`autoSelectVersion`），亦可在设置中手动指定。

## 4. 未来展望

短期目标（向 v1.0 推进）：

- 交叉编译并集成 OpenJDK 8，打通 1.0 – 1.16.5 整个老版本生态（也是最大的传统 mod 库）
- 交叉编译 OpenJDK 16，覆盖 1.17 这一独立节点
- 将 LWJGL 2.x 移植到 HarmonyOS NEXT，支撑 1.13 以前仍使用 LWJGL 2 的客户端
- 实现 NeoForge 安装服务（数据层已就绪）
- 接入 Quilt / OptiFine
- 在 Mojang 26.x 快照节奏稳定后，交叉编译 OpenJDK 25，覆盖 26.1+

长期目标（对齐 HMCL / PCL2 等成熟桌面启动器）：

- 多账户金库 + HUKS AES-GCM-256 本地加密
- 皮肤 & 披风管理（预览、上传、切换）
- Modrinth + CurseForge 模组浏览与一键安装
- 资源包 / 光影包 / 存档 / 数据包一键安装
- 全量版本隔离（每个版本独立 `.minecraft`，独立 JVM 参数）
- 自定义虚拟按键布局 + 云同步
- 崩溃报告器（自动 JVM 线程转储与日志归集）
- 后台下载管理器（多镜像、多线程、断点续传）

## 5. 已知问题

首个公开预览版（`v1.0.0-alpha.1`，即本次 release）存在以下限制：

- **HAP 未签名。** 当前 release 为 DevEco Studio 默认未签名构建。真机安装需要：(a) 加入华为开发者计划并自签名；或者 (b) 等待我们后续发布由组织签名证书签好的再分发版本。
- **仅支持 HarmonyOS NEXT API 20**。更早的 ROM（API ≤ 19）会拒绝安装。
- **必须开启 `ALLOW_WRITABLE_CODE_MEMORY` ACL** 才能让定制 HotSpot 的 JIT 路径生效。未开启时 JDK 会回退到解释器模式，游戏能跑但 FPS 远低于预期。
- **微软正版登录 & HUKS 凭据加密处于 M2 里程碑，部分完成。** 当前构建仅可使用离线账户。
- **OpenJDK 21 路径标注为实验性。** 真 headless AWT（绕过 HarmonyOS NEXT 缺 X11 / Wayland 的方案）在已测试的代码路径稳定，但未覆盖全部用例，部分触发 `java.awt` 的模组可能抛异常。
- **GPU 支持当前仅覆盖 Maleoon 910 家族。** 其它华为芯片大概率可用但未验证。
- **MC 版本覆盖当前为 1.18 – 1.21.x。** 更早或 26.1+ 版本启动时会报"运行时缺失"错误。

## 6. 发布与下载

最新版本：**v1.0.0-alpha.1**（预发布）。

HAP 包作为本仓库的 GitHub release 资产发布，请前往 [Releases 页面](https://github.com/LZZLHY/amcl/releases) 下载。

## 7. 源代码开源策略

**当前仅本 `amcl-public` 仓库（文档与规范）开源。** 应用源代码在项目处于 v1.0 之前活跃开发期间保持私有，**将在首个稳定版发布后再行开源**。在此之前，本仓库是面向评审方、未来贡献者和其它想做类似 HarmonyOS JVM 移植的开发者的唯一公开入口。

## 许可

本仓库文档采用 [MIT License](./LICENSE) 协议发布。

"Minecraft" 是 Mojang Studios 的商标。AMCL 与 Mojang Studios、Microsoft Corporation、Xbox 均**无关联、无授权、无背书**。
