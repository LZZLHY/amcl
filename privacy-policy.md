# AMCL 隐私政策

- 文档版本：v1.1
- 生效日期：2026 年 5 月 27 日
- 最近更新：2026 年 6 月 9 日

---

## 引言

欢迎使用 **AMCL（Axe Minecraft Client Launcher）**，以下简称"本应用"或"AMCL"。

AMCL 是面向 HarmonyOS NEXT 的第三方 Minecraft Java 版启动器，由独立开发者维护，全部代码与文档遵循开源协议（详见 [GitHub 仓库](https://github.com/LZZLHY/amcl)）。本应用与 Mojang Studios、Microsoft Corporation、Xbox、华为终端有限公司均无关联、无授权、无背书。

我们深知个人信息对您的重要性，并恪守"最小必要"原则。本隐私政策旨在以清晰、坦诚的方式向您说明：AMCL 在您使用过程中**会**和**不会**处理哪些信息、为什么需要、如何保护、以及您拥有哪些权利。

请您在使用本应用前完整阅读并充分理解本政策。**当您启动并继续使用 AMCL 时，即视为您已知悉并同意本政策的全部内容。** 如您不同意本政策的任何条款，请立即停止使用本应用并卸载。

---

## 一、本政策适用范围

本政策仅适用于您在 HarmonyOS NEXT 设备上安装并使用的 AMCL 应用本身（包名 `com.amcl.launcher`）。

本政策**不适用于**以下场景，相关数据处理由各自服务的隐私政策约束：

- 您通过 AMCL 启动的 **Minecraft Java 版游戏本体**（由 Mojang Studios 提供，[Mojang 隐私政策](https://www.minecraft.net/en-us/privacy)）；
- 您通过 AMCL 接入的 **微软账户登录服务**（由 Microsoft 提供，[Microsoft 隐私声明](https://privacy.microsoft.com/zh-cn/privacystatement)）；
- 您通过 AMCL 接入的 **Mojang / Xbox Live 鉴权服务**；
- 您主动启用的 **第三方下载镜像**（如 BMCLAPI，由其各自维护方运营）；
- 您安装的任何 **Minecraft 模组（mod）/ 资源包 / 光影包**；
- 您从 GitHub Release 下载的、由 AMCL 项目维护者发布的 **OpenJDK 运行时资源包**（其源代码与构建脚本同样开源，详见仓库 `docker/` 目录）。

---

## 二、我们收集与处理哪些信息

### 2.1 我们**不**收集的信息

我们郑重承诺，AMCL 客户端**不**收集、上传或共享以下任何信息至开发者控制的服务器：

- ❌ 您的设备唯一标识符（IMEI、AAID、OAID、Android ID、UDID 等）
- ❌ 您的位置信息（GPS、Wi-Fi、基站）
- ❌ 您的通讯录、短信、通话记录、日历
- ❌ 您的相册、媒体文件
- ❌ 您的麦克风、摄像头数据
- ❌ 您的剪贴板内容
- ❌ 应用使用统计、行为埋点、崩溃遥测
- ❌ 您安装的其它应用列表
- ❌ 您在游戏中的存档、聊天内容、玩家行为

**AMCL 没有自有服务器，不向任何开发者控制的第三方传输任何用户数据。**

### 2.2 在您设备本地处理的信息

AMCL 为完成启动器核心功能，会在**您的设备本地**处理以下信息。这些信息**仅存储在您的设备**上，不离开您的设备（除非该信息根据其本身性质必须被发往对应官方服务器，详见 §2.3）。

| 信息类别 | 内容 | 存储位置 | 用途 |
|---|---|---|---|
| 微软账户凭据 | OAuth 2.0 access token、refresh token、Mojang access token、Xbox UserHash、Minecraft 玩家 UUID 与昵称 | 应用沙箱 `filesDir`，使用 HarmonyOS HUKS 加密保护（AES-GCM-256） | 实现微软正版登录与游戏内身份鉴权 |
| 离线账户信息 | 您自行输入的玩家昵称（仅本地） | 应用沙箱 `filesDir` | 仅用于开发调试场景的离线启动 |
| 启动器配置 | 已安装的 MC 版本列表、JVM 参数、虚拟按键布局、镜像源选择、UI 偏好 | 应用沙箱 `filesDir` | 保留您的启动偏好，下次启动时自动恢复 |
| 游戏文件 | Minecraft 客户端 jar、资源、模组、存档、`options.txt` 等 | 应用沙箱 `filesDir/.minecraft/` | 启动并运行 Minecraft Java 版本身的需要 |
| OpenJDK 运行时 | 从 GitHub Release 下载的 OpenJDK `.so` 库及配套数据 | 应用沙箱 `filesDir/jdk/<version>/` | 提供 Java 字节码执行环境 |
| 运行日志 | `mc_output.log`、`mc_error.log`、AMCL 自身日志 | 应用沙箱 `filesDir` | 帮助您本地排查启动失败、崩溃等问题 |

**说明**：以上"应用沙箱"指 HarmonyOS 为本应用分配的私有目录，其它应用与第三方无法直接访问。卸载本应用时，HarmonyOS 系统会清理该目录。

### 2.3 因功能必需而发往**第三方官方服务器**的信息

为完成 Minecraft Java 版的启动与正版鉴权，AMCL 会**直接**与下列第三方官方服务器通信。这些通信**不经过任何 AMCL 开发者控制的中间服务器**。所传输的信息和用途如下：

| 第三方端点 | 域名 | 传输内容 | 触发场景 |
|---|---|---|---|
| Microsoft 身份平台 | `login.microsoftonline.com`、`login.live.com` | 您发起的 OAuth 2.0 授权码、PKCE code_verifier、客户端 ID | 您在 AMCL 内点击"微软账户登录"时 |
| Xbox Live 鉴权 | `user.auth.xboxlive.com`、`xsts.auth.xboxlive.com` | Microsoft 颁发的 access token、Xbox UserHash | 您在 AMCL 内完成微软登录后的鉴权链路 |
| Mojang 鉴权与 Profile | `api.minecraftservices.com`、`sessionserver.mojang.com` | XSTS token、Mojang access token、玩家 UUID | 完成正版登录、获取玩家档案、游戏内进入服务器时的鉴权 |
| Mojang 资源服务器 | `launcher.mojang.com`、`launchermeta.mojang.com`、`piston-meta.mojang.com`、`piston-data.mojang.com`、`libraries.minecraft.net`、`resources.download.minecraft.net` | 仅 HTTP 请求，包含您要下载的版本号、文件路径 | 您选择安装某个 MC 版本或其依赖时 |
| GitHub Release | `github.com`、`objects.githubusercontent.com` | 仅 HTTP 请求，包含资源 tag 与文件名 | 您首次启动选择某个 JDK 版本，或安装 LWJGL 资源时 |
| BMCLAPI 镜像（可选） | `bmclapi2.bangbang93.com` 等 | 仅 HTTP 请求，包含您要下载的 MC 资源路径 | **仅当您主动在设置中启用镜像源时** |
| Modrinth / CurseForge（规划中） | 待对应模组浏览功能上线时启用 | 仅 HTTP 请求，包含您搜索的模组名 | 仅当您主动使用模组浏览功能时 |

以上所有通信均通过 HTTPS（TLS 1.2 及以上）进行，使用本应用内置的、与 Mozilla CA bundle 同源的根证书集合（约 220 KB，随 HAP 一同打包），**不会**因任何原因关闭证书校验。

**重要**：上述第三方服务在收到您的请求后，可能会按其自身隐私政策记录您的 IP 地址、User-Agent 等访问元数据。这些数据由第三方控制，AMCL 既不接收也不二次处理。

### 2.4 资源完整性校验

为防止下载源被篡改，AMCL 对从 GitHub Release 下载的 OpenJDK 资源包执行强制 **SHA-256** 校验。校验值随应用版本固化在源代码中。哈希不匹配时，文件会被自动删除并拒绝加载。

---

## 三、我们如何使用您的信息

我们仅在以下范围内使用 §2.2 所列的本地数据：

1. **完成核心功能**：登录、启动游戏、保存配置、加载已下载资源；
2. **提升用户体验**：记住您上次使用的版本、语言、按键布局；
3. **排查本地问题**：在您主动查看日志时，向您本人展示崩溃堆栈；
4. **保障应用安全**：通过 SHA-256 校验防止资源被篡改；通过 HUKS 加密保护账户凭据。

我们**不会**：

- 将您的信息用于任何形式的商业广告、画像、推荐；
- 将您的信息出售、出租、分享、披露给任何第三方（依法配合监管要求的除外）；
- 在未取得您明示同意的情况下扩展上述用途。

---

## 四、申请的系统权限

AMCL 在 `module.json5` 中声明的系统权限**完整列表**如下：

| 权限名 | 授权方式 | 用途 | 不授予的影响 |
|---|---|---|---|
| `ohos.permission.INTERNET` | 普通权限（无弹窗） | 与 §2.3 所列第三方官方服务器通信，下载 OpenJDK / MC 资源、完成正版登录 | 完全无法使用本应用 |
| `ohos.permission.VIBRATE` | 普通权限（无弹窗） | 游戏内虚拟按键的轻触触觉反馈 | 仅失去按键震动反馈，不影响功能 |
| `ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY` | 运行时弹窗授权 | 可选功能：将游戏数据 `.minecraft` 存到公共「下载」目录，使其卸载应用后仍保留（仅你在设置中主动开启时申请） | 不影响默认沙箱存储；不开启此功能即不申请 |
| `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY` | 受限权限 / 系统静默授予（无弹窗） | 内嵌的 OpenJDK 运行时（HotSpot JIT）需要可写可执行内存以提升 Java 执行效率。**该权限仅在平板 / 2in1 设备可用** | 无此权限时 Java 仅能解释执行，游戏帧率显著下降甚至无法流畅运行 |
| `ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY` | 受限权限 / 系统静默授予（无弹窗） | 配合上一项，允许系统 JS 引擎以 MAP_FORT 申请匿名可执行内存进行 JIT 编译。同为平板 / 2in1 受限权限 | 同上 |

> **关于平台支持**：上述两项 `kernel.ALLOW_*` 受限权限**仅平板 / 2in1 设备可用**（华为不允许手机应用使用 JIT 可执行内存），因此 AMCL 经应用市场分发的版本**仅面向平板 / 2in1 设备**；手机用户请使用侧载渠道。这两项权限为系统静默授予（system_grant），不会向你弹窗，也不读取任何个人信息——它们只影响内存的执行属性，与数据收集无关。

我们承诺**不会**在不告知您的前提下追加权限。任何后续版本若新增权限，会在本政策更新记录中明确披露。

> **关于 ELF Loader 与受限权限**：
> AMCL 包含一个自实现的 ELF 动态库加载器，用于加载从 GitHub Release 下载到沙箱的 OpenJDK 运行时（绕过 HarmonyOS 内核 `MAP_XPM` 对沙箱内可执行内存的代码签名约束）。该加载器**仅**加载经 SHA-256 校验的、由项目维护者在公开 Docker 容器中编译产出的 OpenJDK 二进制，**不**提供任意 URL 下载并执行代码的能力，**不**加载用户自带的 `.so`，**不**访问任何额外系统能力。上述 `kernel.ALLOW_*` 权限服务于同一目的（让 JIT 编译出的机器码可执行），其合规边界与工程约束详见项目源代码仓库中的相应安全文档。

---

## 五、第三方组件与开源协议

AMCL 内嵌多个开源组件，它们运行在您的设备本地，**不向任何远端服务器汇报数据**。完整清单如下：

| 组件 | 用途 | 协议 | 上游 |
|---|---|---|---|
| OpenJDK HotSpot（17/21）| Java 运行时（含 AMCL 自维护 patch） | GPL-2.0 with Classpath Exception | [openjdk/jdk17u](https://github.com/openjdk/jdk17u) / [openjdk/jdk21u](https://github.com/openjdk/jdk21u) |
| LWJGL 3 | OpenGL / OpenAL / GLFW 的 Java 绑定 | BSD-3-Clause | [LWJGL/lwjgl3](https://github.com/LWJGL/lwjgl3) |
| MobileGlues | OpenGL → OpenGL ES 翻译层 | LGPL-2.1 | [MobileGlues](https://github.com/MobileGlues/MobileGlues) |
| OpenAL Soft | 软件 3D 音频渲染 | LGPL-2.1 | [kcat/openal-soft](https://github.com/kcat/openal-soft) |
| libcurl | HTTPS 客户端 | curl license（MIT 派生） | [curl/curl](https://github.com/curl/curl) |
| JNA | Java native 桥接 | Apache-2.0 / LGPL-2.1 | [java-native-access/jna](https://github.com/java-native-access/jna) |

以上组件均为成熟开源软件，源代码可公开审计。AMCL 未集成任何"统计 SDK"、"广告 SDK"、"推送 SDK"或类似具备数据采集能力的商业 SDK。

---

## 六、信息存储与保留

- **存储位置**：所有 AMCL 写入的文件均位于 HarmonyOS 为本应用分配的私有沙箱（`filesDir`、`cacheDir`），位于您本人的设备本地。
- **存储期限**：直至您主动卸载本应用、清除应用数据，或在 AMCL 内主动执行"删除版本"、"退出账号"等操作。
- **加密**：账户凭据使用 HarmonyOS **HUKS（Universal Keystore Kit）** 进行 AES-GCM-256 加密；密钥由 HUKS 在系统级 TEE/SE 中保护，应用代码无法直接读取明文密钥。
- **跨境传输**：AMCL 不会将您的信息从您的设备主动传输至境外。但您主动选择登录微软账户或下载 Mojang 资源时，相关请求按其性质会发往 Microsoft / Mojang 在境外的服务器，这是 Minecraft Java 版本身的固有要求。

---

## 七、您的权利

依据《个人信息保护法》及相关法律法规，您对自己的个人信息拥有如下权利。AMCL 已在应用内或通过卸载机制为您提供相应能力：

| 您的权利 | 在 AMCL 中如何行使 |
|---|---|
| **知情权** | 阅读本政策；查看应用内的"关于"页面 |
| **查询权** | 您可在沙箱浏览器或 hdc 中查看 `filesDir` 下的全部本地数据 |
| **更正权** | 在 AMCL 设置中修改昵称、版本配置、镜像源等 |
| **删除权** | 在 AMCL 内"账号管理"中点击退出登录可清除本机凭据；卸载应用会触发 HarmonyOS 自动清理沙箱 |
| **撤回同意权** | 您可随时通过卸载本应用撤回对本政策的同意 |
| **可携带权** | `filesDir/.minecraft` 与配置文件均为标准格式，您可自行备份至其它设备 |
| **投诉权** | 通过本政策第十节的联系方式与我们沟通 |

---

## 八、未成年人保护

AMCL 是一款面向 Minecraft Java 版玩家的工具应用，预期用户年龄分级为 **8 岁及以上**。

- 我们**不会**主动收集 14 周岁以下未成年人的个人信息；
- 若您是未成年人，请在监护人指导下使用本应用，并阅读本政策；
- 若监护人发现未成年人未经同意使用了本应用并产生本地数据，可通过卸载应用清除全部本地数据；
- AMCL 内置的"微软账户登录"由 Microsoft 提供，对未成年人账号的保护遵循 Microsoft 家庭账户与 Xbox Family Settings 规则。

---

## 九、本政策的更新

我们可能根据法律法规变化、本应用功能调整等原因更新本政策。重要更新会通过以下方式告知您：

- 在 AMCL 应用启动页弹出更新提示；
- 在本仓库 [GitHub Pages](https://lzzlhy.github.io/amcl/privacy-policy) 发布新版本；
- 在应用市场版本说明中标注。

每次更新均会在文档顶部"最近更新"字段标注日期。继续使用即视为您接受更新后的政策；如您不接受，请停止使用并卸载本应用。

历史版本可通过 [GitHub 提交记录](https://github.com/LZZLHY/amcl/commits/main/docs/privacy-policy.md) 查阅。

---

## 十、联系方式

如您对本政策有任何疑问、意见或投诉，或希望行使第七节列出的任何权利，可通过以下渠道与我们联系：

- **GitHub Issues**（推荐）：<https://github.com/LZZLHY/amcl/issues>
- **个人信息保护负责人邮箱**：<3185300855@qq.com>
- **通讯地址**：如需邮寄请先通过上述邮箱联系开发者获取地址

我们将在收到您的请求后 **15 个工作日** 内做出回应。

---

## 十一、适用法律

本政策的解释、效力及与本政策有关的争议，适用 **中华人民共和国** 法律（不含港澳台地区法律）。如发生争议，您与我们应首先友好协商；协商不成的，任一方均可向开发者实际居住地有管辖权的人民法院提起诉讼。

---

## 附录：术语

- **AMCL**：本应用的简称，全称 Axe Minecraft Client Launcher。
- **HarmonyOS NEXT**：华为终端有限公司发布的、不再兼容 Android 的纯鸿蒙操作系统。
- **HAP**：HarmonyOS Ability Package，HarmonyOS 应用安装包格式。
- **沙箱**：操作系统为每个应用分配的私有数据目录，仅本应用可读写。
- **HUKS**：HarmonyOS Universal Keystore Kit，鸿蒙系统级密钥管理服务。
- **OAuth 2.0 / PKCE**：行业标准授权码流程，用于在不暴露用户密码的前提下获取 access token。
- **OpenJDK**：开源的 Java 标准实现，AMCL 使用其 HotSpot 虚拟机。
- **MAP_XPM**：HarmonyOS 内核对应用沙箱内可执行内存的代码签名约束机制。
- **SHA-256**：广泛使用的密码学哈希函数，用于校验文件完整性。

---

> 本隐私政策的可读源代码托管于 <https://github.com/LZZLHY/amcl/blob/main/docs/privacy-policy.md>，与应用商店所示版本严格一致。
