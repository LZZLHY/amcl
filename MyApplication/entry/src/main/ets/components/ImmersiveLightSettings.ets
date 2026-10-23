/**
 * 沉浸光感详情的纯展示组件。
 *
 * 父页面只下发已确认的偏好及保存状态；此组件不访问存储、不查询设备，也不改写
 * Prop 中的对象。每次操作复制一份完整偏好交回父页面，保存成功或失败均由父页面
 * 重新发布确认态，避免把未落盘的选择当作已生效设置。
 */
import {
  DockLightMode,
  dockLightModeLabel,
  ImmersiveLightPreferences,
  copyImmersiveLightPreferences,
  ThemeColors
} from 'commons';

/** 关闭由总开关表达；这里的四档只表示 HDS 导航材质的渲染偏好。 */
const NAVIGATION_MATERIAL_MODES: DockLightMode[] = [
  DockLightMode.AUTO,
  DockLightMode.EXQUISITE,
  DockLightMode.GENTLE,
  DockLightMode.SMOOTH
];

@Component
export struct ImmersiveLightSettings {
  @Prop theme: ThemeColors = {} as ThemeColors;
  /** 完整的已确认偏好；总关闭不清空其中已保存的模块选择。 */
  @Prop preferences: ImmersiveLightPreferences = new ImmersiveLightPreferences();
  @Prop saving: boolean = false;
  /** 由父页面给出请求档位、设备回退等实际状态，详情组件不自行猜测能力。 */
  @Prop status: string = '';
  @Prop saveError: string = '';
  @Prop hasPresets: boolean = false;
  onChange: (preferences: ImmersiveLightPreferences) => void = () => {};

  /** 总开关始终可在非保存期操作；只改变 enabled，保留档位和两个模块的勾选。 */
  private requestEnabled_(enabled: boolean): void {
    if (this.saving || this.preferences.enabled === enabled) return;
    const next: ImmersiveLightPreferences = copyImmersiveLightPreferences(this.preferences);
    next.enabled = enabled;
    this.onChange(next);
  }

  /** 档位仅影响已启用导航；能力不足时只提供自动，不保存无法兑现的手动选择。 */
  private requestNavigationMode_(mode: DockLightMode): void {
    if (this.saving || !this.preferences.enabled ||
      (!this.hasPresets && mode !== DockLightMode.AUTO) || this.preferences.navigationMode === mode) return;
    const next: ImmersiveLightPreferences = copyImmersiveLightPreferences(this.preferences);
    next.navigationMode = mode;
    this.onChange(next);
  }

  /** 底部栏和标题栏独立保存；关闭任一模块不覆盖另一个模块及材质档位。 */
  private requestBottomBar_(enabled: boolean): void {
    if (this.saving || !this.preferences.enabled || this.preferences.bottomBar === enabled) return;
    const next: ImmersiveLightPreferences = copyImmersiveLightPreferences(this.preferences);
    next.bottomBar = enabled;
    this.onChange(next);
  }

  /** 只控制父层实际接入的返回/关闭按钮，不扩张到所有正文图标或整个弹层背板。 */
  private requestTitleButtons_(enabled: boolean): void {
    if (this.saving || !this.preferences.enabled || this.preferences.titleButtons === enabled) return;
    const next: ImmersiveLightPreferences = copyImmersiveLightPreferences(this.preferences);
    next.titleButtons = enabled;
    this.onChange(next);
  }

