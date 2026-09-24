/**
 * CancelDownloadDialog.ets — 下载取消确认对话框（v5 新增）
 *
 * 用户按"取消下载"时弹出，提供三个选项：
 *   - 保留已下文件（下次续传）— 默认推荐
 *   - 清理已下文件（释放磁盘）
 *   - 继续下载（取消本次操作）
 *
 * UI 层通过 @CustomDialog 注入并在 Index.ets 里控制显隐。
 */

import { ThemeColors } from 'commons';

@CustomDialog
export struct CancelDownloadDialog {
  controller: CustomDialogController
  theme: ThemeColors = {} as ThemeColors
  versionName: string = ''
  bytesDone: number = 0       // 已下载字节数，用于展示"已下载 42 MB"
  bytesDoneLabel: string = '' // 预格式化的字节文案（调用方传进来，避免 Dialog 里再依赖 PathUtils）

  // 回调：true = 清理、false = 保留
  onConfirm: (cleanup: boolean) => void = () => {}
  onDismiss: () => void = () => {}

  build() {
    Column({ space: 16 }) {
      // 标题
      Row() {
        Text('取消下载？')
          .fontSize(18)
          .fontWeight(700)
          .fontColor(this.theme.textPrimary)
      }
      .width('100%')
      .padding({ top: 4 })

      // 描述
      Column({ space: 6 }) {
        Text(this.versionName)
          .fontSize(14)
          .fontWeight(600)
          .fontColor(this.theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.bytesDoneLabel.length > 0) {
          Text('已下载 ' + this.bytesDoneLabel + '，可选择是否清理已下载的文件')
            .fontSize(13)
            .fontColor(this.theme.textSecondary)
        } else {
          Text('可选择是否清理已下载的文件')
            .fontSize(13)
            .fontColor(this.theme.textSecondary)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // 按钮 — 三个操作并排
      Column({ space: 10 }) {
        Button('保留已下文件（下次续传）')
          .type(ButtonType.Capsule)
          .width('100%')
          .height(44)
          .fontSize(14)
          .fontWeight(600)
          .backgroundColor(this.theme.primary)
          .fontColor(this.theme.textOnPrimary)
          .onClick(() => {
            this.controller.close()
            this.onConfirm(false)
          })

        Button('清理已下文件')
          .type(ButtonType.Capsule)
          .width('100%')
          .height(44)
          .fontSize(14)
          .backgroundColor(this.theme.bgInput)
          .fontColor(this.theme.error)
          .onClick(() => {
            this.controller.close()
            this.onConfirm(true)
          })

        Button('继续下载')
          .type(ButtonType.Capsule)
          .width('100%')
          .height(44)
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor(this.theme.textSecondary)
          .onClick(() => {
            this.controller.close()
            this.onDismiss()
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(20)
    .backgroundColor(this.theme.bgCard)
    .borderRadius(16)
  }
}
