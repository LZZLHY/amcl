/**
 * 版本详情域的选项行、分隔线与单选行。
 *
 * 本文件只消费父层确认的展示值并派发整行操作，不读取偏好、不持有版本身份，
 * 也不负责展开、保存、导航或半模态关闭。父层仍是这些业务状态的唯一所有者。
 * 行内容沿用 V1 Prop，内部 Builder 直接读取组件字段，避免多参数 Builder 的刷新边界。
 */
import { AppIconName, ThemeColors } from 'commons';
import { AppIcon } from './AppIcon';

/**
 * 同组通用选项行。kind 支持 readonly/navigation/disclosure/action/external：
 * navigation 包含进入同一 Sheet 内的单选页，统一用向右箭头；external 才用右上箭头。
 * disclosure 根据父层 expanded 展示上下箭头；即时 action 与只读项不伪装成页面导航。
 */
@Component
export struct VersionDetailOptionRow {
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop value: string = '';
  @Prop icon: AppIconName = AppIconName.Settings;
  @Prop controlId: string = '';
  @Prop kind: string = 'navigation';
  @Prop expanded: boolean = false;
  @Prop danger: boolean = false;
  @Prop actionEnabled: boolean = true;
  onAction: () => void = () => {};

  /** 只有明确的导航、展开和外跳展示尾部方向；尾区始终保留24vp以对齐同组内容。 */
  private showsTrailing_(): boolean {
    return this.kind === 'navigation' || this.kind === 'disclosure' || this.kind === 'external';
  }

  /** 图标目录均复用已验证资源，不把进入单选页画成原地弹出下拉菜单。 */
  private trailingIcon_(): AppIconName {
    if (this.kind === 'external') return AppIconName.ArrowUpRight;
    if (this.kind === 'disclosure') return this.expanded ? AppIconName.ChevronUp : AppIconName.ChevronDown;
    return AppIconName.ChevronRight;
  }

  /** 读出完整内容与展开状态；视觉图标不再创建额外无障碍焦点。 */
  private accessibilityLabel_(): string {
    let label: string = this.title;
    if (this.value.length > 0) label += '，' + this.value;
    if (this.description.length > 0) label += '，' + this.description;
    if (this.kind === 'disclosure') label += this.expanded ? '，已展开' : '，已收起';
    if (this.kind === 'external') label += '，在外部打开';
    return label;
  }

  /** 点击只发一次请求；父层禁用后的迟到点击以及误调用只读行均不得执行动作。 */
  private requestAction_(): void {
    if (this.kind !== 'readonly' && this.actionEnabled) this.onAction();
  }

