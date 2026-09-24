/**
 * HomeTab.ets — 首页 Tab 组件（Phase R-2 重设计 2026-05-13）
 *
 * 设计稿：docs/design/download-page-redesign/05_app_home.png（Screen E）
 *
 * 重设计改动：
 *   - 删除原"3D 皮肤预览"40% 屏幕占位
 *   - 新增 AMCL Logo Header（左侧白色圆角 + 像素粉斧 icon + AMCL 标题，右侧 🔔 / ⚙）
 *   - Account Card 暴露令牌过期倒计时（占位文本）
 *   - **Hero Version Card 大蓝色卡**：超大 56sp 版本号 + Loader 副标题 + 3 个深蓝 chip
 *   - 状态指示行：● 就绪 · JDK 17 已加载（沿用现有 props）
 *   - **64dp 大启动按钮**（胶囊形）
 *   - Quick Stats 三列：已装版本数 / 已装模组数（占位）/ 上次游戏（占位）
 *   - 最近活动卡（占位）
 */

import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors } from 'commons';
import { AppIconName } from 'commons';
import { ActivityRecord, ActivityCategory, ActivityStatus } from 'feature_core';
import { getModpackIconPath } from 'mods';
// 一多适配（响应式）：设备形态 / 断点抽象，由 Index @Provide 下沉。
import { Breakpoint, DeviceForm } from 'commons';
import { AppIcon, AppIconButton, loaderIconForVersion } from '../../components/AppIcon';
import { inferLoaderKey, getLoaderInfo, resolveInstalledLoaderKey } from '../../components/LoaderCatalog';
import { MarqueeText } from '../../components/MarqueeText';
import { VersionBlockIcon } from '../../components/VersionBlockIcon';
import { MinecraftHeadAvatar } from '../../components/MinecraftHeadAvatar';
// 2026-05-23 语义色统一：账号验证 badge 走 SemanticColors，不再硬编码 #16A34A/#DCFCE7。
import { accountVerifiedTone } from '../../components/SemanticColors';
// 2026-05-24：FloatingDock 占高预留，让 Scroll 内容最后一项不被 dock 盖住
import { floatingDockReserveHeight } from 'commons';
import { MotionSection } from '../../components/MotionSection';

/**
 * 一多适配：宽屏（LG 断点 · 平板/2in1 横向）下首页内容收敛到的左栏定宽（vp）。
 * 右侧留白，供后续放新闻 / 自定义卡片。手机及窄窗口不使用此宽度（走整宽单列）。
 */
const HOME_WIDE_COLUMN_WIDTH: number = 480

@Component
export struct HomeTab {
  // 状态（只读，由父组件传入）
  @Prop theme: ThemeColors = {} as ThemeColors
  @Prop topSafeHeight: number = 0
  /** home indicator 安全区高度。用于算 Scroll 内容的 padding.bottom，避开底部悬浮 dock。 */
  @Prop bottomSafeHeight: number = 0
  /** 手机横屏：true 时整页可滚动（垂直空间小，避免启动按钮被挤出够不到）。 */
  @Prop isLandscape: boolean = false
  @Prop mcVersion: string = ''
  /** .minecraft 根目录（用于按 version.json 内容判定当前版本的 loader）。 */
  @Prop mcDir: string = ''
  @Prop mcXmx: number = 0
  @Prop selectedJdkVersion: string = '17'
  /** 当前版本实际生效的 JDK（全局选"自动"时为真正会用的版本号），用于展示。 */
  @Prop effectiveJdkVersion: string = '17'
  @Prop availableVersions: string[] = []
  @Prop jdkReady: boolean = false
  @Prop jdkExtractProgress: string = ''
  @Prop isRunning: boolean = false
  @Prop mcDownloading: boolean = false
  @Prop statusMsg: string = ''
  @Prop versionIsolation: boolean = true
  // M2 Phase B：账户信息
  @Prop accountUsername: string = 'MCPlayer'
  @Prop accountTypeLabel: string = '离线账户'
  /**
   * 当前账户的 Minecraft UUID（含连字符的 36 位标准格式）。
   * - 微软正版：从 profile 拿到，36 位有效字符串
   * - 离线账户：本地派生，不一定是 36 位 / 没意义 → 走首字母 fallback
   *
   * AccountCard 把它喂给 MinecraftHeadAvatar.uuid。Avatar 组件内部按 uuid 长度
   * 决定是否 fetch（< 36 位不发请求），同时 @Watch uuid 切换账户自动 reload。
   */
  @Prop accountUuid: string = ''
  /** 当前账户皮肤 URL（textures.minecraft.net）；头像优先从皮肤本地裁头，比第三方头像服务可靠。 */
  @Prop accountSkinUrl: string = ''
  // R-5：Quick Stats 实数据
  /** 当前选中版本的已装模组数（含禁用） */
  @Prop installedModsCount: number = 0
  /** 上次成功启动 MC 的 wall-clock 时间戳（ms），0 = 从未玩过 */
  @Prop lastPlayedAt: number = 0
  /** 有可用更新时在右上 ⚙ 设置入口显示红点。 */
  @Prop showUpdateDot: boolean = false
  /**
   * 铃铛未读角标文案（M4）：空串 = 不显示，'99+' = 超上限。
   * 由 Index 传入 —— HomeTab 不自己读存储，保持现有数据流方向。
   */
  @Prop unreadBadge: string = ''
  /** 最近活动记录（由 Index 传入，最新在前，已截到前几条）。 */
  @Prop recentActivities: ActivityRecord[] = []

