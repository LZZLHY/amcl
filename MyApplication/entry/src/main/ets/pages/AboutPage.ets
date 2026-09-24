import { DistributionPolicy } from 'commons';
/**
 * AboutPage.ets — 关于页
 *
 * 入口：SettingsTab「关于」行 → getRouter().pushUrl('pages/AboutPage')。
 *
 * 内容：
 *   - 顶部居中软件图标（$media:amcl_axe）+ 名称 + 版本
 *   - GitHub 仓库链接（点击用系统浏览器打开 APP_REPO_URL）
 *   - 作者联系方式（邮箱，点击复制到剪贴板）
 *   - QQ 交流群号（点击复制到剪贴板）
 *   - 检查更新（复用 update HAR 的 UpdateChecker，有新版可跳转下载页）
 *
 * 主题/安全区/返回导航沿用其它 push 页（DownloadHistoryPage）的约定。
 *
 * 创建日期：2026-07-03
 */

import { common, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { APP_VERSION, APP_REPO_URL, AUTHOR_EMAIL, QQ_GROUP_ID } from 'commons';
import { BRAND_DISCLAIMER } from 'commons';
import { DeviceProfile } from 'commons';
import { AppIconName } from 'commons';
import { formatBytes } from 'commons';
import { AppIcon } from '../components/AppIcon';
import { UpdateDialog } from '../components/UpdateDialog';
import { PreferenceManager } from 'feature_system';
import { UpdateChecker, UpdateCheckResult, UpdateManifest } from 'update';

const TAG = 'AboutPage'

@Entry
@Component
struct AboutPage {
  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false)
  @StorageProp('topRectHeight') topSafeHeight: number = 0
  @StorageProp('bottomRectHeight') bottomSafeHeight: number = 0
  @StorageProp('currentColorMode') @Watch('onColorModeChange') currentColorMode: number = 0
  /** 检查更新进行中（禁用重复点击 + 显示「检查中…」）。 */
  @State private checkingUpdate: boolean = false
  /** 是否有可用更新（驱动「检查更新」行红点，与 Index 的自动更新红点同源判定）。 */
  @State private hasUpdate: boolean = false

  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  private prefManager: PreferenceManager = new PreferenceManager(this.context)
  /** 更新弹窗控制器：每次弹前重建（内容随 manifest 固化），持有引用只为让实例活到关闭。 */
  private updateDialogCtrl_: CustomDialogController | null = null

  aboutToAppear() {
    this.applyTheme_()
    // 上架轨（应用市场分发）：更新由应用市场负责，App 内暂不做 GitHub 检查更新。
    // 未来方向：接入应用市场的版本更新接口 / 跳转应用市场详情页检查更新。
    if (DistributionPolicy.isStore()) return
    // 这里只读启动检查留下的持久化结果，避免每次进入「关于」页又绕过 24h 节流联网。
    // 用户点击下方「检查更新」始终执行一次手动检查，不受自动节流影响。
    this.hasUpdate = UpdateChecker.hasCachedUpdate(
      UpdateChecker.currentVersionCode(), this.prefManager.latestSeenVersionCode)
  }

  /** 把手动检查结果落到红点、节流时间与 latestSeen。 */
  private applyUpdateResult_(res: UpdateCheckResult): void {
    if (!res.ok || res.manifest === null) return   // 网络/解析失败不动红点
    this.prefManager.lastUpdateCheckAt = Date.now()
    if (res.manifest.versionCode > this.prefManager.latestSeenVersionCode) {
      this.prefManager.latestSeenVersionCode = res.manifest.versionCode
    }
    this.hasUpdate = res.hasUpdate
    if (!res.hasUpdate) this.prefManager.updatePromptDeferredAt = 0
  }

  private applyTheme_(): void {
    let systemIsDark = (this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
    let mode = this.prefManager.themeMode
    this.theme = resolveTheme(mode, resolveIsDark(mode, systemIsDark))
  }

  onColorModeChange(): void {
    this.applyTheme_()
  }

  private safeToast_(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 })
    } catch (e) { /* UI 实例已销毁，忽略 */ }
  }

  /** 用系统浏览器打开 URL。 */
  private openUrl_(url: string): void {
    try {
      let want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url,
      }
      this.context.startAbility(want)
    } catch (e) {
      hilog.error(0x0000, TAG, 'openUrl failed: %{public}s', (e as Error).message)
      this.safeToast_('无法打开浏览器，请手动访问 ' + url)
    }
  }

  /** 复制文本到系统剪贴板 + 提示。 */
  private copyToClipboard_(text: string, label: string): void {
    try {
      let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.safeToast_('已复制' + label + '：' + text)
      }).catch((e: Error) => {
        hilog.warn(0x0000, TAG, 'setData failed: %{public}s', e.message)
        this.safeToast_('复制失败')
      })
    } catch (e) {
      this.safeToast_('复制失败')
    }
  }

  /** 检查更新：拉 update.json 比对 versionCode，弹结果。 */
  private async doCheckUpdate_(): Promise<void> {
    if (this.checkingUpdate) return
    this.checkingUpdate = true
    try {
      let res: UpdateCheckResult = await UpdateChecker.checkForUpdate()
      if (!res.ok) {
        this.safeToast_('检查更新失败：' + (res.error.length > 0 ? res.error : '未知错误'))
        return
      }
      this.applyUpdateResult_(res)   // 同步红点 + 持久化 latestSeen
      if (!res.hasUpdate || res.manifest === null) {
        this.safeToast_('已是最新版本 v' + APP_VERSION)
        return
      }
      this.showUpdateDialog_(res.manifest)
    } catch (e) {
      this.safeToast_('检查更新失败：' + (e as Error).message)
    } finally {
      this.checkingUpdate = false
    }
  }

  /**
   * 弹新版本提示（与 Index 的自动检查共用同一个 UpdateDialog 组件）。
   * 条目走 `UpdateChecker.displayEntries`：结构化优先、缺失时回退解析 notes，
   * 因此对新旧 update.json 都能渲染（见 AMCL-web/CHANGELOG-SPEC.md 第四节）。
   */
  private showUpdateDialog_(m: UpdateManifest): void {
    try {
      this.prefManager.updatePromptDeferredAt = 0
      let ctrl: CustomDialogController = new CustomDialogController({
        builder: UpdateDialog({
          theme: this.theme,
          newVersion: m.versionName.length > 0 ? m.versionName : m.tag,
          currentVersion: APP_VERSION,
          releaseDate: m.date,
          sizeLabel: m.sizeBytes > 0 ? formatBytes(m.sizeBytes) : '',
          mandatory: m.mandatory,
          entries: UpdateChecker.displayEntries(m),
          showChangelogEntry: true,
          onDownload: () => {
            this.closeUpdateDialog_()
            this.openUrl_(m.url.length > 0 ? m.url : APP_REPO_URL)
          },
          onLater: () => {
            this.prefManager.updatePromptDeferredAt = Date.now()
            // hasUpdate/latestSeenVersionCode 保留，红点不会因延后消失。
            this.closeUpdateDialog_()
          },
          onViewChangelog: () => {
            this.closeUpdateDialog_()
            this.openChangelog_()
          },
        }),
        autoCancel: !m.mandatory,
        customStyle: true,
        alignment: DialogAlignment.Center,
      })
      this.updateDialogCtrl_ = ctrl
      ctrl.open()
    } catch (e) {
      // 弹框不可用时退化为直接打开下载页，不能让用户点了没反应
      hilog.warn(0x0000, TAG, 'UpdateDialog open failed: %{public}s', (e as Error).message)
      this.openUrl_(m.url.length > 0 ? m.url : APP_REPO_URL)
    }
  }

  /** UpdateDialog 不拥有 controller；关闭统一由创建它的父页面执行。 */
  private closeUpdateDialog_(): void {
    let ctrl: CustomDialogController | null = this.updateDialogCtrl_
    this.updateDialogCtrl_ = null
    if (ctrl !== null) ctrl.close()
  }

  /** 打开更新日志页。 */
  private openChangelog_(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/ChangelogPage' })
    } catch (e) {
      hilog.warn(0x0000, TAG, 'push ChangelogPage failed: %{public}s', (e as Error).message)
    }
  }

  build() {
    Column() {
      // ===== 顶栏 =====
      Row() {
        Stack() {
          AppIcon({ name: AppIconName.Back, iconSize: 20, color: this.theme.textPrimary })
        }
        .width(40).height(40).borderRadius(20)
        .backgroundColor(this.theme.bgCard)
        .onClick(() => { this.getUIContext().getRouter().back() })

        Text('关于')
          .fontSize(20).fontWeight(700).fontColor(this.theme.textPrimary)
          .margin({ left: 12 }).layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.topSafeHeight + 12, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 16 }) {
          // ===== 头部：居中软件图标 + 名称 + 版本 =====
          Column({ space: 10 }) {
            Image($r('app.media.amcl_axe'))
              .width(96).height(96)
              .borderRadius(22)
              .draggable(false)
            Text('AMCL')
              .fontSize(24).fontWeight(700).fontColor(this.theme.textPrimary)
            Text('v' + APP_VERSION)
              .fontSize(14).fontWeight(500).fontColor(this.theme.primary)
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .alignItems(HorizontalAlign.Center)

          // ===== 信息卡片 =====
          Column() {
            // GitHub
            this.InfoRow('GitHub', APP_REPO_URL, AppIconName.ChevronRight, true,
              () => { this.openUrl_(APP_REPO_URL) })

            Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

            // 作者联系方式（邮箱，点击复制）
            this.InfoRow('作者联系方式', AUTHOR_EMAIL, AppIconName.Copy, false,
              () => { this.copyToClipboard_(AUTHOR_EMAIL, '邮箱') })

            Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

            // QQ 交流群（点击复制群号）
            this.InfoRow('QQ 交流群', QQ_GROUP_ID, AppIconName.Copy, false,
              () => { this.copyToClipboard_(QQ_GROUP_ID, '群号') })

            Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

            // 更新日志（上架轨也保留：数据走随包快照，不联网）
            this.InfoRow('更新日志', '查看每个版本的变更', AppIconName.ChevronRight, false,
              () => { this.openChangelog_() })

            // 检查更新（上架轨隐藏：更新交由应用市场；未来方向——跳转应用市场详情页 / 接入市场更新接口）
            if (!DistributionPolicy.isStore()) {
              Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

              Row() {
                Column() {
                  Text('检查更新')
                    .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
                  Text(this.checkingUpdate ? '检查中…' : ('当前 v' + APP_VERSION + ' · 从 GitHub 获取最新版本'))
                    .fontSize(12).fontColor(this.theme.textHint).margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (this.checkingUpdate) {
                  LoadingProgress().width(20).height(20).color(this.theme.primary)
                } else {
                  // 有可用更新时在箭头前显示红点
                  if (this.hasUpdate) {
                    Row().width(8).height(8).borderRadius(4).backgroundColor(this.theme.error).margin({ right: 8 })
                  }
                  AppIcon({ name: AppIconName.ChevronRight, iconSize: 16, color: this.theme.textHint })
                }
              }
              .width('100%').height(60).alignItems(VerticalAlign.Center)
              .onClick(() => { this.doCheckUpdate_() })
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .backgroundColor(this.theme.bgCard)
          .borderRadius(this.theme.cardRadius)
          .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })

          // ===== 免责声明卡片（知识产权合规） =====
          Column({ space: 8 }) {
            Text('免责声明')
              .fontSize(14).fontWeight(600).fontColor(this.theme.textPrimary).width('100%')
            Text(BRAND_DISCLAIMER)
              .fontSize(12).fontColor(this.theme.textSecondary).lineHeight(19).width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(this.theme.bgCard)
          .borderRadius(this.theme.cardRadius)
          .shadow({ radius: this.theme.cardShadowRadius, color: this.theme.cardShadowColor })

          Text('感谢使用 AMCL · 点击邮箱 / 群号可复制')
            .fontSize(11).fontColor(this.theme.textHint)
            .textAlign(TextAlign.Center).width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: Math.max(24, this.bottomSafeHeight + 16) })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
  }

  /**
   * 信息行：左标题 + 副值 + 右图标。isLink=true 时副值用主色（表示可跳转）。
   */
  @Builder
  InfoRow(title: string, value: string, rightIcon: AppIconName, isLink: boolean, onTap: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(16).fontWeight(400).fontColor(this.theme.textPrimary)
        Text(value)
          .fontSize(12).fontColor(isLink ? this.theme.primary : this.theme.textHint)
          .margin({ top: 2 })
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ right: 12 })
      AppIcon({ name: rightIcon, iconSize: 16, color: this.theme.textHint })
    }
    .width('100%').height(60).alignItems(VerticalAlign.Center)
    .onClick(() => { onTap() })
  }
}