  /**
   * 唯一内容内边距位于本 Row；外层 Button 的 padding 为0，72vp是整行最小高度。
   * 中间 Flex 按文本原生测量宽度换行，标题与值不压缩、不截断。短值留在标题右侧，
   * 值太长或系统fp字体放大后空间不足时，整个值移到下一行并从内容左侧开始。
   * 每段文本最多占中间区域全宽，超长文件名/技术值仍可自身换行；无窗口监听和全局字体写入。
   */
  @Builder
  private rowContent_() {
    Row({ space: 12 }) {
      Row() {
        AppIcon({ name: this.icon, iconSize: 22,
          color: this.danger ? this.theme.errorText : this.theme.textSecondary });
      }.width(22).height(22).justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
        .flexShrink(0).accessibilityLevel('no');

      Column({ space: 4 }) {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, alignContent: FlexAlign.Start }) {
          Text(this.title).fontSize(16).fontWeight(600)
            .fontColor(this.danger ? this.theme.errorText : this.theme.textPrimary)
            .constraintSize({ maxWidth: '100%' }).flexGrow(1).flexShrink(0)
            // 间距归标题尾部，值换到下一行时不会携带左边距而产生错位。
            .padding({ right: this.value.length > 0 ? 12 : 0 });
          if (this.value.length > 0) {
            Text(this.value).fontSize(14)
              .fontColor(this.danger ? this.theme.errorText :
                (this.kind === 'action' ? this.theme.actionText : this.theme.textSecondary))
              .constraintSize({ maxWidth: '100%' }).flexShrink(0).wordBreak(WordBreak.BREAK_ALL);
          }
        }.width('100%');
        if (this.description.length > 0) {
          Text(this.description).fontSize(14).fontColor(this.theme.textSecondary).width('100%');
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);

      Row() {
        if (this.showsTrailing_()) {
          AppIcon({ name: this.trailingIcon_(), iconSize: 16,
            color: this.danger ? this.theme.errorText : this.theme.textSecondary });
        }
      }.width(24).height(24).flexShrink(0).justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center).accessibilityLevel('no');
    }.width('100%').constraintSize({ minHeight: 72 })
      .padding({ left: 16, right: 16, top: 12, bottom: 12 }).alignItems(VerticalAlign.Center);
  }

  build() {
    if (this.kind === 'readonly') {
      // 只读信息仍可整体播报，但不创建按钮角色或无效键盘操作。
      Row() { this.rowContent_(); }.width('100%').id(this.controlId)
        .accessibilityGroup(true).accessibilityText(this.accessibilityLabel_());
    } else {
      Button({ type: ButtonType.Normal }) { this.rowContent_(); }
        .width('100%').constraintSize({ minHeight: 72 }).padding(0).borderRadius(0)
        .backgroundColor(Color.Transparent).enabled(this.actionEnabled).id(this.controlId)
        .accessibilityGroup(true).accessibilityText(this.accessibilityLabel_())
        .onClick((): void => { this.requestAction_(); });
    }
  }
}

/** 只画组内边界，不增加行高或垂直留白；组背景和圆角由详情宿主统一拥有。 */
@Component
export struct VersionDetailDivider {
  @Prop theme: ThemeColors = {} as ThemeColors;
  build() {
    Row() { Divider().width('100%').strokeWidth(0.5).color(this.theme.divider); }
      .width('100%').padding({ left: 50, right: 16 }).accessibilityLevel('no');
  }
}

/**
 * 同一 Sheet 内单选页的选项行。selected由父层草稿投影，组件不会自行选择或保存。
 * group应由宿主按选择类别/面板owner提供，controlId应为选项稳定ID，避免复用标题当业务身份。
 * 外层普通Button是唯一点击和键盘入口；Radio仅显示确认的选中态，不另挂onChange。
 */
@Component
export struct VersionDetailChoiceRow {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop selected: boolean = false;
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop controlId: string = '';
  @Prop group: string = 'version-detail-choice';
  onAction: () => void = () => {};

  /** 由唯一可聚焦Button读出选择状态，不让装饰性Radio重复播报或重复派发。 */
  private accessibilityLabel_(): string {
    return this.title + (this.description.length > 0 ? '，' + this.description : '') +
      (this.selected ? '，已选择' : '，未选择');
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.title).fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary).width('100%');
          if (this.description.length > 0) {
            Text(this.description).fontSize(14).fontColor(this.theme.textSecondary).width('100%');
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
        // None不阻断祖先Button的触摸测试；焦点和读屏也统一交给父按钮。
        // Radio原生默认四周各有14px margin，显式清零才能保证尾区确为24vp且不抬高普通行。
        Radio({ value: this.controlId.length > 0 ? this.controlId : this.title, group: this.group })
          .checked(this.selected).width(24).height(24).margin(0).flexShrink(0)
          .radioStyle({ checkedBackgroundColor: this.theme.actionPrimary,
            uncheckedBorderColor: this.theme.controlBorder })
          .hitTestBehavior(HitTestMode.None).focusable(false).accessibilityLevel('no');
      }.width('100%').constraintSize({ minHeight: 72 })
        .padding({ left: 16, right: 16, top: 12, bottom: 12 }).alignItems(VerticalAlign.Center);
    }.width('100%').constraintSize({ minHeight: 72 }).padding(0).borderRadius(0)
      .backgroundColor(this.selected ? this.theme.primaryLight : Color.Transparent).id(this.controlId)
      .accessibilityGroup(true).accessibilityText(this.accessibilityLabel_())
      .onClick((): void => { this.onAction(); });
  }
}
