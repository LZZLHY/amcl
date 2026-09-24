/**
 * AddAccountSheet.ets — 添加账户半屏 Sheet（v2 · 2026-05-23）
 *
 * v1 → v2 视觉升级：
 *   - Chooser 视图：微软账户从普通卡片提升为渐变 Hero 卡（含 4 色 logo +
 *     "皮肤同步 / 披风 / 联机" 三 chip）；离线卡保持浅色 secondary 视觉
 *   - Microsoft 视图：
 *       · 顶部加 step progress（1/3 授权 → 2/3 令牌 → 3/3 档案）
 *       · 底部加 SafeArea footer（"WebView 由 ArkWeb 提供" + 取消按钮），
 *         消除原版底部纯黑的"未完成感"
 *       · 头部加返回 + helpBtn 按钮，结构与系统类 sheet 一致
 *   - 全部 view 都尊重 bottomSafeHeight 给底部留 home indicator 空间
 *
 * 不变项（保持兼容）：
 *   - OAuth Authorization Code + PKCE 流程逻辑（generatePkce / buildAuthorizeUrl /
 *     exchangeCodeForToken / completeMicrosoftLogin → AccountManager.add）
 *   - DESKTOP_EDGE_UA 反 anti-WebView 拦截策略（mobile UA 在 2024+ 会被拦）
 *   - state CSRF 校验
 *   - cookie 清理（防上次失败 session 污染）
 *
 * 模式：
 *   mode = 0 (chooser)   : 微软 / 离线 二选一
 *   mode = 1 (offline)   : 输入用户名
 *   mode = 2 (microsoft) : WebView 跑 OAuth
 *
 * 创建日期：2026-05-09 · v2 重设计 2026-05-23
 */

import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { ThemeColors } from 'commons';
import { MSA_REDIRECT_URI } from 'commons';
import { AppLogger } from 'commons';
import { LOG_DOMAIN_ACCOUNT } from 'commons';
import { common } from '@kit.AbilityKit';
import { getDownloadHistoryStore, ActivityCategory, ActivityStatus, ActivityRecord } from 'feature_core';
import { getAccountManager } from 'account';
import { OfflineAccount, randomAccountId } from 'account';
import { MicrosoftAccount, completeMicrosoftLogin } from 'account';
import { AuthlibInjectorAccount, authlibAuthenticate, authlibBindProfile, AuthlibAuthSession } from 'account';
import { AccountProfile } from 'account';
import { SKIN_SERVER_PRESETS, SkinServerPreset } from 'commons';
import {
  MicrosoftOAuth,
  generatePkce,
  buildAuthorizeUrl,
  PkceChallenge,
  MsaTokenSet,
} from 'account';
import { RealHttpClient } from 'account';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';

const TAG = 'AddAccountSheet';

// 模式常量（不用 enum，避免 ArkTS 严格类型问题）
const MODE_CHOOSER = 0;
const MODE_OFFLINE = 1;
const MODE_MICROSOFT = 2;
const MODE_AUTHLIB = 3;   // 第三方皮肤站（authlib-injector / Yggdrasil）

// 微软流程内部 stage（用于 step progress 高亮）
const STAGE_NONE = 0;       // WebView 中（用户在输密码）
const STAGE_TOKEN = 1;      // 换 MS token
const STAGE_XBOX_MC = 2;    // XBL/XSTS/MC bearer
const STAGE_PROFILE = 3;    // profile + persist

// ============================================================
//  桌面 Edge UA：绕过 MSA 对嵌入式 WebView 的反自动化拦截
//
//  Microsoft 自 2021 年起强制阻止 "embedded webview" 跑 OAuth（页面会显示
//  "this browser may not be supported"）。绕过手段：UA 伪装成桌面 Edge —
//  微软信任自家浏览器内核签名。HMCL 用 JavaFX WebKit UA 老旧反而被放行，
//  而 ArkWeb 默认 UA 含 "HuaweiBrowser/HMOS" 等明显嵌入式标记必被拦。
//
//  选桌面 Edge 而非移动 Edge：移动 UA 在 2024 年后被加进黑名单，桌面 UA
//  仍稳定。形态适配靠 sheet 高度（92% 安全区）+ Microsoft 自适应卡片，
//  实测 375vp 宽显示已可用。
// ============================================================
const DESKTOP_EDGE_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0';

@Component
export struct AddAccountSheet {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop bottomSafeHeight: number = 0;

  /** 添加成功后回调（UI 自行 close sheet）。 */
  onSuccess: () => void = () => {};
  /** 用户主动关闭 sheet（或加密失败放弃）。 */
  onClose: () => void = () => {};

  // ========= UI 状态 =========
  @State mode: number = MODE_CHOOSER;
  @State busy: boolean = false;            // chooser/offline 时的"添加中"
  @State errorMsg: string = '';
  @State statusMsg: string = '';           // 微软流程的进度文本
  @State stage: number = STAGE_NONE;       // step progress 高亮

