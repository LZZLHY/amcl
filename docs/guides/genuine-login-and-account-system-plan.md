# AMCL 正版登录与账户体系规划文档（2026-05-09）

> **状态**：规划阶段（未开工）。主流程采用 **HMCL 同款 Authorization Code + PKCE + 嵌入式 WebView**，备选 **PCL2 同款 Device Code**。本文档为 M1~M4 的单一事实来源（SSOT）。
>
> **评审基线**：`docs/self-inspection/2026-05-09_AMCL_项目全面评审报告.md`（综合 8.2 / 10）
>
> **核心原则**：零 C++/NAPI/Java 中间层修改，纯 ArkTS 增量；不动报告里 5 个长文件的任何一行。

---

## 目录

- 一、文档范围与读者
- 二、现状评估（基于代码事实）
- 三、对标调研（PCL2 / HMCL）
- 四、架构设计
- 五、主方案：Authorization Code + PKCE + WebView（HMCL 同款）
- 六、备选方案：Device Code（PCL2 同款）
- 七、Xbox Live / XSTS / Minecraft 链路（两方案共用）
- 八、Azure 应用注册教程（操作指南）
- 九、凭据持久化设计（HUKS）
- 十、UI 集成设计
- 十一、阶段化落地计划
- 十二、风险评审
- 十三、影响面评估
- 十四、测试策略
- 十五、与 5/9 自检报告对照
- 十六、参考资料
- 十七、决策记录
- 附录 A：启动链路差异对比

---

## 一、文档范围与读者

**本文档回答 3 个问题**：

1. AMCL 如何在 HarmonyOS NEXT 上给 Minecraft 接入 Microsoft 正版登录？
2. 动手之前需要做什么准备（Azure 应用注册、权限、法务声明）？
3. 落地过程中的每一个风险在哪里、如何缓解？

**读者**：AMCL 核心开发者；账户/安全模块 reviewer；未来维护者。

**不在本文档范围**：多人联机 session 协议（MC 客户端处理）、皮肤上传 / 披风管理 / 皮肤渲染（M4 之后）、正版玩家增值服务。

---

## 二、现状评估（基于代码事实）

### 2.1 账户字段链路

AMCL 代码里账户四件套（`username / uuid / accessToken / userType`）的**完整链路已搭好**，只是**从未被调用**。

```
[McGamePage.startMC]
  ↓  ❌ 未调用 setUsername/setUuid/setAccessToken/setUserType
[LaunchProfileBuilder]
  ↓  ✅ 字段存在，默认值 MCPlayer / 全0 UUID / 全0 token / legacy
[--accessToken/--uuid/--username/--userType  argv]
  ↓  ✅ 已就位，Forge/Vanilla 共用
[NAPI mcLaunchWithProfileV2 → mc_launcher.cpp → MC main]
  ↓  以占位值运行（Session 无效、皮肤默认 Steve/Alex）
```

**关键代码位置**：

| 关注点 | 文件位置 | 状态 |
|---|---|---|
| Builder setter | `entry/src/main/ets/services/LaunchProfileBuilder.ets:79-82` | ✅ 已有 |
| Builder 默认值 | `entry/src/main/ets/services/LaunchProfileBuilder.ets:67-70` | ⚠️ 全 0 占位 |
| McArgs 注入 | `entry/src/main/ets/services/LaunchProfileBuilder.ets:816-824` | ✅ 已有 |
| `${auth_*}` 占位符 | `entry/src/main/ets/services/LaunchProfileBuilder.ets:836-846` | ✅ 已有 |
| 调用方 | `entry/src/main/ets/pages/McGamePage.ets:291-298` | ❌ 未调用账户 setter |
| Preferences 账户字段 | `entry/src/main/ets/services/PreferenceManager.ets` | ❌ 完全无 |
| 账户 UI | （无） | ❌ 完全无 |

### 2.2 下游基础设施（已就位，零改动）

| 能力 | 模块 | 说明 |
|---|---|---|
| HTTP | `@ohos.net.http` | 已在 `SourceProber/McDownloader/MavenUtils` 使用 |
| WebView | `@ohos.web.webview` / `@kit.ArkWeb` | 原生支持 redirect 拦截 |
| 对称加密 | `@ohos.security.huks` | AES-GCM-256 + 硬件密钥保护 |
| 随机数 | `@ohos.security.cryptoFramework` | PKCE `code_verifier` / `state` |
| 偏好存储 | `PreferenceManager` | 存明文账户元信息 |
| 浏览器跳转 | `startAbility` + `viewData` | Device Code 备选路径用 |

### 2.3 缺口清单

新增 6 个 `.ets` 服务文件 + 3 个 UI 组件：

```
entry/src/main/ets/services/account/
├── Account.ets                # ~80 行  接口 + 类型枚举
├── OfflineAccount.ets         # ~120 行 离线（保留现状）
├── MicrosoftAccount.ets       # ~250 行 正版完整链路
├── AccountStorage.ets         # ~200 行 HUKS 加密 + Preferences
├── AccountManager.ets         # ~180 行 单例列表管理
└── microsoft/
    ├── MicrosoftOAuth.ets     # ~300 行 Auth Code + PKCE + Device Code
    ├── XboxLiveAuth.ets       # ~180 行 XBL + XSTS
    └── MinecraftProfileApi.ets # ~150 行 MC bearer + profile + XErr

entry/src/main/ets/components/
├── AccountBadge.ets           # ~60 行  主页顶栏头像/用户名
├── AccountListSheet.ets       # ~180 行 账户管理 Sheet
└── AddMicrosoftAccountSheet.ets # ~250 行 添加微软账户（双模）
```

改动现有文件：`McGamePage.ets` +15、`PreferenceManager.ets` +10、`Index.ets` +30、`Constants.ets` +5。

**总量**：新增约 **1650 行** + 改动 **60 行**。**不动任何长文件**。

---

## 三、对标调研（PCL2 / HMCL）

### 3.1 PCL2 的做法

PCL2（VB.NET/WPF，开源）：

- **OAuth 流程**：Device Code Flow
- **为什么选 Device Code**：WPF 嵌入 WebView 兼容性差，Device Code 跳系统浏览器，UX 稍差但绕开 WebView 地狱
- **Azure App 注册**：自有 Azure AD 应用，`client_id` 公开写在代码仓库
- **凭据存储**：Windows DPAPI（`ProtectedData.Protect`）
- **错误处理**：XErr 错误码全量翻译中文
- **账户类型**：离线 / 微软 / Mojang（已失效） / 统一通行证（Authlib-Injector）

### 3.2 HMCL 的做法

HMCL（JavaFX，开源）：

- **OAuth 流程**：Authorization Code + PKCE
- **WebView**：JavaFX 内置 WebView（基于 WebKit），完整拦截 redirect URI
- **为什么选 Auth Code**：UX 顺滑（无需复制粘贴），PKCE 免去 client_secret，适合公开客户端
- **重定向 URI**：`https://login.live.com/oauth20_desktop.srf`（MSA 公认 desktop 回调）
- **Azure App 注册**：自有 Azure AD 应用，代码公开
- **凭据存储**：AES-128，key 由系统属性派生（非硬件隔离）
- **账户抽象**：`Account` 抽象类 + `logIn()/refresh()/play()` + `AccountFactory`
- **账户类型**：离线 / 微软 / Authlib-Injector / Yggdrasil

### 3.3 结论矩阵（为什么选 HMCL 主 + PCL2 备）

