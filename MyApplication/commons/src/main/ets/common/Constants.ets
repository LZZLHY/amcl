/**
 * Constants.ets — 全局常量定义
 *
 * 统一管理颜色、字体大小、间距、运行时版本策略等常量，避免硬编码。
 */

// ===== 运行时版本策略（全局唯一定义，其他文件 import 使用） =====
//
// 历史：项目曾 hardcode 锁到 JDK 17 一个版本，避免误用未上线运行时；
// 2026-05-18 起 JDK 21 真 patch 移植完成 + 真机回归通过 →  解锁。
//
// 现在的策略：
//   - SUPPORTED_JDK_VERSION       = 默认 prefs / 首次引导下载用的"主版本"。
//                                   仍然是 17（占绝大多数 mc 版本 + 最稳定）。
//   - SUPPORTED_JDK_VERSIONS      = 用户在 SettingsTab 里能切换的全集合。
//                                   现包括 17（默认）+ 21 + 25（实验性）。
//   - JdkManager.autoSelectVersion(mcVersion)：纪元路由——26.1+（YEARLY）→ 25，
//     CLASSIC 且 ≥ 1.20.5 → 21，≤ 1.20.4 → 17；UNKNOWN（周快照 / 纯中文目录名等
//     无法判定的）→ 兜底【最新可用 JDK】(fallbackJdkVersion()，当前 25，高版本向后兼容)。
//   - SUPPORTED_RELEASE_TAG / ASSET 是 17 的 release（保留向后兼容；JdkManager
//     的 JDK_VERSIONS map 里 21 / 25 自带 tag/asset）。
//
// 编译期常量；运行时真正决策入口都在 JdkManager / Index.updateJdkReadyState 等。
export const SUPPORTED_JDK_VERSION = '17'
export const SUPPORTED_JDK_VERSIONS: string[] = ['8', '17', '21', '25']
export const SUPPORTED_RELEASE_TAG = 'v17.0.13-ohos-5'
export const SUPPORTED_RELEASE_ASSET = 'jdk17-ohos-full-v5.zip'

// JDK 选择的特殊哨兵值：
//   - 全局设置 / 单版本覆盖里，'auto' = 按 MC 版本纪元自动路由（JdkManager.resolveLaunchJdk）。
//   - 单版本覆盖里，'' = 跟随全局设置；具体版本号（'8'/'17'/'21'/'25'）= 硬覆盖（即便与纪元不匹配
//     也照用，供调试"错误 JDK 也能启动"）。
export const JDK_AUTO = 'auto'

// JDK 21 release（2026-05-19 v6 上线，"⚠️ 实验性"）
// v6 关键变化：放弃 Cacio AWT，改走 -Djava.awt.headless=true + sun.awt.HeadlessToolkit
//             真 headless 路径，patch 0009 + libawt_xawt.so stub 全部移除。
//             详见 docs/archive/jdk21-awt-headless-journey-202605.md §5（第一阶段方案）。
// sha256/sizeBytes 在 JdkManager.JDK_VERSIONS 里维护，避免常量散落两份。
export const JDK21_RELEASE_TAG = 'v21.0.5-ohos-7'
export const JDK21_RELEASE_ASSET = 'jdk21-ohos-full-v7.zip'

// JDK 25 release（2026-05-30 上线，MC 26.1+ YY.D.H 纪元首个要求 Java 25）
// 与 21 同构 8 个 OHOS patch（全部 __MUSL__ 门控），真 headless 模式。
// 详见 docs/adaptation/JDK25_ADAPTATION_ASSESSMENT.md。
// sha256/sizeBytes 在 JdkManager.JDK_VERSIONS 里维护，避免常量散落两份。
export const JDK25_RELEASE_TAG = 'v25.0.4-ohos-2'
export const JDK25_RELEASE_ASSET = 'jdk25-ohos-full-v2.zip'