  // ==================== 一多适配（响应式）====================
  // 由 Index @Provide 下沉：appBreakpoint=随窗口宽度变化的断点；deviceForm=出厂形态。
  // 宽屏（平板/2in1 横向）下首页走"左栏定宽 + 右侧留白"，手机/窄窗口维持整宽单列。
  @Consume('appBreakpoint') appBreakpoint: Breakpoint
  @Consume('deviceForm') deviceForm: DeviceForm

  // 回调
  onLaunch: () => void = () => {}
  /** 无已装版本时点大按钮「去下载」：跳「下载-版本」页。 */
  onGoDownload: () => void = () => {}
  onSelectVersion: (ver: string) => void = () => {}
  onDeleteVersion: (ver: string) => void = () => {}
  onOpenVersionManager: () => void = () => {}
  onOpenAccountList: () => void = () => {}
  /** 点击"已装模组" Quick Stats 卡 → 打开当前版本已装模组管理 sheet */
  onOpenInstalledMods: () => void = () => {}
  /**
   * 点击 PageHeader 右上角的 ⚙ 按钮 → 切到设置 Tab（index=2）。
   * 父组件 Index 持有 HdsTabsController，通过 changeIndex 完成切换。
   */
  onOpenSettings: () => void = () => {}
  /** 点铃铛 → 打开消息中心（M4）。 */
  onOpenMessages: () => void = () => {}