| 决策点 | AMCL 选择 | 理由 |
|---|---|---|
| 主流程 | HMCL 同款 Auth Code + PKCE + WebView | 鸿蒙 `@ohos.web.webview` 原生可拦截 redirect，UX 最佳 |
| 备选流程 | PCL2 同款 Device Code | WebView 故障时自动回退；用户可选"使用浏览器登录" |
| 账户抽象 | HMCL 的 `Account` 接口 | 干净、可测试，M4 加 Authlib-Injector 时天然插拔 |
| 凭据加密 | HUKS（超越两者） | 鸿蒙硬件密钥隔离，比 DPAPI / AES-derived 更强 |
| 错误翻译 | 借鉴 PCL2 中文文案 | 免重复劳动 |
| M1 账户类型 | 离线 + 微软 | Authlib-Injector 留 M4 |

---

## 四、架构设计

### 4.1 账户抽象层

```typescript
// Account.ets
export enum AccountType {
  OFFLINE = 'legacy',           // 对应 MC --userType
  MICROSOFT = 'msa',            // 微软正版
  AUTHLIB_INJECTOR = 'mojang',  // M4 保留
}

export interface Account {
  readonly id: string                  // 稳定 UUID，列表索引
  readonly type: AccountType
  readonly username: string
  readonly uuid: string                // MC UUID
  readonly createdAt: number

  getAccessToken(): Promise<string>     // 自动判断过期触发刷新
  refresh(): Promise<void>              // 强制刷新
  fillProfile(builder: LaunchProfileBuilder): void
  serialize(): AccountRecord            // 持久化 schema
  isUsable(): Promise<boolean>          // token 有效或可刷新
  getDisplayName(): string
}
```

- **`OfflineAccount`** 的 `refresh()` 是空操作；`uuid` 由 `UUID.nameUUIDFromBytes('OfflinePlayer:' + username)` 派生（与 Mojang 离线规则一致）
- **`MicrosoftAccount`** 持有 `refreshToken / mcAccessToken / mcTokenExpiresAt`，`refresh()` 走完整 5 步链路；`getAccessToken()` 自动判断 `Date.now() > expiresAt - 60000` 触发 refresh

### 4.2 端到端调用链

```
[McGamePage.startMC]
  1. AccountManager.getSelected() → Account
  2. await account.refresh()           // 启动前强制一次
  3. account.fillProfile(builder)      // 注入 username/uuid/accessToken/userType
  4. builder.build() → LaunchProfile   // 现有逻辑
  5. testNapi.mcLaunchWithProfileV2(...) // 现有 NAPI
```

仅第 1-3 步是新增。**C 层 / NAPI / Java 层完全无感**。

### 4.3 文件组织职责

- `Account.ets`：纯接口 + 枚举，无实现（便于 mock）
- `OfflineAccount.ets` 与 `MicrosoftAccount.ets`：独立文件，互不 import
- `microsoft/` 三个文件分别负责 OAuth / XBL / MC Services 三层，**每层可单测**
- `AccountManager.ets`：单例挂 AppStorage，与 `LayoutStore / MetadataCacheStore` 同风格
- `AccountStorage.ets`：HUKS 细节全部封装在内，上层只看到 `encrypt(plain) / decrypt(cipher)`

---

## 五、主方案：Authorization Code + PKCE + WebView（HMCL 同款）

### 5.1 总流程图

```
[用户点击"添加微软账户"]
  ↓
[生成 code_verifier (64B 随机) + code_challenge = SHA256(verifier) + state (32B 随机)]
  ↓
[构造授权 URL：
   https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize
     ?client_id=<AMCL_CLIENT_ID>
     &response_type=code
     &redirect_uri=https://login.live.com/oauth20_desktop.srf
     &response_mode=query
     &scope=XboxLive.signin offline_access
     &code_challenge=<S256(verifier)>
     &code_challenge_method=S256
     &state=<RANDOM>
     &prompt=select_account]
  ↓
[弹出 Sheet 内嵌 Web 组件，加载授权 URL]
  ↓
[用户登录 → MS 跳转到 redirect_uri?code=xxx&state=xxx]
  ↓
[onLoadIntercept 捕获 redirect_uri 前缀 → 关闭 WebView → 拿到 code + 校验 state]
  ↓
[POST /oauth2/v2.0/token  with code + code_verifier (PKCE)
   → access_token + refresh_token + expires_in]
  ↓
[走 Xbox Live → XSTS → MC Services 链路（§7）]
  ↓
[构造 MicrosoftAccount，HUKS 加密敏感字段，持久化到 Preferences]
  ↓
[AccountManager.add + select → Toast "登录成功"]
```

### 5.2 PKCE 细节（RFC 7636）

- `code_verifier`：43~128 字符随机串，字符集 `[A-Za-z0-9-._~]`，AMCL 用 64 字节随机数 base64url-no-pad
- `code_challenge`：`BASE64URL-NO-PAD(SHA256(code_verifier))`
- `code_challenge_method`：固定 `S256`
- **为什么必须用 PKCE**：AMCL 是公开客户端（client_secret 不能放进 HAP），PKCE 防止授权码被中间人拦截后换 token

### 5.3 WebView 集成（`@kit.ArkWeb`）

```typescript
// AddMicrosoftAccountSheet.ets（简化）
import { webview } from '@kit.ArkWeb';

@CustomDialog
struct MsaWebDialog {
  @Link code: string
  @Link error: string
  controller: CustomDialogController
  private webController = new webview.WebviewController()
  private authUrl: string = ''
  private redirectPrefix = 'https://login.live.com/oauth20_desktop.srf'
  private expectedState: string = ''

  build() {
    Column() {
      Web({ src: this.authUrl, controller: this.webController })
        .onLoadIntercept((event) => {
          let url = event.data.getRequestUrl()
          if (url.startsWith(this.redirectPrefix)) {
            this.handleRedirect(url)
            return true   // 拦截，不实际加载
          }
          return false
        })
        .onErrorReceive((event) => { /* 网络错误处理 */ })
        .width('100%').height('80%')
      Button('取消').onClick(() => this.controller.close())
    }
  }

  private handleRedirect(url: string) {
    let u = new URL(url)
    let code = u.searchParams.get('code')
    let state = u.searchParams.get('state')
    let err = u.searchParams.get('error')
    if (err) { this.error = err; this.controller.close(); return }
    if (!code || state !== this.expectedState) {
      this.error = 'state_mismatch'
    } else {
      this.code = code
    }
    this.controller.close()
  }
}
```

**关键点**：

- `onLoadIntercept` 在导航**之前**触发，拿到 URL 立即拦截
- 监听 `onErrorReceive` 处理网络失败 / TLS 错误
- WebView 关闭时 `webview.WebCookieManager.clearAllCookiesSync()` + `webController.clearHistory()`，避免下次复用老会话
- 登录前 `webController.setCustomUserAgent(<默认UA>)`，**不要伪造 UA**（MSA 反自动化）

### 5.4 重定向拦截与 state 校验

- `state` 每次请求重新生成（32 字节随机），与 `code_verifier` 一同保存在本次会话
- redirect 到达后**严格比对 state**，不匹配视为 CSRF 失败
- `code` 只能使用一次，拿到后立即 exchange，**过期时间 10 分钟**

### 5.5 关键 API 调用（Auth Code 方案下 2 步，后接 §7）

| # | 端点 | 方法 | body 关键字段 | 返回关键字段 |
|---|---|---|---|---|
| 1 | `/oauth2/v2.0/authorize` | GET（浏览器） | — | `code` |
| 2 | `/oauth2/v2.0/token` | POST form | `grant_type=authorization_code&client_id&code&redirect_uri&code_verifier` | `access_token`, `refresh_token`, `expires_in` |