// MC 版本 → 推荐 JDK 的路由阈值（含 1.20.5 起需要 JDK 21）
// MC ≤ 1.20.4 走 17；1.20.5 ≤ MC ≤ 1.x 走 21（与 Mojang 自身的 java-runtime 切换一致）；
// MC 26.1+（YY.D.H 新纪元）走 25。纪元判定见 McVersionUtils.detectMcEra。
export const JDK21_MIN_MC_VERSION = '1.20.5'

// MC 官方 Vulkan 渲染后端（Vibrant Visuals）起始版本。26.2 起 Options→Video→Graphics API
// 可在 OpenGL/Vulkan 间切换；Vulkan 稳定后 Mojang 计划移除 OpenGL。用户选 ≥ 此版本时，
// VulkanCapability 服务会静默跑 native 探针，按设备能力提示"Vulkan 可用 / 不可用"。
// 详见 docs/adaptation/VULKAN_ADAPTATION_PLAN.md §十。
export const VULKAN_MIN_MC_VERSION = '26.2'

// 下载前设备可行性和安装后客户端审计共用此已核实的要求身份。后续版本的下载页可按
// 它给参考报告，但启动资格仍由真实客户端摘要、窗口和运行库检查决定，不能据此外推。
export const VULKAN_264_REFERENCE_VERSION: string = '26.4-snapshot-1'
export const VULKAN_264_REQUIREMENT_ID: string = 'minecraft-26.4-snapshot1-sdl-vulkan-v1'

// ===== 应用信息 =====
export const APP_NAME = 'AMCL'
// 关于页与设置页共用的展示版本；发布准备时与 AppScope.versionName 同步。
export const APP_VERSION = '1.0.5'
export const APP_FULL_NAME = 'Axe Minecraft Launcher'

// 品牌免责声明（知识产权合规）：同时满足
//   · 微软/Mojang《Minecraft Usage Guidelines》要求的"显著标注非官方 + 无关联 + 商标归属"；
//   · 华为审核指南 9.5 / 1.15 的"消除混淆、不暗示与他人存在特定联系"。
// 在首次启动隐私弹窗、关于页均显著展示；商店应用介绍也应引用同一口径。
export const BRAND_DISCLAIMER =
  'AMCL 是第三方开源游戏启动器，与 Mojang Studios、Microsoft 及网易公司均无关联，未获其授权或认可。' +
  '相关游戏名称及商标归各自权利人所有。本应用不含也不分发任何游戏本体及受版权保护的游戏文件，' +
  '仅帮助用户下载、管理并启动其自行购买的正版游戏。'

// ===== AMCL-web（赞助 / 反馈站点，见 AMCL-web/API.md）=====
// 已上 HTTPS 域名（nginx 反代 → Node:7438，Let's Encrypt 证书）。
export const AMCL_WEB_BASE = 'https://amcl.lovedhy.cn'
// 赞助页用 ?embed=1 隐藏站点导航/页脚，只留"赞助星云 + 赞助登记"两屏，适合内嵌 WebView。
export const SPONSOR_PAGE_URL = AMCL_WEB_BASE + '/sponsor?embed=1'
// 反馈页同样用 ?embed=1 隐藏站点导航栏/页脚（内嵌时只显示反馈表单本身）。
export const FEEDBACK_PAGE_URL = AMCL_WEB_BASE + '/feedback?embed=1'

// ===== 文档中心（AMCL-web /docs，内嵌 WebView 打开） =====
// ?embed=1 隐藏站点导航/页脚，只显示文档正文（供 App 内嵌）；fallback 为可读的浏览器版。
export const DOCS_INSTALL_URL = AMCL_WEB_BASE + '/docs/install-hokit?embed=1'
export const DOCS_INSTALL_FALLBACK_URL = AMCL_WEB_BASE + '/docs/install-hokit'
export const DOCS_NO_JIT_URL = AMCL_WEB_BASE + '/docs/no-jit?embed=1'
export const DOCS_NO_JIT_FALLBACK_URL = AMCL_WEB_BASE + '/docs/no-jit'

