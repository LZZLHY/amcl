/**
 * NetworkDiagnosticsSheet.ets — 网络环境检测 Sheet
 *
 * 由顶部「网络异常」横幅点击、或各下载错误处的「网络检测」按钮打开。
 * 跑一次完整分层诊断（feature_core/NetworkDiagnostics），把「设备无网 / 上不了公网 /
 * 证书未就绪 / 能上网但连不上下载服务器 / 部分源不可用」直观呈现给用户，并给出建议。
 *
 * 复用 Index 的 bindSheet 锚点渲染；主题由 @Prop theme 注入。
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { AppIcon } from './AppIcon';
import { ThemeColors, AppIconName } from 'commons';
import {
  runNetworkDiagnostics, NetworkReport, NetworkProbe,
  ProbeStatus, NetworkVerdict,
} from 'feature_core';

@Component
export struct NetworkDiagnosticsSheet {
  @Prop theme: ThemeColors
  @Prop bottomSafeHeight: number = 0
  /** 关闭 Sheet 回调（由父组件把 show flag 置 false）。 */
  onClose: () => void = () => {}

  @State private report: NetworkReport | null = null
  @State private running: boolean = false
  @State private errorText: string = ''

  aboutToAppear(): void {
    this.runDiag_()
  }

  private runDiag_(): void {
    if (this.running) return
    this.running = true
    this.report = null
    this.errorText = ''
    runNetworkDiagnostics().then((r: NetworkReport) => {
      this.report = r
      this.running = false
      // 按诊断结论同步全局横幅：仍异常→点亮，已恢复(OK/部分可用)→隐藏。
      let bad = r.verdict === NetworkVerdict.NO_SYSTEM_NET
        || r.verdict === NetworkVerdict.NO_INTERNET
        || r.verdict === NetworkVerdict.CA_NOT_READY
        || r.verdict === NetworkVerdict.DOWNLOAD_BLOCKED
      if (bad) {
        AppStorage.setOrCreate('amcl_net_banner_text', '网络连接异常，下载 / 搜索可能不可用，点此检测')
      }
      AppStorage.setOrCreate('amcl_net_banner_visible', bad)
    }).catch((e: Error) => {
      this.running = false
      this.errorText = '网络检测失败：' + (e.message || '未知错误')
    })
  }

  private verdictColor_(): ResourceColor {
    if (!this.report) return this.theme.textHint
    let v = this.report.verdict
    if (v === NetworkVerdict.OK) return this.theme.success
    if (v === NetworkVerdict.PARTIAL) return this.theme.warning
    return this.theme.error
  }

  private verdictBg_(): ResourceColor {
    if (!this.report) return this.theme.bgCard
    let v = this.report.verdict
    if (v === NetworkVerdict.OK) return this.theme.successBg
    if (v === NetworkVerdict.PARTIAL) return this.theme.warningBg
    return this.theme.errorBg
  }

  private copyReport_(): void {
    if (!this.report) return
    let lines: string[] = []
    lines.push('AMCL 网络检测报告')
    lines.push('结论：' + this.report.title)
    lines.push(this.report.summary)
    lines.push('---')
    for (let p of this.report.probes) {
      let mark = p.status === ProbeStatus.OK ? '[OK]' : (p.status === ProbeStatus.FAIL ? '[FAIL]' : '[SKIP]')
      lines.push(mark + ' ' + p.name + ' — ' + p.detail)
    }
    try {
      let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, lines.join('\n'))
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast_('检测报告已复制')
      }).catch((e: Error) => { this.errorText = '报告复制失败：' + (e.message || '系统剪贴板不可用') })
    } catch (e) { this.errorText = '报告复制失败：' + (e as Error).message }
  }

  private toast_(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1800 })
    } catch (e) { /* ignore */ }
  }

  build() {
    Column() {
      // 头部
      Row() {
        Text('网络环境检测')
          .fontSize(18).fontWeight(600).fontColor(this.theme.textPrimary)
          .layoutWeight(1)
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          AppIcon({ name: AppIconName.Close, iconSize: 18, color: this.theme.textSecondary })
        }
        .width(44).height(44).backgroundColor(this.theme.bgCard).accessibilityText('关闭网络检测')
        .onClick(() => { this.onClose() })
      }
      .width('100%').padding({ left: 20, right: 16, top: 14, bottom: 10 })

      Scroll() {
        Column({ space: 14 }) {
          // 结论卡片
          if (this.running) {
            Row({ space: 12 }) {
              LoadingProgress().width(24).height(24).color(this.theme.primary)
              Text('正在检测网络环境…')
                .fontSize(15).fontColor(this.theme.textSecondary)
            }
            .width('100%').padding(18)
            .backgroundColor(this.theme.bgCard).borderRadius(this.theme.cardRadius)
            .alignItems(VerticalAlign.Center)
          } else if (this.report) {
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                AppIcon({
                  name: this.report.verdict === NetworkVerdict.OK ? AppIconName.CheckCircle : AppIconName.Warning,
                  iconSize: 20, color: this.verdictColor_(),
                })
                Text(this.report.title)
                  .fontSize(16).fontWeight(600).fontColor(this.verdictColor_())
                  .layoutWeight(1)
              }
              .width('100%').alignItems(VerticalAlign.Center)
              Text(this.report.summary)
                .fontSize(13.5).fontColor(this.theme.textSecondary).lineHeight(20)
                .width('100%')
            }
            .width('100%').padding(16)
            .backgroundColor(this.verdictBg_()).borderRadius(this.theme.cardRadius)
            .alignItems(HorizontalAlign.Start)
          } else if (this.errorText.length > 0) {
            Column({ space: 8 }) {
              AppIcon({ name: AppIconName.Warning, iconSize: 22, color: this.theme.error })
              Text(this.errorText).fontSize(14).fontColor(this.theme.error).textAlign(TextAlign.Center)
              Button('重试检测').onClick(() => { this.runDiag_() })
            }.width('100%').padding(18).backgroundColor(this.theme.errorBg)
              .borderRadius(this.theme.cardRadius).alignItems(HorizontalAlign.Center)
          }

          // 建议
          if (this.report !== null && this.errorText.length > 0) {
            Text(this.errorText).fontSize(13).fontColor(this.theme.error).width('100%')
          }
          if (this.report && this.report.suggestions.length > 0) {
            Column({ space: 6 }) {
              Text('建议')
                .fontSize(13).fontWeight(600).fontColor(this.theme.textHint)
                .width('100%')
              ForEach(this.report.suggestions, (s: string) => {
                Row({ space: 8 }) {
                  Text('•').fontSize(14).fontColor(this.theme.primary)
                  Text(s).fontSize(13.5).fontColor(this.theme.textSecondary).layoutWeight(1)
                }
                .width('100%').alignItems(VerticalAlign.Top)
              })
            }
            .width('100%').padding(16)
            .backgroundColor(this.theme.bgCard).borderRadius(this.theme.cardRadius)
            .alignItems(HorizontalAlign.Start)
          }

          // 逐项检测明细
          if (this.report) {
            Column() {
              Text('检测明细')
                .fontSize(13).fontWeight(600).fontColor(this.theme.textHint)
                .width('100%').margin({ bottom: 4 })
              ForEach(this.report.probes, (p: NetworkProbe) => {
                Row({ space: 10 }) {
                  AppIcon({
                    name: p.status === ProbeStatus.OK ? AppIconName.CheckCircle
                      : (p.status === ProbeStatus.FAIL ? AppIconName.Error : AppIconName.Info),
                    iconSize: 18,
                    color: p.status === ProbeStatus.OK ? this.theme.success
                      : (p.status === ProbeStatus.FAIL ? this.theme.error : this.theme.textHint),
                  })
                  Column({ space: 2 }) {
                    Text(p.name)
                      .fontSize(14.5).fontColor(this.theme.textPrimary).width('100%')
                    Text(p.detail)
                      .fontSize(12).fontColor(this.theme.textHint).width('100%')
                  }
                  .layoutWeight(1).alignItems(HorizontalAlign.Start)
                }
                .width('100%').padding({ top: 10, bottom: 10 })
                .alignItems(VerticalAlign.Center)
                .border({ width: { bottom: 0.5 }, color: this.theme.divider })
              })
            }
            .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 4 })
            .backgroundColor(this.theme.bgCard).borderRadius(this.theme.cardRadius)
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%').padding({ left: 16, right: 16, bottom: 12 })
      }
      .layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Off)

      // 底部操作
      Row({ space: 12 }) {
        Button('复制报告')
          .fontSize(15).fontColor(this.theme.textSecondary)
          .backgroundColor(this.theme.bgCard).borderRadius(24)
          .height(46).layoutWeight(1)
          .enabled(this.report !== null)
          .onClick(() => { this.copyReport_() })
        Button(this.running ? '检测中…' : '重新检测')
          .fontSize(15).fontColor(Color.White)
          .backgroundColor(this.theme.primary).borderRadius(24)
          .height(46).layoutWeight(1)
          .enabled(!this.running)
          .onClick(() => { this.runDiag_() })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: Math.max(16, this.bottomSafeHeight + 8) })
    }
    .width('100%').height('100%')
    .backgroundColor(this.theme.bgSecondary)
  }
}
