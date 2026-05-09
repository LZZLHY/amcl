# AMCL — Axe Minecraft Launcher for HarmonyOS NEXT

> Public design specs & technical documentation for AMCL, an open-source third-party Minecraft Java Edition launcher targeting **HarmonyOS NEXT** (Huawei mobile / tablet devices).

[English](#english) · [中文](#中文)

---

<a id="english"></a>

## What this repository is

This repository hosts the **technical design documents and project specifications** for AMCL. The application source code is currently kept in a private repository while the project is in pre-1.0 active development; it will be open-sourced after the first stable release. Documents here are intended for:

- Reviewers evaluating the project (e.g. Microsoft Minecraft API access review)
- Future contributors looking to understand the architecture
- Developers building similar HarmonyOS-based runtimes for legacy JVM workloads

## Project status

Minecraft Java Edition **1.20.4** has been launched and rendered successfully on real hardware:

| Subsystem | Status | Implementation |
|---|---|---|
| Rendering | Working | MobileGlues (GL → GLES translation) on Maleoon 910 GPU |
| Audio | Working | OpenAL Soft + OHAudio backend |
| Input | Working | XComponent `DispatchTouchEvent` + on-screen virtual keys |
| JVM | Working | OpenJDK 17.0.13-internal (HotSpot, 4 OHOS patches) |
| ELF loader | Working | Custom loader bypassing HarmonyOS MAP_XPM, JDK `.so` files served from `filesDir/jdk/<ver>/` |
| Microsoft sign-in | M2 in progress | OAuth 2.0 Authorization Code + PKCE; Xbox Live → XSTS → Mojang chain |
| Account encryption | M2 in progress | HUKS AES-GCM-256 at-rest |

**Test device**: HUAWEI Mate 70 · HarmonyOS NEXT API 20 · GPU: Maleoon 910 (OpenGL ES 3.2).

## Documentation

Start at [`docs/README.md`](docs/README.md) — that is the canonical document index.

Highlight pages:

- [`docs/architecture.md`](docs/architecture.md) — full architectural overview
- [`docs/JDK_ADAPTATION_GUIDE.md`](docs/JDK_ADAPTATION_GUIDE.md) — OpenJDK 17 patches for OHOS, ELF loader, signal-chaining
- [`docs/guides/genuine-login-and-account-system-plan.md`](docs/guides/genuine-login-and-account-system-plan.md) — Microsoft genuine login / Xbox Live / XSTS / Mojang chain plan
- [`docs/guides/openjdk_ohos_build_guide.md`](docs/guides/openjdk_ohos_build_guide.md) — cross-compiling OpenJDK in Docker
- [`docs/guides/download-system.md`](docs/guides/download-system.md) — multi-mirror, multi-thread download engine
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — milestones and pending items

## Architecture (one-screen view)

```
Minecraft Java Edition (vanilla 1.20.4 jar, unmodified)
        |
     LWJGL 3.3.3
        |
+----------+------------+----------+
|  GLFW    | MobileGlues| OpenAL   |
|  Compat  | (GL->GLES) | Soft     |
+----------+------------+----------+
|XComponent|  GLES 3.2  | OHAudio  |
|  + EGL   | (Maleoon)  |          |
+----------+------------+----------+
|         HarmonyOS NEXT API 20    |
+-----------------------------------+
|   OpenJDK 17 (HotSpot, 4 OHOS    |
|   patches, custom ELF loader)    |
+-----------------------------------+
```

## Compliance & legal notice

AMCL is an independent third-party launcher developed by individual contributors. It has **no affiliation, sponsorship, or endorsement** from Mojang Studios, Microsoft Corporation, or Xbox.

- "Minecraft" is a trademark of Mojang Studios.
- AMCL only launches Minecraft Java Edition installations the end-user has legally purchased through their own Microsoft account.
- AMCL does **not** redistribute Minecraft client `.jar` files. Game files are downloaded at runtime from official Mojang servers (or BMCLAPI mirror, with user consent).
- User credentials (Microsoft `access_token` / `refresh_token`, Mojang bearer tokens) are stored locally with HUKS AES-GCM-256 at-rest encryption and never leave the device.
- Adheres to the [Minecraft Java EULA](https://www.minecraft.net/en-us/eula).

## Contact

For Microsoft Minecraft API approval review or other inquiries, please open an issue in this repository.

---

<a id="中文"></a>

## 仓库说明（中文）

本仓库存放 AMCL 项目的**技术设计文档与规范**。项目源代码当前位于私有仓库，待 v1.0 稳定版发布后再行开源。文档面向：

- 评审方（如 Microsoft Minecraft API 访问审核）
- 未来想了解架构的潜在贡献者
- 在 HarmonyOS 上做类似 JVM 移植的开发者

## 项目状态

Minecraft Java Edition **1.20.4** 已在真机成功启动并渲染：

| 子系统 | 状态 | 实现 |
|---|---|---|
| 渲染 | ✅ 工作 | MobileGlues GL→GLES 翻译层 + Maleoon 910 GPU |
| 音频 | ✅ 工作 | OpenAL Soft + OHAudio 后端 |
| 输入 | ✅ 工作 | XComponent `DispatchTouchEvent` + 虚拟按键 |
| JVM | ✅ 工作 | OpenJDK 17.0.13-internal（HotSpot，4 个 OHOS patch）|
| ELF 加载器 | ✅ 工作 | 自定义 loader 绕过 HarmonyOS MAP_XPM，从 `filesDir/jdk/<ver>/` 加载 .so |
| 微软正版登录 | 🚧 M2 进行中 | OAuth 2.0 Auth Code + PKCE；Xbox Live → XSTS → Mojang 链路 |
| 凭据加密 | 🚧 M2 进行中 | HUKS AES-GCM-256 at-rest |

**测试设备**：HUAWEI Mate 70 · HarmonyOS NEXT API 20 · GPU: Maleoon 910 (OpenGL ES 3.2)

## 文档导航

请从 [`docs/README.md`](docs/README.md) 入口阅读。

重点文档：

- [`docs/architecture.md`](docs/architecture.md) — 架构全景
- [`docs/JDK_ADAPTATION_GUIDE.md`](docs/JDK_ADAPTATION_GUIDE.md) — JDK 适配（patch、信号链、ELF loader）
- [`docs/guides/genuine-login-and-account-system-plan.md`](docs/guides/genuine-login-and-account-system-plan.md) — 微软正版登录 + Xbox Live / XSTS / Mojang 链路设计
- [`docs/guides/openjdk_ohos_build_guide.md`](docs/guides/openjdk_ohos_build_guide.md) — Docker 交叉编译 OpenJDK
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — 待办与里程碑

## 合规与法务声明

AMCL 是个人独立开发的第三方启动器，**与 Mojang Studios / Microsoft / Xbox 无关联、无授权、无背书**。

- "Minecraft" 是 Mojang Studios 的商标
- AMCL 仅用于启动**用户自有的正版** Minecraft Java 版（用户通过自己的 Microsoft 账户购买）
- AMCL **不**分发 Minecraft 客户端 `.jar`；游戏文件在运行时从官方 Mojang 服务器（或 BMCLAPI 镜像，需用户同意）下载
- 用户凭据（Microsoft `access_token` / `refresh_token`、Mojang bearer token）通过 HUKS AES-GCM-256 本地加密存储，不上传任何第三方服务器
- 遵守 [Minecraft Java 版 EULA](https://www.minecraft.net/zh-hans/eula)