  // Offline
  @State offlineUsername: string = '';

  // 第三方皮肤站（authlib-injector）
  @State authApiRoot: string = '';
  @State authUsername: string = '';
  @State authPassword: string = '';
  // 多角色选择：authenticate 后若账号有多个角色且未选中，进入选角态。
  @State authPickProfiles: AccountProfile[] = [];
  // authenticate 中间态（选角阶段用；不进 @State 深比对，仅持有引用）。
  private authSession: AuthlibAuthSession | null = null;

  // Microsoft
  @State authUrl: string = '';
  private pkceVerifier: string = '';
  private pkceState: string = '';   // CSRF 校验：必须与 redirect 中的 ?state= 匹配
  private webController: webview.WebviewController = new webview.WebviewController();
  // 防止 onLoadIntercept 多次触发同一个 code（WebView 重定向期间会反复回调）
  private codeConsumed: boolean = false;

  build() {
    Column() {
      if (this.mode === MODE_CHOOSER) {
        this.ChooserView();
      } else if (this.mode === MODE_OFFLINE) {
        this.OfflineView();
      } else if (this.mode === MODE_MICROSOFT) {
        this.MicrosoftView();
      } else if (this.mode === MODE_AUTHLIB) {
        this.AuthlibView();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgSecondary)
  }

  // ============================================================
  //  分支 1：选择账户类型
  // ============================================================

  @Builder
  ChooserView() {
    Column({ space: 14 }) {
      // 标题
      Text('添加账户')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme.textPrimary)
        .margin({ top: 8, bottom: 4 })

      // 微软正版 Hero 卡（渐变 + 阴影 + 三 chip）
      this.MicrosoftHero();

      // 第三方皮肤站卡
      this.AuthlibCard();

      // 离线账户卡
      this.OfflineCard();

      // 安全提示
      Row({ space: 10 }) {
        AppIcon({ name: AppIconName.Info, iconSize: 16, color: this.theme.primary })
        Text('令牌加密存储于设备 HUKS 安全区，不上传任何服务器')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.primary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 10, bottom: 10, left: 12, right: 12 })
      .backgroundColor(this.theme.primaryLight)
      .borderRadius(12)
      .alignItems(VerticalAlign.Top)

      if (this.errorMsg.length > 0) {
        this.ErrorBanner(this.errorMsg);
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 + this.bottomSafeHeight })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  MicrosoftHero() {
    Column({ space: 14 }) {
      // 上半：logo + 标题 + 描述
      Row({ space: 12 }) {
        // 4 色微软 logo
        Stack() {
          Column()
            .width(48)
            .height(48)
            .borderRadius(12)
            .backgroundColor('#FFFFFF')
          this.MicrosoftLogo();
        }
        .width(48)
        .height(48)

        Column({ space: 4 }) {
          Row({ space: 8 }) {
            Text('微软正版账户')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Row() {
              Text('推荐')
                .fontSize(10)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
            }
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor('#FFFFFF30')
            .borderRadius(6)
          }
          .alignItems(VerticalAlign.Center)
          Text('使用 Microsoft 账户登录，可加入正版服务器')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFFCC')
            .maxLines(2)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 下半：三个 chip
      Row({ space: 8 }) {
        this.HeroChip(AppIconName.ResourcePack, '皮肤同步');
        this.HeroChip(AppIconName.Shader, '披风');
        this.HeroChip(AppIconName.Game, '联机');
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .borderRadius(16)
    .linearGradient({
      angle: 135,
      colors: [['#0064CC', 0.0], ['#007DFF', 1.0]],
    })
    .shadow({
      radius: 24,
      color: '#007DFF40',
      offsetX: 0,
      offsetY: 8,
    })
    .onClick(() => { this.startMicrosoftLogin(); })
  }

  @Builder
  MicrosoftLogo() {
    Stack() {
      // 4x4 网格的 4 色块
      Column().width(10).height(10).backgroundColor('#F25022')
        .position({ x: 13, y: 13 })
      Column().width(10).height(10).backgroundColor('#7FBA00')
        .position({ x: 25, y: 13 })
      Column().width(10).height(10).backgroundColor('#00A4EF')
        .position({ x: 13, y: 25 })
      Column().width(10).height(10).backgroundColor('#FFB900')
        .position({ x: 25, y: 25 })
    }
    .width(48)
    .height(48)
  }

  @Builder
  HeroChip(icon: AppIconName, label: string) {
    Row({ space: 5 }) {
      AppIcon({ name: icon, iconSize: 12, color: '#FFFFFF' })
      Text(label)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .backgroundColor('#FFFFFF20')
    .borderRadius(8)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  OfflineCard() {
    Row({ space: 14 }) {
      Row() {
        AppIcon({ name: AppIconName.Person, iconSize: 24, color: this.theme.textSecondary })
      }
      .width(48)
      .height(48)
      .borderRadius(12)
      .backgroundColor(this.theme.bgInput)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Column({ space: 3 }) {
        Text('离线账户')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary)
        Text('仅本地用户名，无法加入正版服务器')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textSecondary)
          .maxLines(2)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      AppIcon({ name: AppIconName.ChevronRight, iconSize: 18, color: this.theme.textHint })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(16)
    .alignItems(VerticalAlign.Center)
    .onClick(() => { this.mode = MODE_OFFLINE; this.errorMsg = ''; })
  }

  @Builder
  AuthlibCard() {
    Row({ space: 14 }) {
      Row() {
        AppIcon({ name: AppIconName.ResourcePack, iconSize: 24, color: this.theme.primary })
      }
      .width(48)
      .height(48)
      .borderRadius(12)
      .backgroundColor(this.theme.primaryLight)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Column({ space: 3 }) {
        Text('第三方皮肤站')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary)
        Text('外置登录（authlib-injector），如 LittleSkin')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textSecondary)
          .maxLines(2)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      AppIcon({ name: AppIconName.ChevronRight, iconSize: 18, color: this.theme.textHint })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(16)
    .alignItems(VerticalAlign.Center)
    .onClick(() => { this.enterAuthlibMode(); })
  }

  // ============================================================
  //  分支 2：离线账户表单
  // ============================================================

  @Builder
  OfflineView() {
    Column({ space: 16 }) {
      this.HeaderWithBack('添加离线账户');

      Text('用户名')
        .fontSize(14)
        .fontColor(this.theme.textSecondary)

      TextInput({ placeholder: '请输入用户名（默认 MCPlayer）', text: this.offlineUsername })
        .height(48)
        .fontSize(16)
        .fontColor(this.theme.textPrimary)
        .placeholderColor(this.theme.textHint)
        .backgroundColor(this.theme.bgInput)
        .borderRadius(12)
        .padding({ left: 14, right: 14 })
        .maxLength(16)
        .enabled(!this.busy)
        .onChange((value: string) => { this.offlineUsername = value; })

      Text('用户名只在本地使用，不与任何在线服务关联')
        .fontSize(12)
        .fontColor(this.theme.textHint)

      Blank()

      Button(this.busy ? '添加中...' : '添加')
        .type(ButtonType.Capsule)
        .width('100%')
        .height(48)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .backgroundColor(this.busy ? this.theme.disabled : this.theme.primary)
        .fontColor(this.theme.textOnPrimary)
        .enabled(!this.busy)
        .onClick(() => { this.addOffline(); })

      if (this.errorMsg.length > 0) {
        this.ErrorBanner(this.errorMsg);
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 + this.bottomSafeHeight })
    .alignItems(HorizontalAlign.Start)
  }

  // ============================================================
  //  分支 4：第三方皮肤站（authlib-injector）
  // ============================================================

  @Builder
  AuthlibView() {
    Column() {
      if (this.authPickProfiles.length > 0) {
        this.AuthlibProfilePicker();
      } else {
        this.AuthlibForm();
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  AuthlibForm() {
    Scroll() {
      Column({ space: 14 }) {
        this.HeaderWithBack('添加第三方账户');

        // 预设皮肤站快捷填充
        if (SKIN_SERVER_PRESETS.length > 0) {
          Text('常用皮肤站')
            .fontSize(13)
            .fontColor(this.theme.textSecondary)
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(SKIN_SERVER_PRESETS, (preset: SkinServerPreset) => {
              Row({ space: 6 }) {
                AppIcon({ name: AppIconName.ResourcePack, iconSize: 13, color: this.theme.primary })
                Text(preset.name)
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.theme.primary)
              }
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .margin({ right: 8, bottom: 8 })
              .backgroundColor(this.theme.primaryLight)
              .borderRadius(10)
              .alignItems(VerticalAlign.Center)
              .onClick(() => { this.authApiRoot = preset.apiRoot; this.errorMsg = ''; })
            }, (preset: SkinServerPreset) => preset.apiRoot)
          }
          .width('100%')
        }

        Text('服务器地址（API 根）')
          .fontSize(14)
          .fontColor(this.theme.textSecondary)
          .width('100%')
        TextInput({ placeholder: '如 https://littleskin.cn/api/yggdrasil', text: this.authApiRoot })
          .height(48)
          .fontSize(15)
          .fontColor(this.theme.textPrimary)
          .placeholderColor(this.theme.textHint)
          .backgroundColor(this.theme.bgInput)
          .borderRadius(12)
          .padding({ left: 14, right: 14 })
          .enabled(!this.busy)
          .onChange((v: string) => { this.authApiRoot = v; })

        Text('账号（邮箱 / 用户名）')
          .fontSize(14)
          .fontColor(this.theme.textSecondary)
          .width('100%')
        TextInput({ placeholder: '皮肤站注册的账号', text: this.authUsername })
          .height(48)
          .fontSize(15)
          .fontColor(this.theme.textPrimary)
          .placeholderColor(this.theme.textHint)
          .backgroundColor(this.theme.bgInput)
          .borderRadius(12)
          .padding({ left: 14, right: 14 })
          .enabled(!this.busy)
          .onChange((v: string) => { this.authUsername = v; })

        Text('密码')
          .fontSize(14)
          .fontColor(this.theme.textSecondary)
          .width('100%')
        TextInput({ placeholder: '账号密码', text: this.authPassword })
          .type(InputType.Password)
          .height(48)
          .fontSize(15)
          .fontColor(this.theme.textPrimary)
          .placeholderColor(this.theme.textHint)
          .backgroundColor(this.theme.bgInput)
          .borderRadius(12)
          .padding({ left: 14, right: 14 })
          .enabled(!this.busy)
          .onChange((v: string) => { this.authPassword = v; })

        Row({ space: 8 }) {
          AppIcon({ name: AppIconName.Info, iconSize: 14, color: this.theme.textHint })
          Text('账号密码将加密保存于设备，用于登录状态过期时自动重新登录')
            .fontSize(12)
            .fontColor(this.theme.textHint)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Button(this.busy ? '登录中...' : '登录')
          .type(ButtonType.Capsule)
          .width('100%')
          .height(48)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(this.busy ? this.theme.disabled : this.theme.primary)
          .fontColor(this.theme.textOnPrimary)
          .enabled(!this.busy)
          .onClick(() => { this.submitAuthlibLogin(); })

        if (this.errorMsg.length > 0) {
          this.ErrorBanner(this.errorMsg);
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 24 + this.bottomSafeHeight })
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  AuthlibProfilePicker() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Row() {
          AppIcon({ name: AppIconName.ChevronLeft, iconSize: 22, color: this.theme.textPrimary })
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor(this.theme.bgInput)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          if (this.busy) return;
          this.authPickProfiles = [];
          this.authSession = null;
          this.errorMsg = '';
        })
        Text('选择角色')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .alignItems(VerticalAlign.Center)

      Text('该账号下有多个角色，请选择要使用的角色')
        .fontSize(13)
        .fontColor(this.theme.textSecondary)
        .width('100%')

      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.authPickProfiles, (p: AccountProfile) => {
            Row({ space: 12 }) {
              Row() {
                AppIcon({ name: AppIconName.Person, iconSize: 20, color: this.theme.primary })
              }
              .width(40)
              .height(40)
              .borderRadius(10)
              .backgroundColor(this.theme.primaryLight)
              .justifyContent(FlexAlign.Center)
              .alignItems(VerticalAlign.Center)
              Text(p.name)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.theme.textPrimary)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              AppIcon({ name: AppIconName.ChevronRight, iconSize: 16, color: this.theme.textHint })
            }
            .width('100%')
            .padding(12)
            .backgroundColor(this.theme.bgCard)
            .borderRadius(12)
            .alignItems(VerticalAlign.Center)
            .opacity(this.busy ? 0.5 : 1.0)
            .onClick(() => { this.selectAuthlibProfile(p); })
          }, (p: AccountProfile) => p.id)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      if (this.errorMsg.length > 0) {
        this.ErrorBanner(this.errorMsg);
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 24 + this.bottomSafeHeight })
    .alignItems(HorizontalAlign.Start)
  }

  // ============================================================
  //  分支 3：微软 OAuth WebView
  // ============================================================

  @Builder
  MicrosoftView() {
    Column() {
      // —— 顶部 header（返回 + 标题 + 帮助） ——
      this.MicrosoftHeader();

      // —— 步骤 progress ——
      this.StepProgress();

      // —— 状态条 / 错误条 ——
      if (this.statusMsg.length > 0) {
        Row({ space: 8 }) {
          LoadingProgress()
            .color(this.theme.primary)
            .width(18)
            .height(18)
          Text(this.statusMsg)
            .fontSize(13)
            .fontColor(this.theme.textPrimary)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .backgroundColor(this.theme.primaryLight)
        .alignItems(VerticalAlign.Center)
      }

      if (this.errorMsg.length > 0) {
        this.ErrorBanner(this.errorMsg);
      }

      // —— WebView 占据剩余空间 ——
      Web({ src: this.authUrl, controller: this.webController })
        .layoutWeight(1)
        .width('100%')
        .domStorageAccess(true)
        .javaScriptAccess(true)
        .mixedMode(MixedMode.None)
        .cacheMode(CacheMode.Default)
        // ⚠️ MSA 反 WebView 拦截：必须在 controller attach 时立即覆盖 UA，
        //   官方文档明确：在 onLoadIntercept 中设置概率性失败。
        .onControllerAttached(() => {
          try {
            this.webController.setCustomUserAgent(DESKTOP_EDGE_UA);
            AppLogger.info(TAG, `custom UA applied (length=${DESKTOP_EDGE_UA.length})`, LOG_DOMAIN_ACCOUNT);
          } catch (e) {
            let be = e as BusinessError;
            AppLogger.warn(TAG, `setCustomUserAgent failed: code=${be.code}`, be, LOG_DOMAIN_ACCOUNT);
          }
        })
        .onLoadIntercept((event) => {
          let url = event.data.getRequestUrl();
          if (url && url.indexOf(MSA_REDIRECT_URI) === 0 && !this.codeConsumed) {
            this.codeConsumed = true;
            this.handleAuthRedirect(url);
            return true;  // 阻止 WebView 继续加载 redirect URL
          }
          return false;
        })
        .onErrorReceive((event) => {
          // 网络/SSL/DNS 错误：把详情上抛到 UI banner，避免用户看到空白以为卡死
          if (!event || !event.request || !event.error) return;
          let req = event.request;
          let err = event.error;
          let isMain = req.isMainFrame();
          let url = req.getRequestUrl();
          let desc = err.getErrorInfo();
          let code = err.getErrorCode();
          AppLogger.warn(TAG, `Web onErrorReceive: mainFrame=${isMain ? 'true' : 'false'} code=${code} desc=${desc} url=${url}`, null, LOG_DOMAIN_ACCOUNT);
          // 仅主 frame 错误才打扰用户（图片 / 子资源失败不影响登录）
          if (isMain && this.errorMsg.length === 0) {
            this.errorMsg = '网页加载失败（' + desc + '）。请检查网络后返回重试。';
          }
        })

      // —— 底部安全区 footer（取消原版的纯黑底） ——
      this.MicrosoftFooter();
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  MicrosoftHeader() {
    Row({ space: 10 }) {
      Row() {
        AppIcon({ name: AppIconName.ChevronLeft, iconSize: 22, color: this.theme.textPrimary })
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor(this.theme.bgInput)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        if (this.statusMsg.length > 0) return;  // 后端流程进行中禁止后退
        this.mode = MODE_CHOOSER;
        this.errorMsg = '';
        this.codeConsumed = false;
        this.stage = STAGE_NONE;
      })

      Column({ space: 2 }) {
        Text('微软账户登录')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary)
          .maxLines(1)
        Text('login.microsoftonline.com')
          .fontSize(11)
          .fontWeight(FontWeight.Regular)
          .fontColor(this.theme.textHint)
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 6, bottom: 8, left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  StepProgress() {
    Row({ space: 8 }) {
      this.StepDot(1, '授权');
      this.StepLine(this.stage >= STAGE_TOKEN);
      this.StepDot(2, '令牌');
      this.StepLine(this.stage >= STAGE_XBOX_MC);
      this.StepDot(3, '档案');
    }
    .width('100%')
    .padding({ top: 6, bottom: 10, left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  StepDot(n: number, label: string) {
    Row({ space: 6 }) {
      // n=1 在 STAGE_NONE 时高亮（用户在 WebView 输密码就是"授权"中）
      // n=2 在 STAGE_TOKEN 时高亮
      // n=3 在 STAGE_XBOX_MC 或 STAGE_PROFILE 时高亮
      if (this.isStepDone(n)) {
        Row() {
          AppIcon({ name: AppIconName.Check, iconSize: 11, color: '#FFFFFF', weight: FontWeight.Bold })
        }
        .width(18)
        .height(18)
        .borderRadius(9)
        .backgroundColor(this.theme.success)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      } else {
        Row() {
          Text(String(n))
            .fontSize(10)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isStepActive(n) ? this.theme.textOnPrimary : this.theme.textHint)
        }
        .width(18)
        .height(18)
        .borderRadius(9)
        .backgroundColor(this.isStepActive(n) ? this.theme.primary : this.theme.bgInput)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      }
      Text(label)
        .fontSize(11)
        .fontWeight(this.isStepActive(n) ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.isStepActive(n) ? this.theme.textPrimary : this.theme.textHint)
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  StepLine(done: boolean) {
    Row()
      .layoutWeight(1)
      .height(2)
      .backgroundColor(done ? this.theme.success : this.theme.divider)
      .borderRadius(1)
  }

  @Builder
  MicrosoftFooter() {
    Column() {
      // 真正的底部 chrome：分隔线 + 安全提示 + 取消按钮
      Row({ space: 8 }) {
        AppIcon({ name: AppIconName.CheckCircle, iconSize: 13, color: this.theme.success })
        Text('WebView 由 ArkWeb 提供 · 仅访问 microsoft.com')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textSecondary)
          .layoutWeight(1)
        Text('取消')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.error)
          .padding({ left: 8, right: 4 })
          .onClick(() => { this.onClose(); })
      }
      .width('100%')
      .padding({ top: 10, bottom: 10, left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .border({
        width: { top: 1 },
        color: this.theme.divider,
      })
      // 系统底部安全区（home indicator 区域）—— 用主题底色填充避免黑边
      Row()
        .width('100%')
        .height(this.bottomSafeHeight)
    }
    .width('100%')
    .backgroundColor(this.theme.bgSecondary)
  }

  // ============================================================
  //  公共：标题栏（带返回按钮）+ 错误条
  // ============================================================

  @Builder
  HeaderWithBack(title: string) {
    Row({ space: 12 }) {
      Row() {
        AppIcon({ name: AppIconName.ChevronLeft, iconSize: 22, color: this.theme.textPrimary })
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor(this.theme.bgInput)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        if (this.busy || this.statusMsg.length > 0) return;  // 进行中禁止后退
        this.mode = MODE_CHOOSER;
        this.errorMsg = '';
        this.codeConsumed = false;
      })
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme.textPrimary)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ErrorBanner(msg: string) {
    Row({ space: 8 }) {
      AppIcon({ name: AppIconName.Error, iconSize: 16, color: this.theme.error })
      Text(msg)
        .fontSize(13)
        .fontColor(this.theme.error)
        .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.theme.errorBg)
    .borderRadius(8)
    .alignItems(VerticalAlign.Top)
  }

  // ============================================================
  //  step 状态判断
  // ============================================================

  /**
   * 当前是否在某一步"激活态"。
   *   - n=1: 用户在 WebView 输密码 = STAGE_NONE 时高亮
   *   - n=2: 在 STAGE_TOKEN 时高亮
   *   - n=3: 在 STAGE_XBOX_MC 或 STAGE_PROFILE 时高亮
   */
  private isStepActive(n: number): boolean {
    if (n === 1) return this.stage === STAGE_NONE;
    if (n === 2) return this.stage === STAGE_TOKEN;
    if (n === 3) return this.stage === STAGE_XBOX_MC || this.stage === STAGE_PROFILE;
    return false;
  }

  /** 是否已完成（已经走过这一步且开始下一步）。 */
  private isStepDone(n: number): boolean {
    if (n === 1) return this.stage >= STAGE_TOKEN;
    if (n === 2) return this.stage >= STAGE_XBOX_MC;
    if (n === 3) return false; // 第 3 步完成后整个流程就 onSuccess 关 sheet 了，不需要 done
    return false;
  }

  // ============================================================
  //  动作
  // ============================================================

  /** 写一条账户活动记录（仅存用户名+类型，绝不存 token）。 */
  private recordAccountActivity_(name: string, accType: string, status: string, errorMessage: string): void {
    let ctx = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
    if (!ctx) return;
    let nowMs = Date.now();
    let rec: ActivityRecord = {
      versionName: name,
      gameVersion: '-',
      loaderType: 'account',
      startedAt: nowMs,
      durationMs: 0,
      totalBytes: 0,
      fileCount: 0,
      status: status,
      category: ActivityCategory.ACCOUNT,
      endedAt: nowMs,
      title: name,
      subtitle: accType,
    };
    if (errorMessage.length > 0) rec.errorMessage = errorMessage;
    let store = getDownloadHistoryStore();
    store.init(ctx);
    store.add(rec).catch((e: Error) => {
      AppLogger.warn(TAG, 'account activity record failed', e, LOG_DOMAIN_ACCOUNT);
    });
  }

  /** 离线账户：直接 create + add + select。 */
  private async addOffline(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.errorMsg = '';
    try {
      let acc = OfflineAccount.create(this.offlineUsername);
      let am = getAccountManager();
      await am.add(acc);
      am.select(acc.id);
      AppLogger.info(TAG, `offline added: id=${acc.id} username=${acc.username}`, LOG_DOMAIN_ACCOUNT);
      this.recordAccountActivity_(acc.username, '离线账户', ActivityStatus.SUCCESS, '');
      this.onSuccess();
    } catch (e) {
      this.errorMsg = '添加失败：' + (e as Error).message;
      AppLogger.error(TAG, 'addOffline failed', e, LOG_DOMAIN_ACCOUNT);
      this.recordAccountActivity_(this.offlineUsername.length > 0 ? this.offlineUsername : '离线账户', '离线账户', ActivityStatus.FAILED, (e as Error).message);
    } finally {
      this.busy = false;
    }
  }

  // ============================================================
  //  第三方皮肤站（authlib-injector）动作
  // ============================================================

  /** 进入第三方登录表单：重置字段。默认预填首个预设地址（方便，可改）。 */
  private enterAuthlibMode(): void {
    this.mode = MODE_AUTHLIB;
    this.errorMsg = '';
    this.authPickProfiles = [];
    this.authSession = null;
    if (this.authApiRoot.length === 0 && SKIN_SERVER_PRESETS.length > 0) {
      this.authApiRoot = SKIN_SERVER_PRESETS[0].apiRoot;
    }
  }

  /**
   * 提交账密登录（阶段 1）。
   *   - 无角色 → 报错
   *   - 单角色 → 直接绑定并添加
   *   - 多角色 → 进入选角态
   */
  private async submitAuthlibLogin(): Promise<void> {
    if (this.busy) return;
    let root = this.authApiRoot.trim();
    let user = this.authUsername.trim();
    let pass = this.authPassword;
    if (root.length === 0) { this.errorMsg = '请输入服务器地址'; return; }
    if (user.length === 0) { this.errorMsg = '请输入账号'; return; }
    if (pass.length === 0) { this.errorMsg = '请输入密码'; return; }
    this.busy = true;
    this.errorMsg = '';
    try {
      let session = await authlibAuthenticate(root, user, pass);
      if (session.availableProfiles.length === 0) {
        this.errorMsg = '该账号下没有可用角色，请先在皮肤站创建角色';
        return;
      }
      this.authSession = session;
      if (session.availableProfiles.length === 1) {
        await this.finishAuthlibLogin(session.availableProfiles[0]);
      } else {
        // 多角色：进入选角态
        this.authPickProfiles = session.availableProfiles.slice();
      }
    } catch (e) {
      this.errorMsg = '登录失败：' + (e as Error).message;
      AppLogger.error(TAG, 'authlib authenticate failed', e, LOG_DOMAIN_ACCOUNT);
      this.recordAccountActivity_(this.authUsername.length > 0 ? this.authUsername : '第三方账户', '第三方皮肤站', ActivityStatus.FAILED, (e as Error).message);
    } finally {
      this.busy = false;
    }
  }

  /** 选角态：用户点选某个角色。 */
  private async selectAuthlibProfile(profile: AccountProfile): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.errorMsg = '';
    try {
      await this.finishAuthlibLogin(profile);
    } catch (e) {
      this.errorMsg = '登录失败：' + (e as Error).message;
      AppLogger.error(TAG, 'authlib bind profile failed', e, LOG_DOMAIN_ACCOUNT);
    } finally {
      this.busy = false;
    }
  }

  /** 绑定角色（阶段 2）→ 构造账户 → 添加 → 选中 → 成功回调。 */
  private async finishAuthlibLogin(profile: AccountProfile): Promise<void> {
    let session = this.authSession;
    if (session === null) {
      throw new Error('登录会话已失效，请重新登录');
    }
    let id = randomAccountId();
    let args = await authlibBindProfile(session, profile, id);
    let account = AuthlibInjectorAccount.fromInteractiveLogin(args);
    let am = getAccountManager();
    await am.add(account);
    am.select(account.id);
    AppLogger.info(TAG, `authlib account added: id=${account.id} username=${account.username} server=${args.serverName}`, LOG_DOMAIN_ACCOUNT);
    this.recordAccountActivity_(account.username, '第三方皮肤站', ActivityStatus.SUCCESS, '');
    this.authPickProfiles = [];
    this.authSession = null;
    this.onSuccess();
  }

  /**
   * 微软：生成 PKCE → 清理上一次会话的 cookie → 切到 WebView 模式。
   *
   * 必须清 cookie：否则用户上次失败的 session（半登录态、CAPTCHA 票据）会让
   * MSA 直接拒登录或自动登成旧账户。HMCL 自带新进程没这问题，鸿蒙 WebView
   * 同进程复用 cookie store。
   */
  private async startMicrosoftLogin(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    this.errorMsg = '';
    this.statusMsg = '';
    this.codeConsumed = false;
    this.stage = STAGE_NONE;
    try {
      // 1) 清掉上次的 MSA cookie（不影响其他站点的 cookie 因为 MSA 没存其他业务的）
      try {
        webview.WebCookieManager.clearAllCookiesSync();
        AppLogger.info(TAG, 'cookies cleared before MSA auth', LOG_DOMAIN_ACCOUNT);
      } catch (e) {
        let be = e as BusinessError;
        AppLogger.warn(TAG, `clearAllCookiesSync failed (non-fatal): code=${be.code}`, be, LOG_DOMAIN_ACCOUNT);
      }
      // 2) 生成 PKCE
      let pkce: PkceChallenge = await generatePkce();
      this.pkceVerifier = pkce.verifier;
      this.pkceState = pkce.state;
      this.authUrl = buildAuthorizeUrl(pkce);
      AppLogger.info(TAG, `authorize URL prepared (length=${this.authUrl.length})`, LOG_DOMAIN_ACCOUNT);
      this.mode = MODE_MICROSOFT;
    } catch (e) {
      this.errorMsg = '准备登录失败：' + (e as Error).message;
      AppLogger.error(TAG, 'startMicrosoftLogin failed', e, LOG_DOMAIN_ACCOUNT);
    } finally {
      this.busy = false;
    }
  }

  /**
   * WebView 截到 redirect_uri 后的处理：
   *   - 解析 ?code=xxx 或 ?error=xxx
   *   - 跑 token exchange + XBL/XSTS/MC + profile 全链路
   *   - 成功 → AccountManager.add → onSuccess
   */
  private async handleAuthRedirect(url: string): Promise<void> {
    let parsed = parseQueryParams(url);
    let err = parsed.get('error');
    if (err && err.length > 0) {
      let desc = parsed.get('error_description');
      this.errorMsg = '登录被拒绝（' + err + '）：' + (desc ? desc : '');
      this.statusMsg = '';
      AppLogger.warn(TAG, `oauth redirect with error: ${this.errorMsg}`, null, LOG_DOMAIN_ACCOUNT);
      return;
    }
    let code = parsed.get('code');
    if (!code || code.length === 0) {
      this.errorMsg = 'redirect 未带 code 参数';
      this.statusMsg = '';
      return;
    }
    // CSRF 校验：MSA 必须把我们发出去的 state 原样回传
    let state = parsed.get('state');
    if (!state || state !== this.pkceState) {
      this.errorMsg = 'state 校验失败（可能存在 CSRF 攻击或 redirect 不完整）';
      this.statusMsg = '';
      AppLogger.warn(TAG, `state mismatch: expected=${this.pkceState.substring(0, 8)}... got=${state ? state.substring(0, 8) + '...' : '<empty>'}`, null, LOG_DOMAIN_ACCOUNT);
      return;
    }

    // stage 用于在错误中提示用户具体卡在哪步（每步成功后立即推进）
    let stageLabel = 'token';
    try {
      this.stage = STAGE_TOKEN;
      this.statusMsg = '[1/4] 正在换取 Microsoft Token...';
      let http = new RealHttpClient();
      let oauth = new MicrosoftOAuth(http);
      let tokens: MsaTokenSet = await oauth.exchangeCodeForToken(code, this.pkceVerifier);

      stageLabel = 'xbl/xsts/mc';
      this.stage = STAGE_XBOX_MC;
      this.statusMsg = '[2/4] 正在请求 Xbox Live 授权...';
      let id = randomAccountId();
      let args = await completeMicrosoftLogin(tokens, id);

      stageLabel = 'persist';
      this.stage = STAGE_PROFILE;
      this.statusMsg = '[4/4] 正在保存账户...';
      let account = MicrosoftAccount.fromInteractiveLogin(args);
      let am = getAccountManager();
      await am.add(account);
      am.select(account.id);
      AppLogger.info(TAG, `microsoft account added: id=${account.id} username=${account.username} uuid=${account.uuid}`, LOG_DOMAIN_ACCOUNT);

      this.statusMsg = '';
      this.recordAccountActivity_(account.username, '微软账户', ActivityStatus.SUCCESS, '');
      this.onSuccess();
    } catch (e) {
      this.statusMsg = '';
      // stage 标签让用户能告诉我们卡在哪步：[token]=换 MS token，[xbl/xsts/mc]=Xbox 链路或 MC 档案，[persist]=加密落盘
      this.errorMsg = '登录失败 [' + stageLabel + ']：' + (e as Error).message;
      AppLogger.error(TAG, `handleAuthRedirect failed at stage=${stageLabel}`, e, LOG_DOMAIN_ACCOUNT);
      this.recordAccountActivity_('微软登录', '微软账户', ActivityStatus.FAILED, '[' + stageLabel + '] ' + (e as Error).message);
      // 允许用户重新登录：重置 codeConsumed
      this.codeConsumed = false;
      this.stage = STAGE_NONE;
    }
  }
}

// ============================================================
//  内部工具：解析 URL 的 query string
// ============================================================

/**
 * 从 URL 解析 query 参数为 Map<string, string>。
 * 兼容大小写 / 重复 key（重复时取最后一个）。不依赖 URL 类（ArkTS 部分版本不支持）。
 */
function parseQueryParams(url: string): Map<string, string> {
  let out = new Map<string, string>();
  let q = url.indexOf('?');
  if (q < 0) return out;
  let qs = url.substring(q + 1);
  let hash = qs.indexOf('#');
  if (hash >= 0) qs = qs.substring(0, hash);
  let parts = qs.split('&');
  for (let p of parts) {
    if (p.length === 0) continue;
    let eq = p.indexOf('=');
    let k: string;
    let v: string;
    if (eq < 0) {
      k = p;
      v = '';
    } else {
      k = p.substring(0, eq);
      v = p.substring(eq + 1);
    }
    try {
      k = decodeURIComponent(k);
      v = decodeURIComponent(v);
    } catch (e) {
      // 解码失败保留原值
    }
    out.set(k, v);
  }
  return out;
}
