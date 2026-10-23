/**
 * 圆形图标操作的普通渲染底座，使用真实 Button 提供焦点、键盘、按压和禁用语义。
 * 视觉圆与命中区分开；不查询设备、不读取偏好、不创建导航。合法 HDS 标题内的
 * 原生项由共同标题宿主绘制；正文、特殊浮层和旧系统以本组件提供普通样式。
 */
import { AppIconName, ThemeColors } from 'commons';
import { AppIcon } from './AppIcon';
import { ROUND_ACTION_HIT_SIZE, roundActionLabel } from './AppTitleAction';

/**
 * SDK分别声明string和Resource两个无障碍重载；在修饰器内真实收窄类型，
 * 将资源交还系统本地化，不通过不实强转或每次重绘同步读取资源来绕过检查。
 */
class RoundActionAccessibility implements AttributeModifier<ButtonAttribute> {
  private label_: ResourceStr;
  constructor(label: ResourceStr) { this.label_ = label; }
  applyNormalAttribute(button: ButtonAttribute): void {
    const label: ResourceStr = this.label_;
    if (typeof label === 'string') button.accessibilityText(label);
    else button.accessibilityText(label);
  }
}

@Component
export struct AppRoundIconButton {
  @Prop name: AppIconName = AppIconName.Help;
  @Prop theme: ThemeColors = {} as ThemeColors;
  /** 保留字符串资源，聊天等已本地化的调用方不必同步读取或重新拼文案。 */
  @Prop accessibilityLabel: ResourceStr = '';
  @Prop actionEnabled: boolean = true;
  @Prop visualDiameter: number = ROUND_ACTION_HIT_SIZE;
  @Prop iconSize: number = 20;
  /** 特殊编辑／游戏浮层沿用已有配色，普通页面只需传主题。 */
  @Prop color: ResourceColor | undefined = undefined;
  @Prop containerBg: ResourceColor | undefined = undefined;
  @Prop controlId: string = '';
  @Prop badge: string = '';
  onAction: () => void = () => {};
  /** 控件销毁后原生队列中的迟到点击不应再派发到已离开的页面。 */
  private alive_: boolean = false;
  aboutToAppear(): void { this.alive_ = true; }
  aboutToDisappear(): void { this.alive_ = false; }

  /** 大按钮保留原视觉尺寸，小圆仍至少占44vp，避免隐形热区与邻项重叠。 */
  private hitDiameter_(): number { return Math.max(ROUND_ACTION_HIT_SIZE, this.visualDiameter); }

  /** 再读当前禁用状态，拒绝已进入原生事件队列的迟到点击。 */
  private requestAction_(): void { if (this.alive_ && this.actionEnabled) this.onAction(); }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        Row() {
          AppIcon({ name: this.name, iconSize: this.iconSize,
            color: this.color ?? this.theme.textPrimary ?? '#182431' }).accessibilityLevel('no')
        }.width(this.visualDiameter).height(this.visualDiameter)
          .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
          .borderRadius(this.visualDiameter / 2)
          .backgroundColor(this.containerBg ?? this.theme.bgCard ?? Color.Transparent)
      }.width(this.hitDiameter_()).height(this.hitDiameter_()).padding(0)
        .backgroundColor(Color.Transparent).enabled(this.actionEnabled).opacity(this.actionEnabled ? 1 : 0.4)
        .attributeModifier(new RoundActionAccessibility(this.accessibilityLabel || roundActionLabel(this.name)))
        .id(this.controlId)
        // 使用Button内置点击竞争；ClickEvent没有stopPropagation，不额外叠加手势。
        .onClick((): void => { this.requestAction_(); })
      if (this.badge.length > 0) {
        Row() {
          Text(this.badge).fontSize(9).fontWeight(FontWeight.Bold)
            .fontColor(this.theme.textOnPrimary ?? '#FFFFFF').maxLines(1)
        }.constraintSize({ minWidth: 16 }).height(16).padding({ left: 4, right: 4 })
          .borderRadius(8).backgroundColor(this.theme.error ?? '#D43C33')
          .position({ x: this.hitDiameter_() - 14, y: 0 })
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      }
    }.width(this.hitDiameter_()).height(this.hitDiameter_())
  }
}
