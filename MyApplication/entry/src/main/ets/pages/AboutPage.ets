import { util } from '@kit.ArkTS';
import { DistributionPolicy } from 'commons';
import { ImmersiveTitleScaffold } from '../components/ImmersiveTitleScaffold';
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
import { SideloadUpdateService } from '../sideload/SideloadUpdateService';
import { UpdatePromptPresenter } from '../components/UpdatePromptPresenter';
import { UpdateDialog } from '../components/UpdateDialog';
import { PreferenceManager } from 'feature_system';
import { GameRunAdmission } from '../runtime/GameRunAdmission';
import { UpdateChecker, UpdateCheckResult, UpdateManifest } from 'update';
import { ProductBuildProfile } from 'entry/ProductBuildProfile';

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
  @State private hasPendingUpdate: boolean = false
  @State private allowDebug: boolean = false
  @State private savingDebug: boolean = false
  @State private debugMessage: string = ''

  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  private prefManager: PreferenceManager = new PreferenceManager(this.context)
  /** 更新弹窗控制器：每次弹前重建（内容随 manifest 固化），持有引用只为让实例活到关闭。 */
  private pageVisible: boolean = true
  private checkGeneration: number = 0
  private pendingUpdate: UpdateManifest | undefined = undefined
  private exitPresentedUpdate: () => boolean = (): boolean => true
  private updatePresenterOwner: string = 'about-' + util.generateRandomUUID()
  private updateDialogCtrl_: CustomDialogController | null = null

  aboutToAppear() {
    this.applyTheme_()
    this.allowDebug = GameRunAdmission.isAllowed()
    // 上架轨（应用市场分发）：更新由应用市场负责，App 内暂不做 GitHub 检查更新。
    // 未来方向：接入应用市场的版本更新接口 / 跳转应用市场详情页检查更新。
    if (DistributionPolicy.isStore()) return
    // 这里只读启动检查留下的持久化结果，避免每次进入「关于」页又绕过 24h 节流联网。
    // 用户点击下方「检查更新」始终执行一次手动检查，不受自动节流影响。
    this.hasUpdate = UpdateChecker.hasCachedUpdate(
      UpdateChecker.currentVersionCode(), this.prefManager.appUpdateLatestSeen(ProductBuildProfile.product,this.prefManager.appUpdateChannel),UpdateChecker.currentVersionName(),
      this.prefManager.appUpdateLatestName(ProductBuildProfile.product,this.prefManager.appUpdateChannel),this.prefManager.appUpdateChannel)
  }

  /** 保存确认后才发布开关值；撤销同样交给统一准入所有者，不把旧快照当实时授权。 */
  private async saveDebugChoice_(enabled: boolean): Promise<void> {
    if (this.savingDebug) return
    this.savingDebug = true
    this.debugMessage = '正在保存…'
    try {
      await GameRunAdmission.saveChoice(this.context, enabled)
      this.allowDebug = GameRunAdmission.isAllowed()
      this.debugMessage = this.allowDebug ? '已允许运行调试。' : '已关闭新运行；已有游戏仍可返回并退出。'
    } catch (error) {
      this.allowDebug = GameRunAdmission.isAllowed()
      this.debugMessage = '保存未完成：' + (error as Error).message
    } finally { this.savingDebug = false }
  }

  /** 商店条款与许可使用随包文本；路由键保持字符串，兼容release属性混淆。 */
  private openLocalPolicy_(policy: string): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/LocalPolicyPage', params: { 'policy': policy } })
        .catch((): void => { this.safeToast_('无法打开本地说明，请重试') })
    } catch (_) { this.safeToast_('无法打开本地说明，请重试') }
  }

  /** 把手动检查结果落到红点、节流时间与 latestSeen。 */
  private applyUpdateResult_(res: UpdateCheckResult): void {
    if (!res.ok || res.manifest === null) return
    const channel=this.prefManager.appUpdateChannel
    if((res.manifest.updateChannel ?? 'stable')!==channel) return
    this.prefManager.rememberAppUpdate(ProductBuildProfile.product,channel,res.manifest.versionCode,
      UpdateChecker.targetKey(res.manifest,ProductBuildProfile.product))
    this.hasUpdate=res.hasUpdate
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
    if (DistributionPolicy.isStore()) return
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

  /** 检查更新：按所选通道核对安装编号及发行名，并展示更新或返回正式版候选。 */
  private async doCheckUpdate_(): Promise<void> {
    if (DistributionPolicy.isStore()) return
    if (this.checkingUpdate) return
    this.checkingUpdate = true
    const generation = ++this.checkGeneration
    const channel=this.prefManager.appUpdateChannel
    try {
      let res: UpdateCheckResult = await UpdateChecker.checkForUpdate(undefined, ProductBuildProfile.product,channel)
      if (!this.pageVisible || generation !== this.checkGeneration || channel!==this.prefManager.appUpdateChannel) return
      if (!res.ok) {
        this.safeToast_('检查更新失败：' + (res.error.length > 0 ? res.error : '未知错误'))
        return
      }
      this.applyUpdateResult_(res)   // 同步红点 + 持久化 latestSeen
      if (!res.hasUpdate || res.manifest === null) {
        this.safeToast_(res.error || '已是最新版本 v' + APP_VERSION)
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
    if((m.updateChannel ?? 'stable')!==this.prefManager.appUpdateChannel) return
    if (!this.pageVisible || this.updateDialogCtrl_ !== null || !UpdatePromptPresenter.claim(this.updatePresenterOwner)) {
      this.pendingUpdate = m; UpdatePromptPresenter.defer(this.updatePresenterOwner, (): void => {
        if (this.pageVisible && this.pendingUpdate !== undefined) { const pending = this.pendingUpdate; this.pendingUpdate = undefined; this.showUpdateDialog_(pending); }
      }); return;
    }
    try {
      let allowDismiss: () => boolean = (): boolean => true
      // 延后由成功检查时的目标身份变化自动清理。
      let ctrl: CustomDialogController = new CustomDialogController({
        builder: UpdateDialog({
          theme: this.theme,
          newVersion: m.versionName.length > 0 ? m.versionName : m.tag,
          currentVersion: UpdateChecker.currentVersionName() || APP_VERSION,
          title: UpdateChecker.isStableReturn(m) ? '返回正式版' : '',
          releaseDate: m.date,
          sizeLabel: m.sizeBytes > 0 ? formatBytes(m.sizeBytes) : '',
          mandatory: m.mandatory,
          entries: UpdateChecker.displayEntries(m),
          showChangelogEntry: true,
          actionLabel: UpdateChecker.isStableReturn(m) ? '返回此正式版' : '立即更新',
          selfUpdateParams: { manifest: m, autoStart: true },
          onDismissGuardReady: (guard: () => boolean): void => { allowDismiss = guard; },
          onExitGuardReady: (exit: () => boolean): void => { this.exitPresentedUpdate = exit; },
          showManualDownload: true,
          onManualDownload: (): void => {
            this.closeUpdateDialog_()
            this.openUrl_(m.url.length > 0 ? m.url : APP_REPO_URL)
          },
          onDownload: () => {
            this.closeUpdateDialog_()
            this.openUrl_(m.url.length > 0 ? m.url : APP_REPO_URL)
          },
          onLater: () => {
            this.prefManager.deferAppUpdate(ProductBuildProfile.product,m.updateChannel ?? 'stable',UpdateChecker.targetKey(m,ProductBuildProfile.product))
            // hasUpdate/latestSeenVersionCode 保留，红点不会因延后消失。
            this.closeUpdateDialog_()
          },
          onViewChangelog: () => {
            this.closeUpdateDialog_()
            this.openChangelog_()
          },
        }),
        autoCancel: !m.mandatory,
        onWillDismiss: (action: DismissDialogAction): void => { if (allowDismiss()) action.dismiss(); },
        cancel: (): void => { this.prefManager.deferAppUpdate(ProductBuildProfile.product,m.updateChannel ?? 'stable',UpdateChecker.targetKey(m,ProductBuildProfile.product)); this.updateDialogCtrl_ = null; UpdatePromptPresenter.release(this.updatePresenterOwner) },
        customStyle: true,
        alignment: DialogAlignment.Center,
      })
      this.updateDialogCtrl_ = ctrl
      ctrl.open()
    } catch (e) {
      this.updateDialogCtrl_ = null; UpdatePromptPresenter.release(this.updatePresenterOwner)
      // 弹框不可用时退化为直接打开下载页，不能让用户点了没反应
      hilog.warn(0x0000, TAG, 'UpdateDialog open failed: %{public}s', (e as Error).message)
      this.openUrl_(m.url.length > 0 ? m.url : APP_REPO_URL)
    }
  }

  /** UpdateDialog 不拥有 controller；关闭统一由创建它的父页面执行。 */
  /** 路由离开与系统后台/helper往返区分，只有本实例仍持席位才退出自己的更新。 */
  private exitUpdateForRoute_(): void {
    if (this.updateDialogCtrl_ === null || !UpdatePromptPresenter.owns(this.updatePresenterOwner)) return
    try {
      const current = this.getUIContext().getRouter().getState()
      if (current.name !== 'AboutPage' && current.name !== 'pages/AboutPage') { this.exitPresentedUpdate(); this.closeUpdateDialog_(); }
    } catch (_) { /* 路由尚未更新时不把后台误判退出；真正销毁仍执行显式出口。 */ }
  }

  private closeUpdateDialog_(): void {
    let ctrl: CustomDialogController | null = this.updateDialogCtrl_
    this.updateDialogCtrl_ = null
    if (ctrl !== null) ctrl.close()
    UpdatePromptPresenter.release(this.updatePresenterOwner)
  }

  /** 打开更新日志页。 */
  private openChangelog_(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/ChangelogPage' })
    } catch (e) {
      hilog.warn(0x0000, TAG, 'push ChangelogPage failed: %{public}s', (e as Error).message)
    }
  }

  /** 后台/设置往返仅发布显示事实，不销毁连续更新。真正离页取消迟到检查请求。 */
  onPageShow(): void { this.allowDebug = GameRunAdmission.isAllowed(); this.hasPendingUpdate = !DistributionPolicy.isStore() && SideloadUpdateService.get(this.context).needsAttention(); this.pageVisible = true; if (this.pendingUpdate !== undefined) { const pending = this.pendingUpdate; this.pendingUpdate = undefined; this.showUpdateDialog_(pending) } }
  onPageHide(): void { this.pageVisible = false; this.exitUpdateForRoute_(); setTimeout((): void => { this.exitUpdateForRoute_(); }, 0) }
  aboutToDisappear(): void {
    this.checkGeneration++; this.pageVisible = false; if (UpdatePromptPresenter.owns(this.updatePresenterOwner)) this.exitPresentedUpdate(); this.closeUpdateDialog_(); UpdatePromptPresenter.forget(this.updatePresenterOwner)
  }

  build() {
    Column() {
    // 返回按钮迁入真正的 HDS 标题栏；正文、更新弹窗所有权及 router 返回仍由本页负责。
    ImmersiveTitleScaffold({ title: '关于', theme: this.theme, topSafeHeight: this.topSafeHeight,
      surfaceColor: this.theme.bgPrimary, onBack: (): void => { this.getUIContext().getRouter().back(); },
      content: (): void => { this.ImmersiveTitleContent1_(); }
    })
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

  /** 保留原正文的父组件状态与业务回调；具名content只转调此真正@Builder，避免this漂移。 */
  @Builder
  private ImmersiveTitleContent1_() {
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
            if (!DistributionPolicy.isStore()) {
            // GitHub
            this.InfoRow('GitHub', APP_REPO_URL, AppIconName.ChevronRight, true,
              () => { this.openUrl_(APP_REPO_URL) })

            Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
            }

            // 作者联系方式（邮箱，点击复制）
            this.InfoRow('作者联系方式', AUTHOR_EMAIL, AppIconName.Copy, false,
              () => { this.copyToClipboard_(AUTHOR_EMAIL, '邮箱') })

            Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

            // QQ 交流群（点击复制群号）
            this.InfoRow('QQ 交流群', QQ_GROUP_ID, AppIconName.Copy, false,
              () => { this.copyToClipboard_(QQ_GROUP_ID, '群号') })

            if (DistributionPolicy.isStore()) {
              Row().width('100%').height(0.5).backgroundColor(this.theme.divider)
              Row({ space: 12 }) {
                Column({ space: 6 }) {
                  Text('允许调试').fontSize(16).fontColor(this.theme.textPrimary)
                  Text('开启后显示运行游戏及运行设定；版本下载、文件管理与导出始终可用。')
                    .fontSize(12).fontColor(this.theme.textHint)
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                if (this.savingDebug) {
                  LoadingProgress().width(24).height(24).color(this.theme.primary)
                } else {
                  Toggle({ type: ToggleType.Switch, isOn: this.allowDebug })
                    .onChange((enabled: boolean): void => { this.saveDebugChoice_(enabled) })
                }
              }.width('100%').padding({ top: 16, bottom: 16 })
              if (this.debugMessage.length > 0) {
                Text(this.debugMessage).fontSize(12).fontColor(this.theme.textSecondary).width('100%').padding({ bottom: 12 })
              }
            }

            Row().width('100%').height(0.5).backgroundColor(this.theme.divider)

            // 更新日志（上架轨也保留：数据走随包快照，不联网）
            this.InfoRow('更新日志', '查看每个版本的变更', AppIconName.ChevronRight, false,
              () => { this.openChangelog_() })
            if (DistributionPolicy.isStore()) {
              this.InfoRow('隐私政策', '随包本地阅读', AppIconName.ChevronRight, false,
                () => { this.openLocalPolicy_('privacy') })
              this.InfoRow('许可与致谢', '第三方组件与开源许可', AppIconName.ChevronRight, false,
                () => { this.openLocalPolicy_('license') })
            }

            if (!DistributionPolicy.isStore()) {
              this.InfoRow('软件更新', '稳定／测试通道 · 手动安装包', AppIconName.ChevronRight, false,
                () => { this.getUIContext().getRouter().pushUrl({ url: 'pages/SoftwareUpdatePage' }) })
            }
            // 检查更新（上架轨隐藏：更新交由应用市场；未来方向——跳转应用市场详情页 / 接入市场更新接口）
            if (this.hasPendingUpdate && !DistributionPolicy.isStore()) {
              this.InfoRow('上次更新', '查看进度或恢复更新', AppIconName.ChevronRight, false,
                () => { this.getUIContext().getRouter().pushUrl({ url: 'pages/SideloadUpdatePage', params: { autoStart: false } }) })
            }
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
}