// 隐私政策（托管于 amcl-public GitHub Pages；开屏隐私弹窗「查看完整政策」用）。
export const PRIVACY_POLICY_URL = 'https://lzzlhy.github.io/amcl/privacy-policy'

// ===== 检查更新（GitHub 权威源：github.com/LZZLHY/amcl）=====
// 比较口径：设备已装 versionCode（bundleManager）对比线上 update.json 的 versionCode。
// update.json 由发版者在 amcl-public 仓库随每次发布手动同步（schema 见 UpdateChecker.UpdateManifest）。
//
// 网络可达性：国内直连 raw.githubusercontent.com 经常被 DNS 污染/阻断（这正是手动检查
// 总是「更新失败」的根因）。这里复用 JDK 下载同款的 GitHub 代理镜像（ghfast.top /
// gh-proxy.com / mirror.ghproxy.com），按"快的在前、直连兜底"排列，fetchText 会依次 fallback。
export const APP_REPO_URL = 'https://github.com/LZZLHY/amcl'

// 作者联系方式 / 交流群（关于页展示，点击复制到剪贴板）。
export const AUTHOR_EMAIL = '3185300855@qq.com'
export const QQ_GROUP_ID = '185698705'

// 权威 raw 源（被代理镜像包裹，也作为直连兜底）。
const UPDATE_MANIFEST_RAW = 'https://raw.githubusercontent.com/LZZLHY/amcl/main/update.json'
export const UPDATE_MANIFEST_URLS: string[] = [
  'https://ghfast.top/' + UPDATE_MANIFEST_RAW,          // ghfast 镜像（最快，优先）
  'https://gh-proxy.com/' + UPDATE_MANIFEST_RAW,        // gh-proxy 镜像
  'https://mirror.ghproxy.com/' + UPDATE_MANIFEST_RAW,  // ghproxy 镜像
  UPDATE_MANIFEST_RAW,                                  // GitHub 直连（兜底）
  'https://lzzlhy.github.io/amcl/update.json',          // GitHub Pages 兜底（另一套 DNS/CDN）
]

// ===== 更新日志（全量历史，App 内「更新日志」页数据源）=====
// 事实源是 AMCL-web 仓库的 web/changelog/*.md，由 scripts/gen-changelog.mjs 生成
// changelog.json 并同时发布到 AMCL-web 站点、amcl-public（GitHub Pages/raw）与本包
// rawfile 快照三处。规范见 AMCL-web/CHANGELOG-SPEC.md。
//
// 取源顺序：
//   1) AMCL-web 权威接口 `GET /api/changelog`（带 ETag/304，见 AMCL-web/API.md 第 11 节）；
//   2) 同源静态兜底 `/changelog.json` —— AMCL-web 的部署脚本支持 `-FrontendOnly`（只推 dist、
//      不重启后端），所以"前端已更新、后端还没有新路由"是该项目的**常态偏斜**，只押接口会让
//      更新日志在这个窗口里整体失效；静态文件就是该接口透传的那份构建产物，内容必然一致；
//   3) 与 update.json 同一套 GitHub 镜像链上的 changelog.json（amcl-web 单源无镜像，国内波动必须兜底）。
// 客户端**首选**接口而非静态文件：前缀统一、可加缓存/限流策略、在 API.md 内有归属。
// 商店渠道由 DistributionPolicy 管理；此更新日志服务只读随包 rawfile 快照。
//    备案口径「无自有服务器」，且商店分发的更新由应用市场负责。
const CHANGELOG_JSON_RAW = 'https://raw.githubusercontent.com/LZZLHY/amcl/main/changelog.json'
export const CHANGELOG_JSON_URLS: string[] = [
  AMCL_WEB_BASE + '/api/changelog',                     // 权威接口（带 ETag/304，见 AMCL-web/API.md）
  AMCL_WEB_BASE + '/changelog.json',                    // 同源兜底：构建产物本身（前端常先于后端部署）
  'https://ghfast.top/' + CHANGELOG_JSON_RAW,
  'https://gh-proxy.com/' + CHANGELOG_JSON_RAW,
  'https://mirror.ghproxy.com/' + CHANGELOG_JSON_RAW,
  CHANGELOG_JSON_RAW,
  'https://lzzlhy.github.io/amcl/changelog.json',
]
/** 随包快照的 rawfile 名（由 gen-changelog.mjs --publish 写入）。 */
export const CHANGELOG_RAWFILE = 'changelog.json'
/** 网页版完整更新日志（浏览器打开；update.json 的 changelogUrl 缺失时的兜底）。 */
export const CHANGELOG_PAGE_URL = AMCL_WEB_BASE + '/changelog'

