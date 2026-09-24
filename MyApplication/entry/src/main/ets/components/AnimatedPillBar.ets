/**
 * 共享的胶囊切换栏：只有一个选中背景，用弹簧平移到目标项。
 * 快速连续点击由 springMotion 继承当前速度，不排队，不改动内容区域的布局尺寸。
 * 宽度变化只重新定位终点；业务选中值始终由父组件持有。
 */
import { curves } from '@kit.ArkUI';
import { ThemeColors } from 'commons';
import { UiMotion } from './UiMotion';

@Component
export struct AnimatedPillBar {
  @Prop labels: string[] = [];
  @Prop @Watch('selectionChanged_') selectedIndex: number = 0;
  @Prop theme: ThemeColors = new ThemeColors();
  @Prop filled: boolean = false;
  @Prop disabled: boolean = false;
  onSelect: (index: number) => void = () => {};
  @State private trackWidth: number = 0;
  @State private highlightX: number = 0;

  private itemWidth_(): number { return Math.max(0, this.trackWidth - 8) / Math.max(1, this.labels.length); }

  private targetX_(): number {
    const index: number = Math.max(0, Math.min(this.labels.length - 1, this.selectedIndex));
    return this.itemWidth_() * index;
  }

  /** 只动画背景的 x；文本和触控区域固定，不在每帧重新布局所有按钮。 */
  private selectionChanged_(): void {
    if (UiMotion.reduced() || this.trackWidth <= 0) { this.highlightX = this.targetX_(); return; }
    this.getUIContext().animateTo({ curve: curves.springMotion(0.32, 0.86) }, (): void => {
      this.highlightX = this.targetX_();
    });
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row().width(this.itemWidth_()).height(44).borderRadius(22)
        .backgroundColor(this.filled ? this.theme.actionPrimary : this.theme.bgCard)
        .translate({ x: this.highlightX }).hitTestBehavior(HitTestMode.None)
      Row() {
        ForEach(this.labels, (label: string, index: number) => {
          Button(label).layoutWeight(1).height(44).fontSize(12)
            .fontWeight(this.selectedIndex === index ? 600 : 400)
            .fontColor(this.selectedIndex === index ? (this.filled ? this.theme.textOnPrimary : this.theme.primary) : this.theme.textSecondary)
            .backgroundColor(Color.Transparent).enabled(!this.disabled)
            .accessibilityText(label + (this.selectedIndex === index ? '，已选中' : ''))
            .onClick(() => { if (index !== this.selectedIndex) this.onSelect(index); })
        }, (label: string, index: number): string => index + '-' + label)
      }.width('100%')
    }.width('100%').height(52).padding(4).borderRadius(26).backgroundColor(this.theme.bgInput)
      .onAreaChange((_old: Area, current: Area): void => {
        this.trackWidth = Number(current.width);
        this.highlightX = this.targetX_();
      })
  }
}
