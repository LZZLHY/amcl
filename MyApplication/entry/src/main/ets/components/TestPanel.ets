/**
 * TestPanel — 通用测试面板组件
 *
 * 提供统一的按钮 + 滚动结果显示区域，消除 Index.ets 中的重复 UI 代码。
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';

@Component
export struct TestPanel {
  @Prop buttonText: string = '运行测试'
  @Prop buttonColor: string = '#007DFF'
  @Prop placeholder: string = '点击上方按钮开始测试'
  @Prop isRunning: boolean = false
  @Prop testResult: string = ''
  onRun: () => void = () => {}

  build() {
    Column() {
      Button(this.isRunning ? '测试中...' : this.buttonText)
        .type(ButtonType.Capsule)
        .width('80%')
        .height(48)
        .fontSize(16)
        .backgroundColor(this.isRunning ? '#CCCCCC' : this.buttonColor)
        .enabled(!this.isRunning)
        .margin({ bottom: 12 })
        .onClick(() => {
          this.onRun()
        })

      // 复制结果按钮
      if (this.testResult.length > 0) {
        Button('复制结果')
          .type(ButtonType.Capsule)
          .width('50%')
          .height(32)
          .fontSize(13)
          .backgroundColor('#607D8B')
          .fontColor('#FFFFFF')
          .margin({ bottom: 8 })
          .onClick(() => {
            const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.testResult)
            const sysBoard = pasteboard.getSystemPasteboard()
            sysBoard.setData(pasteData, () => {
              // 2026-05-23 API NEXT 迁移：promptAction.showToast 弃用，改走 UIContext。
              // 详见 docs/guides/api-migration-2026-05.md。
              this.getUIContext().getPromptAction().showToast({ message: '已复制到剪贴板', duration: 1500 })
            })
          })
      }

      Scroll() {
        Text(this.testResult || this.placeholder)
          .fontSize(13)
          .fontFamily('monospace')
          .padding(14)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor('#F5F5F5')
      .borderRadius(12)
    }
    .width('92%')
    .layoutWeight(1)
    .margin({ bottom: 12 })
  }
}