// ===== 日志 =====
// 主 domain（向后兼容：未指定 domain 的旧调用仍走这个）
// 0xA000~0xAFFF 段是 OHOS 应用约定可用的 domain 范围
export const LOG_DOMAIN = 0xA000

// 子系统 domain — DevEco Hilog 面板可按 `--domain 0xA002` 一键过滤
// 2026-05-10（LOG-P1-2）：账户/下载/启动/modloader/UI/native 五分类
export const LOG_DOMAIN_DOWNLOAD  = 0xA001
export const LOG_DOMAIN_ACCOUNT   = 0xA002
export const LOG_DOMAIN_LAUNCH    = 0xA003
export const LOG_DOMAIN_MODLOADER = 0xA004
export const LOG_DOMAIN_UI        = 0xA005
export const LOG_DOMAIN_NATIVE    = 0xA006

// ===== 下载镜像源 =====
export const BMCLAPI_HOST = 'bmclapi2.bangbang93.com'
export const BMCLAPI_BASE = 'https://' + BMCLAPI_HOST
export const MOJANG_META = 'https://piston-meta.mojang.com'
export const MOJANG_RESOURCES = 'https://resources.download.minecraft.net'
export const MOJANG_LIBRARIES = 'https://libraries.minecraft.net'

// Tab 颜色
export const COLOR_TAB_ACTIVE_DEFAULT = '#007DFF'
export const COLOR_TAB_INACTIVE = '#E0E0E0'
export const COLOR_TEXT_DARK = '#333333'
export const COLOR_TEXT_LIGHT = '#FFFFFF'
export const COLOR_TEXT_SECONDARY = '#888888'
export const COLOR_TEXT_HINT = '#AAAAAA'

// 状态颜色
export const COLOR_SUCCESS = '#4CAF50'
export const COLOR_WARNING = '#FF9800'
export const COLOR_ERROR = '#F44336'
export const COLOR_DISABLED = '#999999'

// 测试模块颜色
export const COLOR_JIT = '#007DFF'
export const COLOR_JVM = '#FF5722'
export const COLOR_GLES = '#4CAF50'
export const COLOR_VULKAN = '#9C27B0'
export const COLOR_GLFW = '#795548'
export const COLOR_GL4 = '#E91E63'
export const COLOR_JVM_EMBED = '#00BCD4'
export const COLOR_MOBILEGLUES = '#FF6F00'
export const COLOR_LWJGL = '#3F51B5'
export const COLOR_MC_LAUNCH = '#F44336'

// 背景
export const COLOR_BG_PANEL = '#F5F5F5'
export const COLOR_BG_LOG = '#607D8B'

// 字体
export const FONT_SIZE_TITLE = 24
export const FONT_SIZE_BODY = 13
export const FONT_SIZE_SMALL = 12
export const FONT_SIZE_TINY = 11
export const FONT_SIZE_MICRO = 10

