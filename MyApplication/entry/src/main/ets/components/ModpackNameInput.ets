/**
 * 整合包安装前的版本名称输入。在线下载详情与本地导入详情共用普通版本的紧凑卡片样式。
 * 名称和校验结果由父页面持有；本组件只回传编辑，不持有安装任务或读取文件系统，
 * 因此详情关闭后不会修改已经快照并入队的安装意图。
 */
import { ThemeColors, AppIconName } from 'commons';
import { AppIcon } from './AppIcon';

@Component
export struct ModpackNameInput {
  @Prop theme: ThemeColors;
  @Prop value: string = '';
  @Prop error: string = '';
  /** 每次编辑同步到父页面，由父页面校验并决定开始按钮是否可用。 */
  onChange: (value: string) => void = (_value: string): void => {};

  build() {
    Column({ space: 8 }) {
      Text('版本名称').fontSize(13).fontWeight(600).fontColor(this.theme.textPrimary)
      Row() {
        TextInput({ text: this.value, placeholder: '输入版本名称...' })
          .height(40).fontSize(14).fontColor(this.theme.textPrimary).layoutWeight(1)
          .backgroundColor(Color.Transparent).borderRadius(0)
          .onChange((value: string): void => { this.onChange(value); })
        AppIcon({ name: AppIconName.Edit, iconSize: 14, color: this.theme.textHint })
          .padding({ left: 8, right: 12 })
      }.width('100%').padding({ left: 12 }).backgroundColor(this.theme.bgInput).borderRadius(10)
      if (this.error.length > 0) {
        Text(this.error).fontSize(11).fontColor(this.theme.error).width('100%')
      } else {
        Text('重名时自动添加序号').fontSize(11).fontColor(this.theme.textHint).width('100%')
      }
    }.width('100%').padding(12).backgroundColor(this.theme.bgCard).borderRadius(14)
      .alignItems(HorizontalAlign.Start)
  }
}
