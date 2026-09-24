/**
 * 时间轴行：时间、状态节点与细连线独立于内容卡片，不再用一列大卡片代替时间线。
 * 只测量右侧内容高度，左侧连线跟随；AI 摘要变化不会形成双向尺寸依赖。
 */
import { ThemeColors } from 'commons';

@Component
export struct ActivityTimelineItem {
  @Prop time: string = '';
  @Prop color: ResourceColor = '#006FE6';
  @Prop last: boolean = false;
  @Prop theme: ThemeColors = new ThemeColors();
  @BuilderParam content: () => void = this.empty_;
  @State private cardHeight: number = 0;

  @Builder
  private empty_() { Column() {} }

  build() {
    Row({ space: 10 }) {
      Column({ space: 0 }) {
        Text(this.time).fontSize(10).fontFamily('monospace').fontWeight(500)
          .fontColor(this.theme.textSecondary).height(18)
        Stack() {
          // 基础背景/圆角支持 API 20，不依赖 ResourceColor 的新版 fill 重载。
          Row().width(8).height(8).backgroundColor(this.color).borderRadius(4)
        }.width(38).height(26).accessibilityLevel('no')
        if (!this.last) {
          Column().width(1).height(Math.max(0, this.cardHeight - 44))
            .backgroundColor(this.theme.divider).accessibilityLevel('no')
        }
      }.width(38)
      Column() { this.content() }.layoutWeight(1)
        .onAreaChange((_old: Area, current: Area): void => { this.cardHeight = Number(current.height); })
    }.width('100%').alignItems(VerticalAlign.Top)
  }
}
