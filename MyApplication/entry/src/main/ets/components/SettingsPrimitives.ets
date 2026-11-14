/**
 * 设置域的展示原语：统一分组、导航行、开关行、说明及分隔线。
 *
 * 这些组件只渲染父层确认值，不读取偏好、不查询设备，也不自行决定配置是否可用。
 * 所有写入继续经调用方回调交给原业务所有者；行高采用最小值，让系统大字体可以撑开。
 * 正文容器保持 V1 状态管理，跨组件正文用具名 BuilderParam 与父层箭头转调绑定。
 */
import { AppIconName, ThemeColors } from 'commons';
import { AppIcon } from './AppIcon';

/** 一个有明确功能归属的列表组；标题位于白色内容组之外，避免与具体设置争夺视觉重点。 */
@Component
export struct SettingsGroup {
  @Prop title: string = '';
  @Prop theme: ThemeColors = {} as ThemeColors;
  @BuilderParam content: () => void = this.empty_;

  /** 默认空正文只用于安全初始化，实际调用必须提供所属页面的正文 Builder。 */
  @Builder
  private empty_() { Column() {} }

  build() {
    Column({ space: 8 }) {
      if (this.title.length > 0) {
        Text(this.title).fontSize(14).fontColor(this.theme.textSecondary)
          .width('100%').padding({ left: 16, right: 16 });
      }
      Column({ space: 0 }) { this.content() }
        .width('100%').backgroundColor(this.theme.bgCard).borderRadius(20).clip(true);
    }.width('100%').alignItems(HorizontalAlign.Start);
  }
}

/** 组内分隔线只承担行的边界，左右缩进与设置正文对齐。 */
@Component
export struct SettingsDivider {
  @Prop theme: ThemeColors = {} as ThemeColors;
  build() {
    Row() { Divider().color(this.theme.divider).strokeWidth(0.5).width('100%'); }
      .width('100%').padding({ left: 16, right: 16 });
  }
}

/** 可点击行同时呈现名称、可选说明和当前值；复制等即时动作可以指定自己的尾部图标。 */
@Component
export struct SettingsValueRow {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop value: string = '';
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop showIcon: boolean = false;
  @Prop icon: AppIconName = AppIconName.Settings;
  @Prop showTrailing: boolean = true;
  @Prop trailingIcon: AppIconName = AppIconName.ChevronRight;
  @Prop actionValue: boolean = false;
  @Prop interactive: boolean = true;
  @Prop actionEnabled: boolean = true;
  @Prop controlId: string = '';
  @Prop highlighted: boolean = false;
  onAction: () => void = () => {};
  onLayout: () => void = () => {};

  /** 行内容访问自身 Prop，因此当前值、主题和禁用状态随父层发布正常刷新。 */
  @Builder
  private row_() {
    Row({ space: 12 }) {
      if (this.showIcon) {
        Row() { AppIcon({ name: this.icon, iconSize: 22, color: this.theme.actionText }); }
          .width(36).height(36).borderRadius(12).backgroundColor(this.theme.primaryLight)
          .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center);
      }
      Column({ space: 4 }) {
        Text(this.title).fontSize(16).fontColor(this.theme.textPrimary).width('100%');
        if (this.description.length > 0) {
          Text(this.description).fontSize(14).fontColor(this.theme.textSecondary)
            .lineHeight(20).width('100%');
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      if (this.value.length > 0) {
        Text(this.value).fontSize(14)
          .fontColor(this.actionValue ? this.theme.actionText : this.theme.textSecondary)
          .constraintSize({ maxWidth: 150 }).textAlign(TextAlign.End);
      }
      if (this.showTrailing && this.interactive) {
        AppIcon({ name: this.trailingIcon, iconSize: 16, color: this.theme.textSecondary });
      }
    }.width('100%').constraintSize({ minHeight: this.description.length > 0 ? 76 : 64 })
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor(this.highlighted ? this.theme.primaryLight : Color.Transparent)
      .alignItems(VerticalAlign.Center);
  }

  build() {
    if (this.interactive) {
      Button({ type: ButtonType.Normal }) { this.row_(); }
        .width('100%').constraintSize({ minHeight: this.description.length > 0 ? 76 : 64 })
        .padding(0).borderRadius(0).backgroundColor(Color.Transparent)
        .enabled(this.actionEnabled).id(this.controlId)
        .accessibilityText(this.title + (this.value.length > 0 ? '，' + this.value : ''))
        .onClick((): void => { if (this.actionEnabled) this.onAction(); })
        .onAreaChange((): void => { this.onLayout(); });
    } else {
      Row() { this.row_(); }.width('100%').id(this.controlId).onAreaChange((): void => { this.onLayout(); });
    }
  }
}

/** 开关只发送请求值，确认态仍由父层传回；保存期间禁用不改变旧值或清空说明。 */
@Component
export struct SettingsToggleRow {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop value: boolean = false;
  @Prop saving: boolean = false;
  @Prop actionEnabled: boolean = true;
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop controlId: string = '';
  @Prop highlighted: boolean = false;
  onChange: (value: boolean) => void = () => {};
  onLayout: () => void = () => {};

  build() {
    Row({ space: 16 }) {
      Column({ space: 4 }) {
        Text(this.title).fontSize(16).fontColor(this.theme.textPrimary).width('100%');
        if (this.description.length > 0) {
          Text(this.description).fontSize(14).fontColor(this.theme.textSecondary)
            .lineHeight(20).width('100%');
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      if (this.saving) {
        LoadingProgress().width(48).height(32).color(this.theme.actionText);
      } else {
        Toggle({ type: ToggleType.Switch, isOn: this.value })
          .width(48).height(32).selectedColor(this.theme.primary)
          .responseRegion({ x: 0, y: -8, width: 48, height: 48 })
          .enabled(this.actionEnabled).id(this.controlId).accessibilityText(this.title)
          .onChange((value: boolean): void => { if (this.actionEnabled) this.onChange(value); });
      }
    }.width('100%').constraintSize({ minHeight: this.description.length > 0 ? 76 : 64 })
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor(this.highlighted ? this.theme.primaryLight : Color.Transparent)
      .alignItems(VerticalAlign.Center).onAreaChange((): void => { this.onLayout(); });
  }
}

/** 辅助说明统一使用可读的次要文字色，避免沿用低对比度占位色承载必要信息。 */
@Component
export struct SettingsHint {
  @Prop text: string = '';
  @Prop theme: ThemeColors = {} as ThemeColors;
  @Prop isError: boolean = false;
  @Prop isAccent: boolean = false;
  build() {
    Text(this.text).fontSize(14).lineHeight(22).width('100%')
      .fontColor(this.isError ? this.theme.errorText : this.isAccent ? this.theme.actionText : this.theme.textSecondary);
  }
}
