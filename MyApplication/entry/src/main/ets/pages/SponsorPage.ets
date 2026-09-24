/**
 * SponsorPage.ets — 赞助作者页（内嵌 AMCL-web 赞助页）
 *
 * 用通用 WebHostView 内嵌 `${AMCL_WEB_BASE}/sponsor?embed=1`（embed=1 隐藏站点导航/页脚，
 * 只显示「赞助星云 + 赞助登记」两屏）。本页只负责：① 按系统深浅色解析软件侧主题；
 * ② 接住收款码「下载」→ 用 AlbumSaver 免权限保存到相册。
 *
 * 入口：SettingsTab「支持作者」行 → router.pushUrl('pages/SponsorPage')。
 * 创建日期：2026-06-07
 */

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { PreferenceManager } from 'feature_system';
import { SPONSOR_PAGE_URL, AMCL_WEB_BASE } from 'commons';
import { WebHostView } from '../components/WebHostView';
import { AlbumSaver } from 'feature_system';

const TAG = 'SponsorPage'

@Entry
@Component
struct SponsorPage {
  @State theme: ThemeColors = resolveTheme(ThemeMode.SYSTEM, false)
  @StorageProp('topRectHeight') topSafeHeight: number = 0
  @StorageProp('currentColorMode') @Watch('onColorModeChange') currentColorMode: number = 0

  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  private prefManager: PreferenceManager = new PreferenceManager(this.context)

  aboutToAppear() {
    this.applyTheme_()
  }

  private applyTheme_() {
    let systemIsDark = (this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK)
    let mode = this.prefManager.themeMode
    this.theme = resolveTheme(mode, resolveIsDark(mode, systemIsDark))
  }

  onColorModeChange() {
    this.applyTheme_()
  }

  private toast_(msg: string) {
    try { this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 }) } catch (e) { /* */ }
  }

  /** 收款码放大图「下载」→ 下载并经系统弹窗免权限存进相册。 */
  private handleImageDownload_(url: string) {
    if (!url || url.length === 0) return
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      this.toast_('该图片需在浏览器中保存')
      return
    }
    this.toast_('正在保存收款码…')
    AlbumSaver.saveImageUrl(this.context, url).then((r) => {
      this.toast_(r === 'saved' ? '已保存到相册' : '已取消')
    }).catch((e: Error) => {
      hilog.warn(0x0000, TAG, 'save image failed: %{public}s', e.message)
      this.toast_('保存失败：' + e.message)
    })
  }

  build() {
    Column() {
      WebHostView({
        theme: this.theme,
        topSafeHeight: this.topSafeHeight,
        src: SPONSOR_PAGE_URL,
        title: '支持作者',
        fallbackBrowserUrl: AMCL_WEB_BASE + '/sponsor',
        onDownloadUrl: (url: string) => { this.handleImageDownload_(url) },
        onBack: () => { this.getUIContext().getRouter().back() },
      })
    }
    .width('100%').height('100%')
  }
}