  build() {
    Column({ space: 20 }) {
      Column({ space: 12 }) {
        Row({ space: 16 }) {
          Column({ space: 6 }) {
            Text('启用沉浸光感').fontSize(17).fontWeight(600).fontColor(this.theme.textPrimary);
            Text('控制底部导航与圆形图标按钮，不更改系统光感设置。')
              .fontSize(13).fontColor(this.theme.textHint);
          }.layoutWeight(1).alignItems(HorizontalAlign.Start);
          Toggle({ type: ToggleType.Switch, isOn: this.preferences.enabled })
            .selectedColor(this.theme.primary).enabled(!this.saving)
            .accessibilityText('启用沉浸光感').id('immersive-light-master')
            .onChange((enabled: boolean): void => { this.requestEnabled_(enabled); });
        }.width('100%').alignItems(VerticalAlign.Center);
        if (this.status.length > 0) {
          Text(this.status).fontSize(13).fontColor(this.theme.textSecondary).width('100%');
        }
        if (!this.preferences.enabled) {
          Text('已暂停效果。下方的档位与模块选择会保留，再次开启后恢复。')
            .fontSize(13).fontColor(this.theme.textHint).width('100%');
        }
        if (this.saving) {
          Text('正在保存…').fontSize(13).fontColor(this.theme.textHint).width('100%');
        }
        if (this.saveError.length > 0) {
          // 失败留在当前详情中，用户可以看到旧的确认态并再次操作，不弹出遮挡式提示。
          Text(this.saveError).fontSize(13).fontColor(this.theme.errorText).width('100%')
            .id('immersive-light-save-error');
        }
      }.width('100%').padding(20).borderRadius(24).backgroundColor(this.theme.bgCard);

      Column({ space: 12 }) {
        Text('导航材质档位').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary).width('100%');
        Text('应用于已启用的导航模块。实际观感随设备能力与系统设置调整。')
          .fontSize(13).fontColor(this.theme.textHint).width('100%');
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(NAVIGATION_MATERIAL_MODES, (mode: DockLightMode) => {
            Button(dockLightModeLabel(mode))
              .fontSize(14)
              .fontColor(this.preferences.navigationMode === mode ? this.theme.textOnPrimary : this.theme.textSecondary)
              .backgroundColor(this.preferences.navigationMode === mode ? this.theme.primary : this.theme.bgInput)
              .constraintSize({ minHeight: 44 }).padding({ left: 16, right: 16 })
              .borderRadius(22).margin({ right: 8, bottom: 8 })
              .enabled(this.preferences.enabled && !this.saving && (this.hasPresets || mode === DockLightMode.AUTO))
              .accessibilityText('导航材质，' + dockLightModeLabel(mode) +
                (this.preferences.navigationMode === mode ? '，已选中' : ''))
              .id('immersive-light-mode-' + mode)
              .onClick((): void => { this.requestNavigationMode_(mode); });
          }, (mode: DockLightMode): string => mode);
        }.width('100%');
        if (!this.hasPresets) {
          Text('当前设备未提供手动材质档位，可保留自动适配。')
            .fontSize(13).fontColor(this.theme.textHint).width('100%');
        }
      }.width('100%').padding(20).borderRadius(24).backgroundColor(this.theme.bgCard);

      Column({ space: 16 }) {
        Text('应用位置').fontSize(16).fontWeight(600).fontColor(this.theme.textPrimary).width('100%');
        Row({ space: 16 }) {
          Column({ space: 5 }) {
            Text('底部导航栏').fontSize(16).fontColor(this.theme.textPrimary);
            Text('为底部页签保留轻盈的悬浮材质。').fontSize(13).fontColor(this.theme.textHint);
          }.layoutWeight(1).alignItems(HorizontalAlign.Start);
          Toggle({ type: ToggleType.Switch, isOn: this.preferences.bottomBar })
            .selectedColor(this.theme.primary).enabled(this.preferences.enabled && !this.saving)
            .accessibilityText('底部导航栏光感').id('immersive-light-bottom-bar')
            .onChange((enabled: boolean): void => { this.requestBottomBar_(enabled); });
        }.width('100%').alignItems(VerticalAlign.Center);
        Row().width('100%').height(0.5).backgroundColor(this.theme.divider);
        Row({ space: 16 }) {
          Column({ space: 5 }) {
            Text('圆形图标按钮').fontSize(16).fontColor(this.theme.textPrimary);
            Text('统一控制返回、关闭和同类标题操作；不支持材质的位置使用一致的普通样式。')
              .fontSize(13).fontColor(this.theme.textHint);
          }.layoutWeight(1).alignItems(HorizontalAlign.Start);
          Toggle({ type: ToggleType.Switch, isOn: this.preferences.titleButtons })
            .selectedColor(this.theme.primary).enabled(this.preferences.enabled && !this.saving)
            .accessibilityText('圆形图标按钮光感').id('immersive-light-title-buttons')
            .onChange((enabled: boolean): void => { this.requestTitleButtons_(enabled); });
        }.width('100%').alignItems(VerticalAlign.Center);
      }.width('100%').padding(20).borderRadius(24).backgroundColor(this.theme.bgCard);
    }.width('100%').alignItems(HorizontalAlign.Start);
  }
}
