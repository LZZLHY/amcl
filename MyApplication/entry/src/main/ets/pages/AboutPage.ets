import { applyNativeTheme } from '../components/AppTheme';
import { util } from '@kit.ArkTS';
import { DistributionPolicy } from 'commons';
import { ImmersiveTitleScaffold } from '../components/ImmersiveTitleScaffold';
import {
  SettingsDivider,
  SettingsGroup,
  SettingsHint,
  SettingsToggleRow,
  SettingsValueRow
} from '../components/SettingsPrimitives';
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
import { AppIconName } from 'commons';
import { formatBytes } from 'commons';
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
  /** 同进程主题确认后重建本页快照；不触发业务重载、偏好写入或新的窗口订阅。 */
  @StorageProp('appThemeRevision') @Watch('onColorModeChange') private appThemeRevision: number = 0;
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
    this.theme = resolveTheme(mode, resolveIsDark(mode, systemIsDark), this.prefManager.themeAccent)
    applyNativeTheme(this.theme);
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
    // 开发者版只在专用页明确选择退出，不借普通“检查更新”恢复自动推荐。
    if (!UpdateChecker.automaticAllowed()) {
      this.getUIContext().getRouter().pushUrl({url:'pages/SoftwareUpdatePage'}).catch((): void => {})
      return
    }
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
  onPageShow(): void { this.applyTheme_();  this.allowDebug = GameRunAdmission.isAllowed(); this.hasPendingUpdate = !DistributionPolicy.isStore() && SideloadUpdateService.get(this.context).needsAttention(); this.pageVisible = true; if (this.pendingUpdate !== undefined) { const pending = this.pendingUpdate; this.pendingUpdate = undefined; this.showUpdateDialog_(pending) } }
  onPageHide(): void { this.pageVisible = false; this.exitUpdateForRoute_(); setTimeout((): void => { this.exitUpdateForRoute_(); }, 0) }
  aboutToDisappear(): void {
    this.checkGeneration++; this.pageVisible = false; if (UpdatePromptPresenter.owns(this.updatePresenterOwner)) this.exitPresentedUpdate(); this.closeUpdateDialog_(); UpdatePromptPresenter.forget(this.updatePresenterOwner)
  }

  /**
   * 标题仍由既有 HDS 宿主管理，系统返回和更新弹窗席位不会因视觉重排另起所有者。
   * 通过箭头转调正文 Builder，保证正文中的状态始终读取当前 AboutPage 实例。
   */
  build() {
    Column() {
      ImmersiveTitleScaffold({
        title: '关于 AMCL', emphasizedTitle: true, theme: this.theme, topSafeHeight: this.topSafeHeight,
        surfaceColor: this.theme.bgPrimary,
        onBack: (): void => { this.getUIContext().getRouter().back(); },
        content: (): void => { this.ImmersiveTitleContent1_(); }
      })
    }.width('100%').height('100%').backgroundColor(this.theme.bgPrimary)
  }

  /** 读取已装包的名称。包信息查询失败时，使用与构建配置同步的版本名。 */
  private readonly installedVersionName: string = UpdateChecker.currentVersionName() || APP_VERSION;

  /** 只在默认开发包读取安装码，独立于预览版名称。 */
  private readonly installedVersionCode: number = ProductBuildProfile.product === 'default'
    ? UpdateChecker.currentVersionCode() : 0;

  /** 应用名和实际包内版本名共用一行，预览后缀随包内名称呈现。 */
  @Builder
  private BrandHeader_() {
    Column({ space: 8 }) {
      Image($r('app.media.amcl_axe')).width(80).height(80).objectFit(ImageFit.Contain)
        .backgroundColor(this.theme.bgCard).borderRadius(20).clip(true).draggable(false)
      Row({ space: 12 }) {
        Text('AMCL').fontSize(28).fontWeight(600).fontColor(this.theme.textPrimary)
        Text(this.installedVersionName).fontSize(16).fontColor(this.theme.textSecondary)
      }.alignItems(VerticalAlign.Center).justifyContent(FlexAlign.Center)
    }.width('100%').padding({ top: 20, bottom: 8 }).alignItems(HorizontalAlign.Center)
  }

  /**
   * 版本分组集中现有更新入口。检查状态直接以文字表达，同时继续禁用重复检查；
   * 商店产品仅保留本地更新日志，不能因分组抽取恢复 GitHub、自更新或安装包入口。
   */
  @Builder
  private VersionGroupContent_() {
    // 开发包可核对真实安装码。发行产品只在顶部显示其实际版本名。
    if (ProductBuildProfile.product === 'default' && this.installedVersionCode > 0) {
      SettingsValueRow({ title: 'versionCode', value: String(this.installedVersionCode),
        theme: this.theme, interactive: false, showTrailing: false, controlId: 'about-version-code' })
      SettingsDivider({ theme: this.theme })
    }
    if (!DistributionPolicy.isStore()) {
      SettingsValueRow({
        title: '检查更新', value: this.checkingUpdate ? '检查中…' : this.hasUpdate ? '有新版本' : '检查',
        theme: this.theme, actionValue: true, showTrailing: false, actionEnabled: !this.checkingUpdate,
        controlId: 'about-check-update', onAction: (): void => { this.doCheckUpdate_(); }
      })
      SettingsDivider({ theme: this.theme })
      SettingsValueRow({
        title: '软件更新', value: '稳定 / 测试通道', theme: this.theme,
        controlId: 'about-software-update',
        onAction: (): void => { this.getUIContext().getRouter().pushUrl({ url: 'pages/SoftwareUpdatePage' }); }
      })
      SettingsDivider({ theme: this.theme })
    }
    SettingsValueRow({
      title: '更新日志', value: '查看版本变化', theme: this.theme,
      controlId: 'about-changelog', onAction: (): void => { this.openChangelog_(); }
    })
    if (this.hasPendingUpdate && !DistributionPolicy.isStore()) {
      SettingsDivider({ theme: this.theme })
      SettingsValueRow({
        title: '上次更新', value: '查看进度或恢复', theme: this.theme,
        controlId: 'about-resume-update',
        onAction: (): void => {
          this.getUIContext().getRouter().pushUrl({ url: 'pages/SideloadUpdatePage', params: { autoStart: false } });
        }
      })
    }
  }

  /** 联系信息沿用原常量与复制方法，复制图标区分即时动作和进入下一页的导航箭头。 */
  @Builder
  private ContactGroupContent_() {
    if (!DistributionPolicy.isStore()) {
      SettingsValueRow({
        title: 'GitHub', value: '查看源代码', theme: this.theme,
        controlId: 'about-github', onAction: (): void => { this.openUrl_(APP_REPO_URL); }
      })
      SettingsDivider({ theme: this.theme })
    }
    SettingsValueRow({
      title: '作者联系方式', description: AUTHOR_EMAIL, value: '复制', theme: this.theme,
      trailingIcon: AppIconName.Copy, actionValue: true, controlId: 'about-copy-email',
      onAction: (): void => { this.copyToClipboard_(AUTHOR_EMAIL, '邮箱'); }
    })
    SettingsDivider({ theme: this.theme })
    SettingsValueRow({
      title: 'QQ 交流群', value: QQ_GROUP_ID, theme: this.theme,
      trailingIcon: AppIconName.Copy, actionValue: true, controlId: 'about-copy-group',
      onAction: (): void => { this.copyToClipboard_(QQ_GROUP_ID, '群号'); }
    })
  }

  /**
   * 商店调试开关只消费 GameRunAdmission 发布的确认态；保存期以进度指示替代重复操作，
   * 失败与关闭运行的说明继续来自原事务方法，不在展示层推定准入已经变化。
   */
  @Builder
  private StoreDebugGroupContent_() {
    SettingsToggleRow({
      title: '允许调试', description: '开启后显示运行游戏及运行设定；版本下载、文件管理与导出始终可用。',
      value: this.allowDebug, saving: this.savingDebug, theme: this.theme,
      controlId: 'about-allow-debug', onChange: (enabled: boolean): void => { this.saveDebugChoice_(enabled); }
    })
    if (this.debugMessage.length > 0) {
      Column() {
        SettingsHint({
          text: this.debugMessage, theme: this.theme, isError: this.debugMessage.startsWith('保存未完成')
        })
      }.width('100%').padding({ left: 16, right: 16, bottom: 16 })
    }
  }

  /** 商店政策与许可始终使用原本地路由，不把规范说明改成外部网页请求。 */
  @Builder
  private StorePolicyGroupContent_() {
    SettingsValueRow({
      title: '隐私政策', value: '随包本地阅读', theme: this.theme,
      controlId: 'about-local-privacy', onAction: (): void => { this.openLocalPolicy_('privacy'); }
    })
    SettingsDivider({ theme: this.theme })
    SettingsValueRow({
      title: '许可与致谢', description: '第三方组件与开源许可', theme: this.theme,
      controlId: 'about-local-license', onAction: (): void => { this.openLocalPolicy_('license'); }
    })
  }

  /** 免责声明完整引用共享事实源，允许大字体自然换行，不截短或另写合规文案。 */
  @Builder
  private DisclaimerContent_() {
    Column({ space: 12 }) {
      Text('免责声明').fontSize(16).fontColor(this.theme.textPrimary).width('100%')
      SettingsHint({ text: BRAND_DISCLAIMER, theme: this.theme })
    }.width('100%').padding(20).alignItems(HorizontalAlign.Start)
  }

  /**
   * 正文使用原滚动宿主，手机保持 16vp 页边距，大屏居中限宽以免设置行与长说明过度拉伸。
   * 分组间距统一为 24vp；所有动态行使用独立 Prop，组正文通过箭头回到本页 Builder，
   * 因而主题、检查状态和调试确认值都不会被一次性的 Builder 参数快照冻结。
   */
  @Builder
  private ImmersiveTitleContent1_() {
    Scroll() {
      Row() {
        Column({ space: 24 }) {
          this.BrandHeader_()
          SettingsGroup({ title: '版本', theme: this.theme, content: (): void => { this.VersionGroupContent_(); } })
          SettingsGroup({
            title: DistributionPolicy.isStore() ? '联系' : '联系与开源', theme: this.theme,
            content: (): void => { this.ContactGroupContent_(); }
          })
          if (DistributionPolicy.isStore()) {
            SettingsGroup({ title: '调试', theme: this.theme, content: (): void => { this.StoreDebugGroupContent_(); } })
            SettingsGroup({ title: '政策与许可', theme: this.theme, content: (): void => { this.StorePolicyGroupContent_(); } })
          }
          SettingsGroup({ title: '说明', theme: this.theme, content: (): void => { this.DisclaimerContent_(); } })
          Text('感谢使用 AMCL').fontSize(14).fontColor(this.theme.textSecondary)
            .textAlign(TextAlign.Center).width('100%')
        }.width('100%').constraintSize({ maxWidth: 760 }).alignItems(HorizontalAlign.Start)
          .padding({ left: 16, right: 16, top: 8, bottom: Math.max(24, this.bottomSafeHeight + 16) })
      }.width('100%').justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Top)
    }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
  }
}