**token 端点不需要 `client_secret`**（PKCE 替代）。误传会被拒绝。

### 5.6 错误处理

| 场景 | 表现 | 处理 |
|---|---|---|
| 用户关闭 Sheet | `code` 为空 | Toast "已取消" |
| 授权端返回 error | URL 带 `error=access_denied` | Toast 展示错误 |
| state 不匹配 | 可能 CSRF | 拒绝，Toast "登录链路异常" |
| redirect 未触发 | WebView 停在登录页 | 5 分钟超时关闭 |
| token 端点网络失败 | 重试 ≤2 次 | Toast "网络问题" |

### 5.7 WebView 方案特有风险

1. **HarmonyOS NEXT Web 内核能力**：必须真机验证 `onLoadIntercept` 对 `https://login.live.com/oauth20_desktop.srf` 前缀的拦截准确性。如内核不支持必须降级 Device Code
2. **Cookie 持久化**：登录后必须 `clearAllCookiesSync()`，避免账户切换失败
3. **MSA 反自动化**：对非标 UA 可能弹 CAPTCHA，不要伪造 UA
4. **键盘遮挡**：键盘弹起可能遮挡登录按钮，需 `adjustResize`

---

## 六、备选方案：Device Code（PCL2 同款）

### 6.1 流程图

```
[POST /devicecode → device_code + user_code + verification_uri + interval (轮询间隔)]
  ↓
[UI 展示 user_code（大字 + 复制按钮）+ "打开浏览器登录" 按钮]
  ↓
[用户在系统浏览器登录 Microsoft 账户并粘贴 user_code]
  ↓
[APP 后台每 interval 秒轮询 /token (grant_type=device_code)
   → 初期返回 authorization_pending
   → 成功返回 access_token + refresh_token]
  ↓
[后续流程与主方案相同，走 §7]
```

### 6.2 何时自动回退到备选

`MicrosoftOAuth.loginInteractive()` 内：

```typescript
try {
  return await this.loginAuthCodeWebView()
} catch (e) {
  if (this.isWebViewCapabilityError(e)) {
    hilog.warn(TAG, 'WebView 能力不足，回退 Device Code')
    return await this.loginDeviceCode()
  }
  throw e
}
```

回退条件：

- WebView 不可用 / `onLoadIntercept` 不工作
- redirect 拦截 5 分钟超时
- 用户在 UI 主动选"使用浏览器登录"

### 6.3 实现差异

| 项 | Auth Code + PKCE | Device Code |
|---|---|---|
| `client_secret` | 否 | 否 |
| `redirect_uri` | 必须 | 不需要 |
| `scope` | `XboxLive.signin offline_access` | 同 |
| UI 组件 | WebView | 文本 + 复制 + 浏览器跳转 |
| 平均耗时 | 30s ~ 1min | 1 ~ 3min |
| 国内稳定性 | 较差（WebView 内登录页慢） | 较好（用户可走系统代理） |
| 关键参数 | `code_verifier / state` | `device_code / interval / expires_in` |

### 6.4 关键 API 调用

| # | 端点 | 方法 | body | 返回关键字段 |
|---|---|---|---|---|
| 1 | `/oauth2/v2.0/devicecode` | POST form | `client_id&scope=XboxLive.signin+offline_access` | `device_code, user_code, verification_uri, interval, expires_in` |
| 2 | `/oauth2/v2.0/token` | POST form 轮询 | `grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id&device_code` | 成功：`access_token, refresh_token`；中间：`error=authorization_pending` |

**轮询规则**：

- 间隔严格遵守 `interval`（一般 5 秒），过快服务端会返回 `slow_down` 并要求 +5s
- `expires_in`（一般 900s = 15 分钟）超时则报"二维码过期，请重试"
- 用户拒绝 → `error=authorization_declined`，立即终止

---

## 七、Xbox Live / XSTS / Minecraft 链路（两方案共用）

### 7.1 步骤详解

**步骤 3：XBL 认证**

```http
POST https://user.auth.xboxlive.com/user/authenticate
Content-Type: application/json
x-xbl-contract-version: 1

{
  "Properties": {
    "AuthMethod": "RPS",
    "SiteName": "user.auth.xboxlive.com",
    "RpsTicket": "d=<MS_access_token>"
  },
  "RelyingParty": "http://auth.xboxlive.com",
  "TokenType": "JWT"
}
```

返回：`Token`（XBL Token），`DisplayClaims.xui[0].uhs`（user hash）。

**步骤 4：XSTS 授权**

```http
POST https://xsts.auth.xboxlive.com/xsts/authorize
Content-Type: application/json

{
  "Properties": {
    "SandboxId": "RETAIL",
    "UserTokens": ["<XBL_token>"]
  },
  "RelyingParty": "rp://api.minecraftservices.com/",
  "TokenType": "JWT"
}
```

返回：`Token`（XSTS token），同 `uhs`。

**错误**：HTTP 401 且 body 含 `XErr` 字段，必须解析为用户可读错误（见 7.2）。

**步骤 5：MC bearer 换取**

```http
POST https://api.minecraftservices.com/authentication/login_with_xbox
Content-Type: application/json

{
  "identityToken": "XBL3.0 x=<uhs>;<XSTS_token>"
}
```

返回：`access_token`（MC bearer，**24h 有效**），`expires_in`。

**步骤 6：MC profile**

```http
GET https://api.minecraftservices.com/minecraft/profile
Authorization: Bearer <MC_access_token>
```

返回：`id`（UUID 无连字符），`name`（玩家名）。

- HTTP 404 → 未购买 Minecraft → 错误 `NOT_PREMIUM`，UI 提示"该账户尚未购买 Minecraft Java 版"
- HTTP 200 → 写入 `MicrosoftAccount.uuid` / `username`

### 7.2 XErr 错误码表（借鉴 PCL2 译法）

| XErr | 英文含义 | 中文提示 |
|---|---|---|
| `2148916233` | Account doesn't have an Xbox account | 该账户未注册 Xbox，请先到 xbox.com 创建 |
| `2148916235` | Account is from a country where Xbox Live is banned | 当前地区 Xbox Live 不可用 |
| `2148916236` | Account needs adult verification on Xbox page | 需在 Xbox 完成身份/年龄验证 |
| `2148916237` | Account needs adult verification (US) | 需在 Xbox 完成身份验证（美国地区） |
| `2148916238` | Child account, must be added to family | 未成年账户需家长 Family 授权 |

### 7.3 重试策略

| 步骤 | connect / total | 重试次数 | 重试条件 |
|---|---|---|---|
| §5/§6 `/token` | 10s / 30s | 2 | HTTP 5xx / 网络异常 |
| §7 XBL | 10s / 30s | 1 | HTTP 5xx |
| §7 XSTS | 10s / 30s | 1 | HTTP 5xx（4xx + XErr 不重试） |
| §7 MC bearer | 10s / 30s | 1 | HTTP 5xx |
| §7 profile | 10s / 20s | 1 | HTTP 5xx（404 不重试，直接报未购买） |

### 7.4 端到端时序（成功路径）

