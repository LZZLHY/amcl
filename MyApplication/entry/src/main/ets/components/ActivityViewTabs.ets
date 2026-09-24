/**
 * 活动工作区页签：固定点击区、细分隔线与滑动下划线形成主次层级。
 * 参考开源工作台的信息组织，自行使用 ArkUI 实现；不依赖 Web 动画运行时。
 */
import { curves } from '@kit.ArkUI';
import { ThemeColors } from 'commons';
import { UiMotion } from './UiMotion';

@Component
export struct ActivityViewTabs {
  @Prop labels: string[] = [];
  @Prop @Watch('move_') selectedIndex: number = 0;
  @Prop theme: ThemeColors = new ThemeColors();
  onSelect: (index: number) => void = () => {};
  @State private trackWidth: number = 0;
  @State private indicatorX: number = 0;

  /** 手机上等分，宽屏保持每项 144vp；空出的右侧让正文保有自己的阅读轴。 */
  private itemWidth_(): number { return Math.min(144, this.trackWidth / Math.max(1, this.labels.length)); }
  private target_(): number { return Math.max(0, Math.min(this.labels.length - 1, this.selectedIndex)) * this.itemWidth_(); }

  /** 只合成移动指示器；快速切换继承原生弹簧速度，不延迟业务状态。 */
  private move_(): void {
    if (UiMotion.reduced() || this.trackWidth <= 0) { this.indicatorX = this.target_(); return; }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.26, 0.92) }, (): void => { this.indicatorX = this.target_(); });
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Row().height(1).width('100%').backgroundColor(this.theme.divider).hitTestBehavior(HitTestMode.None)
      Row().height(2).width(Math.max(0, this.itemWidth_() - 24)).margin({ left: 12 })
        .backgroundColor(this.theme.primary).borderRadius(1).translate({ x: this.indicatorX }).hitTestBehavior(HitTestMode.None)
      Row() {
        ForEach(this.labels, (label: string, index: number) => {
          Button(label).height(48).width(this.itemWidth_()).borderRadius(8).fontSize(14)
            .fontColor(this.selectedIndex === index ? this.theme.textPrimary : this.theme.textSecondary)
            .fontWeight(this.selectedIndex === index ? 600 : 400).backgroundColor(Color.Transparent)
            .accessibilityText(label + (this.selectedIndex === index ? '，已选中' : ''))
            .onClick(() => { if (index !== this.selectedIndex) this.onSelect(index); })
        }, (label: string): string => label)
      }.width('100%')
    }.width('100%').height(48).onAreaChange((_old: Area, current: Area): void => {
      this.trackWidth = Number(current.width); this.indicatorX = this.target_();
    })
  }
}