// ===== Microsoft 正版登录（M2 落地） =====
// Azure App Registration: "Axe Minecraft Launcher"
// 详见 docs/guides/genuine-login-and-account-system-plan.md §8
export const MSA_CLIENT_ID = '2d7924e2-a949-4c00-88e1-bcb612b42745'
export const MSA_REDIRECT_URI = 'https://login.live.com/oauth20_desktop.srf'
export const MSA_SCOPE = 'XboxLive.signin offline_access'
export const MSA_AUTHORITY = 'https://login.microsoftonline.com/consumers'
export const MSA_AUTHORIZE_URL = MSA_AUTHORITY + '/oauth2/v2.0/authorize'
export const MSA_TOKEN_URL = MSA_AUTHORITY + '/oauth2/v2.0/token'
export const MSA_DEVICE_CODE_URL = MSA_AUTHORITY + '/oauth2/v2.0/devicecode'
export const MSA_LOGOUT_URL = 'https://login.live.com/oauth20_logout.srf'

// Xbox Live / Minecraft Services（M2 落地，写死）
export const XBL_AUTH_URL = 'https://user.auth.xboxlive.com/user/authenticate'
export const XSTS_AUTH_URL = 'https://xsts.auth.xboxlive.com/xsts/authorize'
export const MC_BEARER_URL = 'https://api.minecraftservices.com/authentication/login_with_xbox'
export const MC_PROFILE_URL = 'https://api.minecraftservices.com/minecraft/profile'
// 切换 active cape：PUT 设新 cape (body {"capeId":"<uuid>"}) / DELETE 取消 cape。
// 都返回新的 profile JSON（与 MC_PROFILE_URL 同 schema）。
export const MC_ACTIVE_CAPE_URL = 'https://api.minecraftservices.com/minecraft/profile/capes/active'

// ===== 第三方皮肤站（authlib-injector / Yggdrasil）登录（M4 落地） =====
// 协议：Yggdrasil（Mojang 早期正版验证协议的开源复刻），配合 authlib-injector.jar
//   在游戏运行时把 MC 内写死的 Mojang 验证域名重定向到皮肤站。
// 参考：https://github.com/yushijinhun/authlib-injector/wiki
//
// 用户输入的「服务器地址」即 API 根（apiRoot），例如 https://littleskin.cn/api/yggdrasil。
// 各端点在 apiRoot 之下：
//   - authserver/authenticate | refresh | validate | invalidate  （Yggdrasil 认证）
//   - sessionserver/session/minecraft/profile/{uuid}              （皮肤/披风纹理）
//   - GET {apiRoot}                                               （元数据：meta.serverName / skinDomains / 公钥）
export const YGGDRASIL_AUTHSERVER_PATH = '/authserver'
export const YGGDRASIL_SESSIONSERVER_PROFILE_PATH = '/sessionserver/session/minecraft/profile/'
// authlib-injector 通过响应头做 API Location Indication（ALI）重定向：
// 用户填的短链在 GET 时可能返回此头指向真正的 apiRoot。登录时解析一次并落库。
export const YGGDRASIL_ALI_HEADER = 'x-authlib-injector-api-location'
// Yggdrasil authenticate 的 agent 字段（固定值，标识请求方为 Minecraft）。
export const YGGDRASIL_AGENT_NAME = 'Minecraft'
export const YGGDRASIL_AGENT_VERSION = 1
// authlib-injector.jar 打包在 rawfile，启动前提取到 filesDir。文件名 SSOT。
export const AUTHLIB_INJECTOR_JAR_NAME = 'authlib-injector.jar'

/** 皮肤站预设条目（UI 下拉快捷填充；用户仍可自定义地址）。 */
export interface SkinServerPreset {
  name: string
  apiRoot: string
  /** 注册页 URL（可空）。 */
  register: string
}

/** 常见公共皮肤站预设。apiRoot 为其 authlib-injector API 根。 */
export const SKIN_SERVER_PRESETS: SkinServerPreset[] = [
  { name: 'LittleSkin', apiRoot: 'https://littleskin.cn/api/yggdrasil', register: 'https://littleskin.cn/auth/register' },
]