```
T+0    用户点添加微软账户
T+1s   生成 PKCE，弹出 WebView，加载授权页
T+10s  用户扫描或输入凭据
T+15s  Microsoft 同意页 → 用户点同意
T+16s  redirect 触发 → 拿到 code → 关闭 WebView
T+17s  POST /token → 拿到 MS access_token + refresh_token
T+18s  POST XBL /user/authenticate → XBL token + uhs
T+19s  POST XSTS /xsts/authorize → XSTS token
T+20s  POST MC /login_with_xbox → MC access_token (24h)
T+21s  GET MC /minecraft/profile → uuid + name
T+22s  HUKS 加密 + 持久化 → 列表显示新账户 → 提示成功
```

总耗时 ~22 秒（用户操作占大部分）。失败/重试场景另外。

---

## 八、Azure 应用注册教程（操作指南）

### 8.1 前置条件

- **有效 Microsoft 开发者账号**（你已确认具备 ✅）
- **不需要**付费订阅（Azure AD 应用注册免费）
- **不需要**公司租户；个人开发者用 MSA 账户即可

### 8.2 注册步骤（Portal 操作）

1. 访问 `https://portal.azure.com`，用微软账号登录
2. 顶栏搜索 `Microsoft Entra ID`（原 Azure Active Directory）→ 进入
3. 左侧菜单 `管理 → 应用注册 (App registrations)` → 顶部 `+ 新注册 (New registration)`
4. 填写注册表单：
   - **名称**：`AMCL Minecraft Launcher`（任意，用户授权页会看到这个名字）
   - **受支持的账户类型**：**选 `个人 Microsoft 账户 (Personal Microsoft accounts only)`**
     - ⚠️ 不要选"所有 Microsoft 账户 + 个人"，Minecraft 账户都属于 personal 类别
   - **重定向 URI**：先不填，后面单独加
   - 点击 **注册**
5. 注册完成后，立即记下 **应用程序(客户端) ID (Application/Client ID)** —— 这就是 AMCL 代码里用的 `MSA_CLIENT_ID`
6. 左侧菜单 `身份验证 (Authentication)` → 点击 `+ 添加平台 (Add a platform)` → 选 **"移动和桌面应用 (Mobile and desktop applications)"**
7. 勾选以下两个 URI（若列表里没有就在"自定义重定向 URI"里手动加）：
   - `https://login.live.com/oauth20_desktop.srf`（**主流程必需**，AMCL Auth Code + PKCE 用这个）
   - `https://login.microsoftonline.com/common/oauth2/nativeclient`（备用）
8. 在 `身份验证` 页面下方：
   - **高级设置 → 允许公共客户端流 (Allow public client flows)**：**开启 ✅**
     - Device Code 流必需
     - 公开客户端 PKCE 也走这个开关
   - 保存
9. 左侧菜单 `API 权限 (API permissions)`：
   - **只需确保 `offline_access` 存在**（用于 refresh_token）
   - 步骤：`+ 添加权限` → `Microsoft Graph` → `委托的权限` → 搜索 `offline_access` → 勾选 → `添加权限`
   - `openid` 可选；`User.Read` 是 Azure 自动加的默认值，保留或删除都不影响
   - ⚠️ **不要尝试搜 `XboxLive.signin`**：它**不是** Microsoft Graph 权限（搜不到很正常）。Xbox Live scope 由 Microsoft Identity Platform v2.0 的**动态同意机制**在 OAuth 请求时按 `scope=` 参数传递，**不需要在 Portal 预声明**（HMCL / PCL2 / Prism 全部如此）
10. 权限添加完后，**无需管理员同意**（个人账户场景不需要）

**最终 `API 权限` 列表的期望状态**：

| 权限名 | 是否必需 | 说明 |
|---|---|---|
| `offline_access` | ✅ 必需 | refresh_token 必需 |
| `openid` | 可选 | 加不加都行 |
| `User.Read` | 不必需 | Azure 注册时自动加的默认值 |
| `XboxLive.signin` | **不在此处** | 由 OAuth `scope=` 参数动态请求 |

### 8.3 关键配置项核对

完成后到 `概述 (Overview)` 页确认：

| 字段 | 期望值 |
|---|---|
| 客户端 ID | 36 位 GUID，形如 `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| 目录(租户) ID | `9188040d-6c67-4c5b-b112-36a304b66dad`（这是 MSA personal-only 应用的固定 tenant GUID，所有 "Personal accounts only" 应用共享此值；§8.7 申请表会用到） |
| 支持的账户类型 | Personal Microsoft accounts |
| 重定向 URI 数量 | 至少 1（推荐 2） |
| 公共客户端流 | 启用 |

### 8.4 Microsoft 审核与品牌验证

本节区分 3 种容易混淆的"审核"：

| 审核类型 | 是否必需 | 触发时机 |
|---|---|---|
| **Azure Graph scope 同意** | ❌ 不需要 | `offline_access` / `openid` 是低敏感 scope，无需管理员同意 |
| **"验证发布者 (Verified Publisher)"** | ❌ 不需要也不要做 | 需 MPN 合作伙伴号，个人开发者不适用；HMCL/PCL2/Prism 都没做这个 |
| **Minecraft API 访问审核** | ✅ **必需**（**§8.7 详述**） | 2023 年起 Mojang 对**所有新注册** Azure App 强制白名单审核；**不申请就走不通 `login_with_xbox`**（403 "Invalid app registration"） |

**用户首次登录时**会看到"未验证的发布者"提示 —— 这是正常的（HMCL / PCL2 / Prism / 我们都一样）。

**注册即上线**：注册完应用后无需向 Azure 申请"发布"。但**这不等于能调 Minecraft API**——见 §8.7。

### 8.5 需要保存的凭据清单

只有 **1 个** 凭据要保存，且**不敏感**：

| 项 | 是否敏感 | 存放 |
|---|---|---|
| `MSA_CLIENT_ID` | ❌ 不敏感 | 直接写在 `Constants.ets`，提交 git |
| `CLIENT_SECRET` | — | **不生成、不使用**（AMCL 是公开客户端，PKCE 替代） |
| Redirect URI | ❌ 不敏感 | 写在 `MicrosoftOAuth.ets` |
| Scope | ❌ 不敏感 | 写在 `MicrosoftOAuth.ets` |

> ⚠️ **CLIENT_ID 公开是行业惯例**（PCL2 / HMCL / MultiMC / Prism 都把 client_id 明文提交到开源仓库）。PKCE 流程下 client_id 不是秘密，真正的安全靠 `code_verifier` 一次性 + `state` 校验。

### 8.6 本地测试验证

注册完成后，开工前先用 `curl` 验证（Windows PowerShell 也可）：

```bash
# 验证 1：申请 device code
curl -X POST "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode" \
  -d "client_id=<你的 CLIENT_ID>" \
  -d "scope=XboxLive.signin offline_access"
# 应返回 user_code / device_code / verification_uri
```

错误判读：

- `invalid_client` → 检查是否选了"Personal Microsoft accounts only"
- `unauthorized_client` → 检查"公共客户端流"是否启用
- `invalid_scope` → 检查 scope 拼写

```bash
# 验证 2：拿到 code 后换 token（手动走完 device code 后）
curl -X POST "https://login.microsoftonline.com/consumers/oauth2/v2.0/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
  -d "client_id=<你的 CLIENT_ID>" \
  -d "device_code=<上一步的 device_code>"
```

如果 token 端点返回成功，说明 **Azure 侧配置正确**。但⚠️ 这**不**意味着 Mojang 会放行 ——Azure 验通只能证明 OAuth/XBL 链路畅通，最终调 `https://api.minecraftservices.com/authentication/login_with_xbox` 时 Mojang 会单独检查白名单（详见 §8.7）。

### 8.7 Minecraft API 访问权限申请（**必做，否则 403**）

