/**
 * FeedbackPage.ets — 问题反馈页（内嵌 AMCL-web 反馈页）
 *
 * 用通用 WebHostView 内嵌 `${AMCL_WEB_BASE}/feedback`（网页自带图片上传、蜜罐、防机器人）。
 * 本页只负责：① 按系统深浅色解析软件侧主题；② 开启 enableFileUpload，让网页 <input type=file>
 * 拉起系统相册图片选择器（WebHostView 内部处理，免权限）。
 *
 * 入口：SettingsTab「问题反馈」行 → router.pushUrl('pages/FeedbackPage')。
 * 创建日期：2026-06-07
 */

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { ThemeColors, ThemeMode, resolveTheme, resolveIsDark } from 'commons';
import { PreferenceManager } from 'feature_system';
import { FEEDBACK_PAGE_URL, AMCL_WEB_BASE } from 'commons';
import { WebHostView } from '../components/WebHostView';

@Entry
@Component
struct FeedbackPage {
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

  build() {
    Column() {
      WebHostView({
        theme: this.theme,
        topSafeHeight: this.topSafeHeight,
        src: FEEDBACK_PAGE_URL,
        title: '问题反馈',
        fallbackBrowserUrl: AMCL_WEB_BASE + '/feedback',
        enableFileUpload: true,   // 反馈页要上传图片 → 接管文件选择拉起相册
        onBack: () => { this.getUIContext().getRouter().back() },
      })
    }
    .width('100%').height('100%')
  }
}
