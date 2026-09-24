/**
 * DownloadPhaseCard.ets — 下载阶段卡片组件 (v5.2)
 *
 * v5.2: @ObjectLink detail: PhaseDetailModel 替代 @Prop @Watch，
 *       属性变化直接触发重渲染，不依赖父组件重新传值。
 *
 * 视觉规格：
 *   - running：主题色左边框 + bgCard 背景，自动展开，显示文件计数+当前文件
 *   - done：bgCard 背景 80% 不透明，收起，展开显示统计摘要
 *   - error：errorBg 背景 + 红色左边框，自动展开，显示失败文件列表
 *   - pending：bgCard 背景 60% 不透明，不可展开
 *   - 状态点用原生 Circle，展开箭头 / 错误标识用 SymbolGlyph，统一扁平化语言
 */

import { DownloadPhase, PhaseDetailModel, FailedFileBrief } from 'feature_core';
import { ThemeColors } from 'commons';
import { formatBytes } from 'commons';
import { AppIconName } from 'commons';
import { AppIcon } from './AppIcon';

@Component
export struct DownloadPhaseCard {
  @ObjectLink detail: PhaseDetailModel
  @Prop currentFiles: string[] = []
  @Prop failedFiles: FailedFileBrief[] = []
  @Prop theme: ThemeColors = {} as ThemeColors
  @Prop isActivePhase: boolean = false

  @State userToggled: boolean = false
  @State userExpanded: boolean = false

  /**
   * 状态指示色：done = 绿、running = 主题蓝、error = 红、pending = 灰。
   * pending 会通过 isFilledDot()=false 渲染成空心圆环。
   */
  private getStatusDotColor(): ResourceColor {
    if (this.detail.status === 'done') return this.theme.success
    if (this.detail.status === 'running') return this.theme.primary
    if (this.detail.status === 'error') return this.theme.error
    return this.theme.disabled
  }

  /** pending 阶段画空心环；其余画实心点 */
  private isFilledDot(): boolean {
    return this.detail.status !== 'pending'
  }

  private getProgressText(): string {
    if (this.detail.status === 'pending') return '待执行'
    if (this.detail.status === 'done') {
      if (this.detail.total > 0 && this.detail.phase === DownloadPhase.CLIENT) {
        return formatBytes(this.detail.total)
      }
      if (this.detail.total > 0) return this.detail.total + ' 文件'
      return this.detail.message || '完成'
    }
    if (this.detail.status === 'error') return this.detail.message || '失败'
    // modloader（Forge/Fabric 安装）阶段的 current/total 是“安装步骤序号”而非文件数，
    // 显示百分比更贴切，也避免长耗时安装器步里冻结的“5/8 文件”被误认为卡死。
    if (this.detail.phase === DownloadPhase.MODLOADER) {
      if (this.detail.total > 0) {
        return Math.round(this.detail.current / this.detail.total * 100) + '%'
      }
      return this.detail.message || '安装中...'
    }
    if (this.detail.total > 0) {
      if (this.detail.phase === DownloadPhase.CLIENT) {
        return formatBytes(this.detail.current) + ' / ' + formatBytes(this.detail.total)
      }
      return this.detail.current + '/' + this.detail.total + ' 文件'
    }
    return this.detail.message || '进行中...'
  }

  private getLeftBorderColor(): ResourceColor {
    if (this.detail.status === 'running') return this.theme.primary
    if (this.detail.status === 'error') return this.theme.error
    return '#00000000'
  }

  private getCardBg(): ResourceColor {
    if (this.detail.status === 'error') return this.theme.errorBg
    return this.theme.bgCard
  }

  private getCardOpacity(): number {
    if (this.detail.status === 'pending') return 0.6
    if (this.detail.status === 'done') return 0.8
    return 1.0
  }

  private canExpand(): boolean {
    return this.detail.status !== 'pending'
  }

  private isExpanded(): boolean {
    if (this.detail.status === 'running' || this.detail.status === 'error') {
      return this.userToggled ? this.userExpanded : true
    }
    if (this.detail.status === 'pending') return false
    return this.userToggled ? this.userExpanded : false
  }

  private formatErr(ff: FailedFileBrief): string {
    let kind = ff.errorKind || '失败'
    if (ff.httpStatus > 0) {
      return kind + ' HTTP ' + ff.httpStatus
    }
    let m = kind
    if (ff.errorMessage) {
      m += ': ' + (ff.errorMessage.length > 40 ? ff.errorMessage.substring(0, 40) + '...' : ff.errorMessage)
    }
    return m
  }