#### 8.7.1 为什么需要这一步

2023 年起，Mojang 对所有**新注册**的 Azure App 强制白名单审核：你的 client_id 不在 Mojang 内部批准列表里时，最后一步 `POST https://api.minecraftservices.com/authentication/login_with_xbox` 会返回：

```http
HTTP/1.1 403 Forbidden

{
  "path": "/authentication/login_with_xbox",
  "errorMessage": "Invalid app registration, see https://aka.ms/AppRegInfo for more information"
}
```

HMCL / PCL2 / Prism 等老牌启动器的 client_id 是 2023 之前注册的，**祖父条款豁免**，所以代码里看不到任何针对此问题的处理 —— 不是它们做对了什么，而是它们运气好。

**在前 6 步（OAuth + XBL + XSTS）全部跑通**之后才会触发这个 403，所以 §8.6 的 curl 验证看不出来。

#### 8.7.2 申请前提：必须先有失败登录记录

微软审核员需要在后台看到 **"应用至少尝试过一次 Minecraft 登录"**（哪怕失败），才会受理。所以：

1. 先按 §8.1 ~ §8.3 完成 Azure 注册
2. 把 `MSA_CLIENT_ID` 填到 `Constants.ets` 跑一次完整登录（必然会卡在 `[xbl/xsts/mc]` 阶段拿到 403）
3. **然后**再去填申请表 —— 否则可能被以 "未观测到 app 活动" 为由直接拒

#### 8.7.3 填表 cheat sheet

