/**
 * WebHostView.ets — 内嵌网页的通用宿主（赞助页 / 反馈页共用）
 *
 * 抽出原 SponsorPage 的 WebView 外壳（导航栏 + 加载中 + 失败兜底 + 浏览器兜底），
 * 让赞助页、反馈页等"内嵌 AMCL-web 某页"的场景复用同一份 chrome。差异通过 prop 配置：
 *   - src               要加载的网页地址
 *   - title             顶部标题
 *   - fallbackBrowserUrl 失败/右上角"浏览器打开"用的地址（一般是去掉 ?embed=1 的版本）
 *   - enableFileUpload  是否接管网页 <input type=file>（反馈页传图需要 → 拉起系统图片选择器）
 *   - onDownloadUrl     网页触发下载时回调（赞助页收款码保存到相册用）
 *
 * 深浅色：由宿主 @Entry 页解析好 theme 传进来（本组件只渲染，不自己判系统深浅色）。
 * 全屏：不加 bottom safe padding，网页一直铺到屏幕底部。
 */

import { webview } from '@kit.ArkWeb';
import { common, Want } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ThemeColors } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';

const TAG = 'WebHostView'

@Component
export struct WebHostView {
  @Prop theme: ThemeColors
  @Prop topSafeHeight: number = 0

  /** 要加载的网页地址（含 ?embed=1 等参数）。 */
  src: string = ''
  /** 顶部标题。 */
  title: string = ''
  /** 失败兜底 / 右上角按钮用的浏览器地址（一般为去掉 embed 的可读版本）。 */
  fallbackBrowserUrl: string = ''
  /** 是否接管网页文件选择（反馈页上传图片需要）。 */
  enableFileUpload: boolean = false
  /** 网页触发下载时回调（拿到 url，由宿主决定如何保存）。 */
  onDownloadUrl: (url: string) => void = () => {}
  /** 返回（宿主一般走 router.back）。 */
  onBack: () => void = () => {}

  @State private loadFailed: boolean = false
  @State private loading: boolean = true

  private context: common.UIAbilityContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext')!
  private webController: webview.WebviewController = new webview.WebviewController()

  private openInBrowser() {
    let url = this.fallbackBrowserUrl.length > 0 ? this.fallbackBrowserUrl : this.src
    let want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url,
    }
    try {
      this.context.startAbility(want)
    } catch (e) {
      hilog.error(0x0000, TAG, 'open browser failed: %{public}s', (e as BusinessError).message)
      try { this.getUIContext().getPromptAction().showToast({ message: '无法打开浏览器', duration: 2000 }) } catch (_) { /* */ }
    }
  }

  private retry() {
    this.loadFailed = false
    this.loading = true
    try { this.webController.refresh() } catch (e) { /* controller 未 attach */ }
  }

  /**
   * 接管网页 <input type=file>：拉起系统相册图片选择器（免权限），把选中的 uri 回填给 WebView。
   * 反馈页最多 3 张图，这里放宽到 9，由网页侧再校验数量。
   */
  private handleFileSelect_(result: FileSelectorResult) {
    try {
      let picker = new photoAccessHelper.PhotoViewPicker()
      let opts: photoAccessHelper.PhotoSelectOptions = {
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 9,
      }
      picker.select(opts).then((res: photoAccessHelper.PhotoSelectResult) => {
        let uris = res.photoUris && res.photoUris.length > 0 ? res.photoUris : []
        result.handleFileList(uris)
      }).catch((e: BusinessError) => {
        hilog.warn(0x0000, TAG, 'photo pick failed: %{public}s', e.message)
        result.handleFileList([])
      })
    } catch (e) {
      hilog.warn(0x0000, TAG, 'photo picker init failed: %{public}s', (e as BusinessError).message)
      result.handleFileList([])
    }
  }

  build() {
    Column() {
      // ===== 顶部导航栏 =====
      // 用 Stack 让标题相对整条 bar 真正居中（左右按钮宽度不等，
      // 原先 layoutWeight 居中会把标题挤偏）。标题用 padding 让出两侧按钮区域避免重叠。
      Stack() {
        Text(this.title)
          .fontSize(20).fontWeight(700).fontColor(this.theme.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%').textAlign(TextAlign.Center)
          .padding({ left: 76, right: 76 })

        Row() {
          Row({ space: 4 }) {
            AppIcon({ name: AppIconName.Back, iconSize: 18, color: this.theme.primary })
            Text('返回')
              .fontSize(16).fontWeight(400).fontColor(this.theme.primary)
          }
          .onClick(() => { this.onBack() })
          .padding({ left: 12, top: 8, bottom: 8, right: 8 })

          Blank()

          Row({ space: 4 }) {
            AppIcon({ name: AppIconName.ArrowUpRight, iconSize: 16, color: this.theme.textSecondary })
          }
          .onClick(() => { this.openInBrowser() })
          .padding({ left: 8, top: 8, bottom: 8, right: 12 })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ top: this.topSafeHeight })
      .backgroundColor(this.theme.bgPrimary)

      // ===== 内容区：WebView / 加载中 / 错误兜底 =====
      Stack() {
        if (!this.loadFailed) {
          Web({ src: this.src, controller: this.webController })
            .width('100%')
            .height('100%')
            .darkMode(WebDarkMode.Auto)
            .mixedMode(MixedMode.All)
            .cacheMode(CacheMode.Default)
            .domStorageAccess(true)
            .onDownloadStart((event) => { this.onDownloadUrl(event.url) })
            .onShowFileSelector((event) => {
              if (!this.enableFileUpload) return false   // 不接管 → 用默认行为
              this.handleFileSelect_(event.result)
              return true
            })
            .onPageEnd(() => { this.loading = false })
            .onErrorReceive((event) => {
              if (event && event.request && event.request.isMainFrame()) {
                this.loadFailed = true
                this.loading = false
                hilog.warn(0x0000, TAG, 'main frame load error')
              }
            })
        }

        if (this.loading && !this.loadFailed) {
          Column({ space: 12 }) {
            LoadingProgress().width(40).height(40).color(this.theme.primary)
            Text('加载中…').fontSize(13).fontColor(this.theme.textSecondary)
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(this.theme.bgPrimary)
        }

        if (this.loadFailed) {
          Column({ space: 16 }) {
            AppIcon({ name: AppIconName.Error, iconSize: 40, color: this.theme.textHint })
            Text('页面加载失败')
              .fontSize(15).fontWeight(600).fontColor(this.theme.textPrimary)
            Text('请检查网络后重试，或用系统浏览器打开。')
              .fontSize(12).fontColor(this.theme.textSecondary).textAlign(TextAlign.Center)
            Row({ space: 12 }) {
              Text('重试')
                .fontSize(14).fontWeight(600).fontColor(this.theme.textOnPrimary)
                .padding({ left: 24, right: 24, top: 10, bottom: 10 })
                .backgroundColor(this.theme.primary).borderRadius(20)
                .onClick(() => { this.retry() })
              Text('用浏览器打开')
                .fontSize(14).fontWeight(600).fontColor(this.theme.textSecondary)
                .padding({ left: 20, right: 20, top: 10, bottom: 10 })
                .backgroundColor(this.theme.bgCard).borderRadius(20)
                .onClick(() => { this.openInBrowser() })
            }
            .margin({ top: 4 })
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .padding({ left: 32, right: 32 })
          .backgroundColor(this.theme.bgPrimary)
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgPrimary)
    // 不加 bottom safe padding：网页内容一直铺到屏幕最底（全屏）。
  }
}