  build() {
    Column() {
      Row() {
        Stack() {
          if (this.isFilledDot()) {
            Circle({ width: 10, height: 10 }).fill(this.getStatusDotColor())
          } else {
            // 空心环：用一个 stroke=2 的 Circle 模拟（Circle 的 fill 是实心，
            // 用 Stack 叠 2 层避免引入 SymbolGlyph，省一次字体绘制）
            Circle({ width: 10, height: 10 })
              .fill(this.theme.bgCard)
              .stroke(this.getStatusDotColor())
              .strokeWidth(1.5)
          }
        }
        .width(24)
        .height(10)
        .alignContent(Alignment.Center)

        Text(this.detail.label)
          .fontSize(14)
          .fontWeight(this.detail.status === 'running' ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.theme.textPrimary)
          .layoutWeight(1)

        Text(this.getProgressText())
          .fontSize(12)
          .fontColor(this.detail.status === 'error' ? this.theme.error : this.theme.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 140 })

        if (this.canExpand()) {
          AppIcon({
            name: this.isExpanded() ? AppIconName.ChevronUp : AppIconName.ChevronDown,
            iconSize: 12,
            color: this.theme.textHint,
          })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
      .onClick(() => {
        if (this.canExpand()) {
          this.userToggled = true
          this.userExpanded = !this.isExpanded()
        }
      })

      if (this.isExpanded() && this.canExpand()) {
        Column() {
          if (this.detail.status === 'running') {
            if (this.detail.total > 0) {
              Row() {
                Text('进度：')
                  .fontSize(12).fontColor(this.theme.textHint)
                if (this.detail.phase === DownloadPhase.CLIENT) {
                  Text(formatBytes(this.detail.current) + ' / ' + formatBytes(this.detail.total))
                    .fontSize(12).fontColor(this.theme.textSecondary)
                } else if (this.detail.phase === DownloadPhase.MODLOADER) {
                  Text(Math.round(this.detail.current / this.detail.total * 100) + '%')
                    .fontSize(12).fontColor(this.theme.textSecondary)
                } else {
                  Text(this.detail.current + ' / ' + this.detail.total + ' 文件')
                    .fontSize(12).fontColor(this.theme.textSecondary)
                }
              }
              .width('100%')
              .margin({ bottom: 4 })
            }

            if (this.detail.message) {
              Text(this.detail.message)
                .fontSize(12)
                .fontColor(this.theme.textSecondary)
                .margin({ bottom: 4 })
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }

            if (this.isActivePhase && this.currentFiles.length > 0) {
              Text('当前下载:')
                .fontSize(11)
                .fontColor(this.theme.textHint)
                .margin({ top: 4, bottom: 4 })

              ForEach(this.currentFiles.slice(0, 5), (fileName: string, idx: number) => {
                Row() {
                  Circle({ width: 4, height: 4 })
                    .fill(this.theme.textHint)
                    .margin({ right: 8, left: 2 })
                  Text(fileName)
                    .fontSize(12)
                    .fontColor(this.theme.textSecondary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%')
                .padding({ top: 2, bottom: 2 })
              }, (fileName: string, idx: number) => idx + '_' + fileName)
            }
          }

          if (this.detail.status === 'error') {
            if (this.detail.message) {
              Text(this.detail.message)
                .fontSize(12)
                .fontColor(this.theme.error)
                .margin({ bottom: 6 })
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }

            if (this.failedFiles.length > 0) {
              Text(this.failedFiles.length + ' 个文件失败:')
                .fontSize(11)
                .fontColor(this.theme.error)
                .fontWeight(FontWeight.Medium)
                .margin({ bottom: 4 })

              ForEach(this.failedFiles.slice(0, 5), (ff: FailedFileBrief, idx: number) => {
                Column() {
                  Row() {
                    AppIcon({
                      name: AppIconName.Error,
                      iconSize: 12,
                      color: this.theme.error,
                    })
                    Text(ff.basename)
                      .fontSize(12)
                      .fontColor(this.theme.textPrimary)
                      .fontWeight(FontWeight.Medium)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                      .margin({ left: 6 })
                  }
                  .width('100%')

                  Text(this.formatErr(ff))
                    .fontSize(11)
                    .fontColor(this.theme.textSecondary)
                    .margin({ left: 20, top: 2 })
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  if (ff.triedUrls && ff.triedUrls.length > 0) {
                    Text('尝试: ' + ff.triedUrls.join(' → '))
                      .fontSize(10)
                      .fontColor(this.theme.textHint)
                      .margin({ left: 20, top: 2 })
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .width('100%')
                .padding({ top: 4, bottom: 4 })
              }, (ff: FailedFileBrief, idx: number) => idx + '_' + ff.basename)

              if (this.failedFiles.length > 5) {
                Text('…还有 ' + (this.failedFiles.length - 5) + ' 个文件失败')
                  .fontSize(11)
                  .fontColor(this.theme.textHint)
                  .margin({ top: 4 })
              }
            }
          }

          if (this.detail.status === 'done') {
            if (this.detail.total > 0) {
              Row() {
                Text('共 ')
                  .fontSize(12).fontColor(this.theme.textHint)
                if (this.detail.phase === DownloadPhase.CLIENT) {
                  Text(formatBytes(this.detail.total))
                    .fontSize(12).fontColor(this.theme.textSecondary)
                } else {
                  Text(this.detail.total + ' 文件')
                    .fontSize(12).fontColor(this.theme.textSecondary)
                }
              }
              .width('100%')
            }
            if (this.detail.message) {
              Text(this.detail.message)
                .fontSize(12)
                .fontColor(this.theme.textSecondary)
                .margin({ top: this.detail.total > 0 ? 4 : 0 })
            }
          }
        }
        .width('100%')
        .padding({ left: 36, right: 12, bottom: 12 })
      }
    }
    .width('100%')
    .backgroundColor(this.getCardBg())
    .opacity(this.getCardOpacity())
    .borderRadius(12)
    .border({
      width: { left: this.detail.status === 'running' || this.detail.status === 'error' ? 3 : 0 },
      color: { left: this.getLeftBorderColor() }
    })
    .margin({ bottom: 8 })
    .animation({ duration: 200, curve: Curve.EaseInOut })
  }
}