  build() {
    Column() {
      // 竖屏：首页【绝不整页滚动】，固定区 + 最近活动卡（卡内部自己滚动）。
      // 横屏：垂直空间小，整页用 Scroll 包起来可滚，否则启动按钮被挤出够不到。
      if (this.isLandscape) {
        Scroll() {
          this.HomeContent()
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.TopStart)
      } else {
        this.HomeContent()
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 首页主体内容（竖/横屏共用）。横屏时被外层 Scroll 包裹故不吃 layoutWeight。 */
  @Builder
  HomeContent() {
    Column({ space: 14 }) {
      // ============ AMCL Logo Header（设计稿 Screen E 顶部） ============
      this.PageHeader()

      // ============ Account Card（精简版 + 令牌过期占位） ============
      MotionSection({ order: 0 }) { this.AccountCard() }

      // ============ Hero Version Card（大蓝色卡核心新增） ============
      MotionSection({ order: 1 }) { this.HeroVersionCard() }

      // ============ 状态指示行（绿色脉冲点 + 详细状态文字） ============
      this.StatusRow()

      // ============ 大启动按钮（64 dp 胶囊形） ============
      this.LaunchButton()

      // ============ Quick Stats 三列 ============
      MotionSection({ order: 2 }) { this.QuickStatsRow() }

      // ============ 最近活动卡（竖屏吃剩余高度内部滚动；横屏随整页滚动） ============
      this.RecentActivityCard()
    }
    .width(this.isWideLayout() ? HOME_WIDE_COLUMN_WIDTH : '100%')
    // 竖屏吃满父高度；横屏在 Scroll 内按内容高度排布（layoutWeight 0 = 不撑高）
    .layoutWeight(this.isLandscape ? 0 : 1)
    // 竖屏固定主体铺到 dock 下方，尾部避让放在最近活动的内层 Scroll；横屏留白随整页滚动。
    .padding({ left: 20, right: 20, top: this.topSafeHeight + 8,
      bottom: this.isLandscape ? floatingDockReserveHeight(this.bottomSafeHeight) : 0 })
    .alignItems(HorizontalAlign.Start)
  }

  // ============================================================
  //  Builders
  // ============================================================

  /** AMCL Logo Header */
  @Builder
  PageHeader() {
    Row() {
      // 左侧 logo + 标题
      // 2026-05-25：品牌图标改为"圆角白底 + 像素粉斧"——与桌面 launcher icon
      // 一致（参见 entry/.../media/amcl_axe.png + startIcon.png 的合成方式）。
      // 用 syncLoad 防止 Scroll 首帧空白闪烁；ImageInterpolation.None 保留像素锐利。
      Row({ space: 10 }) {
        Stack() {
          Column()
            .width(36)
            .height(36)
            .backgroundColor('#FFFFFF')
            .borderRadius(10)
            .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
          Image($r('app.media.amcl_axe'))
            .width(30)
            .height(30)
            .objectFit(ImageFit.Contain)
            .interpolation(ImageInterpolation.None)
            .syncLoad(true)
        }
        Text('AMCL')
          .fontSize(22)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Center)

      // 右侧通知 / 设置入口
      Row({ space: 8 }) {
        // 铃铛 = 消息中心入口（M4）。此前是纯占位，点了没反应。
        Stack() {
          AppIconButton({
            name: AppIconName.Notification,
            iconSize: 18,
            color: this.theme.textPrimary,
            containerDiameter: 36,
            containerBg: this.theme.bgCard,
            containerRadius: 18,
            containerShadowRadius: this.theme.cardShadowRadius,
            containerShadowColor: this.theme.cardShadowColor,
            onAction: () => { this.onOpenMessages() },
          })
          // 未读角标：1~99 显示数字，超过显示 99+。白描边与 ⚙ 的更新红点同款做法，
          // 保证在任意底色上都看得清。
          if (this.unreadBadge.length > 0) {
            Row() {
              Text(this.unreadBadge)
                .fontSize(9)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.theme.textOnPrimary)
                .maxLines(1)
            }
            .padding({ left: this.unreadBadge.length > 1 ? 4 : 0, right: this.unreadBadge.length > 1 ? 4 : 0 })
            .constraintSize({ minWidth: 16 })
            .height(16)
            .borderRadius(8)
            .backgroundColor(this.theme.error)
            .border({ width: 2, color: this.theme.bgCard })
            .justifyContent(FlexAlign.Center)
            .offset({ x: 15, y: -13 })
          }
        }
        .alignContent(Alignment.Center)
        Stack() {
          AppIconButton({
            name: AppIconName.Settings,
            iconSize: 18,
            color: this.theme.textPrimary,
            containerDiameter: 36,
            containerBg: this.theme.bgCard,
            containerRadius: 18,
            containerShadowRadius: this.theme.cardShadowRadius,
            containerShadowColor: this.theme.cardShadowColor,
            onAction: () => {
              // 2026-05-24：原来跳 DevToolsPage（误设计），现在跳到设置 Tab。
              // 父组件 Index 通过 HdsTabsController.changeIndex(2) 切到第 3 个 tab。
              this.onOpenSettings()
            },
          })
          // 有可用更新时在 ⚙ 右上角叠一个红点（带白描边便于在任意底色上可见）
          if (this.showUpdateDot) {
            Circle({ width: 10, height: 10 })
              .fill(this.theme.error)
              .stroke(this.theme.bgCard)
              .strokeWidth(2)
              .offset({ x: 14, y: -14 })
          }
        }
        .alignContent(Alignment.Center)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 账户卡片 —— 头像 + 用户名 + 类型徽章 + 令牌过期提示 */
  @Builder
  AccountCard() {
    Row({ space: 10 }) {
      // 头像：MinecraftHeadAvatar 内部底层是蓝圆 + 首字母（fallback），uuid 拉到
      // Crafatar 头像后会盖一层 Image(pixelMap) 上去。
      // - 离线账户：传 uuid='' → 内部不发请求 → 只显示首字母
      // - 微软正版：传 uuid=acc.uuid → 内部走 RemoteImageCache 拉 + 解码 → 显示玩家头像
      //
      // 不再用 `Image(httpsUrl)` —— OpenHarmony 5 / API 14 那条路径有"静默不发请求"
      // 的 quirk（见 RemoteImage.ets / RemoteImageCache.ets 顶部考古注释）。
      MinecraftHeadAvatar({
        uuid: this.shouldFetchAvatar() ? this.accountUuid : '',
        skinUrl: this.accountSkinUrl,
        diameter: 36,
        // 圆角方形（cornerRadius=8）—— 方形 Minecraft 头像不被圆形裁角，hat overlay 边
        // 缘和发型轮廓都能完整看到。比起列表行的圆形头像，首页这一格更"产品 logo 感"。
        cornerRadius: 8,
        fallbackLetter: this.avatarLetter(),
        bgColor: this.theme.primary,
        letterColor: this.theme.textOnPrimary,
      })

      Column({ space: 4 }) {
        Text(this.accountUsername)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Text(this.accountTypeLabel)
            .fontSize(9)
            .fontWeight(700)
            .fontColor(this.accountTypeColor())
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .backgroundColor(this.accountTypeBg())
          // P3 占位：令牌过期倒计时（Microsoft 账户场景）
          Text(this.tokenExpiryHint())
            .fontSize(10)
            .fontColor(this.theme.textHint)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      AppIcon({
        name: AppIconName.ChevronRight,
        iconSize: 18,
        color: this.theme.textHint,
      })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(VerticalAlign.Center)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    .onClick(() => { this.onOpenAccountList() })
  }

  /** Hero Version Card —— 大蓝色卡片 + 56sp 版本号 */
  @Builder
  HeroVersionCard() {
    Column({ space: 12 }) {
      // 顶部："当前选中" 绿色脉冲点 + 右侧"切换版本 ▾" 深蓝按钮
      Row() {
        Row({ space: 6 }) {
          Circle({ width: 8, height: 8 }).fill(this.theme.success)
          Text('当前选中')
            .fontSize(11)
            .fontWeight(600)
            .fontColor('#BFDBFE')
        }
        .alignItems(VerticalAlign.Center)
        .layoutWeight(1)

        Row({ space: 4 }) {
          Text('切换版本').fontSize(11).fontWeight(600).fontColor(this.theme.textOnPrimary)
          AppIcon({ name: AppIconName.ChevronDown, iconSize: 11, color: this.theme.textOnPrimary })
        }
        .height(28)
        .padding({ left: 12, right: 12 })
        .borderRadius(14)
        .backgroundColor('#1E40AF')
        .alignItems(VerticalAlign.Center)
        .onClick(() => { this.onOpenVersionManager() })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 超大版本号 —— 长版本名（如 fabric-loader-0.18.6-1.20.4）会自动来回滚动；
      // 用户可手动左右拖；松手 2s 后恢复自动滚。短到能塞下时与普通 Text 视觉等价。
      MarqueeText({
        content: this.heroVersionText(),
        fontSize: 56,
        fontWeight: 700,
        fontColor: this.theme.textOnPrimary,
      })

      // Loader 副标题
      if (this.heroLoaderText().length > 0) {
        Row({ space: 6 }) {
          // 与版本管理 sheet / 下载页一致：用 3D 方块图标（草方块 / 铁砧 / Fabric / ...）
          // 18dp 比文字 14sp 略大，在 hero 蓝底上视觉上才能"立体"起来；
          // 14dp 跟字号同宽时立体感细节会糊
          VersionBlockIcon({
            versionId: this.mcVersion,
            iconSize: 18,
            cornerRadius: 0,
            overrideImagePath: getModpackIconPath(this.mcDir, this.mcVersion),
          })
          Text(this.heroLoaderText())
            .fontSize(14)
            .fontWeight(500)
            .fontColor(this.theme.textOnPrimary)
        }
        .alignItems(VerticalAlign.Center)
      }

      // 3 个深蓝 chip：JDK / Xmx / 隔离
      Row({ space: 6 }) {
        this.HeroChip(AppIconName.Java, 'JDK ' + this.effectiveJdkVersion)
        this.HeroChip(AppIconName.Memory, this.mcXmx > 0 ? this.mcXmx + ' MB' : '自动')
        this.HeroChip(
          this.versionIsolation ? AppIconName.IsolateOn : AppIconName.IsolateOff,
          this.versionIsolation ? '版本隔离' : '共享存档',
        )
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 20, bottom: 20 })
    .backgroundColor(this.theme.primary)
    .borderRadius(24)
  }

  @Builder
  HeroChip(icon: AppIconName, label: string) {
    Row({ space: 4 }) {
      AppIcon({ name: icon, iconSize: 11, color: '#BFDBFE' })
      Text(label)
        .fontSize(10)
        .fontWeight(500)
        .fontColor('#BFDBFE')
    }
    .height(24)
    .padding({ left: 10, right: 10 })
    .borderRadius(12)
    .backgroundColor('#1E40AF')
    .alignItems(VerticalAlign.Center)
  }

  /** 状态指示行 —— ● + 详细状态文字 */
  @Builder
  StatusRow() {
    Row({ space: 8 }) {
      Circle({ width: 8, height: 8 })
        .fill(this.statusColor())
      Text(this.statusDetailText())
        .fontSize(11)
        .fontWeight(500)
        .fontColor(this.statusColor())
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 2, bottom: 2 })
    .alignItems(VerticalAlign.Center)
  }

  /** 64 dp 大启动按钮 */
  @Builder
  LaunchButton() {
    Row({ space: 10 }) {
      AppIcon({
        name: this.noVersionInstalled() ? AppIconName.Download : (this.isRunning ? AppIconName.Hourglass : AppIconName.Play),
        iconSize: 22,
        color: this.theme.textOnPrimary,
        weight: FontWeight.Bold,
      })
      Text(this.launchButtonText())
        .fontSize(19)
        .fontWeight(700)
        .fontColor(this.theme.textOnPrimary)
    }
    .width('100%')
    .height(64)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .borderRadius(32)
    .backgroundColor(this.launchButtonActive() ? this.theme.primary : this.theme.disabled)
    .onClick(() => {
      if (this.noVersionInstalled()) {
        this.onGoDownload()          // 无版本：去「下载-版本」页
      } else if (this.canLaunch()) {
        this.onLaunch()              // 有版本：进启动前自检（无 JDK 也放行，由自检内联下载）
      }
    })
  }

  /**
   * Quick Stats 三列。
   *
   * 全部 inline 渲染 —— **不抽 @Builder StatCard(icon, value, label, ...)**。
   * 历史教训（与 VersionManagerSheet.DetailResourcesCard / DownloadTab 4 chip 同款）：
   * ArkUI 对 @Builder 函数的 primitive 参数（string / number / boolean）脏标记
   * 会漏报，外层 @Prop installedModsCount 改了之后 StatCard 内 value: string
   * 还停在初次构建时的快照值，UI 看起来"不变"。切换版本后 quick stats 数字
   * 永远停在打开 app 时刷上的那个值，必须杀进程重启才更新 = 这个 quirk。
   *
   * 唯一稳定的写法是直接在容器节点里读 this.xxx，不经过任何 @Builder 函数参数。
   * 因此把 3 张卡片 inline 写出来，多了 ~30 行重复 UI 代码，换正确性。
   */
  @Builder
  QuickStatsRow() {
    Row({ space: 10 }) {
      // ===== 已装版本 =====
      Column({ space: 4 }) {
        Text(this.availableVersions.length.toString())
          .fontSize(24).fontWeight(700).fontColor(this.theme.textPrimary)
        Row({ space: 4 }) {
          AppIcon({ name: AppIconName.GameController, iconSize: 11, color: this.theme.textHint })
          Text('已装版本').fontSize(11).fontWeight(500).fontColor(this.theme.textHint)
        }
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start).padding(12)
      .backgroundColor(this.theme.bgCard).borderRadius(14)
      .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
      .onClick(() => { this.onOpenVersionManager() })

      // ===== 已装模组 =====
      Column({ space: 4 }) {
        Text(this.installedModsText())
          .fontSize(24).fontWeight(700).fontColor(this.theme.textPrimary)
        Row({ space: 4 }) {
          AppIcon({ name: AppIconName.Mod, iconSize: 11, color: this.theme.textHint })
          Text('已装模组').fontSize(11).fontWeight(500).fontColor(this.theme.textHint)
        }
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start).padding(12)
      .backgroundColor(this.theme.bgCard).borderRadius(14)
      .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
      .onClick(() => { this.onOpenInstalledMods() })

      // ===== 上次游戏 =====
      Column({ space: 4 }) {
        Text(this.lastPlayedText())
          .fontSize(24).fontWeight(700).fontColor(this.theme.textPrimary)
        Row({ space: 4 }) {
          AppIcon({ name: AppIconName.Time, iconSize: 11, color: this.theme.textHint })
          Text('上次游戏').fontSize(11).fontWeight(500).fontColor(this.theme.textHint)
        }
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start).padding(12)
      .backgroundColor(this.theme.bgCard).borderRadius(14)
      .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
      .onClick(() => {
        this.getUIContext().getRouter().pushUrl({ url: 'pages/DownloadHistoryPage' })
          .catch((e: Error) => { hilog.warn(0x0000, 'HomeTab', 'push history: %{public}s', e.message) })
      })
    }
    .width('100%')
  }

  // ---- 活动记录展示 helper ----
  private activityCategoryLabel_(category: string): string {
    if (category === ActivityCategory.DOWNLOAD) return '下载'
    if (category === ActivityCategory.MOD_INSTALL) return '安装'
    if (category === ActivityCategory.LAUNCH) return '启动'
    if (category === ActivityCategory.REPAIR) return '修复'
    if (category === ActivityCategory.JDK) return 'JDK'
    if (category === ActivityCategory.ACCOUNT) return '账户'
    if (category === ActivityCategory.MODPACK) return '整合包'
    return '操作'
  }

  private activityStatusLabel_(status: string): string {
    // 账本恢复的运行/中断状态与取消不同，首页同样使用中文，不泄漏内部枚举值。
    if (status === 'running') return '进行中'
    if (status === 'interrupted') return '已中断'
    if (status === ActivityStatus.SUCCESS) return '成功'
    if (status === ActivityStatus.FAILED) return '失败'
    if (status === ActivityStatus.ABORTED) return '取消'
    if (status === ActivityStatus.CRASHED) return '崩溃'
    return status
  }

  private activityStatusColor_(status: string): string {
    if (status === 'running') return '#3B82F6'
    if (status === 'interrupted') return '#F59E0B'
    if (status === ActivityStatus.SUCCESS) return '#22C55E'  // 绿
    if (status === ActivityStatus.FAILED) return '#EF4444'   // 红
    if (status === ActivityStatus.CRASHED) return '#F97316'  // 橙
    return '#9CA3AF'                                          // 灰（取消/其它）
  }

  private activityRelativeTime_(ms: number): string {
    if (ms <= 0) return ''
    let diff = Date.now() - ms
    if (diff < 0) diff = 0
    let min = Math.floor(diff / 60000)
    if (min < 1) return '刚刚'
    if (min < 60) return min + ' 分钟前'
    let hr = Math.floor(min / 60)
    if (hr < 24) return hr + ' 小时前'
    let day = Math.floor(hr / 24)
    if (day < 30) return day + ' 天前'
    let d = new Date(ms)
    return (d.getMonth() + 1) + '-' + d.getDate()
  }

  /** 最近活动卡片（阶段4：接 DownloadHistoryStore 实数据）。吃剩余高度，列表内部滚动。 */
  @Builder
  RecentActivityCard() {
    Column({ space: 10 }) {
      Text('·  最近活动')
        .fontSize(11)
        .fontWeight(600)
        .fontColor(this.theme.textSecondary)
        .width('100%')

      if (this.recentActivities.length === 0) {
        // 空态：保持原有"点击进入"入口
        Row({ space: 12 }) {
          Stack() {
            Column().width(36).height(36).backgroundColor(this.theme.bgInput).borderRadius(10)
            AppIcon({ name: AppIconName.Download, iconSize: 18, color: this.theme.textSecondary })
          }
          .width(36).height(36)

          Column({ space: 2 }) {
            Text('暂无近期活动')
              .fontSize(13).fontWeight(500).fontColor(this.theme.textPrimary)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('下载 / 启动 / 安装后会记录在这里')
              .fontSize(11).fontColor(this.theme.textHint)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          AppIcon({ name: AppIconName.ChevronRight, iconSize: 16, color: this.theme.textHint })
        }
        .width('100%').alignItems(VerticalAlign.Center)
      } else {
        // 竖屏：列表内部滚动（内容超出只滚卡内，首页本身不滚动）
        // 横屏：整页已可滚，活动卡按内容自然排布（不再内部滚动，避免嵌套同向滚动冲突）
        if (this.isLandscape) {
          Column({ space: 10 }) {
            ForEach(this.recentActivities, (rec: ActivityRecord) => {
              this.ActivityRow(rec)
            // ActivityRow 使用值参数；同局 RUNNING 回退显示后，终态变化必须重建旧 builder。
            }, (rec: ActivityRecord, idx: number) => rec.startedAt.toString() + '_' + rec.status + '_' + idx.toString())
          }
          .width('100%')
        } else {
          Scroll() {
            Column({ space: 10 }) {
              ForEach(this.recentActivities, (rec: ActivityRecord) => {
                this.ActivityRow(rec)
              }, (rec: ActivityRecord, idx: number) => rec.startedAt.toString() + '_' + rec.status + '_' + idx.toString())
            }
            .width('100%')
            // 只增加可滚动内容尾部，不改变卡片/视口高度；最后一条可滚到浮栏上方。
            .padding({ bottom: floatingDockReserveHeight(this.bottomSafeHeight) })
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
    }
    .width('100%')
    // 竖屏吃剩余高度；横屏按内容高度随整页滚动（layoutWeight 0 = 不撑高）
    .layoutWeight(this.isLandscape ? 0 : 1)
    .constraintSize({ minHeight: 96 })
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(this.theme.bgCard)
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
    .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })
    .onClick(() => {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/DownloadHistoryPage' })
        .catch((e: Error) => { hilog.warn(0x0000, 'HomeTab', 'push history: %{public}s', e.message) })
    })
  }

  @Builder
  ActivityRow(rec: ActivityRecord) {
    Row({ space: 10 }) {
      // 状态色点 + 类别角标
      Stack() {
        Column().width(34).height(34).backgroundColor(this.theme.bgInput).borderRadius(9)
        Text(this.activityCategoryLabel_(rec.category ?? ''))
          .fontSize(10).fontWeight(600).fontColor(this.theme.textSecondary)
      }
      .width(34).height(34)

      Column({ space: 2 }) {
        Text((rec.title && rec.title.length > 0) ? rec.title : rec.versionName)
          .fontSize(13).fontWeight(500).fontColor(this.theme.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.activityRelativeTime_(rec.startedAt))
          .fontSize(11).fontColor(this.theme.textHint)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 状态徽章
      Text(this.activityStatusLabel_(rec.status))
        .fontSize(11).fontWeight(600)
        .fontColor(this.activityStatusColor_(rec.status))
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor(this.activityStatusColor_(rec.status) + '1A')  // 10% 透明底
        .borderRadius(8)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  // ============================================================
  //  helpers
  // ============================================================

  /**
   * 一多：是否走宽屏左栏布局。
   * 条件：① 出厂形态非手机（平板 / 2in1，避免手机横屏误触发）；② 当前窗口宽度达 LG 断点
   * （≥840vp，平板横屏 / 2in1 / 宽窗口）。两者皆满足才收敛为左栏 + 右侧留白；
   * 否则（手机、平板竖屏、分屏窄窗口）维持整宽单列。
   */
  private isWideLayout(): boolean {
    return this.deviceForm !== DeviceForm.PHONE && this.appBreakpoint === Breakpoint.LG
  }

  private avatarLetter(): string {
    if (!this.accountUsername || this.accountUsername.length === 0) return '?'
    return this.accountUsername.charAt(0).toUpperCase()
  }

  /**
   * 是否应该让 MinecraftHeadAvatar 真正去拉 Crafatar 头像。
   *
   * 离线账户的 UUID 是本地派生（hash 自 username），不一定是 32/36 位标准格式，
   * 即使是也不会有对应的玩家头像 → 直接传 '' 让 Avatar 走纯字母 fallback，
   * 省掉一次必然失败的 HTTP 请求。
   *
   * 微软账户的 uuid 早期版本存的是 32 位无连字符 hex，新版本走 formatCanonicalUuid
   * 之后是 36 位 dash 格式。Crafatar 两种都接受，所以这里两种长度都放行。
   */
  private shouldFetchAvatar(): boolean {
    if (!this.isAccountVerified()) return false
    return this.accountUuid.length === 32 || this.accountUuid.length === 36
  }

  /** 账号是否正版（微软）。独立出 helper 是为了 SemanticColors 调用点同源。 */
  private isAccountVerified(): boolean {
    return this.accountTypeLabel.indexOf('微软') >= 0
  }

  private accountTypeColor(): ResourceColor {
    return accountVerifiedTone(this.isAccountVerified(), this.theme).color
  }

  private accountTypeBg(): ResourceColor {
    return accountVerifiedTone(this.isAccountVerified(), this.theme).bg
  }

  /** P3 占位：Microsoft 账户的 token 过期倒计时。M2 之后由 AccountManager 提供 */
  private tokenExpiryHint(): string {
    if (this.accountTypeLabel.indexOf('微软') >= 0) {
      return '令牌有效'  // TODO: 接 AccountManager.getTokenExpiresIn() 后改为 "2h 56m 后到期"
    }
    return '离线模式 · 无需登录'
  }

  private heroVersionText(): string {
    if (this.availableVersions.length === 0) return '未安装'
    return this.mcVersion || '未选择'
  }

  private heroLoaderText(): string {
    // 整合包/重命名版本名里无 loader 关键字，改用 resolveInstalledLoaderKey 读 version.json 内容判定。
    let key = resolveInstalledLoaderKey(this.mcDir, this.mcVersion || '')
    if (key === 'vanilla') return '原版 Vanilla'
    return getLoaderInfo(key).displayName
  }

  private statusColor(): ResourceColor {
    if (this.availableVersions.length === 0) return this.theme.warning
    if (!this.jdkReady) return this.theme.warning
    if (this.mcDownloading) return this.theme.warning
    return this.theme.success
  }

  private statusDetailText(): string {
    if (this.availableVersions.length === 0) return '未安装任何版本 · 点「去下载」新建'
    if (this.mcDownloading) return '版本下载中，启动按钮已禁用'
    if (!this.jdkReady) return 'JDK 未安装 · 启动时可一键下载并安装'
    return '就绪 · JDK ' + this.effectiveJdkVersion + ' 已加载 · ' + this.heroLoaderText() + ' 完整性验证通过'
  }

  private launchButtonText(): string {
    if (this.noVersionInstalled()) return '去下载'
    if (this.isRunning) return '启动中...'
    if (this.mcDownloading) return '正在下载...'
    return '启动游戏'
  }

  /** 是否未安装任何版本（首次使用态：按钮变「去下载」）。 */
  private noVersionInstalled(): boolean {
    return this.availableVersions.length === 0
  }

  /** 按钮是否为「可点/主色」态：无版本(去下载) 或 可启动。 */
  private launchButtonActive(): boolean {
    return this.noVersionInstalled() || this.canLaunch()
  }

  private canLaunch(): boolean {
    // 注意：不再要求 jdkReady——无 JDK 也允许点击进入启动前自检，由自检内联提供
    // 「一同下载 JDK」。真正缺 JDK 的拦截 + 一键下载在 PreLaunchCheckSheet 完成。
    return !this.isRunning && !this.mcDownloading
      && this.availableVersions.length > 0
  }

  /** Quick Stats "已装模组" 数值。0 时显示 "—" 让视觉等同于"暂无"。 */
  private installedModsText(): string {
    if (this.availableVersions.length === 0) return '—'
    if (this.installedModsCount <= 0) return '0'
    return this.installedModsCount.toString()
  }

  /**
   * Quick Stats "上次游戏" 文案。
   *
   * 显示策略（与 PCL2 / HMCL 用户感知接近）：
   *   - 0 / 未来时间   → "—"
   *   - < 1 min        → "刚刚"
   *   - < 60 min       → "Xm 前"
   *   - < 24 h         → "Xh 前"
   *   - < 30 d         → "Xd 前"
   *   - 其它           → "MM-DD"
   *
   * 由 PreferenceManager.lastPlayedAt 在 Index.launchMC 时写入。
   */
  private lastPlayedText(): string {
    if (this.lastPlayedAt <= 0) return '—'
    let diffMs = Date.now() - this.lastPlayedAt
    if (diffMs < 0) return '—'
    let minutes = Math.floor(diffMs / 60000)
    if (minutes < 1) return '刚刚'
    if (minutes < 60) return minutes + 'm'
    let hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + 'h'
    let days = Math.floor(hours / 24)
    if (days < 30) return days + 'd'
    try {
      let d = new Date(this.lastPlayedAt)
      let m = String(d.getMonth() + 1).padStart(2, '0')
      let dd = String(d.getDate()).padStart(2, '0')
      return m + '-' + dd
    } catch (e) {
      return '—'
    }
  }
}