表单地址：**[https://aka.ms/mce-reviewappid](https://aka.ms/mce-reviewappid)**（重定向到 Microsoft Forms）

字段对应：

| 表单字段 | 填什么 | 在哪取 |
|---|---|---|
| Application Name | `AMCL Minecraft Launcher`（与 Azure 注册名一致） | Azure Portal → 应用 → 概述 → 名称 |
| Application ID (Client ID) | 36 位 GUID | Azure Portal → 应用 → 概述 → "应用程序(客户端) ID" |
| Tenant ID | `9188040d-6c67-4c5b-b112-36a304b66dad` | personal-only 应用固定值；若你是多租户 + 个人，则填 Azure Overview 上显示的 GUID |
| Application Description | 简明说明应用用途，建议英文，例：<br/>`AMCL is an open-source third-party Minecraft Java Edition launcher for HarmonyOS NEXT, targeting Huawei mobile/tablet devices. Users authenticate with their own Microsoft accounts to launch their legitimately purchased Minecraft Java Edition. Source code: https://github.com/<your-repo>.` | 自填 |
| Use Case | 选 "Custom Minecraft launcher" / "Authenticator for Minecraft" 之类（具体选项以表单当时显示为准） | — |
| Will the app be public / used by other users? | 老老实实写 `Yes, this is a public-facing launcher distributed as an open-source HarmonyOS HAP. End users sign in with their own Microsoft accounts.` | — |
| Source code link | GitHub 仓库 URL（公开 repo 大幅提升通过率） | — |
| Contact email | 你能收件的邮箱 | — |

> ⚠️ **不要谎报**为内部使用；微软会查 GitHub。诚实写明 "open-source third-party launcher" 反而通过率更高（HMCL/PCL2 都是这样过的）。

#### 8.7.4 审核周期

- **典型耗时**：3 ~ 14 天（社区反馈中位数约 5 天）
- **批准生效**：审核通过邮件到达后，**还要再等最多 24 小时**让白名单同步到 Mojang 节点
- **拒绝率**：合理填写 + 公开 repo 的拒绝率很低；最常见拒绝原因是"无活动记录"（见 §8.7.2）

#### 8.7.5 如何判断已批准

批准后**代码零修改**，直接重新走一次登录：

- ✅ 通过：UI 看到 "添加 Microsoft 账户成功"，账户出现在列表
- ❌ 还没生效：仍然 `登录失败 [xbl/xsts/mc]：[bearer] http_error: HTTP 403: Invalid app registration` —— 等 24 小时再试

#### 8.7.6 申请期间能做什么

本项目主链路 5 步（OAuth + XBL + XSTS + bearer + profile）已实现；申请等待期内可继续推进：

- M2 Phase B 剩余 UI 抛光（错误提示、加载态）
- HUKS 加解密单测（不依赖网络，CryptoProvider 注入 mock）
- 离线账户 / 启动参数注入 / 第三方皮肤站（M4）等不依赖正版登录的链路

### 8.8 合规与法务声明（M2 上线前必做）

1. **README.md 加免责声明**（中英双语）：
   > AMCL 是一款独立开发的第三方 Minecraft 启动器，与 Mojang Studios、Microsoft 或 Xbox 无关联、无授权。Minecraft 是 Mojang Studios 的商标。本启动器仅用于启动用户自有的正版 Minecraft Java 版。

2. **隐私政策**（即使只服务自己也要写）：
   - 采集范围：仅 Microsoft access_token / refresh_token / MC UUID / 用户名
   - 不上传到任何第三方服务器
   - 凭据本地 HUKS 加密存储

3. **MC EULA 合规**：确保启动器不分发 MC 客户端 jar（现状已符合：从官方 / BMCLAPI 镜像下载）

### 8.9 client_id 在代码里的存放

```typescript
// entry/src/main/ets/common/Constants.ets
// Microsoft 登录配置
export const MSA_CLIENT_ID = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'  // Azure 注册后填入
export const MSA_REDIRECT_URI = 'https://login.live.com/oauth20_desktop.srf'
export const MSA_SCOPE = 'XboxLive.signin offline_access'
export const MSA_AUTHORITY = 'https://login.microsoftonline.com/consumers'

// MC Services 配置（写死）
export const XBL_AUTH_URL = 'https://user.auth.xboxlive.com/user/authenticate'
export const XSTS_AUTH_URL = 'https://xsts.auth.xboxlive.com/xsts/authorize'
export const MC_BEARER_URL = 'https://api.minecraftservices.com/authentication/login_with_xbox'
export const MC_PROFILE_URL = 'https://api.minecraftservices.com/minecraft/profile'
```

---

## 九、凭据持久化设计（HUKS）

### 9.1 设计目标

- **at-rest 加密**：refresh_token / mc_access_token 不得明文落盘
- **密钥不离开 TEE**：通过 HUKS API 操作，应用进程只拿密文
- **应用卸载即失效**：HUKS 密钥绑定到应用包名，卸载后丢失（可接受，符合最小信任）
- **多账户支持**：每个账户独立加密条目，彼此隔离
- **向后兼容**：schema 含 `version` 字段，便于将来升级

### 9.2 密钥生命周期

- **生成时机**：首次登录时 `AccountStorage.ensureKey()` 若不存在则生成
- **密钥别名**：`amcl_account_aead_v1`
- **算法**：AES-GCM-256
- **关键 Tag**：

| Tag | 值 |
|---|---|
| `HKS_TAG_ALGORITHM` | `HKS_ALG_AES` |
| `HKS_TAG_KEY_SIZE` | `HKS_AES_KEY_SIZE_256` |
| `HKS_TAG_PURPOSE` | `HKS_KEY_PURPOSE_ENCRYPT \| HKS_KEY_PURPOSE_DECRYPT` |
| `HKS_TAG_BLOCK_MODE` | `HKS_MODE_GCM` |
| `HKS_TAG_PADDING` | `HKS_PADDING_NONE` |
| `HKS_TAG_DIGEST` | `HKS_DIGEST_SHA256` |

- **访问控制**：默认仅本应用进程可调；不导出（不设 `HKS_TAG_EXPORT`）；不允许备份云同步

### 9.3 加解密接口

```typescript
// AccountStorage.ets
export interface EncryptedBlob {
  iv: string          // Base64
  ciphertext: string  // Base64
  tag: string         // Base64 GCM tag
}

class AccountStorage {
  private static readonly KEY_ALIAS = 'amcl_account_aead_v1'

  static async encrypt(plaintext: string): Promise<EncryptedBlob> {
    // 1. ensureKey()
    // 2. 随机生成 IV（12 字节）
    // 3. HUKS init → update → finish
    // 4. 返回 {iv, ciphertext, tag} 全 Base64
  }

  static async decrypt(blob: EncryptedBlob): Promise<string> {
    // 逆过程，失败抛 AccountStorageError
  }

  static async saveAccount(record: AccountRecord): Promise<void> {
    // 敏感字段 JSON.stringify 后 encrypt，整体存到 preferences key = 'account_' + record.id
  }

  static async loadAllAccounts(): Promise<AccountRecord[]> {
    // 读 accounts_list，逐个 decrypt 后返回
  }
}
```

### 9.4 存储 schema

```typescript
interface AccountRecord {
  version: 1                        // schema 版本号，未来升级 bump
  id: string                        // UUID v4
  type: AccountType
  username: string                  // 明文（显示用）
  uuid: string                      // 明文（MC UUID）
  createdAt: number

  // 仅 MicrosoftAccount 有
  encrypted?: EncryptedBlob
  // encrypted 解密后的明文 JSON：
  // { refreshToken, mcAccessToken, mcTokenExpiresAt }
}
```

**Preferences 存储键**（`amcl_settings`）：

- `accounts_list`：JSON 数组（id 列表，决定显示顺序）
- `selected_account_id`：当前选中 id（空字符串表示用 OfflineAccount）
- `account_<id>`：每个账户一个 key，存 `JSON.stringify(record)`

---

## 十、UI 集成设计

### 10.1 入口

| 位置 | 内容 |
|---|---|
| 主页 Tab 顶栏右侧 | `AccountBadge`：头像（M4 上图）+ 用户名截断（最多 8 字），点击弹出 `AccountListSheet` |
| 设置 Sheet | 新增"账户管理"项（与"JDK 版本"同层级）|

### 10.2 `AddMicrosoftAccountSheet`

- **主模式（Auth Code + WebView）**：
  - 顶部标题"登录微软账户"
  - WebView 占 80% 高度，加载授权 URL
  - 底部：`取消` 按钮 + `改用验证码方式` 小字链接（切换到 Device Code 模式）
- **Device Code 模式**：
  - 大字展示 `user_code`（等宽字体）+ 复制按钮（`pasteboard.SystemPasteboard.setData`）
  - "打开浏览器登录"按钮（`startAbility action.viewData verification_uri_complete`）
  - 倒计时（15 分钟）+ 轮询状态（`等待授权... → 授权成功`）
  - `取消` 按钮

### 10.3 列表与切换

`AccountListSheet`：

- 头像 + 用户名 + 类型徽标（"正版" / "离线"）+ 当前选中 ✓
- 点击项 → 切换为选中
- 长按 / 右滑 → 删除（二次确认 + 可选"同时撤销服务端 token"）
- 底部 `+ 添加账户` 按钮

### 10.4 错误提示与回退

启动前 `account.refresh()` 失败：

| 错误类型 | UI 表现 | 用户选项 |
|---|---|---|
| 网络异常 | Sheet "网络异常，无法刷新登录" | 重试 / 离线启动 / 取消 |
| token 失效（refresh 也失败） | Sheet "凭据已过期，请重新登录" | 重新登录 / 离线启动 / 取消 |
| MC profile 404 | Sheet "该账户尚未购买 Minecraft" | 取消（无离线回退，因为不知 username） |

**离线回退实现**：临时构造 `OfflineAccount`，username 沿用原微软账户名，userType **保持 `msa`**（让 MC 本地启动，但联机会被服务端拒绝 —— 用户自负）。

---

## 十一、阶段化落地计划

### 11.1 M1：Account 抽象骨架（0.5 ~ 1 天，零风险）

**产出**：

- `Account.ets` / `OfflineAccount.ets` / `AccountManager.ets` / `AccountStorage.ets`（加密接口先 stub 为明文 passthrough，标 TODO）
- `McGamePage.startMC` 接入 `AccountManager.getSelected().fillProfile(builder)`
- `PreferenceManager` 加 `selectedAccountId` / `accountsList` 字段
- `OfflineAccount.test.ets`（UUID 派生 / fillProfile / serialize 往返）

**行为验证**：

- 现有测试全通过
- 真机启动 MC 行为与之前等价
- ⚠️ **离线 UUID 兼容性**：`OfflineAccount` 用 `nameUUIDFromBytes('OfflinePlayer:' + username)` 派生，与之前硬编码的全 0 UUID **不同**。需在 README / Toast 提示一次"账户 UUID 已升级"，或加一个迁移开关

**退路**：完全独立模块，可直接 revert。

### 11.2 M2：微软正版 MVP（2 ~ 3 天）

**Phase A（网络层 / 账户实现）— ✅ 已完成（2026-05-09）**

- ✅ `services/account/microsoft/HttpClient.ets`：HttpClient 抽象 + RealHttpClient
- ✅ `microsoft/MicrosoftOAuth.ets`：
  - `generatePkce()` / `buildAuthorizeUrl()`（Auth Code + PKCE 主流程）
  - `exchangeCodeForToken()` / `refreshAccessToken()`
  - `requestDeviceCode()` / `pollDeviceCodeOnce()`（备选）
- ✅ `microsoft/XboxLiveAuth.ets`：`authenticateXbl()` + `authorizeXsts()` + XErr 5 种码翻译
- ✅ `microsoft/MinecraftProfileApi.ets`：`loginWithXbox()` + `getProfile()` + 404 NOT_PREMIUM 检测
- ✅ `MicrosoftAccount.ets`：5 步链路 + 缓存策略（60s 安全边际）+ refresh_token 轮换写回
- ✅ 单测覆盖：`MicrosoftOAuth.test.ets` / `XboxLiveAuth.test.ets` / `MinecraftProfileApi.test.ets` / `MicrosoftAccount.test.ets`（HTTP 全 mock，CLI 测试通过）

**Phase B（HUKS 加密 / UI 集成）— ✅ 已完成（2026-05-09）**

- ✅ `utils/Base64Util.ets`：纯 JS RFC 4648 + 7515 base64（含 UTF-8 编解码），CLI 测试可用
- ✅ `services/account/CryptoProvider.ets`：CryptoProvider 接口 + PlaintextCryptoProvider stub（带 MARKER_IV 防混淆）
- ✅ `services/account/HuksCryptoProvider.ets`：HuksAesGcm256Provider — AES-256-GCM、12B nonce、16B tag、密钥别名 `amcl_account_master_v1`
- ✅ `AccountStorage.ets`：构造时注入 PlaintextCryptoProvider；`setCryptoProvider()` 由 AccountManager.init 探测后切 HUKS
- ✅ `AccountManager.ets`：init 异步探测 HUKS；`add()` 异步加密；`reload()` 异步解密；解密失败的账户记录静默丢弃
- ✅ `components/AddAccountSheet.ets`：三态（chooser/offline/microsoft），微软流程内嵌 Web 组件 `onLoadIntercept` 拦截 redirect_uri
- ✅ `components/AccountListSheet.ets`：列表 + 选中（绿色对勾）+ 删除（二次确认）+ 添加按钮嵌套 AddAccountSheet
- ✅ `pages/Index.ets`：HomeTab 头部显示当前账户卡片，点击调出 AccountListSheet；`onAccountsChanged` 回调驱动同步
- ✅ `pages/McGamePage.ets`：启动前 `await account.refresh()` → 仅 Microsoft 账户回写加密存储；OfflineAccount 跳过
- ✅ 单测覆盖：`Base64Util.test.ets`（17 case）/ `CryptoProvider.test.ets`（6 case），CLI 测试通过

**Phase B 跳过项 / 与原计划差异**：

- 原计划 `AccountStorage.test.ets` 的 HUKS 往返测试无法在 CLI 跑（HUKS 是设备/SE 服务）。降级方案：CryptoProvider 抽象 + PlaintextCryptoProvider 测试覆盖 storage 路径；HUKS provider 真功测试留真机验证清单。
- 原计划 `redactToken()` 日志脱敏未做（R-H3 缓解措施）。当前所有现有 `hilog` 调用均不打 token；新增告警在 Phase C 加 lint。
- WebView 选用 `Web` 组件 + `onLoadIntercept`（非 `onUrlLoadIntercept`），HarmonyOS NEXT 推荐 API。

**行为验证 — 真机待跑**：

- [ ] 真机完整跑一次 Microsoft 登录（PKCE + WebView redirect 拦截）
- [ ] 启动后 24h 重启验证 token 自动 refresh + 写回加密存储
- [ ] 长按账户行删除验证 HUKS 加密条目能被清理
- [ ] HUKS provider 在真机首次启动时 `generateKeyItem` 落库

### 11.3 M3：刷新与错误恢复（0.5 ~ 1 天）

**产出**：

- `getAccessToken()` 自动判断过期阈值（提前 60s）
- 启动前 refresh 失败分类提示（网络 / token 失效 / 未购买）
- 设置项：`启动前刷新账户`（默认开启）/ `离线回退`（默认开启）
- 注销流程：调用 `https://login.live.com/oauth20_logout.srf` 撤销 refresh_token

**行为验证**：

- 手动改系统时间 +25h，启动触发 refresh
- 断网启动触发离线回退提示
- refresh_token 失效（手动到 https://account.live.com/consent/Manage 撤销应用授权）后，启动报"请重新登录"

### 11.4 M4：Authlib-Injector + 头像（下迭代，1.5 天）

**产出**：

- `AuthlibInjectorAccount.ets`（LittleSkin / Blessing Skin 通用）
- `LaunchProfileBuilder` 加 `extraAgents: string[]` 字段，启动参数追加 `-javaagent:authlib-injector.jar=<api>`
- 头像渲染：`AccountBadge` 调 `https://crafatar.com/avatars/<uuid>?size=16`，24h 本地缓存

---

## 十二、风险评审

### 12.1 🔴 高风险（上线前必须解决）

| ID | 风险 | 概率 | 影响 | 缓解措施 |
|---|---|---|---|---|
| **R-H1** | 盗用 Mojang 官方 client_id（`00000000402b5328`）违反 Microsoft ToS | 低（已确认自行注册） | 法律 / 应用下架 | §8 教程走完即规避；README 写明合规边界 |
| **R-H2** | HUKS 错用导致 key 可备份/可导出 → refresh_token 泄漏 | 中（首次集成易出错） | 用户账户被盗 | M2 code review 必查 HUKS tag；参照 HUKS 官方 sample；新增 `AccountStorage.test.ets` 断言 key 属性不可导出 |
| **R-H3** | `hilog.info('argv=...')` 类语句打印 accessToken | 高（项目现有日志密度高） | hilog 被运营商/厂商收集时暴露 token | M2 统一封装 `redactToken(s)`；pre-commit grep `accessToken\|refreshToken` 出现在 hilog 时报警 |
| **R-H4** | 启动器被视作"未授权分发 MC 客户端" | 低（AMCL 不内置 jar） | 合规 | README + about 页显式声明与 Mojang 无关 |

### 12.2 🟠 中风险

| ID | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| **R-M1** | 国内访问 login.microsoftonline.com / xboxlive.com 不稳 | 高 | 登录失败率高 | 显式 timeout；错误提示明确指向网络；不镜像（auth 不能镜像） |
| **R-M2** | WebView `onLoadIntercept` 对 `oauth20_desktop.srf` 拦截不准 | 中 | Auth Code 流失败 | M2 前真机验证；失败自动回退 Device Code |
| **R-M3** | 系统 CA 不包含 Microsoft / DigiCert 根证书 | 低 | TLS 握手失败 | M2 启动加一次对 `login.microsoftonline.com` 的 HEAD probe |
| **R-M4** | 单账户 schema 后期改多账户代价大 | 中 | 重构 AccountManager | M1 schema 直接按多账户设计（`accounts_list` + `selected_account_id`） |

### 12.3 🟡 中低风险

| ID | 风险 | 缓解 |
|---|---|---|
| **R-L1** | MSA refresh_token 每次刷新可能下发新值，不重写下次失效 | `refreshAccessToken` 后无条件写回，单测覆盖 |
| **R-L2** | 60s 提前量可能仍导致首次请求过期 | 失败时 retry + 强制 refresh |
| **R-L3** | 真实打 Microsoft 端点导致限流 | HttpClient 注入 mock，禁止 CI/单测连真实网 |
| **R-L4** | Device Code 倒计时丢失（用户切后台） | 用 `verification_uri_complete`（带 code 的完整 URL），跳一次即可 |
| **R-L5** | 账户切换后游戏内仍显示旧名 | MC 启动时 args 已确定，需重启游戏；UI 提示"切换账户后请重启游戏" |

### 12.4 🟢 低风险

| ID | 风险 | 备注 |
|---|---|---|
| **R-VL1** | i18n 错误文案 | 直接用 PCL2 中文译法 |
| **R-VL2** | `ohos.permission.INTERNET` 已有 | 无需改 module.json5 |
| **R-VL3** | JDK 17/21 切换影响 | 账户字段是字符串透传，与 JDK 版本无关 |
| **R-VL4** | 用户问"为什么没有 LittleSkin" | ROADMAP 写清 M4 时间线 |
| **R-VL5** | Azure 应用名被搜到产生品牌混淆 | 用 `AMCL Minecraft Launcher` 而非 `Minecraft` |

### 12.5 ⚪ 已规避（本方案的红利）

| ID | 已规避项 | 说明 |
|---|---|---|
| **R-SKIP1** | C++ / NAPI / Java 中间层 | 全链路下游基础设施已就位，零改动 |
| **R-SKIP2** | 5/9 报告 5 个长文件 | `ForgeService.ets` 1270 / `jvm_launcher.cpp` 1180 / `mc_launcher.cpp` 1146 / `LaunchProfileBuilder.ets` 746 / `Index.ets` 981 |
| **R-SKIP3** | 与 ForgeService 拆分独立 | 可并行进行 |
| **R-SKIP4** | 不引入新第三方依赖 | 全部基于 HarmonyOS 系统 API |

---

## 十三、影响面评估（对照 5/9 自检报告）

| 5/9 维度 | 基线分 | 预估变化 | 说明 |
|---|---|---|---|
| 6. ArkTS UI 层 | 7.8 | **+0.2 ~ +0.4** | 新增 6~9 个 100~300 行 component，延续"小而精"风格 |
| 13. 测试 | 6.5 | **+0.3** | 新增 6 个 .test.ets（Offline/MS OAuth/XBL/MC Profile/Storage/Manager） |
| 14. 安全 | 7.5 | **+0.4** | 首次引入 HUKS at-rest 加密，提升整体凭据卫生 |
| 1/2/3 长文件 | — | **不变** | 本方案零改动 |
| 12. 根目录配置 | 8.0 | **不变** | 无新第三方依赖 |
| **整体评分** | **8.2** | **+0.2 ~ +0.4** | 可冲击 8.4 ~ 8.6 |

---

## 十四、测试策略

### 14.1 单元测试（ArkTS `@ohos/hypium`）

| 测试文件 | 覆盖 |
|---|---|
| `OfflineAccount.test.ets` | UUID 派生 / fillProfile / serialize 往返 |
| `MicrosoftOAuth.test.ets` | PKCE 生成 / code→token exchange / refresh / Device Code polling |
| `XboxLiveAuth.test.ets` | XBL / XSTS 正常路径 / XErr 全 5 个错误码 |
| `MinecraftProfileApi.test.ets` | profile 200 / 404 NOT_PREMIUM / token 过期 |
| `AccountStorage.test.ets` | HUKS encrypt/decrypt 往返 / 密钥属性校验 |
| `AccountManager.test.ets` | add/remove/select 多账户语义 |

**mock 策略**：所有 HTTP 调用注入 mock client（`HttpClient` 接口 + `FakeHttpClient`），**严禁真实打网**（避免 Microsoft 限流封禁）。

### 14.2 集成测试（`ohosTest/`）

- 真机完整登录一次（手动，非 CI）
- 启动 MC 并进 Hypixel / Mineplex 验证 session 通过
- 断网启动触发离线回退
- 24h 后重启验证 token 自动 refresh

### 14.3 回归矩阵

| 场景 | 预期 |
|---|---|
| M1 后：未切账户启动 MC | 行为与之前等价（离线，username = MCPlayer） |
| M2 后：选中微软账户启动 MC | UUID/username 真实，联机可用 |
| M3 后：24h 未启动后启动 | 自动 refresh 成功 |
| M3 后：refresh_token 服务端被撤销 | Sheet 弹"请重新登录" |
| 切换账户后启动 | 新账户 username 进入 MC |

---

## 十五、与 5/9 自检报告对照

本方案**不触及**以下报告里的结构性问题：

- 🟠 `ForgeService.ets` 1270 行拆分（与账户模块完全解耦）
- 🟠 `jvm_launcher.cpp` 1180 行瘦身（C 层零改动）
- 🟠 `mc_launcher.cpp` 1146 行瘦身（C 层零改动）
- 🟠 无 CI 烟雾测试（本方案增加的单测天然兼容未来 CI）

本方案**协助**以下问题：

- 🟢 跨页面参数传递三种并存 → `AccountManager` 用 AppStorage 单例统一，示范"单例 + AppStorage"模式，可作为未来其他模块统一参考
- 🟢 `oh-package.json5` description 占位 → 实施 M2 时顺手把 description 改成 `AMCL Minecraft Launcher for HarmonyOS NEXT`

---

## 十六、参考资料

**Microsoft Identity**：

- [OAuth 2.0 Authorization Code Flow with PKCE](https://learn.microsoft.com/azure/active-directory/develop/v2-oauth2-auth-code-flow)
- [Device Code Flow](https://learn.microsoft.com/azure/active-directory/develop/v2-oauth2-device-code)
- [App Registration Quickstart](https://learn.microsoft.com/azure/active-directory/develop/quickstart-register-app)
- [MSA Redirect URI for Desktop](https://learn.microsoft.com/azure/active-directory/develop/msal-client-application-configuration#redirect-uri)

**Minecraft Services**：

- [Microsoft Authentication Scheme (Wiki.vg)](https://wiki.vg/Microsoft_Authentication_Scheme)
- [XErr Codes](https://wiki.vg/Microsoft_Authentication_Scheme#Authenticate_with_XSTS)

**参考实现**：

- HMCL: https://github.com/HMCL-dev/HMCL/tree/main/HMCLCore/src/main/java/org/jackhuang/hmcl/auth
- PCL2: https://github.com/Hex-Dragon/PCL2 (VB.NET)
- Prism Launcher: https://github.com/PrismLauncher/PrismLauncher/tree/develop/launcher/minecraft/auth

**HarmonyOS**：

- [@ohos.web.webview](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-webview-V5)
- [@ohos.security.huks](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-huks-V5)
- [@ohos.security.cryptoFramework](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-cryptoframework-V5)

**项目内相关文档**：

- `docs/architecture.md` —— 启动链路全景
- `docs/self-inspection/2026-05-09_AMCL_项目全面评审报告.md` —— 当前状态基线
- `entry/src/main/ets/services/LaunchProfileBuilder.ets` —— 下游接入点
- `docs/security-signing.md` —— 现有安全/签名合规边界

---

## 十七、决策记录

| 决策 | 选择 | 备选 | 拍板时间 | 决策者 |
|---|---|---|---|---|
| OAuth 主流程 | Auth Code + PKCE + WebView（HMCL 同款） | Device Code | 2026-05-09 | 用户确认 |
| OAuth 备流程 | Device Code（PCL2 同款，WebView 故障回退） | 无 | 2026-05-09 | 用户确认 |
| 第一期账户类型 | 离线 + 微软 | + Authlib-Injector | 待定 | 待定（建议第二期再加） |
| Azure 注册 | 由 AMCL 团队自行注册（用户已有 MSA 开发者账号） | 借用其他启动器 client_id（违反 ToS，否决） | 2026-05-09 | 用户 |
| 凭据加密 | HUKS AES-GCM-256 | JavaApp Keystore / Preferences 明文 | 2026-05-09 | 本方案 |
| client_id 是否公开提交 | 是（行业惯例） | 走环境变量 + build-profile 注入 | 2026-05-09 | 本方案 |

---

## 附录 A：启动链路差异对比

**M1 前**（当前）：

```
McGamePage.startMC → builder(6 fields) → mcLaunchWithProfileV2
  默认值 MCPlayer / 全0 UUID / 全0 token / legacy
  Session 无效，皮肤 Steve/Alex
```

**M1 后**（账户抽象骨架，仅离线）：

```
McGamePage.startMC
  → AccountManager.getSelected() → OfflineAccount
  → account.fillProfile(builder)
  → builder(10 fields) → mcLaunchWithProfileV2
  行为等价：username=MCPlayer，UUID 由名字派生（与 Mojang 离线规则一致）
```

**M2 后**（微软正版可用）：

```
McGamePage.startMC
  → AccountManager.getSelected() → MicrosoftAccount
  → await account.refresh()  // 启动前强制刷新一次
  → account.fillProfile(builder)
  → builder(10 fields, 真实账户)
  → mcLaunchWithProfileV2
  MC 联机可用，皮肤可用
```

**M3 后**（错误恢复完善）：

```
McGamePage.startMC
  → AccountManager.getSelected() → MicrosoftAccount
  → try refresh()
       网络失败  → Sheet「重试 / 离线启动 / 取消」
       token 失效 → Sheet「重新登录 / 离线启动 / 取消」
       成功 → fillProfile → mcLaunchWithProfileV2
```

**M4 后**（含 Authlib-Injector）：

```
[同 M3 + 第三方账户路径]
  AuthlibInjectorAccount.fillProfile(builder)
    → builder.extraAgents.push('-javaagent:authlib-injector.jar=<api>')
    → 启动参数自动包含 javaagent
```

---

**文档结束**
